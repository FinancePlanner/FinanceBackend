import Fluent
import SQLKit

struct CreateExpenseImportSessions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("expense_import_sessions")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("status", .string, .required)
            .field("file_name", .string, .required)
            .field("sheet_count", .int, .required)
            .field("row_count", .int, .required)
            .field("ai_available", .bool, .required)
            .field("ai_model", .string)
            .field("ai_confidence", .double)
            .field("sheets_encrypted", .data, .required)
            .field("mapping_encrypted", .data, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("committed_at", .datetime)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        // Listing a user's open sessions, and the retention sweep.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS expense_import_sessions_user_created_idx ON expense_import_sessions (user_id, created_at)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS expense_import_sessions_expires_idx ON expense_import_sessions (expires_at)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("expense_import_sessions").delete()
    }
}
