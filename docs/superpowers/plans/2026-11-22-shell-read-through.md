# Read-through (shell, replacing Lock and Manual Review Mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A writer puts one piece into **read-through** by intent and takes it out by intent. On this Mac, and across quitting, that piece's typing is off while every deliberate act stays on: comment, query, suggest, answer, accept, reject, resolve. Its research and figures follow the same rule. Starting a read-through saves a named checkpoint of the version under review, which History can compare with or restore from. The state is very obvious: a lock on the tree row, a quiet line over the text, a reading position instead of a typing caret, the toolbar padlock, a menu item and a key. The window-wide **Lock** and the editor's hidden **Manual Review Mode** (⌘⌥⇧R) go.

**Architecture:** One per-device store holds the set of piece ids in read-through. It lives on `ProjectSession`, so every window on the project shares it, and it never syncs. Every non-editor surface asks one value, `ReadThroughGate`, about a target (a piece, a research item or a figure). The editor asks the same predicate about **the document its buffer holds**, never about the window's subject. The editor reuses the read-only membrane built for reading a translation (`isEditable = false`, the refusing `shouldChangeTextIn`, the reading position), but with three differences. The buffer is the source. Changes driven by ops still land through the one `applyExternalText` site. Undo stays reachable for op-level entries, because the typing entries are dropped at entry by their target. Pure functions decide the offers, the gate and the labels; views take values.

**Tech Stack:** Swift, SwiftUI, AppKit. No new dependency. MaughamCore unchanged; no op-log schema change; no phone change.

**Spec:** `docs/superpowers/specs/2026-11-22-read-through-design.md` (binding; agreed with Denver on 2026-11-22). It replaces ADR 0035's "Lock" section and its decision 14, and it is ADR 0038's owed item 15. Every signature below was read at `7b542fee`. A name marked **new** is created by the task that lists it under Produces.

## How this plan is cut

Four tasks on `claude/shell-without-personas`, the size the design gives. The grouping differs from the design's list in one respect, which the code forces. The read-through key (⌘⌥⇧R, proposed below) is Manual Review Mode's today, and the toolbar's `.navigation` slot is Lock's. So the task that installs the key retires Manual Review Mode, and the task that re-points the padlock retires Lock. No task builds a route that a later task replaces.

1. **The state and the checkpoint.** The store, the gate, the offer and the two verbs, plus History's Compare. Tests drive the verbs, and the writer sees no change yet apart from Compare….
2. **The typing guard.** In the editor, decisions pass and typing is refused, every write route is pinned, and project Find & Replace skips a piece in read-through. The window mirrors the store into `EditorControl`.
3. **The way in, the line and the mark; Manual Review Mode goes.** The View menu item and ⌘⌥⇧R, the line over the text, the tree's lock, and Manual Review Mode's removal, with its capability census.
4. **The padlock is the piece's; Lock goes.** The toolbar padlock re-pointed, every Lock site moved to the per-piece gate, Lock's removal with its capability census, the ADR and the docs.

**Order relative to plan 5 (menus, wording, help):** this plan goes **first**. Plan 5's whole-menu review then works on the real menu, and its help describes what ships (workflow rule 7). This plan leaves the following to plan 5:
- the final placement of View ▸ Start Read-through / Resume Writing (it sits where Toggle Review Mode sat; plan 5 reserves or moves the slot and keeps the key);
- the guide pages: `docs/guide/editor-and-focus.md`, `annotations-and-suggestions.md`, `research.md`, `structure-and-binder.md`, `reference.md`, plus `docs/roadmap.md` and `docs/problem-map.md`, every one of which still describes Lock or Review Mode;
- the tour and the cheat sheet's wording;
- the piece noun ("chapter", "piece", "story", by project) in this plan's strings, which say "piece" until plan 5's wording pass.

If plan 5 is built first, it must keep ⌘⌥⇧R and the slot for this item, and its help must not describe Lock or Review Mode.

## Global Constraints

