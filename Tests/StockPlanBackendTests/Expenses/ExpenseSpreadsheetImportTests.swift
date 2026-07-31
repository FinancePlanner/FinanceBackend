import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

/// End-to-end analyze -> preview -> commit against a real database.
///
/// The AI provider is always stubbed: these tests must never make a network
/// call, and the interesting cases are what happens when the model is absent,
/// wrong, or unavailable — not when it's right.
@Suite("Spreadsheet import endpoints", .serialized)
struct ExpenseSpreadsheetImportTests {
    // MARK: - Harness

    private func withApp(_ test: @escaping (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func registerUser(app: Application) async throws -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "xlsx_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "xlsx_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(
            .POST, "v1/auth/register",
            beforeRequest: { req in try req.content.encode(register) },
            afterResponse: { res async throws in
                token = try res.content.decode(AuthResponse.self).token
            }
        )
        return token
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Spreadsheets/\(name)")
        return try Data(contentsOf: url)
    }

    private func upload(
        app: Application,
        token: String,
        fixtureNamed name: String = "excel-like.xlsx"
    ) async throws -> SpreadsheetImportAnalysisResponse {
        var analysis: SpreadsheetImportAnalysisResponse?
        try await app.testing().test(
            .POST, "v1/expenses/import/spreadsheet",
            beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.contentType = .binary
                req.headers.replaceOrAdd(name: "X-File-Name", value: name)
                req.body = try ByteBuffer(data: fixture(name))
            },
            afterResponse: { res async throws in
                #expect(res.status == .ok, "upload failed: \(res.body.string.prefix(300))")
                analysis = try res.content.decode(SpreadsheetImportAnalysisResponse.self)
            }
        )
        return try #require(analysis)
    }

    /// Turns an analysis into a decision that accepts what was proposed and
    /// assigns a pillar, which the server never fills in on its own.
    private func decision(
        from analysis: SpreadsheetImportAnalysisResponse,
        pillar: BudgetPillar = .fundamentals
    ) -> SpreadsheetImportDecisionRequest {
        let categories = Set(analysis.preview.rows.compactMap(\.sourceCategoryValue))
            .union(analysis.categoryMappings.map(\.sourceValue))
        return SpreadsheetImportDecisionRequest(
            sheets: analysis.sheets,
            categoryMappings: categories.map {
                .init(sourceValue: $0, pillar: pillar, confidence: 1, source: .user)
            },
            amountSign: analysis.amountSign
        )
    }

    // MARK: - Analyze

