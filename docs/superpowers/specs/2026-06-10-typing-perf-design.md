# Typing Performance — Design (remaining per-keystroke floor)

- **Date:** 2026-06-10
- **Status:** Design approved (brainstorm 2026-06-10); pre-implementation
- **Context:** Continues the smoke-found typing-latency work shipped in v0.10.0
  (windowed typography, setFullText parse-once + indexed matching, scanner
  fast paths, live-profile fixes). This spec eliminates the measured remaining
  floor. Method of record for all numbers: `sample <pid>` of the live app
  while typing (headless probes demonstrably miss live-only costs), plus the
  committed probe `MaughamTests/Performance/TypingLatencyProbeTests`.

## 1. Motivation — the measured bill of materials

Per keystroke at 140 pp / ~250 KB single-file screenplay, Debug build
(2026-06-10 live samples 3–5):

| Cost | ~ms | Nature |
|---|---|---|
| `FountainTokenizer.parse` (whole doc) | 40–65 | linear — the dominant floor |
| `setFullText` residual (display `ParagraphParser.parse` + alignment + matching) | ~30 | linear |
| `makeContiguousUTF8` ×2 (binding write + retokenize each copy independently) | ~14 | linear, halvable |
| `ElementGutterView.draw` (per-line work per redraw) | ~5% of typing window | redraw-path |
| Pause-edge batch, ~350 ms after typing stops (footer `metrics()` full re-parse + `sceneSummaries()` + `FountainScript` deep-`==`) | 150–250 per pause | the "intermittent" feel |

Release builds run these scanners ~2–4× faster; the bar below is set in
DEBUG so dev builds feel right too.

## 2. Decisions already made (brainstorm)

1. **The bar ("C"):** instant at any realistic screenplay — ≤ 120 pp feels
   like a short story, in Debug — while structuring the tokenizer so true
   incremental tokenization ("B") is reachable later without redesign.
2. **`setFullText` posture ("C"):** fast-scan the residual with the same
   buffer treatment; do NOT rewire the editor↔Document contract
   (tripwires 2/3/6/7). Incremental Document sync is a future milestone with
   its own spec if ever needed.
3. **UTF-16 buffer, not UTF-8:** tokens carry `NSRange` (UTF-16) over
   `textView.string`; a UTF-8 scanner pays an index-mapping tax at every
   boundary. One contiguous `[UInt16]` (or `String.utf16` over a
   known-contiguous string) with ASCII fast paths on code units keeps ranges
   native.
4. **Footer metrics come from the existing parse** — the coordinator already
   tokenizes per keystroke; deriving the footer's page count from that script
   DELETES the pause-edge re-parse (supersedes the v0.10.0 debounce, which
   stays as transport but carries precomputed values).

## 3. Non-goals

- **No incremental tokenization (B)** — the per-line record structure must
  make it *reachable*, not *implemented*.
- **No editor↔Document contract changes.** The binding shape, echo guards,
  and `applyExternalText` caller set are untouched by construction.
- **No prose scanner work unless M0 measures it warranted** (Collections
  allow arbitrary single-file `.md`; per-chapter novels are structurally
  fine).
- **No async/background tokenization.** Synchronous-but-fast preserves the
  same-render-cycle styling contract; async introduces flicker and a new
  staleness surface for no need at the C bar.

## 4. Phase 0 — extend the probe, record the baseline (gate for M1+)

Extend `TypingLatencyProbeTests` with:
- a large single-file **prose** case (~250 KB `.md`, wiki links + checkboxes
  present) measuring `ProseMode.tokenize` + the prose setFullText path;
- per-item timings at BOTH 120 pp (~250 KB) and 250 pp (~500 KB) screenplay
  scale: tokenizer, setFullText total, display parse alone, the double copy,
  a gutter-draw proxy (per-line work invoked directly), and the pause-edge
  batch (metrics + sceneSummaries + script `==`).

**Budgets (confirm/adjust at Phase 0 exit, all DEBUG):**
- total per-keystroke ≤ 16 ms at 120 pp (one 60 Hz frame); ≤ 50 ms at 250 pp;
- pause-edge hitch ≤ 30 ms at 120 pp;
- prose single-file: same budgets; if its baseline already meets them,
  prose scanner work is dropped (recorded, not silently skipped).

## 5. M1 — FountainTokenizer buffer rewrite (the headline)

### 5.1 Shape

- Build one contiguous UTF-16 view of the input once per parse. Scan it into
  `[LineRecord]`: per line — code-unit range, trimmed-range, blank flag, and
  the **classification inputs captured explicitly** (prevBlank, prevElement,
  forced-prefix byte, trailing `^`, uppercase-run flag, …). Classification
  and inline-span extraction then operate on slices, with ASCII fast paths
  on code units and Foundation fallbacks for non-ASCII lines (the proven
  fix-C pattern).
- `LineRecord` is internal but REAL (not an implementation detail to inline
  away): it is the seam a future incremental pass re-derives from. Document
  this intent on the type.
- Public surface unchanged: `parse(_:) -> FountainScript` with identical
  `FountainLine` output (ranges, elements, isDualSecond, inline spans, title
  page, page estimation).

