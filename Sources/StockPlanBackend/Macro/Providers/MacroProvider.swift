import Foundation
import StockPlanShared
import Vapor

/// Countries with first-class macro/inflation support.
enum MacroCountry: String, CaseIterable {
    case us = "US"
    case br = "BR"
    case pt = "PT"
    case es = "ES"
    case de = "DE"
    case fr = "FR"
    case it = "IT"
    case ea = "EA"

    /// Accepts case-insensitive input plus legacy aliases ("EURO" → EA).
    init?(query raw: String?) {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch normalized {
        case "US": self = .us
        case "BR": self = .br
        case "PT": self = .pt
        case "ES": self = .es
        case "DE": self = .de
        case "FR": self = .fr
        case "IT": self = .it
        case "EA", "EURO", "EZ": self = .ea
        default: return nil
        }
    }

    var currency: String {
        switch self {
        case .us: "USD"
        case .br: "BRL"
        case .pt, .es, .de, .fr, .it, .ea: "EUR"
        }
    }

    var displayName: String {
        switch self {
        case .us: "United States"
        case .br: "Brazil"
        case .pt: "Portugal"
        case .es: "Spain"
        case .de: "Germany"
        case .fr: "France"
        case .it: "Italy"
        case .ea: "Euro Area"
        }
    }

    /// Countries whose data comes from Eurostat/ECB (euro-area members plus the
    /// EA aggregate itself).
    var isEuroArea: Bool {
        switch self {
        case .pt, .es, .de, .fr, .it, .ea: true
        case .us, .br: false
        }
    }

    /// Eurostat `geo` dimension code. The EA aggregate uses the 20-member code.
    var eurostatGeo: String {
        self == .ea ? "EA20" : rawValue
    }
}

/// Registry of series keys stored in `macro_series_points.series_key`.
/// Item price series use the `item.<id>` convention (see `itemKey`).
enum MacroSeriesKey: String, CaseIterable {
    case headlineCPI = "headline_cpi"
    case coreCPI = "core_cpi"
    case pce
    case corePCE = "core_pce"
    case trimmedMeanCPI = "trimmed_mean_cpi"
    case energyCPI = "energy_cpi"
    case foodCPI = "food_cpi"
    case nowflationGauge = "nowflation_gauge"
    case treasury2Y = "dgs2"
    case treasury10Y = "dgs10"
    case real10Y = "dfii10"
    case breakeven10Y = "t10yie"
    // Housing (lite)
    case hpiYoY = "hpi_yoy"
    case mortgageRate = "mortgage_rate"
    case rentYoY = "rent_yoy"
    case housingStarts = "housing_starts"
    case monthsSupply = "months_supply"
    // Economy / labor (lite)
    case unemployment
    case gdpGrowth = "gdp_growth"
    case payrolls
    case initialClaims = "initial_claims"
    case policyRate = "policy_rate"
    case nberRecession = "nber_recession"
    // Rates / sentiment / wages (added for full tax-jurisdiction coverage)
    case govBond10Y = "gov_bond_10y"
    case consumerConfidence = "consumer_confidence"
    case wageGrowth = "wage_growth"

    static func itemKey(_ itemID: String) -> String {
        "item.\(itemID)"
    }

    /// Maps legacy client series names ("nowflation_cpi", "official_cpi",
    /// "headline") onto stored keys so old iOS builds keep working.
    static func resolve(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return MacroSeriesKey.headlineCPI.rawValue }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "headline", "official_cpi", "cpi": return MacroSeriesKey.headlineCPI.rawValue
        case "nowflation_cpi": return MacroSeriesKey.nowflationGauge.rawValue
        case "core", "core_cpi": return MacroSeriesKey.coreCPI.rawValue
        default: return normalized
        }
    }
}

/// Snapshot plus the raw series points backing it, ready for persistence.
struct MacroProviderResult {
    var snapshot: InflationSnapshotResponse
    var points: [MacroSeriesPointRecord]
}

/// A primary/fallback data source for one or more countries.
protocol MacroProvider: Sendable {
    var name: String { get }
    func supports(_ country: MacroCountry) -> Bool
    func fetchSnapshot(country: MacroCountry, on req: Request) async throws -> MacroProviderResult
}

/// Optional layer applied on top of a primary result (e.g. Nowflation daily
/// gauge on top of official FRED numbers). Must never fail the refresh:
/// implementations return the input unchanged on any error.
protocol MacroEnrichmentProviding: Sendable {
    var name: String { get }
    var isEnabled: Bool { get }
    func enrich(_ result: MacroProviderResult, country: MacroCountry, on req: Request) async -> MacroProviderResult
}

struct DisabledMacroProvider: MacroProvider {
    let name = "disabled"

    func supports(_: MacroCountry) -> Bool {
        false
    }

    func fetchSnapshot(country: MacroCountry, on _: Request) async throws -> MacroProviderResult {
        throw Abort(.serviceUnavailable, reason: "Macro data provider is disabled for \(country.rawValue).")
    }
}
