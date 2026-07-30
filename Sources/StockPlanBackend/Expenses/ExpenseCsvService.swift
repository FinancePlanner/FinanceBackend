import Fluent
import Foundation
import StockPlanShared
import Vapor

/// CSV import/export for expenses. Import is atomic-per-row with a dry-run mode
/// and dedup; export streams a UTF-8 BOM CSV (matching Export/ExportService).
struct ExpenseCsvService {
    static let maxRows = 1000
    static let maxBytes = 1_048_576 // 1 MB
    static let columns = ["title", "amount", "currency", "pillar", "category", "occurred_on", "external_id"]

    let expensesService: any ExpensesService
    let request: Request?

    init(expensesService: any ExpensesService, request: Request? = nil) {
        self.expensesService = expensesService
        self.request = request
    }

    // MARK: - Import

    enum RowOutcome: String, Content {
        case imported
        case skippedDuplicate = "skipped_duplicate"
        case error
    }

    struct RowResult: Content {
        let line: Int
        let outcome: RowOutcome
        let message: String?
    }

    struct ImportResult: Content {
        let dryRun: Bool
        let total: Int
        let imported: Int
        let skipped: Int
        let failed: Int
        let rows: [RowResult]
    }

    func importCSV(
        _ csv: String,
        userId: UUID,
        dryRun: Bool,
        categoriesByName: [String: String],
        on db: any Database
    ) async throws -> ImportResult {
        guard csv.utf8.count <= Self.maxBytes else {
            throw Abort(.payloadTooLarge, reason: "CSV exceeds \(Self.maxBytes / 1024)KB limit.")
        }
        let parsed = try parse(csv)
        guard parsed.count <= Self.maxRows else {
            throw Abort(.badRequest, reason: "CSV exceeds \(Self.maxRows) row limit.")
        }

        let importer = ExpenseBulkImporter(expensesService: expensesService, request: request)

        // Phase 1 — validate and classify every row without writing.
        var rows: [RowResult] = []
        var candidates: [ExpenseBulkImporter.Candidate] = []
        var pendingKeys: [Int: String] = [:]
        var skipped = 0, failed = 0

        for (index, fields) in parsed.enumerated() {
            let line = index + 2 // 1-based + header row
            do {
                let request = try buildRequest(fields, categoriesByName: categoriesByName)
                let key = ExpenseBulkImporter.dedupKey(
                    occurredOn: request.occurredOn, amount: request.amount, title: request.title,
                    externalID: fields["external_id"]
                )
                candidates.append(
                    ExpenseBulkImporter.Candidate(
                        reference: line, request: request, externalID: fields["external_id"]
                    )
                )
                pendingKeys[line] = key
                rows.append(RowResult(line: line, outcome: .imported, message: nil))
            } catch {
                rows.append(RowResult(line: line, outcome: .error, message: ExpenseBulkImporter.friendly(error)))
                failed += 1
            }
        }

        // Existing dedup keys for this user, narrowed to the file's own date span.
        var seen = try await importer.existingDedupKeys(
            userId: userId,
            occurredOnRange: ExpenseBulkImporter.occurredOnRange(of: candidates),
            on: db
        )

        // Drop duplicates, both against existing expenses and within the file.
        var toImport: [ExpenseBulkImporter.Candidate] = []
        var resultByLine = Dictionary(uniqueKeysWithValues: rows.map { ($0.line, $0) })
        for candidate in candidates {
            guard let key = pendingKeys[candidate.reference] else { continue }
            if seen.contains(key) {
                resultByLine[candidate.reference] = RowResult(
                    line: candidate.reference, outcome: .skippedDuplicate, message: nil
                )
                skipped += 1
                continue
            }
            seen.insert(key)
            toImport.append(candidate)
        }
        rows = rows.map { resultByLine[$0.line] ?? $0 }

        guard !dryRun, !toImport.isEmpty else {
            return ImportResult(
                dryRun: dryRun, total: parsed.count,
                imported: toImport.count, skipped: skipped, failed: failed, rows: rows
            )
        }

        // Phases 2 and 3 — snapshots, inserts and drift, shared with every other importer.
        let outcome = try await importer.insert(toImport, userId: userId, on: db)
        for (line, message) in outcome.failures {
            resultByLine[line] = RowResult(line: line, outcome: .error, message: message)
            failed += 1
        }

        let finalRows = rows.map { resultByLine[$0.line] ?? $0 }
        return ImportResult(
            dryRun: dryRun, total: parsed.count,
            imported: outcome.imported, skipped: skipped, failed: failed, rows: finalRows
        )
    }

