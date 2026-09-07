import XCTest
@testable import MaughamCore

/// The device's memory of what it wrote: heads per file, verified segments,
/// and the key that decides which file a head belongs to.
final class OpLogDeviceStateTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("olds-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private var stateURL: URL { tmp.appendingPathComponent("state.json") }

    /// (h) The memory survives the process it was written in — which is the
    /// whole point of it: the head this device remembers is what catches a line
    /// written while the app was closed.
    func test_headsAndSegmentsRoundTripThroughTheFile() {
        let first = OpLogDeviceState(fileURL: stateURL)
        first.remember(head: "abc123", for: "key/one")
        first.markVerified(segmentDigest: "digest-a")

        let reloaded = OpLogDeviceState(fileURL: stateURL)
        XCTAssertEqual(reloaded.head(for: "key/one"), "abc123")
        XCTAssertTrue(reloaded.isVerified(segmentDigest: "digest-a"))
        XCTAssertNil(reloaded.head(for: "key/two"))
        XCTAssertFalse(reloaded.isVerified(segmentDigest: "digest-b"))
    }

    /// (h) Two instances over one file see each other's writes once reloaded —
    /// every mutation persists at the moment it is made, not at some later
    /// flush that a crash could lose.
    func test_twoInstancesOverOneFileSeeEachOthersWritesAfterReload() {
        let a = OpLogDeviceState(fileURL: stateURL)
        let b = OpLogDeviceState(fileURL: stateURL)

        a.remember(head: "from-a", for: "shared")
        XCTAssertNil(b.head(for: "shared"), "an instance loaded earlier holds its own snapshot")

        let bAfter = OpLogDeviceState(fileURL: stateURL)
        XCTAssertEqual(bAfter.head(for: "shared"), "from-a")

        bAfter.remember(head: "from-b", for: "shared")
        XCTAssertEqual(OpLogDeviceState(fileURL: stateURL).head(for: "shared"), "from-b")
        _ = b
    }

    /// Forgetting is a first-class write: it persists, so a device that clears
    /// a head adopts on the next load rather than resurrecting the old one.
    func test_rememberingNilForgetsTheHeadAndPersistsTheForgetting() {
        let state = OpLogDeviceState(fileURL: stateURL)
        state.remember(head: "abc", for: "k")
        state.remember(head: nil, for: "k")
        XCTAssertNil(OpLogDeviceState(fileURL: stateURL).head(for: "k"))
    }

    /// An absent file is an empty memory, not a throw — the first run after
    /// this milestone has no memory at all and must still be able to write.
    func test_anAbsentFileStartsEmpty() {
        XCTAssertNil(OpLogDeviceState(fileURL: stateURL).head(for: "anything"))
    }

    /// Corrupt bytes read as an empty memory for the same reason: this is a
    /// memory, not a source of truth, and an empty one is exactly the adopt
    /// case the load path already handles.
    func test_anUndecodableFileStartsEmptyRatherThanTrapping() throws {
        try Data("not json at all".utf8).write(to: stateURL)
        let state = OpLogDeviceState(fileURL: stateURL)
        XCTAssertNil(state.head(for: "k"))
        state.remember(head: "recovered", for: "k")
        XCTAssertEqual(OpLogDeviceState(fileURL: stateURL).head(for: "k"), "recovered")
    }

    /// The key is scoped by the PROJECT ROOT (the ancestor of `.maugham`), so
    /// two devices' files inside one project differ by filename while the same
    /// filename in two projects differs by scope.
    func test_theKeyIsTheProjectRootPlusTheFilename() throws {
        let projectA = tmp.appendingPathComponent("A")
        let projectB = tmp.appendingPathComponent("B")
        for project in [projectA, projectB] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(".maugham/ops"),
                withIntermediateDirectories: true)
        }
        let a1 = OpLogDeviceState.fileKey(
            projectA.appendingPathComponent(".maugham/ops/doc-1.maca.jsonl"))
        let a2 = OpLogDeviceState.fileKey(
            projectA.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl"))
        let b1 = OpLogDeviceState.fileKey(
            projectB.appendingPathComponent(".maugham/ops/doc-1.maca.jsonl"))

        XCTAssertNotEqual(a1, a2, "two device files in one project")
        XCTAssertNotEqual(a1, b1, "the same filename in two projects")
        XCTAssertTrue(a1.hasSuffix("/doc-1.maca.jsonl"))
        XCTAssertEqual(a1.split(separator: "/").first?.count, 64, "a SHA-256 hex scope")
    }

    /// A moved project forgets its heads and adopts, which is the safe
    /// direction: dragging a folder must never quarantine the writer's own
    /// history.
    func test_aMovedProjectGetsADifferentKey() throws {
        let before = tmp.appendingPathComponent("Old/Book")
        let after = tmp.appendingPathComponent("New/Book")
        for project in [before, after] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(".maugham/ops"),
                withIntermediateDirectories: true)
        }
        XCTAssertNotEqual(
            OpLogDeviceState.fileKey(before.appendingPathComponent(".maugham/ops/d.maca.jsonl")),
            OpLogDeviceState.fileKey(after.appendingPathComponent(".maugham/ops/d.maca.jsonl")))
    }

    /// A file with no `.maugham` ancestor — a bare temp file in a test — keys
    /// on its own parent directory, so it is still distinct per directory and
    /// per filename rather than collapsing onto one key.
    func test_aFileOutsideAProjectKeysOnItsOwnDirectory() {
        let loose = tmp.appendingPathComponent("loose.jsonl")
        let sibling = tmp.appendingPathComponent("other.jsonl")
        let elsewhere = tmp.appendingPathComponent("sub/loose.jsonl")
        XCTAssertNotEqual(OpLogDeviceState.fileKey(loose), OpLogDeviceState.fileKey(sibling))
        XCTAssertNotEqual(OpLogDeviceState.fileKey(loose), OpLogDeviceState.fileKey(elsewhere))
        XCTAssertTrue(OpLogDeviceState.fileKey(loose).hasSuffix("/loose.jsonl"))
    }
}
