# The standing plan — approved by Denver, 2026-08-08

Four phases, each with an exit condition. Update this file when a phase closes or a decision
lands; the queue detail lives in `START-HERE.md`, the numbers in the generated state block.

## Phase 1 — finish what's in flight (branch `experiment/behavioural-spec`)

1. ~~`Document+Annotations` characterisation~~ **DONE 2026-08-08** — 53 claims, 6/9, and the
   register's most serious find yet: M5-AN-049/050, a live data-loss path under RULING-5.
2. **RULING-5 fix loop — M5-AN-049+050, jumped the queue** (adopted from the module report): a
   lost-anchor suggestion must be REFUSED, not applied over the whole paragraph; and the staleness
   cache must invalidate on text edits so the warning gate actually fires. Live data loss on the
   writer's prose outranks reporting polish — the constitution's first must.
3. **RULING-27+28 fix loop** — nearest-surviving-moment with revert + both halves of the
   collateral report. One loop: they share the restore boundary and its rendering. Pins some
   UNTRACED view-layer facts (the `_ =` discard, the impact summary) with production tests.
   RULING-28's scope now also covers M5-AN-041's silent typing-sweep by analogy — file, don't
   assume; the typing half may need its own ruling.
4. **RULING-29 fix** (pane Reopen) — now WITH its pinned claims (M5-AN-039's caller census goes
   red when the fix lands). Must not walk into M5-AN-036 (the double-inverse reopen op) or GAP-A3
   (the vanishing rejection reason); the module report records both.
5. **Whole-branch review, then merge to main.** Three rebases now; every pre-merge day is drift
   risk, and the claims suites protect nothing until they run on main.

*Exit: branch merged, CI green on main.*

## Phase 2 — pay down the known debt (from main)

**Absorbed 2026-08-08 from the formal-methods spike** (branch `formal-methods-spike`; findings in
`docs/superpowers/notes/2026-08-01-formal-methods-spike-findings.md`; models are the acceptance
tests — the violating config stays red against HEAD, green against the fix, falsification pair
stays red):

- ~~**FM-1**~~ **DONE 2026-08-09** — per-device partitioning via PartitionedJSONLFile; the two
  silent-regression traps (sidecar routing, backup-signature exclusion) closed with it. Residuals
  deliberately not touched, from the findings: §8.2 (checkpoint outrunning its op → healthy
  project refuses backups; needs the unpropagated-vs-lost design call) and §8.4 (conflictTwins
  scans only ops/ — small, independent, now MORE worth doing).
- ~~**FM-2**~~ **DONE 2026-08-09** — intactness-aware prune + skip-detection, STRICTER than
  findings §10.5's prescription because the prescribed rule fails its own property (reasoned in
  code and model). formal/ now lives on the branch as acceptance infrastructure.
- **FM-3** accept+reject cross-device race: status and spliced text settle in disagreement —
  **GAP-A7, needs Denver**; do not fix ahead of the ruling. Same root the register pinned as
  M5-AN-028 and rewind's stranded-accept apparatus; the model proved the convergence case our
  method marked UNTRACED.
- **FM-4** a checkpoint landing before its pinned op makes isHealthy false and REFUSES backups —
  care-flagged; read findings §8 before any durable reaction to a perceived op-set gap.

**The methods pipe** (adopted): register UNTRACED items that are multi-device → model-checking
candidates; formal "needs a semantics decision" outputs → gap-queue entries; model-checked
properties → a new `enforced_by` level. GAP-A6 and the spike's §5.1 clock-skew observation merge
into one ruling question.

5. Trash's 11 filed violations triaged: fixable-now under existing rulings (the three `InboxStore`
   hard-deletes, RULING-15; unreadable-note-opens-blank, RULING-7) vs gated on the parked
   research-protection milestone — the latter ROI-parked explicitly under PRINCIPLE-4.
6. A trash-gap ruling sitting: the 6 remaining gaps, batched structured questions, mixed
   recommendation/no-recommendation, acceptance rate tracked.
7. The `enforced_by` gradient: classify every RATIFIED ruling (test / tripwire / type /
   prose-only); build mechanisms for enforceable prose-only ones — RULING-15 first (typed-mover
   shape, already proven on user content).

*Exit: zero LIVE violations neither fixed nor explicitly parked.*

## Phase 3 — graduate the layer

8. Out of `experiment/`: rulings, reconciliation, protocol and scripts to a first-class home
   (name is Denver's); phase reports archived as history; decoy-file warnings compressed to one
   paragraph of history.
9. **The owed falsification: `Promotion*.swift`** — characterise the module where the SURVEYS did
   well, at the graduation gate deliberately. If the headline results survive their hardest test,
   they go in the graduation write-up; if not, better to know before scaling.

*Exit: a named, homed layer with a steady-state definition (writer-facing modules claim-covered;
amendments trigger re-checks; fix-loop in the default workflow), results survived falsification.*

## Phase 4 — turn it forward-facing

10. Module sweep by writer-proximity (MCP/Tools per RULING-21, InboxStore, checkpoint paths) —
    and STOPS below the proximity threshold. TreeWalk taught us the floor. Budget ~a session per
    module; the worthwhile set is roughly five or six more, not twenty.
11. **New features ship WITH claims**: specs cite rulings at design time, implementation lands
    with claims filed, reconciliation happens before merge. Characterisation becomes
    legacy-only; the intent→spec gap closes at the source. This is the endgame.
12. Steady-state health: the register check folds into the maintenance-audit cadence — claims
    green, amendment queue empty, plus a periodic sampled independent re-filing (the 5/5
    verification becomes a recurring spot-check).

## Decision points reserved for Denver

- Merge timing (recommended: soon after phase 1's loops close).
- The trash-gap sitting's scheduling.
- The graduated layer's name and home.
- How far the phase-4 sweep goes.
