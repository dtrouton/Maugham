# ADR 0036 — To resolve: one right-column face for what has been raised

**Date:** 2026-11-18 · **Status:** Accepted (plan 2 of a multi-plan milestone; see "Not yet built") · **Milestone:** shell-p2-to-resolve (branch `claude/shell-without-personas`) · **Design:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md` ("To resolve", "Constraints") · **Builds on:** [ADR 0035](0035-the-subject-not-the-persona.md)

## Context

After [ADR 0035](0035-the-subject-not-the-persona.md) the window's right column was still three panes about the same piece: Annotations (notes), Diagnostics (a check's strains) and Tasks (to-dos), each with its own scope switch (This Piece / All Pieces), its own filters and its own empty states. The writer asked one question of them, "what has been raised that waits on me?", and had to ask it three times. The panes also needed the piece open in the editor (ADR 0035's stopgap: with the canvas in the centre they showed empty states).

## Decision

**To resolve** (`RightColumnPosition.resolve` since [ADR 0037](0037-brief-and-the-pulled-up-thing.md); `Maugham/Views/Resolve/`) is one list of everything raised on the faces' subject that waits on the writer: open notes, a check's conformance strains (findings) and open to-dos. It replaced the three panes. It is the first of the right column's positions and bound to ⌘1.

### Show without loading; act only on the open piece

*Decided by the owner, 2026-11-18.*

- **Read.** `ResolveReader` reads a scope from store-level sources only: the project's annotation walk and task walk (each cached whole by `ProjectStore`, and held by the list between real cross-piece signals, below), the open pieces' own `Document`s for their notes, to-dos and order, the diagnostics sidecar, and `currentParagraphState` (the open document's, else `DerivedManuscriptCache`). It never calls `Document.load`, loads nothing transiently, and registers no document (`ResolveReaderTests.test_noResolveSourceLoadsADocument`). Nothing loads a second document.
- **Act.** A verb that is a `Document` method (accept, reject, stet, triage, reopen, delete or restore on a note; toggle, archive, delete or reorder on a to-do; the bulk bar) is offered only where the row's piece is the one open in this window's centre and its document is registered (`ResolveVerbGate.mayAct`). The gate only removes: posture still decides what the open piece offers (tripwires 47, 51).
- **A row on a piece that is not open** is readable, offers none of those verbs (hidden, never disabled), and its click opens the piece on that paragraph through the existing going-to-a-place path (`ResolveNavigation`, `ManuscriptNavigation`): the row then offers its verbs. **In a Book or Part list the click opens the piece inside the faces** (`ClickRule.openInsideTheFaces`, the owner's ruling, decision 24): `open` becomes the piece and the faces, and so the list, stay where they were; the opened piece's rows gain their verbs and its group follows the caret. At a piece's own scope the click is the ordinary place (`open = faces = piece`), as is every other going-to-a-place path (find, wiki links, history, Claude's Show, sluglines, report rows).
- **Offered everywhere, by posture:** a finding's Answer (it files a ruling, no `Document`) and a note's Keep as lesson. A Book-level to-do lives on the project stream, which needs no `Document`, and keeps exactly the verbs its posture gives it.
- **Why.** Accepting or rejecting a note is a judgement about a sentence: the writer should be looking at it. And loading a piece is not a read-only act: a second live `Document` on a path is the paragraph-loss defect, and a load's ops would sit where the writer's ⌘Z never reaches.

### Sources, and the two lifetimes

`ResolveFilter.source(of:localName:)` gives every item one source, the first row of this table that matches: **Questions** (the note carries a `language`: a translator's query), **Checks** (a finding, or a note with a `compilerRunId` and no `compilerRound`), **Mine** (a to-do, or a note the local writer owns), **its pass** (`reviewPassId`), **Others** (everything else). Sources are single-valued by design. An unstamped note is Mine or Others and a coach-lane note sits under its own pass chip; neither appears under another pass's chip, where the old queue showed both under every pass. Filtering by source is the design; multi-select covers "Perkins plus the coach".

Two lifetimes: a **finding** is a sidecar strain and is replaced by the next check (`ResolveItem.isReplacedByTheNextCheck`); everything else stays until settled. Each item appears once: a check's continuity question, reader report or letter question is a note and is listed as the note, captioned "From the check".

### Grouping

Pure, once per refresh (`ResolveGrouping`, tripwire 4). In a piece: Whole chapter, then one group per paragraph in order; in a screenplay, Before the first scene, then one group per scene (keyed by the paragraph its slugline begins). Then "No longer in the text" (always last, never dropped) and the piece's own figures' notes (a figure's notes sit on the piece that owns it, by the board's rule). A piece whose paragraph order would not read has one "Position unknown" group instead, never placed by guess. At Book scope: the Book's own to-dos first, then one group per piece, then one group per figure with open notes, whether a piece owns it or not (after all the pieces, not beside their owners). A Part: one group per piece, then the figures its pieces own; it holds no Book to-dos and no unowned figure. A screenplay's Book is its one script, still holding the Book's to-dos. Inside every group: notes in `AnnotationQueueOrder` (triaged Do first), then findings, then to-dos by priority. A scope that held a piece or figure that would not read says so ("may be incomplete", RULING-54) and never looks complete.

### Filters, density, the caret, the triage control

- Chips: one per source with items in scope, in the column's order (each pass in manifest order, Mine, Checks, Questions, Others); a pass the manifest no longer lists keeps a chip after the listed ones.
- **Density at 12** (`ResolveFilter.singleChoiceThreshold`), counted after the triage filter: at or below, any subset of chips and every group open; past it, one chip at a time and only the caret's group open (`ResolveFilter.cursorGroup`, the open piece's caret paragraph or scene; in a Book or Part list that holds the open piece, that piece's group; no walk per caret move). A dense list with no caret group opens no group (so a dense Book with no piece open is wholly collapsed). A focus request (the board's count) opens the piece's group, else its first owned figure's, and gives the filter way when the filter hides that group.
- **The triage control** (the owner approved it 2026-11-18): All / Do / Discuss / Decline / Untriaged, `AnnotationTriageFilter`'s own vocabulary, separate from the source chips and ANDed with them. It is shown only while a note in scope carries a mark (a quiet chapter gains no furniture), applies to notes only (findings and to-dos show under All only), names its active choice in a word beside the icon, and the choice persists across scope changes (hidden control means All). **Declined notes stay in the list**: a mark is a decision about a note, not its settlement; they are reachable under Decline and still count as open until resolved.

### The head

For a piece: the pass ladder (state, derived status, the pass-order nudge, the drift line; a pass state is a manifest write, so it is offered by posture whether or not the piece is open), the latest letter (the newer of the check's and the round's by run time, keyed by piece and run so a refusal raised on one letter is never drawn under another), then the Run block (the round cockpit, and the check's own header: reader, Reread, Ask, status). Run and Accept as task are offered on the open piece only; elsewhere one link-styled line opens it, saying "Open this chapter to answer its notes" where the piece has notes or to-dos (whose verbs act only on the open piece), else "Open this chapter to run a check or a round on it" (the project's noun for a piece; ADR 0037, appraisal wave). A Book or Part list's group whose piece is not open carries the first line under its header, and opens the piece inside the faces, as a row's click does. One model menu. There is no Check Writing button: ⌘R is the check and the head's Run is the round. A Book or Part's head is one line counted from the unfiltered snapshot (pieces with something open, Book to-dos, notes on figures no piece owns); it never says "Nothing to resolve" above a non-empty list.

### Settled

A collapsed last section, read only when opened. On the open piece (`.piece` scope): resolved notes (Reopen needs the piece open, RULING-29; Revert, RULING-31), deleted notes (Restore, RULING-34), done to-dos with Archive all done (hidden when the posture files no task), and **Archived** to-dos with Unarchive only: there is no delete op for to-dos, and an archived inline to-do cannot be unarchived (its words were spliced out of the text; a status change cannot restore them) and says why. At Book scope, **Settled on the Book** holds the Book-level to-dos on the project stream (un-tick, archive, delete, Archive all done); in the old Tasks pane those verbs were silent no-ops, and now work. **A figure's settled notes** (RULING-29) are listed at the figure's own scope ("Settled") and at its owning piece's ("Settled on its figures"), out of the held walk, through the list's figure row: Reopen is offered by the figure's posture and lands through the figure's host, with no piece open. A withdrawn figure note has no figure verb to restore it and is not listed.

### Keys and the unread dot

⌘1 opens To resolve. A translation round report's **Open the queue** opens the round's piece (`open = faces = piece`, the report is drawn over an edition, which has no list) and then asks for Questions (`TranslationRoundReport.openQueue`). ⌘⌥A, ⌘⌥D and ⌘⌥T keep their keys and open it on their filter (Rounds, Checks, Mine) through `MaughamEvent.postResolve`; each is inert when its chip is absent, leaving the writer's selection as it was. A dot (never a number) marks To resolve in the picker and the Checks chip while a check's notes are unread; showing the checks clears it.

### Refresh

Three keys. The **read key** (`ResolveReadKey`: scope, the annotations token, which of the scope's pieces are open, the project task version, the diagnostics version, the passes and local name) re-runs the sidecar and the reader. **The project walks run only on real cross-piece signals** (`ResolveWalkHold`, review C1): an annotations event about a document no window holds open (a closed piece's op log, a figure's stream, a peer's sync), a piece in scope opening or closing, a scope change, the Book's own to-dos; any other read gathers over the walks it holds. The **list key** (`ResolveListKey`) adds the open in-scope pieces' `annotationsVersion` and `tasksVersion`: a keystroke, a burst flush, a note minted on an open piece (a round's arrival, or MCP `add_comment`, `add_suggested_change`, `add_query` or `add_craft_note`) and a verb on one splice that piece's live notes, to-dos and order off its `Document` and run no walk (`ResolveTypingPathTests`; measured on 30 closed pieces, a burst flush or a mint went from both walks, about 51 ms, to under 0.3 ms). The **regroup key** adds the window's parsed screenplay: a new parse re-reads only the open piece's paragraph state and regroups what is held. A note just stetted is **held for its 2.5 s flourish** on the live stetted note (the row offers Reopen alone), then leaves.

### The tree's dot

A row with anything To resolve would list carries one small accent dot at its trailing edge, never a number (`ResolvePresence`, shell plan 4): a piece with an open note, an open to-do or a live strain (a figure's notes on its owning piece); a Part when any piece under it does; the Book for its own to-dos, an unowned figure's notes, or anything inside it (owner, 2026-11-21); in a screenplay, the scene an item's paragraph falls in. A reference piece carries none. A piece that would not read, with nothing listed on it, draws a hollow ring ("Could not be read", RULING-54; the pieces Status draws an em dash for); a Part or the Book over it rolls up as a ring only when nothing inside carries a dot. The read is mounted on the window (`ResolvePresenceWatch`, `ResolvePresenceReader`), so it runs with the tree hidden; rows ask `ResolvePresence.rowMark`. Unlike To resolve's list it never walks when a piece opens or closes (the open piece is read off its `Document`, a closing one folds in its last live state), it re-marks without a read when Parts are rearranged or a figure changes owner, it coalesces a burst of closed-piece events into one walk, and it reads the sidecars off the main actor. **No step of it holds the main actor for a walk**: the closed pieces are read off the main actor eight at a time (`ResolveChunkedWalk`, each read exactly as the store's walk reads it, one load per piece for its notes and to-dos), each chunk folded in as one main-actor step, and the marks fill in as the chunks land — a piece not yet read draws nothing, never the ring. A change arriving mid-walk is neither lost nor counted twice (a chunk replaces its pieces' entries; a chunk from a walk the token has moved past is dropped). Measured on 200 closed chapters (`ResolvePresenceCostTests`): opening or closing a chapter went from a full walk, about 825 ms, to about 1 ms (fix round 1); the first read when a window opens, and a burst's one walk, went from one main-actor step of about 680 ms to about 28 steps whose longest is about 3 ms (22–27 ms of main-actor work in all, about 590 ms of wall time off it) (fix round 2). Two windows on one project share one `ProjectStore` but each window's watch walks for itself, off the main actor. Progress is monotonic (fix round 3): a walk reads first what it has never read, and skips a held piece whose op-log fingerprint, trust and manifest facts are unchanged, so a walk restarted by a steady cadence of events always reaches the end of the book (a quiet re-walk at 200 chapters reads nothing; its producer spends about 90 ms resolving trust and under 1 ms checking fingerprints); a figure added or removed during a walk is read on the next one, because the walk records the figures it read, not the manifest's; a cancelled walk applies nothing more and its producer stops before its next piece or figure, holding only values. **Known costs, accepted:** each window's walk occupies one cooperative-pool thread for its length (about 600 ms at 200 chapters); the first `ProjectStore.projectLevelTasks()` in a store's life can be its first `ensureProjectOpLogLoaded()`, a trust resolve and the project log read on the main actor, once; and each window holds every closed piece's paragraph text, read only to judge an anchored strain.

### What was deleted, and what moved

`AnnotationsPane`, `DiagnosticsPane` and `TasksPane` (and their `DetailSegment` cases `.annotations`, `.diagnostics`, `.tasks`); the This Piece / All Pieces switch; the triage filter's old home (the queue) and the author filter; the pass filter (`AnnotationPassFilter`); the old queue's toolbar. Moved into `Maugham/Views/Resolve/`: the note row host and verbs, to-do verbs, the bulk bar, the check's statics (`CheckNarrative*`), the letter host and the round cockpit mount. The mounted `DiagnosticsPaneTests` were retired or re-pointed at the live gate; each guard that still ships was kept on a To resolve census.

### Gone by design, for the owner's eye

- The yield notice with Edit Anyway on a piece that is not open (nothing acts on such a piece now; its click opens it).
- Double-click and Return on a to-do (a click goes to its place).
- The old queue's empty-state teaching.
- The author filter. The inclusive pass filter (single-valued sources, above). The old queue's kind filter (comment / suggestion / query): the chips are sources, not kinds.
- No capture-to-canvas drag in one window (from plan 1).

## Not yet built

- Built in [ADR 0037](0037-brief-and-the-pulled-up-thing.md): the Brief, the pulled-up thing and the fold, ⌘2 and ⌘3, and the check's strains and silent-clause readings (drawn as marks on the intent in Brief; a clause the draft holds draws nothing).
- The translator's letter at the head (a `TranslationRound`, kept per language) and edition scope. The translator's changes (the design lists "questions and changes"; only questions, a note carrying a `language`, are built).
- Glossary proposals, design proposals, compile problems and figure source-changed items in To resolve.
- Status views; the margin setting; the rewrite of the guide, the welcome tour and Claude's help text (`docs/guide/annotations-and-suggestions.md` and others still describe the old panes). The translation round report's interim pane still uses the old "ruled" sentence.

## Consequences

- One question, one list; the right column no longer needs the piece open to show what is raised on it.
- A writer on the canvas sees a piece's raised items but must open the piece (one click on a row) to act: the cost of never loading a second document.
- Known limits: a note on another piece lands the click on its paragraph, not the exact span; a warm check has no Check Writing button.
- A Book or Part list survives a row click (decision 24), so the subject can now be a piece open in the centre with the Book or a Part on the faces; the tree draws the faces' row selected, as what was clicked last.

## Decisions made during the build

Each was a ruling taken in the build ledger on the agent's authority unless it says it was the owner's. Cost-if-wrong is cheap in each.

1. **Owner, 2026-11-18:** read anywhere, act only on the open piece; a row click opens the piece. Keep the Others filter. Accept the clause-reading gap until the Brief. A separate triage control (yes).
2. A piece's own figures' notes appear at that piece's scope (agrees with the board's open-notes count).
3. A screenplay's Book scope includes the Book-level to-dos, otherwise they are unreachable in a screenplay.
4. The refresh key is split into a read key (no script) and a regroup key (with it).
5. One model menu in the head if the cockpit's and the check header's bind the same setting.
6. The Book or Part head counts from the unfiltered snapshot and includes Book-level to-dos; "Book figures have notes open" is accepted for figures no piece owns.
7. No Check Writing button in the head; ⌘R is the check, Run is the round. Denver may want one at smoke.
8. The stet flourish is kept: a stetted note stays for its 2.5 s before it leaves.
9. The Book's own done to-dos get a Settled section at Book scope.
10. A to-do with no paragraph anchor has no click target.
11. Archived to-dos get an Archived group in Settled (every data type needs a surface).
12. Within a group, notes keep the old queue's triage order.
13. A finding row on the open piece keeps one-gesture "Not this".
14. The triage filter and the author filter are gone from the old queue (the design filters by source only); the triage control is the owner-approved replacement.
15. Dead code from the deleted panes was culled and its posture pins moved onto the live gate: dead statics with passing tests are false assurance.
16. Archived to-dos offer Unarchive only (no delete op exists); an archived inline to-do is listed without Unarchive and the row says why.
17. Single-valued sources stand: an unstamped note is Mine or Others, a coach-lane note sits under its own pass chip.
18. Declined notes stay in the list (the owner did not say where they go).
19. The triage mark shows read-only on stetted and settled rows.
20. When a triage choice is on, the control names it in a word.
21. The dense rule counts items after the triage filter.
22. The triage choice persists across scope changes.
23. Tripwire 52's counted list for `ResolveTaskVerbs.swift` rose from 2 to 4: the Book to-do verbs' two project-stream appends are real new writers, each asking its posture first (they were silent no-ops before).
24. **Owner, 2026-11-18 (final review I1):** a row click in a Book or Part list opens the row's piece in the centre and leaves the faces where they are; the list stays, the opened piece's rows gain their verbs and its group follows the caret. A distinct navigation (`ClickRule.openInsideTheFaces`, posted only by `ResolveNavigation.goInsideTheFaces`); every other place keeps `open = faces = piece`.
25. The project walks are held by the list and re-run only on real cross-piece signals; the open pieces are read off their `Document`s (final review C1). Document note verbs no longer bump the walk token; a figure verb still does.
26. A figure's settled notes get a Settled section at the figure's scope and its owning piece's (final review I2, RULING-29).
27. Open the queue on a round report opens the round's piece, then asks for Questions (final review I3).
28. A dense list with no caret group opens no group (a Task 3 ruling that superseded the plan's "first group"; final review M2).
29. A focus request falls back to the piece's owned figure's group and unhides its group when the filter hides it (final review M1).
