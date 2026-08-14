import Vapor

/// Env knobs for bring-your-own-key. Sits beside `AICostControls`, which is
/// already the home for AI feature switches.
enum AICredentialSettings {
    /// Kill switch. Off means the routes 503 and the resolver never looks a
    /// credential up, so the assistant stays on Norviq's key.
    static var enabled: Bool {
        envBool("AI_USER_CREDENTIALS_ENABLED", default: true)
    }

    /// Whether a *rejected* user key silently falls back to Norviq's key.
    ///
    /// Default false, deliberately. Falling back turns the user's mistake into
    /// a silent Norviq bill and hides a broken credential the user explicitly
    /// asked us to use. Absence of a credential is a different case and always
    /// falls back.
    static var fallbackToNorviqKey: Bool {
        envBool("AI_USER_CREDENTIAL_FALLBACK", default: false)
    }

    static var verifyTimeoutSeconds: Int {
        Environment.get("AI_USER_CREDENTIAL_VERIFY_TIMEOUT_SECONDS").flatMap(Int.init) ?? 10
    }

    private static func envBool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let raw = Environment.get(key)?.lowercased() else { return defaultValue }
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return defaultValue
        }
    }
}
