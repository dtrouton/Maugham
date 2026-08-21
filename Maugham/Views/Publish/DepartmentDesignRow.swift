import Foundation
import MaughamCore

/// **The DESIGN half of the department desk, as decisions rather than as a
/// view** (publish-department P4 Task 4).
///
/// `DepartmentRunState`'s sibling one section up the pane, written to the same
/// rule and for the same reason: everything the Design row draws or refuses is a
/// pure function here, so the whole surface is drivable from literals and
/// `DepartmentPane` goes on taking values and holding no store
/// (`DepartmentPaneTests.test_theSourceReadsNoStoreAtAll`).
///
/// **Where it departs from the language rows, and why.**
///
/// - **There is one design line for the whole book**, not one per language
///   (spec §5), so nothing here is scoped to a pair the way every decision in
///   `DepartmentRunState` is. The desk's ruling for this milestone is that
///   `runDesign` is called with `language: nil` — no picker, no per-edition
///   round — so the row is about the book's design, full stop.
/// - **A design round's PRODUCT is on the desk.** A translation round writes
///   paragraphs the desk cannot show, which is why a language row keeps a
///   report line from `TranslationRunLog`. A design round stages a *proposal*,
///   and the proposal is the row's own second line — so the round's account of
///   itself is the thing it made, re-derived, rather than a remembered
///   sentence. The only endings that leave nothing behind are a failure (which
///   `runState` carries) and the writer's own Cancel (which they performed).
/// - **A round stays OPEN after it ends** (`DesignerOrchestrator
///   .hasOpenProposalRound`), which is what Request changes acts on. Nothing in
///   the translator's loop has an equivalent.

// MARK: - What the one designer session is doing

/// **Whether the window's single designer session is free**, and which round has
/// it when it is not.
///
/// `DepartmentRunSession`'s shape, keyed on the round rather than an edition:
/// `DesignerOrchestrator` holds one warm `claude` per project and refuses a
/// second round outright (`runDesign`'s `!isRunning` guard) — silently, which is
/// what Global Constraint 2 forbids a surface to leave at that.
enum DesignSession: Equatable {
    case free
    /// A round is under way. `round` is `nil` in the window between the click
    /// and the send, while the briefing is gathered: `isPreparingRun` counts as
    /// running there and `runState` has not named a round yet. Short — an AST
    /// build and a template walk — and a writer double-clicking is exactly who
    /// lands in it.
    case busy(round: Int?)

    static func read(runState: DesignerOrchestrator.RunState,
                     isRunning: Bool) -> DesignSession {
        guard isRunning else { return .free }
        if case .running(let round, _) = runState { return .busy(round: round) }
        return .busy(round: nil)
    }
}

// MARK: - What this project can be briefed for

/// **Whether a design round is a round at all** — the two things
/// `DesignerEnvironment`'s briefing refuses a project for, asked at the desk so
/// the click gets words instead of vanishing.
///
/// `DesignerOrchestrator.begin` treats a `nil` briefing as "not a run": it
/// abandons, sets no state and emits no summary, so a writer whose project has
/// no publish tree presses Run and *nothing whatever happens*. That is the
/// silent no-op Global Constraint 2 exists against, and Task 3's report handed
/// it forward by name.
///
/// **Asked by CALLING the same two gates, never by re-spelling them.** The
/// publish-tree question is `PublishStarter.isInitialized`, the identical call
/// the briefing makes. The book question is `ProjectStoreASTSource
/// .publishablePieces()` — the very list `orderedPieces()` maps over, extracted
/// so the desk can ask "is there a book" without materializing one; the
/// briefing's own test is `ast.sections.isEmpty`, and
/// `DepartmentRunTests.test_thePublishablePiecesAreExactlyTheSectionsTheASTWouldBuild`
/// is what keeps the two from drifting.
///
/// **What is deliberately NOT closed here**: `ProjectASTBuilder.build` can also
/// throw, when a piece's own history is unreadable (RULING-54). That is a
/// damaged project rather than a project with nothing to design, its own
/// surfaces already say so loudly on a compile, and asking it at the desk would
/// mean materializing every chapter on a click to answer a question about none
/// of them.
enum DesignBriefability: Equatable {
    /// There is a template set to revise and a book to revise it for.
    case ready
    /// `.maugham/publish/` has never been initialized, so there is nothing to
    /// redesign — and the sample compile would fail at the copy for the same
    /// reason.
    case noPublishTemplates
    /// No piece the publish path would render, so the census would find nothing
    /// and the sample pages could only be empty.
    case noBook
}

