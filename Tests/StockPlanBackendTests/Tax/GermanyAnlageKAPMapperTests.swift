import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Germany Anlage KAP mapper")
struct GermanyAnlageKAPMapperTests {
    private static func day(_ value: String) -> Date {
        FXRateResolverTests.day(value)
    }

    private static func disposal(
        symbol: String = "SAP",
        type: String = "stock",
        isin: String? = "DE0007164600",
        country: String? = "DE",
        acquisition: Decimal = Decimal(string: "1000.00")!,
        realization: Decimal = Decimal(string: "1300.00")!,
        expenses: Decimal = Decimal(string: "2.00")!
    ) -> FilingDisposal {
        FilingDisposal(
            symbol: symbol, isin: isin, instrumentType: type, quantity: 10,
            acquisitionDate: day("2025-02-03"), acquisitionValue: acquisition,
            realizationDate: day("2025-09-10"), realizationValue: realization,
            expenses: expenses, gain: realization - acquisition,
            holdingPeriod: "short", sourceCountry: country, fx: [], lotDisposalID: UUID()
        )
    }

    private static func dividend(symbol: String = "AAPL", gross: String, withholding: String, country: String? = "US") throws -> FilingDividend {
        let grossValue = try #require(Decimal(string: gross))
        return try FilingDividend(
            symbol: symbol, payDate: day("2025-06-13"), sourceCountry: country,
            gross: grossValue, withholding: #require(Decimal(string: withholding)), net: grossValue - #require(Decimal(string: withholding)),
            fx: FXConversion(amount: grossValue, rate: 1, fixingDate: day("2025-06-13"), sourceCurrency: "EUR"),
            dividendID: UUID()
        )
    }

    private static func ledger(
        disposals: [FilingDisposal] = [],
        dividends: [FilingDividend] = [],
        unsupported: [FilingUnsupportedRow] = [],
        germany: GermanyFilingSupplement? = nil
    ) -> FilingLedger {
        FilingLedger(taxYear: 2025, reportingCurrency: "EUR", jurisdiction: .germany, disposals: disposals, dividends: dividends, unsupported: unsupported, germany: germany)
    }

    private static func row(_ pack: FilingPack, section: String, line: String) -> [String]? {
        pack.sections.first { $0.id == section }?.rows.first { $0.first == line }
    }

