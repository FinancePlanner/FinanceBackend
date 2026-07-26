import Crypto
import Fluent
import Foundation
import Redis
import StockPlanShared
import Vapor

/// GoCardless Bank Account Data driver (EU). AIS-only and read-only by design.
/// Uses a hosted requisition flow (no SDK) and polls transactions within the
/// PSD2 rate limit (≤4 API calls/day/account), enforced via Redis.
struct GoCardlessProvider: BankProvider {
    let kind: BankProviderKind = .gocardless
    let client: GoCardlessClient

    /// PSD2 caps balance/transaction pulls at 4/day/account. Keep headroom for
    /// user-triggered manual syncs.
    private let dailyAccountCallBudget = 4

    // MARK: - SDK-style methods are unsupported (GoCardless uses hosted links)

    func createLinkSession(userId _: UUID, on _: Request) async throws -> BankLinkSessionResponse {
        throw BankProviderError.unsupportedOperation
    }

    func exchange(_: BankExchangeRequest, userId _: UUID, on _: Request) async throws -> BankConnection {
        throw BankProviderError.unsupportedOperation
    }

    // MARK: - Hosted-link flow

    func listInstitutions(country: String, on req: Request) async throws -> [BankInstitutionResponse] {
        let token = try await client.newAccessToken(on: req)
        let institutions = try await client.institutions(country: country, accessToken: token, on: req)
        return institutions.map {
            BankInstitutionResponse(id: $0.id, name: $0.name, bic: $0.bic, logoURL: $0.logo, country: country.uppercased())
        }
    }

    func createHostedLink(userId: UUID, institutionId: String, redirectURI: String, on req: Request) async throws -> BankLinkSessionResponse {
        let token = try await client.newAccessToken(on: req)
        let agreementId = try await client.createAgreement(institutionId: institutionId, accessToken: token, on: req)

        let reference = Self.randomReference()
        let callbackURL = try Self.callbackURL(req: req)
        let requisition = try await client.createRequisition(
            institutionId: institutionId,
            redirect: callbackURL,
            agreementId: agreementId,
            reference: reference,
            accessToken: token,
            on: req
        )

        let flow = BankLinkFlow(
            userId: userId,
            provider: kind.rawValue,
            reference: reference,
            requisitionId: requisition.id,
            institutionId: institutionId,
            appRedirectURI: redirectURI,
            expiresAt: Date().addingTimeInterval(1800)
        )
        try await flow.save(on: req.db)

        return BankLinkSessionResponse(provider: .gocardless, linkToken: nil, hostedURL: requisition.link, expiration: flow.expiresAt)
    }

    func completeHostedLink(reference: String, on req: Request) async throws -> BankConnection {
        let now = Date()
        guard let flow = try await BankLinkFlow.query(on: req.db)
            .filter(\.$reference == reference)
            .filter(\.$provider == kind.rawValue)
            .first(),
            flow.expiresAt > now
        else {
            throw Abort(.badRequest, reason: "Bank link is invalid or expired.")
        }

        if let existing = try await existingConnection(for: flow, on: req.db), flow.usedAt != nil {
            return existing
        }

        let token = try await client.newAccessToken(on: req)
        let requisition = try await client.requisition(id: flow.requisitionId, accessToken: token, on: req)
        let accountIds = requisition.accounts ?? []
        guard !accountIds.isEmpty else {
            throw Abort(.badRequest, reason: "No accounts were shared for this bank.")
        }

        if let existing = try await existingConnection(for: flow, on: req.db) {
            try await ensureAccounts(accountIds, connection: existing, accessToken: token, on: req)
            try await markUsed(flow, at: now, on: req.db)
            _ = try? await sync(connection: existing, on: req)
            return existing
        }

        guard flow.usedAt == nil else {
            throw Abort(.badRequest, reason: "Bank link is invalid or expired.")
        }

        let connection = BankConnection(
            userId: flow.userId,
            provider: kind.rawValue,
            institutionId: flow.institutionId,
            institutionName: flow.institutionId,
            providerItemId: flow.requisitionId,
            accessTokenEnc: nil,
            status: BankConnectionStatus.active.rawValue,
            consentExpiresAt: now.addingTimeInterval(90 * 86400)
        )
        try await connection.save(on: req.db)
        guard let connectionId = connection.id else {
            throw Abort(.internalServerError, reason: "Bank connection id missing.")
        }

        try await ensureAccounts(accountIds, connectionId: connectionId, accessToken: token, on: req)

        try await markUsed(flow, at: now, on: req.db)

        _ = try? await sync(connection: connection, on: req)
        return connection
    }

