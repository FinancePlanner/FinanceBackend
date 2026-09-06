import Vapor

/// RFC 8414 authorization-server metadata, served at the root well-known path so
/// MCP clients can discover the OAuth endpoints.
struct WellKnownController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get(".well-known", "oauth-authorization-server", use: metadata)
    }

    func metadata(req: Request) async throws -> AuthorizationServerMetadata {
        let issuer = OAuthServerConfig.issuer(req)
        return AuthorizationServerMetadata(
            issuer: issuer,
            authorizationEndpoint: issuer + "/v1/oauth/authorize",
            tokenEndpoint: issuer + "/v1/oauth/token",
            registrationEndpoint: issuer + "/v1/oauth/register",
            revocationEndpoint: issuer + "/v1/oauth/revoke",
            scopesSupported: APIScope.grantable.map(\.rawValue),
            responseTypesSupported: ["code"],
            grantTypesSupported: ["authorization_code", "refresh_token"],
            codeChallengeMethodsSupported: ["S256"],
            tokenEndpointAuthMethodsSupported: ["none"]
        )
    }
}

struct AuthorizationServerMetadata: Content {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let registrationEndpoint: String
    let revocationEndpoint: String
    let scopesSupported: [String]
    let responseTypesSupported: [String]
    let grantTypesSupported: [String]
    let codeChallengeMethodsSupported: [String]
    let tokenEndpointAuthMethodsSupported: [String]

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case scopesSupported = "scopes_supported"
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }
}

enum OAuthServerConfig {
    /// The issuer/base URL advertised in metadata and used to build endpoint URLs.
    static func issuer(_ req: Request) -> String {
        if let configured = Environment.get("OAUTH_ISSUER_URL")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty
        {
            return configured.hasSuffix("/") ? String(configured.dropLast()) : configured
        }
        let scheme = req.headers.first(name: "X-Forwarded-Proto") ?? "https"
        let host = req.headers.first(name: .host) ?? "api.norviqa.io"
        return "\(scheme)://\(host)"
    }

    /// The web consent page the /authorize endpoint redirects the browser to.
    static func consentURL() -> String {
        Environment.get("OAUTH_CONSENT_URL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "https://norviqa.io/oauth/consent"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
