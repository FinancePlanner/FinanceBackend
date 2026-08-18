import Fluent
import Foundation
import StockPlanShared
import Vapor

struct BudgetingEngineService {
    let req: Request

    func dashboard(userId: UUID, snapshotId: UUID, on database: (any Database)? = nil) async throws -> BudgetDriftDashboard {
        let db = database ?? req.db
        guard let snapshot = try await BudgetSnapshot.query(on: db)
            .filter(\.$id == snapshotId)
            .filter(\.$user.$id == userId)
            .first()
        else { throw Abort(.notFound) }

        let items = try await BudgetPlanItem.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$snapshot.$id == snapshotId)
            .all()
        let range = monthRange(containing: snapshot.monthStart)
        let expenses = try await Expense.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$occurredOn >= range.start)
            .filter(\.$occurredOn < range.end)
            .all()
        return calculate(snapshot: snapshot, items: items, expenses: expenses)
    }

    func spendToUnits(userId: UUID) async throws -> SpendToUnitsCapacity {
        let user = try await User.find(userId, on: req.db)
        let preference = user.flatMap(\.dcaSymbol).flatMap(SpendToUnitsMath.normalizeSymbol)
        let holding = try await largestHoldingSymbol(userId: userId)
        let resolved: (symbol: String, source: SpendToUnitsSource) = {
            if let preference {
                return (preference, .preference)
            }
            if let holding {
                return (holding, .largestHolding)
            }
            return (SpendToUnitsMath.defaultSymbol, .default)
        }()

        let monthStart = monthRange(containing: Date()).start
        var surplus = 0.0
        var currency = "EUR"
        var categories: [SpendToUnitsCategory] = []
        if let snapshot = try await snapshot(userId: userId, monthStart: monthStart, on: req.db),
           let snapshotId = snapshot.id
        {
            let drift = try await dashboard(userId: userId, snapshotId: snapshotId)
            surplus = SpendToUnitsMath.surplus(
                investmentContributionTarget: drift.investmentContributionTarget,
                lostInvestmentCapital: drift.lostInvestmentCapital,
                totalTarget: drift.totalTarget,
                totalActual: drift.totalActual
            )
            currency = drift.currencyCode
            categories = drift.categories
                .filter { $0.allocationKind == .expense && $0.driftAmount > 0 }
                .prefix(5)
                .map { SpendToUnitsCategory(title: $0.title, overspendAmount: $0.driftAmount, units: nil) }
        }

        let quote = try? await req.application.marketDataService.quote(symbol: resolved.symbol, on: req)
        let price = quote.flatMap { $0.currentPrice > 0 ? $0.currentPrice : nil }
        let quoteDate = quote.map { Date(timeIntervalSince1970: $0.timestamp) }
        let stale: Bool = {
            guard let quoteDate else { return price == nil }
            return Date().timeIntervalSince(quoteDate) > SpendToUnitsMath.staleQuoteSeconds
        }()
        let asOf = quoteDate.map { ISO8601DateFormatter().string(from: $0) }

        return SpendToUnitsCapacity(
            symbol: resolved.symbol,
            resolvedFrom: resolved.source,
            price: price,
            priceCurrency: quote?.currency,
            quoteAsOf: asOf,
            quoteStale: stale,
            surplusAmount: surplus,
            surplusUnits: SpendToUnitsMath.units(amount: surplus, price: price),
            currencyCode: currency,
            categories: categories.map {
                SpendToUnitsCategory(
                    title: $0.title,
                    overspendAmount: $0.overspendAmount,
                    units: SpendToUnitsMath.units(amount: $0.overspendAmount, price: price)
                )
            }
        )
    }

    func updateDcaSymbol(userId: UUID, symbol: String) async throws -> SpendToUnitsCapacity {
        guard let normalized = SpendToUnitsMath.normalizeSymbol(symbol) else {
            throw Abort(.badRequest, reason: "Choose a ticker like VWCE or IWDA.")
        }
        guard let user = try await User.find(userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }
        user.dcaSymbol = normalized
        try await user.update(on: req.db)
        return try await spendToUnits(userId: userId)
    }

    private func largestHoldingSymbol(userId: UUID) async throws -> String? {
        let holdings = try await Stock.query(on: req.db).filter(\.$userId == userId).all()
        guard !holdings.isEmpty else { return nil }
        let ranked = Dictionary(grouping: holdings, by: \.symbol).compactMap { symbol, rows -> (String, Double, Int)? in
            let value = rows.reduce(0) { $0 + $1.shares * $1.buyPrice }
            guard value > 0 else { return nil }
            let rank = switch rows.first?.category {
            case .etf: 0
            case .mutualFund: 1
            case .stock: 2
            default: 3
            }
            return (symbol, value, rank)
        }
        return ranked.max { lhs, rhs in
            if lhs.2 != rhs.2 {
                return lhs.2 > rhs.2
            }
            return lhs.1 < rhs.1
        }?.0
    }

    func discipline(userId: UUID, through: Date, months: Int) async throws -> BudgetDisciplineSummary {
        let boundedMonths = min(max(months, 1), 24)
        let throughStart = monthRange(containing: through).start
        var results: [BudgetDisciplineMonth] = []
        for offset in stride(from: boundedMonths - 1, through: 0, by: -1) {
            guard let start = Calendar.utcGregorian.date(byAdding: .month, value: -offset, to: throughStart) else { continue }
            guard let snapshot = try await snapshot(userId: userId, monthStart: start, on: req.db),
                  let snapshotId = snapshot.id
            else {
                results.append(BudgetDisciplineMonth(monthStart: Self.dateString(start), score: nil, compliant: nil))
                continue
            }
            let drift = try await dashboard(userId: userId, snapshotId: snapshotId)
            let positiveDrift = drift.categories
                .filter { $0.allocationKind == .expense }
                .reduce(0) { $0 + max($1.driftAmount, 0) }
            let score = drift.totalTarget > 0 ? max(0, 100 * (1 - positiveDrift / drift.totalTarget)) : nil
            let completed = start < throughStart
            let compliant = completed ? drift.totalLevel != .red && !drift.categories.contains(where: { $0.level == .red }) : nil
            results.append(BudgetDisciplineMonth(monthStart: Self.dateString(start), score: score, compliant: compliant))
        }
        let completed = results.filter { $0.compliant != nil }
        var streak = 0
        for month in completed.reversed() {
            guard month.compliant == true else { break }
            streak += 1
        }
        return BudgetDisciplineSummary(
            currentScore: results.last?.score,
            completedMonthStreak: streak,
            compliantMonths: completed.count { $0.compliant == true },
            evaluatedMonths: completed.count,
            months: results
        )
    }

    func preview(userId: UUID, request: BudgetReallocationPreviewRequest, on db: any Database) async throws -> BudgetReallocationPreviewResponse {
        guard let snapshotId = UUID(uuidString: request.snapshotId),
              let snapshot = try await BudgetSnapshot.query(on: db)
              .filter(\.$id == snapshotId)
              .filter(\.$user.$id == userId)
              .first()
        else { throw Abort(.notFound) }
        guard snapshot.revision == request.expectedRevision else {
            throw Abort(.conflict, reason: "Budget changed. Refresh before reallocating.")
        }
        let validated = try await validateAdjustments(request.adjustments, snapshotId: snapshotId, userId: userId, on: db)
        _ = try await validatedDestination(
            userId: userId,
            goal: request.financialGoalId,
            portfolio: request.portfolioListId,
            on: db
        )
        let freed = rounded(validated.reduce(0) { $0 + $1.amount }, currencyCode: snapshot.currencyCode)
        let nextMonth = Calendar.utcGregorian.date(byAdding: .month, value: 1, to: snapshot.monthStart)!
        let existing = try await self.snapshot(userId: userId, monthStart: nextMonth, on: db)
        let existingInvestment = try await investmentTarget(userId: userId, snapshotId: existing?.id, on: db)
        var warnings: [String] = []
        if validated.reduce(0, { $0 + $1.item.plannedAmount - $1.amount }) + existingInvestment > snapshot.netSalary {
            warnings.append("Planned allocations exceed monthly income.")
        }
        return BudgetReallocationPreviewResponse(
            effectiveMonth: Self.dateString(nextMonth),
            freedCapital: freed,
            annualImpact: rounded(freed * 12, currencyCode: snapshot.currencyCode),
            investmentTargetBefore: existingInvestment,
            investmentTargetAfter: rounded(existingInvestment + freed, currencyCode: snapshot.currencyCode),
            warnings: warnings
        )
    }

    func commit(userId: UUID, request: BudgetReallocationCommitRequest) async throws -> BudgetReallocationEventResponse {
        guard let requestId = UUID(uuidString: request.requestId) else {
            throw Abort(.badRequest, reason: "requestId must be a UUID.")
        }
        if let existing = try await BudgetReallocationEventModel.query(on: req.db)
            .filter(\.$userId == userId).filter(\.$requestId == requestId).first()
        {
            return map(existing)
        }
        return try await req.db.transaction { db in
            if let existing = try await BudgetReallocationEventModel.query(on: db)
                .filter(\.$userId == userId).filter(\.$requestId == requestId).first()
            {
                return map(existing)
            }
            guard let sourceId = UUID(uuidString: request.preview.snapshotId),
                  let source = try await BudgetSnapshot.query(on: db)
                  .filter(\.$id == sourceId).filter(\.$user.$id == userId).first()
            else { throw Abort(.notFound) }
            guard source.revision == request.preview.expectedRevision else {
                throw Abort(.conflict, reason: "Budget changed. Refresh before reallocating.")
            }
            let validated = try await validateAdjustments(request.preview.adjustments, snapshotId: sourceId, userId: userId, on: db)
            let destination = try await validatedDestination(
                userId: userId,
                goal: request.preview.financialGoalId,
                portfolio: request.preview.portfolioListId,
                on: db
            )
            let effectiveMonth = Calendar.utcGregorian.date(byAdding: .month, value: 1, to: source.monthStart)!
            let target = try await cloneSnapshotIfNeeded(source: source, effectiveMonth: effectiveMonth, userId: userId, on: db)
            let targetId = try target.requireID()
            let targetItems = try await BudgetPlanItem.query(on: db)
                .filter(\.$user.$id == userId).filter(\.$snapshot.$id == targetId).all()
            var total = 0.0
            for adjustment in validated {
                guard let targetItem = targetItems.first(where: {
                    ($0.$category.id != nil && $0.$category.id == adjustment.item.$category.id) ||
                        $0.title.caseInsensitiveCompare(adjustment.item.title) == .orderedSame
                }) else { throw Abort(.conflict, reason: "A target category no longer exists in the effective month.") }
                guard targetItem.allocationKind == .expense, targetItem.plannedAmount >= adjustment.amount else {
                    throw Abort(.unprocessableEntity, reason: "A reallocation exceeds its next-month target.")
                }
                targetItem.plannedAmount = rounded(targetItem.plannedAmount - adjustment.amount, currencyCode: target.currencyCode)
                targetItem.targetType = .fixed
                targetItem.incomePercentage = nil
                try await targetItem.update(on: db)
                total += adjustment.amount
            }
            let goalId = destination.goalId
            let portfolioId = destination.portfolioId
            let investment = targetItems.first(where: {
                $0.allocationKind == .investmentContribution
                    && $0.destinationFinancialGoalId == goalId
                    && $0.destinationPortfolioListId == portfolioId
            }) ?? BudgetPlanItem(
                snapshotID: targetId, userID: userId, title: "Investments", plannedAmount: 0,
                pillar: .futureYou, allocationKind: .investmentContribution,
                destinationFinancialGoalId: goalId, destinationPortfolioListId: portfolioId
            )
            investment.plannedAmount = rounded(investment.plannedAmount + total, currencyCode: target.currencyCode)
            if investment.id == nil {
                try await investment.create(on: db)
            } else {
                try await investment.update(on: db)
            }
            if let goalId,
               let goal = try await FinancialGoalModel.owned(by: userId, on: db).filter(\.$id == goalId).first()
            {
                goal.monthlyContribution = rounded(goal.monthlyContribution + total, currencyCode: goal.baseCurrency)
                try await goal.update(on: db)
            }
            target.revision += 1
            source.revision += 1
            try await target.update(on: db)
            try await source.update(on: db)
            let event = BudgetReallocationEventModel()
            event.userId = userId; event.requestId = requestId
            event.sourceSnapshotId = sourceId; event.targetSnapshotId = targetId
            event.effectiveMonth = effectiveMonth; event.freedCapital = rounded(total, currencyCode: target.currencyCode)
            event.financialGoalId = goalId; event.portfolioListId = portfolioId
            event.adjustments = request.preview.adjustments
            try await event.create(on: db)
            return map(event)
        }
    }

    func history(userId: UUID) async throws -> [BudgetReallocationEventResponse] {
        try await BudgetReallocationEventModel.query(on: req.db)
            .filter(\.$userId == userId).sort(\.$createdAt, .descending).limit(100).all().map(map)
    }

    func bulkUpdate(userId: UUID, snapshotId: UUID, request: BudgetBulkPlanItemUpdateRequest) async throws -> BudgetDriftDashboard {
        try await req.db.transaction { db in
            guard let snapshot = try await BudgetSnapshot.query(on: db)
                .filter(\.$id == snapshotId).filter(\.$user.$id == userId).first()
            else { throw Abort(.notFound) }
            guard snapshot.revision == request.expectedRevision else { throw Abort(.conflict) }
            for update in request.items {
                guard update.plannedAmount.isFinite, update.plannedAmount >= 0,
                      let id = UUID(uuidString: update.id),
                      let item = try await BudgetPlanItem.query(on: db)
                      .filter(\.$id == id).filter(\.$snapshot.$id == snapshotId).filter(\.$user.$id == userId).first()
                else { throw Abort(.badRequest, reason: "Invalid bulk budget item.") }
                if update.targetType == .percentageIncome {
                    guard let percentage = update.incomePercentage, percentage.isFinite, (0 ... 1000).contains(percentage)
                    else { throw Abort(.badRequest, reason: "Invalid income percentage.") }
                    item.plannedAmount = snapshot.netSalary * percentage / 100
                } else {
                    item.plannedAmount = update.plannedAmount
                }
                item.targetType = update.targetType; item.incomePercentage = update.incomePercentage
                item.thresholdOverride = update.thresholdOverride; item.reallocationEligible = update.reallocationEligible
                try await item.update(on: db)
            }
            snapshot.revision += 1
            try await snapshot.update(on: db)
        }
        try await BudgetDriftEvaluator(req: req).evaluate(userId: userId, monthStart: requiredSnapshot(userId: userId, id: snapshotId).monthStart, notify: true)
        return try await dashboard(userId: userId, snapshotId: snapshotId)
    }

    func listTemplates(userId: UUID) async throws -> [BudgetTemplateResponse] {
        try await BudgetTemplateModel.query(on: req.db).filter(\.$userId == userId)
            .sort(\.$name).all().map(map)
    }

    func createTemplate(userId: UUID, request: BudgetTemplateRequest) async throws -> BudgetTemplateResponse {
        try validateTemplate(request)
        let model = BudgetTemplateModel()
        model.userId = userId; model.name = request.name.trimmingCharacters(in: .whitespacesAndNewlines); model.items = request.items
        try await model.create(on: req.db)
        return map(model)
    }

    func updateTemplate(userId: UUID, id: UUID, request: BudgetTemplateRequest) async throws -> BudgetTemplateResponse {
        try validateTemplate(request)
        guard let model = try await BudgetTemplateModel.query(on: req.db).filter(\.$id == id).filter(\.$userId == userId).first()
        else { throw Abort(.notFound) }
        model.name = request.name.trimmingCharacters(in: .whitespacesAndNewlines); model.items = request.items
        try await model.update(on: req.db)
        return map(model)
    }

    func deleteTemplate(userId: UUID, id: UUID) async throws {
        guard let model = try await BudgetTemplateModel.query(on: req.db).filter(\.$id == id).filter(\.$userId == userId).first()
        else { throw Abort(.notFound) }
        try await model.delete(on: req.db)
    }

    func applyTemplate(userId: UUID, id: UUID, request: BudgetTemplateApplyRequest) async throws -> BudgetDriftDashboard {
        guard let snapshotId = UUID(uuidString: request.snapshotId) else { throw Abort(.badRequest) }
        try await req.db.transaction { db in
            guard let template = try await BudgetTemplateModel.query(on: db).filter(\.$id == id).filter(\.$userId == userId).first(),
                  let snapshot = try await BudgetSnapshot.query(on: db).filter(\.$id == snapshotId).filter(\.$user.$id == userId).first()
            else { throw Abort(.notFound) }
            guard snapshot.revision == request.expectedRevision else { throw Abort(.conflict) }
            let existing = try await BudgetPlanItem.query(on: db).filter(\.$snapshot.$id == snapshotId).all()
            if !existing.isEmpty, !request.replaceExisting {
                throw Abort(.conflict, reason: "Snapshot already has targets.")
            }
            if request.replaceExisting {
                try await existing.delete(on: db)
            }
            for value in template.items {
                let item = BudgetPlanItem(
                    snapshotID: snapshotId, userID: userId, title: value.title,
                    plannedAmount: value.targetType == .percentageIncome ? snapshot.netSalary * (value.incomePercentage ?? 0) / 100 : value.plannedAmount,
                    pillar: value.pillar, targetType: value.targetType, incomePercentage: value.incomePercentage,
                    thresholdOverride: value.thresholdOverride, allocationKind: value.allocationKind,
                    reallocationEligible: value.reallocationEligible
                )
                if let category = value.categoryId.flatMap(UUID.init(uuidString:)),
                   let owned = try await ExpenseCategory.query(on: db).filter(\.$id == category).filter(\.$user.$id == userId).first()
                {
                    item.$category.id = try owned.requireID()
                }
                try await item.create(on: db)
            }
            snapshot.revision += 1; try await snapshot.update(on: db)
        }
        return try await dashboard(userId: userId, snapshotId: snapshotId)
    }

    private func calculate(snapshot: BudgetSnapshot, items: [BudgetPlanItem], expenses: [Expense]) -> BudgetDriftDashboard {
        var actualByItem: [UUID: Double] = [:]
        var actualByCategory: [UUID: Double] = [:]
        var actualByTitle: [String: Double] = [:]
        let investmentItemIds = Set(items.filter { $0.allocationKind == .investmentContribution }.compactMap(\.id))
        var totalActual = 0.0
        for expense in expenses {
            let amount = effective(amount: expense.amount, split: expense.splitMode, share: expense.userSharePercent)
            if let linked = expense.$linkedPlanItem.id {
                actualByItem[linked, default: 0] += amount
                if investmentItemIds.contains(linked) {
                    continue
                }
            } else if let category = expense.$category.id {
                actualByCategory[category, default: 0] += amount
            } else {
                actualByTitle[normalize(expense.title), default: 0] += amount
            }
            totalActual += amount
        }
        var consumedCategories = Set<UUID>()
        var consumedTitles = Set<String>()
        var rows: [BudgetCategoryDrift] = items.map { item in
            let target = effective(amount: item.plannedAmount, split: item.splitMode, share: item.userSharePercent)
            let actual: Double
            if let id = item.id, let linked = actualByItem[id] {
                actual = linked
            } else if let category = item.$category.id {
                actual = actualByCategory[category, default: 0]; consumedCategories.insert(category)
            } else {
                let key = normalize(item.title); actual = actualByTitle[key, default: 0]; consumedTitles.insert(key)
            }
            return driftRow(item: item, target: target, actual: actual, defaultThreshold: snapshot.categoryDriftThreshold)
        }
        for (category, actual) in actualByCategory where !consumedCategories.contains(category) {
            rows.append(unbudgetedRow(id: "unbudgeted-category:\(category)", title: "Unbudgeted spending", categoryId: category, actual: actual, threshold: snapshot.categoryDriftThreshold))
        }
        for (title, actual) in actualByTitle where !consumedTitles.contains(title) {
            rows.append(unbudgetedRow(id: "unbudgeted-title:\(title)", title: title.capitalized, categoryId: nil, actual: actual, threshold: snapshot.categoryDriftThreshold))
        }
        let expenseRows = rows.filter { $0.allocationKind == .expense }
        let totalTarget = expenseRows.reduce(0) { $0 + $1.targetAmount }
        let totalDrift = totalActual - totalTarget
        let totalPercent = totalTarget > 0 ? totalDrift / totalTarget * 100 : nil
        let totalLevel = level(drift: totalDrift, percent: totalPercent, target: totalTarget, threshold: snapshot.totalDriftThreshold)
        return BudgetDriftDashboard(
            snapshotId: snapshot.id?.uuidString ?? "", monthStart: Self.dateString(snapshot.monthStart), currencyCode: snapshot.currencyCode,
            revision: snapshot.revision,
            totalTarget: rounded(totalTarget, currencyCode: snapshot.currencyCode), totalActual: rounded(totalActual, currencyCode: snapshot.currencyCode),
            totalDriftAmount: rounded(totalDrift, currencyCode: snapshot.currencyCode), totalDriftPercent: totalPercent,
            totalLevel: totalLevel,
            investmentContributionTarget: rows.filter { $0.allocationKind == .investmentContribution }.reduce(0) { $0 + $1.targetAmount },
            lostInvestmentCapital: rounded(max(totalDrift, 0), currencyCode: snapshot.currencyCode),
            categories: rows.sorted { lhs, rhs in lhs.level.sortRank > rhs.level.sortRank || (lhs.level == rhs.level && lhs.driftAmount > rhs.driftAmount) }
        )
    }

    private func driftRow(item: BudgetPlanItem, target: Double, actual: Double, defaultThreshold: Double) -> BudgetCategoryDrift {
        let drift = actual - target; let percent = target > 0 ? drift / target * 100 : nil
        let threshold = item.thresholdOverride ?? defaultThreshold
        return BudgetCategoryDrift(
            id: item.id?.uuidString ?? "", title: item.title, categoryId: item.$category.id?.uuidString,
            targetAmount: target, actualAmount: actual, driftAmount: drift, driftPercent: percent,
            threshold: threshold, level: level(drift: drift, percent: percent, target: target, threshold: threshold),
            allocationKind: item.allocationKind, reallocationEligible: item.reallocationEligible
        )
    }

    private func unbudgetedRow(id: String, title: String, categoryId: UUID?, actual: Double, threshold: Double) -> BudgetCategoryDrift {
        BudgetCategoryDrift(id: id, title: title, categoryId: categoryId?.uuidString, targetAmount: 0, actualAmount: actual,
                            driftAmount: actual, driftPercent: nil, threshold: threshold, level: .red)
    }

    private func level(drift: Double, percent: Double?, target: Double, threshold: Double) -> BudgetDriftLevel {
        guard drift > 0 else { return .green }
        guard target > 0, let percent else { return .red }
        return percent > threshold ? .red : .yellow
    }

    private func effective(amount: Double, split: ExpenseSplitMode, share: Double) -> Double {
        split == .shared ? amount * share / 100 : amount
    }

    private func validateAdjustments(_ values: [BudgetReallocationAdjustment], snapshotId: UUID, userId: UUID, on db: any Database) async throws -> [(item: BudgetPlanItem, amount: Double)] {
        guard !values.isEmpty else { throw Abort(.badRequest, reason: "At least one adjustment is required.") }
        var ids = Set<UUID>(); var result: [(BudgetPlanItem, Double)] = []
        for value in values {
            guard value.amount.isFinite, value.amount > 0, let id = UUID(uuidString: value.planItemId), ids.insert(id).inserted,
                  let item = try await BudgetPlanItem.query(on: db).filter(\.$id == id).filter(\.$snapshot.$id == snapshotId).filter(\.$user.$id == userId).first(),
                  item.allocationKind == .expense, item.reallocationEligible, value.amount <= item.plannedAmount
            else { throw Abort(.unprocessableEntity, reason: "Invalid reallocation adjustment.") }
            result.append((item, value.amount))
        }
        return result
    }

    private func validatedDestination(
        userId: UUID,
        goal: String?,
        portfolio: String?,
        on db: any Database
    ) async throws -> (goalId: UUID?, portfolioId: UUID?) {
        let requestedPortfolioId: UUID?
        if let portfolio {
            guard let id = UUID(uuidString: portfolio) else {
                throw Abort(.badRequest, reason: "Invalid portfolio.")
            }
            requestedPortfolioId = id
        } else {
            requestedPortfolioId = nil
        }

        let goalModel: FinancialGoalModel?
        if let goal {
            guard let id = UUID(uuidString: goal),
                  let model = try await FinancialGoalModel.owned(by: userId, on: db)
                  .filter(\.$id == id)
                  .first()
            else { throw Abort(.badRequest, reason: "Invalid financial goal.") }
            goalModel = model
        } else {
            goalModel = nil
        }

        if let goalModel, let requestedPortfolioId, goalModel.portfolioListId != requestedPortfolioId {
            throw Abort(.badRequest, reason: "The financial goal does not belong to the selected portfolio.")
        }

        let resolvedPortfolioId = requestedPortfolioId ?? goalModel?.portfolioListId
        if let resolvedPortfolioId {
            guard try await PortfolioList.query(on: db)
                .filter(\.$id == resolvedPortfolioId)
                .filter(\.$userId == userId)
                .first() != nil
            else { throw Abort(.badRequest, reason: "Invalid portfolio.") }
        }

        return (goalModel?.id, resolvedPortfolioId)
    }

    private func cloneSnapshotIfNeeded(source: BudgetSnapshot, effectiveMonth: Date, userId: UUID, on db: any Database) async throws -> BudgetSnapshot {
        if let existing = try await snapshot(userId: userId, monthStart: effectiveMonth, on: db) {
            return existing
        }
        let clone = BudgetSnapshot(userID: userId, monthStart: effectiveMonth, netSalary: source.netSalary, targetShares: source.targetShares,
                                   currencyCode: source.currencyCode, categoryDriftThreshold: source.categoryDriftThreshold,
                                   totalDriftThreshold: source.totalDriftThreshold, alertsEnabled: source.alertsEnabled,
                                   alertOnUnbudgeted: source.alertOnUnbudgeted)
        try await clone.create(on: db); let cloneId = try clone.requireID(); let sourceId = try source.requireID()
        let items = try await BudgetPlanItem.query(on: db).filter(\.$snapshot.$id == sourceId).filter(\.$user.$id == userId).all()
        for item in items {
            let copy = BudgetPlanItem(snapshotID: cloneId, userID: userId, title: item.title, plannedAmount: item.plannedAmount,
                                      pillar: item.pillar, splitMode: item.splitMode, userSharePercent: item.userSharePercent,
                                      targetType: item.targetType, incomePercentage: item.incomePercentage,
                                      thresholdOverride: item.thresholdOverride, allocationKind: item.allocationKind,
                                      reallocationEligible: item.reallocationEligible,
                                      destinationFinancialGoalId: item.destinationFinancialGoalId,
                                      destinationPortfolioListId: item.destinationPortfolioListId)
            copy.$category.id = item.$category.id; try await copy.create(on: db)
        }
        return clone
    }

    private func snapshot(userId: UUID, monthStart: Date, on db: any Database) async throws -> BudgetSnapshot? {
        let range = monthRange(containing: monthStart)
        let widenedStart = Calendar.utcGregorian.date(byAdding: .day, value: -1, to: range.start)!
        let widenedEnd = Calendar.utcGregorian.date(byAdding: .day, value: 1, to: range.start)!
        let candidates = try await BudgetSnapshot.query(on: db).filter(\.$user.$id == userId)
            .filter(\.$monthStart >= widenedStart).filter(\.$monthStart < widenedEnd).all()
        return candidates.min {
            abs($0.monthStart.timeIntervalSince(range.start)) < abs($1.monthStart.timeIntervalSince(range.start))
        }
    }

    private func requiredSnapshot(userId: UUID, id: UUID) async throws -> BudgetSnapshot {
        guard let value = try await BudgetSnapshot.query(on: req.db).filter(\.$id == id).filter(\.$user.$id == userId).first()
        else { throw Abort(.notFound) }; return value
    }

    private func investmentTarget(userId: UUID, snapshotId: UUID?, on db: any Database) async throws -> Double {
        guard let snapshotId else { return 0 }
        return try await BudgetPlanItem.query(on: db).filter(\.$user.$id == userId).filter(\.$snapshot.$id == snapshotId).all()
            .filter { $0.allocationKind == .investmentContribution }.reduce(0) { $0 + $1.plannedAmount }
    }

    private func validateTemplate(_ request: BudgetTemplateRequest) throws {
        guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.name.count <= 80, !request.items.isEmpty else {
            throw Abort(.badRequest, reason: "Template name and at least one target are required.")
        }
        guard request.items.allSatisfy({ $0.plannedAmount.isFinite && $0.plannedAmount >= 0 }) else { throw Abort(.badRequest) }
    }

    private func map(_ model: BudgetReallocationEventModel) -> BudgetReallocationEventResponse {
        BudgetReallocationEventResponse(id: model.id?.uuidString ?? "", requestId: model.requestId.uuidString,
                                        sourceSnapshotId: model.sourceSnapshotId.uuidString, targetSnapshotId: model.targetSnapshotId.uuidString,
                                        effectiveMonth: Self.dateString(model.effectiveMonth), freedCapital: model.freedCapital,
                                        financialGoalId: model.financialGoalId?.uuidString, portfolioListId: model.portfolioListId?.uuidString,
                                        adjustments: model.adjustments, createdAt: model.createdAt.map(Self.isoString))
    }

    private func map(_ model: BudgetTemplateModel) -> BudgetTemplateResponse {
        BudgetTemplateResponse(id: model.id?.uuidString ?? "", name: model.name, items: model.items,
                               createdAt: model.createdAt.map(Self.isoString), updatedAt: model.updatedAt.map(Self.isoString))
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func rounded(_ amount: Double, currencyCode: String) -> Double {
        let digits = ["JPY", "KRW", "VND"].contains(currencyCode.uppercased()) ? 0 : 2
        let factor = pow(10, Double(digits)); return (amount * factor).rounded() / factor
    }

    private func monthRange(containing date: Date) -> (start: Date, end: Date) {
        let components = Calendar.utcGregorian.dateComponents([.year, .month], from: date)
        let start = Calendar.utcGregorian.date(from: components)!; return (start, Calendar.utcGregorian.date(byAdding: .month, value: 1, to: start)!)
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .utcGregorian
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

struct BudgetDriftEvaluator {
    let req: Request

    func evaluate(userId: UUID, monthStart: Date, notify: Bool) async throws {
        let range = Calendar.utcGregorian.dateComponents([.year, .month], from: monthStart)
        let start = Calendar.utcGregorian.date(from: range)!
        let widenedStart = Calendar.utcGregorian.date(byAdding: .day, value: -1, to: start)!
        let widenedEnd = Calendar.utcGregorian.date(byAdding: .day, value: 1, to: start)!
        let snapshots = try await BudgetSnapshot.query(on: req.db).filter(\.$user.$id == userId)
            .filter(\.$monthStart >= widenedStart).filter(\.$monthStart < widenedEnd).all()
        guard let snapshot = snapshots.min(by: {
            abs($0.monthStart.timeIntervalSince(start)) < abs($1.monthStart.timeIntervalSince(start))
        }),
            let snapshotId = snapshot.id
        else { return }
        let dashboard = try await BudgetingEngineService(req: req).dashboard(userId: userId, snapshotId: snapshotId)
        var scopes = dashboard.categories
            .filter { snapshot.alertOnUnbudgeted || $0.targetAmount > 0 }
            .map { ($0.id, $0.title, $0.level, $0.driftAmount) }
        scopes.append(("total", "Total expenses", dashboard.totalLevel, dashboard.totalDriftAmount))
        for (key, title, level, amount) in scopes {
            let state = try await BudgetDriftAlertState.query(on: req.db)
                .filter(\.$snapshot.$id == snapshotId).filter(\.$scopeKey == key).first() ?? BudgetDriftAlertState()
            let isNew = state.id == nil; let wasRed = !isNew && state.level == .red
            if isNew {
                state.userId = userId; state.$snapshot.id = snapshotId; state.scopeKey = key; state.breachSequence = 0
            }
            state.level = level; state.evaluatedAt = Date()
            if level == .red {
                if !wasRed {
                    state.breachSequence += 1
                }
                if notify, snapshot.alertsEnabled, envBool("BUDGET_DRIFT_ALERTS_ENABLED", default: true), !wasRed {
                    let sequence = state.breachSequence
                    _ = try await NotificationEventPublisher.publishAndPush(
                        userId: userId, kind: .budget,
                        deduplicationKey: "budget-drift:\(snapshotId):\(key):\(sequence)",
                        title: "Budget drift needs attention",
                        body: "\(title) is \(Self.amount(amount, currency: snapshot.currencyCode)) over target.",
                        deepLink: "norviq://expenses?month=\(BudgetingEngineService.dateString(snapshot.monthStart))&scope=\(key)",
                        payload: ["snapshot_id": snapshotId.uuidString, "scope": key, "level": level.rawValue], req: req
                    )
                    state.lastNotifiedLevel = .red; state.lastNotifiedAt = Date()
                }
                state.clearedAt = nil
            } else if wasRed {
                state.clearedAt = Date(); state.lastNotifiedLevel = nil
            }
            if isNew {
                try await state.create(on: req.db)
            } else {
                try await state.update(on: req.db)
            }
        }
    }

    private static func amount(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: abs(value))) ?? "\(abs(value)) \(currency)"
    }
}

private extension Calendar {
    static var utcGregorian: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
}

private extension BudgetDriftLevel {
    var sortRank: Int {
        switch self { case .red: 2; case .yellow: 1; case .green: 0 }
    }
}
