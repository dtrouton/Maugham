# Typing Loop (plan 1 of 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A manuscript keystroke no longer counts the whole document's words, and autosave's render and file write leave the main actor.

**Architecture:** `DocumentStore` holds the latest text of a typing burst and counts it once, at a trailing edge or when a reader needs the total as final. `Document.performAutosave` snapshots on the main actor, renders and writes off it, and serialises its writes. A standing probe reports the per-stage costs.

**Tech Stack:** Swift, AppKit, Observation; XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-10-typing-loop-and-note-versions-design.md` (Plan 1 and "Calls made after the builder check"). Plan 2 (note versions) is written after this plan is built (CLAUDE.md rule 11).

## Global Constraints

- The editor binding contract is untouched: one `Binding`, `displayText` written once per `setFullText`, no new observable state on `EditorHost`, no `.onChange` that reads back into the binding (tripwires 2, 3, 6, 7). Read `Maugham/Editor/AREA.md` → "The binding contract" first.
- `recordEditorTextWrite(documentId:newText:mode:store:)` keeps its signature and both production callers (`Maugham/Views/EditorHost.swift:259`, `Maugham/MCP/Test/Tools/TestEditTool.swift:49`).
- Per keystroke, still: the session starts, its last-change time moves, the 30-minute idle timer re-arms.
- Perf guards assert counts or ratios, never wall-clock budgets.
- No test types into a mounted view and then waits on a timer for the effect (tripwire 33): drive the settle by calling it, or by awaiting the scheduler's `flush()`.
- No migration, no schema change, nothing in `MaughamPhone/` or `Packages/MaughamCore`.
- Every task ends with `./scripts/test.sh` green, and states the disable experiment it ran: the one line put back or removed that makes its new test fail.
- Docs travel with the task that makes them false: `Maugham/Stores/AREA.md`, `Maugham/Editor/AREA.md`, `Maugham/OpLog/AREA.md`.

## Review Focus

1. **One burst, then ⌘Q inside the settle delay.** The burst's words are in the session event that `flushSessionOnQuit` appends. (Task 1)
2. **Type in piece A, switch to piece B inside the settle delay.** A's count is recorded for A before B's first keystroke is taken, and the session delta is the sum. (Task 1)
3. **Another device's words arrive mid-burst** (`reReadAfterExternalChange`, `register(document:for:)`, `excludeForeignWords`). Typed words stay the writer's; arrived words are excluded; neither is counted twice. (Task 1)
4. **An autosave is in flight when the document closes, or its piece is moved or trashed.** No file appears at the old path afterwards, and the closed document's last text is on disk. (Task 2)
5. **The off-main write fails** (unwritable folder). `performAutosave` throws as it does today, the echo still describes what is really on disk, and the next autosave writes. (Task 2)

---

### Task 1: The word count leaves the keystroke

Model: opus. Dual review (the binding's side effects are regression-scarred).

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift` (`recordEditorTextWrite` at 1294, `recordSessionActivity` at 1315, `excludeForeignWords` ~1345, `reReadAfterExternalChange` ~1378, `flushSessionOnQuit` ~1400, `register(document:for:)` ~1700, the store's close path)
- Modify: `Maugham/Stores/AREA.md`, `Maugham/Editor/AREA.md` (the line "The binding setter's side effects are part of the contract")
- Test: `MaughamTests/Editor/EditorBindingSideEffectsTests.swift` (update), `MaughamTests/Stores/DeferredWordCountTests.swift` (create; run `./gen.sh`)
- Test: `MaughamTests/TripwireGrepTests.swift` (one counted list, `countedLists` at ~12256)

**What is true today (verified 2026-11-10):**
- `recordEditorTextWrite` runs `mode.wordCount(newText)` over the whole document on every keystroke: 10.9 ms of a 38.4 ms keystroke at 250 KB.
- `recordSessionActivity` assigns the observed `lastKnownProjectWordCount` on every keystroke. `ProjectWindow` reads `liveSessionWordsNet` (lines 1643, 2391), so its body is invalidated on every key.
- A session's `startWordCount` is today the total after the first keystroke. `EditorBindingSideEffectsTests.test_typing_updatesLiveSessionWordsNet` pins "0 after the first write".

**Interfaces:**
- Produces: `DocumentStore.settleWordCount()` — synchronous, main actor. If a burst's text is pending: count it, `store.recordWordCount`, move `lastKnownProjectWordCount`; else nothing.
- Produces: `DocumentStore.wordCountRunCount: Int` (`internal private(set)`) — whole-document word counts run by the typing path. Task 3 reads it.
- Produces: `DocumentStore.wordCountSettleDelay: Duration` (default `.milliseconds(350)`, `@ObservationIgnored`).

**Contract:**
- `recordEditorTextWrite` keeps the text, mode, document id and store as the pending burst (holding the `String` is free), calls the session bookkeeping with the project total as cached, and arms the trailing edge. It counts nothing.
- A pending burst for another document is settled before the new one is taken.
- `settleWordCount()` is called before every read of the total as final. Known readers: the trailing edge itself, the idle timer's fire, `flushSessionOnQuit`, `register(document:for:)`, `reReadAfterExternalChange` (before `cachedAtEntry` is read), `excludeForeignWords`, and the store's close. Find the rest: every non-view reader of `ProjectStore.cachedWordCount`, `projectWordCount` or `lastKnownProjectWordCount`.
- `lastKnownProjectWordCount` is assigned only when its value changes.
- A session that starts on this keystroke takes the cached total (before the burst) as `startWordCount`. This changes the pinned "0 after the first write": the first burst's words now count.

- [ ] **Step 1: Write the failing tests** in `DeferredWordCountTests` (use `EditorIntegrationHarness.withRealDocument`, as `EditorBindingSideEffectsTests` does):

| Test | Asserts |
|---|---|
| `test_aBurstCountsNothingUntilItSettles_thenOnce` | 30 `typeCharacter` calls: `wordCountRunCount` delta 0; `settleWordCount()`: delta 1; a second `settleWordCount()`: still 1 |
| `test_theTrailingEdgeSettlesOnItsOwn` | `wordCountSettleDelay = .zero`; type; await the scheduler's `flush()`; `projectStore.projectWordCount` > 0 |
| `test_aBurstThenQuit_landsItsWordsInTheSessionEvent` | type "one two three" into an empty piece; `await flushSessionOnQuit()` with no settle call; the appended event's net words == 3 |
| `test_switchingPieceMidBurst_recordsTheFirstPiecesCount` | `recordEditorTextWrite` for doc A ("a b"), then for doc B ("c") with no settle between; after `settleWordCount()`: `cachedWordCount(A) == 2`, `cachedWordCount(B) == 1`, `liveSessionWordsNet == 3` |
| `test_wordsArrivingMidBurstAreNotTheWriters` | type 2 words (unsettled), then `excludeForeignWords(5)` after moving another piece's cached count by 5; after settle `liveSessionWordsNet == 2` |
| `test_typingInsideOneWordDoesNotInvalidateTheSessionReaders` | `withObservationTracking { _ = store.liveSessionWordsNet }`; 10 keystrokes: `onChange` not called; `settleWordCount()` after typing a new word: called |
| `test_theSessionStillStartsAndRearmsOnEveryKeystroke` | after one `typeCharacter`, before any settle: `currentSessionStart != nil` |

- [ ] **Step 2: Run them; all fail** (`./scripts/test.sh only DeferredWordCountTests`; the first for "delta 30, not 0").
- [ ] **Step 3: Implement the contract above** in `DocumentStore.swift`.
- [ ] **Step 4: Update `EditorBindingSideEffectsTests`:** each test settles before asserting counts; `test_typing_updatesLiveSessionWordsNet` now expects 1 after "One." and 5 after " Two three four five."; `test_typing_startsLiveSession` asserts with no settle.
- [ ] **Step 5: Add the census:** a `countedLists` entry pinning the number of `settleWordCount()` call sites in `DocumentStore.swift`, with a planted-offender note in the test's comment (a reader that skips it).
- [ ] **Step 6: Disable experiment.** Put `mode.wordCount(newText)` back in `recordEditorTextWrite`; `test_aBurstCountsNothingUntilItSettles_thenOnce` fails; revert.
- [ ] **Step 7: Update the two AREA.md lines; `./scripts/test.sh` green; commit.**

---

### Task 2: Autosave off the main actor

Model: opus. Dual review (data safety).

**Files:**
- Modify: `Maugham/OpLog/Document.swift` (`performAutosave` at 849; `close()` ~1645, its `autosaveScheduler.flush()` at 1733)
- Modify: `Maugham/OpLog/Document+ExternalChange.swift:16` (the echo compare), `Maugham/OpLog/EchoState.swift` if the echo gains a case
- Modify: `Maugham/OpLog/AREA.md`
- Test: `MaughamTests/OpLog/AutosaveOffMainTests.swift` (create; run `./gen.sh`)

**What is true today (verified 2026-11-10):**
- `performAutosave` is on the main actor end to end: pending-mirror flush, `materialize()`, `MarkdownDisplayFilter.stripAnchors`, then a coordinated atomic write that sets `lastDiskEcho = .afterWrite(bytes:)` inside the block. 23–50 ms at 250 KB.
- Callers that await it and rely on the write having landed when it returns: the 750 ms `autosaveScheduler` (`Document+Load.swift:680`), `close()`, `ProjectStore+Structure.swift:916`, `ProjectStore+RemovedElsewhere.swift:133` and `:145`, two dev test tools.
- `handleExternalChange` treats disk bytes that differ from `lastDiskEcho.bytes` as an outside change.

**Contract:**
- `performAutosave()` stays `async throws` and returns only when its write has landed or failed.
- On the main actor: the guards it has now (`rejectMutationIfNotWritable`, `mayWriteThePendingFile`, `rendersToDisk`), the pending-mirror flush with its logged failure, and a snapshot of `paragraphs` and `sequence`.
- Off the main actor: materialize, strip, and the coordinated atomic write.
- **Writes are serialised and never go backwards.** Two calls in flight write in snapshot order; a snapshot older than one already written is not written.
- **The echo knows the bytes in flight.** While a write is in flight, disk bytes equal to the last landed bytes or to the in-flight bytes are both our own. (This corrects the spec's call "the echo is recorded before the write": a presenter callback for the previous write can arrive while the next is in flight and must still match.) When the write lands, the in-flight bytes become the landed echo; when it fails, they are dropped and the landed echo is unchanged.
- `close()` awaits the in-flight write before it husks; nothing writes after `isClosed`.
- A document whose `rendersToDisk` turned false while its write was queued does not write.

**Interfaces:**
- Produces: a test seam on `Document`, `autosaveWriteHook: (@Sendable (Data, URL) throws -> Void)?` (`internal`), called in place of the real write when set, off the main actor. Tests gate, fail or observe a write through it.

- [ ] **Step 1: Write the failing tests** in `AutosaveOffMainTests` (load through `Document.load` in a `TestTemp.root` project, as `TypingLatencyProbeTests.makeDoc` does):

| Test | Asserts |
|---|---|
| `test_theRenderAndWriteRunOffTheMainThread` | the hook records `Thread.isMainThread == false` |
| `test_twoAutosavesLandInOrder_andTheOlderNeverReplacesTheNewer` | hook holds the first write on a semaphore; edit; second `performAutosave`; release; both awaited: the file holds the second text |
| `test_aCallbackForThePreviousWriteWhileTheNextIsInFlightIsOurOwn` | with write 2 held in the hook, `handleExternalChange` reading write 1's bytes changes nothing (no conflict backup, `displayText` unchanged) |
| `test_aFailedWriteThrows_leavesTheEchoOnTheLandedBytes_andTheNextOneWrites` | hook throws once: `performAutosave` throws, `lastDiskEcho.bytes` equals the file's bytes; next call writes the new text |
| `test_closeAwaitsTheWriteInFlight_andNothingWritesAfter` | hold a write; start `close()`; release; file holds the last text; hook call count does not move after `close()` returns |
| `test_aPieceThatStoppedRenderingWhileQueuedIsNotWritten` | hold write 1; set `rendersToDisk` false through its production door; queue write 2; release: hook called once |

- [ ] **Step 2: Run them; all fail** (`./scripts/test.sh only AutosaveOffMainTests`).
- [ ] **Step 3: Implement the contract.** The mechanism (a serial chain of tasks, an actor, a queue) is the implementer's; `Materializer.materialize(paragraphs:sequence:)` and `MarkdownDisplayFilter.stripAnchors` are static and pure.
- [ ] **Step 4: Disable experiment.** Remove the never-backwards check; `test_twoAutosavesLandInOrder…` fails; revert.
- [ ] **Step 5: Run the echo and close suites that already exist** (`./scripts/test.sh only EditorIntegrationHarnessTests DocumentDoubleCloseTests` plus whatever `grep -l "lastDiskEcho\|performAutosave" MaughamTests` names); all green.
- [ ] **Step 6: Update `Maugham/OpLog/AREA.md`** (the autosave and echo rules) and the Editor AREA's binding diagram line on `lastDiskEcho`; `./scripts/test.sh` green; commit.

---

### Task 3: The standing probe and the measurements

Model: sonnet. Single review.

**Files:**
- Create: `MaughamTests/Performance/TypingLoopCensusTests.swift` (run `./gen.sh`)
- Modify: `scripts/skip-baseline.txt` (one line, the probe's skip)
- Create: `docs/superpowers/notes/2026-11-10-typing-loop-measurements.md`
- Modify: `docs/INDEX.md` if it lists the performance notes

**Interfaces:**
- Consumes: `DocumentStore.wordCountRunCount`, `DocumentStore.settleWordCount()` (Task 1); `Document.performAutosave()` (Task 2).

**Contract:**
- The probe types 40 mid-document keystrokes through `EditorIntegrationHarness.withRealDocument` (so the production binding setter runs) for five corpora: prose 30 KB, prose 250 KB, report prose 250 KB (`TypingLatencyProbeTests.generateProse(bytes:report:)`), Fountain 60 KB and 250 KB (a generator of sluglines, action, character and dialogue lines). It prints, per corpus: keystroke median and max, `setFullText`, tokenize, string copy, settle, autosave, whole-document paint.
- It is gated as `OpLogGrowthBaselineTests` is (`MAUGHAM_PERF_FIXTURE == "1"`, else `XCTSkip`), and its skip is named in `scripts/skip-baseline.txt`.
- One ungated test in the same file asserts the count, on the 30 KB corpus: 40 keystrokes move `wordCountRunCount` by 0, and one settle by 1.
- The note records the before figures from the spec's table and the after figures from a run of the gated probe (Debug, and an optimised run with `SWIFT_OPTIMIZATION_LEVEL=-O` in its own `-derivedDataPath`), with the command used.

- [ ] **Step 1: Write the ungated count test; run; it passes** (Task 1 made it true) — then prove it can fail by the Task 1 disable experiment, and revert.
- [ ] **Step 2: Write the gated probe; run it** with `TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1` (the command in `OpLogGrowthBaselineTests`' header); capture the printed tables.
- [ ] **Step 3: Write the measurements note; add the skip-baseline line; `./scripts/test.sh full` green; commit.**
