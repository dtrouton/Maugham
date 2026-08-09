# Delta since the trash reconciliation

Read this after `experiment/RECONCILE.md`. It records what changed as a result of your run.

## Your three corrections were accepted

**1. RULINGS.md was defective and is now fixed.** You flagged that D11 convicted under RULING-19
while quoting a clause the file did not contain. You were right: the extraction script emitted only
`family`/`statement`/`basis` for the three ROOT rulings, so RULING-19's `corollary_RULED` — *"a
repair firing at a lower layer means a guard above did not fire — that is a BUG"* — was silently
dropped. That clause **reverses** the ruling: without it R19 licenses a silent lower-layer repair;
with it a repair is a defect signal. Four clauses have been restored across the roots.

**Re-check your D11 filing against the repaired file.** Your conclusion was probably right, but it
was reached from a damaged artifact.

**2. Your RULING-15 sampling-artefact argument is accepted and supersedes the earlier finding.**
The Phase 19 claim — that specificity tracks whether a ruling was derived from a case in that area —
was built on decision surveys, which sample the *residue a ruling set leaves*. That is selection
bias. `experiment/19-scaling-sweep.md`'s headline is superseded by your framing: a decision survey
and a claim ledger are two statistics that should not be compared.

**3. The comply/violate inversion is recorded as a primary result.** 31:1 on MaughamCore's pure
modules, 13:11 on the app layer. The "97% of what a ruling reaches is already right" line is a fact
about pure, writer-distant code and is not restated about the codebase.

## Two new rulings, one of which resolves your GAP-2

**RULING-24 (new ROOT, TIERED shape)** — deleting state is not deleting history. Protection is
tiered, and the boundary is practical economics:

- **The work** (prose, screenplay) — protected at all costs, version-controlled, every change
- **Research** — recoverable, not versioned
- **Ingested/derived** (a promoted voice note, a cache, a render) — not protected

**This resolves GAP-2 by showing my reading was wrong, not Denver's ruling.** The op log surviving
"permanently delete" is not a contradiction: trash deletes STATE, history retention is a separate
contract, and for a manuscript the history is kept *because* the work is protected at all costs.
RULING-23 stands as ruled.

**But one clause of RULING-24's basis was verified FALSE.** Denver said research relies on ⌘S plus
filesystem backups. ⌘S covers nothing: `allDocIds = documentIds(in: manifest.STRUCTURE)` (the
manuscript binder, not `manifest.research`), and `Checkpoint.docPointers` is `[docId: opId]` —
pointers into op logs, which research notes do not have. **Research's only recovery is filesystem
backups, outside Maugham entirely.** This raised `M1-C-055`'s severity and produced
`experiment/MILESTONE-research-protection.md`.

## A new class of finding, and a possible seventh template field

Two cases in one exchange of **"a ruling resting on a belief about the code that does not hold"** —
once me misreading, once the product owner mis-remembering their own architecture. Neither is
visible to a test, and neither is caught by the six-field template, which forces *scope* but not
*premise*.

**Consider adding `premise_verified` (with a call path) to any ruling you propose.** A ruling made
on a false premise propagates further than a claim filed under the wrong ruling. If you find the
field useful, say so; if it is bureaucratic overhead, say that instead.

## Your next module

**`Maugham/OpLog/Document+Rewind.swift` + `Document+RewindUndo.swift` + `Deriver+Rewind.swift`.**

Three reasons, and there is a prediction attached that you can falsify:

1. **It tests whether your sampling-artefact correction generalises.** Rewind scored 20%
   specificity on the decision survey — the second lowest after trash's 0%. If pinned claims lift it
   the way they lifted trash (0% → 79%), the correction holds. If rewind stays low, it does not, and
   the original finding was partly right.
2. **RULING-22 ("never surprise the writer; controls do what they say") was authored FROM rewind's
   survey findings.** Reconciling rewind against a ruling derived from rewind is the cleanest
   available test of whether a ruling made from hand-picked decisions survives contact with the full
   claim set of the area it came from.
3. **It is RULING-24's tier-1 mechanism.** Rewind is *how* the work is protected at all costs, so a
   defect there is a defect in the protection itself.

Known unverified claims in this territory, from the survey (`experiment/sweep2/Rewind.json`) —
treat as leads, not facts:

- the confirm sheet's impact count is a modal-open snapshot; another device writing during the
  session is not counted
- a rewind auto-archives open annotations without mentioning them in the count
- `Deriver.derive(ops:upTo:)` returns the FULL derivation when the cursor's op id is not found, so
  Restore silently lands on "now"
- `M1-C-056` is already filed: the per-op control says "Rewind to before this…" and
  `ops.prefix(through: idx)` is inclusive, so it lands after

Same rules as before: worktree, probe before you assert, `UNTRACED` rather than a guess, gaps
phrased as product statements a non-programmer can rule on.
