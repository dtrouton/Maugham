# Inspector, Research & Outline

The right column's modes are Inspector, Research, and Outline (covered on this page), plus Tasks, Annotations, History, Inbox, Palette, Translation, Intent, and Visual Language (each covered elsewhere, or at the bottom of this page). Switch with the lettered shortcuts below or the small picker at the top of the pane.

### Panes are grouped by persona

Each of the four personas (⌘1 Plan, ⌘2 Author, ⌘3 Review, ⌘4 Publish — see [Getting Started → Personas](getting-started.md#personas)) offers its own subset of these modes in the picker, in an order suited to that persona's work. A shortcut still opens its pane from any persona — it reveals the right column if it's hidden and switches to it — even one the current persona doesn't lead with:

- **Plan** — Research, Palette, Inbox, Intent, Visual Language, Tasks, Inspector.
- **Author** — Inspector, Research, Tasks, Palette, Intent, History.
- **Review** — Annotations, History, Intent, Translation, Inspector, Tasks, Palette, Visual Language.
- **Publish** — Visual Language, Inspector.

**Outline is in no persona's picker.** It's still there — ⌘⌥O opens it from any persona, and it stays selected while you use it — it just isn't one of the modes a persona leads you to. The binder is where structure lives.

Switching persona while sitting on a pane the destination doesn't offer falls back to that persona's default rather than blanking the pane. A pane no persona offers is the one thing that isn't remembered across a persona switch: summon Outline with ⌘⌥O, switch persona and come back, and you're on that persona's own mode again.

### Inspector mode (⌘⌥I)

Default in Author. Shows metadata for whatever's selected in the binder.

**On the planning canvas** (Plan → Canvas) it shows whatever is selected there, in one of three forms:

- **A region** — its name, whether it's collapsed, the **Piece** it's associated with, which cards live in it and which only appear in it (with **Cite a Card** to add an appearance), **Promote…**, and a Delete Region button.
- **A line** — its name, which is drawn on the line itself; clear the field and the name comes off. **Promote…**, and a Delete Line button. Both cards stay.
- **A card** — its first line, its own **Piece** picker with a line reading where its promotions will go, what it has been promoted into (with an **Open** button that takes you to the note, or a note that what it produced is no longer in the project), **what its words are part of** if a region's promotion folded them into something — *Its words are in “Act II fog”*, with its own **Open**, and a line saying that promoting this card makes something new rather than rewriting that — and **Promote…**. A card can say both at once: what it became, and what it is part of. **If Claude put the card there it says so** — *From Claude.*, and *Read from “…”* when it names the page it was read off — up with the card's own facts rather than down among the promotions, because being Claude's is not something that happened *to* the card and must not read as a mark saying it has already been promoted. Your own cards say nothing there. There's no Delete button here: ⌫ on the canvas is how a card goes.

Select nothing and it says so.

Both Piece pickers offer only pieces that can actually hold research, so nothing on either list can fail when you promote. A card left on **None** follows the region it lives in, and the line under its picker says so — *Chapter Three (from its region)* — rather than leaving you to work out where the note went. See [Getting Started → The planning canvas](getting-started.md#the-planning-canvas) and [→ Promoting](getting-started.md#promoting).

### Research mode (⌘⌥R)

Shows research for the current manuscript document in up to two sections:

- **Piece Research** (in a Collection) / **Project Research** (in a single-document project) — research that already belongs to this piece or project. It appears automatically; there's no linking step. Promote a piece to its own project and this carried research comes with it.
- **Linked** — research explicitly linked to this document from elsewhere in the project.

Click an item in either section → the pane swaps to a read-only Markdown preview, side-by-side with your editor. Back chevron returns to the list.

The **+** button offers **Link Research…**, a picker sheet offering everything not already shown above, plus **New Note…**, **Add File…**, **Add Link…** to create research scoped to the open document. Dragging an item from the binder's Research segment onto this pane links it the same way.

Unlink: × on a row in **Linked**. Items in the automatic section have no × — untangle those by editing the piece/project structure itself, not the link.

### Outline mode (⌘⌥O)

Either a **table** view (Title / Status / Synopsis / Words) or a **cards** view (corkboard with synopses). Toggle between the two with the small picker in the pane header. Click a row or card → editor jumps to that document.

Layout choice persists per project.

⌘⌥0 toggles the whole right pane visibility.

The right pane also has a **Tasks** mode (⌘⌥T) — see [Tasks & To-Dos](tasks.md) — and an **Annotations** mode (⌘⌥A) — see [Annotations & Suggestions](annotations-and-suggestions.md).

It also has a **History** mode (⌘⌥H) — a read-only timeline of edits, annotations, and checkpoints, with a scrubber for time-travel — an **Inbox** mode (⌘⌥B) — triage text/audio/photo captures from MaughamPhone, see [The Sense Pass](sense-pass.md) — a **Palette** mode (⌘⌥P) — a card for the sensory palette wall, also covered there — and a **Translation** mode (⌘⌥L) — the selected paragraph's source text and any open translator queries, active while reviewing a translation, see [Translating Your Manuscript](translation-review.md).

### Intent mode (⌘⌥N)

What you're going for — freeform prose, never a form. The pane shows the selected document's intent, or the project's when nothing is selected; when a document is selected, a small switch at the top of the pane puts the book's intent one click away.

Intent is a real document, not a note: every edit lands in its own operation log, so ⌘Z works here as it does in the manuscript, and it merges across your Macs the same way. `[[Chapter 9]]` links resolve here too.

**Having no intent recorded is a valid state.** An undeclared scope is simply an empty editor — start typing and the file is created for you. Nothing nags, and nothing is written until you write it.

### Visual Language mode (⌘⌥V)

How the book looks — typography, cover direction, the references you're steering by. Project-scope: one book, one look. Like Intent it's an ordinary document, with the same undo and the same cross-Mac merge, and it's likewise empty until you write in it.

**It takes pictures as well as words.** Drop image files onto the strip at the bottom of the pane, or paste one straight into the editor with ⌘V. Either way the picture is copied into a `visual-language_assets/` folder beside the document — your original stays where it is — and a Markdown image reference is added to the text, which you can move, caption or delete like any other line. Anything that isn't a picture is turned away and says so. Intent doesn't take pictures; it's prose about the writing.

**Claude reads this pane when it writes your book's design.** Ask it to author or revise a PDF/EPUB template and it reads what you've written here first, including a list of the images you've referenced — so the typography comes from your description rather than its own taste, and the sixth piece still matches the first five. Write it in your own words; there's no format to hit.
