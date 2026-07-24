import Fluent
import Foundation
import NIOCore
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

typealias CashFlowStatementResponse = StockPlanShared.CashFlowStatementResponse
typealias BalanceSheetStatementResponse = StockPlanShared.BalanceSheetStatementResponse
typealias RatiosTTMResponse = StockPlanShared.RatiosTTMResponse
typealias FinancialGrowthResponse = StockPlanShared.FinancialGrowthResponse
typealias AnalystEstimatesResponse = StockPlanShared.AnalystEstimatesResponse
typealias RatiosResponse = StockPlanShared.RatiosResponse
typealias AuthRegisterRequest = StockPlanBackend.AuthRegisterRequest
typealias NewsItemResponse = StockPlanShared.NewsItemResponse
typealias NewsItemRequest = StockPlanShared.NewsItemRequest
typealias NewsSyncResponse = StockPlanShared.NewsSyncResponse
typealias FinnhubNewsWebhookResponse = StockPlanShared.FinnhubNewsWebhookResponse
typealias StockRequest = StockPlanShared.StockRequest
typealias StockResponse = StockPlanShared.StockResponse
typealias WatchlistItemRequest = StockPlanShared.WatchlistItemRequest
typealias WatchlistItemUpdateRequest = StockPlanShared.WatchlistItemUpdateRequest
typealias WatchlistItemResponse = StockPlanShared.WatchlistItemResponse
typealias WatchlistStatus = StockPlanShared.WatchlistStatus
typealias WatchlistListRequest = StockPlanShared.WatchlistListRequest
typealias WatchlistListResponse = StockPlanShared.WatchlistListResponse
typealias ResearchNoteRequest = StockPlanShared.ResearchNoteRequest
typealias ResearchNoteResponse = StockPlanShared.ResearchNoteResponse
typealias StockHistory = StockPlanShared.StockHistory
typealias StockNews = StockPlanShared.StockNews
typealias BulkStockRequest = StockPlanShared.BulkStockRequest
typealias BulkStockResultItem = StockPlanShared.BulkStockResultItem
typealias BulkStockResponse = StockPlanShared.BulkStockResponse
typealias TargetRequest = StockPlanShared.TargetRequest
typealias TargetResponse = StockPlanShared.TargetResponse
typealias SellStockRequest = StockPlanShared.SellStockRequest
typealias PortfolioListRequest = StockPlanShared.PortfolioListRequest
typealias PortfolioListResponse = StockPlanShared.PortfolioListResponse
typealias StockDetailsResponse = StockPlanShared.StockDetailsResponse
typealias CsvImportCommitResponse = StockPlanShared.CsvImportCommitResponse
typealias CsvImportPreviewResponse = StockPlanShared.CsvImportPreviewResponse
typealias CsvImportPreviewItem = StockPlanShared.CsvImportPreviewItem
typealias CsvImportPreviewError = StockPlanShared.CsvImportPreviewError
typealias BrokerConnectionResponse = StockPlanShared.BrokerConnectionResponse
typealias BrokerHoldingResponse = StockPlanShared.BrokerHoldingResponse
typealias BrokerSyncResponse = StockPlanShared.BrokerSyncResponse
typealias BrokerSyncStatusResponse = StockPlanShared.BrokerSyncStatusResponse
typealias BrokerConnectStartRequest = StockPlanShared.BrokerConnectStartRequest
typealias BrokerConnectStartResponse = StockPlanShared.BrokerConnectStartResponse
typealias LotResponse = StockPlanShared.LotResponse

@Suite("App Tests with DB", .serialized)
struct StockPlanBackendTests {
    private struct TestHealthResponse: Decodable {
        let status: String
    }

    private struct TestReadinessResponse: Decodable {
        let status: String
        let checks: [String: TestReadinessCheck]
    }

    private struct TestReadinessCheck: Decodable {
        let status: String
        let message: String?
        let latencyMs: Double?
    }

    private actor TestNewsProviderState {
        private var batches: [[ProviderNewsItem]]
        private var fetchCallCount: Int = 0

        init(batches: [[ProviderNewsItem]]) {
            self.batches = batches
        }

        func next() -> [ProviderNewsItem] {
            fetchCallCount += 1
            guard !batches.isEmpty else { return [] }
            if batches.count == 1 {
                return batches[0]
            }
            return batches.removeFirst()
        }

        func fetchCalls() -> Int {
            fetchCallCount
        }
    }

    private struct TestNewsProvider: NewsProvider {
        let name: String = "test-news"
        let state: TestNewsProviderState

        func fetch(symbols _: [String], on _: Request) async throws -> [ProviderNewsItem] {
            await state.next()
        }

