import XCTest
@testable import MaughamCore

final class IntegrityChecksTests: XCTestCase {
    private func checkpoint(_ id: String, pointers: [String: String]) -> Checkpoint {
        Checkpoint(checkpointId: id, label: "l", labelSource: .auto,
                   at: Date(timeIntervalSince1970: 0), device: "d", activeDoc: "doc-1",
                   docPointers: pointers, manuscriptWordCount: 0)
    }

    func test_danglingCheckpointPointers_flagsMissingOpIds() {
        let cps = [
            checkpoint("cp1", pointers: ["doc-1": "op-a", "doc-2": "op-x"]),
            checkpoint("cp2", pointers: ["doc-1": "op-gone"]),
        ]
        let opsByDoc: [String: Set<String>] = ["doc-1": ["op-a"], "doc-2": ["op-x"]]

        let dangling = IntegrityChecks.danglingCheckpointPointers(checkpoints: cps, opsByDoc: opsByDoc)

        XCTAssertEqual(dangling, [
            IntegrityChecks.DanglingPointer(checkpointId: "cp2", docId: "doc-1", opId: "op-gone")
        ])
    }

    func test_danglingCheckpointPointers_cleanWhenAllResolve() {
        let cps = [checkpoint("cp1", pointers: ["doc-1": "op-a"])]
        let dangling = IntegrityChecks.danglingCheckpointPointers(
            checkpoints: cps, opsByDoc: ["doc-1": ["op-a"]])
        XCTAssertTrue(dangling.isEmpty)
    }

    func test_conflictTwins_detectsICloudNumberedCopies() {
        let names = [
            "doc-0f677d7e.macA.jsonl",       // normal
            "doc-0f677d7e.macA 2.jsonl",     // iCloud conflict twin
            "scene-f8c9644e 3.jsonl",        // twin without device slug
            "doc-0f677d7e.phoneB.jsonl",     // normal
            "notes.txt",                     // ignored (not jsonl)
        ]
        XCTAssertEqual(
            Set(IntegrityChecks.conflictTwins(inOpsDirectoryFilenames: names)),
            ["doc-0f677d7e.macA 2.jsonl", "scene-f8c9644e 3.jsonl"])
    }

    func test_conflictTwins_emptyWhenNone() {
        XCTAssertTrue(IntegrityChecks.conflictTwins(
            inOpsDirectoryFilenames: ["doc-0f677d7e.macA.jsonl"]).isEmpty)
    }

    private func op(_ opId: String, changes: [(String, String)], sequence: [String]? = nil) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 0), device: "d", session: "s",
           kind: .typingBurst,
           changes: changes.map { Op.ParagraphChange(paragraphId: $0.0, prior: nil, next: $0.1) },
           sequence: sequence, provenance: nil)
    }

    func test_invalidParagraphIds_cleanForNormalOps() {
        let ops = [op("01A", changes: [("ab12", "hello")], sequence: ["ab12", "cd34"])]
        XCTAssertTrue(IntegrityChecks.invalidParagraphIds(inOps: ops).isEmpty)
    }

    func test_invalidParagraphIds_flagsEmptyId() {
        let ops = [op("01A", changes: [("", "orphaned text")])]
        XCTAssertEqual(IntegrityChecks.invalidParagraphIds(inOps: ops),
                       [IntegrityChecks.InvalidParagraphId(docId: "doc-1", opId: "01A", value: "")])
    }

    func test_invalidParagraphIds_flagsJunkInSequence() {
        let ops = [op("01A", changes: [("ab12", "t")], sequence: ["ab12", "bad id\n"])]
        XCTAssertEqual(IntegrityChecks.invalidParagraphIds(inOps: ops).map(\.value), ["bad id\n"])
    }

    func test_invalidParagraphIds_doesNotEnforceStrictAlphabet() {
        // Permissive in-memory ids (tripwire 8) must NOT be flagged — only garbage is.
        let ops = [op("01A", changes: [("p1", "t"), ("legacy-longer-id", "t2")])]
        XCTAssertTrue(IntegrityChecks.invalidParagraphIds(inOps: ops).isEmpty)
    }
}
