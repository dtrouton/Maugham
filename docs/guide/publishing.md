# Publishing to PDF & EPUB

Maugham can publish your project to PDF and EPUB directly from Claude Desktop. The PDF pipeline uses a bundled copy of tectonic (an XeTeX-based LaTeX engine) so there's nothing to install — just ask Claude to set up publishing for your project.

### A deeply personal PDF

The real power of the PDF output is the template. Claude co-authors a bespoke LaTeX template tuned to your typographic taste: your preferred font (from a `.otf` or `.ttf` you provide, or a system font via fontspec), your chapter-head styling, your drop caps, your ornaments. Ask Claude what you want — *"I'd like a classic serif feel with small-caps chapter titles and a fleuron between scenes"* — and it iterates on `preamble.tex` and `template.tex` until the rendered page looks right. PDF output is closed-loop: Claude edits the template, compiles, and reads the resulting page image directly, so it can see what changed.

### Clean EPUB

The EPUB output produces a structurally clean file with one `<section>` per piece, embedded fonts, and a `styles.css` you can tune. Because EPUB rendering varies by reading application (Books, Kindle, Calibre), EPUB iteration is open-loop: Claude proposes a CSS change, compiles, and then you load the new `.epub` in your reader and describe what you see. Claude iterates from your description.

### Where outputs land

Compiled PDFs and EPUBs appear in the project's `Exports/` folder, which is shown as a footer beneath the binder tree in Author, Review, and Publish (Plan's centre column is the planning canvas, so it doesn't carry this footer). You can open the file from there or find it in Finder alongside your manuscript folder.

### The Publish persona's centre column

Switch to Publish (⌘4) and the centre column shows your compiled book — full-width, scrollable, the real PDF. It shows at *project* level: the project row, a group, or nothing selected. Select a chapter and the editor opens on it exactly as it does in Author, because a proof you're reading is a proof you're about to fix — a line to re-break, a heading to shorten. Click back up to the project row and the book is there again, on the same open document underneath.

Where there's more than one compiled PDF, the header carries a picker: version, language and compile time, newest first, and choosing one puts that file on screen. It's for comparing a proof against the last one, or a translated edition against its source. EPUBs aren't listed — they're not pages this column can draw, and they're in the Exports footer. The choice lasts as long as the window: a new compile snaps the preview back to the book you just made, and so does reopening the project.

