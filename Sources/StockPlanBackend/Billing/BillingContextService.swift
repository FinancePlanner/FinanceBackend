import Fluent
import Foundation
import Vapor

protocol BillingContextService: Sendable {
    func context(userId: UUID, on db: any Database) async throws -> BillingContextResponse
}

struct DefaultBillingContextService: BillingContextService {
    let entitlementResolver: any EntitlementResolver
    let usageCounterService: any UsageCounterService
    let trialService: any TrialServicing

    func context(userId: UUID, on db: any Database) async throws -> BillingContextResponse {
        guard let user = try await User.find(userId, on: db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        async let entitlementValue = entitlementResolver.resolve(userId: userId, on: db)
        async let subscriptionValue = currentSubscription(userId: userId, on: db)
        async let usageValue = usageCounterService.counter(userId: userId, on: db)
        async let portfolioListCountValue = PortfolioList.query(on: db)
            .filter(\.$userId == userId)
            .count()
        async let holdingCountValue = Stock.query(on: db)
            .filter(\.$userId == userId)
            .count()
        async let watchlistItemCountValue = WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .count()
        async let valuationCaseCountValue = StockValuation.query(on: db)
            .filter(\.$userId == userId)
            .count()
        async let targetAlertCountValue = Target.query(on: db)
            .filter(\.$userId == userId)
            .count()

        let entitlement = try await entitlementValue
        let subscription = try await subscriptionValue
        let usage = try await usageValue
        let portfolioListCount = try await portfolioListCountValue
        let holdingCount = try await holdingCountValue
        let watchlistItemCount = try await watchlistItemCountValue
        let valuationCaseCount = try await valuationCaseCountValue
        let targetAlertCount = try await targetAlertCountValue
        let limits = usageCounterService.limits(for: entitlement)

        let trialStatus = trialService.checkTrialStatus(user: user)
        let (trialDaysRemaining, isTrialActive): (Int?, Bool) = switch trialStatus {
        case let .active(days), let .expiringSoon(days):
            (days, true)
        case .expired, .notOnTrial:
            (nil, false)
        }

        // A trial has "expired" once the user is no longer entitled and either the
        // background sweep has already stamped `hadTrial` (which clears the trial_*
        // fields) or the trial window has lapsed but the sweep hasn't run yet.
        // Never-trialed free users have `hadTrial == false` and no trial fields, so
        // this stays false for them.
        let trialExpired = !entitlement.isPremium
            && (user.hadTrial || trialService.isTrialExpired(user: user))

        let usageRows = makeUsageRows(
            usage: usage,
            limits: limits,
            portfolioListCount: portfolioListCount,
            holdingCount: holdingCount,
            watchlistItemCount: watchlistItemCount,
            valuationCaseCount: valuationCaseCount,
            targetAlertCount: targetAlertCount
        )

        let usageByFeature = Dictionary(uniqueKeysWithValues: usageRows.map { ($0.key, $0) })
        let features = makeFeatures(
            entitlement: entitlement,
            limits: limits,
            usageByFeature: usageByFeature
        )

        let plan = subscription?.plan ?? entitlement.level

        return BillingContextResponse(
            plan: plan,
            entitlementLevel: entitlement.level,
            isPremium: entitlement.isPremium,
            subscription: subscription.map(makeSubscriptionDTO),
            planOptions: makePlanOptions(currentPlan: plan, isPremium: entitlement.isPremium),
            features: features,
            usage: usageRows,
            trialDaysRemaining: trialDaysRemaining,
            isTrialActive: isTrialActive,
            trialExpired: trialExpired,
            generatedAt: Date()
        )
    }

    private func currentSubscription(userId: UUID, on db: any Database) async throws -> Subscription? {
        try await Subscription.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)
            .first()
    }

