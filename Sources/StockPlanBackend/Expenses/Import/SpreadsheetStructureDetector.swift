import Foundation

/// Works out where the data actually is in a worksheet, and what each column
/// probably means — with no AI involved.
///
/// This runs before the model and constrains it afterwards. Anything decided
/// here is mechanically checkable (does this column parse as dates? does this
/// row equal the sum of the rows above it?), so when a proposal disagrees with
/// the evidence, the evidence wins. It also means the whole import still works
/// with the AI disabled, just with weaker category mapping.
enum SpreadsheetStructureDetector {
    /// How many rows from the top to consider as a possible header.
    private static let headerSearchDepth = 25
    /// Rows inspected below a candidate header when scoring it.
    private static let headerConfirmationDepth = 5
    /// Tolerance when testing whether a row equals the sum of the rows above.
    private static let aggregateTolerance = 0.01

    struct DetectedColumn {
        let index: Int
        let letter: String
        let header: String?
        let kind: ColumnKind
        let samples: [String]
        let distinctCount: Int
        let field: SpreadsheetColumnRole
        let confidence: Double
    }

    enum ColumnKind: String {
        case date
        case number
        case currencyAmount
        case text
        case mostlyEmpty
    }

    struct DetectedSheet {
        let headerRow: Int?
        let dataStartRow: Int
        let dataEndRow: Int
        let firstColumn: Int
        let lastColumn: Int
        let columns: [DetectedColumn]
        /// 1-based rows that must not be imported: totals, subtotals, blank rows.
        let excludedRows: [Int]
        let notes: [String]
        /// Rough "does this look like expense data" score, for picking a sheet.
        let score: Double
    }

    // MARK: - Entry point

    static func detect(sheet: SpreadsheetSheet, sampleLimit: Int = 20) -> DetectedSheet {
        let bounds = usedColumnBounds(in: sheet)
        guard let firstColumn = bounds.first, let lastColumn = bounds.last else {
            return DetectedSheet(
                headerRow: nil, dataStartRow: 0, dataEndRow: 0, firstColumn: 0, lastColumn: 0,
                columns: [], excludedRows: [], notes: ["This sheet is empty."], score: 0
            )
        }

        let headerRow = findHeaderRow(in: sheet, firstColumn: firstColumn, lastColumn: lastColumn)
        let dataStartRow = (headerRow ?? 0) + 1
        let dataEndRow = lastNonEmptyRow(in: sheet, from: dataStartRow) ?? dataStartRow

        var notes: [String] = []
        if headerRow == nil {
            notes.append("No header row was found, so column names are unavailable.")
        } else if let headerRow, headerRow > 1 {
            notes.append("Headers detected on row \(headerRow).")
        }
        if firstColumn > 1 {
            notes.append("Data starts at column \(CoreXLSXSpreadsheetReader.columnLetters(for: firstColumn)).")
        }

        let excludedRows = aggregateRows(
            in: sheet, dataStartRow: dataStartRow, dataEndRow: dataEndRow,
            firstColumn: firstColumn, lastColumn: lastColumn
        )
        if !excludedRows.isEmpty {
            notes.append(
                "Row\(excludedRows.count == 1 ? "" : "s") \(excludedRows.map(String.init).joined(separator: ", ")) look like totals and won't be imported."
            )
        }

        let columns = (firstColumn ... lastColumn).map { columnIndex in
            describeColumn(
                sheet: sheet, columnIndex: columnIndex, headerRow: headerRow,
                dataStartRow: dataStartRow, dataEndRow: dataEndRow,
                excludedRows: Set(excludedRows), sampleLimit: sampleLimit
            )
        }

        let assigned = assignFields(to: columns)

        return DetectedSheet(
            headerRow: headerRow,
            dataStartRow: dataStartRow,
            dataEndRow: dataEndRow,
            firstColumn: firstColumn,
            lastColumn: lastColumn,
            columns: assigned,
            excludedRows: excludedRows,
            notes: notes,
            score: score(columns: assigned, dataRowCount: max(0, dataEndRow - dataStartRow + 1))
        )
    }

    // MARK: - Geometry

