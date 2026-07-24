import CryptoKit
import Darwin
import Foundation

/// A terminal the native app created and owns. Electron-observed terminals
/// never appear here; membership in this store is the sole gate for enabling
/// input and mutation on a session.
struct NativeOwnedSession: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let projectID: String
    let cwd: String
    var title: String
    let createdAt: Int64
    /// The agent CLI this session boots (AgentRegistry id), or nil for a plain
    /// shell. Persisted so a relaunched session keeps its agent identity.
    var agentID: String?

    init(id: String, projectID: String, cwd: String, title: String, createdAt: Int64, agentID: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.cwd = cwd
        self.title = title
        self.createdAt = createdAt
        self.agentID = agentID
    }
}

/// An explicitly-opened project tab: a folder the user opened as a workspace,
/// which persists even with no live sessions and carries a custom name and
/// optional tint color.
struct OpenProject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    var name: String
    let createdAt: Int64
    /// Tab tint (hex RGB like "E16A6A"); nil = default chrome.
    var colorHex: String?

    init(id: String, path: String, name: String, createdAt: Int64, colorHex: String? = nil) {
        self.id = id
        self.path = path
        self.name = name
        self.createdAt = createdAt
        self.colorHex = colorHex
    }
}

/// What Reopen Closed Session (⌘⌥T) needs to recreate an ended session: the
/// folder, the agent (if any), and the title it had. The PTY itself is gone —
/// reopening starts a fresh shell in the same place.
struct ClosedSession: Codable, Equatable, Sendable {
    let cwd: String
    let agentID: String?
    let title: String
}

/// Persists the app's broker owner identity and its owned-terminal registry in
/// the native application-support directory (never Electron's). Writes are
/// atomic; a corrupt file degrades to an empty registry rather than a crash.
struct NativeSessionStore: Sendable {
    private struct Payload: Codable {
        var ownerID: String
        var sessions: [NativeOwnedSession]
        var projects: [OpenProject]?
        /// Recently closed project tabs, newest last, bounded — powers
        /// Reopen Closed Project (⌘⇧T).
        var closedProjects: [OpenProject]?
        /// Recently ended sessions, newest last, bounded — powers
        /// Reopen Closed Session (⌘⌥T).
        var closedSessions: [ClosedSession]?
        /// Recently opened folders, most recent first — File ▸ Open Recent.
        var recentFolders: [String]?
        /// The session selected when the app last ran, restored on relaunch.
        var lastSelectedSessionID: String?
        /// User-facing aliases for sessions that this native install does not
        /// own (for example an Electron-created terminal).  Ownership still
        /// gates every broker mutation; aliases are local navigation metadata.
        var sessionAliases: [String: String]?
    }

    private let closedStackCap = 10

    let fileURL: URL

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("native-sessions.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// Stable per-install controller identity: the broker's ownership and
    /// stale-write rules key on it, so reattach after relaunch must present
    /// the same value.
    func ownerID() -> String {
        if let payload = read(), !payload.ownerID.isEmpty { return payload.ownerID }
        let fresh = "native-" + UUID().uuidString.lowercased()
        var payload = read() ?? Payload(ownerID: fresh, sessions: [])
        payload.ownerID = fresh
        write(payload)
        return fresh
    }

    func sessions() -> [NativeOwnedSession] {
        read()?.sessions ?? []
    }

    func sessionAliases() -> [String: String] {
        read()?.sessionAliases ?? [:]
    }

    /// Persist or clear a local display alias without touching the PTY or its
    /// broker-owned title. This makes observed sessions safely renameable.
    func setSessionAlias(_ title: String?, for terminalID: String) {
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [])
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var aliases = payload.sessionAliases ?? [:]
        if trimmed.isEmpty {
            aliases.removeValue(forKey: terminalID)
        } else {
            aliases[terminalID] = trimmed
        }
        payload.sessionAliases = aliases.isEmpty ? nil : aliases
        write(payload)
    }

