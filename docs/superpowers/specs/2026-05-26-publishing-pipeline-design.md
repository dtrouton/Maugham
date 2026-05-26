# Publishing Pipeline — v1 Design

**Status:** draft, awaiting writer review
**Date:** 2026-05-26
**Scope:** v1 of the publishing milestone — sharable PDF + EPUB across all project types, with Claude as a typographic co-pilot via a rich MCP surface

---

## 1. Purpose

Today Maugham reads, edits, and stores manuscripts. It produces nothing the writer can share with a friend, submit to a magazine, or hand to a designer. The publishing pipeline closes that gap.

The differentiating story is not "Maugham can produce a PDF." Pandoc and a dozen web tools do that. The story is: **your manuscript ships with a Claude-co-authored bespoke LaTeX template that gets tuned to your typographic taste over time**, with PDFs that look distinct rather than generic. Claude is the typographic co-pilot; the writer is the editorial voice; Maugham hosts the conversation and the artifacts.

This milestone delivers:

- A bidirectional publishing pipeline (PDF via LaTeX/tectonic, EPUB via HTML/CSS) driven by per-project Claude-authored templates plus a small structured config
- A rich MCP surface (~15 tools) so Claude can author, refine, compile, and view publications without leaving Claude Desktop
- Reproducible publication history via expanded checkpoints — re-rendering v0.3 a year later produces v0.3 bit-for-bit, not v0.3 hybridized with current state
- Working pipeline from day one via a single deliberately-plain barebones starter that demonstrates the body-emission contract without anchoring on a Maugham house aesthetic

---

## 2. Architecture

### 2.1 Pipeline shape

The unit of compile is the **project**, expressed as a sectioned AST. Three concrete cases all reduce to the same shape:

| Project shape | AST | Output |
|---|---|---|
| Novel-with-chapters (all prose) | N prose sections in binder order | Single PDF/EPUB with continuous page numbers, ToC, running heads |
| Short-story collection (all prose) | N prose sections + per-story title pages | Single PDF; ToC lists stories |
| Mixed collection (prose + screenplay) | Sections with per-section mode metadata | Single PDF where prose sections use prose typography and screenplay sections use screenplay layout, **bound together** with shared cover/ToC/copyright/page numbers |

```
Pieces (.md/.fountain, op-log-derived, mode-tagged)
        |
        v
   AST nodes (parsed per mode by existing MarkdownParser/FountainParser)
        |
        v
   Project AST (sections in binder order, each carries mode metadata)
        |
        v
   Body emit  ---------------------+
        |                          |
        v                          v
   body.tex (per-section          body.xhtml (per-section
   environments)                  classes)
        |                          |
   + .maugham/publish/         + .maugham/publish/
     template.tex + partials      styles.css
   + .maugham/publish/         + .maugham/publish/
     config.json (metadata)       config.json (metadata)
        |                          |
        v                          v
   tectonic -> PDF              HTML->XHTML+OPF zip -> EPUB
        |                          |
        +-------------+------------+
                      v
       Exports/  +  named checkpoint  +  embedded metadata
```

### 2.2 Key invariants

- **Project type is irrelevant to the pipeline.** Novel, story collection, mixed collection, standalone screenplay — all produce a Project AST of sections. There are no type-specific code paths downstream of AST assembly. A standalone novel is "one or more prose sections;" a standalone screenplay is "one fountain section;" a mixed collection is "varied sections with mixed mode metadata."
- **Mode is metadata travelling with the AST.** Each section carries `mode: prose | fountain`. The body emitter dispatches on this, choosing the right LaTeX environment or XHTML class. Upstream of body emit, nothing cares.
- **Claude edits the artifact, not a config-that-transcompiles-to-the-artifact.** The LaTeX template *is* the publishing template. The CSS *is* the EPUB stylesheet. We do not synthesize TeX from a config schema. Claude's deep training on LaTeX is the differentiation; making Claude write JSON-against-a-schema would discard that.
- **Config is small and tactile.** Anything in config is metadata or structured override: title, author, ISBN, cover path, version, per-section overrides (start-on-recto, skip-in-ToC). Anything aesthetic — fonts, page geometry, drop caps, scene-break ornaments, custom commands — lives in `template.tex` / `styles.css`. The boundary protects the differentiation: config can't drive the engine into generic output.
- **Two pipelines are explicitly accepted.** PDF and EPUB share the AST and the config but emit different bodies and use different stylesheet artifacts. The writer-Claude pair maintains both. EPUB is the more-generic side because the format and reader software are more constrained; PDF is where bespoke typographic personality lives.

