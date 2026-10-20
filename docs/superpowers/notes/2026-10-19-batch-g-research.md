# Batch G research — #83 and #84

Worktree `batch-g` at `e6d23ad4` (origin/main). This was read-only: no build and no tests were run. Paths are repo-relative, and `:N` means a line.

## #83: Run looks live while the SAME loop runs on another document

**Status: still present.** The run state is one per window: `RunState.running(docId:kind:checking:)` (`Maugham/Compiler/CompilerOrchestrator.swift:45-50`). The run's document is that `docId`. One session serves both loops. A press while busy is refused by `runRequested`'s `guard !isRunning` and only flashes "Still checking…" (`CompilerOrchestrator.swift:698-715`, `:129`).

**Review cockpit** (`Maugham/Views/Review/ReviewRoundCockpit.swift`):
- `RunPhase` is at `:175`. F7 added `.authorsCheckIsRunning` at `:192`.
- `phase(runState:docId:)` is at `:215-236`. A `.round` run matches only `where runDocId == docId` (`:222`). A check matches on any document (`:227`). A round on ANOTHER document falls to `default: .idle` (`:233`). That `.idle` is the bug.
- Run and Fresh Eyes are disabled via `isRunning = refusesRun(phase:)` (`:526`, `:591-596`, `:842/:847`). Cancel shows when `offersCancel(phase:)` (`:602-607`, `:851-854`), and it calls `orchestrator.cancel()`. The other-loop line is drawn at `:653-659` and is also used as the buttons' tooltip (`runButtonHelp`, `:829-834`). The copy is `authorsCheckIsRunningLine` (`:575-576`).
- The view mounts at `Maugham/Views/AnnotationsPane.swift:711-721`, with `phase:` computed there from `orchestrator.runState` and `document.docId`.

**Author Diagnostics header** (`Maugham/Views/DiagnosticsPane.swift`):
- `headerState` (`:525-554`) matches `.check` `where runDocId == docId`. A check on another document falls through to `.idle` or `.clean`.
- `otherLoopLine(runState:docId:)` (`:571-576`) fires only for `.round`, on any document. That gap is the bug.
- Cancel is controlled by `offersCancel(state:otherLoopLine:)` (`:583-586`, button `:685-686`). Reread is disabled by `isRunningState || otherLoopLine != nil` (`:714-715`). The line is drawn at `:726-730`. The view reads it through the computed property at `:780-782`.
- **Same-class gap F7 also missed:** the cold-start **Read** button (`:1371-1373`) is not gated on `otherLoopLine` at all. It is dead whenever any run is in flight. The fix should disable it too.

**Getting the other document's title, with no new state.** `StructureItem.id == docId` (see `ProjectStore+Annotations.swift:104`). There is a precedent for a pure lookup: `PartialRestorePicker.titles` (`Maugham/Views/PartialRestorePicker.swift:208-212`) uses `TreeWalk.find(id:in: structure)?.title`. Both hosts already hold the manifest:
- `AnnotationsPane.store` (`AnnotationsPane.swift:18`)
- `DiagnosticsPane.store: ProjectStore?` (`DiagnosticsPane.swift:100`, passed at `DetailPaneToggle.swift:604`)

F7 added no observable state: both lines are pure statics computed in `body`. Keep that shape:
- Resolve the title in the host's `body` from `store.manifest.structure`.
- Pass it into a pure function, e.g. `phase(runState:docId:titleOf:)` or `otherLoopLine(…, titleOf: (String) -> String?)`.

The cockpit deliberately stores no `docId` (`ReviewRoundCockpit.swift:35-41`). Carrying the *run's* doc id or its title inside a new phase case is fine, because the cockpit's own subject is still not stored. If the title is unresolved, write a title-less line; never show the raw id. (`PartialRestorePicker` falls back to the id, which is wrong for prose.)

