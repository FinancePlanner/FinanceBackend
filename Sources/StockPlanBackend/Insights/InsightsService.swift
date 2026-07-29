import Fluent
import Foundation
import Vapor

protocol InsightsService: Sendable {
    var isEnabled: Bool { get }
    func summary(days: Int, on db: any Database) async throws -> InsightsSummaryResponse
    func topic(_ topic: String, days: Int, limit: Int, on db: any Database) async throws -> InsightsTopicResponse
    func sentiment(topic: String?, on db: any Database) async throws -> InsightsSentimentResponse
    func netWorth(on db: any Database) async throws -> InsightsNetWorthResponse
    func tickerSentiment(symbol: String, days: Int, limit: Int, on db: any Database) async throws -> TickerSentimentResponse
    func syncFromHermes(on req: Request) async throws -> InsightsSyncSummary
}

struct DefaultInsightsService: InsightsService {
    let repo: any InsightsRepository
    let provider: any InsightsProvider
    let tickerLimit: Int
    let pinnedTickers: [String]

    init(
        repo: any InsightsRepository = DatabaseInsightsRepository(),
        provider: any InsightsProvider = DisabledInsightsProvider(),
        tickerLimit: Int = 25,
        pinnedTickers: [String] = []
    ) {
        self.repo = repo
        self.provider = provider
        self.tickerLimit = max(1, tickerLimit)
        self.pinnedTickers = pinnedTickers.map { $0.uppercased() }
    }

    var isEnabled: Bool {
        provider.isEnabled
    }

    // MARK: - Reads (Postgres only; Hermes never sits on the request path)

    func summary(days: Int, on db: any Database) async throws -> InsightsSummaryResponse {
        let since = windowStart(days: days)
        let counts = try await repo.topicCounts(since: since, on: db)
        let latest = try await repo.recentEvents(topic: nil, since: since, limit: 10, on: db)
        return InsightsSummaryResponse(
            windowDays: days,
            totalEvents: counts.values.reduce(0, +),
            byTopic: counts,
            latestEvents: latest.map(makeEventResponse)
        )
    }

    func topic(_ topic: String, days: Int, limit: Int, on db: any Database) async throws -> InsightsTopicResponse {
        let since = windowStart(days: days)
        let events = try await repo.recentEvents(topic: topic, since: since, limit: limit, on: db)
        return InsightsTopicResponse(
            topic: topic,
            windowDays: days,
            count: events.count,
            events: events.map(makeEventResponse)
        )
    }

    func sentiment(topic: String?, on db: any Database) async throws -> InsightsSentimentResponse {
        let scope = topic == nil ? "overall" : "topic"
        guard let snapshot = try await repo.latestSentimentSnapshot(scope: scope, scopeKey: topic, on: db) else {
            throw Abort(.notFound, reason: "No sentiment snapshot available yet. The Hermes sync has not run for this scope.")
        }
        return InsightsSentimentResponse(
            scope: snapshot.scope,
            topic: snapshot.scopeKey,
            windowDays: snapshot.windowDays,
            averageScore: snapshot.averageScore,
            label: snapshot.label,
            eventCount: snapshot.eventCount,
            positiveCount: snapshot.positiveCount,
            neutralCount: snapshot.neutralCount,
            negativeCount: snapshot.negativeCount,
            capturedAt: formatISO(snapshot.capturedAt)
        )
    }

    func netWorth(on db: any Database) async throws -> InsightsNetWorthResponse {
        let snapshots = try await repo.netWorthSnapshots(limit: 30, on: db)
        let points = snapshots.map { NetWorthPointResponse(value: $0.totalValue, capturedAt: formatISO($0.capturedAt)) }
        return InsightsNetWorthResponse(latest: points.first, history: points)
    }

