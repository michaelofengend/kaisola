import Foundation

/// A CLI agent the native app can launch into an owned terminal. Mirrors the
/// Electron renderer's TERMINAL_CLI_PROFILES (src/lib/terminalAgent.ts) so the
/// two shells recognize and label the same agents.
struct AgentProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The command that boots the agent CLI, run through a login shell so the
    /// user's PATH and CLI configuration apply exactly as in Electron.
    let launchCommand: String
    /// SF Symbol shown on the session row.
    let symbol: String

    /// A shell terminal with no agent, for a plain command line.
    static let shell = AgentProfile(id: "shell", name: "Terminal", launchCommand: "", symbol: "terminal")
}

enum AgentRegistry {
    /// The agents shipped with the app, in display order. Keep in sync with
    /// src/lib/terminalAgent.ts TERMINAL_CLI_PROFILES.
    static let builtIns: [AgentProfile] = [
        AgentProfile(id: "claude-code", name: "Claude", launchCommand: "claude", symbol: "sparkle"),
        AgentProfile(id: "codex", name: "Codex", launchCommand: "codex", symbol: "chevron.left.forwardslash.chevron.right"),
        AgentProfile(id: "opencode", name: "OpenCode", launchCommand: "opencode", symbol: "curlybraces"),
        AgentProfile(id: "gemini", name: "Gemini", launchCommand: "gemini", symbol: "diamond"),
    ]

    /// Test-only seam: when set, `custom` reads this store instead of the
    /// default on-disk one, so registry tests never touch the real
    /// application-support file. `nil` in production. `nonisolated(unsafe)`
    /// because it is a single-threaded test hook, not shared runtime state, and
    /// keeping the registry non-isolated preserves every existing call site.
    nonisolated(unsafe) static var customStoreOverride: CustomAgentStore?

    /// User-registered terminal-only agents, loaded from `CustomAgentStore`.
    /// These deliberately have no ACP adapter — `AcpAdapter.forAgent` returns
    /// nil for their `custom-…` ids — so they only ever launch into an owned
    /// terminal, never the chat surface.
    static var custom: [AgentProfile] {
        (customStoreOverride ?? CustomAgentStore()).asProfiles()
    }

    /// Agents offered in the New menu, in display order: built-ins first, then
    /// the user's custom agents. Computed so freshly saved custom agents appear
    /// without a relaunch.
    static var all: [AgentProfile] {
        builtIns + custom
    }

    static func profile(id: String) -> AgentProfile? {
        all.first { $0.id == id }
    }

    /// Recognizes an agent from a stored session's launch metadata.
    static func profile(forCommand command: String?) -> AgentProfile? {
        guard let command, !command.isEmpty else { return nil }
        let leaf = command.split(separator: "/").last.map(String.init) ?? command
        let word = leaf.split(separator: " ").first.map(String.init) ?? leaf
        return all.first { $0.launchCommand == word }
    }
}
