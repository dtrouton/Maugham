# ADR 0039 — Read-through: a piece its writer reads as a reviewer would, by intent, and the window's Lock goes

**Date:** 2026-11-22 · **Status:** Accepted · **Milestone:** shell-without-personas, the read-through plan (branch `claude/shell-without-personas`) · **Design:** `docs/superpowers/specs/2026-11-22-read-through-design.md` (agreed with Denver, 2026-11-22) · **Plan:** `docs/superpowers/plans/2026-11-22-shell-read-through.md` · **Supersedes:** [ADR 0035](0035-the-subject-not-the-persona.md)'s "Lock" section and its decision 14; it is [ADR 0038](0038-status-editions-and-translation.md)'s owed item 15

## Context

When the personas went ([ADR 0035](0035-the-subject-not-the-persona.md)), the old Review persona's side effect — research, palette cards and figures read-only — became a window toggle with a padlock on it: **Lock**. It protected what a writer is least likely to damage and left the manuscript live, and no writer's intent stood behind it. Separately, the editor kept its own switch, **Manual Review Mode** (⌘⌥⇧R), which stopped typing into the manuscript, with no button and no tie to Lock.

Denver's intent, in his words: "If I'm reaching for the lock I want to protect that version and work as a reviewer, leave comments for myself, but I am not ready to edit the text yet, or want to let the thoughts settle as a distinct activity." And: "an intent I entered … should need my intent to exit."

## Decision

### 1. A piece is being written or in read-through

