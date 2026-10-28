import SwiftUI
import MaughamCore

// MARK: - What the pane says, per state — pure, so every sentence is a test without a mount

extension DiagnosticsPane {
    /// **What the wet-ink view has to say about this check, as far as the
    /// empty state's copy is concerned** (M4 P2 Task 1 review, Important 2).
    ///
    /// The invariant this type exists to keep: **the copy never announces as
    /// waiting what is visible or settled here.** Before it, the empty state
    /// read `CompilerRun.mintedNotes` — the historical record of what the run
    /// put in the queue — and said "2 notes went to your queue" over the two
    /// notes sitting directly above it with verbs on them, and went on saying
    /// it after the writer had settled both. A surface telling the writer to
    /// go elsewhere for what is in front of them is worse than one that says
    /// nothing.
    enum WetInk: Equatable {
        /// Nothing this check queued is accounted for here — either it queued
        /// nothing, or this pane cannot see the document's queue at all. The
        /// historical sentence is the honest one: those notes exist and the
        /// writer has to be told where.
        case none
        /// Rows are on screen. The section IS the news, so the copy beneath it
        /// says nothing about a queue.
        case showing
        /// This check queued notes and the writer has settled every one of
        /// them. Re-announcing them would be the pane forgetting what it just
        /// watched them do.
        case settled
    }

    /// Pure, on `headerCopy`'s rule — every sentence this pane can say is
    /// assertable without mounting anything.
    ///
    /// `queueVisible` is the honest half: with no document behind the pane
    /// there is no queue to read, so an empty `openNow` means "cannot see"
    /// rather than "handled", and the answer is `.none`.
    static func wetInkStanding(
        mintedNotes: Int?, queueVisible: Bool, openNow: Int
    ) -> WetInk {
        if openNow > 0 { return .showing }
        guard queueVisible, let mintedNotes, mintedNotes > 0 else { return .none }
        return .settled
    }

    // MARK: - Header state — pure, so every state is a test without a mount

    enum HeaderState: Equatable {
        case neverRun
        case idle(lastRun: CompilerRun)
        /// Carrying what the run is reading, so the wait is legible from the
        /// moment it starts (requirement 5) — and, since spec
        /// 2026-09-09 §5, WHEN it started and how far the model has got, so
        /// the same state read a minute later says a different sentence. Both
        /// are optional: a caller with no clock draws the line requirement 5
        /// shipped.
        case running(checking: CompilerOrchestrator.DeltaCounts,
                     since: Date?, progress: RunProgress?)
        case nothingNew(at: Date)
        case failed(CompilerRunFailure, at: Date)
        case clean(lastRun: CompilerRun)
    }

    /// Derives the header's state from the orchestrator's run state, the
    /// last-run record, and how many notes are currently live.
    ///
    /// `runState` wins whenever it describes something that just happened **to
    /// this document** — the `where` clause is on all three run-describing
    /// cases and not only on `.running`, because the run state is per-window
    /// while this pane is per-document. Anything about another document falls
    /// through to what is on disk here, which is also what makes a reopened
    /// project show its last answer rather than reverting to "never run".
    static func headerState(
        runState: CompilerOrchestrator.RunState,
        lastRun: CompilerRun?,
        noteCount: Int,
        docId: String,
        runStartedAt: Date? = nil,
        runProgress: RunProgress? = nil
    ) -> HeaderState {
        // **`.check` on all three arms** (#77 F7): this pane is Author's, and
        // the window's one run state also carries Review's rounds. A round on
        // this document falls through to what is on disk here — the pane's
        // OWN state — and `otherLoopLine` says the one sentence about it.
        switch runState {
        case .running(let runDocId, .check, let checking) where runDocId == docId:
            // The clock and the progress are the ORCHESTRATOR's, not the run
            // state's: they belong to the live turn rather than to the delta
            // it was launched over, and a caller with neither passes neither.
            return .running(checking: checking, since: runStartedAt, progress: runProgress)
        case .nothingNew(let runDocId, .check, let at) where runDocId == docId:
            return .nothingNew(at: at)
        case .failed(let runDocId, .check, let failure, let at) where runDocId == docId:
            return .failed(failure, at: at)
        default:
            guard let lastRun else { return .neverRun }
            return noteCount == 0 ? .clean(lastRun: lastRun) : .idle(lastRun: lastRun)
        }
    }

