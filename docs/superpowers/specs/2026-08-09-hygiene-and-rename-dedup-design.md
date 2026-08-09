# Hygiene + rename durability — the enforcement ladder's gap, the doc drift, and W2's last sibling

**Date:** 2026-08-09
**Source:** Issues #27 (audit F2, F3, F4, S4, S8; S3 verified already-fixed) and #31 (sweep S1 of 2026-07-26 — the W2-class residual), combined per Denver.
**Decided with Denver:** one branch, both issues; the audit's "DocSync ledger↔catalog reconciler at tagged commits" suggestion dropped as YAGNI.

## 1. Scope

### 1.1 F2 — tripwire 25 gets its grep guard (the one real enforcement item)

Tripwire 25 (no `.scaleEffect` / no `NSScrollView.magnification` for canvas zoom) is the only canvas tripwire whose failure is silent (blurred text; clicks stop registering at ≥2×) and the only one with zero recurrence protection. Add a `TripwireGrepTests` census banning `.scaleEffect(` and `.magnification` assignment in production sources under `Maugham/Canvas/`, following the TW13/14/17 pattern (comment-line exclusion as the siblings do it), plus a planted-offender meta-test in the file's existing self-check section proving the guard fires. `CanvasCameraTests` keeps owning the coordinate math; this guard owns recurrence.

### 1.2 Doc-truth (F3, F4, S4, S8)

- **F3:** `docs/roadmap.md:11` — flip the MCP-clock-tests `•` to `✓`, one line summarizing the 2026-08-08 parallel-workers resolution (CLAUDE.md:~154 and the 2026-07-29 note's Resolution section are the sources).
- **F4:** the roadmap's M1C "left open" line — reword to "no route to select (and therefore delete) a line" (the VoiceOver gap is selection, not deletion; ⌫ works once selected).
- **S4:** the roadmap gains the missing Group-3 line for PR #17 (publish-pipeline improvements, shipped `read_preview_page`, the undocumented 51→52 tool-ledger step, merged 2026-07-23). The reconciler suggestion is dropped: both ledger endpoints are already `DocSync`-pinned; a tagged-commit historical checker is speculative machinery with no live failure.
- **S8:** CLAUDE.md's Canvas cell "count the arms in `PromotionCommandTests`' wiring census" — correct the pointer to say the census counts wiring SITES; name `Promotion.targets` (and `ItemInspector`'s promote affordance) as where the promotable subject KINDS live. Add a kind-count assertion to `PromotionCommandTests` only if it lands as a one-liner against an existing enumeration; otherwise prose-only (no new census machinery for a pointer fix).
- **S3:** already fixed (CLAUDE.md's Views cell reads "read them off `MaughamApp`'s bindings" since the M1A sweep) — close on the issue with the verification note; nothing in this branch.

### 1.3 #31 — `renameResearchPath` joint dedup (finishes W2)

`renameResearchPath` (`Maugham/Stores/ProjectStore+Research.swift:664`) dedups only the `.md` leaf via a `fileExists` loop, then moves `<oldSlug>_assets → <dedupedSlug>_assets` against a destination that was never checked. An orphaned `<dedupedSlug>_assets/` (manual delete, prior partial failure) makes the assets move throw AFTER the `.md` move committed → manifest↔disk divergence, the exact class W2 fixed for `moveResearchItems`. Fix: generalize/reuse `researchDedupedNotePair` (`ProjectStore+ResearchMove.swift:286`) so the rename picks a slug whose `.md` AND `_assets` destinations are both vacant BEFORE any move commits. Same coordinated-move discipline the function already uses (typed mover, tripwire 14 — the moves themselves already route correctly; only the dedup choice changes).

## 2. Testing

- F2: the planted-offender meta-test (fires on a planted `.scaleEffect(` in a temp source), plus the census passing on the real tree.
- #31: repro test — create note + assets, plant an orphaned `<dedupedSlug>_assets/` at the rename destination, rename → BOTH land at a jointly-deduped slug, manifest matches disk, no throw; regression pass on existing rename/move tests (`renameResearchPath` and W2's `moveResearchItems` suites).
- Doc edits: verified by reading; F3/F4/S4 have no test surface (roadmap is prose; the audit's reconciler idea is declined above).

## 3. Out of scope

- Any new DocSync check for the roadmap ledger (declined, YAGNI).
- The `CanvasViewMounting*` families and camera behavior (F2 is a grep guard, not runtime).
- Anything else in #28–#30/#32.
