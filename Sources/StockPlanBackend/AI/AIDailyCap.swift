import Foundation
import NIOCore
import Redis
import RediStack
import Vapor

/// Per-user daily Redis counter for Norviq-paid LLM endpoints.
enum AIDailyCap {
    /// The counter every caller shared before buckets existed.
    static let defaultBucket = "ai_daily"

    /// - Parameters:
    ///   - bucket: Which counter to charge. Separate buckets exist so a feature
    ///     that fans out over many screens cannot exhaust the allowance the
    ///     assistant needs to answer at all; the default keeps every original
    ///     caller on the one shared counter.
    ///   - limit: The allowance for that bucket. Defaults to `AI_DAILY_LIMIT`.
    static func enforce(
        _ req: Request,
        userId: UUID,
        unavailableReason: String,
        limitReachedReason: String,
        bucket: String = defaultBucket,
        limit: Int? = nil
    ) async throws {
        try AICostControls.requireEnabled(reason: unavailableReason)

        let limit = limit ?? AICostControls.dailyLimit
        guard req.application.redis.configuration != nil else {
            if req.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: unavailableReason)
            }
            return
        }

        let day = dayBucket(Date())
        let key = RedisKey("\(bucket):\(userId.uuidString):\(day)")
        let count: Int
        do {
            count = try await req.redis.increment(key).get()
            if count == 1 {
                _ = try await req.redis.expire(key, after: .seconds(86400)).get()
            }
        } catch {
            if req.application.environment == .production {
                req.logger.error("ai_daily_cap unavailable bucket=\(bucket) userId=\(userId)")
                throw Abort(.serviceUnavailable, reason: unavailableReason)
            }
            return
        }

        guard count <= limit else {
            throw Abort(.tooManyRequests, reason: limitReachedReason)
        }
    }

    static func dayBucket(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
