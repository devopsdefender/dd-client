import Foundation
import UserNotifications

struct AgentSettings: Sendable {
    var agentURL: String
    var keyPath: String
    var insecureSkipQuoteVerify: Bool
    var itaAPIKey: String
    var itaBaseURL: String
    var itaJwksURL: String
    var itaIssuer: String
}

struct RecipeSummary: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
}

struct SessionSummary: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
}

struct DDClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum DDClientBridge {
    static func importKey(keyPath: String, keyContent: String) throws -> [String: Any] {
        try request([
            "operation": "import_key",
            "key_path": keyPath,
            "key_content": keyContent
        ])
    }

    static func listRecipes(settings: AgentSettings) throws -> [String: Any] {
        try request(basePayload("recipes", settings: settings))
    }

    static func listSessions(settings: AgentSettings) throws -> [String: Any] {
        try request(basePayload("sessions", settings: settings))
    }

    static func createShellSession(settings: AgentSettings) throws -> [String: Any] {
        var payload = basePayload("create_session", settings: settings)
        payload["recipe"] = "shell"
        payload["name"] = "iOS shell"
        return try request(payload)
    }

    static func replaySession(id: String, settings: AgentSettings) throws -> [String: Any] {
        var payload = basePayload("replay_session", settings: settings)
        payload["id"] = id
        return try request(payload)
    }

    static func attachExchange(
        id: String,
        input: String,
        maxBytes: Int,
        idleTimeoutMS: Int,
        settings: AgentSettings
    ) throws -> [String: Any] {
        var payload = basePayload("attach_exchange", settings: settings)
        payload["id"] = id
        payload["input"] = input
        payload["max_bytes"] = maxBytes
        payload["idle_timeout_ms"] = idleTimeoutMS
        return try request(payload)
    }

    private static func basePayload(_ operation: String, settings: AgentSettings) -> [String: Any] {
        [
            "operation": operation,
            "agent_url": settings.agentURL,
            "key_path": settings.keyPath,
            "insecure_skip_quote_verify": settings.insecureSkipQuoteVerify,
            "ita_api_key": settings.itaAPIKey,
            "ita_base_url": settings.itaBaseURL,
            "ita_jwks_url": settings.itaJwksURL,
            "ita_issuer": settings.itaIssuer
        ]
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
    static let previewAgentURL = "https://dd-pr-261-api-23bf4739-7737-483f-9256-1d184cbb7fab.devopsdefender.com"
    static let itaBaseURL = "https://api.trustauthority.intel.com"
    static let itaJwksURL = "https://portal.trustauthority.intel.com/certs"
    static let itaIssuer = "https://portal.trustauthority.intel.com"

    static var defaultKeyPath: String {
        #if targetEnvironment(simulator)
        return hostNoiseKeyPath
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return hostNoiseKeyPath
        }
        return appSupportNoiseKeyPath
        #endif
    }

    static var appSupportNoiseKeyPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("devopsdefender", isDirectory: true)
            .appendingPathComponent("noise.key")
            .path
    }

    private static var hostNoiseKeyPath: String {
        let userName = NSUserName()
        if userName.isEmpty {
            return appSupportNoiseKeyPath
        }
        return "/Users/\(userName)/.config/devopsdefender/noise.key"
    }
}

@MainActor
final class ClientViewModel: ObservableObject {
    @Published var agentURL = AppDefaults.previewAgentURL
    @Published var keyPath = AppDefaults.defaultKeyPath
    @Published var keyContent = ""
    @Published var insecureSkipQuoteVerify = true
    @Published var itaAPIKey = ""
    @Published var itaBaseURL = AppDefaults.itaBaseURL
    @Published var itaJwksURL = AppDefaults.itaJwksURL
    @Published var itaIssuer = AppDefaults.itaIssuer
    @Published var recipes: [RecipeSummary] = []
    @Published var sessions: [SessionSummary] = []
    @Published var selectedSessionID = ""
    @Published var quickInput = ""
    @Published var transcript = ""
    @Published var rawResponse = ""
    @Published var status = "Ready"
    @Published var isBusy = false
    @Published var transcriptFontSize = 15.0
    @Published var notifyOnSessionChanges = false {
        didSet {
            if notifyOnSessionChanges {
                requestNotificationPermission()
            }
        }
    }

