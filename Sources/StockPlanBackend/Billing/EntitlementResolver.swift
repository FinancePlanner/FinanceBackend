import Fluent
import Foundation
import Vapor

struct EntitlementSnapshot {
    let userId: UUID
    let level: String

    var isPro: Bool {
        level == "pro" || level.hasPrefix("pro_") || level == "premium" || level.hasPrefix("premium_") || level == "temporary"
    }

    var isPremium: Bool {
        isPro
    }
}

struct BillingUpgradeRequiredError: Error, AbortError {
    let status: HTTPResponseStatus = .forbidden
    let reason: String
    let feature: BillingFeature
    let plan: String
    let requiredPlan: String
    let limit: Int?
    let current: Int?

    init(
        feature: BillingFeature,
        plan: String,
        requiredPlan: String = "pro",
        limit: Int? = nil,
        current: Int? = nil
    ) {
        self.feature = feature
        self.plan = plan
        self.requiredPlan = requiredPlan
        self.limit = limit
        self.current = current
        if let limit, let current {
            reason = "Upgrade required. feature=\(feature.rawValue) plan=\(plan) limit=\(limit) current=\(current)"
        } else {
            reason = "Upgrade required. feature=\(feature.rawValue) plan=\(plan) required=\(requiredPlan)"
        }
    }
}

protocol EntitlementResolver: Sendable {
    func resolve(userId: UUID, on db: any Database) async throws -> EntitlementSnapshot
}

struct DefaultEntitlementResolver: EntitlementResolver {
    let environment: Vapor.Environment
    let premiumEmails: Set<String>

    func resolve(userId: UUID, on db: any Database) async throws -> EntitlementSnapshot {
        // 1. Explicit local/test bypass
        let bypassBilling = Environment.get("BYPASS_BILLING") == "true"
        if bypassBilling {
            return EntitlementSnapshot(userId: userId, level: "pro")
        }

        // 2. Admin/Premium Email Bypass
        if !premiumEmails.isEmpty,
           let user = try await User.find(userId, on: db),
           premiumEmails.contains(user.email.lowercased())
        {
            return EntitlementSnapshot(userId: userId, level: "pro")
        }

        // 3. Fetch explicit entitlement (e.g. from a subscription)
        let entitlement = try await Entitlement.query(on: db)
            .filter(\.$userId == userId)
            .first()

        // 4. Active Trial Logic: Trial Tier ("temporary") should override "free" or missing entitlements
        if let user = try await User.find(userId, on: db),
           let trialTier = user.trialTier,
           Self.hasActiveTrial(user)
        {
            // If user has a trial, and no entitlement or the entitlement is "free", trial wins.
            if entitlement == nil || entitlement?.level == "free" {
                return EntitlementSnapshot(userId: userId, level: trialTier)
            }
        }

        return EntitlementSnapshot(userId: userId, level: entitlement?.level ?? "free")
    }

    private static func hasActiveTrial(_ user: User) -> Bool {
        guard let startedAt = user.trialStartedAt,
              let days = user.trialDays,
              days > 0
        else {
            return false
        }

        let expiresAt = startedAt.addingTimeInterval(TimeInterval(days * 86400))
        return Date() < expiresAt
    }
}

