import Fluent
import Foundation
import StockPlanShared
import Vapor

struct CsvPortfolioImportService {
    func preview(
        csv: String,
        provider: String,
        portfolioListId rawPortfolioListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> CsvImportPreviewResponse {
        let base = try CsvImportService().preview(csv: csv, provider: provider)
        let existingBySymbol = try await existingStockKinds(userId: userId, on: req.db)
        let sourceAccountId = try await resolveImportAccount(
            provider: provider,
            portfolioListId: rawPortfolioListId,
            userId: userId,
            createIfMissing: false,
            on: req.db
        )?.id

        var items: [CsvImportPreviewItem] = []
        var errors = base.errors
        items.reserveCapacity(base.items.count)

        for item in base.items {
            let validationError = try await validatePreviewItem(item, on: req)
            if let validationError {
                errors.append(.init(line: item.line, message: validationError))
            }

            let existing = existingBySymbol[item.symbol] ?? CsvImportExistingPositionKind.none
            let hasExistingImportedSymbolForSource: Bool = if sourceAccountId != nil, existing.hasImportedPosition {
                try await hasExistingImportedSymbol(
                    symbol: item.symbol,
                    provider: provider,
                    sourceAccountId: sourceAccountId,
                    userId: userId,
                    on: req.db
                )
            } else {
                false
            }

            items.append(
                CsvImportPreviewItem(
                    line: item.line,
                    symbol: item.symbol,
                    shares: item.shares,
                    buyPrice: item.buyPrice,
                    buyDate: item.buyDate,
                    notes: item.notes,
                    existingPositionKind: existing,
                    willReplaceExistingImport: hasExistingImportedSymbolForSource
                )
            )
        }

        return .init(provider: provider, items: items, errors: dedupeErrors(errors))
    }

    func commit(
        csv: String,
        provider: String,
        portfolioListId rawPortfolioListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> CsvImportCommitResponse {
        let preview = try await preview(
            csv: csv,
            provider: provider,
            portfolioListId: rawPortfolioListId,
            userId: userId,
            on: req
        )
        let invalidLines = Set(preview.errors.map(\.line))
        let validItems = preview.items.filter { !invalidLines.contains($0.line) }
        let groupedItems = Dictionary(grouping: validItems, by: \.symbol)
        let targetListId = try await requirePortfolioListId(
            requestedId: rawPortfolioListId,
            userId: userId,
            on: req.db
        )

        var errors = preview.errors
        var resolvedImports: [(symbol: String, rows: [CsvImportPreviewItem], instrument: Instrument)] = []
        resolvedImports.reserveCapacity(groupedItems.count)

        for (symbol, rows) in groupedItems.sorted(by: { $0.key < $1.key }) {
            do {
                let instrument = try await resolveImportInstrument(symbol: symbol, on: req, db: req.db)
                resolvedImports.append((symbol: symbol, rows: rows, instrument: instrument))
            } catch {
                let message: String = if let abortError = error as? any AbortError {
                    abortError.reason
                } else {
                    "Failed to import row."
                }
                let line = rows.map(\.line).min() ?? 0
                errors.append(.init(line: line, message: message))
            }
        }

        let broker = try await req.application.brokersService.recordCsvImport(
            provider: provider,
            userId: userId,
            on: req.db
        )

        if !resolvedImports.isEmpty {
            try await req.usageCounterService.incrementUsage(.csvImports, userId: userId, by: 1, on: req.db)
        }

        var inserted: [StockResponse] = []
        var updated: [StockResponse] = []
        var replacedSymbols = Set<String>()
        var importedLotsCount = 0

        for importItem in resolvedImports {
            do {
                let result = try await req.db.transaction { tx in
                    try await importSymbolRows(
                        importItem.rows,
                        symbol: importItem.symbol,
                        instrument: importItem.instrument,
                        provider: provider,
                        portfolioListId: targetListId,
                        userId: userId,
                        db: tx
                    )
                }

                importedLotsCount += result.lotsInserted
                if result.replacedExisting {
                    replacedSymbols.insert(importItem.symbol)
                    updated.append(result.stock)
                } else {
                    inserted.append(result.stock)
                }
            } catch {
                let message: String = if let abortError = error as? any AbortError {
                    abortError.reason
                } else {
                    "Failed to import row."
                }
                let line = importItem.rows.map(\.line).min() ?? 0
                errors.append(.init(line: line, message: message))
            }
        }

        return .init(
            provider: broker.provider,
            inserted: inserted,
            updated: updated,
            errors: dedupeErrors(errors),
            replacedSymbols: replacedSymbols.sorted(),
            importedLotsCount: importedLotsCount
        )
    }
}

private extension CsvPortfolioImportService {
    struct ImportResult {
        let stock: StockResponse
        let replacedExisting: Bool
        let lotsInserted: Int
    }

    struct NormalizedImportRow {
        let shares: Double
        let buyPrice: Double
        let buyDate: Date
        let notes: String?
    }

    func validatePreviewItem(_ item: CsvImportPreviewItem, on _: Request) async throws -> String? {
        if let shares = item.shares, shares < 0 {
            return "Invalid shares (quantity)."
        }
        if let buyPrice = item.buyPrice, buyPrice < 0 {
            return "Invalid buyPrice (average_cost)."
        }
        if let rawBuyDate = item.buyDate,
           !rawBuyDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           CsvImportService.normalizeDateOnlyString(rawBuyDate) == nil
        {
            return "Invalid buyDate. Expected YYYY-MM-DD."
        }
        return nil
    }

    func importSymbolRows(
        _ rows: [CsvImportPreviewItem],
        symbol: String,
        instrument: Instrument,
        provider: String,
        portfolioListId: UUID,
        userId: UUID,
        db: any Database
    ) async throws -> ImportResult {
        let sourceAccount = try await requireImportAccount(
            provider: provider,
            portfolioListId: portfolioListId.uuidString,
            userId: userId,
            on: db
        )

        let existingImportedStocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$sourceProvider == provider)
            .filter(\.$sourceAccountId == sourceAccount.requireID())
            .filter(\.$symbol == symbol)
            .all()

        for stock in existingImportedStocks {
            try await stock.delete(on: db)
        }

        let existingLots = try await Lot.query(on: db)
            .filter(\.$accountId == sourceAccount.requireID())
            .filter(\.$instrumentId == instrument.requireID())
            .all()
        for lot in existingLots {
            try await lot.delete(on: db)
        }

        if let existingPosition = try await Position.query(on: db)
            .filter(\.$accountId == sourceAccount.requireID())
            .filter(\.$instrumentId == instrument.requireID())
            .first()
        {
            try await existingPosition.delete(on: db)
        }

        let normalizedRows = try rows.map(normalizeRequiredRow)
        let sourceAccountId = try sourceAccount.requireID()
        let instrumentId = try instrument.requireID()
        let totalShares = normalizedRows.reduce(0.0) { $0 + $1.shares }
        let totalCostBasis = normalizedRows.reduce(0.0) { $0 + ($1.shares * $1.buyPrice) }
        let averageCost = totalShares > 0 ? totalCostBasis / totalShares : 0
        let earliestBuyDate = normalizedRows.map(\.buyDate).min() ?? Date()
        let notes = normalizedRows.compactMap(\.notes).first

        for row in normalizedRows {
            let lot = Lot(
                accountId: sourceAccountId,
                instrumentId: instrumentId,
                openDate: row.buyDate,
                openQuantity: row.shares,
                remainingQuantity: row.shares,
                openPrice: row.buyPrice,
                currency: instrument.currency,
                status: "open"
            )
            try await lot.save(on: db)
        }

        let position = Position(
            accountId: sourceAccountId,
            instrumentId: instrumentId,
            quantity: totalShares,
            averageCost: averageCost,
            currency: instrument.currency
        )
        try await position.save(on: db)

        let stock = Stock(
            userId: userId,
            portfolioListId: portfolioListId,
            symbol: symbol,
            shares: totalShares,
            buyPrice: averageCost,
            buyDate: earliestBuyDate,
            notes: notes,
            category: .stock,
            sourceProvider: provider,
            sourceAccountId: sourceAccountId
        )
        try await stock.save(on: db)

        return try .init(
            stock: StockResponse(from: stock),
            replacedExisting: !existingImportedStocks.isEmpty || !existingLots.isEmpty,
            lotsInserted: normalizedRows.count
        )
    }

    func normalizeRequiredRow(_ row: CsvImportPreviewItem) throws -> NormalizedImportRow {
        let shares = row.shares ?? 0
        let buyPrice = row.buyPrice ?? 0

        if let rawBuyDate = row.buyDate,
           !rawBuyDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let normalized = CsvImportService.normalizeDateOnlyString(rawBuyDate)
        {
            let formatter = Self.isoDateOnlyFormatter()
            guard let buyDate = formatter.date(from: normalized) else {
                throw Abort(.badRequest, reason: "Invalid buyDate. Expected YYYY-MM-DD.")
            }
            return .init(shares: shares, buyPrice: buyPrice, buyDate: buyDate, notes: row.notes)
        }

        return .init(
            shares: shares,
            buyPrice: buyPrice,
            buyDate: Self.defaultImportBuyDate(),
            notes: row.notes
        )
    }

    static func defaultImportBuyDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        return calendar.date(from: components) ?? Date()
    }

