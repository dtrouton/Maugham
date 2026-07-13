# Palette-hardening milestone — 2026-07-13

Executes the ten still-valid findings from the 2026-07-12 sweep (S6 already
resolved by the weekend A1 funnel). Split into 5 disjoint-file work units so
subagents run in parallel without write conflicts. Agents make edits + tests;
they do NOT run xcodebuild (shared DerivedData/simulator contention). The
authoritative full Mac + phone build runs once at the end, with a fix-loop,
then a whole-branch review, then smoke.

## Design decisions (baked into dispatch)

- **S1** — eager one-shot role heal at project load for the legacy path
  (`research/palette`) / filename (`craft-intent.md`), so the window closes
  before any rename is reachable. Heal on load, not lazy-on-lookup.
- **S3** — phone aim senses derive from `PaletteCard.Sense.allCases.map(\.rawValue)`;
  add a parity guard so the literal can't silently drift.
- **S5** — guard the `.text` promote branch like `.audio` (throw
  `nothingToPromote`) AND have the renderer skip fully-empty untagged notes,
  so an empty note can neither be created nor silently dropped.
- **S7** — `case unknown(String)` preserving the raw value across a
  cross-version round-trip (custom Codable), matching ADR-0015's safe pattern
  more faithfully than a lossy `.unknown`.
- **S8** — make `appendSensoryNote` idempotent (skip an identical note) so a
  retry can't double-append, AND surface the status-flip failure instead of
  swallowing it.
- **S10** — add a shared child-filter helper to `PaletteLookup`; delegate all
  three duplicated call sites.
- **S2 / S4** — doc-truth: registry row for the role-lookup substrate, correct
  the false "no phone consumer" prose, and make AREA.md's "parity-tested"
  claim true with a real shared-fixture parity test (or reword if a
  cross-target fixture is infeasible).
- **S9** — `read_inbox_entry` uses the same ISO8601 date encoding as `list_inbox`.
- **S11** — pin "title ignored for palette promotes" with a test.

## Work units (disjoint write sets)

| Unit | Findings | Owns (writes) |
|---|---|---|
| P1 | S1, S3, S10 | PaletteConvention, ProjectStore+Palette, ProjectStore+CraftIntent, PaletteLoading, PaletteAimPicker, project-load path, their tests |
| P2 | S5, S8 | InboxStore, PaletteCard, their tests |
| M  | S9, S11 | InboxTools, InboxToolsTests |
| S  | S7 | ResearchItem, its tests |
| D  | S2, S4 | cross-surface-contracts.md, MaughamPhone/AREA.md, new parity test |

Cross-file compile coupling (e.g. S7's enum-shape change vs P1's role usage)
is resolved in the final build fix-loop, not by the editing agents.
