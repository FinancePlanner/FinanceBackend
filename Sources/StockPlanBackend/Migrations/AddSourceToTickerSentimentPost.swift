import Fluent
import FluentSQL

struct AddSourceToTickerSentimentPost: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("ticker_sentiment_posts")
            .field("source", .string)
            .update()

        // Every row predating this migration came from the X scrape path, which
        // was the only per-ticker post source that ever ran.
        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE ticker_sentiment_posts SET source = 'x' WHERE source IS NULL").run()
        }

        try await database.createIndex(
            on: "ticker_sentiment_posts",
            columns: ["symbol", "source", "posted_at"]
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("ticker_sentiment_posts")
            .deleteField("source")
            .update()
    }
}