    /// **Review's round is holding the window's one session** (#77 F7) — the
    /// ruling's sentence, verbatim (Denver 2026-10-17, applied symmetrically by
    /// the controller to the cockpit's "Author's check is running" line).
    /// `static let` for `headerCopy`'s reason: every sentence this pane says
    /// is assertable without mounting anything.
    static let reviewsRoundIsRunningLine =
        "Review's round is running \u{2014} \u{2318}R waits until it finishes."

    /// **The one line this pane says about a run that is not its own here** —
    /// `nil` unless a ROUND is running, on ANY document (#77 F7 review
    /// ruling), or a check on another piece (#83, below). The
    /// pane's own states match by document (`headerState`), but the session
    /// is the window's: ⌘R here is refused while a round reads any piece, and
    /// a header that read idle over a refusal would be a dead control. It
    /// sits beside the header's own state rather than replacing it — the last
    /// check is still the last check — and ⌘R stays refused by the
    /// orchestrator's in-flight guard exactly as it was; this only says why
    /// before the press rather than after it.
    ///
    /// **And THIS loop's check on ANOTHER piece** (#83): the same session
    /// rule, so ⌘R here waits for it too, and the line names the piece it is
    /// reading (`RoundNarrative.runElsewhereLine`) by `titleOf` — a pure
    /// lookup the pane builds from the manifest, asked only for that arm. A
    /// check on this piece is the header's own `.running`, never this line.
    static func otherLoopLine(
        runState: CompilerOrchestrator.RunState, docId: String,
        titleOf: (String) -> String? = { _ in nil }
    ) -> String? {
        switch runState {
        case .running(_, .round, _):
            return reviewsRoundIsRunningLine
        case .running(let runDocId, .check, _) where runDocId != docId:
            return RoundNarrative.runElsewhereLine(kind: .check, title: titleOf(runDocId))
        default:
            return nil
        }
    }

    /// **Whether the cold-start offer's Read refuses** (#83): whenever the
    /// other-loop line is showing, the window's one session is another run's,
    /// and a Read pressed into it would only flash a refusal. (A check on
    /// this piece takes the pane off `.neverRun`, so the offer is not drawn
    /// at all then.) Pure, so the dead-control rule is assertable unmounted.
    static func refusesColdStartRead(otherLoopLine: String?) -> Bool {
        otherLoopLine != nil
    }

    /// **Whether the header offers Cancel** — over this pane's own check in
    /// flight, and over the other loop's run wherever it is (#77 F7 review
    /// ruling): the session is the window's, and a writer standing in Author
    /// while Review's round holds it must not be stranded in the wrong tab
    /// (nor on the wrong piece, while a check reads another one, #83).
    /// Every Cancel calls the one `orchestrator.cancel()`.
    static func offersCancel(state: HeaderState, otherLoopLine: String?) -> Bool {
        if case .running = state { return true }
        return otherLoopLine != nil
    }

    /// **Whether a row offers a fate at all — false for every row of a preview.**
    ///
    /// The notes on screen during `.running` came from a turn that has not
    /// ended: `finish` reconciles the whole turn with `parseAll` and REPLACES
    /// all of them, so a note answered mid-stream is answered against a record
    /// about to be superseded. Both fates end in `DiagnosticsStore.dismiss`,
    /// whose write would put the half-report on disk as the standing sidecar —
    /// with the run-start marker on it, so the prose the run stopped reading is
    /// never re-checked — and a completed turn would then raise the answered
    /// note again for a duplicate ruling.
    ///
    /// Pure and taking `HeaderState` rather than `RunState`, so it inherits
    /// `headerState`'s per-document scoping instead of reading the run state a
    /// second way: a run on ANOTHER document reaches here as `.idle`/`.clean`
    /// and this pane's rows keep their fates.
    ///
    /// Only `.running` withholds them. `.failed` and `.nothingNew` describe runs
    /// that are over, and the rows under them are the last finished run's, on
    /// disk — a writer must still be able to answer those.
    static func offersDurableActions(state: HeaderState) -> Bool {
        if case .running = state { return false }
        return true
    }

    /// **The cold-start offer's decision, pure** — no view mounted, the same
    /// idiom `headerState`/`emptyState` use for exactly this reason.
    ///
    /// True only for a document this build has genuinely never run
    /// (`state == .neverRun`; any run at all, even one that found nothing,
    /// moves `state` off this case for good), whose manuscript is more than a
    /// stub (`liveParagraphCount > 1` — the discriminator is LIVE paragraphs,
    /// never ops: an op count would call a document "worth reading" for a
    /// checkpoint or an annotation that touched no prose), and that the
    /// writer has not already refused.
    static func showsColdStartOffer(
        state: HeaderState, liveParagraphCount: Int, hasRefused: Bool
    ) -> Bool {
        guard case .neverRun = state else { return false }
        guard liveParagraphCount > 1 else { return false }
        return !hasRefused
    }

