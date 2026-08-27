import Fluent
@testable import StockPlanBackend
import Testing
import Vapor
import VaporTesting

@Suite("Why-moved endpoint", .serialized)
struct WhyMovedTests {
    // MARK: - Stubs

    private actor WhyMovedStubState {
        var summaries: [StockStatisticsSummary] = []
        var sentimentBySymbol: [String: TickerSentimentAggregate] = [:]
        var sentimentThrows = false
        var topicCounts: [String: Int] = [:]
        var chatCalls = 0
        var chatResponse = #"{"text": "AAPL drove the gain on bullish chatter."}"#

        func setSummaries(_ value: [StockStatisticsSummary]) {
            summaries = value
        }

        func setSentiment(_ value: [String: TickerSentimentAggregate]) {
            sentimentBySymbol = value
        }

        func setSentimentThrows(_ value: Bool) {
            sentimentThrows = value
        }

        func setTopics(_ value: [String: Int]) {
            topicCounts = value
        }

        func setChatResponse(_ value: String) {
            chatResponse = value
        }

        func recordChatCall() {
            chatCalls += 1
        }

        func chatCallCount() -> Int {
            chatCalls
        }
    }

    private struct StubError: Error {}

    private struct StatsRepoStub: StatisticsRepository {
        let state: WhyMovedStubState

        func overviewStatistics(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            let summaries = await state.summaries
            return StatisticsViewModel(
                generatedAt: Date(),
                importedStocks: ImportedStocksStatisticsView(
                    totalPositions: summaries.count,
                    totalMarketValue: summaries.reduce(0) { $0 + $1.marketValue },
                    totalCostBasis: 0,
                    totalUnrealizedPnl: 0,
                    totalRealizedPnl: 0,
                    stockSummaries: summaries,
                    stockAllocations: [],
                    sectorAllocations: [],
                    calendarPerformance: []
                ),
                watchlist: WatchlistStatisticsView(totalSymbols: 0, symbolsWithNotes: 0, sectorAllocations: [], topWatched: []),
                looklist: LooklistStatisticsView(totalIdeas: 0, activeIdeas: 0, ideasWithTarget: 0, ideasByConviction: []),
                market: MarketStatisticsView(benchmarkSymbol: "SPY", benchmarkChange1D: nil, benchmarkChange1W: nil, benchmarkChange1M: nil, benchmarkChangeYtd: nil, heatmap: [])
            )
        }

