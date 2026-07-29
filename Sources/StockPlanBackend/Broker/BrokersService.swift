import Fluent
import Foundation
import Vapor

enum BrokersServiceError: Error {
    case invalidProvider
    case notFound
}

extension BrokersServiceError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .invalidProvider:
            .badRequest
        case .notFound:
            .notFound
        }
    }

    var reason: String {
        switch self {
        case .invalidProvider:
            "Invalid broker provider."
        case .notFound:
            "Broker not found."
        }
    }
}

protocol BrokersService: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [BrokerConnectionResponse]
    func get(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse
    func recordCsvImport(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse
    func startIBKRConnect(redirectURI: String, portfolioListId: String?, userId: UUID, on req: Request) async throws -> BrokerConnectStartResponse
    func connectIBKRCredentials(
        token: String,
        queryId: String,
        portfolioListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> BrokerConnectionResponse
    func handleIBKRCallback(flowId: UUID?, code: String?, error: String?, state: String, on req: Request) async throws -> Response
    func syncIBKR(userId: UUID, on req: Request) async throws -> BrokerSyncResponse
    func disconnectIBKR(userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse
}

enum IBKRConnectMarkers {
    /// `BrokerConnection.externalId` value for Norviq Web Service (SOD) credentials.
    static let sodWebService = "sod-web-service"
}

private enum IBKRConnectionMode: String {
    case gateway = "Gateway"
    case sodWebService = "Web Service"

    init?(externalId: String?) {
        guard let externalId else { return nil }
        self = externalId == IBKRConnectMarkers.sodWebService ? .sodWebService : .gateway
    }
}

struct DefaultBrokersService: BrokersService {
    let repo: any BrokersRepository
    let ibkrGatewayClient: IBKRBrokerGatewayClient
    let ibkrOAuthClient: IBKROAuthClient?
    let ibkrConnectMode: IBKRConnectMode
    let tokenVault: any TokenEncryptionService

    init(
        repo: any BrokersRepository,
        ibkrGatewayClient: IBKRBrokerGatewayClient,
        ibkrOAuthClient: IBKROAuthClient? = nil,
        ibkrConnectMode: IBKRConnectMode = .gateway,
        tokenVault: any TokenEncryptionService
    ) {
        self.repo = repo
        self.ibkrGatewayClient = ibkrGatewayClient
        self.ibkrOAuthClient = ibkrOAuthClient
        self.ibkrConnectMode = ibkrConnectMode
        self.tokenVault = tokenVault
    }

    func list(userId: UUID, on db: any Database) async throws -> [BrokerConnectionResponse] {
        let connections = try await repo.list(userId: userId, on: db)
        return try connections.map { try BrokerConnectionResponse(from: $0) }
    }

    func get(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse {
        let normalized = try BrokerProvider.normalize(provider)
        guard let connection = try await repo.find(provider: normalized, userId: userId, on: db) else {
            throw BrokersServiceError.notFound
        }
        return try BrokerConnectionResponse(from: connection)
    }

    func recordCsvImport(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse {
        let normalized = try BrokerProvider.normalize(provider)
        let connection = try await repo.upsertCsvImport(provider: normalized, userId: userId, on: db)
        return try BrokerConnectionResponse(from: connection)
    }

    func startIBKRConnect(
        redirectURI: String,
        portfolioListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> BrokerConnectStartResponse {
        let normalizedRedirectURI = try normalizeRedirectURI(redirectURI)
        try validateRedirectURI(normalizedRedirectURI)
        let provider = "ibkr"
        let state = randomURLSafeString(length: 32)
        let expiresIn = 600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let resolvedPortfolioListId = try await resolvePortfolioListId(
            requestedId: portfolioListId,
            userId: userId,
            on: req.db,
            defaultWhenMissing: true
        )

        let flow = BrokerOAuthFlow(
            userId: userId,
            provider: provider,
            state: state,
            redirectURI: normalizedRedirectURI,
            portfolioListId: resolvedPortfolioListId,
            expiresAt: expiresAt
        )
        try await flow.save(on: req.db)

        guard let flowID = flow.id else {
            throw Abort(.internalServerError, reason: "Broker connect flow id missing.")
        }

        let callbackURL = try makeBrokerCallbackURL(req: req)
        let authorizationURL: URL
        if ibkrConnectMode == .oauth2 {
            guard let ibkrOAuthClient else {
                throw Abort(.serviceUnavailable, reason: "IBKR OAuth2 is not configured.")
            }
            authorizationURL = try ibkrOAuthClient.makeAuthorizationURL(
                state: state,
                redirectURI: callbackURL.absoluteString
            )
        } else {
            authorizationURL = try makeGatewayBrokerCallbackURL(
                callbackURL: callbackURL,
                flowId: flowID,
                state: state
            )
        }
        return BrokerConnectStartResponse(
            flowId: flowID.uuidString,
            authorizationURL: authorizationURL.absoluteString,
            expiresIn: expiresIn
        )
    }

    func connectIBKRCredentials(
        token: String,
        queryId: String,
        portfolioListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> BrokerConnectionResponse {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQueryId = queryId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw Abort(.badRequest, reason: "IBKR Web Service token is required.")
        }
        guard !trimmedQueryId.isEmpty else {
            throw Abort(.badRequest, reason: "IBKR Web Service query ID is required.")
        }
        if let conflictReason = try await ibkrConnectionModeConflictReason(
            desiredMode: .sodWebService,
            userId: userId,
            on: req.db
        ) {
            throw Abort(.conflict, reason: conflictReason)
        }

        let resolvedPortfolioListId = try await resolvePortfolioListId(
            requestedId: portfolioListId,
            userId: userId,
            on: req.db,
            defaultWhenMissing: true
        )
        let now = Date()
        let connection = try await upsertBrokerConnection(
            provider: "ibkr",
            userId: userId,
            externalId: IBKRConnectMarkers.sodWebService,
            displayName: "IBKR Web Service",
            status: "connected",
            statusDetail: "Credentials saved. Statement sync runs after IBKR publishes the daily SOD files.",
            connectedAt: now,
            lastSyncedAt: nil,
            portfolioListId: resolvedPortfolioListId,
            accessToken: trimmedToken,
            refreshToken: trimmedQueryId,
            expiresAt: nil,
            on: req.db
        )
        // Force SOD marker even when upsert would keep a prior externalId via ?? —
        // upsertBrokerConnection uses `externalId ?? connection.externalId`.
        connection.externalId = IBKRConnectMarkers.sodWebService
        connection.expiresAt = nil
        try await connection.save(on: req.db)
        return try BrokerConnectionResponse(from: connection)
    }

    func handleIBKRCallback(flowId: UUID?, code: String?, error: String?, state: String, on req: Request) async throws -> Response {
        let now = Date()
        let normalizedState = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let flowQuery = BrokerOAuthFlow.query(on: req.db)
            .filter(\.$provider == "ibkr")
            .filter(\.$usedAt == nil)
        if let flowId {
            flowQuery.filter(\.$id == flowId)
        } else {
            flowQuery.filter(\.$state == normalizedState)
        }
        guard let flow = try await flowQuery.first() else {
            throw Abort(.unauthorized, reason: "Broker connect flow is invalid or expired.")
        }

        guard flow.expiresAt > now else {
            throw Abort(.unauthorized, reason: "Broker connect flow expired.")
        }

        guard flow.state == normalizedState else {
            throw Abort(.unauthorized, reason: "Broker connect state mismatch.")
        }

        flow.usedAt = now
        try await flow.save(on: req.db)

        if let conflictReason = try await ibkrConnectionModeConflictReason(
            desiredMode: .gateway,
            userId: flow.userId,
            on: req.db
        ) {
            return redirectResponse(to: brokerAppRedirectURL(base: flow.redirectURI, status: "error", error: conflictReason))
        }

        do {
            if let error = error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                throw Abort(.badRequest, reason: "IBKR authorization failed: \(error)")
            }
            let authorization = try await connectCallbackAuthorization(
                flow: flow,
                code: code,
                callbackURL: makeBrokerCallbackURL(req: req),
                on: req
            )
            let syncClient = authorization.client
            let account = try await syncClient.requirePrimaryAccount(on: req)
            let connection = try await upsertBrokerConnection(
                provider: "ibkr",
                userId: flow.userId,
                externalId: account.externalID,
                displayName: account.displayName,
                status: "connected",
                statusDetail: nil,
                connectedAt: now,
                lastSyncedAt: nil,
                portfolioListId: flow.portfolioListId,
                accessToken: authorization.accessToken,
                refreshToken: authorization.refreshToken,
                expiresAt: authorization.expiresAt,
                on: req.db
            )

            _ = try await IBKRBrokerSyncService(gatewayClient: syncClient)
                .sync(connection: connection, userId: flow.userId, on: req)
            return redirectResponse(to: brokerAppRedirectURL(base: flow.redirectURI, status: "success", error: nil))
        } catch {
            _ = try? await upsertBrokerConnection(
                provider: "ibkr",
                userId: flow.userId,
                externalId: nil,
                displayName: nil,
                status: "error",
                statusDetail: brokerErrorMessage(error),
                connectedAt: nil,
                lastSyncedAt: nil,
                portfolioListId: flow.portfolioListId,
                accessToken: nil,
                refreshToken: nil,
                expiresAt: nil,
                on: req.db
            )
            return redirectResponse(
                to: brokerAppRedirectURL(
                    base: flow.redirectURI,
                    status: "error",
                    error: brokerErrorMessage(error)
                )
            )
        }
    }

    func syncIBKR(userId: UUID, on req: Request) async throws -> BrokerSyncResponse {
        guard let connection = try await repo.find(provider: "ibkr", userId: userId, on: req.db) else {
            throw BrokersServiceError.notFound
        }

        if connection.externalId == IBKRConnectMarkers.sodWebService {
            do {
                return try await IBKRSODSyncService(tokenVault: tokenVault)
                    .sync(connection: connection, userId: userId, on: req)
            } catch {
                // IBKRSODSyncService already stamps statusDetail on IBKRSODError;
                // still stamp unknown failures here.
                if connection.statusDetail == nil || !(error is IBKRSODError) {
                    connection.status = "error"
                    connection.statusDetail = brokerErrorMessage(error)
                    connection.updatedAt = Date()
                    try? await connection.save(on: req.db)
                }
                throw error
            }
        }

        do {
            let syncClient = try await syncDataClient(connection: connection, on: req)
            return try await IBKRBrokerSyncService(gatewayClient: syncClient)
                .sync(connection: connection, userId: userId, on: req)
        } catch {
            connection.status = "error"
            connection.statusDetail = brokerErrorMessage(error)
            connection.updatedAt = Date()
            try? await connection.save(on: req.db)
            throw error
        }
    }

    func disconnectIBKR(userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse {
        guard let connection = try await repo.find(provider: "ibkr", userId: userId, on: db) else {
            throw BrokersServiceError.notFound
        }

        // Disconnecting removes the synced holdings so a stale broker snapshot
        // never lingers as if it were manually entered. Ledger rows are keyed to
        // the account and cleaned up on the next reconcile; user-facing `stocks`
        // rows tagged with this provider are removed here.
        let importedStocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$sourceProvider == "ibkr")
            .all()
        for stock in importedStocks {
            try await stock.delete(on: db)
        }

        connection.accessToken = nil
        connection.refreshToken = nil
        connection.expiresAt = nil
        connection.status = "disconnected"
        connection.statusDetail = nil
        connection.updatedAt = Date()
        try await connection.save(on: db)
        return try BrokerConnectionResponse(from: connection)
    }
}

private struct IBKRCallbackAuthorization {
    let client: IBKRBrokerGatewayClient
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Date?
}

extension BrokerConnectionResponse {
    init(from model: BrokerConnection) throws {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "BrokerConnection id missing")
        }

        self.init(
            id: id.uuidString,
            provider: model.provider,
            status: model.status,
            displayName: model.displayName,
            statusDetail: model.statusDetail,
            connectedAt: model.connectedAt,
            lastSyncedAt: model.lastSyncedAt,
            portfolioListId: model.portfolioListId?.uuidString
        )
    }
}

private extension DefaultBrokersService {
    func normalizeRedirectURI(_ redirectURI: String) throws -> String {
        let normalized = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized),
              let scheme = url.scheme,
              !scheme.isEmpty,
              url.host != nil || url.path.hasPrefix("/")
        else {
            throw Abort(.badRequest, reason: "Invalid broker redirect URI.")
        }
        return normalized
    }

    func validateRedirectURI(_ redirectURI: String) throws {
        let allowed = Environment.get("OAUTH_ALLOWED_REDIRECT_URIS")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        guard !allowed.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "OAuth redirect allowlist is not configured.")
        }
        guard allowed.contains(redirectURI) else {
            throw Abort(.badRequest, reason: "Broker redirect URI is not allowed.")
        }
    }

    func makeBrokerCallbackURL(req: Request) throws -> URL {
        let scheme = req.headers.first(name: "X-Forwarded-Proto") ?? "https"
        guard let host = req.headers.first(name: .host), !host.isEmpty else {
            throw Abort(.internalServerError, reason: "Missing request host.")
        }
        guard var components = URLComponents(string: "\(scheme)://\(host)") else {
            throw Abort(.internalServerError, reason: "Failed to build broker callback URL.")
        }
        components.path = "/v1/auth/brokers/ibkr/callback"
        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Failed to build broker callback URL.")
        }
        return url
    }

    func makeGatewayBrokerCallbackURL(callbackURL: URL, flowId: UUID, state: String) throws -> URL {
        guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw Abort(.internalServerError, reason: "Failed to build broker callback URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "flowId", value: flowId.uuidString),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Failed to build broker callback URL.")
        }
        return url
    }

    func connectCallbackAuthorization(
        flow _: BrokerOAuthFlow,
        code: String?,
        callbackURL: URL,
        on req: Request
    ) async throws -> IBKRCallbackAuthorization {
        guard ibkrConnectMode == .oauth2 else {
            return IBKRCallbackAuthorization(client: ibkrGatewayClient, accessToken: nil, refreshToken: nil, expiresAt: nil)
        }
        guard let ibkrOAuthClient else {
            throw Abort(.serviceUnavailable, reason: "IBKR OAuth2 is not configured.")
        }
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            throw Abort(.badRequest, reason: "Missing IBKR authorization code.")
        }

        let token = try await ibkrOAuthClient.exchangeCode(
            code: code,
            redirectURI: callbackURL.absoluteString,
            on: req
        )
        let expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        let client = IBKRBrokerGatewayClient(
            baseURL: ibkrOAuthClient.config.apiBaseURL,
            defaultCurrency: ibkrGatewayClient.defaultCurrency,
            accessToken: token.accessToken
        )
        return IBKRCallbackAuthorization(
            client: client,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: expiresAt
        )
    }

    func syncDataClient(connection: BrokerConnection, on req: Request) async throws -> IBKRBrokerGatewayClient {
        if connection.externalId == IBKRConnectMarkers.sodWebService {
            throw Abort(
                .serviceUnavailable,
                reason: "IBKR statement sync is not available yet. Your Web Service token and query ID are saved."
            )
        }

        guard let storedAccessToken = connection.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !storedAccessToken.isEmpty,
              let ibkrOAuthClient
        else {
            return ibkrGatewayClient
        }

        let accessToken = try tokenVault.decrypt(storedAccessToken, context: .broker)
        let storedRefreshToken = connection.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = try storedRefreshToken.flatMap { stored -> String? in
            guard !stored.isEmpty else { return nil }
            return try tokenVault.decrypt(stored, context: .broker)
        }

        let refreshThreshold = Date().addingTimeInterval(60)
        if let expiresAt = connection.expiresAt,
           expiresAt <= refreshThreshold,
           let refreshToken,
           !refreshToken.isEmpty
        {
            let token = try await ibkrOAuthClient.refresh(refreshToken: refreshToken, on: req)
            connection.accessToken = try tokenVault.encrypt(token.accessToken, context: .broker)
            connection.refreshToken = try tokenVault.encrypt(token.refreshToken ?? refreshToken, context: .broker)
            connection.expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            connection.updatedAt = Date()
            try await connection.save(on: req.db)
            return IBKRBrokerGatewayClient(
                baseURL: ibkrOAuthClient.config.apiBaseURL,
                defaultCurrency: ibkrGatewayClient.defaultCurrency,
                accessToken: token.accessToken
            )
        }

        // Legacy plaintext rows predate the encryption service; re-encrypt on first use.
        if !tokenVault.isEncrypted(storedAccessToken) || storedRefreshToken.map({ !$0.isEmpty && !tokenVault.isEncrypted($0) }) == true {
            connection.accessToken = try tokenVault.encrypt(accessToken, context: .broker)
            if let refreshToken, !refreshToken.isEmpty {
                connection.refreshToken = try tokenVault.encrypt(refreshToken, context: .broker)
            }
            connection.updatedAt = Date()
            try await connection.save(on: req.db)
        }

        return IBKRBrokerGatewayClient(
            baseURL: ibkrOAuthClient.config.apiBaseURL,
            defaultCurrency: ibkrGatewayClient.defaultCurrency,
            accessToken: accessToken
        )
    }

    func redirectResponse(to url: URL) -> Response {
        let response = Response(status: .seeOther)
        response.headers.replaceOrAdd(name: .location, value: url.absoluteString)
        return response
    }

    func brokerAppRedirectURL(base: String, status: String, error: String?) -> URL {
        var components = URLComponents(string: base) ?? URLComponents()
        var queryItems = components.queryItems ?? []
        queryItems.append(.init(name: "broker", value: "ibkr"))
        queryItems.append(.init(name: "status", value: status))
        if let error, !error.isEmpty {
            queryItems.append(.init(name: "error", value: error))
        }
        components.queryItems = queryItems
        return components.url ?? URL(string: base)!
    }

    // swiftlint:disable:next function_parameter_count
    func upsertBrokerConnection(
        provider: String,
        userId: UUID,
        externalId: String?,
        displayName: String?,
        status: String,
        statusDetail: String?,
        connectedAt: Date?,
        lastSyncedAt: Date?,
        portfolioListId: UUID?,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        on db: any Database
    ) async throws -> BrokerConnection {
        let connection = try await repo.find(provider: provider, userId: userId, on: db)
            ?? BrokerConnection(userId: userId, provider: provider, status: status)
        connection.externalId = externalId ?? connection.externalId
        connection.accessToken = try accessToken.map { try tokenVault.encrypt($0, context: .broker) }
            ?? connection.accessToken
        connection.refreshToken = try refreshToken.map { try tokenVault.encrypt($0, context: .broker) }
            ?? connection.refreshToken
        connection.expiresAt = expiresAt ?? connection.expiresAt
        connection.displayName = displayName ?? connection.displayName
        connection.status = status
        connection.statusDetail = statusDetail
        connection.connectedAt = connectedAt ?? connection.connectedAt
        connection.lastSyncedAt = lastSyncedAt ?? connection.lastSyncedAt
        connection.portfolioListId = portfolioListId ?? connection.portfolioListId
        connection.updatedAt = Date()
        try await connection.save(on: db)
        return connection
    }

    private func ibkrConnectionModeConflictReason(
        desiredMode: IBKRConnectionMode,
        userId: UUID,
        on db: any Database
    ) async throws -> String? {
        guard let existing = try await repo.find(provider: "ibkr", userId: userId, on: db),
              existing.status != "disconnected",
              let existingMode = IBKRConnectionMode(externalId: existing.externalId),
              existingMode != desiredMode
        else {
            return nil
        }
        return "Disconnect the existing IBKR \(existingMode.rawValue) connection before connecting IBKR \(desiredMode.rawValue)."
    }

    func brokerErrorMessage(_ error: any Error) -> String {
        if let abortError = error as? any AbortError {
            return abortError.reason
        }
        return (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0 ..< length).map { _ in alphabet.randomElement()! })
    }
}
