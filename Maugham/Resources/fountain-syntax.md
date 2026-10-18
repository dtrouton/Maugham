# Fountain syntax in Maugham

Screenplays in Maugham are written in [Fountain](https://fountain.io), a plain-text screenplay format that Final Draft, Highland, Slugline and other screenwriting apps can read. This page covers what Maugham recognizes and how each element looks.

Maugham lays your script out like a standard Hollywood spec script: scene headings bold, character names indented toward the center of the page, dialogue in a narrower column, parentheticals narrower still, and transitions on the right. The script page is always 60 characters wide, whatever page width you use for prose. The same rules apply while you write, on the phone, and in published PDF and EPUB.

## The basics

A Fountain screenplay is plain text. Maugham decides what each line is (a scene heading, a character name, dialogue and so on) from how it's written and from the line above it. So **blank lines matter**: they're how Maugham knows where one block ends and the next begins.

```
INT. COFFEE SHOP - DAY

Two friends sit across from each other.

BARRY
(after a long pause)
You ever wonder if we made the right call?

SAM
Every damn day.
```

That reads as a scene heading, a line of action, then Barry's name, a parenthetical and his dialogue, then Sam's name and his dialogue. A line in ALL CAPS after a blank line is read as a character name.

## Title page

You can start the file with an optional **title page**: a block of `Key: Value` lines ending with a blank line. Maugham shows it above the script.

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

The keys Maugham recognizes (capitals don't matter) are **Title**, **Credit**, **Author** (or **Authors**), **Source**, **Notes**, **Draft date**, **Contact** and **Copyright**.

The title page only counts if **the very first line of the file uses one of these keys**. That way, an opening line that happens to contain a colon won't swallow your first scene.

For a value that runs over several lines, indent the extra lines by **three or more spaces, or a tab** (like `Contact:` above). A blank line ends the title page.

## Elements

### Action

Anything that isn't one of the elements below is action, and runs the full width of the page.

```
Two friends sit across from each other.
```

### Scene heading

A line after a blank line that starts with `INT`, `EXT`, `EST`, `INT/EXT`, `EXT/INT` or `I/E` (any capitalization), followed by a period or a space, is a scene heading. It shows in bold.

```
INT. KITCHEN - DAY
EXT. ROOFTOP - NIGHT
EST. MEADOW - DAWN
I/E. CAR - CONTINUOUS
INT/EXT. WAREHOUSE - DAWN
INT ROOM - DAY
EXT/INT GARAGE - NIGHT
```

The period is optional: `INT ROOM - DAY` works too. Because of that, an ordinary line after a blank that happens to begin with one of these words (say, `Int room` in sentence case) also becomes a scene heading.

To make any line a scene heading, start it with a single period:

```
.barbershop
```

### Scene numbers

Add a scene number between `#` marks at the end of a scene heading:

```
INT. KITCHEN - DAY #4A#
```

While you write, the number shows dimmed at the end of the heading. On the phone's Read tab the number isn't shown. In published PDF and EPUB it sits at the right-hand end of the heading. You type scene numbers yourself; Maugham doesn't number or renumber scenes for you.

### Character

A line in **ALL CAPS** after a blank line is a character name.

```
BARRY
Hello there.
```

To use a name with lower-case letters, start the line with `@`:

```
@Sam
Hi.
```

`@McConnell` keeps its capitals exactly as you typed them; Maugham doesn't turn the name into upper case.

**An ALL CAPS line after a blank is a character name straight away**, before you've typed any dialogue under it, so that a new name looks right the moment you type it. The catch is that a one-line action beat written entirely in capitals after a blank line also reads as a character name. Write it in mixed case, or keep it attached to the line above, to avoid that.

#### Character extensions

Periods, parentheses, digits and spaces don't affect the ALL CAPS test, so **extensions** like V.O., O.S. and CONT'D need nothing special:

```
MARLOWE (V.O.)
The city was hotter than a two-dollar pistol.

JANE (O.S.)
Did you say something?

BOB (CONT'D)
Where was I?
```

There's no fixed list of extensions: anything that keeps the line in capitals works, including `(FILTERED)` or `(ON RADIO)`.

**Note:** a single lower-case letter anywhere on the line turns it into action, so `Marlowe (V.O.)` is action. Use `@` for a name with lower-case letters (for example `@McTeague`).

### Dialogue

The lines right after a character name or parenthetical are dialogue, up to the next blank line. Dialogue sits in a narrower column, about 35 characters wide.

```
BARRY
You ever wonder if we made the right call?
What if we'd just driven north that night?
```

To leave a gap inside a speech without ending it, put exactly two spaces on the "blank" line. A truly empty line ends the dialogue.

### Parenthetical

A line in `(...)` between a character name and dialogue is a parenthetical. It shows in italics, in a narrower column than the dialogue.

```
BARRY
(after a long pause)
You ever wonder if we made the right call?
```

### Dual dialogue

When two characters speak at once, add `^` after the **second** character's name:

```
BRICK
Screw retirement.

STEVE ^
Screw retirement.
```

The `^` shows dimmed. While you write and on the phone, the two speeches are stacked, with the second one shifted to the right. **In published PDF and EPUB they print side by side** in two columns. The page count counts the pair as the longer of the two speeches, not both added together.

Speeches pair up two at a time: in a run of `A`, `B^`, `C^`, A and B make a pair and C stands alone.

### Transition

An ALL CAPS line after a blank that ends in `TO:` is a transition, shown bold on the right:

```
SMASH CUT TO:
DISSOLVE TO:
```

**`FADE OUT.` isn't recognized on its own**, because it doesn't end in `TO:`, so it reads as a character name. Start it with `>` instead:

```
> FADE OUT.
```

A leading `>` makes any line a transition:

```
> Cut to:
> Fade out.
```

### Centered text

Put `>` before and `<` after a line to center it:

```
>THE END<
> A title card <
```

Handy for title cards, end credits and montage labels.

### Lyric

A line starting with `~` is a lyric, for songs, poems and chants. Lyrics show in italics everywhere, including published PDF and EPUB, where each lyric line is printed on its own line.

```
~la la la
~Somewhere over the rainbow
```

### Sections

Lines starting with `#` (one to six of them) are sections, shown bold and underlined. They're for your own outline of acts, sequences and beats, not part of the script itself: they don't count toward the page count and **don't appear in published PDF or EPUB**.

```
# ACT ONE
## Sequence A: The Setup
### Beat: Inciting incident
```

### Synopses

A line starting with `= ` (an equals sign and a space) is a synopsis, a one-line summary of a beat. It shows dimmed in italics. Like sections, synopses are notes for you: they don't count toward the page count and **don't appear in published output**.

```
= Sam confronts Barry about the lie.
```

### Page break

A line of three or more `=` signs (and nothing else) is a page break. Published PDF and EPUB start a new page there.

```
===
```

### Boneyard (cut material)

Put `/*` at the start of a line and `*/` where the cut ends to set material aside without deleting it. It shows dimmed in italics, can run over several lines, doesn't count toward the page count and **doesn't appear in published PDF or EPUB**. The `/*` has to start a line; a `/* ... */` in the middle of a line stays as ordinary text.

```
/* This scene was cut for pacing.
   Keep it here in case we want it back. */
```

### Notes

Wrap text in `[[ ... ]]` to make it a note to yourself. A note can stand on its own line (or run over several lines), or sit inside a line of action or dialogue.

A note on its own line:

```
[[ todo: rewrite this beat ]]

[[ check with director:
   should this be daytime or night? ]]
```

A note inside a line:

```
Action paragraph with a [[ side note ]] embedded inline.
```

Notes show dimmed in italics; a note inside a line is dimmed while the rest of the line looks as usual. Notes are only for you: they don't count toward the page count and **don't appear in published PDF or EPUB**.

### Inline emphasis

Inside any line you can use:

- `*italic*` with single asterisks.
- `**bold**` with double asterisks.
- `***bold italic***` with triple asterisks, and you can put bold inside italic (`*a **b** a*`).
- `_underline_` with single underscores.
- `\*` or `\_` (a backslash first) for a literal asterisk or underscore that doesn't start or end emphasis.

```
She glances at the *worn* photograph, then **slams** the drawer shut.
The sign reads _Closed for inventory_.
She almost said \*yes\* out loud.
```

The marks show dimmed while the words between them take the style. Emphasis works in action, dialogue and parentheticals, and it never changes what kind of line something is. In a screenplay, emphasis has to open and close on the same line. Strikethrough (`~~`) isn't available in screenplays, because `~` marks a lyric.

### Tasks

Write `[[todo: ...]]` for a task, or `[[done: ...]]` for one that's finished:

```
[[todo: rewrite the meet-cute beat]]
[[done: confirmed timeline with director]]
```

Maugham shows the task as a checkbox; clicking it switches between `todo` and `done`. Tasks don't count toward the page count and don't change what kind of line they're on. The file stays ordinary Fountain that other screenwriting apps can open.

## Page count

Maugham estimates pages the way Final Draft does: 55 lines to a page, with action wrapping at 60 characters, dialogue at 35 and parentheticals at 20. A scene heading counts as two lines (it has a blank line above it). Sections, synopses, boneyard, notes and page breaks don't count, and a dual-dialogue pair counts as its longer speech.

For a typical feature script, the estimate lands within about 5% of Final Draft's page count. Very short scripts and outline-heavy drafts can differ more, so treat it as a guide rather than an exact figure.

The page count appears in the status line at the bottom of the editor. Set a **Page target** in the Inspector (⌘⌥I) to see your progress, for example "27.5 / 110 pages (25%)".

## Smart typography

Screenplays never get smart typography (em dashes, curly quotes, ellipses). Scripts stay in plain characters so other screenwriting apps read them correctly.

## Publishing (PDF and EPUB)

Published output follows the same rules as the editor, so what you see while you write is what prints:

- Boneyard, notes, synopses and sections are left out.
- The forcing marks (`.` for a scene heading, `@` for a character, `!` for action, `>` for a transition or centered text) do their job and don't print.
- Page breaks (`===`) start a new page.
- Lyrics print in italics, each on its own line.
- Dual dialogue prints side by side in two columns.
- Scene numbers sit at the right-hand end of the scene heading.

## Not supported

These aren't recognized, or show as ordinary text:

- **Cut material in the middle of a line** (`Some action /* cut */ more action`): only a `/*` at the start of a line works.
- **MORE / CONT'D across page breaks**: Maugham doesn't add these at page breaks.
- **Revision marks** (colored change marks for each draft).
- **Final Draft (.fdx) import and export**: your screenplay stays a plain Fountain file. To get an .fdx, open the file in Highland or another Fountain app and convert it there.
- **Upper-casing names that start with `@`**: `@sam` shows exactly as typed.
- **A button for dual dialogue**: type `^` yourself. There's no menu command for it, and Tab doesn't cycle to it.

## How to think about it

Your `.fountain` file is the script: plain text that any Fountain app can read. Maugham's job is to give it proper screenplay layout (the right indents, alignment and page count) without locking it into a proprietary format, so the same script opens cleanly in Highland, Slugline or any plain-text editor.

For the full Fountain specification, including features Maugham doesn't support, see [fountain.io/syntax](https://fountain.io/syntax).
