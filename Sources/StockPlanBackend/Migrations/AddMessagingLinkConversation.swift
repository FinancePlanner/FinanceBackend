import Fluent

/// Binds a chat to the assistant conversation it writes into.
///
/// Before this, "Telegram and the app are the same thread" was
/// `ORDER BY updated_at DESC LIMIT 1`, evaluated independently by the Telegram
/// resolver, the iOS client and the web handler. The intent was deliberate; the
/// pairing was not enforced anywhere, so tapping "New conversation" in the app
/// silently moved where Telegram wrote, and nothing could opt out.
struct AddMessagingLinkConversation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MessagingLink.schema)
            // Nullable on purpose. There is nothing correct to backfill: the
            // resolver picks a better thread lazily, when a message actually
            // arrives, than this migration could pick now. `.setNull` requires
            // it anyway.
            //
            // `.setNull` rather than `.cascade` is the load-bearing choice.
            // `AIAssistantRetentionJob` deletes conversations past their expiry;
            // under `.cascade` that job would delete the link row itself and
            // silently unlink someone's Telegram because a 30-day-idle thread
            // retired. Nulling instead lets the link survive and re-bind on the
            // next message. Matches `ai_pending_actions.conversation_id`.
            .field(
                "conversation_id",
                .uuid,
                .references(AIConversation.schema, "id", onDelete: .setNull)
            )
            .update()

        // No index: the lookup is by link, then by primary key. No unique
        // constraint either — two chats on one account may legitimately share a
        // thread, which is the whole point of the feature.
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MessagingLink.schema)
            .deleteField("conversation_id")
            .update()
    }
}
