import Foundation
import StockPlanShared
import Vapor

protocol AIViewSummaryService: Sendable {
    func generate(
        scope: AIViewScope,
        userId: UUID,
        options: AIViewSummaryOptions,
        on req: Request
    ) async throws -> AIViewSummaryResponse
}

/// Per-scope extras the client may send. Everything is optional and every
/// absence has a server-side default, because a 400 here would show up as a
/// sheet that retries forever.
struct AIViewSummaryOptions: Sendable {
    var refresh: Bool = false
    var country: MacroCountry?
    var jurisdiction: TaxJurisdiction?
    var taxYear: Int?

    static let none = AIViewSummaryOptions()
}

/// One generated summary of one screen.
///
/// Same split as `DefaultAIInsightsService`: the server selects the facts and
/// computes every displayed number; the model only writes the title and the
/// sentences. A hallucinated figure cannot reach the screen because the
/// highlights never pass through the model.
struct DefaultAIViewSummaryService: AIViewSummaryService {
    let client: any OpenAIChatClient

    /// An hour. Long enough that a day of tapping around the app costs a
    /// handful of calls rather than one per tap, short enough that the prose
    /// still describes today.
    static let cacheTTLSeconds = 3600

    /// The `v1` segment is not decoration: when the prompt or the highlight
    /// selection changes, bumping it retires every stale entry at once instead
    /// of serving a mix of old and new shapes for an hour.
    static func cacheKey(scope: AIViewScope, userId: UUID) -> String {
        "viewsummary:ai:v1:\(scope.rawValue):\(userId.uuidString)"
    }

