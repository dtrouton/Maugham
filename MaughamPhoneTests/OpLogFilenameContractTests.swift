import XCTest
import MaughamCore
@testable import MaughamPhone

/// Cross-surface contract: phone half. The real minter lives in the Mac target,
/// so this uses the shared `DocIdShape` contract (MaughamCore) instead of a
/// hand-typed literal — the original phone-v0.1.1 bug slipped through because
/// this test used to reproduce the id shape by hand (`d_<ULID>`), agreeing with
/// itself rather than with production. `DocIdShape` is asserted against the real
/// minter on the Mac side of this same contract
/// (MaughamTests/OpLogFilenameContractTests.swift), so a Mac-side shape change
/// now fails there and forces `DocIdShape` — and this test — to move together.
final class OpLogFilenameContractTests: XCTestCase {
    func test_productionFormDocIds_roundTripThroughParser() {
        let docId = DocIdShape.example
        XCTAssertTrue(DocIdShape.isValid(docId))
        let slug = DeviceSlug.make(from: "phone:host")
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).jsonl"), docId)
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).\(slug.raw).jsonl"), docId)
    }
}
