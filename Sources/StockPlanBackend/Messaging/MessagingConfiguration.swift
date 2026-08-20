import Vapor

/// Telegram wiring, read once at boot.
///
/// Mode is *derived*, never configured directly: a webhook secret means webhook
/// mode, its absence means long-polling. There is deliberately no third flag,
/// because "webhook mode with no secret" — an unauthenticated public endpoint —
/// must not be a state this type can represent.
struct TelegramConfiguration: Sendable {
    let botToken: String
    let botUsername: String
    let webhookSecret: String?

    var usesWebhook: Bool {
        webhookSecret?.isEmpty == false
    }

    static func load() -> TelegramConfiguration? {
        func trimmed(_ key: String) -> String? {
            let value = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        guard let token = trimmed("TELEGRAM_BOT_TOKEN") else { return nil }
        return TelegramConfiguration(
            botToken: token,
            // Leading "@" is how people write it and not how the API wants it.
            botUsername: (trimmed("TELEGRAM_BOT_USERNAME") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@")),
            webhookSecret: trimmed("TELEGRAM_WEBHOOK_SECRET")
        )
    }

    /// The configuration the app should actually run with.
    ///
    /// Production must not run the bot on long-polling: a rolling deploy briefly
    /// runs two pods, and two pollers on one token fight over `getUpdates`, so
    /// the bot would answer roughly every other message.
    ///
    /// A half-configured bot therefore turns *itself* off rather than taking the
    /// API down with it. Refusing to boot would also prevent the bad state, but
    /// the blast radius is wrong: an optional chat integration must not be able
    /// to crash-loop `api.norviq.org` because one of two keys reached `api-env`.
    /// The poller still never starts, which is the property that matters.
    static func resolve(
        _ config: TelegramConfiguration?,
        environment: Environment,
        logger: Logger
    ) -> TelegramConfiguration? {
        guard let config else { return nil }
        guard environment == .production, !config.usesWebhook else { return config }
        logger.error(
            """
            telegram_disabled reason=missing_webhook_secret \
            TELEGRAM_BOT_TOKEN is set in production without TELEGRAM_WEBHOOK_SECRET. \
            The bot is off: seal both keys together, then restart.
            """
        )
        return nil
    }
}

extension Application {
    private struct TelegramConfigurationKey: StorageKey {
        typealias Value = TelegramConfiguration
    }

    /// Nil when no bot token is configured, which is also the signal not to
    /// mount the webhook route or start the poller.
    var telegramConfiguration: TelegramConfiguration? {
        get { storage[TelegramConfigurationKey.self] }
        set { storage[TelegramConfigurationKey.self] = newValue }
    }
}

extension Request {
    var telegramConfiguration: TelegramConfiguration? {
        application.telegramConfiguration
    }
}
