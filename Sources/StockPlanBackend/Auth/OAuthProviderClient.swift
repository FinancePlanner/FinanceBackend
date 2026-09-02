import Crypto
import Foundation
import JWT
import JWTKit
import Vapor

/// Shared across token exchanges; provider payloads are plain snake_case JSON
/// and must not go through the app-wide key strategy.
private let oauthProviderJSONDecoder = JSONDecoder()

struct OAuthAuthorizationContext {
    let state: String
    let nonce: String
    let codeChallenge: String
    let redirectURI: String
}

struct OAuthIdentityInfo {
    let providerUserID: String
    let email: String?
    let emailVerified: Bool
    let suggestedUsername: String?
}

protocol OAuthProviderClient: Sendable {
    var provider: OAuthProvider { get }
    func makeAuthorizationURL(context: OAuthAuthorizationContext) throws -> URL
    func resolveIdentity(
        code: String,
        redirectURI: String,
        codeVerifier: String,
        nonce: String,
        on req: Request
    ) async throws -> OAuthIdentityInfo
}

struct GoogleOAuthProviderClient: OAuthProviderClient {
    struct Config {
        let clientID: String
        let clientSecret: String?
        let authURL: URL
        let tokenURL: URI
        let userInfoURL: URI

        static func fromEnvironment(
            clientIDKey: String = "OAUTH_GOOGLE_CLIENT_ID",
            clientSecretKey: String = "OAUTH_GOOGLE_CLIENT_SECRET"
        ) -> Config? {
            guard let clientID = Environment.get(clientIDKey)?.trimmedNonEmpty else {
                return nil
            }
            let clientSecret = Environment.get(clientSecretKey)?.trimmedNonEmpty

            let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            let tokenURL = URI(string: "https://oauth2.googleapis.com/token")
            let userInfoURL = URI(string: "https://openidconnect.googleapis.com/v1/userinfo")
            return Config(
                clientID: clientID,
                clientSecret: clientSecret,
                authURL: authURL,
                tokenURL: tokenURL,
                userInfoURL: userInfoURL
            )
        }
    }

    private struct TokenResponse: Content {
        let accessToken: String?
        let tokenType: String?
        let expiresIn: Int?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }

    let provider: OAuthProvider = .google
    let config: Config

    func makeAuthorizationURL(context: OAuthAuthorizationContext) throws -> URL {
        guard var components = URLComponents(url: config.authURL, resolvingAgainstBaseURL: false) else {
            throw Abort(.internalServerError, reason: "Failed to create Google OAuth authorization URL")
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: context.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: context.state),
            URLQueryItem(name: "nonce", value: context.nonce),
            URLQueryItem(name: "code_challenge", value: context.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Failed to build Google OAuth authorization URL")
        }
        return url
    }

    func resolveIdentity(
        code: String,
        redirectURI: String,
        codeVerifier: String,
        nonce: String,
        on req: Request
    ) async throws -> OAuthIdentityInfo {
        var payloadFields: [(String, String)] = [
            ("client_id", config.clientID),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
        ]
        if let clientSecret = config.clientSecret {
            payloadFields.insert(("client_secret", clientSecret), at: 1)
        }
        let tokenPayload = try oauthURLFormEncoded(Dictionary(uniqueKeysWithValues: payloadFields))

        let tokenResponse = try await req.client.post(config.tokenURL) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.body = .init(string: tokenPayload)
        }

        let rawBody = oauthExtractBody(from: tokenResponse)
        guard tokenResponse.status == HTTPStatus.ok else {
            req.logger.warning("Google token exchange non-200 (\(tokenResponse.status.code)): \(rawBody)")
            throw Abort(
                .badGateway,
                reason: "Google token exchange failed (\(tokenResponse.status.code)): \(rawBody)"
            )
        }
        if let providerError = oauthDetectProviderError(in: tokenResponse, provider: "Google") {
            req.logger.warning("Google token exchange returned 200 with error body: \(rawBody)")
            throw providerError
        }

