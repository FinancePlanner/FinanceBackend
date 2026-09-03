import Foundation

/// A broker "withholding tax" cash line. IBKR reports these as separate
/// negative cash transactions on the dividend's pay date, not as a field on
/// the dividend itself.
struct IBKRWithholdingRow: Sendable, Equatable {
    let symbol: String
    let payDate: Date
    let amount: Double // negative in broker statements
    let currency: String
}

/// Attaches withholding lines to dividends by symbol, pay date, and currency.
/// Each withholding row is consumed at most once; unmatched rows are ignored
/// (they surface later as a nil withholding on the dividend, never as a
/// phantom dividend).
struct DividendWithholdingReconciler: Sendable {
    func apply(withholdings: [IBKRWithholdingRow], to dividends: [(symbol: String, dividend: Dividend)]) -> [Dividend] {
        var remaining = withholdings
        return dividends.map { entry in
            let dividend = entry.dividend
            let day = Calendar.utcFiling.startOfDay(for: dividend.payDate)
            let symbol = entry.symbol.uppercased()
            let currency = dividend.currency.uppercased()
            guard let index = remaining.firstIndex(where: {
                $0.symbol.uppercased() == symbol
                    && Calendar.utcFiling.startOfDay(for: $0.payDate) == day
                    && $0.currency.uppercased() == currency
            }) else {
                return dividend
            }
            let tax = abs(remaining.remove(at: index).amount)
            dividend.withholdingTax = tax
            dividend.grossAmount = dividend.amount + tax
            return dividend
        }
    }

    /// Broker transaction types that are withholding lines. IBKR's Client
    /// Portal uses "WHTAX"; Flex statements spell it out.
    static func isWithholdingType(_ type: String) -> Bool {
        let normalized = type.uppercased().replacingOccurrences(of: "_", with: " ")
        return normalized == "WHTAX" || normalized.contains("WITHHOLDING")
    }
}
