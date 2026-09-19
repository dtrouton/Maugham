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

    // MARK: - The writer and the reader are two files apart

    /// `release.yml` writes the marker and this parser reads it, so the
    /// spelling is a contract across two files with nothing but this test
    /// between them. Divergence fails in the worst direction and in SILENCE:
    /// a body whose marker the parser cannot see carries no fact, and every
    /// release is offered again to Macs that cannot run it — the exact bug
    /// this machinery exists to close.
    func test_theWorkflowWritesTheMarkerThisParserReads() throws {
        let workflow = try String(contentsOf: Self.releaseWorkflowURL, encoding: .utf8)

        // The printf format the Compose step appends, with %s standing for the
        // app's LSMinimumSystemVersion. Pulled out of the workflow's own text
        // and round-tripped, so a rename on either side is caught here.
        let pattern = #"printf '([^']*)' "\$MIN_OS""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(workflow.startIndex..., in: workflow)
        guard let match = regex.firstMatch(in: workflow, range: range),
              let formatRange = Range(match.range(at: 1), in: workflow) else {
            return XCTFail("release.yml no longer appends a printf'd minimum-macOS line")
        }
        let appended = String(workflow[formatRange])
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "%s", with: "27.0")

        XCTAssertEqual(MinimumSystemVersion.parse(releaseBody: "notes" + appended),
                       MinimumSystemVersion(major: 27),
                       "the line release.yml appends must parse back to what it published")
        XCTAssertEqual(MinimumSystemVersion.strippingMarker(from: "notes" + appended), "notes")
    }

    /// The Compose step writes one file and the Create step publishes another;
    /// if they drift, the marker never reaches the release and every build is
    /// offered as before — silently.
    func test_theComposedBodyIsTheOneThatGetsPublished() throws {
        let workflow = try String(contentsOf: Self.releaseWorkflowURL, encoding: .utf8)
        // Anchored on the marker's own printf — the workflow is full of
        // unrelated `>> "$GITHUB_OUTPUT"` appends.
        let regex = try NSRegularExpression(pattern: #"printf '[^']*' "\$MIN_OS" >> (\S+)"#)
        let range = NSRange(workflow.startIndex..., in: workflow)
        guard let match = regex.firstMatch(in: workflow, range: range),
              let pathRange = Range(match.range(at: 1), in: workflow) else {
            return XCTFail("release.yml no longer appends the marker to a composed body file")
        }
        let composed = String(workflow[pathRange])
        XCTAssertTrue(workflow.contains("body_path: \(composed)"),
                      "release.yml composes \(composed) but publishes something else")
    }

    private static var releaseWorkflowURL: URL {
        // MaughamTests/Updates/<this file> → repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/release.yml")
    }
}
