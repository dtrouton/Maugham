# Publishing to PDF, EPUB & Word

Maugham can publish your project to PDF, EPUB and Word (.docx) directly from Claude Desktop. The PDF pipeline uses a bundled copy of tectonic (an XeTeX-based LaTeX engine) so there's nothing to install — just ask Claude to set up publishing for your project.

### A deeply personal PDF

The real power of the PDF output is the template. Claude co-authors a bespoke LaTeX template tuned to your typographic taste: your preferred font (from a `.otf` or `.ttf` you provide, or a system font via fontspec), your chapter-head styling, your drop caps, your ornaments. Ask Claude what you want — *"I'd like a classic serif feel with small-caps chapter titles and a fleuron between scenes"* — and it iterates on `preamble.tex` and `template.tex` until the rendered page looks right. PDF output is closed-loop: Claude edits the template, compiles, and reads the resulting page image directly, so it can see what changed.

### Clean EPUB

The EPUB output produces a structurally clean file with one `<section>` per piece, embedded fonts, and a `styles.css` you can tune. Because EPUB rendering varies by reading application (Books, Kindle, Calibre), EPUB iteration is open-loop: Claude proposes a CSS change, compiles, and then you load the new `.epub` in your reader and describe what you see. Claude iterates from your description.

### Where outputs land

Compiled PDFs, EPUBs and Word files appear in the project's `Exports/` folder, which is shown as a footer beneath the binder tree in Author, Review, and Publish (Plan's centre column is the planning canvas, so it doesn't carry this footer). You can open the file from there or find it in Finder alongside your manuscript folder.

### The Publish persona's centre column

Switch to Publish (⌘4) and the centre column shows your compiled book — full-width, scrollable, the real PDF. It shows at *project* level: the project row, a group, or nothing selected. Select a chapter and the editor opens on it exactly as it does in Author, because a proof you're reading is a proof you're about to fix — a line to re-break, a heading to shorten. Click back up to the project row and the book is there again, on the same open document underneath.

Where there's more than one compiled PDF, the header carries a picker: version, language and compile time, newest first, and choosing one puts that file on screen. It's for comparing a proof against the last one, or a translated edition against its source. EPUBs aren't listed — they're not pages this column can draw, and they're in the Exports footer. The choice lasts as long as the window: a new compile snaps the preview back to the book you just made, and so does reopening the project.

