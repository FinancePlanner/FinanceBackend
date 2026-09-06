import Fluent
import Foundation
import NIOCore
import Vapor

struct BrokerController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let brokers = routes.grouped("brokers")
        let protected = brokers.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.integrationsRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.integrationsWrite))

        read.get(use: listBrokers)
        // Holdings are portfolio data that happens to be served from the broker
        // prefix, so they follow the holdings domain, not integrations.
        protected.grouped(ScopeRequirementMiddleware(.holdingsRead)).get("holdings", use: listHoldings)
        read.get(":provider", use: getBroker)
        protected.grouped(ScopeRequirementMiddleware(.holdingsWrite))
            .group("import", "csv") { csv in
                csv.post(use: importCsvPreview)
                csv.post("commit", use: importCsvCommit)
            }
        write.post("ibkr", "connect", "start", use: startIBKRConnect)
        write.post("ibkr", "connect", "credentials", use: connectIBKRCredentials)
        write.post("ibkr", "sync", use: syncIbkr)
        read.get("ibkr", "sync", "status", use: getIbkrSyncStatus)
        write.delete("ibkr", "connection", use: disconnectIbkr)
    }

    @Sendable
    func listBrokers(req: Request) async throws -> [BrokerConnectionResponse] {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.brokersService.list(userId: session.userId, on: req.db)
    }

    @Sendable
    func getBroker(req: Request) async throws -> BrokerConnectionResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let provider = req.parameters.get("provider") else {
            throw Abort(.badRequest, reason: "Missing broker provider")
        }
        return try await req.application.brokersService.get(provider: provider, userId: session.userId, on: req.db)
    }

    @Sendable
    func listHoldings(req: Request) async throws -> [BrokerHoldingResponse] {
        let session = try req.auth.require(SessionToken.self)
        let stocks = try await req.application.stocksRepository.list(
            userId: session.userId,
            portfolioListId: nil,
            on: req.db
        )

        return stocks.map {
            BrokerHoldingResponse(symbol: $0.symbol, quantity: $0.shares, currency: "USD")
        }
    }

    @Sendable
    func syncIbkr(req: Request) async throws -> BrokerSyncResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .brokerSync,
            userId: session.userId,
            on: req.db
        )
        let response = try await req.application.brokersService.syncIBKR(userId: session.userId, on: req)
        await req.reconcileBadges(userId: session.userId, on: req.db)
        return response
    }

    @Sendable
    func getIbkrSyncStatus(req: Request) async throws -> BrokerSyncStatusResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let connection = try await BrokerConnection.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$provider == "ibkr")
            .first()
        else {
            throw Abort(.notFound, reason: "IBKR connection not found")
        }

        let now = Date()
        let isStale = connection.lastSyncedAt.map { now.timeIntervalSince($0) > 24 * 3600 } ?? true

        return BrokerSyncStatusResponse(
            status: connection.status,
            lastSyncedAt: connection.lastSyncedAt,
            isStale: isStale,
            statusDetail: connection.statusDetail
        )
    }

    @Sendable
    func startIBKRConnect(req: Request) async throws -> BrokerConnectStartResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(BrokerConnectStartRequest.self)
        return try await req.application.brokersService.startIBKRConnect(
            redirectURI: payload.redirectURI,
            portfolioListId: payload.portfolioListId,
            userId: session.userId,
            on: req
        )
    }

    @Sendable
    func connectIBKRCredentials(req: Request) async throws -> BrokerConnectionResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(BrokerConnectCredentialsRequest.self)
        return try await req.application.brokersService.connectIBKRCredentials(
            token: payload.token,
            queryId: payload.queryId,
            portfolioListId: payload.portfolioListId,
            userId: session.userId,
            on: req
        )
    }

    @Sendable
    func disconnectIbkr(req: Request) async throws -> BrokerConnectionResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.brokersService.disconnectIBKR(userId: session.userId, on: req.db)
    }

    @Sendable
    func importCsvPreview(req: Request) async throws -> CsvImportPreviewResponse {
        let session = try req.auth.require(SessionToken.self)
        let upload = try await readCsvUpload(req)
        return try await CsvPortfolioImportService().preview(
            csv: upload.csv,
            provider: upload.provider,
            portfolioListId: req.query[String.self, at: "portfolioListId"],
            userId: session.userId,
            on: req
        )
    }

    @Sendable
    func importCsvCommit(req: Request) async throws -> CsvImportCommitResponse {
        let session = try req.auth.require(SessionToken.self)
        let upload = try await readCsvUpload(req)
        let response = try await CsvPortfolioImportService().commit(
            csv: upload.csv,
            provider: upload.provider,
            portfolioListId: req.query[String.self, at: "portfolioListId"],
            userId: session.userId,
            on: req
        )
        await req.reconcileBadges(userId: session.userId, on: req.db)
        return response
    }

    private struct CsvMultipartUpload: Content {
        var provider: String?
        var file: File?
        var csv: File?
    }

    private func readCsvUpload(_ req: Request) async throws -> (provider: String, csv: String) {
        if req.headers.contentType?.type.lowercased() == "multipart" {
            let upload = try req.content.decode(CsvMultipartUpload.self)
            let provider = try requireProvider(req, multipartValue: upload.provider)
            guard var buffer = (upload.file ?? upload.csv)?.data else {
                throw Abort(.badRequest, reason: "Missing file field in multipart body.")
            }
            let maxBytes = 5 * 1024 * 1024
            guard buffer.readableBytes <= maxBytes else {
                throw Abort(.payloadTooLarge, reason: "CSV file must be 5 MB or smaller.")
            }
            guard let csv = buffer.readString(length: buffer.readableBytes) else {
                throw Abort(.badRequest, reason: "CSV file must be UTF-8 text.")
            }
            return (provider: provider, csv: csv)
        }

        let provider = try requireProvider(req, multipartValue: nil)
        let maxBytes = 5 * 1024 * 1024
        guard var buffer = try await req.body.collect(max: maxBytes).get() else {
            throw Abort(.badRequest, reason: "Missing CSV body.")
        }
        guard let csv = buffer.readString(length: buffer.readableBytes) else {
            throw Abort(.badRequest, reason: "CSV body must be UTF-8 text.")
        }
        return (provider: provider, csv: csv)
    }

    private func requireProvider(_ req: Request, multipartValue: String?) throws -> String {
        let raw = multipartValue
            ?? req.query[String.self, at: "provider"]
            ?? req.query[String.self, at: "broker"]
            ?? req.headers.first(name: "X-Broker-Provider")

        guard let raw else {
            throw Abort(.badRequest, reason: "Missing broker provider. Use ?provider=... or multipart field provider.")
        }

        return try BrokerProvider.normalize(raw)
    }
}
