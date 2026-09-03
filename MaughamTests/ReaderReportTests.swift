import XCTest
@testable import Maugham

/// The blind reader's answer (translation pipeline spec §4): one object, an
/// `overall` verdict against the brief's texture line, and notes that can only
/// ever be about fluency. All-or-nothing, `TranslatorReport`'s doctrine.
final class ReaderReportTests: XCTestCase {

    private let briefed: Set<String> = ["k7mq", "a1b2"]

    func test_roundTrip_overallAndNotes() throws {
        let raw = """
            {"overall":{"verdict":"mixed","text":"Reads well until the dialogue."},
             "notes":[{"paragraph_id":"k7mq","kind":"register","severity":"major","text":"Too formal for a bar."}]}
            """
        let report = try XCTUnwrap(ReaderReport.parse(raw, briefedParagraphIds: briefed))
        XCTAssertEqual(report.overall.verdict, .mixed)
        XCTAssertEqual(report.overall.text, "Reads well until the dialogue.")
        XCTAssertEqual(report.notes, [.init(paragraphId: "k7mq", kind: .register, severity: .major, text: "Too formal for a bar.")])
    }

    func test_zeroNotesIsAValidReport() throws {
        let raw = #"{"overall":{"verdict":"reads_as_native","text":"Clean."},"notes":[]}"#
        let report = try XCTUnwrap(ReaderReport.parse(raw, briefedParagraphIds: briefed))
        XCTAssertTrue(report.notes.isEmpty)
        let absent = #"{"overall":{"verdict":"reads_as_native","text":"Clean."}}"#
        XCTAssertEqual(ReaderReport.parse(absent, briefedParagraphIds: briefed)?.notes, [])
    }

    func test_overallIsRequired() {
        XCTAssertNil(ReaderReport.parse(#"{"notes":[]}"#, briefedParagraphIds: briefed))
        XCTAssertNil(ReaderReport.parse(#"{"overall":{"verdict":"mixed","text":""},"notes":[]}"#, briefedParagraphIds: briefed), "empty text refused")
        XCTAssertNil(ReaderReport.parse(#"{"overall":{"verdict":"great","text":"x"},"notes":[]}"#, briefedParagraphIds: briefed), "closed verdict enum")
    }

    func test_aNoteOutsideTheBriefedSetFailsTheReport() {
        let raw = #"{"overall":{"verdict":"mixed","text":"x"},"notes":[{"paragraph_id":"zzzz","kind":"rhythm","severity":"minor","text":"limps"}]}"#
        XCTAssertNil(ReaderReport.parse(raw, briefedParagraphIds: briefed))
    }

    func test_kindAndSeverityAreClosedEnums() {
        let badKind = #"{"overall":{"verdict":"mixed","text":"x"},"notes":[{"paragraph_id":"k7mq","kind":"mistranslation","severity":"minor","text":"y"}]}"#
        XCTAssertNil(ReaderReport.parse(badKind, briefedParagraphIds: briefed), "a reader cannot file an accuracy kind")
        let badSeverity = #"{"overall":{"verdict":"mixed","text":"x"},"notes":[{"paragraph_id":"k7mq","kind":"rhythm","severity":"critical","text":"y"}]}"#
        XCTAssertNil(ReaderReport.parse(badSeverity, briefedParagraphIds: briefed))
    }

    func test_aNoteWithEmptyTextFailsTheReport() {
        let raw = #"{"overall":{"verdict":"mixed","text":"x"},"notes":[{"paragraph_id":"k7mq","kind":"rhythm","severity":"minor","text":"  "}]}"#
        XCTAssertNil(ReaderReport.parse(raw, briefedParagraphIds: briefed))
    }

    func test_proseWrappedFence_takesTheLastCompleteBlock() throws {
        let raw = """
            Here is a draft {"overall":{"verdict":"mixed","text":"draft"}} and the answer:
            ```json
            {"overall":{"verdict":"reads_as_translated","text":"final"},"notes":[]}
            ```
            """
        XCTAssertEqual(try XCTUnwrap(ReaderReport.parse(raw, briefedParagraphIds: briefed)).overall.text, "final")
    }

    func test_wireFieldNamesAppearInTheSchemaDescription() {
        for name in ["overall", "verdict", "text", "notes", "paragraph_id", "kind", "severity"] {
            XCTAssertTrue(ReaderReport.schemaDescription.contains(name), name)
        }
        for verdict in ReaderReport.Verdict.allCases {
            XCTAssertTrue(ReaderReport.schemaDescription.contains(verdict.rawValue), verdict.rawValue)
        }
        for kind in ReaderReport.NoteKind.allCases {
            XCTAssertTrue(ReaderReport.schemaDescription.contains(kind.rawValue), kind.rawValue)
        }
        for severity in ReaderReport.Severity.allCases {
            XCTAssertTrue(ReaderReport.schemaDescription.contains(severity.rawValue), severity.rawValue)
        }
        XCTAssertTrue(ReaderReport.schemaDescription.contains("Do not rewrite"))
    }
}
