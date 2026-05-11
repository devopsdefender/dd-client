import SwiftUI

enum ActiveSheet: Identifiable {
    case events
    case commands
    case history
    case mode
    case keys

    var id: String {
        switch self {
        case .events: return "events"
        case .commands: return "commands"
        case .history: return "history"
        case .mode: return "mode"
        case .keys: return "keys"
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ClientViewModel()
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        ZStack(alignment: .top) {
            Palette.background.ignoresSafeArea()

            switch viewModel.appMode {
            case .chooser:
                LaunchView(viewModel: viewModel)
            case .fleet:
                AgentListView(viewModel: viewModel)
            case .session:
                sessionView
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .events:
                EventsSheet(viewModel: viewModel, onDismiss: { activeSheet = nil })
            case .commands:
                CommandsSheet(viewModel: viewModel, onDismiss: { activeSheet = nil })
            case .history:
                HistorySheet(viewModel: viewModel, onDismiss: { activeSheet = nil })
            case .mode:
                ModeSheet(viewModel: viewModel, onDismiss: { activeSheet = nil })
            case .keys:
                KeysSheet(viewModel: viewModel, onDismiss: { activeSheet = nil })
            }
        }
        .onOpenURL { url in
            viewModel.openMobileLink(url)
        }
        .onChange(of: viewModel.debugAutoOpenEvents) { _, newValue in
            if newValue {
                activeSheet = .events
            }
        }
        .onChange(of: viewModel.debugAutoOpenSheet) { _, sheet in
            switch sheet {
            case "commands": activeSheet = .commands
            case "history": activeSheet = .history
            case "mode": activeSheet = .mode
            case "keys": activeSheet = .keys
            case "events": activeSheet = .events
            default: break
            }
        }
    }

    /// The existing session UI (status bar + transcript + keyboard).
    /// Kept as a subview so the top-level `body` can switch between it
    /// and the fleet/launch screens.
    private var sessionView: some View {
        VStack(spacing: 0) {
            statusBar
            transcriptArea
            KeyboardSurface(viewModel: viewModel, activeSheet: $activeSheet)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Button {
                    viewModel.returnToChooser()
                } label: {
                    Image(systemName: "chevron.backward.circle")
                        .font(.callout)
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to home")

                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)

                Text(primaryLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Button {
                    activeSheet = .events
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.badge")
                            .font(.caption2)
                        Text("\(viewModel.oscEvents.count)")
                            .font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.muted.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.text)
                .accessibilityLabel("Events")

                if viewModel.hasLinkedSession {
                    Text(shortSessionLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(Palette.muted)
                }
            }

            HStack(spacing: 6) {
                Text(secondaryLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(secondaryLabelColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let error = viewModel.lastSendError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Palette.error)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.surface)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Palette.divider), alignment: .bottom)
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                Text(transcriptDisplay)
                    .font(transcriptFont)
                    .foregroundStyle(Palette.transcriptDefaultText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .id("transcriptBottom")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.transcriptBackground)
            .onChange(of: viewModel.transcript) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("transcriptBottom", anchor: .bottomLeading)
                }
            }
        }
    }

    private var transcriptDisplay: AttributedString {
        if !viewModel.transcript.isEmpty {
            return viewModel.attributedTranscript
        }
        if viewModel.hasLinkedSession {
            return AttributedString(viewModel.status)
        }
        return AttributedString("Open a DevOps Defender session link from the desktop CLI.")
    }

    private var transcriptFont: Font {
        viewModel.effectiveApp.isFancy
            ? .system(size: 14, design: .monospaced)
            : .system(size: 13, design: .monospaced)
    }

    // MARK: - Status text

    private var primaryLabel: String {
        guard viewModel.hasLinkedSession else { return "DevOps Defender" }
        switch viewModel.keyboardMode {
        case .generating(let label):
            return label.isEmpty ? "Working" : label
        case .choose:
            return "Choose one"
        case .confirm:
            return "Confirm"
        case .idle(let latest):
            return latest?.nonEmpty ?? viewModel.effectiveApp.displayName
        case .rawShell:
            return "Shell"
        case .disconnected:
            return viewModel.effectiveApp.displayName
        }
    }

    private var secondaryLabel: String {
        switch viewModel.keyboardMode {
        case .generating:
            return "Tap Interrupt to send Esc"
        case .choose(let options):
            return "\(options.count) options · tap one or use ↑↓⏎"
        case .confirm:
            return "Yes / No"
        case .idle(let latest):
            if let latest, !latest.isEmpty { return "Last: \(latest)" }
            return viewModel.status
        case .rawShell:
            return viewModel.status
        case .disconnected:
            return viewModel.status
        }
    }

    private var secondaryLabelColor: Color {
        switch viewModel.keyboardMode {
        case .choose, .confirm: return Palette.attention
        case .generating: return Palette.busy
        default: return Palette.muted
        }
    }

    private var statusDotColor: Color {
        if viewModel.isBusy { return Palette.busy }
        if !viewModel.hasLinkedSession { return Palette.muted }
        if !viewModel.isStreamConnected { return Palette.busy }
        switch viewModel.keyboardMode {
        case .generating: return Palette.busy
        case .choose, .confirm: return Palette.attention
        default: return Palette.ready
        }
    }

    private var shortSessionLabel: String {
        guard viewModel.hasLinkedSession else { return "" }
        return String(viewModel.selectedSessionID.prefix(8))
    }
}