    /// Repair a lost/stale local registry only from the broker's authenticated
    /// stable-owner capability. This is intentionally narrower than matching
    /// the `nproj_` namespace: unrelated native installs remain observed.
    /// A persisted open project supplies the cwd because broker diagnostics do
    /// not expose it. Existing records (including titles/agent ids) win.
    @discardableResult
    func recoverOwnedSessions(
        from records: [BrokerTerminalRecord],
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [NativeOwnedSession] {
        guard var payload = read(), !payload.ownerID.isEmpty else { return [] }
        let projectsByID = Dictionary(uniqueKeysWithValues: (payload.projects ?? []).map { ($0.id, $0) })
        var known = Set(payload.sessions.map(\.id))
        var recovered: [NativeOwnedSession] = []

        for record in records where !record.exited && !known.contains(record.id) {
            guard record.wasOwned(by: payload.ownerID),
                  let project = projectsByID[record.projectID] else { continue }
            let session = NativeOwnedSession(
                id: record.id,
                projectID: record.projectID,
                cwd: project.path,
                title: project.name,
                createdAt: now
            )
            payload.sessions.append(session)
            known.insert(record.id)
            recovered.append(session)
        }
        if !recovered.isEmpty { write(payload) }
        return recovered
    }

    // MARK: - Opened project tabs

    func projects() -> [OpenProject] {
        read()?.projects ?? []
    }

    /// Add a project tab for a directory (idempotent by projectID). Returns the
    /// project so the caller can select it.
    @discardableResult
    func openProject(directory path: String) -> OpenProject {
        let id = Self.projectID(forDirectory: path)
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [], projects: [])
        // Re-opening a folder retires any stale closed-stack entry for it.
        payload.closedProjects?.removeAll { $0.id == id }
        // Every open lands at the head of File ▸ Open Recent.
        let normalized = (path as NSString).standardizingPath
        var recents = payload.recentFolders ?? []
        recents.removeAll { $0 == normalized }
        recents.insert(normalized, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        payload.recentFolders = recents
        var projects = payload.projects ?? []
        if let existing = projects.first(where: { $0.id == id }) {
            write(payload)
            return existing
        }
        let project = OpenProject(
            id: id,
            path: (path as NSString).standardizingPath,
            name: (path as NSString).lastPathComponent,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        projects.append(project)
        payload.projects = projects
        write(payload)
        return project
    }

    func renameProject(id: String, name: String) {
        guard var payload = read(), var projects = payload.projects,
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name
        payload.projects = projects
        write(payload)
    }

    /// Set (or clear) a project tab's tint color.
    func setProjectColor(id: String, colorHex: String?) {
        guard var payload = read(), var projects = payload.projects,
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].colorHex = colorHex
        payload.projects = projects
        write(payload)
    }

    /// Move a project tab one position left/right in the persisted order.
    func moveProject(id: String, delta: Int) {
        guard var payload = read(), var projects = payload.projects,
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard target >= 0, target < projects.count else { return }
        projects.swapAt(index, target)
        payload.projects = projects
        write(payload)
    }

    /// Point a project tab at a folder that moved on disk. Identity follows the
    /// path, so this closes the old tab and opens the new folder carrying the
    /// custom name/color across.
    @discardableResult
    func relocateProject(id: String, toDirectory newPath: String) -> OpenProject? {
        guard let existing = projects().first(where: { $0.id == id }) else { return nil }
        closeProject(id: id)
        var replacement = openProject(directory: newPath)
        // Carry look & feel over to the relocated tab.
        renameProject(id: replacement.id, name: existing.name)
        setProjectColor(id: replacement.id, colorHex: existing.colorHex)
        replacement.name = existing.name
        replacement.colorHex = existing.colorHex
        return replacement
    }

    // MARK: - Recents & selection restore

    func recentFolders() -> [String] {
        read()?.recentFolders ?? []
    }

    func recordRecentFolder(_ path: String) {
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [])
        var recents = payload.recentFolders ?? []
        let normalized = (path as NSString).standardizingPath
        recents.removeAll { $0 == normalized }
        recents.insert(normalized, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        payload.recentFolders = recents
        write(payload)
    }

    func lastSelectedSessionID() -> String? {
        read()?.lastSelectedSessionID
    }

    func recordSelectedSession(_ id: String?) {
        guard var payload = read() else { return }
        payload.lastSelectedSessionID = id
        write(payload)
    }

    func closeProject(id: String) {
        guard var payload = read() else { return }
        if let closed = payload.projects?.first(where: { $0.id == id }) {
            var stack = payload.closedProjects ?? []
            stack.removeAll { $0.id == id }   // no duplicates; most-recent wins
            stack.append(closed)
            if stack.count > closedStackCap { stack.removeFirst(stack.count - closedStackCap) }
            payload.closedProjects = stack
        }
        payload.projects?.removeAll { $0.id == id }
        write(payload)
    }

    /// Restore the most recently closed project tab, removing it from the stack.
    /// Returns the restored project, or nil if the stack is empty.
    @discardableResult
    func reopenLastClosedProject() -> OpenProject? {
        guard var payload = read(), var stack = payload.closedProjects, let restored = stack.popLast() else { return nil }
        var projects = payload.projects ?? []
        if !projects.contains(where: { $0.id == restored.id }) {
            projects.append(restored)
        }
        payload.projects = projects
        payload.closedProjects = stack
        write(payload)
        return restored
    }

    func closedProjects() -> [OpenProject] {
        read()?.closedProjects ?? []
    }

    // MARK: - Closed sessions (⌘⌥T)

    /// Record an ended session so it can be recreated.
    func pushClosedSession(_ closed: ClosedSession) {
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [])
        var stack = payload.closedSessions ?? []
        stack.append(closed)
        if stack.count > closedStackCap { stack.removeFirst(stack.count - closedStackCap) }
        payload.closedSessions = stack
        write(payload)
    }

