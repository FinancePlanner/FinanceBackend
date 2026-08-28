import Foundation
import StockPlanShared
import Vapor

protocol AIInsightsService: Sendable {
    func generate(kind: AIInsightKind, userId: UUID, on req: Request) async throws -> AIInsightCardResponse
}

/// Insight data selection and every displayed number are deterministic. The
/// model receives a server-selected snapshot and writes only the short title and
/// narrative; it cannot add or reformat highlight values.
struct DefaultAIInsightsService: AIInsightsService {
    let client: any OpenAIChatClient

    func generate(kind: AIInsightKind, userId: UUID, on req: Request) async throws -> AIInsightCardResponse {
        let dataset = try await loadDataset(kind: kind, userId: userId, on: req)
        let highlights = Self.highlights(for: kind, dataset: dataset)
        let fallback = Self.fallbackCard(kind: kind, highlights: highlights)
        let facts = try AIReadToolRegistry.encode(dataset)

        let messages = [
            OpenAIMessage(role: "system", content: AIPrompt.system),
            OpenAIMessage(role: "user", content: AIPrompt.userPrompt(for: kind, factsJSON: facts)),
        ]

        do {
            let message = try await client.chat(
                messages: messages, tools: [], responseFormat: "json_object", on: req
            )
            guard let narrative = Self.parseNarrative(message.content) else {
                req.logger.warning("ai_insight_fallback kind=\(kind.rawValue) reason=empty_or_invalid_response")
                return fallback
            }
            return AIInsightCardResponse(
                kind: kind,
                title: narrative.title,
                body: narrative.body,
                highlights: highlights
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.warning("ai_insight_fallback kind=\(kind.rawValue) reason=provider_failure error=\(error)")
            return fallback
        }
    }

    private func loadDataset(kind: AIInsightKind, userId: UUID, on req: Request) async throws -> InsightDataset {
        var dataset = InsightDataset()
        if kind == .portfolio || kind == .summary {
            dataset.dashboard = try await req.application.dashboardService.dashboard(
                userId: userId, req: req, on: req.db
            )
            dataset.dashboardInsights = try await req.application.dashboardService.insights(
                userId: userId, req: req, on: req.db
            )
        }
        if kind == .expenses || kind == .summary {
            dataset.expenseReports = try await req.expensesService.getMonthlyReports(
                userId: userId, from: nil, to: nil, on: req.db
            )
            dataset.budgetPlanning = try await req.expensesService.getPillarPlanningSummaries(
                userId: userId, monthStart: Self.currentMonthStart(), on: req.db
            )
        }
        return dataset
    }

    struct InsightDataset: Encodable, Sendable {
        var dashboard: DashboardResponse?
        var dashboardInsights: DashboardInsightsResponse?
        var expenseReports: [BudgetMonthSummaryResponse]?
        var budgetPlanning: [PillarPlanningSummaryResponse]?
    }

    private struct AICardNarrative: Decodable {
        let title: String
        let body: String
    }

    private static func parseNarrative(_ json: String?) -> AICardNarrative? {
        guard let data = json?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AICardNarrative.self, from: data)
        else { return nil }
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = payload.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else { return nil }
        return AICardNarrative(title: String(title.prefix(80)), body: String(body.prefix(1200)))
    }

    static func highlights(for kind: AIInsightKind, dataset: InsightDataset) -> [AIInsightHighlight] {
        switch kind {
        case .portfolio:
            portfolioHighlights(dataset)
        case .expenses:
            expenseHighlights(dataset)
        case .summary:
            Array((portfolioHighlights(dataset) + expenseHighlights(dataset)).prefix(4))
        }
    }

    static func fallbackCard(
        kind: AIInsightKind,
        highlights: [AIInsightHighlight]
    ) -> AIInsightCardResponse {
        let copy = switch kind {
        case .portfolio:
            ("Portfolio snapshot", "Your latest portfolio snapshot is ready. The figures below come directly from your Norviq dashboard.")
        case .expenses:
            ("Spending snapshot", "Your latest spending snapshot is ready. The figures below come directly from your expense and budget records.")
        case .summary:
            ("Financial snapshot", "Your latest financial snapshot is ready. The figures below come directly from your portfolio, expense, and budget records.")
        }
        return AIInsightCardResponse(kind: kind, title: copy.0, body: copy.1, highlights: highlights)
    }

    private static func portfolioHighlights(_ dataset: InsightDataset) -> [AIInsightHighlight] {
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
            values.append(AIInsightHighlight(label: "Savings rate", value: formatPercent(insights.savingsRate)))
        }
        return values
    }

    private static func expenseHighlights(_ dataset: InsightDataset) -> [AIInsightHighlight] {
        guard let latest = dataset.expenseReports?.last else {
            let actual = dataset.budgetPlanning?.reduce(0) { $0 + $1.actualAmount } ?? 0
            return actual == 0 ? [] : [AIInsightHighlight(label: "Month spending", value: formatNumber(actual))]
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

    /// Number and month rendering live in `MoneyFormat`, shared with the
    /// messaging replies so both say a number the same way.
    private static func formatNumber(_ value: Double) -> String {
        MoneyFormat.number(value)
    }

    private static func formatPercent(_ value: Double) -> String {
        MoneyFormat.percent(value)
    }

    private static func trend(_ value: Double) -> String {
        MoneyFormat.trend(value)
    }

    private static func currentMonthStart() -> Date {
        MoneyFormat.currentMonthStart()
    }
}
