import Fluent
import Foundation
import Vapor

/// Persists in-progress imports, encrypted, and hands them back only to the
/// user who created them.
///
/// Every lookup filters by `user_id` and reports a miss the same way whether the
/// session belongs to someone else, has expired, or never existed. Telling the
/// two apart would confirm the existence of another user's session.
struct ExpenseImportSessionStore {
    /// Long enough to review a few hundred rows without hurrying, short enough
    /// that an abandoned import isn't financial data sitting around all day.
    static let lifetime: TimeInterval = 60 * 60
    /// Keeps a user from stockpiling encrypted copies of their spreadsheets by
    /// uploading repeatedly and never finishing.
    static let maxOpenSessionsPerUser = 3

    /// What actually gets stored. Kept separate from the wire DTOs so the
    /// storage format can change without a shared-package release.
    struct StoredSheet: Codable, Sendable {
        struct Row: Codable, Sendable {
            /// 1-based worksheet row, so it matches what the user sees in Excel.
            let row: Int
            /// Column letter -> display text.
            let cells: [String: String]
        }

        let name: String
        let index: Int
        let rowCount: Int
        let headerRow: Int?
        let dataStartRow: Int
        let dataEndRow: Int
        let excludedRows: [Int]
        let columns: [StoredColumn]
        let rows: [Row]
        let notes: [String]
        let score: Double
    }

    struct StoredColumn: Codable, Sendable {
        let letter: String
        let header: String?
        let kind: String
        let samples: [String]
        let distinctCount: Int
        let role: String
        let confidence: Double
    }

    struct StoredMapping: Codable, Sendable {
        struct Category: Codable, Sendable {
            let sourceValue: String
            let pillar: String?
            let categoryId: String?
            let categoryName: String?
            let createCategory: Bool
            let confidence: Double
            let source: String
        }

        var selectedSheet: String?
        var columnRoles: [String: String]
        var categories: [Category]
        var amountSign: String
        var dateOrder: String
        var decimalSeparator: String
        var currency: String?
        var baseCurrency: String?
        var exchangeRates: [String: Double]
        var skippedRows: [Int]
        var notes: [String]
        var warnings: [String]
    }

    let encryption: any UserPIIEncrypting

    // MARK: - Create

    func create(
        userId: UUID,
        fileName: String,
        sheets: [StoredSheet],
        mapping: StoredMapping,
        aiAvailable: Bool,
        aiModel: String?,
        aiConfidence: Double?,
        on db: any Database
    ) async throws -> ExpenseImportSession {
        try await pruneExcessSessions(userId: userId, on: db)

        let session = try ExpenseImportSession(
            userID: userId,
            fileName: String(fileName.prefix(255)),
            sheetCount: sheets.count,
            rowCount: sheets.reduce(0) { $0 + $1.rows.count },
            aiAvailable: aiAvailable,
            aiModel: aiModel,
            aiConfidence: aiConfidence,
            sheetsEncrypted: encode(sheets),
            mappingEncrypted: encode(mapping),
            expiresAt: Date().addingTimeInterval(Self.lifetime)
        )
        try await session.create(on: db)
        return session
    }

    // MARK: - Read

    /// Loads a session the user owns and that is still usable.
    ///
    /// Throws `.notFound` for missing, expired, foreign and discarded sessions
    /// alike — the client message is the same in every case ("that import
    /// expired, upload the file again") and distinguishing them leaks.
    func load(id: UUID, userId: UUID, on db: any Database) async throws -> ExpenseImportSession {
        guard let session = try await ExpenseImportSession.query(on: db)
            .filter(\.$id == id)
            .filter(\.$user.$id == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "That import has expired. Upload the file again.")
        }
        if session.status == .committed {
            throw Abort(.conflict, reason: "This import was already applied.")
        }
        guard session.status == .ready, !session.isExpired else {
            throw Abort(.notFound, reason: "That import has expired. Upload the file again.")
        }
        return session
    }

    func sheets(of session: ExpenseImportSession) throws -> [StoredSheet] {
        try decode([StoredSheet].self, from: session.sheetsEncrypted)
    }

    func mapping(of session: ExpenseImportSession) throws -> StoredMapping {
        try decode(StoredMapping.self, from: session.mappingEncrypted)
    }

    // MARK: - Update

    func updateMapping(
        _ mapping: StoredMapping,
        on session: ExpenseImportSession,
        db: any Database
    ) async throws {
        session.mappingEncrypted = try encode(mapping)
        try await session.save(on: db)
    }

    func markCommitted(_ session: ExpenseImportSession, on db: any Database) async throws {
        session.status = .committed
        session.committedAt = Date()
        try await session.save(on: db)
    }

    /// Called when the user cancels, so an abandoned review doesn't sit
    /// encrypted-at-rest for the full hour.
    func discard(id: UUID, userId: UUID, on db: any Database) async throws {
        try await ExpenseImportSession.query(on: db)
            .filter(\.$id == id)
            .filter(\.$user.$id == userId)
            .delete()
    }

    // MARK: - Helpers

    private func pruneExcessSessions(userId: UUID, on db: any Database) async throws {
        let open = try await ExpenseImportSession.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$status == .ready)
            .sort(\.$createdAt, .descending)
            .all()
        guard open.count >= Self.maxOpenSessionsPerUser else { return }
        for session in open.dropFirst(Self.maxOpenSessionsPerUser - 1) {
            try await session.delete(on: db)
        }
    }

    private func encode(_ value: some Encodable) throws -> Data {
        let json = try JSONEncoder().encode(value)
        guard let text = String(data: json, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Could not store the import.")
        }
        return try encryption.encryptString(text)
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        let text = try encryption.decryptString(payload)
        guard let data = text.data(using: .utf8) else {
            throw Abort(.internalServerError, reason: "Could not read the stored import.")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

extension Request {
    var expenseImportSessionStore: ExpenseImportSessionStore {
        ExpenseImportSessionStore(encryption: userPIIEncryptionService)
    }
}