    @Test("A share gain lands in Zeile 19 and 20 with one Einzelnachweis row")
    func shareGain() throws {
        let pack = GermanyAnlageKAPMapper().map(Self.ledger(disposals: [Self.disposal()]))
        #expect(pack.formName == "ESt 1 A — Anlage KAP / KAP-INV")
        #expect(pack.rulePackVersion == "DE-2026.1")
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapSectionID, line: "19")?[2] == "300.00")
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapSectionID, line: "20")?[2] == "300.00")
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapSectionID, line: "22")?[2] == "0.00")
        let detail = try #require(pack.sections.first { $0.id == GermanyAnlageKAPMapper.disposalsSectionID })
        #expect(detail.rows == [["SAP", "DE0007164600", "2025-09-10", "2025-02-03", "1300.00", "1000.00", "2.00", "300.00"]])
        #expect(pack.summary["totalGain"] == 300)
        #expect(pack.summary["stockGains"] == 300)
    }

    @Test("A share loss reduces Zeile 19 and is broken out as a positive figure in Zeile 22")
    func shareLoss() throws {
        let loss = try Self.disposal(symbol: "BAYN", realization: #require(Decimal(string: "700.00")))
        let pack = GermanyAnlageKAPMapper().map(Self.ledger(disposals: [Self.disposal(), loss]))
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapSectionID, line: "19")?[2] == "0.00")
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapSectionID, line: "20")?[2] == "300.00")
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapSectionID, line: "22")?[2] == "300.00")
        let losses = try #require(pack.sections.first { $0.id == GermanyAnlageKAPMapper.lossSectionID })
        #expect(losses.rows.first == ["Aktienverluste 2025 (Zeile 22)", "300.00"])
        #expect(pack.summary["totalGain"] == 0)
    }

    @Test("A US dividend adds its gross to Zeile 19 and credits withholding capped at 15 % in Zeile 41")
    func dividendCredit() throws {
        // 30 % withheld at source; only the treaty 15 % is creditable.
        let pack = try GermanyAnlageKAPMapper().map(Self.ledger(dividends: [Self.dividend(gross: "100.00", withholding: "30.00")]))
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapSectionID, line: "19")?[2] == "100.00")
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapSectionID, line: "41")?[2] == "15.00")
        let detail = try #require(pack.sections.first { $0.id == GermanyAnlageKAPMapper.dividendsSectionID })
        #expect(detail.rows == [["AAPL", "US", "2025-06-13", "KAP Zeile 19", "100.00", "30.00", "15.00"]])
        #expect(pack.summary["creditableForeignTax"] == 15)
        #expect(pack.summary["totalWithholding"] == 30)
    }

    @Test("A classified equity ETF goes to KAP-INV before Teilfreistellung and never to Anlage KAP")
    func equityFund() throws {
        let supplement = GermanyFilingSupplement(
            fundClassifications: ["VWCE": .equity], advanceLumpSums: [],
            priorStockLossCarryforward: nil, priorGeneralLossCarryforward: nil
        )
        let etf = Self.disposal(symbol: "VWCE", type: "etf", isin: "IE00BK5BQT80", country: "IE")
        let distribution = try Self.dividend(symbol: "VWCE", gross: "40.00", withholding: "0.00", country: "IE")
        let pack = GermanyAnlageKAPMapper().map(Self.ledger(disposals: [etf], dividends: [distribution], germany: supplement))
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapSectionID, line: "19")?[2] == "0.00")
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapInvSectionID, line: "4")?[2] == "40.00")
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapInvSectionID, line: "14")?[2] == "300.00")
        let fundDetail = try #require(pack.sections.first { $0.id == GermanyAnlageKAPMapper.fundDisposalsSectionID })
        #expect(fundDetail.rows.count == 1)
        #expect(fundDetail.rows[0][2] == "Aktienfonds")
        #expect(pack.sections.first { $0.id == GermanyAnlageKAPMapper.disposalsSectionID }?.rows.isEmpty == true)
        #expect(pack.summary["fundResult"] == 300)
        let counts = FilingCountryMappers.counts(of: pack)
        #expect(counts.disposals == 1)
        #expect(counts.dividends == 1)
    }

    @Test("A fund without an InvStG classification is routed to the manual section")
    func unclassifiedFund() throws {
        let supplement = GermanyFilingSupplement(fundClassifications: ["XYZ": .unknown], advanceLumpSums: [], priorStockLossCarryforward: nil, priorGeneralLossCarryforward: nil)
        let pack = GermanyAnlageKAPMapper().map(Self.ledger(disposals: [Self.disposal(symbol: "XYZ", type: "etf")], germany: supplement))
        let manual = try #require(pack.sections.first { $0.id == GermanyAnlageKAPMapper.unsupportedSectionID })
        #expect(manual.rows.count == 1)
        #expect(manual.rows[0][0] == "XYZ")
        #expect(pack.sections.first { $0.id == GermanyAnlageKAPMapper.kapInvSectionID }?.rows.isEmpty == true)
        #expect(FilingCountryMappers.counts(of: pack).unsupported == 1)
    }

    @Test("Vorabpauschalen are summed per fund type into Zeile 9–13")
    func advanceLumpSums() throws {
        let supplement = try GermanyFilingSupplement(
            fundClassifications: [:],
            advanceLumpSums: [
                GermanyFilingAdvanceLumpSum(symbol: "VWCE", classification: .equity, gross: #require(Decimal(string: "12.34"))),
                GermanyFilingAdvanceLumpSum(symbol: "EUNL", classification: .equity, gross: #require(Decimal(string: "7.66"))),
                GermanyFilingAdvanceLumpSum(symbol: "MIX", classification: .mixed, gross: 5),
            ],
            priorStockLossCarryforward: nil, priorGeneralLossCarryforward: nil
        )
        let pack = GermanyAnlageKAPMapper().map(Self.ledger(germany: supplement))
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapInvSectionID, line: "9")?[2] == "20.00")
        #expect(Self.row(pack, section: GermanyAnlageKAPMapper.kapInvSectionID, line: "10")?[2] == "5.00")
        #expect(pack.summary["advanceLumpSums"] == 25)
    }

    @Test("Prior-year carry-forwards appear in the informational loss section")
    func carryforwards() throws {
        let supplement = try GermanyFilingSupplement(fundClassifications: [:], advanceLumpSums: [], priorStockLossCarryforward: 250, priorGeneralLossCarryforward: #require(Decimal(string: "80.50")))
        let pack = GermanyAnlageKAPMapper().map(Self.ledger(germany: supplement))
        let losses = try #require(pack.sections.first { $0.id == GermanyAnlageKAPMapper.lossSectionID })
        #expect(losses.rows.contains(["Verlustvortrag Aktien aus 2024", "250.00"]))
        #expect(losses.rows.contains(["Verlustvortrag sonstige Kapitalerträge aus 2024", "80.50"]))
    }

    @Test("An option disposal is listed for manual review with the rule pack named")
    func optionManual() throws {
        let pack = GermanyAnlageKAPMapper().map(Self.ledger(disposals: [Self.disposal(type: "option")]))
        let manual = try #require(pack.sections.first { $0.id == GermanyAnlageKAPMapper.unsupportedSectionID })
        #expect(manual.rows == [["SAP", "Instrumententyp option wird von DE-2026.1 nicht abgedeckt", "300.00"]])
    }

    @Test("The registry now resolves a mapper for Germany")
    func registry() {
        #expect(FilingCountryMappers.mapper(for: .germany)?.jurisdiction == .germany)
        #expect(FilingCountryMappers.mapper(for: .france) == nil)
    }
}
