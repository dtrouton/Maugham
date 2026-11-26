# Publishing to PDF, EPUB & Word

Maugham publishes your project to PDF, EPUB and Word (.docx), from its own **Compile…** or by asking Claude in Claude Desktop. Everything it needs to make a PDF comes with Maugham, so there's nothing to install.

### A deeply personal PDF

The real power of the PDF output is the template. Claude co-authors a bespoke LaTeX template tuned to your typographic taste: your preferred font (from a `.otf` or `.ttf` you provide, or a system font via fontspec), your chapter-head styling, your drop caps, your ornaments. Ask Claude what you want — *"I'd like a classic serif feel with small-caps chapter titles and a fleuron between scenes"* — and it iterates on `preamble.tex` and `template.tex` until the rendered page looks right. PDF output is closed-loop: Claude edits the template, compiles, and reads the resulting page image directly, so it can see what changed.

### Clean EPUB

The EPUB output produces a structurally clean file with one `<section>` per piece, embedded fonts, and a `styles.css` you can tune. Because EPUB rendering varies by reading application (Books, Kindle, Calibre), EPUB iteration is open-loop: Claude proposes a CSS change, compiles, and then you load the new `.epub` in your reader and describe what you see. Claude iterates from your description.

### Where outputs land

Compiled PDFs, EPUBs and Word files go in the project's `Exports/` folder, listed in a footer beneath the binder. Open one from there, or find it in Finder beside your manuscript folder.

### Editions and their pages

Each language of the book is an edition, a row under **Editions** in the binder: the book's own language (**Source**) first, then each translation. Click one and the centre shows that edition's **Book** — the compiled PDF in its language, full width — with **Status** beside it in the toolbar. Click a chapter in the binder and the book scrolls to the page it starts on. A book compiled before this version says *Compile again to jump from the binder to the page*. Nothing compiled yet? The centre says *No compiled book yet*, with Compile… above it. If the list of publications can't be read, the centre says so and names the file: a book that can't be read is never reported as one you never made.

Where there's more than one compiled PDF of the edition, the header carries a picker: version and compile time, newest first, for comparing a proof against the last one. A new compile snaps back to the book you just made. EPUBs aren't listed — they're not pages the centre can draw — and they're in the Exports footer.

**The edition's Status** has a column for each chapter's publishing settings — whether it's in the table of contents, which page it starts on, its title override. Set them per chapter with **Publishing…** in the chapter's row menu.

### Compiling an edition

**Compile…**, in the header of an edition's Book, makes the book. It is the same compile Claude runs, asked for by you. The sheet asks:

