import XCTest
@testable import MaughamCore

/// A directive is a ruling anchored to a paragraph; a glossary entry is a
/// ruling of a recognised shape (translation pipeline spec §3, §3.1). Both are
/// COMPUTED over `Ruling.text`, so the stratum's parser, renderer and
/// round-trip are untouched — a bare hand-written line still parses as it did.
final class RulingShapesTests: XCTestCase {

    private func ruling(_ text: String) -> Ruling {
        Ruling(id: "x", text: text, ruledOn: nil, provenance: nil)
    }

    // MARK: - Directive

    func test_aDirectiveLineParsesItsAnchorAndItsInstruction() {
        let r = ruling("¶k7mq: keep the three \"and\"s")
        XCTAssertEqual(r.directive?.paragraphId, "k7mq")
        XCTAssertEqual(r.directive?.text, "keep the three \"and\"s")
        XCTAssertEqual(r.paragraphId, "k7mq")
    }

    func test_aBareRulingHasNoDirective() {
        XCTAssertNil(ruling("Kelly never lies").directive)
        XCTAssertNil(ruling("Kelly never lies").paragraphId)
    }

    func test_anAnchorOutsideTheIdAlphabetIsNotADirective() {
        XCTAssertNil(ruling("¶iloU: nope").directive, "i l o u are outside ParagraphID's alphabet")
        XCTAssertNil(ruling("¶k7m: too short").directive)
        XCTAssertNil(ruling("¶k7mq:").directive, "an anchor with no instruction is not a directive")
    }

    func test_theDirectiveComposerRoundTripsThroughTheStratum() {
        let line = Ruling.directiveText(paragraphId: "k7mq", "one sentence, not two")
        let md = RulingsSection.appending(line, provenance: Ruling.Provenance.translatorsNote,
                                          on: Date(timeIntervalSince1970: 0), to: "Essay.")
        let parsed = RulingsSection.parse(md).rulings
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].directive?.paragraphId, "k7mq")
        XCTAssertEqual(parsed[0].directive?.text, "one sentence, not two")
        XCTAssertEqual(parsed[0].provenance, "translator's note")
    }

    func test_theDirectiveComposerNeverEmitsAnEmDash() {
        let line = Ruling.directiveText(paragraphId: "k7mq", "plain — not elevated")
        XCTAssertFalse(line.contains("—"), "the stratum splits on the rightmost em-dash")
        let md = RulingsSection.appending(line, provenance: Ruling.Provenance.translatorsNote,
                                          on: Date(timeIntervalSince1970: 0), to: "")
        XCTAssertEqual(RulingsSection.parse(md).rulings.first?.directive?.text, "plain - not elevated")
    }

    // MARK: - Glossary

    func test_aGlossaryLineParsesTermRenderingAndNote() {
        let r = ruling("«October» → «Octubre» (the month, never a name)")
        XCTAssertEqual(r.glossary?.term, "October")
        XCTAssertEqual(r.glossary?.rendering, "Octubre")
        XCTAssertEqual(r.glossary?.note, "the month, never a name")
    }

    func test_aGlossaryLineWithoutANoteParses() {
        let r = ruling("«Kelly» → «Kelly»")
        XCTAssertEqual(r.glossary?.term, "Kelly")
        XCTAssertEqual(r.glossary?.rendering, "Kelly")
        XCTAssertNil(r.glossary?.note)
    }

    func test_aBareRulingIsNotAGlossaryEntry() {
        XCTAssertNil(ruling("Render every month name in Spanish").glossary)
        XCTAssertNil(ruling("«unclosed → «x»").glossary)
    }

    func test_theGlossaryComposerRoundTripsThroughTheStratum() {
        let line = Ruling.glossaryText(term: "October", rendering: "Octubre", note: "the month — never a name")
        XCTAssertFalse(line.contains("—"))
        let md = RulingsSection.appending(line, provenance: Ruling.Provenance.glossary,
                                          on: Date(timeIntervalSince1970: 0), to: "Essay.")
        let parsed = RulingsSection.parse(md).rulings
        XCTAssertEqual(parsed.first?.glossary?.term, "October")
        XCTAssertEqual(parsed.first?.glossary?.rendering, "Octubre")
        XCTAssertEqual(parsed.first?.glossary?.note, "the month - never a name")
        XCTAssertEqual(parsed.first?.provenance, "glossary")
    }

    func test_aDirectiveIsNotAGlossaryEntryAndViceVersa() {
        XCTAssertNil(ruling("¶k7mq: keep it").glossary)
        XCTAssertNil(ruling("«a» → «b»").directive)
    }
}