    /// Pop the most recently ended session for recreation.
    func popClosedSession() -> ClosedSession? {
        guard var payload = read(), var stack = payload.closedSessions, let last = stack.popLast() else { return nil }
        payload.closedSessions = stack
        write(payload)
        return last
    }

    func closedSessions() -> [ClosedSession] {
        read()?.closedSessions ?? []
    }

    func owns(terminalID: String) -> Bool {
        sessions().contains { $0.id == terminalID }
    }

    func upsert(_ session: NativeOwnedSession) {
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [])
        payload.sessions.removeAll { $0.id == session.id }
        payload.sessions.append(session)
        payload.sessions.sort { $0.createdAt < $1.createdAt }
        write(payload)
    }

    func remove(terminalID: String) {
        guard var payload = read() else { return }
        payload.sessions.removeAll { $0.id == terminalID }
        payload.sessionAliases?.removeValue(forKey: terminalID)
        write(payload)
    }

    /// Deterministic project identity for a working directory so the same
    /// folder maps to the same broker project across launches. Distinct from
    /// Electron's `proj_*` namespace by construction.
    static func projectID(forDirectory path: String) -> String {
        let normalized = (path as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "nproj_\(hex)"
    }

    static func terminalID(projectID: String) -> String {
        "term-\(projectID)-\(UUID().uuidString.lowercased().prefix(8))"
    }

    private func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func write(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}

// MARK: - Workspace restoration

/// The persisted surface type is deliberately smaller than the live AppModel surface.
/// In particular, terminal entries are only broker-session references: restoring this
/// state must never synthesize ownership or launch a replacement terminal. Callers must
/// intersect terminal IDs with the broker's live session inventory before attaching.
enum NativeRestorableSurfaceKind: String, Codable, CaseIterable, Sendable {
    case terminal
    case agentChat
}

struct NativeRestorableSurfaceState: Codable, Equatable, Hashable, Sendable {
    let kind: NativeRestorableSurfaceKind
    let id: String
    let projectID: String
    let agentID: String?
    let workspacePath: String?
    /// Adapter-issued ACP session identity. It is a resume candidate only:
    /// callers must negotiate `loadSession` and fall back to `session/new`.
    let acpSessionID: String?
    let title: String?

    init(
        kind: NativeRestorableSurfaceKind,
        id: String,
        projectID: String,
        agentID: String? = nil,
        workspacePath: String? = nil,
        acpSessionID: String? = nil,
        title: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.projectID = projectID
        self.agentID = agentID
        self.workspacePath = workspacePath
        self.acpSessionID = acpSessionID
        self.title = title
    }
}

struct NativeRestorableAgentChatDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let projectID: String
    let agentID: String
    let workspacePath: String
    let acpSessionID: String?
    let title: String?
}

