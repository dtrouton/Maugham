# Phase 2 — Characterization notes (the observed layer)

**HEAD:** `db1bea2c` · **All characterization tests pass against HEAD:** 79 test functions, 0 failures.

```sh
swift test --package-path experiment/ExperimentTests --filter Characterization
#   Executed 52 tests, with 0 failures   (PaletteCardCharacterization)
#   Executed 27 tests, with 0 failures   (TreeWalkCharacterization)
```

---

## 1. Method

I did **not** write characterization assertions from what I expected the code to do. I wrote a
probe — `ExperimentTests/Support/Probe.swift`, which asserts nothing and prints — ran it, and then
wrote every assertion from the printed output. That ordering matters: on my first pass through
`PaletteCardParser` I predicted seven behaviours wrongly, and four of those wrong predictions are
now pinned claims saying the opposite (`M1-C-010`, `M1-C-011`, `M1-C-024`, `M1-C-041`). Had I
written assertions first and iterated until green, I would have quietly converged on the same
answers while believing I had predicted them — and the honest measure of what machine generation
can *derive* would have been inflated.

The probe is kept in the repo, so every observation is reproducible:

```sh
swift test --package-path experiment/ExperimentTests --filter ObservationProbe
```

## 2. Ledger delta

| | count |
|---|---|
| Phase 1 claims (EXISTING_TEST) | 75 |
| Phase 2 claims (CHARACTERIZATION) | **88** |
| — of those, pinned by a passing test | 86 |
| — of those, recorded but deliberately not pinned | 2 |
| **Ledger total** | **163** |
| M1 `PaletteCard` | 100 (48 test-derived, 52 characterization) |
| M2 `TreeWalk` | 63 (27 test-derived, 36 characterization) |

The observed layer is **larger than the asserted layer in both modules** — 52 vs 48 in the
well-tested module, 36 vs 27 in the under-tested one. That is the headline of this phase and I
did not expect the ratio to be that close in M1.

## 3. What I could not observe, and why

Only **two** claims went into the non-deterministic bucket, and both are in M2:

- **`M2-C-035`** — the *iteration order* of the `[String: String]` that `idsByPath` returns is not
  stable across processes. Swift seeds its hasher per process, so a caller that iterates the map
  rather than subscripting it gets a run-varying order. Pinning any particular order would encode
  a fiction. **This one has teeth**: the doc comment says duplicate paths are "last-writer-wins
  (pre-order), which the store invariant — unique on-disk paths — makes moot". The *insertion*
  contest is deterministic (I pinned it as `M2-C-031`/`M2-C-032`); the *iteration* is not, and
  nothing in the codebase distinguishes the two.
- **`M2-C-036`** — the recursion depth at which `TreeWalk`'s walkers overflow the stack. Every
  walker is unbounded recursion with no depth guard. I pinned that a 1,000-deep chain is fine
  (`M2-C-034`); the *threshold* depends on thread stack size and optimisation level, so pinning it
  would produce a test that passes on my machine and fails in CI on a different queue.

**Everything else in both modules was observable, and that is a consequence of my Phase-0
selection rather than a finding about the codebase.** I chose two pure, I/O-free, UI-free,
`Sendable`, all-`let` modules precisely so characterization would be honest. M1 in particular has
*zero* non-deterministic surface — no clock, no dictionary, no set, no concurrency, no file
handle. If this experiment is meant to say something about machine-generated specs for Maugham as
a whole, that limitation is the first thing to discount: `OpLogStore`, `InboxStore` and the editor
seam would have produced a very different ratio, and I rejected `OpLogStore` in Phase 0 for
exactly this reason. **I should be read as having measured the easy case.**

## 4. Eleven pinned behaviours I believe are defects

Pinning is not endorsement. These are flagged `_defect_candidate` in the ledger and carried to the
ruling sheet. Ordered by how much I think they matter.

### 4.1 `M1-C-024` — a CRLF palette card loses every field. **The worst thing I found.**

