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

    // MARK: - Roots, and pruning the dead ones

    /// A hermetic identity: these tests hand-write state files and count
    /// persists, neither of which should depend on this machine's own key.
    private let mine = String(repeating: "c", count: 64)

    private func project(_ name: String) throws -> URL {
        let root = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
        return root
    }

    /// A project the writer deleted takes its heads with it. Without this the
    /// memory only ever grows: every project ever opened on this device keeps a
    /// head per op-log file in one file that is read on every load.
    ///
    /// Forgetting is the safe direction — an entry pruned by mistake is the
    /// adopt case, the same fall-back a moved project already takes.
    func test_anEntryWhoseRecordedRootIsGoneIsPrunedAtLoad() throws {
        let gone = try project("Gone")
        let kept = try project("Kept")
        let goneKey = OpLogDeviceState.fileKey(
            gone.appendingPathComponent(".maugham/ops/d.author-a.jsonl"))
        let keptKey = OpLogDeviceState.fileKey(
            kept.appendingPathComponent(".maugham/ops/d.author-a.jsonl"))

        let first = OpLogDeviceState(fileURL: stateURL, identity: mine)
        first.remember(head: "one", for: goneKey, root: gone)
        first.remember(head: "two", for: goneKey, root: gone)
        first.remember(head: "three", for: keptKey, root: kept)
        XCTAssertEqual(first.previousHead(for: goneKey), "one", "the fixture wants both maps filled")

        try FileManager.default.removeItem(at: gone)
        let reloaded = OpLogDeviceState(fileURL: stateURL, identity: mine)

        XCTAssertNil(reloaded.head(for: goneKey))
        XCTAssertNil(reloaded.previousHead(for: goneKey), "the predecessor goes with the head")
        XCTAssertEqual(reloaded.head(for: keptKey), "three", "a living project is untouched")
    }

    /// The pruning is persisted, not merely applied in memory — otherwise the
    /// file the next process reads is the unpruned one and nothing ever shrinks.
    func test_pruningIsWrittenBackToTheFile() throws {
        let gone = try project("Gone")
        let key = OpLogDeviceState.fileKey(
            gone.appendingPathComponent(".maugham/ops/d.author-a.jsonl"))
        let state = OpLogDeviceState(fileURL: stateURL, identity: mine)
        state.remember(head: "one", for: key, root: gone)
        state.markVerified(segmentDigest: "digest-a")
        try FileManager.default.removeItem(at: gone)

        let reloaded = OpLogDeviceState(fileURL: stateURL, identity: mine)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual((json["heads"] as? [String: String])?.isEmpty, true)
        XCTAssertEqual((json["roots"] as? [String: String])?.isEmpty, true)
        // A segment digest is a hash of BYTES and belongs to no project, so it
        // outlives the project whose heads went. Stated only in `prune`'s doc
        // comment until now, and a distinction that lives in a comment is the
        // shape this repo has a standing lesson about.
        XCTAssertTrue(reloaded.isVerified(segmentDigest: "digest-a"))
        XCTAssertEqual((json["verifiedSegments"] as? [String])?.first, "digest-a")
    }

    /// A state file written before roots were recorded has heads it cannot
    /// attribute to any project. They are KEPT: a head that cannot be shown to
    /// be dead is a head this device wrote, and quarantining the writer's own
    /// history is the one outcome this whole mechanism exists to avoid.
    func test_anEntryWithNoRecordedRootIsKept() throws {
        try Data("""
            {"identity":"\(mine)","heads":{"k/one":"h"},            "previousHeads":{},"verifiedSegments":[]}
            """.utf8).write(to: stateURL)

        let opened = OpLogDeviceState(fileURL: stateURL, identity: mine)

        XCTAssertEqual(opened.head(for: "k/one"), "h")
    }

    /// The root is recorded beside the head, keyed by the hash half of the file
    /// key — one record per project, not one per file, because every op-log
    /// file in a project shares its scope.
    func test_rememberRecordsTheRootBesideTheHead() throws {
        let root = try project("Book")
        let key = OpLogDeviceState.fileKey(
            root.appendingPathComponent(".maugham/ops/d.author-a.jsonl"))

        OpLogDeviceState(fileURL: stateURL, identity: mine)
            .remember(head: "h", for: key, root: root)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL)) as? [String: Any])
        let roots = try XCTUnwrap(json["roots"] as? [String: String])
        XCTAssertEqual(roots[String(key.prefix(while: { $0 != "/" }))],
                       root.standardizedFileURL.path)
    }

    /// Forgetting a head does not forget the project: the other op-log files
    /// under that root still have heads keyed on the same hash, and dropping
    /// the record would make every one of them unprunable.
    func test_forgettingAHeadKeepsTheRootRecord() throws {
        let root = try project("Book")
        let key = OpLogDeviceState.fileKey(
            root.appendingPathComponent(".maugham/ops/d.author-a.jsonl"))
        let state = OpLogDeviceState(fileURL: stateURL, identity: mine)
        state.remember(head: "h", for: key, root: root)

        state.remember(head: nil, for: key)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertNotNil((json["roots"] as? [String: String])?[
            String(key.prefix(while: { $0 != "/" }))])
    }

    /// The measurement the performance step asked for: ONE persist per write,
    /// and a batch of ops is one write. `JSONLAppendStore.append` remembers the
    /// head the WHOLE batch leaves, once, before the bytes go down
    /// (`JSONLAppendStore.swift:368`) — so the file is rewritten once per
    /// append, not once per op, and nothing here may defer or coalesce it: the
    /// persist-before-write ordering is what makes a crash mid-append the adopt
    /// case instead of the writer's own last op quarantined as a stranger's.
    func test_aBatchPersistsOnce() {
        let state = OpLogDeviceState(fileURL: stateURL, identity: mine)
        let before = state.persistCountForTesting

        state.remember(head: "h", for: "k/one")
        XCTAssertEqual(state.persistCountForTesting, before + 1)

        state.markVerified(segmentDigest: "digest-a")
        XCTAssertEqual(state.persistCountForTesting, before + 2)

        state.remember(head: nil, for: "k/one")
        XCTAssertEqual(state.persistCountForTesting, before + 3, "forgetting persists too")
    }

    /// Pruning asks one question — is the recorded root still on disk — and a
    /// path that is simply gone answers no. It is best-effort: nothing throws,
    /// nothing is skipped, the entry goes and the next load adopts.
    func test_pruningDropsAHeadWhoseRootIsGone() throws {
        let gone = try project("Gone")
        let key = OpLogDeviceState.fileKey(
            gone.appendingPathComponent(".maugham/ops/d.author-a.jsonl"))
        OpLogDeviceState(fileURL: stateURL, identity: mine)
            .remember(head: "h", for: key, root: gone)
        try FileManager.default.removeItem(at: gone)

        XCTAssertNil(OpLogDeviceState(fileURL: stateURL, identity: mine).head(for: key))
    }

    /// The predicate is the root ITSELF, not its `.maugham` child. A directory
    /// that is present but whose `.maugham` cannot be found — a project whose
    /// derived folder was deleted, or any condition that makes that one read
    /// fail while the folder is alive — KEEPS its heads: the loss is silent by
    /// construction (the adopt path logs nothing), and a root with no
    /// `.maugham` has no lines for those heads to protect anyway.
    func test_aRootThatExistsWithoutAMaughamChildKeepsItsHeads() throws {
        let root = try project("Present")
        let key = OpLogDeviceState.fileKey(
            root.appendingPathComponent(".maugham/ops/d.author-a.jsonl"))
        OpLogDeviceState(fileURL: stateURL, identity: mine)
            .remember(head: "h", for: key, root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".maugham"))

        XCTAssertEqual(OpLogDeviceState(fileURL: stateURL, identity: mine).head(for: key), "h")
    }
}
