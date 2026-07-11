import XCTest
import MaughamCore
@testable import Maugham

/// Cross-surface contract: an op-log filename built for a REAL minted docId must
/// round-trip back through OpLogStore.docId(...). Mac half — uses the production
/// minter so the test cannot re-encode a wrong id shape.
@MainActor
final class OpLogFilenameContractTests: XCTestCase {
    func test_realMintedDocIds_roundTripThroughParser() {
        for prefix in ["doc", "scene"] {
            let docId = ProjectStore.newId(prefix: prefix)
            let slug = DeviceSlug.make(from: "MacTest:host")
            XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).jsonl"), docId)
            XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).\(slug.raw).jsonl"), docId)
        }
    }
}
