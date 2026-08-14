import Foundation
import Vapor

/// Domain-separation context for third-party credentials encrypted at rest.
/// Each context becomes AES-GCM additional authenticated data, so a ciphertext
/// minted for one integration can never be decrypted as another's.
enum CredentialContext: String, Sendable, CaseIterable {
    case broker
    case bankPlaid = "bank_plaid"
    case bankGoCardless = "bank_gocardless"
    /// User-supplied LLM provider API keys (bring-your-own-key).
    case aiProvider = "ai_provider"

    var authenticatedData: String {
        "norviq.credential.\(rawValue)"
    }
}

enum TokenEncryptionError: Error {
    case malformedStoredValue
}

/// Encrypts third-party access/refresh tokens for storage in string columns.
/// Stored format: `nvq-enc:<base64(envelope JSON)>`. Values without the prefix
/// are legacy plaintext; `decrypt` passes them through so callers can lazily
/// re-encrypt on the next write.
protocol TokenEncryptionService: Sendable {
    func encrypt(_ token: String, context: CredentialContext) throws -> String
    func decrypt(_ stored: String, context: CredentialContext) throws -> String
    func isEncrypted(_ stored: String) -> Bool
}

struct AESGCMTokenEncryptionService: TokenEncryptionService {
    static let storagePrefix = "nvq-enc:"

    private let engine: AESGCMUserPIIEncryptionService

    init(engine: AESGCMUserPIIEncryptionService) {
        self.engine = engine
    }

    func encrypt(_ token: String, context: CredentialContext) throws -> String {
        let envelope = try engine.encryptString(token, authenticating: context.authenticatedData)
        return Self.storagePrefix + envelope.base64EncodedString()
    }

    func decrypt(_ stored: String, context: CredentialContext) throws -> String {
        guard isEncrypted(stored) else {
            return stored
        }
        let encoded = String(stored.dropFirst(Self.storagePrefix.count))
        guard let envelope = Data(base64Encoded: encoded) else {
            throw TokenEncryptionError.malformedStoredValue
        }
        return try engine.decryptString(envelope, authenticating: context.authenticatedData)
    }

    func isEncrypted(_ stored: String) -> Bool {
        stored.hasPrefix(Self.storagePrefix)
    }
}

enum TokenEncryptionBootstrap {
    static func fromEnvironment(app: Application) throws -> any TokenEncryptionService {
        try AESGCMTokenEncryptionService(
            engine: UserPIIEncryptionBootstrap.concreteFromEnvironment(app: app)
        )
    }

    static func fromProcessEnvironment(logger: Logger, isProduction: Bool) throws -> any TokenEncryptionService {
        try AESGCMTokenEncryptionService(
            engine: UserPIIEncryptionBootstrap.concreteFromProcessEnvironment(
                logger: logger,
                isProduction: isProduction
            )
        )
    }
}

extension Application {
    private struct TokenEncryptionServiceKey: StorageKey {
        typealias Value = any TokenEncryptionService
    }

    var tokenEncryptionService: any TokenEncryptionService {
        get {
            guard let service = storage[TokenEncryptionServiceKey.self] else {
                fatalError("TokenEncryptionService not configured")
            }
            return service
        }
        set {
            storage[TokenEncryptionServiceKey.self] = newValue
        }
    }
}

extension Request {
    var tokenEncryptionService: any TokenEncryptionService {
        application.tokenEncryptionService
    }
}
