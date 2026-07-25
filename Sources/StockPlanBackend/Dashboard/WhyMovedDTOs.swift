import Vapor

// MARK: - GET /v1/dashboard/why-moved

/// The moat hero: top-moving holdings joined with Hermes X-sentiment, market
/// context, and one cached AI sentence. Every section degrades independently;
/// the endpoint always returns 200 for an authenticated user.
struct WhyMovedResponse: Content, Equatable {
    let asOf: String
    let portfolioChangePercent: Double?
    let portfolioChangeValue: Double?
    let movers: [WhyMovedMover]
    let context: WhyMovedContext
    let aiSummary: WhyMovedAISummary?
}

struct WhyMovedMover: Content, Equatable {
    let symbol: String
    let changePercent: Double
    /// Day contribution in portfolio currency.
    let contribution: Double?
    let weightPercent: Double?
    /// Hermes X-sentiment aggregate; nil when the pipeline has nothing.
    let sentiment: WhyMovedSentiment?
}

struct WhyMovedSentiment: Content, Equatable {
    let label: String
    let score: Double?
    let postCount: Int
}

struct WhyMovedContext: Content, Equatable {
    let indices: [WhyMovedIndex]
    let topics: [WhyMovedTopic]
}

struct WhyMovedIndex: Content, Equatable {
    let symbol: String
    let label: String
    let changePercent: Double
}

struct WhyMovedTopic: Content, Equatable {
    let topic: String
    let count: Int
}

struct WhyMovedAISummary: Content, Equatable {
    let text: String
    let generatedAt: String
}