        let token: TokenResponse = try oauthDecodeProviderJSON(TokenResponse.self, from: tokenResponse, provider: "Google")
        guard let idToken = token.idToken?.trimmedNonEmpty else {
            req.logger.warning("Google token exchange 200 but missing id_token. Body: \(rawBody)")
            throw Abort(.badGateway, reason: "Google token exchange did not return id_token")
        }

        let googleKeys = try await req.application.jwt.google.keys(on: req)
        let claims: GoogleIDTokenClaims = try await oauthVerifyIDToken(
            idToken,
            using: googleKeys,
            allowedAlgorithms: ["RS256"],
            providerLabel: "Google"
        )

        guard claims.aud.contains(config.clientID) else {
            throw Abort(.unauthorized, reason: "Google id_token audience is invalid")
        }

        if let authorizedPresenter = claims.azp?.trimmedNonEmpty,
           authorizedPresenter != config.clientID
        {
            throw Abort(.unauthorized, reason: "Google id_token authorized presenter is invalid")
        }

        guard claims.nonce == nonce else {
            throw Abort(.unauthorized, reason: "Google id_token nonce mismatch")
        }

        guard let email = claims.email?.trimmedNonEmpty else {
            throw Abort(.unauthorized, reason: "Google account did not return a usable email")
        }

        let emailVerified = claims.emailVerified?.boolValue ?? false
        guard emailVerified else {
            throw Abort(.unauthorized, reason: "Google account email must be verified")
        }

        let emailPrefix = email.split(separator: "@").first.map(String.init)
        let preferredGivenName = claims.givenName?.trimmedNonEmpty
        let preferredDisplayName = claims.name?.trimmedNonEmpty
        let suggestedUsername = preferredGivenName ?? preferredDisplayName ?? emailPrefix

        return OAuthIdentityInfo(
            providerUserID: claims.sub,
            email: email.lowercased(),
            emailVerified: emailVerified,
            suggestedUsername: suggestedUsername
        )
    }
}

struct AppleOAuthProviderClient: OAuthProviderClient {
    struct Config {
        let clientID: String
        let teamID: String
        let keyID: String
        let privateKeyPEM: String
        let authURL: URL
        let tokenURL: URI

        static func fromEnvironment() -> Config? {
            guard
                let clientID = Environment.get("OAUTH_APPLE_CLIENT_ID")?.trimmedNonEmpty,
                let teamID = Environment.get("OAUTH_APPLE_TEAM_ID")?.trimmedNonEmpty,
                let keyID = Environment.get("OAUTH_APPLE_KEY_ID")?.trimmedNonEmpty,
                let privateKeyPEMRaw = Environment.get("OAUTH_APPLE_PRIVATE_KEY")?.trimmedNonEmpty
            else {
                return nil
            }

            return Config(
                clientID: clientID,
                teamID: teamID,
                keyID: keyID,
                privateKeyPEM: privateKeyPEMRaw.replacingOccurrences(of: "\\n", with: "\n"),
                authURL: URL(string: "https://appleid.apple.com/auth/authorize")!,
                tokenURL: URI(string: "https://appleid.apple.com/auth/token")
            )
        }
    }

    private struct TokenResponse: Content {
        let accessToken: String?
        let tokenType: String?
        let expiresIn: Int?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }

    private struct IDTokenClaims: JWTPayload {
        let iss: String
        let aud: StringOrArray
        let exp: Int
        let iat: Int?
        let nonce: String?
        let sub: String
        let email: String?
        let emailVerified: OAuthFlexibleBool?

        enum CodingKeys: String, CodingKey {
            case iss
            case aud
            case exp
            case iat
            case nonce
            case sub
            case email
            case emailVerified = "email_verified"
        }

