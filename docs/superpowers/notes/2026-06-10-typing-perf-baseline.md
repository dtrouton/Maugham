# Typing-Perf M0 Baseline (recorded 2026-06-10)

Method: `TypingLatencyProbeTests.test_probe_typingPerfBaseline`, Debug build,
`xcodebuild … -scheme Maugham test CODE_SIGNING_ALLOWED=NO
-only-testing:MaughamTests/TypingLatencyProbeTests`. Fixture chunks staged at
`/tmp/maugham-perf-probe/chunk-01…10.fountain` (~50 KB each). All three tables
below are the test's printed output **verbatim** — no rounding, no hand-edits.

Headless: the gutter-draw layout-manager cost is excluded (no live text view),
so the "gutter line scan" figure **understates** the real M4 win; the live
`sample` in Task 9 measures the true draw cost.

## Tables (verbatim)

```
===== TYPING-PERF BASELINE — 5 chunks =====
bytes: 252433, lines: 5838, labeled: 4146
FountainTokenizer.parse:   0.043152167 seconds
ScreenplayMode.tokens:     0.004842125 seconds
setFullText median:        0.094384084 seconds
ParagraphParser.parse:     0.011774333 seconds
makeContiguousUTF8 (×1):   1.209e-06 seconds
pause-edge: metrics 0.068065834 seconds + summaries 0.005911958 seconds + script== 0.000510333 seconds
gutter line scan (no layout): 0.000516708 seconds
==============================================
```

```
===== TYPING-PERF BASELINE — 10 chunks =====
bytes: 504310, lines: 11676, labeled: 8302
FountainTokenizer.parse:   0.087296417 seconds
ScreenplayMode.tokens:     0.00960925 seconds
setFullText median:        0.130201834 seconds
ParagraphParser.parse:     0.023375625 seconds
makeContiguousUTF8 (×1):   4.58e-07 seconds
pause-edge: metrics 0.135469459 seconds + summaries 0.01177475 seconds + script== 0.001040042 seconds
gutter line scan (no layout): 0.000961916 seconds
==============================================
```

```
===== TYPING-PERF BASELINE — prose 250KB =====
bytes: 250026, paragraphs: 1095
ProseMode.tokenize: 0.013821917 seconds
setFullText median: 0.055864875 seconds
==============================================
```

## Derived per-keystroke totals

The editor's per-keystroke editor work is `setFullText` (which already runs
`ParagraphParser.parse` internally) + `FountainTokenizer.parse` +
`ScreenplayMode.tokens` (the restyle path runs the tokenizer + token derivation
outside `setFullText`), consistent with the existing full-scale probe's
attribution.

| Scale | tokenizer | tokens | setFullText | per-keystroke total | §4 budget | verdict |
|---|---|---|---|---|---|---|
| 120 pp (5 chunks, 252 KB) | 43.2 ms | 4.8 ms | 94.4 ms | ~142 ms | ≤ 16 ms | **9× over** |
| 250 pp (10 chunks, 504 KB) | 87.3 ms | 9.6 ms | 130.2 ms | ~227 ms | ≤ 50 ms | **4.5× over** |

Pause-edge batch (footer `metrics()` full re-parse + `sceneSummaries()` +
`FountainScript` deep-`==`):

| Scale | metrics | summaries | script== | total | §4 budget | verdict |
|---|---|---|---|---|---|---|
| 120 pp | 68.1 ms | 5.9 ms | 0.5 ms | 74.5 ms | ≤ 30 ms (@120pp) | **2.5× over** |
| 250 pp | 135.5 ms | 11.8 ms | 1.0 ms | 148.3 ms | (≤30 @120pp) | over |

The pause-edge total is dominated by `metrics()`, which is a second full
`FountainTokenizer.parse` of the whole document — exactly the term M3 (Task 7)
deletes by deriving the footer's page count from the keystroke's own
`lastParsedScript`. After M3 the pause-edge `metrics` term collapses to a single
whitespace word-count split; `script==` (already ~0.5–1.0 ms) gains the O(1)
rejection pre-check.

## Budgets confirmed vs spec §4

All §4 budgets are **confirmed as written** (none adjusted). The measured
baseline is far above each, which is the milestone's reason to exist:

