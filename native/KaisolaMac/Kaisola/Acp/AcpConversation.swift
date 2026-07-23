import Foundation
import KaisolaCore
import SwiftUI

/// One rendered row in the chat transcript.
enum AcpTranscriptRow: Identifiable, Equatable {
    /// `failed` marks an optimistic send whose prompt request errored — the row
    /// stays visible with a retry affordance instead of vanishing.
    case user(id: String, text: String, failed: Bool)
    case message(id: String, text: String)
    case thought(id: String, text: String)
    case tool(AcpToolCall)
    case plan(id: String, entries: [AcpPlanEntry])

    var id: String {
        switch self {
        case let .user(id, _, _): "user-\(id)"
        case let .message(id, _): "msg-\(id)"
        case let .thought(id, _): "thought-\(id)"
        case let .tool(call): "tool-\(call.id)"
        case let .plan(id, _): "plan-\(id)"
        }
    }
}

/// Drives one ACP agent conversation and accumulates its streaming turn into a
/// transcript the chat view renders. Owns the AcpClient; runs on the main actor
/// so published transcript mutations are UI-safe.
@MainActor
final class AcpConversation: ObservableObject {
    @Published private(set) var rows: [AcpTranscriptRow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var usage: AcpUsage?
    @Published private(set) var models: [AcpSessionInfo.Model] = []
    @Published private(set) var currentModelID: String?
    @Published private(set) var modes: [AcpSessionInfo.Mode] = []
    @Published private(set) var currentModeID: String?
    @Published private(set) var configOptions: [AcpConfigOption] = []
    @Published private(set) var commands: [AcpCommand] = []
    @Published var pendingPermission: AcpPermissionRequest?
    @Published private(set) var statusMessage: String?
    /// Follow-up messages typed while a turn was running; each dispatches when
    /// the preceding turn ends.
    @Published private(set) var queued: [QueuedMessage] = []
    /// Pre-turn working-tree snapshots (git stash create), restorable from the
    /// header. Present only when the workspace is a git repo with changes.
    @Published private(set) var checkpoints: [TurnCheckpoint] = []

    struct QueuedMessage: Identifiable, Equatable, Sendable {
        let id: String
        let text: String
    }

    struct TurnCheckpoint: Identifiable, Equatable, Sendable {
        let id: String       // stash commit hash
        let turn: Int
        let at: Date
    }

    let title: String
    /// Reports needs-you moments (permission surfaced, turn finished) so the
    /// owner can decide whether they warrant an inbox entry. Set by AppModel.
    var onAttention: ((AttentionCenter.Kind, _ detail: String) -> Void)?
    private let client: AcpClient
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let cwd: String
    private let mcpServers: [JSONValue]
    private let ruleStore: PermissionRuleStore
    private let sensitiveGlobs: [String]
    private var turnCounter = 0
    private var queueCounter = 0

    init(
        title: String,
        command: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cwd: String,
        mcpServers: [JSONValue] = [],
        client: AcpClient = AcpClient(),
        ruleStore: PermissionRuleStore = PermissionRuleStore(),
        sensitiveGlobs: [String] = AcpPermissionRules.defaultSensitiveGlobs
    ) {
        self.title = title
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.client = client
        self.ruleStore = ruleStore
        self.sensitiveGlobs = sensitiveGlobs
    }

    func start() async {
        await client.setEventHandler { [weak self] event in
            Task { @MainActor in self?.consume(event) }
        }
        await client.configureFsGuard(sensitiveGlobs: sensitiveGlobs)
        do {
            let info = try await client.start(
                command: command,
                arguments: arguments,
                environment: environment,
                cwd: cwd,
                mcpServers: mcpServers
            )
            models = info.models
            currentModelID = info.currentModelID
            modes = info.modes
            currentModeID = info.currentModeID
            configOptions = info.configOptions
            isConnected = true
            statusMessage = nil
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isConnected = false
        }
    }

    /// Send a message, or — if a turn is already running — queue it as a
    /// follow-up that dispatches automatically when the current turn ends.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !trimmed.isEmpty else { return }
        if isRunning {
            queueCounter += 1
            queued.append(QueuedMessage(id: "q\(queueCounter)", text: trimmed))
            return
        }
        dispatch(trimmed)
    }

    /// Drop a still-pending queued follow-up before it dispatches.
    func removeQueued(_ id: String) {
        queued.removeAll { $0.id == id }
    }

