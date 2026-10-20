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
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
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
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
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
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
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
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
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
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
Text with \emph{em}, \textbf{strong}, \_under\_, \texttt{code}.

\end{prose}
```

### Anchor-only paragraph

```
<!-- ¶ab12 -->
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
\end{prose}
```

### Bold italic

```
Both ***kinds*** now.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
Both \textbf{\emph{kinds}} now.

\end{prose}
```

### Strikethrough

```
Cut ~~this clause~~ entirely.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
Cut \st{this clause} entirely.

\end{prose}
```

### Escaped asterisk

```
A literal \*star\* here.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
A literal *star* here.

\end{prose}
```

### Underscore is literal in prose

```
snake_case stays flat.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
snake\_case stays flat.

\end{prose}
```

### List

```
- one
- two
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
\begin{itemize}
\item one
\item two
\end{itemize}
\end{prose}
```

### Fenced code block (mangle guard, not code support)

```
```
*not em*
`nor code`
```
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
*not em*\newline `nor code`

\end{prose}
```

## Fountain positive space — recognized patterns

### Scene heading with number

```
INT. HOUSE - DAY #4A#
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{screenplay}{Example}
\providecommand{\lyricline}[1]{\textit{#1}\par}
\providecommand{\centeredline}[1]{\begin{center}#1\end{center}}
\providecommand{\scenenumber}[1]{\hfill #1}
\providecommand{\screenplaytitleblock}[1]{\begin{center}\vspace*{1.5in}#1\end{center}\clearpage}
\scene{INT. HOUSE - DAY\scenenumber{4A}}
\end{screenplay}
```

### Dual dialogue

```
ALICE
Hello.

BOB ^
Hi.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{screenplay}{Example}
\providecommand{\lyricline}[1]{\textit{#1}\par}
\providecommand{\centeredline}[1]{\begin{center}#1\end{center}}
\providecommand{\scenenumber}[1]{\hfill #1}
\providecommand{\screenplaytitleblock}[1]{\begin{center}\vspace*{1.5in}#1\end{center}\clearpage}
\dualdialogue{%
\character{ALICE}
\dialogue{Hello.}
}{%
\character{BOB}
\dialogue{Hi.}
}
\end{screenplay}
```

### Lyric

```
~The moon is out
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{screenplay}{Example}
\providecommand{\lyricline}[1]{\textit{#1}\par}
\providecommand{\centeredline}[1]{\begin{center}#1\end{center}}
\providecommand{\scenenumber}[1]{\hfill #1}
\providecommand{\screenplaytitleblock}[1]{\begin{center}\vspace*{1.5in}#1\end{center}\clearpage}
\lyricline{The moon is out}
\end{screenplay}
```

### Centered

```
> THE END <
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{screenplay}{Example}
\providecommand{\lyricline}[1]{\textit{#1}\par}
\providecommand{\centeredline}[1]{\begin{center}#1\end{center}}
\providecommand{\scenenumber}[1]{\hfill #1}
\providecommand{\screenplaytitleblock}[1]{\begin{center}\vspace*{1.5in}#1\end{center}\clearpage}
\centeredline{THE END}
\end{screenplay}
```

### Page break (===)

```
===
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{screenplay}{Example}
\providecommand{\lyricline}[1]{\textit{#1}\par}
\providecommand{\centeredline}[1]{\begin{center}#1\end{center}}
\providecommand{\scenenumber}[1]{\hfill #1}
\providecommand{\screenplaytitleblock}[1]{\begin{center}\vspace*{1.5in}#1\end{center}\clearpage}
\clearpage
\end{screenplay}
```

### Boneyard omitted

```
/* gone */

Kept.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{screenplay}{Example}
\providecommand{\lyricline}[1]{\textit{#1}\par}
\providecommand{\centeredline}[1]{\begin{center}#1\end{center}}
\providecommand{\scenenumber}[1]{\hfill #1}
\providecommand{\screenplaytitleblock}[1]{\begin{center}\vspace*{1.5in}#1\end{center}\clearpage}
\action{Kept.}
\end{screenplay}
```

### Note omitted

```
Before [[skip me]] after.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{screenplay}{Example}
\providecommand{\lyricline}[1]{\textit{#1}\par}
\providecommand{\centeredline}[1]{\begin{center}#1\end{center}}
\providecommand{\scenenumber}[1]{\hfill #1}
\providecommand{\screenplaytitleblock}[1]{\begin{center}\vspace*{1.5in}#1\end{center}\clearpage}
\action{Before after.}
\end{screenplay}
```

### Title page (F6: emits via \screenplaytitleblock)

```
Title: The Play
Author: A. Writer

INT. HOUSE - DAY

Action.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{screenplay}{Example}
\providecommand{\lyricline}[1]{\textit{#1}\par}
\providecommand{\centeredline}[1]{\begin{center}#1\end{center}}
\providecommand{\scenenumber}[1]{\hfill #1}
\providecommand{\screenplaytitleblock}[1]{\begin{center}\vspace*{1.5in}#1\end{center}\clearpage}
\screenplaytitleblock{{\Large\textbf{The Play}}\par
\vspace{1.5em}
A. Writer\par}
\scene{INT. HOUSE - DAY}
\action{Action.}
\end{screenplay}
```

## Report elements — positive space

Tables, figures, footnotes, citations, cross-references and numbered headings are emitted from the **whole book's resolution**: before any body is written, a resolution pass walks every piece of the book — never only the pieces a preview renders — and numbers, resolves and checks. The emitter reads its numbers and never counts on its own, so a preview of chapter 3 still prints "Figure 7" and a reference into an excluded chapter still resolves.

The examples below run that real resolution pass, then the real emitter, over a fixed one-piece book: one research item cited as `smith2026` ("Smith, Jane", *Annual Report*, 2026), section numbering on, the lists of figures and tables off. The examples have no project on disk, so the figure example hands the emitter its staged name directly; a real compile stages the image under `build/figures/` with a 16-hex-digit content hash for a name (`0123456789abcdef` below stands in for it).

### Captioned table

```
| Region | Sales |
|:--|--:|
| North | 120 |
Table: Sales by region {#tbl:sales}
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\ifdefined\MaughamTable\else\ifdefined\longtable
\newenvironment{MaughamTable}[4]{\begin{longtable}{#1}\caption[{#2}]{#3}\\#4\\\hline\endfirsthead\caption[]{#3}\\#4\\\hline\endhead}{\end{longtable}}
\else
\newenvironment{MaughamTable}[4]{\begin{table}[htbp]\centering\caption[{#2}]{#3}\begin{tabular}{#1}#4\\\hline}{\end{tabular}\end{table}}
\fi\fi
\begin{prose}{Example}
\setcounter{table}{0}
\hypertarget{lbl-tbl-sales}{}
\begin{MaughamTable}{lr}{Sales by region}{Sales by region}{Region & Sales}
North & 120 \\
\end{MaughamTable}
\end{prose}
```

### Figure (image staged under build/figures/)

```
![The study area](../research/map.png){#fig:map}
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
\setcounter{figure}{0}
\begin{figure}[htbp]
\centering
\hypertarget{lbl-fig-map}{}
\ifdefined\includegraphics\includegraphics[width=\linewidth]{build/figures/0123456789abcdef.png}\else\fbox{\parbox{0.9\linewidth}{\centering The study area}}\fi
\caption[{The study area}]{The study area}
\end{figure}
\end{prose}
```

### Footnote

```
A claim.[^1]

[^1]: Where the claim comes from.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
A claim.\footnote[1]{Where the claim comes from.}

\end{prose}
```

### Citation (author–date) and References

```
As reported [@smith2026, p. 12].
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
As reported (Smith 2026, p. 12).

\end{prose}
\clearpage
\section*{References}
\addcontentsline{toc}{section}{References}
\begingroup
\setlength{\parindent}{0pt}
\setlength{\parskip}{0.5em}
\hangindent=1.5em\hangafter=1 Smith, Jane. 2026. \emph{Annual Report}.\par
\endgroup
```

### Numbered heading and a cross-reference to it

```
## Method {#sec:method}

As @sec:method describes.
```

emits:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
\begin{prose}{Example}
\hypertarget{lbl-sec-method}{}
\subsection*{1\quad Method}
\addcontentsline{toc}{subsection}{1\quad Method}
As \MaughamCrossLink{lbl-sec-method}{Section 1} describes.

\end{prose}
```

## Report elements — the contract

### `MaughamTable`

Every table is a `MaughamTable` environment with four arguments: the column spec (`l`/`c`/`r` from the delimiter row), the list-of-tables entry, the caption, and the header row. A body that has a table opens with a guarded definition of it; a template that defines its own `MaughamTable` wins:

```latex
\ifdefined\MaughamTable\else\ifdefined\longtable
  … a longtable: the caption on the first page, the header repeated on every page …
\else
  … a table float around a plain tabular …
\fi\fi
```

Every table prints "Table n", captioned or not, so a reference to it always lands on a visible number; an uncaptioned table's list entry is `\relax`. A row opening with `[` or `*` starts with `\relax`, so `\\` never reads it as an argument.

### Old templates degrade, they don't fail

An existing project never receives starter updates, so its preamble may load neither graphicx nor longtable. Each element asks at the point of use:

- **No longtable** → `MaughamTable` becomes a `table` float around a plain `tabular` (one page; the header is not repeated).
- **No graphicx** → a figure keeps its float and caption, and its image becomes its caption in a framed box: `\ifdefined\includegraphics\includegraphics[width=\linewidth]{…}\else\fbox{\parbox{0.9\linewidth}{\centering …}}\fi`.
- **No `\listoffigures`/`\listoftables`** → the list is skipped (`\ifdefined\listoffigures\listoffigures\clearpage\fi`).

### The metadata preamble additions

`build/metadata.tex` is read in the **preamble** (the template's `\InputIfFileExists{build/metadata}`), the one place a `\usepackage` can still reach a preamble that predates these elements. For a book with a figure it adds `\IfFileExists{graphicx.sty}{\usepackage{graphicx}}{}`; for a book with a table, `\IfFileExists{longtable.sty}{\usepackage{longtable}}{}`. A book with neither gets exactly the metadata block it always got. A redesigned template that never inputs `build/metadata` falls back to the degradations above.

### Figures are staged

A figure's image must sit inside a research folder of the project; the path is written relative to the piece's own file. The PDF compile copies it to `build/figures/<content-hash>.<ext>` (PNG, JPEG or PDF) and `\includegraphics` reads that copy, so no project path — spaces and all — ever reaches TeX. The EPUB copies it to `OEBPS/images/` (PNG, JPEG, GIF or SVG). The counter is set before each `\caption` (`\setcounter{figure}{n-1}`, likewise `table`), so the resolution's number prints in any subset.

### Label anchors — `lbl-<kind>-<name>`

An element carrying `{#fig:map}`, `{#tbl:sales}` or `{#sec:method}` gets `\hypertarget{lbl-fig-map}{}` in LaTeX and `id="lbl-fig-map"` in XHTML. In a multi-body book every body carries the same labels, so the anchor names its body: `lbl-<tag>-<kind>-<name>` (`lbl-sr-fig-map`), and each body's references link within that body. A cross-reference is `\MaughamCrossLink{<anchor>}{<text>}` — the same command, and the same fallback, as a cross-body slugline link — reading "Figure n", "Table n", "Section 1.2", or the heading's own text when section numbering is off.

### Footnotes — `\footnote[n]`

Footnotes are numbered continuously across the book, and the PDF prints the resolution's number explicitly (`\footnote[n]{…}`), so the PDF and the EPUB agree even for a note inside a note. A second reference to the same note in a piece is `\footnotemark[n]`. Where `\footnote` is lost or breaks the compile — a caption, a table cell, a heading, a note's own text — the reference is `\footnotemark[n]` and its `\footnotetext[n]{…}` follows the construct. A footnote label belongs to its piece: `[^1]` in two chapters is two notes.

### Numbered headings

With section numbering on, headings are numbered by level across the book, relative to the shallowest heading level the book uses: a book whose sections are `##` reads 1, 2, never 0.1. Three levels are numbered; deeper ones are not. Headings stay starred (`\section*`) with the number printed in the text, because LaTeX's own counter cannot see the whole book. Piece titles are never numbered.

### References and the lists

In a book that cites anything, each body closes with one unnumbered **References** section (`\section*{References}`, added to the contents), listing the book's cited sources only, sorted by in-text name, then year, then title. The lists of figures and tables, when their switches are on and the book has such an element, open the **first** body; a later body of a multi-body book keeps its captions but stays out of the lists.

### Keep figure and table numbering flat

Maugham numbers figures and tables 1, 2, 3 across the whole book, and a cross-reference reads "Figure 3". A template on a chapter-numbered class (`book` or `report` with a numbered `\chapter`) prints `\thefigure` as "2.3", so the caption and the reference would disagree. A designer must keep `\thefigure` and `\thetable` flat (e.g. `\renewcommand{\thefigure}{\arabic{figure}}`).

### Unresolved means literal

An element the resolution could not resolve — an unknown citation key, a reference to a missing label, a footnote with no definition, an image that was refused or could not be staged — renders as its literal source, never "??". Each is also reported as a publish problem naming its paragraph; in a Report the error kinds refuse a versioned compile and a republish.

## Negative space — patterns the emitter does NOT give special meaning

Anything not listed under "positive space" passes through as its constituent text/inline nodes. Specifically, and from real use:

- A line beginning with `:` (e.g. `: foo`) → literal paragraph text. No definition-list semantics.
- `:*emphasis*` → a literal colon then `\emph{emphasis}`. No marker semantics.
- `**Context: 0%**` → `\textbf{Context: 0\%}`. There is no progress-meter or status rendering — it is ordinary bold text.
- Catch-all: any other punctuation, sigil, or convention not documented under a "positive space" section above (prose, Fountain or report elements) carries no special meaning and renders as its literal text.

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

**Scoping, verified by compile probe** (bundled tectonic 0.15.0, LaTeX kernel 2021-11-15; pinned by `StarterTemplateDefectProbeTests`): command renewals made at style-file scope — `\renewcommand`, `\RenewDocumentCommand`, `\DeclareRobustCommand`, including renewals of robust kernel commands like `\textbf` — revert at the `\endgroup` and cannot restyle later pieces. What DOES escape the group: `\global`-prefixed definitions (never use them in a style file) and counter changes (`\setcounter`/`\addtocounter` — LaTeX counters are global).

**xparse declarations are global, unlike renewals.** `\NewDocumentCommand`, `\NewDocumentEnvironment`, and the wider xparse `\Declare…`/`\New…` family are *new-name* declarations, not renewals of an existing command — they take effect globally and **cross piece boundaries**, even when declared inside a style file's `\begingroup`/`\endgroup`. This is a different animal from the *renewal* scoping documented above (`\renewcommand`, `\RenewDocumentCommand`, `\DeclareRobustCommand` of an already-existing name correctly revert at `\endgroup`). Introducing a brand-new command from a per-piece style file risks a name collision that clobbers or shadows a later piece; declare shared vocabulary in `preamble.tex` instead, where its global lifetime is expected.

**Active-catcode tricks destabilize hyperref (field-verified).** Avoid `\catcode`-based active-character tricks in style files (e.g. making a character active via `\catcode\`X=\active`). hyperref's bookmark/anchor machinery re-scans the token stream across multiple passes, and active catcodes introduced mid-document destabilize that machinery in ways that are hard to predict or debug. Use source-level constructs — an ordinary macro invoked where you need the effect — instead of catcode reassignment.

**Required pattern for restyling a heading or a kernel command.** Do NOT renew a kernel command (`\textbf`, `\emph`, `\scene`, …) at style-file top level to restyle a piece's headings. Put the renewal **inside the `\pieceheading` hook** (or the piece environment's own body) so it is scoped to where it fires — e.g. `\renewcommand{\pieceheading}[1]{{\bfseries\Large #1}\addcontentsline{toc}{section}{#1}}`. This is a **MUST**, not a preference, and it is what the Playlist templates use. Reason: a real six-piece field compile once had a piece-2 style file renew `\textbf` to a `\marginpar{...}` at style-file top level and the restyle bled into a piece **two sections later** (a fountain title block and its scene headings), even though a solo compile was correct and `begingroup`/`endgroup` counts in `body.tex` balanced. The isolated compile-probe reproduction of that exact shape does **not** leak under the bundled tectonic (the renewal reverts at `\endgroup` as documented above), so the field mechanism is **unexplained** — the leading unproven suspect is fontspec's lazy bold/em family setup interacting with the deferred `\marginpar` output routine. Because the field failure was real and its trigger is not understood, the hook-scoped pattern is mandatory: it is immune to the failure regardless of the mechanism, so top-level kernel-command renewals in style files are unsupported and may restyle unrelated pieces.

**`\screenplaytitleblock` (F6).** The fountain title block emits via `\screenplaytitleblock{body}` (one argument: all title-page fields in declared order), `\providecommand`-declared per fountain section alongside `\lyricline`/`\centeredline`/`\scenenumber` (default reproduces the classic centered title-page layout byte-for-byte). It is a sanctioned restyle hook, same class as `\pieceheading` above — a dedicated per-purpose command, not a shared kernel one — so restyle it directly rather than reaching into kernel commands to fake the effect.

**Imprint templates are not style files.** An imprint's own template (spec 2026-08-27 §3) is a full template — a peer of the book's `template.tex`, not a per-piece hook — so the prohibitions above (`\usepackage` only in the preamble, no `\geometry` change) do **not** apply to it: an imprint template may load its own packages and set its own page geometry, exactly as `template.tex` may. Two facts to build one against: tectonic's `--outdir` is **flat** and names its output by the template's own **basename**, which is why an imprint's template basename (language suffix stripped) must differ from the book's and from every other imprint's; and tectonic resolves `\input` **relative to the template's own directory**, so a template at `templates/special.tex` reaches the shared preamble with `\input{../preamble}`, not `\input{preamble}`.

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

## Language editions — template variants (F4)

The resolver auto-picks `template.<lang>.tex` and per-piece `<piece>.<lang>.tex` when compiling with a `language`, falling back to the base file when a variant is absent. That resolution covers **only** those two file kinds — it does not follow `\input` lines inside them to auto-resolve arbitrary partials. This is deliberate: a project may `\input` shared macros that must **not** vary by language, and auto-resolving every `\input` would silently make them vary.

If your template inputs partials (`preamble.tex`, `frontmatter.tex`, `backmatter.tex`, or similar), the language edition needs its own `template.<lang>.tex` whose `\input` lines point at language variants of those partials; the resolver picks the template variant, and everything else follows from it. A `frontmatter.<lang>.tex` sitting next to the base file does nothing on its own — nothing errors, the base file just keeps rendering — until a `template.<lang>.tex` `\input`s it.

## Multi-language bodies — the `MaughamBody` environment

A compile renders **one complete body per language, in order**. `build/body.tex` is not the book any more — it is a WRAPPER:

```latex
\ifdefined\MaughamBody\else\newenvironment{MaughamBody}[1]{\clearpage}{}\fi
\begin{MaughamBody}{en}\input{build/metadata.en}\input{build/body.en}\end{MaughamBody}
\begin{MaughamBody}{sr}\input{build/metadata.sr}\input{build/body.sr}\end{MaughamBody}
```

One `MaughamBody` line per rendered language, in the order the compile asked for them; a single-language compile emits exactly one. The environment takes **one argument, the language tag**, so a template can tell the halves apart.

**The guard line is emitted, not assumed.** An existing project never receives starter updates, so its `preamble.tex` may have never heard of `MaughamBody`; the `\ifdefined` supplies a default (`\clearpage` — each half starts on a fresh page, nothing else changes) without overriding a template that defines its own. The starter `preamble.tex` now ships the same guarded definition.

**To give each half its own title page**, redefine the environment and key the frontmatter on `#1`:

```latex
\renewenvironment{MaughamBody}[1]{\clearpage\input{frontmatter-#1}}{}
```

### Where the files are

| File | What it is |
|---|---|
| `build/body.<tag>.tex` | one language's complete emitted body |
| `build/metadata.<tag>.tex` | that language's `\renewcommand` metadata block |
| `build/body.tex` | the wrapper above — the only BODY file the template inputs (it also `\InputIfFileExists{build/metadata}`) |
| `build/metadata.tex` | **the FIRST body's** block |

`build/metadata.tex` is what the template's `\InputIfFileExists{build/metadata}` reads before `\begin{document}`, so the title page, the running heads and hyperref's document properties are the **first** body's — a bilingual PDF is one book, titled in its source language. Each half's own block is re-input INSIDE its `MaughamBody` group, so a translated title applies to that half and is undone at its `\end{MaughamBody}`.

### `\input` paths and subdirectory templates

The wrapper's `\input` arguments are relative to the **primary template's own directory**, not to `build/body.tex` and not to the working directory — the same rule that makes an imprint template at `templates/special.tex` reach the shared preamble with `\input{../preamble}`. Maugham writes the matching prefix into the wrapper itself (`\input{../build/body.en}` for a template one directory down), so a template author only ever writes their own partials' paths.

## Paragraph anchors — `p-<tag>-<¶id>`

Every node a paragraph in the op log produced carries that paragraph's `¶id` into **both** artifacts. This is the first artifact-side id a template can rely on: before it, nothing in a compiled PDF or EPUB could be addressed back to a paragraph.

The name is `p-<tag>-<¶id>`:

| Part | What it is |
|---|---|
| `<tag>` | the compiler's filename-safe **body tag** — the body's language tag (`en`, `sr`), or its ordinal when that tag cannot be a filename. It is what tells the halves of a bilingual book apart: the same paragraph id appears once per body. |
| `<¶id>` | the op log's own 4-character id, drawn from `0-9a-hjkmnp-tv-z`. Safe both as a LaTeX argument and as an XML `id`. |

**LaTeX** — a `\hypertarget` on its OWN line, immediately BEFORE the node's first line:

```latex
\hypertarget{p-en-k3wq}{}
The paragraph's text, escaped.

```

The second argument is empty on purpose: a target marks a position, it typesets nothing. Never place it AFTER the text — a prose paragraph's own blank line (its `\par`) follows the text, and an anchor between the two would split the paragraph in half.

**XHTML** — `id="p-en-k3wq"` on the node's FIRST element:

```html
<p id="p-en-k3wq">The paragraph's text.</p>
```

**Anchors are sparse.** A paragraph anchors only the first node it produced, so a cue-and-speech block (one paragraph, three fountain nodes) contributes one anchor, and a node whose paragraph could not be identified contributes none. A source that hands no paragraphs at all emits no anchors and is byte-identical to what it emitted before anchors existed.

## Cross-body links — `\MaughamCrossLink`

In a multi-language compile every **slugline** links to the same slugline in each of the other bodies, so a reader of a bilingual screenplay can jump from a scene to its translation. Only sluglines link; every other node still anchors, so a link has somewhere to land.

**LaTeX** — the link WRAPS the mode command and is never wrapped by it. The starter's `\scene` applies `\MakeUppercase` to its argument, which would uppercase (and so break) a target passed inside it:

```latex
\MaughamCrossLink{p-sr-k3wq}{\scene{INT. ROOM - DAY}}
```

With more than one other body the wraps NEST, first other body outermost:

```latex
\MaughamCrossLink{p-sr-k3wq}{\MaughamCrossLink{p-de-k3wq}{\scene{INT. ROOM - DAY}}}
```

`\MaughamCrossLink{target}{content}` takes the anchor name and the content. The starter `preamble.tex` defines it as

```latex
\providecommand{\MaughamCrossLink}[2]{\hyperlink{#1}{#2}}
```

A template is free to define it as something else — a coloured link, a marginal marker, or nothing at all. Whatever it defines wins, because both definitions are `\providecommand` and the preamble is read first.

A single-language compile passes no other bodies and emits neither form — a plain `\scene`.

**XHTML** — an `<a>` around the slugline pointing at the first other body's section file, with a sibling marker link per further body:

```html
<a href="section-sr-002.xhtml#p-sr-k3wq">INT. ROOM - DAY</a>
```

### The prologue is one contract

Every body opens with the same three lines — anchored or not, single-language or not:

```latex
\providecommand{\st}[1]{#1}
\providecommand{\hypertarget}[2]{#2}
\providecommand{\MaughamCrossLink}[2]{\ifdefined\hyperlink\hyperlink{#1}{#2}\else#2\fi}
```

They are unconditional so the emitted contract is one shape rather than four, and each degrades to its content: no `soul` and `\st` sets plainly, no `hyperref` and `\hypertarget{name}{}` sets nothing at all. `\providecommand` in the preamble AND in the body is what lets the preamble's definition win: it is read first, and the body's then no-ops. An existing project never receives starter updates, so this is the only thing standing between a `preamble.tex` written before cross-links existed and a failed compile.

**The cross-link fallback links rather than degrading whenever it can.** Its `\ifdefined\hyperlink` test is decided at each use, not at load time, so a project whose preamble loads `hyperref` — every project the starter ever installed — gets working links from the body alone, with no `\MaughamCrossLink` definition of its own. Only a preamble without hyperref sets the slugline un-linked. A template that defines the command still wins over both.

## Recovery

Overwriting or clearing a style file moves the prior version to the project's trash folder (`.trash/` at the project root, swept after 30 days). It is Maugham's own safety copy, so it stays out of the Trash pane and Restore Last Deletion; recover it from that folder. There is **no git** in this workflow; the trash is the recovery path. `build/body.<lang>.tex` (the PDF emitter's output for one language — `build/body.tex` is the wrapper over them), `build/body.xhtml`, and `build/compile.log` are readable via `read_publish_file` for diagnosing what the emitter and compiler produced.

## EPUB iteration — open-loop workflow

PDF output is **CLOSED-LOOP**: Claude edits `template.tex` or `preamble.tex`, runs a compile, and reads the result via `read_publication_page` — the rendered page image is returned directly. Claude can see what changed.

EPUB output is **OPEN-LOOP**: after each compile, `build/body.xhtml` contains the assembled structural XHTML (one `<section>` block per piece, readable via `read_publish_file build/body.xhtml`). However, this is NOT how a reading application will render the file — final appearance depends on the reader's CSS interpretation, its handling of embedded fonts, device defaults, and night-mode overrides. Claude cannot observe those rendering decisions.

EPUB iteration therefore works as follows:

1. Claude proposes a CSS change in `styles.css` (via `write_publish_file`) and compiles.
2. Denver loads the new `.epub` in his reading application of choice (e.g. Books, Calibre, Kindle).
3. Denver describes what he sees — spacing, font size, chapter breaks, etc.
4. Claude iterates based on Denver's description.

This is the accepted workflow for personal-use EPUB. Closing the loop (embedding a headless reader, capturing screenshots) is out of scope here.
