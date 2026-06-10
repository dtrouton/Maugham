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
  indexing over a contiguous string):** deferred to Task 3 Step 1's 10-minute
  micro-bench; its numbers will be appended here in the Task 6 close-out.
- **OQ2 (does the gutter already clip to the dirty/visible rect?):**
  **answered from code — it does NOT.** `ElementGutterView.draw`
  (`Maugham/Editor/ElementGutterView.swift:110`) iterates `for line in
  script.lines` over the **entire** parsed script on every redraw, with no
  dirty-rect or visible-range bound, calling `layoutManager.glyphRange` +
  `boundingRect` per labeled line. M4 (Task 8) is therefore full scope:
  visible-range binary search + a label cache.
- **OQ3 (prose verdict §9):** answered above — dropped.
