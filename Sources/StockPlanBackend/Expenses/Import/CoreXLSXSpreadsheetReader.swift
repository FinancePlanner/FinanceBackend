import CoreXLSX
import Foundation
import ZIPFoundation

/// Reads .xlsx into the importer's own value types.
///
/// Everything CoreXLSX touches stays inside `read(_:limits:)`. Its types are
/// not `Sendable` and must not escape into the async importer; keeping them
/// local is also what makes the reader swappable.
struct CoreXLSXSpreadsheetReader: SpreadsheetReader {
    /// Days between the 1904 and 1900 epochs.
    private static let date1904Offset: Double = 1462
    private static let secondsPerDay: Double = 86400

    func read(_ data: Data, limits: SpreadsheetLimits) throws -> SpreadsheetWorkbook {
        guard data.count <= limits.maxBytes else {
            throw SpreadsheetReadError.tooLarge(bytes: data.count, limit: limits.maxBytes)
        }
        try Self.validateFormat(data)

        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw SpreadsheetReadError.notASpreadsheet
        }
        if OOXMLPartReader.containsEncryptedPackage(archive) {
            throw SpreadsheetReadError.passwordProtected
        }
        let inflated = OOXMLPartReader.declaredUncompressedSize(of: archive)
        guard inflated <= limits.maxInflatedBytes else {
            throw SpreadsheetReadError.tooLarge(bytes: inflated, limit: limits.maxInflatedBytes)
        }

        let usesDate1904 = OOXMLPartReader.usesDate1904(in: archive)
        let dateStyles = OOXMLPartReader.dateStyleIndexes(in: archive)

        let file: XLSXFile
        do {
            file = try XLSXFile(data: data)
        } catch {
            throw SpreadsheetReadError.notASpreadsheet
        }

        let sharedStrings = try? file.parseSharedStrings()

        guard let workbook = try? file.parseWorkbooks().first,
              let sheetPaths = try? file.parseWorksheetPathsAndNames(workbook: workbook),
              !sheetPaths.isEmpty
        else {
            throw SpreadsheetReadError.noReadableSheets
        }

        var warnings: [String] = []
        if dateStyles.isEmpty {
            warnings.append(
                "We couldn't read this file's cell formats, so date columns may show as numbers. Check the date column before importing."
            )
        }
        if sheetPaths.count > limits.maxSheets {
            warnings.append(
                "Only the first \(limits.maxSheets) of \(sheetPaths.count) sheets were read."
            )
        }

        var sheets: [SpreadsheetSheet] = []
        for (index, entry) in sheetPaths.prefix(limits.maxSheets).enumerated() {
            guard let worksheet = try? file.parseWorksheet(at: entry.path) else {
                warnings.append("Sheet \"\(entry.name ?? "#\(index + 1)")\" couldn't be read and was skipped.")
                continue
            }
            let name = entry.name ?? "Sheet \(index + 1)"
            let rowCount = worksheet.data?.rows.count ?? 0
            guard rowCount <= limits.maxRowsPerSheet else {
                throw SpreadsheetReadError.tooManyRows(
                    sheet: name, rows: rowCount, limit: limits.maxRowsPerSheet
                )
            }
            sheets.append(
                Self.makeSheet(
                    worksheet: worksheet,
                    name: name,
                    index: index,
                    sharedStrings: sharedStrings,
                    dateStyles: dateStyles,
                    usesDate1904: usesDate1904,
                    limits: limits
                )
            )
        }

        guard !sheets.isEmpty else { throw SpreadsheetReadError.noReadableSheets }

        let uncachedTotal = sheets.reduce(0) { $0 + $1.rowsWithUncachedFormulas.count }
        if uncachedTotal > 0 {
            // Files written by tools other than Excel routinely omit cached
            // results. We never evaluate formulas, so those cells read as blank
            // -- say so rather than importing a silent zero.
            warnings.append(
                "\(uncachedTotal) row\(uncachedTotal == 1 ? "" : "s") contain formulas with no saved result. Open the file in Excel, save it again, and re-upload to include them."
            )
        }

        return SpreadsheetWorkbook(sheets: sheets, usesDate1904: usesDate1904, warnings: warnings)
    }

    // MARK: - Format gate

