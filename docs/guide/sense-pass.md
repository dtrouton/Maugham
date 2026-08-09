# The Sense Pass

A **sense pass** is a revision audit: does the prose actually deliver the
sensations the story needs? It is intent-first — Claude measures your draft
against *your* declared standard, not a universal rule. A deliberately spare
story is not "missing" sensory detail.

## The three-part loop

1. **Declare** — write a *craft intent*: a freeform statement of what this
   piece needs. Open the **Intent** pane (⌘⌥N) and type; there is nothing to
   create first. The pane follows what you have selected in the binder tree, so
   the project has one and any document can have its own — select the project
   row at the top of the tree for the book's, a chapter for that chapter's.
   That row is at the top of whichever list your project type shows there:
   chapters in a novel, Pieces in a Collection, the script and its scenes in a
   screenplay. The tree is the same one Plan's left column shows, with the
   canvas in the middle — so the book's intent and then each chapter's is one
   column, without needing a second surface. **⌘⌥N is how you open the Intent
   pane**: it's a right-hand pane, not a tree section, so no persona's picker
   lists it. The shortcut opens it in any persona, and it follows the tree
   selection in all of them. (In a screenplay, selecting the project row or
   the **Script** row keeps whatever's on screen; clicking a *slugline* is a
   navigation into the script itself, so it takes you to **Author** — see
   [Structure & the Binder](structure-and-binder.md).) The Inspector's **Open
   Intent** button goes to the same place. Not having one is a valid choice; it means you've decided
   this piece doesn't need the apparatus.
2. **Gather** — build *palette cards* in the tree's **Palette** section, in
   any persona — right-click it, or use its own **+** menu. One card per
   location, character, or motif. The card editor is visual, not markdown —
   drag images in from Finder or paste them from the clipboard, pick colour
   swatches with the colour picker or sample them straight off a reference
   image with the eyedropper, and add sensory notes tagged sight / sound /
   smell / touch / taste (or left untagged). Keep a card open beside the
   editor with ⌘⌥P while you draft — that pane is a read-only view of a card
   and it opens in any persona, so building cards stays in Plan while reading
   them goes wherever you're working.

   **Managing a card** is the tree's, like managing a note: right-click a card
   row for **Duplicate** or **Delete**, ⌘-click several and delete them
   together, and drag a card row onto the planning canvas to put it on the
   board. Renaming is the card editor's — the title is the card's own heading,
   so you change it where you can see it. There's no **Move to**: a card lives
   in the palette group, and that's what makes it a card.

   **From your phone:** the palette's most natural moment often happens away
   from the desk. Aim a capture at a palette subject from the Capture tab —
   photo, voice, or text, with an optional sense tag — before or after the
   card exists; aiming is never required. Back at your Mac, promote aimed
   captures into cards from the Inbox pane (⌘⌥B): text and audio land as
   sense-tagged notes, photos land in the card's image well. Browse existing
   cards and the project's intent from the phone's Read tab — reading only, and
   the project's own; a document's intent stays on the Mac — and triage
   sense-pass annotations from the Annotations tab, same as any other note.
3. **Audit** — ask Claude (via Claude Desktop + the Maugham MCP connection) to
   run the sense pass below. Claude reads your intent, your palette, and the
   manuscript, and leaves paragraph-anchored annotations you triage in the
   Annotations pane (⌘⌥A) — Accept, Reject, or Archive, as with any annotation.

## The prompt

Paste this into Claude Desktop (adjust the document name):

> Run a sense pass on **[document]** in my project **[project]**.
>
> 1. Call `read_craft_intent` first. If no intent doc exists, tell me so and
>    ask whether I want a generic pass or help drafting an intent doc — do not
>    invent a standard silently.
> 2. Call `list_palette_cards`, then `read_palette_card` for each card relevant
>    to this document (look at its locations, characters, motifs).
> 3. Read the document and audit it against my stated intent and the gathered
>    palette: Which scenes deliver the sensations I said they should? Where is
>    the prose all sight and no body? Which palette material never reached the
>    page? Where is groundedness *absent by my own design* — and therefore fine?
> 4. Leave your findings as paragraph-anchored annotations: `add_comment` for
>    observations, `add_craft_note` for reusable principles. Anchor each note
>    to the specific paragraph it concerns.

## What Claude can and cannot do

Claude reads the intent doc, palette cards (including images), and manuscript;
it writes only into the annotation layer. It never edits your manuscript, your
intent doc, or your palette — those are yours.
