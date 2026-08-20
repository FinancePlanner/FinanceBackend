import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Pure logic — no database, no network.
@Suite("Telegram formatting and parsing")
struct TelegramFormatTests {
    @Test("Markdown becomes Telegram HTML")
    func convertsMarkdown() {
        #expect(TelegramFormat.html("**bold**") == "<b>bold</b>")
        #expect(TelegramFormat.html("*italic*") == "<i>italic</i>")
        #expect(TelegramFormat.html("# Heading") == "<b>Heading</b>")
        #expect(TelegramFormat.html("- one\n- two") == "• one\n• two")
        #expect(TelegramFormat.html("[Norviq](https://norviq.org)") == "<a href=\"https://norviq.org\">Norviq</a>")
    }

    @Test("Angle brackets are escaped so Telegram does not read them as tags")
    func escapesMarkup() {
        #expect(TelegramFormat.html("a < b & c > d") == "a &lt; b &amp; c &gt; d")
        // The apostrophe must survive: escaping quotes turns ordinary prose
        // into a wall of &#39;.
        #expect(TelegramFormat.html("it's fine").contains("it's fine"))
    }

    @Test("Code spans are escaped but never styled")
    func preservesCode() {
        let out = TelegramFormat.html("use `a < b` here")
        #expect(out == "use <code>a &lt; b</code> here")
        // Emphasis markers inside code are content, not formatting.
        #expect(TelegramFormat.html("`**not bold**`") == "<code>**not bold**</code>")
    }

    @Test("The plain fallback keeps the words and the link target")
    func plainFallback() {
        #expect(TelegramFormat.plain("**bold**") == "bold")
        #expect(TelegramFormat.plain("[Norviq](https://norviq.org)") == "Norviq (https://norviq.org)")
    }

    @Test("Long text splits on boundaries, never losing content")
    func splitsLongText() {
        let paragraph = String(repeating: "word ", count: 2000)
        let parts = TelegramFormat.split(paragraph)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.count <= TelegramFormat.maxMessageCharacters })
        let rejoined = parts.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
        #expect(rejoined.trimmingCharacters(in: .whitespaces).hasPrefix("word word"))
    }

    @Test("Short text is one message and empty text is none")
    func splitsShortText() {
        #expect(TelegramFormat.split("hello") == ["hello"])
        #expect(TelegramFormat.split("").isEmpty)
    }
}

@Suite("Telegram update routing")
struct TelegramUpdateTests {
    private func update(from json: String) throws -> TelegramUpdate {
        try JSONDecoder().decode(TelegramUpdate.self, from: Data(json.utf8))
    }

