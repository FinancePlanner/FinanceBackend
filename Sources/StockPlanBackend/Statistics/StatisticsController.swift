import Vapor

struct StatisticsController: RouteCollection {
    private struct StatisticsQueryParams: Content {
        let period: String?
        let top: Int?
        let benchmark: String?
        let asOf: String?
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped(ScopeRequirementMiddleware(.portfolioRead))
        let statistics = protected.grouped("statistics")
        let stocks = statistics.grouped("stocks")

        stocks.get("scorecard", use: getStockLevelScorecard)
        stocks.get("allocation", use: getStockAllocation)
        stocks.get("sector-allocation", use: getSectorAllocation)
        stocks.get("sector-gains", use: getSectorGains)
        stocks.get("calendar-performance", use: getCalendarPerformance)
        stocks.get("contribution-analysis", use: getContributionAnalysis)
        stocks.get("winners-losers", use: getWinnersVsLosers)
        stocks.get("volatility-snapshot", use: getVolatilitySnapshot)
        stocks.get("currency-split", use: getCurrencySplit)
        stocks.get("scenario-tracking", use: getScenarioTracking)
        stocks.get("notes-quality", use: getNotesQualityMetrics)

        statistics.get("imported-stocks", use: getImportedStocksStatistics)
        statistics.get("watchlist", use: getWatchlistStatistics)
        statistics.get("looklist", use: getLooklistStatistics)
        statistics.get("market", use: getMarketStatistics)
        statistics.get("overview", use: getOverviewStatistics)
    }

    @Sendable
    func getStockLevelScorecard(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.stockLevelScorecard(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getStockAllocation(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.stockAllocation(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getSectorAllocation(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.sectorAllocation(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getSectorGains(req: Request) async throws -> SectorGainsResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.sectorGains(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getCalendarPerformance(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.calendarPerformance(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getContributionAnalysis(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.contributionAnalysis(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getWinnersVsLosers(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.winnersVsLosers(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getVolatilitySnapshot(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.volatilitySnapshot(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getCurrencySplit(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.currencySplit(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getScenarioTracking(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.scenarioTracking(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getNotesQualityMetrics(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.notesQualityMetrics(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getImportedStocksStatistics(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.importedStocksStatistics(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getWatchlistStatistics(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.watchlistStatistics(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getLooklistStatistics(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.looklistStatistics(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getMarketStatistics(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.marketStatistics(userId: session.userId, query: query, on: req.db)
    }

    @Sendable
    func getOverviewStatistics(req: Request) async throws -> StatisticsDTO {
        let session = try req.auth.require(SessionToken.self)
        try await requireStatisticsAccess(session: session, req: req)
        let query = try parseQuery(req)
        return try await req.application.statisticsService.overviewStatistics(userId: session.userId, query: query, on: req.db)
    }

    private func parseQuery(_ req: Request) throws -> StatisticsQueryInput {
        let q = try req.query.decode(StatisticsQueryParams.self)
        return StatisticsQueryInput(
            period: q.period,
            top: q.top,
            benchmark: q.benchmark,
            asOf: q.asOf
        )
    }

    private func requireStatisticsAccess(session: SessionToken, req: Request) async throws {
        try await req.usageCounterService.requirePremium(
            .statistics,
            userId: session.userId,
            on: req.db
        )
    }
}
