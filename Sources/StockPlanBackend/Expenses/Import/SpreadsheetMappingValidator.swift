import Foundation
import StockPlanShared

/// Checks a model proposal against what the file and the user's data actually
/// contain, and drops anything that doesn't hold up.
///
/// The model is a suggestion engine, not an authority. Two rules follow:
///
/// * A claim that can be checked mechanically is checked. A column letter that
///   isn't in the sheet, a confidence outside 0...1, a `date` role on a column
///   whose values don't parse as dates — all discarded in favour of what the
///   detector measured.
/// * A pillar is only accepted if it already exists. `BudgetPillar(rawValue:)`
///   accepts any non-empty string (it only rejects an empty canonical key), so
///   nothing upstream stops a typo or a hallucination from becoming a
///   first-class planner pillar that then pollutes snapshots and drift alerts.
///   Unrecognised pillars become the user's decision instead.
enum SpreadsheetMappingValidator {
    struct ValidatedMapping: Sendable, Equatable {
        /// Column letter -> role, after reconciliation with the detector.
        var columnRoles: [String: SpreadsheetColumnRole]
        var categories: [ValidatedCategory]
        var notes: [String]
        var confidence: Double
        /// Roles the proposal claimed that were rejected, for logging and for
        /// telling the user why their sheet mapped the way it did.
        var rejections: [String]
    }

    struct ValidatedCategory: Sendable, Equatable {
        let sourceValue: String
        /// Nil when the proposed pillar wasn't recognised. The row becomes
        /// `needsCategory` and the user picks.
        let pillar: BudgetPillar?
        let categoryName: String?
        let matchedExistingCategory: Bool
        let confidence: Double
    }

    /// Reconciles a proposal with the detector's findings.
    ///
    /// `detected` wins on anything measurable; the proposal contributes
    /// semantics the detector can't see — which sheet is the expense sheet,
    /// what "Lazer" means, which existing category a value belongs to.
    static func validate(
        proposal: SpreadsheetAIProposal?,
        detected: SpreadsheetStructureDetector.DetectedSheet,
        existingCategories: [String: String],
        allowedPillars: Set<String>
    ) -> ValidatedMapping {
        var roles: [String: SpreadsheetColumnRole] = [:]
        var rejections: [String] = []

        // Start from the detector so a missing or useless proposal still yields
        // a working mapping.
        for column in detected.columns where column.field != .ignore {
            roles[column.letter] = column.field
        }

        guard let proposal else {
            return ValidatedMapping(
                columnRoles: roles,
                categories: [],
                notes: detected.notes,
                confidence: 0,
                rejections: []
            )
        }

        let columnsByLetter = Dictionary(
            detected.columns.map { ($0.letter, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for proposed in proposal.columns {
            guard let column = columnsByLetter[proposed.letter] else {
                rejections.append("Column \(proposed.letter) isn't in this sheet.")
                continue
            }
            guard let role = SpreadsheetColumnRole(rawValue: proposed.field) else {
                rejections.append("Unknown field \"\(proposed.field)\" for column \(proposed.letter).")
                continue
            }
            // Contradicted by the cells themselves: keep what was measured.
            if !isPlausible(role: role, for: column) {
                rejections.append(
                    "Column \(proposed.letter) was proposed as \(role.rawValue) but its values are \(column.kind.rawValue)."
                )
                continue
            }
            if role == .ignore {
                roles.removeValue(forKey: proposed.letter)
            } else {
                roles[proposed.letter] = role
            }
        }

        // One column per exclusive role, even after the proposal has had its say.
        roles = deduplicateExclusiveRoles(roles, columnsByLetter: columnsByLetter, rejections: &rejections)

        let categories = proposal.categories.map { proposed -> ValidatedCategory in
            let pillar = validatedPillar(proposed.pillar, allowedPillars: allowedPillars, rejections: &rejections)
            let existingName = proposed.categoryName
                .flatMap { existingCategories[$0.lowercased()] != nil ? $0 : nil }
            return ValidatedCategory(
                sourceValue: proposed.sourceValue,
                pillar: pillar,
                categoryName: existingName ?? proposed.categoryName,
                matchedExistingCategory: existingName != nil,
                confidence: min(max(proposed.confidence, 0), 1)
            )
        }

        return ValidatedMapping(
            columnRoles: roles,
            categories: categories,
            notes: detected.notes + proposal.notes.map { String($0.prefix(140)) },
            confidence: min(max(proposal.confidence, 0), 1),
            rejections: rejections
        )
    }

    // MARK: - Rules

    /// Whether a role is consistent with what the column actually holds.
    /// Roles with no measurable signature (notes, external id) always pass.
    static func isPlausible(
        role: SpreadsheetColumnRole,
        for column: SpreadsheetStructureDetector.DetectedColumn
    ) -> Bool {
        switch role {
        case .date:
            column.kind == .date
        case .amount:
            column.kind == .number || column.kind == .currencyAmount
        case .title, .category, .pillar, .currency:
            column.kind != .date
        case .notes, .externalId, .ignore:
            true
        }
    }

    /// `BudgetPillar` will happily mint a pillar from any non-empty string, so
    /// membership is checked explicitly against the standard set plus whatever
    /// the user already uses.
    private static func validatedPillar(
        _ raw: String?,
        allowedPillars: Set<String>,
        rejections: inout [String]
    ) -> BudgetPillar? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let candidate = BudgetPillar(rawValue: raw) else { return nil }
        guard allowedPillars.contains(candidate.rawValue) else {
            rejections.append("Pillar \"\(raw)\" doesn't exist yet, so those rows need a choice.")
            return nil
        }
        return candidate
    }

    private static let exclusiveRoles: Set<SpreadsheetColumnRole> = [
        .date, .amount, .title, .category, .pillar, .currency, .externalId,
    ]

    /// Keeps the highest-confidence column for each exclusive role. Two columns
    /// claiming `amount` would otherwise double every row.
    private static func deduplicateExclusiveRoles(
        _ roles: [String: SpreadsheetColumnRole],
        columnsByLetter: [String: SpreadsheetStructureDetector.DetectedColumn],
        rejections: inout [String]
    ) -> [String: SpreadsheetColumnRole] {
        var winners: [SpreadsheetColumnRole: (letter: String, confidence: Double)] = [:]
        var result: [String: SpreadsheetColumnRole] = [:]

        for (letter, role) in roles.sorted(by: { $0.key < $1.key }) {
            guard exclusiveRoles.contains(role) else {
                result[letter] = role
                continue
            }
            let confidence = columnsByLetter[letter]?.confidence ?? 0
            if let incumbent = winners[role] {
                if confidence > incumbent.confidence {
                    result.removeValue(forKey: incumbent.letter)
                    rejections.append(
                        "Columns \(incumbent.letter) and \(letter) both looked like \(role.rawValue); kept \(letter)."
                    )
                    winners[role] = (letter, confidence)
                    result[letter] = role
                } else {
                    rejections.append(
                        "Columns \(incumbent.letter) and \(letter) both looked like \(role.rawValue); kept \(incumbent.letter)."
                    )
                }
            } else {
                winners[role] = (letter, confidence)
                result[letter] = role
            }
        }
        return result
    }
}
