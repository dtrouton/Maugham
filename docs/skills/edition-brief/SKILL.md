---
name: edition-brief
description: Interview the writer and draft an edition brief for one language of a Maugham project, then propose it for their Adopt/Discard. Use when asked to set up, draft, or revise how a translated edition should read.
---

# Edition brief

You are drafting the writer's doctrine for one translated edition — how it
should read, in their own hand, for a translator (in-app or human) to honor.
You never write the brief into the project yourself; you interview the
writer, draft a proposal, and hand it to `propose_edition_brief`. The writer
sees a diff against whatever exists and chooses Adopt or Discard in Maugham.

## What matters, in order

1. **A brief is the writer's doctrine, not your judgment call.** It settles
   register, address, and what a translator must never smooth away — for
   one language, on the record, so every session after this one reads the
   same rulings instead of re-deciding. You draft it from what the writer
   tells you; you never invent a register they didn't state.
2. **Read first, in this order:** `read_craft_intent` for the project (the
   voice this edition has to carry across), `read_edition_brief` for the
   language you're working on, one sample chapter via `read_document`, and
   the palette via `list_palette_cards` (the story's world — proper names
   and terms an edition will need to render). A prior session's rulings in
   the existing brief may already answer a question you're about to ask —
   read it before the interview, not after. An existing brief means you are
   REVISING: say so, and the diff the writer sees will show exactly what
   changed rather than replacing their doctrine wholesale.
3. **Interview, one question at a time**, naming the target culture's
   default before each question so the writer is choosing against
   something concrete, not a blank page:
   - Texture and content — what does this prose *do* that a translator has
     to preserve, not just what it says (per the project's craft intent)?
   - What won't you let a translator smooth away — repetitions, fragments,
     the deliberately plain word where a fancier one would read more
     "translated"?
   - Regional variety — es-ES or es-419, pt-BR or pt-PT, fr-FR or fr-CA,
     and any dialect the target language forks on?
   - Forms of address — tú/usted, tu/vous, keigo level, and whether it
     varies by character or relationship?
   - Typographic conventions — quotation marks, dash style, numerals,
     capitalisation of titles?
   - First glossary entries — every proper name in the sample chapter,
     with a proposed rendering, plus any term the book uses as a term
     (an invented word, a title, a recurring object) rather than an
     ordinary noun.
4. **Draft the brief.** Prose sections covering register, forms of
   address, what stays untranslated, and typographic conventions — in
   your own words, answering what the interview settled. Then a
   `## Rulings` section holding ONLY glossary lines, one per entry, of the
   exact shape:
   ```
   - «term» → «rendering» (note)
   ```
   Nothing else goes under that heading — a directive belongs to the
   writer, made in Maugham directly (Translator's note…) once the brief is
   adopted; the tool refuses anything under `## Rulings` that isn't a
   glossary line. No em-dashes and no guillemets inside a term, rendering,
   or note (the guillemets `«` `»` are the delimiter, not part of the
   text), and no line breaks inside an entry.
5. **End by calling `propose_edition_brief`** with `language`, the whole
   `markdown`, and a one-or-two-sentence `rationale`. Never paste the
   drafted brief into chat as the deliverable — the proposal call is the
   deliverable. Tell the writer where the gate is: the tool's response
   carries `adoptWhere`, so read it back to them rather than guessing at a
   menu (Publish → Department desk → the language row's Edition Brief, a
   diff with Adopt / Discard). A second call for the same language
   replaces the pending proposal — if the writer asks for changes before
   they've adopted, redraft and call it again rather than trying to patch
   the pending one some other way.

## Tools

`read_craft_intent` → `read_edition_brief` → `read_document` (sample
chapter) → `list_palette_cards` → interview → `propose_edition_brief`
(`project_id`, `language`, `markdown`, `rationale`).
