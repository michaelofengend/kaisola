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
    /// Agents offered in the New menu, in display order. Keep in sync with
    /// src/lib/terminalAgent.ts TERMINAL_CLI_PROFILES.
    static let all: [AgentProfile] = [
        AgentProfile(id: "claude-code", name: "Claude", launchCommand: "claude", symbol: "sparkle"),
        AgentProfile(id: "codex", name: "Codex", launchCommand: "codex", symbol: "chevron.left.forwardslash.chevron.right"),
        AgentProfile(id: "opencode", name: "OpenCode", launchCommand: "opencode", symbol: "curlybraces"),
        AgentProfile(id: "gemini", name: "Gemini", launchCommand: "gemini", symbol: "diamond"),
    ]

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
