import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("ProviderCooldownRegistry")
struct ProviderCooldownRegistryTests {
    @Test("a fresh registry cools nothing down")
    func startsClear() {
        let registry = ProviderCooldownRegistry()
        #expect(!registry.isCoolingDown("DeepAPI"))
        #expect(registry.activeCooldowns().isEmpty)
    }

    @Test("beginning a cooldown suppresses the provider")
    func suppresses() {
        let registry = ProviderCooldownRegistry(windowSeconds: 3600)
        registry.beginCooldown("DeepAPI")

        #expect(registry.isCoolingDown("DeepAPI"))
        #expect(!registry.isCoolingDown("Hermes"))
        #expect(registry.activeCooldowns() == ["DeepAPI"])
    }

    @Test("a cooldown expires on its own")
    func expires() {
        let registry = ProviderCooldownRegistry(windowSeconds: 60)
        let now = Date()
        registry.beginCooldown("DeepAPI", now: now)

        #expect(registry.isCoolingDown("DeepAPI", now: now.addingTimeInterval(30)))
        #expect(!registry.isCoolingDown("DeepAPI", now: now.addingTimeInterval(120)))
    }

    @Test("a later success clears the cooldown early")
    func clearedOnSuccess() {
        let registry = ProviderCooldownRegistry()
        registry.beginCooldown("DeepAPI")
        registry.clear("DeepAPI")

        #expect(!registry.isCoolingDown("DeepAPI"))
    }
}

/// Counts attempts. Local to this file: the equivalent helper in
/// FallbackInsightsProviderTests is private to that file.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Fails every call with whatever it was handed, and counts the attempts.
private struct ExplodingProvider: InsightsProvider {
    let error: any Error
    let counter: AttemptCounter

    var isEnabled: Bool {
        true
    }

    func fetchEvents(days _: Int, limit _: Int, on _: Request) async throws -> HermesEventsResponse {
        counter.increment()
        throw error
    }

    func fetchSummary(days _: Int, on _: Request) async throws -> HermesSummaryResponse {
        counter.increment()
        throw error
    }

    func fetchSentiment(topic _: String?, days _: Int, on _: Request) async throws -> HermesSentimentResponse {
        counter.increment()
        throw error
    }

    func fetchNetWorth(on _: Request) async throws -> HermesNetWorthResponse {
        counter.increment()
        throw error
    }

    func fetchTickerPosts(symbol _: String, days _: Int, limit _: Int, on _: Request) async throws -> HermesTickerPostsResponse {
        counter.increment()
        throw error
    }

    func health(on _: Request) async -> Bool {
        true
    }
}

private struct QuietProvider: InsightsProvider {
    let counter: AttemptCounter

    var isEnabled: Bool {
        true
    }

    func fetchEvents(days _: Int, limit _: Int, on _: Request) async throws -> HermesEventsResponse {
        counter.increment()
        return HermesEventsResponse(count: 0, events: [])
    }

    func fetchSummary(days _: Int, on _: Request) async throws -> HermesSummaryResponse {
        counter.increment()
        return HermesSummaryResponse(windowDays: 7, totalEvents: 0, byTopic: [:])
    }

    func fetchSentiment(topic _: String?, days _: Int, on _: Request) async throws -> HermesSentimentResponse {
        counter.increment()
        return HermesSentimentResponse(
            topic: nil,
            windowDays: 7,
            count: 0,
            labelCounts: [:],
            averageScore: 0,
            sampled: 0
        )
    }

    func fetchNetWorth(on _: Request) async throws -> HermesNetWorthResponse {
        counter.increment()
        return HermesNetWorthResponse(latest: nil, history: [])
    }

    func fetchTickerPosts(symbol: String, days: Int, limit _: Int, on _: Request) async throws -> HermesTickerPostsResponse {
        counter.increment()
        return HermesTickerPostsResponse(symbol: symbol, days: days, count: 0, posts: [])
    }

    func health(on _: Request) async -> Bool {
        true
    }
}

@Suite("Credit exhaustion failover", .serialized)
struct CreditExhaustionFailoverTests {
    private func withRequest(_ body: (Request) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        let req = Request(application: app, on: app.eventLoopGroup.next())
        do {
            try await body(req)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("an exhausted provider is skipped on every subsequent call")
    func exhaustedProviderIsSuppressed() async throws {
        try await withRequest { req in
            let exhaustedCalls = AttemptCounter()
            let fallbackCalls = AttemptCounter()
            let cooldowns = ProviderCooldownRegistry(windowSeconds: 3600)

            let chain = FallbackInsightsProvider(
                providers: [
                    ExplodingProvider(
                        error: InsightsProviderError.creditsExhausted(provider: "DeepAPI", detail: "no balance"),
                        counter: exhaustedCalls
                    ),
                    QuietProvider(counter: fallbackCalls),
                ],
                logger: req.logger,
                cooldowns: cooldowns
            )

            // First call discovers the exhaustion and falls through.
            _ = try await chain.fetchTickerPosts(symbol: "AAPL", days: 7, limit: 10, on: req)
            #expect(exhaustedCalls.count == 1)
            #expect(fallbackCalls.count == 1)

            // A universe sweep makes hundreds of these. None of them may hit
            // the dry provider again.
            for symbol in ["MSFT", "NVDA", "TSLA", "AMZN"] {
                _ = try await chain.fetchTickerPosts(symbol: symbol, days: 7, limit: 10, on: req)
            }

            #expect(exhaustedCalls.count == 1, "exhausted provider must not be retried during cooldown")
            #expect(fallbackCalls.count == 5)
            #expect(cooldowns.activeCooldowns().contains("ExplodingProvider"))
        }
    }

    @Test("an ordinary failure does not trigger a cooldown")
    func ordinaryFailuresStillRetry() async throws {
        try await withRequest { req in
            let flakyCalls = AttemptCounter()
            let fallbackCalls = AttemptCounter()
            let cooldowns = ProviderCooldownRegistry(windowSeconds: 3600)

            let chain = FallbackInsightsProvider(
                providers: [
                    ExplodingProvider(
                        error: Abort(.badGateway, reason: "transient"),
                        counter: flakyCalls
                    ),
                    QuietProvider(counter: fallbackCalls),
                ],
                logger: req.logger,
                cooldowns: cooldowns
            )

            for symbol in ["AAPL", "MSFT", "NVDA"] {
                _ = try await chain.fetchTickerPosts(symbol: symbol, days: 7, limit: 10, on: req)
            }

            // A blip must not take the primary out for six hours.
            #expect(flakyCalls.count == 3)
            #expect(cooldowns.activeCooldowns().isEmpty)
        }
    }

    @Test("everything in cooldown surfaces as unavailable, not as no-providers")
    func fullCooldownIsDistinguishable() async throws {
        try await withRequest { req in
            let counter = AttemptCounter()
            let cooldowns = ProviderCooldownRegistry(windowSeconds: 3600)
            let chain = FallbackInsightsProvider(
                providers: [
                    ExplodingProvider(
                        error: InsightsProviderError.creditsExhausted(provider: "DeepAPI", detail: "no balance"),
                        counter: counter
                    ),
                ],
                logger: req.logger,
                cooldowns: cooldowns
            )

            await #expect(throws: (any Error).self) {
                _ = try await chain.fetchTickerPosts(symbol: "AAPL", days: 7, limit: 10, on: req)
            }
            await #expect(throws: (any Error).self) {
                _ = try await chain.fetchTickerPosts(symbol: "MSFT", days: 7, limit: 10, on: req)
            }
            #expect(counter.count == 1)
        }
    }
}
