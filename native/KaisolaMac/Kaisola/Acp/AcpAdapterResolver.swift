import Foundation

/// How to spawn an ACP adapter for a given agent. The native app runs the
/// adapter through `npx` so it always resolves the LATEST published package
/// unless a pinned path is provided — matching the "always current" policy the
/// version updater enforces. A login shell recovers the user's PATH exactly as
/// Electron does when spawning agents.
struct AcpAdapter: Equatable, Sendable {
    let command: String
    let arguments: [String]

    /// Resolve the adapter for an agent id (AgentRegistry ids). Returns nil for
    /// agents with no ACP adapter. `packageOverride` lets the version updater
    /// pin an exact resolved binary; otherwise `npx -y <pkg>@latest` is used.
    static func forAgent(_ agentID: String, packageOverride: String? = nil) -> AcpAdapter? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let package: String
        switch agentID {
        case "claude-code": package = "@agentclientprotocol/claude-agent-acp@latest"
        case "codex": package = "@agentclientprotocol/codex-acp@latest"
        default: return nil
        }
        let resolved = packageOverride ?? package
        // -ilc keeps the interactive login environment; the ACP adapter then
        // owns stdio for JSON-RPC.
        return AcpAdapter(command: shell, arguments: ["-ilc", "exec npx -y \(resolved)"])
    }
}
