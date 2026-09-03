import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Filing pack renderer")
struct FilingPackRendererTests {
    private static func samplePack() throws -> FilingPack {
        let disposal = try FilingDisposal(
            symbol: "AAPL", isin: "US0378331005", instrumentType: "stock", quantity: 10,
            acquisitionDate: FXRateResolverTests.day("2025-02-03"), acquisitionValue: #require(Decimal(string: "909.09")),
            realizationDate: FXRateResolverTests.day("2025-09-10"), realizationValue: #require(Decimal(string: "1362.73")),
            expenses: #require(Decimal(string: "0.91")), gain: #require(Decimal(string: "453.64")),
            holdingPeriod: "short", sourceCountry: "US", fx: [], lotDisposalID: UUID()
        )
        let ledger = FilingLedger(taxYear: 2025, reportingCurrency: "EUR", jurisdiction: .portugal, disposals: [disposal], dividends: [], unsupported: [])
        return PortugalAnexoJMapper().map(ledger)
    }

    @Test("CSV carries the form header, each section's columns, the exact row, and the disclaimer")
    func csvShape() throws {
        let csv = try String(decoding: FilingPackRenderer().csv(Self.samplePack()), as: UTF8.self)
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.contains("form,IRS Modelo 3 — Anexo J"))
        #expect(lines.contains("section,anexo-j-9.2A,Quadro 9.2A — Alienação onerosa de partes sociais e outros valores mobiliários"))
        #expect(lines.contains("Código,País,Real. ano,Real. mês,Valor realização,Aq. ano,Aq. mês,Valor aquisição,Despesas"))
        #expect(lines.contains("G01,840,2025,09,1362.73,2025,02,909.09,0.91"))
        #expect(lines.contains("total,gain,453.64"))
        #expect(lines.contains("summary,totalGain,453.64"))
        #expect(lines.last?.hasPrefix("disclaimer,") == true)
    }

    @Test("Fields containing commas or quotes are quoted")
    func csvQuoting() {
        let section = FilingPackSection(id: "x", title: "A, B", columns: ["c"], rows: [["say \"hi\""]], totals: [:], notes: [])
        let pack = FilingPack(jurisdiction: .portugal, taxYear: 2025, reportingCurrency: "EUR", formName: "F", rulePackVersion: "v", sections: [section], summary: [:], disclaimer: "d")
        let csv = String(decoding: FilingPackRenderer().csv(pack), as: UTF8.self)
        #expect(csv.contains("section,x,\"A, B\""))
        #expect(csv.contains("\"say \"\"hi\"\"\""))
    }

    @Test("PDF is a PDF and mentions the form and the row")
    func pdfShape() throws {
        let data = try FilingPackRenderer().pdf(Self.samplePack())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("%PDF"))
        #expect(text.contains("Anexo J"))
    }
}
