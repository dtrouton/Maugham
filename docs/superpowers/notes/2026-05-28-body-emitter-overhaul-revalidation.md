# Body emitter overhaul — done, ready for re-validation

**Date:** 2026-05-28
**Branch:** `feat/publishing-pipeline`
**Status:** Phases 1–7 implemented. Full suite green (1356 tests, 0 failures,
incl. real-tectonic compiles). **Awaiting the external tester's visual
re-validation against Playlist** — the rendered-PDF check is the acceptance
gate; do not consider this closed until it passes.

This picks up from `2026-05-28-body-emitter-overhaul-handoff.md` and executes
its 7-phase plan.

---

## Commits (oldest → newest)

| Commit | Phase | Subject |
|---|---|---|
| `b678659` | 1 | strip ¶ anchors in `parseFountain` (the one-liner; unblocks screenplay markers) |
| `4927336` | 2 | inline markdown parser; `paragraph` carries `[Inline]` |
| `b7487d5` | 3+4 | block-level prose parser + heading/blockquote emission |
| `2f1939c` | 5+6 | delete deprecated `ProseNode` cases; rewrite emitter tests |
| `a84aae4` | 7 | `\clearpage` between pieces + end-to-end PDF render guard |

Phases 3+4 and 5+6 were each committed as a pair: changing a Swift enum case's
associated type (and later deleting cases) forces every exhaustive `switch`
over it to update in the same commit to stay green.

---

## What changed, by symptom

- **Tribute — `*italic*`/`**bold**` leaked as literal text.** `ProseNode.paragraph`
  now carries `[ProjectAST.Inline]` instead of a flat `String`. New
  `InlineParser` (recursive-descent, fallback-to-literal) recognizes
  `*`/`_` emphasis, `**` strong, `` ` `` code (no recursion), `[[t|d]]` wiki
  links, and `  \n` hard breaks. Nesting works (`**bold _italic_**`,
  `*em **strong** em*`). Both emitters gained an `emitInline` walker.
- **Tank Park Salute — collapsed wall of text + literal `## Day 1/3`.**
  `parseProse` is now a line state machine. ATX headings become
  `.heading(level:, [Inline])` → LaTeX `\section*`/`\subsection*` +
  `\addcontentsline`, XHTML `<h2>`/`<h3>` (h1 reserved for the section title).
  Each paragraph emits a trailing blank line so LaTeX inserts `\par`.
  Blockquotes (`> …`) become nested `.blockquote([ProseNode])`.
- **Good Luck Babe — raw `<!-- ¶XXXX -->` anchors.** `parseFountain` now calls
  `stripAnchors` exactly as `parseProse` did.
- **Pieces shared a physical page / "start_on default wrong".** `LaTeXBodyEmitter`
  emits `\clearpage` before every section after the first. EPUB already
  isolates each section into its own spine item, so no change there.

Deprecated standalone `ProseNode.emphasis/.strong/.wikiLink` cases were
deleted — inline content lives only inside `paragraph([Inline])` now.

**`FountainNode` was deliberately not touched** (per the handoff's "what NOT to
do"). The Phase 1 anchor-strip is the whole screenplay fix.

**Out of scope, untouched** (still open per the original handoff): D1
list-desync, D4 checkpointID pinning, D5 per-section overrides
(`title_override`/`start_on`/`include_in_toc`), structured compile-error
codes, and `style_preset`-based chat-transcript rendering for Tribute.

---

## Re-validation: please run this

Re-compile **Playlist** (the same three pieces, same config) and confirm in
the **rendered PDF** (not just compile success — it always compiled):

1. ☐ Visible paragraph breaks within pieces (Tank Park Salute is properly
   paragraphed, not one justified block).
2. ☐ `## Day 1/3` etc. render as section headings, not literal `## ` text.
3. ☐ `**bold**`/`*italic*` render as formatting, not literal asterisks.
4. ☐ No surviving `<!-- ¶XXXX -->` in Good Luck Babe.
5. ☐ Each piece starts on its own page (no manual `start_on`).

### What I could verify here, and what I couldn't

- The production path is confirmed live: `PDFCompiler`/`EPUBCompiler` →
  `ProjectASTBuilder.build` → the emitters. My changes are in the real
  pipeline, not a side path.
- `PublishBodyRenderingEndToEndTests` compiles a markdown-rich prose piece +
  an anchor-bearing screenplay through the **real** `PDFCompiler`, extracts the
  PDF text via PDFKit, and asserts the words survive while `*`, `##`, `<!--`,
  and `¶` do not. This automates criteria 1–4 and would have caught the
  original bug.
- What I can't verify out-of-process: the actual **visual** layout against
  *your* Playlist project's on-disk template. Note your project has its own
  copy of `prose.tex`/`template.tex` (installed at init time) — the
  `\clearpage` fix is emitter-side precisely so it reaches your existing
  project without re-initializing. If criterion 5 still shows pieces sharing a
  page, check whether your project's `prose.tex` redefines anything that would
  swallow a `\clearpage`.

If all five pass, this is ready to fold into the publishing-pipeline milestone.
