import Foundation
import KaisolaCore
import XCTest
@testable import KaisolaMacPreview

/// Per-workspace MCP configuration: round-trip persistence under
/// `<workspace>/.kaisola/mcp.json`, corrupt-file → empty, and `jsonValues`
/// session shapes that mirror `scripts/native-mcp-registry.cjs`
/// `buildSessionServers` byte-for-byte (stdio omits `type`; http/sse carry it;
/// env/headers are arrays of `{name,value}`; disabled servers are dropped).
final class McpConfigStoreTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - Persistence

    func testRoundTripAcrossInstances() {
        let servers = [
            McpServerConfig(
                name: "files",
                kind: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                envPairs: [.init(name: "TOKEN", value: "abc")],
                enabled: true
            ),
            McpServerConfig(
                name: "remote",
                kind: .http,
                url: "https://example.com/mcp",
                headerPairs: [.init(name: "Authorization", value: "Bearer xyz")],
                enabled: false
            ),
        ]
        McpConfigStore(workspace: workspace).save(servers)

        let reopened = McpConfigStore(workspace: workspace)
        XCTAssertEqual(reopened.servers(), servers)
    }

    func testConfigFileLivesUnderDotKaisola() {
        McpConfigStore(workspace: workspace).save([
            McpServerConfig(name: "x", kind: .stdio, command: "echo"),
        ])
        let expected = workspace
            .appendingPathComponent(".kaisola")
            .appendingPathComponent("mcp.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testMissingFileIsEmpty() {
        XCTAssertTrue(McpConfigStore(workspace: workspace).servers().isEmpty)
    }

    func testCorruptFileDegradesToEmpty() throws {
        let directory = workspace.appendingPathComponent(".kaisola")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("mcp.json"))
        XCTAssertTrue(McpConfigStore(workspace: workspace).servers().isEmpty)
    }

    // MARK: - Session wire shapes

    func testStdioJsonValueMatchesNodeShape() {
        let server = McpServerConfig(
            name: "files",
            kind: .stdio,
            command: "npx",
            args: ["-y", "server-filesystem"],
            envPairs: [.init(name: "TOKEN", value: "abc")],
            enabled: true
        )
        // Hand-built to the exact key set buildSessionServers emits for stdio:
        // {name, command, args, env:[{name,value}]} — no `type`.
        let expected: JSONValue = .object([
            "name": .string("files"),
            "command": .string("npx"),
            "args": .array([.string("-y"), .string("server-filesystem")]),
            "env": .array([.object(["name": .string("TOKEN"), "value": .string("abc")])]),
        ])
        XCTAssertEqual(McpConfigStore.jsonValues([server]), [expected])
    }

    func testHttpJsonValueMatchesNodeShape() {
        let server = McpServerConfig(
            name: "remote",
            kind: .http,
            url: "https://example.com/mcp",
            headerPairs: [.init(name: "Authorization", value: "Bearer xyz")],
            enabled: true
        )
        // Hand-built to the exact key set buildSessionServers emits for http/sse:
        // {type, name, url, headers:[{name,value}]}.
        let expected: JSONValue = .object([
            "type": .string("http"),
            "name": .string("remote"),
            "url": .string("https://example.com/mcp"),
            "headers": .array([.object(["name": .string("Authorization"), "value": .string("Bearer xyz")])]),
        ])
        XCTAssertEqual(McpConfigStore.jsonValues([server]), [expected])
    }

    func testStdioOmitsTypeAndAlwaysCarriesEmptyArgsAndEnv() {
        let server = McpServerConfig(name: "bare", kind: .stdio, command: "run", enabled: true)
        let object = McpConfigStore.jsonValues([server]).first?.objectValue
        XCTAssertNil(object?["type"])
        XCTAssertEqual(object?["args"], .array([]))
        XCTAssertEqual(object?["env"], .array([]))
    }

    func testSseCarriesTypeAndAlwaysCarriesEmptyHeaders() {
        let server = McpServerConfig(name: "stream", kind: .sse, url: "https://example.com/sse", enabled: true)
        let object = McpConfigStore.jsonValues([server]).first?.objectValue
        XCTAssertEqual(object?["type"], .string("sse"))
        XCTAssertEqual(object?["headers"], .array([]))
    }

    func testDisabledServersExcluded() {
        let servers = [
            McpServerConfig(name: "on", kind: .stdio, command: "a", enabled: true),
            McpServerConfig(name: "off", kind: .stdio, command: "b", enabled: false),
        ]
        let values = McpConfigStore.jsonValues(servers)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.objectValue?["name"], .string("on"))
    }
}
