# The Editor & Focus

Maugham's editor is a centered ~70-character column with gutters on either side. The column width comes from the typography setting; the gutters are theme-colored.

### Themes and typography

Open **Settings** (⌘,):

- **Theme** — Light, Dark, Sepia, or Follow System. Sepia is paper-yellow; useful in low light.
- **Typography** — font family (curated for prose: Iowan Old Style, New York, Charter, etc.), size, line height, paragraph spacing. Changes apply live.
- **Per-project typography** — `⌘⇧,` opens Project Settings. Override typography just for this project (e.g., a screenplay should use Courier; a novel might use a serif at 17pt). Settings persist across launches.
- **Report settings** — in Project Settings, a **Report** section shows the project's kind and, for every project but a screenplay, a Report toggle. It switches on the numbering of sections and the lists of figures and tables, each with a Default button once you've changed it. Turning it on or off doesn't change the publish template, which was chosen when the project was made; to get the Report layout on an existing project, ask Claude to re-initialise the publish template, which replaces the template files (including your changes to them).

### Focus features

Maugham is built for focused writing sessions. The chrome gets out of your way.

- **⌘\\ — Toggle focus mode.** Hides the title bar and toolbar; just text and gutters. On the planning canvas it also collapses both side columns, giving the canvas the whole window. Press it again and the binder comes back and the right-hand pane returns to the visibility you had before you collapsed. It never moves a column anywhere else.
- **⌘⇧F — Toggle full-screen focus.** Enters full-screen with no chrome — which includes the canvas collapse above, since full-screen focus turns focus mode on.
- **⌘⌥⇧R — Toggle Review Mode.** Not a focus feature but the other posture the editor has: the manuscript goes read-only and you annotate it instead of fixing it, with a REVIEWING pill at the top of the column that stays put even in focus mode. See [Review Mode](annotations-and-suggestions.md#review-mode--reading-your-own-draft-cold).
- **Typewriter scrolling** (Settings → Editor → Focus) — keeps the active line at the vertical center of the viewport as you type.
- **Sentence focus** — only the current sentence is full color; the rest dims. Forces you forward.
- **Paragraph focus** — same idea, paragraph granularity.

These are sticky preferences; once you find your set, they stay.

### Smart typography

As you type, Maugham quietly fixes things:

- `--` becomes an em-dash `—`
- `...` becomes an ellipsis `…`
- Straight quotes `"like this"` become smart quotes `"like this"`

The underlying file still contains the smart characters; nothing is lost on save.

### Writing tables, footnotes, figures and citations

The **Insert** menu puts report elements into the page you're writing. It works in a prose manuscript and is greyed out in a screenplay, in review mode, in translation review, and anywhere the text isn't editable. With a statement, a research note or an inspector field holding the cursor, the menu does nothing: click into the manuscript first. Each insert is one ⌘Z step. How these print is in [Publishing](publishing.md#tables-figures-footnotes-citations-and-cross-references).

- **Table (⌘⇧T)** makes a 3×3 table figure — a header row, saved in the project's `figures/` folder — and writes its figure line at the caret with "Caption" selected, labelled `{#tbl:…}`. One ⌘Z takes back the line and the figure together (the figure goes to the Trash). A small card under the line shows the cells.
- **Convert to Table Figure (⌘⌥⇧T)** turns the pipe table under the caret into a table figure, keeping its caption and `{#tbl:…}` label so every `@tbl:` reference keeps its number; a cell starting `=` becomes a formula. It is also in the Insert menu and on the right-click menu inside a pipe table. One ⌘Z takes it back. A pipe table you type or paste stays ordinary text, and if two devices edit it at once the later edit replaces the whole table; a table figure merges cell by cell. **Tab** and **Shift-Tab** move between a pipe table's cells, selecting each cell's text, and wrap from one row to the next. **Return** at the end of a body row adds a new row; **Return** on the header row moves to the first cell of the row below it (adding one if the table has none), so it never splits the table; **Return** on an empty last row leaves the table for a new paragraph below it. The table lines its pipes up when you press Tab, Shift-Tab or Return, and when you move out of the table — never while you are typing in a cell, and ⌘Z puts it back as you typed it.
#### Editing a table in place

A table figure's card opens into a grid right under its figure line, so you can change the cells without leaving the page.

- **Open it** by double-clicking the card, by pressing **Return** inside the figure line (at the very start or end of the line, Return still starts a new line), or just after **Insert ▸ Table** while you haven't moved on. A table that arrives some other way, such as a redo, stays a card until you open it.
- **Move and select.** Arrow keys move the selected cell; **Shift-arrows** stretch a range; **Tab** and **Shift-Tab** move across and wrap to the next row (they stop at the last and first cell). **⌘-arrows** jump to the table's edge (with Shift, they stretch the range there), and **Home** and **End** go to the row's first and last cell. Click a column letter or a row number to select the whole column or row. **⌘A** selects every cell. Drag a column's edge to resize it.
- **Enter a value.** Type to replace the cell's contents; **Return** or **F2** or a double-click edits what's there. When you began by typing, the arrow keys commit and move; when you began with F2, Return or a double-click, they move the caret inside the cell. **Return** commits and moves down, **Shift-Return** up, **Esc** discards the edit. **Delete** or **fn-Delete** clears the selected cells. Accented letters and input methods work as they do in any field.
- **Write a formula.** Start with `=`. While you're building it, arrow keys or clicks add a cell reference, and Shift-arrows or dragging add a range. A formula that doesn't read stays open with the reason beside it.
- **The formula bar** above the grid shows the selected cell's address and what's in it (its formula, if it has one); you can edit there as well as in the cell.
- **The toolbar** has number format, fewer and more decimal places, alignment, Header row and Total row, and **Σ**, which sums the column above the selection.
- **The bottom bar** shows the table's number ("Table 2"), and holds its caption and its name. Done closes the grid, keeping a caption or name you were still typing.
- **Format ▸ Table** and the grid's **right-click menu** carry the same commands: number format, decimals, alignment, header and total row, Σ, insert, delete and move rows and columns, and sort ascending or descending by the selected cell's column. **⌘⌥↑ ↓ ← →** insert a row above or below and a column left or right. Rows move and delete only inside the body; the header and total rows stay put, and the last row or column can't be deleted. While a grid has the keys, the Insert menu is greyed out.
- **Copy, cut and paste.** ⌘C, ⌘X and ⌘V work on the selected cells. To other apps (Numbers, Excel, a mail) they carry the values as text and as a table; within Maugham they carry formulas too: a copy translates the references as Excel does, and a cut pasted into the same table keeps them as they were. Formulas copied from another table paste as their values. A paste larger than the table adds rows before the total row.
- **Fill.** **⌘D** (Fill Down) copies the selection's top row down it, and **⌘R** (Fill Right) copies its left column across it, with formulas adjusted as Excel's are; one cell fills from the cell above or to its left. In the grid ⌘R is Fill Right; in the text it is still Check Writing.
- **Import from CSV…** (Format ▸ Table) replaces the table's cells with a CSV file's, keeping the same rows and columns where the header and values match. A file has no total row, so a table's total row is switched off, and a notice says so; the file's last row stays data. It is one step to undo. A file the table already matches changes nothing, and a notice says so.
- **Undo.** While the grid is open, ⌘Z and ⇧⌘Z undo and redo its cell, row, column and sort changes, one step per change (deleting several rows or columns is one step). The caption is the page's text, so its change is a step on the page's undo, and a rename is not undone with ⌘Z. When you close the grid, everything you did in its cells becomes one step, "Edit Table", on the page's undo: one ⌘Z takes the whole visit back. If a cell you touched has changed since — in the table's own window, by another undo, or on another device — that undo is declined with a sentence: "Couldn't undo the table edit — it has changed since."
- **One grid at a time.** A table is open in one grid at once. While it is open in another project window on the same project, its card there reads "Editing in another window", and a double-click or Return on it brings that window's grid forward.
- **In its own window.** The **⤢** button on the grid opens the table in a window of its own, so you can keep it beside the page. The card then reads "Editing in window" and a double-click or Return on it brings the window forward. If the grid was read-only because of review mode, the window is too, and it follows review mode in the window you opened it from. The window has its own undo for as long as it is open, and closing it adds nothing to the page's undo. **Done** or **⌘W** closes it; so does closing the project's last window, which first waits a moment for the window's last edit to be saved. An edit still open in a table when you quit Maugham may not be saved: press Return or close the table first. A figure window is never restored on relaunch.
- **Send to Research.** Format ▸ Table ▸ **Send to Research** (and the right-click menu) moves the table into This Piece's Research or Shared Research: the grid closes first, keeping a cell you were still typing, then the table's figure line is taken off the page and the table is kept in Research. It can't be undone with ⌘Z.
- **Close it** with **Done**, by pressing **Esc** with nothing being edited, or by clicking in the text. Clicking in the text, or anything that takes the keys back to the text, commits an open cell edit. If a formula can't be read when you navigate away (a search match, a task jump), the grid closes and a notice keeps what you had typed. So does a change elsewhere that removes the row or column you were editing.
- **Read-only.** In review mode, in a read-only share, in a project Maugham won't let this Mac change, or when the table is parked, the grid opens so you can select and scroll, but the toolbar and formula bar are greyed and typing is answered with the reason. Translation review never opens it. The caption follows the text: you can change a table's cells on a Mac that may not change the page's text, and the caption is then locked.
- **From the binder.** Selecting a table in the binder's **Figures** section puts the same grid in the centre column (see [Figures in the binder](structure-and-binder.md#figures-in-the-binder)), with no Done: it stays until you select something else. A table is open in one grid at a time, whether in place, in its own window or in the centre. If another grid holds it, the centre says "Editing in another window", and a click brings that grid forward; it opens here once the other lets go. **Open in Window** from the binder hands the table to its own window.
- **The figure inspector.** A selected figure's inspector shows its name (change it there) and its number and section; **Used in**, the lines that use it, each a link that takes you to the line; **Reads from Research**, the Research tables it takes values from, with the date each was pinned; **Notes and suggestions** on the figure, with **Show in Notes**; and the actions **Open in Window**, **Send to Research** and **Import from CSV…**. Import is greyed, with its reason, until the table's grid is open.
- **Compare and Refresh.** When a table reads pinned values from Research, **Compare…** lists each pinned cell with what it holds now and what Research holds. **Refresh** brings the cells up to Research as one step on that grid's undo. It needs the grid open, and says so when it isn't.
- **Footnote (⌘⇧N)** puts the next free `[^n]` at the caret and opens its definition, `[^n]: `, below the paragraph, with the caret there ready for the note.
- **Figure… (⌘⇧I)** asks for an image or PDF; dragging an image file onto the page or pasting a picture does the same. The file is copied into the project's `figures/` folder as an image figure, and a figure line is written with "Caption" selected. A small picture of the image shows under the figure line; it is only drawn there, and never becomes part of your text. A figure line always keeps its own paragraph: type just above or below one, or at the start of its line, and Maugham puts a blank line between your text and the figure, and Backspace never joins the figure to the paragraph above. See [Publishing](publishing.md#tables-figures-footnotes-citations-and-cross-references) for the file types and labels.
- **Existing Figure…** places a figure the book already has — one made from Research, one left unused, or one already used elsewhere — at the caret. It lists every figure, unused ones first, then the rest in book order with their number, caption and chapter; type to narrow the list, then **Return** or double-click to insert. The figure line is written with its caption selected, and one ⌘Z takes it back.
- **Citation… (⌘⇧C)** writes `[@` and opens a list of your research sources; typing `[@` yourself opens it too. Type to narrow it, **Return** or **Tab** to pick, **Esc** to close. Inside a citation, `;` offers the next source. A source's key and details are set in the research inspector's Citation section (see [Research](research.md#citation-details)), where **Suggest** fills in a free key. You can still type `[@key]` or `[@key, p. 12]` by hand.
- **Cross-Reference… (⌘⇧X)** writes `@` and opens a list of the project's labelled figures, tables and sections, in book order. Typing `@fig:`, `@tbl:` or `@sec:` opens it too; a plain `@sarah` never does. Typing `@fig:name` by hand works as before.

The lists never open inside code, and they close when you move away or press Esc.

### Labels and problem marks

Next to each citation, cross-reference and footnote marker the editor shows a faint label: the formatted citation, "Figure 3", "Table 2", the footnote's number. The label is drawn beneath the marker when the line has room for it. When it does not, it appears as a small tag while the caret is in the marker or the pointer is over it. On a figure line, the `![`, `](path)` and `{#…}` are drawn faint so the caption reads as the line; they show at full strength while the caret is on that line. The line's number ("Table 2.", "Figure 3.") is drawn in the left margin, or as a small tag above the line when the margin is too narrow. Labels are only drawn; they are never part of your text, and ⌘Z and the file on disk know nothing about them.

The numbers in the editor count the whole book, in book order. An edition that leaves chapters out may number differently in its PDF.

A dotted underline marks a marker with a problem: a citation key no source has, a cross-reference to nothing, a label defined twice, or a footnote that is missing, defined twice or never used. On a figure line it marks the path when it points outside the project's figures folder and research folders, names a figure that isn't there or names two figures at once, or when a table figure is labelled `fig:` or an image `tbl:`. A figure line that shares a paragraph with text (from another device or an older file) is marked too: add a blank line above and below it. Red means a Report would refuse to publish with this problem; amber means it would publish anyway. Hover over the underline to read the sentence. The marks update when you pause typing, not on every keystroke, and appear only in a manuscript, not in a screenplay.

Smart typography leaves table rows, labels and cross-references exactly as typed.

### Goals and word count

The bottom-right of the editor shows a goal capsule: today's word count, document word count, reading time. If you set a word target on a document in the Inspector, the capsule shows progress.

⌘S triggers a "Saved" flash. Autosave already runs every 750ms, so nothing is ever waiting to be saved; ⌘S makes a [checkpoint](backups-and-history.md#checkpoints) and runs your backups.
