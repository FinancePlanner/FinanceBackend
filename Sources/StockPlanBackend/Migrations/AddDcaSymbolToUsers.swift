import Fluent

struct AddDcaSymbolToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("dca_symbol", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("dca_symbol")
            .update()
    }
}
