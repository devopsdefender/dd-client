import Foundation
import SwiftUI

struct AgentSettings: Sendable {
    var agentURL: String
    var keyPath: String
}

struct DDClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum DDClientBridge {
    static func importKey(keyPath: String, keyContent: String) throws {
        let responsePointer = keyPath.withCString { keyPathCString in
            keyContent.withCString { keyContentCString in
                dd_client_import_key(keyPathCString, keyContentCString)
            }
        }
        _ = try decodeResponse(responsePointer)
    }

    static func transcriptHistory(id: String, settings: AgentSettings) throws -> [String: Any] {
        try request([
            "agent_url": settings.agentURL,
            "key_path": settings.keyPath,
            "insecure_skip_quote_verify": true,
            "ita_api_key": "",
            "ita_base_url": "",
            "ita_jwks_url": "",
            "ita_issuer": "",
            "id": id,
            "max_bytes": 32768
        ], using: dd_client_replay_session)
    }

    static func listSessions(settings: AgentSettings) throws -> [String: Any] {
        try request([
            "agent_url": settings.agentURL,
            "key_path": settings.keyPath,
            "insecure_skip_quote_verify": true,
            "ita_api_key": "",
            "ita_base_url": "",
            "ita_jwks_url": "",
            "ita_issuer": ""
        ], using: dd_client_list_sessions)
    }

    static func startAttachStream(
        id: String,
        settings: AgentSettings,
        onEvent: @escaping @Sendable (AttachStreamEvent) -> Void
    ) throws -> AttachStream {
        let payload: [String: Any] = [
            "agent_url": settings.agentURL,
            "key_path": settings.keyPath,
            "insecure_skip_quote_verify": true,
            "ita_api_key": "",
            "ita_base_url": "",
            "ita_jwks_url": "",
            "ita_issuer": "",
            "id": id
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let requestJSON = String(data: data, encoding: .utf8) else {
            throw DDClientError(message: "Failed to encode stream request")
        }
        guard let stream = AttachStream(requestJSON: requestJSON, onEvent: onEvent) else {
            throw DDClientError(message: "Failed to start attach stream")
        }
        return stream
    }

    private static func request(
        _ payload: [String: Any],
        using call: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) throws -> [String: Any] {
        let requestData = try JSONSerialization.data(withJSONObject: payload)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw DDClientError(message: "Failed to encode FFI request")
        }

        let responsePointer = requestJSON.withCString { requestCString in
            call(requestCString)
        }
        return try decodeResponse(responsePointer)
    }

    private static func decodeResponse(_ responsePointer: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        guard let responsePointer else {
            throw DDClientError(message: "Rust FFI returned a null response")
        }
        defer {
            dd_client_string_free(responsePointer)
        }

        let responseJSON = String(cString: responsePointer)
        guard let responseData = responseJSON.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw DDClientError(message: "Failed to decode FFI response: \(responseJSON)")
        }

        if response["ok"] as? Bool == true {
            return response
        }
        throw DDClientError(message: response["error"] as? String ?? responseJSON)
    }
}

struct AttachStreamEvent: Sendable {
    var type: String
    var data: Data?
    var message: String?
}

final class AttachStream {
    private let handle: UInt64

    init?(requestJSON: String, onEvent: @escaping @Sendable (AttachStreamEvent) -> Void) {
        let context = Unmanaged.passRetained(AttachStreamContext(onEvent: onEvent)).toOpaque()
        let handle = requestJSON.withCString { requestCString in
            dd_client_attach_stream_start(requestCString, attachStreamCallback, context)
        }
        if handle == 0 {
            Unmanaged<AttachStreamContext>.fromOpaque(context).release()
            return nil
        }
        self.handle = handle
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return dd_client_attach_stream_send(handle, base, raw.count)
        }
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return send(data)
    }

    func stop() {
        dd_client_attach_stream_stop(handle)
    }

    deinit {
        stop()
    }
}

private final class AttachStreamContext {
    let onEvent: @Sendable (AttachStreamEvent) -> Void

    init(onEvent: @escaping @Sendable (AttachStreamEvent) -> Void) {
        self.onEvent = onEvent
    }
}

private let attachStreamCallback: @convention(c) (
    UInt64,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { _, eventPointer, contextPointer in
    guard let eventPointer, let contextPointer else {
        return
    }
    let eventJSON = String(cString: eventPointer)
    let event = parseAttachStreamEvent(eventJSON)
    let context = Unmanaged<AttachStreamContext>.fromOpaque(contextPointer).takeUnretainedValue()
    context.onEvent(event)
    if event.type == "close" {
        Unmanaged<AttachStreamContext>.fromOpaque(contextPointer).release()
    }
}

enum AppDefaults {
    static var appSupportNoiseKeyPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("devopsdefender", isDirectory: true)
            .appendingPathComponent("noise.key")
            .path
    }
}

