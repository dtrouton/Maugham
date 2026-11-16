# Hardening 11-16, plan 1: the note door Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nothing the assistant can call writes a palette card, whatever the palette group is named; Research Replace changes the characters the writer saw matched; an open note or card hears an outside change; a restore cannot prune its own version; no raw write stands in for a refused door. Closes #141.

**Architecture:** `ResearchTextRole.of` asks Core's role-first `PaletteLookup` instead of a path prefix. Research Replace re-finds with the manuscript arm's `matchRanges`. The note door gains one outside-change entry point, the twin of `ResearchTableHost.fileMayHaveChanged()`, and the existing reload signal carries it to both editors. Version, record and sidecar housekeeping move onto the Core types that own those files.

**Tech Stack:** Swift, SwiftUI + AppKit, the local `MaughamCore` package, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-16-hardening-sweep-11-15-design.md` (§1–§5; rulings R-D, R-E and the RULING-60 amendment). Read it before any task. The rulings are Denver's and are not reopened here; the four "coordinator's calls" in the spec are binding on the builder and are recorded as the coordinator's in the claims.

Branch `claude/hardening-2026-11-16`, derived against `76319f62`. Source: `gh issue view 141`. **Line numbers in the issue have drifted: find code by symbol.**

## Global Constraints

- Read the area guide `CLAUDE.md` names for each path before editing it (`Maugham/Stores/AREA.md`, `Maugham/MCP/AREA.md`, `Maugham/Views/AREA.md`, `Maugham/Editor/AREA.md`, `Packages/MaughamCore/Sources/MaughamCore/AREA.md`), and the rows in `docs/tripwires.md` your change rhymes with (14, 19, 33, 58 most of all).
- Before changing behaviour a claim pins, read the claim: the note door's are M5-AN-070, 071, 072, 084 in `register/reconciliation/Annotations.claims.json`; M6-PR-037 and M6-PR-042 in `Promotion.claims.json`; M8-IN-001 in `Inbox.claims.json`. **Claim and filing text is updated in Task 9, not piecemeal**; a task that makes a claim's sentence false says so in its report.
- Test first: write the failing test, watch it fail for the stated reason, then fix.
- **Disable experiment on every negative assertion** ("is refused", "keeps nothing", "writes nothing", "creates nothing"): remove the guard, watch the test fail, restore it, and put the output in your report.
- Run `./gen.sh` after adding any file. Gate with `./scripts/test.sh`; when `Packages/MaughamCore` changes, also `./scripts/test.sh core` and `./scripts/test.sh phone`. Never raw `swift test` or `xcodebuild test`. Run gates in the foreground, after your last edit.
- Tests are windowless where possible; no press-then-wait (tripwire 33): drive an interleaving through an awaited seam, never a sleep. Temp roots through `TestTemp`; windows through `TestWindow`.
- A census in `TripwireGrepTests` that names a function or file this plan touches (`researchNoteDoorCallers`, `noteWriterFilesWriteCeiling`, `researchFileSaveFunctions`) is updated in the same commit, same count discipline; no entry is loosened.
- Notices go through `MaughamEvent.postNotice(_:projectURL:)`, in the voice of the sentences beside them.
- **#106:** `DocumentStore.swift` is on its list. New logic goes in `ResearchNoteDoor.swift` and `ProjectStore+*.swift`. If `DocumentStore.swift` would grow by more than about twenty lines across this plan, stop and tell the coordinator.
- `Maugham/Stores/AREA.md` is 3 words under its ceiling and `Maugham/OpLog/AREA.md` at it (`DocBudgetTests`, a Core test): guide edits happen in Task 9 and are word-neutral.
- One commit per task, message `hardening 11-16 task 1.N — …`, ending with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Don't push.
- Report: files changed, tests added with their disable-experiment output, the gate result, any claim sentence you made false, and anything you judged that the coordinator should check.

## Review Focus

1. **A project with no palette group at all**, and a legacy project whose cards sit under `research/palette/` with no role stamp: the role answers as it does today (path fallback), and nothing that was a note becomes a card. → Task 2.
2. **Replace where the query no longer occurs at all** in the fresh text, and where it now occurs fewer times than the ordinal clicked: `replaceMatch` throws the stale error and writes nothing; `replaceAll` skips that note and still counts honestly. → Task 3.
3. **The door's own save arriving back as a presenter callback** (the echo): no reload, no notice, ever, including a save that normalises a BOM. → Task 7.
4. **An outside change to a note that is not open in any editor**: `knownHash` is nil; nothing is posted and nothing reloads. → Task 7.
5. **A `ProjectStore` built with no `DocumentStore` at all** (many suites, and the load-only context): the raw fallbacks still write. Only a store that had one and lost it refuses. → Task 8.

---

### Task 1 — the sitting's rulings into the register [sonnet]

**Files:**
- Modify: `register/01-claims-ledger.json` (`_meta.rulings`, and the `questionnaire_rulings_and_ratification_drift` note)
- Generated: `register/RULINGS.md`, `register/reconciliation/ruling-hashes.json`

- [ ] Add RULING-61, RULING-62, RULING-63 with the statements of the spec's R-D, R-E, R-F **verbatim**, verdict `RATIFIED_FROM_OPTIONS`, `basis` "Denver, 2026-11-16, structured question (the hardening 2026-11-16 sitting): chose the recommended option." followed by the example the spec says was put, and a `provenance_note` in RULING-60's shape. Families: R-D joins ADR 0034's (the assistant and Research text); R-E joins RULING-56's; R-F joins RULING-52's and RULING-40's. Copy the key set from RULING-60's entry.
- [ ] Amend RULING-60: the statement's last sentence becomes "This inherits the notes' \"save anyway\" rule (`ResearchNoteDoor.whenTheKeepFails`), ruled under RULING-24's 2026-11-11 amendment (P3, as built); if that rule is later changed, tables change with it." In its `provenance_note`, the sentence ending "not yet ruled by Denver (see M5-AN-080 and M5-AN-081)" becomes "…a reading Denver ruled as built on 2026-11-11 (RULING-24's amendment, P3)." Add "Amended 2026-11-16 (Denver: yes, amend it): wording only."
- [ ] Append to the drift note: "2026-11-16 (hardening 11-16 sitting): four questions, each with a recommendation and its live example first; 4/4 accepted."
- [ ] Run `python3 register/scripts/23-generate-rulings.py --amend`; put the re-check queue it prints in your report (the filings citing RULING-60). Re-read each listed filing: the amendment changes no meaning, so each should stand; say so per filing.
- [ ] Gate: `./scripts/test.sh core` (never a raw `swift test`), and the generator run a second time without `--amend` exits zero and leaves no diff. Commit.

### Task 2 — one answer to "is this a palette card"; `add_note` refuses the palette group (#141 N1; R-D) [opus]

**Files:**
- Modify: `Maugham/Stores/ResearchNoteDoor.swift` (`ResearchTextRole.of`, `noteLookup`, `researchNoteItem(atPath:)`), every other call site of `ResearchTextRole.of` (`ProjectStore+Structure.swift`, `ProjectStore+ResearchMove.swift`, `UpdateNoteTool.swift`, `PromotionPerformer.swift` ×2, `ResearchSubjectColumns.swift`, `ResearchVersionsSection.swift` ×2 and their caller `InspectorResearchPanel.swift`), `Maugham/MCP/Tools/AddNoteTool.swift`
- Test: `MaughamTests/MCP/Tools/UpdateNoteToolTests.swift`, `MaughamTests/ResearchSubjectRoutingTests.swift`, `MaughamTests/MCP/Tools/AddNoteToolTests.swift`

**Interfaces — Produces:**
- `static func of(_ item: ResearchItem, structure: [StructureItem], research: [ResearchItem]) -> ResearchTextRole?`. The two-argument form is **removed**, so the compiler finds every caller. `.paletteCard` when `PaletteLookup.paletteCards(in: research)` contains `item.id`; when `PaletteLookup.paletteGroup(in: research)` is nil, the `ProjectStore.paletteFolderPath + "/"` prefix decides as today; otherwise `.note(path:)`. The guards above it (asset, document, inside a research root, no dot-prefixed component) are unchanged.
- `ResearchNoteDoor.takes` keeps its meaning (nil / non-nil); pass it `research` only if the signature forces it.
- `AddNoteTool` refusal sentence: "The Palette holds the writer's cards; add_note can't create one. Add the note to another Research group." thrown before `addResearchTextNote`, when `parent_group_id` is `PaletteLookup.paletteGroup(in: store.manifest.research)?.id`.

- [ ] Tests first, using the renamed-group recipe from `ProjectStorePaletteTests.test_paletteGroup_survivesRename_andStampsLegacy` (`ensurePaletteGroup()`, `addPaletteCard`, `updateResearchItem(id: group.id, title: "Moods")`):
  - `UpdateNoteToolTests.test_aCardUnderARenamedPaletteGroupIsStillRefused`: the role is `.paletteCard`; `update_note` throws its card refusal; the card's file bytes are unchanged.
  - `ResearchSubjectRoutingTests.test_aCardUnderARenamedPaletteGroupRoutesToTheCardEditor`.
  - `ResearchSubjectRoutingTests.test_aNoteMovedIntoThePaletteGroupIsACard_andADocumentInASubgroupBeneathItIsANote`.
  - `AddNoteToolTests.test_addNoteIntoThePaletteGroupIsRefused_andCreatesNothing`: no manifest row, no file; also under the renamed group.
  - Review Focus 1: `test_withNoPaletteGroupThePathPrefixStillDecides` (a document at `research/palette/x.md` in a manifest with no role-stamped group is `.paletteCard`; one at `research/palettes/x.md` is a note).
- [ ] `test_aNoteBesideThePaletteFolderIsStillANote` and `test_aPaletteCardIsRefusedWhateverP2Says` stay green (the latter's `of(card, structure:)` call gains the argument).
- [ ] Gate: `./scripts/test.sh`. Commit. Report that M5-AN-070's "a card is one under the palette folder" and `Stores/AREA.md`'s "Cards are research assets under `research/palette/`" are now to be reworded (Task 9).

### Task 3 — Research Replace re-finds (#141 N2) [opus]

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Search.swift` (`replaceMatch`'s and `replaceAll`'s research arms)
- Test: `MaughamTests/Stores/ResearchNoteWritersTests.swift`

