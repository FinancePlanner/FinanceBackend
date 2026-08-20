import Foundation
import Vapor

/// Platform identifiers. Kept as strings rather than an enum because the value
/// is persisted in `messaging_links.platform` and read by the web app.
enum MessagingPlatform {
    static let telegram = "telegram"
}

/// One message arriving from any platform, already stripped of platform shape.
///
/// Button taps arrive here too, with the button's value in `text`, so command
/// handling and confirmation answers have exactly one code path.
struct InboundMessage: Sendable {
    let platform: String
    /// The chat this arrived from — `messaging_links.external_id`.
    let externalID: String
    /// Monotonic per-bot sequence number, used as the dedupe watermark.
    /// Zero means the platform does not supply one.
    let updateID: Int64
    let text: String
    /// Group and channel traffic is refused outright; a shared chat must never
    /// resolve to one person's financial data.
    let isPrivateChat: Bool
    /// Set when this message came from tapping an inline button.
    let callbackQueryID: String?
}

/// A reply on its way out.
struct OutboundMessage: Sendable {
    let text: String
    let options: [MessageOption]
    /// A redelivered update produces a silent outcome: the work was already
    /// done, so sending the answer twice would be worse than sending nothing.
    let silent: Bool

    init(text: String, options: [MessageOption] = [], silent: Bool = false) {
        self.text = text
        self.options = options
        self.silent = silent
    }

    static let ignored = OutboundMessage(text: "", silent: true)
}

/// A tappable choice rendered as an inline button where the platform has them.
struct MessageOption: Sendable {
    let label: String
    /// Echoed back verbatim as the inbound text when tapped.
    let value: String
}

/// The whole platform seam.
///
/// Telegram implements it. Discord and WhatsApp would be a new type each,
/// leaving everything above this protocol untouched.
protocol MessagingTransport: Sendable {
    var platform: String { get }
    func send(chatID: String, message: OutboundMessage, req: Request) async throws
    /// Best-effort "typing…" hint. Failures are logged, never propagated.
    func typing(chatID: String, req: Request) async
    /// Acknowledges a button tap so the client stops showing a spinner.
    func answerCallback(id: String, req: Request) async
    /// Leaves a chat the bot should not be in.
    func leave(chatID: String, req: Request) async
}
