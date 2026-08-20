import Fluent
import Foundation
import StockPlanShared
import Vapor

// MARK: - Response DTOs

struct SymbolSentimentResponse: Content, Sendable {
    var symbol: String
    var asOfDate: String
    /// Absent when nothing was measured. Clients must render absence rather
    /// than substituting a neutral zero.
    var score: Double?
    var label: String
    var confidence: Double?
    var postCount: Int
    var delta1d: Double?
    var volumeZ: Double?
    var sourceCounts: SentimentSourceCounts
    /// Pro-only, and only ever populated for symbols someone holds or watches.
    var themes: SentimentThemesPayload?
}

struct SymbolSentimentBatchResponse: Content, Sendable {
    var windowDays: Int
    var requested: Int
    /// Symbols with a reading, keyed by symbol. A requested symbol missing from
    /// this map has no data — which is information, not an error.
    var symbols: [String: SymbolSentimentResponse]
}

struct SentimentHoldingContribution: Content, Sendable {
    var symbol: String
    var score: Double
    var label: String
    var weight: Double
    var delta1d: Double?
}

struct PortfolioSentimentResponse: Content, Sendable {
    var scope: String
    var asOfDate: String?
    var score: Double?
    var label: String
    /// Fraction of positions that actually carry a reading, 0…1. A weighted
    /// score over 30 % of a portfolio is a different claim from one over 95 %,
    /// and the UI is required to say which it is showing.
    var coverage: Double
    var symbolsCovered: Int
    var symbolsTotal: Int
    var postCount: Int
    var mostBullish: SentimentHoldingContribution?
    var mostBearish: SentimentHoldingContribution?
    var biggestMovers: [SentimentHoldingContribution]
}

struct TrendingSentimentEntry: Content, Sendable {
    var symbol: String
    var score: Double?
    var label: String
    var postCount: Int
    var volumeZ: Double?
    var delta1d: Double?
}

struct MarketTrendingResponse: Content, Sendable {
    var asOfDate: String?
    var windowDays: Int
    var mostDiscussed: [TrendingSentimentEntry]
    var bullish: [TrendingSentimentEntry]
    var bearish: [TrendingSentimentEntry]
    var biggestSwings: [TrendingSentimentEntry]
}

// MARK: - Service

protocol SentimentQuerying: Sendable {
    func batch(symbols: [String], includeThemes: Bool, on db: any Database) async throws -> SymbolSentimentBatchResponse
    func portfolio(userId: UUID, portfolioListId: UUID?, on req: Request) async throws -> PortfolioSentimentResponse
    func watchlist(userId: UUID, watchlistListId: UUID?, on req: Request) async throws -> PortfolioSentimentResponse
    func trending(limit: Int, on db: any Database) async throws -> MarketTrendingResponse
    func history(symbol: String, limit: Int, on db: any Database) async throws -> [SymbolSentimentResponse]
}

/// Read path over the materialized daily aggregates.
///
/// Never calls a provider — like `DefaultInsightsService`, everything here is
/// Postgres only, so a scraping outage degrades freshness and never latency.
struct DefaultSentimentQueryService: SentimentQuerying {
    let repo: any SentimentRepository
    let marketDataService: any MarketDataService
    let windowDays: Int

    func batch(
        symbols: [String],
        includeThemes: Bool,
        on db: any Database
    ) async throws -> SymbolSentimentBatchResponse {
        let normalized = Self.normalize(symbols)
        let rows = try await repo.latestDaily(symbols: normalized, windowDays: windowDays, on: db)

        var mapped: [String: SymbolSentimentResponse] = [:]
        for (symbol, row) in rows {
            mapped[symbol] = Self.response(from: row, includeThemes: includeThemes)
        }

        return SymbolSentimentBatchResponse(
            windowDays: windowDays,
            requested: normalized.count,
            symbols: mapped
        )
    }

    func portfolio(
        userId: UUID,
        portfolioListId: UUID?,
        on req: Request
    ) async throws -> PortfolioSentimentResponse {
        var query = Stock.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$category == .stock)
        if let portfolioListId {
            query = query.filter(\.$portfolioListId == portfolioListId)
        }
        let holdings = try await query.all()

