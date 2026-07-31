import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

/// The validator is what makes an AI proposal safe to act on. These tests feed
/// it the proposals a model actually produces when it's wrong -- invented
/// columns, invented pillars, roles contradicted by the data -- and check that
/// none of them survive.
@Suite("Spreadsheet mapping validator")
struct SpreadsheetMappingValidatorTests {
    private let allowedPillars: Set<String> = ["fundamentals", "futureYou", "fun"]

    private func column(
        _ letter: String,
        header: String? = nil,
        kind: SpreadsheetStructureDetector.ColumnKind,
        field: SpreadsheetColumnRole,
        confidence: Double = 0.9
    ) -> SpreadsheetStructureDetector.DetectedColumn {
        .init(
            index: CoreXLSXSpreadsheetReader.columnIndex(of: letter),
            letter: letter,
            header: header,
            kind: kind,
            samples: [],
            distinctCount: 0,
            field: field,
            confidence: confidence
        )
    }

    private func detected(
        _ columns: [SpreadsheetStructureDetector.DetectedColumn]
    ) -> SpreadsheetStructureDetector.DetectedSheet {
        .init(
            headerRow: 1, dataStartRow: 2, dataEndRow: 10,
            firstColumn: 1, lastColumn: columns.count,
            columns: columns, excludedRows: [], notes: [], score: 8
        )
    }

    private func proposal(
        columns: [SpreadsheetAIProposal.ColumnProposal] = [],
        categories: [SpreadsheetAIProposal.CategoryProposal] = [],
        confidence: Double = 0.9
    ) -> SpreadsheetAIProposal {
        .init(sheetName: "Sheet1", columns: columns, categories: categories, notes: [], confidence: confidence)
    }

    // MARK: - Degrading without a model

    /// The import must work with the AI switched off, so no proposal at all has
    /// to yield the detector's mapping rather than nothing.
    @Test("no proposal falls back to the detector's mapping")
    func fallsBackToDetector() {
        let sheet = detected([
            column("A", kind: .date, field: .date),
            column("B", kind: .text, field: .title),
            column("C", kind: .currencyAmount, field: .amount),
        ])
        let result = SpreadsheetMappingValidator.validate(
            proposal: nil, detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.columnRoles == ["A": .date, "B": .title, "C": .amount])
        #expect(result.confidence == 0)
    }

    // MARK: - Column claims

