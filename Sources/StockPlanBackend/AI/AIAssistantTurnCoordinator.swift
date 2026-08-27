import Fluent
import Foundation
import StockPlanShared
import Vapor

/// One assistant turn, independent of how the request arrived.
///
/// The HTTP route used to own this whole sequence, which meant the assistant
/// could only be reached by something holding a `SessionToken`. Telegram
/// updates carry no such token — they carry a chat id that a `MessagingLink`
/// resolves to a user. Minting a synthetic session for that chat would hand a
/// messaging bridge a real bearer credential with every scope the app has, to
/// obtain a `UUID` it already knows. So the orchestration lives here and takes
/// the user id directly; `AIAssistantController.chat` and the Telegram bridge
/// are both thin callers.
///
/// Everything a turn touches — encryption, billing, the model client — hangs off
/// `Application` storage rather than the request, so `req` here may be a
/// synthetic `Request` detached from any inbound connection.
enum AIAssistantTurnCoordinator {
    /// A completed turn, including the persisted assistant message so HTTP
    /// callers can build a DTO with its real id and timestamp.
    struct Outcome {
        let text: String
        let pendingAction: AIPendingAction?
        let assistantMessage: AIAssistantMessage
    }

    static let maxMessageCharacters = 12000

    static func run(
        userId: UUID,
        conversation: AIConversation,
        content: String,
        req: Request
    ) async throws -> Outcome {
        let conversationId = try conversation.requireID()
        guard !content.isEmpty, content.count <= maxMessageCharacters else {
            throw Abort(.badRequest, reason: "Message must contain 1 to 12,000 characters.")
        }
        // Resolved before the quota check on purpose: a user paying for their
        // own inference must not also spend a Norviq turn from the free-tier
        // cap. The global kill switch and the route rate limit still apply.
        let resolved = try await AIAssistantClientResolver.resolve(userId: userId, on: req)
        if !resolved.usesOwnKey {
            try await consumeAssistantTurn(userId: userId, req: req)
        }
        let userMessage = try AIAssistantMessage(
            conversationId: conversationId,
            userId: userId,
            role: AIAssistantRole.user.rawValue,
            contentEncrypted: req.userPIIEncryptionService.encryptString(content)
        )
        try await userMessage.create(on: req.db)

        let result = try await runTurn(
            resolved: resolved,
            userId: userId,
            conversation: conversation,
            content: content,
            req: req
        )
        let assistantMessage = try AIAssistantMessage(
            conversationId: conversationId,
            userId: userId,
            role: AIAssistantRole.assistant.rawValue,
            contentEncrypted: req.userPIIEncryptionService.encryptString(result.text)
        )
        conversation.expiresAt = Date().addingTimeInterval(30 * 86400)
        try await req.db.transaction { database in
            try await assistantMessage.create(on: database)
            try await conversation.save(on: database)
        }
        return Outcome(text: result.text, pendingAction: result.pendingAction, assistantMessage: assistantMessage)
    }

    /// Executes a pending action the user has explicitly approved.
    ///
    /// Status and expiry are re-checked inside the transaction, so a stale or
    /// replayed confirmation — a Telegram button tapped twice, say — cannot
    /// execute the action a second time.
    static func confirm(
        actionId: UUID,
        userId: UUID,
        req: Request
    ) async throws -> AIConfirmedActionExecutor.Result {
        try await req.db.transaction { database -> AIConfirmedActionExecutor.Result in
            guard let action = try await AIPendingAction.query(on: database)
                .filter(\.$id == actionId).filter(\.$userId == userId).first()
            else { throw Abort(.notFound) }
            guard action.status == AIActionStatus.pending.rawValue, action.expiresAt > Date() else {
                throw Abort(.conflict, reason: "Action is no longer available for confirmation.")
            }
            let audit = AIActionAudit()
            audit.userId = userId; audit.pendingActionId = actionId; audit.toolName = action.toolName; audit.status = "executing"
            try await audit.create(on: database)
            action.status = AIActionStatus.confirmed.rawValue
            try await action.save(on: database)
            let argumentsText = try req.userPIIEncryptionService.decryptString(action.argumentsEncrypted)
            guard let arguments = argumentsText.data(using: .utf8) else { throw Abort(.badRequest) }
            let executed = try await AIConfirmedActionExecutor().execute(
                toolName: action.toolName,
                arguments: arguments,
                userId: userId,
                on: database
            )
            action.status = AIActionStatus.completed.rawValue
            audit.status = AIActionStatus.completed.rawValue
            try await action.save(on: database); try await audit.save(on: database)
            return executed
        }
    }

