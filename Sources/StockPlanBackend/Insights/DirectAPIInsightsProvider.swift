import Foundation
import Vapor

/// Last resort in the provider chain: talks to free or already-paid-for
/// endpoints directly, with no scraping vendor in the middle.
///
/// Exists so a dry DeepAPI balance degrades coverage instead of stopping
/// sentiment entirely. It reaches fewer venues by design — Investing.com and
/// Seeking Alpha have no free API and are DeepAPI-only — so a run that falls
/// through to here produces thinner but still honest readings.
///
/// The legacy topic endpoints are not implemented: this provider exists for the
/// per-symbol path, and pretending to serve `fetchEvents` would let it swallow
/// calls that Hermes or DeepAPI should have answered.
struct DirectAPIInsightsProvider: InsightsProvider {
    let stocktwitsBaseURL: String
    let redditClientID: String?
    let redditClientSecret: String?
    let redditUserAgent: String
    let newsProvider: (any NewsProvider)?
    let logger: Logger

    init(
        stocktwitsBaseURL: String = "https://api.stocktwits.com/api/2",
        redditClientID: String? = nil,
        redditClientSecret: String? = nil,
        redditUserAgent: String = "norviq-sentiment/1.0",
        newsProvider: (any NewsProvider)? = nil,
        logger: Logger
    ) {
        self.stocktwitsBaseURL = stocktwitsBaseURL
        self.redditClientID = redditClientID
        self.redditClientSecret = redditClientSecret
        self.redditUserAgent = redditUserAgent
        self.newsProvider = newsProvider
        self.logger = logger
    }

    var isEnabled: Bool {
        !supportedSentimentSources.isEmpty
    }

    var supportedSentimentSources: [SentimentSource] {
        var sources: [SentimentSource] = [.stocktwits]
        if newsProvider != nil {
            sources.append(.news)
        }
        if let redditClientID, let redditClientSecret,
           !redditClientID.isEmpty, !redditClientSecret.isEmpty
        {
            sources.append(.reddit)
        }
        return sources
    }

    // MARK: - Symbol posts

    func fetchSymbolPosts(
        symbols: [String],
        sources: [SentimentSource],
        days _: Int,
        limit: Int,
        on req: Request
    ) async throws -> [SymbolPostBatch] {
        let usable = sources.filter { supportedSentimentSources.contains($0) }
        guard !usable.isEmpty else { return [] }

        // Reddit's token is per-run, not per-symbol: fetching it once keeps a
        // 500-symbol sweep to one auth call instead of 500.
        let redditToken = usable.contains(.reddit) ? try? await redditAccessToken(on: req) : nil

        var newsBySymbol: [String: [ProviderNewsItem]] = [:]
        if usable.contains(.news), let newsProvider {
            do {
                let items = try await newsProvider.fetch(symbols: symbols, on: req)
                newsBySymbol = Dictionary(grouping: items, by: { $0.symbol.uppercased() })
            } catch {
                logger.warning("direct.symbol-posts news failed error=\(String(describing: error))")
            }
        }

        var batches: [SymbolPostBatch] = []
        for symbol in symbols {
            var posts: [IngestedPost] = []

            if usable.contains(.stocktwits) {
                do {
                    posts += try await fetchStocktwits(symbol: symbol, limit: limit, on: req)
                } catch {
                    logger.warning("direct.stocktwits failed symbol=\(symbol) error=\(String(describing: error))")
                }
            }

            if usable.contains(.reddit), let redditToken {
                do {
                    posts += try await fetchReddit(symbol: symbol, token: redditToken, limit: limit, on: req)
                } catch {
                    logger.warning("direct.reddit failed symbol=\(symbol) error=\(String(describing: error))")
                }
            }

            if let items = newsBySymbol[symbol.uppercased()] {
                posts += items.prefix(limit).map { item in
                    IngestedPost(
                        dedupeKey: "direct:news:\(symbol):\(item.url ?? item.headline)",
                        symbol: symbol,
                        author: item.source,
                        authorHandle: nil,
                        text: [item.headline, item.summary].compactMap(\.self).joined(separator: "\n"),
                        url: item.url,
                        postedAt: item.publishedAt,
                        source: .news
                    )
                }
            }

            batches.append(SymbolPostBatch(symbol: symbol, posts: posts))
        }
        return batches
    }

    /// StockTwits publishes an unauthenticated symbol stream. It is rate
    /// limited, so a 429 is treated as "nothing this run" rather than an error
    /// worth failing the batch over.
    private func fetchStocktwits(symbol: String, limit: Int, on req: Request) async throws -> [IngestedPost] {
        let uri = URI(string: "\(stocktwitsBaseURL)/streams/symbol/\(symbol).json?limit=\(min(limit, 30))")
        let response = try await req.client.get(uri)

        guard response.status == .ok else {
            if response.status == .tooManyRequests || response.status == .notFound {
                return []
            }
            throw Abort(.badGateway, reason: "StockTwits returned HTTP \(response.status.code) for \(symbol).")
        }

        let payload = try response.content.decode(StocktwitsStream.self)
        return payload.messages.compactMap { message in
            let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // StockTwits users self-tag Bullish/Bearish. That is a stated
            // stance from the author, so it beats guessing from the words.
            let stated = message.entities?.sentiment?.basic?.lowercased()
            let providedScore: Double? = switch stated {
            case "bullish": 1.0
            case "bearish": -1.0
            default: nil
            }
            return IngestedPost(
                dedupeKey: "direct:stocktwits:\(symbol):\(message.id)",
                symbol: symbol,
                author: message.user?.name,
                authorHandle: message.user?.username,
                text: text,
                url: message.user?.username.map { "https://stocktwits.com/\($0)/message/\(message.id)" },
                postedAt: parseHermesTimestamp(message.createdAt) ?? Date(),
                source: .stocktwits,
                providedScore: providedScore,
                providedLabel: providedScore.map(SentimentClassifier.label(forScore:)),
                // A self-declared tag is a strong signal but only one data
                // point, so it is not asserted at full confidence.
                providedConfidence: providedScore == nil ? nil : 0.8
            )
        }
    }

