import XCTest

/// `THIRD-PARTY-LICENSES.md` exists twice on purpose: the repo-root copy is the
/// canonical one (linked from README.md / LICENSE.md and rendered on GitHub),
/// and `Maugham/Resources/THIRD-PARTY-LICENSES.md` is the copy that actually
/// ships in the app bundle (xcodegen won't bundle a bare repo-root file, so the
/// in-bundle copy lives under the `*.md` resource glob). They MUST stay
/// byte-identical — a stale bundled copy means the shipped binary carries
/// wrong third-party attribution (an MIT-compliance gap). This pins them.
final class ThirdPartyLicensesDriftTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
    }

    func test_rootAndBundledCopiesAreIdentical() throws {
        let root = try String(
            contentsOf: repoRoot.appendingPathComponent("THIRD-PARTY-LICENSES.md"),
            encoding: .utf8)
        let bundled = try String(
            contentsOf: repoRoot.appendingPathComponent("Maugham/Resources/THIRD-PARTY-LICENSES.md"),
            encoding: .utf8)
        XCTAssertEqual(root, bundled,
            "THIRD-PARTY-LICENSES.md drifted between repo root and Maugham/Resources/ — update both (the root copy is canonical; the Resources copy is what ships in the app).")
    }
}
