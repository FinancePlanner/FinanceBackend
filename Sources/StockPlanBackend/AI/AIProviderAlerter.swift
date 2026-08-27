import Foundation
import Vapor

/// Stops one bad minute from becoming a hundred Discord messages.
///
/// The chat chain is walked once per request, so an exhausted provider produces
/// an alert-worthy failure on *every* turn until it recovers. Without a throttle
/// the first outage would bury the channel and train everyone to mute it.
///
/// In-process rather than Redis-backed, matching `ProviderCooldownRegistry`:
/// Redis is optional here and disabled under `.testing`, and a throttle that
/// silently does nothing in tests is worse than one with a known limit. The
/// limit is that each replica alerts independently — at most one duplicate per
/// replica per window.
final class AIAlertThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSent: [String: Date] = [:]
    private let window: TimeInterval

    init(windowSeconds: TimeInterval = 15 * 60) {
        window = windowSeconds
    }

    /// True at most once per window per key, and records the send when it is.
    func shouldSend(_ key: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastSent[key], now.timeIntervalSince(last) < window {
            return false
        }
        lastSent[key] = now
        return true
    }
}

/// Tells someone when the model stopped answering.
///
/// Nothing did before: the only trace of a dead provider chain was a log line
/// nobody reads, so the first sign was a user reporting a broken assistant.
///
/// While the OpenRouter account is deliberately unfunded, the free rungs are not
/// a safety net — they *are* the plan. So the alert-worthy event is the free
/// floor refusing, not a balance crossing a threshold: against an empty account
/// a low-balance alert would fire constantly and mean nothing.
enum AIProviderAlerter {
    /// Shared so the throttle actually throttles; a per-request instance would
    /// forget every previous alert and defeat the point.
    static let throttle = AIAlertThrottle()

    static func chainExhausted(statuses: [String], on req: Request) async {
        guard throttle.shouldSend("ai_chain_exhausted") else { return }
        await send(
            """
            ⚠️ **Norviq AI: every provider failed**
            The whole chain was walked and no rung answered.
            Rungs tried: \(statuses.isEmpty ? "none" : statuses.joined(separator: ", "))
            The assistant is returning errors to users right now.
            """,
            on: req
        )
    }

    /// A `:free` rung refusing is the signal that matters while running without
    /// credits — OpenRouter meters free models per day, and that allowance is
    /// tiered by account balance.
    static func freeTierRefused(tier: String, model: String, status: String, on req: Request) async {
        guard throttle.shouldSend("ai_free_tier_refused:\(model)") else { return }
        await send(
            """
            ⚠️ **Norviq AI: a free model refused**
            Tier `\(tier)` model `\(model)` returned `\(status)`.
            If this is a daily cap, the assistant degrades until it resets or the \
            OpenRouter account is funded.
            """,
            on: req
        )
    }

    /// Best-effort by design: an alert that throws would turn a degraded
    /// assistant into a failed request, which is the opposite of the point.
    private static func send(_ message: String, on req: Request) async {
        do {
            try await req.discord.send(message, on: req)
        } catch {
            req.logger.warning("ai_alert_delivery_failed error=\(String(reflecting: error))")
        }
    }
}
