import Foundation
import StockPlanShared
import Vapor

/// Conversions between the three shapes this feature deals in: what the parser
/// produced, what gets stored, and what goes over the wire.
///
/// They are kept apart on purpose. The stored format can change without a
/// shared-package release, and the wire format can change without touching the
/// parser.
extension ExpenseSpreadsheetImportService {
    // MARK: - Parser -> storage

    static func storedSheet(
        sheet: SpreadsheetSheet,
        detected: SpreadsheetStructureDetector.DetectedSheet
    ) -> ExpenseImportSessionStore.StoredSheet {
        let isoFormatter = SpreadsheetStructureDetector.isoDateFormatter()
        var rows: [ExpenseImportSessionStore.StoredSheet.Row] = []

        if detected.dataEndRow >= detected.dataStartRow, detected.lastColumn >= detected.firstColumn {
            for rowNumber in detected.dataStartRow ... detected.dataEndRow {
                var cells: [String: String] = [:]
                for columnIndex in detected.firstColumn ... detected.lastColumn {
                    let cell = sheet.cell(row: rowNumber - 1, column: columnIndex - 1)
                    guard !cell.isEmpty else { continue }
                    let letter = CoreXLSXSpreadsheetReader.columnLetters(for: columnIndex)
                    cells[letter] = cell.displayText(dateFormatter: isoFormatter)
                }
                // Entirely blank rows carry nothing and would only clutter the
                // review table.
                guard !cells.isEmpty else { continue }
                rows.append(.init(row: rowNumber, cells: cells))
            }
        }

        return .init(
            name: sheet.name,
            index: sheet.index,
            rowCount: sheet.rowCount,
            headerRow: detected.headerRow,
            dataStartRow: detected.dataStartRow,
            dataEndRow: detected.dataEndRow,
            excludedRows: detected.excludedRows,
            columns: detected.columns.map {
                .init(
                    letter: $0.letter, header: $0.header, kind: $0.kind.rawValue,
                    samples: $0.samples, distinctCount: $0.distinctCount,
                    role: $0.field.rawValue, confidence: $0.confidence
                )
            },
            rows: rows,
            notes: detected.notes,
            score: detected.score
        )
    }

    static func digestSheet(
        sheet: SpreadsheetSheet,
        detected: SpreadsheetStructureDetector.DetectedSheet
    ) -> SpreadsheetDigest.Sheet {
        .init(
            name: sheet.name,
            rowCount: sheet.rowCount,
            headerRow: detected.headerRow,
            columns: detected.columns.map {
                .init(
                    letter: $0.letter,
                    header: $0.header,
                    detectedType: $0.kind.rawValue,
                    distinctCount: $0.distinctCount,
                    // Truncated so one long free-text cell can't dominate the
                    // prompt, and so less of the user's data travels.
                    samples: $0.samples.map { String($0.prefix(64)) }
                )
            }
        )
    }