Swift treats `"\r\n"` as a **single `Character`** (an extended grapheme cluster), so
`markdown.split(separator: "\n", omittingEmptySubsequences: false)` **never fires** on a
CRLF-terminated document. The entire file arrives as one line. The first-line branch claims it as
a title, and `kind`, `swatches`, `notes` and `imagePaths` all come back empty:

```
title = "T\r\n\r\nkind: location\r\n\r\n## Swatches\r\n\r\n- #fff\r\n"
kind  = .other        swatches = []        notes = []        imagePaths = []
```

This is not hypothetical input. Palette cards are plain markdown research assets, and CLAUDE.md's
own framing for research is that writers put files there. A card round-tripped through a Windows
editor, a cross-platform sync client, or a pasted web snippet arrives this way. It fails silently
and destructively: the card renders back out as a title-only card, and the swatches are gone from
disk. **No existing test uses a `\r` anywhere in either module.**

### 4.2 `M1-C-003` — `color(fromHex:)` accepts `#+FFFFF`

`UInt32(_:radix:)` accepts a leading `+`, and the length check counts it as one of the six
characters. So `"#+FFFFF"` validates, parses as `0x0FFFFF`, and is admitted as a swatch by
`PaletteCardParser.parse` — which gates entirely on `color(fromHex:) != nil`. It then renders
back out uppercased and round-trips stably. A validator that is the sole gate on a data format
accepting a non-hex character is a small hole, but it is *in the gate*.

### 4.3 `M1-C-043` — an invalid swatch is written to disk and then silently lost

`PaletteCard.init` is public and accepts any `[String]` for `swatches`. A model carrying
`"not-a-hex"` renders to `- NOT-A-HEX` in the writer's file, and comes back as `[]`. The header
comment's round-trip law is qualified as holding "for any editor-reachable model", which may well
make this out of scope — but the *file is written either way*, so the writer's card on disk gains
a line that the app then refuses to read. Whether the initialiser should reject, or the renderer
should skip (as it already does for untagged-empty notes — `M1-T-042`), is a judgement I can't
make; the asymmetry with the note case is what makes me flag it.

### 4.4 `M1-C-044` / `M1-C-045` / `M1-C-046` — the other three model-shapes that don't round-trip

- A newline in `title` migrates the remainder into `body`.
- A newline in a note's text truncates the note at the newline; the rest is lost.
- A remote URL in `imagePaths` is mangled by `relativize` — splitting on `/` collapses the
  scheme's `//` — and reads back as `https:/e.com/x.png`, now a *relative* path. Note the
  parser is careful never to *admit* a remote URL (`M1-C-034`, `M1-T-019`), so the renderer's
  willingness to emit one is an asymmetry between the two halves of a documented inverse pair.

### 4.5 `M1-C-021` — an empty `kind:` value consumes the one-shot capture

`kind: ` (blank) resolves to `.other` **and sets `kindCaptured`**, so a later well-formed
`kind: location` is demoted to body prose. The one-shot rule exists to stop body prose corrupting
`kind` (`M1-T-039`, a deliberate and well-tested claim). This is that rule firing on a line that
carried no information.

### 4.6 `M1-C-023` — a writer's blank line is silently eaten

Every *empty* line before `kind:` is treated as the renderer's structural framing — including one
the writer typed between real prose and the `kind:` line. A blank-*looking* line containing a
space survives, because the test is `raw.isEmpty` rather than a blankness test. So typing a blank
line loses it and typing a space-then-blank line keeps it. Given that four existing tests
(`M1-T-022`…`M1-T-026`) are devoted to byte-exact body preservation, this looks like a gap in a
rule the authors clearly cared about.

### 4.7 `M1-C-041` — `template` and `render` disagree on bytes

`template` emits one blank line between empty sections; `render` emits two. A freshly created card
therefore changes bytes the first time it is saved, with no edit. Both forms re-parse identically,
which is exactly why nothing catches it — every existing test compares *parsed models*, never
bytes. Harmless today; it becomes a spurious diff in any future content-hash, sync or
`git`-facing feature.

