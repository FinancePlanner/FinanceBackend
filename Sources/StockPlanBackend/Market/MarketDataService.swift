import Fluent
import Foundation
import Redis
import StockPlanShared
import Vapor

protocol MarketDataService: Sendable {
    var fmpProvider: (any FMPMarketDataProvider)? { get }
    func marketOverview(on req: Request) async throws -> MarketOverviewResponse
    func marketPressure(symbol: String, on req: Request) async throws -> MarketPressureResponse
    func quote(symbol: String, on req: Request) async throws -> QuoteResponse
    func quoteBatch(symbols: [String], on req: Request) async throws -> QuoteBatchResponse
    func history(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> HistoryResponse
    func archivedHistory(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> HistoryResponse
    func refreshHistory(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> HistoryResponse
    func search(query: String, on req: Request) async throws -> [SearchResultResponse]
    func fx(pair: String, on req: Request) async throws -> FxRateResponse
    func profile(symbol: String, on req: Request) async throws -> CompanyProfileResponse
    func basicFinancials(symbol: String, on req: Request) async throws -> BasicFinancialsResponse
    func analysis(symbol: String, on req: Request) async throws -> StockAnalysisMetricsResponse
    func compare(symbols: [String], on req: Request) async throws -> [StockAnalysisMetricsResponse]
    func cashFlowStatement(symbol: String, limit: Int?, period: String?, on req: Request)
        async throws
        -> [CashFlowStatementResponse]
    func incomeStatement(symbol: String, limit: Int?, period: String?, on req: Request)
        async throws
        -> [IncomeStatementResponse]
    func balanceSheetStatement(symbol: String, limit: Int?, period: String?, on req: Request)
        async throws
        -> [BalanceSheetStatementResponse]
    func ratiosTTM(symbol: String, on req: Request) async throws -> [RatiosTTMResponse]
    func gradesConsensus(symbol: String, on req: Request) async throws -> [GradesConsensusResponse]
    func financialGrowth(symbol: String, limit: Int?, period: String?, on req: Request) async throws
        -> [FinancialGrowthResponse]
    func analystEstimates(
        symbol: String,
        period: String,
        page: Int?,
        limit: Int?,
        on req: Request
    ) async throws -> [AnalystEstimatesResponse]
    func ratios(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [RatiosResponse]
    func earnings(
        symbol: String,
        limit: Int?,
        on req: Request
    ) async throws -> [EarningsResponse]
    func earningsCalendar(
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [EarningsResponse]
    func earningsTranscript(
        symbol: String,
        date: String?,
        year: Int?,
        quarter: Int?,
        on req: Request
    ) async throws -> EarningsTranscriptResponse
    func historicalSectorPerformance(
        sector: String,
        exchange: String?,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [HistoricalSectorPerformanceResponse]
    func priceChart(
        symbol: String,
        range: String,
        on req: Request
    ) async throws -> PriceChartSeries
    func priceChartComparison(
        symbols: [String],
        range: String,
        on req: Request
    ) async throws -> PriceChartComparisonResponse
}

struct MarketDataCacheConfig {
    let quoteTTLSeconds: Int
    let historyTTLSeconds: Int
    let searchTTLSeconds: Int
    let fxTTLSeconds: Int
    let profileTTLSeconds: Int
    let basicFinancialsTTLSeconds: Int
    let fmpTTLSeconds: Int
    let defaultCurrency: String

    static func fromEnvironment() -> MarketDataCacheConfig {
        let quoteTTL = Environment.get("MARKET_TTL_QUOTE_SECONDS").flatMap(Int.init(_:)) ?? 20
        let historyTTL =
            Environment.get("MARKET_TTL_HISTORY_SECONDS").flatMap(Int.init(_:)) ?? 86400
        let searchTTL = Environment.get("MARKET_TTL_SEARCH_SECONDS").flatMap(Int.init(_:)) ?? 3600
        let fxTTL = Environment.get("MARKET_TTL_FX_SECONDS").flatMap(Int.init(_:)) ?? 86400
        let profileTTL =
            Environment.get("MARKET_TTL_PROFILE_SECONDS").flatMap(Int.init(_:)) ?? 86400
        let basicFinancialsTTL =
            Environment.get("MARKET_TTL_BASIC_FINANCIALS_SECONDS").flatMap(Int.init(_:)) ?? 86400
        let fmpTTL = Environment.get("MARKET_TTL_FMP_SECONDS").flatMap(Int.init(_:)) ?? 86400
        let currency = Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD"

        return .init(
            quoteTTLSeconds: max(1, quoteTTL),
            historyTTLSeconds: max(60, historyTTL),
            searchTTLSeconds: max(60, searchTTL),
            fxTTLSeconds: max(60, fxTTL),
            profileTTLSeconds: max(60, profileTTL),
            basicFinancialsTTLSeconds: max(60, basicFinancialsTTL),
            fmpTTLSeconds: max(60, fmpTTL),
            defaultCurrency: currency.uppercased()
        )
    }
}

enum FMPAccessTier: String {
    case free
    case starter
    case premium

    static func fromEnvironment() -> FMPAccessTier {
        let rawValue = Environment.get("FMP_SYMBOL_ACCESS_TIER")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return FMPAccessTier(rawValue: rawValue ?? "") ?? .free
    }

    var allowsAllSymbols: Bool {
        switch self {
        case .free:
            false
        case .starter, .premium:
            true
        }
    }
}

enum FMPSymbolPlanAccess {
    static let freeTierSupportedSymbols: Set<String> = [
        "AAPL", "TSLA", "AMZN", "MSFT", "NVDA", "GOOGL", "META", "NFLX", "JPM", "V",
        "BAC", "PYPL", "DIS", "T", "PFE", "COST", "INTC", "KO", "TGT", "NKE",
        "SPY", "BA", "BABA", "XOM", "WMT", "GE", "CSCO", "VZ", "JNJ", "CVX",
        "PLTR", "SQ", "SHOP", "SBUX", "SOFI", "HOOD", "RBLX", "SNAP", "AMD", "UBER",
        "FDX", "ABBV", "ETSY", "MRNA", "LMT", "GM", "F", "LCID", "CCL", "DAL",
        "UAL", "AAL", "TSM", "SONY", "ET", "MRO", "COIN", "RIVN", "RIOT", "CPRX",
        "VWO", "SPYG", "NOK", "ROKU", "VIAC", "ATVI", "BIDU", "DOCU", "ZM", "PINS",
        "TLRY", "WBA", "MGM", "NIO", "C", "GS", "WFC", "ADBE", "PEP", "UNH",
        "CARR", "HCA", "TWTR", "BILI", "SIRI", "FUBO", "RKT",
    ]

    static func isSupportedOnFreeTier(_ symbol: String) -> Bool {
        freeTierSupportedSymbols.contains(symbol.uppercased())
    }
}

// swiftlint:disable type_body_length
struct DefaultMarketDataService: MarketDataService {
    let provider: any MarketDataProvider
    let fmpProvider: (any FMPMarketDataProvider)?
    let cacheConfig: MarketDataCacheConfig
    let fmpAccessTier: FMPAccessTier
    /// Collapses concurrent cache-miss fetches per symbol into one upstream
    /// call (application-scoped; the service lives in Application.storage).
    let basicFinancialsInFlight = InFlightFetchCoordinator<BasicFinancialsResponse>()

    init(
        provider: any MarketDataProvider,
        fmpProvider: (any FMPMarketDataProvider)? = nil,
        cacheConfig: MarketDataCacheConfig,
        fmpAccessTier: FMPAccessTier = .fromEnvironment()
    ) {
        self.provider = provider
        self.fmpProvider = fmpProvider
        self.cacheConfig = cacheConfig
        self.fmpAccessTier = fmpAccessTier
    }

    func quote(symbol rawSymbol: String, on req: Request) async throws -> QuoteResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let now = Date()
        let providerName = provider.name
        let redisKey = makeQuoteRedisKey(provider: providerName, symbol: symbol)

        if let hotCached: QuoteResponse = await redisGetValue(
            redisKey, as: QuoteResponse.self, on: req
        ) {
            return hotCached
        }

        let existing = try await QuoteCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .first()

        if let existing, isFresh(existing.asOf, ttlSeconds: cacheConfig.quoteTTLSeconds, now: now) {
            let response = makeQuoteResponse(from: existing)
            await redisSetValue(
                redisKey, value: response, ttlSeconds: cacheConfig.quoteTTLSeconds, on: req
            )
            return response
        }

        do {
            let fresh = try await provider.quote(symbol: symbol, on: req)
            let cache = try await upsertQuoteCache(fresh, provider: providerName, on: req.db)
            let response = makeQuoteResponse(from: cache)
            await redisSetValue(
                redisKey, value: response, ttlSeconds: cacheConfig.quoteTTLSeconds, on: req
            )
            return response
        } catch {
            if let existing {
                req.logger.warning(
                    "market.quote stale fallback symbol=\(symbol) provider=\(providerName)"
                )
                let response = makeQuoteResponse(from: existing)
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.quoteTTLSeconds, on: req
                )
                return response
            }
            throw mapProviderError(error, operation: "quote")
        }
    }

    func quoteBatch(symbols rawSymbols: [String], on req: Request) async throws
        -> QuoteBatchResponse
    {
        var seen: Set<String> = []
        let normalized =
            try rawSymbols
                .map(normalizeSymbol)
                .filter { seen.insert($0).inserted }

        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }

        guard normalized.count <= 100 else {
            throw Abort(.badRequest, reason: "Maximum 100 symbols per batch request.")
        }

        var indexedQuotes: [(Int, QuoteResponse)] = []
        indexedQuotes.reserveCapacity(normalized.count)
        let application = req.application

        for chunkStart in stride(from: 0, to: normalized.count, by: 10) {
            let chunkEnd = min(chunkStart + 10, normalized.count)
            let chunk = Array(normalized[chunkStart ..< chunkEnd])
            let chunkResults = try await withThrowingTaskGroup(of: (Int, QuoteResponse).self) { group in
                for (offset, symbol) in chunk.enumerated() {
                    let index = chunkStart + offset
                    group.addTask {
                        let childRequest = Request(
                            application: application,
                            on: application.eventLoopGroup.next()
                        )
                        return try await (index, quote(symbol: symbol, on: childRequest))
                    }
                }

                var results: [(Int, QuoteResponse)] = []
                results.reserveCapacity(chunk.count)
                for try await result in group {
                    results.append(result)
                }
                return results
            }
            indexedQuotes.append(contentsOf: chunkResults)
        }

        let quotes = indexedQuotes
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        return QuoteBatchResponse(quotes: quotes)
    }

    func history(
        symbol rawSymbol: String, from rawFrom: String?, to rawTo: String?, on req: Request
    ) async throws -> HistoryResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let fromDate = try parseOptionalDateOnly(rawFrom, field: "from")
        let toDate = try parseOptionalDateOnly(rawTo, field: "to")
        let now = Date()
        let redisKey = makeHistoryRedisKey(
            provider: provider.name,
            symbol: symbol,
            from: fromDate,
            to: toDate
        )

        if let fromDate, let toDate, fromDate > toDate {
            throw Abort(.badRequest, reason: "`from` must be on or before `to`.")
        }

        if let hotCached: HistoryResponse = await redisGetValue(
            redisKey, as: HistoryResponse.self, on: req
        ) {
            return hotCached
        }

        let cachedBars = try await loadCachedHistory(
            symbol: symbol, from: fromDate, to: toDate, on: req.db
        )
        if isHistoryFresh(cachedBars, now: now) {
            let response = HistoryResponse(
                symbol: symbol,
                currency: cacheConfig.defaultCurrency,
                bars: cachedBars.map(makePriceBarResponse)
            )
            await redisSetValue(
                redisKey, value: response, ttlSeconds: cacheConfig.historyTTLSeconds, on: req
            )
            return response
        }

        do {
            let fresh = try await provider.history(
                symbol: symbol, from: fromDate, to: toDate, on: req
            )
            try await upsertHistoryBars(
                symbol: symbol, currency: fresh.currency, provider: provider.name,
                bars: fresh.bars, on: req.db
            )
            let merged = try await loadCachedHistory(
                symbol: symbol, from: fromDate, to: toDate, on: req.db
            )

            let responseBars =
                merged.isEmpty
                    ? fresh.bars.map { makePriceHistoryModel(symbol: symbol, from: $0) }
                    : merged
            let response = HistoryResponse(
                symbol: symbol,
                currency: fresh.currency,
                bars: responseBars.map(makePriceBarResponse)
            )
            await redisSetValue(
                redisKey, value: response, ttlSeconds: cacheConfig.historyTTLSeconds, on: req
            )
            return response
        } catch {
            if !cachedBars.isEmpty {
                req.logger.warning(
                    "market.history stale fallback symbol=\(symbol) provider=\(provider.name)"
                )
                let response = HistoryResponse(
                    symbol: symbol,
                    currency: cacheConfig.defaultCurrency,
                    bars: cachedBars.map(makePriceBarResponse)
                )
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.historyTTLSeconds, on: req
                )
                return response
            }
            throw mapProviderError(error, operation: "history")
        }
    }

    func archivedHistory(
        symbol rawSymbol: String, from rawFrom: String?, to rawTo: String?, on req: Request
    ) async throws -> HistoryResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let (fromDate, toDate) = try parseHistoryRange(from: rawFrom, to: rawTo)
        let cachedBars = try await loadCachedHistory(
            symbol: symbol, from: fromDate, to: toDate, on: req.db
        )

        return HistoryResponse(
            symbol: symbol,
            currency: cacheConfig.defaultCurrency,
            bars: cachedBars.map(makePriceBarResponse)
        )
    }

