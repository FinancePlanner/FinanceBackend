import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

/// Runs the daily sentiment roll-up.
///
/// Structurally a sibling of `HermesSyncJob` — repeated task on an event loop,
/// overlap guard, shutdown hook — because this codebase has no queue package and
/// no cron. The daily cadence is built on top of an hourly tick: the job wakes
/// every hour and does nothing unless the target hour has passed and it has not
/// already completed a run for today's UTC date. That survives restarts, which a
/// naive 24-hour interval does not — a pod that restarts at 04:00 every day
/// would otherwise never reach its first tick.
final class SentimentAggregationJob: LifecycleHandler, @unchecked Sendable {
    private let tickIntervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let targetHourUTC: Int
    private let state = SentimentAggregationJobState()

    init(
        tickIntervalSeconds: Int64 = 3600,
        initialDelaySeconds: Int64 = 120,
        targetHourUTC: Int = 5
    ) {
        self.tickIntervalSeconds = max(tickIntervalSeconds, 60)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
        self.targetHourUTC = min(max(targetHourUTC, 0), 23)
    }

    func didBoot(_ app: Application) throws {
        guard app.environment != .testing else { return }
        guard app.insightsService.isEnabled else {
            app.logger.info("sentiment_aggregation disabled: no insights provider configured")
            return
        }

        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(tickIntervalSeconds)
        ) { _ in
            guard self.state.beginRun() else {
                app.logger.debug("sentiment_aggregation skipped overlapping tick")
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

    /// Forces a run regardless of the clock or today's completion marker. Used
    /// by the admin endpoint and by tests.
    func runOnce(_ app: Application) async {
        await execute(app)
    }

    private func tick(_ app: Application) async {
        let today = SentimentDate.today()
        guard state.lastCompletedDate() != today else { return }
        guard Self.currentHourUTC() >= targetHourUTC else { return }

        await execute(app)
    }

    private func execute(_ app: Application) async {
        await JobLock.runAsLeader(app, name: "sentiment_aggregation_job") { await self.executeAsLeader(app) }
    }

    private func executeAsLeader(_ app: Application) async {
        let req = Request(application: app, on: app.eventLoopGroup.next())
        do {
            let summary = try await app.sentimentAggregationService.runDailyAggregation(on: req)
            state.recordCompleted(summary.asOfDate)
            app.sentimentSyncStatus.recordSuccess()
            app.logger.info(
                """
                sentiment_aggregation ok date=\(summary.asOfDate) \
                considered=\(summary.symbolsConsidered) ingested=\(summary.symbolsIngested) \
                failed=\(summary.symbolsFailed) posts_fetched=\(summary.postsFetched) \
                posts_inserted=\(summary.postsInserted) rows=\(summary.rowsUpserted) \
                themes=\(summary.themesGenerated) themes_skipped=\(summary.themesSkipped)
                """
            )
        } catch {
            // Not marked complete: the next tick retries rather than skipping
            // the day outright.
            app.logger.error("sentiment_aggregation failed error=\(String(describing: error))")
        }
    }

    static func currentHourUTC(now: Date = Date()) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.component(.hour, from: now)
    }
}

private final class SentimentAggregationJobState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var currentTask: Task<Void, Never>?
    private var isRunning = false
    private var completedDate: String?

    func setScheduled(_ scheduled: RepeatedTask) {
        lock.lock()
        self.scheduled?.cancel()
        self.scheduled = scheduled
        lock.unlock()
    }

    func beginRun() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return false }
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

    func recordCompleted(_ date: String) {
        lock.lock()
        completedDate = date
        lock.unlock()
    }

    func lastCompletedDate() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return completedDate
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

/// Prunes raw posts and stale aggregates.
///
/// `ticker_sentiment_posts`, `sentiment_snapshots` and `insight_events` had no
/// retention at all, in a codebase that retires scenario runs, assistant
/// transcripts and expense imports on a timer. Post text is unbounded, and the
/// universe expansion multiplies the daily row count by roughly forty, so this
/// is load-bearing rather than tidying.
final class SentimentRetentionJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let postRetentionDays: Int
    private let dailyRetentionDays: Int
    private let state = SentimentAggregationJobState()

    init(intervalSeconds: Int64 = 86400, postRetentionDays: Int = 90, dailyRetentionDays: Int = 730) {
        self.intervalSeconds = max(intervalSeconds, 3600)
        self.postRetentionDays = max(postRetentionDays, 7)
        self.dailyRetentionDays = max(dailyRetentionDays, 30)
    }

    func didBoot(_ app: Application) throws {
        // Never schedule under .testing. A test app migrates and reverts its
        // schema inside one process; a timer that outlives a suite and then
        // deletes from tables that no longer exist turns an unrelated test into
        // a crash. The job is still exercised directly via runOnce.
        guard app.environment != .testing else { return }

        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(600),
            delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.beginRun() else { return }
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
        let postCutoff = Date().addingTimeInterval(-Double(postRetentionDays) * 86400)
        let dailyCutoff = SentimentDate.daysAgo(dailyRetentionDays)
        do {
            let posts = try await app.sentimentRepository.deletePosts(olderThan: postCutoff, on: app.db)
            let rows = try await app.sentimentRepository.deleteDaily(olderThan: dailyCutoff, on: app.db)
            if posts > 0 || rows > 0 {
                app.logger.info("sentiment_retention pruned posts=\(posts) daily_rows=\(rows)")
            }
        } catch {
            app.logger.error("sentiment_retention failed error=\(String(describing: error))")
        }
    }
}

/// Last successful aggregation, for the readiness endpoint.
final class SentimentSyncStatus: Sendable {
    private let lastSuccess = NIOLockedValueBox<Date?>(nil)

    func recordSuccess() {
        lastSuccess.withLockedValue { $0 = Date() }
    }

    var lastSuccessAt: Date? {
        lastSuccess.withLockedValue { $0 }
    }
}
