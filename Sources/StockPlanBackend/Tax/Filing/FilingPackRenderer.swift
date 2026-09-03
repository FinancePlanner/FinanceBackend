import Foundation
import StockPlanShared

/// Turns a `FilingPack` into the two artefacts the report queue stores:
/// a CSV with one block per section (header row, data rows, totals) and a
/// text PDF built with the same minimal PDF writer the other tax reports
/// use. A laid-out PDF is a later polish; the CSV is what gets typed into
/// the form, so it is the one that has to be exact.
struct FilingPackRenderer: Sendable {
    func csv(_ pack: FilingPack) -> Data {
        var lines: [String] = []
        lines.append(csvRow(["form", pack.formName]))
        lines.append(csvRow(["jurisdiction", pack.jurisdiction.rawValue]))
        lines.append(csvRow(["tax_year", String(pack.taxYear)]))
        lines.append(csvRow(["reporting_currency", pack.reportingCurrency]))
        lines.append(csvRow(["rule_pack", pack.rulePackVersion]))
        lines.append("")
        for section in pack.sections {
            lines.append(csvRow(["section", section.id, section.title]))
            lines.append(csvRow(section.columns))
            for row in section.rows {
                lines.append(csvRow(row))
            }
            for (key, value) in section.totals.sorted(by: { $0.key < $1.key }) {
                lines.append(csvRow(["total", key, FilingFormat.money(value)]))
            }
            for note in section.notes {
                lines.append(csvRow(["note", note]))
            }
            lines.append("")
        }
        for (key, value) in pack.summary.sorted(by: { $0.key < $1.key }) {
            lines.append(csvRow(["summary", key, FilingFormat.money(value)]))
        }
        lines.append(csvRow(["disclaimer", pack.disclaimer]))
        return Data(lines.joined(separator: "\n").utf8)
    }

    func pdf(_ pack: FilingPack) -> Data {
        var lines: [String] = []
        lines.append("Norviq — \(pack.formName) — \(pack.taxYear)")
        lines.append("Jurisdiction \(pack.jurisdiction.rawValue) · \(pack.reportingCurrency) · rule pack \(pack.rulePackVersion)")
        lines.append("")
        for section in pack.sections {
            lines.append(section.title)
            lines.append(section.columns.joined(separator: " | "))
            if section.rows.isEmpty {
                lines.append("(no rows)")
            }
            for row in section.rows {
                lines.append(row.joined(separator: " | "))
            }
            for (key, value) in section.totals.sorted(by: { $0.key < $1.key }) {
                lines.append("Total \(key): \(FilingFormat.money(value))")
            }
            for note in section.notes {
                lines.append("Note: \(note)")
            }
            lines.append("")
        }
        for (key, value) in pack.summary.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(FilingFormat.money(value))")
        }
        lines.append("")
        lines.append(pack.disclaimer)
        return MinimalPDF.make(lines: lines)
    }

    private func csvRow(_ fields: [String]) -> String {
        fields.map { field in
            let needsQuotes = field.contains(",") || field.contains("\"") || field.contains("\n")
            guard needsQuotes else { return field }
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",")
    }
}
