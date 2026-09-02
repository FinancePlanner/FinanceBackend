@preconcurrency import Crypto
import Foundation
import Vapor

protocol UserPIIEncrypting: Sendable {
    func encryptString(_ value: String) throws -> Data
    func decryptString(_ payload: Data) throws -> String
}

enum UserPIIEncryptionError: Error {
    case missingConfiguration(String)
    case malformedConfiguration(String)
    case unknownKeyIdentifier(String)
    case invalidPayload
    case decryptionFailed
}

struct AESGCMUserPIIEncryptionService: UserPIIEncrypting, @unchecked Sendable {
    // Runs once per encrypted PII field on every user read; the coders were
    // built per call before 2026-09-02.
    private static let jsonDecoder = JSONDecoder()
    private static let jsonEncoder = JSONEncoder()
    private struct EnvelopeV1: Codable {
        let version: Int
        let keyID: String
        let combinedCiphertext: String
    }

    private let activeKeyID: String
    private let activeKey: SymmetricKey
    private let keysByID: [String: SymmetricKey]

    init(activeKeyID: String, activeKey: SymmetricKey, previousKeys: [String: SymmetricKey]) {
        self.activeKeyID = activeKeyID
        self.activeKey = activeKey
        var keys = previousKeys
        keys[activeKeyID] = activeKey
        keysByID = keys
    }

    func encryptString(_ value: String) throws -> Data {
        let payload = Data(value.utf8)
        let sealed = try AES.GCM.seal(payload, using: activeKey)
        guard let combined = sealed.combined else {
            throw UserPIIEncryptionError.invalidPayload
        }
        let envelope = EnvelopeV1(
            version: 1,
            keyID: activeKeyID,
            combinedCiphertext: combined.base64EncodedString()
        )
        return try Self.jsonEncoder.encode(envelope)
    }

    /// Encrypts with additional authenticated data so ciphertexts are bound to a
    /// caller-supplied context (e.g. credential type) and cannot be replayed across domains.
    func encryptString(_ value: String, authenticating context: String) throws -> Data {
        let payload = Data(value.utf8)
        let sealed = try AES.GCM.seal(payload, using: activeKey, authenticating: Data(context.utf8))
        guard let combined = sealed.combined else {
            throw UserPIIEncryptionError.invalidPayload
        }
        let envelope = EnvelopeV1(
            version: 2,
            keyID: activeKeyID,
            combinedCiphertext: combined.base64EncodedString()
        )
        return try Self.jsonEncoder.encode(envelope)
    }

    func decryptString(_ payload: Data, authenticating context: String) throws -> String {
        guard let envelope = try? Self.jsonDecoder.decode(EnvelopeV1.self, from: payload),
              envelope.version == 2,
              let key = keysByID[envelope.keyID],
              let combined = Data(base64Encoded: envelope.combinedCiphertext)
        else {
            if let envelope = try? Self.jsonDecoder.decode(EnvelopeV1.self, from: payload),
               keysByID[envelope.keyID] == nil
            {
                throw UserPIIEncryptionError.unknownKeyIdentifier(envelope.keyID)
            }
            throw UserPIIEncryptionError.invalidPayload
        }

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw UserPIIEncryptionError.invalidPayload
        }

        let decrypted: Data
        do {
            decrypted = try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch {
            throw UserPIIEncryptionError.decryptionFailed
        }

        guard let value = String(data: decrypted, encoding: .utf8) else {
            throw UserPIIEncryptionError.invalidPayload
        }
        return value
    }

    func decryptString(_ payload: Data) throws -> String {
        guard let envelope = try? Self.jsonDecoder.decode(EnvelopeV1.self, from: payload),
              envelope.version == 1,
              let key = keysByID[envelope.keyID],
              let combined = Data(base64Encoded: envelope.combinedCiphertext)
        else {
            if let envelope = try? Self.jsonDecoder.decode(EnvelopeV1.self, from: payload),
               keysByID[envelope.keyID] == nil
            {
                throw UserPIIEncryptionError.unknownKeyIdentifier(envelope.keyID)
            }
            throw UserPIIEncryptionError.invalidPayload
        }

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw UserPIIEncryptionError.invalidPayload
        }

        let decrypted: Data
        do {
            decrypted = try AES.GCM.open(box, using: key)
        } catch {
            throw UserPIIEncryptionError.decryptionFailed
        }

        guard let value = String(data: decrypted, encoding: .utf8) else {
            throw UserPIIEncryptionError.invalidPayload
        }
        return value
    }
}

