import Foundation

/// Turns the raw title a terminal emits over OSC (SwiftTerm's
/// `setTerminalTitle` delegate) into a sidebar-worthy session name, mirroring
/// the Electron renderer's live auto-naming: a session inherits whatever its
/// shell/agent reports unless the user has taken over the name by hand.
///
/// Pure and self-contained on purpose — every rule here is exercised by
/// `SessionTitleTrackerTests` without a broker, a store, or a live PTY. The
/// AppModel layer decides *whether* to apply (via `shouldApply` +
/// `NativeSessionStore.hasCustomTitle`); this type only decides *what* the
/// title would be.
struct SessionTitleTracker {
    /// Longest title we keep; OSC streams occasionally carry a whole command
    /// line, and the sidebar row can only show a few dozen glyphs anyway.
    static let maxLength = 60

    /// The creation-style separator between an agent name and its subject,
    /// kept byte-identical to `AppModel.createOwnedSession` ("<agent> · <x>")
    /// so an auto-title reads as family with the name assigned at spawn.
    static let separator = " \u{00B7} "

    /// Login/interactive shells whose reported title carries no information
    /// beyond "this is a shell". Compared case-insensitively; the leading-dash
    /// forms are what a login shell reports (`-zsh`, `-bash`, …).
    private static let genericTitles: Set<String> = [
        "zsh", "-zsh",
        "bash", "-bash",
        "sh", "-sh",
        "fish", "-fish",
    ]

    /// The auto-title a raw OSC string should produce for a session, or `nil`
    /// when the raw title is empty, purely generic, or just the folder the
    /// session already lives in (all of which the creation default covers).
    ///
    /// - Parameters:
    ///   - raw: the unsanitized OSC title straight from the terminal.
    ///   - agentName: the display name of the agent this session runs
    ///     (`AgentProfile.name`), or `nil` for a plain shell.
    ///   - folder: the session's working-directory leaf, used both to reject a
    ///     redundant folder-only title and to match the creation default.
    static func autoTitle(fromOSC raw: String, agentName: String?, folder: String) -> String? {
        guard let cleaned = sanitize(raw) else { return nil }
        if isGeneric(cleaned, folder: folder) { return nil }

        guard let agentName = agentName?.trimmingCharacters(in: .whitespaces),
              !agentName.isEmpty else {
            return cleaned
        }
        // An agent CLI that already names itself in the title (e.g. "Claude is
        // reviewing…") shouldn't get "Claude · Claude is reviewing…".
        if cleaned.range(of: agentName, options: .caseInsensitive) != nil {
            return cleaned
        }
        return agentName + separator + cleaned
    }

    /// Whether an `autoTitle` should overwrite the currently-stored title.
    /// False when the user has taken the name over, or when the auto-title is
    /// already exactly what's shown (no churn / no needless `objectWillChange`).
    static func shouldApply(autoTitle: String, currentTitle: String, userRenamed: Bool) -> Bool {
        if userRenamed { return false }
        if autoTitle == currentTitle { return false }
        return true
    }

    // MARK: - Sanitization

    /// Trim, neutralize control characters, and collapse internal whitespace to
    /// single spaces, capped at `maxLength`. Returns `nil` when nothing
    /// printable survives. Control and whitespace scalars both become a single
    /// space *before* collapsing so `"build\tstep"` stays two words rather than
    /// merging into `"buildstep"`.
    static func sanitize(_ raw: String) -> String? {
        var blanks = CharacterSet.controlCharacters
        blanks.formUnion(.whitespacesAndNewlines)

        let space: Unicode.Scalar = " "
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            scalars.append(blanks.contains(scalar) ? space : scalar)
        }

        let collapsed = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLength))
    }

    /// A cleaned title that says nothing the creation default doesn't already:
    /// a bare shell name, or the session's own folder.
    static func isGeneric(_ title: String, folder: String) -> Bool {
        let lowered = title.lowercased()
        if genericTitles.contains(lowered) { return true }
        return lowered == folder.lowercased()
    }
}
