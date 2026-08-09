# Phase 0 — Recon and module selection

**Experiment:** can the behavioural claims that constitute Maugham's implicit specification be
generated mostly by machine, leaving a small residue that needs human authorship?

**Date:** 2026-08-01 · **HEAD:** `db1bea2c` · **Working tree:** clean at start.

---

## 1. Codebase shape

| Region | Swift files | Role |
|---|---|---|
| `Packages/MaughamCore/Sources/MaughamCore/` | 76 | Shared substrate. Apple frameworks only, **no UI imports**. Consumed by both the Mac app and the phone app. |
| `Maugham/` | ~330 | macOS app — AppKit/SwiftUI, editor, stores, MCP server, canvas, publish. |
| `MaughamPhone/` | ~60 | iOS companion. |
| `maugham-mcp/` | small | MCP binary shim. |
| `Packages/MaughamCore/Tests/MaughamCoreTests/` | 60 | Core test target. |
| `MaughamTests/` | 212 | Mac test target. |
| `MaughamPhoneTests/` | ~25 | Phone test target. |

The selection pool was restricted to `MaughamCore`, because criterion (a) — *non-trivial logic,
minimal UI entanglement* — is structurally guaranteed there: the package manifest forbids UI
framework imports, so every candidate is pure or near-pure.

I ranked all 76 core sources by LOC, count of `public` declarations, count of dedicated test
functions, and count of reverse-dependency call sites in `Maugham/` + `MaughamPhone/` +
`maugham-mcp/`. The full sweep is reproducible with the shell in §5.

---

## 2. Selection

### Module 1 (comparatively **well-tested**) — `PaletteCard.swift`

`PaletteCard` + `PaletteCard.Kind` + `PaletteCard.Sense` + `PaletteCard.SensoryNote` +
`PaletteCardParser` + `PaletteCardRenderer`.
Path: `Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift` (314 lines).

A parse/render pair over a markdown "sensory palette card" format. Cards are real files under
`research/palette/`; the model owns the file and re-rendering normalizes it. The header comment
asserts a round-trip law — `parse(render(card)) == card` — and then names two documented
residuals against it.

**Why it qualifies**

- *(a) Non-trivial logic, no UI.* A hand-rolled line-oriented parser with a five-state section
  machine, a "capture `kind:` once, before any real section" rule, byte-preserving body capture
  with exactly one layer of structural blank-line framing peeled off, hex-colour validation with
  `#RGB`→`#RRGGBB` expansion, and `..`-collapsing relative-path resolution with a matching
  inverse. Zero I/O, zero UI, fully deterministic.
- *(b) Reverse dependencies.* 133 call-site lines across 20 non-test files, spanning stores,
  canvas promotion, MCP tools, Mac views and **phone** views.
- *(c) Well-tested.* 24 dedicated tests in 2 dedicated core test files, plus 12 further test
  files that exercise it downstream.

### Module 2 (comparatively **under-tested**) — `TreeNode.swift`

`TreeNode` protocol + `TreeWalk` enum (10 generic static functions).
Path: `Packages/MaughamCore/Sources/MaughamCore/TreeNode.swift` (179 lines).

The generic tree-walking substrate. `StructureItem` (the binder) and `ResearchItem` (the research
tree) both conform; `TreeWalk` replaced per-type hand-rolled recursion that had drifted across
the codebase (`d3029ca9 refactor: migrate all tree-walk call sites to TreeWalk; delete copies`).

**Why it qualifies**

- *(a) Non-trivial logic, no UI.* Pre-order DFS semantics, a persistent (copy-on-write) `mutate`
  whose ordering is subtle — children are transformed *before* the parent match is tested — a
  `leaves` definition keyed on children-emptiness rather than node type, and a prefix-rewrite rule
  with a documented boundary condition that reconciles two previously divergent implementations.
- *(b) Reverse dependencies — the strongest in the pool.* **105 call-site lines across 36
  non-test files**, on both platforms. Method histogram:
  `find` 42 · `collect` 36 · `first` 8 · `contains` 6 · `rewritePaths` 3 · `mutate` 3 ·
  `collectIds` 3 · `remove` 2 · `leaves` 2.
- *(c) Under-tested.* **One** dedicated test file, 12 tests, 180 lines.

---

## 3. The contrast, quantified

| | **M1 `PaletteCard`** | **M2 `TreeNode`/`TreeWalk`** |
|---|---|---|
| Source LOC | 314 | 179 |
| Public types | 6 | 2 (1 protocol, 1 namespace enum) |
| Public functions / computed properties | 5 (`color(fromHex:)`, `template`, `parse`, `render`, `relativize`) + `id` | 10 generic statics |
| Public stored properties / cases | 9 stored + 4 `Kind` cases + 5 `Sense` cases + 2 initialisers | 2 protocol requirements |
| **Public surface total** | **25** | **12** |
| Dedicated test files | 2 | 1 |
| Dedicated test functions | 24 | 12 |
| **Tests per 100 source LOC** | **7.6** | **6.7** |
| Test files touching it *as a subject* | 2 | 1 |
| Test files touching it *at all* | 14 | 13 |
| Non-test call-site lines | 133 | 105 |
| Non-test files depending on it | 20 | 36 |
| Cross-platform (Mac + phone) | yes | yes |

**The headline density numbers are close (7.6 vs 6.7) and that is misleading — the real contrast
is coverage per unit of public surface and per unit of dependency.** Three sharper cuts:

