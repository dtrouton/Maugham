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
| `build/body.tex` | the wrapper above — the only file the template `\input`s |
| `build/metadata.tex` | **the FIRST body's** block |

`build/metadata.tex` is what the template's `\InputIfFileExists{build/metadata}` reads before `\begin{document}`, so the title page, the running heads and hyperref's document properties are the **first** body's — a bilingual PDF is one book, titled in its source language. Each half's own block is re-input INSIDE its `MaughamBody` group, so a translated title applies to that half and is undone at its `\end{MaughamBody}`.

### `\input` paths and subdirectory templates

The wrapper's `\input` arguments are relative to the **primary template's own directory**, not to `build/body.tex` and not to the working directory — the same rule that makes an imprint template at `templates/special.tex` reach the shared preamble with `\input{../preamble}`. Maugham writes the matching prefix into the wrapper itself (`\input{../build/body.en}` for a template one directory down), so a template author only ever writes their own partials' paths.

## Recovery

Overwriting or clearing a style file moves the prior version to Maugham's trash (`.maugham/trash/`, 30-day sweep, undo via ⌘⌥Z). There is **no git** in this workflow; the trash is the recovery path. `build/body.<lang>.tex` (the PDF emitter's output for one language — `build/body.tex` is the wrapper over them), `build/body.xhtml`, and `build/compile.log` are readable via `read_publish_file` for diagnosing what the emitter and compiler produced.

## EPUB iteration — open-loop workflow

PDF output is **CLOSED-LOOP**: Claude edits `template.tex` or `preamble.tex`, runs a compile, and reads the result via `read_publication_page` — the rendered page image is returned directly. Claude can see what changed.

EPUB output is **OPEN-LOOP**: after each compile, `build/body.xhtml` contains the assembled structural XHTML (one `<section>` block per piece, readable via `read_publish_file build/body.xhtml`). However, this is NOT how a reading application will render the file — final appearance depends on the reader's CSS interpretation, its handling of embedded fonts, device defaults, and night-mode overrides. Claude cannot observe those rendering decisions.

EPUB iteration therefore works as follows:

1. Claude proposes a CSS change in `styles.css` (via `write_publish_file`) and compiles.
2. Denver loads the new `.epub` in his reading application of choice (e.g. Books, Calibre, Kindle).
3. Denver describes what he sees — spacing, font size, chapter breaks, etc.
4. Claude iterates based on Denver's description.

This is the accepted workflow for personal-use EPUB. Closing the loop (embedding a headless reader, capturing screenshots) is out of scope here.