// MARK: - The row

/// **Everything the Design row draws**, resolved from the project's staged
/// proposals and the window's designer session.
struct DepartmentDesignRow: Equatable {

    /// **What the last thing the design verbs did.**
    ///
    /// `DepartmentRunState.Phase`'s counterpart. `DesignerOrchestrator.RunState`
    /// returns to `.idle` on a round that staged — what it produced is the
    /// proposal, which is `latestLine`'s subject — so there is no success arm
    /// here and nothing to invent one for.
    enum Phase: Equatable {
        case idle
        /// The round number, and the edition when a round was started for one.
        /// The desk starts none (the milestone's ruling: `language: nil`), but
        /// an outside caller can, and a row that dropped the edition would
        /// describe somebody else's round as the book's.
        case running(round: Int, language: String?)
        case failed(DesignerOrchestrator.Failure)
    }

    /// Who signs this book's design — `ProductionRole.effectiveName`, resolved
    /// where every other reader of it resolves it (`ProjectStore.designerRole`),
    /// so the name on the desk and the name on the proposal are one string.
    var designerName: String = ProductionRole.presetDesigner.effectiveName

    /// The badge for a proposal still waiting on the writer's verdict, or `nil`.
    /// At most one can be pending — `DesignProposalStore.stage` supersedes every
    /// pending proposal before it mints — so this is a badge and not a count.
    var pendingBadge: String? = nil

    /// The newest round's own line: which round, where it stands, how long ago.
    /// Never `nil`: a project with no round yet says so, because a blank line
    /// under a designer's name reads as a surface that failed to load.
    var latestLine: String = DepartmentDesignRow.noRoundYet

    var phase: Phase = .idle

    /// Why the design verbs refuse, or `nil` when they are pressable. Never an
    /// empty string.
    var refusal: String? = nil

    /// Whether the session that made the standing proposal can still be asked to
    /// revise it — `DesignerOrchestrator.hasOpenProposalRound`. The control is
    /// drawn only while this is true, because outside it the honest verb is Run
    /// with the writer's words as the round's direction, which is a different
    /// button already on the row.
    var offersRequestChanges: Bool = false

    /// **Whether there is a round to go and look at** (P4 Task 5) — the door to
    /// the gate in the centre column, and the close of Task 4's third concern
    /// (the row drew a pending badge and nothing on it was clickable through).
    ///
    /// It is about the NEWEST proposal, whatever its status, so the row's second
    /// line and its control are about the same thing. And it is deliberately NOT
    /// folded into `refusal`: reading a staged proposal contends with nothing —
    /// the files are on disk and the warm session is not involved — so Show
    /// stays available while a round is running, which is exactly when a writer
    /// wants to re-read what the last one proposed.
    var offersShow: Bool = false

    var canRun: Bool { refusal == nil }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// **The row's one transient line** — what the round is doing, or how the
    /// last one died. `nil` at idle, where `latestLine` is what the row has to
    /// say: a report line under a proposal line would be two accounts of the
    /// same round, and the proposal is the account that survives a relaunch.
    var statusLine: String? {
        switch phase {
        case .running(let round, let language):
            return Self.designingLine(round: round, language: language)
        case .failed(let failure):
            return Self.failureCopy(failure)
        case .idle:
            return nil
        }
    }

