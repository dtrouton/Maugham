# Translation Pipeline — Plan 3: Pipeline, Minting, Round

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one Run a seven-leg pipeline: `TranslationPipeline` sequences the translator's warm session and the sealed cold calls Plan 2 built, mints per spec §6 (addressed notes into a round record, declined notes into `.query` annotations carrying the translator's reason), writes a `TranslationRound` into a per-language ring of ten, widens the desk's one-round-at-a-time gate, and widens `translation_status`.

**Architecture:** `TranslationPipeline` (`Maugham/Compiler/`) is a `@MainActor` state machine over a closure `Environment` — the orchestrators' shape — that owns no session, gathers no briefing and parses no report *itself*: it calls `TranslatorOrchestrator.runTranslation`/`runFix` and awaits their `onRunEnded`/`onRunAbandoned`, calls `ColdCall.call` for the reader and collator legs, and turns every leg's outcome into a `TranslationRound` it hands to `TranslationRoundStore`. The `.fix` briefing is a second gather in `TranslatorEnvironment+Project.swift` behind a new `Environment.briefFix`, reached through a new `runFix` entry so `begin`'s identity-then-briefing order and `finish`'s `reportMode` threading are reused unchanged. **Note ids are minted by the pipeline before leg 3/5/7 is briefed** and the `.fix` work-list is built FROM the notes it briefs. Declined notes are minted by the pipeline through an environment closure, in `TranslatorEnvironment+Project.swift`'s `mint` idiom.

**Tech Stack:** Swift 6, SwiftUI + AppKit, XCTest. Mac scheme only — nothing here touches `Packages/MaughamCore`.

**Spec:** `docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` — §5 (pipeline), §6 (minting), §7 (round record), §8's MCP line, §12 (tests: pipeline, minting, round record, teardown census), §13 item 3. Read §1–§13 once.

**Built on:** Plan 1 (`docs/superpowers/plans/2026-08-28-translation-pipeline-p1-cast-rulings-wire.md`) and Plan 2 (`docs/superpowers/plans/2026-08-29-translation-pipeline-p2-briefings-coldcalls-verbs.md`), merged at `2498d90b`. **This plan never restates their API.** What it points at, by file — read each before the task that uses it:

- `Maugham/Compiler/ColdCall.swift` — `call(message:preamble:model:) async -> CompilerRunEvent`, `cancel()`, `shutdown()`, `detach()`, `notWiredDetail`.
- `Maugham/Compiler/ReaderBriefing.swift` — `Inputs(readerName:language:authorLanguage:roleBrief:editionBriefText:paragraphs:)`, `Paragraph(paragraphId:translation:)` (nil = not shown), `briefedParagraphIds`, `compose(inputs:)`.
- `Maugham/Compiler/CollatorBriefing.swift` — `Inputs(collatorName:language:authorLanguage:roleBrief:craftIntentText:editionBriefText:glossary:pairs:)`, `Pair(paragraphId:sourceText:translation:directives:)`, `briefedParagraphIds`, `compose(inputs:)`.
- `Maugham/Compiler/TranslatorBriefing.swift` — `FixNote(id:paragraphId:author:kind:severity:text:)`, `Mode.fix(notes:isFinalLeg:)`, `Inputs.reportMode`, `WorkItem(paragraphId:sourceText:status:priorTranslation:directives:)`.
- `Maugham/Compiler/BriefingDoctrine.swift` — `Directives.gather/byParagraph`, `GlossaryTable.gather`.
- `Maugham/Compiler/ReaderReport.swift`, `CollatorReport.swift`, `TranslatorReport.swift` — `parse`, `Verdict`/`Kind`/`Severity` raw values, `TranslatorReport.Declined(noteId:reason:)`, `.GlossaryProposal(term:rendering:reason:)`, `CollatorReport.drifted`.
- `Maugham/Compiler/TranslatorOrchestrator.swift` — `Pair`, `RunState`, `Failure`, `BriefedRound`, `IngestContext`, `IngestOutcome`, `RunSummary`/`.Outcome`, `Environment`, `runTranslation`, `cancel`, `shutdown`, `detach`, `begin`/`finish`/`end`/`abandon`.
- `Maugham/Compiler/TranslatorEnvironment+Project.swift` — `production(...)`, `briefing`, `ingest`, `mint`, `midRunEdits`, `queryToolArgs`, and the private statics `craftIntentText`/`editionBriefText`/`neighbours`/`languageQueries`.
- `Maugham/MCP/Tools/TranslationTools.swift` — free function `currentParagraphState(documentId:store:documentStore:projectURL:)`, `TranslationStatusTool`.
- `Maugham/MCP/Tools/AnnotationToolHelpers.swift` — `withAnnotationDocument(store:projectURL:documentId:body:)` (open doc else transient load).
- `Maugham/Stores/ProjectStore+ProductionRoles.swift` — `readerRole(for:)`, `collatorRole(for:)` (RUN-ONLY mints); `Maugham/Publish/EditionStatus.swift` — `translatorName/readerName/collatorName(for:in:)`, `manuscriptDocumentIds(in:)`.
- `Maugham/Views/Publish/DepartmentRunState.swift` — `DepartmentRunSession.read(runState:isRunning:)`, `DepartmentRunState.failureCopy(_:)`; `DepartmentPaneHost.sourceLanguage(imprint:in:pieceIDs:)`, `scopedDocumentIds(_:imprint:in:)` (`DepartmentPaneHost.swift`).
- `Maugham/Compiler/RoundNarrative.swift` — `failureCopy(_:session:)`, `SessionWork.translation`.
- `Maugham/Stores/DesignProposalStore.swift` — the JSON-under-`.maugham/` store precedent (`JSONEncoder` `.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`, `.iso8601`, `.atomic`).
- Tests to mirror: `MaughamTests/TranslatorOrchestratorTests.swift` (SpyRunner, `Gate`, `Box`, `makeHarness`), `MaughamTests/TranslatorEnvironmentTests.swift` (real-project harness; the teardown census at the bottom), `MaughamTests/ColdCallTests.swift`, `MaughamTests/DepartmentRunTests.swift`, `MaughamTests/MCP/Tools/TranslationStatusToolTests.swift`.

## Global Constraints

Copied from the spec; every task's requirements include these.

- **`TranslationPipeline` owns no session, gathers no briefing, parses no report** — it sequences legs by calling the orchestrators and listening to their `onRunEnded` (§5). Parsing a cold report's TEXT into a `ReaderReport`/`CollatorReport` is the pipeline's, since `ColdCall` returns raw text; the *gather* is the environment's.
- **Skips are recorded, never silent** (§5): legs 2/4 skip when there is nothing fresh to read; legs 3/5/7 skip when the preceding pass left nothing; leg 6 runs whenever any earlier leg wrote, else skips and the round says "nothing to do".
- **A failing or rejected leg ends the pipeline there; earlier legs' writes stay; a cancelled leg ends it and nothing later starts** (§5).
- **Cancel reaches whichever leg is live; between legs the pipeline checks its own generation** (§5).
- **Whole book = the documents of the imprint the desk is standing on**, `EditionStatus.languageRows(documentIds:)`'s set, in binder order, one round each; Cancel stops the queue after the live leg (§5).
- **The gate widens** from "a translator round" to "a pipeline, or a book queue" — one round at a time across every language (§5).
- **Minting (§6):** entries land through `TranslationWritePipeline` (unchanged); reader notes and collator departures go to the round record, never the queue; an addressed id is marked so with before/after; a **declined** note mints as a `.query` (anchored; author = reader/collator by `effectiveName`; `language`-tagged; kind/severity in the body's first line) with the translator's reason as a reply; translator queries mint as today; a rejected note is never briefed again.
- **No new `AnnotationKind`, no new `OpKind`.** The annotation layer has no reply primitive; the translator's reason is carried in the query's body under the translator's name (see Task 6's `declinedBody`), and the structured form lives on the round record.
- **`TranslationRound` is derived** — `.maugham/translations/rounds/<lang>.json`, a ring of the last 10 per language, numbering per language across documents; losing it costs a report, never words (§7).
- **Every `ColdCall` spawn stays sealed** (§11). This plan adds callers, never a spawn site; `TripwireGrepTests.test_theOnlySealedSpawnerIsColdCall` must stay green.
- **The keystroke is the only trigger.** Nothing here re-arms itself.
- **Teardown: every window-ending arm carries the pipeline beside the four existing siblings** (`TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown` widens).
- **`./gen.sh` after adding ANY source or test file**; a stale project runs 0 tests silently.
- **`./scripts/test.sh full` before merge; read the kept xcresult** (`xcrun xcresulttool get test-results summary --path <xcresult>`), never the pipe's exit code. Before blaming a red mounted-click test: `ioreg -n Root -d1 | grep ScreenIsLocked`.
- **Execution in a worktree** under `../Maugham-wt/` (`git worktree add ../Maugham-wt/translation-p3 -b translation-pipeline-p3 main`), `./gen.sh` there before any `xcodebuild`. The worktree guard refuses compound shell commands — one command per call.
- One suite: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<Class>`.

## File structure

| File | Responsibility |
|---|---|
| `Maugham/Compiler/TranslationRound.swift` (create) | The round record (§7) — `TranslationRound`, `Leg`, `LegRecord`, `NoteRecord`, `DepartureRecord`, outcomes; pure, `Codable` |
| `Maugham/Stores/TranslationRoundStore.swift` (create) | `.maugham/translations/rounds/<lang>.json`; ring of 10; `nextNumber`; `latest`; `trend` |
| `Maugham/Compiler/TranslatorOrchestrator.swift` (modify) | `runFix`, `Environment.briefFix`, `Environment.onRunAbandoned`, run verbs return the run id, `IngestOutcome` carries the fix report's fields and per-paragraph rewrites |
| `Maugham/Compiler/TranslatorEnvironment+Project.swift` (modify) | Production `briefFix` gather (work-list FROM the notes); ingest computes rewrites; `mint` reaches a closed document; shared statics widened to internal |
| `Maugham/Compiler/TranslationPipeline.swift` (create) | The state machine: seven legs, skips, failure, Cancel, generation, book queue, `Status` |
| `Maugham/Compiler/TranslationPipelineEnvironment+Project.swift` (create) | Production closures: reader/collator identities and gathers, `authorLanguage`, cold calls, declined-query mint, round store |
| `Maugham/Views/Publish/DepartmentRunState.swift` (modify) | `DepartmentRunSession.read` takes the pipeline's status |
| `Maugham/Views/ProjectWindow.swift`, `CompilerRunModifier.swift`, `DetailPaneToggle.swift`, `Publish/DepartmentPaneHost.swift` (modify) | The window owns, configures, tears down and passes the pipeline; the desk's gate reads it |
| `Maugham/MCP/Tools/TranslationTools.swift` (modify) | `translation_status` rows gain `reader`, `collator`, `last_round` |
| `Maugham/Compiler/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/MCP/AREA.md` (modify) | Docs for what shipped |

---

### Task 1: The round record and its store

**Files:**
- Create: `Maugham/Compiler/TranslationRound.swift`
- Create: `Maugham/Stores/TranslationRoundStore.swift`
- Test: `MaughamTests/TranslationRoundStoreTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `TranslationRound` (+ nested `Leg`, `LegStatus`, `LegCounts`, `LegRecord`, `ReaderReportRecord`, `Rewrite`, `NoteOutcome`, `NoteRecord`, `DepartureOutcome`, `DepartureRecord`, `GlossaryProposalRecord`), `TranslationRoundStore(projectURL:)` with `ringSize`, `directoryURL(in:)`, `fileURL(language:in:)`, `nextNumber(language:)`, `append(_:)`, `rounds(language:)`, `latest(language:docId:)`, `trend(language:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/TranslationRoundStoreTests.swift
import XCTest
@testable import Maugham

/// The round record (spec §7): derived, a ring of ten per language, numbered
/// per language across documents. Losing it costs a report, never words.
@MainActor
final class TranslationRoundStoreTests: XCTestCase {

    private func makeStore() throws -> TranslationRoundStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoundStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TranslationRoundStore(projectURL: root)
    }

    private func round(number: Int, language: String = "es", docId: String = "doc-1",
                       notes: Int = 0) -> TranslationRound {
        var round = TranslationRound(number: number, language: language, docId: docId,
                                     startedAt: Date(timeIntervalSince1970: 1_000))
        round.endedAt = Date(timeIntervalSince1970: 2_000)
        round.notes = (0..<notes).map { index in
            TranslationRound.NoteRecord(
                id: "n\(index)", leg: .read, author: "Ocampo", paragraphId: "a1b2",
                kind: "rhythm", severity: "minor", text: "Limps.",
                outcome: .addressed(.init(beforeRecordId: "r1", before: "old",
                                          afterRecordId: "r2", after: "new")))
        }
        return round
    }

    func test_aFullRecordRoundTripsThroughTheStore() throws {
        let store = try makeStore()
        var round = round(number: 1, notes: 1)
        round.legs = [
            .init(leg: .translate, status: .ran, counts: .init(entries: 2, queries: 1)),
            .init(leg: .read, status: .ran, counts: .init(notes: 1)),
            .init(leg: .fix, status: .skipped, reason: "the reader found nothing to fix"),
            .init(leg: .reread, status: .failed, reason: "The translation round died."),
        ]
        round.leg2 = .init(verdict: "mixed", text: "Reads well.")
        round.collatorOverall = "Holds."
        round.departures = [
            .init(id: "d1", paragraphId: "c3d4", verdict: "drifted", kind: "omission",
                  note: "Lost a clause.", gloss: "The fog came.",
                  outcome: .declined(reason: "Deliberate.", annotationId: "ann-1")),
            .init(id: "d2", paragraphId: "a1b2", verdict: "holds", kind: "rendering",
                  note: "Split.", gloss: "She shut it.", outcome: .dismissed),
            .init(id: "d3", paragraphId: "a1b2", verdict: "holds", kind: "rendering",
                  note: "Pun.", gloss: "…", outcome: nil),
        ]
        round.summary = "Done."
        round.glossaryProposals = [.init(term: "October", rendering: "Octubre",
                                         reason: "the month", adopted: false)]
        try store.append(round)

        XCTAssertEqual(store.rounds(language: "es"), [round])
        XCTAssertEqual(store.latest(language: "es", docId: "doc-1"), round)
        XCTAssertEqual(round.stoppedAt, .reread, "a failed leg is where the round stopped")
    }

    func test_theRingKeepsTheNewestTenAndNumberingRunsPastIt() throws {
        let store = try makeStore()
        for number in 1...12 {
            XCTAssertEqual(store.nextNumber(language: "es"), number)
            try store.append(round(number: number))
        }
        let kept = store.rounds(language: "es")
        XCTAssertEqual(kept.count, TranslationRoundStore.ringSize)
        XCTAssertEqual(kept.map(\.number), Array((3...12).reversed()), "newest first")
        XCTAssertEqual(store.nextNumber(language: "es"), 13,
                       "the number outlives the ring — round 3 must not be minted twice")
    }

    func test_numberingIsPerLanguageAcrossDocuments() throws {
        let store = try makeStore()
        try store.append(round(number: 1, language: "es", docId: "doc-1"))
        try store.append(round(number: 2, language: "es", docId: "doc-2"))
        XCTAssertEqual(store.nextNumber(language: "es"), 3)
        XCTAssertEqual(store.nextNumber(language: "fr"), 1)
        XCTAssertEqual(store.latest(language: "es", docId: "doc-1")?.number, 1,
                       "the newest round for THIS pair, not for the language")
        XCTAssertEqual(store.latest(language: "es", docId: nil)?.number, 2)
        XCTAssertNil(store.latest(language: "es", docId: "doc-9"))
    }

    func test_theTrendReadsNotesPerRoundForTheLastFive() throws {
        let store = try makeStore()
        for (number, notes) in [(1, 9), (2, 5), (3, 4), (4, 4), (5, 2), (6, 1)] {
            try store.append(round(number: number, notes: notes))
        }
        XCTAssertEqual(store.trend(language: "es"), [5, 4, 4, 2, 1], "oldest first")
        XCTAssertEqual(store.trend(language: "fr"), [])
    }

    func test_anUndecodableLedgerReadsAsEmptyRatherThanThrowing() throws {
        let store = try makeStore()
        let url = TranslationRoundStore.fileURL(language: "es", in: store.projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(store.rounds(language: "es"), [])
        XCTAssertEqual(store.nextNumber(language: "es"), 1)
        try store.append(round(number: 1))
        XCTAssertEqual(store.rounds(language: "es").count, 1, "the store recovers by rewriting")
    }

    func test_aCancelledRoundRecordsWhereItStoppedAndNoSummary() {
        var round = round(number: 1)
        round.legs = [.init(leg: .translate, status: .ran, counts: .init(entries: 1)),
                      .init(leg: .read, status: .cancelled)]
        XCTAssertEqual(round.stoppedAt, .read)
        XCTAssertTrue(round.wasCancelled)
        XCTAssertNil(round.summary)
    }

    func test_everyLegHasANameAndAVerb() {
        XCTAssertEqual(TranslationRound.Leg.allCases.count, 7)
        XCTAssertEqual(TranslationRound.Leg.allCases.map(\.rawValue), Array(1...7))
        for leg in TranslationRound.Leg.allCases {
            XCTAssertFalse(leg.name.isEmpty)
            XCTAssertFalse(leg.verb.isEmpty)
        }
        XCTAssertEqual(TranslationRound.Leg.reread.name, "re-read")
        XCTAssertEqual(TranslationRound.Leg.collate.verb, "collating")
    }

    func test_theLanguageFileIsLowercased() throws {
        let store = try makeStore()
        XCTAssertEqual(TranslationRoundStore.fileURL(language: "ES", in: store.projectURL)
                           .lastPathComponent, "es.json")
        XCTAssertEqual(TranslationRoundStore.directoryURL(in: store.projectURL).path
                           .hasSuffix(".maugham/translations/rounds"), true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run `./gen.sh`, then the suite. Expected: compile failure — `TranslationRound`/`TranslationRoundStore` undefined.

- [ ] **Step 3: Write the record**

```swift
// Maugham/Compiler/TranslationRound.swift
import Foundation

/// **One pipeline round, as the record the author reads** (translation
/// pipeline spec §7). Derived: `.maugham/translations/rounds/<lang>.json`, a
/// ring of ten per language (`TranslationRoundStore`); losing it costs a
/// report, never words.
///
/// Everything a leg produced that the AUTHOR needs to see lands here — reader
/// reports, every note and departure with what the translator did about it,
/// the summary and glossary proposals — and the queue holds only what needs
/// the author's answer (spec §6). A `Codable` value with no store behind it:
/// `TranslationPipeline` builds one, `TranslationRoundStore` writes it, Plan
/// 4's report surface draws it.
struct TranslationRound: Codable, Equatable, Sendable {

