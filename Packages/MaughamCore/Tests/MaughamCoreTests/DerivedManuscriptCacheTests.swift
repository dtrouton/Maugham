import XCTest
@testable import MaughamCore

/// F5: the mtime-keyed cache fronting `DerivedManuscript` for closed docs.
/// Behaviour asserted via the test-visible `deriveCount` (cache-hit counting,
/// not wall-clock timing).
final class DerivedManuscriptCacheTests: XCTestCase {

    /// Append `ops` to (creating if needed) `<docId>.jsonl` under a temp project.
    /// Returns the project root. Append-mode so a second call grows the file
    /// (mutating its size/mtime — the token's invalidation signal).
    @discardableResult
    private func seed(root: URL? = nil, docId: String, ops: [Op]) throws -> URL {
        let root = root ?? TestTemp.root
            .appendingPathComponent("dmc-\(UUID().uuidString)")
        let opsDir = root.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let lines = try ops.map { String(data: try enc.encode($0), encoding: .utf8)! }
        let blob = lines.joined(separator: "\n").appending("\n")
        let fileURL = opsDir.appendingPathComponent("\(docId).jsonl")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(blob.data(using: .utf8)!)
            try handle.close()
        } else {
            try blob.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func op(_ id: String, doc: String = "doc-1", seq: [String]?, changes: [(String, String)]) -> Op {
        Op(opId: id, docId: doc, at: Date(timeIntervalSince1970: 0),
           device: "d", session: "s", kind: .typingBurst,
           changes: changes.map { Op.ParagraphChange(paragraphId: $0.0, prior: nil, next: $0.1) },
           sequence: seq, provenance: nil)
    }

    /// Many docs' tokens come from ONE listing of `.maugham/ops` (plan 3b
    /// whole-branch review I2: a listing per doc made the editor's reference
    /// index cost the square of the project on the main actor), and each is
    /// exactly the token the per-doc door answers.
    func test_tokensForManyDocs_listTheOpsDirectoryOnce_andMatchThePerDocToken() throws {
        let root = try seed(docId: "doc-1", ops: [
            op("01a", seq: ["n5sg"], changes: [("n5sg", "One.")])])
        try seed(root: root, docId: "doc-2", ops: [
            op("02a", doc: "doc-2", seq: ["xg8q"], changes: [("xg8q", "Two.")])])
        try seed(root: root, docId: "doc-10", ops: [
            op("03a", doc: "doc-10", seq: ["w4kd"], changes: [("w4kd", "Ten.")])])
        var listings = 0
        let tokens = DerivedManuscriptCache.tokens(
            forDocIds: ["doc-1", "doc-2", "doc-10", "doc-none"], in: root,
            list: { listings += 1; return OpLogFiles.opsDirectoryListing(in: $0) })
        XCTAssertEqual(listings, 1, "one directory listing for every doc asked")
        for docId in ["doc-1", "doc-2", "doc-10", "doc-none"] {
            XCTAssertEqual(tokens[docId], DerivedManuscriptCache.token(forDocId: docId, in: root), docId)
        }
        XCTAssertEqual(tokens["doc-1"]?.entries.count, 1, "doc-1 never takes doc-10's file")
        XCTAssertEqual(tokens["doc-none"]?.entries, [])
        XCTAssertEqual(DerivedManuscriptCache.tokens(forDocIds: [], in: root,
                                                     list: { _ in listings += 1; return [] }), [:])
        XCTAssertEqual(listings, 1, "asking about no doc lists nothing")
    }

    /// Two calls on an unchanged file: exactly one derive.
    func test_secondCall_sameFileSet_zeroAdditionalDerives() throws {
        let root = try seed(docId: "doc-1", ops: [
            op("01a", seq: ["n5sg"], changes: [("n5sg", "First para.")])])
        let cache = DerivedManuscriptCache()

        _ = try cache.state(forDocId: "doc-1", in: root)
        XCTAssertEqual(cache.deriveCount, 1)
        let again = try cache.state(forDocId: "doc-1", in: root)
        XCTAssertEqual(cache.deriveCount, 1, "second call on an unchanged file must hit the cache")
        XCTAssertEqual(again.paragraphs["n5sg"], "First para.")
    }

    /// Appending an op grows the file → token changes → re-derive, new content visible.
    func test_afterAppend_reDerives_andSeesNewContent() throws {
        let root = try seed(docId: "doc-1", ops: [
            op("01a", seq: ["n5sg"], changes: [("n5sg", "First.")])])
        let cache = DerivedManuscriptCache()
        _ = try cache.state(forDocId: "doc-1", in: root)
        XCTAssertEqual(cache.deriveCount, 1)

        try seed(root: root, docId: "doc-1", ops: [
            op("01b", seq: ["n5sg", "xg8q"], changes: [("xg8q", "Second.")])])

        let after = try cache.state(forDocId: "doc-1", in: root)
        XCTAssertEqual(cache.deriveCount, 2, "a grown op-log file must invalidate the cached line")
        XCTAssertEqual(after.paragraphs["xg8q"], "Second.")
    }

    /// Editing one doc invalidates only that doc's line — per-doc isolation.
    func test_perDocIsolation_editingOneDocKeepsTheOtherCached() throws {
        let root = try seed(docId: "doc-1", ops: [
            op("01a", doc: "doc-1", seq: ["aaaa"], changes: [("aaaa", "One.")])])
        try seed(root: root, docId: "doc-2", ops: [
            op("02a", doc: "doc-2", seq: ["bbbb"], changes: [("bbbb", "Two.")])])
        let cache = DerivedManuscriptCache()

        _ = try cache.state(forDocId: "doc-1", in: root)
        _ = try cache.state(forDocId: "doc-2", in: root)
        XCTAssertEqual(cache.deriveCount, 2)

        // Grow only doc-1's log.
        try seed(root: root, docId: "doc-1", ops: [
            op("01b", doc: "doc-1", seq: ["aaaa", "cccc"], changes: [("cccc", "More.")])])

        _ = try cache.state(forDocId: "doc-1", in: root)
        XCTAssertEqual(cache.deriveCount, 3, "doc-1 changed → re-derive")
        _ = try cache.state(forDocId: "doc-2", in: root)
        XCTAssertEqual(cache.deriveCount, 3, "doc-2 unchanged → still cached")
    }

    /// materialize / displayText parity with the uncached `DerivedManuscript`.
    func test_materializeAndDisplayText_matchUncachedDerivedManuscript() throws {
        let root = try seed(docId: "doc-1", ops: [
            op("01a", seq: ["n5sg"], changes: [("n5sg", "Hello world.")])])
        let cache = DerivedManuscriptCache()

        XCTAssertEqual(
            try cache.materialize(forDocId: "doc-1", in: root),
            try DerivedManuscript.materialize(forDocId: "doc-1", in: root))
        XCTAssertEqual(
            try cache.displayText(forDocId: "doc-1", in: root),
            MarkdownDisplayFilter.stripAnchors(
                try DerivedManuscript.materialize(forDocId: "doc-1", in: root)))
    }

    /// Explicit invalidation forces a re-derive even without a disk change.
    func test_invalidate_forcesRederive() throws {
        let root = try seed(docId: "doc-1", ops: [
            op("01a", seq: ["n5sg"], changes: [("n5sg", "X.")])])
        let cache = DerivedManuscriptCache()
        _ = try cache.state(forDocId: "doc-1", in: root)
        XCTAssertEqual(cache.deriveCount, 1)
        cache.invalidate(docId: "doc-1")
        _ = try cache.state(forDocId: "doc-1", in: root)
        XCTAssertEqual(cache.deriveCount, 2)
    }

    /// No ops → empty derived state, still counted as a derive (and cached).
    func test_noOps_isEmpty_andCached() throws {
        let root = TestTemp.root
            .appendingPathComponent("dmc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = DerivedManuscriptCache()
        XCTAssertEqual(try cache.materialize(forDocId: "doc-x", in: root), "")
        _ = try cache.state(forDocId: "doc-x", in: root)
        XCTAssertEqual(cache.deriveCount, 1, "empty-op-log state is cached on the empty file set")
    }
}
