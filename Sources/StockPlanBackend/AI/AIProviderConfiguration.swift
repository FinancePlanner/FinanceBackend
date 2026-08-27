import Foundation
import NIOCore
import Vapor

enum AIProviderKind: String, Sendable {
    case openAI = "openai"
    case openRouter = "openrouter"
    case custom
}

/// Provider-neutral configuration for both Chat Completions and Responses API
/// workloads. OpenRouter is the multi-model production path because it
/// normalizes tool calling and Responses payloads across upstream providers.
struct AIProviderConfiguration: Sendable {
    private struct ProviderDefaults {
        let key: String
        let baseURL: String
        let model: String
        let tipsModel: String
    }

    let provider: AIProviderKind
    let apiKey: String
    let baseURL: String
    let defaultModel: String
    let chatModel: String
    let tipsModel: String
    let maxTokens: Int
    /// Ordered providers tried when the primary fails. Empty when none resolve.
    let fallbacks: [AIProviderTier]
    /// The free plan's chain. Guaranteed to contain only zero-cost slugs.
    let freeTiers: [AIProviderTier]
    /// Paid alternates tried after the primary and before the free floor.
    let proFallbacks: [AIProviderTier]
    /// Per-request upstream timeout, shared by every rung of the chain.
    let requestTimeout: TimeAmount

