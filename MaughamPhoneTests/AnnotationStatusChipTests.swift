import XCTest
@testable import MaughamPhone
import MaughamCore

final class AnnotationStatusChipTests: XCTestCase {
    func test_openHasNoChip() {
        XCTAssertNil(AnnotationStatusChip.label(.open))
        XCTAssertNil(AnnotationStatusChip.symbol(.open))
    }

    /// Derived from `allCases` rather than a written-out list, so a status
    /// added later cannot ship a chipless row: the switches in
    /// `AnnotationStatusChip` are exhaustive, but nothing stopped a new arm
    /// from returning nil until this loop asked every case.
    func test_everyResolvedStatusHasLabelAndSymbol() {
        for status in AnnotationStatus.allCases where status != .open {
            XCTAssertNotNil(AnnotationStatusChip.label(status), "\(status) needs a label")
            XCTAssertNotNil(AnnotationStatusChip.symbol(status), "\(status) needs a symbol")
        }
        XCTAssertEqual(AnnotationStatusChip.label(.accepted), "Accepted")
        XCTAssertEqual(AnnotationStatusChip.label(.rejected), "Rejected")
        XCTAssertEqual(AnnotationStatusChip.label(.archived), "Archived")
        XCTAssertEqual(AnnotationStatusChip.label(.stetted), "Stet")
    }
}
