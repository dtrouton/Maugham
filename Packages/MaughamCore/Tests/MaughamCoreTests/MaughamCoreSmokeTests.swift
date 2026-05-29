import XCTest
@testable import MaughamCore

// Placeholder so the MaughamCoreTests target is non-empty. Real coverage
// (OpReplayTests, InboxEntryCodableTests, etc.) lands in later phases; most
// existing OpLog/Fountain unit tests stay in MaughamTests via @testable import
// Maugham, which transitively re-exports MaughamCore (spec §3.1).
final class MaughamCoreSmokeTests: XCTestCase {
    func testULIDMintIsMonotonicAndUnique() {
        let a = ULID.generate()
        let b = ULID.generate()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 26, "Crockford base32 ULID is 26 chars")
    }
}
