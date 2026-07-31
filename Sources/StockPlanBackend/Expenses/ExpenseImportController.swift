import Fluent
import Foundation
import StockPlanShared
import Vapor

/// AI-assisted .xlsx expense import.
///
/// - `POST   /v1/expenses/import/spreadsheet`             upload and analyze (Pro, costs an AI call)
/// - `GET    /v1/expenses/import/spreadsheet/:id`         resume a review in progress
/// - `POST   /v1/expenses/import/spreadsheet/:id/preview`  re-derive after a mapping change (no AI)
/// - `POST   /v1/expenses/import/spreadsheet/:id/commit`   write the approved rows
/// - `DELETE /v1/expenses/import/spreadsheet/:id`         cancel and drop the stored data
///
/// Registered as its own collection rather than folded into `ExpensesController`:
/// that one is mounted without rate-limit middleware, and these endpoints spend
/// Norviq's AI budget, so they need their own throttled group.
struct ExpenseImportController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let imports = protected
            .grouped("expenses", "import", "spreadsheet")
            // First-party only: this spends our AI budget, so scoped MCP tokens
            // must not reach it, matching the assistant endpoints.
            .grouped(ScopeRequirementMiddleware(.expensesWrite), FirstPartyOnlyMiddleware())

        imports.on(
            .POST,
            body: .collect(maxSize: ByteCount(value: SpreadsheetLimits.default.maxBytes)),
            use: analyze
        )
        imports.get(":sessionID", use: fetch)
        imports.post(":sessionID", "preview", use: preview)
        imports.post(":sessionID", "commit", use: commit)
        imports.delete(":sessionID", use: discard)
    }

    // MARK: - Analyze

    @Sendable
    func analyze(req: Request) async throws -> SpreadsheetImportAnalysisResponse {
        let session = try req.auth.require(SessionToken.self)

        // Gate before parsing so a free user never spends server time on a file
        // they can't import.
        try await req.usageCounterService.requirePremium(
            .spreadsheetImport, userId: session.userId, on: req.db
        )

        let (data, fileName) = try await readUpload(req)

        // The daily AI cap is charged only when a model will actually be
        // called; heuristic-only imports shouldn't consume anyone's allowance.
        let provider = req.spreadsheetAnalysisProvider
        if provider.isEnabled {
            try await AIDailyCap.enforce(
                req,
                userId: session.userId,
                unavailableReason: "Spreadsheet import is unavailable right now. Try again shortly.",
                limitReachedReason: "You've reached today's AI limit. Try again tomorrow, or import a CSV."
            )
        }

        let response = try await makeService(req).analyze(
            data: data, fileName: fileName, userId: session.userId, on: req
        )
        req.logger.info(
            "spreadsheet_import_analyze sheets=\(response.sheets.count) rows=\(response.preview.totalRows) ai=\(response.aiAvailable)"
        )
        return response
    }

    // MARK: - Fetch

    @Sendable
    func fetch(req: Request) async throws -> SpreadsheetImportAnalysisResponse {
        let session = try req.auth.require(SessionToken.self)
        let store = req.expenseImportSessionStore
        let record = try await store.load(
            id: sessionID(req), userId: session.userId, on: req.db
        )

        let sheets = try store.sheets(of: record)
        let mapping = try store.mapping(of: record)
        let service = makeService(req)
        let preview = try await service.previewOnly(
            sheets: sheets, mapping: mapping, userId: session.userId, on: req.db
        )

        return try SpreadsheetImportAnalysisResponse(
            sessionId: record.requireID().uuidString,
            fileName: record.fileName,
            expiresAt: ISO8601DateFormatter().string(from: record.expiresAt),
            sheets: sheets.map { ExpenseSpreadsheetImportService.wireSheet($0, mapping: mapping) },
            categoryMappings: ExpenseSpreadsheetImportService.wireCategories(mapping.categories),
            amountSign: SpreadsheetImportAmountSign(rawValue: mapping.amountSign) ?? .positiveIsExpense,
            detectedCurrency: mapping.currency,
            baseCurrency: mapping.baseCurrency,
            dateFormat: mapping.dateOrder,
            preview: preview,
            aiAvailable: record.aiAvailable,
            aiConfidence: record.aiConfidence,
            warnings: mapping.warnings
        )
    }

    // MARK: - Preview

    @Sendable
    func preview(req: Request) async throws -> SpreadsheetImportPreviewResponse {
        let session = try req.auth.require(SessionToken.self)
        // Re-checked on every step so a downgrade mid-review can't slip through.
        try await req.usageCounterService.requirePremium(
            .spreadsheetImport, userId: session.userId, on: req.db
        )

        let record = try await req.expenseImportSessionStore.load(
            id: sessionID(req), userId: session.userId, on: req.db
        )
        let decision = try req.content.decode(SpreadsheetImportDecisionRequest.self)
        return try await makeService(req).preview(
            session: record, decision: decision, userId: session.userId, on: req.db
        )
    }

    // MARK: - Commit

    @Sendable
    func commit(req: Request) async throws -> SpreadsheetImportCommitResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .spreadsheetImport, userId: session.userId, on: req.db
        )

        let record = try await req.expenseImportSessionStore.load(
            id: sessionID(req), userId: session.userId, on: req.db
        )
        let decision = try req.content.decode(SpreadsheetImportDecisionRequest.self)
        let response = try await makeService(req).commit(
            session: record, decision: decision, userId: session.userId, on: req
        )

        try await req.usageCounterService.incrementUsage(
            .spreadsheetImport, userId: session.userId, by: 1, on: req.db
        )
        req.logger.info(
            "spreadsheet_import_commit imported=\(response.imported) skipped=\(response.skipped) failed=\(response.failed)"
        )
        return response
    }

    // MARK: - Discard

    @Sendable
    func discard(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await req.expenseImportSessionStore.discard(
            id: sessionID(req), userId: session.userId, on: req.db
        )
        return .noContent
    }

    // MARK: - Helpers

    private func makeService(_ req: Request) -> ExpenseSpreadsheetImportService {
        ExpenseSpreadsheetImportService(
            reader: CoreXLSXSpreadsheetReader(),
            provider: req.spreadsheetAnalysisProvider,
            store: req.expenseImportSessionStore,
            expensesService: req.expensesService
        )
    }

    private func sessionID(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("sessionID"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid import id.")
        }
        return id
    }

    private struct SpreadsheetUpload: Content {
        var file: File?
        var spreadsheet: File?
    }

    /// Accepts multipart or a raw body, matching the receipts and broker
    /// uploads. The filename is only ever used for display.
    private func readUpload(_ req: Request) async throws -> (data: Data, fileName: String) {
        let maxBytes = SpreadsheetLimits.default.maxBytes

        if req.headers.contentType?.type.lowercased() == "multipart" {
            let upload = try req.content.decode(SpreadsheetUpload.self)
            guard let file = upload.file ?? upload.spreadsheet else {
                throw Abort(.badRequest, reason: "Missing file field in multipart body.")
            }
            var buffer = file.data
            guard buffer.readableBytes <= maxBytes else {
                throw Abort(.payloadTooLarge, reason: "Spreadsheet must be \(maxBytes / (1024 * 1024)) MB or smaller.")
            }
            let data = buffer.readData(length: buffer.readableBytes) ?? Data()
            return (data, sanitize(file.filename))
        }

        guard var buffer = try await req.body.collect(max: maxBytes).get() else {
            throw Abort(.badRequest, reason: "Missing spreadsheet body.")
        }
        let data = buffer.readData(length: buffer.readableBytes) ?? Data()
        let headerName = req.headers.first(name: "X-File-Name")
        return (data, sanitize(headerName ?? "spreadsheet.xlsx"))
    }

    /// Client-supplied and echoed back to the client, so strip path separators
    /// and control characters rather than trusting it.
    private func sanitize(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "[/\\\\\\u{0}-\\u{1F}]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "spreadsheet.xlsx" : String(cleaned.prefix(255))
    }
}
