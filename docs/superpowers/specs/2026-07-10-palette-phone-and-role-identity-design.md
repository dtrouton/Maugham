# Palette Everywhere — Role Identity + Phone Capture/Read — Design

**Date:** 2026-07-10
**Status:** Implemented (branch `feat/palette-phone-role-identity`, 2026-07-11)
**Builds on:** `2026-07-09-craft-intent-sensory-palette-design.md` (shipped v0.19.0)
**Roadmap home:** Group 1 follow-on (palette-group rename identity) + Group 5 (iPhone companion)

## Problem

Two things, bundled because they share MaughamCore surface:

1. **Identity-by-path is fragile** (v0.19.0 known issue): the palette group is found by literal path `research/palette`, the craft-intent doc by literal filename `craft-intent.md`. Both are ordinary research items, so ordinary Research affordances can rename them — detaching the wall/MCP/inspector (no data loss, but the linkage dies and the next add mints a duplicate group).
2. **The palette's most natural moment happens away from the desk.** You encounter the tram-rattle and the pre-storm light out in the world — where the phone is. Today the phone can neither feed nor read the palette.

## Component 1 — Durable identity: `ResearchItem.role`

- New optional field on `ResearchItem` (MaughamCore): `role: ResearchRole?` where `ResearchRole` is a typed enum with cases `paletteGroup`, `craftIntent`. Decode per the ADR-0015 pattern: unknown raw values → nil (custom decoder), field absent → nil. **Additive optional — no manifest schema bump**; old apps (Mac + phone) ignore the key.
- **Stamped at creation:** `ensurePaletteGroup()` stamps `paletteGroup`; `createCraftIntent(forPieceId:)` stamps `craftIntent`.
- **Lookups go role-first:** `paletteGroup()` = first research group with `role == .paletteGroup`; `craftIntentItem(forPieceId:)` = asset with `role == .craftIntent` within the scope's research prefix. **Fallback + lazy healing:** when no role match exists, fall back to the current path/filename match and, on hit, stamp the role and save the manifest (one-time self-heal; no migration, per house rule).
- **Rename becomes supported:** renaming the palette group or intent doc through any Research affordance keeps everything wired. The Mac Palette segment (wall header/sidebar) displays the group's actual title. Remove the v0.19.0 "known issue" from user-facing docs once shipped.
- Cards themselves need no role — they are identified by membership in the role-stamped group.
- Uniqueness: at most one `paletteGroup` per project and one `craftIntent` per scope is the invariant; lookups take `.first` deterministically (manifest order); creation is find-or-create so the app never mints a second. (A hand-crafted manifest with duplicates degrades to first-wins, not corruption.)

## Component 2 — Shared substrate moves (tripwire 19)

- `PaletteCard`, `PaletteCardParser`, `PaletteCardRenderer` move from `Maugham/Models/` to `Packages/MaughamCore/` (the pair stays together for drift visibility even though the phone only reads). Existing tests move with them (MaughamCore test target or stay in MaughamTests importing Core — follow where `AnnotationInverse` tests landed).
- New row in `docs/superpowers/notes/cross-surface-contracts.md`: palette card model/parse — **shared-impl tier** (single MaughamCore implementation, both surfaces).

## Component 3 — Capture into the palette (phone → inbox → Mac)

