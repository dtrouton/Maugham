# 29 — Promotion: the falsification module

The module the old survey method scored BEST (75%) — characterised straight so the numbers could
speak, at the phase-3 graduation gate deliberately. Agent-run (worktree, probe-first, three
probes), pinned on `claude/spec-phase-3` from main `5aa873af`, suite promoted to
`MaughamTests/Claims/PromotionCharacterization.swift` (37 methods, re-verified in place by the
reviewing session).

## Numbers

**78 claims · 62% coverage · 42 COMPLIES / 6 VIOLATES (5 distinct defects) · specificity 81%.**
The app layer's first violations since the fix loops reached 83:0 — a fresh module doing its job.

## THE FALSIFICATION VERDICT — the correction holds, and its magnitude is now bounded

**Survey 75% → ledger 84% (against the 2026-08-02 ruling set, the phase-24 confound method) →
81% (current set).** Direction holds a third time, on the module picked to break it. Magnitude
collapses (+9, vs rewind's +47 and trash's +79) — exactly what the sampling account predicts: a
survey scoring 75% has little residue-vs-measure gap left to recover. Honest bound: ±several
points of filing judgement.

**New method finding, pointing the other way for the first time**: ruling-set growth LOWERED
specificity here (84 → 81) because RULING-24 is a ROOT absorbing cases RULING-4 would catch as a
sub. "Specificity" measures the sub/root mix, so it falls whenever the set grows at the root —
rewind's +13-from-new-rulings is not general.

## The five defects

1. **M6-PR-037 (RULING-24)** — Rewrite atomically replaces a research note with no backup: no op
   log, no checkpoint walk, no trash copy. The same words DELETED would be restorable (R15);
   rewritten, they are gone. Consent is not a recovery route.
2. **M6-PR-038/039 (RULING-22)** — Rewrite reverts the writer's rename (and renames the backing
   file back): the sheet's Name field, seeded from the card and never re-seeded, silently wins
   over the two labels naming the writer's title.
3. **M6-PR-040 (RULING-22, "promotion duplicate" by name)** — a second `.new` promotion duplicates
   AND silently moves the card's mark off last week's note. Most arguable; retires to enhancement
   if the mark is judged internal.
4. **M6-PR-075 (RULING-22)** — a link-write failure throws AFTER the artifact exists, the region
   is marked and contributions are stamped, under a contract that says "validate first, write
   second. A refused promotion leaves nothing behind."
5. **M6-PR-077 (RULING-22)** — "Undo Promote Scrap" takes back the mark only. Second most
   arguable; ADR 0026 §5 could be ratified with an honest label instead.

## Gaps for Denver (P1–P7)

Rewrite keeps a reachable previous version (P1, overlaps research-protection); a post-promotion
rename is the writer's (P2); wiki-link identity under labels (P3); multi-artifact contribution
records (P4); undo's honest scope (P5); a failed operation says what it DID do (P6); re-promotion
says the mark will move (P7). Full text in the filings and the agent report.

## Probe-beat-the-reading (three)

Validate-first fails once links are accepted; referenced pictures vanish when a caller omits the
item index; `linkAlreadyPresent` is a substring test that answers asymmetrically.
