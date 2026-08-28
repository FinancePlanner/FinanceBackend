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

/// Telegram enforces its 4096 limit on the *rendered* payload, counted in UTF-16
/// code units. Chunking the raw markdown in `Character`s satisfies neither, and
/// the gap is not small: escaping turns one `&` into five characters, so a chunk
/// can arrive several times over the limit and be rejected outright.
@Suite("Telegram chunk sizing")
struct TelegramChunkSizingTests {
    private func rendered(_ markdown: String) -> [String] {
        TelegramFormat.htmlChunks(markdown).map { TelegramFormat.html($0) }
    }

    @Test("Ampersands still fit once escaped")
    func ampersandsFitAfterEscaping() {
        let storm = String(repeating: "a & b ", count: 2000)
        for part in rendered(storm) {
            #expect(part.utf16.count <= TelegramFormat.maxMessageCharacters)
        }
    }

    @Test("Angle brackets still fit once escaped")
    func angleBracketsFitAfterEscaping() {
        let storm = String(repeating: "<tag> ", count: 2000)
        for part in rendered(storm) {
            #expect(part.utf16.count <= TelegramFormat.maxMessageCharacters)
        }
    }

    @Test("Emoji are measured in UTF-16, the unit Telegram counts")
    func emojiMeasuredInUTF16() {
        // Two UTF-16 code units each but a single Character, so a Character
        // count is off by half.
        let emoji = String(repeating: "👍", count: 4000)
        for part in TelegramFormat.htmlChunks(emoji) {
            #expect(part.utf16.count <= TelegramFormat.maxMessageCharacters)
        }
    }

    @Test("The plain fallback fits wherever the HTML one did")
    func plainFallbackAlsoFits() {
        let markdown = String(repeating: "**bold** and [a link](https://example.com/x) ", count: 300)
        for part in TelegramFormat.htmlChunks(markdown) {
            #expect(TelegramFormat.html(part).utf16.count <= TelegramFormat.maxMessageCharacters)
            #expect(TelegramFormat.plain(part).utf16.count <= TelegramFormat.maxMessageCharacters)
        }
    }

    @Test("Chunking loses no words")
    func losesNoContent() {
        let paragraph = String(repeating: "Spending is up & down. ", count: 500)
        let stripped = { (text: String) in text.replacingOccurrences(of: " ", with: "") }
        #expect(stripped(TelegramFormat.htmlChunks(paragraph).joined()) == stripped(paragraph))
    }

