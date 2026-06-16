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
