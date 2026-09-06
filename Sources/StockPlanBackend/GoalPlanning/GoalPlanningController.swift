import Fluent
import Foundation
import StockPlanShared
import Vapor

struct GoalPlanningController: RouteCollection {
    private let service = GoalPlanningService()

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.goalsRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.goalsWrite))

        read.group("financial-goals") { goals in
            goals.get(use: list)
            goals.get("templates", use: templates)
            goals.get("overview", use: overview)
            goals.group(":id") { goal in
                goal.get(use: get)
                goal.get("progress", use: progress)
                goal.get("contributions", use: listContributions)
                goal.get("suggestions", use: suggestions)
                goal.get("adjustment-drafts", use: adjustmentDrafts)
            }
        }
        write.group("financial-goals") { goals in
            goals.post(use: create)
            goals.patch("bulk", use: bulkUpdate)
            goals.group(":id") { goal in
                goal.put(use: update)
                goal.delete(use: delete)
                goal.post("what-if", use: whatIf)
                goal.post("contributions", use: createContribution)
                goal.delete("contributions", ":contributionId", use: deleteContribution)
                goal.post("suggestions", ":suggestionId", "accept", use: acceptSuggestion)
                goal.post("suggestions", ":suggestionId", "dismiss", use: dismissSuggestion)
            }
        }
    }

    @Sendable func templates(req _: Request) async throws -> [GoalTemplate] {
        [
            .init(id: "financial-independence", name: "Financial independence", goalType: .financialIndependence,
                  suggestedYears: 20, riskProfile: .moderate),
            .init(id: "retirement", name: "Retirement", goalType: .retirement,
                  suggestedYears: 25, riskProfile: .moderate),
            .init(id: "home-deposit", name: "Home deposit", goalType: .homePurchase,
                  suggestedYears: 5, riskProfile: .conservative),
            .init(id: "emergency-fund", name: "Emergency fund", goalType: .emergencyFund,
                  suggestedYears: 2, riskProfile: .conservative),
            .init(id: "investment-target", name: "Investment target", goalType: .investmentTarget,
                  suggestedYears: 10, riskProfile: .aggressive),
        ]
    }

    @Sendable func list(req: Request) async throws -> [FinancialGoal] {
        let userId = try user(req)
        let models = try await FinancialGoalModel.owned(by: userId, on: req.db).sort(\.$createdAt, .descending).all()
        var result: [FinancialGoal] = []
        for model in models {
            try await result.append(service.goalDTO(model, on: req.db))
        }
        return result
    }

    @Sendable func overview(req: Request) async throws -> GoalOverview {
        let userId = try user(req)
        let entitlement = try await req.application.entitlementResolver.resolve(userId: userId, on: req.db)
        let models = try await FinancialGoalModel.owned(by: userId, on: req.db)
            .filter(\.$status == FinancialGoalStatus.active.rawValue).sort(\.$targetDate).all()
        var items: [GoalOverviewItem] = []
        for model in models {
            let goal = try await service.goalDTO(model, on: req.db)
            let progress = try await service.progress(for: model, userId: userId, req: req)
            items.append(.init(goal: goal, progress: progress))
        }
        return GoalOverview(
            items: items,
            totalCurrentValue: items.reduce(0) { $0 + $1.progress.currentValue },
            totalTargetAmount: items.reduce(0) { $0 + $1.goal.targetAmount },
            activeGoalCount: items.count,
            activeGoalLimit: entitlement.isPro ? nil : 1,
            isPro: entitlement.isPro
        )
    }

    @Sendable func create(req: Request) async throws -> FinancialGoal {
        let userId = try user(req)
        let input = try req.content.decode(FinancialGoalInput.self)
        try await enforceActiveLimit(userId: userId, activating: input.status == .active, excluding: nil, req: req)
        let allocations = try await service.validateLinks(input, userId: userId, excluding: nil, on: req.db)
        let primary = try await primaryPortfolio(from: allocations, userId: userId, on: req.db)
        if allocations.isEmpty {
            try await service.validateAllocationCapacity(
                portfolioId: primary, percentage: 100, status: input.status,
                userId: userId, excluding: nil, on: req.db
            )
        }
        guard let targetDate = GoalPlanningService.parseDate(input.targetDate), targetDate > Date() else {
            throw Abort(.badRequest, reason: "Target date must be in the future")
        }
        let goal = FinancialGoalModel(
            userId: userId,
            portfolioListId: primary,
            name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
            goalType: input.goalType.rawValue,
            targetAmount: input.targetAmount,
            targetDate: targetDate,
            baseCurrency: input.baseCurrency.uppercased(),
            startingCapital: input.startingCapital,
            monthlyContribution: input.monthlyContribution,
            annualContributionGrowth: input.annualContributionGrowth,
            inflationAssumption: input.inflationAssumption,
            riskProfile: input.riskProfile.rawValue,
            expectedAnnualReturn: input.expectedAnnualReturn ?? input.riskProfile.defaultAnnualReturn,
            status: input.status.rawValue
        )
        try await req.db.transaction { database in
            try await goal.save(on: database)
            guard let goalId = goal.id else { throw Abort(.internalServerError) }
            let storedAllocations = allocations.isEmpty ? [(primary, 100)] : allocations
            try await service.replaceLinks(
                goalId: goalId, userId: userId, input: input,
                allocations: storedAllocations, on: database
            )
        }
        return try await service.goalDTO(goal, on: req.db)
    }

    @Sendable func get(req: Request) async throws -> FinancialGoal {
        let (_, goal) = try await ownedGoal(req)
        return try await service.goalDTO(goal, on: req.db)
    }

    @Sendable func update(req: Request) async throws -> FinancialGoal {
        let (userId, goal) = try await ownedGoal(req)
        let input = try req.content.decode(FinancialGoalInput.self)
        let activating = input.status == .active && goal.status != FinancialGoalStatus.active.rawValue
        try await enforceActiveLimit(userId: userId, activating: activating, excluding: goal.id, req: req)
        let allocations = try await service.validateLinks(input, userId: userId, excluding: goal.id, on: req.db)
        let primary = try await primaryPortfolio(from: allocations, userId: userId, on: req.db)
        if allocations.isEmpty {
            try await service.validateAllocationCapacity(
                portfolioId: primary, percentage: 100, status: input.status,
                userId: userId, excluding: goal.id, on: req.db
            )
        }
        guard let targetDate = GoalPlanningService.parseDate(input.targetDate), targetDate > Date() else {
            throw Abort(.badRequest, reason: "Target date must be in the future")
        }
        goal.portfolioListId = primary
        goal.name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        goal.goalType = input.goalType.rawValue
        goal.targetAmount = input.targetAmount
        goal.targetDate = targetDate
        goal.baseCurrency = input.baseCurrency.uppercased()
        goal.startingCapital = input.startingCapital
        goal.monthlyContribution = input.monthlyContribution
        goal.annualContributionGrowth = input.annualContributionGrowth
        goal.inflationAssumption = input.inflationAssumption
        goal.riskProfile = input.riskProfile.rawValue
        goal.expectedAnnualReturn = input.expectedAnnualReturn ?? input.riskProfile.defaultAnnualReturn
        goal.status = input.status.rawValue
        try await req.db.transaction { database in
            try await goal.save(on: database)
            guard let goalId = goal.id else { throw Abort(.internalServerError) }
            try await service.replaceLinks(
                goalId: goalId, userId: userId, input: input,
                allocations: allocations.isEmpty ? [(primary, 100)] : allocations, on: database
            )
        }
        return try await service.goalDTO(goal, on: req.db)
    }

    @Sendable func delete(req: Request) async throws -> HTTPStatus {
        let (_, goal) = try await ownedGoal(req)
        try await goal.delete(on: req.db)
        return .noContent
    }

    @Sendable func progress(req: Request) async throws -> GoalProgress {
        let (userId, goal) = try await ownedGoal(req)
        return try await service.progress(for: goal, userId: userId, req: req)
    }

    @Sendable func whatIf(req: Request) async throws -> GoalWhatIfResponse {
        let (userId, goal) = try await ownedGoal(req)
        let input = try req.content.decode(GoalWhatIfRequest.self)
        guard input.monthlyContribution.map({ $0.isFinite && $0 >= 0 }) ?? true,
              input.expectedAnnualReturn.map({
                  $0.isFinite && abs($0 - goal.expectedAnnualReturn) <= 0.010_001
              }) ?? true
        else { throw Abort(.badRequest, reason: "Invalid what-if assumptions") }
        let targetDate: Date?
        if let targetDateValue = input.targetDate {
            guard let parsed = GoalPlanningService.parseDate(targetDateValue), parsed > Date() else {
                throw Abort(.badRequest, reason: "What-if target date must be in the future")
            }
            targetDate = parsed
        } else {
            targetDate = nil
        }
        let baseline = try await service.progress(for: goal, userId: userId, req: req)
        let scenario = try await service.progress(
            for: goal,
            userId: userId,
            monthlyContribution: input.monthlyContribution,
            expectedAnnualReturn: input.expectedAnnualReturn,
            targetDate: targetDate,
            req: req
        )
        return .init(baseline: baseline, scenario: scenario)
    }

    @Sendable func listContributions(req: Request) async throws -> [GoalContribution] {
        let (_, goal) = try await ownedGoal(req)
        guard let goalId = goal.id else { throw Abort(.internalServerError) }
        return try await GoalContributionModel.query(on: req.db).filter(\.$goal.$id == goalId)
            .sort(\.$occurredAt, .descending).all().map(Self.contributionDTO)
    }

    @Sendable func createContribution(req: Request) async throws -> GoalContribution {
        let (userId, goal) = try await ownedGoal(req)
        let input = try req.content.decode(GoalContributionInput.self)
        guard input.amount > 0, input.amount.isFinite,
              let occurredAt = GoalPlanningService.parseDate(input.occurredAt), occurredAt <= Date()
        else { throw Abort(.badRequest, reason: "Contribution must be positive and cannot be in the future") }
        guard let goalId = goal.id else { throw Abort(.internalServerError) }
        let contribution = GoalContributionModel(
            goalId: goalId, userId: userId, amount: input.amount,
            occurredAt: occurredAt, note: input.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try await contribution.save(on: req.db)
        return Self.contributionDTO(contribution)
    }

    @Sendable func deleteContribution(req: Request) async throws -> HTTPStatus {
        let (userId, goal) = try await ownedGoal(req)
        guard let goalId = goal.id, let id = req.parameters.get("contributionId", as: UUID.self),
              let contribution = try await GoalContributionModel.query(on: req.db)
              .filter(\.$id == id).filter(\.$goal.$id == goalId).filter(\.$userId == userId).first()
        else { throw Abort(.notFound, reason: "Contribution not found") }
        try await contribution.delete(on: req.db)
        return .noContent
    }

    @Sendable func suggestions(req: Request) async throws -> [GoalSuggestion] {
        let (userId, goal) = try await ownedGoal(req)
        return try await service.suggestions(for: goal, userId: userId, req: req)
    }

    @Sendable func acceptSuggestion(req: Request) async throws -> GoalAdjustmentDraft {
        let (userId, goal) = try await ownedGoal(req)
        let suggestion = try await ownedSuggestion(req, goal: goal, userId: userId)
        let destination: GoalAdjustmentDestination = switch GoalSuggestionKind(rawValue: suggestion.kind) {
        case .reduceSpending: .budget
        case .rebalanceAllocation: .rebalancing
        default: .goal
        }
        if destination != .goal {
            let entitlement = try await req.application.entitlementResolver.resolve(userId: userId, on: req.db)
            guard entitlement.isPro else {
                throw BillingUpgradeRequiredError(feature: .goalPlanning, plan: entitlement.level)
            }
        }
        suggestion.status = GoalSuggestionStatus.accepted.rawValue
        try await suggestion.save(on: req.db)
        guard let suggestionId = suggestion.id else { throw Abort(.internalServerError) }
        var values: [String: ScenarioJSONValue] = ["kind": .string(suggestion.kind)]
        if let amount = suggestion.monthlyAmount {
            values["monthly_amount"] = .number(amount)
        }
        if let percentage = suggestion.allocationPercentage {
            values["allocation_percentage"] = .number(percentage)
        }
        let draft = GoalAdjustmentDraftModel(
            suggestionId: suggestionId, userId: userId,
            destination: destination.rawValue, payload: ScenarioJSON(values)
        )
        try await draft.save(on: req.db)
        return Self.draftDTO(draft)
    }

    @Sendable func dismissSuggestion(req: Request) async throws -> HTTPStatus {
        let (userId, goal) = try await ownedGoal(req)
        let suggestion = try await ownedSuggestion(req, goal: goal, userId: userId)
        suggestion.status = GoalSuggestionStatus.dismissed.rawValue
        try await suggestion.save(on: req.db)
        return .noContent
    }

    @Sendable func adjustmentDrafts(req: Request) async throws -> [GoalAdjustmentDraft] {
        let (userId, goal) = try await ownedGoal(req)
        guard let goalId = goal.id else { throw Abort(.internalServerError) }
        let suggestionIds = try await GoalSuggestionModel.query(on: req.db)
            .filter(\.$goal.$id == goalId).filter(\.$userId == userId).all().compactMap(\.id)
        guard !suggestionIds.isEmpty else { return [] }
        return try await GoalAdjustmentDraftModel.query(on: req.db)
            .filter(\.$suggestion.$id ~~ suggestionIds).sort(\.$createdAt, .descending).all().map(Self.draftDTO)
    }

    @Sendable func bulkUpdate(req: Request) async throws -> [FinancialGoal] {
        let userId = try user(req)
        let input = try req.content.decode(FinancialGoalBulkUpdate.self)
        let ids = input.goalIds.compactMap(UUID.init(uuidString:))
        guard ids.count == input.goalIds.count, !ids.isEmpty else { throw Abort(.badRequest, reason: "Invalid goal ids") }
        let goals = try await FinancialGoalModel.owned(by: userId, on: req.db).filter(\.$id ~~ ids).all()
        guard goals.count == ids.count else { throw Abort(.notFound, reason: "Financial goal not found") }
        if input.status == .active {
            let currentlyActive = try await FinancialGoalModel.owned(by: userId, on: req.db)
                .filter(\.$status == FinancialGoalStatus.active.rawValue).filter(\.$id !~ ids).count()
            let entitlement = try await req.application.entitlementResolver.resolve(userId: userId, on: req.db)
            if !entitlement.isPro, currentlyActive + goals.count > 1 {
                throw BillingUpgradeRequiredError(feature: .goalPlanning, plan: entitlement.level, limit: 1,
                                                  current: currentlyActive + goals.count)
            }
            try await service.validateBulkActivation(goals: goals, userId: userId, on: req.db)
        }
        try await req.db.transaction { database in
            for goal in goals {
                goal.status = input.status.rawValue
                try await goal.save(on: database)
            }
        }
        var response: [FinancialGoal] = []
        for goal in goals {
            try await response.append(service.goalDTO(goal, on: req.db))
        }
        return response
    }

    private func user(_ req: Request) throws -> UUID {
        try req.auth.require(SessionToken.self).userId
    }

    private func ownedGoal(_ req: Request) async throws -> (UUID, FinancialGoalModel) {
        let userId = try user(req)
        guard let id = req.parameters.get("id", as: UUID.self),
              let goal = try await FinancialGoalModel.owned(by: userId, on: req.db).filter(\.$id == id).first()
        else { throw Abort(.notFound, reason: "Financial goal not found") }
        return (userId, goal)
    }

    private func ownedSuggestion(_ req: Request, goal: FinancialGoalModel, userId: UUID) async throws -> GoalSuggestionModel {
        guard let goalId = goal.id, let id = req.parameters.get("suggestionId", as: UUID.self),
              let suggestion = try await GoalSuggestionModel.query(on: req.db)
              .filter(\.$id == id).filter(\.$goal.$id == goalId).filter(\.$userId == userId).first()
        else { throw Abort(.notFound, reason: "Suggestion not found") }
        return suggestion
    }

    private func primaryPortfolio(from allocations: [(UUID, Double)], userId: UUID, on db: any Database) async throws -> UUID {
        if let primary = allocations.max(by: { $0.1 < $1.1 })?.0 {
            return primary
        }
        guard let fallback = try await PortfolioList.query(on: db).filter(\.$userId == userId)
            .sort(\.$isDefault, .descending).first()?.id
        else { throw Abort(.unprocessableEntity, reason: "Create a portfolio before creating a financial goal") }
        return fallback
    }

    private func enforceActiveLimit(
        userId: UUID, activating: Bool, excluding goalId: UUID?, req: Request
    ) async throws {
        guard activating else { return }
        let entitlement = try await req.application.entitlementResolver.resolve(userId: userId, on: req.db)
        guard !entitlement.isPro else { return }
        var query = FinancialGoalModel.owned(by: userId, on: req.db)
            .filter(\.$status == FinancialGoalStatus.active.rawValue)
        if let goalId {
            query = query.filter(\.$id != goalId)
        }
        let count = try await query.count()
        guard count < 1 else {
            throw BillingUpgradeRequiredError(feature: .goalPlanning, plan: entitlement.level, limit: 1, current: count)
        }
    }

    private static func contributionDTO(_ model: GoalContributionModel) -> GoalContribution {
        .init(
            id: model.id?.uuidString ?? "", goalId: model.$goal.id.uuidString,
            amount: model.amount, occurredAt: GoalPlanningService.dateString(model.occurredAt),
            note: model.note, createdAt: GoalPlanningService.timestamp(model.createdAt ?? Date())
        )
    }

    private static func draftDTO(_ model: GoalAdjustmentDraftModel) -> GoalAdjustmentDraft {
        let payload = model.payload.values.reduce(into: [String: String]()) { result, item in
            switch item.value {
            case let .string(value): result[item.key] = value
            case let .number(value): result[item.key] = String(value)
            case let .bool(value): result[item.key] = String(value)
            default: break
            }
        }
        return .init(
            id: model.id?.uuidString ?? "", suggestionId: model.$suggestion.id.uuidString,
            destination: GoalAdjustmentDestination(rawValue: model.destination) ?? .goal,
            payload: payload, createdAt: GoalPlanningService.timestamp(model.createdAt ?? Date())
        )
    }
}
