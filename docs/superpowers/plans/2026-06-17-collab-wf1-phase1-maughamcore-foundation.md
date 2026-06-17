# Collaboration WF1 — Phase 1: MaughamCore Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the provenance + sub-paragraph quoted-span anchoring foundation in MaughamCore (and wire it into the Claude/MCP path) so later phases can render and author annotations from any source with sub-paragraph precision.

**Architecture:** Annotations stay paragraph-`¶id`-anchored; we add an *optional* `SpanAnchor` (quote + prefix + suffix + positional hint) stored on the op's `Provenance` and surfaced on the derived `Annotation`. A new stateless `SpanAnchorResolver` re-finds the span in the current paragraph display text via a tiered match (exact-normalized → fuzzy bigram window with context disambiguation → stale). An `AnnotationAuthor` provenance distinguishes Claude from named humans. The Claude/MCP tools gain an optional `quote` parameter that captures a span through the same resolver.

**Tech Stack:** Swift, `Packages/MaughamCore` (Foundation-only, shared Mac+phone), XCTest (`MaughamCoreTests`); the MCP tools live in the Mac target (`Maugham/MCP/Tools/`).

Spec: [`2026-06-17-wf1-human-reviewers-design.md`](../specs/2026-06-17-wf1-human-reviewers-design.md) (Components C, E, J). Overview: [`2026-06-17-collaboration-overview-design.md`](../specs/2026-06-17-collaboration-overview-design.md).

---

## File Structure

**Create (MaughamCore):**
- `Packages/MaughamCore/Sources/MaughamCore/SpanAnchor.swift` — the `SpanAnchor` value type + `AnnotationAuthor` value type.
- `Packages/MaughamCore/Sources/MaughamCore/SpanText.swift` — grapheme-based normalization for span matching.
- `Packages/MaughamCore/Sources/MaughamCore/SpanAnchorResolver.swift` — stateless tiered re-find + capture.
- `Packages/MaughamCore/Tests/MaughamCoreTests/SpanAnchorResolverTests.swift`
- `Packages/MaughamCore/Tests/MaughamCoreTests/SpanTextTests.swift`
- `Packages/MaughamCore/Tests/MaughamCoreTests/AnnotationProvenanceTests.swift`

**Modify (MaughamCore):**
- `Packages/MaughamCore/Sources/MaughamCore/Op.swift` — add optional span + author fields to `Op.Provenance` (flat fields, matching existing convention).
- `Packages/MaughamCore/Sources/MaughamCore/Annotation.swift` — add `span`, `resolvedSpanRange`, `author` to `Annotation`.
- `Packages/MaughamCore/Sources/MaughamCore/AnnotationDeriver.swift` — populate the new fields; compute span resolution + staleness.

**Modify (Mac target — Component J):**
- `Maugham/MCP/Tools/AnnotationCreationTools.swift` — optional `quote` param on `add_comment`/`add_suggested_change`/`add_query`; capture span; stamp `.claude` author.
- `Maugham/MCP/MCPError.swift` — add `spanNotFound` factory.
- `Maugham/OpLog/Document+Annotations.swift` + `Maugham/MCP/Tools/AnnotationToolHelpers.swift` — thread `span` + `author` into `addAnnotation`.
- Tests: `MaughamTests/MCP/AnnotationCreationToolsTests.swift` (extend; confirm exact existing path at execution).

**Conventions:** XCTest, `@testable import MaughamCore`, `func test_*()`. Build/test MaughamCore via the Mac scheme (the package is built as part of it): `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` — or the package directly with `swift test` from `Packages/MaughamCore` for fast iteration on Core-only tasks.

---

## Task 1: `SpanAnchor` and `AnnotationAuthor` value types

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/SpanAnchor.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/AnnotationProvenanceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MaughamCore

final class AnnotationProvenanceTests: XCTestCase {
    func test_spanAnchor_roundTripsThroughJSON() throws {
        let anchor = SpanAnchor(quote: "habit alone", prefix: "as though the ", suffix: " could summon", posHint: 31)
        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(SpanAnchor.self, from: data)
        XCTAssertEqual(decoded, anchor)
    }

    func test_annotationAuthor_roundTripsThroughJSON() throws {
        let author = AnnotationAuthor(sourceKind: .human, displayName: "Marian", collaboratorId: "c-123")
        let data = try JSONEncoder().encode(author)
        let decoded = try JSONDecoder().decode(AnnotationAuthor.self, from: data)
        XCTAssertEqual(decoded, author)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/MaughamCore && swift test --filter AnnotationProvenanceTests`
Expected: FAIL — `cannot find 'SpanAnchor' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// SpanAnchor.swift
import Foundation

/// A sub-paragraph anchor: the quoted span plus surrounding context for robust,
/// stateless re-find. `posHint` is a grapheme offset captured at creation, used
/// only as a tiebreaker when the quote/context are ambiguous.
public struct SpanAnchor: Codable, Equatable, Sendable {
    public let quote: String
    public let prefix: String
    public let suffix: String
    public let posHint: Int

    public init(quote: String, prefix: String, suffix: String, posHint: Int) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.posHint = posHint
    }
}

/// Who created an annotation. The annotation *kind* is source-agnostic;
/// provenance is the authority for "who".
public struct AnnotationAuthor: Codable, Equatable, Sendable {
    public enum SourceKind: String, Codable, Equatable, Sendable {
        case claude
        case human
    }
    public let sourceKind: SourceKind
    public let displayName: String
    public let collaboratorId: String?

