# The Editor & Focus

Maugham's editor is a centered ~70-character column with gutters on either side. The column width comes from the typography setting; the gutters are theme-colored.

### Themes and typography

Open **Settings** (⌘,):

- **Theme** — Light, Dark, Sepia, or Follow System. Sepia is paper-yellow; useful in low light.
- **Typography** — font family (curated for prose: Iowan Old Style, New York, Charter, etc.), size, line height, paragraph spacing. Changes apply live.
- **Per-project typography** — `⌘⇧,` opens Project Settings. Override typography just for this project (e.g., a screenplay should use Courier; a novel might use a serif at 17pt). Settings persist across launches.

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

- **Table (⌘⇧T)** writes a three-column pipe table on a paragraph of its own — a header row, one empty row and a `Table:` caption line with a `{#tbl:…}` label — with the first header cell selected to type over. **Tab** and **Shift-Tab** move between cells, selecting each cell's text, and wrap from one row to the next. **Return** at the end of a body row adds a new row; **Return** on the header row moves to the first cell of the row below it (adding one if the table has none), so it never splits the table; **Return** on an empty last row leaves the table for a new paragraph below it. The table lines its pipes up when you press Tab, Shift-Tab or Return, and when you move out of the table — never while you are typing in a cell, and ⌘Z puts it back as you typed it.
- **Edit Table… (⌘⌥⇧T)** opens the table the caret is in as a grid; double-clicking the dashed line under a table's header does the same (a double-click inside a cell still selects a word). Add, remove and move rows and columns, choose each column's alignment, edit the header, and set the caption and the label — a label is letters, digits, `-` and `_`, and no other table, figure or section in the project may have it. **Paste Cells** fills the grid from the cell you last clicked with cells copied from Excel, Numbers or Google Sheets, adding rows and columns as needed. Return in a cell moves to the cell below (in the last row it does nothing); Return in the caption or label field saves. **Save** writes the table back, lined up, as one ⌘Z step; if the table was changed some other way while the grid was open, nothing is written and a notice says so. Outside a table the command does nothing, and where the text isn't editable the grid opens to read, with Save greyed out.
- **Footnote (⌘⇧N)** puts the next free `[^n]` at the caret and opens its definition, `[^n]: `, below the paragraph, with the caret there ready for the note.
- **Figure… (⌘⇧I)** asks for an image or PDF; dragging an image file onto the page or pasting a picture does the same. The file is copied into research and a figure line is written with "Caption" selected. A small picture of the image shows under the figure line; it is only drawn there, and never becomes part of your text. See [Publishing](publishing.md#tables-figures-footnotes-citations-and-cross-references) for the file types and labels.
- **Citations and cross-references** are typed by hand for now. Write `[@key]` (or `[@key, p. 12]`) to cite a research source, and `@fig:name`, `@tbl:name` or `@sec:name` to point at a label. Table rows, footnote markers, figure lines, citations and cross-references are styled as you type. A source's key and details are set in the research inspector's Citation section (see [Research](research.md#citation-details)), where **Suggest** fills in a free key.

Smart typography leaves table rows, labels and cross-references exactly as typed.

### Goals and word count

The bottom-right of the editor shows a goal capsule: today's word count, document word count, reading time. If you set a word target on a document in the Inspector, the capsule shows progress.

⌘S triggers a "Saved" flash. Autosave already runs every 750ms, so nothing is ever waiting to be saved; ⌘S makes a [checkpoint](backups-and-history.md#checkpoints) and runs your backups.
