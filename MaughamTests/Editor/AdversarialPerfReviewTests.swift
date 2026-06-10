import XCTest
@testable import MaughamCore
@testable import Maugham

/// Adversarial review harness for perf fixes B (45e1983) and C (743cea6).
/// These are NOT shipped pins — they exist to PROVE (or disprove) specific
/// divergence hypotheses raised in review. If any fail, that's a real bug.
@MainActor
final class AdversarialPerfReviewTests: XCTestCase {

    // MARK: - B: faithful pre-B exact-tier oracle

    /// Verbatim re-implementation of the PRE-B `restoreComments` matcher
    /// (ab246b3), including the `unmatchedById.first(where:)` exact tier whose
    /// duplicate-pick was *unspecified*. We can't compare exact ids on
    /// duplicates (the old behavior was nondeterministic), so this oracle is
    /// used two ways:
    ///   - on inputs with NO duplicate stored texts, ids must match EXACTLY;
    ///   - on all inputs, the *reuse-vs-mint shape* and the *multiset of reused
    ///     ids* must match (a refinement can reorder which dup gets which id but
    ///     must not change WHICH ids are reused or how many fresh mints occur).
    private func preBMatcher(
        priorByIdStripped: [String: String],
        displayParsed: [ParsedParagraph]
    ) -> [(id: String, text: String)] {
        var unmatchedById = priorByIdStripped
        var pairs: [(id: String, text: String)] = []
        for d in displayParsed {
            if let id = unmatchedById.first(where: { $0.value == d.text })?.key {
                pairs.append((id, d.text))
                unmatchedById.removeValue(forKey: id)
                continue
            }
            if let m = ShingleMatcher.bestMatch(
                needle: d.text, candidates: unmatchedById, k: 4, threshold: 0.6) {
                pairs.append((m.id, d.text))
                unmatchedById.removeValue(forKey: m.id)
                continue
            }
            let ranked = unmatchedById
                .map { (id: $0.key, score: ShingleMatcher.bigramOverlap(d.text, $0.value)) }
                .sorted { $0.score > $1.score }
            if let best = ranked.first, best.score >= 0.6 {
                let secondScore = ranked.count > 1 ? ranked[1].score : 0.0
                if best.score - secondScore >= 0.1 {
                    pairs.append((best.id, d.text))
                    unmatchedById.removeValue(forKey: best.id)
                    continue
                }
            }
            pairs.append(("MINT", d.text))   // sentinel for "fresh"
        }
        return pairs
    }

    private func newMatcher(
        priorByIdStripped: [String: String],
        storedOrder: [String],
        displayParsed: [ParsedParagraph]
    ) -> [(id: String, text: String)] {
        RenderFilter.restorePairs(
            priorByIdStripped: priorByIdStripped,
            storedOrder: storedOrder,
            displayParsed: displayParsed
        ).map { (id: priorByIdStripped.keys.contains($0.id) ? $0.id : "MINT", text: $0.text) }
    }

    /// HYPOTHESIS (B.2): an earlier display paragraph claims one of text T's ids
    /// via the SHINGLE tier; a later display paragraph exact-matches T. The
    /// prebuilt exact index (built once over ALL T-ids) must skip the
    /// shingle-claimed id and grab the next.
    func test_B_shingleClaimsExactIdFirst_thenExactSkipsIt() {
        // Two stored ids share exact text "the cat sat on the mat today".
        // A third stored id "the cat sat on the mat now" is a near-shingle of a
        // display paragraph that will claim one of the exact ids? No — make the
        // shingle-claimer's TARGET be one of the exact-text ids:
        //
        // stored: id1="the cat sat on the mat", id2="the cat sat on the mat"
        // display[0] = "the cat sat on the mat please"  (shingle-matches id1/id2 > .6)
        // display[1] = "the cat sat on the mat"          (exact)
        // Old: display[0] shingle claims SOME id (id1 or id2); display[1] exact
        //      claims the remaining one. One reuse each.
        // New: display[0] shingle claims one; display[1] exact pops bucket,
        //      skips the claimed one, grabs the other. One reuse each.
        let stored: [String: String] = [
            "id01": "the cat sat on the mat",
            "id02": "the cat sat on the mat",
        ]
        let order = ["id01", "id02"]
        let display = [
            ParsedParagraph(id: nil, text: "the cat sat on the mat please today"),
            ParsedParagraph(id: nil, text: "the cat sat on the mat"),
        ]
        let new = RenderFilter.restorePairs(
            priorByIdStripped: stored, storedOrder: order, displayParsed: display)
        // Both display paras must reuse a stored id; both ids must be consumed
        // exactly once; no fresh mint.
        let reused = new.map(\.id).filter { stored.keys.contains($0) }
        XCTAssertEqual(Set(reused), Set(order),
            "both stored ids reused once; the exact tier must skip the shingle-claimed id")
        XCTAssertEqual(reused.count, 2, "no id reused twice, none minted")
    }

