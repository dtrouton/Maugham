---
name: transcribing-notebooks
description: Transcribe handwritten notebook photos from a Maugham project's research into text notes. Use when asked to transcribe notebook pages, journals, or handwritten research images.
---

# Transcribing notebook photos

You are producing the faithful text record of the writer's handwritten
notebook pages (image research items). The deliverable is a transcription
the writer can trust without re-checking the photos: complete, verbatim,
honestly marked where the ink defeats you.

## What matters, in order

1. **Nothing silently dropped.** Every handwritten line ends up either
   transcribed or explicitly marked `[illegible]`. Before finishing a
   page, reconcile against the image — if a sentence reads as nonsense,
   you have probably lost a line; go back and look.
2. **Verbatim fidelity.** Preserve the writer's spelling, punctuation,
   and paragraph grouping. Resist smoothing what they actually wrote.
3. **Honesty when the ink wins.** Attempt every word; look closer before
   giving up (a region crop raises effective resolution on a stubborn
   line); only then mark `[illegible]`. Never reconstruct from context or
   memory. If a read returns no visible image, stop and say exactly that.

## Constraints

- Transcriptions are research notes — never manuscript text. Create the
  note with `add_note`, then file it beside the source images with
  `move_research_item` (`research_ids: [<note id>]`,
  `target_document_id: <piece id>`).
- Check what's already transcribed before starting (search existing note
  titles and bodies) and extend the established naming rather than
  repeating work.
- Consecutive pages usually continue mid-sentence. If a page doesn't
  follow from the previous one, say so rather than smoothing it over.

## Tools

`list_research` finds the pages (`kind: image`). `read_document` returns
a page image and accepts `max_dimension` and a normalized `region` crop
for looking closer at a stubborn line. Read whole pages; crop to inspect,
not to assemble — stitching a page together from crops is how lines get
lost.
