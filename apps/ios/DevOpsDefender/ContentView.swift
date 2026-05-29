import SwiftUI

struct ContentView: View {
    @StateObject private var model = SessionModel()

    var body: some View {
        NavigationStack {
            if model.connected {
                SessionView(model: model)
                    .navigationTitle("Session")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Disconnect") { model.disconnect() }
                        }
                    }
            } else {
                ConnectForm(model: model)
                    .navigationTitle("DevOps Defender")
            }
        }
    }
}

/// Connect form. `keyPath` defaults into the app's container; the device key is
/// created on first use and enrolled out-of-band via the CP `/admin/enroll` URL
/// (`keygen` returns it).
struct ConnectForm: View {
    @ObservedObject var model: SessionModel
    @State private var agentUrl = "https://"
    @State private var sessionId = ""
    @State private var insecure = false

    private var keyPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("noise.key").path
    }

    var body: some View {
        Form {
            Section("Agent") {
                TextField("Agent URL", text: $agentUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Session ID", text: $sessionId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Skip quote verification", isOn: $insecure)
            }
            Section {
                Button(model.connecting ? "Connecting…" : "Connect") {
                    model.connect(
                        agentUrl: agentUrl, keyPath: keyPath,
                        sessionId: sessionId, insecure: insecure)
                }
                .disabled(model.connecting || agentUrl.isEmpty || sessionId.isEmpty)
            }
            Section { Text(model.status).foregroundStyle(.secondary) }
        }
    }
}

/// The session: a mode picker, the streamed block document, and (in Interact)
/// an input bar.
struct SessionView: View {
    @ObservedObject var model: SessionModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: model.setMode)) {
                Text("Watch").tag(FfiMode.watch)
                Text("Interact").tag(FfiMode.interact)
                Text("Raw").tag(FfiMode.raw)
            }
            .pickerStyle(.segmented)
            .padding(8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.blocks.enumerated()), id: \.offset) { idx, block in
                            BlockView(block: block, interactive: model.mode == .interact) { opt, i in
                                model.pick(option: opt, index: i)
                            }
                            .id(idx)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: model.blocks.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }

            if model.mode == .interact {
                HStack {
                    TextField("Send to session…", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Send") {
                        model.send(draft + "\n")
                        draft = ""
                    }
                    .disabled(draft.isEmpty)
                }
                .padding(8)
            }
        }
    }
}

/// Renders one block. The whole point of the design: markdown reads as markdown,
/// menus are tappable, code/diffs are monospaced — not a terminal.
struct BlockView: View {
    let block: FfiBlock
    let interactive: Bool
    let onPick: (FfiMenuOption, Int) -> Void

    var body: some View {
        switch block {
        case let .markdown(text, _):
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .code(lang, text, _):
            VStack(alignment: .leading, spacing: 2) {
                if let lang { Text(lang).font(.caption2).foregroundStyle(.secondary) }
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

        case let .diff(unified, _):
            DiffView(unified: unified)

        case let .menu(title, options, selected, resolved):
            VStack(alignment: .leading, spacing: 6) {
                if let title { Text(title).font(.headline) }
                ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                    Button { onPick(opt, i) } label: {
                        HStack {
                            Image(systemName: selected == UInt32(i)
                                ? "largecircle.fill.circle" : "circle")
                            Text(opt.label)
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!interactive || resolved)
                }
            }
            .padding(8)
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

        case let .input(prompt):
            Text(prompt).italic().foregroundStyle(.secondary)

        case let .rawTerminal(screen):
            Text(screen)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DiffView: View {
    let unified: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let lines = unified.split(separator: "\n", omittingEmptySubsequences: false)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(color(for: line.first))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func color(for first: Character?) -> Color {
        switch first {
        case "+": return .green
        case "-": return .red
        case "@": return .purple
        default: return .primary
        }
    }
}
