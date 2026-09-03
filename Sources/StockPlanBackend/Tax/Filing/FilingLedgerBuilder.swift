import Fluent
import Foundation
import StockPlanShared

/// Turns one user's `lot_disposals` and `dividends` for a tax year into a
/// `FilingLedger` in the reporting currency. Reads only; never re-matches lots.
struct FilingLedgerBuilder: Sendable {
    let fx: FXRateResolver

    func build(
        userId: UUID,
        taxYear: Int,
        jurisdiction: TaxJurisdiction,
        reportingCurrency: String,
        on db: any Database
    ) async throws -> FilingLedger {
        let calendar = Calendar.utcFiling
        guard let yearStart = calendar.date(from: DateComponents(year: taxYear, month: 1, day: 1)),
              let yearEnd = calendar.date(from: DateComponents(year: taxYear + 1, month: 1, day: 1))
        else {
            return FilingLedger(taxYear: taxYear, reportingCurrency: reportingCurrency, jurisdiction: jurisdiction, disposals: [], dividends: [], unsupported: [])
        }

        let accountIds = try await Account.query(on: db).filter(\.$userId == userId).all().compactMap(\.id)
        guard !accountIds.isEmpty else {
            return FilingLedger(taxYear: taxYear, reportingCurrency: reportingCurrency, jurisdiction: jurisdiction, disposals: [], dividends: [], unsupported: [])
        }

        // Sell legs inside the year, then their disposals, lots, and buy legs.
        let sells = try await Transaction.query(on: db)
            .filter(\.$accountId ~~ accountIds)
            .filter(\.$type == "SELL")
            .filter(\.$tradeDate >= yearStart)
            .filter(\.$tradeDate < yearEnd)
            .all()
        let sellIds = sells.compactMap(\.id)
        let disposals = sellIds.isEmpty ? [] : try await LotDisposal.query(on: db).filter(\.$transactionId ~~ sellIds).all()
        let lotIds = Array(Set(disposals.map(\.lotId)))
        let lots = lotIds.isEmpty ? [] : try await Lot.query(on: db).filter(\.$id ~~ lotIds).all()
        let lotById = Dictionary(uniqueKeysWithValues: lots.compactMap { lot in lot.id.map { ($0, lot) } })
        let buyIds = lots.compactMap(\.openTransactionId)
        let buys = buyIds.isEmpty ? [] : try await Transaction.query(on: db).filter(\.$id ~~ buyIds).all()
        let transactionById = Dictionary(uniqueKeysWithValues: (sells + buys).compactMap { tx in tx.id.map { ($0, tx) } })

        let dividends = try await Dividend.query(on: db)
            .filter(\.$accountId ~~ accountIds)
            .filter(\.$payDate >= yearStart)
            .filter(\.$payDate < yearEnd)
            .all()

        let instrumentIds = Array(Set(sells.map(\.instrumentId) + dividends.map(\.instrumentId)))
        let instruments = instrumentIds.isEmpty ? [] : try await Instrument.query(on: db).filter(\.$id ~~ instrumentIds).all()
        let instrumentById = Dictionary(uniqueKeysWithValues: instruments.compactMap { i in i.id.map { ($0, i) } })

        var rows: [FilingDisposal] = []
        var unsupported: [FilingUnsupportedRow] = []
        for disposal in disposals {
            guard let disposalId = disposal.id,
                  let sell = transactionById[disposal.transactionId],
                  let lot = lotById[disposal.lotId],
                  let instrument = instrumentById[sell.instrumentId]
            else {
                unsupported.append(FilingUnsupportedRow(reason: "Disposal is missing its lot, sell, or instrument", reference: disposal.id?.uuidString ?? "unknown"))
                continue
            }
            let buy = lot.openTransactionId.flatMap { transactionById[$0] }
            let acquisitionDate = buy?.tradeDate ?? lot.openDate
            let quantity = Decimal(disposal.quantity)
            let sellQuantity = Decimal(sell.quantity.map(abs) ?? disposal.quantity)
            let sellFees = Decimal(sell.fees ?? 0) * (sellQuantity > 0 ? quantity / sellQuantity : 1)

            let acquisition = try await fx.convert(Decimal(disposal.costBasis), from: lot.currency, to: reportingCurrency, on: acquisitionDate)
            let realization = try await fx.convert(Decimal(disposal.proceeds), from: sell.currency, to: reportingCurrency, on: sell.tradeDate)
            let expenses = try await fx.convert(sellFees.roundedForFiling(scale: 2), from: sell.currency, to: reportingCurrency, on: sell.tradeDate)

            rows.append(FilingDisposal(
                symbol: instrument.symbol,
                isin: instrument.isin,
                instrumentType: (instrument.instrumentType ?? "stock").lowercased(),
                quantity: quantity,
                acquisitionDate: acquisitionDate,
                acquisitionValue: acquisition.amount,
                realizationDate: sell.tradeDate,
                realizationValue: realization.amount,
                expenses: expenses.amount,
                gain: realization.amount - acquisition.amount,
                holdingPeriod: disposal.holdingPeriod,
                sourceCountry: Self.sourceCountry(isin: instrument.isin),
                fx: [acquisition, realization],
                lotDisposalID: disposalId
            ))
        }

        var dividendRows: [FilingDividend] = []
        for dividend in dividends {
            guard let dividendId = dividend.id else { continue }
            let instrument = instrumentById[dividend.instrumentId]
            let grossNative = Decimal(dividend.grossAmount ?? dividend.amount)
            let withholdingNative = Decimal(dividend.withholdingTax ?? 0)
            let gross = try await fx.convert(grossNative, from: dividend.currency, to: reportingCurrency, on: dividend.payDate)
            let withholding = try await fx.convert(withholdingNative, from: dividend.currency, to: reportingCurrency, on: dividend.payDate)
            dividendRows.append(FilingDividend(
                symbol: instrument?.symbol ?? "?",
                payDate: dividend.payDate,
                sourceCountry: dividend.sourceCountry ?? Self.sourceCountry(isin: instrument?.isin),
                gross: gross.amount,
                withholding: withholding.amount,
                net: gross.amount - withholding.amount,
                fx: gross,
                dividendID: dividendId
            ))
        }

        return FilingLedger(
            taxYear: taxYear,
            reportingCurrency: reportingCurrency.uppercased(),
            jurisdiction: jurisdiction,
            disposals: rows.sorted { $0.realizationDate < $1.realizationDate },
            dividends: dividendRows.sorted { $0.payDate < $1.payDate },
            unsupported: unsupported
        )
    }

    /// The ISIN prefix is the issuer's country, which is what "país da fonte"
    /// asks for. No ISIN, no country: the mapper leaves the column blank.
    static func sourceCountry(isin: String?) -> String? {
        guard let isin = isin?.trimmingCharacters(in: .whitespaces).uppercased(), isin.count >= 2 else { return nil }
        let prefix = String(isin.prefix(2))
        return prefix.allSatisfy(\.isLetter) ? prefix : nil
    }
}
