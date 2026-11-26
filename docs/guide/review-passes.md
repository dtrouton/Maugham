# Review Passes

A pass is a named stage of editing — Structural, Line, Copyedit, Proof, to
start with — and a chapter can stand at a different place on each one. Where
it stands drives the Book's Status, To resolve and the rounds, all from the
same handful of facts.

## Passes and the ladder

Every project starts with four passes: **Structural**, **Line**, **Copyedit**,
**Proof**. Edit the list from **Project Settings…** (⌘⇧,) — rename a pass,
add one, delete one, or drag to reorder. The order is advisory: it says which
pass a writer would normally reach for next, never which one they're allowed
to touch. Working Copyedit before Structural is a legitimate thing to do, and
Maugham never refuses it — see "A quiet nudge, not a gate" below.

Each of the four starting passes carries a **named editor voice** — Structural is **Perkins**, Line is **Lish**, Copyedit is **Gould**, Proof is **Argus** — and a **brief**: doctrine for what that pass's rounds attend to, and what they deliberately leave alone (Perkins reads for shape and never touches a sentence; Argus reads the surface only, and advises its rounds be run as Fresh Eyes). A round's notes carry that pass's editor as their author, so a list spanning several passes still tells you who's speaking. Renaming a pass in **Project Settings…** doesn't move its editor or its brief — both are tied to the pass's identity, not what you call it. A pass you add yourself starts with neither: its rounds are signed with the pass's own name instead of an editor's, and there's no brief behind them — nothing here yet lets you write one in, so a custom pass runs on general editorial judgment until that changes.