    // MARK: - Sync

    func sync(connection: BankConnection, on req: Request) async throws -> BankSyncResult {
        guard let connectionId = connection.id else {
            throw Abort(.internalServerError, reason: "Bank connection id missing.")
        }
        if let expiry = connection.consentExpiresAt, expiry <= Date() {
            connection.status = BankConnectionStatus.reauthRequired.rawValue
            connection.lastSyncStatus = "consent_expired"
            try await connection.save(on: req.db)
            throw Abort(.forbidden, reason: "Bank consent expired. Reconnect to keep syncing.")
        }

        let token = try await client.newAccessToken(on: req)
        let accounts = try await BankAccount.query(on: req.db).filter(\.$connectionId == connectionId).all()

        var result = BankSyncResult()
        for account in accounts {
            guard try await consumeDailyBudget(accountId: account.providerAccountId, on: req) else {
                req.logger.info("gocardless daily budget exhausted account=\(account.providerAccountId)")
                continue
            }
            let payload = try await client.transactions(accountId: account.providerAccountId, accessToken: token, on: req)
            let booked = payload.transactions.booked ?? []
            let pending = payload.transactions.pending ?? []
            for tx in booked {
                if try await upsert(tx, pending: false, account: account, userId: connection.userId, on: req.db) {
                    result.added += 1
                } else {
                    result.modified += 1
                }
            }
            for tx in pending {
                if try await upsert(tx, pending: true, account: account, userId: connection.userId, on: req.db) {
                    result.added += 1
                } else {
                    result.modified += 1
                }
            }
        }

        connection.lastSyncedAt = Date()
        connection.lastSyncStatus = "ok"
        connection.lastSyncError = nil
        try await connection.save(on: req.db)
        return result
    }

    func disconnect(connection: BankConnection, on req: Request) async throws {
        let token = try await client.newAccessToken(on: req)
        try? await client.deleteRequisition(id: connection.providerItemId, accessToken: token, on: req)
    }

    // MARK: - Helpers

    /// Returns true if a call is allowed under the per-account daily budget.
    /// When Redis is unavailable, allows the call (fails open in dev).
    private func consumeDailyBudget(accountId: String, on req: Request) async throws -> Bool {
        guard req.application.redis.configuration != nil else { return true }
        let key = RedisKey("gocardless:budget:\(accountId)")
        let count = try await req.redis.increment(key).get()
        if count == 1 {
            _ = try? await req.redis.expire(key, after: .hours(24)).get()
        }
        return count <= dailyAccountCallBudget
    }

    func upsert(_ tx: GCTransaction, pending: Bool, account: BankAccount, userId: UUID, on db: any Database) async throws -> Bool {
        guard let accountId = account.id else { return false }
        let amount = Double(tx.transactionAmount.amount) ?? 0
        let dateString = tx.bookingDate ?? tx.valueDate ?? ""
        let occurredOn = Self.dateFormatter.date(from: dateString) ?? Date()
        let merchant = tx.creditorName ?? tx.debtorName ?? tx.remittanceInformationUnstructured
        // GoCardless transaction ids are unstable at some banks; fall back to a hash.
        let providerTxId = tx.transactionId ?? tx.internalTransactionId
            ?? Self.hash(accountId: accountId, date: dateString, amount: amount, description: merchant ?? "")
        let dedupeHash = Self.hash(accountId: accountId, date: dateString, amount: amount, description: merchant ?? "")

        if let existing = try await BankTransaction.query(on: db)
            .filter(\.$accountId == accountId)
            .filter(\.$providerTxId == providerTxId)
            .first()
        {
            if existing.status == BankTransactionStatus.suggested.rawValue {
                try await updateSuggested(
                    existing,
                    providerTxId: providerTxId,
                    dedupeHash: dedupeHash,
                    tx: tx,
                    amount: amount,
                    occurredOn: occurredOn,
                    merchant: merchant,
                    pending: pending,
                    on: db
                )
            }
            return false
        }

        if let existingPending = try await pendingMatchForBooked(
            tx,
            accountId: accountId,
            dedupeHash: dedupeHash,
            pending: pending,
            on: db
        ) {
            if existingPending.status == BankTransactionStatus.suggested.rawValue {
                try await updateSuggested(
                    existingPending,
                    providerTxId: providerTxId,
                    dedupeHash: dedupeHash,
                    tx: tx,
                    amount: amount,
                    occurredOn: occurredOn,
                    merchant: merchant,
                    pending: pending,
                    on: db
                )
            }
            return false
        }

        let row = BankTransaction(
            accountId: accountId,
            userId: userId,
            providerTxId: providerTxId,
            dedupeHash: dedupeHash,
            amount: amount,
            currency: tx.transactionAmount.currency,
            occurredOn: occurredOn,
            merchant: merchant,
            descriptionText: tx.remittanceInformationUnstructured,
            pending: pending,
            status: BankTransactionStatus.suggested.rawValue
        )
        try await row.save(on: db)
        return true
    }