    private static func usedColumnBounds(in sheet: SpreadsheetSheet) -> (first: Int?, last: Int?) {
        var first: Int?
        var last: Int?
        for row in sheet.rows {
            for (offset, cell) in row.enumerated() where !cell.isEmpty {
                let columnIndex = offset + 1
                first = min(first ?? columnIndex, columnIndex)
                last = max(last ?? columnIndex, columnIndex)
            }
        }
        return (first, last)
    }

    private static func lastNonEmptyRow(in sheet: SpreadsheetSheet, from startRow: Int) -> Int? {
        var lastRow: Int?
        for rowNumber in startRow ... max(startRow, sheet.rowCount) {
            let row = sheet.rows.indices.contains(rowNumber - 1) ? sheet.rows[rowNumber - 1] : []
            if row.contains(where: { !$0.isEmpty }) {
                lastRow = rowNumber
            }
        }
        return lastRow
    }

    /// Picks the row that best looks like headers.
    ///
    /// A header row is mostly short text labels *and* is followed by rows whose
    /// types are consistent down each column. Requiring both is what stops a
    /// title banner ("Orçamento Pessoal" in B2) from winning: it has text but
    /// nothing type-consistent under it.
    private static func findHeaderRow(in sheet: SpreadsheetSheet, firstColumn: Int, lastColumn: Int) -> Int? {
        var best: (row: Int, score: Double)?
        let limit = min(headerSearchDepth, sheet.rowCount)
        guard limit > 0 else { return nil }

        for rowNumber in 1 ... limit {
            let labels = (firstColumn ... lastColumn).compactMap { columnIndex -> String? in
                guard case let .text(value) = sheet.cell(row: rowNumber - 1, column: columnIndex - 1) else {
                    return nil
                }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                // Headers are labels, not sentences.
                return trimmed.isEmpty || trimmed.count > 40 ? nil : trimmed
            }
            guard labels.count >= 2, Set(labels.map { $0.lowercased() }).count == labels.count else { continue }

            let consistency = typeConsistencyBelow(
                sheet: sheet, headerRow: rowNumber, firstColumn: firstColumn, lastColumn: lastColumn
            )
            guard consistency > 0 else { continue }

            let width = Double(lastColumn - firstColumn + 1)
            let coverage = Double(labels.count) / max(width, 1)
            // Earlier rows break ties: a real header is near the top of its block.
            let score = (coverage * 2 + consistency * 3) - (Double(rowNumber) * 0.01)
            if score > (best?.score ?? 0) {
                best = (rowNumber, score)
            }
        }
        return best?.row
    }

    /// Fraction of columns whose values below `headerRow` share one type.
    private static func typeConsistencyBelow(
        sheet: SpreadsheetSheet, headerRow: Int, firstColumn: Int, lastColumn: Int
    ) -> Double {
        let firstDataRow = headerRow + 1
        let lastDataRow = min(headerRow + headerConfirmationDepth, sheet.rowCount)
        guard lastDataRow >= firstDataRow else { return 0 }

        var consistentColumns = 0
        var consideredColumns = 0
        for columnIndex in firstColumn ... lastColumn {
            var kinds: Set<String> = []
            var populated = 0
            for rowNumber in firstDataRow ... lastDataRow {
                let cell = sheet.cell(row: rowNumber - 1, column: columnIndex - 1)
                guard !cell.isEmpty else { continue }
                populated += 1
                kinds.insert(rawKind(of: cell))
            }
            guard populated >= 2 else { continue }
            consideredColumns += 1
            if kinds.count == 1 {
                consistentColumns += 1
            }
        }
        guard consideredColumns > 0 else { return 0 }
        return Double(consistentColumns) / Double(consideredColumns)
    }

    private static func rawKind(of cell: SpreadsheetCell) -> String {
        switch cell {
        case .date: "date"
        case .number: "number"
        case .boolean: "bool"
        case .text: "text"
        case .empty: "empty"
        }
    }

    // MARK: - Aggregate rows

