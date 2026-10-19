# ADR 0033 — Report elements in manuscripts

**Date:** 2026-10-19 · **Status:** Accepted (grammar and storage; publishing, editor and Word export follow) · **Milestone:** report-foundations (plan 1, grammar and storage; branch `claude/report-plan1`)

## Context

Maugham began as an editor for creative writing. Its goal is now every kind of writing, with business reports first and long-form non-fiction after.

[ADR 0022](0022-commonmark-fountain-ledger.md) ruled tables out of manuscripts and publishing; its ledger design (`docs/superpowers/specs/2026-07-06-commonmark-fountain-expansion-design.md`) called them "not writer content". It also left out reference links, inline images and anything else a report needs. That was right for fiction. It is wrong for a report.

The 2026-10-17 foundations audit (findings C3 and C4) named the gap. Denver ruled on it on 2026-10-19:

- **D1.** Business writing comes first, and the design must serve every form of writing.
- **D8.** The new elements work in every project kind, not only in a Report.
- **D11.** Text on disk follows Pandoc conventions.

ADR 0022's own rule says a ledger change needs an ADR. This is that ADR.

Design of record: `docs/superpowers/specs/2026-10-19-report-foundations-design.md`.

## Decision

### 1. Seven elements are IN, in every project kind.

Each has exactly one form on disk (spec §3.1). The editor writes these forms and never invents others.

| Element | On disk |
|---|---|
| Table | GFM pipe table, with an optional caption line directly below it: `Table: Q3 revenue {#tbl:q3}` |
| Footnote reference | `[^n]`, inline. The label is any label; output numbers footnotes in order. |
| Footnote definition | `[^n]: text`, a block of its own |
| Figure | `![Caption](../research/path.png){#fig:label}`, alone on a line. The path is relative to the document. |
| Citation | `[@key]`, `[@key, p. 12]`, `[@a; @b]` |
| Cross-reference | `@fig:label`, `@tbl:label`, `@sec:label` |
| Section label | `# Heading {#sec:label}` |

Rules that come with them:

- Labels are unique per project. A duplicate is a diagnostic in the editor and a publish problem.
- An image path must resolve inside the project's research. A path outside the project, or a remote URL, is refused.
- A citation of a key that does not exist is a diagnostic and a publish problem.

### 2. Everything else ADR 0022 excludes stays OUT.

This is explicit, so nobody reads the new rows as wider than they are:

- indented (four-space) code;
- fenced code blocks, and code blocks in general;
- entities;
- reference links;
- inline images, meaning any image that is not alone on its line.

Fountain is unchanged.

### 3. The fence fix is dropped.

The spec once planned to make `ParagraphParser` fence-aware. We do not do it.

A fence-aware parser would turn the hidden `¶id` anchor line of an already-split fence's second half into literal text inside the merged fence. That change would sit on the per-keystroke hot path. No element in this decision contains a blank line, so the fix buys nothing here. Code fences stay unsupported writer content, as ADR 0022 says.

### 4. The op log needs no new kind.

Every element is text inside an ordinary paragraph. A pipe table, with its caption, has no blank line, so it is one paragraph. A figure line, a footnote definition and a labelled heading are each one paragraph. Citations, cross-references and footnote references sit inside their paragraphs.

### 5. One reader, in MaughamCore.

`MarkdownBlockParser` and one inline scanner read these forms. Mac and phone share them (tripwire 19). The phone reader renders a pipe table as a table, and a `Table: a | b` caption line below it shows as one more data row. It shows the other forms as plain text and never mangles them.

## Consequences

- **A paired release.** The manifest gains a profile and its switches, and research items gain citation fields. `currentSchemaVersion` goes from 9 to 10. An older Mac or phone then refuses the project rather than dropping the new fields on its next save. Mac and iPhone ship together.
- **The ledger moves.** The commonmark-fountain design's ledger now has tables IN (code blocks stay OUT), and new IN rows for footnotes, figures, citations, cross-references and section labels. ADR 0022 is partly superseded by this ADR.
- **Plan split.** The milestone is four plans, and each later plan is re-derived against the built code:
  1. Grammar and storage: the Core parser and scanner, research citation fields, the manifest profile and schema 10, this ADR.
  2. Publishing: AST nodes, numbering and resolution, the LaTeX and XHTML emitters, References and the lists.
  3. The editor: styling, insert commands and pickers, tidy tables and the grid editor, figure drag-in.
  4. Word export and the Report profile.
- **Existing manuscripts are safe.** A manuscript that happens to contain a pipe table or `[^1]` today reads as the same text. It now also means something.

## References

- `docs/superpowers/specs/2026-10-19-report-foundations-design.md`, §2 (decisions), §3 (grammar and op log), §8 (plan split)
- `docs/superpowers/notes/2026-10-17-foundations-audit.md`, C3 and C4
- [ADR 0022](0022-commonmark-fountain-ledger.md), partly superseded
