import Foundation

/// Live OSC title tracking, layered onto `NativeSessionStore` without touching
/// its file. Both helpers go exclusively through the store's existing public
/// API (`sessions()` / `upsert(_:)`), so the on-disk `Payload` and its atomic
/// write path are unchanged.
extension NativeSessionStore {
    /// Overwrite an owned session's sidebar title with a title derived live
    /// from its terminal's OSC stream, persisting it through the normal upsert.
    ///
    /// A no-op when `terminalID` is unknown here — an observed Electron
    /// terminal, or a session that just ended — because only sessions this app
    /// owns have a mutable title to carry.
    func applyAutoTitle(_ title: String, terminalID: String) {
        guard var stored = sessions().first(where: { $0.id == terminalID }) else { return }
        stored.title = title
        upsert(stored)
    }

    /// Best-effort "did the user (or a prior live title) take this name over?"
    /// used as the `userRenamed` input to `SessionTitleTracker.shouldApply`.
    /// True when the stored title has diverged from the name the session was
    /// given at creation ("<agent> · <folder>" or just "<folder>").
    ///
    /// Limitation — deliberately zero new persistence: there is no per-session
    /// "user renamed" flag on disk, so this cannot tell a *manual* rename apart
    /// from a title a *previous* live OSC update already applied. Any divergence
    /// from the creation default therefore reads as custom, which means the
    /// first non-generic OSC title (or a manual rename) wins and later OSC
    /// titles are then treated as overriding a custom name and suppressed. That
    /// trades continuous relabeling for a guarantee that a hand-picked name is
    /// never clobbered. An unknown `terminalID` reads as not-custom — there is
    /// nothing to protect. Persisting an explicit flag (or the last auto-title)
    /// would be the way to restore fully-continuous live updates later.
    func hasCustomTitle(_ terminalID: String, defaultTitle: String) -> Bool {
        guard let stored = sessions().first(where: { $0.id == terminalID }) else { return false }
        return stored.title != defaultTitle
    }
}
