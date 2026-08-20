import Foundation

/// Remembers which providers are out of credit, so the chain stops paying to
/// rediscover it.
///
/// A run over the symbol universe makes hundreds of provider calls. Without
/// this, an exhausted account is re-hit on every single one — each a request
/// that costs something and cannot succeed — and the logs fill with identical
/// failures that read like a network problem.
///
/// Deliberately in-process rather than Redis-backed: Redis is optional here and
/// disabled outright under `.testing`, and a cooldown that silently does nothing
/// in tests is worse than one with a known limit. The limit is that each replica
/// learns independently, which costs one wasted call per replica per window.
final class ProviderCooldownRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var coolingUntil: [String: Date] = [:]
    private let window: TimeInterval

    init(windowSeconds: TimeInterval = 6 * 60 * 60) {
        window = windowSeconds
    }

    func isCoolingDown(_ provider: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = coolingUntil[provider] else { return false }
        if until <= now {
            coolingUntil[provider] = nil
            return false
        }
        return true
    }

    @discardableResult
    func beginCooldown(_ provider: String, now: Date = Date()) -> Date {
        lock.lock()
        defer { lock.unlock() }
        let until = now.addingTimeInterval(window)
        coolingUntil[provider] = until
        return until
    }

    func clear(_ provider: String) {
        lock.lock()
        defer { lock.unlock() }
        coolingUntil[provider] = nil
    }

    /// Providers currently skipped. Surfaced by the readiness endpoint so an
    /// exhausted account is visible instead of looking like a quiet feed.
    func activeCooldowns(now: Date = Date()) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return coolingUntil.filter { $0.value > now }.keys.sorted()
    }
}

extension InsightsProvider {
    /// Stable name for logs and cooldown keys.
    var providerLabel: String {
        String(describing: type(of: self))
    }
}
