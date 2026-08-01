import Foundation
import Vapor

/// DeepAPI-powered insights provider for financial market sentiment analysis.
/// Uses DeepAPI's web search, X/Twitter scraping, Reddit scraping, and deep research
/// to gather real-time financial sentiment from global markets.
struct DeepAPIInsightsProvider: InsightsProvider {
    let apiKey: String
    let baseURL: String
    let httpClient: any Client
    let logger: Logger
    /// Per-call customer spend cap, in USD, sent as `maxCostUsd`. DeepAPI never
    /// debits more than this for one request.
    let maxCostUsd: String
    /// X/Twitter and Reddit scrapes cost orders of magnitude more than a web
    /// search, so they are opt-in. With this off the provider is web-search only.
    let socialScrapingEnabled: Bool

    init(
        apiKey: String,
        baseURL: String,
        httpClient: any Client,
        logger: Logger,
        maxCostUsd: String = "0.05",
        socialScrapingEnabled: Bool = false
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.logger = logger
        self.maxCostUsd = maxCostUsd
        self.socialScrapingEnabled = socialScrapingEnabled
    }

    var isEnabled: Bool {
        true
    }

    // MARK: - InsightsProvider Protocol

    func fetchEvents(days: Int, limit: Int, on req: Request) async throws -> HermesEventsResponse {
        let query = buildFinancialEventsQuery(days: days, limit: limit)
        let searchResponse = try await searchWeb(query: query, maxResults: limit, on: req)

        let events = searchResponse.results.enumerated().compactMap { index, result -> HermesEventDTO? in
            guard let sentiment = extractSentiment(from: result) else { return nil }
            return HermesEventDTO(
                eventId: "deepapi-web-\(index)-\(Date().timeIntervalSince1970)",
                source: "deepapi-web",
                sourceId: nil,
                topic: categorizeFinancialTopic(result.title + " " + result.snippetText),
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
        // One broad search bucketed by topic, rather than one paid search per
        // topic: the caller only needs relative volume, and a per-topic fan-out
        // multiplied the cost of every sync by ten for no extra signal.
        let query = buildFinancialEventsQuery(days: days, limit: 0)
        let response = try await searchWeb(query: query, maxResults: 10, on: req)

        var byTopic: [String: Int] = [:]
        for result in response.results {
            let topic = categorizeFinancialTopic(result.title + " " + result.snippetText)
            byTopic[topic, default: 0] += 1
        }

        return HermesSummaryResponse(
            windowDays: days,
            totalEvents: byTopic.values.reduce(0, +),
            byTopic: byTopic
        )
    }

    func fetchSentiment(topic: String?, days: Int, on req: Request) async throws -> HermesSentimentResponse {
        let searchTopic = topic ?? "global financial markets"

        var allScores: [Double] = []
        var labelCounts: [String: Int] = ["positive": 0, "neutral": 0, "negative": 0]
        var totalEvents = 0

        let response = try await searchWeb(
            query: buildSentimentQuery(for: searchTopic, days: days),
            maxResults: 10,
            on: req
        )
        totalEvents += response.results.count

        for result in response.results {
            if let sentiment = extractSentiment(from: result) {
                allScores.append(sentiment.score ?? 0.0)
                labelCounts[sentiment.label ?? "neutral", default: 0] += 1
            }
        }

        if socialScrapingEnabled {
            // Real-time retail sentiment from X/Twitter and Reddit. Both are
            // scrape runs, priced far above a web search, hence the gate.
            let twitterSentiment = try await fetchTwitterSentiment(topic: searchTopic, days: days, on: req)
            allScores.append(contentsOf: twitterSentiment.scores)
            for (label, count) in twitterSentiment.labelCounts {
                labelCounts[label, default: 0] += count
            }
            totalEvents += twitterSentiment.count

            let redditSentiment = try await fetchRedditSentiment(topic: searchTopic, days: days, on: req)
            allScores.append(contentsOf: redditSentiment.scores)
            for (label, count) in redditSentiment.labelCounts {
                labelCounts[label, default: 0] += count
            }
            totalEvents += redditSentiment.count
        }

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
        // One search per symbol: the sync job walks up to 25 symbols per run, so
        // every extra query here is multiplied 25x against the credit balance.
        let query = "\(symbol) stock sentiment analyst price target outlook"

        var posts: [HermesTickerPostDTO] = []

        let response = try await searchWeb(query: query, maxResults: min(limit, 10), on: req)

        for (index, result) in response.results.enumerated() {
            guard let sentiment = extractSentiment(from: result) else { continue }

            let confidence = min(1.0, max(0.0, abs(sentiment.score ?? 0.0) * 2.0))

            posts.append(HermesTickerPostDTO(
                eventId: "deepapi-ticker-\(symbol)-\(index)-\(Date().timeIntervalSince1970)",
                author: nil,
                authorHandle: nil,
                text: result.snippetText,
                url: result.url,
                sentiment: sentiment.label,
                sentimentScore: sentiment.score,
                confidence: confidence,
                postedAt: result.dateText ?? ISO8601DateFormatter().string(from: Date())
            ))
        }

        if socialScrapingEnabled {
            let twitterPosts = try await fetchTwitterTickerPosts(symbol: symbol, days: days, limit: limit, on: req)
            posts.append(contentsOf: twitterPosts)
        }

        return HermesTickerPostsResponse(
            symbol: symbol,
            days: days,
            count: posts.count,
            posts: posts
        )
    }

    func health(on req: Request) async -> Bool {
        do {
            // dryRun is a zero-spend validation preview: it proves the key, the
            // route and the request shape without debiting credits.
            let body = DeepAPIWebSearchRequest(query: "financial markets", maxResults: 10, maxCostUsd: maxCostUsd, dryRun: true)
            _ = try await send(path: "/v1/search/web", body: body, on: req) as DeepAPIWebSearchOutput?
            return true
        } catch {
            logger.warning("DeepAPI health check failed: \(String(reflecting: error))")
            return false
        }
    }

    // MARK: - Private Methods

    private func searchWeb(query: String, maxResults: Int, on req: Request) async throws -> DeepAPIWebSearchOutput {
        // 1-10 results are one flat price and 11+ doubles the charge, so never
        // ask for fewer than 10 and never step over it.
        let body = DeepAPIWebSearchRequest(
            query: query,
            maxResults: min(max(maxResults, 10), 10),
            maxCostUsd: maxCostUsd,
            dryRun: nil
        )
        guard let output: DeepAPIWebSearchOutput = try await send(path: "/v1/search/web", body: body, on: req) else {
            throw Abort(.badGateway, reason: "DeepAPI web search returned no output.")
        }
        return output
    }

    private func fetchTwitterSentiment(topic: String, days _: Int, on req: Request) async throws -> (scores: [Double], labelCounts: [String: Int], count: Int) {
        let query = "\(topic) stock market OR crypto OR forex lang:en"
        let body = DeepAPITwitterSearchRequest(query: query, maxItems: 50, sort: "latest", maxCostUsd: maxCostUsd, waitForFinishSecs: 60)

        let posts: [DeepAPITwitterPost] = try await send(path: "/v1/scrape/twitter/search", body: body, on: req) ?? []
        return analyzeTwitterPosts(posts)
    }

    private func fetchTwitterTickerPosts(symbol: String, days _: Int, limit: Int, on req: Request) async throws -> [HermesTickerPostDTO] {
        let query = "$\(symbol) OR #\(symbol) OR \"\(symbol) stock\" lang:en"
        let body = DeepAPITwitterSearchRequest(query: query, maxItems: limit, sort: "latest", maxCostUsd: maxCostUsd, waitForFinishSecs: 60)

        let posts: [DeepAPITwitterPost] = try await send(path: "/v1/scrape/twitter/search", body: body, on: req) ?? []
        return posts.enumerated().compactMap { index, post -> HermesTickerPostDTO? in
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
        let body = DeepAPIRedditSearchRequest(
            query: topic,
            subreddits: subreddits,
            sort: "hot",
            since: "week",
            maxItems: 50,
            maxCostUsd: maxCostUsd,
            waitForFinishSecs: 60
        )

        let posts: [DeepAPIRedditPost] = try await send(path: "/v1/scrape/reddit/search", body: body, on: req) ?? []
        return analyzeRedditPosts(posts)
    }

    /// POSTs a DeepAPI request and unwraps the public envelope, following the
    /// polling `next` action while the run is still settling.
    ///
    /// Every DeepAPI route answers with the same envelope — the payload lives in
    /// `output`, failures in `error` — and the scrape routes may answer `running`
    /// with a GET `next` to poll. `output` is legitimately null while a run
    /// settles, hence the optional return.
    private func send<Output: Decodable>(
        path: String,
        body: some Content,
        on req: Request
    ) async throws -> Output? {
        var response = try await req.client.post(URI(string: baseURL + path)) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            clientReq.headers.contentType = .json
            // Required on every POST: makes a retried request replay instead of
            // running (and charging) twice.
            clientReq.headers.replaceOrAdd(name: "Idempotency-Key", value: UUID().uuidString)
            clientReq.timeout = .seconds(90)
            try clientReq.content.encode(body)
        }

        var envelope = try decodeEnvelope(response, path: path) as DeepAPIEnvelope<Output>

        // Poll while the run is unfinished. Bounded so a stuck run cannot hold a
        // sync open forever.
        var polls = 0
        while let next = envelope.next, next.method.uppercased() == "GET", polls < Self.maxPolls {
            polls += 1
            let delay = min(max(next.afterSecs ?? 5, 1), 15)
            try await Task.sleep(for: .seconds(delay))

            response = try await req.client.get(URI(string: baseURL + next.path)) { clientReq in
                clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
                clientReq.timeout = .seconds(90)
            }
            envelope = try decodeEnvelope(response, path: next.path)
        }

        if envelope.next != nil, polls >= Self.maxPolls {
            throw Abort(.badGateway, reason: "DeepAPI \(path) did not finish within \(Self.maxPolls) polls.")
        }

        return envelope.output
    }

    private func decodeEnvelope<Output: Decodable>(
        _ response: ClientResponse,
        path: String
    ) throws -> DeepAPIEnvelope<Output> {
        let envelope: DeepAPIEnvelope<Output>
        do {
            envelope = try response.content.decode(DeepAPIEnvelope<Output>.self)
        } catch {
            throw Abort(
                .badGateway,
                reason: "DeepAPI \(path) returned an unreadable response (HTTP \(response.status.code))."
            )
        }

        if let apiError = envelope.error {
            // Includes insufficient_credits: the caller treats it like any other
            // failure, so the insights chain falls through to the next provider.
            throw Abort(.badGateway, reason: "DeepAPI \(path) failed [\(apiError.code)]: \(apiError.message)")
        }
        guard response.status.code < 300 else {
            throw Abort(.badGateway, reason: "DeepAPI \(path) failed with HTTP \(response.status.code).")
        }
        guard envelope.status != "failed" else {
            throw Abort(.badGateway, reason: "DeepAPI \(path) reported status failed.")
        }

        return envelope
    }

    private static let maxPolls = 12

    private func buildFinancialEventsQuery(days: Int, limit _: Int) -> String {
        let topics = ["stock market", "crypto", "forex", "commodities", "earnings", "central banks", "macro economics"]
        return topics.joined(separator: " OR ") + " financial news last \(days) days"
    }

    private func buildSentimentQuery(for topic: String, days _: Int) -> String {
        "\(topic) bullish bearish sentiment market outlook forecast"
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
        let text = (result.title + " " + result.snippetText).lowercased()

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
            let text = (post.title + " " + (post.text ?? "")).lowercased()

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

/// The envelope every DeepAPI route answers with. `output` is null while a
/// scrape run is still settling, and again when the route failed.
private struct DeepAPIEnvelope<Output: Decodable>: Decodable {
    let requestId: String?
    let status: String
    let output: Output?
    let next: NextAction?
    let error: ErrorBody?

    struct NextAction: Decodable {
        let method: String
        let path: String
        let afterSecs: Double?
    }

    struct ErrorBody: Decodable {
        let code: String
        let message: String
    }
}

/// `additionalProperties` is false on every DeepAPI body schema: an unknown or
/// wrongly typed field fails the whole request with `invalid_request`. In
/// particular `maxCostUsd` is a decimal *string*, not a number.
private struct DeepAPIWebSearchRequest: Content {
    let query: String
    let maxResults: Int
    let maxCostUsd: String
    let dryRun: Bool?
}

private struct DeepAPIWebSearchOutput: Content {
    let results: [DeepAPISearchResult]
}

private struct DeepAPISearchResult: Content {
    let title: String
    let url: String
    let snippet: String?
    let dateText: String?

    /// Results occasionally arrive without a snippet; the sentiment heuristics
    /// only need the text that is there.
    var snippetText: String {
        snippet ?? ""
    }
}

private struct DeepAPITwitterSearchRequest: Content {
    let query: String
    let maxItems: Int
    let sort: String
    let maxCostUsd: String
    let waitForFinishSecs: Int
}

private struct DeepAPITwitterPost: Content {
    let id: String
    let text: String
    let url: String?
    let author: DeepAPITwitterAuthor?
    let createdAt: String?
    let likes: Int?
    let reposts: Int?
    let replies: Int?
}

private struct DeepAPITwitterAuthor: Content {
    let handle: String?
    let name: String?
    let followers: Int?
}

private struct DeepAPIRedditSearchRequest: Content {
    let query: String
    let subreddits: [String]
    let sort: String
    let since: String
    let maxItems: Int
    let maxCostUsd: String
    let waitForFinishSecs: Int
}

private struct DeepAPIRedditPost: Content {
    let id: String
    let title: String
    let text: String?
    let subreddit: String?
    let author: String?
    let score: Int?
    let comments: Int?
    let postedAt: String?
    let url: String?
}
