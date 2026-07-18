import Foundation

@MainActor
final class CompanionStore: ObservableObject {
    @Published var connection: CompanionConnectionState
    @Published var projects: [CompanionProject]
    @Published var sessions: [CompanionSession]
    @Published var attention: [CompanionAttention]
    @Published var permissions: [CompanionPermission]
    @Published var selectedProjectId: String?
    @Published var previewReceipt: String?
    @Published private(set) var transportState: CompanionTransportState
    @Published private(set) var lastAckCursor: CompanionAckCursor?

    let isPreview: Bool
    let canControlAgents: Bool
    let canControlTerminals: Bool

    init(
        connection: CompanionConnectionState,
        projects: [CompanionProject],
        sessions: [CompanionSession],
        attention: [CompanionAttention],
        permissions: [CompanionPermission],
        selectedProjectId: String? = nil,
        isPreview: Bool,
        canControlAgents: Bool = false,
        canControlTerminals: Bool = false,
        transportState: CompanionTransportState = .idle
    ) {
        self.connection = connection
        self.projects = projects
        self.sessions = sessions
        self.attention = attention
        self.permissions = permissions
        self.selectedProjectId = selectedProjectId ?? projects.first?.id
        self.isPreview = isPreview
        self.canControlAgents = canControlAgents
        self.canControlTerminals = canControlTerminals
        self.transportState = transportState
        lastAckCursor = nil
    }

    static func preview(now: Date = .now) -> CompanionStore {
        CompanionPreviewData.store(now: now)
    }

    static func live(client: CompanionClient) -> CompanionStore {
        let store = CompanionStore(
            connection: .offline,
            projects: [],
            sessions: [],
            attention: [],
            permissions: [],
            isPreview: false,
            transportState: client.transport.state
        )
        store.bind(to: client)
        return store
    }

    func bind(to client: CompanionClient) {
        guard !isPreview else { return }
        client.onTransportState = { [weak self] state in
            guard let self else { return }
            transportState = state
            connection = state.storeState
        }
        client.onEnvelope = { [weak self, weak client] envelope in
            guard let self else { return }
            do {
                if try apply(envelope), let cursor = lastAckCursor {
                    try client?.acknowledge(cursor)
                }
            } catch {
                connection = .stale
            }
        }
    }

    @discardableResult
    func apply(_ envelope: CompanionEnvelope) throws -> Bool {
        guard !isPreview else { return false }
        switch envelope.kind {
        case .snapshot:
            let snapshot = try envelope.body.decode(CompanionSnapshotBody.self)
            projects = snapshot.projection.projects
            sessions = snapshot.projection.sessions
            attention = snapshot.projection.attention
            permissions = snapshot.projection.permissions
            if selectedProjectId == nil || !projects.contains(where: { $0.id == selectedProjectId }) {
                selectedProjectId = projects.first?.id
            }
            connection = snapshot.projection.freshness == "live" ? .live : .stale
        case .event:
            guard lastAckCursor == nil || envelope.epoch == lastAckCursor?.epoch else {
                connection = .stale
                return false
            }
            if let cursor = lastAckCursor, envelope.seq <= cursor.seq { return false }
            try applyEvent(envelope)
        case .hello:
            connection = .live
            return false
        case .receipt, .error:
            previewReceipt = envelope.body.fields["message"]?.stringValue
            return false
        case .command, .ack:
            return false
        }

        if lastAckCursor == nil || envelope.kind == .snapshot {
            lastAckCursor = CompanionAckCursor(epoch: envelope.epoch, seq: envelope.seq)
            return true
        }
        return lastAckCursor?.accept(envelope) == true
    }

