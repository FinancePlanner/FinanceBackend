import Fluent
import Foundation
import Vapor

struct BillingManagementURLResponse: Content {
    let managementUrl: String
    let provider: String
    let source: String
}

struct BillingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())

        protected.grouped(ScopeRequirementMiddleware(.billingRead))
            .get("billing", "me", use: me)

        protected.grouped(ScopeRequirementMiddleware(.billingWrite))
            .group("billing") { billing in
                billing.post("restore", use: restore)
                billing.post("management-url", use: managementURL)
                billing.post("coupon", "redeem", use: redeemCoupon)
            }
    }

    @Sendable
    func me(req: Request) async throws -> BillingContextResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.billingContextService.context(userId: session.userId, on: req.db)
    }

    @Sendable
    func restore(req: Request) async throws -> BillingContextResponse {
        let session = try req.auth.require(SessionToken.self)
        let apiKey = try revenueCatAPIKey()
        let subscriber = try await fetchRevenueCatSubscriber(userId: session.userId, apiKey: apiKey, req: req)
        try await syncRevenueCatSubscriber(subscriber, userId: session.userId, on: req.db)
        return try await req.billingContextService.context(userId: session.userId, on: req.db)
    }

    @Sendable
    func managementURL(req: Request) async throws -> BillingManagementURLResponse {
        let session = try req.auth.require(SessionToken.self)
        let projectID = try revenueCatProjectID()
        let apiKey = try revenueCatAPIV2Key()
        let subscriptions = try await fetchRevenueCatSubscriptions(
            userId: session.userId,
            projectID: projectID,
            apiKey: apiKey,
            req: req
        )
        req.logger.info("billing.management_url subscriptions_found=\(subscriptions.count) user_id=\(session.userId.uuidString)")
        guard let subscription = preferredManagementSubscription(from: subscriptions) else {
            req.logger.warning("billing.management_url no_manageable_subscription user_id=\(session.userId.uuidString)")
            throw Abort(.notFound, reason: "No manageable subscription was found.")
        }

        if isRevenueCatWebBillingStore(subscription.store),
           let url = try await fetchAuthenticatedManagementURL(
               projectID: projectID,
               subscriptionID: subscription.id,
               apiKey: apiKey,
               req: req
           )
        {
            req.logger.info("billing.management_url source=revenuecat_customer_portal subscription_id=\(subscription.id) store=\(subscription.store ?? "unknown") user_id=\(session.userId.uuidString)")
            return BillingManagementURLResponse(
                managementUrl: url,
                provider: subscription.store ?? "revenuecat",
                source: "revenuecat_customer_portal"
            )
        }

        if let url = subscription.managementURL, !url.isEmpty {
            req.logger.info("billing.management_url source=revenuecat_management_url subscription_id=\(subscription.id) store=\(subscription.store ?? "unknown") user_id=\(session.userId.uuidString)")
            return BillingManagementURLResponse(
                managementUrl: url,
                provider: subscription.store ?? "revenuecat",
                source: "revenuecat_management_url"
            )
        }

        if subscription.store?.lowercased() == "app_store" {
            req.logger.info("billing.management_url source=apple_subscriptions subscription_id=\(subscription.id) store=app_store user_id=\(session.userId.uuidString)")
            return BillingManagementURLResponse(
                managementUrl: "https://apps.apple.com/account/subscriptions",
                provider: "app_store",
                source: "apple_subscriptions"
            )
        }

        req.logger.warning("billing.management_url no_management_url subscription_id=\(subscription.id) store=\(subscription.store ?? "unknown") user_id=\(session.userId.uuidString)")
        throw Abort(.notFound, reason: "No subscription management URL is available.")
    }

    @Sendable
    func redeemCoupon(req: Request) async throws -> CouponRedemptionResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(CouponCodeRequest.self)
        guard let user = try await User.find(session.userId, on: req.db) else {
            throw Abort(.notFound, reason: "User not found.")
        }
        let redemption = try await req.application.couponService.redeemCoupon(
            code: payload.code,
            user: user,
            db: req.db
        )
        let context = try await req.billingContextService.context(userId: session.userId, on: req.db)
        return redemption.withBillingContext(context)
    }
}