### 5.2 Safety

- **Differential oracle:** keep the CURRENT tokenizer verbatim in the test
  target (`FountainTokenizerReference`) and pin equality of full
  `FountainScript` output over: the probe chunks; randomized generated
  scripts (dual dialogue `^`, forced elements, title pages, transitions,
  sections, boneyards, notes); CRLF / lone-CR / NBSP / ZWSP / emoji / CJK
  corpora; pathological inputs (empty, whitespace-only, single-line,
  100k-line).
- All existing Fountain/screenplay suites (45+ tests) and
  `WindowedTypographyEquivalenceTests` pass UNMODIFIED.
- Exit: tokenizer ≤ 15 ms at 250 pp Debug (measured ~89–96 ms today — a 6×
  floor; Release lands ~3–5 ms). If the buffer pass beats this comfortably,
  great; the budget that MATTERS is §4's total.

## 6. M2 — setFullText residual + single nativization

- `ParagraphParser.parse` gets the same UTF-16/byte-buffer single-pass
  treatment (it is already Substring-based with ASCII fast paths from fix C;
  this converts the per-line loop to one buffer walk). Differential oracle
  identical in shape to M1's (the fix-C `parseReference` pattern already
  exists — extend its corpus).
- Single nativization: `textDidChange` nativizes once and THREADS the string
  into `retokenizeAndStyle(text:)`; other callers keep self-nativizing.
  Verify string/textView consistency assumptions (the windowed-diff guards
  already fall back to whole-doc on length mismatch).
- Exit: setFullText total ≤ 8 ms at 120 pp, ≤ 18 ms at 250 pp Debug.

## 7. M3 — pause-edge: metrics from the existing parse + coalesced update

- `EditorCoordinator` exposes the per-keystroke `lastParsedScript`-derived
  metrics (word count from the nativized text + `estimatedPageCount` from
  the already-parsed script) through the EXISTING onTextChange/metrics-mirror
  debounce — the payload becomes precomputed `EditorMetrics`, so
  `ProjectWindow.updateMetrics` performs ZERO parsing. `WritingMode.metrics`
  stays for cold callers (load-time, search, publish).
- The script broadcast to the Scenes sidebar keeps its debounce; cheapen the
  SwiftUI-side deep-`==` with an O(1) pre-check (line count + total UTF-16
  length + last-line range) before full comparison — pinned by a test that
  unequal scripts with equal pre-checks still compare unequal (the pre-check
  is an optimization gate, never an equality oracle).
- Exit: pause-edge batch ≤ 30 ms at 120 pp Debug; zero whole-doc parses
  outside the keystroke's own tokenize (assert via the probe's attribution).

## 8. M4 — ElementGutterView draw caching

- Cache the per-line gutter artifacts (abbreviation string, attributed
  string/layout, y-origin inputs) keyed by the line's (range, element)
  derived from the SAME token list the styling pass used; invalidate by
  token-diff window (reuse `TokenRestyleWindow`'s decision) + scroll
  exposure. Draw only lines intersecting the dirty rect (verify what
  `draw(_:)` receives today — it may already clip; the measured cost says
  per-line work dominates regardless).
- Equivalence pin: cached vs uncached produce identical per-line render
  inputs (string, position) over scripted edits — same test shape as the
  windowed-typography pin. Tripwire 4 applies.
- Exit: gutter ≤ 1 ms per redraw at 250 pp Debug.

## 9. Prose (conditional, from M0 data)

If the M0 prose baseline violates the budgets: give `ProseMode.tokenize`
(wiki-link / checkbox / emphasis scan) the M1 buffer treatment with its own
differential oracle. Otherwise record the numbers and close the item.

## 10. Sequencing & exit criteria

| Phase | Gate to start | Exit |
|---|---|---|
| M0 probe + baseline | — | per-item table at 120/250 pp + prose recorded; budgets confirmed |
| M1 tokenizer | M0 recorded | differential green; tokenizer ≤ 15 ms @ 250 pp (see §5.2); all suites green both schemes |
| M2 setFullText | M1 | parser differential green; ≤ 8/18 ms; suites green |
| M3 pause-edge | can parallel M2 | zero non-keystroke parses; ≤ 30 ms hitch |
| M4 gutter | any time after M0 | equivalence pin green; ≤ 1 ms/redraw |
| Final | all above | live `sample` during real typing at 120 pp AND 250 pp shows total ≤ budgets; user manual smoke (type + pause + scrub Scenes + gutter on) |

Manual smoke (user-run): open the 250 pp fixture project in a Debug dev
build → type continuously mid-document and at the end → no perceptible lag,
no pause-edge stutter → Scenes sidebar captions correct after pauses →
gutter abbreviations correct while scrolling fast.

## 11. Open questions (resolve during M0, none block it)

1. Whether `String.utf16` over a `makeContiguousUTF8`'d string is fast
   enough vs an explicit `[UInt16]` copy (one extra O(N) copy per keystroke
   either way today; measure both shapes in M0).
2. Whether the gutter already clips to the dirty rect (M4 scope shrinks to
   caching-only if so).
3. Prose verdict (§9).
