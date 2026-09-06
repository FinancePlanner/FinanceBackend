import Fluent
import Foundation
import StockPlanShared
import Vapor

struct AssetsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped(ScopeRequirementMiddleware(.marketRead))
            .get("assets", "search", use: search)
    }

    @Sendable
    func search(req: Request) async throws -> [SearchResultResponse] {
        let session = try req.auth.require(SessionToken.self)
        guard let rawQuery = req.query[String.self, at: "q"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawQuery.isEmpty
        else {
            throw Abort(.badRequest, reason: "Missing query parameter `q`.")
        }

        let limit = min(max(req.query[Int.self, at: "limit"] ?? 20, 1), 50)
        let normalizedQuery = rawQuery.lowercased()

        let ownedStocks = try await Stock.query(on: req.db)
            .filter(\.$userId == session.userId)
            .all()
        let ownedBySymbol = Dictionary(
            uniqueKeysWithValues: ownedStocks.map { ($0.symbol.uppercased(), $0) }
        )
        let ownedSymbols = Set(ownedBySymbol.keys)

        var marketResults: [SearchResultResponse] = []
        var marketSearchError: (any Error)?
        do {
            marketResults = try await req.application.marketDataService.search(query: rawQuery, on: req)
        } catch {
            marketSearchError = error
            req.logger.warning("assets.search market fallback query=\(rawQuery) error=\(error.localizedDescription)")
        }

        let marketBySymbol = Dictionary(
            uniqueKeysWithValues: marketResults.map { ($0.symbol.uppercased(), $0) }
        )
        let marketMatchedOwnedSymbols = Set(marketBySymbol.keys).intersection(ownedSymbols)
        let locallyMatchedOwnedSymbols = Set(
            ownedStocks
                .filter {
                    $0.symbol.lowercased().contains(normalizedQuery) ||
                        ($0.notes?.lowercased().contains(normalizedQuery) ?? false)
                }
                .map { $0.symbol.uppercased() }
        )

        let matchedOwnedSymbols = locallyMatchedOwnedSymbols.union(marketMatchedOwnedSymbols)

        let ownedFirst = matchedOwnedSymbols.sorted { lhs, rhs in
            ownedSortKey(symbol: lhs, query: normalizedQuery) < ownedSortKey(symbol: rhs, query: normalizedQuery)
        }

        var merged: [SearchResultResponse] = []
        merged.reserveCapacity(limit)
        var seenSymbols = Set<String>()

        for symbol in ownedFirst where merged.count < limit {
            if let market = marketBySymbol[symbol] {
                merged.append(
                    SearchResultResponse(
                        symbol: market.symbol,
                        name: market.name,
                        exchange: market.exchange,
                        currency: market.currency,
                        conid: market.conid
                    )
                )
            } else if let owned = ownedBySymbol[symbol] {
                merged.append(
                    SearchResultResponse(
                        symbol: symbol,
                        name: "\(symbol) - owned asset",
                        exchange: "PORTFOLIO",
                        currency: "USD",
                        conid: "owned-\(owned.id?.uuidString ?? symbol)"
                    )
                )
            }
            seenSymbols.insert(symbol)
        }

        for item in marketResults where merged.count < limit {
            let symbol = item.symbol.uppercased()
            guard !seenSymbols.contains(symbol) else { continue }
            merged.append(item)
            seenSymbols.insert(symbol)
        }

        if merged.isEmpty, let marketSearchError {
            throw marketSearchError
        }

        return merged
    }

    private func ownedSortKey(symbol: String, query: String) -> (Int, String) {
        let symbolLower = symbol.lowercased()
        if symbolLower == query {
            return (0, symbol)
        }
        if symbolLower.hasPrefix(query) {
            return (1, symbol)
        }
        if symbolLower.contains(query) {
            return (2, symbol)
        }
        return (3, symbol)
    }
}
