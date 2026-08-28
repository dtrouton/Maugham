# The Publish Department

Publish has its own department: a designer for the book's typesetting and a
translator for each language edition, all running inside the app on the same
model the compiler uses. They read what you've written, propose work, and
show it to you before anything ships — nothing here ever touches your
manuscript or your live templates without your say-so.

## The desk (⌘⌥K)

The desk is Publish's own working pane, and the mode Publish opens on — the
persona's front door, the way Diagnostics is Author's and Annotations is
Review's. It's about the book as a whole rather than the chapter you happen
to have open: a **Design** section for the book's typesetting, and a
**Languages** section with a row per edition.

Every project has a designer from the moment it exists, so the Design row
and its **Run** button are always there — there's no empty state to work
around. A language row appears the moment there's a reason for one: when
you start the edition yourself (below), as soon as a translator asks a
question about that language, or as soon as a paragraph of it has been
translated.

If Maugham can't read one of your chapters — a history file that's there
but won't open, an iCloud download that hasn't finished — the Languages
section names that chapter above the rows and says why, and the rest of
the book's editions still show. What's missing is that chapter's share of
the counts, not the whole desk.

### Which book the desk is about

If your project declares **imprints** in `config.json` — a special edition
with its own template, its own metadata and its own version count — the
desk's header carries a picker: **Book**, then one row per imprint. What
you pick is what the whole desk is about. An imprint that names its own
`sections` publishes a subset of the book, and the language rows are summed
over exactly that subset: the same Spanish edition can be three paragraphs
short of the novel and complete for the pamphlet cut out of it.

The choice is remembered per project, so if you spend a week on one special
edition you pick it once. A project with no imprints gets one line saying
so instead of a picker — an imprint is declared in `config.json`, not from
this desk.

## Starting an edition

**Add Language…**, at the foot of the Languages section, is how a book
gets an edition it doesn't have yet. Type the language's tag — `es`,
`fr`, `pt-br`; capitals are fine, Maugham lowers them for you — and the
name of the person who translates it. For the four languages that come
with a translator already picked, that name fills itself in; keep it or
type somebody else's. A tag that isn't a language tag says so in the
sheet rather than failing later, and Cancel leaves the book's editions
exactly as they were.

The row appears as soon as you confirm, with nothing translated yet and
the whole book ahead of it. Adding a language the book already has just
says so — the edition is already on the desk, and renaming its translator
is that row's own verb.

## The people

Four languages come with a translator already picked, borrowed from real
literary history: **Cortázar** for Spanish, **Baudelaire** for French,
**Tieck** for German, **Motoyuki** for Japanese. Every project's designer is
**Tschichold**. Their names sign every paragraph and every query the work
they do produces, the same way a review pass's editor — Perkins, Lish,
Gould, Argus — signs its notes.

Ask for a language Maugham has no preset for and the first Run asks you to
name its translator first — a short sheet, one field, **Name & Run**. What
you type there is the byline for everything that edition's translator writes
from then on; there's no picker and no way to leave it blank.

Nobody's name is fixed. Every row on the desk carries a rename — the
pencil beside it, or a right-click on the row: **Rename Cortázar…** on a
language row, **Rename Tschichold…** on the Design row, and **Name This
Translator…** where an edition has nobody yet. A new name signs
everything from then on, and orphans nothing: the paragraphs, queries and
design rounds already signed stay theirs, because a rename renames the
person rather than handing their work to somebody else.

## Running a translation

Open the chapter you want translated, then press **Run** on that language's
row. A round works through whatever in that document is stale or missing
against that edition, asks a query when something needs your call (voice,
register, an ambiguous term — it lands in your queue like any other note),
and writes what it's sure of straight into the translation. Only one
translation round runs at a time, across every language — Run is disabled
with the reason whenever another edition is mid-round, and Cancel appears
once a round is under way. Nothing writes until the round finishes cleanly —
a cancelled or failed round leaves nothing behind.

