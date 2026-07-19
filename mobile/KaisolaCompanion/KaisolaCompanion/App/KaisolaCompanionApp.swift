import SwiftUI

@main
struct KaisolaCompanionApp: App {
    @StateObject private var auth = KaisolaCompanionApp.makeAuth()
    @StateObject private var coordinator = CompanionConnectionCoordinator()
    @StateObject private var previewStore = CompanionStore.preview()

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environmentObject(Self.usePreview ? previewStore : coordinator.store)
                .environmentObject(auth)
                .environmentObject(coordinator)
                .tint(KaisolaTheme.accent)
                .task {
                    await auth.restore()
                    if !Self.usePreview { await coordinator.connectIfPaired() }
                }
        }
    }

    /// Screenshot/dev path uses canned data and skips the live connection.
    static var usePreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["KAISOLA_UI_PREVIEW"] == "1"
        #else
        return false
        #endif
    }

    /// Production signs in through Firebase (Identity Toolkit REST). Launching
    /// with KAISOLA_UI_PREVIEW=1 uses a scripted signed-in backend so the whole
    /// experience is screenshottable without a live Google OAuth round trip.
    @MainActor private static func makeAuth() -> AuthModel {
        #if DEBUG
        if usePreview { return AuthModel.previewSignedIn() }
        #endif
        return AuthModel(backend: FirebaseAuthBackend())
    }
}
