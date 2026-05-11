import Foundation

/// What surface the keyboard should present right now. Fused from the
/// transcript-based AppDetector + OSC-0 TitleClassifier.
enum KeyboardMode: Equatable {
    /// Claude is busy. The only useful action is interrupt.
    case generating(label: String)

    /// Claude is showing a numbered list of options. We replicate them as
    /// full-width tappable rows.
    case choose(options: [String])

    /// Claude is asking a yes/no question.
    case confirm

    /// Claude is at its idle prompt — show a composer.
    case idle(latest: String?)

    /// Raw shell (no fancy TUI detected) — show terminal-style chips.
    case rawShell

    /// We don't have a connected session yet.
    case disconnected
}

enum KeyboardModeResolver {
    /// Pick a single KeyboardMode from the transcript-based detection
    /// and the most recent OSC-0 title. The detector's awaitingChoice /
    /// awaitingYesNo signals are authoritative because they come from
    /// the actual prompt on screen; the title is used to distinguish
    /// "generating" from "idle" and to refine the app classification.
    /// Time we'll trust a "generating" title for before treating Claude
    /// as idle. Claude refreshes its OSC 0 title roughly every second
    /// while working; if we've gone this long without one, the agent has
    /// almost certainly gone quiet.
    static let staleTitleThreshold: TimeInterval = 2.5

    static func resolve(
        detection: DetectionResult,
        effectiveApp: DetectedApp,
        latestTitle: TitleEvent?,
        isStreamConnected: Bool,
        quietSeconds: TimeInterval?
    ) -> KeyboardMode {
        guard isStreamConnected else { return .disconnected }

        if !effectiveApp.isFancy {
            return .rawShell
        }

        // Explicit menus from the transcript always win — Claude is
        // waiting on a specific answer.
        switch detection.activity {
        case .awaitingChoice(let options):
            return .choose(options: options)
        case .awaitingYesNo:
            return .confirm
        default:
            break
        }

        // Fresh OSC 0 title with a "working" classification is the most
        // reliable "agent is busy" signal. Claude keeps re-emitting its
        // status title every ~1s while generating; in steady state on a
        // prompt, titles stop changing. This beats transcript heuristics
        // which can be fooled by a `>` cursor still being on screen
        // while output continues to stream in below it.
        let titleIsFresh = (quietSeconds ?? .greatestFiniteMagnitude) <= staleTitleThreshold
        if titleIsFresh, let kind = latestTitle?.kind {
            switch kind {
            case .generating, .working:
                return .generating(label: latestTitle?.display ?? "Working")
            case .ready, .unknown:
                break
            }
        }

        return .idle(latest: latestTitle?.display)
    }
}

/// Combine the transcript-based detector with OSC-0 title evidence.
/// Heavy title traffic with Claude-typical phrasing is enough evidence
/// to call this a Claude Code session even when the prompt block isn't
/// currently on screen.
enum EffectiveAppResolver {
    static func resolve(detection: DetectedApp, titles: [TitleEvent]) -> DetectedApp {
        if detection != .rawShell { return detection }
        guard !titles.isEmpty else { return detection }
        let recent = titles.suffix(40)
        let generatingCount = recent.filter { $0.kind == .generating }.count
        let combined = recent.map { $0.display.lowercased() }.joined(separator: "\n")
        let claudeMarkers = [
            "tokens", "claude", "thinking", "cogitating", "generating",
            "sautéed", "sauteed", "brewing", "noodling", "esc to interrupt"
        ]
        let hits = claudeMarkers.reduce(0) { acc, m in
            acc + (combined.contains(m) ? 1 : 0)
        }
        if generatingCount >= 2 || hits >= 1 {
            return .claudeCode
        }
        return detection
    }
}
