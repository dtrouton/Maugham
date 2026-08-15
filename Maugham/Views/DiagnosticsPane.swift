import SwiftUI
import MaughamCore

/// The compiler's report on the open document — Author's own pane, reached by
/// ⌘⌥D or by leading its picker (`Persona.author.panes`).
///
/// **It reads as a report, in the second draft's order** (spec §5): the
/// conformance summary first — every clause the writer declared, quoted back in
/// their own words, each holding or straining or silent — then the continuity
/// questions, then the reader's report. The summary renders whether or not a
/// single note came with it, because a run whose clauses all hold is not an
/// empty pane: it is the good outcome, and a pane that showed nothing for it
/// would say the check never happened.
///
/// The register is Maugham's: nothing here bounces, nags, or apologises for
/// what it found. A clean run says so plainly; a failed one names what went
/// wrong in one honest sentence and nothing more.
///
/// **No paragraph id is ever rendered.** Every reference travels as a `Ref`
/// carrying the words that paragraph said when the note landed, and the pane
/// draws those words as a chip that clicks through to the prose
/// (requirement 3, `test_noParagraphIdIsEverRendered`).
///
/// **The report can be half-arrived, and the pane needs no case for it.** The
/// compiler streams its answer, so `CompilerOrchestrator` stores each section
/// as its line closes (`DiagnosticsStore.preview`) and the version counter
/// draws it — the conformance summary is readable while the reader's report is
/// still being written. Nothing here *labels* a preview as one, deliberately:
/// the header is already saying "Checking…", which is the one sentence that has
/// to be true, and a second badge saying the same thing would be the pane
/// narrating its own plumbing. What a preview must never do is OUTLIVE its run
/// — that is the orchestrator's discard, not this view's.
///
/// **But a preview is not a run, so its rows carry no fates** (`offersDurableActions`).
/// Reading is the preview's whole value; Answer and Promote arrive with the
/// reconciled report at finish. Acting on a streamed note used to write the
/// half-report to the sidecar through `DiagnosticsStore.dismiss` — a cancelled
/// run then read it back as the standing answer, carrying a delta marker the
/// finished check never earned, and a completed run resurrected the answered
/// note for a second, duplicate ruling. The store refuses that write on its own
/// side too (`dismiss`'s precondition), so this is a hidden button over a shut
/// door rather than the only guard.
///
/// **Drift is one line, above the conformance summary.** v2 dropped the
/// `intent_drift` field; what stands in its place is not a note kind but a
/// PATTERN — a clause straining the same way across consecutive runs, read
/// on demand from `DiagnosticsStore.clauseStatusHistory` by the pure
/// `DriftDetector`. It is deliberately not a `Diagnostic`: no id, no
/// dismissal, no reply field. Pressing it opens Intent (spec §4's last
/// bullet); the pattern breaking is what takes it away, the next time the
/// version bumps. See `driftNote`.
///
/// **The cold-start offer replaces the plain empty state, once, for a
/// document worth reading.** Spec §4: *"one refusable offer... On-demand,
/// never background, never re-asked as a nag."* Drawn only in place of
/// `.neverRun`'s "Not checked yet" line — never a sheet, never something that
/// appears unasked — for a manuscript with more than a stub of prose
/// (`showsColdStartOffer`'s `liveParagraphCount > 1`). **Read** calls
/// `orchestrator.runRequested` exactly as ⌘R does: the offer is UI over the
/// existing first-run path (a document with no prior marker already reads as
/// "everything is new"), never a second run kind. **Not now** records the
/// refusal in `DiagnosticsStore` and the offer never renders again for this
/// document — the writer says no once, not every time they open the pane.
@MainActor
struct DiagnosticsPane: View {
    let orchestrator: CompilerOrchestrator
    @Bindable var diagnostics: DiagnosticsStore
    let docId: String
    /// `(paragraphId) -> the paragraph's text now` — `DiagnosticsStore.live`'s
    /// staleness check. Mirrors `CompilerEnvironment+Project`'s
    /// `liveParagraphText` closure rather than reaching for a `Document`
    /// itself, so this view has no opinion about where paragraphs live.
    let currentText: (String) -> String?
    let compilerModel: CompilerModelChoice
    var onCompilerModelChange: (CompilerModelChoice) -> Void = { _ in }
    /// The document a promoted note becomes a task on — `TasksPane.activeDoc()`'s
    /// idiom, a closure rather than a `Document` so this view still holds no
    /// editor state (tripwires 3, 6). Defaulted so the callers that only read
    /// notes keep compiling; a `nil` return means there is nothing to promote
    /// onto, and the note is left where it is rather than dismissed into
    /// nowhere.
    var activeDocument: @MainActor () -> Document? = { nil }
    /// The project an answered question becomes a ruling in. Optional, and its
    /// absence is what takes the **Answer** action off every row rather than
    /// leaving one that presses into nowhere — see `offersAnAnswer`.
    var store: ProjectStore? = nil
    /// The derivation cache a ruling has to drop.
    ///
    /// **Not optional out of convenience.** A reply that lands as a ruling
    /// changes the prose the next run's clauses are derived from, and a cached
    /// reading made before it would check the writer against a world they have
    /// just changed — with nothing red, a run later. The deprecated answer shim
    /// passed `nil` here because no pane held the store; `ProjectWindow` builds
    /// one now, and this is where it arrives.
    var world: DeclaredWorldStore? = nil

