import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Manual trade record-keeping.
///
/// `Transaction` rows were previously written only by the IBKR and activity-statement
/// importers, so a trade entered by hand never reached tax reports or realized P&L.
/// This service is the hand-entry counterpart. Manual rows are marked by a
/// `manual:` prefix on `external_id`, which does three things at once:
///
/// 1. keeps them out of the importers' `(account_id, external_id)` namespace, so a
///    later broker sync can never collide with or overwrite a hand-entered row;
/// 2. makes "is this row mine to edit?" a property of the row rather than a
///    separate column, so importer-owned rows stay read-only over HTTP;
/// 3. gives the unique index something stable to deduplicate on.
enum TransactionType: String, CaseIterable, Codable, Sendable {
    case buy
    case sell
}

struct CreateTransactionRequest: Content {
    let symbol: String
    let type: String
    let quantity: Double
    let price: Double
    let currency: String?
    let tradeDate: String
    let settleDate: String?
    let fees: Double?
    let portfolioListId: String?
}

struct UpdateTransactionRequest: Content {
    let quantity: Double?
    let price: Double?
    let currency: String?
    let tradeDate: String?
    let settleDate: String?
    let fees: Double?
}

struct TransactionService {
    static let manualExternalIDPrefix = "manual:"

    let req: Request

    // MARK: - Read

    func list(userId: UUID, on db: any Database) async throws -> [TransactionResponse] {
        let accountIds = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .all()
            .compactMap(\.id)
        guard !accountIds.isEmpty else { return [] }

        let rows = try await Transaction.query(on: db)
            .filter(\.$accountId ~~ accountIds)
            .sort(\.$tradeDate, .descending)
            .all()

        let instrumentIds = Set(rows.map(\.instrumentId))
        let instruments = instrumentIds.isEmpty ? [] : try await Instrument.query(on: db)
            .filter(\.$id ~~ Array(instrumentIds))
            .all()
        let symbolById = Dictionary(uniqueKeysWithValues: instruments.compactMap { instrument in
            instrument.id.map { ($0, instrument.symbol) }
        })

        return rows.compactMap { row in
            guard let id = row.id else { return nil }
            return TransactionResponse(
                id: id.uuidString,
                accountId: row.accountId.uuidString,
                instrumentId: symbolById[row.instrumentId] ?? row.instrumentId.uuidString,
                type: row.type,
                quantity: row.quantity,
                price: row.price,
                currency: row.currency,
                tradeDate: Self.dateFormatter.string(from: row.tradeDate),
                settleDate: row.settleDate.map { Self.dateFormatter.string(from: $0) },
                fees: row.fees
            )
        }
    }

    // MARK: - Write

    func create(payload: CreateTransactionRequest, userId: UUID, on db: any Database) async throws -> TransactionResponse {
        let type = try Self.parseType(payload.type)
        let symbol = payload.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else {
            throw Abort(.badRequest, reason: "symbol is required.")
        }
        guard payload.quantity > 0 else {
            throw Abort(.badRequest, reason: "quantity must be greater than 0.")
        }
        guard payload.price > 0 else {
            throw Abort(.badRequest, reason: "price must be greater than 0.")
        }
        if let fees = payload.fees, fees < 0 {
            throw Abort(.badRequest, reason: "fees cannot be negative.")
        }
        let tradeDate = try Self.parseDateOnly(payload.tradeDate, field: "tradeDate")
        let settleDate = try payload.settleDate.map { try Self.parseDateOnly($0, field: "settleDate") }
        if let settleDate, settleDate < tradeDate {
            throw Abort(.badRequest, reason: "settleDate cannot be before tradeDate.")
        }

        let importService = CsvPortfolioImportService()
        let portfolioListId = try await importService.manualEntryPortfolioListId(
            requestedId: payload.portfolioListId,
            userId: userId,
            on: db
        )
        let account = try await ManualAccountResolver.findOrCreate(
            userId: userId,
            portfolioId: portfolioListId,
            on: db
        )
        let instrument = try await importService.manualEntryInstrument(symbol: symbol, on: req, db: db)

        guard let accountId = account.id, let instrumentId = instrument.id else {
            throw Abort(.internalServerError, reason: "Failed to resolve account or instrument.")
        }

        let model = Transaction(
            accountId: accountId,
            instrumentId: instrumentId,
            externalId: Self.manualExternalIDPrefix + UUID().uuidString.lowercased(),
            type: type.rawValue,
            quantity: payload.quantity,
            price: payload.price,
            currency: (payload.currency ?? instrument.currency).uppercased(),
            tradeDate: tradeDate,
            settleDate: settleDate,
            fees: payload.fees
        )
        try await model.save(on: db)
        return try Self.response(for: model, symbol: instrument.symbol)
    }

