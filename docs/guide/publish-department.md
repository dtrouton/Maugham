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
name of the person who translates it. Two more fields, both optional, name
the edition's reader and its collator (below). For the four languages that
come with a cast already picked, all three names fill themselves in as you
type the tag; keep them or type somebody else's. A tag that isn't a
language tag says so in the sheet rather than failing later, and Cancel
leaves the book's editions exactly as they were.

The row appears as soon as you confirm, with nothing translated yet and
the whole book ahead of it. Adding a language the book already has just
says so — the edition is already on the desk, and renaming its translator
is that row's own verb.

## The people

**Every language edition has three people, not one.** The **translator**
writes it. The **reader** then reads that translation and nothing else — not
your English, not a phrase of it — and says where the prose doesn't sound
like a book written in that language. Because they have never seen your
source, they can never tell you a sentence is wrong; they can only tell you
it reads badly, which is the one judgement a monolingual read is good for.
The **collator** holds both texts side by side and says where the
translation has moved away from what you wrote, and every departure they
raise carries a **gloss** — a plain, literal rendering back into your own
language of what the translation now says. The gloss is what lets you rule
on a paragraph in a language you don't read.

Four languages come with all three already picked, borrowed from real
literary history:

| Language | Translator | Reader | Collator |
|---|---|---|---|
| Spanish | Cortázar | Ocampo | Borges |
| French | Baudelaire | Colette | Yourcenar |
| German | Tieck | Bachmann | Schlegel |
| Japanese | Motoyuki | Enchi | Futabatei |

Every project's designer is **Tschichold**. Their names sign every paragraph,
every note and every query the work they do produces, the same way a review
pass's editor — Perkins, Lish, Gould, Argus — signs its notes.

Ask for a language Maugham has no preset for and the first Run asks you to
name its translator first — a short sheet, **Name & Run**, with the reader
and collator fields beside it. Only the translator's name is required; leave
the other two blank and Maugham names them for you when a round needs them.
Nobody is named just because you looked at a row: the reader and collator
are minted when a round actually puts them to work.

Nobody's name is fixed. Every row on the desk carries a rename — the
pencil beside it, or a right-click on the row: **Rename Cortázar…** on a
language row, **Rename Tschichold…** on the Design row, and **Name This
Translator…** where an edition has nobody yet. The sheet renames the whole
cast of that edition, all three fields at once. A new name signs
everything from then on, and orphans nothing: the paragraphs, notes, queries
and design rounds already signed stay theirs, because a rename renames the
person rather than handing their work to somebody else.

## Running a translation

Open the chapter you want translated, then press **Run** on that language's
row. One press is **seven legs of work**, in this order:

1. **Translate** — the translator works through whatever in that chapter is
   stale, missing, or covered by a directive you've written, and asks a query
   when something needs your call (voice, register, an ambiguous term — it
   lands in your queue like any other note).
2. **Read** — the reader reads the translation cold and writes notes.
3. **Fix** — the translator answers those notes, addressing each or saying
   why they won't.
4. **Re-read** — the reader reads the repaired text, cold again.
5. **Fix** — the translator answers the second read.
6. **Collate** — the collator compares the translation against your English
   and raises departures, each with its gloss.
7. **Fix** — the translator answers the departures that drifted, writes the
   round's summary, and proposes any glossary terms the book should fix.

**A leg that has nothing to do is skipped, and the skip is recorded** rather
than passed over in silence — the report tells you which leg didn't run and
why. The second read is skipped when the first fix changed nothing, which is
good news; the first read is skipped when there was nothing translated to
read, which isn't.

Before you press anything the row tells you what the click costs: **7 legs ·
~4,300 words briefed**, counted over the chapter you have open — or over the
whole book, when you have no chapter open and Run Whole Book is the verb the
figure is for. Beside it, from the first round on, is the trend — **notes per
round 9 → 5 → 3** — the last five rounds, oldest first, so you can see the
edition settling rather than churning.

While a round runs the row says which leg it's on: *Reading… (leg 2 of 7)*.
Only one round runs at a time, across every language and both kinds of run —
Run is disabled with the reason whenever another edition is mid-round, and
**Cancel** appears once a round is under way.

**Cancel stops the round after the leg that's running, and what earlier legs
wrote stays.** This is not the promise a one-shot translation could make. By
leg 3 the translation has already been written and repaired once, and undoing
that would be throwing away work you can read in Translation Review. A failed
leg ends the round the same way, in the same place: the report names where it
stopped and why, and everything before it stands.

When a round ends the row says so — *Round 3 · finished 2m ago* — with
**Show** beside it. That's the report; see below.

The row also keeps track of how much of the book is fresh, stale, and missing
in that language, and how many open queries you still owe an answer. See
[Translating Your Manuscript](translation-review.md) for reviewing what
comes back, orphaned paragraphs, and publishing the edition itself.

