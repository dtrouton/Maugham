---
name: maugham
description: Working with the Maugham writing app (manuscripts, research, transcription, editing passes, publishing) via its MCP tools. Use whenever the Maugham MCP server's tools are in play or the user mentions Maugham.
---

# Maugham

Maugham serves its own task skills over MCP — always fetch the current
procedure instead of improvising:

1. Call `get_help` with topic `skills` to list the available Maugham
   skills with descriptions.
2. Call `get_help` with the relevant skill's name (e.g.
   `transcribing-notebooks`, `editing-pass`) to load the full procedure.
3. Follow the loaded procedure. It is authoritative for how to use
   Maugham's tools for that task and reflects the installed app version.

Hard rules that apply regardless of task: Claude never edits manuscript
text directly — writes go to research, to the annotation layer, or to the
project's planning canvas, and each of those reaches a manuscript only
when the writer promotes it. `get_help` without a topic lists Maugham's
user documentation.

## A page the writer photographed

The deliverable is what was on the page, on the writer's canvas, beside
the page itself — so they can check the reading against the source by
looking. `add_canvas_scraps` is the write tool; it takes the words, an
optional region label, and `source_item_id`, the **research item** the
page now lives in. It chooses where the cards go, so there is nothing to
decide about placement.

**The order is not guessable, and getting it wrong looks like a missing
image rather than a wrong step.** A capture in the inbox is not yet
readable: `read_inbox_entry` returns text, transcript, kind and the
asset's *filename* — never the image. So the page has to become a
research item first, and only then can it be read:

`list_inbox` → `promote_inbox_entry` → `read_document` (the image) →
`add_canvas_scraps(source_item_id:)`

If a source id is refused, the likely cause is an inbox id passed where a
research id belongs; the refusal says so. For the transcription itself —
what counts as complete, and how to mark what the ink defeats — load
`transcribing-notebooks`, which is authoritative for it.

<!-- maugham:managed — installed by Maugham. Hand edits are replaced when you click Update in Maugham's Claude setup sheet. -->
