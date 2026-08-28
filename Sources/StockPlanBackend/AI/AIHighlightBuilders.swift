import Foundation
import StockPlanShared
import Vapor

/// The server-selected facts a narrative is written from.
///
/// Every field is optional because each surface loads only what it needs; a
/// builder that finds nothing returns no highlights rather than inventing a
/// zero.
struct AIInsightDataset: Encodable, Sendable {
    var dashboard: DashboardResponse?
    var dashboardInsights: DashboardInsightsResponse?
    var expenseReports: [BudgetMonthSummaryResponse]?
    var budgetPlanning: [PillarPlanningSummaryResponse]?
}

/// Builds the numbers shown on an AI card.
///
/// These are deliberately not the model's job. The model writes the title and
/// the sentences; every figure a user reads is computed here from the dataset,
/// so a hallucinated number cannot reach the screen. `AIInsightsTests` asserts
/// this by feeding a scripted reply containing a wrong figure and checking the
/// highlights still match the seeded data.
///
/// Extracted from `DefaultAIInsightsService` so a second surface can reuse the
/// same builders without importing the insight-card flow around them.
enum AIHighlightBuilders {
    static func portfolio(_ dataset: AIInsightDataset) -> [AIInsightHighlight] {
        guard let dashboard = dataset.dashboard else { return [] }
        var values = [
            AIInsightHighlight(label: "Portfolio value", value: formatNumber(dashboard.totalValue)),
            AIInsightHighlight(
                label: "Daily change",
                value: formatPercent(dashboard.dailyChangePercent),
                trend: trend(dashboard.dailyChangePercent)
            ),
        ]
        if let insights = dataset.dashboardInsights {
            values.append(AIInsightHighlight(
                label: "Financial health",
                value: "\(insights.financialHealth.score)/\(insights.financialHealth.maxScore)"
            ))
            values.append(AIInsightHighlight(
                label: "Savings rate", value: formatPercent(insights.savingsRate)
            ))
        }
        return values
    }

    static func expenses(_ dataset: AIInsightDataset) -> [AIInsightHighlight] {
        guard let latest = dataset.expenseReports?.last else {
            let actual = dataset.budgetPlanning?.reduce(0) { $0 + $1.actualAmount } ?? 0
            return actual == 0
                ? []
                : [AIInsightHighlight(label: "Month spending", value: formatNumber(actual))]
        }
        var values = [
            AIInsightHighlight(label: "Month spending", value: formatNumber(latest.actual)),
            AIInsightHighlight(label: "Month plan", value: formatNumber(latest.planned)),
        ]
        if latest.salary > 0 {
            let savingsRate = max(0, ((latest.salary - latest.actual) / latest.salary) * 100)
            values.append(AIInsightHighlight(label: "Savings rate", value: formatPercent(savingsRate)))
        }
        return values
    }

    /// Both sides, trimmed. Four is what the card can show without scrolling.
    static func combined(_ dataset: AIInsightDataset) -> [AIInsightHighlight] {
        Array((portfolio(dataset) + expenses(dataset)).prefix(4))
    }

    // MARK: - Formatting

    /// Thin passes through to `MoneyFormat`, which main made the single source
    /// of truth so an insight card and a Telegram reply cannot disagree about
    /// what a number looks like. Kept as named members here because the builders
    /// read better for it and the tests assert on them directly.
    static func formatNumber(_ value: Double) -> String {
        MoneyFormat.number(value)
    }

    static func formatPercent(_ value: Double) -> String {
        MoneyFormat.percent(value)
    }

    static func trend(_ value: Double) -> String {
        MoneyFormat.trend(value)
    }
}
