import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Builds the text for the data commands.
///
/// Every function here answers from the database and returns markdown. No model
/// is involved: a question the data answers exactly should not cost a model call
/// or a turn from the monthly allowance. `MessagingCommands` owns dispatch; this
/// file owns wording.
///
/// These call the same services `AIReadToolRegistry.execute` calls, so a command
/// and Q always see the same numbers. They call the services directly rather
/// than going through `execute`, which returns JSON — decoding our own JSON back
/// into a struct just to print it would buy nothing.
///
/// No entitlement checks. `GET /dashboard`, `NewsController`, and
/// `InsightsController.summary` are all ungated today, so gating here would make
/// the bot *stricter* than the app rather than safer. `ThesisWatchService`
/// degrades itself for free users and needs no help.
enum MessagingCommandReplies {
    /// Rows past this get dropped. Telegram's own cap is 4096 characters and the
    /// client chunks, but a wall of holdings is not an answer.
    private static let listLimit = 6

    // MARK: - /finance

    static func finance(userId: UUID, on req: Request) async throws -> String {
        async let dashboardValue = req.application.dashboardService.dashboard(
            userId: userId, req: req, on: req.db
        )
        async let insightsValue = req.application.dashboardService.insights(
            userId: userId, req: req, on: req.db
        )
        let dashboard = try await dashboardValue
        let insights = try await insightsValue

        let health = insights.financialHealth
        var lines = [
            "**Your finances**",
            "",
            "Portfolio  **\(MoneyFormat.number(dashboard.totalValue))**  "
                + "\(MoneyFormat.arrow(dashboard.dailyChange)) \(MoneyFormat.percent(dashboard.dailyChangePercent)) today",
            "Cash buffer  \(MoneyFormat.number(insights.cashBuffer))",
            "Savings rate  \(MoneyFormat.percent(insights.savingsRate))",
            "Health  \(health.score)/\(health.maxScore) — \(readable(health.status))",
        ]
        if insights.budgetStreak > 0 {
            lines.append("Budget streak  \(insights.budgetStreak) month\(insights.budgetStreak == 1 ? "" : "s")")
        }
        lines.append("")
        lines.append("_/portfolio, /budget, /expenses for detail._")
        return lines.joined(separator: "\n")
    }

    // MARK: - /portfolio

    static func portfolio(userId: UUID, on req: Request) async throws -> String {
        let dashboard = try await req.application.dashboardService.dashboard(
            userId: userId, req: req, on: req.db
        )

        guard dashboard.totalValue != 0 || !dashboard.topPerformers.isEmpty else {
            return "**Portfolio**\n\nNo holdings yet. Add one in the app and this fills in."
        }

        var lines = [
            "**Portfolio**  \(MoneyFormat.number(dashboard.totalValue))",
            "\(MoneyFormat.arrow(dashboard.dailyChange)) \(MoneyFormat.signed(dashboard.dailyChange)) "
                + "(\(MoneyFormat.percent(dashboard.dailyChangePercent))) today",
        ]

        if !dashboard.topPerformers.isEmpty {
            lines.append("")
            lines.append("**Leading**")
            lines.append(contentsOf: dashboard.topPerformers.prefix(3).map(performer))
        }
        if !dashboard.bottomPerformers.isEmpty {
            lines.append("")
            lines.append("**Lagging**")
            lines.append(contentsOf: dashboard.bottomPerformers.prefix(3).map(performer))
        }
        if !dashboard.sectorAllocation.isEmpty {
            lines.append("")
            lines.append("**Sectors**")
            lines.append(contentsOf: dashboard.sectorAllocation.prefix(listLimit).map {
                "\($0.sector) — \(MoneyFormat.percent($0.percent))"
            })
        }
        return lines.joined(separator: "\n")
    }

    private static func performer(_ item: DashboardPerformerDTO) -> String {
        "\(item.symbol)  \(MoneyFormat.arrow(item.changePercent)) \(MoneyFormat.percent(item.changePercent))"
    }

    // MARK: - /budget

