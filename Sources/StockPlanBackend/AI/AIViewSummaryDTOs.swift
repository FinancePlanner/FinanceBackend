import Foundation
import StockPlanShared
import Vapor

/// A generated summary of one screen.
///
/// Defined here rather than in `norviq-shared` so that adding a scope never
/// requires a package tag and a two-repo release. `AIInsightHighlight` is
/// reused from shared because it predates the iOS pin (4.4.0) and is not the
/// part that would need to change.
struct AIViewSummaryResponse: Content, Equatable {
    /// A plain string, not the enum, on purpose: a backend that learns a ninth
    /// scope can return it to a client that has never heard of it, and that
    /// client decodes it and shows the text. Encoding the enum here would make
    /// every new screen a client release.
    let scope: String
    let title: String
    let body: String
    /// Server-computed. The model never supplies a number that reaches the
    /// screen — see `AIHighlightBuilders`.
    let highlights: [AIInsightHighlight]
    /// Server-injected, never model-sourced.
    let disclaimer: String
    let generatedAt: Date
    /// Whether this came from the cache. Lets the client show "updated an hour
    /// ago" honestly, and makes the cache assertable from the outside in tests.
    let isCached: Bool

    init(
        scope: AIViewScope,
        title: String,
        body: String,
        highlights: [AIInsightHighlight],
        generatedAt: Date = Date(),
        isCached: Bool = false
    ) {
        self.scope = scope.rawValue
        self.title = title
        self.body = body
        self.highlights = highlights
        disclaimer = AIInsightCardResponse.standardDisclaimer
        self.generatedAt = generatedAt
        self.isCached = isCached
    }
}

/// What actually goes in Redis.
///
/// Only the generated prose is cached. Highlights are recomputed on every read
/// so a cache hit still shows current figures against an hour-old narrative —
/// stale numbers would be worse than a stale sentence, because the numbers are
/// the part users act on.
struct CachedViewSummary: Codable, Sendable {
    let title: String
    let body: String
    let generatedAt: Date
}
