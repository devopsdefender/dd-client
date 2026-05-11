import Foundation

/// One agent the CP says this user has access to. Returned by
/// `GET /api/v1/agents`.
struct AgentSummary: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let label: String
    let agentURL: String
    let lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case agentURL = "agent_url"
        case lastSeenAt = "last_seen_at"
    }
}

/// One shell session on an agent. Returned by `shell.list_sessions`
/// over Noise — we don't strictly know the agent's response schema,
/// so this is best-effort decoding from a flexible JSON shape.
struct SessionSummary: Identifiable, Equatable {
    let id: String
    let name: String?
    let recipe: String?
    let startedAt: Date?

    /// Parse the agent's `list_sessions` response into a typed list.
    /// We accept either `{ sessions: [...] }` or a top-level array, and
    /// individual entries with any of: `id`, `session_id`, `uuid` for the
    /// id field; `name` / `label` for the label; `recipe` / `recipe_id`
    /// for the recipe; `started_at` / `created_at` for the timestamp.
    static func parse(value: Any?) -> [SessionSummary] {
        let array: [[String: Any]] = {
            if let dict = value as? [String: Any], let nested = dict["sessions"] as? [[String: Any]] {
                return nested
            }
            if let array = value as? [[String: Any]] {
                return array
            }
            return []
        }()
        return array.compactMap(parseEntry)
    }

    private static func parseEntry(_ dict: [String: Any]) -> SessionSummary? {
        let id = (dict["id"] as? String)
            ?? (dict["session_id"] as? String)
            ?? (dict["uuid"] as? String)
        guard let id, !id.isEmpty else { return nil }
        let name = (dict["name"] as? String) ?? (dict["label"] as? String)
        let recipe = (dict["recipe"] as? String) ?? (dict["recipe_id"] as? String)
        let timestamp = (dict["started_at"] as? String) ?? (dict["created_at"] as? String)
        let date = timestamp.flatMap(SessionSummary.iso8601.date(from:))
        return SessionSummary(id: id, name: name, recipe: recipe, startedAt: date)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
