import XCTest
import MaughamCore
@testable import Maugham

/// Cross-surface contract: an op-log filename built for a REAL minted docId must
/// round-trip back through OpLogStore.docId(...). Mac half — uses the production
/// minter so the test cannot re-encode a wrong id shape. Also asserts the minted
/// id against the shared `DocIdShape` contract (MaughamCore) that the phone's
/// half of this test consumes — a Mac-side shape change now fails HERE, not
/// silently (see docs/superpowers/notes/2026-07-11-maintainability-review.md §2 E5(b)).
@MainActor
final class OpLogFilenameContractTests: XCTestCase {
    func test_realMintedDocIds_roundTripThroughParser() {
        for prefix in ["doc", "scene"] {
            let docId = ProjectStore.newId(prefix: prefix)
            XCTAssertTrue(DocIdShape.isValid(docId), "ProjectStore.newId(prefix:) drifted from the shared DocIdShape contract")
            let slug = DeviceSlug.make(from: "MacTest:host")
            XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).jsonl"), docId)
            XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).\(slug.raw).jsonl"), docId)
        }
    }
}
