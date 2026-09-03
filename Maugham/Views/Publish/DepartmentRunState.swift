import Foundation
import MaughamCore

/// **The run half of the department desk, as decisions rather than as a view**
/// (publish-department P4 Task 3).
///
/// Task 2 gave every edition a row and a door; this file is about the verb on it.
/// Everything a Run button does before it is pressed — whether it may be pressed,
/// why not, what the row says while a round is in flight and what it says when one
/// ends — is a pure function here, so the whole surface is drivable from literals
/// and `DepartmentPane` goes on taking values and holding no store
/// (`DepartmentPaneTests.test_theSourceReadsNoStoreAtAll`).
///
/// **`ReviewRoundCockpit`'s idiom, one persona over.** The cockpit resolves a
/// window-wide `runState` down to one document's phase with a `where runDocId ==
/// docId`, disables its Run with the reason as help, and offers Cancel only from
/// the arm that has something to cancel. The desk does the same three things — the
/// difference is that a translation round names a PAIR, so every scope test here
/// carries the language as well, and the desk draws a row per language where the
/// cockpit draws one strip.

// MARK: - Which document a run is for

/// **What a translation run would be run on** — Global Constraint 1, as a value.
///
/// The desk is a project-level surface: it sums every chapter's coverage into one
/// row per edition. A round, though, is one document's, and the document it is for
/// is the one the window is on. So the button's availability is a question about
/// the TREE's subject, not about the desk — and the answer is either a document or
/// a sentence saying what to do instead. There is no third state and no `nil`: a
/// refusal that carries no words is the dead control RULING-35 is about.
enum DepartmentRunTarget: Equatable {

    /// The tree names a manuscript document, and the window has it open.
    case ready(docId: String, title: String)

    /// Anything else, carrying the sentence the writer reads.
    case unavailable(String)

    /// The document a run would be for, or `nil`.
    var docId: String? {
        if case .ready(let docId, _) = self { return docId }
        return nil
    }

    /// The chapter's own title — what a run's help text names, so the offer says
    /// which chapter it would translate rather than "this document".
    var title: String? {
        if case .ready(_, let title) = self { return title }
        return nil
    }

    /// Why a run is not available here, or `nil` when it is.
    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// The one sentence for every subject that is not an open chapter.
    ///
    /// **An instruction rather than a diagnosis.** "No document selected" states
    /// the writer's own situation back at them; what they need is the move that
    /// makes the button work, which is the same move whether the tree is on the
    /// project row, a group, a research note or nothing at all — so one sentence
    /// serves all of them and the desk never has to explain a distinction the
    /// writer did not draw.
    static let openAChapter =
        "Open a chapter to translate it \u{2014} a round translates the document "
        + "this window is on."

    /// **Resolve the window's subject to a run target.**
    ///
    /// Three tests, in order, and the third is the one Global Constraint 1 is
    /// really about: the subject must name a structure item, that item must be a
    /// document with a path, and the window must actually have it OPEN. The first
    /// two are `ProjectWindow.selectionIsDocument`'s rule; the third is this
    /// surface's own, and it is not a formality — the briefing resolves a closed
    /// document through the derived cache, which would work, but a desk offering
    /// to translate a chapter nobody is looking at is a run started by accident.
    ///
    /// `isOpen` takes the manuscript-relative PATH because that is what the
    /// document registry is keyed on (`DocumentStore.document(for:)`), and it is a
    /// closure so this rule is drivable with no store — the store is the host's.
    static func resolve(subject: BinderSubject?,
                        structure: [StructureItem],
                        isOpen: (String) -> Bool) -> DepartmentRunTarget {
        guard let id = subject?.itemID,
              let item = TreeWalk.find(id: id, in: structure),
              item.type == .document,
              let path = item.path,
              isOpen(path)
        else { return .unavailable(openAChapter) }
        return .ready(docId: id, title: item.title)
    }
}

// MARK: - What the one session is doing

