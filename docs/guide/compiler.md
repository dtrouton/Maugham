# Checking Your Writing

Maugham can read what you have just written and check it two ways at once —
as a continuity editor, against what you've declared and what the manuscript
has already established, and as a first reader, reporting what happens in the
reading itself. Press **⌘R** — *Check Writing* — and the report appears in the
**Diagnostics** pane (⌘⌥D), which leads the pane picker in the **Author**
persona (⌘2). A capsule flashes **Checking…**, the same register as ⌘S's;
press ⌘R again while one is already running and it flashes **Still
checking…** instead of starting a second one.

The report arrives in sections rather than all at once. Your clauses come back
first, so you are reading the conformance summary while the reader's report is
still being written; the header keeps saying **Checking…** until the whole
check is done. A check you cancel takes its half-finished report with it and
puts the last completed one back.

It runs when you press the key, and at no other time. There is no background
check, no linting as you type, no badge that appears while you are mid-sentence.
That is deliberate: the point is a check you can reach for constantly because it
is cheap, not one that reaches for you.

## What it reads

- **Your intent**, read as checkable clauses and rules — your own sentences,
  quoted back to you exactly, never turned into a form or a diagram. The
  Intent pane's statement for this document, or the project's if the document
  has none. If you have declared no intent at all, the check still runs;
  conformance is simply absent from the report, and the reader's report still
  runs regardless.
- **What has already been established** — facts, knowledge states, voices —
  read silently off your manuscript by earlier checks and kept in the Intent
  pane's own ledger (see "The bible, filling quietly" below).
- **What has changed since the last check.** Not the whole document. The first
  check on a document reads everything; after that each one picks up where the
  last left off, so a check in the middle of a session is about the paragraphs
  you just wrote.
- **What you're pinned to.** The same set the References shelf shows you (see
  below) — named by title, alongside the tool it would use to look closer. A
  photograph you own has no such tool yet, and the run says so rather than
  pretending to see it.

