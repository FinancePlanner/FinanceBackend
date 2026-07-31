import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Shared write path for bulk expense imports.
///
/// Extracted from `ExpenseCsvService` so every importer (CSV today, spreadsheet
/// next) dedupes, creates snapshots and re-evaluates budget drift the same way.
/// Callers own parsing and validation; this type owns everything from "here are
/// the rows I want to insert" onwards.
struct ExpenseBulkImporter {
    /// A row a caller has already parsed and validated.
    struct Candidate {
        /// Caller-defined identifier echoed back in failures — a CSV line
        /// number, a worksheet row number, whatever the caller reports on.
        let reference: Int
        let request: ExpenseRequest
        /// Optional stable id from the source document. When present it alone
        /// determines duplicate identity.
        let externalID: String?

        init(reference: Int, request: ExpenseRequest, externalID: String? = nil) {
            self.reference = reference
            self.request = request
            self.externalID = externalID
        }
    }

    struct InsertOutcome {
        let imported: Int
        /// Keyed by `Candidate.reference`. A row failing here does not affect
        /// the others — each insert is its own statement.
        let failures: [Int: String]
        let months: Set<Date>
    }

    let expensesService: any ExpensesService
    let request: Request?

    init(expensesService: any ExpensesService, request: Request? = nil) {
        self.expensesService = expensesService
        self.request = request
    }

    // MARK: - Dedup

    static func dedupKey(occurredOn: String, amount: Double, title: String, externalID: String?) -> String {
        if let externalID, !externalID.isEmpty {
            return "ext:\(externalID)"
        }
        return "\(occurredOn)|\(amount)|\(title.lowercased())"
    }

    /// Preloads dedup keys for expenses the user already has.
    ///
    /// `occurredOnRange` narrows the query to the incoming document's own date
    /// span. Existing rows only ever produce `occurredOn|amount|title` keys
    /// (never `ext:`), and a duplicate must share `occurredOn`, so anything
    /// outside the range cannot collide — the narrowing is exact, not a
    /// heuristic. It matters because the unbounded query is capped at 10 000
    /// rows, past which dedup silently degraded for heavy users.
    ///
    /// The range is padded by a day on each side before querying: `occurred_on`
    /// is a DATE column, and binding a `Date` to it round-trips through the
    /// session timezone, so an exact bound can drop the very row it should
    /// match (`getExpenses` guards its cursor against the same hazard). Padding
    /// only widens the key set, and keys are compared as exact strings, so
    /// extra days cost a little memory and change no outcome.
    func existingDedupKeys(
        userId: UUID,
        occurredOnRange: ClosedRange<Date>?,
        on db: any Database
    ) async throws -> Set<String> {
        let padded = occurredOnRange.map { range in
            (
                from: range.lowerBound.addingTimeInterval(-86400),
                to: range.upperBound.addingTimeInterval(86400)
            )
        }
        let (items, _) = try await expensesService.getExpenses(
            userId: userId,
            from: padded?.from,
            to: padded?.to,
            limit: 10000,
            cursor: nil,
            on: db
        )
        return Set(items.map {
            Self.dedupKey(occurredOn: $0.occurredOn, amount: $0.amount, title: $0.title, externalID: nil)
        })
    }

    /// Inclusive span of the candidates' `occurredOn` values, for
    /// `existingDedupKeys`. Nil when nothing parses as a date.
    static func occurredOnRange(of candidates: [Candidate]) -> ClosedRange<Date>? {
        let dates = candidates.compactMap { parseDate($0.request.occurredOn) }
        guard let min = dates.min(), let max = dates.max() else { return nil }
        return min ... max
    }

    // MARK: - Insert

    /// Creates the accepted rows, then re-evaluates budget drift per touched month.
    func insert(
        _ candidates: [Candidate],
        userId: UUID,
        on db: any Database
    ) async throws -> InsertOutcome {
        guard !candidates.isEmpty else {
            return InsertOutcome(imported: 0, failures: [:], months: [])
        }

        let months = Set(candidates.compactMap { Self.monthStart(for: $0.request.occurredOn) })

        // Ensure each distinct month's snapshot exists exactly once. We avoid
        // createExpense here: it re-runs ensureSnapshotExists per row, and within
        // a single request that repeated find-or-create races into a duplicate
        // snapshot insert. One ensure per month sidesteps that.
        for month in months {
            try await expensesService.ensureSnapshotExists(userId: userId, monthStart: month, on: db)
        }

        var imported = 0
        var failures: [Int: String] = [:]
        for candidate in candidates {
            do {
                try await insertExpense(candidate.request, userId: userId, on: db)
                imported += 1
            } catch {
                failures[candidate.reference] = Self.friendly(error)
            }
        }

        await evaluateDrift(userId: userId, months: months)

        return InsertOutcome(imported: imported, failures: failures, months: months)
    }

    /// Best-effort: a drift failure must never fail an import that already wrote rows.
    func evaluateDrift(userId: UUID, months: Set<Date>) async {
        guard let request else { return }
        for month in months {
            do {
                try await BudgetDriftEvaluator(req: request).evaluate(userId: userId, monthStart: month, notify: true)
            } catch {
                request.logger.warning(
                    "budget drift evaluation after bulk import failed userId=\(userId.uuidString) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func insertExpense(_ request: ExpenseRequest, userId: UUID, on db: any Database) async throws {
        guard let occurredOn = Self.parseDate(request.occurredOn) else {
            throw Abort(.badRequest, reason: "Invalid occurredOn format. Expected YYYY-MM-DD.")
        }
        let expense = Expense(
            userID: userId,
            title: request.title,
            amount: request.amount,
            pillar: request.pillar,
            occurredOn: occurredOn,
            splitMode: request.splitMode,
            userSharePercent: request.userSharePercent
        )
        if let catIdStr = request.categoryId, let catId = UUID(uuidString: catIdStr) {
            expense.$category.id = catId
        }
        try await expense.create(on: db)
    }

    // MARK: - Date helpers

    static func parseDate(_ string: String) -> Date? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        return df.date(from: string)
    }

    /// Month start (UTC, day 1) for a YYYY-MM-DD string, matching the service's
    /// snapshot normalization.
    static func monthStart(for occurredOn: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = parseDate(occurredOn) else { return nil }
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = 1
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return calendar.date(from: comps)
    }

    static func friendly(_ error: any Error) -> String {
        if let abort = error as? any AbortError {
            return abort.reason
        }
        return "\(error)"
    }
}