// MARK: - Keyboard surface

private struct KeyboardSurface: View {
    @ObservedObject var viewModel: ClientViewModel
    @Binding var activeSheet: ActiveSheet?

    var body: some View {
        VStack(spacing: 10) {
            content
            if showMenuRail {
                MenuRail(viewModel: viewModel, activeSheet: $activeSheet)
            }
            navStrip
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.surface)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Palette.divider), alignment: .top)
    }

    private var showMenuRail: Bool {
        switch viewModel.keyboardMode {
        case .disconnected, .generating: return false
        case .choose, .confirm, .idle, .rawShell: return true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.keyboardMode {
        case .disconnected:
            disconnectedContent
        case .generating(let label):
            InterruptPanel(label: label) {
                viewModel.sendKey(.escape)
            }
        case .choose(let options):
            ChoosePanel(options: options) { index in
                viewModel.sendText("\(index)\n")
            }
        case .confirm:
            ConfirmPanel(viewModel: viewModel)
        case .idle(let latest):
            IdleComposer(viewModel: viewModel, hint: latest)
        case .rawShell:
            RawShellPanel(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var disconnectedContent: some View {
        if viewModel.canReconnect {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(Palette.busy)
                    Text("Stream disconnected")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Palette.text)
                    Spacer()
                }
                Button {
                    viewModel.manualReconnect()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text("Reconnect")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
            }
        } else {
            HStack {
                Image(systemName: "link.badge.plus")
                Text("Open a DevOps Defender session link to begin.")
                    .font(.callout)
            }
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var navStrip: some View {
        if showNavStrip {
            HStack(spacing: 8) {
                NavChip(label: "↑") { viewModel.sendKey(.arrowUp) }
                NavChip(label: "↓") { viewModel.sendKey(.arrowDown) }
                NavChip(label: "⏎") { viewModel.sendKey(.enter) }
                NavChip(label: "Esc") { viewModel.sendKey(.escape) }
                Spacer()
                NavChip(label: "⌃C", destructive: true) { viewModel.sendKey(.ctrlC) }
            }
            .disabled(!viewModel.isStreamConnected)
            .opacity(viewModel.isStreamConnected ? 1.0 : 0.4)
        }
    }

    private var showNavStrip: Bool {
        switch viewModel.keyboardMode {
        case .disconnected, .generating: return false
        case .choose, .confirm, .idle, .rawShell: return true
        }
    }
}

// MARK: - Panels

private struct InterruptPanel: View {
    let label: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.callout.monospaced())
                .foregroundStyle(Palette.busy)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(role: .destructive, action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "stop.circle.fill")
                    Text("Interrupt")
                        .font(.title3.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.error)
        }
    }
}

