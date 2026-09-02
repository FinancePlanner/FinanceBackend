import Fluent
import Foundation
import Vapor

/// OAuth 2.1 authorization-server endpoints for third-party MCP clients.
///
/// Flow: client → GET /authorize (validate, create flow, 302 to web consent) →
/// web consent posts approve/deny (first-party session) → returns redirect_url
/// with code → client → POST /token (code + PKCE) → access/refresh tokens.
struct OAuthServerController: RouteCollection {
    private static let jsonDecoder = JSONDecoder()
    static let maxRedirectURIs = 5

    func boot(routes: any RoutesBuilder) throws {
        let oauth = routes.grouped("oauth")
        oauth.get("authorize", use: authorize)
        oauth.post("register", use: register)
        oauth.post("token", use: token)
        oauth.post("revoke", use: revoke)

        // Consent approval is driven by norviq-web with the user's session JWT.
        let authed = oauth.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        authed.get("flows", ":flowID", use: flowDetail)
        authed.post("flows", ":flowID", "approve", use: approve)
        authed.post("flows", ":flowID", "deny", use: deny)
    }

    // MARK: - Authorize (browser entry)

    func authorize(req: Request) async throws -> Response {
        let params = try req.query.decode(AuthorizeQuery.self)
        guard params.responseType == "code" else {
            throw Abort(.badRequest, reason: "unsupported_response_type")
        }
        guard params.codeChallengeMethod == "S256", !params.codeChallenge.isEmpty else {
            throw Abort(.badRequest, reason: "invalid_request: PKCE S256 required")
        }
        guard let client = try await OAuthClient.query(on: req.db)
            .filter(\.$clientID == params.clientID)
            .first()
        else {
            throw Abort(.badRequest, reason: "invalid_client")
        }
        guard client.redirectURIs.contains(params.redirectURI) else {
            throw Abort(.badRequest, reason: "invalid_redirect_uri")
        }
        let scopes = try APIScope.parse(params.scope?.split(separator: " ").map(String.init) ?? [])
        guard !scopes.isEmpty else {
            throw Abort(.badRequest, reason: "invalid_scope")
        }

        let flow = OAuthAuthorizationFlow(
            clientID: params.clientID,
            scopes: scopes.map(\.rawValue),
            redirectURI: params.redirectURI,
            state: params.state,
            codeChallenge: params.codeChallenge,
            expiresAt: Date().addingTimeInterval(OAuthServerService.authorizationCodeTTL)
        )
        try await flow.save(on: req.db)

        var consent = URLComponents(string: OAuthServerConfig.consentURL())!
        consent.queryItems = try [URLQueryItem(name: "flow_id", value: flow.requireID().uuidString)]
        return req.redirect(to: consent.url!.absoluteString)
    }

    // MARK: - Consent (first-party session)

    func flowDetail(req: Request) async throws -> FlowDetailResponse {
        _ = try req.auth.require(SessionToken.self)
        let flow = try await loadPendingFlow(req)
        let client = try await OAuthClient.query(on: req.db)
            .filter(\.$clientID == flow.clientID).first()
        return FlowDetailResponse(
            clientName: client?.clientName ?? flow.clientID,
            scopes: flow.scopes,
            scopeDescriptions: flow.scopes.compactMap { APIScope(rawValue: $0)?.humanDescription }
        )
    }