        func verify(using _: some JWTAlgorithm) throws {
            guard iss == "https://appleid.apple.com" else {
                throw Abort(.unauthorized, reason: "Apple id_token issuer is invalid")
            }
            try oauthValidateStandardTimes(exp: exp, iat: iat, providerLabel: "Apple")
            guard sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw Abort(.unauthorized, reason: "Apple id_token is missing subject")
            }
        }
    }

    let provider: OAuthProvider = .apple
    let config: Config

    func makeAuthorizationURL(context: OAuthAuthorizationContext) throws -> URL {
        guard var components = URLComponents(url: config.authURL, resolvingAgainstBaseURL: false) else {
            throw Abort(.internalServerError, reason: "Failed to create Apple OAuth authorization URL")
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: context.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "scope", value: "name email"),
            URLQueryItem(name: "state", value: context.state),
            URLQueryItem(name: "nonce", value: context.nonce),
            URLQueryItem(name: "code_challenge", value: context.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Failed to build Apple OAuth authorization URL")
        }
        return url
    }

    func resolveIdentity(
        code: String,
        redirectURI: String,
        codeVerifier: String,
        nonce: String,
        on req: Request
    ) async throws -> OAuthIdentityInfo {
        let clientSecret = try makeClientSecretJWT()
        let tokenPayload = try oauthURLFormEncoded([
            "client_id": config.clientID,
            "client_secret": clientSecret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
        ])

        let tokenResponse = try await req.client.post(config.tokenURL) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.body = .init(string: tokenPayload)
        }

        let rawBody = oauthExtractBody(from: tokenResponse)
        guard tokenResponse.status == HTTPStatus.ok else {
            req.logger.warning("Apple token exchange non-200 (\(tokenResponse.status.code)): \(rawBody)")
            throw Abort(
                .badGateway,
                reason: "Apple token exchange failed (\(tokenResponse.status.code)): \(rawBody)"
            )
        }
        if let providerError = oauthDetectProviderError(in: tokenResponse, provider: "Apple") {
            req.logger.warning("Apple token exchange returned 200 with error body: \(rawBody)")
            throw providerError
        }

        let token: TokenResponse = try oauthDecodeProviderJSON(TokenResponse.self, from: tokenResponse, provider: "Apple")
        guard let idToken = token.idToken?.trimmedNonEmpty else {
            req.logger.warning("Apple token exchange 200 but missing id_token. Body: \(rawBody)")
            throw Abort(.badGateway, reason: "Apple token exchange did not return id_token")
        }

        let appleKeys = try await req.application.jwt.apple.keys(on: req)
        let claims: IDTokenClaims = try await oauthVerifyIDToken(
            idToken,
            using: appleKeys,
            allowedAlgorithms: ["RS256"],
            providerLabel: "Apple"
        )

        guard claims.aud.contains(config.clientID) else {
            throw Abort(.unauthorized, reason: "Apple id_token audience is invalid")
        }

        guard claims.nonce == nonce else {
            throw Abort(.unauthorized, reason: "Apple id_token nonce mismatch")
        }

        let normalizedEmail = claims.email?.trimmedNonEmpty?.lowercased()
        let emailVerified = claims.emailVerified?.boolValue ?? (normalizedEmail != nil)
        let suggestedUsername = normalizedEmail?.split(separator: "@").first.map(String.init)

        return OAuthIdentityInfo(
            providerUserID: claims.sub,
            email: normalizedEmail,
            emailVerified: emailVerified,
            suggestedUsername: suggestedUsername
        )
    }

    private func makeClientSecretJWT() throws -> String {
        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: config.privateKeyPEM)
        } catch {
            throw Abort(.internalServerError, reason: "Invalid OAUTH_APPLE_PRIVATE_KEY format")
        }

        let now = Int(Date().timeIntervalSince1970)
        let exp = now + (60 * 60 * 24 * 30)

        let header: [String: Any] = [
            "alg": "ES256",
            "kid": config.keyID,
            "typ": "JWT",
        ]
        let claims: [String: Any] = [
            "iss": config.teamID,
            "iat": now,
            "exp": exp,
            "aud": "https://appleid.apple.com",
            "sub": config.clientID,
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let claimsData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let signingInput = "\(base64URLEncoded(headerData)).\(base64URLEncoded(claimsData))"

        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URLEncoded(signature.rawRepresentation))"
    }
}

