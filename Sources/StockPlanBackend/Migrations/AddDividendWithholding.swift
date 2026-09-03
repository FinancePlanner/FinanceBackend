import Fluent

/// Withholding tax and gross amount per dividend, so a filing pack can report
/// foreign tax already paid at source. Both stay optional: rows imported
/// before this migration, or from brokers whose feed has no withholding
/// line, simply carry `nil` and the pack reports the net amount as gross.
struct AddDividendWithholding: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("dividends")
            .field("withholding_tax", .double)
            .field("gross_amount", .double)
            .field("source_country", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("dividends")
            .deleteField("withholding_tax")
            .deleteField("gross_amount")
            .deleteField("source_country")
            .update()
    }
}
