# Markdown syntax in Maugham

Maugham's prose mode renders a focused subset of Markdown — the constructs writers actually reach for in fiction, with a few additions (wiki links) borrowed from notes-app conventions. The renderer keeps the source visible (iA Writer style): syntax markers like `**` stay in the text but render quietly while the surrounding word renders bold, so you can always see exactly what's on disk.

This page documents what Maugham recognizes. The underlying parser is `MarkdownTokenizer.swift`.

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

One to six leading `#` characters followed by a space and the heading text. Six levels are recognized; deeper nesting renders as plain text. Headings are styled with progressively smaller scale (1.6× body for `#`, 1.4× for `##`, 1.25× for `###`, 1.1× for the rest) and bold weight.

### Lists

```
- A bullet item
* Another bullet item
+ Yet another
1. A numbered item
2. The next one
```

Recognized markers: `-`, `*`, `+`, or `<digits>.` followed by a space. The marker renders in the syntax-punctuation color; the item text renders normally. Indented (nested) lists are not styled differently — they render with their leading whitespace preserved.

### Blockquotes

```
> A quoted line.
```

The `>` marker renders in the syntax-punctuation color. Multi-line blockquotes work by prefixing each line with `>`; Maugham doesn't auto-continue a blockquote across line breaks.

### Horizontal rule

```
---
```

A line consisting of three or more `-` characters renders as a horizontal divider.

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

Single asterisks around the text. Same visible-syntax treatment as bold.

### Inline code

```
`monospace`
```

Wrapped in backticks. The text inside renders in the editor's monospace code color, slightly smaller than body.

### Links

```
[link text](https://example.com)
```

Standard CommonMark link syntax. The `link text` renders in the link color; the URL inside `(...)` renders in the syntax-punctuation color.

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

## Not supported (deliberately)

The following CommonMark constructs render as plain text in Maugham:

- Tables
- Fenced code blocks (```` ``` ````) — inline backticks work, but block-level code fences don't get special syntax highlighting
- Reference-style links (`[text][id]` with `[id]: url` definitions elsewhere)
- HTML pass-through
- Footnotes
- Task lists (`- [ ] todo`) — the `[ ]` renders as plain text
- Strikethrough (`~~text~~`)
- Image embeds (`![alt](url)`) — these render as plain text; images live in the Research browser, not inline

These omissions keep the prose surface focused. If a fiction writer needs a feature on this list, file an issue.

## How to think about it

Maugham's prose mode treats Markdown syntax as a *light scaffolding* for typography, not as a full document format. The goal is that source files stay readable in any plain-text editor (Claude desktop, VS Code, `cat`) and the writer's intent — emphasis, headings, links — is preserved without locking the manuscript into a proprietary format.
