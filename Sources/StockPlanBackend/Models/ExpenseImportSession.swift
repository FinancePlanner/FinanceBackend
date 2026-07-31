import Fluent
import Foundation

/// A spreadsheet import in progress.
///
/// The upload itself is never stored. What is stored is the parsed grid and the
/// validated mapping, so the review screen can re-preview a changed mapping
/// without re-uploading the file or paying for a second model call.
///
/// Both payloads are user financial data, so both are encrypted at rest with
/// the same service `AIPendingAction` uses, the row cascades from the user, and
/// it expires within the hour whether or not the client cleans up after itself.
final class ExpenseImportSession: Model, @unchecked Sendable {
    static let schema = "expense_import_sessions"

    enum Status: String, Codable {
        case ready
        case committed
        case discarded
    }

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "status")
    var status: Status

    @Field(key: "file_name")
    var fileName: String

    @Field(key: "sheet_count")
    var sheetCount: Int

    @Field(key: "row_count")
    var rowCount: Int

    /// Whether a model contributed to the stored mapping. Surfaced to the client
    /// so the UI can say the mapping is heuristic-only rather than pretend.
    @Field(key: "ai_available")
    var aiAvailable: Bool

    @OptionalField(key: "ai_model")
    var aiModel: String?

    @OptionalField(key: "ai_confidence")
    var aiConfidence: Double?

    /// JSON of the parsed sheets, encrypted.
    @Field(key: "sheets_encrypted")
    var sheetsEncrypted: Data

    /// JSON of the validated mapping, encrypted.
    @Field(key: "mapping_encrypted")
    var mappingEncrypted: Data

    @Field(key: "expires_at")
    var expiresAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalField(key: "committed_at")
    var committedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        fileName: String,
        sheetCount: Int,
        rowCount: Int,
        aiAvailable: Bool,
        aiModel: String? = nil,
        aiConfidence: Double? = nil,
        sheetsEncrypted: Data,
        mappingEncrypted: Data,
        expiresAt: Date
    ) {
        self.id = id
        $user.id = userID
        status = .ready
        self.fileName = fileName
        self.sheetCount = sheetCount
        self.rowCount = rowCount
        self.aiAvailable = aiAvailable
        self.aiModel = aiModel
        self.aiConfidence = aiConfidence
        self.sheetsEncrypted = sheetsEncrypted
        self.mappingEncrypted = mappingEncrypted
        self.expiresAt = expiresAt
    }

    var isExpired: Bool {
        expiresAt <= Date()
    }
}
