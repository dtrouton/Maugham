import XCTest
@testable import Maugham

/// Regression: earlier builds emitted junk bootstrap ops with
/// `sequence: []` and `changes: []` when a doc was opened against a
/// momentarily-empty `.md` (newly-created doc before first autosave;
/// transient autosave race). The deriver naively folded these,
/// clobbering the accumulated sequence to `[]`. Display collapsed,
/// load-time recovery had to dig the doc back out from parsed .md.
///
/// Two fixes:
/// - `Bootstrap.run` no longer emits an op when `parsed.isEmpty`.
/// - `Document.load`'s `needsBootstrap` check excludes empty `parsed`.
/// - **And** as defensive healing for existing op logs in the wild
///   that already carry the junk op, `Deriver.derive` ignores
///   `bootstrap` ops whose `sequence` is empty. This test pins that
///   defensive layer — even if the emission paths regress, the
///   deriver heals the resulting log.
final class DeriverEmptyBootstrapHealingTests: XCTestCase {

    func test_emptyBootstrapDoesNotClobberSequence() {
        // Sequence is accumulated by a typing_burst with 3 paragraphs.
        // Then an empty bootstrap op fires (the bug). The deriver must
        // ignore the empty-bootstrap sequence and preserve the prior
        // sequence + paragraphs.
        let typing = Op(
            opId: "01-burst",
            docId: "doc-test",
            at: Date(),
            device: "d",
            session: "s",
            kind: .typingBurst,
            changes: [
                .init(paragraphId: "abcd", prior: nil, next: "first"),
                .init(paragraphId: "efgh", prior: nil, next: "second"),
                .init(paragraphId: "jkmn", prior: nil, next: "third"),
            ],
            sequence: ["abcd", "efgh", "jkmn"])
        let junkBootstrap = Op(
            opId: "02-junk-bootstrap",
            docId: "doc-test",
            at: Date(),
            device: "d",
            session: "s",
            kind: .bootstrap,
            changes: [],
            sequence: [])

        let derived = Deriver.derive(ops: [typing, junkBootstrap])
        XCTAssertEqual(derived.sequence, ["abcd", "efgh", "jkmn"],
            "junk empty-bootstrap must not clobber the typing burst's sequence")
        XCTAssertEqual(derived.paragraphs.count, 3)
    }

    func test_legitimateBootstrapStillFolds() {
        // Counter-case: a real bootstrap with non-empty changes + sequence
        // should still be applied. The defensive filter ONLY skips ops where
        // sequence.isEmpty.
        let realBootstrap = Op(
            opId: "01-real-bootstrap",
            docId: "doc-test",
            at: Date(),
            device: "d",
            session: "s",
            kind: .bootstrap,
            changes: [
                .init(paragraphId: "abcd", prior: nil, next: "para A"),
                .init(paragraphId: "efgh", prior: nil, next: "para B"),
            ],
            sequence: ["abcd", "efgh"])
        let derived = Deriver.derive(ops: [realBootstrap])
        XCTAssertEqual(derived.sequence, ["abcd", "efgh"])
        XCTAssertEqual(derived.paragraphs["abcd"], "para A")
        XCTAssertEqual(derived.paragraphs["efgh"], "para B")
    }

    func test_emptyBootstrapBetweenTwoTypingBursts_preservesLatest() {
        // The actual smoke scenario: burst → junk → burst. Final sequence
        // must come from the SECOND burst, not be clobbered to [].
        let burst1 = Op(
            opId: "01", docId: "doc-x", at: Date(), device: "d", session: "s",
            kind: .typingBurst,
            changes: [.init(paragraphId: "abcd", prior: nil, next: "v1")],
            sequence: ["abcd"])
        let junk = Op(
            opId: "02", docId: "doc-x", at: Date(), device: "d", session: "s",
            kind: .bootstrap, changes: [], sequence: [])
        let burst2 = Op(
            opId: "03", docId: "doc-x", at: Date(), device: "d", session: "s",
            kind: .typingBurst,
            changes: [
                .init(paragraphId: "abcd", prior: "v1", next: "v2"),
                .init(paragraphId: "efgh", prior: nil, next: "new"),
            ],
            sequence: ["abcd", "efgh"])

        let derived = Deriver.derive(ops: [burst1, junk, burst2])
        XCTAssertEqual(derived.sequence, ["abcd", "efgh"])
        XCTAssertEqual(derived.paragraphs["abcd"], "v2")
        XCTAssertEqual(derived.paragraphs["efgh"], "new")
    }
}
