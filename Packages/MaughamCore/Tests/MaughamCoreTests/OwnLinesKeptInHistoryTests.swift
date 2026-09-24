import XCTest
@testable import MaughamCore

/// **Some of what you wrote here is kept in History** (signed op log P3c Task
/// 3, controller ruling K): `OpLogProvenance.ownLinesKeptInHistory` counts the
/// set-aside and held lines of THIS device's own files and nobody else's.
final class OwnLinesKeptInHistoryTests: XCTestCase {

    private let mine = "author-mine"
    private let theirs = "author-theirs"

    private func file(
        _ slug: String?, quarantined: Int = 0, pending: Int = 0, verified: Int = 3
    ) -> FileProvenance {
        FileProvenance(
            name: "doc.\(slug ?? "legacy").jsonl", verified: verified,
            quarantined: quarantined, pending: pending,
            pendingByDevice: pending > 0 ? ["someone": pending] : [:],
            deviceSlug: slug)
    }

    func test_aSetAsideLineInMyOwnFileIsCounted() {
        let provenance = OpLogProvenance(
            files: [file(mine, quarantined: 1)], ownStreams: [mine])
        XCTAssertEqual(provenance.ownLinesKeptInHistory, 1)
    }

    func test_theSameLineInAnotherDevicesFileIsNot() {
        let provenance = OpLogProvenance(
            files: [file(mine), file(theirs, quarantined: 1)], ownStreams: [mine])
        XCTAssertEqual(provenance.ownLinesKeptInHistory, 0,
                       "another device's set-aside line is not what she wrote")
    }

    func test_aHeldLineInMyOwnFileIsCounted() {
        let provenance = OpLogProvenance(
            files: [file(mine, pending: 2), file(theirs, pending: 5)], ownStreams: [mine])
        XCTAssertEqual(provenance.ownLinesKeptInHistory, 2)
    }

    /// Every one of this device's actors' files counts; the legacy unsuffixed
    /// log names nobody; a hand-built value names no stream as mine.
    func test_everyOwnActorCountsAndNothingElseDoes() {
        let assistant = "assistant-mine"
        let provenance = OpLogProvenance(
            files: [file(mine, quarantined: 1), file(assistant, pending: 1),
                    file(nil, quarantined: 4)],
            ownStreams: [mine, assistant])
        XCTAssertEqual(provenance.ownLinesKeptInHistory, 2)
        XCTAssertEqual(OpLogProvenance(files: [file(mine, quarantined: 1)])
            .ownLinesKeptInHistory, 0)
        XCTAssertEqual(file(mine, quarantined: 1, pending: 2).keptInHistory, 3)
    }
}