- The hard invariants in `CLAUDE.md` stand. **The op log is the source of truth.** Read-through writes no op of its own, apart from the checkpoint's existing breadcrumb through `CheckpointCapture.run`. **⌘S stays a labelled project-scope checkpoint**, and read-through's checkpoint is the same kind, through the same door.
- **`EditorHost` gains no state** (tripwire 6). The line over the text reads `EditorControl`. **`applyExternalText` keeps exactly one production call site** (tripwire 7), and every op-driven change in read-through arrives through it. The binding setter is untouched (tripwire 3). The new synchronous observer only flips a stored fact on the coordinator, as Bug B's did (tripwire 2: nothing reads back).
- **Read-through only adds refusals.** Every site asks it beside the posture and the share, never in their place. It is offered only where the open piece's drawing posture `allows(.writeText)` (tripwires 47, 51: ask `Posture`, never a rung). It is never a grant, and no permission reads it.
- **The membrane follows what the buffer holds** (Task 8's I1 lesson): the editor asks about its own `documentId`, set for the mount, never about the window's subject or a mirrored window-wide flag.
- Notifications go through `MaughamEvent` with a scope (tripwire 21), and new events get their entries in `MaughamEventLivenessTests`. The per-device file name takes a `DeviceSlug` (tripwire 24), is locally minted with `// local-path:` (tripwire 58), and is one file per device (tripwire 17).
- No test-data migration (tripwire 11): the dead `isReviewModeOn` key in `ui-state.json` is read by nothing.
- Tests are pure functions, censuses, hand-pumped editor tests (as `ReadingTranslationPostureTests` pumps `reconcileTextBuffer`) or mounted measurements read synchronously. **Never press a control and wait for its effect** (tripwire 33). A mounted host is built only through `MaughamTests/TestSupport/ViewHostFixtures.swift` and `TestWindow`.
- `DocBudgetTests` (`Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`): `CLAUDE.md` and every `AREA.md` this plan touches (Editor 6,809, Views 7,979, Stores 7,988) are at their ceilings. Every addition is paid for by a cut, and Lock's and Review Mode's entries are the cuts. Never raise a ceiling.
- Read before editing: the area guide each path's row in `CLAUDE.md` names. Before Tasks 2–4, also read the Annotations filings `M5-AN-066`, `M5-AN-067` and `M5-AN-071` in `register/reconciliation/Annotations.claims.json`, which describe review-mode and Review refusals this plan changes. Update each claim in the task that changes its behaviour.
- **Every implementer, every task:** run `./scripts/test.sh` **in the foreground** with a 600000 ms timeout, never in the background and never raw `xcodebuild test`. Run `./gen.sh` after adding or deleting any file. Run a local Release build (`xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`) whenever `ProjectWindow.body` or the toolbar changes; every task here does. Commit before reporting. One branch. No task merges, pushes or tags.
- Every commit message ends with exactly these two lines:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

## Review Focus

1. **Type a sentence, then press ⌘⌥⇧R and immediately Return.** No newline lands, and the checkpoint holds the sentence (the burst was flushed first). ⌘Z then undoes nothing of the sentence, and the editor does not eat an action silently (Task 2).
2. **In read-through, accept a suggestion, then ⌘Z, then ⇧⌘Z.** The text view shows each state, `applyExternalText` is called once per apply, and typing stays refused throughout (Task 2).
3. **Piece A in read-through, click piece B, type, click back to A, type.** B takes the typing and A refuses it from its first frame. Then quit and relaunch, and A is still in read-through (Tasks 1, 2).
4. **A Collection piece in read-through.** Its folder's note opens read-only, a shared note stays editable, its figure's grid is read-only with Accept still on, the palette wall's card stays editable, and New Table is offered (Task 4).
5. **Two windows on one project.** Starting read-through in one shows the lock, the line and the padlock in the other without a reopen (Tasks 1, 3, 4).

---

### Task 1: The state, the checkpoint and Compare

**Files:**
- Create: `Maugham/Stores/ReadThroughStore.swift`, `Maugham/Views/ReadThrough.swift`, `Maugham/Views/ReadThroughModifier.swift`, `MaughamTests/ReadThroughStoreTests.swift`, `MaughamTests/ReadThroughVerbsTests.swift`.
- Modify: `Maugham/Stores/ProjectSession.swift` (a stored `readThrough`, built in `open(url:)` beside `BibleStore` from `DeviceIdentity.author.slug`), `Maugham/Models/MaughamNotifications.swift` (one event), `Maugham/Views/ProjectWindow.swift` (mount `ReadThroughModifier`), `Maugham/Views/HistoryRow.swift`, `Maugham/Views/HistoryPaneStatics.swift`, `Maugham/Views/RewindModifier.swift`, `Maugham/Views/RewindWindow.swift` (an initial preview mode), `Maugham/Stores/AREA.md` (a `.maugham/` table row, paid for), `MaughamTests/Events/MaughamEventLivenessTests.swift`.

**Consumes:**
- `CheckpointFlashDecision.labelled(_:projectURL:activeDocId:allDocIds:figureIds:device:session:activeDocument:posture:backups:flash:)` (`CheckpointModifier.swift`): capture, then backup, then flash, with a notice on failure.
- `CheckpointCapture.run`, which is project-wide: `docPointers` covers every document and figure, `activeDoc` is the subject, and the breadcrumb lands on the subject.
- `Document.flushBurstNow()`, `DocumentStore.settledPosture(forDocId:)`, `DocumentStore.posture(forDocId:as:)`, `_checkpointDeviceId` / `_checkpointSessionId`, `ProjectWindow.documentIds(in:)`.
- `EditorHost.loadsAsAManuscript(_:)`, `ProjectWindow.selectedManuscriptDocId`.
- `ProjectStore.researchRootPath(ofItemId:in:)`, `ProjectStore.researchScopePieceId(ofPath:structure:)`, `FigureRecord.piece`.
- `HistoryPane.rewindPayload(docId:before:)`, `RewindModifier.rewindTarget(of:isOpen:)`, `RewindWindow.PreviewMode`.
- `Deriver.derive(ops:upTo: .atOp(...))`, which is inclusive of the cursor op.

**Produces:**
- **new** `@MainActor @Observable final class ReadThroughStore`:
  - `init(projectRoot: URL, device: DeviceSlug)` and `static func fileURL(projectRoot: URL, device: DeviceSlug) -> URL`, which is `.maugham/read-through.<slug>.json`. `.raw` is interpolated only here.
  - `private(set) var pieces: [String: Date]` (piece id → started) and `var pieceIds: Set<String>`.
  - `func begin(_ pieceId: String, at: Date)`, `func end(_ pieceId: String)`, `func prune(keeping eligible: Set<String>)`.
  - Every change writes the file at once (atomic, no debounce, so a ⌘Q right after still remembers). A failed write posts one notice through `MaughamEvent.postNotice` ("Couldn't remember the read-through on this Mac — …"). A missing file reads as empty, and an unreadable one reads as empty and is logged (tolerant, tripwire 11).
- **new** `enum ReadThroughTarget: Equatable { case piece(String), research(String), figure(String) }`.
- **new** `enum ReadThrough`:
  - `static func isOn(_ pieceId: String?, in pieces: Set<String>) -> Bool` is **the one predicate**: true only for a non-nil id in the set.
  - `static func eligibleIds(in structure: [StructureItem]) -> Set<String>`: documents that `loadsAsAManuscript`.
  - `static func checkpointLabel(at: Date, title: String) -> String`: "Read-through, 22 Nov — Chapter Three", day and abbreviated month in the user's locale.
  - `static func post(_ request: Request)` and **new** `struct Request: Equatable { let docId: String; let on: Bool }`, the one sender for every route.
- **new** `struct ReadThroughGate: Equatable`:
  - `static let writing` (the empty gate).
  - `init(pieces: Set<String>, structure: [StructureItem], research: [ResearchItem], figures: [FigureRecord])`. It builds owner maps only when `pieces` is non-empty: research → its Collection piece through the two `ProjectStore` statics above, and figure → `FigureRecord.piece`.
  - `func owner(of: ReadThroughTarget) -> String?` and `func refusesEdits(_ target: ReadThroughTarget) -> Bool`, which is `ReadThrough.isOn(owner(of: target), in: pieces)`.
- **new** `struct ReadThroughOffer: Equatable { let docId: String; let isOn: Bool; let isEnabled: Bool; let reason: String? }` and `static func of(docId: String?, item: StructureItem?, posture: Posture?, shareIsReadOnly: Bool, isReadingTranslation: Bool, pieces: Set<String>) -> ReadThroughOffer?`:
  - nil where no manuscript piece is open (`docId` nil, or the item does not `loadsAsAManuscript`);
  - **Resume** is always enabled while the piece is in read-through;
  - **Start** is enabled only where the posture `allows(.writeText)`, the share is writable and no translation is read, each refusal with its one-sentence `reason`.
- **new** event `.maughamSetReadThrough`, scope `.keyWindow`, with payload `{docId, on}`.
- **new** `ReadThroughModifier`, the window's receiver (`.onKeyWindowCommand(.maughamSetReadThrough, window:)`), which calls:
  - **new** `ReadThroughVerbs.start(docId:session:store:documentStore:backups:flash:)`. It runs `store.begin` at once, so the tree, line and padlock show in the same turn. It then, in a Task, flushes the piece's burst, then runs `CheckpointFlashDecision.labelled` with `activeDocId: docId`, the label above, and `posture: settledPosture`. The checkpoint backs up and flashes as ⇧⌘S does (#90). A failed checkpoint leaves read-through on, and its notice says why.
  - **new** `ReadThroughVerbs.resume(docId:store:)`, which runs `store.end`.
  - On `store.manifest.structure`'s change it calls `prune(keeping: ReadThrough.eligibleIds(in:))`. That one rule drops a deleted, trashed or promoted piece (all three leave the structure) and keeps a renamed or moved one (the id is stable). It never prunes before the manifest has loaded.
- **new** `HistoryPane.comparePayload(docId: String, checkpoint: Checkpoint) -> [String: Any]?`: `rewindPayload`'s keys with `scrub_op_id = checkpoint.docPointers[docId]`, `scrub_op_at = checkpoint.at`, and **new** `RewindWindow.initialPreviewKey: "diff"`. It is nil where the checkpoint has no pointer for the piece. **new** `HistoryRow` input `offersCompare: Bool` draws a "Compare…" button on a checkpoint row whose `activeDoc` is the History's piece, only while that piece is open (Rewind is the open piece's, owner ruling 13 of 2026-11-22). `RewindModifier` passes the initial mode to `RewindWindow`.

**Why a project-scope checkpoint is right here:** no piece-scoped kind exists (`Checkpoint` is always project-wide, and `activeDoc` names the subject). With the piece as subject:
- the breadcrumb lands on the piece's own log;
- "Revert here…" seeds `PartialRestorePicker`'s scope to the piece, so restoring only this chapter is the picker's first choice;
- Compare reads `docPointers[piece]`, the last content op before the breadcrumb, which `.atOp` derives inclusively, so the diff is exactly "since the read-through began";
- the other documents' and figures' pointers cost nothing, and they protect the piece's figures too.

A new kind would be a MaughamCore schema change for no gain.

**Contract (tests):**
- Store: begin, quit and reopen remembers; end forgets; rename and move keep the entry; trash, delete and promotion prune it; restore from Trash comes back writing. The file name is the slug's. Two stores built on two slugs do not see each other (the "does not sync" contract). A corrupt file reads as empty and is not rewritten until a change.
- `ReadThroughGate`:
  - `.writing` refuses nothing;
  - a piece in the set refuses `.piece(id)`, its Collection folder's research (nested items included, through `researchRootPath`) and its figures;
  - a shared research item and an unowned figure are refused by nothing;
  - a novel's research linked to the chapter is shared and refused by nothing.
- `ReadThroughOffer`: each refusal row (no piece, reference piece, posture refusing `.writeText`, view-only share, translation read) for Start; Resume is enabled under every one of them.
- Verbs: the burst is flushed **before** the checkpoint (an injected order recorder). The checkpoint's `activeDoc` is the piece, `labelSource == .user`, and the label is `checkpointLabel`'s. A refused checkpoint leaves the piece in read-through and posts the notice. `start` on a piece already in read-through takes no second checkpoint.
- Compare: the payload's op is `docPointers[docId]`; nil without a pointer; offered only for the open piece's checkpoints. `Deriver.derive(ops:upTo:)` at that op equals the piece's text at the start (a store-level round trip).

- [ ] **Step 1:** Write the tests above; expected red.
- [ ] **Step 2:** Implement. Pay for the Stores `AREA.md` row (`.maugham/read-through.<deviceSlug>.json | ReadThroughStore | per device, never synced: the pieces in read-through on this Mac`) with a cut in the same file.
- [ ] **Step 3: Disable experiment.** Make `ReadThrough.isOn` return false: every gate test goes red, as do the offer's Resume rows. Then move `store.begin` after the checkpoint: the order test goes red. Restore both.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground, 600000 ms); Release build (the `ProjectWindow.body` modifier). Commit `shell read-through task 1: the state, the checkpoint and Compare`.

**Tripwires and censuses tripped:** 11, 17, 21 (`MaughamEventLivenessTests`), 24, 51 (the offer asks the posture the window already draws, `posture(forDocId:)`; the act asks `settledPosture`), 52 (the checkpoint is `CheckpointCapture.run`, already counted), 58.

**Hand checks:** none yet; nothing routes to the verbs until Task 3. Compare… on a ⌘S checkpoint of the open piece opens Rewind in Diff.

---

### Task 2: The typing guard; decisions pass

**Files:**
- Modify: `Maugham/Editor/EditorControl.swift`, `Maugham/Editor/EditorCoordinator.swift`, `Maugham/Editor/EditorCoordinator+ReviewRender.swift`, `Maugham/Editor/EditorCoordinator+FigureGrid.swift`, `Maugham/Editor/EditorSurface.swift`, `Maugham/Editor/EditorEditPolicy.swift`, `Maugham/Editor/FigureGridGate.swift`, `Maugham/Editor/FigureGridStrip.swift`, `Maugham/Views/EditorHost.swift`, `Maugham/Views/EditorControlMirror.swift`, `Maugham/Views/ProjectWindow.swift`, `Maugham/Views/LanguageSwitch.swift` (the pulse), `Maugham/Stores/ProjectStore+Search.swift`, `Maugham/Stores/ProjectSession.swift`, `Maugham/Editor/AREA.md`, `register/reconciliation/Annotations.claims.json` (M5-AN-066).
- Create: `MaughamTests/Editor/ReadThroughWriteRouteTests.swift`, `MaughamTests/Editor/ReadThroughDecisionTests.swift`, `MaughamTests/Stores/ReadThroughReplaceTests.swift`.

**Consumes:** `EditorCoordinator.setBufferHoldsTranslation(_:in:control:)`, `sourceLanded(_:)`, `typingUndoManager`, `undoManager(for:)`, `setReviewMode(_:)`, `applyControl(_:)`, `refreshFigureGridAccess()`, `closeCompletionIfTheMembraneRefuses()`, `updateSelectionToolbar(in:)`, `receiverContext(.keyWindow)`; `EditorSurface.mount(_:on:servesTranslation:control:)`; `MaughamTextView.drawsReadingPosition(isReadingTranslation:isFirstResponder:selectionIsEmpty:)`, `caretColor(isReadingTranslation:editing:)`, `onTypingRefusedWhileReadOnly`, `isTextInsertionEvent`; `EditorEditPolicy.allowsTextMutation(isReviewMode:lockEditing:isReadingTranslation:)`; `FigureGridGate.mode(figureMayEdit:parked:hostClosed:shareIsReadOnly:isReviewMode:isLocked:isReadingTranslation:)`; `FigureGridStrip.Plan.acceptRefusal(for:)`; `ProjectStore.replaceMatch(_:with:)`, `replaceAll(in:with:)`, `ReplaceAllOutcome`; Task 1's store, predicate and event.

**Produces:**
- **new** `EditorControl.readThroughDocIds: Set<String>`. `EditorControlMirrorModifier` gains a `readThroughPieces` input that mirrors it from `session.readThrough.pieceIds`, both on appear and on change. **new** `EditorControl.reviewRenders(docId: String?) -> Bool` is `isReviewMode || ReadThrough.isOn(docId, in: readThroughDocIds)`, the one rule for "draw the review render for this document". `EditorHost`'s three `control.isReviewMode` reads (the open-annotation mirror) ask it with `doc.docId`.
- **new** `EditorCoordinator.isInReadThrough` (`private(set)`) and `func setReadThrough(_ on: Bool, in mountingView: NSTextView? = nil)`, self-guarded. **On** does six things, in this order:
  1. commits an open composition (`unmarkText()`);
  2. `breakUndoCoalescing()`;
  3. drops the **typing** undo by target (`typingUndoManager?.removeAllActions(withTarget: textStorage)`, exactly as `sourceLanded` does), keeping op-level ADR 0023 entries;
  4. closes the completion list;
  5. refreshes editability, the review render (`setReviewMode(control.reviewRenders(docId: documentId))`), the figure grids' access and the selection toolbar;
  6. redraws the caret.

  **Off** refreshes the same. `applyControl` calls `setReadThrough(ReadThrough.isOn(documentId, in: c.readThroughDocIds))`, and `observeControl`'s tracked set gains `control.readThroughDocIds`.
- **new** a synchronous key-window observer on `.maughamSetReadThrough` in the coordinator (`MaughamEvent.observe`, `.keyWindow` context): `if payload.docId == documentId { setReadThrough(payload.on) }`. This is Bug B's reason: a Return pressed right after the key must meet a refusing view, and the control's mirror lands a turn later. The reconciler converges both routes.
- **new** `EditorCoordinator.refreshEditability()`: `textView.isEditable = !readOnlyRecovery && !bufferHoldsTranslation && !isInReadThrough`. It **replaces** `editableBeforeTranslation`'s save and restore in `setBufferHoldsTranslation`, so leaving a translation of a piece in read-through lands non-editable. `readOnlyRecovery` is stored on the coordinator at the mount, from the configuration.
- `EditorSurface.mount(_:on:servesTranslation:control:)` sets read-through **before** `attach`, from `control.readThroughDocIds` and the coordinator's `documentId`. A piece mounted in read-through therefore refuses from its first frame.
- `EditorEditPolicy.allowsTextMutation` gains `isInReadThrough: Bool = false`, a belt beside `isEditable`. `allowsCheckboxToggle` is unchanged, so resolving a to-do is a decision and stays on.
- `MaughamTextView`: `drawsReadingPosition(isReadingTranslation:…)` becomes `drawsReadingPosition(typingIsOff:isFirstResponder:selectionIsEmpty:)`, and `caretColor(isReadingTranslation:editing:)` becomes `caretColor(typingIsOff:editing:)`, where `typingIsOff` is `bufferHoldsTranslation || isInReadThrough`. The result is no typing caret, and a reading position in secondary ink that moves with the arrows.
- **new** `enum TypingRefusal { case recovery, readThrough, none }` and `EditorHost.typingRefusal(isRecovery:isInReadThrough:isReadingTranslation:)`, pure. `EditorHost` passes a non-nil `onTypingRefused` for every manuscript, which answers recovery as today. Elsewhere it posts **new** `.maughamTypingRefused` (`.keyWindow`), and both quiet lines (Task 3's, and `ReadingLanguageLine`) pulse their "typing is off" / "read-only" once. Over a translation, a typed character is now answered by that pulse instead of AppKit's beep.
- `FigureGridGate.mode` gains `isInReadThrough: Bool`, giving **new** `Reason.readThrough` ("In read-through — the table can be read, not typed into."), asked after the share and before `isReviewMode`. `refreshFigureGridAccess` passes the coordinator's `isInReadThrough`. `FigureGridStrip.Plan.acceptRefusal(for: .readThrough)` is nil, and the strip offers **Accept**, Got it and Reject under it. An Accept is a decision and writes the cell; the implementer verifies the controller's accept write passes under `.readThrough` and lets it through if it does not. M5-AN-066 gains that clause.
- `ProjectStore` gains **new** `var readThroughPieceIds: @MainActor () -> Set<String>` (default `{ [] }`), set in `ProjectSession.open` from the session's store (a weak capture). `replaceOneMatch` refuses a manuscript match in such a piece with **new** `ProjectStoreError.inReadThrough(title:)`, writing nothing. `replaceEveryMatch` skips the piece and lists it in **new** `ReplaceAllOutcome.inReadThrough: [String]`. `notice` gains "Left as it was — in read-through: Chapter Three." Research matches are unaffected here (Task 4 decides research).

**How the guard lets decisions through while refusing typing.** `isEditable = false` makes AppKit refuse every *typing* route before the delegate is asked: keys, paste, drop, drag-move, Services, Writing Tools, spelling and autocorrect, text replacement, IME commits, and find-bar Replace or Replace All. `shouldChangeTextIn` refuses again behind it. A deliberate act never types. It writes an op through `Document` (accept, reject, revert, a checkbox flip, Rewind), and its text reaches the view through the binding's get and the one `applyExternalText` site, whose `textView.string =` is programmatic and so is not stopped by `isEditable`. Translation swaps go through the same site today. Undo reaches those acts because the window's undo manager stays the view's: there is no `ReadingUndoGuard` and no throwaway manager. The only entries that could misbehave are typing entries, which AppKit consumes without applying on a non-editable view (Task 8's I5 measurement). They are dropped at entry by their target, and no new ones can register. An Accept clears the stack before registering its own action anyway (ADR 0023 D1).

**Write-route table — every row pinned in `ReadThroughWriteRouteTests` unless named:**

| Route | Answer in read-through | Pinned by |
|---|---|---|
| Keystroke | refused, line pulses | `test_typingIsRefusedAndAnswered` |
| Keystroke in the entry turn (event delivered, control not yet mirrored) | refused | `test_theKeyFlipsTheViewBeforeTheMirrorLands` |
| A mount already in read-through | refused from the first frame | `test_aMountInReadThroughRefusesFromTheFirstFrame` |
| Piece flip to a piece not in read-through | typing lands there | `test_theGuardFollowsTheDocumentTheBufferHolds` |
| Leaving a translation of a piece in read-through | stays refused | `test_leavingATranslationLandsInReadThroughNotEditable` |
| Paste (text, image), figure drop | refused | `test_pasteAndAFigureDropAreRefused` (+ `InsertCommandTests` `commandMayWrite`) |
| Drag-drop, drag-move, Services | refused | `test_aDropADragMoveAndAServiceAreRefused` |
| Cut, Delete, Backspace | refused | `test_typingIsRefusedAndAnswered` |
| Spelling, autocorrect, text replacement | refused | `test_spellingCorrectionAndReplacementAreRefused` |
| IME composition open at entry | committed, then refused | `test_aCompositionOpenAtEntryIsCommittedThenRefused` |
| Writing Tools, find-bar Replace / Replace All | refused | `test_writingToolsAndFindBarReplaceAreRefused` |
| Project Find & Replace: Replace / Replace All | refused, skipped and named | `ReadThroughReplaceTests` |
| Insert menu and commands | disabled and refused | Task 3's `InsertMenuGate` row; `commandMayWrite` here |
| Table tidy | never armed (no typing) and refused | `test_noTableTidyRunsInReadThrough` |
| Typing undo from before entry | dropped; op-level kept | `test_entryDropsTheTypingUndoAndKeepsOpLevelEntries` |
| Figure grid in the text | read-only, Accept on | `FigureGridReadOnlyTests`, `FigureGridStripTests` (new rows) |
| Checkbox flip (resolve a to-do) | allowed | `ReadThroughDecisionTests` |
| Sync merge from another device or the phone | lands (it was not typed here) | `test_aMergeLandsInTheView` |

**Decisions — one test per family in `ReadThroughDecisionTests`, each on a hand-pumped mounted editor in read-through. Each test asserts the op landed, the text view shows the result, `applyExternalTextCallCount` rose by one per apply, the window's undo manager undoes and redoes it with the view following, and typing is still refused afterwards:**
1. Comment, Query, Suggest from the selection toolbar: `SelectionToolbarView.kinds(isReadingTranslation: false)` is offered and the create handler appends; the text is unchanged.
2. Accept a suggestion (the margin card's `reviewAcceptHandler`): the text changes, and undo and redo work.
3. Reject, Stet, Got it, Reply ("answer a note"), Keep as lesson: the op lands and undo is reachable.
4. Resolve a to-do: a checkbox flip through `checkboxToggleHandler`, and a Tasks-pane archive.
5. The round verbs: a bulk accept through `AnnotationBulkActions`, triage.
6. A Translator's note is offered only over a translation, which does not combine with read-through. One assertion: a piece in read-through, read in a language, offers `[.translatorsNote]` and draws Task 8's line, not Task 3's.

- [ ] **Step 1:** Write the route, decision and replace tests; expected red.
- [ ] **Step 2:** Implement. Update `Editor/AREA.md`'s membrane and undo rules (one line each, paid for by Task 3's and Task 4's cuts of the ⌘⌥⇧R and Lock lines; if those come later, cut now from the same section's history sentences).
- [ ] **Step 3: Disable experiments.**
  - Remove `isInReadThrough` from `refreshEditability`: five route rows go red.
  - Make the coordinator ask the window's open piece instead of its own `documentId`: `test_theGuardFollowsTheDocumentTheBufferHolds` goes red.
  - Skip the typing-undo drop: `test_entryDropsTheTypingUndoAndKeepsOpLevelEntries` goes red.
  - Install `ReadingUndoGuard` in read-through: decision tests 2–5 go red on undo.

  Restore each.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground); Release build. Commit `shell read-through task 2: typing is off, decisions are on`.

**Tripwires and censuses tripped:**
- 2, 3, 6, 7 (`EditorIntegrationHarnessTests`, `test_applyExternalTextHasExactlyOneProductionCallSite`, `test_editorHostDeclaresOneBindingAndNoUnlistedObservable`);
- 21 (two new events);
- 33;
- 52 (Replace is a counted writer; its new refusal is classified);
- `EditorWriteCommandCensusTests` (the new observer writes no text: classify it);
- `test_everySelectionAndScrollSetterIsClassified` (no new setter expected; if one is added, classify it).

**Hand checks:** in a dev build with a piece put in read-through through a test-only path, or after Task 3:
- type: nothing lands, there is no caret, and a soft reading position shows;
- accept a margin suggestion, then ⌘Z: the text returns;
- Replace All across the book: the notice names the piece.

---

### Task 3: The way in, the line over the text and the tree's lock; Manual Review Mode goes

**Files:**
- Create: `Maugham/Views/ReadThroughLine.swift`, `MaughamTests/ReadThroughSurfaceTests.swift`.
- Delete: `Maugham/Views/ReviewModeIndicator.swift`.
- Modify:
  - `Maugham/MaughamApp.swift` (the View item);
  - `Maugham/Views/ReadThrough.swift` (the focused value);
  - `Maugham/Views/EditorHost.swift` (mount the line);
  - `Maugham/Views/BinderRow.swift`, `PieceRow.swift`, `SceneNavigatorPane.swift`, `TreeTopRows.swift`, `BinderTreeSections.swift` (the mark);
  - `Maugham/Views/ProjectWindow.swift`, `FocusPostureModifier.swift`, `EditorControlMirror.swift`, `FigureActions.swift`, `FigureSubjectColumns.swift`, `ViewOnlyShareNotice.swift` (a comment);
  - `Maugham/Editor/EditorControl.swift`, `EditorCoordinator.swift`, `EditorCoordinator+FigureGrid.swift`, `FigureGridGate.swift`, `FigureGridStrip.swift`, `FigureCentreGrid.swift`, `FigureWindow.swift`;
  - `Maugham/Stores/UIState.swift`, `Maugham/Models/MaughamNotifications.swift`, `Maugham/Resources/KeyboardShortcuts.swift`;
  - `Maugham/Editor/AREA.md`, `Maugham/Views/AREA.md`, M5-AN-066;
  - the suites that set `isManualReviewMode` or post `.maughamToggleReviewMode`: `EditorControlBridgeTests`, `FigureGridReadOnlyTests`, `FigureGridMenuTests`, `FigureGridOneGridPerHostTests`, `FigureCentreGridTests`, `FigureInspectorTests`, `ReviewModeMembraneTests`, `InsertCommandTests`, `PostureStandingLineTests`, `SharingStatusPillTests`, `CentreItemCoverTests`, `UIStateTests`, `BinderSubjectTests`, `PulledUpTests`, `SubjectRestoreTests`, `EditorWriteCommandCensusTests`, `MaughamEventLivenessTests`, `StatementEditorMountTests`.

**Consumes:** Tasks 1–2; `ResolvePresenceMark`, `TreeRowMarks`, `treeRowStates(state:subject:)`, `BinderTreeSectionsState.presence`; `ReadingLanguageLine` (its shape, `ViewThatFits` and link button); `InsertMenuGate.isEnabled(posture:format:manualReview:shareIsReadOnly:isReadingTranslation:gridHoldsTheKeys:route:)`; `EditorControlMirror.membrane(posture:manualReview:shareIsReadOnly:)`; `FigureWindows.reviewModeChanged(_:from:)`.

**Produces:**
- **new** `FocusedValues.readThroughOffer` (published by `ReadThroughModifier` from `ReadThroughOffer.of(...)` with the window's `selectedManuscriptDocId`, its item, `editorPosture`, the share and `editorControl.translationLanguage != nil`).
- **new** `FocusedReadThroughItem` in View, **where Toggle Review Mode stood**. It is titled "Start Read-through" or "Resume Writing" by the offer, carries `.keyboardShortcut("r", modifiers: [.command, .option, .shift])`, is disabled without an enabled offer, and calls `ReadThrough.post`.
  - **Collision check (done at `7b542fee`):** the other "r" chords are ⌘R, ⇧⌘R, ⌃⌘R, ⌃⇧⌘R and ⌘⌥R (`MaughamApp.swift:208–215`). ⌘⌥⇧R is Toggle Review Mode's alone, which this task deletes. The implementer adds a census that no second ⌘⌥⇧R exists.
- **new** `ReadThroughLine` (in `EditorHost`'s top safe-area inset, beside `ReadingLanguageLine`, drawn when `control.translationLanguage == nil && ReadThrough.isOn(doc.docId, in: control.readThroughDocIds)`):
  - It reads "In read-through · typing is off" in `.callout` secondary ink, with a **Resume writing** link button that posts the one event.
  - `ViewThatFits` drops to "In read-through", and the button always stays.
  - VoiceOver hears one sentence: "In read-through. Typing is off."
  - It pulses on `.maughamTypingRefused`.
  - It is inside `.id(path)`, so a piece flip tears it down. It is not toolbar chrome, so it stays in ⌘\ focus mode, where it is the only thing saying so.
- **new** `ReadThroughMark` (`lock.fill`, 9 pt, `.secondary` ink, `.primary` under increased background prominence as `ResolvePresenceMark` does; VoiceOver "In read-through"):
  - `TreeRowMarks` gains `readThrough: Set<String>`, which `treeRowStates` fills from **new** `BinderTreeSectionsState.readThrough`. The window writes that field from the session store, guarded by `!=`, as presence is.
  - `BinderRow` and `PieceRow` draw it on a document row **after the stage dot and figure count and before `ResolvePresenceMark`**, so no title moves and the presence dot keeps the trailing edge. `SceneNavigatorPane`'s script row does the same.
  - No roll-up onto a Part or the Book.
- Manual Review Mode removed, every capability rehomed (census below):
  - `EditorControl.isManualReviewMode`, `EditorCoordinator.isManualReviewMode` / `setManualReviewMode`, and the `reviewToggleObserver`;
  - `.maughamToggleReviewMode`, the menu item, and `FocusPostureModifier`'s review half (it keeps ⌘\);
  - `ProjectWindow.isReviewModeOn` and its pill;
  - `UIState.isReviewModeOn`, out of `CodingKeys` (an old file decodes and the key is ignored, tripwire 11);
  - `Membrane.manualReview`; `EditorControlMirror.membrane(posture:manualReview:shareIsReadOnly:)` becomes `membrane(posture:shareIsReadOnly:)`, with `isReviewMode = !mayWrite` alone;
  - `InsertMenuGate.isEnabled`'s `manualReview:` becomes `readThrough:` (the open piece's);
  - `FigureActions.windowRefusesWrites`' `isManualReviewMode` term;
  - `FigureGridGate`'s `isReviewMode:` parameter, `Reason.reviewMode` and `FigureGridStrip.Plan.reviewModeAccept`;
  - `FigureWindows.reviewModeChanged(_:from:)` and `Handoff.isReviewMode`: a figure window's frame asks **new** `isInReadThrough` of its figure's piece through the session store, injected at `ProjectSession`'s `figureWindows` construction;
  - `FigureCentreGrid`'s `isReviewMode:`, which becomes `isInReadThrough:` from the gate's `.figure(id)`.
- `KeyboardShortcuts.swift`: the Review Mode entry becomes "Start or resume a read-through" ⌘⌥⇧R (plan 5 rewrites the wording).

**Manual Review Mode's capability census** (`ReadThroughSurfaceTests.test_everyManualReviewCapabilityHasAHome`, in the shape of `test_everyDeskCapabilityHasAHome`, with each home a code token in a production file):

| Capability | Home now |
|---|---|
| Text refuses typing | `EditorCoordinator.refreshEditability` (`isInReadThrough`) and `EditorEditPolicy` |
| Review render: marks, margin rail, selection toolbar | `EditorControl.reviewRenders(docId:)` → `setReviewMode` |
| Focus-dim and typewriter centring off | the same, through `isReviewMode` |
| The open-annotation mirror | `EditorHost` asks `reviewRenders(docId:)` |
| Remembered across quitting | `ReadThroughStore.fileURL` |
| Visible feedback | `ReadThroughLine` |
| The figure grid is read-only, Got it and Reject kept | `FigureGridGate.Reason.readThrough` (Accept now on too) |
| The figure inspector refuses | `FigureActions` (per figure in Task 4) |
| Insert menu off | `InsertMenuGate.isEnabled(…readThrough:…)` |
| A menu item and a key | `FocusedReadThroughItem` |
| The synchronous flip (Bug B) | the coordinator's `.maughamSetReadThrough` observer |
| Completion closes | `setReadThrough` |
| Window-wide over every piece | **gone by design**: per piece |
| "Reviewing · <name>" | **gone**: the line names the state; notes still carry the author's name |

Plus `test_noManualReviewNamesRemain`, which finds no `isManualReviewMode`, `maughamToggleReviewMode`, `isReviewModeOn` or `ReviewModeIndicator` in `Maugham/`.

**Tests:** the offer's title per state, read from the pure offer; the menu item's source (census: `FocusedReadThroughItem()` in View, ⌘⌥⇧R once); the line's three widths through `ViewThatFits` (mounted, read synchronously); its VoiceOver sentence; the mark's presence on a document row in read-through, measured through `TreeHostFixture.binder`, `.collection` and `.scenes`; its trailing x right of the title's frame and left of the presence dot; `TreeTopLevelAlignmentTests` unchanged; **the three delivery routes pinned**: the menu item, the line's button and (Task 4) the padlock each call `ReadThrough.post`, by source census, and `ReadThrough.post` builds the one payload (pure).

- [ ] **Step 1:** Write the tests and both censuses; expected red.
- [ ] **Step 2:** Implement; move each listed suite's assertion onto its new home, and say in the report what moved. Cut Review Mode's lines from `Editor/AREA.md` (§ "The membrane reads the posture", the Bug B line) and `Views/AREA.md` to pay for the new entries. M5-AN-066 loses its review-mode clause.
- [ ] **Step 3: Disable experiment.** Drop `ReadThroughMark` from `PieceRow`: the Collection mark test goes red. Remove the item's shortcut: the census goes red. Restore.
- [ ] **Step 4:** `./gen.sh` (one file added, one deleted); `./scripts/test.sh` (foreground); Release build. Commit `shell read-through task 3: the way in, the line and the mark; Manual Review Mode goes`.

**Tripwires and censuses tripped:**
- 4 (rows look up a set);
- 6 (the line reads the control);
- 9 (no tap gesture: the mark takes no hits);
- 21;
- 33;
- `TreeTopLevelAlignmentTests`;
- `HostBuilderCensusTests`;
- `EditorWriteCommandCensusTests` and `MaughamEventLivenessTests` (the old event is gone).

**Hand checks:**
- ⌘⌥⇧R on a chapter: the History flash, the lock on the row, the line, no caret;
- quit and relaunch: still in read-through;
- ⌘\: the line stays;
- narrow the window: the line shortens and the button stays;
- VoiceOver on the row and the line;
- a screenplay's script row carries the lock.

---

### Task 4: The padlock is the piece's; Lock goes; research and figures follow

**Files:**
- Create: `Maugham/Views/ReadThroughToggle.swift`, `MaughamTests/ReadThroughResearchSurfaceTests.swift`, `docs/adr/0039-read-through.md`.
- Delete: `Maugham/Views/LockToggle.swift`, `MaughamTests/LockTests.swift`, `MaughamTests/LockedResearchSurfaceTests.swift` (their policed behaviour is re-made first; see below).
- Modify:
  - `Maugham/Views/ProjectWindow.swift` (`TopChromeModifier`, the `isLocked` state and its threading);
  - `Maugham/MaughamApp.swift` (`WindowChrome`, `FocusedLockToggle`);
  - `Maugham/Models/MaughamNotifications.swift`, `Maugham/Models/PulledUp.swift`;
  - `Maugham/Views/CentreColumn.swift`, `RightColumn.swift`, `PulledUpView.swift`, `ResearchSubjectColumns.swift`, `InspectorResearchPanel.swift`, `ResearchVersionsSection.swift`, `FigureSection.swift`, `FigureSubjectColumns.swift`, `FigureInspector.swift`, `FigureActions.swift`, `BinderTreeSections.swift`, `Palette/PaletteWallView.swift`, `RightColumnToggle.swift` (a comment);
  - `Maugham/Editor/FigureCentreGrid.swift`, `FigureGridGate.swift`, `FigureGridStrip.swift`, `FigureWindow.swift`;
  - `Maugham/Stores/ProjectStore+Search.swift` (research matches);
  - `Maugham/Resources/KeyboardShortcuts.swift`;
  - `docs/adr/0035-the-subject-not-the-persona.md` (a superseded line at "Lock" and decision 14), `docs/adr/0038-status-editions-and-translation.md` ("Not yet built" and owed item 15), `docs/adr/README.md`;
  - `Maugham/Views/AREA.md`, `Maugham/Editor/AREA.md`;
  - M5-AN-066, M5-AN-067, M5-AN-071;
  - the suites listed by `grep -rln 'WindowLock\|LockToggle\|isLocked'` under `MaughamTests` at HEAD: `PaletteWallDoorTests`, `ResearchSubjectRevealTests`, `ResearchSubjectRoutingTests`, `ProjectAltitudeCentreTests`, `TestSupport/RightColumnFixture.swift`, `TestSupport/ViewHostFixtures.swift`, `PulledUpTests`, `PulledUpViewTests`, `PulledUpFitsTheColumnTests`, `RightColumnAppraisalTests`, `FigureInspectorTests`, `ResearchNewTableTests`, `ResearchTableGridTests`, `ResearchVersionsModelTests`, `FigureCentreGridTests`, `FigureGridGateTests`.

**Consumes:** Tasks 1–3; the Lock sites as `LockTests.lockSites` / `pulledUpLockSites` list them; `PulledUp.refusesEdits(isLocked:)`, `PulledUp.lockApplies`, `PulledUpView.face(of:centre:isLocked:card:)`, `PulledUpView.centreResearchIsReadOnly(_:isLocked:)`, `FigureActions.windowRefusesWrites(control:isLocked:)`, `BinderTreeSectionsState.offersNewTable(shareIsReadOnly:isLocked:)`, `ResearchVersionsModel.restoreRefusal(shareIsReadOnly:isLocked:)`, `FigureGridGate.Reason.locked`, `FigureGridStrip.Plan.lockedAccept`.

**Produces:**
- **new** `ReadThroughToggle`, in `TopChromeModifier`'s **same `.navigation` item** that `LockToggle` holds, so no toolbar position moves:
  - It shows `lock` when the open piece is in read-through and `lock.open` when it is being written. It is **drawn but disabled** where the offer is nil or Start is refused, which keeps the chrome stable on the Book, an edition, research and the canvas.
  - The tooltip says what a press does and gives the key: "Start a read-through: typing is off; comments and decisions stay on. Saves a checkpoint. (⌘⌥⇧R)" or "Resume writing (⌘⌥⇧R)". Disabled, it gives the offer's reason, or "Open a piece to start a read-through."
  - VoiceOver: label "Start read-through" / "Resume writing", value "In read-through" / "Writing". `accessibilityIdentifier("readThrough")`.
  - It calls `ReadThrough.post`, and it is hidden with the toolbar in ⌘\ (`windowToolbarIsVisible`, unchanged).
- `WindowChrome` keeps `rightColumnShown` only. `FocusedLockToggle`, `.maughamToggleLock` and ⌘⌥⇧L are deleted (⌘⌥⇧L is left free).
- The window threads **`readThrough: ReadThroughGate`** wherever it threaded `isLocked: Bool`, built once per change of the store's set and the manifest (`.writing` when the set is empty). Each site asks `refusesEdits(target)` for **its** target:
  - research centre and research details (`ResearchSubjectColumns`, `InspectorResearchPanel`, `PulledUpView.centreResearchIsReadOnly(_:readThrough:)`): `.research(id)`;
  - **new** `PulledUp.refusesEdits(readThrough:)`: `!isEditableBeside || readThrough.refusesEdits(target)`, with `.research(id)` / `.figure(id)` and false for every other case. `lockApplies` is deleted;
  - **new** `FigureActions.refusesWrites(to figureId: String, control: EditorControl, readThrough: ReadThroughGate) -> Bool`: the share or `.figure(id)`. The inspector, `FigureSection` and `PulledUpView` ask it with their figure's id;
  - `FigureCentreGrid`, `FigureGridGate`: `isLocked:` and `Reason.locked` are deleted, and `.readThrough` (Task 2) covers it;
  - `ResearchVersionsModel.restoreRefusal(shareIsReadOnly:inReadThrough:)`, with reason `.readThrough`;
  - project Find & Replace: a research match in a piece-owned folder of a piece in read-through is skipped and named, like its manuscript (`ReplaceAllOutcome.inReadThrough`).
- **Refused by nothing now** (Lock's refusals that go with it):
  - **the palette wall's card**: a palette card belongs to the book, and no piece owns it. `PaletteWallView` loses `isLocked`.
  - **New Table**: `offersNewTable(shareIsReadOnly:)`. Creating a table damages nothing.
  - **shared research and unowned figures.**

**Lock's capability census** (`ReadThroughResearchSurfaceTests.test_everyLockCapabilityHasAHome`, each row a home token or a named reason):

| Lock refused | Now |
|---|---|
| Research in the centre (`CentreColumn` → `ResearchSubjectColumns`) | `.research(id)`, the piece's folder only |
| A pulled-up research item or figure (`PulledUp.refusesEdits`) | `PulledUp.refusesEdits(readThrough:)` |
| The centre's research details | `PulledUpView.centreResearchIsReadOnly(_:readThrough:)` |
| A figure's writes (`FigureActions.windowRefusesWrites`) | `FigureActions.refusesWrites(to:control:readThrough:)` |
| The centre figure grid (`FigureSubjectColumns`, `FigureCentreGrid`) | `FigureGridGate.Reason.readThrough` |
| A figure window | its frame's `isInReadThrough` (Task 3) |
| Research versions' Restore | `restoreRefusal(…inReadThrough:)` |
| A palette card on the wall | nothing: no piece owns a palette card |
| New Table | nothing: creation is not an accidental edit |
| Accept on a figure cell | nothing: a decision (Task 2) |
| The padlock and ⌘⌥⇧L | `ReadThroughToggle`; ⌘⌥⇧L freed |
| Per window, never stored, every window opens unlocked | **gone by design**: per piece, remembered on this Mac |

Plus `test_everyReadThroughSiteAsksTheOneAnswer`, a named dictionary of files that call `ReadThrough.isOn(` or `.refusesEdits(` on a `ReadThroughGate`, with a count per file (tripwire 50's shape). It has a planted offender and a control. Plus `test_noLockNamesRemain`, which finds no `WindowLock`, `LockToggle`, `isLocked`, `lockApplies` or `maughamToggleLock` in `Maugham/`.

**Re-made before the deletions:**
- `LockTests`' behaviour that still ships becomes `ReadThroughResearchSurfaceTests`:
  - a piece in read-through: its folder's note is read-only in the centre and beside, an image paste into it lands no file, and its table and figure refuse;
  - a piece not in read-through, or shared research: editable;
  - posture refusals hold with read-through off, and read-through never permits what posture refuses (the `test_lockNeverPermitsWhatPostureRefuses` matrix over share and posture);
  - tree verbs stay live: a rename lands;
  - the padlock's title per state; the toolbar hidden in ⌘\.
- `LockedResearchSurfaceTests`' mounted rows: the same assertions through `ViewHostFixtures`, keyed on a Collection piece.

**Docs:**
- **new** ADR 0039 "Read-through", which supersedes ADR 0035's "Lock" section and decision 14. It gives the decision, why, the cost (pre-entry typing undo is dropped; read-through does not sync, so the phone and other Macs may type; Lock's palette, New Table and shared-research refusals are gone) and the overrule-if.
- ADR 0035 gets one line at its Lock section, "Superseded by ADR 0039". ADR 0038 has item 15 and its "Not yet built" line marked built. The README gets its index row.
- `Views/AREA.md` and `Editor/AREA.md` lose Lock's lines and gain the gate's one line.
- M5-AN-067 and M5-AN-071 ("in Review" Restore off) now say "in read-through, for the piece's own research".

- [ ] **Step 1:** Write the censuses and the re-made tests; expected red.
- [ ] **Step 2:** Implement; move each listed suite onto the gate; update `RightColumnAppraisalTests.test_theButtonRidesTheWindowToolbarOnItsTrailingEdge`'s flattened toolbar pin to the new shape.
- [ ] **Step 3: Disable experiment.**
  - Make `ReadThroughGate.owner(of: .research)` return nil: the piece-folder note rows go red.
  - Make it return the piece for shared research: the "shared stays editable" rows go red.
  - Delete the padlock's `.disabled`: the no-piece row goes red.

  Restore each.
- [ ] **Step 4:** `./gen.sh` (files added and deleted); `./scripts/test.sh` (foreground); then `./scripts/test.sh full` (the last task of the plan); Release build (toolbar and `ProjectWindow.body`). Commit `shell read-through task 4: the padlock is the piece's; Lock goes`.

**Tripwires and censuses tripped:**
- 9;
- 15 (no new `ContentUnavailableView`);
- 21;
- 33;
- 47 and 51 (the toggle asks the offer, which asked the posture);
- 50's shape for the new counted list;
- 52 (Replace's research arm);
- `HostBuilderCensusTests`;
- `MaughamEventLivenessTests`;
- `RightColumnAppraisalTests`.

**Hand checks:**
- the padlock on a chapter, the Book and an edition (disabled with its reason);
- a press, then the same piece in a second window (lock, line and padlock follow);
- a Collection piece in read-through: its folder note is read-only, a shared note is editable, the palette wall's card is editable, and New Table is offered;
- a figure suggestion in that piece: Accept writes the cell;
- reading a translation of that piece: the translation's line shows, the padlock reads locked, Start is refused elsewhere with its reason, and Resume works;
- the smoke: launch → New project → Novel → "Smoke" → type a sentence → ⌘⌥⇧R → type (nothing lands) → ⌘Q → relaunch → open from Recents → the sentence is intact and the chapter is still in read-through → History shows "Read-through, …" → Compare… shows no difference → Resume writing → type.

---

## Interactions, settled from the code

- **A translation.** These do not combine. Reading a language shows Task 8's line, membrane and Undo bar; the read-through line hides. The tree's lock and the padlock still show the piece's state. Start is refused ("Read Source to start a read-through"), and Resume works. Leaving the translation lands non-editable while the piece is in read-through (`refreshEditability`, Task 2).
- **Open, faced, pulled up.** The state is the piece's. The padlock and menu act on the piece **open in the centre** (`selectedManuscriptDocId`), as the language switch does. A piece faced but not open has no editor, so nothing changes for it. A piece cannot be pulled up (`PulledUp` has no piece case); only its History can, and History is a record.
- **Status, Cards, Outline.** No mark (tree only, call 9). The pieces open as they are.
- **A Collection's pieces.** These work per piece. A reference (promoted-in) piece does not `loadsAsAManuscript`, so it is never offered. A screenplay is one `.fountain`, one piece, and its script row in Scenes carries the lock.
- **Posture.** Read-through only adds refusals. A reviewer's copy, already locked by posture, is never offered Start. A piece whose posture narrows during a read-through keeps its state, and Resume removes only the writer's own refusal; the posture's lock stays.
- **The promotion door.** Read-through loads nothing (tripwire 59 untouched). A promoted piece leaves the Collection's structure and is pruned, so the promoted project opens writing.
- **Two windows.** One store on `ProjectSession`: both windows observe it, each mirrors it into its own `EditorControl`, and only the key window gets the synchronous flip. The other window cannot take a keystroke before its mirror lands.
- **The phone and other Macs.** They are not synced and show nothing. Typing there lands here as a merge (route table). The checkpoint's per-device file syncs, so other Macs' History lists it. The phone reads no checkpoints.
- **MCP.** No tool text changes. Claude's tools never write manuscript text, and `add_note` is exactly what a read-through wants.

## Calls made in this plan, for Denver to check

1. **Stored in a per-device file**, `.maugham/read-through.<device>.json`, not in `ui-state.json`. That file is one per project, sits in the project folder and travels to every Mac with iCloud Drive, so it would sync, which the design rules out.
2. **The checkpoint is the ordinary project-wide one**, with the piece as its subject, labelled "Read-through, 22 Nov — Chapter Three". It backs up and flashes as ⇧⌘S does. If it fails, a notice says so and read-through stays on.
3. **Compare… on every checkpoint of the open piece** (Rewind's diff at that point), not only read-through ones. Restore is Rewind's (the open piece) or Revert here… (the picker).
4. **A soft reading position instead of no caret**, as over a translation. A typed key makes the line pulse instead of beeping, and over a translation too.
5. **Start is off while reading a translation; Resume is always on.**
6. **"The piece's research" is a Collection piece's own folder.** A novel's shared research linked to a chapter is the book's and stays editable. Figures follow their `piece`.
7. **Lock's other refusals go**: the palette wall's cards and New Table refuse nothing.
8. **Accept on a figure cell is on in read-through** (it was off under review mode and Lock).
9. **Tree rows only.** There is no mark on Cards, Outline or Status, no roll-up to a Part or the Book, and no "Start for everything inside" (the design's default).
10. **Deliberate writers stay on**: Rewind and Revert, accepted suggestions, checkbox flips, rename sweeps, and merges from other devices. Project Find & Replace skips the piece and names it.
11. **The padlock is drawn but disabled where no piece is open**, so the toolbar does not shift.
12. **A window that was in Review Mode opens writing**: the old setting is ignored, not migrated.

## Questions for Denver

1. **Undo across the start.** Starting a read-through drops ⌘Z for the typing just before it. The checkpoint holds that version, and AppKit would otherwise use up those undo steps silently. Comments, accepts and resolves stay undoable. *Recommend: accept.*
2. **The key.** ⌘⌥⇧R (Review Mode's old key: "R" for read-through, and the same intent) or ⌘⌥⇧L (the padlock's old key)? *Recommend: ⌘⌥⇧R, leaving ⌘⌥⇧L free.*
3. **The checkpoint's name.** Should it be "Read-through, 22 Nov" as the design says, or "Read-through, 22 Nov — Chapter Three", so the project's History tells two chapters' read-throughs apart? *Recommend: with the chapter's name.*
