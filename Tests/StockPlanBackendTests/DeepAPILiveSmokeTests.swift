import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

/// Live contract check against DeepAPI. Opt-in because it makes real network
/// calls and debits real credits — `health` is a zero-spend dry run, but
/// `fetchEvents` runs one paid web search (~$0.005).
///
///     DEEPAPI_LIVE_SMOKE=1 DEEPAPI_API_KEY=... swift test --filter DeepAPILiveSmoke
///
/// It exists because the request bodies are validated strictly on DeepAPI's side
/// (`additionalProperties: false`, `maxCostUsd` as a decimal string) and the
/// payload is wrapped in an envelope — mistakes there fail every call at runtime
/// while still compiling perfectly.
@Suite(
    "DeepAPI live smoke",
    .enabled(if: ProcessInfo.processInfo.environment["DEEPAPI_LIVE_SMOKE"] == "1")
)
struct DeepAPILiveSmokeTests {
    private func withProvider(_ test: (DeepAPIInsightsProvider, Request) async throws -> Void) async throws {
        let apiKey = try #require(
            ProcessInfo.processInfo.environment["DEEPAPI_API_KEY"],
            "DEEPAPI_API_KEY must be set for the live smoke test"
        )
        let app = try await Application.make(.testing)
        do {
            let provider = DeepAPIInsightsProvider(
                apiKey: apiKey,
                baseURL: ProcessInfo.processInfo.environment["DEEPAPI_API_BASE_URL"] ?? "https://deepapi.co",
                httpClient: app.client,
                logger: app.logger
            )
            let req = Request(application: app, on: app.eventLoopGroup.next())
            try await test(provider, req)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("health passes as a zero-spend dry run")
    func healthIsGreen() async throws {
        try await withProvider { provider, req in
            #expect(await provider.health(on: req))
        }
    }

    @Test("fetchEvents decodes real web-search results")
    func fetchEventsReturnsRealEvents() async throws {
        try await withProvider { provider, req in
            let response = try await provider.fetchEvents(days: 3, limit: 10, on: req)

            // The sentiment filter drops results with no directional keywords, so
            // a low count is fine — an empty one means the contract broke.
            #expect(response.count == response.events.count)
            let event = try #require(response.events.first, "DeepAPI returned no usable events")
            let title = try #require(event.payload?.title)
            #expect(!title.isEmpty)
            #expect(event.source == "deepapi-web")
            #expect(event.sentiment?.label != nil)
        }
    }
}
