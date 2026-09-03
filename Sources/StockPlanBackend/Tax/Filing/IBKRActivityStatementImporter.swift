import Fluent
import Foundation

/// Writes a parsed IBKR activity statement into one broker account: the
/// instruments it names, every stock order as a `Transaction` run through lot
/// accounting (so `lot_disposals` exist for the filing ledger), and every
/// dividend with its withholding line attached. Used by the golden-file
/// validation; the same call is what a "upload your statement" flow would run.
struct IBKRActivityStatementImporter: Sendable {
    struct Result: Sendable, Equatable {
        let accountId: UUID
        let transactions: Int
        let lotDisposals: Int
        /// Sells with no lot to close against (position opened before the
        /// statement starts). They are stored but produce no filing row.
        let unmatchedSells: Int
        let dividends: Int
        let dividendsWithWithholding: Int
        let skippedTradeRows: Int
    }

    func importStatement(
        _ statement: IBKRActivityStatement,
        userId: UUID,
        accountExternalId: String,
        baseCurrency: String,
        on db: any Database
    ) async throws -> Result {
        let account = Account()
        account.userId = userId
        account.externalId = accountExternalId
        account.broker = "ibkr"
        account.displayName = "IBKR \(accountExternalId)"
        account.baseCurrency = baseCurrency.uppercased()
        account.taxWrapper = "taxable"
        try await account.create(on: db)
        let accountId = try account.requireID()

        let infoBySymbol = Dictionary(statement.instruments.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        var instrumentIds: [String: UUID] = [:]
        let symbols = Set(statement.trades.map(\.symbol) + statement.dividends.map(\.symbol))
        for symbol in symbols.sorted() {
            instrumentIds[symbol] = try await resolveInstrument(
                symbol: symbol,
                info: infoBySymbol[symbol],
                currency: statement.trades.first { $0.symbol == symbol }?.currency
                    ?? statement.dividends.first { $0.symbol == symbol }?.currency
                    ?? baseCurrency,
                isinHint: statement.dividends.first { $0.symbol == symbol && $0.isin != nil }?.isin,
                on: db
            )
        }

        let accounting = TaxLotAccountingService()
        var transactions = 0
        var lotDisposals = 0
        var unmatchedSells = 0
        for (index, trade) in statement.trades.enumerated() {
            guard let instrumentId = instrumentIds[trade.symbol], trade.quantity != 0 else { continue }
            let transaction = Transaction(
                accountId: accountId,
                instrumentId: instrumentId,
                externalId: "flex-\(accountExternalId)-\(index)",
                type: trade.quantity > 0 ? "BUY" : "SELL",
                quantity: abs(trade.quantity),
                price: trade.price,
                currency: trade.currency.uppercased(),
                tradeDate: trade.tradeDate,
                fees: trade.fee
            )
            try await transaction.create(on: db)
            transactions += 1
            if trade.quantity > 0 {
                _ = try await accounting.recordAcquisition(transaction: transaction, on: db)
            } else {
                do {
                    lotDisposals += try await accounting.recordDisposal(transaction: transaction, method: .fifo, on: db).count
                } catch {
                    unmatchedSells += 1
                }
            }
        }

        var pending: [(symbol: String, dividend: Dividend)] = []
        for (index, line) in statement.dividends.enumerated() {
            guard let instrumentId = instrumentIds[line.symbol] else { continue }
            let dividend = Dividend(
                accountId: accountId,
                instrumentId: instrumentId,
                externalId: "flex-div-\(accountExternalId)-\(index)",
                amount: line.amount,
                currency: line.currency.uppercased(),
                payDate: line.date
            )
            dividend.sourceCountry = FilingLedgerBuilder.sourceCountry(isin: line.isin ?? infoBySymbol[line.symbol]?.isin)
            pending.append((line.symbol, dividend))
        }
        let withholdingRows = statement.withholdingTaxes.map {
            IBKRWithholdingRow(symbol: $0.symbol, payDate: $0.date, amount: $0.amount, currency: $0.currency.uppercased())
        }
        let reconciled = DividendWithholdingReconciler().apply(withholdings: withholdingRows, to: pending)
        var withWithholding = 0
        for dividend in reconciled {
            if (dividend.withholdingTax ?? 0) != 0 {
                withWithholding += 1
            }
            try await dividend.create(on: db)
        }

        return Result(
            accountId: accountId,
            transactions: transactions,
            lotDisposals: lotDisposals,
            unmatchedSells: unmatchedSells,
            dividends: reconciled.count,
            dividendsWithWithholding: withWithholding,
            skippedTradeRows: statement.skippedTradeRows
        )
    }

    /// Instruments are global, so reuse one that already carries the symbol;
    /// otherwise create it from the statement's instrument table.
    private func resolveInstrument(
        symbol: String,
        info: IBKRActivityStatement.InstrumentInfo?,
        currency: String,
        isinHint: String?,
        on db: any Database
    ) async throws -> UUID {
        if let existing = try await Instrument.query(on: db).filter(\.$symbol == symbol).first() {
            if existing.isin == nil, let isin = info?.isin ?? isinHint {
                existing.isin = isin
                try await existing.save(on: db)
            }
            return try existing.requireID()
        }
        let instrument = Instrument(
            conid: info?.conid ?? "flex-\(symbol)",
            symbol: symbol,
            exchange: info?.listingExchange ?? "SMART",
            currency: currency.uppercased(),
            name: info?.description ?? symbol
        )
        instrument.isin = info?.isin ?? isinHint
        instrument.instrumentType = Self.instrumentType(ibkrType: info?.type)
        try await instrument.create(on: db)
        return try instrument.requireID()
    }

    static func instrumentType(ibkrType: String?) -> String {
        switch ibkrType?.uppercased() {
        case "ETF", "ETN", "FUND": "etf"
        default: "stock"
        }
    }
}
