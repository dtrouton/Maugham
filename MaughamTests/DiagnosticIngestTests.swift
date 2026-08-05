import XCTest
@testable import Maugham
import MaughamCore

final class DiagnosticIngestTests: XCTestCase {

    private let runId = ULID.generate()
    private let docId = "doc-under-test"

    /// A live document of two paragraphs. `nil` for anything else — the same
    /// shape `DiagnosticsStore.live` reads paragraphs through.
    private func liveDoc(
        _ paragraphs: [String: String] = [
            "a1b2": "The first paragraph, as it stands right now.",
            "c3d4": "The second paragraph, as it stands right now.",
        ]
    ) -> (String) -> String? {
        { paragraphs[$0] }
    }

    private func parse(
        _ resultText: String, live: ((String) -> String?)? = nil
    ) -> DiagnosticIngest.Outcome? {
        DiagnosticIngest.parse(
            resultText: resultText, runId: runId, docId: docId,
            liveParagraphText: live ?? liveDoc())
    }

    // MARK: - The schema constant is the single source of field names

    /// The anti-drift pin: every wire name the parser reads is a name the
    /// prompt actually asks for. If Task 3's schema is reworded, this fails
    /// rather than the parser silently reading a field nobody sends.
    func test_fieldNamesComeFromThePromptsSchema() {
        let schema = CompilerPrompt.outputSchemaDescription
        for field in [
            DiagnosticIngest.Field.diagnostics, DiagnosticIngest.Field.paragraphId,
            DiagnosticIngest.Field.category, DiagnosticIngest.Field.body,
            DiagnosticIngest.Field.intentDrift,
        ] {
            XCTAssertTrue(
                schema.contains("\"\(field)\""),
                "the prompt's schema never names \"\(field)\"")
        }
    }

    // MARK: - Anchors are captured live, at ingest

    func test_anchorsCaptureLiveTextAtIngest() {
        let result = """
            {"diagnostics":[{"paragraph_id":"a1b2","category":"rhythm",\
            "body":"Three sentences in a row open the same way."}],\
            "intent_drift":null}
            """
        guard let outcome = parse(result) else { return XCTFail("expected an outcome") }

        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.droppedDangling, 0)
        XCTAssertNil(outcome.drift)

