import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("AI Provider Credential Tests", .serialized)
struct AIProviderCredentialTests {
    // MARK: - Harness

    private func withApp(_ test: @escaping (Application) async throws -> Void) async throws {
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

    private func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let identifier = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "aicred_user_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "aicred_\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            token = try res.content.decode(AuthResponse.self).token
        })
        let session = try await app.jwt.keys.verify(token, as: SessionToken.self)
        return (token, session.userId)
    }

    private func mintPAT(app: Application, userId: UUID) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        let pat = PersonalAccessToken(
            userId: userId,
            name: "test",
            tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: APIScope.allCases.map(\.rawValue),
            expiresAt: Date().addingTimeInterval(3600)
        )
        try await pat.save(on: app.db)
        return raw
    }

    private func createBody(
        provider: String = "openai",
        label: String = "My key",
        apiKey: String = "sk-test-abcdefgh1234",
        baseURL: String? = nil,
        defaultModel: String? = nil
    ) -> UserAIProviderCredentialCreateRequest {
        UserAIProviderCredentialCreateRequest(
            provider: provider, label: label, apiKey: apiKey,
            baseURL: baseURL, defaultModel: defaultModel, verify: false
        )
    }

    // MARK: - Storage and encryption

    @Test("The stored column is ciphertext, never the plaintext key")
    func keyIsEncryptedAtRest() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let secret = "sk-test-supersecretvalue"

            try await app.testing().test(.POST, "v1/ai/credentials", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(createBody(apiKey: secret))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            let row = try #require(try await UserAIProviderCredential.query(on: app.db)
                .filter(\.$userId == user.userId).first())

            #expect(row.apiKeyEncrypted.hasPrefix(AESGCMTokenEncryptionService.storagePrefix))
            #expect(!row.apiKeyEncrypted.contains(secret))
            #expect(row.keyHint == "alue")
            #expect(row.keyFingerprint == OpaqueToken.sha256Hex(secret))
            #expect(try app.tokenEncryptionService.decrypt(row.apiKeyEncrypted, context: .aiProvider) == secret)
        }
    }

    @Test("A stored AI key cannot be decrypted as a broker token")
    func contextBindingIsEnforced() async throws {
        try await withApp { app in
            let stored = try app.tokenEncryptionService.encrypt("sk-test-x", context: .aiProvider)
            #expect(throws: (any Error).self) {
                _ = try app.tokenEncryptionService.decrypt(stored, context: .broker)
            }
        }
    }

    // MARK: - The key never comes back out

    @Test("Neither create nor list ever returns the plaintext key")
    func keyIsNeverEchoed() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let secret = "sk-test-neverecho9999"

            try await app.testing().test(.POST, "v1/ai/credentials", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(createBody(apiKey: secret))
            }, afterResponse: { res async throws in
                // Asserted on the raw body, not decoded fields, so a stray
                // field added later cannot slip past this test.
                #expect(!res.body.string.contains(secret))
            })

            try await app.testing().test(.GET, "v1/ai/credentials", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains(secret))
            })
        }
    }

    // MARK: - Upsert and delete

    @Test("Re-adding the same provider replaces the key instead of failing")
    func secondCreateUpserts() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)

            try await app.testing().test(.POST, "v1/ai/credentials", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(createBody(apiKey: "sk-test-first0001"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/ai/credentials", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(createBody(apiKey: "sk-test-second002"))
            }, afterResponse: { res async throws in
                // 200, not 500 from the unique constraint and not 409.
                #expect(res.status == .ok)
            })

            let count = try await UserAIProviderCredential.query(on: app.db)
                .filter(\.$userId == user.userId).count()
            #expect(count == 1)

            let row = try #require(try await UserAIProviderCredential.query(on: app.db)
                .filter(\.$userId == user.userId).first())
            #expect(try app.tokenEncryptionService.decrypt(row.apiKeyEncrypted, context: .aiProvider) == "sk-test-second002")
        }
    }

    @Test("Delete removes the row and another user's id is a 404")
    func deleteIsScopedToOwner() async throws {
        try await withApp { app in
            let owner = try await registerUser(app: app)
            let stranger = try await registerUser(app: app)

            var credentialId = ""
            try await app.testing().test(.POST, "v1/ai/credentials", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
                try req.content.encode(createBody())
            }, afterResponse: { res async throws in
                credentialId = try res.content.decode(UserAIProviderCredentialSummary.self).id.uuidString
            })

            try await app.testing().test(.DELETE, "v1/ai/credentials/\(credentialId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: stranger.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.DELETE, "v1/ai/credentials/\(credentialId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            let count = try await UserAIProviderCredential.query(on: app.db)
                .filter(\.$userId == owner.userId).count()
            #expect(count == 0)
        }
    }

    // MARK: - Validation, including SSRF

    @Test("A base URL pointing at a private or loopback host is rejected")
    func ssrfHostsAreRejected() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)

            // The metadata endpoint and loopback are the two that actually
            // matter: the server would authenticate to them with the user's key.
            for hostile in [
                "http://localhost:11434/v1",
                "https://169.254.169.254/v1",
                "https://127.0.0.1/v1",
                "https://10.0.0.5/v1",
                "https://192.168.1.10/v1",
                "https://172.16.4.4/v1",
                "https://box.local/v1",
            ] {
                try await app.testing().test(.POST, "v1/ai/credentials", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: user.token)
                    try req.content.encode(createBody(
                        provider: "compatible", baseURL: hostile, defaultModel: "some-model"
                    ))
                }, afterResponse: { res async throws in
                    #expect(res.status == .badRequest, "\(hostile) should be rejected")
                })
            }
        }
    }

    @Test("Plain http is rejected even for a public host")
    func httpIsRejected() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await app.testing().test(.POST, "v1/ai/credentials", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(createBody(
                    provider: "compatible", baseURL: "http://example.com/v1", defaultModel: "m"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Malformed submissions are rejected")
    func validationRejectsBadInput() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)

            let cases: [(String, UserAIProviderCredentialCreateRequest)] = [
                ("empty label", createBody(label: "   ")),
                ("unknown provider", createBody(provider: "hermes")),
                ("compatible without baseURL", createBody(provider: "compatible")),
                ("whitespace in key", createBody(apiKey: "sk-test abcd")),
                ("empty key", createBody(apiKey: "  ")),
            ]

            for (name, body) in cases {
                try await app.testing().test(.POST, "v1/ai/credentials", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: user.token)
                    try req.content.encode(body)
                }, afterResponse: { res async throws in
                    #expect(res.status == .badRequest, "\(name) should be rejected")
                })
            }
        }
    }

    // MARK: - Auth

    @Test("Unauthenticated requests are rejected")
    func unauthenticatedIsRejected() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/ai/credentials", afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    /// The important one. Without the first-party session guard, an MCP token
    /// scoped only to read expenses could enumerate or replace the user's
    /// provider keys.
    @Test("A fully scoped PAT cannot touch credentials on any route")
    func patCannotManageCredentials() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId)
            let someID = UUID().uuidString

            let routes: [(HTTPMethod, String)] = [
                (.GET, "v1/ai/credentials"),
                (.POST, "v1/ai/credentials"),
                (.POST, "v1/ai/credentials/\(someID)/verify"),
                (.DELETE, "v1/ai/credentials/\(someID)"),
            ]

            for (method, path) in routes {
                try await app.testing().test(method, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: pat)
                    if method == .POST, !path.hasSuffix("verify") {
                        try req.content.encode(createBody())
                    }
                }, afterResponse: { res async throws in
                    #expect(res.status == .forbidden || res.status == .unauthorized,
                            "\(method) \(path) must not accept a PAT, got \(res.status)")
                })
            }
        }
    }

    // MARK: - Outbound URL guard (pure)

    @Test("The shared outbound guard blocks what it claims to")
    func outboundGuardUnit() throws {
        #expect(OutboundURLGuard.isBlockedHost("localhost"))
        #expect(OutboundURLGuard.isBlockedHost("169.254.169.254"))
        #expect(OutboundURLGuard.isBlockedHost("172.20.1.1"))
        #expect(OutboundURLGuard.isBlockedHost("nas.local"))
        // Just outside the RFC 1918 172.16/12 range.
        #expect(!OutboundURLGuard.isBlockedHost("172.32.1.1"))
        #expect(!OutboundURLGuard.isBlockedHost("api.openai.com"))

        #expect(throws: (any Error).self) { _ = try OutboundURLGuard.validate("http://api.openai.com/v1") }
        #expect(throws: (any Error).self) { _ = try OutboundURLGuard.validate("https://127.0.0.1/v1") }
        #expect((try? OutboundURLGuard.validate("https://api.openai.com/v1")) != nil)
    }
}
