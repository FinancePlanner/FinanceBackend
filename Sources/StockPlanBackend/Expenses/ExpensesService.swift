import Fluent
import Foundation
import StockPlanShared
import Vapor

struct ExpenseSearchFilters: Sendable {
    let from: Date?
    let to: Date?
    let query: String?
    let categoryId: UUID?
    let pillar: BudgetPillar?
    let limit: Int
    let cursor: Date?
}

protocol ExpensesService: Sendable {
    func getHouseholdPartner(userId: UUID, on db: any Database) async throws -> HouseholdPartnerProfileResponse
    func updateHouseholdPartner(userId: UUID, request: HouseholdPartnerProfileRequest, on db: any Database) async throws -> HouseholdPartnerProfileResponse

    // Snapshots
    func getSnapshots(userId: UUID, year: Int?, month: Int?, on db: any Database) async throws -> [BudgetSnapshotResponse]
    func createBudgetSnapshot(userId: UUID, request: BudgetSnapshotRequest, on db: any Database) async throws -> BudgetSnapshotResponse
    func updateSnapshot(userId: UUID, snapshotId: UUID, request: BudgetSnapshotRequest, on db: any Database) async throws -> BudgetSnapshotResponse
    func deleteSnapshot(userId: UUID, snapshotId: UUID, on db: any Database) async throws

    // Plan Items
    func getAllPlanItems(userId: UUID, on db: any Database) async throws -> [BudgetPlanItemResponse]
    func getPlanItems(userId: UUID, snapshotId: UUID, on db: any Database) async throws -> [BudgetPlanItemResponse]
    func createPlanItem(userId: UUID, request: BudgetPlanItemRequest, on db: any Database) async throws -> BudgetPlanItemResponse
    func updatePlanItem(userId: UUID, itemId: UUID, request: BudgetPlanItemRequest, on db: any Database) async throws -> BudgetPlanItemResponse
    func deletePlanItem(userId: UUID, itemId: UUID, on db: any Database) async throws

    // Expenses
    func getExpenses(userId: UUID, from: Date?, to: Date?, limit: Int, cursor: Date?, on db: any Database) async throws -> (items: [ExpenseResponse], nextCursor: String?)
    func searchExpenses(userId: UUID, filters: ExpenseSearchFilters, on db: any Database) async throws -> (items: [ExpenseResponse], nextCursor: String?)
    func createExpense(userId: UUID, request: ExpenseRequest, on db: any Database) async throws -> ExpenseResponse
    /// Creates the month's budget snapshot only if none exists (non-destructive).
    /// Exposed so bulk importers can pre-create snapshots once per month.
    func ensureSnapshotExists(userId: UUID, monthStart: Date, on db: any Database) async throws
    func updateExpense(userId: UUID, expenseId: UUID, request: ExpenseRequest, on db: any Database) async throws -> ExpenseResponse
    func deleteExpense(userId: UUID, expenseId: UUID, on db: any Database) async throws

    // Categories
    func getCategories(userId: UUID, on db: any Database) async throws -> [ExpenseCategoryResponse]
    func createCategory(userId: UUID, request: ExpenseCategoryRequest, on db: any Database) async throws -> ExpenseCategoryResponse
    func deleteCategory(userId: UUID, categoryId: UUID, on db: any Database) async throws

    // Recurring Templates
    func getRecurringTemplates(userId: UUID, on db: any Database) async throws -> [RecurringTemplateResponse]
    func createRecurringTemplate(userId: UUID, request: RecurringTemplateRequest, on db: any Database) async throws -> RecurringTemplateResponse
    func updateRecurringTemplate(userId: UUID, templateId: UUID, request: RecurringTemplateRequest, on db: any Database) async throws -> RecurringTemplateResponse
    func deleteRecurringTemplate(userId: UUID, templateId: UUID, on db: any Database) async throws

