# Publishing to PDF & EPUB

Maugham can publish your project to PDF and EPUB directly from Claude Desktop. The PDF pipeline uses a bundled copy of tectonic (an XeTeX-based LaTeX engine) so there's nothing to install — just ask Claude to set up publishing for your project.

### A deeply personal PDF

The real power of the PDF output is the template. Claude co-authors a bespoke LaTeX template tuned to your typographic taste: your preferred font (from a `.otf` or `.ttf` you provide, or a system font via fontspec), your chapter-head styling, your drop caps, your ornaments. Ask Claude what you want — *"I'd like a classic serif feel with small-caps chapter titles and a fleuron between scenes"* — and it iterates on `preamble.tex` and `template.tex` until the rendered page looks right. PDF output is closed-loop: Claude edits the template, compiles, and reads the resulting page image directly, so it can see what changed.

### Clean EPUB

The EPUB output produces a structurally clean file with one `<section>` per piece, embedded fonts, and a `styles.css` you can tune. Because EPUB rendering varies by reading application (Books, Kindle, Calibre), EPUB iteration is open-loop: Claude proposes a CSS change, compiles, and then you load the new `.epub` in your reader and describe what you see. Claude iterates from your description.

### Where outputs land

Compiled PDFs and EPUBs appear in the project's `Exports/` folder, which is shown as a segment in the binder. You can open the file from there or find it in Finder alongside your manuscript folder.

### The publish configuration

The template, preamble, per-piece style files, and a small `config.json` live under `.maugham/publish/` inside your project folder. `EMISSION.md` in that folder is the authoritative contract describing what the body emitter produces for each source pattern — Claude reads it to understand what LaTeX the emitter will generate before writing template hooks. If you want to inspect or hand-edit the template, it's plain text at `.maugham/publish/template.tex`.

### Getting started with publishing

Ask Claude: *"Set up publishing for this project."* It will scaffold the initial template and config, run a test compile, and show you the first page. From there it's an iterative conversation: describe the look you want, and Claude tunes the template until it's right.

### Language editions and version families

A publication is identified by three dimensions: **version, language, and format** — so `1.0/en/pdf`, `1.0/es/pdf`, and `1.0/es/epub` coexist as one family.

**The source edition is the authority:** Compile your manuscript in the source language first (no `language` parameter). This is when `next_version` bumps — each source compile gets the next available version number. Once a source publication exists at `1.0`, you can compile translated editions of it.

**Language editions are renderings of existing source versions:** `compile language:es` (without a `version` parameter) renders the latest source publication's version as a Spanish edition — it borrows that source's version number (e.g., `1.0`) as its identity. If you want to pair a translation with a *specific* earlier source version, pass `version: 1.0` alongside `language: es`. Importantly, language compiles never bump `next_version` — translations don't mint new versions, they render existing ones.

The manuscript text in a language edition is the *current* text, not the frozen text from when the source version was compiled. The same holds for the edition's *piece set*: a pinned edition renders the pieces currently included (sections you exclude or include after the source compile change the edition accordingly), and republishing reproduces that historical included subset from the snapshot. If you need to reproduce a translation exactly as it was, use `republish` on that edition to recreate its output from the same snapshot. Note that republished `-r…` rows sit outside the version families — they carry a distinct republish-marked version and aren't themselves pinnable as an edition's source version.

**Failing-loudly:** If you try to compile a language edition but no source publication exists yet, it refuses with a clear message: *"compile the source edition first or pass version."*

**Coverage gate:** Language editions are behind a translation-coverage gate: paragraphs that aren't yet translated (or are stale because the source changed) block the compile by default. `dry_run: true` answers "would this edition compile right now?" without producing output. If you want to publish a partial edition anyway (for a preview), pass `allow_stale: true` to override the gate.

**Filenames and language tags:** Output filenames auto-suffix with the language (e.g. `-es`) unless your `filename_template` includes a `{language}` placeholder. If it does, that placeholder expands to the language tag for translations, and to nothing for the source edition. The template engine is smart about separators: if a placeholder expands to empty (the source case) and is immediately preceded by a separator like `-`, `_`, or `.`, that separator is dropped, so a single template `{title}-v{version}-{language}.{ext}` yields clean names like `Playlist-v1.0.pdf` and `Playlist-v1.0-es.pdf`.

**Template variants by language:** Compiling with a `language` set resolves `template.<lang>.tex` and per-piece `<piece>.<lang>.tex` automatically when they exist, falling back to the base file otherwise. This resolution only covers the template and per-piece style files themselves — it doesn't follow `\input` lines inside them. If your template inputs partials (preamble, frontmatter, backmatter), the edition needs its own `template.<lang>.tex` whose `\input` lines point at the `<lang>` partial variants; the resolver picks the template variant, and everything else follows from it.

### Iterating on a subset of a book

For a multi-piece collection, you don't have to recompile the whole thing to check one piece's typography. Turn off `sections.<id>.include` for the pieces you want to skip, then run `preview_compile` (pass `language` too, for a translated edition) to render just the included subset without touching the project's published version history — `compile`'s `dry_run` option is the companion check when you just want to know whether an edition's translation-coverage gate would pass, without producing output at all. `read_preview_page` closes the loop the same way `read_publication_page` does for a real Publication — Claude reads the rendered page directly rather than working blind. Once the subset looks right, turn the excluded sections back on and compile the full edition.
