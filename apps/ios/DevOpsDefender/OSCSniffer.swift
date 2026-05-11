import Foundation

/// One captured terminal "notification-class" event. We keep the schema
/// deliberately raw for the observation pass: enough to see what arrives,
/// not yet a typed Claude Code event.
struct OSCEvent: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case osc
        case bell
    }

    let id: UUID
    let kind: Kind
    /// For `.osc`, the payload between `ESC ]` and the terminator (BEL or ST),
    /// not including either delimiter. For `.bell`, the empty string.
    let raw: String
    let at: Date
    let byteOffset: Int

    init(kind: Kind, raw: String, at: Date = Date(), byteOffset: Int) {
        self.id = UUID()
        self.kind = kind
        self.raw = raw
        self.at = at
        self.byteOffset = byteOffset
    }

    /// Parsed `Ps` (OSC command number) when the payload starts with digits
    /// followed by a semicolon. Returns nil for malformed OSC or bell.
    var oscPs: Int? {
        guard kind == .osc else { return nil }
        var digits = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                digits.unicodeScalars.append(scalar)
                continue
            }
            break
        }
        return Int(digits)
    }
}

/// Streaming parser that watches a PTY byte stream and emits OSC + bell
/// notifications. Stateful so it can be fed in chunks: a sequence that
/// spans two `feed(_:)` calls is still parsed correctly.
///
/// Recognizes the standard openings:
///   - 7-bit `ESC ]` (0x1B 0x5D) ... `BEL` (0x07) or `ESC \` (ST)
///   - 8-bit `OSC`  (0x9D) ... `BEL` or `0x9C` (ST)
///
/// Bare BEL outside an OSC sequence is captured as a `.bell` event.
final class OSCSniffer {
    private enum State {
        case idle
        case afterEsc
        case inOSC
        case inOSCAfterEsc
    }

    private var state: State = .idle
    private var buffer = String.UnicodeScalarView()
    private var bytesSeen: Int = 0

    private(set) var events: [OSCEvent] = []
    var maxEvents: Int = 500

    func reset() {
        state = .idle
        buffer.removeAll()
        bytesSeen = 0
        events.removeAll()
    }

    func feed(_ scalars: String.UnicodeScalarView) {
        for scalar in scalars {
            consume(scalar)
            bytesSeen += 1
        }
    }

    private func consume(_ scalar: UnicodeScalar) {
        let v = scalar.value
        switch state {
        case .idle:
            if v == 0x1B {
                state = .afterEsc
            } else if v == 0x9D {
                state = .inOSC
                buffer.removeAll()
            } else if v == 0x07 {
                append(.init(kind: .bell, raw: "", byteOffset: bytesSeen))
            }
        case .afterEsc:
            if v == 0x5D {
                state = .inOSC
                buffer.removeAll()
            } else {
                state = .idle
            }
        case .inOSC:
            if v == 0x07 || v == 0x9C {
                flushOSC()
                state = .idle
            } else if v == 0x1B {
                state = .inOSCAfterEsc
            } else {
                buffer.append(scalar)
            }
        case .inOSCAfterEsc:
            if v == 0x5C {
                flushOSC()
                state = .idle
            } else {
                buffer.append(UnicodeScalar(0x1B)!)
                buffer.append(scalar)
                state = .inOSC
            }
        }
    }

    private func flushOSC() {
        let raw = String(buffer)
        buffer.removeAll()
        append(.init(kind: .osc, raw: raw, byteOffset: bytesSeen))
    }

    private func append(_ event: OSCEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }
}
