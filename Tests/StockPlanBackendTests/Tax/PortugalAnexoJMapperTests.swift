import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Portugal Anexo J mapper")
struct PortugalAnexoJMapperTests {
    private static func day(_ value: String) -> Date {
        FXRateResolverTests.day(value)
    }

    private static func disposal(type: String = "stock", isin: String? = "US0378331005", country: String? = "US") -> FilingDisposal {
        FilingDisposal(
            symbol: "AAPL", isin: isin, instrumentType: type, quantity: 10,
            acquisitionDate: day("2025-02-03"), acquisitionValue: Decimal(string: "909.09")!,
            realizationDate: day("2025-09-10"), realizationValue: Decimal(string: "1362.73")!,
            expenses: Decimal(string: "0.91")!, gain: Decimal(string: "453.64")!,
            holdingPeriod: "short", sourceCountry: country, fx: [], lotDisposalID: UUID()
        )
    }

    private static func ledger(disposals: [FilingDisposal] = [], dividends: [FilingDividend] = [], unsupported: [FilingUnsupportedRow] = []) -> FilingLedger {
        FilingLedger(taxYear: 2025, reportingCurrency: "EUR", jurisdiction: .portugal, disposals: disposals, dividends: dividends, unsupported: unsupported)
    }

    @Test("One US share disposal becomes one Quadro 9.2A row with code G01 and country 840")
    func sharesRow() throws {
        let pack = PortugalAnexoJMapper().map(Self.ledger(disposals: [Self.disposal()]))
        let quadro = try #require(pack.sections.first { $0.id == PortugalAnexoJMapper.sharesSectionID })
        #expect(quadro.rows == [["G01", "840", "2025", "09", "1362.73", "2025", "02", "909.09", "0.91"]])
        #expect(quadro.totals["gain"] == Decimal(string: "453.64")!)
        #expect(pack.summary["totalGain"] == Decimal(string: "453.64")!)
        #expect(pack.formName == "IRS Modelo 3 — Anexo J")
        #expect(pack.rulePackVersion == "PT-2026.2")
    }

    @Test("A US dividend becomes a Quadro 8A row with code E11, gross, and withholding")
    func dividendRow() throws {
        let dividend = try FilingDividend(
            symbol: "AAPL", payDate: Self.day("2025-06-13"), sourceCountry: "US",
            gross: #require(Decimal(string: "90.91")), withholding: #require(Decimal(string: "13.64")), net: #require(Decimal(string: "77.27")),
            fx: FXConversion(amount: #require(Decimal(string: "90.91")), rate: #require(Decimal(string: "1.10")), fixingDate: Self.day("2025-06-13"), sourceCurrency: "USD"),
            dividendID: UUID()
        )
        let pack = PortugalAnexoJMapper().map(Self.ledger(dividends: [dividend]))
        let quadro = try #require(pack.sections.first { $0.id == PortugalAnexoJMapper.dividendsSectionID })
        #expect(quadro.rows == [["E11", "840", "90.91", "13.64", "0.00"]])
        #expect(quadro.totals["withholding"] == Decimal(string: "13.64")!)
    }

    @Test("An option disposal is routed to the manual section, not to 9.2A")
    func unsupportedInstrument() throws {
        let pack = PortugalAnexoJMapper().map(Self.ledger(disposals: [Self.disposal(type: "option")]))
        let shares = try #require(pack.sections.first { $0.id == PortugalAnexoJMapper.sharesSectionID })
        let manual = try #require(pack.sections.first { $0.id == PortugalAnexoJMapper.unsupportedSectionID })
        #expect(shares.rows.isEmpty)
        #expect(manual.rows.count == 1)
        #expect(manual.rows[0][0] == "AAPL")
        #expect(shares.totals["gain"] == 0)
    }

    @Test("Unknown country renders blank instead of a wrong code")
    func unknownCountryBlank() throws {
        let pack = PortugalAnexoJMapper().map(Self.ledger(disposals: [Self.disposal(isin: nil, country: nil)]))
        let quadro = try #require(pack.sections.first { $0.id == PortugalAnexoJMapper.sharesSectionID })
        #expect(quadro.rows[0][1] == "")
    }

    @Test("Money formatting always carries two decimals")
    func moneyFormat() throws {
        #expect(FilingFormat.money(910) == "910.00")
        #expect(try FilingFormat.money(#require(Decimal(string: "910.5"))) == "910.50")
        #expect(try FilingFormat.money(#require(Decimal(string: "-1.2"))) == "-1.20")
        #expect(try FilingFormat.money(#require(Decimal(string: "0.005"))) == "0.00")
    }
}