### 2.3 Body emission contract

The body emitter writes intermediate files that the project's template/stylesheet consumes. This contract is documented as part of the MCP surface so Claude knows what `body.tex` and `body.xhtml` will look like when authoring its template.

**LaTeX side (`body.tex`):**

```latex
% For prose sections:
\begin{prose}{section title}
  Paragraphs as plain LaTeX, one per AST paragraph.
  Scene breaks emit \scenebreak (template defines what this does).
  Emphasis is \emph{...}; strong is \textbf{...}; wiki-links are \wikilink{target}{display}.
\end{prose}

% For screenplay sections:
\begin{screenplay}{section title}
  \scene{INT. KITCHEN - DAY}
  \action{Aaron pours coffee.}
  \character{AARON}
  \dialogue{Morning.}
  \parenthetical{(quietly)}
  \transition{CUT TO:}
  \dualdialogue{...}{...}
\end{screenplay}
```

The template (in `prose.tex` and `screenplay.tex`) must define each of these environments and commands. The barebones starter ships working definitions; Claude is expected to rewrite them per project.

**HTML side (`body.xhtml`):**

```xhtml
<section class="prose" data-piece-id="p_abc123">
  <h1>Section Title</h1>
  <p>Paragraph text...</p>
  <hr class="scene-break"/>
  <p>More text with <em>emphasis</em> and <strong>strong</strong>...</p>
</section>

<section class="screenplay" data-piece-id="p_def456">
  <h1>Section Title</h1>
  <p class="scene-heading">INT. KITCHEN - DAY</p>
  <p class="action">Aaron pours coffee.</p>
  <p class="character">AARON</p>
  <p class="dialogue">Morning.</p>
</section>
```

`styles.css` must define rules for `.prose` / `.screenplay` containers and their children. The barebones starter ships minimal CSS; Claude rewrites per project.

---

## 3. File layout

```
ProjectFolder/
  manuscript/                    (existing — .md, .fountain pieces)
  research/                      (existing)
  Exports/                       (NEW — writer-visible compiled outputs)
    Stories from the Edge-v0.1.pdf
    Stories from the Edge-v0.2.pdf
    Stories from the Edge-v0.2-galley.pdf
    Stories from the Edge-v0.3.epub
  .maugham/
    ops/                         (existing)
    checkpoints/                 (existing — expanded scope: see §6)
    publish/                     (NEW)
      template.tex               (entry point; \inputs the partials below)
      preamble.tex               (packages, fontspec, custom commands)
      frontmatter.tex            (title page, copyright, dedication, ToC trigger)
      prose.tex                  (defines \begin{prose}...\end{prose} + per-mode styling)
      screenplay.tex             (defines \begin{screenplay}...\end{screenplay} + per-mode styling)
      backmatter.tex             (about author, also-by, acknowledgments)
      styles.css                 (EPUB stylesheet — the EPUB analogue of template.tex)
      config.json                (structured metadata + per-section overrides)
      cover.{jpg,png}            (conventional location; config can override path)
      fonts/                     (project-specific font files, referenced from preamble via fontspec)
        EBGaramond-Regular.otf
        ...
      build/                     (transient — body.tex, body.xhtml, tectonic aux files; gitignored)
```

The whole `.maugham/publish/` directory (except `build/`) is part of the project's identity and SHOULD be tracked if the writer version-controls the project. `build/` is throwaway.

---

## 4. Starter

A single barebones starter ships in the app bundle (read-only). When a new project is created, Maugham copies the barebones into `.maugham/publish/` automatically. The barebones starter is also the **reference implementation of the body-emission contract** — it demonstrates exactly which environments and commands the template must define.

The barebones starter is deliberately plain:

