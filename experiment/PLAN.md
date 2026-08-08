# The standing plan — approved by Denver, 2026-08-08

Four phases, each with an exit condition. Update this file when a phase closes or a decision
lands; the queue detail lives in `START-HERE.md`, the numbers in the generated state block.

## Phase 1 — finish what's in flight (branch `experiment/behavioural-spec`)

1. `Document+Annotations` characterisation lands (agent-run, worktree, probe-first) → review,
   commit; the module where RULING-25/26/29 live gets pinned claims.
2. **RULING-27+28 fix loop** — nearest-surviving-moment with revert + both halves of the
   collateral report. One loop: they share the restore boundary and its rendering. Pins some
   UNTRACED view-layer facts (the `_ =` discard, the impact summary) with production tests.
3. **RULING-29 fix** (pane Reopen) — deliberately AFTER the annotations module is claim-covered,
   so the fix lands against pinned claims.
4. **Whole-branch review, then merge to main.** Two rebases already; every pre-merge day is drift
   risk, and the claims suites protect nothing until they run on main.

*Exit: branch merged, CI green on main.*

## Phase 2 — pay down the known debt (from main)

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
