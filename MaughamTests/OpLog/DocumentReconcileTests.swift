import XCTest
@testable import Maugham
import MaughamCore

/// Pins the op-log-only orphan-drop that `Document.reconcile(derived:)` applies
/// after load derives state. Crosses the .md ↔ op-log boundary, so ids use the
/// 4-char restricted alphabet (`0123456789abcdefghjkmnpqrstvwxyz`, no i/l/o/u).
///
/// (Pre-ADR-0019 `reconcile` also carried three `.md`-anchor recovery branches
/// that rebuilt content/order from the parsed on-disk file. ADR 0019 made the
/// op log authoritative and F2's Bootstrap fix seeds the empty-log case, so
/// those branches were removed; only the orphan-drop remains.)
final class DocumentReconcileTests: XCTestCase {

    // Orphan drop: paragraphs carry an id not in sequence → drop it, so the
    // inline-task deriver doesn't surface a phantom row for it.
    func test_dropsOrphansNotInSequence() {
        let derived = Deriver.DerivedState(
            paragraphs: ["aaaa": "Hello", "zzzz": "orphan"], sequence: ["aaaa"])
        let out = Document.reconcile(derived: derived)
        XCTAssertNil(out.paragraphs["zzzz"])
        XCTAssertEqual(Set(out.paragraphs.keys), Set(out.sequence))
        XCTAssertEqual(out.sequence, ["aaaa"])
        XCTAssertEqual(out.paragraphs["aaaa"], "Hello")
    }

    // No orphans: sequence and paragraphs already agree → state passes through
    // unchanged.
    func test_noOrphans_passesThrough() {
        let derived = Deriver.DerivedState(
            paragraphs: ["aaaa": "Hello", "bbbb": "World"],
            sequence: ["aaaa", "bbbb"])
        let out = Document.reconcile(derived: derived)
        XCTAssertEqual(out.sequence, ["aaaa", "bbbb"])
        XCTAssertEqual(out.paragraphs, ["aaaa": "Hello", "bbbb": "World"])
    }

    // Empty sequence: the orphan-drop is gated on a non-empty sequence, so an
    // empty-sequence derived state passes through untouched.
    func test_emptySequence_passesThrough() {
        let derived = Deriver.DerivedState(paragraphs: [:], sequence: [])
        let out = Document.reconcile(derived: derived)
        XCTAssertTrue(out.paragraphs.isEmpty)
        XCTAssertTrue(out.sequence.isEmpty)
    }
}