- Document class: `article` (not memoir or book)
- Font: Computer Modern (the TeX default — utilitarian, recognizably "academic," explicitly *not* a published-novel aesthetic)
- No drop caps, no scene-break ornaments, no chapter-page typography
- Plain running heads, page numbers bottom-center
- A working title page that reads metadata from `config.json`
- A working `prose` environment and `screenplay` environment that render correctly but without personality
- Minimal `styles.css` with thesis-grade typography

This intentionally leaves a wide gap between "what you get out of the box" and "what your published book should look like." The gap forces the writer-Claude conversation: when the writer says "make this look like a real novel," Claude proposes a fresh design rather than tweaking defaults.

No other starters ship in v1. We don't encode taste; the writer-Claude pair encodes it per project. Adding curated starters or user-defined starter libraries is deferred.

---

## 5. Config schema

`.maugham/publish/config.json` is small, schema-validated, MCP-mutable. It contains only what is structured and tactile — never typography rules.

```json
{
  "schema_version": 1,

  "metadata": {
    "title": "Stories from the Edge",
    "subtitle": null,
    "author": "Denver Trouton",
    "copyright": "© 2026 Denver Trouton",
    "isbn": null,
    "publisher": null,
    "year": 2026,
    "language": "en",
    "keywords": []
  },

  "outputs": {
    "directory": "Exports",
    "filename_template": "{title}-v{version}{label_suffix}.{ext}",
    "sanitize_spaces": false,
    "formats_enabled": ["pdf", "epub"]
  },

  "cover": {
    "path": "cover.jpg",
    "epub_specific_path": null
  },

  "sections": {
    "p_abc123": {
      "title_override": null,
      "start_on": "any",
      "include_in_toc": true
    }
  },

  "epub_overrides": {
    "metadata": {},
    "cover": null
  },

  "next_version": "0.1",
  "active_label_hint": null
}
```

**Notes:**

- No `font` field, no `page_size` field, no per-mode typography field. Those live in `template.tex` / `styles.css`.
- `sections` is keyed by `piece_id` (matching binder identifiers used elsewhere).
- `epub_overrides` is narrow — only metadata and cover differ between PDF and EPUB. EPUB style differences live in `styles.css`.
- `next_version` is incremented automatically on successful `compile()`.

Schema validation rejects unknown fields (forward-compatibility happens via `schema_version` bumps, not silent acceptance).

---

## 6. Versioning and reproducibility

### 6.1 Auto-bumped versions with optional labels

- Each `compile()` (full, not preview) increments `config.next_version`: `v0.1`, `v0.2`, `v0.3`.
- `compile(format, label="galley")` decorates the version. The label travels with publication metadata, appears in filenames, prints in `list_publications()`.
- Multi-format compiles at the same version are allowed (`v0.3.pdf` and `v0.3.epub` are "one publication, two formats"). Within a single `compile()` call only one format is rendered; calling `compile(format="epub")` immediately after `compile(format="pdf")` reuses the same version number iff no editing has occurred between them. Implementation detail: `next_version` does not bump on the second compile if the publish-state snapshot is identical to the prior compile.
- `republish(checkpoint_id)` uses a new version number, not the snapshotted one. The publication metadata records `republished_from: "v0.3"` for lineage.
- No version-rollback tool in v1; if the writer wants to start over at v0.1 they edit `config.json` directly (or via `set_publish_config`).

### 6.2 Expanded checkpoint scope

Today's `CheckpointStore` snapshots manuscript op-log state. Publishing introduces a new variant, `Checkpoint.publication`, which carries additional snapshot data so that `republish(checkpoint_id)` produces a bit-for-bit reproduction of the original publication.

Snapshot contents:

| What | Why | Cost |
|---|---|---|
| Manuscript op-log state | Reproducible content | (already paid) |
| `template.tex` + partials (`preamble.tex`, `prose.tex`, etc.) | Reproducible typography | ~10–50 KB |
| `styles.css` and any css partials | Reproducible EPUB | ~10 KB |
| `config.json` | Reproducible metadata + overrides | ~1 KB |
| Cover image bytes (full file) | Reproducible cover even if writer replaces it later | ~50–500 KB |
| Font file bytes under `.maugham/publish/fonts/` | Reproducible typography across machines | ~100 KB – 1 MB |
| `maugham_version`, `tectonic_version` | Debug if reproduction differs | trivial |
| Output file references | What was produced | trivial |