enum AppMode: Equatable {
    case chooser
    case fleet
    case session
}

@MainActor
final class ClientViewModel: ObservableObject {
    @Published var appMode: AppMode = .chooser
    @Published var selectedSessionID = ""
    @Published var transcript = ""
    @Published var attributedTranscript = AttributedString("")
    @Published var status = "Open a mobile link from desktop"
    @Published var isBusy = false
    @Published var detection: DetectionResult = .empty
    @Published var inputDraft = ""
    @Published var isStreamConnected = false
    @Published var lastSendError: String?
    @Published var oscEvents: [OSCEvent] = []
    @Published var debugAutoOpenEvents = false
    @Published var debugAutoOpenSheet: String? = nil
    @Published var keyboardMode: KeyboardMode = .disconnected
    @Published var titles: [TitleEvent] = []
    @Published var effectiveApp: DetectedApp = .rawShell
    @Published var sentHistory: [SentInput] = []

    private var agentURL = ""
    private var keyPath = AppDefaults.appSupportNoiseKeyPath
    private var attachStream: AttachStream?
    private var terminalRenderer = TerminalScreenRenderer(width: 96, maxRows: 160)
    private var oscSniffer = OSCSniffer()
    private var titleClassifier = TitleClassifier()
    private var refreshScheduled = false
    private var lastRenderedText = ""
    private let refreshInterval: TimeInterval = 0.08
    private let visibleTailRows: Int = 80
    private var idleTickTimer: Timer?
    private let idleTickInterval: TimeInterval = 1.0
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private let reconnectMaxDelay: TimeInterval = 30

    var hasLinkedSession: Bool {
        !selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// We have enough state to reattach the same Noise stream without
    /// requiring the user to re-tap the desktop link.
    var canReconnect: Bool {
        hasLinkedSession
            && !agentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func manualReconnect() {
        cancelScheduledReconnect()
        reconnectAttempts = 0
        startAttachStream()
    }

    /// Switch to the fleet flow. Called from the LaunchView's
    /// "Sign in with GitHub" button.
    func enterFleet() {
        appMode = .fleet
    }

    /// Return to the launch chooser. Called when sign-out happens or
    /// the user explicitly backs out of a session.
    func returnToChooser() {
        attachStream?.stop()
        attachStream = nil
        isStreamConnected = false
        stopIdleTick()
        cancelScheduledReconnect()
        reconnectAttempts = 0
        selectedSessionID = ""
        agentURL = ""
        transcript = ""
        attributedTranscript = AttributedString("")
        detection = .empty
        titles = []
        sentHistory = []
        inputDraft = ""
        status = "Open a session link or sign in with GitHub"
        appMode = .chooser
    }

    /// Wipe the CP-issued bearer token and return to the chooser.
    func signOutOfFleet(keychain: KeychainStore = KeychainStore()) {
        keychain.reset()
        returnToChooser()
    }

    /// Begin a session that was picked from the fleet flow. Uses the
    /// iOS device's own Noise key (`AppKeyStore`), not the mobile-link
    /// imported key.
    func attachToFleetSession(agentURL: String, sessionID: String) {
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = agentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !agent.isEmpty else {
            status = "Missing agent or session"
            return
        }
        attachStream?.stop()
        attachStream = nil
        isStreamConnected = false
        stopIdleTick()
        cancelScheduledReconnect()
        reconnectAttempts = 0

        self.agentURL = agent
        self.selectedSessionID = id
        self.keyPath = AppKeyStore.shared.keyPath
        self.transcript = ""
        self.attributedTranscript = AttributedString("")
        self.detection = .empty
        self.titles = []
        self.sentHistory = []
        self.inputDraft = ""
        self.lastSendError = nil
        self.terminalRenderer = TerminalScreenRenderer(width: 96, maxRows: 160)
        self.oscSniffer.reset()
        self.oscEvents = []
        self.titleClassifier.reset()
        self.keyboardMode = .disconnected
        self.appMode = .session

        loadFleetTranscript()
    }

    private func loadFleetTranscript() {
        let id = selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = AgentSettings(
            agentURL: agentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPath: keyPath.expandingTildePath
        )
        run("Loading \(id)", startStreamAfterInitialLoad: true) {
            initialTranscriptUpdate(id: id, settings: settings)
        }
    }

    var linkedSessionTitle: String {
        let id = selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            return "No linked session"
        }
        return "Session \(String(id.prefix(8)))"
    }

    func openMobileLink(_ url: URL) {
        guard url.scheme == "devopsdefender",
              url.host == "session",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            status = "Unsupported mobile link"
            return
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value
        }

        guard let agent = query["agent"], !agent.isEmpty,
              let id = query["id"], !id.isEmpty else {
            status = "Mobile link missing agent or session"
            return
        }

        attachStream?.stop()
        attachStream = nil
        isStreamConnected = false
        stopIdleTick()
        cancelScheduledReconnect()
        reconnectAttempts = 0
        agentURL = agent
        selectedSessionID = id
        keyPath = AppDefaults.appSupportNoiseKeyPath
        transcript = ""
        attributedTranscript = AttributedString("")
        detection = .empty
        inputDraft = ""
        lastSendError = nil
        terminalRenderer = TerminalScreenRenderer(width: 96, maxRows: 160)
        oscSniffer.reset()
        oscEvents = []
        lastRenderedText = ""
        refreshScheduled = false
        titleClassifier.reset()
        titles = []
        keyboardMode = .disconnected
        sentHistory = []
        appMode = .session

        guard let key = query["key"], !key.isEmpty else {
            status = "Mobile link missing key"
            return
        }

        debugAutoOpenEvents = (query["debug_events"] == "1")
        debugAutoOpenSheet = query["debug_sheet"]
        importKeyAndLoadTranscript(key)
    }

