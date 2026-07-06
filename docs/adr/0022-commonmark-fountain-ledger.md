# 0022 — CommonMark + Fountain grammar ledger

- **Status:** Implemented (2026-07-06, branch `feat/commonmark-fountain-expansion`)
- **Date:** 2026-07-06

## Context

The 2026-07-06 compliance audit
(`docs/superpowers/notes/2026-07-06-commonmark-fountain-compliance-audit.md`)
catalogued every place Maugham diverges from CommonMark 0.31.2 and Fountain
1.1: five real bugs (A1–A5), a set of semantic divergences needing an
intentional/not call (B1–B7), seven doc-drift items (C1–C7), and a long list
of already-intentional omissions (D). The design doc
(`docs/superpowers/specs/2026-07-06-commonmark-fountain-expansion-design.md`)
actioned it: fixed the bugs, reopened every previously-excluded feature under
one agreed philosophy, and consolidated the parser duplication that produced
the worst findings (`ProjectASTBuilder`'s independent Fountain classifier,
three separate asterisk-emphasis grammars).

## Decision

**Writer-first, per-surface** is the standing inclusion philosophy: manuscripts
get everything that serves creative writing; programmer-ish constructs
(tables, indented code, footnotes, entities, reference links) are supported
only where their corpus actually needs them — the in-app Help renderer and
research-note previews, never the manuscript surfaces.

The **decision ledger in the design doc is the canonical record** of what's IN
and OUT, and why, as of this milestone:

- CommonMark — IN: `docs/superpowers/specs/2026-07-06-commonmark-fountain-expansion-design.md#commonmark--in`
- CommonMark — OUT (confirmed intentional): `…#commonmark--out-confirmed-intentional`
- Fountain — IN: `…#fountain--in`
- Fountain — OUT (confirmed intentional): `…#fountain--out-confirmed-intentional`

Rather than duplicate that ledger's prose here (it would drift), this ADR
exists to make the decision **findable and binding**: the next compliance
audit should treat every row in those four tables as a deliberate, reviewed
choice — not re-litigate them from scratch. A gap not on the ledger and not
in `markdown-syntax.md` / `fountain-syntax.md`'s own omission lists is fair
game to flag; a gap that IS on the ledger is not a bug report, it's a design
decision that changed since 2026-07-06 or nothing at all.

Shipped highlights (full detail in the ledger):

- Strikethrough (`~~x~~`, prose only) and backslash escapes across every
  inline parser (editor, publish, Fountain).
- Paragraph-scoped (not just line-scoped) emphasis in prose.
- Publish now parses Fountain through the real `FountainTokenizer` (via
  `FountainNodeMapper`) instead of a duplicated hand-rolled classifier —
  this was the audit's highest-severity finding (A1): boneyard, notes,
  synopses, and sections were leaking into compiled PDFs/EPUBs. Dual
  dialogue publishes as true side-by-side columns as a result.
- Fountain scene numbers (`#4A#`), dot-less scene-heading stems
  (`INT ROOM - DAY`), and the two-space held blank line in dialogue.
- Publish lists (flat/tight), a fence verbatim guard, and backslash hard
  breaks.
- Editor scene-break styling parity with publish's `---`/`***`/`###` rule.
- Help renderer gained ordered lists and pipe tables (the corpus already
  used both — audit A3); research-note preview now groups paragraphs by
  blank line instead of one block per source line (A4).

## Consequences

- `markdown-syntax.md` and `fountain-syntax.md` are rewritten to match this
  ledger and the actual shipped behavior (closing all seven C-items);
  they are the writer-facing surface of this same decision.
- `docs/superpowers/notes/cross-surface-contracts.md` gains rows bringing the
  publish pipeline inside the registry for the first time (strikethrough via
  `EmphasisTraits`, the `sceneNumber` span/field, and "publish inline/Fountain
  parsing are adapters over the shared scanner/tokenizer" as a documented
  contract, not a free-standing reimplementation).
- Approach C (a unified display-block parser collapsing the five independent
  Markdown block-splitters) was explicitly deferred — see the design doc's
  "Non-goals" and `docs/roadmap.md`'s follow-on entry. This ADR's ledger does
  not cover block-splitter unification; that remains open.
- A future ledger row change (e.g. deciding to support reference links) should
  update the design doc's table AND get its own ADR addendum or a new ADR —
  this file is a pointer, not itself the place new decisions get made.
