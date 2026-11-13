# Hardening: the open issues of 2026-11-11 — design

Branch `claude/hardening-2026-11-11`. One branch closes #136, #137, #138 and #139, and checks
`FigureDocument.swift` off #106's list. #106 itself stays open as a standing ruling.

Sources: each issue's body (`gh issue view N`), `docs/superpowers/notes/2026-11-08-sweep.md`, and
two read-only verification passes run on 2026-11-11 against HEAD `7a9607f8`, whose corrections are
folded in below. **Line numbers in the issues have drifted (the note-versions branch merged on
11-10/11): find code by symbol, not by line.**

## Intent

Denver, 2026-11-11, on the list of open issues: "we don't want to allow corruption."

Three of these issues let the writer's work or its history go wrong without saying so:

- a figure suggestion left open over a cell that already holds its value, where Accept then records
  the suggested value as the "before" value and undo can never reach the original (#136);
- a Research table's last edits dropped at close (#138);
- an update that hides its own "ready" state and can re-stage while the installer runs (#137).

The branch closes every route to those states that we know of, and puts one guard at the root
(Accept itself) so a route we have not found cannot corrupt the undo history either.

## Goals

1. No figure suggestion is ever left open, by Maugham's own travel, over a cell that already holds
   its suggested value.
2. Accepting a suggestion whose value is already in place never writes a `prior` equal to its
   `next`, however that state was reached.
3. The checkpoint revert sheet tells the truth about figure notes before and after (RULING-28).
4. A Research table's edits survive a close when the version cannot be kept or the save fails.
5. A background update check never disturbs an update that is ready or installing.
6. The docs and counts the sweep found stale are true again, and the Annotations count cannot
   drift silently again.

## Non-goals

- No new feature and no new UI surface beyond sentences in existing sheets and notices.
- No amendment-judging of `get_annotation`'s history (W7): raw history is deliberate on both the
  figure and the manuscript side. Only the two-read race is fixed.
- No tidy-up milestone for #106's other fifteen files.
- No data migration (tripwire 11).

## Anti-goals

- A fix that makes the figure rule and the manuscript rule diverge further.
- A restore that quietly ignores another device's cell-moving lines in order to tolerate a note
  arriving mid-restore (W6).
- Saving a Research table over an outside change it has not seen (R3) in the name of not losing
  edits (R1).

## Rulings taken in this sitting (Denver, 2026-11-11, structured questions, each a recommended option accepted)

These go into `register/RULINGS.md` as the next free numbers, basis recorded verbatim as
`RATIFIED_FROM_OPTIONS`, with the example put to him. Regenerate `ruling-hashes.json` by the
register's own script; never by hand.

**R-A. Figure suggestions follow the manuscript's rule on a checkpoint revert (RULING-57's
family).** A revert changes a suggestion only where it rewrites that suggestion's cell. A
suggestion on a cell the revert does not write keeps its status. The one figure-only arm: a
suggestion whose row or column does not exist at the checkpoint is archived, because a figure
revert can remove cells and a manuscript revert never removes a paragraph. Example put: "you type
12 by hand, take a checkpoint, then accept a suggestion for 12; reverting reopens it over the 12."
Accepted consequence, stated in the option: accept a suggestion, type the old value back by hand,
revert, and the note now stays accepted where it used to reopen.

**R-B. Accept is guarded at the root.** When the cell already holds the suggestion's value, Accept
marks the note accepted and writes nothing to the cell. Figures now. The manuscript too if the same
sequence reproduces there; otherwise the manuscript gap is filed in the register. Example put: the
phone rejects or archives a suggestion just after the Mac accepted it, a reopen leaves it open over
its own value, and accepting again records the suggested value as the "before" value.

**R-C. A Research table closes the way a note does.** At close, the edits are saved even though the
previous version could not be kept. If the save itself fails, the edits are written as a backup
copy under `.maugham/conflicts` and the notice names the file. This inherits the notes' interim
"save anyway" rule (`ResearchNoteDoor.whenTheKeepFails`); if that interim rule is later changed,
tables change with it.

## Design

### 1. Split first (#106's ruling)

W1, W3 and W4 are substantial work in `FigureDocument.swift` (2,382 lines), so the ruling fires:
the first commit is a no-behaviour-change split, in the foundations plan 4 style (a child type or a
pure Core function, not an extension sharing all the state).

- **The note walk moves to MaughamCore** as a pure function over ops, amendments, the pointer, the
  current table (it resolves notes and leaves out withdrawn ones, as `annotations()` does), the
  target state and the restore's cell changes. `noteLifecycleKinds`, a private static on
  `FigureDocument` today, moves with it. It returns the note plan: which cell changes carry a
  note line, and which notes get a status-only line or an archive. Nothing in it touches the host.
  Its home is `Packages/MaughamCore/Sources/MaughamCore/Table/`, beside `FigureRestoreDiff`. This
  is the function W3 needs anyway, since the sheet must count from the same walk the restore acts
  on, and tripwire 19 wants one implementation.
- **The checkpoint restore section** (`restoreToCheckpoint`, the picture keeping, the park reads,
  `lastRestoreNotes`, the test seam) moves out of `FigureDocument` into a child type the host owns,
  which reaches the host through the narrow set of verbs it uses today (`requireWritable`,
  `commit`, `mayHere`, `reloadGeneration`, the open-cell-notes hold).

The existing `FigureRestoreTests` and `FigureAnnotationDispositionTests` pass unchanged across this
commit. That is the proof of no behaviour change. The builder may adjust the exact seam of the
child type against the real file; the Core function is not optional.

### 2. Figure notes on a checkpoint revert (#136 W1, W3, W4)

One walk, three classes, mirroring `RewindImpact.travelStatusChanges`:

| Class | When | What the restore writes |
|---|---|---|
| **Stranded** | accepted now; not accepted at the checkpoint; the restore rewrites its cell | the cell change becomes the note's `claudeAcceptRevert` (cell and note in one op), as today |
| **Returning** (new, W1) | open now after a revert; accepted at the checkpoint; the restore rewrites its cell back to the accepted value | the cell change becomes a `claudeAccept` carrying `sourceAnnotationId`, checkpoint-stamped |
| **Gone** | accepted now; its row or column does not exist at the checkpoint | `claudeArchive`, status only (or a status-only reopen where this hand may not dispose, as today) |

Everything else is left alone (R-A). In particular:

- **Accepted at the checkpoint and accepted now** is never stranded, "however many Reverts and
  re-accepts came since": the figure walk gains the manuscript's `acceptedAtTarget` guard. This is
  the fix for the verification pass's cases 1 and 2 (accept, checkpoint, ⌘Z, ⇧⌘Z, with or without
  a later hand edit).
