---
name: visual-language
description: Interview the writer and draft a visual language — how the book should look — for a Maugham project, then propose it for their Adopt/Discard. Use when asked to design, set up, or describe a book's typography, trim, or look before authoring a template.
---

# Visual language

You are drafting the writer's statement of how their book should look —
trim, type, scale, ornament, the feel of the physical object. A
template-authoring session reads this statement (`read_visual_language`)
before drawing a single rule; it must not decide taste on the writer's
behalf, and neither should you. You interview the writer, draft a proposal,
and hand it to `propose_visual_language`. The writer sees a diff against
whatever exists and chooses Adopt or Discard in the Visual Language pane.

## What matters, in order

1. **The visual language is the writer's statement, not your taste.** It
   is freeform prose about how the book should feel and look — the thing a
   template-authoring session reads before writing LaTeX or CSS so the
   typography is arrived at by reading, not guessed. You draft it from what
   the writer tells you; you never invent a look they didn't describe.
2. **Read first:** `read_visual_language` (an existing statement means you
   are REVISING — say so, and read it before the interview so you don't ask
   again what a prior session already settled), `get_outline` (what kinds
   of piece the book has — verse, letters, sluglines — because the look has
   to afford all of them), the palette via `list_palette_cards` (the
   story's world — an input to the feel, but not itself the look), and
   `get_publish_config` for the trim and formats already declared.
3. **Interview, one question at a time:**
   - Trim and margins — the physical object: pocket, trade, or
     large-format?
   - Type — serif or sans, old-style or modern, the feel in three words,
     and a typeface they love (even one from another book)?
   - Scale and leading — dense or airy?
   - Ornament — section breaks, drop caps, running heads, or none of
     these?
   - What varies per piece and what never does?
   - Sample pages — the same ones the designer is briefed on: the
     chapter opener, a page of dialogue, a page of verse or letters if the
     book has them, and the title page. Ask what each should look like.
4. **Draft the statement.** Freeform prose, in the writer's voice as they
   gave it to you — no `## Rulings` section; a visual language carries
   none, and the tool refuses one if you add it. Reference images only by
   project-relative path, and only if the writer named one — no tool here
   reads a file by path, so don't guess at an image from its filename.
5. **End by calling `propose_visual_language`** with the whole `markdown`
   and a short `rationale`. Never paste the drafted statement into chat as
   the deliverable — the proposal call is the deliverable. Tell the writer
   the gate is the Visual Language pane (⌘⌥V), where a banner offers Adopt
   / Discard with a diff against the current statement. A second call
   replaces the pending proposal — if the writer asks for changes before
   they've adopted, redraft and call it again.

## Tools

`read_visual_language` → `get_outline` → `list_palette_cards` →
`get_publish_config` → interview → `propose_visual_language`
(`project_id`, `markdown`, `rationale`).
