# Phase 9 — Predictions, recorded before the regeneration ran

Written after the brief was built and before any agent saw it, so the result can falsify me.
Timestamps are enforced by git: this file is committed/created before `10-regeneration-results.md`.

## Setup

- **Module:** M2 `MaughamCore.TreeNode` / `TreeWalk` — chosen over M1 because it has 36 downstream
  files and 105 call sites, and because 12 of the 13 test files touching it use it as a *fixture
  helper* (`M2-B-01`), which makes downstream test breakage unusually informative.
- **Brief:** `experiment/08-regeneration-brief.md` — 63 claims, 26 intent clauses, bare public
  signatures. No implementation, no doc comments, no test source, no commit messages. A leak guard
  in `scripts/08-build-regen-brief.py` fails the build if implementation tokens or verbatim doc
  comment lines appear.
- **Clauses given UNRULED**, including the three I judged hallucinations in Phase 5 (`M2-A-16`
  ids-are-unique, `M2-A-20` stay-recursive, plus `M2-A-19` out-of-scope). This is deliberate: the
  ledger's honest state is unruled, and I want to know whether bad clauses cause harm.
- **Control:** the same worktree at `db1bea2c`, unmodified, must pass first.

## What I predict

1. **It compiles.** Signatures are given verbatim; the risk is near zero. *(Low information — I
   include it only so a compile failure counts as a surprise.)*

2. **`TreeNodeTests` (12 tests) passes.** 27 claims cover 12 tests; the coverage is dense and the
   claims were derived from those very tests. If this fails, claim extraction is worse than Phase 1
   suggested.

3. **My headline prediction: the first real breakage is COMPLEXITY, not behaviour.** Nothing in
   163 claims or 55 clauses says one word about algorithmic cost. A plausible reading of the brief
   implements `collect(where:)` as "flatten, then filter", or `find` as "collectIds, then locate",
   or `contains` as `collectIds(...).contains(id)` — all behaviourally identical, all with worse
   constant factors or complexity. CLAUDE.md **tripwire 4** exists because per-row tree work went
   O(N²) and produced visible load pauses in Phase 3d, and `MaughamTests/Performance/` +
   `AdversarialPerfReviewTests` exist to catch it. **A performance test is my single most likely
   downstream failure**, and it would be the cleanest possible demonstration of an implicit
   contract the claims layer cannot express.

4. **`rewritePaths` goes one of two ways, and both are findings.**
   - If the agent implements the *semantic* rule, it will normalise a trailing separator and
     **silently fix the P13 defect** — producing code better than the original that nonetheless
     contradicts pinned claim `M2-C-027`.
   - If it implements `M2-C-027` literally, it **faithfully reproduces the bug**, which is the
     ossification risk made concrete.

   I lean slightly toward the second, because `M2-C-027` is stated flatly and the brief says
   "satisfy every claim".

5. **`M2-A-16` ("ids MUST be unique") will cause visible harm.** It is false, it is in the brief,
   and an implementer who believes it has licence to early-return from `mutate`/`remove` after the
   first match. That breaks `M2-C-012`/`M2-C-013` — which are also in the brief, and contradict it.
   **I expect the agent to notice this contradiction and flag it.** If it does, that is the
   escalation path working; if it silently picks one, the artifact failed to surface a conflict it
   contained.

6. **1–3 downstream failures in the Mac suite**, most likely in `Performance/`,
   `ProjectStoreReorderTests`, or one of the `Canvas/Promotion*` tests. I do not expect a
   phone-suite failure.

7. **What I predict will NOT break**, because the claims cover it well: pre-order everywhere,
   `leaves`' childless-branch rule, `mutate`'s child-before-parent ordering, `idsByPath`'s
   last-writer-wins, the empty-forest cases, `collect` not pruning below a failing parent.

## What would falsify the claims-as-durable-artifact thesis, on this test

- **Strong support:** compiles, both suites green, and the agent's ambiguity list is short.
- **Interesting support:** a small number of downstream failures, each naming a specific implicit
  contract that could be written down and added to the ledger. This is what I expect.
- **Against:** many failures, or failures that resist being expressed as a claim at all (timing,
  emergent interaction, "it just feels wrong"), or a green run achieved only because the
  regenerated code accidentally matched an accident.

## The measurement I care about most

Not the pass rate. **Every downstream failure, converted into the claim that would have prevented
it.** If those claims are writable, the thesis survives and the ledger just needs more rows. If
they are not — if the missing contract is complexity, or timing, or "the whole test suite trusts
this as an oracle" — then claims need a category the current schema has no room for, and that is
the more useful result.