    var isConfigured: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !defaultModel.isEmpty
    }

    /// The configured primary, or nil when no provider key is set.
    var primaryTier: AIProviderTier? {
        guard isConfigured else { return nil }
        return AIProviderTier(
            label: "primary-\(provider.rawValue)",
            apiKey: apiKey,
            baseURL: baseURL,
            model: defaultModel,
            maxTokens: maxTokens,
            supportsResponseFormat: AIModelCapabilities.supportsResponseFormat(defaultModel)
        )
    }

    /// The Pro plan's chain: the paid primary, then any paid alternates, then the
    /// free floor.
    ///
    /// The floor is deliberate. Norviq's OpenRouter account can sit at zero
    /// balance, and a Pro user hitting a 402 should get a weaker answer rather
    /// than no answer. See `AIFallbackChain` for the demotion rules.
    var proTiers: [AIProviderTier] {
        (primaryTier.map { [$0] } ?? []) + proFallbacks + freeTiers
    }

    /// The pre-routing chain: the primary followed by `AI_FALLBACK_PROVIDERS`.
    /// Used when plan routing is switched off.
    var legacyTiers: [AIProviderTier] {
        (primaryTier.map { [$0] } ?? []) + fallbacks
    }

    static func load() -> Self {
        let provider = AIProviderKind(
            rawValue: (Environment.get("AI_PROVIDER") ?? "openai").lowercased()
        ) ?? .custom
        let defaults = switch provider {
        case .openAI:
            ProviderDefaults(
                key: Environment.get("OPENAI_API_KEY") ?? "",
                baseURL: "https://api.openai.com/v1",
                model: "gpt-5.6-terra",
                tipsModel: "gpt-5.6-luna"
            )
        case .openRouter:
            ProviderDefaults(
                key: Environment.get("OPENROUTER_API_KEY") ?? "",
                baseURL: "https://openrouter.ai/api/v1",
                model: "anthropic/claude-sonnet-4.6",
                tipsModel: "google/gemini-3.5-flash"
            )
        case .custom:
            ProviderDefaults(key: "", baseURL: "", model: "", tipsModel: "")
        }

        let legacyBaseURL = provider == .openAI ? Environment.get("OPENAI_BASE_URL") : nil
        let legacyModel = provider == .openAI ? Environment.get("OPENAI_MODEL") : nil
        let defaultModel = firstNonEmpty(
            Environment.get("AI_MODEL"),
            legacyModel,
            defaults.model
        )
        let maxTokens = Environment.get("AI_MAX_TOKENS").flatMap(Int.init)
            ?? Environment.get("OPENAI_MAX_TOKENS").flatMap(Int.init)
            ?? 700
        return Self(
            provider: provider,
            apiKey: firstNonEmpty(Environment.get("AI_API_KEY"), defaults.key),
            baseURL: firstNonEmpty(
                Environment.get("AI_BASE_URL"),
                legacyBaseURL,
                defaults.baseURL
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            defaultModel: defaultModel,
            chatModel: firstNonEmpty(Environment.get("AI_CHAT_MODEL"), defaultModel),
            tipsModel: firstNonEmpty(Environment.get("AI_TIPS_MODEL"), defaults.tipsModel, defaultModel),
            maxTokens: maxTokens,
            fallbacks: loadFallbacks(maxTokens: maxTokens),
            freeTiers: loadFreeTiers(maxTokens: maxTokens),
            proFallbacks: loadProFallbacks(maxTokens: maxTokens),
            requestTimeout: .seconds(Int64(
                max(1, Environment.get("AI_REQUEST_TIMEOUT_SECONDS").flatMap(Int.init) ?? 60)
            ))
        )
    }

    /// The default floor: free OpenRouter models, in capability order.
    ///
    /// Used when `AI_FALLBACK_PROVIDERS` is unset, so a checkout carrying
    /// nothing but an OpenRouter key still answers. The ultra model leads
    /// because it is the strongest free option; the 120b sits behind it because
    /// it is the one that declares `response_format` support, which the JSON
    /// workloads need. See `AIModelCapabilities`.
    static let defaultFallbackModels = [
        "nvidia/nemotron-3-ultra-550b-a55b:free",
        "nvidia/nemotron-3-super-120b-a12b:free",
    ]

    /// Parses `AI_FALLBACK_PROVIDERS` into ordered tiers.
    ///
    /// Format is comma-separated `provider|model`. The separator is `|` rather
    /// than `:` or `/` because model slugs contain both
    /// (`openrouter|nvidia/nemotron-3-ultra-550b-a55b:free`). Malformed entries
    /// are dropped rather than failing the boot — a typo in one rung must not
    /// take the whole app down.
    static func loadFallbacks(maxTokens: Int) -> [AIProviderTier] {
        guard envBool("AI_FALLBACK_ENABLED", default: true) else { return [] }

        let raw = Environment.get("AI_FALLBACK_PROVIDERS")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let specs = raw.isEmpty
            ? defaultFallbackModels.map { (provider: "openrouter", model: $0) }
            : parseTierSpecs(raw)

        return makeTiers(specs: specs, maxTokens: maxTokens)
    }

    /// The free plan's chain, in order.
    ///
    /// Sources, first non-empty wins: `AI_FREE_PROVIDERS`, then
    /// `AI_FALLBACK_PROVIDERS` (so a deployment that predates plan routing keeps
    /// the floor it already has), then `defaultFallbackModels`.
    ///
    /// Deliberately not gated on `AI_FALLBACK_ENABLED`. That switch means "the
    /// paid chain does not demote"; it must never mean "free users have no model
    /// at all".
    static func loadFreeTiers(maxTokens: Int) -> [AIProviderTier] {
        let raw = firstNonEmpty(
            Environment.get("AI_FREE_PROVIDERS"),
            Environment.get("AI_FALLBACK_PROVIDERS")
        )
        let specs = raw.isEmpty
            ? defaultFallbackModels.map { (provider: "openrouter", model: $0) }
            : parseTierSpecs(raw)

        // The money guard. A free user must never reach a metered slug, so a
        // configured tier that is not zero-cost is dropped rather than billed —
        // an env-var typo is not a licence to spend.
        let free = specs.filter { isFreeModelSlug($0.model) }
        guard !free.isEmpty else {
            return makeTiers(
                specs: defaultFallbackModels.map { (provider: "openrouter", model: $0) },
                maxTokens: maxTokens
            )
        }
        return makeTiers(specs: free, maxTokens: maxTokens)
    }

    /// Paid alternates tried after the primary, before the free floor. Usually a
    /// cheaper model than `AI_MODEL`. Empty is the normal case.
    static func loadProFallbacks(maxTokens: Int) -> [AIProviderTier] {
        let raw = Environment.get("AI_PRO_FALLBACK_PROVIDERS")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return [] }
        return makeTiers(specs: parseTierSpecs(raw), maxTokens: maxTokens)
    }

    /// Whether a slug costs nothing to run.
    ///
    /// OpenRouter marks zero-cost variants with a `:free` suffix, and
    /// `openrouter/free` is the auto-router across that same pool. Anything else
    /// is assumed metered — the safe direction to be wrong in.
    static func isFreeModelSlug(_ model: String) -> Bool {
        let slug = model.trimmingCharacters(in: .whitespaces).lowercased()
        return slug.hasSuffix(":free") || slug == "openrouter/free"
    }

    /// Parses comma-separated `provider|model` entries. Malformed entries are
    /// dropped rather than failing the boot.
    private static func parseTierSpecs(_ raw: String) -> [(provider: String, model: String)] {
        raw.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (provider: parts[0].lowercased(), model: parts[1])
        }
    }

    private static func makeTiers(
        specs: [(provider: String, model: String)],
        maxTokens: Int
    ) -> [AIProviderTier] {
        specs.compactMap { spec in
            guard let endpoint = fallbackEndpoint(for: spec.provider) else { return nil }
            return AIProviderTier(
                label: "\(spec.provider)-\(spec.model)",
                apiKey: endpoint.apiKey,
                baseURL: endpoint.baseURL,
                model: spec.model,
                maxTokens: maxTokens,
                supportsResponseFormat: AIModelCapabilities.supportsResponseFormat(spec.model)
            )
        }
    }

    /// Fallback rungs are OpenAI-compatible bearer-key endpoints only. A
    /// provider needing OAuth or a subscription session has no client here, so
    /// it is dropped rather than half-configured.
    private static func fallbackEndpoint(for provider: String) -> (apiKey: String, baseURL: String)? {
        switch provider {
        case "openrouter":
            (
                apiKey: firstNonEmpty(
                    Environment.get("AI_FALLBACK_OPENROUTER_API_KEY"),
                    Environment.get("OPENROUTER_API_KEY")
                ),
                baseURL: "https://openrouter.ai/api/v1"
            )
        case "openai":
            (
                apiKey: firstNonEmpty(
                    Environment.get("AI_FALLBACK_OPENAI_API_KEY"),
                    Environment.get("OPENAI_API_KEY")
                ),
                baseURL: "https://api.openai.com/v1"
            )
        default:
            nil
        }
    }

    private static func envBool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let raw = Environment.get(key)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty
        else { return defaultValue }
        switch raw {
        case "1", "true", "yes", "on", "enabled": return true
        case "0", "false", "no", "off", "disabled": return false
        default: return defaultValue
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.first ?? ""
    }
}
