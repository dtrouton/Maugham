import XCTest
import MaughamCore
@testable import MaughamPhone

/// Cross-surface contract: phone half. The real minter lives in the Mac target,
/// so reproduce the PRODUCTION id form here (doc-<8 lowercase hex>) — never a
/// hand-typed `d_<ULID>` literal, which is what let the old test agree with the bug.
final class OpLogFilenameContractTests: XCTestCase {
    func test_productionFormDocIds_roundTripThroughParser() {
        let docId = "doc-" + UUID().uuidString.prefix(8).lowercased()
        let slug = DeviceSlug.make(from: "phone:host")
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).jsonl"), String(docId))
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).\(slug).jsonl"), String(docId))
    }
}
