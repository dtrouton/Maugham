# Publishing Feedback Milestone — Handoff

**Date:** 2026-05-29
**Branch:** `feat/publishing-pipeline` (unmerged)
**Spec:** `docs/superpowers/specs/2026-05-29-publishing-feedback-design.md`
**Plan:** `docs/superpowers/plans/2026-05-29-publishing-feedback.md`
**Outcome:** all 17 plan tasks shipped. Full suite **1407 tests, 0 failures**. Tool catalog **37 → 39**.

This milestone answered the seven pieces of feedback Claude Desktop raised after using the v1 publishing pipeline on real work (Tribute, Tank Park Salute, Good Luck Babe).

## What shipped (commit-by-commit)

| Commit | What |
|---|---|
| `685c4c3` | A1 — `PDFCompiler` persists `build/compile.log` on every compile (success+failure) |
| `6d869c9` | A2 — `warnings` + `log_path` surfaced on the *completed* compile response (was hardcoded `[]`); threaded through `Outcome.completed(_, warnings:)`, `encodeCompleted`, the `compile_status` path, and `Republisher` |
| `ed3a847` | A3 — `list_publish_files` surfaces `build/` under a `build_artifacts` key; removed the `_diagnostic` instrumentation; added a completeness regression test; documented `build/` readability |
| `ef8237e` | B1 (keystone) — threaded `PublishConfig` into `LaTeXBodyEmitter.emit`/`XHTMLBodyEmitter.emit` (defaulted; no behavior change) |
| `f9c70a7` | A4 — generated `EMISSION.md` contract (rendered from `EmissionContract.swift`, golden-test-enforced, shipped in starter) |
| `ed3e364` | B2 — `PublishConfig.Section.styleFile` (`style_file`) |
| `95f3183` | B3 — LaTeX emitter honors `title_override`, `include_in_toc` (`[notoc]` arg), `start_on` (`\cleardoublepage`) |
| `71d5570` | B4 — XHTML emitter honors `title_override` + `include_in_toc` (`data-toc="false"`) |
| `d2b7462` | B5 — starter `prose.tex`/`screenplay.tex` flipped to UNNUMBERED `\pieceheading` default + `[notoc]` optional env arg (real tectonic compile-guard) |
| `88b6e50` | B6 — scoped-group `style_file` emission + the named **scope-reversion** regression guard |
| `24d40ce` | B7 — `set_piece_style` tool (write file + wire config in one call; deterministic slug; overwrite → trash) |
| `8cc3cb8` | B8 — `clear_piece_style` tool (unwire + delete-iff-orphaned; shared-file survives → trash) |
| `a69ee95` | B9 — registered both tools in `MCPToolCatalog.all`; tool-count assertions 37→39 |
| `e336b96` | F1 — custom-font compile + determinism spike (**GREEN**) |
| `31a75f5` | F2 — shipped fontspec convention (commented starter block + EMISSION.md Fonts section) |
| `aaa32a2` | E1 — `EPUBCompiler` persists `build/body.xhtml` + log stub; documented PDF-closed-loop / EPUB-open-loop asymmetry |
| `a56271f` | Z1 — end-to-end guard that a `style_file`+`[notoc]` piece compiles through tectonic; holistic review (no CRITICAL/IMPORTANT findings) |

## Key design decisions (carried from brainstorming)

- **Locality criterion** governs config-vs-template: *global knowledge needed → config; piece-local → template (per-piece `.tex`)*. Documented in `EMISSION.md`. The two aesthetic flags Claude Desktop proposed (`chapter_number_visible`, `final_line_isolated`) were **dropped** — served by per-piece `.tex` instead.
- **Per-piece overrides made cheap** so the pure path beats a config flag: one MCP call (`set_piece_style`), scoped-group `\input` so a 3-line override file is first-class, and the starter default flipped so the common case (unnumbered titles) needs no override.
- **Recovery = trash, not git.** Maugham is iCloud + op-log; there is no git. `set_piece_style` overwrite and `clear_piece_style` delete route the prior file to `.maugham/`-project `.trash/` (30-day sweep, ⌘⌥Z undo).
- **EPUB is open-loop** (personal-use): `read_publish_file build/body.xhtml` shows structure, not rendering. PDF stays closed-loop via `read_publication_page`.

## Carry-forwards / follow-ups (none blocking)

1. **`SOURCE_DATE_EPOCH` for republish reproducibility.** The font spike (F1) proved custom fonts compile *deterministically* once `SOURCE_DATE_EPOCH` is pinned — without it, only PDF timestamp/ID fields vary (font subsets are deterministic). For byte-identical **republish** from a snapshot, the compile path should set `SOURCE_DATE_EPOCH` from the snapshot time. Out of scope here (PDF is the gift, not a bit-exact archive). Touches `TectonicInvoker`/`PDFCompiler`.
2. **`set_piece_style` default filename uses the piece-id, not the manuscript title.** When no `filename` is passed and the section has no `titleOverride`, the slug falls back to the opaque piece-id (`ab12.tex`). The tool description says "slug of the piece title." Either wire a real title lookup (from project structure) or tighten the description. Cosmetic; deterministic and safe today.
3. **fontspec requires removing `\usepackage[utf8]{inputenc}`** under XeTeX. This is documented in both the starter `preamble.tex` comment and `EMISSION.md`, but the *default* starter still ships inputenc active (correct — the fontspec block is commented). A future "house starter" that defaults to a custom font would drop inputenc.

