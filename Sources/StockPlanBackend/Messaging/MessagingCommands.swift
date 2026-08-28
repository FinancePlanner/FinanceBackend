import Fluent
import Foundation
import Vapor

/// What the dispatcher decided to do with a message.
enum MessagingCommandOutcome {
    /// Answered here, without the model.
    case reply(OutboundMessage)
    /// A known command carrying a question — `/budget how do I cut it?`. The
    /// command word is dropped and the rest goes to Q.
    case assistant(String)
}

/// Slash commands, handled before the model ever sees the text.
///
/// These live here rather than in the Telegram adapter because `/help` is not a
/// Telegram idea — every chat platform in use has the same leading slash. Only
/// the *menu registration* is platform-specific.
enum MessagingCommands {
    static let start = "/start"
    static let help = "/help"
    static let unlink = "/unlink"
    static let clear = "/clear"
    static let finance = "/finance"
    static let portfolio = "/portfolio"
    static let budget = "/budget"
    static let expenses = "/expenses"
    static let news = "/news"

    /// Commands answered from the database, with no model call and no turn spent
    /// from the monthly allowance.
    static let dataCommands: Set<String> = [finance, portfolio, budget, expenses, news]

    /// The published command menu. Exported so the adapter's `setMyCommands`
    /// cannot drift from what is actually implemented.
    ///
    /// `/start` is absent on purpose: Telegram renders a START button anyway,
    /// and listing it invites people to re-run pairing they have finished.
    static func published() -> [(name: String, description: String)] {
        [
            (name: "finance", description: "your money at a glance"),
            (name: "portfolio", description: "holdings, value, and today's move"),
            (name: "budget", description: "this month against your targets"),
            (name: "expenses", description: "what you have spent this month"),
            (name: "news", description: "signals and headlines on your holdings"),
            (name: "clear", description: "start a fresh conversation"),
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
    I'm Q. Ask me about your spending, portfolio, budget or the markets — the same assistant that lives in the Norviq app, and the same conversation. "Hey Q" and "@Q" both work, but you don't need either here.

    I can also propose changes, like logging an expense. I never apply one without you tapping Confirm first.

    These answer straight from your data, and never cost you an AI request:

    /finance — your money at a glance
    /portfolio — holdings, value, and today's move
    /budget — this month against your targets
    /expenses — what you have spent this month
    /news — signals and headlines on your holdings

    Add a question to any of them and I'll answer it myself instead — "/budget how do I cut it?".

    /clear — start a fresh conversation
    /help — this message
    /unlink — disconnect this chat from your account
    """

    /// Runs a command if the text is one.
    ///
    /// Returns nil when the text is not a command *this bot implements* — and
    /// that includes unrecognised slash commands, which fall through to the
    /// model on purpose. "/summarise my month" is a sentence, not a typo.
    ///
    /// The same reasoning is why a *known* data command carrying an argument
    /// returns `.assistant` rather than its canned reply: "/budget how do I cut
    /// it?" is also a sentence, and answering it with a table would be ignoring
    /// the question.
    static func run(
        _ inbound: InboundMessage,
        userId: UUID,
        req: Request
    ) async throws -> MessagingCommandOutcome? {
        guard let parsed = parse(inbound.text) else { return nil }

        if dataCommands.contains(parsed.command), !parsed.argument.isEmpty {
            return .assistant(parsed.argument)
        }

        switch parsed.command {
        case start:
            return .reply(OutboundMessage(text: "This chat is already connected to your Norviq account. \(helpText)"))
        case help:
            return .reply(OutboundMessage(text: helpText))
        case unlink:
            let removed = try await MessagingLinkService.unlink(
                userId: userId,
                platform: inbound.platform,
                req: req
            )
            return .reply(OutboundMessage(
                text: removed
                    ? "Disconnected. This chat no longer reaches your Norviq account. You can reconnect any time from Settings."
                    : "This chat was not connected."
            ))
        case clear:
            try await MessagingConversations.startFresh(userId: userId, req: req)
            return .reply(OutboundMessage(
                text: "Fresh start — I've forgotten what we were talking about. Your earlier messages are still in the app."
            ))
        case finance:
            return try await .reply(OutboundMessage(text: MessagingCommandReplies.finance(userId: userId, on: req)))
        case portfolio:
            return try await .reply(OutboundMessage(text: MessagingCommandReplies.portfolio(userId: userId, on: req)))
        case budget:
            return try await .reply(OutboundMessage(text: MessagingCommandReplies.budget(userId: userId, on: req)))
        case expenses:
            return try await .reply(OutboundMessage(text: MessagingCommandReplies.expenses(userId: userId, on: req)))
        case news:
            return try await .reply(OutboundMessage(text: MessagingCommandReplies.news(userId: userId, on: req)))
        default:
            return nil
        }
    }
}