struct XOAuthProviderClient: OAuthProviderClient {
    struct Config {
        let clientID: String
        let clientSecret: String?
        let scopes: String
        let authURL: URL
        let tokenURL: URI
        let userInfoURL: URI

        static func fromEnvironment() -> Config? {
            guard let clientID = Environment.get("OAUTH_X_CLIENT_ID")?.trimmedNonEmpty else {
                return nil
            }

            let clientSecret = Environment.get("OAUTH_X_CLIENT_SECRET")?.trimmedNonEmpty
            let scopes = Environment.get("OAUTH_X_SCOPES")?.trimmedNonEmpty ?? "tweet.read users.read offline.access"
            return Config(
                clientID: clientID,
                clientSecret: clientSecret,
                scopes: scopes,
                authURL: URL(string: "https://twitter.com/i/oauth2/authorize")!,
                tokenURL: URI(string: "https://api.twitter.com/2/oauth2/token"),
                userInfoURL: URI(string: "https://api.twitter.com/2/users/me?user.fields=id,name,username")
            )
        }
    }

    private struct TokenResponse: Content {
        let accessToken: String?
        let tokenType: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    private struct UserEnvelope: Content {
        struct User: Content {
            let id: String
            let name: String?
            let username: String?
        }

        let data: User
    }

    let provider: OAuthProvider = .x
    let config: Config

    func makeAuthorizationURL(context: OAuthAuthorizationContext) throws -> URL {
        guard var components = URLComponents(url: config.authURL, resolvingAgainstBaseURL: false) else {
            throw Abort(.internalServerError, reason: "Failed to create X OAuth authorization URL")
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: context.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "state", value: context.state),
            URLQueryItem(name: "code_challenge", value: context.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Failed to build X OAuth authorization URL")
        }
        return url
    }

    func resolveIdentity(
        code: String,
        redirectURI: String,
        codeVerifier: String,
        nonce _: String,
        on req: Request
    ) async throws -> OAuthIdentityInfo {
        let tokenPayload = try oauthURLFormEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
            "client_id": config.clientID,
        ])

        let tokenResponse = try await req.client.post(config.tokenURL) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            if let clientSecret = config.clientSecret {
                let credentials = "\(config.clientID):\(clientSecret)"
                let encoded = Data(credentials.utf8).base64EncodedString()
                clientRequest.headers.replaceOrAdd(name: .authorization, value: "Basic \(encoded)")
            }
            clientRequest.body = .init(string: tokenPayload)
        }

        let rawTokenBody = oauthExtractBody(from: tokenResponse)
        guard tokenResponse.status == HTTPStatus.ok else {
            req.logger.warning("X token exchange non-200 (\(tokenResponse.status.code)): \(rawTokenBody)")
            throw Abort(
                .badGateway,
                reason: "X token exchange failed (\(tokenResponse.status.code)): \(rawTokenBody)"
            )
        }
        if let providerError = oauthDetectProviderError(in: tokenResponse, provider: "X") {
            req.logger.warning("X token exchange returned 200 with error body: \(rawTokenBody)")
            throw providerError
        }

        // Decode with a plain JSONDecoder to bypass the global snake_case→camelCase
        // keyDecodingStrategy, which collides with the explicit `access_token` CodingKey
        // and silently drops the token.
        let token = try oauthDecodeProviderJSON(TokenResponse.self, from: tokenResponse, provider: "X")
        guard let accessToken = token.accessToken?.trimmedNonEmpty else {
            req.logger.warning("X token exchange 200 but missing access_token. Body: \(rawTokenBody)")
            throw Abort(.badGateway, reason: "X token exchange did not return an access token")
        }

        let userResponse = try await req.client.get(config.userInfoURL) { clientRequest in
            clientRequest.headers.bearerAuthorization = .init(token: accessToken)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
        }

        guard userResponse.status == HTTPStatus.ok else {
            let rawUserBody = oauthExtractBody(from: userResponse)
            req.logger.warning("X user profile non-200 (\(userResponse.status.code)): \(rawUserBody)")
            throw Abort(
                .badGateway,
                reason: "X user profile request failed (\(userResponse.status.code)): \(rawUserBody)"
            )
        }

        let envelope = try oauthDecodeProviderJSON(UserEnvelope.self, from: userResponse, provider: "X")
        let suggestedUsername = envelope.data.username?.trimmedNonEmpty
            ?? envelope.data.name?.trimmedNonEmpty

        return OAuthIdentityInfo(
            providerUserID: envelope.data.id,
            email: nil,
            emailVerified: false,
            suggestedUsername: suggestedUsername
        )
    }
}

