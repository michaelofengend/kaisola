import Foundation

/// Quick Actions execution. A quick action opens a fresh **owned** terminal in
/// the project directory and runs the command there, then leaves the shell
/// interactive — the same "run then hand back control" shape as a launched
/// agent CLI (`<command>; exec <shell> -il`).
///
/// Implementation note / deliberate tradeoff: `createOwnedSession` and the
/// `controlClient` write path are private to `AppModel`, so this extension does
/// **not** reach into them. Instead it uses only the public surface —
/// `createTerminal(inDirectory:)` to spawn the shell, then `sendInput(_:to:)`
/// to type the command into it. The command therefore lands on the shell's
/// stdin exactly as if the user had typed it: it appears in the terminal
/// scrollback and the shell's history. That is intentional (an honest "type it
/// into a fresh shell" flow, not a hidden exec) and mirrors what a human does
/// when they open a terminal and run `npm test`.
extension AppModel {
    /// Open a fresh owned shell in `directory` and run `action.command` in it.
    /// No-op for a blank command. Requires the broker's controller lane; if it
    /// is unavailable, `createTerminal` surfaces the reason and nothing is
    /// typed (the guards below never fall back to an already-open terminal).
    func runQuickAction(_ action: QuickAction, inProject directory: URL) async {
        let command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        // Remember what was selected so we only ever type into a genuinely NEW
        // owned session. If creation fails (no control, error) the selection is
        // unchanged and we send nothing rather than run the command in whatever
        // terminal happened to be open.
        let priorSelection = selectedSessionID
        await createTerminal(inDirectory: directory)

        // The create path sets `selectedSessionID` and marks the terminal owned
        // once the PTY lands. Poll for that (≤5s at 100ms) so the write targets
        // the fresh shell even if selection settles a beat after the await.
        var waitedMillis = 0
        while waitedMillis < 5_000 {
            if controlAvailable,
               let sessionID = selectedSessionID,
               sessionID != priorSelection,
               isOwned(sessionID) {
                sendInput(command + "\r", to: sessionID)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitedMillis += 100
        }
        // Timed out: creation did not produce a new owned shell (e.g. the
        // connected broker refuses native control). `createTerminal` has
        // already explained why in the detail pane; nothing more to do.
    }

    /// Open a fresh owned shell in the current project (or home) and run a
    /// one-off command there — the Settings sign-in card's path. A brief settle
    /// after the shell lands keeps a heavy rc file from eating the keystrokes.
    func runCommandInNewTerminal(_ command: String) async {
        let directory = currentProjectDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let priorSelection = selectedSessionID
        await createTerminal(inDirectory: directory)
        var waitedMillis = 0
        while waitedMillis < 5_000 {
            if controlAvailable,
               let sessionID = selectedSessionID,
               sessionID != priorSelection,
               isOwned(sessionID) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                sendInput(trimmed + "\r", to: sessionID)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitedMillis += 100
        }
    }
}
