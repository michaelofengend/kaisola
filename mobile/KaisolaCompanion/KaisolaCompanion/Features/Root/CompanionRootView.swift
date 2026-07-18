import SwiftUI

/// The app shell: gate on auth, then a three-tab structure (Home / Sessions /
/// Settings) with the agent transcript and terminal pushed onto the stack.
struct CompanionRootView: View {
    enum Tab: Hashable { case home, sessions, settings }

    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var auth: AuthModel
    @State private var selection: Tab = .home
    @State private var homePath = NavigationPath()
    @State private var sessionsPath = NavigationPath()

    var body: some View {
        Group {
            switch auth.phase {
            case .restoring:
                SplashView()
            case .signedIn:
                signedInShell
                    .transition(.opacity)
            default:
                SignInView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: auth.isSignedIn)
    }

    private var signedInShell: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $homePath) {
                HomeView(
                    onOpenSession: { pushSession($0, into: .home) },
                    onOpenPermission: { openPermission($0) }
                )
                .navigationDestination(for: CompanionSession.self) { destination(for: $0) }
                .navigationDestination(for: CompanionPermission.self) { PermissionDetailView(permission: $0) }
            }
            .tabItem { Label("Home", systemImage: "square.grid.2x2") }
            .tag(Tab.home)

            NavigationStack(path: $sessionsPath) {
                SessionsView()
                    .navigationDestination(for: CompanionSession.self) { destination(for: $0) }
            }
            .tabItem { Label("Sessions", systemImage: "list.bullet") }
            .tag(Tab.sessions)

            NavigationStack {
                CompanionSettingsView()
            }
            .tabItem { Label("Settings", systemImage: "person.crop.circle") }
            .badge(0)
            .tag(Tab.settings)
        }
        .tint(KaisolaTheme.accent)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .overlay(alignment: .bottom) { receiptToast }
    }

    private func pushSession(_ session: CompanionSession, into tab: Tab) {
        if tab == .home { homePath.append(session) } else { sessionsPath.append(session) }
    }
    private func openPermission(_ permission: CompanionPermission) {
        homePath.append(permission)
    }

    @ViewBuilder private func destination(for session: CompanionSession) -> some View {
        switch session.kind {
        case .terminal: TerminalSessionView(sessionId: session.id)
        default: AgentSessionView(sessionId: session.id)
        }
    }

    @ViewBuilder private var receiptToast: some View {
        if let receipt = store.previewReceipt {
            HStack(spacing: 9) {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(KaisolaTheme.done)
                Text(receipt).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5) }
            .padding(.bottom, 62)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.2))
                    withAnimation(.smooth) { store.previewReceipt = nil }
                }
            }
        }
    }
}

/// Brief launch state while the Keychain refresh token is checked.
struct SplashView: View {
    var body: some View {
        ZStack {
            AmbientBackdrop()
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [KaisolaTheme.electric, KaisolaTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay { Image(systemName: "square.grid.2x2.fill").font(.system(size: 27, weight: .medium)).foregroundStyle(KaisolaTheme.darkFrame) }
                .shadow(color: KaisolaTheme.accent.opacity(0.4), radius: 20, y: 8)
        }
    }
}

#Preview("Signed in") {
    CompanionRootView()
        .environmentObject(CompanionStore.preview())
        .environmentObject(AuthModel.previewSignedIn())
}

#Preview("Signed out") {
    CompanionRootView()
        .environmentObject(CompanionStore.preview())
        .environmentObject(AuthModel.previewSignedOut())
}