    private func applyEvent(_ envelope: CompanionEnvelope) throws {
        let fields = envelope.body.fields
        switch envelope.body.type {
        case "project.updated":
            guard let projectionValue = fields["projection"] else {
                connection = .stale
                return
            }
            let projection = try JSONDecoder().decode(
                CompanionProjection.self,
                from: CanonicalJSON.data(from: projectionValue)
            )
            merge(projection: projection)
        case "session.updated":
            if let sessionValue = fields["session"] {
                let session = try JSONDecoder().decode(
                    CompanionSession.self,
                    from: CanonicalJSON.data(from: sessionValue)
                )
                upsert(session)
            } else if let sessionId = fields["sessionId"]?.stringValue,
                      let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                if let busy = fields["busy"]?.boolValue {
                    sessions[index].status = busy ? .running : .idle
                }
                sessions[index].updatedAt = envelope.sentAt
                sessions[index].terminalStreamEpoch = fields["streamEpoch"]?.stringValue
                sessions[index].terminalEndOffset = fields["offset"]?.intValue
            }
        case "attention.raised":
            var payload = fields
            payload.removeValue(forKey: "type")
            let item = try JSONDecoder().decode(
                CompanionAttention.self,
                from: CanonicalJSON.data(from: .object(payload))
            )
            upsert(item)
        case "attention.cleared":
            if let id = fields["id"]?.stringValue { attention.removeAll { $0.id == id } }
        case "agent.turn.delta":
            try applyAgentDelta(fields, sentAt: envelope.sentAt)
        case "agent.turn.completed":
            let sessionId = fields["sessionId"]?.stringValue ?? fields["targetId"]?.stringValue
            if let sessionId, let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[index].status = fields["ok"]?.boolValue == false ? .failed : .idle
                sessions[index].updatedAt = envelope.sentAt
            }
        case "agent.permission.requested":
            let body = try envelope.body.decode(CompanionPermissionRequestedBody.self)
            let permission = CompanionPermission(
                permId: body.permId,
                projectId: body.projectId,
                sessionId: body.sessionId ?? body.targetId,
                agent: body.agent,
                title: body.title,
                kind: body.kind,
                requestedAt: body.requestedAt ?? envelope.sentAt,
                options: body.options,
                diffs: body.diffs,
                revision: body.revision,
                completeness: body.completeness
            )
            if let index = permissions.firstIndex(where: { $0.id == permission.id }) { permissions[index] = permission }
            else { permissions.append(permission) }
        case "agent.permission.resolved":
            if let id = fields["permId"]?.stringValue { permissions.removeAll { $0.id == id } }
        case "terminal.output":
            let body = try envelope.body.decode(CompanionTerminalOutputBody.self)
            applyTerminalText(
                sessionId: body.terminalId,
                text: body.data,
                streamEpoch: body.streamEpoch,
                endOffset: body.endOffset,
                replace: false,
                sentAt: envelope.sentAt
            )
        case "terminal.snapshot":
            if let terminalId = fields["terminalId"]?.stringValue,
               let output = fields["output"]?.stringValue {
                applyTerminalText(
                    sessionId: terminalId,
                    text: output,
                    streamEpoch: fields["streamEpoch"]?.stringValue,
                    endOffset: fields["endOffset"]?.intValue,
                    replace: true,
                    sentAt: envelope.sentAt
                )
            }
        case "terminal.exit":
            if let terminalId = fields["terminalId"]?.stringValue,
               let index = sessions.firstIndex(where: { $0.id == terminalId }) {
                sessions[index].status = .done
                sessions[index].updatedAt = envelope.sentAt
                sessions[index].terminalEndOffset = fields["offset"]?.intValue
            }
        default:
            break
        }
    }

    private func merge(projection: CompanionProjection) {
        let projectIds = Set(projection.projects.map(\.id))
        projects.removeAll { projectIds.contains($0.id) }
        projects.append(contentsOf: projection.projects)
        sessions.removeAll { projectIds.contains($0.projectId) }
        sessions.append(contentsOf: projection.sessions)
        attention.removeAll { projectIds.contains($0.projectId) }
        attention.append(contentsOf: projection.attention)
        permissions.removeAll { projectIds.contains($0.projectId) }
        permissions.append(contentsOf: projection.permissions)
    }

    private func upsert(_ session: CompanionSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions.append(session) }
    }

    private func upsert(_ item: CompanionAttention) {
        if let index = attention.firstIndex(where: { $0.id == item.id }) { attention[index] = item }
        else { attention.append(item) }
    }

    private func applyAgentDelta(_ fields: [String: JSONValue], sentAt: Int64) throws {
        guard let sessionId = fields["sessionId"]?.stringValue ?? fields["targetId"]?.stringValue,
              let index = sessions.firstIndex(where: { $0.id == sessionId }),
              let turnId = fields["turnId"]?.stringValue,
              let deltaValue = fields["delta"] else { return }
        let text: String?
        if let direct = deltaValue.stringValue { text = direct }
        else if let delta = deltaValue.objectValue {
            text = delta["text"]?.stringValue
                ?? delta["content"]?.objectValue?["text"]?.stringValue
        } else { text = nil }
        guard let text else { return }
        var turns = sessions[index].turns ?? []
        if let turnIndex = turns.firstIndex(where: { $0.wireId == turnId }) {
            turns[turnIndex].text += text
            turns[turnIndex].at = sentAt
        } else {
            turns.append(CompanionTurn(role: .assistant, text: text, status: "streaming", at: sentAt, wireId: turnId))
        }
        sessions[index].turns = turns
        sessions[index].summary = String(text.prefix(240))
        sessions[index].updatedAt = sentAt
    }

    private func applyTerminalText(
        sessionId: String,
        text: String,
        streamEpoch: String?,
        endOffset: Int64?,
        replace: Bool,
        sentAt: Int64
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let existing = replace ? "" : (sessions[index].terminalLines ?? []).joined(separator: "\n")
        let bounded = String((existing + text).suffix(128_000))
        sessions[index].terminalLines = bounded.components(separatedBy: "\n")
        sessions[index].terminalStreamEpoch = streamEpoch
        sessions[index].terminalEndOffset = endOffset
        sessions[index].updatedAt = sentAt
    }

    var needsYouCount: Int {
        let representedSessionIds = Set(permissions.compactMap(\.sessionId) + attention.compactMap(\.sessionId))
        let unrepresentedWaitingSessions = sessions.filter {
            $0.needsYou && $0.status == .waiting && !representedSessionIds.contains($0.id)
        }.count
        return permissions.count + attention.count + unrepresentedWaitingSessions
    }

    var visibleSessions: [CompanionSession] {
        guard let selectedProjectId else { return sessions }
        return sessions.filter { $0.projectId == selectedProjectId }
    }

    func project(for id: String) -> CompanionProject? {
        projects.first { $0.id == id }
    }

    func session(for id: String) -> CompanionSession? {
        sessions.first { $0.id == id }
    }

    func counts(for projectId: String) -> CompanionProjectCounts {
        let projectSessions = sessions.filter { $0.projectId == projectId }
        return CompanionProjectCounts(
            running: projectSessions.filter { $0.status == .running }.count,
            waiting: projectSessions.filter { $0.status == .waiting }.count,
            done: projectSessions.filter { $0.status == .done }.count,
            failed: projectSessions.filter { $0.status == .failed }.count
        )
    }

    func resolvePermission(_ permissionId: String, decision: String) {
        guard isPreview, let permission = permissions.first(where: { $0.id == permissionId }) else { return }
        permissions.removeAll { $0.id == permissionId }
        if let sessionId = permission.sessionId,
           let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].needsYou = false
            sessions[index].unread = false
            sessions[index].status = decision == "Allow once" ? .running : .done
            sessions[index].summary = decision == "Allow once"
                ? "Preview decision applied; agent resumed locally"
                : "Preview decision rejected locally"
        }
        previewReceipt = "Preview only: \(decision.lowercased())"
    }

    func acknowledge(_ attentionId: String) {
        guard isPreview else { return }
        attention.removeAll { $0.id == attentionId }
        previewReceipt = "Preview only: item acknowledged"
    }

    func sendPreviewPrompt(to sessionId: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPreview, !clean.isEmpty, let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        var turns = sessions[index].turns ?? []
        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        turns.append(CompanionTurn(role: .user, text: clean, at: nowMs))
        turns.append(CompanionTurn(
            role: .assistant,
            text: "Preview received. Live delivery will become available after the Mac is securely paired.",
            status: "preview",
            at: nowMs + 1
        ))
        sessions[index].turns = turns
        sessions[index].summary = clean
        previewReceipt = "Preview only: prompt added locally"
    }
}