**Interfaces:**
- Consumes: `static func matchRanges(in text: String, query: String, options: SearchOptions) -> [NSRange]`; `currentSearch?.query` / `.options` as the manuscript arm of `replaceMatch` reads them; `writeReplacedResearchText(_:to:path:url:)`.
- Produces: `private static func replacingResearchMatches(in stored: String, query: String, options: SearchOptions, replacement: String, ordinals: IndexSet?) throws -> String` — `ordinals == nil` replaces every match in `stored`; an ordinal past the fresh count throws `ProjectStoreError.fileSystemError("Match range out of bounds")`. Both research arms call it; the manuscript arm is untouched.
- The ordinal of a clicked match is its index among that document's matches in the search results, as the manuscript arm derives it.

- [ ] Tests first (helpers `note(_:titled:in:)`, `queueEdit(_:of:_:)`, `search(_:_:)`):
  - `test_replaceMatchAfterAnEditInsertedBeforeItReplacesTheMatch_notTheOldOffsets`: note "alpha beta alpha"; search "alpha"; queue an edit that prepends "xx "; replace the second match with "Z"; the note reads "xx alpha beta Z".
  - `test_twoSingleReplacesInOneNoteWithoutASearchBetweenThemBothLand`: replacement longer than the query; replace match 1, then replace what the stale results call match 2. State in the test which occurrence the second click means after the first is gone (the ordinal is taken from the stale list, so it now names the following occurrence): assert the outcome the manuscript arm gives for the same sequence, and pin both arms to the same result.
  - `test_replaceMatchWhoseQueryIsGoneFromTheNoteThrowsAndWritesNothing` (Review Focus 2).
  - `test_replaceAllReplacesWhatTheNoteHoldsNow`: an edit adds a third occurrence after the search; all three are replaced, and the returned count says three.
