# The tectonic bundle fetch — CI's one live network dependency

**Date:** 2026-08-15
**Trigger:** CI run [31874029028](https://github.com/dtrouton/Maugham/actions/runs/31874029028), `Mac tests (Maugham scheme)`, exit 65.
**Status:** resolved (cached + skip-by-name). Residues below are worth keeping.

## What was red

Two tests, both in `PublishingEndToEndTests`:

- `testFullFlow_initialize_setConfig_compilePDF_compileEPUB_listPublications_readPage()` (12.372s)
- `testRepublish_producesIdenticalContent_evenAfterTemplateMutation()` (2.775s)

Eight assertion failures between them, and **one** cause. From the xcresult:

```
PublishingEndToEndTests.swift:78: XCTAssertEqual failed:
  ("Optional("failed")") is not equal to ("Optional("completed")")
  - PDF compile failed: ["log_excerpt": note: …, "status": failed,
    "errors": <__NSArray0>(), "log_path": build/compile.log]
```

Everything else cascaded: `format`/`version`/`output_path` nil, `expected 2
publications … got: 1` (the EPUB landed, the PDF did not), `no PDF publication
with version='0.1'`, and in the republish test the v0.1 PDF simply never
existed.

## The diagnosis, and the two things that made it slow

The compile died **before typesetting began**. The tell is `errors: []` —
`TectonicLogParser` only recognises LaTeX errors (lines beginning `! `), so an
empty array with a non-zero exit means the process never got as far as reading
the document. What the `log_excerpt` did carry was bundle traffic:

```
note: connecting to https://relay.fullyjustified.net/default_bundle_v33.tar
note: resolved to https://data1.fullyjustified.net/tlextras-2022.0r0.tar
note: downloading index … downloading latex.ltx … downloading hyph-fur.tex …
```

`TectonicCache` lives at `~/Library/Caches/Maugham Dev/tectonic` (Debug builds
are the `dev` BuildVariant) and **nothing cached it in CI** — so every run did a
full cold fetch from a third-party host, and this one broke partway.

Two traps on the way to that conclusion, both worth remembering:

1. **The excerpt is `prefix(4000)` — the HEAD.** `CompileTools.swift:32`
   truncates to the first 4000 characters, which on a cold run is nothing but
   `note: downloading …`. It is tempting to read "it stopped at `hyph-fur.tex`"
   as *where* it failed. It is not; it is where the 4000-character budget ran
   out. The actual tectonic error line lives in `build/compile.log`, which CI
   does not upload, and is unrecoverable from the artifact.
2. **The obvious suspect was the wrong one.** This was the first `main` run
   after the M3 P1 merge (`f19c6be9`), which bumps `ProjectManifest`'s schema
   5 → 6 and stops seeding `status: "draft"` in `ProjectFactory` — both of
   which touch the project a publish run reads. Ruled out by running the suite
   locally at HEAD: both tests pass in 0.470s / 0.717s with a warm cache.

## The evidence that it was transient

Duration comparison across the two runs, same tests, same machine image:

| test | 08-13 (green) | 08-15 (red) |
|---|---|---|
| `PublishingEndToEndTests.testFullFlow…` | 12.343s **passed** | 12.372s **failed** |
| `CompileOrchestratorTests.testCompile_pdf_writesPublication…` | 1.187s (warm) | 8.292s (cold again) |

On 08-13 one worker paid the cold fetch once and everything else was warm. On
08-15 the E2E test's fetch failed, so the cache was still cold when the next
suite on **the same worker** needed it — and that second fetch, 8.3s later,
**succeeded**. A failure that recovers on its own inside the same gate is a
transient fetch failure, not a code defect.

Confirmed by re-running the job on the unchanged commit: green, with both tests
passing (`testRepublish` at 1.516s).

## What shipped

**1. CI caches the bundle** (`.github/workflows/ci.yml`). Restore before the
test step, save after, **split** rather than one `actions/cache` step so a red
gate still seeds the cache — a failing run is exactly when the warm bundle is
most worth keeping, and the combined action only saves on success. Keyed on
`scripts/fetch-tectonic.sh`, which pins the tectonic version, and the version
chooses which bundle is fetched. A hit takes the network out of the common path
and ~12s off the gate.

**2. `TectonicProbe` reads the premise** (`MaughamTests/TestSupport/`). Every
suite that shells out to tectonic now calls `try await
TectonicProbe.requireReady()` where it used to hand-roll a
"is-tectonic-bundled" guard (−232 lines, +57, across 18 files). The probe runs
one **canary** compile per test-host process, memoized behind an actor so two
suites in one worker cannot race two fetches into one cache directory.

**The load-bearing property** — read it before touching `canarySource`: the
canary is a bare `\documentclass{article}` document using no package, no
`\input`, and nothing this app emits. It therefore **cannot** fail because a
body emitter, a template or a style file regressed — only because tectonic
cannot run or cannot get its bundle. That is what makes skipping on a canary
failure honest rather than a way to hide red: break `LaTeXBodyEmitter` and the
canary still passes, so every real compile test still runs and still goes red.
`TectonicProbeTests` pins this, along with the tail-not-head rule and
once-per-process memoization.

## Residues

- **A red PDF-compile test with `errors: []` is the environment, not the code.**
  An empty errors array means typesetting never started. Check the fetch before
  reading any Swift.
- **`log_excerpt` is the head of the log and is useless on a cold run.** Feeding
  the tail instead (`CompileTools.swift:32`) would have made this run
  self-diagnosing. Not done — it changes an MCP response shape and wanted its
  own decision. `TectonicProbe.tail(of:)` is the shape it should take.
- **Skip-by-name now covers this class**, so the next occurrence reports as a
  named skip carrying the canary's log tail rather than as eight red
  assertions.
