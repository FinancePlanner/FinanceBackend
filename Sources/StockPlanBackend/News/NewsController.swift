import StockPlanShared
import Vapor

struct NewsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())

        // The feed is the one news read exposed to third-party tokens (the MCP
        // `get_news` tool, source=tracked). It takes the scoped authenticator so a
        // personal access token with market:read is accepted; every other news
        // route stays first-party JWT only, so a PAT can never create, edit, or
        // delete items regardless of its scopes.
        let scopedFeed = routes
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped("news")
            .grouped(ScopeRequirementMiddleware(.marketRead))
        scopedFeed.get("feed", use: feedNews)

        let news = protected.grouped("news")
        news.get(use: listNews)
        news.post(use: createNews)
        news.post("sync", use: syncNews)
        news.post("view", use: recordNewsView)
        news.get("thesis-watch", use: thesisWatchFeed)
        news.get("thesis-watch", "notifications", use: thesisWatchNotificationPreferences)
        news.put("thesis-watch", "notifications", use: updateThesisWatchNotificationPreferences)
        news.group("thesis-watch", ":storyId") { story in
            story.get(use: thesisWatchStory)
            story.post("feedback", use: thesisWatchFeedback)
            story.post("view", use: markThesisWatchStoryRead)
        }
        news.group(":newsId") { item in
            item.get(use: getNews)
            item.put(use: updateNews)
            item.delete(use: deleteNews)
        }
    }

    @Sendable
    func thesisWatchFeed(req: Request) async throws -> ThesisWatchFeedResponse {
        let session = try req.auth.require(SessionToken.self)
        let rawScope = req.query[String.self, at: "scope"] ?? ThesisWatchScope.forYou.rawValue
        guard let scope = ThesisWatchScope(rawValue: rawScope) else {
            throw Abort(.badRequest, reason: "Invalid Thesis Watch scope.")
        }
        return try await req.thesisWatchService.feed(
            userId: session.userId,
            scope: scope,
            sector: req.query[String.self, at: "sector"],
            limit: clampedLimit(req.query[Int.self, at: "limit"], default: 20, max: 50),
            cursor: req.query[String.self, at: "cursor"],
            on: req.db
        )
    }

    @Sendable
    func thesisWatchStory(req: Request) async throws -> ThesisWatchStory {
        let session = try req.auth.require(SessionToken.self)
        let storyId = try requireUUIDParameter(req, name: "storyId", reason: "Invalid story ID")
        return try await req.thesisWatchService.story(id: storyId, userId: session.userId, on: req.db)
    }

    @Sendable
    func thesisWatchFeedback(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let storyId = try requireUUIDParameter(req, name: "storyId", reason: "Invalid story ID")
        let payload = try req.content.decode(ThesisWatchFeedbackRequest.self)
        try await req.thesisWatchService.feedback(
            id: storyId,
            userId: session.userId,
            signal: payload.signal,
            on: req.db
        )
        return .noContent
    }

    @Sendable
    func markThesisWatchStoryRead(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let storyId = try requireUUIDParameter(req, name: "storyId", reason: "Invalid story ID")
        try await req.thesisWatchService.markRead(id: storyId, userId: session.userId, on: req.db)
        return .noContent
    }

    @Sendable
    func thesisWatchNotificationPreferences(req: Request) async throws -> ThesisWatchNotificationPreferences {
        let session = try req.auth.require(SessionToken.self)
        return try await req.thesisWatchService.notificationPreferences(userId: session.userId, on: req.db)
    }

    @Sendable
    func updateThesisWatchNotificationPreferences(req: Request) async throws -> ThesisWatchNotificationPreferences {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(UpdateThesisWatchNotificationPreferences.self)
        return try await req.thesisWatchService.updateNotificationPreferences(
            userId: session.userId,
            payload: payload,
            on: req.db
        )
    }

    @Sendable
    func listNews(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let symbol = req.query[String.self, at: "symbol"]
        let limit = clampedLimit(req.query[Int.self, at: "limit"])

        let cursor = NewsListCursor.parse(req.query[String.self, at: "cursor"])

        let result = try await req.application.newsService.list(userId: session.userId, symbol: symbol, limit: limit, cursor: cursor, on: req.db)

        var response = Response(status: .ok)
        try response.content.encode(result.items)
        if let nextCursor = result.nextCursor {
            response.headers.add(name: "X-Next-Cursor", value: nextCursor)
        }
        return response
    }

    @Sendable
    func feedNews(req: Request) async throws -> [NewsItemResponse] {
        let session = try req.auth.require(SessionToken.self)
        let limit = clampedLimit(req.query[Int.self, at: "limit"], default: 50)
        return try await req.application.newsService.feed(userId: session.userId, limit: limit, on: req.db)
    }

    @Sendable
    func createNews(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(NewsItemRequest.self)
        let created = try await req.application.newsService.create(payload: payload, userId: session.userId, on: req.db)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func getNews(req: Request) async throws -> NewsItemResponse {
        let session = try req.auth.require(SessionToken.self)
        let newsId = try requireUUIDParameter(req, name: "newsId", reason: "Invalid news ID")
        return try await req.application.newsService.get(id: newsId, userId: session.userId, on: req.db)
    }

    @Sendable
    func updateNews(req: Request) async throws -> NewsItemResponse {
        let session = try req.auth.require(SessionToken.self)
        let newsId = try requireUUIDParameter(req, name: "newsId", reason: "Invalid news ID")
        let payload = try req.content.decode(NewsItemRequest.self)
        return try await req.application.newsService.update(id: newsId, payload: payload, userId: session.userId, on: req.db)
    }

    @Sendable
    func deleteNews(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let newsId = try requireUUIDParameter(req, name: "newsId", reason: "Invalid news ID")
        try await req.application.newsService.delete(id: newsId, userId: session.userId, on: req.db)
        return .noContent
    }

    @Sendable
    func syncNews(req: Request) async throws -> NewsSyncResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.newsService.syncNews(userId: session.userId, on: req)
    }

    @Sendable
    func recordNewsView(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(NewsViewRequest.self)
        let headline = payload.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty else {
            throw Abort(.badRequest, reason: "headline is required.")
        }

        let symbol = payload.symbol?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let referenceKey = newsViewReferenceKey(payload: payload, headline: headline, symbol: symbol)

        try await req.userActivityService.recordActivity(
            UserActivityRecord(
                userId: session.userId,
                type: .newsViewed,
                title: headline,
                subtitle: symbol.map { "Read \($0) news" } ?? "Read market news",
                amount: nil,
                isGrowth: true,
                symbol: "newspaper.fill",
                referenceKey: referenceKey
            ),
            on: req.db
        )

        await req.reconcileBadges(userId: session.userId, on: req.db)
        return .noContent
    }

    private func requireUUIDParameter(_ req: Request, name: String, reason: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: reason)
        }
        return value
    }

    private func clampedLimit(_ rawLimit: Int?, default defaultValue: Int = 50, max maxValue: Int = 200) -> Int {
        max(1, min(rawLimit ?? defaultValue, maxValue))
    }

    private func newsViewReferenceKey(payload: NewsViewRequest, headline: String, symbol: String?) -> String {
        if let newsId = payload.newsId {
            return "news:\(newsId.uuidString.lowercased())"
        }
        if let url = payload.url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !url.isEmpty
        {
            return "url:\(url)"
        }
        let normalizedSymbol = symbol ?? "market"
        let normalizedHeadline = headline
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return "headline:\(normalizedSymbol):\(normalizedHeadline)"
    }
}
