import XCTest
@testable import KaisolaMacPreview

final class SessionPaneLayoutTests: XCTestCase {
    func testExplicitAddsOpenBesideThenBalanceIntoStacks() {
        var layout = SessionPaneLayout(sessionID: "one")
        layout.add("two")
        layout.add("three")
        layout.add("four")

        XCTAssertEqual(layout.columns.count, 2)
        XCTAssertEqual(layout.columns[0].sessionIDs, ["one", "three"])
        XCTAssertEqual(layout.columns[1].sessionIDs, ["two", "four"])
    }

    func testFocusReplacesOnlyPrimaryAndKeepsExplicitSplits() {
        var layout = SessionPaneLayout(columns: [
            .init(sessionIDs: ["one", "three"]),
            .init(sessionIDs: ["two"]),
        ])
        layout.focus("replacement")
        XCTAssertEqual(layout.columns[0].sessionIDs, ["replacement", "three"])
        XCTAssertEqual(layout.columns[1].sessionIDs, ["two"])
    }

    func testEdgePlacementMakesColumnsAndRows() {
        var layout = SessionPaneLayout(columns: [
            .init(sessionIDs: ["one", "two"]),
            .init(sessionIDs: ["three"]),
        ])
        layout.place("two", relativeTo: "three", edge: .top)
        XCTAssertEqual(layout.columns.map(\.sessionIDs), [["one"], ["two", "three"]])

        layout.place("one", relativeTo: "three", edge: .right)
        XCTAssertEqual(layout.columns.map(\.sessionIDs), [["two", "three"], ["one"]])
    }

    func testNormalizeDropsStaleDuplicatesAndCapsCards() {
        var layout = SessionPaneLayout(columns: [
            .init(sessionIDs: ["one", "one", "stale"]),
            .init(sessionIDs: (2...12).map { "s\($0)" }),
        ])
        layout.normalize(availableSessionIDs: Set(["one"] + (2...12).map { "s\($0)" }))
        XCTAssertEqual(layout.sessionIDs.first, "one")
        XCTAssertEqual(Set(layout.sessionIDs).count, layout.sessionIDs.count)
        XCTAssertLessThanOrEqual(layout.sessionIDs.count, SessionPaneLayout.maximumPaneCount)
        XCTAssertFalse(layout.sessionIDs.contains("stale"))
    }

    func testResizeTransfersWeightWithoutChangingPairTotal() {
        var layout = SessionPaneLayout(columns: [
            .init(sessionIDs: ["one"], weight: 1),
            .init(sessionIDs: ["two"], weight: 1),
        ])
        layout.resizeColumns(boundary: 0, delta: 0.4, minimumWeight: 0.2)
        XCTAssertEqual(layout.columns[0].weight, 1.4, accuracy: 0.0001)
        XCTAssertEqual(layout.columns[1].weight, 0.6, accuracy: 0.0001)
        XCTAssertEqual(layout.columns.map(\.weight).reduce(0, +), 2, accuracy: 0.0001)
    }

    func testCodableRoundTripPreservesGeometry() throws {
        var layout = SessionPaneLayout(columns: [
            .init(id: "left", sessionIDs: ["one", "two"], weight: 1.4, rowWeights: [0.7, 1.3]),
            .init(id: "right", sessionIDs: ["three"], weight: 0.6),
        ])
        layout.resizeRows(columnID: "left", boundary: 0, delta: 0.1, minimumWeight: 0.2)
        let decoded = try JSONDecoder().decode(SessionPaneLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
    }
}