    /// Sniffs magic bytes rather than trusting the extension, so a renamed .xls
    /// gets a useful message instead of a parse failure.
    static func validateFormat(_ data: Data) throws {
        let prefix = [UInt8](data.prefix(8))
        guard prefix.count >= 4 else { throw SpreadsheetReadError.notASpreadsheet }

        // OLE2 compound document: legacy .xls, and also the container used by
        // password-protected OOXML files.
        if prefix.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) {
            throw SpreadsheetReadError.legacyBinaryFormat
        }
        guard prefix.starts(with: [0x50, 0x4B, 0x03, 0x04])
            || prefix.starts(with: [0x50, 0x4B, 0x05, 0x06])
            || prefix.starts(with: [0x50, 0x4B, 0x07, 0x08])
        else {
            throw SpreadsheetReadError.notASpreadsheet
        }
    }

    // MARK: - Sheet construction

    private static func makeSheet(
        worksheet: Worksheet,
        name: String,
        index: Int,
        sharedStrings: SharedStrings?,
        dateStyles: [Int: Bool],
        usesDate1904: Bool,
        limits: SpreadsheetLimits
    ) -> SpreadsheetSheet {
        let sourceRows = worksheet.data?.rows ?? []
        var grid: [[SpreadsheetCell]] = []
        var uncachedFormulaRows: [Int] = []

        // Rows are addressed by their real worksheet row number so a blank
        // separator row doesn't shift everything below it. The declared
        // <dimension> is ignored on purpose: it is writer-supplied and a hostile
        // file can claim A1:XFD1048576.
        let highestRow = sourceRows.map { Int($0.reference) }.max() ?? 0
        let rowCap = min(highestRow, limits.maxRowsPerSheet)
        guard rowCap > 0 else {
            return SpreadsheetSheet(name: name, index: index, rows: [], rowsWithUncachedFormulas: [])
        }

        var cellsByRow: [Int: [CoreXLSX.Cell]] = [:]
        for row in sourceRows {
            cellsByRow[Int(row.reference)] = row.cells
        }

        for rowNumber in 1 ... rowCap {
            let cells = cellsByRow[rowNumber] ?? []
            var line = [SpreadsheetCell](repeating: .empty, count: 0)
            var sawUncachedFormula = false

            for cell in cells {
                let columnIndex = columnIndex(of: cell.reference.column.value)
                guard columnIndex >= 1, columnIndex <= limits.maxColumns else { continue }
                if line.count < columnIndex {
                    line.append(contentsOf: [SpreadsheetCell](repeating: .empty, count: columnIndex - line.count))
                }
                let resolved = resolve(
                    cell: cell,
                    sharedStrings: sharedStrings,
                    dateStyles: dateStyles,
                    usesDate1904: usesDate1904
                )
                line[columnIndex - 1] = resolved.cell
                sawUncachedFormula = sawUncachedFormula || resolved.formulaWithoutCache
            }

            grid.append(line)
            if sawUncachedFormula {
                uncachedFormulaRows.append(rowNumber)
            }
        }

        return SpreadsheetSheet(
            name: name,
            index: index,
            rows: grid,
            rowsWithUncachedFormulas: uncachedFormulaRows
        )
    }

    private static func resolve(
        cell: CoreXLSX.Cell,
        sharedStrings: SharedStrings?,
        dateStyles: [Int: Bool],
        usesDate1904: Bool
    ) -> (cell: SpreadsheetCell, formulaWithoutCache: Bool) {
        let rawValue = cell.value ?? ""

        // Formulas are read from their cached result and never evaluated. No
        // cached result means we genuinely do not know the value; blank is the
        // honest answer, and the caller surfaces it as a warning.
        if cell.formula != nil, rawValue.isEmpty {
            return (.empty, true)
        }

        switch cell.type {
        case .sharedString:
            guard let sharedStrings, let text = cell.stringValue(sharedStrings) else {
                return (.empty, false)
            }
            return (text.isEmpty ? .empty : .text(text), false)
        case .inlineStr:
            let text = cell.inlineString?.text ?? rawValue
            return (text.isEmpty ? .empty : .text(text), false)
        case .bool:
            return (.boolean(rawValue == "1" || rawValue.lowercased() == "true"), false)
        case .error:
            return (.empty, false)
        case .date:
            // Rare: an ISO date written directly rather than as a serial.
            if let parsed = isoDate(from: rawValue) {
                return (.date(parsed), false)
            }
            return (rawValue.isEmpty ? .empty : .text(rawValue), false)
        default:
            break
        }

        if let inline = cell.inlineString?.text, !inline.isEmpty {
            return (.text(inline), false)
        }
        guard !rawValue.isEmpty else { return (.empty, false) }
        guard let number = Double(rawValue) else {
            return (.text(rawValue), false)
        }
        if let styleIndex = cell.styleIndex, dateStyles[styleIndex] == true {
            return (.date(date(fromSerial: number, usesDate1904: usesDate1904)), false)
        }
        // xlsx round-trips 84.2 as 84.200000000000003; carrying that into an
        // amount would show up as a cent of drift in the preview totals.
        return (.number((number * 1_000_000).rounded() / 1_000_000), false)
    }

    // MARK: - Dates

    /// Converts an Excel serial to a UTC instant.
    ///
    /// CoreXLSX's own `Cell.dateValue` anchors on `TimeZone.autoupdatingCurrent`,
    /// so it yields a different calendar day depending on where the process
    /// runs. Expenses are filed by calendar date, so that has to be UTC-fixed.
    static func date(fromSerial serial: Double, usesDate1904: Bool) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = 1899
        components.month = 12
        components.day = 30
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let epoch = calendar.date(from: components) ?? Date(timeIntervalSince1970: -2_209_161_600)
        let days = usesDate1904 ? serial + date1904Offset : serial
        return epoch.addingTimeInterval(days * secondsPerDay)
    }

    private static func isoDate(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: value)
    }

    // MARK: - Columns

    /// "A" -> 1, "AA" -> 27. CoreXLSX keeps `ColumnReference.intValue` internal,
    /// so the conversion lives here.
    static func columnIndex(of letters: String) -> Int {
        letters.uppercased().unicodeScalars.reduce(0) { total, scalar in
            guard scalar.value >= 65, scalar.value <= 90 else { return total }
            return total * 26 + Int(scalar.value) - 64
        }
    }

    static func columnLetters(for index: Int) -> String {
        guard index > 0 else { return "" }
        var remaining = index
        var letters = ""
        while remaining > 0 {
            let offset = (remaining - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + offset))) + letters
            remaining = (remaining - 1) / 26
        }
        return letters
    }
}