    // Reports
    func getMonthlyReports(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [BudgetMonthSummaryResponse]
    func getYearlyReports(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [BudgetYearSummaryResponse]
    func getPillarPlanningSummaries(userId: UUID, monthStart: Date, on db: any Database) async throws -> [PillarPlanningSummaryResponse]
}

final class DefaultExpensesService: ExpensesService {
    let req: Request

    init(req: Request) {
        self.req = req
    }

    private func symbol(for pillar: BudgetPillar) -> String {
        if pillar == .fundamentals {
            return "house.fill"
        }
        if pillar == .futureYou {
            return "chart.line.uptrend.xyaxis"
        }
        if pillar == .fun {
            return "sparkles"
        }
        return "square.stack.3d.up.fill"
    }

    private func defaultTargetShare(for pillar: BudgetPillar) -> Double {
        if pillar == .fundamentals {
            return 0.50
        }
        if pillar == .futureYou {
            return 0.20
        }
        if pillar == .fun {
            return 0.30
        }
        return 0
    }

    // MARK: - Formatters

    private func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func evaluateDriftBestEffort(userId: UUID, monthStart: Date) async {
        do {
            try await BudgetDriftEvaluator(req: req).evaluate(userId: userId, monthStart: monthStart, notify: true)
        } catch {
            req.logger.warning(
                "budget drift evaluation failed userId=\(userId.uuidString) month=\(formatDate(monthStart)) error=\(error.localizedDescription)"
            )
        }
    }

    private func formatISODate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func normalizeBudgetKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizePartnerName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeSplit(
        splitMode: ExpenseSplitMode,
        userSharePercent: Double
    ) throws -> (ExpenseSplitMode, Double) {
        guard (0 ... 100).contains(userSharePercent) else {
            throw Abort(.badRequest, reason: "userSharePercent must be between 0 and 100.")
        }

        switch splitMode {
        case .personal:
            return (.personal, 100)
        case .shared:
            return (.shared, userSharePercent)
        }
    }

    private func validateBudgetSettings(
        currencyCode: String?,
        categoryThreshold: Double?,
        totalThreshold: Double?
    ) throws {
        if let currencyCode {
            guard currencyCode.count == 3, currencyCode.allSatisfy(\.isLetter) else {
                throw Abort(.badRequest, reason: "currencyCode must be a three-letter ISO 4217 code.")
            }
        }
        for value in [categoryThreshold, totalThreshold].compactMap(\.self) {
            guard value.isFinite, (0 ... 1000).contains(value) else {
                throw Abort(.badRequest, reason: "Drift thresholds must be between 0 and 1000.")
            }
        }
    }

    private func validatePlanItemRequest(
        _ request: BudgetPlanItemRequest,
        userId: UUID,
        on db: any Database
    ) async throws {
        guard request.plannedAmount.isFinite, request.plannedAmount >= 0 else {
            throw Abort(.badRequest, reason: "plannedAmount must be finite and non-negative.")
        }
        if request.targetType == .percentageIncome {
            guard let percentage = request.incomePercentage,
                  percentage.isFinite,
                  (0 ... 1000).contains(percentage)
            else {
                throw Abort(.badRequest, reason: "incomePercentage is required and must be between 0 and 1000.")
            }
        }
        if let threshold = request.thresholdOverride,
           !threshold.isFinite || !(0 ... 1000).contains(threshold)
        {
            throw Abort(.badRequest, reason: "thresholdOverride must be between 0 and 1000.")
        }
        if let rawCategory = request.categoryId {
            guard let categoryId = UUID(uuidString: rawCategory),
                  let category = try await ExpenseCategory.find(categoryId, on: db),
                  category.$user.id == userId
            else {
                throw Abort(.badRequest, reason: "Invalid categoryId.")
            }
        }
        if let rawGoal = request.destinationFinancialGoalId {
            guard let goalId = UUID(uuidString: rawGoal),
                  try await FinancialGoalModel.owned(by: userId, on: db).filter(\.$id == goalId).first() != nil
            else {
                throw Abort(.badRequest, reason: "Invalid destinationFinancialGoalId.")
            }
        }
        if let rawPortfolio = request.destinationPortfolioListId {
            guard let portfolioId = UUID(uuidString: rawPortfolio),
                  try await PortfolioList.query(on: db)
                  .filter(\.$id == portfolioId)
                  .filter(\.$userId == userId)
                  .first() != nil
            else {
                throw Abort(.badRequest, reason: "Invalid destinationPortfolioListId.")
            }
        }
    }

    private func userPortion(of amount: Double, splitMode: ExpenseSplitMode, userSharePercent: Double) -> Double {
        switch splitMode {
        case .personal:
            amount
        case .shared:
            amount * (userSharePercent / 100)
        }
    }

    private func partnerPortion(of amount: Double, splitMode: ExpenseSplitMode, userSharePercent: Double) -> Double {
        amount - userPortion(of: amount, splitMode: splitMode, userSharePercent: userSharePercent)
    }

    private func requireUser(userId: UUID, on db: any Database) async throws -> User {
        guard let user = try await User.find(userId, on: db) else {
            throw Abort(.notFound, reason: "User not found.")
        }
        try user.hydrateProtectedFields(using: req.userPIIEncryptionService)
        return user
    }

    // MARK: - Household Partner

    func getHouseholdPartner(userId: UUID, on db: any Database) async throws -> HouseholdPartnerProfileResponse {
        let user = try await requireUser(userId: userId, on: db)
        return HouseholdPartnerProfileResponse(
            displayName: normalizePartnerName(user.householdPartnerDisplayName),
            defaultUserSharePercent: user.householdDefaultUserSharePercent
        )
    }

    func updateHouseholdPartner(userId: UUID, request: HouseholdPartnerProfileRequest, on db: any Database) async throws -> HouseholdPartnerProfileResponse {
        let user = try await requireUser(userId: userId, on: db)
        user.householdPartnerDisplayName = normalizePartnerName(request.displayName)
        user.householdDefaultUserSharePercent = try normalizeDefaultSharePercent(request.defaultUserSharePercent)
        try user.encryptProtectedFields(using: req.userPIIEncryptionService)
        try await user.update(on: db)
        try user.hydrateProtectedFields(using: req.userPIIEncryptionService)
        return HouseholdPartnerProfileResponse(
            displayName: user.householdPartnerDisplayName,
            defaultUserSharePercent: user.householdDefaultUserSharePercent
        )
    }

    /// Validates the household default share. Rejects out-of-range values rather
    /// than clamping, matching `normalizeSplit`. A nil clears the default, which
    /// is distinct from setting it to zero.
    private func normalizeDefaultSharePercent(_ value: Double?) throws -> Double? {
        guard let value else { return nil }
        guard (0 ... 100).contains(value) else {
            throw Abort(.badRequest, reason: "defaultUserSharePercent must be between 0 and 100.")
        }
        return value
    }

    // MARK: - Snapshots

    func getSnapshots(userId: UUID, year: Int?, month: Int?, on db: any Database) async throws -> [BudgetSnapshotResponse] {
        let query = BudgetSnapshot.query(on: db).filter(\.$user.$id == userId)

        // Load items along with snapshot if needed, but the endpoint might just be snapshots.
        // Let's just return snapshots for now. We can load them if requested, but DTO doesn't include items.
        let snapshots = try await query.all()

        // Client filtering by year/month if provided (since monthStart is a Date, easier to filter in Swift or via Postgres extract)
        // Filtering in Swift for simplicity unless data is huge
        var filtered = snapshots
        if let year {
            filtered = filtered.filter { Calendar.current.component(.year, from: $0.monthStart) == year }
        }
        if let month {
            filtered = filtered.filter { Calendar.current.component(.month, from: $0.monthStart) == month }
        }

        return filtered.map { mapSnapshot($0) }.sorted { $0.monthStart < $1.monthStart }
    }

    func createBudgetSnapshot(userId: UUID, request: BudgetSnapshotRequest, on db: any Database) async throws -> BudgetSnapshotResponse {
        try validateBudgetSettings(
            currencyCode: request.currencyCode,
            categoryThreshold: request.categoryDriftThreshold,
            totalThreshold: request.totalDriftThreshold
        )
        guard request.netSalary.isFinite, request.netSalary >= 0 else {
            throw Abort(.badRequest, reason: "netSalary must be finite and non-negative.")
        }
        guard let rawDate = parseDate(request.monthStart) else {
            throw Abort(.badRequest, reason: "Invalid monthStart format. Expected YYYY-MM-DD.")
        }

        // Normalize to the first day of the month to avoid timezone shifts causing day-boundary issues
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents([.year, .month], from: rawDate)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)

        guard let monthStart = calendar.date(from: components) else {
            throw Abort(.internalServerError, reason: "Could not normalize monthStart.")
        }

        let existing = try await findSnapshot(userId: userId, matchingMonth: monthStart, on: db)

        if let snapshot = existing {
            // Update existing
            snapshot.monthStart = monthStart // Update to normalized date if it was different
            snapshot.netSalary = request.netSalary
            snapshot.targetShares = request.targetShares
            applyBudgetSettings(request, to: snapshot)
            snapshot.revision += 1
            try await snapshot.update(on: db)
            return mapSnapshot(snapshot)
        } else {
            // Create new
            let snapshot = BudgetSnapshot(
                userID: userId,
                monthStart: monthStart,
                netSalary: request.netSalary,
                targetShares: request.targetShares,
                currencyCode: request.currencyCode?.uppercased() ?? "USD",
                categoryDriftThreshold: request.categoryDriftThreshold ?? 15,
                totalDriftThreshold: request.totalDriftThreshold ?? 10,
                alertsEnabled: request.alertsEnabled ?? true,
                alertOnUnbudgeted: request.alertOnUnbudgeted ?? true
            )
            do {
                try await snapshot.create(on: db)
                return mapSnapshot(snapshot)
            } catch {
                // A concurrent expense import may have created this month's
                // snapshot after the lookup. Treat the unique row as the winner.
                if let concurrent = try await findSnapshot(userId: userId, matchingMonth: monthStart, on: db) {
                    concurrent.netSalary = request.netSalary
                    concurrent.targetShares = request.targetShares
                    applyBudgetSettings(request, to: concurrent)
                    concurrent.revision += 1
                    try await concurrent.update(on: db)
                    return mapSnapshot(concurrent)
                }
                throw error
            }
        }
    }

    func updateSnapshot(userId: UUID, snapshotId: UUID, request: BudgetSnapshotRequest, on db: any Database) async throws -> BudgetSnapshotResponse {
        try validateBudgetSettings(
            currencyCode: request.currencyCode,
            categoryThreshold: request.categoryDriftThreshold,
            totalThreshold: request.totalDriftThreshold
        )
        guard let snapshot = try await BudgetSnapshot.find(snapshotId, on: db) else {
            throw Abort(.notFound)
        }
        guard snapshot.$user.id == userId else {
            throw Abort(.forbidden)
        }
        guard let rawDate = parseDate(request.monthStart) else {
            throw Abort(.badRequest, reason: "Invalid monthStart format. Expected YYYY-MM-DD.")
        }

        // Normalize
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents([.year, .month], from: rawDate)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)

        guard let monthStart = calendar.date(from: components) else {
            throw Abort(.internalServerError, reason: "Could not normalize monthStart.")
        }

        snapshot.monthStart = monthStart
        snapshot.netSalary = request.netSalary
        snapshot.targetShares = request.targetShares
        applyBudgetSettings(request, to: snapshot)
        snapshot.revision += 1
        try await snapshot.update(on: db)
        return mapSnapshot(snapshot)
    }

