import Fluent
import Foundation
import NIOCore
import Vapor

final class AIAssistantRetentionJob: LifecycleHandler, @unchecked Sendable {
    private var scheduled: RepeatedTask?

    func didBoot(_ app: Application) throws {
        scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .minutes(3),
            delay: .hours(24)
        ) { _ in
            Task { await self.runOnce(app) }
        }
    }

    func shutdown(_: Application) {
        scheduled?.cancel()
        scheduled = nil
    }

    func runOnce(_ app: Application) async {
        do {
            let now = Date()
            try await AIConversation.query(on: app.db).filter(\.$expiresAt < now).delete()
            try await AIAssistantTip.query(on: app.db).filter(\.$expiresAt < now).delete()

            let expiredActions = try await AIPendingAction.query(on: app.db)
                .filter(\.$status == "pending")
                .filter(\.$expiresAt < now)
                .all()
            for action in expiredActions {
                action.status = "expired"
                try await action.save(on: app.db)
            }

            let calendar = Calendar(identifier: .gregorian)
            if let usageCutoff = calendar.date(byAdding: .month, value: -14, to: now) {
                try await AIAssistantUsage.query(on: app.db).filter(\.$monthStart < usageCutoff).delete()
            }
            if let auditCutoff = calendar.date(byAdding: .day, value: -90, to: now) {
                try await AIActionAudit.query(on: app.db).filter(\.$createdAt < auditCutoff).delete()
            }
        } catch {
            app.logger.warning("ai_assistant.retention_failed error=\(error)")
        }
    }
}