    private func importKeyAndLoadTranscript(_ key: String) {
        let path = keyPath.expandingTildePath
        let id = selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = AgentSettings(
            agentURL: agentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPath: path
        )
        run("Importing key", startStreamAfterInitialLoad: true) {
            try DDClientBridge.importKey(keyPath: path, keyContent: key)
            return initialTranscriptUpdate(id: id, settings: settings)
        }
    }

    private func run(
        _ pendingStatus: String,
        startStreamAfterInitialLoad: Bool = false,
        work: @escaping @Sendable () throws -> ClientUpdate
    ) {
        guard !isBusy else {
            status = "Already loading"
            return
        }
        isBusy = true
        status = pendingStatus
        Task {
            do {
                let update = try await Task.detached(priority: .userInitiated) {
                    try work()
                }.value
                status = update.status
                apply(update)
                if startStreamAfterInitialLoad {
                    startAttachStream()
                }
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func startAttachStream() {
        let id = selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return
        }
        attachStream?.stop()
        let settings = AgentSettings(
            agentURL: agentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPath: keyPath.expandingTildePath
        )
        do {
            attachStream = try DDClientBridge.startAttachStream(id: id, settings: settings) { [weak self] event in
                Task { @MainActor in
                    self?.handleStreamEvent(event, id: id)
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func handleStreamEvent(_ event: AttachStreamEvent, id: String) {
        switch event.type {
        case "open":
            status = "Connected \(id)"
            isStreamConnected = true
            reconnectAttempts = 0
            cancelScheduledReconnect()
            startIdleTick()
            refreshKeyboardMode()
        case "bytes":
            guard let data = event.data,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            apply(ClientUpdate(status: "Connected \(id)", terminalText: text))
        case "error":
            status = event.message ?? "Stream error"
            isStreamConnected = false
            attachStream = nil
            stopIdleTick()
            refreshKeyboardMode()
            scheduleReconnectIfPossible()
        case "close":
            status = "Disconnected \(id)"
            isStreamConnected = false
            attachStream = nil
            stopIdleTick()
            refreshKeyboardMode()
            scheduleReconnectIfPossible()
        default:
            break
        }
    }

    /// Pick the next reconnect delay (1, 2, 4, 8, 16, 30 seconds, then
    /// capped). Returns nil when we shouldn't auto-reconnect — e.g. no
    /// linked session yet.
    private func scheduleReconnectIfPossible() {
        guard canReconnect else { return }
        cancelScheduledReconnect()
        let delay = min(pow(2.0, Double(reconnectAttempts)), reconnectMaxDelay)
        reconnectAttempts += 1
        status = "Reconnecting in \(Int(delay))s · attempt \(reconnectAttempts)"
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.attemptReconnect()
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func attemptReconnect() {
        reconnectWorkItem = nil
        guard canReconnect else { return }
        guard !isStreamConnected else { return }
        status = "Reconnecting…"
        startAttachStream()
    }

    private func startIdleTick() {
        stopIdleTick()
        let timer = Timer.scheduledTimer(withTimeInterval: idleTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshKeyboardMode()
            }
        }
        idleTickTimer = timer
    }

    private func stopIdleTick() {
        idleTickTimer?.invalidate()
        idleTickTimer = nil
    }

    /// Feed bytes into the renderer + sniffer immediately, but defer the
    /// expensive UI updates (AttributedString construction, detection,
    /// keyboard-mode resolution, @Published assignments) to a coalesced
    /// refresh that fires at most ~12fps. Claude can emit dozens of PTY
    /// chunks per second; rendering on every one of them is the lag.
    private func apply(_ update: ClientUpdate) {
        guard !update.terminalText.isEmpty else { return }
        let scalars = update.terminalText.unicodeScalars
        terminalRenderer.feed(scalars)
        oscSniffer.feed(scalars)
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshInterval) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.performRefresh()
        }
    }

    private func performRefresh() {
        let rendered = terminalRenderer.renderedText()
        let textChanged = rendered != lastRenderedText
        if textChanged {
            lastRenderedText = rendered
            let plain = rendered.isEmpty
                ? "(no transcript output before idle timeout)"
                : rendered
            if plain != transcript {
                transcript = plain
            }
            attributedTranscript = rendered.isEmpty
                ? AttributedString("(no transcript output before idle timeout)")
                : terminalRenderer.renderedAttributedString(
                    defaultForeground: Color(red: 0.91, green: 0.89, blue: 0.84),
                    lastRows: visibleTailRows
                )
            let newDetection = AppDetector.detect(transcript: rendered)
            if newDetection != detection {
                detection = newDetection
            }
        }
        if oscEvents.count != oscSniffer.events.count
            || oscEvents.last?.id != oscSniffer.events.last?.id {
            oscEvents = oscSniffer.events
        }
        titleClassifier.feed(oscSniffer.events)
        if titles.count != titleClassifier.titles.count
            || titles.last?.display != titleClassifier.titles.last?.display {
            titles = titleClassifier.titles
        }
        refreshKeyboardMode()
    }

    private func refreshKeyboardMode() {
        let resolvedApp = EffectiveAppResolver.resolve(
            detection: detection.app,
            titles: titleClassifier.titles
        )
        if resolvedApp != effectiveApp {
            effectiveApp = resolvedApp
        }
        let newMode = KeyboardModeResolver.resolve(
            detection: detection,
            effectiveApp: resolvedApp,
            latestTitle: titleClassifier.latest,
            isStreamConnected: isStreamConnected,
            quietSeconds: titleClassifier.quietSeconds()
        )
        if newMode != keyboardMode {
            keyboardMode = newMode
        }
    }

    func sendBytes(_ data: Data) {
        guard let stream = attachStream else {
            lastSendError = "Not connected"
            return
        }
        if !stream.send(data) {
            lastSendError = "Send failed"
        } else {
            lastSendError = nil
        }
    }

    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            lastSendError = "Could not encode text"
            return
        }
        recordSent(text)
        sendBytes(data)
    }

    private func recordSent(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = SentInput(text: trimmed, at: Date())
        if sentHistory.last?.text == trimmed { return }
        sentHistory.append(entry)
        if sentHistory.count > 200 {
            sentHistory.removeFirst(sentHistory.count - 200)
        }
    }

    func sendKey(_ key: SpecialKey) {
        sendBytes(key.bytes)
    }

    func submitDraft(appendNewline: Bool = true) {
        let payload = appendNewline ? inputDraft + "\n" : inputDraft
        guard !payload.isEmpty else { return }
        sendText(payload)
        inputDraft = ""
    }
}

struct SentInput: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let at: Date
}

enum SpecialKey {
    case enter
    case newline
    case escape
    case escEsc
    case tab
    case shiftTab
    case backspace
    case ctrlC
    case ctrlD
    case ctrlL
    case ctrlR
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case raw(Data)

