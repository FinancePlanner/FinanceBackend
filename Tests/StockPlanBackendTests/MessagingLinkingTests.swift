import Fluent
import Foundation
import Logging
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Database-backed behaviour: identity, dedupe, and the guards around them.
///
/// These use a real Postgres rather than a fake repository on purpose — the
/// invariants under test *are* a unique index and a single-use update, so a
/// stubbed store would only prove that the Swift compiles.
@Suite("Telegram linking", .serialized)
struct MessagingLinkingTests {
    private static let botToken = "12345:test-token"
    private static let webhookSecret = "test-webhook-secret"

    private func withApp(
        webhook: Bool = true,
        botConfigured: Bool = true,
        _ test: @escaping (Application) async throws -> Void
    ) async throws {
        try await DatabaseTestLock.withLock {
            setenv("BYPASS_BILLING", "false", 1)
            if botConfigured {
                setenv("TELEGRAM_BOT_TOKEN", Self.botToken, 1)
                setenv("TELEGRAM_BOT_USERNAME", "norviq_test_bot", 1)
                if webhook {
                    setenv("TELEGRAM_WEBHOOK_SECRET", Self.webhookSecret, 1)
                } else {
                    unsetenv("TELEGRAM_WEBHOOK_SECRET")
                }
            } else {
                unsetenv("TELEGRAM_BOT_TOKEN")
                unsetenv("TELEGRAM_WEBHOOK_SECRET")
            }
            defer {
                unsetenv("TELEGRAM_BOT_TOKEN")
                unsetenv("TELEGRAM_BOT_USERNAME")
                unsetenv("TELEGRAM_WEBHOOK_SECRET")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "tg_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "tg_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        let session = try await app.jwt.keys.verify(token, as: SessionToken.self)
        return (token, session.userId)
    }

    /// The detached request the bridge would build for a real update.
    private func backgroundRequest(_ app: Application) -> Request {
        Request(
            application: app, method: .POST,
            url: URI(string: "/internal/telegram-test"),
            on: app.eventLoopGroup.next()
        )
    }

    private func inbound(_ text: String, chat: String = "4242", updateID: Int64 = 1) -> InboundMessage {
        InboundMessage(
            platform: MessagingPlatform.telegram, externalID: chat,
            updateID: updateID, text: text, isPrivateChat: true, callbackQueryID: nil
        )
    }

    // MARK: - Codes

    @Test("A code links the chat, and cannot be spent a second time")
    func codeIsSingleUse() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            let code = try await MessagingLinkService.issueCode(
                userId: user.userId, platform: MessagingPlatform.telegram, req: req
            )

            let link = try await MessagingLinkService.redeem(
                code: code, platform: MessagingPlatform.telegram,
                externalID: "4242", isPrivateChat: true, req: req
            )
            #expect(link.userId == user.userId)

            // A second chat presenting the same code must get nothing.
            await #expect(throws: MessagingLinkService.RedeemFailure.self) {
                _ = try await MessagingLinkService.redeem(
                    code: code, platform: MessagingPlatform.telegram,
                    externalID: "9999", isPrivateChat: true, req: req
                )
            }
        }
    }

    @Test("Only the hash of a code is stored")
    func codeIsStoredHashed() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            let code = try await MessagingLinkService.issueCode(
                userId: user.userId, platform: MessagingPlatform.telegram, req: req
            )
            let rows = try await MessagingLinkCode.query(on: app.db).all()
            #expect(rows.count == 1)
            // The plaintext must not be recoverable from the row.
            let stored = String(decoding: rows[0].codeHash, as: UTF8.self)
            #expect(!stored.contains(code))
            #expect(rows[0].codeHash == MessagingLinkService.hash(code))
        }
    }

    @Test("Issuing a new code invalidates the previous one")
    func issuingReplacesPreviousCode() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            let first = try await MessagingLinkService.issueCode(
                userId: user.userId, platform: MessagingPlatform.telegram, req: req
            )
            _ = try await MessagingLinkService.issueCode(
                userId: user.userId, platform: MessagingPlatform.telegram, req: req
            )
            await #expect(throws: MessagingLinkService.RedeemFailure.self) {
                _ = try await MessagingLinkService.redeem(
                    code: first, platform: MessagingPlatform.telegram,
                    externalID: "4242", isPrivateChat: true, req: req
                )
            }
        }
    }

    @Test("A group chat cannot redeem a code")
    func groupChatCannotRedeem() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            let code = try await MessagingLinkService.issueCode(
                userId: user.userId, platform: MessagingPlatform.telegram, req: req
            )
            // Negative id plus a non-private flag: either alone is refused.
            await #expect(throws: MessagingLinkService.RedeemFailure.self) {
                _ = try await MessagingLinkService.redeem(
                    code: code, platform: MessagingPlatform.telegram,
                    externalID: "-100200", isPrivateChat: false, req: req
                )
            }
            let links = try await MessagingLink.query(on: app.db).count()
            #expect(links == 0)
        }
    }

    @Test("An expired code is refused")
    func expiredCodeIsRefused() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            let code = "ABCD2345"
            try await MessagingLinkCode(
                codeHash: MessagingLinkService.hash(code),
                userId: user.userId,
                platform: MessagingPlatform.telegram,
                expiresAt: Date().addingTimeInterval(-60)
            ).create(on: app.db)

            await #expect(throws: MessagingLinkService.RedeemFailure.self) {
                _ = try await MessagingLinkService.redeem(
                    code: code, platform: MessagingPlatform.telegram,
                    externalID: "4242", isPrivateChat: true, req: req
                )
            }
        }
    }

    // MARK: - Dedupe and routing

    @Test("A redelivered update is ignored rather than answered twice")
    func redeliveredUpdateIsIgnored() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram, externalID: "4242"
            ).create(on: app.db)

            let first = try await MessagingService.handle(inbound("/help", updateID: 5), req: req)
            #expect(!first.silent)

            // Same update id arriving again: the work is already done, so a
            // second answer would be a duplicate, not a recovery.
            let replay = try await MessagingService.handle(inbound("/help", updateID: 5), req: req)
            #expect(replay.silent)

            let newer = try await MessagingService.handle(inbound("/help", updateID: 6), req: req)
            #expect(!newer.silent)
        }
    }

    @Test("An unlinked chat is told how to connect and is never forwarded")
    func unlinkedChatGetsInstructions() async throws {
        try await withApp { app in
            let req = backgroundRequest(app)
            let reply = try await MessagingService.handle(inbound("what is my balance?"), req: req)
            #expect(reply.text == MessagingService.connectInstructions)
        }
    }

    @Test("An unlinked chat can redeem by sending the bare code")
    func unlinkedChatCanRedeem() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            let code = try await MessagingLinkService.issueCode(
                userId: user.userId, platform: MessagingPlatform.telegram, req: req
            )
            let reply = try await MessagingService.handle(inbound(code), req: req)
            #expect(reply.text.hasPrefix("Connected."))

            let link = try await MessagingLink.query(on: app.db).first()
            #expect(link?.userId == user.userId)
        }
    }

    @Test("Group traffic never reaches an account")
    func groupTrafficIsIgnored() async throws {
        try await withApp { app in
            let req = backgroundRequest(app)
            let group = InboundMessage(
                platform: MessagingPlatform.telegram, externalID: "-100200",
                updateID: 1, text: "hello", isPrivateChat: false, callbackQueryID: nil
            )
            let reply = try await MessagingService.handle(group, req: req)
            #expect(reply.silent)
        }
    }

    @Test("Commands never reach the model or spend quota")
    func commandsAreFree() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram, externalID: "4242"
            ).create(on: app.db)
            // Any model call would throw, proving the command short-circuited.
            app.openAIChatClient = ExplodingChatClient()

            let reply = try await MessagingService.handle(inbound("/help"), req: req)
            #expect(reply.text == MessagingCommands.helpText)
            let usage = try await AIAssistantUsage.query(on: app.db).count()
            #expect(usage == 0)
        }
    }

    // MARK: - Data commands

    /// The whole point of these commands: they answer from the database, so no
    /// model is called, no OpenRouter credits are spent, and no turn comes off
    /// the monthly allowance. `ExplodingChatClient` throws if the model is
    /// reached, so a passing test is the proof.
    @Test("Every data command answers without touching the model")
    func dataCommandsNeverReachTheModel() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram, externalID: "4242"
            ).create(on: app.db)
            app.openAIChatClient = ExplodingChatClient()

            // No Entitlement row and BYPASS_BILLING=false, so this really is a
            // free user: every command must still answer.
            for (index, command) in ["/finance", "/portfolio", "/budget", "/expenses", "/news"].enumerated() {
                let reply = try await MessagingService.handle(
                    inbound(command, updateID: Int64(index + 1)), req: req
                )
                #expect(!reply.text.isEmpty, "\(command) returned nothing")
                #expect(!reply.silent, "\(command) was silent")
            }

            let usage = try await AIAssistantUsage.query(on: app.db).count()
            #expect(usage == 0)
        }
    }

    @Test("A data command carrying a question goes to the assistant instead")
    func dataCommandWithQuestionFallsThroughToTheModel() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram, externalID: "4242"
            ).create(on: app.db)
            app.openAIChatClient = FixedReplyChatClient(text: "Cut the fun pillar first.")

            let reply = try await MessagingService.handle(
                inbound("/budget how do I cut it?"), req: req
            )

            #expect(reply.text == "Cut the fun pillar first.")
            let usage = try await AIAssistantUsage.query(on: app.db).count()
            #expect(usage == 1)
        }
    }

    @Test("A bare data command does not spend a turn even when the model would answer")
    func bareDataCommandDoesNotSpendATurn() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram, externalID: "4242"
            ).create(on: app.db)
            app.openAIChatClient = FixedReplyChatClient(text: "prose the model would have written")

            let reply = try await MessagingService.handle(inbound("/budget"), req: req)

            #expect(reply.text != "prose the model would have written")
            #expect(reply.text.contains("Budget"))
            let usage = try await AIAssistantUsage.query(on: app.db).count()
            #expect(usage == 0)
        }
    }

    // MARK: - /clear

    @Test("/clear starts a new thread without deleting the old one")
    func clearStartsAFreshConversation() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram, externalID: "4242"
            ).create(on: app.db)
            app.openAIChatClient = FixedReplyChatClient(text: "noted")

            // A turn first, so there is a thread to leave behind.
            _ = try await MessagingService.handle(inbound("remember this", updateID: 1), req: req)
            let first = try #require(try await AIConversation.query(on: app.db).first())

            let reply = try await MessagingService.handle(inbound("/clear", updateID: 2), req: req)
            #expect(reply.text.hasPrefix("Fresh start"))

            // Two conversations now exist: nothing was destroyed.
            let all = try await AIConversation.query(on: app.db).all()
            #expect(all.count == 2)
            #expect(all.contains { $0.id == first.id })

            // And the next turn lands on the new one, not the old.
            _ = try await MessagingService.handle(inbound("and this", updateID: 3), req: req)
            let messagesOnFirst = try await AIAssistantMessage.query(on: app.db)
                .filter(\.$conversation.$id == first.requireID())
                .count()
            #expect(messagesOnFirst == 2) // the original user message + reply, nothing new
        }
    }

    @Test("/unlink disconnects the chat")
    func unlinkCommand() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let req = backgroundRequest(app)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram, externalID: "4242"
            ).create(on: app.db)

            let reply = try await MessagingService.handle(inbound("/unlink"), req: req)
            #expect(reply.text.hasPrefix("Disconnected."))
            let remaining = try await MessagingLink.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("A casual \"ok\" with nothing pending reaches the assistant")
    func typedYesIsNotSwallowed() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram, externalID: "4242"
            ).create(on: app.db)
            app.openAIChatClient = FixedReplyChatClient(text: "Sure — what would you like to know?")

            // Nothing is awaiting confirmation, so this is ordinary conversation.
            let reply = try await MessagingService.handle(inbound("ok"), req: req)
            #expect(reply.text == "Sure — what would you like to know?")
        }
    }

    @Test("A pinned chat keeps its thread even when a newer one exists")
    func pinnedThreadWinsOverNewer() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            app.openAIChatClient = FixedReplyChatClient(text: "Noted.")

            let pinned = try AIConversation(
                userId: user.userId,
                titleEncrypted: req.userPIIEncryptionService.encryptString("Telegram"),
                expiresAt: Date().addingTimeInterval(30 * 86400)
            )
            try await pinned.create(on: app.db)

            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram,
                externalID: "4242", conversationId: pinned.requireID()
            ).create(on: app.db)

            // Newer by updatedAt, which is precisely what the old resolver
            // would have chosen.
            let newer = try AIConversation(
                userId: user.userId,
                titleEncrypted: req.userPIIEncryptionService.encryptString("From the app"),
                expiresAt: Date().addingTimeInterval(30 * 86400)
            )
            try await newer.create(on: app.db)

            _ = try await MessagingService.handle(inbound("hello"), req: req)

            let pinnedMessages = try await AIAssistantMessage.query(on: app.db)
                .filter(\.$conversation.$id == pinned.requireID()).count()
            let newerMessages = try await AIAssistantMessage.query(on: app.db)
                .filter(\.$conversation.$id == newer.requireID()).count()
            #expect(pinnedMessages == 2, "the turn belongs to the pinned thread")
            #expect(newerMessages == 0, "a newer thread must not steal the chat")
        }
    }

    @Test("Retiring the pinned conversation does not break the chat")
    func retiredThreadReleasesTheLink() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            app.openAIChatClient = FixedReplyChatClient(text: "Still here.")

            let doomed = try AIConversation(
                userId: user.userId,
                titleEncrypted: req.userPIIEncryptionService.encryptString("Telegram"),
                expiresAt: Date().addingTimeInterval(30 * 86400)
            )
            try await doomed.create(on: app.db)
            let doomedID = try doomed.requireID()
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram,
                externalID: "4242", conversationId: doomedID
            ).create(on: app.db)

            // What the retention job does to an expired thread. The FK is
            // ON DELETE SET NULL precisely so this cannot take the link with it.
            try await doomed.delete(on: app.db)

            let afterDelete = try await MessagingLink.query(on: app.db).first()
            #expect(afterDelete != nil, "the link must outlive the conversation")
            #expect(afterDelete?.conversationId == nil)

            // And the next message re-binds rather than failing.
            let reply = try await MessagingService.handle(inbound("are you there?"), req: req)
            #expect(reply.text == "Still here.")
            let rebound = try await MessagingLink.query(on: app.db).first()
            #expect(rebound?.conversationId != nil)
            #expect(rebound?.conversationId != doomedID)
        }
    }

    @Test("Starting a conversation in the app moves the chat to it")
    func appConversationMovesTheChat() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            app.openAIChatClient = FixedReplyChatClient(text: "Fresh.")

            let old = try AIConversation(
                userId: user.userId,
                titleEncrypted: req.userPIIEncryptionService.encryptString("Telegram"),
                expiresAt: Date().addingTimeInterval(30 * 86400)
            )
            try await old.create(on: app.db)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram,
                externalID: "4242", conversationId: old.requireID()
            ).create(on: app.db)

            var createdID = ""
            try await app.testing().test(
                .POST, "v1/ai/assistant/conversations",
                beforeRequest: { r in
                    r.headers.bearerAuthorization = .init(token: user.token)
                    try r.content.encode(["title": "New conversation"])
                },
                afterResponse: { res async throws in
                    #expect(res.status == .created)
                    createdID = try res.content.decode(AIConversationResponse.self).id
                }
            )

            let link = try await MessagingLink.query(on: app.db).first()
            #expect(link?.conversationId?.uuidString == createdID)

            // And the next Telegram message lands there, not on the old thread.
            _ = try await MessagingService.handle(inbound("hi"), req: req)
            let oldMessages = try await AIAssistantMessage.query(on: app.db)
                .filter(\.$conversation.$id == old.requireID()).count()
            #expect(oldMessages == 0)
        }
    }

    // MARK: - Confirmations are scoped to the thread they arrived on

    /// Builds a proposal without going through the model, so the test is about
    /// the lookup rather than about tool-calling.
    private func pendingAction(
        userId: UUID,
        conversationId: UUID?,
        req: Request,
        on db: any Database
    ) async throws -> AIPendingAction {
        let action = AIPendingAction()
        action.userId = userId
        action.conversationId = conversationId
        action.toolName = "delete_expense"
        action.argumentsEncrypted = try req.userPIIEncryptionService.encryptString("{}")
        action.summaryEncrypted = try req.userPIIEncryptionService
            .encryptString("Delete the selected expense.")
        action.status = AIActionStatus.pending.rawValue
        action.expiresAt = Date().addingTimeInterval(15 * 60)
        try await action.create(on: db)
        return action
    }

    @Test("A typed answer in the chat cannot settle a proposal made in the app")
    func typedAnswerCannotSettleAnotherThreadsProposal() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            app.openAIChatClient = FixedReplyChatClient(text: "Here are your expenses.")

            // The chat's own thread...
            let chatThread = try AIConversation(
                userId: user.userId,
                titleEncrypted: req.userPIIEncryptionService.encryptString("Telegram"),
                expiresAt: Date().addingTimeInterval(30 * 86400)
            )
            try await chatThread.create(on: app.db)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram,
                externalID: "4242", conversationId: chatThread.requireID()
            ).create(on: app.db)

            // ...and a deletion proposed somewhere else entirely.
            let appThread = try AIConversation(
                userId: user.userId,
                titleEncrypted: req.userPIIEncryptionService.encryptString("In the app"),
                expiresAt: Date().addingTimeInterval(30 * 86400)
            )
            try await appThread.create(on: app.db)
            let action = try await pendingAction(
                userId: user.userId, conversationId: appThread.requireID(),
                req: req, on: app.db
            )

            // "no" is a refusal word, so under the old lookup this cancelled the
            // app's proposal. It must now be read as ordinary conversation.
            let reply = try await MessagingService.handle(inbound("no", updateID: 1), req: req)
            #expect(reply.text == "Here are your expenses.")

            let after = try await AIPendingAction.find(action.requireID(), on: app.db)
            #expect(after?.status == AIActionStatus.pending.rawValue, "untouched")
        }
    }

    @Test("A typed answer does settle a proposal made on the same thread")
    func typedAnswerSettlesItsOwnThreadsProposal() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            app.openAIChatClient = FixedReplyChatClient(text: "Here are your expenses.")

            let chatThread = try AIConversation(
                userId: user.userId,
                titleEncrypted: req.userPIIEncryptionService.encryptString("Telegram"),
                expiresAt: Date().addingTimeInterval(30 * 86400)
            )
            try await chatThread.create(on: app.db)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram,
                externalID: "4242", conversationId: chatThread.requireID()
            ).create(on: app.db)

            let action = try await pendingAction(
                userId: user.userId, conversationId: chatThread.requireID(),
                req: req, on: app.db
            )

            let reply = try await MessagingService.handle(inbound("no", updateID: 1), req: req)
            #expect(reply.text == "Cancelled. Nothing was changed.")

            let after = try await AIPendingAction.find(action.requireID(), on: app.db)
            #expect(after?.status == AIActionStatus.cancelled.rawValue)
        }
    }

    @Test("An orphaned proposal needs its button, not a typed answer")
    func orphanedProposalNeedsItsButton() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            app.openAIChatClient = FixedReplyChatClient(text: "Here are your expenses.")

            let chatThread = try AIConversation(
                userId: user.userId,
                titleEncrypted: req.userPIIEncryptionService.encryptString("Telegram"),
                expiresAt: Date().addingTimeInterval(30 * 86400)
            )
            try await chatThread.create(on: app.db)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram,
                externalID: "4242", conversationId: chatThread.requireID()
            ).create(on: app.db)

            // conversationId nil: the thread it was proposed on has been retired.
            let action = try await pendingAction(
                userId: user.userId, conversationId: nil, req: req, on: app.db
            )
            let actionID = try action.requireID().uuidString

            // A bare answer has no context to attach to, so it must not reach it.
            let typed = try await MessagingService.handle(inbound("no", updateID: 1), req: req)
            #expect(typed.text == "Here are your expenses.")
            var after = try await AIPendingAction.find(action.requireID(), on: app.db)
            #expect(after?.status == AIActionStatus.pending.rawValue)

            // The button names the action, so it still works.
            let tapped = try await MessagingService.handle(
                inbound(MessagingService.declinePrefix + actionID, updateID: 2), req: req
            )
            #expect(tapped.text == "Cancelled. Nothing was changed.")
            after = try await AIPendingAction.find(action.requireID(), on: app.db)
            #expect(after?.status == AIActionStatus.cancelled.rawValue)
        }
    }

    @Test("A Telegram turn continues the same conversation the web app shows")
    func sharesTheWebThread() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await Entitlement(userId: user.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            try await MessagingLink(
                userId: user.userId, platform: MessagingPlatform.telegram, externalID: "4242"
            ).create(on: app.db)
            app.openAIChatClient = FixedReplyChatClient(text: "You spent 42 euros.")

            // An existing thread, as the browser would have created.
            let existing = try AIConversation(
                userId: user.userId,
                titleEncrypted: req.userPIIEncryptionService.encryptString("From the web"),
                expiresAt: Date().addingTimeInterval(30 * 86400)
            )
            try await existing.create(on: app.db)

            let reply = try await MessagingService.handle(inbound("what did I spend?"), req: req)
            #expect(reply.text == "You spent 42 euros.")

            // No second thread, and both turns landed in the existing one.
            let conversations = try await AIConversation.query(on: app.db).count()
            #expect(conversations == 1)
            let messages = try await AIAssistantMessage.query(on: app.db)
                .filter(\.$conversation.$id == existing.requireID()).count()
            #expect(messages == 2)

            // Adopting the thread also pins it, so the pairing survives the app
            // later creating a newer conversation.
            let existingID = try existing.requireID()
            let link = try await MessagingLink.query(on: app.db).first()
            #expect(link?.conversationId == existingID)
        }
    }

    // MARK: - Tenancy

    @Test("A chat linked to one account cannot be claimed by another")
    func aChatBelongsToExactlyOneAccount() async throws {
        try await withApp { app in
            let owner = try await registerUser(app: app)
            let intruder = try await registerUser(app: app)
            let req = backgroundRequest(app)

            let ownerCode = try await MessagingLinkService.issueCode(
                userId: owner.userId, platform: MessagingPlatform.telegram, req: req
            )
            _ = try await MessagingLinkService.redeem(
                code: ownerCode, platform: MessagingPlatform.telegram,
                externalID: "4242", isPrivateChat: true, req: req
            )

            // The intruder holds a valid code of their own, but this chat is
            // already spoken for. Re-pointing it would silently hand them the
            // owner's finances.
            let intruderCode = try await MessagingLinkService.issueCode(
                userId: intruder.userId, platform: MessagingPlatform.telegram, req: req
            )
            await #expect(throws: MessagingLinkService.RedeemFailure.self) {
                _ = try await MessagingLinkService.redeem(
                    code: intruderCode, platform: MessagingPlatform.telegram,
                    externalID: "4242", isPrivateChat: true, req: req
                )
            }

            let link = try await MessagingLink.query(on: app.db)
                .filter(\.$externalID == "4242").first()
            #expect(link?.userId == owner.userId)
        }
    }

    @Test("Two chats on one bot resolve to their own accounts")
    func chatsAreIsolatedFromEachOther() async throws {
        try await withApp { app in
            let first = try await registerUser(app: app)
            let second = try await registerUser(app: app)
            try await Entitlement(userId: first.userId, level: "pro").save(on: app.db)
            try await Entitlement(userId: second.userId, level: "pro").save(on: app.db)
            let req = backgroundRequest(app)
            app.openAIChatClient = FixedReplyChatClient(text: "Here you go.")

            try await MessagingLink(
                userId: first.userId, platform: MessagingPlatform.telegram, externalID: "1111"
            ).create(on: app.db)
            try await MessagingLink(
                userId: second.userId, platform: MessagingPlatform.telegram, externalID: "2222"
            ).create(on: app.db)

            _ = try await MessagingService.handle(inbound("hello", chat: "1111", updateID: 1), req: req)
            _ = try await MessagingService.handle(inbound("hello", chat: "2222", updateID: 2), req: req)

            // Each chat got its own conversation, owned by its own account —
            // one shared bot must never mean one shared thread.
            let firstConversations = try await AIConversation.query(on: app.db)
                .filter(\.$userId == first.userId).count()
            let secondConversations = try await AIConversation.query(on: app.db)
                .filter(\.$userId == second.userId).count()
            #expect(firstConversations == 1)
            #expect(secondConversations == 1)

            let firstMessages = try await AIAssistantMessage.query(on: app.db)
                .filter(\.$userId == second.userId).count()
            #expect(firstMessages == 2, "the second account sees only its own turn")
        }
    }

    // MARK: - Webhook

    @Test("The webhook refuses a delivery with the wrong secret")
    func webhookRejectsBadSecret() async throws {
        try await withApp { app in
            try await app.testing().test(
                .POST, "webhooks/telegram",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: TelegramWebhookController.secretHeader, value: "wrong")
                    try req.content.encode(["update_id": 1])
                },
                afterResponse: { res async throws in
                    // 401 from the secret check — not 403 from CSRF, and not 404.
                    #expect(res.status == .unauthorized)
                }
            )
        }
    }

    @Test("The webhook accepts a delivery carrying the right secret")
    func webhookAcceptsGoodSecret() async throws {
        try await withApp { app in
            try await app.testing().test(
                .POST, "webhooks/telegram",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(
                        name: TelegramWebhookController.secretHeader, value: Self.webhookSecret
                    )
                    req.body = ByteBuffer(string: #"{"update_id":1}"#)
                    req.headers.contentType = .json
                },
                afterResponse: { res async throws in
                    // Acked immediately; the turn runs detached.
                    #expect(res.status == .ok)
                }
            )
        }
    }

    @Test("In-flight turns are drained before the application stops")
    func inFlightTurnsAreDrained() async throws {
        try await withApp { app in
            // A valid delivery spawns a detached turn. Without draining, that
            // turn keeps using the database and event loop while the app is
            // being torn down — which is a segfault, not an error, and shows up
            // on Linux long before it shows up on macOS.
            try await app.testing().test(
                .POST, "webhooks/telegram",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(
                        name: TelegramWebhookController.secretHeader, value: Self.webhookSecret
                    )
                    req.body = ByteBuffer(string: #"{"update_id":77,"message":{"message_id":1,"chat":{"id":4242,"type":"private"},"text":"hello"}}"#)
                    req.headers.contentType = .json
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                }
            )
            await app.telegramInFlightTurns.drain()
            // Draining is terminal: nothing new may start afterwards.
            #expect(app.telegramInFlightTurns.acceptsWork == false)
        }
    }

    @Test("The webhook route does not exist without a bot token")
    func webhookAbsentWithoutToken() async throws {
        try await withApp(botConfigured: false) { app in
            try await app.testing().test(
                .POST, "webhooks/telegram",
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )
        }
    }

    @Test("A half-configured bot disables itself instead of taking the API down")
    func productionDisablesPollingBot() {
        let logger = Logger(label: "test")
        let polling = TelegramConfiguration(
            botToken: Self.botToken, botUsername: "bot", webhookSecret: nil
        )
        // Two pods during a rolling deploy would fight over getUpdates, so this
        // must never run in production — but an optional chat feature must not
        // be able to crash-loop the API either.
        #expect(TelegramConfiguration.resolve(polling, environment: .production, logger: logger) == nil)

        // Locally, polling is exactly what we want.
        #expect(TelegramConfiguration.resolve(polling, environment: .development, logger: logger) != nil)

        let webhook = TelegramConfiguration(
            botToken: Self.botToken, botUsername: "bot", webhookSecret: Self.webhookSecret
        )
        #expect(TelegramConfiguration.resolve(webhook, environment: .production, logger: logger) != nil)
        #expect(TelegramConfiguration.resolve(nil, environment: .production, logger: logger) == nil)
    }
}

// MARK: - Fakes

/// Fails if the model is reached at all.
private struct ExplodingChatClient: OpenAIChatClient {
    struct ShouldNotBeCalled: Error {}

    func chat(
        messages _: [OpenAIMessage], tools _: [OpenAITool],
        responseFormat _: String?, on _: Request
    ) async throws -> OpenAIMessage {
        throw ShouldNotBeCalled()
    }
}

/// Answers immediately, with no tool calls.
private struct FixedReplyChatClient: OpenAIChatClient {
    let text: String

    func chat(
        messages _: [OpenAIMessage], tools _: [OpenAITool],
        responseFormat _: String?, on _: Request
    ) async throws -> OpenAIMessage {
        OpenAIMessage(role: "assistant", content: text)
    }
}
