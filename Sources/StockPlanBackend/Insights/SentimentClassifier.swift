import Foundation

/// Deterministic lexicon scorer for a single retail post.
///
/// This replaces three divergent copies that previously lived inside
/// `DeepAPIInsightsProvider` (one for web snippets, one for tweets, one for
/// Reddit). They disagreed on thresholds, on vocabulary, and on what a score of
/// zero meant, so the same sentence scored differently depending on which feed
/// carried it.
///
/// Three behaviours differ from the code it replaces, deliberately:
///
/// 1. **Word-boundary matching for words.** The old scorers used `contains`, so
///    `"up"` fired on "supply", "disruption" and "upset", and `"down"` fired on
///    "download". Only phrases and emoji are matched as substrings now.
/// 2. **Negation.** "not bullish" previously scored bullish.
/// 3. **Confidence measures evidence, not score.** The old value was
///    `min(1, abs(score) * 2)` — a restatement of the score wearing a different
///    name. A one-word post and a fifty-word post with the same polarity are
///    not equally trustworthy, and now they no longer claim to be.
///
/// Pure and synchronous by design: no I/O, so it is cheap to test exhaustively.
enum SentimentClassifier {
    struct Result: Sendable, Equatable {
        /// -1…1. `nil` when the text carried no sentiment-bearing term at all —
        /// distinct from a genuine neutral reading of mixed signals.
        var score: Double?
        var label: String
        /// 0…1, driven by how much evidence was found.
        var confidence: Double
        var matchCount: Int
    }

    static let positiveLabel = "positive"
    static let neutralLabel = "neutral"
    static let negativeLabel = "negative"

    /// Matches `DefaultInsightsService.sentimentLabel(forScore:postLabels:)` so
    /// per-post labels and aggregate labels never disagree about the same number.
    static let labelThreshold = 0.15

    /// Saturation constant. Score approaches ±1 asymptotically, so a post that
    /// stacks ten bullish words is stronger than one with two, but never
    /// infinitely so.
    private static let saturation = 2.0

    /// How many tokens back a negator reaches.
    private static let negationWindow = 3

    static func classify(_ text: String) -> Result {
        let lowered = text.lowercased()
        let tokens = tokenize(lowered)

        var sum = 0.0
        var matches = 0

        // Phrases and emoji: substring matching is correct here, because these
        // carry their own boundaries.
        for (phrase, weight) in phraseLexicon where lowered.contains(phrase) {
            sum += weight
            matches += 1
        }

        // Single words: boundary-matched against the token stream.
        for (index, token) in tokens.enumerated() {
            guard let weight = wordLexicon[token] else { continue }
            matches += 1
            sum += isNegated(tokens: tokens, termIndex: index) ? -weight * 0.8 : weight
        }

        guard matches > 0 else {
            return Result(score: nil, label: neutralLabel, confidence: 0, matchCount: 0)
        }

        let score = sum / (abs(sum) + saturation)
        return Result(
            score: score,
            label: label(forScore: score),
            confidence: confidence(matchCount: matches, score: score),
            matchCount: matches
        )
    }

    static func label(forScore score: Double) -> String {
        if score > labelThreshold {
            return positiveLabel
        }
        if score < -labelThreshold {
            return negativeLabel
        }
        return neutralLabel
    }

    /// Evidence volume first, polarity strength second. Four or more matched
    /// terms is treated as a saturated amount of evidence for one short post.
    private static func confidence(matchCount: Int, score: Double) -> Double {
        let evidence = min(1.0, Double(matchCount) / 4.0)
        return min(1.0, evidence * (0.5 + 0.5 * abs(score)))
    }

    private static func isNegated(tokens: [String], termIndex: Int) -> Bool {
        let lowerBound = max(0, termIndex - negationWindow)
        guard lowerBound < termIndex else { return false }
        return tokens[lowerBound ..< termIndex].contains { negators.contains($0) }
    }

