import Foundation
import Vapor

/// DeepAPI-powered insights provider for financial market sentiment analysis.
/// Uses DeepAPI's web search, X/Twitter scraping, Reddit scraping, and deep research
/// to gather real-time financial sentiment from global markets.
struct DeepAPIInsightsProvider: InsightsProvider {
    let apiKey: String
    let baseURL: String
    let httpClient: Client
    let logger: Logger

    var isEnabled: Bool {
        true
    }

    // MARK: - InsightsProvider Protocol

    func fetchEvents(days: Int, limit: Int, on req: Request) async throws -> HermesEventsResponse {
        let query = buildFinancialEventsQuery(days: days, limit: limit)
        let searchResponse = try await searchWeb(query: query, limit: limit, on: req)

        let events = searchResponse.results.enumerated().compactMap { index, result -> HermesEventDTO? in
            guard let sentiment = extractSentiment(from: result) else { return nil }
            return HermesEventDTO(
                eventId: "deepapi-web-\(index)-\(Date().timeIntervalSince1970)",
                source: "deepapi-web",
                sourceId: nil,
                topic: categorizeFinancialTopic(result.title + " " + result.snippet),
                observedAt: result.dateText ?? ISO8601DateFormatter().string(from: Date()),
                ingestedAt: ISO8601DateFormatter().string(from: Date()),
                payload: HermesEventPayload(
                    title: result.title,
                    summary: result.snippet,
                    url: result.url,
                    author: nil
                ),
                sentiment: HermesEventSentiment(
                    label: sentiment.label,
                    score: sentiment.score
                )
            )
        }

        return HermesEventsResponse(count: events.count, events: events)
    }

    func fetchSummary(days: Int, on req: Request) async throws -> HermesSummaryResponse {
        let topics = [
            "stock market", "crypto", "forex", "commodities", "central banks",
            "earnings", "IPO", "M&A", "macro economics", "geopolitics",
        ]

        var byTopic: [String: Int] = [:]

        for topic in topics {
            let query = "\(topic) financial markets news last \(days) days"
            let response = try await searchWeb(query: query, limit: 10, on: req)
            byTopic[topic] = response.results.count
        }

        return HermesSummaryResponse(
            windowDays: days,
            totalEvents: byTopic.values.reduce(0, +),
            byTopic: byTopic
        )
    }

    func fetchSentiment(topic: String?, days: Int, on req: Request) async throws -> HermesSentimentResponse {
        let searchTopic = topic ?? "global financial markets"
        let queries = buildSentimentQueries(for: searchTopic, days: days)

        var allScores: [Double] = []
        var labelCounts: [String: Int] = ["positive": 0, "neutral": 0, "negative": 0]
        var totalEvents = 0

        for query in queries {
            let response = try await searchWeb(query: query, limit: 20, on: req)
            totalEvents += response.results.count

            for result in response.results {
                if let sentiment = extractSentiment(from: result) {
                    allScores.append(sentiment.score ?? 0.0)
                    labelCounts[sentiment.label ?? "neutral", default: 0] += 1
                }
            }
        }

        // Also scrape X/Twitter for real-time sentiment
        let twitterSentiment = try await fetchTwitterSentiment(topic: searchTopic, days: days, on: req)
        allScores.append(contentsOf: twitterSentiment.scores)
        for (label, count) in twitterSentiment.labelCounts {
            labelCounts[label, default: 0] += count
        }
        totalEvents += twitterSentiment.count

        // Scrape Reddit for retail sentiment
        let redditSentiment = try await fetchRedditSentiment(topic: searchTopic, days: days, on: req)
        allScores.append(contentsOf: redditSentiment.scores)
        for (label, count) in redditSentiment.labelCounts {
            labelCounts[label, default: 0] += count
        }
        totalEvents += redditSentiment.count

        let averageScore = allScores.isEmpty ? 0 : allScores.reduce(0, +) / Double(allScores.count)

        return HermesSentimentResponse(
            topic: topic,
            windowDays: days,
            count: totalEvents,
            labelCounts: labelCounts,
            averageScore: averageScore,
            sampled: totalEvents
        )
    }

    func fetchNetWorth(on _: Request) async throws -> HermesNetWorthResponse {
        // DeepAPI doesn't provide net worth data - return empty
        HermesNetWorthResponse(latest: nil, history: [])
    }

