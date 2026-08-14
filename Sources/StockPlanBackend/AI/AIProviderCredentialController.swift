import Fluent
import Foundation
import Vapor

/// CRUD for bring-your-own LLM provider keys.
///
/// Deliberately unlike `PersonalAccessTokenController` in one respect: the
/// plaintext key is never returned, not even once at creation. A PAT is
/// returned once because Norviq mints it and the user has no other copy. Here
/// the user supplied the key, so echoing it back would only put a second copy
/// in a response body and any log that captures one.
struct AIProviderCredentialController: RouteCollection {
    static let maxLabelLength = 100
    static let maxKeyLength = 512

    func boot(routes: any RoutesBuilder) throws {
        let credentials = routes
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
            .grouped("ai", "credentials")
        credentials.get(use: list)
        credentials.post(use: upsert)
        credentials.post(":credentialId", "verify", use: verify)
        credentials.delete(":credentialId", use: delete)
    }

    // MARK: - Handlers

    func list(req: Request) async throws -> UserAIProviderCredentialListResponse {
        let session = try requireFirstPartySession(req)
        try requireEnabled()

        let rows = try await UserAIProviderCredential.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$createdAt, .descending)
            .all()

        return try UserAIProviderCredentialListResponse(items: rows.map(Self.summary(for:)))
    }

    func upsert(req: Request) async throws -> Response {
        let session = try requireFirstPartySession(req)
        try requireEnabled()

        let payload = try req.content.decode(UserAIProviderCredentialCreateRequest.self)

        guard let provider = UserAIProvider(rawValue: payload.provider.lowercased()) else {
            throw Abort(.badRequest, reason: "Unknown provider '\(payload.provider)'.")
        }

        let label = payload.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= Self.maxLabelLength else {
            throw Abort(.badRequest, reason: "Label must be 1-\(Self.maxLabelLength) characters.")
        }

        let apiKey = payload.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, apiKey.count <= Self.maxKeyLength else {
            throw Abort(.badRequest, reason: "API key must be 1-\(Self.maxKeyLength) characters.")
        }
        // Embedded whitespace means a mangled paste, which is the single most
        // common BYO-key support ticket. Catch it here rather than letting the
        // provider return a confusing 401.
        guard !apiKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw Abort(.badRequest, reason: "API key contains whitespace — check for a broken copy/paste.")
        }

        var baseURL: String?
        if provider.requiresExplicitEndpoint {
            guard let raw = payload.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                throw Abort(.badRequest, reason: "A base URL is required for an OpenAI-compatible endpoint.")
            }
            // SSRF guard. The server is about to send a bearer token here.
            _ = try OutboundURLGuard.validateForRequest(raw)
            baseURL = raw
            guard let model = payload.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
                throw Abort(.badRequest, reason: "A default model is required for an OpenAI-compatible endpoint.")
            }
        } else if let raw = payload.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            _ = try OutboundURLGuard.validateForRequest(raw)
            baseURL = raw
        }

        let encrypted = try req.tokenEncryptionService.encrypt(apiKey, context: .aiProvider)

        // Upsert rather than insert: the (user_id, provider) unique constraint
        // would otherwise turn "I rotated my key" into an opaque 409.
        let existing = try await UserAIProviderCredential.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$provider == provider.rawValue)
            .first()

        let row = existing ?? UserAIProviderCredential(
            userId: session.userId,
            provider: provider,
            label: label,
            apiKeyEncrypted: encrypted,
            keyHint: UserAIProviderCredential.hint(for: apiKey),
            keyFingerprint: OpaqueToken.sha256Hex(apiKey),
            baseURL: baseURL,
            defaultModel: payload.defaultModel
        )
        if existing != nil {
            row.label = label
            row.apiKeyEncrypted = encrypted
            row.keyHint = UserAIProviderCredential.hint(for: apiKey)
            row.keyFingerprint = OpaqueToken.sha256Hex(apiKey)
            row.baseURL = baseURL
            row.defaultModel = payload.defaultModel
            row.status = UserAIProviderCredentialStatus.unverified.rawValue
            row.lastErrorCode = nil
            row.lastErrorAt = nil
            row.lastVerifiedAt = nil
        }
        try await row.save(on: req.db)

        if payload.verify ?? true {
            let result = try await req.application.aiProviderCredentialVerifier.verify(
                provider: provider,
                apiKey: apiKey,
                baseURL: row.baseURL,
                defaultModel: row.defaultModel,
                on: req
            )
            Self.apply(result, to: row)
            try await row.save(on: req.db)
        }

        let summary = try Self.summary(for: row)
        let status: HTTPStatus = existing == nil ? .created : .ok
        return try await summary.encodeResponse(status: status, for: req)
    }

    func verify(req: Request) async throws -> UserAIProviderCredentialVerifyResponse {
        let session = try requireFirstPartySession(req)
        try requireEnabled()

        let row = try await requireOwnedCredential(req, userId: session.userId)
        guard let provider = row.providerKind else {
            throw Abort(.badRequest, reason: "Stored credential has an unrecognised provider.")
        }
        let apiKey = try decryptKey(row, on: req)

        let result = try await req.application.aiProviderCredentialVerifier.verify(
            provider: provider,
            apiKey: apiKey,
            baseURL: row.baseURL,
            defaultModel: row.defaultModel,
            on: req
        )
        Self.apply(result, to: row)
        try await row.save(on: req.db)

        // 200 even on a bad key: the diagnostic call itself succeeded, and the
        // settings page renders a result card either way. A 4xx here would
        // force an error branch through the whole web handler for a normal,
        // expected answer.
        return UserAIProviderCredentialVerifyResponse(
            status: row.status,
            verifiedAt: row.lastVerifiedAt,
            errorCode: row.lastErrorCode,
            detail: result.detail,
            latencyMs: result.latencyMs
        )
    }

    func delete(req: Request) async throws -> HTTPStatus {
        let session = try requireFirstPartySession(req)
        try requireEnabled()

        let row = try await requireOwnedCredential(req, userId: session.userId)
        let provider = row.provider
        // Hard delete, not a soft revoke: Fluent cannot express a partial
        // unique index, so a tombstoned row would block re-adding the provider
        // forever. The reversible case is status = "disabled".
        try await row.delete(on: req.db)
        req.logger.info("ai_credential.deleted user=\(session.userId) provider=\(provider)")
        return .noContent
    }

    // MARK: - Helpers

    /// Credential management requires a first-party session.
    ///
    /// This matters more here than it does for PATs: without it, an MCP token
    /// scoped to read expenses could enumerate or replace the user's provider
    /// keys.
    private func requireFirstPartySession(_ req: Request) throws -> SessionToken {
        guard req.auth.get(ScopeContext.self) == nil else {
            throw Abort(.forbidden, reason: "Credential management requires a first-party session.")
        }
        return try req.auth.require(SessionToken.self)
    }

    private func requireEnabled() throws {
        guard AICredentialSettings.enabled else {
            throw Abort(.serviceUnavailable, reason: "Bring-your-own-key is currently disabled.")
        }
    }

    private func requireOwnedCredential(_ req: Request, userId: UUID) async throws -> UserAIProviderCredential {
        guard let id = req.parameters.get("credentialId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid credential id.")
        }
        guard let row = try await UserAIProviderCredential.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Credential not found.")
        }
        return row
    }

    private func decryptKey(_ row: UserAIProviderCredential, on req: Request) throws -> String {
        // For this table plaintext can only mean corruption or a bad write
        // path, so refuse it rather than using the legacy passthrough.
        guard req.tokenEncryptionService.isEncrypted(row.apiKeyEncrypted) else {
            throw Abort(.internalServerError, reason: "Stored credential is not encrypted.")
        }
        return try req.tokenEncryptionService.decrypt(row.apiKeyEncrypted, context: .aiProvider)
    }

    private static func apply(_ result: AIProviderVerifyResult, to row: UserAIProviderCredential) {
        if result.ok {
            row.status = UserAIProviderCredentialStatus.active.rawValue
            row.lastVerifiedAt = Date()
            row.lastErrorCode = nil
            row.lastErrorAt = nil
            return
        }
        row.lastErrorCode = result.errorCode?.rawValue
        row.lastErrorAt = Date()
        // Rate limiting and unreachability prove nothing about the key, so they
        // must not brand it invalid.
        if !result.isInconclusive {
            row.status = UserAIProviderCredentialStatus.invalid.rawValue
        }
    }

    private static func summary(for row: UserAIProviderCredential) throws -> UserAIProviderCredentialSummary {
        try UserAIProviderCredentialSummary(
            id: row.requireID(),
            provider: row.provider,
            label: row.label,
            keyHint: row.keyHint,
            baseURL: row.baseURL,
            defaultModel: row.defaultModel,
            status: row.status,
            lastVerifiedAt: row.lastVerifiedAt,
            lastUsedAt: row.lastUsedAt,
            lastErrorCode: row.lastErrorCode,
            createdAt: row.createdAt ?? Date(),
            updatedAt: row.updatedAt ?? Date()
        )
    }
}

// MARK: - DTOs

//
// Kept local to this file rather than in StockPlanShared: that package is
// pinned `exact: "4.4.0"` in Package.swift, so a shared DTO would block the
// build until a new shared release is cut and pinned.

struct UserAIProviderCredentialCreateRequest: Content {
    let provider: String
    let label: String
    let apiKey: String
    let baseURL: String?
    let defaultModel: String?
    /// Defaults to true; the caller can skip the round trip to the provider.
    let verify: Bool?
}

/// Note the absence of an `apiKey` field. Leaking the key is made structurally
/// impossible rather than left to whoever edits this next remembering to omit it.
struct UserAIProviderCredentialSummary: Content {
    let id: UUID
    let provider: String
    let label: String
    let keyHint: String
    let baseURL: String?
    let defaultModel: String?
    let status: String
    let lastVerifiedAt: Date?
    let lastUsedAt: Date?
    let lastErrorCode: String?
    let createdAt: Date
    let updatedAt: Date
}

struct UserAIProviderCredentialListResponse: Content {
    let items: [UserAIProviderCredentialSummary]
}

struct UserAIProviderCredentialVerifyResponse: Content {
    let status: String
    let verifiedAt: Date?
    let errorCode: String?
    let detail: String
    let latencyMs: Int
}