The coach, **Le Guin**, is not on this ladder and never was: she reads your
*checks*, and a check is filed in no pass at all. Neither is the
**first reader** you name yourself, who is the other person a check can be
handed to. See
[Checking Your Writing → Who reads a check](compiler.md#who-reads-a-check).
Because she isn't a pass, her name is reserved: adding a pass called
"Workshop" gets you a pass of your own with a distinct identity, not the
coach.

Where you rule on a pass is the **ladder** at the head of the chapter's
[To resolve](right-column.md#to-resolve-1) (⌘1). Each pass has a rung —
**Untouched**, **In Progress**, **Done**, or **Skip** — and beside them one
derived **status**: **Draft** while nothing's touched, **Revising** while any
pass is in progress or the chapter is partway up the ladder, **Final** once
every pass reads Done or Skip. Skipping every pass counts as final — skipping
is a decision, not an omission. Status isn't something you set; it's read off
the passes. It shows as the coloured dot on the chapter's row in the binder.

## Status

Click the Book (or a Part) and choose **Status** in the toolbar (⌃⌘3): one
row per chapter, the stage, one column per pass with a chip saying where
that chapter stands, then **Notes open** and **To-dos**.

The coach has no column here, because nothing on it is hers: what the passes
govern is rounds.

- **Click a chip** to open that chapter through that pass — it becomes the
  chapter's active pass, which is what To resolve's head and the next round read.
- **Right-click a chip** to ask that pass's editor for a round right there —
  *Run Gould's Round* — or set the pass's state, without opening the chapter.
  Asking for a round opens the chapter and starts the round once it's open.
- **A count** opens the chapter on what it counts.

A Collection piece that is really another project draws as a blank row — its
passes live in its own project.

## In To resolve

Each pass gets a filter chip in To resolve, named for the pass, and a note
sits under the chip of the pass it was written in. Notes from a check — Le
Guin's, your first reader's, or Claude's — are under **Checks**; a note written
with no pass active is under **Mine** or **Others**. See [Notes &
Suggestions](annotations-and-suggestions.md) for triage marks, Stet and
[answering a batch at once](annotations-and-suggestions.md#working-a-batch).
A note of your first reader's carries **Answer as ruling…**, which files your
answer as a standing instruction in her statement (see [Your own first
reader](compiler.md#your-own-first-reader)).

**Run**, at the head of the chapter's To resolve, is where you meet a round:
the chapter's lane — *Copyedit · Gould · round 2* — what changed since the
last one, and two buttons, **Run Gould's Round** and **Fresh Eyes**. **The lane
line is itself the pass picker**: click it to read the chapter through a
different pass, with the current one checked. No pass active yet? The line
reads *Set a pass to run a round*, and both buttons are off with a tooltip
saying why: *A round is an editor's. Set a pass and its editor runs the round.*

**A round that fails says so right there**, in red, in place of the usual
line — *"The check took too long and was stopped"* — and both buttons stay
live, because another round is the answer to a failed one. A round Claude
stopped talking to for three minutes says *Claude went quiet for 3 minutes and
was stopped*. While a round runs, the line counts the minutes and shows what
Claude has thought so far, with **Cancel** beside it; cancelling leaves you
where you were before you asked. While a check is running, or a round on
another chapter, the head says so — naming the chapter — and Run waits.

**The round's letter** is the latest letter at the head, when the round is
newer than your last check — the same letter a check writes, with the same
jumps, **Accept as To-Do**, **Add to intent** and **Keep this letter**. See
[Checking Your Writing → The letter](compiler.md#the-letter).

**A quiet nudge, not a gate.** Work a chapter through a later pass while an
earlier one is still open, and the head says so — *"Structural still open on
this piece"* — without disabling anything. **Mark done** and **Skip** sit
beside it, so you can close the earlier pass there. The passes are an order,
not a workflow the app enforces.

## Rounds and Fresh Eyes

Run a round — **Run** at the head of To resolve, or **⌃⌘R**, which the File
menu titles with the editor's name, *Run Gould's Round* — on a chapter with
an active pass, and the run is a numbered **round** in that pass's own count.
A round needs a pass: on a chapter with none set, it says so and starts
nothing. **⌘R** is the other loop — a *check*, filed in no lane and given no
round number — so nothing it does moves a pass's count. The report leads with
the distance travelled: *"Since round 4: 2 resolved · 1 persisting · 1 new"*
— counted from To resolve: notes from an earlier round of this pass
that you've settled since the last one, notes from an earlier round still
open in front of you, and notes this round raised. A finding this round
raised that you're holding in another pass's lane is counted separately, and
named — *"1 still open in Structural"*, or *"2 still open in Structural and
Line"* — since the three counts read only the pass the round was run in. A
note from one of your checks, which are filed in no lane, is named
*"your checks"*. Like the three counts it's live: settle that note in
Structural and the clause goes. (A round
filed before this version says *"1 was already open in another lane"*.) Round numbers are per pass, but the memory is the document's, not
any one pass's: Maugham remembers a document's last six finished rounds,
across every pass it's been worked through. Run enough rounds in other
passes and a pass you haven't touched in a while ages out of that memory —
the next round in it starts back at round 1, with nothing to compare against.
A check never ages a round out of that memory.

**⌃⇧⌘R** — *Run Gould's Round with Fresh Eyes*, or **Fresh Eyes** in the head — is a different kind of round: it ends the warm
session and reads the whole piece cold, as if for the first time. It's still
briefed on your intent, your rulings, your lessons ledger, and the bible, but
not on anything a previous round found — that's the point of asking for fresh eyes. Its report
says so at the top, in place of the since-last-round line: *"Fresh eyes"*, or
*"Fresh eyes · round 3"* when it's also filed against a pass. A cold read that
re-raised something you're holding in another pass says that here too —
*"Fresh eyes · round 3 · 1 still open in Structural"* — since the
since-last-round line it stands in for isn't there to carry it.

## The drift mark

Every round also answers one quiet question: does the draft still hold to
what you declared, or has it drifted? A run with no declared intent records
no verdict at all. A **drifted** verdict puts a small mark on the line
above the prose — *"intent may trail the draft"* — that stays until a later round comes
back **holds**, or until you edit the statement yourself. Nothing times it
out and nothing dismisses it; both of those are just the two ways the
question gets answered.

## What Claude sees, and what it can never set

Claude's read tools carry the same facts Status and To resolve draw from:
`get_outline` reports each piece's derived status and its per-pass states —
a pass with no entry there is untouched, the same reading the ladder gives
an unruled rung, and an entry under an id the ladder no longer
lists is a pass you deleted, kept so the states come back if you add it
again — plus the project's own pass ladder in order, each pass carrying its
**brief** (`null` for a custom pass with none of its own — see above), the
same doctrine a round is signed against;
`list_annotations` and `get_annotation` report a note's triage mark, which
pass it's stamped with, and — for a question a check raised under a habit your
ledger already names — that heading, so Claude can see which standing lesson a
note came out of. The coach is not in that ladder and never appears in
it — she isn't a pass — so her brief isn't reported there either: hers is the
preset's, fixed, and unlike a pass's it isn't something you can edit.
None of it is something Claude can write. Triage,
Stet, a piece's pass states, and your lessons ledger — which `read_lessons`
gives Claude in full — are yours alone: the same membrane that keeps Claude out
of your manuscript keeps it out of your review workflow too.