    /// Finds totals rows, which are the single most damaging thing to import:
    /// a monthly total lands as an expense and every figure in the app inflates.
    ///
    /// Two independent signals, either sufficient — a labelled total ("TOTAL")
    /// and an arithmetic one (a numeric cell equal to the sum of the column
    /// above it). The label alone misses unlabelled totals; the arithmetic
    /// alone misses a total whose formula had no cached result.
    static func aggregateRows(
        in sheet: SpreadsheetSheet, dataStartRow: Int, dataEndRow: Int,
        firstColumn: Int, lastColumn: Int
    ) -> [Int] {
        guard dataEndRow >= dataStartRow, lastColumn >= firstColumn else { return [] }
        var flagged: Set<Int> = []

        for rowNumber in dataStartRow ... dataEndRow {
            for columnIndex in firstColumn ... lastColumn {
                guard case let .text(value) = sheet.cell(row: rowNumber - 1, column: columnIndex - 1) else {
                    continue
                }
                if isAggregateLabel(value) {
                    flagged.insert(rowNumber)
                    break
                }
            }
        }

        // Only the *last* numeric value in a column can be its total. Checking
        // every row against the running sum above it flags honest coincidences:
        // in 10, 20, 30 the 30 equals 10+20 and would be dropped as a total.
        for columnIndex in firstColumn ... lastColumn {
            var numericRows: [(row: Int, value: Double)] = []
            for rowNumber in dataStartRow ... dataEndRow {
                if case let .number(value) = sheet.cell(row: rowNumber - 1, column: columnIndex - 1) {
                    numericRows.append((rowNumber, value))
                }
            }
            // Needs at least two contributing rows for the sum to mean anything.
            guard let candidate = numericRows.last, numericRows.count >= 3 else { continue }
            let sumAbove = numericRows.dropLast().reduce(0) { $0 + $1.value }
            guard sumAbove != 0 else { continue }
            if abs(candidate.value - sumAbove) < aggregateTolerance {
                flagged.insert(candidate.row)
            }
        }

        return flagged.sorted()
    }

    private static let aggregateLabels: Set<String> = [
        "total", "totals", "subtotal", "sub total", "sum", "saldo", "balance",
        "soma", "somme", "gesamt", "totale", "grand total", "net", "média", "media",
        "average", "avg",
    ]

    static func isAggregateLabel(_ raw: String) -> Bool {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[:：]+$", with: "", options: .regularExpression)
        guard !normalized.isEmpty, normalized.count <= 24 else { return false }
        return aggregateLabels.contains(normalized)
    }

    // MARK: - Columns