- **A cell the restore does not write** gets no status-only reopen. That branch is removed. This
  changes `test_aRestoreReopensWhereTheCellStands_andArchivesWhereItIsGone`: its "reopens where the
  cell stands" half is re-pinned to "stays accepted", by R-A.
- "Accepted at the checkpoint" is judged over honoured lifecycle lines only, as the walk does now.
- **The Gone class stays a separate status-only list.** A deleted row or column is a
  `figureStructure` change, not a `figureCellSet`, so no cell change carries it. Its existing
  fallback also stays: where this hand may not dispose of a note, the note is reopened status-only
  over the missing cell. That is not the state R-A forbids, since there is no cell holding its
  value, and Accept refuses an orphaned anchor.
- **Two implementations, one rule.** The manuscript's walk (`RewindImpact.travelStatusChanges`)
  stays in the Mac target and the figure walk goes to Core. They are kept in step by tests that
  name each other, not by sharing code. The figure walk cuts at the raw pointer and does not adopt
  `momentEnd`: a checkpoint pointer landing among a figure restore's own trailing note lines needs
  a checkpoint taken mid-restore. If the builder finds that reachable, it is filed in the register,
  not fixed here.

**The sheet (W3, RULING-28 both halves).** `PartialRestorePicker.revertNotes(for:)` counts figure
notes for the figures in scope from the same Core walk, behind the same door the restore asks, and
its confirm sentence names them with the documents' counts. The count comes from a read-only
"what would this restore do to notes" answer on the figure host, which runs the same preparation
`restoreToCheckpoint` runs (the door, the two skips, the park reads, the diff, the two `mayHere`
answers) and stops before writing; the restore itself calls the same preparation. The sheet
borrows a host per figure through the store's existing door for that. A figure the restore would
skip, or refuse outright, is left out of the count, as a document behind a closed door is. `FigureRestoreNotes` gains
`reaccepted`; `figureSentence` reports it AFTER ("restored to accepted"), in the manuscript toast's
words. BEFORE and AFTER come from one function so they cannot disagree.

