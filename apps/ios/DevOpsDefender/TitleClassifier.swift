import Foundation

/// One OSC-0 title, cleaned for display and classified.
struct TitleEvent: Equatable {
    enum Kind: Equatable {
        case generating
        case working
        case ready
        case unknown
    }

    var raw: String
    /// `raw` with the leading status glyph + whitespace stripped.
    var display: String
    var kind: Kind
    var at: Date
}

/// Stateful classifier that turns the OSC-0 firehose into a deduped
/// sequence of TitleEvents. Consecutive identical titles are coalesced.
///
/// The classifier is called repeatedly with a growing buffer of OSC
/// events, so it tracks the last `byteOffset` it processed and skips
/// anything at or before that. Without this, replays and idle ticks
/// re-process the same events and inflate the timeline.
final class TitleClassifier {
    private(set) var titles: [TitleEvent] = []
    var maxTitles: Int = 200
    private var lastProcessedOffset: Int = -1

    func reset() {
        titles.removeAll()
        lastProcessedOffset = -1
    }

    /// Feed the cumulative captured OSC event buffer. Only events whose
    /// `byteOffset` is past the last seen one are actually classified.
    func feed(_ events: [OSCEvent]) {
        for event in events {
            guard event.byteOffset > lastProcessedOffset else { continue }
            lastProcessedOffset = event.byteOffset
            guard event.kind == .osc else { continue }
            guard let body = oscZeroBody(event.raw) else { continue }
            let display = cleanDisplay(body)
            if display.isEmpty { continue }
            if titles.last?.display == display { continue }
            let kind = classify(display)
            titles.append(TitleEvent(raw: body, display: display, kind: kind, at: event.at))
            if titles.count > maxTitles {
                titles.removeFirst(titles.count - maxTitles)
            }
        }
    }

    var latest: TitleEvent? { titles.last }

    /// Time since the most recent title — used to detect "the agent went
    /// quiet, probably awaiting input."
    func quietSeconds(now: Date = Date()) -> TimeInterval? {
        guard let last = latest else { return nil }
        return now.timeIntervalSince(last.at)
    }

    private func oscZeroBody(_ raw: String) -> String? {
        // OSC 0 payload is `0;<title>`. Some terminals also use `1;` or
        // `2;` for icon name / window title separately — accept all three
        // because they all describe the running app's state.
        for prefix in ["0;", "1;", "2;"] {
            if raw.hasPrefix(prefix) {
                return String(raw.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// Strip Claude Code's leading status glyphs (✻, ●, ⏺, ▌, ▎, dingbats…)
    /// so the display string is just the human-readable label. We strip
    /// any leading whitespace plus characters in the dingbat / geometric /
    /// misc-symbols / arrows blocks — basically "any decorative glyph that
    /// appears before the first letter or digit". Caps the strip so we
    /// don't eat real content.
    private func cleanDisplay(_ body: String) -> String {
        var scalars = Array(body.unicodeScalars)
        var stripped = 0
        while let first = scalars.first, stripped < 8 {
            let v = first.value
            let isWhitespace = v == 0x20 || v == 0x09
            let isLetter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isDigit = v >= 0x30 && v <= 0x39
            if isLetter || isDigit { break }
            let isDecorativeBlock =
                (v >= 0x2190 && v <= 0x21FF)    // Arrows
                || (v >= 0x2200 && v <= 0x22FF) // Math operators (∗ etc.)
                || (v >= 0x2300 && v <= 0x23FF) // Misc technical (⏺ etc.)
                || (v >= 0x2500 && v <= 0x259F) // Box drawing + block elements
                || (v >= 0x25A0 && v <= 0x25FF) // Geometric shapes (●, ▎, etc.)
                || (v >= 0x2600 && v <= 0x26FF) // Misc symbols
                || (v >= 0x2700 && v <= 0x27BF) // Dingbats (✻, ❯, ★, etc.)
                || v == 0x2022                  // •
                || v == 0x00B7                  // ·
                || v == 0x002A                  // *
                || v == 0x002D                  // -
                || v == 0x2013                  // –
                || v == 0x2014                  // —
                || v == 0x003E                  // > (rare prompt glyph)
            if isWhitespace || isDecorativeBlock {
                scalars.removeFirst()
                stripped += 1
                continue
            }
            break
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespaces)
    }

    private func classify(_ text: String) -> TitleEvent.Kind {
        let lower = text.lowercased()
        let workingPhrases = [
            "generating", "cogitating", "thinking", "brewing", "sautéing",
            "sauteed", "sautéed", "considering", "pondering", "noodling",
            "investigating", "exploring", "reading", "scanning", "spinning",
            "running", "executing", "tooling", "fetching", "compiling",
            "writing", "applying", "patching", "diffing", "planning",
            "noodling", "deliberating", "musing"
        ]
        if workingPhrases.contains(where: { lower.contains($0) }) {
            return .generating
        }
        let readyPhrases = ["ready", "awaiting", "done", "complete", "finished"]
        if readyPhrases.contains(where: { lower.contains($0) }) {
            return .ready
        }
        if lower.contains("for ") && lower.range(of: #" for \d+"#, options: .regularExpression) != nil {
            // "Cogitated for 32s" / "Sautéed for 9s" — a verb-past + "for Ns".
            // These appear right after Claude finishes a phase; treat as
            // ".generating" still because more output usually follows. The
            // hint that we're idle comes from the "no new title for N
            // seconds" check, not from any single title.
            return .generating
        }
        return .working
    }
}
