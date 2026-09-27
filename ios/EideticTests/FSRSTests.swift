import XCTest
@testable import Eidetic

final class FSRSTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var fsrs: FSRS { var f = FSRS(); f.enableFuzz = false; return f }
    private let day: TimeInterval = 86_400

    func testNewCardGoodEntersSecondLearningStep() {
        let s = fsrs.review(Scheduling(), rating: .good, at: t0)
        XCTAssertEqual(s.state, .learning)
        XCTAssertEqual(s.step, 1)
        XCTAssertEqual(s.due, t0.addingTimeInterval(600))
        XCTAssertEqual(s.stability!, FSRS.defaultParameters[2], accuracy: 1e-9)
        // D0(good) = w4 - e^(2·w5) + 1
        XCTAssertEqual(s.difficulty!, 6.4133 - exp(2 * 0.8334) + 1, accuracy: 1e-9)
        XCTAssertEqual(s.reps, 1)
        XCTAssertEqual(s.introducedAt, t0)
    }

    func testNewCardAgainAndHardUseStepTimings() {
        XCTAssertEqual(fsrs.review(Scheduling(), rating: .again, at: t0).due, t0.addingTimeInterval(60))
        XCTAssertEqual(fsrs.review(Scheduling(), rating: .hard, at: t0).due, t0.addingTimeInterval(330))
    }

    func testEasyGraduatesWithIntervalEqualToStabilityAtNinetyPercent() {
        // At 90% desired retention the FSRS interval equals stability.
        let s = fsrs.review(Scheduling(), rating: .easy, at: t0)
        XCTAssertEqual(s.state, .review)
        XCTAssertNil(s.step)
        XCTAssertEqual(s.due, t0.addingTimeInterval(8 * day))
    }

    func testGoodThroughStepsGraduates() {
        let first = fsrs.review(Scheduling(), rating: .good, at: t0)
        let second = fsrs.review(first, rating: .good, at: first.due!)
        XCTAssertEqual(second.state, .review)
        XCTAssertGreaterThanOrEqual(second.due!.timeIntervalSince(first.due!), day)
        XCTAssertGreaterThanOrEqual(second.stability!, first.stability!) // same-day good never shrinks stability
    }

    func testIntervalsGrowWithSuccessfulReviews() {
        var s = fsrs.review(Scheduling(), rating: .easy, at: t0)
        var last: TimeInterval = 0
        for _ in 0..<5 {
            let now = s.due!
            s = fsrs.review(s, rating: .good, at: now)
            let interval = s.due!.timeIntervalSince(now)
            XCTAssertGreaterThan(interval, last)
            last = interval
        }
        XCTAssertEqual(s.state, .review)
    }

    func testLapseRelearnsAndCounts() {
        let graduated = fsrs.review(Scheduling(), rating: .easy, at: t0)
        let lapsed = fsrs.review(graduated, rating: .again, at: graduated.due!)
        XCTAssertEqual(lapsed.state, .relearning)
        XCTAssertEqual(lapsed.step, 0)
        XCTAssertEqual(lapsed.lapses, 1)
        XCTAssertEqual(lapsed.due, graduated.due!.addingTimeInterval(600))
        XCTAssertLessThan(lapsed.stability!, graduated.stability!)

        let relearned = fsrs.review(lapsed, rating: .good, at: lapsed.due!)
        XCTAssertEqual(relearned.state, .review)
        XCTAssertEqual(relearned.lapses, 1)
    }

    func testDifficultyStaysInRange() {
        var s = Scheduling()
        var now = t0
        for _ in 0..<30 {
            s = fsrs.review(s, rating: .again, at: now)
            now = s.due!
            XCTAssert((1...10).contains(s.difficulty!))
        }
        for _ in 0..<30 {
            s = fsrs.review(s, rating: .easy, at: now)
            now = s.due!
            XCTAssert((1...10).contains(s.difficulty!))
        }
    }

    func testFuzzStaysNearTheExactInterval() {
        var fuzzy = FSRS()
        fuzzy.enableFuzz = true
        let graduated = fsrs.review(Scheduling(), rating: .easy, at: t0) // 8d exact
        let exact = fsrs.review(graduated, rating: .good, at: graduated.due!).due!.timeIntervalSince(graduated.due!) / day
        for _ in 0..<50 {
            let days = fuzzy.review(graduated, rating: .good, at: graduated.due!).due!.timeIntervalSince(graduated.due!) / day
            XCTAssertLessThanOrEqual(abs(days - exact), max(2, exact * 0.15))
        }
    }

    func testPreviewsMatchReviewsAndOrderByRating() {
        let card = fsrs.review(Scheduling(), rating: .easy, at: t0)
        let previews = FSRS().previews(card, at: card.due!)
        XCTAssertEqual(previews[.good], fsrs.review(card, rating: .good, at: card.due!).due!.timeIntervalSince(card.due!))
        XCTAssertLessThan(previews[.again]!, previews[.hard]!)
        XCTAssertLessThan(previews[.hard]!, previews[.good]!)
        XCTAssertLessThan(previews[.good]!, previews[.easy]!)
    }
}
