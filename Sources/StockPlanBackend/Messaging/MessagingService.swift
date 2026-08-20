import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Turns an inbound platform message into a reply, using the same assistant,
/// the same conversation and the same quota as the app.
///
/// Nothing here knows what Telegram is.
enum MessagingService {
    /// Prefixes on confirmation button payloads. These are matched exactly,
    /// before any free-text interpretation, so a tap is never ambiguous.
    static let confirmPrefix = "norviq:confirm:"
    static let declinePrefix = "norviq:decline:"

    static func handle(_ inbound: InboundMessage, req: Request) async throws -> OutboundMessage {
        // Group and channel traffic never reaches an account.
        guard inbound.isPrivateChat else { return .ignored }

        guard let link = try await claimUpdate(inbound, req: req) else {
            // Either unlinked, or a redelivery of an update already answered.
            if try await existingLink(inbound, req: req) != nil {
                return .ignored
            }
            return try await handleUnlinked(inbound, req: req)
        }

        if let handled = try await MessagingCommands.run(inbound, userId: link.userId, req: req) {
            return handled
        }

        return try await assistantTurn(inbound, userId: link.userId, req: req)
    }

    // MARK: - Identity and dedupe

    /// Resolves the sender and rejects a redelivery in one step.
    ///
    /// Telegram redelivers until it sees an ack, and an ack can be lost after
    /// the work is already done. The watermark makes the second delivery a
    /// no-op rather than a second answer — and a second charge against quota.
    private static func claimUpdate(_ inbound: InboundMessage, req: Request) async throws -> MessagingLink? {
        guard let link = try await existingLink(inbound, req: req) else { return nil }
        if inbound.updateID > 0 {
            guard inbound.updateID > link.lastUpdateID else { return nil }
            link.lastUpdateID = inbound.updateID
        }
        link.lastSeenAt = Date()
        try await link.save(on: req.db)
        return link
    }

    private static func existingLink(_ inbound: InboundMessage, req: Request) async throws -> MessagingLink? {
        try await MessagingLink.query(on: req.db)
            .filter(\.$platform == inbound.platform)
            .filter(\.$externalID == inbound.externalID)
            .first()
    }

    /// An unlinked chat can do exactly one thing: present a pairing code.
    /// Anything else it sends is answered with instructions, never forwarded.
    private static func handleUnlinked(_ inbound: InboundMessage, req: Request) async throws -> OutboundMessage {
        let attempt = MessagingLinkService.normalise(inbound.text)
        guard attempt.count == MessagingLinkService.codeLength else {
            return OutboundMessage(text: connectInstructions)
        }
        do {
            _ = try await MessagingLinkService.redeem(
                code: attempt,
                platform: inbound.platform,
                externalID: inbound.externalID,
                isPrivateChat: inbound.isPrivateChat,
                req: req
            )
            return OutboundMessage(text: "Connected. \(MessagingCommands.helpText)")
        } catch MessagingLinkService.RedeemFailure.rateLimited {
            return OutboundMessage(text: "Too many attempts. Wait a minute and try again.")
        } catch MessagingLinkService.RedeemFailure.alreadyLinkedToAnotherAccount {
            return OutboundMessage(text: "This chat is already connected to a different Norviq account.")
        } catch MessagingLinkService.RedeemFailure.notPrivateChat {
            return .ignored
        } catch MessagingLinkService.RedeemFailure.invalidCode {
            return OutboundMessage(text: "That code is not valid or has expired. Generate a new one in Norviq under Settings → Integrations.")
        }
    }

    static let connectInstructions = """
    This chat is not connected to a Norviq account yet.

    Open Norviq → Settings → Integrations → Telegram, tap Connect, and send me the 8-character code it shows you.
    """

    // MARK: - Assistant

    private static func assistantTurn(
        _ inbound: InboundMessage,
        userId: UUID,
        req: Request
    ) async throws -> OutboundMessage {
        // A confirmation resolves a proposal instead of starting a turn, and
        // costs no quota — the user is answering us, not asking.
        //
        // A tapped button is unambiguous and always counts. A typed "yes" only
        // counts while something is actually pending: otherwise every casual
        // "ok" or "go on" would be answered with "nothing to confirm" instead
        // of reaching the assistant.
        if let answer = parseConfirmationAnswer(inbound.text) {
            switch answer {
            case .approve, .decline:
                return try await resolveConfirmation(answer, userId: userId, req: req)
            case .approveLatest, .declineLatest:
                if try await latestPendingActionID(userId: userId, req: req) != nil {
                    return try await resolveConfirmation(answer, userId: userId, req: req)
                }
            }
        }

        let conversation = try await resolveConversation(userId: userId, req: req)
        do {
            let outcome = try await AIAssistantTurnCoordinator.run(
                userId: userId,
                conversation: conversation,
                content: inbound.text,
                req: req
            )
            guard let pending = outcome.pendingAction else {
                return OutboundMessage(text: outcome.text)
            }
            let actionID = try pending.requireID().uuidString
            return OutboundMessage(
                text: outcome.text,
                options: [
                    MessageOption(label: "Confirm", value: confirmPrefix + actionID),
                    MessageOption(label: "Cancel", value: declinePrefix + actionID),
                ]
            )
        } catch let abort as any AbortError {
            // Quota, kill switch and BYO-key failures all arrive here already
            // carrying a sentence written for a person to read.
            req.logger.warning("messaging_turn_refused status=\(abort.status.code)")
            return OutboundMessage(text: abort.reason)
        }
    }

