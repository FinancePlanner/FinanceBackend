import Foundation
import Vapor

/// Scopes grantable to third-party credentials (personal access tokens, OAuth tokens).
/// First-party session JWTs carry no ScopeContext and bypass scope checks entirely.
///
/// Scopes are per-domain read/write pairs. A domain maps to one controller's
/// routes, so `ScopeRequirementMiddleware` can gate a whole route group at
/// registration without touching handlers.
///
/// Three endpoints are deliberately *not* reachable by any scope — account
/// deletion, personal-access-token minting, and OAuth consent approval. They stay
/// on `SessionToken.authenticator()` plus `FirstPartyOnlyMiddleware`. A token that
/// can mint tokens grants itself every scope, which would make this enum decorative.
enum APIScope: String, CaseIterable, Codable, Sendable {
    // Portfolio data
    case watchlistRead = "watchlist:read"
    case watchlistWrite = "watchlist:write"
    case holdingsRead = "holdings:read"
    case holdingsWrite = "holdings:write"
    case transactionsRead = "transactions:read"
    case transactionsWrite = "transactions:write"
    case portfolioRead = "portfolio:read"
    case portfolioWrite = "portfolio:write"
    case targetsRead = "targets:read"
    case targetsWrite = "targets:write"
    case cryptoRead = "crypto:read"
    case cryptoWrite = "crypto:write"

    // Research and notes
    case researchRead = "research:read"
    case researchWrite = "research:write"

    // Money in / money out
    case expensesRead = "expenses:read"
    case expensesWrite = "expenses:write"
    case budgetRead = "budget:read"
    case budgetWrite = "budget:write"
    case goalsRead = "goals:read"
    case goalsWrite = "goals:write"

    // Planning and modelling
    case planningRead = "planning:read"
    case planningWrite = "planning:write"
    case taxRead = "tax:read"
    case taxWrite = "tax:write"

    // Account surface
    case notificationsRead = "notifications:read"
    case notificationsWrite = "notifications:write"
    case settingsRead = "settings:read"
    case settingsWrite = "settings:write"
    case integrationsRead = "integrations:read"
    case integrationsWrite = "integrations:write"
    case billingRead = "billing:read"
    case billingWrite = "billing:write"
    case exportRead = "export:read"
    case exportWrite = "export:write"
    case assistantRead = "assistant:read"
    case assistantWrite = "assistant:write"

    // Read-only reference data
    case marketRead = "market:read"
    case insightsRead = "insights:read"
    case reportsRead = "reports:read"

    /// Superseded by `integrationsRead`. Still parses so tokens minted before the
    /// per-domain split keep working; it gates nothing on its own.
    case bankRead = "bank:read"

    var humanDescription: String {
        switch self {
        case .watchlistRead: "Read your watchlists"
        case .watchlistWrite: "Add, edit, and remove watchlist entries"
        case .holdingsRead: "Read your holdings and positions"
        case .holdingsWrite: "Add, edit, sell, and delete positions"
        case .transactionsRead: "Read your recorded trades, lots, and profit/loss"
        case .transactionsWrite: "Record, edit, and delete trades"
        case .portfolioRead: "Read your portfolio holdings and summary"
        case .portfolioWrite: "Create and edit portfolios, lists, and cash accounts"
        case .targetsRead: "Read your price targets and alerts"
        case .targetsWrite: "Create, edit, and delete price targets and alerts"
        case .cryptoRead: "Read your crypto holdings and watchlist"
        case .cryptoWrite: "Add, edit, and remove crypto holdings and watchlist entries"
        case .researchRead: "Read your research notes and saved articles"
        case .researchWrite: "Write and delete research notes and saved articles"
        case .expensesRead: "Read your expenses and categories"
        case .expensesWrite: "Add, edit, and delete expenses"
        case .budgetRead: "Read your budget snapshots and plan items"
        case .budgetWrite: "Create and edit budget snapshots and plan items"
        case .goalsRead: "Read your goals"
        case .goalsWrite: "Create, edit, and delete goals"
        case .planningRead: "Read your scenarios, forecasts, and rebalancing plans"
        case .planningWrite: "Create and run scenarios, forecasts, and rebalancing plans"
        case .taxRead: "Read your tax dashboard and loss carryforwards"
        case .taxWrite: "Edit your tax profile and generate tax reports"
        case .notificationsRead: "Read your notifications"
        case .notificationsWrite: "Mark notifications read and change notification preferences"
        case .settingsRead: "Read your account preferences"
        case .settingsWrite: "Change your account preferences"
        case .integrationsRead: "Read your connected banks, brokers, and integrations"
        case .integrationsWrite: "Connect, sync, and disconnect banks, brokers, and integrations"
        case .billingRead: "Read your subscription status"
        case .billingWrite: "Restore purchases and redeem coupons"
        case .exportRead: "Read and download your data exports"
        case .exportWrite: "Create data exports of your account"
        case .assistantRead: "Read your assistant conversations and insights"
        case .assistantWrite: "Start conversations and confirm assistant actions"
        case .marketRead: "Read market data"
        case .insightsRead: "Read market insights"
        case .reportsRead: "Read your spending reports"
        case .bankRead: "Read your synced bank accounts and transactions"
        }
    }

    /// Scopes offered when minting a new credential. `bank:read` is omitted so the
    /// deprecated scope is not granted to anything new, while existing tokens
    /// carrying it still authenticate.
    static var grantable: [APIScope] {
        allCases.filter { $0 != .bankRead }
    }

    static func parse(_ raw: [String]) throws -> Set<APIScope> {
        var scopes: Set<APIScope> = []
        for value in raw {
            guard let scope = APIScope(rawValue: value) else {
                throw Abort(.badRequest, reason: "Unknown scope '\(value)'")
            }
            scopes.insert(scope)
        }
        return scopes
    }
}

enum ScopedTokenKind: String, Sendable {
    case personalAccessToken = "pat"
    case oauthAccessToken = "oauth"
}

/// Present on a request only when it authenticated with a scoped third-party token.
struct ScopeContext: Authenticatable, Sendable {
    let tokenId: UUID
    let kind: ScopedTokenKind
    let scopes: Set<APIScope>
}