enum BillingFeature: String {
    case brokerSync = "broker_sync"
    case portfolioLists = "portfolio_lists"
    case holdings
    case watchlistItems = "watchlist_items"
    case valuationCases = "valuation_cases"
    case csvImports = "csv_imports"
    case targetAlerts = "target_alerts"
    case reportGenerations = "report_generations"
    /// Core expense budgeting (record spend, snapshots, plan items, categories).
    /// Free users have access to this — the planner itself is free, only advanced
    /// features (partner, recurring, year overview, suggestions) are Pro.
    /// Reports are now available to free users (with report generation limits).
    case expensePlanner = "expense_planner"
    case reports
    case statistics
    case marketFundamentals = "market_fundamentals"
    case advancedResearch = "advanced_research"
    case peerComparison = "peer_comparison"
    case earningsText = "earnings_text"
    /// Household partner split view — Pro only.
    case householdPartner = "household_partner"
    /// Recurring expense templates — Pro only.
    case recurringTemplates = "recurring_templates"
    /// Year-over-year expense history card — Pro only.
    case yearOverview = "year_overview"
    /// AI/rule-based smart spending suggestions — Pro only.
    case smartSuggestions = "smart_suggestions"
    /// Cryptocurrency endpoints (market data, news, portfolio) — Pro/trial only.
    case crypto
    /// AI financial insight cards (educational, reads user's own data) — Pro/trial only.
    case aiInsights = "ai_insights"
    /// Connecting external AI clients via MCP (personal access tokens, OAuth) — Pro/trial only.
    case mcpAccess = "mcp_access"
    /// Advanced portfolio scenarios and stress tests — Pro/trial only.
    case scenarioPlanning = "scenario_planning"
    /// Tax projections, harvesting scenarios, workpapers, and alerts — Pro/trial only.
    case taxOptimization = "tax_optimization"
    /// Server-side OCR of receipt photos for expense entry — Pro/trial only.
    /// (Structured fiscal-QR parsing is free; only image OCR is gated.)
    case receiptScan = "receipt_scan"
    /// Read-only bank sync (Plaid, GoCardless) into the expense flow — Pro/trial only.
    case bankSync = "bank_sync"
    /// AI-assisted .xlsx expense import — Pro/trial only. Distinct from
    /// `csvImports`, which is a counted free-tier allowance with different
    /// semantics; this one costs an AI call per upload.
    case spreadsheetImport = "spreadsheet_import"
    /// Retirement, joint, and hypothetical portfolios beyond the free personal portfolio.
    case advancedPortfolios = "advanced_portfolios"
    /// Sharing a portfolio with verified editor accounts.
    case jointPortfolios = "joint_portfolios"
    /// Composable PDF/XLSX report templates.
    case advancedReportTemplates = "advanced_report_templates"
    /// Scheduled report generation and email delivery.
    case advancedReportSchedules = "advanced_report_schedules"
    /// On-demand advanced PDF/XLSX generation.
    case advancedReportRuns = "advanced_report_runs"
    /// Portfolio cash-flow Monte Carlo forecasting — Pro/trial only.
    case netWorthForecasting = "net_worth_forecasting"
    /// User-defined watchlist fundamentals screens and entry alerts — Pro/trial only.
    case smartScreening = "smart_screening"
    /// Deterministic portfolio drift and cadence policies — Pro/trial only.
    case rebalancingRules = "rebalancing_rules"
    /// Deterministic planning is free for one active goal; cross-feature optimization is Pro.
    case goalPlanning = "goal_planning"
}

struct BillingPlanLimits {
    let portfolioListCount: Int?
    let holdingCount: Int?
    let watchlistItemCount: Int?
    let valuationCaseCount: Int?
    let csvImportCount: Int?
    let targetAlertCount: Int?
    let reportGenerationCount: Int?

    static let free = BillingPlanLimits(
        portfolioListCount: 1,
        holdingCount: 5,
        watchlistItemCount: 10,
        valuationCaseCount: 1,
        csvImportCount: 1,
        targetAlertCount: 1,
        reportGenerationCount: 50
    )

    static let premium = BillingPlanLimits(
        portfolioListCount: nil,
        holdingCount: nil,
        watchlistItemCount: nil,
        valuationCaseCount: nil,
        csvImportCount: nil,
        targetAlertCount: nil,
        reportGenerationCount: nil
    )

    static let pro = premium

    func limit(for feature: BillingFeature) -> Int? {
        switch feature {
        case .portfolioLists:
            portfolioListCount
        case .holdings:
            holdingCount
        case .watchlistItems:
            watchlistItemCount
        case .valuationCases:
            valuationCaseCount
        case .csvImports:
            csvImportCount
        case .targetAlerts:
            targetAlertCount
        case .reportGenerations:
            reportGenerationCount
        case .brokerSync, .expensePlanner, .reports, .statistics, .marketFundamentals,
             .advancedResearch, .peerComparison, .earningsText,
             .householdPartner, .recurringTemplates, .yearOverview, .smartSuggestions,
             .crypto, .aiInsights, .mcpAccess, .scenarioPlanning, .taxOptimization, .receiptScan, .bankSync,
             .spreadsheetImport,
             .advancedPortfolios, .jointPortfolios, .advancedReportTemplates,
             .advancedReportSchedules, .advancedReportRuns,
             .netWorthForecasting, .smartScreening, .rebalancingRules, .goalPlanning:
            nil
        }
    }
}

protocol UsageCounterService: Sendable {
    func limits(for entitlement: EntitlementSnapshot) -> BillingPlanLimits
    func counter(userId: UUID, on db: any Database) async throws -> UsageCounter
    func requirePremium(_ feature: BillingFeature, userId: UUID, on db: any Database) async throws
    func enforceResourceLimit(
        _ feature: BillingFeature,
        userId: UUID,
        currentCount: Int,
        adding: Int,
        on db: any Database
    ) async throws
    func incrementUsage(_ feature: BillingFeature, userId: UUID, by amount: Int, on db: any Database) async throws
    func syncResourceCount(_ feature: BillingFeature, userId: UUID, count: Int, on db: any Database) async throws
}

struct DefaultUsageCounterService: UsageCounterService {
    let entitlementResolver: any EntitlementResolver

    func limits(for entitlement: EntitlementSnapshot) -> BillingPlanLimits {
        entitlement.isPro ? .pro : .free
    }

