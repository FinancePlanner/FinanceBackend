import Fluent
import Foundation
import Vapor

struct StockController: RouteCollection {
    private struct StocksListQuery: Content {
        let portfolioListId: String?
        let limit: Int?
        let cursor: String? // ISO8601 timestamp for keyset pagination
    }

    func boot(routes: any RoutesBuilder) throws {
        // ScopedBearerAuthenticator accepts a first-party session JWT *or* an opaque
        // PAT/OAuth token, logging in a synthesised SessionToken either way, so every
        // handler below is unchanged. ScopeRequirementMiddleware is a no-op for
        // first-party sessions, which carry no ScopeContext.
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())

        let holdingsRead = protected.grouped(ScopeRequirementMiddleware(.holdingsRead))
        let holdingsWrite = protected.grouped(ScopeRequirementMiddleware(.holdingsWrite))

        let stocksRead = holdingsRead.grouped("stocks")
        let stocksWrite = holdingsWrite.grouped("stocks")
        stocksRead.get(use: listStocks)
        stocksWrite.post(use: createStock)
        stocksWrite.post("bulk", use: bulkCreateStocks)

        // Symbol-based routes (use explicit "symbol" prefix to avoid conflicts)
        stocksRead.get("symbol", ":symbol", "insights", use: getStockInsights)
        // Backward-compatible route retained for clients/contracts using /v1/stocks/{symbol}/insights.
        stocksRead.get(":symbol", "insights", use: getStockInsights)
        stocksRead.get("symbol", ":symbol", "valuation", use: getStockValuation)
        stocksWrite.group("symbol", ":symbol", "valuation") { valuation in
            valuation.post(use: createStockValuation)
            valuation.put(use: updateStockValuation)
        }

        // ID-based routes (use explicit "id" prefix to avoid conflicts)
        stocksRead.get("id", ":stockId", use: getStock)
        stocksWrite.group("id", ":stockId") { stock in
            stock.put(use: updateStock)
            stock.post("sell", use: sellStock)
            stock.delete(use: deleteStock)
        }

        let watchlistRead = protected.grouped(ScopeRequirementMiddleware(.watchlistRead)).grouped("watchlist")
        let watchlistWrite = protected.grouped(ScopeRequirementMiddleware(.watchlistWrite)).grouped("watchlist")
        watchlistRead.get(use: listWatchlist)
        watchlistWrite.post(use: createWatchlistItem)
        watchlistWrite.post("import", "csv", "preview", use: importWatchlistCsvPreview)
        watchlistWrite.post("import", "csv", "commit", use: importWatchlistCsvCommit)
        watchlistRead.get("lists", use: listWatchlistLists)
        watchlistWrite.group("lists") { lists in
            lists.post(use: createWatchlistList)
            lists.group(":watchlistListId") { list in
                list.patch(use: updateWatchlistList)
                list.delete(use: deleteWatchlistList)
            }
        }
        watchlistWrite.group(":watchlistId") { item in
            item.patch(use: updateWatchlistItem)
            item.delete(use: deleteWatchlistItem)
        }

        let researchRead = protected.grouped(ScopeRequirementMiddleware(.researchRead)).grouped("research")
        let researchWrite = protected.grouped(ScopeRequirementMiddleware(.researchWrite)).grouped("research")
        researchRead.get(use: listResearch)
        researchWrite.post(use: createResearch)
        researchRead.get(":researchId", use: getResearch)
        researchWrite.group(":researchId") { note in
            note.put(use: updateResearch)
            note.delete(use: deleteResearch)
        }

