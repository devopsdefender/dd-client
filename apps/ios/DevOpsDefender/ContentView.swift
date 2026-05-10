import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ClientViewModel()
    @State private var isConnectionExpanded = false
    @State private var isDebugExpanded = false
    @State private var showTranscriptReader = false

    private let actionColumns = [
        GridItem(.adaptive(minimum: 150), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.page.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        statusStrip
                        actionPanel
                        transcriptPanel
                        writePanel
                        sessionsPanel
                        recipesPanel
                        connectionPanel
                        debugPanel
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 980, alignment: .center)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("DevOps Defender")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showTranscriptReader) {
                TranscriptReaderView(
                    transcript: viewModel.transcript,
                    fontSize: $viewModel.transcriptFontSize
                )
            }
        }
    }

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent workspace")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Palette.text)
                        Text(agentHost)
                            .font(.callout)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(viewModel.insecureSkipQuoteVerify ? "PR preview" : "Quote verified")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.chip)
                        .clipShape(Capsule())
                        .foregroundStyle(Palette.text)
                }

                HStack(spacing: 10) {
                    Label(selectedSessionLabel, systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)

                    Spacer()

                    if viewModel.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(viewModel.isBusy ? Palette.busy : Palette.ready)
                .frame(width: 8, height: 8)

            Text(viewModel.status)
                .font(.callout)
                .foregroundStyle(Palette.text)
                .lineLimit(2)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.status)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var actionPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Runbook", subtitle: "Load, create, attach, detach")

                LazyVGrid(columns: actionColumns, spacing: 10) {
                    ActionButton("Load recipes", systemImage: "list.bullet.rectangle") {
                        viewModel.loadRecipes()
                    }
                    .disabled(viewModel.isBusy)

                    ActionButton("List sessions", systemImage: "rectangle.stack") {
                        viewModel.loadSessions()
                    }
                    .disabled(viewModel.isBusy)

                    ActionButton("Create shell", systemImage: "plus.app") {
                        viewModel.createShellSession()
                    }
                    .disabled(viewModel.isBusy)

                    ActionButton("Attach refresh", systemImage: "arrow.clockwise") {
                        viewModel.attachSelectedSession()
                    }
                    .disabled(viewModel.isBusy)
                }
            }
        }
    }

    private var transcriptPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Transcript", subtitle: selectedSessionLabel)

                    Spacer()

                    Button {
                        showTranscriptReader = true
                    } label: {
                        Label("Reader", systemImage: "text.magnifyingglass")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(QuietButtonStyle())
                }

                HStack(spacing: 10) {
                    Button("Replay") {
                        viewModel.replaySelectedSession()
                    }
                    .buttonStyle(PlainPillButtonStyle())
                    .disabled(viewModel.isBusy)

                    Stepper(
                        "Text \(Int(viewModel.transcriptFontSize))",
                        value: $viewModel.transcriptFontSize,
                        in: 11...30,
                        step: 1
                    )
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                }

                ScrollView([.horizontal, .vertical]) {
                    Text(transcriptText)
                        .font(.system(size: viewModel.transcriptFontSize, design: .monospaced))
                        .foregroundStyle(Palette.terminalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(minHeight: 340)
                .background(Palette.terminal)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Palette.border, lineWidth: 1)
                )
            }
        }
    }

    private var writePanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Mobile replies",
                    subtitle: "Optimized for 1, 2, enter, and short prompts"
                )

                TextField("Type a short reply", text: $viewModel.quickInput, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .font(.body.monospaced())
                    .lineLimit(1...3)
                    .padding(12)
                    .background(Palette.input)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 10) {
                    Button("Send") {
                        viewModel.sendQuickInput()
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(viewModel.isBusy)

                    Button("1") {
                        viewModel.sendQuickInput("1\n")
                    }
                    .buttonStyle(PlainPillButtonStyle())
                    .disabled(viewModel.isBusy)

                    Button("2") {
                        viewModel.sendQuickInput("2\n")
                    }
                    .buttonStyle(PlainPillButtonStyle())
                    .disabled(viewModel.isBusy)

                    Button("Enter") {
                        viewModel.sendQuickInput("\n")
                    }
                    .buttonStyle(PlainPillButtonStyle())
                    .disabled(viewModel.isBusy)
                }

                Text("Each send attaches, writes bytes, waits briefly, then detaches without closing the session.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    private var sessionsPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Sessions", subtitle: "\(viewModel.sessions.count) loaded")

                Toggle("Notify on session changes", isOn: $viewModel.notifyOnSessionChanges)
                    .font(.callout)

                TextField("Paste or edit selected session id", text: $viewModel.selectedSessionID)
                    .textInputAutocapitalization(.never)
                    .font(.caption.monospaced())
                    .padding(12)
                    .background(Palette.input)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if viewModel.sessions.isEmpty {
                    EmptyState(text: "No sessions loaded")
                } else {
                    VStack(spacing: 8) {
                        ForEach(viewModel.sessions) { session in
                            SessionRow(
                                session: session,
                                isSelected: session.id == viewModel.selectedSessionID
                            ) {
                                viewModel.selectSession(session)
                            }
                        }
                    }
                }
            }
        }
    }

    private var recipesPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recipes", subtitle: "\(viewModel.recipes.count) loaded")

                if viewModel.recipes.isEmpty {
                    EmptyState(text: "Load recipes to confirm the PR preview is reachable")
                } else {
                    VStack(spacing: 8) {
                        ForEach(viewModel.recipes) { recipe in
                            SummaryRow(title: recipe.title, id: recipe.id, detail: recipe.detail)
                        }
                    }
                }
            }
        }
    }

    private var connectionPanel: some View {
        Card {
            DisclosureGroup(isExpanded: $isConnectionExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Agent URL", text: $viewModel.agentURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .textFieldStyle(WorkspaceTextFieldStyle())

                    TextField("Noise key path", text: $viewModel.keyPath)
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                        .textFieldStyle(WorkspaceTextFieldStyle())

                    Button("Use app support key path") {
                        viewModel.useAppSupportKeyPath()
                    }
                    .buttonStyle(PlainPillButtonStyle())

                    Toggle("Dev/test: skip TDX quote verification", isOn: $viewModel.insecureSkipQuoteVerify)

                    if !viewModel.insecureSkipQuoteVerify {
                        SecureField("Intel Trust Authority API key", text: $viewModel.itaAPIKey)
                            .textFieldStyle(WorkspaceTextFieldStyle())
                        TextField("ITA base URL", text: $viewModel.itaBaseURL)
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(WorkspaceTextFieldStyle())
                        TextField("ITA JWKS URL", text: $viewModel.itaJwksURL)
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(WorkspaceTextFieldStyle())
                        TextField("ITA issuer", text: $viewModel.itaIssuer)
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(WorkspaceTextFieldStyle())
                    }

                    Text("Paste a 32-byte Noise key as hex or base64 if the app cannot read your host key path.")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)

                    TextEditor(text: $viewModel.keyContent)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 88)
                        .padding(8)
                        .background(Palette.input)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button("Import pasted key") {
                        viewModel.importPastedKey()
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(viewModel.isBusy)
                }
                .padding(.top, 12)
            } label: {
                SectionHeader(title: "Connection", subtitle: viewModel.keyPath)
            }
        }
    }

    private var debugPanel: some View {
        Card {
            DisclosureGroup(isExpanded: $isDebugExpanded) {
                ScrollView([.horizontal, .vertical]) {
                    Text(viewModel.rawResponse.isEmpty ? "{}" : viewModel.rawResponse)
                        .font(.caption.monospaced())
                        .foregroundStyle(Palette.terminalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(minHeight: 140)
                .background(Palette.terminal)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 12)
            } label: {
                SectionHeader(title: "Debug", subtitle: "Last Rust response")
            }
        }
    }

    private var agentHost: String {
        URL(string: viewModel.agentURL)?.host ?? viewModel.agentURL
    }

    private var selectedSessionLabel: String {
        let id = viewModel.selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            return "No session selected"
        }
        return "Session \(String(id.prefix(8)))"
    }

    private var transcriptText: String {
        viewModel.transcript.isEmpty ? "No transcript loaded" : viewModel.transcript
    }
}

