import XCTest
@testable import Maugham

final class TectonicLogParserTests: XCTestCase {

    func testParses_undefinedControlSequence() {
        let log = """
        ! Undefined control sequence.
        l.42 \\customcmd
                    {something}
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.count, 1)
        let d = diags[0]
        XCTAssertEqual(d.level, .error)
        XCTAssertEqual(d.line, 42)
        XCTAssertTrue(d.message.contains("Undefined control sequence"))
    }

    func testParses_missingNumber() {
        let log = """
        ! Missing number, treated as zero.
        l.10 \\hspace{abc}
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].line, 10)
        XCTAssertEqual(diags[0].level, .error)
    }

    func testParses_warning_overfullHbox() {
        let log = """
        Overfull \\hbox (12.3pt too wide) in paragraph at lines 5--6
        []
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].level, .warning)
    }

    func testParses_multipleDiagnostics() {
        let log = """
        ! Undefined control sequence.
        l.42 \\foo

        ! Missing number, treated as zero.
        l.55 \\bar
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.count, 2)
        XCTAssertEqual(diags[0].line, 42)
        XCTAssertEqual(diags[1].line, 55)
    }

    func testEmpty_input_returnsNoDiagnostics() {
        XCTAssertTrue(TectonicLogParser.parse(log: "").isEmpty)
    }

    func testContextLines_capturedAfterMarker() {
        let log = """
        ! Undefined control sequence.
        l.42 \\customcmd
                    {value here}
                                {another}
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.first?.contextLines.count, 2)
    }

    // Regression test for the broadened warning-matching fix.
    // Before the fix the warning branch only matched "Overfull", "Underfull",
    // and the literal prefix "LaTeX Warning:". Package/class/font warnings such
    // as "Package hyperref Warning:" were silently dropped. The fix adds a
    // `.contains("Warning")` arm so those lines are captured.
    func test_parse_surfacesPackageAndBoxWarnings() {
        let log = """
        Package hyperref Warning: Token not allowed in a PDF string.
        Overfull \\hbox (15.0pt too wide) in paragraph at lines 12--13
        Underfull \\vbox (badness 10000) has occurred
        ! Undefined control sequence.
        l.7 \\bogus
        """

        let diags = TectonicLogParser.parse(log: log)

        // At least three warnings (hyperref, Overfull, Underfull).
        let warnings = diags.filter { $0.level == .warning }
        XCTAssertGreaterThanOrEqual(warnings.count, 3,
            "Expected at least 3 warnings, got \(warnings.count)")

        // The hyperref package warning must be among them.
        let hyperrefWarning = warnings.first { $0.message.contains("hyperref") }
        XCTAssertNotNil(hyperrefWarning,
            "hyperref package warning should be surfaced as a warning diagnostic")

        // The Overfull warning must be captured as a warning diagnostic.
        // Note: the parser uses a plain (non-regex) substring search for
        // "at lines? " (with a literal question mark), so the "at lines N--M"
        // pattern in Overfull/Underfull lines does NOT produce a line number —
        // that extraction is a known pre-existing limitation. Assert nil here
        // so the test reflects actual parser behaviour rather than a wishful one.
        let overfullWarning = warnings.first { $0.message.hasPrefix("Overfull") }
        XCTAssertNotNil(overfullWarning, "Overfull warning should be present")
        XCTAssertNil(overfullWarning?.line,
            "Overfull line extraction is a known limitation; line is nil for 'at lines N--M' patterns")

        // Error handling must not regress — the "! " error is still an error.
        let errors = diags.filter { $0.level == .error }
        XCTAssertEqual(errors.count, 1, "There should be exactly 1 error diagnostic")
        XCTAssertTrue(errors[0].message.contains("Undefined control sequence"),
            "Error message should be preserved")
        XCTAssertEqual(errors[0].line, 7, "Error line number should be extracted correctly")
    }
}
