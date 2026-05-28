# Publishing Pipeline — Typesetting Feedback Milestone

**Status:** draft, awaiting writer review
**Date:** 2026-05-29
**Builds on:** `docs/superpowers/specs/2026-05-26-publishing-pipeline-design.md` (the v1 pipeline, now shipped on `feat/publishing-pipeline`)
**Scope:** the seven pieces of feedback Claude Desktop raised after using the v1 pipeline to typeset real work (Tribute, Tank Park Salute, Good Luck Babe), refined through two rounds of brainstorming review.

---

## 1. Purpose

The v1 pipeline works: Claude Desktop can author templates, compile PDFs, and see results via `read_publication_page`. But using it in anger surfaced a consistent failure mode — **the pipeline is more capable than its MCP surface reveals, and the config/template boundary is ergonomically fragile.** Claude burns half-sessions probing the body emitter to rediscover what it does, can't see the build artifacts that would answer its questions in seconds, and is tempted toward aesthetic config flags because the "correct" per-piece-template path is more expensive than the flag would be.

This milestone closes those gaps. It is deliberately *not* a new feature surface — it is visibility, one architectural seam, and the ergonomics that make the existing design's boundary hold under real use.

### 1.1 The governing criterion

Every "should this be config or template?" decision in this milestone (and future ones) is resolved by a single test, established during brainstorming:

> **Does honoring this override require *global* knowledge the piece cannot have on its own?**
> **Global → config. Local → template.**

This subsumes the earlier structural/aesthetic split and gives clean answers on the cases that were muddy:

| Override | Needs global knowledge? | Lives in |
|---|---|---|
| `start_on: recto\|verso` | Yes — the piece can't know its current page; only the engine does | **config** |
| `include_in_toc` | Yes — adding/removing ToC entries is global ToC state | **config** |
| `title_override` | No, but it is a declaration, not typography | **config** |
| `final_line_isolated` | No — `\clearpage` before the last paragraph is local | **template** (per-piece `.tex`) |
| `chapter_number_visible` | No — suppressing the number in the section macro is local | **template** (starter default + per-piece opt-in) |

The criterion is documented in `EMISSION.md` so Claude Desktop applies it consistently rather than re-deriving it each session.

### 1.2 The load-bearing constraint

Holding the boundary ("no aesthetic config flags") is only safe if the alternative — per-piece `.tex` overrides — is *genuinely cheaper than a config flag would have been*. Architectural purity loses to ergonomics every time the pure path costs more than the impure one. So this milestone treats "don't add the flags" and "make small overrides cheap" as one decision, not two. Three requirements follow:

1. **Minimal overrides are first-class** — a piece's `.tex` can be three lines, not a copied template.
2. **Creating one is a single MCP call** — not write-file-then-update-config.
3. **The common case needs no override** — starter defaults make the frequent choice (unnumbered piece titles) the no-op case.

---

## 2. Scope

One milestone, built in this order:

- **Cluster A — Visibility** (§4). Cheapest, highest leverage, ships value first. You cannot reason about Cluster B's correctness without A landed.
- **Cluster B — The config→emitter seam** (§5). The architectural keystone. Honors per-section overrides and adds per-piece style files.
- **Fonts** (§6). Spike-gated: a determinism-aware compile spike runs first and can descope the rest without blocking A/B.
- **EPUB source read** (§7). The agreed floor for EPUB-as-personal-use. Open-loop; small.

### Out of scope

- **EPUB visual inspection** (rasterized rendering for Claude to see). EPUB is personal-use; PDF is the gift deliverable. EPUB iteration stays open-loop (see §7).
- **Aesthetic config flags** (`chapter_number_visible`, `final_line_isolated`, etc.). Dropped per §1.1; served by per-piece `.tex`.
- **A new/parallel backup store for style files.** Maugham runs on iCloud Drive with the op-log as manuscript history; there is **no git** in the writer's workflow, so the v1-review's "git is backup" answer does not apply. Recovery reuses the existing **trash mechanism** rather than a bespoke checkpoint store (§5.6).
- **Per-piece geometry / package loading.** LaTeX enforces these as preamble-level; documented as a constraint, not engineered around (see §5.3).