    var bytes: Data {
        switch self {
        case .enter: return Data([0x0D])
        case .newline: return Data([0x0A])
        case .escape: return Data([0x1B])
        case .escEsc: return Data([0x1B, 0x1B])
        case .tab: return Data([0x09])
        case .shiftTab: return Data([0x1B, 0x5B, 0x5A])
        case .backspace: return Data([0x7F])
        case .ctrlC: return Data([0x03])
        case .ctrlD: return Data([0x04])
        case .ctrlL: return Data([0x0C])
        case .ctrlR: return Data([0x12])
        case .arrowUp: return Data([0x1B, 0x5B, 0x41])
        case .arrowDown: return Data([0x1B, 0x5B, 0x42])
        case .arrowRight: return Data([0x1B, 0x5B, 0x43])
        case .arrowLeft: return Data([0x1B, 0x5B, 0x44])
        case .raw(let data): return data
        }
    }
}

private struct ClientUpdate: Sendable {
    var status: String
    var terminalText: String
}

private extension String {
    var expandingTildePath: String {
        (self as NSString).expandingTildeInPath
    }
}

private func parseAttachStreamEvent(_ eventJSON: String) -> AttachStreamEvent {
    guard let data = eventJSON.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return AttachStreamEvent(type: "error", data: nil, message: "Invalid stream event")
    }

