import Foundation
import NIOCore
import Vapor

final class EarningsNotificationPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let state = EarningsNotificationPollerState()

    init(intervalSeconds: Int64 = 86400, initialDelaySeconds: Int64 = 60) {
        self.intervalSeconds = max(intervalSeconds, 3600)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.beginRun() else {
                app.logger.debug("earnings_notification_poller skipped overlapping tick")
                return
            }
            let task = Task {
                defer { self.state.finishRun() }
                await self.tick(app)
            }
            self.state.setCurrentTask(task)
        }
        state.setScheduled(scheduled)
    }

    func shutdown(_: Application) {
        state.cancelAll()
    }

    func runOnce(_ app: Application) async {
        await tick(app)
    }

    private func tick(_ app: Application) async {
        await JobLock.runAsLeader(app, name: "earnings_notification_poller") { await self.tickAsLeader(app) }
    }

    private func tickAsLeader(_ app: Application) async {
        let req = Request(application: app, on: app.eventLoopGroup.next())
        await app.earningsNotificationEvaluator.evaluateUpcomingEarnings(req: req)
    }
}

private final class EarningsNotificationPollerState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var currentTask: Task<Void, Never>?
    private var isRunning = false

    func setScheduled(_ scheduled: RepeatedTask) {
        lock.lock()
        self.scheduled?.cancel()
        self.scheduled = scheduled
        lock.unlock()
    }

    func beginRun() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else {
            return false
        }
        isRunning = true
        return true
    }

    func setCurrentTask(_ task: Task<Void, Never>) {
        lock.lock()
        currentTask = task
        lock.unlock()
    }

    func finishRun() {
        lock.lock()
        currentTask = nil
        isRunning = false
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        scheduled?.cancel()
        scheduled = nil
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        lock.unlock()
    }
}
