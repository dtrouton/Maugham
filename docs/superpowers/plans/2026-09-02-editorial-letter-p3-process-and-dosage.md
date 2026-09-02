# Editorial letter P3 — process and dosage

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Maugham observes the writer's own process off the op log — where the frontier is, what is being rewritten and how often, how long since the frontier moved, how long they were away — shows it in the Statistics window, briefs a round on it only when a plain threshold says it is worth a sentence, lets the letter say that sentence in the reader's own words with real numbers behind it, and doses the letter by a draft stage the app derives and never asks the writer to set: a short letter while drafting, the full letter while revising, always the full letter on Fresh Eyes.

**Architecture:** `ProcessSignals` is a pure value over `(ops, sequence, now)` — the same reading `DeltaBuilder` already takes — so the compiler computes it at the keystroke from `DocumentReading` with no new `Environment` closure, and the Statistics window computes it per closed document off `OpLogStore.loadSyncMerged`. `DraftStage` is derived at the keystroke from `DeltaCounts` plus the signals, carried on `StreamingRun` like the scene position, stamped onto `Letter.stage` in the one `record` spelling, and its `LetterDosage` is enforced at INGEST (caps) as well as stated in the briefing, so the short letter is short whatever the model did. The briefing gains two per-run frame sections outside the hash — the stage (always) and the process numbers (only when noteworthy). `process` and `stage` are two more optional keys on the letter; the lane line's stage word rides the ONE lane string every reader already calls.

