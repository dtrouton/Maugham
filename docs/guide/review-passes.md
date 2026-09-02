# Review Passes

A pass is a named stage of editing — Structural, Line, Copyedit, Proof, to
start with — and a piece can stand at a different place on each one. Where it
stands drives the board, the queue, and the compiler's rounds, all from the
same handful of facts.

## Passes and the ladder

Every project starts with four passes: **Structural**, **Line**, **Copyedit**,
**Proof**. Edit the list from **Project Settings…** (⌘⇧,) — rename a pass,
add one, delete one, or drag to reorder. The order is advisory: it says which
pass a writer would normally reach for next, never which one they're allowed
to touch. Working Copyedit before Structural is a legitimate thing to do, and
Maugham never refuses it — see "A quiet nudge, not a gate" below.

Each of the four starting passes carries a **named editor voice** — Structural is **Perkins**, Line is **Lish**, Copyedit is **Gould**, Proof is **Argus** — and a **brief**: doctrine for what that pass's rounds attend to, and what they deliberately leave alone (Perkins reads for shape and never touches a sentence; Argus reads the surface only, and advises its rounds be run as Fresh Eyes). A round's notes carry that pass's editor as their author, so a queue spanning several passes still tells you who's speaking. Renaming a pass in **Project Settings…** doesn't move its editor or its brief — both are tied to the pass's identity, not what you call it. A pass you add yourself starts with neither: its rounds are signed with the pass's own name instead of an editor's, and there's no brief behind them — nothing here yet lets you write one in, so a custom pass runs on general editorial judgment until that changes.

### The coach's seat

Above the four passes sits one more editor who is **not** a pass: **Le Guin**,
the coach. She reads any piece you haven't assigned a pass to — which, if you
never open Review, is every piece you have. The four passes are stages of
finishing; she is the reader for work that isn't there yet, and what she
writes is a letter about the piece rather than a stack of line notes.

The seat sits outside the ladder on purpose. She is never a column on the
board, never a row in a piece's Inspector, and never something a piece can be
"done" with — assigning a pass is how you hand a piece to Perkins or Lish
instead, and setting that pass back to untouched is how you hand it back to
her. Because she isn't a pass, her name is reserved: adding a pass called
"Workshop" gets you a pass of your own with a distinct identity, not the
coach.

If you'd rather not have a coach at all, **vacate the seat** in **Project
Settings…** (⌘⇧,). An unassigned piece then goes back to the plain
all-altitudes reader, signed "Claude". Nothing is lost by vacating: her past
rounds stay in the piece's history, and restoring the seat brings her back
where she left off. There is no beginner mode and no experience setting — the
seat is simply your own declaration of what kind of writer you are today.

Where you actually *rule* on a pass is the piece's own **Inspector** (⌘⌥I).
Each pass gets a row there — **Untouched**, **In Progress**, **Done**, or
**Skip** — and above the rows, a read-only **Status** dot shows the one
derived verdict: **Draft** while nothing's touched, **Revising** while any
pass is in progress or the piece is partway through the ladder, **Final** once
every pass reads Done or Skip. Skipping every pass counts as final — skipping
is a decision, not an omission. Status is no longer something you set
directly; it's read off the passes you've ruled on.

## The board

The **Review** persona (⌘3) puts this front and centre. Select the project
row, or any group row, and the centre column shows the board instead of a
corkboard: one row per piece, one column per pass, a chip at every
intersection saying where that piece stands.

One line sits above the grid saying who holds the coach's seat — *Le Guin
reads any piece with no editor assigned*, or *The seat is vacant — an
unassigned piece gets the plain reader*. It is context for every row whose
chips are all untouched, not a control: vacating is Project Settings' row.
She is never a column here, and no piece is ever "done" with her.

- **Click a chip** to open that piece through that pass — it becomes the
  piece's active pass, which is what the queue and the compiler read next.
- **Right-click a chip** to ask that pass's editor for a round right
  there — *Run \<Editor\>'s round* — or set one of the four states
  directly, without opening the piece at all. Asking for a round takes you
  to the piece and starts the check once it's open; if it won't open, a
  capsule says **Couldn't open the piece — try again.** rather than leaving
  you waiting for a round that isn't coming.
- A trailing **Open** column counts each piece's unresolved notes; click
  the number to jump straight into the queue, scoped to that piece.

A Collection piece that's really another project draws thin and chip-less —
its own passes live in its own project, and a control here would be a
decision made in the wrong window.

## The queue

Answering what the board only counts is the **Annotations pane** (⌘⌥A) — see
[Annotations & Suggestions](annotations-and-suggestions.md) for triage marks,
Stet, bulk actions, and cross-document scope. The one thing worth knowing
here: the queue carries a **pass filter** alongside its others. Choosing a
pass shows every note stamped with it *plus* every unstamped note — a note
only carries a pass if one was active when it was written, so "unstamped"
covers everything older than passes, everything Claude wrote against a closed
piece, and everything made with nothing chosen. **Le Guin's notes show
under every pass**, for the same reason: she isn't a pass, so no choice in
that menu could bring them back once a piece she read is handed to Perkins
or Lish. Left alone, the filter
follows the piece's own active pass — the one a board chip click just set —
so clicking through from the board lands you already narrowed to the pass you
came from. Narrow that filter — or Kind, Author, or Triage — down to nothing
and the queue says so plainly, *"No notes match your filters,"* rather than
offering the empty queue's round-teaching as if nothing had ever been raised.
**Settle every open note instead and the teaching returns**, because that's
the ordinary empty queue, not a filtered one — none of those four filters is
what's standing between you and a note you've already resolved. That one
comes back through the show-resolved filter (the tray icon), not by widening
Kind, Author, Triage, or the pass.

