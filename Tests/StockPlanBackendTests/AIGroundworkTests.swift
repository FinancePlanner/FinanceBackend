import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

/// Covers the shared pieces the per-view AI summaries are built on, so a
/// regression in them is attributed here rather than surfacing as a puzzling
/// failure in a feature test.
@Suite("AI groundwork")
struct AIGroundworkTests {
    // MARK: - Read tools

    @Test("The assistant can see crypto holdings")
    func cryptoToolIsRegistered() {
        // Until this tool existed the registry had no crypto source at all, so
        // "how are my crypto holdings" was answered from the stock dashboard.
        #expect(AIReadToolRegistry.contains("get_crypto_portfolio"))
        let names = AIReadToolRegistry.toolDefinitions().map(\.function.name)
        #expect(names.contains("get_crypto_portfolio"))
    }

    @Test("Every declared read tool is executable, and no tool is declared twice")
    func toolDeclarationsAreConsistent() {
        let names = AIReadToolRegistry.toolDefinitions().map(\.function.name)
        #expect(Set(names).count == names.count, "a duplicate would shadow itself")
        for name in names {
            #expect(AIReadToolRegistry.contains(name), "\(name) is declared but unroutable")
        }
    }

    // MARK: - The response cache

    /// The in-memory double is what lets the cache-hit tests assert a hit at
    /// all: `RedisJSONCache` soft-fails to nil, so without a live Redis a real
    /// cache is indistinguishable from a broken one.
    @Test("The in-memory cache round-trips a value and misses on an unknown key")
    func inMemoryCacheRoundTrips() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let req = Request(application: app, on: app.eventLoopGroup.next())
        let cache = InMemoryAIResponseCache()

        struct Payload: Codable, Equatable {
            let text: String
        }

        #expect(await cache.get("absent", as: Payload.self, on: req) == nil)

        await cache.set("k", value: Payload(text: "hello"), ttlSeconds: 3600, on: req)
        #expect(await cache.get("k", as: Payload.self, on: req) == Payload(text: "hello"))

        // Keys are independent, so one feature's entry cannot answer another's.
        #expect(await cache.get("other", as: Payload.self, on: req) == nil)

        cache.removeAll()
        #expect(await cache.get("k", as: Payload.self, on: req) == nil)
    }

    @Test("A decode mismatch is a miss, not a crash")
    func cacheDecodeMismatchIsAMiss() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let req = Request(application: app, on: app.eventLoopGroup.next())
        let cache = InMemoryAIResponseCache()

        struct Written: Codable { let text: String }
        struct Expected: Codable { let count: Int }

        await cache.set("k", value: Written(text: "hello"), ttlSeconds: 60, on: req)
        // A cache key whose shape changed between deploys must degrade to a
        // regeneration rather than taking the request down. This is why cache
        // keys carry a version segment.
        #expect(await cache.get("k", as: Expected.self, on: req) == nil)
    }

    @Test("Redis absent means every read is a miss and every write is a no-op")
    func redisCacheWithoutRedisIsInert() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let req = Request(application: app, on: app.eventLoopGroup.next())
        // `.testing` configures no Redis, which is the degraded path in
        // production too: pay for the call again rather than fail the request.
        let cache = RedisJSONCache(label: "test")

        struct Payload: Codable { let text: String }

        await cache.set("k", value: Payload(text: "hello"), ttlSeconds: 60, on: req)
        #expect(await cache.get("k", as: Payload.self, on: req) == nil)
    }

    // MARK: - Highlight builders

    @Test("A builder with no data returns no highlights rather than zeroes")
    func buildersReturnNothingWithoutData() {
        let empty = AIInsightDataset()
        #expect(AIHighlightBuilders.portfolio(empty).isEmpty)
        #expect(AIHighlightBuilders.expenses(empty).isEmpty)
        #expect(AIHighlightBuilders.combined(empty).isEmpty)
    }

    @Test("Trend follows the sign of the change")
    func trendFollowsSign() {
        #expect(AIHighlightBuilders.trend(1.2) == "up")
        #expect(AIHighlightBuilders.trend(-0.4) == "down")
        #expect(AIHighlightBuilders.trend(0) == "flat")
    }

    @Test("Numbers format independently of the host locale")
    func numbersAreHostIndependent() {
        // Fixed en_US_POSIX on purpose: these strings are asserted in tests and
        // localised by the clients, so a server locale would make output depend
        // on the machine.
        #expect(AIHighlightBuilders.formatNumber(1234.5) == "1,234.50")
        #expect(AIHighlightBuilders.formatPercent(-2.5) == "-2.50%")
    }
}