## Known flake (NOT a regression)

`DocumentStoreConflictManifestTests.test_externalManifestNewer_preservesInMemoryAndReloads` failed once in a full-suite run, **passed in isolation**, and was green across all per-task full-suite runs. It is a timing-sensitive manifest-mtime ("newer") comparison unrelated to anything this milestone touched. Worth a separate ticket to de-flake (inject/await a detectable mtime delta) but it does not gate this work.

## Verification status

- Full suite green (1407 tests) at `a56271f`.
- `style_file` end-to-end compile (incl. `[notoc]`) verified against real tectonic.
- `[notoc]` env arg verified compiling (B5).
- Trash-on-overwrite and orphan-survival verified (B7/B8).
- Default-config emitter output byte-identical (golden `EMISSION.md` test + existing emitter tests unchanged).

## Manual smoke (for the writer to run via Claude Desktop)

Not yet done — needs the user. Suggested:
1. "Set up publishing" on a test collection → confirm `.maugham/publish/EMISSION.md` exists; `read_publish_file EMISSION.md`.
2. `read_publish_file build/body.tex` after a compile — confirm it's readable.
3. `set_piece_style` on one piece with a small `\renewcommand{\pieceheading}[1]{\section{#1}}` → compile → confirm that piece is numbered and others aren't; overwrite it → confirm the prior version is in trash.
4. Set a piece `include_in_toc:false` and `start_on:recto` via `set_publish_config` → compile → confirm ToC omission + recto placement.
5. Compile with a tectonic warning → confirm `warnings` + `log_path` appear in the response.

## Follow-up round (2026-05-29, later) — "fail loudly" hardening

During live Claude-Desktop validation, the milestone *appeared* broken for several rounds: per-section overrides and `style_file` were "stored but ignored," `body.tex` unchanged. **Root cause was NOT the code** — it was a cross-server piece-ID namespace mismatch. The client had cached `doc-XXXX` ids from the *live* `maugham` server (`~/Documents/Maugham/Playlist`) and reused them against `maugham-dev` (`~/Documents/Maugham Tests/Playlist`), which has its own id namespace. Config was keyed by ids the dev emitter never mints; the emitter looked up its own (correct) ids, found nothing, emitted defaults. A reproduction on the real path (`StyleFileProductionPathTests`, `a450a81`) proved the emitter consumes config correctly when ids match — the "couldn't reproduce" was the true signal. Verified end-to-end once correct ids were used: all five markers (`\begingroup`/`\input{pieces/…}`/`[notoc]`/`\cleardoublepage`/`\endgroup`) emit correctly, scope reverts before the next piece.

The unifying defect across this and the `tool_search` confusion: **the surface silently no-ops and returns a success-shaped response instead of objecting.** Fixes shipped (all "fail loudly / authoritative surface"):

| Commit | Fix |
|---|---|
| `c21a640` | (earlier) partial section-patch decodes with defaults; broadened warning parsing |
| `9999870` | **`set_piece_style` hard-rejects an unknown `piece_id`** (`"no piece <id> in this project; call get_outline"`) — would have stopped the whole chase at the first call. Also: default filename now slugs the piece **title**, not the `doc-XXXX` id. Existing tests migrated from synthetic ids to real manifest ids. |
| `369dff6` | **`set_publish_config` returns `warnings: [String]`** naming any section key matching no real piece in the project (warn-and-proceed, doesn't reject the patch). |
| `573f930` | **`list_maugham_tools`** — flat, unranked, complete catalog (name+description) + `server.{name, build_variant, version, tool_count}` identity block + optional `name_contains` substring filter. One call authoritatively answers "what tools exist" and "which build am I on." Catalog 39 → **40**. |

Suite green at **1417 tests, 0 failures**. Valid piece ids are `ProjectStore.collectDocuments(in: store.manifest.structure).map(\.id)` — the same set `get_outline` exposes and `ProjectStoreASTSource` uses.

**Carry-forward (NOT ours to fix):** the highest-leverage discoverability fixes — `tool_search` total-match count, exact-name-match priority, a client-side flat tool list — live in the MCP **host (Claude Desktop)** and the **MCP protocol**, not this repo. Worth raising upstream (Claude Desktop feedback / `modelcontextprotocol` GitHub). `list_maugham_tools` is the local mitigation; it only helps once a client thinks to call it.

## Updated smoke (this round)

6. On `maugham-dev`, ALWAYS get piece ids from `maugham-dev:get_outline` for THIS project — never reuse ids from the `maugham` server (separate namespace).
7. `set_piece_style` with a bogus `piece_id` → confirm it now ERRORS with the get_outline hint (not silent).
8. `set_publish_config` with a section key for a non-existent piece → confirm `warnings` names it.
9. `list_maugham_tools` → confirm 40 tools incl. `set_piece_style`/`clear_piece_style`, and `server.build_variant == "dev"` / expected version.