    /// The offer's one sentence. A `static let` for `headerCopy`'s reason —
    /// every sentence the pane can say is assertable without mounting anything
    /// — and because the property that it WRAPS rather than truncating is now
    /// pinned by a test (`DiagnosticsPaneColumnHeightTests`), which must ask
    /// production for the words rather than quote them.
    static let coldStartOfferSentence =
        "I haven\u{2019}t read this piece. Read it whole and take notes?"

    /// The header's one line, per state. Static and exhaustive for
    /// `emptyState`'s reason: every sentence the pane can say is then assertable
    /// without mounting anything.
    ///
    /// **Also carries `WetInk`, on the same rule as `emptyState`** — found by
    /// smoke, after the fix round that introduced `WetInk` only reached
    /// `emptyState`'s `ContentUnavailableView`. This header line renders
    /// unconditionally, ABOVE `content` and its own empty state (`body`'s
    /// `VStack(header, Divider, content)`), so a `.clean` run with mintedNotes
    /// still said "N notes went to your queue" here even after `emptyState`
    /// below it stopped saying it — the same defect, one call site over.
    ///
    /// `annotations`/`passes` feed `RoundNarrative.openElsewhere` (#53) — the
    /// queue and the ladder, so the cross-lane arm is live: a finding the
    /// writer has since settled in the other pass gives the seal back.
    /// REQUIRED, not defaulted: an empty queue over a new run reads as nothing
    /// held elsewhere, and the seal would stand over a finding the writer is
    /// holding — #42 I1's false clean bill. `nil` is "this pane cannot see the
    /// queue" (`visibleQueue`), which keeps the run's stored count instead.
    static func headerCopy(
        for state: HeaderState, wetInk: WetInk = .none, now: Date = Date(),
        annotations: [Annotation]?, passes: [ReviewPass]
    ) -> String {
        switch state {
        case .neverRun:
            return "Not checked yet \u{2014} press \u{2318}R to check your writing."
        case .idle(let run):
            // **What it cost, in one clause** (spec 2026-09-09 §5). Empty over
            // a run filed before timing existed, so the line a writer already
            // knows is unchanged to the byte.
            return "Last checked \(relative(run.at)) \u{00b7} \(run.deltaSummary)"
                + RoundNarrative.readInSuffix(run.timing)
        case .running(let checking, let since, let progress):
            // `.check`, always: this pane is Author's, and Author's ⌘R is the
            // check (two loops P1 Task 3). The cockpit passes `.round` at the
            // mirror of this line.
            //
            // `now` is a parameter rather than a `Date()` inside, so the clock
            // is what the `TimelineView` supplies and what a test moves.
            return RoundNarrative.checkingCopy(
                checking, kind: .check,
                elapsed: since.map { now.timeIntervalSince($0) },
                thinkingTokens: progress?.thinkingTokens)
        case .nothingNew:
            return "Nothing new since the last check."
        case .failed(let failure, _):
            // `RoundNarrative`'s, since 2026-08-18 — Review's cockpit says the
            // same sentence over the same death, and this pane is one caller
            // among two rather than the owner (the hoist `checkingCopy` and the
            // round lines already made).
            return RoundNarrative.failureCopy(failure)
        case .clean(let run):
            // **`.clean` means this PANE has nothing to show, which is not the
            // same as the run having found nothing** (M4 P1). A run that raised
            // three continuity questions and no conformance strain leaves this
            // store empty and the writer's queue three notes fuller; "Nothing
            // to flag" over it is the surface affirming a falsehood. The
            // queued sentence therefore REPLACES the seal rather than being
            // appended to it — the two cannot both be true.
            //
            // Unless `wetInk` says those notes are RIGHT HERE, below this
            // header, on this same pane — showing with their own verbs, or
            // already settled. Then "N notes went to your queue" would point
            // the writer somewhere else for what is (or was) directly beneath
            // this line, so it drops to the same "Nothing to flag" the header
            // has always said when a run truly minted nothing.
            //
            // **A round whose findings were already open in another pass gets
            // the same treatment** (#42, whole-branch review I1): nothing
            // landed here and nothing landed in the queue this writer is
            // looking at, so the seal would affirm the same falsehood one case
            // along. It sits below the queued sentence — notes that really
            // landed are the stronger news — and inside the `.none` arm alone,
            // exactly where the seal it replaces lives: under `.showing` /
            // `.settled` this run's own notes are on screen beneath the header,
            // and that arm's whole point is not to send the writer elsewhere.
            let opening: String
            switch wetInk {
            case .none:
                if let queued = queuedNotesSentence(run.mintedNotes) {
                    opening = queued
                } else if RoundNarrative.openElsewhere(
                    run: run, annotations: annotations, passes: passes) != nil {
                    opening = "Nothing new to flag"
                } else {
                    opening = "Nothing to flag"
                }
            case .showing, .settled:
                opening = "Nothing to flag"
            }
            // **What it cost, on this arm too** (spec 2026-09-09 §5, and the
            // whole-branch review). A first reader raises no conformance
            // strain, so every check of hers lands here rather than on
            // `.idle` — a "read in" that only the `.idle` arm carried was a
            // clause the reader who most needs it never saw. Inside the
            // sentence, before the full stop, because the sentence is the
            // unit the writer reads.
            let line = "\(opening). Last checked \(relative(run.at))"
                + RoundNarrative.readInSuffix(run.timing) + "."
            // Appended rather than interleaved: the standing sentence is the
            // one the writer reads at a glance, and this is the footnote to it.
            guard let discarded = discardedNotesSentence(run.droppedDangling) else {
                return line
            }
            return "\(line) (\(discarded))"
        }
    }

