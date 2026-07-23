import Foundation
import XCTest
@testable import KaisolaMacPreview

/// NativeSessionStore against a throwaway file — owner identity, owned-session
/// upsert/remove, and the opened-project-tab persistence added for the shell
/// spine's explicit open/rename/close.
final class NativeSessionStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: NativeSessionStore!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-store-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("native-sessions.json")
        store = NativeSessionStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testOwnerIDIsStableAcrossReads() {
        let first = store.ownerID()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, store.ownerID())
    }

    func testProjectIDIsDeterministicAndNamespaced() {
        let path = "/Users/example/Developer/Kaisola"
        let id = NativeSessionStore.projectID(forDirectory: path)
        XCTAssertTrue(id.hasPrefix("nproj_"))
        XCTAssertEqual(id, NativeSessionStore.projectID(forDirectory: path))
        // Distinct from Electron's proj_* namespace by construction.
        XCTAssertFalse(id.hasPrefix("proj_"))
    }

    func testOpenProjectIsIdempotentByDirectory() {
        let path = "/tmp/example-project"
        let a = store.openProject(directory: path)
        let b = store.openProject(directory: path)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(store.projects().count, 1)
        XCTAssertEqual(store.projects().first?.name, "example-project")
    }

    func testOpenProjectPersistsAcrossStoreInstances() {
        let opened = store.openProject(directory: "/tmp/persisted-project")
        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.projects().count, 1)
        // Same normalized path the store recorded survives the round-trip.
        XCTAssertEqual(reopened.projects().first?.path, opened.path)
        XCTAssertEqual(reopened.projects().first?.name, "persisted-project")
    }

    func testRenameProjectUpdatesNameOnly() {
        let project = store.openProject(directory: "/tmp/rename-me")
        store.renameProject(id: project.id, name: "Custom Name")
        let renamed = store.projects().first { $0.id == project.id }
        XCTAssertEqual(renamed?.name, "Custom Name")
        XCTAssertEqual(renamed?.path, project.path)
    }

    func testCloseProjectRemovesTabButLeavesOthers() {
        let keep = store.openProject(directory: "/tmp/keep")
        let drop = store.openProject(directory: "/tmp/drop")
        store.closeProject(id: drop.id)
        let ids = store.projects().map(\.id)
        XCTAssertTrue(ids.contains(keep.id))
        XCTAssertFalse(ids.contains(drop.id))
    }

    func testOpenProjectDoesNotDisturbOwnedSessions() {
        let session = NativeOwnedSession(
            id: "term-1",
            projectID: NativeSessionStore.projectID(forDirectory: "/tmp/with-session"),
            cwd: "/tmp/with-session",
            title: "shell",
            createdAt: 1
        )
        store.upsert(session)
        _ = store.openProject(directory: "/tmp/with-session")
        XCTAssertEqual(store.sessions().count, 1)
        XCTAssertEqual(store.sessions().first?.id, "term-1")
        XCTAssertEqual(store.projects().count, 1)
    }
}