The row keeps track of how much of the book is fresh, stale, and missing in
that language, and how many open queries you still owe an answer. See
[Translating Your Manuscript](translation-review.md) for reviewing what
comes back, orphaned paragraphs, and publishing the edition itself.

## Running a design round

The Design row's field takes **direction** — a sentence or two about what
this round should attend to. It's optional: a bare Run briefs the designer
on your visual language statement alone, which is the point of having
written one. Press **Run** and the designer reads the book, proposes a spec
plus a complete set of templates, and compiles a handful of sample pages
that demonstrate every kind of element your manuscript actually uses — a
verse passage, a block quote, a footnote, whatever's really there.

Nothing from a round reaches your live templates on its own. When it's
ready, the row shows which round it is, where it stands, and how long ago —
press **Show** to open it.

## Compiling from the desk

**Compile…** at the foot of the Languages section makes the book. Until it
existed the only way to publish from Maugham was to ask Claude for it; this
is the same compile, asked for by you.

The sheet asks three things:

- **Format** — PDF or EPUB.
- **Editions** — the book's own language is checked to begin with, and
  every language on the desk gets a checkbox of its own. Check more than
  one and you get a single volume with both bodies in it, in the order the
  sheet lists them. Uncheck everything and Compile refuses: a compile with
  no edition in it would make nothing.
- **Allow stale translations** — off by default. A stale paragraph is one
  whose source has changed underneath the translation, and leaving this off
  is what stops one shipping unnoticed.

Which imprint the compile is for is the picker's answer, shown at the top
of the sheet and not asked again.

One compile runs at a time. While it does, the desk says what it is
compiling and offers **Cancel**; press Compile… again and it tells you a
compile is already running rather than starting a second one — the one in
flight is untouched, and Cancel still stops it. A cancelled compile
publishes nothing. When one lands, the line says the version, the imprint
and the edition, and where the file is.

Nothing already published is touched: every compile mints its own version.

## The gate

Show opens the round in the centre column: the spec on the left, the sample
pages on the right. A round is always for the book as a whole — direction
doesn't single out one language edition. From here you decide what happens
to it:

- **Approve** puts the round's templates onto your live publish tree. Your
  current templates are backed up first, so this is never a one-way door on
  its own.
- **Request Changes** sends your own words back to the same session that
  made the proposal, and starts its next round — the field on the desk
  becomes the request.
- **Revert** takes an approved round back, restoring the templates it
  replaced from that backup.
- **Finalize** keeps an approved round for good and lets the backup go. This
  is the one irreversible step in the department: once you finalize, there's
  nothing left to revert to. It's also the only verb here that asks before it
  acts — a confirmation naming what's discarded, with Cancel leaving the
  promotion exactly as it stood.

Only the verbs that make sense for where a round stands are ever offered —
Approve on a pending round, and Request Changes beside it while the session
that proposed it is still open (once that session has closed, the honest next
move is a fresh Run from the desk); Revert and Finalize once you've approved
one — and a round that's been superseded by a newer one, or turned down, says
so instead of offering anything at all. Whenever a verb
can't go through — another proposal is already holding the one backup slot,
a compile is running, there's nothing to finalize — you get the reason in
words, never a button that quietly does nothing.

## The brief and rulings

**Edition Brief**, on any language row, opens that edition's own brief — a
writer-owned statement, the same standing as your craft intent and your
visual language: register, idiom policy, what stays untranslated,
typographic conventions for that language. The first click creates it; every
click after opens the same one. Like the others, it carries its own
**Rulings** section — dated, itemized decisions the translator is expected
to honor exactly as written, not treat as a suggestion.

## Answering a translator

A translator's query and a whole-document question (voice, an honorific,
whether to translate a name) both show up in your queue like any other note
from Claude, tagged with the language they're about. Answer one from the
queue, or from the Translation pane (⌘⌥L) while reviewing that edition, and
an open one carries an extra option beside the ordinary reply: **Answer as
ruling…**. Taking it writes a dated entry into that edition's brief in the
same act as your reply — so the next round doesn't have to ask again, and
neither does a translator working a different chapter of the same book.
