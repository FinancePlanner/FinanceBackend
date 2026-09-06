import StockPlanShared
import Vapor

struct BadgeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("badges")
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped(ScopeRequirementMiddleware(.settingsRead))
            .get(use: index)
    }

    @Sendable
    func index(req: Request) async throws -> BadgesListResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.badgeService.evaluateBadges(
            userId: session.userId,
            req: req,
            on: req.db
        )
    }
}