    func deleteSnapshot(userId: UUID, snapshotId: UUID, on db: any Database) async throws {
        guard let snapshot = try await BudgetSnapshot.find(snapshotId, on: db) else {
            throw Abort(.notFound)
        }
        guard snapshot.$user.id == userId else {
            throw Abort(.forbidden)
        }
        try await snapshot.delete(on: db)
    }

    // MARK: - Plan Items

    func getAllPlanItems(userId: UUID, on db: any Database) async throws -> [BudgetPlanItemResponse] {
        let items = try await BudgetPlanItem.query(on: db)
            .filter(\.$user.$id == userId)
            .all()

        return items.map { mapPlanItem($0) }
    }

    func getPlanItems(userId: UUID, snapshotId: UUID, on db: any Database) async throws -> [BudgetPlanItemResponse] {
        let items = try await BudgetPlanItem.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$snapshot.$id == snapshotId)
            .all()

        return items.map { mapPlanItem($0) }
    }

    func createPlanItem(userId: UUID, request: BudgetPlanItemRequest, on db: any Database) async throws -> BudgetPlanItemResponse {
        try await validatePlanItemRequest(request, userId: userId, on: db)
        guard let snapshotId = UUID(uuidString: request.snapshotId) else {
            throw Abort(.badRequest, reason: "Invalid snapshotId.")
        }
        // Verify snapshot belongs to user
        guard let snapshot = try await BudgetSnapshot.find(snapshotId, on: db), snapshot.$user.id == userId else {
            throw Abort(.notFound, reason: "Snapshot not found.")
        }

        let split = try normalizeSplit(splitMode: request.splitMode, userSharePercent: request.userSharePercent)

        let item = BudgetPlanItem(
            snapshotID: snapshotId,
            userID: userId,
            title: request.title,
            plannedAmount: request.targetType == .percentageIncome
                ? snapshot.netSalary * (request.incomePercentage ?? 0) / 100
                : request.plannedAmount,
            pillar: request.pillar,
            splitMode: split.0,
            userSharePercent: split.1,
            targetType: request.targetType,
            incomePercentage: request.incomePercentage,
            thresholdOverride: request.thresholdOverride,
            allocationKind: request.allocationKind,
            reallocationEligible: request.reallocationEligible,
            destinationFinancialGoalId: request.destinationFinancialGoalId.flatMap(UUID.init(uuidString:)),
            destinationPortfolioListId: request.destinationPortfolioListId.flatMap(UUID.init(uuidString:))
        )
        if let catIdStr = request.categoryId, let catId = UUID(uuidString: catIdStr) {
            item.$category.id = catId
        }
        try await item.create(on: db)
        snapshot.revision += 1
        try await snapshot.update(on: db)
        return mapPlanItem(item)
    }

    func updatePlanItem(userId: UUID, itemId: UUID, request: BudgetPlanItemRequest, on db: any Database) async throws -> BudgetPlanItemResponse {
        try await validatePlanItemRequest(request, userId: userId, on: db)
        guard let item = try await BudgetPlanItem.find(itemId, on: db) else {
            throw Abort(.notFound)
        }
        guard item.$user.id == userId else {
            throw Abort(.forbidden)
        }

        let split = try normalizeSplit(splitMode: request.splitMode, userSharePercent: request.userSharePercent)
        item.title = request.title
        guard let snapshot = try await BudgetSnapshot.find(item.$snapshot.id, on: db) else {
            throw Abort(.notFound, reason: "Snapshot not found.")
        }
        item.plannedAmount = request.targetType == .percentageIncome
            ? snapshot.netSalary * (request.incomePercentage ?? 0) / 100
            : request.plannedAmount
        item.pillar = request.pillar
        item.splitMode = split.0
        item.userSharePercent = split.1
        item.targetType = request.targetType
        item.incomePercentage = request.incomePercentage
        item.thresholdOverride = request.thresholdOverride
        item.allocationKind = request.allocationKind
        item.reallocationEligible = request.reallocationEligible
        item.destinationFinancialGoalId = request.destinationFinancialGoalId.flatMap(UUID.init(uuidString:))
        item.destinationPortfolioListId = request.destinationPortfolioListId.flatMap(UUID.init(uuidString:))
        item.$category.id = request.categoryId.flatMap { UUID(uuidString: $0) }
        try await item.update(on: db)
        snapshot.revision += 1
        try await snapshot.update(on: db)
        return mapPlanItem(item)
    }

    func deletePlanItem(userId: UUID, itemId: UUID, on db: any Database) async throws {
        guard let item = try await BudgetPlanItem.find(itemId, on: db) else {
            throw Abort(.notFound)
        }
        guard item.$user.id == userId else {
            throw Abort(.forbidden)
        }
        let snapshotId = item.$snapshot.id
        try await item.delete(on: db)
        if let snapshot = try await BudgetSnapshot.find(snapshotId, on: db) {
            snapshot.revision += 1
            try await snapshot.update(on: db)
        }
    }

    // MARK: - Expenses

    func getExpenses(userId: UUID, from: Date?, to: Date?, limit: Int, cursor: Date?, on db: any Database) async throws -> (items: [ExpenseResponse], nextCursor: String?) {
        var query = Expense.query(on: db).filter(\.$user.$id == userId)
        if let from {
            query = query.filter(\.$occurredOn >= from)
        }
        if let to {
            query = query.filter(\.$occurredOn <= to)
        }
        if let cursor {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            // occurred_on is a DATE column. Move to the preceding calendar day
            // before binding so timezone conversion cannot re-include the cursor day.
            let precedingDay = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            query = query.filter(\.$occurredOn <= precedingDay)
        }

        let maxLimit = 200
        let fetchLimit = limit + 1
        let expenses = try await query.sort(\.$occurredOn, .descending).limit(fetchLimit).all()
        if expenses.count > limit, limit < maxLimit {
            let pageExpenses = Array(expenses.prefix(limit))
            let items = pageExpenses.map { mapExpense($0) }
            guard let last = pageExpenses.last else {
                return (items, nil)
            }
            let nextCursor = formatISODate(last.occurredOn)
            return (items, nextCursor)
        } else {
            let items = Array(expenses.prefix(limit)).map { mapExpense($0) }
            return (items, nil)
        }
    }

    func searchExpenses(
        userId: UUID,
        filters: ExpenseSearchFilters,
        on db: any Database
    ) async throws -> (items: [ExpenseResponse], nextCursor: String?) {
        var query = Expense.query(on: db).filter(\.$user.$id == userId)
        if let from = filters.from {
            query = query.filter(\.$occurredOn >= from)
        }
        if let to = filters.to {
            query = query.filter(\.$occurredOn <= to)
        }
        if let categoryId = filters.categoryId {
            query = query.filter(\.$category.$id == categoryId)
        }
        if let pillar = filters.pillar {
            query = query.filter(\.$pillar == pillar)
        }
        if let cursor = filters.cursor {
            query = query.filter(\.$occurredOn < cursor)
        }
        var expenses = try await query.sort(\.$occurredOn, .descending).limit(1000).all()
        if let search = filters.query?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            expenses = expenses.filter {
                $0.title.localizedCaseInsensitiveContains(search) || ($0.notes?.localizedCaseInsensitiveContains(search) ?? false)
            }
        }
        let page = Array(expenses.prefix(filters.limit + 1))
        let visible = Array(page.prefix(filters.limit))
        return (visible.map(mapExpense), page.count > filters.limit ? visible.last.map { formatISODate($0.occurredOn) } : nil)
    }

    func createExpense(userId: UUID, request: ExpenseRequest, on db: any Database) async throws -> ExpenseResponse {
        guard request.amount.isFinite, request.amount >= 0 else {
            throw Abort(.badRequest, reason: "amount must be finite and non-negative.")
        }
        guard let occurredOn = parseDate(request.occurredOn) else {
            throw Abort(.badRequest, reason: "Invalid occurredOn format. Expected YYYY-MM-DD.")
        }
        let monthStart = normalizedMonthStart(for: occurredOn)
        try await ensureSnapshotExists(
            userId: userId,
            monthStart: monthStart,
            on: db
        )

        var linkedId: UUID?
        if let reqLinkedId = request.linkedPlanItemId {
            guard let parsed = UUID(uuidString: reqLinkedId) else {
                throw Abort(.badRequest, reason: "Invalid linkedPlanItemId.")
            }
            // Verify plan item belongs to user
            guard let planItem = try await BudgetPlanItem.find(parsed, on: db), planItem.$user.id == userId else {
                throw Abort(.badRequest, reason: "Invalid linkedPlanItemId.")
            }
            linkedId = parsed
        }

        let split = try normalizeSplit(splitMode: request.splitMode, userSharePercent: request.userSharePercent)

        let expense = Expense(
            userID: userId,
            title: request.title,
            amount: request.amount,
            pillar: request.pillar,
            occurredOn: occurredOn,
            linkedPlanItemID: linkedId,
            splitMode: split.0,
            userSharePercent: split.1
        )
        if let catIdStr = request.categoryId {
            guard let catId = UUID(uuidString: catIdStr),
                  let category = try await ExpenseCategory.find(catId, on: db),
                  category.$user.id == userId
            else { throw Abort(.badRequest, reason: "Invalid categoryId.") }
            expense.$category.id = catId
        }
        if let foreignAmount = request.foreignAmount {
            guard let rate = request.exchangeRate, rate > 0 else {
                throw Abort(.badRequest, reason: "exchangeRate must be > 0 when foreignAmount is provided.")
            }
            expense.foreignAmount = foreignAmount
            expense.foreignCurrency = request.foreignCurrency
            expense.exchangeRate = rate
        }
        expense.notes = request.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        expense.receiptMetadata = request.receiptMetadata
        try await expense.create(on: db)

        // Record activity
        try? await req.userActivityService.recordActivity(
            userId: userId,
            type: .expenseRecorded,
            title: "Expense Added",
            subtitle: request.title,
            amount: request.amount,
            isGrowth: false,
            symbol: symbol(for: request.pillar),
            on: db
        )

        await evaluateDriftBestEffort(userId: userId, monthStart: monthStart)

        await req.reconcileBadges(userId: userId, on: db)

        return mapExpense(expense)
    }

    func updateExpense(userId: UUID, expenseId: UUID, request: ExpenseRequest, on db: any Database) async throws -> ExpenseResponse {
        guard let expense = try await Expense.find(expenseId, on: db) else {
            throw Abort(.notFound)
        }
        guard expense.$user.id == userId else {
            throw Abort(.forbidden)
        }
        let previousMonthStart = normalizedMonthStart(for: expense.occurredOn)
        guard let occurredOn = parseDate(request.occurredOn) else {
            throw Abort(.badRequest, reason: "Invalid occurredOn format. Expected YYYY-MM-DD.")
        }

        var linkedId: UUID?
        if let reqLinkedId = request.linkedPlanItemId {
            guard let parsed = UUID(uuidString: reqLinkedId) else {
                throw Abort(.badRequest, reason: "Invalid linkedPlanItemId.")
            }
            guard let planItem = try await BudgetPlanItem.find(parsed, on: db), planItem.$user.id == userId else {
                throw Abort(.badRequest, reason: "Invalid linkedPlanItemId.")
            }
            linkedId = parsed
        }

        let split = try normalizeSplit(splitMode: request.splitMode, userSharePercent: request.userSharePercent)

        expense.title = request.title
        expense.amount = request.amount
        expense.pillar = request.pillar
        expense.occurredOn = occurredOn
        expense.splitMode = split.0
        expense.userSharePercent = split.1
        expense.$linkedPlanItem.id = linkedId
        if let rawCategory = request.categoryId {
            guard let categoryId = UUID(uuidString: rawCategory),
                  let category = try await ExpenseCategory.find(categoryId, on: db),
                  category.$user.id == userId
            else { throw Abort(.badRequest, reason: "Invalid categoryId.") }
            expense.$category.id = categoryId
        } else {
            expense.$category.id = nil
        }
        if let foreignAmount = request.foreignAmount {
            guard let rate = request.exchangeRate, rate > 0 else {
                throw Abort(.badRequest, reason: "exchangeRate must be > 0 when foreignAmount is provided.")
            }
            expense.foreignAmount = foreignAmount
            expense.foreignCurrency = request.foreignCurrency
            expense.exchangeRate = rate
        } else {
            expense.foreignAmount = nil
            expense.foreignCurrency = nil
            expense.exchangeRate = nil
        }
        expense.notes = request.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        expense.receiptMetadata = request.receiptMetadata
        try await expense.update(on: db)
        let currentMonthStart = normalizedMonthStart(for: occurredOn)
        await evaluateDriftBestEffort(userId: userId, monthStart: previousMonthStart)
        if currentMonthStart != previousMonthStart {
            await evaluateDriftBestEffort(userId: userId, monthStart: currentMonthStart)
        }

        // Record activity
        try? await req.userActivityService.recordActivity(
            userId: userId,
            type: .expenseUpdated,
            title: "Expense Updated",
            subtitle: request.title,
            amount: request.amount,
            isGrowth: false,
            symbol: symbol(for: request.pillar),
            on: db
        )

        await req.reconcileBadges(userId: userId, on: db)

        return mapExpense(expense)
    }

    func deleteExpense(userId: UUID, expenseId: UUID, on db: any Database) async throws {
        guard let expense = try await Expense.find(expenseId, on: db) else {
            throw Abort(.notFound)
        }
        guard expense.$user.id == userId else {
            throw Abort(.forbidden)
        }
        let monthStart = normalizedMonthStart(for: expense.occurredOn)
        try await expense.delete(on: db)
        await evaluateDriftBestEffort(userId: userId, monthStart: monthStart)
        await req.reconcileBadges(userId: userId, on: db)
    }

    // MARK: - Categories

    private static let defaultCategories: [(name: String, pillar: BudgetPillar)] = [
        ("Groceries", .fundamentals), ("Rent", .fundamentals), ("Mortgage", .fundamentals),
        ("Utilities", .fundamentals), ("Transport", .fundamentals), ("Insurance", .fundamentals),
        ("Phone Bill", .fundamentals),
        ("Savings", .futureYou), ("Investments", .futureYou), ("Emergency Fund", .futureYou),
        ("Dining Out", .fun), ("Entertainment", .fun), ("Travel", .fun), ("Subscriptions", .fun),
    ]

    func getCategories(userId: UUID, on db: any Database) async throws -> [ExpenseCategoryResponse] {
        let existing = try await ExpenseCategory.query(on: db).filter(\.$user.$id == userId).all()
        if existing.isEmpty {
            // Seed defaults on first access
            let defaults = Self.defaultCategories.map {
                ExpenseCategory(userID: userId, name: $0.name, pillar: $0.pillar, isDefault: true)
            }
            try await defaults.create(on: db)
            return defaults.map { mapCategory($0) }
        }
        return existing.sorted { $0.name < $1.name }.map { mapCategory($0) }
    }

    func createCategory(userId: UUID, request: ExpenseCategoryRequest, on db: any Database) async throws -> ExpenseCategoryResponse {
        let pillar = request.pillar
        let category = ExpenseCategory(userID: userId, name: request.name, pillar: pillar, isDefault: false)
        try await category.create(on: db)
        return mapCategory(category)
    }

    func deleteCategory(userId: UUID, categoryId: UUID, on db: any Database) async throws {
        guard let category = try await ExpenseCategory.find(categoryId, on: db) else {
            throw Abort(.notFound)
        }
        guard category.$user.id == userId else { throw Abort(.forbidden) }
        guard !category.isDefault else { throw Abort(.badRequest, reason: "Cannot delete default categories.") }
        try await category.delete(on: db)
    }

    // MARK: - Recurring Templates

    func getRecurringTemplates(userId: UUID, on db: any Database) async throws -> [RecurringTemplateResponse] {
        let templates = try await RecurringTemplate.query(on: db).filter(\.$user.$id == userId).all()
        return templates.map { mapRecurringTemplate($0) }
    }

    func createRecurringTemplate(userId: UUID, request: RecurringTemplateRequest, on db: any Database) async throws -> RecurringTemplateResponse {
        let frequency = request.frequency
        let categoryID = request.categoryId.flatMap { UUID(uuidString: $0) }
        let split = try normalizeSplit(splitMode: request.splitMode, userSharePercent: request.userSharePercent)
        let template = RecurringTemplate(
            userID: userId,
            title: request.title,
            amount: request.amount,
            pillar: request.pillar,
            categoryID: categoryID,
            frequency: frequency,
            splitMode: split.0,
            userSharePercent: split.1
        )
        try await template.create(on: db)
        return mapRecurringTemplate(template)
    }

    func updateRecurringTemplate(userId: UUID, templateId: UUID, request: RecurringTemplateRequest, on db: any Database) async throws -> RecurringTemplateResponse {
        guard let template = try await RecurringTemplate.find(templateId, on: db) else {
            throw Abort(.notFound)
        }
        guard template.$user.id == userId else { throw Abort(.forbidden) }
        let split = try normalizeSplit(splitMode: request.splitMode, userSharePercent: request.userSharePercent)
        template.title = request.title
        template.amount = request.amount
        template.pillar = request.pillar
        template.$category.id = request.categoryId.flatMap { UUID(uuidString: $0) }
        template.frequency = request.frequency.rawValue
        template.splitMode = split.0
        template.userSharePercent = split.1
        try await template.update(on: db)
        return mapRecurringTemplate(template)
    }

    func deleteRecurringTemplate(userId: UUID, templateId: UUID, on db: any Database) async throws {
        guard let template = try await RecurringTemplate.find(templateId, on: db) else {
            throw Abort(.notFound)
        }
        guard template.$user.id == userId else { throw Abort(.forbidden) }
        try await template.delete(on: db)
    }

    // MARK: - Reports

    func getMonthlyReports(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [BudgetMonthSummaryResponse] {
        let itemsQuery = BudgetPlanItem.query(on: db).filter(\.$user.$id == userId)
        // PostgreSQL DATE columns do not compare reliably with Swift Date
        // parameters across every configured timezone, so the exact boundary
        // is still applied to decoded values below. The SQL predicate is
        // widened by a day on each side: it cannot exclude a row the exact
        // filter would keep, and it turns "load every row this user ever
        // wrote" into a bounded range scan on (user_id, occurred_on).
        let widenedFrom = from.map { $0.addingTimeInterval(-86400) }
        let widenedTo = to.map { $0.addingTimeInterval(86400) }
        var snapshotsQuery = BudgetSnapshot.query(on: db).filter(\.$user.$id == userId)
        var expensesQuery = Expense.query(on: db).filter(\.$user.$id == userId)
        if let widenedFrom {
            snapshotsQuery = snapshotsQuery.filter(\.$monthStart >= widenedFrom)
            expensesQuery = expensesQuery.filter(\.$occurredOn >= widenedFrom)
        }
        if let widenedTo {
            snapshotsQuery = snapshotsQuery.filter(\.$monthStart <= widenedTo)
            expensesQuery = expensesQuery.filter(\.$occurredOn <= widenedTo)
        }
        let allSnapshots = try await snapshotsQuery.all()
        let items = try await itemsQuery.all()
        let allExpenses = try await expensesQuery.all()

        let snapshots = allSnapshots.filter { snapshot in
            (from.map { snapshot.monthStart >= $0 } ?? true)
                && (to.map { snapshot.monthStart <= $0 } ?? true)
        }
        let expenses = allExpenses.filter { expense in
            (from.map { expense.occurredOn >= $0 } ?? true)
                && (to.map { expense.occurredOn <= $0 } ?? true)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Group items by snapshot
        var itemsBySnapshot: [UUID: [BudgetPlanItem]] = [:]
        for item in items {
            let snapshotId = item.$snapshot.id
            itemsBySnapshot[snapshotId, default: []].append(item)
        }

        // Group expenses by month start date
        var expensesByMonth: [Date: [Expense]] = [:]
        for expense in expenses {
            let date = calendar.date(from: calendar.dateComponents([.year, .month], from: expense.occurredOn)) ?? expense.occurredOn
            expensesByMonth[date, default: []].append(expense)
        }

        var summaries: [BudgetMonthSummaryResponse] = []

        for snapshot in snapshots.sorted(by: { $0.monthStart < $1.monthStart }) {
            let monthStart = normalizedMonthStart(for: snapshot.monthStart)

            var snapshotItems: [BudgetPlanItem] = []
            if let id = snapshot.id {
                snapshotItems = itemsBySnapshot[id] ?? []
            }

            let monthExpenses = expensesByMonth[monthStart] ?? []

            var plannedTotal: Double = 0
            for item in snapshotItems {
                plannedTotal += item.plannedAmount
            }

            var actualTotal: Double = 0
            for expense in monthExpenses {
                actualTotal += expense.amount
            }

            var myPlannedTotal: Double = 0
            var partnerPlannedTotal: Double = 0
            for item in snapshotItems {
                myPlannedTotal += userPortion(
                    of: item.plannedAmount,
                    splitMode: item.splitMode,
                    userSharePercent: item.userSharePercent
                )
                partnerPlannedTotal += partnerPortion(
                    of: item.plannedAmount,
                    splitMode: item.splitMode,
                    userSharePercent: item.userSharePercent
                )
            }

            var myActualTotal: Double = 0
            var partnerActualTotal: Double = 0
            for expense in monthExpenses {
                myActualTotal += userPortion(
                    of: expense.amount,
                    splitMode: expense.splitMode,
                    userSharePercent: expense.userSharePercent
                )
                partnerActualTotal += partnerPortion(
                    of: expense.amount,
                    splitMode: expense.splitMode,
                    userSharePercent: expense.userSharePercent
                )
            }

            var pillarPlans: [String: Double] = [:]
            var pillarActuals: [String: Double] = [:]
            var myPillarPlans: [String: Double] = [:]
            var partnerPillarPlans: [String: Double] = [:]
            var myPillarActuals: [String: Double] = [:]
            var partnerPillarActuals: [String: Double] = [:]

            let pillars = resolvedPillars(
                snapshot: snapshot,
                items: snapshotItems,
                expenses: monthExpenses
            )

            for pillar in pillars {
                let itemsForPillar = snapshotItems.filter { $0.pillar == pillar }
                var plannedAmount: Double = 0
                var myPlannedAmount: Double = 0
                var partnerPlannedAmount: Double = 0
                for item in itemsForPillar {
                    plannedAmount += item.plannedAmount
                    myPlannedAmount += userPortion(
                        of: item.plannedAmount,
                        splitMode: item.splitMode,
                        userSharePercent: item.userSharePercent
                    )
                    partnerPlannedAmount += partnerPortion(
                        of: item.plannedAmount,
                        splitMode: item.splitMode,
                        userSharePercent: item.userSharePercent
                    )
                }
                pillarPlans[pillar.rawValue] = plannedAmount
                myPillarPlans[pillar.rawValue] = myPlannedAmount
                partnerPillarPlans[pillar.rawValue] = partnerPlannedAmount

                let expensesForPillar = monthExpenses.filter { $0.pillar == pillar }
                var actualAmount: Double = 0
                var myActualAmount: Double = 0
                var partnerActualAmount: Double = 0
                for expense in expensesForPillar {
                    actualAmount += expense.amount
                    myActualAmount += userPortion(
                        of: expense.amount,
                        splitMode: expense.splitMode,
                        userSharePercent: expense.userSharePercent
                    )
                    partnerActualAmount += partnerPortion(
                        of: expense.amount,
                        splitMode: expense.splitMode,
                        userSharePercent: expense.userSharePercent
                    )
                }
                pillarActuals[pillar.rawValue] = actualAmount
                myPillarActuals[pillar.rawValue] = myActualAmount
                partnerPillarActuals[pillar.rawValue] = partnerActualAmount
            }

            let summary = BudgetMonthSummaryResponse(
                monthStart: formatDate(monthStart),
                planned: plannedTotal,
                actual: actualTotal,
                salary: snapshot.netSalary,
                myPlanned: myPlannedTotal,
                partnerPlanned: partnerPlannedTotal,
                myActual: myActualTotal,
                partnerActual: partnerActualTotal,
                pillarActuals: pillarActuals,
                pillarPlans: pillarPlans,
                myPillarActuals: myPillarActuals,
                partnerPillarActuals: partnerPillarActuals,
                myPillarPlans: myPillarPlans,
                partnerPillarPlans: partnerPillarPlans
            )
            summaries.append(summary)
        }

        return summaries
    }

    func getYearlyReports(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [BudgetYearSummaryResponse] {
        let monthlyReports = try await getMonthlyReports(userId: userId, from: from, to: to, on: db)

        let groupedByYear = Dictionary(grouping: monthlyReports) { report in
            guard let date = parseDate(report.monthStart) else { return 0 }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar.component(.year, from: date)
        }

        var yearlySummaries: [BudgetYearSummaryResponse] = []
        for (year, reports) in groupedByYear where year != 0 {
            let planned = reports.reduce(0) { $0 + $1.planned }
            let actual = reports.reduce(0) { $0 + $1.actual }
            let salary = reports.reduce(0) { $0 + $1.salary }
            let myPlanned = reports.reduce(0) { $0 + $1.myPlanned }
            let partnerPlanned = reports.reduce(0) { $0 + $1.partnerPlanned }
            let myActual = reports.reduce(0) { $0 + $1.myActual }
            let partnerActual = reports.reduce(0) { $0 + $1.partnerActual }

            yearlySummaries.append(BudgetYearSummaryResponse(
                year: year,
                planned: planned,
                actual: actual,
                salary: salary,
                myPlanned: myPlanned,
                partnerPlanned: partnerPlanned,
                myActual: myActual,
                partnerActual: partnerActual
            ))
        }

        return yearlySummaries.sorted { $0.year < $1.year }
    }

    func getPillarPlanningSummaries(userId: UUID, monthStart: Date, on db: any Database) async throws -> [PillarPlanningSummaryResponse] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let normalizedMonthStart = normalizedMonthStart(for: monthStart)
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: normalizedMonthStart)

        let snapshots = try await BudgetSnapshot.query(on: db)
            .filter(\.$user.$id == userId)
            .all()
        guard let snapshot = snapshots.first(where: {
            calendar.isDate($0.monthStart, equalTo: normalizedMonthStart, toGranularity: .month)
        })
        else {
            return []
        }

        let snapshotID = try snapshot.requireID()
        let snapshotItems = try await BudgetPlanItem.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$snapshot.$id == snapshotID)
            .all()

        var expensesQuery = Expense.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$occurredOn >= normalizedMonthStart)

        if let nextMonthStart {
            expensesQuery = expensesQuery.filter(\.$occurredOn < nextMonthStart)
        }

        let monthExpenses = try await expensesQuery.all()

        let pillars = resolvedPillars(
            snapshot: snapshot,
            items: snapshotItems,
            expenses: monthExpenses
        )

        return pillars.map { pillar in
            let plannedItems = snapshotItems.filter { $0.pillar == pillar }
            let expensesForPillar = monthExpenses.filter { $0.pillar == pillar }
            let targetShare = snapshot.targetShares[pillar.rawValue] ?? defaultTargetShare(for: pillar)
            let plannedAmount = plannedItems.reduce(0) { $0 + $1.plannedAmount }
            let actualAmount = expensesForPillar.reduce(0) { $0 + $1.amount }
            let unplannedActualAmount = expensesForPillar
                .filter { expense in
                    if let linkedPlanItemID = expense.$linkedPlanItem.id {
                        return !plannedItems.contains(where: { $0.id == linkedPlanItemID })
                    }

                    let normalizedExpenseTitle = normalizeBudgetKey(expense.title)
                    return !plannedItems.contains {
                        normalizeBudgetKey($0.title) == normalizedExpenseTitle
                    }
                }
                .reduce(0) { $0 + $1.amount }

            return PillarPlanningSummaryResponse(
                pillar: pillar,
                targetAmount: snapshot.netSalary * targetShare,
                plannedAmount: plannedAmount,
                actualAmount: actualAmount,
                unplannedActualAmount: unplannedActualAmount
            )
        }
    }

    // MARK: - Mappers

    private func mapCategory(_ model: ExpenseCategory) -> ExpenseCategoryResponse {
        ExpenseCategoryResponse(
            id: model.id?.uuidString ?? "",
            name: model.name,
            pillar: model.pillar.flatMap { BudgetPillar(rawValue: $0) },
            isDefault: model.isDefault
        )
    }

    private func mapRecurringTemplate(_ model: RecurringTemplate) -> RecurringTemplateResponse {
        RecurringTemplateResponse(
            id: model.id?.uuidString ?? "",
            title: model.title,
            amount: model.amount,
            pillar: model.pillar,
            categoryId: model.$category.id?.uuidString,
            frequency: RecurringFrequency(rawValue: model.frequency) ?? .monthly,
            splitMode: model.splitMode,
            userSharePercent: model.userSharePercent,
            createdAt: model.createdAt.map { formatISODate($0) }
        )
    }

    private func mapSnapshot(_ model: BudgetSnapshot) -> BudgetSnapshotResponse {
        BudgetSnapshotResponse(
            id: model.id?.uuidString ?? "",
            monthStart: formatDate(model.monthStart),
            netSalary: model.netSalary,
            targetShares: model.targetShares,
            currencyCode: model.currencyCode,
            categoryDriftThreshold: model.categoryDriftThreshold,
            totalDriftThreshold: model.totalDriftThreshold,
            alertsEnabled: model.alertsEnabled,
            alertOnUnbudgeted: model.alertOnUnbudgeted,
            revision: model.revision,
            createdAt: model.createdAt.map { formatISODate($0) },
            updatedAt: model.updatedAt.map { formatISODate($0) }
        )
    }

    private func mapPlanItem(_ model: BudgetPlanItem) -> BudgetPlanItemResponse {
        BudgetPlanItemResponse(
            id: model.id?.uuidString ?? "",
            snapshotId: model.$snapshot.id.uuidString,
            title: model.title,
            plannedAmount: model.plannedAmount,
            pillar: model.pillar,
            categoryId: model.$category.id?.uuidString,
            splitMode: model.splitMode,
            userSharePercent: model.userSharePercent,
            targetType: model.targetType,
            incomePercentage: model.incomePercentage,
            thresholdOverride: model.thresholdOverride,
            allocationKind: model.allocationKind,
            reallocationEligible: model.reallocationEligible,
            destinationFinancialGoalId: model.destinationFinancialGoalId?.uuidString,
            destinationPortfolioListId: model.destinationPortfolioListId?.uuidString,
            createdAt: model.createdAt.map { formatISODate($0) },
            updatedAt: model.updatedAt.map { formatISODate($0) }
        )
    }

    private func mapExpense(_ model: Expense) -> ExpenseResponse {
        ExpenseResponse(
            id: model.id?.uuidString ?? "",
            title: model.title,
            amount: model.amount,
            pillar: model.pillar,
            occurredOn: formatDate(model.occurredOn),
            linkedPlanItemId: model.$linkedPlanItem.id?.uuidString,
            categoryId: model.$category.id?.uuidString,
            splitMode: model.splitMode,
            userSharePercent: model.userSharePercent,
            foreignAmount: model.foreignAmount,
            foreignCurrency: model.foreignCurrency,
            exchangeRate: model.exchangeRate,
            notes: model.notes,
            receiptMetadata: model.receiptMetadata,
            createdAt: model.createdAt.map { formatISODate($0) },
            updatedAt: model.updatedAt.map { formatISODate($0) }
        )
    }
}

