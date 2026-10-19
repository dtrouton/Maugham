# Report foundations — design

**Status:** design approved in conversation 2026-10-19; awaiting Denver's review of this written spec.
**Milestone:** 1 of 4 in the non-fiction line (roadmap at the end).
**Inputs:** the foundations audit (`docs/superpowers/notes/2026-10-17-foundations-audit.md`, findings C2, C3, C4, C10 and §7's rulings) and the brainstorm of 2026-10-19.

## 1. Purpose

Maugham is a creative-writing editor. Its goal now is to support every kind of writing. Business writing (reports, proposals, memos) comes first, and long-form non-fiction follows. This milestone builds what every later step rests on:

- tables, footnotes, figures, citations and cross-references in manuscripts;
- real output for all of them in PDF and EPUB;
- a new Word (.docx) export;
- a **Report** profile.

**Success:** a writer creates a Report and writes a 20-page document with numbered sections, three tables, two figures from research, footnotes and cited sources. It publishes to a PDF that looks professionally typeset, with numbered captions, working cross-references and a References list. It exports to a Word file that opens cleanly in Word and Google Docs, with real footnotes, captions and tables.

## 2. Decisions (Denver, 2026-10-19)

| # | Decision |
|---|---|
| D1 | Business writing first; the design must serve every form of writing. |
| D2 | The final deliverable is a PDF. Drafts go out as Word files for collaboration and come back in (milestone 3). |
| D3 | A returned Word file becomes a **review**: each edit is a suggested change and each comment is a comment, labelled with the reviewer's name. Nothing touches the manuscript until the writer accepts. (Milestone 3; this milestone prepares the exports for it.) |
| D4 | Google Docs travels as Word files first; a direct Google connection comes later, on the same import and export. |
| D5 | Spreadsheets live in research; manuscript tables link to a range and refresh on re-import. (Milestone 3.) |
| D6 | **Figure** is one concept covering images, charts and diagrams: caption, number, cross-reference, list of figures. Sources arrive in order: images (this milestone), charts, then diagrams written as text. |
| D7 | Footnotes **and** citations of research items, in one house style, with a References list. Multiple styles and Zotero/BibTeX come later. |
| D8 | The new elements work in **every** project. A **Report** profile brings business defaults. |
| D9 | Report cast (milestone 2): Minto (structure), Orwell (plain English), Gould (copy), Lippincott (fact-checker, name provisional), and an executive first reader. |
| D10 | The fact-checker (milestone 2) checks research and the web. Web access is a **per-project switch**, on by default for Reports. |
| D11 | Text on disk uses **Pandoc conventions**. |
| D12 | Tables are edited as **tidy text plus a grid editor**. A table drawn inside the text stays a possible later step. |
| D13 | Report is a **profile over an existing structure, with a manifest schema bump**, so this is a paired Mac + iPhone release. |

## 3. The text on disk and the op log

### 3.1 Grammar

A new ADR (0033) supersedes ADR 0022's exclusions for these elements, and the ledger in `docs/superpowers/specs/2026-07-06-commonmark-fountain-expansion-design.md` gains the rows. Everything else in ADR 0022 stands (indented code, entities, reference links and so on stay out). Fountain is unchanged.

| Element | On disk | Op-log shape |
|---|---|---|
| Table | GFM pipe table, optional caption line `Table: Q3 revenue {#tbl:q3}` directly above or below | one paragraph (pipe tables contain no blank line) |
| Footnote reference | `[^n]` inline (`n` is any label; output numbers them in order) | inside its paragraph |
| Footnote definition | `[^n]: text`, a block of its own | one paragraph |
| Figure | `![Caption](research/path.png){#fig:label}` alone on a line | one paragraph |
| Citation | `[@key]`, `[@key, p. 12]`, `[@a; @b]` | inside its paragraph |
| Cross-reference | `@fig:label`, `@tbl:label`, `@sec:label` | inside its paragraph |
| Section label | `# Heading {#sec:label}` | the heading's paragraph |

Rules:
- **Labels are unique per project.** A duplicate is a diagnostic in the editor and a publish problem.
- **Image paths resolve inside the project's research.** A path outside the project, or a remote URL, is refused (a publish problem). Research still owns images, as before.
- **The editor writes these forms; it never invents others.** Every insert command (section 4) writes exactly the text above.

### 3.2 One shared reader

Parsing lives in MaughamCore's `MarkdownBlockParser`, which already reads pipe tables and solo images; it gains the attribute block, the caption line and footnote definitions. The inline scanner for `[^n]`, `[@…]` and `@…:…` also lives in Core. Mac and phone read through the same code (tripwire 19). The phone displays these as plain text in this milestone, but never mangles them.

### 3.3 The op log

No new `OpKind` is needed: every element is text inside ordinary paragraphs.

**Fence fix.** `ParagraphParser` is fence-unaware, so a fenced block containing a blank line splits into two paragraphs (already noted at `ProjectAST.Section.anchors`). Fix it in this milestone: a paragraph that opens a fence runs to the fence's close. The fix needs a pinned test that a fence with an internal blank line is one paragraph, and the existing bootstrap and materializer tests must stay green.

### 3.4 Research gains citation fields

`ResearchItem` gains optional fields: `citeKey`, `authors` (`[String]`), `sourceTitle` (distinct from the item's display title), `publisher`, `year`, `url` (reusing the existing `url`), `accessed` (a date) and `pages`.

- `citeKey` is suggested from the first author's surname plus the year (`gartner2026`), then deduplicated with a/b/… suffixes. It must be unique per project and is editable in the research inspector.
- A citation of a key that doesn't exist is a diagnostic in the editor and a publish problem.

### 3.5 Manifest

- `ProjectManifest` gains `profile: ProjectProfile?` (nil means the historical behaviour) and the per-project switches the profile seeds: `numberSections`, `listOfFigures`, `listOfTables` and `webAccess` (the last is read in milestone 2).
- Research items gain the fields in 3.4.
- `currentSchemaVersion` goes from 9 to 10, so an older Mac or phone **refuses** the project rather than dropping the profile on its next save. That makes this a **paired release**.

## 4. The editor

### 4.1 Commands and pickers

- **Insert Table** opens the grid editor (4.2) and writes the table where the cursor is.
- **Insert Footnote** puts `[^n]` at the cursor, with the next free label, and opens a definition paragraph directly after the current paragraph, with the cursor in it.
- **Citation picker:** typing `[@` offers research sources by title, author and key. It uses the same mechanism the wiki-link picker uses; tripwire 5 means no `NSPopover`.
- **Cross-reference picker:** typing `@` followed by a letter offers the document's figures, tables and labelled sections by caption or title.
- **Insert Figure… or drag an image into the manuscript:**
  1. Maugham copies the file into research through `DocumentStore`'s typed mover (tripwire 14) and creates the research item.
  2. It writes the figure line with a caption placeholder, selected.

Keyboard shortcuts are chosen when the plan is written, against the existing shortcut map.

### 4.2 Tables: tidy text plus a grid editor

- **In the text:**
  - the table's pipes are kept column-aligned as you type;
  - Tab and Shift-Tab move between cells;
  - Return at the end of a row adds a row.

  It is text editing, so undo and the op log behave as for any paragraph.
- **The grid editor** opens on double-click on a table, or Edit Table…. It is a sheet with:
  - add and remove rows and columns, and drag to reorder them;
  - column alignment;
  - a header row;
  - the caption and label;
  - paste from Excel, Numbers or Sheets (tab-separated text).

  Saving rewrites the table's paragraph as **one edit**, so one ⌘Z undoes it. The grid editor is the same component the milestone 3 linked tables open read-only.

### 4.3 Styling

New token kinds:
- table: pipes and delimiter row muted, header row bold;
- footnote reference: a small superscript chip;
- footnote definition: muted, with its label shown as a number;
- citation: a quiet chip, "(Gartner 2026)", with the raw text revealed while the cursor is inside it;
- cross-reference: a chip showing "Figure 3";
- figure line: muted syntax and a thumbnail line beneath it.

The tokenizer is regex-based and per blank-line block. The table pass is block-aware, and it scans per block like emphasis does. The thumbnail is drawn as a decoration, **not** a text attachment, so the shared text storage stays plain text (tripwires 1, 26).

## 5. Publishing (PDF and EPUB)

### 5.1 The AST

- `ProseNode` gains `.table(caption, label, header, alignments, rows)` and `.figure(caption, label, imageURL)`.
- `Inline` gains `.footnoteRef(n)`, `.citation(keys, locator)` and `.crossRef(label)`.
- Footnote definitions are collected per document into a footnote table the emitters read.
- `ElementCensus` grows the matching kinds, and its exhaustive `switch` makes each emitter handle each one (tripwire 12's discipline).

### 5.2 Numbering and resolution

One pass over the whole project, in binder order, before emission:

- numbers figures, tables and (when `numberSections` is on) sections, as 1, 1.2 and 1.2.3;
- resolves every cross-reference and citation;
- builds the References list from cited sources only, in author–date order.

Problems it reports:
- an unresolved label;
- a missing key;
- a duplicate label;
- an image that won't load.

Each is a **publish problem** with the paragraph it came from. Output never prints "??".

### 5.3 Emitters

| Element | PDF (LaTeX) | EPUB (XHTML) |
|---|---|---|
| Table | `longtable` with repeating header, caption above | `<table>` with `<caption>` |
| Figure | `figure` with `\includegraphics` at text width, caption below | `<figure>` with `<figcaption>` |
| Footnote | `\footnote` | EPUB 3 pop-up note (`epub:type="noteref"` / `footnote`) |
| Citation | "(Gartner 2026)" or "(Gartner 2026, p. 12)" | same text |
| Cross-reference | "Figure 3" as a hyperlink | `<a href>` |
| References | an unnumbered "References" section at the end | a final section |
| Lists of figures and tables | `\listoffigures` / `\listoftables` after the contents, when switched on | nav entries |

- **House citation style:** author–date in the text. A reference entry reads: Author(s). Year. *Title*. Publisher. URL (accessed date).
- The emission contract (`EmissionContract.swift`) gains positive examples for each element, and `EMISSION.md` is regenerated, never hand-edited.

## 6. Word export

### 6.1 Format and plumbing

- `PublishConfig.Format` gains `.docx`, with a `DOCXCompiler` beside `PDFCompiler` and `EPUBCompiler`.
- The three dispatch sites (`CompileOrchestrator`, `Republisher`, `PreviewCompiler`) and the validator get their arms.
- Audit C5 (a shared `OutputRenderer`) is in scope **only if** adding the third format makes the copy-paste worse. The plan decides, against the code.

### 6.2 The file

Maugham writes OOXML itself: XML plus zip, with no third-party dependency, like EPUB's packager. Word's own features are used throughout:

- Headings are Heading 1–3 styles, so Word's outline and table of contents work.
- Footnotes are native footnotes.
- Captions are Caption-style paragraphs with `SEQ Figure`/`SEQ Table` fields, so Word renumbers them when a reviewer adds a figure.
- Cross-references are `REF` fields to bookmarks.
- Tables are native tables with a repeating header row.
- Images are embedded.
- The References list is formatted text.

**Look:** there is a built-in default. A `reference.docx` in the project's publish folder overrides its styles (fonts, colours, headings), the same idea as the PDF style file.

### 6.3 Ready for the round trip (consumed in milestone 3)

1. **Paragraph bookmarks:** every paragraph carries a bookmark named after its `¶id`.
2. **A sent copy.** Each export writes, under `.maugham/exports/<doc>/<export-id>/`, exactly what was sent: the paragraph ids and their text, plus the .docx. A returned file is later compared against **what was sent**, not the current text, so:
   - only the reviewer's changes count;
   - when Google Docs strips the bookmarks, matching falls back to paragraph text.
3. **An export label:** "Draft 3, sent 19 Oct", stored in the file's custom properties and in the sent copy, so a returned file names the version it answers.

## 7. The Report profile

- **New Project:** Report appears beside the existing kinds and asks "Single document or sections?". It maps to the short-story or novel structure with `profile: .report`. Screenplay plus a profile is refused.
- **Defaults it seeds:**
  - the business PDF template (a new `PublishStarter` variant);
  - `numberSections`, `listOfFigures` and `listOfTables` on;
  - Word export configured;
  - `webAccess` on.

  The milestone 2 cast reads `profile` too. Audit C10 (`effectiveReviewPasses` falls back to fiction presets) is fixed in milestone 2, where the cast lands.
- **Naming:** every surface that names a project's kind asks one function, `ProjectKindName.of(manifest)`, which says "Report" for a Report. That covers project settings, the window title, the MCP tools and the prompt preamble. A census bans naming the kind from `type` alone outside that function, following tripwire 55's pattern.
- **`ProjectProfile`** is a tolerant enum (`.report`, `.unknown`). Adding a case later bumps the schema, per the manifest's schema contract.

## 8. Plan split

The milestone is too big for one plan. CLAUDE.md rule 11 applies: build plan 1, then re-derive the rest against the built code.

1. **Grammar and storage:**
   - the Core parser and inline scanner;
   - the fence fix;
   - research citation fields;
   - the manifest profile and schema 10;
   - ADR 0033.
2. **Publishing:**
   - AST nodes, numbering and resolution;
   - LaTeX and XHTML emitters;
   - References and the lists;
   - the emission contract.
3. **The editor:**
   - styling;
   - insert commands and pickers;
   - tidy tables and the grid editor;
   - figure drag-in.
4. **Word export and the Report profile:**
   - the DOCX compiler;
   - the sent copy;
   - New Project's Report;
   - `ProjectKindName` and its census;
   - the Report PDF starter.

## 9. Testing

- Core:
  - parser tests for each element, including malformed forms (an unclosed `[^`, a table without a delimiter row, `{#fig:}` with no label);
  - the fence fix;
  - citeKey suggestion and deduplication;
  - manifest round-trip at schema 10, and schema-9 files still opening.
- Publish:
  - AST builder tests for every element;
  - numbering and resolution tests, including unresolved and duplicate labels and missing keys;
  - `ElementCensus`;
  - emission-contract regeneration;
  - a real tectonic compile of a fixture report (`TectonicProbe.requireReady()`).
- DOCX:
  - the package unzips and its parts validate against what Word requires;
  - footnote, caption-field, bookmark and image parts are present;
  - golden XML for a small fixture;
  - the sent copy is written.
- Editor:
  - tokenizer tests for each new kind;
  - tidy-table alignment;
  - Tab navigation;
  - grid-editor save is one undo step.
- Census tests:
  - kind naming through `ProjectKindName`;
  - figure images only through the typed mover;
  - the existing process-launch census stays green (no new spawns).
- **Smoke (Denver):** create a Report, write the success scenario in section 1, publish to PDF, export to Word, then open it in Word and in Google Docs.

## 10. Risks

1. **The editor's text system is fragile.** The thumbnail must be a decoration, and tidy-table alignment must not fight typing (tripwires 2, 3 and 6). Gate it on `EditorIntegrationHarnessTests`.
2. **Pandoc-style text near ordinary prose.** `@` in an email address, and `[^` or `[@` typed casually. Cross-references need a known prefix (`fig:`, `tbl:`, `sec:`), and email-shaped text never matches.
3. **Word compatibility.** Validate the .docx in real Word and Google Docs during the plan. A file that opens in Pages but makes Word show "repair" is a fail.
4. **A paired release.** Schema 10 binds the Mac and the phone together. Follow the release memory: CI before the tag, and push one tag at a time.

## 11. Roadmap (later milestones, each with its own spec)

2. **The Report cast and the fact-checker.**
   - Minto, Orwell, Gould, Lippincott and the executive first reader.
   - Review passes chosen by profile (audit C10).
   - The fact-checker as the first exception to ADR 0028's confinement: web search and fetch only, no files, no execution, behind the per-project `webAccess` switch.
   - It checks claims against the cited sources, research and the web, and files findings as annotations with sources.
   - The process-launch census (`TripwireGrepTests.test_everyProcessLaunchIsNamedAndEveryClaudeLaunchIsSealed`) gains the web-enabled spawn as a named, argv-pinned exception.
3. **The round trip.**
   - Word import as a new document.
   - A returned review comes back as suggestions and comments with the reviewer's name, diffed against the sent copy.
   - Spreadsheets (.xlsx and .csv) into research, and linked tables that refresh.
4. **Later:**
   - the direct Google connection (Docs and Sheets);
   - charts from linked ranges;
   - diagrams written as text;
   - tables drawn inside the text, if real use asks for them;
   - more citation styles and Zotero/BibTeX;
   - further profiles (non-fiction book, essay, academic paper).
