# EMISSION.md — Body Emission Contract

_Generated from `EmissionContract.swift`. Do not hand-edit; edit the Swift source and regenerate (the test enforces the match)._

This is the authoritative description of what the LaTeX body emitter produces for each source pattern. The positive-space examples below are rendered by calling the real emitter, so they always reflect reality.

## Where does a typographic move live? The locality criterion

> Does honoring this override require **global** knowledge the piece cannot have on its own? **Global → config. Local → template (per-piece `.tex`).**

| Override | Lives in | Why |
| --- | --- | --- |
| `start_on` (recto/verso) | config | needs global page state |
| `include_in_toc` | config | needs global ToC state |
| `title_override` | config | a declaration, not typography |
| Numbering visibility | template (per-piece `.tex`) | local to the piece |
| Final-line isolation | template (per-piece `.tex`) | local to the piece |
| Drop caps | template (per-piece `.tex`) | local to the piece |
| Ornaments | template (per-piece `.tex`) | local to the piece |

## Positive space — recognized patterns

### Paragraph

```
A plain sentence.
```

emits:

```latex
\begin{prose}{Example}
A plain sentence.

\end{prose}
```

### Heading level 1

```
# Chapter Title
```

emits:

```latex
\begin{prose}{Example}
\section*{Chapter Title}
\addcontentsline{toc}{section}{Chapter Title}
\end{prose}
```

### Blockquote with emphasis

```
> A quote with *italic* inside.
```

emits:

```latex
\begin{prose}{Example}
\begin{quote}
A quote with \emph{italic} inside.

\end{quote}
\end{prose}
```

### Scene break

```
***
```

emits:

```latex
\begin{prose}{Example}
\scenebreak
\end{prose}
```

### Inline mix

```
Text with *em*, **strong**, _under_, `code`.
```

emits:

```latex
\begin{prose}{Example}
Text with \emph{em}, \textbf{strong}, \emph{under}, \texttt{code}.

\end{prose}
```

### Anchor-only paragraph

```
<!-- ¶ab12 -->
```

emits:

```latex
\begin{prose}{Example}
\end{prose}
```

## Negative space — patterns the emitter does NOT give special meaning

Anything not listed under "positive space" passes through as its constituent text/inline nodes. Specifically, and from real use:

- A line beginning with `:` (e.g. `: foo`) → literal paragraph text. No definition-list semantics.
- `:*emphasis*` → a literal colon then `\emph{emphasis}`. No marker semantics.
- `**Context: 0%**` → `\textbf{Context: 0\%}`. There is no progress-meter or status rendering — it is ordinary bold text.
- Catch-all: any other punctuation, sigil, or convention not documented under "positive space" carries no special meaning and renders as its literal text.

If you need any of these to render specially, that's a per-piece `.tex` hook.

## Per-piece style files (`style_file`)

Set via `set_piece_style`. Sourced inside a TeX group, **before** the piece's environment opens:

```latex
\begingroup
  \input{pieces/<file>}      % runs here, at source time
  \begin{prose}{Title} ... \end{prose}
\endgroup
```

A per-piece file **MAY**: `\renewcommand`, `\newcommand`, `\definecolor`, `\renewenvironment`, and emit arbitrary body LaTeX at file top (e.g. a per-piece **title page** — put it before any `\renewcommand`).

A per-piece file **MAY NOT**: `\usepackage` (packages load only in the preamble) or change `\geometry` (page geometry is preamble-level and does not revert at `\endgroup`). These are collection-level — edit `preamble.tex`.

## Fonts

Custom body fonts compile deterministically under the bundled tectonic (XeTeX engine + fontspec package).

**To use a custom font:**

1. Drop the `.otf` or `.ttf` file into `.maugham/publish/fonts/` via `write_publish_file` (base64-encode the bytes; the tool writes it at the path you specify under `build/` — place it as `build/fonts/<filename>`).
2. Enable it in `preamble.tex` (collection-level; this is an aesthetic global, not a per-piece override — per the locality criterion, fonts belong in the preamble, never in config):
   ```latex
   \usepackage{fontspec}
   \setmainfont[Path=fonts/]{YourFont-Regular.otf}
   ```
3. **Remove or comment out `\usepackage[utf8]{inputenc}`** on the line above. `inputenc` is incompatible with `fontspec` under XeTeX — leaving both active will cause a compilation error.

The starter `preamble.tex` ships with a commented-out fontspec block that includes this reminder. Uncomment it and set your filename; the `inputenc` removal is the only other required change.

## Recovery

Overwriting or clearing a style file moves the prior version to Maugham's trash (`.maugham/trash/`, 30-day sweep, undo via ⌘⌥Z). There is **no git** in this workflow; the trash is the recovery path. `build/body.tex`, `build/body.xhtml`, and `build/compile.log` are readable via `read_publish_file` for diagnosing what the emitter and compiler produced.

## EPUB iteration — open-loop workflow

PDF output is **CLOSED-LOOP**: Claude edits `template.tex` or `preamble.tex`, runs a compile, and reads the result via `read_publication_page` — the rendered page image is returned directly. Claude can see what changed.

EPUB output is **OPEN-LOOP**: after each compile, `build/body.xhtml` contains the assembled structural XHTML (one `<section>` block per piece, readable via `read_publish_file build/body.xhtml`). However, this is NOT how a reading application will render the file — final appearance depends on the reader's CSS interpretation, its handling of embedded fonts, device defaults, and night-mode overrides. Claude cannot observe those rendering decisions.

EPUB iteration therefore works as follows:

1. Claude proposes a CSS change in `styles.css` (via `write_publish_file`) and compiles.
2. Denver loads the new `.epub` in his reading application of choice (e.g. Books, Calibre, Kindle).
3. Denver describes what he sees — spacing, font size, chapter breaks, etc.
4. Claude iterates based on Denver's description.

This is the accepted workflow for personal-use EPUB. Closing the loop (embedding a headless reader, capturing screenshots) is out of scope here.
