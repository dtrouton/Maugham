import XCTest
import MaughamCore
@testable import Maugham

/// Task 5 — E3(a): a peer op-log sync arriving mid-draft must NOT discard the
/// writer's un-bursted typing.
///
/// `Document.handleExternalLogChange` re-derives manuscript state purely from
/// the on-disk ops. Before this fix it never consulted the pending buffer, so a
/// peer op syncing in mid-burst (a second Mac, a phone Accept) silently threw
/// away up to a burst window of live keystrokes — and autosaved the wrong text
/// (recoverable only on reload).
///
/// The fix flushes the pending burst FIRST (the existing, tested `flushBurstNow`
/// path): the local edits become real ops and participate in the opId-ordered
/// merge like any peer's.
@MainActor
final class ExternalMergePendingTests: XCTestCase {

    func test_externalLogChange_foldsUnburstedTyping_whileMergingPeerOp() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "ExternalMergePending",
            initialMd: "Alpha original.\n\nBeta original.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        let pids = doc.sequence
        XCTAssertEqual(pids.count, 2, "fixture seeds two paragraphs")
        let p2 = pids[1]

        // Live typing: edit the FIRST paragraph in place. `setFullText` records
        // the change in the pending buffer and schedules a burst, but does NOT
        // append an op yet — the edit is un-bursted.
        doc.setFullText("Alpha EDITED.\n\nBeta original.\n")
        XCTAssertFalse(
            doc.pending.isEmpty(),
            "precondition: the local edit is un-bursted (still in the pending buffer)")

