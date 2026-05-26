# Fountain syntax in Maugham

Maugham's screenplay mode uses [Fountain](https://fountain.io) — a plain-text screenplay format readable by Final Draft, Highland, Slugline, FountainJS, and other screenwriting tools. This page documents what Maugham specifically recognizes and how it renders each element.

The underlying parser is `FountainTokenizer.swift`. The styling pipeline is `ScreenplayMode.applyTypography`. Layout follows the Cole & Haag standard (Hollywood spec): 60-character page width at 10cpi, scene heading bold, character cue at column 22, dialogue indented at column 10 with 35-char width, parenthetical at column 15 with 20-char width, transition right-aligned. Maugham's screenplay text container is fixed at 60 characters wide regardless of your prose-mode page-width setting. Dual-dialogue second blocks render with deeper indents to mark the simultaneous-speech pair visually.

## The basics

A Fountain screenplay is plain text. Each line is classified into an element by a small line-based parser that uses two pieces of context: whether the previous line was blank, and what element the previous line was. So **blank lines matter** — they're how the parser knows where one block ends and another begins.

```
INT. COFFEE SHOP - DAY

Two friends sit across from each other.

BARRY
(after a long pause)
You ever wonder if we made the right call?

SAM
Every damn day.
```

That parses cleanly into: scene heading, action, character + parenthetical + dialogue, character + dialogue. Blank lines separate the blocks; ALL CAPS lines preceded by a blank are treated as character cues.

## Title page

Fountain supports an optional **title page** at the very top of the file — a block of `Key: Value` pairs ending with a blank line. Maugham recognizes the standard keys and renders them with per-key styling above the screenplay body.

```
Title: The Long Goodbye
Credit: Written by
Author: Raymond Chandler
Source: Based on the novel
Draft date: 2026-05-26
Contact:
    Some Agency
    123 Sunset Blvd
    Los Angeles, CA
Notes: First draft
Copyright: © 2026

INT. OFFICE - NIGHT

Marlowe sits at his desk.
```

Recognized keys (case-insensitive): **Title**, **Credit**, **Author** (or **Authors**), **Source**, **Notes**, **Draft date**, **Contact**, **Copyright**.

For the title page to be recognized, **the first non-blank line of the file must match one of these keys**. Otherwise the document has no title page and parsing starts at the body. This strict gate prevents a stray `Foo: bar` opening line from accidentally swallowing your first scene.

**Multi-line values** are continuation-indented by **3 or more spaces, or a tab** (see the `Contact:` example above). A blank line ends the title page; the body begins immediately after.

## Elements

### Action

The default. Any line that doesn't match another rule is action and renders left-aligned at full width.

```
Two friends sit across from each other.
```

### Scene heading

A line preceded by a blank line and starting with `INT.`, `EXT.`, `EST.`, `I/E.`, or `INT/EXT.` (case-insensitive). Renders bold, left-aligned.

```
INT. KITCHEN - DAY
EXT. ROOFTOP - NIGHT
EST. MEADOW - DAWN
I/E. CAR - CONTINUOUS
INT/EXT. WAREHOUSE - DAWN
```

You can also force a scene heading with a leading `.` (single dot, not double):

```
.barbershop
```

A forced scene heading lets you write sluglines that don't start with the standard prefixes.

### Character

A line in **ALL CAPS** preceded by a blank line and followed by a non-blank line. Renders left-aligned, indented to column 22.

```
BARRY
Hello there.
```

You can force a character with a leading `@`:

```
@Sam
Hi.
```

The `@` lets you write character names with mixed case (e.g., `@McConnell`) when the writer wants the name preserved as-typed. Without `@`, only ALL CAPS lines are recognized as character cues. Currently Maugham renders forced character lines as-typed (option A — the visual-uppercase glyph substitution feature is deferred to a future milestone).

A character cue must be followed by a non-blank line. An ALL CAPS line followed by a blank line is treated as action — that catches "He yelled SOMETHING!" mid-paragraph from being misread as a character.

