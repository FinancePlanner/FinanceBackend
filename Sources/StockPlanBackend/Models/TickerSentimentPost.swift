import Fluent
import Foundation
import Vapor

final class TickerSentimentPost: Model, Content, @unchecked Sendable {
    static let schema = "ticker_sentiment_posts"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "dedupe_key")
    var dedupeKey: String

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "author")
    var author: String?

    @Field(key: "author_handle")
    var authorHandle: String?

    @Field(key: "text")
    var text: String

    @Field(key: "url")
    var url: String?

    @Field(key: "sentiment_label")
    var sentimentLabel: String

    @Field(key: "sentiment_score")
    var sentimentScore: Double?

    @Field(key: "confidence")
    var confidence: Double?

    @Field(key: "posted_at")
    var postedAt: Date

    /// Which feed this post came from. Nil only for rows written before the
    /// multi-source ingest landed; `AddSourceToTickerSentimentPost` backfills
    /// those to `x`.
    @Field(key: "source")
    var source: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        dedupeKey: String,
        symbol: String,
        author: String?,
        authorHandle: String?,
        text: String,
        url: String?,
        sentimentLabel: String,
        sentimentScore: Double?,
        confidence: Double?,
        postedAt: Date,
        source: SentimentSource? = nil
    ) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.symbol = symbol
        self.author = author
        self.authorHandle = authorHandle
        self.text = text
        self.url = url
        self.sentimentLabel = sentimentLabel
        self.sentimentScore = sentimentScore
        self.confidence = confidence
        self.postedAt = postedAt
        self.source = source?.rawValue
    }

    var resolvedSource: SentimentSource {
        source.flatMap(SentimentSource.init(rawValue:)) ?? .x
    }
}
