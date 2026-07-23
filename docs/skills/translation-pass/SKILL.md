---
name: translation-pass
description: Translate a Maugham manuscript into another language through the parallel translation layer. Use when asked to translate, localize, or prepare a foreign-language edition of a Maugham project.
---

# Translation pass

You are producing a translated edition of the writer's book — not editing the
manuscript. Every translated paragraph lives in a parallel layer keyed to the
source text; the manuscript itself never changes, and nothing you write here
is visible in any other language's edition.

## What matters, in order

1. **Coverage is derived, never assumed.** `translation_status` tells you how
   much of a document (or the whole project) is translated for a language,
   broken down by `fresh` / `stale` / `missing`, plus `orphans` (translations
   whose source paragraph was deleted) and `open_queries`. Start every pass
   here — it's the honest state of the work, not your memory of it.
2. **Work the gap, not the whole document.** `read_translation` with
   `status=stale` or `status=missing` returns exactly the paragraphs that
   need attention, each paired with its current source text. Retranslate
   those; leave `fresh` alone.
3. **Write in batches with `write_translation`.** It's all-or-nothing — one
   unknown paragraph id fails the whole batch, so pull ids fresh from
   `read_document`/`read_translation` rather than reusing ones from an
   earlier session. The server stamps each record with a hash of the source
   paragraph at write time, so a later source edit is what flips a
   translation to `stale` — you don't manage that yourself.
4. **The compile gate is the real finish line.** `compile` with `language`
   set refuses to produce a translated edition while paragraphs are stale or
   missing (an untranslated book mislabeled as an edition is worse than no
   edition). Run it, read the gap report, translate what it names, and
   repeat — that loop, not a self-assessment, is how you know the pass is
   done. `allow_stale: true` is the writer's escape hatch for a
   partial-edition preview, not something to reach for on your own.
5. **Chrome is verbatim, not translated.** Scene numbers, standalone numerals,
   sluglines you're leaving in the source language, and similar non-prose
   elements go through `write_translation` with `verbatim: true` rather than
   a copied-by-hand `text` — the server copies the current source text, so it
   never drifts out of sync with it.
6. **Preserve the structure inside a paragraph.** `write_translation` checks
   non-verbatim entries for structural drift — a dropped `**bold**` run, a
   changed block shape — and returns warnings. Heed them: they usually mean
   an inline marker or a speaker label got flattened in translation, not that
   the checker is being pedantic. For Fountain pieces, `compile` separately
   warns when a translated line's screenplay element (action / dialogue /
   character / scene heading) no longer matches the source at the same
   position — that's a sign a slugline or character cue was translated into
   plain prose by mistake.
7. **A language-coupled template is the writer's job, not the gate's.** The
   coverage gate only covers paragraph text. If the edition's front matter,
   headers, or typographic conventions need to differ by language, that's a
   `template.<lang>.tex` / `styles.<lang>.css` / per-piece
   `<piece>.<lang>.tex` variant beside the base file — Maugham resolves it
   automatically when compiling with that language, falling back to the base
   file if the variant is absent. Ask the writer before assuming a variant is
   needed; don't invent one to make a compile pass. The resolver's reach
   stops at the template and per-piece style files themselves — it does not
   follow `\input` lines inside them. If the base template inputs partials
   (preamble/frontmatter/backmatter), a `frontmatter.<lang>.tex` sitting next
   to the base file does nothing until a `template.<lang>.tex` exists whose
   `\input` lines point at those `<lang>` partials — write the template
   variant and everything else follows from it.
8. **Literal-string style hooks are part of the translation contract, not
   just the LaTeX.** A piece's style file can key special formatting off a
   fixed string — a speaker-label probe that matches a character's dialogue
   cue, say. A probe written against the source-language spelling silently
   stops firing the moment that line is translated, with no error to flag
   it. Check a piece's style file for this kind of hook before calling a
   translation pass done, and update it to match the translator's actual
   word choice, not a guessed cognate. The Playlist ES edition needed a
   `Docto` stem probe (matching `Doctor:` and `Doctora:` both) because the
   translator correctly rendered the character as female — "Doctora:" — and
   a probe pinned to `Doctor:` alone would have missed her every time.
9. **Don't guess at voice, register, or ambiguous terms.** Formality level,
   regional variants (`es` vs `es-mx`), a pun that doesn't survive translation
   — raise it with `add_query`, passing `language` so it's tagged as a
   question about this edition rather than a general manuscript query. The
   writer answers through the same reply flow as any other query.

## Tools

`translation_status` (coverage summary, per-doc or project-wide) →
`read_translation` (source + translated text + freshness `status`, filterable)
→ `write_translation` (batched writes, `text` or `verbatim: true` per entry) →
`compile` with `language` (produces the edition; the failure report *is* the
worklist) → `add_query` with `language` (voice/register decisions that aren't
yours to make). `republish` reproduces a prior edition exactly, including its
original `language` and gate mode — use it to regenerate output, not to
re-translate.