private extension DefaultExpensesService {
    func applyBudgetSettings(_ request: BudgetSnapshotRequest, to snapshot: BudgetSnapshot) {
        if let currencyCode = request.currencyCode {
            snapshot.currencyCode = currencyCode.uppercased()
        }
        if let value = request.categoryDriftThreshold {
            snapshot.categoryDriftThreshold = value
        }
        if let value = request.totalDriftThreshold {
            snapshot.totalDriftThreshold = value
        }
        if let value = request.alertsEnabled {
            snapshot.alertsEnabled = value
        }
        if let value = request.alertOnUnbudgeted {
            snapshot.alertOnUnbudgeted = value
        }
    }
}

/// Not `private`: `ensureSnapshotExists` below satisfies an internal protocol
/// requirement, so this extension's members must be at least internal.
extension DefaultExpensesService {
    func sortedPillars(_ pillars: Set<BudgetPillar>) -> [BudgetPillar] {
        pillars.sorted { lhs, rhs in
            let lhsRank = pillarRank(lhs)
            let rhsRank = pillarRank(rhs)
            if lhsRank == rhsRank {
                return lhs.rawValue.localizedCaseInsensitiveCompare(rhs.rawValue) == .orderedAscending
            }
            return lhsRank < rhsRank
        }
    }

