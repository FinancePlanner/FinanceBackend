import Fluent
import Foundation
import StockPlanShared
import Vapor

enum NotificationEventPublisher {
    /// Channels an event is offered to, in order.
    ///
    /// A channel declines quietly when it has nowhere to send — no registered
    /// device, no linked chat, or the user has not opted this alert kind in —
    /// so adding one here cannot start messaging people who did not ask.
    static let channels = ["apns", MessagingPlatform.telegram]

    @discardableResult
    static func publishAndPush(
        userId: UUID,
        kind: NotificationEventKind,
        deduplicationKey: String,
        title: String,
        body: String,
        deepLink: String? = nil,
        payload: [String: String] = [:],
        req: Request
    ) async throws -> NotificationEventModel {
        let event = try await publish(
            userId: userId,
            kind: kind,
            deduplicationKey: deduplicationKey,
            title: title,
            body: body,
            deepLink: deepLink,
            payload: payload,
            on: req.db
        )
        guard let eventId = event.id else { return event }

        for channel in channels {
            do {
                try await deliver(
                    channel: channel,
                    eventId: eventId,
                    userId: userId,
                    kind: kind,
                    title: title,
                    body: body,
                    deepLink: deepLink,
                    payload: payload,
                    req: req
                )
            } catch {
                // One channel failing must not deny the user the others.
                req.logger.warning(
                    "notification delivery failed channel=\(channel) event_id=\(eventId) error_type=\(String(reflecting: type(of: error)))"
                )
            }
        }
        return event
    }

    /// Claims `(event, channel)` and, if this process won the claim, sends.
    private static func deliver(
        channel: String,
        eventId: UUID,
        userId: UUID,
        kind: NotificationEventKind,
        title: String,
        body: String,
        deepLink: String?,
        payload: [String: String],
        req: Request
    ) async throws {
        guard let delivery = try await claim(channel: channel, eventId: eventId, req: req) else { return }
        do {
            let outcome = try await send(
                channel: channel,
                eventId: eventId,
                userId: userId,
                kind: kind,
                title: title,
                body: body,
                deepLink: deepLink,
                payload: payload,
                req: req
            )
            delivery.status = outcome.status
            delivery.lastError = outcome.lastError
            try await delivery.update(on: req.db)
        } catch {
            delivery.status = "failed"
            delivery.lastError = String(reflecting: type(of: error))
            try? await delivery.update(on: req.db)
            throw error
        }
    }

    /// Returns the delivery row this process owns, or nil when another already
    /// owns this send.
    private static func claim(channel: String, eventId: UUID, req: Request) async throws -> NotificationDeliveryModel? {
        if let existing = try await existingDelivery(channel: channel, eventId: eventId, req: req) {
            guard existing.status != "delivered",
                  existing.status != "no_devices",
                  existing.status != "pending"
            else {
                return nil
            }
            existing.status = "pending"
            existing.attemptCount += 1
            existing.lastError = nil
            try await existing.update(on: req.db)
            return existing
        }
        let delivery = NotificationDeliveryModel()
        delivery.$event.id = eventId
        delivery.channel = channel
        delivery.status = "pending"
        delivery.attemptCount = 1
        delivery.lastError = nil
        do {
            try await delivery.create(on: req.db)
            return delivery
        } catch {
            // The unique (event, channel) index is the final concurrency guard.
            // If another publisher created the claim, it owns this send attempt.
            if try await existingDelivery(channel: channel, eventId: eventId, req: req) != nil {
                return nil
            }
            throw error
        }
    }

    private static func existingDelivery(
        channel: String,
        eventId: UUID,
        req: Request
    ) async throws -> NotificationDeliveryModel? {
        try await NotificationDeliveryModel.query(on: req.db)
            .filter(\.$event.$id == eventId)
            .filter(\.$channel == channel)
            .first()
    }

    private struct DeliveryOutcome {
        let status: String
        let lastError: String?

        /// Nothing to send to. Terminal, and deliberately not "failed": there
        /// is nothing to retry until the user connects something.
        static let noTarget = DeliveryOutcome(status: "no_devices", lastError: nil)
    }

    private static func send(
        channel: String,
        eventId: UUID,
        userId: UUID,
        kind: NotificationEventKind,
        title: String,
        body: String,
        deepLink: String?,
        payload: [String: String],
        req: Request
    ) async throws -> DeliveryOutcome {
        switch channel {
        case "apns":
            let devices = try await req.pushDeviceService.activeDevices(userId: userId, on: req.db)
            guard devices.isEmpty == false else { return .noTarget }
            let summary = await req.application.pushNotificationSender.sendAutomationAlert(
                message: AutomationPushMessage(
                    eventId: eventId,
                    kind: kind,
                    title: title,
                    body: body,
                    deepLink: deepLink,
                    payload: payload
                ),
                devices: devices,
                req: req
            )
            return DeliveryOutcome(
                status: summary.delivered > 0 ? "delivered" : "failed",
                lastError: summary.failed > 0 ? "Failed deliveries: \(summary.failed)" : nil
            )

        case MessagingPlatform.telegram:
            guard let config = req.telegramConfiguration else { return .noTarget }
            // Opt-in per alert kind, plus quiet hours. Without this the bot
            // would relay every poller in the system unprompted.
            guard try await MessagingPreferenceService.allowsDelivery(
                userId: userId,
                platform: MessagingPlatform.telegram,
                kind: kind,
                on: req.db
            ) else { return .noTarget }
            guard let link = try await MessagingLinkService.link(
                userId: userId,
                platform: MessagingPlatform.telegram,
                req: req
            ) else { return .noTarget }

            let client = TelegramClient(token: config.botToken)
            var text = "*\(title)*\n\(body)"
            if let deepLink {
                text += "\n\n\(deepLink)"
            }
            try await client.send(chatID: link.externalID, message: OutboundMessage(text: text), req: req)
            return DeliveryOutcome(status: "delivered", lastError: nil)

        default:
            return .noTarget
        }
    }

    @discardableResult
    static func publish(
        userId: UUID,
        kind: NotificationEventKind,
        deduplicationKey: String,
        title: String,
        body: String,
        deepLink: String? = nil,
        payload: [String: String] = [:],
        on db: any Database
    ) async throws -> NotificationEventModel {
        if let existing = try await NotificationEventModel.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$deduplicationKey == deduplicationKey)
            .first()
        {
            return existing
        }
        let event = NotificationEventModel(
            userId: userId,
            kind: kind,
            deduplicationKey: deduplicationKey,
            title: title,
            body: body,
            deepLink: deepLink,
            payload: payload
        )
        do {
            try await event.create(on: db)
            return event
        } catch {
            if let existing = try await NotificationEventModel.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$deduplicationKey == deduplicationKey)
                .first()
            {
                return existing
            }
            throw error
        }
    }
}
