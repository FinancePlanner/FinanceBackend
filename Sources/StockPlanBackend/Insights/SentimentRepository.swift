import Fluent
import Foundation
import SQLKit

/// Persistence for the materialized daily sentiment aggregates and the symbol
/// universe the aggregation job walks.
///
/// Kept separate from `InsightsRepository`, which owns the raw Hermes event and
/// post tables. The split is along lifecycle: that one records what was
/// observed, this one records what was computed.
protocol SentimentRepository: Sendable {
    func upsertDaily(_ row: SymbolSentimentDaily, on db: any Database) async throws
    func latestDaily(symbols: [String], windowDays: Int, on db: any Database) async throws -> [String: SymbolSentimentDaily]
    func dailyHistory(symbol: String, windowDays: Int, limit: Int, on db: any Database) async throws -> [SymbolSentimentDaily]
    func trending(asOfDate: String, windowDays: Int, limit: Int, on db: any Database) async throws -> [SymbolSentimentDaily]
    func latestAvailableDate(windowDays: Int, on db: any Database) async throws -> String?

    func universe(on db: any Database) async throws -> [SentimentUniverseSymbol]
    func replaceUniverseTier(_ tier: SentimentTier, symbols: [String], on db: any Database) async throws
    func addTrendingSymbols(_ symbols: [String], on db: any Database) async throws
    func markIngested(symbols: [String], at date: Date, on db: any Database) async throws

    func deletePosts(olderThan cutoff: Date, on db: any Database) async throws -> Int
    func deleteDaily(olderThan cutoffDate: String, on db: any Database) async throws -> Int
}

struct DatabaseSentimentRepository: SentimentRepository {
    /// How many days back `latestDaily` will look for a row. A symbol that has
    /// not been scored in this long is reported as having no reading at all,
    /// rather than surfacing a stale score with a fresh-looking badge.
    static let stalenessWindowDays = 3

    // MARK: - Daily aggregates

    func upsertDaily(_ row: SymbolSentimentDaily, on db: any Database) async throws {
        let existing = try await SymbolSentimentDaily.query(on: db)
            .filter(\.$symbol == row.symbol)
            .filter(\.$asOfDate == row.asOfDate)
            .filter(\.$windowDays == row.windowDays)
            .first()

        guard let existing else {
            try await row.save(on: db)
            return
        }

        existing.score = row.score
        existing.label = row.label
        existing.confidence = row.confidence
        existing.postCount = row.postCount
        existing.positiveCount = row.positiveCount
        existing.neutralCount = row.neutralCount
        existing.negativeCount = row.negativeCount
        existing.sourceCounts = row.sourceCounts
        existing.volumeZ = row.volumeZ
        existing.delta1d = row.delta1d
        existing.capturedAt = row.capturedAt
        // Themes are generated in a later pass and cost money. Never clear an
        // existing set by re-running the cheap aggregation over the same day.
        if let themes = row.themes {
            existing.themes = themes
            existing.themesGeneratedAt = row.themesGeneratedAt
        }
        try await existing.update(on: db)
    }

    /// Newest row per symbol, within the staleness window.
    ///
    /// Deliberately not a `DISTINCT ON`: the bound is
    /// `symbols.count * stalenessWindowDays` rows (a few hundred at the 100-symbol
    /// API cap), the `(symbol, as_of_date)` index covers it, and staying in
    /// Fluent keeps this testable on any driver.
    func latestDaily(
        symbols: [String],
        windowDays: Int,
        on db: any Database
    ) async throws -> [String: SymbolSentimentDaily] {
        guard !symbols.isEmpty else { return [:] }
        let cutoff = SentimentDate.string(
            for: Date().addingTimeInterval(-Double(Self.stalenessWindowDays) * 86400)
        )

        let rows = try await SymbolSentimentDaily.query(on: db)
            .filter(\.$symbol ~~ symbols)
            .filter(\.$windowDays == windowDays)
            .filter(\.$asOfDate >= cutoff)
            .all()

        var newest: [String: SymbolSentimentDaily] = [:]
        for row in rows {
            if let current = newest[row.symbol], current.asOfDate >= row.asOfDate {
                continue
            }
            newest[row.symbol] = row
        }
        return newest
    }

    func dailyHistory(
        symbol: String,
        windowDays: Int,
        limit: Int,
        on db: any Database
    ) async throws -> [SymbolSentimentDaily] {
        try await SymbolSentimentDaily.query(on: db)
            .filter(\.$symbol == symbol)
            .filter(\.$windowDays == windowDays)
            .sort(\.$asOfDate, .descending)
            .limit(limit)
            .all()
    }

