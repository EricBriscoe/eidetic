import SwiftUI

struct SetListView: View {
    @Environment(Store.self) private var store
    @State private var showingConnect = false

    var body: some View {
        NavigationStack {
            Group {
                if store.sets.isEmpty && store.hasLoaded {
                    ContentUnavailableView {
                        Text("no sets yet")
                    } description: {
                        Text("ask your assistant to make one.")
                    } actions: {
                        Button("connect") { showingConnect = true }
                    }
                } else {
                    List(store.sets) { set in
                        NavigationLink(value: set.id) { SetRow(cardSet: set) }
                    }
                    .listStyle(.plain)
                }
            }
            .overlay {
                if !store.hasLoaded { ProgressView() }
            }
            .refreshable { await store.refresh() }
            .navigationTitle("sets")
            .navigationDestination(for: String.self) { StudyView(setId: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("connect", systemImage: "link") { showingConnect = true }
                }
                if let error = store.syncError {
                    ToolbarItem(placement: .topBarLeading) {
                        Label(error, systemImage: "icloud.slash")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showingConnect) { ConnectView() }
        }
    }
}

private struct SetRow: View {
    let cardSet: CardSet

    var body: some View {
        TimelineView(.everyMinute) { context in
            let queue = StudyQueue(cards: cardSet.cards, newPerDay: cardSet.newPerDay, now: context.date)
            VStack(alignment: .leading, spacing: 2) {
                Text(cardSet.name)
                Text(subtitle(queue))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func subtitle(_ q: StudyQueue) -> String {
        var parts: [String] = []
        if q.dueCount > 0 { parts.append("\(q.dueCount) due") }
        if q.newAvailable > 0 { parts.append("\(q.newAvailable) new") }
        if parts.isEmpty {
            if let next = q.nextDue { return "next \(next.formatted(.relative(presentation: .named)))" }
            return cardSet.cards.isEmpty ? "empty" : "\(cardSet.cards.count) cards"
        }
        return parts.joined(separator: " · ")
    }
}
