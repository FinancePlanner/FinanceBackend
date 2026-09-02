import Crypto
import Fluent
import Foundation
import JWT
import StockPlanShared
import Vapor

enum AuthMFAPurpose: String {
    case login
    case oauth
}

struct AuthMFAConfig {
    let enabled: Bool
    let allowLegacyBypass: Bool
    let codeTTLSeconds: Int
    let maxVerifyAttempts: Int
    let resendCooldownSeconds: Int
    let maxResends: Int
    let bypassEmails: Set<String>

    static let `default` = AuthMFAConfig(
        enabled: false,
        allowLegacyBypass: true,
        codeTTLSeconds: 300,
        maxVerifyAttempts: 5,
        resendCooldownSeconds: 30,
        maxResends: 3,
        bypassEmails: []
    )
}

/// TestFlight bypass: allows a hardcoded test account to skip email sending and use a fixed OTP.
/// Enabled only when `TESTFLIGHT_BYPASS_ENABLED=true` and the environment is NOT production.
enum TestFlightBypass {
    static let email = "test@stockplan.app"
    static let magicCode = "123456"

    static func isEnabled(on app: Application) -> Bool {
        guard app.environment != .production else { return false }
        return (Environment.get("TESTFLIGHT_BYPASS_ENABLED") ?? "false").lowercased() == "true"
    }

    static func applies(to email: String, on app: Application) -> Bool {
        isEnabled(on: app) && email.lowercased() == Self.email
    }
}

protocol AuthService: Sendable {
    var mfaConfig: AuthMFAConfig { get }

    func register(
        username: String,
        email: String,
        password: String,
        confirmPassword: String,
        dateOfBirth: Date,
        trialDays: Int?,
        couponCode: String?,
        on req: Request
    ) async throws -> AuthResponse
    func login(email: String, password: String, requireMFA: Bool, on req: Request) async throws -> AuthLoginOutcome
    func currentUser(from req: Request) async throws -> AuthUserResponse
    func forgotPassword(email: String, on req: Request) async throws -> AuthForgotPasswordResponse
    func resendResetCode(email: String, on req: Request) async throws -> AuthForgotPasswordResponse
    func resetPassword(email: String, code: String, newPassword: String, on req: Request)
        async throws -> HTTPStatus
    func refresh(using refreshToken: String, on req: Request) async throws -> AuthResponse
    func oauthStart(provider: OAuthProvider, redirectURI: String, on req: Request) async throws
        -> OAuthStartResponse
    func oauthLinkStart(provider: OAuthProvider, redirectURI: String, on req: Request) async throws
        -> OAuthStartResponse
    func oauthExchange(
        provider: OAuthProvider,
        flowId: UUID,
        code: String,
        state: String,
        redirectURI: String,
        on req: Request
    ) async throws -> AuthLoginOutcome
    func oauthLinkedAccounts(on req: Request) async throws -> OAuthLinkedAccountsResponse
    func oauthLinkExchange(
        provider: OAuthProvider,
        flowId: UUID,
        code: String,
        state: String,
        redirectURI: String,
        on req: Request
    ) async throws -> OAuthLinkResponse
    func verifyMFA(challengeId: UUID, code: String, on req: Request) async throws -> AuthResponse
    func resendMFA(challengeId: UUID, on req: Request) async throws -> AuthMFAChallengeResponse
    func authResponse(for user: User, on req: Request) async throws -> AuthResponse
}

// swiftlint:disable type_body_length
struct DefaultAuthService: AuthService {
    private static let passwordResetMaxAttempts = 5
    private static let passwordResetLockSeconds: TimeInterval = 15 * 60
    private static let passwordResetIssueWindowSeconds: TimeInterval = 5 * 60
    private static let passwordResetMaxIssuesPerWindow = 3

    let repo: any AuthRepository
    let oauthProviders: [OAuthProvider: any OAuthProviderClient]
    let oauthWebProviders: [OAuthProvider: any OAuthProviderClient]
    let mfaConfig: AuthMFAConfig
    let trialService: any TrialServicing

    init(
        repo: any AuthRepository,
        oauthProviders: [OAuthProvider: any OAuthProviderClient] = [:],
        oauthWebProviders: [OAuthProvider: any OAuthProviderClient] = [:],
        mfaConfig: AuthMFAConfig = .default,
        trialService: any TrialServicing = TrialService()
    ) {
        self.repo = repo
        self.oauthProviders = oauthProviders
        self.oauthWebProviders = oauthWebProviders
        self.mfaConfig = mfaConfig
        self.trialService = trialService
    }

