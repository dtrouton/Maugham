import XCTest
@testable import Maugham

final class LineDiffTests: XCTestCase {

    func test_identicalStrings_zeroHunks() {
        let diff = LineDiff(mine: "alpha\nbeta\ngamma", cloud: "alpha\nbeta\ngamma")
        XCTAssertEqual(diff.hunks.count, 0)
        XCTAssertEqual(diff.totalMineLines, 3)
        XCTAssertEqual(diff.totalCloudLines, 3)
    }

    func test_oneLineAdded_endOfFile() {
        let diff = LineDiff(mine: "alpha\nbeta", cloud: "alpha\nbeta\ngamma")
        XCTAssertEqual(diff.hunks.count, 1)
        let h = diff.hunks[0]
        XCTAssertTrue(h.lines.contains(where: { $0.kind == .added && $0.text == "gamma" }))
    }

    func test_oneLineRemoved_endOfFile() {
        let diff = LineDiff(mine: "alpha\nbeta\ngamma", cloud: "alpha\nbeta")
        XCTAssertEqual(diff.hunks.count, 1)
        let h = diff.hunks[0]
        XCTAssertTrue(h.lines.contains(where: { $0.kind == .removed && $0.text == "gamma" }))
    }

    func test_oneLineReplaced_producesRemovedAndAdded() {
        let diff = LineDiff(mine: "alpha\nold\ngamma", cloud: "alpha\nnew\ngamma")
        XCTAssertEqual(diff.hunks.count, 1)
        let h = diff.hunks[0]
        XCTAssertTrue(h.lines.contains(where: { $0.kind == .removed && $0.text == "old" }))
        XCTAssertTrue(h.lines.contains(where: { $0.kind == .added && $0.text == "new" }))
    }

    func test_nonAdjacentChanges_produceMultipleHunks() {
        let mine = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\nFOO\n"
            + (31...60).map { "line \($0)" }.joined(separator: "\n") + "\nBAR\n"
            + (61...80).map { "line \($0)" }.joined(separator: "\n")
        let cloud = mine
            .replacingOccurrences(of: "FOO", with: "FOO_CLOUD")
            .replacingOccurrences(of: "BAR", with: "BAR_CLOUD")
        let diff = LineDiff(mine: mine, cloud: cloud, contextRadius: 3)
        XCTAssertEqual(diff.hunks.count, 2)
    }

    func test_adjacentChanges_mergeIntoOneHunk() {
        // Two changes within 2*contextRadius of each other → one hunk.
        let mine = """
        a
        b
        OLD1
        c
        OLD2
        d
        e
        """
        let cloud = """
        a
        b
        NEW1
        c
        NEW2
        d
        e
        """
        let diff = LineDiff(mine: mine, cloud: cloud, contextRadius: 3)
        XCTAssertEqual(diff.hunks.count, 1)
    }

    func test_emptyMine_allLinesAdded() {
        let diff = LineDiff(mine: "", cloud: "alpha\nbeta")
        XCTAssertEqual(diff.totalMineLines, 0)
        XCTAssertEqual(diff.totalCloudLines, 2)
        let allAdded = diff.hunks.flatMap(\.lines).filter { $0.kind == .added }
        XCTAssertEqual(allAdded.count, 2)
    }

    func test_emptyCloud_allLinesRemoved() {
        let diff = LineDiff(mine: "alpha\nbeta", cloud: "")
        let allRemoved = diff.hunks.flatMap(\.lines).filter { $0.kind == .removed }
        XCTAssertEqual(allRemoved.count, 2)
    }

    func test_lineNumbersTrackBothSides() {
        let diff = LineDiff(mine: "a\nb\nc", cloud: "a\nB\nc")
        let h = diff.hunks[0]
        let removed = h.lines.first(where: { $0.kind == .removed })!
        let added = h.lines.first(where: { $0.kind == .added })!
        XCTAssertEqual(removed.mineLineNumber, 2)
        XCTAssertNil(removed.cloudLineNumber)
        XCTAssertNil(added.mineLineNumber)
        XCTAssertEqual(added.cloudLineNumber, 2)
    }

    func test_trailingNewline_doesNotProduceSpuriousHunk() {
        let diff = LineDiff(mine: "alpha\nbeta\n", cloud: "alpha\nbeta\n")
        XCTAssertEqual(diff.hunks.count, 0)
    }
}