    private static func describeColumn(
        sheet: SpreadsheetSheet, columnIndex: Int, headerRow: Int?,
        dataStartRow: Int, dataEndRow: Int, excludedRows: Set<Int>, sampleLimit: Int
    ) -> DetectedColumn {
        var header: String?
        if let headerRow, case let .text(value) = sheet.cell(row: headerRow - 1, column: columnIndex - 1) {
            header = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var values: [SpreadsheetCell] = []
        if dataEndRow >= dataStartRow {
            for rowNumber in dataStartRow ... dataEndRow where !excludedRows.contains(rowNumber) {
                let cell = sheet.cell(row: rowNumber - 1, column: columnIndex - 1)
                if !cell.isEmpty {
                    values.append(cell)
                }
            }
        }

        let kind = classify(values: values, populatedOf: max(1, dataEndRow - dataStartRow + 1))
        let formatter = isoDateFormatter()
        let texts = values.map { $0.displayText(dateFormatter: formatter) }

        return DetectedColumn(
            index: columnIndex,
            letter: CoreXLSXSpreadsheetReader.columnLetters(for: columnIndex),
            header: header?.isEmpty == true ? nil : header,
            kind: kind,
            samples: Array(sampled(texts, limit: sampleLimit)),
            distinctCount: Set(texts).count,
            field: .ignore,
            confidence: 0
        )
    }

    /// First half of the samples from the top, second half spread across the
    /// rest — a header-adjacent slice alone hides format drift further down.
    static func sampled(_ values: [String], limit: Int) -> [String] {
        guard values.count > limit else { return values }
        let head = Array(values.prefix(limit / 2))
        let remainder = Array(values.dropFirst(limit / 2))
        let wanted = limit - head.count
        guard wanted > 0, !remainder.isEmpty else { return head }
        let stride = max(1, remainder.count / wanted)
        var spread: [String] = []
        var cursor = 0
        while cursor < remainder.count, spread.count < wanted {
            spread.append(remainder[cursor])
            cursor += stride
        }
        return head + spread
    }

    private static func classify(values: [SpreadsheetCell], populatedOf total: Int) -> ColumnKind {
        guard !values.isEmpty else { return .mostlyEmpty }
        if Double(values.count) / Double(total) < 0.2 {
            return .mostlyEmpty
        }

        var dates = 0, numbers = 0, currencyish = 0
        let formatter = isoDateFormatter()
        for value in values {
            switch value {
            case .date:
                dates += 1
            case .number:
                numbers += 1
            case let .text(text):
                if looksLikeDate(text) {
                    dates += 1
                } else if let amount = looksLikeAmount(text) {
                    numbers += 1
                    if amount.hadCurrencySymbol {
                        currencyish += 1
                    }
                }
                _ = formatter
            default:
                break
            }
        }
        let count = Double(values.count)
        if Double(dates) / count >= 0.8 {
            return .date
        }
        if Double(numbers) / count >= 0.8 {
            return Double(currencyish) / count >= 0.5 ? .currencyAmount : .number
        }
        return .text
    }

    // MARK: - Field assignment

    private static let dateAliases: Set<String> = [
        "date", "data", "day", "dia", "fecha", "datum", "when", "transactiondate",
        "postingdate", "valuedate", "datamovimento",
    ]
    private static let amountAliases: Set<String> = [
        "amount", "valor", "value", "total", "price", "cost", "custo", "montante",
        "importe", "betrag", "spend", "spent", "debit", "outgoing", "expense", "despesa",
    ]
    private static let titleAliases: Set<String> = [
        "title", "description", "descricao", "descrição", "merchant", "payee", "name",
        "item", "detail", "details", "concepto", "beschreibung", "what", "vendor", "store",
    ]
    private static let categoryAliases: Set<String> = [
        "category", "categoria", "kategorie", "type", "tipo", "group", "grupo",
        "classification", "bucket",
    ]
    private static let pillarAliases: Set<String> = ["pillar", "pilar", "bucket", "area"]
    private static let notesAliases: Set<String> = [
        "notes", "note", "notas", "nota", "memo", "comment", "comments",
        "observacoes", "observações", "obs", "kommentar", "notiz",
    ]
    private static let currencyAliases: Set<String> = ["currency", "moeda", "ccy", "divisa", "währung"]
    private static let externalIDAliases: Set<String> = [
        "id", "externalid", "reference", "referencia", "transactionid", "ref",
    ]

    /// Assigns a field to each column from its header name and its content,
    /// then resolves collisions so at most one column holds each role.
    private static func assignFields(to columns: [DetectedColumn]) -> [DetectedColumn] {
        var scored: [(column: DetectedColumn, field: SpreadsheetColumnRole, confidence: Double)] = []

        for column in columns {
            let normalized = column.header.map(normalizeHeader) ?? ""
            var field: SpreadsheetColumnRole = .ignore
            var confidence = 0.0

            if !normalized.isEmpty {
                if dateAliases.contains(normalized) {
                    field = .date; confidence = 0.9
                } else if amountAliases.contains(normalized) {
                    field = .amount; confidence = 0.9
                } else if titleAliases.contains(normalized) {
                    field = .title; confidence = 0.9
                } else if categoryAliases.contains(normalized) {
                    field = .category; confidence = 0.85
                } else if pillarAliases.contains(normalized) {
                    field = .pillar; confidence = 0.8
                } else if notesAliases.contains(normalized) {
                    field = .notes; confidence = 0.8
                } else if currencyAliases.contains(normalized) {
                    field = .currency; confidence = 0.8
                } else if externalIDAliases.contains(normalized) {
                    field = .externalId; confidence = 0.7
                }
            }

            // Content backs up a header match and stands in for a missing one,
            // at lower confidence so the review screen flags it.
            if field == .ignore {
                switch column.kind {
                case .date: field = .date; confidence = 0.6
                case .currencyAmount: field = .amount; confidence = 0.6
                case .number: field = .amount; confidence = 0.35
                case .text: field = .title; confidence = 0.3
                case .mostlyEmpty: field = .ignore; confidence = 0
                }
            } else if (field == .date && column.kind != .date)
                || (field == .amount && column.kind != .number && column.kind != .currencyAmount)
            {
                // Header says one thing, the cells say another. Trust the cells:
                // a column that doesn't parse as dates cannot be the date column.
                confidence = min(confidence, 0.4)
            }

            scored.append((column, field, confidence))
        }

        // One column per role. A "Valor" and a "Valor c/ IVA" both look like
        // amounts; the stronger match wins and the other is ignored rather than
        // quietly doubling the import.
        var claimed: [SpreadsheetColumnRole: Int] = [:]
        let exclusive: Set<SpreadsheetColumnRole> = [.date, .amount, .title, .category, .pillar, .currency, .externalId]
        for (index, entry) in scored.enumerated() where exclusive.contains(entry.field) {
            if let incumbent = claimed[entry.field] {
                if entry.confidence > scored[incumbent].confidence {
                    scored[incumbent].field = .ignore
                    scored[incumbent].confidence = 0
                    claimed[entry.field] = index
                } else {
                    scored[index].field = .ignore
                    scored[index].confidence = 0
                }
            } else {
                claimed[entry.field] = index
            }
        }

        return scored.map { entry in
            DetectedColumn(
                index: entry.column.index,
                letter: entry.column.letter,
                header: entry.column.header,
                kind: entry.column.kind,
                samples: entry.column.samples,
                distinctCount: entry.column.distinctCount,
                field: entry.field,
                confidence: entry.confidence
            )
        }
    }

    static func normalizeHeader(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "[^a-z0-9à-ÿ]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How much this sheet looks like a table of expenses. Used to pick the
    /// recommended sheet, not to exclude anything.
    private static func score(columns: [DetectedColumn], dataRowCount: Int) -> Double {
        guard dataRowCount > 0 else { return 0 }
        let fields = Set(columns.map(\.field))
        var total = 0.0
        if fields.contains(.date) {
            total += 3
        }
        if fields.contains(.amount) {
            total += 3
        }
        if fields.contains(.title) {
            total += 2
        }
        if fields.contains(.category) {
            total += 1
        }
        guard total > 0 else { return 0 }
        return total + min(log(Double(dataRowCount) + 1), 4)
    }

    // MARK: - Value sniffing

    struct AmountSniff {
        let value: Double
        let hadCurrencySymbol: Bool
    }

    private static let currencySymbols = CharacterSet(charactersIn: "€$£¥₹R$kr zł Kč₺₽")

    /// Recognises an amount without committing to a decimal separator; that
    /// decision is made per column later, where there is enough evidence.
    static func looksLikeAmount(_ raw: String) -> AmountSniff? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadSymbol = trimmed.rangeOfCharacter(from: currencySymbols) != nil
            || trimmed.range(of: "\\b(eur|usd|gbp|brl|chf|pln|sek|nok|dkk)\\b", options: [.regularExpression, .caseInsensitive]) != nil

        var cleaned = trimmed
        // Accounting negatives: (123.45)
        var negative = false
        if cleaned.hasPrefix("("), cleaned.hasSuffix(")") {
            negative = true
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        cleaned = cleaned.replacingOccurrences(
            of: "[^0-9,.\\-]", with: "", options: .regularExpression
        )
        guard !cleaned.isEmpty, cleaned.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }

        // Strip grouping separators for the sniff only.
        let normalized = cleaned
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "\\.(?=.*\\.)", with: "", options: .regularExpression)
        guard let value = Double(normalized) else { return nil }
        return AmountSniff(value: negative ? -value : value, hadCurrencySymbol: hadSymbol)
    }

    static func looksLikeDate(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6, trimmed.count <= 24 else { return false }
        let patterns = [
            "^\\d{4}[-/.]\\d{1,2}[-/.]\\d{1,2}$",
            "^\\d{1,2}[-/.]\\d{1,2}[-/.]\\d{2,4}$",
            "^\\d{1,2} [A-Za-zÀ-ÿ]{3,} \\d{2,4}$",
        ]
        return patterns.contains { trimmed.range(of: $0, options: .regularExpression) != nil }
    }

    static func isoDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
