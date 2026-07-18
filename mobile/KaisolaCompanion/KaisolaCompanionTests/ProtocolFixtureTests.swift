import XCTest
@testable import KaisolaCompanion

final class ProtocolFixtureTests: XCTestCase {
    private let validEnvelopeFixtures = [
        "hello", "agent-delta", "command-receipt", "permission-requested",
        "snapshot-board", "stale-revision-error", "terminal-output",
    ]

    func testEveryValidProtocolEnvelopeRoundTripsSemantically() throws {
        for name in validEnvelopeFixtures {
            let original = try fixtureData(name)
            let envelope = try CompanionProtocolCodec.decode(original)
            let encoded = try CompanionProtocolCodec.encode(envelope)
            XCTAssertEqual(
                try JSONDecoder().decode(JSONValue.self, from: encoded),
                try JSONDecoder().decode(JSONValue.self, from: original),
                "\(name).json must preserve every Node field"
            )
        }
    }

    func testProtocolMismatchFixtureFailsClosedLikeNode() throws {
        XCTAssertThrowsError(try CompanionProtocolCodec.decode(fixtureData("protocol-mismatch"))) { error in
            XCTAssertEqual(error as? CompanionProtocolError, .protocolMismatch(99))
        }
    }

    func testFixtureBodiesDecodeToTheirTypedSwiftRepresentations() throws {
        let hello = try CompanionProtocolCodec.decode(fixtureData("hello"))
            .body.decode(CompanionHelloBody.self)
        XCTAssertEqual(hello.role, .device)
        XCTAssertEqual(hello.capabilities, [.observe])

        let delta = try CompanionProtocolCodec.decode(fixtureData("agent-delta"))
            .body.decode(CompanionAgentTurnDeltaBody.self)
        XCTAssertEqual(delta.turnId, "turn-8")
        XCTAssertEqual(delta.delta, .string("Adding replay protection."))

        let permission = try CompanionProtocolCodec.decode(fixtureData("permission-requested"))
            .body.decode(CompanionPermissionRequestedBody.self)
        XCTAssertEqual(permission.options.map(\.id), ["allow-once", "reject"])

        let terminal = try CompanionProtocolCodec.decode(fixtureData("terminal-output"))
            .body.decode(CompanionTerminalOutputBody.self)
        XCTAssertEqual(terminal.endOffset, 7)
        XCTAssertEqual(terminal.data, "🙂")
    }

