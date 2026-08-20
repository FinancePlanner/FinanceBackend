import Foundation

/// Where a retail post came from.
///
/// Raw values are persisted in `ticker_sentiment_posts.source` and are keys in
/// `SentimentSourceCounts`, so they are part of the storage contract — rename
/// one and you need a backfill.
enum SentimentSource: String, Codable, Sendable, CaseIterable {
    case x
    case reddit
    case stocktwits
    case news
    case investing
    case seekingAlpha = "seeking_alpha"

    /// Sources cheap enough to sweep across the whole S&P 500 tier.
    static let inexpensive: [SentimentSource] = [.news, .stocktwits, .reddit]

    /// Everything, reserved for symbols a user actually holds or watches.
    static let all: [SentimentSource] = SentimentSource.allCases
}

/// Which slice of the universe a symbol belongs to. Drives how much of the
/// daily ingestion budget it is allowed to spend.
enum SentimentTier: String, Codable, Sendable, CaseIterable {
    /// Someone holds or watches it. Every source, plus LLM themes.
    case user
    /// Index membership. Cheap sources only, no LLM.
    case sp500
    /// Surfaced by the firehose, held by nobody. Capped hard.
    case trending

    var sources: [SentimentSource] {
        switch self {
        case .user: SentimentSource.all
        case .sp500, .trending: SentimentSource.inexpensive
        }
    }

    var allowsLLMThemes: Bool {
        self == .user
    }

    /// Order the daily budget is spent in.
    var priority: Int {
        switch self {
        case .user: 0
        case .trending: 1
        case .sp500: 2
        }
    }
}