    func tickerSentiment(symbol: String, days: Int, limit: Int, on db: any Database) async throws -> TickerSentimentResponse {
        let since = windowStart(days: days)
        let posts = try await repo.tickerPosts(symbol: symbol, since: since, limit: limit, on: db)
        let scores = posts.compactMap(\.sentimentScore)
        let averageScore = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        return TickerSentimentResponse(
            symbol: symbol,
            windowDays: days,
            aggregate: TickerSentimentAggregate(
                label: sentimentLabel(forScore: averageScore, postLabels: posts.map(\.sentimentLabel)),
                score: averageScore,
                postCount: posts.count
            ),
            posts: posts.map { post in
                TickerPostResponse(
                    author: post.author,
                    authorHandle: post.authorHandle,
                    text: post.text,
                    url: post.url,
                    sentimentLabel: post.sentimentLabel,
                    sentimentScore: post.sentimentScore,
                    confidence: post.confidence,
                    postedAt: formatISO(post.postedAt)
                )
            }
        )
    }

    // MARK: - Sync (called by HermesSyncJob)

    func syncFromHermes(on req: Request) async throws -> InsightsSyncSummary {
        guard provider.isEnabled else {
            throw Abort(.serviceUnavailable, reason: "Insights provider is disabled.")
        }

        let eventsInserted = try await syncEvents(on: req)
        let snapshotsUpserted = try await syncSentimentSnapshots(on: req)
        let netWorthInserted = try await syncNetWorth(on: req)
        let tickerPosts = await syncTickerPosts(on: req)

        return InsightsSyncSummary(
            eventsInserted: eventsInserted,
            snapshotsUpserted: snapshotsUpserted,
            tickerPostsInserted: tickerPosts.inserted,
            netWorthInserted: netWorthInserted,
            tickerPostsFetched: tickerPosts.fetched,
            tickerPostsNewestAt: tickerPosts.newestAt,
            tickerSymbolsFailed: tickerPosts.symbolsFailed
        )
    }
}

private extension DefaultInsightsService {
    func syncEvents(on req: Request) async throws -> Int {
        let response = try await provider.fetchEvents(days: 7, limit: 200, on: req)
        let models = response.events.compactMap { event -> InsightEvent? in
            guard let topic = event.topic, !topic.isEmpty else { return nil }
            let observedAt = parseHermesTimestamp(event.observedAt)
                ?? parseHermesTimestamp(event.ingestedAt)
                ?? Date()
            return InsightEvent(
                dedupeKey: event.eventId,
                source: event.source ?? "hermes",
                topic: topic,
                title: event.payload?.title,
                summary: event.payload?.summary,
                sentimentLabel: event.sentiment?.label,
                sentimentScore: event.sentiment?.score,
                sourceURL: event.payload?.url,
                author: event.payload?.author,
                observedAt: observedAt,
                rawPayload: nil
            )
        }
        return try await repo.insertNewEvents(models, on: req.db)
    }

    func syncSentimentSnapshots(on req: Request) async throws -> Int {
        let windowDays = 30
        var upserted = 0

        let overall = try await provider.fetchSentiment(topic: nil, days: windowDays, on: req)
        try await repo.upsertSentimentSnapshot(
            makeSnapshot(from: overall, scope: "overall", scopeKey: nil, windowDays: windowDays),
            on: req.db
        )
        upserted += 1

        let summary = try await provider.fetchSummary(days: windowDays, on: req)
        let topics = (summary.byTopic ?? [:]).keys.sorted().prefix(20)
        for topic in topics {
            do {
                let sentiment = try await provider.fetchSentiment(topic: topic, days: windowDays, on: req)
                try await repo.upsertSentimentSnapshot(
                    makeSnapshot(from: sentiment, scope: "topic", scopeKey: topic, windowDays: windowDays),
                    on: req.db
                )
                upserted += 1
            } catch {
                req.logger.warning("insights.sync topic sentiment failed topic=\(topic) error=\(String(describing: error))")
            }
        }
        return upserted
    }

    func syncNetWorth(on req: Request) async throws -> Int {
        let response = try await provider.fetchNetWorth(on: req)
        var snapshots: [NetWorthSnapshot] = []
        let entries = [response.latest].compactMap(\.self) + (response.history ?? [])
        for entry in entries {
            guard let eventId = entry.eventId else { continue }
            snapshots.append(
                NetWorthSnapshot(
                    dedupeKey: "net-worth:\(eventId)",
                    totalValue: entry.value,
                    capturedAt: parseHermesTimestamp(entry.ingestedAt) ?? Date()
                )
            )
        }
        return try await repo.insertNewNetWorthSnapshots(snapshots, on: req.db)
    }