    func testTerminalCursorFixtureRoundTripsAndUsesUTF8ByteOffsets() throws {
        let original = try fixtureData("terminal-cursor")
        let cursor = try JSONDecoder().decode(CompanionTerminalCursorFixture.self, from: original)
        XCTAssertEqual(cursor.chunks.map(\.startOffset), [0, 3, 7])
        XCTAssertEqual(cursor.chunks.map(\.endOffset), [3, 7, 9])
        XCTAssertEqual(cursor.chunks[1].data.lengthOfBytes(using: .utf8), 4)

        let encoded = try JSONEncoder().encode(cursor)
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: encoded),
            try JSONDecoder().decode(JSONValue.self, from: original)
        )
    }

    @MainActor
    func testLiveStoreAppliesSnapshotAndMonotonicDeltas() throws {
        let store = CompanionStore(
            connection: .offline,
            projects: [],
            sessions: [],
            attention: [],
            permissions: [],
            isPreview: false
        )
        XCTAssertTrue(try store.apply(CompanionProtocolCodec.decode(fixtureData("snapshot-board"))))
        XCTAssertTrue(try store.apply(CompanionProtocolCodec.decode(fixtureData("terminal-output"))))
        XCTAssertTrue(try store.apply(CompanionProtocolCodec.decode(fixtureData("agent-delta"))))
        XCTAssertTrue(try store.apply(CompanionProtocolCodec.decode(fixtureData("permission-requested"))))

        XCTAssertEqual(store.lastAckCursor, CompanionAckCursor(epoch: "desktop-epoch-7", seq: 15))
        XCTAssertEqual(store.session(for: "session-codex")?.turns?.last?.text, "Adding replay protection.")
        XCTAssertEqual(store.permissions.map(\.id), ["permission-1"])
        XCTAssertEqual(store.connection, .live)
    }

    @MainActor
    func testProjectMergePreservesTerminalCursorAndStreamingTurnIdentity() throws {
        let store = try liveStoreFromSnapshot()
        try store.apply(event(
            type: "terminal.snapshot",
            seq: 13,
            fields: [
                "projectId": .string("project-kaisola"),
                "terminalId": .string("session-done"),
                "streamEpoch": .string("terminal-epoch-live"),
                "endOffset": .integer(6),
                "output": .string("before"),
            ]
        ))
        try store.apply(event(
            type: "agent.turn.delta",
            seq: 14,
            fields: [
                "projectId": .string("project-kaisola"),
                "sessionId": .string("session-codex"),
                "turnId": .string("turn-live"),
                "delta": .string("Working "),
            ]
        ))

        var projection = try snapshotProjection()
        let sessionIndex = try XCTUnwrap(projection.sessions.firstIndex(where: { $0.id == "session-codex" }))
        projection.sessions[sessionIndex].turns = [
            CompanionTurn(role: .assistant, text: "Working ", status: "streaming", at: 1_784_250_001_400),
        ]
        try store.apply(event(
            type: "project.updated",
            seq: 15,
            fields: [
                "windowId": .string("saved-primary"),
                "revision": .integer(2),
                "projection": try JSONValue.from(projection),
            ]
        ))
        try store.apply(event(
            type: "agent.turn.delta",
            seq: 16,
            fields: [
                "projectId": .string("project-kaisola"),
                "sessionId": .string("session-codex"),
                "turnId": .string("turn-live"),
                "delta": .string("still"),
            ]
        ))

        let terminal = try XCTUnwrap(store.session(for: "session-done"))
        XCTAssertEqual(terminal.terminalLines, ["before"])
        XCTAssertEqual(terminal.terminalStreamEpoch, "terminal-epoch-live")
        XCTAssertEqual(terminal.terminalEndOffset, 6)
        let turns = try XCTUnwrap(store.session(for: "session-codex")?.turns)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].wireId, "turn-live")
        XCTAssertEqual(turns[0].text, "Working still")
    }

    @MainActor
    func testProjectRemovedDeletesOwnedDataWithoutMakingLiveConnectionStale() throws {
        let store = try liveStoreFromSnapshot()
        let projection = try snapshotProjection()
        try store.apply(event(
            type: "project.updated",
            seq: 13,
            fields: [
                "windowId": .string("saved-primary"),
                "revision": .integer(2),
                "projection": try JSONValue.from(projection),
            ]
        ))
        store.attention = [CompanionAttention(
            id: "attention-1",
            projectId: "project-kaisola",
            sessionId: "session-codex",
            kind: "review",
            title: "Review",
            createdAt: 1,
            severity: "warning"
        )]
        store.permissions = [CompanionPermission(
            permId: "permission-1",
            projectId: "project-kaisola",
            sessionId: "session-codex",
            agent: "Codex",
            title: "Approve",
            requestedAt: 1,
            options: [],
            diffs: []
        )]

        try store.apply(event(
            type: "project.updated",
            seq: 14,
            fields: [
                "windowId": .string("saved-primary"),
                "removed": .bool(true),
                "revision": .integer(3),
            ]
        ))

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.attention.isEmpty)
        XCTAssertTrue(store.permissions.isEmpty)
        XCTAssertNil(store.selectedProjectId)
        XCTAssertEqual(store.connection, .live)
    }

    @MainActor
    func testSnapshotRequiredResetsTerminalBufferAndCursorBeforeNextOutput() throws {
        let store = try liveStoreFromSnapshot()
        try store.apply(event(
            type: "terminal.snapshot",
            seq: 13,
            fields: [
                "projectId": .string("project-kaisola"),
                "terminalId": .string("session-done"),
                "streamEpoch": .string("terminal-epoch-old"),
                "endOffset": .integer(6),
                "output": .string("stale"),
            ]
        ))
        try store.apply(event(
            type: "terminal.snapshot",
            seq: 14,
            fields: [
                "projectId": .string("project-kaisola"),
                "terminalId": .string("session-done"),
                "streamEpoch": .string("terminal-epoch-new"),
                "endOffset": .integer(40),
                "snapshotRequired": .bool(true),
                "reason": .string("slow_consumer"),
            ]
        ))

        var terminal = try XCTUnwrap(store.session(for: "session-done"))
        XCTAssertEqual(terminal.terminalLines, [])
        XCTAssertEqual(terminal.terminalStreamEpoch, "terminal-epoch-new")
        XCTAssertEqual(terminal.terminalEndOffset, 40)

        try store.apply(event(
            type: "terminal.output",
            seq: 15,
            fields: [
                "projectId": .string("project-kaisola"),
                "terminalId": .string("session-done"),
                "streamEpoch": .string("terminal-epoch-new"),
                "startOffset": .integer(40),
                "endOffset": .integer(45),
                "data": .string("fresh"),
            ]
        ))
        terminal = try XCTUnwrap(store.session(for: "session-done"))
        XCTAssertEqual(terminal.terminalLines, ["fresh"])
        XCTAssertEqual(terminal.terminalEndOffset, 45)
        XCTAssertEqual(store.connection, .live)
    }

    @MainActor
    func testPermissionRequestedWithoutRevisionDecodesAndApplies() throws {
        let store = try liveStoreFromSnapshot()
        let envelope = try event(
            type: "agent.permission.requested",
            seq: 13,
            fields: [
                "projectId": .string("project-kaisola"),
                "sessionId": .string("session-review"),
                "permId": .string("permission-without-revision"),
                "agent": .string("Claude"),
                "title": .string("Approve live action"),
                "options": .array([]),
                "diffs": .array([]),
            ]
        )

        let decoded = try envelope.body.decode(CompanionPermissionRequestedBody.self)
        XCTAssertNil(decoded.revision)
        XCTAssertTrue(try store.apply(envelope))
        XCTAssertEqual(store.permissions.map(\.id), ["permission-without-revision"])
        XCTAssertNil(store.permissions[0].revision)
    }

    @MainActor
    private func liveStoreFromSnapshot() throws -> CompanionStore {
        let store = CompanionStore(
            connection: .offline,
            projects: [],
            sessions: [],
            attention: [],
            permissions: [],
            isPreview: false
        )
        XCTAssertTrue(try store.apply(CompanionProtocolCodec.decode(fixtureData("snapshot-board"))))
        return store
    }

    private func snapshotProjection() throws -> CompanionProjection {
        try CompanionProtocolCodec.decode(fixtureData("snapshot-board"))
            .body.decode(CompanionSnapshotBody.self)
            .projection
    }

    private func event(type: String, seq: Int64, fields: [String: JSONValue]) throws -> CompanionEnvelope {
        var bodyFields = fields
        bodyFields["type"] = .string(type)
        return try CompanionEnvelope(
            kind: .event,
            desktopId: "desktop-fixture",
            deviceId: "device-fixture",
            connectionId: "connection-fixture",
            epoch: "desktop-epoch-7",
            seq: seq,
            id: "event-\(seq)",
            sentAt: 1_784_250_001_200 + seq,
            body: CompanionBody(fields: bodyFields)
        )
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
