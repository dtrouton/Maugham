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

## Making the book look like something

The deliverable of any LaTeX or EPUB/CSS work is a template that looks like
the book *the writer described* — so the typography is theirs, arrived at
by reading, not by taste. `read_visual_language` (it takes `project_id`
and nothing else; the book has one look) is where that description lives:
freeform prose about feel and type, plus `image_paths`, the pictures it is
built on. Read it before writing a template and before revising one — the
second is where the look quietly drifts, because a session that re-decides
from scratch produces a piece six that does not match pieces one to five.

**Two things are worth knowing before you go looking.** The sensory
palette is a different object that looks like this one: it is the
*story's* world, an input to prose, and it will not tell you how the book
should be set. And `image_paths` are paths, not pixels — no tool here
reads a file by project-relative path, so you can see which images the
look rests on but not what is in them. Ask the writer to describe one
rather than guessing from its filename.

Absence is an answer: `exists: false` means the writer has not declared a
look, not that they forgot. That is the moment to ask what the book should
feel like — and what they tell you belongs in the Visual Language pane,
where it will still be there for the next edition.

<!-- maugham:managed — installed by Maugham. Hand edits are replaced when you click Update in Maugham's Claude setup sheet. -->
