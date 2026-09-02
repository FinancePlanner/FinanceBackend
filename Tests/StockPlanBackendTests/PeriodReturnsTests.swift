import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Period returns mapping")
struct PeriodReturnsMappingTests {
    @Test("Maps FMP 3M, 6M, and ytd windows and ignores extra periods")
    func mapsFMPWindows() throws {
        let json = Data(
            """
            {
              "symbol": "AAPL",
              "1D": 0.21,
              "5D": 3.14,
              "1M": 8.2,
              "3M": 12.5,
              "6M": 15.3,
              "ytd": 18.2,
              "1Y": 22.1,
              "5Y": 120.0
            }
            """.utf8
        )
        let item = try JSONDecoder().decode(FMPStockPriceChange.self, from: json)
        let mapped = mapFMPPriceChange(item)
        #expect(mapped.symbol == "AAPL")
        #expect(mapped.threeMonth == 12.5)
        #expect(mapped.sixMonth == 15.3)
        #expect(mapped.yearToDate == 18.2)
        #expect(mapped.asOf == nil)
    }

    @Test("Treats a missing window as nil rather than zero")
    func nilWhenWindowMissing() throws {
        let json = Data(
            """
            { "symbol": "NEW", "3M": 5.0, "ytd": 8.0 }
            """.utf8
        )
        let item = try JSONDecoder().decode(FMPStockPriceChange.self, from: json)
        let mapped = mapFMPPriceChange(item)
        #expect(mapped.threeMonth == 5.0)
        #expect(mapped.sixMonth == nil)
        #expect(mapped.yearToDate == 8.0)
    }

    @Test("Accepts YTD uppercase and integer window values")
    func acceptsAlternateKeysAndInts() throws {
        let json = Data(
            """
            { "symbol": "msft", "3M": 1, "6M": 2, "YTD": 3 }
            """.utf8
        )
        let item = try JSONDecoder().decode(FMPStockPriceChange.self, from: json)
        let mapped = mapFMPPriceChange(item)
        #expect(mapped.symbol == "MSFT")
        #expect(mapped.threeMonth == 1)
        #expect(mapped.sixMonth == 2)
        #expect(mapped.yearToDate == 3)
    }

    @Test("hasUsableWindows is false when every window is nil")
    func hasUsableWindowsFalseWhenEmpty() {
        #expect(emptyPeriodReturns(symbol: "AMD").hasUsableWindows == false)
    }

    @Test("hasUsableWindows is true when any window is present")
    func hasUsableWindowsTrueWhenAnyWindowPresent() {
        #expect(
            StockPeriodReturnsResponse(
                symbol: "AMD",
                threeMonth: nil,
                sixMonth: 1.2,
                yearToDate: nil,
                asOf: nil
            ).hasUsableWindows
        )
    }
}
