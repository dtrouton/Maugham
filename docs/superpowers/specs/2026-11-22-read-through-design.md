# Read-through: a chapter under review by its own writer

Agreed with Denver in conversation, 2026-11-22. Part of the window-without-personas milestone
(`2026-11-16-subject-resolve-brief-shell-design.md`); it replaces that design's **Lock** and the
editor's hidden Manual Review Mode (⌘⌥⇧R). Nothing here is built yet; a plan is written against
the built code and brought to Denver before building.

## Why

The padlock was a leftover. The old Review persona made research, palette cards and figures
read-only as a side effect; when the personas went, that side effect became a toggle with a padlock
on it. It protected the things a writer is least likely to damage and left the manuscript live. No
writer's intent stood behind it. Separately the editor kept its own switch, Manual Review Mode,
which does stop typing into the manuscript, with no button and no connection to Lock.

Denver's words for the real intent: "If I'm reaching for the lock I want to protect that version and
work as a reviewer, leave comments for myself, but I am not ready to edit the text yet, or want to
let the thoughts settle as a distinct activity." And: "an intent I entered … should need my intent
to exit."

## What it is

A chapter (a piece, in a collection) can be put into **read-through**. It is a deliberate switch of
activity: the writer reads their own text as a reviewer would, leaves comments for themselves, and
lets the thoughts settle before editing.

## Behaviour (Denver's decisions)

- **Per chapter.** Each piece is either being written or in read-through. Clicking another piece
  opens it as it is. ("Per chapter sort of works as it aligns nicely for pieces in a collection.")
- **Entered and left by intent; remembered on this Mac**, across quitting, until the writer resumes
  writing.
- **A checkpoint on entry.** Starting a read-through saves a named checkpoint ("Read-through,
  22 Nov") of the piece, so the version reviewed can be compared with or restored from History.
  This is what "protect that version" means; the lock on one Mac is not the protection.
- **Typing is off; decisions are on.** The text cannot change by typing, pasting, dragging,
  autocorrect or Replace. Commenting, suggesting, answering notes, and accepting or rejecting
  suggestions all work, including those that change the text, because they are deliberate.
  ("Accepting and resolving is fine in this mode.")
- **The piece's research and figures follow the same rule:** readable and commentable, not edited
  by accident.
- **Very obvious.** The piece's tree row carries a lock; a quiet line stands over the text
  ("In read-through · typing is off · Resume writing"); no typing caret is drawn; the toolbar
  padlock shows and switches the open piece's state, with a menu item and a key.

## My calls, agreed by Denver ("looks good")

- **It does not sync.** Stored with the project's per-device UI state. Another Mac or the phone does
  not know the piece is in read-through; the checkpoint protects the version everywhere.
- **Read-through and reading a translation do not combine.** A translation is already read-only;
  read-through is a state of the source.
- **It never changes anyone's permissions.** It is the writer's own switch on their own Mac; posture
  still decides what a reviewer or collaborator may do, and read-through only ever adds refusals.
- **The name is "Read-through"**, not "Review", which already means editors' review passes and the
  Status board.
- **Window-wide Lock goes.** Nothing freezes research and figures on their own any more.

## Left to the builder

- Reuse the read-only membrane built for reading a translation (`EditorCoordinator`'s
  buffer-follows-fact guard, `isEditable = false`, the write-route tests) rather than a second
  mechanism; what Undo does while in read-through (accepting a suggestion must stay undoable).
- What Manual Review Mode did that read-through must keep (the selection toolbar's Comment /
  Suggest), and the removal of ⌘⌥⇧R and `WindowLock` with a capability census, as for the desk.
- The key, the menu title and the tree mark's look beside the existing marks (dot, ring,
  "Proposed", "new").
- Whether the Book or a Part offers "Start Read-through" for everything inside (not asked; default
  no).

## Size

A small plan of its own, about four tasks: the state and checkpoint; the typing guard; the tree mark,
line and toolbar; removing the two old switches.