        let diagnostic = outcome.accepted[0]
        XCTAssertEqual(diagnostic.docId, docId)
        XCTAssertEqual(diagnostic.runId, runId)
        XCTAssertEqual(diagnostic.category, "rhythm")
        XCTAssertEqual(diagnostic.body, "Three sentences in a row open the same way.")
        XCTAssertEqual(diagnostic.anchor?.paragraphId, "a1b2")
        XCTAssertEqual(
            diagnostic.anchor?.anchorText, "The first paragraph, as it stands right now.",
            "the anchor must be the LIVE text at ingest, not anything the model echoed")
        XCTAssertFalse(diagnostic.id.isEmpty)
    }

    /// The captured anchor is what makes `DiagnosticsStore.live`'s exact-match
    /// staleness rule work: ingest, then edit the paragraph, and the note goes
    /// stale — which it cannot do if the anchor were left empty or guessed.
    func test_capturedAnchorDrivesLatentStaleness() {
        let result = """
            {"diagnostics":[{"paragraph_id":"a1b2","category":null,\
            "body":"A note."}],"intent_drift":null}
            """
        guard let outcome = parse(result) else { return XCTFail("expected an outcome") }
        guard let anchor = outcome.accepted.first?.anchor else {
            return XCTFail("expected an anchored diagnostic")
        }

        XCTAssertEqual(anchor.anchorText, liveDoc()("a1b2"))
        XCTAssertNotEqual(anchor.anchorText, "The first paragraph, rewritten.")
    }

    // MARK: - Dangling ids

    func test_danglingParagraphIdsAreDroppedNotFatal() {
        let result = """
            {"diagnostics":[\
            {"paragraph_id":"zzzz","category":"pace","body":"Gone paragraph."},\
            {"paragraph_id":"a1b2","category":"pace","body":"Live paragraph."}],\
            "intent_drift":null}
            """
        guard let outcome = parse(result) else {
            return XCTFail("a dangling id must not fail the whole run")
        }

        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.accepted[0].body, "Live paragraph.")
        XCTAssertEqual(outcome.droppedDangling, 1)
    }

    /// The prompt prints ids as `[a1b2]`; a model that copies the brackets is
    /// naming a paragraph the doc knows, so it is not dangling.
    func test_bracketedOrPilcrowedIdsStillResolve() {
        let result = """
            {"diagnostics":[\
            {"paragraph_id":"[a1b2]","category":null,"body":"Bracketed."},\
            {"paragraph_id":"\u{00b6}c3d4","category":null,"body":"Pilcrowed."}],\
            "intent_drift":null}
            """
        guard let outcome = parse(result) else { return XCTFail("expected an outcome") }

        XCTAssertEqual(outcome.droppedDangling, 0)
        XCTAssertEqual(
            outcome.accepted.map { $0.anchor?.paragraphId }, ["a1b2", "c3d4"],
            "the resolved id is stored, never the decorated spelling")
    }

    // MARK: - Unusable single notes

    /// An empty body is unusable content for one note, not for the run —
    /// same disposal as a dangling id (drop, count, carry on).
    func test_emptyBodiesAreDroppedAndCounted() {
        let result = """
            {"diagnostics":[\
            {"paragraph_id":"a1b2","category":null,"body":"   "},\
            {"paragraph_id":"c3d4","category":null,"body":"Real note."},\
            {"paragraph_id":"a1b2","category":null},\
            "not an object"],\
            "intent_drift":null}
            """
        guard let outcome = parse(result) else { return XCTFail("expected an outcome") }

        XCTAssertEqual(outcome.accepted.map { $0.body }, ["Real note."])
        XCTAssertEqual(outcome.droppedDangling, 3)
    }

    // MARK: - Null paragraph_id — anchorless, but not drift

    func test_nullParagraphIdIsAnchorlessAndKeepsItsOwnCategory() {
        let result = """
            {"diagnostics":[{"paragraph_id":null,"category":"structure",\
            "body":"The delta as a whole circles one idea."}],\
            "intent_drift":null}
            """
        guard let outcome = parse(result) else { return XCTFail("expected an outcome") }

        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertNil(outcome.accepted[0].anchor)
        XCTAssertEqual(
            outcome.accepted[0].category, "structure",
            "a whole-delta note is not a drift note and must keep its category")
        XCTAssertEqual(outcome.droppedDangling, 0)
        XCTAssertNil(outcome.drift)
    }

    // MARK: - Drift

    func test_driftBecomesAnAnchorlessDiagnostic() {
        let result = """
            {"diagnostics":[],"intent_drift":"The intent still promises a \
            frame story the chapters have stopped using."}
            """
        guard let outcome = parse(result) else { return XCTFail("expected an outcome") }

        guard let drift = outcome.drift else { return XCTFail("expected a drift diagnostic") }
        XCTAssertNil(drift.anchor)
        XCTAssertEqual(drift.category, DiagnosticIngest.driftCategory)
        XCTAssertEqual(drift.category, "intent")
        XCTAssertEqual(
            drift.body,
            "The intent still promises a frame story the chapters have stopped using.")
        XCTAssertEqual(drift.docId, docId)
        XCTAssertEqual(drift.runId, runId)
        XCTAssertTrue(
            outcome.accepted.isEmpty,
            "drift is reported on its own field, never doubled into accepted")
    }

    func test_absentOrEmptyDriftIsNoDiagnostic() {
        for result in [
            #"{"diagnostics":[],"intent_drift":null}"#,
            #"{"diagnostics":[]}"#,
            #"{"diagnostics":[],"intent_drift":"   "}"#,
        ] {
            guard let outcome = parse(result) else {
                return XCTFail("expected an outcome for \(result)")
            }
            XCTAssertNil(outcome.drift, "no drift for \(result)")
            XCTAssertTrue(outcome.accepted.isEmpty)
        }
    }

    // MARK: - Fenced, bare, and unusable

    func test_fencedAndBareJSONBothParse() {
        let payload = """
            {"diagnostics":[{"paragraph_id":"a1b2","category":null,\
            "body":"A note."}],"intent_drift":null}
            """
        let forms = [
            payload,
            "```json\n\(payload)\n```",
            "```\n\(payload)\n```",
            "Here's what I found.\n\n```json\n\(payload)\n```\n\nHope that helps.",
        ]

        for form in forms {
            guard let outcome = parse(form) else {
                return XCTFail("failed to parse: \(form)")
            }
            XCTAssertEqual(outcome.accepted.count, 1, "wrong count for: \(form)")
            XCTAssertEqual(outcome.accepted[0].body, "A note.")
        }
    }

    func test_unusableOutputIsNilNotCrash() {
        let unusable = [
            "",
            "   \n  ",
            "The prose is going well; I have no notes.",
            #"{"diagnostics":[{"paragraph_id":"a1b2","body":"truncated"#,
            "```json\n{\"diagnostics\": [\n```",
            #"["diagnostics"]"#,
            #"{"something_else":true}"#,
            "null",
        ]

        for text in unusable {
            XCTAssertNil(parse(text), "expected nil for: \(text)")
        }
    }

    // MARK: - Mid-run edits

    /// The writer edits a paragraph while the run is in flight. The note is
    /// still ingested, anchored to the text as it stands NOW — so it reads as
    /// live until the next edit. Uniform staleness; no special case.
    func test_midRunEditsDoNotDropNotes() {
        let editedText = "The first paragraph, rewritten while the run was in flight."
        let live = liveDoc([
            "a1b2": editedText,
            "c3d4": "The second paragraph, as it stands right now.",
        ])
        let result = """
            {"diagnostics":[{"paragraph_id":"a1b2","category":"clarity",\
            "body":"Written against the text the run was sent."}],\
            "intent_drift":null}
            """

        guard let outcome = parse(result, live: live) else {
            return XCTFail("a mid-run edit must not fail the run")
        }

        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.droppedDangling, 0)
        XCTAssertEqual(
            outcome.accepted[0].anchor?.anchorText, editedText,
            "the anchor is the text at INGEST, not the text the run was sent")

        // And that is exactly what a store read then calls live.
        let stillLive = outcome.accepted[0].anchor?.anchorText == live("a1b2")
        XCTAssertTrue(stillLive, "the note must read as live until the NEXT edit")
    }

    // MARK: - Identity

    func test_everyDiagnosticGetsItsOwnId() {
        let result = """
            {"diagnostics":[\
            {"paragraph_id":"a1b2","category":null,"body":"One."},\
            {"paragraph_id":"c3d4","category":null,"body":"Two."}],\
            "intent_drift":"Drifted."}
            """
        guard let outcome = parse(result) else { return XCTFail("expected an outcome") }

        var ids = outcome.accepted.map { $0.id }
        ids.append(outcome.drift?.id ?? "")
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertFalse(ids.contains(""))
    }
}
