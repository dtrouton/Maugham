# Typing loop and note versions — design

2026-11-10. One Mac-only milestone, two plans. No op-log schema change, no
phone change, no paired release.

## Why

Two findings from the 2026-11-09 performance analysis and the conversation
that followed it.

**The typing loop pays for work the keystroke does not need.** A temporary
probe typed through a real `NSTextView`, `EditorCoordinator` and `Document`
(optimised build, median of 40 mid-document keys):

| Stage | Prose 30 KB | Prose 250 KB | Report prose 250 KB | Fountain 250 KB |
|---|---|---|---|---|
| Keystroke total | 5.0 ms | 38.4 ms | 52.9 ms | 39.0 ms |
| `Document.setFullText` | 1.4 | 10.4 | 10.5 | 13.8 |
| Word count in the binding setter | 1.4 | 10.9 | 11.2 | 10.7 |
| Whole-document tokenize | 1.6 | 12.6 | 24.5 | 9.0 |
| String copy (`makeContiguousUTF8`) | 0.5 | 4.1 | 4.1 | 4.0 |

Pause edges at 250 KB: autosave 23–50 ms on the main actor, 750 ms after the
last key.

**Research notes have no history.** A Research table keeps the bytes each
save replaced (`ResearchVersionStore`, report plan 9d); a Research note is
saved whole-file and the earlier text is gone. Denver wanted note history and
first thought of the op log. Backups of a real project (Playlist, 16 snapshots
over four months) showed no Research note edited once while the manuscript
was reworked throughout, so the op log's cost and machinery are not earned.
Denver's ruling: notes get what tables have.

## Goals

1. A keystroke in a manuscript no longer counts the whole document's words.
2. The 750 ms autosave no longer holds the main actor for the render and the
   file write.
3. Every Research note keeps earlier versions the way a Research table does,
   listed in the inspector with Restore.

## Non-goals

- Incremental tokenizing and an incremental `setFullText`. They are a
  rewrite of the keystroke path needing a frozen reference oracle; whether
  they are needed is judged after this milestone, on real document sizes.
- Research notes in the op log: no paragraph ids, no History pane entries, no
  rewind, no annotations on notes, no signing.
