import Foundation
@testable import StockPlanBackend
import Testing

/// The chain is walked once per request, so an exhausted provider is
/// alert-worthy on every turn until it recovers. These tests pin the throttle
/// that keeps that from flooding the channel.
@Suite("AI provider alert throttling")
struct AIProviderAlertTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The first failure alerts")
    func firstFailureAlerts() {
        let throttle = AIAlertThrottle(windowSeconds: 900)
        #expect(throttle.shouldSend("chain_exhausted", now: start))
    }

    @Test("A repeat inside the window stays quiet")
    func repeatsAreSuppressed() {
        let throttle = AIAlertThrottle(windowSeconds: 900)
        #expect(throttle.shouldSend("chain_exhausted", now: start))
        #expect(!throttle.shouldSend("chain_exhausted", now: start.addingTimeInterval(1)))
        #expect(!throttle.shouldSend("chain_exhausted", now: start.addingTimeInterval(899)))
    }

    @Test("A still-broken provider alerts again once the window passes")
    func alertsAgainAfterWindow() {
        let throttle = AIAlertThrottle(windowSeconds: 900)
        #expect(throttle.shouldSend("chain_exhausted", now: start))
        #expect(throttle.shouldSend("chain_exhausted", now: start.addingTimeInterval(901)))
    }

    @Test("Different failures do not silence each other")
    func keysAreIndependent() {
        let throttle = AIAlertThrottle(windowSeconds: 900)
        #expect(throttle.shouldSend("chain_exhausted", now: start))
        // A rate-limit alert must still get through while an exhaustion alert
        // is in its quiet window — they mean different things.
        #expect(throttle.shouldSend("rate_limited", now: start))
    }
}