    /// **The whole row, from the project's proposals and the window's session.**
    ///
    /// `proposals` arrives newest-first (`DesignProposalStore.list()`'s own
    /// order) and is read exactly twice: the newest of any status for the line,
    /// and the newest still pending for the badge.
    static func resolve(designerName: String,
                        proposals: [DesignProposalStore.Proposal],
                        runState: DesignerOrchestrator.RunState,
                        session: DesignSession,
                        hasOpenProposalRound: Bool,
                        now: Date = Date()) -> DepartmentDesignRow {
        var phase = Phase.idle
        switch runState {
        case .running(let round, let language):
            phase = .running(round: round, language: language)
        case .failed(let failure, _):
            phase = .failed(failure)
        case .idle:
            break
        }

        return DepartmentDesignRow(
            designerName: designerName,
            pendingBadge: proposals.contains { $0.status == .pending }
                ? pendingBadgeTitle : nil,
            latestLine: proposals.first.map { latestLine($0, now: now) } ?? noRoundYet,
            phase: phase,
            refusal: refusal(session: session),
            offersRequestChanges: hasOpenProposalRound,
            offersShow: proposals.first != nil)
    }

    /// **Why the design verbs refuse**, or `nil`.
    ///
    /// One session per orchestrator, so a round in flight is the only standing
    /// reason: everything else a click can run into is asked at the click, where
    /// the answer is fresh (see `preflight`).
    static func refusal(session: DesignSession) -> String? {
        guard case .busy(let round) = session else { return nil }
        return busyReason(round: round)
    }

    /// **Everything that must be true before a design click reaches the
    /// orchestrator** — Global Constraint 2's pre-flight, answering with the
    /// sentence to show or `nil` to go ahead.
    ///
    /// The busy arm is the disabled button's own reason re-asked, because a
    /// control's disabled state lands on the next body pass and a fast second
    /// click can beat it. The other two are the arms that can *only* be caught
    /// here: `briefRound` answers `nil` for them and `DesignerOrchestrator
    /// .abandon()` sets no state and emits no summary, so the click vanishes.
    ///
    /// **Asked at the click rather than folded into `refusal`** — i.e. the
    /// button stays pressable — on purpose: both are questions about the disk,
    /// and a writer who asks Claude to set up publishing while this pane is open
    /// would otherwise face a button disabled by an answer that stopped being
    /// true. A stale refusal that cannot be pressed past is worse than a fresh
    /// one the press earns.
    static func preflight(session: DesignSession,
                          briefability: DesignBriefability) -> String? {
        if let refusal = refusal(session: session) { return refusal }
        switch briefability {
        case .ready: return nil
        case .noPublishTemplates: return noPublishTemplatesRefusal
        case .noBook: return noBookRefusal
        }
    }

    /// **Which of the two gates this project fails**, by calling them.
    ///
    /// Both calls are cheap on purpose — one file-existence check and one walk
    /// of the manifest's structure — so a click pays for its own honesty and
    /// nothing here materializes a chapter.
    @MainActor
    static func briefability(store: ProjectStore,
                             projectURL: URL) -> DesignBriefability {
        guard PublishStarter.isInitialized(in: projectURL) else {
            return .noPublishTemplates
        }
        guard !ProjectStoreASTSource(projectStore: store)
            .publishablePieces().isEmpty else { return .noBook }
        return .ready
    }

