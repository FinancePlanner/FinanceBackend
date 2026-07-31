import Foundation

// Value types the rest of the importer works in.
//
// Deliberately independent of any parsing library: CoreXLSX's types are not
// `Sendable` and must never cross an `await`, and keeping the boundary here
// means swapping the reader (for a hand-rolled OOXML parser, say) touches one
// file instead of the whole feature.

/// What a column is understood to hold.
///
/// Internal on purpose. The wire enum (`SpreadsheetImportField` in
/// norviq-shared) is a separate type so the parser and detector can be built
/// and tested without waiting on a shared-package release; the two are mapped
/// at the API boundary, which is also where an unrecognised wire value gets
/// handled.
enum SpreadsheetColumnRole: String, Sendable, Equatable, CaseIterable {
    case title
    case amount
    case date
    case category
    case pillar
    case notes
    case currency
    case externalId
    case ignore
}

/// A single cell, already resolved — shared strings looked up, formulas reduced
/// to their cached result, date-formatted serials converted.
enum SpreadsheetCell: Sendable, Equatable {
    case empty
    case text(String)
    case number(Double)
    case date(Date)
    case boolean(Bool)

    /// Whether the cell holds nothing worth reading. Cells that held a formula
    /// with no cached result arrive as `.empty`.
    var isEmpty: Bool {
        switch self {
        case .empty: true
        case let .text(value): value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }

    /// Display form, used for AI samples and for text-date parsing.
    func displayText(dateFormatter: DateFormatter) -> String {
        switch self {
        case .empty: ""
        case let .text(value): value
        case let .number(value): Self.formatNumber(value)
        case let .date(value): dateFormatter.string(from: value)
        case let .boolean(value): value ? "TRUE" : "FALSE"
        }
    }

    /// Trims the float noise xlsx stores (84.2 round-trips as 84.200000000000003).
    private static func formatNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%g", value)
    }
}

/// One worksheet as a dense grid. `rows[r][c]` is 0-based; row 1 in Excel is
/// `rows[0]`. Gaps in a sparse sheet are filled with `.empty` so column indexes
/// stay meaningful across rows.
struct SpreadsheetSheet: Sendable {
    let name: String
    /// 0-based position in the workbook.
    let index: Int
    let rows: [[SpreadsheetCell]]
    /// Rows whose only content was a formula with no cached result, 1-based.
    let rowsWithUncachedFormulas: [Int]

    var rowCount: Int {
        rows.count
    }

    var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }

    func cell(row: Int, column: Int) -> SpreadsheetCell {
        guard row >= 0, row < rows.count, column >= 0, column < rows[row].count else {
            return .empty
        }
        return rows[row][column]
    }
}

struct SpreadsheetWorkbook: Sendable {
    let sheets: [SpreadsheetSheet]
    /// True when the file uses the 1904 date system. Already applied to every
    /// `.date` cell; retained for diagnostics.
    let usesDate1904: Bool
    /// Workbook-level notes for the review screen, e.g. formula cells with no
    /// saved result, or a sheet dropped for exceeding the row cap.
    let warnings: [String]
}

/// Caps applied while reading. Set from measured parse cost: CoreXLSX is
/// superlinear in row count (~0.3s at 2 000 rows, ~6s at 5 000), and analyze
/// also pays for an AI round trip, so the sheet cap is what keeps the request
/// inside a sane budget.
struct SpreadsheetLimits: Sendable {
    var maxBytes: Int = 8 * 1024 * 1024
    var maxInflatedBytes: Int = 64 * 1024 * 1024
    var maxSheets: Int = 12
    var maxRowsPerSheet: Int = 2000
    var maxColumns: Int = 64

    static let `default` = SpreadsheetLimits()
}

/// Failures that map onto a specific HTTP status and a message we are willing
/// to show the user verbatim.
enum SpreadsheetReadError: Error, Equatable {
    /// Old binary .xls (BIFF). Not a zip, cannot be salvaged.
    case legacyBinaryFormat
    case passwordProtected
    case notASpreadsheet
    case tooLarge(bytes: Int, limit: Int)
    case tooManyRows(sheet: String, rows: Int, limit: Int)
    case noReadableSheets

    var reason: String {
        switch self {
        case .legacyBinaryFormat:
            "That's an older .xls file. Open it in Excel and save it as .xlsx, then try again."
        case .passwordProtected:
            "That file is password-protected. Remove the password and try again."
        case .notASpreadsheet:
            "We couldn't read that file. Make sure it's a valid .xlsx spreadsheet."
        case let .tooLarge(_, limit):
            "Spreadsheet must be \(limit / (1024 * 1024)) MB or smaller."
        case let .tooManyRows(sheet, _, limit):
            "Sheet \"\(sheet)\" has more than \(limit) rows. Split it and try again."
        case .noReadableSheets:
            "We couldn't find any readable sheets in that file."
        }
    }
}

protocol SpreadsheetReader: Sendable {
    func read(_ data: Data, limits: SpreadsheetLimits) throws -> SpreadsheetWorkbook
}
