import SwiftUI

/// First screen after fleet sign-in. Lists the agents the CP says
/// this user has access to. Tap → navigate to SessionListView for
/// that agent.
struct AgentListView: View {
    @ObservedObject var viewModel: ClientViewModel
    @State private var agents: [AgentSummary] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var selectedAgent: AgentSummary?

    private let api: FleetAPIClient

    init(viewModel: ClientViewModel, api: FleetAPIClient = FleetAPIClient()) {
        self.viewModel = viewModel
        self.api = api
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && agents.isEmpty {
                    ProgressView("Loading agents…")
                        .progressViewStyle(.circular)
                } else if agents.isEmpty {
                    ContentUnavailableView(
                        "No agents",
                        systemImage: "server.rack",
                        description: Text(loadError ?? "Your account has no enrolled agents yet.")
                    )
                } else {
                    List {
                        ForEach(agents) { agent in
                            Button {
                                selectedAgent = agent
                            } label: {
                                AgentRow(agent: agent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Sign out") {
                        viewModel.signOutOfFleet()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .navigationDestination(item: $selectedAgent) { agent in
                SessionListView(viewModel: viewModel, agent: agent)
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            agents = try await api.agents()
        } catch FleetError.unauthorized {
            viewModel.signOutOfFleet()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct AgentRow: View {
    let agent: AgentSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.label)
                    .font(.body.weight(.semibold))
                Text(agent.agentURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let last = agent.lastSeenAt {
                    Text("Last seen \(last.formatted(.relative(presentation: .named)))")
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