    func fetchTickerPosts(symbol: String, days: Int, limit: Int, on req: Request) async throws -> HermesTickerPostsResponse {
        let queries = [
            "\(symbol) stock sentiment analysis",
            "\(symbol) earnings call transcript",
            "$\(symbol) stock twitter",
            "\(symbol) price target analyst",
        ]

        var posts: [HermesTickerPostDTO] = []

        for query in queries {
            let response = try await searchWeb(query: query, limit: limit / queries.count, on: req)

            for (index, result) in response.results.enumerated() {
                guard let sentiment = extractSentiment(from: result) else { continue }

                let confidence = min(1.0, max(0.0, abs(sentiment.score ?? 0.0) * 2.0))

                posts.append(HermesTickerPostDTO(
                    eventId: "deepapi-ticker-\(symbol)-\(index)-\(Date().timeIntervalSince1970)",
                    author: nil,
                    authorHandle: nil,
                    text: result.snippet,
                    url: result.url,
                    sentiment: sentiment.label,
                    sentimentScore: sentiment.score,
                    confidence: confidence,
                    postedAt: result.dateText ?? ISO8601DateFormatter().string(from: Date())
                ))
            }
        }

        // Also get X/Twitter posts for the ticker
        let twitterPosts = try await fetchTwitterTickerPosts(symbol: symbol, days: days, limit: limit, on: req)
        posts.append(contentsOf: twitterPosts)

        return HermesTickerPostsResponse(
            symbol: symbol,
            days: days,
            count: posts.count,
            posts: posts
        )
    }

