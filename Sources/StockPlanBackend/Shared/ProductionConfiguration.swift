import Vapor

enum ProductionConfiguration {
    static func validate(for app: Application) throws {
        guard app.environment == .production else { return }

        try validateJWTSecret(Environment.get("JWT_SECRET"))
        _ = try allowedOrigins(from: Environment.get("ALLOWED_ORIGINS"), isProduction: true)
        try validateDatabaseCredentials(
            username: Environment.get("DATABASE_USERNAME"),
            password: Environment.get("DATABASE_PASSWORD")
        )
        try validateRequiredSecret(Environment.get("REVENUECAT_API_KEY"), name: "REVENUECAT_API_KEY")
        // Without Redis, `RateLimitMiddleware` and `AIDailyCap` both fail closed
        // and every rate-limited route answers 503 for the pod's whole life.
        // A malformed URL already fails the boot in `ConfigureBootstrap`; a
        // missing one used to only warn, which is how production served 503s on
        // every /v1/ai/* route for three days.
        try validateRequiredSecret(Environment.get("REDIS_URL"), name: "REDIS_URL")

        let webhookSecret = (Environment.get("REVENUECAT_WEBHOOK_SECRET")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let hmacSecret = (Environment.get("REVENUECAT_HMAC_SECRET")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        if webhookSecret.isEmpty, hmacSecret.isEmpty {
            throw Abort(.internalServerError, reason: "Either REVENUECAT_WEBHOOK_SECRET or REVENUECAT_HMAC_SECRET is required in production.")
        }
    }

    static func allowedOrigins(from rawValue: String?, isProduction: Bool) throws -> [String] {
        let configured = rawValue?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let origins = configured, !origins.isEmpty else {
            if isProduction {
                throw Abort(.internalServerError, reason: "ALLOWED_ORIGINS is required in production.")
            }
            return ["http://localhost:3000", "http://localhost:8080"]
        }

        if isProduction {
            let unsafeOrigins = origins.filter { origin in
                let lowercased = origin.lowercased()
                return lowercased == "*"
                    || lowercased.contains("localhost")
                    || lowercased.contains("127.0.0.1")
                    || lowercased.contains("0.0.0.0")
            }
            guard unsafeOrigins.isEmpty else {
                throw Abort(
                    .internalServerError,
                    reason: "ALLOWED_ORIGINS contains unsafe production origins: \(unsafeOrigins.joined(separator: ", "))"
                )
            }
        }

        return origins
    }

    static func validateJWTSecret(_ rawValue: String?) throws {
        let secret = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !secret.isEmpty else {
            throw Abort(.internalServerError, reason: "JWT_SECRET is required in production.")
        }
        guard secret != "dev-secret" else {
            throw Abort(.internalServerError, reason: "JWT_SECRET must not use the development default in production.")
        }
        guard secret.count >= 32 else {
            throw Abort(.internalServerError, reason: "JWT_SECRET must be at least 32 characters in production.")
        }
    }

    static func validateDatabaseCredentials(username rawUsername: String?, password rawPassword: String?) throws {
        let username = rawUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = rawPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !username.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_USERNAME is required in production.")
        }
        guard !password.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_PASSWORD is required in production.")
        }
        let unsafeUsernames = ["postgres", "stockplan_user", "vapor_username", "replace_with_non_default_db_user"]
        guard !unsafeUsernames.contains(username.lowercased()) else {
            throw Abort(.internalServerError, reason: "DATABASE_USERNAME must not use a development/default value in production.")
        }
        let unsafePasswords = ["postgres", "stockplan_password", "vapor_password", "change-me-prod", "replace-with-strong-random-db-password"]
        guard !unsafePasswords.contains(password) else {
            throw Abort(.internalServerError, reason: "DATABASE_PASSWORD must not use a development/default value in production.")
        }
        guard password.count >= 24 else {
            throw Abort(.internalServerError, reason: "DATABASE_PASSWORD must be at least 24 characters in production.")
        }
    }

    static func validateRequiredSecret(_ rawValue: String?, name: String) throws {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw Abort(.internalServerError, reason: "\(name) is required in production.")
        }
    }
}
