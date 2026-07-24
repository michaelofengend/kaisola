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

    func testCloseThenReopenRestoresMostRecentProject() {
        let a = store.openProject(directory: "/tmp/alpha")
        let b = store.openProject(directory: "/tmp/beta")
        store.closeProject(id: a.id)
        store.closeProject(id: b.id)
        XCTAssertTrue(store.projects().isEmpty)

        // ⌘⇧T restores newest-first: beta, then alpha.
        let first = store.reopenLastClosedProject()
        XCTAssertEqual(first?.id, b.id)
        XCTAssertEqual(store.projects().map(\.id), [b.id])
        let second = store.reopenLastClosedProject()
        XCTAssertEqual(second?.id, a.id)
        XCTAssertNil(store.reopenLastClosedProject())   // stack drained
    }

    func testReopenPersistsClosedStackAcrossInstances() {
        let a = store.openProject(directory: "/tmp/persisted-closed")
        store.closeProject(id: a.id)
        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.closedProjects().map(\.id), [a.id])
        XCTAssertEqual(reopened.reopenLastClosedProject()?.id, a.id)
    }

    func testReopeningAFolderDirectlyRetiresItsClosedEntry() {
        let a = store.openProject(directory: "/tmp/gamma")
        store.closeProject(id: a.id)
        XCTAssertFalse(store.closedProjects().isEmpty)
        // Opening the same folder again should clear the stale closed entry.
        _ = store.openProject(directory: "/tmp/gamma")
        XCTAssertTrue(store.closedProjects().isEmpty)
    }

    func testClosedSessionStackPushesAndPopsNewestFirst() {
        store.pushClosedSession(ClosedSession(cwd: "/tmp/one", agentID: nil, title: "one"))
        store.pushClosedSession(ClosedSession(cwd: "/tmp/two", agentID: "claude-code", title: "two"))
        let first = store.popClosedSession()
        XCTAssertEqual(first?.cwd, "/tmp/two")
        XCTAssertEqual(first?.agentID, "claude-code")
        XCTAssertEqual(store.popClosedSession()?.cwd, "/tmp/one")
        XCTAssertNil(store.popClosedSession())
    }

    func testClosedSessionStackIsBounded() {
        for index in 0..<15 {
            store.pushClosedSession(ClosedSession(cwd: "/tmp/s\(index)", agentID: nil, title: "s\(index)"))
        }
        XCTAssertEqual(store.closedSessions().count, 10)
        XCTAssertEqual(store.closedSessions().first?.cwd, "/tmp/s5")   // oldest dropped
    }

    func testProjectColorPersistsAndClears() {
        let project = store.openProject(directory: "/tmp/tinted")
        store.setProjectColor(id: project.id, colorHex: "E16A6A")
        XCTAssertEqual(store.projects().first?.colorHex, "E16A6A")
        store.setProjectColor(id: project.id, colorHex: nil)
        XCTAssertNil(store.projects().first?.colorHex)
    }

    func testMoveProjectReordersWithinBounds() {
        let a = store.openProject(directory: "/tmp/order-a")
        let b = store.openProject(directory: "/tmp/order-b")
        _ = store.openProject(directory: "/tmp/order-c")
        store.moveProject(id: b.id, delta: -1)
        XCTAssertEqual(store.projects().map(\.path), ["/tmp/order-b", "/tmp/order-a", "/tmp/order-c"])
        // Out-of-bounds moves are no-ops.
        store.moveProject(id: b.id, delta: -1)
        XCTAssertEqual(store.projects().first?.id, b.id)
        store.moveProject(id: a.id, delta: 5)
        XCTAssertEqual(store.projects().map(\.path), ["/tmp/order-b", "/tmp/order-a", "/tmp/order-c"])
    }

    func testRelocateProjectCarriesNameAndColorToTheNewPath() {
        let project = store.openProject(directory: "/tmp/old-home")
        store.renameProject(id: project.id, name: "My Workspace")
        store.setProjectColor(id: project.id, colorHex: "5AA9E6")
        let relocated = store.relocateProject(id: project.id, toDirectory: "/tmp/new-home")
        XCTAssertEqual(relocated?.name, "My Workspace")
        XCTAssertEqual(relocated?.colorHex, "5AA9E6")
        XCTAssertEqual(store.projects().count, 1)
        XCTAssertEqual(store.projects().first?.path, "/tmp/new-home")
        XCTAssertEqual(store.projects().first?.name, "My Workspace")
        XCTAssertEqual(store.projects().first?.colorHex, "5AA9E6")
        // The old id's closed-stack entry must not resurrect the old path.
        XCTAssertNotEqual(store.projects().first?.id, project.id)
    }

    func testRecentFoldersAreMostRecentFirstDedupedAndBounded() {
        for index in 0..<10 {
            _ = store.openProject(directory: "/tmp/recent-\(index)")
        }
        _ = store.openProject(directory: "/tmp/recent-3")   // re-open moves to head
        let recents = store.recentFolders()
        XCTAssertEqual(recents.first, "/tmp/recent-3")
        XCTAssertEqual(recents.count, 8)
        XCTAssertEqual(recents.filter { $0 == "/tmp/recent-3" }.count, 1)
    }

    func testSelectedSessionPersistsAcrossInstances() {
        _ = store.openProject(directory: "/tmp/sel")   // ensures the file exists
        store.recordSelectedSession("term-abc")
        XCTAssertEqual(NativeSessionStore(fileURL: fileURL).lastSelectedSessionID(), "term-abc")
        store.recordSelectedSession(nil)
        XCTAssertNil(NativeSessionStore(fileURL: fileURL).lastSelectedSessionID())
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

    func testObservedSessionAliasPersistsClearsAndIsRemovedWithSession() {
        store.setSessionAlias("  Build watcher  ", for: "terminal:observed")
        XCTAssertEqual(
            NativeSessionStore(fileURL: fileURL).sessionAliases()["terminal:observed"],
            "Build watcher"
        )
        store.setSessionAlias("   ", for: "terminal:observed")
        XCTAssertNil(store.sessionAliases()["terminal:observed"])

        let session = NativeOwnedSession(
            id: "term-owned",
            projectID: "nproj_alias",
            cwd: "/tmp/alias",
            title: "Alias",
            createdAt: 1
        )
        store.upsert(session)
        store.setSessionAlias("Temporary", for: session.id)
        store.remove(terminalID: session.id)
        XCTAssertNil(store.sessionAliases()[session.id])
    }

    func testRecoverOwnedSessionsRequiresExactStableOwnerAndKnownProject() throws {
        let project = store.openProject(directory: "/tmp/recover-owned")
        let stableOwnerID = store.ownerID()
        let record = BrokerTerminalRecord(
            id: "term-\(project.id)-recovered",
            projectID: project.id,
            pid: 4_321,
            exited: false,
            streamEpoch: "epoch",
            endOffset: 42,
            lastOwnerID: stableOwnerID
        )

        let recovered = store.recoverOwnedSessions(from: [record], now: 123_456)

        let session = try XCTUnwrap(recovered.first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(session.id, record.id)
        XCTAssertEqual(session.projectID, project.id)
        XCTAssertEqual(session.cwd, project.path)
        XCTAssertEqual(session.title, project.name)
        XCTAssertEqual(session.createdAt, 123_456)
        XCTAssertEqual(store.sessions(), recovered)
        XCTAssertTrue(store.recoverOwnedSessions(from: [record]).isEmpty)
    }

    func testRecoverOwnedSessionsRejectsObservedExitedAndUnknownProjectRecords() {
        let project = store.openProject(directory: "/tmp/recover-guarded")
        let stableOwnerID = store.ownerID()
        let observed = BrokerTerminalRecord(
            id: "term-observed",
            projectID: project.id,
            pid: 1,
            exited: false,
            streamEpoch: nil,
            endOffset: 0,
            lastOwnerID: "another-install"
        )
        let exited = BrokerTerminalRecord(
            id: "term-exited",
            projectID: project.id,
            pid: nil,
            exited: true,
            streamEpoch: nil,
            endOffset: 0,
            lastOwnerID: stableOwnerID
        )
        let unknownProject = BrokerTerminalRecord(
            id: "term-unknown-project",
            projectID: "nproj_missing",
            pid: 2,
            exited: false,
            streamEpoch: nil,
            endOffset: 0,
            currentOwnerID: stableOwnerID
        )

        XCTAssertTrue(
            store.recoverOwnedSessions(from: [observed, exited, unknownProject]).isEmpty
        )
        XCTAssertTrue(store.sessions().isEmpty)
    }

    func testWorkspaceRestorationRoundTripsPaneOrderAndAgentDescriptor() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let projectID = "nproj_workspace"
        let chat = NativeRestorableAgentChatDescriptor(
            id: "chat-1",
            projectID: projectID,
            agentID: "claude-code",
            workspacePath: "/tmp/workspace",
            acpSessionID: "acp-session-1",
            title: "Claude · workspace"
        )
        let panes = [
            NativeRestorablePaneState(
                id: "term-live",
                surface: NativeRestorableSurfaceState(
                    kind: .terminal,
                    id: "term-live",
                    projectID: projectID,
                    title: "Build"
                ),
                sizeWeight: 0.65
            ),
            NativeRestorablePaneState(
                id: "chat-1",
                surface: NativeRestorableSurfaceState(agentChat: chat),
                sizeWeight: 0.35
            ),
        ]
        let state = NativeWorkspaceRestorationState(
            selectedProjectID: projectID,
            projects: [
                NativeProjectWorkspaceState(
                    projectID: projectID,
                    layout: SessionPaneLayout(columns: [
                        .init(
                            id: "main-column",
                            sessionIDs: ["term-live", "chat-1"],
                            rowWeights: [0.7, 0.3]
                        ),
                    ]),
                    arrangement: .columns,
                    panes: panes,
                    focusedPaneID: "chat-1",
                    updatedAt: 123
                ),
            ]
        )

        try await workspaceStore.saveRestorationState(state)

        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let restored = try await reopened.restorationState()
        XCTAssertEqual(restored, state)
        XCTAssertEqual(
            restored.projects.first?.panes.last?.surface.agentChatDescriptor,
            chat
        )
        XCTAssertEqual(
            restored.projects.first?.layout.columns.first?.sessionIDs,
            ["term-live", "chat-1"]
        )
        XCTAssertEqual(
            restored.projects.first?.layout.columns.first?.rowWeights,
            [0.7, 0.3]
        )
    }

    func testWorkspaceRestorationDoesNotMutateBrokerOwnedSessions() async throws {
        let project = store.openProject(directory: "/tmp/durable-terminal")
        let session = NativeOwnedSession(
            id: "term-detached",
            projectID: project.id,
            cwd: project.path,
            title: "Detached",
            createdAt: 7
        )
        store.upsert(session)

        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: project.id,
                panes: [
                    NativeRestorablePaneState(
                        id: session.id,
                        surface: NativeRestorableSurfaceState(
                            kind: .terminal,
                            id: session.id,
                            projectID: project.id
                        )
                    ),
                ]
            ),
            makeSelected: true
        )

        XCTAssertEqual(NativeSessionStore(fileURL: fileURL).sessions(), [session])
    }

    func testWorkspaceRestorationSanitizesInvalidDuplicateAndOversizedPaneState() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let projectID = "nproj_bounded"
        var panes = (0..<(NativeWorkspaceStateStore.maximumPanesPerProject + 3)).map { index in
            NativeRestorablePaneState(
                id: "term-\(index)",
                surface: NativeRestorableSurfaceState(
                    kind: .terminal,
                    id: "term-\(index)",
                    projectID: projectID
                ),
                sizeWeight: index == 0 ? .infinity : 1
            )
        }
        panes.insert(
            NativeRestorablePaneState(
                id: "term-0",
                surface: NativeRestorableSurfaceState(
                    kind: .terminal,
                    id: "term-duplicate-pane",
                    projectID: projectID
                )
            ),
            at: 1
        )
        panes.insert(
            NativeRestorablePaneState(
                id: "chat-invalid",
                surface: NativeRestorableSurfaceState(
                    kind: .agentChat,
                    id: "chat-invalid",
                    projectID: projectID,
                    agentID: "claude-code",
                    workspacePath: "relative/path"
                )
            ),
            at: 2
        )

        try await workspaceStore.saveProjectState(
            NativeProjectWorkspaceState(
                projectID: projectID,
                panes: panes,
                focusedPaneID: "missing-pane",
                updatedAt: 1
            )
        )

        let storedProject = try await workspaceStore.projectState(for: projectID)
        let restored = try XCTUnwrap(storedProject)
        XCTAssertEqual(restored.panes.count, NativeWorkspaceStateStore.maximumPanesPerProject)
        XCTAssertEqual(Set(restored.panes.map(\.id)).count, restored.panes.count)
        XCTAssertEqual(restored.panes.first?.sizeWeight, 1)
        XCTAssertFalse(restored.panes.contains { $0.id == "chat-invalid" })
        XCTAssertNil(restored.focusedPaneID)
    }

    func testProjectWorkspaceStateDecodesSnapshotWrittenBeforePaneLayout() throws {
        let projectID = "nproj_legacy-layout"
        let legacyJSON = """
        {
          "projectID": "\(projectID)",
          "arrangement": "rows",
          "panes": [
            {
              "id": "term-one",
              "surface": {
                "kind": "terminal",
                "id": "term-one",
                "projectID": "\(projectID)"
              },
              "sizeWeight": 1,
              "isMinimized": false
            },
            {
              "id": "term-two",
              "surface": {
                "kind": "terminal",
                "id": "term-two",
                "projectID": "\(projectID)"
              },
              "sizeWeight": 1,
              "isMinimized": false
            }
          ],
          "focusedPaneID": "term-two",
          "updatedAt": 42
        }
        """

        let decoded = try JSONDecoder().decode(
            NativeProjectWorkspaceState.self,
            from: try XCTUnwrap(legacyJSON.data(using: .utf8))
        )

        XCTAssertEqual(decoded.layout.columns.count, 1)
        XCTAssertEqual(decoded.layout.columns.first?.sessionIDs, ["term-one", "term-two"])
        XCTAssertEqual(decoded.focusedPaneID, "term-two")
    }

    func testWorkspaceStoreRefusesToOverwriteNewerSchema() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let futureData = try XCTUnwrap(
            "{\"schemaVersion\":999,\"future\":true}".data(using: .utf8)
        )
        try futureData.write(to: stateURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        do {
            try await workspaceStore.saveRestorationState(NativeWorkspaceRestorationState())
            XCTFail("Expected a newer schema to be preserved")
        } catch {
            XCTAssertEqual(
                error as? NativeWorkspaceStateStore.StoreError,
                .unsupportedSchema(found: 999)
            )
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), futureData)
    }

    func testAgentChatDraftRoundTripsAcrossStoreInstancesAndEmptyTextClearsIt() async throws {
        let stateURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let key = NativeWorkspaceStateStore.agentChatStableKey(
            agentID: "claude-code",
            workspacePath: "/tmp/draft-project/./"
        )

        try await workspaceStore.saveDraft(
            "Unsent follow-up",
            stableKey: key,
            projectID: "nproj_draft",
            agentID: "claude-code",
            workspacePath: "/tmp/draft-project",
            updatedAt: 10
        )

        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let restoredText = try await reopened.draft(for: key)
        XCTAssertEqual(restoredText, "Unsent follow-up")
        let allDrafts = try await reopened.allDrafts()
        let draft = try XCTUnwrap(allDrafts.first)
        XCTAssertEqual(draft.workspacePath, "/tmp/draft-project")
        XCTAssertNotEqual(draft.id, key)

        try await reopened.saveDraft(
            "",
            stableKey: key,
            projectID: "nproj_draft",
            agentID: "claude-code",
            workspacePath: "/tmp/draft-project"
        )
        let clearedText = try await reopened.draft(for: key)
        XCTAssertNil(clearedText)
    }

    func testAgentChatDraftRejectsOversizeWithoutLosingPreviousText() async throws {
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        let key = "claude-code|/tmp/draft-limit"
        try await workspaceStore.saveDraft(
            "keep me",
            stableKey: key,
            projectID: "nproj_limit",
            agentID: "claude-code",
            workspacePath: "/tmp/draft-limit"
        )

        do {
            try await workspaceStore.saveDraft(
                String(repeating: "x", count: NativeWorkspaceStateStore.maximumDraftBytes + 1),
                stableKey: key,
                projectID: "nproj_limit",
                agentID: "claude-code",
                workspacePath: "/tmp/draft-limit"
            )
            XCTFail("Expected an oversized draft to be rejected")
        } catch {
            XCTAssertEqual(
                error as? NativeWorkspaceStateStore.StoreError,
                .draftTooLarge(maxBytes: NativeWorkspaceStateStore.maximumDraftBytes)
            )
        }
        let preservedText = try await workspaceStore.draft(for: key)
        XCTAssertEqual(preservedText, "keep me")
    }

    func testAgentChatDraftArchiveEvictsOldestEntriesAtBound() async throws {
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        for index in 0...NativeWorkspaceStateStore.maximumDrafts {
            try await workspaceStore.saveDraft(
                "draft \(index)",
                stableKey: "agent|/tmp/project-\(index)",
                projectID: "nproj_\(index)",
                agentID: "agent",
                workspacePath: "/tmp/project-\(index)",
                updatedAt: Int64(index)
            )
        }

        let drafts = try await workspaceStore.allDrafts()
        let oldestDraft = try await workspaceStore.draft(for: "agent|/tmp/project-0")
        let newestDraft = try await workspaceStore.draft(
            for: "agent|/tmp/project-\(NativeWorkspaceStateStore.maximumDrafts)"
        )
        XCTAssertEqual(drafts.count, NativeWorkspaceStateStore.maximumDrafts)
        XCTAssertNil(oldestDraft)
        XCTAssertEqual(
            newestDraft,
            "draft \(NativeWorkspaceStateStore.maximumDrafts)"
        )
    }
}
