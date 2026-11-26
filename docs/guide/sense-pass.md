# The Sense Pass

A **sense pass** is a revision audit: does the prose actually deliver the
sensations the story needs? It is intent-first — Claude measures your draft
against *your* declared standard, not a universal rule. A deliberately spare
story is not "missing" sensory detail.

## The three-part loop

1. **Declare** — write a *craft intent*: what this piece needs. Click a
   chapter, press ⌘2 for its [Brief](right-column.md#brief-2), and type under
   **Going for** (⌘⌥N puts the cursor there); there is nothing to create
   first. Click the Book for the book's own. Not having one is a valid
   choice; it means you've decided this piece doesn't need the apparatus.
2. **Gather** — build *palette cards* in the binder's **Palette** section:
   right-click it, or use its **+** menu. One card per location, character,
   or motif. The card editor is visual, not Markdown — drag images in from
   Finder or paste them, pick colour swatches with the colour picker or
   sample them off a reference image with the eyedropper, and add sensory
   notes tagged sight / sound / smell / touch / taste (or untagged). ⌘⌥P
   (View ▸ Go to Palette) opens the section. Click a card to read and edit
   it beside your text, in Pulled up (⌘3).

   To keep a card at hand while you draft a chapter, pin it to the chapter —
   associate the card with the piece, or put it in a canvas region bound to
   the piece — and it shows in that chapter's fold in the binder, where a
   click pulls it up.

   **Managing a card** happens in the binder, like a note: right-click a card
   for **Duplicate** or **Delete**, ⌘-click several to delete them together,
   and drag a card onto the canvas to put it on the board. Renaming is the
   card editor's — the title is the card's own heading. There's no **Move
   to**: a card lives in the palette, and that's what makes it a card.

   **From your phone:** aim a capture at a palette subject from the Capture
   tab — photo, voice, or text, with an optional sense tag. Back at your Mac,
   click **Inbox** in the binder and promote aimed captures into cards: text
   and audio land as sense-tagged notes, photos in the card's image well.
   Browse cards and the project's intent from the phone's Read tab (reading
   only), and triage sense-pass notes from its Annotations tab.
3. **Audit** — ask Claude (via Claude Desktop and the Maugham connection) to
   run the sense pass below. Claude reads your intent, your palette, and the
   manuscript, and leaves paragraph-anchored notes in
   [To resolve](right-column.md#to-resolve-1) — Accept, Reject, Stet or
   Archive, as with any note, and mark what you plan to do about each one
   first if the pile is large.

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
