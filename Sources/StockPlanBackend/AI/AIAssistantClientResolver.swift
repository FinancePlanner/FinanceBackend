import Fluent
import Foundation
import Vapor

/// A user's own provider key was rejected mid-turn.
///
/// Distinct from the generic `.badGateway` that `DefaultOpenAIChatClient`
/// raises, so callers can tell "your credential is broken" apart from "Norviq's
/// AI is down" and say so to the user.
enum AIUserCredentialFailure: Error {
    case rejected(provider: String, credentialId: UUID)
    case rateLimited(provider: String, credentialId: UUID)
    case unreachable(provider: String, credentialId: UUID)

    var provider: String {
        switch self {
        case let .rejected(provider, _), let .rateLimited(provider, _), let .unreachable(provider, _):
            provider
        }
    }

    var credentialId: UUID {
        switch self {
        case let .rejected(_, id), let .rateLimited(_, id), let .unreachable(_, id):
            id
        }
    }

    var userFacingMessage: String {
        switch self {
        case .rejected:
            "Your \(provider) key was rejected. Update it in Settings → AI providers."
        case .rateLimited:
            "Your \(provider) account is rate limiting requests. Try again shortly."
        case .unreachable:
            "Could not reach \(provider) with your key. Try again shortly."
        }
    }

    var errorCode: String {
        switch self {
        case .rejected: "user_credential_rejected"
        case .rateLimited: "user_credential_rate_limited"
        case .unreachable: "user_credential_unreachable"
        }
    }
}

/// What the assistant should use for one turn.
struct ResolvedAssistantClient {
    let client: any OpenAIChatClient
    /// Nil when running on Norviq's own key.
    let credential: UserAIProviderCredential?
    /// Which plan's chain served the turn. Nil when the turn ran on the user's
    /// own key, or when plan routing is off — in both cases the plan did not
    /// pick the model.
    let plan: AIPlanTier?

    init(
        client: any OpenAIChatClient,
        credential: UserAIProviderCredential?,
        plan: AIPlanTier? = nil
    ) {
        self.client = client
        self.credential = credential
        self.plan = plan
    }

    /// A user paying for their own inference must not also spend a Norviq turn
    /// from the free-tier cap.
    var usesOwnKey: Bool {
        credential != nil
    }
}

enum AIAssistantClientResolver {
    /// Picks the chat client for this user's turn.
    ///
    /// With no stored credential this returns `app.openAIChatClient` unchanged,
    /// which is load-bearing for the test suite: `AIChatTests` and
    /// `WhyMovedTests` inject a `ScriptedChatClient` there and must keep
    /// passing untouched.
    ///
    /// Background and aggregate paths (`WhyMovedService`, the insights and chat
    /// services wired in `configure.swift`) deliberately stay on Norviq's key —
    /// they are not user-attributed conversation turns.
    static func resolve(userId: UUID, on req: Request) async throws -> ResolvedAssistantClient {
        guard AICredentialSettings.enabled else {
            return await platformClient(userId: userId, on: req)
        }

        let candidates = try await UserAIProviderCredential.query(on: req.db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .all()

        guard let row = candidates.first(where: { $0.isUsable }), let provider = row.providerKind else {
            return await platformClient(userId: userId, on: req)
        }

        guard req.tokenEncryptionService.isEncrypted(row.apiKeyEncrypted) else {
            req.logger.error("ai_credential_not_encrypted user=\(userId) provider=\(row.provider)")
            return await platformClient(userId: userId, on: req)
        }
        let apiKey = try req.tokenEncryptionService.decrypt(row.apiKeyEncrypted, context: .aiProvider)

        let config = AIProviderConfiguration.load()
        let baseURL = try resolveBaseURL(row: row, provider: provider)
        let model = row.defaultModel.flatMap { $0.isEmpty ? nil : $0 } ?? config.chatModel

        let client = DefaultOpenAIChatClient(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            // The org's output cap still applies — a user's key does not let
            // them opt out of Norviq's own limits.
            maxTokens: config.maxTokens
        )

        return ResolvedAssistantClient(client: client, credential: row)
    }

    /// The chain for a turn running on Norviq's own key, chosen by the user's
    /// plan.
    ///
    /// OpenRouter has no idea who is a paying Norviq user; it runs the slug it is
    /// handed. So the entitlement is read here and the plan picks the chain,
    /// rather than letting a free user's turn spend credits on the paid model and
    /// waiting for a failure to demote it.
    private static func platformClient(
        userId: UUID,
        on req: Request
    ) async -> ResolvedAssistantClient {
        let routed = await AIPlanRouting.client(for: userId, on: req)
        return ResolvedAssistantClient(client: routed.client, credential: nil, plan: routed.plan)
    }

    /// Records the outcome of a turn on the credential so the settings page can
    /// show a red badge without the user having to hit Test.
    static func recordSuccess(_ credential: UserAIProviderCredential, on req: Request) async {
        credential.lastUsedAt = Date()
        do { try await credential.save(on: req.db) } catch {
            req.logger.warning("ai_credential_last_used_write_failed")
        }
    }

    static func recordFailure(
        _ credential: UserAIProviderCredential,
        failure: AIUserCredentialFailure,
        on req: Request
    ) async {
        credential.lastErrorAt = Date()
        switch failure {
        case .rejected:
            credential.status = UserAIProviderCredentialStatus.invalid.rawValue
            credential.lastErrorCode = AIProviderVerifyErrorCode.invalidKey.rawValue
        case .rateLimited:
            credential.lastErrorCode = AIProviderVerifyErrorCode.rateLimited.rawValue
        case .unreachable:
            credential.lastErrorCode = AIProviderVerifyErrorCode.unreachable.rawValue
        }
        do { try await credential.save(on: req.db) } catch {
            req.logger.warning("ai_credential_failure_write_failed")
        }
    }

    /// Re-validates the stored base URL at use time. A host that resolved to a
    /// public address when it was saved can point somewhere else by now.
    private static func resolveBaseURL(row: UserAIProviderCredential, provider: UserAIProvider) throws -> String {
        if let raw = row.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            _ = try OutboundURLGuard.validate(raw)
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let fallback = provider.defaultBaseURL else {
            throw Abort(.badRequest, reason: "Stored credential has no usable base URL.")
        }
        return fallback
    }
}
