import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

/// Periodically pulls Hermes finance data into Postgres. Mirrors
/// TargetAlertPoller: repeated task on an event loop, overlap guard, and a
/// shutdown hook. Skips scheduling entirely when the provider is disabled.
final class HermesSyncJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let state = HermesSyncJobState()

    init(intervalSeconds: Int64, initialDelaySeconds: Int64 = 30) {
        self.intervalSeconds = max(intervalSeconds, 60)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        guard app.insightsService.isEnabled else {
            app.logger.info("hermes_sync disabled: HERMES_BASE_URL is not configured")
            return
        }

        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.beginRun() else {
                app.logger.debug("hermes_sync skipped overlapping tick")
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
        let req = Request(application: app, on: app.eventLoopGroup.next())
        do {
            let summary = try await app.insightsService.syncFromHermes(on: req)
            app.insightsSyncStatus.recordSuccess()
            app.logger.info(
                "hermes_sync ok events=\(summary.eventsInserted) snapshots=\(summary.snapshotsUpserted) ticker_posts=\(summary.tickerPostsInserted) net_worth=\(summary.netWorthInserted)"
            )
        } catch {
            // String(reflecting:) — PSQLError's description is deliberately
            // opaque, which cost a full debugging cycle here.
            app.logger.warning("hermes_sync failed error=\(String(reflecting: error))")
        }
    }
}

private final class HermesSyncJobState: @unchecked Sendable {
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

/// Tracks the last successful Hermes sync so the readiness endpoint can report
/// a degraded (but never failing) `hermes` check.
final class InsightsSyncStatus: Sendable {
    private let lastSuccess = NIOLockedValueBox<Date?>(nil)

    func recordSuccess() {
        lastSuccess.withLockedValue { $0 = Date() }
    }

    var lastSuccessAt: Date? {
        lastSuccess.withLockedValue { $0 }
    }
}