    func update(id: UUID, payload: UpdateTransactionRequest, userId: UUID, on db: any Database) async throws -> TransactionResponse {
        let model = try await requireManualTransaction(id: id, userId: userId, on: db)

        if let quantity = payload.quantity {
            guard quantity > 0 else {
                throw Abort(.badRequest, reason: "quantity must be greater than 0.")
            }
            model.quantity = quantity
        }
        if let price = payload.price {
            guard price > 0 else {
                throw Abort(.badRequest, reason: "price must be greater than 0.")
            }
            model.price = price
        }
        if let fees = payload.fees {
            guard fees >= 0 else {
                throw Abort(.badRequest, reason: "fees cannot be negative.")
            }
            model.fees = fees
        }
        if let currency = payload.currency {
            model.currency = currency.uppercased()
        }
        if let raw = payload.tradeDate {
            model.tradeDate = try Self.parseDateOnly(raw, field: "tradeDate")
        }
        if let raw = payload.settleDate {
            model.settleDate = try Self.parseDateOnly(raw, field: "settleDate")
        }
        if let settleDate = model.settleDate, settleDate < model.tradeDate {
            throw Abort(.badRequest, reason: "settleDate cannot be before tradeDate.")
        }

        try await model.save(on: db)
        let symbol = try await Instrument.find(model.instrumentId, on: db)?.symbol
        return try Self.response(for: model, symbol: symbol ?? model.instrumentId.uuidString)
    }

    func delete(id: UUID, userId: UUID, on db: any Database) async throws {
        let model = try await requireManualTransaction(id: id, userId: userId, on: db)
        try await model.delete(on: db)
    }

    // MARK: - Helpers

    /// Only hand-entered rows are editable over HTTP. An importer-owned row is
    /// reconstructed on the next sync, so letting a client edit it would silently
    /// lose the change and desynchronise the broker's view from ours.
    private func requireManualTransaction(id: UUID, userId: UUID, on db: any Database) async throws -> Transaction {
        guard let model = try await Transaction.find(id, on: db) else {
            throw Abort(.notFound, reason: "Transaction not found.")
        }
        guard let account = try await Account.find(model.accountId, on: db), account.userId == userId else {
            throw Abort(.notFound, reason: "Transaction not found.")
        }
        guard model.externalId?.hasPrefix(Self.manualExternalIDPrefix) == true else {
            throw Abort(.forbidden, reason: "Imported transactions are read-only. Edit them at the source instead.")
        }
        return model
    }

    static func parseType(_ raw: String) throws -> TransactionType {
        guard let type = TransactionType(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            let allowed = TransactionType.allCases.map(\.rawValue).joined(separator: ", ")
            throw Abort(.badRequest, reason: "Invalid type '\(raw)'. Expected one of: \(allowed).")
        }
        return type
    }

    /// `trade_date` and `settle_date` are DATE columns. Parsing in UTC keeps a
    /// date-only value from sliding a day when the session timezone is behind GMT.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parseDateOnly(_ raw: String, field: String) throws -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "\(field) is required.")
        }
        guard let value = dateFormatter.date(from: trimmed) else {
            throw Abort(.badRequest, reason: "Invalid \(field). Expected YYYY-MM-DD.")
        }
        return value
    }

    static func response(for model: Transaction, symbol: String) throws -> TransactionResponse {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Transaction was not persisted.")
        }
        return TransactionResponse(
            id: id.uuidString,
            accountId: model.accountId.uuidString,
            instrumentId: symbol,
            type: model.type,
            quantity: model.quantity,
            price: model.price,
            currency: model.currency,
            tradeDate: dateFormatter.string(from: model.tradeDate),
            settleDate: model.settleDate.map { dateFormatter.string(from: $0) },
            fees: model.fees
        )
    }
}
