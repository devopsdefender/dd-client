import SwiftUI

/// One ANSI color slot. `default` means "use the terminal's default
/// foreground/background", which lets the renderer pick a theme color
/// rather than baking one in.
enum ANSIColor: Equatable, Hashable {
    case `default`
    /// Named palette index 0–15. 0–7 are the standard CGA colors, 8–15
    /// are the bright variants (selected via SGR 90–97 / 100–107).
    case named(Int)
    /// Indexed xterm 256-color palette entry (0–255).
    case indexed(Int)
    /// 24-bit truecolor (SGR 38;2;r;g;b / 48;2;r;g;b).
    case rgb(UInt8, UInt8, UInt8)

    /// Resolve to a SwiftUI Color against a dark terminal theme. Named
    /// colors are picked to match common terminal palettes (close to
    /// Apple Terminal "Basic" / iTerm2 default) so output looks normal.
    func resolved(default fallback: Color) -> Color {
        switch self {
        case .default:
            return fallback
        case .named(let i):
            return ANSIColor.namedPalette[max(0, min(15, i))]
        case .indexed(let i):
            return ANSIColor.indexedColor(i)
        case .rgb(let r, let g, let b):
            return Color(
                red: Double(r) / 255.0,
                green: Double(g) / 255.0,
                blue: Double(b) / 255.0
            )
        }
    }

    // MARK: - Palette

    private static let namedPalette: [Color] = [
        Color(red: 0.00, green: 0.00, blue: 0.00), // 0  black
        Color(red: 0.80, green: 0.18, blue: 0.18), // 1  red
        Color(red: 0.30, green: 0.69, blue: 0.31), // 2  green
        Color(red: 0.83, green: 0.68, blue: 0.21), // 3  yellow
        Color(red: 0.30, green: 0.55, blue: 0.86), // 4  blue
        Color(red: 0.77, green: 0.33, blue: 0.79), // 5  magenta
        Color(red: 0.31, green: 0.73, blue: 0.76), // 6  cyan
        Color(red: 0.85, green: 0.85, blue: 0.85), // 7  white (light gray)
        Color(red: 0.50, green: 0.50, blue: 0.50), // 8  bright black (gray)
        Color(red: 0.95, green: 0.36, blue: 0.36), // 9  bright red
        Color(red: 0.55, green: 0.89, blue: 0.47), // 10 bright green
        Color(red: 0.98, green: 0.84, blue: 0.36), // 11 bright yellow
        Color(red: 0.51, green: 0.72, blue: 0.99), // 12 bright blue
        Color(red: 0.93, green: 0.54, blue: 0.96), // 13 bright magenta
        Color(red: 0.51, green: 0.93, blue: 0.95), // 14 bright cyan
        Color(red: 1.00, green: 1.00, blue: 1.00)  // 15 bright white
    ]

    private static func indexedColor(_ i: Int) -> Color {
        let i = max(0, min(255, i))
        if i < 16 {
            return namedPalette[i]
        }
        if i < 232 {
            // 6×6×6 color cube: index 16 + 36r + 6g + b
            let n = i - 16
            let r = (n / 36) % 6
            let g = (n / 6) % 6
            let b = n % 6
            let steps: [Double] = [0.0, 0.37, 0.53, 0.69, 0.84, 1.0]
            return Color(red: steps[r], green: steps[g], blue: steps[b])
        }
        // 232–255: 24-step grayscale ramp
        let step = Double(i - 232)
        let value = (step * 10.0 + 8.0) / 255.0
        return Color(red: value, green: value, blue: value)
    }
}

/// Visual attributes for a single terminal cell.
struct CellStyle: Equatable {
    var fg: ANSIColor = .default
    var bg: ANSIColor = .default
    var bold: Bool = false
    var dim: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var inverse: Bool = false

    static let plain = CellStyle()

    mutating func reset() {
        self = .plain
    }
}

/// One cell on the terminal screen — a printable scalar plus its visual
/// style at the moment it was written.
struct StyledCell: Equatable {
    var scalar: UnicodeScalar
    var style: CellStyle

    static let blank = StyledCell(scalar: " ", style: .plain)
}
