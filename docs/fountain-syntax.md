# Fountain syntax in Maugham

Maugham's screenplay mode uses [Fountain](https://fountain.io) — a plain-text screenplay format readable by Final Draft, Highland, Slugline, FountainJS, and other screenwriting tools. This page documents what Maugham specifically recognizes and how it renders each element.

The underlying parser is `FountainTokenizer.swift`. The styling pipeline is `ScreenplayMode.applyTypography`. Layout follows the Cole & Haag standard (Hollywood spec): 60-character page width at 10cpi, scene heading bold, character cue at column 22, dialogue indented at column 10 with 35-char width, parenthetical at column 15 with 20-char width, transition right-aligned. Maugham's screenplay text container is fixed at 60 characters wide regardless of your prose-mode page-width setting.

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

## Page count

Maugham computes page count using the standard Final Draft heuristic: 55 lines per page, with element-specific wrap widths. Action wraps at 60 characters per line, dialogue at 35, parenthetical at 20. Scene headings count as 2 lines (heading + implicit blank above). Sections, synopses, boneyard, notes, and page breaks don't count.

For a typical feature screenplay (action-heavy with normal dialogue ratios), Maugham's estimate is within ~5% of Final Draft's pagination. Short fixtures and outline-heavy drafts may diverge more — page count is a guidance number, not a production-fidelity figure.

The page count appears in the bottom-right goal indicator capsule. Set a Page target via the Inspector for a screenplay project to see progress (e.g., "27.5 / 110 pages (25%)").

## Smart typography

Smart typography (em dash, curly quotes, ellipsis substitution) is **disabled** by default for screenplay mode. Screenplays stay ASCII so they remain compatible with Final Draft, Highland, FountainJS, and other tools that expect plain Fountain.

## What's not supported in milestone-3a

The following Fountain features are deferred to later milestones:

- **Tab/Enter element cycling** — pressing Tab on a line to cycle its element type. **Milestone 3b**.
- **Character autocomplete** — completion of character names from prior usage. **Milestone 3b**.
- **Scene navigator** — a slugline jump list. **Milestone 3c**.
- **Title page block** — `Title:` / `Author:` / `Credit:` metadata at the document head. **Milestone 3c**. Currently those lines render as plain action.
- **Multi-file screenplays** — one `.fountain` per scene with the binder showing scenes as siblings. **Milestone 3d**.
- **Visual uppercase for forced characters** — rendering `@sam` as "SAM" via glyph substitution. Deferred (option A is currently active: forced characters render as-typed).
- **Scene numbers** — `INT. KITCHEN - DAY #5#`. **Phase 4**.
- **Dual dialogue** — two speakers side-by-side via `^`. **Phase 4**.
- **MORE / CONT'D** markers across page breaks. **Phase 4**.
- **Revisions** (color-coded change marks per draft). **Phase 4**.
- **FDX import/export** (Final Draft binary format). **Phase 4**.
- **Inline emphasis inside dialogue** — `*italic*` and `**bold**` mid-line. **Phase 3c or 4**.

## How to think about it

Fountain is the source of truth — `.fountain` files on disk are plain text that any other Fountain-aware tool can read. Maugham's job is to render those files with screenwriting typography (proper indents, proper alignment, proper page count) without ever locking the manuscript into a proprietary format. The same screenplay opens cleanly in Highland, Slugline, FountainJS, or just `cat`.

For the canonical Fountain spec — including features Maugham doesn't yet implement — see [fountain.io/syntax](https://fountain.io/syntax).
