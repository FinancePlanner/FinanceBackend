import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// GET /v1/tax/filing/preview. Runs with the ambient BYPASS_BILLING=true of
/// the local .env, so every user is Pro; the Pro gate itself is covered by
/// the existing tax report tests.
@Suite("Filing pack preview endpoint", .serialized)
struct FilingPreviewEndpointTests {
    private static func day(_ value: String) -> Date {
        FXRateResolverTests.day(value)
    }

    private func withApp(_ test: @escaping (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let identifier = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "preview_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "preview_\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            token = try res.content.decode(AuthResponse.self).token
        })
        let session = try await app.jwt.keys.verify(token, as: SessionToken.self)
        return (token, session.userId)
    }

    private func completePortugalProfile(app: Application, userId: UUID, taxYear: Int, jurisdiction: TaxJurisdiction = .portugal) async throws {
        let profile = TaxProfile()
        profile.userId = userId
        profile.jurisdiction = jurisdiction.rawValue
        profile.taxYear = taxYear
        profile.filingStatus = "single"
        profile.reportingCurrency = "EUR"
        profile.profileJSON = "{}"
        profile.isComplete = true
        try await profile.create(on: app.db)
    }

    private func seedEURRoundTrip(app: Application, userId: UUID) async throws {
        let account = Account()
        account.userId = userId
        account.externalId = "U\(UUID().uuidString.prefix(6))"
        account.broker = "ibkr"
        account.displayName = "IBKR"
        account.baseCurrency = "EUR"
        account.taxWrapper = "taxable"
        try await account.create(on: app.db)
        let instrument = Instrument(conid: "1", symbol: "ASML", exchange: "AEB", currency: "EUR", name: "ASML")
        instrument.instrumentType = "stock"
        instrument.isin = "NL0010273215"
        try await instrument.create(on: app.db)
        let accountId = try account.requireID()
        let instrumentId = try instrument.requireID()
        // EUR-denominated so the endpoint test never touches the ECB provider.
        let buy = Transaction(accountId: accountId, instrumentId: instrumentId, externalId: "b1", type: "BUY", quantity: 2, price: 500, currency: "EUR", tradeDate: Self.day("2025-03-03"), fees: 2)
        try await buy.create(on: app.db)
        _ = try await TaxLotAccountingService().recordAcquisition(transaction: buy, on: app.db)
        let sell = Transaction(accountId: accountId, instrumentId: instrumentId, externalId: "s1", type: "SELL", quantity: 2, price: 650, currency: "EUR", tradeDate: Self.day("2025-10-06"), fees: 2)
        try await sell.create(on: app.db)
        _ = try await TaxLotAccountingService().recordDisposal(transaction: sell, method: .fifo, on: app.db)
    }

    @Test("Preview returns Anexo J sections and counts for a complete PT profile")
    func previewReturnsPack() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await completePortugalProfile(app: app, userId: user.userId, taxYear: 2025)
            try await seedEURRoundTrip(app: app, userId: user.userId)

            try await app.testing().test(.GET, "v1/tax/filing/preview?taxYear=2025", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(FilingPackPreviewResponse.self)
                #expect(body.jurisdiction == .portugal)
                #expect(body.formName == "IRS Modelo 3 — Anexo J")
                #expect(body.disposalCount == 1)
                #expect(body.dividendCount == 0)
                #expect(body.unsupportedCount == 0)
                #expect(body.sections.first?.id == PortugalAnexoJMapper.sharesSectionID)
                #expect(body.sections.first?.rows.first?[0] == "G01")
                #expect(body.sections.first?.rows.first?[1] == "528")
                #expect(body.summary["totalGain"] == Decimal(296)) // proceeds 1300 - 2 fees, basis 1000 + 2 fees
            })
        }
    }

    @Test("Preview for a complete DE profile returns Anlage KAP with the disposal in Zeile 19/20")
    func previewReturnsGermanPack() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await completePortugalProfile(app: app, userId: user.userId, taxYear: 2025, jurisdiction: .germany)
            try await seedEURRoundTrip(app: app, userId: user.userId)

            try await app.testing().test(.GET, "v1/tax/filing/preview?taxYear=2025", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(FilingPackPreviewResponse.self)
                #expect(body.jurisdiction == .germany)
                #expect(body.formName == "ESt 1 A — Anlage KAP / KAP-INV")
                #expect(body.rulePackVersion == "DE-2026.1")
                #expect(body.disposalCount == 1)
                #expect(body.dividendCount == 0)
                #expect(body.unsupportedCount == 0)
                let kap = try #require(body.sections.first { $0.id == GermanyAnlageKAPMapper.kapSectionID })
                #expect(kap.rows.first { $0[0] == "19" }?[2] == "296.00")
                #expect(kap.rows.first { $0[0] == "20" }?[2] == "296.00")
                #expect(body.summary["totalGain"] == Decimal(296))
            })
        }
    }

    @Test("Preview without a complete profile is a 409")
    func previewWithoutProfileConflicts() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await app.testing().test(.GET, "v1/tax/filing/preview?taxYear=2025", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Preview without taxYear is a 400")
    func previewRequiresYear() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await app.testing().test(.GET, "v1/tax/filing/preview", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }
}
