import XCTest
import MaughamCore
@testable import Maugham

/// Pins the perf-fix-B restructure of the per-keystroke document path:
///
///   1. `RenderFilter.restorePairs` (the factored-out matcher) drives the
///      public `restoreComments(stored:displayEdited:)` wrapper byte-for-byte.
///      `restoreComments` == "manual pipeline" (parse stored → strip → ordered
///      `restorePairs` → materialize) on varied inputs.
///   2. `Document.setFullText`, after the parse-once restructure, produces the
///      same end state (paragraphs / sequence / pending changes / id stability)
///      as the contract it always upheld — verified through derived invariants:
///      unchanged paragraphs keep their id, the edited paragraph keeps its id,
///      genuinely new paragraphs get fresh ids, and `pending.snapshot()` matches
///      the expected change set.
///   3. The `priorById == paragraphs-filtered-to-sequence` identity that lets
///      `setFullText` skip the prior-side materialize→parse roundtrip holds.
///   4. The indexed exact tier claims duplicate-text stored ids in deterministic
///      STORED ORDER (FIFO) — the screenplay "CUT TO:" ×N case.
@MainActor
final class RestorePairsEquivalenceTests: XCTestCase {

    // MARK: - Helpers

    private func makeDoc(text: String) async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RPE-\(UUID().uuidString)")
        let manuscriptDir = tmp.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(
            at: manuscriptDir, withIntermediateDirectories: true)
        let mdURL = manuscriptDir.appendingPathComponent("doc.md")
        try text.write(to: mdURL, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: mdURL, device: "test", session: "s", presenter: nil)
    }

    /// The "manual pipeline" reference: exactly what the public wrapper does,
    /// spelled out so we can assert the wrapper still equals it.
    private func manualRestore(stored: String, displayEdited: String) -> String {
        let storedParsed = ParagraphParser.parse(stored)
        let displayParsed = ParagraphParser.parse(displayEdited)
        var priorById: [String: String] = [:]
        var storedOrder: [String] = []
        for p in storedParsed {
            if let id = p.id {
                priorById[id] = RenderFilter.stripTaskAnchorsInline(p.text)
                storedOrder.append(id)
            }
        }
        let pairs = RenderFilter.restorePairs(
            priorByIdStripped: priorById, storedOrder: storedOrder,
            displayParsed: displayParsed)
        var paragraphs: [String: String] = [:]
        var sequence: [String] = []
        for pair in pairs {
            paragraphs[pair.id] = pair.text
            sequence.append(pair.id)
        }
        return Materializer.materialize(paragraphs: paragraphs, sequence: sequence)
    }

    /// Stored .md with two anchored paragraphs (ids from the restricted
    /// alphabet). Used to exercise the public `restoreComments(stored:…)`
    /// wrapper, which legitimately parses anchored stored text.
    private func twoParaStored(
        _ id1: String, _ t1: String, _ id2: String, _ t2: String
    ) -> String {
        """
        <!-- ¶\(id1) -->

        \(t1)

        <!-- ¶\(id2) -->

        \(t2)
        """
    }

    // MARK: - (a) wrapper == manual pipeline

    /// `restoreComments` (the public wrapper) must equal the manual pipeline
    /// that routes through the ordered `restorePairs` seam. Because both mint
    /// fresh ids non-deterministically, compare structurally: identical id for
    /// paragraphs that should be reused, fresh ids where minting is expected.
    func test_wrapper_matchesManualPipeline_idReuseAndMint() {
        // Use ids that survive ParagraphID.parseComment (4-char alphabet).
        let id1 = "abcd", id2 = "wxyz"
        let cases: [(stored: String, display: String)] = [
            // unchanged
            (twoParaStored(id1, "Hello world.", id2, "Goodbye world."),
             "Hello world.\n\nGoodbye world."),
            // first edited (minor), second unchanged
            (twoParaStored(id1, "Hello world.", id2, "Goodbye world."),
             "Hello, world!\n\nGoodbye world."),
            // inserted middle paragraph (fresh id expected for new one)
            (twoParaStored(id1, "Alpha beta gamma.", id2, "Delta epsilon zeta."),
             "Alpha beta gamma.\n\nbrand new middle line here.\n\nDelta epsilon zeta."),
            // reorder
            (twoParaStored(id1, "First sentence here.", id2, "Second sentence here."),
             "Second sentence here.\n\nFirst sentence here."),
        ]
        for c in cases {
            let viaWrapper = RenderFilter.restoreComments(
                stored: c.stored, displayEdited: c.display)
            let viaManual = manualRestore(
                stored: c.stored, displayEdited: c.display)
            // Compare id-sequence structure: which display paragraphs reused
            // a stored id vs minted fresh. Strip out the specific minted id
            // values (which differ run-to-run) by mapping to "reused"/"fresh".
            let storedIds = Set([id1, id2])
            func shape(_ md: String) -> [(reused: Bool, text: String)] {
                ParagraphParser.parse(md).map { p in
                    (reused: p.id.map { storedIds.contains($0) } ?? false,
                     text: p.text)
                }
            }
            let sW = shape(viaWrapper)
            let sM = shape(viaManual)
            XCTAssertEqual(sW.count, sM.count, "para count: \(c.display)")
            for (w, m) in zip(sW, sM) {
                XCTAssertEqual(w.reused, m.reused,
                    "reuse decision must match for \"\(w.text)\" in case \(c.display)")
                XCTAssertEqual(w.text, m.text)
            }
            // Reused ids must be the SAME id, not just both "reused".
            let wReusedIds = ParagraphParser.parse(viaWrapper)
                .compactMap { $0.id }.filter { storedIds.contains($0) }
            let mReusedIds = ParagraphParser.parse(viaManual)
                .compactMap { $0.id }.filter { storedIds.contains($0) }
            XCTAssertEqual(wReusedIds, mReusedIds,
                "reused stored ids (and their order) must be identical")
        }
    }

    // MARK: - (b) setFullText end-state parity (derived invariants)

    func test_setFullText_minorEdit_keepsId_recordsOneChange() async throws {
        let doc = try await makeDoc(text: "The quick brown fox.")
        let originalId = doc.sequence.first
        XCTAssertNotNil(originalId)

        doc.setFullText("The quick brown fox jumps.")

        XCTAssertEqual(doc.sequence, [originalId],
            "minor in-place edit must keep the single paragraph id")
        XCTAssertEqual(doc.paragraphs[originalId!], "The quick brown fox jumps.")
        let changes = doc.pending.snapshot()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.paragraphId, originalId)
        XCTAssertEqual(changes.first?.prior, "The quick brown fox.")
        XCTAssertEqual(changes.first?.next, "The quick brown fox jumps.")
    }

    func test_setFullText_split_keepsFirstId_mintsSecond() async throws {
        let doc = try await makeDoc(text: "Lead sentence here that is long.")
        let id1 = doc.sequence.first!
        doc.setFullText("Lead sentence here that is long.\n\nA freshly added second paragraph.")
        XCTAssertEqual(doc.sequence.count, 2)
        XCTAssertEqual(doc.sequence.first, id1, "unchanged first paragraph keeps its id")
        XCTAssertNotEqual(doc.sequence[1], id1, "new paragraph must get a fresh id")
        XCTAssertEqual(doc.paragraphs[doc.sequence[1]], "A freshly added second paragraph.")
        XCTAssertEqual(doc.paragraphs.count, 2)
        XCTAssertTrue(Set(doc.paragraphs.keys).isSubset(of: Set(doc.sequence)),
            "paragraphs.keys ⊆ sequence invariant must hold after the edit")
    }

    func test_setFullText_merge_dropsSecondId_recordsChangeAndPrune() async throws {
        // Drive through DISPLAY text (anchor-free) — production never feeds
        // setFullText literal anchors; ids are assigned by restorePairs from
        // the doc's own state. Capture the two real minted ids.
        let doc = try await makeDoc(text: "seed.")
        doc.setFullText("Para one content.\n\nPara two content.")
        XCTAssertEqual(doc.sequence.count, 2)
        let firstId = doc.sequence[0]
        let secondId = doc.sequence[1]

        // Merge: delete the blank line so both bodies join into one paragraph.
        // The merged text matches NEITHER prior exactly and (being two short
        // sentences) doesn't clear the shingle/bigram tiers against either, so
        // restoreComments mints a fresh id for the merged paragraph — EXISTING
        // behavior, unchanged by the parse-once refactor (the matcher was moved,
        // not rewritten). The load-bearing invariant for THIS test is the
        // orphan prune: both pre-merge ids must leave `paragraphs` so neither
        // lingers as a phantom. (Cross-checked against the public wrapper below
        // to prove the refactor didn't change the outcome.)
        doc.setFullText("Para one content.\nPara two content.")
        XCTAssertEqual(doc.sequence.count, 1, "merge leaves one paragraph")
        XCTAssertNil(doc.paragraphs[firstId],
            "pre-merge first id must not linger in paragraphs")
        XCTAssertNil(doc.paragraphs[secondId],
            "pre-merge second id must not linger in paragraphs")
        XCTAssertEqual(doc.paragraphs.count, 1, "paragraphs.keys ⊆ sequence (size 1)")
        XCTAssertEqual(doc.paragraphs[doc.sequence[0]], "Para one content.\nPara two content.")

        // Cross-check: the public wrapper applied to the same prior+display
        // yields the same id-reuse SHAPE (here: a single fresh-id paragraph),
        // proving the parse-once path matches restoreComments.
        let priorMd = """
            <!-- ¶\(firstId) -->\n\nPara one content.\n
            <!-- ¶\(secondId) -->\n\nPara two content.
            """
        let viaWrapper = RenderFilter.restoreComments(
            stored: priorMd, displayEdited: "Para one content.\nPara two content.")
        let wrapperParsed = ParagraphParser.parse(viaWrapper)
        XCTAssertEqual(wrapperParsed.count, 1)
        XCTAssertFalse([firstId, secondId].contains(wrapperParsed[0].id ?? ""),
            "wrapper also mints fresh for this merge — refactor parity confirmed")
    }

    func test_setFullText_delete_dropsTrailingParagraph() async throws {
        let doc = try await makeDoc(text: "seed.")
        doc.setFullText("Keeper paragraph.\n\nDoomed paragraph.")
        XCTAssertEqual(doc.sequence.count, 2)
        let firstId = doc.sequence[0]
        let secondId = doc.sequence[1]

        doc.setFullText("Keeper paragraph.")
        XCTAssertEqual(doc.sequence, [firstId])
        XCTAssertNil(doc.paragraphs[secondId])
        XCTAssertEqual(doc.paragraphs.count, 1)
    }

    func test_setFullText_pasteAppend_mintsFreshForNewTail() async throws {
        let doc = try await makeDoc(text: "Original opening paragraph.")
        let id1 = doc.sequence.first!
        doc.setFullText("Original opening paragraph.\n\nPasted block alpha.\n\nPasted block beta.")
        XCTAssertEqual(doc.sequence.first, id1)
        XCTAssertEqual(doc.sequence.count, 3)
        XCTAssertEqual(Set([doc.sequence[1], doc.sequence[2]]).count, 2,
            "two distinct fresh ids for two pasted paragraphs")
        XCTAssertFalse([doc.sequence[1], doc.sequence[2]].contains(id1))
    }

    func test_setFullText_reorder_preservesIdsAcrossSwap() async throws {
        let doc = try await makeDoc(text: "seed.")
        doc.setFullText("Alpha paragraph one.\n\nBeta paragraph two.")
        let alphaId = doc.sequence[0]
        let betaId = doc.sequence[1]
        // Swap the two paragraphs (display order reversed).
        doc.setFullText("Beta paragraph two.\n\nAlpha paragraph one.")
        XCTAssertEqual(doc.sequence, [betaId, alphaId],
            "exact-text reorder must preserve ids, just reordering sequence")
    }

    // MARK: - priorById == paragraphs identity (the perf-fix premise)

    /// The restructure assumes `parse(materialize(paragraphs, sequence))`
    /// reconstructs `paragraphs` 1:1 for ids in `sequence`. If any paragraph
    /// value weren't already parse-normalized this would diverge and the
    /// parse-once path would feed V2 alignment a different prior map. Drive a
    /// realistic edit sequence and assert the identity holds at each step.
    func test_priorByIdEqualsParagraphs_afterVariedEdits() async throws {
        let doc = try await makeDoc(text: "First paragraph of the document.")
        let edits = [
            "First paragraph of the document, now extended.",
            "First paragraph of the document, now extended.\n\nSecond paragraph appears.",
            "First paragraph, trimmed.\n\nSecond paragraph appears.",
            "First paragraph, trimmed.\nSecond paragraph appears.",   // merge
            "First paragraph, trimmed.",                              // delete tail
        ]
        for edit in edits {
            doc.setFullText(edit)
            // The identity: rebuild priorById both ways.
            let viaState = doc.paragraphs   // {id: anchored text} over sequence
            let materialized = Materializer.materialize(
                paragraphs: doc.paragraphs, sequence: doc.sequence)
            var viaParse: [String: String] = [:]
            for p in ParagraphParser.parse(materialized) {
                if let id = p.id { viaParse[id] = p.text }
            }
            XCTAssertEqual(viaState, viaParse,
                "parse(materialize(paragraphs,sequence)) must reconstruct paragraphs 1:1 after edit: \(edit)")
            XCTAssertTrue(Set(doc.paragraphs.keys).isSubset(of: Set(doc.sequence)),
                "paragraphs.keys ⊆ sequence after edit: \(edit)")
        }
    }

    // MARK: - (b cont.) duplicate-text deterministic stored-order claiming

    /// Screenplay-realistic: many identical "CUT TO:" paragraphs. The indexed
    /// exact tier must claim stored ids in STORED ORDER (FIFO) so an edit that
    /// preserves all of them maps each display paragraph to the SAME-positioned
    /// stored id — deterministic, not arbitrary `Dictionary.first(where:)`.
    func test_restorePairs_duplicateText_claimsInStoredOrder() {
        let n = 20
        var stripped: [String: String] = [:]
        var order: [String] = []
        // Mint distinct 4-char ids; all carry identical text "CUT TO:".
        for _ in 0..<n {
            let id = ParagraphID.mint()
            stripped[id] = "CUT TO:"
            order.append(id)
        }
        let display = (0..<n).map { _ in ParsedParagraph(id: nil, text: "CUT TO:") }
        let pairs = RenderFilter.restorePairs(
            priorByIdStripped: stripped, storedOrder: order,
            displayParsed: display)
        XCTAssertEqual(pairs.map(\.id), order,
            "duplicate-text exact matches must claim stored ids in stored (FIFO) order")
        // Determinism: identical inputs → identical output (run twice).
        let pairs2 = RenderFilter.restorePairs(
            priorByIdStripped: stripped, storedOrder: order,
            displayParsed: display)
        XCTAssertEqual(pairs.map(\.id), pairs2.map(\.id))
    }

    /// Deleting one of N identical paragraphs: N-1 display copies must claim
    /// the FIRST N-1 stored ids (FIFO), leaving the last id unclaimed (and thus
    /// available to leave `sequence`, i.e. be archived/pruned downstream).
    func test_restorePairs_duplicateText_deleteOne_claimsFirstStoredIds() {
        let n = 5
        var stripped: [String: String] = [:]
        var order: [String] = []
        for _ in 0..<n {
            let id = ParagraphID.mint()
            stripped[id] = "CUT TO:"
            order.append(id)
        }
        let display = (0..<(n - 1)).map { _ in ParsedParagraph(id: nil, text: "CUT TO:") }
        let pairs = RenderFilter.restorePairs(
            priorByIdStripped: stripped, storedOrder: order,
            displayParsed: display)
        XCTAssertEqual(pairs.map(\.id), Array(order.prefix(n - 1)),
            "N-1 survivors claim the first N-1 stored ids in order; the last id is freed")
    }

    /// End-to-end via setFullText: 6 identical screenplay transitions, edit one
    /// in the middle, assert the five unchanged ones keep their original ids in
    /// deterministic FIFO order. (Production feeds setFullText anchor-free
    /// display text and ids are assigned by restorePairs from doc state, so we
    /// capture the real minted ids — literal anchors in input are ignored.)
    func test_setFullText_manyIdenticalParagraphs_stableIds() async throws {
        let doc = try await makeDoc(text: "seed.")
        // Establish 6 identical "CUT TO:" paragraphs; capture their fresh ids.
        doc.setFullText(Array(repeating: "CUT TO:", count: 6).joined(separator: "\n\n"))
        let ids = doc.sequence
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids).count, 6, "six distinct fresh ids")

        // Edit the 4th paragraph's text; the other five stay "CUT TO:".
        var display = Array(repeating: "CUT TO:", count: 6)
        display[3] = "FADE OUT:"
        doc.setFullText(display.joined(separator: "\n\n"))

        // Exact-match claims happen in DISPLAY order, each grabbing the next
        // unclaimed stored id in STORED order (FIFO). So the five "CUT TO:"
        // display slots — indices 0,1,2,4,5 — claim the first five stored ids
        // in order: ids[0..4]. The edited slot (index 3, "FADE OUT:") has no
        // exact match; the remaining stored id (ids[5]) carries "CUT TO:",
        // which is far enough from "FADE OUT:" that the bigram tier misses →
        // it mints fresh. Pin the deterministic part: the five survivors map
        // to the first five stored ids, in order.
        let seq = doc.sequence
        XCTAssertEqual(seq.count, 6)
        let survivors = [seq[0], seq[1], seq[2], seq[4], seq[5]]
        XCTAssertEqual(survivors, Array(ids.prefix(5)),
            "the five unchanged CUT TO: paragraphs claim the first five stored ids in FIFO order")
        // The edited slot got a fresh id (not one of the original six).
        XCTAssertFalse(ids.contains(seq[3]),
            "the edited FADE OUT: slot mints fresh (ids[5] carries CUT TO:, not FADE OUT:)")
    }
}
