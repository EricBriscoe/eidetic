import Foundation

struct CardSet: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String?
    var newPerDay: Int
    var cards: [Card]
}

struct Card: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let setId: String
    var front: String
    var back: String
    var position: Int
    var state: CardState
    var step: Int?
    var stability: Double?
    var difficulty: Double?
    var due: Date?
    var lastReview: Date?
    var reps: Int
    var lapses: Int
    var introducedAt: Date?

    var scheduling: Scheduling {
        get {
            Scheduling(state: state, step: step, stability: stability, difficulty: difficulty, due: due,
                       lastReview: lastReview, reps: reps, lapses: lapses, introducedAt: introducedAt)
        }
        set {
            state = newValue.state
            step = newValue.step
            stability = newValue.stability
            difficulty = newValue.difficulty
            due = newValue.due
            lastReview = newValue.lastReview
            reps = newValue.reps
            lapses = newValue.lapses
            introducedAt = newValue.introducedAt
        }
    }
}

struct Library: Codable, Sendable {
    var sets: [CardSet]
}

/// One graded card, queued in the outbox until the server accepts it.
struct ReviewUpload: Codable, Identifiable, Sendable {
    let id: UUID
    let cardId: String
    let rating: Rating
    let reviewedAt: Date
    let durationMs: Int?
    let priorState: CardState
    let card: Scheduling
}

struct ReviewSyncResult: Decodable, Sendable {
    let accepted: [UUID]
    let missing: [UUID]
}

struct ConnectCode: Decodable, Sendable {
    let code: String
    let expiresAt: Date
}
