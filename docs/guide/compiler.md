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

Two things, and only two:

- **Your intent** for the piece you are writing — the Intent pane's statement
  for this document, or the project's if the document has none. If you have
  declared no intent at all, the check still runs; it simply has no standard of
  yours to measure against, and says less.
- **What has changed since the last check.** Not the whole document. The first
  check on a document reads everything; after that each one picks up where the
  last left off, so a check in the middle of a session is about the paragraphs
  you just wrote.

The header line above the notes tells you both: when it last ran, and how much
it looked at ("3 new, 2 revised ¶").

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
which model, and what it was checked against. Tasks sync and survive; the notes
do not. ⌘Z takes the task back.

**Leave it.** A note you neither answer nor keep disappears at the next check.
If it still stands, the next check raises it again.

## Choosing how hard it looks

The gear menu in the pane's header picks the model: **Fast**, **Standard** (the
default), or **Deep**. The choice is per project and is remembered. Changing it
never interrupts a check already running — the one you are waiting for finishes
in the model it started in, and the next one is the one that changes.

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
