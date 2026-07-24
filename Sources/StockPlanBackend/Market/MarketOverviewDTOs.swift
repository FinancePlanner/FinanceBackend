import Vapor

// MARK: - /v1/market/overview response

struct MarketOverviewResponse: Content, Equatable {
    let indices: [MarketIndexQuote]
    let gainers: [MarketMover]
    let losers: [MarketMover]
    let heatmap: [MarketHeatmapTile]
    let asOf: String
}

struct MarketIndexQuote: Content, Equatable {
    let symbol: String
    let label: String
    let price: Double
    let changePct: Double
    /// True when the value comes from the ETF proxy (free FMP tier) rather
    /// than the index itself.
    let isProxy: Bool
}

struct MarketMover: Content, Equatable {
    let symbol: String
    let name: String
    let price: Double
    let changePct: Double
}

struct MarketHeatmapTile: Content, Equatable {
    let symbol: String
    let name: String
    let sector: String
    let marketCap: Double
    let changePct: Double
}

// MARK: - FMP wire models

/// `/stable/biggest-gainers` and `/stable/biggest-losers` item.
struct FMPMoverItem: Codable, Sendable {
    let symbol: String
    let name: String?
    let price: Double?
    let change: Double?
    let changesPercentage: Double?
}

/// `/stable/company-screener` item (only the fields the overview needs).
struct FMPScreenerItem: Codable, Sendable {
    let symbol: String
    let companyName: String?
    let marketCap: Double?
    let sector: String?
    let isEtf: Bool?
    let isActivelyTrading: Bool?
}