    static func budget(userId: UUID, on req: Request) async throws -> String {
        let summaries = try await req.expensesService.getPillarPlanningSummaries(
            userId: userId,
            monthStart: MoneyFormat.currentMonthStart(),
            on: req.db
        )
        guard !summaries.isEmpty else {
            return "**Budget**\n\nNo plan for this month yet. Set targets in the app and this fills in."
        }

        var lines = ["**Budget — this month**", ""]
        for summary in summaries {
            let remaining = summary.targetAmount - summary.actualAmount
            let state = remaining < 0
                ? "**\(MoneyFormat.number(-remaining)) over**"
                : "\(MoneyFormat.number(remaining)) left"
            lines.append(
                "\(pillarName(summary.pillar))  "
                    + "\(MoneyFormat.number(summary.actualAmount)) / \(MoneyFormat.number(summary.targetAmount))  — \(state)"
            )
        }

        let target = summaries.reduce(0) { $0 + $1.targetAmount }
        let actual = summaries.reduce(0) { $0 + $1.actualAmount }
        lines.append("")
        lines.append("Total  \(MoneyFormat.number(actual)) / \(MoneyFormat.number(target))")
        return lines.joined(separator: "\n")
    }

    // MARK: - /expenses

    static func expenses(userId: UUID, on req: Request) async throws -> String {
        let monthStart = MoneyFormat.currentMonthStart()
        async let recentValue = req.expensesService.getExpenses(
            userId: userId, from: monthStart, to: nil, limit: listLimit, cursor: nil, on: req.db
        )
        async let reportsValue = req.expensesService.getMonthlyReports(
            userId: userId, from: nil, to: nil, on: req.db
        )
        let recent = try await recentValue
        let reports = try await reportsValue

        var lines = ["**Expenses — this month**"]
        if let current = reports.last {
            lines.append("")
            lines.append("Spent  **\(MoneyFormat.number(current.actual))** of \(MoneyFormat.number(current.planned)) planned")
        }

        if recent.items.isEmpty {
            lines.append("")
            lines.append("Nothing logged this month yet.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("**Latest**")
        for item in recent.items {
            lines.append("\(item.occurredOn)  \(item.title) — \(MoneyFormat.number(item.amount))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - /news

    static func news(userId: UUID, on req: Request) async throws -> String {
        // Sentiment first for the shape of the week, then headlines against the
        // user's own positions. Both read stored data; neither calls a provider.
        async let summaryValue = req.application.insightsService.summary(days: 7, on: req.db)
        async let feedValue = req.application.thesisWatchService.feed(
            userId: userId, scope: .forYou, sector: nil, limit: listLimit, cursor: nil, on: req.db
        )
        let summary = try await summaryValue
        let feed = try await feedValue

        var lines = ["**News**"]
        if summary.totalEvents > 0 {
            let topics = summary.byTopic
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key) (\($0.value))" }
                .joined(separator: ", ")
            lines.append("")
            lines.append("\(summary.totalEvents) signals in \(summary.windowDays) days\(topics.isEmpty ? "" : " — \(topics)")")
        }

        guard !feed.items.isEmpty else {
            lines.append("")
            lines.append("Nothing on your holdings right now.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("**On your holdings**")
        for story in feed.items {
            let tickers = story.symbols.prefix(3).joined(separator: ", ")
            lines.append("")
            lines.append("[\(story.headline)](\(story.url))")
            var footnote = tickers.isEmpty ? "" : tickers
            if let source = story.source, !source.isEmpty {
                footnote = footnote.isEmpty ? source : "\(footnote) · \(source)"
            }
            if !footnote.isEmpty {
                lines.append("_\(footnote)_")
            }
            // Pro-only enrichment; free feeds simply have none. See ThesisWatchService.
            if let why = story.whyItMatters, !why.isEmpty {
                lines.append(why)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Wording

    private static func readable(_ status: FinancialHealthStatus) -> String {
        switch status {
        case .atRisk: "at risk"
        case .needsAttention: "needs attention"
        case .healthy: "healthy"
        case .excellent: "excellent"
        }
    }

    /// `BudgetPillar` is a string-backed struct, and its raw values are camelCase
    /// identifiers (`futureYou`) rather than anything meant to be read.
    private static func pillarName(_ pillar: BudgetPillar) -> String {
        switch pillar {
        case .fundamentals: "Fundamentals"
        case .futureYou: "Future you"
        case .fun: "Fun"
        default: pillar.rawValue
        }
    }
}