    func approve(req: Request) async throws -> ApproveResponse {
        let session = try req.auth.require(SessionToken.self)
        // Consent to connect an external client is a Pro feature.
        try await req.usageCounterService.requirePremium(.mcpAccess, userId: session.userId, on: req.db)

        let flow = try await loadPendingFlow(req)
        flow.userID = session.userId
        let code = try await OAuthServerService.issueAuthorizationCode(for: flow, on: req.db)

        var comps = URLComponents(string: flow.redirectURI)!
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "code", value: code))
        if let state = flow.state {
            items.append(URLQueryItem(name: "state", value: state))
        }
        comps.queryItems = items
        return ApproveResponse(redirectURL: comps.url!.absoluteString)
    }

    func deny(req: Request) async throws -> ApproveResponse {
        _ = try req.auth.require(SessionToken.self)
        let flow = try await loadPendingFlow(req)
        flow.status = "denied"
        try await flow.save(on: req.db)

        var comps = URLComponents(string: flow.redirectURI)!
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "error", value: "access_denied"))
        if let state = flow.state {
            items.append(URLQueryItem(name: "state", value: state))
        }
        comps.queryItems = items
        return ApproveResponse(redirectURL: comps.url!.absoluteString)
    }

    // MARK: - Token

    func token(req: Request) async throws -> Response {
        let body: TokenRequest = try decodeBody(req)
        switch body.grantType {
        case "authorization_code":
            return try await exchangeCode(req, body)
        case "refresh_token":
            return try await refreshGrant(req, body)
        default:
            throw Abort(.badRequest, reason: "unsupported_grant_type")
        }
    }

    private func exchangeCode(_ req: Request, _ body: TokenRequest) async throws -> Response {
        guard let code = body.code, let verifier = body.codeVerifier, let redirectURI = body.redirectURI else {
            throw Abort(.badRequest, reason: "invalid_request")
        }
        let codeHash = OpaqueToken.sha256Hex(code)
        guard let flow = try await OAuthAuthorizationFlow.query(on: req.db)
            .filter(\.$codeHash == codeHash).first()
        else {
            throw Abort(.badRequest, reason: "invalid_grant")
        }
        // Single-use: a consumed or expired code is rejected.
        guard flow.isApproved, let userID = flow.userID else {
            throw Abort(.badRequest, reason: "invalid_grant")
        }
        guard flow.clientID == body.clientID, flow.redirectURI == redirectURI else {
            throw Abort(.badRequest, reason: "invalid_grant")
        }
        guard OAuthServerService.verifyPKCE(codeVerifier: verifier, challenge: flow.codeChallenge) else {
            throw Abort(.badRequest, reason: "invalid_grant: PKCE verification failed")
        }

        flow.status = "consumed"
        try await flow.save(on: req.db)

        let issued = try await OAuthServerService.issueTokens(
            clientID: flow.clientID, userID: userID, scopes: flow.scopes, on: req.db
        )
        return try await tokenResponse(issued, on: req)
    }

    private func refreshGrant(_ req: Request, _ body: TokenRequest) async throws -> Response {
        guard let refresh = body.refreshToken else {
            throw Abort(.badRequest, reason: "invalid_request")
        }
        let requested = body.scope?.split(separator: " ").map(String.init)
        guard let issued = try await OAuthServerService.rotateRefreshToken(
            rawRefreshToken: refresh, requestedScopes: requested, on: req.db
        ) else {
            throw Abort(.badRequest, reason: "invalid_grant")
        }
        return try await tokenResponse(issued, on: req)
    }

    private func tokenResponse(_ issued: OAuthServerService.IssuedTokens, on _: Request) async throws -> Response {
        let payload = TokenResponse(
            accessToken: issued.accessToken,
            tokenType: "Bearer",
            expiresIn: issued.accessExpiresIn,
            refreshToken: issued.refreshToken,
            scope: issued.scopes.joined(separator: " ")
        )
        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        try res.content.encode(payload)
        return res
    }

    // MARK: - Dynamic client registration (RFC 7591)

    func register(req: Request) async throws -> Response {
        let body: RegisterRequest = try decodeBody(req)
        guard !body.redirectURIs.isEmpty, body.redirectURIs.count <= Self.maxRedirectURIs else {
            throw Abort(.badRequest, reason: "invalid_redirect_uri")
        }
        for uri in body.redirectURIs {
            guard isAllowedRedirectURI(uri) else {
                throw Abort(.badRequest, reason: "invalid_redirect_uri: must be https or loopback")
            }
        }
        let clientID = OpaqueToken.generate(prefix: "nvq_client_", byteCount: 16)
        let client = OAuthClient(
            clientID: clientID,
            clientName: body.clientName ?? "MCP client",
            redirectURIs: body.redirectURIs
        )
        try await client.save(on: req.db)

        let res = Response(status: .created)
        try res.content.encode(RegisterResponse(
            clientID: clientID,
            clientName: client.clientName,
            redirectURIs: client.redirectURIs,
            tokenEndpointAuthMethod: "none"
        ))
        return res
    }

    private func isAllowedRedirectURI(_ uri: String) -> Bool {
        guard let url = URL(string: uri), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" {
            return true
        }
        // Allow http only for loopback (native clients per RFC 8252).
        if scheme == "http", let host = url.host, host == "127.0.0.1" || host == "localhost" || host == "[::1]" {
            return true
        }
        // Custom app schemes (e.g. cursor://) are permitted for native clients.
        return scheme != "http"
    }

    // MARK: - Revoke

    func revoke(req: Request) async throws -> HTTPStatus {
        let body: RevokeRequest = try decodeBody(req)
        let hash = OpaqueToken.sha256Hex(body.token)
        // Match on access or refresh hash; revoke silently either way (RFC 7009).
        if let token = try await OAuthToken.query(on: req.db)
            .group(.or, { group in
                group.filter(\.$accessTokenHash == hash)
                group.filter(\.$refreshTokenHash == hash)
            })
            .first(), token.revokedAt == nil
        {
            token.revokedAt = Date()
            try await token.save(on: req.db)
        }
        return .ok
    }

    // MARK: - Helpers

    /// Decodes an OAuth request body honoring the spec-mandated snake_case field
    /// names. Form-encoded bodies (RFC 6749 /token) use Vapor's form decoder,
    /// which respects CodingKeys; JSON bodies use a plain JSONDecoder to bypass
    /// the app's snake→camel normalizing decoder.
    private func decodeBody<T: Content>(_ req: Request) throws -> T {
        if req.headers.contentType == .urlEncodedForm {
            return try req.content.decode(T.self)
        }
        guard let buffer = req.body.data else {
            throw Abort(.badRequest, reason: "invalid_request: missing body")
        }
        return try Self.jsonDecoder.decode(T.self, from: Data(buffer: buffer))
    }

    private func loadPendingFlow(_ req: Request) async throws -> OAuthAuthorizationFlow {
        guard let flowID = req.parameters.get("flowID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "invalid_request")
        }
        guard let flow = try await OAuthAuthorizationFlow.find(flowID, on: req.db) else {
            throw Abort(.notFound, reason: "flow_not_found")
        }
        guard flow.isPending else {
            throw Abort(.badRequest, reason: "flow_not_pending")
        }
        return flow
    }
}