    private var lastSessionIDs = Set<String>()

    var settings: AgentSettings {
        AgentSettings(
            agentURL: agentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPath: keyPath.expandingTildePath,
            insecureSkipQuoteVerify: insecureSkipQuoteVerify,
            itaAPIKey: itaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            itaBaseURL: itaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            itaJwksURL: itaJwksURL.trimmingCharacters(in: .whitespacesAndNewlines),
            itaIssuer: itaIssuer.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func useAppSupportKeyPath() {
        keyPath = AppDefaults.appSupportNoiseKeyPath
    }

    func importPastedKey() {
        let path = keyPath.expandingTildePath
        let content = keyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            status = "Paste a 32-byte key as hex or base64 first"
            return
        }
        run("Importing key") {
            let response = try DDClientBridge.importKey(keyPath: path, keyContent: content)
            return ClientUpdate(
                status: "Imported key to \(response["key_path"] as? String ?? path)",
                rawResponse: prettyJSONString(response)
            )
        }
    }

    func loadRecipes() {
        let settings = settings
        run("Loading recipes") {
            let response = try DDClientBridge.listRecipes(settings: settings)
            return ClientUpdate(
                status: "Loaded recipes",
                recipes: extractRecipes(from: response["value"]),
                rawResponse: prettyJSONString(response)
            )
        }
    }

    func loadSessions() {
        let settings = settings
        run("Loading sessions") {
            let response = try DDClientBridge.listSessions(settings: settings)
            let sessions = extractSessions(from: response["value"])
            return ClientUpdate(
                status: "Loaded \(sessions.count) sessions",
                sessions: sessions,
                rawResponse: prettyJSONString(response)
            )
        }
    }

    func createShellSession() {
        let settings = settings
        run("Creating shell session") {
            let response = try DDClientBridge.createShellSession(settings: settings)
            let id = response["session_id"] as? String ?? ""
            return ClientUpdate(
                status: id.isEmpty ? "Created shell session" : "Created shell session \(id)",
                selectedSessionID: id,
                rawResponse: prettyJSONString(response)
            )
        }
    }

    func replaySelectedSession() {
        let id = selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            status = "Select or enter a session id first"
            return
        }
        let settings = settings
        run("Replaying session") {
            let response = try DDClientBridge.replaySession(id: id, settings: settings)
            return ClientUpdate(
                status: "Replayed \(id)",
                transcript: transcriptText(from: response["value"]),
                rawResponse: prettyJSONString(response)
            )
        }
    }

    func attachSelectedSession() {
        attach(input: "", statusText: "Attaching for output")
    }

    func sendQuickInput(_ input: String? = nil) {
        let text = input ?? quickInput
        guard !text.isEmpty else {
            status = "Enter text or use a quick key"
            return
        }
        let normalized = text.hasSuffix("\n") ? text : text + "\n"
        attach(input: normalized, statusText: "Sending short input")
        if input == nil {
            quickInput = ""
        }
    }

    func selectSession(_ session: SessionSummary) {
        selectedSessionID = session.id
        transcript = session.detail
    }