    /// HYPOTHESIS (B.2): more display copies of T than stored copies → extra
    /// mints; the extra display copies must mint fresh (not steal a non-T id).
    func test_B_moreDisplayCopiesThanStored_extraMint() {
        let stored: [String: String] = ["id01": "CUT TO:", "id02": "CUT TO:"]
        let order = ["id01", "id02"]
        let display = Array(repeating: ParsedParagraph(id: nil, text: "CUT TO:"), count: 4)
        let new = RenderFilter.restorePairs(
            priorByIdStripped: stored, storedOrder: order, displayParsed: display)
        XCTAssertEqual(new.count, 4)
        // First two reuse id01,id02 in FIFO order; last two mint fresh.
        XCTAssertEqual(new[0].id, "id01")
        XCTAssertEqual(new[1].id, "id02")
        XCTAssertFalse(order.contains(new[2].id))
        XCTAssertFalse(order.contains(new[3].id))
        XCTAssertNotEqual(new[2].id, new[3].id, "two distinct fresh ids")
    }

    /// HYPOTHESIS (B.2): MORE stored copies of T than display → leftover stored
    /// T-ids stay in `unmatchedById` and remain available to LATER display
    /// paragraphs' shingle/bigram tiers. Verify a later non-exact display
    /// paragraph can reuse a LEFTOVER exact-text id via the shingle tier.
    func test_B_leftoverExactIds_feedLaterShingleTier() {
        // stored: 3 copies of a long prose paragraph + nothing else.
        let body = "the quick brown fox jumps over the lazy dog repeatedly"
        let stored: [String: String] = ["id01": body, "id02": body, "id03": body]
        let order = ["id01", "id02", "id03"]
        // display: one exact copy, then a SHINGLE-near variant of the same body.
        let display = [
            ParsedParagraph(id: nil, text: body),
            ParsedParagraph(id: nil, text: body + " now"),  // shingle > .6 vs leftover copies
        ]
        let new = RenderFilter.restorePairs(
            priorByIdStripped: stored, storedOrder: order, displayParsed: display)
        XCTAssertEqual(new[0].id, "id01", "exact claims first stored id FIFO")
        // The second display paragraph should reuse a LEFTOVER stored id
        // (id02 or id03) via the shingle tier — NOT mint fresh.
        XCTAssertTrue(["id02", "id03"].contains(new[1].id),
            "leftover exact-text ids must remain available to later shingle tiers; got \(new[1].id)")
    }