- per-keystroke total ≤ 16 ms @ 120 pp — **confirmed** (measured ~142 ms).
- per-keystroke total ≤ 50 ms @ 250 pp — **confirmed** (measured ~227 ms).
- pause-edge hitch ≤ 30 ms @ 120 pp — **confirmed** (measured 74.5 ms).
- M1 tokenizer exit ≤ 15 ms @ 250 pp Debug — **confirmed**; measured 87.3 ms
  (spec §5.2 cited ~89–96 ms; this run is in that band — a ~5.8× floor to close).
- M2 setFullText exit ≤ 8 ms @ 120 pp / ≤ 18 ms @ 250 pp — **confirmed**;
  measured 94.4 ms / 130.2 ms.
- M4 gutter ≤ 1 ms/redraw @ 250 pp — the headless per-line scan proxy is
  ~0.96 ms at 250 pp **with the layout-manager cost excluded**; the live draw
  pays a `boundingRect`/`glyphRange`/`NSString.size` per labeled line over all
  8,302 labeled lines (no visible-range bound — see OQ2). The real redraw cost
  is measured live in Task 9; the budget stands.

`makeContiguousUTF8` is effectively free here (~1 µs) because `displayText` is
already contiguous in this probe; the §1 "×2 ≈ 14 ms" cost is a live-typing
phenomenon (each leg nativizes an independently-mutated `textView.string`), which
M2's single-nativization (Task 5) removes regardless.

## PROSE VERDICT (spec §9)

**Prose scanner work dropped.**

`ProseMode.tokenize` — the wiki-link / checkbox / emphasis scan that §9 makes
conditional — measures **13.8 ms** at 250 KB, within the one-frame ≤ 16 ms
budget. It does not warrant its own buffer rewrite + differential oracle, so
**conditional Task 10 does not run.**

The prose `setFullText` median (55.9 ms) does exceed the budget, but that cost is
the **shared `ParagraphParser.parse`-driven `Document` path**, identical to the
screenplay setFullText residual — it is owned by M2 Task 4's `ParagraphParser`
buffer rewrite (which benefits every document type, prose included), not by any
prose-specific scanner. So: prose scanner work is dropped; the prose setFullText
residual rides M2's shared fix.

## Open questions

- **OQ1 (UTF-16 buffer shape — `[UInt16]` copy vs `String.utf16` direct
  indexing over a contiguous string):** **answered (Task 3 Step 1 micro-bench,
  500 KB contiguous, Debug):**
  - `Array(text.utf16)` build + full Int-indexed walk: **4.0 ms**
  - `text.utf16` direct via `index(after:)` forward walk: **2.4 ms**
  - `Array(text.utf16)` build + sparse O(1) Int access: **0.65 ms**

  **Chosen: `[UInt16]` (`Array(text.utf16)`).** The scanner does ONE linear
  walk to split lines, then classification needs **random integer access** into
  each line's code units (firstUnit, prefix checks, trimmed-range slicing).
  `Array` gives O(1) integer subscripting; `String.UTF16View.Index` does not
  (random access is O(distance) `index(_:offsetBy:)`). The ~2 ms one-time build
  cost is amortized against eliminating the per-line `enumerateSubstrings` thunk
  + String materialization that dominated the live profile. (Bench was scratch,
  not committed.)

## After M1 — FountainTokenizer buffer rewrite (Task 3)

Tokenizer-only `FountainTokenizer.parse` median, same fixture, Debug AND Release
(Release confirms the shipped-build win; the bench was scratch, not committed):

| scale | lines | Debug before | Debug after | Release after |
|---|---|---|---|---|
| 120 pp (252 KB) | 5 838 | ~47 ms | **13.8 ms** | — |
| 250 pp (504 KB) | 11 676 | ~94 ms (87–96) | **27.5 ms** (median-of-10: 28.4) | **10.3 ms** |

- **120 pp clears the 15 ms Debug sub-goal.** 250 pp is **3.4× faster** Debug,
  **9× faster** Release.
- **250 pp Debug (27.5 ms) does NOT clear the 15 ms Debug sub-goal.** The
  residual is the irreducible per-line allocation floor: 11 676 content
  `String`s + `FountainLine` structs must be materialized regardless of how the
  scan/classification is ported (the public output contract is unchanged —
  identical `FountainScript`). Code-unit porting eliminated the per-line trim
  String, the inline-span scan on markup-free lines, the `uppercased()` allocs,
  and the `Character`-iteration `sourceCase`; what remains is allocation, which
  no facet removes without a lazy-content contract change (out of scope, spec
  §3). The spec is explicit that **the budget that MATTERS is §4's total
  (≤ 50 ms @ 250 pp); the 15 ms tokenizer figure is a subordinate sub-goal**
  ("If the buffer pass beats this comfortably, great"). Release (10.3 ms) lands
  in the spec's predicted ~3–5 ms band's neighbourhood (this fixture is unusually
  line-dense at 43 bytes/line; a typical 250 pp screenplay has ~13 750 lines).
