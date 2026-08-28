import Foundation
import Vapor

/// Central knobs for Norviq-paid in-app AI spend (chat, insights, tips).
/// MCP / BYO-LLM traffic is out of scope — users pay their own model host.
enum AICostControls {
    /// Global kill switch. Default on. Set `AI_ENABLED=false` (or 0/off/no) to
    /// fail closed on all LLM-backed in-app routes and tip generation.
    static var isEnabled: Bool {
        truthy(Environment.get("AI_ENABLED"), default: true)
    }

    /// Separate kill for the proactive tips background job. Also off when
    /// `AI_ENABLED` is false.
    static var proactiveTipsEnabled: Bool {
        guard isEnabled else { return false }
        return truthy(Environment.get("AI_PROACTIVE_TIPS_ENABLED"), default: true)
    }

    /// Per-user Redis day-bucket cap shared by `/v1/ai/chat` and `/v1/ai/insights/*`.
    static var dailyLimit: Int {
        max(1, Environment.get("AI_DAILY_LIMIT").flatMap(Int.init) ?? 50)
    }

    /// Allowance for the per-view AI summaries, counted separately from
    /// `dailyLimit`.
    ///
    /// Its own bucket because the button appears on eight screens and carries a
    /// refresh control, so on the shared counter it would starve `/v1/ai/chat`
    /// -- the one AI surface a user would notice losing. Lower than the shared
    /// limit on purpose: summaries are cached for an hour, so a working day
    /// needs far fewer calls than taps.
    static var viewSummaryDailyLimit: Int {
        max(1, Environment.get("AI_VIEW_SUMMARY_DAILY_LIMIT").flatMap(Int.init) ?? 25)
    }

    /// The Redis bucket the above is counted in.
    static let viewSummaryBucket = "ai_view_summary_daily"

    /// Free-tier monthly assistant turns (`/v1/ai/assistant/...`). Pro is uncapped
    /// at this layer (still subject to route rate limits + daily Redis cap where applied).
    static var freeMonthlyLimit: Int {
        max(0, Environment.get("AI_FREE_MONTHLY_LIMIT").flatMap(Int.init) ?? 5)
    }

    static func requireEnabled(
        reason: String = "AI features are temporarily disabled."
    ) throws {
        guard isEnabled else {
            throw Abort(.serviceUnavailable, reason: reason)
        }
    }

    private static func truthy(_ raw: String?, default defaultValue: Bool) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else { return defaultValue }
        switch value {
        case "0", "false", "off", "no", "disabled":
            return false
        case "1", "true", "on", "yes", "enabled":
            return true
        default:
            return defaultValue
        }
    }
}
