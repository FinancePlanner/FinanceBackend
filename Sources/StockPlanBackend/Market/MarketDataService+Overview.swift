import Foundation
import Vapor

/// Defaults keep pre-existing MarketDataService conformers (test stubs)
/// compiling; DefaultMarketDataService overrides with the real assembly.
extension MarketDataService {
    func marketOverview(on _: Request) async throws -> MarketOverviewResponse {
        throw Abort(.serviceUnavailable, reason: "Market overview is not supported by this provider.")
    }
}

/// Static index → ETF-proxy mapping. The caret index symbols require an FMP
/// starter+ tier; the ETFs are on the free-tier whitelist, so the strip
/// degrades to proxies (marked `isProxy`) instead of disappearing.
private let marketOverviewIndices: [(index: String, proxy: String, label: String)] = [
    ("^DJI", "DIA", "Dow Jones"),
    ("^GSPC", "SPY", "S&P 500"),
    ("^IXIC", "QQQ", "Nasdaq"),
    ("^RUT", "IWM", "Russell 2000"),
]

private enum MarketOverviewCache {
    static let freshKey = "market:overview:v1"
    static let staleKey = "market:overview:v1:stale"
    static let universeKey = "market:overview:universe:v1"

    static let freshTTL = Environment.get("MARKET_OVERVIEW_TTL_SECONDS").flatMap(Int.init(_:)) ?? 60
    static let staleTTL = 86400
    static let universeTTL = Environment.get("MARKET_OVERVIEW_UNIVERSE_TTL_SECONDS").flatMap(Int.init(_:)) ?? 3600
    static let universeLimit = 150
    static let moverLimit = 15
}

extension DefaultMarketDataService {
    func marketOverview(on req: Request) async throws -> MarketOverviewResponse {
        if let cached = await redisGetValue(MarketOverviewCache.freshKey, as: MarketOverviewResponse.self, on: req) {
            return cached
        }

        guard let fmp = fmpProvider else {
            if let stale = await redisGetValue(MarketOverviewCache.staleKey, as: MarketOverviewResponse.self, on: req) {
                return stale
            }
            throw Abort(.serviceUnavailable, reason: "Market overview requires the FMP provider.")
        }

        async let indicesTask = loadOverviewIndices(fmp: fmp, on: req)
        async let gainersTask = loadOverviewMovers(fmp: fmp, kind: .gainers, on: req)
        async let losersTask = loadOverviewMovers(fmp: fmp, kind: .losers, on: req)
        async let heatmapTask = loadOverviewHeatmap(fmp: fmp, on: req)

        let response = await MarketOverviewResponse(
            indices: indicesTask,
            gainers: gainersTask,
            losers: losersTask,
            heatmap: heatmapTask,
            asOf: ISO8601DateFormatter().string(from: Date())
        )

        let isEmpty = response.indices.isEmpty && response.gainers.isEmpty
            && response.losers.isEmpty && response.heatmap.isEmpty
        if isEmpty {
            if let stale = await redisGetValue(MarketOverviewCache.staleKey, as: MarketOverviewResponse.self, on: req) {
                req.logger.warning("market.overview total failure; serving stale snapshot")
                return stale
            }
            throw Abort(.badGateway, reason: "Market overview is temporarily unavailable.")
        }

        await redisSetValue(MarketOverviewCache.freshKey, value: response, ttlSeconds: MarketOverviewCache.freshTTL, on: req)
        await redisSetValue(MarketOverviewCache.staleKey, value: response, ttlSeconds: MarketOverviewCache.staleTTL, on: req)
        return response
    }

