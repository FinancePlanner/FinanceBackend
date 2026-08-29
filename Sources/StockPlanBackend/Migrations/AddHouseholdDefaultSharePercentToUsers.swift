import Fluent

/// Stores the household's default split ratio: the percentage of a shared item
/// the account owner keeps, so 40 means the partner covers 60%.
///
/// Nullable on purpose — null means "no default set", which clients treat
/// differently from an explicit 0 or 100. Unlike the partner's display name this
/// is not encrypted: a ratio is not personal data, and keeping it plain avoids
/// adding a field to the encrypt/decrypt path in `User`.
struct AddHouseholdDefaultSharePercentToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("household_default_user_share_percent", .double)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("household_default_user_share_percent")
            .update()
    }
}