/// **Whether the desk's single translator session is free**, and which edition has
/// it when it is not.
///
/// `TranslatorOrchestrator` holds one warm `claude` per window and refuses a second
/// run outright (`runTranslation`'s `!isRunning` guard) — silently, which is
/// exactly what Global Constraint 2 forbids a surface to leave at that. So the desk
/// reads the same question the orchestrator asks itself, and answers it in words on
/// every row before a click can be swallowed.
enum DepartmentRunSession: Equatable {
    case free
    /// A run is under way. `language` is `nil` in the window between the click and
    /// the send, while the identity is minted and the round gathered:
    /// `isPreparingRun` counts as running there, and `runState` has not named a
    /// pair yet. Short, and a writer double-clicking is exactly who lands in it.
    case busy(language: String?)

    /// **The pipeline outranks the orchestrator's own state** (translation
    /// pipeline spec §5). A round's cold legs — the reader's, the collator's —
    /// hold no warm translator session at all, so `isRunning` reads false and
    /// every row would offer Run while a reader is out. The gate is the
    /// pipeline's now; the orchestrator's own state is what is left to read
    /// when no pipeline round is up (a bare `runTranslation` from the desk's
    /// P4 verb, and the probe mounts that pass no pipeline).
    static func read(runState: TranslatorOrchestrator.RunState,
                     isRunning: Bool,
                     pipeline: TranslationPipeline.Status = .idle) -> DepartmentRunSession {
        if case .running(_, let language, _, _) = pipeline {
            return .busy(language: language)
        }
        guard isRunning else { return .free }
        if case .running(_, let language, _) = runState {
            return .busy(language: language)
        }
        return .busy(language: nil)
    }
}

// MARK: - One row's run half

/// **Everything one language row draws about running**, resolved for that row's
/// own edition of the chapter the window is on.
struct DepartmentRunState: Equatable {

    /// **What the last thing the run verb did means for THIS edition of THIS
    /// chapter.**
    ///
    /// A separate type from `TranslatorOrchestrator.RunState` for
    /// `ReviewRoundCockpit.RunPhase`'s reason, doubled: that state is per WINDOW,
    /// this is per row, and the desk draws a row per language — so a phase scoped
    /// to the document alone would paint every edition of a chapter with one
    /// round's progress, and a red line across the French row for a Spanish death.
    ///
    /// No `at:` on the arms. The cockpit carries one so a later surface could age
    /// its line; nothing here ages anything, and a date on an `Equatable` value
    /// nobody reads is a field a test has to construct to compare two states.
    ///
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

    /// What the last finished round for this pair reported — entries, questions,
    /// warnings, or the sentence that refused it. `nil` before any.
    var report: String? = nil

    /// Why Run refuses on this row, or `nil` when it is pressable. Never an empty
    /// string: a refusal with no words is the thing Constraint 2 exists against.
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

    var canRun: Bool { refusal == nil }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    var offersShow: Bool { latestRound != nil }

    /// Run Whole Book refuses for a busy session and for an empty set — never
    /// for a missing open chapter, which the book does not need.
    var bookRefusal: String? {
        if let refusal, refusal != DepartmentRunTarget.openAChapter { return refusal }
        if bookDocumentCount == 0 { return Self.nothingInTheBook }
        return nil
    }
    var canRunBook: Bool { bookRefusal == nil }

    /// **The row's one line**, in the cockpit's own order: what is happening now
    /// outranks what happened last, and a finished round's report is what an idle
    /// row has to say.
    ///
    /// One slot rather than two because the column is narrow and because the two
    /// would otherwise describe different runs at the same moment — a report about
    /// the round before, drawn under a round in flight, reads as that round's
    /// result.
    ///
    /// **An idle row with a round says the round**, not the translator's own
    /// last summary: the log records every LEG's summary, and a seven-leg
    /// round's newest entry is leg 7's own sentence about a repair, not the
    /// round.
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

    /// Pre-flight and trend, sharing one slot (spec §8: they share the row's
    /// slot rather than adding a line each) — and only while idle, since a
    /// running row's detail is its leg and the pre-flight is for a click that
    /// has not happened.
    var detailLine: String? {
        guard case .idle = phase else { return nil }
        let parts = [Self.preflightLine(words: chapterWords ?? bookWords),
                     Self.trendLine(trend)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00b7} ")
    }

