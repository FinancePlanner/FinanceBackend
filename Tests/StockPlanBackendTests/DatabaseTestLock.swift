import Foundation
import Testing

actor DatabaseTestMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

enum DatabaseTestLock {
    private static let mutex = DatabaseTestMutex()

    /// Re-entrancy: a suite scoped by `DatabaseLockedTrait` may contain tests
    /// that take the lock themselves; the task-local makes the inner call a
    /// no-op instead of a deadlock.
    @TaskLocal private static var isHeld = false

    static func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        if isHeld {
            return try await operation()
        }
        await mutex.acquire()
        do {
            let result = try await $isHeld.withValue(true) { try await operation() }
            await mutex.release()
            return result
        } catch {
            await mutex.release()
            throw error
        }
    }
}

/// Runs every test of a suite under `DatabaseTestLock`.
///
/// Suites that mutate the process environment (`setenv`/`unsetenv`) must not
/// overlap the app-booting suites, which read it through `Environment.get`:
/// glibc's `getenv` is not safe against a concurrent `setenv`, and CI on
/// Linux crashed with SIGSEGV in `AIModelRouterTests` (2026-09-03) exactly
/// that way. The DB suites already hold this lock while they boot, so taking
/// it here serialises the two groups against each other without slowing the
/// rest of the run.
struct DatabaseLockedTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func provideScope(
        for _: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // Scope is offered at suite, function, and case level; the mutex is
        // not re-entrant, so lock once, at the innermost (case) level.
        guard testCase != nil else {
            try await function()
            return
        }
        try await DatabaseTestLock.withLock {
            try await function()
        }
    }
}

extension Trait where Self == DatabaseLockedTrait {
    static var databaseLocked: Self {
        DatabaseLockedTrait()
    }
}