- **Inbox entry gains two additive optional fields** (MaughamCore inbox model): `paletteSubject: String?` (a card title, or free text for a new subject) and `sense: String?` (raw sense tag, one of the five or absent). Old readers ignore them; old entries decode with nils (pin with a legacy-decode test).
- **Phone Capture tab: optional target row.** Default = plain inbox capture (exactly today's behavior). Optional: aim at a palette subject — picker lists the selected project's card titles (read via Core parser); free-text entry mints a new subject name; optional sense chip. **Aiming is never required** — unaimed captures are aimed at promote time on the Mac, or never (absence-is-valid ethos).
- Per-device inbox JSONL partitioning, monotonic `writtenAt`, eviction handling: all unchanged. No new sync surface.

## Component 4 — Read the palette on the phone

- The Read tab's project drill-down gains a **Palette** section: card list (title, kind icon, swatch strip) → read-only card detail (images, swatches, sense-grouped notes, freeform body). Plus a **Craft Intent** row rendering the intent doc — **project scope only in this milestone**; per-piece intent display on the phone is deferred (the drill's per-piece context isn't uniform across project types yet).
- **Strictly read-only.** No card editing on phone: cards are plain files, not op-logged; concurrent phone/Mac writes through iCloud are conflict-twin territory (tripwire 17's cousin). Phone card editing is a future op-logging bet, explicitly out of scope.
- iOS tripwires honored (never assume non-evicted; `startAccessing == false` is not a denial; no `d_`-prefix double-prefixing) per `MaughamPhone/AREA.md`.

## Component 5 — Mac promote lands in cards

- `InboxPane` promote flow gains a destination: **Promote into palette card…** — card picker (pre-selected when the entry's `paletteSubject` matches a card title, case-insensitive; "New card…" option minting a card from the subject text, kind defaulting to `.other`).
- **Photo entries** append to the card's image well (existing `ImagePasteHandler` `_assets` path + `updatePaletteCard`). **Text/transcribed-audio entries** become sensory notes: sense-tagged when the entry carries `sense`, untagged otherwise. (Audio promotes its transcription text, matching the existing promote behavior.)
- **MCP `promote_inbox_entry`** learns the same optional destination params (`palette_card_id` or `palette_subject`) — promote is already within the tool's sanctioned inbox scope (read + promote only). MCP never edits cards directly beyond this sanctioned promote path.

## Component 6 — Free wins + docs

- Sense-pass triage already works on the phone (annotations are annotations) — say so in the guide.
- Guide: sense-pass topic gains a "from your phone" paragraph; phone-relevant help surfaces updated. Roadmap, AREA.md files, contracts registry updated.
- Ships as a **paired release** (Mac v0.20.0 + phone-v0.6.0) — Core inbox/model changes are additive, but the features are cross-surface.

## Out of scope (deferred, not rejected)

- Phone card **editing** (requires op-logging cards — its own milestone if ever).
- Fifth phone tab; freeform canvas; extract-palette-from-image.
- Friendly default titles for synthetic dropped-/pasted- imports (separate small fix, still filed).
- Claude proposing palette additions via annotations (carried forward).

## Testing shape

- Core: parser/renderer tests move intact; `ResearchRole` decode (known/unknown/absent); role stamping at creation; lazy-healing fallback (legacy path-named items get stamped on first lookup); inbox additive-decode against legacy JSONL lines.
- Mac: role-first lookups survive group/doc rename (rename → wall still finds cards; inspector still finds intent); promote-into-card (photo → image, text+sense → tagged note, subject → new card); MCP promote params.
- Phone: card list/detail view-model tests; grep tripwires extend automatically; capture target-row model tests.
- **Cross-surface round-trip integration test** (the tripwire-19 real safety net): phone-shaped inbox entry with palette fields → Mac promote → card re-parses with the new image/note.
- Both schemes run (Core changes): Mac suite + phone suite; Release build (ProjectWindow touched by wall-title display).

## Risks / tripwires touched

- MaughamCore is now in play (unlike v0.19.0): tripwire 19 registry row required; phone grep tripwires must keep passing; both-scheme testing mandatory.
- `ResearchItem` decode changes must stay tolerant in BOTH directions (old JSON → nil role; new JSON on old app → key ignored).
- Inbox schema evolution mirrors the same additive discipline (ADR 0012 partitioning untouched).
- Phone Read drill-down grew a section in phone-v0.2.0 (annotations drill) — mirror its structure; on-device smoke is the verification of record for phone UI.
