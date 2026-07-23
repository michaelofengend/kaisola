import Foundation
import XCTest
@testable import KaisolaMacPreview

/// Kaisola Mesh end-to-end: one prompt fans out to every ACP-capable agent,
/// each column in an isolated `kaisola-mesh-*` worktree, all streaming from a
/// REAL spawned mock adapter; shutdown cleans the worktrees up. Skips cleanly
/// without node.
final class MeshSessionTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mesh-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
        try "seed\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "seed.txt"])
        try git(["commit", "-q", "-m", "seed"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    @MainActor
    func testMeshFansOutToIsolatedWorktreeColumnsAgainstRealMock() async throws {
        guard let node = Self.resolveNode() else { throw XCTSkip("node unavailable") }
        let mock = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KaisolaTests
            .deletingLastPathComponent()   // KaisolaMac
            .deletingLastPathComponent()   // native
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("electron/nativeAcpMock.cjs").path
        guard FileManager.default.fileExists(atPath: mock) else { throw XCTSkip("mock unavailable") }

        var environment = ProcessInfo.processInfo.environment
        environment["KAISOLA_ACP_ADAPTER_OVERRIDE"] = "\(node)\t\(mock)"

        let mesh = MeshSession(baseDirectory: repo)
        await mesh.start(
            agents: AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil },
            environment: environment
        )
        XCTAssertGreaterThanOrEqual(mesh.columns.count, 2, "expected multiple agent columns")

        // Every column is isolated in its own kaisola-mesh-* worktree.
        let worktrees = mesh.columns.compactMap(\.worktreePath)
        XCTAssertEqual(worktrees.count, mesh.columns.count, "every column should get a worktree in a repo")
        XCTAssertEqual(Set(worktrees).count, worktrees.count, "worktrees must be distinct")
        for path in worktrees {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/seed.txt"))
        }

        // The fan-out reaches every column and each streams a full turn.
        mesh.send("hello mesh")
        let deadline = Date().addingTimeInterval(15)
        func allResponded() -> Bool {
            mesh.columns.allSatisfy { column in
                column.conversation.rows.contains { row in
                    if case .message = row { return true } else { return false }
                }
            }
        }
        while !allResponded(), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            // The mock asks a permission mid-turn; grant it per column.
            for column in mesh.columns {
                if let permission = column.conversation.pendingPermission,
                   let allow = permission.options.first(where: { $0.kind.contains("allow") }) {
                    column.conversation.answerPermission(allow.id)
                }
            }
        }
        XCTAssertTrue(allResponded(), "every column should stream an agent message")
        for column in mesh.columns {
            XCTAssertTrue(column.conversation.rows.contains { row in
                if case let .user(_, text, _) = row { return text == "hello mesh" }
                return false
            }, "the prompt lands in every column's transcript")
        }

        // Shutdown removes the worktrees + branches (sequential async cleanup).
        mesh.shutdown()
        let cleanupDeadline = Date().addingTimeInterval(10)
        func branchesLeft() throws -> String {
            try git(["branch", "--list", "\(GitService.meshBranchPrefix)*"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func cleanupPending() throws -> Bool {
            try worktrees.contains(where: { FileManager.default.fileExists(atPath: $0) }) || !branchesLeft().isEmpty
        }
        while Date() < cleanupDeadline, try cleanupPending() {
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        for path in worktrees {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "worktree should be removed on shutdown")
        }
        XCTAssertTrue(try branchesLeft().isEmpty, "mesh branches should be deleted on shutdown")
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func resolveNode() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["KAISOLA_NODE"],
            "/Users/michaelofengenden/miniforge3/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