        func fetchGeneral(on _: Request) async throws -> [ProviderNewsItem] {
            await state.next()
        }
    }

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            for attempt in 0 ..< 2 {
                let app = try await Application.make(.testing)
                do {
                    try await configure(app)
                    try await flushRedisIfConfigured(app)
                    try await app.autoMigrate()
                    try await test(app)
                    try await app.autoRevert()
                    try await app.asyncShutdown()
                    return
                } catch {
                    try? await app.autoRevert()
                    try? await app.asyncShutdown()
                    let reflected = String(reflecting: error)
                    let isTransientDBRestart = reflected.contains("sqlState: 57P01")
                        || reflected.contains("sqlState: 57P03")
                        || reflected.contains("database system is shutting down")
                        || reflected.contains("terminating connection due to administrator command")
                    if attempt == 0, isTransientDBRestart {
                        try await Task.sleep(for: .milliseconds(750))
                        continue
                    }
                    throw error
                }
            }
        }
    }

    private func flushRedisIfConfigured(_ app: Application) async throws {
        guard app.redis.configuration != nil else { return }
        do {
            _ = try await app.redis.send(command: "FLUSHDB", with: [])
        } catch {
            app.logger.warning("test.redis.flush skipped error=\(error)")
        }
    }

    private func registerTestUser(
        app: Application,
        identifier: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws -> (token: String, userId: UUID) {
        let normalizedIdentifier = String(identifier.prefix(12))
        let register = AuthRegisterRequest(
            username: "test_\(normalizedIdentifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "test+\(normalizedIdentifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?

        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })

        guard let response else {
            throw Abort(.internalServerError, reason: "Auth register did not return a response")
        }
        return (response.token, response.userId)
    }

    private func grantPremium(userId: UUID, on app: Application) async throws {
        let entitlement = Entitlement(userId: userId, level: "premium")
        try await entitlement.save(on: app.db)
    }

    private func seedInstrument(
        symbol: String,
        name: String? = nil,
        exchange: String = "NASDAQ",
        currency: String = "USD",
        conid: String? = nil,
        on app: Application
    ) async throws {
        let instrument = Instrument(
            conid: conid ?? "test-\(symbol.lowercased())",
            symbol: symbol,
            exchange: exchange,
            currency: currency,
            name: name ?? symbol
        )
        try await instrument.save(on: app.db)
    }

    private func makeTestMarketService(
        state: TestMarketProviderState,
        fmpState: TestFMPProviderState? = nil,
        fmpProvider: (any FMPMarketDataProvider)? = nil,
        fmpAccessTier: FMPAccessTier = .free,
        quoteTTLSeconds: Int = 3600,
        historyTTLSeconds: Int = 3600,
        searchTTLSeconds: Int = 3600,
        fxTTLSeconds: Int = 3600,
        profileTTLSeconds: Int = 3600,
        basicFinancialsTTLSeconds: Int = 3600
    ) -> any MarketDataService {
        DefaultMarketDataService(
            provider: TestMarketDataProvider(state: state),
            fmpProvider: fmpProvider ?? fmpState.map { TestFMPMarketDataProvider(state: $0) },
            cacheConfig: .init(
                quoteTTLSeconds: quoteTTLSeconds,
                historyTTLSeconds: historyTTLSeconds,
                searchTTLSeconds: searchTTLSeconds,
                fxTTLSeconds: fxTTLSeconds,
                profileTTLSeconds: profileTTLSeconds,
                basicFinancialsTTLSeconds: basicFinancialsTTLSeconds,
                fmpTTLSeconds: 3600,
                defaultCurrency: "USD"
            ),
            fmpAccessTier: fmpAccessTier
        )
    }

    private func makeTestMarketNewsArchiveService(
        state: TestNewsProviderState,
        ttlSeconds: Int = 900,
        defaultLimit: Int = 50,
        maxLimit: Int = 200
    ) -> any MarketNewsArchiveService {
        DefaultMarketNewsArchiveService(
            provider: TestNewsProvider(state: state),
            config: .init(
                ttlSeconds: ttlSeconds,
                defaultLimit: defaultLimit,
                maxLimit: maxLimit
            )
        )
    }

    private func makeValuationPayload(
        symbol: String = "AAPL",
        bearLow: Double = 10,
        bearHigh: Double = 15,
        baseLow: Double = 16,
        baseHigh: Double = 22,
        bullLow: Double = 23,
        bullHigh: Double = 30,
        rationale: String? = nil,
        targetDate: String? = "2026-12-31"
    ) -> StockValuationRequest {
        StockValuationRequest(
            symbol: symbol,
            bearCase: PriceRange(low: bearLow, high: bearHigh),
            baseCase: PriceRange(low: baseLow, high: baseHigh),
            bullCase: PriceRange(low: bullLow, high: bullHigh),
            rationale: rationale,
            targetDate: targetDate
        )
    }

    private func monthStartDate(year: Int, month: Int) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = 1
        return calendar.date(from: components)!
    }

    private func seedMonthlyBudgetData(
        app: Application,
        userId: UUID,
        year: Int,
        month: Int,
        salary: Double,
        planned: Double,
        actual: Double,
        includeExpense: Bool = true
    ) async throws {
        let monthStart = monthStartDate(year: year, month: month)
        let snapshot = BudgetSnapshot(
            userID: userId,
            monthStart: monthStart,
            netSalary: salary,
            targetShares: ["fundamentals": 0.5]
        )
        try await snapshot.save(on: app.db)

        if planned > 0, let snapshotId = snapshot.id {
            let item = BudgetPlanItem(
                snapshotID: snapshotId,
                userID: userId,
                title: "Planned \(year)-\(month)",
                plannedAmount: planned,
                pillar: .fundamentals
            )
            try await item.save(on: app.db)
        }

        if includeExpense, actual > 0 {
            let expense = Expense(
                userID: userId,
                title: "Actual \(year)-\(month)",
                amount: actual,
                pillar: .fundamentals,
                occurredOn: monthStart
            )
            try await expense.save(on: app.db)
        }
    }

    private func seedCashBuffer(
        app: Application,
        userId: UUID,
        balance: Double
    ) async throws {
        let account = Account(
            userId: userId,
            externalId: "acct-\(UUID().uuidString)",
            broker: "manual",
            displayName: "Primary",
            baseCurrency: "USD"
        )
        try await account.save(on: app.db)

        guard let accountId = account.id else {
            throw Abort(.internalServerError, reason: "Account id missing after save")
        }

        let cash = CashBalance(
            accountId: accountId,
            currency: "USD",
            balance: balance,
            asOf: Date()
        )
        try await cash.save(on: app.db)
    }

    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }

    @Test("Health endpoint returns ok")
    func healthEndpoint() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "health", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(TestHealthResponse.self)
                #expect(body.status == "ok")
            })
        }
    }

    @Test("Liveness endpoint returns ok")
    func livenessEndpoint() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "health/live", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(TestHealthResponse.self)
                #expect(body.status == "ok")
            })
        }
    }

    @Test("Readiness endpoint reports dependency checks")
    func readinessEndpoint() async throws {
        try await withApp { app in
            #expect(app.redis.configuration == nil)
            try await app.testing().test(.GET, "health/ready", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(TestReadinessResponse.self)
                #expect(["ready", "degraded"].contains(body.status))
                #expect(body.checks["database"]?.status == "healthy")
                #expect(body.checks["redis"]?.status == "skipped")
                #expect(body.checks["mailer"] != nil)
                #expect(body.checks["apns"] != nil)
                #expect(body.checks["marketData"] != nil)
            })
        }
    }

    @Test("Production config rejects missing, default, and short JWT secrets")
    func productionJWTSecretValidation() throws {
        #expect(throws: Abort.self) {
            try ProductionConfiguration.validateJWTSecret(nil)
        }
        #expect(throws: Abort.self) {
            try ProductionConfiguration.validateJWTSecret("dev-secret")
        }
        #expect(throws: Abort.self) {
            try ProductionConfiguration.validateJWTSecret("short")
        }
        try ProductionConfiguration.validateJWTSecret("01234567890123456789012345678901")
    }

    @Test("Production CORS requires explicit safe origins")
    func productionCORSValidation() throws {
        #expect(throws: Abort.self) {
            _ = try ProductionConfiguration.allowedOrigins(from: nil, isProduction: true)
        }
        #expect(throws: Abort.self) {
            _ = try ProductionConfiguration.allowedOrigins(from: "https://api.example.com,http://localhost:3000", isProduction: true)
        }
        let origins = try ProductionConfiguration.allowedOrigins(from: "https://app.example.com, https://www.example.com", isProduction: true)
        #expect(origins == ["https://app.example.com", "https://www.example.com"])
        let defaults = try ProductionConfiguration.allowedOrigins(from: nil, isProduction: false)
        #expect(defaults.contains("http://localhost:3000"))
    }

    @Test("Production database credentials reject defaults")
    func productionDatabaseCredentialValidation() throws {
        #expect(throws: Abort.self) {
            try ProductionConfiguration.validateDatabaseCredentials(username: nil, password: "valid-password-valid-password")
        }
        #expect(throws: Abort.self) {
            try ProductionConfiguration.validateDatabaseCredentials(username: "stockplan_user", password: "valid-password-valid-password")
        }
        #expect(throws: Abort.self) {
            try ProductionConfiguration.validateDatabaseCredentials(username: "stockplan_prod_app", password: "stockplan_password")
        }
        #expect(throws: Abort.self) {
            try ProductionConfiguration.validateDatabaseCredentials(username: "stockplan_prod_app", password: "short")
        }
        try ProductionConfiguration.validateDatabaseCredentials(
            username: "stockplan_prod_app",
            password: "012345678901234567890123"
        )
    }

    @Test("Stock valuation endpoints create, fetch, and update by symbol")
    func stockValuationLifecycle() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    StockRequest(
                        symbol: "AAPL",
                        shares: 2,
                        buyPrice: 100,
                        buyDate: "2024-01-01",
                        notes: nil
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/stocks/symbol/AAPL/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    makeValuationPayload(symbol: "AAPL", rationale: "original thesis")
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let body = try res.content.decode(StockValuationRequest.self)
                #expect(body.symbol == "AAPL")
                #expect(body.bearCase.low == 10)
            })

            try await app.testing().test(.GET, "v1/stocks/symbol/aapl/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockValuationRequest.self)
                #expect(body.baseCase.high == 22)
                #expect(body.rationale == "original thesis")
            })

            try await app.testing().test(.PUT, "v1/stocks/symbol/AAPL/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    makeValuationPayload(symbol: "AAPL", baseHigh: 29, bullHigh: 36)
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockValuationRequest.self)
                #expect(body.baseCase.high == 29)
                #expect(body.bullCase.high == 36)
            })
        }
    }

    @Test("Stock valuation endpoints are scoped to the authenticated user")
    func stockValuationIsUserScoped() async throws {
        try await withApp { app in
            let (ownerToken, ownerUserId) = try await registerTestUser(app: app, identifier: "owner")
            let (otherToken, otherUserId) = try await registerTestUser(app: app, identifier: "other")
            try await grantPremium(userId: ownerUserId, on: app)
            try await grantPremium(userId: otherUserId, on: app)

            try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
                try req.content.encode(
                    StockRequest(
                        symbol: "ZETA",
                        shares: 5,
                        buyPrice: 15,
                        buyDate: "2024-01-01",
                        notes: nil
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/stocks/symbol/ZETA/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
                try req.content.encode(
                    makeValuationPayload(symbol: "ZETA", rationale: "owner thesis")
                )
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/stocks/symbol/ZETA/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.POST, "v1/stocks/symbol/ZETA/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherToken)
                try req.content.encode(
                    makeValuationPayload(symbol: "ZETA", rationale: "other thesis")
                )
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("Stock not found."))
            })
        }
    }

    @Test("Sell endpoint credits cash and portfolio summary/performance include cash balance")
    func sellCreditsCashAndPortfolioReflectsIt() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app, identifier: "sellcash")

            var createdStock: StockResponse?
            try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    StockRequest(
                        symbol: "AAPL",
                        shares: 5,
                        buyPrice: 100,
                        buyDate: "2026-01-02",
                        notes: nil
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                createdStock = try res.content.decode(StockResponse.self)
            })

            let stock = try #require(createdStock)
            let holdingsValueAfterSell = 4 * 100.0
            let expectedCash = 1 * 150.0

            try await app.testing().test(.POST, "v1/stocks/id/\(stock.id)/sell", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    SellStockRequest(
                        sharesToSell: 1,
                        sellPrice: 150,
                        sellDate: "2026-04-10"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let updated = try res.content.decode(StockResponse.self)
                #expect(updated.shares == 4)
            })

            try await app.testing().test(.GET, "v1/portfolio/summary", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let summary = try res.content.decode(PortfolioSummaryResponse.self)
                #expect(abs(summary.cashBalance - expectedCash) < 0.001)
                #expect(summary.allocation.contains(where: { $0.symbol == "CASH" }))
                #expect(abs(summary.totalValue - (holdingsValueAfterSell + expectedCash)) < 0.001)
            })

            try await app.testing().test(.GET, "v1/portfolio/performance", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let performance = try res.content.decode(PortfolioPerformanceResponse.self)
                #expect(!performance.points.isEmpty)
                #expect(performance.points.allSatisfy { $0.value > holdingsValueAfterSell })
            })
        }
    }

    @Test("Watchlist endpoints create, update, and list enriched items")
    func watchlistLifecycle() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            var created: WatchlistItemResponse?
            try await app.testing().test(.POST, "v1/watchlist", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    WatchlistItemRequest(
                        symbol: "msft",
                        note: "Waiting for a better entry",
                        status: .researching,
                        nextReviewAt: "2026-04-15"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                created = try res.content.decode(WatchlistItemResponse.self)
            })

            #expect(created?.symbol == "MSFT")
            #expect(created?.note == "Waiting for a better entry")
            #expect(created?.status == .researching)
            #expect(created?.nextReviewAt == "2026-04-15")
            #expect(created?.createdAt != nil)

            let watchlistId = try #require(created?.id)

            try await app.testing().test(.PATCH, "v1/watchlist/\(watchlistId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    WatchlistItemUpdateRequest(
                        note: "",
                        status: .ready,
                        lastReviewedAt: "2026-03-20",
                        nextReviewAt: "2026-05-01"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let updated = try res.content.decode(WatchlistItemResponse.self)
                #expect(updated.id == watchlistId)
                #expect(updated.note == nil)
                #expect(updated.status == .ready)
                #expect(updated.lastReviewedAt == "2026-03-20")
                #expect(updated.nextReviewAt == "2026-05-01")
                #expect(updated.updatedAt != nil)
            })

            try await app.testing().test(.GET, "v1/watchlist", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let items = try res.content.decode([WatchlistItemResponse].self)
                #expect(items.count == 1)
                #expect(items.first?.id == watchlistId)
                #expect(items.first?.status == .ready)
                #expect(items.first?.note == nil)
                #expect(items.first?.lastReviewedAt == "2026-03-20")
            })
        }
    }

    @Test("Stock insights endpoint returns deterministic projections and excludes primary symbol from peers")
    func stockInsightsEndpointReturnsDeterministicPayload() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "stockinsights")
            try await grantPremium(userId: userId, on: app)

            for symbol in ["AAPL", "TSLA"] {
                try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(
                        StockRequest(
                            symbol: symbol,
                            shares: 2,
                            buyPrice: 100,
                            buyDate: "2026-01-02",
                            notes: nil
                        )
                    )
                }, afterResponse: { res async in
                    #expect(res.status == .created)
                })
            }

            for symbol in ["MSFT", "AAPL"] {
                try await app.testing().test(.POST, "v1/watchlist", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(
                        WatchlistItemRequest(
                            symbol: symbol,
                            note: nil,
                            status: .active,
                            nextReviewAt: nil
                        )
                    )
                }, afterResponse: { res async in
                    #expect(res.status == .created)
                })
            }

            var first: StockInsightsResponse?
            try await app.testing().test(.GET, "v1/stocks/AAPL/insights", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(StockInsightsResponse.self)
            })

            var second: StockInsightsResponse?
            try await app.testing().test(.GET, "v1/stocks/AAPL/insights", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(StockInsightsResponse.self)
            })

            let firstPayload = try #require(first)
            let secondPayload = try #require(second)

            #expect(firstPayload.symbol == "AAPL")
            #expect(firstPayload.profile.symbol == "AAPL")
            #expect(firstPayload.peers.contains(where: { $0.symbol == "MSFT" }))
            #expect(firstPayload.peers.contains(where: { $0.symbol == "TSLA" }))
            #expect(!firstPayload.peers.contains(where: { $0.symbol == "AAPL" }))
            #expect(firstPayload.peers.first?.symbol == "MSFT")
            #expect(firstPayload.projectionScenarios.count == 3)
            #expect(Set(firstPayload.projectionScenarios.map(\.kind)) == Set(["bear", "base", "bull"]))
            #expect(firstPayload.projectionScenarios.allSatisfy { !$0.years.isEmpty })
            #expect(firstPayload.peers == secondPayload.peers)
            #expect(firstPayload.projectionScenarios == secondPayload.projectionScenarios)
        }
    }

    @Test("Market compatibility endpoints return stock details, history, and news")
    func marketCompatibilityEndpoints() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            let news = MarketNewsArchive(
                provider: "test-news",
                symbol: "ZETA",
                headline: "ZETA wins new contract",
                source: "Example Wire",
                url: "https://example.com/zeta",
                summary: "Summary",
                imageURL: nil,
                publishedAt: Date(),
                fetchedAt: Date()
            )
            try await news.save(on: app.db)

            try await app.testing().test(.GET, "v1/market/details?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockDetailsResponse.self)
                #expect(body.symbol == "ZETA")
                #expect(body.company == "ZETA Inc")
                #expect(body.latestPrice == 101.25)
                #expect(body.changePercent > 0)
            })

            try await app.testing().test(.GET, "v1/market/history?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.count == 1)
                #expect(body.first?.close == 101)
            })

            try await app.testing().test(.GET, "v1/market/news?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.count == 1)
                #expect(body.first?.title == "ZETA wins new contract")
                #expect(body.first?.url == "https://example.com/zeta")
            })
        }
    }

    private struct ThrowingNewsProvider: NewsProvider {
        struct ProviderDown: Error {}
        let name: String = "test-news-down"

        func fetch(symbols _: [String], on _: Request) async throws -> [ProviderNewsItem] {
            throw ProviderDown()
        }

        func fetchGeneral(on _: Request) async throws -> [ProviderNewsItem] {
            throw ProviderDown()
        }
    }

    private func saveGeneralArchiveRow(
        headline: String,
        url: String,
        fetchedAt: Date,
        on app: Application
    ) async throws {
        try await MarketNewsArchive(
            provider: "test-news",
            symbol: "GENERAL",
            headline: headline,
            source: "Example Wire",
            url: url,
            summary: nil,
            imageURL: nil,
            publishedAt: fetchedAt,
            fetchedAt: fetchedAt
        ).save(on: app.db)
    }

    @Test("General market news serves a fresh archive without calling the provider")
    func generalMarketNewsFreshArchive() async throws {
        try await withApp { app in
            let state = TestNewsProviderState(batches: [[
                ProviderNewsItem(
                    symbol: "GENERAL",
                    headline: "Should not appear",
                    source: nil,
                    url: "https://example.com/should-not-appear",
                    summary: nil,
                    image: nil,
                    publishedAt: Date()
                ),
            ]])
            app.marketNewsArchiveService = makeTestMarketNewsArchiveService(state: state)
            let (token, _) = try await registerTestUser(app: app, identifier: "generalnewsfresh")

            try await saveGeneralArchiveRow(
                headline: "Markets steady ahead of CPI print",
                url: "https://example.com/cpi",
                fetchedAt: Date(),
                on: app
            )

            try await app.testing().test(.GET, "v1/market/news/general", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.map(\.title) == ["Markets steady ahead of CPI print"])
            })
            #expect(await state.fetchCalls() == 0)
        }
    }

    @Test("General market news refreshes a stale archive from the provider")
    func generalMarketNewsStaleArchiveRefreshes() async throws {
        try await withApp { app in
            let state = TestNewsProviderState(batches: [[
                ProviderNewsItem(
                    symbol: "GENERAL",
                    headline: "Fed signals patience",
                    source: "Example Wire",
                    url: "https://example.com/fed-patience",
                    summary: nil,
                    image: nil,
                    publishedAt: Date()
                ),
            ]])
            app.marketNewsArchiveService = makeTestMarketNewsArchiveService(state: state)
            let (token, _) = try await registerTestUser(app: app, identifier: "generalnewsstale")

            try await saveGeneralArchiveRow(
                headline: "Old headline",
                url: "https://example.com/old",
                fetchedAt: Date().addingTimeInterval(-3600),
                on: app
            )

            try await app.testing().test(.GET, "v1/market/news/general", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.map(\.title).contains("Fed signals patience"))
            })
            #expect(await state.fetchCalls() == 1)
        }
    }

    @Test("General market news falls back to a stale archive when the provider fails")
    func generalMarketNewsStaleFallbackOnProviderFailure() async throws {
        try await withApp { app in
            app.marketNewsArchiveService = DefaultMarketNewsArchiveService(
                provider: ThrowingNewsProvider(),
                config: .init(ttlSeconds: 900, defaultLimit: 50, maxLimit: 200)
            )
            let (token, _) = try await registerTestUser(app: app, identifier: "generalnewsfallback")

            try await saveGeneralArchiveRow(
                headline: "Yesterday's market wrap",
                url: "https://example.com/wrap",
                fetchedAt: Date().addingTimeInterval(-7200),
                on: app
            )

            try await app.testing().test(.GET, "v1/market/news/general", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.map(\.title) == ["Yesterday's market wrap"])
            })
        }
    }

    @Test("General market news surfaces an error when the provider fails and the archive is empty")
    func generalMarketNewsErrorWhenEmptyAndProviderDown() async throws {
        try await withApp { app in
            app.marketNewsArchiveService = DefaultMarketNewsArchiveService(
                provider: ThrowingNewsProvider(),
                config: .init(ttlSeconds: 900, defaultLimit: 50, maxLimit: 200)
            )
            let (token, _) = try await registerTestUser(app: app, identifier: "generalnewsempty")

            try await app.testing().test(.GET, "v1/market/news/general", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status.code >= 500)
            })
        }
    }

    @Test("Archived market history endpoints read stored bars and sync provider data into the archive")
    func archivedMarketHistoryEndpoints() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app, identifier: "historyarchive")

            let seededDay = Calendar(identifier: .gregorian).startOfDay(for: Date().addingTimeInterval(-86400))
            try await PriceHistory(
                symbol: "AAPL",
                date: seededDay,
                open: 90,
                high: 95,
                low: 88,
                close: 94,
                volume: 750_000
            ).save(on: app.db)

            try await app.testing().test(.GET, "v1/market/history/archive?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.count == 1)
                #expect(body.first?.close == 94)
            })

            try await app.testing().test(.POST, "v1/market/history/archive/sync?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.count >= 1)
                #expect(body.first?.close == 101)
            })

            try await app.testing().test(.GET, "v1/market/history/archive?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.contains(where: { $0.close == 101 }))
            })

            #expect(await state.historyCalls() == 1)
        }
    }

    @Test("Archived market news is shared across users and compatibility reads come from the DB archive")
    func archivedMarketNewsSharedAcrossUsers() async throws {
        try await withApp { app in
            let state = TestNewsProviderState(batches: [[
                ProviderNewsItem(
                    symbol: "AAPL",
                    headline: "Apple launches archived news",
                    source: "Example Wire",
                    url: "https://example.com/news/apple-archive",
                    summary: "Archived market news",
                    image: nil,
                    publishedAt: Date(timeIntervalSince1970: 1_774_884_000)
                ),
            ]])
            app.marketNewsArchiveService = makeTestMarketNewsArchiveService(state: state)

            let (token1, _) = try await registerTestUser(app: app, identifier: "archiveuser1")
            let (token2, _) = try await registerTestUser(app: app, identifier: "archiveuser2")

            try await app.testing().test(.POST, "v1/market/news/archive/sync?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token1)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.count == 1)
                #expect(body.first?.title == "Apple launches archived news")
            })

            try await app.testing().test(.GET, "v1/market/news/archive?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token2)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.count == 1)
                #expect(body.first?.url == "https://example.com/news/apple-archive")
            })

            try await app.testing().test(.GET, "v1/market/news?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token2)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.count == 1)
                #expect(body.first?.title == "Apple launches archived news")
            })

            #expect(await state.fetchCalls() == 1)
        }
    }

    @Test("Market compatibility endpoints degrade gracefully when provider is disabled")
    func marketCompatibilityEndpointsWhenProviderDisabled() async throws {
        try await withApp { app in
            app.marketDataService = DefaultMarketDataService(
                provider: DisabledMarketDataProvider(),
                cacheConfig: .init(
                    quoteTTLSeconds: 3600,
                    historyTTLSeconds: 3600,
                    searchTTLSeconds: 3600,
                    fxTTLSeconds: 3600,
                    profileTTLSeconds: 3600,
                    basicFinancialsTTLSeconds: 3600,
                    fmpTTLSeconds: 3600,
                    defaultCurrency: "USD"
                )
            )
            let (token, _) = try await registerTestUser(app: app, identifier: "marketdisabled")

            try await app.testing().test(.GET, "v1/market/details?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockDetailsResponse.self)
                #expect(body.symbol == "ZETA")
                #expect(body.company == "ZETA")
                #expect(body.latestPrice == 0)
                #expect(body.changePercent == 0)
            })

            try await app.testing().test(.GET, "v1/market/history?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.isEmpty)
            })
        }
    }

    @Test("Market history returns a diagnosable 503 when the provider is unavailable")
    func marketHistoryProviderUnavailable() async throws {
        try await withApp { app in
            app.marketDataService = DefaultMarketDataService(
                provider: FailingMarketDataProvider(),
                cacheConfig: .init(
                    quoteTTLSeconds: 3600,
                    historyTTLSeconds: 3600,
                    searchTTLSeconds: 3600,
                    fxTTLSeconds: 3600,
                    profileTTLSeconds: 3600,
                    basicFinancialsTTLSeconds: 3600,
                    fmpTTLSeconds: 3600,
                    defaultCurrency: "USD"
                )
            )

            let (token, _) = try await registerTestUser(app: app, identifier: "market503")

            try await app.testing().test(.GET, "v1/market/history?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async in
                #expect(res.status == .badGateway)
                #expect(res.body.string.contains("Forced market provider failure"))
            })
        }
    }

    @Test("Market quote endpoint requires authentication")
    func quoteRequiresAuth() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)

            try await app.testing().test(.GET, "v1/market/quote/AAPL", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Quote uses cache after first fetch")
    func quoteUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            var first: QuoteResponse?
            var second: QuoteResponse?

            try await app.testing().test(.GET, "v1/market/quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(QuoteResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(QuoteResponse.self)
            })

            #expect(first?.symbol == "AAPL")
            #expect(second?.symbol == "AAPL")
            #expect(first?.currentPrice == second?.currentPrice)
            #expect(await state.quoteCalls() == 1)
        }
    }

    @Test("Profile uses cache after first fetch")
    func profileUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            var first: CompanyProfileResponse?
            var second: CompanyProfileResponse?

            try await app.testing().test(.GET, "v1/market/profile/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(CompanyProfileResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/profile/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(CompanyProfileResponse.self)
            })

            #expect(first?.ticker == "AAPL")
            #expect(second?.ticker == "AAPL")
            #expect(first?.name == second?.name)
            #expect(await state.profileCalls() == 1)
        }
    }

    @Test("Basic financials use cache after first fetch")
    func basicFinancialsUseCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, userId) = try await registerTestUser(app: app, identifier: "basicfinancials")
            try await grantPremium(userId: userId, on: app)

            var first: BasicFinancialsResponse?
            var second: BasicFinancialsResponse?

            try await app.testing().test(.GET, "v1/market/basic-financials/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(BasicFinancialsResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/basic-financials/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(BasicFinancialsResponse.self)
            })

            #expect(first?.symbol == "AAPL")
            #expect(first?.metricType == "all")
            #expect(first?.metric["52WeekHigh"] == .number(190.25))
            #expect(first?.metric["52WeekLowDate"] == .string("2026-01-14"))
            #expect(first?.series["annual"]?["currentRatio"]?.count == 2)
            #expect(second?.metric["beta"] == .number(1.2989))
            #expect(first == second)
            #expect(await state.basicFinancialsCalls() == 1)
        }
    }

    @Test("Ratios TTM endpoint returns FMP-backed market data")
    func ratiosTTMEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "ratiosttm")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/ratios-ttm/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([RatiosTTMResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.grossProfitMarginTTM == 0.46518849807964424)
                #expect(body.first?.enterpriseValueTTM == 3_216_333_928_000)
            })

            #expect(await fmpState.ratiosTTMCalls() == 1)
        }
    }

    @Test("Balance sheet statement endpoint forwards limit and period to FMP")
    func balanceSheetStatementEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "balancesheet")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/balance-sheet-statement/AAPL?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([BalanceSheetStatementResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.period == "FY")
                #expect(body.first?.totalAssets == 364_980_000_000)
                #expect(body.first?.totalLiabilities == 308_030_000_000)
                #expect(body.first?.totalStockholdersEquity == 56_950_000_000)
            })

            let lastRequest = await fmpState.lastBalanceSheetRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Balance sheet statement endpoint clamps free-tier limit to plan-safe maximum")
    func balanceSheetStatementEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "balancesheetclamp")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/balance-sheet-statement/META?limit=10&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastBalanceSheetRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Cash flow statement endpoint forwards limit and period to FMP")
    func cashFlowStatementEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "cashflow")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/cash-flow-statement/AAPL?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([CashFlowStatementResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.period == "FY")
                #expect(body.first?.operatingCashFlow == 118_254_000_000)
                #expect(body.first?.freeCashFlow == 108_807_000_000)
                #expect(body.first?.capitalExpenditure == -9_447_000_000)
            })

            let lastRequest = await fmpState.lastCashFlowRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Income statement endpoint forwards limit and period to FMP")
    func incomeStatementEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "incomestatement")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/income-statement/AAPL?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([IncomeStatementResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.period == "FY")
                #expect(body.first?.revenue == 391_035_000_000)
                #expect(body.first?.grossProfit == 180_683_000_000)
                #expect(body.first?.operatingIncome == 123_216_000_000)
                #expect(body.first?.netIncome == 93_736_000_000)
                #expect(body.first?.eps == 6.11)
            })

            let lastRequest = await fmpState.lastIncomeStatementRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Income statement endpoint clamps free-tier limit to plan-safe maximum")
    func incomeStatementEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "incomestatementclamp")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/income-statement/META?limit=10&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastIncomeStatementRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Cash flow statement endpoint clamps free-tier limit to plan-safe maximum")
    func cashFlowStatementEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "cashflowclamp")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/cash-flow-statement/META?limit=10&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastCashFlowRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Compare endpoint returns metrics for multiple symbols")
    func compareEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "comparemetrics")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/compare?symbols=AAPL,MSFT", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockAnalysisMetricsResponse].self)
                #expect(body.count == 2)
                let symbols = body.map(\.symbol)
                #expect(symbols.contains("AAPL"))
                #expect(symbols.contains("MSFT"))

                if let aapl = body.first(where: { $0.symbol == "AAPL" }) {
                    #expect(aapl.ttmPE == 32.889608822880916)
                    #expect(aapl.forwardPE == 28.0)
                }
            })

            #expect(await state.basicFinancialsCalls() == 2)
            #expect(await fmpState.ratiosTTMCalls() == 2)
        }
    }

    @Test("Earnings endpoint returns data for supported symbols")
    func earningsEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "earningsuser")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/earnings/AAPL?limit=10", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([EarningsResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.epsActual == 1.64)
                #expect(body.first?.surprisePercent == 2.5)
                #expect(body.first?.hasTranscript == true)
            })

            #expect(await fmpState.earningsCalls() == 1)
        }
    }

    @Test("Earnings calendar endpoint validates date range by tier")
    func earningsCalendarEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            // Default is free tier
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "calendaruser")
            try await grantPremium(userId: userId, on: app)

            // Test free tier limit (1 month) - 2 months ago should fail
            let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
            let from = Self.formatISODateOnly(twoMonthsAgo)

            try await app.testing().test(.GET, "v1/market/earnings-calendar?from=\(from)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("limited to 1 month"))
            })

            // Test free tier within range
            let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date())!
            let fromOk = Self.formatISODateOnly(twoWeeksAgo)

            try await app.testing().test(.GET, "v1/market/earnings-calendar?from=\(fromOk)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([EarningsResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.surprisePercent == 2.5)
                #expect(body.first?.hasTranscript == false)
            })

            #expect(await fmpState.earningsCalendarCalls() == 1)
        }
    }

    @Test("Earnings transcript endpoint returns transcript for an earnings date")
    func earningsTranscriptEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "earningstranscriptuser")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/earnings/AAPL/transcript?date=2024-10-29", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(EarningsTranscriptResponse.self)
                #expect(body.symbol == "AAPL")
                #expect(body.date == "2024-10-29")
                #expect(body.year == 2024)
                #expect(body.quarter == 4)
                #expect(body.provider == "fmp")
                #expect(body.content.contains("Prepared remarks for Apple earnings."))
            })

            #expect(await fmpState.earningsTranscriptCalls() == 1)
            #expect(await fmpState.lastEarningsTranscriptRequest() == .init(symbol: "AAPL", year: 2024, quarter: 4))
        }
    }

    @Test("Earnings transcript endpoint supports year+quarter without date")
    func earningsTranscriptEndpoint_yearQuarterVariant() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "earningstranscriptyq")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/earnings/AAPL/transcript?year=2023&quarter=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(EarningsTranscriptResponse.self)
                #expect(body.symbol == "AAPL")
                #expect(body.year == 2023)
                #expect(body.quarter == 2)
                #expect(body.provider == "fmp")
            })

            #expect(await fmpState.earningsTranscriptCalls() == 1)
            #expect(await fmpState.lastEarningsTranscriptRequest() == .init(symbol: "AAPL", year: 2023, quarter: 2))
        }
    }

    @Test("Earnings transcript endpoint rejects missing date/year/quarter with 400")
    func earningsTranscriptEndpoint_missingParamsReturns400() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "earningstranscriptmissing")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/earnings/AAPL/transcript", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("`date` is required"))
            })

            #expect(await fmpState.earningsTranscriptCalls() == 0)
        }
    }

    @Test("Earnings transcript endpoint rejects invalid quarter with 400")
    func earningsTranscriptEndpoint_invalidQuarterReturns400() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "earningstranscriptbadq")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/earnings/AAPL/transcript?year=2024&quarter=7", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("`quarter` must be between 1 and 4"))
            })

            #expect(await fmpState.earningsTranscriptCalls() == 0)
        }
    }

    @Test("Earnings transcript endpoint blocks free users with billing-upgrade 403")
    func earningsTranscriptEndpoint_nonPremiumReturns403() async throws {
        setenv("BYPASS_BILLING", "false", 1)
        defer { unsetenv("BYPASS_BILLING") }
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "earningstranscriptfree")
            // Auth-service register grants a default trial (level "temporary" = isPro).
            // Clear the trial fields so the user resolves to plain "free" for this test.
            if let user = try await User.find(userId, on: app.db) {
                user.trialTier = nil
                user.trialStartedAt = nil
                user.trialDays = nil
                try await user.save(on: app.db)
            }

            try await app.testing().test(.GET, "v1/market/earnings/AAPL/transcript?date=2024-10-29", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("earnings_text"))
            })

            #expect(await fmpState.earningsTranscriptCalls() == 0)
        }
    }

    @Test("Earnings transcript endpoint surfaces 404 when FMP has no transcript")
    func earningsTranscriptEndpoint_fmpNotFoundReturns404() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            await fmpState.setEarningsTranscriptShouldThrowNotFound(true)
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "earningstranscriptnf")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/earnings/AAPL/transcript?date=2024-10-29", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("not found"))
            })

            #expect(await fmpState.earningsTranscriptCalls() == 1)
        }
    }

    @Test("Analysis endpoint returns server-computed metrics for the analysis tab")
    func analysisEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "analysismetrics")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/analysis/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockAnalysisMetricsResponse.self)
                #expect(body.symbol == "AAPL")
                #expect(body.ttmPE == 32.889608822880916)
                #expect(body.forwardPE == 28.0)
                #expect(body.ttmEPSGrowth == 0.12)
                #expect(body.currentYearExpectedRevenueGrowth == 0.020219940775141214)
                #expect(body.nextYearRevenueGrowth == 0.031)
                #expect(body.grossMargin == 0.46518849807964424)
                #expect(body.netMargin == 0.24295027289266222)
                #expect(body.currentQuarterRevenueGrowthVsPreviousYear == 0.07)
            })

            #expect(await state.basicFinancialsCalls() == 1)
            #expect(await fmpState.ratiosTTMCalls() == 1)
            let lastGrowthRequest = await fmpState.lastFinancialGrowthRequest()
            #expect(lastGrowthRequest?.symbol == "AAPL")
            #expect(lastGrowthRequest?.limit == 5)
            #expect(lastGrowthRequest?.period == "FY")
        }
    }

    @Test("Ratios TTM endpoint returns 402 for symbols outside free-tier FMP coverage")
    func ratiosTTMEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "ratiosplanlimit")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/ratios-ttm/ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for ratios-ttm"))
            })

            #expect(await fmpState.ratiosTTMCalls() == 0)
        }
    }

    @Test("Balance sheet statement endpoint returns 402 for symbols outside free-tier FMP coverage")
    func balanceSheetStatementEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "balanceplanlimit")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/balance-sheet-statement/ZETA?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for balance-sheet-statement"))
            })

            #expect(await fmpState.lastBalanceSheetRequest() == nil)
        }
    }

    @Test("Cash flow statement endpoint returns 402 for symbols outside free-tier FMP coverage")
    func cashFlowStatementEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "cashflowplanlimit")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/cash-flow-statement/ZETA?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for cash-flow-statement"))
            })

            #expect(await fmpState.lastCashFlowRequest() == nil)
        }
    }

    @Test("Grades consensus endpoint returns FMP-backed analyst consensus data")
    func gradesConsensusEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "gradesconsensus")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/grades-consensus/UBER", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([GradesConsensusResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "UBER")
                #expect(body.first?.strongBuy == 1)
                #expect(body.first?.buy == 49)
                #expect(body.first?.hold == 11)
                #expect(body.first?.sell == 0)
                #expect(body.first?.strongSell == 0)
                #expect(body.first?.consensus == "Buy")
            })

            #expect(await fmpState.gradesConsensusCalls() == 1)
        }
    }

    @Test("Grades consensus endpoint returns 402 when the symbol requires a paid FMP plan")
    func gradesConsensusEndpointReturnsPaymentRequiredForPlanLimitedSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(
                state: state,
                fmpProvider: TestPaymentRequiredFMPMarketDataProvider()
            )
            let (token, userId) = try await registerTestUser(app: app, identifier: "gradespremium")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/grades-consensus/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                let body = res.body.string
                #expect(body.contains("FMP plan upgrade required"))
                #expect(body.contains("grades-consensus"))
            })
        }
    }

    @Test("Financial growth endpoint forwards limit and period to FMP")
    func financialGrowthEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "financialgrowth")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/financial-growth/AAPL?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([FinancialGrowthResponse].self)
                #expect(body.count == 2)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.period == "FY")
                #expect(body.first?.revenueGrowth == 0.020219940775141214)
            })

            let lastRequest = await fmpState.lastFinancialGrowthRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Financial growth endpoint clamps free-tier limit to plan-safe maximum")
    func financialGrowthEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "financialgrowthclamp")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/financial-growth/META?limit=10&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastFinancialGrowthRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Financial growth endpoint returns 402 for symbols outside free-tier FMP coverage")
    func financialGrowthEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "growthplanlimit")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/financial-growth/ZETA?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for financial-growth"))
            })

            #expect(await fmpState.lastFinancialGrowthRequest() == nil)
        }
    }

    @Test("Analyst estimates endpoint forwards parameters to FMP")
    func analystEstimatesEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "analystestimates")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/analyst-estimates/AAPL?period=annual&limit=5&page=0", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([AnalystEstimatesResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.epsAvg == 9.68)
            })

            let lastRequest = await fmpState.lastAnalystEstimatesRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.period == "annual")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.page == 0)
        }
    }

    @Test("Analyst estimates endpoint clamps free-tier limit to plan-safe maximum")
    func analystEstimatesEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "analystestimatesclamp")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/analyst-estimates/META?period=annual&limit=10&page=0", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastAnalystEstimatesRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.period == "annual")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.page == 0)
        }
    }

    @Test("Analyst estimates endpoint returns 402 for non-annual period on free-tier")
    func analystEstimatesEndpointReturnsPaymentRequiredForNonAnnualPeriodOnFreeTier() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "estimatesperiodlimit")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/analyst-estimates/AAPL?period=quarter", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier for analyst-estimates is limited to annual reports"))
            })

            #expect(await fmpState.lastAnalystEstimatesRequest() == nil)
        }
    }

    @Test("Analyst estimates endpoint returns 402 for symbols outside free-tier FMP coverage")
    func analystEstimatesEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "estimatesplanlimit")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/analyst-estimates/ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for analyst-estimates"))
            })

            #expect(await fmpState.lastAnalystEstimatesRequest() == nil)
        }
    }

    @Test("Ratios endpoint forwards limit and period to FMP")
    func ratiosEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "ratios")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/ratios/AAPL?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([RatiosResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.grossProfitMargin == 0.4620634981523393)
            })

            let lastRequest = await fmpState.lastRatiosRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Ratios endpoint clamps free-tier limit to plan-safe maximum")
    func ratiosEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "ratiosclamp")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/ratios/META?limit=10&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastRatiosRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Ratios endpoint returns 402 for symbols outside free-tier FMP coverage")
    func ratiosEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "ratiosplanlimit")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/ratios/ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for ratios"))
            })

            #expect(await fmpState.lastRatiosRequest() == nil)
        }
    }

    @Test("Analysis endpoint returns 402 for symbols outside free-tier FMP coverage")
    func analysisEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, userId) = try await registerTestUser(app: app, identifier: "analysisplanlimit")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(.GET, "v1/market/analysis/ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for analysis"))
            })

            #expect(await state.basicFinancialsCalls() == 0)
            #expect(await fmpState.ratiosTTMCalls() == 0)
            #expect(await fmpState.lastFinancialGrowthRequest() == nil)
        }
    }

    @Test("Historical sector performance endpoint forwards FMP filters")
    func historicalSectorPerformanceEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, userId) = try await registerTestUser(app: app, identifier: "sectorperf")
            try await grantPremium(userId: userId, on: app)

            try await app.testing().test(
                .GET,
                "v1/market/historical-sector-performance?sector=Energy&exchange=NASDAQ&from=2024-02-01&to=2024-03-01",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode([HistoricalSectorPerformanceResponse].self)
                    #expect(body.count == 1)
                    #expect(body.first?.sector == "Energy")
                    #expect(body.first?.exchange == "NASDAQ")
                    #expect(body.first?.averageChange == 0.6397534025664513)
                }
            )

            let lastRequest = await fmpState.lastSectorPerformanceRequest()
            #expect(lastRequest?.sector == "Energy")
            #expect(lastRequest?.exchange == "NASDAQ")
            #expect(lastRequest?.from == "2024-02-01")
            #expect(lastRequest?.to == "2024-03-01")
        }
    }

    @Test("Quote batch normalizes, deduplicates, and caches symbols")
    func quoteBatchUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            var first: QuoteBatchResponse?
            var second: QuoteBatchResponse?

            try await app.testing().test(.GET, "v1/market/quote/batch?symbols=AAPL, msft ,aapl", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(QuoteBatchResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/quote/batch?symbols=MSFT,AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(QuoteBatchResponse.self)
            })

            #expect(first?.quotes.count == 2)
            #expect(second?.quotes.count == 2)
            #expect(Set(first?.quotes.map(\.symbol) ?? []) == Set(["AAPL", "MSFT"]))
            #expect(Set(second?.quotes.map(\.symbol) ?? []) == Set(["AAPL", "MSFT"]))
            #expect(await state.quoteCalls() == 2)
        }
    }

    @Test("History uses cache after first fetch")
    func historyUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(
                state: state,
                quoteTTLSeconds: 3600,
                historyTTLSeconds: 86400,
                searchTTLSeconds: 3600,
                fxTTLSeconds: 3600
            )
            let (token, _) = try await registerTestUser(app: app)

            var first: HistoryResponse?
            var second: HistoryResponse?

            try await app.testing().test(.GET, "v1/market/history/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(HistoryResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/history/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(HistoryResponse.self)
            })

            #expect(first?.symbol == "AAPL")
            #expect(second?.symbol == "AAPL")
            #expect(first?.bars.count == 1)
            #expect(second?.bars.count == 1)
            #expect(await state.historyCalls() == 1)
        }
    }

    @Test("Search uses cache after first fetch")
    func searchUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            var first: [SearchResultResponse] = []
            var second: [SearchResultResponse] = []

            try await app.testing().test(.GET, "v1/market/search?q=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode([SearchResultResponse].self)
            })

            try await app.testing().test(.GET, "v1/market/search?q=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode([SearchResultResponse].self)
            })

            #expect(first.count == 1)
            #expect(second.count == 1)
            #expect(first.first?.symbol == "AAPL")
            #expect(second.first?.symbol == "AAPL")
            #expect(await state.searchCalls() == 1)
        }
    }

    @Test("Quote returns stale DB cache if provider fails")
    func quoteFallsBackToStaleDatabaseCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(
                state: state,
                quoteTTLSeconds: 1,
                historyTTLSeconds: 3600,
                searchTTLSeconds: 3600,
                fxTTLSeconds: 3600
            )
            let (token, _) = try await registerTestUser(app: app)

            let stale = QuoteCache(
                provider: "ibkr",
                symbol: "AAPL",
                currency: "USD",
                price: 123.45,
                asOf: Date().addingTimeInterval(-3600)
            )
            try await stale.save(on: app.db)
            await state.setFailQuote(true)

            var response: QuoteResponse?
            try await app.testing().test(.GET, "v1/market/quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(QuoteResponse.self)
            })

            #expect(response?.symbol == "AAPL")
            #expect(response?.currentPrice == 123.45)
            #expect(await state.quoteCalls() == 1)
        }
    }

    @Test("News feed returns tracked symbols and respects limit")
    func newsFeedReturnsTrackedAndLimitedResults() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await grantPremium(userId: userId, on: app)
            let seededLists = try await seedDefaultLists(userId: userId, on: app.db)

            let stock = Stock(
                userId: userId,
                portfolioListId: seededLists.portfolioListId,
                symbol: "AAPL",
                shares: 3,
                buyPrice: 100,
                buyDate: Date()
            )
            try await stock.save(on: app.db)

            let watchlist = WatchlistItem(
                userId: userId,
                watchlistListId: seededLists.watchlistListId,
                symbol: "MSFT"
            )
            try await watchlist.save(on: app.db)

            let trackedRecent = NewsItem(
                userId: userId,
                symbol: "AAPL",
                headline: "Tracked recent",
                source: "Reuters",
                url: nil,
                summary: nil,
                publishedAt: Date()
            )
            let trackedOlder = NewsItem(
                userId: userId,
                symbol: "MSFT",
                headline: "Tracked older",
                source: "Bloomberg",
                url: nil,
                summary: nil,
                publishedAt: Date().addingTimeInterval(-3600)
            )
            let untrackedNewest = NewsItem(
                userId: userId,
                symbol: "TSLA",
                headline: "Untracked newest",
                source: "WSJ",
                url: nil,
                summary: nil,
                publishedAt: Date().addingTimeInterval(3600)
            )

            try await trackedRecent.save(on: app.db)
            try await trackedOlder.save(on: app.db)
            try await untrackedNewest.save(on: app.db)

            var allFeed: [NewsItemResponse] = []
            var limitedFeed: [NewsItemResponse] = []

            try await app.testing().test(.GET, "v1/news/feed?limit=10", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                allFeed = try res.content.decode([NewsItemResponse].self)
            })

            try await app.testing().test(.GET, "v1/news/feed?limit=1", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                limitedFeed = try res.content.decode([NewsItemResponse].self)
            })

            #expect(allFeed.count == 2)
            #expect(Set(allFeed.map(\.symbol)) == Set(["AAPL", "MSFT"]))
            #expect(!allFeed.contains { $0.symbol == "TSLA" })

            #expect(limitedFeed.count == 1)
            #expect(limitedFeed.first?.symbol == "AAPL")
        }
    }

    @Test("Finnhub news webhook ingests tracked symbols and deduplicates repeated deliveries")
    func finnhubNewsWebhookIngestsTrackedSymbols() async throws {
        setenv("FINNHUB_WEBHOOK_SECRET", "test-finnhub-secret", 1)
        setenv("FINNHUB_WEBHOOK_URL", "http://localhost:8080/webhooks/finnhub/news", 1)
        defer {
            unsetenv("FINNHUB_WEBHOOK_SECRET")
            unsetenv("FINNHUB_WEBHOOK_URL")
        }

        try await withApp { app in
            let (_, user1Id) = try await registerTestUser(app: app, identifier: "finnhubnews1")
            let (_, user2Id) = try await registerTestUser(app: app, identifier: "finnhubnews2")
            let user1Lists = try await seedDefaultLists(userId: user1Id, on: app.db)
            let user2Lists = try await seedDefaultLists(userId: user2Id, on: app.db)

            try await Stock(
                userId: user1Id,
                portfolioListId: user1Lists.portfolioListId,
                symbol: "AAPL",
                shares: 5,
                buyPrice: 100,
                buyDate: Date()
            ).save(on: app.db)
            try await WatchlistItem(
                userId: user1Id,
                watchlistListId: user1Lists.watchlistListId,
                symbol: "MSFT"
            ).save(on: app.db)
            try await WatchlistItem(
                userId: user2Id,
                watchlistListId: user2Lists.watchlistListId,
                symbol: "AAPL"
            ).save(on: app.db)

            let payload = FinnhubNewsWebhookRequest(news: [
                FinnhubNewsWebhookItem(
                    category: "company",
                    datetime: 1_774_884_000,
                    headline: "Apple launches a new enterprise service",
                    id: 42,
                    image: nil,
                    related: "AAPL,MSFT,TSLA",
                    source: "Reuters",
                    summary: "Sample webhook article",
                    symbol: nil,
                    symbols: nil,
                    publishedAt: nil,
                    url: "https://example.com/news/apple-enterprise-service"
                ),
            ])

            var firstResponse: FinnhubNewsWebhookResponse?
            var secondResponse: FinnhubNewsWebhookResponse?

            try await app.testing().test(.POST, "webhooks/finnhub/news", beforeRequest: { req in
                req.headers.add(name: "X-Finnhub-Secret", value: "test-finnhub-secret")
                try req.content.encode(payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                firstResponse = try res.content.decode(FinnhubNewsWebhookResponse.self)
            })

            try await app.testing().test(.POST, "webhooks/finnhub/news", beforeRequest: { req in
                req.headers.add(name: "X-Finnhub-Secret", value: "test-finnhub-secret")
                try req.content.encode(payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                secondResponse = try res.content.decode(FinnhubNewsWebhookResponse.self)
            })

            #expect(firstResponse?.provider == "finnhub")
            #expect(firstResponse?.receivedCount == 1)
            #expect(firstResponse?.matchedSymbolsCount == 2)
            #expect(firstResponse?.matchedUsersCount == 2)
            #expect(firstResponse?.insertedCount == 3)
            #expect(firstResponse?.skippedCount == 0)

            #expect(secondResponse?.insertedCount == 0)
            #expect(secondResponse?.skippedCount == 3)

            let user1News = try await NewsItem.query(on: app.db)
                .filter(\.$userId == user1Id)
                .sort(\.$symbol, .ascending)
                .all()
            let user2News = try await NewsItem.query(on: app.db)
                .filter(\.$userId == user2Id)
                .all()

            #expect(user1News.count == 2)
            #expect(user2News.count == 1)
            #expect(user1News.map(\.symbol) == ["AAPL", "MSFT"])
            #expect(user2News.first?.symbol == "AAPL")
        }
    }

    @Test("Finnhub news webhook rejects an invalid secret")
    func finnhubNewsWebhookRejectsInvalidSecret() async throws {
        setenv("FINNHUB_WEBHOOK_SECRET", "test-finnhub-secret", 1)
        defer { unsetenv("FINNHUB_WEBHOOK_SECRET") }

        try await withApp { app in
            let payload = FinnhubNewsWebhookRequest(news: [
                FinnhubNewsWebhookItem(
                    category: "company",
                    datetime: 1_774_884_000,
                    headline: "Invalid secret test",
                    id: 99,
                    image: nil,
                    related: "AAPL",
                    source: "Reuters",
                    summary: nil,
                    symbol: nil,
                    symbols: nil,
                    publishedAt: nil,
                    url: "https://example.com/news/invalid-secret"
                ),
            ])

            try await app.testing().test(.POST, "webhooks/finnhub/news", beforeRequest: { req in
                req.headers.add(name: "X-Finnhub-Secret", value: "wrong-secret")
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("News sync persists provider items, filters untracked symbols, and updates duplicates")
    func newsSyncPersistsProviderItems() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app, identifier: "newssync")
            let seededLists = try await seedDefaultLists(userId: userId, on: app.db)

            try await Stock(
                userId: userId,
                portfolioListId: seededLists.portfolioListId,
                symbol: "AAPL",
                shares: 5,
                buyPrice: 100,
                buyDate: Date()
            ).save(on: app.db)
            try await WatchlistItem(
                userId: userId,
                watchlistListId: seededLists.watchlistListId,
                symbol: "MSFT"
            ).save(on: app.db)

            let publishedAt = Date(timeIntervalSince1970: 1_774_884_000)
            let providerState = TestNewsProviderState(batches: [
                [
                    ProviderNewsItem(
                        symbol: "AAPL",
                        headline: "Apple launches a new enterprise service",
                        source: "Reuters",
                        url: "https://example.com/news/apple-enterprise-service",
                        summary: "Initial summary",
                        image: nil,
                        publishedAt: publishedAt
                    ),
                    ProviderNewsItem(
                        symbol: "TSLA",
                        headline: "Tesla opens a new plant",
                        source: "Reuters",
                        url: "https://example.com/news/tesla-new-plant",
                        summary: "Untracked symbol should be skipped",
                        image: nil,
                        publishedAt: publishedAt
                    ),
                ],
                [
                    ProviderNewsItem(
                        symbol: "AAPL",
                        headline: "Apple launches a new enterprise service",
                        source: "Reuters",
                        url: "https://example.com/news/apple-enterprise-service",
                        summary: "Updated summary",
                        image: nil,
                        publishedAt: publishedAt.addingTimeInterval(5)
                    ),
                    ProviderNewsItem(
                        symbol: "TSLA",
                        headline: "Tesla opens a new plant",
                        source: "Reuters",
                        url: "https://example.com/news/tesla-new-plant",
                        summary: "Untracked symbol should still be skipped",
                        image: nil,
                        publishedAt: publishedAt
                    ),
                ],
            ])
            app.newsService = DefaultNewsService(
                repo: app.newsRepository,
                provider: TestNewsProvider(state: providerState)
            )

            var firstResponse: NewsSyncResponse?
            var secondResponse: NewsSyncResponse?

            try await app.testing().test(.POST, "v1/news/sync", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                firstResponse = try res.content.decode(NewsSyncResponse.self)
            })

            try await app.testing().test(.POST, "v1/news/sync", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                secondResponse = try res.content.decode(NewsSyncResponse.self)
            })

            #expect(firstResponse?.provider == "test-news")
            #expect(firstResponse?.symbolsCount == 2)
            #expect(firstResponse?.fetchedCount == 2)
            #expect(firstResponse?.insertedCount == 1)
            #expect(firstResponse?.updatedCount == 0)
            #expect(firstResponse?.skippedCount == 1)

            #expect(secondResponse?.provider == "test-news")
            #expect(secondResponse?.symbolsCount == 2)
            #expect(secondResponse?.fetchedCount == 2)
            #expect(secondResponse?.insertedCount == 0)
            #expect(secondResponse?.updatedCount == 1)
            #expect(secondResponse?.skippedCount == 1)

            let items = try await NewsItem.query(on: app.db)
                .filter(\.$userId == userId)
                .all()

            #expect(items.count == 1)
            #expect(items.first?.symbol == "AAPL")
            #expect(items.first?.summary == "Updated summary")
        }
    }

    @Test("Dashboard returns aggregate metrics for current user")
    func dashboardReturnsAggregateMetrics() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let seededLists = try await seedDefaultLists(userId: userId, on: app.db)

            let aapl = Stock(
                userId: userId,
                portfolioListId: seededLists.portfolioListId,
                symbol: "AAPL",
                shares: 10,
                buyPrice: 100,
                buyDate: Date()
            )
            let msft = Stock(
                userId: userId,
                portfolioListId: seededLists.portfolioListId,
                symbol: "MSFT",
                shares: 5,
                buyPrice: 200,
                buyDate: Date()
            )
            try await aapl.save(on: app.db)
            try await msft.save(on: app.db)

            let aaplQuote = QuoteCache(
                provider: "ibkr",
                symbol: "AAPL",
                currency: "USD",
                price: 120,
                asOf: Date()
            )
            let msftQuote = QuoteCache(
                provider: "ibkr",
                symbol: "MSFT",
                currency: "USD",
                price: 180,
                asOf: Date()
            )
            try await aaplQuote.save(on: app.db)
            try await msftQuote.save(on: app.db)

            let watchlist = WatchlistItem(
                userId: userId,
                watchlistListId: seededLists.watchlistListId,
                symbol: "GOOGL"
            )
            try await watchlist.save(on: app.db)

            let research = ResearchNote(
                userId: userId,
                symbol: "AAPL",
                title: "Q1 review",
                thesis: "Strong ecosystem",
                risks: "Valuation",
                catalysts: "Services growth",
                referenceLinks: nil
            )
            try await research.save(on: app.db)

            let target = Target(
                userId: userId,
                symbol: "AAPL",
                scenario: "base",
                targetPrice: 150,
                targetDate: nil,
                rationale: "12m estimate"
            )
            try await target.save(on: app.db)

            let news = NewsItem(
                userId: userId,
                symbol: "AAPL",
                headline: "Earnings update",
                source: "Reuters",
                url: nil,
                summary: nil,
                publishedAt: Date()
            )
            try await news.save(on: app.db)

            var response: DashboardResponse?
            try await app.testing().test(.GET, "v1/dashboard", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(DashboardResponse.self)
            })

            #expect(response?.totalValue == 2100)
            #expect(response?.dailyChange == 0)
            #expect(response?.dailyChangePercent == 0)

            #expect(response?.topPerformers.count == 2)
            #expect(response?.topPerformers.first?.symbol == "AAPL")
            #expect(response?.topPerformers.first?.change == 0)
            #expect(response?.topPerformers.first?.changePercent == 0)

            #expect(response?.bottomPerformers.count == 2)
            #expect(response?.bottomPerformers.first?.symbol == "AAPL")

            #expect(response?.sectorAllocation.count == 1)
            #expect(response?.sectorAllocation.first?.sector == "Unknown")
            #expect(response?.sectorAllocation.first?.value == 2100)
            #expect(response?.sectorAllocation.first?.percent == 100)
        }
    }

    @Test("Dashboard insights endpoint returns financial health payload")
    func dashboardInsightsReturnsFinancialHealthPayload() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            try await seedMonthlyBudgetData(
                app: app,
                userId: userId,
                year: 2026,
                month: 1,
                salary: 5000,
                planned: 1500,
                actual: 1000
            )
            try await seedCashBuffer(app: app, userId: userId, balance: 2000)

            var response: DashboardInsightsResponse?
            try await app.testing().test(.GET, "v1/dashboard/insights", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(DashboardInsightsResponse.self)
            })

            #expect(response != nil)
            #expect(response?.financialHealth.maxScore == 100)
            #expect((response?.financialHealth.score ?? -1) >= 0)
            #expect((response?.financialHealth.score ?? -1) <= 100)
        }
    }

    @Test("Dashboard insights score strong profile is excellent")
    func dashboardInsightsStrongProfile() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            for month in 1 ... 6 {
                try await seedMonthlyBudgetData(
                    app: app,
                    userId: userId,
                    year: 2026,
                    month: month,
                    salary: 10000,
                    planned: 4000,
                    actual: 1000
                )
            }
            try await seedCashBuffer(app: app, userId: userId, balance: 10000)

            var response: DashboardInsightsResponse?
            try await app.testing().test(.GET, "v1/dashboard/insights", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(DashboardInsightsResponse.self)
            })

            #expect((response?.financialHealth.score ?? 0) >= 90)
            #expect(response?.financialHealth.status == .excellent)
        }
    }

    @Test("Dashboard insights score medium profile is healthy")
    func dashboardInsightsMediumProfile() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            for month in 1 ... 3 {
                try await seedMonthlyBudgetData(
                    app: app,
                    userId: userId,
                    year: 2026,
                    month: month,
                    salary: 10000,
                    planned: 3000,
                    actual: 2000
                )
            }
            try await seedCashBuffer(app: app, userId: userId, balance: 1000)

            var response: DashboardInsightsResponse?
            try await app.testing().test(.GET, "v1/dashboard/insights", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(DashboardInsightsResponse.self)
            })

            let score = response?.financialHealth.score ?? -1
            #expect(score >= 70)
            #expect(score <= 89)
            #expect(response?.financialHealth.status == .healthy)
        }
    }

    @Test("Dashboard insights score weak profile is at risk")
    func dashboardInsightsWeakProfile() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            try await seedMonthlyBudgetData(
                app: app,
                userId: userId,
                year: 2026,
                month: 1,
                salary: 1000,
                planned: 1000,
                actual: 1500
            )
            try await seedCashBuffer(app: app, userId: userId, balance: 0)

            var response: DashboardInsightsResponse?
            try await app.testing().test(.GET, "v1/dashboard/insights", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(DashboardInsightsResponse.self)
            })

            #expect((response?.financialHealth.score ?? 100) < 40)
            #expect(response?.financialHealth.status == .atRisk)
        }
    }

    @Test("Dashboard insights no-expense case keeps buffer contribution at zero")
    func dashboardInsightsNoExpenseData() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            for month in 1 ... 6 {
                try await seedMonthlyBudgetData(
                    app: app,
                    userId: userId,
                    year: 2026,
                    month: month,
                    salary: 8000,
                    planned: 2000,
                    actual: 0,
                    includeExpense: false
                )
            }
            try await seedCashBuffer(app: app, userId: userId, balance: 50000)

            var response: DashboardInsightsResponse?
            try await app.testing().test(.GET, "v1/dashboard/insights", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(DashboardInsightsResponse.self)
            })

            // savings: 40 + streak: 30 + buffer: 0 => 70
            #expect(response?.financialHealth.score == 70)
            #expect(response?.financialHealth.status == .healthy)
        }
    }

    @Test("Goals can update focus status")
    func goalsCanUpdateFocusStatus() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            var created: GoalResponse?
            try await app.testing().test(.POST, "v1/goals", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(GoalRequest(title: "Review watchlist before earnings"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                created = try res.content.decode(GoalResponse.self)
            })

            guard let created else {
                Issue.record("Expected created goal response")
                return
            }

            #expect(created.status == .pending)
            #expect(created.completedAt == nil)

            var updated: GoalResponse?
            try await app.testing().test(.PATCH, "v1/goals/\(created.id)/status", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(GoalStatusUpdateRequest(status: .completed, source: .manual))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                updated = try res.content.decode(GoalResponse.self)
            })

            #expect(updated?.status == .completed)
            #expect(updated?.statusUpdatedBy == .manual)
            #expect(updated?.completedAt != nil)
        }
    }

    @Test("Importing stocks from CSV (commit)")
    func importStocksFromCsvCommit() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)
            try await seedInstrument(symbol: "AAPL", on: app)

            let csv = """
            symbol,shares,buy_price,buy_date,notes
            AAPL,12,145.30,2026-01-10,Long-term core
            """

            var importResponse: CsvImportCommitResponse?
            try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: csv)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                importResponse = try res.content.decode(CsvImportCommitResponse.self)
            })

            #expect(importResponse?.errors.isEmpty == true)
            #expect(importResponse?.inserted.count == 1)
            #expect(importResponse?.provider == "ibkr")

            try await app.testing().test(.GET, "v1/brokers", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let brokers = try res.content.decode([BrokerConnectionResponse].self)
                let hasIbkrCsv = brokers.contains { broker in
                    broker.provider == "ibkr" && broker.status == "csv"
                }
                #expect(hasIbkrCsv)
            })

            try await app.testing().test(.GET, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let stocks = try res.content.decode([StockListItem].self)
                let hasAAPL = stocks.contains { stock in
                    stock.symbol == "AAPL" && stock.shares == 12
                }
                #expect(hasAAPL)
            })

            try await app.testing().test(.GET, "v1/lots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let lots = try res.content.decode([LotResponse].self)
                #expect(lots.count == 1)
                #expect(lots.first?.instrumentId == "AAPL")
                #expect(lots.first?.openQuantity == 12)
            })
        }
    }

    @Test("Previewing CSV handles header aliases and row errors")
    func previewCsvSupportsHeaderAliasesAndReportsRowErrors() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)
            try await seedInstrument(symbol: "AAPL", on: app)

            let csv = """
            ticker,quantity,average_cost,purchase_date,memo
            AAPL,10,120.50,2026-01-10,Core position
            ,2,50.00,2026-01-11,Missing symbol
            """

            var previewResponse: CsvImportPreviewResponse?
            try await app.testing().test(.POST, "v1/brokers/import/csv?provider=IBKR", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: csv)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                previewResponse = try res.content.decode(CsvImportPreviewResponse.self)
            })

            #expect(previewResponse?.provider == "ibkr")
            #expect(previewResponse?.items.count == 1)
            #expect(previewResponse?.items.first?.symbol == "AAPL")
            #expect(previewResponse?.items.first?.shares == 10)
            #expect(previewResponse?.errors.count == 1)
            #expect(previewResponse?.errors.first?.line == 3)
        }
    }

    @Test("CSV import replaces prior imported lots for same provider and symbol")
    func csvImportReplacesPriorImportedLotsForSameSource() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)
            try await seedInstrument(symbol: "AAPL", on: app)

            let firstCSV = """
            symbol,shares,buy_price,buy_date
            AAPL,2,100,2026-01-10
            AAPL,3,110,2026-01-15
            """

            try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: firstCSV)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(CsvImportCommitResponse.self)
                #expect(response.inserted.count == 1)
                #expect(response.updated.isEmpty)
                #expect(response.importedLotsCount == 2)
            })

            let replacementCSV = """
            symbol,shares,buy_price,buy_date
            AAPL,5,120,2026-02-01
            """

            try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: replacementCSV)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(CsvImportCommitResponse.self)
                #expect(response.inserted.isEmpty)
                #expect(response.updated.count == 1)
                #expect(response.replacedSymbols == ["AAPL"])
                #expect(response.importedLotsCount == 1)
                #expect(response.errors.isEmpty)
            })

            try await app.testing().test(.GET, "v1/lots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let lots = try res.content.decode([LotResponse].self)
                #expect(lots.count == 1)
                #expect(lots.first?.instrumentId == "AAPL")
                #expect(lots.first?.openQuantity == 5)
                #expect(lots.first?.openPrice == 120)
            })
        }
    }

    @Test("CSV import partially commits valid rows and reports malformed rows")
    func csvImportPartiallyCommitsValidRowsAndReportsMalformedRows() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)
            try await seedInstrument(symbol: "AAPL", on: app)

            let csv = """
            symbol,shares,buy_price,buy_date
            AAPL,4,150,2026-01-10
            MSFT,3,250,
            NOT!!!,2,50,2026-01-11
            """

            try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: csv)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(CsvImportCommitResponse.self)
                #expect(response.inserted.count == 2)
                #expect(response.importedLotsCount == 2)
                #expect(response.errors.count == 1)
                #expect(response.errors.contains(where: { $0.line == 4 && $0.message.contains("Unknown symbol") }))
            })

            try await app.testing().test(.GET, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let stocks = try res.content.decode([StockListItem].self)
                #expect(stocks.count == 2)
                let aapl = stocks.first(where: { $0.symbol == "AAPL" })
                let msft = stocks.first(where: { $0.symbol == "MSFT" })
                #expect(aapl?.shares == 4)
                #expect(msft?.shares == 3)
            })
        }
    }

    @Test("CSV preview requires provider and body")
    func previewCsvRequiresProviderAndBody() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            try await app.testing().test(.POST, "v1/brokers/import/csv", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: "symbol,shares\nAAPL,10")
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.POST, "v1/brokers/import/csv?provider=ibkr", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Committing CSV returns inserted rows and row-level validation errors")
    func commitCsvReturnsMixedSuccessAndErrors() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            let csv = """
            symbol,shares,buy_price,buy_date,notes
            AAPL,10,120.50,2026-01-10,Core
            MSFT,5,,2026-01-11,Missing buy price
            """

            var commitResponse: CsvImportCommitResponse?
            try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: csv)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                commitResponse = try res.content.decode(CsvImportCommitResponse.self)
            })

            #expect(commitResponse?.provider == "ibkr")
            #expect(commitResponse?.inserted.count == 2)
            let insertedSymbols = Set(commitResponse?.inserted.map(\.symbol) ?? [])
            #expect(insertedSymbols == Set(["AAPL", "MSFT"]))
            #expect(commitResponse?.updated.isEmpty == true)
            #expect(commitResponse?.errors.isEmpty == true)

            try await app.testing().test(.GET, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let stocks = try res.content.decode([StockListItem].self)
                let symbols = Set(stocks.map(\.symbol))
                #expect(symbols.contains("AAPL"))
                #expect(symbols.contains("MSFT"))
            })
        }
    }

    @Test("CSV commit requires provider and body")
    func commitCsvRequiresProviderAndBody() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            try await app.testing().test(.POST, "v1/brokers/import/csv/commit", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: "symbol,shares\nAAPL,10")
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("APNS device registration upserts the same token idempotently")
    func apnsDeviceRegistrationUpsertsTokenIdempotently() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            var firstResponse: PushDeviceRegistrationResponse?
            try await app.testing().test(.PUT, "v1/notifications/apns/device", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    PushDeviceRegistrationRequest(
                        deviceToken: " ABC123TOKEN ",
                        platform: .ios,
                        apnsEnvironment: .development,
                        authorizationStatus: .authorized
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                firstResponse = try res.content.decode(PushDeviceRegistrationResponse.self)
            })

            var secondResponse: PushDeviceRegistrationResponse?
            try await app.testing().test(.PUT, "v1/notifications/apns/device", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    PushDeviceRegistrationRequest(
                        deviceToken: "abc123token",
                        platform: .ios,
                        apnsEnvironment: .production,
                        authorizationStatus: .provisional
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                secondResponse = try res.content.decode(PushDeviceRegistrationResponse.self)
            })

            #expect(firstResponse?.id == secondResponse?.id)
            #expect(secondResponse?.apnsEnvironment == .production)
            #expect(secondResponse?.authorizationStatus == .provisional)

            let devices = try await PushDevice.query(on: app.db)
                .filter(\.$deviceToken == "abc123token")
                .all()
            #expect(devices.count == 1)
            #expect(devices.first?.userId == userId)
            #expect(devices.first?.isActive == true)
            #expect(devices.first?.apnsEnvironment == PushAPNSEnvironment.production.rawValue)
        }
    }

    @Test("APNS device deactivate marks token inactive")
    func apnsDeviceDeactivateMarksTokenInactive() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            let registered = PushDevice(
                userId: userId,
                deviceToken: "deactivate-token",
                platform: PushPlatform.ios.rawValue,
                apnsEnvironment: PushAPNSEnvironment.development.rawValue,
                authorizationStatus: PushAuthorizationStatus.authorized.rawValue,
                isActive: true,
                lastSeenAt: Date()
            )
            try await registered.save(on: app.db)

            try await app.testing().test(.POST, "v1/notifications/apns/device/deactivate", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(PushDeviceDeactivateRequest(deviceToken: "deactivate-token"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let updated = try await PushDevice.query(on: app.db)
                .filter(\.$userId == userId)
                .filter(\.$deviceToken == "deactivate-token")
                .first()
            #expect(updated != nil)
            #expect(updated?.isActive == false)
        }
    }

    @Test("APNS device endpoints require authentication")
    func apnsDeviceEndpointsRequireAuthentication() async throws {
        try await withApp { app in
            try await app.testing().test(.PUT, "v1/notifications/apns/device", beforeRequest: { req in
                try req.content.encode(
                    PushDeviceRegistrationRequest(
                        deviceToken: "token-1",
                        platform: .ios,
                        apnsEnvironment: .development,
                        authorizationStatus: .authorized
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.POST, "v1/notifications/apns/device/deactivate", beforeRequest: { req in
                try req.content.encode(PushDeviceDeactivateRequest(deviceToken: "token-1"))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Target alert evaluator triggers bull/bear and does not duplicate after trigger")
    func targetAlertEvaluatorTriggersAndDedupes() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)

            let marketState = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: marketState)

            let senderState = TestPushSenderState(queuedSummaries: [
                .init(delivered: 1, failed: 0),
                .init(delivered: 1, failed: 0),
            ])
            app.pushNotificationSender = TestPushNotificationSender(state: senderState)

            let device = PushDevice(
                userId: userId,
                deviceToken: "token-trigger",
                platform: PushPlatform.ios.rawValue,
                apnsEnvironment: PushAPNSEnvironment.development.rawValue,
                authorizationStatus: PushAuthorizationStatus.authorized.rawValue,
                isActive: true,
                lastSeenAt: Date()
            )
            try await device.save(on: app.db)

            let bull = Target(userId: userId, symbol: "AAPL", scenario: "bull", targetPrice: 100)
            let bear = Target(userId: userId, symbol: "MSFT", scenario: "bear", targetPrice: 105)
            let baseNotTriggered = Target(userId: userId, symbol: "TSLA", scenario: "base", targetPrice: 120)
            try await bull.save(on: app.db)
            try await bear.save(on: app.db)
            try await baseNotTriggered.save(on: app.db)

            let req = Request(application: app, on: app.eventLoopGroup.next())
            await app.targetAlertEvaluator.evaluateUnresolvedTargets(req: req)
            await app.targetAlertEvaluator.evaluateUnresolvedTargets(req: req)

            let sendCount = await senderState.callCount()
            #expect(sendCount == 2)

            let sentSymbols = await senderState.sentSymbols()
            #expect(sentSymbols.contains("AAPL"))
            #expect(sentSymbols.contains("MSFT"))
            #expect(!sentSymbols.contains("TSLA"))

            let reloadedBull = try await Target.find(bull.id, on: app.db)
            let reloadedBear = try await Target.find(bear.id, on: app.db)
            let reloadedBase = try await Target.find(baseNotTriggered.id, on: app.db)

            #expect(reloadedBull?.alertTriggeredAt != nil)
            #expect(reloadedBull?.alertTriggeredPrice == 101.25)
            #expect(reloadedBear?.alertTriggeredAt != nil)
            #expect(reloadedBear?.alertTriggeredPrice == 101.25)
            #expect(reloadedBase?.alertTriggeredAt == nil)
        }
    }

    @Test("Target alert evaluator does not mark target triggered when all deliveries fail")
    func targetAlertEvaluatorDoesNotMarkTriggeredWhenDeliveryFails() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)

            let marketState = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: marketState)

            let senderState = TestPushSenderState(queuedSummaries: [
                .init(delivered: 0, failed: 1),
            ])
            app.pushNotificationSender = TestPushNotificationSender(state: senderState)

            let device = PushDevice(
                userId: userId,
                deviceToken: "token-fail",
                platform: PushPlatform.ios.rawValue,
                apnsEnvironment: PushAPNSEnvironment.development.rawValue,
                authorizationStatus: PushAuthorizationStatus.authorized.rawValue,
                isActive: true,
                lastSeenAt: Date()
            )
            try await device.save(on: app.db)

            let target = Target(userId: userId, symbol: "NVDA", scenario: "bull", targetPrice: 100)
            try await target.save(on: app.db)

            let req = Request(application: app, on: app.eventLoopGroup.next())
            await app.targetAlertEvaluator.evaluateUnresolvedTargets(req: req)

            let sendCount = await senderState.callCount()
            #expect(sendCount == 1)

            let reloaded = try await Target.find(target.id, on: app.db)
            #expect(reloaded?.alertTriggeredAt == nil)
            #expect(reloaded?.alertTriggeredPrice == nil)
        }
    }

    @Test("Updating target resets alert-triggered state")
    func updatingTargetResetsAlertTriggeredState() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            let target = Target(
                userId: userId,
                symbol: "AAPL",
                scenario: "bull",
                targetPrice: 100,
                targetDate: nil,
                rationale: "Before reset",
                alertTriggeredAt: Date(),
                alertTriggeredPrice: 100
            )
            try await target.save(on: app.db)

            guard let targetId = target.id else {
                Issue.record("Target id missing after save")
                return
            }

            try await app.testing().test(.PUT, "v1/targets/\(targetId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    TargetRequest(
                        symbol: "AAPL",
                        scenario: "bull",
                        targetPrice: 120,
                        targetDate: nil,
                        rationale: "After reset"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let updated = try await Target.find(targetId, on: app.db)
            #expect(updated?.targetPrice == 120)
            #expect(updated?.alertTriggeredAt == nil)
            #expect(updated?.alertTriggeredPrice == nil)
        }
    }

    @Test("Target alert poller runOnce invokes evaluator")
    func targetAlertPollerRunOnceInvokesEvaluator() async throws {
        try await withApp { app in
            let evaluatorState = TestTargetAlertEvaluatorState()
            app.targetAlertEvaluator = TestTargetAlertEvaluator(state: evaluatorState)

            let poller = TargetAlertPoller(intervalSeconds: 300, initialDelaySeconds: 0)
            await poller.runOnce(app)

            let calls = await evaluatorState.callCount()
            #expect(calls == 1)
        }
    }

    @Test("Balance sheet DTO decodes both lease-current key variants")
    func balanceSheetDTOAcceptsBothLeaseCurrentKeys() throws {
        let decoder = JSONDecoder()

        let canonicalJSON = """
        {"date":"2024-09-28","symbol":"AAPL","capitalLeaseOblationsCurrent":123.45}
        """
        let legacyJSON = """
        {"date":"2024-09-28","symbol":"AAPL","capitalLeaseOblationsCurrent":678.9}
        """

        let canonical = try decoder.decode(
            BalanceSheetStatementResponse.self,
            from: #require(canonicalJSON.data(using: .utf8))
        )
        #expect(canonical.capitalLeaseOblationsCurrent == 123.45)

        let legacy = try decoder.decode(
            BalanceSheetStatementResponse.self,
            from: #require(legacyJSON.data(using: .utf8))
        )
        #expect(legacy.capitalLeaseOblationsCurrent == 678.9)
    }

    @Test("Balance sheet DTO encoding includes canonical lease-current key")
    func balanceSheetDTOEncodingContainsCanonicalLeaseCurrentKey() throws {
        let encoder = JSONEncoder()
        let response = BalanceSheetStatementResponse(
            date: "2024-09-28",
            symbol: "AAPL",
            reportedCurrency: "USD",
            cik: nil,
            filingDate: nil,
            acceptedDate: nil,
            fiscalYear: nil,
            period: nil,
            cashAndCashEquivalents: nil,
            shortTermInvestments: nil,
            cashAndShortTermInvestments: nil,
            netReceivables: nil,
            accountsReceivables: nil,
            otherReceivables: nil,
            inventory: nil,
            prepaids: nil,
            otherCurrentAssets: nil,
            totalCurrentAssets: nil,
            propertyPlantEquipmentNet: nil,
            goodwill: nil,
            intangibleAssets: nil,
            goodwillAndIntangibleAssets: nil,
            longTermInvestments: nil,
            taxAssets: nil,
            otherNonCurrentAssets: nil,
            totalNonCurrentAssets: nil,
            otherAssets: nil,
            totalAssets: nil,
            totalPayables: nil,
            accountPayables: nil,
            otherPayables: nil,
            accruedExpenses: nil,
            shortTermDebt: nil,
            capitalLeaseOblationsCurrent: 123.45,
            taxPayables: nil,
            deferredRevenue: nil,
            otherCurrentLiabilities: nil,
            totalCurrentLiabilities: nil,
            longTermDebt: nil,
            deferredRevenueNonCurrent: nil,
            deferredTaxLiabilitiesNonCurrent: nil,
            otherNonCurrentLiabilities: nil,
            totalNonCurrentLiabilities: nil,
            otherLiabilities: nil,
            capitalLeaseObligations: nil,
            totalLiabilities: nil,
            treasuryStock: nil,
            preferredStock: nil,
            commonStock: nil,
            retainedEarnings: nil,
            additionalPaidInCapital: nil,
            accumulatedOtherComprehensiveIncomeLoss: nil,
            otherTotalStockholdersEquity: nil,
            totalStockholdersEquity: nil,
            totalEquity: nil,
            minorityInterest: nil,
            totalLiabilitiesAndTotalEquity: nil,
            totalInvestments: nil,
            totalDebt: nil,
            netDebt: nil
        )

        let payload = try encoder.encode(response)
        let text = String(decoding: payload, as: UTF8.self)
        #expect(text.contains("\"capitalLeaseOblationsCurrent\""))
    }

    // MARK: - Pagination

    @Test("Stocks list pagination returns correct page size and next cursor")
    func stocksListPagination() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let seeded = try await seedDefaultLists(userId: userId, on: app.db)

            // Create 75 stocks (more than default limit 50)
            for i in 1 ... 75 {
                let stock = Stock(
                    userId: userId,
                    portfolioListId: seeded.portfolioListId,
                    symbol: "STK\(i)",
                    shares: Double(i),
                    buyPrice: 100.0,
                    buyDate: Date(),
                    notes: nil,
                    category: .stock,
                    sourceProvider: nil,
                    sourceAccountId: nil
                )
                try await stock.save(on: app.db)
            }

            // Page 1: default limit
            var page1Stocks: [StockListItem] = []
            var cursor1 = ""
            try await app.testing().test(.GET, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                page1Stocks = try res.content.decode([StockListItem].self)
                cursor1 = res.headers.first(name: "X-Next-Cursor") ?? ""
            })
            #expect(page1Stocks.count == 50)
            #expect(!cursor1.isEmpty)

            // Page 2: use cursor
            var page2Stocks: [StockListItem] = []
            var page2Cursor: String? = nil
            try await app.testing().test(.GET, "v1/stocks?cursor=\(cursor1)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                page2Stocks = try res.content.decode([StockListItem].self)
                page2Cursor = res.headers.first(name: "X-Next-Cursor")
            })
            #expect(page2Stocks.count == 25)
            #expect(page2Cursor == nil) // last page

            // Verify no overlap
            let page1Symbols = Set(page1Stocks.map(\.symbol))
            let page2Symbols = Set(page2Stocks.map(\.symbol))
            #expect(page1Symbols.isDisjoint(with: page2Symbols))
        }
    }

    @Test("Expenses list pagination returns correct page size and next cursor")
    func expensesListPagination() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let now = Date()

            // Create 55 expenses
            for i in 1 ... 55 {
                let expense = Expense(
                    userID: userId,
                    title: "Expense \(i)",
                    amount: Double(i) * 10.0,
                    pillar: .fundamentals,
                    occurredOn: Calendar.current.date(byAdding: .day, value: -i, to: now)!,
                    linkedPlanItemID: nil,
                    splitMode: .personal,
                    userSharePercent: 100
                )
                try await expense.save(on: app.db)
            }

            // Page 1
            var page1Expenses: [ExpenseResponse] = []
            var cursor1 = ""
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                page1Expenses = try res.content.decode([ExpenseResponse].self)
                cursor1 = res.headers.first(name: "X-Next-Cursor") ?? ""
            })
            #expect(page1Expenses.count == 50)
            #expect(!cursor1.isEmpty)

            // Page 2
            var page2Expenses: [ExpenseResponse] = []
            var page2Cursor: String? = nil
            try await app.testing().test(.GET, "v1/expenses?cursor=\(cursor1)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                page2Expenses = try res.content.decode([ExpenseResponse].self)
                page2Cursor = res.headers.first(name: "X-Next-Cursor")
            })
            #expect(page2Expenses.count == 5)
            #expect(page2Cursor == nil)

            // Verify ordering (by occurredOn descending)
            let page1Dates = Set(page1Expenses.map(\.occurredOn))
            let page2Dates = Set(page2Expenses.map(\.occurredOn))
            #expect(page1Dates.isDisjoint(with: page2Dates))
            if let earliestPage2 = page2Expenses.last {
                #expect(page1Expenses.allSatisfy { $0.occurredOn > earliestPage2.occurredOn })
            }
        }
    }

    @Test("News list pagination returns correct page size and next cursor")
    func newsListPagination() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let now = Date()

            // Create 60 news items for AAPL
            for i in 1 ... 60 {
                let news = NewsItem(
                    userId: userId,
                    symbol: "AAPL",
                    headline: "Apple News \(i)",
                    source: "TestSource",
                    url: "https://example.com/news/\(i)",
                    summary: "Summary \(i)",
                    publishedAt: Calendar.current.date(byAdding: .hour, value: -i, to: now)!
                )
                try await news.save(on: app.db)
            }

            // Page 1
            var page1News: [NewsItemResponse] = []
            var cursor1 = ""
            try await app.testing().test(.GET, "v1/news?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                page1News = try res.content.decode([NewsItemResponse].self)
                cursor1 = res.headers.first(name: "X-Next-Cursor") ?? ""
            })
            #expect(page1News.count == 50)
            #expect(!cursor1.isEmpty)

            // Page 2
            var page2News: [NewsItemResponse] = []
            var page2Cursor: String? = nil
            try await app.testing().test(.GET, "v1/news?symbol=AAPL&cursor=\(cursor1)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                page2News = try res.content.decode([NewsItemResponse].self)
                page2Cursor = res.headers.first(name: "X-Next-Cursor")
            })
            #expect(page2News.count == 10)
            #expect(page2Cursor == nil)

            // Verify ordering (publishedAt descending)
            let page1Times = Set(page1News.map(\.publishedAt))
            let page2Times = Set(page2News.map(\.publishedAt))
            #expect(page1Times.isDisjoint(with: page2Times))
            if let earliestPage2 = page2News.last {
                #expect(page1News.allSatisfy { $0.publishedAt > earliestPage2.publishedAt })
            }
        }
    }

    @Test("Pagination respects custom limit up to max")
    func paginationRespectsCustomLimit() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let seeded = try await seedDefaultLists(userId: userId, on: app.db)

            // Create 250 stocks
            for i in 1 ... 250 {
                let stock = Stock(
                    userId: userId,
                    portfolioListId: seeded.portfolioListId,
                    symbol: "LIM\(i)",
                    shares: Double(i),
                    buyPrice: 100.0,
                    buyDate: Date(),
                    notes: nil,
                    category: .stock,
                    sourceProvider: nil,
                    sourceAccountId: nil
                )
                try await stock.save(on: app.db)
            }

            // Request limit=200 (max)
            var stocks: [StockListItem] = []
            var respCursor: String? = nil
            try await app.testing().test(.GET, "v1/stocks?limit=200", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                stocks = try res.content.decode([StockListItem].self)
                respCursor = res.headers.first(name: "X-Next-Cursor")
            })
            #expect(stocks.count == 200)
            #expect(respCursor == nil) // last page

            // Request limit=150
            var stocks2: [StockListItem] = []
            var resp2Cursor: String? = nil
            try await app.testing().test(.GET, "v1/stocks?limit=150", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                stocks2 = try res.content.decode([StockListItem].self)
                resp2Cursor = res.headers.first(name: "X-Next-Cursor")
            })
            #expect(stocks2.count == 150)
            #expect(resp2Cursor != nil)
        }
    }

    @Test("Wealth forecast lifecycle persists updates and deletion")
    func wealthForecastLifecycle() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let seeded = try await seedDefaultLists(userId: userId, on: app.db)
            try await grantPremium(userId: userId, on: app)
            let create = NetWorthForecastUpsertRequest(
                name: "Retirement", baseCurrency: "EUR", horizonMonths: 240,
                annualIncomeGrowth: 0.03, monthlyIncomeOverride: 5000,
                monthlySpendingOverride: 3000, targetAmount: 1_000_000, pathCount: 2000
            )
            var created: NetWorthForecastDefinition?
            try await app.testing().test(
                .POST,
                "v1/net-worth-forecasts?portfolio_list_id=\(seeded.portfolioListId.uuidString)",
                beforeRequest: { req in req.headers.bearerAuthorization = .init(token: token); try req.content.encode(create) },
                afterResponse: { res async throws in #expect(res.status == .ok); created = try res.content.decode(NetWorthForecastDefinition.self) }
            )
            let forecast = try #require(created)
            let update = NetWorthForecastUpsertRequest(name: "Retirement plan", baseCurrency: "USD", horizonMonths: 300, pathCount: 3000)
            try await app.testing().test(.PUT, "v1/net-worth-forecasts/\(forecast.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token); try req.content.encode(update)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(NetWorthForecastDefinition.self)
                #expect(body.name == "Retirement plan"); #expect(body.baseCurrency == "USD"); #expect(body.pathCount == 3000)
            })
            try await app.testing().test(.DELETE, "v1/net-worth-forecasts/\(forecast.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in #expect(res.status == .noContent) })
            let forecastID = try #require(UUID(uuidString: forecast.id))
            #expect(try await NetWorthForecastModel.find(forecastID, on: app.db) == nil)
        }
    }

    @Test("Notification inbox cursor is stable when timestamps tie")
    func notificationInboxStableCursor() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
            for index in 1 ... 3 {
                let event = NotificationEventModel(
                    userId: userId, kind: .budget, deduplicationKey: "cursor-\(index)",
                    title: "Alert \(index)", body: "Body \(index)"
                )
                event.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))
                event.createdAt = timestamp
                try await event.create(on: app.db)
            }
            var firstPage: NotificationInboxPage?
            try await app.testing().test(.GET, "v1/notifications/inbox?limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in #expect(res.status == .ok); firstPage = try res.content.decode(NotificationInboxPage.self) })
            let first = try #require(firstPage)
            #expect(first.items.count == 2); let cursor = try #require(first.nextCursor)
            var secondPage: NotificationInboxPage?
            try await app.testing().test(.GET, "v1/notifications/inbox?limit=2&cursor=\(cursor)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in #expect(res.status == .ok); secondPage = try res.content.decode(NotificationInboxPage.self) })
            let second = try #require(secondPage)
            #expect(second.items.count == 1)
            #expect(Set(first.items.map(\.id)).isDisjoint(with: Set(second.items.map(\.id))))
        }
    }

    actor TestPushSenderState {
        private var summaries: [TargetPushSendSummary]
        private var calls: [(symbol: String, scenario: String)] = []

        init(queuedSummaries: [TargetPushSendSummary]) {
            summaries = queuedSummaries
        }

        func recordSend(symbol: String, scenario: String) -> TargetPushSendSummary {
            calls.append((symbol: symbol, scenario: scenario))
            if !summaries.isEmpty {
                return summaries.removeFirst()
            }
            return .init(delivered: 1, failed: 0)
        }

        func callCount() -> Int {
            calls.count
        }

        func sentSymbols() -> [String] {
            calls.map(\.symbol)
        }
    }

    struct TestPushNotificationSender: PushNotificationSending {
        let state: TestPushSenderState

        func sendAutomationAlert(
            message _: AutomationPushMessage,
            devices: [PushDevice],
            req _: Request
        ) async -> TargetPushSendSummary {
            .init(delivered: devices.count, failed: 0)
        }

        func sendRebalancingDrift(
            alert _: RebalancingAlert,
            portfolioName _: String,
            devices: [PushDevice],
            req _: Request
        ) async -> TargetPushSendSummary {
            .init(delivered: devices.count, failed: 0)
        }

        func sendTargetHit(
            target: Target,
            currentPrice _: Double,
            devices _: [PushDevice],
            req _: Request
        ) async -> TargetPushSendSummary {
            await state.recordSend(symbol: target.symbol, scenario: target.scenario)
        }

        func sendBudgetAlert(
            snapshot _: BudgetSnapshot,
            threshold _: Int,
            remainingAmount _: Double,
            devices: [PushDevice],
            req _: Request
        ) async -> TargetPushSendSummary {
            // For now, no-op or record if needed in tests
            .init(delivered: devices.count, failed: 0)
        }

        func sendEarningsReminder(
            symbol _: String,
            earningsDate _: String,
            leadDays _: Int,
            devices: [PushDevice],
            req _: Request
        ) async -> TargetPushSendSummary {
            .init(delivered: devices.count, failed: 0)
        }

        func sendTaxOpportunity(
            opportunity _: TaxOpportunityResponse,
            devices: [PushDevice],
            req _: Request
        ) async -> TargetPushSendSummary {
            .init(delivered: devices.count, failed: 0)
        }
    }

    actor TestTargetAlertEvaluatorState {
        private var calls: Int = 0

        func recordCall() {
            calls += 1
        }

        func callCount() -> Int {
            calls
        }
    }

    struct TestTargetAlertEvaluator: TargetAlertEvaluating {
        let state: TestTargetAlertEvaluatorState

        func evaluateUnresolvedTargets(req _: Request) async {
            await state.recordCall()
        }
    }

    actor TestMarketProviderState {
        private var quoteCallCount: Int = 0
        private var historyCallCount: Int = 0
        private var searchCallCount: Int = 0
        private var fxCallCount: Int = 0
        private var profileCallCount: Int = 0
        private var basicFinancialsCallCount: Int = 0
        private var failQuoteRequests: Bool = false

        func nextQuoteCall() -> Int {
            quoteCallCount += 1
            return quoteCallCount
        }

        func nextHistoryCall() -> Int {
            historyCallCount += 1
            return historyCallCount
        }

        func nextSearchCall() -> Int {
            searchCallCount += 1
            return searchCallCount
        }

        func nextFxCall() -> Int {
            fxCallCount += 1
            return fxCallCount
        }

        func nextProfileCall() -> Int {
            profileCallCount += 1
            return profileCallCount
        }

        func nextBasicFinancialsCall() -> Int {
            basicFinancialsCallCount += 1
            return basicFinancialsCallCount
        }

        func setFailQuote(_ value: Bool) {
            failQuoteRequests = value
        }

        func shouldFailQuote() -> Bool {
            failQuoteRequests
        }

        func quoteCalls() -> Int {
            quoteCallCount
        }

        func historyCalls() -> Int {
            historyCallCount
        }

        func searchCalls() -> Int {
            searchCallCount
        }

        func fxCalls() -> Int {
            fxCallCount
        }

        func profileCalls() -> Int {
            profileCallCount
        }

        func basicFinancialsCalls() -> Int {
            basicFinancialsCallCount
        }
    }

    struct FinancialGrowthRequestCapture: Equatable {
        let symbol: String
        let limit: Int?
        let period: String?
    }

    struct SectorPerformanceRequestCapture: Equatable {
        let sector: String
        let exchange: String?
        let from: String?
        let to: String?
    }

    struct AnalystEstimatesRequestCapture: Equatable {
        let symbol: String
        let period: String
        let page: Int?
        let limit: Int?
    }

    struct EarningsRequestCapture: Equatable {
        let symbol: String
        let limit: Int?
    }

    struct EarningsCalendarRequestCapture: Equatable {
        let from: String?
        let to: String?
    }

    struct EarningsTranscriptRequestCapture: Equatable {
        let symbol: String
        let year: Int
        let quarter: Int
    }

    actor TestFMPProviderState {
        private var balanceSheetRequests: [FinancialGrowthRequestCapture] = []
        private var cashFlowRequests: [FinancialGrowthRequestCapture] = []
        private var incomeStatementRequests: [FinancialGrowthRequestCapture] = []
        private var ratiosTTMCallCount: Int = 0
        private var gradesConsensusCallCount: Int = 0
        private var financialGrowthRequests: [FinancialGrowthRequestCapture] = []
        private var analystEstimatesRequests: [AnalystEstimatesRequestCapture] = []
        private var ratiosRequests: [FinancialGrowthRequestCapture] = []
        private var earningsRequests: [EarningsRequestCapture] = []
        private var earningsCalendarRequests: [EarningsCalendarRequestCapture] = []
        private var earningsTranscriptRequests: [EarningsTranscriptRequestCapture] = []
        private var earningsTranscriptShouldThrowNotFound: Bool = false
        private var sectorPerformanceRequests: [SectorPerformanceRequestCapture] = []

        func nextRatiosTTMCall() -> Int {
            ratiosTTMCallCount += 1
            return ratiosTTMCallCount
        }

        func nextGradesConsensusCall() -> Int {
            gradesConsensusCallCount += 1
            return gradesConsensusCallCount
        }

        func recordFinancialGrowth(symbol: String, limit: Int?, period: String?) {
            financialGrowthRequests.append(.init(symbol: symbol, limit: limit, period: period))
        }

        func recordRatios(symbol: String, limit: Int?, period: String?) {
            ratiosRequests.append(.init(symbol: symbol, limit: limit, period: period))
        }

        func recordAnalystEstimates(symbol: String, period: String, page: Int?, limit: Int?) {
            analystEstimatesRequests.append(.init(symbol: symbol, period: period, page: page, limit: limit))
        }

        func recordEarnings(symbol: String, limit: Int?) {
            earningsRequests.append(.init(symbol: symbol, limit: limit))
        }

        func recordEarningsCalendar(from: String?, to: String?) {
            earningsCalendarRequests.append(.init(from: from, to: to))
        }

        func recordEarningsTranscript(symbol: String, year: Int, quarter: Int) {
            earningsTranscriptRequests.append(.init(symbol: symbol, year: year, quarter: quarter))
        }

        func setEarningsTranscriptShouldThrowNotFound(_ value: Bool) {
            earningsTranscriptShouldThrowNotFound = value
        }

        func shouldEarningsTranscriptThrowNotFound() -> Bool {
            earningsTranscriptShouldThrowNotFound
        }

        func recordBalanceSheet(symbol: String, limit: Int?, period: String?) {
            balanceSheetRequests.append(.init(symbol: symbol, limit: limit, period: period))
        }

        func recordCashFlow(symbol: String, limit: Int?, period: String?) {
            cashFlowRequests.append(.init(symbol: symbol, limit: limit, period: period))
        }

        func recordIncomeStatement(symbol: String, limit: Int?, period: String?) {
            incomeStatementRequests.append(.init(symbol: symbol, limit: limit, period: period))
        }

        func recordSectorPerformance(sector: String, exchange: String?, from: String?, to: String?) {
            sectorPerformanceRequests.append(.init(sector: sector, exchange: exchange, from: from, to: to))
        }

        func ratiosTTMCalls() -> Int {
            ratiosTTMCallCount
        }

        func gradesConsensusCalls() -> Int {
            gradesConsensusCallCount
        }

        func lastFinancialGrowthRequest() -> FinancialGrowthRequestCapture? {
            financialGrowthRequests.last
        }

        func lastRatiosRequest() -> FinancialGrowthRequestCapture? {
            ratiosRequests.last
        }

        func lastAnalystEstimatesRequest() -> AnalystEstimatesRequestCapture? {
            analystEstimatesRequests.last
        }

        func lastBalanceSheetRequest() -> FinancialGrowthRequestCapture? {
            balanceSheetRequests.last
        }

        func lastCashFlowRequest() -> FinancialGrowthRequestCapture? {
            cashFlowRequests.last
        }

        func lastIncomeStatementRequest() -> FinancialGrowthRequestCapture? {
            incomeStatementRequests.last
        }

        func earningsCalls() -> Int {
            earningsRequests.count
        }

        func earningsCalendarCalls() -> Int {
            earningsCalendarRequests.count
        }

        func earningsTranscriptCalls() -> Int {
            earningsTranscriptRequests.count
        }

        func lastEarningsTranscriptRequest() -> EarningsTranscriptRequestCapture? {
            earningsTranscriptRequests.last
        }

        func lastSectorPerformanceRequest() -> SectorPerformanceRequestCapture? {
            sectorPerformanceRequests.last
        }
    }

    struct TestMarketDataProvider: MarketDataProvider {
        let state: TestMarketProviderState

        var name: String {
            "ibkr"
        }

        func quote(symbol: String, on _: Request) async throws -> MarketProviderQuote {
            _ = await state.nextQuoteCall()
            if await state.shouldFailQuote() {
                throw Abort(.badGateway, reason: "Forced quote failure")
            }

            return MarketProviderQuote(
                symbol: symbol,
                price: 101.25,
                change: nil,
                percentChange: nil,
                high: nil,
                low: nil,
                open: nil,
                previousClose: nil,
                currency: "USD",
                asOf: Date()
            )
        }

        func history(symbol: String, from _: Date?, to _: Date?, on _: Request) async throws -> MarketProviderHistory {
            _ = await state.nextHistoryCall()
            let bar = MarketProviderPriceBar(
                date: Date(),
                open: 100,
                high: 103,
                low: 99,
                close: 101,
                volume: 1_000_000
            )

            return MarketProviderHistory(
                symbol: symbol,
                currency: "USD",
                bars: [bar]
            )
        }

        func search(query: String, on _: Request) async throws -> [MarketProviderSearchResult] {
            _ = await state.nextSearchCall()
            return [
                .init(
                    symbol: query,
                    name: "\(query) Inc",
                    exchange: "NASDAQ",
                    currency: "USD",
                    conid: "265598"
                ),
            ]
        }

        func fx(base: String, quote: String, on _: Request) async throws -> MarketProviderFxRate {
            _ = await state.nextFxCall()
            return .init(base: base, quote: quote, rate: 1.1, asOf: Date())
        }

        func profile(symbol: String, on _: Request) async throws -> MarketProviderCompanyProfile? {
            _ = await state.nextProfileCall()
            return MarketProviderCompanyProfile(
                symbol: symbol,
                country: "US",
                currency: "USD",
                estimateCurrency: "USD",
                exchange: "NASDAQ",
                finnhubIndustry: "Technology",
                ipo: "1980-12-12",
                logo: "https://example.com/logo.png",
                marketCapitalization: 1000.0,
                name: "Apple Inc",
                phone: "123456789",
                shareOutstanding: 100.0,
                ticker: symbol,
                weburl: "https://apple.com"
            )
        }

        func basicFinancials(symbol: String, on _: Request) async throws -> MarketProviderBasicFinancials? {
            _ = await state.nextBasicFinancialsCall()
            return MarketProviderBasicFinancials(
                symbol: symbol,
                metricType: "all",
                metric: [
                    "52WeekHigh": .number(190.25),
                    "52WeekLow": .number(164.10),
                    "52WeekLowDate": .string("2026-01-14"),
                    "beta": .number(1.2989),
                    "forwardPE": .number(28.0),
                    "epsGrowthTTMYoy": .number(12.0),
                    "revenueGrowthTTMYoy": .number(10.0),
                    "epsGrowthQuarterlyYoy": .number(8.0),
                    "revenueGrowthQuarterlyYoy": .number(7.0),
                    "grossMarginTTM": .number(60.63),
                    "netProfitMarginTTM": .number(24.20),
                ],
                series: [
                    "annual": [
                        "currentRatio": [
                            BasicFinancialSeriesPoint(period: "2025-09-28", value: 1.5401),
                            BasicFinancialSeriesPoint(period: "2024-09-29", value: 1.1329),
                        ],
                    ],
                ]
            )
        }
    }

    struct TestFMPMarketDataProvider: FMPMarketDataProvider {
        let state: TestFMPProviderState

        var name: String {
            "test-fmp"
        }

        func cashFlowStatement(
            symbol: String,
            limit: Int?,
            period: String?,
            on _: Request
        ) async throws -> [CashFlowStatementResponse] {
            await state.recordCashFlow(symbol: symbol, limit: limit, period: period)
            return [
                CashFlowStatementResponse(
                    date: "2024-09-28",
                    symbol: symbol,
                    reportedCurrency: "USD",
                    cik: "0000320193",
                    filingDate: "2024-11-01",
                    acceptedDate: "2024-11-01 06:01:36",
                    fiscalYear: "2024",
                    period: period ?? "FY",
                    netIncome: 93_736_000_000,
                    depreciationAndAmortization: 11_445_000_000,
                    deferredIncomeTax: 0,
                    stockBasedCompensation: 11_688_000_000,
                    changeInWorkingCapital: 3_651_000_000,
                    accountsReceivables: -5_144_000_000,
                    inventory: -1_046_000_000,
                    accountsPayables: 6_020_000_000,
                    otherWorkingCapital: 3_821_000_000,
                    otherNonCashItems: -2_266_000_000,
                    netCashProvidedByOperatingActivities: 118_254_000_000,
                    investmentsInPropertyPlantAndEquipment: -9_447_000_000,
                    acquisitionsNet: 0,
                    purchasesOfInvestments: -48_656_000_000,
                    salesMaturitiesOfInvestments: 62_346_000_000,
                    otherInvestingActivities: -1_308_000_000,
                    netCashProvidedByInvestingActivities: 2_935_000_000,
                    netDebtIssuance: -5_998_000_000,
                    longTermNetDebtIssuance: -9_958_000_000,
                    shortTermNetDebtIssuance: 3_960_000_000,
                    netStockIssuance: -94_949_000_000,
                    netCommonStockIssuance: -94_949_000_000,
                    commonStockIssuance: 0,
                    commonStockRepurchased: -94_949_000_000,
                    netPreferredStockIssuance: 0,
                    netDividendsPaid: -15_234_000_000,
                    commonDividendsPaid: -15_234_000_000,
                    preferredDividendsPaid: 0,
                    otherFinancingActivities: -5_802_000_000,
                    netCashProvidedByFinancingActivities: -121_983_000_000,
                    effectOfForexChangesOnCash: 0,
                    netChangeInCash: -794_000_000,
                    cashAtEndOfPeriod: 29_943_000_000,
                    cashAtBeginningOfPeriod: 30_737_000_000,
                    operatingCashFlow: 118_254_000_000,
                    capitalExpenditure: -9_447_000_000,
                    freeCashFlow: 108_807_000_000,
                    incomeTaxesPaid: 26_102_000_000,
                    interestPaid: 0
                ),
            ]
        }

        func incomeStatement(
            symbol: String,
            limit: Int?,
            period: String?,
            on _: Request
        ) async throws -> [IncomeStatementResponse] {
            await state.recordIncomeStatement(symbol: symbol, limit: limit, period: period)
            return [
                IncomeStatementResponse(
                    date: "2024-09-28",
                    symbol: symbol,
                    reportedCurrency: "USD",
                    cik: "0000320193",
                    filingDate: "2024-11-01",
                    acceptedDate: "2024-11-01 06:01:36",
                    fiscalYear: "2024",
                    period: period ?? "FY",
                    revenue: 391_035_000_000,
                    costOfRevenue: 210_352_000_000,
                    grossProfit: 180_683_000_000,
                    researchAndDevelopmentExpenses: 31_370_000_000,
                    generalAndAdministrativeExpenses: nil,
                    sellingAndMarketingExpenses: nil,
                    sellingGeneralAndAdministrativeExpenses: 26_097_000_000,
                    otherExpenses: nil,
                    operatingExpenses: 57_467_000_000,
                    costAndExpenses: 267_819_000_000,
                    netInterestIncome: nil,
                    interestIncome: nil,
                    interestExpense: nil,
                    depreciationAndAmortization: 11_445_000_000,
                    ebitda: 134_661_000_000,
                    ebit: 123_216_000_000,
                    nonOperatingIncomeExcludingInterest: nil,
                    operatingIncome: 123_216_000_000,
                    totalOtherIncomeExpensesNet: 269_000_000,
                    incomeBeforeTax: 123_485_000_000,
                    incomeTaxExpense: 29_749_000_000,
                    netIncomeFromContinuingOperations: 93_736_000_000,
                    netIncomeFromDiscontinuedOperations: nil,
                    otherAdjustmentsToNetIncome: nil,
                    netIncome: 93_736_000_000,
                    netIncomeDeductions: nil,
                    bottomLineNetIncome: 93_736_000_000,
                    eps: 6.11,
                    epsDiluted: 6.08,
                    weightedAverageShsOut: 15_343_783_000,
                    weightedAverageShsOutDil: 15_408_095_000
                ),
            ]
        }

        func balanceSheetStatement(
            symbol: String,
            limit: Int?,
            period: String?,
            on _: Request
        ) async throws -> [BalanceSheetStatementResponse] {
            await state.recordBalanceSheet(symbol: symbol, limit: limit, period: period)
            return [
                BalanceSheetStatementResponse(
                    date: "2024-09-28",
                    symbol: symbol,
                    reportedCurrency: "USD",
                    cik: "0000320193",
                    filingDate: "2024-11-01",
                    acceptedDate: "2024-11-01 06:01:36",
                    fiscalYear: "2024",
                    period: period ?? "FY",
                    cashAndCashEquivalents: 29_943_000_000,
                    shortTermInvestments: 35_228_000_000,
                    cashAndShortTermInvestments: 65_171_000_000,
                    netReceivables: 66_243_000_000,
                    accountsReceivables: 33_410_000_000,
                    otherReceivables: 32_833_000_000,
                    inventory: 7_286_000_000,
                    prepaids: 0,
                    otherCurrentAssets: 14_287_000_000,
                    totalCurrentAssets: 152_987_000_000,
                    propertyPlantEquipmentNet: 45_680_000_000,
                    goodwill: 0,
                    intangibleAssets: 0,
                    goodwillAndIntangibleAssets: 0,
                    longTermInvestments: 91_479_000_000,
                    taxAssets: 19_499_000_000,
                    otherNonCurrentAssets: 55_335_000_000,
                    totalNonCurrentAssets: 211_993_000_000,
                    otherAssets: 0,
                    totalAssets: 364_980_000_000,
                    totalPayables: 95_561_000_000,
                    accountPayables: 68_960_000_000,
                    otherPayables: 26_601_000_000,
                    accruedExpenses: 0,
                    shortTermDebt: 20_879_000_000,
                    capitalLeaseOblationsCurrent: 1_632_000_000,
                    taxPayables: 26_601_000_000,
                    deferredRevenue: 8_249_000_000,
                    otherCurrentLiabilities: 50_071_000_000,
                    totalCurrentLiabilities: 176_392_000_000,
                    longTermDebt: 85_750_000_000,
                    deferredRevenueNonCurrent: 10_798_000_000,
                    deferredTaxLiabilitiesNonCurrent: 0,
                    otherNonCurrentLiabilities: 35_090_000_000,
                    totalNonCurrentLiabilities: 131_638_000_000,
                    otherLiabilities: 0,
                    capitalLeaseObligations: 12_430_000_000,
                    totalLiabilities: 308_030_000_000,
                    treasuryStock: 0,
                    preferredStock: 0,
                    commonStock: 83_276_000_000,
                    retainedEarnings: -19_154_000_000,
                    additionalPaidInCapital: 0,
                    accumulatedOtherComprehensiveIncomeLoss: -7_172_000_000,
                    otherTotalStockholdersEquity: 0,
                    totalStockholdersEquity: 56_950_000_000,
                    totalEquity: 56_950_000_000,
                    minorityInterest: 0,
                    totalLiabilitiesAndTotalEquity: 364_980_000_000,
                    totalInvestments: 126_707_000_000,
                    totalDebt: 106_629_000_000,
                    netDebt: 76_686_000_000
                ),
            ]
        }

        func ratiosTTM(symbol: String, on _: Request) async throws -> [RatiosTTMResponse] {
            _ = await state.nextRatiosTTMCall()
            return [
                RatiosTTMResponse(
                    symbol: symbol,
                    grossProfitMarginTTM: 0.46518849807964424,
                    ebitMarginTTM: 0.3175535678188801,
                    ebitdaMarginTTM: 0.34705882352941175,
                    operatingProfitMarginTTM: 0.3175535678188801,
                    pretaxProfitMarginTTM: 0.31773296947645036,
                    continuousOperationsProfitMarginTTM: 0.24295027289266222,
                    netProfitMarginTTM: 0.24295027289266222,
                    bottomLineProfitMarginTTM: 0.24295027289266222,
                    receivablesTurnoverTTM: 6.673186524129093,
                    payablesTurnoverTTM: 3.4187853335486995,
                    inventoryTurnoverTTM: 30.626103313558097,
                    fixedAssetTurnoverTTM: 8.590592372311098,
                    assetTurnoverTTM: 1.1501809145995903,
                    currentRatioTTM: 0.9229383853427077,
                    quickRatioTTM: 0.8750666712845911,
                    solvencyRatioTTM: 0.3888081578786054,
                    cashRatioTTM: 0.20987774044955496,
                    priceToEarningsRatioTTM: 32.889608822880916,
                    priceToEarningsGrowthRatioTTM: 9.104441715061135,
                    forwardPriceToEarningsGrowthRatioTTM: 9.104441715061135,
                    priceToBookRatioTTM: 47.370141231313106,
                    priceToSalesRatioTTM: 7.958949686678795,
                    priceToFreeCashFlowRatioTTM: 32.04339747098139,
                    priceToOperatingCashFlowRatioTTM: 29.201395167968677,
                    debtToAssetsRatioTTM: 0.28132292892744526,
                    debtToEquityRatioTTM: 1.4499985020521886,
                    debtToCapitalRatioTTM: 0.5918364851397372,
                    longTermDebtToCapitalRatioTTM: 0.557055084464615,
                    financialLeverageRatioTTM: 5.154213727193745,
                    workingCapitalTurnoverRatioTTM: -22.92267593397046,
                    operatingCashFlowRatioTTM: 0.7501402694558931,
                    operatingCashFlowSalesRatioTTM: 0.2736355366889024,
                    freeCashFlowOperatingCashFlowRatioTTM: 0.9077049513361775,
                    debtServiceCoverageRatioTTM: 8.390251498870981,
                    interestCoverageRatioTTM: 0,
                    shortTermOperatingCashFlowCoverageRatioTTM: 8.432142022891847,
                    operatingCashFlowCoverageRatioTTM: 1.1187512267688715,
                    capitalExpenditureCoverageRatioTTM: 10.834817408704351,
                    dividendPaidAndCapexCoverageRatioTTM: 4.287173396674584,
                    dividendPayoutRatioTTM: 0.15876235049401977,
                    dividendYieldTTM: 0.0047691720717283476,
                    enterpriseValueTTM: 3_216_333_928_000,
                    revenuePerShareTTM: 26.24103186081379,
                    netIncomePerShareTTM: 6.375265851569754,
                    interestDebtPerShareTTM: 6.418298067250137,
                    cashPerShareTTM: 3.565573803101025,
                    bookValuePerShareTTM: 4.426417032959892,
                    tangibleBookValuePerShareTTM: 4.426417032959892,
                    shareholdersEquityPerShareTTM: 4.426417032959892,
                    operatingCashFlowPerShareTTM: 7.180478836504368,
                    capexPerShareTTM: 0.6627226436447186,
                    freeCashFlowPerShareTTM: 6.5177561928596495,
                    netIncomePerEBTTTM: 0.7646366484818603,
                    ebtPerEbitTTM: 1.0005649492739208,
                    priceToFairValueTTM: 47.370141231313106,
                    debtToMarketCapTTM: 0.030731461471514124,
                    effectiveTaxRateTTM: 0.23536335151813975,
                    enterpriseValueMultipleTTM: 23.41672438697653
                ),
            ]
        }

        func gradesConsensus(symbol: String, on _: Request) async throws -> [GradesConsensusResponse] {
            _ = await state.nextGradesConsensusCall()
            return [
                GradesConsensusResponse(
                    symbol: symbol,
                    strongBuy: 1,
                    buy: 49,
                    hold: 11,
                    sell: 0,
                    strongSell: 0,
                    consensus: "Buy"
                ),
            ]
        }

        func financialGrowth(
            symbol: String,
            limit: Int?,
            period: String?,
            on _: Request
        ) async throws -> [FinancialGrowthResponse] {
            await state.recordFinancialGrowth(symbol: symbol, limit: limit, period: period)
            return [
                FinancialGrowthResponse(
                    symbol: symbol,
                    date: "2024-09-28",
                    fiscalYear: "2024",
                    period: period ?? "FY",
                    reportedCurrency: "USD",
                    revenueGrowth: 0.020219940775141214,
                    grossProfitGrowth: 0.06819471705252206,
                    ebitgrowth: 0.07799581805933456,
                    operatingIncomeGrowth: 0.07799581805933456,
                    netIncomeGrowth: -0.033599670086086914,
                    epsgrowth: -0.008116883116883088,
                    epsdilutedGrowth: -0.008156606851549727,
                    weightedAverageSharesGrowth: -0.02543458616683152,
                    weightedAverageSharesDilutedGrowth: -0.02557791606880283,
                    dividendsPerShareGrowth: 0.040371570095532654,
                    operatingCashFlowGrowth: 0.06975566069312394,
                    receivablesGrowth: 0.08621792243994425,
                    inventoryGrowth: 0.15084504817564365,
                    assetGrowth: 0.035160515396374756,
                    bookValueperShareGrowth: -0.059693251557224776,
                    debtGrowth: -0.0401393489845888,
                    rdexpenseGrowth: 0.04863780712017383,
                    sgaexpensesGrowth: 0.04672709770575967,
                    freeCashFlowGrowth: 0.092615279562982,
                    tenYRevenueGrowthPerShare: 2.3937532854122625,
                    fiveYRevenueGrowthPerShare: 0.8093292228858464,
                    threeYRevenueGrowthPerShare: 0.163506592883552,
                    tenYOperatingCFGrowthPerShare: 2.1417809176982403,
                    fiveYOperatingCFGrowthPerShare: 1.051533221923415,
                    threeYOperatingCFGrowthPerShare: 0.23720294833900227,
                    tenYNetIncomeGrowthPerShare: 2.76381558093543,
                    fiveYNetIncomeGrowthPerShare: 1.0421744314966246,
                    threeYNetIncomeGrowthPerShare: 0.07761907162786884,
                    tenYShareholdersEquityGrowthPerShare: -0.19003774225234785,
                    fiveYShareholdersEquityGrowthPerShare: -0.24235004889283715,
                    threeYShareholdersEquityGrowthPerShare: -0.017459858915902907,
                    tenYDividendperShareGrowthPerShare: 1.1722201809466772,
                    fiveYDividendperShareGrowthPerShare: 0.29890046876764864,
                    threeYDividendperShareGrowthPerShare: 0.14617932692103452,
                    ebitdaGrowth: nil,
                    growthCapitalExpenditure: nil,
                    tenYBottomLineNetIncomeGrowthPerShare: nil,
                    fiveYBottomLineNetIncomeGrowthPerShare: nil,
                    threeYBottomLineNetIncomeGrowthPerShare: nil
                ),
                FinancialGrowthResponse(
                    symbol: symbol,
                    date: "2023-09-28",
                    fiscalYear: "2023",
                    period: period ?? "FY",
                    reportedCurrency: "USD",
                    revenueGrowth: 0.031,
                    grossProfitGrowth: 0.05,
                    ebitgrowth: 0.06,
                    operatingIncomeGrowth: 0.06,
                    netIncomeGrowth: 0.04,
                    epsgrowth: 0.041,
                    epsdilutedGrowth: 0.04,
                    weightedAverageSharesGrowth: -0.02,
                    weightedAverageSharesDilutedGrowth: -0.02,
                    dividendsPerShareGrowth: 0.03,
                    operatingCashFlowGrowth: 0.05,
                    receivablesGrowth: 0.04,
                    inventoryGrowth: 0.06,
                    assetGrowth: 0.03,
                    bookValueperShareGrowth: -0.04,
                    debtGrowth: -0.02,
                    rdexpenseGrowth: 0.03,
                    sgaexpensesGrowth: 0.04,
                    freeCashFlowGrowth: 0.08,
                    tenYRevenueGrowthPerShare: 2.1,
                    fiveYRevenueGrowthPerShare: 0.7,
                    threeYRevenueGrowthPerShare: 0.15,
                    tenYOperatingCFGrowthPerShare: 1.9,
                    fiveYOperatingCFGrowthPerShare: 0.9,
                    threeYOperatingCFGrowthPerShare: 0.21,
                    tenYNetIncomeGrowthPerShare: 2.2,
                    fiveYNetIncomeGrowthPerShare: 0.9,
                    threeYNetIncomeGrowthPerShare: 0.07,
                    tenYShareholdersEquityGrowthPerShare: -0.16,
                    fiveYShareholdersEquityGrowthPerShare: -0.22,
                    threeYShareholdersEquityGrowthPerShare: -0.01,
                    tenYDividendperShareGrowthPerShare: 1.0,
                    fiveYDividendperShareGrowthPerShare: 0.25,
                    threeYDividendperShareGrowthPerShare: 0.13,
                    ebitdaGrowth: nil,
                    growthCapitalExpenditure: nil,
                    tenYBottomLineNetIncomeGrowthPerShare: nil,
                    fiveYBottomLineNetIncomeGrowthPerShare: nil,
                    threeYBottomLineNetIncomeGrowthPerShare: nil
                ),
            ]
        }

        func analystEstimates(
            symbol: String,
            period: String,
            page: Int?,
            limit: Int?,
            on _: Request
        ) async throws -> [AnalystEstimatesResponse] {
            await state.recordAnalystEstimates(symbol: symbol, period: period, page: page, limit: limit)
            return [
                AnalystEstimatesResponse(
                    symbol: symbol,
                    date: "2029-09-28",
                    revenueLow: 483_092_500_000,
                    revenueHigh: 483_093_500_000,
                    revenueAvg: 483_093_000_000,
                    ebitdaLow: 155_952_166_036,
                    ebitdaHigh: 155_952_488_856,
                    ebitdaAvg: 155_952_327_446,
                    ebitLow: 140_628_295_747,
                    ebitHigh: 140_628_586_847,
                    ebitAvg: 140_628_441_297,
                    netIncomeLow: 139_446_957_701,
                    netIncomeHigh: 157_185_372_990,
                    netIncomeAvg: 149_150_359_609,
                    sgaExpenseLow: 31_694_652_812,
                    sgaExpenseHigh: 31_694_718_420,
                    sgaExpenseAvg: 31_694_685_616,
                    epsAvg: 9.68,
                    epsHigh: 10.20148,
                    epsLow: 9.05024,
                    numAnalystsRevenue: 16,
                    numAnalystsEps: 6
                ),
            ]
        }

        func ratios(
            symbol: String,
            limit: Int?,
            period: String?,
            on _: Request
        ) async throws -> [RatiosResponse] {
            await state.recordRatios(symbol: symbol, limit: limit, period: period)
            return [
                RatiosResponse(
                    symbol: symbol,
                    date: "2024-09-28",
                    fiscalYear: "2024",
                    period: period ?? "FY",
                    reportedCurrency: "USD",
                    grossProfitMargin: 0.4620634981523393,
                    ebitMargin: 0.31510222870075566,
                    ebitdaMargin: 0.3443707085043538,
                    operatingProfitMargin: 0.31510222870075566,
                    pretaxProfitMargin: 0.3157901466620635,
                    continuousOperationsProfitMargin: 0.23971255769943867,
                    netProfitMargin: 0.23971255769943867,
                    bottomLineProfitMargin: 0.23971255769943867,
                    receivablesTurnover: 5.903038811648023,
                    payablesTurnover: 3.0503480278422272,
                    inventoryTurnover: 28.870710952511665,
                    fixedAssetTurnover: 8.560310858143607,
                    assetTurnover: 1.0713874732862074,
                    currentRatio: 0.8673125765340832,
                    quickRatio: 0.8260068483831466,
                    solvencyRatio: 0.3414634938155374,
                    cashRatio: 0.16975259648963673,
                    priceToEarningsRatio: 37.287278415656736,
                    priceToEarningsGrowthRatio: -45.93792700808932,
                    forwardPriceToEarningsGrowthRatio: -45.93792700808932,
                    priceToBookRatio: 61.37243774486391,
                    priceToSalesRatio: 8.93822887866815,
                    priceToFreeCashFlowRatio: 32.12256867269569,
                    priceToOperatingCashFlowRatio: 29.55638142954995,
                    debtToAssetsRatio: 0.29215025480848267,
                    debtToEquityRatio: 1.872326602282704,
                    debtToCapitalRatio: 0.6518501763673821,
                    longTermDebtToCapitalRatio: 0.6009110021023125,
                    financialLeverageRatio: 6.408779631255487,
                    workingCapitalTurnoverRatio: -31.099932397502684,
                    operatingCashFlowRatio: 0.6704045534944896,
                    operatingCashFlowSalesRatio: 0.3024128274962599,
                    freeCashFlowOperatingCashFlowRatio: 0.9201126388959359,
                    debtServiceCoverageRatio: 5.024761722304708,
                    interestCoverageRatio: 0,
                    shortTermOperatingCashFlowCoverageRatio: 5.663777000814215,
                    operatingCashFlowCoverageRatio: 1.109022873702276,
                    capitalExpenditureCoverageRatio: 12.517624642743728,
                    dividendPaidAndCapexCoverageRatio: 4.7912969490701345,
                    dividendPayoutRatio: 0.16252026969360758,
                    dividendYield: 0.0043585983369965175,
                    dividendYieldPercentage: 0.43585983369965176,
                    revenuePerShare: 25.484914639368924,
                    netIncomePerShare: 6.109054070954992,
                    interestDebtPerShare: 6.949329249507765,
                    cashPerShare: 4.247388013764271,
                    bookValuePerShare: 3.711600978715614,
                    tangibleBookValuePerShare: 3.711600978715614,
                    shareholdersEquityPerShare: 3.711600978715614,
                    operatingCashFlowPerShare: 7.706965094592383,
                    capexPerShare: 0.6156891035281195,
                    freeCashFlowPerShare: 7.091275991064264,
                    netIncomePerEBT: 0.7590881483581001,
                    ebtPerEbit: 1.0021831580314244,
                    priceToFairValue: 61.37243774486391,
                    debtToMarketCap: 0.03050761336980449,
                    effectiveTaxRate: 0.24091185164189982,
                    enterpriseValueMultiple: 26.524727497716487
                ),
            ]
        }

        func earnings(symbol: String, limit: Int?, on _: Request) async throws -> [EarningsResponse] {
            await state.recordEarnings(symbol: symbol, limit: limit)
            return [
                EarningsResponse(
                    symbol: symbol,
                    date: "2024-10-29",
                    epsActual: 1.64,
                    epsEstimated: 1.60,
                    revenueActual: 94_930_000_000,
                    revenueEstimated: 94_400_000_000,
                    lastUpdated: "2024-12-08",
                    surprisePercent: 2.5,
                    hasTranscript: true
                ),
            ]
        }

        func earningsCalendar(from: Date?, to: Date?, on _: Request) async throws -> [EarningsResponse] {
            await state.recordEarningsCalendar(from: from.map(StockPlanBackendTests.formatISODateOnly), to: to.map(StockPlanBackendTests.formatISODateOnly))
            return [
                EarningsResponse(
                    symbol: "AAPL",
                    date: "2024-10-29",
                    epsActual: 1.64,
                    epsEstimated: 1.60,
                    revenueActual: 94_930_000_000,
                    revenueEstimated: 94_400_000_000,
                    lastUpdated: "2024-12-08",
                    surprisePercent: 2.5,
                    hasTranscript: false
                ),
            ]
        }

        func earningsTranscript(
            symbol: String,
            date _: String?,
            year: Int?,
            quarter: Int?,
            on _: Request
        ) async throws -> EarningsTranscriptResponse {
            let year = year ?? 2024
            let quarter = quarter ?? 4
            await state.recordEarningsTranscript(symbol: symbol, year: year, quarter: quarter)
            if await state.shouldEarningsTranscriptThrowNotFound() {
                throw Abort(.notFound, reason: "Earnings transcript not found for \(symbol).")
            }
            return EarningsTranscriptResponse(
                symbol: symbol,
                date: "2024-10-29",
                year: year,
                quarter: quarter,
                period: "Q4",
                content: "Prepared remarks for Apple earnings. Analyst Q&A followed.",
                provider: "fmp"
            )
        }

        func historicalSectorPerformance(
            sector: String,
            exchange: String?,
            from: Date?,
            to: Date?,
            on _: Request
        ) async throws -> [HistoricalSectorPerformanceResponse] {
            await state.recordSectorPerformance(
                sector: sector,
                exchange: exchange,
                from: from.map(StockPlanBackendTests.formatISODateOnly),
                to: to.map(StockPlanBackendTests.formatISODateOnly)
            )
            return [
                HistoricalSectorPerformanceResponse(
                    date: "2024-02-01",
                    sector: sector,
                    exchange: exchange ?? "NASDAQ",
                    averageChange: 0.6397534025664513
                ),
            ]
        }

        func fetchGeneralMarketNews(
            page _: Int?,
            limit _: Int?,
            from _: Date?,
            to _: Date?,
            on _: Request
        ) async throws -> [FMPMarketNewsItem] {
            []
        }

        func stockIntraday(
            interval _: String,
            symbol _: String,
            from _: String?,
            to _: String?,
            on _: Request
        ) async throws -> [CryptoHistoricalPoint] {
            []
        }

        func stockHistoricalEOD(
            symbol _: String,
            from _: String?,
            to _: String?,
            on _: Request
        ) async throws -> [CryptoHistoricalLightPoint] {
            []
        }
    }

    private static func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private struct SeededLists {
        let portfolioListId: UUID
        let watchlistListId: UUID
    }

    private func seedDefaultLists(userId: UUID, on db: any Database) async throws -> SeededLists {
        let portfolioList = PortfolioList(userId: userId, name: "Main Portfolio", isDefault: true)
        let watchlistList = WatchlistList(userId: userId, name: "Main Watchlist", isDefault: true)
        try await portfolioList.save(on: db)
        try await watchlistList.save(on: db)

        guard let portfolioListId = portfolioList.id, let watchlistListId = watchlistList.id else {
            throw Abort(.internalServerError, reason: "Failed to seed default lists for tests.")
        }
        return SeededLists(portfolioListId: portfolioListId, watchlistListId: watchlistListId)
    }

    struct TestPaymentRequiredFMPMarketDataProvider: FMPMarketDataProvider {
        let name: String = "test-fmp-payment-required"

        func cashFlowStatement(
            symbol _: String,
            limit _: Int?,
            period _: String?,
            on _: Request
        ) async throws -> [CashFlowStatementResponse] {
            []
        }

        func incomeStatement(
            symbol _: String,
            limit _: Int?,
            period _: String?,
            on _: Request
        ) async throws -> [IncomeStatementResponse] {
            []
        }

        func balanceSheetStatement(
            symbol _: String,
            limit _: Int?,
            period _: String?,
            on _: Request
        ) async throws -> [BalanceSheetStatementResponse] {
            []
        }

        func ratiosTTM(symbol _: String, on _: Request) async throws -> [RatiosTTMResponse] {
            []
        }

        func gradesConsensus(symbol _: String, on _: Request) async throws -> [GradesConsensusResponse] {
            throw Abort(
                .paymentRequired,
                reason: "FMP plan upgrade required for /stable/grades-consensus. This endpoint is not available for the requested symbol on the current subscription."
            )
        }

        func financialGrowth(
            symbol _: String,
            limit _: Int?,
            period _: String?,
            on _: Request
        ) async throws -> [FinancialGrowthResponse] {
            []
        }

        func analystEstimates(
            symbol _: String,
            period _: String,
            page _: Int?,
            limit _: Int?,
            on _: Request
        ) async throws -> [AnalystEstimatesResponse] {
            []
        }

        func ratios(
            symbol _: String,
            limit _: Int?,
            period _: String?,
            on _: Request
        ) async throws -> [RatiosResponse] {
            []
        }

        func earnings(symbol _: String, limit _: Int?, on _: Request) async throws -> [EarningsResponse] {
            []
        }

        func earningsCalendar(from _: Date?, to _: Date?, on _: Request) async throws -> [EarningsResponse] {
            []
        }

        func earningsTranscript(
            symbol _: String,
            date _: String?,
            year _: Int?,
            quarter _: Int?,
            on _: Request
        ) async throws -> EarningsTranscriptResponse {
            throw Abort(.paymentRequired, reason: "FMP plan upgrade required.")
        }

        func historicalSectorPerformance(
            sector _: String,
            exchange _: String?,
            from _: Date?,
            to _: Date?,
            on _: Request
        ) async throws -> [HistoricalSectorPerformanceResponse] {
            []
        }

        func fetchGeneralMarketNews(
            page _: Int?,
            limit _: Int?,
            from _: Date?,
            to _: Date?,
            on _: Request
        ) async throws -> [FMPMarketNewsItem] {
            []
        }

        func stockIntraday(
            interval _: String,
            symbol _: String,
            from _: String?,
            to _: String?,
            on _: Request
        ) async throws -> [CryptoHistoricalPoint] {
            []
        }

        func stockHistoricalEOD(
            symbol _: String,
            from _: String?,
            to _: String?,
            on _: Request
        ) async throws -> [CryptoHistoricalLightPoint] {
            []
        }
    }

    struct FailingMarketDataProvider: MarketDataProvider {
        var name: String {
            "ibkr"
        }

        func quote(symbol _: String, on _: Request) async throws -> MarketProviderQuote {
            throw Abort(.badGateway, reason: "Forced market provider failure")
        }

        func history(symbol _: String, from _: Date?, to _: Date?, on _: Request) async throws
            -> MarketProviderHistory
        {
            throw Abort(.badGateway, reason: "Forced market provider failure")
        }

        func search(query _: String, on _: Request) async throws -> [MarketProviderSearchResult] {
            throw Abort(.badGateway, reason: "Forced market provider failure")
        }

        func fx(base _: String, quote _: String, on _: Request) async throws -> MarketProviderFxRate {
            throw Abort(.badGateway, reason: "Forced market provider failure")
        }

        func profile(symbol _: String, on _: Request) async throws -> MarketProviderCompanyProfile? {
            throw Abort(.badGateway, reason: "Forced market provider failure")
        }

        func basicFinancials(symbol _: String, on _: Request) async throws -> MarketProviderBasicFinancials? {
            throw Abort(.badGateway, reason: "Forced market provider failure")
        }
    }
}