// MARK: - DTOs

struct AuthorizeQuery: Content {
    let responseType: String
    let clientID: String
    let redirectURI: String
    let scope: String?
    let state: String?
    let codeChallenge: String
    let codeChallengeMethod: String

    enum CodingKeys: String, CodingKey {
        case responseType = "response_type"
        case clientID = "client_id"
        case redirectURI = "redirect_uri"
        case scope
        case state
        case codeChallenge = "code_challenge"
        case codeChallengeMethod = "code_challenge_method"
    }
}

struct FlowDetailResponse: Content {
    let clientName: String
    let scopes: [String]
    let scopeDescriptions: [String]
}

struct ApproveResponse: Content {
    let redirectURL: String
    enum CodingKeys: String, CodingKey { case redirectURL = "redirect_url" }
}

struct TokenRequest: Content {
    let grantType: String
    let code: String?
    let redirectURI: String?
    let clientID: String?
    let codeVerifier: String?
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case code
        case redirectURI = "redirect_uri"
        case clientID = "client_id"
        case codeVerifier = "code_verifier"
        case refreshToken = "refresh_token"
        case scope
    }
}

struct TokenResponse: Content {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

struct RegisterRequest: Content {
    let clientName: String?
    let redirectURIs: [String]

    enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case redirectURIs = "redirect_uris"
    }
}

struct RegisterResponse: Content {
    let clientID: String
    let clientName: String
    let redirectURIs: [String]
    let tokenEndpointAuthMethod: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientName = "client_name"
        case redirectURIs = "redirect_uris"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
    }
}

struct RevokeRequest: Content {
    let token: String
}
