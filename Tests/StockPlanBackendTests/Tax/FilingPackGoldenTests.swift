import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Task 7: the whole pipeline on a real statement. Fixtures live next to this
/// file (loaded via #filePath, not Bundle):
///
/// - `ecb-usd-2025.csv` — one recorded ECB `EXR/D.USD.EUR.SP00.A` csvdata
///   response for 2025 (committed), so nothing here touches the network.
/// - `ibkr-2025-anonymized.csv` — Fernando's 2025 IBKR Activity Statement CSV
///   with account id and names replaced. Not committed until anonymised; the
///   golden test is skipped while it is missing.
/// - `anexo-j-2025.golden.csv` — written on the first run, asserted byte-equal
///   on every later one. Compare it to the filed Anexo J / IBKR Realized Summary
///   and log every difference in docs/tax-v2-validation.md.
@Suite("Filing pack golden", .serialized)
struct FilingPackGoldenTests {
    static let fixturesDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let statementFixture = fixturesDirectory.appendingPathComponent("ibkr-2025-anonymized.csv")
    static let goldenFixture = fixturesDirectory.appendingPathComponent("anexo-j-2025.golden.csv")
    static var hasStatementFixture: Bool {
        FileManager.default.fileExists(atPath: statementFixture.path)
    }

    static var hasGolden: Bool {
        FileManager.default.fileExists(atPath: goldenFixture.path)
    }

