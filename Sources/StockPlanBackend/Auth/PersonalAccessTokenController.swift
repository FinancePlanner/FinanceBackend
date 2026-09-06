import Fluent
import Foundation
import Vapor

struct PersonalAccessTokenController: RouteCollection {
    static let defaultExpiryDays = 90
    static let maxExpiryDays = 365
    static let maxActiveTokensPerUser = 25

    func boot(routes: any RoutesBuilder) throws {
        // Never scopeable. A credential that can mint credentials can grant itself
        // every scope, which would reduce APIScope to advisory labelling. This stays
        // on the first-party session authenticator, with FirstPartyOnlyMiddleware and
        // the requireFirstPartySession check below as defence in depth.
        let tokens = routes
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
            .grouped(FirstPartyOnlyMiddleware())
            .grouped("tokens")
        tokens.post(use: create)
        tokens.get(use: list)
        tokens.delete(":tokenId", use: revoke)
    }

    // MARK: - Handlers

    func create(req: Request) async throws -> PersonalAccessTokenCreateResponse {
        let session = try requireFirstPartySession(req)
        try await req.usageCounterService.requirePremium(.mcpAccess, userId: session.userId, on: req.db)

        let payload = try req.content.decode(PersonalAccessTokenCreateRequest.self)
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else {
            throw Abort(.badRequest, reason: "Token name must be 1-100 characters.")
        }
        guard !payload.scopes.isEmpty else {
            throw Abort(.badRequest, reason: "At least one scope is required.")
        }
        let scopes = try APIScope.parse(payload.scopes)

        let expiryDays = payload.expiresInDays ?? Self.defaultExpiryDays
        guard (1 ... Self.maxExpiryDays).contains(expiryDays) else {
            throw Abort(.badRequest, reason: "expiresInDays must be between 1 and \(Self.maxExpiryDays).")
        }

        let activeCount = try await PersonalAccessToken.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$revokedAt == nil)
            .count()
        guard activeCount < Self.maxActiveTokensPerUser else {
            throw Abort(.badRequest, reason: "Active token limit reached. Revoke unused tokens first.")
        }

        let rawToken = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        let pat = PersonalAccessToken(
            userId: session.userId,
            name: name,
            tokenHash: OpaqueToken.sha256Hex(rawToken),
            scopes: scopes.map(\.rawValue).sorted(),
            expiresAt: Date().addingTimeInterval(TimeInterval(expiryDays * 86400))
        )
        try await pat.save(on: req.db)

        return try PersonalAccessTokenCreateResponse(
            id: pat.requireID(),
            name: pat.name,
            scopes: pat.scopes,
            token: rawToken,
            expiresAt: pat.expiresAt,
            createdAt: pat.createdAt ?? Date()
        )
    }

    func list(req: Request) async throws -> PersonalAccessTokenListResponse {
        let session = try requireFirstPartySession(req)
        let tokens = try await PersonalAccessToken.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$revokedAt == nil)
            .sort(\.$createdAt, .descending)
            .all()
        return try PersonalAccessTokenListResponse(items: tokens.map { pat in
            try PersonalAccessTokenSummary(
                id: pat.requireID(),
                name: pat.name,
                scopes: pat.scopes,
                lastUsedAt: pat.lastUsedAt,
                expiresAt: pat.expiresAt,
                createdAt: pat.createdAt ?? Date()
            )
        })
    }

    func revoke(req: Request) async throws -> HTTPStatus {
        let session = try requireFirstPartySession(req)
        guard let tokenId = req.parameters.get("tokenId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid token id.")
        }
        guard let pat = try await PersonalAccessToken.query(on: req.db)
            .filter(\.$id == tokenId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Token not found.")
        }
        if pat.revokedAt == nil {
            pat.revokedAt = Date()
            try await pat.save(on: req.db)
        }
        return .noContent
    }

    /// Token management requires a first-party session: a PAT must not mint or revoke PATs.
    private func requireFirstPartySession(_ req: Request) throws -> SessionToken {
        guard req.auth.get(ScopeContext.self) == nil else {
            throw Abort(.forbidden, reason: "Token management requires a first-party session.")
        }
        return try req.auth.require(SessionToken.self)
    }
}

// MARK: - DTOs

struct PersonalAccessTokenCreateRequest: Content {
    let name: String
    let scopes: [String]
    let expiresInDays: Int?
}

struct PersonalAccessTokenCreateResponse: Content {
    let id: UUID
    let name: String
    let scopes: [String]
    /// Plaintext token — returned exactly once at creation.
    let token: String
    let expiresAt: Date
    let createdAt: Date
}

struct PersonalAccessTokenSummary: Content {
    let id: UUID
    let name: String
    let scopes: [String]
    let lastUsedAt: Date?
    let expiresAt: Date
    let createdAt: Date
}

struct PersonalAccessTokenListResponse: Content {
    let items: [PersonalAccessTokenSummary]
}