    @Test("Short text is still a single message")
    func shortTextStaysWhole() {
        #expect(TelegramFormat.htmlChunks("hello & goodbye") == ["hello & goodbye"])
        #expect(TelegramFormat.htmlChunks("").isEmpty)
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
        #expect(names == [
            "finance", "portfolio", "budget", "expenses", "news",
            "clear", "help", "unlink",
        ])
        #expect(!names.contains("start"))
    }

    /// The command list is written down three times — the constants, the menu,
    /// and the help text — and only the first two are checked against each other
    /// by `publishedMenu`. This closes the triangle.
    @Test("Every published command is named in the help text")
    func helpTextCoversPublishedMenu() {
        for name in MessagingCommands.published().map(\.name) {
            #expect(
                MessagingCommands.helpText.contains("/\(name)"),
                "/\(name) is published but missing from helpText"
            )
        }
    }

    @Test("Help text tells people how to address Q directly")
    func helpTextMentionsAddressing() {
        // @Q already works via AssistantAddress; the only gap was that nothing
        // said so.
        #expect(MessagingCommands.helpText.contains("@Q"))
    }

    @Test("The command limiter fails closed in production and open in development")
    func commandAllowanceBranches() throws {
        // Within the allowance, and one past it.
        #expect(try MessagingService.commandAllowance(count: 20, limit: 20, isProduction: true))
        #expect(try !MessagingService.commandAllowance(count: 21, limit: 20, isProduction: true))

        // No counter to ask. Production must refuse rather than run unmetered;
        // a developer without a Redis must still be able to try the bot.
        #expect(throws: (any Error).self) {
            try MessagingService.commandAllowance(count: nil, limit: 20, isProduction: true)
        }
        #expect(try MessagingService.commandAllowance(count: nil, limit: 20, isProduction: false))
    }

    @Test("Data commands are parsed bare and with a trailing question")
    func dataCommandParsing() {
        #expect(MessagingCommands.parse("/budget")?.argument == "")
        #expect(MessagingCommands.parse("/budget how do I cut it?")?.argument == "how do I cut it?")
        #expect(MessagingCommands.parse("/portfolio@Norviq_bot")?.command == "/portfolio")
        #expect(MessagingCommands.parse("/EXPENSES")?.command == "/expenses")
        #expect(MessagingCommands.dataCommands.contains("/news"))
        #expect(!MessagingCommands.dataCommands.contains("/help"))
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

/// Pure logic — no database, no network.
@Suite("Addressing the assistant by name")
struct AssistantAddressTests {
    @Test("The assistant's name is stripped off the front of a question")
    func stripsTheName() {
        #expect(AssistantAddress.strip("Hey Q, what did I spend last month?") == "what did I spend last month?")
        #expect(AssistantAddress.strip("@Q summarise my month") == "summarise my month")
        #expect(AssistantAddress.strip("Q: how is my portfolio doing") == "how is my portfolio doing")
        #expect(AssistantAddress.strip("q - log a coffee") == "log a coffee")
        #expect(AssistantAddress.strip("  hi Q!  budget please ") == "budget please ")
    }

    @Test("A ticker or quarter beginning with Q survives untouched")
    func leavesTickersAlone() {
        // The word-boundary rule: a letter or digit straight after the Q means
        // it was never the assistant's name.
        for text in ["Q3 earnings for AAPL", "QQQ price?", "Quick question about my budget",
                     "Qualcomm outlook", "QS is down again"]
        {
            #expect(AssistantAddress.strip(text) == text)
        }
    }

    @Test("A Telegram pairing code starting with Q is never mangled")
    func leavesPairingCodesAlone() {
        // MessagingLinkService.codeAlphabet contains Q, so roughly one code in
        // thirty-one starts with it. Stripping one character would fail the
        // length check and strand the user on "code is not valid or expired".
        #expect(MessagingLinkService.codeAlphabet.contains("Q"))
        #expect(AssistantAddress.strip("Q7KMPX3R") == "Q7KMPX3R")
    }

    @Test("The name alone is left whole rather than reduced to nothing")
    func keepsBareGreetings() {
        #expect(AssistantAddress.strip("Q") == "Q")
        #expect(AssistantAddress.strip("Hey Q") == "Hey Q")
        #expect(AssistantAddress.strip("Q???") == "Q???")
    }

    @Test("Addressing Q is not mistaken for consent")
    func addressIsNotConsent() {
        // "ok" and "okay" open a sentence to Q and are also approvalWords, so
        // the address has to come off before the confirmation parser sees the
        // text. Otherwise "Ok Q, what did I spend?" approves a pending action.
        for text in ["Ok Q, what did I spend?", "Okay Q, show me my budget"] {
            #expect(MessagingService.parseConfirmationAnswer(AssistantAddress.strip(text)) == nil)
        }
        // And the raw form is exactly what would have gone wrong.
        guard case .approveLatest = MessagingService.parseConfirmationAnswer("Ok Q, what did I spend?") else {
            Issue.record("expected the unstripped form to look like consent"); return
        }
    }

    @Test("A real answer still reads as consent once the address is stripped")
    func addressedConsentStillCounts() {
        guard case .approveLatest = MessagingService.parseConfirmationAnswer(AssistantAddress.strip("Hey Q, yes")) else {
            Issue.record("expected an approval"); return
        }
        guard case .declineLatest = MessagingService.parseConfirmationAnswer(AssistantAddress.strip("@Q no")) else {
            Issue.record("expected a decline"); return
        }
    }

    @Test("Callback payloads survive the stripper untouched")
    func callbackPayloadsSurvive() {
        // TelegramUpdate folds callbackQuery.data into the same text field.
        let id = UUID()
        for payload in ["norviq:confirm:\(id.uuidString)", "norviq:decline:\(id.uuidString)"] {
            #expect(AssistantAddress.strip(payload) == payload)
        }
    }

    @Test("A greeting on its own is not treated as an address")
    func leavesPlainGreetingsAlone() {
        #expect(AssistantAddress.strip("hey there") == "hey there")
        #expect(AssistantAddress.strip("ok sounds good") == "ok sounds good")
        #expect(AssistantAddress.strip("what did I spend?") == "what did I spend?")
    }
}
