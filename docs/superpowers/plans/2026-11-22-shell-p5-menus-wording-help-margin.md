# Menus, Wording, Help and the Margin (shell plan 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The window teaches itself and says one thing one way. A writer can turn on a quiet margin that shows where their own and their reviewers' notes sit, and where a check or a round flagged a paragraph, without a word of the model's reaching the page. Every menu and right-click menu matches the window plans 1–4 built; a piece is called by the project's own word everywhere; and the guide, the tour, the cheat sheet, the samples and the help Claude reads describe what ships. The two owed carries close: figure "source data changed" items in To resolve, and the do-or-drop list of ADR 0038's known limits.

**Architecture:** 5a first (code that later tasks describe): the note's signer reaches the editor, then the margin and its amendment to ADR 0027 §1, then the figure item, then the carries. 5b last (what the writer reads): one noun function and one vocabulary, then the menus as Denver approves them in this plan's table, then the guide, then every other teaching surface, then the record. Pure functions decide marks, nouns and titles; views take values; censuses keep retired words out.

**Tech Stack:** Swift, SwiftUI, AppKit. No new dependency. One additive MaughamCore change (Task 1), no schema change.

**Spec:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md` ("To resolve" — the margin setting; "Where today's surfaces go"; "Open decisions" 3, teaching it). Built on ADRs 0035–0038. Amends ADR 0027 §1. Every signature below was read at `7b542fee`; a name marked **new** is created by the task that lists it under Produces.

## How this plan is cut

Plan 5 of 5 on `claude/shell-without-personas`. Ten tasks, split in this file:

- **5a — the margin and the carries (Tasks 1–5).** Independent of the menus and the help; may be built now.
- **5b — the words, the menus and the help (Tasks 6–10).** Runs **last on the branch**, after the read-through plan (`docs/superpowers/specs/2026-11-22-read-through-design.md`, being planned now) and the promotion-carries-history plan, because 5b describes what ships and both of those change what ships. Task 7 applies the menu table **only after Denver has approved it on paper** (the table below is the deliverable he approves; Task 7 builds what he approved).

**Order of the three plans.** 5a → read-through → promotion-carries-history → 5b. Read-through must land before Task 7: it deletes Toggle Review Mode (⌘⌥⇧R) and Lock (⌘⌥⇧L) and adds its own item and key; this plan leaves a named slot for that item (table rows 24–25) and designs nothing of read-through. If 5b's Task 6 is ready before read-through lands it may go first; Tasks 7–10 may not.

**Not in this plan:** Read-through; promotion carries history; new features; the design's open decision on the Inbox at scale (ADR 0035 "Not yet built"), which is an unmade design choice of Denver's, not a carry.

**Merge gate (from plan 4, Task 7 review M7):** the bundled in-app Help still describes the deleted Department desk and translation review pane. The branch does not merge until Task 8 rewrites it and Task 8's census holds (workflow rule 7).

## Global Constraints

- The hard invariants in `CLAUDE.md` stand. **No second manuscript `Document`**: the margin reads the open piece's own `Document` and the same store-level sources To resolve reads (`ResolveReader.read(scope:store:…)`, `DiagnosticsStore.live(docId:currentText:)`); the figure item reads no manuscript.
- **Nothing a model wrote is drawn in the editor or its chrome** (constitution must-not #2, ADR 0027 §1, as amended by Task 2). The margin draws positions, never words; a census enforces it.
- `EditorHost` gains no state (tripwire 6); `EditorSurface.applyExternalText` keeps one call site (tripwire 7); the margin's value is threaded one way through `EditorControl` (tripwire 2), recomputed off the binding setter (tripwire 3).
- No uncached per-row or per-draw work (tripwire 4): marks are computed once per (document revision, annotations version, items key, setting, filter) and the overlay draws from the cache.
- `List(.sidebar)` rows select by tag or act by `Button(.plain)`, never `.onTapGesture` (tripwire 9).
- Hide, don't disable, in the window; ask `Posture` (tripwires 47, 51). **The menu bar disables** (its convention, already the house rule for focused items). Notifications through `MaughamEvent` with a scope (tripwire 21).
- **Each command's three delivery routes — menu, key, control — are each pinned** where the command has them (the mode-UX lesson: one test must model the real delivery path). A route that does not exist is named in the task's report.
- Tests are pure functions, censuses or mounted measurements read synchronously; **never press a control and wait for its effect** (tripwire 33). Mounted tests build their views through `MaughamTests/TestSupport/ViewHostFixtures.swift` (`HostBuilderCensusTests`), windows through `TestWindow`.
- **Every census has a planted offender and a control** (`feedback_census_over_warning`).
- **Every `AREA.md` and `CLAUDE.md` is AT its `DocBudgetTests` word ceiling** (`Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`: `CLAUDE.md` 3,081 of 3,081; `Maugham/Views/AREA.md` 7,979 of 7,979; `Maugham/Editor/AREA.md` 6,809; `Maugham/Compiler/AREA.md` 7,934; `Maugham/Stores/AREA.md` 7,988; `Maugham/MCP/AREA.md` 6,856, at 6,854). A word added is a word cut; never raise a ceiling.
- Read before editing: the area guide each path's row in `CLAUDE.md` names; for Task 1 also `Maugham/OpLog/AREA.md` and the permit tripwires 39, 44–50; for Tasks 6–9 workflow rules 7 and 10.
- **Every implementer, every task:** run `./scripts/test.sh` **in the foreground** with a 600000 ms timeout, never in the background and never raw `xcodebuild test`; `./scripts/test.sh core` after touching `Packages/MaughamCore`; run `./gen.sh` after adding or deleting any file; commit before reporting. One branch; **no task merges, pushes or tags**; every task builds final behaviour; no test-data migrations (tripwire 11).
- Every commit message ends with exactly these two lines:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

## Review Focus

1. **The margin carries no model content** (Task 2): a Claude note, an assistant-sealed note stamped "human", a peer's note no seal covers and a check finding with a long message each draw exactly what the rule allows (nothing, nothing, nothing, one grey tick), and the overlay file draws no string.
2. **The signer is read, never guessed** (Task 1): the actor comes from the seal's key through the trust table, the only stamped field never consulted; the four-actor and unknown-key cases each answered.
3. **Every menu key once** (Task 7): the census walks the real `NSApp.mainMenu`, not source text, so a system item and a SwiftUI item that collide are caught.
4. **The help a writer reads is true** (Tasks 8–9): no retired word anywhere bundled, every key the menus bind has a reference row and a cheat-sheet line, every page link resolves.
5. **The piece's word** (Task 6): a Short Story, a Collection, a Screenplay and a Report each read their own noun on every surface the census scans.

---

## Plan 5a — the margin and the carries

### Task 1: Who sealed a note reaches the editor

The design's *My Notes* shows "a note signed by a person (the writer, a human reviewer; decided by the actor key that sealed it, never guessed)". Today nothing on the read side knows which actor sealed an annotation's line: `AnnotationAuthor.sourceKind` (`SpanAnchor.swift:23`, `.claude`/`.human`) is the op's own stamp (`AnnotationDeriver.author(of:)`, `AnnotationDeriver.swift:379`), which any writer of a line could set, and the review render already colours by it (`ReviewPalette.swift:41`). The facts exist at the walk: `PermitPartition.attributableKeys(of:trust:settledByKey:namedBy:)` (`PermitPartition.swift:749`) attributes every applied line to a seal key, and `PermitPartition.actor(ofSealKey:trust:deviceSlug:)` (`:868`) names its `DeviceActor` through `TrustTable.actor(forSealKey:)` (`TrustTable.swift:579`) or `DeviceIdentity.actor(ofDeviceId:signingWith:)` (`DeviceIdentity.swift:120`).

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/PermitPartition.swift`, `Packages/MaughamCore/Sources/MaughamCore/OpLogPermitContext.swift` (a recorder beside `AmendmentPermits`, `:127`, the precedent for an out-parameter of the partition), the Mac load path that already passes `recordingAmendmentsInto:` (find it by grep), `Maugham/OpLog/Document.swift` (the map, and the local append's own actor), `Maugham/OpLog/AREA.md`, `Packages/MaughamCore/Sources/MaughamCore/AREA.md` (one line each, paid for by a cut).
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/PermitPartitionSignerTests.swift` (**new**), `MaughamTests/OpLog/DocumentNoteSignerTests.swift` (**new**).

**Consumes:** the functions above; `PermitPartition.partition(of:class:streamKey:deviceSlug:fileSegmentDigest:trust:settledByKey:decoding:recordingAmendmentsInto:unowned:startedBy:)` (`:141`); `DeviceActor` (`author`, `assistant`, `translator`, `maugham`).

**Produces:**
```swift
// MaughamCore
public final class LineSigners: @unchecked Sendable {      // new; the partition records into it
    public func actor(ofOp opId: String) -> DeviceActor?
}
// Maugham
extension Document {
    func noteSigner(_ annotationId: String) -> DeviceActor?   // new: the creation op's actor, nil = not known
}
```

**Contract:**
- An annotation's signer is the actor of the key that sealed its **creation** line, read exactly as the partition reads it (`attributableKeys` then `actor(ofSealKey:…)`), and recorded per opId by the partition when it walks the file. Where the partition judges nothing (`judgesAnything(trust)` false), the signer is read the same way with the file's own verified seals; a line no seal covers has no signer.
- A note made on this Mac is recorded at its append with the actor whose stream it is appended to — `Document.deviceFor(author:)` (`Document+Annotations.swift:256`) already routes a non-human creation, Claude's and every round's, to the assistant's stream and key — so a new note's signer is known before its seal.
- **Nil is never a person.** No caller may fall back to `AnnotationAuthor.sourceKind`, the display name or the file name's claimed actor for the margin. A census (`DocumentNoteSignerTests.test_theMarginNeverReadsTheStamp`) holds that the margin's source files do not name `sourceKind`.
- Tripwires 39 (no parallel trust table: the recorder holds actors read off the one table, never verdicts), 45 (the partition's call sites are unchanged in number), 37 (a seal line is recognised in `OpLogChain` only).

- [ ] **Step 1: Failing tests.** Core: `test_aLineSealedByTheAuthorKeyIsTheAuthors`, `…AssistantKeyIsTheAssistants`, `test_anUnsealedTailHasNoSigner`, `test_anUnrecordedKeyHasNoSigner`, `test_aSettledSegmentNamesItsKeysActor`. Mac: `test_aNoteMadeHereIsTheAuthorsBeforeItsSeal`, `test_aClaudeNoteStampedHumanIsStillTheAssistants` (a line whose provenance says human, sealed by an assistant key), `test_aPeersNoteIsReadOffItsSeal`.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Disable experiment.** Answer `.author` for an unsealed line; `test_anUnsealedTailHasNoSigner` goes red. Restore.
- [ ] **Step 4:** `./scripts/test.sh core`; `./gen.sh`; `./scripts/test.sh` (foreground, 600000 ms); `./scripts/test.sh phone` (Core changed). Commit `shell p5 task 1: a note's signer is read off its seal`.

**Tripwires:** 37, 38, 39, 45, 49 (no new unsigned-door decision), `OpLogClassifierIsolationTests` (56).
**Hand check:** none (no surface until Task 2).

---

### Task 2: The margin setting, and the amendment to ADR 0027 §1

**Seat.** Before: nothing in the writing surface says where a note or a flagged paragraph is; the writer works To resolve's list, which follows the caret. After: View ▸ Margin ▸ **Off** (the default) / **My Notes** / **Everything Flagged**, remembered per project on this Mac. *My Notes*: a note signed by a person shows as a small dot in the margin beside its paragraph and a faint tint on its words. *Everything Flagged*: adds one grey tick beside any paragraph carrying an item from a check or a round — the same tick whatever the item says and however many there are. Click a dot or a tick: To resolve shows that paragraph's group; the editor's caret does not move and nothing opens in the editor. Focus mode hides the margin whatever the setting. Nothing about this is a toolbar control.

**Files:**
- Create: `Maugham/Editor/MarginMarks.swift` (**new** pure `MarginSetting`, `MarginMarks`), `Maugham/Editor/MarginOverlayView.swift` (**new**; installed as `ReviewMarginRailView` and `ElementGutterView` are, drawing from the cache).
- Modify: `Maugham/Editor/EditorControl.swift` (**new** `margin: MarginMarks` value), `Maugham/Editor/EditorCoordinator.swift` (apply one way in `applyControl`), `Maugham/Stores/UIState.swift` (`marginSetting`, decodeIfPresent `.off`), `Maugham/Views/Resolve/ResolvePane.swift` (publish its `selection`; receive "show this paragraph": set `caretGroup` to the paragraph's group without moving the editor), the window wiring that threads the published selection and the setting into `EditorControl.margin`, `Maugham/Models/MaughamNotifications.swift` + `Maugham/Events/MaughamEvent.swift` (one scoped event), `Maugham/MaughamApp.swift` (View ▸ Margin ▸, three checked items, no key), `docs/adr/0027-the-compiler-and-the-editor-boundary.md` (appended amendment), `docs/adr/0036-to-resolve.md` and `0038-*.md` ("Not yet built" loses the margin), `Maugham/Editor/AREA.md`.
- Test: `MaughamTests/Editor/MarginMarksTests.swift` (**new**), `MaughamTests/Editor/MarginOverlayCensusTests.swift` (**new**), `MaughamTests/Editor/MarginMountedTests.swift` (**new**, through `TestWindow`).

**Consumes:** Task 1's `Document.noteSigner(_:)`; `Document.annotations(filter:)` (as `EditorHost.swift:297` calls it); `ResolveItem` (`.note`, `.finding`, `ResolveItem.swift:26–36`), `ResolveSource` (`ResolveFilter.swift:10`) and `ResolveFilter`; `ResolveReader.read(scope:store:…)` (`ResolveReader.swift:161`) for the open piece's `.piece(docId:includesBookLevel:)` scope; `ResolveGroup.Key` and `ResolvePane.caretGroup` (`ResolvePane.swift:230`); `ResolvedReviewMark` and `AnnotationMarkRenderer` (`ReviewRenderViews.swift`) for how a span maps to glyph rects; `EditorCoordinator.isReadingTranslation`; `UIState.isNoChromeOn`; `MaughamEvent.postPosition(_:)` (`MaughamEvent.swift:223`).

**Produces:**
```swift
enum MarginSetting: String, Codable, CaseIterable { case off, myNotes, everythingFlagged }
struct MarginMarks: Equatable {
    struct Dot: Equatable { let paragraphId: String; let span: NSRange?; let annotationId: String }
    let dots: [Dot]                 // My Notes and Everything Flagged
    let ticks: Set<String>          // paragraph ids; Everything Flagged only
    static let none: MarginMarks
    static func of(setting: MarginSetting, notes: [Annotation], signer: (String) -> DeviceActor?,
                   items: [ResolveItem], selection: Set<ResolveSource>, localName: String, focusMode: Bool,
                   readingTranslation: Bool, reviewRenderIsOn: Bool) -> MarginMarks
}
```

**Contract:**
- **A dot** is an open note whose signer is `.author` (any person's author key: the writer's own Macs, an admitted reviewer's). `.assistant`, `.translator`, `.maugham` and nil draw nothing. A round's notes are minted under the assistant's key (`deviceFor(author:)`, above), so they are never dots; they are ticks.
- **A tick** is a paragraph carrying a To resolve item whose source (`ResolveFilter.source(of:localName:)`, `ResolveFilter.swift:46`) is `.checks` or `.pass(_)`, **among the items the list's selection shows** (`ResolveFilter.visible(_:selection:localName:)`, `:113`; a selection showing no such items gives no ticks). The selection is `ResolvePane`'s private `@State` today (`ResolvePane.swift:228`): the pane publishes it to the window as one value with one writer, and with the column hidden the margin uses the last value published (empty = everything). One tick per paragraph whatever the count; no words, no tint, no count, the same glyph for every source. Items not at a paragraph tick nothing.
- **Nothing** while focus mode is on; nothing over a piece read in a language (the anchors are the source's: `recomputeReviewMarks` already refuses there); nothing for a reference piece. While the review render draws (`isReviewMode`, which read-through inherits or replaces), the dots yield to it (it already marks the same notes) and the ticks still draw.
- **Where:** the trailing margin, so the leading margin stays the screenplay element gutter's and the figure captions'. Each mark is an accessibility element ("Note by <name>", "Flagged paragraph") whose action is the click.
- **The click** posts one window-scoped event; To resolve shows (revealing a hidden right column: a click is a deliberate act) with that paragraph's group open. The editor receives nothing.
- **Cost:** marks recompute once per key (document revision, `annotationsVersion`, items key, setting, filter), never per draw; the overlay draws visible paragraphs only (`ElementGutterView`'s binary search is the precedent).
- **ADR 0027 §1 amendment** (appended, the ADR's own practice; §1's text is left as written): a wordless, opt-in **position** mark derived from a check's or a round's item is permitted; a mark on a person's own note is permitted (a person's words are not a model's); anything carrying model content — a string, a count, a colour that encodes what the item says — is not. It cites the precedents (the line above the prose's "intent may trail the draft", and Brief's clause marks, ADR 0037, ruled within must-not #2 on 2026-11-16) and Denver's approval of all three positions (2026-11-16). It records, as it stands at HEAD, that the review render draws open notes' text, Claude's included, as margin cards (`EditorCoordinator+ReviewRender.swift:66`, `ReviewPalette.swift:41`), and states Denver's answer to Question 2 below.

- [ ] **Step 1: Failing tests.** Pure: `test_offDrawsNothing`, `test_aPersonsNoteIsADotAndATint`, `test_anAssistantNoteIsNeverADotWhateverItsStamp`, `test_anUnsignedNoteIsNeverADot`, `test_aFindingIsOneTickHoweverMany`, `test_aRoundNoteIsATickNotADot`, `test_theWritersToDoIsNeither`, `test_theTicksFollowTheSelection` (Mine alone → none), `test_focusModeHidesEverything`, `test_aPieceReadInALanguageDrawsNothing`, `test_theReviewRenderTakesTheDots`. Census: `test_theMarginOverlayDrawsNoString` (the overlay file contains no text-drawing call: `draw(at:`, `draw(in:` on a string, `NSAttributedString`, `Text(`), with a planted offender and the real file as control. Mounted (`TestWindow`, read synchronously): with Everything Flagged and a finding on paragraph 2, the overlay holds one tick at paragraph 2's line rect; the menu's three items are checked by the UIState value; the event's receiver sets `caretGroup` (read the published value, no wait).
- [ ] **Step 2: Implement; append the amendment.**
- [ ] **Step 3: Disable experiment.** Let `.assistant` count as a person; `test_anAssistantNoteIsNeverADotWhateverItsStamp` goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground). Commit `shell p5 task 2: the margin setting, and ADR 0027 §1's amendment`.

**Tripwires:** 2, 3, 4, 6, 7, 21, `DocBudgetTests` (Editor/AREA.md), `NoPersonaCensusTests`.
**Hand check:** plan-5 checks P1, P2.

---

### Task 3: A figure whose source data changed is in To resolve

**Seat.** Before: a table figure pinned to research cells whose values changed says "changed" only in its own details (`FigurePinSourceRow.statusText`, `FigureInspector.swift:21`) and in the MCP listing (`FigureTools.swift:148`); nothing tells the writer working on the chapter. After: the chapter's To resolve lists "Table 2's source data changed" under the paragraph that places the figure, with Compare… (the details' own sheet) and Open; the tree's dot marks the chapter. ADR 0036's last unbuilt item kind.

**Files:**
- Modify: `Maugham/Views/Resolve/ResolveItem.swift` (**new** case), `ResolveReader.swift`, `ResolveFilter.swift` (its source: Others), `ResolvePane.swift` (the row), `ResolvePresence.swift` (the mark), `Maugham/Stores/DocumentStore+Figures.swift` (a read of the changed set the figure cards already compute, for a scope), `docs/adr/0036-to-resolve.md` ("Still unbuilt" goes).
- Test: `MaughamTests/Resolve/ResolveFigureSourceTests.swift` (**new**); `ResolveReaderTests.test_noResolveSourceLoadsADocument` extended.

**Consumes:** `FigureCardInputs.sourceChanged` / `.pinChanged` (`FigureCardCache.swift:243`), `DocumentStore+Figures.swift`'s `snapshotSourcesChanged` (`:743`, private; expose a read, not a second computation), `PinStatus.sourceChanged`, `FigureListing` (`usedIn`, `FigureListing.swift:37`), the inspector's Compare… (`FigureInspector.swift:537`).

**Produces:** `case figureSourceChanged(figureId: String, docId: String?, paragraphId: String?)` on `ResolveItem`.

**Contract:** one item per figure per piece that places it, at the figure line's paragraph; an unused figure's item is Book-level; durable (it stays until the pin is current again, never replaced by a check); its verbs act wherever listed (a figure is not a manuscript) under the figure's own posture gate (`FigureRowGate`); computed from the cache, never by opening a `FigureDocument` per row.

- [ ] Steps: failing tests (`test_aChangedSourceListsUnderThePlacingParagraph`, `test_anUnusedFigureIsBookLevel`, `test_aCurrentPinListsNothing`, `test_theTreeMarksThePlacingChapter`, `test_noReadOpensAFigureDocumentPerRow`); implement; disable experiment (drop the item from the presence read: the tree test goes red); `./scripts/test.sh`. Commit `shell p5 task 3: a figure's changed source is in To resolve`.

**Tripwires:** 4, 47/51, `ResolveReaderTests`.
**Hand check:** P3.

---

### Task 4: The tree's carries

ADR 0038 "Known limits", each done or dropped on its merit (no later list):

- **Done — a drop of several files is one undo step.** Today each file is its own (ADR 0038 §12 Cost). Writer: drops five photos on a group, ⌘Z once, all five go. Wrap the drop's ingests in one undo group named for the drop ("Undo Add 5 Files").
- **Done — a closed Collection script's Scenes follow a peer's sync.** Re-key `PieceFoldIndex`'s scenes on the same arrival signal `ResolvePresenceWatch` already refreshes on.
- **Done — a card listed in two open folds carries one tag per row.** A palette card pinned to two chapters, both folds open: today both rows share `TreeRowTag.pullUp(_)` (`BinderTreeSections.swift:2011`) and the `List` selects both. The tag carries the fold's piece id; `BinderTreeSelection`'s readers map it back.
- **Done — Space during type-select.** A Space pressed while the list's type-select is collecting (a letter key within the system's type-select interval) is type-select's, not `TreeRowKeys.returnOrSpace`'s (`BinderTreeSections.swift:1876`).
- **Dropped — the removal busy check sees only this window's compile.** Removal hides one tag and loses nothing; a compile finishing in another window for a hidden edition writes a book that shows again when the language is added back.
- **Dropped — the Canvas row's dot is per window, not persisted.** It marks a drop made in this window; another window did not see the drop happen.
- **Dropped — a re-click on the selected tree row does not re-jump the edition's book.** The header's "starts on page N" link is the route, and the release notes say so; a re-click would need a gesture the `List` does not deliver (tripwire 9).

**Files:** `Maugham/Views/BinderTreeSections.swift`, `Maugham/Views/TreeDropIntent.swift` and the drop performer it routes to, `Maugham/Views/PieceFoldContents.swift`, `Maugham/Views/BinderPieceFold.swift`, `docs/adr/0038-*.md` (Known limits: each line marked done or dropped with its reason). Tests in `BinderTreeSelectionTests`, `PieceFoldIndexTests`, `BinderTreeDropRoutingTests` (add).

- [ ] Steps: failing tests (`test_aFiveFileDropIsOneUndoStep`, `test_aPeersEditMovesAClosedScriptsScenes`, `test_aCardInTwoFoldsHasTwoTags`, `test_spaceDuringTypeSelectIsTypeSelects`); implement; disable experiment (drop the piece id from the tag: the two-folds test goes red); `./scripts/test.sh`. Commit `shell p5 task 4: the tree's carries`.

**Tripwires:** 3, 4, 9, 14 (the drop's moves through the typed mover), 31, 33.
**Hand check:** P4.

---

### Task 4a: Research in the tree is either the book's or a chapter's

**Owner's ruling, 2026-11-22** (hand check: "All research shows up under research now, and I can't
tell which relates to which chapter. And which is top level, part of the book."). Agreed: either/or.

**Contract**

- The tree's Research section lists only whole-book research: shared items linked to no piece.
  Today `TreeSectionDerivation.sharedResearchRoots` lists every shared item, and a novel chapter's
  fold (`pieceFold`, `.sharedPlusLink`, `linkedResearchIds`) lists its links as well, so a linked
  note shows twice and the section says nothing about which is which.
- Research linked to a piece shows only in that piece's fold. Linked to two pieces: in both folds.
  A group whose every item is linked still shows if it holds anything whole-book; a linked item
  inside a whole-book group is filtered out of the section, not the group (derive, never move files).
- Dragging a research row onto a piece links it (it leaves the section); dragging a fold row onto
  the Research section unlinks it from that piece (whole-book again once no piece links it). The
  row menus say the same in words: "Move to Chapter…" / "Make Whole-Book". Collections keep owned
  research (`.pieceFolder`) as built; the two project kinds now read alike.
- Selecting a piece opens its fold when it has research in it, so its research is in sight. It
  never closes a fold the writer opened.
- Nothing becomes unreachable: Find, Show in Tree (`revealResearch`), a wiki-link's jump and a
  pulled-up note's "Show in Tree" open the owning fold and select the row there. The Research `+`
  and ⌘V still make whole-book research; a fold's New Note makes the piece's.
- The fold's link glyph goes: with either/or there is nothing to tell apart.

**Tests**: a derivation table (unlinked / linked to one / linked to two / inside a group / link to a
deleted piece falls back to whole-book); the reveal routes over a closed fold; drag both ways through
`DropIntent`; a census that the section and the fold ask one predicate for "is whole-book".

**Guide and MCP**: Task 8 and Task 9 describe it; `list_research` output is unchanged.

### Task 5: Reading, the toolbar and MCP — the remaining carries

- **Done — a screenplay read in a language groups by scene** in To resolve, as its source does (`ResolveGrouping`'s scene grouping over the source sequence).
- **Done — VoiceOver.** The translation badge dots get accessibility elements ("Out of date", "Not translated yet"); Brief's Details menu reads its offers, not an empty value.
- **Done — the toolbar's leading reserve is measured**, mounted at the window's minimum width through `TestWindow`, reading each item's frame synchronously: the view switch, the language switch, the running-round indicator in its short form, read-through's padlock (when read-through has landed) and the right-column toggle fit without overflow. If a test host lays out no `NSToolbar` item frames, the report says so with the measurement attempted, and the estimate stands as a recorded limit.
- **Done — Claude writing into a removed edition.** `write_translation` into a language the writer removed is refused in words ("The writer removed the Spanish edition; it comes back when they add Spanish again."), so nothing is written where the writer cannot see it.
- **Dropped — a peer Mac's rounds-ledger write arrives with no event.** It needs a file presenter on a synced directory, a sync change outside this milestone; the next re-render shows it.
- **Dropped — the Earlier letters choice resets when the faces change.** Intended: the head returns to the latest letter.
- **Dropped — the empty line and "N not translated yet" are two sentences.** Joining them reads the translation twice.

**Files:** `Maugham/Views/Resolve/ResolveGrouping.swift`, `ResolvePieceInLanguage.swift`, `Maugham/Editor/TranslationBadgeOverlayView.swift`, `Maugham/Views/Brief/BriefDetails.swift`, `Maugham/MCP/Tools/TranslationTools.swift`, `Maugham/Views/ProjectWindow.swift` (only if the measurement moves an item), `docs/adr/0038-*.md` (Known limits). Tests: `ResolvePieceInLanguageTests`, `TranslationSourceUnderTests`, `BriefFootTests`, `TranslationToolsTests` (add), `ToolbarWidthTests` (**new**).

- [ ] Steps: failing tests; implement; disable experiment (let `write_translation` accept a removed language: its test goes red); `./scripts/test.sh`. Commit `shell p5 task 5: reading, the toolbar and MCP carries`.

**Tripwires:** 4, 10, 33.
**Hand check:** P5.

---

## Plan 5b — the words, the menus and the help

### Task 6: One noun for a piece, one vocabulary for a round, no retired words

**Seat.** Before: a Short Story's single text is "this chapter" in To resolve; a Report's sections are chapters; "Open this chapter to rewind it" in a Collection; the Statistics window says "Words by chapter" in a screenplay; the tree's menu says "New Document" and "New Group" in a novel whose Status calls them chapters and Parts; a to-do is a "Task" in Undo's title and a "to-do" in To resolve; the left column is "the binder" in some places and "the tree" in others; the guide's old panes survive in app strings ("Opens the Intent pane", "Pick another piece in the inspector"). After: every surface says the project's own word, one word per thing.

**The piece's word** (Question 3 settles the two marked ★):

| Project | A piece | Plural | A group | The whole |
|---|---|---|---|---|
| Novel | chapter | chapters | Part | the Book |
| Short Story ★ | story | — | — | the Book |
| Collection | piece (a screenplay piece: script) | pieces | — | the Book |
| Screenplay | script; a slugline is a scene | scenes | — | the Book |
| Report ★ | section | sections | Part | the Book |

**The words for a round** (Question 1 settles the verbs):

| Term | Meaning | Where it is used |
|---|---|---|
| round | one run of one reader over one piece: a translator's into one language, an editor's in one pass, the designer's over the book | report titles, To resolve heads, letters, Status |
| Translate This Chapter / Translate Whole Book ★ | the buttons that start a translator's round (today "Run" and "Run Whole Book") | To resolve heads (piece in a language, edition), the menu item if Denver takes table row 7 |
| Translating | a translator's round running | toolbar indicator, heads (unchanged) |
| Run Round / Fresh Eyes | an editor's round (⌃⌘R, ⌃⇧⌘R) | File, the board's chips ("Run Gould's Round") |
| Run Design | the designer's round | the Source edition's head |
| letter | what a reader writes at the end of a round | heads, reports |
| question | a translator's question | the Questions chip, ⌘⌥L |
| To look at | what a translation round leaves to settle | done in plan 4; census stands |
| out of date / not translated yet / left over | a paragraph's state in a language | the line over the text, heads |
| edition; Source | one language of the book; the writer's own | tree, menus, switch |
| to-do | the writer's own item (Undo titles, history rows, Status) | everywhere the writer reads; MCP tool names keep `task` (wire contract) |
| binder ★ | the left column (Question 4) | guide, tour, accessibility, empty states |
| check; finding | ⌘R's run; one thing it found | unchanged |

**Files:**
- Create: `Maugham/Views/PieceNoun.swift` (**new** `PieceNoun.of(_ item: StructureItem?, in manifest: ProjectManifest) -> PieceNoun` with `singular`, `plural`, `capitalised`; asks the manifest's profile through `ProjectKindName`'s rule and the item's format by capability, tripwire 55). `ResolveGrouping.pieceNoun(isScript:projectType:)` (`ResolveGrouping.swift:142`), `FiledUnder.pieceNoun(_:projectType:)` (`FiledUnder.swift:101`) and `HistoryPaneStatics.pieceNoun(docId:store:)` (`HistoryPaneStatics.swift:693`) become callers of it or are deleted — one noun function.
- Modify: every file the census lists. At HEAD, single-line string literals naming "chapter" number 65 across 41 files (`Maugham/Views/Publish/TranslationRunState.swift` 8, `ResolveEditionItems.swift` 4, `ResolveGrouping.swift` 3, `PeopleAndDevicesConfirmation.swift` 4 (sample names, allowed), `ReviewBoardPane.swift` 2, `EditionStatusView.swift` 2, `BriefPartView.swift` 2, `ResolvePieceInLanguage.swift` 2, `HelpClaudeDesktopSheet.swift` 2, `FigureInspector.swift` 2, and one each in 31 more); the implementer's census reads multi-line literals too. Retired-word strings in app and MCP text, single-line, at HEAD: "Inspector" 7 files, four of them seen by the writer or Claude (`KeyboardShortcuts.swift:107`, `UpdateNoteTool.swift:28`, `CitationCompletion.swift:37`, `PromotionPerformer.swift:187`; the other three are comments or keys: `MaughamApp.swift:856`, `PieceWriters.swift`, `MaughamNotifications.swift`), "pane" 8 files (`TaskReadTools.swift` 3, `CanvasAccessibility.swift` 2, `IntentStrip.swift:108`, `TaskRow.swift:104`, others), "desk" 2 (`EditionStatus.swift:44`, `InboxTools.swift:8` "off-desk", allowed), "Synopses"/"corkboard" (`WelcomeCarousel.swift`, Task 9's), `CanvasTools.swift:188` ("the marks the inspector shows"); the stale "translation review" comments the ledger names (`FigureGridGate.swift:30`, the `InsertMenuGate` comment at `MaughamApp.swift:733`).
- Modify: the To resolve head's "Run"/"Run Whole Book" titles per Question 1; `Document+Tasks.swift`/`ResolveTaskVerbs.swift`/`HistoryRow.swift` undo and history titles ("Change To-Do Status", "Archive Done To-Dos"); `ReviewBoardPane.swift`'s "Open" column (ADR 0038 Known limits: becomes "Notes open"). Menu titles are Task 7's.
- Create: `MaughamTests/WordingCensusTests.swift` (**new**).

**Contract:**
- `test_noUserFacingStringHardCodesAPieceNoun`: no Swift string literal under `Maugham/` outside `PieceNoun.swift` contains `\b[Cc]hapters?\b`, except a named allow-list, each with its reason (example titles such as "Chapter 4" in `PeopleAndDevicesConfirmation`, `EmissionContract`'s heading example, the sample projects). "story" and "section" are not grepped (too many innocent uses); the table test below covers them.
- `test_eachProjectKindReadsItsOwnNoun`: a table over the five kinds through the surfaces that take the noun (To resolve's whole-piece group, Filed in Brief, Open this … to answer its notes, Open this … to rewind it, Run's scope line, the board's and the edition Status's empty states, the Statistics section title, Brief's Part line, the tree's New item).
- `test_noAppStringUsesARetiredWord`: Swift string literals under `Maugham/` contain none of `Inspector`, `inspector` (as a surface name), `\bpanes?\b`, `Department`, `\bdesk\b`, `[Tt]ranslation review`, `review pane`, `[Ss]ynops`, `corkboard`, `\bTasks?\b` in a title; MCP tool descriptions are read as values (`MCPToolCatalog.all`), not text, so a description built by concatenation is caught. Allow-list with reasons (`maughamTestOpenProject` dev strings; "off-desk" in `InboxTools`; the `task` wire nouns in MCP parameter names).
- `test_oneNounFunction`: no other `func pieceNoun` / `func noun(` returning a piece's word exists under `Maugham/` (census, planted offender, control).

- [ ] **Step 1:** Write the censuses; run; expected red with today's list.
- [ ] **Step 2:** Implement the noun and the vocabulary; empty the lists. Where a sentence reads worse with the noun swapped ("1 section" beside "the imprint chosen"), rewrite the sentence, do not bend the noun.
- [ ] **Step 3: Disable experiment.** Make `PieceNoun.of` answer "chapter" for a Short Story; `test_eachProjectKindReadsItsOwnNoun` goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground); Release build. Commit `shell p5 task 6: the project's word for a piece, one word per thing`.

**Tripwires:** 13 (identity strings), 19, 54, 55, `NoPersonaCensusTests`, `TranslationVocabulary` census (`EditionStatusRowsTests.test_whatARoundLeavesIsToLookAtEverywhereTheWriterSeesIt`), `DocSyncTests` (tool counts).
**Hand check:** P6.

---

### Task 7: The menus as approved, every key once

**Precondition:** Denver has approved "The menus, on paper" below (row by row, ★ rows answered), and read-through has landed. Task 7 builds the approved table; a row he rejects is built as he says or not at all.

**Files:**
- Modify: `Maugham/MaughamApp.swift`, `Maugham/Views/LanguageSwitch.swift` (`FocusedReadingItems`), `Maugham/Views/CentreViewSwitch.swift` (`FocusedCentreViewItems`), `Maugham/Views/BinderView.swift`, `CollectionPiecesPane.swift`, `PieceRowMenus.swift`, `BinderPieceFold.swift`, `ResearchTree.swift`, `BinderTreeSections.swift` (palette rows), `TreeEditionRows.swift`, `Maugham/Views/Publish/EditionCastVerbs.swift` (titles), `Maugham/Resources/KeyboardShortcuts.swift` (the cheat sheet, re-curated: a Tree category for ↑↓, Return/Space and ⌘↓; ⌃⌘1/2/3; ⌘[; the margin has no key), `docs/guide/reference.md` (the shortcut table only; the rest is Task 8's).
- Create: `MaughamTests/MenuBarCensusTests.swift` (**new**).
- Modify: `MaughamTests/DocSyncTests.swift` (the key extractors read every source file that declares a menu key, not `MaughamApp.swift` alone, and a key held in a named constant such as `LanguageSwitch.nextKey`), `PaneKeyspaceTests`, `RightColumnMountingTests.test_everyPositionAndPullUpHasAMenuShortcut`.

**Contract:**
- `MenuBarCensusTests.test_everyMenuKeyIsBoundOnce`: walks the real `NSApp.mainMenu` in the test host recursively (system items included), collects `(keyEquivalent, modifierMask)` for every item, and finds no two equal, except a named allow-list each with its reason (Format ▸ Table ▸ Fill Right has no glyph because ⌘R is File's; a focused item and its disabled twin). A control: a planted duplicate in a synthetic `NSMenu` is reported.
- `test_everyKeyTheMenusBindHasACheatSheetLineAndAReferenceRow`: from the same walk, not from source text — so ⌃⌘1/2/3, ⌃⌘L and anything bound outside `MaughamApp.swift` are seen.
- `test_noMenuItemTitleRepeatsInOneMenu` (two "Outline"s was this).
- **Three routes pinned** for each new or moved command: the menu item's action posts what the key's receiver reads (source census, `RightColumnMountingTests`' shape), the key's binding is the walk's, and the control (where there is one: the tree's ⌘↓, a row menu's item) reaches the same receiver.
- **Enabled state per focused window:** an item that acts on a project window is disabled when none is in front (Welcome, Help, Statistics), except Run's four (`RunButtons`' standing ruling: never greyed). A pure function per item over the focused values, tested as a table.

- [ ] Steps: failing censuses (today: two "Outline" items in View; `reference.md` has no row for ⌃⌘1/2/3 or ⌃⌘L and still names ⌘1–4 as personas; the cheat sheet lacks ⌃⌘1/2/3 and ⌘[ and lists "Toggle inspector column"); build the approved rows; disable experiment (bind a second item to ⌘⌥R: the walk goes red); `./gen.sh`; `./scripts/test.sh` (foreground); Release build (a `ProjectWindow`-adjacent change). Commit `shell p5 task 7: the menus, every key once`.

**Tripwires:** 5, 21, 33, `PaneKeyspaceTests`, `DocSyncTests`, `InsertCommandTests.test_theInsertShortcutsAreBoundOnceAndListed`, `FigureGridMenuTests.test_theTableShortcutsAreBoundOnceListed_andNotTheGridsOwnKeys`.
**Hand check:** P7.

---

**Added by the owner, 2026-11-22 ("Yes right click is a good idea"):** a writer can comment on
their own text without entering read-through. The text's right-click menu on a selection gains
"Comment…" (and "Suggest…" where the posture offers it), and Edit gains the same item with a key
chosen in this task's key pass (every key once). It opens the same composer the read-through
selection toolbar opens; the floating toolbar itself stays read-through's. Offered by `Posture`,
never by read-through; pinned through the real menu builder, with the menu table gaining its row.

### Task 8: The guide (merge gate)

**Seat.** Before: Help ▸ Maugham Help opens a guide whose first pages teach four personas and ⌘1–4, an Inspector, a Department desk (35 mentions on 8 pages), a translation review pane (9 on 4), and an index that titles page 5 "Inspector, Research & Outline". After: the guide teaches the window that ships, in the order a writer meets it.

**Pages** (`docs/guide/`, bundled by `project.yml:58`, served in the app by `HelpWindow` and over MCP by `get_help` through `HelpTopicIndex`, `Maugham/Help/HelpTopicIndex.swift`):

| Page | Today | Becomes |
|---|---|---|
| `getting-started.md` | personas 7, Inspector 18, pane 12 | the window: the binder picks the subject; the centre; the right column's three positions; the toolbar; a first chapter |
| `structure-and-binder.md` | personas 2, Inspector 2 | the binder's rows (Book, Inbox, Canvas, manuscript, Figures, Research, Palette, Editions, Trash); the click rule; the fold; the dots; dragging and the drop look; the keys |
| `right-pane.md` → slug `right-column` | personas 7, Inspector 9, desk 2 | To resolve (filters, density, lifetimes, verbs), Brief (line, Going for, Decided, the marks, the foot), the pulled-up thing (Back, Open in Centre, Details of …); title "To Resolve, Brief & Pulled Up" |
| `editor-and-focus.md` | Inspector 4, translation review 2 | focus, the line above the prose, **the margin setting**, the status line's target, reading in a language (pointer) |
| `research.md` | personas (by mode) 8, Inspector 5 | research in the binder and the fold, linked vs owned, pulled up beside and editable |
| `tasks.md` | pane 5 | to-dos in To resolve (Mine), inline to-dos |
| `compiler.md` | modes 12, pane 23 | ⌘R / ⌘⇧R; findings in To resolve (Checks); the marks in Brief; Run's two commands |
| `review-passes.md` | desk 3, Inspector 3 | passes, rounds, the ladder at To resolve's head, Status, Earlier letters |
| `sense-pass.md` | personas 4, pane 5 | the same, for the sense pass |
| `annotations-and-suggestions.md` | pane 17 | notes in To resolve; the margin; review render as read-through ships it |
| `publishing.md` | desk 8, personas 4 | editions as binder rows; the edition's centre (its book, Compile…, imprints), Status, Brief (brief, cast) |
| `translation-review.md` → slug `translation` | desk 2, review pane 4 | Add Language…, Remove Edition…, a round, reading a chapter in a language, its To resolve, the running indicator |
| `publish-department.md` | desk 17 | **deleted**; its content merged into `publishing.md` (design, designer, imprints) and `translation.md` (translators, cast) |
| `backups-and-history.md` | pane 3 | History pulled up (⌘⌥H), Rewind and "Open this chapter to rewind it", checkpoints |
| `screenplay.md`, `claude-desktop.md`, `people-and-devices.md` | small | swept for retired words; the script's Scenes |
| `reference.md` | personas 5, the ⌘⌥ rows false | the shortcut table (Task 7's), on-disk layout, troubleshooting, all true |

**Files:** the pages above; `docs/guide/index.json` (titles, slugs, order); `MaughamTests/DocSyncTests.swift` (`positionsTheGuideDoesNotNameYet` becomes `[]`, `DocSyncTests.swift:458`); `MaughamTests/HelpWordsCensusTests.swift` (**new**); any in-app link that names a renamed slug (find by grep: `HelpWindow`, `HelpClaudeDesktopSheet`, MCP tool descriptions, skills).

**Contract:**
- `HelpWordsCensusTests.test_noBundledHelpUsesARetiredWord` over everything bundled for the writer or Claude to read: `docs/guide/**`, `docs/skills/**`, `Maugham/Resources/Samples/**`, `Maugham/Resources/*-syntax.md`. Retired: `persona`, the four persona names used as a mode (`\b(Plan|Author|Review|Publish) (persona|mode)\b`, `\bin (Plan|Author|Publish)\b`), `Inspector`, `Department`, `\bdesk\b` (not Desktop), `translation review`, `review pane`, `<Name> pane` for every retired pane (Annotations, Diagnostics, Tasks, Intent, References, History, Translation, Inbox, Outline), `This Piece`/`All Pieces`, `⌘4`, `segment`, `Pull Up Previous`, and, once read-through has landed, `Lock Research`/`Toggle Review Mode`. Planted offender per word; a control that a true sentence ("Claude Desktop", "the History of a chapter") passes.
- `GuideDocsDriftTests` (index ↔ files; every relative link and anchor resolves) and `DocSyncTests` hold; `GuideCorpusRenderabilityTest` renders every page.
- Every page describes only what ships at the commit (rule 7): no "coming soon", no plan names.
- A page says each thing once and links; the guide's total length must not grow by more than the deleted page.

- [ ] Steps: census first (red: the counts above); rewrite; the slug renames with their links; disable experiment (put one "Department desk" back in `publishing.md`: the census goes red); `./gen.sh`; `./scripts/test.sh` (foreground). Commit `shell p5 task 8: the guide describes the window that ships`.

**Tripwires:** `DocSyncTests`, `GuideDocsDriftTests`, `HelpTopicIndexTests`, `GetHelpToolTests`.
**Hand check:** P8.

---

### Task 9: The tour, the samples, the sheets and the help Claude reads

**Seat.** Before: the welcome tour says "The Binder holds your structure" and "Synopses, status, tags, word targets, to-do checklists, [[wiki-links]], an Outline corkboard"; the sample novel's second chapter is headed "The Inspector" and says ⌘⌥O swaps the right pane into the Outline; its research note is "About the Research Pane"; the Fountain syntax sheet sets a page target "in the Inspector (⌘⌥I)"; the cheat sheet lists "Toggle inspector column"; skills say "pane". After: each says what ships.

**Files:**
- `Maugham/Views/WelcomeCarousel.swift` (cards `.structure` and `.organize`; the copy is drafted for Denver's read in the hand check, Calls 9): the binder picks the subject; To resolve and Brief beside the draft.
- `Maugham/Resources/Samples/novel/manuscript/0[1-3]-*.md`, `novel/research/about-this-sample.md`, `screenplay/manuscript/01-welcome.fountain` (rewritten as a walk through the window: click a chapter, ⌘1, ⌘2, a fold, the Book's Status).
- `Maugham/Resources/fountain-syntax.md:306`, `markdown-syntax.md` (swept), `Maugham/Views/HelpClaudeDesktopSheet.swift`, `Maugham/Views/SyntaxHelpSheet.swift` (title per table row 56).
- `docs/skills/*/SKILL.md` (bootstrap: "Inspector" 1, "pane" 1; translation-pass: "translation review" 1, "pane" 1; visual-language: "pane" 2; editing-pass: modes 2) and every MCP tool description and the server's instructions that name a surface (read as values: `MCPToolCatalog.all`), including `CanvasTools.swift:188` and `UpdateNoteTool.swift:28`.
- Tests: `WelcomeCarouselTests`, `SampleProjectBuilderTests` (the samples still load with anchors), `HelpWordsCensusTests` (Task 8's, now also over the carousel's card values and MCP descriptions), `SkillIndex` tests.

**Contract:** the tour stays eight cards; no card names a key the cheat sheet does not list; a sample's text names only verbs that exist (census: every `⌘`-token in `Samples/**` is a key the menu walk of Task 7 binds).

- [ ] Steps: failing censuses; rewrite; disable experiment (put "Inspector" back in the sample: red); `./scripts/test.sh` (foreground). Commit `shell p5 task 9: the tour, the samples and the help Claude reads`.

**Tripwires:** 10 (MCP response size: descriptions only), `DocSyncTests.test_toolCountSyncedAcrossDocsAndCatalog`.
**Hand check:** P9.

---

### Task 10: The record

**Files:**
- Create: an ADR at the next free number (read-through's plan may take 0039): **the words and the menus** — the piece's noun and its one function, the round vocabulary, the binder's name, the menu map and its census, the help census; each decision marked the agent's or Denver's.
- Modify: `docs/adr/README.md`; ADRs 0035–0038 "Not yet built" (plan 5's lines closed; 0035's Inbox-at-scale line stays, as Denver's open decision); `docs/adr/0038-*.md` Known limits (Tasks 4–5 verdicts); `CLAUDE.md` and the area guides (map entries for files created or deleted; budgets held); `docs/INDEX.md`; `docs/roadmap.md` (the desk 21 times, the review pane 5: swept, workflow rule 10); the register's claims that name a renamed surface (fix, pin, flip in the branch).
- Modify: `docs/release-notes/DRAFT-shell-without-personas.md` — add plans 1–3's and plan 5's parts, written for the writer (the persona bar gone, the binder picks the subject, To resolve, Brief, the pulled-up thing, the fold, the margin, the menus, the words); fold the release checklist below into its Technical notes.
- Modify: this plan's "Hand checks" if any task changed a check's wording.

**Release checklist (found, not planned — no task merges, pushes or tags):**
- **Schema:** `ProjectManifest.currentSchemaVersion` stays 10 across the branch; no paired phone release is forced.
- **MaughamCore changed** in five production files on the branch (`ProjectManifest.swift` `removedEditions`, `RulingsSection.swift`, `ReviewPass.swift`, `RegistryReader.swift`, `BackupSignature.swift`) and Task 1's: the phone builds them, so `./scripts/test.sh phone` must be green before the cut. The one phone file reading a changed type is `MaughamPhone/Settings/BookStandingRow.swift` (`RegistryReader`); nothing the phone shows changes, so a Mac-only release is the expectation — the release-notes author confirms.
- **MCP:** no tool added or removed on the branch (catalog unchanged); descriptions changed (Task 9), `translation_status`'s `last_round` (plan 4), `write_translation` refuses a removed edition (Task 5); the `get_help` topic slugs `right-pane`, `translation-review` and `publish-department` are renamed or gone (Task 8) — the notes say so for anyone whose Claude cached a slug.
- **Derived files** gain optional keys (plan 4's ledger and sidecar; Task 2's `UIState.marginSetting`): an older build drops them, nothing lost.
- **Gates:** `./scripts/test.sh full` (no skips), `core`, `phone`, and a Release build; then the whole-branch review of plan 5 and the milestone's whole-branch review (workflow rule 9).

- [ ] Steps: write; `./scripts/test.sh full` (foreground, 600000 ms); Release build. Commit `shell p5 task 10: the record`.

**Tripwires:** `DocBudgetTests` (all ceilings), `DocSyncTests`, the ADR index census.

---

## The menus, on paper (for Denver to approve before Task 7)

★ = a product choice for Denver; every other row is the agent's call, his to overrule. "Keep" rows were reviewed and change nothing. A slot is another plan's.

| # | Menu | Item | Today | Proposed | Why |
|---|---|---|---|---|---|
| 1 | Maugham | Check for Updates…; Settings… ⌘, | as is | keep | — |
| 2 | File | New Project… ⌘N; Open Project… ⌘O; Open Recent ▸ | as is | keep | — |
| 3 | File | Save ⌘S | a checkpoint, with the flash | keep the title "Save" | the ⌘S reflex (invariant) |
| 4 | File | Save Checkpoint As… ⌘⇧S | as is | keep | — |
| 5 | File | Check Writing ⌘R; Reread ⌘⇧R | as is | keep | — |
| 6 | File | Run Round ⌃⌘R; Fresh Eyes ⌃⇧⌘R | fixed titles | titled for the focused piece's pass ("Run Gould's Round"), as the board's chip is; still never greyed | "Run Round" does not say whose |
| 7 | File | — | a translator's round has no menu item or key | ★ "Translate This Chapter into Serbian" (reading in a language) / "Translate Whole Book into Serbian" (an edition faced); no key; hidden title "Translate…" disabled elsewhere | the act has only a button at To resolve's head |
| 8 | File | Restore from Backup… | as is | keep | — |
| 9 | File | Tidy All Filenames | between Restore and Add Research File | move to the last group, beside Project Settings… | housekeeping, not creation |
| 10 | File | Add Research File… | as is | keep, first in a "new things" group | — |
| 11 | File | — | no "new chapter" item; the binder's + is the only route | ★ "New Chapter" / "New Part" (titled by the noun; a Collection keeps row 16's three) | a missing verb |
| 12 | File | Add Language… | in the Promote group | keep; own group with row 13 | grouping |
| 13 | File | Remove Edition… | fixed title | "Remove Spanish Edition…" when one is selected; disabled "Remove Edition…" otherwise | say what goes |
| 14 | File | Promote… ⌘⇧↩ | between the edition items | "Promote Canvas Selection…", in the "new things" group | two Promotes (row 63); it is a canvas verb |
| 15 | File | Show Project Statistics | as is | keep | — |
| 16 | File | New Prose Story; New Screenplay (Collection); Link Existing Project… | disabled outside a Collection | keep in a Collection ("New Screenplay" without the parenthesis); a novel shows row 11 instead | one group per kind |
| 17 | File | Share Project via iCloud…; Project Settings… ⌘⇧, | as is | keep | — |
| 18 | Edit | Undo / Redo | "… — Returns in Source" while reading | keep | — |
| 19 | Edit | Find… ⌘F; Find Next ⌘G; Find Previous ⌘⇧G; Find in Project… ⌘⌥F | as is | keep | — |
| 20 | Edit | Translator's Note… ⌘⌥C | as is | keep | — |
| 21 | Edit | Restore Last Deletion ⌘⌥Z | as is | keep | — |
| 22 | View | Toggle Focus Mode ⌘\ | "Toggle" title | "Focus Mode", checked when on | state, the macOS way |
| 23 | View | Toggle Full-Screen Focus ⌘⇧F | "Toggle" title | "Full-Screen Focus", checked when on | the same |
| 24 | View | Toggle Review Mode ⌘⌥⇧R | manual review | **slot: read-through's item and key** (read-through's plan removes this) | — |
| 25 | View | Lock/Unlock Research and Figures ⌘⌥⇧L | the padlock | **slot: removed by read-through's plan**; its padlock becomes read-through's | — |
| 26 | View | Toggle Research Preview ⌘⇧P | "Toggle" title | "Show/Hide Research Preview" by state | the same |
| 27 | View | Hide/Show Right Column ⌘⌥0 | titled by state | keep | — |
| 28 | View | — | the margin has no item | Margin ▸ Off / My Notes / Everything Flagged (checked); no key (Task 2) | the design's place |
| 29 | View | Read In ▸ Source, languages | as is | keep; a "Reading" group with 30–31 | — |
| 30 | View | Read In Next Language ⌃⌘L | as is | keep | — |
| 31 | View | Show Source Under Translation | no key | ★ ⌃⇧⌘L | the switch's menu has it; the keyboard does not |
| 32 | View | To Resolve ⌘1 | as is | keep | — |
| 33 | View | To Resolve: Checks ⌘⌥D; Rounds ⌘⌥A; Mine ⌘⌥T | as is | keep | — |
| 34 | View | To Resolve: Questions ⌘⌥L | where a scope has none, To resolve shows with its old filter | land on Questions with its own empty line ("No questions from the translator here") | silence reads as broken |
| 35 | View | To Resolve: <Language> Edition ⌘⌥K | dynamic; a colon like the filters | "Serbian Edition's To Resolve" (disabled "An Edition's To Resolve") | it moves the faces; the colon titles filter this subject |
| 36 | View | Brief ⌘2 | as is | keep | — |
| 37 | View | Brief: the Line ⌘⌥I; Brief: Going For ⌘⌥N | colon titles | "Write the Line"; "Write Going For" | they put the cursor there |
| 38 | View | Pulled Up ⌘3 | as is | keep | — |
| 39 | View | Pull Up What I've Learned ⌘⌥G; First Reader ⌘⌥Y; Visual Language ⌘⌥V; History ⌘⌥H | as is | keep | — |
| 40 | View | Back ⌘[ | as is | keep | — |
| 41 | View | — | ⌘↓ opens the selected binder row in the centre; no menu item | "Open in Centre", **no key equivalent on the item** (⌘↓ stays the binder's own key: as a menu equivalent it would take ⌘↓, "end of document", from every text view); enabled for the selected row or the pulled-up thing; the cheat sheet lists ⌘↓ under Binder | findable without stealing a key |
| 42 | View | Open the Piece's Fold ⌘⌥E | "Piece" | "Show the Chapter's Fold" (the noun) | the project's word |
| 43 | View | Research ⌘⌥R; Palette ⌘⌥P; Inbox ⌘⌥B | bare nouns | "Go to Research"; "Go to Palette"; "Go to Inbox" | verbs say they move |
| 44 | View | Outline ⌘⌥O | selects the Book row; a second "Outline" is ⌃⌘2 | "Go to the Book" | two items, one title |
| 45 | View | — | the Canvas has no item | "Go to the Canvas", no key | a primary place with no menu route |
| 46 | View | View as Cards / Outline / Status ⌃⌘1/2/3 (an edition: Book ⌃⌘1, Status ⌃⌘3) | as is | keep (Status is ⌃⌘3 everywhere) | — |
| 47 | View | (dev) Dump Coordinator Leak Probe | dev builds | keep | — |
| 48 | View | order | toggles, Read In, column, lock, then positions, then places, then views | toggles; Reading; Margin; the right column's three groups; the binder's places; the centre's views | where each lands |
| 49 | Insert | Table ⌘⇧T; Convert to Table Figure ⌘⌥⇧T; Footnote ⌘⇧N; Figure… ⌘⇧I; Existing Figure…; Citation… ⌘⇧C; Cross-Reference… ⌘⇧X | as is | keep | — |
| 50 | Format | Table ▸ … (⌘⌥↑↓←→, ⌘D) | as is | keep | — |
| 51 | Window | system | as is | keep | — |
| 52 | Help | Maugham Help ⌘? | as is | keep | — |
| 53 | Help | Welcome to Maugham | opens the tour | keep | — |
| 54 | Help | Sample Projects ▸ Novel, Screenplay | as is | keep | — |
| 55 | Help | Set up Claude Desktop…; Acknowledgements | as is | keep | — |
| 56 | Help | Syntax Reference ⌘/ | the sheet has a Keyboard tab | "Syntax & Keyboard Shortcuts" | reference.md sends readers there for keys |
| 57 | all | enabled state | View items act with no project window in front | disabled with none in front, Run's four excepted | a press that does nothing |
| 58 | Binder: a novel's piece | New Document; New Group | | ★ "New Chapter"; "New Part" (row 11's answer) | the project's word |
| 59 | Binder: piece | Duplicate; Rename; Delete | | keep | — |
| 60 | Binder: piece | Link Research…; Add Link… | two "link" verbs | keep "Link Research…"; "Add Link…" → "Link to Another Chapter…" | which link |
| 61 | Binder: piece | Tags…; Target…; Publishing…; History | | keep; **slot: read-through's item** if its plan puts one here | — |
| 62 | Binder: Part | Tidy Filenames | | keep | — |
| 63 | Binder: Collection piece | Rename; Promote to Standalone Project…; Delete | | keep (row 14 renames the other Promote) | — |
| 64 | Binder: fold rows (cards, regions, pins, figures, research links) | Open in Centre; Remove Link | the click's twin is missing | add "Pull Up" / "Put Away" first; research links also "Open in Centre" | the menu holds what the click does |
| 65 | Binder: research rows | New Note; New Table; New Group; Add File…; Add Link…; Move to ▸; Duplicate; Rename; Delete | "Add Link…" means a web link here | "Add Web Link…"; add "Pull Up" and "Open in Centre" | two meanings of one title |
| 66 | Binder: palette rows | Duplicate; Delete | | add "Pull Up" | the same |
| 67 | Binder: figure rows | Open in Window; Send to Research ▸; Rename; Move into Figures; Show in Text | | keep | — |
| 68 | Binder: edition rows | Source: Add Language…; a translation: Remove Edition… | | "Remove Spanish Edition…" (row 13) | — |
| 69 | Binder: Inbox, Trash, Removed Elsewhere | Promote…, Send to Canvas, Edit Transcript…, Transcribe, Trash; Restore, Permanently Delete | | keep | — |
| 70 | Status board chips | Run <editor>'s Round; the ladder's verbs | | keep | — |
| 71 | Brief's foot | Details ▸ Tags…, Add Link…, Target…, Publishing… | | "Add Link…" → as row 60 | one name |
| 72 | Editor | AppKit's menu, Convert to Table Figure first in a pipe table | | keep | — |
| 73 | Canvas | none (the details carry the verbs) | | keep | — |
| 74 | Exports list; Welcome recents | Reveal in Finder, Delete…; Open, Remove from Recents | | keep | — |

**Keys freed or taken:** read-through frees ⌘⌥⇧R and ⌘⌥⇧L and takes its own; row 31 takes ⌃⇧⌘L. Known overlaps, kept on purpose and allow-listed in Task 7's census: ⌘R (Check Writing; Fill Right while a table grid has the keys); ⌘↓ (the binder's own, never a menu equivalent).

---

## Hand checks owed to the owner (the whole milestone, in one sitting)

Plans 1–4's lists are consolidated here; nothing is lost. Each line cites its sources (p3 = plan 3's list of 59, p4 = plan 4's list of 21, A37 = ADR 0037's list of 17); where a source has many steps, its full text in that plan is the check. Checks of Lock and Toggle Review Mode are replaced by read-through's own (p3 5, 28's Lock half, 40, 55's Lock half; p4 8's review-mode sentence).

**A. The binder and the centre**
1. Open a novel; click a chapter, the Book (Cards / Outline / Status), a chapter from each view: it opens. The open row is tinted, the last-clicked row selected — say if the fill belongs on the open row. (p3 1, 4; p4 2)
2. The Book's Status: stage, passes, notes, to-dos per chapter; a to-do count opens the chapter on Mine; the Source edition's Status links here. (p4 2, 20)
3. The dots: a check on two chapters and a round on a third, all closed: those rows, their Part and the Book carry the dot; settle the last note: it goes; a screenplay scene with a note carries it; a piece that would not read shows the hollow ring. (p4 1)
4. Drag feedback and the Canvas row drop. (p4 15, 16)
5. Arrow keys, Return/Space and ⌘↓ through a fold; click safety; renaming. (p4 14; A37 16: ⌘⌥E on a chapter in a closed Part opens the Part)

**B. To resolve**
6. ⌘1 on a chapter: one list, "Whole chapter" first, follows the caret; past twelve the filters go single-choice; triage, stet, Reopen; a round arriving causes no stutter; the head's model menu (say if you want a Check Writing button back); a note on another chapter lands on its paragraph; a shared book's verdict lingering (say if it matters). (p3 9–16, 18)
7. The Book's list: a row for another chapter opens it and the list stays; "Open this chapter to answer its notes". (p3 10, 36)
8. Answer a finding: "Filed in Brief", a link, stays until your next act in the list. (p4 19; supersedes p3 21)
9. A figure's changed source in To resolve (Task 3). (P3 below)

**C. Brief**
10. ⌘2 on a chapter: line, Going for, the foot "Details · History"; the line shows on the card, outline and above the prose; the marks after a check, a solid one clicks to its finding, editing clears them. (p3 19, 20; p4 18; supersedes p3 43, 46, 47)
11. Keep a lesson, Add to intent, Make it a rule, Confirm: each says where it filed; "Already in". (p3 22; A37 3)
12. ⌘2 on the Book (filterable decisions; open What I've Learned, First Reader, Visual Language), a Part, an edition. (p3 23, 24)
13. Open the intent in the centre; edit a chapter's intent and line with the canvas in the centre. (p3 25, 26)
14. Undo around Revoke (A37 10, full steps); the narrower permissions and the Core change (A37 11); the line survives ⌘Q (A37 14); Tags… Return, Target Esc (A37 15); the proposal notice (p3 44); Going for grows (p3 45).

**D. The pulled-up thing and the fold**
15. A chapter's fold: research, cards, palette cards, figures, links; groups past six; linked vs owned; a short story's chevron (say). (p3 27; A37 6)
16. Pull up a note (editable), a card (read-only, Open in Centre); it stays across chapters; History of a chapter not open, with "Open this chapter to rewind it". (p3 28 less Lock, 29; A37 13; p4 20)
17. The column at its narrowest; the control's names; the faces' title line; ⌘3's empty state. (p3 30, 35, 37, 38)
18. Regions in the fold and pulled up; a palette card in a region; Claude's cards into a closed canvas. (p3 33, 52; A37 17; p4 13)
19. Thumbnails; figures in a fold (single, double click); double-click scraps; Back ⌘[ (the menu says "Back"); Details of …; Details with the binder out of sight; the left edge lines up; the Palette's open mark; the right-column button; two windows. (p3 34, 41, 42, 48–51, 53, 54, 56–58; p3 55 less Lock)

**E. The canvas**
20. Click a chapter with the canvas open: its region lights, the faces follow; a slugline in Scenes opens the script there; Claude's Show on a region while a note is up. (p3 2, 3, 8)

**F. Editions and translation**
21. An edition's book, the jump to a chapter, a chapter outside the imprint. (p4 3)
22. The edition's Status. (p4 4)
23. A translated edition's To resolve: settle, file, adopt, a question in its language, ⌘⌥A/D/T. (p4 5)
24. The Source edition: the designer's Run, proposals, compile problems. (p4 6)
25. Add Language…, cast, proposed briefs, a failed run, nowhere says "desk". (p4 7, full steps)
26. Reading a chapter in a language: the switch, grey source lines, read-only, undo, copy, ⌃⌘L. (p4 8, full steps, less its review-mode sentence)
27. The running indicator; two windows; Cancel. (p4 9)
28. A chapter in a language: its To resolve, left-overs, Earlier letters, a round report's Open the queue. (p4 10, 11; p3 17)
29. Remove Edition, and Add brings it back. (p4 20)

**G. Collections and promotion**
30. A Collection script's Scenes fold; a peer's edit moves it (Task 4). (p4 12)
31. Promote a piece: success and failure, Story B never stops. (p4 17)

**H. Plan 5**
- P1. View ▸ Margin ▸ My Notes on a chapter with your note, a reviewer's and Claude's: dots and tint on yours and the reviewer's only. Everything Flagged after a check: one grey tick per flagged paragraph, the same whatever it found; set To resolve's filter to Mine: the ticks go. Click a tick: To resolve opens on that paragraph and your caret has not moved. ⌘\: the margin goes. Read the chapter in Serbian: no margin. Quit and reopen: the setting is kept for this book; another book is Off.
- P2. VoiceOver on a dot and a tick reads what it marks and offers the click.
- P3. Change a research table's cells that a figure is pinned to: the chapter placing it lists "Table 2's source data changed" with Compare… and Open; its binder row has the dot; pin again: it goes.
- P4. Drop five photos on a Research group, ⌘Z once: all five go. A palette card pinned to two chapters with both folds open: arrowing selects one row at a time. Type "Ch" then Space in the binder: nothing is pulled up.
- P5. A screenplay read in Serbian: To resolve groups by scene. Narrow the window to its minimum with a round running: nothing in the toolbar overflows. Ask Claude to write into a removed edition: it is told why, and nothing appears.
- P6. A short story, a Collection, a screenplay and a report: To resolve, History, Status's empty state and Statistics each use the project's word. Undo after archiving to-dos says "To-Dos".
- P7. Walk the approved menu table: every menu, every right-click menu; each key does what its item says; with the Welcome window in front, the window items are greyed and Run's four are not.
- P8. Help ▸ Maugham Help: read Getting Started, The Binder, To Resolve, Brief & Pulled Up, and Translating Your Book from a writer's chair; say what is merely adequate. Ask Claude "how do I add a language?" and "what is the margin?".
- P9. Help ▸ Welcome to Maugham: read the tour; open the sample novel and follow its second chapter.

**I. Smoke (last)**
32. Launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence intact.

---

## Calls made in this plan, for Denver to check

1. **An unsealed note is not drawn under My Notes** (the design's "never guessed"); your own new note is known at once because this Mac records whose it is as it writes. Cost if wrong: an old note written before signing shows no dot.
2. **The margin is on the trailing side**, so the screenplay gutter and figure captions keep the leading one. Cost: one constant.
3. **A tick's click reveals a hidden right column** (a click is deliberate); the margin itself stays visible with the column hidden. Cost: one line.
4. **While the review render is on, it takes the dots**; ticks still draw. Cost: one condition.
5. **A figure's changed source is a durable item** at the paragraph that places it (Book-level if unused). Cost: its row's place.
6. **The carries' verdicts** (Tasks 4–5): four tree carries and four reading/toolbar/MCP carries done; six dropped with reasons. Cost: each a small task later if a drop was wrong.
7. **⌘↓ gets a menu item with no key equivalent** (a menu ⌘↓ would take "end of document" from every text view). Cost: the key is learned from the cheat sheet, not the menu.
8. **Two guide slugs renamed and one page deleted** (`right-pane` → `right-column`, `translation-review` → `translation`, `publish-department` merged). Cost: a Claude that cached a slug asks for the list again.
9. **The tour's two rewritten cards and the samples' text are my drafts**, for your read in P9.
10. **The census reads the real menu bar**, not the source, and the cheat sheet must list every key it binds. Cost: a curated cheat sheet becomes a complete one.

## Questions for Denver

1. **What do the translation buttons say?** Recommendation: "Translate This Chapter" and "Translate Whole Book", matching the running indicator's "Translating", with "round" kept as the noun for the record ("Serbian · round 3"); an editor's stays "Run Round". The alternative keeps "Run" and "Run Whole Book". This changes Task 6's vocabulary and table row 7.
2. **Should the review render keep drawing Claude's notes as margin cards?** Today manual review mode (⌘⌥⇧R) draws every open note's text in the editor's margin, Claude's included, which ADR 0027 §1 as written forbids. Recommendation: no — under read-through only a person's notes draw in the editor, and Claude's stay in To resolve, the same line as My Notes. This changes what Task 2's amendment records and what read-through's plan builds.
3. **A short story's piece and a report's: "story" and "section"?** Recommendation: yes; and a novel's groups are "Parts" on every menu (they already are in Status and Brief). This changes Task 6's noun table and rows 11 and 58.
4. **The left column: "the binder" or "the tree"?** Recommendation: "the binder" — the tour, the guide, the samples and most strings already say it, and it is a writer's word; "tree" stays in code. This changes Tasks 6, 8 and 9's prose.
5. **The menu table:** approve, change or strike each ★ row (7, 11, 31, 58) and any other. Task 7 builds only what you approve.