    let type = object["type"] as? String ?? "unknown"
    let payload = (object["data_b64"] as? String).flatMap { Data(base64Encoded: $0) }
    let message = object["message"] as? String
    return AttachStreamEvent(type: type, data: payload, message: message)
}

private func initialTranscriptUpdate(id: String, settings: AgentSettings) -> ClientUpdate {
    if let response = try? DDClientBridge.transcriptHistory(id: id, settings: settings) {
        let history = historyText(from: response)
        if !history.isEmpty {
            return ClientUpdate(status: "Loaded \(id)", terminalText: history)
        }
    }
    return ClientUpdate(status: "Loaded \(id)", terminalText: "")
}

private func transcriptText(from value: Any?) -> String {
    if let text = firstString(for: ["transcript", "output", "text", "stdout", "data"], in: value) {
        return text
    }
    return prettyJSONString(value ?? [:])
}

private func historyText(from value: Any?) -> String {
    guard let encoded = firstString(for: ["bytes_b64"], in: value),
          let data = Data(base64Encoded: encoded),
          let text = String(data: data, encoding: .utf8) else {
        return transcriptText(from: value)
    }
    return text
}

private func prettyJSONString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return "\(value)"
    }
    return text
}

private func firstString(for keys: [String], in value: Any?) -> String? {
    if let dict = value as? [String: Any] {
        for key in keys {
            if let text = dict[key] as? String, !text.isEmpty {
                return text
            }
        }
        for nested in dict.values {
            if let text = firstString(for: keys, in: nested) {
                return text
            }
        }
    }
    if let array = value as? [Any] {
        for item in array {
            if let text = firstString(for: keys, in: item) {
                return text
            }
        }
    }
    return nil
}

final class TerminalScreenRenderer {
    /// Snapshot of the main (scrollback) screen state taken when we
    /// enter the alternate buffer. The alternate buffer is for TUI-only
    /// content (Claude's prompt redraws) which we intentionally do not
    /// surface to the iOS transcript pane.
    private struct AltBackup {
        var rows: [[StyledCell]]
        var row: Int
        var column: Int
        var style: CellStyle
        var savedRow: Int
        var savedColumn: Int
        var savedStyle: CellStyle
    }

    private let width: Int
    private let maxRows: Int
    private var rows: [[StyledCell]]
    private var row = 0
    private var column = 0
    private var currentStyle = CellStyle.plain
    private var savedRow = 0
    private var savedColumn = 0
    private var savedStyle = CellStyle.plain
    private var inAltScreen = false
    private var altBackup: AltBackup?

    init(width: Int, maxRows: Int) {
        self.width = width
        self.maxRows = maxRows
        self.rows = [Self.blankRow(width: width)]
    }

    /// What we expose to the UI: the main scrollback contents, *not* the
    /// alt-screen TUI grid. While we're inside an alt screen, scrollback
    /// is frozen at whatever it was on entry (matches how real terminals
    /// behave — scrollback doesn't update during a TUI session).
    private var renderableRows: [[StyledCell]] {
        if inAltScreen { return altBackup?.rows ?? [] }
        return rows
    }

    func feed(_ scalars: String.UnicodeScalarView) {
        feed(Array(scalars))
    }

