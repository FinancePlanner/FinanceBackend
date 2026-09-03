import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Filing ledger builder", .serialized)
struct FilingLedgerBuilderTests {
    /// Every day converts at the same rate; enough to check the arithmetic.
    struct FlatUSD: FXDailyRateProviding {
        let rate: Decimal
        func rates(quote: String, from: Date, to: Date) async throws -> [FXDailyRate] {
            guard quote == "USD" else { return [] }
            var out: [FXDailyRate] = []
            var cursor = from
            while cursor <= to {
                out.append(FXDailyRate(date: cursor, base: "EUR", quote: "USD", rate: rate))
                cursor = Calendar.utcFiling.date(byAdding: .day, value: 1, to: cursor)!
            }
            return out
        }
    }

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

    private func registerUser(app: Application) async throws -> UUID {
        let identifier = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "filing_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "filing_\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            token = try res.content.decode(AuthResponse.self).token
        })
        return try await app.jwt.keys.verify(token, as: SessionToken.self).userId
    }

    private func seedUSDAccount(app: Application, userId: UUID) async throws -> (accountId: UUID, instrumentId: UUID) {
        let account = Account()
        account.userId = userId
        account.externalId = "U\(UUID().uuidString.prefix(6))"
        account.broker = "ibkr"
        account.displayName = "IBKR"
        account.baseCurrency = "USD"
        account.taxWrapper = "taxable"
        try await account.create(on: app.db)
        let instrument = Instrument(conid: "265598", symbol: "AAPL", exchange: "NASDAQ", currency: "USD", name: "Apple Inc.")
        instrument.instrumentType = "stock"
        instrument.isin = "US0378331005"
        try await instrument.create(on: app.db)
        return try (account.requireID(), instrument.requireID())
    }

    @discardableResult
    private func trade(app: Application, accountId: UUID, instrumentId: UUID, type: String, quantity: Double, price: Double, fees: Double, on date: String) async throws -> Transaction {
        let tx = Transaction(accountId: accountId, instrumentId: instrumentId, externalId: UUID().uuidString, type: type, quantity: quantity, price: price, currency: "USD", tradeDate: Self.day(date), fees: fees)
        try await tx.create(on: app.db)
        return tx
    }

    @Test("A USD round trip and a dividend become EUR rows for the year")
    func buildsEurLedger() async throws {
        try await withApp { app in
            let userId = try await registerUser(app: app)
            let (accountId, instrumentId) = try await seedUSDAccount(app: app, userId: userId)
            let accounting = TaxLotAccountingService()
            let buy = try await trade(app: app, accountId: accountId, instrumentId: instrumentId, type: "BUY", quantity: 10, price: 100, fees: 1, on: "2025-02-03")
            _ = try await accounting.recordAcquisition(transaction: buy, on: app.db)
            let sell = try await trade(app: app, accountId: accountId, instrumentId: instrumentId, type: "SELL", quantity: 10, price: 150, fees: 1, on: "2025-09-10")
            let disposals = try await accounting.recordDisposal(transaction: sell, method: .fifo, on: app.db)
            #expect(disposals.count == 1)

            let dividend = Dividend(accountId: accountId, instrumentId: instrumentId, externalId: "d1", amount: 85, currency: "USD", payDate: Self.day("2025-06-13"))
            dividend.withholdingTax = 15
            dividend.grossAmount = 100
            dividend.sourceCountry = "US"
            try await dividend.create(on: app.db)

            let builder = FilingLedgerBuilder(fx: FXRateResolver(provider: FlatUSD(rate: Decimal(string: "1.10")!), db: nil))
            let ledger = try await builder.build(userId: userId, taxYear: 2025, jurisdiction: .portugal, reportingCurrency: "EUR", on: app.db)

            #expect(ledger.disposals.count == 1)
            let row = ledger.disposals[0]
            #expect(row.symbol == "AAPL")
            #expect(row.sourceCountry == "US")
            #expect(row.acquisitionDate == Self.day("2025-02-03"))
            #expect(row.realizationDate == Self.day("2025-09-10"))
            // Cost basis and proceeds come from the lot ledger; only the FX division is ours.
            #expect(row.acquisitionValue == (Decimal(disposals[0].costBasis) / Decimal(string: "1.10")!).roundedForFiling(scale: 2))
            #expect(row.realizationValue == (Decimal(disposals[0].proceeds) / Decimal(string: "1.10")!).roundedForFiling(scale: 2))
            #expect(row.gain == row.realizationValue - row.acquisitionValue)
            #expect(row.expenses == Decimal(string: "0.91")!)
            #expect(row.fx.count == 2)

            #expect(ledger.dividends.count == 1)
            #expect(ledger.dividends[0].gross == Decimal(string: "90.91")!)
            #expect(ledger.dividends[0].withholding == Decimal(string: "13.64")!)
            #expect(ledger.dividends[0].net == Decimal(string: "77.27")!)
            #expect(ledger.unsupported.isEmpty)
        }
    }

    @Test("Disposals and dividends outside the tax year are excluded")
    func yearFilter() async throws {
        try await withApp { app in
            let userId = try await registerUser(app: app)
            let (accountId, instrumentId) = try await seedUSDAccount(app: app, userId: userId)
            let accounting = TaxLotAccountingService()
            let buy = try await trade(app: app, accountId: accountId, instrumentId: instrumentId, type: "BUY", quantity: 5, price: 100, fees: 0, on: "2025-02-03")
            _ = try await accounting.recordAcquisition(transaction: buy, on: app.db)
            let sell = try await trade(app: app, accountId: accountId, instrumentId: instrumentId, type: "SELL", quantity: 5, price: 120, fees: 0, on: "2026-01-05")
            _ = try await accounting.recordDisposal(transaction: sell, method: .fifo, on: app.db)
            try await Dividend(accountId: accountId, instrumentId: instrumentId, externalId: "d2", amount: 10, currency: "USD", payDate: Self.day("2024-12-31")).create(on: app.db)

            let builder = FilingLedgerBuilder(fx: FXRateResolver(provider: FlatUSD(rate: 1), db: nil))
            let ledger = try await builder.build(userId: userId, taxYear: 2025, jurisdiction: .portugal, reportingCurrency: "EUR", on: app.db)
            #expect(ledger.disposals.isEmpty)
            #expect(ledger.dividends.isEmpty)
        }
    }

    @Test("A user with no accounts gets an empty ledger, not an error")
    func noAccounts() async throws {
        try await withApp { app in
            let userId = try await registerUser(app: app)
            let builder = FilingLedgerBuilder(fx: FXRateResolver(provider: FlatUSD(rate: 1), db: nil))
            let ledger = try await builder.build(userId: userId, taxYear: 2025, jurisdiction: .portugal, reportingCurrency: "EUR", on: app.db)
            #expect(ledger.disposals.isEmpty && ledger.dividends.isEmpty)
        }
    }
}
