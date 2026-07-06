# Markdown syntax in Maugham

Maugham's prose mode renders a focused subset of Markdown — the constructs writers actually reach for in fiction, with a few additions (wiki links, task checkboxes) borrowed from notes-app conventions. The renderer keeps the source visible (iA Writer style): syntax markers like `**` stay in the text but render quietly while the surrounding word renders bold, so you can always see exactly what's on disk.

This page documents what Maugham recognizes. The underlying parser is `MarkdownTokenizer.swift` for editor styling; inline markup (bold/italic/strikethrough/etc.) is shared via `InlineEmphasisScanner`, consumed directly by the editor and through a thin adapter (`InlineParser.swift`) by publish, so editor and published output agree there. Block-level segmentation — where a list, fence, table, blockquote, or divider starts and ends — is shared too, via `MarkdownBlockParser` (MaughamCore): the phone Read tab, the in-app Guide (⌘?), research note previews, this syntax-help sheet, and publish all parse blocks through it, so those surfaces agree with each other on block boundaries even though the editor's live-typing styling pass and each surface's renderer remain separate.

## Block elements

### Headings

```
# Chapter title
## Section heading
### Sub-section
#### Smaller heading
##### Even smaller
###### Smallest
```

One to six leading `#` characters followed by a space and the heading text. Six levels are recognized; deeper nesting renders as plain text. A `#` **without** a following space (`#foo`) is not a heading — it renders as plain text, matching CommonMark's precedence rule (the in-app Help renderer is a documented exception; see below). Headings are styled with progressively smaller scale (1.6× body for `#`, 1.4× for `##`, 1.25× for `###`, 1.1× for the rest) and bold weight.

### Lists

```
- A bullet item
* Another bullet item
+ Yet another
1. A numbered item
2. The next one
```

Recognized markers: `-`, `*`, `+`, or `<digits>.` followed by a space. The marker renders in the syntax-punctuation color; the item text renders normally. Indented (nested) lists are not styled differently — they render with their leading whitespace preserved. `1)`-style ordered markers are **not** styled in the editor (see the omission list) — an asymmetry worth knowing: every read surface (phone Read tab, research preview, Guide, this syntax-help sheet, and publish — see "Read surfaces" below) accepts both the `.` and `)` delimiters.

### Task checkboxes

```
- [ ] Rewrite the meet-cute beat
- [x] Confirm timeline with director
```

A `- [ ]` or `- [x]` line is a clickable task: the checkbox renders as a real toggle, and clicking it flips `[ ]` ↔ `[x]` (with matching strikethrough on the body when checked). On first toggle, an invisible `<!--t-XXXXXX-->` anchor is appended after the line so Maugham can track the task across edits — the anchor is an HTML comment, so the file stays valid Markdown. Maugham also recognizes an inline form, `[[todo: ...]]` / `[[done: ...]]`, for dropping a task mid-paragraph without breaking prose flow.

### Blockquotes

```
> A quoted line.
```