    /// Differential over a randomized corpus with NO duplicate stored texts:
    /// new matcher ids must EXACTLY equal pre-B matcher ids (mint sentinel for
    /// fresh). This is the strongest equality claim and only valid when there
    /// are no exact-text duplicates (where old behavior was unspecified).
    func test_B_differential_noDuplicateTexts_exactIdParity() {
        var rng = SystemRandomNumberGenerator()
        let words = ["alpha","beta","gamma","delta","epsilon","zeta","eta","theta",
                     "the","cat","sat","mat","fox","dog","run","jump","over","lazy"]
        func randPara() -> String {
            let n = Int.random(in: 1...10, using: &rng)
            return (0..<n).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
        }
        for _ in 0..<400 {
            // Build a stored set with UNIQUE texts.
            var stored: [String: String] = [:]
            var order: [String] = []
            var seenTexts = Set<String>()
            let count = Int.random(in: 0...8, using: &rng)
            var attempts = 0
            while order.count < count && attempts < 50 {
                attempts += 1
                let t = randPara()
                if seenTexts.contains(t) { continue }
                seenTexts.insert(t)
                let id = ParagraphID.mint()
                if stored[id] != nil { continue }
                stored[id] = t
                order.append(id)
            }
            // Display: a mix of (exact stored texts, edited variants, new texts),
            // also kept unique to preserve determinism of the exact tier.
            var display: [ParsedParagraph] = []
            var displaySeen = Set<String>()
            func pushUnique(_ t: String) {
                if displaySeen.contains(t) { return }
                displaySeen.insert(t); display.append(ParsedParagraph(id: nil, text: t))
            }
            for t in order.shuffled(using: &rng).map({ stored[$0]! }) {
                let r = Int.random(in: 0...2, using: &rng)
                if r == 0 { pushUnique(t) }                       // exact keep
                else if r == 1 { pushUnique(t + " extra") }        // edit
                // r==2: drop it
            }
            let extra = Int.random(in: 0...3, using: &rng)
            for _ in 0..<extra { pushUnique(randPara() + " brandnew unique") }

            let old = preBMatcher(priorByIdStripped: stored, displayParsed: display)
            let new = newMatcher(priorByIdStripped: stored, storedOrder: order, displayParsed: display)
            XCTAssertEqual(old.map(\.id), new.map(\.id),
                "exact-id parity (no dup texts). stored=\(stored) display=\(display.map(\.text))")
        }
    }

