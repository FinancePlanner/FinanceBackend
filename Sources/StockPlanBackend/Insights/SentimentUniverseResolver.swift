import Fluent
import Foundation
import Vapor

/// Decides which symbols the daily aggregation job is responsible for, and how
/// much of the ingestion budget each is allowed to spend.
///
/// Tier A is recomputed from live holdings and watchlists every run, so a symbol
/// a user added this morning is covered tonight. Tier B is index membership,
/// seeded out of band. Tier C is whatever the firehose surfaced that nobody
/// holds — capped hard, because it is the tier with no user asking for it.
struct SentimentUniverseResolver: Sendable {
    let insightsRepo: any InsightsRepository
    let sentimentRepo: any SentimentRepository
    /// Symbols pinned by `HERMES_TRACKED_TICKERS`. Folded into Tier A so an
    /// operator-pinned symbol is never demoted by the automatic tiering.
    let pinnedSymbols: [String]
    let userTierLimit: Int
    let trendingTierLimit: Int

    struct Resolved: Sendable {
        var symbol: String
        var tier: SentimentTier
    }

    /// Refreshes tier membership, then returns the work list in spend order.
    func resolve(on db: any Database) async throws -> [Resolved] {
        let tracked = try await insightsRepo.allTrackedSymbols(limit: userTierLimit, on: db)

        var userTier: [String] = []
        var seen = Set<String>()
        for symbol in pinnedSymbols + tracked where seen.insert(symbol).inserted {
            userTier.append(symbol)
        }
        userTier = Array(userTier.prefix(userTierLimit))

        try await sentimentRepo.replaceUniverseTier(.user, symbols: userTier, on: db)

        let rows = try await sentimentRepo.universe(on: db)

        // Retire the coldest trending symbols over the cap. They have no user
        // behind them, so the only cost of dropping one is that it re-enters if
        // it stays loud.
        let trending = rows
            .filter { $0.resolvedTier == .trending }
            .sorted { lhs, rhs in
                (lhs.lastIngestedAt ?? .distantPast) > (rhs.lastIngestedAt ?? .distantPast)
            }
        let keptTrending = Set(trending.prefix(trendingTierLimit).map(\.symbol))

        return rows
            .compactMap { row -> Resolved? in
                let tier = row.resolvedTier
                if tier == .trending, !keptTrending.contains(row.symbol) {
                    return nil
                }
                return Resolved(symbol: row.symbol, tier: tier)
            }
            .sorted { lhs, rhs in
                if lhs.tier.priority != rhs.tier.priority {
                    return lhs.tier.priority < rhs.tier.priority
                }
                return lhs.symbol < rhs.symbol
            }
    }
}

/// Populates the `.sp500` tier.
///
/// The constituent list is fetched or configured rather than hardcoded on
/// purpose. Index membership changes several times a year, and a literal baked
/// into the binary is wrong the moment it ships — silently, since a missing
/// symbol looks identical to a quiet one.
///
/// Resolution order: `SENTIMENT_SP500_SYMBOLS` (explicit operator override),
/// then FMP's constituent endpoint when `FMP_API_KEY` is set. Neither present
/// means the tier stays empty and the universe is user symbols only, which
/// degrades coverage without breaking anything.
struct SentimentIndexSeeder: Sendable {
    let sentimentRepo: any SentimentRepository
    let fmpAPIKey: String?
    let overrideSymbols: [String]

    func seed(on req: Request) async throws -> Int {
        let symbols = try await resolveSymbols(on: req)
        guard !symbols.isEmpty else {
            req.logger.notice("sentiment.universe sp500 seed skipped: no override and no FMP key")
            return 0
        }
        try await sentimentRepo.replaceUniverseTier(.sp500, symbols: symbols, on: req.db)
        return symbols.count
    }

    private func resolveSymbols(on req: Request) async throws -> [String] {
        if !overrideSymbols.isEmpty {
            return overrideSymbols
        }
        guard let fmpAPIKey, !fmpAPIKey.isEmpty else { return [] }

        let uri = URI(string: "https://financialmodelingprep.com/api/v3/sp500_constituent?apikey=\(fmpAPIKey)")
        let response = try await req.client.get(uri)
        guard response.status == .ok else {
            req.logger.warning("sentiment.universe sp500 fetch failed status=\(response.status.code)")
            return []
        }

        let constituents = try response.content.decode([FMPConstituent].self)
        return constituents
            .map { $0.symbol.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }

    private struct FMPConstituent: Content {
        let symbol: String
    }
}