    /// Runs one turn with whichever client the resolver picked.
    ///
    /// On a user's own key, an upstream auth failure is translated into a typed
    /// `AIUserCredentialFailure` and recorded on the credential, so the settings
    /// page can show "key rejected" without the user having to hit Test. When
    /// running on Norviq's key the error passes through untouched.
    static func runTurn(
        resolved: ResolvedAssistantClient,
        userId: UUID,
        conversation: AIConversation,
        content: String,
        req: Request
    ) async throws -> AIAssistantTurnService.Result {
        // The kill switch normally runs inside consumeAssistantTurn, which a
        // BYO turn skips — so apply it here too. Bringing your own key does not
        // opt you out of Norviq's own controls.
        if resolved.usesOwnKey {
            try AICostControls.requireEnabled(reason: "The assistant is temporarily unavailable.")
        }

        do {
            let result = try await AIAssistantTurnService(client: resolved.client)
                .generate(userId: userId, conversation: conversation, userMessage: content, req: req)
            if let credential = resolved.credential {
                await AIAssistantClientResolver.recordSuccess(credential, on: req)
            }
            return result
        } catch let upstream as OpenAIChatUpstreamError {
            guard let credential = resolved.credential, let id = credential.id else { throw upstream }

            let failure: AIUserCredentialFailure = if upstream.isAuthFailure {
                .rejected(provider: credential.provider, credentialId: id)
            } else if upstream.isRateLimit {
                .rateLimited(provider: credential.provider, credentialId: id)
            } else {
                .unreachable(provider: credential.provider, credentialId: id)
            }
            await AIAssistantClientResolver.recordFailure(credential, failure: failure, on: req)

            // Falling back would quietly move the bill to Norviq and hide a
            // credential the user asked us to use, so it is off by default.
            if AICredentialSettings.fallbackToNorviqKey {
                req.logger.warning("ai_credential_fallback provider=\(credential.provider)")
                // Plan-routed: moving the bill to Norviq is bad enough without
                // also moving a free user onto the paid chain.
                let routed = await AIPlanRouting.client(for: userId, on: req)
                return try await AIAssistantTurnService(client: routed.client)
                    .generate(userId: userId, conversation: conversation, userMessage: content, req: req)
            }
            // 424 reads exactly right: your upstream dependency failed, not ours.
            throw Abort(.failedDependency, reason: failure.userFacingMessage)
        }
    }

    /// Spends one turn from the user's monthly allowance.
    ///
    /// Every entry point shares this counter. A linked Telegram chat must never
    /// be a cheaper door to the model than the app is.
    static func consumeAssistantTurn(userId: UUID, req: Request) async throws {
        try AICostControls.requireEnabled(reason: "The assistant is temporarily unavailable.")
        let billing = try await req.application.billingContextService.context(userId: userId, on: req.db)
        let calendar = Calendar(identifier: .gregorian)
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        let freeLimit = AICostControls.freeMonthlyLimit
        try await req.db.transaction { database in
            let usage = try await AIAssistantUsage.query(on: database).filter(\.$userId == userId)
                .filter(\.$monthStart == month).first() ?? AIAssistantUsage(userId: userId, monthStart: month)
            guard billing.isPro || usage.requestCount < freeLimit else {
                throw Abort(
                    .paymentRequired,
                    reason: "The free AI preview includes \(freeLimit) requests per month."
                )
            }
            usage.requestCount += 1; try await usage.save(on: database)
        }
    }
}
