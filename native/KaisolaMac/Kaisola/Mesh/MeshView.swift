import SwiftUI

/// The Mesh surface: one composer fanning a prompt to every agent column;
/// side-by-side streaming transcripts; per-column status, inline permission
/// answers, and a worktree diff sheet for judging each agent's edits.
struct MeshView: View {
    @ObservedObject var mesh: MeshSession
    @State private var draft = ""
    @State private var diffColumnID: String?
    @State private var diffText = ""
    @State private var integrateColumnID: String?
    @State private var integrationStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let status = integrationStatus {
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isConflictStatus(status) ? .orange : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
            }
            Divider()
            if mesh.columns.isEmpty {
                ProgressView("Starting agents…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(mesh.columns.enumerated()), id: \.element.id) { index, column in
                        if index > 0 { Divider() }
                        MeshColumnView(
                            column: column,
                            showDiff: { diffColumnID = column.id },
                            integrate: { integrateColumnID = column.id }
                        )
                    }
                }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Apply this column's diff to the base workspace?",
            isPresented: Binding(
                get: { integrateColumnID != nil },
                set: { if !$0 { integrateColumnID = nil } }
            ),
            presenting: integrateColumnID
        ) { columnID in
            Button("Apply Diff") { integrate(columnID) }
            Button("Cancel", role: .cancel) { integrateColumnID = nil }
        } message: { _ in
            Text("Grafts this column's edits onto \(mesh.baseDirectory.lastPathComponent) with a 3-way merge. Conflicts leave git markers you'll need to resolve.")
        }
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
            if let chip = headerChip {
                Text(chip)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
            }
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
        let text = draft
        draft = ""
        switch (mesh.purpose, mesh.mode) {
        case (.idea, _): mesh.sendIdea(text)
        case (.build, .staged): mesh.sendStaged(text)
        case (.build, .flat): mesh.send(text)
        }
    }

    /// The header status chip: the run's purpose plus, when a staged/idea
    /// pipeline is active, its current phase. Nil for a plain flat build run.
    private var headerChip: String? {
        switch mesh.purpose {
        case .idea:
            return mesh.stage == "Idle" ? "Idea" : "Idea · \(mesh.stage)"
        case .build:
            return mesh.mode == .staged ? "Staged · \(mesh.stage)" : nil
        }
    }

    /// Fetch the column's worktree diff and graft it onto the base workspace.
    /// Success and conflict/error alike surface in the status line under the
    /// header. Runs on the main actor so the @State write is safe.
    private func integrate(_ columnID: String) {
        let name = mesh.columns.first { $0.id == columnID }?.agent.name ?? "column"
        let base = mesh.baseDirectory
        Task { @MainActor in
            let patch = await mesh.diff(for: columnID)
            guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                integrationStatus = "\(name): no changes to apply."
                return
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try GitService(repoRoot: base).applyPatch(patch)
                }.value
                integrationStatus = "Applied \(name)'s diff to \(base.lastPathComponent)."
            } catch {
                integrationStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func isConflictStatus(_ status: String) -> Bool {
        status.range(of: "conflict", options: .caseInsensitive) != nil
            || status.range(of: "marker", options: .caseInsensitive) != nil
    }
}

/// One agent's column: status, streaming transcript, inline permission answers,
/// and the worktree diff affordance.
private struct MeshColumnView: View {
    let column: MeshSession.Column
    let showDiff: () -> Void
    let integrate: () -> Void
    @ObservedObject private var conversation: AcpConversation

    init(column: MeshSession.Column, showDiff: @escaping () -> Void, integrate: @escaping () -> Void) {
        self.column = column
        self.showDiff = showDiff
        self.integrate = integrate
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
                    Button("Integrate", action: integrate)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Apply this column's diff onto the base workspace")
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
