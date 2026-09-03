import Fluent
import Foundation
import StockPlanShared
import Vapor

struct IBKRBrokerGatewayClient {
    let baseURL: String
    let defaultCurrency: String
    let accessToken: String?

    init(
        baseURL: String = Environment.get("IBKR_API_BASE_URL") ?? "http://localhost:5000/v1/api",
        defaultCurrency: String = Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD",
        accessToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.defaultCurrency = defaultCurrency
        self.accessToken = accessToken
    }

    func checkAuthStatus(on req: Request) async throws -> Bool {
        let response = try await get(path: "/iserver/auth/status", on: req)
        guard response.status == .ok else { return false }
        if let status = try? response.content.decode(IBKRAuthStatus.self) {
            return status.authenticated == true
        }
        return false
    }

    func reauthenticate(on req: Request) async throws {
        let response = try await post(path: "/iserver/reauthenticate", on: req)
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR reauthentication failed with status \(response.status.code).")
        }
    }

    func requirePrimaryAccount(on req: Request) async throws -> IBKRBrokerAccount {
        let accounts = try await fetchAccounts(on: req)
        guard let account = accounts.first else {
            throw Abort(.badGateway, reason: "IBKR did not return any accounts.")
        }
        return account
    }

    func fetchPositions(accountID: String, on req: Request) async throws -> [IBKRBrokerPosition] {
        let response = try await withRetry(on: req) {
            try await get(path: "/portfolio/\(accountID)/positions/0", on: req)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR positions request failed with status \(response.status.code).")
        }

        if let positions = try? response.content.decode([IBKRBrokerPositionPayload].self) {
            return positions.compactMap { $0.toPosition(defaultCurrency: defaultCurrency) }
        }

        if let envelope = try? response.content.decode(IBKRBrokerPositionsEnvelope.self) {
            return envelope.positions.compactMap { $0.toPosition(defaultCurrency: defaultCurrency) }
        }

        throw Abort(.badGateway, reason: "IBKR positions response format was not recognized.")
    }

    func fetchContractInfo(conid: String, on req: Request) async throws -> IBKRContractInfo? {
        let response = try await withRetry(on: req) {
            try await get(path: "/iserver/contract/\(conid)/info", on: req)
        }
        guard response.status == .ok else { return nil }
        return try? response.content.decode(IBKRContractInfoPayload.self).toContractInfo()
    }

    func fetchTransactions(accountID: String, from: Date, to: Date, on req: Request) async throws -> [IBKRBrokerTransaction] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let fromStr = formatter.string(from: from)
        let toStr = formatter.string(from: to)

        let response = try await withRetry(on: req) {
            try await get(path: "/pa/transactions?accountId=\(accountID)&from=\(fromStr)&to=\(toStr)", on: req)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR transactions request failed with status \(response.status.code).")
        }

        if let transactions = try? response.content.decode([IBKRBrokerTransactionPayload].self) {
            return transactions.compactMap { $0.toTransaction() }
        }

        if let envelope = try? response.content.decode(IBKRBrokerTransactionsEnvelope.self) {
            return envelope.transactions.compactMap { $0.toTransaction() }
        }

        return []
    }

    func fetchCashBalances(accountID: String, on req: Request) async throws -> [IBKRBrokerCashBalance] {
        let response = try await withRetry(on: req) {
            try await get(path: "/portfolio/\(accountID)/ledger", on: req)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR cash balances request failed with status \(response.status.code).")
        }

        if let ledger = try? response.content.decode(IBKRBrokerLedgerPayload.self) {
            return ledger.toCashBalances()
        }

        return []
    }

    func fetchDividends(accountID: String, from: Date, to: Date, on req: Request) async throws -> [IBKRBrokerDividend] {
        try await fetchDividendsAndWithholdings(accountID: accountID, from: from, to: to, on: req).dividends
    }

    /// One statement read serves both: dividend lines become `IBKRBrokerDividend`,
    /// withholding-tax lines become `IBKRWithholdingRow` for the reconciler.
    func fetchDividendsAndWithholdings(
        accountID: String, from: Date, to: Date, on req: Request
    ) async throws -> (dividends: [IBKRBrokerDividend], withholdings: [IBKRWithholdingRow]) {
        let transactions = try await fetchTransactions(accountID: accountID, from: from, to: to, on: req)
        var dividends: [IBKRBrokerDividend] = []
        var withholdings: [IBKRWithholdingRow] = []
        for transaction in transactions {
            if transaction.type == "DIV" || transaction.type == "DIVIDEND" {
                dividends.append(IBKRBrokerDividend(
                    externalID: transaction.externalID,
                    symbol: transaction.symbol,
                    amount: transaction.amount,
                    currency: transaction.currency,
                    date: transaction.date
                ))
            } else if DividendWithholdingReconciler.isWithholdingType(transaction.type) {
                withholdings.append(IBKRWithholdingRow(
                    symbol: transaction.symbol,
                    payDate: transaction.date,
                    amount: transaction.amount,
                    currency: transaction.currency
                ))
            }
        }
        return (dividends, withholdings)
    }

    private func fetchAccounts(on req: Request) async throws -> [IBKRBrokerAccount] {
        let response = try await withRetry(on: req) {
            try await get(path: "/portfolio/accounts", on: req)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR accounts request failed with status \(response.status.code).")
        }

        if let accounts = try? response.content.decode([IBKRBrokerAccountPayload].self) {
            return accounts.compactMap { $0.toAccount() }
        }

        if let envelope = try? response.content.decode(IBKRBrokerAccountsEnvelope.self) {
            return envelope.accounts.compactMap { $0.toAccount() }
        }

        throw Abort(.badGateway, reason: "IBKR accounts response format was not recognized.")
    }

    private func withRetry<T>(on req: Request, maxRetries: Int = 3, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: (any Error)?
        for attempt in 0 ..< maxRetries {
            do {
                if attempt > 0, accessToken == nil {
                    let isAuthenticated = try await checkAuthStatus(on: req)
                    if !isAuthenticated {
                        try await reauthenticate(on: req)
                    }
                }
                return try await operation()
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    let delay = Double(1 << attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError ?? Abort(.badGateway, reason: "IBKR request failed after \(maxRetries) retries.")
    }

    private func get(path: String, on req: Request) async throws -> ClientResponse {
        try await req.client.get(URI(string: makeURL(path: path))) { request in
            addAuthorizationHeader(to: &request.headers)
        }
    }

    private func post(path: String, on req: Request) async throws -> ClientResponse {
        try await req.client.post(URI(string: makeURL(path: path))) { request in
            addAuthorizationHeader(to: &request.headers)
        }
    }

    private func addAuthorizationHeader(to headers: inout HTTPHeaders) {
        guard let accessToken, !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        headers.bearerAuthorization = .init(token: accessToken)
    }

    private func makeURL(path: String) -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base + "/" + normalizedPath
    }
}

struct IBKRBrokerAccount {
    let externalID: String
    let displayName: String?
}

struct IBKRBrokerPosition {
    let symbol: String
    let quantity: Double
    let averageCost: Double
    let currency: String
    let conid: String?
}

struct IBKRBrokerTransaction {
    let externalID: String
    let symbol: String
    let type: String
    let quantity: Double
    let amount: Double
    let price: Double?
    let fees: Double
    let currency: String
    let date: Date
    let settleDate: Date?
    let conid: String?
}

struct IBKRContractInfo: Sendable {
    let listingExchange: String?
}

struct IBKRBrokerCashBalance {
    let currency: String
    let amount: Double
}

struct IBKRBrokerDividend {
    let externalID: String?
    let symbol: String
    let amount: Double
    let currency: String
    let date: Date
}

private struct IBKRAuthStatus: Decodable {
    let authenticated: Bool?
}

struct IBKRBrokerSyncService {
    private let gatewayClient: IBKRBrokerGatewayClient

    init(gatewayClient: IBKRBrokerGatewayClient) {
        self.gatewayClient = gatewayClient
    }

    func sync(connection: BrokerConnection, userId: UUID, on req: Request) async throws -> BrokerSyncResponse {
        let account = try await resolveGatewayAccount(for: connection, on: req)
        let positions = try await gatewayClient.fetchPositions(accountID: account.externalID, on: req)
            .filter { $0.quantity > 0 }

        guard let connectionID = connection.id else {
            throw Abort(.internalServerError, reason: "Broker connection id missing.")
        }

        let portfolioListId: UUID = if let existingPortfolioListId = connection.portfolioListId {
            existingPortfolioListId
        } else {
            try await ensureDefaultPortfolioListId(userId: userId, on: req.db)
        }
        let sourceAccount = try await resolveImportAccount(
            account: account,
            provider: connection.provider,
            userId: userId,
            on: req.db
        )
        let sourceAccountID = try sourceAccount.requireID()
        let existingSymbols = try await existingImportedSymbols(
            provider: connection.provider,
            sourceAccountId: sourceAccountID,
            userId: userId,
            on: req.db
        )

        var inserted = 0
        var updated = 0
        var seenSymbols = Set<String>()

        for position in positions {
            let symbol = position.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !symbol.isEmpty else { continue }
            let didExist = existingSymbols.contains(symbol)
            try await upsertPosition(
                symbol: symbol,
                position: position,
                provider: connection.provider,
                sourceAccountId: sourceAccountID,
                portfolioListId: portfolioListId,
                userId: userId,
                on: req
            )
            seenSymbols.insert(symbol)
            if didExist {
                updated += 1
            } else {
                inserted += 1
            }
        }

        let removed = try await removeStaleImportedSymbols(
            existingSymbols: existingSymbols,
            seenSymbols: seenSymbols,
            provider: connection.provider,
            sourceAccountId: sourceAccountID,
            userId: userId,
            on: req.db
        )

        let initialLookbackDays = Double(Environment.get("IBKR_TRANSACTION_LOOKBACK_DAYS") ?? "3650") ?? 3650
        let overlapDays = Double(Environment.get("IBKR_TRANSACTION_OVERLAP_DAYS") ?? "7") ?? 7
        let lastSyncDate = connection.lastSyncedAt
            .map { $0.addingTimeInterval(-overlapDays * 24 * 3600) }
            ?? Date().addingTimeInterval(-initialLookbackDays * 24 * 3600)
        _ = try await syncTransactions(
            accountID: account.externalID,
            sourceAccountId: sourceAccountID,
            userId: userId,
            positions: positions,
            from: lastSyncDate,
            to: Date(),
            on: req
        )

        _ = try await syncCashBalances(
            accountID: account.externalID,
            sourceAccountId: sourceAccountID,
            on: req
        )

        _ = try await syncDividends(
            accountID: account.externalID,
            sourceAccountId: sourceAccountID,
            from: lastSyncDate,
            to: Date(),
            on: req
        )

        connection.externalId = account.externalID
        connection.displayName = account.displayName ?? connection.displayName
        connection.status = "connected"
        connection.statusDetail = nil
        connection.connectedAt = connection.connectedAt ?? Date()
        connection.lastSyncedAt = Date()
        connection.portfolioListId = portfolioListId
        connection.updatedAt = Date()
        try await connection.save(on: req.db)

        return BrokerSyncResponse(
            runId: connectionID.uuidString,
            status: "completed",
            inserted: inserted,
            updated: updated,
            removed: removed
        )
    }

    private func syncTransactions(
        accountID: String,
        sourceAccountId: UUID,
        userId: UUID,
        positions: [IBKRBrokerPosition],
        from: Date,
        to: Date,
        on req: Request
    ) async throws -> Int {
        let transactions = try await gatewayClient.fetchTransactions(
            accountID: accountID,
            from: from,
            to: to,
            on: req
        )

        var syncedCount = 0
        var canonicalTransactions = [Transaction]()
        for ibkrTransaction in transactions.sorted(by: {
            ($0.date, $0.externalID) < ($1.date, $1.externalID)
        }) {
            let type = mapTransactionType(ibkrTransaction.type)
            let existing = try await Transaction.query(on: req.db)
                .filter(\.$accountId == sourceAccountId)
                .filter(\.$externalId == ibkrTransaction.externalID)
                .first()

            let instrument = try await requireInstrument(
                symbol: ibkrTransaction.symbol,
                conid: ibkrTransaction.conid,
                currency: ibkrTransaction.currency,
                on: req,
                db: req.db
            )
            try await enrichMarketAdmission(
                instrument: instrument,
                conid: ibkrTransaction.conid,
                on: req
            )
            let instrumentID = try instrument.requireID()
            let price = ibkrTransaction.price
                ?? (ibkrTransaction.quantity != 0 ? abs(ibkrTransaction.amount / ibkrTransaction.quantity) : 0)

            let transaction: Transaction
            if let existing {
                let existingID = try existing.requireID()
                let hasLot = try await Lot.query(on: req.db)
                    .filter(\.$openTransactionId == existingID)
                    .first() != nil
                let hasDisposal = try await LotDisposal.query(on: req.db)
                    .filter(\.$transactionId == existingID)
                    .first() != nil
                if !hasLot, !hasDisposal {
                    existing.instrumentId = instrumentID
                    existing.type = type
                    existing.quantity = ibkrTransaction.quantity
                    existing.price = price
                    existing.currency = ibkrTransaction.currency
                    existing.tradeDate = ibkrTransaction.date
                    existing.settleDate = ibkrTransaction.settleDate ?? ibkrTransaction.date
                    existing.fees = ibkrTransaction.fees
                    try await existing.save(on: req.db)
                }
                transaction = existing
            } else {
                transaction = Transaction(
                    accountId: sourceAccountId,
                    instrumentId: instrumentID,
                    externalId: ibkrTransaction.externalID,
                    type: type,
                    quantity: ibkrTransaction.quantity,
                    price: price,
                    currency: ibkrTransaction.currency,
                    tradeDate: ibkrTransaction.date,
                    settleDate: ibkrTransaction.settleDate ?? ibkrTransaction.date,
                    fees: ibkrTransaction.fees
                )
                try await transaction.save(on: req.db)
                req.application.businessMetrics.incrementTransactionsCreated()
                syncedCount += 1
            }
            canonicalTransactions.append(transaction)
        }

        let accounting = TaxLotAccountingService()
        let taxPlanReconciler = TaxPlanReconciler()
        for transaction in canonicalTransactions where transaction.type == "BUY" {
            _ = try await accounting.recordAcquisition(transaction: transaction, on: req.db)
            let match = try await taxPlanReconciler.match(
                transaction: transaction,
                userId: userId,
                on: req.db
            )
            try await taxPlanReconciler.complete(
                match,
                transaction: transaction,
                userId: userId,
                on: req.db
            )
        }
        try await reconcileOpeningLots(
            positions: positions,
            accountID: accountID,
            sourceAccountId: sourceAccountId,
            accounting: accounting,
            on: req
        )

        let account = try await Account.find(sourceAccountId, on: req.db)
        let method = account?.lotSelectionMethod.flatMap(TaxLotSelectionMethod.init(rawValue:))
            ?? .jurisdictionDefault
        let hasCompletedUSProfile = try await TaxProfile.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == TaxJurisdiction.unitedStates.rawValue)
            .filter(\.$isComplete == true)
            .first() != nil
        let hasCompletedSpainProfile = try await TaxProfile.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == TaxJurisdiction.spain.rawValue)
            .filter(\.$isComplete == true)
            .first() != nil
        let hasCompletedPortugalProfile = try await TaxProfile.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == TaxJurisdiction.portugal.rawValue)
            .filter(\.$isComplete == true)
            .first() != nil
        let hasCompletedGermanyProfile = try await TaxProfile.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == TaxJurisdiction.germany.rawValue)
            .filter(\.$isComplete == true)
            .first() != nil
        let disposalMethod: TaxLotSelectionMethod = hasCompletedSpainProfile || hasCompletedPortugalProfile || hasCompletedGermanyProfile
            ? .fifo
            : method
        let usRuleVersion = TaxRuleRegistry(validatedJurisdictions: [.unitedStates])
            .pack(for: .unitedStates).ruleVersion
        let spainRuleVersion = TaxRuleRegistry(validatedJurisdictions: [.spain])
            .pack(for: .spain).ruleVersion

        for transaction in canonicalTransactions where transaction.type == "SELL" {
            do {
                let match = try await taxPlanReconciler.match(
                    transaction: transaction,
                    userId: userId,
                    on: req.db
                )
                let disposals = try await accounting.recordDisposal(
                    transaction: transaction,
                    method: match?.lotIDs.isEmpty == false ? .specificID : disposalMethod,
                    specificLotIDs: match?.lotIDs ?? [],
                    on: req.db
                )
                if hasCompletedUSProfile {
                    _ = try await accounting.recordUSWashSales(
                        disposals: disposals,
                        saleTransaction: transaction,
                        userId: userId,
                        ruleVersion: usRuleVersion,
                        on: req.db
                    )
                } else if hasCompletedSpainProfile {
                    _ = try await accounting.recordSpainLossDeferrals(
                        disposals: disposals,
                        saleTransaction: transaction,
                        userId: userId,
                        ruleVersion: spainRuleVersion,
                        on: req.db
                    )
                }
                try await taxPlanReconciler.complete(
                    match,
                    transaction: transaction,
                    userId: userId,
                    on: req.db
                )
            } catch let TaxLotAccountingError.insufficientQuantity(available, requested) {
                req.logger.warning("broker.ibkr disposal_unmatched", metadata: [
                    "external_id": .string(transaction.externalId ?? "unknown"),
                    "available_quantity": .string("\(available)"),
                    "requested_quantity": .string("\(requested)"),
                ])
            }
        }

        return syncedCount
    }

    private func reconcileOpeningLots(
        positions: [IBKRBrokerPosition],
        accountID: String,
        sourceAccountId: UUID,
        accounting: TaxLotAccountingService,
        on req: Request
    ) async throws {
        let reconciler = IBKROpeningLotReconciler()
        for position in positions where position.quantity > 0 {
            let instrument = try await requireInstrument(
                symbol: position.symbol,
                conid: position.conid,
                currency: position.currency,
                on: req,
                db: req.db
            )
            let instrumentID = try instrument.requireID()
            let trades = try await Transaction.query(on: req.db)
                .filter(\.$accountId == sourceAccountId)
                .filter(\.$instrumentId == instrumentID)
                .all()
            let bought = trades
                .filter { $0.type == "BUY" }
                .compactMap(\.quantity)
                .reduce(0) { $0 + abs($1) }
            let sold = trades
                .filter { $0.type == "SELL" }
                .compactMap(\.quantity)
                .reduce(0) { $0 + abs($1) }
            let requiredOpeningQuantity = reconciler.requiredQuantity(
                position: position.quantity,
                bought: bought,
                sold: sold
            )
            guard requiredOpeningQuantity > 0.000_000_1 else { continue }

            let externalID = "ibkr:opening:\(accountID):\(instrumentID.uuidString)"
            if let existing = trades.first(where: { $0.externalId == externalID }),
               let transactionID = existing.id,
               let lot = try await Lot.query(on: req.db)
               .filter(\.$openTransactionId == transactionID)
               .first()
            {
                let consumed = max(0, lot.openQuantity - lot.remainingQuantity)
                guard let remaining = try? reconciler.remainingQuantity(
                    required: requiredOpeningQuantity,
                    consumed: consumed
                ) else {
                    req.logger.warning("broker.ibkr inferred_basis_rebuild_required", metadata: [
                        "external_id": .string(externalID),
                        "required_quantity": .string("\(requiredOpeningQuantity)"),
                        "consumed_quantity": .string("\(consumed)"),
                    ])
                    continue
                }
                existing.quantity = requiredOpeningQuantity
                lot.openQuantity = requiredOpeningQuantity
                lot.remainingQuantity = remaining
                try await existing.save(on: req.db)
                try await lot.save(on: req.db)
                continue
            }

            let inferredDate = trades.map(\.tradeDate).min()
                .map { $0.addingTimeInterval(-1) } ?? Date()
            let transaction = Transaction(
                accountId: sourceAccountId,
                instrumentId: instrumentID,
                externalId: externalID,
                type: "OPENING_BALANCE",
                quantity: requiredOpeningQuantity,
                price: abs(position.averageCost),
                currency: position.currency,
                tradeDate: inferredDate,
                settleDate: inferredDate,
                fees: 0
            )
            try await transaction.create(on: req.db)
            _ = try await accounting.recordAcquisition(transaction: transaction, on: req.db)
            req.logger.notice("broker.ibkr inferred_opening_lot_created", metadata: [
                "external_id": .string(externalID),
                "quantity": .string("\(requiredOpeningQuantity)"),
                "basis_source": .string("position_snapshot"),
            ])
        }
    }

    private func enrichMarketAdmission(
        instrument: Instrument,
        conid: String?,
        on req: Request
    ) async throws {
        guard instrument.listingExchange == nil,
              let conid, !conid.isEmpty,
              let info = try await gatewayClient.fetchContractInfo(conid: conid, on: req),
              let listingExchange = info.listingExchange?.trimmingCharacters(in: .whitespacesAndNewlines),
              !listingExchange.isEmpty
        else { return }
        instrument.listingExchange = listingExchange.uppercased()
        instrument.regulatedMarketStatus = instrument.regulatedMarketStatus ?? "unknown"
        try await instrument.save(on: req.db)
    }

    private func syncCashBalances(
        accountID: String,
        sourceAccountId: UUID,
        on req: Request
    ) async throws -> Int {
        let balances = try await gatewayClient.fetchCashBalances(accountID: accountID, on: req)

        try await CashBalance.query(on: req.db)
            .filter(\.$accountId == sourceAccountId)
            .delete()

        var syncedCount = 0
        for ibkrBalance in balances {
            let balance = CashBalance(
                accountId: sourceAccountId,
                currency: ibkrBalance.currency,
                balance: ibkrBalance.amount,
                asOf: Date()
            )
            try await balance.save(on: req.db)
            syncedCount += 1
        }
        return syncedCount
    }

    private func syncDividends(
        accountID: String,
        sourceAccountId: UUID,
        from: Date,
        to: Date,
        on req: Request
    ) async throws -> Int {
        let statement = try await gatewayClient.fetchDividendsAndWithholdings(accountID: accountID, from: from, to: to, on: req)
        let dividends = statement.dividends
        let reconciler = DividendWithholdingReconciler()

        var syncedCount = 0
        for ibkrDividend in dividends {
            if let externalID = ibkrDividend.externalID {
                let existing = try await Dividend.query(on: req.db)
                    .filter(\.$accountId == sourceAccountId)
                    .filter(\.$externalId == externalID)
                    .first()
                if let existing {
                    // Rows imported before withholding existed get it on the next sync.
                    if existing.withholdingTax == nil {
                        let updated = reconciler.apply(withholdings: statement.withholdings, to: [(symbol: ibkrDividend.symbol, dividend: existing)])[0]
                        if updated.withholdingTax != nil {
                            try await updated.save(on: req.db)
                        }
                    }
                    continue
                }
            }

            let instrument = try await requireInstrument(
                symbol: ibkrDividend.symbol,
                conid: nil,
                currency: ibkrDividend.currency,
                on: req,
                db: req.db
            )
            let instrumentID = try instrument.requireID()

            let dividend = Dividend(
                accountId: sourceAccountId,
                instrumentId: instrumentID,
                externalId: ibkrDividend.externalID,
                amount: ibkrDividend.amount,
                currency: ibkrDividend.currency,
                payDate: ibkrDividend.date
            )
            let reconciled = reconciler.apply(withholdings: statement.withholdings, to: [(symbol: ibkrDividend.symbol, dividend: dividend)])[0]
            try await reconciled.save(on: req.db)
            syncedCount += 1
        }
        return syncedCount
    }

    private func mapTransactionType(_ ibkrType: String) -> String {
        switch ibkrType.uppercased() {
        case "BUY", "BOT": "BUY"
        case "SELL", "SLD": "SELL"
        case "DIV", "DIVIDEND": "DIVIDEND"
        case "INTEREST": "INTEREST"
        case "FEE": "FEE"
        case "DEPOSIT": "DEPOSIT"
        case "WITHDRAWAL": "WITHDRAWAL"
        default: ibkrType.uppercased()
        }
    }
}