    /// HYPOTHESIS (B.3): `storedOrder` (== full `sequence`) may carry an id that
    /// has NO `priorByIdStripped` entry (a sequence id whose paragraph text is
    /// absent — the same case `materialize` defensively skips). The exact-index
    /// builder must skip it (no phantom bucket entry / no crash).
    func test_B_storedOrderIdMissingFromMap_isSkipped() {
        let stored: [String: String] = ["id01": "hello there world"]
        let order = ["id01", "ghost"]   // "ghost" has no entry
        let display = [ParsedParagraph(id: nil, text: "hello there world")]
        let pairs = RenderFilter.restorePairs(
            priorByIdStripped: stored, storedOrder: order, displayParsed: display)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].id, "id01", "missing-from-map stored id must not be claimable")
    }

    // MARK: - C: ParagraphParser CRLF / CR / NBSP / leading-ws-comment

    /// Verbatim pre-C ParagraphParser oracle (from the perf-C diff's removed code).
    private static func parseReferencePreC(_ markdown: String) -> [ParsedParagraph] {
        var result: [ParsedParagraph] = []
        var pendingId: String? = nil
        var buffer: [String] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { result.append(ParsedParagraph(id: pendingId, text: text)) }
            buffer.removeAll(keepingCapacity: true); pendingId = nil
        }
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines {
            let s = String(line)
            if s.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            if let id = ParagraphID.parseComment(s) { flush(); pendingId = id; continue }
            buffer.append(s)
        }
        flush()
        return result
    }

    func test_C_paragraphParser_crlf_cr_nbsp_leadingWsComment() {
        let docs: [String] = [
            "a\r\nb\r\nc",                                   // CRLF body
            "para one\r\n\r\npara two",                      // CRLF blank line
            "a\rb\rc",                                       // lone CR
            "<!-- ¶ab2c -->\r\n\r\nHello.",                  // CRLF after anchor
            "  <!-- ¶ab2c -->  \n\nIndented anchor",         // leading-ws own-line anchor
            "\t<!-- ¶ab2c -->\n\nTab anchor",
            "\u{00A0}<!-- ¶ab2c -->\n\nNBSP-led anchor",     // NBSP before '<' → defer path
            "line\u{00A0}with nbsp\n\nnext",                 // NBSP mid-line non-blank
            "\u{00A0}\n\u{2003}\n\u{2009}\n\ncontent",        // unicode-ws-only lines (blank)
            "  \t  \n\nonly-ascii-blanks",                   // ascii blanks
            "\u{00A0}",                                       // NBSP-only single line
            "\u{2028}",                                       // line separator scalar
            "x\u{2028}y",                                     // U+2028 mid (isNewline?)
            "trailing nbsp  \u{00A0}\n\nbody",
            "<!-- ¶ab2c --> trailing text on anchor line",   // not pure anchor → kept as text
        ]
        for d in docs {
            let got = ParagraphParser.parse(d)
            let want = Self.parseReferencePreC(d)
            XCTAssertEqual(got, want, "ParagraphParser diverged for \(d.debugDescription)")
        }
    }

    func test_C_fastTrim_crlf_residue_and_unicode() {
        // Lines that could appear after splitting; include CR residue forms even
        // though split normally consumes CR — defensive against direct callers.
        let lines: [String] = [
            "a\r", "\ra", "a\rb", "  x  ", "\u{00A0}x\u{00A0}", "\u{2003}",
            "  \u{00A0}  ", "x\u{2028}", "\tcafé\t", "\u{200B}x",  // ZWSP (not Zs)
        ]
        for line in lines {
            let got = FountainTokenizer.fastTrimWhitespaces(line)
            let want = line.trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(got, want, "fastTrimWhitespaces diverged for \(line.debugDescription)")
        }
    }

    // MARK: - C.8: TaskAnchorAlignment early-out cannot perturb cross-move

    /// A skipped unchanged no-anchor paragraph sitting between an anchor SOURCE
    /// (loses a line) and a DESTINATION (gains it) must not change the Pass 2
    /// cross-paragraph correlation result. We compare align() — where the
    /// middle paragraph IS skipped (no `<!--`, prior==displayed) — against a
    /// run where the middle paragraph is forced through the full path by
    /// carrying a no-op anchor of its own. The SOURCE→DEST carry must be
    /// identical in both.
    func test_C8_earlyOut_skippedParagraph_doesNotPerturbCrossMove() {
        let aPid = "aaaa", cPid = "cccc", bPid = "bbbb"
        // prior: A has an anchored task line; C is plain unchanged prose;
        // B is plain prose.
        let priorById: [String: String] = [
            aPid: "lead\n- [ ] foo <!--t-aaaaaa-->\ntail",
            cPid: "an unchanged middle paragraph of prose here",
            bPid: "a destination paragraph of prose here",
        ]
        // next: A loses the foo line; C unchanged (→ skipped); B gains foo.
        let next: [(id: String, text: String)] = [
            (aPid, "lead\ntail"),
            (cPid, "an unchanged middle paragraph of prose here"),
            (bPid, "a destination paragraph of prose here\n- [ ] foo"),
        ]
        let seq = [aPid, cPid, bPid]
        // Cursor bias: pre-edit in A, post-edit in B.
        let preCur = 6                              // inside A's foo line
        let aLen = ("lead\ntail" as NSString).length
        let cLen = ("an unchanged middle paragraph of prose here" as NSString).length
        let postCur = aLen + 2 + cLen + 2 + ("a destination paragraph of prose here\n- [ ] foo" as NSString).length - 1
        let res = TaskAnchorAlignment.align(
            priorById: priorById, nextParagraphs: next,
            priorSequence: seq, nextSequence: seq,
            preEditCursor: preCur, postEditCursor: postCur)
        // The anchor must have carried onto B's foo line, and produced NO archive.
        XCTAssertTrue((res.restoredById[bPid] ?? "").contains("<!--t-aaaaaa-->"),
            "cross-move carry must land on B even with a skipped middle paragraph; got \(res.restoredById[bPid] ?? "nil")")
        XCTAssertTrue(res.archivedAnchors.isEmpty,
            "cross-move should rescind the archive; got \(res.archivedAnchors)")
        // The skipped paragraph must round-trip its displayed text verbatim.
        XCTAssertEqual(res.restoredById[cPid], "an unchanged middle paragraph of prose here")
    }

    /// Whole-pipeline: parse(restoreComments(stored, display)) form-equivalence
    /// across the parse-once seam, with anchored stored text containing CRLF.
    func test_C_restoreComments_crlf_roundtrip() {
        let stored = "<!-- ¶ab2c -->\r\n\r\nHello world here.\r\n\r\n<!-- ¶wxyz -->\r\n\r\nGoodbye world here."
        let display = "Hello world here.\n\nGoodbye world here."
        let out = RenderFilter.restoreComments(stored: stored, displayEdited: display)
        let parsed = ParagraphParser.parse(out)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "ab2c", "anchor id survives CRLF stored form")
        XCTAssertEqual(parsed[1].id, "wxyz")
        XCTAssertEqual(parsed[0].text, "Hello world here.")
    }
}
