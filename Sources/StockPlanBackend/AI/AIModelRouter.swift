import Foundation
import Vapor

/// Which chain a turn is entitled to.
///
/// This is Norviq's own plan, not anything OpenRouter knows about. OpenRouter
/// runs whatever slug it is handed and bills accordingly; deciding which slug a
/// user may reach is entirely this server's job.
enum AIPlanTier: String, Sendable {
    case free
    case pro
}

/// Env knobs for plan-based model routing.
enum AIPlanRoutingSettings {
    /// Rollback lever. Off means both plans share the one legacy chain — the
    /// exact behaviour that shipped on 2026-08-20, where a free user keeps the
    /// paid model until it fails.
    static var enabled: Bool {
        guard let raw = Environment.get("AI_PLAN_ROUTING_ENABLED")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty
        else { return true }
        switch raw {
        case "0", "false", "no", "off", "disabled": return false
        default: return true
        }
    }
}

/// Holds one prebuilt chat chain per plan.
///
/// Both chains are assembled once at boot. Nothing here is per-request: routing
/// is a lookup, and the failure-demotion inside each chain is unchanged.
struct AIModelRouter: Sendable {
    let free: any OpenAIChatClient
    let pro: any OpenAIChatClient
    /// Kept for logging and for the tests that assert on chain composition.
    let freeTiers: [AIProviderTier]
    let proTiers: [AIProviderTier]

    init(
        free: any OpenAIChatClient,
        pro: any OpenAIChatClient,
        freeTiers: [AIProviderTier] = [],
        proTiers: [AIProviderTier] = []
    ) {
        self.free = free
        self.pro = pro
        self.freeTiers = freeTiers
        self.proTiers = proTiers
    }

    func client(for plan: AIPlanTier) -> any OpenAIChatClient {
        switch plan {
        case .free: free
        case .pro: pro
        }
    }

    func tiers(for plan: AIPlanTier) -> [AIProviderTier] {
        switch plan {
        case .free: freeTiers
        case .pro: proTiers
        }
    }
}

/// Builds both plan chains from the environment.
///
/// Returns nil when plan routing is switched off, which leaves callers on the
/// single pre-routing chain — the one rollback path, and the same path the
/// scripted-client tests take.
///
/// Reuses `makeFallbackChatClient` for each chain, so tier dropping, the
/// `ai_tier_dropped` / `ai_provider_chain` logs, and the single-rung collapse all
/// behave identically to the pre-routing build.
func makeAIModelRouter(_ app: Application) -> AIModelRouter? {
    guard AIPlanRoutingSettings.enabled else {
        app.logger.notice("ai_plan_routing disabled; every plan shares the legacy chain")
        return nil
    }

    let configuration = AIProviderConfiguration.load()
    let freeTiers = configuration.freeTiers
    let proTiers = configuration.proTiers

    // Built separately so a broken free rung cannot silently reshape the pro
    // chain, and so each gets its own `ai_provider_chain` line at boot.
    let free = makeFallbackChatClient(
        tiers: freeTiers, timeout: configuration.requestTimeout, logger: app.logger
    )
    let pro = makeFallbackChatClient(
        tiers: proTiers, timeout: configuration.requestTimeout, logger: app.logger
    )

    // No usable rung on either side means there is nothing to route between.
    // Returning nil rather than a pair of disabled clients matters: the resolver
    // then falls through to `app.openAIChatClient`, which is what a caller that
    // sets that client directly — a test with a scripted client, say — expects to
    // be used.
    guard free != nil || pro != nil else {
        app.logger.notice("ai_plan_routing no usable tier on either plan; routing is inert")
        return nil
    }

    app.logger.notice("""
    ai_plan_routing enabled \
    free=\(freeTiers.map(\.model).joined(separator: " -> ")) \
    pro=\(proTiers.map(\.model).joined(separator: " -> "))
    """)

    return AIModelRouter(
        free: free ?? DisabledOpenAIChatClient(),
        pro: pro ?? DisabledOpenAIChatClient(),
        freeTiers: freeTiers,
        proTiers: proTiers
    )
}