    /// The seven legs, numbered as the spec's table numbers them.
    enum Leg: Int, Codable, CaseIterable, Sendable {
        case translate = 1, read, fix, reread, fixAgain, collate, finalFix

        /// The noun the record and the report use.
        var name: String {
            switch self {
            case .translate: return "translate"
            case .read: return "read"
            case .fix, .fixAgain, .finalFix: return "fix"
            case .reread: return "re-read"
            case .collate: return "collate"
            }
        }

        /// The present participle the desk's status slot draws (spec §8) —
        /// exposed here so Plan 4 only draws it.
        var verb: String {
            switch self {
            case .translate: return "translating"
            case .read: return "reading"
            case .fix, .fixAgain, .finalFix: return "fixing"
            case .reread: return "re-reading"
            case .collate: return "collating"
            }
        }

        var isFix: Bool { self == .fix || self == .fixAgain || self == .finalFix }
    }

    enum LegStatus: String, Codable, Sendable { case ran, skipped, failed, cancelled }

    /// What a leg that ran produced. Every field defaults to zero so a leg
    /// records only the counts it has.
    struct LegCounts: Codable, Equatable, Sendable {
        var entries = 0
        var queries = 0
        var notes = 0
        var departures = 0
        var addressed = 0
        var declined = 0

        init(entries: Int = 0, queries: Int = 0, notes: Int = 0,
             departures: Int = 0, addressed: Int = 0, declined: Int = 0) {
            self.entries = entries; self.queries = queries; self.notes = notes
            self.departures = departures; self.addressed = addressed; self.declined = declined
        }
    }

    /// `ran(counts) | skipped(reason) | failed(sentence) | cancelled`, flattened
    /// so the record stays plain JSON: `reason` carries a skip's reason or a
    /// failure's sentence.
    struct LegRecord: Codable, Equatable, Sendable {
        let leg: Leg
        let status: LegStatus
        var counts: LegCounts?
        var reason: String?

        init(leg: Leg, status: LegStatus, counts: LegCounts? = nil, reason: String? = nil) {
            self.leg = leg; self.status = status; self.counts = counts; self.reason = reason
        }
    }

    /// A reader's `overall`: `ReaderReport.Verdict.rawValue` and the paragraph
    /// written to the author.
    struct ReaderReportRecord: Codable, Equatable, Sendable {
        let verdict: String
        let text: String
    }

    /// The paragraph's translation before and after a fix leg — the sidecar is
    /// append-only, so the two record ids name the two entries and the texts
    /// travel beside them so the report needs no second read.
    struct Rewrite: Codable, Equatable, Sendable {
        let beforeRecordId: String?
        let before: String?
        let afterRecordId: String?
        let after: String?
    }

    enum NoteOutcome: Codable, Equatable, Sendable {
        case addressed(Rewrite)
        case declined(reason: String, annotationId: String?)
    }

    /// A reader's note (leg 2 or 4). `id` is minted by the pipeline BEFORE the
    /// fix leg is briefed and is what `addressed`/`declined` name. `outcome`
    /// nil = the fix leg never reached it (skipped, failed, cancelled, or the
    /// paragraph lost its translation in between).
    struct NoteRecord: Codable, Equatable, Sendable {
        let id: String
        let leg: Leg
        let author: String
        let paragraphId: String
        let kind: String
        let severity: String?
        let text: String
        var outcome: NoteOutcome?
    }

    enum DepartureOutcome: Codable, Equatable, Sendable {
        case addressed(Rewrite)
        case declined(reason: String, annotationId: String?)
        /// The author's own "Fine" on the round report (Plan 4).
        case dismissed
    }

    /// A collator's departure (leg 6). Only `drifted` ones are briefed to leg
    /// 7, but every one is recorded. `id` as for a note.
    struct DepartureRecord: Codable, Equatable, Sendable {
        let id: String
        let paragraphId: String
        let verdict: String
        let kind: String
        let note: String
        let gloss: String
        var outcome: DepartureOutcome?
    }

    struct GlossaryProposalRecord: Codable, Equatable, Sendable {
        let term: String
        let rendering: String
        let reason: String
        var adopted: Bool
    }

    let number: Int
    let language: String
    let docId: String
    let startedAt: Date
    var endedAt: Date?
    var legs: [LegRecord] = []
    var leg2: ReaderReportRecord?
    var leg4: ReaderReportRecord?
    var collatorOverall: String?
    var notes: [NoteRecord] = []
    var departures: [DepartureRecord] = []
    var summary: String?
    var glossaryProposals: [GlossaryProposalRecord] = []

    init(number: Int, language: String, docId: String, startedAt: Date) {
        self.number = number; self.language = language; self.docId = docId
        self.startedAt = startedAt
    }

    /// The leg a failed or cancelled round stopped at, or nil for one that ran
    /// to the end.
    var stoppedAt: Leg? {
        legs.first { $0.status == .failed || $0.status == .cancelled }?.leg
    }

    var wasCancelled: Bool { legs.contains { $0.status == .cancelled } }
    var failed: Bool { legs.contains { $0.status == .failed } }

    /// Notes per round — the desk's trend figure (spec §7).
    var noteCount: Int { notes.count }

    var declinedCount: Int {
        notes.filter { if case .declined = $0.outcome { return true } else { return false } }.count
            + departures.filter { if case .declined = $0.outcome { return true } else { return false } }.count
    }
}
```

- [ ] **Step 4: Write the store**

```swift
// Maugham/Stores/TranslationRoundStore.swift
import Foundation
import MaughamCore
import os

private let roundLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "TranslationRounds")

/// **The ring of rounds** (spec §7): `.maugham/translations/rounds/<lang>.json`,
/// one file per language holding the last `ringSize` rounds and the next
/// number. Derived — losing it costs a report and restarts numbering, never
/// words. Not per-device (tripwire 17 is about concurrent APPENDS to one file;
/// this is a whole-file rewrite by the one pipeline the gate allows), and
/// `.maugham/translations/` already classifies as `unknownSidecar` in
/// `MaughamSidecarPath`, so no presenter route changes.
struct TranslationRoundStore {

    static let ringSize = 10

    /// The file's whole content. `nextNumber` outlives the ring so a number
    /// trimmed out of it is never minted twice.
    struct Ledger: Codable, Equatable {
        var nextNumber: Int = 1
        /// Oldest first on disk; readers below reverse it.
        var rounds: [TranslationRound] = []
    }

    let projectURL: URL

    init(projectURL: URL) { self.projectURL = projectURL }

    static func directoryURL(in projectURL: URL) -> URL {
        TranslationStore.directoryURL(in: projectURL).appendingPathComponent("rounds")
    }

    static func fileURL(language: String, in projectURL: URL) -> URL {
        directoryURL(in: projectURL).appendingPathComponent("\(language.lowercased()).json")
    }

    func nextNumber(language: String) -> Int {
        load(language: language).nextNumber
    }

    /// Newest first.
    func rounds(language: String) -> [TranslationRound] {
        load(language: language).rounds.reversed()
    }

    /// The newest round for `(language, docId)`, or for the language when
    /// `docId` is nil.
    func latest(language: String, docId: String?) -> TranslationRound? {
        rounds(language: language).first { docId == nil || $0.docId == docId }
    }

    /// Notes per round over the last five, oldest first — the desk's trend.
    func trend(language: String) -> [Int] {
        Array(load(language: language).rounds.suffix(5)).map(\.noteCount)
    }

    /// Append one finished round, advance the number past it, trim the ring.
    func append(_ round: TranslationRound) throws {
        var ledger = load(language: round.language)
        ledger.rounds.append(round)
        ledger.nextNumber = max(ledger.nextNumber, round.number + 1)
        if ledger.rounds.count > Self.ringSize {
            ledger.rounds.removeFirst(ledger.rounds.count - Self.ringSize)
        }
        try write(ledger, language: round.language)
    }

    /// A missing or undecodable file is an empty ledger, logged — the ring is
    /// derived, and a round that cannot be written because last month's could
    /// not be read is the wrong trade.
    private func load(language: String) -> Ledger {
        let url = Self.fileURL(language: language, in: projectURL)
        guard let data = try? Data(contentsOf: url) else { return Ledger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Ledger.self, from: data)
        } catch {
            roundLog.error("round ledger for \(language, privacy: .public) is unreadable and will be replaced: \(error, privacy: .public)")
            return Ledger()
        }
    }

    private func write(_ ledger: Ledger, language: String) throws {
        try FileManager.default.createDirectory(
            at: Self.directoryURL(in: projectURL), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ledger).write(
            to: Self.fileURL(language: language, in: projectURL), options: .atomic)
    }
}
```

- [ ] **Step 5: `./gen.sh`, run the suite, expect PASS**

- [ ] **Step 6: Commit**

```bash
git add Maugham/Compiler/TranslationRound.swift Maugham/Stores/TranslationRoundStore.swift MaughamTests/TranslationRoundStoreTests.swift
git commit -m "feat(translation-pipeline): TranslationRound record and its ring-of-ten store"
```

---

### Task 2: `runFix` on the orchestrator

**Files:**
- Modify: `Maugham/Compiler/TranslatorOrchestrator.swift`
- Test: `MaughamTests/TranslatorOrchestratorTests.swift`

**Interfaces:**
- Consumes: everything on `TranslatorOrchestrator` today.
- Produces:
  - `Environment.briefFix: @MainActor (String, String, [TranslatorBriefing.FixNote], Bool) async -> BriefedRound?` (docId, language, notes, isFinalLeg) — **not defaulted**.
  - `Environment.onRunAbandoned: @MainActor (String) -> Void = { _ in }` — the run id of a click that turned out not to be a run (the briefing answered nil).
  - `@discardableResult func runTranslation(docId:language:) -> String?` — the run id, or nil when refused.
  - `@discardableResult func runFix(docId:language:notes:isFinalLeg:) -> String?`.
  - `IngestOutcome` gains `addressed: [String] = []`, `declined: [TranslatorReport.Declined] = []`, `summary: String? = nil`, `glossaryProposals: [TranslatorReport.GlossaryProposal] = []`, `rewrites: [ParagraphRewrite] = []`; new `struct ParagraphRewrite: Equatable, Sendable { let paragraphId: String; let beforeRecordId: String?; let before: String?; let afterRecordId: String?; let after: String? }` nested in `TranslatorOrchestrator`.

- [ ] **Step 1: Write the failing tests** (append to `TranslatorOrchestratorTests`; the harness's `Environment(...)` init must gain `briefFix:` — add a `fixRound` parameter to `makeHarness` and an `abandoned` recorder; the file's existing `Harness` gains `let abandoned: () -> [String]`):

```swift
    // In makeHarness, beside `round:`:
    //   fixRound: TranslatorOrchestrator.BriefedRound? = nil,
    // and in the Environment init, after briefRound:
    //   briefFix: { _, _, notes, isFinalLeg in
    //       order.value.append("briefFix(\(notes.count),\(isFinalLeg))")
    //       return fixRound
    //   },
    // and after onRunEnded:
    //   onRunAbandoned: { abandoned.value.append($0) }
    // where `let abandoned = Box<[String]>([])` and Harness carries
    // `abandoned: { abandoned.value }`.

    private static let oneFixReport = """
        {"entries":[{"paragraph_id":"a1b2","text":"Vino la niebla."}],"queries":[],\
        "addressed":["n1"],"declined":[{"note_id":"n2","reason":"Deliberate."}]}
        """

    private func fixNotes() -> [TranslatorBriefing.FixNote] {
        [.init(id: "n1", paragraphId: "a1b2", author: "Ocampo", kind: "rhythm",
               severity: "minor", text: "Limps."),
         .init(id: "n2", paragraphId: "c3d4", author: "Ocampo", kind: "register",
               severity: "major", text: "Wobbles.")]
    }

    /// The fix leg asks `briefFix`, never `briefRound`, AFTER the identity;
    /// its report is parsed with the fix contract the briefing derives.
    func test_aFixLegBriefsThroughBriefFixAndParsesWithTheFixContract() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(Self.oneFixReport)
        let fix = makeRound(work: 2, mode: .fix(notes: fixNotes(), isFinalLeg: false))
        let harness = try makeHarness(runner: runner, round: nil, fixRound: fix)

        let runId = harness.orchestrator.runFix(
            docId: docId, language: language, notes: fixNotes(), isFinalLeg: false)
        XCTAssertNotNil(runId)
        pump { harness.summaries.count == 1 }

        XCTAssertEqual(harness.order, ["translatorIdentity", "briefFix(2,false)"])
        XCTAssertEqual(harness.ingests.count, 1)
        XCTAssertEqual(harness.ingests.first?.report.addressed, ["n1"])
        XCTAssertEqual(harness.ingests.first?.report.declined.map(\.noteId), ["n2"])
        XCTAssertEqual(harness.summaries.first?.runId, runId)
        XCTAssertEqual(harness.ingests.first?.context.briefedSourceHashes.count,
                       fix.sourceHashes.count)
    }

    /// A report that stays silent on a briefed note is unusable — the parser
    /// holds the fix leg to its notes (spec §4), through this entry too.
    func test_aFixReportSilentOnANoteIsUnusableOutput() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(
            #"{"entries":[],"queries":[],"addressed":["n1"],"declined":[]}"#)
        let harness = try makeHarness(
            runner: runner, round: nil,
            fixRound: makeRound(work: 2, mode: .fix(notes: fixNotes(), isFinalLeg: true)))
        harness.orchestrator.runFix(docId: docId, language: language,
                                    notes: fixNotes(), isFinalLeg: true)
        pump { harness.summaries.count == 1 }
        XCTAssertEqual(harness.summaries.map(\.outcome), [.failed(.run(.unusableOutput))])
        XCTAssertTrue(harness.ingests.isEmpty)
    }

    /// The run verbs answer with the id the summary will carry, and nil when
    /// they refuse — what the pipeline sequences on.
    func test_theRunVerbsReturnTheRunIdTheSummaryCarriesAndNilWhenRefused() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, round: makeRound())
        let first = harness.orchestrator.runTranslation(docId: docId, language: language)
        XCTAssertNotNil(first)
        pump { runner.sends.count == 1 }
        XCTAssertNil(harness.orchestrator.runTranslation(docId: docId, language: language),
                     "a second run while one is in flight is refused with nil")
        XCTAssertNil(harness.orchestrator.runFix(docId: docId, language: language,
                                                 notes: fixNotes(), isFinalLeg: false))
        runner.release(.resultText(Self.oneEntry))
        pump { harness.summaries.count == 1 }
        XCTAssertEqual(harness.summaries.first?.runId, first)
    }

    /// A click that turned out not to be a run (the briefing answered nil)
    /// still tells whoever is waiting on it — by run id, through
    /// `onRunAbandoned`, never through a summary.
    func test_anAbandonedRunIsReportedByIdThroughOnRunAbandoned() throws {
        let harness = try makeHarness(runner: SpyRunner(), round: nil)
        let runId = try XCTUnwrap(
            harness.orchestrator.runTranslation(docId: docId, language: language))
        pump { !harness.abandoned.isEmpty }
        XCTAssertEqual(harness.abandoned, [runId])
        XCTAssertTrue(harness.summaries.isEmpty, "an abandon is not a summary")
        XCTAssertFalse(harness.orchestrator.isRunning)
    }
```

`pump` is whatever this suite already uses to spin the main loop until a predicate holds — read the file and reuse its helper (it exists; the suite is synchronous over `RunLoop`). If the helper has another name, use that name.

- [ ] **Step 2: Run to verify it fails** — compile errors: no `briefFix`, `runFix`, `onRunAbandoned`; `runTranslation` returns Void.

- [ ] **Step 3: Implement**

In `Environment`, after `briefRound`:

```swift
        /// A FIX leg's briefing (spec §2's `.fix` mode): the same shape as
        /// `briefRound`, over the notes the pipeline hands it. Its work-list
        /// is built FROM those notes — one item per noted paragraph that still
        /// has a current translation — so a `FixNote` the report must answer
        /// is always a paragraph the model was shown. `nil` is "not a run"
        /// exactly as above; an empty work-list (no noted paragraph has a
        /// translation any more) is `nothingToTranslate`, which the pipeline
        /// records as a skip.
        var briefFix: @MainActor (String, String, [TranslatorBriefing.FixNote], Bool) async
            -> BriefedRound?
```

After `onRunEnded`:

```swift
        /// A click that turned out not to be a run — the briefing answered
        /// nil — named by the run id the verb returned. `onRunEnded` is
        /// deliberately NOT called for it (no state, no summary, no desk row);
        /// a caller sequencing on the run (`TranslationPipeline`) needs to
        /// hear it all the same, or it waits on a run that never started.
        var onRunAbandoned: @MainActor (String) -> Void = { _ in }
```

Add `ParagraphRewrite` beside `IngestOutcome`, and widen `IngestOutcome`:

```swift
    /// One paragraph a fix leg rewrote: the record that stood before the
    /// write and the one the write appended (`TranslationRound.Rewrite`'s
    /// source). Computed by ingest because ingest is the only thing that sees
    /// both sides of the write.
    struct ParagraphRewrite: Equatable, Sendable {
        let paragraphId: String
        let beforeRecordId: String?
        let before: String?
        let afterRecordId: String?
        let after: String?
    }

    struct IngestOutcome: Equatable, Sendable {
        let entriesWritten: Int
        let queriesMinted: Int
        let warnings: [String]
        let rejection: String?
        /// The fix report's own answers, carried whole so the pipeline can
        /// route them without re-parsing (empty / nil on a translate leg).
        let addressed: [String]
        let declined: [TranslatorReport.Declined]
        let summary: String?
        let glossaryProposals: [TranslatorReport.GlossaryProposal]
        let rewrites: [ParagraphRewrite]

        init(entriesWritten: Int = 0, queriesMinted: Int = 0,
             warnings: [String] = [], rejection: String? = nil,
             addressed: [String] = [], declined: [TranslatorReport.Declined] = [],
             summary: String? = nil,
             glossaryProposals: [TranslatorReport.GlossaryProposal] = [],
             rewrites: [ParagraphRewrite] = []) {
            self.entriesWritten = entriesWritten
            self.queriesMinted = queriesMinted
            self.warnings = warnings
            self.rejection = rejection
            self.addressed = addressed
            self.declined = declined
            self.summary = summary
            self.glossaryProposals = glossaryProposals
            self.rewrites = rewrites
        }
    }
