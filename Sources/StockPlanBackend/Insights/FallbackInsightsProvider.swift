import Foundation
import Vapor

/// Tries a list of insights providers in order and returns the first success.
///
/// The chain exists so a dead upstream does not take insights down with it: the
/// self-hosted Hermes agent is primary, and DeepAPI takes over whenever a Hermes
/// call fails (feed outage, rejected upstream key, network). It works the other
/// way too — a DeepAPI response that fails because the account ran out of credit
/// is just another thrown error, so the next provider in the chain gets a turn.
///
/// Only a single provider is ever consulted per call in the happy path; the
/// fallbacks are touched exactly when the one before them throws.
struct FallbackInsightsProvider: InsightsProvider {
    let providers: [any InsightsProvider]
    let logger: Logger

    var isEnabled: Bool {
        providers.contains { $0.isEnabled }
    }

    func fetchEvents(days: Int, limit: Int, on req: Request) async throws -> HermesEventsResponse {
        try await firstSuccess("events") { try await $0.fetchEvents(days: days, limit: limit, on: req) }
    }

    func fetchSummary(days: Int, on req: Request) async throws -> HermesSummaryResponse {
        try await firstSuccess("summary") { try await $0.fetchSummary(days: days, on: req) }
    }

    func fetchSentiment(topic: String?, days: Int, on req: Request) async throws -> HermesSentimentResponse {
        try await firstSuccess("sentiment") { try await $0.fetchSentiment(topic: topic, days: days, on: req) }
    }

    func fetchNetWorth(on req: Request) async throws -> HermesNetWorthResponse {
        try await firstSuccess("net-worth") { try await $0.fetchNetWorth(on: req) }
    }

    func fetchTickerPosts(symbol: String, days: Int, limit: Int, on req: Request) async throws -> HermesTickerPostsResponse {
        try await firstSuccess("ticker-posts") {
            try await $0.fetchTickerPosts(symbol: symbol, days: days, limit: limit, on: req)
        }
    }

    func health(on req: Request) async -> Bool {
        for provider in providers where await provider.health(on: req) {
            return true
        }
        return false
    }

    /// Runs `operation` against each provider in turn. The first value wins; a
    /// thrown error is logged and the next provider is tried. When every
    /// provider fails the last error is rethrown, so callers keep seeing the
    /// same `Abort` surface a single provider would have produced.
    private func firstSuccess<T>(
        _ label: String,
        _ operation: (any InsightsProvider) async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?

        for (index, provider) in providers.enumerated() {
            do {
                return try await operation(provider)
            } catch {
                lastError = error
                logger.warning(
                    "Insights provider \(index + 1)/\(providers.count) failed for \(label), falling through: \(String(reflecting: error))"
                )
            }
        }

        throw lastError ?? Abort(.serviceUnavailable, reason: "No insights provider configured.")
    }
}

/// Resolves the insights provider chain from the environment.
///
/// Hermes is primary (self-hosted, reached only over the private Tailscale
/// network) and DeepAPI is the fallback that takes over whenever a Hermes call
/// throws. With neither `HERMES_BASE_URL` nor `DEEPAPI_API_KEY` set, insights
/// boot disabled.
func makeInsightsProvider(_ app: Application) -> any InsightsProvider {
    var chain: [any InsightsProvider] = []
    var names: [String] = []

    let hermesBaseURL = Environment.get("HERMES_BASE_URL")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let hermesBaseURL, !hermesBaseURL.isEmpty {
        chain.append(HermesInsightsProvider(
            baseURL: hermesBaseURL,
            apiToken: Environment.get("HERMES_API_TOKEN")?.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        names.append("hermes")
    }

    let deepAPIKey = Environment.get("DEEPAPI_API_KEY")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let deepAPIKey, !deepAPIKey.isEmpty {
        chain.append(DeepAPIInsightsProvider(
            apiKey: deepAPIKey,
            baseURL: Environment.get("DEEPAPI_API_BASE_URL")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "https://deepapi.co",
            httpClient: app.client,
            logger: app.logger,
            maxCostUsd: Environment.get("DEEPAPI_MAX_COST_USD")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.05",
            socialScrapingEnabled: Environment.get("DEEPAPI_SOCIAL_SCRAPING_ENABLED")
                .flatMap(Bool.init(_:)) ?? false
        ))
        names.append("deepapi")
    }

    guard !chain.isEmpty else {
        app.logger.warning("No insights provider configured (set HERMES_BASE_URL or DEEPAPI_API_KEY)")
        return DisabledInsightsProvider()
    }

    app.logger.info("Insights providers: \(names.joined(separator: " -> "))")
    return chain.count == 1 ? chain[0] : FallbackInsightsProvider(providers: chain, logger: app.logger)
}