    func health(on req: Request) async -> Bool {
        do {
            let response = try await searchWeb(query: "test", limit: 1, on: req)
            return !response.results.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - Private Methods

    private func searchWeb(query: String, limit: Int, on req: Request) async throws -> DeepAPIWebSearchResponse {
        let body = DeepAPIWebSearchRequest(query: query, limit: limit, includeAnswer: true)
        let response = try await req.client.post("\(baseURL)/v1/search/web") { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            clientReq.headers.contentType = .json
            try clientReq.content.encode(body)
        }

        guard response.status == .ok else {
            let errorBody = try? response.content.decode(DeepAPIErrorResponse.self)
            throw Abort(.badGateway, reason: "DeepAPI web search failed: \(errorBody?.message ?? response.status.reasonPhrase)")
        }

        return try response.content.decode(DeepAPIWebSearchResponse.self)
    }

    private func fetchTwitterSentiment(topic: String, days _: Int, on req: Request) async throws -> (scores: [Double], labelCounts: [String: Int], count: Int) {
        let query = "\(topic) stock market OR crypto OR forex lang:en"
        let body = DeepAPITwitterSearchRequest(query: query, maxItems: 50, maxCostUsd: 0.50)

        let response = try await req.client.post("\(baseURL)/v1/scrape/twitter/search") { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            clientReq.headers.contentType = .json
            try clientReq.content.encode(body)
        }

        guard response.status == .ok else { return ([], [:], 0) }

        let twitterResponse = try response.content.decode(DeepAPITwitterSearchResponse.self)
        return analyzeTwitterPosts(twitterResponse.posts)
    }

    private func fetchTwitterTickerPosts(symbol: String, days _: Int, limit: Int, on req: Request) async throws -> [HermesTickerPostDTO] {
        let query = "$\(symbol) OR #\(symbol) OR \"\(symbol) stock\" lang:en"
        let body = DeepAPITwitterSearchRequest(query: query, maxItems: limit, maxCostUsd: 1.00)

        let response = try await req.client.post("\(baseURL)/v1/scrape/twitter/search") { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            clientReq.headers.contentType = .json
            try clientReq.content.encode(body)
        }

        guard response.status == .ok else { return [] }

        let twitterResponse = try response.content.decode(DeepAPITwitterSearchResponse.self)
        return twitterResponse.posts.enumerated().compactMap { index, post -> HermesTickerPostDTO? in
            let sentiment = analyzeTweetSentiment(post.text)
            let confidence = min(1.0, max(0.0, abs(sentiment.score ?? 0.0) * 2.0))
            return HermesTickerPostDTO(
                eventId: "deepapi-twitter-\(symbol)-\(index)-\(Date().timeIntervalSince1970)",
                author: post.author?.name,
                authorHandle: post.author?.handle,
                text: post.text,
                url: post.url,
                sentiment: sentiment.label,
                sentimentScore: sentiment.score,
                confidence: confidence,
                postedAt: post.createdAt ?? ISO8601DateFormatter().string(from: Date())
            )
        }
    }

    private func fetchRedditSentiment(topic: String, days _: Int, on req: Request) async throws -> (scores: [Double], labelCounts: [String: Int], count: Int) {
        let subreddits = ["wallstreetbets", "stocks", "investing", "SecurityAnalysis", "ValueInvesting", "CryptoCurrency", "Forex"]
        let query = "\(topic) (\(subreddits.joined(separator: " OR ")))"
        let body = DeepAPIRedditSearchRequest(query: query, subreddits: subreddits, sort: "hot", timeFilter: "week", maxItems: 50)

        let response = try await req.client.post("\(baseURL)/v1/scrape/reddit/search") { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            clientReq.headers.contentType = .json
            try clientReq.content.encode(body)
        }

        guard response.status == .ok else { return ([], [:], 0) }

        let redditResponse = try response.content.decode(DeepAPIRedditSearchResponse.self)
        return analyzeRedditPosts(redditResponse.posts)
    }

    private func buildFinancialEventsQuery(days: Int, limit _: Int) -> String {
        let topics = ["stock market", "crypto", "forex", "commodities", "earnings", "central banks", "macro economics"]
        return topics.joined(separator: " OR ") + " financial news last \(days) days"
    }

    private func buildSentimentQueries(for topic: String, days _: Int) -> [String] {
        [
            "\(topic) bullish bearish sentiment",
            "\(topic) market outlook analysis",
            "\(topic) price prediction forecast",
            "\(topic) risk opportunity analysis",
        ]
    }

    private func categorizeFinancialTopic(_ text: String) -> String {
        let lowercased = text.lowercased()
        if lowercased.contains("crypto") || lowercased.contains("bitcoin") || lowercased.contains("ethereum") {
            return "crypto"
        }
        if lowercased.contains("forex") || lowercased.contains("currency") || lowercased.contains("fx") {
            return "forex"
        }
        if lowercased.contains("commodit") || lowercased.contains("gold") || lowercased.contains("oil") {
            return "commodities"
        }
        if lowercased.contains("earning") {
            return "earnings"
        }
        if lowercased.contains("central bank") || lowercased.contains("fed") || lowercased.contains("ecb") || lowercased.contains("rate") {
            return "central-banks"
        }
        if lowercased.contains("macro") || lowercased.contains("gdp") || lowercased.contains("inflation") || lowercased.contains("cpi") {
            return "macro-economics"
        }
        if lowercased.contains("ipo") {
            return "ipo"
        }
        if lowercased.contains("merger") || lowercased.contains("acquisition") || lowercased.contains("m&a") {
            return "ma"
        }
        return "general-markets"
    }

    private func extractSentiment(from result: DeepAPISearchResult) -> HermesEventSentiment? {
        let text = (result.title + " " + result.snippet).lowercased()

        let bullishKeywords = ["bullish", "surge", "rally", "gain", "up", "rise", "soar", "jump", "climb", "strong", "beat", "exceed", "outperform", "buy", "long", "optimistic", "positive", "growth", "profit", "record high"]
        let bearishKeywords = ["bearish", "crash", "fall", "drop", "down", "decline", "plunge", "tumble", "slump", "weak", "miss", "underperform", "sell", "short", "pessimistic", "negative", "loss", "recession", "correction"]

        var bullishCount = 0
        var bearishCount = 0

        for keyword in bullishKeywords {
            if text.contains(keyword) {
                bullishCount += 1
            }
        }
        for keyword in bearishKeywords {
            if text.contains(keyword) {
                bearishCount += 1
            }
        }

        let total = bullishCount + bearishCount
        guard total > 0 else { return nil }

        let score = Double(bullishCount - bearishCount) / Double(total)
        let label = if score > 0.2 {
            "positive"
        } else if score < -0.2 {
            "negative"
        } else {
            "neutral"
        }

        return HermesEventSentiment(label: label, score: score)
    }

    private func analyzeTwitterPosts(_ posts: [DeepAPITwitterPost]) -> (scores: [Double], labelCounts: [String: Int], count: Int) {
        var scores: [Double] = []
        var labelCounts: [String: Int] = ["positive": 0, "neutral": 0, "negative": 0]

        for post in posts {
            let sentiment = analyzeTweetSentiment(post.text)
            scores.append(sentiment.score ?? 0.0)
            labelCounts[sentiment.label ?? "neutral", default: 0] += 1
        }

        return (scores, labelCounts, posts.count)
    }

    private func analyzeTweetSentiment(_ text: String) -> HermesEventSentiment {
        let lowercased = text.lowercased()

        let bullishKeywords = ["bullish", "moon", "pump", "buy", "long", "calls", "green", "up", "rally", "breakout", "support", "accumulate", "🚀", "📈", "💎", "🙌"]
        let bearishKeywords = ["bearish", "dump", "sell", "short", "puts", "red", "down", "crash", "breakdown", "resistance", "distribute", "📉", "🐻", "💀", "🚮"]

        var bullishCount = 0
        var bearishCount = 0

        for keyword in bullishKeywords {
            if lowercased.contains(keyword) {
                bullishCount += 1
            }
        }
        for keyword in bearishKeywords {
            if lowercased.contains(keyword) {
                bearishCount += 1
            }
        }

        let total = bullishCount + bearishCount
        let score = total > 0 ? Double(bullishCount - bearishCount) / Double(total) : 0
        let label = if score > 0.15 {
            "positive"
        } else if score < -0.15 {
            "negative"
        } else {
            "neutral"
        }

        return HermesEventSentiment(label: label, score: score)
    }

    private func analyzeRedditPosts(_ posts: [DeepAPIRedditPost]) -> (scores: [Double], labelCounts: [String: Int], count: Int) {
        var scores: [Double] = []
        var labelCounts: [String: Int] = ["positive": 0, "neutral": 0, "negative": 0]

        for post in posts {
            let text = (post.title + " " + (post.selftext ?? "")).lowercased()

            let bullishKeywords = ["bullish", "buy", "long", "calls", "undervalued", "growth", "moon", "diamond hands", "hold", "accumulate"]
            let bearishKeywords = ["bearish", "sell", "short", "puts", "overvalued", "crash", "paper hands", "dump", "bubble"]

            var bullishCount = 0
            var bearishCount = 0

            for keyword in bullishKeywords {
                if text.contains(keyword) {
                    bullishCount += 1
                }
            }
            for keyword in bearishKeywords {
                if text.contains(keyword) {
                    bearishCount += 1
                }
            }

            let total = bullishCount + bearishCount
            let score = total > 0 ? Double(bullishCount - bearishCount) / Double(total) : 0
            let label = if score > 0.2 {
                "positive"
            } else if score < -0.2 {
                "negative"
            } else {
                "neutral"
            }

            scores.append(score)
            labelCounts[label, default: 0] += 1
        }

        return (scores, labelCounts, posts.count)
    }
}

// MARK: - DeepAPI Request/Response Models

private struct DeepAPIWebSearchRequest: Content {
    let query: String
    let limit: Int
    let includeAnswer: Bool
}

private struct DeepAPIWebSearchResponse: Content {
    let results: [DeepAPISearchResult]
    let answer: String?
}

private struct DeepAPISearchResult: Content {
    let title: String
    let url: String
    let snippet: String
    let dateText: String?
}

private struct DeepAPITwitterSearchRequest: Content {
    let query: String
    let maxItems: Int
    let maxCostUsd: Double
}

private struct DeepAPITwitterSearchResponse: Content {
    let posts: [DeepAPITwitterPost]
}

private struct DeepAPITwitterPost: Content {
    let id: String
    let text: String
    let url: String
    let author: DeepAPITwitterAuthor?
    let createdAt: String?
    let likeCount: Int?
    let retweetCount: Int?
    let replyCount: Int?
}

private struct DeepAPITwitterAuthor: Content {
    let handle: String
    let name: String
    let followersCount: Int?
    let verified: Bool?
}

private struct DeepAPIRedditSearchRequest: Content {
    let query: String
    let subreddits: [String]
    let sort: String
    let timeFilter: String
    let maxItems: Int
}

private struct DeepAPIRedditSearchResponse: Content {
    let posts: [DeepAPIRedditPost]
}

private struct DeepAPIRedditPost: Content {
    let id: String
    let title: String
    let selftext: String?
    let subreddit: String
    let author: String?
    let score: Int
    let numComments: Int
    let createdUtc: Double
    let url: String
}

private struct DeepAPIErrorResponse: Content {
    let code: String
    let message: String
}
