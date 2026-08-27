import Foundation
import NIOCore
@testable import StockPlanBackend
import Testing
import Vapor

/// A realistic OpenRouter/OpenAI chat completion: a tool call, a finish reason
/// and a usage block. Everything that matters here is snake_case on the wire,
/// which is exactly what the global decoder used to eat.
private let toolCallBody = #"""
{
  "id": "gen-abc123",
  "provider": "DigitalOcean",
  "model": "deepseek/deepseek-v4-flash",
  "choices": [
    {
      "finish_reason": "tool_calls",
      "message": {
        "role": "assistant",
        "content": "Let me check your expenses",
        "tool_calls": [
          {
            "id": "call_1",
            "type": "function",
            "function": { "name": "list_expenses", "arguments": "{\"month\":\"2026-08\"}" }
          }
        ]
      }
    }
  ],
  "usage": {
    "prompt_tokens": 1284,
    "completion_tokens": 96,
    "total_tokens": 1380,
    "completion_tokens_details": { "reasoning_tokens": 32 }
  }
}
"""#

private let truncatedBody = #"""
{
  "model": "deepseek/deepseek-v4-flash",
  "choices": [
    {
      "finish_reason": "length",
      "message": { "role": "assistant", "content": "Your biggest category this month was" }
    }
  ],
  "usage": { "prompt_tokens": 900, "completion_tokens": 2000, "total_tokens": 2900 }
}
"""#

/// Wraps a JSON string the way `req.client.post` hands it back, so the tests
/// exercise the decode the client actually performs rather than a bare
/// `JSONDecoder` that proves nothing about production.
private func providerResponse(_ json: String) -> ClientResponse {
    var buffer = ByteBufferAllocator().buffer(capacity: json.utf8.count)
    buffer.writeString(json)
    var headers = HTTPHeaders()
    headers.contentType = .json
    return ClientResponse(status: .ok, headers: headers, body: buffer)
}

/// Runs `body` with the decoder production actually boots with.
///
/// This is the whole point of the suite. `configure.swift` installs
/// `JSONDecoder.backendAPI` globally, but tests never call `configure`, so a
/// test that skips this helper decodes with Vapor's stock decoder — and passes
/// happily against the exact bug this file exists to catch. Serialized because
/// `ContentConfiguration.global` is process-wide shared state.
private func withProductionContentConfiguration<T>(_ body: () throws -> T) rethrows -> T {
    let original = ContentConfiguration.global
    defer { ContentConfiguration.global = original }
    ContentConfiguration.global.use(decoder: JSONDecoder.backendAPI, for: .json)
    return try body()
}

@Suite("OpenAI wire decoding", .serialized)
struct OpenAIWireDecodingTests {
    @Test("Tool calls, finish reason and usage survive the decode")
    func decodesSnakeCaseFields() throws {
        let decoded = try withProductionContentConfiguration {
            try DefaultOpenAIChatClient.decodeChatResponse(providerResponse(toolCallBody))
        }
        let choice = try #require(decoded.choices.first)

        // Without this the tool call is dropped, the tool loop exits at round
        // one, and the user is left with the lead-in sentence on its own.
        let toolCalls = try #require(choice.message.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.function.name == "list_expenses")

        #expect(choice.finishReason == "tool_calls")
        #expect(decoded.usage?.promptTokens == 1284)
        #expect(decoded.usage?.completionTokens == 96)
        #expect(decoded.usage?.totalTokens == 1380)
        #expect(decoded.usage?.completionTokensDetails?.reasoningTokens == 32)

        // Keys without an underscore were never affected. Asserted so that a
        // future failure points at the key strategy, not at the payload.
        #expect(decoded.provider == "DigitalOcean")
        #expect(decoded.model == "deepseek/deepseek-v4-flash")
    }

    @Test("A length-capped completion is recognisable as truncated")
    func decodesLengthFinishReason() throws {
        let decoded = try withProductionContentConfiguration {
            try DefaultOpenAIChatClient.decodeChatResponse(providerResponse(truncatedBody))
        }
        #expect(decoded.choices.first?.finishReason == "length")
    }

    /// The request side is believed safe because `JSONEncoder.backendAPI` uses
    /// `.useDefaultKeys`. Asserted rather than believed.
    @Test("The request body keeps the provider's field names")
    func encodesSnakeCaseFields() throws {
        let message = OpenAIMessage(
            role: "tool",
            content: "{}",
            toolCallId: "call_1"
        )
        let json = try String(decoding: JSONEncoder.backendAPI.encode(message), as: UTF8.self)
        #expect(json.contains("\"tool_call_id\""))
        #expect(!json.contains("\"toolCallId\""))
    }

    /// Pins the trap itself, so the bypass in `decodeChatResponse` is not
    /// "tidied away" later: the global decoder camel-cases snake_case keys
    /// before `CodingKeys` lookup, which is why third-party payloads must not
    /// go through it.
    @Test("The global backendAPI decoder still drops these fields")
    func globalDecoderDropsSnakeCaseFields() throws {
        let decoded = try JSONDecoder.backendAPI.decode(
            OpenAIChatResponseBody.self,
            from: Data(toolCallBody.utf8)
        )
        #expect(decoded.choices.first?.message.toolCalls == nil)
        #expect(decoded.choices.first?.finishReason == nil)
        #expect(decoded.usage?.promptTokens == nil)
    }
}
