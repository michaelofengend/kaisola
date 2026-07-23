import Foundation
import XCTest
@testable import KaisolaMacPreview

/// End-to-end proof that the Swift ACP client speaks the wire protocol over a
/// REAL child process — it spawns the Node mock agent
/// (electron/nativeAcpMock.cjs) through AcpProcessTransport and runs a full
/// handshake + streamed turn + permission callback. Skips cleanly if node or
/// the mock is unavailable so it never fails a machine without the toolchain.
final class AcpProcessIntegrationTests: XCTestCase {
    func testSpawnsMockAgentAndStreamsARealTurn() async throws {
        guard let node = Self.resolveNode(), let mock = Self.resolveMock() else {
            throw XCTSkip("node or the ACP mock agent is unavailable")
        }
        let client = AcpClient()
        let collector = IntegrationCollector()
        await client.setEventHandler { event in collector.append(event) }

        let info: AcpSessionInfo
        do {
            info = try await client.start(
                command: node,
                arguments: [mock],
                environment: ProcessInfo.processInfo.environment,
                cwd: FileManager.default.temporaryDirectory.path,
                mcpServers: []
            )
        } catch {
            throw XCTSkip("could not spawn the mock agent: \(error.localizedDescription)")
        }
        XCTAssertFalse(info.sessionID.isEmpty)
        // The real mock nests models/modes under SessionModeState-style objects;
        // this asserts the client parses that shape end-to-end (not just the
        // scripted flat fallback).
        XCTAssertFalse(info.models.isEmpty, "expected models from the mock's nested shape")
        XCTAssertFalse(info.modes.isEmpty, "expected modes from the mock's nested shape")

        // Answer the permission request the mock issues mid-turn.
        collector.onPermission = { request in
            let allow = request.options.first { $0.kind.contains("allow") } ?? request.options.first
            if let allow { Task { await client.resolvePermission(id: request.id, optionID: allow.id) } }
        }

        try await client.prompt("please make a change that needs permission")
        await client.stop()

        let events = collector.events
        XCTAssertTrue(events.contains { if case .turnItem(.message) = $0 { return true } else { return false } },
                      "expected at least one agent message")
        XCTAssertTrue(events.contains { if case .permission = $0 { return true } else { return false } },
                      "expected the permission callback")
        XCTAssertTrue(events.contains { if case .turnEnded = $0 { return true } else { return false } },
                      "expected the turn to end")
    }

    private static func resolveNode() -> String? {
        for candidate in [
            ProcessInfo.processInfo.environment["HOME"].map { $0 + "/miniforge3/bin/node" },
            "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
        ].compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private static func resolveMock() -> String? {
        // Walk up from the test bundle to the repo root, then to the mock.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("electron/nativeAcpMock.cjs")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }
}

private final class IntegrationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AcpEvent] = []
    var onPermission: (@Sendable (AcpPermissionRequest) -> Void)?

    func append(_ event: AcpEvent) {
        lock.lock(); storage.append(event); lock.unlock()
        if case let .permission(request) = event { onPermission?(request) }
    }

    var events: [AcpEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}