    /// Reuses the newest live conversation so Telegram and the browser are the
    /// same thread — ask on the phone, scroll back on the desktop.
    private static func resolveConversation(userId: UUID, req: Request) async throws -> AIConversation {
        if let existing = try await AIConversation.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$expiresAt > Date())
            .sort(\.$updatedAt, .descending)
            .first()
        {
            return existing
        }
        let conversation = try AIConversation(
            userId: userId,
            titleEncrypted: req.userPIIEncryptionService.encryptString("Telegram"),
            expiresAt: Date().addingTimeInterval(30 * 86400)
        )
        try await conversation.create(on: req.db)
        return conversation
    }

    // MARK: - Confirmations

    enum ConfirmationAnswer {
        case approve(UUID)
        case decline(UUID)
        /// Typed rather than tapped, so the action is whichever one is pending.
        case approveLatest
        case declineLatest
    }

    /// Reads a button payload, or failing that a typed yes/no.
    ///
    /// Refusals are checked before approvals, deliberately: "no, please don't
    /// do that" contains "do that" and must never be read as consent.
    static func parseConfirmationAnswer(_ text: String) -> ConfirmationAnswer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(confirmPrefix), let id = UUID(uuidString: String(trimmed.dropFirst(confirmPrefix.count))) {
            return .approve(id)
        }
        if trimmed.hasPrefix(declinePrefix), let id = UUID(uuidString: String(trimmed.dropFirst(declinePrefix.count))) {
            return .decline(id)
        }
        let words = Set(
            trimmed.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
        guard !words.isEmpty else { return nil }
        if !words.isDisjoint(with: refusalWords) {
            return .declineLatest
        }
        if !words.isDisjoint(with: approvalWords) {
            return .approveLatest
        }
        return nil
    }

    private static let refusalWords: Set<String> = [
        "no", "nope", "cancel", "stop", "don't", "dont", "decline", "abort", "nevermind",
    ]
    private static let approvalWords: Set<String> = [
        "yes", "yep", "yeah", "confirm", "approve", "ok", "okay", "do", "go",
    ]

    private static func resolveConfirmation(
        _ answer: ConfirmationAnswer,
        userId: UUID,
        req: Request
    ) async throws -> OutboundMessage {
        let actionID: UUID?
        let approving: Bool
        switch answer {
        case let .approve(id): actionID = id; approving = true
        case let .decline(id): actionID = id; approving = false
        case .approveLatest: actionID = try await latestPendingActionID(userId: userId, req: req); approving = true
        case .declineLatest: actionID = try await latestPendingActionID(userId: userId, req: req); approving = false
        }
        guard let actionID else {
            // Nothing is waiting, so this was ordinary conversation after all.
            return OutboundMessage(text: "There's nothing waiting for confirmation right now.")
        }
        guard approving else {
            try await cancel(actionID: actionID, userId: userId, req: req)
            return OutboundMessage(text: "Cancelled. Nothing was changed.")
        }
        do {
            let result = try await AIAssistantTurnCoordinator.confirm(actionId: actionID, userId: userId, req: req)
            return OutboundMessage(text: result.message)
        } catch let abort as any AbortError where abort.status == .conflict {
            return OutboundMessage(text: "That action has expired or was already handled. Ask me again if you still want it.")
        }
    }

    private static func latestPendingActionID(userId: UUID, req: Request) async throws -> UUID? {
        try await AIPendingAction.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$status == AIActionStatus.pending.rawValue)
            .filter(\.$expiresAt > Date())
            .sort(\.$createdAt, .descending)
            .first()?
            .id
    }

    private static func cancel(actionID: UUID, userId: UUID, req: Request) async throws {
        guard let action = try await AIPendingAction.query(on: req.db)
            .filter(\.$id == actionID)
            .filter(\.$userId == userId)
            .filter(\.$status == AIActionStatus.pending.rawValue)
            .first()
        else { return }
        action.status = AIActionStatus.cancelled.rawValue
        try await action.save(on: req.db)
    }
}
