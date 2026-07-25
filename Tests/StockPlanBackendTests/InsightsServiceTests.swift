import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

private struct StubInsightsProvider: InsightsProvider {
    var isEnabled: Bool {
        true
    }

    func fetchEvents(days _: Int, limit _: Int, on _: Request) async throws -> HermesEventsResponse {
        HermesEventsResponse(count: 2, events: [
            HermesEventDTO(
                eventId: "event-1",
                source: "x",
                sourceId: "post-1",
                topic: "Housing",
                observedAt: "2026-07-01T10:00:00+00:00",
                ingestedAt: "2026-07-01T10:05:00+00:00",
                payload: HermesEventPayload(title: "Housing cooling", summary: "Prices flat", url: "https://x.com/a/1", author: "Ana"),
                sentiment: HermesEventSentiment(label: "negative", score: -0.4)
            ),
            HermesEventDTO(
                eventId: "event-2",
                source: "x",
                sourceId: "post-2",
                topic: "Crypto",
                // Malformed legacy Hermes timestamp: offset plus trailing Z.
                observedAt: "2026-07-02T09:00:00+00:00Z",
                ingestedAt: nil,
                payload: HermesEventPayload(title: "BTC rally", summary: nil, url: nil, author: nil),
                sentiment: HermesEventSentiment(label: "positive", score: 0.7)
            ),
        ])
    }

    func fetchSummary(days: Int, on _: Request) async throws -> HermesSummaryResponse {
        HermesSummaryResponse(windowDays: days, totalEvents: 2, byTopic: ["Housing": 1, "Crypto": 1])
    }

    func fetchSentiment(topic: String?, days: Int, on _: Request) async throws -> HermesSentimentResponse {
        HermesSentimentResponse(
            topic: topic,
            windowDays: days,
            count: 10,
            labelCounts: ["positive": 6, "neutral": 3, "negative": 1],
            averageScore: 0.42,
            sampled: 10
        )
    }

    func fetchNetWorth(on _: Request) async throws -> HermesNetWorthResponse {
        HermesNetWorthResponse(
            latest: HermesNetWorthEntry(eventId: "nw-1", ingestedAt: "2026-07-03T08:00:00+00:00", value: 125_000),
            history: [HermesNetWorthEntry(eventId: "nw-0", ingestedAt: "2026-06-26T08:00:00+00:00", value: 120_000)]
        )
    }

    func fetchTickerPosts(symbol: String, days: Int, limit _: Int, on _: Request) async throws -> HermesTickerPostsResponse {
        HermesTickerPostsResponse(symbol: symbol, days: days, count: 1, posts: [
            HermesTickerPostDTO(
                eventId: "tweet-\(symbol)-1",
                author: "Notable Investor",
                authorHandle: "notable",
                text: "\(symbol) thesis: undervalued on AI demand.",
                url: "https://x.com/notable/status/1",
                sentiment: "bullish",
                sentimentScore: 0.8,
                confidence: 0.9,
                postedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
            ),
        ])
    }

    func health(on _: Request) async -> Bool {
        true
    }
}