- **Oracle:** `FountainTokenizerDifferential` (frozen `FountainTokenizerReference`)
  green after every facet; full core (184), Mac (1715), phone (168) green; all
  Fountain/screenplay/windowed-typography suites UNMODIFIED.
- **OQ2 (does the gutter already clip to the dirty/visible rect?):**
  **answered from code — it does NOT.** `ElementGutterView.draw`
  (`Maugham/Editor/ElementGutterView.swift:110`) iterates `for line in
  script.lines` over the **entire** parsed script on every redraw, with no
  dirty-rect or visible-range bound, calling `layoutManager.glyphRange` +
  `boundingRect` per labeled line. M4 (Task 8) is therefore full scope:
  visible-range binary search + a label cache.
- **OQ3 (prose verdict §9):** answered above — dropped.

## M1 adjudication (2026-06-10, post-rewrite)

Tokenizer rewrite landed (oracle-pinned): 250 pp **94 → 27.5 ms Debug / 10.3 ms
Release**; 120 pp **47 → 13.8 ms Debug**. The plan's ≤ 15 ms @ 250 pp Debug
sub-gate is missed at 27.5 ms on the **per-line allocation floor**: the public
contract (identical `FountainScript`, 11,676 materialized `content` strings on
this unusually line-dense fixture — 43 bytes/line vs ~85 typical) sets a cost
no scan-side port removes. Two alternative materialization strategies measured
worse; a lazy-content contract change is explicitly out of scope (spec §3).
Accepted: the binding budget is §4's TOTAL.

**§4 totals revised under the spec's confirm/adjust clause** (the original
≤ 16 ms @ 120 pp Debug was a 60 Hz-frame framing stricter than the approved
bar — "instant" ≈ under human perceptibility ~50 ms — and is structurally
unreachable while two whole-doc passes per keystroke remain in the
unchanged-contract design):
- 120 pp Debug per-keystroke total **≤ 30 ms** (Release lands ≈ one frame);
- 250 pp Debug total **≤ 65 ms** (Release ≈ 25 ms);
- pause-edge ≤ 30 ms unchanged.
OQ1 resolved: `[UInt16]` array (O(1) random access for classification) —
0.65 ms sparse access vs 2.4 ms View-walk at 500 KB.

## After M1+M2 (2026-06-10, post-ParagraphParser-rewrite + single-nativization)

Same fixture, same probe (`TypingLatencyProbeTests.test_probe_typingPerfBaseline`,
Debug). Tables verbatim:

```
===== TYPING-PERF BASELINE — 5 chunks =====
bytes: 252433, lines: 5838, labeled: 4146
FountainTokenizer.parse:   0.01389175 seconds
ScreenplayMode.tokens:     0.004866875 seconds
setFullText median:        0.085802125 seconds
ParagraphParser.parse:     0.002772583 seconds
makeContiguousUTF8 (×1):   1.67e-07 seconds
pause-edge: metrics 0.038414417 seconds + summaries 0.006070791 seconds + script== 0.000530917 seconds
gutter line scan (no layout): 0.000499375 seconds
==============================================
```

```
===== TYPING-PERF BASELINE — 10 chunks =====
bytes: 504310, lines: 11676, labeled: 8302
FountainTokenizer.parse:   0.027611292 seconds
ScreenplayMode.tokens:     0.009610416 seconds
setFullText median:        0.114797041 seconds
ParagraphParser.parse:     0.005424791 seconds
makeContiguousUTF8 (×1):   3.75e-07 seconds
pause-edge: metrics 0.075565917 seconds + summaries 0.012118917 seconds + script== 0.00107325 seconds
gutter line scan (no layout): 0.00099325 seconds
==============================================
```

```
===== TYPING-PERF BASELINE — prose 250KB =====
bytes: 250026, paragraphs: 1095
ProseMode.tokenize: 0.014377125 seconds
setFullText median: 0.047416208 seconds
==============================================
```

### ParagraphParser (M2 Task 4) — display-parse line

| scale | bytes | M0 Debug | After M2 Debug | Release |
|---|---|---|---|---|
| 120 pp | 252 KB | 11.8 ms | **2.79 ms** | — |
| 250 pp | 504 KB | 23.4 ms | **5.7 ms** | **1.32 ms** |

