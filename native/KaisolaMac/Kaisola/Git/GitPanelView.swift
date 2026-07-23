import SwiftUI

/// A compact Git panel: branch + ahead/behind, staged / unstaged / untracked
/// files with one-click stage/unstage, and a commit box. Backed by GitService
/// (git as a child process); refreshes on demand.
@MainActor
final class GitPanelModel: ObservableObject {
    @Published private(set) var status: GitService.Status?
    @Published private(set) var errorMessage: String?
    @Published var commitMessage = ""
    @Published private(set) var isBusy = false

    let repoRoot: URL
    private let service: GitService

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
        self.service = GitService(repoRoot: repoRoot)
    }

    func refresh() {
        perform { try $0.status() } apply: { self.status = $0 }
    }

    func stage(_ path: String) {
        perform { try $0.stage(path: path); return try $0.status() } apply: { self.status = $0 }
    }

    func unstage(_ path: String) {
        perform { try $0.unstage(path: path); return try $0.status() } apply: { self.status = $0 }
    }

    func commit() {
        let message = commitMessage
        perform { (try $0.commit(message: message), try $0.status()) } apply: {
            self.status = $0.1
            self.commitMessage = ""
            ToastCenter.shared.show("Committed \($0.0.prefix(7))", style: .success)
        }
    }

    /// Diffs revealed inline per file, keyed by path.
    @Published private(set) var diffs: [String: String] = [:]
    /// Recent history (lazy, shown at the panel's foot).
    @Published private(set) var log: [GitService.Commit] = []

    func toggleDiff(_ path: String, staged: Bool) {
        if diffs[path] != nil {
            diffs[path] = nil
            return
        }
        perform { try $0.diff(path: path, staged: staged) } apply: { patch in
            self.diffs[path] = patch.isEmpty ? "No changes." : patch
        }
    }

    func loadLog() {
        perform { try $0.log(limit: 10) } apply: { self.log = $0 }
    }

    /// Discard unstaged changes to a file (destructive; confirmed by the view).
    func restore(_ path: String) {
        perform { try $0.restoreFile(path: path); return try $0.status() } apply: {
            self.status = $0
            self.diffs[path] = nil
        }
    }

    /// Run a git operation off the main actor (git blocks), then apply its
    /// Sendable result back on the main actor. GitService and Status are
    /// Sendable, so nothing unsafe crosses the boundary.
    private func perform<T: Sendable>(
        _ work: @escaping @Sendable (GitService) throws -> T,
        apply: @escaping @MainActor (T) -> Void
    ) {
        isBusy = true
        errorMessage = nil
        let service = self.service
        Task {
            do {
                let value = try await Task.detached { try work(service) }.value
                apply(value)
                isBusy = false
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isBusy = false
            }
        }
    }
}

struct GitPanelView: View {
    @StateObject private var model: GitPanelModel
    @State private var restoreCandidate: String?

    init(repoRoot: URL) {
        _model = StateObject(wrappedValue: GitPanelModel(repoRoot: repoRoot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            } else if let status = model.status {
                content(status)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { model.refresh() }
        .confirmationDialog(
            "Discard changes?",
            isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } })
        ) {
            Button("Discard Changes", role: .destructive) {
                if let restoreCandidate { model.restore(restoreCandidate) }
                restoreCandidate = nil
            }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: {
            Text("Unstaged changes to \((restoreCandidate as NSString?)?.lastPathComponent ?? "this file") are discarded permanently (git restore).")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
            Text(model.status?.branch ?? "—").font(.subheadline.weight(.medium))
            if let s = model.status, s.ahead > 0 { Text("↑\(s.ahead)").font(.caption).foregroundStyle(.secondary) }
            if let s = model.status, s.behind > 0 { Text("↓\(s.behind)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    @ViewBuilder
    private func content(_ status: GitService.Status) -> some View {
        if status.isClean {
            VStack(spacing: 0) {
                ContentUnavailableView("Working tree clean", systemImage: "checkmark.seal")
                logSection
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    fileSection("Staged", status.staged.map { ($0.path, $0.code) }, action: "Unstage", staged: true) { model.unstage($0) }
                    fileSection("Changes", status.unstaged.map { ($0.path, $0.code) }, action: "Stage", staged: false, restorable: true) { model.stage($0) }
                    fileSection("Untracked", status.untracked.map { ($0, "?") }, action: "Stage", staged: false) { model.stage($0) }
                    logSection
                }
                .padding(12)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Commit message…", text: $model.commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.commit() }
                Button("Commit") { model.commit() }
                    .disabled(model.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || status.staged.isEmpty || model.isBusy)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("History")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.log.isEmpty ? "Show" : "Refresh") { model.loadLog() }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.top, 8)
            ForEach(model.log) { commit in
                HStack(spacing: 8) {
                    Text(commit.shortHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(commit.subject).font(.caption).lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, model.status?.isClean == true ? 12 : 0)
    }

    @ViewBuilder
    private func fileSection(
        _ title: String,
        _ files: [(String, String)],
        action: String,
        staged: Bool,
        restorable: Bool = false,
        perform: @escaping (String) -> Void
    ) -> some View {
        if !files.isEmpty {
            Text("\(title) (\(files.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(files, id: \.0) { path, code in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(code).font(.caption.monospaced()).foregroundStyle(color(code)).frame(width: 14)
                        Button {
                            model.toggleDiff(path, staged: staged)
                        } label: {
                            HStack(spacing: 4) {
                                Text((path as NSString).lastPathComponent).lineLimit(1)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show the diff")
                        Spacer()
                        if restorable {
                            Button("Discard") { restoreCandidate = path }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Button(action) { perform(path) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    if let patch = model.diffs[path] {
                        PatchText(patch: patch)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func color(_ code: String) -> Color {
        switch code {
        case "M": .orange
        case "A": .green
        case "D": .red
        case "?": .secondary
        default: .primary
        }
    }
}

/// A raw unified diff, tinted per line (+ green, − red, @@ blue), horizontally
/// scrollable so long lines never wrap into noise.
private struct PatchText: View {
    let patch: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tint(for: line))
                        .textSelection(.enabled)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 200)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func tint(for line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }
}
