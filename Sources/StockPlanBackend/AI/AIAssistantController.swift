import Fluent
import Foundation
import StockPlanShared
import Vapor

struct AIAssistantController: RouteCollection {
    private struct CreateConversationPayload: Content { let title: String? }
    private struct CreateMessagePayload: Content { let content: String }
    private struct PreferencesPayload: Content {
        let proactiveTipsEnabled: Bool
        let pushEnabled: Bool
        let timezone: String
    }

    func boot(routes: any RoutesBuilder) throws {
        let group = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware()).grouped("ai", "assistant")
        group.get("conversations", use: listConversations)
        group.post("conversations", use: createConversation)
        group.get("conversations", ":id", use: getConversation)
        group.delete("conversations", ":id", use: deleteConversation)
        group.post("conversations", ":id", "messages", use: createMessage)
        group.post("conversations", ":id", "chat", use: chat)
        group.post("conversations", ":id", "stream", use: streamChat)
        group.get("preferences", use: getPreferences)
        group.put("preferences", use: updatePreferences)
        group.get("tips", use: listTips)
        group.post("tips", ":id", "seen", use: markTipSeen)
        group.delete("tips", ":id", use: dismissTip)
        group.get("usage", use: getUsage)
        group.get("actions", use: listPendingActions)
        group.post("actions", ":id", "cancel", use: cancelAction)
        group.post("actions", ":id", "confirm", use: confirmAction)
    }

    @Sendable private func listConversations(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        let rows = try await AIConversation.query(on: req.db).filter(\.$userId == userId)
            .filter(\.$expiresAt > Date()).sort(\.$updatedAt, .descending).limit(50).all()
        return try json(rows.map {
            try AIConversationSummaryResponse(id: $0.requireID().uuidString,
                                              title: req.userPIIEncryptionService.decryptString($0.titleEncrypted),
                                              lastMessagePreview: nil, createdAt: timestamp($0.createdAt),
                                              updatedAt: timestamp($0.updatedAt ?? $0.createdAt))
        })
    }

    @Sendable private func createConversation(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        let payload = try req.content.decode(CreateConversationPayload.self)
        let title = String(payload.title?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120) ?? "New conversation")
        let row = try AIConversation(userId: userId,
                                     titleEncrypted: req.userPIIEncryptionService.encryptString(title),
                                     expiresAt: Date().addingTimeInterval(30 * 86400))
        try await row.create(on: req.db)
        // Starting fresh in the app starts fresh everywhere. The alternative --
        // leaving a linked Telegram chat on the thread the user just walked away
        // from -- is the incoherence the stored pairing exists to remove.
        // Unconditional: the client only reaches here for a deliberate "New
        // conversation" (or a first-run account with none), and it is a no-op
        // for users with no linked chats.
        try await MessagingConversations.bindLinks(userId: userId, to: row.requireID(), req: req)
        return try json(AIConversationResponse(id: row.requireID().uuidString, title: title,
                                               messages: [], createdAt: timestamp(row.createdAt), updatedAt: timestamp(row.updatedAt ?? row.createdAt)), status: .created)
    }

    @Sendable private func getConversation(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        let row = try await ownedConversation(req, userId)
        let rowID = try row.requireID()
        let messages = try await AIAssistantMessage.query(on: req.db)
            .filter(\.$conversation.$id == rowID).filter(\.$userId == userId)
            .sort(\.$createdAt, .ascending).all()
        let values = try messages.map { message in
            try AIMessageResponse(id: message.requireID().uuidString, conversationId: rowID.uuidString,
                                  role: AIAssistantRole(rawValue: message.role) ?? .assistant,
                                  content: req.userPIIEncryptionService.decryptString(message.contentEncrypted),
                                  createdAt: timestamp(message.createdAt))
        }
        return try json(AIConversationResponse(id: rowID.uuidString,
                                               title: req.userPIIEncryptionService.decryptString(row.titleEncrypted), messages: values,
                                               createdAt: timestamp(row.createdAt), updatedAt: timestamp(row.updatedAt ?? row.createdAt)))
    }

    @Sendable private func deleteConversation(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        try await ownedConversation(req, userId).delete(on: req.db)
        return .noContent
    }

    @Sendable private func createMessage(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        let conversation = try await ownedConversation(req, userId)
        let content = try req.content.decode(CreateMessagePayload.self).content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.count <= 12000 else { throw Abort(.badRequest, reason: "Message must contain 1 to 12,000 characters.") }
        try await consumeGeneration(userId, req)
        let message = try AIAssistantMessage(conversationId: conversation.requireID(), userId: userId,
                                             role: AIAssistantRole.user.rawValue,
                                             contentEncrypted: req.userPIIEncryptionService.encryptString(content))
        conversation.expiresAt = Date().addingTimeInterval(30 * 86400)
        try await req.db.transaction { db in try await message.create(on: db); try await conversation.save(on: db) }
        return try json(AIMessageResponse(id: message.requireID().uuidString,
                                          conversationId: conversation.requireID().uuidString, role: .user,
                                          content: content, createdAt: timestamp(message.createdAt)), status: .created)
    }

    @Sendable private func getPreferences(req: Request) async throws -> Response {
        let row = try await preference(req.auth.require(SessionToken.self).userId, req.db)
        return try json(AIAssistantPreferencesResponse(proactiveTipsEnabled: row.proactiveTipsEnabled,
                                                       pushEnabled: row.pushEnabled, timezone: row.timezone))
    }

    @Sendable private func updatePreferences(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        let payload = try req.content.decode(PreferencesPayload.self)
        guard TimeZone(identifier: payload.timezone) != nil else { throw Abort(.badRequest, reason: "Invalid IANA timezone.") }
        let row = try await preference(userId, req.db)
        row.proactiveTipsEnabled = payload.proactiveTipsEnabled; row.pushEnabled = payload.pushEnabled; row.timezone = payload.timezone
        try await row.save(on: req.db)
        return try json(AIAssistantPreferencesResponse(proactiveTipsEnabled: row.proactiveTipsEnabled,
                                                       pushEnabled: row.pushEnabled, timezone: row.timezone))
    }

    @Sendable private func listTips(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        let rows = try await AIAssistantTip.query(on: req.db).filter(\.$userId == userId)
            .filter(\.$isDismissed == false).filter(\.$expiresAt > Date())
            .sort(\.$createdAt, .descending).limit(30).all()
        return try json(rows.map {
            try AITipResponse(id: $0.requireID().uuidString, kind: $0.kind,
                              title: req.userPIIEncryptionService.decryptString($0.titleEncrypted),
                              body: req.userPIIEncryptionService.decryptString($0.bodyEncrypted),
                              importance: $0.importance, actionPath: $0.actionPath,
                              createdAt: timestamp($0.createdAt), expiresAt: timestamp($0.expiresAt))
        })
    }

    @Sendable private func markTipSeen(req: Request) async throws -> HTTPStatus {
        let row = try await ownedTip(req); row.isSeen = true; try await row.save(on: req.db); return .noContent
    }

    @Sendable private func dismissTip(req: Request) async throws -> HTTPStatus {
        let row = try await ownedTip(req); row.isDismissed = true; try await row.save(on: req.db); return .noContent
    }

    @Sendable private func getUsage(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        let start = monthStart()
        let used = try await AIAssistantUsage.query(on: req.db).filter(\.$userId == userId)
            .filter(\.$monthStart == start).first()?.requestCount ?? 0
        let billing = try await req.application.billingContextService.context(userId: userId, on: req.db)
        return try json(AIAssistantUsageResponse(month: monthString(start), used: used,
                                                 limit: billing.isPro ? nil : AICostControls.freeMonthlyLimit,
                                                 remaining: billing.isPro ? nil : max(0, AICostControls.freeMonthlyLimit - used),
                                                 isPro: billing.isPro))
    }

    @Sendable private func listPendingActions(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        let rows = try await AIPendingAction.query(on: req.db).filter(\.$userId == userId)
            .filter(\.$status == AIActionStatus.pending.rawValue).filter(\.$expiresAt > Date())
            .sort(\.$createdAt, .descending).all()
        return try json(rows.map {
            try AIPendingActionResponse(id: $0.requireID().uuidString,
                                        conversationId: $0.conversationId?.uuidString, toolName: $0.toolName,
                                        summary: req.userPIIEncryptionService.decryptString($0.summaryEncrypted),
                                        arguments: req.userPIIEncryptionService.decryptString($0.argumentsEncrypted),
                                        status: AIActionStatus(rawValue: $0.status) ?? .pending,
                                        expiresAt: timestamp($0.expiresAt), createdAt: timestamp($0.createdAt))
        })
    }

    @Sendable private func cancelAction(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        guard let id = req.parameters.get("id", as: UUID.self),
              let row = try await AIPendingAction.query(on: req.db).filter(\.$id == id).filter(\.$userId == userId).first()
        else { throw Abort(.notFound) }
        guard row.status == AIActionStatus.pending.rawValue else { throw Abort(.conflict, reason: "Action is no longer pending.") }
        row.status = AIActionStatus.cancelled.rawValue; try await row.save(on: req.db); return .noContent
    }

    private func ownedConversation(_ req: Request, _ userId: UUID) async throws -> AIConversation {
        guard let id = req.parameters.get("id", as: UUID.self),
              let row = try await AIConversation.query(on: req.db).filter(\.$id == id).filter(\.$userId == userId).first()
        else { throw Abort(.notFound) }; return row
    }

    private func ownedTip(_ req: Request) async throws -> AIAssistantTip {
        let userId = try req.auth.require(SessionToken.self).userId
        guard let id = req.parameters.get("id", as: UUID.self),
              let row = try await AIAssistantTip.query(on: req.db).filter(\.$id == id).filter(\.$userId == userId).first()
        else { throw Abort(.notFound) }; return row
    }

    private func preference(_ userId: UUID, _ db: any Database) async throws -> AIAssistantPreference {
        if let row = try await AIAssistantPreference.query(on: db).filter(\.$userId == userId).first() {
            return row
        }
        let row = AIAssistantPreference(userId: userId); try await row.create(on: db); return row
    }

    private func consumeGeneration(_ userId: UUID, _ req: Request) async throws {
        let billing = try await req.application.billingContextService.context(userId: userId, on: req.db)
        let start = monthStart()
        try await req.db.transaction { transaction in
            let row = try await AIAssistantUsage.query(on: transaction).filter(\.$userId == userId)
                .filter(\.$monthStart == start).first() ?? AIAssistantUsage(userId: userId, monthStart: start)
            guard billing.isPro || row.requestCount < 5 else {
                throw Abort(.paymentRequired, reason: "The free AI preview includes 5 requests per month.")
            }
            row.requestCount += 1; try await row.save(on: transaction)
        }
    }

    private func monthStart() -> Date {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
    }

    private func timestamp(_ date: Date?) -> String {
        ISO8601DateFormatter().string(from: date ?? Date())
    }

    private func monthString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"; return formatter.string(from: date)
    }

    private func json(_ value: some Encodable, status: HTTPStatus = .ok) throws -> Response {
        let response = Response(status: status); try response.content.encode(value, as: .json); return response
    }
}
