import XCTest
import MaughamCore
@testable import MaughamPhone

/// Mirrors the Mac's BuildVariantTests for the iOS-only knobs added in
/// BuildVariantPhone.swift. Both values must differ between dev and stable so a
/// dev build's bundle id + bookmarked folder never leak into stable.
final class BuildVariantPhoneTests: XCTestCase {
    func test_phoneBundleId_differsByVariant() {
        XCTAssertEqual(BuildVariant.stable.phoneBundleId, "com.maugham.MaughamPhone")
        XCTAssertEqual(BuildVariant.dev.phoneBundleId, "com.maugham.MaughamPhone.dev")
        XCTAssertNotEqual(BuildVariant.stable.phoneBundleId, BuildVariant.dev.phoneBundleId)
    }

    func test_bookmarkUserDefaultsKey_differsByVariant() {
        XCTAssertEqual(BuildVariant.stable.bookmarkUserDefaultsKey, "projectsRootBookmark.stable")
        XCTAssertEqual(BuildVariant.dev.bookmarkUserDefaultsKey, "projectsRootBookmark.dev")
        XCTAssertNotEqual(BuildVariant.stable.bookmarkUserDefaultsKey,
                          BuildVariant.dev.bookmarkUserDefaultsKey)
    }
}
