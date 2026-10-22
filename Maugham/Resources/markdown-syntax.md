# Markdown syntax in Maugham

Prose in Maugham is written in Markdown: plain text with a few light marks for headings, emphasis, links and lists. Maugham supports the marks fiction writers actually reach for, plus two extras borrowed from notes apps (wiki links and task checkboxes).

The marks stay visible as you write. When you type `**bold**`, the asterisks stay in the text but fade into a quiet color while the word between them turns bold, so you always see exactly what's in your file.

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

Start a line with one to six `#` characters, then a space, then the heading. More `#` means a smaller heading. The space matters: `#foo` with no space is ordinary text, not a heading.

### Lists

```
- A bullet item
* Another bullet item
+ Yet another
1. A numbered item
2. The next one
```

Start a line with `-`, `*`, `+`, or a number and a period (`1.`), then a space. The marker shows in the quiet syntax color and the item reads as normal text. Indented (nested) items keep their indent but aren't styled differently.

### Task checkboxes

```
- [ ] Rewrite the meet-cute beat
- [x] Confirm timeline with director
```

A line starting `- [ ]` or `- [x]` becomes a clickable checkbox. Click it to tick or untick the task; a ticked task is struck through.

You can also drop a task into the middle of a paragraph without breaking the flow of your prose: write `[[todo: ...]]`, and it becomes `[[done: ...]]` when you tick it.

### Blockquotes

```
> A quoted line.
```

Start a line with `>` and a space. The space is required: `>quote` with no space stays ordinary text. For a quote that runs over several lines, start each line with `>`; Maugham doesn't carry the quote onto the next line for you.

### Scene breaks

```
---
***
###
```

A line of three or more dashes, or exactly three `*` or exactly three `#`, becomes a scene break (a horizontal divider). Spaces around the marks are fine. `****`, `####` and `___` are not scene breaks. What counts as a break while you write is exactly what counts as one in your published PDF or EPUB.

## Inline elements

### Bold

```
**bold text**
```

Wrap the text in double asterisks.

### Italic

```
*italic text*
```

Wrap the text in single asterisks. `***bold italic***` works, and so does italic with bold inside it (`*a **b** a*`). Emphasis can start on one line and finish on a later line of the same paragraph or stanza, but it stops at a blank line.

### Strikethrough

```
~~struck text~~
```

Wrap the text in double tildes. It shows struck through while you write, on the phone, and in published PDF and EPUB. Strikethrough is for prose only; screenplays use `~` for lyrics instead.

### Escaping

```
\*not italic\*
\~not struck\~
```

When you want a literal `*`, `~`, `_`, `` ` `` or `\`, put a backslash in front of it. The character then can't start or end emphasis, and the backslash itself is left out of published output.

### Inline code

```
`monospace`
```

Wrap the text in single backticks to show it in a monospace font. Only single backticks work; double-backtick spans aren't supported.

### Links

```
[link text](https://example.com)
```

Put the link text in square brackets and the web address in parentheses right after. Other link styles (link titles, `<https://...>` addresses, and links whose address is defined elsewhere in the file) aren't supported and stay as plain text.

### Wiki links

```
[[Document Title]]
```

Link to another document in your manuscript by putting its title in double square brackets (capitals don't matter). When the title matches a document, the link is underlined and clicking it takes you there. When nothing matches, the link has no underline and does nothing when clicked.

If you rename a document, Maugham updates the `[[Old Title]]` links in your other manuscript documents to the new title.

## Smart typography

As you type prose, Maugham swaps a few plain-keyboard characters for their proper typographic versions, and your file keeps the typographic character:

| You type | You get |
|---|---|
| `--` | `—` (em dash) |
| `...` | `…` (ellipsis) |
| `"` (straight) | `“` or `”` (curly, depending on position) |
| `'` (straight) | `‘` or `’` (curly, depending on position) |

You can turn each of these on or off in **Settings → Typography** (⌘,). They're on by default for prose. Screenplays never use them, so a script stays in plain characters.

## Lists, tables and quotes outside the editor

While you write, lists, tables, quotes and code blocks keep the light styling described above. Wherever Maugham shows your writing as a finished page — the phone's Read tab, research note previews, Maugham Help, this reference, and published PDF and EPUB — they get the full treatment:

- **Lists** show as proper lists (one level, no nesting). Numbered lists can use `1.` or `1)`, although the editor only colors the `1.` form. Numbers are always counted from the top of the list, so a list you start at `10.` shows as `1.`.
- **Code blocks**, fenced with three backticks, show in a monospace block exactly as written, with no bold or italic inside them.
- **Tables** (a header row, a row of dashes, then data rows, each column separated by `|`) show as a real grid. In published PDF, EPUB and Word they are real numbered tables ("Table 1"), captioned by a `Table:` line under them; see Publishing.
- **Quotes** show indented with a rule beside them. A quote inside a quote shows nested on the phone and in published output, and as a single level elsewhere.
- **Line breaks inside a paragraph**: end a line with two spaces to break it there. A backslash at the end of the line also works, but only in published output.

## Not supported

These are shown as plain text, or don't do what they would in other Markdown apps:

- Table styling while you write (tables read as plain text in the editor)
- Headings underlined with `===` or `---` on the next line (`---` is a scene break in Maugham)
- Code blocks made by indenting four spaces (so indenting your prose is always safe)
- Colored code highlighting inside code blocks
- Link titles, `<https://...>` links, and links defined elsewhere in the file
- HTML tags, and codes like `&amp;`
- Strikethrough in screenplays
- Footnotes and figures (`![caption](path)`) outside the editor and publishing: the phone's Read tab and previews show them as plain text, though a research note's preview does show an image that sits on a line of its own with a path starting `./`. How they publish is in Publishing.
- `1)` numbering styled in the editor (it works everywhere else, as above)
- `>` quotes without a space after the `>`
- Double-backtick code spans
- Keeping your own list numbers: lists are always renumbered from the top
- Emphasis that runs across a blank line. If the asterisks are unbalanced or ambiguous, they show as plain asterisks rather than Maugham guessing.

## How to think about it

In Maugham, Markdown is light scaffolding for typography, not a document format to wrestle with. Your files stay readable in any plain-text app, and your emphasis, headings and links come through without locking your manuscript into a proprietary format.
