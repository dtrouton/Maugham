import XCTest
@testable import Maugham
@testable import MaughamCore

/// Task 6.5 pin: `RenderFilter.restorePairs` WITH a `ShingleSetCache` must
/// produce BYTE-FOR-BYTE identical output to WITHOUT one — the cache memoizes
/// candidate shingle/bigram SET computation only; it does not change which id
/// each display paragraph claims, the threshold/margin rules, or the claim
/// order. Three angles:
///
///   1. Cold cache (fresh per call) vs no cache, over randomized mixed-length
///      corpora that exercise the exact tier, the word-shingle tier (tier 2),
///      AND the bigram-fallback tier (tier 3) incl. the margin-over-second-best
///      rule (near-duplicate short paragraphs).
///   2. Warm cache reused across a *single* call vs no cache — same inputs.
///   3. Cache REUSE across a simulated keystroke stream (same candidate set,
///      evolving needle): each keystroke's cached output must equal the
///      uncached output for that keystroke. This is the actual production
///      pattern the cache exists to serve.
///
/// Deterministic via SplitMix64 (the differential-suite RNG), so a failure is
/// reproducible from the seed printed in the assertion message.
final class RestorePairsCacheEquivalenceTests: XCTestCase {

    // MARK: - Corpus generation (mixed lengths, near-duplicates)

    /// Word lexicon kept small so near-duplicate prose and short-string
    /// collisions arise naturally — driving tiers 2 and 3 and the margin rule.
    private static let lexicon = [
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "the", "cat", "sat", "on", "mat", "fox", "dog", "ran", "jumped", "over",
        "lazy", "quick", "brown", "yes", "no", "maybe", "soon", "now",
    ]

    /// A paragraph of `wordCount` words (1...12). Short counts (< 4) deliberately
    /// fall to the bigram tier; long counts feed the word-shingle tier.
    private static func makePara(wordCount: Int, rng: inout SplitMix64) -> String {
        (0..<wordCount)
            .map { _ in lexicon[Int(rng.next() % UInt64(lexicon.count))] }
            .joined(separator: " ")
    }

    /// Build a stored map + stored-order array of `count` paragraphs with mixed
    /// lengths (so both fuzzy tiers are reachable) plus occasional exact / near
    /// duplicates (so the margin rule fires). Ids are 4-char minted (cross the
    /// .md boundary cleanly — tripwire 8).
    private static func makeStored(
        count: Int, rng: inout SplitMix64
    ) -> (map: [String: String], order: [String]) {
        var map: [String: String] = [:]
        var order: [String] = []
        var lastText = ""
        for i in 0..<count {
            let len = 1 + Int(rng.next() % 12)
            var text = makePara(wordCount: len, rng: &rng)
            // ~25%: emit a NEAR-duplicate of the previous paragraph (one-word
            // tweak) to provoke tier-3 near-ties / tier-2 high overlaps.
            if i > 0 && rng.next() % 4 == 0 && !lastText.isEmpty {
                text = lastText + (rng.next() % 2 == 0 ? " now" : " soon")
            }
            // ~12%: an EXACT duplicate of the previous (screenplay "CUT TO:").
            if i > 0 && rng.next() % 8 == 0 && !lastText.isEmpty {
                text = lastText
            }
            let id = ParagraphID.mint()
            map[id] = text
            order.append(id)
            lastText = text
        }
        return (map, order)
    }

    /// Build a display script from a stored map: keep some exact, edit some
    /// (minor + major), drop some, insert brand-new — the full edit vocabulary.
    private static func makeDisplay(
        from stored: (map: [String: String], order: [String]),
        rng: inout SplitMix64
    ) -> [ParsedParagraph] {
        var out: [ParsedParagraph] = []
        for id in stored.order {
            let text = stored.map[id]!
            switch rng.next() % 5 {
            case 0: out.append(ParsedParagraph(id: nil, text: text))            // exact keep
            case 1: out.append(ParsedParagraph(id: nil, text: text + " edited")) // minor edit
            case 2:                                                              // major edit
                out.append(ParsedParagraph(
                    id: nil, text: makePara(wordCount: 1 + Int(rng.next() % 6), rng: &rng)))
            case 3: break                                                       // drop
            default: out.append(ParsedParagraph(id: nil, text: text))           // keep
            }
        }
        // A couple of genuinely-new paragraphs.
        for _ in 0..<Int(rng.next() % 3) {
            out.append(ParsedParagraph(
                id: nil, text: makePara(wordCount: 1 + Int(rng.next() % 10), rng: &rng)))
        }
        return out
    }

    // MARK: - 1 & 2: cold + warm cache == no cache (single call)

    func test_coldAndWarmCache_matchNoCache_randomizedCorpora() {
        for trial in 0..<500 {
            var rng = SplitMix64(seed: 0xCACEED &+ UInt64(trial))
            let count = Int(rng.next() % 40)
            let stored = Self.makeStored(count: count, rng: &rng)
            let display = Self.makeDisplay(from: stored, rng: &rng)

            let noCache = RenderFilter.restorePairs(
                priorByIdStripped: stored.map, storedOrder: stored.order,
                displayParsed: display, cache: nil)

            // Cold cache: a fresh instance, never primed.
            let cold = RenderFilter.restorePairs(
                priorByIdStripped: stored.map, storedOrder: stored.order,
                displayParsed: display, cache: RenderFilter.ShingleSetCache())

            // Warm cache: prime it with a throwaway identical pass first, then
            // run the measured pass against the SAME instance (every candidate
            // set is now a cache hit).
            let warmCache = RenderFilter.ShingleSetCache()
            _ = RenderFilter.restorePairs(
                priorByIdStripped: stored.map, storedOrder: stored.order,
                displayParsed: display, cache: warmCache)
            let warm = RenderFilter.restorePairs(
                priorByIdStripped: stored.map, storedOrder: stored.order,
                displayParsed: display, cache: warmCache)

            assertSameShape(noCache, cold, storedIds: Set(stored.order),
                seed: 0xCACEED &+ UInt64(trial), label: "cold")
            assertSameShape(noCache, warm, storedIds: Set(stored.order),
                seed: 0xCACEED &+ UInt64(trial), label: "warm")
        }
    }

