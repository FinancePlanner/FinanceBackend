import Crypto
import Fluent
import Foundation
import Logging
@testable import StockPlanBackend
import Testing
import VaporTesting

@Suite("Auth Tests", .serialized)
struct AuthTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func makeRegisterRequest(
        email: String,
        password: String = "Password123!",
        username: String = "valid_user",
        dateOfBirth: Date = Date(timeIntervalSince1970: 946_684_800)
    ) -> AuthRegisterRequest {
        AuthRegisterRequest(
            username: username,
            password: password,
            confirmPassword: password,
            email: email,
            dateOfBirth: dateOfBirth
        )
    }

    private func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeRequest(_ app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    private func configureFakeOAuthProvider(
        _ app: Application,
        provider: OAuthProvider,
        identity: OAuthIdentityInfo,
        mfaConfig: AuthMFAConfig = .default
    ) {
        app.authService = DefaultAuthService(
            repo: app.authRepository,
            oauthProviders: [provider: FakeOAuthProviderClient(provider: provider, identity: identity)],
            mfaConfig: mfaConfig,
            trialService: app.trialService
        )
    }

    private func makeOAuthExchangeRequest(app: Application, provider: OAuthProvider) async throws -> OAuthExchangeRequest {
        let redirectURI = "norviqa://oauth/callback"
        let startReq = OAuthStartRequest(redirectURI: redirectURI)
        var startResponse: OAuthStartResponse?

        try await app.testing().test(.POST, "v1/auth/oauth/\(provider.rawValue)/start", beforeRequest: { req in
            try req.content.encode(startReq)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            startResponse = try res.content.decode(OAuthStartResponse.self)
        })

        guard let startResponse,
              let url = URL(string: startResponse.authorizationURL),
              let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?
              .first(where: { $0.name == "state" })?
              .value
        else {
            throw Abort(.internalServerError, reason: "Fake OAuth start did not return a state")
        }

        return OAuthExchangeRequest(
            flowId: startResponse.flowId,
            code: "fake-code",
            state: state,
            redirectURI: redirectURI
        )
    }

    private func makeAuthenticatedUser(
        app: Application,
        email: String,
        username: String = "linked_user"
    ) async throws -> AuthResponse {
        let registerReq = makeRegisterRequest(email: email, username: username)
        var auth: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(registerReq)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            auth = try res.content.decode(AuthResponse.self)
        })
        return try #require(auth)
    }

    private func makeOAuthLinkExchangeRequest(
        app: Application,
        provider: OAuthProvider,
        token: String
    ) async throws -> OAuthExchangeRequest {
        let redirectURI = "norviqa://oauth/callback"
        let startReq = OAuthStartRequest(redirectURI: redirectURI)
        var startResponse: OAuthStartResponse?

        try await app.testing().test(.POST, "v1/auth/oauth/\(provider.rawValue)/link/start", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(startReq)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            startResponse = try res.content.decode(OAuthStartResponse.self)
        })

        guard let startResponse,
              let url = URL(string: startResponse.authorizationURL),
              let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?
              .first(where: { $0.name == "state" })?
              .value
        else {
            throw Abort(.internalServerError, reason: "Fake OAuth link start did not return a state")
        }

        return OAuthExchangeRequest(
            flowId: startResponse.flowId,
            code: "fake-code",
            state: state,
            redirectURI: redirectURI
        )
    }

    private func assertOAuthLinksVerifiedExistingEmail(provider: OAuthProvider) async throws {
        try await withApp { app in
            let email = "oauth-\(provider.rawValue)-link@example.com"
            let registerReq = makeRegisterRequest(
                email: email,
                username: "oauth_\(provider.rawValue)_link_user"
            )
            var existingUserID: UUID?

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                existingUserID = try res.content.decode(AuthResponse.self).userId
            })

            guard let existingUserID else {
                Issue.record("Expected existing user id")
                return
            }

            let providerUserID = "\(provider.rawValue)-linked-user"
            configureFakeOAuthProvider(
                app,
                provider: provider,
                identity: OAuthIdentityInfo(
                    providerUserID: providerUserID,
                    email: email,
                    emailVerified: true,
                    suggestedUsername: "oauth_\(provider.rawValue)_link_user"
                )
            )

            let exchangeReq = try await makeOAuthExchangeRequest(app: app, provider: provider)
            try await app.testing().test(.POST, "v1/auth/oauth/\(provider.rawValue)/exchange", beforeRequest: { req in
                try req.content.encode(exchangeReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                #expect(response.userId == existingUserID)
                #expect(response.email == email)
            })

            let identity = try await OAuthIdentity.query(on: app.db)
                .filter(\.$provider == provider.rawValue)
                .filter(\.$providerUserID == providerUserID)
                .first()
            #expect(identity?.$user.id == existingUserID)
            #expect(identity?.email == email)
            #expect(identity?.emailVerified == true)

            let usersWithEmail = try await User.query(on: app.db)
                .filter(\.$email == email)
                .count()
            #expect(usersWithEmail == 1)
        }
    }

    @Test("Registration fails when password confirmation does not match")
    func registerPasswordConfirmationMismatch() async throws {
        try await withApp { app in
            let registerReq = AuthRegisterRequest(
                username: "mismatch_user",
                password: "Password123!",
                confirmPassword: "Password123",
                email: "mismatch@example.com",
                dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
            )

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - Registration Tests

    @Test("Successful user registration")
    func registerSuccess() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "newuser@example.com", password: "Password123!")

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                #expect(!response.token.isEmpty)
                #expect(response.expiresIn > 0)
                #expect(!response.refreshToken.isEmpty)
                #expect(response.refreshExpiresIn > 0)
            })
        }
    }

    @Test("Registration persists encrypted date of birth")
    func registerStoresEncryptedDateOfBirth() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "encrypted-dob@example.com")
            var userID: UUID?

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                userID = try res.content.decode(AuthResponse.self).userId
            })

            guard let userID,
                  let user = try await User.find(userID, on: app.db)
            else {
                Issue.record("Expected created user")
                return
            }

            #expect(user.dateOfBirthEncrypted != nil)
        }
    }

    @Test("Registration fails with duplicate email")
    func registerDuplicateEmail() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "duplicate@example.com", password: "Password123!")

            // First registration should succeed
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            // Second registration with same email should fail
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Registration fails with invalid email")
    func registerInvalidEmail() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "invalid-email", password: "Password123!")

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Registration fails with short password")
    func registerShortPassword() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "test@example.com", password: "short")

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Email normalization - trims whitespace and lowercases")
    func registerEmailNormalization() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "  TEST@Example.COM  ", password: "Password123!")

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            // Now try to login with normalized email
            let loginReq = AuthLoginRequest(email: "test@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    // MARK: - Login Tests

    @Test("Successful login")
    func loginSuccess() async throws {
        try await withApp { app in
            let credentials = makeRegisterRequest(email: "login@example.com", password: "Password123!")

            // Register first
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(credentials)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            // Then login
            let loginReq = AuthLoginRequest(email: "login@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                #expect(!response.token.isEmpty)
                #expect(!response.refreshToken.isEmpty)
            })
        }
    }

    @Test("Login fails with wrong password")
    func loginWrongPassword() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "wrongpwd@example.com", password: "Password123!")

            // Register first
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            // Login with wrong password
            let loginReq = AuthLoginRequest(email: "wrongpwd@example.com", password: "WrongPassword1!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Login fails with non-existent email")
    func loginNonExistentEmail() async throws {
        try await withApp { app in
            let loginReq = AuthLoginRequest(email: "nonexistent@example.com", password: "Password123!")

            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Login returns MFA challenge for MFA-capable clients")
    func loginReturnsMFAChallengeForCapableClient() async throws {
        setenv("AUTH_MFA_ENABLED", "true", 1)
        defer { unsetenv("AUTH_MFA_ENABLED") }

        try await withApp { app in
            let mailer = RecordingMailerService()
            app.mailer = mailer
            let registerReq = makeRegisterRequest(email: "mfa-login@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let loginReq = AuthLoginRequest(email: "mfa-login@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-StockPlan-Client-Capabilities", value: "mfa-auth-v1")
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let outcome = try res.content.decode(AuthLoginOutcome.self)
                #expect(outcome.status == .mfaRequired)
                #expect(outcome.mfa != nil)
                #expect(outcome.auth == nil)
            })
        }
    }

    @Test("MFA email subject includes the generated verification code")
    func mfaEmailSubjectIncludesGeneratedCode() async throws {
        setenv("AUTH_MFA_ENABLED", "true", 1)
        defer { unsetenv("AUTH_MFA_ENABLED") }

        try await withApp { app in
            let mailer = RecordingMailerService()
            app.mailer = mailer
            let registerReq = makeRegisterRequest(email: "mfa-subject@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let loginReq = AuthLoginRequest(email: "mfa-subject@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-StockPlan-Client-Capabilities", value: "mfa-auth-v1")
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let outcome = try res.content.decode(AuthLoginOutcome.self)
                #expect(outcome.status == .mfaRequired)
            })

            let message = try #require(await mailer.messages().first)
            let regex = try NSRegularExpression(pattern: "\\b[0-9]{6}\\b")
            let bodyRange = NSRange(message.body.startIndex ..< message.body.endIndex, in: message.body)
            let match = try #require(regex.firstMatch(in: message.body, range: bodyRange))
            let codeRange = try #require(Range(match.range, in: message.body))
            let code = String(message.body[codeRange])

            #expect(message.subject == "Your Norviq code is \(code)")
        }
    }

    @Test("Console mailer logs MFA metadata without leaking code")
    func consoleMailerDoesNotLogVerificationCode() async throws {
        let app = try await Application.make(.testing)
        do {
            let recorder = LogRecorder()
            let request = makeRequest(app)
            request.logger = Logger(label: "mailer-test") { _ in CapturingLogHandler(recorder: recorder) }

            try await ConsoleMailerService().send(
                MailMessage(
                    to: "person@example.com",
                    subject: "Your Norviq code is 123456",
                    body: "Use this code to finish signing in: 123456.",
                    purpose: "mfa_login",
                    challengeId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")
                ),
                on: request
            )

            let logs = recorder.messages().joined(separator: "\n")
            #expect(!logs.contains("123456"))
            #expect(!logs.contains("Your Norviq code"))
            #expect(logs.contains("mfa_login"))
            #expect(logs.contains("00000000-0000-0000-0000-000000000001"))
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("MFA bypass email authenticates without challenge")
    func loginBypassesMFAForConfiguredEmail() async throws {
        setenv("AUTH_MFA_ENABLED", "true", 1)
        setenv("AUTH_MFA_BYPASS_EMAILS", " review-bypass@example.com ", 1)
        defer {
            unsetenv("AUTH_MFA_ENABLED")
            unsetenv("AUTH_MFA_BYPASS_EMAILS")
        }

        try await withApp { app in
            let registerReq = makeRegisterRequest(
                email: "review-bypass@example.com",
                username: "review_bypass_user"
            )
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let loginReq = AuthLoginRequest(email: "review-bypass@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-StockPlan-Client-Capabilities", value: "mfa-auth-v1")
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let outcome = try res.content.decode(AuthLoginOutcome.self)
                #expect(outcome.status == .authenticated)
                #expect(outcome.auth?.email == "review-bypass@example.com")
                #expect(outcome.mfa == nil)
            })

            let challengeCount = try await MFAChallenge.query(on: app.db).count()
            #expect(challengeCount == 0)
        }
    }

    @Test("MFA verify issues tokens for valid challenge")
    func mfaVerifyIssuesTokens() async throws {
        setenv("AUTH_MFA_ENABLED", "true", 1)
        defer { unsetenv("AUTH_MFA_ENABLED") }

        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "mfa-verify@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            var challengeID: UUID?
            let loginReq = AuthLoginRequest(email: "mfa-verify@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-StockPlan-Client-Capabilities", value: "mfa-auth-v1")
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                let outcome = try res.content.decode(AuthLoginOutcome.self)
                challengeID = outcome.mfa?.challengeId
            })

            guard let challengeID,
                  let challenge = try await MFAChallenge.find(challengeID, on: app.db)
            else {
                Issue.record("Expected MFA challenge to exist")
                return
            }

            challenge.codeHash = sha256("123456")
            try await challenge.save(on: app.db)

            try await app.testing().test(.POST, "v1/auth/mfa/verify", beforeRequest: { req in
                try req.content.encode(AuthMFAVerifyRequest(challengeId: challengeID, code: "123456"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let auth = try res.content.decode(AuthResponse.self)
                #expect(!auth.token.isEmpty)
                #expect(!auth.refreshToken.isEmpty)
            })
        }
    }

    @Test("Non-capable client is rejected when legacy bypass is disabled")
    func loginRejectsLegacyWhenBypassDisabled() async throws {
        setenv("AUTH_MFA_ENABLED", "true", 1)
        setenv("AUTH_MFA_ALLOW_LEGACY_BYPASS", "false", 1)
        defer {
            unsetenv("AUTH_MFA_ENABLED")
            unsetenv("AUTH_MFA_ALLOW_LEGACY_BYPASS")
        }

        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "legacy-bypass@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let loginReq = AuthLoginRequest(email: "legacy-bypass@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .upgradeRequired)
            })
        }
    }

    // MARK: - Current User Tests

    @Test("Get current user with valid token")
    func getCurrentUser() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "currentuser@example.com", password: "Password123!")
            var authToken = ""

            // Register to get a token
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                authToken = response.token
            })

            // Get current user
            try await app.testing().test(.GET, "v1/auth/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: authToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let user = try res.content.decode(AuthUserResponse.self)
                #expect(user.email == "currentuser@example.com")
            })
        }
    }

    @Test("Get current user fails without token")
    func getCurrentUserNoToken() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/auth/me", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - Refresh Token Tests

    @Test("Successful token refresh")
    func refreshTokenSuccess() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "refresh@example.com", password: "Password123!")
            var refreshToken = ""

            // Register to get refresh token
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                refreshToken = response.refreshToken
            })

            // Use refresh token to get new tokens
            let refreshReq = AuthRefreshRequest(refreshToken: refreshToken)
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(refreshReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                #expect(!response.token.isEmpty)
                #expect(!response.refreshToken.isEmpty)
                // New refresh token should be different (old one is revoked)
                #expect(response.refreshToken != refreshToken)
            })
        }
    }

    @Test("Refresh token fails with invalid token")
    func refreshTokenInvalid() async throws {
        try await withApp { app in
            let refreshReq = AuthRefreshRequest(refreshToken: "invalid-refresh-token")

            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(refreshReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Refresh token fails after being used (rotation)")
    func refreshTokenRotation() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "rotation@example.com", password: "Password123!")
            var refreshToken = ""

            // Register to get refresh token
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                let response = try res.content.decode(AuthResponse.self)
                refreshToken = response.refreshToken
            })

            // First refresh should succeed
            let refreshReq = AuthRefreshRequest(refreshToken: refreshToken)
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(refreshReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            // Second refresh with same token should fail (token was revoked)
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(refreshReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - OAuth Tests

    @Test("OAuth start succeeds for configured Google provider")
    func oauthStartGoogleSuccess() async throws {
        setenv("OAUTH_GOOGLE_CLIENT_ID", "google-client-id", 1)
        setenv("OAUTH_GOOGLE_CLIENT_SECRET", "google-client-secret", 1)
        setenv("OAUTH_ALLOWED_REDIRECT_URIS", "norviqa://oauth/callback", 1)
        defer {
            unsetenv("OAUTH_GOOGLE_CLIENT_ID")
            unsetenv("OAUTH_GOOGLE_CLIENT_SECRET")
            unsetenv("OAUTH_ALLOWED_REDIRECT_URIS")
        }

        try await withApp { app in
            let startReq = OAuthStartRequest(redirectURI: "norviqa://oauth/callback")
            try await app.testing().test(.POST, "v1/auth/oauth/google/start", beforeRequest: { req in
                try req.content.encode(startReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(OAuthStartResponse.self)
                #expect(response.expiresIn > 0)
                #expect(!response.authorizationURL.isEmpty)
                #expect(response.authorizationURL.contains("accounts.google.com"))
            })
        }
    }

    @Test("OAuth start fails for unsupported provider")
    func oauthStartUnsupportedProvider() async throws {
        try await withApp { app in
            let startReq = OAuthStartRequest(redirectURI: "norviqa://oauth/callback")
            try await app.testing().test(.POST, "v1/auth/oauth/unknown/start", beforeRequest: { req in
                try req.content.encode(startReq)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("OAuth exchange links verified Google email to existing account")
    func oauthExchangeLinksVerifiedGoogleEmailToExistingAccount() async throws {
        try await assertOAuthLinksVerifiedExistingEmail(provider: .google)
    }

    @Test("OAuth exchange links verified Apple email to existing account")
    func oauthExchangeLinksVerifiedAppleEmailToExistingAccount() async throws {
        try await assertOAuthLinksVerifiedExistingEmail(provider: .apple)
    }

    @Test("OAuth exchange links verified X email to existing account")
    func oauthExchangeLinksVerifiedXEmailToExistingAccount() async throws {
        try await assertOAuthLinksVerifiedExistingEmail(provider: .x)
    }

    @Test("OAuth exchange does not link unverified email to existing account")
    func oauthExchangeRejectsUnverifiedExistingEmail() async throws {
        try await withApp { app in
            let email = "oauth-unverified@example.com"
            let registerReq = makeRegisterRequest(
                email: email,
                username: "oauth_unverified_user"
            )
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            configureFakeOAuthProvider(
                app,
                provider: .google,
                identity: OAuthIdentityInfo(
                    providerUserID: "google-unverified-user",
                    email: email,
                    emailVerified: false,
                    suggestedUsername: "oauth_unverified_user"
                )
            )

            let exchangeReq = try await makeOAuthExchangeRequest(app: app, provider: .google)
            try await app.testing().test(.POST, "v1/auth/oauth/google/exchange", beforeRequest: { req in
                try req.content.encode(exchangeReq)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("ACCOUNT_EXISTS_LINK_REQUIRED"))
            })
        }
    }

    @Test("OAuth exchange still creates new OAuth user when email is new")
    func oauthExchangeCreatesNewUserForNewEmail() async throws {
        try await withApp { app in
            let email = "oauth-new-user@example.com"
            configureFakeOAuthProvider(
                app,
                provider: .google,
                identity: OAuthIdentityInfo(
                    providerUserID: "google-new-user",
                    email: email,
                    emailVerified: true,
                    suggestedUsername: "oauth_new_user"
                )
            )

            let exchangeReq = try await makeOAuthExchangeRequest(app: app, provider: .google)
            try await app.testing().test(.POST, "v1/auth/oauth/google/exchange", beforeRequest: { req in
                try req.content.encode(exchangeReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                #expect(response.email == email)
            })

            let identity = try await OAuthIdentity.query(on: app.db)
                .filter(\.$provider == OAuthProvider.google.rawValue)
                .filter(\.$providerUserID == "google-new-user")
                .first()
            #expect(identity != nil)

            let userID = try #require(identity?.$user.id)
            let user = try #require(try await User.find(userID, on: app.db))
            #expect(user.trialTier == "temporary")
            #expect(user.trialDays == 7)
            #expect(user.trialStartedAt != nil)
        }
    }

    @Test("OAuth exchange never triggers MFA, even for a new user with MFA enabled")
    func oauthExchangeSkipsMFAForNewUser() async throws {
        // Reviewer scenario: Sign in with Apple using a fresh Apple ID (not in the
        // bypass list) while MFA is enabled. Federated sign-in must authenticate
        // directly and must never issue an email MFA challenge.
        try await withApp { app in
            let email = "oauth-reviewer@example.com"

            configureFakeOAuthProvider(
                app,
                provider: .apple,
                identity: OAuthIdentityInfo(
                    providerUserID: "apple-reviewer-user",
                    email: email,
                    emailVerified: true,
                    suggestedUsername: "oauth_reviewer_user"
                ),
                mfaConfig: AuthMFAConfig(
                    enabled: true,
                    allowLegacyBypass: true,
                    codeTTLSeconds: 300,
                    maxVerifyAttempts: 5,
                    resendCooldownSeconds: 30,
                    maxResends: 3,
                    bypassEmails: []
                )
            )

            let exchangeReq = try await makeOAuthExchangeRequest(app: app, provider: .apple)
            try await app.testing().test(.POST, "v1/auth/oauth/apple/exchange", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-StockPlan-Client-Capabilities", value: "mfa-auth-v1")
                try req.content.encode(exchangeReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let outcome = try res.content.decode(AuthLoginOutcome.self)
                #expect(outcome.status == .authenticated)
                #expect(outcome.auth?.email == email)
                #expect(outcome.mfa == nil)
            })

            let challengeCount = try await MFAChallenge.query(on: app.db).count()
            #expect(challengeCount == 0)
        }
    }

    @Test("OAuth identities lists all supported providers with connected status")
    func oauthIdentitiesListsSupportedProviders() async throws {
        try await withApp { app in
            let auth = try await makeAuthenticatedUser(app: app, email: "linked-list@example.com")
            try await OAuthIdentity(
                userID: auth.userId,
                provider: OAuthProvider.google.rawValue,
                providerUserID: "google-list-user",
                email: "linked-list@example.com",
                emailVerified: true
            ).save(on: app.db)

            try await app.testing().test(.GET, "v1/auth/oauth/identities", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(OAuthLinkedAccountsResponse.self)
                #expect(response.accounts.map(\.provider) == [.apple, .google, .x])
                #expect(response.accounts.first(where: { $0.provider == .google })?.connected == true)
                #expect(response.accounts.first(where: { $0.provider == .apple })?.connected == false)
                #expect(response.accounts.first(where: { $0.provider == .x })?.connected == false)
            })
        }
    }

    @Test("OAuth link start requires auth and creates link flow bound to user")
    func oauthLinkStartRequiresAuthAndCreatesBoundLinkFlow() async throws {
        try await withApp { app in
            let startReq = OAuthStartRequest(redirectURI: "norviqa://oauth/callback")
            try await app.testing().test(.POST, "v1/auth/oauth/google/link/start", beforeRequest: { req in
                try req.content.encode(startReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            let auth = try await makeAuthenticatedUser(app: app, email: "link-start@example.com")
            configureFakeOAuthProvider(
                app,
                provider: .google,
                identity: OAuthIdentityInfo(
                    providerUserID: "google-link-start-user",
                    email: "link-start@example.com",
                    emailVerified: true,
                    suggestedUsername: "link_start"
                )
            )

            try await app.testing().test(.POST, "v1/auth/oauth/google/link/start", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
                try req.content.encode(startReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(OAuthStartResponse.self)
                let flow = try await OAuthFlow.find(response.flowId, on: app.db)
                #expect(flow?.purpose == OAuthFlowPurpose.link.rawValue)
                #expect(flow?.userId == auth.userId)
            })
        }
    }

    @Test("OAuth link exchange succeeds for same verified email and is idempotent")
    func oauthLinkExchangeSucceedsForSameVerifiedEmailAndIsIdempotent() async throws {
        try await withApp { app in
            let email = "same-link@example.com"
            let auth = try await makeAuthenticatedUser(app: app, email: email)
            configureFakeOAuthProvider(
                app,
                provider: .google,
                identity: OAuthIdentityInfo(
                    providerUserID: "google-same-user",
                    email: "  SAME-LINK@example.com ",
                    emailVerified: true,
                    suggestedUsername: "same_link"
                )
            )

            let exchangeReq = try await makeOAuthLinkExchangeRequest(app: app, provider: .google, token: auth.token)
            try await app.testing().test(.POST, "v1/auth/oauth/google/link/exchange", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
                try req.content.encode(exchangeReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(OAuthLinkResponse.self)
                #expect(response.provider == .google)
                #expect(response.connected == true)
                #expect(response.email == email)
            })

            let secondReq = try await makeOAuthLinkExchangeRequest(app: app, provider: .google, token: auth.token)
            try await app.testing().test(.POST, "v1/auth/oauth/google/link/exchange", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
                try req.content.encode(secondReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(OAuthLinkResponse.self)
                #expect(response.connected == true)
            })

            let identityCount = try await OAuthIdentity.query(on: app.db)
                .filter(\.$provider == OAuthProvider.google.rawValue)
                .filter(\.$providerUserID == "google-same-user")
                .count()
            #expect(identityCount == 1)
        }
    }

    @Test("OAuth link exchange rejects mismatched provider email")
    func oauthLinkExchangeRejectsMismatchedEmail() async throws {
        try await withApp { app in
            let auth = try await makeAuthenticatedUser(app: app, email: "current@example.com")
            configureFakeOAuthProvider(
                app,
                provider: .x,
                identity: OAuthIdentityInfo(
                    providerUserID: "x-mismatch-user",
                    email: "other@example.com",
                    emailVerified: true,
                    suggestedUsername: nil
                )
            )

            let exchangeReq = try await makeOAuthLinkExchangeRequest(app: app, provider: .x, token: auth.token)
            try await app.testing().test(.POST, "v1/auth/oauth/x/link/exchange", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
                try req.content.encode(exchangeReq)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("Provider email must match your account email"))
            })
        }
    }

    @Test("OAuth link exchange rejects identity already linked to another user")
    func oauthLinkExchangeRejectsIdentityLinkedToAnotherUser() async throws {
        try await withApp { app in
            let owner = try await makeAuthenticatedUser(app: app, email: "owner@example.com", username: "owner_user")
            let current = try await makeAuthenticatedUser(app: app, email: "current-owner@example.com", username: "current_owner")
            try await OAuthIdentity(
                userID: owner.userId,
                provider: OAuthProvider.apple.rawValue,
                providerUserID: "apple-owner-user",
                email: "current-owner@example.com",
                emailVerified: true
            ).save(on: app.db)

            configureFakeOAuthProvider(
                app,
                provider: .apple,
                identity: OAuthIdentityInfo(
                    providerUserID: "apple-owner-user",
                    email: "current-owner@example.com",
                    emailVerified: true,
                    suggestedUsername: nil
                )
            )

            let exchangeReq = try await makeOAuthLinkExchangeRequest(app: app, provider: .apple, token: current.token)
            try await app.testing().test(.POST, "v1/auth/oauth/apple/link/exchange", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: current.token)
                try req.content.encode(exchangeReq)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("already linked to a different account"))
            })
        }
    }

    // MARK: - Password Reset Tests

    @Test("Forgot password returns success message")
    func forgotPasswordSuccess() async throws {
        try await withApp { app in
            // Register a user first
            let registerReq = makeRegisterRequest(email: "forgot@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            // Request password reset
            let forgotReq = AuthForgotPasswordRequest(email: "forgot@example.com")
            try await app.testing().test(.POST, "v1/auth/forgot-password", beforeRequest: { req in
                try req.content.encode(forgotReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthForgotPasswordResponse.self)
                #expect(response.message.contains("reset code"))
            })
        }
    }

    @Test("Forgot password for non-existent email still returns success")
    func forgotPasswordNonExistent() async throws {
        try await withApp { app in
            let forgotReq = AuthForgotPasswordRequest(email: "nonexistent@example.com")

            try await app.testing().test(.POST, "v1/auth/forgot-password", beforeRequest: { req in
                try req.content.encode(forgotReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthForgotPasswordResponse.self)
                // Should still return success message to prevent email enumeration
                #expect(response.message.contains("reset code"))
            })
        }
    }

    @Test("Reset password fails with invalid code")
    func resetPasswordInvalidCode() async throws {
        try await withApp { app in
            // Register a user first
            let registerReq = makeRegisterRequest(email: "resetinvalid@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            // Try to reset with invalid code
            let resetReq = AuthResetPasswordRequest(
                email: "resetinvalid@example.com",
                code: "000000",
                newPassword: "NewPassword123!"
            )
            try await app.testing().test(.POST, "v1/auth/reset-password", beforeRequest: { req in
                try req.content.encode(resetReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Reset token is consumed after repeated invalid attempts")
    func resetPasswordInvalidAttemptsConsumeToken() async throws {
        try await withApp { app in
            let req = makeRequest(app)
            let repo = DatabaseAuthRepository()
            let user = try await repo.createUser(
                email: "resetattempts@example.com",
                passwordHash: req.password.async.hash("OldPassword123!").get(),
                on: app.db
            )
            let userId = try #require(user.id)
            try await repo.createPasswordResetToken(
                userId: userId,
                codeHash: sha256("123456"),
                expiresAt: Date().addingTimeInterval(15 * 60),
                on: app.db
            )

            for _ in 0 ..< 5 {
                do {
                    _ = try await app.authService.resetPassword(
                        email: "resetattempts@example.com",
                        code: "000000",
                        newPassword: "NewPassword123!",
                        on: req
                    )
                    Issue.record("Expected invalid reset code to fail.")
                } catch let abort as Abort {
                    #expect(abort.status == .unauthorized)
                }
            }

            let token = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: sha256("123456"),
                now: Date(),
                on: app.db
            )
            #expect(token == nil)
        }
    }
}

private actor RecordingMailerService: MailerService {
    private var sentMessages: [MailMessage] = []

    func send(_ message: MailMessage, on _: Request) async throws {
        sentMessages.append(message)
    }

    func messages() -> [MailMessage] {
        sentMessages
    }
}

private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedMessages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        capturedMessages.append(message)
    }

    func messages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedMessages
    }
}

private struct CapturingLogHandler: LogHandler {
    let recorder: LogRecorder
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let renderedMetadata = (event.metadata ?? [:])
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        let rendered = renderedMetadata.isEmpty
            ? "\(event.message)"
            : "\(event.message) \(renderedMetadata)"
        recorder.append(rendered)
    }
}

private struct FakeOAuthProviderClient: OAuthProviderClient {
    let provider: OAuthProvider
    let identity: OAuthIdentityInfo

    func makeAuthorizationURL(context: OAuthAuthorizationContext) throws -> URL {
        var components = URLComponents(string: "https://oauth.example.test/authorize")!
        components.queryItems = [
            URLQueryItem(name: "state", value: context.state),
            URLQueryItem(name: "nonce", value: context.nonce),
        ]
        return components.url!
    }

    func resolveIdentity(
        code _: String,
        redirectURI _: String,
        codeVerifier _: String,
        nonce _: String,
        on _: Request
    ) async throws -> OAuthIdentityInfo {
        identity
    }
}

// MARK: - AuthRepository Unit Tests

@Suite("AuthRepository Tests", .serialized)
struct AuthRepositoryTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Create and find user by email")
    func createAndFindUserByEmail() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()

            // Create a user
            let user = try await repo.createUser(
                email: "repo@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )

            #expect(user.id != nil)
            #expect(user.email == "repo@example.com")

            // Find by email
            let found = try await repo.findUser(email: "repo@example.com", on: app.db)
            #expect(found != nil)
            #expect(found?.id == user.id)
        }
    }

    @Test("Find user by ID")
    func findUserById() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()

            let user = try await repo.createUser(
                email: "findbyid@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )

            let userId = try #require(user.id)
            let found = try await repo.findUser(id: userId, on: app.db)

            #expect(found != nil)
            #expect(found?.email == "findbyid@example.com")
        }
    }

    @Test("Find user returns nil for non-existent email")
    func findUserNonExistent() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()

            let found = try await repo.findUser(email: "nonexistent@example.com", on: app.db)
            #expect(found == nil)
        }
    }

    @Test("Create and find valid password reset token")
    func passwordResetTokenLifecycle() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()

            // Create a user first
            let user = try await repo.createUser(
                email: "resettoken@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)

            // Create a reset token
            let codeHash = "test_code_hash"
            let expiresAt = Date().addingTimeInterval(15 * 60) // 15 minutes
            try await repo.createPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                expiresAt: expiresAt,
                on: app.db
            )

            // Find the valid token
            let token = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                now: Date(),
                on: app.db
            )

            #expect(token != nil)
            #expect(token?.userId == userId)
            #expect(token?.codeHash == codeHash)
        }
    }

    @Test("Expired password reset token not found")
    func expiredPasswordResetToken() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()

            let user = try await repo.createUser(
                email: "expired@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)

            // Create an expired token
            let codeHash = "expired_code_hash"
            let expiresAt = Date().addingTimeInterval(-60) // Already expired
            try await repo.createPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                expiresAt: expiresAt,
                on: app.db
            )

            // Try to find - should return nil
            let token = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                now: Date(),
                on: app.db
            )

            #expect(token == nil)
        }
    }

    @Test("Mark password reset token as used")
    func markPasswordResetTokenUsed() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()

            let user = try await repo.createUser(
                email: "markused@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)

            let codeHash = "used_code_hash"
            let expiresAt = Date().addingTimeInterval(15 * 60)
            try await repo.createPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                expiresAt: expiresAt,
                on: app.db
            )

            // Find and mark as used
            let token = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                now: Date(),
                on: app.db
            )
            let foundToken = try #require(token)

            try await repo.markPasswordResetTokenUsed(foundToken, usedAt: Date(), on: app.db)

            // Should not be findable anymore
            let usedToken = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                now: Date(),
                on: app.db
            )

            #expect(usedToken == nil)
        }
    }

    @Test("Create and find valid refresh token")
    func refreshTokenLifecycle() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()

            let user = try await repo.createUser(
                email: "refreshrepo@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)

            // Create refresh token
            let tokenHash = "refresh_token_hash"
            let expiresAt = Date().addingTimeInterval(30 * 24 * 60 * 60) // 30 days
            try await repo.createRefreshToken(
                userId: userId,
                tokenHash: tokenHash,
                expiresAt: expiresAt,
                on: app.db
            )

            // Find the valid token
            let token = try await repo.findValidRefreshToken(
                tokenHash: tokenHash,
                now: Date(),
                on: app.db
            )

            #expect(token != nil)
            #expect(token?.userId == userId)
            #expect(token?.tokenHash == tokenHash)
        }
    }

    @Test("Expired refresh token not found")
    func expiredRefreshToken() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()

            let user = try await repo.createUser(
                email: "expiredrefresh@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)

            // Create an expired token
            let tokenHash = "expired_refresh_hash"
            let expiresAt = Date().addingTimeInterval(-60) // Already expired
            try await repo.createRefreshToken(
                userId: userId,
                tokenHash: tokenHash,
                expiresAt: expiresAt,
                on: app.db
            )

            // Try to find - should return nil
            let token = try await repo.findValidRefreshToken(
                tokenHash: tokenHash,
                now: Date(),
                on: app.db
            )

            #expect(token == nil)
        }
    }

    @Test("Revoke refresh token")
    func revokeRefreshToken() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()

            let user = try await repo.createUser(
                email: "revokerefresh@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)

            let tokenHash = "revoke_token_hash"
            let expiresAt = Date().addingTimeInterval(30 * 24 * 60 * 60)
            try await repo.createRefreshToken(
                userId: userId,
                tokenHash: tokenHash,
                expiresAt: expiresAt,
                on: app.db
            )

            // Find and revoke
            let token = try await repo.findValidRefreshToken(
                tokenHash: tokenHash,
                now: Date(),
                on: app.db
            )
            let foundToken = try #require(token)

            try await repo.revokeRefreshToken(foundToken, revokedAt: Date(), on: app.db)

            // Should not be findable anymore
            let revokedToken = try await repo.findValidRefreshToken(
                tokenHash: tokenHash,
                now: Date(),
                on: app.db
            )

            #expect(revokedToken == nil)
        }
    }
}
