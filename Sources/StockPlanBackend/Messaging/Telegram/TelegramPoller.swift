import Foundation
import Vapor

/// Long-polls `getUpdates` instead of receiving a webhook.
///
/// This exists so the bot can be developed against a real Telegram bot from a
/// laptop, with no public URL and no tunnel. Production runs webhook mode —
/// `TelegramConfiguration.validate` refuses to boot a polling bot there,
/// because a rolling deploy briefly runs two pods and two pollers on one token
/// fight over the same update queue.
final class TelegramPoller: LifecycleHandler, @unchecked Sendable {
    private let client: TelegramClient
    private var task: Task<Void, Never>?

    /// Not persisted. The database watermark on `messaging_links` is the real
    /// dedupe; this only avoids re-fetching within a single process lifetime.
    private var offset: Int64 = 0

    static let errorBackoff: Duration = .seconds(5)

    init(client: TelegramClient) {
        self.client = client
    }

    func didBoot(_ application: Application) throws {
        application.logger.info("telegram poller starting (long-polling mode)")
        task = Task { [client] in
            let req = Request(
                application: application,
                method: .POST,
                url: URI(string: "/internal/telegram-poll"),
                on: application.eventLoopGroup.next()
            )
            while !Task.isCancelled {
                do {
                    let updates = try await client.getUpdates(offset: offset, req: req)
                    for update in updates {
                        // Advance before dispatching, mirroring the webhook's
                        // ack-then-answer order: a crash mid-turn must not
                        // replay the same update forever.
                        offset = max(offset, update.updateId + 1)
                        TelegramBridge.dispatch(update, application: application)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    application.logger.warning("telegram_poll_failed error=\(String(reflecting: type(of: error)))")
                    try? await Task.sleep(for: Self.errorBackoff)
                }
            }
        }
    }

    func shutdown(_ application: Application) {
        application.logger.info("telegram poller stopping")
        task?.cancel()
        task = nil
    }
}