    /// Splits on anything that is not a letter, digit, or an intra-word
    /// apostrophe. Cashtags and hashtags lose their sigil, which is what we
    /// want — `$TSLA` and `TSLA` are the same token.
    static func tokenize(_ lowercasedText: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        for character in lowercasedText {
            if character.isLetter || character.isNumber || character == "'" {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private static let negators: Set<String> = [
        "not", "no", "never", "isn't", "isnt", "aren't", "arent", "wasn't", "wasnt",
        "won't", "wont", "don't", "dont", "doesn't", "doesnt", "didn't", "didnt",
        "can't", "cant", "cannot", "nothing", "hardly", "barely", "without", "avoid",
    ]

    /// Weights are polarity, not confidence: ±1.0 for terms that are only ever
    /// used one way, ±0.5 for terms that carry direction but also appear in
    /// neutral market commentary.
    private static let wordLexicon: [String: Double] = {
        var lexicon: [String: Double] = [:]

        let strongBullish = [
            "bullish", "moon", "mooning", "moass", "squeeze", "rally", "rallying",
            "soar", "soared", "soaring", "surge", "surged", "surging", "breakout",
            "outperform", "outperformed", "undervalued", "oversold", "accumulate",
            "accumulating", "longing", "bagholding",
        ]
        // "up" and "down" are only safe here because matching is
        // boundary-based. Under the old `contains` scorers they fired on
        // "supply", "disruption" and "download".
        let mildBullish = [
            "up", "buy", "buying", "bought", "long", "calls", "green", "gain", "gains",
            "gained", "rise", "rising", "rose", "jump", "jumped", "climb", "climbed",
            "strong", "beat", "beats", "exceeded", "optimistic", "positive", "growth",
            "profit", "profits", "upside", "support", "hold", "holding", "conviction",
            "rip", "ripping", "printing", "tendies", "yolo",
        ]
        let strongBearish = [
            "bearish", "crash", "crashed", "crashing", "plunge", "plunged", "plunging",
            "tumble", "tumbled", "collapse", "collapsed", "bagholder", "overvalued",
            "overbought", "breakdown", "underperform", "underperformed", "bubble",
            "fraud", "scam", "halted", "delisted", "bankruptcy", "dilution",
        ]
        let mildBearish = [
            "down", "sell", "selling", "sold", "short", "shorting", "puts", "red", "fall",
            "falling", "fell", "drop", "dropped", "dropping", "decline", "declining",
            "slump", "weak", "weakness", "miss", "missed", "pessimistic", "negative",
            "loss", "losses", "recession", "correction", "downside", "resistance",
            "dump", "dumping", "dumped", "rekt", "cooked",
        ]

        for term in strongBullish {
            lexicon[term] = 1.0
        }
        for term in mildBullish {
            lexicon[term] = 0.5
        }
        for term in strongBearish {
            lexicon[term] = -1.0
        }
        for term in mildBearish {
            lexicon[term] = -0.5
        }

        return lexicon
    }()

    /// Multi-word phrases and emoji. Checked as substrings, so ordering against
    /// the word lexicon does not matter — a post can match both.
    private static let phraseLexicon: [String: Double] = [
        "diamond hands": 1.0,
        "to the moon": 1.0,
        "buy the dip": 0.8,
        "record high": 0.8,
        "all time high": 0.8,
        "all-time high": 0.8,
        "loading up": 0.6,
        "paper hands": -0.8,
        "dead cat bounce": -0.8,
        "bag holder": -0.8,
        "catching a falling knife": -1.0,
        "record low": -0.8,
        "profit taking": -0.4,
        "🚀": 1.0,
        "📈": 0.8,
        "💎": 0.8,
        "🙌": 0.4,
        "🌙": 0.6,
        "🐂": 0.8,
        "📉": -0.8,
        "🐻": -1.0,
        "💀": -0.8,
        "🚮": -0.8,
        "🧻": -0.6,
    ]
}
