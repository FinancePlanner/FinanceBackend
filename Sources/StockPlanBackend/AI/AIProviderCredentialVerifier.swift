import Foundation
import NIOCore
import Vapor

/// Why a credential check failed. A stable code, never provider error text —
/// provider errors sometimes echo the submitted key back at us.
enum AIProviderVerifyErrorCode: String, Sendable {
    case invalidKey = "invalid_key"
    case restricted
    case rateLimited = "rate_limited"
    case unreachable
}

struct AIProviderVerifyResult: Sendable {
    let ok: Bool
    let errorCode: AIProviderVerifyErrorCode?
    let detail: String
    let latencyMs: Int

    /// A rate-limited key is almost certainly valid — we just could not prove
    /// it. Callers use this to leave `status` untouched instead of marking the
    /// credential invalid on what is a transient condition.
    var isInconclusive: Bool {
        errorCode == .rateLimited || errorCode == .unreachable
    }
}

protocol AIProviderCredentialVerifier: Sendable {
    func verify(
        provider: UserAIProvider,
        apiKey: String,
        baseURL: String?,
        defaultModel: String?,
        on req: Request
    ) async throws -> AIProviderVerifyResult
}

/// Checks a key with the cheapest authenticated call each provider offers.
/// These are metadata reads: they cost no inference tokens.
struct DefaultAIProviderCredentialVerifier: AIProviderCredentialVerifier {
    /// Deliberately short. This runs inside a user-facing request, and
    /// `DefaultOpenAIChatClient` setting no timeout at all is a bug we are not
    /// copying.
    let timeout: TimeAmount

    init(timeoutSeconds: Int = 10) {
        timeout = .seconds(Int64(timeoutSeconds))
    }

    func verify(
        provider: UserAIProvider,
        apiKey: String,
        baseURL: String?,
        defaultModel: String?,
        on req: Request
    ) async throws -> AIProviderVerifyResult {
        let started = Date()

        func elapsed() -> Int {
            Int(Date().timeIntervalSince(started) * 1000)
        }

        let resolvedBase = try resolveBaseURL(provider: provider, baseURL: baseURL)

        do {
            let response = try await req.client.get(URI(string: "\(resolvedBase)/models")) { clientReq in
                clientReq.timeout = timeout
                applyAuth(provider: provider, apiKey: apiKey, to: &clientReq)
            }

            switch response.status.code {
            case 200 ..< 300:
                return AIProviderVerifyResult(
                    ok: true,
                    errorCode: nil,
                    detail: "Key accepted.",
                    latencyMs: elapsed()
                )
            case 401:
                logFailure(req, provider: provider, apiKey: apiKey, response: response)
                return AIProviderVerifyResult(
                    ok: false, errorCode: .invalidKey,
                    detail: "The provider rejected this key.", latencyMs: elapsed()
                )
            case 403:
                logFailure(req, provider: provider, apiKey: apiKey, response: response)
                return AIProviderVerifyResult(
                    ok: false, errorCode: .restricted,
                    detail: "The key is valid but not permitted to use this endpoint.",
                    latencyMs: elapsed()
                )
            case 429:
                return AIProviderVerifyResult(
                    ok: false, errorCode: .rateLimited,
                    detail: "The provider is rate limiting us; the key is probably fine.",
                    latencyMs: elapsed()
                )
            case 404, 405:
                guard provider == .compatible else {
                    logFailure(req, provider: provider, apiKey: apiKey, response: response)
                    return AIProviderVerifyResult(
                        ok: false, errorCode: .unreachable,
                        detail: "The provider returned \(response.status.code).",
                        latencyMs: elapsed()
                    )
                }
                // Plenty of self-hosted gateways never implement /models. Fall
                // back to a one-token completion, which is why `defaultModel`
                // is mandatory for this provider.
                return try await probeChatCompletion(
                    baseURL: resolvedBase, apiKey: apiKey,
                    model: defaultModel, startedAt: started, on: req
                )
            default:
                logFailure(req, provider: provider, apiKey: apiKey, response: response)
                return AIProviderVerifyResult(
                    ok: false, errorCode: .unreachable,
                    detail: "The provider returned \(response.status.code).",
                    latencyMs: elapsed()
                )
            }
        } catch {
            req.logger.warning("ai_credential_verify_unreachable provider=\(provider.rawValue)")
            return AIProviderVerifyResult(
                ok: false, errorCode: .unreachable,
                detail: "Could not reach the provider.", latencyMs: elapsed()
            )
        }
    }

