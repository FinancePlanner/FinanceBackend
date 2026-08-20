import Fluent
import Foundation
import Vapor

struct SentimentSyncSummary: Content, Sendable {
    var asOfDate: String
    var symbolsConsidered: Int
    var symbolsIngested: Int
    var symbolsFailed: Int
    var postsFetched: Int
    var postsInserted: Int
    var rowsUpserted: Int
    var themesGenerated: Int
    var themesSkipped: Int
}

protocol SentimentAggregationServing: Sendable {
    func runDailyAggregation(on req: Request) async throws -> SentimentSyncSummary
}

/// Walks the symbol universe once a day, pulls posts, scores them, and writes
/// one `symbol_sentiment_daily` row per symbol.
///
/// Kept separate from `DefaultInsightsService.syncFromHermes`, which pulls the
/// raw firehose every 15 minutes. Merging them would tie the cheap high-frequency
/// pull to the expensive once-a-day LLM pass, and one failing would take the
/// other down.
struct DefaultSentimentAggregationService: SentimentAggregationServing {
    let provider: any InsightsProvider
    let insightsRepo: any InsightsRepository
    let sentimentRepo: any SentimentRepository
    let resolver: SentimentUniverseResolver
    let themeService: (any SentimentThemeGenerating)?
    let windowDays: Int
    /// How many symbols go into one provider call.
    let batchSize: Int
    /// Posts requested per symbol per run.
    let postsPerSymbol: Int
    /// Upper bound on LLM theme calls in a single run, on top of the daily cap.
    let maxThemeSymbols: Int

    func runDailyAggregation(on req: Request) async throws -> SentimentSyncSummary {
        guard provider.isEnabled else {
            throw Abort(.serviceUnavailable, reason: "Insights provider is disabled.")
        }

        let asOfDate = SentimentDate.today()
        let capturedAt = Date()
        let since = capturedAt.addingTimeInterval(-Double(windowDays) * 86400)

        let universe = try await resolver.resolve(on: req.db)
        var summary = SentimentSyncSummary(
            asOfDate: asOfDate,
            symbolsConsidered: universe.count,
            symbolsIngested: 0,
            symbolsFailed: 0,
            postsFetched: 0,
            postsInserted: 0,
            rowsUpserted: 0,
            themesGenerated: 0,
            themesSkipped: 0
        )

        // Group by tier so every symbol in a provider call wants the same feeds.
        let byTier = Dictionary(grouping: universe, by: \.tier)
        var ingestedSymbols: [String] = []
        var themeCandidates: [(symbol: String, row: SymbolSentimentDaily)] = []

        for tier in SentimentTier.allCases.sorted(by: { $0.priority < $1.priority }) {
            guard let entries = byTier[tier], !entries.isEmpty else { continue }
            let symbols = entries.map(\.symbol)

            for chunk in symbols.chunked(into: batchSize) {
                let batches: [SymbolPostBatch]
                do {
                    batches = try await provider.fetchSymbolPosts(
                        symbols: chunk,
                        sources: tier.sources,
                        days: windowDays,
                        limit: postsPerSymbol,
                        on: req
                    )
                } catch {
                    summary.symbolsFailed += chunk.count
                    req.logger.warning(
                        "sentiment.aggregate batch failed tier=\(tier.rawValue) count=\(chunk.count) error=\(String(describing: error))"
                    )
                    continue
                }

                for batch in batches {
                    do {
                        let outcome = try await persist(
                            batch: batch,
                            tier: tier,
                            asOfDate: asOfDate,
                            capturedAt: capturedAt,
                            since: since,
                            on: req
                        )
                        summary.postsFetched += batch.posts.count
                        summary.postsInserted += outcome.postsInserted
                        summary.rowsUpserted += 1
                        summary.symbolsIngested += 1
                        ingestedSymbols.append(batch.symbol)
                        if tier.allowsLLMThemes, outcome.row.postCount > 0 {
                            themeCandidates.append((batch.symbol, outcome.row))
                        }
                    } catch {
                        summary.symbolsFailed += 1
                        req.logger.warning(
                            "sentiment.aggregate persist failed symbol=\(batch.symbol) error=\(String(describing: error))"
                        )
                    }
                }
            }
        }

        try await sentimentRepo.markIngested(symbols: ingestedSymbols, at: capturedAt, on: req.db)

        let themeOutcome = await generateThemes(
            candidates: themeCandidates,
            since: since,
            on: req
        )
        summary.themesGenerated = themeOutcome.generated
        summary.themesSkipped = themeOutcome.skipped

        return summary
    }

