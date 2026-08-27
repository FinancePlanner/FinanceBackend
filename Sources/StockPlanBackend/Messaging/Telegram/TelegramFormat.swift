import Foundation

/// Markdown → Telegram HTML.
///
/// Telegram's `MarkdownV2` requires escaping sixteen characters anywhere they
/// appear, and rejects the *entire message* on one mistake. HTML has three
/// special characters and a small tag vocabulary, so it fails far less often —
/// and when it does, `plain` below is a fallback that always sends.
///
/// The app's own markdown renderer is deliberately not reused: it targets a
/// browser, and Telegram rejects any tag outside its short allowlist.
enum TelegramFormat {
    /// Telegram's hard limit on a single message.
    static let maxMessageCharacters = 4096

    private static let codeBlockPattern = "```(?:[a-zA-Z0-9_+-]*)\\n?([\\s\\S]*?)```"
    private static let inlineCodePattern = "`([^`\\n]+)`"
    private static let linkPattern = "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)"
    private static let headingPattern = "^#{1,6}\\s+(.+)$"
    private static let boldPattern = "\\*\\*([^*\\n]+)\\*\\*"
    private static let italicStarPattern = "(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])"
    private static let italicUnderscorePattern = "(?<![\\w_])_([^_\\n]+)_(?![\\w_])"
    private static let bulletPattern = "^\\s*[-*]\\s+"

    static func html(_ markdown: String) -> String {
        // Code spans come out first so their contents are escaped but never
        // interpreted as emphasis. They go back in last, after tags exist.
        var codeBlocks: [String] = []
        var text = markdown

        text = rewrite(codeBlockPattern, in: text) { groups in
            codeBlocks.append("<pre>" + escape(groups[0]) + "</pre>")
            return placeholder(codeBlocks.count - 1)
        }
        text = rewrite(inlineCodePattern, in: text) { groups in
            codeBlocks.append("<code>" + escape(groups[0]) + "</code>")
            return placeholder(codeBlocks.count - 1)
        }

        text = escape(text)

        // Links before emphasis: a URL can contain underscores.
        text = rewrite(linkPattern, in: text) { groups in
            "<a href=\"\(groups[1])\">\(groups[0])</a>"
        }
        text = rewrite(headingPattern, in: text, options: [.anchorsMatchLines]) { "<b>" + $0[0] + "</b>" }
        text = rewrite(boldPattern, in: text) { "<b>" + $0[0] + "</b>" }
        text = rewrite(italicStarPattern, in: text) { "<i>" + $0[0] + "</i>" }
        text = rewrite(italicUnderscorePattern, in: text) { "<i>" + $0[0] + "</i>" }
        text = rewrite(bulletPattern, in: text, options: [.anchorsMatchLines]) { _ in "• " }

        for (index, block) in codeBlocks.enumerated() {
            text = text.replacingOccurrences(of: placeholder(index), with: block)
        }
        return text
    }

    /// Removes markdown markers without introducing tags, keeping link targets
    /// visible. Used when Telegram refuses the formatted version.
    static func plain(_ markdown: String) -> String {
        var text = markdown
        text = rewrite(codeBlockPattern, in: text) { $0[0] }
        text = rewrite(inlineCodePattern, in: text) { $0[0] }
        text = rewrite(linkPattern, in: text) { "\($0[0]) (\($0[1]))" }
        text = rewrite(headingPattern, in: text, options: [.anchorsMatchLines]) { $0[0] }
        text = rewrite(boldPattern, in: text) { $0[0] }
        text = rewrite(italicStarPattern, in: text) { $0[0] }
        text = rewrite(italicUnderscorePattern, in: text) { $0[0] }
        text = rewrite(bulletPattern, in: text, options: [.anchorsMatchLines]) { _ in "• " }
        return text
    }