private struct ChoosePanel: View {
    let options: [String]
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(options.prefix(9).enumerated()), id: \.offset) { entry in
                let index = entry.offset + 1
                Button {
                    onChoose(index)
                } label: {
                    HStack(spacing: 10) {
                        Text("\(index).")
                            .font(.body.monospaced().weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 26, alignment: .leading)
                        Text(entry.element)
                            .font(.body)
                            .foregroundStyle(Palette.text)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Palette.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Palette.divider.opacity(0.6), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ConfirmPanel: View {
    @ObservedObject var viewModel: ClientViewModel

    var body: some View {
        VStack(spacing: 6) {
            ConfirmRow(
                index: 1,
                title: "Yes",
                systemImage: "checkmark.circle.fill",
                tint: Palette.ready
            ) {
                viewModel.sendText("1\n")
            }
            ConfirmRow(
                index: 2,
                title: "Yes, don't ask again this session",
                systemImage: "checkmark.circle.fill",
                tint: Palette.accent
            ) {
                viewModel.sendText("2\n")
            }
            ConfirmRow(
                index: 3,
                title: "No, tell me what to do differently",
                systemImage: "arrow.uturn.left.circle.fill",
                tint: Palette.error
            ) {
                viewModel.sendText("3\n")
            }
        }
    }
}

private struct ConfirmRow: View {
    let index: Int
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(index).")
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, alignment: .leading)
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.body)
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Palette.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct IdleComposer: View {
    @ObservedObject var viewModel: ClientViewModel
    let hint: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $viewModel.inputDraft, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Palette.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Palette.divider.opacity(0.6), lineWidth: 0.5)
                )
                .disabled(!viewModel.isStreamConnected)

            Button {
                viewModel.submitDraft(appendNewline: true)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Palette.accent : Palette.muted.opacity(0.5))
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    private var canSend: Bool {
        viewModel.isStreamConnected && !viewModel.inputDraft.isEmpty
    }

    private var placeholder: String {
        if let hint, !hint.isEmpty {
            return "Reply to Claude…"
        }
        return "Type a message…"
    }
}

private struct SlashChip: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.monospaced().weight(.semibold))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Palette.accent.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

private struct RawShellPanel: View {
    @ObservedObject var viewModel: ClientViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Type a command…", text: $viewModel.inputDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Palette.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Palette.divider.opacity(0.6), lineWidth: 0.5)
                    )
                    .disabled(!viewModel.isStreamConnected)

                Button {
                    viewModel.submitDraft(appendNewline: true)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Palette.accent : Palette.muted.opacity(0.5))
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    NavChip(label: "Tab") { viewModel.sendKey(.tab) }
                    NavChip(label: "←") { viewModel.sendKey(.arrowLeft) }
                    NavChip(label: "→") { viewModel.sendKey(.arrowRight) }
                    NavChip(label: "⌃D", destructive: true) { viewModel.sendKey(.ctrlD) }
                    SlashChip(label: "clear") { viewModel.sendText("clear\n") }
                    SlashChip(label: "ls") { viewModel.sendText("ls\n") }
                    SlashChip(label: "pwd") { viewModel.sendText("pwd\n") }
                }
            }
            .disabled(!viewModel.isStreamConnected)
        }
    }

    private var canSend: Bool {
        viewModel.isStreamConnected && !viewModel.inputDraft.isEmpty
    }
}

// MARK: - Menu rail

private struct MenuRail: View {
    @ObservedObject var viewModel: ClientViewModel
    @Binding var activeSheet: ActiveSheet?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MenuLauncher(
                    label: "Commands",
                    systemImage: "command.square",
                    badge: nil
                ) { activeSheet = .commands }

                MenuLauncher(
                    label: "History",
                    systemImage: "clock.arrow.circlepath",
                    badge: viewModel.sentHistory.isEmpty ? nil : "\(viewModel.sentHistory.count)"
                ) { activeSheet = .history }

                MenuLauncher(
                    label: "Mode",
                    systemImage: "rectangle.stack",
                    badge: nil
                ) { activeSheet = .mode }

                MenuLauncher(
                    label: "Keys",
                    systemImage: "keyboard.chevron.compact.left",
                    badge: nil
                ) { activeSheet = .keys }
            }
            .padding(.horizontal, 2)
        }
        .disabled(!viewModel.isStreamConnected)
        .opacity(viewModel.isStreamConnected ? 1.0 : 0.4)
    }
}

