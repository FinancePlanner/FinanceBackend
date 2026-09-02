import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

/// Periodically refreshes macro snapshots/series into Postgres + Redis.
/// Mirrors HermesSyncJob: repeated task on an event loop, overlap guard,
/// shutdown hook, `runOnce` for tests. The tick interval is short; each
/// country only actually refreshes once its own cadence has elapsed
/// (US ~4x/day for the daily gauge, intl daily against monthly prints).
final class MacroRefreshJob: LifecycleHandler, @unchecked Sendable {
    private let tickIntervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let usRefreshSeconds: TimeInterval
    private let intlRefreshSeconds: TimeInterval
    private let state = MacroRefreshJobState()

    init(
        tickIntervalSeconds: Int64,
        usRefreshSeconds: TimeInterval,
        intlRefreshSeconds: TimeInterval,
        initialDelaySeconds: Int64 = 20
    ) {
        self.tickIntervalSeconds = max(tickIntervalSeconds, 300)
        self.usRefreshSeconds = max(usRefreshSeconds, 600)
        self.intlRefreshSeconds = max(intlRefreshSeconds, 600)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        // Tests boot and shut down an application per suite, far faster than a
        // refresh cycle takes. Scheduling live upstream fetches there races
        // teardown for no benefit; the tests that exercise this job call
        // `runOnce` directly.
        guard app.environment != .testing else {
            app.logger.debug("macro_refresh not scheduled in testing environment")
            return
        }
        let countries = app.macroProviderRegistry.enabledCountries
        guard !countries.isEmpty else {
            app.logger.info("macro_refresh disabled: no macro providers configured (set FRED_API_KEY and/or MACRO_ENABLED)")
            return
        }
        app.logger.info("macro_refresh scheduled countries=\(countries.map(\.rawValue).joined(separator: ",")) tick=\(tickIntervalSeconds)s")

        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(tickIntervalSeconds)
        ) { _ in
            guard self.state.beginRun() else {
                app.logger.debug("macro_refresh skipped overlapping tick")
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

    func runOnce(_ app: Application, force: Bool = false) async {
        await tick(app, force: force)
    }

    private func cadence(for country: MacroCountry) -> TimeInterval {
        country == .us ? usRefreshSeconds : intlRefreshSeconds
    }

    private func tick(_ app: Application, force: Bool = false) async {
        await JobLock.runAsLeader(app, name: "macro_refresh_job") { await self.tickAsLeader(app, force: force) }
    }

    private func tickAsLeader(_ app: Application, force: Bool = false) async {
        let now = Date()
        for country in app.macroProviderRegistry.enabledCountries {
            // Task cancellation is cooperative: `shutdown` cancels this task,
            // but without this check the loop would carry on to the next
            // country and build a `Request` against an application whose
            // clients and databases are already torn down, which traps.
            if Task.isCancelled {
                app.logger.info("macro_refresh cancelled; stopping before \(country.rawValue)")
                return
            }
            if !force,
               let last = app.macroSyncStatus.lastSuccessAt(country),
               now.timeIntervalSince(last) < cadence(for: country)
            {
                continue
            }
            let req = Request(application: app, on: app.eventLoopGroup.next())
            do {
                let snapshot = try await app.macroService.refresh(country: country, on: req)
                app.macroSyncStatus.recordSuccess(country)
                app.logger.info("macro_refresh ok country=\(country.rawValue) as_of=\(snapshot.asOf)")
            } catch {
                // Per-country isolation: one failing source never blocks the rest.
                // PSQLError's describing form hides all detail; use the debug
                // reflection outside production (it may embed query text).
                let detail = app.environment == .production
                    ? String(describing: error)
                    : String(reflecting: error)
                app.logger.warning("macro_refresh failed country=\(country.rawValue) error=\(detail)")
            }
        }
    }
}

private final class MacroRefreshJobState: @unchecked Sendable {
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

/// Tracks the last successful refresh per country so the readiness endpoint
/// can report a degraded (never failing) `macro` check.
final class MacroSyncStatus: Sendable {
    private let lastSuccess = NIOLockedValueBox<[String: Date]>([:])

    func recordSuccess(_ country: MacroCountry) {
        lastSuccess.withLockedValue { $0[country.rawValue] = Date() }
    }

    func lastSuccessAt(_ country: MacroCountry) -> Date? {
        lastSuccess.withLockedValue { $0[country.rawValue] }
    }

    var all: [String: Date] {
        lastSuccess.withLockedValue { $0 }
    }
}
