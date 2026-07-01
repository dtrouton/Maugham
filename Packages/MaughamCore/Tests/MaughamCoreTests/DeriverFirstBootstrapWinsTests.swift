import XCTest
@testable import MaughamCore

/// F3 — first-bootstrap-wins in the Deriver.
///
/// Post-migration `.md` files are clean, so "op log is empty" is the sole
/// bootstrap signal. iCloud delivering the `.md` before `.maugham/ops/` makes
/// device B re-mint every ¶id; when the real log finally merges in, a naive
/// fold would apply the re-mint bootstrap on top of the real history — its
/// fresh ids replacing the originals, mass-orphaning paragraph-anchored
/// annotations. The Deriver now honors only the FIRST `.bootstrap` op (ULID
/// order); a later one's SEQUENCE is skipped (it must not win ordering) but its
/// CHANGES are kept (Minor 4), so the original sequence still orders the doc and
/// a subsequent burst referencing re-minted ids renders full content instead of
/// a near-empty doc. With no post-re-mint edit the kept re-mint texts are orphan
/// paragraphs (ids not in the surviving sequence) that `Document.reconcile`
/// drops — asserted here at the pure-Deriver level via sequence-inertness.
final class DeriverFirstBootstrapWinsTests: XCTestCase {

    private func op(
        _ opId: String, _ kind: OpKind,
        changes: [Op.ParagraphChange], sequence: [String]?
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(), device: "m", session: "s",
           kind: kind, changes: changes, sequence: sequence)
    }

    // MARK: - (a) re-mint after a real history is inert

    func test_reMintBootstrapAfterHistory_isInert_derive() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
            .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
        ], sequence: ["aaaa", "bbbb"])
        // Real drafting history on top of the original ids.
        let typing = op("02BBBB", .typingBurst, changes: [
            .init(paragraphId: "aaaa", prior: "Alpha.", next: "Alpha edited."),
            .init(paragraphId: "cccc", prior: nil, next: "Charlie."),
        ], sequence: ["aaaa", "bbbb", "cccc"])
        // Device B's partial-sync re-mint: same content, FRESH ids, later opId.
        let reMint = op("03CCCC", .bootstrap, changes: [
            .init(paragraphId: "wwww", prior: nil, next: "Alpha edited."),
            .init(paragraphId: "xxxx", prior: nil, next: "Bravo."),
            .init(paragraphId: "yyyy", prior: nil, next: "Charlie."),
        ], sequence: ["wwww", "xxxx", "yyyy"])

        let before = Deriver.derive(ops: [bootstrap, typing])
        let after = Deriver.derive(ops: [bootstrap, typing, reMint])

        // The re-mint's SEQUENCE is inert: the original ids still order the doc
        // and their texts are unchanged. Its CHANGES linger as orphan paragraphs
        // (Minor 4) — not in `sequence` — which `Document.reconcile` drops.
        XCTAssertEqual(after.sequence, before.sequence,
            "a re-mint bootstrap must not change the ordering")
        XCTAssertEqual(after.sequence, ["aaaa", "bbbb", "cccc"])
        XCTAssertEqual(after.paragraphs["aaaa"], "Alpha edited.")
        XCTAssertEqual(after.paragraphs["bbbb"], "Bravo.")
        XCTAssertEqual(after.paragraphs["cccc"], "Charlie.")
        // The re-minted ids are present as orphans (kept text) but absent from
        // the surviving sequence, so they never render.
        XCTAssertFalse(after.sequence.contains("wwww"))
        XCTAssertFalse(after.sequence.contains("yyyy"))
    }

    // MARK: - (b) single bootstrap is unchanged

    func test_singleBootstrap_unchanged_derive() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
            .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
        ], sequence: ["aaaa", "bbbb"])
        let derived = Deriver.derive(ops: [bootstrap])
        XCTAssertEqual(derived.sequence, ["aaaa", "bbbb"])
        XCTAssertEqual(derived.paragraphs["aaaa"], "Alpha.")
        XCTAssertEqual(derived.paragraphs["bbbb"], "Bravo.")
    }

    // MARK: - (c) applies to deriveWithSequenceFallback too

    func test_reMintBootstrapAfterHistory_isInert_deriveWithSequenceFallback() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
            .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
        ], sequence: ["aaaa", "bbbb"])
        let typing = op("02BBBB", .typingBurst, changes: [
            .init(paragraphId: "cccc", prior: nil, next: "Charlie."),
        ], sequence: ["aaaa", "bbbb", "cccc"])
        let reMint = op("03CCCC", .bootstrap, changes: [
            .init(paragraphId: "wwww", prior: nil, next: "Alpha."),
            .init(paragraphId: "xxxx", prior: nil, next: "Bravo."),
            .init(paragraphId: "yyyy", prior: nil, next: "Charlie."),
        ], sequence: ["wwww", "xxxx", "yyyy"])

        let before = Deriver.deriveWithSequenceFallback(ops: [bootstrap, typing])
        let after = Deriver.deriveWithSequenceFallback(
            ops: [bootstrap, typing, reMint])

        XCTAssertEqual(after.sequence, before.sequence,
            "deriveWithSequenceFallback must also skip a re-mint bootstrap's ordering")
        XCTAssertEqual(after.sequence, ["aaaa", "bbbb", "cccc"])
        XCTAssertFalse(after.sequence.contains("wwww"))
    }

    // MARK: - (d) Minor 4: post-re-mint sequence-bearing burst preserves content

    /// The worst case Minor 4 fixes: a re-mint is followed by a real edit made on
    /// top of it (a burst carrying an explicit sequence of the RE-MINTED ids).
    /// Dropping the re-mint's changes (the old behavior) left that sequence
    /// pointing at ids with no text → a near-empty doc. Keeping the changes means
    /// the content survives under the new ids (degrades to an annotation archive,
    /// not data loss).
    func test_postReMintSequenceBearingBurst_preservesFullContent_derive() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
            .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
        ], sequence: ["aaaa", "bbbb"])
        // Device B re-mints (clean .md arrived before ops/): fresh ids, later opId.
        let reMint = op("02BBBB", .bootstrap, changes: [
            .init(paragraphId: "wwww", prior: nil, next: "Alpha."),
            .init(paragraphId: "xxxx", prior: nil, next: "Bravo."),
        ], sequence: ["wwww", "xxxx"])
        // A real edit made on top of the re-mint BEFORE the merge — references the
        // re-minted ids and carries their sequence.
        let postEdit = op("03CCCC", .typingBurst, changes: [
            .init(paragraphId: "wwww", prior: "Alpha.", next: "Alpha, revised on B."),
        ], sequence: ["wwww", "xxxx"])

        let derived = Deriver.derive(ops: [bootstrap, reMint, postEdit])

        // The re-mint's sequence lost to the original bootstrap, but the post-edit
        // burst's explicit sequence wins (newest opId) — and because the re-mint's
        // changes were KEPT, every id in that sequence has text. Full content,
        // NOT a near-empty doc.
        XCTAssertEqual(derived.sequence, ["wwww", "xxxx"])
        XCTAssertEqual(derived.paragraphs["wwww"], "Alpha, revised on B.")
        XCTAssertEqual(derived.paragraphs["xxxx"], "Bravo.")
        let materialized = Materializer.materialize(
            paragraphs: derived.paragraphs, sequence: derived.sequence)
        XCTAssertTrue(materialized.contains("Alpha, revised on B."))
        XCTAssertTrue(materialized.contains("Bravo."))
        XCTAssertFalse(materialized.isEmpty)
    }

    func test_singleBootstrap_unchanged_deriveWithSequenceFallback() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
        ], sequence: ["aaaa"])
        let derived = Deriver.deriveWithSequenceFallback(ops: [bootstrap])
        XCTAssertEqual(derived.sequence, ["aaaa"])
        XCTAssertEqual(derived.paragraphs["aaaa"], "Alpha.")
    }

    // MARK: - order-independence: re-mint stays inert regardless of input order

    func test_reMint_inert_regardlessOfInputOrder() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
        ], sequence: ["aaaa"])
        let typing = op("02BBBB", .typingBurst, changes: [
            .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
        ], sequence: ["aaaa", "bbbb"])
        let reMint = op("03CCCC", .bootstrap, changes: [
            .init(paragraphId: "wwww", prior: nil, next: "Alpha."),
            .init(paragraphId: "xxxx", prior: nil, next: "Bravo."),
        ], sequence: ["wwww", "xxxx"])

        // Deriver sorts by opId internally, so a shuffled input still folds the
        // re-mint (highest opId) last and skips its ordering.
        let shuffled = Deriver.derive(ops: [reMint, typing, bootstrap])
        XCTAssertEqual(shuffled.sequence, ["aaaa", "bbbb"])
        // Re-mint ids stay out of the surviving sequence regardless of input order
        // (they linger as orphan text that reconcile drops).
        XCTAssertFalse(shuffled.sequence.contains("wwww"))
        XCTAssertFalse(shuffled.sequence.contains("xxxx"))
    }
}