    private func makeUsageRows(
        usage: UsageCounter,
        limits: BillingPlanLimits,
        portfolioListCount: Int,
        holdingCount: Int,
        watchlistItemCount: Int,
        valuationCaseCount: Int,
        targetAlertCount: Int
    ) -> [BillingUsageDTO] {
        [
            usageRow(.portfolioLists, used: portfolioListCount, limit: limits.limit(for: .portfolioLists), periodStart: nil),
            usageRow(.holdings, used: holdingCount, limit: limits.limit(for: .holdings), periodStart: nil),
            usageRow(.watchlistItems, used: watchlistItemCount, limit: limits.limit(for: .watchlistItems), periodStart: nil),
            usageRow(.valuationCases, used: valuationCaseCount, limit: limits.limit(for: .valuationCases), periodStart: nil),
            usageRow(.csvImports, used: usage.csvImportCount, limit: limits.limit(for: .csvImports), periodStart: usage.periodStart),
            usageRow(.targetAlerts, used: targetAlertCount, limit: limits.limit(for: .targetAlerts), periodStart: nil),
            usageRow(.reportGenerations, used: usage.reportGenerationCount, limit: limits.limit(for: .reportGenerations), periodStart: usage.periodStart),
        ]
    }

    private func makeFeatures(
        entitlement: EntitlementSnapshot,
        limits: BillingPlanLimits,
        usageByFeature: [String: BillingUsageDTO]
    ) -> [BillingFeatureDTO] {
        BillingFeatureDescriptor.all.map { descriptor in
            let available = entitlement.isPro || !descriptor.proOnly
            let usage = usageByFeature[descriptor.feature.rawValue]
            let limit = limits.limit(for: descriptor.feature)
            return BillingFeatureDTO(
                key: descriptor.feature.rawValue,
                title: descriptor.title,
                available: available,
                requiredPlan: available ? nil : "pro",
                reason: available ? nil : "Upgrade to Pro to use \(descriptor.title).",
                limit: limit,
                used: usage?.used,
                remaining: usage?.remaining
            )
        }
    }

    private func usageRow(
        _ feature: BillingFeature,
        used: Int,
        limit: Int?,
        periodStart: Date?
    ) -> BillingUsageDTO {
        BillingUsageDTO(
            key: feature.rawValue,
            used: used,
            limit: limit,
            remaining: limit.map { max(0, $0 - used) },
            periodStart: periodStart
        )
    }

    private func makeSubscriptionDTO(_ subscription: Subscription) -> BillingSubscriptionDTO {
        let now = Date()
        let isTrial = subscription.status == "trialing" || subscription.trialEndsAt.map { $0 > now } == true
        let isInGracePeriod = subscription.gracePeriodEndsAt.map { $0 > now } == true
        let isCancelledButActive = subscription.status == "cancelled"
            && subscription.periodEndsAt.map { $0 > now } == true

        return BillingSubscriptionDTO(
            provider: subscription.provider,
            store: subscription.store,
            productId: subscription.productId,
            plan: subscription.plan,
            status: subscription.status,
            periodStartedAt: subscription.periodStartedAt,
            periodEndsAt: subscription.periodEndsAt,
            trialEndsAt: subscription.trialEndsAt,
            gracePeriodEndsAt: subscription.gracePeriodEndsAt,
            cancelledAt: subscription.cancelledAt,
            isTrial: isTrial,
            isInGracePeriod: isInGracePeriod,
            hasBillingIssue: subscription.status == "billing_issue",
            isCancelledButActive: isCancelledButActive,
            renewsOrExpiresAt: subscription.periodEndsAt,
            willRenew: willRenew(subscription),
            accessEndsAt: subscription.periodEndsAt,
            pendingProductId: subscription.pendingProductId,
            pendingPlan: subscription.pendingPlan,
            pendingPlanEffectiveAt: subscription.pendingPlanEffectiveAt
        )
    }

    private func makePlanOptions(currentPlan: String, isPremium: Bool) -> [BillingPlanOptionDTO] {
        PlanOptionDescriptor.all.map { descriptor in
            let currentRank = planRank(currentPlan)
            let isCurrent = descriptor.plan == currentPlan
            let changeKind = if isCurrent {
                "current"
            } else if !isPremium {
                "subscribe"
            } else if let currentRank, descriptor.rank > currentRank {
                "upgrade"
            } else if let currentRank, descriptor.rank < currentRank {
                "downgrade"
            } else {
                "subscribe"
            }

            return BillingPlanOptionDTO(
                productId: descriptor.productId,
                plan: descriptor.plan,
                displayName: descriptor.displayName,
                interval: descriptor.interval,
                rank: descriptor.rank,
                badge: descriptor.badge,
                isCurrent: isCurrent,
                changeKind: changeKind
            )
        }
    }

    private func planRank(_ plan: String) -> Int? {
        switch plan {
        case "pro_weekly":
            1
        case "pro_monthly":
            2
        case "pro_yearly", "pro_annual":
            3
        default:
            nil
        }
    }