    /// Steer: promote a queued follow-up to the front and interrupt the current
    /// turn so it dispatches now (the cancel ends the turn, and the normal
    /// turn-end flush sends the promoted message). Idle → dispatches directly.
    func steerQueued(_ id: String) {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let message = queued.remove(at: index)
        if isRunning {
            queued.insert(message, at: 0)
            Task { await client.cancel() }
        } else {
            dispatch(message.text)
        }
    }

    /// Retry a failed optimistic send: the failed row is replaced by a fresh
    /// dispatch of the same text.
    func retryFailed(_ rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }),
              case let .user(_, text, failed) = rows[index], failed else { return }
        rows.remove(at: index)
        if isRunning {
            queueCounter += 1
            queued.append(QueuedMessage(id: "q\(queueCounter)", text: text))
        } else {
            dispatch(text)
        }
    }

    private func dispatch(_ trimmed: String) {
        turnCounter += 1
        let rowID = "\(turnCounter)"
        rows.append(.user(id: rowID, text: trimmed, failed: false))
        isRunning = true
        recordCheckpoint(turn: turnCounter)
        Task {
            do { try await client.prompt(trimmed) }
            catch {
                statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isRunning = false
                // Roll back optimism: mark the row failed so the user can retry.
                if let index = rows.firstIndex(where: { $0.id == "user-\(rowID)" }) {
                    rows[index] = .user(id: rowID, text: trimmed, failed: true)
                }
            }
        }
    }

    func cancel() {
        Task { await client.cancel() }
    }

    func selectModel(_ id: String) {
        currentModelID = id
        Task { await client.setModel(id) }
    }

    func selectMode(_ id: String) {
        currentModeID = id
        Task { await client.setMode(id) }
    }

    /// Set an adapter config option (effort level etc.); the client re-emits the
    /// adapter's normalized option set, which `consume` applies.
    func selectConfigOption(_ id: String, value: String) {
        if let index = configOptions.firstIndex(where: { $0.id == id }) {
            configOptions[index].currentValue = value   // optimistic
        }
        Task { await client.setConfigOption(id: id, value: value) }
    }

    func answerPermission(_ optionID: String) {
        guard let permission = pendingPermission else { return }
        pendingPermission = nil
        Task { await client.resolvePermission(id: permission.id, optionID: optionID) }
    }

    /// Grant this ask AND create a standing rule so future matching asks
    /// auto-allow. Refused for sensitive-file asks — those can never be
    /// rule-covered (the button is hidden in that case, this is defense in depth).
    func answerPermissionAlways() {
        guard let permission = pendingPermission else { return }
        if !AcpPermissionRules.requestIsSensitive(globs: sensitiveGlobs, title: permission.title, paths: permission.paths) {
            let derived = AcpPermissionRules.ruleForRequest(kind: permission.kind, title: permission.title)
            let rule = PermissionRule(
                id: UUID().uuidString,
                workspace: cwd,
                action: derived.action,
                resource: derived.resource,
                at: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            _ = ruleStore.add(rule)
        }
        answerAllowOnce(permission)
    }

    /// Route an incoming permission ask: sensitive files always surface a card;
    /// otherwise a matching standing rule auto-allows silently; else surface.
    private func handlePermission(_ request: AcpPermissionRequest) {
        if AcpPermissionRules.requestIsSensitive(globs: sensitiveGlobs, title: request.title, paths: request.paths) {
            pendingPermission = request
            onAttention?(.permission, request.title)
            return
        }
        if AcpPermissionRules.requestMatchesRule(ruleStore.rules(), workspace: cwd, kind: request.kind, title: request.title) != nil {
            answerAllowOnce(request)
            return
        }
        pendingPermission = request
        onAttention?(.permission, request.title)
    }

    /// Answer with the request's allow_once option (falling back to the first
    /// non-reject option, then the first option), never persisting allow_always.
    private func answerAllowOnce(_ request: AcpPermissionRequest) {
        if pendingPermission?.id == request.id { pendingPermission = nil }
        let option = request.options.first { $0.kind == "allow_once" }
            ?? request.options.first { !$0.kind.contains("reject") }
            ?? request.options.first
        guard let option else { return }
        Task { await client.resolvePermission(id: request.id, optionID: option.id) }
    }

    /// Whether the pending ask may be "always allowed" (hidden for sensitive files).
    var pendingPermissionAllowsRule: Bool {
        guard let permission = pendingPermission else { return false }
        return !AcpPermissionRules.requestIsSensitive(globs: sensitiveGlobs, title: permission.title, paths: permission.paths)
    }

    func stop() {
        Task { await client.stop() }
    }

    /// Live output of an agent-spawned terminal, for tool-card rendering.
    func terminalSnapshot(_ id: String) async -> AcpTerminalHost.Snapshot? {
        await client.terminalSnapshot(id)
    }

    // MARK: - Pre-turn checkpoints

    /// Snapshot the working tree before the agent's turn starts. Off-main; a
    /// non-repo or clean tree is silently skipped.
    private func recordCheckpoint(turn: Int) {
        let workspace = cwd
        Task.detached(priority: .utility) { [weak self] in
            let service = GitService(repoRoot: URL(fileURLWithPath: workspace, isDirectory: true))
            guard let hash = try? service.checkpoint() else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                checkpoints.append(TurnCheckpoint(id: hash, turn: turn, at: Date()))
                if checkpoints.count > 20 { checkpoints.removeFirst(checkpoints.count - 20) }
            }
        }
    }

    /// Restore a checkpoint's files over the current tree (user-confirmed in
    /// the header). Conflicts surface as a status message, never silently.
    func restoreCheckpoint(_ id: String) {
        let workspace = cwd
        Task.detached(priority: .userInitiated) { [weak self] in
            let service = GitService(repoRoot: URL(fileURLWithPath: workspace, isDirectory: true))
            let message: String?
            do {
                try service.applyCheckpoint(id)
                message = "Checkpoint restored."
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await MainActor.run { [weak self] in self?.statusMessage = message }
        }
    }

    // MARK: - Stream accumulation

    private func consume(_ event: AcpEvent) {
        switch event {
        case let .turnItem(item):
            accumulate(item)
        case let .toolCallUpdate(id, status, content, title):
            if let index = rows.lastIndex(where: { if case let .tool(c) = $0 { return c.id == id } else { return false } }),
               case var .tool(call) = rows[index] {
                if let status { call.status = status }
                if let content, !content.isEmpty { call.content = content }
                if let title, !title.isEmpty { call.title = title }
                rows[index] = .tool(call)
            }
        case let .usage(usage):
            self.usage = usage
        case let .modelChanged(id):
            currentModelID = id
        case let .modeChanged(id):
            currentModeID = id
        case let .commands(list):
            commands = list
        case let .configOptions(options):
            configOptions = options
        case let .permission(request):
            handlePermission(request)
        case .turnEnded:
            isRunning = false
            onAttention?(.turnCompleted, "Finished a turn")
            flushQueue()
        case let .error(message):
            statusMessage = message
            isRunning = false
            // Leave the queue intact on error — auto-dispatching into a failing
            // agent would loop; the user can retry or clear it.
        case let .exited(code):
            isConnected = false
            isRunning = false
            queued.removeAll()   // the agent is gone; nothing can dispatch
            statusMessage = code == 0 ? "The agent ended." : "The agent exited (code \(code))."
        }
    }

    /// Dispatch the next queued follow-up after a turn ends.
    private func flushQueue() {
        guard !isRunning, isConnected, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        dispatch(next.text)
    }

    /// Streaming chunks accumulate into the current agent message/thought so the
    /// transcript grows smoothly rather than one row per chunk.
    private func accumulate(_ item: AcpTurnItem) {
        switch item {
        case let .message(_, text):
            appendChunk(text, isThought: false)
        case let .thought(_, text):
            appendChunk(text, isThought: true)
        case let .toolCall(call):
            rows.append(.tool(call))
        case let .plan(entries):
            if let index = rows.lastIndex(where: { if case .plan = $0 { return true } else { return false } }) {
                rows[index] = .plan(id: "\(turnCounter)", entries: entries)
            } else {
                rows.append(.plan(id: "\(turnCounter)", entries: entries))
            }
        }
    }

    private func appendChunk(_ text: String, isThought: Bool) {
        let rowID = "\(turnCounter)"
        if let last = rows.last {
            if !isThought, case let .message(id, existing) = last, id == rowID {
                rows[rows.count - 1] = .message(id: id, text: existing + text)
                return
            }
            if isThought, case let .thought(id, existing) = last, id == rowID {
                rows[rows.count - 1] = .thought(id: id, text: existing + text)
                return
            }
        }
        rows.append(isThought ? .thought(id: rowID, text: text) : .message(id: rowID, text: text))
    }
}