private extension IBKRBrokerSyncService {
    func resolveGatewayAccount(for connection: BrokerConnection, on req: Request) async throws -> IBKRBrokerAccount {
        let gatewayAccount = try await gatewayClient.requirePrimaryAccount(on: req)
        if let externalID = connection.externalId,
           !externalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           gatewayAccount.externalID != externalID
        {
            req.logger.warning("broker.ibkr account_mismatch stored=\(externalID) live=\(gatewayAccount.externalID)")
        }
        return gatewayAccount
    }

    func resolveImportAccount(
        account: IBKRBrokerAccount,
        provider: String,
        userId: UUID,
        on db: any Database
    ) async throws -> Account {
        if let existing = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$broker == provider)
            .filter(\.$externalId == account.externalID)
            .first()
        {
            existing.displayName = account.displayName ?? existing.displayName
            existing.updatedAt = Date()
            try await existing.save(on: db)
            return existing
        }

        let defaultPortfolioId = try await ensureDefaultPortfolioListId(userId: userId, on: db)
        let created = Account(
            userId: userId,
            externalId: account.externalID,
            broker: provider,
            displayName: account.displayName,
            baseCurrency: gatewayClient.defaultCurrency,
            portfolioId: defaultPortfolioId
        )
        try await created.save(on: db)
        return created
    }

    func existingImportedSymbols(
        provider: String,
        sourceAccountId: UUID,
        userId: UUID,
        on db: any Database
    ) async throws -> Set<String> {
        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$sourceProvider == provider)
            .filter(\.$sourceAccountId == sourceAccountId)
            .all()
        return Set(stocks.map(\.symbol))
    }

    func upsertPosition(
        symbol: String,
        position: IBKRBrokerPosition,
        provider: String,
        sourceAccountId: UUID,
        portfolioListId: UUID,
        userId: UUID,
        on req: Request
    ) async throws {
        try await req.db.transaction { db in
            let instrument = try await requireInstrument(symbol: symbol, conid: position.conid, currency: position.currency, on: req, db: db)

            let existingStocks = try await Stock.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$sourceProvider == provider)
                .filter(\.$sourceAccountId == sourceAccountId)
                .filter(\.$symbol == symbol)
                .all()
            for stock in existingStocks {
                try await stock.delete(on: db)
            }

            let instrumentID = try instrument.requireID()
            let existingLots = try await Lot.query(on: db)
                .filter(\.$accountId == sourceAccountId)
                .filter(\.$instrumentId == instrumentID)
                .all()
            for lot in existingLots {
                try await lot.delete(on: db)
            }

            if let existingPosition = try await Position.query(on: db)
                .filter(\.$accountId == sourceAccountId)
                .filter(\.$instrumentId == instrumentID)
                .first()
            {
                try await existingPosition.delete(on: db)
            }

            let quantity = max(position.quantity, 0)
            let averageCost = max(position.averageCost, 0)
            let now = Date()

            let lot = Lot(
                accountId: sourceAccountId,
                instrumentId: instrumentID,
                openDate: now,
                openQuantity: quantity,
                remainingQuantity: quantity,
                openPrice: averageCost,
                currency: position.currency,
                status: "open"
            )
            try await lot.save(on: db)

            let dbPosition = Position(
                accountId: sourceAccountId,
                instrumentId: instrumentID,
                quantity: quantity,
                averageCost: averageCost,
                currency: position.currency
            )
            try await dbPosition.save(on: db)

            let stock = Stock(
                userId: userId,
                portfolioListId: portfolioListId,
                symbol: symbol,
                shares: quantity,
                buyPrice: averageCost,
                buyDate: now,
                notes: nil,
                category: .stock,
                sourceProvider: provider,
                sourceAccountId: sourceAccountId
            )
            try await stock.save(on: db)
        }
    }

    func requireInstrument(
        symbol: String,
        conid: String?,
        currency: String,
        on req: Request,
        db: any Database
    ) async throws -> Instrument {
        if let existing = try await Instrument.query(on: db)
            .filter(\.$symbol == symbol)
            .first()
        {
            return existing
        }

        let candidates = try await req.application.marketDataService.search(query: symbol, on: req)
        if let matched = candidates.first(where: { $0.symbol == symbol }) ?? candidates.first {
            let instrument = Instrument(
                conid: matched.conid,
                symbol: matched.symbol,
                exchange: matched.exchange,
                currency: matched.currency,
                name: matched.name
            )
            try await instrument.save(on: db)
            return instrument
        }

        let instrument = Instrument(
            conid: conid ?? symbol,
            symbol: symbol,
            exchange: "UNKNOWN",
            currency: currency,
            name: symbol
        )
        try await instrument.save(on: db)
        return instrument
    }

    func removeStaleImportedSymbols(
        existingSymbols: Set<String>,
        seenSymbols: Set<String>,
        provider: String,
        sourceAccountId: UUID,
        userId: UUID,
        on db: any Database
    ) async throws -> Int {
        let staleSymbols = existingSymbols.subtracting(seenSymbols)
        guard !staleSymbols.isEmpty else { return 0 }

        for symbol in staleSymbols {
            let stocks = try await Stock.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$sourceProvider == provider)
                .filter(\.$sourceAccountId == sourceAccountId)
                .filter(\.$symbol == symbol)
                .all()
            for stock in stocks {
                try await stock.delete(on: db)
            }

            if let instrument = try await Instrument.query(on: db)
                .filter(\.$symbol == symbol)
                .first(),
                let instrumentID = instrument.id
            {
                let lots = try await Lot.query(on: db)
                    .filter(\.$accountId == sourceAccountId)
                    .filter(\.$instrumentId == instrumentID)
                    .all()
                for lot in lots {
                    try await lot.delete(on: db)
                }

                if let position = try await Position.query(on: db)
                    .filter(\.$accountId == sourceAccountId)
                    .filter(\.$instrumentId == instrumentID)
                    .first()
                {
                    try await position.delete(on: db)
                }
            }
        }

        return staleSymbols.count
    }

    func ensureDefaultPortfolioListId(userId: UUID, on db: any Database) async throws -> UUID {
        if let list = try await PortfolioList.query(on: db)
            .filter(\.$userId == userId)
            .first()
        {
            return try list.requireID()
        }
        let list = PortfolioList(userId: userId, name: "Default")
        try await list.save(on: db)
        return try list.requireID()
    }
}

