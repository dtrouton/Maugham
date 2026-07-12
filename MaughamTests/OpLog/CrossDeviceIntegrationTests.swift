// MaughamTests/OpLog/CrossDeviceIntegrationTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// Adversarial cross-device merge/reconcile harness (plan task 0.3, Milestone 0).
///
/// These cases drive the **production** load / merge / derive / reconcile path —
/// `OpLogStore.load` glob+merge, `Deriver.derive`, the live external-edit seam
/// `Document.handleExternalDiskChange` (discards the external bytes: snapshots
/// them under `.maugham/conflicts/` and re-materializes the op-log truth, ADR
/// 0019), and the save-time id-reattach seam `RenderFilter.restoreComments` —
/// with the cross-device scenarios that have NO coverage today. They are NOT isolated
/// unit helpers; each goes through the same entry points the Mac app uses.
///
/// The active cases are EXPECTED TO FAIL against current code. That red is
/// intended: it defines "done" for Milestone 1/2. Do NOT modify production code
/// to make them pass here — this is a tests-only task.
///
/// Tripwire 8: cases 2 and 3 cross the `.md` ↔ op-log boundary
/// (the external-edit seam / RenderFilter), so every paragraph id uses the 4-char restricted
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
        let fileA = opsDir().appendingPathComponent("\(docId).\(slugA.raw).jsonl")
        let fileB = opsDir().appendingPathComponent("\(docId).\(slugB.raw).jsonl")

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

    // MARK: - Case 2 — external `.md` deletion must NOT remove an op-log paragraph

    /// Drives: `Document.load` (production open) → `doc.handleExternalDiskChange`
    /// (the live external-edit seam, which discards the external bytes and
    /// re-materializes the op-log truth, ADR 0019).
    ///
    /// Scenario: op log + `.md` agree on anchored paragraphs [p1, p2, p3]; an
    /// external editor (or a stale iCloud `.md`) deletes p2's text+anchor from the
    /// `.md` while Maugham is running. We feed that disk bytes through the SAME
    /// path the NSFilePresenter callback uses.
    ///
    /// Contract: the op log is the SOURCE OF TRUTH; the `.md` is derived. An
    /// external mutation of the `.md` — including a deletion — must NOT remove a
    /// paragraph the op log still authoritatively holds. p2 SURVIVES, and a
    /// re-materialize restores it to the `.md` (Maugham blows away the external
    /// edit). Honoring an outside deletion would let any external actor (another
    /// editor, a botched sync, a stale `.md`) silently delete authoritative
    /// manuscript content — the opposite of what we want.
    ///
    /// (Decision 2026-06-09, user: external `.md` edits are not a supported input
    /// channel — editing is through Maugham, which appends ops; cross-device sync
    /// flows through the op-log MERGE, ADR 0012, not `.md` reconcile. The audit's
    /// "deletion must be observed" framing had the polarity backwards. This test
    /// is the GUARD that protects op-log authority.)
    func test_case2_externalMdDeletion_doesNotRemoveOpLogParagraph() async throws {
        // Anchored on-disk .md with three paragraphs (4-char restricted ids).
        let p1 = "aaaa", p2 = "bbbb", p3 = "cccc"
        let initialMd = Materializer.materialize(
            paragraphs: [p1: "Para one.", p2: "Para two.", p3: "Para three."],
            sequence: [p1, p2, p3])

        let docURL = try makeManuscriptProject(initialMd: initialMd)
        // ADR 0019: the op log is the source of truth — seed it so load derives
        // the three paragraphs from the op log, not the `.md`'s anchors.
        try await seedOpLogBootstrap(
            projectURL: docURL.deletingLastPathComponent().deletingLastPathComponent(),
            docId: "doc-test",
            paragraphs: [p1: "Para one.", p2: "Para two.", p3: "Para three."],
            sequence: [p1, p2, p3])
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
        // body). The external bytes are snapshotted and discarded; the op-log
        // truth is re-materialized over them (ADR 0019).
        try await doc.handleExternalDiskChange(diskMd: editedMd)

        // The op log wins: p2 must SURVIVE the external deletion.
        XCTAssertTrue(
            doc.displayText.contains("Para two."),
            "external `.md` deletion must NOT remove an op-log-anchored paragraph "
                + "— the op log is the source of truth; honoring an outside "
                + "deletion would let any external actor silently delete "
                + "authoritative manuscript content")

        // And a re-materialize restores p2 to the `.md` (external edit discarded).
        let rematerialized = doc.materialize()
        XCTAssertTrue(
            ParagraphParser.parse(rematerialized).contains { $0.id == p2 },
            "re-materializing must re-emit p2 (id \(p2)) — Maugham blows away the "
                + "external `.md` edit and re-derives from the authoritative op log")
    }

    // MARK: - Case 3 — drastic-rewrite / near-duplicate id-reattach (id steal)

    /// Drives: `RenderFilter.restoreComments(stored:displayEdited:)` — the
    /// production save-time id-reattach path (called on every editor save via
    /// `Document.setFullText`). The char-bigram (≥0.6) fallback tier reattaches
    /// ids for short paragraphs where word-shingles collapse.
    ///
    /// Scenario A — single-candidate high-overlap = minor edit ⇒ KEEPS its id
    /// (REFRAMED 2026-06-09; the original assertion pinned the wrong behavior).
    ///
    /// The writer has ONE stored short paragraph "Yes." (id `aaaa`) and ends up
    /// with "Yes?" (`bigramOverlap == 0.667 ≥ 0.6`). From `restoreComments`'
    /// vantage — it sees only `stored` + `displayEdited` — a delete-and-retype
    /// is BYTE-IDENTICAL to an in-place one-character edit. The only safe,
    /// self-consistent default for a single high-overlap candidate is therefore
    /// to KEEP the id: that is exactly the common minor-edit case the production
    /// `RenderFilterTests.test_restoreComments_reattachesIdsByContentMatch`
    /// pins ("First." → "First, edited." at overlap 0.8 must keep `a3f9`). They
    /// are the same shape; forcing this one to mint fresh would break legit
    /// minor-edit reattach. The genuine corruption hazard is the *ambiguous*
    /// multi-candidate tie — covered by 3b, where the new margin-over-second-best
    /// rule mints fresh because there is no clear winner.
    ///
    /// (Original 3a asserted "must NOT inherit `aaaa`" on a single candidate.
    /// That conflicts with the legit-minor-edit contract above and was an
    /// instance of the audit's "a test pinning the wrong behavior" lesson; the
    /// margin rule deliberately reuses a *uniquely* best single candidate.)
    func test_case3a_singleCandidateMinorEdit_keepsItsId() {
        // Single stored paragraph "Yes." with id `aaaa`.
        let stored = "<!-- ¶aaaa -->\n\nYes.\n"
        // The displayed form is a lightly-edited "Yes?" — one stored candidate.
        let displayEdited = "Yes?"

        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)

        XCTAssertEqual(parsed.count, 1)
        // A single high-overlap candidate has no competitor to be ambiguous
        // against, so the margin rule reuses it — identical to the
        // "First." → "First, edited." minor-edit case. Reattaching `aaaa` is the
        // correct, identity-preserving behavior here; the corruption case is the
        // ambiguous multi-candidate tie in 3b.
        XCTAssertEqual(
            parsed.first?.id, "aaaa",
            "a lightly-edited single short paragraph must KEEP its id — a "
                + "delete+retype is byte-identical to an in-place edit, so id "
                + "retention is the safe single-candidate default (the corruption "
                + "case is the ambiguous tie in 3b)")
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

    // NOTE: skew-aware same-paragraph LWW (two devices edit one paragraph; the
    // later real edit has the earlier wall clock → lower ULID → loses the
    // opId-order merge, no conflict surfaced) is DEFERRED to the collaboration
    // milestone per the single-editor decision — see audit finding 0.2 + plan
    // M2. No test here: it would be inert until that resolution API exists;
    // TDD it red against the real skew-aware merge when the milestone starts.

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
