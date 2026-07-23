import XCTest
@testable import KaisolaMacPreview

/// Pure routing test for the terminal `file:` OSC 8 link parser
/// (`NativeTerminalSurface.Coordinator.parseFileLink`): a bare file URL carries
/// no line, a trailing `:LINE` (literal or percent-encoded `%3A`) becomes an
/// `Int` line, and directory / non-numeric-colon URLs pass through untouched.
final class TerminalLinkRoutingTests: XCTestCase {
    private func parse(_ string: String) throws -> (path: String, line: Int?) {
        let url = try XCTUnwrap(URL(string: string))
        return NativeTerminalSurface.Coordinator.parseFileLink(url)
    }

    func testPlainFileURLHasNoLine() throws {
        let result = try parse("file:///a/b.swift")
        XCTAssertEqual(result.path, "/a/b.swift")
        XCTAssertNil(result.line)
    }

    func testPercentEncodedColonYieldsLine() throws {
        // The colon in `path:line` frequently arrives percent-encoded as %3A.
        let result = try parse("file:///a/b.swift%3A42")
        XCTAssertEqual(result.path, "/a/b.swift")
        XCTAssertEqual(result.line, 42)
    }

    func testLiteralColonSuffixYieldsLine() throws {
        let result = try parse("file:///a/b.swift:42")
        XCTAssertEqual(result.path, "/a/b.swift")
        XCTAssertEqual(result.line, 42)
    }

    func testDeepPathWithLine() throws {
        let result = try parse("file:///Users/x/Developer/app/src/main.swift%3A128")
        XCTAssertEqual(result.path, "/Users/x/Developer/app/src/main.swift")
        XCTAssertEqual(result.line, 128)
    }

    func testDirectoryURLUntouched() throws {
        // A directory has no line citation: the line is nil and no `:` was
        // split out of the path (asserted robustly to tolerate whether
        // `URL.path` keeps the trailing separator).
        let result = try parse("file:///a/b/")
        XCTAssertNil(result.line)
        XCTAssertFalse(result.path.contains(":"))
        XCTAssertTrue(result.path.hasPrefix("/a/b"))
    }

    func testNonNumericColonKeptInPath() throws {
        // A colon that is not followed by digits is part of the path, not a
        // citation — the parser must not split on it.
        let result = try parse("file:///a/notes:draft")
        XCTAssertEqual(result.path, "/a/notes:draft")
        XCTAssertNil(result.line)
    }

    func testTrailingColonWithoutDigitsKeptInPath() throws {
        let result = try parse("file:///a/b.swift:")
        XCTAssertEqual(result.path, "/a/b.swift:")
        XCTAssertNil(result.line)
    }
}