    @Environment(\.undoManager) private var undoManager

    /// Per note: an answer in flight, and the sentence the last one refused
    /// with. Both live on the pane rather than in `DiagnosticRow` because the
    /// commit is asynchronous and the row that started it is gone on success —
    /// a row owning its own in-flight flag could only clear it by outliving
    /// the thing that clears it.
    @State private var answering: Set<String> = []
    @State private var answerFailures: [String: String] = [:]

    // MARK: - Reads

    /// Observing `diagnostics.version` forces re-render on every store
    /// mutation — the `AnnotationsPane.kindStatusAnnotations` idiom.
    private var rows: [Diagnostic] {
        _ = diagnostics.version
        return diagnostics.live(docId: docId, currentText: currentText)
    }

    private var lastRun: CompilerRun? {
        _ = diagnostics.version
        return diagnostics.lastRun(docId: docId)
    }

    /// Every clause the last run checked, whatever the answer. Empty for a run
    /// made with nothing declared — the schema tolerates an empty `checks`
    /// array and absence is valid (spec §7).
    private var clauses: [DiagnosticIngest.ClauseStatus] { lastRun?.clauseStatuses ?? [] }

    /// Every clause straining a pattern across runs, for the document this
    /// pane is showing. `DriftDetector` is pure — no store, no caching — and
    /// is read fresh off the version-gated ring the same way `rows`/`lastRun`
    /// read the store's notes; its own doc: "computed from records, never a
    /// background process."
    private var driftFindings: [DriftFinding] {
        _ = diagnostics.version
        return DriftDetector.drift(history: diagnostics.clauseStatusHistory(docId: docId))
    }

    /// The rounds this document has finished, oldest→newest — the ring the
    /// since-last-round line is measured against, read the same version-gated
    /// way as everything else here.
    private var roundHistory: [RoundRecord] {
        _ = diagnostics.version
        return diagnostics.roundHistory(docId: docId)
    }

    /// The three note kinds, split into the sections that render them.
    ///
    /// A note whose `kind` is `nil` belongs to none of them — and cannot reach
    /// here: `DiagnosticsStore.load` drops v1 records as superseded, and this
    /// pane calls `load` in its own `onAppear`.
    private var strains: [Diagnostic] { rows.filter { $0.kind == .conformanceStrain } }
    private var questions: [Diagnostic] { rows.filter { $0.kind == .continuity } }
    private var readerReports: [Diagnostic] { rows.filter { $0.kind == .readerReport } }

    /// Is there a report to draw at all? **Clauses count even with no notes** —
    /// that is the clean conformance report, and it is the outcome the writer
    /// most wants to see.
    private var hasReport: Bool { !clauses.isEmpty || !rows.isEmpty }

    private var state: HeaderState {
        Self.headerState(runState: orchestrator.runState, lastRun: lastRun,
                          noteCount: rows.count, docId: docId)
    }

    /// Whether the rows on screen may be acted on — read through `state`, which
    /// is this view's ONE reading of `orchestrator.runState` and already scopes
    /// it to this document (`headerState`'s `where runDocId == docId`). A run on
    /// another document leaves this pane's fates exactly where they were.
    private var offersDurableActions: Bool { Self.offersDurableActions(state: state) }

