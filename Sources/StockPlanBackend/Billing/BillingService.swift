import Fluent
import Foundation
import Vapor

struct RevenueCatWebhookPayload: Content {
    let event: RevenueCatWebhookEvent
}

struct RevenueCatWebhookEvent: Content {
    let id: String
    let type: String
    let appUserId: String
    let productId: String?
    let periodType: String?
    let purchasedAtMs: Int64?
    let expirationAtMs: Int64?
    let gracePeriodExpiresDateMs: Int64?
    let cancelReason: String?
    let expirationReason: String?
    let newProductId: String?
    let store: String?
    let originalTransactionId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case appUserId = "app_user_id"
        case appUserIdCamel = "appUserId"
        case productId = "product_id"
        case productIdCamel = "productId"
        case periodType = "period_type"
        case periodTypeCamel = "periodType"
        case purchasedAtMs = "purchased_at_ms"
        case purchasedAtMsCamel = "purchasedAtMs"
        case expirationAtMs = "expiration_at_ms"
        case expirationAtMsCamel = "expirationAtMs"
        case gracePeriodExpiresDateMs = "grace_period_expires_date_ms"
        case gracePeriodExpirationAtMs = "grace_period_expiration_at_ms"
        case gracePeriodExpiresDateMsCamel = "gracePeriodExpiresDateMs"
        case cancelReason = "cancel_reason"
        case cancelReasonCamel = "cancelReason"
        case expirationReason = "expiration_reason"
        case expirationReasonCamel = "expirationReason"
        case newProductId = "new_product_id"
        case newProductIdCamel = "newProductId"
        case store
        case originalTransactionId = "original_transaction_id"
        case originalTransactionIdCamel = "originalTransactionId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        appUserId = try container.decodeIfPresent(String.self, forKey: .appUserId)
            ?? container.decode(String.self, forKey: .appUserIdCamel)
        productId = try container.decodeIfPresent(String.self, forKey: .productId)
            ?? container.decodeIfPresent(String.self, forKey: .productIdCamel)
        periodType = try container.decodeIfPresent(String.self, forKey: .periodType)
            ?? container.decodeIfPresent(String.self, forKey: .periodTypeCamel)
        purchasedAtMs = try container.decodeIfPresent(Int64.self, forKey: .purchasedAtMs)
            ?? container.decodeIfPresent(Int64.self, forKey: .purchasedAtMsCamel)
        expirationAtMs = try container.decodeIfPresent(Int64.self, forKey: .expirationAtMs)
            ?? container.decodeIfPresent(Int64.self, forKey: .expirationAtMsCamel)
        gracePeriodExpiresDateMs = try container.decodeIfPresent(Int64.self, forKey: .gracePeriodExpiresDateMs)
            ?? container.decodeIfPresent(Int64.self, forKey: .gracePeriodExpirationAtMs)
            ?? container.decodeIfPresent(Int64.self, forKey: .gracePeriodExpiresDateMsCamel)
        cancelReason = try container.decodeIfPresent(String.self, forKey: .cancelReason)
            ?? container.decodeIfPresent(String.self, forKey: .cancelReasonCamel)
        expirationReason = try container.decodeIfPresent(String.self, forKey: .expirationReason)
            ?? container.decodeIfPresent(String.self, forKey: .expirationReasonCamel)
        newProductId = try container.decodeIfPresent(String.self, forKey: .newProductId)
            ?? container.decodeIfPresent(String.self, forKey: .newProductIdCamel)
        store = try container.decodeIfPresent(String.self, forKey: .store)
        originalTransactionId = try container.decodeIfPresent(String.self, forKey: .originalTransactionId)
            ?? container.decodeIfPresent(String.self, forKey: .originalTransactionIdCamel)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(appUserId, forKey: .appUserId)
        try container.encodeIfPresent(productId, forKey: .productId)
        try container.encodeIfPresent(periodType, forKey: .periodType)
        try container.encodeIfPresent(purchasedAtMs, forKey: .purchasedAtMs)
        try container.encodeIfPresent(expirationAtMs, forKey: .expirationAtMs)
        try container.encodeIfPresent(gracePeriodExpiresDateMs, forKey: .gracePeriodExpiresDateMs)
        try container.encodeIfPresent(cancelReason, forKey: .cancelReason)
        try container.encodeIfPresent(expirationReason, forKey: .expirationReason)
        try container.encodeIfPresent(newProductId, forKey: .newProductId)
        try container.encodeIfPresent(store, forKey: .store)
        try container.encodeIfPresent(originalTransactionId, forKey: .originalTransactionId)
    }
}

