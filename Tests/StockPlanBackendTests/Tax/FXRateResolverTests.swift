import Foundation
@testable import StockPlanBackend
import Testing

@Suite("FX rate resolver")
struct FXRateResolverTests {
    struct StubProvider: FXDailyRateProviding {
        let rows: [FXDailyRate]
        func rates(quote: String, from: Date, to: Date) async throws -> [FXDailyRate] {
            rows.filter { $0.quote == quote && $0.date >= from && $0.date <= to }
        }
    }

    static func day(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)!
    }

    private let usdOnMarch14 = FXDailyRate(date: day("2025-03-14"), base: "EUR", quote: "USD", rate: Decimal(string: "1.0880")!)

    @Test("USD converts to EUR at the fixing on the trade date")
    func convertsOnFixingDate() async throws {
        let resolver = FXRateResolver(provider: StubProvider(rows: [usdOnMarch14]), db: nil)
        let out = try await resolver.convert(Decimal(1088), from: "USD", to: "EUR", on: Self.day("2025-03-14"))
        #expect(out.amount == Decimal(1000))
        #expect(out.rate == Decimal(string: "1.0880")!)
        #expect(out.fixingDate == Self.day("2025-03-14"))
        #expect(out.sourceCurrency == "USD")
    }

    @Test("A weekend uses the last fixing before it and reports that date")
    func weekendFallsBack() async throws {
        let resolver = FXRateResolver(provider: StubProvider(rows: [usdOnMarch14]), db: nil)
        let out = try await resolver.convert(Decimal(1088), from: "usd", to: "eur", on: Self.day("2025-03-16"))
        #expect(out.amount == Decimal(1000))
        #expect(out.fixingDate == Self.day("2025-03-14"))
    }

    @Test("Same currency is identity with rate 1")
    func identity() async throws {
        let resolver = FXRateResolver(provider: StubProvider(rows: []), db: nil)
        let out = try await resolver.convert(Decimal(42), from: "EUR", to: "EUR", on: Self.day("2025-01-02"))
        #expect(out.amount == 42)
        #expect(out.rate == 1)
    }

    @Test("No fixing within ten days throws")
    func missingFixingThrows() async throws {
        let resolver = FXRateResolver(provider: StubProvider(rows: []), db: nil)
        await #expect(throws: FXRateResolverError.noFixing(currency: "USD", on: Self.day("2025-01-02"))) {
            _ = try await resolver.convert(Decimal(1), from: "USD", to: "EUR", on: Self.day("2025-01-02"))
        }
    }

    @Test("Only EUR reporting is supported for now")
    func nonEuroReportingThrows() async throws {
        let resolver = FXRateResolver(provider: StubProvider(rows: []), db: nil)
        await #expect(throws: FXRateResolverError.unsupportedReportingCurrency("USD")) {
            _ = try await resolver.convert(Decimal(1), from: "EUR", to: "USD", on: Self.day("2025-01-02"))
        }
    }

    @Test("Amounts round half-even to cents")
    func roundsBankers() async throws {
        let rows = try [FXDailyRate(date: Self.day("2025-03-14"), base: "EUR", quote: "USD", rate: #require(Decimal(string: "1.10")))]
        let resolver = FXRateResolver(provider: StubProvider(rows: rows), db: nil)
        let out = try await resolver.convert(Decimal(1001), from: "USD", to: "EUR", on: Self.day("2025-03-14"))
        #expect(out.amount == Decimal(string: "910.00")!)
    }

    @Test("ECB csvdata parses by header name and skips malformed rows")
    func parsesECBCSV() {
        let csv = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE,OBS_STATUS
        EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2025-03-13,1.0855,A
        EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2025-03-14,1.0880,A
        EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,not-a-date,1.0900,A
        """
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let rows = ECBDailyRateProvider.parseCSV(csv, quote: "USD", formatter: formatter)
        #expect(rows.count == 2)
        #expect(rows.last?.rate == Decimal(string: "1.0880")!)
        #expect(rows.first?.date == Self.day("2025-03-13"))
    }
}
