---
name: transcribing-notebooks
description: Transcribe handwritten notebook photos from a Maugham project's research into text notes. Use when asked to transcribe notebook pages, journals, or handwritten research images.
---

# Transcribing notebook photos

Turn photographed notebook pages (image research items) into faithful text
transcriptions stored as research notes. Never write into the manuscript.

## Workflow

1. **Find the pages.** `list_research(project_id)` — image items have
   `kind: image`. Note which pages are already covered by existing
   transcription notes (search their titles/bodies first; don't re-transcribe).
2. **Read each page.** `read_document(project_id, document_id)` — the
   default 2048px works for most handwriting. If the transport caps you
   to a lower size (the response says so), that's normal.
3. **Hard-to-read lines:** re-read with a `region` crop at higher
   effective resolution, e.g. `{"x": 0, "y": 0.6, "width": 1, "height": 0.2}`
   for a band 60% down the page. Crop tight; resolution goes where the
   pixels are.
4. **Write the transcription** with `add_note` into the piece's research
   (pass the piece as the target so it lands beside the source images).
   One note per session or per chapter of pages — follow the existing
   naming in the project (e.g. `dreams-notes-transcription-part-2`).
5. **Verify continuity.** Consecutive pages usually continue sentences
   across the boundary; if a page doesn't follow from the last, say so
   rather than smoothing it over.

## Honesty rules (non-negotiable)

- Transcribe only what you can actually read in the returned pixels.
- Mark unreadable passages `[illegible]` — never reconstruct, guess, or
  paraphrase them into existence.
- If a read returns no visible image, STOP and say exactly that. Do not
  produce a transcription from context or memory.
- Preserve the writer's spelling, punctuation, and line grouping; use
  paragraph breaks where the notebook has them.
