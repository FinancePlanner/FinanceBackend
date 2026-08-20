import Foundation
import Vapor

/// Scopes grantable to third-party credentials (personal access tokens, OAuth tokens).
/// First-party session JWTs carry no ScopeContext and bypass scope checks entirely.
enum APIScope: String, CaseIterable, Codable, Sendable {
    case expensesRead = "expenses:read"
    case expensesWrite = "expenses:write"
    case reportsRead = "reports:read"
    case marketRead = "market:read"
    case portfolioRead = "portfolio:read"
    case insightsRead = "insights:read"
    case bankRead = "bank:read"
    case taxRead = "tax:read"

    var humanDescription: String {
        switch self {
        case .expensesRead: "Read your expenses and categories"
        case .expensesWrite: "Add, edit, and delete expenses"
        case .reportsRead: "Read your spending reports"
        case .marketRead: "Read market data"
        case .portfolioRead: "Read your portfolio holdings and summary"
        case .insightsRead: "Read market insights"
        case .bankRead: "Read your synced bank accounts and transactions"
        case .taxRead: "Read your tax dashboard and loss carryforwards"
        }
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
