import NIOCore
import Redis
@preconcurrency import RediStack // RESPValue is not Sendable; it never leaves incrementWithWindow.
import Vapor

struct RateLimitMiddleware: AsyncMiddleware {
    let limit: Int
    let interval: TimeInterval
    let keyPrefix: String

    init(limit: Int, interval: TimeInterval, keyPrefix: String = "ratelimit") {
        self.limit = limit
        self.interval = interval
        self.keyPrefix = keyPrefix
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.application.redis.configuration != nil else {
            if request.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: "Rate limiting is unavailable.")
            }
            return try await next.respond(to: request)
        }

        // Key by authenticated user when available so shared egress IPs (e.g. the
        // MCP service proxying many users) don't exhaust a single bucket.
        let identifier: String = if let session = request.auth.get(SessionToken.self) {
            "user:\(session.userId.uuidString)"
        } else {
            request.remoteAddress?.ipAddress ?? "unknown"
        }
        let key = RedisKey("\(keyPrefix):\(identifier)")
        let count: Int
        do {
            count = try await Self.incrementWithWindow(key, interval: interval, on: request.redis)
        } catch {
            if request.application.environment == .production {
                request.logger.error("rate_limit unavailable prefix=\(keyPrefix)")
                throw Abort(.serviceUnavailable, reason: "Rate limiting is unavailable.")
            }
            return try await next.respond(to: request)
        }

        guard count <= limit else {
            throw Abort(.tooManyRequests, reason: "Rate limit exceeded. Please try again later.")
        }
        return try await next.respond(to: request)
    }

    /// INCR the bucket and guarantee it carries a TTL, in one round trip.
    ///
    /// The previous shape was `INCR` then `EXPIRE` only when the count was 1.
    /// If that second command never landed (pod killed, connection dropped,
    /// Redis error) the key lived forever and the user or IP was 429'd until
    /// someone deleted it by hand. The script keeps the fixed window — the TTL
    /// is only set when the key has none, not refreshed on every hit.
    static let incrementScript = """
    local count = redis.call('INCR', KEYS[1])
    if redis.call('TTL', KEYS[1]) < 0 then
        redis.call('EXPIRE', KEYS[1], ARGV[1])
    end
    return count
    """

    static func incrementWithWindow(_ key: RedisKey, interval: TimeInterval, on redis: any RedisClient) async throws -> Int {
        let seconds = max(1, Int64(interval))
        let result = try await redis.send(
            command: "EVAL",
            with: [
                .init(from: incrementScript),
                .init(from: 1),
                .init(from: key.rawValue),
                .init(from: seconds),
            ]
        ).get()
        guard let count = result.int else {
            throw Abort(.internalServerError, reason: "Rate limit counter returned a non-integer.")
        }
        return count
    }
}
