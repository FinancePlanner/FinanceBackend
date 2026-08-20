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
    /// Shared across every call so one exhausted-credit answer suppresses the
    /// rest of the run, not just the call that discovered it.
    let cooldowns: ProviderCooldownRegistry

    init(
        providers: [any InsightsProvider],
        logger: Logger,
        cooldowns: ProviderCooldownRegistry = ProviderCooldownRegistry()
    ) {
        self.providers = providers
        self.logger = logger
        self.cooldowns = cooldowns
    }

    /// Union of what every non-cooling provider in the chain can serve.
    var supportedSentimentSources: [SentimentSource] {
        var seen = Set<SentimentSource>()
        var ordered: [SentimentSource] = []
        for provider in providers where !cooldowns.isCoolingDown(provider.providerLabel) {
            for source in provider.supportedSentimentSources where seen.insert(source).inserted {
                ordered.append(source)
            }
        }
        return ordered
    }

    func fetchSymbolPosts(
        symbols: [String],
        sources: [SentimentSource],
        days: Int,
        limit: Int,
        on req: Request
    ) async throws -> [SymbolPostBatch] {
        try await firstSuccess("symbol-posts") {
            try await $0.fetchSymbolPosts(
                symbols: symbols,
                sources: sources,
                days: days,
                limit: limit,
                on: req
            )
        }
    }

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
        var skipped = 0

        for (index, provider) in providers.enumerated() {
            let providerLabel = provider.providerLabel
            if cooldowns.isCoolingDown(providerLabel) {
                skipped += 1
                continue
            }

            do {
                let value = try await operation(provider)
                // A success means whatever put it in cooldown is resolved.
                cooldowns.clear(providerLabel)
                return value
            } catch let error as InsightsProviderError where error.isTerminalUntilTopUp {
                lastError = error
                let until = cooldowns.beginCooldown(providerLabel)
                logger.error(
                    "Insights provider \(providerLabel) is out of credit for \(label); suppressed until \(until). \(error.reason)"
                )
            } catch {
                lastError = error
                logger.warning(
                    "Insights provider \(index + 1)/\(providers.count) failed for \(label), falling through: \(String(reflecting: error))"
                )
            }
        }

        if let lastError {
            throw lastError
        }
        if skipped > 0 {
            throw Abort(
                .serviceUnavailable,
                reason: "Every insights provider is in credit cooldown."
            )
        }
        throw Abort(.serviceUnavailable, reason: "No insights provider configured.")
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

    // Last link: free and already-paid-for endpoints, reached directly. It
    // covers fewer venues than DeepAPI on purpose — Investing.com and Seeking
    // Alpha have no free API — so an exhausted balance thins the readings
    // instead of stopping them.
    let directProvider = DirectAPIInsightsProvider(
        redditClientID: Environment.get("REDDIT_CLIENT_ID")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        redditClientSecret: Environment.get("REDDIT_CLIENT_SECRET")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        redditUserAgent: Environment.get("REDDIT_USER_AGENT")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "norviq-sentiment/1.0",
        newsProvider: (Environment.get("FINNHUB_API_KEY")?.isEmpty == false)
            ? FinnhubNewsProvider()
            : nil,
        logger: app.logger
    )
    if directProvider.isEnabled {
        chain.append(directProvider)
        names.append("direct")
    }

    guard !chain.isEmpty else {
        app.logger.warning("No insights provider configured (set HERMES_BASE_URL or DEEPAPI_API_KEY)")
        return DisabledInsightsProvider()
    }

    app.logger.info("Insights providers: \(names.joined(separator: " -> "))")

    // Registered unconditionally so the readiness endpoint can always ask what
    // is in cooldown, even on a single-provider chain.
    let cooldowns = ProviderCooldownRegistry(
        windowSeconds: TimeInterval(
            Environment.get("PROVIDER_CREDIT_COOLDOWN_SECONDS").flatMap(Int.init(_:)) ?? 6 * 60 * 60
        )
    )
    app.providerCooldowns = cooldowns

    guard chain.count > 1 else { return chain[0] }
    return FallbackInsightsProvider(providers: chain, logger: app.logger, cooldowns: cooldowns)
}
