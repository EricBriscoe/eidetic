import Foundation
import Observation

/// App state. The server owns set/card content (assistants edit it over MCP);
/// the phone owns scheduling — FSRS runs here, so studying works offline.
/// Grades apply locally at once and queue in a persisted outbox that the
/// server accepts idempotently (client UUIDs).
@Observable @MainActor
final class Store {
    private(set) var sets: [CardSet] = []
    private(set) var syncError: String?
    private(set) var hasLoaded = false

    private var outbox: [ReviewUpload] = []
    private var flushing = false
    private let api = APIClient()
    private let scheduler = FSRS()

    private static let dir = URL.applicationSupportDirectory
    private static let libraryFile = dir.appending(path: "library.json")
    private static let outboxFile = dir.appending(path: "outbox.json")

    init() {
        if let cached: Library = Self.read(Self.libraryFile) {
            sets = cached.sets
            hasLoaded = true
        }
        outbox = Self.read(Self.outboxFile) ?? []
    }

    func set(_ id: String) -> CardSet? { sets.first { $0.id == id } }

    // MARK: Sync

    /// Pushes pending reviews, then pulls the library. Pending reviews the
    /// server hasn't taken yet are re-applied on top, so a failed push never
    /// rewinds a card on screen.
    func refresh() async {
        await flush()
        do {
            let library: Library = try await api.get("/api/library")
            sets = library.sets
            for review in outbox { apply(review.card, to: review.cardId) }
            hasLoaded = true
            syncError = nil
            save()
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func flush() async {
        guard !flushing, !outbox.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        do {
            let batch = Array(outbox.prefix(500))
            let result: ReviewSyncResult = try await api.post("/api/reviews", ["reviews": batch])
            // Missing = the card was deleted server-side; nothing left to sync.
            let done = Set(result.accepted + result.missing)
            outbox.removeAll { done.contains($0.id) }
            Self.write(outbox, to: Self.outboxFile)
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    // MARK: Studying

    func previews(for card: Card, at now: Date = .now) -> [Rating: TimeInterval] {
        scheduler.previews(card.scheduling, at: now)
    }

    func grade(_ card: Card, _ rating: Rating, duration: TimeInterval, at now: Date = .now) {
        let next = scheduler.review(card.scheduling, rating: rating, at: now)
        apply(next, to: card.id)
        outbox.append(ReviewUpload(
            id: UUID(), cardId: card.id, rating: rating, reviewedAt: now,
            durationMs: Int(min(duration, 3600) * 1000), priorState: card.state, card: next
        ))
        save()
        Task { await flush() }
    }

    private func apply(_ scheduling: Scheduling, to cardId: String) {
        for s in sets.indices {
            if let c = sets[s].cards.firstIndex(where: { $0.id == cardId }) {
                sets[s].cards[c].scheduling = scheduling
                return
            }
        }
    }

    // MARK: Connecting assistants

    func mintConnectCode() async throws -> ConnectCode {
        try await api.post("/api/connect-code")
    }

    // MARK: Persistence

    private func save() {
        Self.write(Library(sets: sets), to: Self.libraryFile)
        Self.write(outbox, to: Self.outboxFile)
    }

    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? APIClient.decoder.decode(T.self, from: data)
    }

    private static func write(_ value: some Encodable, to url: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? APIClient.encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