    @Test("a column letter that isn't in the sheet is rejected")
    func rejectsUnknownColumn() {
        let sheet = detected([column("A", kind: .date, field: .date)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(columns: [.init(letter: "ZZ", field: "amount", confidence: 0.99)]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.columnRoles["ZZ"] == nil)
        #expect(result.rejections.contains { $0.contains("ZZ") })
    }

    @Test("an unknown field name is rejected")
    func rejectsUnknownField() {
        let sheet = detected([column("A", kind: .text, field: .title)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(columns: [.init(letter: "A", field: "vibes", confidence: 0.99)]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.columnRoles["A"] == .title)
        #expect(result.rejections.contains { $0.contains("vibes") })
    }

    /// The cells are checkable and the model's claim is not, so the cells win
    /// however confident the model was.
    @Test("a date role on a column of text is rejected")
    func rejectsRoleContradictedByContent() {
        let sheet = detected([column("A", header: "Date", kind: .text, field: .title)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(columns: [.init(letter: "A", field: "date", confidence: 1.0)]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.columnRoles["A"] == .title)
        #expect(result.rejections.contains { $0.contains("date") })
    }

    @Test("an amount role on a date column is rejected")
    func rejectsAmountOnDateColumn() {
        let sheet = detected([column("A", kind: .date, field: .date)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(columns: [.init(letter: "A", field: "amount", confidence: 1.0)]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.columnRoles["A"] == .date)
    }

    @Test("a plausible reassignment is accepted")
    func acceptsPlausibleReassignment() {
        // Detector guessed title from content; the model recognises it as a category.
        let sheet = detected([column("B", header: "Tipo", kind: .text, field: .title)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(columns: [.init(letter: "B", field: "category", confidence: 0.9)]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.columnRoles["B"] == .category)
    }

    /// Two amount columns would double every row's value.
    @Test("only one column can hold an exclusive role")
    func keepsOneColumnPerExclusiveRole() {
        let sheet = detected([
            column("J", header: "Valor", kind: .currencyAmount, field: .amount, confidence: 0.9),
            column("L", header: "Valor c/ IVA", kind: .number, field: .ignore, confidence: 0.35),
        ])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(columns: [
                .init(letter: "J", field: "amount", confidence: 0.9),
                .init(letter: "L", field: "amount", confidence: 0.8),
            ]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.columnRoles.filter { $0.value == .amount }.count == 1)
        #expect(result.columnRoles["J"] == .amount)
    }

    // MARK: - Pillars

    // BudgetPillar(rawValue:) accepts any non-empty string, so without this
    // check a hallucinated pillar becomes a real planner pillar and pollutes
    // snapshots and drift alerts.
    @Test("a pillar that doesn't exist is refused, not created")
    func refusesUnknownPillar() {
        let sheet = detected([column("C", kind: .text, field: .category)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(categories: [
                .init(sourceValue: "Groceries", pillar: "Essentials", categoryName: nil, confidence: 0.9),
            ]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.categories.first?.pillar == nil)
        #expect(result.rejections.contains { $0.contains("Essentials") })
    }

    @Test("a standard pillar is accepted")
    func acceptsKnownPillar() {
        let sheet = detected([column("C", kind: .text, field: .category)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(categories: [
                .init(sourceValue: "Lazer", pillar: "fun", categoryName: nil, confidence: 0.8),
            ]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.categories.first?.pillar == .fun)
    }

    @Test("a custom pillar the user already has is accepted")
    func acceptsExistingCustomPillar() {
        let sheet = detected([column("C", kind: .text, field: .category)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(categories: [
                .init(sourceValue: "Casa", pillar: "household", categoryName: nil, confidence: 0.8),
            ]),
            detected: sheet, existingCategories: [:],
            allowedPillars: allowedPillars.union(["household"])
        )
        #expect(result.categories.first?.pillar?.rawValue == "household")
    }

    @Test("an empty pillar is simply absent, not an error")
    func handlesNullPillar() {
        let sheet = detected([column("C", kind: .text, field: .category)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(categories: [
                .init(sourceValue: "Outros", pillar: nil, categoryName: nil, confidence: 0.2),
            ]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.categories.first?.pillar == nil)
        #expect(result.rejections.isEmpty)
    }

    // MARK: - Categories

    @Test("a category matching an existing one is marked as matched")
    func matchesExistingCategory() {
        let sheet = detected([column("C", kind: .text, field: .category)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(categories: [
                .init(sourceValue: "Supermercado", pillar: "fundamentals",
                      categoryName: "groceries", confidence: 0.9),
            ]),
            detected: sheet,
            existingCategories: ["groceries": UUID().uuidString],
            allowedPillars: allowedPillars
        )
        #expect(result.categories.first?.matchedExistingCategory == true)
    }

    @Test("a category with no counterpart is carried through as new")
    func passesThroughNewCategory() {
        let sheet = detected([column("C", kind: .text, field: .category)])
        let result = SpreadsheetMappingValidator.validate(
            proposal: proposal(categories: [
                .init(sourceValue: "Padaria", pillar: "fundamentals",
                      categoryName: "Bakery", confidence: 0.7),
            ]),
            detected: sheet, existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(result.categories.first?.matchedExistingCategory == false)
        #expect(result.categories.first?.categoryName == "Bakery")
    }

    // MARK: - Confidence

    @Test("confidence is clamped into range")
    func clampsConfidence() {
        let sheet = detected([column("A", kind: .date, field: .date)])
        let high = SpreadsheetMappingValidator.validate(
            proposal: proposal(confidence: 7.5), detected: sheet,
            existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(high.confidence == 1)

        let low = SpreadsheetMappingValidator.validate(
            proposal: proposal(confidence: -3), detected: sheet,
            existingCategories: [:], allowedPillars: allowedPillars
        )
        #expect(low.confidence == 0)
    }
}