    func pillarRank(_ pillar: BudgetPillar) -> Int {
        if pillar == .fundamentals {
            return 0
        }
        if pillar == .futureYou {
            return 1
        }
        if pillar == .fun {
            return 2
        }
        return 3
    }

    func resolvedPillars(
        snapshot: BudgetSnapshot,
        items: [BudgetPlanItem],
        expenses: [Expense]
    ) -> [BudgetPillar] {
        var pillars = Set(BudgetPillar.allCases)

        for key in snapshot.targetShares.keys {
            if let pillar = BudgetPillar(rawValue: key) {
                pillars.insert(pillar)
            }
        }
        for item in items {
            pillars.insert(item.pillar)
        }
        for expense in expenses {
            pillars.insert(expense.pillar)
        }

        return sortedPillars(pillars)
    }

    func normalizedMonthStart(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return calendar.date(from: components) ?? date
    }

    func ensureSnapshotExists(
        userId: UUID,
        monthStart: Date,
        on db: any Database
    ) async throws {
        if try await findSnapshot(userId: userId, matchingMonth: monthStart, on: db) != nil {
            return
        }

        let template = try await BudgetSnapshot.query(on: db)
            .filter(\.$user.$id == userId)
            .sort(\.$monthStart, .descending)
            .first()

        let defaultShares = Dictionary(uniqueKeysWithValues: BudgetPillar.allCases.map { pillar in
            (pillar.rawValue, defaultTargetShare(for: pillar))
        })
        let targetShares = template?.targetShares ?? defaultShares
        let netSalary = template?.netSalary ?? 0

        let createdSnapshot = try await createBudgetSnapshot(
            userId: userId,
            request: BudgetSnapshotRequest(
                monthStart: formatDate(monthStart),
                netSalary: netSalary,
                targetShares: targetShares
            ),
            on: db
        )

        // Auto-carry forward subscription plan items from previous month
        if let templateSnapshotId = template?.id {
            let previousItems = try await BudgetPlanItem.query(on: db)
                .filter(\.$snapshot.$id == templateSnapshotId)
                .filter(\.$user.$id == userId)
                .with(\.$category)
                .all()

            let subscriptionItems = previousItems.filter { item in
                item.category?.name.lowercased() == "subscriptions"
            }

            for item in subscriptionItems {
                let newItem = BudgetPlanItem(
                    snapshotID: UUID(uuidString: createdSnapshot.id) ?? UUID(),
                    userID: userId,
                    title: item.title,
                    plannedAmount: item.plannedAmount,
                    pillar: item.pillar,
                    splitMode: item.splitMode,
                    userSharePercent: item.userSharePercent
                )
                newItem.$category.id = item.$category.id
                try await newItem.create(on: db)
            }
        }
    }

