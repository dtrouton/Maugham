// MaughamTests/OpLog/CrossDeviceIntegrationTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// Adversarial cross-device merge/reconcile harness (plan task 0.3, Milestone 0).
///
/// These cases drive the **production** load / merge / derive / reconcile path —
/// `OpLogStore.load` glob+merge, `Deriver.derive`, the live external-edit seam
/// `Document.handleExternalDiskChange` (→ `Reconciler.classify`), and the
/// save-time id-reattach seam `RenderFilter.restoreComments` — with the
/// cross-device scenarios that have NO coverage today. They are NOT isolated
/// unit helpers; each goes through the same entry points the Mac app uses.
///
/// The active cases are EXPECTED TO FAIL against current code. That red is
/// intended: it defines "done" for Milestone 1/2. Do NOT modify production code
/// to make them pass here — this is a tests-only task.
///
/// Tripwire 8: cases 2 and 3 cross the `.md` ↔ op-log boundary
/// (Reconciler / RenderFilter), so every paragraph id uses the 4-char restricted
/// alphabet (regex `[0123456789abcdefghjkmnpqrstvwxyz]{4}`). Case 1 is pure
/// store/deriver (permissive) but stays alphabet-clean for consistency.
@MainActor
final class CrossDeviceIntegrationTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("XDEV-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Shared helpers

    /// Seed a specific op-log file directly via the production
    /// `JSONLAppendStore<Op>` (the same writer `OpLogStore.append` uses), so the
    /// on-disk shape is real, not a fabricated fixture.
    private func seed(_ url: URL, _ ops: [Op]) async throws {
        let store = JSONLAppendStore<Op>(
            fileURL: url, dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        for o in ops { try await store.append(o) }
    }

    private func opsDir() -> URL { tmp.appendingPathComponent(".maugham/ops") }

    // MARK: - Case 1 — divergent-content opId collision → deterministic survivor

    /// Drives: `OpLogStore.load(docId:)` (real glob of per-device
    /// `<docId>.<slug>.jsonl` files + `mergeSortedDedup`) → `Deriver.derive`.
    ///
    /// Contract: a same-opId collision whose two payloads DIFFER must resolve to
    /// the SAME derived state regardless of which per-device file the filesystem
    /// enumerates first (load-order independence). We do NOT pin which payload
    /// wins — the survivor rule is M2.1's unmade design decision; we assert only
    /// determinism (order-swap equality).
    ///
    /// RED until M1/M2 — `mergeSortedDedup` is first-wins over a non-stable
    /// `sorted` fed by `contentsOfDirectory` enumeration order, so the survivor
    /// of a divergent collision is silently load-order-dependent. See plan
    /// 0.3 + finding 0.4.
    func test_case1_divergentOpIdCollision_loadIsOrderIndependent() async throws {
        // doc ids contain no dot (delimiter between id and device slug); use a
        // realistic ADR-0008 shape.
        let docId = "doc-c1adversarial"

        // The SAME opId "01HZK02" appears in two different per-device files with
        // DIFFERENT `next` text — a genuine divergent-content opId collision
        // (replay / hand-recovery / astronomically-unlikely ULID clash).
        func op(_ opId: String, device: String, next: String) -> Op {
            Op(opId: opId, docId: docId,
               at: Date(timeIntervalSince1970: 0), device: device,
               session: "s", kind: .typingBurst,
               changes: [.init(paragraphId: "aaaa", prior: nil, next: next)],
               sequence: ["aaaa"])
        }
        let opB0 = op("01HZK01", device: "mac-B", next: "B-0")
        let collisionFromA = op("01HZK02", device: "mac-A", next: "A-1")
        let collisionFromB = op("01HZK02", device: "mac-B", next: "B-1-divergent")

        let slugA = DeviceSlug.make(from: "mac-A")
        let slugB = DeviceSlug.make(from: "mac-B")
        let fileA = opsDir().appendingPathComponent("\(docId).\(slugA).jsonl")
        let fileB = opsDir().appendingPathComponent("\(docId).\(slugB).jsonl")

        // --- Physical layout 1: device A's file written first. ---
        try await seed(fileA, [collisionFromA])
        try await seed(fileB, [opB0, collisionFromB])
        let store = OpLogStore(projectURL: tmp)
        let loaded1 = try await store.load(docId: docId)
        let derived1 = Deriver.derive(ops: loaded1)

        // --- Physical layout 2: SAME logical ops, files re-created in the
        // opposite write order. `contentsOfDirectory` enumeration is not
        // ordering-guaranteed, but recreating the files flips the order the
        // bytes land for any FS that returns creation/inode order, exercising
        // "the other file could be read first." ---
        try FileManager.default.removeItem(at: fileA)
        try FileManager.default.removeItem(at: fileB)
        try await seed(fileB, [opB0, collisionFromB])
        try await seed(fileA, [collisionFromA])
        let loaded2 = try await store.load(docId: tmpDocIdForReload(docId))
        let derived2 = Deriver.derive(ops: loaded2)

        // Both loads must agree on the opId-sorted, deduped id set.
        XCTAssertEqual(loaded1.map(\.opId), ["01HZK01", "01HZK02"])
        XCTAssertEqual(loaded2.map(\.opId), ["01HZK01", "01HZK02"])

        // Determinism = LOAD-ORDER INDEPENDENCE, asserted two ways the real
        // `load` glob exercises:
        //  (a) the surviving content of the collision is the same across layouts,
        //  (b) so is the fully-derived manuscript state.
        // RED until M1 — divergent same-opId collision must resolve identically;
        // see plan 0.3 + finding 0.4.
        XCTAssertEqual(
            loaded1.first { $0.opId == "01HZK02" }?.changes.first?.next,
            loaded2.first { $0.opId == "01HZK02" }?.changes.first?.next,
            "divergent same-opId collision must resolve to the same survivor "
                + "regardless of per-device file enumeration order (no silent "
                + "load-order-dependent first-wins)")

        XCTAssertEqual(
            derived1, derived2,
            "two devices with identical logs must derive identical manuscript "
                + "state regardless of merge/enumeration order")

        // Belt-and-braces: also assert order-independence at the pure
        // `mergeSortedDedup` level over the two relative orders of the colliding
        // op (filesystem enumeration we cannot pin, but input order we can). This
        // pins the determinism contract even on FSs whose enumeration happens to
        // be stable across the recreate above.
        let mergedXY = OpLogStore.mergeSortedDedup([opB0, collisionFromA, collisionFromB])
        let mergedYX = OpLogStore.mergeSortedDedup([opB0, collisionFromB, collisionFromA])
        XCTAssertEqual(
            mergedXY.first { $0.opId == "01HZK02" }?.changes.first?.next,
            mergedYX.first { $0.opId == "01HZK02" }?.changes.first?.next,
            "mergeSortedDedup must pick the same survivor regardless of input "
                + "order — RED today (first-wins over a non-stable sort)")
    }

    /// Identity passthrough kept as a named helper so the second `load` call in
    /// case 1 reads as "reload the same doc" rather than a bare literal — the
    /// docId is unchanged; only the physical file layout differs.
    private func tmpDocIdForReload(_ docId: String) -> String { docId }

    // MARK: - Case 2 — external `.md` deletion of an anchored paragraph

    /// Drives: `Document.load` (production open) → `doc.handleExternalDiskChange`
    /// (the live external-edit seam, which calls `Reconciler.classify`).
    ///
    /// Scenario: op log + `.md` agree on anchored paragraphs [p1, p2, p3]; an
    /// external editor deletes p2's text+anchor from the `.md` while Maugham is
    /// running. We feed that disk bytes through the SAME path the NSFilePresenter
    /// callback uses.
    ///
    /// Contract: the deletion must be OBSERVED — p2 must NOT survive in the
    /// reconciled manuscript state.
    ///
    /// RED until M1 — `Reconciler.classify` iterates DISK paragraphs only, so a
    /// disk-deleted paragraph produces no change entry and classifies as `.echo`
    /// (or a `.silentIngest` that omits it); p2's id lingers in `paragraphs` +
    /// `sequence` and `materialize()` still emits it. See plan 0.3 +
    /// Reconciler-deletion finding (audit Tier-2 / sweep 3).
    func test_case2_externalDeletionOfAnchoredParagraph_isObserved() async throws {
        // Anchored on-disk .md with three paragraphs (4-char restricted ids).
        let p1 = "aaaa", p2 = "bbbb", p3 = "cccc"
        let initialMd = Materializer.materialize(
            paragraphs: [p1: "Para one.", p2: "Para two.", p3: "Para three."],
            sequence: [p1, p2, p3])

        let docURL = try makeManuscriptProject(initialMd: initialMd)
        let doc = try await Document.load(
            url: docURL, device: "mac-A", session: "s", presenter: nil)

        // Sanity: the live document agrees on all three before the edit.
        XCTAssertEqual(doc.displayText, "Para one.\n\nPara two.\n\nPara three.")

        // External editor deletes p2 entirely (its anchor + text), leaving p1, p3
        // both still anchored. This is exactly what a plain-text editor would
        // write back.
        let editedMd = Materializer.materialize(
            paragraphs: [p1: "Para one.", p3: "Para three."],
            sequence: [p1, p3])

        // Drive the production live-edit seam (the NSFilePresenter callback's
        // body). This routes through Reconciler.classify.
        try await doc.handleExternalDiskChange(diskMd: editedMd)

        // RED until M1 — the deletion must be observed. Today p2 survives because
        // the classifier never sees its absence.
        XCTAssertFalse(
            doc.displayText.contains("Para two."),
            "external deletion of anchored paragraph p2 must be observed — "
                + "Reconciler.classify iterates disk paragraphs only, so the "
                + "deleted paragraph silently survives (plan 0.3 + "
                + "Reconciler-deletion finding)")

        // Stronger: the reconciled/materialized manuscript must not re-emit p2.
        let rematerialized = doc.materialize()
        XCTAssertFalse(
            ParagraphParser.parse(rematerialized).contains { $0.id == p2 },
            "deleted paragraph id \(p2) must not linger in the derived "
                + "manuscript state after the external deletion is ingested")
    }

    // MARK: - Case 3 — drastic-rewrite / near-duplicate id-reattach (id steal)

    /// Drives: `RenderFilter.restoreComments(stored:displayEdited:)` — the
    /// production save-time id-reattach path (called on every editor save via
    /// `Document.setFullText`). The char-bigram (≥0.6) fallback tier reattaches
    /// ids for short paragraphs where word-shingles collapse.
    ///
    /// Scenario A (deterministic, single candidate): the writer DELETES the only
    /// stored paragraph "Yes." (id `aaaa`) and types a genuinely different short
    /// line "Yes?" in its place. The new paragraph should get a FRESH id. But
    /// `bigramOverlap("Yes?", "Yes.") == 0.667 ≥ 0.6`, so the bigram tier
    /// REATTACHES the deleted paragraph's id `aaaa` to the new line — identity
    /// corruption (the op log records `prior`/`next` against the wrong identity).
    ///
    /// Scenario B (the audit's named tie): two near-duplicate dialogue lines
    /// "Yes." / "Yes?" — a survivor "Yes!" ties both candidates at 0.667, so the
    /// surviving paragraph can steal EITHER sibling's id non-deterministically.
    ///
    /// RED until M1 — the bigram tier has no margin/uniqueness/own-id check
    /// (AREA.md calls tier-2/3 mis-pairing "silent corruption"; the disagreement
    /// test is missing). See plan 0.3 + finding O1/RenderFilter.
    func test_case3a_drasticRewrite_doesNotStealDeletedSiblingId() {
        // Single stored paragraph "Yes." with id `aaaa`.
        let stored = "<!-- ¶aaaa -->\n\nYes.\n"
        // Writer deletes "Yes." and types a different short line "Yes?".
        let displayEdited = "Yes?"

        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)

        XCTAssertEqual(parsed.count, 1)
        // RED until M1 — "Yes?" is a genuinely different paragraph than the
        // deleted "Yes."; it must mint a FRESH id, not inherit `aaaa` via the
        // unguarded bigram tier (overlap 0.667 ≥ 0.6 on a single candidate ⇒
        // deterministic steal).
        XCTAssertNotEqual(
            parsed.first?.id, "aaaa",
            "a drastically-different short paragraph must NOT inherit a deleted "
                + "sibling's id by char-bigram match — id-steal = identity "
                + "corruption (plan 0.3 + RenderFilter O1)")
    }

    func test_case3b_nearDuplicateTie_reusesIdWithNoMargin() {
        // Two near-duplicate dialogue lines `aaaa:"Yes."` / `bbbb:"Yes?"`. The
        // writer deletes one and lightly edits the other to a survivor "Yes!"
        // that is EQUIDISTANT from both:
        //   bigramOverlap("Yes!","Yes.") == bigramOverlap("Yes!","Yes?") == 0.667
        // — a perfect tie, both ≥ 0.6.
        let stored =
            "<!-- ¶aaaa -->\n\nYes.\n\n<!-- ¶bbbb -->\n\nYes?\n"
        let displayEdited = "Yes!"

        // The bigram tier's actual ambiguity is fully deterministic and provable
        // independent of how `max(by:)` happens to break the tie this run.
        let scoreA = ShingleMatcher.bigramOverlap("Yes!", "Yes.")
        let scoreB = ShingleMatcher.bigramOverlap("Yes!", "Yes?")
        XCTAssertEqual(scoreA, scoreB, accuracy: 1e-9,
            "the two candidates tie exactly — there is NO margin to choose between them")
        XCTAssertGreaterThanOrEqual(scoreA, 0.6,
            "and both clear the 0.6 reuse threshold, so the tier WILL reuse one id")

        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 1)

        // RED until M1 — on a within-margin tie the tier reuses SOME stored id
        // (`aaaa` or `bbbb`, picked by hash-seeded dictionary iteration) instead
        // of recognising the ambiguity and minting fresh. WHICH id it steals is
        // non-deterministic across process runs (so we can't pin it), but THAT it
        // reuses one with zero margin is the deterministic defect: a survivor can
        // inherit the DELETED sibling's id ⇒ silent identity corruption. A
        // margin/uniqueness rule (no reuse when the top-2 candidates are within
        // ε) would mint a fresh id here. See plan 0.3 + RenderFilter O1.
        let reusedAnExistingId = (parsed.first?.id == "aaaa" || parsed.first?.id == "bbbb")
        XCTAssertFalse(
            reusedAnExistingId,
            "on a zero-margin bigram tie the reattach tier must NOT reuse a "
                + "stored id (it can be the DELETED sibling's) — it should mint "
                + "fresh; reusing one is the identity-corruption hazard AREA.md "
                + "names")
    }

    // MARK: - Case 4 — skewed-clock same-paragraph LWW (DEFERRED, NOT a gate)

    /// Drives: `OpLogStore.mergeSortedDedup` + `Deriver.derive` on two devices
    /// that edit the SAME paragraph, where the device with the LATER real edit
    /// has the EARLIER wall clock (lower ULID prefix) and so loses on
    /// opId-order merge.
    ///
    /// DEFERRED — authored for documentation, NOT gated. Per the plan's
    /// single-editor decision (M2), skew-aware LWW + same-paragraph conflict
    /// surfacing is owned by the collaboration milestone, not Milestone 1. We
    /// skip so this scenario is recorded without being a failing gate.
    func test_case4_skewedClockSameParagraphLWW_DEFERRED() throws {
        throw XCTSkip(
            "deferred: skew-aware LWW / same-paragraph conflict surfacing owned "
                + "by the collaboration milestone — see plan M2. The scenario is "
                + "authored in `skewedClockScenario_documentationOnly` for the "
                + "record; it is NOT a Milestone-1 gate.")
    }

    /// Documents (does NOT gate) the skew-induced cross-device LWW loss: device
    /// B's clock is 5 minutes BEHIND device A. B makes the LATER real edit to a
    /// shared paragraph, but its lower wall clock → lower ULID prefix → its op
    /// sorts BEFORE A's and loses the opId-order LWW race, with no conflict
    /// surfaced (log-merge re-derives silently). Intentionally unreferenced —
    /// the deferral lives in `test_case4_…_DEFERRED` above (audit 0.2; plan M2).
    private func skewedClockScenario_documentationOnly() -> Deriver.DerivedState {
        let pid = "aaaa"
        // A: edited EARLIER in real time, but LATER wall clock (higher ULID).
        let changeA = Op.ParagraphChange(
            paragraphId: pid, prior: nil, next: "A's older text")
        let opA = Op(
            opId: "01HZK09", docId: "doc-skew",
            at: Date(timeIntervalSince1970: 100), device: "mac-A", session: "s",
            kind: .typingBurst, changes: [changeA], sequence: [pid])
        // B: edited LATER in real time, but SKEWED-BEHIND wall clock (lower ULID).
        let changeB = Op.ParagraphChange(
            paragraphId: pid, prior: nil, next: "B's NEWER text")
        let opB = Op(
            opId: "01HZK01", docId: "doc-skew",
            at: Date(timeIntervalSince1970: 400), device: "mac-B", session: "s",
            kind: .typingBurst, changes: [changeB], sequence: [pid])

        let merged = OpLogStore.mergeSortedDedup([opA, opB])
        // Today: opId-order keeps A's older text. Skew-aware LWW (collaboration
        // milestone) would keep B's newer text. Returned for the record only.
        return Deriver.derive(ops: merged)
    }

    // MARK: - Manuscript-project fixture (real Document.load path)

    /// Build a minimal on-disk Novel project with a single anchored manuscript
    /// `.md`, mirroring `DocumentTests.makeProject` so `Document.load` resolves
    /// the docId via the manifest and the real op log / reconcile path runs.
    private func makeManuscriptProject(initialMd: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp.appendingPathComponent(docPath)
    }
}