    private func pendingMatchForBooked(
        _ tx: GCTransaction,
        accountId: UUID,
        dedupeHash: String,
        pending: Bool,
        on db: any Database
    ) async throws -> BankTransaction? {
        guard !pending else { return nil }

        if let internalTransactionId = tx.internalTransactionId,
           !internalTransactionId.isEmpty,
           let existing = try await BankTransaction.query(on: db)
           .filter(\.$accountId == accountId)
           .filter(\.$providerTxId == internalTransactionId)
           .filter(\.$pending == true)
           .first()
        {
            return existing
        }

        let hashMatches = try await BankTransaction.query(on: db)
            .filter(\.$accountId == accountId)
            .filter(\.$dedupeHash == dedupeHash)
            .filter(\.$pending == true)
            .all()

        return hashMatches.count == 1 ? hashMatches[0] : nil
    }

    private func existingConnection(for flow: BankLinkFlow, on db: any Database) async throws -> BankConnection? {
        try await BankConnection.query(on: db)
            .filter(\.$provider == kind.rawValue)
            .filter(\.$providerItemId == flow.requisitionId)
            .first()
    }

    private func ensureAccounts(_ accountIds: [String], connection: BankConnection, accessToken: String, on req: Request) async throws {
        guard let connectionId = connection.id else {
            throw Abort(.internalServerError, reason: "Bank connection id missing.")
        }
        try await ensureAccounts(accountIds, connectionId: connectionId, accessToken: accessToken, on: req)
    }

    private func ensureAccounts(_ accountIds: [String], connectionId: UUID, accessToken: String, on req: Request) async throws {
        let existing = try await BankAccount.query(on: req.db)
            .filter(\.$connectionId == connectionId)
            .all()
        let existingIds = Set(existing.map(\.providerAccountId))

        for accountId in accountIds where !existingIds.contains(accountId) {
            let name = await (try? client.accountDetails(accountId: accountId, accessToken: accessToken, on: req))?.account
            let account = BankAccount(
                connectionId: connectionId,
                providerAccountId: accountId,
                name: name?.name ?? name?.ownerName ?? "Account",
                currency: name?.currency
            )
            try await account.save(on: req.db)
        }
    }

    private func markUsed(_ flow: BankLinkFlow, at date: Date, on db: any Database) async throws {
        guard flow.usedAt == nil else { return }
        flow.usedAt = date
        try await flow.save(on: db)
    }

    private func updateSuggested(
        _ existing: BankTransaction,
        providerTxId: String,
        dedupeHash: String,
        tx: GCTransaction,
        amount: Double,
        occurredOn: Date,
        merchant: String?,
        pending: Bool,
        on db: any Database
    ) async throws {
        existing.providerTxId = providerTxId
        existing.amount = amount
        existing.currency = tx.transactionAmount.currency
        existing.occurredOn = occurredOn
        existing.merchant = merchant
        existing.descriptionText = tx.remittanceInformationUnstructured
        existing.pending = pending
        existing.dedupeHash = dedupeHash
        try await existing.save(on: db)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func hash(accountId: UUID, date: String, amount: Double, description: String) -> String {
        let normalized = "\(accountId.uuidString)|\(date)|\(String(format: "%.2f", amount))|\(description.lowercased().trimmingCharacters(in: .whitespaces))"
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomReference() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return "nvq-" + String((0 ..< 24).map { _ in alphabet.randomElement()! })
    }

    private static func callbackURL(req: Request) throws -> String {
        let scheme = req.headers.first(name: "X-Forwarded-Proto") ?? "https"
        guard let host = req.headers.first(name: .host), !host.isEmpty else {
            throw Abort(.internalServerError, reason: "Missing request host.")
        }
        return "\(scheme)://\(host)/v1/banks/gocardless/callback"
    }
}
