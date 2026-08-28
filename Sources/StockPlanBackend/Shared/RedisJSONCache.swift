import Foundation
import NIOConcurrencyHelpers
import Redis
import RediStack
import Vapor

/// A soft-failing JSON cache for generated content.
///
/// "Soft-failing" is the whole contract: every operation degrades to a miss
/// rather than throwing. A cache exists here to keep a second identical
/// question from costing a second LLM call, so an unreachable Redis must mean
/// "pay again", never "fail the request". Callers are written to that
/// assumption and do not handle errors from it.
///
/// A protocol rather than free functions because the interesting behaviour —
/// that a second read is a hit and costs no upstream call — cannot otherwise be
/// asserted without a live Redis, and the suite has no guaranteed one.
protocol AIResponseCache: Sendable {
    func get<T: Decodable>(_ key: String, as type: T.Type, on req: Request) async -> T?
    func set(_ key: String, value: some Encodable, ttlSeconds: Int, on req: Request) async
}

extension AIResponseCache {
    /// Lets a caller lean on the return type instead of naming it twice.
    func get<T: Decodable>(_ key: String, on req: Request) async -> T? {
        await get(key, as: T.self, on: req)
    }
}

/// The production cache. No-ops entirely when Redis is not configured.
struct RedisJSONCache: AIResponseCache {
    /// Prefixes the log lines so a degraded cache is attributable to a feature
    /// rather than to "something, somewhere, uses Redis".
    let label: String

    func get<T: Decodable>(_ key: String, as _: T.Type, on req: Request) async -> T? {
        guard req.application.redis.configuration != nil else { return nil }
        do {
            guard let data = try await req.redis.get(RedisKey(key), as: Data.self).get() else {
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            req.logger.warning("\(label) cache read failed key=\(key) error=\(error)")
            return nil
        }
    }

    func set(_ key: String, value: some Encodable, ttlSeconds: Int, on req: Request) async {
        guard req.application.redis.configuration != nil else { return }
        do {
            let data = try JSONEncoder().encode(value)
            try await req.redis.setex(
                RedisKey(key), to: data, expirationInSeconds: max(1, ttlSeconds)
            ).get()
        } catch {
            req.logger.warning("\(label) cache write failed key=\(key) error=\(error)")
        }
    }
}

/// In-process cache for tests and for a dev box with no Redis.
///
/// Honours keys but not TTLs: nothing in the suite waits an hour, and a fake
/// clock would only test the fake. Expiry is Redis's job and is not reimplemented
/// here.
final class InMemoryAIResponseCache: AIResponseCache, @unchecked Sendable {
    private let lock = NIOLock()
    private var storage: [String: Data] = [:]

    init() {}

    func get<T: Decodable>(_ key: String, as _: T.Type, on _: Request) async -> T? {
        guard let data = lock.withLock({ storage[key] }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func set(_ key: String, value: some Encodable, ttlSeconds _: Int, on _: Request) async {
        guard let data = try? JSONEncoder().encode(value) else { return }
        lock.withLock { storage[key] = data }
    }

    func removeAll() {
        lock.withLock { storage.removeAll() }
    }
}

extension Application {
    private struct AIResponseCacheKey: StorageKey {
        typealias Value = any AIResponseCache
    }

    /// Shared by every AI surface that caches generated prose. Defaults to Redis;
    /// a test replaces it with `InMemoryAIResponseCache`.
    var aiResponseCache: any AIResponseCache {
        get { storage[AIResponseCacheKey.self] ?? RedisJSONCache(label: "ai") }
        set { storage[AIResponseCacheKey.self] = newValue }
    }
}
