import Foundation
import ZIPFoundation

/// Reads the two workbook parts CoreXLSX either can't give us or gets wrong.
///
/// This is not a preference for hand-rolled XML. Both are forced:
///
/// * **`xl/styles.xml`** — `XLSXFile.parseStyles()` throws
///   `keyNotFound … patternFill.patternType` on entirely valid files, because
///   CoreXLSX declares `PatternFill.patternType` non-optional while a bare
///   `<patternFill/>` is legal and common (openpyxl writes exactly that). It
///   threw on 3 of 5 real-world sample files. Styles are how a date serial is
///   told apart from a plain number, so falling back to "no styles" would
///   silently turn every date column into numbers.
/// * **`xl/workbook.xml`** — CoreXLSX's `Workbook` exposes no `workbookPr`, so
///   the 1904 date system is unreachable through its API. Ignoring it shifts
///   every date in a 1904 workbook by 1 462 days.
///
/// Only the handful of attributes the importer needs are read; this is not a
/// general-purpose OOXML parser.
enum OOXMLPartReader {
    /// numFmt ids Excel reserves for date and time formats.
    private static let builtInDateFormatIDs: Set<Int> = [14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47]

    /// True when the workbook counts days from 1904-01-01 instead of 1899-12-30.
    static func usesDate1904(in archive: Archive) -> Bool {
        guard let xml = text(of: "xl/workbook.xml", in: archive),
              let range = xml.range(of: "<workbookPr[^>]*>", options: .regularExpression)
        else { return false }
        return xml[range].range(of: "date1904=\"(1|true)\"", options: .regularExpression) != nil
    }

    /// Maps a cell's style index to whether its number format renders a date.
    ///
    /// Excel stores dates as plain numbers; the format is the only signal. A
    /// missing styles part yields an empty map, which degrades to treating
    /// serials as numbers — the caller reports that rather than guessing.
    static func dateStyleIndexes(in archive: Archive) -> [Int: Bool] {
        guard let xml = text(of: "xl/styles.xml", in: archive) else { return [:] }

        var customFormatCodes: [Int: String] = [:]
        for range in xml.ranges(ofPattern: "<numFmt [^>]*/?>") {
            let tag = String(xml[range])
            guard let id = tag.xmlAttribute("numFmtId").flatMap(Int.init),
                  let code = tag.xmlAttribute("formatCode")
            else { continue }
            customFormatCodes[id] = code.decodingXMLEntities()
        }

        // Only cellXfs maps a cell's style index; cellStyleXfs is a different
        // table and indexing into it would mislabel columns.
        guard let cellXfsRange = xml.range(
            of: "<cellXfs[^>]*>.*?</cellXfs>",
            options: [.regularExpression, .caseInsensitive]
        ) else { return [:] }
        let cellXfs = String(xml[cellXfsRange])

        var result: [Int: Bool] = [:]
        for (index, range) in cellXfs.ranges(ofPattern: "<xf [^>]*?/?>").enumerated() {
            let id = String(cellXfs[range]).xmlAttribute("numFmtId").flatMap(Int.init) ?? 0
            result[index] = isDateFormat(id: id, code: customFormatCodes[id])
        }
        return result
    }

    /// Total uncompressed size of the archive, for the zip-bomb guard. The
    /// declared sizes are attacker-controlled, which is the point: we reject on
    /// the claim before spending memory finding out whether it was honest.
    static func declaredUncompressedSize(of archive: Archive) -> Int {
        archive.reduce(0) { $0 + Int($1.uncompressedSize) }
    }

    static func containsEncryptedPackage(_ archive: Archive) -> Bool {
        archive.contains { $0.path.hasSuffix("EncryptedPackage") }
    }

    static func isDateFormat(id: Int, code: String?) -> Bool {
        if builtInDateFormatIDs.contains(id) {
            return true
        }
        guard let code, !code.isEmpty else { return false }
        // Quoted literals and [colour]/[condition] blocks can contain letters
        // that would otherwise read as date tokens -- `#,##0.00 "€"` is not a
        // date, but its 'e' would say so.
        let stripped = code.replacingOccurrences(
            of: "\"[^\"]*\"|\\[[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        guard !stripped.contains("General") else { return false }
        return stripped.range(of: "[ymdhs]", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func text(of path: String, in archive: Archive) -> String? {
        guard let entry = archive[path] else { return nil }
        var bytes = Data()
        do {
            _ = try archive.extract(entry) { bytes.append($0) }
        } catch {
            return nil
        }
        return String(data: bytes, encoding: .utf8)
    }
}

private extension String {
    func ranges(ofPattern pattern: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = startIndex
        while let found = range(of: pattern, options: .regularExpression, range: cursor ..< endIndex) {
            result.append(found)
            cursor = found.upperBound
        }
        return result
    }

    func xmlAttribute(_ name: String) -> String? {
        guard let range = range(of: "\(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
        let match = self[range]
        return String(match.dropFirst(name.count + 2).dropLast())
    }

    func decodingXMLEntities() -> String {
        replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
