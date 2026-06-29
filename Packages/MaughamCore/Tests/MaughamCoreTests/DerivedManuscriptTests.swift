import XCTest
@testable import MaughamCore

final class DerivedManuscriptTests: XCTestCase {

    /// Write an op-log JSONL file for `docId` under a temp project; return the URL.
    private func makeProject(docId: String, ops: [Op]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-\(UUID().uuidString)")
        let opsDir = root.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let lines = try ops.map { String(data: try enc.encode($0), encoding: .utf8)! }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: opsDir.appendingPathComponent("\(docId).jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    private func op(_ id: String, seq: [String]?, changes: [(String, String)]) -> Op {
        Op(opId: id, docId: "doc-1", at: Date(timeIntervalSince1970: 0),
           device: "d", session: "s", kind: .typingBurst,
           changes: changes.map { Op.ParagraphChange(paragraphId: $0.0, prior: nil, next: $0.1) },
           sequence: seq, provenance: nil)
    }

    /// materialize equals Deriver+Materializer over the same ops (parity).
    func test_materialize_equalsDeriverMaterializer() throws {
        let ops = [op("01a", seq: ["n5sg", "xg8q"],
                      changes: [("n5sg", "First para."), ("xg8q", "Second para.")])]
        let root = try makeProject(docId: "doc-1", ops: ops)
        let want = Materializer.materialize(
            paragraphs: Deriver.deriveWithSequenceFallback(ops: ops).paragraphs,
            sequence: Deriver.deriveWithSequenceFallback(ops: ops).sequence)
        XCTAssertEqual(DerivedManuscript.materialize(forDocId: "doc-1", in: root), want)
        XCTAssertTrue(DerivedManuscript.materialize(forDocId: "doc-1", in: root).contains("xg8q"))
    }

    /// Legacy ops (no explicit sequence) still yield ordered, non-empty text — op-log-only.
    func test_materialize_legacyNoSequence_synthesisesOrder() throws {
        let ops = [op("01a", seq: nil, changes: [("aaaa", "Alpha.")]),
                   op("01b", seq: nil, changes: [("bbbb", "Beta.")])]
        let root = try makeProject(docId: "doc-1", ops: ops)
        let text = DerivedManuscript.materialize(forDocId: "doc-1", in: root)
        XCTAssertTrue(text.contains("Alpha.") && text.contains("Beta."),
            "legacy logs must still materialise, order synthesised from ops (never the .md)")
    }

    /// derivedState exposes paragraphs + sequence directly.
    func test_derivedState_exposesParagraphsAndSequence() throws {
        let ops = [op("01a", seq: ["n5sg"], changes: [("n5sg", "Only.")])]
        let root = try makeProject(docId: "doc-1", ops: ops)
        let s = DerivedManuscript.derivedState(forDocId: "doc-1", in: root)
        XCTAssertEqual(s.paragraphs["n5sg"], "Only.")
        XCTAssertEqual(s.sequence, ["n5sg"])
    }

    /// A junk empty-sequence bootstrap op must NOT clobber the first-appearance
    /// synthesis fallback in `deriveWithSequenceFallback`. Before the guard was
    /// added, the bootstrap set `sequence = []` AND `sequenceWasExplicit = true`,
    /// so the synthesis branch never fired and the result was `[]` instead of the
    /// correct first-appearance order.
    func test_deriveWithSequenceFallback_junkEmptyBootstrap_survivesIntoSynthesis() {
        // Junk bootstrap with sequence: [] — exists in the wild per derive's comment.
        let junkBootstrap = Op(opId: "0001", docId: "doc-1",
                               at: Date(timeIntervalSince1970: 0),
                               device: "d", session: "s", kind: .bootstrap,
                               changes: [], sequence: [], provenance: nil)
        // Sequence-less typing-burst ops; opIds sort after the bootstrap so
        // first-appearance order is deterministically aaaa → bbbb → cccc.
        let burst1 = Op(opId: "0002", docId: "doc-1",
                        at: Date(timeIntervalSince1970: 1),
                        device: "d", session: "s", kind: .typingBurst,
                        changes: [Op.ParagraphChange(paragraphId: "aaaa", prior: nil, next: "Alpha.")],
                        sequence: nil, provenance: nil)
        let burst2 = Op(opId: "0003", docId: "doc-1",
                        at: Date(timeIntervalSince1970: 2),
                        device: "d", session: "s", kind: .typingBurst,
                        changes: [Op.ParagraphChange(paragraphId: "bbbb", prior: nil, next: "Beta.")],
                        sequence: nil, provenance: nil)
        let burst3 = Op(opId: "0004", docId: "doc-1",
                        at: Date(timeIntervalSince1970: 3),
                        device: "d", session: "s", kind: .typingBurst,
                        changes: [Op.ParagraphChange(paragraphId: "cccc", prior: nil, next: "Gamma.")],
                        sequence: nil, provenance: nil)
        let state = Deriver.deriveWithSequenceFallback(ops: [junkBootstrap, burst1, burst2, burst3])
        XCTAssertEqual(state.sequence, ["aaaa", "bbbb", "cccc"],
            "junk empty-sequence bootstrap must not clobber first-appearance synthesis")
    }

    /// No ops → empty string (no crash, no .md read).
    func test_materialize_noOps_isEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dm-empty-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(DerivedManuscript.materialize(forDocId: "doc-x", in: root), "")
    }
}
