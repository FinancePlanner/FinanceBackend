import Fluent
import Foundation

/// Which upstream a user-supplied key talks to.
///
/// The third case is deliberately named `compatible`, not `hermes`: "Hermes"
/// already means the self-hosted insights scraper in this codebase
/// (`HERMES_BASE_URL`, `HermesSyncJob`, `hermesHealthCheck`), and a second
/// meaning would wreck log search. The web UI is free to label it "Hermes".
enum UserAIProvider: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openAI = "openai"
    case compatible

    /// Anthropic is reached through its OpenAI-compatible Chat Completions
    /// endpoint. The assistant's whole tool loop is built on OpenAI semantics,
    /// and a native Messages-API adapter is a separate piece of work.
    ///
    /// Known cost of the compatibility layer: `reasoning_details` does not
    /// round-trip, which can degrade multi-round tool calls.
    var defaultBaseURL: String? {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .openAI: "https://api.openai.com/v1"
        case .compatible: nil
        }
    }

    /// Whether the caller must supply `baseURL` and `defaultModel` themselves.
    var requiresExplicitEndpoint: Bool {
        self == .compatible
    }
}

/// Status of a stored credential, as shown on the settings page.
enum UserAIProviderCredentialStatus: String, Codable, Sendable {
    case unverified
    case active
    case invalid
    case disabled
}

/// A user's own LLM provider API key, encrypted at rest.
///
/// The plaintext key is never returned to any caller after creation — unlike a
/// personal access token, Norviq did not mint it and the user already has a
/// copy, so echoing it back would only create a second one to leak.
final class UserAIProviderCredential: Model, @unchecked Sendable {
    static let schema = "user_ai_provider_credentials"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "provider")
    var provider: String

    @Field(key: "label")
    var label: String

    /// `nvq-enc:<base64 envelope>` produced by `TokenEncryptionService` under
    /// `CredentialContext.aiProvider`.
    @Field(key: "api_key_encrypted")
    var apiKeyEncrypted: String

    /// Last four characters of the plaintext, computed once at write time so
    /// the UI can tell two keys apart without ever decrypting.
    @Field(key: "key_hint")
    var keyHint: String

    /// SHA-256 of the plaintext. Lets us compare or dedupe keys without
    /// decrypting, and lets a test prove the stored column is not the key.
    @Field(key: "key_fingerprint")
    var keyFingerprint: String

    @Field(key: "base_url")
    var baseURL: String?

    @Field(key: "default_model")
    var defaultModel: String?

    @Field(key: "status")
    var status: String

    @Field(key: "last_verified_at")
    var lastVerifiedAt: Date?

    @Field(key: "last_used_at")
    var lastUsedAt: Date?

    /// A stable code (`invalid_key`, `rate_limited`, `unreachable`) and never
    /// provider error text, which can echo the submitted key back at us.
    @Field(key: "last_error_code")
    var lastErrorCode: String?

    @Field(key: "last_error_at")
    var lastErrorAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        provider: UserAIProvider,
        label: String,
        apiKeyEncrypted: String,
        keyHint: String,
        keyFingerprint: String,
        baseURL: String? = nil,
        defaultModel: String? = nil,
        status: UserAIProviderCredentialStatus = .unverified
    ) {
        self.id = id
        self.userId = userId
        self.provider = provider.rawValue
        self.label = label
        self.apiKeyEncrypted = apiKeyEncrypted
        self.keyHint = keyHint
        self.keyFingerprint = keyFingerprint
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.status = status.rawValue
    }
}

extension UserAIProviderCredential {
    var providerKind: UserAIProvider? {
        UserAIProvider(rawValue: provider)
    }

    var statusKind: UserAIProviderCredentialStatus {
        UserAIProviderCredentialStatus(rawValue: status) ?? .unverified
    }

    /// Usable for a live assistant turn. `unverified` counts: a key the user
    /// never explicitly tested may still be perfectly good, and refusing it
    /// would be a worse failure than trying it.
    var isUsable: Bool {
        switch statusKind {
        case .active, .unverified: true
        case .invalid, .disabled: false
        }
    }

    /// The last four characters, or fewer for an implausibly short key.
    static func hint(for rawKey: String) -> String {
        String(rawKey.suffix(4))
    }
}