    /// Whether the pane's empty state should offer the cold-start read rather
    /// than show the plain "Not checked yet" line. Reads `activeDocument()`
    /// directly rather than through a closure of its own — the discriminator
    /// is the manuscript's LIVE paragraph count (tripwire-relevant: not the
    /// delta's "new" count, which counts ops since a marker this document has
    /// never had), and `activeDocument` already exists on this pane for
    /// `promote()`. Scoped to the `.neverRun` window only: once any run
    /// happens `state` moves off `.neverRun` for good (`headerState` never
    /// returns to it with a `lastRun` on record), so this stops reading
    /// `sequence` again for the rest of the document's life.
    private var showsColdStartOffer: Bool {
        _ = diagnostics.version
        return Self.showsColdStartOffer(
            state: state,
            liveParagraphCount: activeDocument()?.sequence.count ?? 0,
            hasRefused: diagnostics.hasRefusedColdStart(docId: docId))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            diagnostics.load(docId: docId)
            diagnostics.markRead(docId: docId)
        }
        .onChange(of: docId) { _, new in
            diagnostics.load(docId: new)
            diagnostics.markRead(docId: new)
        }
        // Notes landing while this pane is already on screen were never
        // unread: the picker's badge is for a run that finished somewhere the
        // writer wasn't looking. `markRead` does not bump `version`, so this
        // cannot re-enter itself.
        .onChange(of: diagnostics.version) { _, _ in
            diagnostics.markRead(docId: docId)
        }
    }

    // MARK: - Header state — pure, so every state is a test without a mount

    enum HeaderState: Equatable {
        case neverRun
        case idle(lastRun: CompilerRun)
        /// Carrying what the run is reading, so the wait is legible from the
        /// moment it starts (requirement 5).
        case running(checking: CompilerOrchestrator.DeltaCounts)
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
        docId: String
    ) -> HeaderState {
        switch runState {
        case .running(let runDocId, let checking) where runDocId == docId:
            return .running(checking: checking)
        case .nothingNew(let runDocId, let at) where runDocId == docId:
            return .nothingNew(at: at)
        case .failed(let runDocId, let failure, let at) where runDocId == docId:
            return .failed(failure, at: at)
        default:
            guard let lastRun else { return .neverRun }
            return noteCount == 0 ? .clean(lastRun: lastRun) : .idle(lastRun: lastRun)
        }
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

    /// One honest sentence per failure — no apology, no chirp. `cliNotFound`
    /// and `disabledByToggle` each name the surface that fixes them;
    /// `sessionDied` only ever reaches here for a death that was NOT the
    /// writer's own doing (`CompilerOrchestrator.finish` already routes the
    /// other three details to `.idle`), so its detail is worth showing rather
    /// than translating away.
    static func failureCopy(_ failure: CompilerRunFailure) -> String {
        switch failure {
        case .cliNotFound:
            return "Claude Code isn't installed. Set it up, then check "
                + "Settings \u{2192} General \u{2192} Claude integration."
        case .disabledByToggle:
            return "Claude access is off in Settings \u{2014} turn on "
                + "\u{201C}Allow Claude to connect (MCP)\u{201D} to check your writing."
        case .timedOut:
            return "The check took too long and was stopped."
        case .sessionDied(let detail):
            return "The compiler's session ended before it could answer: \(detail)."
        case .unusableOutput:
            return "Claude's answer couldn't be read as notes."
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        // No spinner: the register is understated, and the state word in
        // `headerLine` ("Checking 14 new paragraphs…") already says what's
        // happening — an indeterminate control here would only animate to say
        // it twice.
        HStack(spacing: 8) {
            // **This wraps, and it must NOT be made to wrap with
            // `fixedSize(horizontal: false, vertical: true)`.** A `Text`
            // already reports its WRAPPED height as its ideal for whatever
            // width it is proposed, so it wraps here without the modifier;
            // what the modifier adds is an *unbreakable minimum* height, and
            // AppKit resolves that minimum at a probe width far narrower than
            // the column — `cliNotFound`'s sentence came back ~400pt tall.
            // `NSSplitView` takes the tallest column, so a pane that cannot be
            // broken grows all three columns past the window: the tree is laid
            // out taller than the window and shows a band the writer cannot
            // scroll back up from, and the centre column's content is pushed
            // above the visible region. There is no max-height constraint for
            // AppKit to break here, which is why this fails differently from
            // the WIDTH conflict `DetailColumnWidthTests` documents.
            // Measured 2026-08-08 (macOS 26.5); see
            // `DiagnosticsPaneColumnHeightTests`.
            Text(headerLine)
                .font(.caption)
                .foregroundStyle(isFailureState ? Color.red : .secondary)
            Spacer()
            if case .running = state {
                Button("Cancel") { orchestrator.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            gearMenu
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var isFailureState: Bool {
        if case .failed = state { return true }
        return false
    }

    private var headerLine: String { Self.headerCopy(for: state) }

    /// The header's one line, per state. Static and exhaustive for
    /// `emptyState`'s reason: every sentence the pane can say is then assertable
    /// without mounting anything.
    static func headerCopy(for state: HeaderState) -> String {
        switch state {
        case .neverRun:
            return "Not checked yet \u{2014} press \u{2318}R to check your writing."
        case .idle(let run):
            return "Last checked \(relative(run.at)) \u{00b7} \(run.deltaSummary)"
        case .running(let checking):
            return checkingCopy(checking)
        case .nothingNew:
            return "Nothing new since the last check."
        case .failed(let failure, _):
            return failureCopy(failure)
        case .clean(let run):
            let line = "Nothing to flag. Last checked \(relative(run.at))."
            // Appended rather than interleaved: the standing sentence is the
            // one the writer reads at a glance, and this is the footnote to it.
            guard let discarded = discardedNotesSentence(run.droppedDangling) else {
                return line
            }
            return "\(line) (\(discarded))"
        }
    }

    /// **The legible wait** (requirement 5). "Checking 14 new paragraphs…",
    /// never a bare participle: a cold first run over a long delta takes about
    /// two minutes, and a writer watching an unqualified "Checking…" for that
    /// long cannot tell a working compiler from a hung one.
    ///
    /// Total over counts a delta cannot have — `beginRun` refuses an empty one
    /// before the running state is ever set — because a function that has to be
    /// reasoned about before it can be called is one a later caller gets wrong.
    static func checkingCopy(_ counts: CompilerOrchestrator.DeltaCounts) -> String {
        guard let phrase = paragraphPhrase(counts) else { return "Checking\u{2026}" }
        return "Checking \(phrase)\u{2026}"
    }

    /// What a delta is, in the writer's English — the ONE spelling, read by the
    /// header and by the empty state, because two sentences about the same two
    /// numbers are two things that can disagree.
    static func paragraphPhrase(_ counts: CompilerOrchestrator.DeltaCounts) -> String? {
        switch (counts.new, counts.revised) {
        case (0, 0):
            return nil
        case (let new, 0):
            return "\(new) new \(new == 1 ? "paragraph" : "paragraphs")"
        case (0, let revised):
            return "\(revised) revised \(revised == 1 ? "paragraph" : "paragraphs")"
        case (let new, let revised):
            // Always plural: the sum is at least two to reach this arm.
            return "\(new) new and \(revised) revised paragraphs"
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

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private var gearMenu: some View {
        Menu {
            ForEach(CompilerModelChoice.allCases, id: \.self) { choice in
                Button {
                    onCompilerModelChange(choice)
                } label: {
                    if choice == compilerModel {
                        Label(choice.displayName, systemImage: "checkmark")
                    } else {
                        Text(choice.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model: \(compilerModel.displayName)")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if showsColdStartOffer {
            coldStartOffer
        } else if !hasReport {
            let empty = Self.emptyState(for: state)
            ContentUnavailableView(
                empty.title,
                systemImage: empty.symbol,
                description: Text(empty.description))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    roundLine
                    driftLine
                    conformanceSection
                    continuitySection
                    readerSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// **The cold-start offer** (spec §4). Understated, on `content`'s
    /// register: no sheet, no alert — the same two-button margin-note shape
    /// the pane uses everywhere else (`DiagnosticRow`'s Answer/Promote row).
    @ViewBuilder
    private var coldStartOffer: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            // **No `fixedSize(horizontal:vertical:)` here, and the absence is
            // load-bearing** — see `header`'s own note. This sentence carried
            // one, and it is what Denver's 2026-08-08 smoke found: the whole
            // window's three columns laid out ~600pt taller than the window,
            // so the tree showed a band scrolled off the top that could not be
            // scrolled back, and the centre column's editor sat above the
            // visible region entirely. `DiagnosticsPaneColumnHeightTests`
            // measures it.
            Text(Self.coldStartOfferSentence)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            HStack(spacing: 8) {
                Button("Not now") { diagnostics.refuseColdStart(docId: docId) }
                    .buttonStyle(.bordered)
                Button("Read") { orchestrator.runRequested(docId: docId) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// **The report leads with the distance travelled** (spec §6): what the
    /// last round in this lane raised that is gone, what is still here, and
    /// what is new. Above the drift line and above the conformance summary,
    /// because it is the sentence a writer in a review pass reads first.
    ///
    /// Not a button and not a `Diagnostic`: there is nowhere for it to go —
    /// the notes it counts are drawn immediately below it — and nothing to
    /// dismiss. The next round replaces it; a round that cannot be compared
    /// simply has no line. See `sinceLastRoundLine`.
    @ViewBuilder
    private var roundLine: some View {
        if let line = Self.sinceLastRoundLine(
            history: roundHistory, run: lastRun, current: rows) {
            Text(line)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            Divider()
        }
    }

    /// **The drift line — a pattern across runs, not a note about one.**
    /// Above the conformance summary because it is a claim about a clause the
    /// summary is about to name again (spec §4's last bullet). Not a
    /// `Diagnostic`: no id, no dismissal, no reply field — pressing it opens
    /// Intent, and the pattern breaking is what takes the line away, not a
    /// tap. See `driftNote`.
    @ViewBuilder
    private var driftLine: some View {
        if let line = Self.driftNote(driftFindings) {
            Button {
                MaughamEvent.postDetailSegment(.intent)
            } label: {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Divider()
        }
    }

    /// **The report's first section, and the reason the pane exists** — the
    /// writer's own clauses, quoted, each with how this draft sat against it.
    @ViewBuilder
    private var conformanceSection: some View {
        let paired = Self.conformanceRows(clauses: clauses, strains: strains)
        if !paired.rows.isEmpty || !paired.orphans.isEmpty {
            PaneSectionHeader(title: "Conformance") {
                // The clauses are derived from the writer's intent statement,
                // and this is the door to it — the one place on the pane where
                // the declared world can be changed rather than answered.
                Button("Open Intent") { MaughamEvent.postDetailSegment(.intent) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(paired.rows) { row in
                ClauseRow(row: row, canAnswer: store != nil && offersDurableActions,
                          canPromote: offersDurableActions,
                          answering: answering, answerFailures: answerFailures,
                          onJump: { jump(toParagraph: $0) },
                          onPromote: { promote($0) },
                          onAnswer: { answer($0, to: $1) })
                Divider()
            }
            // A strain whose clause is not in this run's summary at all. It
            // cannot happen through the ingest — a strain and its `ClauseStatus`
            // are minted from the same entry — and it is drawn anyway, because
            // the alternative is a note the compiler raised disappearing with
            // nothing said.
            ForEach(paired.orphans) { note in
                noteRow(note)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var continuitySection: some View {
        if !questions.isEmpty {
            PaneSectionHeader(title: "Continuity") { EmptyView() }
            ForEach(questions) { note in
                noteRow(note)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var readerSection: some View {
        if !readerReports.isEmpty {
            PaneSectionHeader(title: "The reader") { EmptyView() }
            ForEach(readerReports) { note in
                noteRow(note)
                Divider()
            }
            // **One sentence, and nothing else.** The schema caps the reader at
            // its sharpest three; how many it went over is the model's business,
            // not the writer's, and a count here would read as something they
            // had lost.
            if let truncated = lastRun?.truncatedReader, truncated > 0 {
                Text("The reader had more to say.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func noteRow(_ diagnostic: Diagnostic) -> some View {
        DiagnosticRow(
            diagnostic: diagnostic,
            canAnswer: store != nil && Self.offersAnAnswer(diagnostic) && offersDurableActions,
            canPromote: offersDurableActions,
            isSubmitting: answering.contains(diagnostic.id),
            answerFailure: answerFailures[diagnostic.id],
            onJump: { jump(toParagraph: $0) },
            onPromote: { promote(diagnostic) },
            onAnswer: { answer($0, to: diagnostic) })
    }

    /// One clause of the summary and every strain raised against it.
    struct ConformanceRow: Identifiable {
        /// Where this clause sat in the run's own list. Part of the identity
        /// and nothing else — the rows are never sorted by it.
        let position: Int
        let status: DiagnosticIngest.ClauseStatus
        let strains: [Diagnostic]
        /// **Position first, then the writer's sentence.** The quote alone is
        /// not unique: `conformanceRows` deliberately renders a clause the
        /// writer declared twice as two rows (see its doc), which handed
        /// SwiftUI's `ForEach` two identical ids — undefined behaviour for the
        /// duplicate the design intends to keep.
        var id: String { "\(position)\u{0}\(status.clauseQuote)" }
    }

    /// Pair every clause with the strains raised against it, and report any
    /// strain left over.
    ///
    /// Pure and returned as a value rather than assembled in the body, so the
    /// pairing — including the leftovers, which are the interesting half — is a
    /// direct test without a mount. Matching is on the quoted clause because
    /// that is the only thing the two records share: `DiagnosticIngest` mints a
    /// `ClauseStatus` and a `.conformanceStrain` from one entry and stamps both
    /// with the same `clause_quote`.
    ///
    /// Clauses keep the order the run reported them in; a duplicate quote (the
    /// writer declared the same sentence twice) takes the same strains on both
    /// rows rather than dropping one — a wrong-looking duplicate is a smaller
    /// harm than a missing finding.
    static func conformanceRows(
        clauses: [DiagnosticIngest.ClauseStatus], strains: [Diagnostic]
    ) -> (rows: [ConformanceRow], orphans: [Diagnostic]) {
        let quotes = Set(clauses.map(\.clauseQuote))
        let rows = clauses.enumerated().map { position, status in
            ConformanceRow(
                position: position, status: status,
                strains: strains.filter { $0.clauseQuote == status.clauseQuote })
        }
        let orphans = strains.filter { strain in
            guard let quote = strain.clauseQuote else { return true }
            return !quotes.contains(quote)
        }
        return (rows, orphans)
    }

    // MARK: - Since last round (spec §6; the comparison itself is `RoundComparison`)

    /// **"Since round N−1: X resolved · Y persisting · Z new"**, or `nil` when
    /// this run is not a round that can be compared.
    ///
    /// Pure and static on `driftNote`'s mould, and for the same reason: the
    /// sentence is the pane's, the arithmetic is not. `RoundComparison.compare`
    /// is the ONE spelling of what matches what — the model rewords a finding
    /// every time it raises it, so a comparison written here against note prose
    /// would report every persisting note as one resolved plus one new, and the
    /// briefing and the line would then disagree about the same round.
    ///
    /// Silent in three cases:
    ///
    /// - the run carries no round number. A passless ⌘R is an ordinary M2 run;
    ///   there is no round for this to be *since*.
    /// - the newest record in its own lane is not the round immediately
    ///   before it. Round 1 has nothing behind it; a lane whose earlier rounds
    ///   have aged out of the ring has nothing left to compare; and — the case
    ///   this guard is really for — **a run still streaming has not filed the
    ///   round it supersedes yet**, so the newest same-lane record mid-preview
    ///   is round N−2. Without the check the pane would say "Since round 1"
    ///   over round 3's half-arrived report and then correct itself when the
    ///   turn ended. Within a lane the numbers are consecutive by construction
    ///   (`latestRound + 1`), so this costs nothing a finished round has.
    /// - the run was read with fresh eyes (Task 6). It was deliberately
    ///   briefed on no prior findings, so a difference measured against the
    ///   last round would be an artifact of the reading rather than of the
    ///   draft. Its header says what it is instead.
    ///
    /// `current` is what the pane is DRAWING (`rows`), not the run's whole
    /// stored report: a note the writer has edited behind is not on screen,
    /// and counting it as persisting would name something invisible.
    ///
    /// **This line and the run's own briefing can differ, and both are
    /// honest.** A writer who steps out of a lane and back is briefed on
    /// nothing (the previous round's prose was superseded two runs ago) while
    /// this line still counts, because the ring kept that round's fingerprints
    /// — enough to say what changed, never enough to say what was said.
    static func sinceLastRoundLine(
        history: [RoundRecord], run: CompilerRun?, current: [Diagnostic]
    ) -> String? {
        guard let run, let round = run.round, run.freshEyes != true else { return nil }
        guard let previous = history.last(where: {
            $0.passId == run.passId && $0.round != nil
        }), let previousNumber = previous.round, previousNumber == round - 1 else { return nil }

        let outcome = RoundComparison.compare(previous: previous, current: current)
        return "Since round \(previousNumber): \(outcome.resolved) resolved "
            + "\u{00b7} \(outcome.persisting) persisting \u{00b7} \(outcome.new) new"
    }

    // MARK: - Drift (spec §4's last bullet; findings computed by `DriftDetector`)

    /// **The one line above the conformance summary when a clause is
    /// drifting** — pinned to `findings.first`, in the order
    /// `DriftDetector.drift` reports it (the newest run's own clause order).
    /// With more than one, "and one more" says a second is drifting without
    /// counting how many — two findings and five read identically, the same
    /// discipline `readerSection`'s "The reader had more to say." keeps: how
    /// many is forensic detail the writer did not ask for.
    ///
    /// **No count beyond the fixed "three runs" is ever spoken**, either —
    /// not `DriftFinding.runsStraining`'s true streak length, which the
    /// detector reports honestly and can run past the threshold (its own
    /// doc: "the pane ... can choose to say so"; this pane chooses not to,
    /// for the reason above).
    static func driftNote(_ findings: [DriftFinding]) -> String? {
        guard let first = findings.first else { return nil }
        let quote = truncatedDriftQuote(first.clauseQuote)
        let andOneMore = findings.count > 1 ? " \u{2014} and one more" : ""
        return "Your line may have moved \u{2014} \u{201C}\(quote)\u{201D} has strained "
            + "three runs running\(andOneMore). Draft\u{2019}s right, or intent\u{2019}s right?"
    }

    /// How much of the clause the drift line's one sentence can carry —
    /// smaller than `IntentStrip.maximumLength` because this quote sits
    /// inside a longer sentence rather than filling a strip on its own.
    private static let driftQuoteMaxLength = 60

    /// `quote` if it fits, else cut at the last word boundary inside the
    /// budget and ellipsised — `IntentStrip.truncated`'s idiom, restated here
    /// because that one is `private` to its own file and the two truncate
    /// different budgets for different reasons.
    static func truncatedDriftQuote(_ quote: String) -> String {
        guard quote.count > driftQuoteMaxLength else { return quote }
        let head = String(quote.prefix(driftQuoteMaxLength))
        guard let lastSpace = head.lastIndex(of: " ") else { return head + "\u{2026}" }
        let cut = String(head[head.startIndex..<lastSpace])
            .trimmingCharacters(in: .whitespaces)
        return (cut.isEmpty ? head : cut) + "\u{2026}"
    }

    /// The glyph for one clause's answer. Deliberately three quiet marks: a
    /// strain is something to look at, not an error, and an alarm here would be
    /// the pane raising its voice at the writer's own declaration.
    ///
    /// A status this build has never heard of gets a neutral mark rather than
    /// falling into one of the three — `DiagnosticIngest` drops those at ingest,
    /// so this arm is unreachable through the run and exists so a later
    /// contract's fourth word cannot silently render as "holds".
    static func statusSymbol(_ status: String) -> String {
        switch status {
        case DiagnosticIngest.SectionField.holds: return "checkmark"
        case DiagnosticIngest.SectionField.strains: return "arrow.left.and.right"
        case DiagnosticIngest.SectionField.silent: return "circle.dashed"
        default: return "questionmark"
        }
    }

    /// What that glyph says aloud — VoiceOver reads this, and a mark alone is
    /// silent.
    static func statusWord(_ status: String) -> String {
        switch status {
        case DiagnosticIngest.SectionField.holds: return "holds"
        case DiagnosticIngest.SectionField.strains: return "strains"
        case DiagnosticIngest.SectionField.silent:
            return "nothing in this draft touches it"
        default: return status
        }
    }

    /// The reader section's own two-valued kind, as words — and **nothing
    /// else**. v2 mints no free-form category (spec §5: the tag is "removed
    /// from the shipped design"), so a value from anywhere but the schema
    /// renders no label at all rather than putting the old tag back on the pane
    /// through a side door.
    static func readerKindLabel(_ category: String?) -> String? {
        switch category {
        case DiagnosticIngest.SectionField.dreamBreak: return "Dream break"
        case DiagnosticIngest.SectionField.belief: return "Belief"
        default: return nil
        }
    }

    /// **Which notes offer to be answered** — the questions, and only them
    /// (spec §5's fates).
    ///
    /// A conformance strain and a continuity question both ask the writer
    /// something, and the writer's reply to either is a decision: it lands as a
    /// ruling. A reader report is not a question — "I stopped believing her
    /// here" has no answer to rule on — and a reply field under one would invite
    /// the writer to argue with a reader, which is not a decision that belongs
    /// in the declared world.
    static func offersAnAnswer(_ diagnostic: Diagnostic) -> Bool {
        switch diagnostic.kind {
        case .conformanceStrain, .continuity: return true
        case .readerReport, .none: return false
        }
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
    static func emptyState(
        for state: HeaderState
    ) -> (title: String, symbol: String, description: String) {
        switch state {
        case .neverRun:
            return ("Not checked yet", "checkmark.seal",
                    "Press \u{2318}R to ask Claude for notes on what you've written.")
        case .running(let checking):
            guard let phrase = paragraphPhrase(checking) else {
                return ("Checking\u{2026}", "hourglass",
                        "Claude is reading what you've written since the last check.")
            }
            return ("Checking\u{2026}", "hourglass", "Claude is reading \(phrase).")
        case .failed:
            return ("No notes", "exclamationmark.triangle",
                    "The last check didn't finish, so there are none from it.")
        case .clean(let run) where discardedNotesSentence(run.droppedDangling) != nil:
            return ("Nothing to flag.", "circle.dashed",
                    (discardedNotesSentence(run.droppedDangling) ?? "") + ".")
        case .idle, .nothingNew, .clean:
            // `.idle` is unreachable here — `headerState` returns `.clean` for
            // a last run with no live notes — but it is named rather than
            // defaulted so a new state cannot inherit this copy by omission.
            return ("Nothing to flag.", "checkmark.seal",
                    "The compiler found nothing to raise against the last check.")
        }
    }

    /// The paragraph a click on `diagnostic` should jump to, or `nil` for a note
    /// that named none. Split out as a pure static so the mapping is a direct
    /// unit test without mounting a view or simulating a tap gesture, which
    /// SwiftUI does not expose the way it does a `Button`'s press.
    static func paragraphToNavigateTo(for diagnostic: Diagnostic) -> String? {
        diagnostic.anchor?.paragraphId
    }

    /// Turn a note into a durable task and take it off the pane.
    ///
    /// The two halves are deliberately asymmetric about undo. The task is one
    /// undo step — `createPaneTask` registers its own inverse, so ⌘Z takes it
    /// back. The dismissal is not undoable, and that is intended rather than
    /// missing: the diagnostics sidecar is per-device derived state with no
    /// undo of its own, and a note that still stands is raised again by the
    /// next run. A ⌘Z that resurrected it would be claiming the compiler had
    /// re-checked something it has not looked at since.
    private func promote(_ diagnostic: Diagnostic) {
        guard let document = activeDocument() else { return }
        document.createPaneTask(
            body: DiagnosticPromotion.taskBody(for: diagnostic, run: lastRun),
            parentTaskId: nil,
            paragraphId: diagnostic.anchor?.paragraphId,
            undoManager: undoManager)
        diagnostics.dismiss(diagnostic.id, docId: docId)
    }

    // MARK: - The answer, which is a ruling

    /// What the ruling's line says about where it came from.
    ///
    /// **It names no paragraph, and that is requirement 3 rather than a
    /// shortfall.** The shim this replaced left a note anticipating *"from a run
    /// on ¶wnse"* — but a ruling's provenance is prose the writer reads, in the
    /// Intent pane, for as long as the decision stands, and a bare id is exactly
    /// what v2 took off every surface. The DATE is not restated here either:
    /// `RulingsSection` stamps every line with `ruled <d MMM yyyy>`, so a
    /// provenance carrying one too would print the day twice.
    static let answeredNoteProvenance = "answered a compiler note"

    /// **Write the writer's answer into the piece's rulings, and take the note
    /// off the pane once it is there** — the loop this milestone exists for.
    ///
    /// A `static` taking everything it touches, so the whole of it is a direct
    /// test against a real `ProjectStore` and a real `DiagnosticsStore`. SwiftUI
    /// exposes no way to deliver a Return keystroke into a hosted `TextField`'s
    /// editor, so a commit written inline in the field's `.onSubmit` would be
    /// the one part of this path nothing could drive.
    ///
    /// **Through `RulingPerformer.rule`, which is the only door into the
    /// writer-owned layer** (spec §3.4). The answer arrives itemized, dated and
    /// carrying where it came from, under `## Rulings` — never as a paragraph
    /// appended to the essay the writer wrote, which is what shipped in M2 and
    /// what §3.4 names as the membrane's loosest point.
    ///
    /// **The dismissal is conditional on the write, and the order is the
    /// contract.** A note dismissed before the ruling could lose both the note
    /// and the answer to one refusal; dismissed after, the worst case is a note
    /// the writer answers twice. Returns the refusal's own sentence, or `nil`.
    ///
    /// Asymmetric about undo for `promote`'s reason: the answer is an op in the
    /// statement's log and ⌘Z reaches it there, while the dismissal is
    /// per-device derived state with no undo of its own — a ⌘Z that resurrected
    /// the note would claim the compiler had re-checked something it has not
    /// looked at since.
    static func commitAnswer(
        _ text: String, to diagnostic: Diagnostic, docId: String,
        store: ProjectStore, world: DeclaredWorldStore?, diagnostics: DiagnosticsStore
    ) async -> String? {
        do {
            try await RulingPerformer.rule(
                text, provenance: answeredNoteProvenance,
                forScope: .document(docId), store: store, world: world)
        } catch {
            return error.localizedDescription
        }
        diagnostics.dismiss(diagnostic.id, docId: docId)
        return nil
    }

    private func answer(_ text: String, to diagnostic: Diagnostic) {
        // Unreachable from the UI — no row without a store offers the action —
        // and it refuses rather than asserting, because a caller that got here
        // has a writer's sentence in hand and nothing to gain from a crash.
        guard let store else { return }
        answerFailures[diagnostic.id] = nil
        answering.insert(diagnostic.id)
        Task {
            let failure = await Self.commitAnswer(
                text, to: diagnostic, docId: docId, store: store, world: world,
                diagnostics: diagnostics)
            answering.remove(diagnostic.id)
            // Only on failure: on success the row is gone with the note, and
            // an entry for a note nobody can see would surface on the next run
            // that happened to mint the same id.
            answerFailures[diagnostic.id] = failure
        }
    }

    private func jump(toParagraph pid: String) {
        // Reuses `AnnotationsPane.jump`'s event rather than a copy — span
        // precision is that pane's alone; a diagnostic anchors a whole
        // paragraph.
        MaughamEvent.post(
            .maughamNavigateToParagraph, to: .keyWindow,
            payload: ["paragraph_id": pid])
    }
}

// MARK: - Sections

@MainActor
private struct PaneSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// One clause of the conformance summary: the writer's sentence, how the draft
/// sat against it, and — when it strains — what pulled.
@MainActor
private struct ClauseRow: View {
    let row: DiagnosticsPane.ConformanceRow
    let canAnswer: Bool
    /// Passed through to every strain under this clause — see
    /// `DiagnosticsPane.offersDurableActions`. Separate from `canAnswer`
    /// because the two are false for different reasons: no project to write a
    /// ruling into, versus a run still arriving.
    let canPromote: Bool
    let answering: Set<String>
    let answerFailures: [String: String]
    let onJump: (String) -> Void
    let onPromote: (Diagnostic) -> Void
    let onAnswer: (String, Diagnostic) -> Void

    /// **Open, and collapsible — not closed and expandable.** The note under a
    /// strain is the finding; a summary that hid it behind a chevron would make
    /// the writer click once per strain to learn what the run actually said,
    /// and a finding one click away is a finding half the time.
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: DiagnosticsPane.statusSymbol(row.status.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(DiagnosticsPane.statusWord(row.status.status))
                // The writer's own words, quoted — never a summary of them.
                Text("\u{201C}\(row.status.clauseQuote)\u{201D}")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !row.strains.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(isExpanded ? "Hide what pulls" : "Show what pulls")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, row.strains.isEmpty || !isExpanded ? 10 : 0)

            if isExpanded {
                ForEach(row.strains) { strain in
                    DiagnosticRow(
                        diagnostic: strain,
                        canAnswer: canAnswer && DiagnosticsPane.offersAnAnswer(strain),
                        canPromote: canPromote,
                        isSubmitting: answering.contains(strain.id),
                        answerFailure: answerFailures[strain.id],
                        onJump: onJump,
                        onPromote: { onPromote(strain) },
                        onAnswer: { onAnswer($0, strain) })
                }
            }
        }
    }
}

// MARK: - One note

@MainActor
private struct DiagnosticRow: View {
    let diagnostic: Diagnostic
    /// Whether this row offers the **Answer** action at all — false for a
    /// reader report, false with no project to write into, and false for every
    /// row of a preview (`DiagnosticsPane.offersDurableActions`).
    let canAnswer: Bool
    /// Whether this row offers **Promote to Task**. Its own flag rather than
    /// `canAnswer`'s: a reader's report has no answer to give and promotes
    /// perfectly well, so the two are false on different rows for different
    /// reasons and only a preview takes both away at once.
    let canPromote: Bool
    /// An answer of this row's already on its way to the piece's rulings.
    let isSubmitting: Bool
    /// What the last answer refused with, or `nil`. Its arrival is what tells
    /// the row the round trip is over and the field is the writer's again.
    let answerFailure: String?
    let onJump: (String) -> Void
    let onPromote: () -> Void
    let onAnswer: (String) -> Void

    /// The field is REVEALED rather than standing: a text box under every note
    /// is a form, and the pane's register is a margin note.
    @State private var isAnswering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = DiagnosticsPane.readerKindLabel(diagnostic.category) {
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(diagnostic.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // **The writer's prose, never its id** (requirement 3). One chip a
            // line: a chip is already a short quotation, and two side by side in
            // a pane this narrow would each be truncated to nothing.
            ForEach(diagnostic.refs ?? [], id: \.paragraphId) { ref in
                ExcerptChip(ref: ref, onJump: onJump)
            }
            HStack(spacing: 6) {
                if canAnswer && !isAnswering {
                    Button("Answer", action: reveal)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Say why this is deliberate. It becomes a ruling in your "
                              + "intent, and the next check reads it.")
                }
                if canPromote {
                    Button("Promote to Task", action: onPromote)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Keep this note as a task on the document.")
                }
            }
            if isAnswering { replyField }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        // The tap-to-jump must not fire from inside the field the writer is
        // typing in — `onTapGesture` on the row would otherwise scroll the
        // editor out from under them mid-sentence.
        .onTapGesture {
            guard !isAnswering,
                  let pid = DiagnosticsPane.paragraphToNavigateTo(for: diagnostic)
            else { return }
            onJump(pid)
        }
    }

    /// **Understated on purpose.** A plain field with a prompt rather than a
    /// bordered box with a Send button: the writer is answering a margin note,
    /// not filling in a form, and this pane's whole register is that nothing on
    /// it nags.
    @ViewBuilder
    private var replyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Why is this deliberate?", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($fieldFocused)
                .disabled(isSubmitting)
                .onSubmit { commit() }
                .onExitCommand { cancel() }
            if let answerFailure {
                Text(answerFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Reveal the field and put the caret in it. The deferral is tripwire 16's:
    /// a single `DispatchQueue.main.async` tick loses the race with SwiftUI's
    /// own focus pass, and a field the writer has to click into is an action
    /// that only half happened. `BinderRow.claimFocus()` is the canonical
    /// spelling.
    private func reveal() {
        isAnswering = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            fieldFocused = true
        }
    }

    /// **The words go up and the field stays open** — closing it is not this
    /// method's job. The pane owns the round trip: on success the note is
    /// dismissed and this whole row goes with it, and on failure the row stays
    /// exactly as it is with the draft still in it, because a commit that
    /// emptied the field would take the writer's sentence with it on the one
    /// path where they still need it.
    ///
    /// Return on an untouched field is a cancel rather than a refusal: nothing
    /// was said, so there is nothing to report.
    private func commit() {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            cancel()
            return
        }
        onAnswer(words)
    }

    /// Escape: the field goes away and nothing is written. The draft goes with
    /// it — the writer said no.
    private func cancel() {
        isAnswering = false
        fieldFocused = false
        draft = ""
    }
}

/// A paragraph the note points at, drawn as **the words it said** — the whole
/// of requirement 3 on this surface. Pressing it makes the same jump the row
/// makes; the id it carries is a payload and never a label.
@MainActor
private struct ExcerptChip: View {
    let ref: Diagnostic.Ref
    let onJump: (String) -> Void

    var body: some View {
        Button {
            onJump(ref.paragraphId)
        } label: {
            Text("\u{201C}\(ref.excerpt)\u{201D}")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Go to this paragraph")
    }
}
