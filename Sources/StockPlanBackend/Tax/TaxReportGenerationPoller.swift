import Fluent
import Foundation
import NIOCore
import Vapor

final class TaxReportGenerationPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = TaxReportGenerationPollerState()

    init(intervalSeconds: Int64 = 10) {
        self.intervalSeconds = max(5, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        // Test applications boot and shut down in about a second -- less than
        // this poller's one-second initial delay -- so a scheduled tick only
        // races teardown. It reaches `app.db` after the databases are disposed
        // and traps in `FluentProvider.swift:48`, taking the whole test process
        // with it partway through a run. That failure reddened CI on #146,
        // on the post-merge run for #147, and on #149, each time for reasons
        // unrelated to the change under test.
        //
        // Same fix, and the same reasoning, as `MacroRefreshJob` in a08a73b.
        // The tests that exercise this poller call `runOnce` directly.
        guard app.environment != .testing else {
            app.logger.debug("tax_report_poller not scheduled in testing environment")
            return
        }
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(1),
            delay: .seconds(intervalSeconds)
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
        do {
            // Cancellation is cooperative, and `shutdown` cancels this task --
            // but the first thing below reaches for a database. Without this
            // check a tick that started just before teardown traps instead of
            // returning.
            try Task.checkCancellation()
            let candidates = try await TaxReport.query(on: app.db)
                .filter(\.$status ~~ ["pending", "retry", "generating"])
                .sort(\.$createdAt, .ascending)
                .limit(25)
                .all()
            let now = Date()
            for report in candidates where report.nextAttemptAt.map({ $0 <= now }) ?? true {
                try Task.checkCancellation()
                try await process(report, app: app)
            }
        } catch is CancellationError {
            return
        } catch {
            app.logger.error("tax_report.poll_failed error=\(error)")
        }
    }

    private func process(_ report: TaxReport, app: Application) async throws {
        guard let reportID = report.id else { return }
        let attempt = (report.attemptCount ?? 0) + 1
        report.status = "generating"
        report.attemptCount = attempt
        report.nextAttemptAt = nil
        try await report.save(on: app.db)
        app.logger.info("tax_report.generation_started report_id=\(reportID) attempt=\(attempt)")

        await app.taxReportGenerator.generate(reportID: reportID, application: app)
        guard let refreshed = try await TaxReport.find(reportID, on: app.db) else { return }
        if refreshed.status == "ready" {
            refreshed.nextAttemptAt = nil
            try await refreshed.save(on: app.db)
            app.logger.info("tax_report.generation_completed report_id=\(reportID) attempt=\(attempt)")
            return
        }

        if attempt >= 5 {
            refreshed.status = "failed"
            refreshed.nextAttemptAt = nil
            try await refreshed.save(on: app.db)
            app.logger.error("tax_report.generation_exhausted report_id=\(reportID) attempts=\(attempt)")
            return
        }

        let delay = Self.retryDelaySeconds(for: attempt)
        refreshed.status = "retry"
        refreshed.nextAttemptAt = Date().addingTimeInterval(TimeInterval(delay))
        try await refreshed.save(on: app.db)
        app.logger.warning(
            "tax_report.generation_retry report_id=\(reportID) attempt=\(attempt) delay_seconds=\(delay)"
        )
    }

    static func retryDelaySeconds(for attempt: Int) -> Int {
        min(3600, 30 * (1 << max(0, attempt - 1)))
    }
}

private final class TaxReportGenerationPollerState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var task: Task<Void, Never>?
    private var running = false

    func begin() -> Bool {
        lock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
    }

    func finish() {
        lock.withLock {
            running = false
            task = nil
        }
    }

    func set(scheduled: RepeatedTask) {
        lock.withLock { self.scheduled = scheduled }
    }

    func set(task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        lock.withLock {
            scheduled?.cancel()
            task?.cancel()
            scheduled = nil
            task = nil
            running = false
        }
    }
}
