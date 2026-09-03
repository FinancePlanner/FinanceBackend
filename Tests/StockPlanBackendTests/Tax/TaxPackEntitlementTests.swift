import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Per-year filing pack purchases: the webhook grants them, and they open the
/// preview and the pack report — nothing else — for a free user.
@Suite("Tax pack entitlements", .serialized)
struct TaxPackEntitlementTests {
    private struct FreeEntitlementResolver: EntitlementResolver {
        func resolve(userId: UUID, on _: any Database) async throws -> EntitlementSnapshot {
            EntitlementSnapshot(userId: userId, level: "free")
        }
    }

    private func withFreeApp(_ test: @escaping (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                // BYPASS_BILLING=true in the local .env makes everyone Pro through
                // DefaultEntitlementResolver; the gate under test needs a free user.
                app.entitlementResolver = FreeEntitlementResolver()
                app.usageCounterService = DefaultUsageCounterService(entitlementResolver: FreeEntitlementResolver())
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
            username: "pack_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "pack_\(identifier)@example.com",
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

    private func completeProfile(app: Application, userId: UUID, taxYear: Int, jurisdiction: TaxJurisdiction = .portugal) async throws {
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

    private func webhookEvent(id: String, type: String, userId: UUID, productId: String) throws -> RevenueCatWebhookEvent {
        let json = """
        {"id":"\(id)","type":"\(type)","app_user_id":"\(userId.uuidString)","product_id":"\(productId)","store":"APP_STORE","purchased_at_ms":1756800000000}
        """
        return try JSONDecoder().decode(RevenueCatWebhookEvent.self, from: Data(json.utf8))
    }

    @Test("Product ids parse only for norviq_tax_pack_<year>")
    func productIdParsing() {
        #expect(TaxPackEntitlementService.taxYear(fromProductId: "norviq_tax_pack_2025") == 2025)
        #expect(TaxPackEntitlementService.taxYear(fromProductId: " NORVIQ_TAX_PACK_2024 ") == 2024)
        #expect(TaxPackEntitlementService.taxYear(fromProductId: "norviq_tax_pack_2025_eur") == 2025)
        #expect(TaxPackEntitlementService.taxYear(fromProductId: "pro_yearly") == nil)
        #expect(TaxPackEntitlementService.taxYear(fromProductId: "norviq_tax_pack_25") == nil)
        #expect(TaxPackEntitlementService.taxYear(fromProductId: nil) == nil)
        #expect(TaxPackEntitlementService.productId(taxYear: 2025) == "norviq_tax_pack_2025")
    }

    @Test("A NON_RENEWING_PURCHASE for a pack product grants the year; other consumables do not")
    func webhookGrantsEntitlement() async throws {
        try await withFreeApp { app in
            let user = try await registerUser(app: app)
            let service = TaxPackEntitlementService()

            let other = try webhookEvent(id: "evt-other", type: "NON_RENEWING_PURCHASE", userId: user.userId, productId: "norviq_tip_jar")
            try await app.billingService.process(event: other, rawPayload: "{}", on: app.db)
            #expect(try await service.hasEntitlement(userId: user.userId, taxYear: 2025, on: app.db) == false)

            let pack = try webhookEvent(id: "evt-pack", type: "NON_RENEWING_PURCHASE", userId: user.userId, productId: "norviq_tax_pack_2025")
            try await app.billingService.process(event: pack, rawPayload: "{}", on: app.db)
            #expect(try await service.hasEntitlement(userId: user.userId, taxYear: 2025, on: app.db))
            #expect(try await service.hasEntitlement(userId: user.userId, taxYear: 2024, on: app.db) == false)

            // Replaying the same event is idempotent, and a second purchase for
            // the same year updates rather than violating the unique index.
            try await app.billingService.process(event: pack, rawPayload: "{}", on: app.db)
            let again = try webhookEvent(id: "evt-pack-2", type: "NON_RENEWING_PURCHASE", userId: user.userId, productId: "norviq_tax_pack_2025")
            try await app.billingService.process(event: again, rawPayload: "{}", on: app.db)
            let rows = try await TaxPackEntitlement.query(on: app.db).filter(\.$userId == user.userId).all()
            #expect(rows.count == 1)
            #expect(rows.first?.providerEventId == "evt-pack-2")
            #expect(rows.first?.source == "app_store")

            // The Pro entitlement is untouched by a consumable.
            let entitlement = try await Entitlement.query(on: app.db).filter(\.$userId == user.userId).first()
            #expect(entitlement == nil || entitlement?.level == "free")
        }
    }

    @Test("A free user with a pack for 2025 can preview and generate that year's pack, and nothing else")
    func entitlementOpensOnlyThePack() async throws {
        try await withFreeApp { app in
            let user = try await registerUser(app: app)
            try await completeProfile(app: app, userId: user.userId, taxYear: 2025)
            try await completeProfile(app: app, userId: user.userId, taxYear: 2024)

            try await app.testing().test(.GET, "v1/tax/filing/preview?taxYear=2025", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            try await TaxPackEntitlementService().grant(
                userId: user.userId, taxYear: 2025, source: "test", productId: "norviq_tax_pack_2025", providerEventId: nil, on: app.db
            )

            try await app.testing().test(.GET, "v1/tax/filing/preview?taxYear=2025", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(FilingPackPreviewResponse.self)
                #expect(body.jurisdiction == .portugal)
                #expect(body.disposalCount == 0)
            })

            try await app.testing().test(.GET, "v1/tax/filing/preview?taxYear=2024", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            var reportId = ""
            try await app.testing().test(.POST, "v1/tax/reports", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(TaxReportRequest(taxYear: 2025, kind: .annualFilingPack, format: .csv))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let report = try res.content.decode(TaxReportResponse.self)
                #expect(report.kind == .annualFilingPack)
                reportId = report.id
            })

            try await app.testing().test(.GET, "v1/tax/reports/\(reportId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "v1/tax/reports", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(TaxReportRequest(taxYear: 2025, kind: .transactionWorkpaper, format: .csv))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            try await app.testing().test(.POST, "v1/tax/reports", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(TaxReportRequest(taxYear: 2024, kind: .annualFilingPack, format: .csv))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }
}
