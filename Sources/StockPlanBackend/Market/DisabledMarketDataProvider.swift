import Foundation
import Vapor

struct MarketDataProviderDisabledError: AbortError {
    let status: HTTPResponseStatus = .serviceUnavailable
    let reason = "Market data provider is disabled."
}

/// No configured provider could price this symbol — the primary returned an
/// empty quote and the FMP fallback had nothing (or is not licensed for it).
///
/// Distinct from `MarketDataProviderDisabledError`: the provider may be perfectly
/// healthy and simply not cover the symbol, which is the common case for non-US
/// listings on Finnhub. Composite endpoints that must not fail a whole screen
/// catch this and degrade, the way they already do for the disabled provider.
struct MarketQuoteUnavailableError: AbortError {
    let symbol: String
    let status: HTTPResponseStatus = .notFound
    var reason: String { "No quote is available for \(symbol)." }
}

struct DisabledMarketDataProvider: MarketDataProvider {
    var name: String {
        "disabled"
    }

    func quote(symbol: String, on _: Request) async throws -> MarketProviderQuote {
        MarketProviderQuote(symbol: symbol, price: 0, change: nil, percentChange: nil, high: nil, low: nil, open: nil, previousClose: nil, currency: "USD", asOf: Date())
    }

    func history(symbol _: String, from _: Date?, to _: Date?, on _: Request) async throws
        -> MarketProviderHistory
    {
        throw MarketDataProviderDisabledError()
    }

    func search(query _: String, on _: Request) async throws -> [MarketProviderSearchResult] {
        throw MarketDataProviderDisabledError()
    }

    func fx(base _: String, quote _: String, on _: Request) async throws -> MarketProviderFxRate {
        throw MarketDataProviderDisabledError()
    }

    func profile(symbol _: String, on _: Request) async throws -> MarketProviderCompanyProfile? {
        throw MarketDataProviderDisabledError()
    }

    func basicFinancials(symbol _: String, on _: Request) async throws -> MarketProviderBasicFinancials? {
        throw MarketDataProviderDisabledError()
    }
}