extension NativeRestorableSurfaceState {
    init(agentChat descriptor: NativeRestorableAgentChatDescriptor) {
        self.init(
            kind: .agentChat,
            id: descriptor.id,
            projectID: descriptor.projectID,
            agentID: descriptor.agentID,
            workspacePath: descriptor.workspacePath,
            acpSessionID: descriptor.acpSessionID,
            title: descriptor.title
        )
    }

    var agentChatDescriptor: NativeRestorableAgentChatDescriptor? {
        guard kind == .agentChat,
              let agentID,
              let workspacePath else {
            return nil
        }
        return NativeRestorableAgentChatDescriptor(
            id: id,
            projectID: projectID,
            agentID: agentID,
            workspacePath: workspacePath,
            acpSessionID: acpSessionID,
            title: title
        )
    }
}

struct NativeRestorablePaneState: Codable, Equatable, Identifiable, Sendable {
    /// Stable session/chat ID used by `SessionPaneLayout`.
    let id: String
    let surface: NativeRestorableSurfaceState
    var sizeWeight: Double
    var isMinimized: Bool

    init(
        id: String,
        surface: NativeRestorableSurfaceState,
        sizeWeight: Double = 1,
        isMinimized: Bool = false
    ) {
        self.id = id
        self.surface = surface
        self.sizeWeight = sizeWeight
        self.isMinimized = isMinimized
    }
}

enum NativePaneArrangement: String, Codable, CaseIterable, Sendable {
    case columns
    case rows
    case grid
}

struct NativeProjectWorkspaceState: Codable, Equatable, Identifiable, Sendable {
    var id: String { projectID }

    let projectID: String
    /// Exact two-dimensional pane ordering and geometry. IDs address entries
    /// in `panes`; the descriptors remain the source of terminal/chat identity.
    var layout: SessionPaneLayout
    /// Retained for schema-v1 snapshots and as a coarse fallback when decoding
    /// an archive written before `layout` existed.
    var arrangement: NativePaneArrangement
    var panes: [NativeRestorablePaneState]
    var focusedPaneID: String?
    var updatedAt: Int64

