import Foundation
import XCTest
@testable import KaisolaMacPreview

/// Covers only the pure, deterministic surface of `NotificationBridge`: the
/// persisted enable flag and the `post()` gate. The real UserNotifications path
/// is never exercised here — `UNUserNotificationCenter.current()` traps in the
/// unbundled test host, so every test either stays behind the enable/background
/// guards or installs `postHook` (which returns before any UN access).
@MainActor
final class NotificationBridgeTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "kaisola-notification-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - enabled flag

    func testEnabledDefaultsToTrue() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        XCTAssertTrue(bridge.enabled)
    }

    func testEnabledPersistsRoundTrip() {
        let defaults = makeDefaults()
        let bridge = NotificationBridge(defaults: defaults)
        XCTAssertTrue(bridge.enabled)

        bridge.enabled = false
        let reloaded = NotificationBridge(defaults: defaults)
        XCTAssertFalse(reloaded.enabled)

        reloaded.enabled = true
        let reloadedAgain = NotificationBridge(defaults: defaults)
        XCTAssertTrue(reloadedAgain.enabled)
    }

    // MARK: - post() gate

    func testPostRecordsWhenBackgroundAndEnabled() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        bridge.appIsActiveProvider = { false }   // app in the background
        var recorded: [NotificationBridge.PostRequest] = []
        bridge.postHook = { recorded.append($0) }

        bridge.post(kind: .permission, title: "Needs you", detail: "Approve edit", targetID: "chat-42")

        XCTAssertEqual(recorded, [
            NotificationBridge.PostRequest(
                identifier: "chat-42",
                categoryID: NotificationBridge.Category.permission.rawValue,
                title: "Needs you",
                body: "Approve edit"
            )
        ])
    }

    func testPostSuppressedWhenDisabled() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        bridge.enabled = false
        bridge.appIsActiveProvider = { false }   // background, but notifications off
        var recorded: [NotificationBridge.PostRequest] = []
        bridge.postHook = { recorded.append($0) }

        bridge.post(kind: .turnCompleted, title: "Done", detail: "Turn finished", targetID: "term-1")

        XCTAssertTrue(recorded.isEmpty)
    }

    func testPostSuppressedWhenAppActive() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        bridge.appIsActiveProvider = { true }    // Kaisola is frontmost
        var recorded: [NotificationBridge.PostRequest] = []
        bridge.postHook = { recorded.append($0) }

        bridge.post(kind: .sessionResponded, title: "Agent", detail: "Responded", targetID: "term-2")

        XCTAssertTrue(recorded.isEmpty)
    }

    func testPostSuppressedWhenAppStateUnknown() {
        let bridge = NotificationBridge(defaults: makeDefaults())
        bridge.appIsActiveProvider = { nil }     // can't confirm background ⇒ don't post
        var recorded: [NotificationBridge.PostRequest] = []
        bridge.postHook = { recorded.append($0) }

        bridge.post(kind: .permission, title: "x", detail: "y", targetID: "z")

        XCTAssertTrue(recorded.isEmpty)
    }

    func testCategoryCoversEveryAttentionKind() {
        XCTAssertEqual(NotificationBridge.Category(.permission), .permission)
        XCTAssertEqual(NotificationBridge.Category(.turnCompleted), .turnCompleted)
        XCTAssertEqual(NotificationBridge.Category(.sessionResponded), .sessionResponded)
    }
}
