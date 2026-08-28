import Foundation

/// Shared number rendering for anything a user reads.
///
/// Extracted from `DefaultAIInsightsService`, which owned the only copy. A
/// second formatter written for the messaging replies would be how two parts of
/// one product start disagreeing about what a number looks like — the insight
/// card saying `1,204.50` while the Telegram reply says `1204.5`.
///
/// Locale is pinned to `en_US_POSIX` deliberately: these strings are read back
/// by tests and logs as well as people, and a server whose locale drifts must
/// not change what they say.
enum MoneyFormat {
    /// Grouped, always two decimals: `1,204.50`.
    static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func percent(_ value: Double) -> String {
        "\(number(value))%"
    }

    /// A signed amount, so a reply can show direction without a separate word.
    static func signed(_ value: Double) -> String {
        value > 0 ? "+\(number(value))" : number(value)
    }

    static func trend(_ value: Double) -> String {
        if value > 0 {
            return "up"
        }
        if value < 0 {
            return "down"
        }
        return "flat"
    }

    /// Direction as a glyph. Telegram renders these everywhere, and they
    /// survive the plaintext fallback that strips HTML tags.
    static func arrow(_ value: Double) -> String {
        if value > 0 {
            return "▲"
        }
        if value < 0 {
            return "▼"
        }
        return "▬"
    }

    /// First day of the current month, UTC.
    ///
    /// Budget months are stored against a UTC month start, so a reply computed
    /// in local time would query the wrong month for anyone east of Greenwich
    /// on the first of the month.
    static func currentMonthStart(_ now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
    }
}
