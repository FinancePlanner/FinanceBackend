import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

/// Periodically refreshes portfolio/watchlist news for the global union of tracked
/// symbols (fetch once per symbol, fan out only to users who hold/watch it).
/// Mirrors HermesSyncJob: repeated task, overlap guard, shutdown cancel.
final class NewsSyncJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let state = NewsSyncJobState()

    init(intervalSeconds: Int64, initialDelaySeconds: Int64 = 45) {
        self.intervalSeconds = max(intervalSeconds, 60)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        let disabled = (Environment.get("NEWS_SYNC_JOB_ENABLED") ?? "true")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if disabled == "false" || disabled == "0" || disabled == "no" {
            app.logger.info("news_sync disabled: NEWS_SYNC_JOB_ENABLED=false")
            return
        }

        // Provider is optional; skip scheduling when nothing is configured.
        // DefaultNewsService still throws on sync if provider is nil.
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.beginRun() else {
                app.logger.debug("news_sync skipped overlapping tick")
                return
            }
            let task = Task {
                defer { self.state.finishRun() }
                await self.tick(app)
            }
            self.state.setCurrentTask(task)
        }
        state.setScheduled(scheduled)
        app.logger.info("news_sync scheduled interval=\(intervalSeconds)s initial_delay=\(initialDelaySeconds)s")
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
            let summary = try await app.newsService.syncGlobalNews(on: req)
            app.logger.info(
                "news_sync ok provider=\(summary.provider) symbols=\(summary.symbolsCount) fetched=\(summary.fetchedCount) inserted=\(summary.insertedCount) updated=\(summary.updatedCount) skipped=\(summary.skippedCount)"
            )
        } catch {
            // notImplemented when no provider configured is expected in local/dev.
            if let abort = error as? Abort, abort.status == .notImplemented {
                app.logger.debug("news_sync skipped: provider not configured")
                return
            }
            app.logger.warning("news_sync failed error=\(String(describing: error))")
        }
    }
}

private final class NewsSyncJobState: @unchecked Sendable {
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