**Tests.** A figure twin of `RewindReturningAcceptTests` (the returning class, including "Reject is
never offered over the returned value"); the `acceptedAtTarget` cases 1 and 2; the untouched-cell
case 3 (type the value, checkpoint, accept, revert: stays accepted); the gone arm unchanged; the
sheet's BEFORE count equal to the AFTER report for a mixed revert. Core tests for the pure walk.

### 3. The Accept guard (R-B; #136 W2)

In the figure accept path (`FigureDocument+Annotations`): when the anchored cell's content already
equals the suggestion's value, Accept emits a **status-only `claudeAccept`** with no cell payload,
so no `prior` is recorded. This is Mac-only work: the phone never accepts a figure suggestion
(`acceptsOnlyInTheTable`).

**The way back.** A figure suggestion's accept is taken back by ⌘Z in the grid and by nothing else:
the pane offers no Revert for figures, and `FigureAnnotationOps.reopen(for:)` refuses an accepted
suggestion (`.acceptedInTheTable`). The guarded accept keeps that shape. Today a status-only
`claudeAccept` registers no undo, because `registerFigureUndo` builds its inverse from `op.figure`
and there is none. So the guard adds one ⌘Z arm: it writes the note's status-only reopen and leaves
the cell alone, and inside an open grid visit it folds into the visit's one undo like the visit's
other steps. The existing ⌘Z of a stet or an archive (a status-only re-accept) is the pattern to
follow. Once the undo stack is gone a guarded accept is as final as an ordinary one.

Consequences to pin:

- The stranded walk already judges a status-only accept "against the newest accept for that note
  that carries a cell". A note accepted status-only with no cell-carrying accept at all (the
  hand-typed case) has nothing to revert and is never stranded. Pin it.
  *Correction, 2026-11-12 (coordinator's call, hardening 2026-11-11, not yet ruled by Denver):* the sentence
  above is overruled. A guarded-accepted figure note (accepted status-only, no cell-carrying accept) IS
  stranded when a restore writes its anchor cell away from the suggestion: the walk judges it by its
  anchor cell and suggested content (the change carries its revert; a revive gives a status-only revert;
  a gone cell archives it). It still keeps its status where the restore leaves the cell alone or writes
  the suggested content back. Built in Task 4 fix round 1 (`5686c2bc`), recorded as claim M5-AN-073.
  *Refined, 2026-11-12 (plan 1 final review F2; coordinator's call, hardening 2026-11-11, not yet ruled by
  Denver):* the stranded rule above applies only to a guarded note NOT accepted at the checkpoint.
  "Accepted at the checkpoint" is the note's latest honoured lifecycle line there being an accept, with
  or without a cell; such a note is never stranded, whatever its cell held then. The mirror: a guarded
  accept taken back since the checkpoint returns accepted, status only, when the restore writes the
  suggested content back to its anchor cell (`f6f31c7b`, claim M5-AN-073).
- Reject stays allowed on an open note over its own value. A rejected note beside a value the
  writer typed themselves is honest, and nothing is written to the cell.
- `FigureAnnotationOps.reopen(for:)` is left as it is. The guard on Accept covers the race, and
  the same route by Reject, however the note came to be open over its own value.

**The manuscript.** Reproduce first, in a test: accept a suggested change, have a second device's
newer reject or archive win, reopen, accept again. If the second accept records a `prior` equal to
the accepted text, or fails to find its range and corrupts nothing, the outcome decides the work:

- it reproduces: the same guard in the manuscript accept, a pinned production test, claim
  M5-AN-034's neighbours updated, and a filing flipped `VIOLATES→COMPLIES` in the same branch;
- it does not: record the reproduction test as the pin, and file the reopen-any-status reachability
  (M5-AN-034's "UNTRACED") in the register with what was found.

### 4. MCP and figure notes (#136 W5, W6, W7)

- **W5.** `DocumentStore.addFigureAnnotation`'s open-host branch re-resolves the anchor against
  `host.state` before appending and refuses an anchor that no longer resolves, with the refusal the
  MCP tool already returns for an orphaned anchor. The snapshot is not windowless as the issue
  says; the gap is the awaits between snapshot and append. Where a cheaper read than
  `publishFigures()` serves the tool (`translationFigures()` was suggested), the builder may take
  it, since `publishFigures` documents itself as once per publish.
- **W6.** The open-host branch adopts the one op it just wrote without bumping
  `reloadGeneration`. It does not teach the restore to ignore "note-only" reloads, because a
  reload can also bring another device's cell-moving lines (anti-goal). Pinned with the existing
  `betweenRestoreOpsForTesting` seam: a note added mid-restore lets the restore finish; a real
  reload mid-restore still stops it.
- **W7.** `get_annotation` on a figure takes status and history from one `FigureNotesRead.read`.
  History stays raw (non-goal).

### 5. Research tables (#138)

- **R1 (R-C).** `ResearchTableHost.write` reports why it did not write, as a value, where today it
  returns a bare `false` and three of its branches leave `isDirty` clear.

  **When the rule applies.** Notes save anyway at every `.editorFlush` (⌘S, a switch, the typed
  mover, the store's close including ⌘Q), and refuse only on the debounce timer
  (`ResearchNoteDoor.SaveSource`). Tables take the same split: `write` is told whether it is the
  debounced save or a flush. A flush is every path that commits the held edits for the last time
  or on the writer's say-so: `settle` (⌘S, ⌘Q and a window close, through
  `DocumentStore.flushPendingSave`), the grid's leave, and `close()`. `close()` alone is too late
  and too narrow: ⌘Q never reaches it, and by the time it runs the grid's own flush has already
  been refused. The debounced save keeps today's behaviour (refuse, stay dirty, say so).

  **What a flush does with each refusal:**
  - the version could not be kept: save anyway (the notes' rule), with the notice saying the
    previous version was not kept;
  - the prior bytes will not read, the item is no longer in Research, the research-root guard
    refuses, the outside version could not be backed up (`keepTheOutsideVersion` answers nil), or
    the save itself fails: nothing is written over the file. The held table's CSV goes through
    `Document.writeConflictBackup` (kind `"unsaved"`) and the notice names the file;
  - the file is gone (another Mac trashed it): the file is still **not made again**, which is the
    earlier review's point (task 7 re-review R2-2) and stands. The edits go to the same backup,
    named from a fallback anchor as `ResearchNoteDoor`'s unreachable arm does. This replaces
    "the edits are dropped and said" with "the edits are kept aside and said";
  - the backup itself fails: the notice says so in plain words. Nothing is silent.

  A flush that ended in a backup leaves the host clean, so a second flush on the way out (`settle`
  then `close()`) does not write a second copy. The backup holds the CSV text, not the sidecar's
  formats; the notice does not promise formats.
  Tests hang off `ResearchTableVersionTests.test_aVersionThatCannotBeKeptWritesNothing`: one per
  arm, each ending in either the edits on disk or a `.maugham/conflicts/*-unsaved-*.csv` holding
  them.
- **R2.** After the shared opening task resolves, `DocumentStore` re-checks the registry and the
  closings: it never registers a closing or closed host, replaces a closed entry, and always hands
  back the one live registered host. Verified reachable (a grid left during its own load; an MCP
  write refused before its first await). Pinned by driving the interleaving through the existing
  opening and release functions, with no press-then-wait (tripwire 33).
- **R3.** The save re-checks the on-disk hash inside the coordinated write (an expected-hash
  variant of `performFileSave`). A mismatch takes the existing outside-change branch
  (`keepTheOutsideVersion`). `ResearchNoteDoor` has the same read-await-write shape and gets the
  same check in the same task.
- **R4.** `PhoneFigureBook` keeps the last resolved `TrustTable` and calls
  `cache.invalidateAll()` when it differs, as the Mac does in `figureTrustChanged`. Where the rule
  can be written once in Core for both, do that (tripwire 19).

### 6. Updates (#137)

- **U1.** `checkInBackgroundIfDue` decides by an exhaustive `switch` over the state:
  `idle`, `upToDate`, `error` check; `checking`, `downloading`, `readyToInstall`, `installing`
  skip; `newerBuildNeedsNewerSystem` checks. A background check that fails restores the state it
  began from; it never sets `.idle` over a state that carried information. `.installing` always
  skips, which also closes the re-staging race the verification pass found. One test per state in
  `UpdateScheduleTests`, using `UpdateCheckerTests`' release helper and `.app` stub.
- **U2.** The wake and activation observers take injected notification centers; a test posts a
  fake wake and a fake activation and sees one due check each. `stopBackgroundLoop` either gains
  its caller or goes.
- **U3, U4.** `docs/guide/reference.md` says every six hours, on wake, and on switching back to
  Maugham. The stale "24h poll" comment goes. `Maugham/Updates/AREA.md` gains the
  `UpdateSchedule` testability row and names `UpdateScheduleTests`.

### 7. Doc truth (#139) and the register

- **D1.** Recount `register/START-HERE.md`'s Annotations row, subtotal, totals and complies figure
  from the claims files, and pin them with a test that reads the claims files and the table, so
  the next added claim fails the gate until the row moves. Where the table can be generated by the
  register's existing scripts, generate it.
- **D2.** `scripts/test.sh`'s header says three.
- **Register.** New claims for the figure revert classes, the Accept guard and the table close
  arms, each pinned by its test; the three rulings above; filings for anything the branch finds
  and does not fix. `_summary` recomputed, never hand-adjusted
  (`register/reconciliation/PROTOCOL.md`).
- **Sibling docs.** `Maugham/OpLog/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/Editor/AREA.md`,
  `MaughamPhone/AREA.md`, `docs/tripwires.md` and the user guide are swept for sentences this
  branch makes false (the figure reopen rule, the table close behaviour), in the same commits.
- **#106.** `FigureDocument.swift` is added to the tracked list and checked off with its new line
  count.

## Constraints

- The hard invariants and tripwires in `CLAUDE.md`. Touched most closely here: 19 (one shared Core
  implementation for Mac and phone), 33 (no press-then-wait tests), 47 and 51 (ask `Posture`, never
  compare a rung), 52 (every manuscript writer outside the editor asks its posture first), 58
  (synced paths through `SafeRelativePath`; `writeConflictBackup` already does).
- MCP never writes manuscript text. Nothing here changes that.
- Test first, with a disable experiment on every negative assertion, as the 11-01 hardening did.
- Gates: `./scripts/test.sh`, `./scripts/test.sh core` and `./scripts/test.sh phone` for any Core
  change; `./scripts/test.sh full` before merge. `./gen.sh` after adding any file.

## Left to the builder

- The exact seam of the restore child type, and the names of the Core walk and its result types.
- Whether the Accept guard lives in `FigureAnnotationOps` or one level up, provided Mac and phone
  share it.
- The wording of new notice and sheet sentences, in the voice of the ones beside them.
- Task order after the split, and which tasks run in parallel. The plan caps at about ten tasks;
  split into two plans if it runs past that, building the first before writing the second.

## Calls made here that are not Denver's rulings

- W7's history stays raw; only the race is fixed.
- W6 is fixed on the writing side (adopt the op), not by loosening the restore.
- `reopen(for:)` is left alone, since R-B guards Accept and covers the same race.
- R3's hash re-check is applied to `ResearchNoteDoor` as well as tables.
- U1: `newerBuildNeedsNewerSystem` still checks in the background, and a failure restores it.
- D1's count is pinned by a test, not merely corrected.
- R-C's "at close" is read as the notes' own split: every flush saves anyway, the debounced save
  still refuses. Denver's question named window close and quit; ⌘S and leaving the grid are
  included because that is where notes draw the line.
- A table whose file is gone keeps its edits in a backup copy; the file is still not remade. This
  changes an earlier deliberate "dropped and said".
- A flush that cannot back up the outside version writes nothing over the file and backs up the
  writer's edits.
- A guarded Accept is taken back by ⌘Z only, like any figure accept; `reopen(for:)` stays closed
  to accepted suggestions.
- The sheet's BEFORE count borrows a figure host and leaves out figures the restore would skip or
  refuse.
- The figure walk does not adopt `momentEnd`, and the figure and manuscript walks stay two
  implementations kept in step by tests.
- The Gone class keeps its status-only reopen where this hand may not archive.
