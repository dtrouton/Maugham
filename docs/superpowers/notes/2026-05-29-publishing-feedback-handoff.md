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
