import Fluent

struct CreateMessagingPreferences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MessagingPreference.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("platform", .string, .required)
            .field("kind", .string, .required)
            .field("enabled", .bool, .required, .sql(.default(false)))
            .field("quiet_hours_start", .int)
            .field("quiet_hours_end", .int)
            .field("timezone", .string, .required, .sql(.default("UTC")))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "platform", "kind")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MessagingPreference.schema).delete()
    }
}