### 4.8 `M2-C-027` — a trailing slash on `oldPrefix` silently no-ops the whole rewrite

`rewritePaths(replacingPrefix: "p/", …)` matches neither `p == "p/"` nor `p.hasPrefix("p//")`, so
nothing is rewritten and nothing is reported. The three production call sites all pass paths
without a trailing separator, so this is latent — but the function takes a bare `String` and the
failure mode is total silence.

### 4.9 `M2-C-029` — an empty `newPrefix` produces leading-slash paths

`rewritePaths(replacingPrefix: "p", with: "")` turns `p/q` into `/q`, which reads as absolute to
anything that later joins it against a project root. Also latent (group names are non-empty in
practice), also unreported.

## 5. Three observations that are not defects but changed how I read the modules

1. **`TreeWalk.mutate` and `TreeWalk.remove` apply to EVERY node matching the id, not the first.**
   (`M2-C-012`, `M2-C-013`.) With a duplicated root id, `remove` can empty the forest entirely.
   Nothing in the API says ids are unique, no test exercises a duplicate, and both `StructureItem`
   and `ResearchItem` ids come from `ULID`/`ParagraphID` mints — so uniqueness is an invariant
   held *elsewhere*, by convention, and `TreeWalk` is where that convention would fail loudly if
   it ever broke. Contrast tripwire 23 in CLAUDE.md, which records that a mint-collision *has*
   already happened once in this codebase (`ParagraphID.mint()`, 2026-06-10).

2. **`TreeWalk.collect` descends through nodes that fail the predicate, and a collected node
   carries its whole unfiltered subtree.** (`M2-C-018`, `M2-C-019`.) `collect` is the
   second-most-called walker (36 sites) and this is the property every one of them depends on. It
   was untested. It holds.

3. **An indented `## Swatches` still opens a section** (`M1-C-016`) because structure detection
   runs on a trimmed probe while body storage uses the raw line. That asymmetry is deliberate and
   documented — but it means indentation cannot be used to protect a heading-shaped line in body
   prose, which is the natural thing a writer would try after hitting the documented
   heading-in-body residual.

## 6. Where I think this phase is weak

- **Coverage of the input space is by enumeration, not exhaustion.** I probed the edges I could
  think of. `PaletteCardParser.parse` takes an arbitrary `String`; I sampled maybe forty shapes of
  it. Phase 4's property hammering is the answer to that, and it is the right place to judge
  whether these pins are the *right* pins.
- **I pinned `M1-C-040` (an exact render byte-string) and `M1-C-042` (enum declaration order).**
  Both are true and both are the kind of over-specific pin that turns a harmless refactor into a
  red test. They are in the ledger deliberately — a machine-generated spec that *only* produces
  such claims would be a bad spec, and the ruling sheet should be allowed to kill them. If the
  human pass ratifies pins like these unread, that is itself the falsification the experiment is
  looking for.
- **Two claims are cross-references, not new observations.** `M2-C-015` and `M2-C-018` confirm
  Phase 1 claims that were MEDIUM/INCIDENTAL. I counted them in the characterization total, which
  slightly flatters it; Phase 5's agreement map treats them as Region C, not Region D.

## 7. Artifacts

| Path | What |
|---|---|
| `experiment/01-claims-ledger.json` | Updated: 163 claims (75 EXISTING_TEST + 88 CHARACTERIZATION) |
| `experiment/ExperimentTests/Tests/ExperimentTests/PaletteCardCharacterization.swift` | 52 pinning tests, M1 |
| `experiment/ExperimentTests/Tests/ExperimentTests/TreeWalkCharacterization.swift` | 27 pinning tests, M2 |
| `experiment/ExperimentTests/Tests/ExperimentTests/Support/Probe.swift` | The observation probe (asserts nothing) |
| `experiment/ExperimentTests/Tests/ExperimentTests/Support/Fixtures.swift` | Conformers + the seeded RNG Phase 4 uses |
| `experiment/scripts/02-append-characterization.py` | Reproduces the ledger append |
