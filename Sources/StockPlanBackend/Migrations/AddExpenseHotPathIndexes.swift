import Fluent
import FluentSQL

/// Indexes for the three tables every expenses/budget request filters by
/// `user_id` and then sorts or narrows by a second column.
///
/// `CreateExpensesTables` only declared foreign keys, and Postgres does not
/// index the referencing side of a foreign key. Until this migration every
/// expenses list (`ExpensesService.list*`, `getMonthlyReports`) was a sequential
/// scan of the whole table followed by an external sort on `occurred_on`, and
/// the IBKR dividend sync probed `dividends` once per statement row with no
/// index on `(account_id, external_id)`. Found in the 2026-09-02 audit.
///
/// Plain btree indexes serve both ascending and descending sorts, so no
/// `DESC` qualifier is needed on `occurred_on`.
struct AddExpenseHotPathIndexes: AsyncMigration {
    private static let indexes: [(table: String, columns: [String], name: String)] = [
        ("expenses", ["user_id", "occurred_on"], "idx_expenses_user_occurred_on"),
        ("budget_plan_items", ["user_id", "snapshot_id"], "idx_budget_plan_items_user_snapshot"),
        ("dividends", ["account_id", "external_id"], "idx_dividends_account_external_id"),
    ]

    func prepare(on database: any Database) async throws {
        for index in Self.indexes {
            try await database.createIndex(on: index.table, columns: index.columns, name: index.name)
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for index in Self.indexes {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
        }
    }
}
