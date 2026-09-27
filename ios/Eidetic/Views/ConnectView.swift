import SwiftUI

/// How assistants get in: add the MCP URL as a connector, then approve the
/// OAuth page with a one-time code minted here.
struct ConnectView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var code: ConnectCode?
    @State private var error: String?
    @State private var minting = false
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    copyRow(AppConfig.mcpURL, font: .footnote.monospaced())
                    if let url = AppConfig.addToClaudeURL {
                        Link("add to claude", destination: url)
                    }
                } header: {
                    Text("connector url")
                } footer: {
                    Text("add this as a custom connector in your assistant.")
                }

                Section {
                    if let code {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if context.date < code.expiresAt {
                                copyRow(code.code, font: .system(.largeTitle, design: .monospaced).weight(.semibold))
                            } else {
                                Text("expired").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(code == nil ? "get code" : "new code") { Task { await mint() } }
                        .disabled(minting)
                    if let error {
                        Text(error).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("code")
                } footer: {
                    Text("when the connector asks, enter this code. it works once, for 10 minutes.")
                }
            }
            .navigationTitle("connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func copyRow(_ value: String, font: Font) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = value
        } label: {
            HStack {
                Text(value).font(font).lineLimit(1).minimumScaleFactor(0.5)
                Spacer()
                Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .sensoryFeedback(.success, trigger: copied)
    }

    private func mint() async {
        minting = true
        defer { minting = false }
        do {
            code = try await store.mintConnectCode()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
