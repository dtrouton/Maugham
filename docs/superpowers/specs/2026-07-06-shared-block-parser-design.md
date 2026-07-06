# Shared Markdown block parser (approach C) — design

**Date:** 2026-07-06
**Status:** approved design, pending implementation plan
**Antecedents:** the 2026-07-06 compliance audit's cross-surface inconsistency
table (`docs/superpowers/notes/2026-07-06-commonmark-fountain-compliance-audit.md`,
section E) and ADR 0022's writer-first ledger. This milestone was green-lit at
the CommonMark/Fountain expansion's A-vs-C checkpoint.

## Problem

Five hand-rolled Markdown block splitters exist — phone `MarkdownBlocks`,
`GuideMarkdownView`, `ResearchNotePreviewPane`, `SyntaxHelpSheet`, and
`ProjectASTBuilder.parseProseBlocks` — and three of the five shipped real bugs
found by the audit. The same Markdown segments differently per surface (soft
breaks: three behaviors; `#foo`: heading on one surface only; fences:
monospace on one, emphasis soup on others). Divergence is structural: five
implementations of one idea always drift.

## Decisions (user-approved)

- **Reach:** the four display surfaces AND publish's prose block loop — all
  five duplicates die. Publish keeps its own inline layer and the EMISSION
  contract.
- **Grammar:** uniform block recognition everywhere. Per-surface PRESENTATION
  choices stay in the views (phone keeps manuscript line breaks; research
  renders images; Help uses `.full` inline parsing).
- **Out of scope:** annotation-body Markdown rendering (separate decision);
  inline-layer unification (swift-cmark on display surfaces vs
  `InlineEmphasisScanner` in editor/publish stays as-is); the editor tokenizer
  (styling layer over live text — different output shape); third-party parser
  adoption (MaughamCore is Apple-frameworks-only; swift-markdown is an SPM
  package and parses full CommonMark, not the ledger subset).

## Architecture

### Core: `MarkdownBlockParser` (MaughamCore, new file)

```swift
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(lines: [String])           // raw lines — consumers choose the join
    case list(ordered: Bool, items: [[String]]) // raw lines per item
    case fence(lines: [String], info: String?)
    case table(header: [String], rows: [[String]])
    indirect case blockquote(blocks: [MarkdownBlock])
    case thematicBreak                        // ---(3+) | *** | ### exactly-3
    case soloImage(altText: String, path: String) // ./-relative, whole-line
}
public enum MarkdownBlockParser {
    public static func parse(_ text: String) -> [MarkdownBlock]
}
```

Pure function, **no options** — configuration knobs are how divergence sneaks
back in. Grammar rules (each matches the ledger/current best implementation):
- ATX headings: 1–6 `#` + required space (the Help window's lax `#foo` rule
  dies — that was an audit divergence, not a feature).