    func refreshHistory(
        symbol rawSymbol: String, from rawFrom: String?, to rawTo: String?, on req: Request
    ) async throws -> HistoryResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let (fromDate, toDate) = try parseHistoryRange(from: rawFrom, to: rawTo)
        let fresh = try await provider.history(symbol: symbol, from: fromDate, to: toDate, on: req)

        try await upsertHistoryBars(
            symbol: symbol, currency: fresh.currency, provider: provider.name,
            bars: fresh.bars, on: req.db
        )
        let archivedBars = try await loadCachedHistory(
            symbol: symbol, from: fromDate, to: toDate, on: req.db
        )
        let responseBars =
            archivedBars.isEmpty
                ? fresh.bars.map { makePriceHistoryModel(symbol: symbol, from: $0) }
                : archivedBars

        return HistoryResponse(
            symbol: symbol,
            currency: fresh.currency,
            bars: responseBars.map(makePriceBarResponse)
        )
    }

    func search(query rawQuery: String, on req: Request) async throws -> [SearchResultResponse] {
        let query = try normalizeQuery(rawQuery)
        let now = Date()
        let providerName = provider.name
        let redisKey = makeSearchRedisKey(provider: providerName, query: query)

        if let hotCached: [SearchResultResponse] = await redisGetValue(
            redisKey, as: [SearchResultResponse].self, on: req
        ) {
            return hotCached
        }

        let existing = try await SearchCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$normalizedQuery == query)
            .first()

        if let existing,
           isFresh(
               existing.updatedAt ?? existing.createdAt, ttlSeconds: cacheConfig.searchTTLSeconds,
               now: now
           ),
           let cachedResults = decodeSearchPayload(existing.payload)
        {
            await redisSetValue(
                redisKey, value: cachedResults, ttlSeconds: cacheConfig.searchTTLSeconds, on: req
            )
            return cachedResults
        }

        do {
            let fresh = try await provider.search(query: query, on: req)
            let mapped = fresh.map {
                SearchResultResponse(
                    symbol: $0.symbol,
                    name: $0.name,
                    exchange: $0.exchange,
                    currency: $0.currency,
                    conid: $0.conid
                )
            }

            let payload = try JSONEncoder().encode(mapped)
            let payloadString = String(decoding: payload, as: UTF8.self)
            _ = try await upsertSearchCache(
                query: query,
                provider: providerName,
                payload: payloadString,
                on: req.db
            )
            await redisSetValue(
                redisKey, value: mapped, ttlSeconds: cacheConfig.searchTTLSeconds, on: req
            )
            return mapped
        } catch {
            if let existing, let cachedResults = decodeSearchPayload(existing.payload) {
                req.logger.warning(
                    "market.search stale fallback query=\(query) provider=\(providerName)"
                )
                await redisSetValue(
                    redisKey, value: cachedResults, ttlSeconds: cacheConfig.searchTTLSeconds,
                    on: req
                )
                return cachedResults
            }
            throw mapProviderError(error, operation: "search")
        }
    }

    func fx(pair rawPair: String, on req: Request) async throws -> FxRateResponse {
        let (base, quote) = try normalizePair(rawPair)
        let now = Date()
        let redisKey = makeFxRedisKey(provider: provider.name, base: base, quote: quote)

        if let hotCached: FxRateResponse = await redisGetValue(
            redisKey, as: FxRateResponse.self, on: req
        ) {
            return hotCached
        }

        let existing = try await FxRate.query(on: req.db)
            .filter(\.$base == base)
            .filter(\.$quote == quote)
            .sort(\.$date, .descending)
            .first()

        if let existing, isFresh(existing.date, ttlSeconds: cacheConfig.fxTTLSeconds, now: now) {
            let response = makeFxResponse(from: existing)
            await redisSetValue(
                redisKey, value: response, ttlSeconds: cacheConfig.fxTTLSeconds, on: req
            )
            return response
        }

        do {
            let fresh = try await provider.fx(base: base, quote: quote, on: req)
            let cached = try await upsertFxRate(fresh, on: req.db)
            let response = makeFxResponse(from: cached)
            await redisSetValue(
                redisKey, value: response, ttlSeconds: cacheConfig.fxTTLSeconds, on: req
            )
            return response
        } catch {
            if let existing {
                req.logger.warning(
                    "market.fx stale fallback pair=\(base)\(quote) provider=\(provider.name)"
                )
                let response = makeFxResponse(from: existing)
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.fxTTLSeconds, on: req
                )
                return response
            }
            throw mapProviderError(error, operation: "fx")
        }
    }

    func profile(symbol rawSymbol: String, on req: Request) async throws -> CompanyProfileResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let now = Date()
        let providerName = provider.name
        let redisKey = makeProfileRedisKey(provider: providerName, symbol: symbol)

        if let hotCached: CompanyProfileResponse = await redisGetValue(
            redisKey, as: CompanyProfileResponse.self, on: req
        ) {
            return hotCached
        }

        let existing = try await ProfileCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .first()

        if let existing,
           isFresh(
               existing.updatedAt ?? existing.createdAt ?? .distantPast,
               ttlSeconds: cacheConfig.profileTTLSeconds, now: now
           )
        {
            let response = makeProfileResponse(from: existing)
            await redisSetValue(
                redisKey, value: response, ttlSeconds: cacheConfig.profileTTLSeconds, on: req
            )
            return response
        }

        do {
            guard let fresh = try await provider.profile(symbol: symbol, on: req) else {
                throw Abort(.notFound, reason: "Profile not found for \(symbol).")
            }
            let cached = try await upsertProfileCache(fresh, provider: providerName, on: req.db)
            let response = makeProfileResponse(from: cached)
            await redisSetValue(
                redisKey, value: response, ttlSeconds: cacheConfig.profileTTLSeconds, on: req
            )
            return response
        } catch {
            if let existing {
                req.logger.warning(
                    "market.profile stale fallback symbol=\(symbol) provider=\(providerName)"
                )
                let response = makeProfileResponse(from: existing)
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.profileTTLSeconds, on: req
                )
                return response
            }
            throw mapProviderError(error, operation: "profile")
        }
    }

    func basicFinancials(symbol rawSymbol: String, on req: Request) async throws
        -> BasicFinancialsResponse
    {
        let symbol = try normalizeSymbol(rawSymbol)
        let now = Date()
        let providerName = provider.name
        let redisKey = makeBasicFinancialsRedisKey(provider: providerName, symbol: symbol)

        if let hotCached: BasicFinancialsResponse = await redisGetValue(
            redisKey, as: BasicFinancialsResponse.self, on: req
        ) {
            return hotCached
        }

        let existing: BasicFinancialsCache?
        do {
            existing = try await BasicFinancialsCache.query(on: req.db)
                .filter(\.$provider == providerName)
                .filter(\.$symbol == symbol)
                .first()
        } catch {
            if isMissingDatabaseRelationError(error, relation: BasicFinancialsCache.schema) {
                req.logger.warning(
                    "market.basic-financials cache bypassed because relation \(BasicFinancialsCache.schema) is missing"
                )
                existing = nil
            } else {
                throw error
            }
        }

        if let existing,
           isFresh(
               existing.updatedAt ?? existing.createdAt ?? .distantPast,
               ttlSeconds: cacheConfig.basicFinancialsTTLSeconds, now: now
           ),
           let cached = decodeBasicFinancialsPayload(existing.payload)
        {
            await redisSetValue(
                redisKey, value: cached, ttlSeconds: cacheConfig.basicFinancialsTTLSeconds, on: req
            )
            return cached
        }

        do {
            // Collapse concurrent cache misses for the same symbol into one
            // upstream call: the first request leads, the rest await its result.
            let dedupKey = "\(providerName):\(symbol)"
            if let shared = try await basicFinancialsInFlight.joinOrLead(key: dedupKey) {
                return shared
            }
            do {
                let fresh = try await fetchAndCacheBasicFinancials(
                    symbol: symbol, providerName: providerName, redisKey: redisKey, on: req
                )
                await basicFinancialsInFlight.complete(key: dedupKey, result: .success(fresh))
                return fresh
            } catch {
                await basicFinancialsInFlight.complete(key: dedupKey, result: .failure(error))
                throw error
            }
        } catch {
            if let existing, let cached = decodeBasicFinancialsPayload(existing.payload) {
                req.logger.warning(
                    "market.basic-financials stale fallback symbol=\(symbol) provider=\(providerName)"
                )
                await redisSetValue(
                    redisKey, value: cached, ttlSeconds: cacheConfig.basicFinancialsTTLSeconds,
                    on: req
                )
                return cached
            }
            throw mapProviderError(error, operation: "basic financials")
        }
    }

    // fetchAndCacheBasicFinancials lives in MarketDataProviderRateLimitedError.swift
    // (same-module extension) to keep this file under the SwiftLint length cap.

    func analysis(symbol rawSymbol: String, on req: Request) async throws
        -> StockAnalysisMetricsResponse
    {
        let symbol = try normalizeSymbol(rawSymbol)
        try validateFMPSymbolAccess(symbol: symbol, operation: "analysis")

        req.logger.debug("market.analysis starting symbol=\(symbol)")

        let basic: BasicFinancialsResponse
        do {
            basic = try await basicFinancials(symbol: symbol, on: req)
        } catch {
            req.logger.error(
                "market.analysis basicFinancials failed symbol=\(symbol) error=\(error)"
            )
            throw error
        }

        let ratios: [RatiosTTMResponse]
        do {
            ratios = try await ratiosTTM(symbol: symbol, on: req)
        } catch {
            req.logger.error("market.analysis ratiosTTM failed symbol=\(symbol) error=\(error)")
            throw error
        }

        let growth: [FinancialGrowthResponse]
        do {
            growth = try await financialGrowth(symbol: symbol, limit: 5, period: "FY", on: req)
        } catch {
            req.logger.error(
                "market.analysis financialGrowth failed symbol=\(symbol) error=\(error)"
            )
            throw error
        }

        req.logger.debug("market.analysis data fetch complete symbol=\(symbol)")

        let latestRatio = ratios.first
        let sortedGrowth = growth.sorted { $0.date > $1.date }
        let latestGrowth = sortedGrowth.first
        let priorGrowth = sortedGrowth.dropFirst().first

        let ttmPE =
            latestRatio?.priceToEarningsRatioTTM
                ?? metricDouble("peTTM", in: basic)
                ?? metricDouble("peBasicExclExtraTTM", in: basic)
                ?? metricDouble("peExclExtraTTM", in: basic)
                ?? metricDouble("peAnnual", in: basic)

        let forwardPE = metricDouble("forwardPE", in: basic)
        let ttmEPSGrowth = metricPercent("epsGrowthTTMYoy", in: basic) ?? latestGrowth?.epsgrowth
        let currentYearExpectedEPSGrowth =
            impliedForwardGrowth(ttmPE: ttmPE, forwardPE: forwardPE)
                ?? latestGrowth?.epsgrowth
        let nextYearEPSGrowth = priorGrowth?.epsgrowth ?? latestGrowth?.epsgrowth
        let ttmRevenueGrowth =
            metricPercent("revenueGrowthTTMYoy", in: basic) ?? latestGrowth?.revenueGrowth
        let currentYearExpectedRevenueGrowth = latestGrowth?.revenueGrowth ?? ttmRevenueGrowth
        let nextYearRevenueGrowth = priorGrowth?.revenueGrowth ?? latestGrowth?.revenueGrowth
        let grossMargin =
            latestRatio?.grossProfitMarginTTM
                ?? metricPercent("grossMarginTTM", in: basic)
                ?? metricPercent("grossMarginAnnual", in: basic)
                ?? latestSeriesValue(frequency: "quarterly", metric: "grossMargin", in: basic)
                ?? latestSeriesValue(frequency: "annual", metric: "grossMargin", in: basic)
        let netMargin =
            latestRatio?.netProfitMarginTTM
                ?? metricPercent("netProfitMarginTTM", in: basic)
                ?? metricPercent("netProfitMarginAnnual", in: basic)
                ?? latestSeriesValue(frequency: "quarterly", metric: "netMargin", in: basic)
                ?? latestSeriesValue(frequency: "annual", metric: "netMargin", in: basic)

        // DCF Data Fetching
        async let quoteTask = try? quote(symbol: symbol, on: req)
        async let profileTask = try? profile(symbol: symbol, on: req)
        async let balanceSheetTask = try? balanceSheetStatement(
            symbol: symbol, limit: 1, period: "FY", on: req
        )

        let currentQuote = await quoteTask
        let companyProfile = await profileTask
        let latestBalanceSheet = await balanceSheetTask?.first

        let currentPrice = currentQuote?.currentPrice
        let sharesMillions = companyProfile?.shareOutstanding
        let sharesOutstanding = sharesMillions.map { $0 * 1_000_000 }
        let marketCap = currentPrice.flatMap { p in sharesOutstanding.map { s in p * s } }

        let shortTermDebt = latestBalanceSheet?.shortTermDebt ?? 0
        let longTermDebt = latestBalanceSheet?.longTermDebt ?? 0
        let cashAndEquivalents = latestBalanceSheet?.cashAndCashEquivalents ?? 0
        let netDebt = (shortTermDebt + longTermDebt) - cashAndEquivalents

        let ttmRevenueBase = metricDouble("revenueTTM", in: basic) ?? 0
        let ttmRevenue: Double = if ttmRevenueBase > 0 {
            ttmRevenueBase * 1_000_000
        } else if let mCap = marketCap, let pe = ttmPE, pe > 0, let margin = netMargin, margin > 0 {
            (mCap / pe) / margin
        } else {
            0
        }

        let ttmNetIncome = ttmRevenue * (netMargin ?? 0.1)

        let wacc = req.query[Double.self, at: "wacc"] ?? 0.09
        let terminalGrowthRate = req.query[Double.self, at: "terminalGrowthRate"] ?? 0.025
        let terminalMargin = req.query[Double.self, at: "terminalMargin"] ?? 0.22

        let safeRevenueGrowth1 = currentYearExpectedRevenueGrowth ?? ttmRevenueGrowth ?? 0.1
        let safeRevenueGrowth2 = nextYearRevenueGrowth ?? safeRevenueGrowth1
        let safeEPSGrowth1 = currentYearExpectedEPSGrowth ?? ttmEPSGrowth ?? 0.1
        let safeEPSGrowth2 = nextYearEPSGrowth ?? safeEPSGrowth1
        let fcfMarginAssumption = req.query[Double.self, at: "fcfMarginAssumption"] ?? 1.0

        let currentYear = Calendar.current.component(.year, from: Date())
        let finalNetMargin = netMargin

        let buildProjections: (Double) -> [YearlyProjectionResponse] = { growthShift in
            var projections: [YearlyProjectionResponse] = []
            var currentRev = ttmRevenue
            var currentNetInc = ttmNetIncome

            for i in 1 ... 5 {
                let revGrowth: Double
                let niGrowth: Double
                if i == 1 {
                    revGrowth = safeRevenueGrowth1 + growthShift
                    niGrowth = safeEPSGrowth1 + growthShift
                } else if i == 2 {
                    revGrowth = safeRevenueGrowth2 + growthShift
                    niGrowth = safeEPSGrowth2 + growthShift
                } else {
                    let prevRevGrowth = projections.last!.revenueGrowth
                    revGrowth = max(prevRevGrowth - 0.03, terminalGrowthRate)
                    niGrowth = max(projections.last!.netIncomeGrowth - 0.05, terminalGrowthRate)
                }

                currentRev = currentRev * (1 + revGrowth)
                currentNetInc = currentNetInc * (1 + niGrowth)

                let baseMargin = finalNetMargin ?? 0.1
                let marginStep = (terminalMargin - baseMargin) / 5.0
                let targetMargin = baseMargin + marginStep * Double(i)

                let actualNetInc = currentRev * targetMargin
                let fcf = actualNetInc * fcfMarginAssumption

                let actualEps: Double = if let shares = sharesOutstanding, shares > 0 {
                    actualNetInc / shares
                } else {
                    0
                }

                projections.append(
                    YearlyProjectionResponse(
                        year: currentYear + i,
                        revenue: currentRev,
                        revenueGrowth: revGrowth,
                        netIncome: actualNetInc,
                        netIncomeGrowth: niGrowth,
                        netMargin: targetMargin,
                        eps: actualEps,
                        fcf: fcf,
                        fcfMargin: targetMargin * fcfMarginAssumption
                    )
                )
            }
            return projections
        }

        var baseProjections: [YearlyProjectionResponse]?
        var dcfBasePrice: Double?
        var dcfBearPrice: Double?
        var dcfBullPrice: Double?

        if ttmRevenue > 0 {
            let base = buildProjections(0)
            let bear = buildProjections(-0.03)
            let bull = buildProjections(0.03)

            baseProjections = base

            dcfBasePrice = Self.calculateDCFPrice(
                projections: base,
                sharesOutstanding: sharesOutstanding,
                wacc: wacc,
                terminalGrowthRate: terminalGrowthRate,
                netDebt: netDebt
            )
            dcfBearPrice = Self.calculateDCFPrice(
                projections: bear,
                sharesOutstanding: sharesOutstanding,
                wacc: wacc,
                terminalGrowthRate: terminalGrowthRate,
                netDebt: netDebt
            )
            dcfBullPrice = Self.calculateDCFPrice(
                projections: bull,
                sharesOutstanding: sharesOutstanding,
                wacc: wacc,
                terminalGrowthRate: terminalGrowthRate,
                netDebt: netDebt
            )
        }

        return StockAnalysisMetricsResponse(
            symbol: symbol,
            ttmPE: ttmPE,
            forwardPE: forwardPE,
            twoYearForwardPE: twoYearForwardPE(
                forwardPE: forwardPE, nextYearEPSGrowth: nextYearEPSGrowth
            ),
            ttmEPSGrowth: ttmEPSGrowth,
            currentYearExpectedEPSGrowth: currentYearExpectedEPSGrowth,
            nextYearEPSGrowth: nextYearEPSGrowth,
            ttmRevenueGrowth: ttmRevenueGrowth,
            currentYearExpectedRevenueGrowth: currentYearExpectedRevenueGrowth,
            nextYearRevenueGrowth: nextYearRevenueGrowth,
            grossMargin: grossMargin,
            netMargin: finalNetMargin,
            ttmPEGRatio: latestRatio?.priceToEarningsGrowthRatioTTM,
            lastYearEPSGrowth: priorGrowth?.epsgrowth,
            ttmVsNTMEPSGrowth: delta(lhs: currentYearExpectedEPSGrowth, rhs: ttmEPSGrowth),
            currentQuarterEPSGrowthVsPreviousYear: metricPercent(
                "epsGrowthQuarterlyYoy", in: basic
            ),
            twoYearStackExpectedEPSGrowth: stackedGrowth(
                first: currentYearExpectedEPSGrowth, second: nextYearEPSGrowth
            ),
            lastYearRevenueGrowth: priorGrowth?.revenueGrowth,
            ttmVsNTMRevenueGrowth: delta(
                lhs: currentYearExpectedRevenueGrowth, rhs: ttmRevenueGrowth
            ),
            currentQuarterRevenueGrowthVsPreviousYear: metricPercent(
                "revenueGrowthQuarterlyYoy", in: basic
            ),
            twoYearStackExpectedRevenueGrowth: stackedGrowth(
                first: currentYearExpectedRevenueGrowth,
                second: nextYearRevenueGrowth
            ),
            currentPrice: currentPrice,
            marketCap: marketCap,
            sharesOutstanding: sharesOutstanding,
            baseYear: currentYear,
            yearlyProjections: baseProjections,
            wacc: wacc,
            terminalGrowthRate: terminalGrowthRate,
            terminalMargin: terminalMargin,
            exitPELow: nil,
            exitPEHigh: nil,
            dcfBasePrice: dcfBasePrice,
            dcfBearPrice: dcfBearPrice,
            dcfBullPrice: dcfBullPrice,
            netDebt: netDebt
        )
    }

    func compare(symbols: [String], on req: Request) async throws -> [StockAnalysisMetricsResponse] {
        let uniqueSymbols = Array(Set(symbols)).prefix(3)
        guard !uniqueSymbols.isEmpty else { return [] }

        var results: [StockAnalysisMetricsResponse] = []
        for symbol in uniqueSymbols {
            if let result = try? await analysis(symbol: symbol, on: req) {
                results.append(result)
            }
        }
        return results
    }

    // MARK: - Price Chart

    func priceChart(
        symbol rawSymbol: String,
        range rawRange: String,
        on req: Request
    ) async throws -> PriceChartSeries {
        let symbol = try normalizeSymbol(rawSymbol)
        let range = rawRange.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard let chartRange = PriceChartRange(rawValue: range) else {
            throw Abort(.badRequest, reason: "Invalid range '\(rawRange)'. Allowed: 1H, 1D, 1W, 1M, 3M, 1Y, 5Y.")
        }

        let fmp = try requireFMPProvider()
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)

        do {
            switch chartRange {
            case .oneHour, .oneDay, .oneWeek:
                let (interval, fromDate) = intradayConfig(for: chartRange, now: now, calendar: calendar)
                let fromStr = formatISODateTime(fromDate)
                let toStr = formatISODateTime(now)
                let points = try await fmp.stockIntraday(
                    interval: interval, symbol: symbol, from: fromStr, to: toStr, on: req
                )
                return mapIntradayToPriceChart(symbol: symbol, range: range, points: points)

            case .oneMonth, .threeMonths, .oneYear, .fiveYears:
                return try await fetchEODChart(
                    fmp: fmp, symbol: symbol, range: range, chartRange: chartRange,
                    now: now, calendar: calendar, on: req
                )
            }
        } catch let error as Abort where error.status == .paymentRequired {
            // Fallback: intraday not available on this FMP plan, use daily data instead
            req.logger.info("market.price-chart intraday fallback to EOD symbol=\(symbol) range=\(range)")
            let fallbackRange: PriceChartRange = chartRange == .oneHour ? .oneDay : chartRange
            return try await fetchEODChart(
                fmp: fmp, symbol: symbol, range: range, chartRange: fallbackRange,
                now: now, calendar: calendar, on: req
            )
        }
    }

    func priceChartComparison(
        symbols rawSymbols: [String],
        range: String,
        on req: Request
    ) async throws -> PriceChartComparisonResponse {
        var seen: Set<String> = []
        let normalized = try rawSymbols
            .map(normalizeSymbol)
            .filter { seen.insert($0).inserted }

        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }
        guard normalized.count <= 5 else {
            throw Abort(.badRequest, reason: "Maximum 5 symbols per comparison.")
        }

        var seriesList: [PriceChartSeries] = []
        for symbol in normalized {
            do {
                let series = try await priceChart(symbol: symbol, range: range, on: req)
                seriesList.append(series)
            } catch {
                req.logger.warning("market.price-chart-compare skipped symbol=\(symbol) error=\(error.localizedDescription)")
            }
        }

        return PriceChartComparisonResponse(series: seriesList, range: range)
    }

    private func intradayConfig(
        for range: PriceChartRange,
        now: Date,
        calendar: Calendar
    ) -> (interval: String, from: Date) {
        switch range {
        case .oneHour:
            ("1min", calendar.date(byAdding: .hour, value: -1, to: now) ?? now)
        case .oneDay:
            ("5min", calendar.date(byAdding: .day, value: -1, to: now) ?? now)
        case .oneWeek:
            ("1hour", calendar.date(byAdding: .day, value: -7, to: now) ?? now)
        default:
            ("1hour", now)
        }
    }

    private func fetchEODChart(
        fmp: any FMPMarketDataProvider,
        symbol: String,
        range: String,
        chartRange: PriceChartRange,
        now: Date,
        calendar: Calendar,
        on req: Request
    ) async throws -> PriceChartSeries {
        let fromDate: Date = switch chartRange {
        case .oneHour, .oneDay:
            calendar.date(byAdding: .day, value: -1, to: now) ?? now
        case .oneWeek:
            calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .oneMonth:
            calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths:
            calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .oneYear:
            calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .fiveYears:
            calendar.date(byAdding: .year, value: -5, to: now) ?? now
        }

        let fromStr = formatISODateOnly(fromDate)
        let toStr = formatISODateOnly(now)
        let points = try await fmp.stockHistoricalEOD(
            symbol: symbol, from: fromStr, to: toStr, on: req
        )
        return mapEODToPriceChart(symbol: symbol, range: range, points: points)
    }

    private func mapIntradayToPriceChart(
        symbol: String,
        range: String,
        points: [CryptoHistoricalPoint]
    ) -> PriceChartSeries {
        let sorted = points.sorted { $0.date < $1.date }
        return PriceChartSeries(
            symbol: symbol,
            currency: cacheConfig.defaultCurrency,
            range: range,
            points: sorted.map {
                PriceChartPoint(
                    date: $0.date,
                    close: $0.close,
                    open: $0.open,
                    high: $0.high,
                    low: $0.low,
                    volume: $0.volume.map { Int($0) }
                )
            }
        )
    }

    private func mapEODToPriceChart(
        symbol: String,
        range: String,
        points: [CryptoHistoricalLightPoint]
    ) -> PriceChartSeries {
        let sorted = points.sorted { $0.date < $1.date }
        return PriceChartSeries(
            symbol: symbol,
            currency: cacheConfig.defaultCurrency,
            range: range,
            points: sorted.map {
                PriceChartPoint(
                    date: $0.date,
                    close: $0.price,
                    open: nil,
                    high: nil,
                    low: nil,
                    volume: $0.volume.map { Int($0) }
                )
            }
        )
    }

    func balanceSheetStatement(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [BalanceSheetStatementResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizeOptionalText(rawPeriod)
        let limit = try normalizeFMPResultLimit(limit)

        if let limit, limit <= 0 {
            throw Abort(.badRequest, reason: "`limit` must be greater than 0.")
        }

        try validateFMPSymbolAccess(symbol: symbol, operation: "balance-sheet-statement")
        let fmpProvider = try requireFMPProvider()

        do {
            return try await fmpProvider.balanceSheetStatement(
                symbol: symbol,
                limit: limit,
                period: period,
                on: req
            )
        } catch {
            throw mapFMPProviderError(error, operation: "balance-sheet-statement")
        }
    }

    func cashFlowStatement(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [CashFlowStatementResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizeOptionalText(rawPeriod)
        let limit = try normalizeFMPResultLimit(limit)

        if let limit, limit <= 0 {
            throw Abort(.badRequest, reason: "`limit` must be greater than 0.")
        }

        try validateFMPSymbolAccess(symbol: symbol, operation: "cash-flow-statement")
        let fmpProvider = try requireFMPProvider()

        do {
            return try await fmpProvider.cashFlowStatement(
                symbol: symbol,
                limit: limit,
                period: period,
                on: req
            )
        } catch {
            throw mapFMPProviderError(error, operation: "cash-flow-statement")
        }
    }

    func incomeStatement(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [IncomeStatementResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizeOptionalText(rawPeriod)
        let limit = try normalizeFMPResultLimit(limit)

        if let limit, limit <= 0 {
            throw Abort(.badRequest, reason: "`limit` must be greater than 0.")
        }

        try validateFMPSymbolAccess(symbol: symbol, operation: "income-statement")
        let fmpProvider = try requireFMPProvider()

        do {
            return try await fmpProvider.incomeStatement(
                symbol: symbol,
                limit: limit,
                period: period,
                on: req
            )
        } catch {
            throw mapFMPProviderError(error, operation: "income-statement")
        }
    }

    func ratiosTTM(symbol rawSymbol: String, on req: Request) async throws -> [RatiosTTMResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let now = Date()
        let providerName = "fmp" // Fixed for FMP endpoints
        let redisKey = makeRatiosTTMRedisKey(provider: providerName, symbol: symbol)

        if let hotCached: [RatiosTTMResponse] = await redisGetValue(
            redisKey, as: [RatiosTTMResponse].self, on: req
        ) {
            return hotCached
        }

        let existing = try await RatiosTTMCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .first()

        if let existing,
           isFresh(
               existing.updatedAt ?? existing.createdAt, ttlSeconds: cacheConfig.fmpTTLSeconds,
               now: now
           )
        {
            if let response = decodeRatiosTTMPayload(existing.payload) {
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
                )
                return response
            }
        }

        try validateFMPSymbolAccess(symbol: symbol, operation: "ratios-ttm")
        let fmpProvider = try requireFMPProvider()

        do {
            let fresh = try await fmpProvider.ratiosTTM(symbol: symbol, on: req)
            try await upsertRatiosTTMCache(
                symbol: symbol, payload: fresh, provider: providerName, on: req.db
            )
            await redisSetValue(
                redisKey, value: fresh, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
            )
            return fresh
        } catch {
            if let existing, let response = decodeRatiosTTMPayload(existing.payload) {
                req.logger.warning("market.ratios-ttm stale fallback symbol=\(symbol)")
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
                )
                return response
            }
            throw mapFMPProviderError(error, operation: "ratios-ttm")
        }
    }

    func gradesConsensus(symbol rawSymbol: String, on req: Request) async throws
        -> [GradesConsensusResponse]
    {
        let symbol = try normalizeSymbol(rawSymbol)
        try validateFMPSymbolAccess(symbol: symbol, operation: "grades-consensus")
        let fmpProvider = try requireFMPProvider()

        do {
            return try await fmpProvider.gradesConsensus(symbol: symbol, on: req)
        } catch {
            throw mapFMPProviderError(error, operation: "grades-consensus")
        }
    }

    func financialGrowth(
        symbol rawSymbol: String,
        limit rawLimit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [FinancialGrowthResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizeOptionalText(rawPeriod) ?? "FY"
        let limit = try normalizeFMPResultLimit(rawLimit, defaultLimit: 5) ?? 5
        let now = Date()
        let providerName = "fmp"
        let redisKey = makeFinancialGrowthRedisKey(
            provider: providerName, symbol: symbol, period: period, limit: limit
        )

        if limit <= 0 {
            throw Abort(.badRequest, reason: "`limit` must be greater than 0.")
        }

        if let hotCached: [FinancialGrowthResponse] = await redisGetValue(
            redisKey, as: [FinancialGrowthResponse].self, on: req
        ) {
            return hotCached
        }

        let existing = try await FinancialGrowthCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .filter(\.$period == period)
            .filter(\.$limit == limit)
            .first()

        if let existing,
           isFresh(
               existing.updatedAt ?? existing.createdAt, ttlSeconds: cacheConfig.fmpTTLSeconds,
               now: now
           )
        {
            if let response = decodeFinancialGrowthPayload(existing.payload) {
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
                )
                return response
            }
        }

        try validateFMPSymbolAccess(symbol: symbol, operation: "financial-growth")
        let fmpProvider = try requireFMPProvider()

        do {
            let fresh = try await fmpProvider.financialGrowth(
                symbol: symbol,
                limit: limit,
                period: period,
                on: req
            )
            try await upsertFinancialGrowthCache(
                symbol: symbol, period: period, limit: limit, payload: fresh,
                provider: providerName, on: req.db
            )
            await redisSetValue(
                redisKey, value: fresh, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
            )
            return fresh
        } catch {
            if let existing, let response = decodeFinancialGrowthPayload(existing.payload) {
                req.logger.warning("market.financial-growth stale fallback symbol=\(symbol)")
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
                )
                return response
            }
            throw mapFMPProviderError(error, operation: "financial-growth")
        }
    }

    func analystEstimates(
        symbol rawSymbol: String,
        period rawPeriod: String,
        page: Int?,
        limit: Int?,
        on req: Request
    ) async throws -> [AnalystEstimatesResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = try normalizeRequiredText(rawPeriod, field: "period")
        let limit = try normalizeFMPResultLimit(limit)
        let now = Date()
        let providerName = "fmp"
        let redisKey = makeAnalystEstimatesRedisKey(
            provider: providerName, symbol: symbol, period: period
        )

        if let limit, limit <= 0 {
            throw Abort(.badRequest, reason: "`limit` must be greater than 0.")
        }

        if let hotCached: [AnalystEstimatesResponse] = await redisGetValue(
            redisKey, as: [AnalystEstimatesResponse].self, on: req
        ) {
            return hotCached
        }

        let existing = try await AnalystEstimatesCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .filter(\.$period == period)
            .first()

        if let existing,
           isFresh(
               existing.updatedAt ?? existing.createdAt, ttlSeconds: cacheConfig.fmpTTLSeconds,
               now: now
           )
        {
            if let response = decodeAnalystEstimatesPayload(existing.payload) {
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
                )
                return response
            }
        }

        try validateFMPSymbolAccess(symbol: symbol, operation: "analyst-estimates")

        if fmpAccessTier == .free || fmpAccessTier == .starter, period.lowercased() != "annual" {
            throw Abort(
                .paymentRequired,
                reason: "FMP free-tier for analyst-estimates is limited to annual reports."
            )
        }

        let fmpProvider = try requireFMPProvider()

        do {
            let fresh = try await fmpProvider.analystEstimates(
                symbol: symbol,
                period: period,
                page: page,
                limit: limit,
                on: req
            )
            try await upsertAnalystEstimatesCache(
                symbol: symbol, period: period, payload: fresh, provider: providerName, on: req.db
            )
            await redisSetValue(
                redisKey, value: fresh, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
            )
            return fresh
        } catch {
            if let existing, let response = decodeAnalystEstimatesPayload(existing.payload) {
                req.logger.warning("market.analyst-estimates stale fallback symbol=\(symbol)")
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
                )
                return response
            }
            throw mapFMPProviderError(error, operation: "analyst-estimates")
        }
    }

    func ratios(
        symbol rawSymbol: String,
        limit rawLimit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [RatiosResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizeOptionalText(rawPeriod) ?? "FY"
        let limit = try normalizeFMPResultLimit(rawLimit, defaultLimit: 5) ?? 5
        let now = Date()
        let providerName = "fmp"
        let redisKey = makeRatiosRedisKey(
            provider: providerName, symbol: symbol, period: period, limit: limit
        )

        if limit <= 0 {
            throw Abort(.badRequest, reason: "`limit` must be greater than 0.")
        }

        if let hotCached: [RatiosResponse] = await redisGetValue(
            redisKey, as: [RatiosResponse].self, on: req
        ) {
            return hotCached
        }

        let existing = try await RatiosCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .filter(\.$period == period)
            .filter(\.$limit == limit)
            .first()

        if let existing,
           isFresh(
               existing.updatedAt ?? existing.createdAt, ttlSeconds: cacheConfig.fmpTTLSeconds,
               now: now
           )
        {
            if let response = decodeRatiosPayload(existing.payload) {
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
                )
                return response
            }
        }

        try validateFMPSymbolAccess(symbol: symbol, operation: "ratios")
        let fmpProvider = try requireFMPProvider()

        do {
            let fresh = try await fmpProvider.ratios(
                symbol: symbol,
                limit: limit,
                period: period,
                on: req
            )
            try await upsertRatiosCache(
                symbol: symbol, period: period, limit: limit, payload: fresh,
                provider: providerName, on: req.db
            )
            await redisSetValue(
                redisKey, value: fresh, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
            )
            return fresh
        } catch {
            if let existing, let response = decodeRatiosPayload(existing.payload) {
                req.logger.warning("market.ratios stale fallback symbol=\(symbol)")
                await redisSetValue(
                    redisKey, value: response, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
                )
                return response
            }
            throw mapFMPProviderError(error, operation: "ratios")
        }
    }

    func earnings(
        symbol rawSymbol: String,
        limit rawLimit: Int?,
        on req: Request
    ) async throws -> [EarningsResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let limit = try normalizeFMPResultLimit(rawLimit, defaultLimit: 100) ?? 100
        let providerName = "fmp"
        let redisKey = "market:earnings:\(providerName):\(symbol):\(limit)"

        if let hotCached: [EarningsResponse] = await redisGetValue(
            redisKey, as: [EarningsResponse].self, on: req
        ) {
            return hotCached
        }

        try validateFMPSymbolAccess(symbol: symbol, operation: "earnings")
        let fmpProvider = try requireFMPProvider()

        do {
            let fresh = try await fmpProvider.earnings(symbol: symbol, limit: limit, on: req)
            await redisSetValue(
                redisKey, value: fresh, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
            )
            return fresh
        } catch {
            throw mapFMPProviderError(error, operation: "earnings")
        }
    }

    func earningsCalendar(
        from rawFrom: String?,
        to rawTo: String?,
        on req: Request
    ) async throws -> [EarningsResponse] {
        let fromDate = try parseOptionalDateOnly(rawFrom, field: "from")
        let toDate = try parseOptionalDateOnly(rawTo, field: "to")
        let now = Date()
        let providerName = "fmp"
        let fromStr = fromDate.map(formatISODateOnly) ?? "none"
        let toStr = toDate.map(formatISODateOnly) ?? "none"
        let redisKey = "market:earnings-calendar:\(providerName):\(fromStr):\(toStr)"

        if let hotCached: [EarningsResponse] = await redisGetValue(
            redisKey, as: [EarningsResponse].self, on: req
        ) {
            return hotCached
        }

        if let fromDate {
            let calendar = Calendar.current
            let limitDate: Date? = switch fmpAccessTier {
            case .free:
                calendar.date(byAdding: .month, value: -1, to: now)
            case .starter:
                calendar.date(byAdding: .year, value: -1, to: now)
            case .premium:
                calendar.date(byAdding: .year, value: -5, to: now)
            }

            if let limitDate, fromDate < startOfDay(limitDate) {
                let rangeDescription = switch fmpAccessTier {
                case .free:
                    "limited to 1 month"
                case .starter:
                    "limited to 1 year"
                case .premium:
                    "limited to 5 years"
                }
                throw Abort(
                    .paymentRequired,
                    reason:
                    "This historical earnings range is \(rangeDescription) on the current market data coverage."
                )
            }
        }

        if let fromDate, let toDate, fromDate > toDate {
            throw Abort(.badRequest, reason: "`from` must be on or before `to`.")
        }

        let fmpProvider = try requireFMPProvider()

        do {
            let fresh = try await fmpProvider.earningsCalendar(from: fromDate, to: toDate, on: req)
            await redisSetValue(
                redisKey, value: fresh, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
            )
            return fresh
        } catch {
            throw mapFMPProviderError(error, operation: "earnings-calendar")
        }
    }

    func earningsTranscript(
        symbol rawSymbol: String,
        date rawDate: String?,
        year rawYear: Int?,
        quarter rawQuarter: Int?,
        on req: Request
    ) async throws -> EarningsTranscriptResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let date = try parseOptionalDateOnly(rawDate, field: "date").map(formatISODateOnly)

        if (rawYear == nil) != (rawQuarter == nil) {
            throw Abort(.badRequest, reason: "`year` and `quarter` must be provided together.")
        }
        if let quarter = rawQuarter, !(1 ... 4).contains(quarter) {
            throw Abort(.badRequest, reason: "`quarter` must be between 1 and 4.")
        }
        if date == nil, rawYear == nil {
            throw Abort(.badRequest, reason: "Query parameter `date` is required unless `year` and `quarter` are provided.")
        }

        let providerName = "fmp"
        let keyDate = date ?? "none"
        let keyYear = rawYear.map(String.init) ?? "none"
        let keyQuarter = rawQuarter.map(String.init) ?? "none"
        let redisKey = "market:earnings-transcript:\(providerName):\(symbol):\(keyDate):\(keyYear):\(keyQuarter)"

        if let hotCached: EarningsTranscriptResponse = await redisGetValue(
            redisKey, as: EarningsTranscriptResponse.self, on: req
        ) {
            return hotCached
        }

        try validateFMPSymbolAccess(symbol: symbol, operation: "earnings-transcript")
        let fmpProvider = try requireFMPProvider()

        do {
            let fresh = try await fmpProvider.earningsTranscript(
                symbol: symbol,
                date: date,
                year: rawYear,
                quarter: rawQuarter,
                on: req
            )
            await redisSetValue(
                redisKey, value: fresh, ttlSeconds: cacheConfig.fmpTTLSeconds, on: req
            )
            return fresh
        } catch {
            throw mapFMPProviderError(error, operation: "earnings-transcript")
        }
    }

    func historicalSectorPerformance(
        sector rawSector: String,
        exchange rawExchange: String?,
        from rawFrom: String?,
        to rawTo: String?,
        on req: Request
    ) async throws -> [HistoricalSectorPerformanceResponse] {
        let sector = try normalizeRequiredText(rawSector, field: "sector")
        let exchange = normalizeOptionalText(rawExchange)
        let fromDate = try parseOptionalDateOnly(rawFrom, field: "from")
        let toDate = try parseOptionalDateOnly(rawTo, field: "to")

        if let fromDate, let toDate, fromDate > toDate {
            throw Abort(.badRequest, reason: "`from` must be on or before `to`.")
        }

        let fmpProvider = try requireFMPProvider()

        do {
            return try await fmpProvider.historicalSectorPerformance(
                sector: sector,
                exchange: exchange,
                from: fromDate,
                to: toDate,
                on: req
            )
        } catch {
            throw mapFMPProviderError(error, operation: "historical-sector-performance")
        }
    }
}