## Running the whole book

**Run Whole Book**, beside Run on every language row (and in the row's
right-click menu), runs one round on **every chapter of the book the desk is
on**, in binder order. If you've picked an imprint, that's the imprint's own
chapters and no others — the same set the row's coverage figures are summed
over, so a book that's complete for the pamphlet cut isn't sent through the
whole novel to find out.

It needs no chapter open. Run is about the document this window is on;
Run Whole Book is about the book, which is what the desk is about, so it
works from the project row or anywhere else in the tree. Hovering it says how
many chapters and roughly how many words that is. It refuses, in words, while
another round is running, when the edition's language tag isn't one Maugham
can write an edition for, and when the imprint you've picked names no
chapters at all.

While the queue runs, the row says which chapter as well as which leg:
*Chapter 4 of 12 · reading… (leg 2 of 7)*. **Cancel** stops the queue after
the leg that's running, exactly as it stops a single round — the chapters
already done stay done. **A failed round stops the queue too**, rather than
sending the next chapter into the same trouble: you should see what went
wrong on this one first.

## The round report

**Show** on a language row opens the newest round for that edition in the
centre column. It's written to you in your own language — every verb on it is
one you can press without reading a word of the translation. Six sections,
in this order:

**The reader's report.** The first read beside the second, each with its
verdict and the paragraph the reader wrote. Read them together and you can
see whether the middle of the round earned its keep. Where a read didn't
happen the column says which silence this is, in its own words. Beneath the
two, under **The collator**, is the collator's own verdict on the chapter as
a whole — the departures below are the particulars of it.

**Where your prose was changed.** One row per departure: your own paragraph,
the collator's gloss of what the translation now says, their reason, and what
the translator did about it. Three verbs on each row.

- **Fine** — you're happy with the change. It's recorded on the round beside
  what the translator did, never over it, so the row still says whether they
  rewrote the paragraph or declined to. The row's verbs come off once you've
  said so — offering you Fine again over your own answer would be the app
  forgetting it.
- **Keep mine** — opens the Translator's Note sheet with the collator's note
  already in the field, homed to **this edition only** by default, since the
  decision came out of this language. What you write is a dated directive on
  that paragraph, and the next Run treats the paragraph as work.
- **Make it a rule** — a general ruling in this edition's brief, prefilled
  from the note. Doctrine for the edition from the next round on.

The translated text itself is behind **Show the translation** on rows the
translator rewrote — before and after, and only when you ask for it.

**Disagreements.** Only the notes the translator turned down, with both
bylines: who raised it, and the translator's reason for declining. The verbs
are **Translator's right** (you side with the translator; the question is
settled and the translation stands), **Reader's right** or **Collator's
right** depending on who raised it (you side with the note; it becomes a
dated directive on that paragraph and the question is answered), and **Make
it a rule**. Where a declined note never became a question there's nothing to
reject: Translator's right comes off that row, and the row says so. The other
two verbs still apply — your decision stands whether or not there's a thread
to post it on.

**Questions for you.** The round's own queries, with **Answer** and — where
the question is about one edition — **Answer as ruling…**, the same pair
you'd get in the queue. If the questions can't be read at all, the section
says that instead of showing you an empty list.

**Glossary proposals.** Terms the round thinks the book should fix, each with
its rendering and the reason. **Adopt** writes it as a glossary line in the
edition brief, where every later translator, reader and collator is briefed
with it; **Skip** is remembered on the round so you aren't asked to decide
twice.

**Summary.** The round's own closing words, its counts, and **Open the queue** — the round's
questions settle in the same notes queue everything else does, and that's the
door to it.

**Every source line on the report is a way back into the book.** Click the
paragraph at the top of a departure or a disagreement and Maugham opens that
chapter in Translation Review, in that language, at that paragraph — selecting
the chapter first if it isn't the one you have open, and waiting for the
translation to draw before it scrolls, so you land on the paragraph rather
than at the top of the edition.

**Back to the book** closes the report.

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
compiling and offers **Cancel**; Compile… itself is greyed out, and
hovering it says a compile is already running. A cancelled compile
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
queue, from the round report's **Questions for you**, or from the Translation
pane (⌘⌥L) while reviewing that edition, and an open one carries an extra
option beside the ordinary reply: **Answer as ruling…**. Taking it writes a
dated entry into that edition's brief in the same act as your reply — so the
next round doesn't have to ask again, and neither does a translator working a
different chapter of the same book.

A note the *reader* or the *collator* raised and the translator declined
arrives in your queue the same way: a question signed by whoever raised it,
with the translator's reason for turning it down written into the body under
their own name. Settling it in the queue and settling it on the round
report's **Disagreements** section are the same act.
