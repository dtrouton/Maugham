# Translation Pipeline — Plan 4: Surfaces — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the seven-leg pipeline in front of the writer — the desk row that starts it (one chapter or the whole book) and reports it, the round report in the centre column with its verbs and click-through, Gloss and Ask the collator in the Translation pane, the statement pane's glossary table and orphaned directives, and the docs (guide, roadmap, AREA files, ADR 0030).

**Architecture:** Everything here is a *caller* of Plan 1–3's API, never a restatement of it. The desk keeps its shape (`DepartmentPane` takes values, `DepartmentPaneHost` does the disk work and owns the verbs); the round report is a fourth arm of the ONE `publishCentre` switch drawn inside `manuscriptEditor`'s existing `ZStack`, exactly as the design gate is; the report's verbs are a closure struct (`TranslationRoundActions`, `DesignGateActions`' shape) whose production wiring is `RulingPerformer.rule`, `Document.rejectAnnotation`/`acceptAnnotation` through `withAnnotationDocument`, and one new store verb `TranslationRoundStore.update`; Gloss and Ask the collator are two more `ColdCall` callers over pure briefings. No new `AnnotationKind`, no new session owner, no new MCP tool.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (macOS 26), XCTest, the Mac scheme (`./scripts/test.sh`), `MaughamCore` for `Ruling`'s shapes.

**Spec:** `docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` — §5 (whole book, pre-flight, the gate), §7 (the round record's trend), §8 (the round report, the desk row, `Phase.running` widening), §9 (Gloss, Ask the collator), §12 (report-surface and spot-check tests), §13 item 4, §14 (docs, ADR 0030). Read the P3 handoff first: `docs/superpowers/notes/2026-08-29-translation-pipeline-p3-handoff.md` — its "Plan 4 — surfaces" section names every seam this plan wires to.

## Global Constraints

- **Point at P1–P3's API by file; never restate it.** `TranslationPipeline` (`Maugham/Compiler/TranslationPipeline.swift`: `run(docId:language:)`, `runBook(documentIds:language:)`, `cancel()`, `status`, `Status.running(docId:language:leg:book:)`, `BookProgress`, `coldPreamble`), `TranslationRound` (`Maugham/Compiler/TranslationRound.swift`), `TranslationRoundStore` (`Maugham/Stores/TranslationRoundStore.swift`: `latest(language:docId:)`, `rounds(language:)`, `trend(language:)`, `append`), `TranslationPipeline.Environment.production(...)` and its gathers `readerBriefing`/`collatorBriefing`/`authorLanguage` (`Maugham/Compiler/TranslationPipelineEnvironment+Project.swift`), `ColdCall.call(message:preamble:model:)` (`Maugham/Compiler/ColdCall.swift`), `CollatorBriefing`/`CollatorReport`/`ReportJSON`, `RulingPerformer.rule(_:provenance:kind:forScope:store:world:)` (`Maugham/Compiler/RulingPerformer.swift`), `Ruling.directiveText`/`glossaryText`/`Provenance` (`Packages/MaughamCore/Sources/MaughamCore/RulingShapes.swift`), `TranslatorsNote`/`TranslatorsNoteSheet` (`Maugham/Views/TranslatorsNote.swift`), `QueryRuling`/`QueryRulingSheet` (`Maugham/Views/QueryRuling.swift`), `withAnnotationDocument(store:projectURL:documentId:body:)` and `currentParagraphState(documentId:store:documentStore:projectURL:)` (`Maugham/MCP/Tools/AnnotationToolHelpers.swift`, `Maugham/MCP/Tools/TranslationTools.swift`), `DepartmentPaneHost.scopedDocumentIds(_:imprint:in:)`.
- **The keystroke is the only trigger** (ADR 0028 tempo discipline): nothing here starts a run or a cold call from a timer or an event.
- **No new `AnnotationKind`, no new MCP tool, no new session owner.** The catalogue count stays at 56; `TranslatorEnvironmentTests`' teardown census is unchanged.
- **MCP never mutates manuscript text; neither does anything here.** Every write is a ruling (`RulingPerformer.rule`, the one door), an annotation lifecycle op, or a derived round record.
- **Tripwire 4:** no disk read on a `body` path. `DepartmentPane`, `TranslationRoundReportView` and `DepartureRowView` take values; the hosts read in `.task`s.
- **Tripwire 21:** every new notification goes through `MaughamEvent` with a declared scope; receive with `.onProjectEvent`/`.onKeyWindowCommand`.
- **Tripwire 15:** every `ContentUnavailableView` chains `.frame(maxWidth: .infinity, maxHeight: .infinity)`.
- **Tripwire 9:** `Button(.plain)`, never `.onTapGesture`, for clickable rows.
- **Global Constraint 2 of the publish-department spec:** a control that cannot act says why, in words, in the surface's one notice channel — never a silent no-op.
- **No `keyboardShortcut` on any desk or report verb** — ⌘R/⌘⇧R belong to the compiler in whichever window hosts these panes.
- **The round report is a fourth arm of the ONE `publishCentre` switch** inside `ProjectWindow.manuscriptEditor`'s `ZStack` — never a new ViewBuilder arm (a new arm tears `EditorHost` down on every Show and Back; stage 3a's rule, which `.designProposal` already follows).
- **Every implementer's pre-commit list**, in addition to the task's own suites: `-only-testing:MaughamTests/TripwireGrepTests` and `-only-testing:MaughamTests/AnnotationChangeEventTests` — both censuses bit P3 and only later tasks' fast loops caught them. A task that adds a source or test file runs `./gen.sh` before any `xcodebuild`.
- **Copy lives in statics** (`DepartmentDesk`/`DepartmentRunState`/`TranslationRoundReport`/`SpotCheck`), so every sentence the writer reads is assertable with nothing mounted.
- **Reviews:** opus for any task touching `ProjectWindow.body` or `TranslationPipeline`; a local Release build (`xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`) after any `ProjectWindow.body` change. Reviewer reports under ~80 lines, Issues first.

## File structure

| File | Responsibility |
|---|---|
| `Maugham/Views/Publish/DepartmentRunState.swift` (modify) | The row's run half as decisions: `Phase.running(RunningLeg)`, the round line, trend, pre-flight, the book verb's availability |
| `Maugham/Compiler/TranslationPreflight.swift` (create) | Word budget of a document set for one language — "~N words briefed" |
| `Maugham/Stores/TranslationRoundStore.swift` (modify) | `update(_:)` — the report's verbs rewrite one round in the ring |
| `Maugham/Compiler/TranslationRound.swift` (modify) | `GlossaryProposalRecord.skipped`, `disagreements` |
| `Maugham/Models/MaughamNotifications.swift`, `Maugham/Events/MaughamEvent.swift` (modify) | `.maughamTranslationRoundEnded` (project scope) + `.maughamRevealTranslation` (key-window command) |
| `Maugham/Views/Publish/DepartmentPane.swift`, `DepartmentPaneHost.swift`, `DepartmentCastSheet.swift` (modify) | The row draws leg/round/trend/pre-flight, Show, Run Whole Book; the host runs the pipeline |
| `Maugham/Views/Publish/PublishPreviewCentre.swift`, `Maugham/Views/ProjectWindow.swift`, `Maugham/Views/DetailPaneToggle.swift` (modify) | `PublishCentre.translationRound`, window state, Show threading |
| `Maugham/Views/Publish/TranslationRoundReport.swift` (create) | Pure: sections, rows, counts, copy, provenance strings |
| `Maugham/Views/Publish/TranslationRoundReportView.swift` (create) | The value-taking surface (six sections, verbs, sheets, click-through) |
| `Maugham/Views/Publish/TranslationRoundReportHost.swift` (create) | `.task` reads: source lines, chapter title, the round's queries |
| `Maugham/Views/Publish/TranslationRoundActions.swift` (create) | The verbs as closures + `.production(...)` |
| `Maugham/Views/Publish/DepartureRow.swift` (create) | One departure row with Fine / Keep mine / Make it a rule — shared by the report and the Translation pane |
| `Maugham/Views/Publish/RoundRuleSheet.swift` (create) | "Make it a rule" — a seeded sentence into the edition brief |
| `Maugham/Views/TranslationReveal.swift` (create) + `ProjectWindow.swift` (`TranslationReviewModifier`) | Click-through: select the chapter, enter translation review, navigate to the paragraph |
| `Maugham/Compiler/GlossBriefing.swift`, `GlossReport.swift`, `SpotCheck.swift` (create) | Gloss and Ask the collator: briefings, parser, the two cold calls |
| `Maugham/Views/TranslationReviewPane.swift` (modify) | The two verbs and what they draw |
| `Maugham/Views/RulingsStratum.swift`, `StatementPane.swift` (modify) | Glossary table, orphaned directives |
| `docs/adr/0030-…md`, `docs/roadmap.md`, `Maugham/*/AREA.md`, `docs/guide/*.md`, `docs/skills/translation-pass/SKILL.md` | Docs |

---

### Task 1: Foundations — the row's decisions, the pre-flight budget, the store's update verb, the two events

