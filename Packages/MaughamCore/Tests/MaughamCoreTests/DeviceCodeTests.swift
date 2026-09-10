import Foundation
import XCTest
@testable import MaughamCore

/// The four-character code a device shows for itself — one spelling, shared by
/// the Mac's History pane, People & Devices and the phone's Settings row.
///
/// It is pinned exactly because it is a code the writer COMPARES: the phone
/// shows one screen and the Mac shows another, and if the two builds disagreed
/// about how many characters or which case, the comparison the code exists for
/// would silently fail.
final class DeviceCodeTests: XCTestCase {

    func test_theCodeIsTheFirstFourCharactersUppercased() {
        XCTAssertEqual(DeviceCode.short("a1b2c3d4e5f6"), "A1B2")
    }

    func test_aCodeIsAlreadyItsOwnCode() {
        XCTAssertEqual(DeviceCode.short(DeviceCode.short("a1b2c3d4e5f6")), "A1B2")
    }

    /// Not every fingerprint this reaches is a full hash — a test fixture or a
    /// truncated field can be shorter, and a code is still whatever there is.
    func test_aFingerprintShorterThanFourIsTheWholeOfIt() {
        XCTAssertEqual(DeviceCode.short("ab"), "AB")
    }

    func test_noFingerprintAtAllIsAnEmptyCode() {
        XCTAssertEqual(DeviceCode.short(""), "")
    }

    /// The Mac's History pane used to spell this itself; it now asks here, and
    /// a real fingerprint answers the same either way.
    func test_aRealFingerprintAnswersItsOwnFirstFourInCapitals() {
        let fingerprint = DeviceIdentity.softwareForTesting().fingerprint
        XCTAssertEqual(DeviceCode.short(fingerprint),
                       fingerprint.prefix(4).uppercased())
        XCTAssertEqual(DeviceCode.short(fingerprint).count, 4)
    }
}
