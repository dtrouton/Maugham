import XCTest
@testable import MaughamPhone
import MaughamCore

final class AnnotationStatusChipTests: XCTestCase {
    func test_openHasNoChip() {
        XCTAssertNil(AnnotationStatusChip.label(.open))
        XCTAssertNil(AnnotationStatusChip.symbol(.open))
    }

    func test_resolvedStatusesHaveLabelAndSymbol() {
        for status in [AnnotationStatus.accepted, .rejected, .archived] {
            XCTAssertNotNil(AnnotationStatusChip.label(status), "\(status) needs a label")
            XCTAssertNotNil(AnnotationStatusChip.symbol(status), "\(status) needs a symbol")
        }
        XCTAssertEqual(AnnotationStatusChip.label(.accepted), "Accepted")
        XCTAssertEqual(AnnotationStatusChip.label(.rejected), "Rejected")
        XCTAssertEqual(AnnotationStatusChip.label(.archived), "Archived")
    }
}