- **Format** — PDF, EPUB or Word (.docx).
- **Editions** — this edition is checked to begin with, and every other edition gets a checkbox. Check more than one and you get a single volume with each body in it, in the order the sheet lists them ([Bilingual editions](#bilingual-editions)).
- **Allow stale translations** — off by default, which is what stops a paragraph whose source changed shipping unnoticed.

The **imprint picker** beside Compile… chooses which book: **Book**, or one of the imprints the project declares ([Imprints](#imprints)). It's remembered per project.

One compile runs at a time. While it does, the header says so with **Cancel Compile**; a cancelled compile publishes nothing. When one lands, the line says the version, the imprint and the edition, and where the file is. Nothing already published is touched: every compile makes its own version.

**The problems list.** When a compile finds publish problems, its line says so — *"Couldn't publish: 3 problems in the manuscript"* for a Report it refused, or *"Compiled v1.0 · 20 Oct 2026 at 15:04 — in Exports, with 2 warnings"* — and a compile that was stopped shows the list over the centre at once; one that only warned offers **Show Problems**. Each row says Error or Warning, names its chapter and says what's wrong; **Show in Manuscript** opens that chapter at the paragraph, in a translated edition too. **Back** returns to the book. A compile that stopped is also listed in every edition's To resolve until the next one succeeds.

### The designer

Every project has a designer from the moment it exists, **Tschichold**, named on the Source edition's Brief (with **Change…**). The designer reads the book and proposes its typesetting, and nothing reaches your live templates until you approve it.

**Run Design** sits at the head of the Source edition's To resolve, with a field for **direction** — a sentence or two about what this round should attend to. It's optional: a bare run briefs the designer on your [Visual Language](right-column.md#visual-language-v) alone. The designer proposes a spec and a complete set of templates, and compiles a few sample pages showing every kind of element your manuscript actually uses — a verse passage, a block quote, a footnote, whatever is really there.

**The gate.** A design waiting for your answer is listed in every edition's To resolve; **Show** opens it over the centre: the spec on one side, the sample pages on the other. A round is always for the whole book.

- **Approve** puts the round's templates onto your live publish templates. Your current ones are backed up first.
- **Request Changes** sends your words back to the session that made the proposal, and starts its next round.
- **Revert** takes an approved round back, restoring the templates it replaced.
- **Finalize** keeps an approved round for good and lets the backup go. It is the one step that can't be undone, and it asks first.
- **Discard** turns the proposal down.

Only the verbs that make sense for where a round stands are offered, and a reviewer is offered none. When a verb can't go through — another proposal holds the backup, a compile is running — it says why.

### The publish configuration

Your book's design lives in plain text files under `.maugham/publish/` in the project folder: its template, its settings, and a template for each [imprint](#imprints). Claude reads and edits them; you can open `template.tex` yourself in any text editor.

### Getting started with publishing

Ask Claude: *"Set up publishing for this project."* It will scaffold the initial template and config, run a test compile, and show you the first page. From there it's an iterative conversation: describe the look you want, and Claude tunes the template until it's right.

### Word export

Ask for the `docx` format and Maugham writes a native Word file: headings, lists, tables with a repeating header row, figures, footnotes, captions and cross-references are real Word elements, not pasted text. It's meant for sending a draft to someone who works in Word, so it follows the same rules as the other formats for what the book contains, and it has no template to design.

**A Word export is a draft, not a version.** It never takes the next version number, so it doesn't use up a version of your PDF or EPUB. Each export is "Draft 1", "Draft 2" and so on, counted across the book (an imprint keeps its own draft count), and the file is named `<title>-draft1.docx`. A label inside the file reads "Draft N, sent <date>" (the date is your local day, in the book's language). A Word export isn't republished: export again for the next draft. A language edition of the PDF or EPUB renders your latest version, never a Word draft.

**The sent copy.** Every Word export also leaves a copy of what you sent, under `.maugham/exports/` in the project: the exported file, plus a record of each piece's paragraphs as they were. The file names its sent copy inside it, and sent copies are included in backups.

**Styles.** The file uses Word's own styles (Heading 1 to 3, Caption, Table Grid, and so on). To change how they look, put a `reference.docx` in `.maugham/publish/`: the styles in it are used in place of the built-in ones, matched by id or by Word's style name, so a localised Word works too. Nothing else in that file is used. If it can't be read, the export still happens with the built-in styles and says so.

**Figures.** Word takes PNG, JPEG and GIF as they are. A PDF or SVG figure is converted to a picture (a PNG at 200 dpi, a PDF's first page) before it goes in. That happens only during the real export, so a check that the book would compile can't warn you that a PDF or SVG won't convert.

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

**A table figure** (a table made with Insert ▸ Table, or converted from a pipe table, whose line reads `![Caption](../figures/cash.csv){#tbl:cash}`) is numbered "Table n" like a pipe table, and publishes its computed cells: every formula is worked out, and numbers and dates are formatted in the edition's language (a Spanish or Serbian edition prints its own decimal comma). Money keeps the book's currency in every edition: a report in pounds prints pounds in its Spanish edition too, with Spanish separators. The PDF repeats the header row on each page and rules the total row above; the EPUB and Word draw the same table, Word with a repeating header row. A table with no header row simply has none. A table figure that nothing in the book names isn't published, and pipe tables are unchanged. Column widths aren't published.

**Table figure problems.** In a Report these stop a `compile` or `republish`; the book is not made until you fix them:

- *A formula error in a table* ("Table “cash” has an error in B4"): fix the cell in the table, then publish.
- *A table reads a Research source that is gone*: bring the source back into Research, or change the cells that read it.
- *A table couldn't be read*: its line prints as written; open the table in the Figures area to check it.
- *A figure is in Research* (it was sent there, and a line or reference still names it): bring it back into Figures, or remove the line and the references.
- *A table line points at no figure* (the path isn't a figure in Figures): fix the path, or make the table with Insert ▸ Table.
- *A table line names two figures* (two tables share its path): rename one of them in the Figures area.
- *A table line is labelled as a figure* (`{#fig:…}` on a `.csv` line): label it `{#tbl:…}`.

These only warn, and the book is made: a table line into a Research folder (written before `figures/` existed) publishes as the line is written, so move it into Figures to publish its cells; a table that uses numbers from Research; Research has changed since the table took its numbers (refresh it in the Figures area); and an `NPV` whose first cash flow is negative, which discounts that flow one period, as Excel does (add a flow that falls today outside the `NPV`). In any other kind of project everything here is a warning.

**A figure** is an image alone on its own line, its caption in the brackets:

```
![The study area](../research/map.png){#fig:map}
```

The image must be in the project's `figures/` folder or a research folder of the project — the project's `research/` folder, or a Collection piece's own `research/`, where figure lines written before `figures/` existed point — and the path is written from the piece's own file, as a Markdown previewer would read it (a chapter in `manuscript/` reaches `figures/` with `../figures/`). A path that leaves the project or points outside those folders is refused, and so is a file the output can't show: the PDF takes PNG, JPEG and PDF images; the EPUB takes PNG, JPEG, GIF and SVG; Word takes PNG, JPEG, GIF, PDF and SVG. Figures are numbered "Figure 1", "Figure 2" across the book.

You don't have to write the line yourself. **Insert ▸ Figure…** (⌘⇧I), dragging an image or PDF file onto the page, or pasting a picture makes an image figure:

- The file is copied into the project's `figures/` folder, and the figure belongs to the piece you're writing in.
- The figure line is written as a paragraph of its own, with "Caption" selected for you to type over.
- PNG, JPEG, GIF, PDF and SVG files are copied as they are. Any other picture (HEIC, TIFF, WebP, BMP…) is saved as a PNG under its own name, so every output can show it.
- The figure's name, its file's name and its label come from the file's name, accents dropped: `Site Map.png` → `figures/site-map.png` and `{#fig:site-map}`. `_2`, `_3` are added when the book or the `figures/` folder already uses it.

Pasting text copied from Word, Pages or Excel pastes the text, never a picture of it.

**While a large image copies, keep typing.** The figure goes above the paragraph you dropped it in, and your cursor stays where you are typing. A figure that lands after you've moved on never takes the cursor or the focus; "Caption" is selected only if you're still where you dropped it. While you're composing with an input method (Japanese, Chinese, accents held down), the figure waits for you to finish. If the copy fails, nothing is written and a notice says so.

**⌘Z** takes the figure line back in one step, but the figure and its file stay in `figures/`. They stay there too if you switch to another document before the figure lands, in which case nothing is written.

**A footnote** is a marker in the text and a definition anywhere in the same piece:

```
A claim.[^1]

[^1]: Where the claim comes from.
```

Notes are numbered continuously through the whole book, whatever you call them — `[^1]` in two chapters is two different notes. In the EPUB a note is a pop-up footnote.

**A citation** names a research source by its citation key: `[@smith2026]`, with a page or other locator after a comma, `[@smith2026, p. 12]`, or several sources at once, `[@smith2026; @jones2025]`. It prints author–date — *(Smith 2026, p. 12)* — from the citation details the research source carries (its key, authors, title and year — set in its **Citation** details), and the book ends with a **References** list of the sources it actually cites, sorted by author.

**A cross-reference** points at a label. Give a figure, a table or a heading a label in braces — `{#fig:map}`, `{#tbl:sales}`, `## Method {#sec:method}` — and write `@fig:map`, `@tbl:sales` or `@sec:method` anywhere in the book. It prints "Figure 1", "Table 2" or "Section 1.2", and in both the PDF and the EPUB it's a link. These words — and "References" and the lists' titles — follow the edition's language (a Serbian edition prints "Slika 1"), and you can change any of them under `element_words` in the publish config's `metadata`, or a translated edition's `language_overrides`. A label's name is letters, digits, `-` and `_`, starting with a letter or digit, and each label is used once in the book.

**Numbering is the edition's**: it counts every section the edition includes, even when you preview one chapter, so a figure in chapter 3 prints the same number in a preview as in the full compile, and a reference to a figure in another included chapter still reads correctly. A section the edition leaves out (its `sections.<id>.include` turned off, or one an imprint drops) is outside the book: it takes no number, adds no source to References, and isn't checked for problems — while a reference into it, from a chapter that is published, is a problem, because the book doesn't contain what it points at.

**In a Report**, headings are numbered too — 1, 1.1, 1.1.1, counted from the shallowest heading level the book uses, so a report whose sections are `##` headings reads 1, 2, 3 — and a reference to a heading reads "Section 1.2". A Report's PDF also opens with a list of figures and a list of tables, when it has any; its EPUB carries the same lists in its navigation. Piece titles are never numbered. In other books headings aren't numbered, and a reference to a heading prints the heading's own words.

**When something doesn't resolve** — a key no research source carries, a reference to a label that doesn't exist, a footnote with no definition, an image that can't be used — it prints as you typed it, never as "??", and it's reported as a publish problem (see [The problems list](#compiling-an-edition)). A Report refuses to compile until its errors are fixed; every other book compiles and lists them as warnings.

### Language editions

Each translation of the book is an **edition** of a version you have already compiled in your own language. So compile the book in its own language first; a translated edition then takes that version's number (a Spanish 1.0 beside the English 1.0) and never uses up a new one. Its text is your book as it stands now, translated.

An edition with paragraphs that aren't translated yet, or whose source changed since they were, is refused, and the refusal names them. To compile it anyway, turn on **Allow stale translations** ([Compiling an edition](#compiling-an-edition)). Its file is named with its language, `My Novel-v1.0-es.pdf`.

To compile again with the design an earlier edition had — its template and settings as they were then — ask Claude to **republish** it. The text is your book as it stands now, not as it was. A republish writes a new file beside the old one and never overwrites it. A Word draft isn't republished: export again. If you want the book with its old words, the file you compiled then is still in Exports.

### Imprints

An **imprint** is a second book made from the same project — say, a special edition of one story, with its own look, its own contents, its own cover and its own version numbers — without copying the manuscript. Ask Claude to set one up. Once the project has one, the imprint picker beside **Compile…** chooses which book you are making: **Book**, or the imprint. An edition's coverage is counted over the imprint's own chapters, so the same Spanish edition can be unfinished for the novel and complete for a story cut from it.

### Bilingual editions

One volume can hold the whole book in two languages, one after the other — the first language from start to finish, then the second — never interleaved paragraph by paragraph: each half reads as a book in its own right. In **Compile…**, check more than one edition. The volume's title page and running heads are the first language's. In a screenplay, a scene heading in one half links to the same scene in the other. Everywhere a compiled book is named — the compile line, the edition's pages, the Exports footer — a bilingual volume says both languages, `EN+SR`. To give each half its own title page, ask Claude.

### Trying out part of a book

You don't have to compile the whole book to see how one chapter looks. Ask Claude to preview just the chapters you want: a preview uses no version number, and Claude can read the rendered page to check its work.
