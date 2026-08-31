import Foundation
import StockPlanShared
import Vapor

struct MarketDataController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Scoped auth: first-party JWTs pass through untouched; MCP tokens need market:read.
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let market = protected.grouped("market").grouped(ScopeRequirementMiddleware(.marketRead))
        let rateLimited = market.grouped(RateLimitMiddleware(limit: 120, interval: 60, keyPrefix: "ratelimit:market"))

        rateLimited.get("overview", use: overview)
        rateLimited.get("pressure", ":symbol", use: pressure)
        rateLimited.get("returns", "batch", use: periodReturnsBatch)
        rateLimited.get("returns", ":symbol", use: periodReturns)
        rateLimited.get("details", use: details)
        rateLimited.get("history", use: stockHistory)
        rateLimited.get("history", "archive", use: archivedStockHistory)
        rateLimited.post("history", "archive", "sync", use: syncArchivedStockHistory)
        rateLimited.get("news", use: stockNews)
        rateLimited.get("news", "general", use: generalMarketNews)
        rateLimited.get("news", "archive", use: archivedStockNews)
        rateLimited.post("news", "archive", "sync", use: syncArchivedStockNews)
        rateLimited.get("quote", "batch", use: quoteBatch)
        rateLimited.get("quote", ":symbol", use: quote)
        rateLimited.get("profile", ":symbol", use: profile)
        rateLimited.get("basic-financials", ":symbol", use: basicFinancials)
        rateLimited.get("analysis", ":symbol", use: analysis)
        rateLimited.get("compare", use: compare)
        rateLimited.get("cash-flow-statement", ":symbol", use: cashFlowStatement)
        rateLimited.get("income-statement", ":symbol", use: incomeStatement)
        rateLimited.get("balance-sheet-statement", ":symbol", use: balanceSheetStatement)
        rateLimited.get("ratios-ttm", ":symbol", use: ratiosTTM)
        rateLimited.get("grades-consensus", ":symbol", use: gradesConsensus)
        rateLimited.get("financial-growth", ":symbol", use: financialGrowth)
        rateLimited.get("earnings", ":symbol", use: earnings)
        rateLimited.get("earnings", ":symbol", "transcript", use: earningsTranscript)
        rateLimited.get("earnings-calendar", use: earningsCalendar)
        rateLimited.get("analyst-estimates", ":symbol", use: analystEstimates)
        rateLimited.get("ratios", ":symbol", use: ratios)
        rateLimited.get("historical-sector-performance", use: historicalSectorPerformance)
        rateLimited.get("history", ":symbol", use: history)
        rateLimited.get("search", use: search)
        rateLimited.get("fx", use: fx)
        rateLimited.get("price-chart", "compare", use: priceChartComparison)
        rateLimited.get("price-chart", ":symbol", use: priceChart)
        rateLimited.get("chart-builder", "metrics", use: chartBuilderMetrics)
        rateLimited.get("chart-builder", ":symbol", "csv", use: chartBuilderCSV)
        rateLimited.get("chart-builder", ":symbol", use: chartBuilder)
    }

    @Sendable
    func chartBuilderMetrics(req: Request) async throws -> ChartBuilderMetricCatalogResponse {
        _ = try req.auth.require(SessionToken.self)
        return ChartBuilderMetricCatalogResponse.current()
    }

    @Sendable
    func chartBuilder(req: Request) async throws -> ChartBuilderResponse {
        let request = try await authorizedChartBuilderRequest(req: req)
        return try await req.application.chartBuilderService.build(request, on: req)
    }

    @Sendable
    func chartBuilderCSV(req: Request) async throws -> Response {
        let request = try await authorizedChartBuilderRequest(req: req)
        let chart = try await req.application.chartBuilderService.build(request, on: req)
        let csv = DefaultChartBuilderService.makeCSV(response: chart)

        let response = Response(status: .ok, body: .init(data: csv))
        response.headers.replaceOrAdd(name: .contentType, value: "text/csv; charset=utf-8")
        response.headers.replaceOrAdd(
            name: "Content-Disposition",
            value: "attachment; filename=\"\(DefaultChartBuilderService.csvFilename(symbol: request.symbol, period: request.period))\""
        )
        return response
    }

    private func authorizedChartBuilderRequest(req: Request) async throws -> ChartBuilderRequest {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try DefaultChartBuilderService.parseRequest(
            symbol: symbol,
            metricsQuery: req.query[String.self, at: "metrics"],
            periodQuery: req.query[String.self, at: "period"],
            limitQuery: req.query[Int.self, at: "limit"],
            compareQuery: req.query[String.self, at: "compare"]
        )
    }

    @Sendable
    func details(req: Request) async throws -> StockDetailsResponse {
        let symbol = try requireSymbolQuery(req)
        do {
            let quote = try await req.application.marketDataService.quote(symbol: symbol, on: req)
            let company = await resolveCompanyName(for: quote.symbol, on: req)
            let changePercent = await resolveChangePercent(
                for: quote.symbol,
                latestPrice: quote.currentPrice,
                on: req
            )

            return StockDetailsResponse(
                symbol: quote.symbol,
                company: company,
                latestPrice: quote.currentPrice,
                changePercent: changePercent
            )
        } catch is MarketDataProviderDisabledError {
            return zeroedDetails(for: symbol)
        } catch is MarketQuoteUnavailableError {
            // Same graceful degradation as a disabled provider: this endpoint backs a
            // whole screen, so an unpriceable symbol must not fail the entire response.
            // `GET /market/quote/:symbol` still answers 404 for the same case, because
            // there a fabricated 0.00 would be the only thing the caller receives.
            return zeroedDetails(for: symbol)
        }
    }

    private func zeroedDetails(for symbol: String) -> StockDetailsResponse {
        StockDetailsResponse(
            symbol: symbol.uppercased(),
            company: symbol.uppercased(),
            latestPrice: 0,
            changePercent: 0
        )
    }

    @Sendable
    func stockHistory(req: Request) async throws -> [StockHistory] {
        let symbol = try requireSymbolQuery(req)
        do {
            let response = try await req.application.marketDataService.history(
                symbol: symbol,
                from: nil,
                to: nil,
                on: req
            )

            return response.bars
                .sorted { $0.date > $1.date }
                .map {
                    StockHistory(
                        date: $0.date,
                        open: $0.open,
                        high: $0.high,
                        low: $0.low,
                        close: $0.close,
                        volume: $0.volume ?? 0
                    )
                }
        } catch is MarketDataProviderDisabledError {
            return []
        }
    }

    @Sendable
    func archivedStockHistory(req: Request) async throws -> [StockHistory] {
        let symbol = try requireSymbolQuery(req)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        let response = try await req.application.marketDataService.archivedHistory(
            symbol: symbol,
            from: from,
            to: to,
            on: req
        )
        return makeStockHistory(response)
    }

    @Sendable
    func syncArchivedStockHistory(req: Request) async throws -> [StockHistory] {
        let symbol = try requireSymbolQuery(req)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        let response = try await req.application.marketDataService.refreshHistory(
            symbol: symbol,
            from: from,
            to: to,
            on: req
        )
        return makeStockHistory(response)
    }

    @Sendable
    func stockNews(req: Request) async throws -> [StockNews] {
        let symbol = try requireSymbolQuery(req)
        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketNewsArchiveService.news(
            symbol: symbol,
            limit: limit,
            on: req
        )
    }

    @Sendable
    func overview(req: Request) async throws -> MarketOverviewResponse {
        try await req.application.marketDataService.marketOverview(on: req)
    }

    @Sendable
    func pressure(req: Request) async throws -> MarketPressureResponse {
        let symbol = req.parameters.get("symbol") ?? ""
        return try await req.application.marketDataService.marketPressure(symbol: symbol, on: req)
    }

    @Sendable
    func periodReturns(req: Request) async throws -> StockPeriodReturnsResponse {
        guard let symbol = req.parameters.get("symbol"), !symbol.isEmpty else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.periodReturns(symbol: symbol, on: req)
    }

    @Sendable
    func periodReturnsBatch(req: Request) async throws -> StockPeriodReturnsBatchResponse {
        guard let symbols = req.query[String.self, at: "symbols"] else {
            throw Abort(.badRequest, reason: "Missing query parameter `symbols`.")
        }

        let parsed = symbols
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parsed.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }
        guard parsed.count <= PeriodReturnsConfig.batchLimit else {
            throw Abort(
                .badRequest,
                reason: "Period-returns batch supports at most \(PeriodReturnsConfig.batchLimit) symbols."
            )
        }

        return try await req.application.marketDataService.periodReturnsBatch(symbols: parsed, on: req)
    }

    @Sendable
    func generalMarketNews(req: Request) async throws -> [StockNews] {
        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketNewsArchiveService.generalNews(
            limit: limit,
            on: req
        )
    }

    @Sendable
    func archivedStockNews(req: Request) async throws -> [StockNews] {
        let symbol = try requireSymbolQuery(req)
        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketNewsArchiveService.archivedNews(
            symbol: symbol,
            limit: limit,
            on: req.db
        )
    }

    @Sendable
    func syncArchivedStockNews(req: Request) async throws -> [StockNews] {
        let symbol = try requireSymbolQuery(req)
        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketNewsArchiveService.refreshNews(
            symbol: symbol,
            limit: limit,
            on: req
        )
    }

    @Sendable
    func quote(req: Request) async throws -> Response {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        let quote = try await req.application.marketDataService.quote(symbol: symbol, on: req)

        // Caching validators
        let lastModDate = Date(timeIntervalSince1970: quote.timestamp)
        let lastModStr = Self.formatHTTPDate(lastModDate)
        let etag = "W/\"\(symbol)-\(quote.timestamp)\""

        // Conditional GET check
        if let ifNoneMatch = req.headers[.ifNoneMatch].first, ifNoneMatch == etag {
            return Response(status: .notModified)
        }
        if let ifModifiedSince = req.headers[.ifModifiedSince].first,
           let modDate = Self.parseHTTPDate(ifModifiedSince),
           lastModDate <= modDate
        {
            return Response(status: .notModified)
        }

        var response = Response(status: .ok)
        try response.content.encode(quote)
        response.headers.add(name: .lastModified, value: lastModStr)
        response.headers.add(name: .eTag, value: etag)
        response.headers.add(name: .cacheControl, value: "public, max-age=60")
        return response
    }

    @Sendable
    func profile(req: Request) async throws -> Response {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        let profile = try await req.application.marketDataService.profile(symbol: symbol, on: req)

        // Compute weak ETag from profile content (no modification timestamp available)
        var hasher = Hasher()
        hasher.combine(profile.ticker ?? "")
        hasher.combine(profile.name ?? "")
        hasher.combine(profile.marketCapitalization ?? 0)
        hasher.combine(profile.shareOutstanding ?? 0)
        hasher.combine(profile.exchange ?? "")
        hasher.combine(profile.finnhubIndustry ?? "")
        hasher.combine(profile.ipo ?? "")
        hasher.combine(profile.logo ?? "")
        hasher.combine(profile.currency ?? "")
        hasher.combine(profile.country ?? "")
        let hash = hasher.finalize()
        let etag = "W/\"\(symbol)-\(hash)\""

        // Conditional GET
        if let ifNoneMatch = req.headers[.ifNoneMatch].first, ifNoneMatch == etag {
            return Response(status: .notModified)
        }

        var response = Response(status: .ok)
        try response.content.encode(profile)
        response.headers.add(name: .eTag, value: etag)
        response.headers.add(name: .cacheControl, value: "public, max-age=300")
        return response
    }

    @Sendable
    func basicFinancials(req: Request) async throws -> BasicFinancialsResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.basicFinancials(symbol: symbol, on: req)
    }

    @Sendable
    func analysis(req: Request) async throws -> StockAnalysisMetricsResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.analysis(symbol: symbol, on: req)
    }

    @Sendable
    func compare(req: Request) async throws -> [StockAnalysisMetricsResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .peerComparison,
            userId: session.userId,
            on: req.db
        )
        guard let symbolsStr = req.query[String.self, at: "symbols"] else {
            throw Abort(.badRequest, reason: "Missing symbols query parameter.")
        }
        let symbols = symbolsStr
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !symbols.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }
        guard symbols.count <= 10 else {
            throw Abort(.badRequest, reason: "Compare supports at most 10 symbols.")
        }
        return try await req.application.marketDataService.compare(symbols: symbols, on: req)
    }

    @Sendable
    func cashFlowStatement(req: Request) async throws -> [CashFlowStatementResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        let period = req.query[String.self, at: "period"]
        return try await req.application.marketDataService.cashFlowStatement(
            symbol: symbol,
            limit: limit,
            period: period,
            on: req
        )
    }

    @Sendable
    func incomeStatement(req: Request) async throws -> [IncomeStatementResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        let period = req.query[String.self, at: "period"]
        return try await req.application.marketDataService.incomeStatement(
            symbol: symbol,
            limit: limit,
            period: period,
            on: req
        )
    }

    @Sendable
    func balanceSheetStatement(req: Request) async throws -> [BalanceSheetStatementResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        let period = req.query[String.self, at: "period"]
        return try await req.application.marketDataService.balanceSheetStatement(
            symbol: symbol,
            limit: limit,
            period: period,
            on: req
        )
    }

    @Sendable
    func ratiosTTM(req: Request) async throws -> [RatiosTTMResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.ratiosTTM(symbol: symbol, on: req)
    }

    @Sendable
    func gradesConsensus(req: Request) async throws -> [GradesConsensusResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        return try await req.application.marketDataService.gradesConsensus(symbol: symbol, on: req)
    }

    @Sendable
    func financialGrowth(req: Request) async throws -> [FinancialGrowthResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        let period = req.query[String.self, at: "period"]
        return try await req.application.marketDataService.financialGrowth(
            symbol: symbol,
            limit: limit,
            period: period,
            on: req
        )
    }

    @Sendable
    func earnings(req: Request) async throws -> [EarningsResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .earningsText,
            userId: session.userId,
            on: req.db
        )
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        return try await req.application.marketDataService.earnings(
            symbol: symbol,
            limit: limit,
            on: req
        )
    }

    @Sendable
    func earningsCalendar(req: Request) async throws -> [EarningsResponse] {
        // Teaser model: calendar list is free to browse (to surface value).
        // Transcripts + detailed earnings per symbol remain earningsText Pro-gated.
        _ = try req.auth.require(SessionToken.self)
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.marketDataService.earningsCalendar(
            from: from,
            to: to,
            on: req
        )
    }

    @Sendable
    func earningsTranscript(req: Request) async throws -> EarningsTranscriptResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .earningsText,
            userId: session.userId,
            on: req.db
        )
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let date = req.query[String.self, at: "date"]
        let year = req.query[Int.self, at: "year"]
        let quarter = req.query[Int.self, at: "quarter"]
        return try await req.application.marketDataService.earningsTranscript(
            symbol: symbol,
            date: date,
            year: year,
            quarter: quarter,
            on: req
        )
    }

    @Sendable
    func analystEstimates(req: Request) async throws -> [AnalystEstimatesResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let period = req.query[String.self, at: "period"] ?? "annual"
        let page = req.query[Int.self, at: "page"]
        let limit = req.query[Int.self, at: "limit"]

        return try await req.application.marketDataService.analystEstimates(
            symbol: symbol,
            period: period,
            page: page,
            limit: limit,
            on: req
        )
    }

    @Sendable
    func ratios(req: Request) async throws -> [RatiosResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let limit = req.query[Int.self, at: "limit"]
        let period = req.query[String.self, at: "period"]

        return try await req.application.marketDataService.ratios(
            symbol: symbol,
            limit: limit,
            period: period,
            on: req
        )
    }

    @Sendable
    func historicalSectorPerformance(req: Request) async throws -> [HistoricalSectorPerformanceResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireMarketFundamentalsAccess(session: session, req: req)
        guard let sector = req.query[String.self, at: "sector"] else {
            throw Abort(.badRequest, reason: "Missing query parameter `sector`.")
        }

        let exchange = req.query[String.self, at: "exchange"]
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        return try await req.application.marketDataService.historicalSectorPerformance(
            sector: sector,
            exchange: exchange,
            from: from,
            to: to,
            on: req
        )
    }

    @Sendable
    func quoteBatch(req: Request) async throws -> QuoteBatchResponse {
        guard let symbols = req.query[String.self, at: "symbols"] else {
            throw Abort(.badRequest, reason: "Missing query parameter `symbols`.")
        }

        let parsed = symbols
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parsed.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }
        guard parsed.count <= 50 else {
            throw Abort(.badRequest, reason: "Quote batch supports at most 50 symbols.")
        }

        return try await req.application.marketDataService.quoteBatch(symbols: parsed, on: req)
    }

    private func requireMarketFundamentalsAccess(session: SessionToken, req: Request) async throws {
        try await req.usageCounterService.requirePremium(
            .marketFundamentals,
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func history(req: Request) async throws -> Response {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }

        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]
        let history = try await req.application.marketDataService.history(symbol: symbol, from: from, to: to, on: req)

        // Determine latest date from bars (ascending order expected, so last is latest)
        var lastModDate: Date? = nil
        if let lastBar = history.bars.last {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            lastModDate = formatter.date(from: lastBar.date)
        }

        let etagBase = lastModDate.map(\.timeIntervalSince1970) ?? 0
        let etag = "W/\"\(symbol)-\(etagBase)\""
        let lastModStr = lastModDate.map { Self.formatHTTPDate($0) }

        // Conditional GET
        if let ifNoneMatch = req.headers[.ifNoneMatch].first, ifNoneMatch == etag {
            return Response(status: .notModified)
        }
        if let ifModifiedSince = req.headers[.ifModifiedSince].first,
           let modDate = Self.parseHTTPDate(ifModifiedSince),
           let lastMod = lastModDate,
           lastMod <= modDate
        {
            return Response(status: .notModified)
        }

        var response = Response(status: .ok)
        try response.content.encode(history)
        if let lastModStr {
            response.headers.add(name: .lastModified, value: lastModStr)
        }
        response.headers.add(name: .eTag, value: etag)
        response.headers.add(name: .cacheControl, value: "public, max-age=300")
        return response
    }

    @Sendable
    func search(req: Request) async throws -> [SearchResultResponse] {
        guard let query = req.query[String.self, at: "q"] else {
            throw Abort(.badRequest, reason: "Missing query parameter `q`.")
        }
        return try await req.application.marketDataService.search(query: query, on: req)
    }

    @Sendable
    func fx(req: Request) async throws -> FxRateResponse {
        let pair = req.query[String.self, at: "pair"] ?? "EURUSD"
        return try await req.application.marketDataService.fx(pair: pair, on: req)
    }

    private func requireSymbolQuery(_ req: Request) throws -> String {
        guard let symbol = req.query[String.self, at: "symbol"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !symbol.isEmpty
        else {
            throw Abort(.badRequest, reason: "Missing query parameter `symbol`.")
        }
        return symbol
    }

    // MARK: - Price Chart

    @Sendable
    func priceChart(req: Request) async throws -> PriceChartSeries {
        guard let symbol = req.parameters.get("symbol") else {
            throw Abort(.badRequest, reason: "Missing symbol.")
        }
        let range = req.query[String.self, at: "range"] ?? "1D"
        return try await req.application.marketDataService.priceChart(
            symbol: symbol, range: range, on: req
        )
    }

    @Sendable
    func priceChartComparison(req: Request) async throws -> PriceChartComparisonResponse {
        guard let symbolsStr = req.query[String.self, at: "symbols"] else {
            throw Abort(.badRequest, reason: "Missing query parameter `symbols`.")
        }
        let symbols = symbolsStr.split(separator: ",").map(String.init)
        let range = req.query[String.self, at: "range"] ?? "1D"
        return try await req.application.marketDataService.priceChartComparison(
            symbols: symbols, range: range, on: req
        )
    }

    private func resolveCompanyName(for symbol: String, on req: Request) async -> String {
        do {
            let results = try await req.application.marketDataService.search(query: symbol, on: req)
            if let exact = results.first(where: { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }) {
                return exact.name
            }
            return results.first?.name ?? symbol
        } catch {
            req.logger.debug("market.details company fallback symbol=\(symbol) error=\(error.localizedDescription)")
            return symbol
        }
    }

    private func resolveChangePercent(for symbol: String, latestPrice: Double, on req: Request) async -> Double {
        do {
            let response = try await req.application.marketDataService.history(
                symbol: symbol,
                from: nil,
                to: nil,
                on: req
            )
            return calculateChangePercent(latestPrice: latestPrice, bars: response.bars)
        } catch {
            req.logger.debug("market.details change fallback symbol=\(symbol) error=\(error.localizedDescription)")
            return 0
        }
    }

    private func calculateChangePercent(latestPrice: Double, bars: [PriceBarResponse]) -> Double {
        let sorted = bars.sorted { $0.date < $1.date }

        if sorted.count >= 2 {
            let previousClose = sorted[sorted.count - 2].close
            guard previousClose != 0 else { return 0 }
            return (latestPrice - previousClose) / previousClose
        }

        if let latestBar = sorted.last, latestBar.open != 0 {
            return (latestBar.close - latestBar.open) / latestBar.open
        }

        return 0
    }

    private func makeStockHistory(_ response: HistoryResponse) -> [StockHistory] {
        response.bars
            .sorted { $0.date > $1.date }
            .map {
                StockHistory(
                    date: $0.date,
                    open: $0.open,
                    high: $0.high,
                    low: $0.low,
                    close: $0.close,
                    volume: $0.volume ?? 0
                )
            }
    }

    private static func formatHTTPDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private static func parseHTTPDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: string)
    }
}