private struct IBKRBrokerAccountsEnvelope: Decodable {
    let accounts: [IBKRBrokerAccountPayload]
}

private struct IBKRBrokerAccountPayload: Decodable {
    let id: BrokerLossyValue?
    let accountId: BrokerLossyValue?
    let accountID: BrokerLossyValue?
    let accountTitle: String?
    let displayName: String?
    let alias: String?

    func toAccount() -> IBKRBrokerAccount? {
        let externalID =
            id?.stringValue
                ?? accountId?.stringValue
                ?? accountID?.stringValue
        guard let externalID, !externalID.isEmpty else { return nil }

        let displayName = [displayName, accountTitle, alias]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return IBKRBrokerAccount(externalID: externalID, displayName: displayName)
    }
}

private struct IBKRBrokerPositionsEnvelope: Decodable {
    let positions: [IBKRBrokerPositionPayload]

    enum CodingKeys: String, CodingKey {
        case positions = "data"
    }
}

private struct IBKRBrokerPositionPayload: Decodable {
    let ticker: String?
    let symbol: String?
    let contractDesc: String?
    let position: BrokerLossyValue?
    let qty: BrokerLossyValue?
    let avgPrice: BrokerLossyValue?
    let averagePrice: BrokerLossyValue?
    let avgCost: BrokerLossyValue?
    let currency: String?
    let conid: BrokerLossyValue?

