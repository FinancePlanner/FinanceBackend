import Foundation
import StockPlanShared
import Vapor

struct BudgetController: RouteCollection {
    private struct BudgetSnapshotPayload: Decodable {
        let monthStart: String
        let netSalary: Double
        let targetShares: [String: Double]
        let currencyCode: String?
        let categoryDriftThreshold: Double?
        let totalDriftThreshold: Double?
        let alertsEnabled: Bool?
        let alertOnUnbudgeted: Bool?

        private enum CodingKeys: String, CodingKey {
            case monthStartSnake = "month_start"
            case monthStartCamel = "monthStart"
            case netSalarySnake = "net_salary"
            case netSalaryCamel = "netSalary"
            case targetSharesSnake = "target_shares"
            case targetSharesCamel = "targetShares"
            case currencyCodeSnake = "currency_code"
            case currencyCodeCamel = "currencyCode"
            case categoryDriftThresholdSnake = "category_drift_threshold"
            case categoryDriftThresholdCamel = "categoryDriftThreshold"
            case totalDriftThresholdSnake = "total_drift_threshold"
            case totalDriftThresholdCamel = "totalDriftThreshold"
            case alertsEnabledSnake = "alerts_enabled"
            case alertsEnabledCamel = "alertsEnabled"
            case alertOnUnbudgetedSnake = "alert_on_unbudgeted"
            case alertOnUnbudgetedCamel = "alertOnUnbudgeted"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            monthStart =
                try container.decodeIfPresent(String.self, forKey: .monthStartSnake)
                    ?? container.decode(String.self, forKey: .monthStartCamel)
            netSalary =
                try container.decodeIfPresent(Double.self, forKey: .netSalarySnake)
                    ?? container.decode(Double.self, forKey: .netSalaryCamel)
            targetShares =
                try container.decodeIfPresent([String: Double].self, forKey: .targetSharesSnake)
                    ?? container.decodeIfPresent([String: Double].self, forKey: .targetSharesCamel)
                    ?? [:]
            currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCodeSnake)
                ?? container.decodeIfPresent(String.self, forKey: .currencyCodeCamel)
            categoryDriftThreshold = try container.decodeIfPresent(Double.self, forKey: .categoryDriftThresholdSnake)
                ?? container.decodeIfPresent(Double.self, forKey: .categoryDriftThresholdCamel)
            totalDriftThreshold = try container.decodeIfPresent(Double.self, forKey: .totalDriftThresholdSnake)
                ?? container.decodeIfPresent(Double.self, forKey: .totalDriftThresholdCamel)
            alertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .alertsEnabledSnake)
                ?? container.decodeIfPresent(Bool.self, forKey: .alertsEnabledCamel)
            alertOnUnbudgeted = try container.decodeIfPresent(Bool.self, forKey: .alertOnUnbudgetedSnake)
                ?? container.decodeIfPresent(Bool.self, forKey: .alertOnUnbudgetedCamel)
        }

        func asRequest() -> BudgetSnapshotRequest {
            BudgetSnapshotRequest(
                monthStart: monthStart,
                netSalary: netSalary,
                targetShares: targetShares,
                currencyCode: currencyCode,
                categoryDriftThreshold: categoryDriftThreshold,
                totalDriftThreshold: totalDriftThreshold,
                alertsEnabled: alertsEnabled,
                alertOnUnbudgeted: alertOnUnbudgeted
            )
        }
    }

    private struct BudgetPlanItemPayload: Decodable {
        let snapshotId: String
        let title: String
        let plannedAmount: Double
        let pillar: BudgetPillar
        let splitMode: ExpenseSplitMode?
        let userSharePercent: Double?
        let categoryId: String?
        let targetType: BudgetTargetType?
        let incomePercentage: Double?
        let thresholdOverride: Double?
        let allocationKind: BudgetAllocationKind?
        let reallocationEligible: Bool?
        let destinationFinancialGoalId: String?
        let destinationPortfolioListId: String?

        private enum CodingKeys: String, CodingKey {
            case snapshotIdSnake = "snapshot_id"
            case snapshotIdCamel = "snapshotId"
            case title
            case plannedAmountSnake = "planned_amount"
            case plannedAmountCamel = "plannedAmount"
            case pillar
            case splitModeSnake = "split_mode"
            case splitModeCamel = "splitMode"
            case userSharePercentSnake = "user_share_percent"
            case userSharePercentCamel = "userSharePercent"
            case categoryIdSnake = "category_id"
            case categoryIdCamel = "categoryId"
            case targetTypeSnake = "target_type"
            case targetTypeCamel = "targetType"
            case incomePercentageSnake = "income_percentage"
            case incomePercentageCamel = "incomePercentage"
            case thresholdOverrideSnake = "threshold_override"
            case thresholdOverrideCamel = "thresholdOverride"
            case allocationKindSnake = "allocation_kind"
            case allocationKindCamel = "allocationKind"
            case reallocationEligibleSnake = "reallocation_eligible"
            case reallocationEligibleCamel = "reallocationEligible"
            case destinationFinancialGoalIdSnake = "destination_financial_goal_id"
            case destinationFinancialGoalIdCamel = "destinationFinancialGoalId"
            case destinationPortfolioListIdSnake = "destination_portfolio_list_id"
            case destinationPortfolioListIdCamel = "destinationPortfolioListId"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            snapshotId =
                try container.decodeIfPresent(String.self, forKey: .snapshotIdSnake)
                    ?? container.decode(String.self, forKey: .snapshotIdCamel)
            title = try container.decode(String.self, forKey: .title)
            plannedAmount =
                try container.decodeIfPresent(Double.self, forKey: .plannedAmountSnake)
                    ?? container.decode(Double.self, forKey: .plannedAmountCamel)
            pillar = try container.decode(BudgetPillar.self, forKey: .pillar)
            splitMode =
                try container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeSnake)
                    ?? container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeCamel)
            userSharePercent =
                try container.decodeIfPresent(Double.self, forKey: .userSharePercentSnake)
                    ?? container.decodeIfPresent(Double.self, forKey: .userSharePercentCamel)
            categoryId = try container.decodeIfPresent(String.self, forKey: .categoryIdSnake)
                ?? container.decodeIfPresent(String.self, forKey: .categoryIdCamel)
            targetType = try container.decodeIfPresent(BudgetTargetType.self, forKey: .targetTypeSnake)
                ?? container.decodeIfPresent(BudgetTargetType.self, forKey: .targetTypeCamel)
            incomePercentage = try container.decodeIfPresent(Double.self, forKey: .incomePercentageSnake)
                ?? container.decodeIfPresent(Double.self, forKey: .incomePercentageCamel)
            thresholdOverride = try container.decodeIfPresent(Double.self, forKey: .thresholdOverrideSnake)
                ?? container.decodeIfPresent(Double.self, forKey: .thresholdOverrideCamel)
            allocationKind = try container.decodeIfPresent(BudgetAllocationKind.self, forKey: .allocationKindSnake)
                ?? container.decodeIfPresent(BudgetAllocationKind.self, forKey: .allocationKindCamel)
            reallocationEligible = try container.decodeIfPresent(Bool.self, forKey: .reallocationEligibleSnake)
                ?? container.decodeIfPresent(Bool.self, forKey: .reallocationEligibleCamel)
            destinationFinancialGoalId = try container.decodeIfPresent(String.self, forKey: .destinationFinancialGoalIdSnake)
                ?? container.decodeIfPresent(String.self, forKey: .destinationFinancialGoalIdCamel)
            destinationPortfolioListId = try container.decodeIfPresent(String.self, forKey: .destinationPortfolioListIdSnake)
                ?? container.decodeIfPresent(String.self, forKey: .destinationPortfolioListIdCamel)
        }

        func asRequest() -> BudgetPlanItemRequest {
            BudgetPlanItemRequest(
                snapshotId: snapshotId,
                title: title,
                plannedAmount: plannedAmount,
                pillar: pillar,
                categoryId: categoryId,
                splitMode: splitMode ?? .personal,
                userSharePercent: userSharePercent ?? 100,
                targetType: targetType ?? .fixed,
                incomePercentage: incomePercentage,
                thresholdOverride: thresholdOverride,
                allocationKind: allocationKind ?? .expense,
                reallocationEligible: reallocationEligible ?? false,
                destinationFinancialGoalId: destinationFinancialGoalId,
                destinationPortfolioListId: destinationPortfolioListId
            )
        }
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let budget = protected.grouped("budget")
        let readable = budget.grouped(ScopeRequirementMiddleware(.budgetRead))
        let writable = budget.grouped(ScopeRequirementMiddleware(.budgetWrite))

        readable.get("snapshots", use: getSnapshots)
        writable.post("snapshots", use: createSnapshot)
        writable.patch("snapshots", ":snapshotId", use: updateSnapshot)
        writable.delete("snapshots", ":snapshotId", use: deleteSnapshot)
        readable.get("snapshots", ":snapshotId", "items", use: getSnapshotItems)
        readable.get("items", use: getAllPlanItems)
        writable.post("items", use: createPlanItem)
        writable.patch("items", ":itemId", use: updatePlanItem)
        writable.delete("items", ":itemId", use: deletePlanItem)
    }

    // MARK: - Snapshots

    @Sendable
    func getSnapshots(req: Request) async throws -> [BudgetSnapshotResponse] {
        let session = try req.auth.require(SessionToken.self)
        // Monthly budget snapshots (salary, pillar targets) are free — no Pro gate required.
        let year = req.query[Int.self, at: "year"]
        let month = req.query[Int.self, at: "month"]

        // Listing is how both clients open the planner, so this is where a new
        // calendar month gets its plan. Idempotent; a failure must not break reads.
        do {
            try await req.expensesService.ensureCurrentMonthRollover(userId: session.userId, now: Date(), on: req.db)
        } catch {
            req.logger.warning("budget month rollover failed: \(error)")
        }

        return try await req.expensesService.getSnapshots(
            userId: session.userId,
            year: year,
            month: month,
            on: req.db
        )
    }

    @Sendable
    func createSnapshot(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        // Monthly budget snapshot creation is free — no Pro gate required.
        let payload = try req.content.decode(BudgetSnapshotPayload.self).asRequest()

        let created = try await req.expensesService.createBudgetSnapshot(
            userId: session.userId,
            request: payload,
            on: req.db
        )
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updateSnapshot(req: Request) async throws -> BudgetSnapshotResponse {
        let session = try req.auth.require(SessionToken.self)
        // Snapshot update is free — no Pro gate required.
        let snapshotId = try requireUUIDParameter(req, name: "snapshotId")
        let payload = try req.content.decode(BudgetSnapshotPayload.self).asRequest()

        return try await req.expensesService.updateSnapshot(
            userId: session.userId,
            snapshotId: snapshotId,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    func deleteSnapshot(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        // Snapshot deletion is free — no Pro gate required.
        let snapshotId = try requireUUIDParameter(req, name: "snapshotId")

        try await req.expensesService.deleteSnapshot(
            userId: session.userId,
            snapshotId: snapshotId,
            on: req.db
        )
        return .noContent
    }

    // MARK: - Items

    @Sendable
    func getAllPlanItems(req: Request) async throws -> [BudgetPlanItemResponse] {
        let session = try req.auth.require(SessionToken.self)
        // Plan items are free — no Pro gate required.
        return try await req.expensesService.getAllPlanItems(
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func getSnapshotItems(req: Request) async throws -> [BudgetPlanItemResponse] {
        let session = try req.auth.require(SessionToken.self)
        // Plan items are free — no Pro gate required.
        let snapshotId = try requireUUIDParameter(req, name: "snapshotId")

        return try await req.expensesService.getPlanItems(
            userId: session.userId,
            snapshotId: snapshotId,
            on: req.db
        )
    }

    @Sendable
    func createPlanItem(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        // Plan item creation is free — no Pro gate required.
        let payload = try req.content.decode(BudgetPlanItemPayload.self).asRequest()

        let created = try await req.expensesService.createPlanItem(
            userId: session.userId,
            request: payload,
            on: req.db
        )
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updatePlanItem(req: Request) async throws -> BudgetPlanItemResponse {
        let session = try req.auth.require(SessionToken.self)
        // Plan item update is free — no Pro gate required.
        let itemId = try requireUUIDParameter(req, name: "itemId")
        let payload = try req.content.decode(BudgetPlanItemPayload.self).asRequest()

        return try await req.expensesService.updatePlanItem(
            userId: session.userId,
            itemId: itemId,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    func deletePlanItem(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        // Plan item deletion is free — no Pro gate required.
        let itemId = try requireUUIDParameter(req, name: "itemId")

        try await req.expensesService.deletePlanItem(
            userId: session.userId,
            itemId: itemId,
            on: req.db
        )
        return .noContent
    }

    // MARK: - Helpers

    private func requireUUIDParameter(_ req: Request, name: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid \(name).")
        }
        return value
    }

    // MARK: - Future Free-User Limits

    //
    // Core budget features (snapshots, plan items) are currently ungated for all authenticated users.
    // If you later decide to restrict free users, add quota enforcement in each endpoint above.
    // For example:
    //   - Limit free users to 1 active snapshot (current month only).
    //   - Cap plan items to a fixed number per snapshot.
    //   - Use `req.usageCounterService.enforceResourceLimit(.expensePlanner, ...)` for count-based limits.
    //   - Or use `req.usageCounterService.requirePremium(.expensePlanner, ...)` to block completely.
    // Backend feature key: `.expensePlanner` (currently `proOnly: false` in BillingContextService).
}