    // MARK: - Helpers

    private func resolveBaseURL(provider: UserAIProvider, baseURL: String?) throws -> String {
        if let explicit = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            // Re-checked here and not only at create time: a host that resolved
            // to a public address when it was saved can point elsewhere now.
            _ = try OutboundURLGuard.validateForRequest(explicit)
            return explicit.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let fallback = provider.defaultBaseURL else {
            throw Abort(.badRequest, reason: "A base URL is required for this provider.")
        }
        return fallback
    }

    private func applyAuth(provider: UserAIProvider, apiKey: String, to clientReq: inout ClientRequest) {
        switch provider {
        case .anthropic:
            // Anthropic's native /models needs both headers. Omitting the
            // version header yields a 400 that is easily mistaken for a bad key.
            clientReq.headers.replaceOrAdd(name: "x-api-key", value: apiKey)
            clientReq.headers.replaceOrAdd(name: "anthropic-version", value: "2023-06-01")
        case .openAI, .compatible:
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
        }
    }

    private func probeChatCompletion(
        baseURL: String,
        apiKey: String,
        model: String?,
        startedAt: Date,
        on req: Request
    ) async throws -> AIProviderVerifyResult {
        func elapsed() -> Int {
            Int(Date().timeIntervalSince(startedAt) * 1000)
        }

        guard let model, !model.isEmpty else {
            return AIProviderVerifyResult(
                ok: false, errorCode: .unreachable,
                detail: "This endpoint has no /models list, so a default model is required to test it.",
                latencyMs: elapsed()
            )
        }

        struct Probe: Content {
            let model: String
            let messages: [[String: String]]
            // swiftlint:disable:next identifier_name
            let max_tokens: Int
        }

        let response = try await req.client.post(URI(string: "\(baseURL)/chat/completions")) { clientReq in
            clientReq.timeout = timeout
            clientReq.headers.contentType = .json
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            try clientReq.content.encode(Probe(
                model: model,
                messages: [["role": "user", "content": "hi"]],
                max_tokens: 1
            ))
        }

        if (200 ..< 300).contains(Int(response.status.code)) {
            return AIProviderVerifyResult(
                ok: true, errorCode: nil,
                detail: "Key accepted (verified with a one-token completion).",
                latencyMs: elapsed()
            )
        }
        logFailure(req, provider: .compatible, apiKey: apiKey, response: response)
        return AIProviderVerifyResult(
            ok: false,
            errorCode: response.status.code == 401 ? .invalidKey : .unreachable,
            detail: "The endpoint returned \(response.status.code).",
            latencyMs: elapsed()
        )
    }

    /// Logs a truncated body, and drops it entirely if it contains the key —
    /// some providers echo the credential back in their error payload.
    private func logFailure(
        _ req: Request,
        provider: UserAIProvider,
        apiKey: String,
        response: ClientResponse
    ) {
        let raw = response.body.map { String(buffer: $0) } ?? ""
        let safe = raw.contains(apiKey) ? "<redacted: contained the key>" : String(raw.prefix(300))
        req.logger.warning(
            "ai_credential_verify_failed provider=\(provider.rawValue) status=\(response.status.code) body=\(safe)"
        )
    }
}

/// Used when the feature is switched off, and as a seam in tests.
struct DisabledAIProviderCredentialVerifier: AIProviderCredentialVerifier {
    func verify(
        provider _: UserAIProvider,
        apiKey _: String,
        baseURL _: String?,
        defaultModel _: String?,
        on _: Request
    ) async throws -> AIProviderVerifyResult {
        AIProviderVerifyResult(
            ok: false, errorCode: .unreachable,
            detail: "Credential verification is disabled.", latencyMs: 0
        )
    }
}

extension Application {
    struct AIProviderCredentialVerifierKey: StorageKey {
        typealias Value = any AIProviderCredentialVerifier
    }

    var aiProviderCredentialVerifier: any AIProviderCredentialVerifier {
        get { storage[AIProviderCredentialVerifierKey.self] ?? DefaultAIProviderCredentialVerifier() }
        set { storage[AIProviderCredentialVerifierKey.self] = newValue }
    }
}
