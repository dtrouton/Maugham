import XCTest
@testable import Maugham

final class TranslatorReportTests: XCTestCase {

    // MARK: - Round-trip

    func test_roundTrip_textEntryVerbatimEntryAndQueries() throws {
        let raw = """
            {"entries":[\
            {"paragraph_id":"a1b2","text":"Le premier paragraphe."},\
            {"paragraph_id":"c3d4","verbatim":true}],\
            "queries":[\
            {"paragraph_id":"a1b2","text":"Is this a proper name?"},\
            {"text":"Should the title stay untranslated?"}]}
            """

        let report = try XCTUnwrap(TranslatorReport.parse(raw))

        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.entries[0].paragraphId, "a1b2")
        XCTAssertEqual(report.entries[0].text, "Le premier paragraphe.")
        XCTAssertNil(report.entries[0].verbatim)
        XCTAssertEqual(report.entries[1].paragraphId, "c3d4")
        XCTAssertNil(report.entries[1].text)
        XCTAssertEqual(report.entries[1].verbatim, true)

        XCTAssertEqual(report.queries.count, 2)
        XCTAssertEqual(report.queries[0].paragraphId, "a1b2")
        XCTAssertEqual(report.queries[0].text, "Is this a proper name?")
        XCTAssertNil(report.queries[1].paragraphId)
        XCTAssertEqual(report.queries[1].text, "Should the title stay untranslated?")
    }

    func test_roundTrip_explicitNullParagraphIdOnQueryIsDocumentLevel() throws {
        let raw = """
            {"entries":[],"queries":[{"paragraph_id":null,"text":"Whole-piece question?"}]}
            """

        let report = try XCTUnwrap(TranslatorReport.parse(raw))

        XCTAssertEqual(report.queries.count, 1)
        XCTAssertNil(report.queries[0].paragraphId)
    }

    // MARK: - Prose-wrapped fence

    func test_proseWrappedFence_takesTheLastCompleteBlock() throws {
        let raw = """
            Let me think this through. For example I might write something \
            like {"entries":[],"queries":[]} but that's not my real answer.

            ```json
            {"entries":[{"paragraph_id":"a1b2","text":"El primer párrafo."}],\
            "queries":[]}
            ```

            That's my answer for this round.
            """

        let report = try XCTUnwrap(TranslatorReport.parse(raw))

        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].paragraphId, "a1b2")
        XCTAssertEqual(report.entries[0].text, "El primer párrafo.")
        XCTAssertTrue(report.queries.isEmpty)
    }

    func test_proseWrappedFence_narratedLineStillParses() throws {
        let raw = """
            Here is this round's report: \
            {"entries":[{"paragraph_id":"c3d4","verbatim":true}],"queries":[]} \
            — let me know if you need anything else.
            """

        let report = try XCTUnwrap(TranslatorReport.parse(raw))

        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].paragraphId, "c3d4")
        XCTAssertEqual(report.entries[0].verbatim, true)
    }

    // MARK: - Both/neither refusal

    func test_entryWithBothFormsRefusesTheWholeReport() {
        let raw = """
            {"entries":[\
            {"paragraph_id":"a1b2","text":"Good."},\
            {"paragraph_id":"c3d4","text":"Also good.","verbatim":true}],\
            "queries":[]}
            """

        XCTAssertNil(TranslatorReport.parse(raw))
    }

    func test_entryWithNeitherFormRefusesTheWholeReport() {
        let raw = """
            {"entries":[\
            {"paragraph_id":"a1b2","text":"Good."},\
            {"paragraph_id":"c3d4"}],\
            "queries":[]}
            """

        XCTAssertNil(TranslatorReport.parse(raw))
    }

    func test_entryWithVerbatimFalseAndNoTextRefusesTheWholeReport() {
        // `verbatim: false` is not a form — an entry claiming it and
        // nothing else has still supplied neither of the two real forms.
        let raw = """
            {"entries":[{"paragraph_id":"a1b2","verbatim":false}],"queries":[]}
            """

        XCTAssertNil(TranslatorReport.parse(raw))
    }

    // MARK: - Empty is valid

    func test_emptyEntriesAndQueriesIsAValidReport() throws {
        let raw = #"{"entries":[],"queries":[]}"#

        let report = try XCTUnwrap(TranslatorReport.parse(raw))

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertTrue(report.queries.isEmpty)
    }

    func test_missingKeysReadAsEmptyLists() throws {
        // A model that omits an empty array has still answered "nothing
        // here" — `queries` absent entirely reads the same as `[]`.
        let raw = #"{"entries":[]}"#

        let report = try XCTUnwrap(TranslatorReport.parse(raw))

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertTrue(report.queries.isEmpty)
    }

    // MARK: - Malformed → nil

    func test_notJSON_returnsNil() {
        XCTAssertNil(TranslatorReport.parse("I don't have anything to report this round."))
    }

    func test_truncatedJSON_returnsNil() {
        let raw = #"{"entries":[{"paragraph_id":"a1b2","text":"Cut off mid"#
        XCTAssertNil(TranslatorReport.parse(raw))
    }

    func test_entryMissingParagraphId_returnsNil() {
        let raw = #"{"entries":[{"text":"No id given."}],"queries":[]}"#
        XCTAssertNil(TranslatorReport.parse(raw))
    }

    func test_entriesNotAnArray_returnsNil() {
        let raw = #"{"entries":"not a list","queries":[]}"#
        XCTAssertNil(TranslatorReport.parse(raw))
    }

    func test_queryMissingText_returnsNil() {
        let raw = #"{"entries":[],"queries":[{"paragraph_id":"a1b2"}]}"#
        XCTAssertNil(TranslatorReport.parse(raw))
    }

    func test_queryParagraphIdWrongType_returnsNil() {
        let raw = #"{"entries":[],"queries":[{"paragraph_id":42,"text":"Question?"}]}"#
        XCTAssertNil(TranslatorReport.parse(raw))
    }

    func test_noRecognizableObjectAtAll_returnsNil() {
        let raw = #"{"foo":"bar"}"#
        XCTAssertNil(TranslatorReport.parse(raw))
    }

    // MARK: - Empty text is not an answer

    /// **An empty translation is not a translation.** Taken at face value it
    /// would blank the paragraph in the published edition through a path that
    /// never touched the manuscript — and the record would carry the current
    /// source's hash, so it would read fresh and no later coverage derivation
    /// would ever raise it. It reads as no `text` at all, which puts the entry
    /// in front of the exactly-one-form rule and fails the whole report, the
    /// same all-or-nothing posture every other malformed entry gets.
    func test_anEntryWithEmptyTextMakesTheWholeReportUnusable() {
        let raw = """
            {"entries":[{"paragraph_id":"a1b2","text":"Llegó la niebla."},\
            {"paragraph_id":"c3d4","text":""}],"queries":[]}
            """
        XCTAssertNil(TranslatorReport.parse(raw),
                     "the good entry beside it is refused too — all-or-nothing")
    }

    func test_anEntryWithWhitespaceOnlyTextIsTheSameRefusal() {
        let raw = #"{"entries":[{"paragraph_id":"a1b2","text":"   \n  "}],"queries":[]}"#
        XCTAssertNil(TranslatorReport.parse(raw))
    }

    /// A question with no words in it is not a question.
    func test_aQueryWithEmptyTextMakesTheWholeReportUnusable() {
        let raw = """
            {"entries":[{"paragraph_id":"a1b2","verbatim":true}],\
            "queries":[{"paragraph_id":"a1b2","text":"  "}]}
            """
        XCTAssertNil(TranslatorReport.parse(raw))
    }

    /// The control: the same shapes with real text still parse, so the guard
    /// above is about emptiness and not about the fields themselves.
    func test_textThatHasWordsInItStillParses() throws {
        let raw = """
            {"entries":[{"paragraph_id":"a1b2","text":"Llegó la niebla."}],\
            "queries":[{"paragraph_id":"a1b2","text":"¿Formal?"}]}
            """
        let report = try XCTUnwrap(TranslatorReport.parse(raw))
        XCTAssertEqual(report.entries.first?.text, "Llegó la niebla.")
        XCTAssertEqual(report.queries.first?.text, "¿Formal?")
    }

    /// Text is stored trimmed — `nonEmptyString`'s own discipline, the same
    /// one the paragraph id has always had. Whitespace around an answer is an
    /// artifact of how the model wrote its JSON, not of the prose.
    func test_entryTextIsTrimmed() throws {
        let raw = #"{"entries":[{"paragraph_id":"a1b2","text":"  Llegó.  "}],"queries":[]}"#
        let report = try XCTUnwrap(TranslatorReport.parse(raw))
        XCTAssertEqual(report.entries.first?.text, "Llegó.")
    }

    // MARK: - Wire names in one place

    func test_wireFieldNamesAppearInTheSchemaDescription() {
        let schema = TranslatorReport.schemaDescription
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.entries))
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.queries))
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.paragraphId))
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.text))
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.verbatim))
    }

    /// The contract the parser enforces has to be the contract the model is
    /// shown: a refusal the schema never mentioned reads as a random failure.
    func test_theSchemaSaysTextMustNotBeEmpty() {
        let schema = TranslatorReport.schemaDescription
        XCTAssertTrue(schema.contains("never empty"), schema)
        XCTAssertTrue(schema.contains("must not be empty either"), schema)
    }

    // MARK: - Fix mode (translation pipeline P1)

    private let briefedNotes: Set<String> = ["n1", "n2", "n3"]

    func test_fixMode_roundTrip_addressedDeclinedSummaryAndGlossary() throws {
        let raw = """
            {"entries":[{"paragraph_id":"k7mq","text":"Nueva versión."}],
             "queries":[],
             "addressed":["n1","n2"],
             "declined":[{"note_id":"n3","reason":"The fragment is the author's."}],
             "summary":"Two repaired; one stands.",
             "glossary_proposals":[{"term":"October","rendering":"Octubre","reason":"the month"}]}
            """
        let report = try XCTUnwrap(TranslatorReport.parse(raw, mode: .fix(briefedNoteIds: briefedNotes)))
        XCTAssertEqual(report.addressed, ["n1", "n2"])
        XCTAssertEqual(report.declined, [.init(noteId: "n3", reason: "The fragment is the author's.")])
        XCTAssertEqual(report.summary, "Two repaired; one stands.")
        XCTAssertEqual(report.glossaryProposals, [.init(term: "October", rendering: "Octubre", reason: "the month")])
    }

    func test_fixMode_everyBriefedNoteMustAppearExactlyOnce() {
        let missing = #"{"entries":[],"addressed":["n1"],"declined":[{"note_id":"n2","reason":"r"}]}"#
        XCTAssertNil(TranslatorReport.parse(missing, mode: .fix(briefedNoteIds: briefedNotes)), "n3 unaccounted for — silence is refused")
        let twice = #"{"entries":[],"addressed":["n1","n2","n3"],"declined":[{"note_id":"n3","reason":"r"}]}"#
        XCTAssertNil(TranslatorReport.parse(twice, mode: .fix(briefedNoteIds: briefedNotes)))
        let duplicate = #"{"entries":[],"addressed":["n1","n1","n2","n3"]}"#
        XCTAssertNil(TranslatorReport.parse(duplicate, mode: .fix(briefedNoteIds: briefedNotes)))
        let unknown = #"{"entries":[],"addressed":["n1","n2","n3","n9"]}"#
        XCTAssertNil(TranslatorReport.parse(unknown, mode: .fix(briefedNoteIds: briefedNotes)), "an id from another pass fails the report")
    }

    func test_fixMode_withNoBriefedNotesAcceptsEmptyLists() throws {
        let raw = #"{"entries":[],"summary":"Nothing to fix."}"#
        let report = try XCTUnwrap(TranslatorReport.parse(raw, mode: .fix(briefedNoteIds: [])))
        XCTAssertEqual(report.summary, "Nothing to fix.")
        XCTAssertTrue(report.addressed.isEmpty)
    }

    func test_fixMode_aDeclineNeedsAReasonAndAProposalNeedsAllThreeFields() {
        let noReason = #"{"entries":[],"addressed":["n1","n2"],"declined":[{"note_id":"n3"}]}"#
        XCTAssertNil(TranslatorReport.parse(noReason, mode: .fix(briefedNoteIds: briefedNotes)))
        let badProposal = #"{"entries":[],"addressed":["n1","n2","n3"],"glossary_proposals":[{"term":"x","rendering":"y"}]}"#
        XCTAssertNil(TranslatorReport.parse(badProposal, mode: .fix(briefedNoteIds: briefedNotes)))
    }

    func test_translateMode_ignoresTheFixFieldsAndReadsThemEmpty() throws {
        let raw = #"{"entries":[],"queries":[],"addressed":["n1"],"summary":"x","glossary_proposals":[{"term":"a","rendering":"b","reason":"c"}]}"#
        let report = try XCTUnwrap(TranslatorReport.parse(raw))
        XCTAssertTrue(report.addressed.isEmpty)
        XCTAssertNil(report.summary)
        XCTAssertTrue(report.glossaryProposals.isEmpty)
    }

    /// The widened `shapedBy` list must not loosen what counts as a
    /// translate-mode report: an object with only fix fields is not one, the
    /// same refusal the pre-existing contract gave an object with neither
    /// `entries` nor `queries`. A fix leg reads the very same object fine —
    /// a round with nothing to translate can still carry just a summary.
    func test_translateMode_anObjectWithOnlyFixFieldsIsNotAReport() throws {
        let raw = #"{"summary":"x"}"#
        XCTAssertNil(TranslatorReport.parse(raw))
        let report = try XCTUnwrap(TranslatorReport.parse(raw, mode: .fix(briefedNoteIds: [])))
        XCTAssertEqual(report.summary, "x")
    }

    func test_fixSchemaDescriptionNamesEveryFixField() {
        for name in ["addressed", "declined", "note_id", "reason", "summary", "glossary_proposals", "term", "rendering"] {
            XCTAssertTrue(TranslatorReport.fixSchemaDescription.contains(name), name)
        }
        XCTAssertTrue(TranslatorReport.fixSchemaDescription.contains("exactly one of"))
        XCTAssertFalse(TranslatorReport.schemaDescription.contains("addressed"), "the translate contract is unchanged")
    }
}
