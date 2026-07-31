import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Orchestrates analyze -> preview -> commit.
///
/// Preview and commit run the *same* derivation; commit is preview plus the
/// writes. That's deliberate: if they were separate code paths, the rows a user
/// approved and the rows we insert could drift apart, and the review screen
/// would stop being a guarantee.
struct ExpenseSpreadsheetImportService {
    /// Rows returned to the client. Counts always describe the whole import.
    static let previewRowLimit = 200
    /// Ceiling on new categories created in one import, so a mis-mapped column
    /// of free text can't manufacture hundreds of them.
    static let maxNewCategories = 50

    let reader: any SpreadsheetReader
    let provider: any SpreadsheetAnalysisProvider
    let store: ExpenseImportSessionStore
    let expensesService: any ExpensesService

    // MARK: - Analyze

    func analyze(
        data: Data,
        fileName: String,
        userId: UUID,
        on req: Request
    ) async throws -> SpreadsheetImportAnalysisResponse {
        let workbook: SpreadsheetWorkbook
        do {
            workbook = try reader.read(data, limits: .default)
        } catch let error as SpreadsheetReadError {
            throw Self.abort(for: error)
        }

        let detections = workbook.sheets.map { sheet in
            (sheet: sheet, detected: SpreadsheetStructureDetector.detect(sheet: sheet))
        }
        guard let best = detections.max(by: { $0.detected.score < $1.detected.score }),
              best.detected.score > 0
        else {
            throw Abort(.badRequest, reason: "We couldn't find a table of expenses in that file.")
        }

        let categories = try await expensesService.getCategories(userId: userId, on: req.db)
        let existingCategories = Dictionary(
            categories.map { ($0.name.lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let allowedPillars = Self.allowedPillars(from: categories)

        // Only the recommended sheet plus the runner-up go to the model; more
        // than that is spend without much return.
        let digestSheets = detections
            .sorted { $0.detected.score > $1.detected.score }
            .prefix(2)
            .map { Self.digestSheet(sheet: $0.sheet, detected: $0.detected) }

        var proposal: SpreadsheetAIProposal?
        if provider.isEnabled {
            let digest = SpreadsheetDigest(
                sheets: Array(digestSheets),
                existingCategories: Array(existingCategories.keys),
                allowedPillars: Array(allowedPillars)
            )
            proposal = try? await provider.analyze(digest: digest, on: req)
        }

        // A proposal naming a different sheet only wins if that sheet actually
        // scored; the model can't nominate an empty tab.
        var chosen = best
        if let named = proposal?.sheetName,
           let match = detections.first(where: { $0.sheet.name == named }),
           match.detected.score > 0
        {
            chosen = match
        }

        let validated = SpreadsheetMappingValidator.validate(
            proposal: proposal,
            detected: chosen.detected,
            existingCategories: existingCategories,
            allowedPillars: allowedPillars
        )

        let stored = detections.map { Self.storedSheet(sheet: $0.sheet, detected: $0.detected) }
        var mapping = Self.storedMapping(
            selectedSheet: chosen.sheet.name,
            validated: validated,
            detected: chosen.detected,
            sheet: chosen.sheet,
            existingCategories: existingCategories,
            baseCurrency: nil
        )
        mapping.warnings = workbook.warnings + validated.rejections

        let session = try await store.create(
            userId: userId,
            fileName: fileName,
            sheets: stored,
            mapping: mapping,
            aiAvailable: proposal != nil,
            aiModel: nil,
            aiConfidence: proposal.map(\.confidence),
            on: req.db
        )

        let preview = try await buildPreview(
            sheets: stored, mapping: mapping, overrides: [:], userId: userId, on: req.db
        )

        return try SpreadsheetImportAnalysisResponse(
            sessionId: session.requireID().uuidString,
            fileName: session.fileName,
            expiresAt: ISO8601DateFormatter().string(from: session.expiresAt),
            sheets: stored.map { Self.wireSheet($0, mapping: mapping) },
            categoryMappings: Self.wireCategories(mapping.categories),
            amountSign: SpreadsheetImportAmountSign(rawValue: mapping.amountSign) ?? .positiveIsExpense,
            detectedCurrency: mapping.currency,
            baseCurrency: mapping.baseCurrency,
            dateFormat: mapping.dateOrder,
            preview: preview,
            aiAvailable: proposal != nil,
            aiConfidence: proposal.map(\.confidence),
            warnings: mapping.warnings
        )
    }

    // MARK: - Preview

    func preview(
        session: ExpenseImportSession,
        decision: SpreadsheetImportDecisionRequest,
        userId: UUID,
        on db: any Database
    ) async throws -> SpreadsheetImportPreviewResponse {
        let sheets = try store.sheets(of: session)
        var mapping = try store.mapping(of: session)
        mapping = Self.apply(decision: decision, to: mapping)
        try await store.updateMapping(mapping, on: session, db: db)

        let overrides = Self.overrideIndex(decision.rowOverrides)
        let preview = try await buildPreview(
            sheets: sheets, mapping: mapping, overrides: overrides, userId: userId, on: db
        )

        return try SpreadsheetImportPreviewResponse(
            sessionId: session.requireID().uuidString,
            sheets: sheets.map { Self.wireSheet($0, mapping: mapping) },
            categoryMappings: Self.wireCategories(mapping.categories),
            preview: preview,
            warnings: mapping.warnings
        )
    }

    // MARK: - Commit

    func commit(
        session: ExpenseImportSession,
        decision: SpreadsheetImportDecisionRequest,
        userId: UUID,
        on req: Request
    ) async throws -> SpreadsheetImportCommitResponse {
        let db = req.db
        let sheets = try store.sheets(of: session)
        var mapping = try Self.apply(decision: decision, to: store.mapping(of: session))
        let overrides = Self.overrideIndex(decision.rowOverrides)

        // Create the categories the user confirmed, before deriving rows, so
        // rows can reference them by id.
        let created = try await createConfirmedCategories(
            mapping: &mapping, userId: userId, on: db
        )

        let derived = try await derive(
            sheets: sheets, mapping: mapping, overrides: overrides, userId: userId, on: db
        )

        let importer = ExpenseBulkImporter(expensesService: expensesService, request: req)
        let candidates = derived.rows.compactMap { row -> ExpenseBulkImporter.Candidate? in
            guard row.status == .ok, let request = row.expenseRequest else { return nil }
            return .init(reference: row.reference, request: request)
        }

        let outcome = try await importer.insert(candidates, userId: userId, on: db)
        try await store.markCommitted(session, on: db)

        var rows: [SpreadsheetImportRowResult] = derived.rows.map { row in
            let failure = outcome.failures[row.reference]
            return SpreadsheetImportRowResult(
                sheetName: row.sheetName,
                row: row.row,
                status: failure == nil ? row.status : .unknown,
                message: failure ?? row.message
            )
        }
        rows = Array(rows.prefix(Self.previewRowLimit))

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "yyyy-MM"
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        return try SpreadsheetImportCommitResponse(
            sessionId: session.requireID().uuidString,
            imported: outcome.imported,
            skipped: derived.rows.filter { $0.status != .ok }.count,
            failed: outcome.failures.count,
            createdCategories: created,
            monthsTouched: outcome.months.map { monthFormatter.string(from: $0) }.sorted(),
            rows: rows
        )
    }

    // MARK: - Derivation

    /// One row as the importer sees it, before any writing.
    struct DerivedRow {
        let reference: Int
        let sheetName: String
        let row: Int
        let status: SpreadsheetImportRowStatus
        let message: String?
        let preview: SpreadsheetImportPreviewRow
        let expenseRequest: ExpenseRequest?
    }

    struct Derivation {
        let rows: [DerivedRow]
        let currencies: Set<String>
        let totalAmount: Double
        let earliest: String?
        let latest: String?
    }

    /// The single source of truth for what an import will do. Preview renders
    /// it; commit writes the subset that came out `.ok`.
    func derive(
        sheets: [ExpenseImportSessionStore.StoredSheet],
        mapping: ExpenseImportSessionStore.StoredMapping,
        overrides: [String: SpreadsheetImportRowOverride],
        userId: UUID,
        on db: any Database
    ) async throws -> Derivation {
        guard let sheet = sheets.first(where: { $0.name == mapping.selectedSheet }) ?? sheets.first else {
            return Derivation(rows: [], currencies: [], totalAmount: 0, earliest: nil, latest: nil)
        }

        let roles = mapping.columnRoles.compactMapValues { SpreadsheetColumnRole(rawValue: $0) }
        let categoriesBySource = Dictionary(
            mapping.categories.map { ($0.sourceValue.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var settings = SpreadsheetRowNormalizer.Settings()
        settings.dateOrder = SpreadsheetRowNormalizer.DateOrder(rawValue: mapping.dateOrder) ?? .dayFirst
        settings.decimalSeparator =
            SpreadsheetRowNormalizer.DecimalSeparator(rawValue: mapping.decimalSeparator) ?? .dot
        settings.negativeIsExpense = mapping.amountSign == SpreadsheetImportAmountSign.negativeIsExpense.rawValue
        settings.exchangeRates = mapping.exchangeRates
        settings.baseCurrency = mapping.baseCurrency
        settings.defaultCurrency = mapping.currency

        let excluded = Set(sheet.excludedRows)
        let skipped = Set(mapping.skippedRows)
        let isoFormatter = SpreadsheetStructureDetector.isoDateFormatter()

        var derived: [DerivedRow] = []
        var currencies: Set<String> = []
        var totalAmount = 0.0
        var earliest: String?
        var latest: String?
        var seenInFile: Set<String> = []

        // Dedup against what the user already has, over this file's own span.
        var existingKeys: Set<String> = []
        let candidateDates = sheet.rows.compactMap { row -> Date? in
            guard let letter = roles.first(where: { $0.value == .date })?.key,
                  let raw = row.cells[letter]
            else { return nil }
            return SpreadsheetRowNormalizer.parseDate(raw, order: settings.dateOrder)
        }
        if let min = candidateDates.min(), let max = candidateDates.max() {
            let importer = ExpenseBulkImporter(expensesService: expensesService, request: nil)
            existingKeys = try await importer.existingDedupKeys(
                userId: userId, occurredOnRange: min ... max, on: db
            )
        }

        for storedRow in sheet.rows {
            let override = overrides[Self.overrideKey(sheet: sheet.name, row: storedRow.row)]
            if override?.include == false || skipped.contains(storedRow.row) {
                derived.append(
                    Self.derivedRow(
                        sheet: sheet.name, row: storedRow.row, status: .skippedByUser,
                        message: nil, normalized: nil, category: nil, request: nil
                    )
                )
                continue
            }

            var cells: [SpreadsheetColumnRole: SpreadsheetCell] = [:]
            for (letter, role) in roles {
                guard let text = storedRow.cells[letter], !text.isEmpty else { continue }
                cells[role] = .text(text)
            }

            let normalized = SpreadsheetRowNormalizer.normalize(
                row: storedRow.row,
                cells: cells,
                settings: settings,
                isAggregateRow: excluded.contains(storedRow.row)
            )

            // A manual edit in the review screen wins over anything derived.
            let title = override?.title ?? normalized.title
            let amount = override?.amount ?? normalized.amount
            let occurredOn = override?.occurredOn ?? normalized.occurredOn

            if let issue = normalized.issue, override?.amount == nil, override?.occurredOn == nil {
                derived.append(
                    Self.derivedRow(
                        sheet: sheet.name, row: storedRow.row, status: Self.status(for: issue),
                        message: Self.message(for: issue), normalized: normalized, category: nil, request: nil
                    )
                )
                continue
            }

            let categoryRule = normalized.sourceCategoryValue
                .flatMap { categoriesBySource[$0.lowercased()] }
            let pillar = override?.pillar
                ?? categoryRule?.pillar.flatMap { BudgetPillar(rawValue: $0) }
            let categoryId = override?.categoryId ?? categoryRule?.categoryId

            guard let title, let amount, let occurredOn else {
                derived.append(
                    Self.derivedRow(
                        sheet: sheet.name, row: storedRow.row, status: .invalidAmount,
                        message: "This row is missing a value.", normalized: normalized,
                        category: categoryRule, request: nil
                    )
                )
                continue
            }

            // Duplicates are checked before the pillar is required. An expense
            // the user already has needs no categorising, and reporting it as
            // "needs a category" would ask them to do work that ends in the row
            // being skipped anyway.
            let dedupKey = ExpenseBulkImporter.dedupKey(
                occurredOn: occurredOn, amount: amount, title: title, externalID: nil
            )
            if existingKeys.contains(dedupKey) {
                derived.append(
                    Self.derivedRow(
                        sheet: sheet.name, row: storedRow.row, status: .duplicateExisting,
                        message: "You already have this expense.", normalized: normalized,
                        category: categoryRule, request: nil
                    )
                )
                continue
            }
            if seenInFile.contains(dedupKey) {
                derived.append(
                    Self.derivedRow(
                        sheet: sheet.name, row: storedRow.row, status: .duplicateInFile,
                        message: "This row repeats an earlier row.", normalized: normalized,
                        category: categoryRule, request: nil
                    )
                )
                continue
            }
            seenInFile.insert(dedupKey)

            // Without a pillar the expense has nowhere to live, so ask rather
            // than defaulting it into somebody's budget.
            guard let pillar else {
                derived.append(
                    Self.derivedRow(
                        sheet: sheet.name, row: storedRow.row, status: .needsCategory,
                        message: "Choose a pillar for \"\(normalized.sourceCategoryValue ?? title)\".",
                        normalized: normalized, category: categoryRule, request: nil
                    )
                )
                continue
            }

            let request = ExpenseRequest(
                title: title,
                amount: amount,
                pillar: pillar,
                occurredOn: occurredOn,
                categoryId: categoryId,
                foreignAmount: normalized.foreignAmount,
                foreignCurrency: normalized.foreignAmount != nil ? normalized.currency : nil,
                exchangeRate: normalized.exchangeRate,
                notes: normalized.notes
            )

            totalAmount += amount
            if let currency = normalized.currency {
                currencies.insert(currency)
            }
            if earliest == nil || occurredOn < earliest! {
                earliest = occurredOn
            }
            if latest == nil || occurredOn > latest! {
                latest = occurredOn
            }

            derived.append(
                DerivedRow(
                    reference: storedRow.row,
                    sheetName: sheet.name,
                    row: storedRow.row,
                    status: .ok,
                    message: nil,
                    preview: SpreadsheetImportPreviewRow(
                        sheetName: sheet.name, row: storedRow.row, title: title, amount: amount,
                        currency: normalized.currency, occurredOn: occurredOn, pillar: pillar,
                        categoryId: categoryId, categoryName: categoryRule?.categoryName,
                        sourceCategoryValue: normalized.sourceCategoryValue, status: .ok, message: nil
                    ),
                    expenseRequest: request
                )
            )
            _ = isoFormatter
        }

        return Derivation(
            rows: derived, currencies: currencies, totalAmount: totalAmount,
            earliest: earliest, latest: latest
        )
    }

    /// Re-derives a preview from what's already stored, without applying any
    /// new decisions. Used when resuming a review.
    func previewOnly(
        sheets: [ExpenseImportSessionStore.StoredSheet],
        mapping: ExpenseImportSessionStore.StoredMapping,
        userId: UUID,
        on db: any Database
    ) async throws -> SpreadsheetImportPreview {
        try await buildPreview(
            sheets: sheets, mapping: mapping, overrides: [:], userId: userId, on: db
        )
    }

    private func buildPreview(
        sheets: [ExpenseImportSessionStore.StoredSheet],
        mapping: ExpenseImportSessionStore.StoredMapping,
        overrides: [String: SpreadsheetImportRowOverride],
        userId: UUID,
        on db: any Database
    ) async throws -> SpreadsheetImportPreview {
        let derivation = try await derive(
            sheets: sheets, mapping: mapping, overrides: overrides, userId: userId, on: db
        )
        let rows = derivation.rows
        let needsAttention = rows.filter {
            [.needsCategory, .needsExchangeRate, .invalidDate, .invalidAmount, .missingTitle]
                .contains($0.status)
        }

        return SpreadsheetImportPreview(
            totalRows: rows.count,
            importableRows: rows.filter { $0.status == .ok }.count,
            duplicateRows: rows.filter { $0.status == .duplicateExisting || $0.status == .duplicateInFile }.count,
            needsAttentionRows: needsAttention.count,
            excludedRows: rows.filter { $0.status == .aggregateRow || $0.status == .skippedByUser }.count,
            detectedCurrencies: derivation.currencies.sorted(),
            dateRangeStart: derivation.earliest,
            dateRangeEnd: derivation.latest,
            totalAmount: (derivation.totalAmount * 100).rounded() / 100,
            rows: rows.prefix(Self.previewRowLimit).map(\.preview),
            truncated: rows.count > Self.previewRowLimit
        )
    }

    // MARK: - Categories

    private func createConfirmedCategories(
        mapping: inout ExpenseImportSessionStore.StoredMapping,
        userId: UUID,
        on db: any Database
    ) async throws -> [String] {
        let wanted = mapping.categories.filter { $0.createCategory && $0.categoryId == nil }
        guard !wanted.isEmpty else { return [] }
        guard wanted.count <= Self.maxNewCategories else {
            throw Abort(
                .badRequest,
                reason: "That mapping would create \(wanted.count) new categories. Map them to existing ones instead."
            )
        }

        var createdNames: [String] = []
        for rule in wanted {
            guard let name = rule.categoryName, !name.isEmpty else { continue }
            let created = try await expensesService.createCategory(
                userId: userId,
                request: ExpenseCategoryRequest(
                    name: name,
                    pillar: rule.pillar.flatMap { BudgetPillar(rawValue: $0) }
                ),
                on: db
            )
            createdNames.append(created.name)
            if let index = mapping.categories.firstIndex(where: { $0.sourceValue == rule.sourceValue }) {
                let existing = mapping.categories[index]
                mapping.categories[index] = .init(
                    sourceValue: existing.sourceValue,
                    pillar: existing.pillar,
                    categoryId: created.id,
                    categoryName: created.name,
                    createCategory: false,
                    confidence: existing.confidence,
                    source: existing.source
                )
            }
        }
        return createdNames
    }

    static func allowedPillars(from categories: [ExpenseCategoryResponse]) -> Set<String> {
        var pillars = Set(BudgetPillar.allCases.map(\.rawValue))
        for category in categories {
            guard let pillar = category.pillar else { continue }
            pillars.insert(pillar.rawValue)
        }
        return pillars
    }
}
