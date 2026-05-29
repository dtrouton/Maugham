# 0013 — Publishing pipeline: Claude-authored bespoke typography

**Status:** Accepted
**Date:** 2026-05-29

## Context

Maugham read, edited, and stored manuscripts but produced nothing shareable. The publishing milestone (merged to `main` 2026-05-29) closes that gap. The differentiating goal is not "produce a PDF" — Pandoc and a dozen tools do that — but "your manuscript ships with a Claude-co-authored bespoke LaTeX template, tuned to your typographic taste over time." Claude is the typographic co-pilot; the writer is the editorial voice; Maugham hosts the conversation and the artifacts.

Several decisions shaped the architecture and are recorded here because they are load-bearing and recur in every future publishing change.

## Decision

1. **Claude edits the artifact, not a config-that-transcompiles-to-the-artifact.** The LaTeX template *is* the publishing template; the CSS *is* the EPUB stylesheet. We do not synthesize TeX from a config schema — that would discard Claude's deep LaTeX training, which is the differentiation.

2. **The locality criterion governs config vs. template.** *Does honoring an override require global knowledge the piece cannot have on its own? Global → config; local → template (per-piece `.tex`).* So `start_on` (needs page parity) and `include_in_toc` (needs global ToC state) are config; numbering, drop caps, final-line isolation, ornaments are template. **No aesthetic config flags** — this protects the differentiation (config can't drive the engine into generic output). The criterion only holds because per-piece `.tex` overrides were made cheap (one `set_piece_style` call; scoped-group `\input` so a 3-line override file is first-class; starter defaults make the common case need no override).

3. **The body-emission contract is an authoritative generated document, not probe-inferred.** `EMISSION.md` (generated from `EmissionContract.swift`, golden-test-enforced) is the source of truth for what the emitter produces for each source pattern, plus the locality criterion and the style_file capability/constraint contract. This replaced Claude reverse-engineering the emitter across sessions.

4. **Pipeline shape is project-type-agnostic.** Novel, story collection, mixed collection, standalone screenplay all reduce to a sectioned AST; mode (`prose`/`fountain`) is metadata travelling with each section. There are no type-specific code paths downstream of AST assembly. Override lookup is keyed by `section.pieceID` = `StructureItem.id` — the same id `get_outline` exposes.

5. **PDF via bundled tectonic, accepting the CDN dependency.** Tectonic (~49MB, git-tracked binary) embeds the engine and fetches TeX Live packages on demand from the tectonic CDN. Chosen over MacTeX (5GB, admin install) and Typst (no CDN, but Claude's LaTeX depth is the moat). The CDN dependency is the accepted cost; custom fonts (fontspec + local `Path=`) compile deterministically with `SOURCE_DATE_EPOCH` pinned.

6. **Fail loudly instead of silently no-op'ing.** Tools taking a `piece_id` validate it against the project's real pieces and reject/warn on unknown ids. This was added after a multi-round false "emitter is broken" debugging chase whose actual cause was a cross-server piece-ID namespace mismatch silently accepted by `set_publish_config`. See `memory/project_publishing_namespace_footgun.md`.

## Consequences

- MCP surface grew 20 → 40 tools (publishing families + `list_maugham_tools`).
- `.maugham/publish/` joins the canonical sidecar layout; `Exports/` is writer-visible output.
- Reproducibility rides publication checkpoints (snapshot template+config+styles+cover+font bytes).
- EPUB is open-loop: Claude can read the generated `build/body.xhtml` source but not its rendered appearance (the writer describes that). PDF is closed-loop via `read_publication_page`.
- Full design in `docs/superpowers/specs/2026-05-26-publishing-pipeline-design.md` and `…/2026-05-29-publishing-feedback-design.md`.
