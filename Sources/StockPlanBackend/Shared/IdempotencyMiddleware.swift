import Redis
import Vapor

/// Idempotency middleware using Redis.
///
/// Clients provide `Idempotency-Key` header (opaque string).
/// First request with a given key passes through and caches response.
/// Retries within TTL (default 24h) return cached response without re-executing.
///
/// Only applies to methods with side effects (POST/PUT/DELETE/PATCH).
/// If Redis is unavailable in production, requests fail closed.
struct IdempotencyMiddleware: AsyncMiddleware {
    let ttl: TimeInterval
    let keyPrefix: String

    init(ttl: TimeInterval = 86400, keyPrefix: String = "idempotency") {
        self.ttl = ttl
        self.keyPrefix = keyPrefix
    }

    /// Namespaced per caller. `Idempotency-Key` is a client-chosen opaque string,
    /// so without a caller component every credential shares one keyspace and a
    /// colliding key replays one caller's cached response body to another.
    private func cacheKey(for key: String, callerDigest: String) -> RedisKey {
        RedisKey("\(keyPrefix):\(callerDigest):\(key)")
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Apply only to mutating verbs; skip otherwise.
        guard [.POST, .PUT, .DELETE, .PATCH].contains(request.method) else {
            return try await next.respond(to: request)
        }

        guard let rawKey = request.headers.first(name: "Idempotency-Key"), !rawKey.isEmpty else {
            return try await next.respond(to: request)
        }

        let idemKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // This middleware is registered globally, ahead of authentication, so the
        // credential is the only identity available here. Unauthenticated callers
        // deliberately get no bucket at all rather than a shared one: replaying a
        // cached `/v1/auth/*` response would hand one caller another's session.
        guard let authorization = request.headers.first(name: .authorization),
              !authorization.isEmpty
        else {
            return try await next.respond(to: request)
        }
        let callerDigest = String(OpaqueToken.sha256Hex(authorization).prefix(32))

        // Redis required — fail closed in prod if missing.
        guard request.application.redis.configuration != nil else {
            if request.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: "Idempotency requires Redis.")
            }
            return try await next.respond(to: request)
        }

        let key = cacheKey(for: idemKey, callerDigest: callerDigest)

        // Try cache hit.
        if let cachedString = try? await request.redis.get(key, as: String.self).get(),
           let (status, headers, body) = Self.parseCached(cachedString)
        {
            request.logger.debug("idempotency.hit key=\(idemKey.prefix(8))...")
            var response = Response(status: HTTPStatus(statusCode: status))
            response.headers = HTTPHeaders(headers)
            response.body = Response.Body(string: body)
            return response
        }

        request.logger.debug("idempotency.miss key=\(idemKey.prefix(8))...")

        // Execute real handler.
        let resp = try await next.respond(to: request)

        // Cache successful responses with body.
        let statusCode = Int(resp.status.code)
        if (200 ... 399).contains(statusCode), let body = resp.body.string {
            let headerPairs = resp.headers.map { ($0.name, $0.value) }
            let cached = Self.encodeCached(status: statusCode, headers: headerPairs, body: body)
            try? await request.redis.set(key, to: cached).get()
            try? await request.redis.expire(key, after: .seconds(Int64(ttl))).get()
        }

        return resp
    }

    // MARK: - Serialization

    /// encode status/headers/body into a single string for Redis
    private static func encodeCached(status: Int, headers: [(String, String)], body: String) -> String {
        // Format: STATUS\nHeader1:Val1\nHeader2:Val2\n\nBODY
        let headerLines = headers.map { "\($0):\($1)" }.joined(separator: "\n")
        return "\(status)\n\(headerLines)\n\n\(body)"
    }

    /// decode cached string → (status, headers, body) or nil if malformed
    private static func parseCached(_ stored: String) -> (status: Int, headers: [(String, String)], body: String)? {
        let parts = stored.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let meta = parts[0]
        let body = String(parts[1])

        let metaLines = meta.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let statusStr = metaLines.first,
              let status = Int(statusStr.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }

        var headers: [(String, String)] = []
        if metaLines.count > 1 {
            for line in metaLines[1].split(separator: "\n") {
                let kv = line.split(separator: ":", maxSplits: 1)
                if kv.count == 2 {
                    headers.append((
                        String(kv[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                        String(kv[1].trimmingCharacters(in: .whitespacesAndNewlines))
                    ))
                }
            }
        }

        return (status, headers, body)
    }
}
