import Foundation
@testable import StockPlanBackend
import Testing

/// Parser-level tests. No database, no app boot -- these run in milliseconds and
/// are where the awkward real-world cases belong.
///
/// Fixtures are real files from two different writers, because they disagree in
/// ways that matter: XlsxWriter emits shared strings and cached formula results
/// like Excel does, openpyxl emits inline strings and no cached results at all.
/// Regenerate them with the scripts alongside.
@Suite("Spreadsheet reader")
struct SpreadsheetReaderTests {
    private let reader = CoreXLSXSpreadsheetReader()

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Spreadsheets/\(name)")
        return try Data(contentsOf: url)
    }

    private func isoString(_ date: Date) -> String {
        SpreadsheetStructureDetector.isoDateFormatter().string(from: date)
    }

    // MARK: - Reading

    @Test("reads a multi-sheet workbook whose data starts away from A1")
    func readsMessyWorkbook() throws {
        let workbook = try reader.read(fixture("messy.xlsx"), limits: .default)

        #expect(workbook.sheets.count == 3)
        #expect(workbook.sheets.map(\.name) == ["Gastos 2026", "Resumo", "2025 (antigo)"])

        let sheet = try #require(workbook.sheets.first)
        // Header sits on row 5, data begins at column G.
        #expect(sheet.cell(row: 4, column: 6) == .text("Data"))
        #expect(sheet.cell(row: 4, column: 7) == .text("Descrição"))
        // Blank cells before the data region stay addressable.
        #expect(sheet.cell(row: 5, column: 0) == .empty)
        #expect(sheet.cell(row: 5, column: 7) == .text("Continente"))
        #expect(sheet.cell(row: 5, column: 9) == .number(84.2))
    }

    @Test("date-formatted serials become dates, plain numbers stay numbers")
    func distinguishesDatesFromNumbers() throws {
        let workbook = try reader.read(fixture("messy.xlsx"), limits: .default)
        let sheet = try #require(workbook.sheets.first)

        guard case let .date(occurredOn) = sheet.cell(row: 5, column: 6) else {
            Issue.record("expected G6 to be a date, got \(sheet.cell(row: 5, column: 6))")
            return
        }
        #expect(isoString(occurredOn) == "2026-01-03")

        // Same magnitude, no date format -- must not be mistaken for a date.
        #expect(sheet.cell(row: 5, column: 9) == .number(84.2))
    }

    /// The whole file's dates shift by 1 462 days if the 1904 flag is ignored,
    /// and CoreXLSX exposes no accessor for it, so this guards our own reader.
    @Test("1904-system workbooks resolve to the same calendar dates as 1900")
    func handlesBothDateSystems() throws {
        let epoch1900 = try reader.read(fixture("excel-like.xlsx"), limits: .default)
        let epoch1904 = try reader.read(fixture("excel-like-1904.xlsx"), limits: .default)

        #expect(epoch1900.usesDate1904 == false)
        #expect(epoch1904.usesDate1904 == true)

        func firstDate(_ workbook: SpreadsheetWorkbook) throws -> String {
            let sheet = try #require(workbook.sheets.first)
            guard case let .date(value) = sheet.cell(row: 4, column: 3) else {
                Issue.record("expected D5 to be a date, got \(sheet.cell(row: 4, column: 3))")
                return ""
            }
            return isoString(value)
        }

        #expect(try firstDate(epoch1900) == "2026-01-03")
        #expect(try firstDate(epoch1904) == "2026-01-03")
    }

    @Test("shared strings resolve and cached formula results are read")
    func readsSharedStringsAndCachedFormulas() throws {
        let workbook = try reader.read(fixture("excel-like.xlsx"), limits: .default)
        let sheet = try #require(workbook.sheets.first)

        #expect(sheet.cell(row: 4, column: 4) == .text("Continente"))
        // =SUM(G5:G9), cached as 954.59. We read the cache, never evaluate.
        #expect(sheet.cell(row: 9, column: 6) == .number(954.59))
        #expect(sheet.rowsWithUncachedFormulas.isEmpty)
    }

    /// Anything not written by Excel tends to omit cached results. Importing a
    /// silent zero there would be worse than importing nothing.
    @Test("formulas with no cached result read as empty and warn")
    func flagsUncachedFormulas() throws {
        let workbook = try reader.read(fixture("no-cached-formula.xlsx"), limits: .default)
        let sheet = try #require(workbook.sheets.first)

        #expect(sheet.cell(row: 2, column: 2) == .empty)
        #expect(sheet.rowsWithUncachedFormulas == [3])
        #expect(workbook.warnings.contains { $0.contains("no saved result") })
    }

    @Test("float noise is rounded out of numeric cells")
    func roundsFloatNoise() throws {
        let workbook = try reader.read(fixture("messy.xlsx"), limits: .default)
        let sheet = try #require(workbook.sheets[2])
        // Stored as 9.300000000000001.
        #expect(sheet.cell(row: 1, column: 2) == .number(9.3))
    }

    // MARK: - Format gate

    @Test("legacy .xls is rejected with a message that tells the user what to do")
    func rejectsLegacyBinary() throws {
        let ole2 = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 64))
        #expect(throws: SpreadsheetReadError.legacyBinaryFormat) {
            try reader.read(ole2, limits: .default)
        }
    }

    @Test("non-spreadsheet input is rejected")
    func rejectsGarbage() throws {
        #expect(throws: SpreadsheetReadError.notASpreadsheet) {
            try reader.read(Data("this is not a spreadsheet, it is prose".utf8), limits: .default)
        }
    }

    @Test("oversized uploads are rejected before parsing")
    func rejectsOversizeUploads() throws {
        var limits = SpreadsheetLimits.default
        limits.maxBytes = 128
        #expect(throws: (any Error).self) {
            try reader.read(fixture("messy.xlsx"), limits: limits)
        }
    }

    @Test("a sheet over the row cap is rejected, naming the sheet")
    func rejectsTooManyRows() throws {
        var limits = SpreadsheetLimits.default
        limits.maxRowsPerSheet = 3
        #expect(throws: SpreadsheetReadError.tooManyRows(sheet: "Gastos 2026", rows: 12, limit: 3)) {
            try reader.read(fixture("messy.xlsx"), limits: limits)
        }
    }

    // MARK: - Column letters

    @Test("column letters round trip past Z")
    func columnLetterRoundTrip() {
        for (letters, index) in [("A", 1), ("G", 7), ("Z", 26), ("AA", 27), ("AZ", 52), ("BA", 53)] {
            #expect(CoreXLSXSpreadsheetReader.columnIndex(of: letters) == index)
            #expect(CoreXLSXSpreadsheetReader.columnLetters(for: index) == letters)
        }
    }
}
