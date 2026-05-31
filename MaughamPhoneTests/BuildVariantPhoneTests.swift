import XCTest
import MaughamCore
@testable import MaughamPhone

/// Mirrors the Mac's BuildVariantTests for the iOS-only knobs added in
/// BuildVariantPhone.swift. Both values must differ between dev and stable so a
/// dev build's bundle id + bookmarked folder never leak into stable.
final class BuildVariantPhoneTests: XCTestCase {
    func test_phoneBundleId_differsByVariant() {
        // Capital "M" — matches the registered Apple App ID com.Maugham.MaughamPhone
        // (see CLAUDE.md → phone bundle-id note). Codesign is case-sensitive, so this
        // pins the exact casing the build ships with.
        XCTAssertEqual(BuildVariant.stable.phoneBundleId, "com.Maugham.MaughamPhone")
        XCTAssertEqual(BuildVariant.dev.phoneBundleId, "com.Maugham.MaughamPhone.dev")
        XCTAssertNotEqual(BuildVariant.stable.phoneBundleId, BuildVariant.dev.phoneBundleId)
    }

    func test_bookmarkUserDefaultsKey_differsByVariant() {
        XCTAssertEqual(BuildVariant.stable.bookmarkUserDefaultsKey, "projectsRootBookmark.stable")
        XCTAssertEqual(BuildVariant.dev.bookmarkUserDefaultsKey, "projectsRootBookmark.dev")
        XCTAssertNotEqual(BuildVariant.stable.bookmarkUserDefaultsKey,
                          BuildVariant.dev.bookmarkUserDefaultsKey)
    }
}
