import Foundation

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
        _ = try request([
            "operation": "import_key",
            "key_path": keyPath,
            "key_content": keyContent
        ])
    }

    static func transcriptSnapshot(id: String, settings: AgentSettings) throws -> [String: Any] {
        try request([
            "operation": "attach_exchange",
            "agent_url": settings.agentURL,
            "key_path": settings.keyPath,
            "insecure_skip_quote_verify": true,
            "ita_api_key": "",
            "ita_base_url": "",
            "ita_jwks_url": "",
            "ita_issuer": "",
            "id": id,
            "input": "",
            "max_bytes": 131072,
            "idle_timeout_ms": 250
        ])
    }

    static func transcriptHistory(id: String, settings: AgentSettings) throws -> [String: Any] {
        try request([
            "operation": "replay_session",
            "agent_url": settings.agentURL,
            "key_path": settings.keyPath,
            "insecure_skip_quote_verify": true,
            "ita_api_key": "",
            "ita_base_url": "",
            "ita_jwks_url": "",
            "ita_issuer": "",
            "id": id,
            "max_bytes": 49152
        ])
    }

    private static func request(_ payload: [String: Any]) throws -> [String: Any] {
        let requestData = try JSONSerialization.data(withJSONObject: payload)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw DDClientError(message: "Failed to encode FFI request")
        }

        let responsePointer = requestJSON.withCString { requestCString in
            dd_client_agent_request(requestCString)
        }
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

@MainActor
final class ClientViewModel: ObservableObject {
    @Published var selectedSessionID = ""
    @Published var transcript = ""
    @Published var status = "Open a mobile link from desktop"
    @Published var isBusy = false

    private var agentURL = ""
    private var keyPath = AppDefaults.appSupportNoiseKeyPath
    private var refreshTask: Task<Void, Never>?
    private var terminalRenderer = TerminalScreenRenderer(width: 96, maxRows: 160)

    var hasLinkedSession: Bool {
        !selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

        refreshTask?.cancel()
        agentURL = agent
        selectedSessionID = id
        keyPath = AppDefaults.appSupportNoiseKeyPath
        transcript = ""
        terminalRenderer = TerminalScreenRenderer(width: 96, maxRows: 160)

        if let key = query["key"], !key.isEmpty {
            importKeyAndLoadTranscript(key)
            return
        }

        if FileManager.default.fileExists(atPath: keyPath.expandingTildePath) {
            loadTranscript()
        } else {
            status = "Linked \(linkedSessionTitle); link did not include key"
        }
    }

    private func importKeyAndLoadTranscript(_ key: String) {
        let path = keyPath.expandingTildePath
        let id = selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = AgentSettings(
            agentURL: agentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPath: path
        )
        run("Importing key", keepRefreshing: true) {
            try DDClientBridge.importKey(keyPath: path, keyContent: key)
            return initialTranscriptUpdate(id: id, settings: settings)
        }
    }