extension BillingController {
    struct RevenueCatV2SubscriptionListResponse: Decodable {
        let items: [RevenueCatV2Subscription]
    }

    struct RevenueCatV2Subscription: Decodable {
        let id: String
        let store: String?
        let status: String?
        let givesAccess: Bool?
        let managementURL: String?
        let currentPeriodEndsAt: Int64?
        let endsAt: Int64?

        enum CodingKeys: String, CodingKey {
            case id
            case store
            case status
            case givesAccess = "gives_access"
            case managementURL = "management_url"
            case currentPeriodEndsAt = "current_period_ends_at"
            case endsAt = "ends_at"
        }
    }

    struct RevenueCatAuthenticatedManagementURLResponse: Decodable {
        let managementURL: String

        enum CodingKeys: String, CodingKey {
            case managementURL = "management_url"
        }
    }

    struct RevenueCatSubscriberResponse: Decodable {
        let subscriber: RevenueCatSubscriber
    }

    struct RevenueCatSubscriber: Decodable {
        let entitlements: [String: RevenueCatEntitlement]
        let subscriptions: [String: RevenueCatSubscription]
    }

    struct RevenueCatEntitlement: Decodable {
        let expiresDate: String?
        let purchaseDate: String?
        let productIdentifier: String?

        enum CodingKeys: String, CodingKey {
            case expiresDate = "expires_date"
            case purchaseDate = "purchase_date"
            case productIdentifier = "product_identifier"
        }
    }

    struct RevenueCatSubscription: Decodable {
        let expiresDate: String?
        let purchaseDate: String?
        let originalPurchaseDate: String?
        let periodType: String?
        let store: String?
        let unsubscribeDetectedAt: String?
        let billingIssuesDetectedAt: String?
        let gracePeriodExpiresDate: String?

        enum CodingKeys: String, CodingKey {
            case expiresDate = "expires_date"
            case purchaseDate = "purchase_date"
            case originalPurchaseDate = "original_purchase_date"
            case periodType = "period_type"
            case store
            case unsubscribeDetectedAt = "unsubscribe_detected_at"
            case billingIssuesDetectedAt = "billing_issues_detected_at"
            case gracePeriodExpiresDate = "grace_period_expires_date"
        }
    }

    private enum RevenueCatEntitlementID {
        static let proAccess = "pro_access"
    }

    func revenueCatAPIKey() throws -> String {
        let value = Environment.get("REVENUECAT_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "REVENUECAT_API_KEY is not configured.")
        }
        return value
    }