```

(`TranslatorReport.Declined`/`.GlossaryProposal` are internal structs of `String`s, so `Sendable` is inferred; if the compiler disagrees, add `: Sendable` to both in `TranslatorReport.swift`.)

Replace `runTranslation` with the two verbs over one `start`:

```swift
    /// Run a translation for this document into this language. Returns the
    /// run id the summary will carry, or nil when refused — a run already in
    /// flight, or no environment.
    @discardableResult
    func runTranslation(docId: String, language: String) -> String? {
        start(pair: Pair(docId: docId, language: language)) { environment, pair in
            await environment.briefRound(pair.docId, pair.language)
        }
    }

    /// Run a FIX leg (spec §5, legs 3/5/7): the same run — identity first,
    /// then the briefing, then the warm session, then ingest through the one
    /// door — over a `.fix` briefing built from `notes`. Not `runTranslation`
    /// with a flag, because the two gathers answer different questions and
    /// the environment says which it is being asked.
    @discardableResult
    func runFix(docId: String, language: String,
                notes: [TranslatorBriefing.FixNote], isFinalLeg: Bool) -> String? {
        start(pair: Pair(docId: docId, language: language)) { environment, pair in
            await environment.briefFix(pair.docId, pair.language, notes, isFinalLeg)
        }
    }

    private func start(
        pair: Pair,
        brief: @escaping @MainActor (Environment, Pair) async -> BriefedRound?
    ) -> String? {
        guard let environment, !isRunning else { return nil }

        runGeneration &+= 1
        let generation = runGeneration
        let runId = ULID.generate()
        active = (generation, runId, pair)
        isPreparingRun = true

        Task { [weak self] in
            await self?.begin(pair: pair, runId: runId, generation: generation,
                              environment: environment, brief: brief)
        }
        return runId
    }
```

In `begin`: add the `brief:` parameter; replace `await environment.briefRound(pair.docId, pair.language)` with `await brief(environment, pair)`; replace `abandon()` with `abandon(runId: runId)`. Keep the doc comment's identity-then-briefing paragraph. Change `abandon`:

```swift
    private func abandon(runId: String) {
        isPreparingRun = false
        active = nil
        if case .running = runState { runState = .idle }
        environment?.onRunAbandoned(runId)
    }
```

- [ ] **Step 4: Run the suite** — `TranslatorOrchestratorTests` all green (the existing 24 plus the 4 new). Then `-only-testing:MaughamTests/TranslatorEnvironmentTests` and `DepartmentRunTests` still compile and pass (they construct the environment through `.production`, which Task 3 wires; until then add `briefFix: { _, _, _, _ in nil }` to `production`'s `Environment(...)` init so the tree builds — Task 3 replaces it).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/TranslatorOrchestrator.swift Maugham/Compiler/TranslatorEnvironment+Project.swift MaughamTests/TranslatorOrchestratorTests.swift
git commit -m "feat(translation-pipeline): runFix entry, briefFix seam, onRunAbandoned, run ids and fix fields on IngestOutcome"
```

---

### Task 3: The production `.fix` gather, rewrites at ingest, and a mint that reaches a closed document

**Files:**
- Modify: `Maugham/Compiler/TranslatorEnvironment+Project.swift`
- Test: `MaughamTests/TranslatorEnvironmentTests.swift`

**Interfaces:**
- Consumes: Task 2's `briefFix`, `IngestOutcome.rewrites` etc.
- Produces:
  - `production(...)` wires `briefFix` and takes `onRunAbandoned: @escaping @MainActor (String) -> Void = { _ in }`.
  - `static func fixBriefing(docId:language:notes:isFinalLeg:store:documentStore:bible:projectURL:) -> BriefedRound?` (internal, `@MainActor`).
  - The statics `craftIntentText`, `editionBriefText`, `neighbours`, `languageQueries`, `queryToolArgs` become internal (drop `private`) — Task 6's file calls them.
  - `mint` resolves its document through `withAnnotationDocument(store:projectURL:documentId:body:)`, so a closed document's queries land.

