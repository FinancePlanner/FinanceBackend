import Fluent
import Foundation
import Vapor

protocol WhyMovedService: Sendable {
    func whyMoved(userId: UUID, on req: Request) async throws -> WhyMovedResponse
}

/// Joins the user's top-moving holdings with Hermes X-sentiment, market
/// context, and a cached one-sentence AI summary. Deterministic numbers; the
/// model only ever writes the sentence.
struct DefaultWhyMovedService: WhyMovedService {
    let statisticsRepo: any StatisticsRepository

    private static let sentimentDays = 7
    private static let moversPerSide = 3
    private static let aiCacheTTLSeconds = 3600

    func whyMoved(userId: UUID, on req: Request) async throws -> WhyMovedResponse {
        let overview = try await statisticsRepo.overviewStatistics(
            userId: userId,
            options: StatisticsQueryOptions(
                period: .oneMonth,
                top: 5,
                benchmarkSymbol: "SPY",
                asOfDate: nil
            ),
            on: req.db
        )
        let summaries = overview.importedStocks.stockSummaries
        let changed = summaries.filter { ($0.dailyChangePercent ?? 0) != 0 }

        let totalValue = overview.importedStocks.totalMarketValue
        let dailyChange = round2(summaries.reduce(0.0) { $0 + absoluteDailyChange(for: $1) })
        let previousTotal = totalValue - dailyChange
        let portfolioChangePercent: Double? = previousTotal == 0
            ? nil
            : round2((dailyChange / previousTotal) * 100)

        let gainers = changed
            .filter { ($0.dailyChangePercent ?? 0) > 0 }
            .sorted { absoluteDailyChange(for: $0) > absoluteDailyChange(for: $1) }
            .prefix(Self.moversPerSide)
        let losers = changed
            .filter { ($0.dailyChangePercent ?? 0) < 0 }
            .sorted { absoluteDailyChange(for: $0) < absoluteDailyChange(for: $1) }
            .prefix(Self.moversPerSide)
        let selected = Array(gainers) + Array(losers)

        var movers: [WhyMovedMover] = []
        for summary in selected {
            await movers.append(WhyMovedMover(
                symbol: summary.symbol,
                changePercent: round2(summary.dailyChangePercent ?? 0),
                contribution: absoluteDailyChange(for: summary),
                weightPercent: round2(summary.weightPercent),
                sentiment: loadSentiment(symbol: summary.symbol, on: req)
            ))
        }
        movers.sort { abs($0.contribution ?? 0) > abs($1.contribution ?? 0) }

        let sentimentSource = await loadSentimentSource(movers: movers, on: req)
        let context = await loadContext(on: req)
        let aiSummary = await loadAISummary(
            userId: userId,
            portfolioChangePercent: portfolioChangePercent,
            movers: movers,
            context: context,
            on: req
        )

        return WhyMovedResponse(
            asOf: ISO8601DateFormatter().string(from: Date()),
            portfolioChangePercent: portfolioChangePercent,
            portfolioChangeValue: movers.isEmpty ? nil : dailyChange,
            movers: movers,
            context: context,
            aiSummary: aiSummary,
            sentimentSource: sentimentSource
        )
    }

    /// Aggregates what the X-sentiment actually covers for this portfolio.
    /// Returns nil when no mover carried sentiment so the clients can hide
    /// the claim entirely rather than showing an empty one.
    private func loadSentimentSource(
        movers: [WhyMovedMover],
        on req: Request
    ) async -> WhyMovedSentimentSource? {
        let covered = movers.compactMap(\.sentiment)
        guard !covered.isEmpty else { return nil }

        let symbols = movers.filter { $0.sentiment != nil }.map(\.symbol)
        let lastPostAt = try? await TickerSentimentPost.query(on: req.db)
            .filter(\.$symbol ~~ symbols)
            .sort(\.$postedAt, .descending)
            .first()?
            .postedAt

        return WhyMovedSentimentSource(
            postsAnalyzed: covered.reduce(0) { $0 + $1.postCount },
            symbolsCovered: covered.count,
            windowDays: Self.sentimentDays,
            lastPostAt: lastPostAt.map { ISO8601DateFormatter().string(from: $0) } ?? nil
        )
    }

    // MARK: - Sentiment / context (all soft-fail)

    private func loadSentiment(symbol: String, on req: Request) async -> WhyMovedSentiment? {
        do {
            let sentiment = try await req.application.insightsService.tickerSentiment(
                symbol: symbol,
                days: Self.sentimentDays,
                limit: 0,
                on: req.db
            )
            guard sentiment.aggregate.postCount > 0 else { return nil }
            return WhyMovedSentiment(
                label: sentiment.aggregate.label,
                score: sentiment.aggregate.score,
                postCount: sentiment.aggregate.postCount
            )
        } catch {
            req.logger.debug("why_moved sentiment unavailable symbol=\(symbol) error=\(error)")
            return nil
        }
    }

