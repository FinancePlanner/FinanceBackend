import Foundation

/// Turns a day's scored posts for one symbol into the row that gets stored.
///
/// Pure and synchronous: every number the job writes is decided here, so the
/// weighting and the "no chatter" rules can be tested without a database or a
/// provider.
enum SentimentAggregator {
    struct DailyAggregate: Sendable, Equatable {
        var score: Double?
        var label: String
        var confidence: Double?
        var postCount: Int
        var positiveCount: Int
        var neutralCount: Int
        var negativeCount: Int
        var sourceCounts: SentimentSourceCounts
    }

    /// Confidence-weighted mean of the per-post scores.
    ///
    /// Weighting matters: a post whose only signal is one ambiguous word should
    /// not move the symbol's reading as far as one that stacks five unambiguous
    /// ones. Posts that carried no sentiment term at all are counted in
    /// `postCount` (they are still chatter) but contribute no score.
    ///
    /// Returns a nil `score` when nothing scoreable was found, which callers
    /// must render as absence. A neutral-looking zero would claim the crowd is
    /// balanced when the truth is that nobody said anything.
    static func aggregate(posts: [(scored: SentimentScoring.Scored, source: SentimentSource)]) -> DailyAggregate {
        var sourceCounts = SentimentSourceCounts()
        var positive = 0
        var neutral = 0
        var negative = 0
        var weightedSum = 0.0
        var weightTotal = 0.0
        var confidenceSum = 0.0
        var scoredCount = 0

        for post in posts {
            sourceCounts[post.source] += 1

            switch post.scored.label {
            case SentimentClassifier.positiveLabel: positive += 1
            case SentimentClassifier.negativeLabel: negative += 1
            default: neutral += 1
            }

            guard let score = post.scored.score else { continue }
            // Floor the weight so a zero-confidence post still counts for
            // something; otherwise provider-supplied scores with no confidence
            // would vanish entirely.
            let weight = max(0.1, post.scored.confidence ?? 0.5)
            weightedSum += score * weight
            weightTotal += weight
            confidenceSum += post.scored.confidence ?? 0.5
            scoredCount += 1
        }

        guard scoredCount > 0, weightTotal > 0 else {
            return DailyAggregate(
                score: nil,
                label: SentimentClassifier.neutralLabel,
                confidence: nil,
                postCount: posts.count,
                positiveCount: positive,
                neutralCount: neutral,
                negativeCount: negative,
                sourceCounts: sourceCounts
            )
        }

        let score = weightedSum / weightTotal
        // Mean per-post confidence, discounted when the sample is thin. Ten
        // posts is treated as a full sample for a single symbol-day.
        let sampleFactor = min(1.0, Double(scoredCount) / 10.0)
        let confidence = (confidenceSum / Double(scoredCount)) * sampleFactor

        return DailyAggregate(
            score: score,
            label: SentimentClassifier.label(forScore: score),
            confidence: confidence,
            postCount: posts.count,
            positiveCount: positive,
            neutralCount: neutral,
            negativeCount: negative,
            sourceCounts: sourceCounts
        )
    }

    /// How unusual today's chatter volume is for this symbol, in standard
    /// deviations above its own trailing mean.
    ///
    /// Ranking trending by raw post count would return the same megacaps every
    /// day — AAPL always out-posts a small cap. What is interesting is a symbol
    /// being loud *relative to itself*.
    ///
    /// Returns nil below `minimumBaselineDays` of history: with two data points
    /// the standard deviation is noise, and a fabricated z-score would rank a
    /// brand-new symbol straight to the top of the page.
    static func volumeZScore(todayCount: Int, baseline: [Int]) -> Double? {
        guard baseline.count >= minimumBaselineDays else { return nil }

        let mean = Double(baseline.reduce(0, +)) / Double(baseline.count)
        let variance = baseline
            .map { pow(Double($0) - mean, 2) }
            .reduce(0, +) / Double(baseline.count)
        let stdDev = sqrt(variance)

        // A symbol with a perfectly flat history has no meaningful spread. Fall
        // back to a proportional reading so a genuine spike still surfaces.
        guard stdDev > 0.5 else {
            guard mean > 0 else { return todayCount > 0 ? 1.0 : nil }
            return (Double(todayCount) - mean) / max(1.0, mean)
        }

        return (Double(todayCount) - mean) / stdDev
    }

    static let minimumBaselineDays = 5

    /// Day-over-day score change. Nil unless both days actually have a reading —
    /// a delta against "no data" is not a movement.
    static func delta(today: Double?, yesterday: Double?) -> Double? {
        guard let today, let yesterday else { return nil }
        return today - yesterday
    }
}