        // Value-weight by live market value. Sentiment on a 40 % position and
        // sentiment on a 0.5 % position are not equally relevant to the owner,
        // and an equal-weighted mean would let a token holding swing the number.
        var weights: [String: Double] = [:]
        let symbols = Self.normalize(holdings.map(\.symbol))
        if !symbols.isEmpty {
            let quotes = await (try? marketDataService.quoteBatch(symbols: symbols, on: req))?.quotes ?? []
            let priceBySymbol = Dictionary(
                quotes.map { ($0.symbol.uppercased(), $0.currentPrice) },
                uniquingKeysWith: { first, _ in first }
            )
            for holding in holdings {
                let symbol = holding.symbol.trimmingCharacters(in: .whitespaces).uppercased()
                guard !symbol.isEmpty else { continue }
                // Fall back to cost basis when a quote is missing, so an
                // unquotable holding still carries its share rather than
                // silently weighting to zero.
                let price = priceBySymbol[symbol] ?? holding.buyPrice
                weights[symbol, default: 0] += holding.shares * price
            }
        }

        return try await rollUp(
            scope: "portfolio",
            symbols: symbols,
            weights: weights,
            on: req.db
        )
    }

    func watchlist(
        userId: UUID,
        watchlistListId: UUID?,
        on req: Request
    ) async throws -> PortfolioSentimentResponse {
        var query = WatchlistItem.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$status != "archived")
        if let watchlistListId {
            query = query.filter(\.$watchlistListId == watchlistListId)
        }
        let items = try await query.all()
        let symbols = Self.normalize(items.map(\.symbol))

        // Equal weight: a watchlist carries no position sizes, so there is
        // nothing to weight by and pretending otherwise would invent one.
        let weights = Dictionary(symbols.map { ($0, 1.0) }, uniquingKeysWith: { first, _ in first })

        return try await rollUp(
            scope: "watchlist",
            symbols: symbols,
            weights: weights,
            on: req.db
        )
    }

    func trending(limit: Int, on db: any Database) async throws -> MarketTrendingResponse {
        guard let asOfDate = try await repo.latestAvailableDate(windowDays: windowDays, on: db) else {
            return MarketTrendingResponse(
                asOfDate: nil,
                windowDays: windowDays,
                mostDiscussed: [],
                bullish: [],
                bearish: [],
                biggestSwings: []
            )
        }

        // Over-fetch so the bullish/bearish splits are drawn from a real pool
        // rather than from whatever happened to land in the top `limit`.
        let rows = try await repo.trending(
            asOfDate: asOfDate,
            windowDays: windowDays,
            limit: max(limit * 4, limit),
            on: db
        )
        let entries = rows.map(Self.trendingEntry(from:))

        let scored = entries.filter { $0.score != nil }
        let bullish = scored
            .filter { ($0.score ?? 0) > SentimentClassifier.labelThreshold }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        let bearish = scored
            .filter { ($0.score ?? 0) < -SentimentClassifier.labelThreshold }
            .sorted { ($0.score ?? 0) < ($1.score ?? 0) }
        let swings = entries
            .filter { $0.delta1d != nil }
            .sorted { abs($0.delta1d ?? 0) > abs($1.delta1d ?? 0) }

        return MarketTrendingResponse(
            asOfDate: asOfDate,
            windowDays: windowDays,
            mostDiscussed: Array(entries.prefix(limit)),
            bullish: Array(bullish.prefix(limit)),
            bearish: Array(bearish.prefix(limit)),
            biggestSwings: Array(swings.prefix(limit))
        )
    }

    func history(symbol: String, limit: Int, on db: any Database) async throws -> [SymbolSentimentResponse] {
        let rows = try await repo.dailyHistory(
            symbol: symbol.uppercased(),
            windowDays: windowDays,
            limit: limit,
            on: db
        )
        // Oldest first: this feeds a chart, and every caller would otherwise
        // reverse it.
        return rows.reversed().map { Self.response(from: $0, includeThemes: false) }
    }

    // MARK: - Roll-up

    private func rollUp(
        scope: String,
        symbols: [String],
        weights: [String: Double],
        on db: any Database
    ) async throws -> PortfolioSentimentResponse {
        guard !symbols.isEmpty else {
            return PortfolioSentimentResponse(
                scope: scope,
                asOfDate: nil,
                score: nil,
                label: SentimentClassifier.neutralLabel,
                coverage: 0,
                symbolsCovered: 0,
                symbolsTotal: 0,
                postCount: 0,
                mostBullish: nil,
                mostBearish: nil,
                biggestMovers: []
            )
        }

        let rows = try await repo.latestDaily(symbols: symbols, windowDays: windowDays, on: db)

        // Only positions with an actual reading participate. Renormalizing over
        // the covered subset is what makes `coverage` meaningful: the score
        // answers "among what I can see", and coverage says how much that is.
        var contributions: [SentimentHoldingContribution] = []
        var weightedSum = 0.0
        var weightTotal = 0.0
        var postCount = 0

        for symbol in symbols {
            guard let row = rows[symbol], let score = row.score else { continue }
            let weight = max(weights[symbol] ?? 0, 0)
            postCount += row.postCount
            guard weight > 0 else { continue }

            weightedSum += score * weight
            weightTotal += weight
            contributions.append(
                SentimentHoldingContribution(
                    symbol: symbol,
                    score: score,
                    label: row.label,
                    weight: weight,
                    delta1d: row.delta1d
                )
            )
        }

        let covered = contributions.count
        let coverage = symbols.isEmpty ? 0 : Double(covered) / Double(symbols.count)
        let score = weightTotal > 0 ? weightedSum / weightTotal : nil

        // Normalize weights to fractions only now that the total is known, so
        // clients get a share-of-portfolio number rather than a raw currency
        // amount they would have to divide themselves.
        let normalized = contributions.map { contribution in
            SentimentHoldingContribution(
                symbol: contribution.symbol,
                score: contribution.score,
                label: contribution.label,
                weight: weightTotal > 0 ? contribution.weight / weightTotal : 0,
                delta1d: contribution.delta1d
            )
        }

        let asOfDate = symbols.compactMap { rows[$0]?.asOfDate }.max()

        return PortfolioSentimentResponse(
            scope: scope,
            asOfDate: asOfDate,
            score: score,
            label: score.map(SentimentClassifier.label(forScore:)) ?? SentimentClassifier.neutralLabel,
            coverage: coverage,
            symbolsCovered: covered,
            symbolsTotal: symbols.count,
            postCount: postCount,
            mostBullish: normalized.max { $0.score < $1.score },
            mostBearish: normalized.min { $0.score < $1.score },
            biggestMovers: Array(
                normalized
                    .filter { $0.delta1d != nil }
                    .sorted { abs($0.delta1d ?? 0) > abs($1.delta1d ?? 0) }
                    .prefix(3)
            )
        )
    }

    // MARK: - Mapping

    static func normalize(_ symbols: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for symbol in symbols {
            let cleaned = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            ordered.append(cleaned)
        }
        return ordered
    }

    static func response(from row: SymbolSentimentDaily, includeThemes: Bool) -> SymbolSentimentResponse {
        SymbolSentimentResponse(
            symbol: row.symbol,
            asOfDate: row.asOfDate,
            score: row.score,
            label: row.label,
            confidence: row.confidence,
            postCount: row.postCount,
            delta1d: row.delta1d,
            volumeZ: row.volumeZ,
            sourceCounts: row.sourceCounts,
            themes: includeThemes ? row.themes : nil
        )
    }

    static func trendingEntry(from row: SymbolSentimentDaily) -> TrendingSentimentEntry {
        TrendingSentimentEntry(
            symbol: row.symbol,
            score: row.score,
            label: row.label,
            postCount: row.postCount,
            volumeZ: row.volumeZ,
            delta1d: row.delta1d
        )
    }
}
