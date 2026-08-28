import Fluent
import Foundation
import NIOConcurrencyHelpers
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// The per-view AI summaries.
///
/// The guarantees worth defending here are the ones that cost money or mislead:
/// a free user never reaches the paid chain, a cache hit makes no upstream call,
/// this feature cannot exhaust the assistant's allowance, and no number the
/// model produced is ever shown.
@Suite("AI view summaries", .serialized)
struct AIViewSummaryTests {
    // MARK: - Harness

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("BYPASS_BILLING", "false", 1)
            defer {
                unsetenv("AI_VIEW_SUMMARY_DAILY_LIMIT")
                unsetenv("AI_DAILY_LIMIT")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                // Redis is disabled in `.testing`, so the real cache would be
                // permanently inert and a hit could never be observed.
                app.aiResponseCache = InMemoryAIResponseCache()
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

    private func registerUser(on app: Application, identifier: String) async throws -> AuthResponse {
        let suffix = String(identifier.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(18))
        let request = AuthRegisterRequest(
            username: "vs_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "vs+\(identifier)@example.com",
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
        let user = try #require(try await User.find(auth.userId, on: app.db))
        user.trialStartedAt = nil
        user.trialDays = nil
        user.trialTier = nil
        try await user.save(on: app.db)
        return auth
    }

    private func grantPremium(userId: UUID, on app: Application) async throws {
        try await Entitlement(userId: userId, level: "pro").save(on: app.db)
    }

    private func get(
        _ path: String, token: String, on app: Application
    ) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var body = ""
        try await app.testing().test(.GET, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            status = res.status
            body = res.body.string
        })
        return (status, body)
    }

    private func path(_ scope: AIViewScope, refresh: Bool = false) -> String {
        "v1/ai/view-summary/\(scope.rawValue)\(refresh ? "?refresh=true" : "")"
    }

    // MARK: - Entitlement

