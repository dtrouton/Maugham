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
}