**Tech Stack:** Swift 6, SwiftUI/AppKit (Mac only — nothing here reaches MaughamCore or the phone except one hoisted constant), XCTest via `./scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-08-29-the-editorial-letter-design.md` — §3.1 (`process` key), §3.8 (dosage by draft stage), §4.4 (the brief's process clause), §5 (process signals, two surfaces, thresholds). Read with `docs/superpowers/notes/2026-09-02-editorial-letter-handoff.md` (P1 rulings, P2 addendum, the P3 notes at the end).

## Global Constraints

P1's twelve and P2's seven (13–19) are the milestone's and all still apply — see the two plans. P3 adds:

20. **Every process number is deterministic and off the op log alone.** `ProcessSignals` takes `[Op]`, a `[String]` sequence and a `now: Date`; it reads no store, no `SessionLog`, no clock of its own. Session boundaries are derived (constraint 21). The test fixture is `DeltaBuilderTests`' `makeOp` shape (`MaughamTests/DeltaBuilderTests.swift:12`) with explicit `at`/`session` values.
21. **A session, for a per-document signal, is a run of manuscript ops split where `Op.session` changes OR where consecutive ops are ≥ the idle threshold apart** — the one constant `SessionTracker.idleThreshold`, hoisted from `DocumentStore.sessionIdleThreshold` (`Maugham/Stores/DocumentStore.swift:112`, `private static let sessionIdleThreshold: TimeInterval = 30 * 60`) so the op-derived session and the Statistics window's session agree on the number. `Op.session` alone is process-lifetime (`EditorHost.swift:165`, `private static let sessionId: String = UUID().uuidString`) and would count a week's work as one session. Ruled on Denver's behalf; surfaced in the handoff.
22. **Only ops that apply to the manuscript count, and a bootstrap never moves the frontier.** Filter by `Deriver.appliesToManuscript(_:)` (`Packages/MaughamCore/Sources/MaughamCore/Deriver.swift:191`) — never a local re-switch (`HistoryPane.mutatesManuscript` at `HistoryPane.swift:618` is the pre-existing copy; do not add a third). A `.bootstrap` op mints ids for text that already existed, so it is a session but not a frontier move: importing a finished chapter is not drafting it.
23. **The stage is derived, never set, never stored anywhere but the letter.** `DraftStage.derive(counts:signals:)` is pure; the only persisted trace is `Letter.stage` (a rawValue, a disk format on `ScenePosition`'s rule — explicit snake_case raws, pinned). No manifest field, no UI state, no sidecar field on `CompilerRun`.
24. **Dosage is enforced at ingest and stated in the briefing — both, never one.** `LetterDosage.short` caps questions at 1, drops `exercise` and reads `scenes` as `nil` inside `parseLetter`; `CompilerPrompt.stageSection` tells the model the same thing. Fresh Eyes is always `.full`; the answer to an ask is never dosed (the ask override is the model's, stated in `stageSection`'s drafting arm, and `parseLetter` never touches `answer`).
25. **Nothing per-run folds into the briefing hash** (constraint 5, restated because two new sections land here): `stageSection` and `processSection` sit in the per-run frame between the scene position and the round section, with one hash pin each (a control that the essay still moves the hash already exists: `CompilerPromptTests.test_theBriefingHashStillMovesWhenTheEssayDoes`, `:770`).
26. **The word budget stays 715 and is measured, not assumed.** `CompilerPromptTests.test_theStandingPerRunInstructionAdditionsStayUnderAWordBudget` (`MaughamTests/CompilerPromptTests.swift:1637`) last measured **651**. The `process` sentence joins `letterInstruction`; the dosage doctrine does NOT (it is per-run frame, `stageSection`, unmeasured by that test on purpose). Task 3 tightens `letterInstruction` BEFORE adding the sentence and records both numbers in the test's doc comment; the total after Task 3 must not exceed **671** (651 + 20). Cut doctrine, not the ceiling.
27. **The schema census names every key** (constraint 3). `process` is on the wire: it joins `DiagnosticIngestTests.test_v2FieldNamesComeFromTheSectionSchema`'s array (`:113`) and the letter's schema line after `retired`. `stage` is a STAMP (`scenePosition`/`asked`'s kind), never on the wire: it is not a `SectionField`, and `sectionSchemaDescription` must not name it (a negative assertion with its planted-offender control). `test_theSchemaAsksForExactlySixSections` (`:1579`) stays at six.
28. **The stage word has one source and the lane line's spelling does not multiply.** The word is `DraftStage.laneWord` (the rawValue) and it is appended by exactly the lines that already spell a round: `ReviewRoundCockpit.laneLine(pass:round:stage:)`/`coachLine(coach:round:stage:)` (`Maugham/Views/Review/ReviewRoundCockpit.swift:220`, `:261`) and `LetterSection.signature(voice:round:stage:)` (`LetterSection.swift:305` — the letter's own line, already the deliberate Author-side sibling of the lane; its doc says why it carries no pass name and that reason stands). `LetterKeep.laneLine(passId:round:store:)` (`LetterKeep.swift:75`) becomes `laneLine(passId:round:stage:store:)`; the run overload passes `run.letter?.stage`; the queue's `QueueLedgerVerbs.provenance` passes `nil` (an annotation carries no stage). Consequences, ruled on Denver's behalf: the cockpit's live label shows the LAST run's stage beside its round ("Le Guin · round 3 · drafting" — the number is that run's too); a ledger row filed FROM A LETTER carries the stage in its provenance and a row filed from the queue does not. `TripwireGrepTests` gets a census: `.laneWord` is read in `ReviewRoundCockpit.swift` and `LetterSection.swift` only (planted offender + control).
29. **Nothing about the signals appears in the footer, the tree, the editor or as a badge** (spec §5, constitution must #2). Two surfaces only: the Statistics window's Practice section and the briefing/letter. A negative census over `EditorStatusFooter`/`BinderRow`/`PieceRow` sources for `ProcessSignals` with a planted offender.
30. **The Statistics window reads CLOSED documents.** It runs its own `ProjectStore`/`DocumentStore` (`Maugham/Views/ProjectStatisticsWindow.swift:49-56`), so the Practice section derives every document through `OpLogStore.loadSyncMerged(forDocId:in:)` + `Deriver.deriveWithSequenceFallback(ops:)` — the `ProjectStore+Annotations.swift:184-214` walk — never a live `Document`. A document whose log cannot be read is skipped and NAMED (RULING-54 lenient, reason recorded, the same shape as `unreadableDocIds`).
31. **A jump from the Practice section opens the CHAPTER, and the copy says so.** The stats window is its own scene; `.maughamNavigateToParagraph` is `.keyWindow`-scoped and its receiver ignores `paragraph_id` today (`ProjectWindow.swift:4377-4380`, "anchored scroll-to-paragraph is a follow-up"). The section reuses `onSelectChapter` (a project-scoped `.maughamNavigateToDocument`) and shows the paragraph's excerpt in the row rather than promising a scroll it cannot make.
32. **Rule 10 doc sweep in the task that falsifies a sentence**; Task 9 sweeps the rest. `docs/guide/compiler.md:174-175` ("A lesson already in the ledger, in any state, stops being offered") is already ahead of the code for the queue's door — Task 8 makes it true.

---

## Task 1 — `ProcessSignals`: the pure value, and the one idle threshold

**Files:** Create `Maugham/Compiler/ProcessSignals.swift`; modify `Maugham/Stores/SessionTracker.swift` (gains `public static let idleThreshold: TimeInterval = 30 * 60`) and `Maugham/Stores/DocumentStore.swift:112` + `:464` (the private constant becomes a read of `SessionTracker.idleThreshold`; `DocumentStoreSessionTests`/`SessionTrackerTests` stay green unchanged). Test: create `MaughamTests/ProcessSignalsTests.swift`.

**Contract.**
```swift
// Maugham/Compiler/ProcessSignals.swift — pure, no store, no clock
struct ProcessSignals: Equatable, Sendable {
    struct Session: Equatable, Sendable {
        let index: Int                 // 0-based, file order
        let startedAt: Date            // first manuscript op's `at`
        let endedAt: Date              // last manuscript op's `at`
        let opIds: [String]
    }
    struct Frontier: Equatable, Sendable {
        let paragraphId: String        // the most recently MINTED paragraph still in `sequence`
        let position: Int              // its index in `sequence`
        let sessionIndex: Int          // the session that minted it
        let at: Date
    }
    struct Hotspot: Equatable, Sendable {
        let paragraphId: String
        let position: Int
        let rewrites: Int              // manuscript ops in the churn window with an EDIT (prior != nil, next != "") of this paragraph
    }

    let sessions: [Session]
    let frontier: Frontier?
    /// Sessions AFTER the frontier's session — `nil` with no frontier, 0 when it moved in the latest session.
    let sessionsSinceFrontierMoved: Int?
    /// Top `hotspotCount` live paragraphs by rewrites over the last `churnWindowSessions` sessions, ties by position; excludes paragraphs with 0 rewrites.
    let hotspots: [Hotspot]
    /// Days away BEFORE the latest session when the writer is mid-session now (last op within `SessionTracker.idleThreshold` of `now`), else days since the last op. `nil` with fewer than one session, or mid-session with no earlier session.
    let daysAway: Int?

    static let frontierStallSessions = 3
    static let churnWindowSessions = 5
    static let hotspotRewrites = 5
    static let hotspotCount = 3
    static let coldReadDays = 14

    init(ops: [Op], sequence: [String], now: Date)

    /// The threshold rule of spec §5 — what makes a `processSection` worth writing. Empty is a quiet session.
    var noteworthy: [Signal]
    enum Signal: Equatable, Sendable {
        case frontierUnmoved(sessions: Int)            // sessionsSinceFrontierMoved >= frontierStallSessions
        case hotspot(Hotspot)                          // rewrites >= hotspotRewrites (each such hotspot, up to hotspotCount)
        case coldRead(days: Int)                       // daysAway >= coldReadDays
    }
}
```

**Requirements.** Ops are sorted the way `DeltaBuilder.delta` sorts them (`DeltaBuilder.swift:58-65`: by `opId`, enumeration-offset tiebreak) before anything is read; only `Deriver.appliesToManuscript(op.kind)` ops form sessions (constraint 22). A session boundary is `Op.session` changing OR `at` gaps ≥ `SessionTracker.idleThreshold` (constraint 21). A mint is a `ParagraphChange` with `prior == nil` on a non-`.bootstrap` op; the frontier is the LATEST such change (by op order) whose paragraph is still in `sequence` — a minted-then-deleted paragraph never holds the frontier. An edit is `prior != nil && next != ""` (a delete carries `next == ""`, `Document.swift:976`); a paragraph's rewrites are counted once per op, over the last `churnWindowSessions` sessions, over live paragraphs only. `daysAway` is whole days (`Calendar.current.dateComponents([.day])`, no time zone parameter — days away is the writer's own calendar). No ops ⇒ everything empty/nil and `noteworthy == []`.

**Tests** (each negative with its disable experiment recorded in the doc comment): a change of `Op.session` splits a session at zero gap; a 31-minute gap splits within one `Op.session` (disable: use a 29-minute gap → one session); the frontier is the latest mint and not the highest-positioned one (insert a paragraph mid-document in a later session → it holds the frontier); a bootstrap-only log has no frontier (disable: count bootstrap → frontier appears); a minted-then-deleted paragraph does not hold the frontier; `sessionsSinceFrontierMoved` counts sessions after the frontier's, 0 when it moved in the latest one; hotspots count edits and not mints or deletes, top three by rewrites with ties by position, window of five sessions (a sixth-session-ago rewrite is not counted — disable: widen the window); `daysAway` mid-session reads the gap BEFORE the latest session and idle reads since the last op; `noteworthy` at each threshold and one under (2 stall sessions, 4 rewrites, 13 days ⇒ empty); `SessionTracker.idleThreshold == 30 * 60` and `DocumentStore` no longer declares its own (grep census in the same test file, planted offender by string).

Run `./scripts/test.sh`. Commit: `feat(compiler): ProcessSignals — frontier, churn, forward motion and time away off the op log`.

## Task 2 — the draft stage and its dosage

**Files:** Create `Maugham/Compiler/DraftStage.swift`. Test: create `MaughamTests/DraftStageTests.swift`.

**Contract.**
```swift
enum DraftStage: String, Codable, Equatable, Sendable {
    case drafting = "drafting"
    case revising = "revising"

    /// Drafting iff the delta is mostly new (`counts.new > counts.revised`) AND the frontier moved in the latest session (`signals?.sessionsSinceFrontierMoved == 0`). A `nil` frontier (nothing ever typed new in Maugham) is revising. `signals == nil` (no reading) decides on counts alone.
    static func derive(counts: CompilerOrchestrator.DeltaCounts, signals: ProcessSignals?) -> DraftStage

    /// Fresh Eyes is always full; otherwise drafting is short.
    func dosage(freshEyes: Bool) -> LetterDosage

    /// The word the lane line shows — the rawValue, so "Le Guin · round 3 · drafting".
    var laneWord: String
}

enum LetterDosage: Equatable, Sendable {
    case full, short
    var questionsCap: Int          // full: DiagnosticIngest.letterQuestionsCap; short: 1
    var allowsExercise: Bool       // short: false
    var allowsScenes: Bool         // short: false
}
```

**Requirements.** Raw values are a disk format (`Letter.stage` stores them) and are pinned like `ScenePositionTests.test_theRawValuesAreTheSidecarsOwn` (`MaughamTests/ScenePositionTests.swift:276`). `DeltaCounts` is `CompilerOrchestrator.DeltaCounts` (`CompilerOrchestrator.swift:55-67`, `init(new:revised:)`). `LetterDosage.full.questionsCap` READS `DiagnosticIngest.letterQuestionsCap` (`DiagnosticIngest.swift:762`) rather than restating 3.

**Tests:** the four `(new > revised) × (frontier moved)` cells; the equal-counts case is revising; nil signals decides by counts; nil frontier is revising even with `new > revised` (disable: drop the frontier check → drafting); `dosage(freshEyes: true)` is `.full` for both stages; raw values pinned; `.short.questionsCap == 1`, `.full.questionsCap == DiagnosticIngest.letterQuestionsCap`.

Run `./scripts/test.sh`. Commit: `feat(compiler): DraftStage — drafting or revising, derived from the delta and the frontier`.

## Task 3 — `process` and `stage` on the letter; dosage at ingest; the instruction sentence

**Files:** `Maugham/Compiler/Letter.swift` (`var process: String? = nil` after `retired` at `:145`; `var stage: String? = nil` after `scenePosition`'s pattern — a stamp, `:106`; `isEmpty` at `:166` counts `process` on `answer`'s side and NOT `stage`, on `asked`'s side); `Maugham/Compiler/DiagnosticIngest.swift` (`SectionField.process = "process"` after `retired` `:179`; `parseSection` `:275` and `parseAll` `:304` gain `dosage: LetterDosage = .full` LAST, threaded to `parseLetter` `:578`; in `parseLetter`: `process` joins `recognised` `:581-585`, is read with `nonEmptyString` and id-scrubbed as a FIELD like `answer` (`:731-749` — empties, never drops), never fix-scrubbed; under `.short` the questions loop's guard reads `dosage.questionsCap`, `exercise` is `nil`, and `scenes` is `nil` regardless of the wire); `Maugham/Compiler/CompilerPrompt.swift` (`sectionSchemaDescription` letter line `:59-66` gains `,"process":<string or null>` after `retired`; `letterInstruction` `:170-198` is tightened first, then gains one sentence: *process is one sentence in your own words from the numbers under Process, and null when none were given*). Tests: `MaughamTests/LetterTests.swift`, `MaughamTests/DiagnosticIngestTests.swift`, `MaughamTests/CompilerPromptTests.swift`.

**Requirements.** Constraint 26: measure before, tighten, add, measure after — both numbers in the budget test's doc comment (`:1590-1636`), total ≤ 671. Constraint 27: `process` in the census array (`DiagnosticIngestTests.swift:113`), `stage` NOT in the schema (a negative assertion: `sectionSchemaDescription` does not contain `"stage"` — with its planted-offender control). `test_theLetterInstructionCarriesItsDoctrineClauseByClause` (`CompilerPromptTests.swift:1286`) gains the `process` clause. `parseSection`'s two production callers (`CompilerOrchestrator.swift:933`, `:1295`) are untouched here — Task 4 threads the dosage; the default keeps them compiling.

**Tests:** `Letter` round-trips `process` and `stage`; a letter written before P3 decodes with both nil; `isEmpty` false with only `process`, true with only `stage` (mirror `test_isEmpty_staysTrueWhenOnlyTheAskWasStamped`, `LetterTests.swift:102`); `parseLetter` parses `process`, empties it on a leaked id without dropping the letter, and yields a letter from a `process`-only line (`test_aLetterOfNothingButRetiredIsStillALetter`'s shape, `:1283`); under `.short`: three questions in ⇒ one out and only ONE `.letterQuestion` diagnostic minted (the cap runs before the mint — disable: cap after the loop → three notes), `exercise` dropped, `scenes: [...]` ⇒ `nil`; under `.full` all three survive (control); `answer` survives `.short` untouched.

Run `./scripts/test.sh`. Commit: `feat(letter): the process line and the stage stamp; a short letter is short at ingest`.

## Task 4 — the run: signals at the keystroke, the stage carried and stamped, two briefing sections, the brief's clause

**Files:** `Maugham/Compiler/CompilerOrchestrator.swift` (`beginRun` `:641`: after the delta and before the send, `let signals = ProcessSignals(ops: reading.ops, sequence: reading.sequence, now: Date())`, `let stage = DraftStage.derive(counts: DeltaCounts(of: delta), signals: signals)`, `let dosage = stage.dosage(freshEyes: freshEyes)`; `StreamingRun` `:480` gains `let stage: DraftStage` and `let dosage: LetterDosage` beside `scenePosition`; construction `:880-884`, the `finish(...)` call `:890-897` and `finish`'s signature `:1259` gain `stage:`; both `parseSection` `:933` and `parseAll` `:1295` pass the dosage; `record` `:1012-1016` gains `stage: DraftStage` (undefaulted, on `passId`/`round`/`freshEyes`'s rule) and stamps `letter?.stage = stage.rawValue` after `letter?.asked = ask` `:1036`; `runMessageV2` call `:865-874` passes `stage:` and `signals:`); `Maugham/Compiler/CompilerPrompt.swift` (`runMessageV2` `:255-265` gains `stage: DraftStage? = nil, signals: ProcessSignals? = nil`; new `static func stageSection(_ stage: DraftStage?) -> String?` and `static func processSection(_ signals: ProcessSignals?) -> String?`, appended after `scenePositionSection` and before `roundSection` in that order; a `static let processHeading = "Process"`); `Packages/MaughamCore/Sources/MaughamCore/ReviewPass.swift:218-221` (the workshop brief's clause rewritten from the conditional *Shown that the frontier has not moved, she may say so once…* to the declarative *When the Process numbers say the frontier has not moved, she says so once, in her own words, with the numbers behind her and without scolding.*). Tests: `MaughamTests/CompilerPromptTests.swift`, `MaughamTests/CompilerOrchestratorTests.swift` (or the existing orchestrator suite that pins `scenePosition`'s stamp — find it by `scenePosition` and add beside it), `MaughamTests/CompilerRunCommandTests.swift` if the brief is pinned there.

**Requirements.** `stageSection` always writes when a stage is given: the drafting arm states the stage, WHY (the frontier moved this session and the delta is mostly new), the short dosage (about, working, at most one question, a habit only when it is everywhere in the delta, no exercise, scenes null), that the ask is answered in full whatever the stage, and that the full letter waits for Fresh Eyes; the revising arm states the stage and "write the full letter". `processSection` is `nil` when `signals.noteworthy.isEmpty` (a quiet session produces no line — spec §5) and otherwise writes `Process:` plus one sentence per signal with the numbers in it (sessions since the frontier moved; the paragraph's excerpt is NOT available here, so a hotspot names the paragraph by its position — "the 4th paragraph, rewritten 7 times in the last 5 sessions"; days away). Both are out of the hash (constraint 25). Constraint 26: `stageSection`'s prose is NOT added to the budget test's list — say so in its doc comment and pin it with `test_theCoachsBriefStaysWithinHalfAgainOfAStagesBrief`'s neighbour: a test that the drafting arm stays under 120 words. The brief rewrite stays under the half-again pin (`CompilerPromptTests.swift:1679`).

**Tests:** placement pin for each section (`test_theScenePositionSitsBetweenTheRoleFrameAndTheDelta`'s shape, `:670`); one hash pin each — a run with signals and a run without produce the same hash (`test_theAskNeverFoldsIntoTheBriefingHash`'s shape, `:742`); quiet signals ⇒ no `Process` heading anywhere in the message (disable: return the heading unconditionally); each of the three signals yields a sentence carrying its number; the stamp: a finished run's `letter.stage` equals the derived stage's raw, on a preview too (the `record` census — grep the file for `letter?.asked = ask` and assert `letter?.stage` is on the adjacent line, the one-spelling guard); a Fresh Eyes run over a mostly-new delta stamps `drafting` and ingests under `.full` (three questions survive); a warm mostly-new run over a document whose latest session minted ingests ONE question; the brief's new clause is pinned by substring and the old conditional spelling is gone.

Run `./scripts/test.sh` AND `swift test --parallel --package-path Packages/MaughamCore` (the brief lives in Core). Commit: `feat(compiler): the round is briefed on its draft stage and on noteworthy process numbers; the stage is stamped`.

## Task 5 — the stage on the lane line, the process line on screen and in the kept letter

**Files:** `Maugham/Views/Review/ReviewRoundCockpit.swift` (`laneLine(pass:round:)` `:220`, `coachLine(coach:round:)` `:261` and `laneLabel(pass:round:coach:)` `:244` each gain `stage: String? = nil` LAST; the first two append ` · <stage>` when non-nil, `laneLabel` threads it to whichever arm draws; `setAPassTitle` carries none); `Maugham/Views/AnnotationsPane.swift:701-719` (the cockpit mount passes `stage: diagnostics.lastRun(docId: document.docId)?.letter?.stage`) and `:846-848` (the signature call passes `run?.letter?.stage`); `Maugham/Views/LetterKeep.swift` (`laneLine(passId:round:store:)` `:75` becomes `laneLine(passId:round:stage:store:)`; `laneLine(for:store:)` `:63` passes `run.letter?.stage`); `Maugham/Views/QueueLedgerVerbs.swift:214` (passes `stage: nil`); `Maugham/Views/LetterSection.swift` (`signature(voice:round:)` `:305` gains `stage: String? = nil` and appends the word; a `processPart` between `retiredPart` and `ledgerFailurePart` in `body` `:359-380`, drawn from `letter.process` under a caption constant `processCaption = "From Maugham's numbers"`; a `shortLetterLine` under the title when `letter.stage == DraftStage.drafting.rawValue && !freshEyes`: *A short letter while you draft — Fresh Eyes reads the whole piece.*); `Maugham/Views/DiagnosticsPane.swift:926-931` (the signature call passes `run.letter?.stage`); `Maugham/Compiler/LetterMarkdown.swift` (`render` `:45` writes `## Process` + the line after the not-found block, borrowing `LetterSection.processCaption` on the register rule at `:13-20`). Tests: `MaughamTests/ReviewRoundCockpitTests.swift` (the four literal pins at `:59-99` stay true with `stage: nil`; siblings assert the suffixed forms), `MaughamTests/LetterKeepTests.swift` (`:252-282` — the exact coach-line pin `"Le Guin · round 2"` stays true for a run whose letter has no stage; a sibling over a stamped letter asserts `"Le Guin · round 2 · drafting"`), `MaughamTests/LetterMarkdownTests.swift`, `MaughamTests/LetterSectionTests.swift`, `MaughamTests/AnnotationsPaneChoiceTests.swift:472-475` (unchanged — queue provenance carries no stage; assert it explicitly beside a letter-filed row that does, `LessonLedgerVerbsTests.swift:99`'s fixture), `MaughamTests/TripwireGrepTests.swift` (constraint 28's census over `.laneWord`, planted offender + control).

**Requirements.** The stage word is `DraftStage.laneWord` of the STAMP on the letter, never re-derived live (a run that wrote no letter has no stage and every line is what it was — the pins above are the control). A ledger row filed from a letter carries the stage in its provenance and a row from the queue does not (constraint 28 — pin both). The short-letter line appears only over a warm drafting letter; a Fresh Eyes letter with `stage == drafting` draws no such line (disable: drop the `!freshEyes` → the cold letter claims to be short). The process part draws only when `letter.process` is non-empty (an empty part draws nothing — the guide's own rule).

Run `./scripts/test.sh`. Commit: `feat(letter): the lane line names the stage; the process line draws and keeps`.

## Task 6 — `ProjectPractice`: the Statistics window's value

**Files:** Create `Maugham/Views/statistics/ProjectPractice.swift`. Test: create `MaughamTests/ProjectPracticeTests.swift`.

**Contract.**
```swift
/// The Practice section's whole input, derived off closed documents (constraint 30). No view, no store retained.
struct ProjectPractice: Equatable {
    struct DocumentRow: Equatable, Identifiable {
        let id: String                      // docId == StructureItem.id
        let title: String
        let signals: ProcessSignals
        let excerpts: [String: String]      // paragraphId → first ~80 characters, for the frontier and each hotspot
        let sceneCaptions: [String: String] // screenplay only: paragraphId → nearest preceding slugline's text
    }
    let rows: [DocumentRow]                 // manuscript documents in structure order, documents only
    let unreadableDocIds: [String]
    let isScreenplay: Bool

    /// The project's frontier: the row whose frontier is the most recent, or nil.
    var frontier: (row: DocumentRow, frontier: ProcessSignals.Frontier)?
    /// Top `ProcessSignals.hotspotCount` hotspots across every row, by rewrites, ties by (row order, position).
    var hotspots: [(row: DocumentRow, hotspot: ProcessSignals.Hotspot)]

    @MainActor static func derive(store: ProjectStore, projectURL: URL, now: Date) -> ProjectPractice
}
```

**Requirements.** Walk `store.manifest.structure` the way `ProjectStore+Annotations.swift:184-214` walks it (documents with a `path`, `OpLogStore.loadSyncMerged(forDocId:in:)`, `Deriver.deriveWithSequenceFallback(ops:)`), skip-and-name unreadable logs. `isScreenplay` is `store.manifest.type == .screenplay`. Scene captions use the SAME slugline predicate the Scenes navigator uses (find the public entry `SceneNavigatorPane`/`list_scenes` derive from — never a second regex); prose projects leave the map empty. Excerpts come from the derived paragraphs, trimmed, whitespace-collapsed.

**Tests** over a real on-disk project (the `LetterKeepTests.makeNovel()` fixture shape): two chapters, ops appended through `Document` so the logs are real; the project frontier is the later-minted chapter's; hotspots merge across chapters; an unreadable log (chmod the file, on `DocumentStoreSessionTests`' precedent — restore in teardown) lands in `unreadableDocIds` and the other rows still derive; a screenplay project fills `sceneCaptions` for a paragraph below a slugline and a novel does not (disable: caption everything).

Run `./scripts/test.sh`. Commit: `feat(statistics): ProjectPractice — the writer's process across the book, off closed op logs`.

## Task 7 — the Practice section

**Files:** Create `Maugham/Views/statistics/PracticeSection.swift`; modify `Maugham/Views/statistics/ProjectStatisticsView.swift:9-26` (a fifth section after `RecentSessionsSection`, fed by a `practice: ProjectPractice?` input) and `Maugham/Views/ProjectStatisticsWindow.swift` (derives `ProjectPractice` in `load()` after the store opens, re-derives on `.maughamSessionLogChanged` beside the session-log reload — the same trigger, because a session ending is when a number changed). Tests: create `MaughamTests/PracticeSectionTests.swift` (mounted through `TestWindow.mount`, constraint 9).

**Contract.**
```swift
struct PracticeSection: View {
    let practice: ProjectPractice?          // nil while deriving
    let onSelectChapter: (String) -> Void   // the window's existing closure (constraint 31)
    static let title = "Practice"
    static func frontierLine(_ practice: ProjectPractice) -> String     // "Frontier: Chapter 3 — "The rain had…" · moved 2 sessions ago" / "No new paragraphs typed yet"
    static func forwardMotionLine(_ practice: ProjectPractice) -> String?
    static func hotspotLine(_ row: ProjectPractice.DocumentRow, _ hotspot: ProcessSignals.Hotspot) -> String   // screenplay: "INT. KITCHEN — DAY · …excerpt… · rewritten 7 times"; prose: "Chapter 3 · …excerpt… · rewritten 7 times"
    static let unreadableNotice: (Int) -> String
}
```

**Requirements.** Reuse `sectionHeader(_:)` (`ProjectTotalSection.swift:50`). Empty states through `ContentUnavailableView` with the full frame (tripwire 15). Every hotspot row and the frontier row is a `Button(.plain)` calling `onSelectChapter(row.id)`, with `.help("Opens the chapter")` — never a promise to scroll (constraint 31). Screenplay-shaped copy where `isScreenplay` (the caption is the slugline; the word is "scene", not "chapter"). Constraint 29's negative census lives here: no production file under `Maugham/Views/` other than `statistics/` and the letter's own (`LetterSection.swift`) names `ProcessSignals`/`ProjectPractice` (planted offender + control).

**Tests:** the pure line builders (frontier with and without one, forward-motion line at 0/1/N sessions, hotspot line prose vs screenplay, unreadable notice); a mount over a two-chapter fixture shows three hotspot rows and the frontier, and pressing the frontier row calls `onSelectChapter` with the frontier's docId (a synthetic press on the button's action, not a click — the stats window is not the key window); `nil` practice shows the deriving placeholder; the census with its planted offender.

Run `./scripts/test.sh`. Commit: `feat(statistics): the Practice section — frontier, churn hotspots, forward motion`.

## Task 8 — the queue's two provisional rulings

**Files:** `Maugham/Views/QueueLedgerVerbs.swift` (`offersAKeep(_:)` `:138` becomes `offersAKeep(_:ledgerText:)` — false when `annotation.body` trimmed matches ANY ledger entry's heading through `LessonsLedger.matches` (open, choice or retired — `LessonOffer.keepIsOffered`'s rule, `LessonLedgerVerbs.swift:315`); the `secondStetOffer(for:in:ledgerText:)` overload `:188` is DELETED and its doc moves to the `among:` overload); `Maugham/Views/AnnotationsPane.swift:1593-1596` (`stet` searches `projectSnapshot.annotations.map(\.annotation)` — every document, open or closed, `:425-429` — in BOTH scopes) and `:2229` (passes `ledgerText: LessonLedgerVerbs.ledgerText(store: store)`); `Maugham/Views/LessonLedgerVerbs.swift:92-100` (the doc that says the queue's Keep is a pure annotation predicate is corrected); `docs/guide/compiler.md:174-175` (now true — say the queue's door hides too, in one clause). Tests: `MaughamTests/AnnotationsPaneChoiceTests.swift`, `MaughamTests/AnnotationStetTests.swift`.

**Requirements.** Ruling A (twin search): the ledger is project-scope and a habit is the writer's, not a chapter's, so the stetted twin is looked for across the project in both scopes — the cost is one cached snapshot read at the press (`listAnnotationsAcrossProject`, `ProjectStore+Annotations.swift:95`). Ruling B (Keep as lesson…): hidden only on EXACT identity of the note's whole body with a heading (constraint 15 — no fuzzy match), which is rare by construction because the sheet exists to shorten a paragraph into a sentence; the honest protection against a duplicate stays `keepAsLesson`'s find-or-create.

**Tests:** a stetted twin in chapter two draws the offer on chapter one's note (disable: search the document alone → no offer), in document scope and in project scope; no twin ⇒ plain stet (control); `offersAKeep` false when the body already stands as a lesson, as a choice, as retired; true on a near-miss (a trailing period) — the disable experiment for the exactness; the mounted pane hides the Keep button on a standing body.

Run `./scripts/test.sh`. Commit: `feat(queue): the stetted twin is found across the project; Keep as lesson hides on a sentence that stands`.

## Task 9 — docs, censuses, and the sweep

**Files:** `docs/guide/compiler.md` (in *The letter*: the stage word on the lane line, the short letter while drafting and how to get the full one, the process line; a new *What Maugham counts* paragraph naming the Statistics window's Practice section and the three numbers, with the two thresholds and "a quiet session says nothing"); `docs/guide/review-passes.md:105-114` (the lane line paragraph: a finished round's line can end in the stage); `docs/guide/reference.md` (the Statistics window row, if it has one — grep; else no change); `Maugham/Compiler/AREA.md` (a P3 paragraph beside the ask's and the ledger's: `ProcessSignals`, `DraftStage`/`LetterDosage`, the two per-run sections out of the hash, the stamp in the one `record` spelling, the session ruling; rows in the file table for the two new files); `Maugham/Views/AREA.md` (the `LetterSection` bullet: the stage word and the process part; a `statistics/` bullet: Practice reads closed logs, jumps open the chapter); `CLAUDE.md`'s Compiler cell (one sentence each for P3's stage/dosage and process signals — the letter fields list says "count `Letter`'s own fields", keep it so); `docs/roadmap.md:270` (P3 merged, the row's status flips when the milestone ships — leave the • until Denver's smoke; update the parenthetical); `docs/superpowers/notes/2026-09-02-editorial-letter-handoff.md` (NOT here — the P3 addendum is written after merge by the session, not by this task).

**Requirements.** `DocSyncTests` gates untouched by construction (no new `DetailSegment`, no shortcut, the round-ring docs' number unchanged — but `Maugham/Compiler/AREA.md` and `compiler.md` are in `roundRingDocs`, so re-run the suite). Every claim in the guide is of what ships in this branch. `docs/guide/index.json` is unchanged — no Statistics topic is added (a topic for one section is a stub; the compiler topic is where the writer meets the numbers).

Run `./scripts/test.sh`. Commit: `docs(letter): process and dosage — the guide, the area notes, the roadmap`.

## Whole-branch review (after Task 9, before the gate)

Give the reviewer the diff `main..HEAD` and these seams by name — the Critical has come from a seam no task's diff contained in P1 and P2:

- `beginRun` × `nothingNew`: the signals are computed AFTER the empty-delta return, so a `nothingNew` never derives a stage — confirm nothing downstream expects one.
- `parseLetter`'s dosage × the mint: a capped question must not mint; a `.short` letter's `scenes == nil` × `TurnClauseOffer`/`hasTurnlessScene` — no offer over a short letter, by construction, and the section's short-letter line explains why.
- `record`'s stamp × `LetterKeep.laneLine(for:)` × `LessonLedgerVerbs.provenance`: the stage in a letter-filed ledger row — is it drawn from the letter's stamp and never re-derived; and the queue's `stage: nil`.
- `ProcessSignals` sessions × `SessionTracker.idleThreshold`: one constant, and `DocumentStore:464`'s deadline still reads it.
- `ProjectPractice.derive` on the MAIN actor over every op log of a long novel: measure once on a 30-chapter fixture; if it exceeds ~200 ms, move the walk into a detached task in `ProjectStatisticsWindow.load()` (the `loadSyncMerged` path is `nonisolated`).
- Constraint 29: nothing in the footer/tree/editor.
- The budget test's recorded numbers versus a fresh measurement.
