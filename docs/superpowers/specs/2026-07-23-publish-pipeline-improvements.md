# Publish pipeline improvements — from the Playlist Volume One experience

**Date:** 2026-07-23
**Source:** Two multi-day sessions producing *Playlist, Volume One* (EN) and *Playlist, Volumen Uno* (ES) — the first real books through the publish pipeline and the first real translated edition through the translation layer. Every item below is something that cost real time or forced a workaround in that work; nothing is speculative.
**Constitution check:** All items serve *plain text on disk* (nothing here adds sidecar manuscript formats), *fail loudly* (several items convert silent gaps into loud ones), and the *op log as source of truth* (translation/AST paths already comply; nothing here reads `.md` as truth).

---

## P0 — Land the defect branch, reopen defect 4 honestly

`fix/publishing-latex-defects` (`c91ffc8`) fixes the starter `\ifx`/`\long` ToC dispatch, the `\scenebreak` `\centering` leak, and the `\\`+`[` optional-argument scan — all three verified against the field failures that found them. **It is not merged.** Merge and release it; any project initialized before the release keeps broken starter copies (see F5 for the doc-refresh half of that story; user-owned `.tex` is never auto-touched, per the no-migration rule the writer re-inits or hand-fixes).

**Defect 4 (style-scope escape) needs a better ending than "refuted."** The probe in `StarterTemplateDefectProbeTests` shows simple robust-command renewals reverting at the emitter's `\endgroup` — but the field observation was real and reproducible: in a six-piece compile, Tribute's style-file-scope `\renewcommand{\textbf}` (body = `\marginpar{...}`) restyled A Little Soul's fountain title block and scene headings two pieces later, while a solo compile of A Little Soul rendered correctly and `begingroup`/`endgroup` counts in `body.tex` were balanced. The probe and the field disagree, which means the probe doesn't reproduce the triggering shape (candidates: `\marginpar` in the renewal body, fontspec's lazy `\em`/bold family setup, interaction with the fountain `\providecommand` block). **Action:** import the actual six-piece reproduction (piece 2 renews `\textbf` to a `\marginpar` at style-file scope; piece 4 is fountain with a title block) into the probe suite before closing the defect. If it reproduces, fix; if it genuinely cannot, document the pieceheading-hook pattern as *required* (not advisory) in EMISSION.md. The working fix in the field — all renewals inside the `\pieceheading` hook, scoped by the environment group — is sound either way and is what the Playlist templates use.

---

## F1 — Per-section publish include flag (the volume-subset gap) — **highest-value feature**

**Experience:** The Playlist binder holds 17 manuscript docs: six Volume One pieces and eleven Volume Two drafts. A versioned `compile` includes everything, so *neither edition of Volume One could ship as a real Publication*. The EN edition shipped from `preview_compile` subset output (no Publication record, no version, no snapshot); the ES edition shipped via `allow_stale` (two junk Publications minted) plus an external `pdftocairo`/`pdfunite` page-stitch to drop the untranslated stub tail. Both are workarounds for the same missing bit.

**Design:** `sections.<docId>.include: Bool` (default `true`) in `PublishConfig`. Honored by:
- `LaTeXBodyEmitter`/`XHTMLBodyEmitter` — excluded sections are not emitted (both formats).
- **The translation coverage gate** — excluded sections do not gate. (This is the ES-edition unlock: the stub drafts stop blocking the compile.)
- `preview_compile` — an omitted `section_ids` means "all *included* sections," and explicit `section_ids` may still name an excluded section (preview is exploratory).
- Snapshot/`republish` — `include` flags are part of the config, which is already snapshotted; republish reproduces the same subset for free.

**Schema evolution:** additive-optional field; ADR 0015 pattern (absent ⇒ `true`). No migration.

**UI surface (workflow rule 8):** minimum viable = the flag is visible/editable via `get_publish_config`/`set_publish_config` and *displayed* in whatever publish UI exists; if a publish settings sheet ships later, this is a checkbox per binder piece. Do not block the MCP feature on the sheet.

**Tests:** emitter skips excluded sections (both formats); gate ignores excluded sections; ToC/`\pageref` integrity with exclusions; snapshot round-trip preserves flags; config validator normalizes unknown keys as today.

**Acceptance (north star for this whole spec):** *both* editions of Playlist Volume One reproducible as first-class versioned Publications with zero external tooling and zero `allow_stale` escapes.

## F2 — Edition parity for previews

**Experience:** There was no way to *see* the Spanish edition without minting a Publication — `preview_compile` has no `language`, so validating the ES templates required two throwaway versioned Publications (`v0.1`, `v0.2`) that now live in the record forever.

**Design:** `preview_compile` gains `language` and `allow_stale` with identical semantics to `compile` (including the gate report on failure). Additionally, `compile` gains `dry_run: true` — run the gate and return the report with no output, no Publication, no version bump. `translation_status` answers "how translated is the book"; `dry_run` answers the different question "would *this edition compile* pass, for the currently included sections."

**Tests:** preview with language resolves `.es` templates; preview gate parity; `dry_run` produces no Publication/version churn.

## F3 — Close the loop for preview pages

**Experience:** `read_publication_page` rasterizes Publication pages, but preview output is only a file path — closing the visual loop on previews required installing poppler and shelling out for every page check, dozens of times. The pipeline's closed-loop story ("Claude edits, compiles, and reads the page image") is only true for versioned Publications today.

**Design:** `read_preview_page` — same envelope, crop, and cap semantics as `read_publication_page` (ADR 0004 crop-on-demand, tripwire 10), reading the last preview output for the project. PDFKit rasterization; no new dependencies. Invalidate the handle when a newer preview overwrites the file.

**Tests:** page render + region crop parity with `read_publication_page`; stale-handle behavior after a fresh preview.

## F4 — Document the language-variant template pattern (resolver stays dumb)

**Experience:** The resolver picks `template.<lang>.tex` and per-piece `<piece>.<lang>.tex`, but not partials — `frontmatter.es.tex` sat silently ignored until a `template.es.tex` was written whose `\input`s point at the `.es` partials. One compile cycle wasted; the failure mode is silent (base files render, nothing errors).

**Design decision:** keep the resolver's scope exactly as-is (template + per-piece styles). Auto-resolving arbitrary `\input`s is magic with surprise potential (a project may `\input` shared macros that must *not* vary by language). Instead:
1. Add to the `translation-pass` help topic and EMISSION.md: *"If your template inputs partials (preamble/frontmatter/backmatter), the language edition needs a `template.<lang>.tex` whose `\input` lines point at language variants of those partials; the resolver picks the template variant, and everything else follows from it."*
2. Starter `template.tex` gains a two-line comment saying the same.

**Tests:** doc-presence probe (same style as the EMISSION.md generation test).

## F5 — EMISSION.md auto-refresh (app-owned docs must track the installed app)

**Experience:** Playlist's `.maugham/publish/EMISSION.md` is frozen at init time (v0.23 era). It still documents `\\` joins (changed to `\newline` in `c91ffc8`) and predates the entire language machinery. An agent that reads it — as instructed — is now *misinformed by the pipeline's own contract document.*

**Design:** EMISSION.md is generated, app-owned, and never user-edited — refresh it in the project's publish dir on every compile (or app-open of a publish-initialized project; compile-time is simpler). Never touch user-owned files (`template.tex`, partials, `config.json`, pieces). Stamp the generating app version in the file header so staleness is self-evident.

**Tests:** compile against a dir with stale EMISSION.md leaves it matching the installed contract; user-owned files byte-identical before/after.

## F6 — Fountain title block emits through hooks

**Experience:** The screenplay title block is emitted as hardcoded `\begin{center}…{\Large\textbf{…}}` — per-piece styles can't restyle it (the field leak incident surfaced this: the title block was the visible victim, and there was no sanctioned hook to control it). The ES edition also had no way to style "Primer borrador" distinctly.

**Design:** emit the title block through `\providecommand`-backed macros (e.g. `\screenplaytitleblock{title}{credit}{author}{notes}` with a default matching today's output), same pattern as `\lyricline`/`\scenenumber`. EMISSION.md byte-gate updated with the pinned deviation, per the shared-block-parser precedent.

**Tests:** emitter unit test for the macro emission; byte-gate pin; default-render equivalence.

## F7 — Filename template `{language}` placeholder

**Experience:** `Playlist-v0.2-es-proof-2-es.pdf` — the language is auto-suffixed *and* was in the label, yielding a double `es`. Cosmetic, but these filenames are the artifact friends receive.

**Design:** `{language}` placeholder in `filename_template` (empty for source-language, including any separator cleanup); auto-suffix only applies when the template lacks the placeholder (back-compat).

## F8 — Translation audit polish

**Experience:** `read_translation` can't distinguish a deliberately-verbatim paragraph from a suspicious translated-equals-source one; auditing a "100% fresh" book for accidental non-translation requires the raw store.

**Design:** surface `verbatim: Bool` on `read_translation` entries and a `verbatim` count on `translation_status` rows. Optional advisory (not warning) from `write_translation` when a non-verbatim entry's text equals its source.

---

## Documentation & skills (cheap, high leverage)

- **EMISSION.md additions** (some landed in `c91ffc8` item 4): xparse `\NewDocumentCommand`-family declarations are **global** and cross piece boundaries; active-catcode tricks in style files destabilize hyperref's multi-pass machinery (field-verified) — use source-level constructs instead; the pieceheading-hook scoping pattern (required or strongly advised per the defect-4 outcome).
- **Translation-pass topic:** the F4 template-variant pattern; a note that speaker-label probes and other literal-string hooks in style files are part of the piece's *translation contract* (the ES edition needed a `Docto` stem probe because the translator correctly chose "Doctora:").
- **Publishing guide:** the Playlist sessions are a complete worked example of closed-loop book design (subset preview → read pages → iterate; per-piece registers; language editions). Worth mining for a "designing a book with Claude" topic — the current publishing topic describes the mechanism, not the craft.

## Out of scope

- EPUB-specific translation work beyond what the existing emitter does (open-loop iteration story unchanged).
- Phone surfaces for translations (v1 decision stands).
- Translation store sealing/compaction (noted future work in the feature's own plan).
- Personalized per-copy editions (project-level technique; F1 + existing config machinery suffice when Playlist's full edition wants it).

## Suggested order

1. **P0** (merge + defect-4 repro) — correctness debt, blocks nothing else.
2. **F1** (include flag) — unlocks real Publications for both existing editions; smallest feature with the largest effect.
3. **F5 + F4** (doc freshness + pattern docs) — nearly free, prevents the next agent losing cycles to known traps.
4. **F2 + F3** (edition previews + preview pages) — closes the loop properly for iteration.
5. **F6, F7, F8** — polish; bundle into the same milestone per the ambitious-scope default.

**Milestone acceptance:** re-produce `Playlist - Volume One.pdf` and `Playlist - Volumen Uno.pdf` as versioned Publications v1.0/v1.0-es from a clean checkout of the app, using only MCP tools, with green gates and no external PDF tooling.
