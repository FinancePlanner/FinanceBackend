import Vapor

/// Failures the provider chain needs to tell apart.
///
/// Everything used to collapse into `Abort(.badGateway)`, which works as
/// failover and is useless as a signal: a dry DeepAPI account and a transient
/// network blip produced identical logs, and `FallbackInsightsProvider.health`
/// aggregates with `any`, so the whole chain still reported green while the
/// paid tier had been silently skipped for days.
enum InsightsProviderError: AbortError {
    /// The provider is out of credit. Retrying costs another request and cannot
    /// succeed until someone tops up.
    case creditsExhausted(provider: String, detail: String)

    var status: HTTPResponseStatus {
        .badGateway
    }

    var reason: String {
        switch self {
        case let .creditsExhausted(provider, detail):
            "\(provider) is out of credit: \(detail)"
        }
    }

    /// True when retrying before the cooldown elapses is pointless.
    var isTerminalUntilTopUp: Bool {
        switch self {
        case .creditsExhausted: true
        }
    }
}