private struct MenuLauncher: View {
    let label: String
    let systemImage: String
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.callout)
                Text(label)
                    .font(.callout.weight(.semibold))
                if let badge {
                    Text(badge)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.accent.opacity(0.22)))
                }
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Palette.muted.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Menu sheets

private struct CommandsSheet: View {
    @ObservedObject var viewModel: ClientViewModel
    let onDismiss: () -> Void
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(SlashCatalog.filtered(by: query)) { command in
                    Button {
                        if command.takesArgument {
                            viewModel.inputDraft = "\(command.name) "
                            onDismiss()
                        } else {
                            viewModel.sendText("\(command.name)\n")
                            onDismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(command.name)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Palette.accent)
                                .frame(width: 110, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.summary)
                                    .font(.body)
                                    .foregroundStyle(Palette.text)
                                if command.takesArgument {
                                    Text("takes an argument — fills the composer")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward.circle")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Slash commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }
}

private struct HistorySheet: View {
    @ObservedObject var viewModel: ClientViewModel
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.sentHistory.isEmpty {
                    ContentUnavailableView(
                        "No messages sent yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Anything you send to the linked session will appear here so you can recall and resend it.")
                    )
                } else {
                    List {
                        ForEach(Array(viewModel.sentHistory.enumerated().reversed()), id: \.offset) { entry in
                            Button {
                                viewModel.inputDraft = entry.element.text
                                onDismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.element.text)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(Palette.text)
                                        .lineLimit(4)
                                    Text(entry.element.at, style: .time)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }
}

private struct ModeSheet: View {
    @ObservedObject var viewModel: ClientViewModel
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Claude Code cycles modes with Shift+Tab. Tap to send Shift+Tab once.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 4)

                ForEach(ClaudeMode.allCases) { mode in
                    Button {
                        viewModel.sendKey(.shiftTab)
                        onDismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: mode.systemImage)
                                .font(.title3)
                                .foregroundStyle(Palette.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Palette.text)
                                Text(mode.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward.circle")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12).fill(Palette.background)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12).stroke(Palette.divider.opacity(0.5), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    viewModel.sendKey(.shiftTab)
                } label: {
                    Label("Send Shift+Tab again", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.muted.opacity(0.35))
                .padding(.top, 6)

                Spacer()
            }
            .padding(16)
            .navigationTitle("Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }
}

private struct KeysSheet: View {
    @ObservedObject var viewModel: ClientViewModel
    let onDismiss: () -> Void

    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 10) {
                    KeyTile(label: "Tab", systemImage: "arrow.right.to.line") { viewModel.sendKey(.tab) }
                    KeyTile(label: "Shift+Tab", systemImage: "arrow.left.to.line") { viewModel.sendKey(.shiftTab) }
                    KeyTile(label: "Esc", systemImage: "escape") { viewModel.sendKey(.escape) }
                    KeyTile(label: "Esc Esc", systemImage: "escape") { viewModel.sendKey(.escEsc) }
                    KeyTile(label: "Enter", systemImage: "return") { viewModel.sendKey(.enter) }
                    KeyTile(label: "Newline", systemImage: "text.insert") { viewModel.sendKey(.newline) }
                    KeyTile(label: "↑", systemImage: "arrow.up") { viewModel.sendKey(.arrowUp) }
                    KeyTile(label: "↓", systemImage: "arrow.down") { viewModel.sendKey(.arrowDown) }
                    KeyTile(label: "←", systemImage: "arrow.left") { viewModel.sendKey(.arrowLeft) }
                    KeyTile(label: "→", systemImage: "arrow.right") { viewModel.sendKey(.arrowRight) }
                    KeyTile(label: "Ctrl-R", systemImage: "doc.text.magnifyingglass") { viewModel.sendKey(.ctrlR) }
                    KeyTile(label: "Ctrl-L", systemImage: "eraser") { viewModel.sendKey(.ctrlL) }
                    KeyTile(label: "Ctrl-C", systemImage: "stop.circle", destructive: true) { viewModel.sendKey(.ctrlC) }
                    KeyTile(label: "Ctrl-D", systemImage: "power", destructive: true) { viewModel.sendKey(.ctrlD) }
                    KeyTile(label: "Backspace", systemImage: "delete.left") { viewModel.sendKey(.backspace) }
                }
                .padding(16)
            }
            .navigationTitle("Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }
}

private struct KeyTile: View {
    let label: String
    let systemImage: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(tile)
            )
            .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
    }

    private var tile: Color {
        destructive ? Palette.error.opacity(0.14) : Palette.muted.opacity(0.18)
    }

    private var foreground: Color {
        destructive ? Palette.error : Palette.text
    }
}

// MARK: - Shared chips

private struct NavChip: View {
    let label: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout.monospaced().weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(background)
                )
                .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        destructive ? Palette.error.opacity(0.14) : Palette.muted.opacity(0.18)
    }

