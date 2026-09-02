import Fluent
import Foundation
import Vapor

struct IBKRSyncJob: LifecycleHandler {
    private let state = IBKRSyncJobState()

    func willBoot(_: Application) async throws {
        // Job scheduled to run
    }

    func didBoot(_ app: Application) async throws {
        app.logger.info("ibkr_sync_job starting")
        scheduleJob(app: app)
    }

    private func scheduleJob(app: Application) {
        let task = Task {
            while !Task.isCancelled {
                let now = Date()
                let calendar = Calendar.current
                let targetHour = 6
                let targetMinute = 0

                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
                components.hour = targetHour
                components.minute = targetMinute
                components.second = 0

                guard var nextRun = calendar.date(from: components) else {
                    app.logger.error("ibkr_sync_job failed to calculate next run time")
                    break
                }

                if nextRun <= now {
                    nextRun = calendar.date(byAdding: .day, value: 1, to: nextRun) ?? nextRun
                }

                let delay = nextRun.timeIntervalSince(now)
                app.logger.info("ibkr_sync_job next_run=\(nextRun) delay_seconds=\(Int(delay))")

                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch is CancellationError {
                    break
                } catch {
                    app.logger.error("ibkr_sync_job sleep_error=\(error)")
                    break
                }

                if Task.isCancelled {
                    break
                }

                await runSync(app: app)
            }
        }
        state.setTask(task)
    }

    private func runSync(app: Application) async {
        await JobLock.runAsLeader(app, name: "ibkr_sync_job") { await runSyncAsLeader(app: app) }
    }

    private func runSyncAsLeader(app: Application) async {
        app.logger.info("ibkr_sync_job starting scheduled sync")

        do {
            let connections = try await BrokerConnection.query(on: app.db)
                .filter(\.$provider == "ibkr")
                .filter(\.$status == "connected")
                .all()

            app.logger.info("ibkr_sync_job found \(connections.count) active IBKR connections")

            var successCount = 0
            var failureCount = 0

            for connection in connections {
                let userId = connection.userId

                do {
                    let req = Request(application: app, on: app.eventLoopGroup.any())
                    let result = try await app.brokersService.syncIBKR(userId: userId, on: req)

                    app.logger.info("ibkr_sync_job sync completed", metadata: [
                        "user_id": .string(userId.uuidString),
                        "inserted": .string("\(result.inserted)"),
                        "updated": .string("\(result.updated)"),
                        "removed": .string("\(result.removed)"),
                    ])
                    successCount += 1
                } catch {
                    app.logger.error("ibkr_sync_job sync failed", metadata: [
                        "user_id": .string(userId.uuidString),
                        "error": .string(error.localizedDescription),
                    ])
                    failureCount += 1

                    connection.status = "error"
                    connection.statusDetail = error.localizedDescription
                    connection.updatedAt = Date()
                    try? await connection.save(on: app.db)
                }
            }

            app.logger.info("ibkr_sync_job completed", metadata: [
                "total": .string("\(connections.count)"),
                "success": .string("\(successCount)"),
                "failure": .string("\(failureCount)"),
            ])
        } catch {
            app.logger.error("ibkr_sync_job error=\(error)")
        }
    }

    func shutdown(_ app: Application) async {
        state.cancelTask()
        app.logger.info("ibkr_sync_job shutdown")
    }
}

private final class IBKRSyncJobState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
    }

    func cancelTask() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        task = nil
    }
}