    func trending(
        asOfDate: String,
        windowDays: Int,
        limit: Int,
        on db: any Database
    ) async throws -> [SymbolSentimentDaily] {
        try await SymbolSentimentDaily.query(on: db)
            .filter(\.$asOfDate == asOfDate)
            .filter(\.$windowDays == windowDays)
            .filter(\.$volumeZ != nil)
            .sort(\.$volumeZ, .descending)
            .limit(limit)
            .all()
    }

    func latestAvailableDate(windowDays: Int, on db: any Database) async throws -> String? {
        try await SymbolSentimentDaily.query(on: db)
            .filter(\.$windowDays == windowDays)
            .sort(\.$asOfDate, .descending)
            .first()?
            .asOfDate
    }

    // MARK: - Universe

    func universe(on db: any Database) async throws -> [SentimentUniverseSymbol] {
        try await SentimentUniverseSymbol.query(on: db).all()
    }

    /// Rewrites one tier wholesale. Used for `.user` every run (holdings change
    /// constantly) and for `.sp500` on reseed.
    ///
    /// A symbol promoted into this tier is moved rather than duplicated —
    /// `symbol` is unique, and tier is the mutable part.
    func replaceUniverseTier(
        _ tier: SentimentTier,
        symbols: [String],
        on db: any Database
    ) async throws {
        let desired = Set(symbols)
        let existing = try await SentimentUniverseSymbol.query(on: db).all()
        let bySymbol = Dictionary(existing.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })

        // Demote rows that left this tier. They are not deleted: a symbol that
        // drops out of every user's portfolio is still worth tracking while it
        // is loud, and the trending cap will retire it.
        for row in existing where row.tier == tier.rawValue && !desired.contains(row.symbol) {
            row.tier = SentimentTier.trending.rawValue
            try await row.update(on: db)
        }

        for symbol in desired {
            if let row = bySymbol[symbol] {
                guard row.tier != tier.rawValue else { continue }
                // Only ever promote toward the higher-priority tier.
                if tier.priority <= (SentimentTier(rawValue: row.tier)?.priority ?? Int.max) {
                    row.tier = tier.rawValue
                    try await row.update(on: db)
                }
            } else {
                try await SentimentUniverseSymbol(symbol: symbol, tier: tier).save(on: db)
            }
        }
    }

    func addTrendingSymbols(_ symbols: [String], on db: any Database) async throws {
        guard !symbols.isEmpty else { return }
        let existing = try await SentimentUniverseSymbol.query(on: db)
            .filter(\.$symbol ~~ symbols)
            .all()
            .map(\.symbol)
        let existingSet = Set(existing)

        for symbol in symbols where !existingSet.contains(symbol) {
            try await SentimentUniverseSymbol(symbol: symbol, tier: .trending).save(on: db)
        }
    }

    func markIngested(symbols: [String], at date: Date, on db: any Database) async throws {
        guard !symbols.isEmpty else { return }
        try await SentimentUniverseSymbol.query(on: db)
            .filter(\.$symbol ~~ symbols)
            .set(\.$lastIngestedAt, to: date)
            .update()
    }

    // MARK: - Retention

    func deletePosts(olderThan cutoff: Date, on db: any Database) async throws -> Int {
        let doomed = try await TickerSentimentPost.query(on: db)
            .filter(\.$postedAt < cutoff)
            .count()
        guard doomed > 0 else { return 0 }

        try await TickerSentimentPost.query(on: db)
            .filter(\.$postedAt < cutoff)
            .delete()
        return doomed
    }

    func deleteDaily(olderThan cutoffDate: String, on db: any Database) async throws -> Int {
        let doomed = try await SymbolSentimentDaily.query(on: db)
            .filter(\.$asOfDate < cutoffDate)
            .count()
        guard doomed > 0 else { return 0 }

        try await SymbolSentimentDaily.query(on: db)
            .filter(\.$asOfDate < cutoffDate)
            .delete()
        return doomed
    }
}

/// `yyyy-MM-dd` in UTC. The single place that decides what "today" means for
/// sentiment, so a job running at 23:58 local and a query at 00:02 agree.
enum SentimentDate {
    static func string(for date: Date) -> String {
        formatter.string(from: date)
    }

    static func today() -> String {
        string(for: Date())
    }

    static func daysAgo(_ days: Int, from date: Date = Date()) -> String {
        string(for: date.addingTimeInterval(-Double(days) * 86400))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
