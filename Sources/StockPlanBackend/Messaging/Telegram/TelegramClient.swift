import Foundation
import Vapor

/// Telegram Bot API over plain HTTP.
///
/// Hand-rolled rather than pulled from a package: the bot uses five methods,
/// and a dependency would cost more in supply chain and upgrade friction than
/// the ~150 lines it saves.
struct TelegramClient: MessagingTransport {
    let platform = MessagingPlatform.telegram

    let token: String
    /// A property rather than a constant so tests can point it at a local
    /// stand-in for `api.telegram.org`.
    var baseURL: String = "https://api.telegram.org"

    /// Long-poll window. The HTTP timeout must comfortably exceed this or every
    /// quiet minute would read as a network failure.
    static let pollTimeoutSeconds = 30

    // MARK: - MessagingTransport

    func send(chatID: String, message: OutboundMessage, req: Request) async throws {
        // A redelivery already produced this answer once.
        guard !message.silent else { return }

        let parts = TelegramFormat.split(message.text)
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            var body: [String: TelegramValue] = [
                "chat_id": .string(chatID),
                "text": .string(TelegramFormat.html(part)),
                "parse_mode": .string("HTML"),
            ]
            // Buttons belong on the final chunk; on an earlier one they would
            // scroll away above the rest of the answer.
            if isLast, !message.options.isEmpty {
                body["reply_markup"] = .raw(inlineKeyboard(message.options))
            }
            do {
                try await call("sendMessage", body: body, req: req)
            } catch {
                // Telegram rejects the whole message on one unsupported tag.
                // Losing the formatting beats losing the answer.
                req.logger.warning("telegram refused formatted text; resending it plain")
                body["parse_mode"] = nil
                body["text"] = .string(TelegramFormat.plain(part))
                try await call("sendMessage", body: body, req: req)
            }
        }
    }

    func typing(chatID: String, req: Request) async {
        try? await call("sendChatAction", body: [
            "chat_id": .string(chatID),
            "action": .string("typing"),
        ], req: req)
    }

    func answerCallback(id: String, req: Request) async {
        try? await call("answerCallbackQuery", body: ["callback_query_id": .string(id)], req: req)
    }

    func leave(chatID: String, req: Request) async {
        try? await call("leaveChat", body: ["chat_id": .string(chatID)], req: req)
    }

    // MARK: - Setup

    /// Publishes the command menu. Best-effort: a failure here costs a nicety,
    /// not the bot.
    func registerCommands(req: Request) async {
        let commands = MessagingCommands.published()
            .map { ["command": $0.name, "description": $0.description] }
        guard let encoded = try? JSONEncoder().encode(commands) else { return }
        try? await call("setMyCommands", body: [
            "commands": .raw(String(decoding: encoded, as: UTF8.self)),
        ], req: req)
    }

    /// Fetches pending updates. Long-polling, used in local development where
    /// there is no public URL for Telegram to call back to.
    func getUpdates(offset: Int64, req: Request) async throws -> [TelegramUpdate] {
        struct Envelope: Decodable {
            let ok: Bool
            let result: [TelegramUpdate]?
            let description: String?
        }
        let body: [String: TelegramValue] = [
            "offset": .raw(String(offset)),
            "timeout": .raw(String(Self.pollTimeoutSeconds)),
            "allowed_updates": .raw("[\"message\",\"callback_query\"]"),
        ]
        let response = try await post(method: "getUpdates", body: body, req: req)
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(buffer: response))
        guard envelope.ok else {
            throw TelegramError.api(envelope.description ?? "getUpdates failed")
        }
        return envelope.result ?? []
    }

    // MARK: - Transport

    enum TelegramError: Error {
        /// Never carries the URL: the bot token lives in the path, and an error
        /// string ends up in logs.
        case api(String)
        case http(UInt)
    }

    @discardableResult
    private func call(_ method: String, body: [String: TelegramValue], req: Request) async throws -> ByteBuffer {
        struct Envelope: Decodable {
            let ok: Bool
            let description: String?
        }
        let buffer = try await post(method: method, body: body, req: req)
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(buffer: buffer))
        guard envelope.ok else {
            throw TelegramError.api(envelope.description ?? "\(method) failed")
        }
        return buffer
    }

    private func post(method: String, body: [String: TelegramValue], req: Request) async throws -> ByteBuffer {
        let uri = URI(string: "\(baseURL)/bot\(token)/\(method)")
        let payload = TelegramValue.object(body).json
        let response = try await req.client.post(uri) { clientRequest in
            clientRequest.headers.contentType = .json
            clientRequest.body = ByteBuffer(string: payload)
        }
        guard let buffer = response.body else {
            throw TelegramError.http(response.status.code)
        }
        return buffer
    }

    private func inlineKeyboard(_ options: [MessageOption]) -> String {
        let buttons = options.map { option in
            TelegramValue.object([
                "text": .string(option.label),
                "callback_data": .string(option.value),
            ])
        }
        // One button per row: labels are short but a phone is narrow, and a
        // wrapped label reads as two buttons.
        let rows = buttons.map { TelegramValue.array([$0]) }
        return TelegramValue.object(["inline_keyboard": .array(rows)]).json
    }
}

/// Minimal JSON writer.
///
/// The Bot API takes heterogeneous objects that `Codable` models awkwardly, and
/// `[String: Any]` is not `Sendable`.
enum TelegramValue {
    case string(String)
    /// Pre-encoded JSON, inserted verbatim.
    case raw(String)
    case object([String: TelegramValue])
    case array([TelegramValue])

    var json: String {
        switch self {
        case let .string(value):
            // Hand-rolling this would miss the C0 control characters, which a
            // model's output can contain and which make the whole request
            // invalid JSON. Foundation already knows the rules.
            guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
                  let array = String(data: data, encoding: .utf8),
                  array.count >= 2
            else { return "\"\"" }
            return String(array.dropFirst().dropLast())
        case let .raw(value):
            return value
        case let .object(fields):
            let body = fields
                .sorted { $0.key < $1.key }
                .map { "\(TelegramValue.string($0.key).json):\($0.value.json)" }
                .joined(separator: ",")
            return "{\(body)}"
        case let .array(items):
            return "[\(items.map(\.json).joined(separator: ","))]"
        }
    }
}
