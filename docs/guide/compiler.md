# Checking Your Writing

Maugham can read what you have just written and tell you where it drifts from
what you said you were going for. Press **⌘R** — *Check Writing* — and the notes
appear in the **Diagnostics** pane (⌘⌥D), which leads the pane picker in the
**Author** persona (⌘2).

It runs when you press the key, and at no other time. There is no background
check, no linting as you type, no badge that appears while you are mid-sentence.
That is deliberate: the point is a check you can reach for constantly because it
is cheap, not one that reaches for you.

## What it reads

- **Your intent** for the piece you are writing — the Intent pane's statement
  for this document, or the project's if the document has none. If you have
  declared no intent at all, the check still runs; it simply has no standard of
  yours to measure against, and says less.
- **What has changed since the last check.** Not the whole document. The first
  check on a document reads everything; after that each one picks up where the
  last left off, so a check in the middle of a session is about the paragraphs
  you just wrote.
- **What you're pinned to.** The same set the References shelf shows you (see
  below) — named by title, alongside the tool it would use to look closer. A
  photograph you own has no such tool yet, and the run says so rather than
  pretending to see it.

The header line above the notes tells you the first two: when it last ran, and
how much it looked at ("3 new, 2 revised ¶").

## The intent strip

While you're in Author, one dimmed line sits right above the prose — the
running head's register, not the editor's. It's the first line of the intent
that applies to what you're writing, the piece's own if it has one, headings
skipped so `# Intent` never becomes the sentence you see. Click it to open the
Intent pane at that scope. If you've declared no intent, there's no line at
all — an empty strip would be a nag wearing typography, not a signature. It
goes away with the rest of the chrome under ⌘\, and it's Author's alone: the
other personas aren't writing.

It's not decoration. It's the same sentence a check measures your writing
against — always in view, without switching panes to remember what you said
you were going for.

## References, and what you can study

⌘⌥E opens **References** — the research you've linked to this document, plus
any cards you've clustered for it on the planning canvas, as a shelf of
thumbnails and titles. Click a pin and it opens in a column between the binder
and your prose, wide enough to read, and you can drag its edge to resize.
Click the same pin again, promote a different one, or press Escape, and it
goes back.

**This is the same list a check reads.** What's on your shelf is what Claude
is briefed on when you press ⌘R — nothing more, nothing hidden. Full mechanics
— how a pin gets there, resizing, what each kind renders as — are in
[Inspector, Research & Outline → References mode](right-pane.md#references-mode-e).

## What comes back

Each note is anchored to a paragraph. Click one to jump to that paragraph in the
editor.

A note stops being shown once you have changed the paragraph it was about — the
check has not seen your revision, so it no longer has an opinion on it. Notes
are also replaced wholesale by the next check: what you see is always the most
recent run's, never a pile.

One kind of note is different. A **drift** note has no paragraph under it and
sits at the top of the pane. It means the writing has moved and your stated
intent has not caught up. Its action is **Open Intent**, which takes you to the
statement so you can bring it up to date.

## Three things you can do with a note

**Answer it.** If a note describes something you did on purpose, press
**Answer**, type why, and press Return. Your sentence is added as a new
paragraph to that piece's intent — minting the statement if you did not have
one — and the note goes away. The next check reads the intent you just enriched,
so an answer is permanent rather than a dismissal you have to repeat. Escape
takes the field away without writing anything.

Answers go into the *piece's* intent, never the project's. An explanation of
what you were going for in this chapter belongs to this chapter; the project's
statement stays something you write deliberately, in the Intent pane.

A drift note offers no **Answer** — it is not about a paragraph, so there is
nothing to explain in a sentence. Open Intent and edit the statement whole.

**Keep it.** **Promote to Task** turns the note into a real task on the
document, carrying its own words plus one line recording who raised it, when, in
which model, and what it was checked against. That line quotes your intent as
it stood at the moment the note was raised — if you rewrite your intent later,
older tasks keep naming what they were checked against then, not what you have
now. Tasks sync and survive; the notes do not. ⌘Z takes the task back.

**Leave it.** A note you neither answer nor keep disappears at the next check.
If it still stands, the next check raises it again.

## Choosing how hard it looks

The gear menu in the pane's header picks the model: **Fast**, **Standard** (the
default), or **Deep**. The choice is per project and is remembered. Changing it
never interrupts a check already running — the one you are waiting for finishes
in the model it started in, and the next one is the one that changes. That
next check starts a fresh session behind the scenes, so it's a few seconds
slower than the warm session you're used to — a one-time cost of the switch.

**Cancel** appears in the header while a check is running.

## What you need for it to work

- **Claude Code installed on your Mac.** The check runs it for you; you do not
  open it. If it is missing, the pane says so.
- **Claude access turned on** — Settings → General → *Allow Claude to connect
  (MCP)*. The same switch governs this as governs Claude Desktop. Turning it off
  stops any check immediately.

Checks use your own Claude account.

## What it will not do

It reads your manuscript and writes nothing into it. It cannot edit your prose,
your research, your palette, or your intent — including the intent it is
measuring you against, which only you and the **Answer** field can add to.

Notes live on the Mac that produced them and are not synced. Losing them costs
nothing: press ⌘R again.
