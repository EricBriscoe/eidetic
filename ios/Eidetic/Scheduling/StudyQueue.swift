import Foundation

/// Picks what to show next from a set. Stateless: every pick is derived from
/// the cards' scheduling, so the queue survives relaunches and syncs for free.
struct StudyQueue {
    /// Learning cards due within this window are shown early once nothing
    /// else is left, so a session doesn't stall on a 10-minute step (Anki's default).
    static let learnAhead: TimeInterval = 20 * 60

    let cards: [Card]
    let newPerDay: Int
    let now: Date
    var calendar = Calendar.current

    var newIntroducedToday: Int {
        cards.count { $0.introducedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
    }

    var newAvailable: Int {
        min(max(0, newPerDay - newIntroducedToday), cards.count { $0.state == .new })
    }

    /// Seen cards due now.
    var dueCount: Int {
        cards.count { $0.state != .new && ($0.due ?? .distantFuture) <= now }
    }

    /// What's left in today's session: due now, new still allowed today, and
    /// learning cards that come due within the learn-ahead window.
    var remaining: Int {
        dueCount + newAvailable + cards.count { isLearning($0) && isWithinLearnAhead($0) && !isDue($0) }
    }

    /// Earliest future due date among seen cards, for "next in 3h".
    var nextDue: Date? {
        cards.filter { $0.state != .new }.compactMap(\.due).filter { $0 > now }.min()
    }

    /// Order: due (re)learning steps, due reviews, new cards, then learning
    /// cards within learn-ahead. Avoids repeating `previous` if anything else is eligible.
    func next(after previous: String? = nil) -> Card? {
        let byDue = { (a: Card, b: Card) in (a.due ?? .distantPast) < (b.due ?? .distantPast) }
        let dueLearning = cards.filter { isLearning($0) && isDue($0) }.sorted(by: byDue)
        let dueReviews = cards.filter { $0.state == .review && isDue($0) }.sorted(by: byDue)
        let fresh = Array(cards.filter { $0.state == .new }.sorted { $0.position < $1.position }.prefix(newAvailable))
        let ahead = cards.filter { isLearning($0) && !isDue($0) && isWithinLearnAhead($0) }.sorted(by: byDue)

        let ordered = dueLearning + dueReviews + fresh + ahead
        return ordered.first { $0.id != previous } ?? ordered.first
    }

    private func isLearning(_ c: Card) -> Bool { c.state == .learning || c.state == .relearning }
    private func isDue(_ c: Card) -> Bool { (c.due ?? .distantFuture) <= now }
    private func isWithinLearnAhead(_ c: Card) -> Bool { (c.due ?? .distantFuture) <= now.addingTimeInterval(Self.learnAhead) }
}