#### Character extensions

The all-caps rule is permissive about non-letter characters — periods, parentheses, digits, and spaces are all ignored. That means **character extensions** (V.O., O.S., O.C., CONT'D, etc.) work as plain Fountain without any special syntax:

```
MARLOWE (V.O.)
The city was hotter than a two-dollar pistol.

JANE (O.S.)
Did you say something?

BOB (CONT'D)
Where was I?
```

Maugham doesn't have a fixed list of extensions — anything that keeps the line all-caps-letters classifies as a character cue. Exotic conventions like `(FILTERED)` or `(ON RADIO)` work too.

**Note:** any lowercase letter anywhere on the line breaks the cue test. `Marlowe (V.O.)` becomes action. Force a lowercase-name cue with the `@` prefix (e.g. `@McTeague`).

### Dialogue

A non-blank line immediately following a Character or Parenthetical, until the next blank line. Renders left-aligned at column 10 with a 35-character wrap width.

```
BARRY
You ever wonder if we made the right call?
What if we'd just driven north that night?
```

Dialogue continues across multiple lines until a blank.

### Parenthetical

A line wrapped in `(...)` between a Character and Dialogue. Renders italic at column 15 with a 20-character wrap width.

```
BARRY
(after a long pause)
You ever wonder if we made the right call?
```

### Dual dialogue

For simultaneous speech — two characters talking at once, or interrupting each other — add a trailing `^` to the **second** character cue. The pair renders stacked in the editor, with the `^`-marked block offset visually to the right:

```
BRICK
Screw retirement.

STEVE ^
Screw retirement.
```

The `^` itself fades to dim, like other forced-syntax markers. Page count treats the pair as the height of the longer block (Final Draft semantics), not the sum — so a dual pair won't inflate your page count.

**Asymmetric layout.** Maugham renders dual dialogue as **stacked + visually offset** rather than true side-by-side columns. The first block sits at the normal cue position; the second block is pushed right. The on-disk `.fountain` file is standard Fountain — opens correctly in Highland, Slugline, FountainJS, and other tools that may render true columns. A future print/PDF export milestone may upgrade Maugham's on-screen layout to true columns too.

**Pairing.** Maugham pairs blocks two-at-a-time, greedily. A chain like `A`, `B^`, `C^` pairs (A,B) and leaves C standing alone. Multi-speaker chains are exotic; if you actually need them, file an issue.

### Transition

An ALL CAPS line preceded by a blank, ending in `TO:`, renders right-aligned and bold:

```
SMASH CUT TO:
FADE OUT:
DISSOLVE TO:
```

Or force a transition with a leading `>`:

```
> Cut to:
> Fade out.
```

### Centered text

Wrap a line in `>...<` to center it horizontally:

```
>THE END<
> A title card <
```

Useful for title cards, end credits, montage labels.

### Lyric

A line starting with `~` is a lyric (used for songs, poetry, chants). Renders italic.

```
~la la la
~Somewhere over the rainbow
```

### Sections

Structural markers using `#` (1 to 6 levels). Render bold + underlined. Sections aren't part of the screenplay per se — they're the writer's outline structure. They're not counted in the page count.

```
# ACT ONE
## Sequence A: The Setup
### Beat: Inciting incident
```

### Synopses

A line starting with `= ` (single equals + space) is a synopsis — a one-line beat description. Renders dim italic. Like sections, synopses are working-doc metadata and aren't counted in the page count.

```
= Sam confronts Barry about the lie.
```

### Page break

A line consisting of three or more `=` characters (and only `=`) is a page break.

```
===
```

### Boneyard (cut content)

Wrap content in `/* ... */` to mark it as cut from the script. Renders dim italic. Boneyard content can span multiple lines and is not counted in the page count.

```
/* This scene was cut for pacing.
   Keep it here in case we want it back. */
```

### Notes

Wrap content in `[[ ... ]]` to mark it as a note. Notes can be:

- **Block notes** (full line or multi-line):
  ```
  [[ todo: rewrite this beat ]]
  
  [[ check with director:
     should this be daytime or night? ]]
  ```

- **Inline notes** (within an action or other line):
  ```
  Action paragraph with a [[ side note ]] embedded inline.
  ```

Notes render dim italic. Inline notes get their `[[ ... ]]` range styled dim while the rest of the line keeps its parent element styling (action, dialogue, etc.). Notes don't count toward page count.

### Inline emphasis

Within any line, Maugham recognizes:

- `*italic*` — single asterisks around the run.
- `**bold**` — double asterisks around the run.
- `_underline_` — single underscores around the run.

```
She glances at the *worn* photograph, then **slams** the drawer shut.
The sign reads _Closed for inventory_.
```

Markers fade to dim while the inner text renders styled. Emphasis works inside action, dialogue, parenthetical — anywhere there's prose. It does **not** affect line classification (a `**ALL CAPS**` line is still classified by its bracketed content's case).

