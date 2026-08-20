import Fluent
import FluentSQL

struct CreateMessagingLinks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MessagingLink.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("platform", .string, .required)
            .field("external_id", .string, .required)
            .field("last_update_id", .int64, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .field("last_seen_at", .datetime)
            .unique(on: "platform", "external_id")
            .create()

        try await database.schema(MessagingLinkCode.schema).id()
            .field("code_hash", .data, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("platform", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("redeemed_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "code_hash")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX messaging_links_user_id_idx ON messaging_links (user_id)").run()
        try await sql.raw("CREATE INDEX messaging_link_codes_user_id_idx ON messaging_link_codes (user_id)").run()
        try await sql.raw("CREATE INDEX messaging_link_codes_expires_at_idx ON messaging_link_codes (expires_at)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MessagingLinkCode.schema).delete()
        try await database.schema(MessagingLink.schema).delete()
    }
}