Implementation note: this rides on the existing `JSONLAppendStore<T>` primitive. A new `Checkpoint.publication` enum case carries the publish-artifact blob as associated data; the existing snapshot infrastructure handles persistence.

Storage cost: a publication checkpoint runs ~100 KB – 1.5 MB depending on cover + font sizes. For a writer publishing weekly over a multi-year project, this is ~50–500 MB of publication history per year. Acceptable; a future cleanup tool can prune old publications if needed.

**Why snapshot bytes, not paths:** If we snapshotted only paths and the writer replaced `cover.jpg` six months later, every historical publication would silently change cover when republished. Bytes-in-the-checkpoint is the only honest reproducibility model.

This expansion of checkpoint scope is the right place to add a new typed seam per [ADR 0010](../../adr/0010-typed-cross-area-seams.md). Existing manuscript checkpoints stay simple; publication checkpoints are a different enum case with their own associated data.

### 6.3 Output file conventions

- **Location:** `ProjectFolder/Exports/`. Writer-visible in Finder. Created on first publish.
- **Filename template** (from `config.outputs.filename_template`, default `"{title}-v{version}{label_suffix}.{ext}"`):
  - `Stories from the Edge-v0.3.pdf`
  - `Stories from the Edge-v0.3-galley.pdf`
  - `Stories from the Edge-v0.3.epub`
- Title is sanitized for filesystem safety (slashes and leading dots stripped). Spaces preserved by default; `config.outputs.sanitize_spaces: true` replaces them with hyphens.
- Filename collisions are refused with an error referencing the existing publication. Writer can pass `label` to disambiguate or delete the prior file.

### 6.4 Metadata embedding

**PDF metadata** is written by the template via `hyperref` / `pdfx`. Values come from `config.json`:

- Standard: `Title`, `Author`, `Subject` (= `subtitle` if set), `Keywords`
- `Producer` = `"Maugham {maugham_version} via tectonic"`
- `Creator` = `"Maugham"`
- Custom XMP: `maugham:version`, `maugham:label` (if set), `maugham:checkpoint_id`, `maugham:compiled_at` (ISO8601)

**EPUB metadata** is written into the OPF manifest by the EPUB packager:

- `dc:title`, `dc:creator`, `dc:subject`, `dc:language`, `dc:identifier` (= ISBN if set; otherwise a UUIDv5 derived from `project_id + version`)
- `meta` extensions: `maugham:version`, `maugham:label`, `maugham:checkpoint_id`, `maugham:compiled_at`

---

## 7. LaTeX engine: bundled tectonic