---

## 3. Current-state ground truth

Verified against the code on `feat/publishing-pipeline` (2026-05-29), because the implementation has drifted from the handoff notes:

- **Tool catalog has 37 tools** (all of v1's Phase 7/8 landed). This milestone adds 2 → **39**.
- **`LaTeXBodyEmitter.emit(_ ast:)` is config-blind** — it takes only the AST. This is why per-section overrides are stored-and-ignored and why there is no channel for style files. Threading config in is the keystone.
- **`PDFCompiler` writes `build/body.tex`** and never cleans it; `build/metadata.tex` too. The combined tectonic log is *not* persisted to disk — it is only returned on the failure path.
- **`EPUBCompiler` does NOT persist `build/body.xhtml`** — it emits per-section XHTML straight into the EPUB package (`EPUBCompiler.swift:48`). §7 must add the write.
- **`read_publish_file` already reads anything under `build/`** — path validation only blocks escapes. `read_publish_file build/body.tex` works *today*; it is undiscoverable because `list_publish_files` skips `build/`.
- **`CompileResponseEncoder.encodeCompleted` hardcodes `"warnings": []` / `"errors": []`** even though `PDFCompiler.Result` carries real parsed warnings.
- **`list_publish_files` already does `readdir`-on-call** (`FileManager.enumerator`), with `.skipsHiddenFiles` and a `build/` skip. It carries a `_diagnostic` instrumentation block added 2026-05-28 to hunt a "listing returns a subset of disk truth" symptom (see §4.4).
- **Starter `prose.tex`** defines `\newenvironment{prose}[1]{\section{#1}}{}`. In the `article` class `\section` is *numbered*, so piece titles render "1 Tank Park Salute". In-content markdown `##` headings already emit `\section*` (unnumbered). The default-flip is therefore localized to this one environment (and `screenplay.tex`'s mirror).
- **Starter `preamble.tex`** has no `fontspec` / font wiring at all.

---

## 4. Cluster A — Visibility

### 4.1 `EMISSION.md` — the authoritative emission contract

A single document, the source of truth for "what LaTeX does the body emitter produce for source pattern X." Shipped in the starter bundle and copied to `.maugham/publish/EMISSION.md` on `initialize_publish_template`, so Claude reads it via `read_publish_file EMISSION.md`.

**Contents:**

- **Positive space** — every recognized source pattern and its emission:
  - Prose: paragraph (→ text + `\par`), the three heading levels (`#`/`##`/`###` → `\section*`/`\subsection*`/`\subsubsection*` + `\addcontentsline`), blockquote (→ `\begin{quote}…\end{quote}`, recursively parsed), scene break (`***`/`###`/`---` ornament lines → `\scenebreak`).
  - Inline: `*em*` → `\emph`, `**strong**` → `\textbf`, `_underline_` → `\underline`, `` `code` `` → `\texttt`, `[[target|display]]` → `\wikilink{target}{display}`, trailing-two-spaces hard break → `\\`.
  - Fountain: scene heading → `\scene`, action → `\action`, character → `\character`, dialogue (coalesced multi-line) → `\dialogue`, parenthetical → `\parenthetical`, transition → `\transition`, title page → centered block, dual dialogue → `\dualdialogue`.
  - Anchor stripping: `<!-- ¶XXXX -->` and `<!--t-XXXXXX-->` are removed before parsing; a paragraph that is *only* an anchor emits nothing.
  - Empty lines: skipped; they are paragraph separators.
  - Section wrapper: `\begin{prose}{title}` / `\begin{screenplay}{title}`; `\clearpage` between pieces (overridable per §5.2).
- **Negative space** — patterns the emitter does **NOT** give special meaning, listed explicitly so Claude knows immediately what needs a per-piece hook vs. what can be styled:
  - `:`-marker lines (e.g. Tribute's `: foo`) → literal paragraph text; no definition-list semantics.
  - `:*emphasis*` → a literal colon followed by `\emph{emphasis}`; no marker semantics.
  - `**Context: 0%**` → `\textbf{Context: 0\%}`; there is no progress-meter/marker rendering — it is ordinary bold text.
  - (Non-exhaustive, with a one-line "anything not listed in positive space passes through as its constituent inline/text nodes.")
- **The locality criterion** (§1.1) and the **style_file capability/constraint contract** (§5.3): what a per-piece file can and cannot do.
- **The style_file recovery model** (§5.6): overwriting or clearing a style file moves the prior version to Maugham's trash (30-day sweep, undo). No git — this is the recovery path. Stated so a future Claude session doesn't reinvent an ad-hoc `.bak` dance.

**Durability — the doc is a build artifact, not a maintained file.** A test renders `EMISSION.md`'s example sections from the golden-fixture corpus (§8) and asserts the committed `EMISSION.md` matches. If the emitter changes and the committed doc is stale, the test fails. This makes "can't drift" enforced rather than aspirational. Hand-written prose framing (the criterion, the constraint contract) lives in template fragments the test interpolates the generated examples into; the *examples themselves* are always generated.

### 4.2 Persist the compile log

`PDFCompiler` and `EPUBCompiler` write the combined tectonic log to `.maugham/publish/build/compile.log` on every run (success *and* failure), overwriting the previous run's. This makes the full log readable via `read_publish_file build/compile.log` regardless of compile outcome.

### 4.3 Surface warnings + log pointer on success

`CompileResponseEncoder.encodeCompleted` is extended to carry the real parsed `warnings` (already present on `PDFCompiler.Result`, currently discarded) and a `"log_path": "build/compile.log"` field. `Publication` / the orchestrator `Outcome` carries the warnings through to the encoder. The failure path already returns `log_excerpt`; it additionally gains `"log_path"` for the full log.

### 4.4 Build-artifact visibility + `list_publish_files` cleanup

- **Surface build artifacts:** `list_publish_files` adds a `build_artifacts` key listing readable files under `build/` (`body.tex`, `body.xhtml`, `compile.log`) so Claude discovers them. Main `files` list still excludes `build/`.
- **Document readability:** the `read_publish_file` tool description and `EMISSION.md` both state that `build/body.tex`, `build/body.xhtml`, and `build/compile.log` are readable.
- **Remove `_diagnostic` noise:** the instrumentation block added 2026-05-28 is removed — it is noise in a contract surface.
- **Settle the subset symptom honestly:** the instrumentation was hunting a "listing returns a subset of disk truth" report. The tool already does `readdir`-on-call (so the "in-memory write-set" framing from review does not apply). The task is: reproduce the symptom, identify the root cause if one exists (prime suspects: `.skipsHiddenFiles` interacting with a dotfile the writer expects to see, or the `build/` skip being misread as the bug), fix or formally close it, and add a regression test that lists a known on-disk fixture tree and asserts completeness. If no root cause reproduces, the resolution is "removed instrumentation + added regression test proving completeness."

---

## 5. Cluster B — The config→emitter seam

### 5.1 The keystone change

`LaTeXBodyEmitter.emit(_ ast:)` → `emit(_ ast:, config:)`. The XHTML emitter takes the same change. Callers (`PDFCompiler`, `PreviewCompiler`, `EPUBCompiler`) already hold the `PublishConfig`. The emitter looks up `config.sections[pieceID]` per section to resolve overrides. Everything below hangs off this one seam.

### 5.2 Honor the three structural overrides

Per §1.1 these stay in config. Applied in the emitter:

- **`title_override`** — substituted for `section.title` in the environment open. Applies to both PDF and EPUB.
- **`include_in_toc: false`** — the emitter signals the environment to skip its ToC entry via an optional environment argument: `\begin{prose}[notoc]{title}` (mirrors LaTeX's optional-arg convention, cf. `\begin{minipage}[t]{}`). The starter environments gain the optional first arg (default includes ToC). Applies to both PDF and EPUB.
- **`start_on: recto|verso`** — the emitter emits `\cleardoublepage` (recto) or a verso break instead of the default `\clearpage` before the section. PDF only; no-op for EPUB (no page concept).

### 5.3 Per-piece `style_file`

The local-override channel. A new optional `style_file: String?` field on `PublishConfig.Section`.

**Mechanism — scoped-group `\input`, with pinned emission order:**

For a section whose config has a `style_file`, the emitter emits:

```latex
\begingroup
  \input{pieces/<style_file>}   % sourced HERE, before the environment opens
  \begin{prose}{title}
    … paragraphs …
  \end{prose}
\endgroup
```

The base macros load once in the preamble (`\input{prose}`); the piece file contains only scoped redefinitions, which revert at `\endgroup`. **Emission order is part of the contract:** the file is `\input` at source time *inside the group and before* `\begin{prose}`. This means a piece wanting a per-piece **title page** simply places title-page LaTeX at the top of its `.tex` (before any `\renewcommand`); it runs before the environment opens. Documented as the title-page pattern in `EMISSION.md`. PDF only.

**Capability / constraint contract (documented in `EMISSION.md`):**

A per-piece file **may**: `\renewcommand`, `\newcommand`, `\definecolor`, `\renewenvironment`, emit arbitrary body LaTeX (including a title page) at source time.

A per-piece file **may NOT**: `\usepackage` (packages load only in the preamble) or change `\geometry` (page geometry is set at preamble time and does not revert at `\endgroup`). These are collection-level decisions and belong in `preamble.tex`. The constraint is LaTeX-enforced, not a Maugham choice — so it is documented, not engineered around. The rare genuine case (e.g. Tribute's marginalia channel) is handled by reserving the space at collection level in `preamble.tex`; pieces that don't use it simply have a wider effective measure.

### 5.4 `set_piece_style` / `clear_piece_style` MCP tools

What makes the pure path cheaper than a config flag. Tool count 37 → 39.

- **`set_piece_style(project_id, piece_id, content, filename?)`** — one atomic call:
  1. Writes `pieces/<filename>.tex` under `.maugham/publish/`.
  2. Wires `config.sections[piece_id].style_file = "<filename>.tex"`.
  - **`filename`** defaults to a deterministic, idempotent slug of the piece title (same title → same filename, always). Calling `set_piece_style` again on a piece that already has a `style_file` **overwrites that file in place** rather than creating a new one — this is what "atomic" guarantees here.
- **`clear_piece_style(project_id, piece_id)`** — the inverse:
  1. Unwires `config.sections[piece_id].style_file`.
  2. Deletes `pieces/<file>.tex` **iff orphaned** — i.e. no other section's `style_file` still references it. Two pieces may share one style file; clearing one must not break the other. Reflected in the docstring.

### 5.5 Starter default-flip

- Piece-title rendering in `prose.tex` moves from numbered `\section{#1}` to unnumbered, via a redefinable macro:
  ```latex
  \newcommand{\pieceheading}[1]{\section*{#1}\addcontentsline{toc}{section}{#1}}
  ```
  so the common case (unnumbered titles, still in ToC) is the no-op. A piece wanting numbering opts in with a one-line scoped override in its style file: `\renewcommand{\pieceheading}[1]{\section{#1}}`. The `[notoc]` optional arg (§5.2) selects a no-ToC variant.
- `screenplay.tex` gets the mirror flip.

### 5.6 style_file recovery model — reuse the trash mechanism

`set_piece_style` is destructive (overwrites in place, §5.4) and `clear_piece_style` deletes the file. The v1-review assumed git as the safety net, but **Maugham's actual model is iCloud Drive + the op-log, and there is no git.** Two facts shaped the decision:

- The op-log is **manuscript-only**. Publish artifacts under `.maugham/publish/` (templates, partials, style files, config, `styles.css`) do **not** flow through the op-log; they are plain files synced by iCloud Drive.
- Maugham already has the right primitive: the **trash mechanism** (`.maugham/trash/`, 30-day sweep, ⌘⌥Z undo) that handles destructive manuscript/research file ops today.

**Decision:** reuse the trash mechanism. Before `set_piece_style` overwrites an existing style file, and before `clear_piece_style` deletes one, the prior file is moved to `.maugham/trash/` — the same path, sweep, and undo affordance the app already uses for deleted manuscript and research files. This gives real per-edit safety during the `preview_compile` tuning loop (where overwrite mistakes are most likely), costs no new concept, and stays idiomatic.

Implementation notes:
- This is a **small extension of trash to cover `.maugham/publish/`**. The existing trash plumbing lives in `ProjectStore+Trash.swift`; route the pre-overwrite/pre-delete move through it rather than building a parallel backup store.
- A fresh write (no existing file at the target) does **not** trash anything — only overwrites and deletes do.
- Per CLAUDE.md tripwire 14 (close-before-FS-surgery): style files are *not* open in a `Document` writing surface (they are publish artifacts, not manuscript), so the autosave-recreates-phantom hazard does not apply here. No `Document.close` dance is required for style files — but the trash move itself must still be atomic.
- Documented in `EMISSION.md`: "Overwriting or clearing a style file moves the prior version to Maugham's trash (30-day sweep, undo via ⌘⌥Z). There is no git; this is the recovery path."

The v1 **publication checkpoint** (which snapshots the whole publish artifact set on each successful full `compile()`) remains a *second*, coarser recovery path for "restore the whole publication's artifacts as of version X" — but the trash is the per-edit safety net.

---

## 6. Fonts — spike-gated

### 6.1 The spike (gating task, runs first)

Verify the whole loop before committing to the feature: `write_publish_file` (base64) → `fonts/EBGaramond-Regular.otf` → `\setmainfont[Path=fonts/]{EBGaramond-Regular.otf}` in `preamble.tex` → tectonic compile.

**Acceptance criteria — not just "it compiles":**

1. A PDF compiles end-to-end with the body set in the local font (verified by inspecting `read_publication_page`).
2. **Determinism holds.** Compile the same input twice and diff the two PDFs. The only differences must be the already-known interpolated metadata fields (`\MaughamVersion`, `\MaughamCompiledAt`, etc.). If the PDFs differ in font-subset ordering, stream offsets, or other font-path-dependent ways, fonts have introduced non-determinism beyond Maugham's control.

### 6.2 If the spike is green

- A commented `fontspec` block in the starter `preamble.tex` showing the `\setmainfont[Path=fonts/]{…}` pattern (currently there is none).
- The `fonts/` convention documented in `EMISSION.md` with a working example and the explicit loop (write base64 → reference via `Path=fonts/`).
- Font *loading* stays in `preamble.tex` (local-to-collection → template per §1.1); **no config schema field for fonts.**

### 6.3 If the spike reveals non-determinism

Not necessarily a kill-shot — for a gift chapbook, byte-identical republish does not matter. But it weakens the v1 republish-reproducibility contract (§6 of the v1 spec) more than that spec acknowledged. Disposition if it occurs:

- Document the determinism caveat in the spec and in `list_publications` lineage notes.
- Decide (at spike-review time, with the writer) whether to ship fonts with the caveat or descope fonts to a carry-forward. Either way, **A and B are untouched.**

---

## 7. EPUB source read — open-loop

The agreed floor for EPUB-as-personal-use. **Not** symmetric with PDF inspection, and the asymmetry is documented so future architecture conversations don't assume otherwise.

- **Code change (not free):** `EPUBCompiler` writes the assembled XHTML to `.maugham/publish/build/body.xhtml` (it currently emits per-section XHTML straight into the package and persists nothing). The styles in effect are already on disk as `styles.css`.
- **Read path:** `read_publish_file build/body.xhtml` + `read_publish_file styles.css`, surfaced in `build_artifacts` (§4.4) and documented in `EMISSION.md`.
- **Documented asymmetry (in `EMISSION.md`):**
  - **PDF is closed-loop.** Claude edits the template, compiles, and *sees* the result via `read_publication_page`. Iteration converges on what Claude observes.
  - **EPUB is open-loop.** `build/body.xhtml` shows whether the *structural* XHTML changed, not how a reader *renders* it — rendering depends on the reader's CSS interpretation, embedded fonts, and device defaults. EPUB iteration is therefore: Claude proposes CSS changes → Denver loads the EPUB in a reader → Denver describes what he sees → Claude iterates on the description. This is acceptable for personal-use; it is not a gap to be closed in this milestone.

---

## 8. Testing

The golden-fixture corpus is the backbone — it is simultaneously the emitter regression net and the generator source for `EMISSION.md` (§4.1).

- **Golden corpus:** input markdown/fountain fixtures → expected `body.tex` snapshots, covering every positive-space pattern in §4.1. `EMISSION.md` generation reads from this; a test asserts the committed doc matches.
- **Config→emitter overrides:** `title_override` substitution, `[notoc]` emission when `include_in_toc: false`, `\cleardoublepage` vs `\clearpage` for `start_on`. Both PDF and EPUB emitters where applicable.
- **`style_file` scoped-group emission:** asserts the `\begingroup \input{pieces/…} \begin{prose}… \endgroup` shape and the input-before-environment order.
- **Scope-reversion regression test (named invariant):** a piece with a `style_file` that `\renewcommand`s a macro, *followed by a piece without a style_file*, asserts the second piece sees the unmodified macro. This is the bug the scoped group exists to prevent and the first thing to regress if someone hoists the `\input` out of the group. Comment it as such.
- **Tool atomicity:** `set_piece_style` writes file + wires config in one call; re-call overwrites in place (no new file); `clear_piece_style` unwires + deletes-iff-orphaned (shared-file case asserts the file survives while another section references it).
- **Trash recovery:** `set_piece_style` overwriting an existing file moves the prior version to `.maugham/trash/` (and a *fresh* write trashes nothing); `clear_piece_style` deleting a file trashes it. Asserts the prior content is recoverable from trash.
- **Default-flip:** piece titles render unnumbered (`\section*`); the per-piece numbering opt-in restores `\section`.
- **Warnings-on-success:** a compile that produces a tectonic warning surfaces it in the `completed` response with `log_path` set.
- **`list_publish_files`:** completeness regression test over a known fixture tree; `build_artifacts` populated; `_diagnostic` gone.
- **EPUB:** `build/body.xhtml` is written and readable after an EPUB compile.
- **Fonts (if green):** the spike's determinism diff becomes a (possibly `#if`-gated / slow-lane) test.
- **Catalog:** bump the two hardcoded tool-count assertions 37 → 39 and add `set_piece_style` / `clear_piece_style` to the expected-names set (`MCPProtocolHandlersTests`, `MCPToolsListSmokeTest`); `MCPCatalogConsistencyTests` enforces the rest.
- **E2E:** extend the existing end-to-end PDF render guard to assert a piece with a `style_file` compiles.

---

## 9. Build order summary

1. **Cluster A** — `EMISSION.md` (generated + golden corpus), persist `compile.log`, warnings-on-success, `build_artifacts` + `list_publish_files` cleanup.
2. **Cluster B** — thread config into emitter; honor `title_override` / `include_in_toc` / `start_on`; `style_file` scoped-group; `set_piece_style` / `clear_piece_style`; starter default-flip.
3. **Fonts spike** — gate on determinism-aware acceptance criteria; build convention if green.
4. **EPUB source read** — persist `build/body.xhtml`; document the open-loop asymmetry.

---

## 10. Invariants this milestone must not violate

- **No aesthetic config flags.** The schema gains `style_file` (a pointer, not typography) and nothing else aesthetic. The locality criterion (§1.1) is the gate for any future field.
- **MCP never mutates manuscript text.** All new tools operate under `.maugham/publish/` only; `PublishPath.validateAndResolve` continues to guard every path.
- **Tool catalog single source of truth.** New tools implement `MCPTool` and register in `MCPToolCatalog.all`; no parallel registration.
- **`.md`/`.fountain` on disk stay authoritative for manuscript content.** Publish reads last-autosaved disk state (handoff gotcha 13); this milestone does not change that.
- **Generated `Maugham.xcodeproj/` stays untracked.** New files go in `project.yml`-sourced folders; run `./gen.sh` after adding them.