    func revenueCatAPIV2Key() throws -> String {
        let value = Environment.get("REVENUECAT_API_V2_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? Environment.get("REVENUECAT_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !value.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "REVENUECAT_API_V2_KEY is not configured.")
        }
        return value
    }

    func revenueCatProjectID() throws -> String {
        let value = Environment.get("REVENUECAT_PROJECT_ID")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "REVENUECAT_PROJECT_ID is not configured.")
        }
        return value
    }

    func fetchRevenueCatSubscriptions(
        userId: UUID,
        projectID: String,
        apiKey: String,
        req: Request
    ) async throws -> [RevenueCatV2Subscription] {
        let encodedProjectID = pathSegment(projectID)
        let encodedUserID = pathSegment(userId.uuidString)
        let response = try await req.client.get(
            "https://api.revenuecat.com/v2/projects/\(encodedProjectID)/customers/\(encodedUserID)/subscriptions?limit=20"
        ) { clientRequest in
            clientRequest.headers.bearerAuthorization = .init(token: apiKey)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.headers.contentType = .json
        }

        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "RevenueCat subscription lookup failed with status \(response.status.code).")
        }

        do {
            return try response.content.decode(RevenueCatV2SubscriptionListResponse.self).items
        } catch {
            throw Abort(.badGateway, reason: "RevenueCat subscription list response was invalid.")
        }
    }

    func fetchAuthenticatedManagementURL(
        projectID: String,
        subscriptionID: String,
        apiKey: String,
        req: Request
    ) async throws -> String? {
        let encodedProjectID = pathSegment(projectID)
        let encodedSubscriptionID = pathSegment(subscriptionID)
        let response = try await req.client.get(
            "https://api.revenuecat.com/v2/projects/\(encodedProjectID)/subscriptions/\(encodedSubscriptionID)/authenticated_management_url"
        ) { clientRequest in
            clientRequest.headers.bearerAuthorization = .init(token: apiKey)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.headers.contentType = .json
        }

        guard response.status == .ok else {
            return nil
        }

        do {
            return try response.content.decode(RevenueCatAuthenticatedManagementURLResponse.self).managementURL
        } catch {
            return nil
        }
    }

    func preferredManagementSubscription(from subscriptions: [RevenueCatV2Subscription]) -> RevenueCatV2Subscription? {
        subscriptions.sorted(by: managementSubscriptionSort).first
    }

    func managementSubscriptionSort(_ lhs: RevenueCatV2Subscription, _ rhs: RevenueCatV2Subscription) -> Bool {
        let lhsScore = managementSubscriptionScore(lhs)
        let rhsScore = managementSubscriptionScore(rhs)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        return (lhs.currentPeriodEndsAt ?? lhs.endsAt ?? 0) > (rhs.currentPeriodEndsAt ?? rhs.endsAt ?? 0)
    }

    func managementSubscriptionScore(_ subscription: RevenueCatV2Subscription) -> Int {
        if subscription.givesAccess == true {
            return 4
        }
        switch subscription.status?.lowercased() {
        case "active", "trialing", "grace_period":
            return 3
        case "cancelled":
            return 2
        case "billing_issue":
            return 1
        default:
            return 0
        }
    }

    func isRevenueCatWebBillingStore(_ store: String?) -> Bool {
        switch store?.lowercased() {
        case "rc_billing", "revenuecat", "web_billing", "revenuecat_web_billing":
            true
        default:
            false
        }
    }

    func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func fetchRevenueCatSubscriber(
        userId: UUID,
        apiKey: String,
        req: Request
    ) async throws -> RevenueCatSubscriber {
        let encodedUserId = userId.uuidString.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId.uuidString
        let response = try await req.client.get("https://api.revenuecat.com/v1/subscribers/\(encodedUserId)") { clientRequest in
            clientRequest.headers.bearerAuthorization = .init(token: apiKey)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.headers.contentType = .json
        }

        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "RevenueCat subscriber lookup failed with status \(response.status.code).")
        }

        do {
            return try response.content.decode(RevenueCatSubscriberResponse.self).subscriber
        } catch {
            throw Abort(.badGateway, reason: "RevenueCat subscriber response was invalid.")
        }
    }

    func syncRevenueCatSubscriber(
        _ subscriber: RevenueCatSubscriber,
        userId: UUID,
        on db: any Database
    ) async throws {
        guard !subscriber.entitlements.isEmpty || !subscriber.subscriptions.isEmpty else {
            let entitlement = try await Entitlement.query(on: db)
                .filter(\.$userId == userId)
                .first()
                ?? Entitlement(userId: userId, level: "free", subscriptionId: nil)
            entitlement.level = "free"
            entitlement.subscriptionId = nil
            try await entitlement.save(on: db)
            return
        }

        let proEntitlement = subscriber.entitlements[RevenueCatEntitlementID.proAccess]
        let productId = proEntitlement?.productIdentifier
            ?? subscriber.subscriptions.keys.sorted(by: preferredProductSort).first
            ?? "unknown"
        let subscriptionInfo = subscriber.subscriptions[productId]
        let periodEndsAt = parseRevenueCatDate(proEntitlement?.expiresDate ?? subscriptionInfo?.expiresDate)
        let purchaseDate = parseRevenueCatDate(proEntitlement?.purchaseDate ?? subscriptionInfo?.purchaseDate ?? subscriptionInfo?.originalPurchaseDate)
        let graceEndsAt = parseRevenueCatDate(subscriptionInfo?.gracePeriodExpiresDate)
        let now = Date()
        let isActive = periodEndsAt.map { $0 > now } ?? false
        let isInGrace = graceEndsAt.map { $0 > now } ?? false
        let hasBillingIssue = subscriptionInfo?.billingIssuesDetectedAt != nil
        let isCancelled = subscriptionInfo?.unsubscribeDetectedAt != nil

        let status: String
        let entitlementLevel: String
        if isActive {
            status = isCancelled ? "cancelled" : "active"
            entitlementLevel = "pro"
        } else if hasBillingIssue && isInGrace {
            status = "billing_issue"
            entitlementLevel = "pro"
        } else if hasBillingIssue {
            status = "billing_issue"
            entitlementLevel = "free"
        } else {
            status = "expired"
            entitlementLevel = "free"
        }

        let subscription = try await Subscription.query(on: db)
            .filter(\.$provider == "revenuecat")
            .filter(\.$providerOriginalTransactionId == "\(userId.uuidString):\(productId)")
            .first()
            ?? Subscription(
                userId: userId,
                provider: "revenuecat",
                providerCustomerId: userId.uuidString,
                providerOriginalTransactionId: "\(userId.uuidString):\(productId)",
                productId: productId,
                plan: plan(for: productId),
                status: status
            )

        subscription.userId = userId
        subscription.store = subscriptionInfo?.store?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        subscription.providerCustomerId = userId.uuidString
        subscription.productId = productId
        subscription.plan = plan(for: productId)
        subscription.status = status
        subscription.periodStartedAt = purchaseDate ?? subscription.periodStartedAt
        subscription.periodEndsAt = periodEndsAt
        subscription.trialEndsAt = subscriptionInfo?.periodType?.uppercased() == "TRIAL" ? periodEndsAt : subscription.trialEndsAt
        subscription.gracePeriodEndsAt = graceEndsAt
        subscription.cancelledAt = parseRevenueCatDate(subscriptionInfo?.unsubscribeDetectedAt)
        if subscription.pendingProductId == productId {
            subscription.pendingProductId = nil
            subscription.pendingPlan = nil
            subscription.pendingPlanEffectiveAt = nil
        }
        try await subscription.save(on: db)

        let entitlement = try await Entitlement.query(on: db)
            .filter(\.$userId == userId)
            .first()
            ?? Entitlement(userId: userId, level: entitlementLevel, subscriptionId: subscription.id)
        entitlement.level = entitlementLevel
        entitlement.subscriptionId = subscription.id
        try await entitlement.save(on: db)
    }

    func preferredProductSort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "pro_yearly" {
            return true
        }
        if rhs == "pro_yearly" {
            return false
        }
        if lhs == "pro_annual" {
            return true
        }
        if rhs == "pro_annual" {
            return false
        }
        if lhs == "pro_monthly" {
            return true
        }
        if rhs == "pro_monthly" {
            return false
        }
        return lhs < rhs
    }

    func plan(for productId: String) -> String {
        let product = productId.lowercased()
        if product.contains("annual") || product.contains("year") {
            return "pro_yearly"
        }
        if product.contains("weekly") || product.contains("week") {
            return "pro_weekly"
        }
        if product.contains("monthly") || product.contains("month") {
            return "pro_monthly"
        }
        return productId.hasPrefix("pro_") ? productId : "pro_monthly"
    }

    func parseRevenueCatDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
