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
- **Footnote (⌘⇧N)** puts the next free `[^n]` at the caret and opens its definition, `[^n]: `, below the paragraph, with the caret there ready for the note.
- **Figure… (⌘⇧I)** asks for an image or PDF; dragging an image file onto the page or pasting a picture does the same. The file is copied into the project's `figures/` folder as an image figure, and a figure line is written with "Caption" selected. A small picture of the image shows under the figure line; it is only drawn there, and never becomes part of your text. See [Publishing](publishing.md#tables-figures-footnotes-citations-and-cross-references) for the file types and labels.
- **Citation… (⌘⇧C)** writes `[@` and opens a list of your research sources; typing `[@` yourself opens it too. Type to narrow it, **Return** or **Tab** to pick, **Esc** to close. Inside a citation, `;` offers the next source. A source's key and details are set in the research inspector's Citation section (see [Research](research.md#citation-details)), where **Suggest** fills in a free key. You can still type `[@key]` or `[@key, p. 12]` by hand.
- **Cross-Reference… (⌘⇧X)** writes `@` and opens a list of the project's labelled figures, tables and sections, in book order. Typing `@fig:`, `@tbl:` or `@sec:` opens it too; a plain `@sarah` never does. Typing `@fig:name` by hand works as before.

The lists never open inside code, and they close when you move away or press Esc.

### Labels and problem marks

Next to each citation, cross-reference and footnote marker the editor shows a faint label: the formatted citation, "Figure 3", "Table 2", the footnote's number. The label is drawn beneath the marker when the line has room for it. When it does not, it appears as a small tag while the caret is in the marker or the pointer is over it. On a figure line, the `![`, `](path)` and `{#…}` are drawn faint so the caption reads as the line; they show at full strength while the caret is on that line. The line's number ("Table 2.", "Figure 3.") is drawn in the left margin, or as a small tag above the line when the margin is too narrow. Labels are only drawn; they are never part of your text, and ⌘Z and the file on disk know nothing about them.

The numbers in the editor count the whole book, in book order. An edition that leaves chapters out may number differently in its PDF.

A dotted underline marks a marker with a problem: a citation key no source has, a cross-reference to nothing, a label defined twice, or a footnote that is missing, defined twice or never used. On a figure line it marks the path when it points outside the project, names a figure that isn't there or names two figures at once, or when a table figure is labelled `fig:` or an image `tbl:`. Red means a Report would refuse to publish with this problem; amber means it would publish anyway. Hover over the underline to read the sentence. The marks update when you pause typing, not on every keystroke, and appear only in a manuscript, not in a screenplay.

Smart typography leaves table rows, labels and cross-references exactly as typed.

### Goals and word count

The bottom-right of the editor shows a goal capsule: today's word count, document word count, reading time. If you set a word target on a document in the Inspector, the capsule shows progress.

⌘S triggers a "Saved" flash. Autosave already runs every 750ms, so nothing is ever waiting to be saved; ⌘S makes a [checkpoint](backups-and-history.md#checkpoints) and runs your backups.
