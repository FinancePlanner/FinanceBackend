import Foundation
import Vapor

// MARK: - Hermes wire DTOs

// Decoded with the global backendAPI decoder, which normalizes snake_case keys
// to camelCase (event_id -> eventId, source_url -> sourceURL). Timestamps stay
// String because Hermes emits non-standard ISO variants; parse with
// parseHermesTimestamp.

struct HermesHealthResponse: Content {
    let ok: Bool
    let events: Int?
}

struct HermesEventPayload: Content {
    let title: String?
    let summary: String?
    let url: String?
    let author: String?
}

struct HermesEventSentiment: Content {
    let label: String?
    let score: Double?
}

struct HermesEventDTO: Content {
    let eventId: String
    let source: String?
    let sourceId: String?
    let topic: String?
    let observedAt: String?
    let ingestedAt: String?
    let payload: HermesEventPayload?
    let sentiment: HermesEventSentiment?
}

struct HermesEventsResponse: Content {
    let count: Int?
    let events: [HermesEventDTO]
}

struct HermesSummaryResponse: Content {
    let windowDays: Int?
    let totalEvents: Int?
    let byTopic: [String: Int]?
}

struct HermesSentimentResponse: Content {
    let topic: String?
    let windowDays: Int?
    let count: Int?
    let labelCounts: [String: Int]?
    let averageScore: Double?
    let sampled: Int?
}

struct HermesNetWorthEntry: Content {
    let eventId: String?
    let ingestedAt: String?
    let value: Double?
}

struct HermesNetWorthResponse: Content {
    let latest: HermesNetWorthEntry?
    let history: [HermesNetWorthEntry]?
}

struct HermesTickerPostDTO: Content {
    let eventId: String
    let author: String?
    let authorHandle: String?
    let text: String?
    let url: String?
    let sentiment: String?
    let sentimentScore: Double?
    let confidence: Double?
    let postedAt: String?
}

struct HermesTickerPostsResponse: Content {
    let symbol: String?
    let days: Int?
    let count: Int?
    let posts: [HermesTickerPostDTO]
}

/// Hermes emits timestamps like "2026-07-03T22:13:45+00:00" and (in older
/// builds) the malformed "2026-07-03T22:13:45+00:00Z". Accept both, plus a
/// bare "Z" suffix.
func parseHermesTimestamp(_ raw: String?) -> Date? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    if value.hasSuffix("Z"), value.contains("+") {
        value = String(value.dropLast())
    }
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: value) {
        return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

// MARK: - Public API responses

struct InsightEventResponse: Content {
    let id: String
    let topic: String
    let source: String
    let title: String?
    let summary: String?
    let sentimentLabel: String?
    let sentimentScore: Double?
    let url: String?
    let author: String?
    let observedAt: String
}

struct InsightsSummaryResponse: Content {
    let windowDays: Int
    let totalEvents: Int
    let byTopic: [String: Int]
    let latestEvents: [InsightEventResponse]
}

struct InsightsTopicResponse: Content {
    let topic: String
    let windowDays: Int
    let count: Int
    let events: [InsightEventResponse]
}

struct InsightsSentimentResponse: Content {
    let scope: String
    let topic: String?
    let windowDays: Int
    let averageScore: Double
    let label: String
    let eventCount: Int
    let positiveCount: Int
    let neutralCount: Int
    let negativeCount: Int
    let capturedAt: String
}

struct NetWorthPointResponse: Content {
    let value: Double?
    let capturedAt: String
}

struct InsightsNetWorthResponse: Content {
    let latest: NetWorthPointResponse?
    let history: [NetWorthPointResponse]
}

struct TickerPostResponse: Content {
    let author: String?
    let authorHandle: String?
    let text: String
    let url: String?
    let sentimentLabel: String
    let sentimentScore: Double?
    let confidence: Double?
    let postedAt: String
}

struct TickerSentimentAggregate: Content {
    let label: String
    let score: Double?
    let postCount: Int
}

struct TickerSentimentResponse: Content {
    let symbol: String
    let windowDays: Int
    let aggregate: TickerSentimentAggregate
    let posts: [TickerPostResponse]
}

struct InsightsSyncSummary: Content {
    let eventsInserted: Int
    let snapshotsUpserted: Int
    let tickerPostsInserted: Int
    let netWorthInserted: Int
    /// Ticker posts Hermes returned this tick, inserted or not. Inserted alone
    /// cannot tell a healthy steady state (nothing new upstream) apart from a
    /// broken link (nothing upstream at all) — both log 0.
    let tickerPostsFetched: Int
    /// Newest `postedAt` across everything Hermes returned, so a stale
    /// pipeline is visible in the log line instead of only in the database.
    let tickerPostsNewestAt: Date?
    /// Symbols whose fetch threw, so a partial outage is not read as healthy.
    let tickerSymbolsFailed: Int
}

struct TrackedSymbolsResponse: Content {
    let symbols: [String]
    let limit: Int
}