    static func storedMapping(
        selectedSheet: String,
        validated: SpreadsheetMappingValidator.ValidatedMapping,
        detected: SpreadsheetStructureDetector.DetectedSheet,
        sheet _: SpreadsheetSheet,
        existingCategories: [String: String],
        baseCurrency: String?
    ) -> ExpenseImportSessionStore.StoredMapping {
        // Date order and decimal separator are inferred from the columns the
        // mapping actually selected, not from the sheet at large.
        let dateColumn = validated.columnRoles.first { $0.value == .date }?.key
        let amountColumn = validated.columnRoles.first { $0.value == .amount }?.key
        let columnsByLetter = Dictionary(
            detected.columns.map { ($0.letter, $0) }, uniquingKeysWith: { first, _ in first }
        )

        let dateOrder = dateColumn
            .flatMap { columnsByLetter[$0] }
            .map { SpreadsheetRowNormalizer.inferDateOrder(from: $0.samples) } ?? .dayFirst
        let separator = amountColumn
            .flatMap { columnsByLetter[$0] }
            .map { SpreadsheetRowNormalizer.inferDecimalSeparator(from: $0.samples) } ?? .dot

        var notes = validated.notes
        if dateOrder == .ambiguous {
            // Worth saying out loud: this is the difference between 3 April and
            // 4 March, and it is invisible once imported.
            notes.append("Dates are being read as day/month — 03/04/2026 means 3 April 2026. Change it if that's wrong.")
        }

        let categories = validated.categories.map { category in
            ExpenseImportSessionStore.StoredMapping.Category(
                sourceValue: category.sourceValue,
                pillar: category.pillar?.rawValue,
                categoryId: category.categoryName.flatMap { existingCategories[$0.lowercased()] },
                categoryName: category.categoryName,
                createCategory: category.categoryName != nil && !category.matchedExistingCategory,
                confidence: category.confidence,
                source: category.confidence > 0 ? "ai" : "heuristic"
            )
        }

        return .init(
            selectedSheet: selectedSheet,
            columnRoles: validated.columnRoles.mapValues(\.rawValue),
            categories: categories,
            amountSign: SpreadsheetImportAmountSign.positiveIsExpense.rawValue,
            // Ambiguous is not a usable parsing mode, so it resolves to
            // day-first for parsing while the note above flags it to the user.
            dateOrder: (dateOrder == .ambiguous ? .dayFirst : dateOrder).rawValue,
            decimalSeparator: separator.rawValue,
            currency: nil,
            baseCurrency: baseCurrency,
            exchangeRates: [:],
            skippedRows: [],
            notes: notes,
            warnings: []
        )
    }

    // MARK: - Wire -> storage

