import Fluent
import Foundation
import Vapor

/// Conversation lifecycle for chat platforms.
///
/// Split out of `MessagingService` because `/clear` needs the same creation the
/// turn path needs, and two copies of "what a new Telegram conversation looks
/// like" would drift on the first change to the title or the expiry.
enum MessagingConversations {
    /// How long a conversation stays the live one without being touched. Matches
    /// the window the HTTP assistant uses when it extends a thread.
    static let lifetime: TimeInterval = 30 * 86400

    /// Reuses the newest live conversation so Telegram and the browser are the
    /// same thread — ask on the phone, scroll back on the desktop.
    static func resolve(userId: UUID, req: Request) async throws -> AIConversation {
        if let existing = try await newest(userId: userId, req: req) {
            return existing
        }
        return try await create(userId: userId, req: req)
    }

    /// Begins a new thread, leaving the old one alone.
    ///
    /// Nothing is deleted. `resolve` picks the newest live conversation, so a
    /// brand-new one simply wins, and the previous thread stays readable in the
    /// app until the retention job retires it on its own schedule. That is what
    /// people mean by "clear the chat" — forget the context, not burn the
    /// records.
    @discardableResult
    static func startFresh(userId: UUID, req: Request) async throws -> AIConversation {
        try await create(userId: userId, req: req)
    }

    private static func newest(userId: UUID, req: Request) async throws -> AIConversation? {
        try await AIConversation.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$expiresAt > Date())
            .sort(\.$updatedAt, .descending)
            .first()
    }

    private static func create(userId: UUID, req: Request) async throws -> AIConversation {
        let conversation = try AIConversation(
            userId: userId,
            titleEncrypted: req.userPIIEncryptionService.encryptString("Telegram"),
            expiresAt: Date().addingTimeInterval(lifetime)
        )
        try await conversation.create(on: req.db)
        return conversation
    }
}