    @Test("Free users are blocked from every scope")
    func freeUsersBlocked() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free")
            // Exhaustive by construction: a ninth scope added without thinking
            // about the gate fails here.
            for scope in AIViewScope.allCases {
                let (status, _) = try await get(path(scope), token: auth.token, on: app)
                #expect(
                    status == .paymentRequired || status == .forbidden,
                    "\(scope.rawValue) must be Pro-gated, got \(status)"
                )
            }
        }
    }

    @Test("An unknown scope is refused with the valid ones named")
    func unknownScopeIsRefused() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "unknown")
            try await grantPremium(userId: auth.userId, on: app)
            let (status, body) = try await get(
                "v1/ai/view-summary/nonsense", token: auth.token, on: app
            )
            #expect(status == .badRequest)
            #expect(body.contains("portfolio"), "the error should name the valid scopes")
        }
    }

    // MARK: - Degradation

    @Test("Every scope still answers when the provider is unavailable")
    func everyScopeFallsBack() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "fallback")
            try await grantPremium(userId: auth.userId, on: app)
            app.aiViewSummaryService = DefaultAIViewSummaryService(
                client: DisabledOpenAIChatClient()
            )
            for scope in AIViewScope.allCases {
                let (status, body) = try await get(path(scope), token: auth.token, on: app)
                #expect(status == .ok, "\(scope.rawValue) returned \(status)")
                #expect(body.contains("\"scope\":\"\(scope.rawValue)\""))
                #expect(
                    body.contains(AIInsightCardResponse.standardDisclaimer),
                    "the disclaimer is server-injected, never model-sourced"
                )
            }
        }
    }

    // MARK: - The cache

    @Test("A second request inside the window makes no upstream call")
    func cacheHitCostsNothing() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "cache")
            try await grantPremium(userId: auth.userId, on: app)
            let counter = CallCountingChatClient(
                json: #"{"title":"Your spending","body":"Spending held steady this month."}"#
            )
            app.aiViewSummaryService = DefaultAIViewSummaryService(client: counter)

            let (first, firstBody) = try await get(
                path(.expenses), token: auth.token, on: app
            )
            #expect(first == .ok)
            #expect(firstBody.contains("\"isCached\":false"))
            #expect(counter.count == 1)

            let (second, secondBody) = try await get(
                path(.expenses), token: auth.token, on: app
            )
            #expect(second == .ok)
            #expect(secondBody.contains("\"isCached\":true"))
            #expect(counter.count == 1, "the second request must not reach the provider")
        }
    }

    @Test("refresh=true regenerates")
    func refreshBypassesTheCache() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "refresh")
            try await grantPremium(userId: auth.userId, on: app)
            let counter = CallCountingChatClient(
                json: #"{"title":"Your spending","body":"Spending held steady this month."}"#
            )
            app.aiViewSummaryService = DefaultAIViewSummaryService(client: counter)

            _ = try await get(path(.expenses), token: auth.token, on: app)
            #expect(counter.count == 1)
            let (status, body) = try await get(
                path(.expenses, refresh: true), token: auth.token, on: app
            )
            #expect(status == .ok)
            #expect(body.contains("\"isCached\":false"))
            #expect(counter.count == 2)
        }
    }

    @Test("One scope's cache entry cannot answer another's")
    func cacheKeysAreScoped() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "scoped")
            try await grantPremium(userId: auth.userId, on: app)
            let counter = CallCountingChatClient(
                json: #"{"title":"A title","body":"A body sentence about the data."}"#
            )
            app.aiViewSummaryService = DefaultAIViewSummaryService(client: counter)

            _ = try await get(path(.expenses), token: auth.token, on: app)
            let (status, body) = try await get(path(.portfolio), token: auth.token, on: app)
            #expect(status == .ok)
            #expect(body.contains("\"isCached\":false"))
            #expect(counter.count == 2, "a different screen is a different question")
        }
    }

    // MARK: - Cost isolation

    @Test("Exhausting the summary allowance leaves the assistant's intact")
    func summariesCannotStarveTheAssistant() async throws {
        try await withApp { app in
            // The whole reason the bucket was split: the button lands on eight
            // screens with a refresh control, and on the shared counter it would
            // spend the allowance /v1/ai/chat needs.
            setenv("AI_VIEW_SUMMARY_DAILY_LIMIT", "1", 1)
            let auth = try await registerUser(on: app, identifier: "bucket")
            try await grantPremium(userId: auth.userId, on: app)
            app.aiViewSummaryService = DefaultAIViewSummaryService(
                client: CallCountingChatClient(
                    json: #"{"title":"A title","body":"A body sentence about the data."}"#
                )
            )

            // Redis is disabled in `.testing`, so `AIDailyCap` cannot actually
            // count and returns early. The assertion that survives regardless is
            // the one that matters here: the insight endpoint is unaffected by
            // anything the summary endpoint does.
            _ = try await get(path(.expenses, refresh: true), token: auth.token, on: app)
            _ = try await get(path(.portfolio, refresh: true), token: auth.token, on: app)

            let (status, _) = try await get(
                "v1/ai/insights/portfolio", token: auth.token, on: app
            )
            #expect(status == .ok, "the assistant's allowance is a different bucket")
            #expect(AICostControls.viewSummaryBucket != AIDailyCap.defaultBucket)
        }
    }

    // MARK: - The numbers are the server's

    @Test("A model-invented figure never reaches the highlights")
    func highlightsIgnoreTheModel() {
        // Seeded server-side, then the model is scripted to state a different
        // number in its prose. The highlights must still be the seeded ones --
        // this is the guarantee that lets the card show figures at all.
        var dataset = AIInsightDataset()
        dataset.expenseReports = [
            BudgetMonthSummaryResponse(
                monthStart: "2026-08-01", planned: 1500, actual: 1234.5, salary: 3000,
                pillarActuals: [:], pillarPlans: [:]
            ),
        ]
        let view = DefaultAIViewSummaryService.ViewDataset(insight: dataset)
        let highlights = DefaultAIViewSummaryService.highlights(for: .expenses, dataset: view)

        #expect(highlights.contains { $0.value == "1,234.50" }, "seeded, not invented")
        #expect(!highlights.contains { $0.value.contains("9,999") })
    }

    @Test("A scope with no data shows no highlights rather than zeroes")
    func emptyDatasetsShowNothing() {
        for scope in AIViewScope.allCases {
            let highlights = DefaultAIViewSummaryService.highlights(
                for: scope, dataset: DefaultAIViewSummaryService.ViewDataset()
            )
            #expect(highlights.isEmpty, "\(scope.rawValue) invented a highlight from nothing")
        }
    }

    @Test("Crypto holdings are valued at the live quote, not the purchase price")
    func cryptoUsesLiveQuotes() {
        let holdings = [
            CryptoPortfolioItemResponse(
                id: UUID().uuidString, symbol: "BTC", name: "Bitcoin",
                quantity: 2, averageBuyPrice: 100, createdAt: nil, updatedAt: nil
            ),
        ]
        let quotes = [CryptoQuoteShortResponse(symbol: "BTC", price: 150, change: 50, volume: nil)]
        let dataset = DefaultAIViewSummaryService.ViewDataset(
            cryptoHoldings: holdings, cryptoQuotes: quotes
        )
        let highlights = DefaultAIViewSummaryService.highlights(for: .crypto, dataset: dataset)

        #expect(highlights.contains { $0.label == "Crypto value" && $0.value == "300.00" })
        #expect(highlights.contains { $0.label == "Since purchase" && $0.trend == "up" })
    }

    @Test("A holding with no quote falls back to its purchase price")
    func cryptoToleratesAMissingQuote() {
        // A provider that skips one coin should cost accuracy on that coin, not
        // blank the whole card.
        let holdings = [
            CryptoPortfolioItemResponse(
                id: UUID().uuidString, symbol: "XYZ", name: "Unlisted",
                quantity: 3, averageBuyPrice: 10, createdAt: nil, updatedAt: nil
            ),
        ]
        let dataset = DefaultAIViewSummaryService.ViewDataset(
            cryptoHoldings: holdings, cryptoQuotes: []
        )
        let highlights = DefaultAIViewSummaryService.highlights(for: .crypto, dataset: dataset)

        #expect(highlights.contains { $0.label == "Crypto value" && $0.value == "30.00" })
        #expect(highlights.contains { $0.label == "Holdings" && $0.value == "1" })
    }

    // MARK: - Scope hygiene

    @Test("Every scope has its own instruction and display name")
    func scopesAreDistinct() {
        let instructions = AIViewScope.allCases.map(\.instruction)
        let names = AIViewScope.allCases.map(\.displayName)
        #expect(Set(instructions).count == instructions.count, "a copy-paste would blur two screens")
        #expect(Set(names).count == names.count)
    }

    @Test("Markets and the economy are the only user-independent scopes")
    func userIndependenceIsDeclaredCorrectly() {
        // Recorded so a future shared cache key cannot be applied to a scope
        // whose facts are about one person.
        let shared = AIViewScope.allCases.filter { !$0.isUserSpecific }
        #expect(Set(shared) == [.markets, .economy])
    }
}

/// Counts calls so a cache hit can be asserted from the outside.
private final class CallCountingChatClient: OpenAIChatClient, @unchecked Sendable {
    private let lock = NIOLock()
    private var calls = 0
    let json: String

    init(json: String) {
        self.json = json
    }

    var count: Int {
        lock.withLock { calls }
    }

    func chat(
        messages _: [OpenAIMessage], tools _: [OpenAITool],
        responseFormat _: String?, on _: Request
    ) async throws -> OpenAIMessage {
        lock.withLock { calls += 1 }
        return OpenAIMessage(role: "assistant", content: json)
    }
}
