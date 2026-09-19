// MaughamTests/Updates/MinimumSystemVersionTests.swift
import XCTest
@testable import Maugham

/// The pure half of "the updater refuses a build this Mac cannot run": how the
/// minimum-macOS fact is carried in a release body, how it is read back, and
/// how it compares against the running system.
final class MinimumSystemVersionTests: XCTestCase {

    // MARK: - Parsing a version string

    func test_aBareMajorIsAVersion() {
        XCTAssertEqual(MinimumSystemVersion("27"), MinimumSystemVersion(major: 27))
    }

    func test_majorAndMinorParse() {
        XCTAssertEqual(MinimumSystemVersion("26.5"), MinimumSystemVersion(major: 26, minor: 5))
    }

    func test_aPatchComponentIsKept() {
        XCTAssertEqual(MinimumSystemVersion("14.4.1"),
                       MinimumSystemVersion(major: 14, minor: 4, patch: 1))
    }

    func test_nonNumericIsNotAVersion() {
        XCTAssertNil(MinimumSystemVersion("banana"))
        XCTAssertNil(MinimumSystemVersion(""))
        XCTAssertNil(MinimumSystemVersion("27."))
        XCTAssertNil(MinimumSystemVersion("27.0.0.0"))
    }

    // MARK: - How it reads back to a writer

    func test_trailingZeroesAreNotSpoken() {
        XCTAssertEqual(MinimumSystemVersion(major: 27).displayString, "27")
        XCTAssertEqual(MinimumSystemVersion(major: 27, minor: 1).displayString, "27.1")
        XCTAssertEqual(MinimumSystemVersion(major: 14, minor: 4, patch: 1).displayString, "14.4.1")
        XCTAssertEqual(MinimumSystemVersion(major: 27, minor: 0, patch: 2).displayString, "27.0.2")
    }

    // MARK: - Satisfaction

    func test_aBuildAboveThisMacIsNotSatisfied() {
        let required = MinimumSystemVersion(major: 27)
        XCTAssertFalse(required.isSatisfied(by: MinimumSystemVersion(major: 26, minor: 5)))
    }

    func test_aBuildAtThisMacIsSatisfied() {
        let required = MinimumSystemVersion(major: 27)
        XCTAssertTrue(required.isSatisfied(by: MinimumSystemVersion(major: 27)))
    }

    func test_aBuildBelowThisMacIsSatisfied() {
        let required = MinimumSystemVersion(major: 26)
        XCTAssertTrue(required.isSatisfied(by: MinimumSystemVersion(major: 27, minor: 1)))
    }

    func test_minorsDecideWhenTheMajorsAgree() {
        let required = MinimumSystemVersion(major: 26, minor: 5)
        XCTAssertFalse(required.isSatisfied(by: MinimumSystemVersion(major: 26, minor: 4)))
        XCTAssertTrue(required.isSatisfied(by: MinimumSystemVersion(major: 26, minor: 5)))
    }

    func test_theRunningSystemIsProcessInfosAnswer() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(MinimumSystemVersion.runningSystem,
                       MinimumSystemVersion(major: os.majorVersion,
                                            minor: os.minorVersion,
                                            patch: os.patchVersion))
    }

    // MARK: - Reading the fact off a release body

    func test_theMarkerIsReadOffTheBody() {
        let body = """
        ## What's new

        Everything.

        <!-- maugham-minimum-macos: 27.0 -->
        """
        XCTAssertEqual(MinimumSystemVersion.parse(releaseBody: body),
                       MinimumSystemVersion(major: 27))
    }

    /// Every release before 0.40.0 carries no such line, and those are offered
    /// exactly as they are today — never refused for lack of the field.
    func test_aBodyWithoutTheMarkerCarriesNoFact() {
        XCTAssertNil(MinimumSystemVersion.parse(releaseBody: "## What's new\n\nEverything."))
        XCTAssertNil(MinimumSystemVersion.parse(releaseBody: ""))
    }

    /// The workflow appends its line last, so the last one is the authoritative
    /// one — a stray earlier marker (a hand-written note quoting one) loses.
    func test_theLastMarkerWins() {
        let body = """
        <!-- maugham-minimum-macos: 14.0 -->
        notes
        <!-- maugham-minimum-macos: 27.0 -->
        """
        XCTAssertEqual(MinimumSystemVersion.parse(releaseBody: body),
                       MinimumSystemVersion(major: 27))
    }

    func test_aMarkerWithAnUnreadableValueCarriesNoFact() {
        XCTAssertNil(MinimumSystemVersion.parse(
            releaseBody: "<!-- maugham-minimum-macos: banana -->"))
    }

    func test_theMarkerIsFoundThroughSurroundingWhitespace() {
        XCTAssertEqual(
            MinimumSystemVersion.parse(releaseBody: "   <!--   maugham-minimum-macos:  27.1   -->  "),
            MinimumSystemVersion(major: 27, minor: 1))
    }

    // MARK: - The marker never reaches the writer's eyes

    /// The sheet renders the release body as plain `Text`, so an HTML comment
    /// would show as literal markup. It is stripped before display.
    func test_theMarkerIsStrippedFromWhatTheSheetShows() {
        let body = "## What's new\n\nEverything.\n\n<!-- maugham-minimum-macos: 27.0 -->\n"
        XCTAssertEqual(MinimumSystemVersion.strippingMarker(from: body),
                       "## What's new\n\nEverything.")
    }

    func test_strippingABodyWithoutTheMarkerChangesNothingButTrailingSpace() {
        XCTAssertEqual(MinimumSystemVersion.strippingMarker(from: "## What's new\n\nEverything."),
                       "## What's new\n\nEverything.")
    }

    func test_strippingKeepsProseThatMerelyMentionsMacOS() {
        let body = "Requires macOS 27 or later.\n\n<!-- maugham-minimum-macos: 27.0 -->"
        XCTAssertEqual(MinimumSystemVersion.strippingMarker(from: body),
                       "Requires macOS 27 or later.")
    }
}
