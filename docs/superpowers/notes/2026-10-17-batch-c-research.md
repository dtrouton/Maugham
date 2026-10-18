# Batch C — pre-plan research (main @ eb139f10, read-only)

Verified against current code 2026-10-17. Line numbers are today's.

---

## #79 — suggestion-accept undo/redo is blind to the yield

**Status: STILL PRESENT.**

`Maugham/OpLog/Document+Annotations.swift`:
- `acceptAnnotation` door is the stamp alone — `:513 if rejectMutationIfNotWritable("acceptAnnotation") { return }` / `:515 try requireDispositionPermitted(.claudeAccept)`.
- Suggestion arm registers a hand-rolled undo (`:612-655`): undo → `revertAcceptedAnnotation(id:, undoManager: nil)` (`:649-654`), nested redo → `acceptAnnotation(id:userResponse:undoManager:)` (`:641-647`). Neither asks anything but the stamp on re-entry.
- `revertAcceptedAnnotation` door `:752-753` is the stamp alone; it writes `paragraphs[pid] = restored` (`:815`).
- The pane's direct Revert (`AnnotationsPane.swift:2010`) registers its own undo → re-accept (`:827-837`) — **a third text-writing re-entry the issue did not list.**

`requireDispositionPermitted` (`:1417`) asks only `localWritePermit.allows(.op(...))`; `Posture.allows` (`Packages/MaughamCore/Sources/MaughamCore/Posture.swift:203-207`) is where the yield lives (`case .yes: return verb == .annotate || yieldingTo == nil`). The Document cannot see it.

