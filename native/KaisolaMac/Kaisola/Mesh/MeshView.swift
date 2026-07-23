import SwiftUI

/// The Mesh surface: one composer fanning a prompt to every agent column;
/// side-by-side streaming transcripts; per-column status, inline permission
/// answers, and a worktree diff sheet for judging each agent's edits.
struct MeshView: View {
    @ObservedObject var mesh: MeshSession
    @State private var draft = ""
    @State private var diffColumnID: String?
    @State private var diffText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if mesh.columns.isEmpty {
                ProgressView("Starting agents…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(mesh.columns.enumerated()), id: \.element.id) { index, column in
                        if index > 0 { Divider() }
                        MeshColumnView(column: column) {
                            diffColumnID = column.id
                        }
                    }
                }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: Binding(
            get: { diffColumnID.map(DiffSheetID.init) },
            set: { diffColumnID = $0?.id }
        )) { sheet in
            VStack(spacing: 0) {
                HStack {
                    Text("Worktree diff — \(mesh.columns.first { $0.id == sheet.id }?.agent.name ?? "")")
                        .font(.headline)
                    Spacer()
                    Button("Done") { diffColumnID = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
                Divider()
                ScrollView {
                    UnifiedPatchView(patch: diffText.isEmpty ? "No changes yet." : diffText)
                        .padding(12)
                }
            }
            .frame(width: 640, height: 480)
            .task { diffText = await mesh.diff(for: sheet.id) }
        }
    }

    private struct DiffSheetID: Identifiable {
        let id: String
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.purple)
            Text(mesh.title).font(.subheadline.weight(.medium))
            if mesh.anyRunning {
                ProgressView().controlSize(.small)
            }
            if let note = mesh.isolationNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Text("\(mesh.columns.count) agents")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Send to every agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Fan this prompt out to every column")
        }
        .padding(12)
        .background(.bar)
    }

    private func send() {
        mesh.send(draft)
        draft = ""
    }
}

/// One agent's column: status, streaming transcript, inline permission answers,
/// and the worktree diff affordance.
private struct MeshColumnView: View {
    let column: MeshSession.Column
    let showDiff: () -> Void
    @ObservedObject private var conversation: AcpConversation

    init(column: MeshSession.Column, showDiff: @escaping () -> Void) {
        self.column = column
        self.showDiff = showDiff
        self.conversation = column.conversation
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: column.agent.symbol).foregroundStyle(.purple)
                Text(column.agent.name).font(.callout.weight(.semibold))
                Circle()
                    .fill(conversation.isRunning ? Color.accentColor : (conversation.isConnected ? .green : .secondary))
                    .frame(width: 6, height: 6)
                Spacer()
                if column.worktreePath != nil {
                    Button("Diff", action: showDiff)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("This column's isolated worktree diff vs HEAD")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.quaternary.opacity(0.3))
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let status = conversation.statusMessage {
                            Label(status, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(conversation.rows) { row in
                            TranscriptRowView(
                                row: row,
                                retry: { conversation.retryFailed($0) },
                                terminalSnapshot: { [weak conversation] id in await conversation?.terminalSnapshot(id) }
                            )
                            .id(row.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: conversation.rows.count) { _, _ in
                    if let last = conversation.rows.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if let permission = conversation.pendingPermission {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(permission.title, systemImage: "hand.raised.fill")
                        .font(.caption).lineLimit(2)
                        .foregroundStyle(.orange)
                    HStack(spacing: 6) {
                        ForEach(permission.options) { option in
                            Button(option.name) { conversation.answerPermission(option.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(option.kind.contains("reject") ? .red : .accentColor)
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A raw unified diff with the standard +/− tinting (shared Mesh/diff-sheet
/// rendering).
struct UnifiedPatchView: View {
    let patch: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tint(for: line))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func tint(for line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }
}
