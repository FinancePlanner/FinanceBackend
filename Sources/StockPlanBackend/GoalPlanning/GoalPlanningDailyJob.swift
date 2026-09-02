import Fluent
import Foundation
import NIOCore
import StockPlanShared
import Vapor

final class GoalPlanningDailyJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = GoalPlanningDailyJobState()

    init(intervalSeconds: Int64 = 86400) {
        self.intervalSeconds = max(300, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(120), delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                await self.runOnce(app)
            }
            self.state.set(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) {
        state.cancel()
    }

    func runOnce(_ app: Application) async {
        await JobLock.runAsLeader(app, name: "goal_planning_daily_job") { await self.runOnceAsLeader(app) }
    }

    func runOnceAsLeader(_ app: Application) async {
        let req = Request(application: app, on: app.eventLoopGroup.next())
        do {
            let goals = try await FinancialGoalModel.query(on: req.db)
                .filter(\.$status == FinancialGoalStatus.active.rawValue).all()
            for goal in goals where !Task.isCancelled {
                try await evaluate(goal, req: req)
            }
            try await pruneDailyHistory(on: req.db)
        } catch {
            app.logger.error("goal-planning daily evaluation failed error_type=\(String(reflecting: type(of: error)))")
        }
    }

    private func evaluate(_ goal: FinancialGoalModel, req: Request) async throws {
        guard let goalId = goal.id else { return }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        guard try await GoalProgressSnapshotModel.query(on: req.db)
            .filter(\.$goal.$id == goalId).filter(\.$calculatedAt >= startOfDay).first() == nil else { return }
        let prior = try await GoalProgressSnapshotModel.query(on: req.db)
            .filter(\.$goal.$id == goalId).sort(\.$calculatedAt, .descending).limit(2).all()
        let service = GoalPlanningService()
        let progress = try await service.progress(for: goal, userId: goal.userId, req: req)
        try await service.persistSnapshot(progress, goal: goal, userId: goal.userId, on: req.db)
        _ = try await service.suggestions(for: goal, userId: goal.userId, req: req)
        guard progress.warnings.isEmpty else { return }
        try await publishMilestoneIfNeeded(progress: progress, previous: prior.first, goal: goal, req: req)
        try await publishDriftIfNeeded(progress: progress, previous: prior, goal: goal, req: req)
    }

    private func publishMilestoneIfNeeded(
        progress: GoalProgress, previous: GoalProgressSnapshotModel?, goal: FinancialGoalModel, req: Request
    ) async throws {
        guard let goalId = goal.id else { return }
        let previousPercent = previous.map { $0.currentValue / goal.targetAmount } ?? 0
        guard let milestone = [0.25, 0.5, 0.75, 1.0].last(where: {
            previousPercent < $0 && progress.percentComplete >= $0
        }) else { return }
        let percent = Int(milestone * 100)
        _ = try await NotificationEventPublisher.publishAndPush(
            userId: goal.userId,
            kind: .financialGoal,
            deduplicationKey: "financial-goal:\(goalId):milestone:\(percent)",
            title: "\(goal.name): \(percent)% complete",
            body: "Your goal has reached a new progress milestone.",
            deepLink: "norviq://financial-goals/\(goalId.uuidString)",
            payload: ["goal_id": goalId.uuidString, "milestone": String(percent)],
            req: req
        )
    }

    private func publishDriftIfNeeded(
        progress: GoalProgress, previous: [GoalProgressSnapshotModel], goal: FinancialGoalModel, req: Request
    ) async throws {
        guard let goalId = goal.id, let latest = previous.first,
              latest.driftState == progress.driftState.rawValue,
              [.ahead, .behind].contains(progress.driftState)
        else { return }
        let period = String(GoalPlanningService.dateString(Date()).prefix(7))
        let title = progress.driftState == .behind ? "\(goal.name) needs attention" : "\(goal.name) is ahead"
        let body = progress.driftState == .behind
            ? "The plan has remained behind for two evaluations. Review deterministic adjustment options."
            : "The plan has remained ahead for two evaluations. You may have contribution headroom."
        _ = try await NotificationEventPublisher.publishAndPush(
            userId: goal.userId,
            kind: .financialGoal,
            deduplicationKey: "financial-goal:\(goalId):drift:\(progress.driftState.rawValue):\(period)",
            title: title,
            body: body,
            deepLink: "norviq://financial-goals/\(goalId.uuidString)",
            payload: ["goal_id": goalId.uuidString, "drift_state": progress.driftState.rawValue],
            req: req
        )
    }

    private func pruneDailyHistory(on db: any Database) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -400, to: Date()) ?? .distantPast
        try await GoalProgressSnapshotModel.query(on: db)
            .filter(\.$calculatedAt < cutoff).filter(\.$isMonthEnd == false).delete()
    }
}

private final class GoalPlanningDailyJobState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var task: Task<Void, Never>?
    private var running = false

    func begin() -> Bool {
        lock.withLock {
            if running {
                return false
            }; running = true; return true
        }
    }

    func set(scheduled: RepeatedTask) {
        lock.withLock { self.scheduled = scheduled }
    }

    func set(task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func finish() {
        lock.withLock { task = nil; running = false }
    }

    func cancel() {
        lock.withLock { scheduled?.cancel(); task?.cancel(); scheduled = nil; task = nil; running = false }
    }
}