    private func willRenew(_ subscription: Subscription) -> Bool {
        switch subscription.status {
        case "active", "trialing", "grace_period":
            true
        default:
            false
        }
    }
}

private struct PlanOptionDescriptor {
    let productId: String
    let plan: String
    let displayName: String
    let interval: String
    let rank: Int
    let badge: String?

    static let all: [PlanOptionDescriptor] = [
        .init(productId: "pro_weekly", plan: "pro_weekly", displayName: "Weekly", interval: "weekly", rank: 1, badge: nil),
        .init(productId: "pro_monthly", plan: "pro_monthly", displayName: "Monthly", interval: "monthly", rank: 2, badge: "Better value"),
        .init(productId: "pro_yearly", plan: "pro_yearly", displayName: "Annual", interval: "annual", rank: 3, badge: "Best value"),
    ]
}

private struct BillingFeatureDescriptor {
    let feature: BillingFeature
    let title: String
    let proOnly: Bool

    static let all: [BillingFeatureDescriptor] = [
        .init(feature: .brokerSync, title: "Broker sync", proOnly: true),
        .init(feature: .portfolioLists, title: "Portfolio lists", proOnly: false),
        .init(feature: .holdings, title: "Holdings", proOnly: false),
        .init(feature: .watchlistItems, title: "Watchlist items", proOnly: false),
        .init(feature: .valuationCases, title: "Saved valuation cases", proOnly: true),
        .init(feature: .csvImports, title: "CSV imports", proOnly: false),
        .init(feature: .targetAlerts, title: "Price, dividend, and earnings alerts", proOnly: true),
        .init(feature: .reportGenerations, title: "Report generations", proOnly: false),
        // Core expense planner is free; advanced expense features are gated individually below.
        .init(feature: .expensePlanner, title: "Expense planner (core budgeting)", proOnly: false),
        .init(feature: .householdPartner, title: "Household partner split view", proOnly: true),
        .init(feature: .recurringTemplates, title: "Recurring expense templates", proOnly: true),
        .init(feature: .yearOverview, title: "Year-over-year expense history", proOnly: true),
        .init(feature: .smartSuggestions, title: "Smart spending suggestions", proOnly: true),
        .init(feature: .reports, title: "Reports with charts", proOnly: false),
        .init(feature: .statistics, title: "Advanced statistics", proOnly: true),
        .init(feature: .marketFundamentals, title: "Real stock fundamentals", proOnly: true),
        .init(feature: .advancedResearch, title: "Advanced stock research", proOnly: true),
        .init(feature: .peerComparison, title: "Peer comparison", proOnly: true),
        .init(feature: .earningsText, title: "Earnings detail", proOnly: true),
        .init(feature: .crypto, title: "Cryptocurrency", proOnly: true),
        .init(feature: .receiptScan, title: "Receipt photo scanning (OCR)", proOnly: true),
        .init(feature: .spreadsheetImport, title: "Smart spreadsheet import", proOnly: true),
        .init(feature: .bankSync, title: "Bank sync", proOnly: true),
        .init(feature: .advancedPortfolios, title: "Retirement and hypothetical portfolios", proOnly: true),
        .init(feature: .jointPortfolios, title: "Joint portfolio collaboration", proOnly: true),
        .init(feature: .advancedReportTemplates, title: "Advanced report templates", proOnly: true),
        .init(feature: .advancedReportSchedules, title: "Scheduled report delivery", proOnly: true),
        .init(feature: .advancedReportRuns, title: "PDF and Excel reports", proOnly: true),
        .init(feature: .netWorthForecasting, title: "Net worth forecasting", proOnly: true),
        .init(feature: .smartScreening, title: "Smart watchlist screening", proOnly: true),
        .init(feature: .rebalancingRules, title: "Custom rebalancing rules", proOnly: true),
        .init(feature: .goalPlanning, title: "Goal-based financial planning", proOnly: false),
        .init(feature: .aiInsights, title: "AI assistant and insights", proOnly: true),
        .init(feature: .mcpAccess, title: "MCP integrations", proOnly: true),
        .init(feature: .scenarioPlanning, title: "Scenario planning", proOnly: true),
        .init(feature: .taxOptimization, title: "Tax strategy", proOnly: true),
    ]
}