PDF compilation uses [tectonic](https://tectonic-typesetting.github.io/), bundled as a ~25 MB binary inside `Maugham.app`. Tectonic embeds the TeX engine and fetches packages on demand from the tectonic CDN, caching them under `~/Library/Caches/Maugham/tectonic/`.

**First-publish UX:** the first compile after install downloads ~150 MB of TeX Live packages from the CDN (typically 30–90s on a normal connection). Subsequent compiles work offline. Compile-job state machine surfaces a `phase: "fetching_packages"` value so Claude can tell the writer what's happening rather than "still running…"

**CDN dependency risk:** the tectonic CDN is run by the open-source tectonic-typesetting project. If it goes offline, users without cached packages cannot complete a first publish. Mitigations available in future versions: ship a pre-cached package bundle in the app (adds ~150 MB to app size); mirror the CDN on Anthropic infrastructure (real ops cost). v1 accepts the bare CDN dependency.

**Why not MacTeX:** 5 GB user install, admin password required, user-hostile failure modes for missing packages. Inappropriate for a self-contained Mac app.

**Why not Typst:** considered. Strengths: fully bundled, no CDN, modern syntax. Rejected because Claude's training depth on LaTeX is part of the differentiation story — "Claude writes bespoke typography" works better when Claude is writing in its strongest typesetting language. LaTeX is the deliberate choice; the CDN dependency is the accepted cost.

---

## 8. MCP surface

15 tools across 5 functional groups. Maugham goes from 20 to 35 MCP tools.

### 8.1 Initialization

- **`initialize_publish_template(force=false)`** — copies the bundled barebones template into `.maugham/publish/`. Refuses if already initialized unless `force=true`. Auto-called when a new project is created in Maugham; available via MCP for projects that predate the publishing feature.

### 8.2 Publish files (scoped file access)

Read/write of anything under `.maugham/publish/`. Paths are validated to prevent escape.

- **`list_publish_files()`** — enumerate files with sizes and mtimes.
- **`read_publish_file(path)`** — read a text file (UTF-8). Refuses binary content.
- **`read_publish_image(path, max_dimension=2048, quality=85, region?)`** — read an image (cover, font preview) via the existing crop-on-demand image-response infrastructure.
- **`write_publish_file(path, content, content_encoding="utf8")`** — write text or base64-binary content. Creates intermediate dirs. Path validated against `.maugham/publish/`.
- **`delete_publish_file(path, force=false)`** — remove. Refuses `template.tex`, `config.json`, `styles.css` unless `force=true`.

### 8.3 Config

- **`get_publish_config()`** — returns the current parsed config.
- **`set_publish_config(patch)`** — JSON-Merge-Patch update, schema-validated. Returns the new merged config plus any validation errors. Per-section overrides are settable via `patch.sections.<piece_id>`.

### 8.4 Compile actions

- **`compile(format, label?, wait_seconds=60)`** — full render. `format` ∈ `{"pdf", "epub"}`. Returns either `{status: "completed", version, label?, format, output_path, checkpoint_id, warnings[], errors[]}` or `{status: "in_progress", job_id, phase, started_at}` if `wait_seconds` elapsed without completion, or `{status: "failed", errors[], log_excerpt}` on early failure. `phase` ∈ `{"fetching_packages", "rendering_body", "compiling", "writing_output"}`. Creates a publication-checkpoint on success.
- **`preview_compile(format, section_ids?, max_pages?, wait_seconds=30)`** — fast subset compile. Same return shape. Does NOT create a checkpoint or bump version. Useful for "show me what chapter 3 looks like with the new drop cap macro" iteration.
- **`compile_status(job_id)`** — same return shape as `compile()`. Returns `{status: "not_found"}` for unknown / garbage-collected jobs (jobs are GC'd 24h after completion or cancellation).
- **`compile_cancel(job_id)`** — `{status: "cancelled" | "already_completed" | "already_failed" | "not_found"}`.

LaTeX errors are parsed by the compile tool — log files are not returned raw. Errors are surfaced as `{level: "error" | "warning", file, line, message, context_lines[]}` where `file` is relative to `.maugham/publish/`. The parser handles tectonic's standard error format.

### 8.5 Publications

- **`list_publications(version?, format?, limit?)`** — past publications with full metadata. Pulls from checkpoint store filtered to `Checkpoint.publication`. Single-element array for a specific version query (no separate `get_publication`).
- **`read_publication_page(version, page_number, max_dimension=2048, quality=85, region?)`** — rasterize one PDF page as an image via PDFKit. Uses the existing crop-on-demand image-response infrastructure. **This is the visual-feedback loop that makes Claude an effective typographic co-pilot** — without it, Claude is editing typography blind.
- **`republish(checkpoint_id, format?, label?)`** — re-render from a checkpoint snapshot using snapshotted template/config/styles (not current). Creates a new publication entry. Doesn't disturb live edits.

---

## 9. UI surface

Minimal Maugham UI additions. This is a Claude-driven feature; the writer interacts with publications mostly through Claude Desktop. But Maugham needs a few surfaces:

- **`Exports/` view in the binder.** A new collapsible section in the binder shows files under `Exports/`. Click to open in Preview.app (PDF) or default EPUB reader. Right-click to reveal in Finder, delete, or `Republish from this version` (opens a confirmation flow that calls `republish` under the hood).
- **Publish status indicator.** While a compile job is running, a small status pill near the toolbar shows `Publishing v0.3 — compiling…` (with the current `phase`). Clicking it opens a sheet with the log excerpt if errors occur.
- **Per-section overrides editor.** Inspector pane gains a "Publishing" section that surfaces the per-section overrides (`start_on`, `include_in_toc`, `title_override`) for the currently-selected piece. This is the writer's escape hatch — for setting per-section overrides without going through Claude.

That's it. No UI for templates, no UI for fonts, no UI for the LaTeX preamble — those are Claude's territory.

---

## 10. Workflows

### 10.1 First-time publish on an existing project

1. Writer opens an existing Maugham project that predates the publishing feature.
2. Writer asks Claude (in Claude Desktop): "Set up publishing for this project."
3. Claude calls `initialize_publish_template()`. The barebones template is copied into `.maugham/publish/`.
4. Claude calls `set_publish_config({metadata: {title: "...", author: "..."}})` to set basic metadata.
5. Writer asks Claude: "Compile a PDF so I can see what it looks like."
6. Claude calls `compile(format="pdf")`. First-publish triggers the CDN package download; `wait_seconds=60` returns `{status: "in_progress", phase: "fetching_packages"}`. Claude polls `compile_status()` and reports progress.
7. Compile completes. PDF lands in `Exports/Title-v0.1.pdf`. Claude calls `read_publication_page(version="0.1", page_number=1)` to render page 1 as an image and shows it to the writer.
8. Writer says: "This looks like a thesis. I want something more polished — let's design something."
9. Claude and writer iterate: Claude reads the relevant partial, proposes changes, calls `preview_compile(section_ids=[first_chapter])`, calls `read_publication_page()` to see the result, iterates.
10. Once satisfied, writer asks for a real publish. Claude calls `compile(format="pdf", label="initial")`. v0.2 is born.

### 10.2 Routine republish after content edits

1. Writer has been editing the manuscript over a week.
2. Writer asks Claude: "Compile a new EPUB."
3. Claude calls `compile(format="epub")`. EPUB is rendered against current template/styles/config. v0.7 is born; previous v0.3, v0.4, etc. are untouched.

### 10.3 Reproduce a historical publication

1. Writer wants to send a friend the same PDF they shared last month, but the cover image has since been replaced.
2. Writer asks Claude: "Republish v0.3 as a PDF."
3. Claude calls `list_publications(version="0.3")` to confirm what was published. Gets back `[{version: "0.3", checkpoint_id: "chk-abc123", ...}]`.
4. Claude calls `republish(checkpoint_id="chk-abc123", format="pdf")`. The snapshotted template/config/styles (including the original cover image bytes) are extracted to a temporary directory; tectonic compiles against them. v0.8 is born, with `republished_from: "v0.3"` in metadata.
5. PDF is identical to the original v0.3.

### 10.4 Typographic iteration

1. Writer says to Claude: "The drop caps on chapter opens are too tall."
2. Claude calls `read_publish_file("prose.tex")`, reads the relevant macro.
3. Claude edits the macro, calls `write_publish_file("prose.tex", new_content)`.
4. Claude calls `preview_compile(format="pdf", section_ids=[first_chapter], max_pages=3)`.
5. Claude calls `read_publication_page()` to see the result.
6. If too short, iterate. If looks good, ready for the next full publish.

---

## 11. Scope-out (deferred)

Explicitly NOT in v1. Each is its own future milestone:

1. **Industry-grade standalone screenplay PDF.** MORE/CONT'D across page breaks, scene number management, dual-dialogue rules, revision color marks. The barebones screenplay rendering produces Courier 12 with correct margins — not WGA-submission grade. Already a separate roadmap item.
2. **FDX export.** Already a separate roadmap item.
3. **Word/.docx output.** Adds a third pipeline. Possible follow-up.
4. **Submission tracker.** Separate roadmap concern.
5. **Cover image generation.** Claude can write cover bytes via `write_publish_file` from any image source it has access to (including its own image-generation tooling); Maugham doesn't ship a cover-design feature.
6. **Page-fit / page-count-target compilation.** Useful for short fiction submissions ("fit to N pages"). Possibly a `preview_compile` variant later.
7. **Publication diffing.** "Show me what changed between v0.2 and v0.3 PDFs." Hard to do well; defer.
8. **User-defined starter library.** If writers later want to save their tuned templates as personal starters.
9. **Multi-volume projects.** A trilogy as one publishing project producing three PDFs with shared metadata.
10. **Print-on-demand pre-flight.** PDF/X conformance, bleed marks, ICC profiles. Its own focused milestone.
11. **Curated starter library.** Multiple polished starters beyond the barebones one. We may revisit if writers ask for them.

---

## 12. Non-goals (this milestone explicitly does not promise)

- **"Award-winning typography."** The target is "high-quality sharable." LaTeX/tectonic plus a Claude-authored bespoke template will produce typographically distinctive PDFs — but typographic refinement to print-publisher-camera-ready grade requires multiple rounds of tuning and a typographer's eye. v1 enables that conversation; it doesn't guarantee its outcome.
- **A no-code path.** The writer who refuses to ever look at LaTeX is not the target audience for v1. The target is writers who work with Claude as a collaborator and trust Claude to handle the typography while they direct the aesthetic.
- **Workflow parity with Scrivener / Vellum / Ulysses' Compile features.** Those tools optimize for "click button, get book." Maugham's publishing optimizes for "Claude designs your book with you." Different model.

---

## 13. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Tectonic CDN goes offline | v1 accepts the dependency. Future option: bundle pre-cached package set (~150 MB) or self-host mirror. |
| First-publish takes >60s on slow connection | The hybrid compile-timing model (`wait_seconds` + `job_id` fallback + `compile_status`) handles this cleanly. |
| LaTeX compile errors are gnarly | The compile tool parses tectonic's log into structured errors. Claude reads these and iterates with the writer. |
| Publication checkpoint storage grows unbounded | Acceptable for v1. Future cleanup tool prunes old publications by age or count. |
| Writer accidentally deletes `template.tex` | `delete_publish_file` refuses to remove `template.tex`, `config.json`, `styles.css` without `force=true`. |
| Two writers (or one writer on two machines) edit `template.tex` concurrently via iCloud | Existing `NSFileCoordinator/NSFilePresenter` plumbing extended to `.maugham/publish/` files. Conflict resolution UI mirrors manuscript conflict resolution. |
| 35 MCP tools exceeds Claude's working-memory comfort | Tool descriptions carry the load. Categories are tight and self-contained. Tool catalog with categories/search is a future concern, not v1. |

---

## 14. Open questions for implementation

These are decisions that don't need writer input but will surface during implementation:

- **Body emitter output location:** `.maugham/publish/build/body.tex` and `body.xhtml`. Cleared between compiles? Kept for tectonic incremental? Likely kept (tectonic benefits from incremental aux files); user clears via a manual action if needed.
- **Job manager backing:** in-memory Swift `Task` dictionary keyed by UUID, GC'd 24h after terminal state. No persistence across Maugham restart — in-flight compiles on quit are cancelled.
- **Snapshot storage format:** publication-checkpoint blob serialized as a single `.json` (text fields) plus a sibling `.tar` (cover + font bytes) under `.maugham/checkpoints/<id>/publish/`. Or one large JSON with base64-encoded binary. The tar variant is friendlier for big binaries but adds tar dependency; the all-JSON variant is uniform with existing checkpoint storage. Lean toward all-JSON for v1 uniformity.
- **Tool-error UI:** when a `compile()` returns a failure, how does the Maugham UI show it vs. how does Claude see it? Probably: Maugham UI shows the publish status pill in error state with a sheet listing the structured errors; Claude gets the same structured errors via the MCP response.

---

## 15. What success looks like

At the end of this milestone, the writer can:

1. Take their current mixed-content collection
2. Ask Claude in Claude Desktop: "Set up publishing for this and design a polished typographic identity for it"
3. Iterate with Claude on typography over a session or three — Claude proposes drop-cap macros, scene-break ornaments, font choices; the writer reacts; Claude refines
4. End with `Stories from the Edge-v0.5.pdf` and `Stories from the Edge-v0.5.epub` in `Exports/`, with publication metadata embedded, reproducible from checkpoint
5. Email the PDF to a friend, send the EPUB to another, share via AirDrop, whatever

The PDF should look distinctively *theirs* — not "a generic LaTeX novel," not "the Maugham house style," but a book they and Claude designed together. This is the differentiation. Generic HTML→PDF is everywhere; Claude-authored bespoke typography per project is the moat.
