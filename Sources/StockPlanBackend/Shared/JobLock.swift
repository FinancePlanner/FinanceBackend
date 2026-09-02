import Fluent
import FluentSQL
import Vapor

/// Process-level leader election for background pollers.
///
/// Every `LifecycleHandler` job in `configure.swift` runs on every replica.
/// With one pod that is invisible; with two, every push notification is sent
/// twice, every paid market-data or AI refresh is paid twice, and two ticks
/// race to write the same rows. A Postgres session advisory lock keyed on the
/// job name makes exactly one replica the leader for the duration of a tick,
/// with no extra infrastructure and automatic release if the pod dies (the
/// lock goes with the connection).
///
/// Fail-open by design: if the lock cannot be taken because the database is
/// unreachable or is not SQL, the tick still runs and a warning is logged. A
/// database outage already breaks the job; silently skipping it forever would
/// be the worse failure.
enum JobLock {
    /// Runs `body` only if this process wins the advisory lock for `name`.
    /// Returns `true` when the body ran, `false` when another replica held it.
    @discardableResult
    static func runAsLeader(
        _ app: Application,
        name: String,
        _ body: @escaping @Sendable () async -> Void
    ) async -> Bool {
        do {
            return try await app.db.withConnection { conn -> Bool in
                guard let sql = conn as? any SQLDatabase else {
                    await body()
                    return true
                }
                let row = try await sql.raw("SELECT pg_try_advisory_lock(hashtext(\(bind: name))) AS acquired").first()
                let acquired = try row?.decode(column: "acquired", as: Bool.self) ?? false
                guard acquired else {
                    app.logger.debug("job_lock skipped: another replica leads", metadata: ["job": .string(name)])
                    return false
                }
                await body()
                // Release on the same connection, before it goes back to the pool.
                // A failed unlock is not actionable: the lock dies with the session.
                _ = try? await sql.raw("SELECT pg_advisory_unlock(hashtext(\(bind: name)))").run()
                return true
            }
        } catch {
            app.logger.warning(
                "job_lock unavailable; running without leader election",
                metadata: ["job": .string(name), "error": .string(String(reflecting: type(of: error)))]
            )
            await body()
            return true
        }
    }
}