    func toPosition(defaultCurrency: String) -> IBKRBrokerPosition? {
        let resolvedSymbol = [ticker, symbol, contractDesc]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .first(where: { !$0.isEmpty })
        guard let resolvedSymbol else { return nil }

        let quantity = position?.doubleValue ?? qty?.doubleValue ?? 0
        let averageCost = avgPrice?.doubleValue ?? averagePrice?.doubleValue ?? avgCost?.doubleValue ?? 0
        let resolvedCurrency = currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return IBKRBrokerPosition(
            symbol: resolvedSymbol,
            quantity: quantity,
            averageCost: averageCost,
            currency: (resolvedCurrency?.isEmpty == false ? resolvedCurrency! : defaultCurrency),
            conid: conid?.stringValue
        )
    }
}

private struct BrokerLossyValue: Decodable {
    let stringValue: String

    var doubleValue: Double? {
        Double(stringValue.replacingOccurrences(of: ",", with: ""))
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if let int = try? container.decode(Int.self) {
            stringValue = String(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            stringValue = String(double)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            stringValue = bool ? "true" : "false"
            return
        }
        throw DecodingError.typeMismatch(
            String.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported lossy value.")
        )
    }
}

private struct IBKRBrokerTransactionsEnvelope: Decodable {
    let transactions: [IBKRBrokerTransactionPayload]
}

private struct IBKRBrokerTransactionPayload: Decodable {
    let transactionID: BrokerLossyValue?
    let id: BrokerLossyValue?
    let symbol: String?
    let type: String?
    let quantity: BrokerLossyValue?
    let amount: BrokerLossyValue?
    let price: BrokerLossyValue?
    let tradePrice: BrokerLossyValue?
    let commission: BrokerLossyValue?
    let fee: BrokerLossyValue?
    let currency: String?
    let date: String?
    let tradeDate: String?
    let settleDate: String?
    let conid: BrokerLossyValue?

