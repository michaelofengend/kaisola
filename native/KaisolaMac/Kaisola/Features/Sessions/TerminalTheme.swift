import AppKit
import SwiftTerm

/// The terminal palettes, matched to the Electron renderer's xterm themes
/// (src/components/Terminal.tsx DARK_THEME / LIGHT_THEME) so the native
/// surface reads as the same product: ink on a dark appearance, paper on a
/// light one — exactly like Electron's lightSurface switch.
enum TerminalTheme {
    struct Palette {
        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor
        let selection: NSColor
        let ansi: [SwiftTerm.Color]
    }

    /// DARK_THEME (ink). Values from Terminal.tsx / TERM_SURFACE.ink.
    static var dark: Palette {
        Palette(
            background: color(0x0D0F13),
            foreground: color(0xD6DAE2),
            cursor: color(0xD6DAE2),
            selection: color(0x95A456, alpha: 0.25),
            ansi: [
                term(0x14161C), term(0xE16A6A), term(0x54C08A), term(0xD8A44A),
                term(0x5AA9E6), term(0xA88752), term(0x5EC5C0), term(0xC4C8D2),
                term(0x5A5F6B), term(0xE16A6A), term(0x54C08A), term(0xD8A44A),
                term(0x5AA9E6), term(0xA88752), term(0x5EC5C0), term(0xF3F4F6),
            ]
        )
    }

    /// LIGHT_THEME (paper). ANSI black inverts to paper exactly as the
    /// Electron theme does, so TUIs that paint black panels stay readable.
    static var light: Palette {
        Palette(
            background: color(0xE9EBEF),
            foreground: color(0x21242B),
            cursor: color(0x21242B),
            selection: color(0x5E7030, alpha: 0.18),
            ansi: [
                term(0xEEF0F4), term(0xCF4F4F), term(0x2F9E6B), term(0x9A6B1F),
                term(0x2F86C9), term(0x8A713A), term(0x1F8F88), term(0x3B3F48),
                term(0x8B909D), term(0xCF4F4F), term(0x2F9E6B), term(0x9A6B1F),
                term(0x2F86C9), term(0x8A713A), term(0x1F8F88), term(0x16181D),
            ]
        )
    }

    static func palette(light: Bool) -> Palette {
        light ? Self.light : Self.dark
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