    func requirePremium(_ feature: BillingFeature, userId: UUID, on db: any Database) async throws {
        let entitlement = try await entitlementResolver.resolve(userId: userId, on: db)
        guard entitlement.isPro else {
            throw billingUpgradeError(feature: feature, plan: entitlement.level)
        }
    }

    func counter(userId: UUID, on db: any Database) async throws -> UsageCounter {
        let periodStart = Self.monthStart(for: Date())
        if let existing = try await UsageCounter.query(on: db)
            .filter(\.$userId == userId)
            .first()
        {
            if existing.periodStart < periodStart {
                existing.periodStart = periodStart
                existing.csvImportCount = 0
                existing.reportGenerationCount = 0
                try await existing.save(on: db)
            }
            return existing
        }

        let created = UsageCounter(userId: userId, periodStart: periodStart)
        try await created.save(on: db)
        return created
    }

    func enforceResourceLimit(
        _ feature: BillingFeature,
        userId: UUID,
        currentCount: Int,
        adding: Int = 1,
        on db: any Database
    ) async throws {
        let entitlement = try await entitlementResolver.resolve(userId: userId, on: db)
        guard let limit = limits(for: entitlement).limit(for: feature) else { return }
        guard currentCount + adding <= limit else {
            throw billingLimitError(feature: feature, limit: limit, current: currentCount)
        }
    }

    func incrementUsage(_ feature: BillingFeature, userId: UUID, by amount: Int = 1, on db: any Database) async throws {
        guard amount > 0 else { return }
        let entitlement = try await entitlementResolver.resolve(userId: userId, on: db)
        let usage = try await counter(userId: userId, on: db)

        if let limit = limits(for: entitlement).limit(for: feature), usageValue(for: feature, in: usage) + amount > limit {
            throw billingLimitError(feature: feature, limit: limit, current: usageValue(for: feature, in: usage))
        }

        setUsageValue(for: feature, in: usage, value: usageValue(for: feature, in: usage) + amount)
        try await usage.save(on: db)
    }

    func syncResourceCount(_ feature: BillingFeature, userId: UUID, count: Int, on db: any Database) async throws {
        let usage = try await counter(userId: userId, on: db)
        setUsageValue(for: feature, in: usage, value: max(0, count))
        try await usage.save(on: db)
    }

    private func usageValue(for feature: BillingFeature, in usage: UsageCounter) -> Int {
        switch feature {
        case .holdings:
            usage.holdingCount
        case .watchlistItems:
            usage.watchlistItemCount
        case .csvImports:
            usage.csvImportCount
        case .targetAlerts:
            usage.targetAlertCount
        case .reportGenerations:
            usage.reportGenerationCount
        case .brokerSync, .portfolioLists, .valuationCases, .expensePlanner, .reports,
             .statistics, .marketFundamentals, .advancedResearch, .peerComparison, .earningsText,
             .householdPartner, .recurringTemplates, .yearOverview, .smartSuggestions,
             .crypto, .aiInsights, .mcpAccess, .scenarioPlanning, .taxOptimization, .receiptScan, .bankSync,
             .spreadsheetImport,
             .advancedPortfolios, .jointPortfolios, .advancedReportTemplates,
             .advancedReportSchedules, .advancedReportRuns,
             .netWorthForecasting, .smartScreening, .rebalancingRules, .goalPlanning:
            0
        }
    }

    private func setUsageValue(for feature: BillingFeature, in usage: UsageCounter, value: Int) {
        switch feature {
        case .holdings:
            usage.holdingCount = value
        case .watchlistItems:
            usage.watchlistItemCount = value
        case .csvImports:
            usage.csvImportCount = value
        case .targetAlerts:
            usage.targetAlertCount = value
        case .reportGenerations:
            usage.reportGenerationCount = value
        case .brokerSync, .portfolioLists, .valuationCases, .expensePlanner, .reports,
             .statistics, .marketFundamentals, .advancedResearch, .peerComparison, .earningsText,
             .householdPartner, .recurringTemplates, .yearOverview, .smartSuggestions,
             .crypto, .aiInsights, .mcpAccess, .scenarioPlanning, .taxOptimization, .receiptScan, .bankSync,
             .spreadsheetImport,
             .advancedPortfolios, .jointPortfolios, .advancedReportTemplates,
             .advancedReportSchedules, .advancedReportRuns,
             .netWorthForecasting, .smartScreening, .rebalancingRules, .goalPlanning:
            break
        }
    }

    private func billingLimitError(feature: BillingFeature, limit: Int, current: Int) -> BillingUpgradeRequiredError {
        BillingUpgradeRequiredError(
            feature: feature,
            plan: "free",
            limit: limit,
            current: current
        )
    }

    private func billingUpgradeError(feature: BillingFeature, plan: String) -> BillingUpgradeRequiredError {
        BillingUpgradeRequiredError(feature: feature, plan: plan)
    }

    private static func monthStart(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }
}