    private func loadContext(on req: Request) async -> WhyMovedContext {
        var indices: [WhyMovedIndex] = []
        var topics: [WhyMovedTopic] = []
        if let overview = try? await req.application.marketDataService.marketOverview(on: req) {
            indices = overview.indices.prefix(4).map {
                WhyMovedIndex(symbol: $0.symbol, label: $0.label, changePercent: $0.changePct)
            }
        }
        if let summary = try? await req.application.insightsService.summary(days: Self.sentimentDays, on: req.db) {
            topics = summary.byTopic
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { WhyMovedTopic(topic: $0.key, count: $0.value) }
        }
        return WhyMovedContext(indices: indices, topics: topics)
    }

    // MARK: - AI sentence (cached, soft-fail)

    private struct CachedSummary: Codable {
        let text: String
        let generatedAt: String
    }

    private func loadAISummary(
        userId: UUID,
        portfolioChangePercent: Double?,
        movers: [WhyMovedMover],
        context: WhyMovedContext,
        on req: Request
    ) async -> WhyMovedAISummary? {
        guard !movers.isEmpty else { return nil }
        let cacheKey = "whymoved:ai:v1:\(userId.uuidString)"

        if let cached: CachedSummary = await req.application.aiResponseCache.get(cacheKey, on: req) {
            return WhyMovedAISummary(text: cached.text, generatedAt: cached.generatedAt)
        }

        do {
            try await AIDailyCap.enforce(
                req,
                userId: userId,
                unavailableReason: "AI summaries are temporarily disabled.",
                limitReachedReason: "Daily AI limit reached."
            )
        } catch {
            return nil
        }

        let facts = whyMovedFacts(
            portfolioChangePercent: portfolioChangePercent,
            movers: movers,
            context: context
        )
        let messages = [
            OpenAIMessage(role: "system", content: AIPrompt.system),
            OpenAIMessage(role: "user", content: AIPrompt.whyMovedUserPrompt(factsJSON: facts)),
        ]
        // Plan-routed, not on `app.openAIChatClient`. This endpoint has no Pro
        // gate, so a free user reaches it — and reaching it must not spend
        // credits. The per-user cache key above keeps the two plans' answers
        // from crossing over.
        let routed = await AIPlanRouting.client(for: userId, on: req)
        do {
            let message = try await routed.client.chat(
                messages: messages, tools: [], responseFormat: "json_object", on: req
            )
            guard
                let content = message.content,
                let data = content.data(using: .utf8),
                let parsed = try? JSONDecoder().decode([String: String].self, from: data),
                let text = parsed["text"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else {
                req.logger.warning("why_moved ai skipped reason=empty_or_invalid_response")
                return nil
            }
            let summary = CachedSummary(
                text: text,
                generatedAt: ISO8601DateFormatter().string(from: Date())
            )
            await req.application.aiResponseCache.set(
                cacheKey, value: summary, ttlSeconds: Self.aiCacheTTLSeconds, on: req
            )
            return WhyMovedAISummary(text: summary.text, generatedAt: summary.generatedAt)
        } catch {
            req.logger.warning("why_moved ai skipped reason=provider_failure error=\(error)")
            return nil
        }
    }

    private func whyMovedFacts(
        portfolioChangePercent: Double?,
        movers: [WhyMovedMover],
        context: WhyMovedContext
    ) -> String {
        var payload: [String: Any] = [:]
        if let portfolioChangePercent {
            payload["portfolioChangePercent"] = portfolioChangePercent
        }
        payload["movers"] = movers.map { mover -> [String: Any] in
            var entry: [String: Any] = [
                "symbol": mover.symbol,
                "changePercent": mover.changePercent,
            ]
            if let sentiment = mover.sentiment {
                entry["sentimentLabel"] = sentiment.label
                entry["postCount"] = sentiment.postCount
            }
            return entry
        }
        payload["indices"] = context.indices.map {
            ["label": $0.label, "changePercent": $0.changePercent] as [String: Any]
        }
        payload["topics"] = context.topics.map(\.topic)
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Small local helpers (duplicated from DashboardService privates)

    private func absoluteDailyChange(for summary: StockStatisticsSummary) -> Double {
        let percent = summary.dailyChangePercent ?? 0
        let ratio = 1 + (percent / 100)
        guard ratio != 0 else { return 0 }
        let previousValue = summary.marketValue / ratio
        return round2(summary.marketValue - previousValue)
    }

    private func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