**Decision** (the owner's). Per piece: each piece is either being written or in read-through, and clicking another opens it as it is. Entered and left **by intent** — View ▸ Start Read-through / Resume Writing, ⌘⌥⇧R, the toolbar padlock, the line over the text's Resume writing — and **remembered on this Mac** across quitting, in a per-device file (`ReadThroughStore`, `.maugham/read-through.<device>.json`). **Typing is off; decisions are on**: typing, pasting, dragging, autocorrect and Replace are refused; comment, suggest, answer, accept, reject and resolve all work, including those that change the text. **A checkpoint on entry**, the ordinary project-scope one, named with the piece ("Read-through, 22 Nov — Chapter Three"), which History can Compare with and restore from. It **does not combine with reading a translation**: Start is refused there ("Read Source to start a read-through"), Resume always works.

**Why.** It is the intent behind the padlock. The checkpoint is what "protect that version" means; the switch on one Mac is not the protection.

**Cost.** Two old switches go (Lock, Manual Review Mode). The state does not sync (section 4).

**Overrule if** Denver wants read-through to travel to his other devices, or to cover a Part or the whole Book.

### 2. One gate for everything that is not the editor

**Decision.** Every non-editor surface asks one value, `ReadThroughGate`, about its own target — a piece, a research item, a figure — and read-through only **adds** refusals: each site asks it beside the posture and the share, never in their place, and no permission reads it (`ReadThroughResearchSurfaceTests.test_readThroughNeverPermitsWhatPostureOrShareRefuses`). The window builds the gate once per change of the set, the book and its figure listing (`ReadThroughModifier.gate`) and hands it to the session's figure windows (`FigureWindows.setReadThrough`). The editor asks the same predicate (`ReadThrough.isOn`) about **the document its buffer holds**.

- **A piece's research** is a Collection piece's own folder (`researchScopePieceId`). A novel's shared research linked to a chapter is the book's and stays editable.
- **A figure's pieces** are the piece it was made in (`FigureRecord.piece`) **and** every piece whose text holds one of its lines. The centre's grid, a figure window, an editor's grid in place, the inspector, the tree's row and what is pulled up all ask this one rule, so ⤢ from a read-only grid never opens an editable window.
- **Find & Replace** leaves a piece in read-through, and a note in its folder, as they were, and names them; the research arm asks the gate's own rule.
- **A piece's research reads whole**: the item, and its inspector's Title, Caption, Tags, URL, Citation and Versions' Restore. **Bring Back to Figures** is refused over a figure whose piece is in read-through, as Send to Research is; making a new figure (Use in Document, New Table) is creation and refused by nothing.
- **Every refusal names the piece and how to resume it** (`ReadThroughGate.refusal`, the first refusing piece in tree order and how many more): the figure grid's reason (centre, window, in place), the figure inspector, the tree's row menu and drops, Restore, and Replace. A read-through piece's research, in the centre or pulled up, carries the line the text carries — "“Alpha” is in read-through · Resume writing" — and its Resume resumes that piece; the padlock over it names the piece and acts on it.
- **One gate per session**: each project window hands its gate to the session's figure windows, which combine them (`FigureWindows.setReadThrough(_:from:)`), so a window whose figure listing has not built cannot unrefuse a figure owned through a line.

**Why.** One answer cannot drift. "Only adds" keeps a reviewer's copy, a narrowed book and a view-only share exactly as strict as before.

**Cost.** A figure whose line moved to another piece reads while either piece is in read-through.

**Overrule if** a figure should follow only the piece it was made in (the permit's owner) — one line in `ReadThroughGate`.

### 3. Lock goes; the padlock is the piece's

**Decision.** The window-wide Lock (`WindowLock`, `LockToggle`, ⌘⌥⇧L, `.maughamToggleLock`) is deleted; ⌘⌥⇧L is left free. The toolbar padlock (`ReadThroughToggle`) sits in Lock's `.navigation` item: closed while the open piece is in read-through, open while it is written. It posts only what the window's offer gives (Start only while the piece's text is in the centre and a Start is allowed; Resume wherever the piece is open); with no offer it is drawn but disabled, its tooltip saying why, so the toolbar never shifts. Lock's capability census (`ReadThroughResearchSurfaceTests.test_everyLockCapabilityHasAHome`) gives each thing it did a home or a reason. **Refused by nothing now:** a palette card on the wall (no piece owns it), New Table (creation is not an accidental edit), shared research and an unowned figure.

**Why.** Nothing should freeze research and figures window-wide without an intent behind it.

**Cost.** Lock's palette, New Table and shared-research refusals are gone. A window that was locked, or in Review Mode, opens writing: the old settings are ignored, not migrated (tripwire 11).

**Overrule if** a writer asks for a window-wide freeze again: it would be a new decision, not this padlock.

### 4. Known limits

- **It does not sync.** The phone and other Macs do not know a piece is in read-through and may type into it; their typing lands here as a merge. The state file travels with an iCloud folder, but no other device reads it. The checkpoint's per-device file syncs, so other Macs' History lists it.
- **Typing undo before the entry is dropped.** ⌘Z cannot type back what was typed just before a Start (owner's R1); the checkpoint holds that version. A half-typed grid cell is **committed** at entry, with no undo — the words are kept; a writer who meant to cancel retypes after Resume.
- **Deliberate pre-entry steps survive.** Undo steps for an accept, a Restore from History or a tree move made before the entry stay, and ⌘Z in read-through may run them: ⌘Z is itself deliberate, and the checkpoint holds the reviewed version.
- **Two windows on one piece** both show Rewind on Compare.
- **A flush failure before the checkpoint is swallowed**, as ⌘S swallows it; a checkpoint that does not land says so and leaves read-through on, with Save one over the text where one could land.
- **Start only over visible text**: never enter a state whose line you cannot see.
- **Rename sweeps write into a piece in read-through, deliberately** (ruling, 2026-11-22). A piece rename's wiki-link sweep and a figure rename's cross-reference relabel rewrite the text of a piece in read-through: refusing them would leave dangling links in the book, and a rename is a deliberate act; the checkpoint holds the reviewed version (`ReadThroughReplaceTests.test_aRenamesLinkSweepRewritesAPieceInReadThrough_deliberately`, `FigureRenameTests.test_aRenamesRelabelRewritesAPieceInReadThrough_deliberately`). **Move into Figures is not a sweep**: it edits that piece's own figure line, so it is refused for a piece in read-through, naming it (the menu, the verb and `ProjectStore.retargetFigureLine`). `ReadThroughResearchSurfaceTests.test_everyDoorCheckedManuscriptWriterIsClassified` classifies every caller of `openManuscriptForWriting` and `holdManuscriptsForFigureText` as a deliberate sweep or refused.
- **A piece trashed and restored comes back writing.** Trash prunes its read-through entry (it left the structure); a restore does not bring it back.
- **A visit step on another window's stack** cannot write a figure one of whose pieces is in read-through: ⌘Z is refused, said with the piece, and the step stays for a ⌘Z after Resume. A refused ⇧⌘Z is said and its redo is lost (AppKit offers no way back onto the redo stack from outside a pass).
- **Writing Tools** is covered by `isEditable == false`, confirmed by reading; the Writing Tools coordinator itself is not driven by a test. Hand check owed.
- **The assistant's research writes are not refused** (ruling M1, 2026-11-22). `write_research_cells`, `create_research_table`, `update_research_citation` and `move_research_item` still succeed for a read-through piece's research. Read-through stops the writer's own accidental edits on this Mac; it is not a permission, and an assistant's research write is neither an accident nor manuscript text (`ResearchTableToolsTests.test_aReadThroughPiecesTableStillTakesTheAssistantsCells`, `ReadThroughResearchSurfaceTests.test_noMCPToolAsksReadThrough`). `add_note` is how the assistant comments.

## The owner's decisions (2026-11-22)

Per piece; entered and left by intent; remembered on this Mac; a checkpoint on entry, named with the piece (R3); typing off, decisions on; ⌘⌥⇧R (R2), Review Mode's old key, ⌘⌥⇧L freed; it does not combine with reading a translation; typing undo across the entry dropped (R1). The plan's calls 1–12 and questions P1–P4, H1–H2 were approved ("i am fine with your recommendations").

## Consequences

`WindowLock`, `LockToggle`, `LockTests`, `LockedResearchSurfaceTests`, `FigureGridGate.Reason.locked`, `FigureGridStrip.Plan.lockedAccept` and `PulledUp.lockApplies` are gone; `test_noLockNamesRemain` keeps them gone. `ReadThroughResearchSurfaceTests.test_everyReadThroughSiteAsksTheOneAnswer` counts every file that asks the answer (tripwire 50's shape). The guide, Help, the tour and the cheat sheet's wording are plan 5's.