    func generate(
        scope: AIViewScope,
        userId: UUID,
        options: AIViewSummaryOptions,
        on req: Request
    ) async throws -> AIViewSummaryResponse {
        // A failed load must not fail the screen. This button sits in a toolbar
        // and its sheet opens on tap, so an error here renders as a dead screen
        // over data the user can already see perfectly well behind it. The
        // markets scope makes this concrete: `marketOverview` throws
        // "Market overview requires the FMP provider", and FMP already refuses
        // some endpoints on the current plan.
        //
        // Degrade the way the rest of this file does -- keep whatever is true,
        // drop what is not. With no facts there are no highlights and nothing
        // worth asking the model, so return the canned card without spending a
        // call or a slice of the daily allowance.
        let dataset: ViewDataset
        do {
            dataset = try await loadDataset(
                scope: scope, userId: userId, options: options, on: req
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.warning(
                "ai_view_summary_dataset_failed scope=\(scope.rawValue) error=\(error)"
            )
            return Self.fallbackSummary(scope: scope, highlights: [])
        }

        let highlights = Self.highlights(for: scope, dataset: dataset)
        let key = Self.cacheKey(scope: scope, userId: userId)

        // Read the cache before charging the daily allowance. A hit did not
        // spend an upstream call, so it must not spend a request either --
        // otherwise opening the same screen twice would cost the user quota for
        // an answer they already had. `WhyMovedService` orders it the same way.
        //
        // Highlights are recomputed above even on a hit: an hour-old sentence
        // beside current figures is fine, an hour-old figure is not.
        if !options.refresh,
           let cached: CachedViewSummary = await req.application.aiResponseCache.get(key, on: req)
        {
            return AIViewSummaryResponse(
                scope: scope,
                title: cached.title,
                body: cached.body,
                highlights: highlights,
                generatedAt: cached.generatedAt,
                isCached: true
            )
        }

        try await AIDailyCap.enforce(
            req,
            userId: userId,
            unavailableReason: "AI summaries are temporarily unavailable.",
            limitReachedReason: "You've reached today's summary limit. Try again tomorrow.",
            bucket: AICostControls.viewSummaryBucket,
            limit: AICostControls.viewSummaryDailyLimit
        )

        let fallback = Self.fallbackSummary(scope: scope, highlights: highlights)
        let facts = try AIReadToolRegistry.encode(dataset)
        let messages = [
            OpenAIMessage(role: "system", content: AIPrompt.system),
            OpenAIMessage(
                role: "user",
                content: AIPrompt.viewSummaryUserPrompt(scope: scope, factsJSON: facts)
            ),
        ]

        do {
            let message = try await client.chat(
                messages: messages, tools: [], responseFormat: "json_object", on: req
            )
            guard let narrative = Self.parseNarrative(message.content) else {
                req.logger.warning(
                    "ai_view_summary_fallback scope=\(scope.rawValue) reason=empty_or_invalid_response"
                )
                return fallback
            }
            let now = Date()
            await req.application.aiResponseCache.set(
                key,
                value: CachedViewSummary(
                    title: narrative.title, body: narrative.body, generatedAt: now
                ),
                ttlSeconds: Self.cacheTTLSeconds,
                on: req
            )
            return AIViewSummaryResponse(
                scope: scope,
                title: narrative.title,
                body: narrative.body,
                highlights: highlights,
                generatedAt: now
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The numbers are already computed and correct, so a provider
            // outage costs the sentence, not the screen. Deliberately not
            // cached: a failure must not suppress the next hour's attempt.
            req.logger.warning(
                "ai_view_summary_fallback scope=\(scope.rawValue) reason=provider_failure error=\(error)"
            )
            return fallback
        }
    }

    // MARK: - Datasets

    /// The facts each screen is summarised from.
    ///
    /// Optional throughout because each scope loads only what it needs; the
    /// encoder omits the rest, so the model sees a small object rather than a
    /// mostly-null one.
    struct ViewDataset: Encodable, Sendable {
        var insight: AIInsightDataset?
        var cryptoHoldings: [CryptoPortfolioItemResponse]?
        var cryptoQuotes: [CryptoQuoteShortResponse]?
        var market: MarketOverviewResponse?
        var inflation: InflationSnapshotResponse?
        var economy: EconomyHubResponse?
        var policyWatch: PolicyWatchResponse?
        var tax: TaxDashboardResponse?
    }

    private func loadDataset(
        scope: AIViewScope,
        userId: UUID,
        options: AIViewSummaryOptions,
        on req: Request
    ) async throws -> ViewDataset {
        var dataset = ViewDataset()

        switch scope {
        case .home, .portfolio:
            var insight = AIInsightDataset()
            insight.dashboard = try await req.application.dashboardService.dashboard(
                userId: userId, req: req, on: req.db
            )
            insight.dashboardInsights = try await req.application.dashboardService.insights(
                userId: userId, req: req, on: req.db
            )
            dataset.insight = insight

        case .expenses:
            var insight = AIInsightDataset()
            insight.expenseReports = try await req.expensesService.getMonthlyReports(
                userId: userId, from: nil, to: nil, on: req.db
            )
            insight.budgetPlanning = try await req.expensesService.getPillarPlanningSummaries(
                userId: userId, monthStart: MoneyFormat.currentMonthStart(), on: req.db
            )
            dataset.insight = insight

        case .reports:
            // The same records the expenses screen reads, but the reports screen
            // is about the trend across months rather than this month's plan --
            // so it gets the history and no current-month planning.
            var insight = AIInsightDataset()
            insight.expenseReports = try await req.expensesService.getMonthlyReports(
                userId: userId, from: nil, to: nil, on: req.db
            )
            dataset.insight = insight

        case .crypto:
            async let holdings = req.application.cryptoService.listPortfolio(
                userId: userId, on: req.db
            )
            async let quotes = req.application.cryptoService.batchQuotes(short: true, on: req)
            dataset.cryptoHoldings = try await holdings
            dataset.cryptoQuotes = try await quotes

        case .markets:
            dataset.market = try await req.application.marketDataService.marketOverview(on: req)

        case .economy:
            let country = options.country ?? .us
            async let inflation = req.application.macroService.currentInflation(
                country: country, on: req
            )
            async let economy = req.application.macroService.economy(country: country, on: req)
            async let policy = req.application.macroService.policyWatch(country: country, on: req)
            dataset.inflation = try await inflation
            dataset.economy = try await economy
            dataset.policyWatch = try await policy

        case .tax:
            // Defaults mirror `TaxController.dashboard` exactly. Never a 400 on
            // a missing parameter: the client opens this sheet from a toolbar
            // button that carries no context, and a 400 would render as a
            // permanent error on a screen that has perfectly good data.
            dataset.tax = try await req.application.taxService.dashboard(
                userId: userId,
                jurisdiction: options.jurisdiction ?? .unitedStates,
                taxYear: options.taxYear ?? Self.currentTaxYear(),
                on: req.db
            )
        }

        return dataset
    }

    // MARK: - Highlights

    /// Every number a user reads, computed here. See `AIHighlightBuilders`.
    static func highlights(for scope: AIViewScope, dataset: ViewDataset) -> [AIInsightHighlight] {
        switch scope {
        case .home:
            AIHighlightBuilders.combined(dataset.insight ?? AIInsightDataset())
        case .portfolio:
            AIHighlightBuilders.portfolio(dataset.insight ?? AIInsightDataset())
        case .expenses, .reports:
            AIHighlightBuilders.expenses(dataset.insight ?? AIInsightDataset())
        case .crypto:
            cryptoHighlights(dataset)
        case .markets:
            marketHighlights(dataset)
        case .economy:
            economyHighlights(dataset)
        case .tax:
            taxHighlights(dataset)
        }
    }

    /// Holdings valued at the live quote, falling back to the average buy price
    /// for anything the quote batch did not cover — a missing quote should cost
    /// accuracy on one coin, not blank the whole card.
    private static func cryptoHighlights(_ dataset: ViewDataset) -> [AIInsightHighlight] {
        guard let holdings = dataset.cryptoHoldings, !holdings.isEmpty else { return [] }
        let prices = Dictionary(
            (dataset.cryptoQuotes ?? []).map { ($0.symbol.uppercased(), $0.price) },
            uniquingKeysWith: { first, _ in first }
        )
        var value = 0.0
        var cost = 0.0
        for holding in holdings {
            let price = prices[holding.symbol.uppercased()] ?? holding.averageBuyPrice
            value += holding.quantity * price
            cost += holding.quantity * holding.averageBuyPrice
        }
        var values = [
            AIInsightHighlight(label: "Holdings", value: "\(holdings.count)"),
            AIInsightHighlight(label: "Crypto value", value: AIHighlightBuilders.formatNumber(value)),
        ]
        guard cost > 0 else { return values }
        let changePercent = ((value - cost) / cost) * 100
        values.append(AIInsightHighlight(
            label: "Since purchase",
            value: AIHighlightBuilders.formatPercent(changePercent),
            trend: AIHighlightBuilders.trend(changePercent)
        ))
        return values
    }

    private static func marketHighlights(_ dataset: ViewDataset) -> [AIInsightHighlight] {
        guard let indices = dataset.market?.indices else { return [] }
        return indices.prefix(3).map {
            AIInsightHighlight(
                label: $0.label,
                value: AIHighlightBuilders.formatPercent($0.changePct),
                trend: AIHighlightBuilders.trend($0.changePct)
            )
        }
    }

    private static func economyHighlights(_ dataset: ViewDataset) -> [AIInsightHighlight] {
        guard let inflation = dataset.inflation else { return [] }
        var values = [
            AIInsightHighlight(
                label: inflation.headline.name,
                value: AIHighlightBuilders.formatPercent(inflation.headline.nowValue)
            ),
        ]
        if let official = inflation.headline.officialValue {
            values.append(AIInsightHighlight(
                label: "Official",
                value: AIHighlightBuilders.formatPercent(official)
            ))
        }
        return values
    }

    private static func taxHighlights(_ dataset: ViewDataset) -> [AIInsightHighlight] {
        guard let summary = dataset.tax?.summary else { return [] }
        return [
            AIInsightHighlight(
                label: "Estimated liability",
                value: AIHighlightBuilders.formatNumber(
                    Self.double(summary.realizedEstimatedLiability.amount)
                )
            ),
            AIInsightHighlight(
                label: "Harvestable losses",
                value: AIHighlightBuilders.formatNumber(
                    Self.double(summary.harvestableLosses.amount)
                )
            ),
        ]
    }

    // MARK: - Fallback

    /// Costs nothing and is built before the call, so a provider failure returns
    /// verified numbers with plain copy rather than an error.
    static func fallbackSummary(
        scope: AIViewScope,
        highlights: [AIInsightHighlight]
    ) -> AIViewSummaryResponse {
        AIViewSummaryResponse(
            scope: scope,
            title: "\(scope.displayName.capitalizedFirst) snapshot",
            body: "Your latest \(scope.displayName) snapshot is ready. "
                + "The figures below come directly from your Norviq records.",
            highlights: highlights
        )
    }

    // MARK: - Parsing

    private struct Narrative: Decodable {
        let title: String
        let body: String
    }

    private static func parseNarrative(_ json: String?) -> Narrative? {
        guard let data = json?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Narrative.self, from: data)
        else { return nil }
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = payload.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else { return nil }
        return Narrative(title: String(title.prefix(80)), body: String(body.prefix(1200)))
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    /// Mirrors `TaxController`'s private helper of the same name.
    private static func currentTaxYear() -> Int {
        Calendar(identifier: .gregorian).component(.year, from: Date())
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
