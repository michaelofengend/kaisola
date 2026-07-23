import SwiftUI

/// Settings ▸ Agents section that pins a per-project Claude/Codex account on top
/// of the app-wide one. Overrides are project-scoped, so a nil `projectID` (no
/// active project) has nowhere to store them — the section shows a hint instead
/// of the editor, mirroring `McpSettingsTab`. Electron parity: per-project
/// CLAUDE_CONFIG_DIR / CODEX_HOME isolation.
struct ProjectAccountsSection: View {
    /// The active project's broker id (NativeSessionStore.projectID), or nil when
    /// no project is open.
    let projectID: String?
    /// The active project's display name, for the caption.
    let projectName: String?

    @State private var claudeConfigDir = ""
    @State private var codexHome = ""
    private let store = ProjectAccountStore()

    var body: some View {
        Section("Per-project account") {
            if let projectID {
                TextField("CLAUDE_CONFIG_DIR", text: $claudeConfigDir, prompt: Text("app default"))
                    .onSubmit { save(projectID) }
                TextField("CODEX_HOME", text: $codexHome, prompt: Text("app default"))
                    .onSubmit { save(projectID) }
                Text("Overrides the app-wide account for sessions in \(projectName ?? "this project") only. Leave a field blank to keep using the app default above for that CLI.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Open a project to give it its own Claude/Codex account. Its agent sessions then use these directories instead of the app-wide account above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // A fresh load whenever the active project changes underneath the window.
        .onAppear { load() }
        .onChange(of: projectID) { _, _ in load() }
        // Persist on every edit — the store no-ops when nothing changed, so the
        // load above never triggers a spurious write.
        .onChange(of: claudeConfigDir) { _, _ in if let projectID { save(projectID) } }
        .onChange(of: codexHome) { _, _ in if let projectID { save(projectID) } }
    }

    private func load() {
        let override = projectID.flatMap { store.override(forProject: $0) }
        claudeConfigDir = override?.claudeConfigDir ?? ""
        codexHome = override?.codexHome ?? ""
    }

    private func save(_ projectID: String) {
        store.set(
            ProjectAccountOverride(claudeConfigDir: claudeConfigDir, codexHome: codexHome),
            forProject: projectID
        )
    }
}
