import SwiftUI

struct AgentSessionView: View {
    @EnvironmentObject private var store: CompanionStore
    @Environment(\.colorScheme) private var colorScheme
    let sessionId: String

    private var session: CompanionSession? { store.session(for: sessionId) }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            if let session {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            metaLine(session)
                            ForEach(session.turns ?? []) { turn in
                                TranscriptTurnView(turn: turn).id(turn.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 15)
                        .padding(.top, 8)
                        .padding(.bottom, 74)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: session.turns?.count ?? 0) {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .safeAreaInset(edge: .bottom) { lockedComposer }
            } else {
                ContentUnavailableView("Session ended", systemImage: "sparkle.slash")
            }
        }
        .navigationTitle(session?.title ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session { StatusBadge(status: session.status) }
            }
        }
    }

    private func metaLine(_ session: CompanionSession) -> some View {
        HStack(spacing: 6) {
            if let provider = session.provider { Text(provider).foregroundStyle(KaisolaTheme.accent) }
            ForEach([session.model, session.mode, session.branch].compactMap { $0 }, id: \.self) { part in
                Text("·"); Text(part)
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 2)
    }

    // Read-only alpha: a real-looking composer that is clearly not yet typable.
    private var lockedComposer: some View {
        HStack(spacing: 10) {
            Text("Message \(session?.provider ?? "the agent")…")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            Label("Controlled from your Mac", systemImage: "lock.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Composer locked. Control this session from your Mac.")
    }
}

private struct TranscriptTurnView: View {
    let turn: CompanionTurn
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(turn.text)
                    .font(.subheadline)
                    .foregroundStyle(KaisolaTheme.darkFrame)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(KaisolaTheme.accent, in: BubbleShape(tail: .trailing))
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(turn.text)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if turn.status == "streaming" {
                        HStack(spacing: 5) {
                            PulseDot(color: KaisolaTheme.running, size: 4)
                            Text("working").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KaisolaTheme.panel(for: colorScheme), in: BubbleShape(tail: .leading))
                .overlay { BubbleShape(tail: .leading).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
                Spacer(minLength: 32)
            }
        case .thought, .tool:
            ToolPill(turn: turn)
        }
    }
}

private struct ToolPill: View {
    let turn: CompanionTurn
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var isThought: Bool { turn.role == .thought }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: isThought ? "brain" : "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isThought ? KaisolaTheme.info : KaisolaTheme.done)
                    Text(isThought ? "Reasoning" : firstLine)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(turn.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
    }

    private var firstLine: String {
        turn.text.split(separator: "\n").first.map(String.init) ?? "Tool result"
    }
}

/// A chat bubble with one squared-off corner on the tail side.
private struct BubbleShape: Shape {
    enum Tail { case leading, trailing }
    let tail: Tail
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 15, small: CGFloat = 5
        let tl = tail == .leading ? small : r
        let bl = tail == .leading ? small : r
        let tr = tail == .trailing ? small : r
        let br = tail == .trailing ? small : r
        return Path { p in
            p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
            p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
            p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
            p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
    }
}

#Preview {
    let store = CompanionStore.preview()
    return NavigationStack {
        if let agent = store.sessions.first(where: { $0.kind == .agent }) {
            AgentSessionView(sessionId: agent.id)
        } else { Text("no agent") }
    }
    .environmentObject(store)
}
