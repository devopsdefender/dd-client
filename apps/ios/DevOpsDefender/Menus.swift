import Foundation

/// A single entry in the slash-command palette. Mirrors what Claude Code
/// itself exposes via `/`.
struct SlashCommand: Identifiable, Hashable {
    let name: String
    let summary: String
    /// True if the command takes an argument and should land in the
    /// composer ("/save <name>") rather than firing immediately.
    let takesArgument: Bool

    var id: String { name }
}

enum SlashCatalog {
    /// Curated to match Claude Code's documented commands. Order roughly
    /// reflects how often they get used.
    static let all: [SlashCommand] = [
        .init(name: "/help", summary: "Show available commands", takesArgument: false),
        .init(name: "/clear", summary: "Clear conversation history", takesArgument: false),
        .init(name: "/compact", summary: "Summarize and compress context", takesArgument: false),
        .init(name: "/cost", summary: "Show session token + cost usage", takesArgument: false),
        .init(name: "/model", summary: "Switch the active model", takesArgument: true),
        .init(name: "/permissions", summary: "Edit tool permissions", takesArgument: false),
        .init(name: "/agents", summary: "Pick a subagent for this turn", takesArgument: false),
        .init(name: "/mcp", summary: "Manage MCP server connections", takesArgument: false),
        .init(name: "/resume", summary: "Resume a previous session", takesArgument: true),
        .init(name: "/save", summary: "Save the current session", takesArgument: true),
        .init(name: "/init", summary: "Bootstrap CLAUDE.md for this repo", takesArgument: false),
        .init(name: "/review", summary: "Review a PR", takesArgument: true),
        .init(name: "/exit", summary: "Exit Claude Code", takesArgument: false)
    ]

    static func filtered(by query: String) -> [SlashCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { cmd in
            cmd.name.lowercased().contains(q) || cmd.summary.lowercased().contains(q)
        }
    }
}

/// Claude Code modes. Cycling order matches Shift+Tab.
enum ClaudeMode: String, CaseIterable, Identifiable {
    case normal
    case plan
    case autoAccept

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .plan: return "Plan"
        case .autoAccept: return "Auto-accept"
        }
    }

    var subtitle: String {
        switch self {
        case .normal: return "Confirm each action"
        case .plan: return "Propose a plan first, no edits"
        case .autoAccept: return "Auto-approve safe edits"
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "person.fill.questionmark"
        case .plan: return "list.bullet.rectangle"
        case .autoAccept: return "bolt.circle.fill"
        }
    }
}
