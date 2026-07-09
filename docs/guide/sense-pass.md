# The Sense Pass

A **sense pass** is a revision audit: does the prose actually deliver the
sensations the story needs? It is intent-first — Claude measures your draft
against *your* declared standard, not a universal rule. A deliberately spare
story is not "missing" sensory detail.

## The three-part loop

1. **Declare** — write a *craft intent* doc: a freeform statement of what this
   piece needs. Add one from the inspector (**Add craft intent…**). Not having
   one is a valid choice; it means you've decided this piece doesn't need the
   apparatus.
2. **Gather** — build *palette cards* in the Palette segment: one card per
   location, character, or motif, holding images, colour swatches, and sensory
   notes (tagged sight / sound / smell / touch / taste). Keep a card open
   beside the editor with ⌘⌥7 while you draft.
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