The header line above the notes tells you when it last ran and how much it
looked at ("3 new, 2 revised ¶").

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
[The Right Column → References mode](right-pane.md#references-mode-e).

## What comes back

The pane reads as a report, in this order:

**This check**, first, and only when the run just raised something — the
notes it minted, in the order they fall down your manuscript rather than
newest first, each with **Got it** and **Not this** and a jump chip to the
words it's about. This is where a continuity question and a reader's report
land: a continuity question ends as a question rather than a verdict —
"Is the dock standing again by this scene?" rather than "Contradiction: the
dock burned" — and a check can raise as many as it finds. A reader's report
says where the dream broke or what a reader believes at this point,
**capped at the sharpest three** — most checks raise none at all, and the
cap belongs to the reader's report alone, not to continuity. Both mint as
ordinary annotations the moment the run that
raised them finishes, so this section is a live view of the newest run's own
rather than a second queue: settle a row and it's simply gone, nothing to
import anywhere because it never lived anywhere else. Leave one alone and it
doesn't vanish either — it's still open in your full queue, Review's
Annotations pane (⌘⌥A), the next time you look; Author itself never shows you
a backlog, only the check you just ran.

**Conformance**, next — every clause you've declared, quoted back in your own
words, each marked *holds*, *strains*, or nothing in this draft touched it
yet. A straining clause names what pulled against it, in one sentence, and
never a fix. **Open Intent**, in the section's own header, takes you straight
to the statement the clauses were read from.

**Nothing here ever shows you a paragraph id.** Every reference — a strain's
what-pulls, a wet-ink note's jump chip — carries the words that paragraph
said, as a chip you click to jump there. You always read your own prose back,
never a four-character token.

A clean run says so plainly — *"Nothing to flag."* — even when every clause
held: that is the good outcome the check exists to report, not an empty pane.

**Drift is one line, not a note.** When a clause has strained the same way
across three checks running, a line appears above the conformance summary —
*"Your line may have moved — '…' has strained three runs running. Draft's
right, or intent's right?"* — computed from what each run already keeps on
record, never a background process. It carries no id, offers no dismissal and
no reply field: press it and it takes you to Intent, and the pattern breaking
on a later check is what takes the line away, not a tap.

Every check also answers a quieter, more direct version of the same question:
does the draft still hold to what you declared? A **drifted** verdict leaves
a small mark on the intent strip — *"intent may trail the draft"* — that
stays until a later check comes back holding, or until you edit the
statement. A check against no declared intent records no verdict; there's
nothing for the draft to trail.

## Rounds

Check a piece while it has an active review pass — set by clicking a chip on
the [Review board](review-passes.md#the-board) — and the check becomes a
numbered **round** in that pass's own count. The report leads with what
changed since the last one: *"Since round 4: 2 resolved · 1 persisting · 1
new"*. The three counts come off your queue, not off what Claude happened to
repeat: *resolved* is what you've settled from an earlier round, *persisting*
is what's still open from an earlier one, and *new* is what this round
raised. A finding Claude raises again in different words is not a new note —
it's the one already in your queue. Round numbers are per pass, but the
memory behind them is the document's, not any one pass's: Maugham remembers a document's last six
finished checks, across every pass. Once enough later checks stack up behind
a round — six, counting the one still standing — it ages out of memory, so a
Structural round buried under a long run of Line checks is gone, and the next
check back in Structural starts over at round 1, with nothing behind it to
compare against. See [Review Passes](review-passes.md#rounds-and-fresh-eyes) for the
pass side of this.

## Fresh Eyes

**⌘⇧R** — *Fresh Eyes* — asks for a different kind of read: it ends the
warm session and reads the whole piece cold, briefed on your intent, your
rulings, and the bible, but deliberately not on anything an earlier round
found. Its report says so where the since-last-round line would otherwise
be: *"Fresh eyes"*, or *"Fresh eyes · round 3"* when it's also filed against
a pass.

## Reading a piece for the first time

The first time you check a document that has some real prose in it, the pane
offers before it runs anything: *"I haven't read this piece. Read it whole
and take notes?"* — **Read** starts the same check ⌘R would (the first check
on any document already reads the whole thing), and **Not now** declines.
Say no once and Maugham does not ask again for that document; a stub of a
document — a title and a line — is not offered at all, and neither is one
you have already checked, however that check turned out.

## The bible, filling quietly

Every check reads the wet ink and, without asking, notices what your prose
establishes — what a character knows and since when, what's physically true,
a voice. These land in the Intent pane's paler strip beneath your rulings —
*What Claude has read* — with three actions: **Bless** (graduate it to a
ruling, in your own words), **Correct** (edit it before it becomes one), and
**Dismiss** (it may return if the manuscript re-establishes it). Nothing there
is truth until you act on it; it is inspected, never tended.

Blessing or correcting is permanent in a way dismissing is not: once a reading
is a ruling of yours, later checks never offer it again, even when you rewrite
the scene that established it. Dismissing says *not so*, and your manuscript is
allowed to argue back. See [The Right
Column → Intent mode](right-pane.md#intent-mode-n).

## What you can do with a note

**Answer a question.** A conformance strain asks you something, and offers
**Answer**: type why, press Return, and your sentence becomes a **ruling** —
a dated, itemized line under that piece's intent, minting the statement if
you did not have one. The note goes away, and the next check reads the ruling
you just made, so answering is permanent rather than a dismissal you have to
repeat. Escape takes the field away without writing anything. See [The Right
Column → Intent mode](right-pane.md#intent-mode-n) for what a
ruling looks like and how to add one yourself, without a note to answer.

Answers go into the *piece's* intent, never the project's. An explanation of
what you were going for in this chapter belongs to this chapter; the project's
statement stays something you write deliberately, in the Intent pane.

**Keep it.** **Promote to Task** turns the note into a real task on the
document, carrying its own words plus one line recording who raised it, when,
in which model, which part of the report it came from, and what it was
checked against. That line quotes your intent as it stood at the moment the
note was raised — if you rewrite your intent later, older tasks keep naming
what they were checked against then, not what you have now. Tasks sync and
survive; the notes do not. ⌘Z takes the task back.

**Leave it.** A note you neither answer nor keep disappears at the next check.
If it still stands, the next check raises it again. That's the conformance
strain's own fate — a **This check** row works differently, because it's an
ordinary annotation underneath: **Got it** and **Not this** are its whole pair
of verbs, quicker than a ruling because the thing it's about isn't one, and a
row you leave untouched doesn't disappear at all. It's just no longer on this
screen — the next check replaces **This check** with its own findings, and
the note you didn't settle waits in your full queue instead.

**While a check is still running, you can read but not act.** The report
arrives section by section, so your conformance summary is on screen long
before the reader's report is written — that is what the streaming is for. The
notes under it carry no **Answer** and no **Promote to Task** until the check
finishes, and **This check**'s own rows carry no **Got it** or **Not this**
either, because a check that has not finished has not decided: cancel it and
those notes were never raised, let it run and it may say something different by
the end. The actions appear the moment the check is done, on the report it
actually settled on.

## Choosing how hard it looks

The gear menu in the pane's header picks the model: **Fast**, **Standard** (the
default), or **Deep**. The choice is per project and is remembered. Changing it
never interrupts a check already running — the one you are waiting for finishes
in the model it started in, and the next one is the one that changes. That
next check starts a fresh session behind the scenes, so it's a few seconds
slower than the warm session you're used to — a one-time cost of the switch.

**Cancel** appears in the header while a check is running. Anything the check
had already put on the pane goes with it — a report from a check that stopped
half way is not a report — and the last completed check comes back.

## What you need for it to work

- **Claude Code installed on your Mac.** The check runs it for you; you do not
  open it. If it is missing, the pane says so.
- **Claude access turned on** — Settings → General → *Allow Claude to connect
  (MCP)*. The same switch governs this as governs Claude Desktop. Turning it off
  stops any check immediately.

Checks use your own Claude account.

## What it will not do

It reads your manuscript and writes nothing into it. It cannot edit your prose,
your research, your palette, or your intent — including the rulings and the
bible it reads you against, which only you, through **Answer**, **Bless**, and
**Correct**, can add to.

Notes live on the Mac that produced them and are not synced. Losing them costs
nothing: press ⌘R again.