        // A peer (second Mac) edits the SECOND paragraph; its op syncs to disk
        // under a DIFFERENT device slug (mirrors the cross-device foreign-op
        // idiom — the write target is derived from `op.device`).
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "peer-mac", session: "peer-session",
            kind: .typingBurst,
            changes: [.init(paragraphId: p2,
                            prior: "Beta original.",
                            next: "Beta FROMPEER.")],
            sequence: nil, provenance: nil)
        try await OpLogStore(projectURL: dir).append(foreign)

        // The NSFilePresenter callback fires: a foreign op has landed on disk.
        try await doc.handleExternalLogChange()

        // BOTH survive the merge: the un-bursted local edit AND the peer's edit.
        XCTAssertTrue(
            doc.displayText.contains("Alpha EDITED."),
            "the un-bursted local edit must survive the merge (E3a)")
        XCTAssertTrue(
            doc.displayText.contains("Beta FROMPEER."),
            "the peer's op must be merged in")

        // Echo-guard reasoning (brief Step 2): the flush appended our local burst
        // to `_opLogMirror` BEFORE `opStore.load`, so the `newOps` filter (which
        // subtracts `_opLogMirror`'s opIds from the reloaded set) saw ONLY the
        // foreign op — our own just-flushed op is never re-processed as foreign
        // (which would risk a spurious sweep). Observable consequences:
        //   1. the pending buffer was cleared (the edit is now a real op), and
        //   2. both the local burst and the foreign op are in the merged mirror.
        XCTAssertTrue(
            doc.pending.isEmpty(),
            "flushBurstNow turned the pending edit into a real op and cleared pending")
        let mirrorHasLocalBurst = doc._opLogMirror.contains { op in
            op.device == "test" && op.kind == .typingBurst
                && op.changes.contains { $0.next == "Alpha EDITED." }
        }
        XCTAssertTrue(
            mirrorHasLocalBurst,
            "the local edit was flushed into the op log and merged into the mirror")
        let mirrorHasForeign = doc._opLogMirror.contains { $0.opId == foreign.opId }
        XCTAssertTrue(
            mirrorHasForeign, "the foreign op merged into the mirror")
    }

    /// Sibling of E3a: a pure `reorder()` sets `_orderingChangedSinceLoad` but
    /// records NOTHING in the pending buffer (the ordering-only burst carries
    /// its sequence as the payload). A guard that flushes only on
    /// `!pending.isEmpty()` would skip it, so a peer op syncing in mid-reorder
    /// would re-derive sequence from disk and discard the un-bursted reorder.
    func test_externalLogChange_foldsUnburstedReorder_whileMergingPeerOp() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "ExternalMergeReorder",
            initialMd: "One.\n\nTwo.\n\nThree.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        let pids = doc.sequence
        XCTAssertEqual(pids.count, 3, "fixture seeds three paragraphs")
        let p1 = pids[0], p2 = pids[1], p3 = pids[2]

        // Live ordering-only edit: move the third paragraph to the front. Pure
        // reorder — no `pending.recordChange`, so the buffer stays empty.
        doc.reorder(sequence: [p3, p1, p2])
        XCTAssertTrue(
            doc.pending.isEmpty(),
            "precondition: a pure reorder records nothing in the pending buffer")

        // A peer edits the middle paragraph; its op syncs to disk under a
        // different device slug.
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "peer-mac", session: "peer-session",
            kind: .typingBurst,
            changes: [.init(paragraphId: p2,
                            prior: "Two.",
                            next: "Two FROMPEER.")],
            sequence: nil, provenance: nil)
        try await OpLogStore(projectURL: dir).append(foreign)

        try await doc.handleExternalLogChange()

        // BOTH survive: the un-bursted reorder AND the peer's edit.
        XCTAssertEqual(
            doc.sequence, [p3, p1, p2],
            "the un-bursted reorder must survive the merge (E3a sibling)")
        XCTAssertTrue(
            doc.displayText.contains("Two FROMPEER."),
            "the peer's op must be merged in")

        // The reorder became a real ordering-only burst (empty changes, explicit
        // sequence) and cleared the ordering-changed flag.
        let mirrorHasReorderBurst = doc._opLogMirror.contains { op in
            op.device == "test" && op.kind == .typingBurst
                && op.changes.isEmpty && op.sequence == [p3, p1, p2]
        }
        XCTAssertTrue(
            mirrorHasReorderBurst,
            "the reorder was flushed as an ordering-only burst into the merged mirror")
    }

    /// E3(c): the live-merge path must derive+reconcile exactly like
    /// `Document.load`. Before the fix, `handleExternalLogChange` used a bare
    /// `Deriver.derive(ops:)` and skipped `Document.reconcile`, so an orphan
    /// paragraph (an id the merged `sequence` no longer references but the
    /// deriver's accumulator still carries) survived a live merge. The
    /// inline-task deriver walks every `paragraphs` entry, not just `sequence`,
    /// so the orphan surfaced a PHANTOM task row that only disappeared on
    /// reopen (where load's orphan-drop runs).
    ///
    /// Deterministic construction (no ULID race): the writer makes a live text
    /// edit, so `pending` is genuinely dirty and the merge's flush-first step
    /// (Task 5) is guaranteed to fire, appending an ordering burst generated
    /// LAST — the newest sequence-bearing op. Its sequence is `[p1]` (the local
    /// order). A peer then syncs in a brand-new paragraph `p2`. Because the
    /// local flush's `[p1]` wins the merged order (newest), the peer's `p2`
    /// lands in the deriver's `paragraphs` accumulator but NOT in `sequence` —
    /// an orphan. `Document.load` would trim it (`reconcile`); the live-merge
    /// path did not, so the orphan surfaced a phantom task row until reopen.
    func test_externalLogChange_dropsOrphanParagraph_matchingLoad() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "ExternalMergeOrphan",
            initialMd: "- [ ] item A\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        XCTAssertEqual(doc.sequence.count, 1, "fixture seeds one paragraph")
        let p1 = doc.sequence[0]

        // Live text edit: a genuine pending change so the merge's flush-first
        // step fires deterministically and re-asserts the local sequence `[p1]`.
        doc.setFullText("- [ ] item A local\n")
        XCTAssertFalse(doc.pending.isEmpty(),
            "precondition: the local edit is un-bursted (pending is dirty)")
        XCTAssertEqual(doc.sequence, [p1], "the edit stays within the one paragraph")

        // A peer (second Mac) ADDS a new paragraph and syncs its op to disk
        // under a different device slug. Its `sequence` includes the new
        // paragraph, but the local flush (generated later, at merge time) is the
        // newest sequence-bearing op, so `[p1]` wins — the peer's `p2` becomes
        // an orphan (present in `paragraphs`, absent from the merged `sequence`).
        let p2 = ParagraphID.mint()
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "peer-mac", session: "peer-session",
            kind: .typingBurst,
            changes: [.init(paragraphId: p2,
                            prior: nil,
                            next: "- [ ] item B")],
            sequence: [p1, p2], provenance: nil)
        try await OpLogStore(projectURL: dir).append(foreign)

        try await doc.handleExternalLogChange()

        // The local ordering flush wins: sequence is just p1.
        XCTAssertEqual(doc.sequence, [p1],
            "the local flush is the newest sequence-bearing op")
        // Orphan trim: the peer's `p2` was accumulated into `paragraphs` but is
        // absent from `sequence` — it must be dropped, exactly as
        // `Document.load`'s reconcile does. Today it survives (no reconcile).
        XCTAssertFalse(
            doc.paragraphs.keys.contains(p2),
            "the orphan peer paragraph must be trimmed from `paragraphs` on a live merge (E3c) — today it survives because the merge skips reconcile")
        // Observable symptom: the inline-task deriver walks `paragraphs`, so an
        // un-trimmed orphan surfaces a phantom second task ("item B").
        let inlineTasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
            .filter { $0.kind == .inlineMarkdown }
        XCTAssertEqual(inlineTasks.count, 1,
            "exactly one inline task after the merge; a phantom 2nd ('item B') indicates the orphan paragraph survived (no reconcile)")
        XCTAssertFalse(inlineTasks.contains { $0.body == "item B" },
            "the orphan paragraph's inline task must not surface")
    }

    /// E3(c), fallback HALF — the Tank Park mass-archive regression (23a3ac6),
    /// now guarded through the MERGE door. `Document.load` uses
    /// `deriveWithSequenceFallback`, which SYNTHESIZES a sequence from
    /// first-appearance order for a legacy sequence-less log. The live-merge
    /// path must do the same. A naive revert to the bare `Deriver.derive` in the
    /// merge (even keeping `reconcile`) re-derives an EMPTY sequence for such a
    /// log — which (a) wipes the synthesized order and (b) makes the sweep see
    /// every paragraph-anchored annotation as orphaned and mass-archive it
    /// (`synthesisSource: .paragraphDeleted`). That is exactly the cascade
    /// 23a3ac6 fixed. `DocumentLoadSequenceRecoveryTests` only covers the LOAD
    /// path, so without this a `fallback → derive` regression in the merge would
    /// pass the whole suite. Proven RED against a temporary
    /// `derive`-instead-of-`deriveWithSequenceFallback` revert (report Step 5).
    func test_externalLogChange_legacySequenceless_synthesizesSequence_noMassArchive() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "ExternalMergeLegacySeqless",
            initialMd: "Alpha.\n\nBeta.\n")

        // A LEGACY sequence-less log: a bootstrap op carrying both paragraphs'
        // text but NO `sequence` field (predates the always-capture-sequence
        // fix). 4-char alphabet ids (they cross the .md/op-log boundary).
        let p1 = "a3f9", p2 = "b21c"
        let legacyBootstrap = Op(
            opId: ULID.generate(),
            docId: "doc-test", at: Date(),
            device: "legacy", session: "legacy",
            kind: .bootstrap,
            changes: [.init(paragraphId: p1, prior: nil, next: "Alpha."),
                      .init(paragraphId: p2, prior: nil, next: "Beta.")],
            sequence: nil, provenance: nil)
        try await OpLogStore(projectURL: dir).append(legacyBootstrap)

        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        // Load synthesized the order from first-appearance (the fallback).
        XCTAssertEqual(doc.sequence, [p1, p2],
            "load's deriveWithSequenceFallback synthesizes order for a legacy log")

        // A paragraph-anchored annotation on p1. `addAnnotation` itself emits a
        // sequence-less op, so the whole local log stays legacy sequence-less.
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: p1, body: "note on Alpha")
        XCTAssertEqual(doc.annotations().count, 1, "one open annotation on p1")

        // A peer op syncs in (the foreign op that triggers the merge). It is
        // itself sequence-less (a legacy peer), so NO op in the merged log
        // carries an explicit sequence — the bare `derive` would return [].
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "peer-mac", session: "peer-session",
            kind: .typingBurst,
            changes: [.init(paragraphId: p1,
                            prior: "Alpha.", next: "Alpha (peer).")],
            sequence: nil, provenance: nil)
        try await OpLogStore(projectURL: dir).append(foreign)

        try await doc.handleExternalLogChange()

        // (a) The synthesized sequence survives the merge — NOT wiped to [].
        XCTAssertEqual(doc.sequence, [p1, p2],
            "the merge must re-synthesize the sequence (deriveWithSequenceFallback), not wipe it to [] like the bare derive")
        XCTAssertTrue(
            doc.paragraphs.keys.contains(p1) && doc.paragraphs.keys.contains(p2),
            "both paragraphs remain")
        // The peer's edit merged in.
        XCTAssertTrue(doc.displayText.contains("Alpha (peer)."),
            "the peer's op must be merged in")

        // (b) The paragraph-anchored annotation is NOT mass-archived.
        XCTAssertEqual(doc.annotations().count, 1,
            "the annotation on p1 must stay open — a wiped sequence would make the sweep archive it (Tank Park)")
        let massArchive = doc.opLogSnapshot.filter {
            $0.kind == .claudeArchive
                && $0.provenance?.synthesisSource == .paragraphDeleted
        }
        XCTAssertTrue(massArchive.isEmpty,
            "no claude_archive(paragraph_deleted) op may be synthesized by the merge — that is the Tank Park mass-archive cascade")
    }
}