**The round cockpit** sits between the queue's toolbar and its notes, in
document scope, and it's the second place you meet a round: the piece's lane
— *Copyedit · Gould · round 2* — what changed since the last one once one
exists, and two buttons doing exactly what ⌘R and ⌘⇧R do, **Run round** and
**Fresh Eyes**, so asking for the next round never means leaving the queue to
find ⌘R's other home. **The lane line is itself the pass picker** — click it
to read the piece through a different pass, with the one it's in checked, so
changing lanes never means going back to the board to click another chip. No
pass active on this piece yet? The line names the coach instead — *Le Guin
reads this piece* before her first round, *Le Guin · round 3* after — because
the piece already has a reader; the control is still the picker, so choosing
a pass hands it over. With the seat vacated it says *Set a pass*. **A check that fails says so right there**,
in red, in place of the usual line — *"The check took too long and was
stopped"* — rather than leaving the strip looking like a round that simply
came back with nothing, and both buttons stay live, because another round is
the answer to a failed one. **A run in flight can be cancelled right there** —
a Cancel button sits beside the checking line for as long as the round is
running, the same control Diagnostics offers, and pressing it lands you back
at Run round with nothing held against you: it's the same as a round you
simply hadn't asked for. **The last round's letter is one line under the
status line** — the one thing it would have you fix, or what it read the piece
to be about — and clicking it folds the whole letter open right there, the
same letter Author shows in Diagnostics, with the same jumps, **Accept as
task**, **Add to intent** and **Keep this letter**. See
[The compiler → The letter](compiler.md#the-letter). An empty queue teaches the
same loop rather than describing an absence: *"Claude proposes; you dispose.
Run Gould's round (⌘R), or ask Claude in Claude Desktop."* The editor it names
is whoever reads that piece — Le Guin on a piece you haven't assigned a
pass to, and nobody at all once the seat is vacated.

**A quiet nudge, not a gate.** Work a piece through a later pass while an
earlier one is still open, and a caption says so — *"Structural still open on
this piece"* — without disabling anything. Two small buttons sit beside the
caption, **Mark done** and **Skip**, so you can close the earlier pass right
there instead of leaving the queue for the Inspector's ladder or the board's
chip menu — and the nudge disappears the moment you do. The passes are an
order, not a workflow the app enforces.

## Rounds and Fresh Eyes

Press **⌘R** — *Check Writing* — while a piece has an active pass, and the
run is a numbered **round** in that pass's own count. A piece with no pass
set is the coach's, so its rounds are numbered in **her** lane and the
cockpit counts them the same way — it is only with the seat vacated that a
run belongs to no lane and mints no round at all. The report leads with
the distance travelled: *"Since round 4: 2 resolved · 1 persisting · 1 new"*
— counted from your own queue: notes from an earlier round of this pass
that you've settled since the last one, notes from an earlier round still
open in front of you, and notes this round raised. A note you're holding in
another pass's lane is counted separately — *"1 was already open in another
lane"* — since the three counts read only the pass the round was run in. Round numbers are per pass, but the memory is the document's, not
any one pass's: Maugham remembers a document's last six finished checks,
across every pass it's been worked through. Run enough checks in other
passes and a pass you haven't touched in a while ages out of that memory —
the next check in it starts back at round 1, with nothing to compare against.

**⌘⇧R** — *Fresh Eyes* — is a different kind of run: it ends the warm
session and reads the whole piece cold, as if for the first time. It's still
briefed on your intent, your rulings, your lessons ledger, and the bible, but
not on anything a previous round found — that's the point of asking for fresh eyes. Its report
says so at the top, in place of the since-last-round line: *"Fresh eyes"*, or
*"Fresh eyes · round 3"* when it's also filed against a pass. A cold read that
re-raised something you're holding in another pass says that here too —
*"Fresh eyes · round 3 · 1 was already open in another lane"* — since the
since-last-round line it stands in for isn't there to carry it.

## The drift mark

Every round also answers one quiet question: does the draft still hold to
what you declared, or has it drifted? A run with no declared intent records
no verdict at all. A **drifted** verdict puts a small mark on the intent
strip — *"intent may trail the draft"* — that stays until a later round comes
back **holds**, or until you edit the statement yourself. Nothing times it
out and nothing dismisses it; both of those are just the two ways the
question gets answered.

## What Claude sees, and what it can never set

Claude's read tools carry the same facts the board and the queue draw from:
`get_outline` reports each piece's derived status and its per-pass states —
a pass with no entry there is untouched, the same reading the Inspector's
ladder gives an unruled row, and an entry under an id the ladder no longer
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
