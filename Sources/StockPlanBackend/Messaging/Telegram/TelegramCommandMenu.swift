import Vapor

/// Publishes the bot's command menu on boot.
///
/// This used to live in `TelegramPoller.didBoot`, which only runs in polling
/// mode — so production, which uses webhooks, never registered a menu at all and
/// the `/` list in Telegram stayed empty no matter what `MessagingCommands`
/// implemented. Registration has nothing to do with how updates arrive, so it
/// belongs on its own handler that runs whenever a bot is configured.
///
/// Best-effort by design: `registerCommands` swallows its own failures, and a
/// missing menu costs discoverability, not the bot.
struct TelegramCommandMenu: LifecycleHandler {
    let client: TelegramClient

    func didBoot(_ application: Application) throws {
        Task {
            let req = Request(
                application: application,
                method: .POST,
                url: URI(string: "/internal/telegram-command-menu"),
                on: application.eventLoopGroup.next()
            )
            await client.registerCommands(req: req)
        }
    }
}