Nothing compiled yet? Publish shows the project at altitude — the same corkboard/table Author shows for the project row (see [Structure & the Binder → The project row](structure-and-binder.md#the-project-row)) — with a standing note saying there's no compiled book yet. If the publications catalog is there but can't be read, you get the corkboard and a different notice, one that names the file and says what went wrong: a book that can't be read from disk is never reported as a book you never made. Selecting a research note or palette card in Publish leaves the centre column on the book (or on the corkboard and its notice) — Publish has no rendering of its own for research material.

### The publish configuration

The template, preamble, per-piece style files, and a small `config.json` live under `.maugham/publish/` inside your project folder. `EMISSION.md` in that folder is the authoritative contract describing what the body emitter produces for each source pattern — Claude reads it to understand what LaTeX the emitter will generate before writing template hooks. If you want to inspect or hand-edit the book's own template, it's plain text at `.maugham/publish/template.tex` — a project may also declare additional named [imprints](#imprints), each with a template of its own.

### Getting started with publishing

Ask Claude: *"Set up publishing for this project."* It will scaffold the initial template and config, run a test compile, and show you the first page. From there it's an iterative conversation: describe the look you want, and Claude tunes the template until it's right.

### Word export

Ask for the `docx` format and Maugham writes a native Word file: headings, lists, tables with a repeating header row, figures, footnotes, captions and cross-references are real Word elements, not pasted text. It's meant for sending a draft to someone who works in Word, so it follows the same rules as the other formats for what the book contains, and it has no template to design.

**A Word export is a draft, not a version.** It never takes the next version number, so it doesn't use up a version of your PDF or EPUB. Each export is "Draft 1", "Draft 2" and so on, counted across the book, and the file is named `<title>-draft1.docx`. A label inside the file reads "Draft N, sent <date>" (the date is your local day, in the book's language). A republish of a Word export keeps its draft label and doesn't write a new one.

**The sent copy.** Every Word export also leaves a copy of what you sent, under `.maugham/exports/` in the project: the exported file, plus a record of each piece's paragraphs as they were. It isn't shown anywhere yet; it's kept so a later feature can compare a returned document to what went out. Bringing a returned .docx back into Maugham isn't built yet.

**Styles.** The file uses Word's own styles (Heading 1 to 3, Caption, Table Grid, and so on). To change how they look, put a `reference.docx` in `.maugham/publish/`: the styles in it are used in place of the built-in ones, matched by id or by Word's style name, so a localised Word works too. Nothing else in that file is used. If it can't be read, the export still happens with the built-in styles and says so.

**Figures.** Word takes PNG, JPEG and GIF as they are. A PDF or SVG figure is converted to a picture (a PNG at 200 dpi, a PDF's first page) before it goes in. Because that happens after the publish checks, `dry_run` can't tell you a PDF or SVG won't convert; the real export will.

**Lists of figures and tables.** The Word file numbers its figures and tables with Word captions but doesn't build a list of them or a table of contents. Insert your own in Word (Insert ▸ Table of Figures, References ▸ Table of Contents).

**Paper size** follows the book's language: Letter for a US or Canadian region, A4 otherwise. A language with no region, such as "en", takes this Mac's region.

### Tables, figures, footnotes, citations and cross-references

A published PDF or EPUB renders these from plain Markdown in your manuscript. Nothing is hidden in the file: what you type is what's on disk.

**A table** is a pipe table, with its caption on a `Table:` line directly under it. Colons in the second row set each column's alignment (`:--` left, `:-:` centred, `--:` right):

```
| Region | Sales |
|:--|--:|
| North | 120 |
Table: Sales by region {#tbl:sales}
```

Every table is numbered — "Table 1", "Table 2" — across the whole book, captioned or not. In the PDF a long table runs across pages and repeats its header row on each.

**A figure** is an image alone on its own line, its caption in the brackets:

```
![The study area](../research/map.png){#fig:map}
```

The image must be in a research folder of the project — the project's `research/` folder, or a Collection piece's own `research/` — and the path is written from the piece's own file, as a Markdown previewer would read it (a chapter in `manuscript/` reaches `research/` with `../research/`). A path that leaves the project or points outside research is refused, and so is a file the output can't show: the PDF takes PNG, JPEG and PDF images; the EPUB takes PNG, JPEG, GIF and SVG; Word takes PNG, JPEG, GIF, PDF and SVG. Figures are numbered "Figure 1", "Figure 2" across the book.

You don't have to write the line yourself: **Insert ▸ Figure…** (⌘⇧I), dragging an image or PDF file onto the page, or pasting a picture copies it into the piece's research — the project's `research/` folder, or a Collection piece's own — and writes the figure line as a paragraph of its own, with "Caption" selected for you to type over. In a novel the copy is also linked to the chapter. PNG, JPEG, GIF, PDF and SVG files are copied as they are; any other picture (HEIC, TIFF, WebP, BMP…) is saved as a PNG under its own name, so every output can show it. The label comes from the file's name (`Site Map.png` → `{#fig:site-map}`, accents dropped), with `-2`, `-3` added when the book already uses it. Pasting text copied from Word, Pages or Excel pastes the text, never a picture of it. If the copy fails nothing is written and a notice says so; if you type while a large image copies, the figure goes above the paragraph you dropped it in, and your cursor stays where you are typing. A figure that lands after you've moved on never takes the cursor or the focus; only if you're still where you dropped it is "Caption" selected. While you're composing with an input method (Japanese, Chinese, accents held down) the figure waits for you to finish. ⌘Z takes the figure line back in one step, but the copy stays in research — and so does it if you switch to another document before the figure lands, in which case nothing is written. Delete it in research if you don't want it.

**A footnote** is a marker in the text and a definition anywhere in the same piece:

```
A claim.[^1]

[^1]: Where the claim comes from.
```

Notes are numbered continuously through the whole book, whatever you call them — `[^1]` in two chapters is two different notes. In the EPUB a note is a pop-up footnote.

**A citation** names a research source by its citation key: `[@smith2026]`, with a page or other locator after a comma, `[@smith2026, p. 12]`, or several sources at once, `[@smith2026; @jones2025]`. It prints author–date — *(Smith 2026, p. 12)* — from the citation details the research source carries (its key, authors, title and year — set in the research inspector's **Citation** section), and the book ends with a **References** list of the sources it actually cites, sorted by author.

**A cross-reference** points at a label. Give a figure, a table or a heading a label in braces — `{#fig:map}`, `{#tbl:sales}`, `## Method {#sec:method}` — and write `@fig:map`, `@tbl:sales` or `@sec:method` anywhere in the book. It prints "Figure 1", "Table 2" or "Section 1.2", and in both the PDF and the EPUB it's a link. These words — and "References" and the lists' titles — follow the edition's language (a Serbian edition prints "Slika 1"), and you can change any of them under `element_words` in the publish config's `metadata`, or a translated edition's `language_overrides`. A label's name is letters, digits, `-` and `_`, starting with a letter or digit, and each label is used once in the book.

**Numbering is the edition's**: it counts every section the edition includes, even when you preview one chapter, so a figure in chapter 3 prints the same number in a preview as in the full compile, and a reference to a figure in another included chapter still reads correctly. A section the edition leaves out (its `sections.<id>.include` turned off, or one an imprint drops) is outside the book: it takes no number, adds no source to References, and isn't checked for problems — while a reference into it, from a chapter that is published, is a problem, because the book doesn't contain what it points at.

**In a Report**, headings are numbered too — 1, 1.1, 1.1.1, counted from the shallowest heading level the book uses, so a report whose sections are `##` headings reads 1, 2, 3 — and a reference to a heading reads "Section 1.2". A Report's PDF also opens with a list of figures and a list of tables, when it has any; its EPUB carries the same lists in its navigation. Piece titles are never numbered. In other books headings aren't numbered, and a reference to a heading prints the heading's own words.

**When something doesn't resolve** — a key no research source carries, a reference to a label that doesn't exist, a footnote with no definition, an image that can't be used — it prints as you typed it, never as "??", and it's reported as a publish problem (see **Publish problems** under [Language editions and version families](#language-editions-and-version-families)). A Report refuses to compile until its errors are fixed; every other book compiles and lists them as warnings.

**The problems list.** When a compile from the desk (⌘⌥K, see [The Publish Department](publish-department.md)) finds publish problems, its status line says so — *"Couldn't publish: 3 problems in the manuscript"* for a Report it refused, or *"Compiled v1.0 · 20 Oct 2026 at 15:04 — in Exports, with 2 warnings"* for a book that compiled — and **Show Problems** beside it opens the list in the centre column. Each row says Error or Warning, names its piece and says what's wrong; **Show in Manuscript** opens that piece and scrolls to the very paragraph, including a paragraph in a translated edition. **Back** returns to the book.

### Language editions and version families

A publication is identified by three dimensions here — **version, language, and format** — so `1.0/en/pdf`, `1.0/es/pdf`, and `1.0/es/epub` coexist as one family. (A fourth dimension, imprint, is covered in [Imprints](#imprints) below; the book's own publications are the ones no imprint compiled.)

**The source edition is the authority:** Compile your manuscript in the source language first (no `language` parameter). This is when `next_version` bumps — each source compile gets the next available version number. Once a source publication exists at `1.0`, you can compile translated editions of it.

**Language editions are renderings of existing source versions:** `compile language:es` (without a `version` parameter) renders the latest source publication's version as a Spanish edition — it borrows that source's version number (e.g., `1.0`) as its identity. If you want to pair a translation with a *specific* earlier source version, pass `version: 1.0` alongside `language: es`. Importantly, language compiles never bump `next_version` — translations don't mint new versions, they render existing ones.

The manuscript text in a language edition is the *current* text, not the frozen text from when the source version was compiled. The same holds for the edition's *piece set*: a pinned edition renders the pieces currently included (sections you exclude or include after the source compile change the edition accordingly), and republishing reproduces that historical included subset from the snapshot. If you need to reproduce a translation exactly as it was, use `republish` on that edition to recreate its output from the same snapshot. Note that republished `-r…` rows sit outside the version families — they carry a distinct republish-marked version and aren't themselves pinnable as an edition's source version. A republish always writes its own file: the `-r` version is minted before the compile runs, so it goes into the filename and into the version stamped inside the artifact, the edition you republished from keeps its own file in `Exports/` untouched, and republishing the same edition twice leaves you with two distinct files rather than one overwritten one.

**Failing-loudly:** If you try to compile a language edition but no source publication exists yet, it refuses with a clear message: *"compile the source edition first or pass version."* And if a compile of the same version, language and format is already running, a second one refuses straight away — *"Publication v1.0 (source, pdf) on the book is already compiling; wait for it to finish."* (under an imprint it says *"under imprint 'special'"* instead — the book and an imprint each count their own versions, so a refusal has to say whose v1.0 it means) — instead of racing it into a half-written file. Poll the one in flight with `compile_status`, or compile a different *language* in the meantime — language editions of the same book still compile side by side. Two formats of the same source at once is the one pairing worth waiting out: which version each ends up carrying depends on which finishes first. A `dry_run` is never refused by any of this — it asks a question and changes nothing, so it answers even while the real compile runs. And if something is already sitting at the filename a republish is about to write, it stops and tells you the path rather than deleting the file: move it aside yourself and republish again.

**Coverage gate:** Language editions are behind a translation-coverage gate: paragraphs that aren't yet translated (or are stale because the source changed) block the compile by default. `dry_run: true` answers "would this edition compile right now?" without producing output. If you want to publish a partial edition anyway (for a preview), pass `allow_stale: true` to override the gate.

**Publish problems:** A cross-reference that points nowhere, a citation key no research source carries, a label used twice, a footnote with no definition, or a figure image that can't be used is a publish problem, and each one names the piece and the paragraph it came from. In a Report, those problems stop a `compile` or `republish` before any version is minted; the smaller ones (an unused footnote, a malformed label) are only warnings. In every other kind of project nothing stops — a novel that happens to say `[@sarah]` still compiles, with a warning. A preview never stops on them either, and `dry_run` lists them without compiling.

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

**From the app, not just MCP.** The Publish persona's desk (⌘⌥K) carries this same choice in its header: **Book**, then one row per declared imprint. Pick one and it's what the whole desk — the language rows, their counts, **Compile…** — is about, remembered per project so you don't have to re-pick it every session. See [The Publish Department](publish-department.md#which-book-the-desk-is-about).

### Bilingual editions

A book doesn't have to choose one language per file. Pass `languages` to `compile` or `preview_compile` — an ordered list, e.g. `["en", "sr"]` — and you get one document holding a complete body per language, **sequential and unrotated**: the source runs start to finish, then the translation runs start to finish, never interleaved paragraph by paragraph. Each half is meant to read as a film in its own right — a Serbian reader gets a Serbian book, not a bilingual facing-page curiosity — rather than as a study aid for comparing the two side by side.

Say which body is the untranslated one with `"source"` in the list, or just name the book's own `metadata.language` directly — both spellings mean the same body. A `languages` set that includes the source is a source compile: it mints at `next_version` and bumps the counter, same as an ordinary source compile today. A set without the source is an edition of an *existing* source version, exactly like today's single-language `language: es` — it doesn't mint a new version. `languages: ["sr"]` is equivalent to `language: "sr"`; if you pass both, they have to agree, or the compile refuses. The same reading applies to the older single `language` parameter: naming your book's own tongue — `language: "en"` on a book whose `metadata.language` is `en` — names the *source* body, so it is a source compile like any other. It mints at `next_version` and bumps the counter, and no translation-coverage gate runs, because there is nothing to translate; it does not go looking for an existing English edition to render. Duplicate or invalid tags refuse the same way a single bad tag always has.

**The identity carries every language, joined.** A bilingual compile of English and Serbian is `(imprint, version, "en+sr", format)` — its own publication, sitting beside the English-only and Serbian-only editions of the same version rather than overwriting either. The filename's `{language}` placeholder expands to `en+sr` the same way it expands to `es` for a single translated edition; `list_publications`'s `language` filter and `read_publication_page` match the joined string exactly, not either half of it. A bilingual publication counts as a source edition for version-pinning purposes when its set includes the source body, same as any other source compile.

**The gate runs once per translated tongue.** Each language in the list gets its own translation-coverage check; a compile refuses only if at least one blocked tongue exists, and when it does, the refusal lists *every* blocked tongue's errors together — not just the first — each prefixed with its own tag (e.g. `[sr] paragraph ¶3f2a is untranslated`) so you can see every gap in one pass rather than compiling once per language to find them all. `allow_stale` applies uniformly: pass it and every tongue with gaps falls back to source text for the missing paragraphs instead of blocking.

**`MaughamBody` is the seam between the halves.** `build/body.tex` is no longer the book itself but a thin wrapper: a guard line that defines a default `MaughamBody` environment if your template hasn't, followed by one `\begin{MaughamBody}{<tag>}...\end{MaughamBody}` block per rendered language, each `\input`-ing that language's own body and metadata. The default behavior is a `\clearpage` between halves and nothing else — a single-language compile still emits exactly one `MaughamBody` block and paginates exactly as it always has. To give each half its own title page, redefine the environment in your template and key the frontmatter on its argument:

```latex
\renewenvironment{MaughamBody}[1]{\clearpage\input{frontmatter-#1}}{}
```

`#1` is the language tag, so that line expects a `frontmatter-en.tex` and a `frontmatter-sr.tex` sitting beside the template — the starter `preamble.tex`'s own commented-out `MaughamBody` example shows the same pairing.

The document-level title page, running heads and PDF metadata are always the **first** listed body's — a bilingual PDF is one book, titled in its source language, with the translated half's own title (if any) applying only inside its own `MaughamBody` group.

**Per-body metadata comes from `language_overrides`**, the same config key that already drives a single translated edition's title, subtitle and the rest — nothing new to configure for a second language beyond what an ordinary `language: sr` compile would already need.

**Every paragraph carries its own place.** A compiled document — bilingual or not — anchors every paragraph invisibly, so a template (or a reader's PDF viewer following a link) can address any paragraph directly. In a multi-language compile, that anchor is what lets a **scene heading link across the halves**: tap a slugline in one language's half and you land on the same scene in the other. In the EPUB, the same tap crosses from one language's section file into the other's. Only sluglines cross-link today — it's the case a bilingual screenplay reader reaches for first — everything else anchors but doesn't yet link anywhere.

**From the app, not just MCP.** The Publish persona's desk (⌘⌥K) is where you make one of these documents without asking Claude for it: **Compile…** at the foot of the Languages section opens a sheet with a checkbox per edition — the book's own language plus every language on the desk — and compiling more than one gives you a single volume with every body you checked, in the order the sheet lists them. And every surface that names a compiled book — the desk's own status line, the Publish persona's compiled-book preview, the Exports footer — says the joined identity plainly (`EN+SR`), never a single tag standing in for a document that holds two. See [The Publish Department](publish-department.md#compiling-from-the-desk) for the sheet itself.

### Iterating on a subset of a book

For a multi-piece collection, you don't have to recompile the whole thing to check one piece's typography. Turn off `sections.<id>.include` for the pieces you want to skip, then run `preview_compile` (pass `language` too, for a translated edition) to render just the included subset without touching the project's published version history — `compile`'s `dry_run` option is the companion check when you just want to know whether an edition's translation-coverage gate would pass, without producing output at all. `read_preview_page` closes the loop the same way `read_publication_page` does for a real Publication — Claude reads the rendered page directly rather than working blind. Once the subset looks right, turn the excluded sections back on and compile the full edition.