- [ ] **Step 1: Write the failing tests** (append to `TranslatorEnvironmentTests`; read the file's `makeHarness`, `context`, `records`, `queries` helpers first):

```swift
    // MARK: - The fix gather (Plan 3)

    private func seedTranslation(_ harness: Harness, paragraph index: Int,
                                 text: String, language: String = "es") throws {
        let id = harness.doc.sequence[index]
        _ = try TranslationWritePipeline.perform(
            entries: [.init(paragraphId: id, text: text, verbatim: nil, delete: nil)],
            language: language, documentId: harness.doc.docId,
            state: (harness.doc.sequence, harness.doc.paragraphs, harness.projectURL),
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current))
    }

    /// The `.fix` work-list is built FROM the notes: one `.fresh` item per
    /// noted paragraph carrying its current translation, in sequence order,
    /// and the mode's notes are exactly the ones whose paragraph made an item
    /// — a note whose paragraph has no current translation is dropped rather
    /// than briefed blind (a `FixNote` with no work item would make the
    /// report fail whole with no clue why).
    func test_theFixGatherBuildsTheWorkListFromTheNotesItBriefs() async throws {
        let harness = try await makeHarness()
        try seedTranslation(harness, paragraph: 0, text: "Llegó la niebla.")
        try seedTranslation(harness, paragraph: 2, text: "Nadie habló.")
        let ids = harness.doc.sequence
        let notes: [TranslatorBriefing.FixNote] = [
            .init(id: "n-last", paragraphId: ids[2], author: "Ocampo", kind: "rhythm",
                  severity: "minor", text: "Limps."),
            .init(id: "n-first", paragraphId: ids[0], author: "Ocampo", kind: "register",
                  severity: "major", text: "Wobbles."),
            .init(id: "n-untranslated", paragraphId: ids[1], author: "Ocampo",
                  kind: "grammar", severity: "minor", text: "No text here."),
        ]

        let round = try XCTUnwrap(await harness.environment.briefFix(
            harness.doc.docId, "es", notes, true))
        let inputs = round.inputs
        XCTAssertEqual(inputs.workList.map(\.paragraphId), [ids[0], ids[2]], "sequence order")
        XCTAssertEqual(inputs.workList.map(\.status), [.fresh, .fresh])
        XCTAssertEqual(inputs.workList.map(\.priorTranslation),
                       ["Llegó la niebla.", "Nadie habló."])
        guard case .fix(let briefed, let isFinal) = inputs.mode else {
            return XCTFail("a fix gather briefs in fix mode")
        }
        XCTAssertTrue(isFinal)
        XCTAssertEqual(briefed.map(\.id), ["n-last", "n-first"],
                       "the untranslated paragraph's note is not briefed")
        XCTAssertEqual(inputs.reportMode, .fix(briefedNoteIds: ["n-last", "n-first"]))
        XCTAssertEqual(Set(round.sourceHashes.keys), Set([ids[0], ids[2]]))
        XCTAssertTrue(TranslatorBriefing.compose(inputs: inputs)
                          .contains(TranslatorBriefing.repairSentence))
        await harness.documentStore.close()
    }

    /// No noted paragraph has a translation → an EMPTY work-list, not nil:
    /// the orchestrator reports `nothingToTranslate` and the pipeline records
    /// a skip, where nil would be an abandon with no leg to show for it.
    func test_aFixGatherWithNoBriefableNoteAnswersAnEmptyWorkList() async throws {
        let harness = try await makeHarness()
        let notes = [TranslatorBriefing.FixNote(
            id: "n1", paragraphId: harness.doc.sequence[0], author: "Ocampo",
            kind: "rhythm", severity: nil, text: "Limps.")]
        let round = try XCTUnwrap(await harness.environment.briefFix(
            harness.doc.docId, "es", notes, false))
        XCTAssertTrue(round.inputs.workList.isEmpty)
        await harness.documentStore.close()
    }

    /// Ingest reports what a fix leg rewrote — the record that stood before
    /// and the one it appended — and carries the report's own answers whole.
    func test_ingestReportsRewritesAndTheFixReportsAnswers() async throws {
        let harness = try await makeHarness()
        try seedTranslation(harness, paragraph: 0, text: "Llegó la niebla.")
        let id = harness.doc.sequence[0]
        let before = try XCTUnwrap(
            TranslationStore.latestByParagraph(records(harness))[id])
        let report = TranslatorReport(
            entries: [.init(paragraphId: id, text: "Vino la niebla.", verbatim: nil)],
            queries: [], addressed: ["n1"],
            declined: [.init(noteId: "n2", reason: "Deliberate.")],
            summary: "Two fixes.",
            glossaryProposals: [.init(term: "fog", rendering: "niebla", reason: "fixed")])

        let outcome = await harness.environment.ingest(report, context(harness))

        XCTAssertNil(outcome.rejection)
        XCTAssertEqual(outcome.addressed, ["n1"])
        XCTAssertEqual(outcome.declined.map(\.reason), ["Deliberate."])
        XCTAssertEqual(outcome.summary, "Two fixes.")
        XCTAssertEqual(outcome.glossaryProposals.map(\.rendering), ["niebla"])
        let rewrite = try XCTUnwrap(outcome.rewrites.first { $0.paragraphId == id })
        XCTAssertEqual(rewrite.beforeRecordId, before.opId)
        XCTAssertEqual(rewrite.before, "Llegó la niebla.")
        XCTAssertEqual(rewrite.after, "Vino la niebla.")
        XCTAssertNotEqual(rewrite.afterRecordId, before.opId)
        XCTAssertEqual(rewrite.afterRecordId,
                       TranslationStore.latestByParagraph(records(harness))[id]?.opId)
        await harness.documentStore.close()
    }

    /// A query on a document the window does not have open still lands — the
    /// book queue runs over closed chapters, and a question with nowhere to go
    /// was the one gap the single-chapter Run could afford.
    func test_aQueryOnAClosedDocumentStillLands() async throws {
        let harness = try await makeHarness()
        let docId = harness.doc.docId
        let paragraphId = harness.doc.sequence[1]
        await harness.documentStore.close()   // the window no longer holds it

        let report = TranslatorReport(
            entries: [], queries: [.init(paragraphId: paragraphId, text: "¿Usted o tú?")])
        let outcome = await harness.environment.ingest(report, context(harness))
        XCTAssertEqual(outcome.queriesMinted, 1)

        let reopened = try await Document.load(
            url: harness.projectURL.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s2", presenter: nil)
        let landed = reopened.annotations(filter: AnnotationFilter(statuses: nil))
        XCTAssertEqual(landed.map(\.body), ["¿Usted o tú?"])
        XCTAssertEqual(landed.first?.language, "es")
        _ = docId
    }
```

If an existing test in this file pins the OLD behaviour (a query on a closed document is dropped and logged — grep for `nowhere to land` / `no longer open`), rewrite it to the new expectation rather than keeping both.

- [ ] **Step 2: Run to verify it fails** — `briefFix` returns nil (Task 2's stub); `rewrites` empty; the closed-doc query is dropped.

- [ ] **Step 3: Implement**

In `production(...)`: add the parameter `onRunAbandoned: @escaping @MainActor (String) -> Void = { _ in }` (after `onRunEnded`), pass it through, and replace the stub with:

```swift
            briefFix: { [weak store, weak documentStore, weak bible] docId, language, notes, isFinalLeg in
                guard let store else { return nil }
                return fixBriefing(
                    docId: docId, language: language, notes: notes, isFinalLeg: isFinalLeg,
                    store: store, documentStore: documentStore, bible: bible,
                    projectURL: projectURL)
            },
```

Extract the common prefix of `briefing` into a private `RoundContext` so the two gathers cannot resolve the round differently:

```swift
    /// What both gathers resolve before they differ: the current paragraphs,
    /// the translator's stored row, the two statements, the directives, and
    /// the merged records with their derivation. `nil` is "not a run" for
    /// `briefing`'s two reasons.
    private struct RoundContext {
        let state: (sequence: [String], paragraphs: [String: String], projectURL: URL)
        let role: ProductionRole?
        let intentText: String?
        let briefText: String?
        let directives: [String: [Directive]]
        let latest: [String: TranslationRecord]
        let derived: TranslatedDocument
    }

    @MainActor
    private static func roundContext(
        docId: String, language: String, store: ProjectStore,
        documentStore: DocumentStore?, projectURL: URL
    ) -> RoundContext? {
        guard (try? TranslationWritePipeline.validate(language: language)) != nil else {
            translatorLog.error(
                "a translation run was asked for an unusable language tag: \(language, privacy: .public)")
            return nil
        }
        guard let state = try? currentParagraphState(
            documentId: docId, store: store, documentStore: documentStore, projectURL: projectURL)
        else {
            translatorLog.error(
                "a translation run found no current paragraphs for doc \(docId, privacy: .public)")
            return nil
        }
        let intentText = craftIntentText(docId: docId, store: store)
        let briefText = editionBriefText(language: language, store: store)
        let records = TranslationStore.loadMerged(forDocId: docId, language: language, in: projectURL)
        return RoundContext(
            state: state,
            role: store.manifest.storedTranslator(for: language),
            intentText: intentText, briefText: briefText,
            directives: Directives.byParagraph(
                Directives.gather(craftIntent: intentText, editionBrief: briefText)),
            latest: TranslationStore.latestByParagraph(records),
            derived: TranslationDeriver.derive(
                records: records, sequence: state.sequence,
                paragraphs: state.paragraphs, language: language))
    }
```

Rewrite `briefing` to build from `roundContext` (its body from "The delta is…" onward is unchanged, reading `context.derived`, `context.latest`, `context.directives`, `context.role`, `context.state`). Then add:

```swift
    /// **The fix leg's briefing** (spec §2, `.fix`): the work-list is exactly
    /// the noted paragraphs — those that still carry a FRESH translation —
    /// each `.fresh` with its current translation as `priorTranslation`, in
    /// sequence order; the mode's notes are the ones whose paragraph made an
    /// item. A note on a paragraph that is missing, stale (the writer edited
    /// the English mid-pipeline) or gone is dropped here rather than briefed
    /// blind — the parser would otherwise fail the whole leg for an id the
    /// model was never shown a paragraph for, with no clue why.
    @MainActor
    static func fixBriefing(
        docId: String, language: String, notes: [TranslatorBriefing.FixNote],
        isFinalLeg: Bool, store: ProjectStore, documentStore: DocumentStore?,
        bible: BibleStore?, projectURL: URL
    ) -> TranslatorOrchestrator.BriefedRound? {
        guard let context = roundContext(
            docId: docId, language: language, store: store,
            documentStore: documentStore, projectURL: projectURL) else { return nil }

        let noted = Set(notes.map(\.paragraphId))
        let work = context.derived.entries.filter {
            noted.contains($0.paragraphId) && $0.status == .fresh && $0.translatedText != nil
        }
        let briefable = Set(work.map(\.paragraphId))
        let briefedNotes = notes.filter { briefable.contains($0.paragraphId) }

        let workList = work.map { entry in
            TranslatorBriefing.Inputs.WorkItem(
                paragraphId: entry.paragraphId,
                sourceText: MarkdownDisplayFilter.stripTaskAnchorsInline(entry.sourceText),
                status: .fresh,
                priorTranslation: entry.translatedText,
                directives: (context.directives[entry.paragraphId] ?? []).map(\.text))
        }
        let (open, answered) = languageQueries(
            docId: docId, language: language, documentStore: documentStore)

        let inputs = TranslatorBriefing.Inputs(
            translatorName: context.role?.effectiveName
                ?? ProductionRole.defaultTranslatorName(language: language) ?? language,
            language: language,
            roleBrief: context.role?.effectiveBrief,
            craftIntentText: context.intentText,
            editionBriefText: context.briefText,
            workList: workList,
            contextParagraphs: neighbours(of: work.map(\.paragraphId), in: context.state),
            openQueries: open,
            answeredQueries: answered,
            bibleFacts: bible?.slice(matching: workList.map(\.sourceText)
                .joined(separator: "\n")) ?? [],
            mode: .fix(notes: briefedNotes, isFinalLeg: isFinalLeg),
            glossary: GlossaryTable.gather(editionBrief: context.briefText))

        let hashes = Dictionary(
            work.map { ($0.paragraphId, TranslationHash.hash(context.state.paragraphs[$0.paragraphId] ?? "")) },
            uniquingKeysWith: { first, _ in first })
        return TranslatorOrchestrator.BriefedRound(inputs: inputs, sourceHashes: hashes)
    }
```

In `ingest`: before the `TranslationWritePipeline.perform` call read `let before = TranslationStore.latestByParagraph(TranslationStore.loadMerged(forDocId: context.docId, language: context.language, in: projectURL))`; after a successful write read `after` the same way and build:

```swift
            rewrites = report.entries.map { entry in
                TranslatorOrchestrator.ParagraphRewrite(
                    paragraphId: entry.paragraphId,
                    beforeRecordId: before[entry.paragraphId]?.opId,
                    before: before[entry.paragraphId]?.text,
                    afterRecordId: after[entry.paragraphId]?.opId,
                    after: after[entry.paragraphId]?.text)
            }
```

and return `.init(entriesWritten:, queriesMinted:, warnings:, addressed: report.addressed, declined: report.declined, summary: report.summary, glossaryProposals: report.glossaryProposals, rewrites: rewrites)`.

In `mint`: replace the `documentStore?.document(forDocId:)` guard with `withAnnotationDocument(store:projectURL:documentId:body:)` — the signature gains `store: ProjectStore, projectURL: URL` (drop `documentStore`); the body inside the closure is the existing loop; a thrown load is logged with the existing sentence and returns 0. Update the doc comment: the closed-document gap is closed because the book queue runs over closed chapters. `languageQueries` (the gather's open-doc read) is unchanged.

Drop `private` from `craftIntentText`, `editionBriefText`, `neighbours`, `languageQueries`, `queryToolArgs`.

- [ ] **Step 4: Run `TranslatorEnvironmentTests`, `TranslatorOrchestratorTests`, `DepartmentRunTests`** — green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/TranslatorEnvironment+Project.swift MaughamTests/TranslatorEnvironmentTests.swift
git commit -m "feat(translation-pipeline): production fix gather builds the work-list from its notes; ingest reports rewrites; queries land on closed documents"
```

---

### Task 4: `TranslationPipeline` — the seven legs, skips, failure, the record

**Files:**
- Create: `Maugham/Compiler/TranslationPipeline.swift`
- Test: `MaughamTests/TranslationPipelineTests.swift`

**Interfaces:**
- Consumes: Task 1's `TranslationRound`, Task 2's orchestrator surface, P2's briefings/reports/`ColdCall` shapes.
- Produces (Task 5 adds Cancel/generation/book on the same type):

```swift
@Observable @MainActor final class TranslationPipeline {
    struct BookProgress: Equatable, Sendable { let position: Int; let count: Int }
    enum Status: Equatable, Sendable {
        case idle
        case running(docId: String, language: String, leg: TranslationRound.Leg, book: BookProgress?)
    }
    struct DeclinedMint: Equatable {
        struct Item: Equatable { let note: TranslatorBriefing.FixNote; let reason: String; let authorRoleId: String }
        let docId: String; let language: String; let translatorName: String; let items: [Item]
    }
    struct Environment {
        var model: String = CompilerOrchestrator.defaultModel
        var runTranslation: @MainActor (String, String) -> String?
        var runFix: @MainActor (String, String, [TranslatorBriefing.FixNote], Bool) -> String?
        var cancelTranslator: @MainActor () -> Void
        var translatorName: @MainActor (String) -> String
        var readerIdentity: @MainActor (String) async throws -> (name: String, roleId: String)
        var collatorIdentity: @MainActor (String) async throws -> (name: String, roleId: String)
        var briefReader: @MainActor (String, String) async -> ReaderBriefing.Inputs?
        var briefCollator: @MainActor (String, String) async -> CollatorBriefing.Inputs?
        var coldCall: @MainActor (String, String?, String) async -> CompilerRunEvent   // message, preamble, model
        var cancelColdCall: @MainActor () -> Void
        var mintDeclinedQueries: @MainActor (DeclinedMint) async -> [String: String]   // noteId → annotationId
        var nextRoundNumber: @MainActor (String) -> Int
        var saveRound: @MainActor (TranslationRound) -> Void
        var onRoundEnded: @MainActor (TranslationRound) -> Void
    }
    private(set) var status: Status
    var isRunning: Bool
    func configure(environment:)
    func updateModel(_:)
    @discardableResult func run(docId: String, language: String) -> Bool
    func translatorRunEnded(_ summary: TranslatorOrchestrator.RunSummary)
    func translatorRunAbandoned(_ runId: String)
    static let coldPreamble: String
    // reason/sentence statics: nothingToTranslateReason, nothingToReadReason, nothingChangedReason,
    // readerFoundNothingReason, collatorFoundNoDriftReason, noCurrentTranslationReason,
    // nothingWrittenReason, nothingToCollateReason, nothingToDoSummary, translatorRefusedSentence,
    // unbriefableSentence(role:), identitySentence(role:error:)
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/TranslationPipelineTests.swift
import XCTest
@testable import Maugham

/// **The pipeline over fake orchestrators** (spec §12): leg order, every skip
/// rule with its reason, failure stopping the rest and keeping earlier
/// writes, minting by id. Cancel, generation and the book queue are
/// `TranslationPipelineCancelTests`' (Task 5).
@MainActor
final class TranslationPipelineTests: XCTestCase {

    // MARK: - A scripted world

    /// Every closure the pipeline calls, answered from a script and recorded.
    /// Translator legs "end" on the next main-actor hop through the same
    /// `translatorRunEnded` the window wires — the orchestrator's own timing.
    @MainActor
    final class FakeWorld {
        let pipeline = TranslationPipeline()
        var translateOutcome: TranslatorOrchestrator.RunSummary.Outcome =
            .ingested(.init(entriesWritten: 2, queriesMinted: 1))
        /// What a fix leg answers, given what it was briefed. Default: address
        /// every note with a rewrite.
        var fixAnswer: ([TranslatorBriefing.FixNote], Bool) -> TranslatorOrchestrator.RunSummary.Outcome = { notes, isFinal in
            .ingested(.init(
                entriesWritten: notes.count, addressed: notes.map(\.id),
                summary: isFinal ? "Done." : nil,
                glossaryProposals: isFinal ? [.init(term: "fog", rendering: "niebla", reason: "fixed")] : [],
                rewrites: notes.map { .init(paragraphId: $0.paragraphId, beforeRecordId: "b",
                                            before: "old", afterRecordId: "a", after: "new") }))
        }
        var readerInputs: ReaderBriefing.Inputs? = ReaderBriefing.Inputs(
            readerName: "Ocampo", language: "es", authorLanguage: "English",
            paragraphs: [.init(paragraphId: "a1b2", translation: "Llegó la niebla."),
                         .init(paragraphId: "c3d4", translation: "Cerró la puerta.")])
        var collatorInputs: CollatorBriefing.Inputs? = CollatorBriefing.Inputs(
            collatorName: "Borges", language: "es", authorLanguage: "English",
            pairs: [.init(paragraphId: "a1b2", sourceText: "The fog came in.", translation: "Llegó la niebla."),
                    .init(paragraphId: "c3d4", sourceText: "She closed the door.", translation: "Cerró la puerta.")])
        /// Consumed per cold leg, in order (read, re-read, collate). A nil
        /// entry = the default report for that leg.
        var coldEvents: [CompilerRunEvent?] = [nil, nil, nil]
        var readerIdentity: (name: String, roleId: String) = ("Ocampo", "role-reader-es")
        var collatorIdentity: (name: String, roleId: String) = ("Borges", "role-collator-es")
        var nextNumber = 7
        var mintAnswer: (TranslationPipeline.DeclinedMint) -> [String: String] = { mint in
            Dictionary(uniqueKeysWithValues: mint.items.map { ($0.note.id, "ann-\($0.note.id)") })
        }

        private(set) var calls: [String] = []
        private(set) var briefedFixNotes: [[TranslatorBriefing.FixNote]] = []
        private(set) var coldMessages: [String] = []
        private(set) var mints: [TranslationPipeline.DeclinedMint] = []
        private(set) var saved: [TranslationRound] = []
        private(set) var ended: [TranslationRound] = []
        private var runs = 0
        private var coldIndex = 0

        static let readerReport = """
            {"overall":{"verdict":"mixed","text":"Reads well."},\
            "notes":[{"paragraph_id":"a1b2","kind":"rhythm","severity":"minor","text":"Limps."}]}
            """
        static let collatorReport = """
            {"overall":{"text":"Holds."},"departures":[\
            {"paragraph_id":"a1b2","verdict":"drifted","kind":"omission","note":"Lost a clause.","gloss":"The fog came."},\
            {"paragraph_id":"c3d4","verdict":"holds","kind":"rendering","note":"Split.","gloss":"She shut it."}]}
            """

        init() {
            pipeline.configure(environment: environment())
        }

        func environment() -> TranslationPipeline.Environment {
            TranslationPipeline.Environment(
                model: "test-model",
                runTranslation: { [unowned self] docId, language in
                    calls.append("translate")
                    return end(with: translateOutcome, docId: docId, language: language)
                },
                runFix: { [unowned self] docId, language, notes, isFinal in
                    calls.append("fix")
                    briefedFixNotes.append(notes)
                    return end(with: fixAnswer(notes, isFinal), docId: docId, language: language)
                },
                cancelTranslator: { [unowned self] in calls.append("cancelTranslator") },
                translatorName: { _ in "Cortázar" },
                readerIdentity: { [unowned self] _ in readerIdentity },
                collatorIdentity: { [unowned self] _ in collatorIdentity },
                briefReader: { [unowned self] _, _ in readerInputs },
                briefCollator: { [unowned self] _, _ in collatorInputs },
                coldCall: { [unowned self] message, _, _ in
                    calls.append("cold")
                    coldMessages.append(message)
                    let scripted = coldIndex < coldEvents.count ? coldEvents[coldIndex] : nil
                    coldIndex += 1
                    if let scripted { return scripted }
                    return .resultText(
                        message.contains("side by side") ? Self.collatorReport : Self.readerReport)
                },
                cancelColdCall: { [unowned self] in calls.append("cancelColdCall") },
                mintDeclinedQueries: { [unowned self] mint in
                    mints.append(mint)
                    return mintAnswer(mint)
                },
                nextRoundNumber: { [unowned self] _ in nextNumber },
                saveRound: { [unowned self] in saved.append($0) },
                onRoundEnded: { [unowned self] in ended.append($0) })
        }

        private func end(with outcome: TranslatorOrchestrator.RunSummary.Outcome,
                         docId: String, language: String) -> String {
            runs += 1
            let runId = "run-\(runs)"
            Task { [pipeline] in
                pipeline.translatorRunEnded(.init(
                    runId: runId, docId: docId, language: language, at: Date(), outcome: outcome))
            }
            return runId
        }
    }

    /// Spin the main actor until the round is saved (or fail after ~2s).
    /// Static so the cancel suite can share it without instantiating a case.
    static func settle(_ world: FakeWorld, rounds: Int = 1,
                       file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if world.saved.count >= rounds, world.pipeline.status == .idle { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the pipeline did not settle", file: file, line: line)
    }

    private func legs(_ round: TranslationRound) -> [(TranslationRound.Leg, TranslationRound.LegStatus)] {
        round.legs.map { ($0.leg, $0.status) }
    }

    // MARK: - Order and the record

    func test_theSevenLegsRunInOrderAndTheRoundRecordsEachOfThem() async throws {
        let world = FakeWorld()
        XCTAssertTrue(world.pipeline.run(docId: "doc-1", language: "es"))
        await Self.settle(world)

        XCTAssertEqual(world.calls, ["translate", "cold", "fix", "cold", "fix", "cold", "fix"])
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(round.number, 7)
        XCTAssertEqual(round.language, "es")
        XCTAssertEqual(round.docId, "doc-1")
        XCTAssertNotNil(round.endedAt)
        XCTAssertEqual(round.legs.map(\.leg), TranslationRound.Leg.allCases)
        XCTAssertTrue(round.legs.allSatisfy { $0.status == .ran })
        XCTAssertEqual(round.legs[0].counts, .init(entries: 2, queries: 1))
        XCTAssertEqual(round.leg2?.verdict, "mixed")
        XCTAssertEqual(round.leg4?.text, "Reads well.")
        XCTAssertEqual(round.collatorOverall, "Holds.")
        XCTAssertEqual(round.notes.map(\.leg), [.read, .reread])
        XCTAssertEqual(round.notes.map(\.author), ["Ocampo", "Ocampo"])
        XCTAssertEqual(round.departures.map(\.verdict), ["drifted", "holds"])
        XCTAssertEqual(round.summary, "Done.")
        XCTAssertEqual(round.glossaryProposals.map(\.term), ["fog"])
        XCTAssertEqual(round.glossaryProposals.first?.adopted, false)
        XCTAssertEqual(world.ended, [round])
        XCTAssertEqual(world.pipeline.status, .idle)
    }

    /// The ids the fix leg is briefed with are the record's own, minted
    /// before the leg — so `addressed` lands on the note it names, with the
    /// paragraph's before/after from the rewrite ingest reported.
    func test_noteIdsAreMintedBeforeTheFixLegAndAreWhatItsAnswersName() async throws {
        let world = FakeWorld()
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)

        XCTAssertEqual(world.briefedFixNotes.count, 3)
        XCTAssertEqual(world.briefedFixNotes[0].map(\.id), [round.notes[0].id])
        XCTAssertEqual(world.briefedFixNotes[0].first?.kind, "rhythm")
        XCTAssertEqual(world.briefedFixNotes[0].first?.severity, "minor")
        XCTAssertEqual(world.briefedFixNotes[1].map(\.id), [round.notes[1].id])
        XCTAssertEqual(world.briefedFixNotes[2].map(\.id), [round.departures[0].id],
                       "leg 7 is briefed with the DRIFTED departures only")
        XCTAssertNil(world.briefedFixNotes[2].first?.severity)
        XCTAssertTrue(world.briefedFixNotes[2].first?.text.contains("The fog came.") == true,
                      "a departure's fix note carries the gloss")
        XCTAssertEqual(round.notes[0].outcome,
                       .addressed(.init(beforeRecordId: "b", before: "old",
                                        afterRecordId: "a", after: "new")))
        XCTAssertEqual(round.departures[0].outcome,
                       .addressed(.init(beforeRecordId: "b", before: "old",
                                        afterRecordId: "a", after: "new")))
        XCTAssertNil(round.departures[1].outcome, "a holds departure is never fix work")
        XCTAssertEqual(round.legs[2].counts?.addressed, 1)
    }

    /// The reader is sent exactly the composed briefing, and its report is
    /// parsed against the ids it was briefed with.
    func test_theColdLegsSendTheComposedBriefings() async throws {
        let world = FakeWorld()
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        XCTAssertEqual(world.coldMessages[0],
                       ReaderBriefing.compose(inputs: try XCTUnwrap(world.readerInputs)))
        XCTAssertEqual(world.coldMessages[2],
                       CollatorBriefing.compose(inputs: try XCTUnwrap(world.collatorInputs)))
    }

    // MARK: - Skips, each with its reason

    func test_aReadWithNothingTranslatedSkipsAndSoDoesEverythingAfterIt() async throws {
        let world = FakeWorld()
        world.readerInputs = ReaderBriefing.Inputs(
            readerName: "Ocampo", language: "es", authorLanguage: "English",
            paragraphs: [.init(paragraphId: "a1b2", translation: nil)])
        world.translateOutcome = .nothingToTranslate
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)

        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(world.calls, ["translate"])
        XCTAssertEqual(round.legs.map(\.status), Array(repeating: .skipped, count: 7))
        XCTAssertEqual(round.legs[0].reason, TranslationPipeline.nothingToTranslateReason)
        XCTAssertEqual(round.legs[1].reason, TranslationPipeline.nothingToReadReason)
        XCTAssertEqual(round.legs[2].reason, TranslationPipeline.readerFoundNothingReason)
        XCTAssertEqual(round.legs[3].reason, TranslationPipeline.nothingChangedReason)
        XCTAssertEqual(round.legs[5].reason, TranslationPipeline.nothingWrittenReason)
        XCTAssertEqual(round.legs[6].reason, TranslationPipeline.collatorFoundNoDriftReason)
        XCTAssertEqual(round.summary, TranslationPipeline.nothingToDoSummary)
    }

    func test_aFixWithNoNotesIsASkipAndTheRereadSkipsBecauseNothingChanged() async throws {
        let world = FakeWorld()
        world.coldEvents = [.resultText(#"{"overall":{"verdict":"reads_as_native","text":"Fine."},"notes":[]}"#), nil, nil]
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)

        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(world.calls, ["translate", "cold", "cold", "fix"],
                       "leg 6 still collates because leg 1 wrote; leg 7 fixes its drift")
        XCTAssertEqual(legs(round).map(\.1),
                       [.ran, .ran, .skipped, .skipped, .skipped, .ran, .ran])
        XCTAssertEqual(round.legs[2].reason, TranslationPipeline.readerFoundNothingReason)
        XCTAssertEqual(round.legs[3].reason, TranslationPipeline.nothingChangedReason)
        XCTAssertEqual(round.legs[4].reason, TranslationPipeline.readerFoundNothingReason)
    }

    func test_aFixWhoseNotedParagraphsLostTheirTranslationIsRecordedAsASkip() async throws {
        let world = FakeWorld()
        world.fixAnswer = { _, _ in .nothingToTranslate }
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(round.legs[2].status, .skipped)
        XCTAssertEqual(round.legs[2].reason, TranslationPipeline.noCurrentTranslationReason)
        XCTAssertNil(round.notes[0].outcome, "a note the leg never reached has no outcome")
    }

    func test_collateSkipsWhenNothingWasWrittenEvenThoughTheReaderSpoke() async throws {
        let world = FakeWorld()
        world.translateOutcome = .nothingToTranslate
        world.fixAnswer = { notes, _ in
            .ingested(.init(entriesWritten: 0, declined: notes.map { .init(noteId: $0.id, reason: "Deliberate.") }))
        }
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(world.calls, ["translate", "cold", "fix"])
        XCTAssertEqual(round.legs[5].status, .skipped)
        XCTAssertEqual(round.legs[5].reason, TranslationPipeline.nothingWrittenReason)
        XCTAssertEqual(round.summary, TranslationPipeline.nothingToDoSummary)
    }

    // MARK: - Failure ends it there

    func test_aFailedLegEndsThePipelineThereAndKeepsEarlierLegs() async throws {
        let world = FakeWorld()
        world.coldEvents = [.failed(.sessionDied(detail: "boom")), nil, nil]
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)

        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(world.calls, ["translate", "cold"])
        XCTAssertEqual(legs(round).map(\.1), [.ran, .failed])
        XCTAssertEqual(round.legs[0].counts?.entries, 2, "leg 1's writes stay")
        XCTAssertEqual(round.legs[1].reason,
                       RoundNarrative.failureCopy(.sessionDied(detail: "boom"), session: .translation))
        XCTAssertEqual(round.stoppedAt, .read)
        XCTAssertNil(round.summary)
    }

    func test_anIngestRejectionIsAFailedLeg() async throws {
        let world = FakeWorld()
        world.translateOutcome = .ingested(.init(rejection: "paragraphs edited while this round was running: a1b2"))
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(legs(round).map(\.1), [.failed])
        XCTAssertEqual(round.legs[0].reason, "paragraphs edited while this round was running: a1b2")
    }

    func test_unusableReaderOutputFailsTheReadLeg() async throws {
        let world = FakeWorld()
        world.coldEvents = [.resultText("I would rather not."), nil, nil]
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(legs(round).map(\.1), [.ran, .failed])
        XCTAssertEqual(round.legs[1].reason,
                       RoundNarrative.failureCopy(.unusableOutput, session: .translation))
    }

    func test_aTranslatorThatRefusesToStartIsAFailedLeg() async throws {
        let world = FakeWorld()
        var environment = world.environment()
        environment.runTranslation = { _, _ in nil }
        world.pipeline.configure(environment: environment)
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(legs(round).map(\.1), [.failed])
        XCTAssertEqual(round.legs[0].reason, TranslationPipeline.translatorRefusedSentence)
    }

    func test_aReaderWhoCannotBeBriefedOrNamedIsAFailedLeg() async throws {
        let world = FakeWorld()
        world.readerInputs = nil
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        XCTAssertEqual(world.saved.first?.legs[1].reason,
                       TranslationPipeline.unbriefableSentence(role: "reader"))
    }

    // MARK: - Minting by id

    func test_declinedNotesAreMintedWithTheTranslatorsReasonAndRecorded() async throws {
        let world = FakeWorld()
        world.fixAnswer = { notes, isFinal in
            .ingested(.init(entriesWritten: 0,
                            declined: notes.map { .init(noteId: $0.id, reason: "Deliberate.") },
                            summary: isFinal ? "Nothing changed." : nil))
        }
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)

        // Leg 3 declined and wrote nothing, so leg 4 skips (nothing changed)
        // and leg 5 has no notes; leg 6 still collates because leg 1 wrote,
        // and leg 7 declines its one drifted departure: two mints.
        XCTAssertEqual(world.mints.count, 2)
        let first = world.mints[0]
        XCTAssertEqual(first.docId, "doc-1")
        XCTAssertEqual(first.language, "es")
        XCTAssertEqual(first.translatorName, "Cortázar")
        XCTAssertEqual(first.items.map(\.reason), ["Deliberate."])
        XCTAssertEqual(first.items.map(\.authorRoleId), ["role-reader-es"])
        XCTAssertEqual(world.mints[1].items.map(\.authorRoleId), ["role-collator-es"])
        XCTAssertEqual(round.notes[0].outcome,
                       .declined(reason: "Deliberate.", annotationId: "ann-\(round.notes[0].id)"))
        XCTAssertEqual(round.departures[0].outcome,
                       .declined(reason: "Deliberate.", annotationId: "ann-\(round.departures[0].id)"))
        XCTAssertEqual(round.legs[2].counts?.declined, 1)
    }

    func test_anAddressedNoteWithNoEntryIsRecordedWithTheTranslationUnchanged() async throws {
        let world = FakeWorld()
        world.fixAnswer = { notes, _ in
            .ingested(.init(entriesWritten: 0, addressed: notes.map(\.id)))
        }
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(round.notes[0].outcome,
                       .addressed(.init(beforeRecordId: nil, before: nil, afterRecordId: nil, after: nil)))
        XCTAssertTrue(world.mints.isEmpty)
    }

    func test_aSecondRunWhileOneIsRunningIsRefused() async throws {
        let world = FakeWorld()
        XCTAssertTrue(world.pipeline.run(docId: "doc-1", language: "es"))
        XCTAssertFalse(world.pipeline.run(docId: "doc-2", language: "es"))
        await Self.settle(world)
        XCTAssertEqual(world.saved.count, 1)
    }

    func test_anUnconfiguredPipelineRefuses() {
        XCTAssertFalse(TranslationPipeline().run(docId: "doc-1", language: "es"))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `./gen.sh`; compile error: `TranslationPipeline` undefined.

- [ ] **Step 3: Implement the pipeline**

```swift
// Maugham/Compiler/TranslationPipeline.swift
import Foundation
import MaughamCore
import os

private let pipelineLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "TranslationPipeline")

/// **One Run, seven legs** (translation pipeline spec §5). A state machine
/// and nothing else: it owns no session, gathers no briefing, parses no
/// translator report. It sequences legs by calling the translator's
/// orchestrator (`runTranslation`, `runFix`) and awaiting the `onRunEnded`/
/// `onRunAbandoned` the window feeds back in, and by calling `ColdCall` for
/// the reader and collator — whose raw text it turns into a `ReaderReport`/
/// `CollatorReport`, because `ColdCall` returns text and the report contract
/// is the caller's.
///
/// | Leg | Who | Input | Output |
/// |---|---|---|---|
/// | 1 translate | translator | stale ∪ missing ∪ directed | entries, queries |
/// | 2 read | reader | translated text, blind | notes + overall |
/// | 3 fix | translator | leg 2's notes | addressed/declined |
/// | 4 re-read | reader | the text again | notes + overall |
/// | 5 fix | translator | leg 4's notes | addressed/declined |
/// | 6 collate | collator | source + translation | departures + overall |
/// | 7 fix | translator | leg 6's `drifted` | addressed/declined, summary, proposals |
///
/// **Skips are recorded, never silent**; **a failing, rejected or cancelled
/// leg ends the round there**, earlier legs' writes stay; **Cancel** reaches
/// the live leg and the generation check catches a cancel in the gap;
/// **the book queue** runs the desk's document set through one round each.
/// Every outcome lands in one `TranslationRound` handed to `saveRound` —
/// the record is the pipeline's whole product.
///
/// **Note ids are minted here, before the fix leg is briefed**: a reader's
/// note or a collator's departure becomes a `TranslatorBriefing.FixNote`
/// whose `id` is the record's own, so `addressed`/`declined` name a row of
/// the record and nothing has to be matched by text afterwards.
///
/// **The owner must call `shutdown()` or `detach()`** on every window-ending
/// path — not for a process (it holds none) but for a leg awaiting a
/// translator summary that will never come once the orchestrator is shut
/// down: `shutdown()` resumes it as cancelled.
@Observable @MainActor
final class TranslationPipeline {

    struct BookProgress: Equatable, Sendable {
        let position: Int
        let count: Int
    }

    /// What the desk draws (Plan 4): idle, or which leg of which pair — and
    /// for a book queue, which chapter of how many.
    enum Status: Equatable, Sendable {
        case idle
        case running(docId: String, language: String, leg: TranslationRound.Leg,
                     book: BookProgress?)

        var language: String? {
            if case .running(_, let language, _, _) = self { return language }
            return nil
        }
    }

    /// What the environment mints a declined note as (spec §6): one `.query`
    /// per item, anchored to the note's paragraph, authored by the reader or
    /// collator (`note.author`, signed with `authorRoleId`), language-tagged,
    /// with the translator's reason in the body under the translator's name.
    struct DeclinedMint: Equatable {
        struct Item: Equatable {
            let note: TranslatorBriefing.FixNote
            let reason: String
            let authorRoleId: String
        }
        let docId: String
        let language: String
        let translatorName: String
        let items: [Item]
    }

    struct Environment {
        var model: String = CompilerOrchestrator.defaultModel
        /// `TranslatorOrchestrator.runTranslation` — the run id, or nil when refused.
        var runTranslation: @MainActor (String, String) -> String?
        /// `TranslatorOrchestrator.runFix(docId:language:notes:isFinalLeg:)`.
        var runFix: @MainActor (String, String, [TranslatorBriefing.FixNote], Bool) -> String?
        var cancelTranslator: @MainActor () -> Void
        /// The translator's display name for a language — read-only
        /// (`EditionStatus.translatorName`), for the declined mint's byline.
        var translatorName: @MainActor (String) -> String
        /// Find-or-create (`ProjectStore.readerRole/collatorRole(for:)`) — a
        /// run is the write act that earns the mint. Asked BEFORE the
        /// briefing, `TranslatorOrchestrator.begin`'s order, for its reason.
        var readerIdentity: @MainActor (String) async throws -> (name: String, roleId: String)
        var collatorIdentity: @MainActor (String) async throws -> (name: String, roleId: String)
        var briefReader: @MainActor (String, String) async -> ReaderBriefing.Inputs?
        var briefCollator: @MainActor (String, String) async -> CollatorBriefing.Inputs?
        /// `ColdCall.call(message:preamble:model:)`.
        var coldCall: @MainActor (String, String?, String) async -> CompilerRunEvent
        var cancelColdCall: @MainActor () -> Void
        /// Mints the declined notes as queries; answers note id → annotation id.
        var mintDeclinedQueries: @MainActor (DeclinedMint) async -> [String: String]
        var nextRoundNumber: @MainActor (String) -> Int
        var saveRound: @MainActor (TranslationRound) -> Void
        var onRoundEnded: @MainActor (TranslationRound) -> Void
    }

    // MARK: - Copy

    /// What governs a cold SESSION. Everything about who and what is in the
    /// briefing (`ReaderBriefing`/`CollatorBriefing`), which is re-sent whole
    /// every time — a second spelling here would be one the writer's doctrine
    /// could drift from.
    static let coldPreamble =
        "You are answering one question about one document for the writer of a "
        + "manuscript-in-progress. Everything you need is in the message: who you "
        + "are, the language, the writer's doctrine and the text. Answer with the "
        + "report the message describes and nothing else."

    static let nothingToTranslateReason = "nothing stale, missing or directed"
    static let nothingToReadReason = "nothing translated to read"
    static let nothingChangedReason = "nothing changed since the first read"
    static let readerFoundNothingReason = "the reader found nothing to fix"
    static let collatorFoundNoDriftReason = "the collator found no drift"
    static let noCurrentTranslationReason =
        "none of the noted paragraphs still has a current translation"
    static let nothingWrittenReason = "nothing was written this round"
    static let nothingToCollateReason = "nothing translated to collate"
    static let nothingToDoSummary = "Nothing to do \u{2014} nothing was written this round."
    static let translatorRefusedSentence = "The translator refused to start a leg."
    static func unbriefableSentence(role: String) -> String {
        "The \(role) could not be briefed on this document."
    }
    static func identitySentence(role: String, error: Error) -> String {
        "The \(role)'s identity could not be resolved: \(error)"
    }

    // MARK: - State

    private(set) var status: Status = .idle
    private var environment: Environment?
    /// Bumped by `cancel()`, `shutdown()` and every `run`; a leg resuming
    /// compares the generation it started under (`TranslatorOrchestrator
    /// .runGeneration`'s discipline, one owner up).
    private var generation = 0
    private var queue: [String] = []

    private enum TranslatorLegEnd {
        case refused
        case abandoned
        case ended(TranslatorOrchestrator.RunSummary)
    }
    /// The translator leg awaiting its summary. `runId` is nil for the
    /// instant between asking for the run and learning its id — a summary
    /// arriving in that instant is accepted, so a synchronous end cannot
    /// slip past.
    private var pending: (runId: String?, continuation: CheckedContinuation<TranslatorLegEnd, Never>)?
    private enum LiveKind { case translator, cold, gap }
    private var live: LiveKind = .gap

    var isRunning: Bool { status != .idle }

    func configure(environment: Environment) { self.environment = environment }

    func updateModel(_ model: String) { environment?.model = model }

    // MARK: - Entry

    /// One round on one pair. `false` when refused: nothing wired, or a round
    /// (or book) already running.
    @discardableResult
    func run(docId: String, language: String) -> Bool {
        start(queue: [docId], language: language)
    }

    private func start(queue documents: [String], language: String) -> Bool {
        guard let environment, !isRunning, !documents.isEmpty else { return false }
        generation &+= 1
        let gen = generation
        queue = documents
        let count = documents.count
        status = .running(docId: documents[0], language: language, leg: .translate,
                          book: count > 1 ? BookProgress(position: 1, count: count) : nil)
        Task { [weak self] in
            await self?.execute(language: language, count: count, generation: gen,
                                environment: environment)
        }
        return true
    }

    private func execute(language: String, count: Int, generation gen: Int,
                         environment: Environment) async {
        var position = 0
        while generation == gen, !queue.isEmpty {
            let docId = queue.removeFirst()
            position += 1
            let book = count > 1 ? BookProgress(position: position, count: count) : nil
            let round = await runRound(docId: docId, language: language, book: book,
                                       generation: gen, environment: environment)
            // A failed or cancelled round stops a book queue: the next chapter
            // would meet the same session, and the author should see this one.
            if round.stoppedAt != nil { break }
        }
        if generation == gen {
            queue = []
            status = .idle
        }
    }

    // MARK: - The translator's summary, fed back by the window

    func translatorRunEnded(_ summary: TranslatorOrchestrator.RunSummary) {
        guard let pending, pending.runId == nil || pending.runId == summary.runId else { return }
        self.pending = nil
        pending.continuation.resume(returning: .ended(summary))
    }

    func translatorRunAbandoned(_ runId: String) {
        guard let pending, pending.runId == nil || pending.runId == runId else { return }
        self.pending = nil
        pending.continuation.resume(returning: .abandoned)
    }

    // MARK: - One round

    private enum LegResult {
        case ran(TranslationRound.LegCounts)
        case skipped(String)
        case failed(String)
        case cancelled
    }

    private func runRound(docId: String, language: String, book: BookProgress?,
                          generation gen: Int, environment env: Environment) async -> TranslationRound {
        var round = TranslationRound(number: env.nextRoundNumber(language), language: language,
                                     docId: docId, startedAt: Date())
        var wroteAnything = false
        var reader: (name: String, roleId: String)?
        var collator: (name: String, roleId: String)?
        var leg3Wrote = false
        var leg2Notes: [TranslatorBriefing.FixNote] = []
        var leg4Notes: [TranslatorBriefing.FixNote] = []
        var driftNotes: [TranslatorBriefing.FixNote] = []

        func record(_ leg: TranslationRound.Leg, _ result: LegResult) -> Bool {
            switch result {
            case .ran(let counts):
                round.legs.append(.init(leg: leg, status: .ran, counts: counts))
                return true
            case .skipped(let reason):
                round.legs.append(.init(leg: leg, status: .skipped, reason: reason))
                return true
            case .failed(let sentence):
                round.legs.append(.init(leg: leg, status: .failed, reason: sentence))
                return false
            case .cancelled:
                round.legs.append(.init(leg: leg, status: .cancelled))
                return false
            }
        }

        legs: for leg in TranslationRound.Leg.allCases {
            guard generation == gen else {
                // A cancel or shutdown landed in the gap: this leg never starts.
                round.legs.append(.init(leg: leg, status: .cancelled))
                break
            }
            status = .running(docId: docId, language: language, leg: leg, book: book)
            let result: LegResult
            switch leg {
            case .translate:
                result = await translatorLeg(
                    generation: gen, skipReason: Self.nothingToTranslateReason,
                    start: { env.runTranslation(docId, language) },
                    onIngested: { outcome in
                        wroteAnything = wroteAnything || outcome.entriesWritten > 0
                    })

            case .read, .reread:
                if leg == .reread, !leg3Wrote {
                    result = .skipped(Self.nothingChangedReason)
                    break
                }
                let read = await readerLeg(leg, docId: docId, language: language,
                                           identity: &reader, generation: gen, environment: env)
                result = read.result
                if let report = read.report {
                    let record = TranslationRound.ReaderReportRecord(
                        verdict: report.overall.verdict.rawValue, text: report.overall.text)
                    if leg == .read { round.leg2 = record } else { round.leg4 = record }
                    let notes = report.notes.map { note in
                        TranslationRound.NoteRecord(
                            id: ULID.generate(), leg: leg, author: reader?.name ?? "",
                            paragraphId: note.paragraphId, kind: note.kind.rawValue,
                            severity: note.severity.rawValue, text: note.text)
                    }
                    round.notes.append(contentsOf: notes)
                    let fixNotes = notes.map { $0.fixNote }
                    if leg == .read { leg2Notes = fixNotes } else { leg4Notes = fixNotes }
                }

            case .fix, .fixAgain, .finalFix:
                let notes = leg == .fix ? leg2Notes : leg == .fixAgain ? leg4Notes : driftNotes
                guard !notes.isEmpty else {
                    result = .skipped(leg == .finalFix ? Self.collatorFoundNoDriftReason
                                                       : Self.readerFoundNothingReason)
                    break
                }
                let authorRoleId = leg == .finalFix ? (collator?.roleId ?? "") : (reader?.roleId ?? "")
                var fixOutcome: TranslatorOrchestrator.IngestOutcome?
                result = await translatorLeg(
                    generation: gen, skipReason: Self.noCurrentTranslationReason,
                    start: { env.runFix(docId, language, notes, leg == .finalFix) },
                    onIngested: { fixOutcome = $0 })
                if let outcome = fixOutcome {
                    wroteAnything = wroteAnything || outcome.entriesWritten > 0
                    if leg == .fix { leg3Wrote = outcome.entriesWritten > 0 }
                    let annotationIds: [String: String]
                    if outcome.declined.isEmpty {
                        annotationIds = [:]
                    } else {
                        let byId = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
                        annotationIds = await env.mintDeclinedQueries(DeclinedMint(
                            docId: docId, language: language,
                            translatorName: env.translatorName(language),
                            items: outcome.declined.compactMap { declined in
                                byId[declined.noteId].map {
                                    .init(note: $0, reason: declined.reason, authorRoleId: authorRoleId)
                                }
                            }))
                        guard generation == gen else {
                            _ = record(leg, .cancelled)
                            break legs
                        }
                    }
                    applyFixOutcomes(outcome, annotationIds: annotationIds, notes: notes, to: &round)
                    if leg == .finalFix {
                        round.summary = outcome.summary
                        round.glossaryProposals = outcome.glossaryProposals.map {
                            .init(term: $0.term, rendering: $0.rendering, reason: $0.reason, adopted: false)
                        }
                    }
                }

            case .collate:
                guard wroteAnything else {
                    result = .skipped(Self.nothingWrittenReason)
                    break
                }
                let collated = await collatorLeg(docId: docId, language: language,
                                                 identity: &collator, generation: gen, environment: env)
                result = collated.result
                if let report = collated.report {
                    round.collatorOverall = report.overall
                    let records = report.departures.map { departure in
                        TranslationRound.DepartureRecord(
                            id: ULID.generate(), paragraphId: departure.paragraphId,
                            verdict: departure.verdict.rawValue, kind: departure.kind.rawValue,
                            note: departure.note, gloss: departure.gloss)
                    }
                    round.departures = records
                    driftNotes = records.filter { $0.verdict == CollatorReport.Verdict.drifted.rawValue }
                        .map { $0.fixNote(author: collator?.name ?? "") }
                }
            }
            if !record(leg, result) { break }
        }

        if !wroteAnything, round.stoppedAt == nil, round.summary == nil {
            round.summary = Self.nothingToDoSummary
        }
        round.endedAt = Date()
        live = .gap
        env.saveRound(round)
        env.onRoundEnded(round)
        return round
    }

    /// Route `addressed`/`declined` onto the record rows the fix leg was
    /// briefed with — notes for legs 3/5, departures for leg 7.
    private func applyFixOutcomes(_ outcome: TranslatorOrchestrator.IngestOutcome,
                                  annotationIds: [String: String],
                                  notes: [TranslatorBriefing.FixNote],
                                  to round: inout TranslationRound) {
        let rewrites = Dictionary(outcome.rewrites.map { ($0.paragraphId, $0) },
                                  uniquingKeysWith: { first, _ in first })
        func rewrite(for paragraphId: String) -> TranslationRound.Rewrite {
            let r = rewrites[paragraphId]
            return .init(beforeRecordId: r?.beforeRecordId, before: r?.before,
                         afterRecordId: r?.afterRecordId, after: r?.after)
        }
        let declined = Dictionary(outcome.declined.map { ($0.noteId, $0.reason) },
                                  uniquingKeysWith: { first, _ in first })
        for index in round.notes.indices {
            let note = round.notes[index]
            if outcome.addressed.contains(note.id) {
                round.notes[index].outcome = .addressed(rewrite(for: note.paragraphId))
            } else if let reason = declined[note.id] {
                round.notes[index].outcome = .declined(reason: reason, annotationId: annotationIds[note.id])
            }
        }
        for index in round.departures.indices {
            let departure = round.departures[index]
            if outcome.addressed.contains(departure.id) {
                round.departures[index].outcome = .addressed(rewrite(for: departure.paragraphId))
            } else if let reason = declined[departure.id] {
                round.departures[index].outcome = .declined(reason: reason, annotationId: annotationIds[departure.id])
            }
        }
    }

    // MARK: - Legs

    /// A translator leg: ask for the run, await the summary the window feeds
    /// back, map it. `skipReason` is what `nothingToTranslate` means for THIS
    /// leg. A cancel arriving mid-leg lands here as a `.cancelled` summary
    /// (the orchestrator's own vocabulary) — and if the generation moved, as
    /// cancelled regardless of what the summary says.
    private func translatorLeg(
        generation gen: Int, skipReason: String,
        start: @MainActor () -> String?,
        onIngested: (TranslatorOrchestrator.IngestOutcome) -> Void
    ) async -> LegResult {
        live = .translator
        let end: TranslatorLegEnd = await withCheckedContinuation { continuation in
            pending = (nil, continuation)
            guard let runId = start() else {
                pending = nil
                continuation.resume(returning: .refused)
                return
            }
            pending?.runId = runId
        }
        live = .gap
        guard generation == gen else { return .cancelled }
        switch end {
        case .refused: return .failed(Self.translatorRefusedSentence)
        case .abandoned: return .failed(Self.unbriefableSentence(role: "translator"))
        case .ended(let summary):
            switch summary.outcome {
            case .ingested(let outcome):
                if let rejection = outcome.rejection { return .failed(rejection) }
                onIngested(outcome)
                return .ran(.init(entries: outcome.entriesWritten, queries: outcome.queriesMinted,
                                  addressed: outcome.addressed.count,
                                  declined: outcome.declined.count))
            case .nothingToTranslate: return .skipped(skipReason)
            case .cancelled: return .cancelled
            case .failed(let failure): return .failed(DepartmentRunState.failureCopy(failure))
            }
        }
    }

    private enum ColdEnd {
        case text(String)
        case failed(String)
        case cancelled
    }

    private func coldLeg(message: String, generation gen: Int,
                         environment env: Environment) async -> ColdEnd {
        live = .cold
        let event = await env.coldCall(message, Self.coldPreamble, env.model)
        live = .gap
        guard generation == gen else { return .cancelled }
        switch event {
        case .resultText(let text): return .text(text)
        case .failed(let failure):
            return failure.isTheWritersOwnDoing
                ? .cancelled
                : .failed(RoundNarrative.failureCopy(failure, session: .translation))
        case .started:
            return .failed(RoundNarrative.failureCopy(.unusableOutput, session: .translation))
        }
    }

    private func readerLeg(
        _ leg: TranslationRound.Leg, docId: String, language: String,
        identity: inout (name: String, roleId: String)?, generation gen: Int,
        environment env: Environment
    ) async -> (result: LegResult, report: ReaderReport?) {
        if identity == nil {
            do { identity = try await env.readerIdentity(language) } catch {
                guard generation == gen else { return (.cancelled, nil) }
                return (.failed(Self.identitySentence(role: "reader", error: error)), nil)
            }
            guard generation == gen else { return (.cancelled, nil) }
        }
        guard let inputs = await env.briefReader(docId, language) else {
            guard generation == gen else { return (.cancelled, nil) }
            return (.failed(Self.unbriefableSentence(role: "reader")), nil)
        }
        guard generation == gen else { return (.cancelled, nil) }
        guard !inputs.briefedParagraphIds.isEmpty else {
            return (.skipped(Self.nothingToReadReason), nil)
        }
        switch await coldLeg(message: ReaderBriefing.compose(inputs: inputs),
                             generation: gen, environment: env) {
        case .cancelled: return (.cancelled, nil)
        case .failed(let sentence): return (.failed(sentence), nil)
        case .text(let text):
            guard let report = ReaderReport.parse(text, briefedParagraphIds: inputs.briefedParagraphIds) else {
                return (.failed(RoundNarrative.failureCopy(.unusableOutput, session: .translation)), nil)
            }
            return (.ran(.init(notes: report.notes.count)), report)
        }
    }

    private func collatorLeg(
        docId: String, language: String,
        identity: inout (name: String, roleId: String)?, generation gen: Int,
        environment env: Environment
    ) async -> (result: LegResult, report: CollatorReport?) {
        if identity == nil {
            do { identity = try await env.collatorIdentity(language) } catch {
                guard generation == gen else { return (.cancelled, nil) }
                return (.failed(Self.identitySentence(role: "collator", error: error)), nil)
            }
            guard generation == gen else { return (.cancelled, nil) }
        }
        guard let inputs = await env.briefCollator(docId, language) else {
            guard generation == gen else { return (.cancelled, nil) }
            return (.failed(Self.unbriefableSentence(role: "collator")), nil)
        }
        guard generation == gen else { return (.cancelled, nil) }
        guard !inputs.briefedParagraphIds.isEmpty else {
            return (.skipped(Self.nothingToCollateReason), nil)
        }
        switch await coldLeg(message: CollatorBriefing.compose(inputs: inputs),
                             generation: gen, environment: env) {
        case .cancelled: return (.cancelled, nil)
        case .failed(let sentence): return (.failed(sentence), nil)
        case .text(let text):
            guard let report = CollatorReport.parse(text, briefedParagraphIds: inputs.briefedParagraphIds) else {
                return (.failed(RoundNarrative.failureCopy(.unusableOutput, session: .translation)), nil)
            }
            return (.ran(.init(departures: report.departures.count)), report)
        }
    }

    // MARK: - Cancel and shutdown (completed in Task 5)

    func cancel() {}
    func shutdown() {}
    func detach() {}
}

extension TranslationRound.NoteRecord {
    /// The note as the fix leg is briefed with it — same id.
    var fixNote: TranslatorBriefing.FixNote {
        .init(id: id, paragraphId: paragraphId, author: author, kind: kind,
              severity: severity, text: text)
    }
}

extension TranslationRound.DepartureRecord {
    /// A departure as a fix note: the collator's reason and the gloss, so
    /// the translator sees what the author will judge it by.
    func fixNote(author: String) -> TranslatorBriefing.FixNote {
        .init(id: id, paragraphId: paragraphId, author: author, kind: kind, severity: nil,
              text: "\(note) The translation now says: \(gloss)")
    }
}
```

The inout-through-async pattern (`identity: &reader`) is fine on a `@MainActor` method with local vars; if the compiler objects to the `inout` across suspension, return the identity from `readerLeg` as a third tuple element instead and assign it in the caller.

- [ ] **Step 4: Run `TranslationPipelineTests`** — green. Also `TripwireGrepTests` (`test_theOnlySealedSpawnerIsColdCall`, `test_coldCallNeverBridges`).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/TranslationPipeline.swift MaughamTests/TranslationPipelineTests.swift
git commit -m "feat(translation-pipeline): TranslationPipeline — seven legs, skips recorded, failure ends it, note ids minted before the fix leg"
```

---

### Task 5: Cancel, the gap, shutdown, and the book queue

**Files:**
- Modify: `Maugham/Compiler/TranslationPipeline.swift`
- Test: `MaughamTests/TranslationPipelineCancelTests.swift`

**Interfaces:**
- Produces: `cancel()`, `shutdown()`, `detach()`, `@discardableResult func runBook(documentIds: [String], language: String) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/TranslationPipelineCancelTests.swift
import XCTest
@testable import Maugham

/// Cancel mid-leg and in the gap, shutdown, generation discipline, and the
/// book queue (spec §5, §12). Uses `TranslationPipelineTests.FakeWorld` with
/// its legs held open.
@MainActor
final class TranslationPipelineCancelTests: XCTestCase {

    typealias FakeWorld = TranslationPipelineTests.FakeWorld

    /// A world whose translator legs and cold legs can be HELD until the test
    /// releases them — so a cancel has something in flight to reach.
    @MainActor
    private final class HeldWorld {
        let world = FakeWorld()
        var holdTranslator = false
        /// A predicate rather than a flag, so a test can hold the cold call
        /// of the SECOND chapter of a book queue without racing the first.
        var holdCold: () -> Bool = { false }
        var holdReaderBriefing = false
        private(set) var heldRunId: String?
        private var heldCold: CheckedContinuation<CompilerRunEvent, Never>?
        private var heldBriefing: CheckedContinuation<Void, Never>?
        private(set) var cancels: [String] = []
        private var runs = 0

        init() {
            var environment = world.environment()
            let base = environment
            environment.runTranslation = { [unowned self] docId, language in
                if holdTranslator {
                    runs += 1
                    heldRunId = "held-\(runs)"
                    return heldRunId
                }
                return base.runTranslation(docId, language)
            }
            environment.cancelTranslator = { [unowned self] in
                cancels.append("translator")
                if let runId = heldRunId {
                    heldRunId = nil
                    world.pipeline.translatorRunEnded(.init(
                        runId: runId, docId: "doc-1", language: "es", at: Date(), outcome: .cancelled))
                }
            }
            environment.coldCall = { [unowned self] message, preamble, model in
                if holdCold() {
                    return await withCheckedContinuation { heldCold = $0 }
                }
                return await base.coldCall(message, preamble, model)
            }
            environment.cancelColdCall = { [unowned self] in
                cancels.append("cold")
                let held = heldCold
                heldCold = nil
                held?.resume(returning: .failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
            }
            environment.briefReader = { [unowned self] docId, language in
                if holdReaderBriefing {
                    await withCheckedContinuation { heldBriefing = $0 }
                }
                return await base.briefReader(docId, language)
            }
            world.pipeline.configure(environment: environment)
        }

        func releaseBriefing() {
            let held = heldBriefing
            heldBriefing = nil
            held?.resume()
        }

        func waitFor(_ predicate: @escaping () -> Bool) async {
            for _ in 0..<200 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("condition never held")
        }
    }

    func test_cancelDuringATranslatorLegReachesTheTranslatorAndEndsTheRound() async throws {
        let held = HeldWorld()
        held.holdTranslator = true
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.heldRunId != nil }
        XCTAssertEqual(held.world.pipeline.status,
                       .running(docId: "doc-1", language: "es", leg: .translate, book: nil))

        held.world.pipeline.cancel()
        await TranslationPipelineTests.settle(held.world)

        XCTAssertEqual(held.cancels, ["translator"])
        let round = try XCTUnwrap(held.world.saved.first)
        XCTAssertEqual(round.legs.map(\.status), [.cancelled])
        XCTAssertNil(round.summary)
        XCTAssertEqual(held.world.calls, ["translate"], "nothing later starts")
    }

    func test_cancelDuringAColdLegReachesTheColdCall() async throws {
        let held = HeldWorld()
        held.holdCold = { true }
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.world.calls == ["translate", "cold"] }
        await held.waitFor { held.world.pipeline.status.leg == .read }

        held.world.pipeline.cancel()
        await TranslationPipelineTests.settle(held.world)

        XCTAssertEqual(held.cancels, ["cold"])
        let round = try XCTUnwrap(held.world.saved.first)
        XCTAssertEqual(round.legs.map(\.status), [.ran, .cancelled])
        XCTAssertEqual(round.legs[0].counts?.entries, 2, "leg 1's writes stay")
        XCTAssertEqual(round.stoppedAt, .read)
    }

    /// A cancel in the GAP — nothing in flight, the next leg's briefing being
    /// gathered — stops the pipeline by generation rather than a leg that
    /// never started: no cold call is made after it.
    func test_cancelInTheGapStopsThePipelineWithoutStartingTheNextLeg() async throws {
        let held = HeldWorld()
        held.holdReaderBriefing = true
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.world.calls == ["translate"] && held.world.pipeline.status.leg == .read }
        try? await Task.sleep(nanoseconds: 30_000_000)   // let the gather start and hold

        held.world.pipeline.cancel()
        held.releaseBriefing()
        await TranslationPipelineTests.settle(held.world)

        XCTAssertTrue(held.cancels.isEmpty, "nothing was in flight to cancel")
        XCTAssertEqual(held.world.calls, ["translate"], "the read leg never sent")
        let round = try XCTUnwrap(held.world.saved.first)
        XCTAssertEqual(round.legs.map(\.status), [.ran, .cancelled])
    }

    func test_shutdownMidTranslatorLegSavesACancelledRoundAndGoesIdle() async throws {
        let held = HeldWorld()
        held.holdTranslator = true
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.heldRunId != nil }

        held.world.pipeline.shutdown()   // the orchestrator's own shutdown emits no summary
        await TranslationPipelineTests.settle(held.world)

        XCTAssertEqual(held.world.pipeline.status, .idle)
        XCTAssertEqual(held.world.saved.first?.legs.map(\.status), [.cancelled])
        held.holdTranslator = false
        XCTAssertTrue(held.world.pipeline.run(docId: "doc-1", language: "es"),
                      "shutdown keeps the environment; the next click works")
        await TranslationPipelineTests.settle(held.world, rounds: 2)
    }

    func test_detachDropsTheEnvironmentAndRefusesTheNextRun() {
        let world = FakeWorld()
        world.pipeline.detach()
        XCTAssertFalse(world.pipeline.run(docId: "doc-1", language: "es"))
    }

    func test_aSummaryForAnotherRunIsIgnored() async throws {
        let held = HeldWorld()
        held.holdTranslator = true
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.heldRunId != nil }
        held.world.pipeline.translatorRunEnded(.init(
            runId: "somebody-elses", docId: "doc-1", language: "es", at: Date(),
            outcome: .ingested(.init(entriesWritten: 9))))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(held.world.pipeline.status.leg, .translate, "still waiting on its own run")
        held.world.pipeline.cancel()
        await TranslationPipelineTests.settle(held.world)
    }

    // MARK: - The book queue

    func test_theBookQueueRunsEveryChapterInOrderWithConsecutiveNumbers() async throws {
        let world = FakeWorld()
        var number = 3
        var environment = world.environment()
        environment.nextRoundNumber = { _ in defer { number += 1 }; return number }
        world.pipeline.configure(environment: environment)

        XCTAssertTrue(world.pipeline.runBook(documentIds: ["doc-1", "doc-2", "doc-3"], language: "es"))
        XCTAssertEqual(world.pipeline.status,
                       .running(docId: "doc-1", language: "es", leg: .translate,
                                book: .init(position: 1, count: 3)))
        await TranslationPipelineTests.settle(world, rounds: 3)

        XCTAssertEqual(world.saved.map(\.docId), ["doc-1", "doc-2", "doc-3"])
        XCTAssertEqual(world.saved.map(\.number), [3, 4, 5])
        XCTAssertEqual(world.ended.count, 3)
        XCTAssertEqual(world.pipeline.status, .idle)
    }

    func test_cancelStopsTheBookQueueAfterTheLiveLeg() async throws {
        let held = HeldWorld()
        // Hold chapter 2's first cold call — decided at the call, so chapter
        // 1's three cold legs run free and there is no race to set a flag in.
        held.holdCold = { held.world.saved.count == 1 }
        held.world.pipeline.runBook(documentIds: ["doc-1", "doc-2", "doc-3"], language: "es")
        await held.waitFor { held.world.pipeline.status == .running(docId: "doc-2", language: "es", leg: .read, book: .init(position: 2, count: 3)) }
        await held.waitFor { held.world.calls.count == 5 }   // 4 from chapter 1 (translate, 3 cold) + chapter 2's translate, then its held cold

        held.world.pipeline.cancel()
        await TranslationPipelineTests.settle(held.world, rounds: 2)

        XCTAssertEqual(held.world.saved.map(\.docId), ["doc-1", "doc-2"])
        XCTAssertTrue(held.world.saved[1].wasCancelled)
        XCTAssertEqual(held.world.pipeline.status, .idle)
    }

    func test_aFailedRoundStopsTheBookQueue() async throws {
        let world = FakeWorld()
        world.coldEvents = [nil, nil, nil, .failed(.sessionDied(detail: "boom"))]   // chapter 2's read
        world.pipeline.runBook(documentIds: ["doc-1", "doc-2", "doc-3"], language: "es")
        await TranslationPipelineTests.settle(world, rounds: 2)
        XCTAssertEqual(world.saved.map(\.docId), ["doc-1", "doc-2"])
        XCTAssertEqual(world.saved[1].stoppedAt, .read)
    }

    func test_anEmptyBookIsRefused() {
        XCTAssertFalse(FakeWorld().pipeline.runBook(documentIds: [], language: "es"))
    }
}

private extension TranslationPipeline.Status {
    var leg: TranslationRound.Leg? {
        if case .running(_, _, let leg, _) = self { return leg }
        return nil
    }
}
```

`FakeWorld` and `settle` must be non-private in `TranslationPipelineTests` (they are `final class FakeWorld` and `func settle` above — keep them internal).

- [ ] **Step 2: Run to verify it fails** — `runBook` undefined; cancel tests hang/fail (the stubs do nothing; `settle` fails after 2s).

- [ ] **Step 3: Implement**

Replace the three stubs and add `runBook`:

```swift
    /// One round per document, in the order given — the desk's imprint set
    /// (`EditionStatus.languageRows(documentIds:)`'s), which the caller
    /// resolves. Same gate as `run`.
    @discardableResult
    func runBook(documentIds: [String], language: String) -> Bool {
        start(queue: documentIds, language: language)
    }

    // MARK: - Cancel and shutdown

    /// One button, whichever leg is live (spec §5): the translator's
    /// `cancel()` covers unsent and in-flight; `ColdCall`'s covers a cold
    /// leg; a cancel in the gap is caught by the generation check before the
    /// next leg starts. The round in flight is recorded where it stopped and
    /// the book queue, if any, stops after it.
    func cancel() {
        guard isRunning else { return }
        generation &+= 1
        queue = []
        switch live {
        case .translator: environment?.cancelTranslator()
        case .cold: environment?.cancelColdCall()
        case .gap: break
        }
    }

    /// The window closing, project close, app quit, the AI toggle. The
    /// orchestrators are shut down beside this and emit no summary for a
    /// turn cut short, so the translator leg awaiting one is resumed here as
    /// cancelled — otherwise the round would never be recorded.
    func shutdown() {
        generation &+= 1
        queue = []
        if let pending {
            self.pending = nil
            pending.continuation.resume(returning: .ended(.init(
                runId: pending.runId ?? "", docId: "", language: "", at: Date(),
                outcome: .cancelled)))
        }
        status = .idle
    }

    func detach() {
        shutdown()
        environment = nil
    }
```

In `execute`, the trailing `if generation == gen` guard already keeps a shut-down pipeline from reviving `status`; after `shutdown()` the round loop still saves its cancelled round (the `saveRound` closure's weak captures decide whether there is anything to write to). In `runRound`, `guard generation == gen` after every `await` is what makes a mid-leg cancel land as `.cancelled` — audit that every `await` in the file is followed by one (the leg helpers above do).

- [ ] **Step 4: Run both pipeline suites** — green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/TranslationPipeline.swift MaughamTests/TranslationPipelineCancelTests.swift
git commit -m "feat(translation-pipeline): Cancel reaches the live leg, the gap is generation-checked, shutdown records, the book queue"
```

---

### Task 6: The pipeline's production environment

**Files:**
- Create: `Maugham/Compiler/TranslationPipelineEnvironment+Project.swift`
- Test: `MaughamTests/TranslationPipelineEnvironmentTests.swift`

**Interfaces:**
- Consumes: Task 3's internal statics, Task 4's `Environment`/`DeclinedMint`, Task 1's store, P1's role mints, P2's briefings, `ColdCall`, `withAnnotationDocument`, `DepartmentPaneHost.sourceLanguage`.
- Produces:

```swift
extension TranslationPipeline.Environment {
    @MainActor static func production(store: ProjectStore, documentStore: DocumentStore, projectURL: URL,
        translator: TranslatorOrchestrator, coldCall: ColdCall, model: String = CompilerOrchestrator.defaultModel,
        onRoundEnded: @escaping @MainActor (TranslationRound) -> Void) -> TranslationPipeline.Environment
    @MainActor static func readerBriefing(docId:language:store:documentStore:projectURL:) -> ReaderBriefing.Inputs?
    @MainActor static func collatorBriefing(docId:language:store:documentStore:projectURL:) -> CollatorBriefing.Inputs?
    @MainActor static func authorLanguage(store:documentStore:projectURL:) -> String   // a language NAME
    static func languageName(tag: String) -> String
    static func declinedBody(note: TranslatorBriefing.FixNote, reason: String, translatorName: String) -> String
    @MainActor static func mintDeclined(_ mint: TranslationPipeline.DeclinedMint, store:projectURL:) async -> [String: String]
}
```

- [ ] **Step 1: Write the failing tests** (a real-project harness — copy `TranslatorEnvironmentTests.makeHarness`'s shape: three-paragraph chapter, `ProjectStore`, `DocumentStore`, `Document.load`, registered; plus a `PublishConfig` written with `metadata.language = "en"` through `PublishConfigStore` — read `PublishConfigStore` for its write verb):

```swift
// MaughamTests/TranslationPipelineEnvironmentTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// The pipeline's production closures against a real project: the reader is
/// briefed with fresh translations only and never with source, the collator
/// with pairs and directives, identities are minted once, declined notes
/// mint as queries carrying the translator's reason, rounds reach the store.
@MainActor
final class TranslationPipelineEnvironmentTests: XCTestCase {

    private struct Harness {
        let projectURL: URL
        let store: ProjectStore
        let documentStore: DocumentStore
        let doc: Document
        let environment: TranslationPipeline.Environment
        let rounds: () -> [TranslationRound]
    }

    private func makeHarness() async throws -> Harness {
        // …TranslatorEnvironmentTests.makeHarness verbatim up to `documentStore.register`,
        // with the chapter text "The fog came in.\n\nShe closed the door.\n\nNobody spoke."
        // Then:
        let suite = "PipelineEnvTests-\(UUID().uuidString)"
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let translator = TranslatorOrchestrator()
        let coldCall = ColdCall()
        let rounds = Box<[TranslationRound]>([])
        let environment = TranslationPipeline.Environment.production(
            store: projectStore, documentStore: documentStore, projectURL: root,
            translator: translator, coldCall: coldCall,
            onRoundEnded: { rounds.value.append($0) })
        _ = preferences
        return Harness(projectURL: root, store: projectStore, documentStore: documentStore,
                       doc: doc, environment: environment, rounds: { rounds.value })
    }

    private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private func seed(_ harness: Harness, paragraph index: Int, text: String) throws {
        let id = harness.doc.sequence[index]
        _ = try TranslationWritePipeline.perform(
            entries: [.init(paragraphId: id, text: text, verbatim: nil, delete: nil)],
            language: "es", documentId: harness.doc.docId,
            state: (harness.doc.sequence, harness.doc.paragraphs, harness.projectURL),
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current))
    }

    func test_theReaderIsBriefedWithFreshTranslationsOnlyAndNeverTheSource() async throws {
        let harness = try await makeHarness()
        try seed(harness, paragraph: 0, text: "Llegó la niebla.")
        let inputs = try XCTUnwrap(await harness.environment.briefReader(harness.doc.docId, "es"))
        XCTAssertEqual(inputs.readerName, "Ocampo", "the preset, read without minting")
        XCTAssertEqual(inputs.language, "es")
        XCTAssertEqual(inputs.authorLanguage, "English")
        XCTAssertEqual(inputs.paragraphs.map(\.paragraphId), harness.doc.sequence)
        XCTAssertEqual(inputs.paragraphs.map(\.translation), ["Llegó la niebla.", nil, nil])
        XCTAssertFalse(ReaderBriefing.compose(inputs: inputs).contains("The fog came in."))
        await harness.documentStore.close()
    }

    func test_aStaleTranslationIsAGapToTheReader() async throws {
        let harness = try await makeHarness()
        // A record whose source hash is not the paragraph's current hash IS a
        // stale translation, by `TranslationDeriver`'s own definition.
        try await TranslationStore.append(
            TranslationRecord(paragraphId: harness.doc.sequence[1], language: "es",
                              text: "Cerró la puerta.", sourceHash: "not-the-current-hash"),
            forDocId: harness.doc.docId,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
            in: harness.projectURL)
        let inputs = try XCTUnwrap(await harness.environment.briefReader(harness.doc.docId, "es"))
        XCTAssertNil(inputs.paragraphs[1].translation, "stale is not the edition either")
        await harness.documentStore.close()
    }

    func test_theCollatorIsBriefedWithPairsDirectivesAndTheGlossary() async throws {
        let harness = try await makeHarness()
        try seed(harness, paragraph: 0, text: "Llegó la niebla.")
        let id = harness.doc.sequence[0]
        // The one door (`TranslatorEnvironmentTests` seeds a directive the
        // same way): a translator's note ruled into this edition's brief.
        try await RulingPerformer.rule(
            Ruling.directiveText(paragraphId: id, "keep the fog literal"),
            provenance: Ruling.Provenance.translatorsNote,
            kind: .editionBrief("es"), forScope: .project,
            store: harness.store, world: nil)
        let inputs = try XCTUnwrap(await harness.environment.briefCollator(harness.doc.docId, "es"))
        XCTAssertEqual(inputs.collatorName, "Borges")
        XCTAssertEqual(inputs.authorLanguage, "English")
        XCTAssertEqual(inputs.pairs.map(\.paragraphId), harness.doc.sequence)
        XCTAssertEqual(inputs.pairs[0].sourceText, "The fog came in.")
        XCTAssertEqual(inputs.pairs[0].translation, "Llegó la niebla.")
        XCTAssertEqual(inputs.pairs[0].directives, ["keep the fog literal"])
        XCTAssertNil(inputs.pairs[1].translation)
        XCTAssertNotNil(inputs.editionBriefText)
        await harness.documentStore.close()
    }

    func test_identitiesAreMintedOnceAndFoundThereafter() async throws {
        let harness = try await makeHarness()
        let first = try await harness.environment.readerIdentity("es")
        let second = try await harness.environment.readerIdentity("es")
        XCTAssertEqual(first.name, "Ocampo")
        XCTAssertEqual(first.roleId, second.roleId)
        XCTAssertEqual(harness.store.manifest.productionRoles.filter {
            if case .reader = $0.role { return true } else { return false }
        }.count, 1)
        let collator = try await harness.environment.collatorIdentity("es")
        XCTAssertEqual(collator.name, "Borges")
        XCTAssertEqual(harness.environment.translatorName("es"), "Cortázar")
        await harness.documentStore.close()
    }

    func test_aDeclinedNoteMintsAQueryCarryingTheTranslatorsReason() async throws {
        let harness = try await makeHarness()
        let id = harness.doc.sequence[0]
        let note = TranslatorBriefing.FixNote(
            id: "n1", paragraphId: id, author: "Ocampo", kind: "rhythm",
            severity: "minor", text: "Limps.")
        let ids = await harness.environment.mintDeclinedQueries(.init(
            docId: harness.doc.docId, language: "es", translatorName: "Cortázar",
            items: [.init(note: note, reason: "Deliberate.", authorRoleId: "role-reader-es")]))

        let annotation = try XCTUnwrap(
            harness.doc.annotations(filter: AnnotationFilter(statuses: nil)).first)
        XCTAssertEqual(ids, ["n1": annotation.id])
        XCTAssertEqual(annotation.kind, .query)
        XCTAssertEqual(annotation.paragraphId, id)
        XCTAssertEqual(annotation.language, "es")
        XCTAssertEqual(annotation.author?.displayName, "Ocampo")
        XCTAssertEqual(annotation.body,
                       TranslationPipeline.Environment.declinedBody(
                           note: note, reason: "Deliberate.", translatorName: "Cortázar"))
        XCTAssertTrue(annotation.body.hasPrefix("rhythm · minor\n"), "kind/severity first line")
        XCTAssertTrue(annotation.body.hasSuffix("Cortázar declined: Deliberate."))
        await harness.documentStore.close()
    }

    /// A note the author REJECTS is never briefed again: the next translate
    /// gather's open queries no longer carry it (spec §6).
    func test_aRejectedDeclinedNoteIsAbsentFromTheNextBriefing() async throws {
        let harness = try await makeHarness()
        let id = harness.doc.sequence[0]
        let note = TranslatorBriefing.FixNote(id: "n1", paragraphId: id, author: "Ocampo",
                                              kind: "rhythm", severity: nil, text: "Limps.")
        let ids = await harness.environment.mintDeclinedQueries(.init(
            docId: harness.doc.docId, language: "es", translatorName: "Cortázar",
            items: [.init(note: note, reason: "Deliberate.", authorRoleId: "r")]))
        let (openBefore, _) = TranslatorOrchestrator.Environment.languageQueries(
            docId: harness.doc.docId, language: "es", documentStore: harness.documentStore)
        XCTAssertEqual(openBefore.count, 1)
        try await harness.doc.rejectAnnotation(id: try XCTUnwrap(ids["n1"]),
                                               userResponse: "Translator's right.")
        let (openAfter, _) = TranslatorOrchestrator.Environment.languageQueries(
            docId: harness.doc.docId, language: "es", documentStore: harness.documentStore)
        XCTAssertTrue(openAfter.isEmpty)
        await harness.documentStore.close()
    }

    func test_roundsReachTheStoreAndNumbersComeFromIt() async throws {
        let harness = try await makeHarness()
        XCTAssertEqual(harness.environment.nextRoundNumber("es"), 1)
        let round = TranslationRound(number: 1, language: "es", docId: harness.doc.docId,
                                     startedAt: Date())
        harness.environment.saveRound(round)
        XCTAssertEqual(TranslationRoundStore(projectURL: harness.projectURL)
                           .latest(language: "es", docId: harness.doc.docId)?.number, 1)
        XCTAssertEqual(harness.environment.nextRoundNumber("es"), 2)
        await harness.documentStore.close()
    }

    func test_theAuthorsLanguageIsTheBooksOwnResolvedThroughTheImprint() {
        XCTAssertEqual(TranslationPipeline.Environment.languageName(tag: "en"), "English")
        XCTAssertEqual(TranslationPipeline.Environment.languageName(tag: "es"), "Spanish")
    }

    func test_theColdCallAndCancelReachTheWindowsRunner() async throws {
        // A ColdCall with no factory refuses with its own detail — the closure
        // is a pass-through and this pins that it IS the window's runner.
        let harness = try await makeHarness()
        let event = await harness.environment.coldCall("hi", nil, "m")
        guard case .failed(let failure) = event else { return XCTFail("an unwired runner refuses") }
        XCTAssertEqual(failure, .sessionDied(detail: ColdCall.notWiredDetail))
        await harness.documentStore.close()
    }
}
```

For `test_aStaleTranslationIsAGapToTheReader`, use whatever `Document` edit verb `TranslatorEnvironmentTests` or `TranslationStatusToolTests` already uses to make a paragraph stale (grep those files for how they edit a paragraph after seeding); if none is convenient, write the translation record with a wrong `sourceHash` directly through `TranslationStore.append` instead.

- [ ] **Step 2: Run to verify it fails** — compile error.

- [ ] **Step 3: Implement**

```swift
// Maugham/Compiler/TranslationPipelineEnvironment+Project.swift
import Foundation
import MaughamCore
import os

private let pipelineEnvLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "TranslationPipeline")

/// **The pipeline's production wiring** — `TranslatorEnvironment+Project
/// .swift`'s peer: one window's stores and the two session owners it
/// sequences, as closures, every capture weak. The translator legs go to the
/// window's `TranslatorOrchestrator`; the cold legs to its `ColdCall`; the
/// reader and collator are `ProjectStore.readerRole/collatorRole(for:)`,
/// find-or-create, which a run is the write act that earns; declined notes
/// mint through `withAnnotationDocument` so a closed chapter in a book queue
/// still gets its queries; rounds go to `TranslationRoundStore`.
extension TranslationPipeline.Environment {

    @MainActor
    static func production(
        store: ProjectStore, documentStore: DocumentStore, projectURL: URL,
        translator: TranslatorOrchestrator, coldCall: ColdCall,
        model: String = CompilerOrchestrator.defaultModel,
        onRoundEnded: @escaping @MainActor (TranslationRound) -> Void
    ) -> TranslationPipeline.Environment {
        TranslationPipeline.Environment(
            model: model,
            runTranslation: { [weak translator] docId, language in
                translator?.runTranslation(docId: docId, language: language)
            },
            runFix: { [weak translator] docId, language, notes, isFinalLeg in
                translator?.runFix(docId: docId, language: language, notes: notes,
                                   isFinalLeg: isFinalLeg)
            },
            cancelTranslator: { [weak translator] in translator?.cancel() },
            translatorName: { [weak store] language in
                guard let store else { return language }
                return EditionStatus.translatorName(for: language, in: store.manifest) ?? language
            },
            readerIdentity: { [weak store] language in
                guard let store else { throw TranslatorOrchestrator.Environment.WiringFailure.windowClosed }
                let role = try await store.readerRole(for: language)
                return (role.effectiveName, role.id)
            },
            collatorIdentity: { [weak store] language in
                guard let store else { throw TranslatorOrchestrator.Environment.WiringFailure.windowClosed }
                let role = try await store.collatorRole(for: language)
                return (role.effectiveName, role.id)
            },
            briefReader: { [weak store, weak documentStore] docId, language in
                guard let store else { return nil }
                return readerBriefing(docId: docId, language: language, store: store,
                                      documentStore: documentStore, projectURL: projectURL)
            },
            briefCollator: { [weak store, weak documentStore] docId, language in
                guard let store else { return nil }
                return collatorBriefing(docId: docId, language: language, store: store,
                                        documentStore: documentStore, projectURL: projectURL)
            },
            coldCall: { [weak coldCall] message, preamble, model in
                guard let coldCall else {
                    return .failed(.sessionDied(detail: ColdCall.notWiredDetail))
                }
                return await coldCall.call(message: message, preamble: preamble, model: model)
            },
            cancelColdCall: { [weak coldCall] in coldCall?.cancel() },
            mintDeclinedQueries: { [weak store] mint in
                guard let store else { return [:] }
                return await mintDeclined(mint, store: store, projectURL: projectURL)
            },
            nextRoundNumber: { TranslationRoundStore(projectURL: projectURL).nextNumber(language: $0) },
            saveRound: { round in
                do { try TranslationRoundStore(projectURL: projectURL).append(round) } catch {
                    pipelineEnvLog.error("round \(round.number, privacy: .public) for \(round.language, privacy: .public) could not be saved: \(error, privacy: .public)")
                }
            },
            onRoundEnded: onRoundEnded)
    }

    // MARK: - Gathers

    /// The reader's inputs: every paragraph in sequence order, a translation
    /// only where the derivation says FRESH — stale and missing are gaps, and
    /// a stale translation is not the edition either (spec §2). Text is
    /// passed through `stripTaskAnchorsInline`, the translator gather's own
    /// rule. The name is read without minting (`EditionStatus.readerName`);
    /// the identity closure has already stored the row by the time this runs.
    @MainActor
    static func readerBriefing(
        docId: String, language: String, store: ProjectStore,
        documentStore: DocumentStore?, projectURL: URL
    ) -> ReaderBriefing.Inputs? {
        guard let state = try? currentParagraphState(
            documentId: docId, store: store, documentStore: documentStore, projectURL: projectURL)
        else { return nil }
        let records = TranslationStore.loadMerged(forDocId: docId, language: language, in: projectURL)
        let derived = TranslationDeriver.derive(
            records: records, sequence: state.sequence, paragraphs: state.paragraphs, language: language)
        let role = store.manifest.storedReader(for: language)
        return ReaderBriefing.Inputs(
            readerName: role?.effectiveName
                ?? ProductionRole.defaultReaderName(language: language) ?? language,
            language: language,
            authorLanguage: authorLanguage(store: store, documentStore: documentStore, projectURL: projectURL),
            roleBrief: role?.effectiveBrief,
            editionBriefText: TranslatorOrchestrator.Environment.editionBriefText(language: language, store: store),
            paragraphs: derived.entries.map { entry in
                .init(paragraphId: entry.paragraphId,
                      translation: entry.status == .fresh
                          ? entry.translatedText.map(MarkdownDisplayFilter.stripTaskAnchorsInline)
                          : nil)
            })
    }

    @MainActor
    static func collatorBriefing(
        docId: String, language: String, store: ProjectStore,
        documentStore: DocumentStore?, projectURL: URL
    ) -> CollatorBriefing.Inputs? {
        guard let state = try? currentParagraphState(
            documentId: docId, store: store, documentStore: documentStore, projectURL: projectURL)
        else { return nil }
        let records = TranslationStore.loadMerged(forDocId: docId, language: language, in: projectURL)
        let derived = TranslationDeriver.derive(
            records: records, sequence: state.sequence, paragraphs: state.paragraphs, language: language)
        let role = store.manifest.storedCollator(for: language)
        let intentText = TranslatorOrchestrator.Environment.craftIntentText(docId: docId, store: store)
        let briefText = TranslatorOrchestrator.Environment.editionBriefText(language: language, store: store)
        let directives = Directives.byParagraph(
            Directives.gather(craftIntent: intentText, editionBrief: briefText))
        return CollatorBriefing.Inputs(
            collatorName: role?.effectiveName
                ?? ProductionRole.defaultCollatorName(language: language) ?? language,
            language: language,
            authorLanguage: authorLanguage(store: store, documentStore: documentStore, projectURL: projectURL),
            roleBrief: role?.effectiveBrief,
            craftIntentText: intentText,
            editionBriefText: briefText,
            glossary: GlossaryTable.gather(editionBrief: briefText),
            pairs: derived.entries.map { entry in
                .init(paragraphId: entry.paragraphId,
                      sourceText: MarkdownDisplayFilter.stripTaskAnchorsInline(entry.sourceText),
                      translation: entry.status == .fresh
                          ? entry.translatedText.map(MarkdownDisplayFilter.stripTaskAnchorsInline)
                          : nil,
                      directives: (directives[entry.paragraphId] ?? []).map(\.text))
            })
    }

    /// **The author's language is the book's own** — nothing else in the
    /// project names it — resolved through the imprint the desk is standing
    /// on exactly as the compile sheet resolves it
    /// (`DepartmentPaneHost.sourceLanguage`, the one spelling), then named in
    /// English for the briefing's role frame.
    @MainActor
    static func authorLanguage(store: ProjectStore, documentStore: DocumentStore?, projectURL: URL) -> String {
        let config = (try? PublishConfigStore.read(in: projectURL)) ?? nil
        let tag = DepartmentPaneHost.sourceLanguage(
            imprint: documentStore?.uiState.publishImprint, in: config,
            pieceIDs: EditionStatus.manuscriptDocumentIds(in: store.manifest))
        return languageName(tag: tag)
    }

    static func languageName(tag: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: tag) ?? tag
    }

    // MARK: - The declined mint

    /// The query's body (spec §6): kind and severity on the first line, the
    /// note, then the translator's reason under the translator's name — the
    /// "reply" the annotation layer has no primitive for, carried where the
    /// queue already draws prose. The structured form is the round record's.
    static func declinedBody(note: TranslatorBriefing.FixNote, reason: String,
                             translatorName: String) -> String {
        let head = note.severity.map { "\(note.kind) \u{00b7} \($0)" } ?? note.kind
        return "\(head)\n\(note.text)\n\n\(translatorName) declined: \(reason)"
    }

    /// `TranslatorEnvironment+Project.mint`'s idiom over the note's own
    /// author: anchored to the live paragraph (doc-scoped craft note if it is
    /// gone), `add_query`'s `toolArgs` with the language and the reader's or
    /// collator's role id, announced once. Never fails the round.
    @MainActor
    static func mintDeclined(
        _ mint: TranslationPipeline.DeclinedMint, store: ProjectStore, projectURL: URL
    ) async -> [String: String] {
        guard !mint.items.isEmpty else { return [:] }
        var ids: [String: String] = [:]
        do {
            try await withAnnotationDocument(store: store, projectURL: projectURL,
                                             documentId: mint.docId) { document in
                for item in mint.items {
                    let anchor = document.sequence.contains(item.note.paragraphId)
                        ? item.note.paragraphId : nil
                    let body = declinedBody(note: item.note, reason: item.reason,
                                            translatorName: mint.translatorName)
                    do {
                        let id = try await document.addAnnotation(
                            kind: anchor == nil ? .craftNote : .query,
                            paragraphId: anchor,
                            body: anchor == nil ? "Translation query (\(mint.language)) \u{2014} \(body)" : body,
                            toolArgs: TranslatorOrchestrator.Environment.queryToolArgs(
                                language: mint.language, roleId: item.authorRoleId),
                            author: AnnotationAuthor(sourceKind: .claude, displayName: item.note.author),
                            announcing: false)
                        ids[item.note.id] = id
                    } catch {
                        pipelineEnvLog.error("a declined note could not be minted on doc \(mint.docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                if !ids.isEmpty { document.announceAnnotationsChanged() }
            }
        } catch {
            pipelineEnvLog.error("\(mint.items.count, privacy: .public) declined note(s) had nowhere to land: \(error.localizedDescription, privacy: .public)")
        }
        return ids
    }
}
```

`WiringFailure` is `TranslatorOrchestrator.Environment`'s nested enum — if it is `private`, make it internal.

- [ ] **Step 4: `./gen.sh`; run the new suite plus `TripwireGrepTests`** — green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/TranslationPipelineEnvironment+Project.swift MaughamTests/TranslationPipelineEnvironmentTests.swift
git commit -m "feat(translation-pipeline): production environment — reader/collator gathers and identities, declined-note mint, round store"
```

---

### Task 7: The window owns the pipeline; the gate widens

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`, `Maugham/Views/CompilerRunModifier.swift`, `Maugham/Views/DetailPaneToggle.swift`, `Maugham/Views/Publish/DepartmentPaneHost.swift`, `Maugham/Views/Publish/DepartmentRunState.swift`
- Test: `MaughamTests/TranslatorEnvironmentTests.swift` (census), `MaughamTests/DepartmentRunTests.swift`

**Interfaces:**
- Produces: `DepartmentRunSession.read(runState:isRunning:pipeline: TranslationPipeline.Status = .idle)`; `DepartmentPaneHost.pipeline: TranslationPipeline? = nil`; `CompilerRunModifier.pipeline: TranslationPipeline`; `ProjectWindow`'s `@State private var pipeline = TranslationPipeline()`.

- [ ] **Step 1: Write the failing tests**

In `DepartmentRunTests`, beside `test_theSessionReadsBusyFromTheOrchestratorsOwnState`:

```swift
    /// The one-round-at-a-time gate is a PIPELINE gate now (spec §5): a cold
    /// leg holds no translator session, so the translator reads free while a
    /// reader is out — and every row must still refuse, naming the edition.
    func test_thePipelineHoldsTheGateEvenWhileTheTranslatorIsFree() {
        let busy = DepartmentRunSession.read(
            runState: .idle, isRunning: false,
            pipeline: .running(docId: "doc-1", language: "fr", leg: .read, book: nil))
        XCTAssertEqual(busy, .busy(language: "fr"))
        XCTAssertEqual(DepartmentRunSession.read(runState: .idle, isRunning: false, pipeline: .idle), .free)
        XCTAssertEqual(
            DepartmentRunState.refusal(target: .ready(docId: "doc-1", title: "One"), session: busy),
            DepartmentRunState.busyReason(language: "fr"))
    }
```

In `TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown`, add after the cold-call count:

```swift
        XCTAssertEqual(
            compilerShutdowns,
            modifier.components(separatedBy: "pipeline.shutdown()").count - 1,
            "every compiler shutdown in the modifier needs its pipeline sibling — "
            + "a leg awaiting a translator summary is otherwise never resumed once "
            + "the orchestrator is shut down (translation pipeline spec §5)")
```

and to the window tokens:

```swift
        for token in ["TranslationPipeline()", "pipeline.detach()", "pipeline.configure(",
                      "pipeline: pipeline", "pipeline.updateModel(",
                      "pipeline.translatorRunEnded(", "pipeline.translatorRunAbandoned("] {
            XCTAssertTrue(window.contains(token),
                          "ProjectWindow is missing \(token) — without it the pipeline is "
                          + "unwired, unmounted, deaf to the translator, or outlives the window")
        }
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement**

`DepartmentRunState.swift` — `DepartmentRunSession.read`:

```swift
    static func read(runState: TranslatorOrchestrator.RunState,
                     isRunning: Bool,
                     pipeline: TranslationPipeline.Status = .idle) -> DepartmentRunSession {
        // The pipeline outranks the orchestrator's own state: during a cold
        // leg the translator is idle and would read free.
        if case .running(_, let language, _, _) = pipeline {
            return .busy(language: language)
        }
        guard isRunning else { return .free }
        if case .running(_, let language, _) = runState {
            return .busy(language: language)
        }
        return .busy(language: nil)
    }
```

`DepartmentPaneHost.swift`: add `var pipeline: TranslationPipeline? = nil` beside `translator` (doc: the window's pipeline, passed for the gate; Plan 4 draws its legs); pass `pipeline: pipeline?.status ?? .idle` at both `DepartmentRunSession.read(` sites (`runStates(for:)` and `run(language:)`). The `.task(id:)` key struct that carries the designer's state — add `pipelineStatus: TranslationPipeline.Status` to it so a leg change re-derives the rows.

`DetailPaneToggle.swift` (line ~504) and wherever `translator: translator` flows to the host: thread `pipeline: pipeline` the same way (a `let pipeline: TranslationPipeline?` on `DetailPaneToggle`, defaulted nil if it has defaults).

`CompilerRunModifier.swift`: `let pipeline: TranslationPipeline` after `coldCall`; in BOTH arms add `pipeline.shutdown()` as the FIRST line (so its generation moves before the orchestrators resolve their legs); update the doc comment's "four session owners" paragraph to name the pipeline as the fifth sibling that owns no session but owns a waiting leg.

`ProjectWindow.swift`:
- `@State private var pipeline = TranslationPipeline()` after `coldCall`.
- `.onDisappear` arm: `pipeline.detach()` before `compiler.detach()`.
- `CompilerRunModifier(... coldCall: coldCall, pipeline: pipeline, ...)`.
- The load block: the translator's `onRunEnded` closure becomes `{ [weak translationRuns, weak pipeline] summary in translationRuns?.record(summary); pipeline?.translatorRunEnded(summary); … log … }` and `.production(...)` gains `onRunAbandoned: { [weak pipeline] in pipeline?.translatorRunAbandoned($0) }`. After `coldCall.configure(...)`:

```swift
            // The pipeline, sequencing the translator and the cold-call runner
            // wired just above. Owns no session; owns the leg that waits.
            pipeline.configure(environment: .production(
                store: s, documentStore: ds, projectURL: url,
                translator: translator, coldCall: coldCall,
                model: ds.uiState.compilerModel.claudeModel,
                onRoundEnded: { round in
                    _projectWindowLog.info(
                        "translation round \(round.number, privacy: .public) for \(round.docId, privacy: .public)/\(round.language, privacy: .public) ended at leg \(round.legs.last?.leg.name ?? "-", privacy: .public)")
                }))
```
- Beside `translator.updateModel(newValue.claudeModel)` (line ~2954): `pipeline.updateModel(newValue.claudeModel)`.
- Where `DetailPaneToggle(... translator: translator, ...)` is built (line ~2937): `pipeline: pipeline`.

- [ ] **Step 4: Run `DepartmentRunTests`, `DepartmentPaneTests`, `TranslatorEnvironmentTests`, `CompilerRunCommandTests`** — green. Then `./scripts/test.sh` (the fast loop) for the whole Mac scheme minus the canvas family.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/ProjectWindow.swift Maugham/Views/CompilerRunModifier.swift Maugham/Views/DetailPaneToggle.swift Maugham/Views/Publish/DepartmentPaneHost.swift Maugham/Views/Publish/DepartmentRunState.swift MaughamTests/TranslatorEnvironmentTests.swift MaughamTests/DepartmentRunTests.swift
git commit -m "feat(translation-pipeline): the window owns the pipeline beside the orchestrators; the desk's gate reads it"
```

---

### Task 8: `translation_status` gains `reader`, `collator`, `last_round`

**Files:**
- Modify: `Maugham/MCP/Tools/TranslationTools.swift`
- Test: `MaughamTests/MCP/Tools/TranslationStatusToolTests.swift`

**Interfaces:**
- Produces on `TranslationStatusTool`: `Row.reader: String?`, `Row.collator: String?`, `Row.last_round: LastRound?`; `struct LastRound: Codable, Equatable { number: Int; leg2_verdict: String?; leg4_verdict: String?; notes: Int; departures: Int; declined: Int; summary: String?; stopped_at: String? }`. All three new `Row` fields are `public var … = nil` so existing `Row(...)` call sites keep compiling.

- [ ] **Step 1: Write the failing tests** (read the file's harness first; it builds a project and calls `TranslationStatusTool.handle` through a registry):

```swift
    /// The row names the whole cast for a preset language (spec §8's MCP
    /// line), read without minting, and omits what has no honest name.
    func test_rowsNameTheReaderAndCollatorWithoutMinting() async throws {
        // seed an `es` translation on the harness document as the existing tests do
        let result = try await status(documentId: docId)   // the file's own helper
        let row = try XCTUnwrap(result.rows.first { $0.language == "es" })
        XCTAssertEqual(row.translator, "Cortázar")
        XCTAssertEqual(row.reader, "Ocampo")
        XCTAssertEqual(row.collator, "Borges")
        XCTAssertNil(row.last_round)
        XCTAssertTrue(store.manifest.productionRoles.isEmpty, "a read never mints")
    }

    func test_theLastRoundIsThisPairsNewestAndAnotherChaptersIsNotReported() async throws {
        var round = TranslationRound(number: 4, language: "es", docId: docId, startedAt: Date())
        round.leg2 = .init(verdict: "mixed", text: "…")
        round.leg4 = .init(verdict: "reads_as_native", text: "…")
        round.notes = [.init(id: "n1", leg: .read, author: "Ocampo", paragraphId: "a1b2",
                             kind: "rhythm", severity: "minor", text: "Limps.",
                             outcome: .declined(reason: "Deliberate.", annotationId: nil))]
        round.departures = [.init(id: "d1", paragraphId: "a1b2", verdict: "holds", kind: "rendering",
                                  note: "Split.", gloss: "…", outcome: nil)]
        round.summary = "Done."
        round.legs = [.init(leg: .translate, status: .ran, counts: .init(entries: 1))]
        try TranslationRoundStore(projectURL: projectURL).append(round)
        var other = TranslationRound(number: 5, language: "es", docId: "doc-other", startedAt: Date())
        other.legs = [.init(leg: .read, status: .failed, reason: "died")]
        try TranslationRoundStore(projectURL: projectURL).append(other)

        let row = try XCTUnwrap((try await status(documentId: docId)).rows.first { $0.language == "es" })
        let last = try XCTUnwrap(row.last_round)
        XCTAssertEqual(last.number, 4, "chapter-other's round 5 is not this row's")
        XCTAssertEqual(last.leg2_verdict, "mixed")
        XCTAssertEqual(last.leg4_verdict, "reads_as_native")
        XCTAssertEqual(last.notes, 1)
        XCTAssertEqual(last.departures, 1)
        XCTAssertEqual(last.declined, 1)
        XCTAssertEqual(last.summary, "Done.")
        XCTAssertNil(last.stopped_at)
    }
```

If the file has no `status(documentId:)` helper, use however its existing tests invoke the tool and decode `Result`.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** — in `TranslationStatusTool`:

```swift
    /// The newest pipeline round for this `(document, language)` pair
    /// (`TranslationRoundStore.latest`), or omitted when none has run.
    public struct LastRound: Codable, Equatable {
        public let number: Int
        public let leg2_verdict: String?
        public let leg4_verdict: String?
        public let notes: Int
        public let departures: Int
        public let declined: Int
        public let summary: String?
        /// The leg a failed or cancelled round stopped at, else omitted.
        public let stopped_at: String?
    }
```

`Row` gains `public var reader: String? = nil`, `public var collator: String? = nil`, `public var last_round: LastRound? = nil` after `translator`. In `handle`, build each row with:

```swift
                reader: EditionStatus.readerName(for: $0.language, in: entry.store.manifest),
                collator: EditionStatus.collatorName(for: $0.language, in: entry.store.manifest),
                last_round: rounds.latest(language: $0.language, docId: $0.documentId).map {
                    LastRound(number: $0.number, leg2_verdict: $0.leg2?.verdict,
                              leg4_verdict: $0.leg4?.verdict, notes: $0.noteCount,
                              departures: $0.departures.count, declined: $0.declinedCount,
                              summary: $0.summary, stopped_at: $0.stoppedAt?.name)
                }
```

with `let rounds = TranslationRoundStore(projectURL: entry.url)` above the map. Extend `description` with: "`reader` and `collator` name the edition's blind reader and collator the same way `translator` does. `last_round` (omitted until a pipeline round has run on that document) carries the newest round's number, the two readers' verdicts, its note/departure/declined counts, its summary, and `stopped_at` for a round that failed or was cancelled."

- [ ] **Step 4: Run `TranslationStatusToolTests`, `TranslationFlowTests`, `MCPProtocolHandlersTests`, `EditionStatusTests`, `DocSyncTests`** — green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/TranslationTools.swift MaughamTests/MCP/Tools/TranslationStatusToolTests.swift
git commit -m "feat(mcp): translation_status reports reader, collator and last_round"
```

---

### Task 9: Docs for what shipped

**Files:**
- Modify: `Maugham/Compiler/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/MCP/AREA.md`

No code. Guide topics, roadmap, CLAUDE.md cells and ADR 0030 are Plan 4's sweep (spec §14) — do not touch them here.

- [ ] **Step 1: `Maugham/Compiler/AREA.md`** — after the "Cold calls" section add "## The pipeline — seven legs (translation pipeline P3)" covering, in this order, each in one or two sentences with the file/test that pins it: `TranslationPipeline` is a state machine over closures (`TranslationPipelineTests`); the leg table; skip rules and their reason strings (note the leg-4 rule: it skips when leg 3 wrote nothing); failure/cancel semantics and the generation gap check (`TranslationPipelineCancelTests`); note ids minted before the fix leg and the `.fix` work-list built FROM the notes (`TranslatorEnvironmentTests.test_theFixGatherBuildsTheWorkListFromTheNotesItBriefs`); `runFix`/`briefFix`/`onRunAbandoned` on the orchestrator and why abandon is not a summary; minting per §6 with the declined "reply" carried in the query body because the annotation layer has no reply primitive (`declinedBody`); `TranslationRound` + `TranslationRoundStore` (ring of 10, numbering per language, derived); the book queue stops on a failed round; the gate now reads `TranslationPipeline.Status`; the teardown census's fifth sibling; what Plan 4 draws (`Status.leg.verb`, `trend`). Update the cold-calls section's "the callers arrive in Plans 3–4" to say the reader and collator arrived in P3 (gloss and Ask the collator are P4's).
- [ ] **Step 2: `Maugham/Stores/AREA.md`** — in the `.maugham/` layout, add `translations/rounds/<lang>.json` (derived; `TranslationRoundStore`; whole-file rewrite by the one pipeline the gate allows, classified `unknownSidecar`).
- [ ] **Step 3: `Maugham/MCP/AREA.md`** — the `translation_status` entry: `reader`, `collator`, `last_round` (a widening; the count did not move).
- [ ] **Step 4: Commit**

```bash
git add Maugham/Compiler/AREA.md Maugham/Stores/AREA.md Maugham/MCP/AREA.md
git commit -m "docs(translation-pipeline): AREA entries for the pipeline, the round store and translation_status"
```

---

## Before merge

1. Whole-branch review (opus) of `git diff main...translation-pipeline-p3` — look especially at: every `await` in `TranslationPipeline` followed by a generation guard; the `pending` continuation never leaked (every path that sets it resumes it exactly once — `cancel`, `shutdown`, `translatorRunEnded`, `translatorRunAbandoned`, refused start); `IngestOutcome`'s defaulted fields not silently empty on the fix path in production; `withAnnotationDocument` closing a transient document after the mint.
2. `./scripts/test.sh full`; read the kept xcresult (`xcrun xcresulttool get test-results summary --path <path>`); a red mounted-click test → check `ioreg -n Root -d1 | grep ScreenIsLocked` before blaming the branch.
3. Merge locally with `--no-ff`; do not push. Write `docs/superpowers/notes/2026-08-29-translation-pipeline-p3-handoff.md` for Plan 4 (what was built by file; the surfaces Plan 4 owes: the desk row's legs/pre-flight/trend/Run whole book wired to `pipeline.run`/`runBook` over `scopedDocumentIds`, the round report arm, Gloss/Ask the collator; carried-forward: the declined "reply" lives in the body until a reply primitive exists; `languageQueries` still reads the open document only; a book queue stops on a failed round).