final class AIDailyTipJob: LifecycleHandler, @unchecked Sendable {
    private struct ResponsesRequest: Content {
        let model: String
        let input: String
        let store: Bool
        let maxOutputTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, input, store
            case maxOutputTokens = "max_output_tokens"
        }
    }

    private struct ResponsesResponse: Content {
        struct Output: Codable { let content: [Part]? }
        struct Part: Codable { let type: String?; let text: String? }
        let output: [Output]
    }

    private struct GeneratedTip: Decodable {
        let kind: String
        let title: String
        let body: String
        let importance: Int
        let actionPath: String?
    }

    private var scheduled: RepeatedTask?

    func didBoot(_ app: Application) throws {
        guard AIProviderConfiguration.load().isConfigured else {
            app.logger.notice("ai_assistant.daily_tips disabled reason=missing_ai_provider_key")
            return
        }
        scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .minutes(10),
            delay: .hours(24)
        ) { _ in
            Task { await self.runOnce(app) }
        }
    }

    func shutdown(_: Application) {
        scheduled?.cancel()
        scheduled = nil
    }

    func runOnce(_ app: Application) async {
        guard AICostControls.proactiveTipsEnabled else {
            app.logger.info("ai_assistant.daily_tips_skipped reason=disabled")
            return
        }
        do {
            let preferences = try await AIAssistantPreference.query(on: app.db)
                .filter(\.$proactiveTipsEnabled == true)
                .all()
            for preference in preferences {
                do {
                    let billing = try await app.billingContextService.context(userId: preference.userId, on: app.db)
                    guard billing.isPro else { continue }
                    try await generateIfMeaningful(for: preference.userId, app: app)
                } catch {
                    app.logger.warning("ai_assistant.daily_tip_user_failed user_id=\(preference.userId) error=\(error)")
                }
            }
        } catch {
            app.logger.error("ai_assistant.daily_tips_failed error=\(error)")
        }
    }

    private func generateIfMeaningful(for userId: UUID, app: Application) async throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let alreadyGenerated = try await AIAssistantTip.query(on: app.db)
            .filter(\.$userId == userId)
            .filter(\.$createdAt >= dayStart)
            .count() > 0
        guard !alreadyGenerated else { return }

        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)
        else { return }

        let expenses = try await Expense.query(on: app.db)
            .filter(\.$user.$id == userId)
            .filter(\.$occurredOn >= monthStart)
            .filter(\.$occurredOn < nextMonth)
            .all()
        guard !expenses.isEmpty else { return }

        let budget = try await BudgetSnapshot.query(on: app.db)
            .filter(\.$user.$id == userId)
            .filter(\.$monthStart == monthStart)
            .first()
        guard let budget, budget.netSalary > 0 else { return }

        let spent = expenses.reduce(0) { partial, expense in
            partial + expense.amount * max(0, min(100, expense.userSharePercent)) / 100
        }
        let day = max(1, calendar.component(.day, from: now))
        let days = max(day, calendar.range(of: .day, in: .month, for: now)?.count ?? 30)
        let expectedToDate = budget.netSalary * 0.80 * Double(day) / Double(days)
        let overspendRatio = expectedToDate > 0 ? (spent - expectedToDate) / expectedToDate : 0
        let projectedSavingsRate = 1 - ((spent / Double(day) * Double(days)) / budget.netSalary)

        // Avoid noisy notifications. Generate only when the trajectory differs materially.
        guard overspendRatio >= 0.05 || projectedSavingsRate < 0.20 else { return }

        let prompt = """
        You are Q, Norviq's cautious personal-finance assistant. Produce one concise, actionable observation.
        Use only the aggregate values below. Do not invent categories, transactions, currency, or facts.
        Do not provide legal, tax, or investment instructions. Avoid shame and certainty.

        Current month progress: day \(day) of \(days)
        Net monthly income: \(round2(budget.netSalary))
        Spending to date: \(round2(spent))
        Expected spending to date at an 80% spending target: \(round2(expectedToDate))
        Difference ratio: \(round2(overspendRatio * 100)) percent
        Projected savings rate: \(round2(projectedSavingsRate * 100)) percent

        Return JSON only with this shape:
        {"kind":"spending|budget|savings","title":"max 70 characters","body":"max 280 characters","importance":1,"actionPath":"/reports"}
        importance must be 1, 2, or 3. Use 3 only for a difference of at least 25 percent.
        """

        let provider = AIProviderConfiguration.load()
        let response = try await app.client.post(URI(string: "\(provider.baseURL)/responses")) { request in
            request.headers.bearerAuthorization = .init(token: provider.apiKey)
            try request.content.encode(ResponsesRequest(model: provider.tipsModel, input: prompt, store: false, maxOutputTokens: 350))
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "OpenAI Responses API returned \(response.status.code).")
        }

        // Not `response.content.decode`: that uses the global `JSONDecoder.backendAPI`,
        // whose key strategy camel-cases snake_case keys before `CodingKeys` lookup and
        // silently nils them out. This payload happens to have no such key today; decoding
        // it as a provider payload keeps that from becoming load-bearing.
        let envelope = try DefaultOpenAIChatClient.decodeProviderJSON(
            ResponsesResponse.self,
            from: response,
            logger: app.logger
        )
        guard let raw = envelope.output.flatMap({ $0.content ?? [] })
            .first(where: { $0.type == "output_text" })?.text,
            let data = normalizedJSON(raw).data(using: .utf8)
        else { throw Abort(.badGateway, reason: "OpenAI returned no tip content.") }
        let generated = try JSONDecoder().decode(GeneratedTip.self, from: data)

        let title = String(generated.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(70))
        let body = String(generated.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        guard !title.isEmpty, !body.isEmpty else { return }

        let tip = AIAssistantTip()
        tip.userId = userId
        tip.kind = ["spending", "budget", "savings"].contains(generated.kind) ? generated.kind : "budget"
        tip.titleEncrypted = try app.userPIIEncryptionService.encryptString(title)
        tip.bodyEncrypted = try app.userPIIEncryptionService.encryptString(body)
        tip.importance = max(1, min(3, generated.importance))
        tip.actionPath = generated.actionPath
        tip.isSeen = false
        tip.isDismissed = false
        tip.expiresAt = now.addingTimeInterval(7 * 86400)
        try await tip.create(on: app.db)
    }

    private func normalizedJSON(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```json") {
            result.removeFirst(7)
        } else if result.hasPrefix("```") {
            result.removeFirst(3)
        }
        if result.hasSuffix("```") {
            result.removeLast(3)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