    /// **The whole row's run half, from the window's state.**
    ///
    /// `lastRun` is looked up by pair before it gets here, and the docId is
    /// checked again anyway: the desk is project-scope and the window's chapter
    /// changes under it, so a report is drawn only while the desk is still on the
    /// chapter that produced it. A lookup that quietly went wrong would otherwise
    /// show chapter 1's round on a desk about chapter 2, which is the shape of
    /// error nothing on screen could reveal.
    ///
    /// **The pipeline outranks the bare translator state**, and scoped by
    /// LANGUAGE ALONE — never the open chapter's docId. A book queue walks
    /// chapters the window is not on, and a row that went idle whenever the
    /// queue left the open chapter would say nothing for eleven of twelve
    /// rounds.
    static func resolve(language: String,
                        target: DepartmentRunTarget,
                        session: DepartmentRunSession,
                        runState: TranslatorOrchestrator.RunState,
                        lastRun: TranslatorOrchestrator.RunSummary?,
                        pipeline: TranslationPipeline.Status = .idle,
                        latestRound: TranslationRound? = nil,
                        trend: [Int] = [],
                        chapterWords: Int? = nil,
                        bookWords: Int? = nil,
                        bookDocumentCount: Int = 0,
                        now: Date = Date())
    -> DepartmentRunState {
        let docId = target.docId
        var phase = Phase.idle
        if case .running(_, let runLanguage, let leg, let book) = pipeline, runLanguage == language {
            phase = .running(.leg(leg, book: book))
        } else {
            switch runState {
            case .running(let runDocId, let runLanguage, let translating)
                where runDocId == docId && runLanguage == language:
                phase = .running(.translating(translating))
            case .nothingToTranslate(let runDocId, let runLanguage, _)
                where runDocId == docId && runLanguage == language:
                phase = .nothingToTranslate
            case .failed(let runDocId, let runLanguage, let failure, _)
                where runDocId == docId && runLanguage == language:
                phase = .failed(failure)
            default:
                break
            }
        }

        let report = lastRun.flatMap { summary -> String? in
            guard summary.docId == docId, summary.language == language else {
                return nil
            }
            return reportLine(summary.outcome)
        }

        return DepartmentRunState(phase: phase, report: report,
                                  refusal: refusal(target: target, session: session),
                                  latestRound: latestRound, trend: trend,
                                  chapterWords: chapterWords, bookWords: bookWords,
                                  bookDocumentCount: bookDocumentCount, now: now)
    }

    /// **Why Run refuses, in the order the writer needs to hear it.**
    ///
    /// A session in flight outranks a subject that could not be run anyway,
    /// because a round under way is the fact that changes what pressing ANYTHING
    /// on this desk will do — and because the writer who moved the tree off the
    /// chapter mid-round would otherwise be told to open a chapter while their
    /// round is still translating one.
    static func refusal(target: DepartmentRunTarget,
                        session: DepartmentRunSession) -> String? {
        if case .busy(let language) = session {
            return busyReason(language: language)
        }
        return target.reason
    }

    /// **Everything that must be true before a click reaches the orchestrator** —
    /// Global Constraint 2's pre-flight, answering with the sentence to show or
    /// `nil` to go ahead.
    ///
    /// The first two arms are the disabled button's own reasons, re-asked because
    /// a control's disabled state lands on the next body pass and a fast second
    /// click can beat it. The third is the one that can only be caught here: a
    /// language tag `TranslationWritePipeline` will not write is refused by the
    /// briefing gather, which answers `nil`, and `TranslatorOrchestrator.abandon()`
    /// sets no state and emits no summary — so the click vanishes. It is refused
    /// by CALLING the pipeline's own gate, not by a second spelling of what a
    /// language tag is; `TranslatorEnvironment`'s briefing calls the same function
    /// a moment later for the same reason, so the two cannot come to disagree.
    ///
    /// The briefing's OTHER `nil` arm — a document whose current paragraphs cannot
    /// be resolved — needs no message because it cannot be reached from here:
    /// `currentParagraphState` answers an open document straight off the registry,
    /// and an open document is precisely what `DepartmentRunTarget.ready` means.
    /// `DepartmentRunTests.test_theBriefingAbandonIsClosedByTheOpenDocumentGate`
    /// is what holds that shut, rather than this paragraph.
    @MainActor
    static func preflight(language: String,
                          target: DepartmentRunTarget,
                          session: DepartmentRunSession) -> String? {
        if let refusal = refusal(target: target, session: session) { return refusal }
        guard (try? TranslationWritePipeline.validate(language: language)) != nil else {
            return unusableTag(language: language)
        }
        return nil
    }

