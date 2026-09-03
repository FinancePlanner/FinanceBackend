import Foundation
@testable import StockPlanBackend
import Testing

@Suite("IBKR activity statement parser")
struct IBKRActivityStatementTests {
    static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Keeps stock orders, drops ClosedLot/SubTotal/Total rows and non-stock categories")
    func trades() throws {
        let statement = try IBKRActivityStatement.parse(Self.fixture("ibkr-activity-sample.csv"))
        #expect(statement.trades.count == 2)
        #expect(statement.trades[0].symbol == "AAPL")
        #expect(statement.trades[0].quantity == 10)
        #expect(statement.trades[0].price == 150)
        #expect(statement.trades[0].fee == 1)
        #expect(statement.trades[0].tradeDate == FXRateResolverTests.day("2025-03-14"))
        #expect(statement.trades[1].quantity == -10)
        #expect(statement.trades[1].tradeDate == FXRateResolverTests.day("2025-09-10"))
        // ClosedLot, SubTotal, Total, and the Forex order.
        #expect(statement.skippedTradeRows == 4)
    }

    @Test("Dividend and withholding lines carry symbol, ISIN, date and signed amount")
    func cashLines() throws {
        let statement = try IBKRActivityStatement.parse(Self.fixture("ibkr-activity-sample.csv"))
        #expect(statement.dividends.count == 1)
        #expect(statement.dividends[0].symbol == "AAPL")
        #expect(statement.dividends[0].isin == "US0378331005")
        #expect(statement.dividends[0].amount == 2.5)
        #expect(statement.dividends[0].date == FXRateResolverTests.day("2025-05-15"))
        #expect(statement.withholdingTaxes.count == 1)
        #expect(statement.withholdingTaxes[0].amount == -0.38)
        #expect(statement.withholdingTaxes[0].symbol == "AAPL")
    }

    @Test("Instrument table yields ISIN, listing exchange and type")
    func instruments() throws {
        let statement = try IBKRActivityStatement.parse(Self.fixture("ibkr-activity-sample.csv"))
        #expect(statement.instruments.count == 3)
        #expect(statement.instruments[0].isin == "US0378331005")
        #expect(statement.instruments[0].listingExchange == "NASDAQ")
        #expect(statement.instruments[0].conid == "265598")
        #expect(IBKRActivityStatementImporter.instrumentType(ibkrType: statement.instruments[0].type) == "stock")
        // "CSPX, SXR8" is one row with two symbols; both must resolve to the ETF's ISIN.
        #expect(statement.instruments.map(\.symbol) == ["AAPL", "CSPX", "SXR8"])
        #expect(statement.instruments[1].isin == "IE00B5BMR087")
        #expect(statement.instruments[2].isin == "IE00B5BMR087")
        #expect(IBKRActivityStatementImporter.instrumentType(ibkrType: statement.instruments[1].type) == "etf")
        #expect(IBKRActivityStatementImporter.instrumentType(ibkrType: "ETF") == "etf")
    }

    @Test("Description parsing tolerates missing ISIN and thousands separators")
    func helpers() {
        #expect(IBKRActivityStatement.symbolAndISIN(from: "VWCE(IE00BK5BQT80) Cash Dividend EUR 0.10 per Share") == ("VWCE", "IE00BK5BQT80"))
        #expect(IBKRActivityStatement.symbolAndISIN(from: "MSFT Cash Dividend USD 0.75 per Share") == ("MSFT", nil))
        #expect(IBKRActivityStatement.parseNumber("\"1,000\"".replacingOccurrences(of: "\"", with: "")) == 1000)
        #expect(IBKRActivityStatement.parseDate("2025-03-14, 09:31:02") == FXRateResolverTests.day("2025-03-14"))
        #expect(IBKRActivityStatement.parseDate("20250314") == FXRateResolverTests.day("2025-03-14"))
    }
}
