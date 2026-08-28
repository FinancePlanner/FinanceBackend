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

    /// The conversation this chat writes into: Telegram and the browser stay the
    /// same thread — ask on the phone, scroll back on the desktop.
    ///
    /// The pairing is a stored reference on the link rather than "whichever
    /// thread was touched last". Guessing worked most of the time and then
    /// surprised people: creating a conversation in the app silently moved where
    /// Telegram wrote, a Telegram message silently changed which thread the app
    /// opened next launch, and nothing could opt out. A key makes both of those
    /// deliberate instead.
    static func resolve(link: MessagingLink, req: Request) async throws -> AIConversation {
        let userId = link.userId

        if let bound = link.conversationId,
           let existing = try await AIConversation.query(on: req.db)
           .filter(\.$id == bound)
           .filter(\.$userId == userId)
           .filter(\.$expiresAt > Date())
           .first()
        {
            return existing
        }

        // Unbound, or bound to a thread that has since expired or been deleted.
        // Adopting the newest live thread is what this did before the pairing
        // existed, and it is still right for a first message: it is how a chat
        // linked today joins the conversation the app is already showing.
        let conversation: AIConversation = if let newest = try await newest(userId: userId, req: req) {
            newest
        } else {
            try await create(userId: userId, req: req)
        }
        try await bind(link: link, to: conversation, req: req)
        return conversation
    }

    /// Begins a new thread, leaving the old one alone.
    ///
    /// Nothing is deleted. The previous thread stays readable in the app until
    /// the retention job retires it on its own schedule. That is what people
    /// mean by "clear the chat" — forget the context, not burn the records.
    ///
    /// Repointing the link is what makes `/clear` mean anything now that the
    /// pairing is stored: without it the chat would keep writing into the thread
    /// the user just asked to leave.
    ///
    /// Keyed by user rather than by link because `/clear` is dispatched from
    /// `MessagingCommands`, which resolves the sender to an account, not to a
    /// row — and every chat that account has linked should follow a deliberate
    /// fresh start anyway.
    @discardableResult
    static func startFresh(userId: UUID, req: Request) async throws -> AIConversation {
        let conversation = try await create(userId: userId, req: req)
        try await bindLinks(userId: userId, to: conversation.requireID(), req: req)
        return conversation
    }

    /// Points every chat a user has linked at a conversation.
    ///
    /// Called when a conversation is created outside a chat — the app's "New
    /// conversation" button — so that starting fresh means starting fresh
    /// everywhere rather than leaving Telegram on a thread the user believes
    /// they already left. A no-op for users with no linked chats.
    static func bindLinks(userId: UUID, to conversationId: UUID, req: Request) async throws {
        try await MessagingLink.query(on: req.db)
            .filter(\.$userId == userId)
            .set(\.$conversationId, to: conversationId)
            .update()
    }

    /// Writes the pairing only when it actually changed. `claimUpdate` already
    /// saves the link on every inbound message; a second unconditional UPDATE
    /// per message would buy nothing.
    private static func bind(
        link: MessagingLink,
        to conversation: AIConversation,
        req: Request
    ) async throws {
        let id = try conversation.requireID()
        guard link.conversationId != id else { return }
        link.conversationId = id
        try await link.save(on: req.db)
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
