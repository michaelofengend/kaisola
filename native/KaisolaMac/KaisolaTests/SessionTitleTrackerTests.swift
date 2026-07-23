import Foundation
import XCTest
@testable import KaisolaMacPreview

/// The pure OSC-title rules (`SessionTitleTracker`) plus the store extension
/// that lands a live title on disk (`NativeSessionStore.applyAutoTitle` /
/// `hasCustomTitle`), the latter over a throwaway file exactly like
/// `NativeSessionStoreTests`.
final class SessionTitleTrackerTests: XCTestCase {

    // MARK: - Sanitization

    func testSanitizeTrimsCollapsesAndStripsControlCharacters() {
        // Leading control bytes, an interior BEL/ESC, tabs and newlines: all
        // become single spaces, runs collapse, ends trim — words stay separate.
        let raw = "\u{01}\u{02}Build\u{07}  step\n\n\tdone\u{1b} "
        XCTAssertEqual(SessionTitleTracker.autoTitle(fromOSC: raw, agentName: nil, folder: "proj"),
                       "Build step done")
    }

    func testSanitizeCaps200CharacterTitleAt60() {
        let raw = String(repeating: "a", count: 200)
        let result = SessionTitleTracker.autoTitle(fromOSC: raw, agentName: nil, folder: "proj")
        XCTAssertEqual(result?.count, 60)
        XCTAssertEqual(result, String(repeating: "a", count: 60))
    }

    func testEmptyAndWhitespaceOnlyTitlesAreNil() {
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "", agentName: nil, folder: "proj"))
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "   \t\n ", agentName: nil, folder: "proj"))
        // Control characters with nothing printable also collapse to nothing.
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "\u{01}\u{07}\u{1b}", agentName: nil, folder: "proj"))
    }

    // MARK: - Generic titles

    func testGenericShellTitlesAreNil() {
        for generic in ["zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish"] {
            XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: generic, agentName: nil, folder: "proj"),
                         "\(generic) should be treated as a generic shell title")
        }
        // Case-insensitive, and even for an agent session (the agent's creation
        // default already covers a bare-shell title).
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "ZSH", agentName: "Claude", folder: "proj"))
    }

    func testFolderOnlyTitleIsNilCaseInsensitively() {
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "Kaisola", agentName: nil, folder: "Kaisola"))
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "KAISOLA", agentName: nil, folder: "kaisola"))
    }

    // MARK: - Agent prefixing

    func testAgentSessionGetsAgentPrefix() {
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromOSC: "building feature", agentName: "Claude", folder: "app"),
            "Claude \u{00B7} building feature"
        )
    }

    func testAgentPrefixSkippedWhenTitleAlreadyContainsAgentNameCaseInsensitively() {
        // Exact-case mention.
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromOSC: "Claude is reviewing", agentName: "Claude", folder: "app"),
            "Claude is reviewing"
        )
        // Lowercase mention still counts — no double-prefix.
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromOSC: "running claude now", agentName: "Claude", folder: "app"),
            "running claude now"
        )
    }

    func testPlainShellSessionHasNoPrefix() {
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromOSC: "npm test", agentName: nil, folder: "app"),
            "npm test"
        )
    }

    // MARK: - shouldApply matrix

    func testShouldApplyMatrix() {
        // Fresh, non-identical auto-title on an untouched name → apply.
        XCTAssertTrue(SessionTitleTracker.shouldApply(autoTitle: "A", currentTitle: "B", userRenamed: false))
        // Identical → skip (no churn).
        XCTAssertFalse(SessionTitleTracker.shouldApply(autoTitle: "A", currentTitle: "A", userRenamed: false))
        // User (or a prior live title) owns the name → never overwrite.
        XCTAssertFalse(SessionTitleTracker.shouldApply(autoTitle: "A", currentTitle: "B", userRenamed: true))
        XCTAssertFalse(SessionTitleTracker.shouldApply(autoTitle: "A", currentTitle: "A", userRenamed: true))
    }

    // MARK: - Store extension (temp-file round-trip)

    private func makeStore() -> (NativeSessionStore, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-title-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("native-sessions.json")
        return (NativeSessionStore(fileURL: fileURL), fileURL)
    }

    private func seed(_ store: NativeSessionStore, id: String, title: String) {
        store.upsert(NativeOwnedSession(
            id: id,
            projectID: NativeSessionStore.projectID(forDirectory: "/tmp/app"),
            cwd: "/tmp/app",
            title: title,
            createdAt: 1,
            agentID: "claude-code"
        ))
    }

    func testApplyAutoTitleUpdatesAndPersists() {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        seed(store, id: "term-1", title: "Claude \u{00B7} app")

        store.applyAutoTitle("Claude \u{00B7} building feature", terminalID: "term-1")
        XCTAssertEqual(store.sessions().first { $0.id == "term-1" }?.title, "Claude \u{00B7} building feature")

        // Survives a fresh store instance reading the same file.
        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.sessions().first { $0.id == "term-1" }?.title, "Claude \u{00B7} building feature")
    }

    func testApplyAutoTitleIsNoOpForUnknownTerminal() {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        seed(store, id: "term-1", title: "Claude \u{00B7} app")

        store.applyAutoTitle("ignored", terminalID: "term-does-not-exist")
        XCTAssertEqual(store.sessions().count, 1)
        XCTAssertEqual(store.sessions().first?.title, "Claude \u{00B7} app")
    }

    func testHasCustomTitleTracksDivergenceFromCreationDefault() {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let defaultTitle = "Claude \u{00B7} app"
        seed(store, id: "term-1", title: defaultTitle)

        // Untouched creation default → not custom.
        XCTAssertFalse(store.hasCustomTitle("term-1", defaultTitle: defaultTitle))
        // After any title change, it reads as custom (the documented limitation:
        // a live auto-title is indistinguishable from a manual rename).
        store.applyAutoTitle("Claude \u{00B7} building", terminalID: "term-1")
        XCTAssertTrue(store.hasCustomTitle("term-1", defaultTitle: defaultTitle))
        // Unknown session → nothing to protect.
        XCTAssertFalse(store.hasCustomTitle("term-nope", defaultTitle: defaultTitle))
    }

    /// The end-to-end gating an owned agent session sees on its first real OSC
    /// title: the tracker produces a prefixed name, the store reports the
    /// creation default as not-yet-custom, `shouldApply` says yes, and the new
    /// title lands.
    func testFirstLiveTitleAppliesOverCreationDefault() {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let folder = "app"
        let defaultTitle = "Claude \u{00B7} \(folder)"
        seed(store, id: "term-1", title: defaultTitle)

        guard let auto = SessionTitleTracker.autoTitle(fromOSC: "building feature", agentName: "Claude", folder: folder) else {
            return XCTFail("expected an auto-title")
        }
        let userRenamed = store.hasCustomTitle("term-1", defaultTitle: defaultTitle)
        XCTAssertTrue(SessionTitleTracker.shouldApply(autoTitle: auto, currentTitle: defaultTitle, userRenamed: userRenamed))
        store.applyAutoTitle(auto, terminalID: "term-1")
        XCTAssertEqual(store.sessions().first?.title, "Claude \u{00B7} building feature")
    }
}