// swiftlint:enable type_body_length

/// Internal (not private) so cache/fetch helpers can be reused by same-module
/// extensions in other files, e.g. fetchAndCacheBasicFinancials.
extension DefaultMarketDataService {
    func upsertQuoteCache(
        _ quote: MarketProviderQuote,
        provider providerName: String,
        on db: any Database
    ) async throws -> QuoteCache {
        if let existing = try await QuoteCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == quote.symbol)
            .first()
        {
            existing.price = quote.price
            existing.currency = quote.currency
            existing.asOf = quote.asOf
            existing.change = quote.change
            existing.percentChange = quote.percentChange
            existing.high = quote.high
            existing.low = quote.low
            existing.open = quote.open
            existing.previousClose = quote.previousClose
            try await existing.save(on: db)
            return existing
        }

        let row = QuoteCache(
            provider: providerName,
            symbol: quote.symbol,
            currency: quote.currency,
            price: quote.price,
            asOf: quote.asOf,
            change: quote.change,
            percentChange: quote.percentChange,
            high: quote.high,
            low: quote.low,
            open: quote.open,
            previousClose: quote.previousClose
        )
        try await row.save(on: db)
        return row
    }

    func upsertSearchCache(
        query: String,
        provider providerName: String,
        payload: String,
        on db: any Database
    ) async throws -> SearchCache {
        if let existing = try await SearchCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$normalizedQuery == query)
            .first()
        {
            existing.payload = payload
            try await existing.save(on: db)
            return existing
        }

        let row = SearchCache(provider: providerName, normalizedQuery: query, payload: payload)
        try await row.save(on: db)
        return row
    }

    func upsertHistoryBars(
        symbol: String,
        currency: String,
        provider: String,
        bars: [MarketProviderPriceBar],
        on db: any Database
    ) async throws {
        for bar in bars {
            let day = startOfDay(bar.date)
            if let existing = try await PriceHistory.query(on: db)
                .filter(\.$symbol == symbol)
                .filter(\.$date == day)
                .first()
            {
                existing.open = bar.open
                existing.high = bar.high
                existing.low = bar.low
                existing.close = bar.close
                existing.volume = bar.volume
                try await existing.save(on: db)
                continue
            }

            let model = PriceHistory(
                symbol: symbol,
                date: day,
                open: bar.open,
                high: bar.high,
                low: bar.low,
                close: bar.close,
                volume: bar.volume
            )
            try await model.save(on: db)
        }
        // Keep the canonical scenario history store in sync while legacy history readers are retired.
        // This is best-effort so a partially rolled-out schema cannot break the existing market API.
        let canonicalBars = bars.map {
            PriceBarResponse(
                date: formatISODateOnly($0.date), open: $0.open, high: $0.high,
                low: $0.low, close: $0.close, volume: $0.volume
            )
        }
        do {
            try await MarketPriceBarRepository().upsert(
                instrumentKey: symbol, currency: currency, provider: provider,
                bars: canonicalBars, on: db
            )
        } catch {
            db.logger.warning("market history canonical dual-write failed symbol=\(symbol) error=\(error)")
        }
    }

    func upsertFxRate(_ rate: MarketProviderFxRate, on db: any Database) async throws
        -> FxRate
    {
        let day = startOfDay(rate.asOf)
        if let existing = try await FxRate.query(on: db)
            .filter(\.$date == day)
            .filter(\.$base == rate.base)
            .filter(\.$quote == rate.quote)
            .first()
        {
            existing.rate = rate.rate
            try await existing.save(on: db)
            return existing
        }

        let model = FxRate(
            date: day,
            base: rate.base,
            quote: rate.quote,
            rate: rate.rate
        )
        try await model.save(on: db)
        return model
    }

    func upsertProfileCache(
        _ profile: MarketProviderCompanyProfile,
        provider providerName: String,
        on db: any Database
    ) async throws -> ProfileCache {
        if let existing = try await ProfileCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == profile.symbol)
            .first()
        {
            existing.country = profile.country
            existing.currency = profile.currency
            existing.estimateCurrency = profile.estimateCurrency
            existing.exchange = profile.exchange
            existing.finnhubIndustry = profile.finnhubIndustry
            existing.ipo = profile.ipo
            existing.logo = profile.logo
            existing.marketCapitalization = profile.marketCapitalization
            existing.name = profile.name
            existing.phone = profile.phone
            existing.shareOutstanding = profile.shareOutstanding
            existing.ticker = profile.ticker
            existing.weburl = profile.weburl
            try await existing.save(on: db)
            return existing
        }

        let row = ProfileCache(
            provider: providerName,
            symbol: profile.symbol,
            country: profile.country,
            currency: profile.currency,
            estimateCurrency: profile.estimateCurrency,
            exchange: profile.exchange,
            finnhubIndustry: profile.finnhubIndustry,
            ipo: profile.ipo,
            logo: profile.logo,
            marketCapitalization: profile.marketCapitalization,
            name: profile.name,
            phone: profile.phone,
            shareOutstanding: profile.shareOutstanding,
            ticker: profile.ticker,
            weburl: profile.weburl
        )
        try await row.save(on: db)
        return row
    }

    func upsertBasicFinancialsCache(
        _ financials: BasicFinancialsResponse,
        provider providerName: String,
        on db: any Database
    ) async throws -> BasicFinancialsCache {
        let payloadData = try JSONEncoder().encode(financials)
        guard let payload = String(bytes: payloadData, encoding: .utf8) else {
            throw Abort(
                .internalServerError, reason: "Failed to encode basic financials cache payload."
            )
        }

        if let existing = try await BasicFinancialsCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == financials.symbol)
            .first()
        {
            existing.payload = payload
            try await existing.save(on: db)
            return existing
        }

        let row = BasicFinancialsCache(
            provider: providerName,
            symbol: financials.symbol,
            payload: payload
        )
        try await row.save(on: db)
        return row
    }

    func upsertAnalystEstimatesCache(
        symbol: String,
        period: String,
        payload responses: [AnalystEstimatesResponse],
        provider providerName: String,
        on db: any Database
    ) async throws -> AnalystEstimatesCache {
        let payloadData = try JSONEncoder().encode(responses)
        guard let payload = String(bytes: payloadData, encoding: .utf8) else {
            throw Abort(
                .internalServerError, reason: "Failed to encode analyst estimates cache payload."
            )
        }

        if let existing = try await AnalystEstimatesCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .filter(\.$period == period)
            .first()
        {
            existing.payload = payload
            try await existing.save(on: db)
            return existing
        }

        let row = AnalystEstimatesCache(
            provider: providerName,
            symbol: symbol,
            period: period,
            payload: payload
        )
        try await row.save(on: db)
        return row
    }

    func upsertFinancialGrowthCache(
        symbol: String,
        period: String,
        limit: Int,
        payload responses: [FinancialGrowthResponse],
        provider providerName: String,
        on db: any Database
    ) async throws -> FinancialGrowthCache {
        let payloadData = try JSONEncoder().encode(responses)
        guard let payload = String(bytes: payloadData, encoding: .utf8) else {
            throw Abort(
                .internalServerError, reason: "Failed to encode financial growth cache payload."
            )
        }

        if let existing = try await FinancialGrowthCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .filter(\.$period == period)
            .filter(\.$limit == limit)
            .first()
        {
            existing.payload = payload
            try await existing.save(on: db)
            return existing
        }

        let row = FinancialGrowthCache(
            provider: providerName,
            symbol: symbol,
            period: period,
            limit: limit,
            payload: payload
        )
        try await row.save(on: db)
        return row
    }

    func upsertRatiosTTMCache(
        symbol: String,
        payload responses: [RatiosTTMResponse],
        provider providerName: String,
        on db: any Database
    ) async throws -> RatiosTTMCache {
        let payloadData = try JSONEncoder().encode(responses)
        guard let payload = String(bytes: payloadData, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to encode ratios TTM cache payload.")
        }

        if let existing = try await RatiosTTMCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .first()
        {
            existing.payload = payload
            try await existing.save(on: db)
            return existing
        }

        let row = RatiosTTMCache(
            provider: providerName,
            symbol: symbol,
            payload: payload
        )
        try await row.save(on: db)
        return row
    }

    func upsertRatiosCache(
        symbol: String,
        period: String,
        limit: Int,
        payload responses: [RatiosResponse],
        provider providerName: String,
        on db: any Database
    ) async throws -> RatiosCache {
        let payloadData = try JSONEncoder().encode(responses)
        guard let payload = String(bytes: payloadData, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to encode ratios cache payload.")
        }

        if let existing = try await RatiosCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .filter(\.$period == period)
            .filter(\.$limit == limit)
            .first()
        {
            existing.payload = payload
            try await existing.save(on: db)
            return existing
        }

        let row = RatiosCache(
            provider: providerName,
            symbol: symbol,
            period: period,
            limit: limit,
            payload: payload
        )
        try await row.save(on: db)
        return row
    }

    func loadCachedHistory(
        symbol: String,
        from: Date?,
        to: Date?,
        on db: any Database
    ) async throws -> [PriceHistory] {
        let query = PriceHistory.query(on: db)
            .filter(\.$symbol == symbol)
            .sort(\.$date, .ascending)

        if let from {
            query.filter(\.$date >= startOfDay(from))
        }

        if let to {
            query.filter(\.$date <= startOfDay(to))
        }

        return try await query.all()
    }

    func parseHistoryRange(from rawFrom: String?, to rawTo: String?) throws -> (
        Date?, Date?
    ) {
        let fromDate = try parseOptionalDateOnly(rawFrom, field: "from")
        let toDate = try parseOptionalDateOnly(rawTo, field: "to")

        if let fromDate, let toDate, fromDate > toDate {
            throw Abort(.badRequest, reason: "`from` must be on or before `to`.")
        }

        return (fromDate, toDate)
    }

    func makeQuoteResponse(from model: QuoteCache) -> QuoteResponse {
        QuoteResponse(
            symbol: model.symbol,
            currency: model.currency,
            currentPrice: model.price,
            change: model.change,
            percentChange: model.percentChange,
            high: model.high,
            low: model.low,
            open: model.open,
            previousClose: model.previousClose,
            timestamp: model.asOf.timeIntervalSince1970
        )
    }

    func makeFxResponse(from model: FxRate) -> FxRateResponse {
        FxRateResponse(
            base: model.base,
            quote: model.quote,
            rate: model.rate,
            date: formatISODateOnly(model.date)
        )
    }

    func makeProfileResponse(from model: ProfileCache) -> CompanyProfileResponse {
        CompanyProfileResponse(
            country: model.country,
            currency: model.currency,
            estimateCurrency: model.estimateCurrency,
            exchange: model.exchange,
            finnhubIndustry: model.finnhubIndustry,
            ipo: model.ipo,
            logo: model.logo,
            marketCapitalization: model.marketCapitalization,
            name: model.name,
            phone: model.phone,
            shareOutstanding: model.shareOutstanding,
            ticker: model.ticker,
            weburl: model.weburl
        )
    }

    func makeBasicFinancialsResponse(from model: MarketProviderBasicFinancials)
        -> BasicFinancialsResponse
    {
        BasicFinancialsResponse(
            symbol: model.symbol,
            metricType: model.metricType,
            metric: model.metric,
            series: model.series
        )
    }

    func makePriceBarResponse(from model: PriceHistory) -> PriceBarResponse {
        PriceBarResponse(
            date: formatISODateOnly(model.date),
            open: model.open,
            high: model.high,
            low: model.low,
            close: model.close,
            volume: model.volume
        )
    }

    func makePriceHistoryModel(symbol: String, from bar: MarketProviderPriceBar)
        -> PriceHistory
    {
        PriceHistory(
            symbol: symbol,
            date: startOfDay(bar.date),
            open: bar.open,
            high: bar.high,
            low: bar.low,
            close: bar.close,
            volume: bar.volume
        )
    }

    func decodeSearchPayload(_ raw: String) -> [SearchResultResponse]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([SearchResultResponse].self, from: data)
    }

    func decodeBasicFinancialsPayload(_ raw: String) -> BasicFinancialsResponse? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BasicFinancialsResponse.self, from: data)
    }

    func decodeAnalystEstimatesPayload(_ raw: String) -> [AnalystEstimatesResponse]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([AnalystEstimatesResponse].self, from: data)
    }

    func decodeFinancialGrowthPayload(_ raw: String) -> [FinancialGrowthResponse]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([FinancialGrowthResponse].self, from: data)
    }

    func decodeRatiosTTMPayload(_ raw: String) -> [RatiosTTMResponse]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([RatiosTTMResponse].self, from: data)
    }

    func decodeRatiosPayload(_ raw: String) -> [RatiosResponse]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([RatiosResponse].self, from: data)
    }

    func isMissingDatabaseRelationError(_ error: any Error, relation: String) -> Bool {
        let description = String(describing: error).lowercased()
        let expectedRelation = relation.lowercased()
        return description.contains("sqlstate: 42p01")
            || description.contains("relation \"\(expectedRelation)\" does not exist")
    }

    func makeQuoteRedisKey(provider: String, symbol: String) -> String {
        "market:quote:\(provider):\(symbol)"
    }

    func makeHistoryRedisKey(provider: String, symbol: String, from: Date?, to: Date?)
        -> String
    {
        let fromPart = from.map(formatISODateOnly) ?? "none"
        let toPart = to.map(formatISODateOnly) ?? "none"
        return "market:history:\(provider):\(symbol):\(fromPart):\(toPart)"
    }

    func makeSearchRedisKey(provider: String, query: String) -> String {
        "market:search:\(provider):\(query)"
    }

    func makeFxRedisKey(provider: String, base: String, quote: String) -> String {
        "market:fx:\(provider):\(base)\(quote)"
    }

    func makeProfileRedisKey(provider: String, symbol: String) -> String {
        "market:profile:\(provider):\(symbol)"
    }

    func makeBasicFinancialsRedisKey(provider: String, symbol: String) -> String {
        "market:basic-financials:\(provider):\(symbol)"
    }

    func makeAnalystEstimatesRedisKey(provider: String, symbol: String, period: String)
        -> String
    {
        "market:analyst-estimates:\(provider):\(symbol):\(period)"
    }

    func makeFinancialGrowthRedisKey(
        provider: String, symbol: String, period: String, limit: Int
    ) -> String {
        "market:financial-growth:\(provider):\(symbol):\(period):\(limit)"
    }

    func makeRatiosTTMRedisKey(provider: String, symbol: String) -> String {
        "market:ratios-ttm:\(provider):\(symbol)"
    }

    func makeRatiosRedisKey(
        provider: String, symbol: String, period: String, limit: Int
    ) -> String {
        "market:ratios:\(provider):\(symbol):\(period):\(limit)"
    }

    func redisGetValue<T: Decodable>(
        _ key: String,
        as type: T.Type,
        on req: Request
    ) async -> T? {
        guard req.application.redis.configuration != nil else {
            return nil
        }

        do {
            guard let data = try await req.redis.get(RedisKey(key), as: Data.self).get() else {
                return nil
            }
            return try JSONDecoder().decode(type, from: data)
        } catch {
            req.logger.warning("market.redis.read failed key=\(key) error=\(error)")
            return nil
        }
    }

    func redisSetValue(
        _ key: String,
        value: some Encodable,
        ttlSeconds: Int,
        on req: Request
    ) async {
        guard req.application.redis.configuration != nil else {
            return
        }

        do {
            let data = try JSONEncoder().encode(value)
            try await req.redis
                .setex(RedisKey(key), to: data, expirationInSeconds: max(1, ttlSeconds))
                .get()
        } catch {
            req.logger.warning("market.redis.write failed key=\(key) error=\(error)")
        }
    }

    func normalizeSymbol(_ raw: String) throws -> String {
        let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return symbol
    }

    func normalizeQuery(_ raw: String) throws -> String {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !query.isEmpty else {
            throw Abort(.badRequest, reason: "Query parameter `q` is required.")
        }
        return query
    }

    func normalizeRequiredText(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw Abort(.badRequest, reason: "Query parameter `\(field)` is required.")
        }
        return value
    }

    func normalizeOptionalText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func normalizePair(_ raw: String) throws -> (String, String) {
        let compact =
            raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "")
                .replacingOccurrences(of: "-", with: "")
                .uppercased()

        guard compact.count == 6 else {
            throw Abort(.badRequest, reason: "Invalid FX pair. Use `EURUSD` or `EUR/USD`.")
        }

        let base = String(compact.prefix(3))
        let quote = String(compact.suffix(3))
        return (base, quote)
    }

    func parseOptionalDateOnly(_ raw: String?, field: String) throws -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        guard let value = formatter.date(from: trimmed) else {
            throw Abort(.badRequest, reason: "Invalid \(field). Expected YYYY-MM-DD.")
        }
        return startOfDay(value)
    }

    func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func formatISODateTime(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.startOfDay(for: date)
    }

    func isFresh(_ at: Date?, ttlSeconds: Int, now: Date) -> Bool {
        guard let at else { return false }
        return now.timeIntervalSince(at) <= TimeInterval(ttlSeconds)
    }

    func isHistoryFresh(_ history: [PriceHistory], now: Date) -> Bool {
        guard let latest = history.last?.date else { return false }
        return isFresh(latest, ttlSeconds: cacheConfig.historyTTLSeconds, now: now)
    }

    func mapProviderError(_ error: any Error, operation: String) -> any Error {
        if error is MarketDataProviderDisabledError {
            return MarketDataProviderDisabledError()
        }

        // Preserve the Retry-After header; the generic AbortError re-wrap below
        // would drop it.
        if let rateLimited = error as? MarketDataProviderRateLimitedError {
            return rateLimited
        }

        if let abort = error as? Abort {
            return abort
        }

        if let abort = error as? any AbortError {
            return Abort(abort.status, reason: abort.reason)
        }

        return Abort(
            .serviceUnavailable,
            reason: """
            Market provider unavailable for \(operation). Check MARKET_PROVIDER and provider-specific configuration such as FINNHUB_API_KEY or IBKR_API_BASE_URL.
            """
        )
    }

    func requireFMPProvider() throws -> any FMPMarketDataProvider {
        guard let fmpProvider else {
            throw Abort(.serviceUnavailable, reason: "FMP_API_KEY is not configured.")
        }
        return fmpProvider
    }

    func validateFMPSymbolAccess(symbol: String, operation: String) throws {
        guard !fmpAccessTier.allowsAllSymbols else {
            return
        }

        guard FMPSymbolPlanAccess.isSupportedOnFreeTier(symbol) else {
            throw Abort(
                .paymentRequired,
                reason: "FMP free-tier coverage for \(operation) does not include \(symbol). Use a supported symbol or upgrade the market data tier."
            )
        }
    }

    func mapFMPProviderError(_ error: any Error, operation: String) -> any Error {
        if let abort = error as? Abort {
            return abort
        }

        if let abort = error as? any AbortError {
            return Abort(abort.status, reason: abort.reason)
        }

        return Abort(
            .serviceUnavailable,
            reason: """
            FMP unavailable for \(operation). Check FMP_API_KEY.
            """
        )
    }

    func metricDouble(_ key: String, in response: BasicFinancialsResponse) -> Double? {
        guard case let .number(value)? = response.metric[key] else {
            return nil
        }
        return value
    }

    func metricPercent(_ key: String, in response: BasicFinancialsResponse) -> Double? {
        metricDouble(key, in: response).map { $0 / 100 }
    }

    func latestSeriesValue(
        frequency: String, metric: String, in response: BasicFinancialsResponse
    ) -> Double? {
        response.series[frequency]?[metric]?.first?.value
    }

    func impliedForwardGrowth(ttmPE: Double?, forwardPE: Double?) -> Double? {
        guard let ttmPE, let forwardPE, ttmPE > 0, forwardPE > 0 else {
            return nil
        }
        return (ttmPE / forwardPE) - 1
    }

    func twoYearForwardPE(forwardPE: Double?, nextYearEPSGrowth: Double?) -> Double? {
        guard let forwardPE, let nextYearEPSGrowth, forwardPE > 0, nextYearEPSGrowth > -1 else {
            return nil
        }
        return forwardPE / (1 + nextYearEPSGrowth)
    }

    func stackedGrowth(first: Double?, second: Double?) -> Double? {
        guard let first, let second else {
            return nil
        }
        return ((1 + first) * (1 + second)) - 1
    }

    func delta(lhs: Double?, rhs: Double?) -> Double? {
        guard let lhs, let rhs else {
            return nil
        }
        return lhs - rhs
    }
}