    static func isoDateOnlyFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    func existingStockKinds(userId: UUID, on db: any Database) async throws -> [String: CsvImportExistingPositionKind] {
        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .all()

        var grouped: [String: (hasManual: Bool, hasImported: Bool)] = [:]
        for stock in stocks {
            var entry = grouped[stock.symbol] ?? (false, false)
            if stock.sourceProvider == nil {
                entry.hasManual = true
            } else {
                entry.hasImported = true
            }
            grouped[stock.symbol] = entry
        }

        return grouped.mapValues { value in
            switch (value.hasManual, value.hasImported) {
            case (false, false): CsvImportExistingPositionKind.none
            case (true, false): CsvImportExistingPositionKind.manual
            case (false, true): CsvImportExistingPositionKind.imported
            case (true, true): CsvImportExistingPositionKind.mixed
            }
        }
    }

    func hasExistingImportedSymbol(
        symbol: String,
        provider: String,
        sourceAccountId: UUID?,
        userId: UUID,
        on db: any Database
    ) async throws -> Bool {
        let query = Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$symbol == symbol)
            .filter(\.$sourceProvider == provider)

        if let sourceAccountId {
            query.filter(\.$sourceAccountId == sourceAccountId)
        }

        return try await query.first() != nil
    }

    func requirePortfolioListId(
        requestedId: String?,
        userId: UUID,
        on db: any Database
    ) async throws -> UUID {
        guard let id = try await resolvePortfolioListId(
            requestedId: requestedId,
            userId: userId,
            on: db,
            defaultWhenMissing: true
        ) else {
            throw Abort(.internalServerError, reason: "Failed to resolve portfolio list.")
        }
        return id
    }

    func resolveImportAccount(
        provider: String,
        portfolioListId: String?,
        userId: UUID,
        createIfMissing: Bool,
        on db: any Database
    ) async throws -> Account? {
        let externalId = importAccountExternalId(provider: provider, portfolioListId: portfolioListId)
        if let existing = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$broker == provider)
            .filter(\.$externalId == externalId)
            .first()
        {
            return existing
        }

        guard createIfMissing else { return nil }
        let resolvedPortfolioId = try await requirePortfolioListId(
            requestedId: portfolioListId,
            userId: userId,
            on: db
        )

        let account = Account(
            userId: userId,
            externalId: externalId,
            broker: provider,
            displayName: "\(provider.uppercased()) CSV Import",
            baseCurrency: "USD",
            portfolioId: resolvedPortfolioId
        )
        try await account.save(on: db)
        return account
    }

    func requireImportAccount(
        provider: String,
        portfolioListId: String?,
        userId: UUID,
        on db: any Database
    ) async throws -> Account {
        guard let account = try await resolveImportAccount(
            provider: provider,
            portfolioListId: portfolioListId,
            userId: userId,
            createIfMissing: true,
            on: db
        ) else {
            throw Abort(.internalServerError, reason: "Failed to create import account.")
        }
        return account
    }

    func resolveImportInstrument(symbol: String, on req: Request, db: any Database) async throws -> Instrument {
        if let existing = try await Instrument.query(on: db)
            .filter(\.$symbol == symbol)
            .first()
        {
            return existing
        }

        if let candidate = try await resolveInstrumentCandidate(symbol: symbol, on: req, db: db) {
            let instrument = Instrument(
                conid: candidate.conid,
                symbol: candidate.symbol,
                exchange: candidate.exchange,
                currency: candidate.currency,
                name: candidate.name
            )
            try await instrument.save(on: db)
            return instrument
        }

        guard Self.isImportableTickerSymbol(symbol) else {
            throw Abort(.badRequest, reason: "Unknown symbol \(symbol).")
        }

        let instrument = Instrument(
            conid: "csv-\(symbol.lowercased())",
            symbol: symbol.uppercased(),
            exchange: "UNKNOWN",
            currency: "USD",
            name: symbol.uppercased()
        )
        try await instrument.save(on: db)
        return instrument
    }

    static func isImportableTickerSymbol(_ raw: String) -> Bool {
        let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty, symbol.count <= 12 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return symbol.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func resolveInstrumentCandidate(symbol: String, on req: Request, db: any Database) async throws -> SearchResultResponse? {
        if let local = try await Instrument.query(on: db)
            .filter(\.$symbol == symbol)
            .first()
        {
            return .init(
                symbol: local.symbol,
                name: local.name ?? local.symbol,
                exchange: local.exchange,
                currency: local.currency,
                conid: local.conid
            )
        }

        do {
            let results = try await req.application.marketDataService.search(query: symbol, on: req)
            return results.first { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }
        } catch {
            return nil
        }
    }

    func importAccountExternalId(provider: String, portfolioListId: String?) -> String {
        let scope = portfolioListId?.lowercased() ?? "default"
        return "csv-import-\(provider)-\(scope)"
    }

    func dedupeErrors(_ errors: [CsvImportPreviewError]) -> [CsvImportPreviewError] {
        var seen = Set<String>()
        var output: [CsvImportPreviewError] = []
        for error in errors.sorted(by: { lhs, rhs in
            if lhs.line == rhs.line {
                return lhs.message < rhs.message
            }
            return lhs.line < rhs.line
        }) {
            let key = "\(error.line)::\(error.message)"
            guard seen.insert(key).inserted else { continue }
            output.append(error)
        }
        return output
    }
}

private extension CsvImportExistingPositionKind {
    var hasImportedPosition: Bool {
        switch self {
        case .imported, .mixed:
            true
        case .none, .manual:
            false
        }
    }
}

/// Manual record-keeping reuses the importer's account, portfolio and instrument
/// resolution so a hand-entered trade lands on the same `Account` and `Instrument`
/// rows as an imported one. Without this the two paths would create parallel
/// records for the same holding.
///
/// The implementations live in a `private extension`, so this narrow façade is
/// what other files see rather than widening that whole extension.
extension CsvPortfolioImportService {
    func manualEntryPortfolioListId(
        requestedId: String?,
        userId: UUID,
        on db: any Database
    ) async throws -> UUID {
        try await requirePortfolioListId(requestedId: requestedId, userId: userId, on: db)
    }

    func manualEntryInstrument(symbol: String, on req: Request, db: any Database) async throws -> Instrument {
        try await resolveImportInstrument(symbol: symbol, on: req, db: db)
    }
}