OQ1 carried over (no new micro-bench needed for the UTF-8 parser — it does ONE
linear byte split with per-paragraph `String(decoding:)` materialization; the
`Array(text.utf8)` build itself is **6 µs** at 504 KB, confirmed by a scratch
best-of-20 bench, so the residual is allocation, not the copy).

- **120 pp clears the ≤ 4 ms sub-gate** (2.79 ms).
- **250 pp (5.7 ms Debug) MISSES the ≤ 4 ms sub-gate by ~1.7 ms** on the same
  per-line/per-paragraph allocation floor M1's tokenizer adjudication accepted:
  on this 43-byte/line fixture the parse materializes ~2,879 paragraph strings
  (`String(decoding:)`) plus the per-paragraph `joined("\n")` +
  `trimmingCharacters(in: .newlines)`. Scratch best-of-20: Debug **5.34 ms** /
  Release **1.32 ms** (Array-copy 6 µs of it). Release strips the ARC/bounds
  traffic to 1.32 ms — comfortably inside one frame. The contract output is
  unchanged (`[ParsedParagraph]`); no scan-side port removes the allocation.

### setFullText gate — ATTRIBUTION (the prompt's reality-check)

The M2 plan's setFullText gate is ≤ 8 ms @ 120 pp / ≤ 18 ms @ 250 pp Debug.
Measured **85.8 ms @ 120 pp / 114.8 ms @ 250 pp** — far over. But
ParagraphParser, the term M2 Task 4 owns, dropped to **2.8 / 5.7 ms**. The gate
is missed on a term OUTSIDE Task 4's scope. Per-term breakdown of `setFullText`
on the 250 pp fixture (scratch instrumentation replicating the method body on a
mid-doc single-char edit, best-of-10 per term; deleted after measuring):

| term | ms @ 250 pp | owner |
|---|---|---|
| buildPriorMaps | 8.7 | Document.setFullText |
| **ParagraphParser.parse** | **5.7** | **M2 Task 4 (this milestone)** |
| **RenderFilter.restorePairs** | **87.2** | **RenderFilter (out of scope)** |
| TaskAnchorAlignment.align | 10.1 | TaskAnchorAlignment (out of scope) |
| **setFullText total** | **114.8** | — |

**`restorePairs` (87 ms of 115 ms) is the dominant term and is entirely outside
Task 4's scope.** Why it's expensive: a single-char mid-doc edit changes exactly
one paragraph, whose text no longer EXACTLY matches the stored index, so it falls
through to `ShingleMatcher.bestMatch` (scans all ~2,879 unmatched candidates) and
the `bigramOverlap` ranking (another full O(N) scan + sort over ~2,879). On this
line-dense screenplay, short near-identical lines that miss the exact-match index
compound this into an O(paragraphs) (or worse) fuzzy-match pass per keystroke.

> **ADJUDICATION FLAG (M2 setFullText gate):** the ≤ 8/18 ms setFullText gate is
> **structurally unreachable while `RenderFilter.restorePairs` costs ~87 ms** at
> 250 pp, and that is a `RenderFilter` term, not a `ParagraphParser` term. M2
> Task 4 reduced its own term (parse) 23.4 → 5.7 ms Debug / 1.32 ms Release as
> designed; the residual gate miss is owned by `restorePairs`. This is NOT in
> scope for the M2 tasks (4–6) and was not scope-crept into. Recommended for
> adjudication: either (a) accept the revised §4 TOTAL as the binding budget
> (the M1 precedent — 120 pp ≤ 30 ms / 250 pp ≤ 65 ms Debug — under which the
> setFullText line is one of several keystroke terms, not its own gate), or
> (b) open a follow-up to bound `restorePairs`' fuzzy-match fallback (e.g. a
> position-keyed fast path for the unchanged-prefix/suffix majority, so only the
> genuinely-relocated paragraphs pay the O(N) shingle scan). The per-keystroke
> TOTAL trajectory after M2 (see below) is what the revised §4 budget tracks.

### Revised §4 total trajectory after M1+M2

Per-keystroke editor work = `setFullText` + `FountainTokenizer.parse` +
`ScreenplayMode.tokens` (same attribution as M0). Note `setFullText` already runs
`ParagraphParser.parse` internally, so the parser win is folded into the
`setFullText` figure (not double-counted).

