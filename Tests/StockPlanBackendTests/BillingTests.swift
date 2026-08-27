import Fluent
import Foundation
@testable import StockPlanBackend
import struct StockPlanShared.CryptoPortfolioItemRequest
import Testing
import VaporTesting

@Suite("Billing Tests", .serialized)
struct BillingTests {
    private let secret = "test-billing-secret"

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("REVENUECAT_WEBHOOK_SECRET", secret, 1)
            setenv("BYPASS_BILLING", "false", 1)
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
        keepDefaultTrial: Bool = false,
        email: String? = nil
    ) async throws -> AuthResponse {
        let usernameSuffix = String(identifier.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(18))
        let request = AuthRegisterRequest(
            username: "billing_\(usernameSuffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: email ?? "billing+\(identifier)@example.com",
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
        if !keepDefaultTrial {
            let user = try #require(try await User.find(auth.userId, on: app.db))
            user.trialStartedAt = nil
            user.trialDays = nil
            user.trialTier = nil
            try await user.save(on: app.db)
        }
        return auth
    }

    private func makePayload(
        type: String,
        eventId: String,
        appUserId: String,
        productId: String = "pro_yearly",
        expirationAtMs: Int64? = nil,
        gracePeriodMs: Int64? = nil,
        originalTransactionId: String? = nil,
        newProductId: String? = nil,
        store: String? = nil
    ) -> String {
        var fields = """
        "id": "\(eventId)",
        "type": "\(type)",
        "app_user_id": "\(appUserId)",
        "product_id": "\(productId)"
        """
        if let ms = expirationAtMs {
            fields += ",\n\"expiration_at_ms\": \(ms)"
        }
        if let ms = gracePeriodMs {
            fields += ",\n\"grace_period_expires_date_ms\": \(ms)"
        }
        if let originalTransactionId {
            fields += ",\n\"original_transaction_id\": \"\(originalTransactionId)\""
        }
        if let newProductId {
            fields += ",\n\"new_product_id\": \"\(newProductId)\""
        }
        if let store {
            fields += ",\n\"store\": \"\(store)\""
        }
        return "{\"event\": {\(fields)}}"
    }

    private func post(
        _ payload: String,
        authorization: String?,
        on app: Application
    ) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.testing().test(.POST, "webhooks/revenuecat", beforeRequest: { req in
            req.headers.contentType = .json
            if let auth = authorization {
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }
            req.body = .init(string: payload)
        }, afterResponse: { res async throws in
            status = res.status
        })
        return status
    }

    private func grantPremium(userId: UUID, on app: Application) async throws {
        let entitlement = Entitlement(userId: userId, level: "pro")
        try await entitlement.save(on: app.db)
    }

    private func createStock(
        symbol: String,
        token: String,
        on app: Application
    ) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var body = ""
        try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(
                StockRequest(
                    symbol: symbol,
                    shares: 1,
                    buyPrice: 100,
                    buyDate: "2026-01-01",
                    notes: nil
                )
            )
        }, afterResponse: { res async in
            status = res.status
            body = res.body.string
        })
        return (status, body)
    }

    private func commitCsv(
        token: String,
        csv: String,
        on app: Application
    ) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var body = ""
        try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.headers.contentType = .plainText
            req.body = .init(string: csv)
        }, afterResponse: { res async in
            status = res.status
            body = res.body.string
        })
        return (status, body)
    }

    private func get(
        _ path: String,
        token: String,
        on app: Application
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

    private func request(
        _ method: HTTPMethod,
        _ path: String,
        token: String,
        body: (any Content)? = nil,
        on app: Application
    ) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var responseBody = ""
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            if let body {
                try req.content.encode(body)
            }
        }, afterResponse: { res async in
            status = res.status
            responseBody = res.body.string
        })
        return (status, responseBody)
    }

    private func getBillingContext(
        token: String,
        on app: Application
    ) async throws -> (HTTPStatus, BillingContextResponse?, String) {
        var status: HTTPStatus = .internalServerError
        var context: BillingContextResponse?
        var body = ""
        try await app.testing().test(.GET, "v1/billing/me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            status = res.status
            body = res.body.string
            if res.status == .ok {
                context = try res.content.decode(BillingContextResponse.self)
            }
        })
        return (status, context, body)
    }

    private func validateCoupon(
        code: String,
        token: String,
        on app: Application
    ) async throws -> (HTTPStatus, CouponResponse?, String) {
        var status: HTTPStatus = .internalServerError
        var coupon: CouponResponse?
        var body = ""
        try await app.testing().test(.POST, "v1/billing/coupons/validate", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CouponCodeRequest(code: code))
        }, afterResponse: { res async throws in
            status = res.status
            body = res.body.string
            if res.status == .ok {
                coupon = try res.content.decode(CouponResponse.self)
            }
        })
        return (status, coupon, body)
    }

    private func redeemCoupon(
        code: String,
        token: String,
        on app: Application
    ) async throws -> (HTTPStatus, CouponRedemptionResponse?, String) {
        var status: HTTPStatus = .internalServerError
        var redemption: CouponRedemptionResponse?
        var body = ""
        try await app.testing().test(.POST, "v1/billing/coupons/redeem", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CouponCodeRequest(code: code))
        }, afterResponse: { res async throws in
            status = res.status
            body = res.body.string
            if res.status == .ok {
                redemption = try res.content.decode(CouponRedemptionResponse.self)
            }
        })
        return (status, redemption, body)
    }

    private func assertUpgradeRequired(
        _ result: (HTTPStatus, String),
        feature: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.0 == .forbidden, sourceLocation: sourceLocation)
        #expect(result.1.contains("\"code\":\"upgrade_required\"") || result.1.contains("upgrade_required"), sourceLocation: sourceLocation)
        #expect(result.1.contains("\"feature\":\"\(feature)\"") || result.1.contains("feature=\(feature)"), sourceLocation: sourceLocation)
        #expect(result.1.contains("\"requiredPlan\":\"pro\"") || result.1.contains("required=pro"), sourceLocation: sourceLocation)
    }

    private func assertNotUpgradeRequired(
        _ result: (HTTPStatus, String),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.0 != .forbidden || !result.1.contains("upgrade_required"), sourceLocation: sourceLocation)
    }

    private func assertAllFeaturesAvailable(
        _ context: BillingContextResponse,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(context.isPremium == true, sourceLocation: sourceLocation)
        #expect(!context.features.contains(where: { !$0.available }), sourceLocation: sourceLocation)
        #expect(context.usage.first { $0.key == "holdings" }?.limit == nil, sourceLocation: sourceLocation)
        #expect(context.usage.first { $0.key == "csv_imports" }?.limit == nil, sourceLocation: sourceLocation)
        #expect(context.usage.first { $0.key == "report_generations" }?.limit == nil, sourceLocation: sourceLocation)
    }

    private func paidFeatureGateResults(
        token: String,
        on app: Application
    ) async throws -> [(feature: String, result: (HTTPStatus, String))] {
        let valuation = StockValuationRequest(
            symbol: "AAPL",
            bearCase: PriceRange(low: 10, high: 12),
            baseCase: PriceRange(low: 13, high: 15),
            bullCase: PriceRange(low: 16, high: 20),
            rationale: nil,
            targetDate: nil
        )
        let target = TargetRequest(
            symbol: "AAPL",
            scenario: "bull",
            targetPrice: 200,
            targetDate: nil,
            rationale: nil
        )

        return try await [
            (
                "broker_sync",
                request(.POST, "v1/brokers/ibkr/sync", token: token, on: app)
            ),
            (
                "valuation_cases",
                request(.POST, "v1/stocks/symbol/AAPL/valuation", token: token, body: valuation, on: app)
            ),
            (
                "target_alerts",
                request(.POST, "v1/targets", token: token, body: target, on: app)
            ),
            (
                "statistics",
                get("v1/statistics/overview", token: token, on: app)
            ),
            (
                "market_fundamentals",
                get("v1/market/basic-financials/AAPL", token: token, on: app)
            ),
            (
                "advanced_research",
                get("v1/stocks/AAPL/insights", token: token, on: app)
            ),
            (
                "peer_comparison",
                get("v1/market/compare?symbols=AAPL,MSFT", token: token, on: app)
            ),
            (
                "earnings_text",
                get("v1/market/earnings/AAPL", token: token, on: app)
            ),
            (
                "household_partner",
                get("v1/expenses/partner", token: token, on: app)
            ),
            (
                "recurring_templates",
                get("v1/expenses/recurring", token: token, on: app)
            ),
            (
                "crypto",
                get("v1/crypto/list", token: token, on: app)
            ),
        ]
    }

    // MARK: - Auth tests

    @Test("Missing Authorization header returns 401")
    func missingAuthReturns401() async throws {
        try await withApp { app in
            let status = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: UUID().uuidString), authorization: nil, on: app)
            #expect(status == .unauthorized)
        }
    }

    @Test("Wrong Authorization header returns 401")
    func wrongAuthReturns401() async throws {
        try await withApp { app in
            let status = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: UUID().uuidString), authorization: "wrong-secret", on: app)
            #expect(status == .unauthorized)
        }
    }

    // MARK: - Event tests

    @Test("INITIAL_PURCHASE creates active subscription and pro entitlement")
    func initialPurchase() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "purchase")
            let userId = auth.userId
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)
            let payload = makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString, productId: "pro_monthly", expirationAtMs: futureMs)

            let status = try await post(payload, authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "active")
            #expect(sub?.plan == "pro_monthly")
            #expect(ent?.level == "pro")
        }
    }

    @Test("RENEWAL updates subscription and keeps pro entitlement")
    func renewal() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "renewal")
            let userId = auth.userId
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)

            // Initial purchase first
            let purchasePayload = makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString, expirationAtMs: futureMs)
            _ = try await post(purchasePayload, authorization: secret, on: app)

            // Renewal
            let renewalPayload = makePayload(type: "RENEWAL", eventId: UUID().uuidString, appUserId: userId.uuidString, expirationAtMs: futureMs)
            let status = try await post(renewalPayload, authorization: secret, on: app)
            #expect(status == .ok)

            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(ent?.level == "pro")
        }
    }

    @Test("PRODUCT_CHANGE records pending plan and keeps current entitlement")
    func productChangeRecordsPendingPlan() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "product-change")
            let userId = auth.userId
            let transactionId = "change-\(UUID().uuidString)"
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)

            let purchasePayload = makePayload(
                type: "INITIAL_PURCHASE",
                eventId: UUID().uuidString,
                appUserId: userId.uuidString,
                productId: "pro_weekly",
                expirationAtMs: futureMs,
                originalTransactionId: transactionId,
                store: "APP_STORE"
            )
            #expect(try await post(purchasePayload, authorization: secret, on: app) == .ok)

            let changePayload = makePayload(
                type: "PRODUCT_CHANGE",
                eventId: UUID().uuidString,
                appUserId: userId.uuidString,
                productId: "pro_weekly",
                expirationAtMs: futureMs,
                originalTransactionId: transactionId,
                newProductId: "pro_yearly",
                store: "APP_STORE"
            )
            #expect(try await post(changePayload, authorization: secret, on: app) == .ok)

            let sub = try #require(try await Subscription.query(on: app.db).filter(\.$userId == userId).first())
            let ent = try #require(try await Entitlement.query(on: app.db).filter(\.$userId == userId).first())
            #expect(sub.productId == "pro_weekly")
            #expect(sub.plan == "pro_weekly")
            #expect(sub.pendingProductId == "pro_yearly")
            #expect(sub.pendingPlan == "pro_yearly")
            #expect(sub.pendingPlanEffectiveAt != nil)
            #expect(sub.store == "app_store")
            #expect(ent.level == "pro")
        }
    }

    @Test("RENEWAL to pending product clears pending plan")
    func renewalToPendingProductClearsPendingPlan() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "product-change-renewal")
            let userId = auth.userId
            let transactionId = "change-renew-\(UUID().uuidString)"
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)

            #expect(try await post(
                makePayload(
                    type: "INITIAL_PURCHASE",
                    eventId: UUID().uuidString,
                    appUserId: userId.uuidString,
                    productId: "pro_weekly",
                    expirationAtMs: futureMs,
                    originalTransactionId: transactionId
                ),
                authorization: secret,
                on: app
            ) == .ok)
            #expect(try await post(
                makePayload(
                    type: "PRODUCT_CHANGE",
                    eventId: UUID().uuidString,
                    appUserId: userId.uuidString,
                    productId: "pro_weekly",
                    expirationAtMs: futureMs,
                    originalTransactionId: transactionId,
                    newProductId: "pro_monthly"
                ),
                authorization: secret,
                on: app
            ) == .ok)
            #expect(try await post(
                makePayload(
                    type: "RENEWAL",
                    eventId: UUID().uuidString,
                    appUserId: userId.uuidString,
                    productId: "pro_monthly",
                    expirationAtMs: futureMs,
                    originalTransactionId: transactionId
                ),
                authorization: secret,
                on: app
            ) == .ok)

            let sub = try #require(try await Subscription.query(on: app.db).filter(\.$userId == userId).first())
            #expect(sub.productId == "pro_monthly")
            #expect(sub.plan == "pro_monthly")
            #expect(sub.pendingProductId == nil)
            #expect(sub.pendingPlan == nil)
            #expect(sub.pendingPlanEffectiveAt == nil)
        }
    }

    @Test("Subscription transfer revokes prior owner's entitlement")
    func subscriptionTransferRevokesPreviousOwnerEntitlement() async throws {
        try await withApp { app in
            let first = try await registerUser(on: app, identifier: "transfer-first")
            let second = try await registerUser(on: app, identifier: "transfer-second")
            let transactionId = "transfer-\(UUID().uuidString)"
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)

            let firstPurchase = makePayload(
                type: "INITIAL_PURCHASE",
                eventId: UUID().uuidString,
                appUserId: first.userId.uuidString,
                expirationAtMs: futureMs,
                originalTransactionId: transactionId
            )
            #expect(try await post(firstPurchase, authorization: secret, on: app) == .ok)

            let transferredRenewal = makePayload(
                type: "RENEWAL",
                eventId: UUID().uuidString,
                appUserId: second.userId.uuidString,
                expirationAtMs: futureMs,
                originalTransactionId: transactionId
            )
            #expect(try await post(transferredRenewal, authorization: secret, on: app) == .ok)

            let subscription = try #require(try await Subscription.query(on: app.db)
                .filter(\.$providerOriginalTransactionId == transactionId)
                .first())
            #expect(subscription.userId == second.userId)

            let firstEntitlement = try await Entitlement.query(on: app.db)
                .filter(\.$userId == first.userId)
                .first()
            let secondEntitlement = try await Entitlement.query(on: app.db)
                .filter(\.$userId == second.userId)
                .first()
            #expect(firstEntitlement?.level == "free")
            #expect(firstEntitlement?.subscriptionId == nil)
            #expect(secondEntitlement?.level == "pro")
            #expect(secondEntitlement?.subscriptionId == subscription.id)
        }
    }

    @Test("CANCELLATION sets subscription cancelled, entitlement stays pro")
    func cancellation() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "cancel")
            let userId = auth.userId
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString, expirationAtMs: futureMs), authorization: secret, on: app)
            let status = try await post(makePayload(type: "CANCELLATION", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "cancelled")
            #expect(ent?.level == "pro")
        }
    }

    @Test("EXPIRATION sets subscription expired and entitlement to free")
    func expiration() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "expire")
            let userId = auth.userId

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            let status = try await post(makePayload(type: "EXPIRATION", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "expired")
            #expect(ent?.level == "free")
        }
    }

    @Test("REFUND sets subscription refunded and entitlement to free")
    func refund() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "refund")
            let userId = auth.userId

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            let status = try await post(makePayload(type: "REFUND", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "refunded")
            #expect(ent?.level == "free")
        }
    }

    @Test("BILLING_ISSUE with future grace period keeps pro entitlement")
    func billingIssueWithGracePeriod() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "billing-grace")
            let userId = auth.userId
            let futureGraceMs = Int64(Date().addingTimeInterval(86400).timeIntervalSince1970 * 1000)

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            let status = try await post(makePayload(type: "BILLING_ISSUE", eventId: UUID().uuidString, appUserId: userId.uuidString, gracePeriodMs: futureGraceMs), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "billing_issue")
            #expect(ent?.level == "pro")
        }
    }

    @Test("BILLING_ISSUE without grace period sets entitlement to free")
    func billingIssueNoGracePeriod() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "billing-nograce")
            let userId = auth.userId

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            let status = try await post(makePayload(type: "BILLING_ISSUE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "billing_issue")
            #expect(ent?.level == "free")
        }
    }

    @Test("Duplicate event is idempotent - only one BillingEvent row persisted")
    func duplicateEventIsIdempotent() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "idempotent")
            let userId = auth.userId
            let eventId = UUID().uuidString
            let payload = makePayload(type: "INITIAL_PURCHASE", eventId: eventId, appUserId: userId.uuidString)

            let s1 = try await post(payload, authorization: secret, on: app)
            let s2 = try await post(payload, authorization: secret, on: app)
            #expect(s1 == .ok)
            #expect(s2 == .ok)

            let count = try await BillingEvent.query(on: app.db)
                .filter(\.$providerEventId == eventId)
                .count()
            #expect(count == 1)
        }
    }

    @Test("Non-UUID app user id persists event without mutating entitlement state")
    func nonUUIDAppUserIdPersistsEventOnly() async throws {
        try await withApp { app in
            let eventId = UUID().uuidString
            let payload = makePayload(type: "INITIAL_PURCHASE", eventId: eventId, appUserId: "revenuecat-alias")

            let status = try await post(payload, authorization: secret, on: app)
            #expect(status == .ok)

            let event = try await BillingEvent.query(on: app.db)
                .filter(\.$providerEventId == eventId)
                .first()
            #expect(event?.userId == nil)
            #expect(event?.rawPayload.contains("revenuecat-alias") == true)

            let subscriptionCount = try await Subscription.query(on: app.db).count()
            let entitlementCount = try await Entitlement.query(on: app.db).count()
            #expect(subscriptionCount == 0)
            #expect(entitlementCount == 0)
        }
    }

    // MARK: - Entitlement and usage tests

    @Test("Free users are blocked when holding count exceeds the free limit")
    func freeHoldingLimitBlocks() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-holdings")
            let symbols = ["AAPL", "MSFT", "GOOG", "AMZN", "NVDA"]

            for symbol in symbols {
                let (status, _) = try await createStock(symbol: symbol, token: auth.token, on: app)
                #expect(status == .created)
            }

            let (status, body) = try await createStock(symbol: "TSLA", token: auth.token, on: app)
            #expect(status == .forbidden)
            #expect(body.contains("feature=holdings"))

            let counter = try await UsageCounter.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .first()
            #expect(counter?.holdingCount == 5)
        }
    }

    @Test("Premium users can exceed the free holding limit")
    func premiumHoldingLimitBypassesFreeLimit() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "premium-holdings")
            try await grantPremium(userId: auth.userId, on: app)
            let symbols = ["AAPL", "MSFT", "GOOG", "AMZN", "NVDA", "TSLA"]

            for symbol in symbols {
                let (status, _) = try await createStock(symbol: symbol, token: auth.token, on: app)
                #expect(status == .created)
            }

            let count = try await Stock.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .count()
            #expect(count == 6)
        }
    }

    @Test("Free users are blocked after the monthly CSV import limit")
    func freeCsvImportLimitBlocksSecondImport() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-csv")

            let first = try await commitCsv(
                token: auth.token,
                csv: "symbol,quantity,average_cost,buy_date\nAAPL,1,100,2026-01-01\n",
                on: app
            )
            #expect(first.0 == .ok)

            let second = try await commitCsv(
                token: auth.token,
                csv: "symbol,quantity,average_cost,buy_date\nMSFT,1,100,2026-01-01\n",
                on: app
            )
            #expect(second.0 == .forbidden)
            #expect(second.1.contains("feature=csv_imports"))

            let counter = try await UsageCounter.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .first()
            #expect(counter?.csvImportCount == 1)
        }
    }

    @Test("Free users are blocked from advanced stock insights")
    func freeAdvancedResearchRequiresPremium() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-research")

            let (status, body) = try await get("v1/stocks/AAPL/insights", token: auth.token, on: app)
            #expect(status == .forbidden)
            #expect(body.contains("feature=advanced_research"))
            #expect(body.contains("required=pro"))
        }
    }

    @Test("Free users are blocked from peer comparison")
    func freePeerComparisonRequiresPremium() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-compare")

            let (status, body) = try await get("v1/market/compare?symbols=AAPL,MSFT", token: auth.token, on: app)
            #expect(status == .forbidden)
            #expect(body.contains("feature=peer_comparison"))
            #expect(body.contains("required=pro"))
        }
    }

    @Test("Free users are blocked from earnings text")
    func freeEarningsTextRequiresPremium() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-earnings")

            let (status, body) = try await get("v1/market/earnings/AAPL", token: auth.token, on: app)
            #expect(status == .forbidden)
            #expect(body.contains("feature=earnings_text"))
            #expect(body.contains("required=pro"))
        }
    }

    @Test("Free users can use core expenses but are blocked from broker and advanced expense routes")
    func freeUsersCanUseCoreExpensesButAreBlockedFromBrokerAndAdvancedExpenseRoutes() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-expense-routes")

            try await app.testing().test(.POST, "v1/brokers/ibkr/sync", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("feature=broker_sync"))
            })

            let freeCoreExpenseRoutes = [
                "v1/expenses",
                "v1/budget/snapshots",
            ]

            for path in freeCoreExpenseRoutes {
                let (status, _) = try await get(path, token: auth.token, on: app)
                #expect(status == .ok)
            }

            let gatedChecks: [(String, String)] = [
                ("v1/expenses/partner", "household_partner"),
                ("v1/expenses/recurring", "recurring_templates"),
                ("v1/statistics/overview", "statistics"),
            ]

            for (path, feature) in gatedChecks {
                let (status, body) = try await get(path, token: auth.token, on: app)
                #expect(status == .forbidden)
                #expect(body.contains("feature=\(feature)"))
            }
        }
    }

    @Test("Free users are blocked from valuation and target alert routes")
    func freeUsersAreBlockedFromValuationsAndTargets() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-valuations")

            let stock = try await createStock(symbol: "AAPL", token: auth.token, on: app)
            #expect(stock.0 == .created)

            try await app.testing().test(.POST, "v1/stocks/symbol/AAPL/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(
                    StockValuationRequest(
                        symbol: "AAPL",
                        bearCase: PriceRange(low: 10, high: 12),
                        baseCase: PriceRange(low: 13, high: 15),
                        bullCase: PriceRange(low: 16, high: 20),
                        rationale: nil,
                        targetDate: nil
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("feature=valuation_cases"))
            })

            try await app.testing().test(.POST, "v1/targets", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(
                    TargetRequest(
                        symbol: "AAPL",
                        scenario: "bull",
                        targetPrice: 200,
                        targetDate: nil,
                        rationale: nil
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("feature=target_alerts"))
            })
        }
    }

    @Test("Free users are blocked from every current Pro-only backend feature")
    func freeUsersAreBlockedFromCurrentProOnlyFeatureMatrix() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-paid-matrix")
            for check in try await paidFeatureGateResults(token: auth.token, on: app) {
                assertUpgradeRequired(check.result, feature: check.feature)
            }
        }
    }

    @Test("Trial users can pass every current Pro-only backend feature gate")
    func trialUsersCanPassCurrentProOnlyFeatureMatrix() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "trial-paid-matrix", keepDefaultTrial: true)
            for check in try await paidFeatureGateResults(token: auth.token, on: app) {
                assertNotUpgradeRequired(check.result)
            }
        }
    }

    @Test("Pro users can pass every current Pro-only backend feature gate")
    func proUsersCanPassCurrentProOnlyFeatureMatrix() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "pro-paid-matrix")
            try await grantPremium(userId: auth.userId, on: app)
            for check in try await paidFeatureGateResults(token: auth.token, on: app) {
                assertNotUpgradeRequired(check.result)
            }
        }
    }

    @Test("Billing context exposes full access for trial users")
    func billingContextForTrialUserShowsFullAccess() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-trial", keepDefaultTrial: true)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.plan == "temporary")
            #expect(body.entitlementLevel == "temporary")
            #expect(body.isTrialActive == true)
            #expect(body.trialDaysRemaining != nil)
            #expect(body.trialExpired == false)
            assertAllFeaturesAvailable(body)
        }
    }

    @Test("Expired default trial resolves to free before cleanup job runs")
    func expiredDefaultTrialResolvesToFreeBeforeCleanupJobRuns() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "trial-expired", keepDefaultTrial: true)
            let user = try #require(try await User.find(auth.userId, on: app.db))
            user.trialStartedAt = Date().addingTimeInterval(-8 * 86400)
            user.trialDays = 7
            user.trialTier = "temporary"
            try await user.save(on: app.db)

            let entitlement = try await app.entitlementResolver.resolve(userId: auth.userId, on: app.db)
            #expect(entitlement.level == "free")
            #expect(entitlement.isPremium == false)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.entitlementLevel == "free")
            #expect(body.isPremium == false)
            #expect(body.isTrialActive == false)
            #expect(body.trialDaysRemaining == nil)
            // Trial window lapsed but the sweep job hasn't cleared the trial_* fields yet:
            // isTrialExpired() catches this case so the client can show the subscribe prompt.
            #expect(body.trialExpired == true)
        }
    }

    @Test("Trial expired flag persists after the cleanup job clears trial fields")
    func trialExpiredFlagPersistsAfterCleanupJob() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "trial-swept", keepDefaultTrial: true)
            let user = try #require(try await User.find(auth.userId, on: app.db))
            user.trialStartedAt = Date().addingTimeInterval(-8 * 86400)
            user.trialDays = 7
            user.trialTier = "temporary"
            try await user.save(on: app.db)

            // Run the sweep: markTrialExpired clears trial_* and stamps hadTrial = true.
            try await app.trialService.markTrialExpired(user: user, db: app.db)
            let swept = try #require(try await User.find(auth.userId, on: app.db))
            #expect(swept.trialTier == nil)
            #expect(swept.hadTrial == true)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.isPremium == false)
            // hadTrial keeps trialExpired true even though isTrialExpired() now returns false.
            #expect(body.trialExpired == true)
        }
    }

    @Test("Trial warning type filter uses PostgreSQL enum binding")
    func trialWarningTypeFilterUsesPostgreSQLEnumBinding() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "trial-warning-filter", keepDefaultTrial: true)
            let user = try #require(try await User.find(auth.userId, on: app.db))

            try await app.trialService.markTrialExpired(user: user, db: app.db)

            let warning = try await TrialWarning.query(on: app.db)
                .filter(\.$userID == auth.userId)
                .filter(\.$warningType == .expired)
                .first()

            #expect(warning?.warningType == .expired)
        }
    }

    @Test("Never-trialed free user is not flagged as trial-expired")
    func neverTrialedFreeUserIsNotTrialExpired() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "never-trialed", keepDefaultTrial: true)
            // Simulate a user who never had a trial: clear the default trial without stamping hadTrial.
            let user = try #require(try await User.find(auth.userId, on: app.db))
            user.trialStartedAt = nil
            user.trialDays = nil
            user.trialTier = nil
            user.hadTrial = false
            try await user.save(on: app.db)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.isPremium == false)
            #expect(body.trialExpired == false)
        }
    }

    @Test("Configured premium email resolves to Pro without subscription")
    func configuredPremiumEmailResolvesToProWithoutSubscription() async throws {
        setenv("BILLING_PREMIUM_EMAILS", " ABC@gmail.com , xyz@gmail.com ", 1)
        defer { unsetenv("BILLING_PREMIUM_EMAILS") }

        try await withApp { app in
            let premiumUsers = try await [
                registerUser(on: app, identifier: "premium-email-abc", email: "abc@gmail.com"),
                registerUser(on: app, identifier: "premium-email-xyz", email: "XYZ@gmail.com"),
            ]

            for auth in premiumUsers {
                let entitlement = try await app.entitlementResolver.resolve(userId: auth.userId, on: app.db)
                #expect(entitlement.level == "pro")
                #expect(entitlement.isPremium == true)

                let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
                #expect(status == .ok)
                let body = try #require(context)
                #expect(body.entitlementLevel == "pro")
                #expect(body.isPremium == true)
                #expect(body.subscription == nil)
            }

            let freeAuth = try await registerUser(on: app, identifier: "premium-email-free", email: "free@gmail.com")
            let freeEntitlement = try await app.entitlementResolver.resolve(userId: freeAuth.userId, on: app.db)
            #expect(freeEntitlement.level == "free")
            #expect(freeEntitlement.isPremium == false)

            let (status, context, _) = try await getBillingContext(token: freeAuth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.entitlementLevel == "free")
            #expect(body.isPremium == false)
            #expect(body.subscription == nil)
        }
    }

    // MARK: - Coupon tests

    @Test("Registration starts a default temporary trial")
    func registrationStartsDefaultTrial() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "trial-default", keepDefaultTrial: true)

            let user = try #require(try await User.find(auth.userId, on: app.db))
            #expect(user.trialTier == "temporary")
            #expect(user.trialDays == 7)
            #expect(user.trialStartedAt != nil)

            let entitlement = try await app.entitlementResolver.resolve(userId: auth.userId, on: app.db)
            #expect(entitlement.level == "temporary")
            #expect(entitlement.isPro == true)
            #expect(entitlement.isPremium == true)
        }
    }

    @Test("Coupon validation route is not public")
    func couponValidationRouteIsNotPublic() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "coupon-validate")
            let coupon = Coupon(
                code: "SAVE20",
                trialDays: 14,
                discountPercentage: 20,
                maxUses: 3
            )
            try await coupon.save(on: app.db)

            let (status, response, _) = try await validateCoupon(code: "save20", token: auth.token, on: app)
            #expect(status == .notFound)
            #expect(response == nil)

            let stored = try await Coupon.query(on: app.db)
                .filter(\.$code == "SAVE20")
                .first()
            #expect(stored?.currentUses == 0)
        }
    }

    @Test("Coupon redemption route is not public and does not grant access")
    func couponRedemptionRouteIsNotPublic() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "coupon-redeem")
            let coupon = Coupon(
                code: "FOREVER",
                grantType: "lifetime_pro",
                trialDays: 0,
                maxUses: 1
            )
            try await coupon.save(on: app.db)

            let (status, response, _) = try await redeemCoupon(code: " forever ", token: auth.token, on: app)
            #expect(status == .notFound)
            #expect(response == nil)

            let stored = try await Coupon.query(on: app.db)
                .filter(\.$code == "FOREVER")
                .first()
            #expect(stored?.currentUses == 0)
            let redemptionCount = try await CouponRedemption.query(on: app.db).count()
            #expect(redemptionCount == 0)
            let entitlement = try await Entitlement.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .first()
            #expect(entitlement?.level != "pro")
        }
    }

    @Test("Registration ignores coupon code and starts normal default trial")
    func registrationIgnoresCouponCode() async throws {
        try await withApp { app in
            let coupon = Coupon(
                code: "FOREVER",
                grantType: "lifetime_pro",
                trialDays: 0,
                maxUses: 1
            )
            try await coupon.save(on: app.db)

            let request = AuthRegisterRequest(
                username: "billing_coupon_register",
                password: "Password123!",
                confirmPassword: "Password123!",
                email: "billing+coupon-register@example.com",
                dateOfBirth: Date(timeIntervalSince1970: 946_684_800),
                couponCode: "FOREVER"
            )
            var auth: AuthResponse?
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(request)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                auth = try res.content.decode(AuthResponse.self)
            })
            let response = try #require(auth)
            let user = try #require(try await User.find(response.userId, on: app.db))
            #expect(user.trialTier == "temporary")
            #expect(user.trialDays == 7)
            #expect(user.trialStartedAt != nil)

            let entitlement = try await Entitlement.query(on: app.db)
                .filter(\.$userId == response.userId)
                .first()
            #expect(entitlement?.level != "pro")
            let redemptionCount = try await CouponRedemption.query(on: app.db).count()
            #expect(redemptionCount == 0)
            let stored = try await Coupon.query(on: app.db)
                .filter(\.$code == "FOREVER")
                .first()
            #expect(stored?.currentUses == 0)
        }
    }

    // MARK: - Billing context tests

    @Test("Billing context returns free plan rules and usage")
    func billingContextForFreeUser() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-free")
            _ = try await createStock(symbol: "AAPL", token: auth.token, on: app)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.plan == "free")
            #expect(body.entitlementLevel == "free")
            #expect(body.isPremium == false)
            #expect(body.subscription == nil)
            #expect(body.planOptions.count == 3)
            #expect(body.planOptions.allSatisfy { $0.changeKind == "subscribe" })
            #expect(body.planOptions.first { $0.plan == "pro_yearly" }?.badge == "Best value")

            let holdings = try #require(body.usage.first { $0.key == "holdings" })
            #expect(holdings.used == 1)
            #expect(holdings.limit == 5)
            #expect(holdings.remaining == 4)

            let research = try #require(body.features.first { $0.key == "advanced_research" })
            #expect(research.available == false)
            #expect(research.requiredPlan == "pro")

            for key in ["ai_insights", "mcp_access", "scenario_planning", "tax_optimization"] {
                let feature = try #require(body.features.first { $0.key == key })
                #expect(feature.available == false)
                #expect(feature.requiredPlan == "pro")
            }
            let reports = try #require(body.features.first { $0.key == "reports" })
            #expect(reports.available == true)
        }
    }

    @Test("Billing context returns pro yearly subscription state")
    func billingContextForProYearlyUser() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-yearly")
            let futureMs = Int64(Date().addingTimeInterval(31_536_000).timeIntervalSince1970 * 1000)
            let payload = makePayload(
                type: "INITIAL_PURCHASE",
                eventId: UUID().uuidString,
                appUserId: auth.userId.uuidString,
                productId: "pro_yearly",
                expirationAtMs: futureMs
            )
            #expect(try await post(payload, authorization: secret, on: app) == .ok)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.plan == "pro_yearly")
            #expect(body.entitlementLevel == "pro")
            #expect(body.isPremium == true)
            #expect(body.subscription?.status == "active")
            #expect(body.subscription?.plan == "pro_yearly")
            #expect(body.subscription?.renewsOrExpiresAt != nil)
            #expect(body.subscription?.willRenew == true)
            #expect(body.planOptions.first { $0.plan == "pro_yearly" }?.isCurrent == true)
            #expect(!body.planOptions.contains { $0.changeKind == "upgrade" })
            #expect(!body.features.contains(where: { !$0.available }))
            #expect(body.usage.first { $0.key == "holdings" }?.limit == nil)
        }
    }

    @Test("Billing context reports cancelled but still active state")
    func billingContextForCancelledButActiveUser() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-cancel")
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)
            #expect(try await post(
                makePayload(
                    type: "INITIAL_PURCHASE",
                    eventId: UUID().uuidString,
                    appUserId: auth.userId.uuidString,
                    expirationAtMs: futureMs
                ),
                authorization: secret,
                on: app
            ) == .ok)
            #expect(try await post(
                makePayload(
                    type: "CANCELLATION",
                    eventId: UUID().uuidString,
                    appUserId: auth.userId.uuidString,
                    expirationAtMs: futureMs
                ),
                authorization: secret,
                on: app
            ) == .ok)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.isPremium == true)
            #expect(body.subscription?.status == "cancelled")
            #expect(body.subscription?.isCancelledButActive == true)
            #expect(body.subscription?.willRenew == false)
            #expect(body.subscription?.accessEndsAt != nil)
            #expect(body.subscription?.periodEndsAt != nil)
        }
    }

    @Test("Billing management URL requires RevenueCat project configuration")
    func billingManagementURLRequiresRevenueCatProjectConfiguration() async throws {
        try await withApp { app in
            let previousProjectID = Environment.get("REVENUECAT_PROJECT_ID")
            let previousAPIV2Key = Environment.get("REVENUECAT_API_V2_KEY")
            unsetenv("REVENUECAT_PROJECT_ID")
            setenv("REVENUECAT_API_V2_KEY", "test-v2-key", 1)
            defer {
                if let previousProjectID {
                    setenv("REVENUECAT_PROJECT_ID", previousProjectID, 1)
                } else {
                    unsetenv("REVENUECAT_PROJECT_ID")
                }
                if let previousAPIV2Key {
                    setenv("REVENUECAT_API_V2_KEY", previousAPIV2Key, 1)
                } else {
                    unsetenv("REVENUECAT_API_V2_KEY")
                }
            }

            let auth = try await registerUser(on: app, identifier: "management-url")
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)
            #expect(try await post(
                makePayload(
                    type: "INITIAL_PURCHASE",
                    eventId: UUID().uuidString,
                    appUserId: auth.userId.uuidString,
                    expirationAtMs: futureMs
                ),
                authorization: secret,
                on: app
            ) == .ok)

            var status: HTTPStatus = .ok
            try await app.testing().test(.POST, "v1/billing/management-url", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                status = res.status
            })

            #expect(status == .serviceUnavailable)
        }
    }

    @Test("Empty RevenueCat restore clears entitlement without creating unknown subscription")
    func emptyRevenueCatRestoreDoesNotCreateUnknownSubscription() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "empty-restore")
            try await grantPremium(userId: auth.userId, on: app)

            let subscriber = BillingController.RevenueCatSubscriber(
                entitlements: [:],
                subscriptions: [:]
            )
            try await BillingController().syncRevenueCatSubscriber(
                subscriber,
                userId: auth.userId,
                on: app.db
            )

            let subscriptions = try await Subscription.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .all()
            let entitlement = try #require(try await Entitlement.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .first())

            #expect(subscriptions.isEmpty)
            #expect(entitlement.level == "free")
            #expect(entitlement.subscriptionId == nil)
        }
    }

    @Test("RevenueCat restore reads pro_access entitlement")
    func revenueCatRestoreReadsProAccessEntitlement() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "pro-access-restore")
            let formatter = ISO8601DateFormatter()
            let purchaseDate = formatter.string(from: Date())
            let expiresDate = formatter.string(from: Date().addingTimeInterval(86400))
            let subscriber = BillingController.RevenueCatSubscriber(
                entitlements: [
                    "pro_access": BillingController.RevenueCatEntitlement(
                        expiresDate: expiresDate,
                        purchaseDate: purchaseDate,
                        productIdentifier: "pro_weekly"
                    ),
                ],
                subscriptions: [:]
            )

            try await BillingController().syncRevenueCatSubscriber(
                subscriber,
                userId: auth.userId,
                on: app.db
            )

            let subscription = try #require(try await Subscription.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .first())
            let entitlement = try #require(try await Entitlement.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .first())

            #expect(subscription.productId == "pro_weekly")
            #expect(subscription.status == "active")
            #expect(entitlement.level == "pro")
            #expect(entitlement.subscriptionId == subscription.id)
        }
    }

    // MARK: - Crypto entitlement tests

    @Test("Free users are blocked from every Crypto endpoint")
    func freeCryptoEndpointsAreBlocked() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-crypto")

            let cryptoChecks: [(method: HTTPMethod, path: String)] = [
                (.GET, "v1/crypto/list"),
                (.GET, "v1/crypto/quote/BTC"),
                (.GET, "v1/crypto/quote-short/BTC"),
                (.GET, "v1/crypto/batch-quotes"),
                (.GET, "v1/crypto/history/1hour/BTC"),
                (.GET, "v1/crypto/news"),
                (.GET, "v1/crypto/news/BTC"),
                (.GET, "v1/crypto/portfolio"),
            ]

            for check in cryptoChecks {
                let result = try await request(check.method, check.path, token: auth.token, on: app)
                assertUpgradeRequired(result, feature: "crypto")
            }
        }
    }

    @Test("Trial users can access Crypto endpoints")
    func trialCryptoEndpointsAllowed() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "trial-crypto", keepDefaultTrial: true)

            let result = try await get("v1/crypto/list", token: auth.token, on: app)
            #expect(result.0 != .forbidden)
            #expect(!result.1.contains("upgrade_required"))
        }
    }

    @Test("Pro users can access Crypto endpoints")
    func proCryptoEndpointsAllowed() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "pro-crypto")
            try await grantPremium(userId: auth.userId, on: app)

            let result = try await get("v1/crypto/list", token: auth.token, on: app)
            #expect(result.0 != .forbidden)
            #expect(!result.1.contains("upgrade_required"))
        }
    }

    @Test("Crypto portfolio mutations require Pro/trial entitlement")
    func freeCryptoPortfolioMutationBlocked() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-crypto-add")
            let payload = CryptoPortfolioItemRequest(
                symbol: "BTC",
                name: "Bitcoin",
                quantity: 1,
                averageBuyPrice: 50000
            )
            let result = try await request(.POST, "v1/crypto/portfolio", token: auth.token, body: payload, on: app)
            assertUpgradeRequired(result, feature: "crypto")
        }
    }

    @Test("Billing context lists crypto as a Pro-only feature for free users")
    func billingContextExposesCryptoAsProOnly() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-crypto-free")

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            let crypto = try #require(body.features.first { $0.key == "crypto" })
            #expect(crypto.available == false)
            #expect(crypto.requiredPlan == "pro")
        }
    }

    @Test("Billing context marks crypto available for trial users")
    func billingContextExposesCryptoAvailableForTrial() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-crypto-trial", keepDefaultTrial: true)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            let crypto = try #require(body.features.first { $0.key == "crypto" })
            #expect(crypto.available == true)
        }
    }

    @Test("Premium gate failures return stable JSON error envelope")
    func premiumGateReturnsBillingErrorEnvelope() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-error")
            var error: BillingUpgradeRequiredResponse?
            try await app.testing().test(.GET, "v1/stocks/AAPL/insights", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
                error = try res.content.decode(BillingUpgradeRequiredResponse.self)
            })

            let body = try #require(error)
            #expect(body.success == false)
            #expect(body.code == "upgrade_required")
            #expect(body.feature == "advanced_research")
            #expect(body.plan == "free")
            #expect(body.requiredPlan == "pro")
        }
    }
}
