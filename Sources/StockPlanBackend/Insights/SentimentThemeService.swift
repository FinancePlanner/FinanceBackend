import Fluent
import Foundation
import Vapor

protocol SentimentThemeGenerating: Sendable {
    func generateThemes(
        symbol: String,
        posts: [TickerSentimentPost],
        on req: Request
    ) async throws -> SentimentThemesPayload?
}

/// Turns a day's posts about one symbol into the handful of things retail is
/// actually arguing about.
///
/// Follows the split already established by `DefaultAIInsightsService`: the
/// server computes every number, the model only names and narrates. The score,
/// the counts and the stance tallies are all decided by `SentimentAggregator`
/// before this runs — if the model returns nothing, the row still ships intact.
struct DefaultSentimentThemeService: SentimentThemeGenerating {
    let client: any OpenAIChatClient
    let maxPosts: Int
    let maxThemes: Int

    func generateThemes(
        symbol: String,
        posts: [TickerSentimentPost],
        on req: Request
    ) async throws -> SentimentThemesPayload? {
        let sample = Array(posts.prefix(maxPosts))
        guard !sample.isEmpty else { return nil }

        let factsJSON = try encodeFacts(symbol: symbol, posts: sample)
        let messages = [
            OpenAIMessage(role: "system", content: Self.systemPrompt),
            OpenAIMessage(role: "user", content: Self.userPrompt(symbol: symbol, factsJSON: factsJSON)),
        ]

        let reply = try await client.chat(
            messages: messages,
            tools: [],
            responseFormat: "json_object",
            on: req
        )
        guard let content = reply.content, let data = content.data(using: .utf8) else {
            return nil
        }

        let parsed: ThemeReply
        do {
            parsed = try JSONDecoder().decode(ThemeReply.self, from: data)
        } catch {
            req.logger.warning("sentiment.themes unparseable symbol=\(symbol) error=\(String(describing: error))")
            return nil
        }

        let themes = parsed.themes
            .prefix(maxThemes)
            .map {
                SentimentTheme(
                    label: String($0.label.prefix(60)),
                    stance: Self.normalizeStance($0.stance),
                    evidenceCount: max(0, min($0.evidenceCount ?? 0, sample.count))
                )
            }

        guard !themes.isEmpty || parsed.summary?.isEmpty == false else { return nil }

        return SentimentThemesPayload(
            themes: Array(themes),
            summary: parsed.summary.map { String($0.prefix(400)) },
            contrarianFlag: parsed.contrarianFlag ?? false
        )
    }

    private func encodeFacts(symbol: String, posts: [TickerSentimentPost]) throws -> String {
        let facts = Facts(
            symbol: symbol,
            postCount: posts.count,
            posts: posts.map {
                Facts.Post(
                    source: $0.resolvedSource.rawValue,
                    label: $0.sentimentLabel,
                    // Trimmed hard: the model needs the gist, and post text is
                    // uncapped in storage.
                    text: String($0.text.prefix(280))
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(facts)
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalizeStance(_ raw: String) -> String {
        switch raw.lowercased() {
        case "bullish", "positive": "bullish"
        case "bearish", "negative": "bearish"
        default: "mixed"
        }
    }

    private struct Facts: Encodable {
        struct Post: Encodable {
            let source: String
            let label: String
            let text: String
        }

        let symbol: String
        let postCount: Int
        let posts: [Post]
    }

    private struct ThemeReply: Decodable {
        struct Theme: Decodable {
            let label: String
            let stance: String
            let evidenceCount: Int?
        }

        let themes: [Theme]
        let summary: String?
        let contrarianFlag: Bool?

        /// Declared explicitly: a Decodable-only type with a hand-written
        /// initializer gets no synthesized CodingKeys.
        enum CodingKeys: String, CodingKey {
            case themes, summary, contrarianFlag
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            themes = try container.decodeIfPresent([Theme].self, forKey: .themes) ?? []
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            contrarianFlag = try container.decodeIfPresent(Bool.self, forKey: .contrarianFlag)
        }
    }

    /// Constant prefix so prompt caching can discount it across the hundreds of
    /// per-symbol calls one run makes.
    static let systemPrompt = """
    You summarize what retail investors are saying about one stock, based only on \
    social and news posts supplied by the server.

    Rules — follow strictly:
    - Use ONLY the supplied posts. Never introduce outside knowledge about the company.
    - Report what people are SAYING. Do not evaluate whether they are right.
    - This is EDUCATIONAL only. No buy/sell/hold recommendations, no price targets, \
      no predictions.
    - Do not include numeric sentiment scores; the server computes and renders those.
    - If the posts are too thin or off-topic to support a theme, return an empty \
      themes array rather than inventing one.

    Output: return ONLY a JSON object with this exact shape and nothing else:
    {
      "themes": [
        {"label": "<3-6 word topic>", "stance": "bullish|bearish|mixed", "evidenceCount": <int>}
      ],
      "summary": "<1-2 sentence plain-language summary of the conversation>",
      "contrarianFlag": <true when the loudest posts run opposite to the quieter majority>
    }
    """

    static func userPrompt(symbol: String, factsJSON: String) -> String {
        """
        Identify the distinct themes in the retail conversation about \(symbol) below.
        SERVER-SELECTED FACTS:
        \(factsJSON)
        """
    }
}