@Suite("InsightsService Tests", .serialized)
struct InsightsServiceTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func makeService(pinnedTickers: [String] = ["AMD"]) -> DefaultInsightsService {
        DefaultInsightsService(
            repo: DatabaseInsightsRepository(),
            provider: StubInsightsProvider(),
            tickerLimit: 25,
            pinnedTickers: pinnedTickers
        )
    }

    @Test("syncFromHermes persists events, snapshots, ticker posts, and net worth")
    func syncPersistsAll() async throws {
        try await withApp { app in
            let service = makeService()
            let req = Request(application: app, on: app.eventLoopGroup.next())

            let summary = try await service.syncFromHermes(on: req)

            #expect(summary.eventsInserted == 2)
            #expect(summary.tickerPostsInserted == 1)
            #expect(summary.netWorthInserted == 2)
            // 1 overall + 2 topics from the stub summary.
            #expect(summary.snapshotsUpserted == 3)

            let events = try await InsightEvent.query(on: app.db).all()
            #expect(events.count == 2)
            let cryptoEvent = events.first { $0.dedupeKey == "event-2" }
            // The malformed "+00:00Z" timestamp must still parse to a real date.
            #expect(cryptoEvent != nil)
            #expect(cryptoEvent?.observedAt != nil)
            #expect(cryptoEvent?.sentimentLabel == "positive")
        }
    }

    @Test("syncFromHermes is idempotent across repeated runs")
    func syncIsIdempotent() async throws {
        try await withApp { app in
            let service = makeService()
            let req = Request(application: app, on: app.eventLoopGroup.next())

            _ = try await service.syncFromHermes(on: req)
            let second = try await service.syncFromHermes(on: req)

            #expect(second.eventsInserted == 0)
            #expect(second.tickerPostsInserted == 0)
            #expect(second.netWorthInserted == 0)

            #expect(try await InsightEvent.query(on: app.db).count() == 2)
            #expect(try await TickerSentimentPost.query(on: app.db).count() == 1)
            #expect(try await NetWorthSnapshot.query(on: app.db).count() == 2)
            // Snapshots are upserts keyed per scope+window+day: still 3 rows.
            #expect(try await SentimentSnapshot.query(on: app.db).count() == 3)
        }
    }

    @Test("tickerSentiment aggregates persisted posts")
    func tickerSentimentAggregates() async throws {
        try await withApp { app in
            let service = makeService()
            let req = Request(application: app, on: app.eventLoopGroup.next())
            _ = try await service.syncFromHermes(on: req)

            let response = try await service.tickerSentiment(symbol: "AMD", days: 14, limit: 20, on: app.db)

            #expect(response.symbol == "AMD")
            #expect(response.aggregate.postCount == 1)
            #expect(response.aggregate.label == "bullish")
            #expect(response.posts.first?.authorHandle == "notable")
            #expect(response.posts.first?.sentimentLabel == "bullish")
        }
    }

    @Test("sentiment throws notFound before the first sync")
    func sentimentNotFoundBeforeSync() async throws {
        try await withApp { app in
            let service = makeService()
            await #expect(throws: Abort.self) {
                _ = try await service.sentiment(topic: nil, on: app.db)
            }
        }
    }

    @Test("disabled provider refuses sync and reports disabled")
    func disabledProviderRefusesSync() async throws {
        try await withApp { app in
            let service = DefaultInsightsService(
                repo: DatabaseInsightsRepository(),
                provider: DisabledInsightsProvider(),
                tickerLimit: 25,
                pinnedTickers: []
            )
            #expect(service.isEnabled == false)

            let req = Request(application: app, on: app.eventLoopGroup.next())
            await #expect(throws: Abort.self) {
                _ = try await service.syncFromHermes(on: req)
            }
        }
    }

    @Test("parseHermesTimestamp accepts offset, malformed offset+Z, and Z forms")
    func timestampParsing() {
        #expect(parseHermesTimestamp("2026-07-03T22:13:45+00:00") != nil)
        #expect(parseHermesTimestamp("2026-07-03T22:13:45+00:00Z") != nil)
        #expect(parseHermesTimestamp("2026-07-03T22:13:45Z") != nil)
        #expect(parseHermesTimestamp("not-a-date") == nil)
        #expect(parseHermesTimestamp(nil) == nil)
    }

    @Test("POST /v1/insights/sync requires authentication")
    func syncRequiresAuth() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "v1/insights/sync", afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("POST /v1/insights/sync is fail-closed when INSIGHTS_ADMIN_EMAILS is unset")
    func syncForbiddenForNonAdmin() async throws {
        try await withApp { app in
            let token = try await registerToken(app: app)
            try await app.testing().test(.POST, "v1/insights/sync", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("GET /v1/insights/tickers/:symbol/sentiment requires Pro")
    func tickerSentimentRequiresPro() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await clearTrial(userId: userId, on: app.db)

            try await app.testing().test(.GET, "v1/insights/tickers/AMD/sentiment", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
                let body = try res.content.decode(BillingUpgradeRequiredResponse.self)
                #expect(body.code == "upgrade_required")
                #expect(body.feature == "ai_insights")
                #expect(body.requiredPlan == "pro")
            })
        }
    }

    @Test("GET /v1/insights/tickers/:symbol/sentiment allows Pro users")
    func tickerSentimentAllowsPro() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await Entitlement(userId: userId, level: "pro").save(on: app.db)

            try await app.testing().test(.GET, "v1/insights/tickers/AMD/sentiment", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(TickerSentimentResponse.self)
                #expect(body.symbol == "AMD")
            })
        }
    }

    private func registerTestUser(app: Application) async throws -> (token: String, userId: UUID) {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let request = StockPlanBackend.AuthRegisterRequest(
            username: "insights_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "insights+\(suffix)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )

        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })

        guard let response else {
            throw Abort(.internalServerError, reason: "Auth register did not return a response")
        }
        return (response.token, response.userId)
    }

    private func clearTrial(userId: UUID, on db: any Database) async throws {
        let user = try #require(try await User.find(userId, on: db))
        user.trialStartedAt = nil
        user.trialDays = nil
        user.trialTier = nil
        try await user.save(on: db)
    }

    private func ensureDefaultPortfolioListId(userId: UUID, on db: any Database) async throws -> UUID {
        if let existing = try await PortfolioList.query(on: db).filter(\.$userId == userId).first() {
            return try existing.requireID()
        }
        let list = PortfolioList(userId: userId, name: "Default", isDefault: true)
        try await list.save(on: db)
        return try list.requireID()
    }

    private func ensureDefaultWatchlistListId(userId: UUID, on db: any Database) async throws -> UUID {
        if let existing = try await WatchlistList.query(on: db).filter(\.$userId == userId).first() {
            return try existing.requireID()
        }
        let list = WatchlistList(userId: userId, name: "Default", isDefault: true)
        try await list.save(on: db)
        return try list.requireID()
    }

    private func createHolding(
        symbol: String,
        userId: UUID,
        on db: any Database,
        category: AssetCategory = .stock
    ) async throws {
        let portfolioListId = try await ensureDefaultPortfolioListId(userId: userId, on: db)
        let stock = Stock(
            userId: userId,
            portfolioListId: portfolioListId,
            symbol: symbol,
            shares: 1,
            buyPrice: 100,
            buyDate: Date(timeIntervalSince1970: 1_704_067_200),
            category: category
        )
        try await stock.save(on: db)
    }

    private func createWatchlistItem(
        symbol: String,
        userId: UUID,
        on db: any Database,
        status: WatchlistStatus = .active
    ) async throws {
        let watchlistListId = try await ensureDefaultWatchlistListId(userId: userId, on: db)
        let item = WatchlistItem(
            userId: userId,
            watchlistListId: watchlistListId,
            symbol: symbol,
            status: status
        )
        try await item.save(on: db)
    }

    @Test("allTrackedSymbols ranks union of holdings and active watchlist items by distinct holder count")
    func allTrackedSymbolsRanksByPopularity() async throws {
        try await withApp { app in
            let repo = DatabaseInsightsRepository()

            let (_, userA) = try await registerTestUser(app: app)
            let (_, userB) = try await registerTestUser(app: app)

            // AMD held by both users (case-insensitivity: one saved lowercase).
            try await createHolding(symbol: "amd", userId: userA, on: app.db)
            try await createHolding(symbol: "AMD", userId: userB, on: app.db)
            // NVDA held by one user.
            try await createHolding(symbol: "NVDA", userId: userA, on: app.db)
            // BTC is a crypto holding and must be excluded.
            try await createHolding(symbol: "BTC", userId: userA, on: app.db, category: .crypto)

            // TSLA is an active watchlist item and must be included.
            try await createWatchlistItem(symbol: "TSLA", userId: userB, on: app.db, status: .active)
            // AAPL is archived and must be excluded.
            try await createWatchlistItem(symbol: "AAPL", userId: userA, on: app.db, status: .archived)

            let symbols = try await repo.allTrackedSymbols(limit: 10, on: app.db)

            #expect(symbols.first == "AMD")
            #expect(symbols.contains("NVDA"))
            #expect(symbols.contains("TSLA"))
            #expect(!symbols.contains("BTC"))
            #expect(!symbols.contains("AAPL"))

            let topOne = try await repo.allTrackedSymbols(limit: 1, on: app.db)
            #expect(topOne == ["AMD"])
        }
    }

    @Test("tracked-symbols is fail-closed when INSIGHTS_SYMBOLS_TOKEN is unset")
    func trackedSymbolsAuth() async throws {
        try await withApp { app in
            // Env unset in tests -> fail-closed (403), not 404.
            try await app.testing().test(.GET, "v1/insights/tracked-symbols", afterResponse: { res async throws in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("syncTickerPosts pulls symbols from holdings, not a static list")
    func syncUsesHoldings() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            try await createHolding(symbol: "AMD", userId: userId, on: app.db)
            let service = DefaultInsightsService(
                repo: DatabaseInsightsRepository(),
                provider: StubInsightsProvider(),
                tickerLimit: 25,
                pinnedTickers: [] // no pins — AMD must come from holdings
            )
            let req = Request(application: app, on: app.eventLoopGroup.next())
            _ = try await service.syncFromHermes(on: req)
            let posts = try await TickerSentimentPost.query(on: app.db).filter(\.$symbol == "AMD").count()
            #expect(posts >= 1)
        }
    }

    private func registerToken(app: Application) async throws -> String {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let register = AuthRegisterRequest(
            username: "test_\(id)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "test+\(id)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token: String?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            token = try res.content.decode(AuthResponse.self).token
        })
        return try #require(token)
    }

    @Test("Insert paths dedupe within a single batch, not just against stored rows")
    func insertsDedupeWithinBatch() async throws {
        try await withApp { app in
            let repo = DatabaseInsightsRepository()

            func makeEvent(_ key: String) -> InsightEvent {
                InsightEvent(
                    dedupeKey: key,
                    source: "test",
                    topic: "Stocks",
                    title: "t",
                    summary: nil,
                    sentimentLabel: "neutral",
                    sentimentScore: nil,
                    sourceURL: nil,
                    author: nil,
                    observedAt: Date(),
                    rawPayload: nil
                )
            }

            // Hermes can emit the same dedupe key twice in one payload; before
            // the batch-level guard both rows counted as "fresh" and the second
            // save violated the unique index, failing the whole sync.
            let inserted = try await repo.insertNewEvents(
                [makeEvent("dup-1"), makeEvent("dup-1"), makeEvent("unique-1")],
                on: app.db
            )
            #expect(inserted == 2)

            // A second run inserts nothing: both keys are now stored.
            let again = try await repo.insertNewEvents(
                [makeEvent("dup-1"), makeEvent("unique-1")],
                on: app.db
            )
            #expect(again == 0)

            let stored = try await InsightEvent.query(on: app.db)
                .filter(\.$dedupeKey ~~ ["dup-1", "unique-1"])
                .count()
            #expect(stored == 2)
        }
    }
}
