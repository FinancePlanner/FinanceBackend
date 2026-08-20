import Foundation

/// The slice of Telegram's update payload this bot acts on.
struct TelegramUpdate: Decodable {
    struct Chat: Decodable {
        let id: Int64
        let type: String
    }

    struct Message: Decodable {
        let messageId: Int64?
        let chat: Chat
        let text: String?

        enum CodingKeys: String, CodingKey {
            case messageId = "message_id"
            case chat, text
        }
    }

    struct CallbackQuery: Decodable {
        let id: String
        let data: String?
        let message: Message?
    }

    let updateId: Int64
    let message: Message?
    let callbackQuery: CallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

extension TelegramUpdate {
    /// What to do with this update.
    ///
    /// Anything unrecognised is ignored rather than guessed at — an update type
    /// we did not plan for should do nothing, not something arbitrary.
    enum Intent {
        case answer(InboundMessage)
        /// The bot was added somewhere it must not be.
        case leave(chatID: String)
        case ignore
    }

    var intent: Intent {
        guard let source = callbackQuery?.message ?? message else { return .ignore }
        let chatID = String(source.chat.id)

        switch source.chat.type {
        case "private":
            break
        case "group", "supergroup", "channel":
            return .leave(chatID: chatID)
        default:
            return .ignore
        }

        // A button tap carries its payload in `data`; typed text in `text`.
        // Normalising both into `text` here keeps one path downstream.
        let text = (callbackQuery?.data ?? source.text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return .ignore }

        return .answer(InboundMessage(
            platform: MessagingPlatform.telegram,
            externalID: chatID,
            updateID: updateId,
            text: text,
            isPrivateChat: true,
            callbackQueryID: callbackQuery?.id
        ))
    }
}