**Proposed copy** (F7's shape and dash):
- Review: **"A round is running on “<title>” — Run waits until it finishes."** Fallback: "…on another piece — …".
- Author: **"A check is running on “<title>” — ⌘R waits until it finishes."** (F7's Author line says ⌘R, `DiagnosticsPane.swift:559`.)

**Shape:**
- Add `RunPhase.roundRunningElsewhere(title:)`, or carry the doc id. The exhaustive switches in `statusLine` (`:568`), `refusesRun` and `offersCancel` force every arm to decide.
- Widen Diagnostics `otherLoopLine` with `.running(runDocId, .check, _) where runDocId != docId`. `headerState` stays as it is: the pane keeps its own last check, as F7 ruled.
- Run is refused and Cancel is offered, the same as F7. **Cancel cancels the other run.** This is right for the same reason as F7 (`DiagnosticsPane.swift:578-582`): one session, one `cancel()`, and the writer is not stranded on the wrong document.

**Tests to copy and to flip** (pure, windowless):
- Models: `ReviewRoundCockpitTests.test_theCockpitSaysAuthorsCheckIsRunning` (`MaughamTests/ReviewRoundCockpitTests.swift:134`), `test_theCockpitNamesAuthorsCheckOnAnyDocument` (`:171`), `DiagnosticsPaneTests.test_theDiagnosticsHeaderSaysReviewsRoundIsRunning` (`MaughamTests/DiagnosticsPaneTests.swift:281`), `test_theHeaderNamesReviewsRoundOnAnyDocument` (`:310`).
- **These must change because they pin today's behaviour:**
  - `test_anotherDocumentsRunLeavesThisCockpitIdle` (`ReviewRoundCockpitTests.swift:102`) asserts `.idle` for a round on ch-2. Keep its true half: the strip's status line is still its own report line, not "Checking…". Flip the Run-refusal half.
  - The control at `:186-189` (round on A → `.idle` on B).
  - `DiagnosticsPaneTests.swift:324`, which asserts `otherLoopLine(checkOnA, "doc-b") == nil`.
- **Keep unchanged:** `test_anotherDocumentsFailureLeavesThisCockpitIdle` (`:300`) and `test_headerState_*AnotherDoc*` (`DiagnosticsPaneTests.swift:267`, `:351`, `:363`). A finished run elsewhere is not busy.

**Docs:**
- The guide never describes F7's line: no hit for "waits until" in `docs/guide/`. Add one sentence each to `docs/guide/right-pane.md:182` (beside "While a check is running you can press Cancel") and `docs/guide/review-passes.md:113-118` (the Cancel paragraph), e.g. "While a check or round is running on another piece, the header names it and offers Cancel; Run waits until it finishes."
- Update `Maugham/Compiler/AREA.md:238`: "names the other loop's run window-wide" becomes "names any run on another piece too".
- The register has no claims file for the compiler or the cockpit.

## #84: merge-time annotation repair ignores the yield

**What it is.** `Document.repairRejectedButSplicedAnnotations()` (`Maugham/OpLog/Document+Annotations.swift:1853-1925`, RULING-33, register claim **M5-AN-057**, `register/reconciliation/Annotations.claims.json:896-905`).
- It handles the race where an accept beats a reject across a merge. The reject wins the status, but the text stays spliced.
- The repair appends one `.claudeReject` that carries the inverse change, with `synthesisSource: .rejectConvergence` (`:1893-1904`). It then sets `paragraphs[pid]` and schedules autosave (`:1913-1923`).
- It declines if the paragraph is gone or has drifted (`:1877-1885`).

**When it runs.** It has one caller: `handleExternalLogChange` (`Maugham/OpLog/Document+ExternalChange.swift:247-249`), gated on `_hasAnyAnnotationOps`. It runs only past the echo guard, i.e. only when a re-read brings new ops or departed lines (`:154-157`). It does **not** run on `Document.load`.

**As whom, and with what guard.** It goes through `appendLifecycleOp(automation: true)`:
- It signs with `authorEmissionDevice` (`:1690-1692`), the author key whoever opened the document.
- It is guarded only by the stamp: `localWritePermit.allows(.op(dispositionProbe))` (`:1698-1700`). A refusal throws `AutomationNotPermitted`, which is logged at debug level and skipped (`:1905-1909`).
- Existing pins: `DocumentWaitingTests.test_theRejectRepairSignsAsTheAuthorAndStopsWhereItMayNotWrite` (`MaughamTests/OpLog/DocumentWaitingTests.swift:740`) and `test_aScopedAuthorOutsideHerPiecesMakesNoRejectRepair` (`:771`).

**Where the yield lives.**
- `LocalWritePermit.unsettledStarter` (`Packages/MaughamCore/Sources/MaughamCore/LocalWritePermit.swift:60-83`). It is set only by the builder (`LocalWritePermitBuilder.swift:121-138`), for a book-author hand in a piece somebody else started and nobody has claimed. It "widens nothing and refuses nothing" (`:80-82`), which is why the stamp says yes.
- The posture yields on it in `DocumentStore+Posture.swift:225-236` (`assemble`), unless the window pressed *Edit Anyway*.
- #74/#79's `mayWrite` closure is the host's posture (`OpUndoRegistrar.swift:105-118`). That closure exists because only the posture knows about Edit Anyway.

**Why the repair matters here:** a book author's text **claims** the piece and sets the starter's held words aside on every Mac (`DocumentStore+Posture.swift:175-178`; builder `:121-128`). A rejectConvergence line carries text, so the automation would do that without the writer seeing anything.

**Can a windowless path ask directly? Yes, at zero census cost.**
- The `Document` already holds the stamp, and `Document.swift:213-214` already reads `localWritePermit.unsettledStarter`.
- Tripwire 51's census `postureAskAllowed` already admits the spelling `localWritePermit` in `Document+Annotations.swift` (`MaughamTests/TripwireGrepTests.swift:10585-10596`, test `test_postureIsAskedOfThePermitInOnePlace` `:10638`). So **no census entry is needed**.
- T46: nothing is built. T47: no rung is compared. T49: this is not an unsigned-door decision.
- T52: `appendLifecycleOp` is not in `manuscriptWriterPatterns`, so `manuscriptWriterCallSites` needs no entry. (This is T52's stated known limit.)
- Do **not** ask `OpLogStore.localWritePermit(…)` afresh. The stamp is the answer, and re-building per merge costs an `unownedPiece` walk.

**Caveats:**
- The stamp's `unsettledStarter` is computed for the *loaded* actor (`claimsAPieceByWritingItsText(actor:)`, builder `:125`). An assistant-loaded document would read nil while the repair still signs as author. Check that MCP opens through the same `DocumentStore` document. Today the existing stamp guard shares this mismatch.
- The repair runs *inside* `handleExternalLogChange`, **before** `restampWhereItsStarterArmMayHaveClosed` (`DocumentStore+Posture.swift:485-499`). On the merge that brings the claiming text, the repair still sees the old, unsettled stamp.

**Options:**

| | (a) skip while unsettled | (b) defer until claimed | (c) accept as-is |
|---|---|---|---|
| Change | One guard in the repair, e.g. `if localWritePermit.unsettledStarter != nil { log; continue }`, placed before the append (repair only, so the sibling sweep, whose archives carry no text, is unaffected). Plus one test copying `:771`'s shape with an unsettled starter, M5-AN-057 updated, and one clause on `Maugham/OpLog/AREA.md:183`. ~10 lines. | (a), plus a re-run hook on claim. **None exists today:** the repair has one caller and does not run on load, *Theirs* or re-stamp. A hook would mean calling the repair after `restampWhereItsStarterArmMayHaveClosed` and after trust/manifest re-stamps when `unsettledStarter` goes non-nil → nil. That touches the posture door (T51 file) and the re-stamp's ordering contract ("no `await`" between re-stamp and bump, `:491-497`), so it needs a separate async call. | Nothing. |
| Writer sees | The rejected suggestion's text stays in the paragraph, with the note reading *rejected* (a visible disagreement, like the drift decline). | The same, until the piece is claimed, then it is repaired. | The text goes back, and the piece silently becomes the book author's. |
| Data-loss risk | None. Nothing is written. | None. | **Real:** the claim sets the starter's held words aside on every Mac, through an act nobody performed. |
| Tripwire cost | None (allow-listed). | Posture-door edit; review against T51 and ruling AG. | — |

**Does (a) get (b) for free?** **Partly.** The trigger condition persists: the latest lifecycle op is still the reject, the latest payload is still the accept, and nothing moves the text (`:1856-1874`). So the repair retries at **the next re-read that applies another device's op to this open document after the stamp has lifted**. It does not retry on reopen, on *Theirs* alone, or on the writer's own typing.

Meanwhile the starter's own Mac, if it merges the race, is not unsettled (`unsettledStarter` is nil for the starter) and repairs it under its own key. That is the W4 rationale ("the author's own Mac makes it anyway", `Document+Annotations.swift:1407-1410`).

The gap: a book where no further peer op ever arrives keeps the splice. It stays visible and is never lost.

**Recommendation (for Denver to rule on):** take (a): while somebody else's unclaimed piece is waiting, Maugham leaves the rejected suggestion's words in place, with a log line, rather than make a repair that would quietly make the piece yours and set the starter's words aside. The repair then happens by itself at the next sync after the piece is claimed. The trade-off is that a rejected suggestion can stay visible in the text until then, where (b) would fix it the moment the piece is claimed but needs posture-door surgery for a case with very low reachability.