    func register(
        username: String,
        email: String,
        password: String,
        confirmPassword: String,
        dateOfBirth: Date,
        trialDays _: Int?,
        couponCode _: String?,
        on req: Request
    ) async throws -> AuthResponse {
        let normalizedUsername = normalizeUsername(username)
        let normalizedEmail = normalizeEmail(email)

        guard password == confirmPassword else {
            throw Abort(.badRequest, reason: "Password and confirm password do not match")
        }

        try validateUsername(normalizedUsername)
        try validateEmail(normalizedEmail)
        try validatePassword(password)
        try validateDateOfBirth(dateOfBirth)

        if try await repo.findUser(username: normalizedUsername, on: req.db) != nil {
            throw Abort(.conflict, reason: "Username already registered")
        }

        if try await repo.findUser(email: normalizedEmail, on: req.db) != nil {
            throw Abort(.conflict, reason: "Email already registered")
        }

        let hash = try await req.password.async.hash(password).get()
        let user: User
        do {
            user = try await repo.createUser(
                username: normalizedUsername,
                email: normalizedEmail,
                passwordHash: hash,
                dateOfBirth: dateOfBirth,
                on: req.db
            )
        } catch {
            req.logger.error("auth.register create_user_failed error_type=\(String(reflecting: type(of: error)))")
            throw error
        }

        try await initializeDefaultTrialIfNeeded(for: user, on: req)

        Task {
            try? await req.discord.send("🎉 New user registered: \(normalizedEmail)", on: req)
        }

        return try await makeAuthResponse(for: user, on: req)
    }

    private func defaultTrialDays(on req: Request) -> Int {
        let configured = Environment.get("AUTH_DEFAULT_TRIAL_DAYS").flatMap(Int.init(_:)) ?? 7
        if configured <= 0 {
            req.logger.warning("auth.register invalid_default_trial_days=\(configured); using 7")
            return 7
        }
        return min(max(configured, 7), 14)
    }

    private func initializeDefaultTrialIfNeeded(for user: User, on req: Request) async throws {
        guard !user.hadTrial else { return }

        try await trialService.initializeTrial(
            user: user,
            trialDays: defaultTrialDays(on: req),
            tierName: "temporary",
            db: req.db
        )
    }

    func login(email: String, password: String, requireMFA: Bool, on req: Request) async throws -> AuthLoginOutcome {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)
        try validatePassword(password)

        guard let user = try await repo.findUser(email: normalizedEmail, on: req.db) else {
            _ = try? await req.password.async.hash(password).get()
            throw Abort(.unauthorized, reason: "Invalid email or password")
        }

        // 1. Check if the account is currently locked
        if let lockoutUntil = user.lockoutUntil, lockoutUntil > Date() {
            let timeRemaining = Int(lockoutUntil.timeIntervalSince(Date()) / 60)
            let message = timeRemaining > 0
                ? "Account is temporarily locked due to multiple failed login attempts. Please try again in \(timeRemaining) minute(s)."
                : "Account is temporarily locked due to multiple failed login attempts. Please try again shortly."
            throw Abort(.forbidden, reason: message)
        }

        let isValid = try await req.password.async.verify(password, created: user.passwordHash).get()

        if !isValid {
            // 2. Increment failed attempts and lock if necessary
            user.failedLoginAttempts += 1
            if user.failedLoginAttempts >= 5 {
                let lockoutUntil = Date().addingTimeInterval(15 * 60)
                user.lockoutUntil = lockoutUntil
                req.logger.warning(
                    "auth.login account_locked user_id=\(user.id?.uuidString ?? "unknown") until=\(lockoutUntil)"
                )
            }
            try await persistUser(user, on: req)
            throw Abort(.unauthorized, reason: "Invalid email or password")
        }

        // 3. Reset failed attempts on successful login
        if user.failedLoginAttempts > 0 || user.lockoutUntil != nil {
            user.failedLoginAttempts = 0
            user.lockoutUntil = nil
            try await persistUser(user, on: req)
        }

        // 4. Check for email verification
        if !user.isVerified {
            // Note: For now, we allow login but might restrict certain features later,
            // or enforce it strictly here if the client is ready for the verification flow.
            // req.logger.info("User \(user.email) logged in but is not verified.")
            // throw Abort(.forbidden, reason: "Please verify your email address before logging in.")
        }

        if requiresMFA(requireMFA, for: user) {
            let challenge = try await issueMFAChallenge(user: user, purpose: .login, channel: .email, on: req)
            req.logger.info("auth.mfa challenge_issued purpose=login user_id=\(user.id?.uuidString ?? "unknown")")
            return .mfaRequired(challenge)
        }