    func findSnapshot(
        userId: UUID,
        matchingMonth monthStart: Date,
        on db: any Database
    ) async throws -> BudgetSnapshot? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshots = try await BudgetSnapshot.query(on: db)
            .filter(\.$user.$id == userId)
            .all()
        return snapshots.first {
            calendar.isDate($0.monthStart, equalTo: monthStart, toGranularity: .month)
        }
    }

    private func evaluateBudgetAlerts(userId: UUID, monthStart: Date, db: any Database) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)

        var snapshotQuery = BudgetSnapshot.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$monthStart >= monthStart)
        if let nextMonthStart {
            snapshotQuery = snapshotQuery.filter(\.$monthStart < nextMonthStart)
        }

        guard let snapshot = try await snapshotQuery.first() else {
            return
        }

        guard snapshot.netSalary > 0 else {
            return
        }

        var expenseQuery = Expense.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$occurredOn >= monthStart)
        if let nextMonthStart {
            expenseQuery = expenseQuery.filter(\.$occurredOn < nextMonthStart)
        }
        let expenses = try await expenseQuery.all()

        let totalExpenses = expenses.reduce(0) { sum, expense in
            let effectiveAmount = expense.splitMode == .shared ? (expense.amount * expense.userSharePercent / 100) : expense.amount
            return sum + effectiveAmount
        }

        let remainingPercentage = ((snapshot.netSalary - totalExpenses) / snapshot.netSalary) * 100

        var newThreshold: Int? = nil
        if remainingPercentage <= 10 {
            newThreshold = 10
        } else if remainingPercentage <= 15 {
            newThreshold = 15
        } else if remainingPercentage <= 20 {
            newThreshold = 20
        }

        guard let threshold = newThreshold else {
            return
        }

        let lastThreshold = snapshot.lastBudgetAlertThreshold ?? 100

        if threshold < lastThreshold {
            snapshot.lastBudgetAlertThreshold = threshold
            try await snapshot.update(on: db)

            let devices = try await PushDevice.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$isActive == true)
                .all()

            let remainingAmount = snapshot.netSalary - totalExpenses

            let snapshotId = try snapshot.requireID()
            _ = try await NotificationEventPublisher.publish(
                userId: userId,
                kind: .budget,
                deduplicationKey: "budget:\(snapshotId.uuidString):\(threshold)",
                title: "Budget threshold reached",
                body: "\(threshold)% of this month's budget remains.",
                deepLink: "norviq://expenses",
                payload: ["snapshot_id": snapshotId.uuidString, "threshold": String(threshold)],
                on: db
            )

            _ = await req.application.pushNotificationSender.sendBudgetAlert(
                snapshot: snapshot,
                threshold: threshold,
                remainingAmount: remainingAmount,
                devices: devices,
                req: req
            )
        }
    }
}
