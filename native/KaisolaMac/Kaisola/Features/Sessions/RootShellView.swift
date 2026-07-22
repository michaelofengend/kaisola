import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.selectedSessionID },
                set: { id in Task { await model.select(id) } }
            )) {
                ForEach(model.projects, id: \.name) { project in
                    Section(project.name) {
                        ForEach(project.sessions) { session in
                            SessionRow(session: session)
                                .tag(Optional(session.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 235, max: 300)
            .safeAreaInset(edge: .bottom) {
                ConnectionFooter(state: model.connectionState) {
                    Task { await model.reload() }
                }
            }
            .accessibilityLabel("Projects and terminal sessions")
        } detail: {
            VStack(spacing: 0) {
                StatusBar(state: model.connectionState)
                Divider()
                terminalContent
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var terminalContent: some View {
        if let message = model.terminalDocument.errorMessage {
            ContentUnavailableView(
                "Terminal unavailable",
                systemImage: "terminal",
                description: Text(message)
            )
        } else if model.terminalDocument.sessionID == nil {
            ContentUnavailableView(
                model.sessions.isEmpty ? "No observable sessions" : "Choose a terminal",
                systemImage: "terminal",
                description: Text("Electron remains the controller. This preview only observes durable output.")
            )
        } else {
            ZStack(alignment: .topTrailing) {
                NativeTerminalSurface(
                    output: model.terminalDocument.output,
                    streamEpoch: model.terminalDocument.cursor?.streamEpoch,
                    endOffset: model.terminalDocument.cursor?.offset
                )
                if model.terminalDocument.truncated {
                    Label("Retained tail", systemImage: "ellipsis.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .accessibilityLabel("Older terminal output was outside the retained history")
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: BrokerTerminalRecord

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal")
                .foregroundStyle(session.exited ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(session.exited ? "Finished" : "Live · PID \(session.pid.map(String.init) ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusBar: View {
    let state: AppModel.ConnectionState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.isConnected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(state.title)
                .font(.subheadline.weight(.medium))
            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Label("Read only", systemImage: "eye")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("Terminal access is read only")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
}

private struct ConnectionFooter: View {
    let state: AppModel.ConnectionState
    let reload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Native preview")
                    .font(.caption.weight(.semibold))
                Text(state.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reconnect without changing terminal ownership")
            .accessibilityLabel("Reconnect to terminal broker")
        }
        .padding(12)
        .background(.bar)
    }
}
