import XCTest
@testable import Maugham
import MaughamCore

/// Pins the four load-time recovery branches lifted out of `Document.load`
/// into the pure `Document.reconcile(derived:parsed:)` function. These cross
/// the .md ↔ op-log boundary, so ids use the 4-char restricted alphabet
/// (`0123456789abcdefghjkmnpqrstvwxyz`, no i/l/o/u).
final class DocumentReconcileTests: XCTestCase {

    private func parsed(_ pairs: [(String?, String)]) -> [ParsedParagraph] {
        pairs.map { ParsedParagraph(id: $0.0, text: $0.1) }
    }

    // Branch 1: empty derived state + tagged on-disk file → seed from parsed.
    func test_branch1_emptyDerived_seedsFromParsedIds() {
        let derived = Deriver.DerivedState(paragraphs: [:], sequence: [])
        let out = Document.reconcile(
            derived: derived, parsed: parsed([("aaaa", "Hello"), ("bbbb", "World")]))
        XCTAssertEqual(out.sequence, ["aaaa", "bbbb"])
        XCTAssertEqual(out.paragraphs["aaaa"], "Hello")
        XCTAssertEqual(out.paragraphs["bbbb"], "World")
    }

    // Branch 2: non-empty paragraphs but empty sequence → rebuild from parsed.
    func test_branch2_emptySequence_rebuildsFromParsed() {
        let derived = Deriver.DerivedState(
            paragraphs: ["aaaa": "stale"], sequence: [])
        let out = Document.reconcile(
            derived: derived, parsed: parsed([("aaaa", "fresh"), ("bbbb", "added")]))
        XCTAssertEqual(out.sequence, ["aaaa", "bbbb"])
        XCTAssertEqual(out.paragraphs["aaaa"], "fresh")
        XCTAssertEqual(out.paragraphs["bbbb"], "added")
    }

    // Branch 2 fallback: empty sequence + parsed has no anchored ids →
    // fall back to op-log paragraphs with their keys as the sequence.
    func test_branch2_emptySequence_noParsedIds_fallsBackToOpLog() {
        let derived = Deriver.DerivedState(
            paragraphs: ["aaaa": "kept"], sequence: [])
        let out = Document.reconcile(
            derived: derived, parsed: parsed([(nil, "unanchored")]))
        XCTAssertEqual(out.paragraphs["aaaa"], "kept")
        XCTAssertEqual(out.sequence, ["aaaa"])
    }

    // Branch 3: parsed has ids not in sequence → trust parsed ordering,
    // prefer op-log text per id where known.
    func test_branch3_parsedHasNewIds_trustsParsedOrdering() {
        let derived = Deriver.DerivedState(
            paragraphs: ["aaaa": "old"], sequence: ["aaaa"])
        let out = Document.reconcile(
            derived: derived,
            parsed: parsed([("aaaa", "old"), ("cccc", "new para")]))
        XCTAssertEqual(out.sequence, ["aaaa", "cccc"])
        XCTAssertEqual(out.paragraphs["aaaa"], "old")
        XCTAssertEqual(out.paragraphs["cccc"], "new para")
    }

    // Branch 4: paragraphs carry an orphan id not in sequence → drop it.
    func test_branch4_dropsOrphansNotInSequence() {
        let derived = Deriver.DerivedState(
            paragraphs: ["aaaa": "Hello", "zzzz": "orphan"], sequence: ["aaaa"])
        let out = Document.reconcile(
            derived: derived, parsed: parsed([("aaaa", "Hello")]))
        XCTAssertNil(out.paragraphs["zzzz"])
        XCTAssertEqual(Set(out.paragraphs.keys), Set(out.sequence))
    }
}
