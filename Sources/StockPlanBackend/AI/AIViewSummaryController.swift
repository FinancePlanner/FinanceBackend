import Foundation
import StockPlanShared
import Vapor

/// `GET /v1/ai/view-summary/:scope` — a generated summary of one screen.
///
/// Separate from `AIInsightsController` because the insight cards are three
/// fixed kinds from a shared enum, while a scope is a backend-local string that
/// can grow without a client release. Same gate stack, same Pro entitlement,
/// but its own daily bucket — see `AICostControls.viewSummaryBucket`.
struct AIViewSummaryController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped(ScopeRequirementMiddleware(.assistantRead))
            .get("ai", "view-summary", ":scope", use: summary)
    }

    @Sendable
    func summary(req: Request) async throws -> AIViewSummaryResponse {
        guard let raw = req.parameters.get("scope"),
              let scope = AIViewScope(rawValue: raw)
        else {
            // Naming the valid scopes turns a client typo into a one-look fix
            // rather than a support thread.
            throw Abort(
                .badRequest,
                reason: "Unknown scope. Valid scopes: "
                    + AIViewScope.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }

        let session = try await requireAIEntitlement(req)
        let query = try req.query.decode(SummaryQuery.self)

        return try await req.application.aiViewSummaryService.generate(
            scope: scope,
            userId: session.userId,
            options: AIViewSummaryOptions(
                refresh: query.refresh ?? false,
                country: MacroCountry(query: query.country),
                jurisdiction: query.jurisdiction,
                taxYear: query.taxYear
            ),
            on: req
        )
    }

    /// Every field optional, and every absence handled server-side. The button
    /// that opens this sheet sits in a toolbar and carries no context, so a 400
    /// on a missing parameter would be a permanent error on a screen whose data
    /// is fine.
    private struct SummaryQuery: Content {
        var refresh: Bool?
        var country: String?
        var jurisdiction: TaxJurisdiction?
        var taxYear: Int?
    }

    /// Identical to `AIInsightsController.requireAIEntitlement` — the same
    /// operation on the same data deserves the same gate. The daily cap is
    /// enforced inside the service instead, because it must come *after* the
    /// cache read: a cache hit spent no upstream call and must not spend quota.
    private func requireAIEntitlement(_ req: Request) async throws -> SessionToken {
        try AICostControls.requireEnabled(reason: "AI summaries are temporarily unavailable.")
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.aiInsights, userId: session.userId, on: req.db)
        return session
    }
}
