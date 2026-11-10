# Typing loop measurements (plan 1), 2026-11-10

Probe: `MaughamTests/Performance/TypingLoopCensusTests.test_probe_typingLoopStages`
(gated; skip named in `scripts/skip-baseline.txt`). It types 40 mid-document
keystrokes through `EditorIntegrationHarness.withRealDocument` (the
production-equivalent binding setter: `Document.setFullText` then
`DocumentStore.recordEditorTextWrite`). Fountain corpora use the same harness
with a new `screenplay: true` flag (a screenplay project, one `.fountain`
piece), so the wiring is the real one for both formats.

Machine: Apple M4 (Mac16,12), 24 GB, macOS 27.2, Xcode 27.2.

## Commands

Debug:

    TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 TEST_RUNNER_MAUGHAM_PERF_OUT=<file> \
      xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
      -only-testing:MaughamTests/TypingLoopCensusTests

Optimised: the same, plus `SWIFT_OPTIMIZATION_LEVEL=-O -derivedDataPath <scratch>/dd-opt`
(run from a script file; the derived-data folder deleted afterwards).
Parallel test workers swallow stdout, so the probe also writes its report to
the file `MAUGHAM_PERF_OUT` names.

## Before (spec table, optimised build, median of 40 keys)

| Stage | Prose 30 KB | Prose 250 KB | Report 250 KB | Fountain 250 KB |
|---|---|---|---|---|
| Keystroke total | 5.0 | 38.4 | 52.9 | 39.0 |
| `Document.setFullText` | 1.4 | 10.4 | 10.5 | 13.8 |
| Word count in the binding setter | 1.4 | 10.9 | 11.2 | 10.7 |
| Whole-document tokenize | 1.6 | 12.6 | 24.5 | 9.0 |
| String copy | 0.5 | 4.1 | 4.1 | 4.0 |

Autosave before: 23-50 ms on the main actor at 250 KB. No other "before" exists
(the temporary probe wrote nothing else down; there is no Debug "before" except
the earlier Debug keystroke totals of 55-78 ms at 250 KB).

## After, optimised (`-O`), ms

| Corpus | Keystroke median | max | setFullText | tokenize | string copy | settle | autosave (wall) | whole-doc paint |
|---|---|---|---|---|---|---|---|---|
| prose 30 KB | 3.51 | 3.67 | 1.12 | 1.56 | 0.53 | 1.37 | 12.73 | 2.73 |
| prose 250 KB | 27.16 | 27.38 | 9.33 | 12.65 | 4.11 | 11.09 | 27.20 | 17.77 |
| report prose 250 KB | 41.74 | 42.45 | 9.80 | 24.40 | 4.13 | 11.47 | 39.29 | 41.56 |
| fountain 60 KB | 6.55 | 6.66 | 2.63 | 2.14 | 0.99 | 2.71 | 22.12 | 14.78 |
| fountain 250 KB | 28.14 | 28.80 | 12.70 | 9.06 | 4.20 | 10.72 | 66.60 | 56.85 |

Keystroke: 38.4 -> 27.2 ms (prose 250 KB), 52.9 -> 41.7 (report), 39.0 -> 28.1
(Fountain), 5.0 -> 3.5 (prose 30 KB): each fell by about the 10-11 ms the
word count cost, which now shows as the "settle" column, paid once per burst.

## After, Debug, ms

| Corpus | Keystroke median | max | setFullText | tokenize | string copy | settle | autosave (wall) | whole-doc paint |
|---|---|---|---|---|---|---|---|---|
| prose 30 KB | 4.50 | 4.65 | 1.57 | 1.91 | 0.58 | 2.51 | 13.31 | 3.11 |
| prose 250 KB | 34.66 | 35.25 | 13.07 | 15.37 | 4.73 | 20.98 | 41.54 | 21.12 |
| report prose 250 KB | 57.75 | 58.46 | 13.51 | 33.94 | 4.73 | 20.64 | 48.94 | 54.02 |
| fountain 60 KB | 12.43 | 12.74 | 4.33 | 5.59 | 1.14 | 4.97 | 24.67 | 19.35 |
| fountain 250 KB | 52.62 | 53.48 | 19.80 | 23.01 | 4.82 | 20.41 | 81.79 | 78.85 |

## Reading the figures

- The count is pinned by `test_aBurstRunsNoWordCount_andOneSettleRunsOne`
  (40 keystrokes move `wordCountRunCount` by 0, one settle by 1); it fails when
  the count is put back in `recordEditorTextWrite`.
- "Autosave (wall)" is the time `performAutosave()` takes to return with its
  write landed. Since Task 2 the render and write run off the main actor, so it
  is no longer main-actor time; the main-actor part (the snapshot) is not
  separated out by this probe. It is not comparable to the 23-50 ms "before".
- The keystroke max sits within 1 ms of the median: the loop is steady, and the
  remaining cost is the whole-document `setFullText`, tokenize and string copy
  (this plan's scope was the word count and autosave only).

## What the probe does not measure

It is headless: a real `NSTextView` and `EditorCoordinator`, but in an
unshown test window. It does not time glyph layout and drawing, spell
checking, overlays (find, annotations, the canvas), or SwiftUI invalidation
and body re-evaluation (for example `ProjectWindow` reading
`liveSessionWordsNet`). A keystroke the writer feels includes all of those, so
these figures bound the model and store work, not the frame time.
