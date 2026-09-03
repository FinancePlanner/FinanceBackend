import Foundation
import StockPlanShared

/// One matched disposal (a sell leg against one lot), already in the
/// reporting currency. The pack never re-matches lots: it reports what
/// `lot_disposals` recorded, converted at the operation dates.
struct FilingDisposal: Sendable, Equatable, Codable {
    let symbol: String
    let isin: String?
    let instrumentType: String
    let quantity: Decimal
    let acquisitionDate: Date
    let acquisitionValue: Decimal // cost basis incl. buy fees (TaxAcquisitionBasisCalculator)
    let realizationDate: Date
    let realizationValue: Decimal // proceeds net of sell fees, as the ledger recorded
    let expenses: Decimal // sell-leg fees attributable to this lot slice
    let gain: Decimal // realizationValue - acquisitionValue
    let holdingPeriod: String
    let sourceCountry: String?
    let fx: [FXConversion]
    let lotDisposalID: UUID
}

struct FilingDividend: Sendable, Equatable, Codable {
    let symbol: String
    let payDate: Date
    let sourceCountry: String?
    let gross: Decimal
    let withholding: Decimal
    let net: Decimal
    let fx: FXConversion
    let dividendID: UUID
}

/// A row the pack could not place; shown to the user, never dropped.
struct FilingUnsupportedRow: Sendable, Equatable, Codable {
    let reason: String
    let reference: String
}

/// One fund's Vorabpauschale for the tax year, already in the reporting
/// currency; feeds Anlage KAP-INV Zeile 9–13.
struct GermanyFilingAdvanceLumpSum: Sendable, Equatable, Codable {
    let symbol: String
    let classification: TaxFundClassification
    let gross: Decimal
}

/// What the German pack needs beyond trades and dividends. Filled by the
/// builder only for `.germany`; the mapper stays a pure function of the ledger.
struct GermanyFilingSupplement: Sendable, Equatable, Codable {
    /// InvStG classification per symbol for every fund-type instrument in the
    /// ledger (`.unknown` when the user has not classified it yet).
    let fundClassifications: [String: TaxFundClassification]
    let advanceLumpSums: [GermanyFilingAdvanceLumpSum]
    /// Ending carry-forwards recorded for the previous tax year, if any.
    let priorStockLossCarryforward: Decimal?
    let priorGeneralLossCarryforward: Decimal?
}

struct FilingLedger: Sendable, Equatable, Codable {
    let taxYear: Int
    let reportingCurrency: String
    let jurisdiction: TaxJurisdiction
    let disposals: [FilingDisposal]
    let dividends: [FilingDividend]
    let unsupported: [FilingUnsupportedRow]
    var germany: GermanyFilingSupplement? = nil

    var totalGain: Decimal {
        disposals.map(\.gain).reduce(0, +)
    }

    var totalDividendsGross: Decimal {
        dividends.map(\.gross).reduce(0, +)
    }

    var totalWithholding: Decimal {
        dividends.map(\.withholding).reduce(0, +)
    }
}
