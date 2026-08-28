import Foundation
import StockPlanShared

/// Static prompt text. Kept as a constant prefix so OpenAI prompt-caching can
/// discount the system prompt on repeat calls.
enum AIPrompt {
    static let system = """
    You are a financial insights assistant inside a personal finance app. You explain a \
    single user's OWN financial data back to them in plain, friendly language.

    Rules — follow strictly:
    - You may ONLY use the server-selected facts in the user message. Never invent data.
    - Write narrative only. Do not include exact numeric values in the title or body; \
      the server renders verified numeric highlights separately.
    - This is EDUCATIONAL only. Describe and explain what the data shows. Do NOT give \
      financial advice: no buy/sell/hold recommendations, no specific allocation or \
      rebalancing suggestions, no predictions of future returns.
    - Be concise, neutral, and encouraging. No hype.
    - You are speaking to the data's owner about their own data only.

    Output: return ONLY a JSON object with this exact shape and nothing else:
    {
      "title": "<short card title, max ~6 words>",
      "body": "<2-4 sentence plain-language summary>"
    }
    Do not include highlights or a disclaimer; the server adds both.
    """

    static func userPrompt(for kind: AIInsightKind, factsJSON: String) -> String {
        let instruction = switch kind {
        case .expenses:
            "Generate a 'where your money went' narrative."
        case .portfolio:
            "Generate a 'your portfolio at a glance' narrative."
        case .summary:
            "Generate a combined financial snapshot narrative covering spending and portfolio."
        }
        return "\(instruction)\nSERVER-SELECTED FACTS:\n\(factsJSON)"
    }

    /// Narrative for one screen of the app.
    ///
    /// Takes the instruction from `AIViewScope` rather than switching here, so
    /// a new screen is one case in one enum. Same two-message shape and the
    /// same `{"title","body"}` contract as `userPrompt` -- `system` is
    /// untouched, because that constant prefix is what earns the prompt-caching
    /// discount and it already forbids numbers in the prose and any advice.
    static func viewSummaryUserPrompt(scope: AIViewScope, factsJSON: String) -> String {
        "\(scope.instruction)\nSERVER-SELECTED FACTS:\n\(factsJSON)"
    }

    /// One-sentence "why your portfolio moved" summary for the dashboard
    /// hero. Deliberately NOT an AIInsightKind: the shared enum is
    /// exhaustively switched and adding a case would force a package bump.
    static func whyMovedUserPrompt(factsJSON: String) -> String {
        """
        Write ONE sentence (max 25 words) explaining why this portfolio moved \
        today, citing the biggest contributor and, when present, its social \
        sentiment or a market index. Respond as JSON: {"text": "..."}.
        SERVER-SELECTED FACTS:
        \(factsJSON)
        """
    }
}
