import Foundation
@testable import StockPlanBackend
import Testing

/// The detector is what makes the import work with the AI switched off, and
/// what constrains the AI when it is on. All of it is mechanically checkable,
/// so all of it is tested without a model.
@Suite("Spreadsheet structure detector")
struct SpreadsheetStructureDetectorTests {
    private let reader = CoreXLSXSpreadsheetReader()

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Spreadsheets/\(name)")
        return try Data(contentsOf: url)
    }

    private func detect(_ file: String, sheet index: Int = 0) throws -> SpreadsheetStructureDetector.DetectedSheet {
        let workbook = try reader.read(fixture(file), limits: .default)
        return SpreadsheetStructureDetector.detect(sheet: workbook.sheets[index])
    }

    // MARK: - Region

    @Test("finds a header row that isn't row 1, past a title banner")
    func findsOffsetHeaderRow() throws {
        let detected = try detect("messy.xlsx")
        // Row 2 holds "Orçamento Pessoal" and row 3 a stray label; neither is a
        // header, because nothing type-consistent sits beneath them.
        #expect(detected.headerRow == 5)
        #expect(detected.dataStartRow == 6)
        #expect(detected.dataEndRow == 14)
    }

    @Test("finds data that starts away from column A")
    func findsOffsetColumns() throws {
        let detected = try detect("messy.xlsx")
        #expect(detected.firstColumn == 2) // B, the title banner
        #expect(detected.lastColumn == 12) // L, the derived column
        #expect(detected.notes.contains { $0.contains("row 5") })
    }

    @Test("handles a plain sheet with headers on row 1")
    func handlesCleanSheet() throws {
        let detected = try detect("messy.xlsx", sheet: 2)
        #expect(detected.headerRow == 1)
        #expect(detected.dataStartRow == 2)
        #expect(detected.firstColumn == 1)
    }

    // MARK: - Aggregate rows

    /// The single most damaging failure mode: a totals row imported as an
    /// expense inflates every figure in the app.
    @Test("excludes a labelled totals row")
    func excludesLabelledTotalRow() throws {
        let detected = try detect("messy.xlsx")
        #expect(detected.excludedRows.contains(14))
        #expect(detected.notes.contains { $0.lowercased().contains("totals") })
    }

    @Test("excludes an unlabelled row that equals the sum above it")
    func excludesArithmeticTotalRow() {
        // 10 + 20 + 30 = 60 on the fourth row, with no "total" label anywhere.
        let sheet = SpreadsheetSheet(
            name: "Sheet1",
            index: 0,
            rows: [
                [.text("date"), .text("item"), .text("amount")],
                [.text("2026-01-01"), .text("a"), .number(10)],
                [.text("2026-01-02"), .text("b"), .number(20)],
                [.text("2026-01-03"), .text("c"), .number(30)],
                [.empty, .empty, .number(60)],
            ],
            rowsWithUncachedFormulas: []
        )
        let detected = SpreadsheetStructureDetector.detect(sheet: sheet)
        #expect(detected.excludedRows.contains(5))
    }

    @Test("ordinary rows are not mistaken for totals")
    func doesNotOverFlagAggregates() {
        let sheet = SpreadsheetSheet(
            name: "Sheet1",
            index: 0,
            rows: [
                [.text("date"), .text("item"), .text("amount")],
                [.text("2026-01-01"), .text("a"), .number(10)],
                [.text("2026-01-02"), .text("b"), .number(20)],
                [.text("2026-01-03"), .text("c"), .number(35)],
            ],
            rowsWithUncachedFormulas: []
        )
        #expect(SpreadsheetStructureDetector.detect(sheet: sheet).excludedRows.isEmpty)
    }

    @Test("total labels are recognised across the languages users actually write in")
    func recognisesTotalLabels() {
        for label in ["TOTAL", "Total:", " subtotal ", "Soma", "Saldo", "Balance", "Gesamt"] {
            #expect(SpreadsheetStructureDetector.isAggregateLabel(label), "\(label) should be a total")
        }
        for label in ["Totally Awesome Cafe", "Continente", "Rent", ""] {
            #expect(!SpreadsheetStructureDetector.isAggregateLabel(label), "\(label) should not be a total")
        }
    }

    // MARK: - Column mapping

    @Test("maps date, description, category and amount columns")
    func mapsColumns() throws {
        let detected = try detect("messy.xlsx")
        func field(_ letter: String) -> SpreadsheetColumnRole? {
            detected.columns.first { $0.letter == letter }?.field
        }
        #expect(field("G") == .date)
        #expect(field("H") == .title)
        #expect(field("I") == .category)
        #expect(field("J") == .amount)
        #expect(field("K") == .notes)
    }

    /// "Valor" and "Valor c/ IVA" both read as amounts. Claiming both would
    /// double the import, so the weaker match is dropped.
    @Test("two amount-like columns resolve to one")
    func resolvesCompetingAmountColumns() throws {
        let detected = try detect("messy.xlsx")
        let amounts = detected.columns.filter { $0.field == .amount }
        #expect(amounts.count == 1)
        #expect(amounts.first?.letter == "J")
    }

    @Test("English headers map too")
    func mapsEnglishHeaders() throws {
        let detected = try detect("messy.xlsx", sheet: 2)
        func field(_ letter: String) -> SpreadsheetColumnRole? {
            detected.columns.first { $0.letter == letter }?.field
        }
        #expect(field("A") == .date)
        #expect(field("B") == .title)
        #expect(field("C") == .amount)
        #expect(field("D") == .pillar)
    }

    /// A header claiming "Date" over cells that aren't dates must not be trusted
    /// at full confidence -- the cells are checkable, the label is not.
    @Test("a header contradicted by its cells loses confidence")
    func headerContradictedByContentLosesConfidence() {
        let sheet = SpreadsheetSheet(
            name: "Sheet1",
            index: 0,
            rows: [
                [.text("Date"), .text("Amount")],
                [.text("not a date"), .number(10)],
                [.text("also not"), .number(20)],
                [.text("still not"), .number(30)],
            ],
            rowsWithUncachedFormulas: []
        )
        let detected = SpreadsheetStructureDetector.detect(sheet: sheet)
        let dateColumn = detected.columns.first { $0.letter == "A" }
        #expect(dateColumn?.confidence ?? 1 <= 0.4)
    }

    @Test("a sheet of expenses scores above a sheet of settings")
    func scoresExpenseSheetsHigher() throws {
        let workbook = try reader.read(fixture("messy.xlsx"), limits: .default)
        let expenses = SpreadsheetStructureDetector.detect(sheet: workbook.sheets[0])
        let summary = SpreadsheetStructureDetector.detect(sheet: workbook.sheets[1])
        #expect(expenses.score > summary.score)
    }

    // MARK: - Value sniffing

    @Test("amounts are recognised across separator and sign conventions")
    func sniffsAmounts() {
        #expect(SpreadsheetStructureDetector.looksLikeAmount("84,20 €")?.hadCurrencySymbol == true)
        #expect(SpreadsheetStructureDetector.looksLikeAmount("1.234,56")?.value == 1234.56)
        #expect(SpreadsheetStructureDetector.looksLikeAmount("1,234.56")?.value == 1234.56)
        // Accounting negatives.
        #expect(SpreadsheetStructureDetector.looksLikeAmount("(123.45)")?.value == -123.45)
        #expect(SpreadsheetStructureDetector.looksLikeAmount("") == nil)
        #expect(SpreadsheetStructureDetector.looksLikeAmount("Continente") == nil)
    }

    @Test("text dates are recognised in the common orders")
    func sniffsDates() {
        for value in ["2026-01-03", "03/04/2026", "3.4.2026", "12-11-2025", "3 April 2026"] {
            #expect(SpreadsheetStructureDetector.looksLikeDate(value), "\(value) should look like a date")
        }
        for value in ["Continente", "84.20", "", "2026"] {
            #expect(!SpreadsheetStructureDetector.looksLikeDate(value), "\(value) should not look like a date")
        }
    }

    /// Sampling only the top of a column hides format drift further down.
    @Test("samples are drawn from across the column, not just the top")
    func samplesSpanTheColumn() {
        let values = (1 ... 100).map(String.init)
        let sampled = SpreadsheetStructureDetector.sampled(values, limit: 20)
        #expect(sampled.count <= 20)
        #expect(sampled.first == "1")
        #expect(sampled.contains { (Int($0) ?? 0) > 50 })
    }
}