private enum OAuthFlexibleBool: Codable {
    case bool(Bool)
    case string(String)

    var boolValue: Bool {
        switch self {
        case let .bool(value):
            value
        case let .string(value):
            value.lowercased() == "true"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        self = try .string(container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

private struct GoogleIDTokenClaims: JWTPayload {
    let iss: String
    let aud: StringOrArray
    let exp: Int
    let iat: Int?
    let sub: String
    let nonce: String?
    let email: String?
    let emailVerified: OAuthFlexibleBool?
    let name: String?
    let givenName: String?
    let azp: String?

    enum CodingKeys: String, CodingKey {
        case iss
        case aud
        case exp
        case iat
        case sub
        case nonce
        case email
        case emailVerified = "email_verified"
        case name
        case givenName = "given_name"
        case azp
    }

    func verify(using _: some JWTAlgorithm) throws {
        let validIssuers: Set = ["accounts.google.com", "https://accounts.google.com"]
        guard validIssuers.contains(iss) else {
            throw Abort(.unauthorized, reason: "Google id_token issuer is invalid")
        }
        try oauthValidateStandardTimes(exp: exp, iat: iat, providerLabel: "Google")
        guard sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw Abort(.unauthorized, reason: "Google id_token is missing subject")
        }
    }
}

private enum StringOrArray: Codable {
    case string(String)
    case array([String])

    func contains(_ value: String) -> Bool {
        switch self {
        case let .string(raw):
            raw == value
        case let .array(values):
            values.contains(value)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            self = .string(raw)
            return
        }
        self = try .array(container.decode([String].self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(raw):
            try container.encode(raw)
        case let .array(values):
            try container.encode(values)
        }
    }
}

private func oauthValidateStandardTimes(exp: Int, iat: Int?, providerLabel: String) throws {
    let now = Date()
    let skew: TimeInterval = 300
    let expDate = Date(timeIntervalSince1970: TimeInterval(exp))
    guard expDate > now.addingTimeInterval(-skew) else {
        throw Abort(.unauthorized, reason: "\(providerLabel) id_token has expired")
    }

    if let iat {
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(iat))
        guard issuedAt <= now.addingTimeInterval(skew) else {
            throw Abort(.unauthorized, reason: "\(providerLabel) id_token issued-at is invalid")
        }
    }
}

private func oauthVerifyIDToken<Claims: JWTPayload>(
    _ token: String,
    using keys: JWTKeyCollection,
    allowedAlgorithms: Set<String>,
    providerLabel: String
) async throws -> Claims {
    try oauthValidateJWTHeader(token, allowedAlgorithms: allowedAlgorithms, providerLabel: providerLabel)
    do {
        return try await keys.verify(token, as: Claims.self, iteratingKeys: false)
    } catch let abort as Abort {
        throw abort
    } catch {
        throw Abort(.unauthorized, reason: "\(providerLabel) id_token signature verification failed")
    }
}

private func oauthValidateJWTHeader(
    _ token: String,
    allowedAlgorithms: Set<String>,
    providerLabel: String
) throws {
    let header = try oauthParseJWTHeader(token)
    let normalizedAllowedAlgorithms = Set(allowedAlgorithms.map { $0.uppercased() })

    guard let alg = header["alg"] as? String, normalizedAllowedAlgorithms.contains(alg.uppercased()) else {
        throw Abort(.unauthorized, reason: "\(providerLabel) id_token algorithm is invalid")
    }

    guard let kid = (header["kid"] as? String)?.trimmedNonEmpty, !kid.isEmpty else {
        throw Abort(.unauthorized, reason: "\(providerLabel) id_token key identifier is missing")
    }

    if let typ = (header["typ"] as? String)?.trimmedNonEmpty,
       typ.uppercased() != "JWT"
    {
        throw Abort(.unauthorized, reason: "\(providerLabel) id_token type header is invalid")
    }

    let disallowedHeaderKeys = ["jku", "jwk", "x5u", "x5c", "x5t", "x5t#s256", "crit"]
    if disallowedHeaderKeys.contains(where: { header[$0] != nil }) {
        throw Abort(.unauthorized, reason: "\(providerLabel) id_token header contains unsupported key material")
    }
}

private func oauthParseJWTHeader(_ token: String) throws -> [String: Any] {
    let segments = token.split(separator: ".")
    guard segments.count == 3 else {
        throw Abort(.unauthorized, reason: "Invalid JWT format")
    }

    let headerData = try oauthDecodeBase64URLSegment(segments[0], component: "header")
    let raw = try JSONSerialization.jsonObject(with: headerData)
    guard let header = raw as? [String: Any] else {
        throw Abort(.unauthorized, reason: "Invalid JWT header encoding")
    }

    return Dictionary(uniqueKeysWithValues: header.map { key, value in
        (key.lowercased(), value)
    })
}

private func oauthDecodeBase64URLSegment(_ segment: Substring, component: String) throws -> Data {
    var value = String(segment)
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")

    let padding = value.count % 4
    if padding > 0 {
        value += String(repeating: "=", count: 4 - padding)
    }

    guard let data = Data(base64Encoded: value) else {
        throw Abort(.unauthorized, reason: "Invalid JWT \(component) encoding")
    }
    return data
}

private func oauthURLFormEncoded(_ parameters: [String: String]) throws -> String {
    try parameters
        .map { key, value in
            let encodedKey = try oauthPercentEncode(key)
            let encodedValue = try oauthPercentEncode(value)
            return "\(encodedKey)=\(encodedValue)"
        }
        .sorted()
        .joined(separator: "&")
}

private func oauthPercentEncode(_ value: String) throws -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=?+")
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
        throw Abort(.internalServerError, reason: "Failed to percent-encode OAuth parameters")
    }
    return encoded
}

private func oauthExtractBody(from response: ClientResponse) -> String {
    response.body
        .flatMap { buffer in
            buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
        }?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private struct OAuthErrorBody: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// Bypass the global `JSONDecoder.backendAPI` custom keyDecodingStrategy that
/// converts every snake_case JSON key to camelCase before CodingKey lookup —
/// it silently breaks structs that declare explicit `case xxx = "snake_case"`
/// mappings against external OAuth provider payloads (e.g. Apple/Google
/// `id_token`, `access_token`, `error_description`).
private func oauthDecodeProviderJSON<T: Decodable>(
    _ type: T.Type,
    from response: ClientResponse,
    provider: String
) throws -> T {
    guard
        let buffer = response.body,
        let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
    else {
        throw Abort(.badGateway, reason: "\(provider) token exchange returned empty body")
    }
    do {
        return try oauthProviderJSONDecoder.decode(type, from: data)
    } catch {
        throw Abort(
            .badGateway,
            reason: "\(provider) token exchange response could not be parsed: \(error)"
        )
    }
}

private func oauthDetectProviderError(in response: ClientResponse, provider: String) -> Abort? {
    guard
        let buffer = response.body,
        let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes),
        let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data),
        let code = body.error?.trimmedNonEmpty
    else {
        return nil
    }
    let desc = body.errorDescription?.trimmedNonEmpty ?? "no description"
    return Abort(.badGateway, reason: "\(provider) token exchange returned error: \(code) — \(desc)")
}

private func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