        func stockLevelScorecard(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func stockAllocation(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func sectorAllocation(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func sectorGains(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> SectorGainsResponse {
            throw StubError()
        }

        func calendarPerformance(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func contributionAnalysis(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func winnersVsLosers(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func volatilitySnapshot(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func currencySplit(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func scenarioTracking(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func notesQualityMetrics(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func importedStocksStatistics(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func watchlistStatistics(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func looklistStatistics(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }

        func marketStatistics(userId _: UUID, options _: StatisticsQueryOptions, on _: any Database) async throws -> StatisticsViewModel {
            throw StubError()
        }
    }

    private struct InsightsServiceStub: InsightsService {
        let state: WhyMovedStubState
        var isEnabled: Bool {
            true
        }

        func summary(days: Int, on _: any Database) async throws -> InsightsSummaryResponse {
            let topics = await state.topicCounts
            return InsightsSummaryResponse(windowDays: days, totalEvents: topics.values.reduce(0, +), byTopic: topics, latestEvents: [])
        }

        func topic(_: String, days _: Int, limit _: Int, on _: any Database) async throws -> InsightsTopicResponse {
            throw StubError()
        }

        func sentiment(topic _: String?, on _: any Database) async throws -> InsightsSentimentResponse {
            throw StubError()
        }

        func netWorth(on _: any Database) async throws -> InsightsNetWorthResponse {
            throw StubError()
        }

        func tickerSentiment(symbol: String, days: Int, limit _: Int, on _: any Database) async throws -> TickerSentimentResponse {
            if await state.sentimentThrows {
                throw StubError()
            }
            guard let aggregate = await state.sentimentBySymbol[symbol.uppercased()] else {
                return TickerSentimentResponse(symbol: symbol, windowDays: days, aggregate: TickerSentimentAggregate(label: "neutral", score: nil, postCount: 0), posts: [])
            }
            return TickerSentimentResponse(symbol: symbol, windowDays: days, aggregate: aggregate, posts: [])
        }

        func syncFromHermes(on _: Request) async throws -> InsightsSyncSummary {
            throw StubError()
        }
    }

    private struct ChatClientStub: OpenAIChatClient {
        let state: WhyMovedStubState

        func chat(messages _: [OpenAIMessage], tools _: [OpenAITool], responseFormat _: String?, on _: Request) async throws -> OpenAIMessage {
            await state.recordChatCall()
            return await OpenAIMessage(role: "assistant", content: state.chatResponse)
        }
    }

    private func summary(_ symbol: String, value: Double, dayPct: Double?, weight: Double = 10) -> StockStatisticsSummary {
        StockStatisticsSummary(symbol: symbol, marketValue: value, weightPercent: weight, dailyChangePercent: dayPct, weeklyChangePercent: nil, monthlyChangePercent: nil, unrealizedPnl: 0)
    }

    private func configureStubs(_ app: Application, state: WhyMovedStubState) {
        app.whyMovedService = DefaultWhyMovedService(statisticsRepo: StatsRepoStub(state: state))
        app.insightsService = InsightsServiceStub(state: state)
        app.openAIChatClient = ChatClientStub(state: state)
    }

    // MARK: - Tests

    @Test("Joins movers with sentiment, context, and an AI sentence")
    func whyMovedHappyPath() async throws {
        try await withAppForWhyMoved { app, token, state in
            await state.setSummaries([
                summary("AAPL", value: 50000, dayPct: 3.0),
                summary("MSFT", value: 20000, dayPct: 1.0),
                summary("XOM", value: 10000, dayPct: -2.0),
                summary("FLAT", value: 5000, dayPct: 0),
            ])
            await state.setSentiment(["AAPL": TickerSentimentAggregate(label: "bullish", score: 0.6, postCount: 12)])
            await state.setTopics(["Stocks": 9, "Housing": 4])

            try await app.testing().test(.GET, "v1/dashboard/why-moved", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(WhyMovedResponse.self)
                #expect(body.movers.first?.symbol == "AAPL")
                #expect(body.movers.first?.sentiment?.label == "bullish")
                #expect(body.movers.contains { $0.symbol == "XOM" })
                #expect(!body.movers.contains { $0.symbol == "FLAT" })
                #expect(body.context.topics.first?.topic == "Stocks")
                // Provenance must reflect only what sentiment actually covered.
                #expect(body.sentimentSource?.postsAnalyzed == 12)
                #expect(body.sentimentSource?.symbolsCovered == 1)
                #expect(body.sentimentSource?.windowDays == 7)
                #expect(body.aiSummary?.text.contains("AAPL") == true)
                #expect(body.portfolioChangePercent != nil)
            })
        }
    }

    @Test("Sentiment failures degrade to nil without failing the response")
    func whyMovedSentimentDegrades() async throws {
        try await withAppForWhyMoved { app, token, state in
            await state.setSummaries([summary("AAPL", value: 50000, dayPct: 2.0)])
            await state.setSentimentThrows(true)

            try await app.testing().test(.GET, "v1/dashboard/why-moved", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(WhyMovedResponse.self)
                #expect(body.movers.count == 1)
                #expect(body.movers.first?.sentiment == nil)
                // No sentiment at all -> no provenance, so the UI can hide
                // the claim rather than showing "0 posts analyzed".
                #expect(body.sentimentSource == nil)
            })
        }
    }

    @Test("No holdings yields empty movers and no AI call")
    func whyMovedEmptyPortfolio() async throws {
        try await withAppForWhyMoved { app, token, state in
            try await app.testing().test(.GET, "v1/dashboard/why-moved", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(WhyMovedResponse.self)
                #expect(body.movers.isEmpty)
                #expect(body.aiSummary == nil)
            })
            #expect(await state.chatCallCount() == 0)
        }
    }

    @Test("Second request within the AI cache TTL skips the model")
    func whyMovedAICacheHit() async throws {
        try await withAppForWhyMoved { app, token, state in
            guard app.redis.configuration != nil else { return }
            await state.setSummaries([summary("AAPL", value: 50000, dayPct: 2.0)])

            for _ in 0 ..< 2 {
                try await app.testing().test(.GET, "v1/dashboard/why-moved", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                })
            }
            #expect(await state.chatCallCount() == 1)
        }
    }

    @Test("Rejects unauthenticated requests")
    func whyMovedRequiresAuth() async throws {
        try await withAppForWhyMoved { app, _, _ in
            try await app.testing().test(.GET, "v1/dashboard/why-moved", afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - Self-contained harness (mirrors StockPlanBackendTests.withApp)

    // MARK: - Plan routing

    /// This endpoint has no Pro gate, so a free user reaches it. Reaching it must
    /// not put them on a metered model.
    @Test("A free user's why-moved summary comes from the free chain, not the paid one")
    func whyMovedFreeUserStaysOnFreeChain() async throws {
        // The local `.env` ships BYPASS_BILLING=true, which resolves every user to
        // Pro. Without this the test would pass for the wrong reason.
        setenv("BYPASS_BILLING", "false", 1)
        defer { unsetenv("BYPASS_BILLING") }

        try await withAppForWhyMoved { app, token, state in
            await state.setSummaries([summary("AAPL", value: 50000, dayPct: 3.0)])
            // Stubbed rather than driven through the database: the local `.env`
            // ships BYPASS_BILLING=true, which resolves every user to Pro, and
            // this test must not depend on the developer's env either way.
            app.entitlementResolver = FixedEntitlementResolver(level: "free")
            app.aiModelRouter = twoChainRouter()

            try await app.testing().test(.GET, "v1/dashboard/why-moved", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(WhyMovedResponse.self)
                #expect(body.aiSummary?.text == "served by the free chain")
            })
            // The paid chain was never asked.
            #expect(await state.chatCalls == 0)
        }
    }

    @Test("A Pro user's why-moved summary comes from the pro chain")
    func whyMovedProUserUsesProChain() async throws {
        setenv("BYPASS_BILLING", "false", 1)
        defer { unsetenv("BYPASS_BILLING") }

        try await withAppForWhyMoved { app, token, state in
            await state.setSummaries([summary("AAPL", value: 50000, dayPct: 3.0)])
            app.entitlementResolver = FixedEntitlementResolver(level: "pro")
            app.aiModelRouter = twoChainRouter()

            try await app.testing().test(.GET, "v1/dashboard/why-moved", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(WhyMovedResponse.self)
                #expect(body.aiSummary?.text == "served by the pro chain")
            })
        }
    }

    private func twoChainRouter() -> AIModelRouter {
        AIModelRouter(
            free: FixedJSONChatClient(text: "served by the free chain"),
            pro: FixedJSONChatClient(text: "served by the pro chain")
        )
    }

    private func withAppForWhyMoved(
        _ body: (Application, String, WhyMovedStubState) async throws -> Void
    ) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                if app.redis.configuration != nil {
                    _ = try? await app.redis.send(command: "FLUSHDB", with: []).get()
                }
                try await app.autoMigrate()
                let state = WhyMovedStubState()
                configureStubs(app, state: state)
                let token = try await registerUser(app: app)
                try await body(app, token, state)
                try await app.autoRevert()
                try await app.asyncShutdown()
            } catch {
                try? await app.autoRevert()
                try? await app.asyncShutdown()
                throw error
            }
        }
    }

    private func registerUser(app: Application) async throws -> String {
        let identifier = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let register = AuthRegisterRequest(
            username: "test_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "test+\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token: String?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            token = try res.content.decode(AuthResponse.self).token
        })
        guard let token else {
            throw Abort(.internalServerError, reason: "Auth register did not return a token")
        }
        return token
    }
}

/// Returns the shape `loadAISummary` decodes, tagged so a test can tell which
/// chain answered.
private struct FixedJSONChatClient: OpenAIChatClient {
    let text: String

    func chat(
        messages _: [OpenAIMessage],
        tools _: [OpenAITool],
        responseFormat _: String?,
        on _: Request
    ) async throws -> OpenAIMessage {
        OpenAIMessage(role: "assistant", content: #"{"text": "\#(text)"}"#)
    }
}

private struct FixedEntitlementResolver: EntitlementResolver {
    let level: String

    func resolve(userId: UUID, on _: any Database) async throws -> EntitlementSnapshot {
        EntitlementSnapshot(userId: userId, level: level)
    }
}