    struct TickerPostSyncResult {
        var inserted = 0
        var fetched = 0
        var newestAt: Date?
        var symbolsFailed = 0
    }

    func syncTickerPosts(on req: Request) async -> TickerPostSyncResult {
        // Resolve the scrape/pull set at sync time: pinned symbols plus the
        // top-N most-popular equities across all users' holdings + watchlist.
        var symbols: [String] = []
        do {
            let dynamic = try await repo.allTrackedSymbols(limit: tickerLimit, on: req.db)
            var seen = Set<String>()
            for s in pinnedTickers + dynamic where seen.insert(s).inserted {
                symbols.append(s)
            }
            symbols = Array(symbols.prefix(tickerLimit))
        } catch {
            req.logger.warning("insights.sync tracked symbols failed error=\(String(describing: error)); using pinned only")
            symbols = pinnedTickers
        }

        var result = TickerPostSyncResult()
        for symbol in symbols {
            do {
                let response = try await provider.fetchTickerPosts(symbol: symbol, days: 30, limit: 100, on: req)
                result.fetched += response.posts.count
                let models = response.posts.compactMap { post -> TickerSentimentPost? in
                    guard let text = post.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                        return nil
                    }
                    return TickerSentimentPost(
                        dedupeKey: post.eventId,
                        symbol: symbol,
                        author: post.author,
                        authorHandle: post.authorHandle,
                        text: text,
                        url: post.url,
                        sentimentLabel: post.sentiment ?? "neutral",
                        sentimentScore: post.sentimentScore,
                        confidence: post.confidence,
                        postedAt: parseHermesTimestamp(post.postedAt) ?? Date()
                    )
                }
                if let newest = models.map(\.postedAt).max(),
                   newest > (result.newestAt ?? .distantPast)
                {
                    result.newestAt = newest
                }
                result.inserted += try await repo.insertNewTickerPosts(models, on: req.db)
            } catch {
                result.symbolsFailed += 1
                req.logger.warning("insights.sync ticker posts failed symbol=\(symbol) error=\(String(describing: error))")
            }
        }
        return result
    }

    func makeSnapshot(
        from response: HermesSentimentResponse,
        scope: String,
        scopeKey: String?,
        windowDays: Int
    ) -> SentimentSnapshot {
        let labelCounts = response.labelCounts ?? [:]
        let averageScore = response.averageScore ?? 0
        let dayKey = dayString(Date())
        let scopePart = scopeKey.map { "topic:\($0)" } ?? "overall"
        return SentimentSnapshot(
            dedupeKey: "\(scopePart):\(windowDays):\(dayKey)",
            scope: scope,
            scopeKey: scopeKey,
            windowDays: windowDays,
            averageScore: averageScore,
            label: sentimentLabel(forScore: averageScore, postLabels: []),
            eventCount: response.count ?? labelCounts.values.reduce(0, +),
            positiveCount: labelCounts["positive"] ?? 0,
            neutralCount: labelCounts["neutral"] ?? 0,
            negativeCount: labelCounts["negative"] ?? 0,
            capturedAt: Date()
        )
    }

    func makeEventResponse(_ event: InsightEvent) -> InsightEventResponse {
        InsightEventResponse(
            id: event.id?.uuidString ?? event.dedupeKey,
            topic: event.topic,
            source: event.source,
            title: event.title,
            summary: event.summary,
            sentimentLabel: event.sentimentLabel,
            sentimentScore: event.sentimentScore,
            url: event.sourceURL,
            author: event.author,
            observedAt: formatISO(event.observedAt)
        )
    }

    func sentimentLabel(forScore score: Double?, postLabels: [String]) -> String {
        if let score {
            if score > 0.15 {
                return "bullish"
            }
            if score < -0.15 {
                return "bearish"
            }
            return "neutral"
        }
        // No numeric scores: fall back to a majority vote over the post labels.
        guard !postLabels.isEmpty else { return "neutral" }
        var counts: [String: Int] = [:]
        for label in postLabels {
            counts[label, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? "neutral"
    }

    func windowStart(days: Int) -> Date {
        Date().addingTimeInterval(-Double(days) * 86400)
    }

    func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func formatISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
