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

        let parts = TelegramFormat.htmlChunks(message.text)
        var delivered = 0
        var lastFailure: (any Error)?

        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            // Buttons belong on the final chunk; on an earlier one they would
            // scroll away above the rest of the answer.
            let keyboard = isLast && !message.options.isEmpty
                ? inlineKeyboard(message.options)
                : nil
            do {
                try await sendChunk(chatID: chatID, part: part, keyboard: keyboard, req: req)
                delivered += 1
            } catch {
                // Keep going. A gap in the middle of an answer is bad; silently
                // dropping everything after the first bad chunk — which is what
                // aborting the loop did — reads to the user as a reply that
                // simply stops, indistinguishable from the model being cut off.
                lastFailure = error
                req.logger.error(
                    "telegram_send_chunk_failed chunk=\(index + 1)/\(parts.count) \(describe(error))"
                )
            }
        }

        guard delivered > 0 else {
            // Nothing arrived at all, so let the caller record a real failure
            // rather than reporting a success the user never saw.
            throw lastFailure ?? TelegramError.api("sendMessage delivered nothing")
        }
        // The keyboard rides on the last chunk, so losing that chunk would strip
        // the Confirm/Cancel buttons off a pending write action.
        if lastFailure != nil, !message.options.isEmpty, delivered < parts.count {
            try? await sendChunk(
                chatID: chatID,
                part: "Choose an option to continue.",
                keyboard: inlineKeyboard(message.options),
                req: req
            )
        }
    }

    /// One chunk, with the retries Telegram's own failures call for.
    private func sendChunk(chatID: String, part: String, keyboard: String?, req: Request) async throws {
        var body: [String: TelegramValue] = [
            "chat_id": .string(chatID),
            "text": .string(TelegramFormat.html(part)),
            "parse_mode": .string("HTML"),
        ]
        if let keyboard {
            body["reply_markup"] = .raw(keyboard)
        }

        for attempt in 0 ..< 3 {
            do {
                try await call("sendMessage", body: body, req: req)
                return
            } catch let error as TelegramError {
                switch error.retryStrategy {
                case let .waitAndRetry(seconds) where attempt < 2:
                    // Flood control. The turn already has its own ceiling, so a
                    // bounded wait here cannot wedge anything.
                    req.logger.warning("telegram_rate_limited retry_after=\(seconds)")
                    try await Task.sleep(for: .seconds(min(seconds, 30)))
                case .resendPlain where body["parse_mode"] != nil:
                    // Telegram rejects the whole message on one unsupported tag.
                    // Losing the formatting beats losing the answer.
                    req.logger.warning("telegram_refused_html \(describe(error)); resending plain")
                    body["parse_mode"] = nil
                    body["text"] = .string(TelegramFormat.plain(part))
                default:
                    throw error
                }
            }
        }
        throw TelegramError.api("sendMessage exhausted its retries")
    }

    /// Errors reach the user's chat by way of `MessagingService`, so the detail
    /// belongs in the log where it can be read without leaking to them.
    private func describe(_ error: any Error) -> String {
        guard let telegram = error as? TelegramError else { return "error=\(type(of: error))" }
        switch telegram {
        case let .api(failure):
            return "error_code=\(failure.errorCode.map(String.init) ?? "none") description=\(failure.description)"
        case let .http(status):
            return "http_status=\(status)"
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
        case api(APIFailure)
        case http(UInt)

        static func api(_ description: String) -> TelegramError {
            .api(APIFailure(description: description, errorCode: nil, retryAfter: nil))
        }

        /// What to do about it, rather than making each call site re-read the
        /// description. Telegram signals all three of these the same way.
        enum RetryStrategy: Equatable {
            case waitAndRetry(seconds: Int)
            case resendPlain
            case giveUp
        }

        var retryStrategy: RetryStrategy {
            guard case let .api(failure) = self else { return .giveUp }
            if failure.errorCode == 429 {
                return .waitAndRetry(seconds: failure.retryAfter ?? 1)
            }
            // 400 covers both a bad tag and an over-long message; the plain
            // resend is shorter as well as tag-free, so it addresses both.
            if failure.errorCode == 400 {
                return .resendPlain
            }
            return .giveUp
        }
    }

    struct APIFailure: Sendable {
        let description: String
        let errorCode: Int?
        let retryAfter: Int?
    }

    @discardableResult
    private func call(_ method: String, body: [String: TelegramValue], req: Request) async throws -> ByteBuffer {
        // A plain `JSONDecoder` on purpose. The global `JSONDecoder.backendAPI`
        // camel-cases snake_case keys before `CodingKeys` lookup, which would
        // silently nil out `error_code` and `retry_after` and leave the rate
        // limit path permanently blind.
        struct Envelope: Decodable {
            struct Parameters: Decodable {
                let retryAfter: Int?

                enum CodingKeys: String, CodingKey {
                    case retryAfter = "retry_after"
                }
            }

            let ok: Bool
            let description: String?
            let errorCode: Int?
            let parameters: Parameters?

            enum CodingKeys: String, CodingKey {
                case ok, description, parameters
                case errorCode = "error_code"
            }
        }
        let buffer = try await post(method: method, body: body, req: req)
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(buffer: buffer))
        guard envelope.ok else {
            throw TelegramError.api(APIFailure(
                description: envelope.description ?? "\(method) failed",
                errorCode: envelope.errorCode,
                retryAfter: envelope.parameters?.retryAfter
            ))
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
private func escapeScalar(_ scalar: Unicode.Scalar) -> String {
    switch scalar {
    case "\"": "\\\""
    case "\\": "\\\\"
    case "\n": "\\n"
    case "\r": "\\r"
    case "\t": "\\t"
    default: scalar.value < 0x20
        ? String(format: "\\u%04x", scalar.value)
        : String(scalar)
    }
}

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
            else {
                // A Swift String is always valid Unicode, so this is effectively
                // unreachable — but posting an empty message would be a silent
                // wrong answer, where an escaped literal is at least legible.
                return "\"" + value.unicodeScalars.map(escapeScalar).joined() + "\""
            }
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
