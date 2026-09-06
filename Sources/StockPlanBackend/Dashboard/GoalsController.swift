import Fluent
import Foundation
import StockPlanShared
import Vapor

struct GoalsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let goals = protected.grouped("goals")
        let readable = goals.grouped(ScopeRequirementMiddleware(.goalsRead))
        let writable = goals.grouped(ScopeRequirementMiddleware(.goalsWrite))

        readable.get(use: index)
        writable.post(use: create)
        readable.get(":id", use: show)
        writable.patch(":id", use: update)
        writable.patch(":id", "status", use: updateStatus)
        writable.delete(":id", use: delete)
    }

    @Sendable
    func index(req: Request) async throws -> [GoalResponse] {
        let session = try req.auth.require(SessionToken.self)

        let manualGoals = try await Goal.owned(by: session.userId, on: req.db)
            .sort(\.$createdAt, .descending)
            .all()
            .map { $0.toDTO() }

        // System Evaluated Goals
        let systemGoals = try await evaluateSystemGoals(userId: session.userId, on: req.db)

        return systemGoals + manualGoals
    }

    private func evaluateSystemGoals(userId: UUID, on db: any Database) async throws -> [GoalResponse] {
        var systemGoals: [GoalResponse] = []
        let formatter = ISO8601DateFormatter()
        let nowString = formatter.string(from: Date())

        // Goal 1: Build a Watchlist
        let watchlistCount = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$status != WatchlistStatus.archived.rawValue)
            .count()

        let isWatchlistCompleted = watchlistCount >= 3
        systemGoals.append(GoalResponse(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!.uuidString,
            title: "Add 3 stocks to your Watchlist (\(watchlistCount)/3)",
            status: isWatchlistCompleted ? .completed : .pending,
            statusUpdatedBy: .system,
            completedAt: isWatchlistCompleted ? nowString : nil,
            createdAt: nil,
            updatedAt: nowString
        ))

        // Goal 2: Set up a Monthly Budget
        let budgetCount = try await BudgetSnapshot.query(on: db)
            .filter(\.$user.$id == userId)
            .count()

        let isBudgetCompleted = budgetCount >= 1
        systemGoals.append(GoalResponse(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!.uuidString,
            title: "Set up your first monthly budget",
            status: isBudgetCompleted ? .completed : .pending,
            statusUpdatedBy: .system,
            completedAt: isBudgetCompleted ? nowString : nil,
            createdAt: nil,
            updatedAt: nowString
        ))

        // Goal 3: Log an Expense
        let expenseCount = try await Expense.query(on: db)
            .filter(\.$user.$id == userId)
            .count()

        let isExpenseCompleted = expenseCount >= 1
        systemGoals.append(GoalResponse(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!.uuidString,
            title: "Log your first expense",
            status: isExpenseCompleted ? .completed : .pending,
            statusUpdatedBy: .system,
            completedAt: isExpenseCompleted ? nowString : nil,
            createdAt: nil,
            updatedAt: nowString
        ))

        return systemGoals
    }

    @Sendable
    func create(req: Request) async throws -> GoalResponse {
        let session = try req.auth.require(SessionToken.self)
        let requestDTO = try req.content.decode(GoalRequest.self)
        let goal = try await Goal.create(title: requestDTO.title, userId: session.userId, on: req.db)
        return goal.toDTO()
    }

    @Sendable
    func show(req: Request) async throws -> GoalResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let id = req.parameters.get("id", as: UUID.self),
              let goal = try await Goal.find(id, userId: session.userId, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return goal.toDTO()
    }

    @Sendable
    func update(req: Request) async throws -> GoalResponse {
        let session = try req.auth.require(SessionToken.self)
        let requestDTO = try req.content.decode(GoalRequest.self)
        guard let id = req.parameters.get("id", as: UUID.self),
              let goal = try await Goal.find(id, userId: session.userId, on: req.db)
        else {
            throw Abort(.notFound)
        }
        goal.title = requestDTO.title
        try await goal.save(on: req.db)
        return goal.toDTO()
    }

    @Sendable
    func updateStatus(req: Request) async throws -> GoalResponse {
        let session = try req.auth.require(SessionToken.self)
        let requestDTO = try req.content.decode(GoalStatusUpdateRequest.self)
        guard let id = req.parameters.get("id", as: UUID.self),
              let goal = try await Goal.find(id, userId: session.userId, on: req.db)
        else {
            throw Abort(.notFound)
        }

        goal.status = requestDTO.status.rawValue
        goal.statusUpdatedBy = requestDTO.source.rawValue
        goal.completedAt = requestDTO.status == .completed ? Date() : nil

        try await goal.save(on: req.db)
        return goal.toDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> EmptyAPIResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let id = req.parameters.get("id", as: UUID.self),
              let goal = try await Goal.find(id, userId: session.userId, on: req.db)
        else {
            throw Abort(.notFound)
        }
        try await goal.delete(on: req.db)
        return EmptyAPIResponse()
    }
}

extension Goal {
    func toDTO() -> GoalResponse {
        let formatter = ISO8601DateFormatter()
        return GoalResponse(
            id: id!.uuidString,
            title: title,
            status: GoalStatus(rawValue: status) ?? .pending,
            statusUpdatedBy: statusUpdatedBy.flatMap { GoalStatusSource(rawValue: $0) },
            completedAt: completedAt.map { formatter.string(from: $0) },
            createdAt: createdAt.map { formatter.string(from: $0) },
            updatedAt: updatedAt.map { formatter.string(from: $0) }
        )
    }
}
