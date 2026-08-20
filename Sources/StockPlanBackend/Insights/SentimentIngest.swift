import Foundation
import Vapor

/// One retail post on its way into `ticker_sentiment_posts`, before scoring.
///
/// Providers hand back these rather than model instances so the aggregation job
/// owns the decision about which scorer runs. Hermes already scores upstream and
/// fills `providedScore`; the scrape paths leave it nil and get
/// `SentimentClassifier`.
struct IngestedPost: Sendable, Equatable {
    var dedupeKey: String
    var symbol: String
    var author: String?
    var authorHandle: String?
    var text: String
    var url: String?
    var postedAt: Date
    var source: SentimentSource
    var providedScore: Double?
    var providedLabel: String?
    var providedConfidence: Double?

    init(
        dedupeKey: String,
        symbol: String,
        author: String? = nil,
        authorHandle: String? = nil,
        text: String,
        url: String? = nil,
        postedAt: Date,
        source: SentimentSource,
        providedScore: Double? = nil,
        providedLabel: String? = nil,
        providedConfidence: Double? = nil
    ) {
        self.dedupeKey = dedupeKey
        self.symbol = symbol
        self.author = author
        self.authorHandle = authorHandle
        self.text = text
        self.url = url
        self.postedAt = postedAt
        self.source = source
        self.providedScore = providedScore
        self.providedLabel = providedLabel
        self.providedConfidence = providedConfidence
    }
}

struct SymbolPostBatch: Sendable {
    var symbol: String
    var posts: [IngestedPost]
}

extension InsightsProvider {
    /// Which feeds this provider can actually serve. Callers intersect their
    /// requested sources with this, so asking Hermes for Seeking Alpha is a
    /// no-op rather than an error.
    var supportedSentimentSources: [SentimentSource] {
        [.x]
    }

    /// Multi-symbol, multi-source post fetch.
    ///
    /// The default fans out over the existing single-symbol `fetchTickerPosts`
    /// so every provider satisfies the contract without change. Providers that
    /// can genuinely batch or that reach more than one feed override it.
    ///
    /// A failure for one symbol must not sink the batch: the symbol is skipped
    /// and logged, matching how `syncTickerPosts` already treats per-symbol
    /// failures.
    func fetchSymbolPosts(
        symbols: [String],
        sources: [SentimentSource],
        days: Int,
        limit: Int,
        on req: Request
    ) async throws -> [SymbolPostBatch] {
        let usable = sources.filter { supportedSentimentSources.contains($0) }
        guard !usable.isEmpty else { return [] }

        var batches: [SymbolPostBatch] = []
        for symbol in symbols {
            do {
                let response = try await fetchTickerPosts(symbol: symbol, days: days, limit: limit, on: req)
                let posts = response.posts.compactMap { dto -> IngestedPost? in
                    guard let text = dto.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty
                    else { return nil }
                    return IngestedPost(
                        dedupeKey: dto.eventId,
                        symbol: symbol,
                        author: dto.author,
                        authorHandle: dto.authorHandle,
                        text: text,
                        url: dto.url,
                        postedAt: parseHermesTimestamp(dto.postedAt) ?? Date(),
                        source: usable.first ?? .x,
                        providedScore: dto.sentimentScore,
                        providedLabel: dto.sentiment,
                        providedConfidence: dto.confidence
                    )
                }
                batches.append(SymbolPostBatch(symbol: symbol, posts: posts))
            } catch {
                req.logger.warning(
                    "sentiment.ingest symbol failed symbol=\(symbol) error=\(String(describing: error))"
                )
            }
        }
        return batches
    }
}

/// Scoring decision for one post: trust the upstream when it scored, otherwise
/// run the local lexicon.
enum SentimentScoring {
    struct Scored: Sendable, Equatable {
        var score: Double?
        var label: String
        var confidence: Double?
    }

    static func score(_ post: IngestedPost) -> Scored {
        if let provided = post.providedScore {
            return Scored(
                score: provided,
                label: post.providedLabel ?? SentimentClassifier.label(forScore: provided),
                confidence: post.providedConfidence
            )
        }

        let result = SentimentClassifier.classify(post.text)
        return Scored(score: result.score, label: result.label, confidence: result.confidence)
    }
}
