# Inspector, Research & Outline

The right column's modes are Inspector, Research, and Outline (covered on this page), plus Tasks, Annotations, History, Inbox, Palette, Translation, Intent, Visual Language, Diagnostics, and References (each covered elsewhere, or at the bottom of this page). Switch with the lettered shortcuts below or the small picker at the top of the pane.

### Panes are grouped by persona

Each of the four personas (⌘1 Plan, ⌘2 Author, ⌘3 Review, ⌘4 Publish — see [Getting Started → Personas](getting-started.md#personas)) offers its own subset of these modes in the picker. A shortcut still opens its pane from any persona — it reveals the right column if it's hidden and switches to it — even one the current persona doesn't lead with:

- **Plan** — Inbox, Tasks, History, Inspector.
- **Author** — Diagnostics, Research, Palette, Intent, References, Tasks, History, Inspector.
- **Review** — Annotations, Intent, References, Tasks, History, Inspector.
- **Publish** — Visual Language, Tasks, Translation, History, Inspector.

**There is one order, and modes appear and disappear within it.** Reading down the whole set: Diagnostics, Annotations, Inbox, Research, Palette, Intent, References, Visual Language, Tasks, Translation, History, Inspector. Every persona above is that same sequence with the modes it doesn't offer taken out — so a mode never moves left or right of a mode it sits beside somewhere else, and you aren't hunting for it in a new place each time you change persona. Tasks marks the break between what you're working *with* and what's flowing *through*; History and Inspector always close the row, with Inspector on the far end.

Each persona's default — the mode it opens on — is just the first one it offers: Inbox in Plan, Diagnostics in Author, Annotations in Review, Visual Language in Publish.

**What a persona leads you to is not what it can reach.** The right column shows what you *consult* while making something else, so a persona doesn't lead you to a mode for the thing it's there to make: you write research notes and palette cards in the binder tree — the same tree in every persona — and Author reads them back in its right column instead. Intent and Visual Language have no tree home at all — **they're right-hand panes everywhere, reached with ⌘⌥N and ⌘⌥V** rather than from any picker. They open, they work, and they stay selected while you use them; switch persona and come back and Plan is on its own modes again.

**Outline is in no persona's picker at all.** Same story — ⌘⌥O opens it from any persona — it just isn't one of the modes a persona leads you to. The binder is where structure lives.

Switching persona while sitting on a pane the destination doesn't offer falls back to that persona's default rather than blanking the pane. A pane no persona offers is the one thing that isn't remembered across a persona switch: summon Outline with ⌘⌥O, switch persona and come back, and you're on that persona's own mode again.

### Inspector mode (⌘⌥I)

Last in every persona's picker, so it's always in the same place. Shows metadata for whatever's selected in the binder.

**On the planning canvas** — Plan's centre column, always — it shows whatever is selected on the canvas, in one of three forms:

- **A region** — its name, whether it's collapsed, the **Piece** it's associated with, which cards live in it and which only appear in it (with **Cite a Card** to add an appearance), **Promote…**, and a Delete Region button.
- **A line** — its name, which is drawn on the line itself; clear the field and the name comes off. **Promote…**, and a Delete Line button. Both cards stay.
- **A card** — its first line, its own **Piece** picker with a line reading where its promotions will go, what it has been promoted into (with an **Open** button that takes you to the note, or a note that what it produced is no longer in the project), **what its words are part of** if a region's promotion folded them into something — *Its words are in “Act II fog”*, with its own **Open**, and a line saying that promoting this card makes something new rather than rewriting that — and **Promote…**. A card can say both at once: what it became, and what it is part of. **If Claude put the card there it says so** — *From Claude.*, and *Read from “…”* when it names the page it was read off — up with the card's own facts rather than down among the promotions, because being Claude's is not something that happened *to* the card and must not read as a mark saying it has already been promoted. Your own cards say nothing there. There's no Delete button here: ⌫ on the canvas is how a card goes.

Select nothing and it says so.

**So in Plan the Inspector is the canvas's** — the Inspector describes the middle column, and in Plan the middle column is always the canvas. Clicking a chapter in Plan's tree doesn't put that chapter's metadata here; it's the panes that are *about* a chapter that follow it — **Intent** (⌘⌥N) above all. Switch to Author (⌘2) for a chapter's own metadata.

Both Piece pickers offer only pieces that can actually hold research, so nothing on either list can fail when you promote. A card left on **None** follows the region it lives in, and the line under its picker says so — *Chapter Three (from its region)* — rather than leaving you to work out where the note went. See [Getting Started → The planning canvas](getting-started.md#the-planning-canvas) and [→ Promoting](getting-started.md#promoting).

### Research mode (⌘⌥R)

Shows research for the current manuscript document in up to two sections:

- **Piece Research** (in a Collection) / **Project Research** (in a single-document project) — research that already belongs to this piece or project. It appears automatically; there's no linking step. Promote a piece to its own project and this carried research comes with it.
- **Linked** — research explicitly linked to this document from elsewhere in the project.

Click an item in either section → the pane swaps to a read-only Markdown preview, side-by-side with your editor. Back chevron returns to the list.

This mode is **Author's** (⌘⌥R) — it's for reading what the open chapter points at while you draft. Writing the notes themselves is the tree's own job, in every persona ([Research](research.md)).

The **+** button offers **Link Research…**, a picker sheet offering everything not already shown above, plus **New Note…**, **Add File…**, **Add Link…** to create research scoped to the open document. Dragging an item from the binder tree's Research section onto this pane links it the same way — summon this pane with **⌘⌥R** in any persona to have both the tree and this preview on screen at once.

Unlink: × on a row in **Linked**. Items in the automatic section have no × — untangle those by editing the piece/project structure itself, not the link.

### Outline mode (⌘⌥O)

Either a **table** view (Title / Status / Synopsis / Words) or a **cards** view (corkboard with synopses). Toggle between the two with the small picker in the pane header. Click a row or card → editor jumps to that document.

Layout choice persists per project.

⌘⌥0 toggles the whole right pane visibility.

The right pane also has a **Tasks** mode (⌘⌥T) — see [Tasks & To-Dos](tasks.md) — and an **Annotations** mode (⌘⌥A) — see [Annotations & Suggestions](annotations-and-suggestions.md).

It also has a **History** mode (⌘⌥H) — a read-only timeline of edits, annotations, and checkpoints, with a scrubber for time-travel — an **Inbox** mode (⌘⌥B) — triage text/audio/photo captures from MaughamPhone, see [The Sense Pass](sense-pass.md) — a **Palette** mode (⌘⌥P) — a card for the sensory palette wall, also covered there — and a **Translation** mode (⌘⌥L) — the selected paragraph's source text and any open translator queries, active while reviewing a translation, see [Translating Your Manuscript](translation-review.md).

### Intent mode (⌘⌥N)

What you're going for — freeform prose, never a form. The pane shows the intent of whatever the binder names: select a chapter and you get the chapter's, select the project row at the top of the binder and you get the book's. Every project type has that row — in a Collection it heads the Pieces list, in a screenplay the Scenes list. The tree is the only place that choice is made, and a line at the top of the pane says which one you're reading — *What “Chapter Three” is going for*, or *What this project is going for*. Selecting a group, or nothing, shows the project's.

Intent is a real document, not a note: every edit lands in its own operation log, so ⌘Z works here as it does in the manuscript, and it merges across your Macs the same way. `[[Chapter 9]]` links resolve here too.

**Having no intent recorded is a valid state.** An undeclared scope is simply an empty editor — start typing and the file is created for you. Nothing nags, and nothing is written until you write it.

**Rulings** are decisions, itemized apart from the prose above them. A rule is
just intent about something specific — "Kelly only ever acts on what she's
actually heard" — and once it firms up it belongs on its own line rather than
buried in a paragraph. **Rulings are made by pressing something, not by typing
a heading.** Answering a check's note (see
[Checking Your Writing](compiler.md)) files your sentence as a ruling on that
piece, dated and marked with where it came from; so do **Bless** and
**Correct**, the two buttons on an entry in the paler strip below — the things
Claude has read off the manuscript, which are its readings until you say
otherwise. Each ruling appears in its own strip beneath the editor with
**Edit** and **Revoke** on it. Revoke
takes a line out (one ⌘Z brings it back exactly as it was — same words, same
day, same note about where it came from); Edit changes the words in place and
leaves the day and provenance untouched, because a correction isn't a new
decision.

The editor above the strip is for your prose, and typing a `## Rulings` heading
into it doesn't make the section — a heading with nothing under it is just a
heading, and it stays in your text like any other line. Let the buttons write
the section; if you've already typed a heading of your own, the next ruling
adopts it rather than adding a second one. **The `.md` file's own shape is
forgiving** — Maugham reads whatever list it finds under that heading and
doesn't require the exact form it writes itself, so a bare line with no date
works as well as one it dated for you. That
tolerance is for files arriving from your other Mac or from an older draft, not
an invitation to edit the file in Finder: like every document in Maugham, an
intent is kept in its own operation log and the `.md` is written out from it, so
an outside edit made while Maugham has the project open is discarded on the next
save.

### Visual Language mode (⌘⌥V)

How the book looks — typography, cover direction, the references you're steering by. Project-scope: one book, one look. Like Intent it's an ordinary document, with the same undo and the same cross-Mac merge, and it's likewise empty until you write in it.

**It takes pictures as well as words.** Drop image files onto the strip at the bottom of the pane, or paste one straight into the editor with ⌘V. Either way the picture is copied into a `visual-language_assets/` folder beside the document — your original stays where it is — and a Markdown image reference is added to the text, which you can move, caption or delete like any other line. Anything that isn't a picture is turned away and says so. Intent doesn't take pictures; it's prose about the writing.

**Claude reads this pane when it writes your book's design.** Ask it to author or revise a PDF/EPUB template and it reads what you've written here first, including a list of the images you've referenced — so the typography comes from your description rather than its own taste, and the sixth piece still matches the first five. Write it in your own words; there's no format to hit.

### Diagnostics mode (⌘⌥D)

The compiler's report on the open document — Author's own pane, and its default. Press ⌘R ("Check Writing") to ask Claude to check what you've written since the last check; the header line says what happened last, and while a check is running you can press **Cancel**.

It reads as a report, three sections in order: **Conformance** — every clause you've declared, quoted back in your own words, each *holds*, *strains*, or untouched by this draft, with an **Open Intent** button in the section header; **Continuity** — questions raised against established facts and rules, each ending as a question rather than a verdict; **The reader** — dream-breaks and belief statements from the reading itself, capped at the sharpest three. No note ever shows a paragraph id — each carries the words that paragraph said, as a chip you click to jump there.

**Notes that arrive while you're looking elsewhere put a count on the picker**, the way new captures do on the Inbox — a check finished somewhere you weren't watching, and the count clears the moment you open the pane.

**A note goes stale the moment its paragraph changes.** Edit the text a note is about and the note quietly drops out — nothing to dismiss, nothing left pointing at words that no longer exist.

The gear menu picks the model a check runs against — **Fast**, **Standard**, or **Deep** — and the choice is remembered per project.

**A clean check says so plainly.** A conformance section where every clause holds still renders — that's the good outcome, not an empty pane — and a check with nothing at all to raise reads *"Nothing to flag."*, not silence and not a green checkmark standing in for an answer.

**Answering a conformance strain or a continuity question becomes a ruling on that piece's intent** — the reader's report offers no Answer, since a belief or a dream-break isn't a question to rule on. Press **Answer**, say why the thing it flagged is deliberate, and press Return: your sentence lands as a dated line under [that piece's Rulings](#intent-mode-n), and the note goes away, so the next check reads what you just told it rather than raising the same thing again. **Promote to Task** keeps a note instead — as a real task on the document, naming which section raised it, which syncs and survives where the notes don't. Full walkthrough: [Checking Your Writing](compiler.md).

### References mode (⌘⌥E)

**What this piece is pinned to**, as a shelf of thumbnails and titles — Author's and Review's. It's not a browser: there's no search and no tree, because the list is short by design. Two things put something on it, and they're the two ways a piece acquires context in Maugham:

- **Research you linked to this document** — the Research pane's own **Link** action (⌘⌥R).
- **Cards you clustered for it on the planning canvas** — anything sitting inside a region bound to this piece, plus any single card you bound to the piece directly.

Research notes, PDFs, recordings, links, palette cards, photographs and loose canvas scraps all appear; a photograph shows a thumbnail, everything else shows the same kind glyph the canvas draws it with. If you delete something, it simply leaves the shelf — you'll never see a row that's only an id.

**In Author, click a pin and it opens as a column beside your prose.** One at a time: clicking another swaps it, clicking the same one again sends it back, and Escape closes it. Drag the divider to set the width — it's remembered per project. The column squeezes your writing column while it's open and gives the width straight back when it isn't, and it goes away with everything else under ⌘\.

**The column itself is Author's only.** In Review the shelf is still there — you can see what a piece is pinned to while you adjudicate it — but a row isn't a button there: a caption at the bottom reads *"Studying a pin opens in Author (⌘2)."* Study something in Author, switch to Review and back, and it's still up — Author remembers what you were looking at, so ⌘2 brings the column straight back.

**This is the same set Claude is briefed on.** When you press ⌘R the compiler is told what this piece is pinned to, by name — so what you see on the shelf is what it can go and read.
