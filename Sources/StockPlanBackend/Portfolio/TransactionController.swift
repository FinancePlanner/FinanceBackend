import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Hand-entered trade records. See `TransactionService` for why manual rows are
/// namespaced away from importer-owned ones.
struct TransactionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.transactionsRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.transactionsWrite))

        read.get("transactions", use: list)
        write.group("transactions") { transactions in
            transactions.post(use: create)
            transactions.patch(":transactionId", use: update)
            transactions.delete(":transactionId", use: delete)
        }
    }

    @Sendable
    func list(req: Request) async throws -> [TransactionResponse] {
        let session = try req.auth.require(SessionToken.self)
        return try await TransactionService(req: req).list(userId: session.userId, on: req.db)
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(CreateTransactionRequest.self)
        let created = try await TransactionService(req: req).create(
            payload: payload,
            userId: session.userId,
            on: req.db
        )
        return try await created.encodeResponse(status: .created, for: req)
    }

    @Sendable
    func update(req: Request) async throws -> TransactionResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(UpdateTransactionRequest.self)
        return try await TransactionService(req: req).update(
            id: try requireTransactionId(req),
            payload: payload,
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await TransactionService(req: req).delete(
            id: try requireTransactionId(req),
            userId: session.userId,
            on: req.db
        )
        return .noContent
    }

    private func requireTransactionId(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("transactionId"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid transaction id.")
        }
        return id
    }
}
