import Foundation

/// One Kaisola Mesh run: the same prompt fanned out to several agents, each in
/// its own ACP conversation — and, when the workspace is a git repo, each in an
/// ISOLATED git worktree on a `kaisola-mesh-*` branch so their edits can't
/// collide. Columns stream independently; each can be diffed against HEAD and
/// the human integrates the winner (v1: judgment stays with the user).
@MainActor
final class MeshSession: ObservableObject, Identifiable {
    struct Column: Identifiable {
        let id: String
        let agent: AgentProfile
        let conversation: AcpConversation
        /// The isolated worktree this column works in (nil = shared workspace).
        let worktreePath: String?
        let branch: String?
    }

    let id: String
    let title: String
    let baseDirectory: URL
    @Published private(set) var columns: [Column] = []
    /// Non-nil when isolation was requested but unavailable (not a repo).
    @Published private(set) var isolationNote: String?

    private let fileManager = FileManager.default

    init(id: String = "mesh-\(UUID().uuidString.lowercased().prefix(8))", baseDirectory: URL) {
        self.id = id
        self.baseDirectory = baseDirectory
        self.title = "Mesh · \(baseDirectory.lastPathComponent)"
    }

    /// Create a column per agent. Worktree isolation is attempted per column
    /// and degrades (with a note) to the shared folder when the base isn't a
    /// git repo.
    func start(agents: [AgentProfile], environment: [String: String] = ProcessInfo.processInfo.environment) async {
        let service = GitService(repoRoot: baseDirectory)
        // A git workspace promises isolation; a plain folder never had it.
        // Distinguish the two so a worktree FAILURE in a repo fails closed
        // instead of silently fanning agents into one shared writable tree.
        let baseIsRepo = await Task.detached(priority: .userInitiated) {
            (try? service.status()) != nil
        }.value
        for agent in agents {
            // Resolve adapters from the SAME environment the columns run with,
            // so a dev/test adapter override actually governs the spawn.
            guard let adapter = AcpAdapter.forAgent(agent.id, environment: environment) else { continue }
            var worktree: String?
            var branch: String?
            if baseIsRepo {
                let candidateBranch = "\(GitService.meshBranchPrefix)\(id.suffix(6))-\(agent.id)"
                let candidatePath = fileManager.temporaryDirectory
                    .appendingPathComponent("kaisola-mesh", isDirectory: true)
                    .appendingPathComponent("\(id)-\(agent.id)", isDirectory: true).path
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try service.worktreeAdd(path: candidatePath, branch: candidateBranch)
                    }.value
                    worktree = candidatePath
                    branch = candidateBranch
                } catch {
                    // Fail closed: no isolated column, no column at all.
                    isolationNote = "Could not create a worktree for \(agent.name) — column skipped."
                    continue
                }
            } else if isolationNote == nil {
                isolationNote = "Not a git repo — columns share the workspace (no isolation)."
            }
            let cwd = worktree ?? baseDirectory.path
            let conversation = AcpConversation(
                title: agent.name,
                command: adapter.command,
                arguments: adapter.arguments,
                environment: environment,
                cwd: cwd,
                sensitiveGlobs: NativePreviewSettings.shared.sensitiveGlobs
            )
            columns.append(Column(
                id: "\(id)-\(agent.id)",
                agent: agent,
                conversation: conversation,
                worktreePath: worktree,
                branch: branch
            ))
        }
        for column in columns {
            await column.conversation.start()
        }
    }

    /// How many worktree columns hold uncommitted changes — the Close guard
    /// asks before destroying them.
    func dirtyColumnCount() async -> Int {
        let paths = columns.compactMap(\.worktreePath)
        guard !paths.isEmpty else { return 0 }
        return await Task.detached(priority: .userInitiated) {
            paths.filter { path in
                let service = GitService(repoRoot: URL(fileURLWithPath: path, isDirectory: true))
                guard let status = try? service.status() else { return false }
                return !status.isClean
            }.count
        }.value
    }

    /// Fan the prompt out to every connected column (each queues if busy).
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for column in columns {
            column.conversation.send(trimmed)
        }
    }

    var anyRunning: Bool {
        columns.contains { $0.conversation.isRunning }
    }

    /// A column's working-tree diff vs HEAD (worktree columns only).
    func diff(for columnID: String) async -> String {
        guard let column = columns.first(where: { $0.id == columnID }),
              let path = column.worktreePath else { return "" }
        let service = GitService(repoRoot: URL(fileURLWithPath: path, isDirectory: true))
        return await Task.detached(priority: .userInitiated) {
            (try? service.diffAgainstHead()) ?? ""
        }.value
    }

    /// Stop every agent and clean up Mesh worktrees + branches. Cleanup runs
    /// sequentially — concurrent git processes contend on the repo lock and
    /// would leave stray branches behind.
    func shutdown() {
        let service = GitService(repoRoot: baseDirectory)
        let cleanups = columns.compactMap { column -> (String, String)? in
            column.conversation.stop()
            guard let path = column.worktreePath, let branch = column.branch else { return nil }
            return (path, branch)
        }
        columns.removeAll()
        guard !cleanups.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (path, branch) in cleanups {
                try? service.worktreeRemove(path: path, branch: branch)
            }
        }
    }
}