    private func fetchReddit(
        symbol: String,
        token: String,
        limit: Int,
        on req: Request
    ) async throws -> [IngestedPost] {
        let subreddits = DeepAPIInsightsProvider.equitySubreddits.joined(separator: "+")
        let query = "\(symbol) stock".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol
        let uri = URI(
            string: "https://oauth.reddit.com/r/\(subreddits)/search?q=\(query)&restrict_sr=1&sort=new&t=week&limit=\(min(limit, 50))"
        )

        let response = try await req.client.get(uri) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: token)
            clientReq.headers.replaceOrAdd(name: .userAgent, value: redditUserAgent)
        }
        guard response.status == .ok else {
            if response.status == .tooManyRequests {
                return []
            }
            throw Abort(.badGateway, reason: "Reddit returned HTTP \(response.status.code) for \(symbol).")
        }

        let listing = try response.content.decode(RedditListing.self)
        return listing.data.children.compactMap { child in
            let post = child.data
            let combined = [post.title, post.selftext]
                .compactMap(\.self)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !combined.isEmpty else { return nil }
            return IngestedPost(
                dedupeKey: "direct:reddit:\(symbol):\(post.id)",
                symbol: symbol,
                author: post.author,
                authorHandle: post.subreddit.map { "r/\($0)" },
                text: combined,
                url: post.permalink.map { "https://www.reddit.com\($0)" },
                postedAt: post.createdUTC.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                source: .reddit
            )
        }
    }

    private func redditAccessToken(on req: Request) async throws -> String {
        guard let redditClientID, let redditClientSecret else {
            throw Abort(.serviceUnavailable, reason: "Reddit credentials are not configured.")
        }

        let credentials = Data("\(redditClientID):\(redditClientSecret)".utf8).base64EncodedString()
        let response = try await req.client.post(URI(string: "https://www.reddit.com/api/v1/access_token")) { clientReq in
            clientReq.headers.replaceOrAdd(name: .authorization, value: "Basic \(credentials)")
            clientReq.headers.replaceOrAdd(name: .userAgent, value: redditUserAgent)
            clientReq.headers.contentType = .urlEncodedForm
            try clientReq.content.encode(["grant_type": "client_credentials"], as: .urlEncodedForm)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Reddit auth returned HTTP \(response.status.code).")
        }
        return try response.content.decode(RedditToken.self).accessToken
    }

    // MARK: - Legacy topic endpoints

    func fetchEvents(days _: Int, limit _: Int, on _: Request) async throws -> HermesEventsResponse {
        throw Abort(.notImplemented, reason: "Direct provider serves per-symbol posts only.")
    }

    func fetchSummary(days _: Int, on _: Request) async throws -> HermesSummaryResponse {
        throw Abort(.notImplemented, reason: "Direct provider serves per-symbol posts only.")
    }

    func fetchSentiment(topic _: String?, days _: Int, on _: Request) async throws -> HermesSentimentResponse {
        throw Abort(.notImplemented, reason: "Direct provider serves per-symbol posts only.")
    }

    func fetchNetWorth(on _: Request) async throws -> HermesNetWorthResponse {
        HermesNetWorthResponse(latest: nil, history: [])
    }

    func fetchTickerPosts(symbol: String, days: Int, limit: Int, on req: Request) async throws -> HermesTickerPostsResponse {
        let batches = try await fetchSymbolPosts(
            symbols: [symbol],
            sources: supportedSentimentSources,
            days: days,
            limit: limit,
            on: req
        )
        let posts = batches.first?.posts ?? []
        return HermesTickerPostsResponse(
            symbol: symbol,
            days: days,
            count: posts.count,
            posts: posts.map { post in
                let scored = SentimentScoring.score(post)
                return HermesTickerPostDTO(
                    eventId: post.dedupeKey,
                    author: post.author,
                    authorHandle: post.authorHandle,
                    text: post.text,
                    url: post.url,
                    sentiment: scored.label,
                    sentimentScore: scored.score,
                    confidence: scored.confidence,
                    postedAt: ISO8601DateFormatter().string(from: post.postedAt)
                )
            }
        )
    }

    func health(on _: Request) async -> Bool {
        // No probe: every backing endpoint is either free or already paid for,
        // and a synthetic health call would consume the same rate limit the
        // real work needs.
        isEnabled
    }
}

// MARK: - Wire formats

private struct StocktwitsStream: Content {
    struct Message: Content {
        struct User: Content {
            let username: String?
            let name: String?
        }

        struct Entities: Content {
            struct Sentiment: Content {
                let basic: String?
            }

            let sentiment: Sentiment?
        }

        let id: Int
        let body: String
        let createdAt: String?
        let user: User?
        let entities: Entities?

        enum CodingKeys: String, CodingKey {
            case id, body, user, entities
            case createdAt = "created_at"
        }
    }

    let messages: [Message]
}

private struct RedditToken: Content {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct RedditListing: Content {
    struct Container: Content {
        let children: [Child]
    }

    struct Child: Content {
        let data: Post
    }

    struct Post: Content {
        let id: String
        let title: String
        let selftext: String?
        let author: String?
        let subreddit: String?
        let permalink: String?
        let createdUTC: Double?

        enum CodingKeys: String, CodingKey {
            case id, title, selftext, author, subreddit, permalink
            case createdUTC = "created_utc"
        }
    }

    let data: Container
}