enum UserPIIEncryptionBootstrap {
    private static let defaultNonProductionKeyID = "dev-default"
    private static let defaultNonProductionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="

    static func fromEnvironment(app: Application) throws -> any UserPIIEncrypting {
        try concreteFromEnvironment(app: app)
    }

    static func fromProcessEnvironment(logger: Logger, isProduction: Bool) throws -> any UserPIIEncrypting {
        try concreteFromProcessEnvironment(logger: logger, isProduction: isProduction)
    }

    static func concreteFromEnvironment(app: Application) throws -> AESGCMUserPIIEncryptionService {
        try fromEnvironment(
            isProduction: app.environment == .production,
            logger: app.logger,
            getValue: { Environment.get($0) }
        )
    }

    static func concreteFromProcessEnvironment(logger: Logger, isProduction: Bool) throws -> AESGCMUserPIIEncryptionService {
        try fromEnvironment(
            isProduction: isProduction,
            logger: logger,
            getValue: { ProcessInfo.processInfo.environment[$0] }
        )
    }

    private static func fromEnvironment(
        isProduction: Bool,
        logger: Logger,
        getValue: (String) -> String?
    ) throws -> AESGCMUserPIIEncryptionService {
        let activeKeyID = getValue("USER_PII_ENCRYPTION_ACTIVE_KEY_ID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKeyRaw = getValue("USER_PII_ENCRYPTION_ACTIVE_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedActiveKeyID: String
        let resolvedActiveKeyRaw: String

        if let activeKeyID, !activeKeyID.isEmpty, let activeKeyRaw, !activeKeyRaw.isEmpty {
            resolvedActiveKeyID = activeKeyID
            resolvedActiveKeyRaw = activeKeyRaw
        } else if isProduction {
            throw UserPIIEncryptionError.missingConfiguration(
                "Missing USER_PII_ENCRYPTION_ACTIVE_KEY_ID / USER_PII_ENCRYPTION_ACTIVE_KEY"
            )
        } else {
            resolvedActiveKeyID = defaultNonProductionKeyID
            resolvedActiveKeyRaw = defaultNonProductionKey
            logger.warning("Using non-production fallback user PII encryption key.")
        }

        let activeKey = try decodeBase64Key(
            resolvedActiveKeyRaw,
            environmentVariable: "USER_PII_ENCRYPTION_ACTIVE_KEY"
        )

        let previousKeysRaw = getValue("USER_PII_ENCRYPTION_PREVIOUS_KEYS")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var previousKeys: [String: SymmetricKey] = [:]
        if let previousKeysRaw, !previousKeysRaw.isEmpty {
            for pair in previousKeysRaw.split(separator: ",") {
                let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    throw UserPIIEncryptionError.malformedConfiguration(
                        "Invalid USER_PII_ENCRYPTION_PREVIOUS_KEYS entry format"
                    )
                }
                let keyID = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let rawKey = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyID.isEmpty, !rawKey.isEmpty else {
                    throw UserPIIEncryptionError.malformedConfiguration(
                        "Invalid USER_PII_ENCRYPTION_PREVIOUS_KEYS entry"
                    )
                }

                previousKeys[keyID] = try decodeBase64Key(
                    rawKey,
                    environmentVariable: "USER_PII_ENCRYPTION_PREVIOUS_KEYS"
                )
            }
        }

        return AESGCMUserPIIEncryptionService(
            activeKeyID: resolvedActiveKeyID,
            activeKey: activeKey,
            previousKeys: previousKeys
        )
    }

    private static func decodeBase64Key(
        _ value: String,
        environmentVariable: String
    ) throws -> SymmetricKey {
        guard let keyData = Data(base64Encoded: value), keyData.count == 32 else {
            throw UserPIIEncryptionError.malformedConfiguration(
                "\(environmentVariable) must be base64 for exactly 32 bytes"
            )
        }
        return SymmetricKey(data: keyData)
    }
}

extension Application {
    private struct UserPIIEncryptionServiceKey: StorageKey {
        typealias Value = any UserPIIEncrypting
    }

    var userPIIEncryptionService: any UserPIIEncrypting {
        get {
            guard let service = storage[UserPIIEncryptionServiceKey.self] else {
                fatalError("UserPIIEncryptionService not configured")
            }
            return service
        }
        set {
            storage[UserPIIEncryptionServiceKey.self] = newValue
        }
    }
}

extension Request {
    var userPIIEncryptionService: any UserPIIEncrypting {
        application.userPIIEncryptionService
    }
}