protocol BillingService: Sendable {
    func process(event: RevenueCatWebhookEvent, rawPayload: String, on db: any Database) async throws
}

struct DefaultBillingService: BillingService {
    private let provider = "revenuecat"

    func process(event: RevenueCatWebhookEvent, rawPayload: String, on db: any Database) async throws {
        if try await BillingEvent.query(on: db)
            .filter(\.$providerEventId == event.id)
            .first() != nil
        {
            return
        }

        let userId = UUID(uuidString: event.appUserId)
        let billingEvent = BillingEvent(
            providerEventId: event.id,
            provider: provider,
            eventType: event.type,
            userId: userId,
            rawPayload: rawPayload,
            processedAt: Date()
        )
        try await billingEvent.save(on: db)

        guard let userId else {
            return
        }

        switch event.type {
        case "NON_RENEWING_PURCHASE":
            // Consumables never touch the subscription or the Pro entitlement.
            // The only one we sell is the per-year filing pack.
            guard let taxYear = TaxPackEntitlementService.taxYear(fromProductId: event.productId) else {
                return
            }
            try await TaxPackEntitlementService().grant(
                userId: userId,
                taxYear: taxYear,
                source: normalizedStore(for: event) ?? provider,
                productId: event.productId ?? TaxPackEntitlementService.productId(taxYear: taxYear),
                providerEventId: event.id,
                on: db
            )

        case "INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION":
            let update = try await upsertSubscription(
                userId: userId,
                event: event,
                status: "active",
                cancelledAt: nil,
                on: db
            )
            try await revokeTransferredEntitlementIfNeeded(
                previousUserId: update.previousUserId,
                newUserId: userId,
                subscriptionId: update.subscription.id,
                on: db
            )
            try await upsertEntitlement(userId: userId, level: "pro", subscriptionId: update.subscription.id, on: db)

        case "CANCELLATION":
            let update = try await upsertSubscription(
                userId: userId,
                event: event,
                status: "cancelled",
                cancelledAt: Date(),
                on: db
            )
            try await revokeTransferredEntitlementIfNeeded(
                previousUserId: update.previousUserId,
                newUserId: userId,
                subscriptionId: update.subscription.id,
                on: db
            )
            try await upsertEntitlement(userId: userId, level: "pro", subscriptionId: update.subscription.id, on: db)

        case "PRODUCT_CHANGE":
            let update = try await upsertSubscription(
                userId: userId,
                event: event,
                status: "active",
                cancelledAt: nil,
                on: db
            )
            try await revokeTransferredEntitlementIfNeeded(
                previousUserId: update.previousUserId,
                newUserId: userId,
                subscriptionId: update.subscription.id,
                on: db
            )
            try await applyPendingPlanChange(event: event, subscription: update.subscription, on: db)
            try await upsertEntitlement(userId: userId, level: "pro", subscriptionId: update.subscription.id, on: db)

        case "EXPIRATION":
            let update = try await upsertSubscription(
                userId: userId,
                event: event,
                status: "expired",
                cancelledAt: nil,
                on: db
            )
            try await revokeTransferredEntitlementIfNeeded(
                previousUserId: update.previousUserId,
                newUserId: userId,
                subscriptionId: update.subscription.id,
                on: db
            )
            try await upsertEntitlement(userId: userId, level: "free", subscriptionId: update.subscription.id, on: db)

        case "REFUND":
            let update = try await upsertSubscription(
                userId: userId,
                event: event,
                status: "refunded",
                cancelledAt: nil,
                on: db
            )
            try await revokeTransferredEntitlementIfNeeded(
                previousUserId: update.previousUserId,
                newUserId: userId,
                subscriptionId: update.subscription.id,
                on: db
            )
            try await upsertEntitlement(userId: userId, level: "free", subscriptionId: update.subscription.id, on: db)

        case "BILLING_ISSUE":
            let update = try await upsertSubscription(
                userId: userId,
                event: event,
                status: "billing_issue",
                cancelledAt: nil,
                on: db
            )
            let graceEndsAt = event.gracePeriodExpiresDateMs.flatMap(dateFromMilliseconds)
            let level = graceEndsAt.map { $0 > Date() } == true ? "pro" : "free"
            try await revokeTransferredEntitlementIfNeeded(
                previousUserId: update.previousUserId,
                newUserId: userId,
                subscriptionId: update.subscription.id,
                on: db
            )
            try await upsertEntitlement(userId: userId, level: level, subscriptionId: update.subscription.id, on: db)

        default:
            return
        }
    }

