import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Which alert kinds a user wants delivered to a messaging platform.
///
/// A row exists only for a kind the user has explicitly turned on. Absence
/// means off, so a newly added alert kind never starts pushing to someone's
/// chat because a migration defaulted it to true.
final class MessagingPreference: Model, @unchecked Sendable {
    static let schema = "messaging_preferences"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "platform")
    var platform: String

    /// A `NotificationEventKind` raw value.
    @Field(key: "kind")
    var kind: String

    @Field(key: "enabled")
    var enabled: Bool

    /// Local hour (0–23) from which alerts may be delivered. Both bounds nil
    /// means no quiet hours.
    @OptionalField(key: "quiet_hours_start")
    var quietHoursStart: Int?

    @OptionalField(key: "quiet_hours_end")
    var quietHoursEnd: Int?

    /// IANA identifier. Quiet hours are meaningless without one.
    @Field(key: "timezone")
    var timezone: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        userId: UUID,
        platform: String,
        kind: String,
        enabled: Bool,
        quietHoursStart: Int? = nil,
        quietHoursEnd: Int? = nil,
        timezone: String = "UTC"
    ) {
        self.userId = userId
        self.platform = platform
        self.kind = kind
        self.enabled = enabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.timezone = timezone
    }
}

enum MessagingPreferenceService {
    /// Whether this alert may be delivered to this platform right now.
    ///
    /// Two independent gates: the user opted this kind in at all, and the
    /// current local time is outside their quiet hours.
    static func allowsDelivery(
        userId: UUID,
        platform: String,
        kind: NotificationEventKind,
        at date: Date = Date(),
        on db: any Database
    ) async throws -> Bool {
        guard let preference = try await MessagingPreference.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$platform == platform)
            .filter(\.$kind == kind.rawValue)
            .first()
        else { return false }
        guard preference.enabled else { return false }
        return !isQuiet(preference, at: date)
    }

    /// Handles a window that wraps midnight (22 → 8) as well as one that does
    /// not (1 → 6).
    static func isQuiet(_ preference: MessagingPreference, at date: Date) -> Bool {
        guard let start = preference.quietHoursStart, let end = preference.quietHoursEnd, start != end else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        // An unknown identifier must not silently become UTC and deliver an
        // alert at 3am; treat it as quiet-hours-off instead.
        guard let zone = TimeZone(identifier: preference.timezone) else { return false }
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    static func preferences(userId: UUID, platform: String, on db: any Database) async throws -> [MessagingPreference] {
        try await MessagingPreference.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$platform == platform)
            .all()
    }

    /// Upserts one kind's setting.
    static func set(
        userId: UUID,
        platform: String,
        kind: NotificationEventKind,
        enabled: Bool,
        quietHoursStart: Int?,
        quietHoursEnd: Int?,
        timezone: String,
        on db: any Database
    ) async throws {
        if let existing = try await MessagingPreference.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$platform == platform)
            .filter(\.$kind == kind.rawValue)
            .first()
        {
            existing.enabled = enabled
            existing.quietHoursStart = quietHoursStart
            existing.quietHoursEnd = quietHoursEnd
            existing.timezone = timezone
            try await existing.save(on: db)
            return
        }
        try await MessagingPreference(
            userId: userId,
            platform: platform,
            kind: kind.rawValue,
            enabled: enabled,
            quietHoursStart: quietHoursStart,
            quietHoursEnd: quietHoursEnd,
            timezone: timezone
        ).create(on: db)
    }
}
