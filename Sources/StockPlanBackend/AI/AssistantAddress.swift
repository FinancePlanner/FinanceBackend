import Foundation

/// Strips the assistant's name off the front of a message.
///
/// The assistant is called Q, and people address it: "Hey Q, what did I spend?"
/// or "@Q summarise my month". The name is not part of the question, so it is
/// removed before the text reaches the model.
///
/// This is deliberately hand-parsed rather than a regex, because getting it
/// wrong is expensive in a specific way: the Telegram pairing-code alphabet
/// (`MessagingLinkService.codeAlphabet`) contains `Q`, so a naive
/// `hasPrefix("q")` would silently corrupt roughly one in thirty-one pairing
/// codes and leave the user stuck on "That code is not valid or has expired".
/// Placement is the first line of defence — see the call sites, which sit after
/// linking and command handling — and the separator rule below is the second.
enum AssistantAddress {
    /// Openers people put in front of the name. A greeting alone is never
    /// stripped; it only counts when the name follows it.
    private static let greetings = ["hey", "hi", "hello", "ok", "okay", "yo"]

    /// What may sit between the name and the actual question.
    private static let separators: Set<Character> = [" ", "\t", "\n", ",", ":", ".", "!", "?", "-", "—", "–"]

    static func strip(_ text: String) -> String {
        var cursor = Substring(text).drop(while: \.isWhitespace)

        // An opener is optional, and only consumed if the name follows it.
        for greeting in greetings {
            guard cursor.lowercased().hasPrefix(greeting) else { continue }
            let after = cursor.dropFirst(greeting.count)
            guard let next = after.first, next.isWhitespace else { continue }
            cursor = after.drop(while: \.isWhitespace)
            break
        }

        if cursor.first == "@" {
            cursor = cursor.dropFirst()
        }

        guard let initial = cursor.first, initial == "Q" || initial == "q" else { return text }
        let afterName = cursor.dropFirst()

        // The word-boundary rule. A letter or digit straight after the Q means
        // this was never the name: "Q3 earnings", "QQQ", "Quick question",
        // "Qualcomm", and every pairing code starting with Q all land here and
        // are returned untouched.
        guard let boundary = afterName.first else { return text }
        guard separators.contains(boundary) else { return text }

        let remainder = afterName.drop(while: { separators.contains($0) })

        // "Hey Q" on its own is a greeting, not an empty question. Leave it
        // whole so the assistant has something to answer.
        guard !remainder.isEmpty else { return text }

        return String(remainder)
    }
}