    /// Folds the user's decisions into the stored mapping.
    ///
    /// Only fields the request actually carries are overwritten, so a client
    /// that sends a partial decision doesn't silently reset the rest.
    static func apply(
        decision: SpreadsheetImportDecisionRequest,
        to mapping: ExpenseImportSessionStore.StoredMapping
    ) -> ExpenseImportSessionStore.StoredMapping {
        var updated = mapping

        if let sheet = decision.sheets.first(where: { $0.include }) ?? decision.sheets.first {
            updated.selectedSheet = sheet.name
            if !sheet.columns.isEmpty {
                updated.columnRoles = Dictionary(
                    sheet.columns
                        .filter { $0.field != .ignore && $0.field != .unknown }
                        .map { ($0.letter, $0.field.rawValue) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }

        if !decision.categoryMappings.isEmpty {
            updated.categories = decision.categoryMappings.map {
                .init(
                    sourceValue: $0.sourceValue,
                    pillar: $0.pillar?.rawValue,
                    categoryId: $0.categoryId,
                    categoryName: $0.categoryName,
                    createCategory: $0.createCategory,
                    confidence: $0.confidence,
                    // A choice the user made is not a guess any more.
                    source: SpreadsheetMappingSource.user.rawValue
                )
            }
        }

        updated.amountSign = decision.amountSign.rawValue
        if let dateFormat = decision.dateFormat,
           let order = SpreadsheetRowNormalizer.DateOrder(rawValue: dateFormat)
        {
            updated.dateOrder = order == .ambiguous ? updated.dateOrder : order.rawValue
        }
        if let separator = decision.decimalSeparator,
           let parsed = SpreadsheetRowNormalizer.DecimalSeparator(rawValue: separator)
        {
            updated.decimalSeparator = parsed.rawValue
        }
        if let currency = decision.currency {
            updated.currency = currency.uppercased()
        }
        if !decision.exchangeRates.isEmpty {
            updated.exchangeRates = decision.exchangeRates.reduce(into: [String: Double]()) {
                $0[$1.key.uppercased()] = $1.value
            }
        }
        updated.skippedRows = decision.rowOverrides.filter { !$0.include }.map(\.row)

        return updated
    }

    static func overrideIndex(
        _ overrides: [SpreadsheetImportRowOverride]
    ) -> [String: SpreadsheetImportRowOverride] {
        Dictionary(
            overrides.map { (overrideKey(sheet: $0.sheetName, row: $0.row), $0) },
            uniquingKeysWith: { _, last in last }
        )
    }

    static func overrideKey(sheet: String, row: Int) -> String {
        "\(sheet)#\(row)"
    }

    // MARK: - Storage -> wire

    static func wireSheet(
        _ sheet: ExpenseImportSessionStore.StoredSheet,
        mapping: ExpenseImportSessionStore.StoredMapping
    ) -> SpreadsheetImportSheet {
        let isSelected = sheet.name == mapping.selectedSheet
        return SpreadsheetImportSheet(
            name: sheet.name,
            index: sheet.index,
            rowCount: sheet.rowCount,
            headerRow: sheet.headerRow ?? 0,
            dataStartRow: sheet.dataStartRow,
            dataEndRow: sheet.dataEndRow,
            include: isSelected,
            isRecommended: isSelected,
            columns: sheet.columns.map { column in
                // The live mapping wins over whatever the detector first
                // guessed, so the review screen shows current state.
                let role = isSelected
                    ? (mapping.columnRoles[column.letter] ?? SpreadsheetColumnRole.ignore.rawValue)
                    : column.role
                return SpreadsheetImportColumn(
                    letter: column.letter,
                    header: column.header,
                    detectedType: column.kind,
                    sampleValues: column.samples,
                    field: SpreadsheetImportField(rawValue: role) ?? .ignore,
                    confidence: column.confidence,
                    source: column.confidence >= 0.85 ? .heuristic : .ai
                )
            },
            excludedRows: sheet.excludedRows,
            notes: sheet.notes
        )
    }

    static func wireCategories(
        _ categories: [ExpenseImportSessionStore.StoredMapping.Category]
    ) -> [SpreadsheetImportCategoryMapping] {
        categories.map {
            SpreadsheetImportCategoryMapping(
                sourceValue: $0.sourceValue,
                pillar: $0.pillar.flatMap { BudgetPillar(rawValue: $0) },
                categoryId: $0.categoryId,
                categoryName: $0.categoryName,
                createCategory: $0.createCategory,
                confidence: $0.confidence,
                source: SpreadsheetMappingSource(rawValue: $0.source) ?? .heuristic
            )
        }
    }

    // MARK: - Rows and errors

    static func derivedRow(
        sheet: String,
        row: Int,
        status: SpreadsheetImportRowStatus,
        message: String?,
        normalized: SpreadsheetRowNormalizer.NormalizedRow?,
        category: ExpenseImportSessionStore.StoredMapping.Category?,
        request: ExpenseRequest?
    ) -> DerivedRow {
        DerivedRow(
            reference: row,
            sheetName: sheet,
            row: row,
            status: status,
            message: message,
            preview: SpreadsheetImportPreviewRow(
                sheetName: sheet,
                row: row,
                title: normalized?.title,
                amount: normalized?.amount,
                currency: normalized?.currency,
                occurredOn: normalized?.occurredOn,
                pillar: category?.pillar.flatMap { BudgetPillar(rawValue: $0) },
                categoryId: category?.categoryId,
                categoryName: category?.categoryName,
                sourceCategoryValue: normalized?.sourceCategoryValue,
                status: status,
                message: message
            ),
            expenseRequest: request
        )
    }

    static func status(for issue: SpreadsheetRowNormalizer.RowIssue) -> SpreadsheetImportRowStatus {
        switch issue {
        case .invalidDate: .invalidDate
        case .invalidAmount: .invalidAmount
        case .missingTitle: .missingTitle
        case .needsExchangeRate: .needsExchangeRate
        case .aggregateRow: .aggregateRow
        }
    }

    static func message(for issue: SpreadsheetRowNormalizer.RowIssue) -> String? {
        switch issue {
        case .invalidDate: "We couldn't read a date on this row."
        case .invalidAmount: "We couldn't read an amount on this row."
        case .missingTitle: "This row has no description."
        case .needsExchangeRate: "Set an exchange rate for this currency to include this row."
        case .aggregateRow: "This looks like a totals row, so it's excluded."
        }
    }

    /// Read failures carry their own user-facing wording; this only picks the
    /// status code.
    static func abort(for error: SpreadsheetReadError) -> Abort {
        switch error {
        case .legacyBinaryFormat:
            Abort(.unsupportedMediaType, reason: error.reason)
        case .tooLarge:
            Abort(.payloadTooLarge, reason: error.reason)
        case .passwordProtected, .notASpreadsheet, .tooManyRows, .noReadableSheets:
            Abort(.badRequest, reason: error.reason)
        }
    }
}
