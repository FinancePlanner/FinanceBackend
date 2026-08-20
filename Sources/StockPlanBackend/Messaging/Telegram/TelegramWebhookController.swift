import Foundation
import Vapor

/// Receives Telegram updates in production.
///
/// Registered at the root, outside the `v1` group and outside every
/// authenticator — Telegram cannot present a session. Nothing in the
/// infrastructure protects this path (there is no WAF or auth proxy in front of
/// `api.norviq.org`), so the secret header below is the entire door.
struct TelegramWebhookController: RouteCollection {
    static let secretHeader = "X-Telegram-Bot-Api-Secret-Token"
    static let maxUpdateBytes = 1 << 20

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("webhooks", "telegram").post(use: receive)
    }

    @Sendable
    func receive(req: Request) async throws -> HTTPStatus {
        guard let config = req.telegramConfiguration, let secret = config.webhookSecret else {
            throw Abort(.serviceUnavailable, reason: "Telegram is not configured.")
        }
        let presented = req.headers.first(name: Self.secretHeader) ?? ""
        guard ConstantTime.equals(presented, secret) else {
            // No reason string: a rejected caller learns only that it failed.
            req.logger.warning("telegram webhook rejected an unauthenticated delivery")
            throw Abort(.unauthorized)
        }
        guard let body = req.body.data, body.readableBytes <= Self.maxUpdateBytes else {
            throw Abort(.payloadTooLarge)
        }

        let update: TelegramUpdate
        do {
            update = try JSONDecoder().decode(TelegramUpdate.self, from: Data(buffer: body))
        } catch {
            // A shape we cannot read is not worth a retry storm.
            req.logger.warning("telegram webhook received an undecodable update")
            return .ok
        }

        // Answer Telegram now and think afterwards. A turn can take minutes;
        // holding the delivery open would have Telegram retry it and would make
        // the pending-update queue back up behind one slow model call.
        TelegramBridge.dispatch(update, application: req.application)
        return .ok
    }
}