    /// Only `& < >`. Quotes are left alone on purpose: Telegram does not need
    /// them escaped in a text node, and escaping them turns every apostrophe in
    /// an ordinary sentence into `&#39;`.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Splits on paragraph, then line, then word boundaries — but only when the
    /// break lands in the second half of the chunk, so one long unbroken run
    /// does not produce a trickle of tiny messages.
    static func split(_ text: String, limit: Int = maxMessageCharacters) -> [String] {
        guard !text.isEmpty else { return [] }
        guard width(text) > limit else { return [text] }
        var parts: [String] = []
        var remaining = Substring(text)
        while width(remaining) > limit {
            let window = prefix(remaining, utf16Limit: limit)
            // Half of *this* window, not half of `limit`: the two differ once the
            // text is not all ASCII, and an emoji window would otherwise never
            // reach the minimum and would always take the mid-word fallback.
            let cut = breakPoint(window, minimum: window.count / 2)
            parts.append(String(remaining[remaining.startIndex ..< cut]).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = remaining[cut...].drop(while: { $0 == "\n" || $0 == " " })
        }
        parts.append(String(remaining).trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.filter { !$0.isEmpty }
    }

    /// Splits into parts whose *rendered* HTML fits a Telegram message.
    ///
    /// `split` alone is not enough for two reasons. It measures the raw markdown,
    /// but what gets posted is `html(part)`, and escaping only ever grows the
    /// string — one `&` becomes five characters, and `<b>`/`<a href>` add tags on
    /// top. It also counts in Swift `Character`s, while Telegram counts UTF-16
    /// code units, so emoji and flags undercount badly.
    /// A split can still land inside a ``` fence, leaving the opening fence to
    /// render as literal text in the first chunk. Preferring boundaries outside
    /// fences would fix it; the answer still arrives intact, so it is left alone.
    static func htmlChunks(_ markdown: String, limit: Int = maxMessageCharacters) -> [String] {
        guard !markdown.isEmpty else { return [] }
        return split(markdown, limit: limit).flatMap { fit($0, limit: limit) }
    }

    /// Shrinks one part until its rendered form fits.
    ///
    /// No fixed safety margin works here: `&` alone expands fivefold, and links
    /// and tags add more on top, so the only honest approach is to render and
    /// measure. Halving converges in a handful of rounds and always terminates.
    private static func fit(_ part: String, limit: Int) -> [String] {
        guard width(html(part)) > limit else { return [part] }
        var budget = limit
        while budget > 16 {
            budget /= 2
            let candidates = split(part, limit: budget)
            if candidates.allSatisfy({ width(html($0)) <= limit }) {
                return candidates
            }
        }
        return split(part, limit: 16)
    }

    /// Length in the unit Telegram actually counts.
    private static func width(_ text: some StringProtocol) -> Int {
        text.utf16.count
    }

    /// Longest prefix within `utf16Limit`, walked by `Character` so a chunk can
    /// never end halfway through a surrogate pair.
    private static func prefix(_ text: Substring, utf16Limit: Int) -> Substring {
        var end = text.startIndex
        var used = 0
        for index in text.indices {
            let next = used + width(String(text[index]))
            if next > utf16Limit {
                break
            }
            used = next
            end = text.index(after: index)
        }
        return text[text.startIndex ..< end]
    }

    private static func breakPoint(_ window: Substring, minimum: Int) -> Substring.Index {
        for separator in ["\n\n", "\n", " "] {
            if let range = window.range(of: separator, options: .backwards),
               window.distance(from: window.startIndex, to: range.lowerBound) >= minimum
            {
                return range.lowerBound
            }
        }
        // No usable boundary: a mid-word split beats not sending the message.
        return window.endIndex
    }

    /// NUL is not valid in a Telegram message, so it cannot collide with text
    /// the model produced.
    private static func placeholder(_ index: Int) -> String {
        "\u{0}CODE\(index)\u{0}"
    }

    /// Applies `transform` to each match's capture groups.
    ///
    /// A malformed pattern returns the text untouched rather than throwing: a
    /// formatting bug must never cost the user their answer.
    private static func rewrite(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [],
        _ transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let full = NSRange(text.startIndex ..< text.endIndex, in: text)
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, options: [], range: full) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var groups: [String] = []
            for index in 1 ..< match.numberOfRanges {
                if let range = Range(match.range(at: index), in: text) {
                    groups.append(String(text[range]))
                } else {
                    groups.append("")
                }
            }
            result += text[last ..< matchRange.lowerBound]
            result += transform(groups)
            last = matchRange.upperBound
        }
        result += text[last...]
        return result
    }
}
