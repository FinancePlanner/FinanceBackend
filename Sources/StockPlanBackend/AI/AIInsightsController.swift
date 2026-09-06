import Foundation
import StockPlanShared
import Vapor

struct AIInsightsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let insights = routes
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped(ScopeRequirementMiddleware(.assistantRead))
            .grouped("ai", "insights")

        insights.get("expenses", use: expenses)
        insights.get("portfolio", use: portfolio)
        insights.get("summary", use: summary)
    }

    @Sendable
    func expenses(req: Request) async throws -> AIInsightCardResponse {
        try await generate(.expenses, req)
    }

    @Sendable
    func portfolio(req: Request) async throws -> AIInsightCardResponse {
        try await generate(.portfolio, req)
    }

    @Sendable
    func summary(req: Request) async throws -> AIInsightCardResponse {
        try await generate(.summary, req)
    }

    // MARK: - Helpers

    private func generate(_ kind: AIInsightKind, _ req: Request) async throws -> AIInsightCardResponse {
        let session = try await requireAIEntitlement(req)
        try await AIDailyCap.enforce(
            req,
            userId: session.userId,
            unavailableReason: "AI insights are temporarily unavailable.",
            limitReachedReason: "Daily AI insight limit reached. Try again tomorrow."
        )
        return try await req.application.aiInsightsService.generate(
            kind: kind, userId: session.userId, on: req
        )
    }

    /// Pro/trial gate — mirrors `requireCryptoEntitlement` in CryptoController.
    private func requireAIEntitlement(_ req: Request) async throws -> SessionToken {
        try AICostControls.requireEnabled(reason: "AI insights are temporarily unavailable.")
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.aiInsights, userId: session.userId, on: req.db)
        return session
    }
}
