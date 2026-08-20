import Foundation
@testable import StockPlanBackend
import Testing

@Suite("SentimentClassifier")
struct SentimentClassifierTests {
    @Test("plain bullish and bearish text lands on the right side")
    func directionality() {
        let bullish = SentimentClassifier.classify("Absolutely bullish on this, loading calls")
        #expect(bullish.label == SentimentClassifier.positiveLabel)
        #expect((bullish.score ?? 0) > 0)

        let bearish = SentimentClassifier.classify("This is a bubble, puts printing, total crash incoming")
        #expect(bearish.label == SentimentClassifier.negativeLabel)
        #expect((bearish.score ?? 0) < 0)
    }

    /// The regression this scorer exists for. The three lexicons it replaced all
    /// used `contains`, so any word embedding "up" or "down" scored as a
    /// directional signal.
    @Test("substring collisions no longer fire")
    func substringCollisions() {
        for text in ["supply chain disruption", "download the report", "the upset was notable"] {
            let result = SentimentClassifier.classify(text)
            #expect(result.matchCount == 0, "\(text) should carry no sentiment term")
            #expect(result.score == nil)
        }

        // The real word still matches when it stands alone.
        let genuine = SentimentClassifier.classify("shares are up today")
        #expect(genuine.matchCount == 1)
    }

    @Test("negation flips polarity")
    func negation() {
        let plain = SentimentClassifier.classify("bullish")
        let negated = SentimentClassifier.classify("not bullish")

        #expect((plain.score ?? 0) > 0)
        #expect((negated.score ?? 0) < 0)
    }

    @Test("negation only reaches back a few tokens")
    func negationWindow() {
        // "not" is far enough away that it modifies something else entirely.
        let distant = SentimentClassifier.classify("not the report I wanted but honestly bullish")
        #expect((distant.score ?? 0) > 0)
    }

    @Test("no sentiment-bearing term yields nil, not zero")
    func absenceIsNotNeutrality() {
        let result = SentimentClassifier.classify("The company filed its quarterly report on Tuesday.")
        #expect(result.score == nil)
        #expect(result.confidence == 0)
        #expect(result.label == SentimentClassifier.neutralLabel)
    }

    @Test("emoji and multi-word phrases are scored")
    func phrasesAndEmoji() {
        let rocket = SentimentClassifier.classify("🚀🚀 diamond hands")
        #expect((rocket.score ?? 0) > 0)
        #expect(rocket.matchCount >= 2)

        let bear = SentimentClassifier.classify("🐻 paper hands everywhere")
        #expect((bear.score ?? 0) < 0)
    }

    @Test("cashtags tokenize to the bare symbol")
    func cashtagTokenization() {
        let tokens = SentimentClassifier.tokenize("$tsla and #tsla and tsla")
        #expect(tokens == ["tsla", "and", "tsla", "and", "tsla"])
    }

    @Test("more evidence produces more confidence at equal polarity")
    func confidenceTracksEvidence() {
        let thin = SentimentClassifier.classify("bullish")
        let thick = SentimentClassifier.classify("bullish rally breakout squeeze moon")

        #expect(thick.confidence > thin.confidence)
    }

    @Test("score saturates instead of running away")
    func saturation() {
        let extreme = SentimentClassifier.classify(
            String(repeating: "bullish rally squeeze moon breakout ", count: 20)
        )
        #expect((extreme.score ?? 0) <= 1.0)
        #expect((extreme.score ?? 0) > 0.8)
    }

    @Test("mixed signals land near neutral")
    func mixedSignals() {
        let mixed = SentimentClassifier.classify("bullish long term but bearish short term")
        #expect(abs(mixed.score ?? 1) <= SentimentClassifier.labelThreshold)
        #expect(mixed.label == SentimentClassifier.neutralLabel)
    }

    @Test("label thresholds match the aggregate service")
    func labelThresholds() {
        #expect(SentimentClassifier.label(forScore: 0.2) == SentimentClassifier.positiveLabel)
        #expect(SentimentClassifier.label(forScore: -0.2) == SentimentClassifier.negativeLabel)
        #expect(SentimentClassifier.label(forScore: 0.1) == SentimentClassifier.neutralLabel)
        #expect(SentimentClassifier.label(forScore: 0.15) == SentimentClassifier.neutralLabel)
    }
}
