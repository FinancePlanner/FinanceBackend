import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("MCP Personal Access Token Auth Tests", .serialized)
struct MCPTokenAuthTests {
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
            username: "mcp_user_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "mcp_\(identifier)@example.com",
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

    /// Mints a PAT directly (bypasses the pro-gate that create() enforces) so
    /// auth-matrix tests don't require a Pro entitlement.
    private func mintPAT(app: Application, userId: UUID, scopes: [APIScope]) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        let pat = PersonalAccessToken(
            userId: userId,
            name: "test",
            tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: scopes.map(\.rawValue),
            expiresAt: Date().addingTimeInterval(3600)
        )
        try await pat.save(on: app.db)
        return raw
    }

    // MARK: - Authenticator matrix

    @Test("PAT with expenses:read can list expenses")
    func patReadListsExpenses() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("PAT without expenses:write is forbidden from creating an expense")
    func patMissingWriteScopeForbidden() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                try req.content.encode(ExpenseRequest(
                    title: "x", amount: 1, pillar: .fundamentals, occurredOn: "2026-07-02"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("PAT with market:read can read the news feed (MCP get_news, source=tracked)")
    func patMarketReadReadsNewsFeed() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead])
            try await app.testing().test(.GET, "v1/news/feed?limit=5", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("PAT without market:read is forbidden from the news feed")
    func patWithoutMarketReadForbiddenFromNewsFeed() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.GET, "v1/news/feed", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("PAT can never write news items, whatever its scopes")
    func patCannotCreateNews() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead, .expensesWrite])
            try await app.testing().test(.POST, "v1/news", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                struct NewsWrite: Content { let symbol: String; let headline: String }
                try req.content.encode(NewsWrite(symbol: "AAPL", headline: "x"))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("PAT with expenses:write can create an expense")
    func patWriteCreatesExpense() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesWrite])
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                try req.content.encode(ExpenseRequest(
                    title: "coffee", amount: 4, pillar: .fundamentals, occurredOn: "2026-07-02"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })
        }
    }

    @Test("Revoked PAT is rejected")
    func revokedPATRejected() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
            let pat = PersonalAccessToken(
                userId: user.userId, name: "revoked",
                tokenHash: OpaqueToken.sha256Hex(raw), scopes: [APIScope.expensesRead.rawValue],
                expiresAt: Date().addingTimeInterval(3600), revokedAt: Date()
            )
            try await pat.save(on: app.db)
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: raw)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Expired PAT is rejected")
    func expiredPATRejected() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
            let pat = PersonalAccessToken(
                userId: user.userId, name: "expired",
                tokenHash: OpaqueToken.sha256Hex(raw), scopes: [APIScope.expensesRead.rawValue],
                expiresAt: Date().addingTimeInterval(-60)
            )
            try await pat.save(on: app.db)
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: raw)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - Security invariant: PAT must not reach non-scoped first-party routes

    @Test("PAT cannot manage tokens (first-party only)")
    func patCannotManageTokens() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead, .expensesWrite])
            try await app.testing().test(.GET, "v1/tokens", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                // Opaque token is not a JWT → SessionToken.authenticator() rejects it.
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("PAT is forbidden from first-party expense sub-resources (recurring templates)")
    func patForbiddenFromFirstPartySubresource() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead, .expensesWrite])
            try await app.testing().test(.GET, "v1/expenses/recurring", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    // MARK: - Portfolio summary is exposed to third-party tokens under portfolio:read

    @Test("PAT with portfolio:read alone can read the portfolio summary")
    func patPortfolioReadReadsPortfolioSummary() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.portfolioRead])
            try await app.testing().test(.GET, "v1/portfolio/summary", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("Legacy PAT with market:read still reads the portfolio summary")
    func patMarketReadReadsPortfolioSummary() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead])
            try await app.testing().test(.GET, "v1/portfolio/summary", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("PAT holding neither portfolio:read nor market:read is forbidden from the summary")
    func patMissingPortfolioScopesForbiddenFromPortfolioSummary() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.GET, "v1/portfolio/summary", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("PAT cannot reach the rest of the portfolio controller")
    func patCannotReachOtherPortfolioRoutes() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead])
            // These stay on SessionToken.authenticator(), which rejects opaque tokens.
            for path in ["v1/portfolio/lists", "v1/portfolio/performance", "v1/pnl"] {
                try await app.testing().test(.GET, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: pat)
                }, afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                })
            }
        }
    }

    // MARK: - First-party session still works everywhere

    @Test("First-party JWT works on scoped routes with no scope context")
    func firstPartyJWTUnaffected() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "v1/expenses/recurring", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status != .forbidden && res.status != .unauthorized)
            })
            try await app.testing().test(.GET, "v1/portfolio/summary", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    // MARK: - PAT lifecycle stores only hashes

    @Test("Created PAT stores only a hash, never plaintext")
    func patStoresOnlyHash() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let raw = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            let stored = try await PersonalAccessToken.query(on: app.db).all()
            #expect(stored.count == 1)
            for row in stored {
                #expect(row.tokenHash != raw)
                #expect(row.tokenHash == OpaqueToken.sha256Hex(raw))
            }
        }
    }
}