**Files:**
- Modify: `Maugham/Views/Publish/DepartmentRunState.swift` (`Phase` at ~line 154, `statusLine` ~193, `resolve` ~210, the Copy section ~289)
- Create: `Maugham/Compiler/TranslationPreflight.swift`
- Modify: `Maugham/Stores/TranslationRoundStore.swift` (after `append`)
- Modify: `Maugham/Compiler/TranslationRound.swift` (`GlossaryProposalRecord`, a `disagreements` accessor)
- Modify: `Maugham/Models/MaughamNotifications.swift` (beside `maughamTranslationDidUpdate`, ~line 88), `Maugham/Events/MaughamEvent.swift` (beside `postDesignProposalsChanged`, ~line 130)
- Test: `MaughamTests/DepartmentRunTests.swift` (update line 136's `.running(translating: 4)`; add cases), create `MaughamTests/TranslationPreflightTests.swift`, `MaughamTests/TranslationRoundStoreTests.swift` (add the update cases)

**Interfaces:**
- Consumes: `TranslationRound`, `TranslationRound.Leg.verb`, `TranslationPipeline.Status`, `TranslationPipeline.BookProgress`, `TranslationRoundStore`, `currentParagraphState`, `TranslationStore.loadMerged(forDocId:language:in:)`, `TranslationDeriver.derive(records:sequence:paragraphs:language:)` (the pipeline env's gathers use exactly these — copy their call shape from `TranslationPipelineEnvironment+Project.readerBriefing`).
- Produces (later tasks rely on these exact names):
  - `DepartmentRunState.RunningLeg` — `enum RunningLeg: Equatable { case translating(Int); case leg(TranslationRound.Leg, book: TranslationPipeline.BookProgress?) }`
  - `DepartmentRunState.Phase.running(RunningLeg)` (replaces `running(translating: Int)`)
  - `DepartmentRunState` fields: `latestRound: TranslationRound? = nil`, `trend: [Int] = []`, `chapterWords: Int? = nil`, `bookWords: Int? = nil`, `bookDocumentCount: Int = 0`, `now: Date = Date()`
  - `DepartmentRunState.detailLine: String?`, `offersShow: Bool`, `bookRefusal: String?`, `canRunBook: Bool`
  - statics: `legLine(_ leg: TranslationRound.Leg, book: TranslationPipeline.BookProgress?) -> String`, `roundLine(_ round: TranslationRound, now: Date) -> String`, `ago(from: Date, to: Date) -> String`, `trendLine(_ counts: [Int]) -> String?`, `preflightLine(words: Int?) -> String?`, `runBookTitle`, `runBookAccessibilityLabel(language:)`, `runBookHelp(language:count:words:)`, `showRoundTitle`, `showRoundAccessibilityLabel(language:)`, `showRoundHelp`, `nothingInTheBook`
  - `DepartmentRunState.resolve(language:target:session:runState:lastRun:pipeline:latestRound:trend:chapterWords:bookWords:bookDocumentCount:now:)` — the six new parameters defaulted (`.idle`, `nil`, `[]`, `nil`, `nil`, `0`, `Date()`) so every existing call site compiles unchanged
  - `TranslationPreflight.wordCount(_ text: String) -> Int`, `TranslationPreflight.budget(documentIds:language:store:documentStore:projectURL:) -> Int?` (`@MainActor`; nil when no document could be read)
  - `TranslationRoundStore.update(_ round: TranslationRound) throws`, `TranslationRoundStore.UpdateError.roundGone(number: Int)`
  - `TranslationRound.GlossaryProposalRecord.skipped: Bool?`; `TranslationRound.Disagreement` and `TranslationRound.disagreements: [Disagreement]`
  - `Notification.Name.maughamTranslationRoundEnded` (`"maugham.translation.round.ended"`, scope `.project`), payload keys `"language"`, `"document_id"`, `"round"`; `MaughamEvent.postTranslationRoundEnded(projectURL: URL, round: TranslationRound)`
  - `Notification.Name.maughamRevealTranslation` (`"maugham.revealTranslation"`, scope `.keyWindow`), payload keys `"document_id"`, `"language"`, `"paragraph_id"` — declared here, handled in Task 5

- [ ] **Step 1: Write the failing tests for the row's decisions**

In `MaughamTests/DepartmentRunTests.swift`, change line 136's construction to the new shape and add these cases near `test_thePhaseBelongsToOneLanguageOfOneDocument`:

```swift
    /// **The pipeline's leg is what the row draws**, scoped by LANGUAGE alone:
    /// a book queue walks chapters the window is not on, and a row that went
    /// idle whenever the queue left the open chapter would say nothing for
    /// eleven of twelve rounds.
    func test_aPipelineLegIsDrawnOnItsLanguagesRowWhateverChapterTheWindowIsOn() {
        let state = DepartmentRunState.resolve(
            language: "es",
            target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .busy(language: "es"),
            runState: .idle, lastRun: nil,
            pipeline: .running(docId: "doc-9", language: "es", leg: .read,
                               book: .init(position: 4, count: 12)))
        XCTAssertEqual(state.phase,
                       .running(.leg(.read, book: .init(position: 4, count: 12))))
        XCTAssertEqual(state.statusLine, DepartmentRunState.legLine(
            .read, book: .init(position: 4, count: 12)))
        XCTAssertTrue(state.statusLine?.contains("4 of 12") == true)
        XCTAssertTrue(state.statusLine?.contains("reading") == true)

        let french = DepartmentRunState.resolve(
            language: "fr",
            target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .busy(language: "es"),
            runState: .idle, lastRun: nil,
            pipeline: .running(docId: "doc-1", language: "es", leg: .read, book: nil))
        XCTAssertEqual(french.phase, .idle, "a Spanish leg is not the French row's")
    }

    /// **A bare translator round keeps its own count line** — the phase the
    /// probe mounts still produce, unchanged in words.
    func test_aBareTranslatorRoundStillSaysHowManyParagraphs() {
        let state = DepartmentRunState.resolve(
            language: "es",
            target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .busy(language: "es"),
            runState: .running(docId: "doc-1", language: "es", translating: 4),
            lastRun: nil)
        XCTAssertEqual(state.phase, .running(.translating(4)))
        XCTAssertEqual(state.statusLine, DepartmentRunState.translating(4))
    }

    /// **An idle row with a round says the round, not the translator's own
    /// summary.** The log records every translator LEG's summary, so after a
    /// seven-leg round its newest entry is leg 7's "2 paragraphs translated" —
    /// a sentence about a repair, drawn as if it were the round.
    func test_theRoundLineOutranksTheTranslatorsOwnSummaryWhenARoundExists() {
        var round = TranslationRound(number: 3, language: "es", docId: "doc-1",
                                     startedAt: Date(timeIntervalSinceNow: -300))
        round.endedAt = Date(timeIntervalSinceNow: -120)
        round.legs = TranslationRound.Leg.allCases.map { .init(leg: $0, status: .skipped, reason: "x") }
        let summary = TranslatorOrchestrator.RunSummary(
            runId: "r", docId: "doc-1", language: "es", at: Date(),
            outcome: .ingested(.init(entriesWritten: 2, queriesMinted: 0)))
        let now = Date()
        let state = DepartmentRunState.resolve(
            language: "es", target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .free, runState: .idle, lastRun: summary,
            latestRound: round, trend: [6, 4, 1], now: now)
        XCTAssertEqual(state.statusLine, DepartmentRunState.roundLine(round, now: now))
        XCTAssertTrue(state.statusLine?.hasPrefix("Round 3") == true)
        XCTAssertTrue(state.statusLine?.contains("2m ago") == true)
        XCTAssertTrue(state.offersShow)

        let none = DepartmentRunState.resolve(
            language: "es", target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .free, runState: .idle, lastRun: summary)
        XCTAssertEqual(none.statusLine, DepartmentRunState.reportLine(summary.outcome),
                       "with no round the translator's summary is still the idle line")
        XCTAssertFalse(none.offersShow)
    }

    func test_aStoppedRoundSaysWhereItStopped() {
        var round = TranslationRound(number: 2, language: "es", docId: "doc-1", startedAt: Date())
        round.endedAt = Date()
        round.legs = [.init(leg: .translate, status: .ran, counts: .init(entries: 1)),
                      .init(leg: .read, status: .cancelled)]
        let line = DepartmentRunState.roundLine(round, now: Date())
        XCTAssertTrue(line.contains("Round 2"))
        XCTAssertTrue(line.contains("cancelled"), line)
        XCTAssertTrue(line.contains("reading"), line)

        round.legs[1] = .init(leg: .read, status: .failed, reason: "The reader died.")
        let failed = DepartmentRunState.roundLine(round, now: Date())
        XCTAssertTrue(failed.contains("failed"), failed)
        XCTAssertTrue(failed.contains("The reader died."), "the failure's own sentence rides the line")
    }

    func test_agoIsCoarseAndNeverNegative() {
        let now = Date()
        XCTAssertEqual(DepartmentRunState.ago(from: now.addingTimeInterval(-5), to: now), "just now")
        XCTAssertEqual(DepartmentRunState.ago(from: now.addingTimeInterval(-125), to: now), "2m ago")
        XCTAssertEqual(DepartmentRunState.ago(from: now.addingTimeInterval(-7200), to: now), "2h ago")
        XCTAssertEqual(DepartmentRunState.ago(from: now.addingTimeInterval(-3 * 86400), to: now), "3d ago")
        XCTAssertEqual(DepartmentRunState.ago(from: now.addingTimeInterval(60), to: now), "just now",
                       "a clock skewed into the future is 'just now', not '-1m ago'")
    }

    /// **Pre-flight and trend share one detail line** (spec §8: they share the
    /// row's slot rather than adding a line each), and the line is absent when
    /// neither has anything to say.
    func test_theDetailLineCarriesPreflightAndTrendAndIsAbsentWithNeither() {
        XCTAssertEqual(DepartmentRunState.preflightLine(words: 1200), "7 legs · ~1,200 words briefed")
        XCTAssertNil(DepartmentRunState.preflightLine(words: nil))
        XCTAssertEqual(DepartmentRunState.trendLine([6, 4, 1]), "notes per round 6 → 4 → 1")
        XCTAssertEqual(DepartmentRunState.trendLine([4]), "notes per round 4")
        XCTAssertNil(DepartmentRunState.trendLine([]))

        var state = DepartmentRunState()
        XCTAssertNil(state.detailLine)
        state.chapterWords = 1200
        state.trend = [6, 4, 1]
        XCTAssertEqual(state.detailLine, "7 legs · ~1,200 words briefed · notes per round 6 → 4 → 1")
        state.phase = .running(.leg(.read, book: nil))
        XCTAssertNil(state.detailLine, "a running row's detail is its leg; the pre-flight is for a click that has not happened")
    }

    /// **Run Whole Book needs no open chapter** — the book is the desk's own
    /// set — but it refuses while a session is busy and when the set is empty.
    func test_theBookVerbRefusesOnlyForBusyAndForAnEmptyBook() {
        let noChapter = DepartmentRunState.resolve(
            language: "es", target: .unavailable(DepartmentRunTarget.openAChapter),
            session: .free, runState: .idle, lastRun: nil, bookDocumentCount: 12)
        XCTAssertNil(noChapter.bookRefusal)
        XCTAssertTrue(noChapter.canRunBook)
        XCTAssertFalse(noChapter.canRun, "…while the chapter Run still refuses")

        let busy = DepartmentRunState.resolve(
            language: "es", target: .unavailable(DepartmentRunTarget.openAChapter),
            session: .busy(language: "fr"), runState: .idle, lastRun: nil, bookDocumentCount: 12)
        XCTAssertEqual(busy.bookRefusal, DepartmentRunState.busyReason(language: "fr"))

        let empty = DepartmentRunState.resolve(
            language: "es", target: .unavailable(DepartmentRunTarget.openAChapter),
            session: .free, runState: .idle, lastRun: nil, bookDocumentCount: 0)
        XCTAssertEqual(empty.bookRefusal, DepartmentRunState.nothingInTheBook)
    }
```

- [ ] **Step 2: Write the failing tests for the budget, the store's update, and the events**

Create `MaughamTests/TranslationPreflightTests.swift`:

```swift
import XCTest
@testable import Maugham

final class TranslationPreflightTests: XCTestCase {

    func test_wordCountSplitsOnWhitespaceLikeTheCheckpointsOwnCount() {
        XCTAssertEqual(TranslationPreflight.wordCount("The fog came in."), 4)
        XCTAssertEqual(TranslationPreflight.wordCount("one\n\ntwo   three\tfour"), 4)
        XCTAssertEqual(TranslationPreflight.wordCount(""), 0)
        XCTAssertEqual(TranslationPreflight.wordCount("   "), 0)
    }

    /// The budget is source words plus translated words of every document in
    /// the set — the two texts every leg is briefed with.
    func test_theBudgetSumsSourceAndTranslationAcrossTheSet() throws {
        XCTAssertEqual(TranslationPreflight.sum(source: ["a b c", "d e"], translations: ["x y", nil]), 7)
        XCTAssertEqual(TranslationPreflight.sum(source: [], translations: []), 0)
    }
}
```

In `MaughamTests/TranslationRoundStoreTests.swift` add:

```swift
    func test_updateRewritesOneRoundInPlaceAndKeepsTheOthers() throws {
        let store = TranslationRoundStore(projectURL: temp.url)
        var first = TranslationRound(number: 1, language: "es", docId: "d", startedAt: Date())
        var second = TranslationRound(number: 2, language: "es", docId: "d", startedAt: Date())
        second.departures = [.init(id: "dep", paragraphId: "a1b2", verdict: "holds",
                                   kind: "rendering", note: "n", gloss: "g")]
        try store.append(first)
        try store.append(second)

        second.departures[0].outcome = .dismissed
        try store.update(second)

        let rounds = store.rounds(language: "es")
        XCTAssertEqual(rounds.map(\.number), [2, 1])
        XCTAssertEqual(rounds[0].departures[0].outcome, .dismissed)
        XCTAssertEqual(store.nextNumber(language: "es"), 3, "update never mints")
        first.summary = "x"
        XCTAssertNoThrow(try store.update(first))
    }

    func test_updatingARoundThatAgedOutOfTheRingIsRefusedInWords() throws {
        let store = TranslationRoundStore(projectURL: temp.url)
        let gone = TranslationRound(number: 99, language: "es", docId: "d", startedAt: Date())
        XCTAssertThrowsError(try store.update(gone)) { error in
            guard case TranslationRoundStore.UpdateError.roundGone(let number) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(number, 99)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func test_aSkippedProposalRoundTripsAndAnOldRecordWithoutTheFieldStillDecodes() throws {
        var round = TranslationRound(number: 1, language: "es", docId: "d", startedAt: Date())
        round.glossaryProposals = [.init(term: "fog", rendering: "niebla", reason: "r", adopted: false)]
        round.glossaryProposals[0].skipped = true
        let data = try JSONEncoder().encode(round)
        let back = try JSONDecoder().decode(TranslationRound.self, from: data)
        XCTAssertEqual(back.glossaryProposals[0].skipped, true)
        let old = #"{"term":"fog","rendering":"niebla","reason":"r","adopted":false}"#.data(using: .utf8)!
        let record = try JSONDecoder().decode(TranslationRound.GlossaryProposalRecord.self, from: old)
        XCTAssertNil(record.skipped)
    }

    func test_disagreementsAreTheDeclinedNotesAndDepartures() {
        var round = TranslationRound(number: 1, language: "es", docId: "d", startedAt: Date())
        round.notes = [
            .init(id: "n1", leg: .read, author: "Ocampo", paragraphId: "a1b2", kind: "rhythm",
                  severity: "minor", text: "limps", outcome: .declined(reason: "meter", annotationId: "ann-1")),
            .init(id: "n2", leg: .read, author: "Ocampo", paragraphId: "a1b2", kind: "rhythm",
                  severity: "minor", text: "fine", outcome: .addressed(.init(
                    beforeRecordId: nil, before: nil, afterRecordId: nil, after: nil)))
        ]
        round.departures = [
            .init(id: "d1", paragraphId: "c3d4", verdict: "drifted", kind: "omission", note: "lost",
                  gloss: "g", outcome: .declined(reason: "no", annotationId: nil))
        ]
        let ids = round.disagreements.map(\.recordId)
        XCTAssertEqual(ids, ["n1", "d1"])
        XCTAssertEqual(round.disagreements[0].annotationId, "ann-1")
        XCTAssertNil(round.disagreements[1].annotationId)
        XCTAssertEqual(round.disagreements[0].author, "Ocampo")
    }
```

Add to `MaughamTests/Events/` the event pins (find the file that already pins `maughamDesignProposalsChanged`'s scope — `grep -rn "maughamDesignProposalsChanged" MaughamTests/Events` — and add beside it):

```swift
    func test_theRoundEndedEventIsProjectScopedAndNamesTheRound() {
        var round = TranslationRound(number: 4, language: "es", docId: "doc-1", startedAt: Date())
        round.endedAt = Date()
        let url = URL(fileURLWithPath: "/tmp/p")
        var received: Notification?
        let token = NotificationCenter.default.addObserver(
            forName: .maughamTranslationRoundEnded, object: nil, queue: nil) { received = $0 }
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.postTranslationRoundEnded(projectURL: url, round: round)
        XCTAssertEqual(received?.userInfo?["language"] as? String, "es")
        XCTAssertEqual(received?.userInfo?["document_id"] as? String, "doc-1")
        XCTAssertEqual(received?.userInfo?["round"] as? Int, 4)
        // Scope: the same project-scope assertion the design-proposals event makes
        // in this file — copy that assertion's shape verbatim for this name.
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DepartmentRunTests -only-testing:MaughamTests/TranslationPreflightTests -only-testing:MaughamTests/TranslationRoundStoreTests 2>&1 | tail -30`
Expected: build failure — `RunningLeg`, `TranslationPreflight`, `update`, `skipped`, `disagreements`, `postTranslationRoundEnded` do not exist.

- [ ] **Step 4: Implement the row's decisions**

In `DepartmentRunState.swift`:

```swift
    /// **What the running row is doing** (spec §8). A bare translator round
    /// (`TranslatorOrchestrator.runTranslation` with no pipeline around it —
    /// the probe mounts) still says its work-list's count; a pipeline round
    /// says its LEG, and for a book queue which chapter of how many.
    enum RunningLeg: Equatable {
        case translating(Int)
        case leg(TranslationRound.Leg, book: TranslationPipeline.BookProgress?)
    }

    enum Phase: Equatable {
        case idle
        case running(RunningLeg)
        case nothingToTranslate
        case failed(TranslatorOrchestrator.Failure)
    }

    var phase: Phase = .idle
    var report: String? = nil
    var refusal: String? = nil
    /// The newest round for this LANGUAGE (numbering is per language across
    /// documents, spec §7; the Show header names the chapter).
    var latestRound: TranslationRound? = nil
    /// `TranslationRoundStore.trend` — notes per round, oldest first.
    var trend: [Int] = []
    /// `TranslationPreflight.budget` over the open chapter, and over the desk's
    /// document set; nil when nothing could be counted.
    var chapterWords: Int? = nil
    var bookWords: Int? = nil
    var bookDocumentCount: Int = 0
    /// Injected so `roundLine`'s "2m ago" is assertable.
    var now: Date = Date()

    var offersShow: Bool { latestRound != nil }

    /// Run Whole Book refuses for a busy session and for an empty set — never
    /// for a missing open chapter, which the book does not need.
    var bookRefusal: String? {
        if let refusal, refusal != DepartmentRunTarget.openAChapter { return refusal }
        if bookDocumentCount == 0 { return Self.nothingInTheBook }
        return nil
    }
    var canRunBook: Bool { bookRefusal == nil }

    var statusLine: String? {
        switch phase {
        case .running(.translating(let count)): return Self.translating(count)
        case .running(.leg(let leg, let book)): return Self.legLine(leg, book: book)
        case .failed(let failure): return Self.failureCopy(failure)
        case .nothingToTranslate: return Self.nothingToTranslateLine
        case .idle:
            if let latestRound { return Self.roundLine(latestRound, now: now) }
            return report
        }
    }

    /// Pre-flight and trend, one line, only while idle.
    var detailLine: String? {
        guard case .idle = phase else { return nil }
        let parts = [Self.preflightLine(words: chapterWords ?? bookWords),
                     Self.trendLine(trend)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00b7} ")
    }
```

`resolve` gains the defaulted parameters and, before the `runState` switch, the pipeline arm (language-scoped — a book queue is not about the open chapter):

```swift
        if case .running(_, let runLanguage, let leg, let book) = pipeline, runLanguage == language {
            phase = .running(.leg(leg, book: book))
        } else {
            switch runState { … existing arms, with `.running(.translating(translating))` … }
        }
        …
        return DepartmentRunState(phase: phase, report: report,
                                  refusal: refusal(target: target, session: session),
                                  latestRound: latestRound, trend: trend,
                                  chapterWords: chapterWords, bookWords: bookWords,
                                  bookDocumentCount: bookDocumentCount, now: now)
```

Copy:

```swift
    static let runBookTitle = "Run Whole Book"
    static func runBookAccessibilityLabel(language: String) -> String {
        "Run the whole book into " + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
    }
    static func runBookHelp(language: String, count: Int, words: Int?) -> String {
        let edition = TranslationReviewIndicator.displayLabel(forLanguageTag: language)
        let chapters = count == 1 ? "1 chapter" : "\(count) chapters"
        let budget = preflightLine(words: words).map { " \u{2014} \($0)" } ?? ""
        return "Run one round on every chapter of this book into \(edition), in order: \(chapters)\(budget)."
    }
    static let nothingInTheBook =
        "There is nothing in this book to translate \u{2014} the imprint the desk is on names no chapters."
    static let showRoundTitle = "Show"
    static func showRoundAccessibilityLabel(language: String) -> String {
        "Show the latest " + TranslationReviewIndicator.displayLabel(forLanguageTag: language) + " round"
    }
    static let showRoundHelp = "Read the round's report in the centre column"

    static func legLine(_ leg: TranslationRound.Leg, book: TranslationPipeline.BookProgress?) -> String {
        let verb = "\(leg.verb)\u{2026} (leg \(leg.rawValue) of \(TranslationRound.Leg.allCases.count))"
        guard let book else { return verb.prefix(1).uppercased() + verb.dropFirst() }
        return "Chapter \(book.position) of \(book.count) \u{00b7} \(verb)"
    }

    static func roundLine(_ round: TranslationRound, now: Date) -> String {
        let when = ago(from: round.endedAt ?? round.startedAt, to: now)
        guard let stopped = round.legs.first(where: { $0.status == .failed || $0.status == .cancelled }) else {
            return "Round \(round.number) \u{00b7} finished \(when)"
        }
        if stopped.status == .cancelled {
            return "Round \(round.number) \u{00b7} cancelled while \(stopped.leg.verb) \u{00b7} \(when)"
        }
        let reason = stopped.reason.map { " \u{2014} \($0)" } ?? ""
        return "Round \(round.number) \u{00b7} failed while \(stopped.leg.verb)\(reason) \u{00b7} \(when)"
    }

    static func ago(from: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(from))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    static func trendLine(_ counts: [Int]) -> String? {
        guard !counts.isEmpty else { return nil }
        return "notes per round " + counts.map(String.init).joined(separator: " \u{2192} ")
    }

    static func preflightLine(words: Int?) -> String? {
        guard let words else { return nil }
        return "\(TranslationRound.Leg.allCases.count) legs \u{00b7} ~\(words.formatted(.number)) words briefed"
    }
```

- [ ] **Step 5: Implement `TranslationPreflight`, `update`, `skipped`, `disagreements`, the events**

`Maugham/Compiler/TranslationPreflight.swift`:

```swift
import Foundation
import MaughamCore

/// **"7 legs · ~N words briefed"** (spec §5's pre-flight): what a Run will send,
/// as a number the writer can weigh before the click. N is the source words
/// plus the translated words of every document in the set — the two texts the
/// legs are briefed with. `Bootstrap`'s own whitespace split, so the figure
/// agrees with the checkpoint's word count.
enum TranslationPreflight {

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    static func sum(source: [String], translations: [String?]) -> Int {
        source.map(wordCount).reduce(0, +)
            + translations.compactMap { $0 }.map(wordCount).reduce(0, +)
    }

    /// nil when no document in the set could be read. Off the body path only
    /// (tripwire 4): it opens every document's derived state.
    @MainActor
    static func budget(documentIds: [String], language: String, store: ProjectStore,
                       documentStore: DocumentStore?, projectURL: URL) -> Int? {
        var total = 0
        var counted = false
        for docId in documentIds {
            guard let state = try? currentParagraphState(
                documentId: docId, store: store, documentStore: documentStore,
                projectURL: projectURL) else { continue }
            counted = true
            let records = TranslationStore.loadMerged(forDocId: docId, language: language, in: projectURL)
            let derived = TranslationDeriver.derive(
                records: records, sequence: state.sequence, paragraphs: state.paragraphs, language: language)
            total += sum(source: derived.entries.map(\.sourceText),
                         translations: derived.entries.map(\.translatedText))
        }
        return counted ? total : nil
    }
}
```

(Read `TranslationDeriver`'s entry type for the exact property names of source and translated text — `TranslationPipelineEnvironment+Project.collatorBriefing` reads `entry.sourceText` and `entry.translatedText`; use the same.)

`TranslationRoundStore`:

```swift
    enum UpdateError: LocalizedError {
        case roundGone(number: Int)
        var errorDescription: String? {
            switch self {
            case .roundGone(let number):
                return "Round \(number) is no longer in the ledger \u{2014} it has aged out of the last \(TranslationRoundStore.ringSize)."
            }
        }
    }

    /// Rewrite one round the report's verbs changed (a departure dismissed, a
    /// proposal adopted). Never mints and never moves the number.
    func update(_ round: TranslationRound) throws {
        var ledger = load(language: round.language)
        guard let index = ledger.rounds.firstIndex(where: { $0.number == round.number }) else {
            throw UpdateError.roundGone(number: round.number)
        }
        ledger.rounds[index] = round
        try write(ledger, language: round.language)
    }
```

`TranslationRound`: `GlossaryProposalRecord` gains `var skipped: Bool? = nil` (declared AFTER `adopted`, so the memberwise init keeps its argument order and existing callers compile); add:

```swift
    /// A note or departure the translator declined — the report's
    /// Disagreements section (spec §8 item 3).
    enum Disagreement: Equatable {
        case note(NoteRecord, reason: String, annotationId: String?)
        case departure(DepartureRecord, reason: String, annotationId: String?)

        var recordId: String { … }
        var paragraphId: String { … }
        var annotationId: String? { … }
        var reason: String { … }
        /// The note's own author for a reader's note; nil for a departure (the
        /// caller names the collator).
        var author: String? { if case .note(let n, _, _) = self { return n.author }; return nil }
        var text: String { … note.text / departure.note … }
    }

    var disagreements: [Disagreement] {
        notes.compactMap { note in
            if case .declined(let reason, let annotationId) = note.outcome {
                return .note(note, reason: reason, annotationId: annotationId)
            }
            return nil
        } + departures.compactMap { departure in
            if case .declined(let reason, let annotationId) = departure.outcome {
                return .departure(departure, reason: reason, annotationId: annotationId)
            }
            return nil
        }
    }
```

`MaughamNotifications.swift` (beside `maughamTranslationDidUpdate`):

```swift
    /// Posted by the window's pipeline wiring when a round ends — data event,
    /// scope `.project(for: projectURL)`, like `maughamTranslationDidUpdate`.
    /// `userInfo["language"]`, `["document_id"]`, `["round"]` (Int).
    public static let maughamTranslationRoundEnded = Notification.Name("maugham.translation.round.ended")
    /// Posted by the round report and the Translation pane to take the writer
    /// to one paragraph of one edition in translation review. Scope: .keyWindow.
    /// `userInfo["document_id"]`, `["language"]`, `["paragraph_id"]`.
    public static let maughamRevealTranslation = Notification.Name("maugham.revealTranslation")
```

`MaughamEvent.swift` (beside `postDesignProposalsChanged`):

```swift
    static func postTranslationRoundEnded(projectURL: URL, round: TranslationRound) {
        post(.maughamTranslationRoundEnded, to: .project(for: projectURL),
             payload: ["language": round.language, "document_id": round.docId, "round": round.number])
    }
```

If `MaughamEvent` (or `TripwireGrepTests`) keeps a scope table of names, add both names to it with their scopes — the test that pins `maughamDesignProposalsChanged`'s scope will tell you where.

- [ ] **Step 6: Run the tests, then the two censuses**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DepartmentRunTests -only-testing:MaughamTests/TranslationPreflightTests -only-testing:MaughamTests/TranslationRoundStoreTests -only-testing:MaughamTests/Events -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests 2>&1 | grep -E "Test Suite|passed|failed|error:" | tail -20`
Expected: all green. Then `./scripts/test.sh` (fast loop) green.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Views/Publish/DepartmentRunState.swift Maugham/Compiler/TranslationPreflight.swift Maugham/Stores/TranslationRoundStore.swift Maugham/Compiler/TranslationRound.swift Maugham/Models/MaughamNotifications.swift Maugham/Events/MaughamEvent.swift MaughamTests/
git commit -m "feat(translation-pipeline): the desk row's leg/round/trend/pre-flight decisions, round update verb, two events"
```

---

### Task 2: The desk runs the pipeline — Run → pipeline, Run Whole Book, Show, the row's new lines

**Files:**
- Modify: `Maugham/Views/Publish/DepartmentPane.swift` (`languageRow` ~line 600, `runControls` ~693, `DepartmentDesk`)
- Modify: `Maugham/Views/Publish/DepartmentPaneHost.swift` (`desk` ~236, `runStates` ~328, `run(language:)` ~365, `confirmCast` ~467, `derive()` ~745, the event subscriptions ~219)
- Modify: `Maugham/Views/Publish/DepartmentCastSheet.swift` (`DepartmentCastPrompt.Ask`, ~line 22 and every `switch` over it)
- Modify: `Maugham/Views/DetailPaneToggle.swift` (the `onShowDesignProposal` property ~line 70, init ~133–166, and the desk mount that passes it)
- Modify: `Maugham/Views/ProjectWindow.swift` (`pipeline.configure` ~line 3866: post the event; the `DetailPaneToggle` call ~2951: thread `onShowTranslationRound`; a new `@State publishSelectedRound: TranslationRound?` beside `publishSelectedProposal` ~line 194 — the arm that DRAWS it is Task 3)
- Test: `MaughamTests/DepartmentRunTests.swift` (mounted desk cases; rewrite `test_theLanguageRunDrivesARealRoundWhoseReportTheRowDraws` ~line 1372), `MaughamTests/DepartmentPaneTests.swift`

**Interfaces:**
- Consumes: Task 1's `DepartmentRunState` fields and statics; `TranslationPipeline.run/runBook/status`; `TranslationRoundStore.latest(language:docId:)`/`trend`; `TranslationPreflight.budget`; `DepartmentPaneHost.scopedDocumentIds`; `MaughamEvent.postTranslationRoundEnded`.
- Produces:
  - `DepartmentPane.runBook: (String) -> Void = { _ in }`, `DepartmentPane.showRound: (String) -> Void = { _ in }`
  - `DepartmentPaneHost.onShowRound: (TranslationRound) -> Void = { _ in }`
  - `DepartmentCastPrompt.Ask.nameForBookRun(language: String, documentIds: [String])`
  - `DetailPaneToggle.onShowTranslationRound: (TranslationRound) -> Void = { _ in }` (init parameter of the same name)
  - `ProjectWindow`'s `@State private var publishSelectedRound: TranslationRound?` — written by `onShowTranslationRound: { publishSelectedRound = $0; publishSelectedProposal = nil }`; `onShowDesignProposal` now also sets `publishSelectedRound = nil` (one centre, one selection)

- [ ] **Step 1: Write the failing mounted-desk tests**

In `DepartmentRunTests.swift`, extend the private `mount(languages:target:…)` fixture (~line 2019) with defaulted `runs: [String: DepartmentRunState]? = nil`, `runBook: @escaping (String) -> Void = { _ in }`, `showRound: @escaping (String) -> Void = { _ in }` (use `runs` when given instead of resolving), and add:

```swift
    func test_runWholeBookIsOnEveryRowAndNamesItsEdition() async throws {
        var asked: [String] = []
        let window = mount(languages: ["es", "fr"],
                           target: .unavailable(DepartmentRunTarget.openAChapter),
                           runs: ["es": .init(bookDocumentCount: 3), "fr": .init(bookDocumentCount: 3)],
                           runBook: { asked.append($0) })
        _ = try await scrollersSettling(in: window)
        let buttons = try axButtons(labelled: DepartmentRunState.runBookAccessibilityLabel(language: "fr"),
                                    in: window)
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(axEnabled(buttons[0]), true, "the book needs no open chapter")
        press(buttons[0])
        _ = await pumpUntil(deadline: 3) { !asked.isEmpty }
        XCTAssertEqual(asked, ["fr"])
    }

    func test_showIsDrawnOnlyWhereARoundExistsAndNamesItsEdition() async throws {
        var shown: [String] = []
        var round = TranslationRound(number: 2, language: "es", docId: "doc-1", startedAt: Date())
        round.endedAt = Date()
        let window = mount(languages: ["es", "fr"],
                           target: .ready(docId: "doc-1", title: "Chapter 1"),
                           runs: ["es": .init(latestRound: round), "fr": .init()],
                           showRound: { shown.append($0) })
        _ = try await scrollersSettling(in: window)
        XCTAssertEqual(try axButtons(labelled: DepartmentRunState.showRoundAccessibilityLabel(language: "fr"),
                                     in: window).count, 0)
        let show = try axButtons(labelled: DepartmentRunState.showRoundAccessibilityLabel(language: "es"),
                                 in: window)
        XCTAssertEqual(show.count, 1)
        press(show[0])
        _ = await pumpUntil(deadline: 3) { !shown.isEmpty }
        XCTAssertEqual(shown, ["es"])
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.hasPrefix("Round 2") }, "\(texts)")
    }

    func test_theRowDrawsItsLegAndItsDetailLine() async throws {
        var idle = DepartmentRunState()
        idle.chapterWords = 900
        idle.trend = [3, 1]
        let running = DepartmentRunState(phase: .running(.leg(.collate, book: .init(position: 2, count: 5))))
        let window = mount(languages: ["es", "fr"],
                           target: .ready(docId: "doc-1", title: "Chapter 1"),
                           runs: ["es": idle, "fr": running])
        _ = try await scrollersSettling(in: window)
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains(idle.detailLine!), "\(texts)")
        XCTAssertTrue(texts.contains(DepartmentRunState.legLine(.collate, book: .init(position: 2, count: 5))))
    }
```

Rewrite `test_theLanguageRunDrivesARealRoundWhoseReportTheRowDraws` as **`test_theLanguageRunDrivesTheSevenLegPipelineAndTheRowDrawsTheRound`**: mount `DepartmentPaneHost` (its existing host fixture in this file) with a `TranslationPipeline` whose environment is `TranslationPipelineTests.FakeWorld().environment()` (internal, same test target) with two fields overridden before `configure`:

```swift
        let world = TranslationPipelineTests.FakeWorld()
        var env = world.environment()
        env.saveRound = { try? TranslationRoundStore(projectURL: projectURL).append($0) }
        env.onRoundEnded = { MaughamEvent.postTranslationRoundEnded(projectURL: projectURL, round: $0) }
        let pipeline = TranslationPipeline()
        pipeline.configure(environment: env)
```

(`FakeWorld.init` configures its OWN pipeline; you configure a second one from the same closures — the fake's `end(with:)` resumes `world.pipeline`, not yours, so ALSO override `env.runTranslation`/`env.runFix` to resume the pipeline you mounted: copy the two closures' bodies from `FakeWorld.environment()` and replace `pipeline.translatorRunEnded` with your instance's. Keep it in a small local helper.) Press the row's Run, `pumpUntil` the row's texts contain a string with prefix `"Round 7"` (the fake's `nextNumber` is 7), and assert a Show button for `es` exists. Assert `world.calls` is non-empty and begins `["translate"]` — proof the click reached the pipeline and not `translator.runTranslation`.

Add a host-level test that Run Whole Book asks the pipeline for the desk's scoped set in binder order (`pipeline.status` reads `.running(docId: <first id>, …, book: .init(position: 1, count: N))` right after the press).

Add, in `DepartmentPaneTests`, a pure test that `DepartmentPaneHost.bookAsk(language:documentIds:)` (a tiny static you will add) yields `.nameForBookRun` and that `DepartmentCastPrompt`'s title/headline arms for it read "Name & Run" with the edition named (assert through whatever statics `DepartmentCastCopy` already exposes for `.nameForRun`).

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild … -only-testing:MaughamTests/DepartmentRunTests -only-testing:MaughamTests/DepartmentPaneTests 2>&1 | tail -20`
Expected: build failure on `runBook:`/`showRound:`/`nameForBookRun`.

- [ ] **Step 3: Implement the pane**

`DepartmentPane`: two new closures (`runBook`, `showRound`); in `languageRow`, beside the status text draw Show when `run.offersShow` (`Button(DepartmentRunState.showRoundTitle) { showRound(row.language) }.controlSize(.small).accessibilityLabel(DepartmentRunState.showRoundAccessibilityLabel(language: row.language)).help(DepartmentRunState.showRoundHelp)`), and beneath it `run.detailLine` in `.caption`/`.secondary` with `fixedSize(horizontal: false, vertical: true)`; in `runControls` add the book verb after Run:

```swift
        Button(DepartmentRunState.runBookTitle) { runBook(row.language) }
            .controlSize(.small)
            .disabled(!run.canRunBook)
            .accessibilityLabel(DepartmentRunState.runBookAccessibilityLabel(language: row.language))
            .help(run.bookRefusal
                  ?? DepartmentRunState.runBookHelp(language: row.language,
                                                    count: run.bookDocumentCount,
                                                    words: run.bookWords))
```

and the same verb as a `.contextMenu` item beside the row's rename (spec §5: "in the Rename… menu's company"). The row's Cancel help sentence ("Nothing it has translated is written…") is now false for a pipeline round — earlier legs' writes STAND (spec §5) — so replace it with `DepartmentRunState.cancelHelp` = "Stop this round after the leg that is running. What earlier legs wrote stays; nothing later starts." (add the static; pin it in `DepartmentRunTests`).

- [ ] **Step 4: Implement the host**

- `run(language:)`: after the pre-flight and the cast gate, `pipeline.run(docId: docId, language: language)`; when `pipeline == nil`, `notice = Self.noTranslatorWired` (the sentence already covers it). `confirmCast`'s `.nameForRun` arm runs `pipeline?.run` the same way.
- `runBook(language:)`:
  ```swift
    private func runBook(language: String) {
        notice = nil
        guard let pipeline else { notice = Self.noTranslatorWired; return }
        let session = DepartmentRunSession.read(
            runState: translator?.runState ?? .idle, isRunning: translator?.isRunning ?? false,
            pipeline: pipeline.status)
        if case .busy(let busyLanguage) = session {
            notice = DepartmentRunState.busyReason(language: busyLanguage); return
        }
        guard (try? TranslationWritePipeline.validate(language: language)) != nil else {
            notice = DepartmentRunState.unusableTag(language: language); return
        }
        let documents = bookDocumentIds
        guard !documents.isEmpty else { notice = DepartmentRunState.nothingInTheBook; return }
        if Self.needsTranslatorName(language: language, in: store.manifest) {
            castPrompt = DepartmentCastPrompt(ask: Self.bookAsk(language: language, documentIds: documents))
            return
        }
        pipeline.runBook(documentIds: documents, language: language)
    }
  ```
  where `bookDocumentIds` is a `@State` the `derive()` pass fills with `Self.scopedDocumentIds(manuscript, imprint: picked, in: config)` (the same call the walk already makes — keep the value, don't recompute).
- `DepartmentCastPrompt.Ask.nameForBookRun(language:documentIds:)`: add the case; the compiler names every `switch` to extend (`DepartmentCastSheet.swift`'s id/headline/title arms mirror `.nameForRun`'s words; `confirmCast` runs `pipeline?.runBook`; `cancelCast` uses `DepartmentCastCopy.cancelledLine(language:)`).
- `derive()`: after the language walk, per row read `TranslationRoundStore(projectURL:)` — `latest(language:docId: nil)` and `trend(language:)` — and `TranslationPreflight.budget(documentIds: bookDocumentIds, language:, store:, documentStore:, projectURL:)` into three `@State` dictionaries keyed by language (`latestRounds`, `trends`, `bookBudgets`). A separate `.task(id: runTarget.docId)` computes `chapterBudgets[language]` for the open chapter alone (one document, every language row) — NOT in `derive()`, whose key must not carry the subject (a tree click would re-walk the book).
- `runStates(for:)` passes `pipeline?.status ?? .idle`, `latestRounds[row.language]`, `trends[…] ?? []`, `chapterBudgets[…]`, `bookBudgets[…]`, `bookDocumentIds.count` into `resolve`.
- Subscribe: `.onProjectEvent(.maughamTranslationRoundEnded, url: projectURL, window: window) { _ in refreshes += 1 }` beside the three existing subscriptions.
- `desk` passes `runBook: { runBook(language: $0) }` and `showRound: { language in if let round = latestRounds[language] { onShowRound(round) } }`.
- `ProjectWindow`: in `pipeline.configure(... onRoundEnded:)` keep the log line and add `MaughamEvent.postTranslationRoundEnded(projectURL: url, round: round)`; thread `onShowTranslationRound` through `DetailPaneToggle` to the host exactly as `onShowDesignProposal` is threaded (property, init parameter, the desk mount).

- [ ] **Step 5: Run the task's suites, the censuses, then the fast loop**

Run: `xcodebuild … -only-testing:MaughamTests/DepartmentRunTests -only-testing:MaughamTests/DepartmentPaneTests -only-testing:MaughamTests/TranslationPipelineTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests 2>&1 | grep -E "passed|failed|error:" | tail`; then `./scripts/test.sh`.
Expected: green. Then a Release build (`ProjectWindow.body` changed).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Views/Publish/DepartmentPane.swift Maugham/Views/Publish/DepartmentPaneHost.swift Maugham/Views/Publish/DepartmentCastSheet.swift Maugham/Views/DetailPaneToggle.swift Maugham/Views/ProjectWindow.swift MaughamTests/
git commit -m "feat(translation-pipeline): the desk runs the pipeline — Run, Run Whole Book, Cancel, Show, leg/round/trend lines"
```

---

### Task 3: The round report — `PublishCentre.translationRound`, the pure report, the surface, Show and Back

**Files:**
- Create: `Maugham/Views/Publish/TranslationRoundReport.swift`, `Maugham/Views/Publish/TranslationRoundReportView.swift`, `Maugham/Views/Publish/TranslationRoundReportHost.swift`, `Maugham/Views/Publish/TranslationRoundActions.swift`, `Maugham/Views/Publish/DepartureRow.swift`, `Maugham/Views/Publish/RoundRuleSheet.swift`
- Modify: `Maugham/Views/Publish/PublishPreviewCentre.swift` (`PublishCentre` ~line 18; `PublishPreviewModifier` ~line 392–405: a `selectedRound` binding cleared on persona change)
- Modify: `Maugham/Views/ProjectWindow.swift` (`publishCentre` ~line 1593; the switch ~2095; `PublishPreviewModifier` call ~655)
- Modify: `Maugham/Views/TranslationReviewPane.swift` (drop `private` from `TranslationQueryReplySheet` so the report reuses it); `Maugham/Views/TranslatorsNote.swift` (`TranslatorsNoteSheet` gains `seed: String = ""` and `defaultHome: TranslatorsNote.Home = .everyEdition`)
- Test: create `MaughamTests/TranslationRoundReportTests.swift`; modify `MaughamTests/DesignGateTests.swift` (routing), `MaughamTests/PublishPreviewCentreTests.swift` (the exhaustive switch ~line 1995)

**Interfaces:**
- Consumes: `TranslationRound` and its records; `TranslationRound.disagreements` (Task 1); `publishSelectedRound` (Task 2); `TranslatorsNoteSheet`, `QueryRulingSheet`, `QueryRuling.offersARuling`, `TranslationQueryReplySheet`; `TranslationReviewPaneLogic.openQueries(_:language:)`; `currentParagraphState`; `withAnnotationDocument`; `TreeWalk.find(id:in:)`; `MaughamEvent.postDetailSegment(.annotations)`.
- Produces:
  - `PublishCentre.translationRound(TranslationRound)`; `ProjectWindow.publishCentre(persona:subject:structure:preview:proposal:round:)` with `round: TranslationRound? = nil` — **a round outranks a proposal**, both outrank the book; both still nil over a chapter subject.
  - `TranslationRoundReport` (pure `enum`): `struct DepartureRow: Identifiable, Equatable { id, paragraphId, source: String?, gloss, note, verdict: String, kind: String, outcomeLine: String?, before: String?, after: String?, isDismissed: Bool }`, `static func departureRows(_ round: TranslationRound, sources: [String: String]) -> [DepartureRow]`; `struct DisagreementRow: Identifiable, Equatable { id, paragraphId, text, reason, noteAuthor: String, translatorName: String, annotationId: String?, rightVerbTitle: String /* "Reader's right" | "Collator's right" */ }`, `static func disagreementRows(_ round:, translatorName: String, collatorName: String) -> [DisagreementRow]`; `struct ProposalRow: Identifiable { id: Int, term, rendering, reason, adopted: Bool, skipped: Bool }`, `static func proposalRows(_:) -> [ProposalRow]`; `static func header(_ round:, chapterTitle: String?) -> String` ("Round 3 · Chapter 2 · Spanish"); `static func readerColumn(_ record: TranslationRound.ReaderReportRecord?, leg: TranslationRound.Leg) -> (title: String, verdict: String, text: String)`; `static func countsLine(_:) -> String`; `static func provenance(round: TranslationRound, verb: String) -> String` (`"round 3, keep mine"`); `static func outcomeLine(_ outcome: TranslationRound.DepartureOutcome?) -> String?`; every heading/verb/label as a static (`readerHeading`, `changedHeading`, `disagreementsHeading`, `questionsHeading`, `proposalsHeading`, `summaryHeading`, `fineTitle`, `keepMineTitle`, `makeRuleTitle`, `translatorsRightTitle`, `readersRightTitle`, `collatorsRightTitle`, `adoptTitle`, `skipTitle`, `answerTitle`, `answerAsRulingTitle`, `openQueueTitle`, `closeTitle = "Back to the book"`, `closeAccessibilityLabel`, `revealAccessibilityLabel(paragraphId:)`, `dismissedLine`, `nothingChangedLine`, `noDisagreementsLine`, `noQuestionsLine`, `noProposalsLine`, plus per-row accessibility labels `fineLabel(id:)` etc. — every button on the surface carries a label that names its row, `DesignGate.Verb.accessibilityLabel`'s reason).
  - `TranslationRoundActions`:
    ```swift
    struct TranslationRoundActions {
        enum Outcome: Equatable { case done(TranslationRound?, String); case refused(String) }
        var dismiss: (TranslationRound, String) async -> Outcome = { _, _ in .refused(TranslationRoundReport.notWired) }
        var keepMine: (TranslationRound, String, String, TranslatorsNote.Home) async -> Outcome = …   // round, paragraphId, instruction, home
        var makeRule: (TranslationRound, String) async -> Outcome = …                              // round, text
        var translatorsRight: (TranslationRound, String) async -> Outcome = …                      // round, annotationId
        var readersRight: (TranslationRound, String, String, String) async -> Outcome = …          // round, annotationId, paragraphId, noteText
        var adopt: (TranslationRound, Int) async -> Outcome = …
        var skip: (TranslationRound, Int) async -> Outcome = …
        var answer: (TranslationRound, Annotation, String) async -> Outcome = …
        var answerAsRuling: (TranslationRound, Annotation, String) async -> Outcome = …
    }
    ```
    (`.done(nil, sentence)` = the record did not change; `.done(updated, sentence)` = write it back through `onRoundChanged`.) Production wiring is Task 4.
  - `TranslationRoundReportView(round:chapterTitle:sources:queries:translatorName:collatorName:actions:onClose:onRoundChanged:onReveal:)` — `onReveal: (String) -> Void` takes a paragraph id (Task 5 wires it); `@State notice`, `working`, `expanded: Set<String>`, sheets.
  - `TranslationRoundReportHost(round:store:documentStore:projectURL:actions:onClose:onRoundChanged:onReveal:)` — `.task(id: "\(round.language)#\(round.number)")` resolves `sources` (`currentParagraphState` → `MarkdownDisplayFilter.stripAnchors` on each paragraph the record names), `chapterTitle`, `translatorName`/`collatorName` (`EditionStatus.translatorName/collatorName(for:in:)`), and `queries` (`withAnnotationDocument` → `document.annotations(filter: AnnotationFilter(kinds: [.query], statuses: [.open]))` → `TranslationReviewPaneLogic.openQueries(_, language:)` → `createdAt >= round.startedAt && createdAt <= (round.endedAt ?? .distantFuture)`).
  - `DepartureRowView(row: TranslationRoundReport.DepartureRow, onFine:onKeepMine:onMakeRule:onReveal:onToggleExpanded:isExpanded:)` — shared with Task 6.
  - `RoundRuleSheet(seed: String, language: String, onCommit: (String) -> Void, onCancel: () -> Void)` — headline "Make it a rule", the sentence prefilled, Cancel + default action; Escape cancels (`TranslatorsNoteSheet`'s shape).
  - `ProjectWindow.publishSelection(after updated: TranslationRound, showing current: TranslationRound?) -> TranslationRound?` — same-round-only write-back (`(language, number)` equality), the design gate's rule.

- [ ] **Step 1: Write the failing pure tests**

`MaughamTests/TranslationRoundReportTests.swift`:

```swift
import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

final class TranslationRoundReportTests: XCTestCase {

    static func round() -> TranslationRound {
        var round = TranslationRound(number: 3, language: "es", docId: "doc-1",
                                     startedAt: Date(timeIntervalSince1970: 1_000))
        round.endedAt = Date(timeIntervalSince1970: 2_000)
        round.legs = TranslationRound.Leg.allCases.map { .init(leg: $0, status: .ran, counts: .init()) }
        round.leg2 = .init(verdict: "reads_as_translated", text: "Stiff in places.")
        round.leg4 = .init(verdict: "reads_as_native", text: "Better now.")
        round.collatorOverall = "Holds together."
        round.notes = [
            .init(id: "n1", leg: .read, author: "Ocampo", paragraphId: "a1b2", kind: "rhythm",
                  severity: "minor", text: "Limps.", outcome: .addressed(.init(
                    beforeRecordId: "b", before: "Llegó la niebla.", afterRecordId: "a", after: "La niebla llegó."))),
            .init(id: "n2", leg: .reread, author: "Ocampo", paragraphId: "c3d4", kind: "register",
                  severity: "major", text: "Too formal.", outcome: .declined(reason: "The brief asks for it.", annotationId: "ann-2"))
        ]
        round.departures = [
            .init(id: "d1", paragraphId: "a1b2", verdict: "drifted", kind: "omission", note: "Lost a clause.",
                  gloss: "The fog came.", outcome: .addressed(.init(beforeRecordId: "b", before: "x", afterRecordId: "a", after: "y"))),
            .init(id: "d2", paragraphId: "c3d4", verdict: "holds", kind: "rendering", note: "Split.",
                  gloss: "She shut it. Then left.", outcome: nil),
            .init(id: "d3", paragraphId: "e5f6", verdict: "drifted", kind: "addition", note: "Added.",
                  gloss: "He smiled warmly.", outcome: .declined(reason: "Needed for rhythm.", annotationId: nil))
        ]
        round.summary = "Two repairs, one stand."
        round.glossaryProposals = [.init(term: "fog", rendering: "niebla", reason: "consistency", adopted: false)]
        return round
    }

    func test_departureRowsCarryTheSourceTheGlossAndWhatTheTranslatorDid() {
        let rows = TranslationRoundReport.departureRows(Self.round(), sources: ["a1b2": "The fog came in."])
        XCTAssertEqual(rows.map(\.id), ["d1", "d2", "d3"])
        XCTAssertEqual(rows[0].source, "The fog came in.")
        XCTAssertNil(rows[1].source, "a paragraph the document no longer has draws no source")
        XCTAssertEqual(rows[0].gloss, "The fog came.")
        XCTAssertEqual(rows[0].outcomeLine, TranslationRoundReport.outcomeLine(.addressed(.init(
            beforeRecordId: "b", before: "x", afterRecordId: "a", after: "y"))))
        XCTAssertTrue(rows[0].outcomeLine?.lowercased().contains("rewrote") == true)
        XCTAssertNil(rows[1].outcomeLine, "a holds departure was never work for the translator")
        XCTAssertTrue(rows[2].outcomeLine?.contains("Needed for rhythm.") == true)
        XCTAssertFalse(rows[0].isDismissed)
    }

    func test_disagreementRowsAreTheDeclinedNotesAndDeparturesWithBothBylines() {
        let rows = TranslationRoundReport.disagreementRows(Self.round(), translatorName: "Cortázar", collatorName: "Borges")
        XCTAssertEqual(rows.map(\.id), ["n2", "d3"])
        XCTAssertEqual(rows[0].noteAuthor, "Ocampo")
        XCTAssertEqual(rows[0].rightVerbTitle, TranslationRoundReport.readersRightTitle)
        XCTAssertEqual(rows[1].noteAuthor, "Borges")
        XCTAssertEqual(rows[1].rightVerbTitle, TranslationRoundReport.collatorsRightTitle)
        XCTAssertEqual(rows[0].translatorName, "Cortázar")
        XCTAssertEqual(rows[0].annotationId, "ann-2")
        XCTAssertNil(rows[1].annotationId)
    }

    func test_theHeaderNamesTheRoundTheChapterAndTheEdition() {
        XCTAssertEqual(TranslationRoundReport.header(Self.round(), chapterTitle: "Chapter 1"),
                       "Round 3 \u{00b7} Chapter 1 \u{00b7} "
                       + TranslationReviewIndicator.displayLabel(forLanguageTag: "es"))
        XCTAssertTrue(TranslationRoundReport.header(Self.round(), chapterTitle: nil).contains("Round 3"))
    }

    func test_theCountsLineAndTheProvenance() {
        let line = TranslationRoundReport.countsLine(Self.round())
        XCTAssertTrue(line.contains("2 notes"), line)
        XCTAssertTrue(line.contains("3 departures"), line)
        XCTAssertTrue(line.contains("2 declined"), line)
        XCTAssertEqual(TranslationRoundReport.provenance(round: Self.round(), verb: "keep mine"), "round 3, keep mine")
    }

    /// **Nothing on the surface is target-language-only** (spec §8, §12): what
    /// draws by default is the record's author-language fields and the source;
    /// the translation's own text appears only inside a row the writer expands.
    func test_theCollapsedSurfaceNeverDrawsTheTranslationItself() async throws {
        let round = Self.round()
        let window = mount(round: round)
        let texts = try axTexts(in: window)
        for translated in ["Llegó la niebla.", "La niebla llegó."] {
            XCTAssertFalse(texts.contains { $0.contains(translated) }, "\(translated) drawn collapsed")
        }
        XCTAssertTrue(texts.contains { $0.contains("The fog came.") }, "the gloss is what the author judges by")
        XCTAssertTrue(texts.contains { $0.contains("Stiff in places.") })
        XCTAssertTrue(texts.contains { $0.contains("Better now.") })
        XCTAssertTrue(texts.contains { $0.contains("Two repairs, one stand.") })
    }

    /// The six sections, in the spec's order, each by its heading.
    func test_theSixSectionsAreDrawnInOrder() async throws {
        let window = mount(round: Self.round())
        let texts = try axTexts(in: window)
        let headings = [TranslationRoundReport.readerHeading, TranslationRoundReport.changedHeading,
                        TranslationRoundReport.disagreementsHeading, TranslationRoundReport.questionsHeading,
                        TranslationRoundReport.proposalsHeading, TranslationRoundReport.summaryHeading]
        let positions = headings.map { heading in texts.firstIndex { $0 == heading } }
        XCTAssertEqual(positions.compactMap { $0 }.count, 6, "\(texts)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
    }

    /// Every verb reaches the action it names with the row's own ids.
    func test_theVerbsReachTheActionsWithTheirRowsIds() async throws {
        var dismissed: [String] = []
        var rights: [String] = []
        var adopted: [Int] = []
        var actions = TranslationRoundActions()
        actions.dismiss = { _, id in dismissed.append(id); return .done(nil, "ok") }
        actions.translatorsRight = { _, id in rights.append(id); return .done(nil, "ok") }
        actions.adopt = { _, i in adopted.append(i); return .done(nil, "ok") }
        let window = mount(round: Self.round(), actions: actions)
        press(try axButtons(labelled: TranslationRoundReport.fineLabel(id: "d2"), in: window)[0])
        press(try axButtons(labelled: TranslationRoundReport.translatorsRightLabel(id: "n2"), in: window)[0])
        press(try axButtons(labelled: TranslationRoundReport.adoptLabel(index: 0), in: window)[0])
        _ = await pumpUntil(deadline: 3) { dismissed.count == 1 && rights.count == 1 && adopted.count == 1 }
        XCTAssertEqual(dismissed, ["d2"])
        XCTAssertEqual(rights, ["ann-2"])
        XCTAssertEqual(adopted, [0])
    }

    /// A disagreement whose query was never minted offers no Translator's right
    /// — there is nothing to reject — and says so.
    func test_aDisagreementWithNoQueryOffersNoTranslatorsRight() async throws {
        let window = mount(round: Self.round())
        XCTAssertEqual(try axButtons(labelled: TranslationRoundReport.translatorsRightLabel(id: "d3"), in: window).count, 0)
        XCTAssertTrue(try axTexts(in: window).contains { $0.contains(TranslationRoundReport.noQueryForThisNote) })
    }

    /// A refused verb lands in the report's one notice slot, in its own words.
    func test_aRefusalIsSaidInTheReportsNoticeSlot() async throws {
        var actions = TranslationRoundActions()
        actions.dismiss = { _, _ in .refused("The ledger is read-only today.") }
        let window = mount(round: Self.round(), actions: actions)
        press(try axButtons(labelled: TranslationRoundReport.fineLabel(id: "d2"), in: window)[0])
        let shown = await pumpUntil(deadline: 3) {
            (try? self.axTexts(in: window).contains { $0.contains("read-only today") }) == true
        }
        XCTAssertTrue(shown)
    }

    /// A verb's updated record is written back to the window only when it is
    /// still the round on screen — `publishSelection`'s rule for the gate.
    func test_theWriteBackOnlyLandsOnTheRoundStillOnScreen() {
        var updated = Self.round()
        updated.departures[1].outcome = .dismissed
        var other = Self.round()
        other = TranslationRound(number: 4, language: "es", docId: "doc-1", startedAt: Date())
        XCTAssertEqual(ProjectWindow.publishSelection(after: updated, showing: Self.round()), updated)
        XCTAssertEqual(ProjectWindow.publishSelection(after: updated, showing: other), other)
        XCTAssertNil(ProjectWindow.publishSelection(after: updated, showing: nil))
    }

    // MARK: - Fixture

    private var windows: [NSWindow] = []
    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    private func mount(round: TranslationRound,
                       actions: TranslationRoundActions = TranslationRoundActions()) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(TranslationRoundReportView(
                round: round, chapterTitle: "Chapter 1",
                sources: ["a1b2": "The fog came in.", "c3d4": "She closed the door."],
                queries: [], translatorName: "Cortázar", collatorName: "Borges",
                actions: actions, onClose: {}, onRoundChanged: { _ in }, onReveal: { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 900, height: 900))
        windows.append(window)
        pump(0.2)
        return window
    }
}
```

In `DesignGateTests`, beside `test_aSelectedProposalTakesTheCentreAheadOfTheBook`, add:

```swift
    func test_aSelectedRoundTakesTheCentreAheadOfTheProposalAndTheBook() {
        let round = TranslationRound(number: 1, language: "es", docId: "doc-1", startedAt: Date())
        XCTAssertEqual(
            ProjectWindow.publishCentre(
                persona: .publish, subject: nil, structure: ProjectAltitudeCentreTests.structure,
                preview: .ready(newestFirst: [PublishPreviewCentreTests.aBook]),
                proposal: Self.proposal(), round: round),
            .translationRound(round))
        XCTAssertNil(ProjectWindow.publishCentre(
            persona: .publish, subject: .item("chapter-1"), structure: ProjectAltitudeCentreTests.structure,
            preview: .nothingCompiled, proposal: nil, round: round),
            "a chapter in Publish is the editor, round or no round")
        XCTAssertNil(ProjectWindow.publishCentre(
            persona: .author, subject: nil, structure: ProjectAltitudeCentreTests.structure,
            preview: .nothingCompiled, proposal: nil, round: round),
            "the report is Publish's")
    }
```

- [ ] **Step 2: Run to verify failure** — `-only-testing:MaughamTests/TranslationRoundReportTests -only-testing:MaughamTests/DesignGateTests`; expected: build failure (`TranslationRoundReport`, `.translationRound`, `round:`).

- [ ] **Step 3: Implement the pure report and the arm**

`PublishCentre`: add `case translationRound(TranslationRound)` with a doc comment in the `.designProposal` case's style (outranks both, no state of its own, the round travels whole because the desk just read it). `ProjectWindow.publishCentre`: add `round: TranslationRound? = nil` after `proposal`; `if let round { return .translationRound(round) }` BEFORE the proposal line. `PublishPreviewModifier`: `@Binding var selectedRound: TranslationRound?`, `selectedRound = nil` beside `selectedProposal = nil` in `.onChange(of: persona)`; ProjectWindow passes `selectedRound: $publishSelectedRound`. The switch in `manuscriptEditor` gains:

```swift
            case .translationRound(let round):
                TranslationRoundReportHost(
                    round: round, store: store, documentStore: documentStore, projectURL: store.url,
                    actions: TranslationRoundActions(),           // Task 4 replaces with .production(…)
                    onClose: { publishSelectedRound = nil },
                    onRoundChanged: { updated in
                        publishSelectedRound = Self.publishSelection(after: updated, showing: publishSelectedRound)
                    },
                    onReveal: { _ in })                          // Task 5 wires the click-through
```

`PublishPreviewCentreTests`' exhaustive switch (~line 1995) gains the arm. `publishSelection(after:showing:)` overload for rounds: `current.map { $0.language == updated.language && $0.number == updated.number } == true ? updated : current`.

`TranslationRoundReport.swift`: the pure rows/copy per the Interfaces block. `outcomeLine`: `.addressed` → "Cortázar rewrote the paragraph" (the name is passed in by the view; the static takes `translatorName:`), `.declined(reason, _)` → "\(translatorName) declined: \(reason)", `.dismissed` → `dismissedLine` ("You said this was fine."), `nil` on a `holds` → nil, `nil` on a `drifted` → "The fix leg never reached this paragraph." (`unreachedLine`). `notWired` = "This window isn't ready to act on a round yet." `noQueryForThisNote` = "No query was minted for this note, so there is nothing to reject — Reader's right and Make it a rule still apply."

`TranslationRoundReportView`: `VStack { header (title + Back button, `DesignGateView.header`'s shape: `closeTitle`/`closeAccessibilityLabel`) ; Divider ; ScrollView { the six sections } }`, opaque full-frame background (`Color(nsColor: .windowBackgroundColor)`), `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`. Sections:
1. Reader's report — two columns (`HStack`), each `readerColumn(...)`: "First read" / "Second read", verdict humanised (`reads_as_native` → "Reads as native", etc. — a static `verdictLabel(_:)`), the text; a missing leg-4 column says `nothingChangedLine` ("The second read was skipped — nothing changed after the first.") when `legs` records leg 4 skipped, else "—".
2. Where your prose was changed — `ForEach(departureRows)` → `DepartureRowView`; an addressed row's disclosure (`Button(.plain)`, tripwire 9) expands to before/after; a dismissed row draws `dismissedLine` and no verbs. Verbs: Fine (`actions.dismiss(round, row.id)`), Keep mine (opens `TranslatorsNoteSheet(target: Target(docId: round.docId, paragraphId:, excerpt: row.source ?? row.gloss, editions: [round.language]), seed: row.note, defaultHome: .edition(round.language))` → `actions.keepMine`), Make it a rule (`RoundRuleSheet(seed: row.note, language:)` → `actions.makeRule`). Each row's source line is a `Button(.plain)` labelled `revealAccessibilityLabel(paragraphId:)` calling `onReveal(paragraphId)`.
3. Disagreements — `ForEach(disagreementRows)`: the note, "\(noteAuthor):" byline, "\(translatorName) declined: \(reason)"; verbs Translator's right (only when `annotationId != nil`, else `noQueryForThisNote` text), `rightVerbTitle` (`actions.readersRight(round, annotationId ?? "", paragraphId, text)` — when `annotationId` is nil the action still mints the directive; pass `""`), Make it a rule. Source line click-through as in §2.
4. Questions for you — `ForEach(queries)`: the body, Answer (→ `TranslationQueryReplySheet` → `actions.answer`), Answer as ruling… (only when `QueryRuling.offersARuling(ann)`; `QueryRulingSheet` → `actions.answerAsRuling`). Empty: `noQuestionsLine`.
5. Glossary proposals — `ForEach(proposalRows)`: "«term» → «rendering»" + reason; Adopt / Skip; an adopted row reads "Adopted", a skipped row "Skipped", no verbs.
6. Summary — `round.summary ?? "—"`, `countsLine`, a button `openQueueTitle` → `MaughamEvent.postDetailSegment(.annotations)`.
`notice` under the header (the surface's ONE transient channel); `working` disables every verb while an action is out; every `Outcome.done(updated, sentence)` → `onRoundChanged(updated)` when non-nil, `notice = sentence`; `.refused(sentence)` → `notice = sentence`.

`TranslationRoundReportHost`: `@State sources`, `chapterTitle`, `queries`, `translatorName`, `collatorName`; the `.task` per the Interfaces block; re-run on `.onProjectEvent(.maughamAnnotationsChanged, url:, window:)` (an answered query leaves §4). `documentStore` is `DocumentStore?` — pass `store.documentStore`.

`DepartureRowView` and `RoundRuleSheet` per the Interfaces block. `TranslatorsNoteSheet`: add `seed`/`defaultHome` (defaulted, so the P2 call site is unchanged) and initialise its `@State`s from them via an explicit `init`.

- [ ] **Step 4: Run the suites, censuses, fast loop, Release build**

`-only-testing:MaughamTests/TranslationRoundReportTests -only-testing:MaughamTests/DesignGateTests -only-testing:MaughamTests/PublishPreviewCentreTests -only-testing:MaughamTests/TranslatorsNoteTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests`; `./scripts/test.sh`; the Release build. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/Publish/ Maugham/Views/ProjectWindow.swift Maugham/Views/TranslationReviewPane.swift Maugham/Views/TranslatorsNote.swift MaughamTests/
git commit -m "feat(translation-pipeline): the round report — PublishCentre.translationRound, six sections, verbs as closures"
```

---

### Task 4: The verbs' production wiring — `TranslationRoundActions.production`

**Files:**
- Modify: `Maugham/Views/Publish/TranslationRoundActions.swift` (add the `production` factory), `Maugham/Views/ProjectWindow.swift` (the arm passes `translationRoundActions()`; `declaredWorld` is the window's `DeclaredWorldStore` — find how `designGateActions(projectURL:)` and `TranslatorsNote.commit`'s `world:` are sourced and pass the same)
- Test: create `MaughamTests/TranslationRoundActionsTests.swift`

**Interfaces:**
- Consumes: `RulingPerformer.rule`, `Ruling.directiveText`/`glossaryText`/`Provenance.glossary`, `TranslatorsNote.destination(home:docId:)`, `Document.rejectAnnotation(id:userResponse:undoManager:)`/`acceptAnnotation(id:userResponse:undoManager:)`, `withAnnotationDocument`, `QueryRuling.commit(_:answering:in:store:undoManager:)`, `TranslationRoundStore.update` (Task 1), `TranslationRoundReport.provenance(round:verb:)` (Task 3), `RulingsSection.parse` (to read back in tests), the on-disk project fixture idiom of `TranslationPipelineEnvironmentTests.makeHarness` (copy it — it is `private` there).
- Produces: `TranslationRoundActions.production(store: ProjectStore, documentStore: DocumentStore?, projectURL: URL, world: DeclaredWorldStore?) -> TranslationRoundActions` (`@MainActor`; every capture weak; a deallocated store answers `.refused(TranslationRoundReport.notWired)`).

- [ ] **Step 1: Write the failing tests**

`MaughamTests/TranslationRoundActionsTests.swift` — build the harness as `TranslationPipelineEnvironmentTests.makeHarness` does (a three-paragraph chapter, open in a `DocumentStore`, a publish config), then one test per verb:

```swift
    func test_fineRecordsDismissedOnTheRoundAndTouchesNoAnnotation() async throws {
        let h = try await makeHarness()
        var round = roundFor(h, number: 1)
        round.departures = [.init(id: "d1", paragraphId: h.doc.sequence[0], verdict: "holds",
                                  kind: "rendering", note: "Split.", gloss: "g")]
        try TranslationRoundStore(projectURL: h.projectURL).append(round)
        let actions = TranslationRoundActions.production(
            store: h.store, documentStore: h.documentStore, projectURL: h.projectURL, world: nil)
        guard case .done(let updated?, _) = await actions.dismiss(round, "d1") else { return XCTFail() }
        XCTAssertEqual(updated.departures[0].outcome, .dismissed)
        XCTAssertEqual(TranslationRoundStore(projectURL: h.projectURL).latest(language: "es", docId: nil)?
                           .departures[0].outcome, .dismissed)
        XCTAssertTrue(h.doc.annotations(filter: AnnotationFilter()).isEmpty)
    }

    func test_keepMineMintsADirectiveInTheChosenHomeWithTheRoundsProvenance() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 2)
        let pid = h.doc.sequence[1]
        let actions = TranslationRoundActions.production(store: h.store, documentStore: h.documentStore,
                                                         projectURL: h.projectURL, world: nil)
        guard case .done = await actions.keepMine(round, pid, "keep the repetition", .edition("es")) else { return XCTFail() }
        let brief = try XCTUnwrap(h.store.statementText(of: try XCTUnwrap(h.store.statement(kind: .editionBrief("es"), scope: .project))))
        let rulings = RulingsSection.parse(brief).rulings
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].directive?.paragraphId, pid)
        XCTAssertEqual(rulings[0].directive?.text, "keep the repetition")
        XCTAssertEqual(rulings[0].provenance, TranslationRoundReport.provenance(round: round, verb: "keep mine"))

        guard case .done = await actions.keepMine(round, pid, "one sentence", .everyEdition) else { return XCTFail() }
        let intent = try XCTUnwrap(h.store.statement(kind: .intent, scope: .document(h.doc.docId)))
        XCTAssertEqual(RulingsSection.parse(try XCTUnwrap(h.store.statementText(of: intent))).rulings.first?.directive?.text, "one sentence")
    }

    func test_makeItARuleLandsAGeneralRulingInTheEditionBrief() async throws { … provenance "round N, make it a rule"; no `¶` prefix … }

    func test_translatorsRightRejectsTheDeclinedQuery() async throws {
        // mint a .query on the doc as the pipeline's declined mint would (document.addAnnotation(kind: .query, paragraphId:, body:, toolArgs: TranslatorOrchestrator.Environment.queryToolArgs(language: "es", roleId: "r"), author: .init(sourceKind: .claude, displayName: "Ocampo"), announcing: false))
        // actions.translatorsRight(round, annId) → the annotation's status is .rejected
    }

    func test_readersRightAcceptsTheQueryAndMintsADirectiveQuotingTheNote() async throws {
        // status .accepted with a userResponse naming the verb; the brief holds `¶<pid>: <noteText>` with provenance "round N, reader's right"
        // and with annotationId "" the directive still lands and the outcome is .done
    }

    func test_adoptMintsOneGlossaryRulingAndMarksTheProposalAdopted() async throws {
        // glossaryText("fog", "niebla", note: "consistency") in the brief with provenance Ruling.Provenance.glossary; updated.glossaryProposals[0].adopted == true; the store agrees
        // an empty term is refused in words and mints nothing (P1's carry-forward)
    }

    func test_skipMarksTheProposalSkippedAndWritesNothingElse() async throws { … }

    func test_answerRepliesAndAnswerAsRulingFilesTheRulingFirst() async throws {
        // answer → acceptAnnotation with the reply; answerAsRuling → QueryRuling.commit's two records (assert through QueryRulingTests' own assertions' shape)
    }

    func test_averbOnARoundThatAgedOutIsRefusedInWords() async throws {
        // a round never appended → dismiss answers .refused containing "aged out"
    }
```

- [ ] **Step 2: Run to verify failure** — `-only-testing:MaughamTests/TranslationRoundActionsTests`; expected: `production` does not exist.

- [ ] **Step 3: Implement**

```swift
extension TranslationRoundActions {
    @MainActor
    static func production(store: ProjectStore, documentStore: DocumentStore?,
                           projectURL: URL, world: DeclaredWorldStore?) -> TranslationRoundActions {
        var actions = TranslationRoundActions()
        actions.dismiss = { round, departureId in
            var updated = round
            guard let index = updated.departures.firstIndex(where: { $0.id == departureId }) else {
                return .refused(TranslationRoundReport.rowGone)
            }
            updated.departures[index].outcome = .dismissed
            do { try TranslationRoundStore(projectURL: projectURL).update(updated) } catch {
                return .refused(error.localizedDescription)
            }
            return .done(updated, TranslationRoundReport.dismissedLine)
        }
        actions.keepMine = { [weak store] round, paragraphId, instruction, home in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return .refused(TranslatorsNoteCopy.emptyRefusal) }
            let (kind, scope) = TranslatorsNote.destination(home: home, docId: round.docId)
            do {
                try await RulingPerformer.rule(
                    Ruling.directiveText(paragraphId: paragraphId, words),
                    provenance: TranslationRoundReport.provenance(round: round, verb: "keep mine"),
                    kind: kind, forScope: scope, store: store,
                    world: home == .everyEdition ? world : nil)
            } catch { return .refused(error.localizedDescription) }
            return .done(nil, TranslationRoundReport.keptLine(home: home))
        }
        actions.makeRule = { [weak store] round, text in … RulingPerformer.rule(text, provenance: provenance(round:verb: "make it a rule"), kind: .editionBrief(round.language), forScope: .project, store:, world: nil) … }
        actions.translatorsRight = { [weak store] round, annotationId in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            do {
                try await withAnnotationDocument(store: store, projectURL: projectURL, documentId: round.docId) { document in
                    try await document.rejectAnnotation(id: annotationId, userResponse: TranslationRoundReport.translatorsRightTitle)
                }
            } catch { return .refused(error.localizedDescription) }
            return .done(nil, TranslationRoundReport.translatorsRightLine)
        }
        actions.readersRight = { [weak store] round, annotationId, paragraphId, noteText in
            // directive FIRST (the decision), then the accept (the reply) — QueryRuling's order, for its reason
            … RulingPerformer.rule(Ruling.directiveText(paragraphId: paragraphId, noteText), provenance: provenance(round:verb: "reader's right"), kind: .editionBrief(round.language), forScope: .project, …)
            … if !annotationId.isEmpty { withAnnotationDocument … acceptAnnotation(id:, userResponse: TranslationRoundReport.readersRightTitle) }
        }
        actions.adopt = { [weak store] round, index in
            guard round.glossaryProposals.indices.contains(index) else { return .refused(TranslationRoundReport.rowGone) }
            let proposal = round.glossaryProposals[index]
            guard !proposal.term.trimmingCharacters(in: .whitespaces).isEmpty,
                  !proposal.rendering.trimmingCharacters(in: .whitespaces).isEmpty
            else { return .refused(TranslationRoundReport.emptyGlossaryTerm) }
            … RulingPerformer.rule(Ruling.glossaryText(term:, rendering:, note: proposal.reason), provenance: Ruling.Provenance.glossary, kind: .editionBrief(round.language), forScope: .project, …)
            var updated = round; updated.glossaryProposals[index].adopted = true
            … store.update(updated) …
            return .done(updated, TranslationRoundReport.adoptedLine)
        }
        actions.skip = { round, index in … skipped = true; update; .done(updated, skippedLine) }
        actions.answer = { [weak store] round, annotation, reply in … withAnnotationDocument … acceptAnnotation(id: annotation.id, userResponse: reply, undoManager: nil) … }
        actions.answerAsRuling = { [weak store] round, annotation, answer in
            … withAnnotationDocument { document in await QueryRuling.commit(answer, answering: annotation, in: document, store: store, undoManager: nil) } → nil = .done(nil, QueryRuling.confirmation(language: round.language)); a sentence = .refused(sentence)
        }
        return actions
    }
}
```

Every copy static named here (`rowGone`, `keptLine(home:)`, `translatorsRightLine`, `readersRightLine`, `adoptedLine`, `skippedLine`, `emptyGlossaryTerm`, `ruledLine`) is added to `TranslationRoundReport`. ProjectWindow's arm passes `TranslationRoundActions.production(store: store, documentStore: documentStore, projectURL: store.url, world: <the window's DeclaredWorldStore>)`.

- [ ] **Step 4: Run** — the new suite, `QueryRulingTests`, `RulingPerformerTests`, `TranslatorsNoteTests`, both censuses, then `./scripts/test.sh`; Release build (ProjectWindow changed). Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/Publish/TranslationRoundActions.swift Maugham/Views/Publish/TranslationRoundReport.swift Maugham/Views/ProjectWindow.swift MaughamTests/TranslationRoundActionsTests.swift
git commit -m "feat(translation-pipeline): the round report's verbs act on the right ruling, annotation and record"
```

---

### Task 5: Click-through — a departure or disagreement row reveals its paragraph in Translation Review

**Files:**
- Create: `Maugham/Views/TranslationReveal.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (`TranslationReviewModifier` ~line 4570: a `selectedSubject` binding, the new command, the pending reveal; the modifier's call site ~line 621; the report arm's `onReveal`)
- Test: create `MaughamTests/TranslationRevealTests.swift`

**Interfaces:**
- Consumes: `.maughamRevealTranslation` (Task 1), `.maughamEnterTranslationReview` (payload `"language"`), `.maughamNavigateToParagraph` (payload `"paragraph_id"`), `BinderSubject.item(_:)`, `DocumentStore.document(forDocId:)`.
- Produces:
  ```swift
  struct TranslationReveal: Equatable {
      let docId: String
      let language: String
      let paragraphId: String
      enum Step: Equatable { case now; case afterSelecting(BinderSubject) }
      static func plan(_ reveal: TranslationReveal, activeDocId: String) -> Step
      static func post(_ reveal: TranslationReveal)          // .maughamRevealTranslation to .keyWindow
      static func decode(_ userInfo: [AnyHashable: Any]?) -> TranslationReveal?
      /// The two posts, in order: enter review for the language, then navigate.
      static func perform(_ reveal: TranslationReveal, post: (Notification.Name, [String: Any]) -> Void)
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
final class TranslationRevealTests: XCTestCase {
    let reveal = TranslationReveal(docId: "doc-2", language: "es", paragraphId: "a1b2")

    func test_aRevealOnTheOpenChapterIsNowAndOnAnotherIsAfterSelectingIt() {
        XCTAssertEqual(TranslationReveal.plan(reveal, activeDocId: "doc-2"), .now)
        XCTAssertEqual(TranslationReveal.plan(reveal, activeDocId: "doc-1"), .afterSelecting(.item("doc-2")))
        XCTAssertEqual(TranslationReveal.plan(reveal, activeDocId: BinderSubject.noDocumentSubject),
                       .afterSelecting(.item("doc-2")))
    }

    func test_theRevealRoundTripsThroughItsPayload() {
        var received: Notification?
        let token = NotificationCenter.default.addObserver(forName: .maughamRevealTranslation, object: nil, queue: nil) { received = $0 }
        defer { NotificationCenter.default.removeObserver(token) }
        TranslationReveal.post(reveal)
        XCTAssertEqual(TranslationReveal.decode(received?.userInfo), reveal)
        XCTAssertNil(TranslationReveal.decode(["language": "es"]))
    }

    func test_performEntersReviewForTheLanguageThenNavigatesToTheParagraph() {
        var posts: [(Notification.Name, [String: Any])] = []
        TranslationReveal.perform(reveal) { posts.append(($0, $1)) }
        XCTAssertEqual(posts.map(\.0), [.maughamEnterTranslationReview, .maughamNavigateToParagraph])
        XCTAssertEqual(posts[0].1["language"] as? String, "es")
        XCTAssertEqual(posts[1].1["paragraph_id"] as? String, "a1b2")
    }
}
```

Plus a grep pin in `TripwireGrepTests` (this file's own style: read the source, assert a token) that `ProjectWindow.swift`'s `TranslationReviewModifier` handles `.maughamRevealTranslation` AND that the report arm's `onReveal` calls `TranslationReveal.post` — the two window-side facts nothing mounted can drive headlessly.

- [ ] **Step 2: Run to verify failure** — `-only-testing:MaughamTests/TranslationRevealTests`; expected: build failure.

- [ ] **Step 3: Implement**

`TranslationReveal.swift` per the Interfaces block (`perform` posts `.maughamEnterTranslationReview` with `["language": language]` then `.maughamNavigateToParagraph` with `["paragraph_id": paragraphId]`; production's `post` closure is `{ MaughamEvent.post($0, to: .keyWindow, payload: $1) }`).

`TranslationReviewModifier`: add `@Binding var selectedSubject: BinderSubject?` and `@State private var pendingReveal: TranslationReveal?`; handle the command:

```swift
            .onKeyWindowCommand(.maughamRevealTranslation, window: window) { note in
                guard let reveal = TranslationReveal.decode(note.userInfo) else { return }
                switch TranslationReveal.plan(reveal, activeDocId: activeDocId) {
                case .now:
                    TranslationReveal.perform(reveal) { MaughamEvent.post($0, to: .keyWindow, payload: $1) }
                case .afterSelecting(let subject):
                    pendingReveal = reveal
                    selectedSubject = subject
                }
            }
```

and in the existing `.onChange(of: activeDocId)`: if `pendingReveal?.docId == newValue`, clear `pendingReveal` and — once the document is registered (`documentStore?.document(forDocId:)` non-nil; poll in a `Task` with 50 ms sleeps up to 3 s, the coordinator's own deferral idiom, then give up silently: the chapter is open and in Publish, which is still the honest most of what was asked) — run `perform`; otherwise keep the existing clear-the-language behaviour. The modifier needs `documentStore` — pass it in (the call site has it). `activeDocId` moves on the SAME body pass as `selectedSubject`, so the `.onChange` will see the new id.

The report arm: `onReveal: { pid in TranslationReveal.post(.init(docId: round.docId, language: round.language, paragraphId: pid)) }`.

- [ ] **Step 4: Run** — the new suite, `TripwireGrepTests`, `AnnotationChangeEventTests`, `./scripts/test.sh`, the Release build. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/TranslationReveal.swift Maugham/Views/ProjectWindow.swift MaughamTests/
git commit -m "feat(translation-pipeline): a report row reveals its paragraph in Translation Review"
```

---

### Task 6: Gloss and Ask the collator — two more cold calls, in the Translation pane

**Files:**
- Create: `Maugham/Compiler/GlossBriefing.swift`, `Maugham/Compiler/GlossReport.swift`, `Maugham/Compiler/SpotCheck.swift`
- Modify: `Maugham/Views/TranslationReviewPane.swift` (inputs, `sourceSection` ~line 233, a new `spotCheckSection`), `Maugham/Views/DetailPaneToggle.swift` (`translationPane` ~line 610: pass `coldCall`, `documentStore`, `model`; a `coldCall: ColdCall? = nil` property + init parameter in the `pipeline`'s style), `Maugham/Views/ProjectWindow.swift` (the `DetailPaneToggle` call: `coldCall: coldCall`)
- Test: create `MaughamTests/GlossBriefingTests.swift`, `MaughamTests/SpotCheckTests.swift`; modify `MaughamTests/TripwireGrepTests.swift`

**Interfaces:**
- Consumes: `ColdCall.call(message:preamble:model:)`, `ColdCall.isRunning`, `TranslationPipeline.coldPreamble`, `TranslationPipeline.Environment.collatorBriefing(docId:language:store:documentStore:projectURL:)` and `.authorLanguage(store:documentStore:projectURL:)` (both `static`, internal), `TranslatorOrchestrator.Environment.editionBriefText(language:store:)`, `CollatorBriefing.Inputs`/`compose`, `CollatorReport.parse(_:briefedParagraphIds:)`, `ReportJSON`, `RoundNarrative.failureCopy(_:session: .translation)`, `EditorControl.translationBadges.entries` (`paragraphId`, `text`, `status`), `DepartureRowView` (Task 3), `TranslationRoundReport.DepartureRow`, `TranslatorsNoteSheet`/`RoundRuleSheet`, `RulingPerformer.rule`, `DocumentStore.uiState.compilerModel.claudeModel`.
- Produces:
  ```swift
  enum GlossBriefing {
      struct Inputs: Equatable {
          let language: String; let authorLanguage: String; let textureLine: String?
          let before: String?; let paragraph: String; let after: String?
      }
      static func compose(inputs: Inputs) -> String
      static let schemaDescription: String        // {"gloss": <literal back-rendering>}
      static func textureLine(in editionBrief: String?) -> String?   // the essay line starting "Texture" (case-insensitive, markdown prefixes stripped), else nil
  }
  enum GlossReport { static func parse(_ raw: String) -> String? }   // ReportJSON.lastObject shaped by ["gloss"], nonEmptyString
  @MainActor enum SpotCheck {
      enum Outcome<T: Equatable>: Equatable { case answered(T); case refused(String) }
      static func neighbours(of paragraphId: String, in entries: [TranslationBadgeLayout.Entry]) -> (before: String?, paragraph: String, after: String?)?
      static func narrow(_ inputs: CollatorBriefing.Inputs, to paragraphId: String) -> CollatorBriefing.Inputs?   // the pair ± one neighbour, everything else kept
      static func gloss(paragraphId:language:entries:store:documentStore:projectURL:coldCall:model:) async -> Outcome<String>
      static func askTheCollator(paragraphId:docId:language:store:documentStore:projectURL:coldCall:model:) async -> Outcome<CollatorReport>
      static let glossTitle = "Gloss", askTitle = "Ask the Collator", glossLabel = "gloss", busyRefusal, notWiredRefusal, noTranslationRefusal
  }
  ```
  `TranslationReviewPane` gains `var coldCall: ColdCall? = nil`, `var documentStore: DocumentStore? = nil`, `var projectURL: URL? = nil`, `var model: String = CompilerOrchestrator.defaultModel`.

- [ ] **Step 1: Write the failing tests**

`GlossBriefingTests`: the composed prompt contains the paragraph, both neighbours when given, the texture line when given, the schema, the author's language in the role frame, and **never** any source text (the `Inputs` type has no field for it — assert by composing and searching for a planted English sentence that was never passed); `textureLine(in:)` finds `**Texture** — fluent Spanish` → "fluent Spanish"-bearing line and answers nil for a brief without one; `GlossReport.parse` accepts `{"gloss":"The fog came."}`, trims, refuses empty and refuses a prose-only answer.

`SpotCheckTests`:
- `neighbours(of:in:)`: middle, first (before nil), last (after nil), unknown id (nil).
- `narrow`: three of five pairs kept in order, directives and glossary intact, `briefedParagraphIds` is the narrowed set; unknown id → nil.
- `gloss(...)` with a `ColdCall` configured with `ColdCallTests`' fake runner factory (read that file's `FakeRunner`; if it is `private`, lift it to an internal `TestSupport` type in this task) answering `{"gloss":"…"}` → `.answered`; a `.failed` event → `.refused(RoundNarrative.failureCopy(...))`; a `ColdCall` already running → `.refused(SpotCheck.busyRefusal)`; the runner's `send` received `TranslationPipeline.coldPreamble` as its preamble and a message containing the paragraph.
- `askTheCollator(...)` over the `TranslationPipelineEnvironmentTests`-style harness with one seeded translation: the message the fake runner received contains the source sentence AND the translation (it is the collator's briefing) and exactly the neighbours; a canned `CollatorReport` JSON naming the paragraph parses; **neither verb writes anything** (statement text unchanged, no annotation, no round appended).
- `TripwireGrepTests`: `SpotCheck.swift` contains `coldCall.call(` and does NOT contain `writeMCPConfig`, `.bridged(`, `RulingPerformer`, `addAnnotation` or `TranslationRoundStore` — spec §12's "neither mints" as a census, with a planted-offender companion in this file's style.

- [ ] **Step 2: Run to verify failure** — the two new suites; expected: build failure.

- [ ] **Step 3: Implement**

`GlossBriefing.compose`: role frame ("You are glossing one paragraph of a \(language) translation for its author, who reads \(authorLanguage) and not \(language). Render, literally, what the paragraph says — a back-rendering, not a polish, not a judgement."), the texture line when present ("The edition's texture: …"), "Before:" / "The paragraph:" / "After:" (neighbours marked as context, "do not gloss these"), then `schemaDescription` (one fenced JSON object `{"gloss": …}`, never empty, nothing else). `SpotCheck.gloss` reads `neighbours` off the badge entries (the translated surface the pane already holds — no disk), the texture line off `TranslatorOrchestrator.Environment.editionBriefText(language:store:)`, the author's language off `TranslationPipeline.Environment.authorLanguage(...)`, refuses `coldCall.isRunning` before calling (`busyRefusal` = "A cold session is already out — wait for the round's leg or the last spot-check to come back."), then `coldCall.call(message:, preamble: TranslationPipeline.coldPreamble, model:)` → `.resultText` → `GlossReport.parse` (nil → `.refused(RoundNarrative.failureCopy(.unusableOutput, session: .translation))`), `.failed(f)` → `.refused(RoundNarrative.failureCopy(f, session: .translation))`. `askTheCollator` = `collatorBriefing(...)` → `narrow` → `CollatorBriefing.compose` → call → `CollatorReport.parse(text, briefedParagraphIds: narrowed.briefedParagraphIds)`.

`TranslationReviewPane`: `@State gloss: SpotCheck.Outcome<String>?`, `@State collation: SpotCheck.Outcome<CollatorReport>?`, `@State spotChecking = false`, `@State dismissedDepartures: Set<String>` (transient "Fine"), sheets for Keep mine / Make it a rule (the same two sheets the report uses; the verbs call `TranslatorsNote.commit` and `RulingPerformer.rule(kind: .editionBrief(language), forScope: .project, world: nil)` directly with provenance `"spot-check, keep mine"` / `"spot-check, make it a rule"`). Under `sourceSection`: two buttons (`SpotCheck.glossTitle`, `SpotCheck.askTitle`, `.controlSize(.small)`, accessibility labels naming the paragraph, disabled while `spotChecking || coldCall?.isRunning == true` with `busyRefusal` as help, and — when `coldCall == nil` — pressing puts `notWiredRefusal` in the pane's existing `rulingNotice` alert? No: give the pane its own `@State notice: String?` drawn as a caption under the buttons — the one channel; the ruling alert stays for `QueryRuling`); the gloss drawn beneath the source text with a small-caps "gloss" label; the collation's departures drawn as `DepartureRowView`s (`TranslationRoundReport.DepartureRow` built from `CollatorReport.Departure` with `source` = the selected source paragraph, `outcomeLine` nil), plus `collation.overall` above them. Both results clear when `selected?.paragraphId` changes (`.onChange`). Nothing here is stored.

`DetailPaneToggle`/`ProjectWindow`: thread `coldCall`, `documentStore` (already `ds`), `projectURL` and `model` (`ds.uiState.compilerModel.claudeModel`) into the pane.

- [ ] **Step 4: Run** — the two new suites, `ColdCallTests`, `TranslationReviewPaneTests` (if it exists; else `DetailPaneToggle`'s suites), both censuses, `./scripts/test.sh`, Release build. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/GlossBriefing.swift Maugham/Compiler/GlossReport.swift Maugham/Compiler/SpotCheck.swift Maugham/Views/TranslationReviewPane.swift Maugham/Views/DetailPaneToggle.swift Maugham/Views/ProjectWindow.swift MaughamTests/
git commit -m "feat(translation-pipeline): Gloss and Ask the collator — two cold calls in the Translation pane, minting nothing"
```

---

### Task 7: The statement pane draws the glossary as a table and an orphaned directive as an orphan; the toolbar-width check

**Files:**
- Modify: `Maugham/Views/RulingsStratum.swift` (`RulingsStratumView` ~line 206; a `partition` static on `RulingsStratum`), `Maugham/Views/StatementPane.swift` (~line 199 where `RulingsStratumView` mounts: a `.task` that resolves the live paragraph ids)
- Test: `MaughamTests/StatementPaneStrataTests.swift` (add), a new `MaughamTests/SelectionToolbarWidthTests.swift`

**Interfaces:**
- Consumes: `Ruling.glossary`, `Ruling.directive`, `Ruling.paragraphId`, `RulingsSection.parse`, `currentParagraphState`, `EditionStatus.manuscriptDocumentIds(in:)`, `SelectionToolbarView` (`Maugham/Editor/EditorSurface.swift` — find its struct and its four `Kind`s).
- Produces:
  ```swift
  extension RulingsStratum {
      struct Partition: Equatable { let glossary: [Ruling]; let orphans: [Ruling]; let others: [Ruling] }
      /// `liveParagraphIds == nil` = unknown: nothing is an orphan (never a false orphan over a doc that has not loaded).
      static func partition(_ rulings: [Ruling], liveParagraphIds: Set<String>?) -> Partition
      static let glossaryHeading = "Glossary", orphanCaption = "This paragraph no longer exists", removeTitle = "Remove"
  }
  ```
  `RulingsStratumView` gains `var liveParagraphIds: Set<String>? = nil`.

- [ ] **Step 1: Write the failing tests**

In `StatementPaneStrataTests`: `partition` puts glossary-shaped rulings in `glossary` (file order), directives whose id is not live in `orphans`, everything else in `others`, and with `liveParagraphIds: nil` no orphan at all; a mounted `RulingsStratumView` with two glossary rulings draws a `Grid` whose texts include both terms and renderings and the `glossaryHeading`, and draws the orphan with `orphanCaption` and a `removeTitle` button whose press revokes exactly that line (the existing revoke test's shape, ~line 424); a mounted `StatementPane` on an edition brief over a project whose chapter lost the directed paragraph shows the orphan — the `.task` resolved the union of every manuscript document's ids (`EditionStatus.manuscriptDocumentIds` → `currentParagraphState` each), and for `.intent` at `.document(docId)` the one document's ids.

`SelectionToolbarWidthTests`: mount `SelectionToolbarView` (with the four kinds) inside a `TestWindow` 320pt wide and assert its rendered width (`NSView` frame via the hosting view, or the accessibility frame) is ≤ 320 and every button is enabled/visible. If it overhangs, this is the measurement the P2 handoff asked for — fix by letting the toolbar's `HStack` wrap or shrink (`.controlSize(.small)` + `.fixedSize(horizontal: false, vertical: true)` on labels, or a second row above 3 buttons) and keep the test as the pin. If it does not overhang, keep the test as the pin and record the measurement in the commit message.

- [ ] **Step 2: Run to verify failure**; **Step 3: Implement** (`partition`; in `RulingsStratumView.body`, when `partition.glossary` is non-empty draw `glossaryHeading` + a `Grid` (Term / Rendering / Note columns, each row followed by its own small Revoke via the existing `revoke(ruling, at: index)` — keep INDEX semantics by passing the ruling's original index, not the grid row); orphans draw `ruling.text` in `.secondary` with `orphanCaption` and a `Remove` `Button(.plain)` calling the same `revoke`; `others` as today. `StatementPane` mounts with `liveParagraphIds` from a `.task(id: <kind+scope>)`.) **Step 4: Run** the two suites, `StatementPaneTests`, both censuses, `./scripts/test.sh`. **Step 5: Commit** — `git commit -m "feat(translation-pipeline): glossary table and orphaned directives in the statement pane; toolbar width pinned"`.

---

### Task 8: ADR 0030, the roadmap entry, the AREA sweeps

**Files:**
- Create: `docs/adr/0030-three-people-seven-legs-directives-as-rulings.md`
- Modify: `docs/adr/README.md` (the index — add the row), `docs/roadmap.md` (Group 2, after the references-shelf entry ~line 242), `Maugham/Compiler/AREA.md` (the "Cold calls" section ~line 804 and after "The pipeline — seven legs"), `Maugham/Views/AREA.md` (the `Publish/DepartmentPane.swift` row ~line 39 and new rows), `Maugham/Stores/AREA.md` (the rounds-ledger row: `update`), `Maugham/MCP/AREA.md` (one sentence: the desk and `translation_status` read the same store), `CLAUDE.md` (the `Maugham/Compiler/` and `Maugham/Publish/` cells: one sentence each pointing at the pipeline's surfaces — keep it short; the cell is already long)
- Test: `MaughamTests/DocSyncTests.swift` — run it; nothing new is expected to fire, but read its ring-memory and shortcut checks against what you wrote

**Interfaces:** consumes the shipped code; produces prose only.

- [ ] **Step 1: ADR 0030** — header in ADR 0029's format (`**Date:** 2026-08-29 · **Status:** Accepted · **Milestone:** translation-pipeline (branches translation-pipeline-p1…p4)`); sections Context / Decision / Consequences. Content: three people per language (reader, collator beside the translator — `ProductionRole.Role.reader/.collator`, lazy-minted, presets), seven fixed legs in one Run (`TranslationPipeline`; skips recorded; a failing leg ends the round; Cancel reaches the live leg; the book queue), cold sessions sealed (`ColdCall`, `Confinement.sealed` — blind by construction), **directives are rulings** (the `¶id:` line through `RulingPerformer.rule` — ADR 0028's "one door into a statement" survives: a directive goes THROUGH the door; the glossary is rulings of a shape), only what needs the author becomes an annotation (declined → `.query` with the reply in the body; addressed → the round record), the round report is the primary surface and is written to the author in their language, Gloss/Ask the collator are the author's audit, and **proposals into statements (Plan 5) stop at the door** — recorded as the decision even though the store/tools/gate are not yet built (say so). Amends ADR 0024's single-translator picture; cites the constitution's Claude-parallel-layer principle by name; falsification: a session that holds a write tool, a directive minted anywhere but `RulingPerformer.rule`, a new `AnnotationKind`.
- [ ] **Step 2: Roadmap** — one `✓` entry "**The translation pipeline — three people, seven legs, directives as rulings (2026-08-28/29, P1–P4 shipped; P5 proposals pending)**" in the house style (what shipped per plan, by file/type; the carried-forward items from the three handoffs that still stand: declined reply lives in the query body; leg 4 skips when leg 3 wrote nothing; a failed round stops a book queue; `languageQueries` reads the open document only; same-day directives re-direct; the round-number collision window; per-row ledger decode cost), spec + plan paths, docs paths, ADR 0030.
- [ ] **Step 3: AREA sweeps** — `Maugham/Compiler/AREA.md`: entries for `ReportJSON` (the shared parser helpers; which parsers use it, which does not — `DiagnosticIngest` — and why), `ReaderReport`/`CollatorReport` (the wire, all-or-nothing, the gloss required), `ReaderBriefing`/`CollatorBriefing`/`BriefingDoctrine` (one line each if absent), `GlossBriefing`/`GlossReport`/`SpotCheck` (two more `ColdCall` callers; census: mints nothing), `TranslationPreflight`; update the "Cold calls" paragraph that says gloss and Ask the collator "are P4's". `Maugham/Views/AREA.md`: the desk row now runs the PIPELINE (Run, Run Whole Book, Cancel, Show, the leg/round/trend/pre-flight lines, `ReloadKey` carries the language only — P3's ruling 7), rows for `Publish/TranslationRoundReport.swift`+`View`+`Host`+`Actions`+`DepartureRow`+`RoundRuleSheet` (the fourth arm of the ONE switch; a round outranks a proposal; verbs are closures; write-back through `publishSelection`; nothing target-language-only collapsed), `TranslationReveal.swift` (the click-through: plan/perform, the pending reveal across a subject change), the Translation pane's two verbs, `RulingsStratum`'s partition. `Maugham/Stores/AREA.md`: `update` on the rounds ledger. `Maugham/MCP/AREA.md`: one sentence.
- [ ] **Step 4: Run `DocSyncTests` + `TripwireGrepTests`** — `xcodebuild … -only-testing:MaughamTests/DocSyncTests -only-testing:MaughamTests/TripwireGrepTests`; expected green.
- [ ] **Step 5: Commit** — `git commit -m "docs(translation-pipeline): ADR 0030, roadmap entry, AREA sweeps for Plan 4"`.

---

### Task 9: The guide, the skill pointer, the handoff

**Files:**
- Modify: `docs/guide/publish-department.md` ("The people" ~line 61, "Running a translation" ~line 83, "Answering a translator" ~184; new sections "The round report" and "Running the whole book"), `docs/guide/translation-review.md` ("The Translation pane (⌘⌥L)" ~line 45: Gloss, Ask the collator, disagreements in the queue), `docs/guide/right-pane.md` (the Rulings paragraph ~line 48: directives, the glossary table, orphaned directives; a one-sentence forward pointer that Claude Desktop will be able to PROPOSE a brief — Plan 5 — phrased as not yet shipped, per CLAUDE.md rule 7 say what ships), `docs/guide/compiler.md` (~line 206: check the Translator's note paragraph still reads true against the pane's new glossary table and the round report's Keep mine; add one sentence pointing at the report), `docs/skills/translation-pass/SKILL.md` (a short "The in-app pipeline" section: the desk's Run is seven legs with a reader and a collator; directives and the glossary are rulings in the brief the translator is briefed with — read `read_edition_brief` first; `translation_status.last_round` is where a Desktop session sees the last round), `docs/superpowers/notes/2026-08-29-translation-pipeline-p4-handoff.md` (create: state, what P4 built by file, the seams Plan 5 wires to, rulings made during execution, carried-forward items, gate record, process lessons — the P3 handoff's shape)
- Test: `MaughamTests/DocSyncTests.swift` (run; `test_toolCountSyncedAcrossDocsAndCatalog` must still pass — no count moved)

- [ ] **Step 1: Write the guide sections** in the guide's voice (second person, what the writer sees and presses, no type names). Publish-department: "Running a translation" becomes the seven legs in one Run — what each person does, Cancel's rule (what earlier legs wrote stays), the row's leg line, "7 legs · ~N words", the trend, **Run Whole Book** (the imprint the desk is on; one round per chapter in order; Cancel stops after the live leg; a failed round stops the queue), **The round report** (Show; the six sections in order and what each verb does; click-through; nothing on it needs the language), the people section gains the reader and the collator (presets Ocampo/Borges, Colette/Yourcenar, Bachmann/Schlegel, Enchi/Futabatei; Rename… offers all three). Translation-review: the pane's Gloss and Ask the collator, and that a declined note arrives in your queue as a query with both bylines. Right-pane: the Rulings paragraph grows the glossary table and orphaned directives.
- [ ] **Step 2: The skill pointer and the handoff** per the file list.
- [ ] **Step 3: Run** `DocSyncTests`, `HelpTopicIndexTests` (if present), `./scripts/test.sh`. Expected: green.
- [ ] **Step 4: Commit** — `git commit -m "docs(translation-pipeline): guide topics, translation-pass pointer, P4 handoff"`.

---

## Self-review (run by the plan's author before execution)

1. **Spec coverage.** §5 whole book → Task 2 (`runBook`, the desk's scoped set, Cancel); pre-flight → Tasks 1–2; the widened gate → already P3's, the desk reads it (Task 2). §7 trend → Tasks 1–2. §8 six sections in order, four-verb rows, click-through, before/after expansion, nothing target-language-only, the desk row's slot, `Phase.running` widening → Tasks 1–5. §9 Gloss/Ask the collator (transient, tool-less, same three verbs, neither mints) → Task 6. §3/§3.1 glossary table + orphan drawing (carried from P2) → Task 7. §12 report-surface tests (verbs act on the right annotation/ruling — Task 4; click-through — Task 5; nothing target-language-only — Task 3), spot-check tests (cold calls with no config, neither mints — Task 6 census). §14 docs → Tasks 8–9; the Compiler AREA entries carried from P1 → Task 8; the toolbar-width check carried from P2 → Task 7. §6's "a note the author rejects is `rejected` and never briefed again" — Translator's right (Task 4) uses `rejectAnnotation`; the gather already reads `open` only (P3 pinned it).
2. **Placeholders.** Task 4's test bodies for `makeItARule`/`translatorsRight`/`readersRight`/`adopt`/`skip`/`answer` are described by their assertions rather than spelled in full — deliberate: each is the `keepMine` test's shape with the verb and the assertion swapped, and the implementer has that full example one test above. Task 7's Step 3 is prose over an existing view; its two tests are spelled. Everything else carries code.
3. **Type consistency.** `RunningLeg`/`Phase.running(RunningLeg)` (T1) ↔ T2's tests; `latestRound`/`trend`/`chapterWords`/`bookWords`/`bookDocumentCount` (T1) ↔ T2's `runStates`; `runBook`/`showRound` (T2 pane) ↔ T2 host; `onShowRound` (host) ↔ `onShowTranslationRound` (toggle/window); `publishSelectedRound` (T2) ↔ T3's arm; `TranslationRoundActions.Outcome.done(TranslationRound?, String)`/`.refused(String)` (T3) ↔ T4's factory; `onReveal: (String) -> Void` (T3) ↔ T5's `TranslationReveal.post`; `DepartureRowView`/`TranslationRoundReport.DepartureRow` (T3) ↔ T6's pane; `TranslationRoundReport.provenance(round:verb:)` (T3) ↔ T4; `Partition`/`liveParagraphIds` (T7) internal to T7.
