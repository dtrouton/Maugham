import XCTest
import MaughamCore

final class ExperimentHarnessSmokeTests: XCTestCase {
    func test_harnessCanReachBothModulesUnderTest() {
        XCTAssertEqual(PaletteCard.color(fromHex: "#FFF")?.r, 1.0)
        XCTAssertTrue(TreeWalk.collectIds(in: [StructureItem]()).isEmpty)
    }
}
