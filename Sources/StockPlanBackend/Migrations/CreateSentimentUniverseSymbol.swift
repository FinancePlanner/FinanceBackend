import Fluent

struct CreateSentimentUniverseSymbol: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("sentiment_universe_symbols")
            .id()
            .field("symbol", .string, .required)
            .field("tier", .string, .required)
            .field("added_at", .datetime, .required)
            .field("last_ingested_at", .datetime)
            .field("created_at", .datetime, .required)
            .unique(on: "symbol")
            .create()

        try await database.createIndex(on: "sentiment_universe_symbols", columns: ["tier"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("sentiment_universe_symbols").delete()
    }
}
