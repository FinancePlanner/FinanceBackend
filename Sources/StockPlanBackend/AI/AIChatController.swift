import Foundation
import NIOCore
import Vapor

/// The in-app assistant chat endpoint. First-party sessions only (MCP tokens are
/// rejected), Pro-gated, and bounded by the same daily cap as insight cards.
/// Responds as Server-Sent Events: `tool` activity events followed by a final
/// `message` event, then `done`.
struct AIChatController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.post("ai", "chat", use: chat)
    }

    func chat(req: Request) async throws -> Response {
        // First-party only: an MCP scoped token must not reach the assistant.
        guard req.auth.get(ScopeContext.self) == nil else {
            throw Abort(.forbidden, reason: "The assistant is only available in the Norviq app.")
        }
        let session = try req.auth.require(SessionToken.self)
        try AICostControls.requireEnabled(reason: "The assistant is temporarily unavailable.")
        try await req.usageCounterService.requirePremium(.aiInsights, userId: session.userId, on: req.db)
        try await AIDailyCap.enforce(
            req,
            userId: session.userId,
            unavailableReason: "The assistant is temporarily unavailable.",
            limitReachedReason: "Daily assistant limit reached. Try again tomorrow."
        )

        let payload = try req.content.decode(AIChatRequest.self)
        // Strip the assistant's name off the user's own turns only. Assistant
        // turns are echoed back verbatim so the transcript stays faithful.
        let history = payload.messages.prefix(30).map { message in
            let role = message.sanitizedRole
            let content = role == "user" ? AssistantAddress.strip(message.content) : message.content
            return OpenAIMessage(role: role, content: content)
        }
        guard history.contains(where: { $0.role == "user" }) else {
            throw Abort(.badRequest, reason: "At least one user message is required.")
        }

        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "text/event-stream; charset=utf-8")
        res.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        res.headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        res.body = .init(managedAsyncStream: { writer in
            do {
                try await req.application.aiChatService.stream(
                    history: Array(history),
                    userId: session.userId,
                    onEvent: { event in
                        try? await Self.write(event, to: writer)
                    },
                    on: req
                )
            } catch {
                try? await Self.write(
                    .message("Sorry — I couldn't complete that just now. Please try again."),
                    to: writer
                )
                req.logger.error("ai_chat error userId=\(session.userId) error=\(String(reflecting: error).prefix(300))")
            }
            try await Self.writeFrame(event: "done", encodedData: "{}", to: writer)
        })
        return res
    }

    // MARK: - SSE encoding

    static func write(_ event: AIChatEvent, to writer: any AsyncBodyStreamWriter) async throws {
        switch event {
        case let .toolActivity(label):
            try await writeFrame(event: "tool", data: ["label": label], to: writer)
        case let .message(text):
            try await writeFrame(event: "message", data: ["content": text], to: writer)
        }
    }

    static func writeFrame(
        event: String,
        data: [String: String],
        to writer: any AsyncBodyStreamWriter
    ) async throws {
        let encoded = (try? JSONEncoder().encode(data)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try await writeFrame(event: event, encodedData: encoded, to: writer)
    }

    static func writeFrame(
        event: String,
        encodedData: String,
        to writer: any AsyncBodyStreamWriter
    ) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: event.utf8.count + encodedData.utf8.count + 16)
        buffer.writeString("event: \(event)\ndata: \(encodedData)\n\n")
        try await writer.writeBuffer(buffer)
    }
}

struct AIChatRequest: Content {
    let messages: [AIChatMessageInput]
}

struct AIChatMessageInput: Content {
    let role: String
    let content: String

    /// Only user/assistant roles are accepted from the client; anything else is
    /// treated as a user turn so a client cannot inject a system prompt.
    var sanitizedRole: String {
        role == "assistant" ? "assistant" : "user"
    }
}
