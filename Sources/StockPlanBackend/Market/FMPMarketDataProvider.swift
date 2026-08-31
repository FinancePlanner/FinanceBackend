import Foundation
import StockPlanShared
import Vapor

protocol FMPMarketDataProvider: Sendable {
    var name: String { get }

    func cashFlowStatement(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [CashFlowStatementResponse]
    func incomeStatement(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [IncomeStatementResponse]
    func balanceSheetStatement(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [BalanceSheetStatementResponse]
    func ratiosTTM(symbol: String, on req: Request) async throws -> [RatiosTTMResponse]
    func gradesConsensus(symbol: String, on req: Request) async throws -> [GradesConsensusResponse]
    func financialGrowth(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [FinancialGrowthResponse]
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
        from: Date?,
        to: Date?,
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
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [HistoricalSectorPerformanceResponse]
    func fetchGeneralMarketNews(
        page: Int?,
        limit: Int?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [FMPMarketNewsItem]

    /// Stock price chart (intraday + EOD)
    func stockIntraday(
        interval: String,
        symbol: String,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [CryptoHistoricalPoint]
    func stockHistoricalEOD(
        symbol: String,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [CryptoHistoricalLightPoint]
    func fetchStockQuotes(symbols: [String], on req: Request) async throws -> [CryptoQuoteResponse]
    func fetchBiggestGainers(on req: Request) async throws -> [FMPMoverItem]
    func fetchBiggestLosers(on req: Request) async throws -> [FMPMoverItem]
    func fetchTopMarketCapUniverse(limit: Int, on req: Request) async throws -> [FMPScreenerItem]
    func fetchInsiderTrades(symbol: String, limit: Int, on req: Request) async throws -> [FMPInsiderTrade]
    func stockPriceChange(symbol: String, on req: Request) async throws -> [FMPStockPriceChange]
}

/// Defaults keep pre-existing conformers (test stubs) compiling; the live
/// provider overrides all of these.
extension FMPMarketDataProvider {
    func fetchStockQuotes(symbols _: [String], on _: Request) async throws -> [CryptoQuoteResponse] {
        throw Abort(.serviceUnavailable, reason: "Batch quotes are not supported by this provider.")
    }

    func fetchBiggestGainers(on _: Request) async throws -> [FMPMoverItem] {
        throw Abort(.serviceUnavailable, reason: "Market movers are not supported by this provider.")
    }

    func fetchBiggestLosers(on _: Request) async throws -> [FMPMoverItem] {
        throw Abort(.serviceUnavailable, reason: "Market movers are not supported by this provider.")
    }

    func fetchTopMarketCapUniverse(limit _: Int, on _: Request) async throws -> [FMPScreenerItem] {
        throw Abort(.serviceUnavailable, reason: "The market screener is not supported by this provider.")
    }

    func fetchInsiderTrades(symbol _: String, limit _: Int, on _: Request) async throws -> [FMPInsiderTrade] {
        throw Abort(.serviceUnavailable, reason: "Insider trades are not supported by this provider.")
    }

    func stockPriceChange(symbol _: String, on _: Request) async throws -> [FMPStockPriceChange] {
        throw Abort(.serviceUnavailable, reason: "Stock price change is not supported by this provider.")
    }
}

struct FMPMarketNewsItem: Codable {
    let symbol: String?
    let publishedDate: String?
    let title: String?
    let image: String?
    let site: String?
    let publisher: String?
    let text: String?
    let url: String?
}

private struct FMPEarningsItem: Codable {
    let symbol: String
    let date: String
    let epsActual: Double?
    let epsEstimated: Double?
    let revenueActual: Double?
    let revenueEstimated: Double?
    let lastUpdated: String?
}

private struct FMPTranscriptDateItem: Decodable {
    let date: String?
    let quarter: Int?
    let year: Int?

    enum CodingKeys: String, CodingKey {
        case date
        case quarter
        case year
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        quarter = try Self.decodeIntIfPresent(from: container, key: .quarter)
        year = try Self.decodeIntIfPresent(from: container, key: .year)
    }

    private static func decodeIntIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int? {
        if let value = try container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let stringValue = try container.decodeIfPresent(String.self, forKey: key) {
            return Int(stringValue)
        }
        return nil
    }
}

private struct FMPEarningsTranscriptItem: Decodable {
    let symbol: String?
    let date: String?
    let period: String?
    let year: Int?
    let quarter: Int?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case symbol
        case date
        case period
        case year
        case quarter
        case content
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        period = try container.decodeIfPresent(String.self, forKey: .period)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        year = try Self.decodeIntIfPresent(from: container, key: .year)
        quarter = try Self.decodeIntIfPresent(from: container, key: .quarter)
    }

    private static func decodeIntIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int? {
        if let value = try container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let stringValue = try container.decodeIfPresent(String.self, forKey: key) {
            return Int(stringValue)
        }
        return nil
    }
}

private struct TranscriptAvailabilityKey: Hashable {
    let date: String?
    let year: Int?
    let quarter: Int?
}

struct LiveFMPMarketDataProvider: FMPMarketDataProvider, CryptoDataProvider {
    let baseURL: String
    let apiKey: String

    var name: String {
        "fmp"
    }

    init(
        baseURL: String = "https://financialmodelingprep.com",
        apiKey: String = Environment.get("FMP_API_KEY") ?? ""
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    // MARK: - CryptoDataProvider

    func cryptocurrencyList(on req: Request) async throws -> [CryptoAssetResponse] {
        try await fetchJSON(path: "/stable/cryptocurrency-list", query: [], on: req)
    }

    func quote(symbols: String, on req: Request) async throws -> [CryptoQuoteResponse] {
        let symbols = try normalizeSymbols(symbols)
        return try await fetchJSON(
            path: "/stable/quote",
            query: [("symbol", symbols)],
            on: req
        )
    }

    func quoteShort(symbol: String, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        let symbol = try normalizeSymbol(symbol)
        return try await fetchJSON(
            path: "/stable/quote-short",
            query: [("symbol", symbol)],
            on: req
        )
    }

    func batchQuotes(short: Bool, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        var query: [(String, String?)] = []
        if short {
            query.append(("short", "true"))
        }
        return try await fetchJSON(
            path: "/stable/batch-crypto-quotes",
            query: query,
            on: req
        )
    }

    func historicalLight(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalLightPoint]
    {
        let symbol = try normalizeSymbol(symbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from {
            query.append(("from", from))
        }
        if let to {
            query.append(("to", to))
        }
        return try await fetchJSON(
            path: "/stable/historical-price-eod/light",
            query: query,
            on: req
        )
    }

    func historicalFull(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalFullPoint]
    {
        let symbol = try normalizeSymbol(symbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from {
            query.append(("from", from))
        }
        if let to {
            query.append(("to", to))
        }
        return try await fetchJSON(
            path: "/stable/historical-price-eod/full",
            query: query,
            on: req
        )
    }

    func intraday1min(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalPoint]
    {
        try await fetchIntraday(interval: "1min", symbol: symbol, from: from, to: to, on: req)
    }

    func intraday5min(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalPoint]
    {
        try await fetchIntraday(interval: "5min", symbol: symbol, from: from, to: to, on: req)
    }

    func intraday1hour(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalPoint]
    {
        try await fetchIntraday(interval: "1hour", symbol: symbol, from: from, to: to, on: req)
    }

    func fetchCryptoNews(
        symbol: String?,
        page: Int?,
        limit: Int?,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [FMPMarketNewsItem] {
        var query: [(String, String?)] = []
        if let symbol {
            try query.append(("symbol", normalizeSymbol(symbol)))
        }
        if let page {
            query.append(("page", String(page)))
        }
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let from {
            query.append(("from", from))
        }
        if let to {
            query.append(("to", to))
        }

        return try await fetchJSON(
            path: "/stable/news/crypto-latest",
            query: query,
            on: req
        )
    }

    private func fetchIntraday(
        interval: String, symbol: String, from: String?, to: String?, on req: Request
    ) async throws -> [CryptoHistoricalPoint] {
        let symbol = try normalizeSymbol(symbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from {
            query.append(("from", from))
        }
        if let to {
            query.append(("to", to))
        }
        return try await fetchJSON(
            path: "/stable/historical-chart/\(interval)",
            query: query,
            on: req
        )
    }

    private func normalizeSymbols(_ raw: String) throws -> String {
        let normalized = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
            .joined(separator: ",")

        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }
        return normalized
    }

    // MARK: - FMPMarketDataProvider

    func cashFlowStatement(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [CashFlowStatementResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizedOptionalValue(rawPeriod)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let period {
            query.append(("period", period))
        }

        return try await fetchJSON(
            path: "/stable/cash-flow-statement",
            query: query,
            on: req
        )
    }

    func incomeStatement(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [IncomeStatementResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizedOptionalValue(rawPeriod)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let period {
            query.append(("period", period))
        }

        return try await fetchJSON(
            path: "/stable/income-statement",
            query: query,
            on: req
        )
    }

    func ratiosTTM(symbol rawSymbol: String, on req: Request) async throws -> [RatiosTTMResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        return try await fetchJSON(
            path: "/stable/ratios-ttm",
            query: [("symbol", symbol)],
            on: req
        )
    }

    func balanceSheetStatement(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [BalanceSheetStatementResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizedOptionalValue(rawPeriod)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let period {
            query.append(("period", period))
        }

        return try await fetchJSON(
            path: "/stable/balance-sheet-statement",
            query: query,
            on: req
        )
    }

    func gradesConsensus(symbol rawSymbol: String, on req: Request) async throws
        -> [GradesConsensusResponse]
    {
        let symbol = try normalizeSymbol(rawSymbol)
        return try await fetchJSON(
            path: "/stable/grades-consensus",
            query: [("symbol", symbol)],
            on: req
        )
    }

    func financialGrowth(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [FinancialGrowthResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizedOptionalValue(rawPeriod)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let period {
            query.append(("period", period))
        }

        return try await fetchJSON(
            path: "/stable/financial-growth",
            query: query,
            on: req
        )
    }

    func analystEstimates(
        symbol rawSymbol: String,
        period rawPeriod: String,
        page: Int?,
        limit: Int?,
        on req: Request
    ) async throws -> [AnalystEstimatesResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = try normalizeRequiredValue(rawPeriod, field: "period")

        var query: [(String, String?)] = [("symbol", symbol), ("period", period)]
        if let page {
            query.append(("page", String(page)))
        }
        if let limit {
            query.append(("limit", String(limit)))
        }

        return try await fetchJSON(
            path: "/stable/analyst-estimates",
            query: query,
            on: req
        )
    }

    func ratios(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [RatiosResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizedOptionalValue(rawPeriod)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let period {
            query.append(("period", period))
        }

        return try await fetchJSON(
            path: "/stable/ratios",
            query: query,
            on: req
        )
    }

    func earnings(
        symbol rawSymbol: String,
        limit: Int?,
        on req: Request
    ) async throws -> [EarningsResponse] {
        let symbol = try normalizeSymbol(rawSymbol)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }

        let items: [FMPEarningsItem] = try await fetchJSON(
            path: "/stable/earnings",
            query: query,
            on: req
        )

        let transcriptAvailability = await (try? fetchTranscriptAvailability(symbol: symbol, on: req)) ?? []

        return items.map { item in
            EarningsResponse(
                symbol: item.symbol,
                date: item.date,
                epsActual: item.epsActual,
                epsEstimated: item.epsEstimated,
                revenueActual: item.revenueActual,
                revenueEstimated: item.revenueEstimated,
                lastUpdated: item.lastUpdated,
                surprisePercent: makeEarningsSurprisePercent(
                    actual: item.epsActual,
                    estimate: item.epsEstimated
                ),
                hasTranscript: hasTranscriptAvailability(
                    for: transcriptAvailabilityKey(for: item.date),
                    in: transcriptAvailability
                )
            )
        }
    }

    func earningsCalendar(
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [EarningsResponse] {
        var query: [(String, String?)] = []
        if let from {
            query.append(("from", formatISODateOnly(from)))
        }
        if let to {
            query.append(("to", formatISODateOnly(to)))
        }

        let items: [FMPEarningsItem] = try await fetchJSON(
            path: "/stable/earnings-calendar",
            query: query,
            on: req
        )

        return items.map { item in
            EarningsResponse(
                symbol: item.symbol,
                date: item.date,
                epsActual: item.epsActual,
                epsEstimated: item.epsEstimated,
                revenueActual: item.revenueActual,
                revenueEstimated: item.revenueEstimated,
                lastUpdated: item.lastUpdated,
                surprisePercent: makeEarningsSurprisePercent(
                    actual: item.epsActual,
                    estimate: item.epsEstimated
                ),
                hasTranscript: false
            )
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
        let resolved = try await resolveTranscriptPeriod(
            symbol: symbol,
            date: rawDate,
            year: rawYear,
            quarter: rawQuarter,
            on: req
        )

        let items: [FMPEarningsTranscriptItem] = try await fetchJSON(
            path: "/stable/earning-call-transcript",
            query: [
                ("symbol", symbol),
                ("year", String(resolved.year)),
                ("quarter", String(resolved.quarter)),
            ],
            on: req
        )

        guard let item = items.first else {
            throw Abort(.notFound, reason: "No earnings transcript found for \(symbol) \(resolved.year) Q\(resolved.quarter).")
        }

        let content = item.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            throw Abort(.notFound, reason: "No earnings transcript content found for \(symbol) \(resolved.year) Q\(resolved.quarter).")
        }

        return EarningsTranscriptResponse(
            symbol: (item.symbol ?? symbol).uppercased(),
            date: normalizedDateOnly(item.date) ?? resolved.date ?? "",
            year: item.year ?? resolved.year,
            quarter: item.quarter ?? resolved.quarter,
            period: item.period,
            content: content,
            provider: name
        )
    }

    func historicalSectorPerformance(
        sector rawSector: String,
        exchange rawExchange: String?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [HistoricalSectorPerformanceResponse] {
        let sector = try normalizeRequiredValue(rawSector, field: "sector")
        let exchange = normalizedOptionalValue(rawExchange)

        return try await fetchJSON(
            path: "/stable/historical-sector-performance",
            query: [
                ("sector", sector),
                ("exchange", exchange),
                ("from", from.map(formatISODateOnly)),
                ("to", to.map(formatISODateOnly)),
            ],
            on: req
        )
    }

    func fetchGeneralMarketNews(
        page: Int?,
        limit: Int?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [FMPMarketNewsItem] {
        var query: [(String, String?)] = []
        if let page {
            query.append(("page", String(page)))
        }
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let from {
            query.append(("from", formatISODateOnly(from)))
        }
        if let to {
            query.append(("to", formatISODateOnly(to)))
        }

        return try await fetchJSON(
            path: "/stable/news/stock-latest",
            query: query,
            on: req
        )
    }

    // MARK: - Market overview (indices, movers, screener universe)

    func fetchStockQuotes(symbols: [String], on req: Request) async throws -> [CryptoQuoteResponse] {
        let joined = symbols
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        guard !joined.isEmpty else { return [] }
        return try await fetchJSON(
            path: "/stable/quote",
            query: [("symbol", joined)],
            on: req
        )
    }

    func fetchBiggestGainers(on req: Request) async throws -> [FMPMoverItem] {
        try await fetchJSON(path: "/stable/biggest-gainers", query: [], on: req)
    }

    func fetchBiggestLosers(on req: Request) async throws -> [FMPMoverItem] {
        try await fetchJSON(path: "/stable/biggest-losers", query: [], on: req)
    }

    func fetchTopMarketCapUniverse(limit: Int, on req: Request) async throws -> [FMPScreenerItem] {
        try await fetchJSON(
            path: "/stable/company-screener",
            query: [
                ("marketCapMoreThan", "10000000000"),
                ("country", "US"),
                ("isEtf", "false"),
                ("isFund", "false"),
                ("isActivelyTrading", "true"),
                ("limit", String(limit)),
            ],
            on: req
        )
    }

    func fetchInsiderTrades(symbol: String, limit: Int, on req: Request) async throws -> [FMPInsiderTrade] {
        let symbol = try normalizeSymbol(symbol)
        return try await fetchJSON(
            path: "/stable/insider-trading/search",
            query: [("symbol", symbol), ("page", "0"), ("limit", String(limit))],
            on: req
        )
    }

    func stockPriceChange(symbol rawSymbol: String, on req: Request) async throws -> [FMPStockPriceChange] {
        let symbol = try normalizeSymbol(rawSymbol)
        return try await fetchJSON(
            path: "/stable/stock-price-change",
            query: [("symbol", symbol)],
            on: req
        )
    }

    // MARK: - Stock Price Chart

    func stockIntraday(
        interval: String,
        symbol rawSymbol: String,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [CryptoHistoricalPoint] {
        let symbol = try normalizeSymbol(rawSymbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from {
            query.append(("from", from))
        }
        if let to {
            query.append(("to", to))
        }
        return try await fetchJSON(
            path: "/stable/historical-chart/\(interval)",
            query: query,
            on: req
        )
    }

    func stockHistoricalEOD(
        symbol rawSymbol: String,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [CryptoHistoricalLightPoint] {
        let symbol = try normalizeSymbol(rawSymbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from {
            query.append(("from", from))
        }
        if let to {
            query.append(("to", to))
        }
        return try await fetchJSON(
            path: "/stable/historical-price-eod/light",
            query: query,
            on: req
        )
    }
}

private extension LiveFMPMarketDataProvider {
    func fetchJSON<ResponseBody: Decodable>(
        path: String,
        query: [(String, String?)],
        on req: Request
    ) async throws -> ResponseBody {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.serviceUnavailable, reason: "FMP_API_KEY is not configured.")
        }

        let uri = try makeURI(path: path, query: query)
        let response = try await req.client.get(uri) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(30)
        }

        switch response.status {
        case .ok:
            do {
                return try response.content.decode(ResponseBody.self)
            } catch {
                throw Abort(.badGateway, reason: "Failed to decode FMP response for \(path).")
            }

        case .notFound:
            throw Abort(.notFound, reason: "No market data found for this symbol.")

        case .unauthorized, .forbidden:
            let body = extractResponseBody(response)
            let maskedApiKey =
                apiKey.count > 4
                    ? String(repeating: "*", count: apiKey.count - 4) + apiKey.suffix(4)
                    : "****"
            req.logger.error(
                "FMP rejected the request. status=\(response.status.code) url=\(uri) apiKeyLength=\(apiKey.count) maskedKey=\(maskedApiKey) response=\(body)"
            )
            throw Abort(.badGateway, reason: "Market data isn’t available right now. Please try again later.")

        case .paymentRequired:
            let body = extractResponseBody(response)
            req.logger.warning(
                "FMP coverage/subscription limit for \(path). status=\(response.status.code) response=\(body)"
            )
            throw Abort(
                .paymentRequired,
                reason: "Chart data isn’t available for this symbol right now. Try another symbol or check back later."
            )

        default:
            let body = extractResponseBody(response)
            req.logger.error(
                "FMP request failed for \(path). status=\(response.status.code) response=\(body)"
            )
            throw Abort(
                .badGateway,
                reason: "Market data isn’t available for this symbol right now. Please try again later."
            )
        }
    }

    func makeURI(path: String, query: [(String, String?)]) throws -> URI {
        let trimmedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmedBaseURL + path) else {
            throw Abort(.internalServerError, reason: "Invalid FMP base URL configuration.")
        }

        var queryItems = query.compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        queryItems.append(URLQueryItem(name: "apikey", value: apiKey))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Unable to build FMP request URL.")
        }

        return URI(string: url.absoluteString)
    }

    func normalizeSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return normalized
    }

    func normalizeRequiredValue(_ raw: String, field: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "\(field.capitalized) is required.")
        }
        return normalized
    }

    func normalizedOptionalValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    func extractResponseBody(_ response: ClientResponse) -> String {
        response.body
            .flatMap { buffer in
                buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
            }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func fetchTranscriptAvailability(symbol: String, on req: Request) async throws
        -> Set<TranscriptAvailabilityKey>
    {
        let items: [FMPTranscriptDateItem] = try await fetchJSON(
            path: "/stable/earning-call-transcript-dates",
            query: [("symbol", symbol)],
            on: req
        )

        return Set(items.map { item in
            TranscriptAvailabilityKey(
                date: normalizedDateOnly(item.date),
                year: item.year,
                quarter: item.quarter
            )
        })
    }

    func resolveTranscriptPeriod(
        symbol: String,
        date rawDate: String?,
        year rawYear: Int?,
        quarter rawQuarter: Int?,
        on req: Request
    ) async throws -> (date: String?, year: Int, quarter: Int) {
        if let rawYear, let rawQuarter {
            try validateTranscriptQuarter(rawQuarter)
            return (normalizedDateOnly(rawDate), rawYear, rawQuarter)
        }

        guard let date = normalizedDateOnly(rawDate) else {
            throw Abort(.badRequest, reason: "Query parameter `date` is required unless `year` and `quarter` are provided.")
        }

        let availability = try await fetchTranscriptAvailability(symbol: symbol, on: req)
        let exact = availability.first { $0.date == date && $0.year != nil && $0.quarter != nil }
        if let exact, let year = exact.year, let quarter = exact.quarter {
            try validateTranscriptQuarter(quarter)
            return (date, year, quarter)
        }

        let fallback = transcriptAvailabilityKey(for: date)
        guard let year = fallback.year, let quarter = fallback.quarter else {
            throw Abort(.badRequest, reason: "Invalid date. Expected YYYY-MM-DD.")
        }
        try validateTranscriptQuarter(quarter)
        return (date, year, quarter)
    }

    func validateTranscriptQuarter(_ quarter: Int) throws {
        guard (1 ... 4).contains(quarter) else {
            throw Abort(.badRequest, reason: "Query parameter `quarter` must be between 1 and 4.")
        }
    }

    func transcriptAvailabilityKey(for rawDate: String) -> TranscriptAvailabilityKey {
        let normalizedDate = normalizedDateOnly(rawDate)
        return TranscriptAvailabilityKey(
            date: normalizedDate,
            year: normalizedDate.flatMap(yearComponent),
            quarter: normalizedDate.flatMap(quarterComponent)
        )
    }

    func normalizedDateOnly(_ rawDate: String?) -> String? {
        guard let rawDate else { return nil }
        let trimmed = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(10))
    }

    func yearComponent(from isoDate: String) -> Int? {
        let parts = isoDate.split(separator: "-")
        guard let yearPart = parts.first else { return nil }
        return Int(yearPart)
    }

    func quarterComponent(from isoDate: String) -> Int? {
        let parts = isoDate.split(separator: "-")
        guard parts.count >= 2, let month = Int(parts[1]) else { return nil }
        return ((month - 1) / 3) + 1
    }

    func makeEarningsSurprisePercent(actual: Double?, estimate: Double?) -> Double? {
        guard let actual, let estimate, estimate != 0 else { return nil }
        return ((actual - estimate) / abs(estimate)) * 100
    }

    func hasTranscriptAvailability(
        for eventKey: TranscriptAvailabilityKey,
        in availability: Set<TranscriptAvailabilityKey>
    ) -> Bool {
        if availability.contains(eventKey) {
            return true
        }

        if let date = eventKey.date,
           availability.contains(.init(date: date, year: nil, quarter: nil))
        {
            return true
        }

        if let year = eventKey.year, let quarter = eventKey.quarter,
           availability.contains(.init(date: nil, year: year, quarter: quarter))
        {
            return true
        }

        return false
    }
}
