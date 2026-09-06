import Fluent
import Foundation
import Vapor

/// Resolves the single "manual" `Account` that holds a user's hand-entered
/// activity for a portfolio.
///
/// Both the sell path (which credits cash) and manually recorded transactions
/// must land on the *same* account, or a user's cash balance and their trade
/// history end up on two different accounts for the same portfolio.
enum ManualAccountResolver {
    static let broker = "manual"

    static func findOrCreate(
        userId: UUID,
        portfolioId: UUID,
        on db: any Database
    ) async throws -> Account {
        if let existing = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$broker == broker)
            .first()
        {
            return existing
        }

        // Accounts created before multi-portfolio support have no portfolio.
        // Adopt the user's legacy manual account so its cash balance is retained
        // and the stable external ID is not inserted a second time.
        if let legacy = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioId == nil)
            .filter(\.$broker == broker)
            .first()
        {
            legacy.portfolioId = portfolioId
            try await legacy.save(on: db)
            return legacy
        }

        let account = Account(
            userId: userId,
            externalId: "manual-\(userId.uuidString.lowercased())",
            broker: broker,
            displayName: "Manual Cash Account",
            baseCurrency: "USD",
            portfolioId: portfolioId
        )
        try await account.save(on: db)
        return account
    }
}
