# The Right Column

The right column's modes are Inspector (covered on this page), plus Tasks, Annotations, History, Inbox, Translation, Intent, Visual Language, Diagnostics, References, and Department (each covered elsewhere, or at the bottom of this page). Switch with the lettered shortcuts below or the small picker at the top of the pane.

**Outline, Research, and Palette are not right-column modes.** ⌘⌥O selects the project row, which shows a corkboard or table full-width in the CENTRE column instead of opening anything here — the review board, in Review; a compiled book instead, in Publish, once you have one — see [Structure & the Binder → The project row](structure-and-binder.md#the-project-row). ⌘⌥R and ⌘⌥P open the tree's own Research and Palette sections and scroll to them — see [Research](research.md) — rather than a pane in this column.

### Panes are grouped by persona

Each of the four personas (⌘1 Plan, ⌘2 Author, ⌘3 Review, ⌘4 Publish — see [Getting Started → Personas](getting-started.md#personas)) offers its own subset of these modes in the picker. A shortcut still opens its pane from any persona — it reveals the right column if it's hidden and switches to it — even one the current persona doesn't lead with:

- **Plan** — Inbox, Tasks, History, Inspector.
- **Author** — Diagnostics, Intent, References, Tasks, History, Inspector.
- **Review** — Annotations, Intent, References, Tasks, History, Inspector.
- **Publish** — Department, Visual Language, Tasks, Translation, History, Inspector.

**There is one order, and modes appear and disappear within it.** Reading down the whole set: Diagnostics, Annotations, Inbox, Department, Intent, References, Visual Language, Tasks, Translation, History, Inspector. Every persona above is that same sequence with the modes it doesn't offer taken out — so a mode never moves left or right of a mode it sits beside somewhere else, and you aren't hunting for it in a new place each time you change persona. Tasks marks the break between what you're working *with* and what's flowing *through*; History and Inspector always close the row, with Inspector on the far end.

Each persona's default — the mode it opens on — is just the first one it offers: Inbox in Plan, Diagnostics in Author, Annotations in Review, Department in Publish.

**What a persona leads you to is not what it can reach.** The right column shows what you *consult* while making something else, so a persona doesn't lead you to a mode for the thing it's there to make: you write research notes and palette cards in the binder tree — the same tree in every persona — and reach for **References** (⌘⌥E, Author and Review) to see what a chapter or a card is pinned to, or open the tree's own Research/Palette sections (⌘⌥R / ⌘⌥P) to browse them directly. Intent and Visual Language have no tree home at all — **they're right-hand panes everywhere, reached with ⌘⌥N and ⌘⌥V** rather than from any picker. They open, they work, and they stay selected while you use them; switch persona and come back and Plan is on its own modes again.

Switching persona while sitting on a pane the destination doesn't offer falls back to that persona's default rather than blanking the pane. A pane no persona offers is the one thing that isn't remembered across a persona switch: summon References with ⌘⌥E in Plan (which doesn't offer it), switch persona and come back, and you're on that persona's own mode again.

### Inspector mode (⌘⌥I)

Last in every persona's picker, so it's always in the same place. Shows metadata for whatever's selected in the binder.

**On the planning canvas** — Plan's centre column, always — it shows whatever is selected on the canvas, in one of three forms:

- **A region** — its name, whether it's collapsed, the **Piece** it's associated with, which cards live in it and which only appear in it (with **Cite a Card** to add an appearance), **Promote…**, and a Delete Region button.
- **A line** — its name, which is drawn on the line itself; clear the field and the name comes off. **Promote…**, and a Delete Line button. Both cards stay.
- **A card** — its first line, its own **Piece** picker with a line reading where its promotions will go, what it has been promoted into (with an **Open** button that takes you to the note, or a note that what it produced is no longer in the project), **what its words are part of** if a region's promotion folded them into something — *Its words are in “Act II fog”*, with its own **Open**, and a line saying that promoting this card makes something new rather than rewriting that — and **Promote…**. A card can say both at once: what it became, and what it is part of. **If Claude put the card there it says so** — *From Claude.*, and *Read from “…”* when it names the page it was read off — up with the card's own facts rather than down among the promotions, because being Claude's is not something that happened *to* the card and must not read as a mark saying it has already been promoted. Your own cards say nothing there. There's no Delete button here: ⌫ on the canvas is how a card goes.

Select nothing and it says so.

**So in Plan the Inspector is the canvas's** — the Inspector describes the middle column, and in Plan the middle column is always the canvas. Clicking a chapter in Plan's tree doesn't put that chapter's metadata here; it's the panes that are *about* a chapter that follow it — **Intent** (⌘⌥N) above all. Switch to Author (⌘2) for a chapter's own metadata.

Both Piece pickers offer only pieces that can actually hold research, so nothing on either list can fail when you promote. A card left on **None** follows the region it lives in, and the line under its picker says so — *Chapter Three (from its region)* — rather than leaving you to work out where the note went. See [Getting Started → The planning canvas](getting-started.md#the-planning-canvas) and [→ Promoting](getting-started.md#promoting).

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

**Two kinds of ruling draw differently, because they're read differently.** A
**directive** is a ruling about one paragraph — the note you leave a
translator with **Translator's note…** (⌘⌥C), or one the round report writes
when you keep your own wording. It sits in the strip like any other line. If
the paragraph it's anchored to is gone, it draws as an **orphan**: dimmed,
its text intact, *This paragraph no longer exists* beneath it, and **Remove**
instead of Edit and Revoke — there's no paragraph left for an edited
instruction to be about. Nothing is ever silently dropped or silently
re-anchored, and the check follows your editing: delete the paragraph in the
open document and the directive becomes an orphan while you watch.

**Glossary** entries — a term and how it's rendered, decided for the whole
book — are pulled out into a **table** above the other rulings, one row each:
term, rendering, and a note where there is one, with **Revoke** beside it.
They belong in an edition brief — that's where the buttons write them, and
where a translator is briefed with them — though the table draws wherever a
ruling of that shape turns up. They come from you or from a glossary proposal
you adopted on a round, and a table is what makes them scannable by someone
who can't read the language they're in. See
[The Publish Department](publish-department.md).

Letting Claude Desktop draft an edition brief or a visual language statement
for you to adopt is designed but not yet shipped — today a statement is
written here, by you.

The editor above the strip is for your prose, and typing a `## Rulings`
heading into it doesn't make the section — a heading with nothing under it is
just a heading, and it stays in your text like any other line. Let the buttons
write the section; if you've already typed a heading of your own, the next
ruling adopts it rather than adding a second one. **The `.md` file's own shape
is forgiving** — Maugham reads whatever list it finds under that heading and
doesn't require the exact form it writes itself, so a bare line with no date
works as well as one it dated for you. That
tolerance is for files arriving from your other Mac or from an older draft,
not an invitation to edit the file in Finder: like every document in Maugham,
an intent is kept in its own operation log and the `.md` is written out from
it, so an outside edit made while Maugham has the project open is discarded on
the next save.

### Visual Language mode (⌘⌥V)

How the book looks — typography, cover direction, the references you're steering by. Project-scope: one book, one look. Like Intent it's an ordinary document, with the same undo and the same cross-Mac merge, and it's likewise empty until you write in it.

**It takes pictures as well as words.** Drop image files onto the strip at the bottom of the pane, or paste one straight into the editor with ⌘V. Either way the picture is copied into a `visual-language_assets/` folder beside the document — your original stays where it is — and a Markdown image reference is added to the text, which you can move, caption or delete like any other line. Anything that isn't a picture is turned away and says so. Intent doesn't take pictures; it's prose about the writing.

**Claude reads this pane when it writes your book's design.** Ask it to author or revise a PDF/EPUB template and it reads what you've written here first, including a list of the images you've referenced — so the typography comes from your description rather than its own taste, and the sixth piece still matches the first five. Write it in your own words; there's no format to hit.

### Diagnostics mode (⌘⌥D)

The compiler's report on the open document — Author's own pane, and its default. Press ⌘R ("Check Writing") to ask Claude to check what you've written since the last check, or ⌘⇧R ("Fresh Eyes") to have it reread the whole piece cold; the header line says what happened last, and while a check is running you can press **Cancel**. See [Review Passes](review-passes.md#rounds-and-fresh-eyes) for what a check becomes once a piece has an active review pass.

It reads as a report: **Conformance** — every clause you've declared, quoted back in your own words, each *holds*, *strains*, or untouched by this draft, with an **Open Intent** button in the section header. No strain ever shows a paragraph id — each carries the words that paragraph said, as a chip you click to jump there.

**A continuity question and a reader's report mint as annotations, and the newest check's own show right here.** They don't send you off to look for them: the check you just ran fills a **This check** section, below the header and above the conformance summary, in the order the findings fall down your manuscript rather than newest-first. Each row carries **Got it** and **Not this** — one gesture each — plus a jump chip to the words it's about. Settle one and it leaves the section; a later check replaces the section entirely, so this is always the run you just pressed ⌘R for, never a backlog. Anything you leave alone is still there — waiting in your full queue, Review's Annotations pane (⌘⌥A) — but Author itself never shows you a pile.

**Notes that arrive while you're looking elsewhere put a count on the picker**, the way new captures do on the Inbox — a check finished somewhere you weren't watching, and the count clears the moment you open the pane.

**A note goes stale the moment its paragraph changes.** Edit the text a note is about and the note quietly drops out — nothing to dismiss, nothing left pointing at words that no longer exist.

The gear menu picks the model a check runs against — **Fast**, **Standard**, or **Deep** — and the choice is remembered per project.

**A clean check says so plainly.** A conformance section where every clause holds still renders — that's the good outcome, not an empty pane — and a check with no strain at all to raise reads *"Nothing to flag."* in the header, not silence and not a green checkmark standing in for an answer. That header line is deliberately about clauses alone, so it reads *"Nothing to flag"* whether or not **This check** has rows showing below it — the rows speak for themselves. Where **This check** changes what you read is the pane's own empty state, reached only when there's no conformance report at all: *"Nothing else to flag."* while a row is still sitting there, *"You've handled this check's notes."* once you've settled every one.

**Answering a conformance strain becomes a ruling on that piece's intent.** Press **Answer**, say why the thing it flagged is deliberate, and press Return: your sentence lands as a dated line under [that piece's Rulings](#intent-mode-n), and the note goes away, so the next check reads what you just told it rather than raising the same thing again. **Promote to Task** keeps a note instead — as a real task on the document, naming which section raised it, which syncs and survives where the notes don't. *(A continuity question and a reader's report answer to **Got it** / **Not this** in **This check**, above — see there. Once they leave that section, unsettled, they're in your full queue, with the full set of things you can do with a note.)* Full walkthrough: [Checking Your Writing](compiler.md).

### References mode (⌘⌥E)

**What this piece is pinned to**, as a shelf of thumbnails and titles — Author's and Review's. It's not a browser: there's no search and no tree. How long the list runs depends on the project — a novel chapter or a Collection piece shows what you linked or filed for it, plus its cards, so it's as long as you've made it; a short story or a screenplay has no per-piece research, so it shows every research asset in the project, plus its cards. Three things put something on it, and they're the ways a piece acquires context in Maugham:

- **Research you linked to this document** — drag its row from the tree's Research section onto the document's own row, or promote a canvas card or region into that chapter (see [Getting Started → Promoting](getting-started.md#promoting)); either links it, the same way. In a Collection this also includes the research a piece simply *contains* — dropped straight into its own folder — with no separate linking step; in a single-document project, every piece of research in the project is pinned, since there's nowhere else for it to belong.
- **Cards you clustered for it on the planning canvas**, grouped under the region they're arranged in — a titled section per region bound to this piece, in the reading order you laid the cards out (top-to-bottom, left-to-right). **If a region has been promoted, its section holds the note it became instead of its cards** — the region's material and the note it turned into are the same thing, not two things to see twice. That note stays under the region's name even when the piece already holds it another way (in a Collection, promoting writes it straight into the piece's own folder), so it appears once, where the region's title says where it came from.
- **Cards bound to the piece directly, with no region of their own**, under a final **Cards** section.

Research notes, PDFs, recordings, links, palette cards, photographs and loose canvas scraps all appear; a photograph shows a thumbnail, everything else shows the same kind glyph the canvas draws it with. If you delete something, it simply leaves the shelf — you'll never see a row that's only an id.

**In Author or Review, click a pin and it studies in the right column, in place of the pane picker and whatever pane was showing.** One at a time: clicking another pin swaps it. The study takes the picker's own width, so nothing about your writing column moves — there's no divider to drag and nothing to squeeze.

**What ends a study and what merely hides it are different things.** ✕, Escape, opening a different document, and selecting something else in the tree all end it outright. Any right-column ⌘⌥-letter ends it too, as long as you're still in Author or Review to receive it — including the one naming the pane you were already on, which is the keystroke to know: ⌘⌥E over a studied pin is how you get the shelf back, since the picker itself isn't on screen to click while you're studying. Switching to Plan or Publish, or hiding the whole right column (⌘⌥I) or the whole chrome (⌘\), only takes the study *off screen*: the pin you were studying is still the one waiting when you come back, whether that's a return to Author or Review, ⌘⌥I again, or ⌘\ again — nothing about a hidden study resets.

**The column studies in Author and Review.** In Plan or Publish the shelf is still there — you can see what a piece is pinned to — but a row isn't a button there: a caption at the bottom reads *"Studying a pin opens here in Author or Review."*

**This is the same set Claude is briefed on.** When you press ⌘R the compiler is told what this piece is pinned to, by name — so what you see on the shelf is what it can go and read.

### Department mode (⌘⌥K)

**Publish's desk**, and the mode Publish opens on. It's about the book rather than the chapter you have open: a **Design** section for the book's design, with its own Run, and a **Languages** section with a row per language edition. Every project has a designer from the moment it exists, so the Design row is always there; a language row appears as soon as there's a reason for one — even a translator's first question, before anything has been translated.

Each language row names its translator, says how much of the book is fresh, stale, and missing in that language, and — where you owe one — how many open queries the translator is waiting on you to answer. These are the same figures Claude reads through `translation_status`. A language you have never named a translator for says so rather than leaving the line blank.

**Edition Brief** on a row opens that edition's brief — a writer-owned statement, like your craft intent and your visual language, for register, idiom policy, what stays untranslated, and typographic conventions. Clicking it creates the brief the first time and opens that same one every time after. The chevron at the top takes you back to the desk.

Running a translation or a design round, judging a design proposal at the gate, and turning a translator's answer into a ruling are all covered in [The Publish Department](publish-department.md); reviewing a finished translation is in [Translating Your Manuscript](translation-review.md).

The right pane also has a **Tasks** mode (⌘⌥T) — see [Tasks & To-Dos](tasks.md) — and an **Annotations** mode (⌘⌥A) — see [Annotations & Suggestions](annotations-and-suggestions.md).

It also has a **History** mode (⌘⌥H) — a read-only timeline of edits, annotations, and checkpoints, with a scrubber for time-travel — an **Inbox** mode (⌘⌥B) — triage text/audio/photo captures from MaughamPhone, see [The Sense Pass](sense-pass.md) — and a **Translation** mode (⌘⌥L) — the selected paragraph's source text and any open translator queries, active while reviewing a translation, see [Translating Your Manuscript](translation-review.md).

⌘⌥0 toggles the whole right pane visibility.