The `>` marker renders in the syntax-punctuation color. A `>` **without** a following space is not recognized (a divergence from CommonMark, which doesn't require the space). Multi-line blockquotes work by prefixing each line with `>`; Maugham doesn't auto-continue a blockquote across line breaks, and only one level of nesting is supported.

### Horizontal rule / scene break

```
---
***
###
```

A line consisting of three or more `-` characters, or exactly three `*` or `#` characters (surrounding spaces allowed; the marker count must be exact for `*`/`#` but not for dashes), renders as a horizontal divider. `****`, `####`, or the underscore form `___` are **not** recognized as dividers. This matches publish's `isSceneBreakLine` rule exactly, so editor and PDF/EPUB agree on what counts as a break.

## Inline elements

### Bold

```
**bold text**
```

Wrapped in double asterisks. Asterisks render in the syntax-punctuation color; the text between them renders bold.

### Italic

```
*italic text*
```

Single asterisks around the text. Same visible-syntax treatment as bold. `***bold italic***` and nesting (`*a **b** a*`) both work, and emphasis is **paragraph-scoped**: an emphasis span may open on one line and close on a later line within the same blank-line-delimited paragraph or stanza — it never crosses a blank line.

### Strikethrough

```
~~struck text~~
```

Wrapped in double tildes (GFM syntax). Renders with a strikethrough line through the text; the `~~` markers render in the syntax-punctuation color. Prose only — Fountain doesn't support `~~` (`~` there is the lyric marker). Published PDF/EPUB and the phone reader both render real strikethrough too (LaTeX via the `soul` package's `\st`, XHTML via `<s>`, phone via swift-cmark's native GFM support).

### Escaping

```
\*not italic\*
\~not struck\~
```

A backslash before `*`, `~`, `_`, `` ` ``, or another `\` renders that character literally and consumes the backslash — the escaped delimiter can't open or close emphasis, strikethrough, or a code span. This works identically in the editor (backslash fades as syntax punctuation) and in every publish path (LaTeX/XHTML drop the backslash and print the literal character).

### Inline code

```
`monospace`
```

Wrapped in backticks. The text inside renders in the editor's monospace code color, slightly smaller than body. Only single-backtick spans are recognized — a run of two or more backticks (CommonMark's escape for code containing a literal backtick) is not supported.

### Links

```
[link text](https://example.com)
```

Inline links only: `[text](url)` styles with `text` in the link color and the URL in the syntax-punctuation color. Link **titles** (`[text](url "title")`), angle-bracket destinations (`<url>`), balanced parens inside the URL, reference-style links (`[text][id]` with a `[id]: url` definition), and autolinks (`<https://example.com>`) are **not supported** — none of that markup is recognized as a link; it renders as plain text.

### Wiki links

```
[[Document Title]]
```

A Maugham-specific addition. The bracketed title is matched against other documents in the project's manuscript binder (case-insensitive). When the title resolves, the link renders underlined and clicking it navigates to that document. When the title doesn't resolve, the link renders without underline (still styled, just no navigation).

Wiki links also propagate on rename: if you rename a document via the binder, every `[[Old Title]]` reference in other manuscript documents is rewritten to `[[New Title]]` automatically (milestone-2d).

## Smart typography

When typed in prose mode, certain ASCII sequences auto-transform as you type — the source text on disk gets the typographic character, not the ASCII shorthand:

| You type | You get |
|---|---|
| `--` | `—` (em dash) |
| `...` | `…` (ellipsis) |
| `"` (straight) | `"` or `"` (curly, context-aware) |
| `'` (straight) | `'` or `'` (curly, context-aware) |

These transforms are configurable per-project under **Project Settings → Typography**. They're enabled by default for prose; disabled by default for screenplay (Fountain stays ASCII).

## Read surfaces: lists, fenced code, tables, and quotes

Manuscript *editing* doesn't style lists, fences, tables, or blockquotes beyond the marker coloring above — the editor is a live-typing surface, not a renderer. But everywhere Maugham *displays* rendered content instead of raw source — the phone Read tab, research note previews, the in-app Guide (⌘?), this syntax-help sheet, and published PDF/EPUB — renders more, sharing one block-level grammar (`MarkdownBlockParser`, MaughamCore):

- **Ordered and unordered lists** render as real lists (flat, tight — no nested-list layout). Both `.`- and `)`-delimited ordered markers are accepted, even though the editor only styles the `.` form. **List numbers are always sequential from position, never the digits you typed**: none of these surfaces retain the source's written ordinal, so a list that resumes at `10.` after an interruption renders as `1.` on every read surface and in publish.
- **Fenced code** (` ``` `) renders as a monospaced block on the phone Read tab, research preview, Guide, and this sheet, and becomes a verbatim block in published output — no inline markup parsing inside it, no syntax highlighting. This guards against a fence's contents being mangled by the inline-emphasis pass; it is not full syntax-highlighted code-block support.
- **Tables** (GFM pipe syntax — a header row, a `---`/`:--`/`--:` delimiter row, then data rows) render as a real grid on the phone Read tab, research preview, Guide, and this sheet. **Publish is the exception**: a table degrades to literal pipe-and-dash text in PDF/EPUB output — table rendering wasn't extended to the publish path, and this is an intentional, pinned behavior, not a gap to fix.
- **Blockquotes** (`>`) render as a styled quote (indent + rule) on the phone Read tab, research preview, Guide, and in publish (LaTeX/XHTML quote environment). A blockquote nested inside another blockquote flattens to one level of quoted text on every read surface — none of them recurse into fully nested quote rendering.
- A hard line break can be written as two trailing spaces (works everywhere) or a trailing backslash (publish only).

## Not supported (deliberately)

The following CommonMark constructs render as plain text, or are not recognized as their CommonMark meaning, in Maugham:

- Tables get no editor styling — pipe syntax renders as plain text while typing (every read surface parses and grids them — see above — except publish, which prints tables as literal text)
- Setext headings (`Title\n=====` / `Title\n-----`) — `---` is claimed by the scene-break/horizontal-rule idiom instead; the precedence conflict is permanent.
- Indented (4-space) code blocks — a footgun for writers who indent for other reasons.
- Fenced code blocks get no editor syntax highlighting (inline backticks work; every read surface gets the monospace/verbatim treatment above, not syntax highlighting)
- Reference-style links (`[text][id]` with `[id]: url` definitions elsewhere), autolinks (`<url>`), and link titles
- HTML pass-through
- Entities (`&amp;` etc.) — never decoded
- Footnotes
- Strikethrough is prose-only, not implemented for Fountain (see above)
- Image embeds (`![alt](url)`) in the manuscript editor and in publish — these render as plain text; research note previews are the one surface that renders a note's own `./`-relative solo-image line as an actual image (the phone Read tab recognizes the same line but renders nothing for it — no image support there)
- `1)`-style ordered-list markers in the editor's styling (every read surface accepts them — see above)
- `>` blockquotes without a following space
- Multi-backtick code spans (`` ``code with a ` backtick`` ``)
- List numbers don't round-trip anywhere: every read surface and publish renumber sequentially from position, discarding the digits you actually typed (see "Read surfaces" above)
- CommonMark's punctuation-class emphasis flanking and "rule of 3" — Maugham's scanner uses whitespace-only flanking; an unbalanced or ambiguous run degrades to literal text rather than guessing
- Emphasis spanning a blank line — paragraph-scoped emphasis (above) still stops at the first blank line

These omissions keep the prose surface focused. If a fiction writer needs a feature on this list, file an issue.

## How to think about it

Maugham's prose mode treats Markdown syntax as a *light scaffolding* for typography, not as a full document format. The goal is that source files stay readable in any plain-text editor (Claude desktop, VS Code, `cat`) and the writer's intent — emphasis, headings, links — is preserved without locking the manuscript into a proprietary format.
