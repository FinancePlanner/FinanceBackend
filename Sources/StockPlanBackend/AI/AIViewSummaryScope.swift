import Foundation

/// Which screen a summary is about.
///
/// Deliberately backend-local, and deliberately **not** an `AIInsightKind`.
/// That enum lives in the pinned `norviq-shared` package, is exhaustively
/// switched in four places across two repos, and is a bare `String, Codable`
/// with no unknown-case handling — so a backend returning a new case to an
/// older client is a hard `DecodingError`, not a graceful degrade. The two
/// repos are already on different tags (backend 4.5.0, iOS 4.4.0), which makes
/// that a two-repo release rather than a config change.
///
/// Keeping the scope here means a ninth screen is a backend-only deploy, and
/// the wire format carries a plain string a stale client can still render.
/// `AIPrompt.whyMovedUserPrompt` and `WhyMovedDTOs` set this precedent; so does
/// `AITipResponse.kind`, which is a free-form `String` inside shared itself.
enum AIViewScope: String, CaseIterable, Sendable {
    case home
    case portfolio
    case expenses
    case crypto
    case markets
    case economy
    case reports
    case tax

    /// Used in the prompt and in the loading copy the client shows.
    var displayName: String {
        switch self {
        case .home: "dashboard"
        case .portfolio: "portfolio"
        case .expenses: "spending"
        case .crypto: "crypto holdings"
        case .markets: "markets"
        case .economy: "economy"
        case .reports: "reports"
        case .tax: "tax position"
        }
    }

    /// What the model is asked to write about this screen.
    ///
    /// One line each, in the same shape as `AIPrompt.userPrompt`, because the
    /// system prompt already carries every rule that matters — no numbers in
    /// the prose, no advice, JSON only.
    var instruction: String {
        switch self {
        case .home:
            "Generate a narrative for the user's dashboard: their overall financial position right now."
        case .portfolio:
            "Generate a 'your portfolio at a glance' narrative."
        case .expenses:
            "Generate a 'where your money went' narrative for the current month."
        case .crypto:
            "Generate a narrative about the user's crypto holdings and how they have moved."
        case .markets:
            "Generate a neutral narrative describing what markets are doing today."
        case .economy:
            "Generate a neutral narrative describing the current economic picture for the user's country."
        case .reports:
            "Generate a narrative about how the user's spending has trended across recent months."
        case .tax:
            "Generate a narrative about the user's current tax position for the selected year."
        }
    }

    /// Whether the facts are about this user, or the same for everyone.
    ///
    /// Markets and the economy are public data: two users on the same day get
    /// the same snapshot. Recorded here rather than acted on — the cache key
    /// stays per-user for now, because a shared key is only safe once the
    /// datasets are confirmed to carry nothing user-derived, and being wrong
    /// about that leaks one person's figures to another.
    var isUserSpecific: Bool {
        switch self {
        case .markets, .economy: false
        case .home, .portfolio, .expenses, .crypto, .reports, .tax: true
        }
    }
}
