import Fluent
import Foundation
import Vapor

/// Per-source post counts behind a day's aggregate. Stored as JSON so a new
/// source can be added without a migration; unknown keys decode to zero.
struct SentimentSourceCounts: Codable, Sendable, Equatable {
    var x: Int
    var reddit: Int
    var stocktwits: Int
    var news: Int
    var investing: Int
    var seekingAlpha: Int

    init(
        x: Int = 0,
        reddit: Int = 0,
        stocktwits: Int = 0,
        news: Int = 0,
        investing: Int = 0,
        seekingAlpha: Int = 0
    ) {
        self.x = x
        self.reddit = reddit
        self.stocktwits = stocktwits
        self.news = news
        self.investing = investing
        self.seekingAlpha = seekingAlpha
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Int.self, forKey: .x) ?? 0
        reddit = try container.decodeIfPresent(Int.self, forKey: .reddit) ?? 0
        stocktwits = try container.decodeIfPresent(Int.self, forKey: .stocktwits) ?? 0
        news = try container.decodeIfPresent(Int.self, forKey: .news) ?? 0
        investing = try container.decodeIfPresent(Int.self, forKey: .investing) ?? 0
        seekingAlpha = try container.decodeIfPresent(Int.self, forKey: .seekingAlpha) ?? 0
    }

    var total: Int {
        x + reddit + stocktwits + news + investing + seekingAlpha
    }

    subscript(source: SentimentSource) -> Int {
        get {
            switch source {
            case .x: x
            case .reddit: reddit
            case .stocktwits: stocktwits
            case .news: news
            case .investing: investing
            case .seekingAlpha: seekingAlpha
            }
        }
        set {
            switch source {
            case .x: x = newValue
            case .reddit: reddit = newValue
            case .stocktwits: stocktwits = newValue
            case .news: news = newValue
            case .investing: investing = newValue
            case .seekingAlpha: seekingAlpha = newValue
            }
        }
    }
}

/// One LLM-extracted talking point. Generated only for Tier A symbols; a
/// failure here leaves `themes` nil and the row still ships its score.
struct SentimentTheme: Codable, Sendable, Equatable {
    var label: String
    var stance: String
    var evidenceCount: Int
}

struct SentimentThemesPayload: Codable, Sendable, Equatable {
    var themes: [SentimentTheme]
    var summary: String?
    var contrarianFlag: Bool

    init(themes: [SentimentTheme], summary: String?, contrarianFlag: Bool) {
        self.themes = themes
        self.summary = summary
        self.contrarianFlag = contrarianFlag
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        themes = try container.decodeIfPresent([SentimentTheme].self, forKey: .themes) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        contrarianFlag = try container.decodeIfPresent(Bool.self, forKey: .contrarianFlag) ?? false
    }
}

/// Materialized daily sentiment aggregate for one symbol.
///
/// This is the read path for badges, portfolio roll-ups and trending. Raw posts
/// in `ticker_sentiment_posts` are the evidence; this table is the answer, so
/// list rendering never recomputes over posts (contrast the on-the-fly
/// aggregation in `DefaultInsightsService.tickerSentiment`).
///
/// `asOfDate` is a `yyyy-MM-dd` UTC string rather than a DATE column: it sorts
/// lexicographically, matches the dedupe-key idiom already used by
/// `SentimentSnapshot`, and sidesteps date/timestamp driver coercion.
final class SymbolSentimentDaily: Model, Content, @unchecked Sendable {
    static let schema = "symbol_sentiment_daily"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "as_of_date")
    var asOfDate: String

    @Field(key: "window_days")
    var windowDays: Int

    /// nil means "no chatter measured", never a neutral reading. Callers must
    /// render absence, not zero.
    @Field(key: "score")
    var score: Double?

    @Field(key: "label")
    var label: String

    @Field(key: "confidence")
    var confidence: Double?

    @Field(key: "post_count")
    var postCount: Int

    @Field(key: "positive_count")
    var positiveCount: Int

    @Field(key: "neutral_count")
    var neutralCount: Int

    @Field(key: "negative_count")
    var negativeCount: Int

    @Field(key: "source_counts")
    var sourceCounts: SentimentSourceCounts

    /// Chatter volume relative to this symbol's own trailing baseline. Drives
    /// trending — raw post count would just rank megacaps every day.
    @Field(key: "volume_z")
    var volumeZ: Double?

    @Field(key: "delta_1d")
    var delta1d: Double?

    @Field(key: "themes")
    var themes: SentimentThemesPayload?

    @Field(key: "themes_generated_at")
    var themesGeneratedAt: Date?

    @Field(key: "captured_at")
    var capturedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        symbol: String,
        asOfDate: String,
        windowDays: Int,
        score: Double?,
        label: String,
        confidence: Double?,
        postCount: Int,
        positiveCount: Int,
        neutralCount: Int,
        negativeCount: Int,
        sourceCounts: SentimentSourceCounts,
        volumeZ: Double? = nil,
        delta1d: Double? = nil,
        themes: SentimentThemesPayload? = nil,
        themesGeneratedAt: Date? = nil,
        capturedAt: Date
    ) {
        self.id = id
        self.symbol = symbol
        self.asOfDate = asOfDate
        self.windowDays = windowDays
        self.score = score
        self.label = label
        self.confidence = confidence
        self.postCount = postCount
        self.positiveCount = positiveCount
        self.neutralCount = neutralCount
        self.negativeCount = negativeCount
        self.sourceCounts = sourceCounts
        self.volumeZ = volumeZ
        self.delta1d = delta1d
        self.themes = themes
        self.themesGeneratedAt = themesGeneratedAt
        self.capturedAt = capturedAt
    }
}
