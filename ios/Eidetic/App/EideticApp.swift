import SwiftUI

@main
struct EideticApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SetListView()
                .environment(store)
                .tint(.primary)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { Task { await store.refresh() } }
                }
        }
    }
}
