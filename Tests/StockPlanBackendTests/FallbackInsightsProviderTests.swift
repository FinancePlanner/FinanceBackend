import Foundation
import NIOConcurrencyHelpers
@testable import StockPlanBackend
import Testing
import Vapor

/// Records whether it was consulted, so the tests can assert that a healthy
/// primary short-circuits the rest of the chain.
private final class CallCounter: @unchecked Sendable {
    private let lock = NIOLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

private struct CountingInsightsProvider: InsightsProvider {
    enum Behaviour {
        case succeeding(marker: String)
        case failing(reason: String)
    }

    let behaviour: Behaviour
    let counter: CallCounter
    let healthy: Bool

    init(behaviour: Behaviour, counter: CallCounter, healthy: Bool = true) {
        self.behaviour = behaviour
        self.counter = counter
        self.healthy = healthy
    }

    var isEnabled: Bool {
        true
    }

    func fetchEvents(days _: Int, limit _: Int, on _: Request) async throws -> HermesEventsResponse {
        counter.increment()
        switch behaviour {
        case let .succeeding(marker):
            return HermesEventsResponse(count: 1, events: [
                HermesEventDTO(
                    eventId: marker,
                    source: "test",
                    sourceId: marker,
                    topic: "Stocks",
                    observedAt: "2026-08-01T10:00:00+00:00",
                    ingestedAt: nil,
                    payload: HermesEventPayload(title: marker, summary: nil, url: nil, author: nil),
                    sentiment: nil
                ),
            ])
        case let .failing(reason):
            throw Abort(.badGateway, reason: reason)
        }
    }

    func fetchSummary(days: Int, on _: Request) async throws -> HermesSummaryResponse {
        counter.increment()
        switch behaviour {
        case .succeeding:
            return HermesSummaryResponse(windowDays: days, totalEvents: 1, byTopic: ["Stocks": 1])
        case let .failing(reason):
            throw Abort(.badGateway, reason: reason)
        }
    }

    func fetchSentiment(topic: String?, days: Int, on _: Request) async throws -> HermesSentimentResponse {
        counter.increment()
        switch behaviour {
        case .succeeding:
            return HermesSentimentResponse(
                topic: topic,
                windowDays: days,
                count: 1,
                labelCounts: ["positive": 1],
                averageScore: 0.5,
                sampled: 1
            )
        case let .failing(reason):
            throw Abort(.badGateway, reason: reason)
        }
    }

    func fetchNetWorth(on _: Request) async throws -> HermesNetWorthResponse {
        counter.increment()
        switch behaviour {
        case .succeeding:
            return HermesNetWorthResponse(latest: nil, history: [])
        case let .failing(reason):
            throw Abort(.badGateway, reason: reason)
        }
    }

    func fetchTickerPosts(symbol: String, days: Int, limit _: Int, on _: Request) async throws -> HermesTickerPostsResponse {
        counter.increment()
        switch behaviour {
        case let .succeeding(marker):
            return HermesTickerPostsResponse(symbol: symbol, days: days, count: 1, posts: [
                HermesTickerPostDTO(
                    eventId: marker,
                    author: nil,
                    authorHandle: nil,
                    text: marker,
                    url: nil,
                    sentiment: "bullish",
                    sentimentScore: 0.6,
                    confidence: nil,
                    postedAt: nil
                ),
            ])
        case let .failing(reason):
            throw Abort(.badGateway, reason: reason)
        }
    }

    func health(on _: Request) async -> Bool {
        healthy
    }
}

@Suite("FallbackInsightsProvider Tests")
struct FallbackInsightsProviderTests {
    /// A bare application: the chain never touches the database, so there is no
    /// need for `configure` (and no need for a live Postgres).
    private func withRequest(_ test: (Request) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            try await test(req)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("A healthy primary short-circuits the chain")
    func primaryWinsWithoutTouchingFallback() async throws {
        try await withRequest { req in
            let primaryCalls = CallCounter()
            let fallbackCalls = CallCounter()
            let provider = FallbackInsightsProvider(
                providers: [
                    CountingInsightsProvider(behaviour: .succeeding(marker: "primary"), counter: primaryCalls),
                    CountingInsightsProvider(behaviour: .succeeding(marker: "fallback"), counter: fallbackCalls),
                ],
                logger: Logger(label: "test")
            )

            let events = try await provider.fetchEvents(days: 3, limit: 10, on: req)

            #expect(events.events.first?.eventId == "primary")
            #expect(primaryCalls.count == 1)
            #expect(fallbackCalls.count == 0)
        }
    }

    @Test("A failing primary falls through to the next provider")
    func fallsThroughOnError() async throws {
        try await withRequest { req in
            let primaryCalls = CallCounter()
            let fallbackCalls = CallCounter()
            let provider = FallbackInsightsProvider(
                providers: [
                    CountingInsightsProvider(behaviour: .failing(reason: "hermes feed down"), counter: primaryCalls),
                    CountingInsightsProvider(behaviour: .succeeding(marker: "fallback"), counter: fallbackCalls),
                ],
                logger: Logger(label: "test")
            )

            let events = try await provider.fetchEvents(days: 3, limit: 10, on: req)
            #expect(events.events.first?.eventId == "fallback")

            // Every method on the protocol falls through, not just events.
            let posts = try await provider.fetchTickerPosts(symbol: "AMD", days: 7, limit: 5, on: req)
            #expect(posts.posts.first?.text == "fallback")
            let summary = try await provider.fetchSummary(days: 7, on: req)
            #expect(summary.totalEvents == 1)
            let sentiment = try await provider.fetchSentiment(topic: nil, days: 7, on: req)
            #expect(sentiment.count == 1)
            _ = try await provider.fetchNetWorth(on: req)

            #expect(primaryCalls.count == 5)
            #expect(fallbackCalls.count == 5)
        }
    }

    @Test("When every provider fails the last error is rethrown")
    func rethrowsLastErrorWhenAllFail() async throws {
        try await withRequest { req in
            let provider = FallbackInsightsProvider(
                providers: [
                    CountingInsightsProvider(behaviour: .failing(reason: "hermes feed down"), counter: CallCounter()),
                    CountingInsightsProvider(behaviour: .failing(reason: "deepapi credits exhausted"), counter: CallCounter()),
                ],
                logger: Logger(label: "test")
            )

            await #expect(throws: Abort.self) {
                _ = try await provider.fetchEvents(days: 3, limit: 10, on: req)
            }

            do {
                _ = try await provider.fetchEvents(days: 3, limit: 10, on: req)
                Issue.record("Expected the chain to throw once every provider failed")
            } catch let error as Abort {
                #expect(error.reason == "deepapi credits exhausted")
            }
        }
    }

    @Test("isEnabled and health reflect any live provider in the chain")
    func enabledAndHealthAggregate() async throws {
        try await withRequest { req in
            let provider = FallbackInsightsProvider(
                providers: [
                    CountingInsightsProvider(
                        behaviour: .failing(reason: "down"),
                        counter: CallCounter(),
                        healthy: false
                    ),
                    CountingInsightsProvider(
                        behaviour: .succeeding(marker: "fallback"),
                        counter: CallCounter(),
                        healthy: true
                    ),
                ],
                logger: Logger(label: "test")
            )

            #expect(provider.isEnabled)
            #expect(await provider.health(on: req))

            let allDown = FallbackInsightsProvider(
                providers: [
                    CountingInsightsProvider(
                        behaviour: .failing(reason: "down"),
                        counter: CallCounter(),
                        healthy: false
                    ),
                ],
                logger: Logger(label: "test")
            )
            #expect(await allDown.health(on: req) == false)
        }
    }
}
