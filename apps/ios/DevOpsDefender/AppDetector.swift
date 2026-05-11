import Foundation

enum DetectedApp: Equatable {
    case claudeCode
    case codex
    case openClaw
    case rawShell

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openClaw: return "OpenClaw"
        case .rawShell: return "Shell"
        }
    }

    var isFancy: Bool {
        switch self {
        case .claudeCode, .codex, .openClaw: return true
        case .rawShell: return false
        }
    }
}

enum DetectedActivity: Equatable {
    case idle
    case running
    case awaitingYesNo
    case awaitingChoice(options: [String])
    case awaitingInput

    var summary: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .awaitingYesNo: return "Needs y/n"
        case .awaitingChoice(let options):
            return "Needs choice (\(options.count))"
        case .awaitingInput: return "Awaiting input"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .idle, .running: return false
        case .awaitingYesNo, .awaitingChoice, .awaitingInput: return true
        }
    }
}

struct DetectionResult: Equatable {
    var app: DetectedApp
    var activity: DetectedActivity

    static let empty = DetectionResult(app: .rawShell, activity: .idle)
}

enum AppDetector {
    /// Inspect the rendered transcript and infer which agent is running plus
    /// what (if anything) it is currently waiting on.
    static func detect(transcript: String) -> DetectionResult {
        let lines = transcript
            .components(separatedBy: CharacterSet.newlines)
            .map { line -> String in
                line.trimmingCharacters(in: .whitespaces)
            }
        let nonEmpty = lines.filter { !$0.isEmpty }
        let tail = Array(nonEmpty.suffix(60))
        let haystack = tail.joined(separator: "\n").lowercased()

        let app: DetectedApp
        if haystack.contains("claude code") || haystack.contains("anthropic") || haystack.contains("bypassing permissions") {
            app = .claudeCode
        } else if haystack.contains("openclaw") {
            app = .openClaw
        } else if haystack.contains("codex") || haystack.contains("openai codex") {
            app = .codex
        } else if looksLikeFancyTui(tail: tail) {
            app = .claudeCode
        } else {
            app = .rawShell
        }

        let activity = detectActivity(tail: tail, app: app)
        return DetectionResult(app: app, activity: activity)
    }

    private static func looksLikeFancyTui(tail: [String]) -> Bool {
        let arrowMarkers = tail.filter { line in
            line.contains("❯") || line.contains("▌") || line.contains("▎")
        }
        return arrowMarkers.count >= 1
    }

    private static func detectActivity(tail: [String], app: DetectedApp) -> DetectedActivity {
        guard !tail.isEmpty else { return .idle }
        let recent = Array(tail.suffix(30))

        if let options = numberedOptions(in: tail), options.count >= 2 {
            return .awaitingChoice(options: options)
        }

        let recentJoined = recent.joined(separator: "\n").lowercased()
        if recentJoined.contains("(y/n)")
            || recentJoined.contains("[y/n]")
            || recentJoined.contains("yes/no")
            || recentJoined.contains("proceed?") {
            return .awaitingYesNo
        }

        if let last = recent.last, endsWithPromptGlyph(last) {
            return app.isFancy ? .awaitingInput : .idle
        }
        if app.isFancy && looksLikeFancyPrompt(in: recent) {
            return .awaitingInput
        }
        if let last = recent.last, endsWithShellPrompt(last) {
            return .idle
        }
        if recentJoined.contains("press enter") || recentJoined.contains("continue?") {
            return .awaitingInput
        }
        return .running
    }

    private static func looksLikeFancyPrompt(in lines: [String]) -> Bool {
        let tail = lines.suffix(8)
        let joined = tail.joined(separator: "\n").lowercased()
        if joined.contains("? for shortcuts") || joined.contains("for shortcuts") {
            return true
        }
        return tail.contains { line in
            let stripped = line.trimmingCharacters(in: .whitespaces)
            return stripped == ">" || stripped == "❯" || stripped == "│ >" || stripped == "│ ❯"
        }
    }

    private static func numberedOptions(in lines: [String]) -> [String]? {
        var bestRun: [(Int, String)] = []
        var current: [(Int, String)] = []
        for line in lines.suffix(60) {
            guard let match = numberedOptionMatch(line) else {
                if current.count > bestRun.count { bestRun = current }
                current.removeAll()
                continue
            }
            if let last = current.last, match.0 != last.0 + 1 {
                if current.count > bestRun.count { bestRun = current }
                current.removeAll()
            }
            current.append(match)
        }
        if current.count > bestRun.count { bestRun = current }
        guard bestRun.count >= 2, bestRun.first?.0 == 1 else { return nil }
        return bestRun.map { $0.1 }
    }

    /// Match lines like "1. label", "─2.─Run …", "  3) label", "▎ 4: label".
    /// Tolerates leading whitespace, box-drawing glyphs, bullets, and the
    /// "─" runs Claude Code uses for option separators.
    private static func numberedOptionMatch(_ line: String) -> (Int, String)? {
        let scalars = Array(line.unicodeScalars)
        var i = 0
        while i < scalars.count, !CharacterSet.decimalDigits.contains(scalars[i]) {
            let value = scalars[i].value
            // Only skip benign prefix glyphs; bail on letters so "abc 1." is rejected.
            let isWhitespace = (value == 0x20 || value == 0x09)
            let isBoxOrSeparator = (value >= 0x2500 && value <= 0x257F)
                || value == 0x2022 // •
                || value == 0x00B7 // ·
                || value == 0x002A // *
                || value == 0x003E // >
                || value == 0x276F // ❯
                || value == 0x258E // ▎
                || value == 0x258C // ▌
                || value == 0x002D // -
                || value == 0x2013 // –
                || value == 0x2014 // —
            guard isWhitespace || isBoxOrSeparator else { return nil }
            i += 1
        }
        guard i < scalars.count else { return nil }

        var digits = ""
        while i < scalars.count, CharacterSet.decimalDigits.contains(scalars[i]) {
            digits.unicodeScalars.append(scalars[i])
            i += 1
        }
        guard let value = Int(digits), value >= 1, value <= 9 else { return nil }

        guard i < scalars.count else { return nil }
        let punct = scalars[i].value
        guard punct == 0x2E || punct == 0x29 || punct == 0x3A else { return nil } // . ) :
        i += 1

        // After the punctuation we expect a separator before the label content.
        // Tolerate runs of whitespace and box-drawing dashes.
        while i < scalars.count {
            let v = scalars[i].value
            let isSep = (v == 0x20 || v == 0x09)
                || (v >= 0x2500 && v <= 0x257F)
                || v == 0x002D || v == 0x2013 || v == 0x2014
            if !isSep { break }
            i += 1
        }

        var rest = ""
        while i < scalars.count {
            rest.unicodeScalars.append(scalars[i])
            i += 1
        }
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (value, label)
    }

    private static func endsWithPromptGlyph(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        return stripped.hasSuffix("❯") || stripped.hasSuffix("▌") || stripped.hasSuffix("▎")
            || stripped.contains("│ >") || stripped.contains("│ ❯")
    }

    private static func endsWithShellPrompt(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        return stripped.hasSuffix("$") || stripped.hasSuffix("#") || stripped.hasSuffix("%") || stripped.hasSuffix(">")
    }
}
