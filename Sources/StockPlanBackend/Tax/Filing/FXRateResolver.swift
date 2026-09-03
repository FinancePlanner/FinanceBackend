import Fluent
import Foundation

/// One ECB reference fixing: 1 EUR = `rate` units of `quote` on `date`.
struct FXDailyRate: Sendable, Equatable {
    let date: Date
    let base: String
    let quote: String
    let rate: Decimal
}

protocol FXDailyRateProviding: Sendable {
    /// Every published fixing for `quote` against EUR in the inclusive range.
    func rates(quote: String, from: Date, to: Date) async throws -> [FXDailyRate]
}

enum FXRateResolverError: Error, Equatable {
    case noFixing(currency: String, on: Date)
    case unsupportedReportingCurrency(String)
}

struct FXConversion: Sendable, Equatable, Codable {
    let amount: Decimal
    let rate: Decimal
    let fixingDate: Date
    let sourceCurrency: String
}

/// Converts trade-currency amounts into the reporting currency at the ECB
/// reference rate for the operation date. Portugal (and the other euro-area
/// packs) accept the ECB fixing; when a date has none — weekends, TARGET
/// holidays — the last published fixing before it is used, and that date is
/// returned so every filing row can show the rate it was built with.
struct FXRateResolver: Sendable {
    private let provider: any FXDailyRateProviding
    private let db: (any Database)?
    /// Ten calendar days covers the longest TARGET closure run (Christmas → New Year).
    private let maxLookbackDays = 10

    init(provider: any FXDailyRateProviding, db: (any Database)?) {
        self.provider = provider
        self.db = db
    }

    func convert(_ amount: Decimal, from currency: String, to reportingCurrency: String, on date: Date) async throws -> FXConversion {
        let from = currency.uppercased()
        let to = reportingCurrency.uppercased()
        if from == to {
            return FXConversion(amount: amount, rate: 1, fixingDate: date, sourceCurrency: from)
        }
        guard to == "EUR" else {
            throw FXRateResolverError.unsupportedReportingCurrency(to)
        }
        let day = Calendar.utcFiling.startOfDay(for: date)
        guard let start = Calendar.utcFiling.date(byAdding: .day, value: -maxLookbackDays, to: day) else {
            throw FXRateResolverError.noFixing(currency: from, on: day)
        }
        let rows = try await cachedRates(quote: from, from: start, to: day)
        guard let fixing = rows.filter({ $0.date <= day }).max(by: { $0.date < $1.date }) else {
            throw FXRateResolverError.noFixing(currency: from, on: day)
        }
        // ECB quotes 1 EUR = rate FROM, so FROM → EUR divides.
        let converted = (amount / fixing.rate).roundedForFiling(scale: 2)
        return FXConversion(amount: converted, rate: fixing.rate, fixingDate: fixing.date, sourceCurrency: from)
    }

    private func cachedRates(quote: String, from: Date, to: Date) async throws -> [FXDailyRate] {
        if let db {
            let cached = try await FXDailyRateModel.query(on: db)
                .filter(\.$quote == quote)
                .filter(\.$date >= from)
                .filter(\.$date <= to)
                .all()
            if !cached.isEmpty {
                return cached.map(\.value)
            }
        }
        let fresh = try await provider.rates(quote: quote, from: from, to: to)
        if let db {
            for row in fresh {
                // The unique index makes a concurrent re-insert fail; that is fine.
                try? await FXDailyRateModel(value: row).create(on: db)
            }
        }
        return fresh
    }
}

extension Calendar {
    /// Gregorian, UTC. Filing dates are calendar dates, never local times.
    static let utcFiling: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

extension Decimal {
    /// Bankers' rounding to `scale` places — what tax forms expect for money.
    func roundedForFiling(scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .bankers)
        return result
    }
}
