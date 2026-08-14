import Fluent
import FluentSQL

/// Storage for bring-your-own LLM provider keys.
///
/// No companion backfill migration exists, and none is needed: unlike
/// `EncryptBrokerConnectionTokens`, this table postdates the credential vault,
/// so every row is encrypted on write from the first one.
struct CreateUserAIProviderCredentials: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_ai_provider_credentials")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("label", .string, .required)
            .field("api_key_encrypted", .string, .required)
            .field("key_hint", .string, .required)
            .field("key_fingerprint", .string, .required)
            .field("base_url", .string)
            .field("default_model", .string)
            .field("status", .string, .required)
            .field("last_verified_at", .datetime)
            .field("last_used_at", .datetime)
            .field("last_error_code", .string)
            .field("last_error_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // One credential per provider per user. Re-adding a provider is an
            // upsert, which is also why DELETE is a hard delete: Fluent cannot
            // express a partial unique index, so a soft-revoked row would
            // permanently block re-adding that provider.
            .unique(on: "user_id", "provider")
            .create()

        try await database.createIndex(on: "user_ai_provider_credentials", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_ai_provider_credentials").delete()
    }
}