    @Test("A private message becomes an answerable inbound message")
    func privateMessage() throws {
        let parsed = try update(from: #"{"update_id":7,"message":{"message_id":1,"chat":{"id":4242,"type":"private"},"text":"hi"}}"#)
        guard case let .answer(inbound) = parsed.intent else {
            Issue.record("expected an answerable intent"); return
        }
        #expect(inbound.externalID == "4242")
        #expect(inbound.updateID == 7)
        #expect(inbound.text == "hi")
        #expect(inbound.isPrivateChat)
    }

    @Test("A group delivery is refused and the bot leaves")
    func groupMessage() throws {
        let parsed = try update(from: #"{"update_id":8,"message":{"message_id":1,"chat":{"id":-100200,"type":"supergroup"},"text":"hi"}}"#)
        guard case let .leave(chatID) = parsed.intent else {
            Issue.record("expected a leave intent"); return
        }
        #expect(chatID == "-100200")
    }

    @Test("A button tap arrives on the same path as typed text")
    func callbackQuery() throws {
        let parsed = try update(from: #"{"update_id":9,"callback_query":{"id":"cb1","data":"norviq:confirm:x","message":{"message_id":1,"chat":{"id":55,"type":"private"}}}}"#)
        guard case let .answer(inbound) = parsed.intent else {
            Issue.record("expected an answerable intent"); return
        }
        #expect(inbound.text == "norviq:confirm:x")
        #expect(inbound.callbackQueryID == "cb1")
    }

    @Test("An update with nothing actionable is ignored, not guessed at")
    func emptyUpdate() throws {
        let parsed = try update(from: #"{"update_id":10}"#)
        guard case .ignore = parsed.intent else {
            Issue.record("expected ignore"); return
        }
    }
}

@Suite("Messaging commands and answers")
struct MessagingCommandTests {
    @Test("Commands parse, including the @botname suffix Telegram adds in groups")
    func parsesCommands() {
        #expect(MessagingCommands.parse("/help")?.command == "/help")
        #expect(MessagingCommands.parse("/help@norviq_bot")?.command == "/help")
        #expect(MessagingCommands.parse("/start ABC12345")?.argument == "ABC12345")
        #expect(MessagingCommands.parse("hello") == nil)
    }

    @Test("A refusal is never read as approval")
    func refusalsBeatApprovals() {
        // "don't do that" contains "do". Word order must not decide consent.
        guard case .declineLatest = MessagingService.parseConfirmationAnswer("no, don't do that") else {
            Issue.record("expected a decline"); return
        }
        guard case .approveLatest = MessagingService.parseConfirmationAnswer("yes please") else {
            Issue.record("expected an approval"); return
        }
        #expect(MessagingService.parseConfirmationAnswer("what is my balance") == nil)
    }

    @Test("Button payloads resolve to a specific action id")
    func buttonPayloads() {
        let id = UUID()
        guard case let .approve(parsed) = MessagingService.parseConfirmationAnswer("norviq:confirm:\(id.uuidString)") else {
            Issue.record("expected an approval for a specific action"); return
        }
        #expect(parsed == id)
        guard case let .decline(declined) = MessagingService.parseConfirmationAnswer("norviq:decline:\(id.uuidString)") else {
            Issue.record("expected a decline for a specific action"); return
        }
        #expect(declined == id)
    }

    @Test("The published menu matches what is implemented")
    func publishedMenu() {
        let names = MessagingCommands.published().map(\.name)
        // /start is intentionally unpublished: Telegram shows a START button
        // anyway, and listing it invites re-running finished pairing.
        #expect(names == ["help", "unlink"])
    }
}

@Suite("Pairing code rules")
struct MessagingLinkCodeTests {
    @Test("Codes avoid characters people confuse when retyping")
    func alphabetIsUnambiguous() {
        let alphabet = String(MessagingLinkService.codeAlphabet)
        for confusable in ["0", "O", "1", "I", "L"] {
            #expect(!alphabet.contains(confusable), "\(confusable) is too easy to mistype")
        }
        #expect(MessagingLinkService.generateCode().count == MessagingLinkService.codeLength)
    }

    @Test("Whatever the user actually types normalises to the code")
    func normalisesInput() {
        #expect(MessagingLinkService.normalise("/start abc12345") == "ABC12345")
        #expect(MessagingLinkService.normalise("ABC1-2345") == "ABC12345")
        #expect(MessagingLinkService.normalise("  abc12345  ") == "ABC12345")
    }

    @Test("Only a positive Telegram chat id can be linked")
    func rejectsGroupIdentifiers() {
        // Telegram group and channel ids are negative. This is the backstop
        // behind the chat-type check on the update itself.
        #expect(MessagingLinkService.isLinkableExternalID("4242", platform: MessagingPlatform.telegram))
        #expect(!MessagingLinkService.isLinkableExternalID("-100200", platform: MessagingPlatform.telegram))
        #expect(!MessagingLinkService.isLinkableExternalID("not-a-number", platform: MessagingPlatform.telegram))
    }
}

@Suite("Telegram delivery preferences")
struct MessagingPreferenceTests {
    private func preference(start: Int?, end: Int?, timezone: String = "UTC") -> MessagingPreference {
        MessagingPreference(
            userId: UUID(), platform: MessagingPlatform.telegram, kind: "budget",
            enabled: true, quietHoursStart: start, quietHoursEnd: end, timezone: timezone
        )
    }

    private func date(hourUTC: Int) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 20; components.hour = hourUTC
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    @Test("A quiet window that wraps midnight silences both sides of it")
    func quietHoursWrapMidnight() {
        let overnight = preference(start: 22, end: 8)
        #expect(MessagingPreferenceService.isQuiet(overnight, at: date(hourUTC: 23)))
        #expect(MessagingPreferenceService.isQuiet(overnight, at: date(hourUTC: 3)))
        #expect(!MessagingPreferenceService.isQuiet(overnight, at: date(hourUTC: 12)))
    }

    @Test("A same-day quiet window silences only its own hours")
    func quietHoursSameDay() {
        let afternoon = preference(start: 13, end: 15)
        #expect(MessagingPreferenceService.isQuiet(afternoon, at: date(hourUTC: 14)))
        #expect(!MessagingPreferenceService.isQuiet(afternoon, at: date(hourUTC: 16)))
    }

    @Test("No window, or an unusable timezone, means never quiet")
    func quietHoursAbsent() {
        #expect(!MessagingPreferenceService.isQuiet(preference(start: nil, end: nil), at: date(hourUTC: 3)))
        // An unreadable identifier must not silently become UTC and then wake
        // someone at 3am.
        #expect(!MessagingPreferenceService.isQuiet(preference(start: 22, end: 8, timezone: "Mars/Olympus"), at: date(hourUTC: 3)))
    }

    @Test("Quiet hours need both bounds or neither")
    func rejectsHalfAWindow() {
        #expect(throws: (any Error).self) {
            try MessagingController.validateQuietHours(start: 22, end: nil)
        }
        #expect(throws: (any Error).self) {
            try MessagingController.validateQuietHours(start: 25, end: 30)
        }
        #expect(throws: Never.self) {
            try MessagingController.validateQuietHours(start: nil, end: nil)
        }
        #expect(throws: Never.self) {
            try MessagingController.validateQuietHours(start: 22, end: 8)
        }
    }
}