- [ ] `test_replaceAllOverANoteWithAnUnflushedEditDoesNotClobberIt` and the four version-keeping tests stay green.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 4 — a restore spares the version it restores, in both doors (#141 N4) [sonnet]

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Table/ResearchVersionStore.swift` (`prune`), `Maugham/Stores/ResearchNoteDoor.swift` (`keepThePriorVersion`, the `restoring` thread from `restoreResearchNote`), `Maugham/Editor/ResearchTableHost.swift` (its keep-then-prune and `restore`)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ResearchVersionStoreTests.swift`, `MaughamTests/Stores/ResearchNoteRestoreTests.swift`, `MaughamTests/Editor/ResearchTableVersionTests.swift`

**Interfaces — Produces:**
- `public func prune(itemId: String, device: DeviceSlug, keep: Int = ResearchVersionStore.retention, sparing: Set<String> = [])` — replaces the `String?` parameter; all callers updated.
- The doors' `restoring: Bool` becomes `restoring: String?` (the restored version's file name; nil when not a restore), threaded to the prune.

- [ ] Core test `test_pruneSparesEveryNameItIsGiven`. App tests, one per door: keep 50 own-device versions (`keepVersions` helper / the table suite's equivalent), restore the oldest; the restored version's file still exists afterwards and the count is 51. Then the failing-write arm: with `DocumentStore.beforeCoordinatedWriteForTesting` landing outside bytes twice (see `landOutside` in `ResearchNoteDoorTests`), the restore throws and the restored version's file **still exists**.
- [ ] Gate: `./scripts/test.sh`, `./scripts/test.sh core`, `./scripts/test.sh phone`. Commit.

### Task 5 — a blank template is nobody's version; `add_note` is recorded as the assistant's (#141 N8, N5) [opus]

**Files:**
- Modify: `Maugham/Stores/ResearchNoteDoor.swift`, `Maugham/Stores/ProjectStore+Palette.swift` (`addPaletteCard`), `Maugham/MCP/Tools/AddNoteTool.swift`, `Maugham/MCP/Tools/InboxTools.swift` + `Maugham/Stores/InboxStore.swift` (`promoteToResearch`), `MaughamTests/TripwireGrepTests.swift` (`researchNoteDoorCallers`)
- Test: `MaughamTests/Stores/ResearchNoteDoorTests.swift`, `MaughamTests/Stores/PaletteCardVersionsTests.swift`, `MaughamTests/MCP/Tools/AddNoteToolTests.swift`, the inbox promote suite

**Interfaces — Produces:**
- `func ResearchNoteDoor.wroteATemplate(itemId: String, bytes: Data)` — sets that item's `lastKeptHash` and `knownHash` to the template's hash, so `keepsAVersion` answers false for the first save over exactly those bytes. `addPaletteCard` calls it (through `DocumentStore`) after its template write lands. No comparison against a re-rendered template.
- `AddNoteTool`: when `store.documentStore` is non-nil, the body is written with `saveResearchNote(itemId:text:by: .assistant, mustLand: true, from: store)` instead of the raw write; with none, the raw write stays (Task 8 governs that arm). `researchNoteDoorCallers` gains `"type:AddNoteTool": 1`.
- `InboxStore.promoteToResearch` gains `by writer: ResearchWriter = .writer`; `InboxTools` passes `.assistant`; with a `DocumentStore` the body goes through the door. The body write stays on the throwing path **before** the entry's flip (M8-IN-001).

- [ ] Tests first:
  - `PaletteCardVersionsTests.test_aNewCardsBlankTemplateIsNotKeptAsAVersion`: `addPaletteCard`, then one `updatePaletteCard` → zero versions; a second update → one version, holding the first update's text.
  - The same through the binder shape (template, then a typed save) and through `InboxPane.promoteToPaletteNewCard`'s two calls.
  - `test_aCardWhoseTemplateWasEditedOutsideBeforeTheFirstSaveKeepsThoseBytes`: bytes on disk differ from the recorded hash → kept.
  - `ResearchNoteDoorTests.test_aTableIsRefused_andACardIsTaken`: its "the card's template is kept as its version" line becomes "keeps nothing over its blank template".
  - `AddNoteToolTests.test_theWritersFirstEditOfAnAddedNoteKeepsTheAssistantsTextMarkedAsTheAssistants` (assertion pattern: `test_theAssistantsSaveAlwaysKeeps_marksTheVersion_andEndsTheRun`); the same for an MCP inbox promotion.
  - `test_addNote_createsFileAndManifestEntry` and `test_addNote_flushesSchedulerBeforeBodyWrite` stay green with and without a `DocumentStore`.
- [ ] Gate: `./scripts/test.sh`. Commit. Report: M5-AN-070 ("ALWAYS keeps … a promotion into a card") and M6-PR-037 clause (3) gain the template case (Task 9).

### Task 6 — a destroyed item's record and sidecar go with its versions (#141 N7) [sonnet]

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Table/ResearchNoteRecord.swift`, the file defining `ResearchTableSidecar`, `Maugham/Stores/ProjectStore+Trash.swift` (`removeResearchVersions(ofDestroyed:)`, `sweepResearchVersions(now:)`)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/` (beside `ResearchNoteRecordTests`), `MaughamTests/Stores/ResearchVersionLifecycleTests.swift`

**Interfaces — Produces (same pair on both types):**
- `static func remove(forItems ids: Set<String>, in projectURL: URL)`
- `static func sweepOrphans(liveItemIds: Set<String>, in projectURL: URL, minimumAge: TimeInterval, now: Date)` — removes a file whose id is not in `liveItemIds` and whose modification date is older than `minimumAge`. Callers pass `liveResearchItemIds()` united with the ids in the Trash (`researchItemIds(inTrashEntry:)` over every entry) and `TrashStore.expiry`.

- [ ] Tests first, on the suite's helpers (`openNovel()`, `ageVersions`): permanent delete removes the destroyed note's record and a destroyed table's sidecar, and leaves a sibling's; Empty Trash likewise; **an item sitting in the Trash keeps both**, and a restore brings the mark back; the open sweep removes an old orphan and keeps a young one and keeps a trashed item's.
- [ ] Gate: `./scripts/test.sh`, `./scripts/test.sh core`, `./scripts/test.sh phone`. Commit.

### Task 7 — an open note or card hears an outside change (#141 N3; R-E) [opus]

**Files:**
- Modify: `Maugham/Stores/ResearchNoteDoor.swift`, `Maugham/Stores/DocumentStore.swift` (`researchFileMayHaveChanged(at:)`: one call)
- Test: `MaughamTests/Stores/ResearchNoteDoorTests.swift`, `MaughamTests/Views/ResearchNoteEditorReloadTests.swift`, the palette card editor's mounted suite

**Interfaces:**
- Consumes: `researchNoteItem(atPath:)`, `signal(itemId).count`, `NoteState.knownHash`, `hasPending(_:)`, the `FileSaveError.changedSinceRead` retry in `write` (c6ab3050), `ResearchTableHost.fileMayHaveChanged()` as the model, `store.presenterDidChangeSubitem(at:)` as the test driver.
- Produces: `func ResearchNoteDoor.fileMayHaveChanged(itemId: String, in store: DocumentStore) async`.

The rule (spec §3, binding):

| State | The door… |
|---|---|
| the note was never read (`knownHash == nil`) | does nothing |
| disk hash == `knownHash` | does nothing (its own echo) |
| differs, no pending edit, no save in flight | sets `knownHash`, bumps the reload signal, posts "Reloaded “X” — the file changed outside Maugham." |
| differs, a pending edit or a save in flight | leaves the edit alone. When that save's retry keeps the outside bytes as a version, it posts once: "“X” changed outside Maugham while you were editing it. That version is kept in its Versions; yours was saved." |

- [ ] Tests first:
  - Door: `test_anOutsideChangeToACleanNoteReloadsItAndSaysSo`; `test_theDoorsOwnSaveComingBackIsNotAnOutsideChange` (Review Focus 3, including a BOM file); `test_anOutsideChangeToANoteNobodyReadSaysNothing` (Review Focus 4); `test_anOutsideChangeUnderAPendingEditIsKeptAsAVersion_andSaidOnce` (use `listen()` for notices; the notice count is exactly one across the retry).
  - `test_bytesWrittenOutsideAfterTheReadAreKeptAsAVersionBeforeTheSave` now also expects the notice; the three second-change tests keep their outcomes.
  - Mounted: the note editor shows the outside text after `presenterDidChangeSubitem`; the palette card editor likewise. `test_typingBeforeTheReloadLandsKeepsTheWritersText_andWhatWasWrittenBehindIt` and `test_theEditorsOwnSaveDoesNotReloadIt` stay green.
- [ ] The BOM echo: `adopt` hashes `Data(text.utf8)`, so compare against the hash of the bytes the door last read or wrote, not a re-encoding. If that needs `knownHash` to be set from file bytes in `adopt`, do it and say so.
- [ ] Gate: `./scripts/test.sh`. Commit. Report: M5-AN-071 extends; M5-AN-084's "says nothing" sentence is now false (Task 9).

### Task 8 — no raw write behind a refused door; the raw-write census (#141 N6) [opus]

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift` (`documentStore`), the five fallback sites (`ProjectStore+Structure.swift` link sweep, `ProjectStore+Search.swift` `writeReplacedResearchText`, `ProjectStore+ResearchMove.swift` `rewriteMovedNoteAssetRefs`, `ProjectStore+Palette.swift` `paletteCoordinatedWrite`, `PromotionPerformer.swift`), `AddNoteTool.swift`, `InboxStore.promoteToResearch`, `MaughamTests/TripwireGrepTests.swift`
- Test: `MaughamTests/TripwireGrepTests.swift`, `MaughamTests/Stores/ResearchNoteWritersTests.swift`

**Interfaces — Produces:**
- `ProjectStore.documentStore` gets a `didSet` recording `private(set) var hadADocumentStore: Bool` (true once a non-nil store is assigned; never reset).
- `enum RawNoteWrite { case allowed, refused }` and `func rawNoteWriteWithNoDoor() -> RawNoteWrite` on `ProjectStore`: `.allowed` iff `!hadADocumentStore`. Each fallback site asks it; `.refused` throws `ProjectStoreError.fileSystemError("The project is closing; the note was not written.")` (or returns without writing where the function cannot throw, logging once).
- `TripwireGrepTests.rawResearchTextWrites: [String: Int]` replaces `noteWriterFilesWriteCeiling`: every `.write(to:` across `Maugham/` whose target is a research-item path, keyed by file with a count, each entry commented as `create` or `no-door fallback`. The planted-offender test covers a new raw write in a file not on the list.

- [ ] Tests first: `test_aStoreThatLostItsDocumentStoreRefusesTheRawNoteWrite` for Replace and the link sweep (wire a `DocumentStore`, drop it, call; the file's bytes are unchanged); `test_aStoreNeverGivenADocumentStoreStillWritesRaw` (Review Focus 5). The census test and its planted offender.
- [ ] Every suite that builds a bare `ProjectStore` stays green (`AddNoteToolTests` among them).
- [ ] Gate: `./scripts/test.sh full` (this is the plan's last code task). Commit. Report: M5-AN-070's "with no document store … write raw" sentence narrows (Task 9).

### Task 9 — claims, filings, guides (#141; D5's note-side half) [sonnet]

**Files:**
- Modify: `register/reconciliation/Annotations.claims.json` + `.filings.json`, `Promotion.claims.json` + `.filings.json`, `Maugham/Stores/AREA.md`, `Maugham/MCP/AREA.md`, `docs/adr/0034-*.md`, `Maugham/Stores/ResearchNoteDoor.swift` (the P3 comment), `MaughamTests/Stores/ResearchNoteDoorTests.swift` (its "interim ruling on P3" comment)
- Generated: `register/START-HERE.md` (between its markers)

- [ ] Claims, each sentence checked against the built code, with the new tests added to its sources: M5-AN-070 (a card is a child of the role-first palette group; a blank template is not kept; raw only where no door ever was; P3 is ruled, RULING-24); M5-AN-071 (an outside change reloads an open note or card); M5-AN-072 (source list); M5-AN-084 (the note retry now says so; cite RULING-62); M6-PR-037 clause (3) (the template case). New claims for RULING-61 (`add_note` refuses the palette group) and RULING-62 (the outside-change table), each with a filing `COMPLIES` citing its ruling and the fix commit. Mark the four coordinator's calls as the coordinator's in the claim text.
- [ ] Recompute each touched module's `_summary`; run `register/scripts/27-generate-state.py`; `StartHereCountsTests` green.
- [ ] `ResearchNoteDoor.swift`'s `WhenTheKeepFails` comment: "P3 (Denver, 2026-11-11: as built; RULING-24's amendment)" in place of "pending … Interim ruling (controller, Task 3)". The test comment likewise.
- [ ] `Stores/AREA.md`: "Cards are research assets under `research/palette/`" → role-first wording; the raw-fallback sentences → "raw only where no `DocumentStore` ever was"; add `fileMayHaveChanged` to the note door's line. Word-neutral against `DocBudgetTests`. `MCP/AREA.md`'s `add_note` line gains "never into the Palette". ADR 0034 gains one dated line: `add_note` refuses the palette group (RULING-61).
- [ ] Gate: `./scripts/test.sh core` (DocBudget and the register tests), then `./scripts/test.sh`. Commit.

---

After Task 9: the coordinator re-derives plan 2 (#142–#144, spec §6–§8) against the built door, then the whole-branch review.