private enum Palette {
    static let page = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let card = Color(red: 0.99, green: 0.98, blue: 0.94)
    static let chip = Color(red: 0.91, green: 0.86, blue: 0.77)
    static let input = Color(red: 0.94, green: 0.92, blue: 0.87)
    static let status = Color(red: 0.90, green: 0.87, blue: 0.80)
    static let border = Color.black.opacity(0.10)
    static let text = Color(red: 0.14, green: 0.12, blue: 0.09)
    static let muted = Color(red: 0.42, green: 0.37, blue: 0.30)
    static let accent = Color(red: 0.54, green: 0.30, blue: 0.18)
    static let accentText = Color(red: 0.99, green: 0.97, blue: 0.91)
    static let ready = Color(red: 0.20, green: 0.48, blue: 0.31)
    static let busy = Color(red: 0.70, green: 0.43, blue: 0.12)
    static let terminal = Color(red: 0.13, green: 0.12, blue: 0.10)
    static let terminalText = Color(red: 0.94, green: 0.91, blue: 0.82)
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Palette.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 6)
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Palette.text)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .foregroundStyle(Palette.text)
            .background(Palette.input)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(isSelected ? Palette.accent : Palette.border)
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Palette.text)
                    Text(session.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    if !session.detail.isEmpty {
                        Text(session.detail)
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                }

                Spacer()
            }
            .padding(12)
            .background(isSelected ? Palette.chip : Palette.input)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SummaryRow: View {
    let title: String
    let id: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.text)
            Text(id)
                .font(.caption.monospaced())
                .foregroundStyle(Palette.muted)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.input)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct EmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Palette.input)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct TranscriptReaderView: View {
    @Environment(\.dismiss) private var dismiss
    let transcript: String
    @Binding var fontSize: Double

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.terminal.ignoresSafeArea()

                ScrollView([.horizontal, .vertical]) {
                    Text(transcript.isEmpty ? "No transcript loaded" : transcript)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(Palette.terminalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
            }
            .navigationTitle("Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Stepper(
                    "Text \(Int(fontSize)) pt",
                    value: $fontSize,
                    in: 11...34,
                    step: 1
                )
                .font(.callout)
                .foregroundStyle(Palette.terminalText)
                .padding(14)
                .background(Palette.terminal.opacity(0.92))
            }
        }
    }
}

private struct WorkspaceTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(12)
            .background(Palette.input)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(Palette.text)
            .background(Palette.input)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(Palette.accentText)
            .background(Palette.accent)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct PlainPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(Palette.text)
            .background(Palette.input)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.70 : 1)
    }
}
