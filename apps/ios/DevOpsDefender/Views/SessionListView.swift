import SwiftUI

/// Second fleet screen: sessions on the picked agent. Calls
/// `shell.list_sessions` over Noise via the new FFI helper. Tap → route
/// into the existing keyboard/transcript surface.
struct SessionListView: View {
    @ObservedObject var viewModel: ClientViewModel
    let agent: AgentSummary

    @State private var sessions: [SessionSummary] = []
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading && sessions.isEmpty {
                ProgressView("Loading sessions…")
            } else if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions",
                    systemImage: "terminal",
                    description: Text(loadError ?? "This agent has no live sessions. Start one from your laptop with `dd-client shell …`.")
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        Button {
                            viewModel.attachToFleetSession(
                                agentURL: agent.agentURL,
                                sessionID: session.id
                            )
                        } label: {
                            SessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(agent.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task {
            await load()
        }
    }

    /// Calls `shell.list_sessions` via the FFI helper. Runs off the
    /// main actor so the synchronous Noise round-trip doesn't block
    /// the UI.
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let agentURL = agent.agentURL
            let result = try await Task.detached(priority: .userInitiated) { () throws -> [SessionSummary] in
                let settings = AgentSettings(
                    agentURL: agentURL,
                    keyPath: AppKeyStore.shared.keyPath
                )
                let response = try DDClientBridge.listSessions(settings: settings)
                return SessionSummary.parse(value: response["value"] ?? response)
            }.value
            sessions = result
        } catch {
            loadError = error.localizedDescription
            sessions = []
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? session.id)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(session.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let recipe = session.recipe {
                    Text("recipe · \(recipe)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let started = session.startedAt {
                    Text("started \(started.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