    private func upsertSubscription(
        userId: UUID,
        event: RevenueCatWebhookEvent,
        status: String,
        cancelledAt: Date?,
        on db: any Database
    ) async throws -> (subscription: Subscription, previousUserId: UUID?) {
        let transactionId = transactionIdentifier(for: event)
        let subscription = try await Subscription.query(on: db)
            .filter(\.$provider == provider)
            .filter(\.$providerOriginalTransactionId == transactionId)
            .first()
            ?? Subscription(
                userId: userId,
                provider: provider,
                providerCustomerId: event.appUserId,
                providerOriginalTransactionId: transactionId,
                productId: productId(for: event),
                plan: plan(for: event),
                status: status
            )
        let previousUserId = subscription.id == nil ? nil : subscription.userId

        subscription.userId = userId
        subscription.store = normalizedStore(for: event)
        subscription.providerCustomerId = event.appUserId
        subscription.productId = productId(for: event)
        subscription.plan = plan(for: event)
        subscription.status = status
        subscription.periodStartedAt = event.purchasedAtMs.flatMap(dateFromMilliseconds) ?? subscription.periodStartedAt
        subscription.periodEndsAt = event.expirationAtMs.flatMap(dateFromMilliseconds) ?? subscription.periodEndsAt
        subscription.trialEndsAt = event.periodType == "TRIAL"
            ? event.expirationAtMs.flatMap(dateFromMilliseconds)
            : subscription.trialEndsAt
        subscription.gracePeriodEndsAt = event.gracePeriodExpiresDateMs.flatMap(dateFromMilliseconds)
        subscription.cancelledAt = cancelledAt ?? (status == "active" ? nil : subscription.cancelledAt)
        if subscription.pendingProductId == subscription.productId {
            subscription.pendingProductId = nil
            subscription.pendingPlan = nil
            subscription.pendingPlanEffectiveAt = nil
        }
        try await subscription.save(on: db)
        return (subscription, previousUserId)
    }

    private func applyPendingPlanChange(
        event: RevenueCatWebhookEvent,
        subscription: Subscription,
        on db: any Database
    ) async throws {
        guard let pendingProductId = event.newProductId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pendingProductId.isEmpty
        else {
            return
        }
        subscription.pendingProductId = pendingProductId
        subscription.pendingPlan = plan(forProductId: pendingProductId)
        subscription.pendingPlanEffectiveAt = event.expirationAtMs.flatMap(dateFromMilliseconds)
            ?? subscription.periodEndsAt
        try await subscription.save(on: db)
    }

    private func revokeTransferredEntitlementIfNeeded(
        previousUserId: UUID?,
        newUserId: UUID,
        subscriptionId: UUID?,
        on db: any Database
    ) async throws {
        guard let previousUserId, previousUserId != newUserId, let subscriptionId else {
            return
        }
        guard let entitlement = try await Entitlement.query(on: db)
            .filter(\.$userId == previousUserId)
            .first()
        else {
            return
        }
        guard entitlement.subscriptionId == subscriptionId else {
            return
        }
        entitlement.level = "free"
        entitlement.subscriptionId = nil
        try await entitlement.save(on: db)
    }

    private func upsertEntitlement(
        userId: UUID,
        level: String,
        subscriptionId: UUID?,
        on db: any Database
    ) async throws {
        let entitlement = try await Entitlement.query(on: db)
            .filter(\.$userId == userId)
            .first()
            ?? Entitlement(userId: userId, level: level, subscriptionId: subscriptionId)

        entitlement.level = level
        entitlement.subscriptionId = subscriptionId
        try await entitlement.save(on: db)
    }

    private func transactionIdentifier(for event: RevenueCatWebhookEvent) -> String {
        if let originalTransactionId = event.originalTransactionId, !originalTransactionId.isEmpty {
            return originalTransactionId
        }
        return "\(event.appUserId):\(productId(for: event))"
    }

    private func productId(for event: RevenueCatWebhookEvent) -> String {
        event.productId ?? "unknown"
    }

    private func plan(for event: RevenueCatWebhookEvent) -> String {
        plan(forProductId: productId(for: event))
    }

    private func plan(forProductId productId: String) -> String {
        let product = productId.lowercased()
        if product.contains("year") || product.contains("annual") {
            return "pro_yearly"
        }
        if product.contains("week") {
            return "pro_weekly"
        }
        if product.contains("month") {
            return "pro_monthly"
        }
        return productId.hasPrefix("pro_") ? productId : "pro_monthly"
    }

    private func normalizedStore(for event: RevenueCatWebhookEvent) -> String? {
        event.store?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func dateFromMilliseconds(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}
