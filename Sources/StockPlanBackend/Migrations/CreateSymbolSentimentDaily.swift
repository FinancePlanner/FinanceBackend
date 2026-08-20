import Fluent

struct CreateSymbolSentimentDaily: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("symbol_sentiment_daily")
            .id()
            .field("symbol", .string, .required)
            .field("as_of_date", .string, .required)
            .field("window_days", .int, .required)
            .field("score", .double)
            .field("label", .string, .required)
            .field("confidence", .double)
            .field("post_count", .int, .required)
            .field("positive_count", .int, .required)
            .field("neutral_count", .int, .required)
            .field("negative_count", .int, .required)
            .field("source_counts", .json, .required)
            .field("volume_z", .double)
            .field("delta_1d", .double)
            .field("themes", .json)
            .field("themes_generated_at", .datetime)
            .field("captured_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "symbol", "as_of_date", "window_days")
            .create()

        // Batch lookup: "latest row for each of these symbols".
        try await database.createIndex(on: "symbol_sentiment_daily", columns: ["symbol", "as_of_date"])
        // Trending: order one day's rows by chatter volume, then by score.
        try await database.createIndex(on: "symbol_sentiment_daily", columns: ["as_of_date", "volume_z"])
        try await database.createIndex(on: "symbol_sentiment_daily", columns: ["as_of_date", "score"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("symbol_sentiment_daily").delete()
    }
}