    // MARK: - Copy

    static let runTitle = "Run"
    static let cancelTitle = "Cancel"

    /// **What Cancel can honestly promise a PIPELINE round** (spec §5).
    ///
    /// Before the pipeline a round was one translator call, so "nothing it has
    /// translated is written" was true: the ingest was the last thing to
    /// happen, and a cancel before it wrote nothing at all. A seven-leg round
    /// has written by leg 1 and repaired by leg 3, and `TranslationPipeline
    /// .cancel` stops after the leg that is running — earlier legs' writes
    /// STAND. So the sentence says what actually survives, because a writer who
    /// cancelled on the old promise and found paragraphs translated would have
    /// been told the wrong thing by the surface at the moment they most needed
    /// it to be right.
    static let cancelHelp =
        "Stop this round after the leg that is running. What earlier legs "
        + "wrote stays; nothing later starts."

    /// What a round with nothing stale and nothing missing says. Its own sentence
    /// rather than silence, for the reason `TranslatorOrchestrator.RunState` keeps
    /// the case: a writer who presses Run and sees the row unchanged cannot tell
    /// "checked, everything is fresh" from "the button did nothing".
    static let nothingToTranslateLine =
        "Nothing to translate \u{2014} this chapter\u{2019}s edition is up to date."

    /// A cancel is the writer's own act and is never drawn as a failure
    /// (`ReviewRoundCockpit`'s rule, in this surface's currency).
    static let cancelledLine = "Run cancelled. Nothing was written."

    static func translating(_ count: Int) -> String {
        "Translating \(count) paragraph\(count == 1 ? "" : "s")\u{2026}"
    }

    /// Why every Run refuses while one is warm, naming the edition that has the
    /// session — a writer with four rows needs to know which one to wait for.
    static func busyReason(language: String?) -> String {
        guard let language else {
            return "A translation round is starting. There is one session, and the "
                + "next round is the next click."
        }
        return "A "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " round is running. There is one session, and the next round is the "
            + "next click."
    }

    /// The offer, naming the chapter it would translate — the one thing a
    /// project-scope desk cannot say in its rows, since every row is about the
    /// whole book's coverage and the run is about one chapter of it.
    static func runHelp(language: String, target: DepartmentRunTarget) -> String {
        let edition = TranslationReviewIndicator.displayLabel(forLanguageTag: language)
        guard let title = target.title else {
            return "Translate a chapter into \(edition)."
        }
        return "Translate \u{201C}\(title)\u{201D} into \(edition) \u{2014} the "
            + "round covers what is stale or missing."
    }

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

    /// The running leg's own line, and for a book queue, which chapter of how
    /// many (spec §8).
    static func legLine(_ leg: TranslationRound.Leg, book: TranslationPipeline.BookProgress?) -> String {
        let verb = "\(leg.verb)\u{2026} (leg \(leg.rawValue) of \(TranslationRound.Leg.allCases.count))"
        guard let book else { return verb.prefix(1).uppercased() + verb.dropFirst() }
        return "Chapter \(book.position) of \(book.count) \u{00b7} \(verb)"
    }

    /// A finished round's line: where it ended, and how long ago.
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

    /// Coarse and never negative — a clock skewed slightly into the future
    /// still reads "just now" rather than a nonsensical "-1m ago".
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

    /// A tag no edition can be written for. It names the tag, because the writer
    /// did not type it here — it came off a translation file or a query somebody
    /// else's session stamped, and the row is the first place they will see it.
    ///
    /// **The example is lowercase on purpose**, and it is the likeliest case a
    /// writer meets this in: `TranslationRecord.isValidLanguageTag` is lowercase
    /// BCP-47-ish, so an outside session that stamped a query `pt-BR` leaves a row
    /// on this desk that no round can ever be run for. Naming the shape is what
    /// lets them see why.
    static func unusableTag(language: String) -> String {
        "\u{201C}\(language)\u{201D} isn\u{2019}t a language tag Maugham can write "
            + "an edition for, so there is nothing to run. Editions are tagged "
            + "lowercase, like \u{201C}es\u{201D} or \u{201C}pt-br\u{201D}."
    }

