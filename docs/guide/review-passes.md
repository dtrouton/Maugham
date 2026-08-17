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

- **Click a chip** to open that piece through that pass — it becomes the
  piece's active pass, which is what the queue and the compiler read next.
- **Right-click a chip** for the four states directly, without opening
  the piece at all.
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
piece, and everything made with nothing chosen. Left alone, the filter
follows the piece's own active pass — the one a board chip click just set —
so clicking through from the board lands you already narrowed to the pass you
came from.

**A quiet nudge, not a gate.** Work a piece through a later pass while an
earlier one is still open, and a caption says so — *"Structural still open on
this piece"* — without disabling anything. The passes are an order, not a
workflow the app enforces.

## Rounds and Fresh Eyes

Press **⌘R** — *Check Writing* — while a piece has an active pass, and the
run is a numbered **round** in that pass's own count. The report leads with
the distance travelled: *"Since round 4: 2 resolved · 1 persisting · 1 new"*
— counted from your own queue: notes from an earlier round of this pass
that you've settled since the last one, notes from an earlier round still
open in front of you, and notes this round raised. Round numbers are per pass, but the memory is the document's, not
any one pass's: Maugham remembers a document's last six finished checks,
across every pass it's been worked through. Run enough checks in other
passes and a pass you haven't touched in a while ages out of that memory —
the next check in it starts back at round 1, with nothing to compare against.

**⌘⇧R** — *Fresh Eyes* — is a different kind of run: it ends the warm
session and reads the whole piece cold, as if for the first time. It's still
briefed on your intent, your rulings, and the bible, but not on anything a
previous round found — that's the point of asking for fresh eyes. Its report
says so at the top, in place of the since-last-round line: *"Fresh eyes"*, or
*"Fresh eyes · round 3"* when it's also filed against a pass.

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
again — plus the project's own pass ladder in order;
`list_annotations` and `get_annotation` report a note's triage mark and which
pass it's stamped with. None of it is something Claude can write. Triage,
Stet, and a piece's pass states are yours alone — the same membrane that
keeps Claude out of your manuscript keeps it out of your review workflow too.