    // MARK: - Per-symbol persistence

    private struct PersistOutcome {
        var postsInserted: Int
        var row: SymbolSentimentDaily
    }

    private func persist(
        batch: SymbolPostBatch,
        tier _: SentimentTier,
        asOfDate: String,
        capturedAt: Date,
        since: Date,
        on req: Request
    ) async throws -> PersistOutcome {
        let scored = batch.posts.map { post in
            (post: post, scored: SentimentScoring.score(post))
        }

        let models = scored.map { entry in
            TickerSentimentPost(
                dedupeKey: entry.post.dedupeKey,
                symbol: entry.post.symbol,
                author: entry.post.author,
                authorHandle: entry.post.authorHandle,
                text: entry.post.text,
                url: entry.post.url,
                sentimentLabel: entry.scored.label,
                sentimentScore: entry.scored.score,
                confidence: entry.scored.confidence,
                postedAt: entry.post.postedAt,
                source: entry.post.source
            )
        }
        let inserted = try await insightsRepo.insertNewTickerPosts(models, on: req.db)

        // Aggregate over the stored window, not just this run's haul, so a run
        // that returns nothing does not erase a symbol's reading.
        let windowPosts = try await insightsRepo.tickerPosts(
            symbol: batch.symbol,
            since: since,
            limit: postsPerSymbol,
            on: req.db
        )
        let aggregateInput = windowPosts.map { post in
            (
                scored: SentimentScoring.Scored(
                    score: post.sentimentScore,
                    label: post.sentimentLabel,
                    confidence: post.confidence
                ),
                source: post.resolvedSource
            )
        }
        let aggregate = SentimentAggregator.aggregate(posts: aggregateInput)

        let history = try await sentimentRepo.dailyHistory(
            symbol: batch.symbol,
            windowDays: windowDays,
            limit: 31,
            on: req.db
        )
        let priorRows = history.filter { $0.asOfDate < asOfDate }
        let baseline = priorRows.prefix(30).map(\.postCount)
        let yesterday = priorRows.first

        let row = SymbolSentimentDaily(
            symbol: batch.symbol,
            asOfDate: asOfDate,
            windowDays: windowDays,
            score: aggregate.score,
            label: aggregate.label,
            confidence: aggregate.confidence,
            postCount: aggregate.postCount,
            positiveCount: aggregate.positiveCount,
            neutralCount: aggregate.neutralCount,
            negativeCount: aggregate.negativeCount,
            sourceCounts: aggregate.sourceCounts,
            volumeZ: SentimentAggregator.volumeZScore(
                todayCount: aggregate.postCount,
                baseline: Array(baseline)
            ),
            delta1d: SentimentAggregator.delta(today: aggregate.score, yesterday: yesterday?.score),
            capturedAt: capturedAt
        )

        try await sentimentRepo.upsertDaily(row, on: req.db)
        return PersistOutcome(postsInserted: inserted, row: row)
    }

    // MARK: - Themes

    private func generateThemes(
        candidates: [(symbol: String, row: SymbolSentimentDaily)],
        since: Date,
        on req: Request
    ) async -> (generated: Int, skipped: Int) {
        guard let themeService else { return (0, candidates.count) }

        // Loudest symbols first: if the cap bites, spend the budget where there
        // is the most to summarize.
        let ordered = candidates.sorted { $0.row.postCount > $1.row.postCount }
        var generated = 0
        var skipped = 0

        for candidate in ordered {
            guard generated < maxThemeSymbols else {
                skipped += 1
                continue
            }
            do {
                let posts = try await insightsRepo.tickerPosts(
                    symbol: candidate.symbol,
                    since: since,
                    limit: 40,
                    on: req.db
                )
                guard !posts.isEmpty else {
                    skipped += 1
                    continue
                }
                guard let payload = try await themeService.generateThemes(
                    symbol: candidate.symbol,
                    posts: posts,
                    on: req
                ) else {
                    skipped += 1
                    continue
                }

                candidate.row.themes = payload
                candidate.row.themesGeneratedAt = Date()
                try await sentimentRepo.upsertDaily(candidate.row, on: req.db)
                generated += 1
            } catch {
                // A theme failure must never cost the symbol its score — the row
                // is already written.
                skipped += 1
                req.logger.warning(
                    "sentiment.themes failed symbol=\(candidate.symbol) error=\(String(describing: error))"
                )
            }
        }

        return (generated, skipped)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