    /// Recording is a deliberate local act (`TAX_GOLDEN_RECORD=1`); CI only
    /// ever asserts against a committed golden, so an incomplete statement
    /// cannot turn main red while the earlier years are still being gathered.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["TAX_GOLDEN_RECORD"] == "1"
    }

    static var goldenEnabled: Bool {
        hasStatementFixture && (hasGolden || isRecording)
    }

    /// The recorded ECB series, parsed by the same code the live provider uses.
    /// One file per currency and year; acquisitions reach back into the years
    /// before the tax year, so those series have to be recorded too.
    struct RecordedECB: FXDailyRateProviding {
        static let usdFiles = ["ecb-usd-2024.csv", "ecb-usd-2025.csv"]

        let rows: [FXDailyRate]

        init(files: [String]) throws {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            rows = try files.flatMap { file in
                let body = try String(contentsOf: FilingPackGoldenTests.fixturesDirectory.appendingPathComponent(file), encoding: .utf8)
                return ECBDailyRateProvider.parseCSV(body, quote: "USD", formatter: formatter)
            }
            .sorted { $0.date < $1.date }
        }

        func rates(quote: String, from: Date, to: Date) async throws -> [FXDailyRate] {
            rows.filter { $0.quote == quote.uppercased() && $0.date >= from && $0.date <= to }
        }
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
            username: "golden_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "golden_\(identifier)@example.com",
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

    private func buildPortugalPack(statementCSV: String, app: Application) async throws -> (pack: FilingPack, ledger: FilingLedger, result: IBKRActivityStatementImporter.Result) {
        let userId = try await registerUser(app: app)
        let statement = try IBKRActivityStatement.parse(statementCSV)
        let result = try await IBKRActivityStatementImporter().importStatement(
            statement, userId: userId, accountExternalId: "U0000000", baseCurrency: "EUR", on: app.db
        )
        let resolver = try FXRateResolver(provider: RecordedECB(files: RecordedECB.usdFiles), db: nil)
        let ledger = try await FilingLedgerBuilder(fx: resolver).build(
            userId: userId, taxYear: 2025, jurisdiction: .portugal, reportingCurrency: "EUR", on: app.db
        )
        return (PortugalAnexoJMapper().map(ledger), ledger, result)
    }

    @Test("The recorded ECB fixtures cover 2024–2025 and parse through the live provider's CSV reader")
    func recordedRatesParse() throws {
        let provider = try RecordedECB(files: RecordedECB.usdFiles)
        #expect(provider.rows.count > 490) // ~255 TARGET business days per year
        #expect(provider.rows.first?.date == FXRateResolverTests.day("2024-01-02"))
        #expect(provider.rows.last?.date == FXRateResolverTests.day("2025-12-31"))
        #expect(provider.rows.allSatisfy { $0.rate > 0.9 && $0.rate < 1.3 })
    }

    @Test("A synthetic activity statement flows end to end into one Anexo J row and one 8A row")
    func syntheticStatement() async throws {
        try await withApp { app in
            let csv = try IBKRActivityStatementTests.fixture("ibkr-activity-sample.csv")
            let (pack, ledger, result) = try await buildPortugalPack(statementCSV: csv, app: app)

            #expect(result.transactions == 2)
            #expect(result.lotDisposals == 1)
            #expect(result.unmatchedSells == 0)
            #expect(result.dividends == 1)
            #expect(result.dividendsWithWithholding == 1)
            #expect(result.skippedTradeRows == 4)

            let provider = try RecordedECB(files: RecordedECB.usdFiles)
            let rate = { (day: String) in provider.rows.first { $0.date == FXRateResolverTests.day(day) }!.rate }
            #expect(ledger.disposals.count == 1)
            let disposal = ledger.disposals[0]
            #expect(disposal.acquisitionValue == (Decimal(1501) / rate("2025-03-14")).roundedForFiling(scale: 2))
            #expect(disposal.realizationValue == (Decimal(1799) / rate("2025-09-10")).roundedForFiling(scale: 2))
            #expect(disposal.sourceCountry == "US")
            #expect(ledger.dividends.count == 1)
            #expect(ledger.dividends[0].gross == (Decimal(string: "2.88")! / rate("2025-05-15")).roundedForFiling(scale: 2))
            #expect(ledger.dividends[0].withholding == (Decimal(string: "0.38")! / rate("2025-05-15")).roundedForFiling(scale: 2))

            let shares = try #require(pack.sections.first { $0.id == PortugalAnexoJMapper.sharesSectionID })
            #expect(shares.rows.count == 1)
            #expect(shares.rows[0][0] == "G01")
            #expect(shares.rows[0][1] == "840")
            #expect(shares.rows[0][2] == "2025")
            #expect(shares.rows[0][3] == "09")
            let dividends = try #require(pack.sections.first { $0.id == PortugalAnexoJMapper.dividendsSectionID })
            #expect(dividends.rows == [["E11", "840", FilingFormat.money(ledger.dividends[0].gross), FilingFormat.money(ledger.dividends[0].withholding), "0.00"]])
            #expect(pack.sections.first { $0.id == PortugalAnexoJMapper.unsupportedSectionID }?.rows.isEmpty == true)

            let rendered = String(decoding: FilingPackRenderer().csv(pack), as: UTF8.self)
            #expect(rendered.contains("section,anexo-j-9.2A"))
            #expect(rendered.contains("G01,840,2025,09,"))
        }
    }

    @Test(
        "Anonymised 2025 statement renders the golden Anexo J CSV",
        .enabled(if: FilingPackGoldenTests.goldenEnabled, "Needs Fixtures/ibkr-2025-anonymized.csv plus either a committed anexo-j-2025.golden.csv or TAX_GOLDEN_RECORD=1 to write one")
    )
    func goldenStatement() async throws {
        try await withApp { app in
            let csv = try String(contentsOf: Self.statementFixture, encoding: .utf8)
            let (pack, ledger, result) = try await buildPortugalPack(statementCSV: csv, app: app)
            let rendered = FilingPackRenderer().csv(pack)

            // Anything the pipeline could not place must be visible, not silent.
            #expect(result.unmatchedSells == 0, "sells without an opening lot in the statement: \(result.unmatchedSellReferences.joined(separator: ", ")) — paste the Trades rows of the earlier statement(s) that bought them")
            let unknownInstruments = Set(ledger.disposals.filter { $0.isin == nil }.map(\.symbol))
            #expect(unknownInstruments.isEmpty, "disposals without an ISIN (missing from Financial Instrument Information): \(unknownInstruments.sorted())")
            #expect(ledger.unsupported.isEmpty, "unsupported rows: \(ledger.unsupported)")

            if FileManager.default.fileExists(atPath: Self.goldenFixture.path) {
                let golden = try Data(contentsOf: Self.goldenFixture)
                #expect(rendered == golden, "Anexo J output changed. If the change is intended, delete anexo-j-2025.golden.csv and re-run to re-golden; record why in docs/tax-v2-validation.md.")
            } else {
                try rendered.write(to: Self.goldenFixture, options: .atomic)
                Issue.record("Golden written for the first time at \(Self.goldenFixture.path). Compare it to the filed Anexo J, then commit it and re-run.")
            }
        }
    }
}
