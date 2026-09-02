import Foundation
import Vapor

/// Defaults keep pre-existing MarketDataService conformers (test stubs)
/// compiling; DefaultMarketDataService overrides with the real assembly.
extension MarketDataService {
    func periodReturns(symbol _: String, on _: Request) async throws -> StockPeriodReturnsResponse {
        throw Abort(.serviceUnavailable, reason: "Period returns are not supported by this provider.")
    }

    func periodReturnsBatch(symbols _: [String], on _: Request) async throws -> StockPeriodReturnsBatchResponse {
        throw Abort(.serviceUnavailable, reason: "Period returns are not supported by this provider.")
    }
}

enum PeriodReturnsConfig {
    static let batchLimit = 20

    static func redisKey(_ symbol: String) -> String {
        "market:returns:fmp:\(symbol)"
    }
}

extension DefaultMarketDataService {
    func periodReturns(symbol rawSymbol: String, on req: Request) async throws -> StockPeriodReturnsResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        return await loadPeriodReturns(symbol: symbol, on: req)
    }

    func periodReturnsBatch(symbols rawSymbols: [String], on req: Request) async throws
        -> StockPeriodReturnsBatchResponse
    {
        var seen: Set<String> = []
        let normalized = try rawSymbols
            .map(normalizeSymbol)
            .filter { seen.insert($0).inserted }

        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }
        guard normalized.count <= PeriodReturnsConfig.batchLimit else {
            throw Abort(
                .badRequest,
                reason: "Period-returns batch supports at most \(PeriodReturnsConfig.batchLimit) symbols."
            )
        }

        let application = req.application
        var indexed: [(Int, StockPeriodReturnsResponse)] = []
        indexed.reserveCapacity(normalized.count)

        try await withThrowingTaskGroup(of: (Int, StockPeriodReturnsResponse).self) { group in
            for (index, symbol) in normalized.enumerated() {
                group.addTask {
                    let childRequest = Request(
                        application: application,
                        on: application.eventLoopGroup.next()
                    )
                    let result = await loadPeriodReturns(symbol: symbol, on: childRequest)
                    return (index, result)
                }
            }
            for try await pair in group {
                indexed.append(pair)
            }
        }

        let returns = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        return StockPeriodReturnsBatchResponse(returns: returns)
    }

    func loadPeriodReturns(symbol: String, on req: Request) async -> StockPeriodReturnsResponse {
        let cacheKey = PeriodReturnsConfig.redisKey(symbol)
        if let cached = await redisGetValue(cacheKey, as: StockPeriodReturnsResponse.self, on: req) {
            return cached
        }

        guard let fmp = fmpProvider else {
            req.logger.warning("market.returns missing_fmp symbol=\(symbol)")
            return emptyPeriodReturns(symbol: symbol)
        }

        do {
            let items = try await fmp.stockPriceChange(symbol: symbol, on: req)
            let mapped = items.first.map(mapFMPPriceChange) ?? emptyPeriodReturns(symbol: symbol)
            let response = StockPeriodReturnsResponse(
                symbol: symbol,
                threeMonth: mapped.threeMonth,
                sixMonth: mapped.sixMonth,
                yearToDate: mapped.yearToDate,
                asOf: mapped.asOf
            )
            guard response.hasUsableWindows else {
                req.logger.warning("market.returns skip_cache empty symbol=\(symbol)")
                return response
            }
            await redisSetValue(
                cacheKey,
                value: response,
                ttlSeconds: cacheConfig.historyTTLSeconds,
                on: req
            )
            return response
        } catch {
            req.logger.warning(
                "market.returns degraded symbol=\(symbol) error=\(error.localizedDescription)"
            )
            return emptyPeriodReturns(symbol: symbol)
        }
    }
}