    // MARK: - Export

    func exportCSV(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> String {
        let (items, _) = try await expensesService.getExpenses(
            userId: userId, from: from, to: to, limit: 10000, cursor: nil, on: db
        )
        var out = "\u{FEFF}" // UTF-8 BOM
        out += "title,amount,pillar,category_id,occurred_on\n"
        for e in items {
            out += [
                csvEscape(e.title),
                String(e.amount),
                e.pillar.rawValue,
                e.categoryId ?? "",
                e.occurredOn,
            ].joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: - Parsing

    /// Minimal RFC 4180 parser: handles quoted fields, embedded commas, and
    /// doubled quotes. Returns one dictionary per data row keyed by header.
    func parse(_ csv: String) throws -> [[String: String]] {
        let records = splitRecords(csv)
        guard let headerLine = records.first else { return [] }
        let headers = splitFields(headerLine).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard headers.contains("title"), headers.contains("amount"), headers.contains("pillar"),
              headers.contains("occurred_on")
        else {
            throw Abort(.badRequest, reason: "CSV header must include title, amount, pillar, occurred_on.")
        }
        var out: [[String: String]] = []
        for record in records.dropFirst() where !record.isEmpty {
            let fields = splitFields(record)
            var row: [String: String] = [:]
            for (i, header) in headers.enumerated() where i < fields.count {
                row[header] = fields[i].trimmingCharacters(in: .whitespaces)
            }
            out.append(row)
        }
        return out
    }

    private func splitRecords(_ csv: String) -> [String] {
        // Split on newlines that are not inside quotes.
        var records: [String] = []
        var current = ""
        var inQuotes = false
        for char in csv {
            if char == "\"" {
                inQuotes.toggle()
            }
            if char == "\n" || char == "\r\n", !inQuotes {
                records.append(current)
                current = ""
            } else if char == "\r", !inQuotes {
                continue
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            records.append(current)
        }
        return records
    }

    private func splitFields(_ record: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = record.makeIterator()
        var pending: Character? = iterator.next()
        while let char = pending {
            pending = iterator.next()
            if char == "\"" {
                if inQuotes, pending == "\"" {
                    current.append("\"")
                    pending = iterator.next()
                } else {
                    inQuotes.toggle()
                }
            } else if char == ",", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    // MARK: - Helpers

    private func buildRequest(_ fields: [String: String], categoriesByName: [String: String]) throws -> ExpenseRequest {
        guard let title = fields["title"], !title.isEmpty else {
            throw Abort(.badRequest, reason: "missing title")
        }
        guard let amountStr = fields["amount"], let amount = Double(amountStr) else {
            throw Abort(.badRequest, reason: "invalid amount")
        }
        guard let pillarRaw = fields["pillar"], let pillar = BudgetPillar(rawValue: pillarRaw) else {
            throw Abort(.badRequest, reason: "invalid pillar")
        }
        guard let occurredOn = fields["occurred_on"], !occurredOn.isEmpty else {
            throw Abort(.badRequest, reason: "missing occurred_on")
        }
        var categoryId: String?
        if let name = fields["category"], !name.isEmpty {
            categoryId = categoriesByName[name.lowercased()]
        }
        return ExpenseRequest(
            title: title, amount: amount, pillar: pillar, occurredOn: occurredOn,
            categoryId: categoryId
        )
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