    func renderedText() -> String {
        renderableRows
            .map { row -> String in
                let scalars = String.UnicodeScalarView(row.map { $0.scalar })
                return trimTrailingSpaces(String(scalars))
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build an AttributedString from the styled grid, grouping runs of
    /// adjacent cells that share the same style. `lastRows` caps the
    /// number of rows included from the bottom — the buffer itself
    /// stays large for detection, but per-frame work shrinks to a
    /// fixed visible window so rapid PTY streams stay responsive.
    func renderedAttributedString(defaultForeground: Color, lastRows: Int = .max) -> AttributedString {
        let source = renderableRows
        let start = max(0, source.count - max(1, lastRows))
        var output = AttributedString("")
        for rowIndex in start..<source.count {
            let row = source[rowIndex]
            let trimmed = trimTrailingBlanks(row)
            if !trimmed.isEmpty {
                var runStart = 0
                while runStart < trimmed.count {
                    var runEnd = runStart + 1
                    while runEnd < trimmed.count, trimmed[runEnd].style == trimmed[runStart].style {
                        runEnd += 1
                    }
                    let scalars = String.UnicodeScalarView(trimmed[runStart..<runEnd].map { $0.scalar })
                    var piece = AttributedString(String(scalars))
                    apply(style: trimmed[runStart].style, to: &piece, defaultForeground: defaultForeground)
                    output += piece
                    runStart = runEnd
                }
            }
            if rowIndex < source.count - 1 {
                output += AttributedString("\n")
            }
        }
        return output
    }

    private func apply(style: CellStyle, to piece: inout AttributedString, defaultForeground: Color) {
        let effectiveFg = style.inverse
            ? style.bg.resolved(default: Palette.transcriptBackground)
            : style.fg.resolved(default: defaultForeground)
        let effectiveBg: Color? = style.inverse
            ? style.fg.resolved(default: defaultForeground)
            : (style.bg == .default ? nil : style.bg.resolved(default: Palette.transcriptBackground))

        piece.foregroundColor = style.dim ? effectiveFg.opacity(0.55) : effectiveFg
        if let bg = effectiveBg {
            piece.backgroundColor = bg
        }
        var traits: InlinePresentationIntent = []
        if style.bold { traits.insert(.stronglyEmphasized) }
        if style.italic { traits.insert(.emphasized) }
        if !traits.isEmpty {
            piece.inlinePresentationIntent = traits
        }
        if style.underline {
            piece.underlineStyle = .single
        }
    }

    private func feed(_ scalars: [UnicodeScalar]) {
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let value = scalar.value

            if value == 0x1B {
                index = handleEscapeSequence(in: scalars, from: index)
                continue
            }
            if value == 0x9B {
                index = handleCSISequence(in: scalars, from: index + 1)
                continue
            }
            if value == 0x9D {
                index = skipOSCSequence(in: scalars, from: index + 1)
                continue
            }
            if let next = skipOrphanCSIFragmentIfPresent(in: scalars, from: index) {
                index = next
                continue
            }
            if value == 0x08 {
                column = max(0, column - 1)
                index += 1
                continue
            }
            if value == 0x0D {
                column = 0
                index += 1
                continue
            }
            if value == 0x0A {
                row += 1
                column = 0
                clampCursor()
                index += 1
                continue
            }
            if value == 0x09 {
                let spaces = max(1, 4 - (column % 4))
                for _ in 0..<spaces {
                    put(" ")
                }
                index += 1
                continue
            }
            if value >= 0x20 {
                put(scalar)
            }
            index += 1
        }
    }

    private func put(_ scalar: UnicodeScalar) {
        clampCursor()
        rows[row][column] = StyledCell(scalar: scalar, style: currentStyle)
        column += 1
        if column >= width {
            column = 0
            row += 1
            clampCursor()
        }
    }

    private func clampCursor() {
        row = max(0, row)
        column = max(0, min(column, width - 1))
        while rows.count <= row {
            rows.append(Self.blankRow(width: width))
        }
        while rows.count > maxRows {
            rows.removeFirst()
            row = max(0, row - 1)
        }
    }

    private func handleEscapeSequence(in scalars: [UnicodeScalar], from start: Int) -> Int {
        let index = start + 1
        guard index < scalars.count else { return index }
        let introducer = scalars[index].value
        if introducer == 0x5B {
            return handleCSISequence(in: scalars, from: index + 1)
        }
        if introducer == 0x5D {
            return skipOSCSequence(in: scalars, from: index + 1)
        }
        if introducer == 0x37 { // ESC 7 — DECSC, save cursor + style
            saveCursor()
            return index + 1
        }
        if introducer == 0x38 { // ESC 8 — DECRC, restore cursor + style
            restoreCursor()
            return index + 1
        }
        return min(index + 1, scalars.count)
    }

    private func saveCursor() {
        savedRow = row
        savedColumn = column
        savedStyle = currentStyle
    }

    private func restoreCursor() {
        row = savedRow
        column = savedColumn
        currentStyle = savedStyle
        clampCursor()
    }

    private func clearScreen() {
        rows = [Self.blankRow(width: width)]
        row = 0
        column = 0
    }

    /// Switch the active write target to a fresh alternate screen
    /// buffer. The main scrollback (and its cursor / saved cursor) is
    /// stashed so it can be restored unmodified when the alt screen
    /// exits. While in the alt buffer, every write goes there — and the
    /// rendered output exposed to the UI ignores it.
    private func enterAltScreen() {
        if inAltScreen { return }
        altBackup = AltBackup(
            rows: rows,
            row: row,
            column: column,
            style: currentStyle,
            savedRow: savedRow,
            savedColumn: savedColumn,
            savedStyle: savedStyle
        )
        inAltScreen = true
        rows = [Self.blankRow(width: width)]
        row = 0
        column = 0
        currentStyle = .plain
        savedRow = 0
        savedColumn = 0
        savedStyle = .plain
    }

    private func exitAltScreen() {
        if !inAltScreen { return }
        inAltScreen = false
        if let backup = altBackup {
            rows = backup.rows
            row = backup.row
            column = backup.column
            currentStyle = backup.style
            savedRow = backup.savedRow
            savedColumn = backup.savedColumn
            savedStyle = backup.savedStyle
        }
        altBackup = nil
    }

    private func skipOSCSequence(in scalars: [UnicodeScalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x07 { return index + 1 }
            if value == 0x1B, index + 1 < scalars.count, scalars[index + 1].value == 0x5C {
                return index + 2
            }
            index += 1
        }
        return index
    }

    private func skipOrphanCSIFragmentIfPresent(in scalars: [UnicodeScalar], from start: Int) -> Int? {
        guard start < scalars.count else { return nil }
        let first = scalars[start].value
        guard first == 0x3B || first == 0x3F || first == 0x5B else { return nil }

        var index = start
        if first == 0x5B { index += 1 }

        let scanLimit = min(index + 20, scalars.count)
        while index < scanLimit {
            let value = scalars[index].value
            if value >= 0x30, value <= 0x39
                || value == 0x3B
                || value == 0x3F
                || value == 0x3D
                || value == 0x3E
                || value == 0x3C {
                index += 1
                continue
            }
            if isCSIControlFinal(value) {
                return index + 1
            }
            return nil
        }
        return nil
    }

    private func isCSIControlFinal(_ value: UInt32) -> Bool {
        switch value {
        case 0x41, 0x42, 0x43, 0x44, 0x47, 0x48, 0x4A, 0x4B, 0x66, 0x68, 0x6C, 0x6D:
            return true
        default:
            return false
        }
    }

    private func handleCSISequence(in scalars: [UnicodeScalar], from start: Int) -> Int {
        var index = start
        var raw = ""
        while index < scalars.count {
            let value = scalars[index].value
            if value >= 0x40, value <= 0x7E {
                applyCSI(raw, final: Character(UnicodeScalar(value)!))
                index += 1
                return index
            }
            raw.unicodeScalars.append(scalars[index])
            index += 1
        }
        return index
    }

    private func applyCSI(_ raw: String, final: Character) {
        let isPrivate = raw.hasPrefix("?")
        let params = parseCSIParams(raw)
        let amount = max(1, params.first ?? 1)

        if isPrivate, final == "h" || final == "l" {
            applyPrivateMode(params: params, set: final == "h")
            clampCursor()
            return
        }

        switch final {
        case "A": row -= amount
        case "B": row += amount
        case "C": column += amount
        case "D": column -= amount
        case "G": column = max(0, amount - 1)
        case "H", "f":
            row = max(0, (params.first ?? 1) - 1)
            column = max(0, (params.dropFirst().first ?? 1) - 1)
        case "J": eraseDisplay(mode: params.first ?? 0)
        case "K": eraseLine(mode: params.first ?? 0)
        case "L": insertLines(amount)
        case "M": deleteLines(amount)
        case "s": saveCursor()
        case "u": restoreCursor()
        case "m": applySGR(params)
        default: break
        }
        clampCursor()
    }

    /// DEC private modes. The ones that matter for Claude Code:
    ///   1049 / 1047 / 47 — alternate screen buffer enter (h) / exit (l).
    ///                       We don't keep two grids; we just blank the
    ///                       screen on both transitions so frames don't
    ///                       layer on top of each other.
    ///   1048             — save/restore cursor (paired with 1049).
    ///   25               — show/hide cursor (we don't render a cursor).
    private func applyPrivateMode(params: [Int], set: Bool) {
        for code in params {
            switch code {
            case 47, 1047, 1049:
                if set { enterAltScreen() } else { exitAltScreen() }
            case 1048:
                if set { saveCursor() } else { restoreCursor() }
            default:
                break
            }
        }
    }

    private func insertLines(_ count: Int) {
        clampCursor()
        for _ in 0..<count {
            rows.insert(Self.blankRow(width: width), at: row)
        }
        if rows.count > maxRows {
            rows.removeLast(rows.count - maxRows)
        }
    }

    private func deleteLines(_ count: Int) {
        clampCursor()
        let n = min(count, rows.count - row)
        guard n > 0 else { return }
        rows.removeSubrange(row..<(row + n))
        while rows.count < row + 1 {
            rows.append(Self.blankRow(width: width))
        }
    }

    /// Walk SGR params and update `currentStyle`. Handles 16-color,
    /// 256-color (`38;5;n` / `48;5;n`), and truecolor (`38;2;r;g;b` /
    /// `48;2;r;g;b`). An empty parameter list resets, per spec.
    private func applySGR(_ params: [Int]) {
        if params.isEmpty {
            currentStyle.reset()
            return
        }
        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0: currentStyle.reset()
            case 1: currentStyle.bold = true
            case 2: currentStyle.dim = true
            case 3: currentStyle.italic = true
            case 4: currentStyle.underline = true
            case 7: currentStyle.inverse = true
            case 22:
                currentStyle.bold = false
                currentStyle.dim = false
            case 23: currentStyle.italic = false
            case 24: currentStyle.underline = false
            case 27: currentStyle.inverse = false
            case 30...37: currentStyle.fg = .named(code - 30)
            case 38:
                if i + 1 < params.count, params[i + 1] == 5, i + 2 < params.count {
                    currentStyle.fg = .indexed(params[i + 2])
                    i += 2
                } else if i + 1 < params.count, params[i + 1] == 2, i + 4 < params.count {
                    currentStyle.fg = .rgb(
                        UInt8(clamping: params[i + 2]),
                        UInt8(clamping: params[i + 3]),
                        UInt8(clamping: params[i + 4])
                    )
                    i += 4
                }
            case 39: currentStyle.fg = .default
            case 40...47: currentStyle.bg = .named(code - 40)
            case 48:
                if i + 1 < params.count, params[i + 1] == 5, i + 2 < params.count {
                    currentStyle.bg = .indexed(params[i + 2])
                    i += 2
                } else if i + 1 < params.count, params[i + 1] == 2, i + 4 < params.count {
                    currentStyle.bg = .rgb(
                        UInt8(clamping: params[i + 2]),
                        UInt8(clamping: params[i + 3]),
                        UInt8(clamping: params[i + 4])
                    )
                    i += 4
                }
            case 49: currentStyle.bg = .default
            case 90...97: currentStyle.fg = .named(code - 90 + 8)
            case 100...107: currentStyle.bg = .named(code - 100 + 8)
            default: break
            }
            i += 1
        }
    }

    private func eraseDisplay(mode: Int) {
        clampCursor()
        switch mode {
        case 2, 3:
            rows = [Self.blankRow(width: width)]
            row = 0
            column = 0
        case 1:
            for y in 0...row {
                let end = y == row ? column : width - 1
                guard end >= 0 else { continue }
                for x in 0...end {
                    rows[y][x] = StyledCell.blank
                }
            }
        default:
            for y in row..<rows.count {
                let start = y == row ? column : 0
                guard start < width else { continue }
                for x in start..<width {
                    rows[y][x] = StyledCell.blank
                }
            }
        }
    }

    private func eraseLine(mode: Int) {
        clampCursor()
        switch mode {
        case 1:
            for x in 0...column {
                rows[row][x] = StyledCell.blank
            }
        case 2:
            rows[row] = Self.blankRow(width: width)
        default:
            for x in column..<width {
                rows[row][x] = StyledCell.blank
            }
        }
    }

    private func parseCSIParams(_ raw: String) -> [Int] {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "?=><"))
        if cleaned.isEmpty { return [] }
        return cleaned.split(separator: ";", omittingEmptySubsequences: false).map {
            Int($0) ?? 0
        }
    }

    private static func blankRow(width: Int) -> [StyledCell] {
        Array(repeating: StyledCell.blank, count: width)
    }

    private func trimTrailingBlanks(_ row: [StyledCell]) -> [StyledCell] {
        var end = row.count
        while end > 0, row[end - 1].scalar == " ", row[end - 1].style == .plain {
            end -= 1
        }
        return Array(row[0..<end])
    }
}

private func trimTrailingSpaces(_ line: String) -> String {
    var line = line
    while line.last == " " || line.last == "\t" {
        line.removeLast()
    }
    return line
}

/// Palette colors that the renderer needs to reach. Mirrors the values in
/// ContentView's private Palette enum.
private enum Palette {
    static let transcriptBackground = Color(red: 0.10, green: 0.10, blue: 0.11)
}