    /// **What a finished round says on the row that asked for it.**
    ///
    /// A rejection is carried WHOLE and never summarised: the sentence
    /// `TranslatorEnvironment` builds names the paragraphs, and which paragraphs
    /// they are is the only part of it the writer can act on (spec §6's "listing
    /// them"). Warnings are carried whole for the same reason — "2 warnings" tells
    /// nobody which constructs drifted.
    static func reportLine(
        _ outcome: TranslatorOrchestrator.RunSummary.Outcome) -> String? {
        switch outcome {
        case .ingested(let ingested):
            if let rejection = ingested.rejection { return rejection }
            return ([landedLine(entries: ingested.entriesWritten,
                                queries: ingested.queriesMinted)]
                    + ingested.warnings).joined(separator: "\n")
        case .nothingToTranslate:
            return nothingToTranslateLine
        case .cancelled:
            return cancelledLine
        case .failed(let failure):
            return failureCopy(failure)
        }
    }

    /// The two halves of what a round produces. **The questions are named only
    /// when there are some**: a "0 questions asked" said after every round is a
    /// figure the writer stops reading, and the day it matters they will not see
    /// it (the rule the query line on the row above already follows).
    static func landedLine(entries: Int, queries: Int) -> String {
        guard entries > 0 || queries > 0 else {
            return "The round wrote nothing and asked nothing."
        }
        let words = entries == 1 ? "1 paragraph translated"
                                 : "\(entries) paragraphs translated"
        guard queries > 0 else { return words }
        let asked = queries == 1 ? "1 question asked" : "\(queries) questions asked"
        return "\(words) \u{00b7} \(asked)"
    }

    /// **One spelling of a death, read by a third surface.**
    ///
    /// The `.run` arm delegates to `RoundNarrative.failureCopy` — the app's single
    /// switch over `CompilerRunFailure`, which the compiler's Diagnostics pane and
    /// Review's cockpit already read — passing `.translation` so the two arms whose
    /// sentence names the work say the translator's. A second switch here would be
    /// a third account of one death, which is exactly what
    /// `ReviewRoundCockpitTests`' one-spelling census is against.
    ///
    /// `.ingestRejected` has no such sibling: it is this loop's own ending, and its
    /// sentence was built where the ids are known.
    static func failureCopy(_ failure: TranslatorOrchestrator.Failure) -> String {
        switch failure {
        case .run(let runFailure):
            return RoundNarrative.failureCopy(runFailure, session: .translation)
        case .ingestRejected(let sentence):
            return sentence
        }
    }
}

// MARK: - The record of finished runs

/// **What the desk remembers about rounds that have ended** (P4 Task 3).
///
/// `TranslatorOrchestrator.RunSummary`'s own doc names the destination — "for
/// whoever keeps the record (P4's desk)" — and this is it. It is window-scoped
/// rather than pane-scoped because `Environment.onRunEnded` is wired when the
/// window's stores are configured, long before anybody opens the department pane,
/// and because a report that vanished when the writer looked at Visual Language and
/// came back would be a record that only survives being watched.
///
/// **Keyed by the pair, because a run is a pair.** A log keyed by language alone
/// would let a Spanish round on chapter 2 overwrite the report the writer is still
/// reading about chapter 1 — and `DepartmentRunState.resolve` checks the docId
/// again on the way out, so a key that ever went wrong shows nothing rather than
/// showing the wrong chapter's round.
///
/// It holds nothing but summaries: no store, no orchestrator, nothing that keeps a
/// project alive. Runs are bounded by the pairs a book has.
@MainActor
@Observable
final class TranslationRunLog {

    private(set) var runs: [TranslatorOrchestrator.Pair:
                            TranslatorOrchestrator.RunSummary] = [:]

    func record(_ summary: TranslatorOrchestrator.RunSummary) {
        runs[TranslatorOrchestrator.Pair(docId: summary.docId,
                                         language: summary.language)] = summary
    }

    func run(docId: String,
             language: String) -> TranslatorOrchestrator.RunSummary? {
        runs[TranslatorOrchestrator.Pair(docId: docId, language: language)]
    }
}
