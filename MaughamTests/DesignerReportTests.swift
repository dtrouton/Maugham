import XCTest
@testable import Maugham

final class DesignerReportTests: XCTestCase {

    // MARK: - Round-trip

    func test_roundTrip_specAndFiles() throws {
        let raw = """
            {"spec":"# Dropcaps\\nA drop cap on every chapter opener.",\
            "files":[\
            {"path":"template.tex","content":"\\\\documentclass{book}"},\
            {"path":"partials/dropcaps.tex","content":""}]}
            """

        let report = try XCTUnwrap(DesignerReport.parse(raw))

        XCTAssertEqual(report.specMarkdown, "# Dropcaps\nA drop cap on every chapter opener.")
        XCTAssertEqual(report.files.count, 2)
        XCTAssertEqual(report.files[0].path, "template.tex")
        XCTAssertEqual(report.files[0].content, "\\documentclass{book}")
        XCTAssertEqual(report.files[1].path, "partials/dropcaps.tex")
        XCTAssertEqual(report.files[1].content, "")
    }

    // MARK: - Prose-wrapped fence

    func test_proseWrappedFence_takesTheLastCompleteBlock() throws {
        let raw = """
            Let me think this through. For example I might write something \
            like {"spec":"draft","files":[]} but that's not my real answer.

            ```json
            {"spec":"A serif template with a wide margin for marginalia.",\
            "files":[{"path":"styles.css","content":"body { color: black; }"}]}
            ```

            That's my answer for this round.
            """

        let report = try XCTUnwrap(DesignerReport.parse(raw))

        XCTAssertEqual(report.specMarkdown, "A serif template with a wide margin for marginalia.")
        XCTAssertEqual(report.files.count, 1)
        XCTAssertEqual(report.files[0].path, "styles.css")
    }

    func test_proseWrappedFence_narratedLineStillParses() throws {
        let raw = """
            Here is this round's report: \
            {"spec":"No files this round, just a question.","files":[]} \
            — let me know if you need anything else.
            """

        let report = try XCTUnwrap(DesignerReport.parse(raw))

        XCTAssertEqual(report.specMarkdown, "No files this round, just a question.")
        XCTAssertTrue(report.files.isEmpty)
    }

    // MARK: - Empty files is valid

    func test_emptyFilesWithNonEmptySpecIsAValidReport() throws {
        let raw = #"{"spec":"A question for the writer, no files proposed.","files":[]}"#

        let report = try XCTUnwrap(DesignerReport.parse(raw))

        XCTAssertEqual(report.specMarkdown, "A question for the writer, no files proposed.")
        XCTAssertTrue(report.files.isEmpty)
    }

    func test_missingFilesKeyReadsAsEmptyList() throws {
        let raw = #"{"spec":"Words only."}"#

        let report = try XCTUnwrap(DesignerReport.parse(raw))

        XCTAssertTrue(report.files.isEmpty)
    }

    func test_fileWithEmptyContentIsValid() throws {
        // An empty partial is a legitimate design choice, not a refusal.
        let raw = #"{"spec":"A stub partial to fill in later.","files":[{"path":"partials/stub.tex","content":""}]}"#

        let report = try XCTUnwrap(DesignerReport.parse(raw))

        XCTAssertEqual(report.files.first?.content, "")
    }

    // MARK: - Spec refusals

    func test_missingSpec_returnsNil() {
        let raw = #"{"files":[]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_emptySpec_returnsNil() {
        let raw = #"{"spec":"","files":[]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_whitespaceOnlySpec_returnsNil() {
        let raw = #"{"spec":"   \n  ","files":[]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_specIsTrimmed() throws {
        let raw = #"{"spec":"  A margin note design.  ","files":[]}"#
        let report = try XCTUnwrap(DesignerReport.parse(raw))
        XCTAssertEqual(report.specMarkdown, "A margin note design.")
    }

    // MARK: - Path refusals — each nils the whole report