    @Test("analyzing a workbook returns a mapping and a preview")
    func analyzeReturnsPreview() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)

            #expect(!analysis.sessionId.isEmpty)
            #expect(analysis.fileName == "excel-like.xlsx")
            #expect(analysis.preview.totalRows > 0)
            // Header is on row 4 and data starts at column D.
            let sheet = try #require(analysis.sheets.first { $0.include })
            #expect(sheet.headerRow == 4)
            #expect(sheet.columns.contains { $0.field == .date })
            #expect(sheet.columns.contains { $0.field == .amount })
        }
    }

    /// With no provider configured the import has to keep working, just with
    /// weaker category mapping. This is also the privacy escape hatch.
    @Test("import works with the AI provider disabled")
    func worksWithoutAI() async throws {
        try await withApp { app in
            app.spreadsheetAnalysisProvider = DisabledSpreadsheetAnalysisProvider()
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)

            #expect(analysis.aiAvailable == false)
            #expect(analysis.preview.totalRows > 0)
            #expect(analysis.sheets.contains { $0.columns.contains { $0.field == .amount } })
        }
    }

    /// A totals row imported as an expense inflates every figure in the app.
    @Test("a totals row is excluded, not imported")
    func excludesTotalsRow() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)

            let sheet = try #require(analysis.sheets.first { $0.include })
            #expect(!sheet.excludedRows.isEmpty)
            #expect(analysis.preview.rows.contains { $0.status == .aggregateRow })
            #expect(!analysis.preview.rows.contains { $0.title == "TOTAL" && $0.status == .ok })
        }
    }

    @Test("a session can be resumed")
    func resumesSession() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)

            try await app.testing().test(
                .GET, "v1/expenses/import/spreadsheet/\(analysis.sessionId)",
                beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let resumed = try res.content.decode(SpreadsheetImportAnalysisResponse.self)
                    #expect(resumed.sessionId == analysis.sessionId)
                    #expect(resumed.preview.totalRows == analysis.preview.totalRows)
                }
            )
        }
    }

    // MARK: - Rejections

    @Test("a legacy .xls upload is refused with guidance")
    func rejectsLegacyBinary() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            try await app.testing().test(
                .POST, "v1/expenses/import/spreadsheet",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    req.headers.contentType = .binary
                    req.body = ByteBuffer(bytes: [0xD0, 0xCF, 0x11, 0xE0] + [UInt8](repeating: 0, count: 64))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unsupportedMediaType)
                    #expect(res.body.string.contains(".xlsx"))
                }
            )
        }
    }

    @Test("a non-spreadsheet upload is refused")
    func rejectsGarbage() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            try await app.testing().test(
                .POST, "v1/expenses/import/spreadsheet",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    req.headers.contentType = .binary
                    req.body = ByteBuffer(string: "definitely not a spreadsheet")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )
        }
    }

    @Test("an unauthenticated upload is refused")
    func requiresAuth() async throws {
        try await withApp { app in
            try await app.testing().test(
                .POST, "v1/expenses/import/spreadsheet",
                beforeRequest: { req in
                    req.headers.contentType = .binary
                    req.body = try ByteBuffer(data: fixture("excel-like.xlsx"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                }
            )
        }
    }

    /// A missing, expired and someone else's session must be indistinguishable,
    /// or the response confirms another user's session exists.
    @Test("another user's session reads as not found")
    func hidesOtherUsersSessions() async throws {
        try await withApp { app in
            let owner = try await registerUser(app: app)
            let stranger = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: owner)

            try await app.testing().test(
                .GET, "v1/expenses/import/spreadsheet/\(analysis.sessionId)",
                beforeRequest: { $0.headers.bearerAuthorization = .init(token: stranger) },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )
        }
    }

    @Test("an expired session reads as not found")
    func rejectsExpiredSession() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)

            let session = try #require(
                try await ExpenseImportSession.find(UUID(uuidString: analysis.sessionId), on: app.db)
            )
            session.expiresAt = Date().addingTimeInterval(-60)
            try await session.save(on: app.db)

            try await app.testing().test(
                .GET, "v1/expenses/import/spreadsheet/\(analysis.sessionId)",
                beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )
        }
    }

    // MARK: - Commit

    @Test("committing writes the approved rows and nothing else")
    func commitWritesRows() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)
            let importable = analysis.preview.rows.filter { $0.status == .needsCategory || $0.status == .ok }

            var commit: SpreadsheetImportCommitResponse?
            try await app.testing().test(
                .POST, "v1/expenses/import/spreadsheet/\(analysis.sessionId)/commit",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(decision(from: analysis))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok, "commit failed: \(res.body.string.prefix(300))")
                    commit = try res.content.decode(SpreadsheetImportCommitResponse.self)
                }
            )
            let result = try #require(commit)
            #expect(result.imported > 0)
            #expect(result.imported <= importable.count)
            #expect(!result.monthsTouched.isEmpty)

            // The rows really landed, and the totals row didn't come with them.
            try await app.testing().test(
                .GET, "v1/expenses",
                beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) },
                afterResponse: { res async throws in
                    let items = try res.content.decode([ExpenseResponse].self)
                    #expect(items.count == result.imported)
                    #expect(!items.contains { $0.title == "TOTAL" })
                    #expect(!items.contains { $0.amount == 954.59 })
                }
            )
        }
    }

    @Test("re-importing the same file reports duplicates instead of doubling")
    func secondImportDedupes() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)

            let first = try await upload(app: app, token: token)
            try await app.testing().test(
                .POST, "v1/expenses/import/spreadsheet/\(first.sessionId)/commit",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(decision(from: first))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let result = try res.content.decode(SpreadsheetImportCommitResponse.self)
                    #expect(result.imported > 0, "first import wrote nothing, so there is nothing to dedupe against")
                }
            )

            let second = try await upload(app: app, token: token)
            #expect(second.preview.duplicateRows > 0)
            #expect(second.preview.importableRows == 0)
        }
    }

    @Test("a committed session cannot be committed twice")
    func refusesDoubleCommit() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)
            let payload = decision(from: analysis)

            try await app.testing().test(
                .POST, "v1/expenses/import/spreadsheet/\(analysis.sessionId)/commit",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(payload)
                },
                afterResponse: { res async throws in #expect(res.status == .ok) }
            )
            try await app.testing().test(
                .POST, "v1/expenses/import/spreadsheet/\(analysis.sessionId)/commit",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(payload)
                },
                afterResponse: { res async throws in #expect(res.status == .conflict) }
            )
        }
    }

    @Test("rows the user deselects are not written")
    func honoursRowExclusions() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)

            let sheet = try #require(analysis.sheets.first { $0.include })
            var payload = decision(from: analysis)
            let excluded = analysis.preview.rows.prefix(2).map {
                SpreadsheetImportRowOverride(sheetName: sheet.name, row: $0.row, include: false)
            }
            payload = SpreadsheetImportDecisionRequest(
                sheets: payload.sheets,
                categoryMappings: payload.categoryMappings,
                rowOverrides: Array(excluded),
                amountSign: payload.amountSign
            )

            try await app.testing().test(
                .POST, "v1/expenses/import/spreadsheet/\(analysis.sessionId)/commit",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(payload)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let result = try res.content.decode(SpreadsheetImportCommitResponse.self)
                    #expect(result.skipped >= excluded.count)
                }
            )
        }
    }

    // MARK: - Session data

    /// The row holds someone's finances, so the stored blobs must not be
    /// readable by anyone with database access alone.
    @Test("stored session payloads are encrypted at rest")
    func storesPayloadsEncrypted() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)

            let session = try #require(
                try await ExpenseImportSession.find(UUID(uuidString: analysis.sessionId), on: app.db)
            )
            let sheetsText = String(decoding: session.sheetsEncrypted, as: UTF8.self)
            #expect(!sheetsText.contains("Continente"))
            #expect(!sheetsText.contains("Despesas"))
        }
    }

    @Test("discarding a session removes it")
    func discardRemovesSession() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)

            try await app.testing().test(
                .DELETE, "v1/expenses/import/spreadsheet/\(analysis.sessionId)",
                beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) },
                afterResponse: { res async throws in #expect(res.status == .noContent) }
            )
            let remaining = try await ExpenseImportSession.find(
                UUID(uuidString: analysis.sessionId), on: app.db
            )
            #expect(remaining == nil)
        }
    }

    @Test("the retention job deletes expired sessions")
    func retentionJobSweepsExpired() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let analysis = try await upload(app: app, token: token)

            let session = try #require(
                try await ExpenseImportSession.find(UUID(uuidString: analysis.sessionId), on: app.db)
            )
            session.expiresAt = Date().addingTimeInterval(-60)
            try await session.save(on: app.db)

            await ExpenseImportRetentionJob().runOnce(app)

            let remaining = try await ExpenseImportSession.find(
                UUID(uuidString: analysis.sessionId), on: app.db
            )
            #expect(remaining == nil)
        }
    }
}
