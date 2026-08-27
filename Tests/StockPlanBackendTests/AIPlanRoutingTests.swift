import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor
import VaporTesting

/// End-to-end plan selection: entitlement in the database, chain out of the
/// resolver. `AIModelRouterTests` covers the chain composition itself; this suite
/// only asks "which plan did this user get, and did BYOK still win".
extension AIEnvironmentSuites {
    @Suite("AI plan routing", .serialized)
    struct AIPlanRoutingTests {
        private func withApp(_ test: (Application) async throws -> Void) async throws {
            try await DatabaseTestLock.withLock {
                setenv("BYPASS_BILLING", "false", 1)
                setenv("AI_PROVIDER", "openrouter", 1)
                setenv("OPENROUTER_API_KEY", "sk-or-test", 1)
                setenv("AI_MODEL", "deepseek/deepseek-v4-flash", 1)
                defer {
                    unsetenv("AI_PROVIDER")
                    unsetenv("OPENROUTER_API_KEY")
                    unsetenv("AI_MODEL")
                    unsetenv("AI_PLAN_ROUTING_ENABLED")
                }
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

        private func registerUser(
            on app: Application,
            identifier: String,
            email: String? = nil
        ) async throws -> AuthResponse {
            let suffix = String(identifier.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(18))
            let request = AuthRegisterRequest(
                username: "airoute_\(suffix)",
                password: "Password123!",
                confirmPassword: "Password123!",
                email: email ?? "airoute+\(identifier)@example.com",
                dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
            )
            var response: AuthResponse?
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(request)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(AuthResponse.self)
            })
            let auth = try #require(response)
            // Registration starts a default trial, and a trial resolves to pro. Clear
            // it so the free cases really are free.
            let user = try #require(try await User.find(auth.userId, on: app.db))
            user.trialStartedAt = nil
            user.trialDays = nil
            user.trialTier = nil
            try await user.save(on: app.db)
            return auth
        }

        private func grantPro(userId: UUID, on app: Application) async throws {
            try await Entitlement(userId: userId, level: "pro").save(on: app.db)
        }

        private func request(on app: Application) -> Request {
            Request(application: app, on: app.eventLoopGroup.next())
        }

        // MARK: - Plan selection

        @Test("A free user is routed to the free chain")
        func freeUserGetsFreeChain() async throws {
            try await withApp { app in
                let auth = try await registerUser(on: app, identifier: "free")

                let resolved = try await AIAssistantClientResolver.resolve(
                    userId: auth.userId, on: request(on: app)
                )

                #expect(resolved.plan == .free)
                #expect(resolved.credential == nil)
            }
        }

        @Test("A Pro user is routed to the pro chain")
        func proUserGetsProChain() async throws {
            try await withApp { app in
                let auth = try await registerUser(on: app, identifier: "pro")
                try await grantPro(userId: auth.userId, on: app)

                let resolved = try await AIAssistantClientResolver.resolve(
                    userId: auth.userId, on: request(on: app)
                )

                #expect(resolved.plan == .pro)
            }
        }

        @Test("An active trial routes to the pro chain")
        func trialUserGetsProChain() async throws {
            try await withApp { app in
                let auth = try await registerUser(on: app, identifier: "trial")
                let user = try #require(try await User.find(auth.userId, on: app.db))
                user.trialStartedAt = Date()
                user.trialDays = 7
                user.trialTier = "temporary"
                try await user.save(on: app.db)

                let resolved = try await AIAssistantClientResolver.resolve(
                    userId: auth.userId, on: request(on: app)
                )

                #expect(resolved.plan == .pro)
            }
        }

        @Test("An allowlisted email routes to the pro chain with no subscription")
        func premiumEmailGetsProChain() async throws {
            setenv("BILLING_PREMIUM_EMAILS", "lifetime@example.com", 1)
            defer { unsetenv("BILLING_PREMIUM_EMAILS") }

            try await withApp { app in
                let auth = try await registerUser(
                    on: app, identifier: "lifetime", email: "LIFETIME@example.com"
                )

                // No entitlement row, no subscription — the allowlist alone.
                #expect(try await Entitlement.query(on: app.db).filter(\.$userId == auth.userId).first() == nil)

                let resolved = try await AIAssistantClientResolver.resolve(
                    userId: auth.userId, on: request(on: app)
                )

                #expect(resolved.plan == .pro)
            }
        }

        // MARK: - Precedence

        @Test("A user's own key still wins over plan routing")
        func byokBeatsPlanRouting() async throws {
            try await withApp { app in
                let auth = try await registerUser(on: app, identifier: "byok")
                let req = request(on: app)
                let encryptedKey = try req.tokenEncryptionService.encrypt("sk-user", context: .aiProvider)
                let credential = UserAIProviderCredential(
                    userId: auth.userId,
                    provider: .openAI,
                    label: "own key",
                    apiKeyEncrypted: encryptedKey,
                    keyHint: "user",
                    keyFingerprint: "fingerprint",
                    defaultModel: "gpt-5.6-luna",
                    status: .active
                )
                try await credential.save(on: app.db)

                let resolved = try await AIAssistantClientResolver.resolve(userId: auth.userId, on: req)

                #expect(resolved.usesOwnKey)
                // A user paying their own bill is not plan-routed at all.
                #expect(resolved.plan == nil)
            }
        }

        @Test("With plan routing off every user lands on the legacy chain")
        func killSwitchDisablesPlanRouting() async throws {
            setenv("AI_PLAN_ROUTING_ENABLED", "false", 1)
            defer { unsetenv("AI_PLAN_ROUTING_ENABLED") }

            try await withApp { app in
                let auth = try await registerUser(on: app, identifier: "killswitch")

                let resolved = try await AIAssistantClientResolver.resolve(
                    userId: auth.userId, on: request(on: app)
                )

                #expect(resolved.plan == nil)
            }
        }

        @Test("A missing router falls back to the shared client, preserving the test contract")
        func absentRouterFallsBackToSharedClient() async throws {
            try await withApp { app in
                let auth = try await registerUser(on: app, identifier: "norouter")
                // `AIChatTests` and `WhyMovedTests` inject a scripted client here and
                // clear the router; that path must keep working.
                app.aiModelRouter = nil

                let resolved = try await AIAssistantClientResolver.resolve(
                    userId: auth.userId, on: request(on: app)
                )

                #expect(resolved.plan == nil)
                #expect(resolved.credential == nil)
            }
        }

        @Test("An entitlement lookup failure fails closed to the free chain")
        func entitlementFailureFailsClosedToFree() async throws {
            try await withApp { app in
                app.entitlementResolver = ThrowingEntitlementResolver()

                let resolved = try await AIAssistantClientResolver.resolve(
                    userId: UUID(), on: request(on: app)
                )

                // Never hand out paid inference because a lookup broke.
                #expect(resolved.plan == .free)
            }
        }
    }
}

private struct ThrowingEntitlementResolver: EntitlementResolver {
    func resolve(userId _: UUID, on _: any Database) async throws -> EntitlementSnapshot {
        throw Abort(.internalServerError, reason: "entitlement backend down")
    }
}