    func test_absolutePathRefusesTheWholeReport() {
        let raw = #"{"spec":"A template change.","files":[{"path":"/etc/passwd","content":"x"}]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_dotDotTraversalRefusesTheWholeReport() {
        let raw = #"{"spec":"A template change.","files":[{"path":"../secrets.tex","content":"x"}]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_dotDotTraversalInAnInnerSegmentRefusesTheWholeReport() {
        // The brief's own example: `a/../b` — `..` as a segment anywhere in
        // the path, not just as a prefix.
        let raw = #"{"spec":"A template change.","files":[{"path":"a/../b","content":"x"}]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_dotDotSubstringInAFilenameIsNotTraversal() throws {
        // Only an exact `..` PATH SEGMENT is traversal — a filename that
        // merely contains two dots is legal, same discipline as PublishPath.
        let raw = #"{"spec":"A template change.","files":[{"path":"chapter..outline.tex","content":"x"}]}"#
        let report = try XCTUnwrap(DesignerReport.parse(raw))
        XCTAssertEqual(report.files.first?.path, "chapter..outline.tex")
    }

    func test_configJsonRefusesTheWholeReport() {
        let raw = #"{"spec":"A config tweak.","files":[{"path":"config.json","content":"{}"}]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_configJsonAnyCaseRefusesTheWholeReport() {
        let raw = #"{"spec":"A config tweak.","files":[{"path":"CONFIG.JSON","content":"{}"}]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_configJsonNestedUnderADirectoryStillRefuses() {
        // The reserved name is refused wherever it would land, not only at
        // the publish root — there is no legitimate reason for a design
        // proposal to produce a file named config.json anywhere.
        let raw = #"{"spec":"A config tweak.","files":[{"path":"partials/config.json","content":"{}"}]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_duplicatePathsRefuseTheWholeReport() {
        let raw = """
            {"spec":"Two passes at the same file.",\
            "files":[{"path":"template.tex","content":"a"},\
            {"path":"template.tex","content":"b"}]}
            """
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_agoodFileBesideABadPathRefusesTheWholeReportTooAllOrNothing() {
        let raw = """
            {"spec":"One good file, one bad one.",\
            "files":[{"path":"styles.css","content":"body{}"},\
            {"path":"/etc/passwd","content":"x"}]}
            """
        XCTAssertNil(DesignerReport.parse(raw),
                     "the good file beside it is refused too — all-or-nothing")
    }

    func test_emptyPathRefusesTheWholeReport() {
        let raw = #"{"spec":"A file with no name.","files":[{"path":"","content":"x"}]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_pathIsTrimmed() throws {
        let raw = #"{"spec":"A trimmed path.","files":[{"path":"  template.tex  ","content":"x"}]}"#
        let report = try XCTUnwrap(DesignerReport.parse(raw))
        XCTAssertEqual(report.files.first?.path, "template.tex")
    }

    // MARK: - Malformed → nil

    func test_notJSON_returnsNil() {
        XCTAssertNil(DesignerReport.parse("I don't have anything to propose this round."))
    }

    func test_truncatedJSON_returnsNil() {
        let raw = #"{"spec":"Cut off mid"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_filesNotAnArray_returnsNil() {
        let raw = #"{"spec":"A template change.","files":"not a list"}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_fileMissingPath_returnsNil() {
        let raw = #"{"spec":"A template change.","files":[{"content":"x"}]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_fileMissingContent_returnsNil() {
        // `content` must be present, even as an empty string — its absence
        // is a form the model has lost, same discipline as a translator
        // entry with neither `text` nor `verbatim`.
        let raw = #"{"spec":"A template change.","files":[{"path":"template.tex"}]}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    func test_noRecognizableObjectAtAll_returnsNil() {
        let raw = #"{"foo":"bar"}"#
        XCTAssertNil(DesignerReport.parse(raw))
    }

    // MARK: - Wire names in one place

    func test_wireFieldNamesAppearInTheSchemaDescription() {
        let schema = DesignerReport.schemaDescription
        XCTAssertTrue(schema.contains(DesignerReport.WireField.spec))
        XCTAssertTrue(schema.contains(DesignerReport.WireField.files))
        XCTAssertTrue(schema.contains(DesignerReport.WireField.path))
        XCTAssertTrue(schema.contains(DesignerReport.WireField.content))
    }

    /// The contract the parser enforces has to be the contract the model is
    /// shown: a refusal the schema never mentioned reads as a random failure.
    func test_theSchemaStatesContentMayBeEmpty() {
        let schema = DesignerReport.schemaDescription
        XCTAssertTrue(schema.contains("may be empty") || schema.contains("MAY be empty"), schema)
    }

    func test_theSchemaStatesTheConfigJsonRefusal() {
        let schema = DesignerReport.schemaDescription
        XCTAssertTrue(schema.lowercased().contains("config.json"), schema)
    }
}