    /// **What a run lost, said plainly and without alarm** — or `nil` when it
    /// lost nothing, which is what keeps the clean bill clean.
    ///
    /// One spelling, read by the header and by the empty state, because two
    /// copies of a sentence about the same number are two things that can
    /// disagree. It names what happened (the paragraphs moved) rather than what
    /// Maugham could not do about it: "unknown paragraphs" is the parser's
    /// vocabulary, and to the writer it reads as an error they caused.
    static func discardedNotesSentence(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 note arrived against a paragraph that has changed "
            + "and was discarded"
        default: return "\(count) notes arrived against paragraphs that have "
            + "changed and were discarded"
        }
    }

    /// **What a run put in the queue**, or `nil` when it put nothing there —
    /// the one spelling, read by the header and by the empty state, on
    /// `discardedNotesSentence`'s rule that two sentences about the same fact
    /// are two sentences that can disagree.
    ///
    /// `nil` for `nil` as well as for zero: a record written before the field
    /// existed, and a preview, both know nothing about a mint, and a surface
    /// must not claim "0 notes went to the queue" on their behalf.
    ///
    /// It names the destination rather than the count alone, because the
    /// writer has to know WHERE to go and this pane is not it.
    static func queuedNotesSentence(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1
            ? "1 note went to your queue"
            : "\(count) notes went to your queue"
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// What an empty pane says, per state. Pure and exhaustive so each answer
    /// is assertable without a mount, and so no state can fall through to
    /// another's copy.
    ///
    /// **A failed check gets neither the seal nor "Nothing to flag."** Those
    /// two say the compiler looked and found nothing; a run that died never
    /// looked, and the header is already carrying the honest sentence about
    /// why. Repeating it here would be the pane saying the same thing twice
    /// under a checkmark that contradicts it.
    ///
    /// **Nor does a run that lost every note it raised.** That is the adjacent
    /// case rather than the same one: it looked, it spoke, and Maugham could
    /// not place what it said. The seal is for a run that came back with
    /// nothing to say — 0 raised and 0 discarded — so a discard takes the
    /// checkmark off without borrowing the failure's warning triangle.
    ///
    /// **And it never announces as waiting what the pane is already showing**
    /// (M4 P2 Task 1 review, Important 2 — see `WetInk`). `wetInk` defaults to
    /// `.none`, which is the pre-§7.0 world and what every state that has no
    /// notes of its own passes; the two other answers replace the queued
    /// sentence rather than joining it, on `queuedNotesSentence`'s own rule
    /// that two sentences about one fact are two sentences that can disagree.
    ///
    /// `annotations`/`passes` are `headerCopy`'s, for its reason (#53): the
    /// seal and the header read one live projection.
    static func emptyState(
        for state: HeaderState, wetInk: WetInk = .none,
        readerName: String = AuthorReader.nobody.editorName,
        annotations: [Annotation]?, passes: [ReviewPass]
    ) -> (title: String, symbol: String, description: String) {
        // **Ordered above every arm below**, including the failure and
        // never-run ones, is deliberate only in appearance: `wetInk` is
        // `.none` in both — a run that never happened queued nothing, and a
        // failed one minted nothing — so this branch cannot capture them.
        switch wetInk {
        case .none:
            break
        case .showing:
            return ("Nothing else to flag.", "checkmark.seal",
                    clauseSentence(for: state))
        case .settled:
            return ("You\u{2019}ve handled this check\u{2019}s notes.", "checkmark.seal",
                    clauseSentence(for: state))
        }
        switch state {
        case .neverRun:
            return ("Not checked yet", "checkmark.seal",
                    "Press \u{2318}R and \(readerName) reads what you've written.")
        case .running(let checking, _, _):
            // The empty state names the delta and never the clock: it is a
            // placeholder for a list, not the header's live line.
            guard let phrase = RoundNarrative.paragraphPhrase(checking) else {
                return ("Checking\u{2026}", "hourglass",
                        "Claude is reading what you've written since the last check.")
            }
            return ("Checking\u{2026}", "hourglass", "Claude is reading \(phrase).")
        case .failed:
            return ("No notes", "exclamationmark.triangle",
                    "The last check didn't finish, so there are none from it.")
        case .clean(let run) where queuedNotesSentence(run.mintedNotes) != nil:
            // **The seal may not stand over a run that queued notes** (M4 P1).
            // This pane holds conformance strains alone; the questions and the
            // reader's reports went somewhere the writer has to be told about,
            // and a checkmark saying "nothing to raise" is the opposite of what
            // happened. Ordered above the discarded arm because it is the
            // stronger claim: a run can have queued notes AND lost some, and
            // the queued ones are the news.
            let queued = queuedNotesSentence(run.mintedNotes) ?? ""
            return ("Notes in your queue", "tray.and.arrow.down",
                    "\(queued). " + clauseSentence(for: state))
        case .clean(let run)
            where RoundNarrative.openElsewhere(
                run: run, annotations: annotations, passes: passes) != nil:
            // **The seal may not stand over a round whose findings were
            // already open in another pass either** (#42, whole-branch review
            // I1) — the same argument as the queued arm above, one case along,
            // and from the same ruling that produced the count. This round
            // raised something; the mint refused it because the writer is
            // holding it in a lane they cannot see from here, so nothing
            // reached this pane and nothing reached their queue. "The compiler
            // found nothing to raise" is then the opposite of what happened.
            //
            // **And this is precisely where the since-line cannot help**: the
            // cross-lane-only round is most often round 1 of a lane, where
            // that line is silent by construction (nothing behind it to be
            // "since"). Below the queued arm because notes that really landed
            // are the stronger news; above the discarded arm because that one
            // still wears the seal, and the discard footnote is carried along
            // by `clauseSentence` rather than lost.
            let elsewhere = RoundNarrative.openElsewhere(
                run: run, annotations: annotations, passes: passes)
            return ("Nothing new to flag.", "tray.full",
                    (elsewhere?.sentence ?? "") + " " + clauseSentence(for: state))
        case .clean(let run) where discardedNotesSentence(run.droppedDangling) != nil:
            return ("Nothing to flag.", "circle.dashed",
                    (discardedNotesSentence(run.droppedDangling) ?? "") + ".")
        case .idle, .nothingNew, .clean:
            // `.idle` cannot reach here, and the reason is a pair rather than
            // one function: `content` renders this only when `hasReport` is
            // false, which requires `strains` to be empty, and `headerState` is
            // handed that same `strains` count — so an empty report and
            // `.clean` are the same condition read twice. (Before M4 P1 the
            // count came from `rows`, which since the slimming can hold notes
            // this pane refuses to draw; a legacy sidecar of continuity rows
            // reached this arm as `.idle` and called itself clean.) Named
            // rather than defaulted so a new state cannot inherit this copy by
            // omission.
            return ("Nothing to flag.", "checkmark.seal",
                    "The compiler found nothing to raise against the last check.")
        }
    }

    /// **What the check found against the writer's own clauses, plus what it
    /// lost** — the sentence under every empty state that describes a run
    /// rather than the absence of one.
    ///
    /// One spelling, read by the queued arm and by both wet-ink arms, on
    /// `discardedNotesSentence`'s rule: three copies of a sentence about the
    /// same two facts are three things that can drift apart. The discard
    /// footnote is appended rather than interleaved, exactly as it was, and is
    /// absent for any state that carries no run to have lost anything.
    static func clauseSentence(for state: HeaderState) -> String {
        let base = "No clause you declared strained in this check."
        guard case .clean(let run) = state,
              let discarded = discardedNotesSentence(run.droppedDangling) else { return base }
        return base + " (\(discarded).)"
    }
}