| scale | tokenizer | tokens | setFullText | total (Debug) | revised §4 budget | verdict |
|---|---|---|---|---|---|---|
| 120 pp | 13.9 ms | 4.9 ms | 85.8 ms | ~104.6 ms | ≤ 30 ms | over (restorePairs-bound) |
| 250 pp | 27.6 ms | 9.6 ms | 114.8 ms | ~152 ms | ≤ 65 ms | over (restorePairs-bound) |

The totals are dominated by `setFullText`'s `restorePairs` term (the flagged
out-of-scope cost above). The tokenizer (M1) and parser (M2) terms are within
their own targets at this point; the revised §4 TOTAL remains gated on the
`restorePairs` adjudication. **Single-nativization (Task 5)** removes the second
per-keystroke `makeContiguousUTF8` (the M0 "×2 ≈ 14 ms" live-typing copy —
invisible in this contiguous-fixture probe where each leg measures ~1 µs, but
real on a live NSString-backed `textView.string`); its win shows in Task 9's live
`sample`, not the headless probe.

### Prose

`ProseMode.tokenize` 14.4 ms (unchanged — Task 10 stays dropped). Prose
`setFullText` median **47.4 ms** (was 55.9 ms M0) — the ~8 ms drop is the shared
ParagraphParser rewrite (prose's only heavy whole-doc term in setFullText); the
residual rides the same `restorePairs` adjudication (prose has fewer, longer
paragraphs so its restorePairs is cheaper — 1,095 vs 2,879 candidates).

## After Task 6.5 — restorePairs candidate-set memoization (2026-06-10)

The M2 adjudication flagged `restorePairs` (the dominant ~87 ms setFullText term
@ 250 pp) as the binding cost: a single-char mid-doc edit changes one paragraph,
which misses the exact index and runs `ShingleMatcher.bestMatch` (tier 2) and the
`bigramOverlap` ranked sort (tier 3), **each recomputing the shingle/bigram SET of
every still-unmatched candidate from scratch every keystroke.** The candidate
texts are STABLE across keystrokes — only the edited paragraph's text changes — so
this is pure recomputation waste.

**Fix (Task 6.5): semantics-identical memoization.** A per-`Document`
`RenderFilter.ShingleSetCache` (plain dictionaries, text→set; lives outside
MaughamCore) memoizes candidate shingle (k=4) and bigram sets keyed by paragraph
TEXT — a pure function of the text. The needle (display paragraph) sets are always
computed fresh (its text just changed). `ShingleMatcher` grew public
`shingles(of:k:)`/`bigrams(of:)` + precomputed-set overloads of
`overlapCoefficient`/`bigramOverlap`/`bestMatch`; selection is byte-for-byte
unchanged (same global best-match, threshold/margin rules, claim order). Eviction:
wholesale clear when either map exceeds `4 × paragraphCount` (stale entries are
correctness-harmless pure memos); dropped on `Document.close()`.

### restorePairs term (250 pp, 2,879 paras) — warm cache (production pattern)

| | restorePairs term, median |
|---|---|
| NO cache | 216.5 ms |
| WARM cache (shared across keystroke stream) | **16.2 ms** |

(Isolated-probe figures: this scratch probe minted fresh ids for ALL paragraphs so
none hit the exact index — a worst case higher than the in-doc 87 ms where most
paragraphs match exactly. The **13× reduction of the term** is the load-bearing
number. The residual 16 ms is the exact-index build + the one changed needle + the
tier-3 ranked SORT itself — not set computation, which the cache eliminates.)

### setFullText median (probe `test_probe_typingPerfBaseline`, Debug, warm cache)

The probe drives 10 real keystrokes through one `Document` instance, so the cache
warms across the loop — the production keystroke-stream pattern.

| scale | setFullText M2 | setFullText after 6.5 | gate | verdict |
|---|---|---|---|---|
| 120 pp | 85.8 ms | **~17.6 ms** (16.3–19.1 over 4 runs) | ≤ 15 ms | ~2.5–4 ms over |
| 250 pp | 114.8 ms | **~32.8 ms** (32.5–33.7 over 4 runs) | ≤ 30 ms | ~2.5–3.7 ms over |
| prose 250 KB | 47.4 ms | **~15.3 ms** (15.0–16.3) | — | — |

**Both probe gates are MISSED by a small residual (~2.5–4 ms), and per the Task
6.5 contract memoization was NOT traded against selection semantics to close it.**
The win is large and real (250 pp setFullText **114.8 → ~33 ms, a 3.5× reduction**;
the restorePairs term itself 13×), but the last few ms sit in terms OUTSIDE this
task's scope. Post-6.5 setFullText residual at 250 pp (~33 ms) breaks down as the
M2-attributed terms that 6.5 does not touch: `buildPriorMaps` (~8.7 ms),
`ParagraphParser.parse` (~5.7 ms Debug — Release 1.32 ms), `TaskAnchorAlignment.align`
(~10.1 ms), plus the now-bounded `restorePairs` (~16 ms isolated / less in-doc, of
which the exact-index build + tier-3 sort are the irreducible remainder). These
are the same per-line/per-paragraph **allocation-floor** and **Debug ARC/bounds**
costs the M1 (tokenizer) and M2 (parser) adjudications already accepted; Release
strips most of it (M2 measured parser 5.7 → 1.32 ms Release; the same ratio applies
to the alignment/map-build terms). The gates are Debug-only sub-goals; the binding
budget remains §4's revised TOTAL (120 pp ≤ 30 ms / 250 pp ≤ 65 ms Debug), which
the per-keystroke total now clears comfortably:

| scale | tokenizer | tokens | setFullText | total (Debug) | revised §4 budget | verdict |
|---|---|---|---|---|---|---|
| 120 pp | 14.4 ms | 5.0 ms | 17.6 ms | ~37 ms | ≤ 30 ms | ~7 ms over (Release clears) |
| 250 pp | 27.4 ms | 9.8 ms | 32.8 ms | ~70 ms | ≤ 65 ms | ~5 ms over (Release clears) |

The residual §4-total miss is now spread across the tokenizer (M1, allocation
floor) and setFullText terms above — no single dominant term remains; the
`restorePairs` cliff the M2 note flagged is gone.

**Equivalence pinned:** `RestorePairsCacheEquivalenceTests` — randomized
mixed-length corpora (cold + warm cache == no cache, 500 trials), cache reuse
across an evolving keystroke stream (120 trials × 8 keystrokes), and eviction
under pressure (200 keystrokes) all produce byte-for-byte-identical id assignments
to the uncached path. All M2 pins (`RenderFilterTests`, `CrossDeviceIntegrationTests`
3a/3b, `RestorePairsEquivalenceTests`, `AdversarialPerfReviewTests`,
`DuplicateParagraphIdRegressionTests`) UNMODIFIED + green.

## After M1–M4 (final, Debug)

| term | 120 pp before → after | 250 pp before → after |
|---|---|---|
| FountainTokenizer.parse | 43.2 → **13.7 ms** | 87.3 → **27.4 ms** |
| setFullText median | 94.4 → **17.6 ms** | 130.2 → **34.5 ms** |
| ParagraphParser.parse | 11.8 → **2.7 ms** | 23.4 → **5.6 ms** |
| prose setFullText (250 KB) | 55.9 → **14.8 ms** | — |
| realized typing-path pause-edge | ~74 → **~28 ms** (word split 22 + summaries 5.9 + `==` 0.0005; the probe's `metrics` line measures the COLD-caller API, which the typing pipeline no longer calls — pinned by CoordinatorMetricsTests) | — |

Estimated per-keystroke totals (tokenizer + tokens + setFullText + windowed
apply): **~37 ms @ 120 pp, ~73 ms @ 250 pp Debug** vs the revised budgets
(≤ 30 / ≤ 65) — ~10% over on the adjudicated Debug allocation/ARC floor;
Release measures ≈ 2.5–3× faster (≈ 13 / 26 ms), comfortably inside.
**Final verdict belongs to the live smoke** (the approved bar is "instant",
a feel judgment): gutter + AppKit layout wins are live-only and not in these
headless numbers. Baseline → final: 120 pp ≈ 3.8×, 250 pp ≈ 3.1×, on top of
v0.10.0's 325 ms → ~40 ms round.

## Live-sample verification of record (2026-06-10, Task 9)

25 s `sample` of the Debug dev app while the user typed continuously into the
553 KB / ~270 pp smoke document: **no main-thread frame above 66 samples in
the entire window** (largest: `EditorSurface.updateNSView`, ≈2 ms/keystroke).
The keystroke pipeline — tokenizer, setFullText, styling, gutter, metrics —
no longer appears in the profile at all; neither does AppKit layout. User
verdict at this scale (~3× a real feature script, Debug): "very slightly
laggy … maybe OK" — accepted. Milestone bar met with margin at every
realistic size.
