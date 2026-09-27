import SwiftUI

struct StudyView: View {
    let setId: String
    @Environment(Store.self) private var store
    @State private var now = Date.now
    @State private var currentId: String?
    @State private var previousId: String?
    @State private var revealed = false
    @State private var shownAt = Date.now
    @State private var gradeCount = 0

    private var cardSet: CardSet? { store.set(setId) }
    private var queue: StudyQueue? {
        cardSet.map { StudyQueue(cards: $0.cards, newPerDay: $0.newPerDay, now: now) }
    }
    private var current: Card? {
        currentId.flatMap { id in cardSet?.cards.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let card = current {
                CardFaces(card: card, revealed: revealed)
                    .contentShape(Rectangle())
                    .onTapGesture { if !revealed { reveal() } }
                controls(for: card)
            } else if let queue {
                done(queue)
            }
        }
        .navigationTitle(cardSet?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let queue, current != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(queue.remaining)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: gradeCount)
        .onAppear(perform: advance)
        // Library refreshes can add, edit, or delete the card on screen.
        .onChange(of: cardSet?.cards) { if current == nil { advance() } }
        // While idle, poll the clock so learning steps resume on their own.
        .task(id: currentId == nil) {
            while currentId == nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                advance()
            }
        }
    }

    @ViewBuilder
    private func controls(for card: Card) -> some View {
        Group {
            if revealed {
                let previews = store.previews(for: card)
                HStack(spacing: 8) {
                    ForEach(Rating.allCases, id: \.self) { rating in
                        Button { grade(card, rating) } label: {
                            VStack(spacing: 2) {
                                Text(rating.label)
                                Text(previews[rating].map(Self.short) ?? "")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Button { reveal() } label: {
                    Text("show").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Color(.systemBackground))
            }
        }
        .padding()
    }

    private func done(_ queue: StudyQueue) -> some View {
        ContentUnavailableView {
            Text(cardSet?.cards.isEmpty == true ? "no cards" : "all caught up")
        } description: {
            if let next = queue.nextDue {
                Text("next review \(next.formatted(.relative(presentation: .named)))")
            }
        }
    }

    private func reveal() {
        withAnimation(.easeOut(duration: 0.15)) { revealed = true }
    }

    private func grade(_ card: Card, _ rating: Rating) {
        store.grade(card, rating, duration: Date.now.timeIntervalSince(shownAt))
        gradeCount += 1
        previousId = card.id
        advance()
    }

    private func advance() {
        now = .now
        let next = queue?.next(after: previousId)
        if next?.id != currentId || next == nil {
            revealed = false
            shownAt = .now
        }
        currentId = next?.id
    }

    /// 1m, 10m, 3h, 4d, 2mo, 1.5y — Anki-style button labels.
    static func short(_ interval: TimeInterval) -> String {
        let minutes = interval / 60, hours = minutes / 60, days = hours / 24
        if minutes < 60 { return "\(max(1, Int(minutes.rounded())))m" }
        if hours < 24 { return "\(Int(hours.rounded()))h" }
        if days < 30 { return "\(Int(days.rounded()))d" }
        if days < 365 { return "\(Int((days / 30).rounded()))mo" }
        let years = days / 365
        return years < 10 ? "\((years * 10).rounded() / 10)y".replacingOccurrences(of: ".0y", with: "y") : "\(Int(years))y"
    }
}

private struct CardFaces: View {
    let card: Card
    let revealed: Bool

    var body: some View {
        // Centered when short, scrollable when long.
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 24) {
                    MarkdownText(card.front)
                        .font(.title2.weight(.medium))
                    if revealed {
                        Divider().frame(width: 48)
                        MarkdownText(card.back)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Inline Markdown (**bold**, *italic*, `code`, links) with newlines kept.
struct MarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: source, options: options) {
            Text(attributed)
        } else {
            Text(source)
        }
    }
}
