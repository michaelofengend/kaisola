import SwiftUI

/// The ACP conversation surface: streaming messages, thinking blocks,
/// tool-call cards, a plan, a live permission prompt, model picker, usage, and
/// a composer. Mirrors the Electron Assistant transcript.
struct AcpChatView: View {
    @State private var restoreTarget: AcpConversation.TurnCheckpoint?
    @ObservedObject var conversation: AcpConversation
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let permission = conversation.pendingPermission {
                PermissionBar(
                    request: permission,
                    allowsRule: conversation.pendingPermissionAllowsRule,
                    answer: { conversation.answerPermission($0) },
                    always: { conversation.answerPermissionAlways() }
                )
            }
            Divider()
            composer
        }
        .task {
            draft = conversation.loadDraft()
            await conversation.start()
        }
        .onChange(of: draft) { _, newValue in
            conversation.saveDraft(newValue)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(conversation.isConnected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(conversation.title).font(.subheadline.weight(.medium))
            if conversation.isRunning {
                ProgressView().controlSize(.small)
                Text("Working…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !conversation.modes.isEmpty {
                Picker("Mode", selection: Binding(
                    get: { conversation.currentModeID ?? conversation.modes.first?.id ?? "" },
                    set: { conversation.selectMode($0) }
                )) {
                    ForEach(conversation.modes) { mode in
                        Text(mode.name).tag(mode.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
                .help("Permission mode — how the agent asks before acting")
            }
            if !conversation.models.isEmpty {
                Picker("Model", selection: Binding(
                    get: { conversation.currentModelID ?? conversation.models.first?.id ?? "" },
                    set: { conversation.selectModel($0) }
                )) {
                    ForEach(conversation.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            if !conversation.checkpoints.isEmpty {
                Menu {
                    Text("Restore the working tree to before a turn:")
                    ForEach(conversation.checkpoints.reversed()) { checkpoint in
                        Button("Turn \(checkpoint.turn) — \(checkpoint.at.formatted(date: .omitted, time: .shortened))") {
                            restoreTarget = checkpoint
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pre-turn checkpoints (git snapshots)")
                .confirmationDialog(
                    "Restore checkpoint?",
                    isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })
                ) {
                    Button("Restore Files", role: .destructive) {
                        if let restoreTarget { conversation.restoreCheckpoint(restoreTarget.id) }
                        restoreTarget = nil
                    }
                    Button("Cancel", role: .cancel) { restoreTarget = nil }
                } message: {
                    Text("Applies the snapshot taken before turn \(restoreTarget?.turn ?? 0) over the current working tree. Conflicts surface as git conflict markers.")
                }
            }
            if !conversation.configOptions.isEmpty {
                Menu {
                    ForEach(conversation.configOptions) { option in
                        Picker(option.name, selection: Binding(
                            get: { option.currentValue ?? option.choices.first?.value ?? "" },
                            set: { conversation.selectConfigOption(option.id, value: $0) }
                        )) {
                            ForEach(option.choices) { choice in
                                Text(choice.name).tag(choice.value)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Agent options (effort, presets)")
            }
            if let usage = conversation.usage {
                Text("\(usage.used / 1000)k / \(usage.max / 1000)k")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let status = conversation.statusMessage {
                        Label(status, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if conversation.hiddenEarlierCount > 0 {
                        Button {
                            conversation.expandEarlier()
                        } label: {
                            Label("Show earlier messages (\(conversation.hiddenEarlierCount) more)", systemImage: "chevron.up")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                        .help("Render 200 more earlier messages (full history is always kept)")
                    }
                    ForEach(conversation.visibleRows) { row in
                        TranscriptRowView(
                            row: row,
                            retry: { conversation.retryFailed($0) },
                            terminalSnapshot: { [weak conversation] id in await conversation?.terminalSnapshot(id) }
                        )
                        .id(row.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation.rows.count) { _, _ in
                if let last = conversation.rows.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// Slash commands matching the draft's leading "/query", ranked by FuzzyMatch.
    private var matchingCommands: [AcpCommand] {
        guard draft.hasPrefix("/"), !conversation.commands.isEmpty else { return [] }
        let query = String(draft.dropFirst()).trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return conversation.commands }
        return conversation.commands
            .compactMap { command -> (AcpCommand, Int)? in
                FuzzyMatch.score(query: query, candidate: command.name).map { (command, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !matchingCommands.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingCommands.prefix(6)) { command in
                        Button {
                            draft = "/\(command.name) "
                        } label: {
                            HStack(spacing: 8) {
                                Text("/\(command.name)").font(.caption.monospaced().weight(.semibold))
                                Text(command.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if !conversation.queued.isEmpty {
                queuedStrip
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(conversation.isRunning ? "Queue a follow-up…" : "Message the agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit(sendDraft)
                if conversation.isRunning {
                    Button(action: conversation.cancel) {
                        Image(systemName: "stop.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop the current turn")
                }
                Button(action: sendDraft) {
                    Image(systemName: conversation.isRunning ? "text.badge.plus" : "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !conversation.isConnected)
                .help(conversation.isRunning ? "Queue this as a follow-up" : "Send")
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var queuedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(conversation.queued) { message in
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                    Text(message.text).font(.caption).lineLimit(1)
                    Spacer()
                    Button {
                        conversation.steerQueued(message.id)
                    } label: {
                        Image(systemName: "bolt.fill").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help("Steer: interrupt the current turn and send this now")
                    Button {
                        conversation.removeQueued(message.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this queued follow-up")
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        conversation.send(text)
    }
}

struct TranscriptRowView: View {
    let row: AcpTranscriptRow
    var retry: ((String) -> Void)?
    var terminalSnapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?

    var body: some View {
        switch row {
        case let .user(_, text, failed):
            HStack(spacing: 8) {
                Spacer(minLength: 40)
                if failed {
                    Button {
                        retry?(row.id)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help("This message failed to send — try again")
                }
                Text(text)
                    .padding(10)
                    .background(
                        failed ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay {
                        if failed {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(.red.opacity(0.5))
                        }
                    }
                    .textSelection(.enabled)
            }
        case let .message(_, text):
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .thought(_, text):
            DisclosureGroup {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case let .tool(call):
            ToolCallCard(call: call, terminalSnapshot: terminalSnapshot)
        case let .plan(_, entries):
            PlanCard(entries: entries)
        }
    }
}

struct ToolCallCard: View {
    let call: AcpToolCall
    var terminalSnapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?
    @State private var expanded = false

    private var hasArtifacts: Bool { !call.content.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if hasArtifacts { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                    Text(call.title).lineLimit(1)
                    Spacer()
                    if hasArtifacts {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(call.kind).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasArtifacts)

            if !call.locations.isEmpty {
                Text(call.locations.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            if expanded {
                ForEach(call.content) { artifact in
                    switch artifact {
                    case let .diff(path, oldText, newText):
                        DiffView(path: path, oldText: oldText, newText: newText)
                    case let .text(text):
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    case let .terminal(id):
                        TerminalContentView(terminalID: id, snapshot: terminalSnapshot)
                    }
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusSymbol: String {
        switch call.status {
        case .pending, .inProgress: "gearshape"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .pending, .inProgress: .secondary
        case .completed: .green
        case .failed: .red
        }
    }
}

/// Live output of an agent-spawned terminal inside a tool card: polls the
/// AcpTerminalHost snapshot until the process exits.
struct TerminalContentView: View {
    let terminalID: String
    var snapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?
    @State private var output = ""
    @State private var exitText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.caption2)
                Text(exitText ?? "Running…").font(.caption2)
                Spacer()
            }
            .foregroundStyle(exitText == nil ? Color.orange : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6))
            ScrollView {
                Text(output.isEmpty ? " " : output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(.black.opacity(0.18))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .task(id: terminalID) {
            while !Task.isCancelled {
                guard let snap = await snapshot?(terminalID) else { break }
                output = snap.output
                if let status = snap.exitStatus {
                    exitText = status.exitCode.map { "Exited (\($0))" }
                        ?? status.signal.map { "Killed (\($0))" }
                        ?? "Exited"
                    break
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }
}

/// A compact unified diff for a tool-call file edit: removed lines tinted red,
/// added lines tinted green, mirroring the Electron chat's inline diff card.
struct DiffView: View {
    let path: String
    let oldText: String?
    let newText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((path as NSString).lastPathComponent)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(AcpDiff.lines(old: oldText ?? "", new: newText).enumerated()), id: \.offset) { _, line in
                        Text(line.kind.prefix + line.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 1)
                            .background(tint(for: line.kind))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func tint(for kind: AcpDiff.LineKind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: .red.opacity(0.18)
        case .added: .green.opacity(0.18)
        }
    }
}

struct PlanCard: View {
    let entries: [AcpPlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Plan", systemImage: "checklist").font(.caption.weight(.semibold))
            ForEach(entries) { entry in
                HStack(spacing: 7) {
                    Image(systemName: entry.status == "completed" ? "checkmark.square" : "square")
                        .foregroundStyle(entry.status == "completed" ? .green : .secondary)
                    Text(entry.content).strikethrough(entry.status == "completed")
                    Spacer()
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PermissionBar: View {
    let request: AcpPermissionRequest
    let allowsRule: Bool
    let answer: (String) -> Void
    let always: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: allowsRule ? "hand.raised.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(allowsRule ? .orange : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.callout).lineLimit(2)
                if !allowsRule {
                    Text("Sensitive file — always asks").font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            if allowsRule {
                Button("Always allow") { always() }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .help("Allow this and create a standing rule for matching requests")
            }
            ForEach(request.options) { option in
                Button(option.name) { answer(option.id) }
                    .buttonStyle(.bordered)
                    .tint(option.kind.contains("reject") ? .red : .accentColor)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }
}
