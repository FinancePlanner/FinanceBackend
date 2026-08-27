import Foundation
import Vapor

/// Slash commands, handled before the model ever sees the text.
///
/// These live here rather than in the Telegram adapter because `/help` is not a
/// Telegram idea — every chat platform in use has the same leading slash. Only
/// the *menu registration* is platform-specific.
enum MessagingCommands {
    static let start = "/start"
    static let help = "/help"
    static let unlink = "/unlink"

    /// The published command menu. Exported so the adapter's `setMyCommands`
    /// cannot drift from what is actually implemented.
    ///
    /// `/start` is absent on purpose: Telegram renders a START button anyway,
    /// and listing it invites people to re-run pairing they have finished.
    static func published() -> [(name: String, description: String)] {
        [
            (name: "help", description: "what I can do"),
            (name: "unlink", description: "disconnect this chat from your account"),
        ]
    }

    /// Extracts a leading command, stripping the `@botname` suffix Telegram
    /// appends when several bots share a chat.
    static func parse(_ text: String) -> (command: String, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let head = parts.first else { return nil }
        var command = String(head).lowercased()
        if let at = command.firstIndex(of: "@") {
            command = String(command[command.startIndex ..< at])
        }
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (command, argument)
    }

    static let helpText = """
    I'm Q. Ask me about your spending, portfolio, budget or the markets — the same assistant that lives in the Norviq app, and the same conversation. "Hey Q" works, but you don't need it here.

    I can also propose changes, like logging an expense. I never apply one without you tapping Confirm first.

    /help — this message
    /unlink — disconnect this chat from your account
    """

    /// Runs a command if the text is one.
    ///
    /// Returns nil when the text is not a command *this bot implements* — and
    /// that includes unrecognised slash commands, which fall through to the
    /// model on purpose. "/summarise my month" is a sentence, not a typo.
    static func run(
        _ inbound: InboundMessage,
        userId: UUID,
        req: Request
    ) async throws -> OutboundMessage? {
        guard let parsed = parse(inbound.text) else { return nil }
        switch parsed.command {
        case start:
            return OutboundMessage(text: "This chat is already connected to your Norviq account. \(helpText)")
        case help:
            return OutboundMessage(text: helpText)
        case unlink:
            let removed = try await MessagingLinkService.unlink(
                userId: userId,
                platform: inbound.platform,
                req: req
            )
            return OutboundMessage(
                text: removed
                    ? "Disconnected. This chat no longer reaches your Norviq account. You can reconnect any time from Settings."
                    : "This chat was not connected."
            )
        default:
            return nil
        }
    }
}
