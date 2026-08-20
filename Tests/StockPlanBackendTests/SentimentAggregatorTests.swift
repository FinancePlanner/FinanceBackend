import Foundation
@testable import StockPlanBackend
import Testing

@Suite("SentimentAggregator")
struct SentimentAggregatorTests {
    private func post(
        _ score: Double?,
        label: String,
        confidence: Double? = 0.5,
        source: SentimentSource = .x
    ) -> (scored: SentimentScoring.Scored, source: SentimentSource) {
        (SentimentScoring.Scored(score: score, label: label, confidence: confidence), source)
    }

    @Test("weights by confidence rather than treating every post equally")
    func confidenceWeighting() {
        let result = SentimentAggregator.aggregate(posts: [
            post(1.0, label: "positive", confidence: 1.0),
            post(-1.0, label: "negative", confidence: 0.1),
        ])

        // A near-worthless bearish post must not cancel a confident bullish one.
        #expect((result.score ?? 0) > 0.5)
        #expect(result.label == SentimentClassifier.positiveLabel)
    }

    @Test("unscoreable posts still count as chatter but not as sentiment")
    func unscoredPostsCountAsVolume() {
        let result = SentimentAggregator.aggregate(posts: [
            post(nil, label: "neutral", confidence: nil),
            post(nil, label: "neutral", confidence: nil),
            post(0.8, label: "positive", confidence: 1.0),
        ])

        #expect(result.postCount == 3)
        #expect((result.score ?? 0) > 0)
    }

    @Test("no scoreable post yields a nil score, never a neutral zero")
    func absenceIsNotNeutrality() {
        let result = SentimentAggregator.aggregate(posts: [
            post(nil, label: "neutral", confidence: nil),
            post(nil, label: "neutral", confidence: nil),
        ])

        #expect(result.score == nil)
        #expect(result.confidence == nil)
        #expect(result.postCount == 2)
    }

    @Test("empty input is empty, not zero")
    func emptyInput() {
        let result = SentimentAggregator.aggregate(posts: [])
        #expect(result.score == nil)
        #expect(result.postCount == 0)
        #expect(result.sourceCounts.total == 0)
    }

    @Test("per-source counts are tallied")
    func sourceCounts() {
        let result = SentimentAggregator.aggregate(posts: [
            post(0.5, label: "positive", source: .reddit),
            post(0.5, label: "positive", source: .reddit),
            post(-0.5, label: "negative", source: .stocktwits),
            post(0.1, label: "neutral", source: .news),
        ])

        #expect(result.sourceCounts.reddit == 2)
        #expect(result.sourceCounts.stocktwits == 1)
        #expect(result.sourceCounts.news == 1)
        #expect(result.sourceCounts.x == 0)
        #expect(result.sourceCounts.total == 4)
    }

    @Test("a thin sample is reported as less confident than a full one")
    func thinSamplesAreDiscounted() {
        let thin = SentimentAggregator.aggregate(posts: [post(0.8, label: "positive", confidence: 1.0)])
        let full = SentimentAggregator.aggregate(
            posts: Array(repeating: post(0.8, label: "positive", confidence: 1.0), count: 10)
        )

        #expect((thin.confidence ?? 1) < (full.confidence ?? 0))
    }

    @Test("provider scores with no confidence still contribute")
    func providerScoresWithoutConfidence() {
        let result = SentimentAggregator.aggregate(posts: [
            post(0.9, label: "positive", confidence: nil),
        ])
        #expect((result.score ?? 0) > 0)
    }

    // MARK: - Volume z-score

    @Test("too little history yields no z-score rather than a fabricated one")
    func zScoreNeedsHistory() {
        #expect(SentimentAggregator.volumeZScore(todayCount: 100, baseline: [1, 2]) == nil)
        #expect(SentimentAggregator.volumeZScore(todayCount: 100, baseline: []) == nil)
    }

    @Test("a spike above a symbol's own baseline scores positive")
    func zScoreSpike() {
        let z = SentimentAggregator.volumeZScore(todayCount: 200, baseline: [10, 12, 9, 11, 10, 13])
        #expect((z ?? 0) > 3)
    }

    @Test("steady volume scores near zero even when the absolute count is large")
    func zScoreIgnoresAbsoluteSize() {
        // The megacap problem: a symbol posting 5000 times a day every day is
        // not trending, and must not outrank a small cap that just woke up.
        let mega = SentimentAggregator.volumeZScore(
            todayCount: 5000,
            baseline: [5000, 4980, 5020, 4990, 5010, 5000]
        )
        let smallCap = SentimentAggregator.volumeZScore(
            todayCount: 90,
            baseline: [3, 4, 2, 5, 3, 4]
        )

        #expect(abs(mega ?? 99) < 1)
        #expect((smallCap ?? 0) > (mega ?? 0))
    }

    @Test("a flat history falls back to a proportional reading")
    func zScoreFlatBaseline() {
        let z = SentimentAggregator.volumeZScore(todayCount: 20, baseline: [5, 5, 5, 5, 5, 5])
        #expect((z ?? 0) > 0)
    }

    // MARK: - Delta

    @Test("delta needs a reading on both days")
    func deltaRequiresBothDays() {
        #expect(SentimentAggregator.delta(today: 0.5, yesterday: nil) == nil)
        #expect(SentimentAggregator.delta(today: nil, yesterday: 0.5) == nil)
        #expect(SentimentAggregator.delta(today: 0.5, yesterday: 0.2) == 0.3)
    }
}
