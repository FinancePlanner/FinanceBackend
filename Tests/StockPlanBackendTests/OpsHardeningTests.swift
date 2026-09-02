import Fluent
import FluentSQL
import Foundation
import Redis
@testable import StockPlanBackend
import Testing
import VaporTesting

@Suite("Ops hardening", .serialized)
struct OpsHardeningTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            if let url = Environment.get("REDIS_URL"), !url.isEmpty {
                // configure() leaves Redis off under .testing; the TTL test needs a real one,
                // and RedisKit only builds its pools for configurations present at boot.
                app.redis.configuration = try RedisConfiguration(url: url)
            }
            try await configure(app)
            try await app.autoMigrate()
            // RedisKit builds its pools in didBoot; nothing in these tests sends a
            // request, so boot explicitly before touching app.redis.
            try await app.asyncBoot()
            try await test(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Second concurrent leader attempt for the same job is refused while the first runs")
    func jobLockRefusesConcurrentLeader() async throws {
        try await withApp { app in
            let name = "ops-hardening-\(UUID().uuidString)"
            let results = await withTaskGroup(of: (String, Bool).self, returning: [String: Bool].self) { group in
                group.addTask {
                    let ran = await JobLock.runAsLeader(app, name: name) {
                        try? await Task.sleep(for: .milliseconds(600))
                    }
                    return ("first", ran)
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(150))
                    let ran = await JobLock.runAsLeader(app, name: name) {}
                    return ("second", ran)
                }
                var out: [String: Bool] = [:]
                for await (label, ran) in group {
                    out[label] = ran
                }
                return out
            }
            #expect(results["first"] == true)
            #expect(results["second"] == false)

            // Once the first tick finishes the lock is released and a new tick leads.
            let again = await JobLock.runAsLeader(app, name: name) {}
            #expect(again == true)
        }
    }

    @Test("Different job names do not contend")
    func jobLockIsPerName() async throws {
        try await withApp { app in
            let a = await JobLock.runAsLeader(app, name: "ops-a-\(UUID())") {
                let b = await JobLock.runAsLeader(app, name: "ops-b-\(UUID())") {}
                #expect(b == true)
            }
            #expect(a == true)
        }
    }

    @Test("Rate limit bucket always carries a TTL")
    func rateLimitBucketAlwaysHasTTL() async throws {
        try await withApp { app in
            guard app.redis.configuration != nil else {
                Issue.record("REDIS_URL not set: rate-limit TTL test needs a Redis; run with REDIS_URL=redis://127.0.0.1:6379")
                return
            }
            let key = RedisKey("ratelimit-test:\(UUID().uuidString)")
            let first = try await RateLimitMiddleware.incrementWithWindow(key, interval: 60, on: app.redis)
            let ttlAfterFirst = try await app.redis.ttl(key).get()
            let second = try await RateLimitMiddleware.incrementWithWindow(key, interval: 60, on: app.redis)
            let ttlAfterSecond = try await app.redis.ttl(key).get()
            _ = try await app.redis.delete(key).get()

            #expect(first == 1)
            #expect(second == 2)
            #expect(ttlAfterFirst.timeAmount != nil, "bucket must expire after the first hit")
            #expect(ttlAfterSecond.timeAmount != nil, "bucket must still expire after later hits")
        }
    }

    @Test("Expense hot-path indexes exist after migration")
    func expenseIndexesExist() async throws {
        try await withApp { app in
            guard let sql = app.db as? any SQLDatabase else { return }
            let rows = try await sql.raw("SELECT indexname FROM pg_indexes WHERE indexname LIKE 'idx_expenses_user_occurred_on' OR indexname LIKE 'idx_budget_plan_items_user_snapshot' OR indexname LIKE 'idx_dividends_account_external_id'").all()
            let names = try rows.map { try $0.decode(column: "indexname", as: String.self) }
            #expect(Set(names) == ["idx_expenses_user_occurred_on", "idx_budget_plan_items_user_snapshot", "idx_dividends_account_external_id"])
        }
    }
}
