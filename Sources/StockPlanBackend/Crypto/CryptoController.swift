import Foundation
import StockPlanShared
import Vapor

struct CryptoController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.cryptoRead)).grouped("crypto")
        let write = protected.grouped(ScopeRequirementMiddleware(.cryptoWrite)).grouped("crypto")

        // Market data endpoints
        read.get("list", use: cryptocurrencyList)
        read.get("quote", ":symbol", use: quote)
        read.get("quote-short", ":symbol", use: quoteShort)
        read.get("batch-quotes", use: batchQuotes)
        read.get("history", ":resolution", ":symbol", use: history)
        read.get("news", use: generalNews)
        read.get("news", ":symbol", use: news)

        // Portfolio CRUD
        read.get("portfolio", use: listPortfolio)
        write.group("portfolio") { portfolio in
            portfolio.post(use: addToPortfolio)
            portfolio.group(":itemId") { item in
                item.put(use: updatePortfolioItem)
                item.delete(use: removeFromPortfolio)
            }
        }
    }

    // MARK: - Market Data

    @Sendable
    func cryptocurrencyList(req: Request) async throws -> [CryptoAssetResponse] {
        _ = try await requireCryptoEntitlement(req)
        return try await req.application.cryptoService.cryptocurrencyList(on: req)
    }

    @Sendable
    func quote(req: Request) async throws -> [CryptoQuoteResponse] {
        _ = try await requireCryptoEntitlement(req)
        let symbol = try requireSymbol(req)
        return try await req.application.cryptoService.quote(symbols: symbol, on: req)
    }

    @Sendable
    func quoteShort(req: Request) async throws -> [CryptoQuoteShortResponse] {
        _ = try await requireCryptoEntitlement(req)
        let symbol = try requireSymbol(req)
        return try await req.application.cryptoService.quoteShort(symbol: symbol, on: req)
    }

    @Sendable
    func batchQuotes(req: Request) async throws -> [CryptoQuoteShortResponse] {
        _ = try await requireCryptoEntitlement(req)
        let short = req.query[Bool.self, at: "short"] ?? false
        return try await req.application.cryptoService.batchQuotes(short: short, on: req)
    }

    @Sendable
    func history(req: Request) async throws -> [CryptoHistoricalPoint] {
        _ = try await requireCryptoEntitlement(req)
        let symbol = try requireSymbol(req)
        let resolution = try req.parameters.require("resolution")
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]

        switch resolution {
        case "1min":
            return try await req.application.cryptoService.intraday1min(symbol: symbol, from: from, to: to, on: req)
        case "5min":
            return try await req.application.cryptoService.intraday5min(symbol: symbol, from: from, to: to, on: req)
        case "1hour":
            return try await req.application.cryptoService.intraday1hour(symbol: symbol, from: from, to: to, on: req)
        case "light":
            let points = try await req.application.cryptoService.historicalLight(symbol: symbol, from: from, to: to, on: req)
            return points.map { CryptoHistoricalPoint(date: $0.date, close: $0.price, volume: $0.volume) }
        case "full":
            let points = try await req.application.cryptoService.historicalFull(symbol: symbol, from: from, to: to, on: req)
            return points.map { CryptoHistoricalPoint(date: $0.date, open: $0.open, low: $0.low, high: $0.high, close: $0.close, volume: $0.volume) }
        default:
            throw Abort(.badRequest, reason: "Invalid resolution.")
        }
    }

    @Sendable
    func generalNews(req: Request) async throws -> [StockNews] {
        _ = try await requireCryptoEntitlement(req)
        let page = req.query[Int.self, at: "page"]
        let limit = req.query[Int.self, at: "limit"]
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]

        let items = try await req.application.cryptoService.fetchCryptoNews(
            symbol: nil,
            page: page,
            limit: limit,
            from: from,
            to: to,
            on: req
        )

        return items.map { item in
            StockNews(
                title: item.title ?? "No Title",
                url: item.url ?? "",
                date: item.publishedDate ?? "",
                imageURL: item.image,
                source: item.publisher ?? item.site,
                summary: item.text
            )
        }
    }

    @Sendable
    func news(req: Request) async throws -> [StockNews] {
        _ = try await requireCryptoEntitlement(req)
        let symbol = try requireSymbol(req)
        let page = req.query[Int.self, at: "page"]
        let limit = req.query[Int.self, at: "limit"]
        let from = req.query[String.self, at: "from"]
        let to = req.query[String.self, at: "to"]

        let items = try await req.application.cryptoService.fetchCryptoNews(
            symbol: symbol,
            page: page,
            limit: limit,
            from: from,
            to: to,
            on: req
        )

        return items.map { item in
            StockNews(
                title: item.title ?? "No Title",
                url: item.url ?? "",
                date: item.publishedDate ?? "",
                imageURL: item.image,
                source: item.publisher ?? item.site,
                summary: item.text
            )
        }
    }

    // MARK: - Portfolio

    @Sendable
    func listPortfolio(req: Request) async throws -> [CryptoPortfolioItemResponse] {
        let session = try await requireCryptoEntitlement(req)
        return try await req.application.cryptoService.listPortfolio(
            userId: session.userId, on: req.db
        )
    }

    @Sendable
    func addToPortfolio(req: Request) async throws -> Response {
        let session = try await requireCryptoEntitlement(req)
        let payload = try req.content.decode(CryptoPortfolioItemRequest.self)
        let created = try await req.application.cryptoService.addToPortfolio(
            payload: payload, userId: session.userId, on: req.db
        )
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updatePortfolioItem(req: Request) async throws -> CryptoPortfolioItemResponse {
        let session = try await requireCryptoEntitlement(req)
        let itemId = try requireUUIDParameter(req, name: "itemId")
        let payload = try req.content.decode(CryptoPortfolioItemRequest.self)
        return try await req.application.cryptoService.updatePortfolioItem(
            id: itemId, payload: payload, userId: session.userId, on: req.db
        )
    }

    @Sendable
    func removeFromPortfolio(req: Request) async throws -> HTTPStatus {
        let session = try await requireCryptoEntitlement(req)
        let itemId = try requireUUIDParameter(req, name: "itemId")
        try await req.application.cryptoService.removeFromPortfolio(
            id: itemId, userId: session.userId, on: req.db
        )
        return .noContent
    }

    // MARK: - Helpers

    private func requireCryptoEntitlement(_ req: Request) async throws -> SessionToken {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.crypto, userId: session.userId, on: req.db)
        return session
    }

    private func requireSymbol(_ req: Request) throws -> String {
        if let querySymbol = req.query[String.self, at: "symbol"] {
            return querySymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let pathSymbol = req.parameters.get("symbol") {
            return pathSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw Abort(.badRequest, reason: "Symbol is required.")
    }

    private func requireUUIDParameter(_ req: Request, name: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid \(name).")
        }
        return value
    }
}
