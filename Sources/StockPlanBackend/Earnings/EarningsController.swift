import Vapor

struct EarningsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // This makes it /v1/earnings (when registered in api group)
        routes
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped(ScopeRequirementMiddleware(.marketRead))
            .get("earnings", use: getCalendar)
    }

    @Sendable
    func getCalendar(req: Request) async throws -> [EarningsItemResponse] {
        let query = try req.query.decode(EarningsQueryRequest.self)
        return try await req.application.earningsService.getCalendar(query: query, on: req)
    }
}
