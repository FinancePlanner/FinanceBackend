import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Periodic reconcile sync for bank connections. For Plaid, webhooks drive
/// real-time updates and this is the missed-webhook backstop; for GoCardless
/// (Phase 4) it becomes the primary poller. Provider-aware so each aggregator's
/// cadence and rate limits can differ.
struct BankSyncJob: LifecycleHandler {
    private let state = BankSyncJobState()

    /// Default reconcile interval (6 hours) unless BANK_SYNC_INTERVAL overrides.
    private var intervalSeconds: Double {
        Environment.get("BANK_SYNC_INTERVAL").flatMap(Double.init) ?? (6 * 3600)
    }

    func didBoot(_ app: Application) async throws {
        app.logger.info("bank_sync_job starting")
        let interval = intervalSeconds
        let task = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
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
        await JobLock.runAsLeader(app, name: "bank_sync_job") { await runSyncAsLeader(app: app) }
    }

    private func runSyncAsLeader(app: Application) async {
        do {
            let connections = try await BankConnection.query(on: app.db)
                .filter(\.$status == BankConnectionStatus.active.rawValue)
                .all()
            app.logger.info("bank_sync_job reconcile connections=\(connections.count)")

            for connection in connections {
                guard let kind = BankProviderKind(rawValue: connection.provider) else { continue }

                // GoCardless consent lasts 90 days; flag connections within a week
                // of expiry so clients can prompt a re-link before sync breaks.
                if let expiry = connection.consentExpiresAt, expiry <= Date().addingTimeInterval(7 * 86400) {
                    connection.status = BankConnectionStatus.reauthRequired.rawValue
                    connection.lastSyncStatus = "consent_expiring"
                    connection.updatedAt = Date()
                    try? await connection.save(on: app.db)
                    continue
                }

                do {
                    let provider = try app.bankProviderRegistry.provider(for: kind)
                    let req = Request(application: app, on: app.eventLoopGroup.any())
                    _ = try await provider.sync(connection: connection, on: req)
                } catch {
                    app.logger.error("bank_sync_job sync failed", metadata: [
                        "connection_id": .string(connection.id?.uuidString ?? "?"),
                        "error": .string(error.localizedDescription),
                    ])
                    connection.lastSyncStatus = "error"
                    connection.lastSyncError = error.localizedDescription
                    connection.updatedAt = Date()
                    try? await connection.save(on: app.db)
                }
            }
        } catch {
            app.logger.error("bank_sync_job error=\(error)")
        }
    }

    func shutdown(_ app: Application) async {
        state.cancelTask()
        app.logger.info("bank_sync_job shutdown")
    }
}

private final class BankSyncJobState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func setTask(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
    }

    func cancelTask() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
    }
}