- Paragraphs: blank-line-delimited; raw lines preserved (soft-break policy is
  the consumer's).
- Lists: `-`/`*`/`+` and `1.`/`1)`; flat; indented continuation joins the
  item; an unindented non-marker line ends the list and reprocesses (same
  rules the publish builder shipped in the expansion milestone).
- Fences: ``` opens/closes; verbatim raw lines; info string captured;
  unclosed fence runs to end of input.
- Tables: a `|` line followed by a `|---|`-style delimiter row (alignment
  colons allowed); cells split on unescaped `|`, trimmed; all-blank header
  permitted (consumer may skip rendering it).
- Blockquotes: leading `>` (optional following space accepted — spec-lenient,
  supersedes the editor-doc'd space-required nuance for display surfaces
  only); one visual level; inner content recursively parsed.
- Thematic breaks: `-{3,}`, `***`, `###` (exactly-3 for `*`/`#`) — identical
  to editor + publish scene-break rules.
- Solo images: whole-line `![alt](./relative)` — recognized so research can
  render; other surfaces may present as text.
- Anchor stripping is NOT the parser's job — callers run
  `MarkdownDisplayFilter.stripAnchors` first where manuscript text is
  involved (existing per-surface responsibility, unchanged).

### Consumers (five thin adapters)

| Surface | Keeps (presentation) | Gains |
|---|---|---|
| Phone `MarkdownBlocks` | `\n` line joins for manuscripts; inline-only AttributedString | lists, monospace fences, tables, styled quotes, breaks |
| `GuideMarkdownView` | `.full` inline path; grid tables (existing Task-14 views) | drops its own parser; heading strictness fix |
| `ResearchNotePreviewPane` | image resolution + NSImage render; `.full` inline | lists, fences, tables, quotes |
| `SyntaxHelpSheet` | curated-content styling | drops its own parser |
| `ProjectASTBuilder.parseProseBlocks` | `InlineParser` inline layer; `ProseNode` mapping; scene-break→`.sceneBreak` | drops its block loop; **EMISSION.md byte-stable is the gate** |

Publish mapping: `MarkdownBlock` → `ProseNode` (`heading`→`.heading` with
inline-parsed text; `paragraph`→`.paragraph` with existing soft-join + hard
break synthesis; `list`→`.list` with per-item inline parse; `fence`→
`.verbatim`; `blockquote`→`.blockquote` recursive; `thematicBreak`→
`.sceneBreak`; `table`/`soloImage` → degrade exactly as today, i.e. paragraph
text — tables are display-only grammar and publish's negative space records
that).

## Testing

1. **Parity corpus (the milestone's centerpiece):** a permanent MaughamCore
   test fixture built from the audit's inconsistency table; asserts
   `MarkdownBlockParser.parse` output per case, then per-surface adapter tests
   assert each surface consumes those blocks (segmentation identical
   everywhere by construction — the parser test IS the parity test; adapter
   tests pin presentation).
2. **Publish gate:** EMISSION.md byte-identical after the cutover (golden
   suite). Any diff = the cutover changed publish behavior = a bug in the
   shared parser or the mapping, not a regen.
3. **Guide corpus:** `GuideCorpusRenderabilityTest` re-pointed at the shared
   parser; every `docs/guide/*.md` construct claimed by a typed block.
4. Existing per-surface tests survive; expectations change only where the
   grammar deliberately improves a surface (each change comments its audit
   finding).
5. Suites: core + Mac + phone (MaughamCore change) + Release build before tag.

## Riders

- Test pins deferred from the expansion milestone: cross-code-span flanking
  (`*a `code` b*` emphasizes across the span — pin in InlineParserTests);
  `EXT/INT ROOM` space-form scene heading (core); double-held-blank and
  EOF-on-held-line exact output shapes (core + mapper).
- Delete dead `RenderFilter.restoreComments` (zero callers since E1).

## Phases

1. **Core parser** — TDD against the parity corpus; grammar rules above.
2. **Publish cutover** — `parseProseBlocks` → shared parser + `ProseNode`
   mapping under the EMISSION byte-stability gate.
3. **Display adapters** — phone, Guide, research, syntax sheet; per-surface
   presentation tests; delete the four local parsers.
4. **Parity test wiring + riders + docs** — inconsistency-table corpus made
   permanent; markdown-syntax.md updated where surfaces gained blocks
   (phone/research now render lists/fences/tables/quotes); registry row for
   the shared block parser; test pins; dead-code deletion.

## Risks

- **Publish behavior drift** — mitigated by the byte-stability gate; if a
  genuine grammar conflict surfaces between the shared rules and current
  publish output, STOP and surface it (the ledger decides, not the parser).
- **Phone rendering churn** — manuscripts gaining fence/list/table rendering
  changes what writers see on existing docs; the presentation is strictly
  better (was emphasis soup), and phone tests pin the new output. On-device
  smoke required.
- **SwiftUI type-check ceiling** — new block cases in view switches; extract
  subviews per the established pattern if the budget complains.