### Inline task anchors

Wrap a working note in `[[todo: ...]]` or `[[done: ...]]` to track in-line work items:

```
[[todo: rewrite the meet-cute beat]]
[[done: confirmed timeline with director]]
```

Maugham renders the bracket as a clickable checkbox; clicking toggles `todo` ↔ `done`. On first save, an invisible `<!--t-XXXXXX-->` anchor is appended after the closing `]]` — that's how Maugham tracks the task across edits. The anchor is an HTML comment, so the file remains valid Fountain and round-trips cleanly through Highland, Slugline, FountainJS, and any other tool.

Task anchors don't count toward the page count and don't affect element classification.

## Page count

Maugham computes page count using the standard Final Draft heuristic: 55 lines per page, with element-specific wrap widths. Action wraps at 60 characters per line, dialogue at 35, parenthetical at 20. Scene headings count as 2 lines (heading + implicit blank above). Sections, synopses, boneyard, notes, and page breaks don't count. Dual-dialogue pairs count as the height of the longer block (matching Final Draft's side-by-side semantics), not the sum.

For a typical feature screenplay (action-heavy with normal dialogue ratios), Maugham's estimate is within ~5% of Final Draft's pagination. Short fixtures and outline-heavy drafts may diverge more — page count is a guidance number, not a production-fidelity figure.

The page count appears in the bottom-right goal indicator capsule. Set a Page target via the Inspector for a screenplay project to see progress (e.g., "27.5 / 110 pages (25%)").

## Smart typography

Smart typography (em dash, curly quotes, ellipsis substitution) is **disabled** by default for screenplay mode. Screenplays stay ASCII so they remain compatible with Final Draft, Highland, FountainJS, and other tools that expect plain Fountain.

## Not supported (deliberately)

The following Fountain features render as plain text or are simply not recognized:

- **Scene numbers** (`INT. KITCHEN - DAY #5#`) — production-side metadata, not a writing concern.
- **MORE / CONT'D markers** across page breaks — production-prep concern handled at export, not while drafting.
- **Revision marks** (color-coded change marks per draft) — production-tool concern.
- **FDX import/export** (Final Draft binary format) — Maugham keeps screenplays in plain Fountain so they stay readable in any tool. Convert via Highland or any other Fountain-aware editor if you need FDX.
- **Visual uppercase for forced characters** — `@sam` renders as-typed (lowercase preserved). Glyph-substituting it to "SAM" was deliberately rejected to keep what you type and what you see aligned.

These omissions keep the screenplay surface focused on writing. If a screenwriter needs a feature on this list, file an issue.

## How to think about it

Fountain is the source of truth — `.fountain` files on disk are plain text that any other Fountain-aware tool can read. Maugham's job is to render those files with screenwriting typography (proper indents, proper alignment, proper page count) without ever locking the manuscript into a proprietary format. The same screenplay opens cleanly in Highland, Slugline, FountainJS, or just `cat`.

For the canonical Fountain spec — including features Maugham doesn't yet implement — see [fountain.io/syntax](https://fountain.io/syntax).
