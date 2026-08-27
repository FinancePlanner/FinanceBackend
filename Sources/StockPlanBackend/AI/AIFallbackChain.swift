import Foundation
import NIOCore
import Vapor

/// One rung of the chat fallback chain: the credentials and model to try, plus
/// what that model is actually capable of.
struct AIProviderTier: Sendable {
    let label: String
    let apiKey: String
    let baseURL: String
    let model: String
    let maxTokens: Int
    /// Whether the model is trusted to honour `response_format`. The insights
    /// and why-moved paths ask for `json_object` and decode the reply strictly,
    /// so a tier that might return prose is skipped rather than tried.
    let supportsResponseFormat: Bool

    var isUsable: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }
}

/// Per-model capability facts that cannot be discovered from a chat response.
///
/// Sourced from the `supported_parameters` field of OpenRouter's `/models`
/// catalog. Only models that *lack* a capability are listed; anything unknown is
/// assumed capable, so a new model slug behaves like it does today rather than
/// being silently skipped.
enum AIModelCapabilities {
    /// Models OpenRouter's catalog does not list `response_format` for, checked
    /// on 2026-08-20. Only the `:free` variants are affected — the paid and
    /// `:batch` variants of the same models do declare support.
    ///
    /// Worth knowing before removing an entry: probing the free ultra model by
    /// hand *does* return valid JSON for a `json_object` request rather than a
    /// 4xx. That is not a guarantee. OpenRouter routes a free slug across
    /// rotating upstream providers, and a request that silently drops the
    /// parameter comes back as prose, which the insights and why-moved decoders
    /// reject. Listing it here trades a slightly weaker free model for a
    /// deterministic one on the JSON paths.
    private static let noResponseFormat: Set<String> = [
        "nvidia/nemotron-3-ultra-550b-a55b:free",
        "nvidia/nemotron-3.5-lightning:free",
    ]

    static func supportsResponseFormat(_ model: String) -> Bool {
        !noResponseFormat.contains(model.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// Tries a list of chat providers in order and returns the first success.
///
/// The chain exists so the assistant always has a floor to stand on: a missing
/// key, an expired key, an account out of credits, a rate limit or an upstream
/// outage demotes to the next rung instead of taking AI down. It mirrors
/// `FallbackInsightsProvider`, which does the same job for the insights feed.
///
/// Only one rung is consulted in the happy path; the rest are touched exactly
/// when the one before them fails.
struct FallbackChatClient: OpenAIChatClient {
    struct Rung: Sendable {
        let tier: AIProviderTier
        let client: any OpenAIChatClient
    }

    let rungs: [Rung]

    func chat(
        messages: [OpenAIMessage],
        tools: [OpenAITool],
        responseFormat: String?,
        on req: Request
    ) async throws -> OpenAIMessage {
        var lastError: (any Error)?
        var failures = 0
        // Only the last error survives to be thrown, which on its own says
        // nothing about what the other rungs did. Kept so the exhaustion log and
        // the alert can name every rung and how it failed.
        var attempted: [String] = []

        for rung in rungs {
            if responseFormat != nil, !rung.tier.supportsResponseFormat {
                req.logger.debug("ai_fallback_skip", metadata: [
                    "tier": "\(rung.tier.label)",
                    "model": "\(rung.tier.model)",
                    "reason": "response_format_unsupported",
                ])
                continue
            }

            do {
                let message = try await rung.client.chat(
                    messages: messages,
                    tools: tools,
                    responseFormat: responseFormat,
                    on: req
                )
                if failures > 0 {
                    req.logger.warning("ai_fallback_used", metadata: [
                        "tier": "\(rung.tier.label)",
                        "model": "\(rung.tier.model)",
                        "failed_tiers": "\(failures)",
                        "last_status": "\(Self.statusLabel(lastError))",
                    ])
                }
                return message
            } catch {
                lastError = error
                failures += 1
                let status = Self.statusLabel(error)
                attempted.append("\(rung.tier.label)|\(rung.tier.model)=\(status)")
                // A free rung refusing is the one that matters while the account
                // is deliberately unfunded: those models are metered per day, and
                // the allowance is tiered by balance.
                if rung.tier.model.hasSuffix(":free"), status == "429_rate_limited" {
                    await AIProviderAlerter.freeTierRefused(
                        tier: rung.tier.label,
                        model: rung.tier.model,
                        status: status,
                        on: req
                    )
                }
                req.logger.warning("ai_fallback_switch", metadata: [
                    "from_tier": "\(rung.tier.label)",
                    "model": "\(rung.tier.model)",
                    "status": "\(Self.statusLabel(error))",
                    "error": "\(String(reflecting: error))",
                ])
            }
        }

        // Every rung failed (or was skipped). Rethrowing the last error keeps the
        // `.badGateway` surface a single client would have produced, so callers
        // and the assistant's BYOK error mapping behave exactly as before — but
        // that error alone cannot say the *chain* is gone rather than one call
        // being unlucky, so record and announce that separately.
        if failures > 0 {
            req.logger.error("ai_chain_exhausted", metadata: [
                "rungs": "\(rungs.count)",
                "failed": "\(failures)",
                "attempted": "\(attempted.joined(separator: ","))",
            ])
            await AIProviderAlerter.chainExhausted(statuses: attempted, on: req)
        }
        throw lastError ?? Abort(.serviceUnavailable, reason: "AI insights are not enabled on this server.")
    }

    /// Short, log-safe description of why a rung was demoted.
    private static func statusLabel(_ error: (any Error)?) -> String {
        guard let error else { return "none" }
        if let upstream = error as? OpenAIChatUpstreamError {
            if upstream.isOutOfCredits {
                return "402_out_of_credits"
            }
            if upstream.isAuthFailure {
                return "\(upstream.upstreamStatus)_auth"
            }
            if upstream.isRateLimit {
                return "429_rate_limited"
            }
            return "\(upstream.upstreamStatus)"
        }
        if error is CancellationError {
            return "cancelled"
        }
        return "transport"
    }
}

/// Builds the ordered chain from provider-neutral config.
///
/// Returns the bare client when there is only one rung, so the common
/// single-provider deployment carries no wrapper and its logs stay unchanged.
func makeFallbackChatClient(
    tiers: [AIProviderTier],
    timeout: TimeAmount,
    logger: Logger
) -> (any OpenAIChatClient)? {
    let usable = tiers.filter(\.isUsable)
    for dropped in tiers where !dropped.isUsable {
        logger.notice("ai_tier_dropped tier=\(dropped.label) model=\(dropped.model) reason=missing_key_or_model")
    }
    guard !usable.isEmpty else { return nil }

    let rungs = usable.map { tier in
        FallbackChatClient.Rung(
            tier: tier,
            client: DefaultOpenAIChatClient(
                apiKey: tier.apiKey,
                model: tier.model,
                baseURL: tier.baseURL,
                maxTokens: tier.maxTokens,
                timeout: timeout
            )
        )
    }

    logger.notice("ai_provider_chain \(usable.map(\.label).joined(separator: " -> "))")
    return rungs.count == 1 ? rungs[0].client : FallbackChatClient(rungs: rungs)
}
