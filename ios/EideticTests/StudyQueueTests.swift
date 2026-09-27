import XCTest
@testable import Eidetic

final class StudyQueueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, _ state: CardState = .new, due: TimeInterval? = nil, position: Int = 0, introduced: Date? = nil) -> Card {
        Card(id: id, setId: "s", front: id, back: id, position: position, state: state, step: nil, stability: nil,
             difficulty: nil, due: due.map { now.addingTimeInterval($0) }, lastReview: nil, reps: 0, lapses: 0,
             introducedAt: introduced)
    }

    func testOrdersLearningThenReviewsThenNewThenLearnAhead() {
        let cards = [
            card("new", position: 0),
            card("ahead", .learning, due: 300),
            card("review", .review, due: -3600),
            card("learning", .learning, due: -10),
        ]
        var queue = StudyQueue(cards: cards, newPerDay: 20, now: now)
        var order: [String] = []
        var remaining = cards
        while let next = queue.next() {
            order.append(next.id)
            remaining.removeAll { $0.id == next.id }
            queue = StudyQueue(cards: remaining, newPerDay: 20, now: now)
        }
        XCTAssertEqual(order, ["learning", "review", "new", "ahead"])
    }

    func testNewCardsCappedByTodaysIntroductions() {
        let cards = (0..<10).map { card("n\($0)", position: $0) } + [
            card("seen1", .review, due: 86_400, introduced: now.addingTimeInterval(-60)),
            card("seen2", .review, due: 86_400, introduced: now.addingTimeInterval(-120)),
        ]
        let queue = StudyQueue(cards: cards, newPerDay: 5, now: now)
        XCTAssertEqual(queue.newAvailable, 3)
        XCTAssertEqual(queue.next()?.id, "n0")
        XCTAssertEqual(queue.remaining, 3)
    }

    func testAvoidsImmediateRepeatWhenAlternativeExists() {
        let cards = [card("a", .learning, due: -20), card("b", .learning, due: -10)]
        let queue = StudyQueue(cards: cards, newPerDay: 0, now: now)
        XCTAssertEqual(queue.next()?.id, "a")
        XCTAssertEqual(queue.next(after: "a")?.id, "b")
        XCTAssertEqual(StudyQueue(cards: [cards[0]], newPerDay: 0, now: now).next(after: "a")?.id, "a")
    }

    func testDoneWhenNothingDueWithinLearnAhead() {
        let cards = [card("later", .learning, due: 3600), card("review", .review, due: 86_400)]
        let queue = StudyQueue(cards: cards, newPerDay: 20, now: now)
        XCTAssertNil(queue.next())
        XCTAssertEqual(queue.nextDue, now.addingTimeInterval(3600))
    }

    func testReviewUploadWireFormat() throws {
        let upload = ReviewUpload(
            id: UUID(), cardId: "c1", rating: .good, reviewedAt: now, durationMs: 1500, priorState: .new,
            card: Scheduling(state: .learning, step: 1, stability: 2.3, difficulty: 2.1, due: now, lastReview: now, reps: 1, lapses: 0, introducedAt: now)
        )
        let json = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(upload)) as! [String: Any]
        XCTAssertEqual(json["card_id"] as? String, "c1")
        XCTAssertEqual(json["rating"] as? Int, 3)
        XCTAssertEqual(json["prior_state"] as? String, "new")
        XCTAssertEqual(json["reviewed_at"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual((json["card"] as? [String: Any])?["introduced_at"] as? String, "2027-01-15T08:00:00Z")
    }
}