1. **Tests per public API member:** M1 = 24/25 ≈ **0.96**. M2 = 12/12 = **1.00**. Still close —
   but M2's twelve tests are not evenly spread: reading `TreeNodeTests.swift`, `find`, `contains`,
   `collectIds`, `first`, `collect`, `mutate`, `remove` and `idsByPath` get **one test each**,
   `leaves` gets two, `rewritePaths` gets two. There is no test file anywhere for a second
   `TreeNode` conformer, no empty-input test, no duplicate-id test, no cycle/aliasing test.
   M1 by contrast has four tests on the body-byte-preservation rule alone.
2. **Tests per dependent file:** M1 = 24/20 = **1.2**. M2 = 12/36 = **0.33**. M2 is depended on
   ~1.8× more widely and tested ~3.6× more thinly relative to that.
3. **The asymmetry that decided it.** `TreeWalk` appears in 13 test files. In **12 of them it is a
   fixture helper, not a subject** — tests call `TreeWalk.find(...)` to locate a node so they can
   assert something about *another* module. So the codebase's tests lean on `TreeWalk`'s
   correctness far more than they check it. That is the shape of an under-specified surface, and
   it is exactly the region the experiment is trying to make visible.

Both modules are pure, deterministic and I/O-free, which keeps Phase 2 characterization honest:
almost nothing here should need the `non_deterministic` escape hatch. The one thing I expect to —
and will flag rather than pin — is `TreeWalk`-adjacent ordering that depends on Swift `Dictionary`
iteration order, and `PaletteCardParser`'s behaviour under the `Set`-backed dedup in
`imagePaths`. (Note the sibling `ShingleMatcher.bestMatch`, which I did *not* select, documents
"first-encountered wins on an exact tie — Dictionary iteration order" as a contract; that is a
latent non-determinism claim in the neighbourhood and I mention it only so it is on record.)

---

## 4. Candidates considered and rejected

| Candidate | LOC | Why not |
|---|---|---|
| `FountainTokenizer` | 1173 | Best-tested module in the pool (differential + reference implementation, 25 test files) but too large to claim complete claim-extraction over inside this experiment. Would bias the result toward "machine generation doesn't scale" for reasons of budget, not principle. |
| `OpLogStore` | 395 | Heavy file I/O + device-partitioning + sealing. Violates the "characterization tests must be deterministic and pinnable" premise; too many claims would land in the non-deterministic bucket. |
| `ShingleMatcher` | 118 | Excellent pure-logic property-test target, but only **3** reverse-dependency files. Fails criterion (b). |
| `FileNaming` | 119 | Genuinely under-tested and fiddly (regex collision-suffix rules), but only **2** reverse-dependency files. Fails criterion (b). Strong reserve pick if `TreeWalk` proves too thin. |
| `CollaborationRole` | 192 | Looked untested (0 hits on the filename token) — a **false signal**: `ShareIdentityMapperTests` and `ReviewPosturePolicyTests` cover the types inside it. Recorded here because the same false signal would corrupt any purely name-keyed coverage metric. |
| `MarkdownBlockParser` | 306 | Very strong alternative well-tested pick (36 tests incl. a parity corpus). Passed over only because `PaletteCard` *depends on it* (`findInlineImages`), and I wanted the two chosen modules independent of each other. |
| `SafeRelativePath`, `SpanAnchorResolver`, `SuggestionSplice` | <150 | Fine modules; each has fewer than 8 reverse-dependency files. |

---

## 5. Harness (already verified working)

Nothing existing is touched. The generated tests live in a **standalone SPM package** that
path-depends on `MaughamCore`:

```
experiment/ExperimentTests/
  Package.swift                          # depends on ../../Packages/MaughamCore
  Tests/ExperimentTests/*.swift
```

Re-run with:

```sh
swift test --package-path experiment/ExperimentTests
```

Verified against HEAD: builds in ~10s, smoke test reaching both modules passes. Neither
`Packages/MaughamCore/Package.swift`, `project.yml`, nor any existing test target is modified, so
the shipping Mac and phone suites cannot be perturbed by anything this experiment produces.

Reproducing the selection sweep:

```sh
for f in Packages/MaughamCore/Sources/MaughamCore/*.swift; do
  b=$(basename "$f" .swift)
  loc=$(wc -l < "$f" | tr -d ' ')
  pub=$(grep -cE '^[[:space:]]*public[[:space:]]' "$f")
  calls=$(grep -rhoE "\b$b\b" --include='*.swift' Maugham MaughamPhone maugham-mcp | wc -l)
  echo "$b loc=$loc pub=$pub calls=$calls"
done | sort -t= -k2 -rn
```

---

## 6. What I need from you

Confirm the pair:

- **M1 (well-tested):** `MaughamCore.PaletteCard` — `PaletteCard`, `PaletteCardParser`, `PaletteCardRenderer`
- **M2 (under-tested):** `MaughamCore.TreeNode` — `TreeNode`, `TreeWalk`

Two notes worth your reaction before I proceed:

1. **`TreeWalk` is thinner than the raw density number suggests** and that is the point — but if
   you think 12 tests over 179 lines is "adequately tested" and the contrast is therefore too
   weak, the reserve pick is `FileNaming` (9 tests, 119 lines of genuinely gnarly regex collision
   logic) at the cost of dropping from 36 dependent files to 2.
2. **I will not be using subagents** for this experiment, despite `CLAUDE.md`'s default. The
   session's operating instructions bar the Agent tool absent an explicit request, and the
   experiment needs one consistent judge across Phases 1–5 anyway — a fan-out would make the
   Arm A / Arm B separation in Phase 3 unenforceable, since I cannot verify a subagent honoured
   "do not consult the tests".

**Stopping here for your confirmation.**
