import Foundation
import NIOConcurrencyHelpers
@testable import StockPlanBackend
import Testing
import Vapor

/// Records whether a rung was consulted, so the tests can assert that a healthy
/// tier short-circuits the rest of the chain.
private final class CallCounter: @unchecked Sendable {
    private let lock = NIOLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

/// Records what `responseFormat` each rung was asked for, so the capability
/// skip can be asserted rather than inferred.
private final class FormatRecorder: @unchecked Sendable {
    private let lock = NIOLock()
    private var value: [String?] = []

    func record(_ format: String?) {
        lock.withLock { value.append(format) }
    }

    var seen: [String?] {
        lock.withLock { value }
    }
}

private struct CountingChatClient: OpenAIChatClient {
    enum Behaviour {
        case succeeding(marker: String)
        case upstream(status: UInt)
        case transport
        /// 200 with neither content nor a tool call — the failure the chain
        /// could not see before.
        case blank(content: String?)
        /// 200 with no content but a real tool call: legitimate, must not demote.
        case toolCallOnly(name: String)
    }

    let behaviour: Behaviour
    let counter: CallCounter
    var formats: FormatRecorder?

    func chat(
        messages _: [OpenAIMessage],
        tools _: [OpenAITool],
        responseFormat: String?,
        on _: Request
    ) async throws -> OpenAIMessage {
        counter.increment()
        formats?.record(responseFormat)
        switch behaviour {
        case let .succeeding(marker):
            return OpenAIMessage(role: "assistant", content: marker)
        case let .upstream(status):
            throw OpenAIChatUpstreamError(upstreamStatus: status)
        case .transport:
            throw Abort(.internalServerError, reason: "socket closed")
        case let .blank(content):
            return OpenAIMessage(role: "assistant", content: content)
        case let .toolCallOnly(name):
            return OpenAIMessage(
                role: "assistant",
                content: nil,
                toolCalls: [OpenAIToolCall(
                    id: "call_1",
                    type: "function",
                    function: OpenAIFunctionCall(name: name, arguments: "{}")
                )]
            )
        }
    }
}

private func tier(
    _ label: String,
    model: String = "test/model",
    supportsResponseFormat: Bool = true
) -> AIProviderTier {
    AIProviderTier(
        label: label,
        apiKey: "key",
        baseURL: "https://example.test/v1",
        model: model,
        maxTokens: 700,
        supportsResponseFormat: supportsResponseFormat
    )
}

extension AIEnvironmentSuites {
    @Suite("AI fallback chain", .serialized)
    struct AIFallbackChainTests {
        /// A bare application: the chain never touches the database, so there is no
        /// need for `configure` (and no need for a live Postgres).
        private func withRequest(_ test: (Request) async throws -> Void) async throws {
            let app = try await Application.make(.testing)
            do {
                let req = Request(application: app, on: app.eventLoopGroup.next())
                try await test(req)
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }

        // MARK: - Chain behaviour

        @Test("A healthy primary short-circuits the chain")
        func primaryWinsWithoutTouchingFallback() async throws {
            try await withRequest { req in
                let primaryCalls = CallCounter()
                let fallbackCalls = CallCounter()
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "primary"), counter: primaryCalls)),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "free"), counter: fallbackCalls)),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)

                #expect(message.content == "primary")
                #expect(primaryCalls.count == 1)
                #expect(fallbackCalls.count == 0)
            }
        }

        @Test("An account out of credits demotes to the free tier")
        func outOfCreditsFallsThrough() async throws {
            try await withRequest { req in
                let primaryCalls = CallCounter()
                let fallbackCalls = CallCounter()
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .upstream(status: 402), counter: primaryCalls)),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "free"), counter: fallbackCalls)),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)

                #expect(message.content == "free")
                #expect(primaryCalls.count == 1)
                #expect(fallbackCalls.count == 1)
            }
        }

        @Test("A 200 with neither content nor a tool call demotes to the next rung")
        func blankResponseFallsThrough() async throws {
            try await withRequest { req in
                let primaryCalls = CallCounter()
                let fallbackCalls = CallCounter()
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .blank(content: "   \n "), counter: primaryCalls)),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "free"), counter: fallbackCalls)),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)

                #expect(message.content == "free")
                #expect(primaryCalls.count == 1)
                #expect(fallbackCalls.count == 1)
            }
        }

        @Test("A nil-content response with no tool call also demotes")
        func nilContentFallsThrough() async throws {
            try await withRequest { req in
                let fallbackCalls = CallCounter()
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .blank(content: nil), counter: CallCounter())),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "free"), counter: fallbackCalls)),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)

                #expect(message.content == "free")
                #expect(fallbackCalls.count == 1)
            }
        }

        @Test("Blank content with a tool call is a success and does not demote")
        func toolCallWithoutProseIsNotDemoted() async throws {
            try await withRequest { req in
                let fallbackCalls = CallCounter()
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .toolCallOnly(name: "get_expenses"), counter: CallCounter())),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "free"), counter: fallbackCalls)),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)

                #expect(message.toolCalls?.first?.function.name == "get_expenses")
                #expect(message.content == nil)
                #expect(fallbackCalls.count == 0, "a tool call is a usable answer")
            }
        }

        @Test("Prose with no tool call is a success and does not demote")
        func proseWithoutToolCallIsNotDemoted() async throws {
            try await withRequest { req in
                let fallbackCalls = CallCounter()
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "US inflation is 3.1%."), counter: CallCounter())),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "free"), counter: fallbackCalls)),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)

                #expect(message.content == "US inflation is 3.1%.")
                #expect(fallbackCalls.count == 0, "a direct answer needs no tool call")
            }
        }

        @Test("A chain of only blank responses reports the badGateway surface")
        func allBlankExhaustsTheChain() async throws {
            try await withRequest { req in
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .blank(content: ""), counter: CallCounter())),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .blank(content: nil), counter: CallCounter())),
                ])

                await #expect(throws: (any Error).self) {
                    _ = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)
                }
                do {
                    _ = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)
                } catch let error as any AbortError {
                    #expect(error.status == .badGateway)
                }
            }
        }

        @Test("A dead platform key does not brick the assistant")
        func authFailureFallsThrough() async throws {
            try await withRequest { req in
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .upstream(status: 401), counter: CallCounter())),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "free"), counter: CallCounter())),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)
                #expect(message.content == "free")
            }
        }

        @Test("A rate limit and a transport failure both demote")
        func rateLimitAndTransportFallThrough() async throws {
            try await withRequest { req in
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .upstream(status: 429), counter: CallCounter())),
                    .init(tier: tier("secondary"),
                          client: CountingChatClient(behaviour: .transport, counter: CallCounter())),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "free"), counter: CallCounter())),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)
                #expect(message.content == "free")
            }
        }

        @Test("A JSON request skips tiers that cannot honour response_format")
        func jsonRequestSkipsIncapableTier() async throws {
            try await withRequest { req in
                let incapableCalls = CallCounter()
                let capableCalls = CallCounter()
                let formats = FormatRecorder()
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("ultra-free", supportsResponseFormat: false),
                          client: CountingChatClient(behaviour: .succeeding(marker: "ultra"), counter: incapableCalls)),
                    .init(tier: tier("super-free"),
                          client: CountingChatClient(behaviour: .succeeding(marker: "super"),
                                                     counter: capableCalls, formats: formats)),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: "json_object", on: req)

                #expect(message.content == "super")
                #expect(incapableCalls.count == 0)
                #expect(capableCalls.count == 1)
                #expect(formats.seen == ["json_object"])
            }
        }

        @Test("An incapable tier is still used when no response_format is asked for")
        func incapableTierServesPlainRequests() async throws {
            try await withRequest { req in
                let calls = CallCounter()
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("ultra-free", supportsResponseFormat: false),
                          client: CountingChatClient(behaviour: .succeeding(marker: "ultra"), counter: calls)),
                ])

                let message = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)
                #expect(message.content == "ultra")
                #expect(calls.count == 1)
            }
        }

        @Test("An exhausted chain rethrows the last error, preserving the badGateway surface")
        func exhaustedChainRethrowsLastError() async throws {
            try await withRequest { req in
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("primary"),
                          client: CountingChatClient(behaviour: .upstream(status: 402), counter: CallCounter())),
                    .init(tier: tier("free"),
                          client: CountingChatClient(behaviour: .upstream(status: 503), counter: CallCounter())),
                ])

                await #expect(throws: OpenAIChatUpstreamError.self) {
                    _ = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)
                }

                do {
                    _ = try await client.chat(messages: [], tools: [], responseFormat: nil, on: req)
                    Issue.record("Expected the exhausted chain to throw")
                } catch let error as OpenAIChatUpstreamError {
                    #expect(error.upstreamStatus == 503)
                    #expect(error.status == .badGateway)
                }
            }
        }

        @Test("A chain where every tier is skipped reports the feature unavailable")
        func fullySkippedChainThrows() async throws {
            try await withRequest { req in
                let calls = CallCounter()
                let client = FallbackChatClient(rungs: [
                    .init(tier: tier("ultra-free", supportsResponseFormat: false),
                          client: CountingChatClient(behaviour: .succeeding(marker: "ultra"), counter: calls)),
                ])

                await #expect(throws: (any Error).self) {
                    _ = try await client.chat(messages: [], tools: [], responseFormat: "json_object", on: req)
                }
                #expect(calls.count == 0)
            }
        }

        // MARK: - Error classification

        @Test("402 is classified as out of credits, distinct from auth and rate limits")
        func outOfCreditsClassification() {
            #expect(OpenAIChatUpstreamError(upstreamStatus: 402).isOutOfCredits)
            #expect(!OpenAIChatUpstreamError(upstreamStatus: 402).isAuthFailure)
            #expect(!OpenAIChatUpstreamError(upstreamStatus: 401).isOutOfCredits)
            #expect(!OpenAIChatUpstreamError(upstreamStatus: 429).isOutOfCredits)
        }

        // MARK: - Capability table

        @Test("Only the free nemotron ultra variant is marked as lacking response_format")
        func capabilityTable() {
            #expect(!AIModelCapabilities.supportsResponseFormat("nvidia/nemotron-3-ultra-550b-a55b:free"))
            #expect(AIModelCapabilities.supportsResponseFormat("nvidia/nemotron-3-ultra-550b-a55b"))
            #expect(AIModelCapabilities.supportsResponseFormat("nvidia/nemotron-3-super-120b-a12b:free"))
            #expect(AIModelCapabilities.supportsResponseFormat("deepseek/deepseek-v4-flash"))
            // An unknown slug is assumed capable, so a new model behaves as it does today.
            #expect(AIModelCapabilities.supportsResponseFormat("some/brand-new-model"))
        }

        // MARK: - Configuration parsing

        private func clearFallbackEnv() {
            unsetenv("AI_FALLBACK_ENABLED")
            unsetenv("AI_FALLBACK_PROVIDERS")
            unsetenv("AI_FALLBACK_OPENROUTER_API_KEY")
            unsetenv("AI_FALLBACK_OPENAI_API_KEY")
            unsetenv("OPENROUTER_API_KEY")
            unsetenv("OPENAI_API_KEY")
        }

        @Test("With no configuration but an OpenRouter key, the default free chain is used")
        func defaultChainFromBareKey() {
            defer { clearFallbackEnv() }
            clearFallbackEnv()
            setenv("OPENROUTER_API_KEY", "sk-or-test", 1)

            let fallbacks = AIProviderConfiguration.loadFallbacks(maxTokens: 700)

            let keys = Set(fallbacks.map(\.apiKey))
            let baseURLs = Set(fallbacks.map(\.baseURL))
            let usable = fallbacks.filter(\.isUsable).count

            #expect(fallbacks.map(\.model) == AIProviderConfiguration.defaultFallbackModels)
            #expect(keys == ["sk-or-test"])
            #expect(baseURLs == ["https://openrouter.ai/api/v1"])
            #expect(usable == fallbacks.count)
            // The ultra model leads, and it is the one that cannot do JSON.
            #expect(fallbacks.first?.supportsResponseFormat == false)
            #expect(fallbacks.last?.supportsResponseFormat == true)
        }

        @Test("With no key at all no tier is usable, so no client is built")
        func noKeyYieldsNoChain() async throws {
            defer { clearFallbackEnv() }
            clearFallbackEnv()

            // The parser still shapes the default tiers; it is the builder that
            // drops them, so the reason lands in the logs as `ai_tier_dropped`.
            let fallbacks = AIProviderConfiguration.loadFallbacks(maxTokens: 700)
            #expect(fallbacks.filter(\.isUsable).isEmpty)

            let app = try await Application.make(.testing)
            defer { Task { try? await app.asyncShutdown() } }
            #expect(makeFallbackChatClient(tiers: fallbacks, timeout: .seconds(5), logger: app.logger) == nil)
        }

        @Test("A dedicated fallback key takes precedence over the shared one")
        func dedicatedKeyWins() {
            defer { clearFallbackEnv() }
            clearFallbackEnv()
            setenv("OPENROUTER_API_KEY", "shared", 1)
            setenv("AI_FALLBACK_OPENROUTER_API_KEY", "dedicated", 1)

            #expect(AIProviderConfiguration.loadFallbacks(maxTokens: 700).first?.apiKey == "dedicated")
        }

        @Test("An explicit provider|model list is parsed in order")
        func explicitListParsing() {
            defer { clearFallbackEnv() }
            clearFallbackEnv()
            setenv("OPENROUTER_API_KEY", "sk-or-test", 1)
            setenv("OPENAI_API_KEY", "sk-oa-test", 1)
            setenv(
                "AI_FALLBACK_PROVIDERS",
                "openrouter|nvidia/nemotron-3-super-120b-a12b:free, openai|gpt-5.6-luna",
                1
            )

            let fallbacks = AIProviderConfiguration.loadFallbacks(maxTokens: 1200)

            #expect(fallbacks.count == 2)
            #expect(fallbacks[0].model == "nvidia/nemotron-3-super-120b-a12b:free")
            #expect(fallbacks[0].baseURL == "https://openrouter.ai/api/v1")
            #expect(fallbacks[1].model == "gpt-5.6-luna")
            #expect(fallbacks[1].baseURL == "https://api.openai.com/v1")
            #expect(fallbacks[1].apiKey == "sk-oa-test")
            #expect(Set(fallbacks.map(\.maxTokens)) == [1200])
        }

        @Test("Malformed and unsupported entries are dropped, not fatal")
        func malformedEntriesDropped() {
            defer { clearFallbackEnv() }
            clearFallbackEnv()
            setenv("OPENROUTER_API_KEY", "sk-or-test", 1)
            // No separator; an OAuth-only provider with no client here; empty model.
            setenv(
                "AI_FALLBACK_PROVIDERS",
                "garbage,xai-oauth|grok-4.6,openrouter|,openrouter|z-ai/glm-5.2:free",
                1
            )

            let fallbacks = AIProviderConfiguration.loadFallbacks(maxTokens: 700)

            #expect(fallbacks.count == 1)
            #expect(fallbacks[0].model == "z-ai/glm-5.2:free")
        }

        @Test("A tier whose key is missing is dropped before a client is built")
        func tierWithoutKeyIsDropped() {
            defer { clearFallbackEnv() }
            clearFallbackEnv()
            setenv("OPENROUTER_API_KEY", "sk-or-test", 1)
            setenv("AI_FALLBACK_PROVIDERS", "openai|gpt-5.6-luna,openrouter|z-ai/glm-5.2:free", 1)

            let fallbacks = AIProviderConfiguration.loadFallbacks(maxTokens: 700)

            #expect(fallbacks.count == 2)
            // Parsed, but not usable — `makeFallbackChatClient` drops it with a log.
            #expect(fallbacks[0].isUsable == false)
            #expect(fallbacks[1].isUsable == true)
        }

        @Test("AI_FALLBACK_ENABLED=false disables the chain entirely")
        func killSwitch() {
            defer { clearFallbackEnv() }
            clearFallbackEnv()
            setenv("OPENROUTER_API_KEY", "sk-or-test", 1)
            setenv("AI_FALLBACK_ENABLED", "false", 1)

            #expect(AIProviderConfiguration.loadFallbacks(maxTokens: 700).isEmpty)

            setenv("AI_FALLBACK_ENABLED", "true", 1)
            #expect(!AIProviderConfiguration.loadFallbacks(maxTokens: 700).isEmpty)
        }

        @Test("Unusable tiers are dropped when the chain is built")
        func builderDropsUnusableTiers() async throws {
            let app = try await Application.make(.testing)
            defer { Task { try? await app.asyncShutdown() } }

            let keyless = AIProviderTier(
                label: "keyless", apiKey: "", baseURL: "https://example.test/v1",
                model: "m", maxTokens: 700, supportsResponseFormat: true
            )
            #expect(makeFallbackChatClient(tiers: [keyless], timeout: .seconds(5), logger: app.logger) == nil)

            // A single usable tier is returned bare, with no chain wrapper around it.
            let single = makeFallbackChatClient(tiers: [keyless, tier("only")], timeout: .seconds(5), logger: app.logger)
            #expect(single is DefaultOpenAIChatClient)

            let pair = makeFallbackChatClient(
                tiers: [tier("a"), tier("b")], timeout: .seconds(5), logger: app.logger
            )
            #expect(pair is FallbackChatClient)
        }
    }
}