    init(
        projectID: String,
        layout: SessionPaneLayout? = nil,
        arrangement: NativePaneArrangement = .columns,
        panes: [NativeRestorablePaneState] = [],
        focusedPaneID: String? = nil,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        self.projectID = projectID
        self.layout = layout ?? Self.fallbackLayout(for: panes, arrangement: arrangement)
        self.arrangement = arrangement
        self.panes = panes
        self.focusedPaneID = focusedPaneID
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case layout
        case arrangement
        case panes
        case focusedPaneID
        case updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        arrangement = try container.decodeIfPresent(NativePaneArrangement.self, forKey: .arrangement) ?? .columns
        panes = try container.decodeIfPresent([NativeRestorablePaneState].self, forKey: .panes) ?? []
        layout = try container.decodeIfPresent(SessionPaneLayout.self, forKey: .layout)
            ?? Self.fallbackLayout(for: panes, arrangement: arrangement)
        focusedPaneID = try container.decodeIfPresent(String.self, forKey: .focusedPaneID)
        updatedAt = try container.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(layout, forKey: .layout)
        try container.encode(arrangement, forKey: .arrangement)
        try container.encode(panes, forKey: .panes)
        try container.encodeIfPresent(focusedPaneID, forKey: .focusedPaneID)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    fileprivate static func fallbackLayout(
        for panes: [NativeRestorablePaneState],
        arrangement: NativePaneArrangement
    ) -> SessionPaneLayout {
        let visibleIDs = panes.filter { !$0.isMinimized }.map(\.id)
        guard !visibleIDs.isEmpty else { return SessionPaneLayout() }
        switch arrangement {
        case .rows:
            return SessionPaneLayout(columns: [.init(sessionIDs: visibleIDs)])
        case .columns:
            return SessionPaneLayout(columns: visibleIDs.map { .init(sessionIDs: [$0]) })
        case .grid:
            var layout = SessionPaneLayout()
            for id in visibleIDs { layout.add(id) }
            return layout
        }
    }
}

struct NativeWorkspaceRestorationState: Codable, Equatable, Sendable {
    var selectedProjectID: String?
    var projects: [NativeProjectWorkspaceState]

