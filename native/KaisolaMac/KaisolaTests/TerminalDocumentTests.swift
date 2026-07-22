import XCTest
@testable import KaisolaMacPreview

final class TerminalDocumentTests: XCTestCase {
    func testOrderedUtf8SuffixAdvancesByteCursor() throws {
        let snapshot = try TerminalSnapshot(value: .object([
            "streamEpoch": .string("epoch"),
            "output": .string("hello"),
            "startOffset": .integer(0),
            "endOffset": .integer(5),
            "truncated": .bool(false),
            "exited": .bool(false),
        ]))
        var document = TerminalDocument.empty.applying(.snapshot(snapshot, resetReason: nil), sessionID: "t1")

        XCTAssertTrue(document.append(epoch: "epoch", startOffset: 5, endOffset: 7, data: "é"))
        XCTAssertEqual(document.output, "helloé")
        XCTAssertEqual(document.cursor?.offset, 7)
    }

    func testGapOrEpochMismatchRequiresReload() {
        var document = TerminalDocument(
            sessionID: "t1",
            output: "hello",
            cursor: TerminalCursor(streamEpoch: "epoch", offset: 5),
            truncated: false,
            exited: false,
            errorMessage: nil
        )
        XCTAssertFalse(document.append(epoch: "epoch", startOffset: 6, endOffset: 7, data: "x"))
        XCTAssertFalse(document.append(epoch: "other", startOffset: 5, endOffset: 6, data: "x"))
        XCTAssertEqual(document.output, "hello")
    }

    func testRetainedOutputStaysBoundedAtAUnicodeBoundary() {
        let prefix = String(repeating: "a", count: TerminalDocument.maximumRetainedBytes - 1)
        var document = TerminalDocument(
            sessionID: "t1",
            output: prefix,
            cursor: TerminalCursor(streamEpoch: "epoch", offset: Int64(prefix.utf8.count)),
            truncated: false,
            exited: false,
            errorMessage: nil
        )
        let start = Int64(prefix.utf8.count)

        XCTAssertTrue(document.append(epoch: "epoch", startOffset: start, endOffset: start + 4, data: "🙂"))
        XCTAssertLessThanOrEqual(document.output.utf8.count, TerminalDocument.maximumRetainedBytes)
        XCTAssertTrue(document.output.hasSuffix("🙂"))
        XCTAssertTrue(document.truncated)
        XCTAssertEqual(document.cursor?.offset, start + 4)
    }

    func testResetReasonMarksRetainedHistoryGap() throws {
        let snapshot = try TerminalSnapshot(value: .object([
            "streamEpoch": .string("epoch"),
            "output": .string("tail"),
            "startOffset": .integer(100),
            "endOffset": .integer(104),
            "truncated": .bool(false),
        ]))
        let document = TerminalDocument.empty.applying(
            .snapshot(snapshot, resetReason: "retention-gap"),
            sessionID: "t1"
        )
        XCTAssertTrue(document.truncated)
    }
}
