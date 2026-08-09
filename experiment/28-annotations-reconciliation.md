# 28 — Reconciliation of the app layer: Document+Annotations

Third app-layer module. `Maugham/OpLog/Document+Annotations.swift` + `AnnotationDeriver` /
`AnnotationInverse` (MaughamCore). Characterised agent-run (worktree, probe-first, five probes),
pinned against HEAD `ea4f4662`, reconciled against the 29-ruling set. Suite promoted directly to
`MaughamTests/Claims/AnnotationsCharacterization.swift` per the permanent-residents discipline —
**41 tests, verified 41/41 green in place by the reviewing session, not only by the author.**

- **53 claims** (`M5-AN-*`), 53 filings, `_summary` recomputed and checked.
- **Coverage 28%** — the lowest app-layer figure (trash 47%, rewind ~59%): the module is mostly
  derivation mechanics a writer never meets. **The writer-proximity result holds.**
- **6 COMPLIES / 9 VIOLATES** over 7 distinct defects; specificity 14/15 = 93%.

## The headline: a live data-loss path under an existing ruling

**M5-AN-049 (RULING-5)** — a span-anchored suggestion whose quoted phrase is GONE is still applied,
and the bare replacement becomes the WHOLE paragraph: measured, "She was livid about the whole
business." + a lost `very angry → furious` anchor accepts to **"furious"**. `SuggestionSplice.apply`
documents the branch as "the safe fallback for a lost anchor" — the exact reading RULING-5 was
written to overturn ("MUST NOT be applied. It is refused, the writer is told why").

**M5-AN-050 (RULING-5)** — the pane's "Paragraph has changed…" confirmation never fires inside the
burst window, so 049 happens with no warning: the gate reads `isStale` off a cache that **no
text-edit path invalidates** (M5-AN-005 — `setParagraph`/`setFullText` don't touch it; only the
burst flush does, ≤30s idle / 90s typing). The probe result came out opposite to the code reading.

## The other defects (all RULING-22 except as noted)

- **M5-AN-039 (RULING-29)** — no Reopen exists anywhere; pinned by a caller census that goes red
  when the fix lands.
- **M5-AN-036** — `annotationReopen` serves two inverses; ⌘Z on "delete my annotation" also
  cancels an archive the writer never undid (note returns OPEN). Tripwire-32 shape, single-device.
- **M5-AN-041** — deleting a paragraph silently closes every open note on it; the typing half of
  the sweep reports nothing while rewind's half must (RULING-28). Asymmetric.
- **M5-AN-030** — Revert on an accepted suggestion whose paragraph is gone: enabled, does nothing,
  says nothing.
- **M5-AN-019 / M5-AN-028** — cross-device races: edit-undo declines to the log only; accepting a
  WITHDRAWN suggestion still rewrites the manuscript with no visible row.
- **M5-AN-047** — see the thread below.

## The verifier's not-chased thread — answered: YES, and it lands in rewind

`handleExternalLogChange` replaces the mirror with a sorted merge (safe), but the next LOCAL append
pushes a lower ULID onto the end when a peer's clock is ahead: the live `_opLogMirror` is unsorted
(M5-AN-046) and `currentFoldBasis`'s "last is newest" doc is false. `Deriver.derive(ops:upTo:)`
correctly refuses to re-sort, so **a rewind to the writer's own newest moment renders the PEER's
text** (M5-AN-047, measured both ways). The annotation projection is unharmed — it compares opIds
rather than trusting order (M5-AN-052), which confines the damage to time travel. → GAP-A6.

## Gaps (6, phrased for Denver) and notable surprises

GAP-A1 blank-replacement suggestions (premise honestly unverified — REW-D9's lesson applied);
GAP-A2 annotation delete has no trash; GAP-A3 a rejection reason vanishes on reopen; GAP-A4 the
silent sweep's replacement behaviour; GAP-A5 resolved notes outliving their paragraph with an
enabled dead Revert; GAP-A6 rewind under clock skew. Full text in the filings and the agent report.

Surprises recorded for the RULING-29 fix: `AnnotationInverse`'s `.noInverse` decline is unreachable
from `reopenAnnotation` (the status switch returns first); reject/archive have no id guards at all;
the closed-document guard covers two of seven mutators; the sweep's craft-note carve-out is
redundant by construction. RULING-5 scored a COMPLIES and two VIOLATES in the same function, ten
lines apart — the span re-resolution honours it; the lost-anchor fallback abandons it.

## Recommended fix order (adopted into PLAN.md phase 1)

**M5-AN-049+050 first** — live data loss on the writer's prose, ruled by an existing RULING-5, fix
is a refusal plus a cache invalidation. Then RULING-27+28, then RULING-29's M5-AN-039 with
M5-AN-036 and GAP-A3 as things that fix must not walk into.
