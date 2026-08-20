import Fluent
import Foundation
import Vapor

/// A symbol the daily aggregation job is responsible for.
///
/// Tier A (`.user`) rows are recomputed every run from live holdings and
/// watchlists. Tier B (`.sp500`) rows are seeded and refreshed out of band so
/// index membership changes do not need a deploy. Tier C (`.trending`) rows are
/// written by the job itself when the firehose surfaces a symbol nobody holds.
final class SentimentUniverseSymbol: Model, Content, @unchecked Sendable {
    static let schema = "sentiment_universe_symbols"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "tier")
    var tier: String

    @Field(key: "added_at")
    var addedAt: Date

    @Field(key: "last_ingested_at")
    var lastIngestedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        symbol: String,
        tier: SentimentTier,
        addedAt: Date = Date(),
        lastIngestedAt: Date? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.tier = tier.rawValue
        self.addedAt = addedAt
        self.lastIngestedAt = lastIngestedAt
    }

    var resolvedTier: SentimentTier {
        SentimentTier(rawValue: tier) ?? .trending
    }
}