    public init(sourceKind: SourceKind, displayName: String, collaboratorId: String? = nil) {
        self.sourceKind = sourceKind
        self.displayName = displayName
        self.collaboratorId = collaboratorId
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/MaughamCore && swift test --filter AnnotationProvenanceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/SpanAnchor.swift Packages/MaughamCore/Tests/MaughamCoreTests/AnnotationProvenanceTests.swift
git commit -m "feat(core): SpanAnchor + AnnotationAuthor value types"
```

---

## Task 2: Span text normalization (`SpanText`)

Normalize smart-typography drift so a quote captured before Maugham curled the quotes still matches. Grapheme-based.

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/SpanText.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/SpanTextTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MaughamCore

final class SpanTextTests: XCTestCase {
    func test_normalize_canonicalizesSmartQuotesAndDashes() {
        XCTAssertEqual(SpanText.normalize("don\u{2019}t \u{201C}go\u{201D}"), "don't \"go\"")
        XCTAssertEqual(SpanText.normalize("a \u{2014} b"), "a - b")        // em dash
        XCTAssertEqual(SpanText.normalize("a \u{2013} b"), "a - b")        // en dash
    }

    func test_normalize_collapsesWhitespaceRuns() {
        XCTAssertEqual(SpanText.normalize("for   the\texercise"), "for the exercise")
    }

    func test_normalize_isIdempotent() {
        let once = SpanText.normalize("the  \u{201C}cat\u{201D}")
        XCTAssertEqual(SpanText.normalize(once), once)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/MaughamCore && swift test --filter SpanTextTests`
Expected: FAIL — `cannot find 'SpanText' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// SpanText.swift
import Foundation

/// Canonicalization for span matching. Smart-typography-insensitive and
/// whitespace-insensitive, so a span captured pre-curl still matches post-curl.
public enum SpanText {
    public static func normalize(_ s: String) -> String {
        var out = s
        // Quotes
        out = out.replacingOccurrences(of: "\u{2018}", with: "'")
                 .replacingOccurrences(of: "\u{2019}", with: "'")
                 .replacingOccurrences(of: "\u{201C}", with: "\"")
                 .replacingOccurrences(of: "\u{201D}", with: "\"")
        // Dashes
        out = out.replacingOccurrences(of: "\u{2014}", with: "-")
                 .replacingOccurrences(of: "\u{2013}", with: "-")
        // Ellipsis
        out = out.replacingOccurrences(of: "\u{2026}", with: "...")
        // Whitespace runs -> single space, trimmed
        let collapsed = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/MaughamCore && swift test --filter SpanTextTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/SpanText.swift Packages/MaughamCore/Tests/MaughamCoreTests/SpanTextTests.swift
git commit -m "feat(core): smart-typography-insensitive span normalization"
```

---

## Task 3: `SpanAnchorResolver` — exact + multi-occurrence disambiguation

The resolver returns a grapheme-offset range into the (raw) paragraph text, or `nil` (stale). This task handles the exact-normalized tier and disambiguation by prefix/suffix context with `posHint` as tiebreaker.

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/SpanAnchorResolver.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/SpanAnchorResolverTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MaughamCore

final class SpanAnchorResolverTests: XCTestCase {
    // Helper: resolve and return the matched substring of `text`, or nil.
    private func matched(_ anchor: SpanAnchor, in text: String) -> String? {
        guard let r = SpanAnchorResolver.resolve(anchor: anchor, in: text) else { return nil }
        let chars = Array(text)
        return String(chars[r])
    }

    func test_exactSingleOccurrence_matches() {
        let text = "She told herself it was for the exercise, half true."
        let anchor = SpanAnchor(quote: "for the exercise", prefix: "it was ", suffix: ", half", posHint: 24)
        XCTAssertEqual(matched(anchor, in: text), "for the exercise")
    }

    func test_repeatedSpan_otherOccurrenceDeleted_usesContext() {
        // "said" appears twice; comment was on the 2nd (after "she").
        let text = "he said. she said again."
        let anchor = SpanAnchor(quote: "said", prefix: "she ", suffix: " again", posHint: 11)
        let r = SpanAnchorResolver.resolve(anchor: anchor, in: text)!
        XCTAssertEqual(r.lowerBound, 13) // the 2nd "said" (index 13 in "he said. she said again.")
    }

    func test_quoteAbsent_returnsNilStale() {
        let text = "completely different sentence."
        let anchor = SpanAnchor(quote: "for the exercise", prefix: "", suffix: "", posHint: 0)
        XCTAssertNil(SpanAnchorResolver.resolve(anchor: anchor, in: text))
    }

    func test_emptyQuote_isParagraphLevel_returnsNil() {
        // Empty span == paragraph-level: resolver returns nil (no inline highlight).
        let anchor = SpanAnchor(quote: "", prefix: "", suffix: "", posHint: 0)
        XCTAssertNil(SpanAnchorResolver.resolve(anchor: anchor, in: "anything"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/MaughamCore && swift test --filter SpanAnchorResolverTests`
Expected: FAIL — `cannot find 'SpanAnchorResolver' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// SpanAnchorResolver.swift
import Foundation

/// Stateless re-find of a SpanAnchor within a paragraph's *display* text.
/// Recomputed on every derive/render; never persisted-and-mutated.
public enum SpanAnchorResolver {
    /// Returns a grapheme-offset range into `text`, or nil if the span is lost (stale).
    public static func resolve(anchor: SpanAnchor, in text: String) -> Range<Int>? {
        guard !anchor.quote.isEmpty else { return nil } // empty == paragraph-level

        let chars = Array(text)
        let nText = SpanText.normalize(text)
        let nChars = Array(nText)
        let nQuote = Array(SpanText.normalize(anchor.quote))
        guard !nQuote.isEmpty else { return nil }

        // Tier 1: exact (normalized) occurrences.
        let occ = occurrences(of: nQuote, in: nChars)
        if !occ.isEmpty {
            let best = disambiguate(occ, anchor: anchor, normalized: nChars)
            return mapNormalizedRangeToRaw(best, normalized: nChars, raw: chars, text: text, nText: nText, quote: anchor.quote)
        }
        return nil // Tier 2 (fuzzy) added in Task 4.
    }

    // MARK: - helpers

    static func occurrences(of needle: [Character], in hay: [Character]) -> [Range<Int>] {
        guard needle.count <= hay.count, !needle.isEmpty else { return [] }
        var result: [Range<Int>] = []
        for start in 0...(hay.count - needle.count) {
            if Array(hay[start..<start+needle.count]) == needle {
                result.append(start..<start+needle.count)
            }
        }
        return result
    }

    /// Pick the occurrence whose surrounding context best matches prefix/suffix,
    /// breaking ties by proximity to posHint.
    static func disambiguate(_ occ: [Range<Int>], anchor: SpanAnchor, normalized: [Character]) -> Range<Int> {
        if occ.count == 1 { return occ[0] }
        let nPrefix = Array(SpanText.normalize(anchor.prefix))
        let nSuffix = Array(SpanText.normalize(anchor.suffix))
        func contextScore(_ r: Range<Int>) -> Int {
            var s = 0
            // matching trailing chars of prefix immediately before r.lowerBound
            var i = r.lowerBound - 1, j = nPrefix.count - 1
            while i >= 0 && j >= 0 && normalized[i] == nPrefix[j] { s += 1; i -= 1; j -= 1 }
            // matching leading chars of suffix immediately after r.upperBound
            var k = r.upperBound, m = 0
            while k < normalized.count && m < nSuffix.count && normalized[k] == nSuffix[m] { s += 1; k += 1; m += 1 }
            return s
        }
        return occ.max(by: { a, b in
            let sa = contextScore(a), sb = contextScore(b)
            if sa != sb { return sa < sb }
            return abs(a.lowerBound - anchor.posHint) > abs(b.lowerBound - anchor.posHint)
        })!
    }

    /// Map a range found in normalized space back to raw grapheme offsets.
    /// Minimal v1: if normalization didn't change length (common case), ranges align;
    /// otherwise locate the raw quote occurrence nearest the normalized index.
    static func mapNormalizedRangeToRaw(_ r: Range<Int>, normalized: [Character], raw: [Character], text: String, nText: String, quote: String) -> Range<Int>? {
        if normalized.count == raw.count { return r }
        // Fallback: find raw occurrences of the (un-normalized) quote and pick nearest.
        let rawQuote = Array(quote)
        let rawOcc = occurrences(of: rawQuote, in: raw)
        guard let nearest = rawOcc.min(by: { abs($0.lowerBound - r.lowerBound) < abs($1.lowerBound - r.lowerBound) }) else {
            return nil
        }
        return nearest
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Fix the illustrative test name to `test_quoteAbsent_returnsNilStale`. Run: `cd Packages/MaughamCore && swift test --filter SpanAnchorResolverTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/SpanAnchorResolver.swift Packages/MaughamCore/Tests/MaughamCoreTests/SpanAnchorResolverTests.swift
git commit -m "feat(core): SpanAnchorResolver exact tier + context disambiguation"
```

---

## Task 4: `SpanAnchorResolver` — fuzzy tier (lenient, edited spans keep anchor)

Add the fuzzy window tier reusing `ShingleMatcher.bigramOverlap`, so incidental edits inside the span keep it anchored; only a genuine rewrite goes stale.

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/SpanAnchorResolver.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/SpanAnchorResolverTests.swift` (add cases)

- [ ] **Step 1: Write the failing test**

```swift
extension SpanAnchorResolverTests {
    func test_minorEditInsideSpan_stillAnchors() {
        // captured "for the exercise"; author fixed to "for the excercise" -> "for the exercise" (typo round-trip)
        let text = "it was for the excercise, half true."   // note misspelling in current text
        let anchor = SpanAnchor(quote: "for the exercise", prefix: "was ", suffix: ", half", posHint: 7)
        XCTAssertNotNil(SpanAnchorResolver.resolve(anchor: anchor, in: text))
    }

    func test_spanFullyRewritten_goesStale() {
        let text = "it was a kind of penance, half true."
        let anchor = SpanAnchor(quote: "for the exercise", prefix: "was ", suffix: ", half", posHint: 7)
        XCTAssertNil(SpanAnchorResolver.resolve(anchor: anchor, in: text))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/MaughamCore && swift test --filter SpanAnchorResolverTests/test_minorEditInsideSpan_stillAnchors`
Expected: FAIL (currently returns nil — no fuzzy tier).

- [ ] **Step 3: Write minimal implementation**

Replace the `return nil // Tier 2 (fuzzy) added in Task 4.` line with a call to the fuzzy tier, and add the method:

```swift
        // Tier 2: fuzzy window (lenient). Reuse ShingleMatcher bigram overlap.
        if let fuzzy = fuzzyWindow(quote: nQuote, in: nChars, anchor: anchor) {
            return mapNormalizedRangeToRaw(fuzzy, normalized: nChars, raw: chars, text: text, nText: nText, quote: anchor.quote)
        }
        return nil
    }

    static let fuzzyThreshold = 0.6
    static let fuzzyMargin = 0.1

    /// Slide windows around the quote's length; pick the best bigram-overlap window
    /// that clears threshold AND beats the runner-up by the margin.
    static func fuzzyWindow(quote: [Character], in hay: [Character], anchor: SpanAnchor) -> Range<Int>? {
        guard !quote.isEmpty, hay.count >= 2 else { return nil }
        let qBigrams = ShingleMatcher.bigrams(of: String(quote))
        let qLen = quote.count
        // Consider window lengths near the quote length to tolerate insert/delete.
        let lengths = Set([qLen, max(1, qLen - 1), qLen + 1, max(1, qLen - 2), qLen + 2]).sorted()
        var scored: [(range: Range<Int>, score: Double)] = []
        for len in lengths where len <= hay.count {
            for start in 0...(hay.count - len) {
                let window = String(hay[start..<start+len])
                let score = ShingleMatcher.bigramOverlap(ShingleMatcher.bigrams(of: window), qBigrams)
                scored.append((start..<start+len, score))
            }
        }
        let ranked = scored.sorted { $0.score > $1.score }
        guard let best = ranked.first, best.score >= fuzzyThreshold else { return nil }
        // Margin against the best *non-overlapping* runner-up.
        if let runnerUp = ranked.dropFirst().first(where: { !$0.range.overlaps(best.range) }),
           best.score - runnerUp.score < fuzzyMargin {
            // ambiguous — fall back to posHint proximity among near-best windows
            let nearBest = ranked.filter { best.score - $0.score < fuzzyMargin }
            return nearBest.min(by: { abs($0.range.lowerBound - anchor.posHint) < abs($1.range.lowerBound - anchor.posHint) })?.range
        }
        return best.range
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/MaughamCore && swift test --filter SpanAnchorResolverTests`
Expected: PASS (all cases, including `test_spanFullyRewritten_goesStale`). If `test_repeatedSpan` or exact cases regress, the exact tier still runs first (fuzzy only on exact-miss) — verify exact tier precedence is intact.

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/SpanAnchorResolver.swift Packages/MaughamCore/Tests/MaughamCoreTests/SpanAnchorResolverTests.swift
git commit -m "feat(core): SpanAnchorResolver lenient fuzzy tier (bigram window)"
```

---

## Task 5: `SpanAnchorResolver.capture` — build an anchor from a selection

Given the display text and a selected grapheme range, produce a `SpanAnchor` with context.

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/SpanAnchorResolver.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/SpanAnchorResolverTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
extension SpanAnchorResolverTests {
    func test_capture_thenResolve_roundTrips() {
        let text = "She told herself it was for the exercise, half true."
        let chars = Array(text)
        let lo = text.distance(from: text.startIndex, to: text.range(of: "for the exercise")!.lowerBound)
        let anchor = SpanAnchorResolver.capture(in: text, range: lo..<(lo+16), contextLength: 8)
        XCTAssertEqual(anchor.quote, "for the exercise")
        XCTAssertEqual(anchor.posHint, lo)
        XCTAssertFalse(anchor.prefix.isEmpty)
        // and it resolves back to the same place
        let r = SpanAnchorResolver.resolve(anchor: anchor, in: text)!
        XCTAssertEqual(String(chars[r]), "for the exercise")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/MaughamCore && swift test --filter SpanAnchorResolverTests/test_capture_thenResolve_roundTrips`
Expected: FAIL — `type 'SpanAnchorResolver' has no member 'capture'`.

- [ ] **Step 3: Write minimal implementation**

```swift
    /// Build an anchor for a selected grapheme range in `text`.
    public static func capture(in text: String, range: Range<Int>, contextLength: Int = 24) -> SpanAnchor {
        let chars = Array(text)
        let lo = max(0, min(range.lowerBound, chars.count))
        let hi = max(lo, min(range.upperBound, chars.count))
        let quote = String(chars[lo..<hi])
        let preLo = max(0, lo - contextLength)
        let sufHi = min(chars.count, hi + contextLength)
        let prefix = String(chars[preLo..<lo])
        let suffix = String(chars[hi..<sufHi])
        return SpanAnchor(quote: quote, prefix: prefix, suffix: suffix, posHint: lo)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/MaughamCore && swift test --filter SpanAnchorResolverTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/SpanAnchorResolver.swift Packages/MaughamCore/Tests/MaughamCoreTests/SpanAnchorResolverTests.swift
git commit -m "feat(core): SpanAnchorResolver.capture (selection -> anchor)"
```

---

## Task 6: Add author + span fields to `Op.Provenance`

Persist the new data on the op. Match the existing flat-optional-field convention with snake_case coding keys.

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Op.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/AnnotationProvenanceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
extension AnnotationProvenanceTests {
    func test_provenance_carriesAuthorAndSpan_andLegacyDecodesNil() throws {
        let prov = Op.Provenance(
            annotationBody: "undersells her",
            authorSourceKind: "human", authorDisplayName: "Marian", authorCollaboratorId: "c-1",
            spanQuote: "for the exercise", spanPrefix: "was ", spanSuffix: ", half", spanPosHint: 7)
        let data = try JSONEncoder().encode(prov)
        let decoded = try JSONDecoder().decode(Op.Provenance.self, from: data)
        XCTAssertEqual(decoded.authorSourceKind, "human")
        XCTAssertEqual(decoded.spanQuote, "for the exercise")
        XCTAssertEqual(decoded.spanPosHint, 7)

        // Legacy op JSON without the new keys decodes to nil (no migration).
        let legacy = #"{"annotation_body":"hi"}"#.data(using: .utf8)!
        let legacyDecoded = try JSONDecoder().decode(Op.Provenance.self, from: legacy)
        XCTAssertNil(legacyDecoded.authorSourceKind)
        XCTAssertNil(legacyDecoded.spanQuote)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/MaughamCore && swift test --filter AnnotationProvenanceTests/test_provenance_carriesAuthorAndSpan_andLegacyDecodesNil`
Expected: FAIL — `extra argument 'authorSourceKind' in call`.

- [ ] **Step 3: Write minimal implementation**

In `Op.Provenance`, add stored properties (after `userResponse`):

```swift
        // Annotation author provenance (WF1). sourceKind is "claude" | "human".
        public let authorSourceKind: String?
        public let authorDisplayName: String?
        public let authorCollaboratorId: String?

        // Sub-paragraph span anchor (WF1). All-nil == paragraph-level.
        public let spanQuote: String?
        public let spanPrefix: String?
        public let spanSuffix: String?
        public let spanPosHint: Int?
```

Add to `CodingKeys`:

```swift
            case authorSourceKind = "author_source_kind"
            case authorDisplayName = "author_display_name"
            case authorCollaboratorId = "author_collaborator_id"
            case spanQuote = "span_quote"
            case spanPrefix = "span_prefix"
            case spanSuffix = "span_suffix"
            case spanPosHint = "span_pos_hint"
```

Extend the `init` with the new params (all defaulting `nil`, appended so existing call-sites still compile):

```swift
        public init(
            sessionId: String? = nil, prompt: String? = nil,
            toolArgs: String? = nil, sourceCheckpoint: String? = nil,
            synthesisSource: SynthesisSource? = nil, orphanRecoveryMethod: String? = nil,
            annotationBody: String? = nil, sourceAnnotationId: String? = nil,
            userResponse: String? = nil,
            taskId: String? = nil, taskBody: String? = nil,
            taskStatus: String? = nil, taskPriority: Double? = nil,
            taskParentId: String? = nil, taskKind: String? = nil,
            appVersion: String? = nil, osVersion: String? = nil,
            authorSourceKind: String? = nil, authorDisplayName: String? = nil,
            authorCollaboratorId: String? = nil,
            spanQuote: String? = nil, spanPrefix: String? = nil,
            spanSuffix: String? = nil, spanPosHint: Int? = nil
        ) {
            // ... existing assignments ...
            self.authorSourceKind = authorSourceKind
            self.authorDisplayName = authorDisplayName
            self.authorCollaboratorId = authorCollaboratorId
            self.spanQuote = spanQuote
            self.spanPrefix = spanPrefix
            self.spanSuffix = spanSuffix
            self.spanPosHint = spanPosHint
        }
```

> Decoding: the synthesized `Codable` with all-optional new keys decodes missing keys as `nil` automatically — confirm `Op.Provenance` uses the synthesized `init(from:)` (it does today). No custom decoder change needed.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/MaughamCore && swift test --filter AnnotationProvenanceTests`
Then full Core suite to catch call-site breaks: `cd Packages/MaughamCore && swift test`
Expected: PASS; no other Core test regresses (new params are defaulted).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/Op.swift Packages/MaughamCore/Tests/MaughamCoreTests/AnnotationProvenanceTests.swift
git commit -m "feat(core): author + span fields on Op.Provenance (additive, legacy-nil)"
```

---

## Task 7: Surface author + resolved span on `Annotation` via the deriver

The derived `Annotation` gains `author`, `span`, and a computed `resolvedSpanRange`; `isStale` accounts for a lost span.

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Annotation.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/AnnotationDeriver.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/AnnotationProvenanceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
extension AnnotationProvenanceTests {
    private func commentOp(opId: String, pid: String, span: SpanAnchor?, author: AnnotationAuthor) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 1), device: "d", session: "s",
           kind: .claudeComment,
           changes: [],
           provenance: Op.Provenance(
               annotationBody: "note", 
               authorSourceKind: author.sourceKind.rawValue,
               authorDisplayName: author.displayName,
               authorCollaboratorId: author.collaboratorId,
               spanQuote: span?.quote, spanPrefix: span?.prefix,
               spanSuffix: span?.suffix, spanPosHint: span?.posHint))
    }

    func test_deriver_surfacesAuthorAndResolvesSpan() {
        let para = "She told herself it was for the exercise, half true."
        let span = SpanAnchor(quote: "for the exercise", prefix: "was ", suffix: ", half", posHint: 24)
        // op.changes carries the paragraph id link; AnnotationDeriver reads paragraph_id from the change.
        var op = commentOp(opId: "01AAAA", pid: "ab12", span: span, author: .init(sourceKind: .human, displayName: "Marian", collaboratorId: "c-1"))
        op = Op(opId: op.opId, docId: op.docId, at: op.at, device: op.device, session: op.session,
                kind: op.kind,
                changes: [Op.ParagraphChange(paragraphId: "ab12", prior: nil, next: "note")],
                provenance: op.provenance)
        let anns = AnnotationDeriver.derive(ops: [op], paragraphs: ["ab12": para])
        let a = anns.first!
        XCTAssertEqual(a.author?.sourceKind, .human)
        XCTAssertEqual(a.author?.displayName, "Marian")
        XCTAssertEqual(a.span?.quote, "for the exercise")
        XCTAssertNotNil(a.resolvedSpanRange)
        XCTAssertFalse(a.isStale)
    }

    func test_deriver_lostSpan_marksStale() {
        let para = "completely rewritten paragraph."
        let span = SpanAnchor(quote: "for the exercise", prefix: "was ", suffix: ", half", posHint: 24)
        var op = commentOp(opId: "01BBBB", pid: "ab12", span: span, author: .init(sourceKind: .claude, displayName: "Claude"))
        op = Op(opId: op.opId, docId: op.docId, at: op.at, device: op.device, session: op.session,
                kind: op.kind,
                changes: [Op.ParagraphChange(paragraphId: "ab12", prior: nil, next: "note")],
                provenance: op.provenance)
        let a = AnnotationDeriver.derive(ops: [op], paragraphs: ["ab12": para]).first!
        XCTAssertNil(a.resolvedSpanRange)
        XCTAssertTrue(a.isStale)
    }
}
```

> The exact way the deriver reads `paragraphId` and `body` from an annotation op must match its current implementation — confirm whether it reads `provenance.annotationBody` + the change's `paragraphId`, and mirror that. Adjust the op-construction in the test to match the deriver's expected shape.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/MaughamCore && swift test --filter AnnotationProvenanceTests/test_deriver_surfacesAuthorAndResolvesSpan`
Expected: FAIL — `value of type 'Annotation' has no member 'author'`.

- [ ] **Step 3: Write minimal implementation**

In `Annotation`, add stored properties + extend the initializer:

```swift
    public let author: AnnotationAuthor?
    public let span: SpanAnchor?
    public let resolvedSpanRange: Range<Int>?   // nil == paragraph-level or lost
```

(Append these as defaulted-nil-friendly params to `Annotation.init` — but since `Annotation.init` lists all fields explicitly, update every construction site in `AnnotationDeriver`.)

In `AnnotationDeriver.derive`, when building each `Annotation`:
1. Read author: `let author = prov.authorSourceKind.flatMap { AnnotationAuthor.SourceKind(rawValue: $0) }.map { AnnotationAuthor(sourceKind: $0, displayName: prov.authorDisplayName ?? "", collaboratorId: prov.authorCollaboratorId) }`
2. Build span: `let span = prov.spanQuote.map { SpanAnchor(quote: $0, prefix: prov.spanPrefix ?? "", suffix: prov.spanSuffix ?? "", posHint: prov.spanPosHint ?? 0) }`
3. Resolve + staleness:
```swift
let resolved: Range<Int>?
if let span, let pid = paragraphId, let text = paragraphs[pid] {
    resolved = SpanAnchorResolver.resolve(anchor: span, in: text)
} else { resolved = nil }
let spanIsStale = (span != nil && resolved == nil)
let isStale = existingStaleCheck || spanIsStale   // OR into the current staleness rule
```
4. Pass `author: author, span: span, resolvedSpanRange: resolved` into the `Annotation(...)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/MaughamCore && swift test --filter AnnotationProvenanceTests`
Then: `cd Packages/MaughamCore && swift test` (full Core suite; fix any `Annotation(...)` call-site that now needs the new args).
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/Annotation.swift Packages/MaughamCore/Sources/MaughamCore/AnnotationDeriver.swift Packages/MaughamCore/Tests/MaughamCoreTests/AnnotationProvenanceTests.swift
git commit -m "feat(core): derive author + resolved span on Annotation; span-lost => stale"
```

---

## Task 8: Component J — Claude/MCP path (provenance + optional `quote`)

Stamp `.claude` provenance and let Claude anchor a sub-paragraph span by quoting it. No new tools — params + one error envelope.

**Files:**
- Modify: `Maugham/MCP/MCPError.swift` — add `spanNotFound` factory.
- Modify: `Maugham/MCP/Tools/AnnotationCreationTools.swift` — optional `quote` on the three tools; capture span; stamp `.claude`.
- Modify: `Maugham/OpLog/Document+Annotations.swift` + `Maugham/MCP/Tools/AnnotationToolHelpers.swift` — thread `span` + `author` into `addAnnotation`.
- Test: `MaughamTests/MCP/AnnotationCreationToolsTests.swift` (confirm exact path/name at execution).

- [ ] **Step 1: Write the failing test**

```swift
// In the MCP annotation tool test file (Mac target).
func test_addComment_withQuote_capturesSpanAndStampsClaude() async throws {
    // Arrange a registry/doc whose paragraph "ab12" contains the quote.
    // (Mirror the existing add_comment test's setup helpers.)
    let params = AddCommentTool.Params(project_id: pid, document_id: did, paragraph_id: "ab12",
                                       body: "tighten this", quote: "for the exercise")
    let data = try await AddCommentTool.handle(paramsJSON: try JSONEncoder().encode(params), registry: registry)
    // Assert: the emitted annotation op carries author_source_kind == "claude"
    //         and span_quote == "for the exercise".
    let ann = /* fetch derived annotation by returned id */
    XCTAssertEqual(ann.author?.sourceKind, .claude)
    XCTAssertEqual(ann.span?.quote, "for the exercise")
}

func test_addComment_withMissingQuote_returnsSpanNotFound() async throws {
    let params = AddCommentTool.Params(project_id: pid, document_id: did, paragraph_id: "ab12",
                                       body: "x", quote: "text that is not present")
    do {
        _ = try await AddCommentTool.handle(paramsJSON: try JSONEncoder().encode(params), registry: registry)
        XCTFail("expected span_not_found")
    } catch let MCPError.toolError(payload) {
        XCTAssertEqual(payload.error, "span_not_found")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the Mac scheme test filter for the new tests.
Expected: FAIL — `Params` has no `quote`; `spanNotFound` undefined.

- [ ] **Step 3: Write minimal implementation**

(a) `MCPError.swift` factory:

```swift
    public static func spanNotFound(paragraphId: String, quote: String) -> MCPError {
        .toolError(payload: .init(
            error: "span_not_found",
            message: "The quoted span was not found in paragraph '\(paragraphId)'.",
            hint: "Re-read the paragraph with read_document and quote an exact phrase from it, or omit `quote` to anchor the whole paragraph.",
            fields: ["paragraph_id": .string(paragraphId), "quote": .string(quote)]))
    }
```

(b) In `AnnotationCreationTools.swift`, add `public let quote: String?` to the `Params` of `AddCommentTool`, `AddSuggestedChangeTool`, `AddQueryTool`, and add `"quote":{"type":"string"}` to each `inputSchemaJSON` (NOT in `required`). In each `handle`, after resolving the paragraph text (the display text of `paragraph_id`), compute the span:

```swift
var span: SpanAnchor? = nil
if let q = params.quote, !q.isEmpty {
    let paraText = /* display text for params.paragraph_id, via the same path that captures priorText */
    guard let r = SpanAnchorResolver.resolve(anchor: SpanAnchor(quote: q, prefix: "", suffix: "", posHint: 0), in: paraText) else {
        throw MCPError.spanNotFound(paragraphId: params.paragraph_id, quote: q)
    }
    span = SpanAnchorResolver.capture(in: paraText, range: r)
}
let author = AnnotationAuthor(sourceKind: .claude, displayName: "Claude")
```

(c) Thread `span` + `author` through `addAnnotation` (extend its signature in `Document+Annotations.swift` with defaulted `span: SpanAnchor? = nil, author: AnnotationAuthor? = nil`, and write them into the `Op.Provenance` it builds: `authorSourceKind: author?.sourceKind.rawValue`, `spanQuote: span?.quote`, etc.). Stamp `.claude` author on *all* MCP annotation emits, even when `quote` is absent.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (filter to the annotation tool tests for speed).
Expected: PASS. Also run the MCP tools-list/catalog tests — they should be **unchanged** (no new tool added; only param schemas changed). If a schema-snapshot test exists, update its expectation for the three tools.

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/MCPError.swift Maugham/MCP/Tools/AnnotationCreationTools.swift Maugham/OpLog/Document+Annotations.swift Maugham/MCP/Tools/AnnotationToolHelpers.swift MaughamTests/MCP/AnnotationCreationToolsTests.swift
git commit -m "feat(mcp): optional quote span anchor + claude provenance on annotation tools"
```

---

## Task 9: Cross-surface + full-suite verification

**Files:** none new — verification gate.

- [ ] **Step 1: Run the full MaughamCore suite**

Run: `cd Packages/MaughamCore && swift test`
Expected: all green.

- [ ] **Step 2: Run the Mac scheme suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: all green; annotation/op coder round-trip and MCP tests pass.

- [ ] **Step 3: Run the phone scheme suite (cross-surface parity)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: green — the phone consumes the same `Annotation` fields; provenance/span decode identically (it doesn't author). If a phone reach-around grep tripwire fires, the phone must use the shared `SpanAnchorResolver`/`AnnotationDeriver`, not a reimplementation.

- [ ] **Step 4: Commit any test-expectation updates**

```bash
git add -A
git commit -m "test(collab): WF1 phase 1 cross-surface verification green"
```

---

## Self-Review Notes (resolved)

- **Spec coverage:** Component C (provenance) → Tasks 6,7,8. Component E (anchoring engine) → Tasks 1–5,7. Component J (MCP) → Task 8. The spike (Task 0 in the spec) is a separate investigation, not code — run it before Phase 2 (identity), which is where its result is consumed; Phase 1 needs no iCloud.
- **Deferred to later phases (correctly out of Phase 1):** membrane, identity, authoring UI, review render, pane, phone authoring (none here — Phase 1 is pure data+logic).
- **Type consistency:** `SpanAnchor`(quote/prefix/suffix/posHint), `AnnotationAuthor`(sourceKind/displayName/collaboratorId), `Op.Provenance` flat fields `author*`/`span*`, `Annotation.author/span/resolvedSpanRange`, `SpanAnchorResolver.resolve(anchor:in:)`/`.capture(in:range:contextLength:)` — names consistent across tasks.
- **Known execution-time confirmations:** (1) the exact shape the `AnnotationDeriver` uses to read an annotation op's paragraph id + body (mirror it in Task 7's test); (2) the exact existing MCP annotation-tool test file path/helpers (Task 8); (3) how the MCP handler fetches a paragraph's display text to feed the resolver (reuse the priorText-capture path). These are wiring confirmations, not design gaps.

## Open follow-ons (NOT this phase)

- Manual cross-paragraph "Find moved text…" / "Reattach" — these are UI (Phase 3/4); the engine they call (`resolve`/doc-wide search) can reuse `SpanAnchorResolver`.
- The `mapNormalizedRangeToRaw` fallback is intentionally simple; if normalization-length-change cases prove common in real prose, revisit with an index map. Covered by tests at the common (length-preserving) path.