    /// **Why `requestChanges` said no**, in words.
    ///
    /// The verb answers a bare `false` — it is a guard over four conditions and
    /// carries no reason — so the sentence is composed here from the same three
    /// the writer can actually be in. That is a second reading of another type's
    /// guard and it is stated as such: the fourth condition (no environment) is
    /// the window having gone away, which the caller answers with its own
    /// sentence before it ever gets here.
    ///
    /// Order matters. A round in flight outranks everything, because it is the
    /// fact that changes what pressing anything on this row will do.
    static func changesRefusal(words: String,
                               session: DesignSession,
                               hasOpenProposalRound: Bool) -> String {
        if let refusal = refusal(session: session) { return refusal }
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return noWordsRefusal
        }
        guard hasOpenProposalRound else { return noOpenRoundRefusal }
        return unknownRefusal
    }

    /// **The one spelling of "send the writer's words back to the standing
    /// round"** (P4 Task 6), answering `nil` when the words went and the
    /// refusal's own sentence otherwise.
    ///
    /// **Two surfaces reach it now** — the desk's Design row, and the gate in the
    /// centre column, which is where a writer actually forms the opinion the
    /// words carry. Composing the refusal is three reads of the orchestrator's
    /// state in a fixed order, and the second surface copying that composition
    /// would be two answers to "why did that not go", free to drift the moment
    /// `requestChanges` grows a fifth guard. `DesignerOrchestrator.requestChanges`
    /// is called from exactly here (`DesignGateTests
    /// .test_requestChangesHasOneSpellingAndBothSurfacesReachIt`).
    ///
    /// The `nil` designer is the window whose stores never finished loading, or
    /// a probe mount — a case the caller cannot compose a sentence for from the
    /// orchestrator's state, because there is no orchestrator.
    @MainActor
    static func sendChanges(_ words: String,
                            to designer: DesignerOrchestrator?) -> String? {
        guard let designer else { return noDesignerWired }
        if designer.requestChanges(words) { return nil }
        return changesRefusal(
            words: words,
            session: DesignSession.read(runState: designer.runState,
                                        isRunning: designer.isRunning),
            hasOpenProposalRound: designer.hasOpenProposalRound)
    }

    /// A window with no designer behind it. **Here rather than on the pane host**
    /// (P4 Task 6): it is the design half's sentence, and it is now read by two
    /// surfaces in two columns — the host's own `noTranslatorWired` stays where
    /// it is because the translation half has only ever had one.
    static let noDesignerWired =
        "This window isn\u{2019}t ready to run a design round yet. Try again in a "
        + "moment, or reopen the project."

    // MARK: - Copy

    static let runTitle = "Run"
    static let requestChangesTitle = "Request Changes"

    /// The door to the gate (P4 Task 5). **"Show" and not "Show Proposal"** —
    /// the row is the design, so the object is in the click, which is the same
    /// argument `DepartmentDesk.editionBriefTitle` makes one section down.
    static let showTitle = "Show"

    /// Distinct in the accessibility tree for `runAccessibilityLabel`'s reason:
    /// a bare "Show" is told apart from anything else on the pane only by the
    /// row it sits on, which a linear tree does not carry.
    static let showAccessibilityLabel = "Show the design proposal"

    static let showHelp =
        "Put the newest round in the centre column \u{2014} its written design, "
        + "the templates it stages, and the sample pages it was compiled on."

    /// **The Design row's rename verb, naming the designer it is about**
    /// (cast-management) — `DepartmentDesk.renameTitle`'s sibling, for the same
    /// reason: a desk full of "Rename…" is a desk of controls a VoiceOver user
    /// cannot tell apart. There is no nobody-yet arm here, because every project
    /// has Tschichold from the moment it exists.
    static func renameTitle(designerName: String) -> String {
        "Rename \(designerName)\u{2026}"
    }

    /// **The Run button's own name in the accessibility tree**, distinct from
    /// the language rows' Run.
    ///
    /// Three buttons on one pane all labelled "Run" are three buttons a
    /// VoiceOver user cannot tell apart, and the visible titles are told apart
    /// only by the row they sit on — which a linear tree does not carry. The
    /// visible title stays "Run" (spec §5's word for it); what is announced,
    /// and what a test finds the design verb by, is this.
    static let runAccessibilityLabel = "Run a design round"
    static let cancelAccessibilityLabel = "Cancel the design round"

    /// The direction field's prompt. **Optional, and it says so**: a bare round
    /// is briefed on the visual language statement alone, which is the whole
    /// point of having written one.
    static let directionPrompt =
        "What this round should do \u{2014} optional"

    static let pendingBadgeTitle = "Pending review"

    static let noRoundYet = "No design round yet."

    /// What Run offers, by the name of the person who answers it — the
    /// personification `RoundNarrative.runRoundTitle` established for the review
    /// passes, in this department's currency.
    static func runHelp(designerName: String) -> String {
        "Ask \(designerName) for a design of this book \u{2014} a written spec "
            + "and a complete template set, demonstrated on sample pages. "
            + "Nothing reaches the live templates until you approve it."
    }

    static let requestChangesHelp =
        "Send these words back to the session that made the standing proposal "
        + "and take the next round of it."

    static let cancelHelp =
        "Stop this round. Nothing it has designed is written \u{2014} a round "
        + "that does not finish stages nothing at all."

    /// The row's line while a round is in flight. Names the round, because
    /// "designing…" says nothing about how far into a conversation the writer
    /// is; and the edition, when a round was started for one.
    static func designingLine(round: Int, language: String?) -> String {
        guard let language else { return "Designing round \(round)\u{2026}" }
        return "Designing round \(round) of the "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " edition\u{2026}"
    }

    /// Why both verbs refuse while a round is warm. Names the round for the
    /// reason the language rows name the edition: the writer needs to know what
    /// they are waiting for.
    static func busyReason(round: Int?) -> String {
        guard let round else {
            return "A design round is starting. There is one designer session, "
                + "and the next round is the next click."
        }
        return "Round \(round) is running. There is one designer session, and "
            + "the next round is the next click."
    }

    /// The newest round's line: which round, where it stands, how long ago.
    static func latestLine(_ proposal: DesignProposalStore.Proposal,
                           now: Date = Date()) -> String {
        "Round \(proposal.round) \u{00b7} \(statusWord(proposal.status)) "
            + "\u{00b7} \(age(proposal.created, now: now))"
    }

    /// Where a proposal stands, in the writer's words rather than the store's.
    ///
    /// `.unknown` is carried raw on purpose: it is a status a NEWER build wrote
    /// (`DesignProposalStore.Status`' own discipline), and printing "unknown"
    /// over it would tell the writer their proposal is broken when it is merely
    /// from the future.
    static func statusWord(_ status: DesignProposalStore.Status) -> String {
        switch status {
        case .pending: return "waiting for your review"
        case .approved: return "approved"
        case .rejected: return "turned down"
        case .superseded: return "superseded"
        case .unknown(let raw): return raw
        }
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func age(_ date: Date, now: Date = Date()) -> String {
        ageFormatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - Refusals

    /// **A project with no publish tree cannot be redesigned**, and the sentence
    /// names the move rather than the state. Setting publishing up is a
    /// conversation with Claude (`initialize_publish_template`), which is what
    /// `docs/guide/publishing.md` tells the writer to ask for, so that is what
    /// this says.
    static let noPublishTemplatesRefusal =
        "This book has no publish templates yet, so there is nothing to "
        + "redesign. Ask Claude to set up publishing for this project, then run "
        + "a design round."

    static let noBookRefusal =
        "There are no pages to design for yet \u{2014} a design round is about "
        + "what the book actually contains. Write a chapter first."

    static let noWordsRefusal =
        "Say what to change in the box above, then ask again \u{2014} a round "
        + "of changes is your words."

    /// What is left when a proposal exists but the session that made it does
    /// not. `DesignerOrchestrator` closes an open round three ways: a fresh
    /// round superseding it, the session being retired, and the process behind
    /// the seam respawning. In every one of them the honest verb is Run, with
    /// the writer's words as the round's direction — which is the button beside
    /// this one, so the sentence points at it.
    static let noOpenRoundRefusal =
        "The session that made this proposal has moved on, so there is nothing "
        + "for it to revise. Press Run instead \u{2014} your words become the "
        + "new round\u{2019}s direction."

    /// The total-function arm. Reachable only if `requestChanges` grows a fifth
    /// guard without a sentence here, which is exactly when a writer must not be
    /// met with silence.
    static let unknownRefusal =
        "That request for changes couldn\u{2019}t be sent. Press Run instead to "
        + "ask for a fresh round."

    /// **One spelling of a death, read by a fourth surface.**
    ///
    /// The `.run` arm delegates to `RoundNarrative.failureCopy` — the app's
    /// single switch over `CompilerRunFailure` — passing `.design` so the two
    /// arms whose sentence names the work say the designer's. `.stagingRejected`
    /// has no sibling: it is this loop's own ending, and its sentence was built
    /// where the cause was known.
    static func failureCopy(_ failure: DesignerOrchestrator.Failure) -> String {
        switch failure {
        case .run(let runFailure):
            return RoundNarrative.failureCopy(runFailure, session: .design)
        case .stagingRejected(let sentence):
            return sentence
        }
    }
}
