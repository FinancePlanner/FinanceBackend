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
