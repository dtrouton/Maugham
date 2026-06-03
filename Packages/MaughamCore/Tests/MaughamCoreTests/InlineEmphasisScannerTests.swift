import XCTest
@testable import MaughamCore

final class InlineEmphasisScannerTests: XCTestCase {
    func testTraitsSetSemantics() {
        let both: EmphasisTraits = [.bold, .italic]
        XCTAssertTrue(both.contains(.bold))
        XCTAssertTrue(both.contains(.italic))
        XCTAssertEqual(EmphasisTraits.bold.union(.italic), both)
        XCTAssertTrue(EmphasisTraits().isEmpty)
    }
}
