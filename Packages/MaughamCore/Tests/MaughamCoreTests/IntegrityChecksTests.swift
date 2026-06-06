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
}
