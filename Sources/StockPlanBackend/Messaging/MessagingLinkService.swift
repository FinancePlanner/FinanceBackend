import Crypto
import Fluent
import Foundation
import Redis
import Vapor

/// Issues and redeems the one-time codes that bind a chat to an account.
enum MessagingLinkService {
    /// Eight characters is 40 bits of entropy from the alphabet below — far
    /// beyond guessable inside the TTL at six attempts a minute, and still
    /// short enough to retype on a phone without resentment.
    static let codeLength = 8
    static let codeTTL: TimeInterval = 15 * 60
    /// No 0/O/1/I/L. Every removed character is one fewer support conversation
    /// about a code that "doesn't work".
    static let codeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let redeemAttemptsPerMinute = 6

    // MARK: - Issue

    /// Mints a fresh code, returning the plaintext to show exactly once.
    ///
    /// Issuing invalidates any previous code for this user, so a code read off
    /// a shoulder or left in a stale browser tab stops working the moment a new
    /// one is requested.
    static func issueCode(userId: UUID, platform: String, req: Request) async throws -> String {
        let code = generateCode()
        try await MessagingLinkCode.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$platform == platform)
            .delete()
        let record = MessagingLinkCode(
            codeHash: hash(code),
            userId: userId,
            platform: platform,
            expiresAt: Date().addingTimeInterval(codeTTL)
        )
        try await record.create(on: req.db)
        return code
    }

    static func generateCode() -> String {
        String((0 ..< codeLength).map { _ in codeAlphabet.randomElement()! })
    }

    static func hash(_ code: String) -> Data {
        Data(SHA256.hash(data: Data(code.uppercased().utf8)))
    }

    /// Accepts what a person actually sends: `/start ABCD-1234`, a bare code,
    /// lowercase, stray spaces.
    static func normalise(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/start", "/link"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        return text
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Redeem

    enum RedeemFailure: Error {
        case notPrivateChat
        case rateLimited
        case invalidCode
        case alreadyLinkedToAnotherAccount
    }

    /// Binds `externalID` to whichever account minted `code`.
    static func redeem(
        code rawCode: String,
        platform: String,
        externalID: String,
        isPrivateChat: Bool,
        req: Request
    ) async throws -> MessagingLink {
        // A group chat has many readers. Linking one would let every member
        // read one member's finances.
        guard isPrivateChat, isLinkableExternalID(externalID, platform: platform) else {
            throw RedeemFailure.notPrivateChat
        }
        // Keyed on the chat, not the code: keying on the code would hand a
        // guesser a fresh bucket for every guess, which is the opposite of a
        // rate limit.
        guard try await allowRedeemAttempt(platform: platform, externalID: externalID, req: req) else {
            throw RedeemFailure.rateLimited
        }

        let code = normalise(rawCode)
        guard code.count == codeLength else { throw RedeemFailure.invalidCode }

        let userId = try await claimCode(hash: hash(code), platform: platform, req: req)
        return try await insertLink(userId: userId, platform: platform, externalID: externalID, req: req)
    }

    /// Marks the code spent and returns its owner, refusing a second attempt.
    ///
    /// Single-use and expiry are enforced in the same statement that spends the
    /// code, so two updates arriving together cannot both win.
    private static func claimCode(hash: Data, platform: String, req: Request) async throws -> UUID {
        try await req.db.transaction { database in
            guard let record = try await MessagingLinkCode.query(on: database)
                .filter(\.$codeHash == hash)
                .filter(\.$platform == platform)
                .filter(\.$redeemedAt == nil)
                .filter(\.$expiresAt > Date())
                .first()
            else { throw RedeemFailure.invalidCode }
            record.redeemedAt = Date()
            try await record.save(on: database)
            return record.userId
        }
    }

    /// Creates the link, treating a re-link of the same chat to the same
    /// account as success and a re-link to a *different* account as a conflict.
    private static func insertLink(
        userId: UUID,
        platform: String,
        externalID: String,
        req: Request
    ) async throws -> MessagingLink {
        if let existing = try await MessagingLink.query(on: req.db)
            .filter(\.$platform == platform)
            .filter(\.$externalID == externalID)
            .first()
        {
            guard existing.userId == userId else { throw RedeemFailure.alreadyLinkedToAnotherAccount }
            return existing
        }
        let link = MessagingLink(userId: userId, platform: platform, externalID: externalID)
        do {
            try await link.create(on: req.db)
            return link
        } catch {
            // The unique (platform, external_id) index is the real guard; a
            // concurrent redemption is not an error if it reached the same place.
            if let existing = try await MessagingLink.query(on: req.db)
                .filter(\.$platform == platform)
                .filter(\.$externalID == externalID)
                .first()
            {
                guard existing.userId == userId else { throw RedeemFailure.alreadyLinkedToAnotherAccount }
                return existing
            }
            throw error
        }
    }

    /// Telegram group and channel ids are negative; a private chat's is not.
    /// This is the backstop behind the `isPrivateChat` flag from the update.
    static func isLinkableExternalID(_ externalID: String, platform: String) -> Bool {
        guard platform == MessagingPlatform.telegram else { return true }
        guard let value = Int64(externalID) else { return false }
        return value > 0
    }

    // MARK: - Unlink

    @discardableResult
    static func unlink(userId: UUID, platform: String, req: Request) async throws -> Bool {
        let links = try await MessagingLink.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$platform == platform)
            .all()
        guard !links.isEmpty else { return false }
        try await links.delete(on: req.db)
        return true
    }

    static func link(userId: UUID, platform: String, req: Request) async throws -> MessagingLink? {
        try await MessagingLink.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$platform == platform)
            .first()
    }

    // MARK: - Rate limiting

    private static func allowRedeemAttempt(platform: String, externalID: String, req: Request) async throws -> Bool {
        guard req.application.redis.configuration != nil else {
            // Matches RateLimitMiddleware: production refuses to run unmetered,
            // development does not require a Redis to try the bot locally.
            if req.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: "Rate limiting is unavailable.")
            }
            return true
        }
        let key = RedisKey("ratelimit:messaging-redeem:\(platform):\(externalID)")
        do {
            let count = try await req.redis.increment(key).get()
            if count == 1 {
                _ = try await req.redis.expire(key, after: .seconds(60)).get()
            }
            return count <= redeemAttemptsPerMinute
        } catch {
            if req.application.environment == .production {
                req.logger.error("messaging_redeem_rate_limit_unavailable platform=\(platform)")
                throw Abort(.serviceUnavailable, reason: "Rate limiting is unavailable.")
            }
            return true
        }
    }
}
