# Hardening: the 2026-11-15 sweep's issues — design

Branch `claude/hardening-2026-11-16`. One branch closes #141, #142, #143 and #144. #106 stays open
as a standing ruling; this branch adds no substantial work to a file on its list (see §6).

Sources: each issue's body (`gh issue view N`), `docs/superpowers/notes/2026-11-15-sweep.md`, and
two read-only verification passes run on 2026-11-16 against HEAD `19600238`, whose corrections are
folded in below. **Line numbers in the issues predate two merges (hardening 11-11, updater
hardening): find code by symbol, not by line.**

## Intent

The sweep found places where Research text or its history goes wrong without saying so: the
assistant can rewrite a palette card after the group is renamed; Replace can change the wrong
characters; an open note saves over a change it never saw; a delete that fails partway leaves notes
in the Trash with no undo. The standing instruction from the 11-11 sitting holds: "we don't want to
allow corruption." Each fix closes the route and, where a second implementation of the same rule
exists, closes its twin in the same task (the sweep's recurring lesson).

## What the verification pass changed

| Finding | As filed | At HEAD `19600238` |
|---|---|---|
| N1 | four consequences | three hold; "Promotion would Rewrite a card" is **refuted** (Promotion asks `PaletteLookup`). New: `add_note` into the palette group makes a card with the assistant's text |
| N2 | typing between search and Replace | also a second Replace click inside the 300 ms re-search debounce, with no typing |
| N3 | notes; `update_note` during a pending edit is skipped | palette cards are equally deaf; the `update_note` half is **overstated** (the door flushes the pending edit first, pinned) |
| N4 | note door | the table door has the same prune-before-write shape |
| N7 | note records | table sidecars (`.maugham/research-tables/<id>.json`) leak the same way |
| N8 | promotion into a new card | the binder's New Card plus first typed save keeps the template too |
| N9 | open (#138 comment) | **already fixed** by c6ab3050 (`FileExpectation` inside the coordinated write); only the note-side notice is missing, and N3 adds it |
| T2 | hold door writes while `structuralVerbDepth > 0` | that hold **deadlocks**: the mover's own flush runs inside the verb |
| T3 | rewrite after a failure-handled save | the rewrite needs only the in-memory manifest; it can simply run before the save |
| Q1 | ⌘Q splits the autosave | ⌘Q now awaits the stores (11-11). Still reachable on the 10 s bound, a crash or force-quit, and for **statements**, which still close fire-and-forget |
| D5 | P3 unrecorded | P3 **is** recorded (RULING-24's 2026-11-11 amendment, "as built"). Stale: the door's comment, one test comment, claim M5-AN-070, RULING-60's wording |
| D1/D2 | carried on #139 | **fixed** in f18e9653 |
| new | — | `Maugham/OpLog/AREA.md` still says "Quit never runs `close()`", false since 11-11 |

## Goals

1. Nothing the assistant can call writes a palette card's text, whatever the palette group is named.
2. Research Replace changes the characters the writer saw matched, or changes nothing and says so.
3. An open note or card never saves over an outside change without the writer being told.
4. A delete gesture either completes as one undoable gesture or says exactly what it did.
5. A stale `.md` that Maugham itself left behind is not reported as an outside edit.
6. The docs, comments and register wording the sweep found stale are true again.

## Non-goals

- No new feature and no new UI surface beyond sentences in existing notices and errors.
- No change to how many versions are kept (50 per item per device) or to RULING-24's tiers.
- No awaited close for statements at quit; Q1's fix is on the load side and covers them.
- No fix for the burst variant of Q1 (a kill between the burst append and the trailing autosave
  leaves the log ahead of the `.md` with no pending file). It is recorded on #143 as a residual.
- No data migration (tripwire 11). No tidy-up of #106's files.

## Anti-goals

- A second spelling of "is this a palette card" or "where is this match" (the sweep's lesson).
- A hold on the note door that can make the mover wait on itself.
- Suppressing the "diverged" backup for a real outside edit.
- A raw write that silently replaces a refused door write.

## Rulings taken in this sitting (Denver, 2026-11-16, structured questions, each a recommended option accepted)

These go into `register/01-claims-ledger.json` → `_meta.rulings` as RULING-61 to RULING-63, verdict
`RATIFIED_FROM_OPTIONS`, with the example put to him in the basis. Regenerate `RULINGS.md` and
`ruling-hashes.json` with `register/scripts/23-generate-rulings.py`; never by hand. Acceptance
tally for the ledger's `questionnaire_rulings_and_ratification_drift` note: 4/4 this sitting, all
with a recommendation, each put with its live example first.

**R-D (RULING-61). The assistant never creates a palette card.** `add_note` refuses the palette
group as its destination, with a sentence saying cards are the writer's; it can still add a note
anywhere else in Research. Example put: `add_note` with `parent_group_id` set to the Palette group
makes a card holding the assistant's text, while `update_note` refuses a card (ADR 0034).

**R-E (RULING-62). An open note or card hears an outside change the way a table does.** With
nothing unsaved, the editor reloads and a notice says "Reloaded “X” — the file changed outside
Maugham." With an unsaved edit, the writer's edit is saved, the outside text is kept as a version,
and a notice says so and where to find it. Example put: the file changes on another device or in an
external editor; today the next keystroke saves over it and nothing is said.

**R-F (RULING-63). A row whose file is already missing can be deleted, and a delete gesture
completes as one.** The row is removed and recorded in the Trash as a row with no file, so the
gesture completes and ⌘⌥Z undoes it as one. Any other failure partway stops, saves what was
trashed, arms undo for it, and the error names what was and was not deleted (RULING-52's route).
Example put: three notes selected, the second's file deleted in Finder; today the first goes to the
Trash with no undo and the dead row can never be deleted.

**RULING-60 amended** (Denver: "Yes, amend it"): its last sentence and provenance note stop calling
the notes' rule "interim" and "not yet ruled"; they cite RULING-24's 2026-11-11 amendment (P3, "as
built"). Meaning unchanged. Run the generator with `--amend` and work the re-check queue it prints.

**Coordinator's calls, not Denver's** (recorded as such in the claims they touch):

- N1: a palette card is what `PaletteLookup.paletteCards` says it is (a direct child of the
  role-first palette group); the `research/palette/` path prefix stays only as the fallback when no
  manifest is in reach. This is `Stores/AREA.md`'s existing "role first, path second" rule.
- N2: re-find by ordinal, as the manuscript arm does; refuse when the ordinal is gone.
- N8: a card's untouched blank template is not kept as a version (nobody wrote it).
- N6: a `ProjectStore` that has ever had a `DocumentStore` refuses instead of writing raw.

## Design

### 1. One answer to "is this a palette card" (#141 N1, R-D)

`ResearchTextRole.of` gains the research tree: `of(_ item:, structure:, research:)`. It answers
`.paletteCard` when `PaletteLookup.paletteCards(in: research)` contains the item, and falls back to
the path prefix only when that lookup finds no palette group. Every call site passes
`manifest.research`; the two pure helpers in `ResearchVersionsSection` take it from their one
caller. `ResearchNoteDoor.takes` needs only nil/non-nil and is unaffected in meaning.

Consequences that change: `update_note` refuses a card under a renamed group; the centre router
opens the card editor; the Versions noun says "card". A note moved into the palette group is a card
(both rules now agree); a document in a subgroup beneath it is a note (both agree).

`add_note` (R-D): refuse when the parent is `PaletteLookup.paletteGroup(in:)`, before anything is
created. Tests: a card under "Moods" stays `.paletteCard` and `update_note` refuses it;
`test_aNoteBesideThePaletteFolderIsStillANote` still passes; `add_note` into the palette group
creates nothing.

Not in scope, filed on #141 as a new low finding: `addResearchTextNote` derives the folder from the
parent's title slug, so a renamed-and-deduped group folder could take a new card in the wrong place.

### 2. Research Replace re-finds (#141 N2)

After the settle and the re-read, both research arms call the existing pure
`ProjectStore.matchRanges(in:query:options:)` on the text just read and replace by ordinal, the
manuscript arm's rule. `replaceMatch` throws the existing stale error ("Match range out of bounds")
when the ordinal is gone; `replaceAll` replaces every match found in the fresh text rather than the
search-time list. The ranges are found in the stored text, which also removes the anchor-offset
skew. One helper, used by both arms; the manuscript arm is untouched.

### 3. An open note or card hears an outside change (#141 N3, R-E; closes N9's notice)

The door gains one entry point, `fileMayHaveChanged(itemId:)`, the note twin of
`ResearchTableHost.fileMayHaveChanged()`. `DocumentStore.researchFileMayHaveChanged(at:)` resolves
the path with the existing `researchNoteItem(atPath:)` and calls it; the logic lives in the door,
not in `DocumentStore.swift`.

- Disk hash equals `knownHash`: nothing (this is the door's own echo).
- Differs, no pending edit: bump the reload signal (the editors already reload on it), set
  `knownHash`, post "Reloaded “X” — the file changed outside Maugham."
- Differs, pending edit: leave the edit; the next save already keeps the outside bytes as a version
  (`FileExpectation`, c6ab3050). That retry path now posts: "“X” changed outside Maugham while you
  were editing it. That version is kept in its Versions; yours was saved." One notice per change.

`PaletteCardEditor` reloads on the same signal, so cards are covered by the same entry point; a
test mounts each. Claims M5-AN-071 (extended) and M5-AN-084 (its "says nothing" sentence flips).

### 4. Version and record housekeeping (#141 N4, N5, N7, N8)

- **N4.** `ResearchVersionStore.prune(…sparing:)` takes a set of names (Core; both schemes). A
  restore spares the version it is restoring, in the note door and the table door.
- **N5.** `add_note`'s body goes through `saveResearchNote(by: .assistant)` when a `DocumentStore`
  is wired, so the record is written by its one owner; `researchNoteDoorCallers` gains
  `type:AddNoteTool`. `InboxStore.promoteToResearch` called from the MCP tool does the same, keeping
  its body write on the throwing path before the flip (M8-IN-001).
- **N7.** Permanent delete and Empty Trash remove the destroyed items' `ResearchNoteRecord` and
  `ResearchTableSidecar` files beside `removeVersions(ofItems:)`; the open-time orphan sweep removes
  a record or sidecar whose item is neither live nor in the Trash and whose file is older than
  `TrashStore.expiry` by mtime. Both removals are Core functions on the owning types.
- **N8.** `addPaletteCard` records the template it wrote as the door's `lastKeptHash` for that item,
  so the first save over an untouched template keeps nothing. No byte comparison against a
  re-rendered template (the deduped title and M1-C-041 make that unreliable). Claims M5-AN-070 and
  M6-PR-037 clause (3) gain the case; `test_aTableIsRefused_andACardIsTaken` changes its last line.

### 5. No raw write behind a refused door (#141 N6)

`ProjectStore` remembers that a `DocumentStore` was once wired. The five `documentStore == nil`
fallbacks write raw only when none ever was (the load-only context the tests and claim M5-AN-070
describe); after teardown they throw. `noteWriterFilesWriteCeiling` becomes a census: every
`.write(to:` in `Maugham/` on a research-item path is in a named allow-list with a count per file
(create-time writes named as such), with a planted-offender test.

### 6. Trash and mover (#142)

- **T1 (R-F).** `trashResearchItemCore` trashes a row whose file is missing through the existing
  `recordManifestOnlyTrash`. `deleteResearchItems` catches a mid-loop throw, saves the manifest,
  refreshes `trashEntries`, arms ⌘⌥Z with the entries made, and throws a new
  `ProjectStoreError` case naming the titles trashed and the title that failed. `moveToTrash`
  removes the folder it minted when it throws. `restoreResearchItem` and `restoreStructureItem`
  refuse an id that is already in the tree. Claims M3-TR-008, M3-TR-009 and M3-TR-034 change; their
  two characterization tests are rewritten from a probe.
- **T2.** `ProjectStore` holds the ids of research items whose files a verb is moving, from just
  before the mover is called until the in-memory manifest names the new place. The door, finding
  `.missing` for an id in that set, does not write afresh: a timer save stays pending, a flush or
  direct save waits for the set to clear and runs once more. The mover's own flush runs before the
  file moves, so it never meets `.missing`. An editor save of a note deleted outside Maugham still
  recreates it, as today.
- **T3.** `rewriteMovedNoteAssetRefs` runs before `saveManifest` in the move and the rename.
  `Stores/AREA.md`'s "asset refs follow manifest saves" is reworded, word-neutral.

### 7. Typing loop (#143)

- **Q1.** `Document.load`'s divergence check also renders the state before the pending fold. A
  stored `.md` equal to that render is Maugham's own stale file: no backup, and the re-render is
  still scheduled. Anything else is diverged as today. Covers the 10 s bound, a crash, and
  statements. `LoadDivergenceSnapshotTests` stays green unchanged.
- **Q2.** In `performClose`, `pending.clear()` moves after `isClosed = true` (drain, close, clear,
  husk), so no suspension separates the final drain from `isClosed` and `runAutosave`'s
  `guard !isClosed` stops a late mirror write. `mayWriteThePendingFile` stays one expression at
  four sites.
- **Q3.** A render hook beside `autosaveWriteHook`; the test asserts both threads.

### 8. Doc truth (#144)

- **D3.** CLAUDE.md's Releases line gains the green-CI sentence, paid for word-for-word by trimming
  the parenthetical list (the file is at its 3,087-word ceiling); regenerate `AGENTS.md`.
- **D4.** `TrashStore.swift`'s comment says "research FILES".
- **D5.** The door's comment, the test comment and M5-AN-070 say P3 is ruled (RULING-24).
- **AREA truth.** `OpLog/AREA.md`'s quit sentence; `Stores/AREA.md` lines the fixes falsify
  (palette path, raw fallbacks, asset refs). Both guides are at their word ceilings: every edit is
  word-neutral or pays for itself in the same commit.

### #106

`DocumentStore.swift` (2,805) and `Document.swift` (2,113) are on #106's list. This branch's work in
them is a call into the door (§3), a set lookup (§6 T2) and a reorder plus one hook (§7): not
"substantial work", so the ruling does not fire. The builder keeps new logic in
`ResearchNoteDoor.swift` and `ProjectStore+*.swift`; if either listed file would grow by more than
about twenty lines, stop and split first. Comment the line counts on #106 at the end.

## Plans

1. **Plan 1 — the note door (#141):** the rulings into the register, then §1–§5.
2. **Plan 2 — trash, typing loop, doc truth (#142–#144):** §6–§8, written after plan 1 is built
   (CLAUDE.md workflow rule 11), since T2 and N3 both touch the door's write path.

Each fix that changes a pinned claim closes the loop in its own commit: fix, pinned production
test, claim text, filing, `_summary`, `27-generate-state.py`. Whole-branch review before merge;
`./scripts/test.sh full` plus the phone scheme (Core changes) are the gate.
