import Foundation

enum Rating: Int, Codable, CaseIterable, Sendable {
    case again = 1, hard, good, easy

    var label: String {
        switch self {
        case .again: "again"
        case .hard: "hard"
        case .good: "good"
        case .easy: "easy"
        }
    }
}

enum CardState: String, Codable, Sendable {
    case new, learning, review, relearning
}

/// A card's memory state — everything FSRS reads and writes.
struct Scheduling: Codable, Equatable, Sendable {
    var state: CardState = .new
    /// Index into the learning/relearning steps; nil outside those states.
    var step: Int?
    var stability: Double?
    var difficulty: Double?
    var due: Date?
    var lastReview: Date?
    var reps = 0
    var lapses = 0
    var introducedAt: Date?
}

/// FSRS-6 scheduler, a port of py-fsrs 6 (open-spaced-repetition) with its
/// default parameters, learning steps, and interval fuzz. Pure: no clock, no I/O.
struct FSRS: Sendable {
    static let defaultParameters: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796,
        1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]

    var w = FSRS.defaultParameters
    var desiredRetention = 0.9
    var learningSteps: [TimeInterval] = [60, 600]
    var relearningSteps: [TimeInterval] = [600]
    var maximumInterval = 36_500
    var enableFuzz = true

    private static let minStability = 0.001
    private static let day: TimeInterval = 86_400

    private var decay: Double { -w[20] }
    private var factor: Double { pow(0.9, 1 / decay) - 1 }

    // MARK: Review

    func review(_ card: Scheduling, rating: Rating, at now: Date) -> Scheduling {
        var next = card
        let daysSince = card.lastReview.map { Int((now.timeIntervalSince($0) / Self.day).rounded(.down)) }

        if let s = card.stability, let d = card.difficulty, let days = daysSince {
            next.stability = days < 1
                ? shortTermStability(s, rating)
                : nextStability(difficulty: d, stability: s, retrievability: retrievability(elapsedDays: days, stability: s), rating: rating)
            next.difficulty = nextDifficulty(d, rating)
        } else {
            next.stability = initialStability(rating)
            next.difficulty = initialDifficulty(rating)
        }
        let stability = next.stability!

        let interval: TimeInterval
        switch card.state {
        case .new, .learning:
            (next.state, next.step, interval) = stepped(learningSteps, step: card.step ?? 0, rating, stability, inState: .learning)
        case .review:
            if rating == .again {
                next.lapses += 1
                if let first = relearningSteps.first {
                    (next.state, next.step, interval) = (.relearning, 0, first)
                } else {
                    (next.state, next.step, interval) = (.review, nil, reviewInterval(stability))
                }
            } else {
                (next.state, next.step, interval) = (.review, nil, reviewInterval(stability))
            }
        case .relearning:
            (next.state, next.step, interval) = stepped(relearningSteps, step: card.step ?? 0, rating, stability, inState: .relearning)
        }

        next.due = now.addingTimeInterval(interval)
        next.lastReview = now
        next.reps += 1
        next.introducedAt = card.introducedAt ?? now
        return next
    }

    /// Time until due for each rating, fuzz-free — for labeling the buttons.
    func previews(_ card: Scheduling, at now: Date) -> [Rating: TimeInterval] {
        var exact = self
        exact.enableFuzz = false
        return Dictionary(uniqueKeysWithValues: Rating.allCases.map { rating in
            (rating, exact.review(card, rating: rating, at: now).due!.timeIntervalSince(now))
        })
    }

    /// Walks the (re)learning steps; graduates to review past the last step or on easy.
    private func stepped(
        _ steps: [TimeInterval], step: Int, _ rating: Rating, _ stability: Double, inState state: CardState
    ) -> (CardState, Int?, TimeInterval) {
        if steps.isEmpty || (step >= steps.count && rating != .again) {
            return (.review, nil, reviewInterval(stability))
        }
        switch rating {
        case .again:
            return (state, 0, steps[0])
        case .hard:
            if step == 0 && steps.count == 1 { return (state, step, steps[0] * 1.5) }
            if step == 0 { return (state, step, (steps[0] + steps[1]) / 2) }
            return (state, step, steps[min(step, steps.count - 1)])
        case .good:
            if step + 1 >= steps.count { return (.review, nil, reviewInterval(stability)) }
            return (state, step + 1, steps[step + 1])
        case .easy:
            return (.review, nil, reviewInterval(stability))
        }
    }

    // MARK: Memory model

    func retrievability(elapsedDays: Int, stability: Double) -> Double {
        pow(1 + factor * Double(max(0, elapsedDays)) / stability, decay)
    }

    private func initialStability(_ r: Rating) -> Double {
        max(w[r.rawValue - 1], Self.minStability)
    }

    private func initialDifficulty(_ r: Rating, clamped: Bool = true) -> Double {
        let d = w[4] - exp(w[5] * Double(r.rawValue - 1)) + 1
        return clamped ? d.clamped(1, 10) : d
    }

    private func nextDifficulty(_ d: Double, _ r: Rating) -> Double {
        let delta = -(w[6] * Double(r.rawValue - 3))
        let damped = d + delta * (10 - d) / 9
        let reverted = w[7] * initialDifficulty(.easy, clamped: false) + (1 - w[7]) * damped
        return reverted.clamped(1, 10)
    }

    private func shortTermStability(_ s: Double, _ r: Rating) -> Double {
        var increase = exp(w[17] * (Double(r.rawValue) - 3 + w[18])) * pow(s, -w[19])
        if r == .good || r == .easy { increase = max(increase, 1) }
        return max(s * increase, Self.minStability)
    }

    private func nextStability(difficulty d: Double, stability s: Double, retrievability r: Double, rating: Rating) -> Double {
        let next: Double
        if rating == .again {
            let longTerm = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
            next = min(longTerm, s / exp(w[17] * w[18]))
        } else {
            let hardPenalty = rating == .hard ? w[15] : 1
            let easyBonus = rating == .easy ? w[16] : 1
            next = s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp((1 - r) * w[10]) - 1) * hardPenalty * easyBonus)
        }
        return max(next, Self.minStability)
    }

    // MARK: Intervals

    private func reviewInterval(_ stability: Double) -> TimeInterval {
        let raw = stability / factor * (pow(desiredRetention, 1 / decay) - 1)
        let days = Int(raw.rounded()).clamped(1, maximumInterval)
        return TimeInterval(enableFuzz ? fuzzed(days) : days) * Self.day
    }

    /// Spreads reviews so cards learned together don't stay due together.
    private func fuzzed(_ days: Int) -> Int {
        let interval = Double(days)
        guard interval >= 2.5 else { return days }
        let ranges: [(start: Double, end: Double, factor: Double)] = [(2.5, 7, 0.15), (7, 20, 0.1), (20, .infinity, 0.05)]
        let delta = ranges.reduce(1.0) { $0 + $1.factor * max(min(interval, $1.end) - $1.start, 0) }
        let upper = min(Int((interval + delta).rounded()), maximumInterval)
        let lower = min(max(2, Int((interval - delta).rounded())), upper)
        return Int.random(in: lower...upper)
    }
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}