    private func loadOverviewIndices(fmp: any FMPMarketDataProvider, on req: Request) async -> [MarketIndexQuote] {
        // Caret symbols only work on starter+ tiers; on free go straight to proxies.
        if fmpAccessTier != .free {
            let carets = marketOverviewIndices.map(\.index)
            if let quotes = try? await fmp.fetchStockQuotes(symbols: carets, on: req), !quotes.isEmpty {
                let bySymbol = Dictionary(uniqueKeysWithValues: quotes.map { ($0.symbol.uppercased(), $0) })
                let mapped = marketOverviewIndices.compactMap { entry -> MarketIndexQuote? in
                    guard let quote = bySymbol[entry.index.uppercased()] else { return nil }
                    return MarketIndexQuote(
                        symbol: entry.index,
                        label: entry.label,
                        price: quote.price,
                        changePct: quote.changePercentage,
                        isProxy: false
                    )
                }
                if !mapped.isEmpty {
                    return mapped
                }
            }
            req.logger.warning("market.overview index quotes failed; falling back to ETF proxies")
        }

        let proxies = marketOverviewIndices.map(\.proxy)
        guard let quotes = try? await fmp.fetchStockQuotes(symbols: proxies, on: req), !quotes.isEmpty else {
            req.logger.warning("market.overview proxy index quotes failed; hiding index strip")
            return []
        }
        let bySymbol = Dictionary(uniqueKeysWithValues: quotes.map { ($0.symbol.uppercased(), $0) })
        return marketOverviewIndices.compactMap { entry -> MarketIndexQuote? in
            guard let quote = bySymbol[entry.proxy.uppercased()] else { return nil }
            return MarketIndexQuote(
                symbol: entry.proxy,
                label: entry.label,
                price: quote.price,
                changePct: quote.changePercentage,
                isProxy: true
            )
        }
    }

    private enum OverviewMoverKind: String {
        case gainers
        case losers
    }

    private func loadOverviewMovers(
        fmp: any FMPMarketDataProvider,
        kind: OverviewMoverKind,
        on req: Request
    ) async -> [MarketMover] {
        do {
            let items: [FMPMoverItem] = switch kind {
            case .gainers: try await fmp.fetchBiggestGainers(on: req)
            case .losers: try await fmp.fetchBiggestLosers(on: req)
            }
            return items.prefix(MarketOverviewCache.moverLimit).compactMap { item -> MarketMover? in
                guard let price = item.price, let changePct = item.changesPercentage else { return nil }
                return MarketMover(
                    symbol: item.symbol,
                    name: item.name ?? item.symbol,
                    price: price,
                    changePct: changePct
                )
            }
        } catch {
            req.logger.warning("market.overview \(kind.rawValue) failed error=\(error)")
            return []
        }
    }

    private func loadOverviewHeatmap(fmp: any FMPMarketDataProvider, on req: Request) async -> [MarketHeatmapTile] {
        let universe: [FMPScreenerItem]
        if let cached = await redisGetValue(MarketOverviewCache.universeKey, as: [FMPScreenerItem].self, on: req) {
            universe = cached
        } else {
            do {
                // Screener sort order is not guaranteed; sort by cap defensively.
                let fetched = try await fmp.fetchTopMarketCapUniverse(limit: MarketOverviewCache.universeLimit, on: req)
                universe = fetched
                    .filter { ($0.marketCap ?? 0) > 0 }
                    .sorted { ($0.marketCap ?? 0) > ($1.marketCap ?? 0) }
                await redisSetValue(MarketOverviewCache.universeKey, value: universe, ttlSeconds: MarketOverviewCache.universeTTL, on: req)
            } catch {
                req.logger.warning("market.overview screener failed error=\(error)")
                return []
            }
        }
        guard !universe.isEmpty else { return [] }

        do {
            let quotes = try await fmp.fetchStockQuotes(symbols: universe.map(\.symbol), on: req)
            let bySymbol = Dictionary(uniqueKeysWithValues: quotes.map { ($0.symbol.uppercased(), $0) })
            return universe.compactMap { item -> MarketHeatmapTile? in
                guard let marketCap = item.marketCap, marketCap > 0 else { return nil }
                guard let quote = bySymbol[item.symbol.uppercased()] else { return nil }
                return MarketHeatmapTile(
                    symbol: item.symbol,
                    name: item.companyName ?? item.symbol,
                    sector: normalizedSector(item.sector),
                    marketCap: marketCap,
                    changePct: quote.changePercentage
                )
            }
        } catch {
            req.logger.warning("market.overview heatmap quotes failed error=\(error)")
            return []
        }
    }

    private func normalizedSector(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Other" : trimmed
    }
}