        let targetsRead = protected.grouped(ScopeRequirementMiddleware(.targetsRead)).grouped("targets")
        let targetsWrite = protected.grouped(ScopeRequirementMiddleware(.targetsWrite)).grouped("targets")
        targetsRead.get(use: listTargets)
        targetsWrite.post(use: createTarget)
        targetsWrite.group(":targetId") { target in
            target.put(use: updateTarget)
            target.delete(use: deleteTarget)
        }
    }

    @Sendable
    func listStocks(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(StocksListQuery.self)
        let portfolioListId = try await resolvePortfolioListId(
            requestedId: query.portfolioListId,
            userId: session.userId,
            on: req.db,
            defaultWhenMissing: true
        )
        let cursor = StockListCursor.parse(query.cursor)

        let limit = clampedLimit(query.limit)
        let result = try await req.stocksService.list(
            userId: session.userId,
            portfolioListId: portfolioListId,
            limit: limit,
            cursor: cursor,
            on: req.db
        )

        // Build response with potential pagination header
        var response = Response(status: .ok)
        if let nextCursor = result.nextCursor {
            response.headers.add(name: "X-Next-Cursor", value: nextCursor)
        }
        let listItems = result.items.map { StockListItem(from: $0) }
        try response.content.encode(listItems)
        return response
    }

    @Sendable
    func createStock(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(StockRequest.self)
        let created = try await req.stocksService.create(
            payload: payload, userId: session.userId, on: req.db
        )
        // Business metric: stocks created
        req.application.businessMetrics.incrementStocksCreated()
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func bulkCreateStocks(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(BulkStockRequest.self)
        let result = try await req.stocksService.bulkCreate(
            payloads: payload.stocks, userId: session.userId, on: req.db
        )
        let res = Response(status: .ok)
        try res.content.encode(result)
        return res
    }

    @Sendable
    func getStock(req: Request) async throws -> StockResponse {
        let session = try req.auth.require(SessionToken.self)
        let stockId = try requireUUIDParameter(req, name: "stockId", reason: "Invalid stock ID")
        return try await req.stocksService.get(
            id: stockId, userId: session.userId, on: req.db
        )
    }

    @Sendable
    func updateStock(req: Request) async throws -> StockResponse {
        let session = try req.auth.require(SessionToken.self)
        let stockId = try requireUUIDParameter(req, name: "stockId", reason: "Invalid stock ID")
        let payload = try req.content.decode(StockRequest.self)
        return try await req.stocksService.update(
            id: stockId, payload: payload, userId: session.userId, on: req.db
        )
    }

    @Sendable
    func getStockInsights(req: Request) async throws -> StockInsightsResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .advancedResearch,
            userId: session.userId,
            on: req.db
        )
        let symbol = try requireStringParameter(req, name: "symbol", reason: "Invalid stock symbol")
        return try await req.stocksService.getInsights(
            symbol: symbol,
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func deleteStock(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let stockId = try requireUUIDParameter(req, name: "stockId", reason: "Invalid stock ID")
        try await req.stocksService.delete(
            id: stockId, userId: session.userId, on: req.db
        )
        return .noContent
    }

    @Sendable
    func sellStock(req: Request) async throws -> StockResponse {
        let session = try req.auth.require(SessionToken.self)
        let stockId = try requireUUIDParameter(req, name: "stockId", reason: "Invalid stock ID")
        let payload = try req.content.decode(SellStockRequest.self)
        return try await req.stocksService.sell(
            id: stockId, payload: payload, userId: session.userId, on: req.db
        )
    }

    @Sendable
    func getStockValuation(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .valuationCases,
            userId: session.userId,
            on: req.db
        )
        let symbol = try requireStringParameter(req, name: "symbol", reason: "Invalid stock symbol")
        do {
            let valuation = try await req.stocksService.getValuation(
                symbol: symbol,
                userId: session.userId,
                on: req.db
            )
            let res = Response(status: .ok)
            try res.content.encode(valuation)
            return res
        } catch let error as StockServiceError {
            switch error {
            case .notFound, .valuationNotFound:
                return Response(status: .notFound)
            case .invalidSymbol, .valuationAlreadyExists:
                throw error
            }
        }
    }

    @Sendable
    func createStockValuation(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .valuationCases,
            userId: session.userId,
            on: req.db
        )
        let symbol = try requireStringParameter(req, name: "symbol", reason: "Invalid stock symbol")
        let payload = try req.content.decode(StockValuationRequest.self)
        req.logger.debug(
            """
            stock.valuation.create routeSymbol=\(String(reflecting: symbol)) \
            bodySymbol=\(String(reflecting: payload.symbol)) \
            userId=\(session.userId.uuidString)
            """
        )
        let created = try await req.stocksService.createValuation(
            symbol: symbol,
            payload: payload,
            userId: session.userId,
            on: req.db
        )
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updateStockValuation(req: Request) async throws -> StockValuationRequest {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .valuationCases,
            userId: session.userId,
            on: req.db
        )
        let symbol = try requireStringParameter(req, name: "symbol", reason: "Invalid stock symbol")
        let payload = try req.content.decode(StockValuationRequest.self)
        req.logger.debug(
            """
            stock.valuation.update routeSymbol=\(String(reflecting: symbol)) \
            bodySymbol=\(String(reflecting: payload.symbol)) \
            userId=\(session.userId.uuidString)
            """
        )
        return try await req.stocksService.updateValuation(
            symbol: symbol,
            payload: payload,
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func listResearch(req: Request) async throws -> [ResearchNoteResponse] {
        let session = try req.auth.require(SessionToken.self)
        let symbolFilter = req.query[String.self, at: "symbol"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        let query = ResearchNote.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)

        if let symbolFilter, !symbolFilter.isEmpty {
            query.filter(\.$symbol == symbolFilter)
        }

        query.limit(clampedLimit(req.query[Int.self, at: "limit"]))
        let notes = try await query.all()

        return try notes.map(makeResearchNoteResponse)
    }

    @Sendable
    func createResearch(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(ResearchNoteRequest.self)

        let note = try ResearchNote(
            userId: session.userId,
            symbol: normalizeSymbol(payload.symbol),
            title: emptyToNil(payload.title),
            thesis: requireNonEmpty(payload.thesis, field: "thesis"),
            risks: emptyToNil(payload.risks),
            catalysts: emptyToNil(payload.catalysts),
            referenceLinks: encodeReferenceLinks(payload.referenceLinks)
        )
        try await note.save(on: req.db)

        let created = try makeResearchNoteResponse(from: note)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func getResearch(req: Request) async throws -> ResearchNoteResponse {
        let session = try req.auth.require(SessionToken.self)
        let researchId = try requireUUIDParameter(
            req, name: "researchId", reason: "Invalid research ID"
        )

        guard
            let note = try await ResearchNote.query(on: req.db)
            .filter(\.$id == researchId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Research note not found.")
        }

        return try makeResearchNoteResponse(from: note)
    }

    @Sendable
    func updateResearch(req: Request) async throws -> ResearchNoteResponse {
        let session = try req.auth.require(SessionToken.self)
        let researchId = try requireUUIDParameter(
            req, name: "researchId", reason: "Invalid research ID"
        )
        let payload = try req.content.decode(ResearchNoteRequest.self)

        guard
            let note = try await ResearchNote.query(on: req.db)
            .filter(\.$id == researchId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Research note not found.")
        }

        note.symbol = try normalizeSymbol(payload.symbol)
        note.title = emptyToNil(payload.title)
        note.thesis = try requireNonEmpty(payload.thesis, field: "thesis")
        note.risks = emptyToNil(payload.risks)
        note.catalysts = emptyToNil(payload.catalysts)
        note.referenceLinks = try encodeReferenceLinks(payload.referenceLinks)
        try await note.save(on: req.db)

        return try makeResearchNoteResponse(from: note)
    }

    @Sendable
    func deleteResearch(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let researchId = try requireUUIDParameter(
            req, name: "researchId", reason: "Invalid research ID"
        )

        guard
            let note = try await ResearchNote.query(on: req.db)
            .filter(\.$id == researchId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Research note not found.")
        }

        try await note.delete(on: req.db)
        return .noContent
    }

    @Sendable
    func listTargets(req: Request) async throws -> [TargetResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .targetAlerts,
            userId: session.userId,
            on: req.db
        )
        let symbolFilter = req.query[String.self, at: "symbol"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()

        let query = Target.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)

        if let symbolFilter, !symbolFilter.isEmpty {
            query.filter(\.$symbol == symbolFilter)
        }

        query.limit(clampedLimit(req.query[Int.self, at: "limit"]))
        let targets = try await query.all()
        return try targets.map(makeTargetResponse)
    }

    @Sendable
    func createTarget(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .targetAlerts,
            userId: session.userId,
            on: req.db
        )
        let payload = try req.content.decode(TargetRequest.self)
        let currentCount = try await Target.query(on: req.db)
            .filter(\.$userId == session.userId)
            .count()
        try await req.usageCounterService.enforceResourceLimit(
            .targetAlerts,
            userId: session.userId,
            currentCount: currentCount,
            adding: 1,
            on: req.db
        )

        let target = try Target(
            userId: session.userId,
            symbol: normalizeSymbol(payload.symbol),
            scenario: normalizeScenario(payload.scenario),
            targetPrice: payload.targetPrice,
            targetDate: parseISODateOnly(payload.targetDate, field: "targetDate"),
            rationale: emptyToNil(payload.rationale),
            alertTriggeredAt: nil,
            alertTriggeredPrice: nil
        )
        try await target.save(on: req.db)
        // Business metric: targets created
        req.application.businessMetrics.incrementTargetsCreated()
        try? await req.usageCounterService.syncResourceCount(
            .targetAlerts,
            userId: session.userId,
            count: currentCount + 1,
            on: req.db
        )

        let created = try makeTargetResponse(from: target)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updateTarget(req: Request) async throws -> TargetResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .targetAlerts,
            userId: session.userId,
            on: req.db
        )
        let targetId = try requireUUIDParameter(req, name: "targetId", reason: "Invalid target ID")
        let payload = try req.content.decode(TargetRequest.self)

        guard
            let target = try await Target.query(on: req.db)
            .filter(\.$id == targetId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Target not found.")
        }

        target.symbol = try normalizeSymbol(payload.symbol)
        target.scenario = try normalizeScenario(payload.scenario)
        target.targetPrice = payload.targetPrice
        target.targetDate = try parseISODateOnly(payload.targetDate, field: "targetDate")
        target.rationale = emptyToNil(payload.rationale)
        target.alertTriggeredAt = nil
        target.alertTriggeredPrice = nil
        try await target.save(on: req.db)

        return try makeTargetResponse(from: target)
    }

    @Sendable
    func deleteTarget(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .targetAlerts,
            userId: session.userId,
            on: req.db
        )
        let targetId = try requireUUIDParameter(req, name: "targetId", reason: "Invalid target ID")

        guard
            let target = try await Target.query(on: req.db)
            .filter(\.$id == targetId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Target not found.")
        }

        try await target.delete(on: req.db)
        let updatedCount = try await Target.query(on: req.db)
            .filter(\.$userId == session.userId)
            .count()
        try? await req.usageCounterService.syncResourceCount(
            .targetAlerts,
            userId: session.userId,
            count: updatedCount,
            on: req.db
        )
        return .noContent
    }

    func requireUUIDParameter(_ req: Request, name: String, reason: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: reason)
        }
        return value
    }

    private func requireStringParameter(_ req: Request, name: String, reason: String) throws -> String {
        guard let raw = req.parameters.get(name) else {
            throw Abort(.badRequest, reason: reason)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: reason)
        }
        return trimmed
    }

    func normalizeSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return normalized
    }

    private func requireNonEmpty(_ raw: String, field: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "\(field) is required.")
        }
        return trimmed
    }

    func emptyToNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeScenario(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["bear", "base", "bull"].contains(normalized) else {
            throw Abort(.badRequest, reason: "scenario must be one of: bear, base, bull.")
        }
        return normalized
    }

    func parseISODateOnly(_ raw: String?, field: String) throws -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"

        guard let value = formatter.date(from: trimmed) else {
            throw Abort(.badRequest, reason: "Invalid \(field). Expected YYYY-MM-DD.")
        }
        return value
    }

    func formatISODateOnly(_ date: Date?) -> String? {
        guard let date else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func formatISODateTime(_ date: Date?) -> String? {
        guard let date else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func encodeReferenceLinks(_ links: [String]?) throws -> String? {
        guard let links else { return nil }

        let cleaned =
            links
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else { return nil }

        let data = try JSONEncoder().encode(cleaned)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeReferenceLinks(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private func makeResearchNoteResponse(from model: ResearchNote) throws -> ResearchNoteResponse {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Research note id missing.")
        }
        return ResearchNoteResponse(
            id: id.uuidString,
            symbol: model.symbol,
            title: model.title,
            thesis: model.thesis,
            risks: model.risks,
            catalysts: model.catalysts,
            referenceLinks: decodeReferenceLinks(model.referenceLinks)
        )
    }

    private func makeTargetResponse(from model: Target) throws -> TargetResponse {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Target id missing.")
        }
        return TargetResponse(
            id: id.uuidString,
            symbol: model.symbol,
            scenario: model.scenario,
            targetPrice: model.targetPrice,
            targetDate: formatISODateOnly(model.targetDate),
            rationale: model.rationale
        )
    }

    private func clampedLimit(_ rawLimit: Int?, default defaultValue: Int = 50, max maxValue: Int = 200) -> Int {
        max(1, min(rawLimit ?? defaultValue, maxValue))
    }
}
