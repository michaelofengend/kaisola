import AppKit
import SwiftTerm

/// The terminal palette, matched to the Electron renderer's xterm theme so the
/// native surface reads as the same product. Kaisola is dark-mode-invariant for
/// terminals (a light desktop still gets an ink terminal), so a single dark
/// palette is authoritative; the surface background follows the "ink" tone.
enum TerminalTheme {
    // Hex values copied from src/components/Terminal.tsx DARK_THEME / TERM_SURFACE.ink.
    static let background = color(0x0D0F13)
    static let foreground = color(0xD6DAE2)
    static let cursor = color(0xD6DAE2)
    static let selection = color(0x95A456, alpha: 0.25)

    /// ANSI 0-15 in SwiftTerm order (black, red, green, yellow, blue, magenta,
    /// cyan, white, then the bright variants). Computed because SwiftTerm's
    /// `Color` is a reference type and not Sendable, so it cannot be a shared
    /// static.
    static var ansiColors: [SwiftTerm.Color] {
        [
            term(0x14161C), term(0xE16A6A), term(0x54C08A), term(0xD8A44A),
            term(0x5AA9E6), term(0xA88752), term(0x5EC5C0), term(0xC4C8D2),
            term(0x5A5F6B), term(0xE16A6A), term(0x54C08A), term(0xD8A44A),
            term(0x5AA9E6), term(0xA88752), term(0x5EC5C0), term(0xF3F4F6),
        ]
    }

    private static func color(_ rgb: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// SwiftTerm's 16-bit-per-channel color.
    private static func term(_ rgb: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((rgb >> 16) & 0xFF) * 257,
            green: UInt16((rgb >> 8) & 0xFF) * 257,
            blue: UInt16(rgb & 0xFF) * 257
        )
    }
}
