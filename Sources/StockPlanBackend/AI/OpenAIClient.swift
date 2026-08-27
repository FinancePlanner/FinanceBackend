import Foundation
import NIOCore
import Vapor

// MARK: - Wire models (OpenAI Chat Completions API)

struct OpenAIMessage: Content {
    var role: String // "system" | "user" | "assistant" | "tool"
    var content: String?
    var toolCalls: [OpenAIToolCall]?
    var toolCallId: String?
    var name: String?
    /// OpenRouter returns these opaque blocks for reasoning models. They must be
    /// sent back unchanged on the next tool round so the provider can continue
    /// the same chain of reasoning.
    var reasoningDetails: [OpenAIJSONValue]?
    var reasoning: String?

    init(
        role: String,
        content: String? = nil,
        toolCalls: [OpenAIToolCall]? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        reasoningDetails: [OpenAIJSONValue]? = nil,
        reasoning: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
        self.reasoningDetails = reasoningDetails
        self.reasoning = reasoning
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name, reasoning
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case reasoningDetails = "reasoning_details"
    }
}

/// Recursive JSON value used to round-trip provider-owned metadata without
/// interpreting or accidentally dropping fields added by OpenRouter.
enum OpenAIJSONValue: Codable, Sendable, Equatable {
    case object([String: OpenAIJSONValue])
    case array([OpenAIJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: OpenAIJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([OpenAIJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct OpenAIToolCall: Content {
    var id: String
    var type: String
    var function: OpenAIFunctionCall
}

struct OpenAIFunctionCall: Content {
    var name: String
    /// JSON-encoded argument string. Our tools take no arguments, so this is "{}".
    var arguments: String
}

struct OpenAITool: Content {
    var type: String = "function"
    var function: OpenAIFunctionDef
}

struct OpenAIFunctionDef: Content {
    var name: String
    var description: String
    var parameters: OpenAIJSONSchema
}

/// A single tool parameter (JSON Schema property). The userId is never a
/// parameter — it is bound server-side, so no tool can request another user's data.
struct OpenAIParameter: Content {
    var type: String
    var description: String?
    var enumValues: [String]?

    init(type: String, description: String? = nil, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }

    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }
}

/// Tool parameter schema. Read-only insight tools pass no properties (encodes to
/// `{"type":"object","properties":{},"required":[]}`); chat write-tools declare
/// typed properties here.
struct OpenAIJSONSchema: Content {
    var type: String = "object"
    var properties: [String: OpenAIParameter] = [:]
    var required: [String] = []

    init(properties: [String: OpenAIParameter] = [:], required: [String] = []) {
        self.properties = properties
        self.required = required
    }
}

struct OpenAIResponseFormat: Content {
    var type: String // "json_object" | "text"
}

private struct OpenAIChatRequestBody: Content {
    var model: String
    var messages: [OpenAIMessage]
    var tools: [OpenAITool]?
    var toolChoice: String?
    var temperature: Double?
    var maxTokens: Int?
    var responseFormat: OpenAIResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, temperature
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

struct OpenAIChatResponseBody: Content {
    var choices: [OpenAIChoice]
    var model: String?
    var provider: String?
    var usage: OpenAIUsage?
}

struct OpenAIUsage: Content {
    struct CompletionDetails: Content {
        var reasoningTokens: Int?

        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var completionTokensDetails: CompletionDetails?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case completionTokensDetails = "completion_tokens_details"
    }
}

struct OpenAIChoice: Content {
    var message: OpenAIMessage
    var finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

// MARK: - Client

/// One stateless chat completion. The tool-calling loop lives in the service,
/// which keeps this injectable + mockable in tests (no network).
protocol OpenAIChatClient: Sendable {
    func chat(
        messages: [OpenAIMessage],
        tools: [OpenAITool],
        responseFormat: String?,
        on req: Request
    ) async throws -> OpenAIMessage
}

extension OpenAIMessage {
    /// No text and no tool call — nothing a caller can show or act on.
    ///
    /// A provider returning this answers 200, so it is not an error any
    /// `catch` would see; the chain has to inspect the payload to notice.
    /// Blank content *with* a tool call is normal and is not this.
    var hasNoUsableOutput: Bool {
        content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && toolCalls?.isEmpty != false
    }
}

/// A 200 from the chat provider whose payload is unusable: no content and no
/// tool call.
///
/// Not an upstream *status* failure, so it is separate from
/// `OpenAIChatUpstreamError`. Carries the same `.badGateway` surface, so if it
/// escapes a single-rung deployment the caller sees what it always saw.
struct OpenAIChatUnusableResponseError: Error, AbortError {
    let model: String
    var status: HTTPResponseStatus {
        .badGateway
    }

    var reason: String {
        "AI service is unavailable. Please try again later."
    }
}

/// A non-200 from the chat provider, carrying the status so callers can tell an
/// auth failure apart from an outage.
///
/// Conforms to `AbortError` with the same `.badGateway` and message this used to
/// throw directly, so every existing caller behaves exactly as before. Only code
/// that explicitly inspects `status` sees anything new.
struct OpenAIChatUpstreamError: AbortError {
    /// The status the provider actually returned.
    let upstreamStatus: UInt

    var reason: String {
        "AI service is unavailable. Please try again later."
    }

    var status: HTTPResponseStatus {
        .badGateway
    }

    var isAuthFailure: Bool {
        upstreamStatus == 401 || upstreamStatus == 403
    }

    var isRateLimit: Bool {
        upstreamStatus == 429
    }

    /// The account reached zero balance. OpenRouter returns 402 for this, and it
    /// is the case the fallback chain exists for, so it gets its own name.
    var isOutOfCredits: Bool {
        upstreamStatus == 402
    }
}

struct DefaultOpenAIChatClient: OpenAIChatClient {
    let apiKey: String
    let model: String
    let baseURL: String
    let maxTokens: Int
    /// Without this a hung provider blocks the request forever, which also means
    /// a fallback chain in front of it never gets to demote.
    let timeout: TimeAmount

    init(apiKey: String, model: String, baseURL: String, maxTokens: Int, timeout: TimeAmount = .seconds(60)) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.timeout = timeout
    }

    /// Decodes a provider chat completion.
    ///
    /// Deliberately not `response.content.decode`: that routes through
    /// `ContentConfiguration.global`, whose `JSONDecoder.backendAPI` key strategy
    /// camel-cases every snake_case key *before* `CodingKeys` lookup. Our wire
    /// structs map those keys explicitly, so `tool_calls`, `finish_reason` and
    /// the whole `usage` block silently decoded as nil — the assistant's tool
    /// calls were dropped and truncation was undetectable. Same trap, and the
    /// same fix, as `oauthDecodeProviderJSON` in `OAuthProviderClient`.
    static func decodeChatResponse(
        _ response: ClientResponse,
        logger: Logger? = nil
    ) throws -> OpenAIChatResponseBody {
        try decodeProviderJSON(OpenAIChatResponseBody.self, from: response, logger: logger)
    }

    /// Shared by every AI-provider payload we decode. See the note above for why
    /// this exists rather than `response.content.decode`.
    static func decodeProviderJSON<T: Decodable>(
        _ type: T.Type,
        from response: ClientResponse,
        logger: Logger? = nil
    ) throws -> T {
        guard
            let buffer = response.body,
            let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
        else {
            throw Abort(.badGateway, reason: "AI service returned no result.")
        }
        do {
            return try JSONDecoder.externalProvider.decode(type, from: data)
        } catch {
            // `MessagingService` sends `abort.reason` straight to the Telegram
            // user, so the decoding detail belongs in the log, never the sentence.
            logger?.error("ai_provider_undecodable type=\(type) error=\(error)")
            throw Abort(.badGateway, reason: "AI service returned an unreadable response.")
        }
    }

    /// How many follow-up requests a truncated answer is worth.
    ///
    /// Each one is a full completion, billed and timed like any other, so this
    /// stays small: two rounds triple the worst-case cost of a turn already.
    static let maxContinuations = 2

    /// Whether a length-truncated completion can be safely resumed.
    ///
    /// Three cases where continuing makes things worse rather than better:
    /// a truncated tool call carries half-written JSON arguments, so resuming
    /// would act on a malformed call; two JSON-mode completions concatenated are
    /// not valid JSON; and with no content at all there is nothing to continue
    /// from — the budget went entirely to reasoning tokens, and asking again
    /// would just burn it the same way.
    static func canResume(
        finishReason: String?,
        message: OpenAIMessage,
        responseFormat: String?
    ) -> Bool {
        guard finishReason == "length", responseFormat == nil else { return false }
        guard message.toolCalls?.isEmpty != false else { return false }
        guard let content = message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    /// Asks for the rest of an answer the token cap cut short.
    ///
    /// Phrased as a plain user turn rather than assistant-prefill: prefill is the
    /// better technique but support for it varies by provider and route, and a
    /// silently-ignored prefill would duplicate the whole answer.
    private static let resumePrompt = """
    Continue your previous answer from exactly where it stopped. \
    Do not repeat any of it, and do not start over.
    """

    func chat(
        messages: [OpenAIMessage],
        tools: [OpenAITool],
        responseFormat: String?,
        on req: Request
    ) async throws -> OpenAIMessage {
        var result = try await completion(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            on: req
        )
        // A completion stopped by the token cap comes back as an ordinary
        // success carrying half an answer. Ask for the rest rather than handing
        // the user a sentence that breaks off mid-word.
        var transcript = messages
        var rounds = 0
        while rounds < Self.maxContinuations,
              Self.canResume(
                  finishReason: result.finishReason,
                  message: result.message,
                  responseFormat: responseFormat
              )
        {
            rounds += 1
            req.logger.warning(
                "ai_completion_truncated round=\(rounds) model=\(model) content_chars=\(result.message.content?.count ?? 0)"
            )
            transcript.append(result.message)
            transcript.append(OpenAIMessage(role: "user", content: Self.resumePrompt))
            let next = try await completion(
                messages: transcript,
                tools: tools,
                responseFormat: responseFormat,
                on: req
            )
            guard let addition = next.message.content, !addition.isEmpty else { break }
            result = Completion(
                message: OpenAIMessage(
                    role: result.message.role,
                    content: (result.message.content ?? "") + addition,
                    toolCalls: next.message.toolCalls,
                    reasoningDetails: next.message.reasoningDetails,
                    reasoning: next.message.reasoning
                ),
                finishReason: next.finishReason
            )
        }
        return result.message
    }

    struct Completion {
        let message: OpenAIMessage
        let finishReason: String?
    }

    /// One round trip to the provider.
    private func completion(
        messages: [OpenAIMessage],
        tools: [OpenAITool],
        responseFormat: String?,
        on req: Request
    ) async throws -> Completion {
        let body = OpenAIChatRequestBody(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: tools.isEmpty ? nil : "auto",
            temperature: 0.3,
            maxTokens: maxTokens,
            responseFormat: responseFormat.map { OpenAIResponseFormat(type: $0) }
        )

        let uri = URI(string: "\(baseURL)/chat/completions")
        let response = try await req.client.post(uri) { clientReq in
            clientReq.headers.contentType = .json
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            clientReq.timeout = timeout
            try clientReq.content.encode(body)
        }

        guard response.status == .ok else {
            let bodyText = response.body.map { String(buffer: $0) } ?? ""
            // Redacted when the provider echoes the key back in its error body,
            // which matters now that the key can be a user's own.
            let safeBody = bodyText.contains(apiKey) ? "<redacted: contained the key>" : String(bodyText.prefix(500))
            req.logger.error("openai_error status=\(response.status.code) body=\(safeBody)")
            throw OpenAIChatUpstreamError(upstreamStatus: response.status.code)
        }

        let decoded = try Self.decodeChatResponse(response, logger: req.logger)
        guard let choice = decoded.choices.first else {
            req.logger.warning("ai_completion_empty_choices provider=\(decoded.provider ?? "unknown") model=\(decoded.model ?? model)")
            throw Abort(.badGateway, reason: "AI service returned no result.")
        }
        let usage = decoded.usage
        let providerName = decoded.provider ?? "unknown"
        let responseModel = decoded.model ?? model
        let finishReason = choice.finishReason ?? "unknown"
        let promptTokens = usage?.promptTokens ?? -1
        let completionTokens = usage?.completionTokens ?? -1
        let totalTokens = usage?.totalTokens ?? -1
        let reasoningTokens = usage?.completionTokensDetails?.reasoningTokens ?? -1
        let contentCharacters = choice.message.content?.count ?? 0
        let toolCallCount = choice.message.toolCalls?.count ?? 0
        req.logger.info("ai_completion", metadata: [
            "provider": "\(providerName)",
            "model": "\(responseModel)",
            "finish_reason": "\(finishReason)",
            "prompt_tokens": "\(promptTokens)",
            "completion_tokens": "\(completionTokens)",
            "total_tokens": "\(totalTokens)",
            "reasoning_tokens": "\(reasoningTokens)",
            "content_chars": "\(contentCharacters)",
            "tool_calls": "\(toolCallCount)",
        ])
        if choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           choice.message.toolCalls?.isEmpty != false
        {
            req.logger.warning(
                "ai_completion_empty finish_reason=\(finishReason) model=\(responseModel)"
            )
        }
        return Completion(message: choice.message, finishReason: choice.finishReason)
    }
}

/// Builds the OpenAI-compatible chat client from provider-neutral config.
///
/// The result is an ordered chain: the configured primary first, then whatever
/// `AI_FALLBACK_PROVIDERS` resolves to. With no primary configured the chain is
/// fallbacks-only, which is what keeps a fresh dev box and staging answering
/// instead of booting into `DisabledOpenAIChatClient`.
func makeOpenAIChatClient(_ app: Application) -> any OpenAIChatClient {
    let configuration = AIProviderConfiguration.load()
    var tiers: [AIProviderTier] = []

    if configuration.isConfigured {
        app.logger.notice("ai_provider configured provider=\(configuration.provider.rawValue) model=\(configuration.defaultModel)")
        tiers.append(AIProviderTier(
            label: "primary-\(configuration.provider.rawValue)",
            apiKey: configuration.apiKey,
            baseURL: configuration.baseURL,
            model: configuration.defaultModel,
            maxTokens: configuration.maxTokens,
            supportsResponseFormat: AIModelCapabilities.supportsResponseFormat(configuration.defaultModel)
        ))
    } else {
        app.logger.warning("AI primary provider key is not configured; falling back to the free chain if one is available.")
    }

    tiers.append(contentsOf: configuration.fallbacks)

    guard let client = makeFallbackChatClient(
        tiers: tiers,
        timeout: configuration.requestTimeout,
        logger: app.logger
    ) else {
        app.logger.warning("AI provider key is not configured; AI insights are disabled.")
        return DisabledOpenAIChatClient()
    }
    return client
}

/// Used when no OPENAI_API_KEY is configured. Keeps the app bootable; the feature
/// simply reports itself unavailable instead of crashing at startup.
struct DisabledOpenAIChatClient: OpenAIChatClient {
    func chat(
        messages _: [OpenAIMessage],
        tools _: [OpenAITool],
        responseFormat _: String?,
        on _: Request
    ) async throws -> OpenAIMessage {
        throw Abort(.serviceUnavailable, reason: "AI insights are not enabled on this server.")
    }
}
