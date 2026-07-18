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

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