        return try await .authenticated(makeAuthResponse(for: user, on: req))
    }

    func currentUser(from req: Request) async throws -> AuthUserResponse {
        let token = try req.auth.require(SessionToken.self)
        guard let user = try await repo.findUser(id: token.userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }
        return AuthUserResponse(
            id: user.id?.uuidString ?? "",
            username: responseUsername(for: user),
            email: user.email,
            dateOfBirth: responseDateOfBirth(for: user)
        )
    }

    func forgotPassword(email: String, on req: Request) async throws -> AuthForgotPasswordResponse {
        try await issueResetCode(email: email, on: req)
    }

    func resendResetCode(email: String, on req: Request) async throws -> AuthForgotPasswordResponse {
        try await issueResetCode(email: email, on: req)
    }

    func resetPassword(email: String, code: String, newPassword: String, on req: Request)
        async throws -> HTTPStatus
    {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)
        try validatePassword(newPassword)

        guard let user = try await repo.findUser(email: normalizedEmail, on: req.db),
              let userId = user.id
        else {
            throw Abort(.unauthorized, reason: "Invalid reset code")
        }

        let now = Date()
        guard let resetToken = try await repo.findLatestActivePasswordResetToken(userId: userId, now: now, on: req.db)
        else {
            throw Abort(.unauthorized, reason: "Invalid reset code")
        }

        if let lockedUntil = resetToken.lockedUntil, lockedUntil > now {
            throw Abort(.tooManyRequests, reason: "Too many reset attempts. Please request a new code later.")
        }

        guard resetToken.codeHash == hashToken(code) else {
            resetToken.failedAttempts += 1
            if resetToken.failedAttempts >= Self.passwordResetMaxAttempts {
                resetToken.lockedUntil = now.addingTimeInterval(Self.passwordResetLockSeconds)
                resetToken.usedAt = now
            }
            try await repo.savePasswordResetToken(resetToken, on: req.db)
            throw Abort(.unauthorized, reason: "Invalid reset code")
        }

        user.passwordHash = try await req.password.async.hash(newPassword).get()
        try await persistUser(user, on: req)
        try await repo.markPasswordResetTokenUsed(resetToken, usedAt: now, on: req.db)

        return .noContent
    }

    func refresh(using refreshToken: String, on req: Request) async throws -> AuthResponse {
        let tokenHash = hashToken(refreshToken)
        let now = Date()

        guard
            let storedToken = try await repo.findValidRefreshToken(
                tokenHash: tokenHash, now: now, on: req.db
            )
        else {
            throw Abort(.unauthorized, reason: "Invalid refresh token")
        }

        guard let user = try await repo.findUser(id: storedToken.userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }

        try await repo.revokeRefreshToken(storedToken, revokedAt: now, on: req.db)
        return try await makeAuthResponse(for: user, on: req)
    }

    func oauthStart(provider: OAuthProvider, redirectURI: String, on req: Request) async throws
        -> OAuthStartResponse
    {
        try await makeOAuthStartResponse(
            provider: provider,
            redirectURI: redirectURI,
            purpose: .login,
            userId: nil,
            on: req
        )
    }

    func oauthLinkStart(provider: OAuthProvider, redirectURI: String, on req: Request) async throws
        -> OAuthStartResponse
    {
        let token = try req.auth.require(SessionToken.self)
        return try await makeOAuthStartResponse(
            provider: provider,
            redirectURI: redirectURI,
            purpose: .link,
            userId: token.userId,
            on: req
        )
    }

    private func makeOAuthStartResponse(
        provider: OAuthProvider,
        redirectURI: String,
        purpose: OAuthFlowPurpose,
        userId: UUID?,
        on req: Request
    ) async throws -> OAuthStartResponse {
        let normalizedRedirectURI = try normalizeRedirectURI(redirectURI)
        try validateRedirectURI(normalizedRedirectURI, app: req.application)

        let oauthProvider = try oauthProviderClient(for: provider, redirectURI: normalizedRedirectURI)
        let state = randomURLSafeString(length: 32)
        let nonce = randomURLSafeString(length: 32)
        let codeVerifier = randomURLSafeString(length: 64)
        let codeChallenge = codeChallenge(for: codeVerifier)

        let authorizationURL = try oauthProvider.makeAuthorizationURL(
            context: OAuthAuthorizationContext(
                state: state,
                nonce: nonce,
                codeChallenge: codeChallenge,
                redirectURI: normalizedRedirectURI
            )
        )

        let expiresIn = 600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let flow = try await repo.createOAuthFlow(
            OAuthFlowDraft(
                provider: provider.rawValue,
                state: state,
                nonce: nonce,
                codeVerifier: codeVerifier,
                redirectURI: normalizedRedirectURI,
                purpose: purpose.rawValue,
                userId: userId,
                expiresAt: expiresAt
            ),
            on: req.db
        )

        guard let flowID = flow.id else {
            throw Abort(.internalServerError, reason: "OAuth flow id missing")
        }

        return OAuthStartResponse(
            flowId: flowID,
            authorizationURL: authorizationURL.absoluteString,
            expiresIn: expiresIn
        )
    }

    func oauthExchange(
        provider: OAuthProvider,
        flowId: UUID,
        code: String,
        state: String,
        redirectURI: String,
        on req: Request
    ) async throws -> AuthLoginOutcome {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedState = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRedirectURI = try normalizeRedirectURI(redirectURI)
        let oauthProvider = try oauthProviderClient(for: provider, redirectURI: normalizedRedirectURI)

        guard !normalizedCode.isEmpty else {
            throw Abort(.badRequest, reason: "OAuth authorization code is required")
        }
        guard !normalizedState.isEmpty else {
            throw Abort(.badRequest, reason: "OAuth state is required")
        }

        let now = Date()
        guard
            let flow = try await repo.findValidOAuthFlow(
                id: flowId,
                provider: provider.rawValue,
                now: now,
                on: req.db
            )
        else {
            throw Abort(.unauthorized, reason: "OAuth flow is invalid or expired")
        }

        guard flow.state == normalizedState else {
            throw Abort(.unauthorized, reason: "OAuth state mismatch")
        }

        guard flow.redirectURI == normalizedRedirectURI else {
            throw Abort(.unauthorized, reason: "OAuth redirect URI mismatch")
        }
        guard flow.purpose == OAuthFlowPurpose.login.rawValue else {
            throw Abort(.unauthorized, reason: "OAuth flow is not valid for sign in")
        }

        let identityInfo = try await oauthProvider.resolveIdentity(
            code: normalizedCode,
            redirectURI: normalizedRedirectURI,
            codeVerifier: flow.codeVerifier,
            nonce: flow.nonce,
            on: req
        )

        try await repo.markOAuthFlowUsed(flow, usedAt: now, on: req.db)

        if let existingIdentity = try await repo.findOAuthIdentity(
            provider: provider.rawValue,
            providerUserID: identityInfo.providerUserID,
            on: req.db
        ) {
            let userId = existingIdentity.$user.id
            guard let user = try await repo.findUser(id: userId, on: req.db) else {
                throw Abort(.unauthorized, reason: "OAuth identity user not found")
            }
            return try await .authenticated(makeAuthResponse(for: user, on: req))
        }

        let normalizedIdentityEmail = identityInfo.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedIdentityEmail,
           let existingUser = try await repo.findUser(email: normalizedIdentityEmail, on: req.db)
        {
            guard identityInfo.emailVerified else {
                throw Abort(.conflict, reason: "ACCOUNT_EXISTS_LINK_REQUIRED")
            }

            _ = try await createOAuthIdentity(
                for: existingUser,
                provider: provider,
                identityInfo: identityInfo,
                email: normalizedIdentityEmail,
                on: req
            )
            req.logger.info(
                "auth.oauth linked_existing_user provider=\(provider.rawValue) user_id=\(existingUser.id?.uuidString ?? "unknown")"
            )

            return try await .authenticated(makeAuthResponse(for: existingUser, on: req))
        } else if normalizedIdentityEmail != nil, !identityInfo.emailVerified {
            throw Abort(.conflict, reason: "ACCOUNT_EXISTS_LINK_REQUIRED")
        }
        let resolvedUserEmail =
            normalizedIdentityEmail
                ?? syntheticOAuthEmail(provider: provider, providerUserID: identityInfo.providerUserID)

        let oauthUsername = try await generateOAuthUsername(
            suggestedUsername: identityInfo.suggestedUsername,
            email: resolvedUserEmail,
            on: req
        )
        let oauthPassword = randomURLSafeString(length: 48)
        let oauthPasswordHash = try await req.password.async.hash(oauthPassword).get()

        let user = try await repo.createUser(
            username: oauthUsername,
            email: resolvedUserEmail,
            passwordHash: oauthPasswordHash,
            dateOfBirth: defaultDateOfBirth(),
            on: req.db
        )
        try await initializeDefaultTrialIfNeeded(for: user, on: req)

        Task {
            try? await req.discord.send("🎉 New user registered via OAuth: \(resolvedUserEmail)", on: req)
        }

        _ = try await createOAuthIdentity(
            for: user,
            provider: provider,
            identityInfo: identityInfo,
            email: normalizedIdentityEmail,
            on: req
        )

        return try await .authenticated(makeAuthResponse(for: user, on: req))
    }

    func oauthLinkedAccounts(on req: Request) async throws -> OAuthLinkedAccountsResponse {
        let token = try req.auth.require(SessionToken.self)
        let identities = try await repo.listOAuthIdentities(userId: token.userId, on: req.db)
        let accounts: [OAuthLinkedAccount] = [OAuthProvider.apple, .google, .x].map { provider in
            if let identity = identities.first(where: { $0.provider == provider.rawValue }) {
                return OAuthLinkedAccount(
                    provider: provider,
                    connected: true,
                    email: identity.email,
                    emailVerified: identity.emailVerified,
                    connectedAt: identity.createdAt
                )
            }
            return OAuthLinkedAccount(provider: provider, connected: false)
        }
        return OAuthLinkedAccountsResponse(accounts: accounts)
    }

    func oauthLinkExchange(
        provider: OAuthProvider,
        flowId: UUID,
        code: String,
        state: String,
        redirectURI: String,
        on req: Request
    ) async throws -> OAuthLinkResponse {
        let token = try req.auth.require(SessionToken.self)
        guard let user = try await repo.findUser(id: token.userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }

        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedState = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRedirectURI = try normalizeRedirectURI(redirectURI)
        let oauthProvider = try oauthProviderClient(for: provider, redirectURI: normalizedRedirectURI)

        guard !normalizedCode.isEmpty else {
            throw Abort(.badRequest, reason: "OAuth authorization code is required")
        }
        guard !normalizedState.isEmpty else {
            throw Abort(.badRequest, reason: "OAuth state is required")
        }

        let now = Date()
        guard let flow = try await repo.findValidOAuthFlow(
            id: flowId,
            provider: provider.rawValue,
            now: now,
            on: req.db
        ) else {
            throw Abort(.unauthorized, reason: "OAuth flow is invalid or expired")
        }

        guard flow.state == normalizedState else {
            throw Abort(.unauthorized, reason: "OAuth state mismatch")
        }
        guard flow.redirectURI == normalizedRedirectURI else {
            throw Abort(.unauthorized, reason: "OAuth redirect URI mismatch")
        }
        guard flow.purpose == OAuthFlowPurpose.link.rawValue, flow.userId == token.userId else {
            throw Abort(.unauthorized, reason: "OAuth flow is not valid for this account")
        }

        let identityInfo = try await oauthProvider.resolveIdentity(
            code: normalizedCode,
            redirectURI: normalizedRedirectURI,
            codeVerifier: flow.codeVerifier,
            nonce: flow.nonce,
            on: req
        )

        try await repo.markOAuthFlowUsed(flow, usedAt: now, on: req.db)

        let normalizedIdentityEmail = identityInfo.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedIdentityEmail, !normalizedIdentityEmail.isEmpty else {
            throw Abort(.conflict, reason: "Provider did not return a verified email for linking")
        }
        guard identityInfo.emailVerified else {
            throw Abort(.conflict, reason: "Provider email is not verified")
        }
        guard normalizedIdentityEmail == normalizeEmail(user.email) else {
            throw Abort(.conflict, reason: "Provider email must match your account email")
        }

        if let existingIdentity = try await repo.findOAuthIdentity(
            provider: provider.rawValue,
            providerUserID: identityInfo.providerUserID,
            on: req.db
        ) {
            guard existingIdentity.$user.id == token.userId else {
                throw Abort(.conflict, reason: "Provider identity is already linked to a different account")
            }
            return OAuthLinkResponse(
                provider: provider,
                connected: true,
                email: normalizedIdentityEmail,
                message: "Connected account is already linked."
            )
        }

        if let providerIdentity = try await repo.findOAuthIdentity(
            userId: token.userId,
            provider: provider.rawValue,
            on: req.db
        ) {
            if providerIdentity.providerUserID != identityInfo.providerUserID {
                throw Abort(.conflict, reason: "Your account already has a different identity for this provider")
            }
        }

        _ = try await createOAuthIdentity(
            for: user,
            provider: provider,
            identityInfo: identityInfo,
            email: normalizedIdentityEmail,
            on: req
        )

        return OAuthLinkResponse(
            provider: provider,
            connected: true,
            email: normalizedIdentityEmail,
            message: "Connected account linked."
        )
    }

    func verifyMFA(challengeId: UUID, code: String, on req: Request) async throws -> AuthResponse {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCode.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Invalid verification code format.")
        }

        let now = Date()
        guard let challenge = try await repo.findMFAChallenge(id: challengeId, on: req.db) else {
            throw Abort(.unauthorized, reason: "Invalid or expired verification challenge.")
        }

        try validateActiveMFAChallenge(challenge, now: now)

        guard challenge.failedAttempts < mfaConfig.maxVerifyAttempts else {
            throw Abort(.unauthorized, reason: "Too many invalid verification attempts.")
        }

        let codeHash = hashToken(normalizedCode)
        let isBypassCode = TestFlightBypass.applies(to: challenge.destination, on: req.application)
            && normalizedCode == TestFlightBypass.magicCode
        guard isBypassCode || challenge.codeHash == codeHash else {
            challenge.failedAttempts += 1
            if challenge.failedAttempts >= mfaConfig.maxVerifyAttempts {
                challenge.consumedAt = now
            }
            try await repo.saveMFAChallenge(challenge, on: req.db)
            req.logger.warning("auth.mfa verify_failed challenge_id=\(challengeId.uuidString) attempts=\(challenge.failedAttempts)")
            throw Abort(.unauthorized, reason: "Invalid verification code.")
        }

        challenge.consumedAt = now
        try await repo.saveMFAChallenge(challenge, on: req.db)
        req.logger.info("auth.mfa verify_succeeded challenge_id=\(challengeId.uuidString)")

        guard let user = try await repo.findUser(id: challenge.userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found.")
        }

        return try await makeAuthResponse(for: user, on: req)
    }

    func authResponse(for user: User, on req: Request) async throws -> AuthResponse {
        try await makeAuthResponse(for: user, on: req)
    }

    func resendMFA(challengeId: UUID, on req: Request) async throws -> AuthMFAChallengeResponse {
        let now = Date()
        guard let challenge = try await repo.findMFAChallenge(id: challengeId, on: req.db) else {
            throw Abort(.unauthorized, reason: "Invalid or expired verification challenge.")
        }
        try validateActiveMFAChallenge(challenge, now: now)

        guard challenge.resendCount < mfaConfig.maxResends else {
            throw Abort(.tooManyRequests, reason: "Maximum resend attempts reached.")
        }

        let nextAllowed = challenge.lastSentAt.addingTimeInterval(TimeInterval(mfaConfig.resendCooldownSeconds))
        if now < nextAllowed {
            throw Abort(.tooManyRequests, reason: "Please wait before requesting another verification code.")
        }

        let newCode = generateMFACode()
        challenge.codeHash = hashToken(newCode)
        challenge.expiresAt = now.addingTimeInterval(TimeInterval(mfaConfig.codeTTLSeconds))
        challenge.resendCount += 1
        challenge.lastSentAt = now
        challenge.failedAttempts = 0
        try await repo.saveMFAChallenge(challenge, on: req.db)
        req.logger.info("auth.mfa resent challenge_id=\(challengeId.uuidString) resend_count=\(challenge.resendCount)")

        try await sendMFACodeEmail(
            to: challenge.destination,
            code: newCode,
            challengeId: challengeId,
            purpose: AuthMFAPurpose(rawValue: challenge.purpose) ?? .login,
            on: req
        )

        return try makeMFAChallengeResponse(from: challenge, now: now)
    }

    // MARK: - Internals

    private func createOAuthIdentity(
        for user: User,
        provider: OAuthProvider,
        identityInfo: OAuthIdentityInfo,
        email: String?,
        on req: Request
    ) async throws -> OAuthIdentity {
        guard let userID = user.id else {
            throw Abort(.internalServerError, reason: "User id missing for OAuth identity")
        }

        return try await repo.createOAuthIdentity(
            userId: userID,
            provider: provider.rawValue,
            providerUserID: identityInfo.providerUserID,
            email: email,
            emailVerified: identityInfo.emailVerified,
            on: req.db
        )
    }

    private func requiresMFA(_ requested: Bool, for user: User) -> Bool {
        requested && !mfaConfig.bypassEmails.contains(normalizeEmail(user.email))
    }

    private func makeAuthResponse(for user: User, on req: Request) async throws -> AuthResponse {
        guard let userId = user.id else {
            throw Abort(.internalServerError, reason: "User id missing")
        }

        let expiresIn = jwtExpiresInSeconds(from: req)
        let expiration = ExpirationClaim(value: Date().addingTimeInterval(TimeInterval(expiresIn)))
        let payload = SessionToken(userId: userId, exp: expiration)
        let token = try await req.jwt.sign(payload)

        let (refresh, refreshExpiresIn) = try await issueRefreshToken(userId: userId, on: req)

        return AuthResponse(
            token: token,
            userId: userId,
            expiresIn: expiresIn,
            refreshToken: refresh,
            refreshExpiresIn: refreshExpiresIn,
            username: responseUsername(for: user),
            email: user.email,
            dateOfBirth: responseDateOfBirth(for: user)
        )
    }

    private func issueMFAChallenge(
        user: User,
        purpose: AuthMFAPurpose,
        channel: AuthMFAChannel,
        on req: Request
    ) async throws -> AuthMFAChallengeResponse {
        guard let userID = user.id else {
            throw Abort(.internalServerError, reason: "User id missing")
        }

        let destination: String
        switch channel {
        case .email:
            destination = normalizeEmail(user.email)
        case .sms:
            throw Abort(.badRequest, reason: "SMS MFA is not enabled in this phase.")
        }

        let now = Date()
        try await repo.invalidateActiveMFAChallenges(
            userId: userID,
            purpose: purpose.rawValue,
            consumedAt: now,
            on: req.db
        )

        let code = generateMFACode()
        let challenge = try await repo.createMFAChallenge(
            userId: userID,
            purpose: purpose.rawValue,
            channel: channel.rawValue,
            destination: destination,
            codeHash: hashToken(code),
            expiresAt: now.addingTimeInterval(TimeInterval(mfaConfig.codeTTLSeconds)),
            lastSentAt: now,
            on: req.db
        )

        if !TestFlightBypass.applies(to: destination, on: req.application) {
            try await sendMFACodeEmail(
                to: destination,
                code: code,
                challengeId: challenge.id,
                purpose: purpose,
                on: req
            )
        }
        return try makeMFAChallengeResponse(from: challenge, now: now)
    }

    private func validateActiveMFAChallenge(_ challenge: MFAChallenge, now: Date) throws {
        guard challenge.consumedAt == nil else {
            throw Abort(.unauthorized, reason: "Verification challenge is no longer valid.")
        }
        guard challenge.expiresAt > now else {
            throw Abort(.unauthorized, reason: "Verification challenge expired.")
        }
    }

    private func makeMFAChallengeResponse(from challenge: MFAChallenge, now: Date) throws -> AuthMFAChallengeResponse {
        guard let challengeID = challenge.id else {
            throw Abort(.internalServerError, reason: "MFA challenge id missing.")
        }
        let channel = AuthMFAChannel(rawValue: challenge.channel) ?? .email
        let availableAt = challenge.lastSentAt.addingTimeInterval(TimeInterval(mfaConfig.resendCooldownSeconds))
        let resendAvailableIn = max(0, Int(ceil(availableAt.timeIntervalSince(now))))

        return AuthMFAChallengeResponse(
            challengeId: challengeID,
            channel: channel,
            maskedDestination: maskDestination(challenge.destination, channel: channel),
            expiresIn: max(0, Int(ceil(challenge.expiresAt.timeIntervalSince(now)))),
            resendAvailableIn: resendAvailableIn
        )
    }

    private func sendMFACodeEmail(
        to destination: String,
        code: String,
        challengeId: UUID?,
        purpose: AuthMFAPurpose,
        on req: Request
    ) async throws {
        let subject = "Your Norviq code is \(code)"
        let context = purpose == .oauth ? "finish sign in with your provider" : "finish signing in"
        let requestedAt = ISO8601DateFormatter().string(from: Date())
        let body = "Use this code to \(context): \(code). This code expires in \(mfaConfig.codeTTLSeconds / 60) minutes. Requested at \(requestedAt)."
        let message = MailMessage(
            to: destination,
            subject: subject,
            body: body,
            purpose: "mfa_\(purpose.rawValue)",
            challengeId: challengeId
        )
        try await req.application.mailer.send(message, on: req)
    }

    private func maskDestination(_ destination: String, channel: AuthMFAChannel) -> String {
        switch channel {
        case .email:
            return maskEmail(destination)
        case .sms:
            if destination.count <= 4 {
                return "••••"
            }
            return "••••\(destination.suffix(4))"
        }
    }

    private func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "••••" }

        let name = parts[0]
        let domain = parts[1]
        let visiblePrefix = String(name.prefix(2))
        let visibleDomainPrefix = String(domain.prefix(1))
        let tld = domain.split(separator: ".").last.map(String.init) ?? ""
        return "\(visiblePrefix)•••@\(visibleDomainPrefix)•••.\(tld)"
    }

    private func issueResetCode(email: String, on req: Request) async throws
        -> AuthForgotPasswordResponse
    {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)

        guard let user = try await repo.findUser(email: normalizedEmail, on: req.db),
              let userId = user.id
        else {
            return AuthForgotPasswordResponse(
                message: "If the account exists, a reset code has been sent.", resetCode: nil
            )
        }

        let recentWindowStart = Date().addingTimeInterval(-Self.passwordResetIssueWindowSeconds)
        let recentCodes = try await repo.countRecentPasswordResetTokens(
            userId: userId,
            since: recentWindowStart,
            on: req.db
        )
        guard recentCodes < Self.passwordResetMaxIssuesPerWindow else {
            req.logger.warning("auth.password_reset throttled user_id=\(userId.uuidString)")
            return AuthForgotPasswordResponse(
                message: "If the account exists, a reset code has been sent.",
                resetCode: nil
            )
        }

        let code = generateResetCode()
        let codeHash = hashToken(code)
        let expiresAt = Date().addingTimeInterval(15 * 60)

        try await repo.createPasswordResetToken(
            userId: userId, codeHash: codeHash, expiresAt: expiresAt, on: req.db
        )

        let shouldReturnCode =
            req.application.environment == .testing
                && (Environment.get("AUTH_RESET_RETURN_CODE") ?? "false").lowercased() == "true"
        let responseCode = shouldReturnCode ? code : nil

        let message = MailMessage(
            to: normalizedEmail,
            subject: "Your StockPlan reset code",
            body: "Use this code to reset your password: \(code)"
        )
        try await req.application.mailer.send(message, on: req)

        return AuthForgotPasswordResponse(
            message: "If the account exists, a reset code has been sent.",
            resetCode: responseCode
        )
    }

    private func issueRefreshToken(userId: UUID, on req: Request) async throws -> (String, Int) {
        let expiresIn = refreshExpiresInSeconds(from: req)
        let rawToken = generateOpaqueToken()
        let tokenHash = hashToken(rawToken)
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))

        try await repo.createRefreshToken(
            userId: userId, tokenHash: tokenHash, expiresAt: expiresAt, on: req.db
        )
        return (rawToken, expiresIn)
    }

    private func oauthProviderClient(for provider: OAuthProvider) throws -> any OAuthProviderClient {
        guard let client = oauthProviders[provider] else {
            throw Abort(
                .serviceUnavailable,
                reason: "OAuth provider '\(provider.rawValue)' is not configured"
            )
        }
        return client
    }

    /// Selects the OAuth client for a given redirect URI. Web (http/https) redirects
    /// use the dedicated web-application client when configured (required for Google,
    /// whose iOS client type cannot register https redirect URIs); native custom-scheme
    /// redirects fall back to the default (mobile) client.
    private func oauthProviderClient(
        for provider: OAuthProvider,
        redirectURI: String
    ) throws -> any OAuthProviderClient {
        if isWebRedirectURI(redirectURI), let webClient = oauthWebProviders[provider] {
            return webClient
        }
        return try oauthProviderClient(for: provider)
    }

    private func isWebRedirectURI(_ redirectURI: String) -> Bool {
        let lowered = redirectURI.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://")
    }

    private func normalizeRedirectURI(_ redirectURI: String) throws -> String {
        let trimmed = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let normalized = components.url?.absoluteString
        else {
            throw Abort(.badRequest, reason: "Invalid OAuth redirect URI")
        }
        return normalized
    }

    private func validateRedirectURI(_ redirectURI: String, app: Application) throws {
        let allowlist = allowedRedirectURIs()
        guard !allowlist.isEmpty else {
            if app.environment == .production {
                throw Abort(.serviceUnavailable, reason: "OAuth redirect allowlist is not configured")
            }
            return
        }

        guard allowlist.contains(redirectURI) else {
            throw Abort(.badRequest, reason: "OAuth redirect URI is not allowed")
        }
    }

    private func allowedRedirectURIs() -> Set<String> {
        guard let raw = Environment.get("OAUTH_ALLOWED_REDIRECT_URIS") else {
            return []
        }

        return Set(
            raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func codeChallenge(for codeVerifier: String) -> String {
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        let data = Data(digest)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func randomURLSafeString(length: Int) -> String {
        let byteCount = max(length, 32)
        let bytes = (0 ..< byteCount).map { _ in UInt8.random(in: 0 ... 255) }
        let raw = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        if raw.count >= length {
            return String(raw.prefix(length))
        }
        return raw + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func generateOAuthUsername(
        suggestedUsername: String?,
        email: String,
        on req: Request
    ) async throws -> String {
        let emailPrefix = email.split(separator: "@").first.map(String.init) ?? "user"
        let normalizedSuggestedUsername: String? = {
            guard let suggestedUsername else { return nil }
            let trimmed = suggestedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let source = normalizedSuggestedUsername ?? emailPrefix

        let sanitized =
            source
                .lowercased()
                .map { char -> Character in
                    if char.isLetter || char.isNumber || char == "_" {
                        return char
                    }
                    return "_"
                }
        var base = String(sanitized)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if base.count < 4 {
            base += String(repeating: "0", count: 4 - base.count)
        }
        if base.count > 30 {
            base = String(base.prefix(30))
        }

        for attempt in 0 ..< 10 {
            let candidate: String
            if attempt == 0 {
                candidate = base
            } else {
                let suffix = "\(Int.random(in: 1000 ... 9999))"
                let maxBaseLength = max(4, 30 - suffix.count)
                let candidateBase = String(base.prefix(maxBaseLength))
                candidate = "\(candidateBase)\(suffix)"
            }

            if try await repo.findUser(username: candidate, on: req.db) == nil {
                return candidate
            }
        }

        return "user_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
    }

    private func syntheticOAuthEmail(provider: OAuthProvider, providerUserID: String) -> String {
        let normalizedProviderUserID =
            providerUserID
                .lowercased()
                .map { char -> Character in
                    if char.isLetter || char.isNumber || char == "_" || char == "-" {
                        return char
                    }
                    return "_"
                }
        let sanitizedID = String(normalizedProviderUserID)
        return "oauth_\(provider.rawValue)_\(sanitizedID)@oauth.norviqa.invalid"
    }

    private func normalizeUsername(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func validateUsername(_ username: String) throws {
        let pattern = #"^[a-zA-Z0-9_]{4,30}$"#
        if username.range(of: pattern, options: .regularExpression) == nil {
            throw Abort(
                .badRequest,
                reason: "Username must be 4-30 characters (letters, numbers, underscore)"
            )
        }
    }

    private func validateEmail(_ email: String) throws {
        if email.isEmpty || !email.contains("@") {
            throw Abort(.badRequest, reason: "Invalid email")
        }
    }

    private func validateDateOfBirth(_ dateOfBirth: Date) throws {
        if dateOfBirth > Date() {
            throw Abort(.badRequest, reason: "Date of birth cannot be in the future")
        }
    }

    private func persistUser(_ user: User, on req: Request) async throws {
        try user.encryptProtectedFields(using: req.userPIIEncryptionService)
        try await user.save(on: req.db)
        try user.hydrateProtectedFields(using: req.userPIIEncryptionService)
    }

    private func validatePassword(_ password: String) throws {
        if password.count < 8 {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters long")
        }

        let uppercase = CharacterSet.uppercaseLetters
        let lowercase = CharacterSet.lowercaseLetters
        let digits = CharacterSet.decimalDigits
        let symbols = CharacterSet.punctuationCharacters.union(.symbols)

        guard password.unicodeScalars.contains(where: { uppercase.contains($0) }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one uppercase letter")
        }
        guard password.unicodeScalars.contains(where: { lowercase.contains($0) }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one lowercase letter")
        }
        guard password.unicodeScalars.contains(where: { digits.contains($0) }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one number")
        }
        guard password.unicodeScalars.contains(where: { symbols.contains($0) }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one special character")
        }
    }

    private func responseUsername(for user: User) -> String {
        if let username = user.username?.trimmingCharacters(in: .whitespacesAndNewlines),
           !username.isEmpty
        {
            return username
        }
        if let prefix = user.email.split(separator: "@").first, !prefix.isEmpty {
            return String(prefix)
        }
        return user.email
    }

    private func responseDateOfBirth(for user: User) -> Date {
        user.dateOfBirth ?? defaultDateOfBirth()
    }

    private func defaultDateOfBirth() -> Date {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let twentyYearsAgoYear = currentYear - 20
        return calendar.date(from: DateComponents(year: twentyYearsAgoYear, month: 1, day: 1))
            ?? Date()
    }

    private func jwtExpiresInSeconds(from _: Request) -> Int {
        if let value = Environment.get("JWT_EXPIRES_IN_SECONDS"), let seconds = Int(value) {
            return seconds
        }
        return 60 * 60 * 24 * 7
    }

    private func refreshExpiresInSeconds(from _: Request) -> Int {
        if let value = Environment.get("JWT_REFRESH_EXPIRES_IN_SECONDS"), let seconds = Int(value) {
            return seconds
        }
        return 60 * 60 * 24 * 30
    }

    private func generateResetCode() -> String {
        String(format: "%06d", Int.random(in: 0 ... 999_999))
    }

    private func generateMFACode() -> String {
        String(format: "%06d", Int.random(in: 0 ... 999_999))
    }

    private func generateOpaqueToken(length: Int = 32) -> String {
        let bytes = (0 ..< length).map { _ in UInt8.random(in: 0 ... 255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func hashToken(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// swiftlint:enable type_body_length

extension Application {
    private struct AuthServiceKey: StorageKey {
        typealias Value = any AuthService
    }

    var authService: any AuthService {
        get {
            guard let service = storage[AuthServiceKey.self] else {
                fatalError("AuthService not configured")
            }
            return service
        }
        set {
            storage[AuthServiceKey.self] = newValue
        }
    }
}
