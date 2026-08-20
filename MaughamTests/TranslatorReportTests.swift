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

    // MARK: - Wire names in one place

    func test_wireFieldNamesAppearInTheSchemaDescription() {
        let schema = TranslatorReport.schemaDescription
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.entries))
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.queries))
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.paragraphId))
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.text))
        XCTAssertTrue(schema.contains(TranslatorReport.WireField.verbatim))
    }
}