**Reachability:** real but rare. Book author's Mac, Option-A book: accept a suggestion (or press the pane's Revert); a trust change then makes the piece yield (somebody else's start becomes visible, nobody has claimed it); writer presses ⌘Z or ⇧⌘Z without Edit Anyway → paragraph text rewritten under the author key, which claims the piece and sets the starter's held words aside on every Mac. Needs the yield to begin between the accept and the ⌘Z.

**Every annotation disposition undo/redo that writes manuscript TEXT** (complete list from `Document+Annotations.swift`):
1. accept(suggestion) → **undo** = `revertAcceptedAnnotation` (`:649-654`)
2. accept(suggestion) → **redo** = re-`acceptAnnotation` (`:641-647`)
3. pane Revert (`revertAcceptedAnnotation` with a manager) → **undo** = re-`acceptAnnotation` (`:827-837`)
That's all of them. These do NOT write text and are out of scope per the issue: textless accept undo (`reopenAcceptedTextlessAnnotation`, `:679-704`), reject/archive/stet/withdraw/edit/triage undos, pane Reopen's undo (`:1277-1309`), and stet-undo's prior-`.claudeAccept` re-apply (`:1000`, `appendLifecycleOp` with `changes: []`).
Related, not an undo: `repairRejectedButSplicedAnnotations` (`:1777`) writes text at merge time as an author-signed automation, asking the stamp alone. It's the same yield-blindness, but it's an automation that restores pre-accept text. Flag it; don't fix it in this batch.

**Fix shape:**
- Add `mayWrite: (@MainActor () -> Bool)? = nil` to `acceptAnnotation(id:userResponse:undoManager:)` and `revertAcceptedAnnotation(id:undoManager:)`. In the **suggestion arm only** (after the kind is known, before `opStore.append`), add `if let mayWrite, !mayWrite() { throw PostureRefusal(kind: .claudeAccept / .claudeAcceptRevert) }`. The existing `refusingLoudly` wrappers then turn that into `declineUndo(.notPermitted)` with no new plumbing. Thread `mayWrite` into all three nested re-entries above, so the redo is asked again (`InlineToggleUndo.perform`'s shape, `OpUndoRegistrar.swift:100-166`).
- Keep the check off the textless arm: a comment or query accept's redo shouldn't be refused for `.writeText`.
- Hosts that pass a live undo manager and can accept a suggestion should supply `{ [weak store] in store?.posture(forDocId: docId).allows(.writeText) ?? false }`, as at `EditorHost.swift:779`: EditorHost margin card `:840` (+ reply `:873`), `AnnotationsPane.swift:1772` (`performAccept`), `:1786`, `:2010` (`performRevert`), `AnnotationBulkActions.perform` `:279` (bulk accept includes suggestions; the pane would pass it in). Windowless or `undoManager: nil` callers (TranslationRoundActions, QueryRuling, FirstReaderRuling, TranslationReviewPane, DiagnosticsPane `gotIt` — compiler never mints suggestions) can keep the default `nil`.
- Decision for the plan: the sentence. `.notPermitted` says "this Mac can no longer answer notes in this piece", and #74 reused `.taskNotPermitted`. Neither fits a yield ("isn't settled whose it is yet"). Either accept the existing wording or add an `UndoDecline` case like `.yielding` / `.suggestionNotPermitted`; `.restoreNotPermitted` ("…can no longer change this piece's text") is the closest existing fit.
- **Tests:** model on `MaughamTests/Views/PostureSurfaceTests.swift:test_aSuggestionAcceptUndoneAfterADemotionLeavesTheWords` (`:353`), which has a suggestion, accept, undo, the notice, and the words staying, combined with the `mayWrite: { allowed }` toggle from `MaughamTests/Stores/ManuscriptWriterPostureTests.swift:test_anUndoOfAToggleAfterTheYieldBeginsIsRefusedAndSaid` (`:297`). Cover undo, redo, pane-revert undo, and an Edit Anyway counterpart (`test_editAnywayLetsTheToggleWriteAgain`).

**Gotchas / tripwires:**
- **Tripwire 51:** the Document may not ask the posture. The closure comes from the view host, which already uses `documentStore.posture(forDocId:)`, and that's allowed. Don't make `Document+Annotations.swift` name `Posture`/`LocalWritePermit`.
- **Tripwire 52:** `TripwireGrepTests.swift:10017-10018` classify `acceptAnnotation`/`revertAcceptedAnnotation` as "a disposition — requireDispositionPermitted". Update the reason strings to mention the host's yield-aware `mayWrite`. Don't add them to `manuscriptWriterPatterns`: that would census every accept caller.
- **Tripwire 33:** pin windowlessly with a bare `UndoManager`, as the models do. No mounted press-then-wait.
- **The redo-before-guard edge** (`:623-629`): the nested redo is registered before the async revert's guards run, so a refused undo still leaves a redo on the stack. That's harmless: the redo re-asks `mayWrite`.

---

## #51 — reject/archive undo declines silently on drift

**Status: STILL PRESENT, and the issue's "bulk" framing is OVERSTATED.** The undo closures are bare: `rejectAnnotation` `:867-869` and `archiveAnnotation` `:1041-1043` are `undo: { doc in await doc.refusingLoudly { try await doc.reopenAnnotation(id: id) } }`. `reopenAnnotation`'s drift arms only log (`:1171` "unknown or not withdrawn — ignoring", `:1176` "status drifted … — ignoring"). The stet undo's own comment (`:946-950`) says the same. **But there is no bulk reject or archive:** `AnnotationBulkActions.BulkVerb` is `accept | stet | triage` (`AnnotationBulkActions.swift:93-96`). The orphan sweep only archives `.open` notes (`:1678-1695`), so it can't drift a rejected or archived note either. The silence is per-note.

**Worse than silent (missed by the issue):** `reopenAnnotation` dispatches on whatever the status is now, not on what this undo wrote. So:
- If a rejected note has since been **archived** (say on a peer), "Undo Reject" reopens the archive: wrong verb, and nothing is said.
- If the note has since been **withdrawn**, `undoneKind = .annotationWithdraw` and the reject undo tries to **restore a deleted note** (`:1160-1167` → `restoreOp` → `requireRestoreHonoured`). It either un-deletes the note under "Undo Reject Annotation", or is refused and says the wrong sentence ("this Mac can no longer answer notes…").
- Same pattern for archive → rejected/stetted/withdrawn.

**Reachability:** low. A peer device acts on the same note (syncs a reopen, accept, stet, archive or withdraw) between the reject/archive and the ⌘Z. A second window over the same Document is another possible route. Nothing local and single-window drifts it.

**Fix shape:** the reject/archive undo closures do the stet/accept-note re-check (`:953-963`). Unfiltered query: `guard live?.status == .rejected` (or `.archived`), `else { documentLog.error(…); doc.declineUndo(.reject / .archive); return }`, then `refusingLoudly { reopenAnnotation }`. Add `case reject, archive` to `Document.UndoDecline` (`Maugham/OpLog/Document.swift:480-534`), with singular and plural lines next to each other (`CaseIterable`, so exhaustive switches will flag them). Suggested copy: "Couldn't undo rejecting the note — it changed on another device." and "Couldn't undo archiving the note — …".
- **Tests:** model on `MaughamTests/AnnotationStetTests.swift:test_aDriftedStetUndoDeclinesToTheWriter` (`:484`) and `MaughamTests/AnnotationAcceptNoteUndoTests.swift:test_aDriftedAcceptUndoDeclinesToTheWriter` (`:154`), because these are single-note. Add a withdrawn-since case so the no-resurrection behaviour is pinned. Leave `AnnotationLifecycleUndoTests.test_reopen_onDriftedStatus_isLoudNoOp` (`:325`) alone; it tests `reopenAnnotation` directly, which stays as it is.
- **Gotchas:** don't change `reopenAnnotation` itself. It's also the pane's Reopen and the withdrawal restore, and M5-AN-034 pins its status set. Sibling with the same shape: the pane Reopen's **undo** (`:1287-1299`) re-applies reject/archive/stet with no check that the note is still `.open`. Same class; it could share the task. Register: claim under RULING-22 (`register/01-claims-ledger.json`). OpLog `AREA.md`'s `notifyWriter`/`declineUndo` paragraph lists "the edit, the textless accept, the stet and the triage mark", so sweep it in the same commit (workflow rule 10).

---

## #63 item 1 — `finish`'s `.failed` arm has no generation guard

**Status: STILL PRESENT, and slightly wider than filed.** `Maugham/Compiler/CompilerOrchestrator.swift:1779-1789`:
```swift
case .failed(let failure):
    discardStreamPreview()
    runState = failure.isTheWritersOwnDoing ? .idle : .failed(docId: docId, failure: failure, at: Date())
    endLiveRun()
```
The `.resultText` arm guards only **after** the mint (`:1862`). Its **unusable-output** early return (`:1811-1819`) is unguarded too. `discardStreamPreview()` (`:1430`) drops `streaming` whatever the generation, so a late failure would also **discard the newer run's live preview**. The issue missed that consequence.

**Reachability:** rare. `shutdown()` (`:1713-1732`) bumps `runGeneration` and kills the runner. The old `send` resolves `.failed(.sessionDied(sessionShutDown))` once the process dies, with a bounded grace (#36's death join), so that can be more than one tick. If the writer toggles Claude back on and presses ⌘R and the new run reaches `runState = .running` (`:1176`) before then, the late failure sets `.idle` and clears the clock. Plausible only for fast toggle-off/on + ⌘R. Cancel of a sent run doesn't bump the generation (`:1696`, `hasUnsentRun`), so its own failure still lands. That's correct.

**Fix shape:** at the top of `finish`'s `.failed` arm, and in the unusable-output `else` (or once at the top of `finish`, for both non-mint paths), add `guard runGeneration == generation else { return }`. The mint arm keeps its post-mint guard.
- **Tests:** `MaughamTests/CompilerRunCommandTests.swift`. Model on `test_lateChunksFromAnAbandonedRunAreIgnored` (`:3178`: hold a send, `shutdown()`, deliver late) and `test_shutdownMidRunClearsTheRunningState` (`:2645`). New test: hold run 1 (`runner.nextEvent = nil`), `shutdown()`, start run 2 and get it to `.running`, then `runner.release(.failed(.sessionDied(...)))` for run 1. Assert `runState` is still `.running`, `runStartedAt` is non-nil, and run 2's preview survives. **Gotcha:** check whether `SpyRunner` can hold two outstanding sends, or whether `makeRunner` hands back the same spy. The test may need a runner factory that returns a fresh spy per session.

## #63 item 2 — pinned-note bodies read on main at every ⌘R

**Status: STILL PRESENT, as designed. The figures are accurate.** `CompilerEnvironment+Project.swift:622-656` `pinnedBody`. It stats before reading (`inlineReadCeilingBytes = 65_536`, `:603`) and `String(contentsOf:)` runs synchronously on the main actor. `pinnedListingLines` (`:689-736`) stops reading once `spent >= inlineBudget` (40,000 chars). The cap is 40 pins (`:741`). Worst case is about 2.6 MB, when many notes under 64 KB are each too long to inline and so spend nothing.

**Reachability:** perf only, no correctness defect. A real shelf is a few KB, so the cost is milliseconds on SSD. The proposed `(path, mtime)` memo still stats every note, so it saves decoding and nothing else.

**Recommendation: DROP** (or leave the issue open as a perf note). If kept: a static `[URL: (Date, String)]` memo in `pinnedBody`, invalidated by mtime, with a test in `CompilerRunCommandTests` near `test_productionPinnedListingIgnoresTheUnrelatedLinksField` (`:1771`).

---

## #77 G1/F6 — round with no editor after the hop

**Status: STILL PRESENT.** The refusal is only before the hops: `CompilerOrchestrator.swift:723 if kind == .round, environment.roundEditor(docId) == nil { …(.noEditor); return }`. The re-checks after `mayRunRound` (`:744-755`) and after `prepareForRun` (`:794-801`) don't ask about the editor. `beginRun` re-resolves with no nil check at `:868 let roundPass: ActivePass? = kind == .round ? environment.roundEditor(docId) : nil`, and then `passId = roundPass?.id` and `editorName = roundPass?.editorName ?? AuthorReader.nobody.editorName` (`~:992-999`), which files a "Claude" round with `passId: nil`.

**Reachability:** very unlikely by hand. The writer would have to clear the piece's stage, or retire the pass, inside the settled-posture hop or the burst-flush hop (milliseconds). A synced manifest change from another device landing in that window could also do it.

**Fix shape:** in `beginRun`, after line 868: `if kind == .round, roundPass == nil { environment.onRunAcknowledged(.noEditor); return }`, placed before `runState`/marker/session work. Note that `.started` has already flashed by then, so the writer sees two acknowledgments. That's acceptable. Place it above the empty-delta guard (`:833`) as well, so an empty-piece round with no editor doesn't set `.nothingNew`. Simplest is to resolve `roundPass` at the top of `beginRun`.
- **Tests:** `CompilerRunCommandTests.swift`. Model on `test_shutdownDuringTheBurstAbandonsTheRun` (`:2060`, `PrepareGate` holds the hop) and `test_aRoundWithNoStageIsRefusedAndStartsNothing` (`:3353`). Clear the stage while the gate holds, release, then assert no send and `runState == .idle`. The harness needs a mutable stage, so check `makeHarness(stage:)`.

## #77 F7 — `RunState` doesn't record which kind of run it is

**Status: STILL PRESENT.** `CompilerOrchestrator.swift:36-41`: `.running(docId:checking:)`, `.nothingNew(docId:at:)`, `.failed(docId:failure:at:)`, with no kind. Matchers: `DiagnosticsPane.swift:533-540` (`headerState`), `Maugham/Views/Review/ReviewRoundCockpit.swift:206-215` (`phase`; the issue's path is stale, the file is under `Views/Review/`), fed from `AnnotationsPane.swift:721`.

**Reachability:** real and easy. Press ⌘R in Author (a check takes 1–2 minutes), switch to Review, and the cockpit shows "running" with the check's counts. A check's `.failed` shows as a round failure in the cockpit, and the reverse happens in Author's Diagnostics header. The Run button is still correctly refused ("Still checking…"), because one session per window is real.

**Fix shape:** add `kind: RunKind` to the three cases. Set sites: `:847`, `:1158`, `:1176`, `:1786`, `:1813` (`finish` already has `kind`). Matchers add `where runKind == .round` / `.check`. **A product decision is needed:** with kind matching, the cockpit would read idle while its Run is refused "Still checking…". Either add a cockpit phase ("Author's check is running") or accept idle plus the refusal. Ask Denver, or pick the third phase. About 20 test sites construct these cases (`CompilerRunCommandTests`, `DiagnosticsPaneTests`, `ReviewRoundCockpitTests`; the Department hits are the translator's own `RunState`).
- **Tests:** pure. Model on `ReviewRoundCockpitTests` around `phase(runState:docId:)`, and on `DiagnosticsPaneTests` for `headerState`.

## #77 G4 — `askKey` joins `docId#kind`

**Status: OVERSTATED.** `DiagnosticsStore.swift:763-765` `"\(docId)#\(kind.rawValue)"`. The key is never split. `kind` is a fixed suffix (`check`/`round`), so two different `(docId, kind)` pairs can't produce the same string even if a docId contains `#`. The only `#`-sensitive code is the legacy migration (`:978`, `key.contains("#")`), which would misread a pre-two-loops bare key whose docId contained `#`. Doc ids are minted `ProjectStore.newId(prefix:)` (`ProjectStore+Structure.swift:65`), so that doesn't happen.
**Reachability:** none. **DROP.**

---

## #77 F8 — cancel inside `mintDeclinedQueries`

**Status: STILL PRESENT, and wider than filed.** `TranslationPipeline.swift:363-376`:
```swift
annotationIds = await env.mintDeclinedQueries(DeclinedMint(...))
guard generation == gen else {
    _ = record(leg, .cancelled)
    break legs
}
...
applyFixOutcomes(outcome, annotationIds: annotationIds, notes: notes, to: &round)
```
The cancel path skips `applyFixOutcomes` (`:438`) entirely, so the round loses the **declined → annotation links**, as filed. It **also** loses every **addressed** outcome (the before/after rewrite record ids) and, on the final fix, the summary and glossary proposals. The fix leg has already written its translation entries and the queries are already in the queue. The round records the leg as `.cancelled`, although the leg ran.

**Reachability:** low. The writer has to press Cancel during the mint await: N `withAnnotationDocument` appends, tens to hundreds of ms after a fix leg that took minutes.

**Fix shape:** after the mint, always `applyFixOutcomes(...)` (and the finalFix summary/proposals), and only then `if generation != gen { _ = record(leg, result); break legs }`. Record the leg's real `.ran` result, since the leg did finish, rather than `.cancelled`; the next leg is what gets cancelled. That needs a small restructure, because `result` is assigned before this block.
- **Tests:** `MaughamTests/TranslationPipelineCancelTests.swift`. Model on `test_cancelInTheGapStopsThePipelineWithoutStartingTheNextLeg` (`:144`), with a `mintDeclinedQueries` stub that calls `pipeline.cancel()` before returning ids. Assert that the saved round's notes carry `.declined(annotationId: <id>)` and that the addressed notes have outcomes. Fixture shapes are in `TranslationPipelineTests.test_declinedNotesAreMintedWithTheTranslatorsReasonAndRecorded` (`:338`).

## #77 F9 — empty-string translation stored as translated

**Status: PARTLY.** The pipeline's own ingest already refuses it: `TranslatorReport.swift:243` reads `text` through `ReportJSON.nonEmptyString` (trimmed; empty means absent), and `:248` rejects the entry. **Only `write_translation` (MCP) can still write it:** `TranslationWritePipeline.swift:100-107` counts `e.text != nil` as a form, and `:150` stores `e.text ?? ""`. `TranslationStore.latestByParagraph` (`Packages/MaughamCore/Sources/MaughamCore/TranslationStore.swift:336-343`) treats any non-nil text as present, so `""` reads as translated for coverage and publishing.

**Reachability:** low to medium. An outside Claude calling `write_translation` with `"text": ""` (or whitespace) for a paragraph it skipped. There's no writer-facing UI path.

**Fix shape:** in `TranslationWritePipeline.perform` step 2, treat a whitespace-only `text` as absent (`e.text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false`), so it falls into the existing "must supply exactly one of" refusal. For a genuinely empty source paragraph, `verbatim: true` is the right form. Optionally add a sentence pointing at `delete: true`/`verbatim`.
- **Tests:** `MaughamTests/MCP/Tools/WriteTranslationToolTests.swift`. Model on `test_writeTranslation_neitherTextNorVerbatim` (`:209`).
- **Gotcha:** the census `test_theTranslationWritePipelineIsTheOnlyPlaceAWriteBatchIsAppended` is unaffected. The MCP tool description text (`TranslationTools.swift` ~:80) may want one clause, and MCP/AREA.md's `write_translation` bullet should get a sweep.

## #77 F10 — `Ruling.directiveText` doesn't validate the paragraph id

**Status: OVERSTATED (defense-in-depth only).** `Packages/MaughamCore/Sources/MaughamCore/RulingShapes.swift:43-45` composes the line unchecked, and the reader regex (`:73-74`) requires the 4-char alphabet. All three callers pass live ids: `TranslatorsNote.swift:123` (the editor's paragraph) and `TranslationRoundActions.swift:265,332` (round note and departure ids). Those come from `ReaderReport.swift:77-78` / `CollatorReport.swift:75-76`, which **reject any id not in the briefed set**, so they're live, mint-valid ids.
**Reachability:** none today. **DROP**, or turn it into a one-line `assert` (Core test `RulingShapesTests`) if it rides along with something else.

## #77 F11 — `TranslationRoundStore` path from an unvalidated tag

**Status: OVERSTATED (defense-in-depth only, as the issue says).** `Maugham/Stores/TranslationRoundStore.swift:37-38` `appendingPathComponent("\(language.lowercased()).json")`. Callers pass pipeline-validated languages, stored role tags, or file-derived tags. If kept, call `TranslationRecord.isValidLanguageTag` (Core) rather than `TranslationWritePipeline.validate`, which throws `MCPError`, the wrong error type for a store.
**Reachability:** none. **DROP.**

---

## Proposed grouping (3 plans, ≤5 tasks each)

**Plan A — Annotation undo honesty** (`Maugham/OpLog/Document+Annotations.swift`, `Document.swift`'s `UndoDecline`)
1. #79: `mayWrite` on `acceptAnnotation`/`revertAcceptedAnnotation` (suggestion arm), threaded through all three nested re-entries. Decide the sentence.
2. #79: host wiring (EditorHost margin card, AnnotationsPane accept/revert, bulk accept), plus tests (undo, redo, pane-revert undo, Edit Anyway) and the tripwire-52 reason strings.
3. #51: reject/archive undo fire-time re-check, plus the two new `UndoDecline` cases and the withdrawn-since no-resurrection test.
4. (Optional sibling) The pane Reopen's undo re-check. Register claim plus OpLog AREA.md sweep.
Opus for 1–2 (Editor/OpLog seam); sonnet or haiku for 3–4.

**Plan B — Compiler run edges** (`CompilerOrchestrator.swift` + two surfaces)
1. #63.1: generation guard on `finish`'s `.failed` and unusable-output arms, plus a two-session test.
2. #77 G1: editor re-check in `beginRun`, plus a gate-held hop test.
3. #77 F7: `RunKind` on `RunState`, the matchers, and the cockpit phase decision (Denver), plus about 20 test-site updates.

**Plan C — Translation pipeline edges**
1. #77 F8: apply fix outcomes before the cancel break, plus a cancel-in-mint test.
2. #77 F9: refuse whitespace-only `text` in `write_translation`, plus a test and a doc clause.
Small enough to fold into Plan B as tasks 4–5 if one plan is preferred.

## Drops
- **#63.2** (pinned-note memo): perf only, a few KB in practice, and the memo still stats every note. Little gain.
- **#77 G4** (askKey `#`): the fixed `#check`/`#round` suffix makes collision impossible, and the key is never split.
- **#77 F10** (directiveText id): every caller passes a live, briefed-set-validated id. No path.
- **#77 F11** (round store tag): every caller passes an already-validated tag. No path.