    private func attach(input: String, statusText: String) {
        let id = selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            status = "Select or enter a session id first"
            return
        }
        let settings = settings
        run(statusText) {
            let response = try DDClientBridge.attachExchange(
                id: id,
                input: input,
                maxBytes: 128 * 1024,
                idleTimeoutMS: 1200,
                settings: settings
            )
            let text = response["text"] as? String ?? ""
            return ClientUpdate(
                status: input.isEmpty ? "Attached and detached without closing \(id)" : "Sent input and detached without closing \(id)",
                transcript: text.isEmpty ? "(no new output before idle timeout)" : text,
                rawResponse: prettyJSONString(response)
            )
        }
    }

    private func run(_ pendingStatus: String, work: @escaping @Sendable () throws -> ClientUpdate) {
        guard !isBusy else {
            status = "Another request is already running"
            return
        }
        isBusy = true
        status = pendingStatus
        Task {
            do {
                let update = try await Task.detached(priority: .userInitiated) {
                    try work()
                }.value
                apply(update)
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func apply(_ update: ClientUpdate) {
        status = update.status
        rawResponse = update.rawResponse ?? rawResponse
        if let recipes = update.recipes {
            self.recipes = recipes
        }
        if let sessions = update.sessions {
            handleSessionUpdate(sessions)
        }
        if let selectedSessionID = update.selectedSessionID, !selectedSessionID.isEmpty {
            self.selectedSessionID = selectedSessionID
        }
        if let transcript = update.transcript {
            self.transcript = transcript
        }
    }

    private func handleSessionUpdate(_ sessions: [SessionSummary]) {
        let newIDs = Set(sessions.map(\.id))
        let added = newIDs.subtracting(lastSessionIDs)
        self.sessions = sessions
        if notifyOnSessionChanges, !lastSessionIDs.isEmpty, !added.isEmpty {
            scheduleNotification(title: "DevOps Defender sessions changed", body: "New sessions: \(added.sorted().joined(separator: ", "))")
        }
        lastSessionIDs = newIDs
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "dd-client-session-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

private struct ClientUpdate: Sendable {
    var status: String
    var recipes: [RecipeSummary]?
    var sessions: [SessionSummary]?
    var selectedSessionID: String?
    var transcript: String?
    var rawResponse: String?
}

private extension String {
    var expandingTildePath: String {
        (self as NSString).expandingTildeInPath
    }
}

private func prettyJSONString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return "\(value)"
    }
    return text
}

private func transcriptText(from value: Any?) -> String {
    if let text = firstString(for: ["transcript", "output", "text", "stdout", "data"], in: value) {
        return text
    }
    return prettyJSONString(value ?? [:])
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

private func extractRecipes(from value: Any?) -> [RecipeSummary] {
    extractDictionaries(from: value).compactMap { dict in
        guard let id = stringValue(dict["id"]) ?? stringValue(dict["recipe_id"]) ?? stringValue(dict["name"]) else {
            return nil
        }
        let title = stringValue(dict["name"]) ?? id
        let detail = [stringValue(dict["description"]), stringValue(dict["command"])]
            .compactMap { $0 }
            .joined(separator: " ")
        return RecipeSummary(id: id, title: title, detail: detail)
    }
}

private func extractSessions(from value: Any?) -> [SessionSummary] {
    extractDictionaries(from: value).compactMap { dict in
        guard let id = stringValue(dict["id"]) ?? stringValue(dict["session_id"]) else {
            return nil
        }
        let title = stringValue(dict["name"]) ?? stringValue(dict["recipe_id"]) ?? "Session"
        let detail = [
            stringValue(dict["status"]),
            stringValue(dict["state"]),
            stringValue(dict["recipe"]),
            stringValue(dict["recipe_id"]),
            stringValue(dict["created_at"]),
            stringValue(dict["updated_at"])
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        return SessionSummary(id: id, title: title, detail: detail)
    }
}

private func extractDictionaries(from value: Any?) -> [[String: Any]] {
    if let dict = value as? [String: Any] {
        var result = [dict]
        for nested in dict.values {
            result.append(contentsOf: extractDictionaries(from: nested))
        }
        return result
    }
    if let array = value as? [Any] {
        return array.flatMap { extractDictionaries(from: $0) }
    }
    return []
}

private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String where !value.isEmpty:
        return value
    case let value as NSNumber:
        return value.stringValue
    default:
        return nil
    }
}