Nothing compiled yet? Publish shows the project at altitude — the same corkboard/table Author shows for the project row (see [Structure & the Binder → The project row](structure-and-binder.md#the-project-row)) — with a standing note saying there's no compiled book yet. If the publications catalog is there but can't be read, you get the corkboard and a different notice, one that names the file and says what went wrong: a book that can't be read from disk is never reported as a book you never made. Selecting a research note or palette card in Publish leaves the centre column on the book (or on the corkboard and its notice) — Publish has no rendering of its own for research material.

### The publish configuration

The template, preamble, per-piece style files, and a small `config.json` live under `.maugham/publish/` inside your project folder. `EMISSION.md` in that folder is the authoritative contract describing what the body emitter produces for each source pattern — Claude reads it to understand what LaTeX the emitter will generate before writing template hooks. If you want to inspect or hand-edit the book's own template, it's plain text at `.maugham/publish/template.tex` — a project may also declare additional named [imprints](#imprints), each with a template of its own.

### Getting started with publishing

Ask Claude: *"Set up publishing for this project."* It will scaffold the initial template and config, run a test compile, and show you the first page. From there it's an iterative conversation: describe the look you want, and Claude tunes the template until it's right.

### Language editions and version families

A publication is identified by three dimensions here — **version, language, and format** — so `1.0/en/pdf`, `1.0/es/pdf`, and `1.0/es/epub` coexist as one family. (A fourth dimension, imprint, is covered in [Imprints](#imprints) below; the book's own publications are the ones no imprint compiled.)

**The source edition is the authority:** Compile your manuscript in the source language first (no `language` parameter). This is when `next_version` bumps — each source compile gets the next available version number. Once a source publication exists at `1.0`, you can compile translated editions of it.

**Language editions are renderings of existing source versions:** `compile language:es` (without a `version` parameter) renders the latest source publication's version as a Spanish edition — it borrows that source's version number (e.g., `1.0`) as its identity. If you want to pair a translation with a *specific* earlier source version, pass `version: 1.0` alongside `language: es`. Importantly, language compiles never bump `next_version` — translations don't mint new versions, they render existing ones.

The manuscript text in a language edition is the *current* text, not the frozen text from when the source version was compiled. The same holds for the edition's *piece set*: a pinned edition renders the pieces currently included (sections you exclude or include after the source compile change the edition accordingly), and republishing reproduces that historical included subset from the snapshot. If you need to reproduce a translation exactly as it was, use `republish` on that edition to recreate its output from the same snapshot. Note that republished `-r…` rows sit outside the version families — they carry a distinct republish-marked version and aren't themselves pinnable as an edition's source version. A republish always writes its own file: the `-r` version is minted before the compile runs, so it goes into the filename and into the version stamped inside the artifact, the edition you republished from keeps its own file in `Exports/` untouched, and republishing the same edition twice leaves you with two distinct files rather than one overwritten one.

**Failing-loudly:** If you try to compile a language edition but no source publication exists yet, it refuses with a clear message: *"compile the source edition first or pass version."* And if a compile of the same version, language and format is already running, a second one refuses straight away — *"Publication v1.0 (source, pdf) on the book is already compiling; wait for it to finish."* (under an imprint it says *"under imprint 'special'"* instead — the book and an imprint each count their own versions, so a refusal has to say whose v1.0 it means) — instead of racing it into a half-written file. Poll the one in flight with `compile_status`, or compile a different *language* in the meantime — language editions of the same book still compile side by side. Two formats of the same source at once is the one pairing worth waiting out: which version each ends up carrying depends on which finishes first. A `dry_run` is never refused by any of this — it asks a question and changes nothing, so it answers even while the real compile runs. And if something is already sitting at the filename a republish is about to write, it stops and tells you the path rather than deleting the file: move it aside yourself and republish again.

**Coverage gate:** Language editions are behind a translation-coverage gate: paragraphs that aren't yet translated (or are stale because the source changed) block the compile by default. `dry_run: true` answers "would this edition compile right now?" without producing output. If you want to publish a partial edition anyway (for a preview), pass `allow_stale: true` to override the gate.

**Filenames and language tags:** Output filenames auto-suffix with the language (e.g. `-es`) unless your `filename_template` includes a `{language}` placeholder. If it does, that placeholder expands to the language tag for translations, and to nothing for the source edition. The template engine is smart about separators: if a placeholder expands to empty (the source case) and is immediately preceded by a separator like `-`, `_`, or `.`, that separator is dropped, so a single template `{title}-v{version}-{language}.{ext}` yields clean names like `Playlist-v1.0.pdf` and `Playlist-v1.0-es.pdf`.

**Template variants by language:** Compiling with a `language` set resolves `template.<lang>.tex` and per-piece `<piece>.<lang>.tex` automatically when they exist, falling back to the base file otherwise. This resolution only covers the template and per-piece style files themselves — it doesn't follow `\input` lines inside them. If your template inputs partials (preamble, frontmatter, backmatter), the edition needs its own `template.<lang>.tex` whose `\input` lines point at the `<lang>` partial variants; the resolver picks the template variant, and everything else follows from it.

### Imprints

An **imprint** is a named publishing configuration living inside one project — its own template, its own rendered set of pieces, its own metadata, cover and filename, and its own version counter — chosen at compile time. It's how a collection ships both its book and, say, a single-piece special edition with a completely different look, without forking the project or the manuscript: both draw on the same pieces and the same translation layer.

Declare one under `imprints` in `.maugham/publish/config.json` (via `set_publish_config`'s merge patch):

```json
"imprints": {
  "special-glb": {
    "template": "templates/special-glb.tex",
    "sections": { "doc-2c6051f2": {} },
    "metadata": { "title": "Good Luck Babe", "subtitle": null },
    "cover": { "path": "covers/glb-cover.jpg" },
    "outputs": { "filename_template": "{title}-{imprint}-v{version}{language}{label_suffix}.{ext}" },
    "next_version": "0.1"
  }
}
```

**`sections` is an allowlist**, the inverse of the top-level rule: at the top level, absent means *included*; inside an imprint, absent means *excluded*. The imprint's map *is* its rendered set — naming a piece is what includes it, so a one-entry map ships exactly that one piece rather than the whole book. Each entry is a full section (`title_override`, `style_file`, `start_on`, `include_in_toc` all work per imprint). Everything else an imprint doesn't name (`metadata`, `outputs`, `cover`) merges over the project's own — `null` deletes a key, and an absent `sections` key inherits the project's map.

**Resolution happens once, at compile time**, before anything else runs: pass `imprint: "special-glb"` to `compile` or `preview_compile` and everything downstream — the emitter, the coverage gate, the snapshot — sees an ordinary, already-resolved config and never learns an imprint was involved. Omit `imprint` (or pass nothing) and you get the book, as always.

**Validation** happens both when you save the config and when you compile: an imprint name must match `[a-z0-9-]+`; its `template` must be a relative path that exists under `.maugham/publish/`; its `sections` allowlist, if given, must be non-empty and name only pieces that exist in the project. A *top-level* `imprint` key is refused at both doors: that field is set by resolution when you compile, never written — a hand-written one would misname the book's own output files while its catalog rows said otherwise. An imprint's own template is a **full** template — a peer of the book's `template.tex`, not a per-piece style-file hook — so it may `\usepackage` and set its own `\geometry` freely (`EMISSION.md` says the same). One more rule is about the *filesystem*, not the config: tectonic's output directory is flat and names each compiled file by the template's own basename, so an imprint's template basename (with any language suffix stripped) must differ from the book's and from every other imprint's, or one compile's output would silently overwrite another's intermediate files. And because tectonic resolves `\input` relative to the *template's own directory*, an imprint template living in a subdirectory (e.g. `templates/special-glb.tex`) reaches a shared `preamble.tex` at the project root with `\input{../preamble}`, not `\input{preamble}`.

**Identity gains a fourth dimension.** A publication is keyed on `(imprint, version, language, format)` — the book's `1.0/en/pdf` and the special edition's `0.1/en/pdf` are independent publications with independent version counters, and compiling one never blocks or races the other. `list_publications`, `read_publication_page`, `compile` and `preview_compile` all take an `imprint` parameter (exact name match); the sentinel `"book"` selects the publications no imprint compiled, mirroring `"source"` for the untagged source language. Output filenames carry a `{imprint}` token with the same strip-one-dangling-separator behavior as `{language}`; if your `filename_template` doesn't mention `{imprint}`, the imprint name is inserted before the extension automatically, so an imprint compile never overwrites the book's file.

### Iterating on a subset of a book

For a multi-piece collection, you don't have to recompile the whole thing to check one piece's typography. Turn off `sections.<id>.include` for the pieces you want to skip, then run `preview_compile` (pass `language` too, for a translated edition) to render just the included subset without touching the project's published version history — `compile`'s `dry_run` option is the companion check when you just want to know whether an edition's translation-coverage gate would pass, without producing output at all. `read_preview_page` closes the loop the same way `read_publication_page` does for a real Publication — Claude reads the rendered page directly rather than working blind. Once the subset looks right, turn the excluded sections back on and compile the full edition.