    // MARK: - 3: cache reuse across an evolving keystroke stream

    /// The production pattern: ONE cache instance, candidate set stable, needle
    /// evolves one char at a time. Each keystroke's cached output must equal the
    /// uncached output for that keystroke's exact inputs.
    func test_cacheReuse_acrossKeystrokeStream_matchesPerKeystrokeNoCache() {
        for trial in 0..<120 {
            var rng = SplitMix64(seed: 0x570BE5 &+ UInt64(trial))
            let count = 5 + Int(rng.next() % 30)
            let stored = Self.makeStored(count: count, rng: &rng)
            let cache = RenderFilter.ShingleSetCache()

            // Evolve ONE paragraph's display text across 8 "keystrokes"; the
            // other display paragraphs stay exact copies of stored (candidate
            // set stable). The edited paragraph drifts further from its origin
            // each keystroke, crossing tier boundaries.
            let editIndex = Int(rng.next() % UInt64(stored.order.count))
            var growing = stored.map[stored.order[editIndex]]!
            for _ in 0..<8 {
                growing += rng.next() % 3 == 0 ? " word" : "x"
                var display: [ParsedParagraph] = []
                for (i, id) in stored.order.enumerated() {
                    let t = i == editIndex ? growing : stored.map[id]!
                    display.append(ParsedParagraph(id: nil, text: t))
                }

                let cached = RenderFilter.restorePairs(
                    priorByIdStripped: stored.map, storedOrder: stored.order,
                    displayParsed: display, cache: cache)
                let uncached = RenderFilter.restorePairs(
                    priorByIdStripped: stored.map, storedOrder: stored.order,
                    displayParsed: display, cache: nil)
                assertSameShape(uncached, cached, storedIds: Set(stored.order),
                    seed: 0x570BE5 &+ UInt64(trial), label: "keystroke")
            }
        }
    }

    // MARK: - Eviction does not perturb selection

    /// Force the cache far past its `4 × paragraphCount` cap (so a wholesale
    /// clear fires mid-stream) and confirm output stays identical to no-cache.
    func test_evictionUnderPressure_staysIdentical() {
        var rng = SplitMix64(seed: 0xE71C7)
        let stored = Self.makeStored(count: 6, rng: &rng)   // cap = max(64, 24)=64
        let cache = RenderFilter.ShingleSetCache()
        // Drive 200 keystrokes with ever-changing needles → >64 distinct texts
        // accumulate → eviction fires repeatedly.
        var growing = "seed"
        for k in 0..<200 {
            growing += "\(k % 10)"
            var display: [ParsedParagraph] = []
            for id in stored.order {
                display.append(ParsedParagraph(id: nil, text: stored.map[id]!))
            }
            display.append(ParsedParagraph(id: nil, text: growing))
            let cached = RenderFilter.restorePairs(
                priorByIdStripped: stored.map, storedOrder: stored.order,
                displayParsed: display, cache: cache)
            let uncached = RenderFilter.restorePairs(
                priorByIdStripped: stored.map, storedOrder: stored.order,
                displayParsed: display, cache: nil)
            assertSameShape(uncached, cached, storedIds: Set(stored.order),
                seed: 0xE71C7, label: "evict k=\(k)")
        }
    }

    // MARK: - Comparison helper

    /// Both passes mint fresh ids non-deterministically (different `mintUnique`
    /// draws), so compare STRUCTURALLY: identical text order, identical
    /// reuse-vs-mint decision per slot, and — for reused ids — the SAME stored
    /// id (this is the load-bearing equivalence; minted ids only need to agree
    /// on "is a fresh mint").
    private func assertSameShape(
        _ a: [(id: String, text: String)],
        _ b: [(id: String, text: String)],
        storedIds: Set<String>, seed: UInt64, label: String
    ) {
        XCTAssertEqual(a.count, b.count, "[\(label) seed=\(seed)] paragraph count")
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.text, y.text, "[\(label) seed=\(seed)] text order")
            let xReused = storedIds.contains(x.id)
            let yReused = storedIds.contains(y.id)
            XCTAssertEqual(xReused, yReused,
                "[\(label) seed=\(seed)] reuse-vs-mint decision for \"\(x.text)\"")
            if xReused {
                XCTAssertEqual(x.id, y.id,
                    "[\(label) seed=\(seed)] reused stored id must be identical for \"\(x.text)\"")
            }
        }
        // The MULTISET of reused stored ids must match exactly (no id reused a
        // different number of times under the cache).
        let aReused = a.map(\.id).filter { storedIds.contains($0) }.sorted()
        let bReused = b.map(\.id).filter { storedIds.contains($0) }.sorted()
        XCTAssertEqual(aReused, bReused, "[\(label) seed=\(seed)] reused-id multiset")
    }
}
