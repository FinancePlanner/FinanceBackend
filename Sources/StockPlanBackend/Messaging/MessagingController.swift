import Fluent
import Foundation
import StockPlanShared
import Vapor

// MARK: - DTOs

struct TelegramStatusResponse: Content {
    /// False when the deployment has no bot configured. Clients hide the whole
    /// feature rather than offering a Connect button that cannot work.
    let available: Bool
    let connected: Bool
    let botUsername: String
    let lastSeenAt: String?
    let connectedAt: String?
}

struct TelegramCodeResponse: Content {
    /// Plaintext, returned on exactly this one response and never readable
    /// again — only its hash is stored.
    let code: String
    let expiresAt: String
    /// Ready-made `https://t.me/...` link so clients do not each rebuild it.
    let deepLink: String
}

struct TelegramPreferenceItem: Content {
    let kind: String
    let enabled: Bool
    let quietHoursStart: Int?
    let quietHoursEnd: Int?
    let timezone: String
}

struct TelegramPreferencesResponse: Content {
    let preferences: [TelegramPreferenceItem]
}

struct TelegramPreferenceUpdateRequest: Content {
    let kind: String
    let enabled: Bool
    let quietHoursStart: Int?
    let quietHoursEnd: Int?
    let timezone: String?
}

// MARK: - Controller

/// Account-side management of the Telegram link.
///
/// Note what is *not* here: nothing accepts a chat id from a client. A chat is
/// only ever bound by redeeming a code inside the chat itself, which is what
/// proves the person holding the account also holds the chat.
struct MessagingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let group = routes
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
            .grouped("integrations", "telegram")
        group.get(use: status)
        group.post("code", use: createCode)
        group.delete(use: disconnect)
        group.get("preferences", use: listPreferences)
        group.put("preferences", use: updatePreference)
    }

    @Sendable func status(req: Request) async throws -> TelegramStatusResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        guard let config = req.telegramConfiguration else {
            return TelegramStatusResponse(
                available: false, connected: false, botUsername: "",
                lastSeenAt: nil, connectedAt: nil
            )
        }
        let link = try await MessagingLinkService.link(
            userId: userId, platform: MessagingPlatform.telegram, req: req
        )
        return TelegramStatusResponse(
            available: true,
            connected: link != nil,
            botUsername: config.botUsername,
            lastSeenAt: link?.lastSeenAt.map(Self.timestamp),
            connectedAt: link?.createdAt.map(Self.timestamp)
        )
    }

    @Sendable func createCode(req: Request) async throws -> TelegramCodeResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        guard let config = req.telegramConfiguration else {
            throw Abort(.serviceUnavailable, reason: "Telegram is not configured.")
        }
        let code = try await MessagingLinkService.issueCode(
            userId: userId, platform: MessagingPlatform.telegram, req: req
        )
        return TelegramCodeResponse(
            code: code,
            expiresAt: Self.timestamp(Date().addingTimeInterval(MessagingLinkService.codeTTL)),
            deepLink: "https://t.me/\(config.botUsername)?start=\(code)"
        )
    }

    @Sendable func disconnect(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        try await MessagingLinkService.unlink(
            userId: userId, platform: MessagingPlatform.telegram, req: req
        )
        return .noContent
    }

    @Sendable func listPreferences(req: Request) async throws -> TelegramPreferencesResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let stored = try await MessagingPreferenceService.preferences(
            userId: userId, platform: MessagingPlatform.telegram, on: req.db
        )
        let byKind = Dictionary(uniqueKeysWithValues: stored.map { ($0.kind, $0) })
        // Every kind is listed, so a client renders the full set of switches
        // without having to know the enum. Unstored kinds report as off.
        let items = NotificationEventKind.allCases.map { kind -> TelegramPreferenceItem in
            let row = byKind[kind.rawValue]
            return TelegramPreferenceItem(
                kind: kind.rawValue,
                enabled: row?.enabled ?? false,
                quietHoursStart: row?.quietHoursStart,
                quietHoursEnd: row?.quietHoursEnd,
                timezone: row?.timezone ?? "UTC"
            )
        }
        return TelegramPreferencesResponse(preferences: items)
    }

    @Sendable func updatePreference(req: Request) async throws -> TelegramPreferencesResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let payload = try req.content.decode(TelegramPreferenceUpdateRequest.self)
        guard let kind = NotificationEventKind(rawValue: payload.kind) else {
            throw Abort(.badRequest, reason: "Unknown notification kind.")
        }
        try Self.validateQuietHours(start: payload.quietHoursStart, end: payload.quietHoursEnd)
        let timezone = payload.timezone ?? "UTC"
        guard TimeZone(identifier: timezone) != nil else {
            throw Abort(.badRequest, reason: "Unknown timezone identifier.")
        }
        try await MessagingPreferenceService.set(
            userId: userId,
            platform: MessagingPlatform.telegram,
            kind: kind,
            enabled: payload.enabled,
            quietHoursStart: payload.quietHoursStart,
            quietHoursEnd: payload.quietHoursEnd,
            timezone: timezone,
            on: req.db
        )
        return try await listPreferences(req: req)
    }

    static func validateQuietHours(start: Int?, end: Int?) throws {
        switch (start, end) {
        case (nil, nil):
            return
        case let (start?, end?):
            guard (0 ... 23).contains(start), (0 ... 23).contains(end) else {
                throw Abort(.badRequest, reason: "Quiet hours must be hours between 0 and 23.")
            }
        default:
            // One bound alone describes no window, and silently ignoring it
            // would look like it had been saved.
            throw Abort(.badRequest, reason: "Quiet hours need both a start and an end, or neither.")
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