    private var foreground: Color {
        destructive ? Palette.error : Palette.text
    }
}

// MARK: - Events sheet

private struct EventsSheet: View {
    @ObservedObject var viewModel: ClientViewModel
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.oscEvents.isEmpty {
                    ContentUnavailableView(
                        "No events yet",
                        systemImage: "bell.slash",
                        description: Text(
                            "OSC and BEL escapes captured from the live PTY stream will appear here. Drive the agent through a state change to see what it emits."
                        )
                    )
                } else {
                    List {
                        if !viewModel.titles.isEmpty {
                            Section("Title timeline (\(viewModel.titles.count))") {
                                ForEach(Array(viewModel.titles.enumerated().reversed()), id: \.offset) { entry in
                                    TitleRow(event: entry.element)
                                }
                            }
                        }
                        Section("Raw events (\(viewModel.oscEvents.count))") {
                            ForEach(viewModel.oscEvents.reversed()) { event in
                                EventRow(event: event)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Captured events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }
}

private struct TitleRow: View {
    let event: TitleEvent

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(kindLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(kindColor.opacity(0.18)))
                    .foregroundStyle(kindColor)
                Text(TitleRow.timeFormatter.string(from: event.at))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(event.display)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var kindLabel: String {
        switch event.kind {
        case .generating: return "WORK"
        case .ready: return "READY"
        case .working: return "TITLE"
        case .unknown: return "?"
        }
    }

    private var kindColor: Color {
        switch event.kind {
        case .generating: return Color(red: 0.70, green: 0.43, blue: 0.12)
        case .ready: return Color(red: 0.20, green: 0.48, blue: 0.31)
        case .working: return Color(red: 0.32, green: 0.30, blue: 0.62)
        case .unknown: return .gray
        }
    }
}

private struct EventRow: View {
    let event: OSCEvent

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(badgeText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(badgeColor.opacity(0.18)))
                    .foregroundStyle(badgeColor)
                Text(EventRow.timeFormatter.string(from: event.at))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("@\(event.byteOffset)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if event.kind == .osc {
                Text(displayPayload)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private var badgeText: String {
        switch event.kind {
        case .osc:
            if let ps = event.oscPs { return "OSC \(ps)" }
            return "OSC"
        case .bell: return "BEL"
        }
    }

    private var badgeColor: Color {
        switch event.kind {
        case .osc: return Color(red: 0.32, green: 0.30, blue: 0.62)
        case .bell: return Color(red: 0.85, green: 0.39, blue: 0.10)
        }
    }

    private var displayPayload: String {
        let raw = event.raw
        guard !raw.isEmpty else { return "(empty)" }
        return raw
            .replacingOccurrences(of: "\u{1B}", with: "\\e")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - Palette

private enum Palette {
    static let background = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let surface = Color(red: 0.99, green: 0.97, blue: 0.93)
    static let text = Color(red: 0.16, green: 0.14, blue: 0.11)
    static let muted = Color(red: 0.42, green: 0.37, blue: 0.30)
    static let divider = Color(red: 0.70, green: 0.63, blue: 0.52)
    static let ready = Color(red: 0.20, green: 0.48, blue: 0.31)
    static let busy = Color(red: 0.70, green: 0.43, blue: 0.12)
    static let attention = Color(red: 0.85, green: 0.39, blue: 0.10)
    static let error = Color(red: 0.78, green: 0.18, blue: 0.18)
    static let accent = Color(red: 0.32, green: 0.30, blue: 0.62)
    static let transcriptBackground = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let transcriptDefaultText = Color(red: 0.91, green: 0.89, blue: 0.84)
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
