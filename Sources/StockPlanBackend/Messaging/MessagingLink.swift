import Fluent
import Foundation
import Vapor

/// A chat on some messaging platform, bound to a Norviq account.
///
/// Deliberately not an auth identity. `PersonalAccessToken` and `OAuthToken`
/// are ways to *sign in*; this is only a delivery address plus a claim about
/// who is typing. Keeping the tables apart means unlinking Telegram can never
/// lock anyone out of their account.
final class MessagingLink: Model, @unchecked Sendable {
    static let schema = "messaging_links"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    /// `"telegram"`. No database CHECK — the set of platforms is bounded at the
    /// adapter edge, where a new one is a new directory rather than a migration.
    @Field(key: "platform")
    var platform: String

    /// Text rather than a bigint. Telegram chat ids are numeric, but the next
    /// platform's will not be, and widening a column later is worse than
    /// storing digits as characters now.
    @Field(key: "external_id")
    var externalID: String

    /// Dedupe watermark. Telegram redelivers an update until it is acked, and
    /// an ack can be lost after the work is already done.
    @Field(key: "last_update_id")
    var lastUpdateID: Int64

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    /// Null means linked but never used — worth distinguishing in settings.
    @OptionalField(key: "last_seen_at")
    var lastSeenAt: Date?

    /// The assistant conversation this chat writes into.
    ///
    /// Null means unbound: either the link predates the binding, or the thread
    /// it pointed at has since been retired (the column is `ON DELETE SET
    /// NULL`). Either way the resolver adopts a thread and pins it on the next
    /// message, so a null here is a normal state rather than an error.
    ///
    /// `@OptionalField` rather than `@OptionalParent`, matching
    /// `AIPendingAction.conversationId`: this table is deliberately not an auth
    /// identity and has no reason to know the AI module's model type.
    @OptionalField(key: "conversation_id")
    var conversationId: UUID?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        platform: String,
        externalID: String,
        lastUpdateID: Int64 = 0,
        lastSeenAt: Date? = nil,
        conversationId: UUID? = nil
    ) {
        self.id = id
        self.userId = userId
        self.platform = platform
        self.externalID = externalID
        self.lastUpdateID = lastUpdateID
        self.lastSeenAt = lastSeenAt
        self.conversationId = conversationId
    }
}

/// A short-lived, single-use pairing code.
///
/// Only the SHA-256 of the code is stored. A leaked database row therefore
/// cannot be redeemed, and the plaintext exists on exactly one HTTP response.
final class MessagingLinkCode: Model, @unchecked Sendable {
    static let schema = "messaging_link_codes"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "code_hash")
    var codeHash: Data

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "platform")
    var platform: String

    @Field(key: "expires_at")
    var expiresAt: Date

    /// A tombstone rather than a delete, so a replayed code is distinguishable
    /// from one that never existed. Both are refused; only the logs differ.
    @OptionalField(key: "redeemed_at")
    var redeemedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        codeHash: Data,
        userId: UUID,
        platform: String,
        expiresAt: Date
    ) {
        self.id = id
        self.codeHash = codeHash
        self.userId = userId
        self.platform = platform
        self.expiresAt = expiresAt
    }
}