- History for Research files that are neither notes nor tables (images, PDFs,
  scripts). Backups cover them (Denver's ruling).
- Any change to how tables keep versions, beyond what sharing the store with
  notes requires.

## Anti-goals

- A session that stops recording, or a footer whose word counts stop moving.
  `recordEditorTextWrite` lost its calls once (commit `b37609a`) and the
  regression hid for three days; `EditorBindingSideEffectsTests` pins it.
- A write of our own that the `Document` then reads as an outside change, or
  an autosave that writes an older text over a newer one.
- A note version kept on every keystroke or every save: one version per
  editing run, as tables.
- Losing a note's text because its previous version could not be kept.

## Plan 1 — the typing loop

### 1a. The word count leaves the keystroke

Today `EditorHost`'s binding setter calls
`DocumentStore.recordEditorTextWrite`, which runs `mode.wordCount(newText)`
over the whole document, stores it (`ProjectStore.recordWordCount`) and feeds
the project total to `SessionTracker.recordTextChange`.

Required behaviour:

- **Per keystroke, still:** the session starts on the first keystroke, its
  last-change time moves, and the 30-minute idle timer re-arms. These are
  cheap and are the regression-scarred part; they stay on the keystroke.
- **Deferred to a trailing edge:** the whole-document word count and the
  write to the project's word-count cache. One count per typing burst, on
  the same order of delay as the footer's metrics (350 ms).
- **Never stale at a boundary:** the count is brought up to date before
  anything reads it as final — a session ending (idle or quit), a document
  switch or close, a checkpoint, the window closing. A burst's words must
  land in `wordsToday` and `liveSessionWordsNet` even if the writer types
  one burst and quits.
- **The session's starting count is the count before the burst.** A session
  that begins with this keystroke must take as its `startWordCount` the
  project total as it stood before the edit, so the first burst's words
  count as written in the session.

The footer's own document word count already arrives on a debounced edge
(`onMetricsChanged`); the builder may reuse that delivery or keep a separate
one, provided the session and footer cannot disagree after a settle.

Left to the builder: where the deferred count lives, and whether it counts
the whole document at the edge or only what changed.

### 1b. Autosave off the main actor

Today `Document.performAutosave` runs on the main actor: it flushes the
pending mirror, materializes the document, strips anchors and writes the
`.md`/`.fountain` inside an `NSFileCoordinator` block, recording
`lastDiskEcho` inside that block.

Required behaviour:

- The render (materialize, strip) and the coordinated write happen off the
  main actor, from a snapshot of `paragraphs` and `sequence` taken on it.
- **The echo guard still holds.** The presenter callback for our own write
  must find `lastDiskEcho` already describing those bytes; it must never be
  treated as an outside change.
- **Writes are ordered.** A later autosave's bytes are never replaced by an
  earlier one's finishing late.
- **`close()` still flushes before it husks.** A closed document's last
  text is on disk, and no write lands after close.
- Every guard the function has today stays: the writability check, the
  pending-file permission (`mayWriteThePendingFile`), `rendersToDisk`.
- The pending mirror's flush (crash recovery) keeps its place before the
  render and its failure stays logged, not swallowed.

Left to the builder: the mechanism (a detached task, an actor, a serial
queue).

### Measuring plan 1

The probe from the analysis becomes a standing test in
`MaughamTests/Performance/`, reporting per-stage times for the corpora above.
It asserts ratios or counts, never wall-clock budgets (the project's rule for
perf guards): the binding setter performs no whole-document word count on a
keystroke, and one burst performs exactly one. Expected effect at 250 KB:
keystroke about 38 ms → about 27 ms; the autosave edge off the main actor.

## Plan 2 — note versions

### What the writer sees

With a Research note selected, the inspector shows the same **Versions**
section a table has: each kept version by date, newest first, **Restore
previous version** and a **Restore** per row. A restore is itself a save, so
the text it replaces is kept and restoring again undoes it. Restore is off in
Review and on a view-only share, with the table section's reasons.

### When a version is kept

The table rules, unchanged (`ResearchSaveRun`, `ResearchVersionStore`):

- The writer's saves with no gap over 10 minutes are one run, and a run keeps
  one version: the text before the run began.
- A save over bytes that are not this app's own last write keeps a version
  (an outside change to the file).
- A restore always keeps what it replaces and ends the run.
- 50 versions per note per device, pruned past that; a deleted note's
  versions are swept after the Trash expiry.
- The copy is made off the main actor.
- A note whose previous text cannot be read or kept is not saved over; the
  writer is told, as for a table.

### One door for note writes

Every write that changes an existing note's text goes through one function
that keeps the version first. Known writers today: `ResearchNoteEditor`'s
autosave (`DocumentStore.scheduleFileSave` → `performFileSave`),
`PartialRestorePicker`, a canvas promotion's Rewrite, and wiki-link renames
that rewrite a note's links. The builder finds the rest; a census test names
the callers so a new one cannot bypass the door.

Creating a note keeps nothing (there is nothing before it).

A promotion's Rewrite already keeps the replaced text as a Trash
`priorVersion` entry (claim M6-PR-037). That stays as filed; the Rewrite also
keeps a version through the door. (My call: two records of one event are
better than changing a filed behaviour in this milestone.)

### The assistant's writes

Denver's ruling: same as tables — an assistant's write always keeps a version
and is marked ("Written by assistant", "Before the assistant's change").

Today the assistant has no way to change an existing note through Maugham:
`add_note` only creates. Denver's ruling (2026-11-10): this milestone adds
one.

- A new MCP tool replaces an existing Research note's body. It joins
  `MCPToolCatalog.all`; every tool count in help and skills derives from the
  catalogue.
- Its write goes through the note door as the assistant: it always keeps the
  text it replaces, and ends the writer's run.
- The inspector marks the versions as it does a table's: "Written by
  assistant" on a version whose text the assistant wrote, "Before the
  assistant's change" on the text an assistant's write replaced. Knowing who
  wrote the text now on disk needs a small record per note (a content hash
  and a writer, as a table's sidecar carries); where it lives is the
  builder's.
- A note open in the editor takes the assistant's text the way it takes a
  restore, and a pending unsaved edit is saved first, so it is the version
  the assistant's write replaces.
- It refuses what is not a Research note (a table, a picture, a manuscript
  piece) and says what the item is. MCP still never writes manuscript text.
- Scope over the inbox is unchanged.

### The store

`ResearchVersionStore` is reused. It is table-shaped today: the payload file
is named `.csv` and `keep`/`read` carry a `ResearchTableSidecar`. It is
generalised so a note's bytes and no sidecar are first-class. Constraints:

- Table versions already on disk keep listing and restoring; no migration.
- A note's version restores byte-for-byte.
- The folder stays `.maugham/research-versions/<itemId>/`, spelled once.

Left to the builder: the payload naming for notes, and whether note and table
share one inspector section or two with a shared model.

### An open note and a restore

Restoring a version of the note that is open in the editor replaces the
editor's text, without the editor's next autosave writing the old text back.
A pending unsaved edit is saved first (and so becomes the version the restore
replaces), as tables do.

## Constraints

- The editor binding contract is untouched: one `Binding`, `displayText`
  written once per `setFullText`, no new observable state on `EditorHost`
  (tripwires 2, 3, 6, 7). Deferring the word count must not add a
  `.onChange` that reads back into the binding.
- A note's path reaches the disk through `SafeRelativePath`
  (`resolveForChange` to change; tripwire 58).
- Registry and claims: `Promotion` and `Trash` have filings that touch note
  rewrites; read them before changing behaviour there, and add claims for
  what this milestone pins.
- Help and docs describe what ships: the guide's Research section gains note
  versions in the same milestone.
- No migration and no schema bump.

## Calls made after the builder check

These are Claude's calls, not Denver's rulings; each is open to correction.

**Plan 1**

- **A footer that trails a burst is fine.** Session words and the project
  total may be stale during a burst and settle at its trailing edge, as the
  footer's document metrics already do.
- **One choke point brings the count current.** Everything that reads the
  project total as final (the idle session end, quit, a document switch or
  close, a checkpoint, the window closing) calls one function first. A
  census names its callers.
- **The echo knows the bytes in flight.** While a write is in flight, disk
  bytes equal to the last landed bytes or to the in-flight bytes are both
  our own; a landed write becomes the echo, a failed one is dropped and the
  landed echo stands. (Corrected while planning: recording the echo before
  the write would misread a late callback for the previous write.)
- **A session's starting count is the total before its first burst**, so
  the first burst's words count. Today it is the total after the first
  keystroke; the pinned test changes with it.
- **The project window stops being invalidated on every key.** The
  observed total is written only when it changes, once per burst.

**Plan 2**

- **Run state lives in memory, per note, for the project's open life** (on
  `DocumentStore`, as a table's lives on its host). It is not persisted.
- **Loading a note records its bytes as known**, so the first save after a
  launch is not read as an outside change. A write by a caller that never
  loaded the note has no record, and keeps a version: unknown provenance is
  kept.
- **The save carries the item id; the path is asked at the save.** A note
  moved between the schedule and the save is written where it then is, and
  the version belongs to the id.
- **A text file with no Research item is saved as today and keeps
  nothing.** The door never blocks a save for want of an id.
- **The keep is awaited before the write.** A keep that fails stops that
  write, tells the writer through the notice tables use
  (`MaughamEvent.postNotice`), leaves the editor's text in place, and the
  next edit or flush tries again. At close and quit the note follows
  whatever a table does in the same position.
- **Item ids are shared across Research kinds**, so the folder needs no
  kind. A version whose payload is not the item's current kind (a file
  whose extension was changed) is listed but not offered for restore.
- **Restore is reached from the inspector only.** The open editor takes the
  restored text by re-reading the file into its own state on a store
  revision; the text then reaches the text view through the existing
  binding and the one `applyExternalText` call. No second caller
  (tripwire 7), and the reload stays keyed on the path (tripwire 22).

## Smoke

Type in a long manuscript piece and watch the footer's counts settle; pause,
quit, relaunch: text and today's words intact. Edit a Research note, wait
past a save, edit again; the inspector lists the earlier version; Restore
brings it back; Restore again returns the newer text. Trash the note; its
versions go after the Trash expiry. Ask the assistant to rewrite a
note; the inspector marks the version it replaced, and Restore brings the
writer's text back.