    private func loadTranscript() {
        let id = selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            status = "No linked session"
            return
        }
        let settings = AgentSettings(
            agentURL: agentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPath: keyPath.expandingTildePath
        )
        run("Loading transcript", keepRefreshing: true) {
            initialTranscriptUpdate(id: id, settings: settings)
        }
    }

    private func run(
        _ pendingStatus: String,
        keepRefreshing: Bool = false,
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
                if keepRefreshing {
                    startRefreshing()
                }
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 650_000_000)
                self?.refreshTranscript()
            }
        }
    }

    private func refreshTranscript() {
        guard hasLinkedSession, !isBusy else {
            return
        }
        let id = selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = AgentSettings(
            agentURL: agentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPath: keyPath.expandingTildePath
        )
        isBusy = true
        Task {
            do {
                let update = try await Task.detached(priority: .utility) {
                    try transcriptUpdate(id: id, settings: settings)
                }.value
                status = update.status
                apply(update)
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func apply(_ update: ClientUpdate) {
        guard !update.terminalText.isEmpty else {
            return
        }
        terminalRenderer.feed(update.terminalText.unicodeScalars)
        let rendered = terminalRenderer.renderedText()
        transcript = rendered.isEmpty ? "(no transcript output before idle timeout)" : rendered
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

private func transcriptUpdate(id: String, settings: AgentSettings) throws -> ClientUpdate {
    let response = try DDClientBridge.transcriptSnapshot(id: id, settings: settings)
    return ClientUpdate(
        status: "Loaded \(id)",
        terminalText: transcriptText(from: response)
    )
}

private func initialTranscriptUpdate(id: String, settings: AgentSettings) -> ClientUpdate {
    if let response = try? DDClientBridge.transcriptHistory(id: id, settings: settings) {
        let history = historyText(from: response)
        if !history.isEmpty {
            return ClientUpdate(status: "Loaded \(id)", terminalText: history)
        }
    }
    return (try? transcriptUpdate(id: id, settings: settings))
        ?? ClientUpdate(status: "Loaded \(id)", terminalText: "")
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

private final class TerminalScreenRenderer {
    private let width: Int
    private let maxRows: Int
    private var rows: [[UnicodeScalar]]
    private var row = 0
    private var column = 0

    init(width: Int, maxRows: Int) {
        self.width = width
        self.maxRows = maxRows
        self.rows = [Self.blankRow(width: width)]
    }

    func feed(_ scalars: String.UnicodeScalarView) {
        feed(Array(scalars))
    }

    func renderedText() -> String {
        rows
            .map { trimTrailingSpaces(String(String.UnicodeScalarView($0))) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        rows[row][column] = scalar
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
        guard index < scalars.count else {
            return index
        }

        let introducer = scalars[index].value
        if introducer == 0x5B {
            return handleCSISequence(in: scalars, from: index + 1)
        }
        if introducer == 0x5D {
            return skipOSCSequence(in: scalars, from: index + 1)
        }

        return min(index + 1, scalars.count)
    }

    private func skipOSCSequence(in scalars: [UnicodeScalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x07 {
                return index + 1
            }
            if value == 0x1B, index + 1 < scalars.count, scalars[index + 1].value == 0x5C {
                return index + 2
        }
            index += 1
        }
        return index
    }

    private func skipOrphanCSIFragmentIfPresent(in scalars: [UnicodeScalar], from start: Int) -> Int? {
        guard start < scalars.count else {
            return nil
        }
        let first = scalars[start].value
        guard first == 0x3B || first == 0x3F || first == 0x5B else {
            return nil
        }

        var index = start
        if first == 0x5B {
            index += 1
        }

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
        let params = parseCSIParams(raw)
        let amount = max(1, params.first ?? 1)

        switch final {
        case "A":
            row -= amount
        case "B":
            row += amount
        case "C":
            column += amount
        case "D":
            column -= amount
        case "G":
            column = max(0, amount - 1)
        case "H", "f":
            row = max(0, (params.first ?? 1) - 1)
            column = max(0, (params.dropFirst().first ?? 1) - 1)
        case "J":
            eraseDisplay(mode: params.first ?? 0)
        case "K":
            eraseLine(mode: params.first ?? 0)
        default:
            break
        }
        clampCursor()
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
                    rows[y][x] = " "
                }
            }
        default:
            for y in row..<rows.count {
                let start = y == row ? column : 0
                guard start < width else { continue }
                for x in start..<width {
                    rows[y][x] = " "
                }
            }
        }
    }

    private func eraseLine(mode: Int) {
        clampCursor()
        switch mode {
        case 1:
            for x in 0...column {
                rows[row][x] = " "
            }
        case 2:
            rows[row] = Self.blankRow(width: width)
        default:
            for x in column..<width {
                rows[row][x] = " "
            }
        }
    }

    private func parseCSIParams(_ raw: String) -> [Int] {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "?=><"))
        if cleaned.isEmpty {
            return []
        }
        return cleaned.split(separator: ";", omittingEmptySubsequences: false).map {
            Int($0) ?? 0
        }
    }

    private static func blankRow(width: Int) -> [UnicodeScalar] {
        Array(repeating: " ", count: width)
    }
}

private func trimTrailingSpaces(_ line: String) -> String {
    var line = line
    while line.last == " " || line.last == "\t" {
        line.removeLast()
    }
    return line
}