    func toTransaction() -> IBKRBrokerTransaction? {
        let externalID = transactionID?.stringValue ?? id?.stringValue
        guard let externalID, !externalID.isEmpty else { return nil }
        guard let symbol, !symbol.isEmpty else { return nil }
        guard let type, !type.isEmpty else { return nil }

        guard let parsedDate = Self.parseDate(date ?? tradeDate) else { return nil }

        return IBKRBrokerTransaction(
            externalID: externalID,
            symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            type: type.uppercased(),
            quantity: quantity?.doubleValue ?? 0,
            amount: amount?.doubleValue ?? 0,
            price: tradePrice?.doubleValue ?? price?.doubleValue,
            fees: abs(commission?.doubleValue ?? fee?.doubleValue ?? 0),
            currency: currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "USD",
            date: parsedDate,
            settleDate: Self.parseDate(settleDate),
            conid: conid?.stringValue
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }
        for format in ["yyyy-MM-dd", "yyyyMMdd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

private struct IBKRContractInfoPayload: Decodable {
    let listingExchange: String?

    func toContractInfo() -> IBKRContractInfo {
        .init(listingExchange: listingExchange)
    }
}

private struct IBKRBrokerLedgerPayload: Decodable {
    let BASE: [String: BrokerLossyValue]?
    let USD: [String: BrokerLossyValue]?
    let EUR: [String: BrokerLossyValue]?
    let GBP: [String: BrokerLossyValue]?
    let JPY: [String: BrokerLossyValue]?
    let CHF: [String: BrokerLossyValue]?
    let CAD: [String: BrokerLossyValue]?
    let AUD: [String: BrokerLossyValue]?

    func toCashBalances() -> [IBKRBrokerCashBalance] {
        var balances: [IBKRBrokerCashBalance] = []
        let currencies = [
            ("USD", USD),
            ("EUR", EUR),
            ("GBP", GBP),
            ("JPY", JPY),
            ("CHF", CHF),
            ("CAD", CAD),
            ("AUD", AUD),
        ]

        for (currency, ledger) in currencies {
            guard let ledger else { continue }
            if let cashBalance = ledger["cashbalance"]?.doubleValue ?? ledger["totalcashvalue"]?.doubleValue {
                balances.append(IBKRBrokerCashBalance(currency: currency, amount: cashBalance))
            }
        }

        if let base = BASE, let cashBalance = base["cashbalance"]?.doubleValue ?? base["totalcashvalue"]?.doubleValue {
            balances.append(IBKRBrokerCashBalance(currency: "BASE", amount: cashBalance))
        }

        return balances
    }
}
