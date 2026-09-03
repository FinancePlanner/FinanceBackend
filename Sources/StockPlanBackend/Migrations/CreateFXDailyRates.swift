import Fluent
import FluentSQL
import Foundation

/// Cache of ECB daily reference rates used by the filing pack. One row per
/// (date, base, quote); rows never change once published, so there is no
/// updated_at and re-inserts are rejected by the unique index.
final class FXDailyRateModel: Model, @unchecked Sendable {
    static let schema = "fx_daily_rates"

    @ID(key: .id) var id: UUID?
    @Field(key: "date") var date: Date
    @Field(key: "base") var base: String
    @Field(key: "quote") var quote: String
    @Field(key: "rate") var rate: Decimal

    init() {}

    init(value: FXDailyRate) {
        date = value.date
        base = value.base
        quote = value.quote
        rate = value.rate
    }

    var value: FXDailyRate {
        FXDailyRate(date: date, base: base, quote: quote, rate: rate)
    }
}

struct CreateFXDailyRates: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(FXDailyRateModel.schema)
            .id()
            .field("date", .date, .required)
            .field("base", .string, .required)
            .field("quote", .string, .required)
            .field("rate", .sql(unsafeRaw: "NUMERIC(18,8)"), .required)
            .unique(on: "date", "base", "quote")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(FXDailyRateModel.schema).delete()
    }
}
