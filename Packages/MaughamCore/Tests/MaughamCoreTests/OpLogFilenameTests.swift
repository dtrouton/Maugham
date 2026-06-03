import XCTest
@testable import MaughamCore

/// The single source of truth for "what op-log filename maps to what docId".
/// Both surfaces delegate here; these assertions use the REAL minted id shapes
/// (doc-<hex> / scene-<hex>, ADR 0008), never a `d_<ULID>` literal.
final class OpLogFilenameTests: XCTestCase {
    func test_docId_parsesRealShapes_excludesProjectAndJunk() {
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "doc-0f677d7e.jsonl"), "doc-0f677d7e")
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "doc-0f677d7e.macA.jsonl"), "doc-0f677d7e")
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "scene-f8c9644e.mcp-cba8e063.jsonl"), "scene-f8c9644e")
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: "__project__.jsonl"))
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: "__project__.macA.jsonl"))
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: "notes.txt"))
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: ".jsonl"))
    }

    func test_docIds_dedupesPerDeviceAndLegacy() {
        let names = ["doc-0f677d7e.jsonl", "doc-0f677d7e.macA.jsonl",
                     "scene-f8c9644e.phoneB.jsonl", "__project__.jsonl"]
        XCTAssertEqual(OpLogStore.docIds(inOpsDirectoryFilenames: names),
                       ["doc-0f677d7e", "scene-f8c9644e"])
    }
}
