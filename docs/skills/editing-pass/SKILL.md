---
name: editing-pass
description: Run an editing pass over a Maugham manuscript using the annotation layer. Use when asked to edit, critique, line-edit, or review manuscript text in Maugham.
---

# Editing pass

Editorial feedback in Maugham flows through the annotation layer. The
manuscript itself is never edited directly — the writer accepts or
rejects every change.

## Workflow

1. **Read this project's craft intent first**: `read_craft_intent`. It
   holds the writer's own guidelines for this project (voice, tense,
   things to leave alone). It overrides any general editing instinct you
   have. If there is no craft intent, say so and ask what kind of pass
   the writer wants before annotating.
2. **Read the target text** with `read_document` and use the returned
   paragraph ids for anchoring.
3. **Annotate, never edit:**
   - `add_comment` — editorial observations; use `quote` to anchor a
     specific phrase.
   - `add_suggested_change` — concrete rewordings the writer can accept
     with one click. Keep each suggestion minimal and single-purpose.
   - `add_query` — questions (continuity, factual, intent) rather than
     opinions.
4. **Batch sensibly.** A pass of focused annotations on one chapter beats
   a scattering across the whole manuscript. State your coverage when done
   ("commented on chapters 1–2, stopped there").
5. **Respect prior rejections.** Rejected annotations carry the writer's
   reasoning — read them (`list_annotations` with status filters) and
   don't re-raise settled points.