    init(
        selectedProjectID: String? = nil,
        projects: [NativeProjectWorkspaceState] = []
    ) {
        self.selectedProjectID = selectedProjectID
        self.projects = projects
    }
}

struct NativeAgentChatDraft: Codable, Equatable, Identifiable, Sendable {
    /// A SHA-256 identifier derived from the caller's stable conversation key.
    /// The raw key is intentionally not persisted.
    let id: String
    let projectID: String
    let agentID: String
    let workspacePath: String
    let text: String
    let updatedAt: Int64
}

/// A private, bounded archive for UI restoration and unsent composer text.
///
/// This is separate from `NativeSessionStore` so frequent draft saves cannot rewrite
/// broker ownership records. Actor isolation serializes reads and atomic replacements,
/// while the UI can call it from a detached task instead of blocking AppKit rendering.
actor NativeWorkspaceStateStore {
    enum StoreError: Error, Equatable {
        case invalidIdentifier
        case invalidWorkspacePath
        case draftTooLarge(maxBytes: Int)
        case archiveTooLarge(maxBytes: Int)
        case unsupportedSchema(found: Int)
        case unsafePath
    }

    static let schemaVersion = 1
    static let maximumProjects = 64
    static let maximumPanesPerProject = 8
    static let maximumDrafts = 128
    static let maximumDraftBytes = 256 * 1_024
    static let maximumTotalDraftBytes = 2 * 1_024 * 1_024
    static let maximumArchiveBytes = 3 * 1_024 * 1_024
    /// Process-wide production instance. Using one actor avoids lost updates
    /// between independently rendered chat/pane views.
    static let live = NativeWorkspaceStateStore()

    private static let maximumIdentifierCharacters = 240
    private static let maximumTitleCharacters = 512
    private static let minimumPaneWeight = 0.05
    private static let maximumPaneWeight = 20.0

    private struct Archive: Codable, Equatable {
        var schemaVersion: Int
        var restoration: NativeWorkspaceRestorationState
        var drafts: [NativeAgentChatDraft]

        static var empty: Archive {
            Archive(
                schemaVersion: NativeWorkspaceStateStore.schemaVersion,
                restoration: NativeWorkspaceRestorationState(),
                drafts: []
            )
        }
    }

    private struct ArchiveHeader: Decodable {
        let schemaVersion: Int
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedArchive: Archive?

    init(
        fileURL: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("workspace-state-v1.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    static func agentChatStableKey(agentID: String, workspacePath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        return "\(agentID)|\(standardizedPath)"
    }

    func restorationState() throws -> NativeWorkspaceRestorationState {
        try loadArchive().restoration
    }

    func projectState(for projectID: String) throws -> NativeProjectWorkspaceState? {
        try loadArchive().restoration.projects.first { $0.projectID == projectID }
    }

    func saveRestorationState(_ state: NativeWorkspaceRestorationState) throws {
        var archive = try loadArchive()
        archive.restoration = Self.normalized(state)
        try persist(archive)
    }

    func saveProjectState(_ state: NativeProjectWorkspaceState, makeSelected: Bool = false) throws {
        guard Self.isValidIdentifier(state.projectID) else {
            throw StoreError.invalidIdentifier
        }

        var archive = try loadArchive()
        var restoration = archive.restoration
        restoration.projects.removeAll { $0.projectID == state.projectID }
        restoration.projects.append(state)
        if makeSelected {
            restoration.selectedProjectID = state.projectID
        }
        archive.restoration = Self.normalized(restoration)
        try persist(archive)
    }

    func setSelectedProjectID(_ projectID: String?) throws {
        if let projectID, !Self.isValidIdentifier(projectID) {
            throw StoreError.invalidIdentifier
        }
        var archive = try loadArchive()
        archive.restoration.selectedProjectID = projectID
        archive.restoration = Self.normalized(archive.restoration)
        try persist(archive)
    }

    func removeProjectState(projectID: String) throws {
        var archive = try loadArchive()
        archive.restoration.projects.removeAll { $0.projectID == projectID }
        if archive.restoration.selectedProjectID == projectID {
            archive.restoration.selectedProjectID = nil
        }
        try persist(archive)
    }

    func draft(for stableKey: String) throws -> String? {
        let id = Self.storageID(for: stableKey)
        return try loadArchive().drafts.first { $0.id == id }?.text
    }

    func allDrafts() throws -> [NativeAgentChatDraft] {
        try loadArchive().drafts.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveDraft(
        _ text: String,
        stableKey: String,
        projectID: String,
        agentID: String,
        workspacePath: String,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws {
        guard Self.isValidIdentifier(projectID), Self.isValidIdentifier(agentID), !stableKey.isEmpty else {
            throw StoreError.invalidIdentifier
        }

        guard workspacePath.hasPrefix("/") else {
            throw StoreError.invalidWorkspacePath
        }
        let standardizedPath = URL(fileURLWithPath: workspacePath).standardizedFileURL.path

        let textBytes = text.lengthOfBytes(using: .utf8)
        guard textBytes <= Self.maximumDraftBytes else {
            throw StoreError.draftTooLarge(maxBytes: Self.maximumDraftBytes)
        }

        var archive = try loadArchive()
        let id = Self.storageID(for: stableKey)
        archive.drafts.removeAll { $0.id == id }

        if !text.isEmpty {
            archive.drafts.append(
                NativeAgentChatDraft(
                    id: id,
                    projectID: projectID,
                    agentID: agentID,
                    workspacePath: standardizedPath,
                    text: text,
                    updatedAt: max(0, updatedAt)
                )
            )
        }

        archive.drafts = Self.boundedDrafts(archive.drafts, preservingID: text.isEmpty ? nil : id)
        try persist(archive)
    }

    func removeDraft(stableKey: String) throws {
        var archive = try loadArchive()
        let id = Self.storageID(for: stableKey)
        archive.drafts.removeAll { $0.id == id }
        try persist(archive)
    }

    func removeDrafts(projectID: String) throws {
        var archive = try loadArchive()
        archive.drafts.removeAll { $0.projectID == projectID }
        try persist(archive)
    }

    /// Forces the next read to come from disk. Primarily useful after an external app
    /// update or in tests; normal callers should benefit from the actor-local cache.
    func invalidateCache() {
        cachedArchive = nil
    }

    private func loadArchive() throws -> Archive {
        if let cachedArchive {
            return cachedArchive
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            let archive = Archive.empty
            cachedArchive = archive
            return archive
        }

        try validateRegularFile(at: fileURL)
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumArchiveBytes {
            throw StoreError.archiveTooLarge(maxBytes: Self.maximumArchiveBytes)
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let header: ArchiveHeader
        do {
            header = try decoder.decode(ArchiveHeader.self, from: data)
        } catch {
            // A truncated or malformed optional UI archive must not prevent launch.
            // It is intentionally independent of broker ownership and can start empty.
            let archive = Archive.empty
            cachedArchive = archive
            return archive
        }
        guard header.schemaVersion == Self.schemaVersion else {
            // Do not interpret or overwrite a newer app's state after downgrade.
            throw StoreError.unsupportedSchema(found: header.schemaVersion)
        }

        let decoded: Archive
        do {
            decoded = try decoder.decode(Archive.self, from: data)
        } catch {
            // A truncated or malformed optional UI archive must not prevent launch.
            // It is intentionally independent of broker ownership and can start empty.
            let archive = Archive.empty
            cachedArchive = archive
            return archive
        }

        var archive = decoded
        archive.restoration = Self.normalized(decoded.restoration)
        archive.drafts = Self.boundedDrafts(decoded.drafts, preservingID: nil)
        cachedArchive = archive
        return archive
    }

    private func persist(_ candidate: Archive) throws {
        var archive = candidate
        archive.schemaVersion = Self.schemaVersion
        archive.restoration = Self.normalized(candidate.restoration)
        archive.drafts = Self.boundedDrafts(candidate.drafts, preservingID: nil)

        let data = try encoder.encode(archive)
        guard data.count <= Self.maximumArchiveBytes else {
            throw StoreError.archiveTooLarge(maxBytes: Self.maximumArchiveBytes)
        }

        try ensurePrivateParentDirectory()
        if fileManager.fileExists(atPath: fileURL.path) {
            try validateRegularFile(at: fileURL)
        }

        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            if chmod(temporaryURL.path, mode_t(0o600)) != 0 {
                throw CocoaError(.fileWriteNoPermission)
            }
            if rename(temporaryURL.path, fileURL.path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            cachedArchive = archive
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func ensurePrivateParentDirectory() throws {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StoreError.unsafePath }
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() else {
                throw StoreError.unsafePath
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }

        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func validateRegularFile(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & mode_t(0o077)) == 0 else {
            throw StoreError.unsafePath
        }
    }

    private static func normalized(_ state: NativeWorkspaceRestorationState) -> NativeWorkspaceRestorationState {
        var seenProjects = Set<String>()
        let normalizedProjects = state.projects
            .filter { isValidIdentifier($0.projectID) }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.projectID < rhs.projectID }
                return lhs.updatedAt > rhs.updatedAt
            }
            .filter { seenProjects.insert($0.projectID).inserted }
            .prefix(maximumProjects)
            .map(normalizedProject)

        let selectedProjectID = state.selectedProjectID.flatMap {
            isValidIdentifier($0) ? $0 : nil
        }
        return NativeWorkspaceRestorationState(
            selectedProjectID: selectedProjectID,
            projects: Array(normalizedProjects)
        )
    }

    private static func normalizedProject(_ state: NativeProjectWorkspaceState) -> NativeProjectWorkspaceState {
        var seenPaneIDs = Set<String>()
        var seenSurfaceIDs = Set<String>()
        var panes: [NativeRestorablePaneState] = []

        for pane in state.panes {
            guard panes.count < maximumPanesPerProject,
                  isValidIdentifier(pane.id),
                  pane.surface.projectID == state.projectID,
                  let surface = normalizedSurface(pane.surface),
                  pane.id == surface.id else {
                continue
            }

            let surfaceKey = "\(surface.kind.rawValue)|\(surface.id)"
            guard seenPaneIDs.insert(pane.id).inserted,
                  seenSurfaceIDs.insert(surfaceKey).inserted else {
                continue
            }

            let weight = pane.sizeWeight.isFinite
                ? min(maximumPaneWeight, max(minimumPaneWeight, pane.sizeWeight))
                : 1
            panes.append(
                NativeRestorablePaneState(
                    id: pane.id,
                    surface: surface,
                    sizeWeight: weight,
                    isMinimized: pane.isMinimized
                )
            )
        }

        let focusedPaneID = state.focusedPaneID.flatMap { focused in
            panes.contains { $0.id == focused && !$0.isMinimized } ? focused : nil
        }
        let visiblePaneIDs = Set(panes.lazy.filter { !$0.isMinimized }.map(\.id))
        var layout = state.layout
        layout.normalize(availableSessionIDs: visiblePaneIDs)
        for id in panes.lazy.filter({ !$0.isMinimized }).map(\.id) where !layout.contains(id) {
            layout.add(id)
        }
        if layout.isEmpty, !visiblePaneIDs.isEmpty {
            layout = NativeProjectWorkspaceState.fallbackLayout(
                for: panes,
                arrangement: state.arrangement
            )
        }
        return NativeProjectWorkspaceState(
            projectID: state.projectID,
            layout: layout,
            arrangement: state.arrangement,
            panes: panes,
            focusedPaneID: focusedPaneID,
            updatedAt: max(0, state.updatedAt)
        )
    }

    private static func normalizedSurface(
        _ surface: NativeRestorableSurfaceState
    ) -> NativeRestorableSurfaceState? {
        guard isValidIdentifier(surface.id),
              isValidIdentifier(surface.projectID) else {
            return nil
        }

        let title = surface.title.map { String($0.prefix(maximumTitleCharacters)) }
        switch surface.kind {
        case .terminal:
            return NativeRestorableSurfaceState(
                kind: .terminal,
                id: surface.id,
                projectID: surface.projectID,
                title: title
            )
        case .agentChat:
            guard let agentID = surface.agentID,
                  isValidIdentifier(agentID),
                  let workspacePath = surface.workspacePath else {
                return nil
            }
            guard workspacePath.hasPrefix("/") else { return nil }
            let standardizedPath = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
            return NativeRestorableSurfaceState(
                kind: .agentChat,
                id: surface.id,
                projectID: surface.projectID,
                agentID: agentID,
                workspacePath: standardizedPath,
                acpSessionID: surface.acpSessionID.flatMap {
                    isValidIdentifier($0) ? $0 : nil
                },
                title: title
            )
        }
    }

    private static func boundedDrafts(
        _ drafts: [NativeAgentChatDraft],
        preservingID: String?
    ) -> [NativeAgentChatDraft] {
        var seen = Set<String>()
        var totalBytes = 0
        var result: [NativeAgentChatDraft] = []
        let ordered = drafts.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
            return lhs.updatedAt > rhs.updatedAt
        }

        for draft in ordered {
            guard result.count < maximumDrafts,
                  seen.insert(draft.id).inserted,
                  isValidIdentifier(draft.projectID),
                  isValidIdentifier(draft.agentID),
                  draft.workspacePath.hasPrefix("/"),
                  !draft.text.isEmpty else {
                continue
            }

            let bytes = draft.text.lengthOfBytes(using: .utf8)
            guard bytes <= maximumDraftBytes else { continue }
            if totalBytes + bytes > maximumTotalDraftBytes {
                if draft.id == preservingID {
                    // The newly saved draft has priority over older entries. Make room
                    // from the oldest end without ever truncating the user's text.
                    while totalBytes + bytes > maximumTotalDraftBytes,
                          let removed = result.popLast() {
                        totalBytes -= removed.text.lengthOfBytes(using: .utf8)
                    }
                } else {
                    continue
                }
            }

            guard totalBytes + bytes <= maximumTotalDraftBytes else { continue }
            result.append(draft)
            totalBytes += bytes
        }
        return result
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumIdentifierCharacters
            && !value.contains("\0")
            && !value.contains("\n")
            && !value.contains("\r")
    }

    private static func storageID(for stableKey: String) -> String {
        let digest = SHA256.hash(data: Data(stableKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
