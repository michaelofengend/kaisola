import XCTest
@testable import KaisolaCompanion

final class TransportFramingTests: XCTestCase {
    func testLengthFramingMatchesNodeBigEndianWireFormatAcrossChunks() throws {
        let first = Data(#"{"v":1}"#.utf8)
        let second = Data(#"{"type":"hello"}"#.utf8)
        let wire = try CompanionLengthFrameDecoder.encode(first) + CompanionLengthFrameDecoder.encode(second)
        XCTAssertEqual(Array(wire.prefix(4)), [0, 0, 0, UInt8(first.count)])

        var decoder = CompanionLengthFrameDecoder()
        XCTAssertTrue(try decoder.push(Data(wire.prefix(5))).isEmpty)
        XCTAssertEqual(try decoder.push(Data(wire.dropFirst(5))), [first, second])
    }

    func testLengthFramingRejectsZeroAndOversizedFrames() throws {
        var decoder = CompanionLengthFrameDecoder(maximumFrameBytes: 8)
        XCTAssertThrowsError(try decoder.push(Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try CompanionLengthFrameDecoder.encode(Data(repeating: 1, count: 9), maximumFrameBytes: 8))
    }
}
