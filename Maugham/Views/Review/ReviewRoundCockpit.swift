import SwiftUI
import MaughamCore

/// **The round cockpit** — the strip between the annotations queue's toolbar
/// and its notes (M4 P2 Task 3, spec §7).
///
/// Review is where a reviewer lives, and until this strip the loop that fills
/// the queue was invisible from there: which pass the piece is being read
/// through, which editor reads it, which round they are on, and how to ask for
/// the next one. Every one of those was knowable — the board knew the pass, the
/// Diagnostics pane knew the round — and none of it was where the work is.
///
/// **It is a second delivery site for ⌘R, exactly as the cold-start offer's
/// Read button is** (`DiagnosticsPane.coldStartOffer`): the buttons call
/// `CompilerOrchestrator.runRequested` directly. They deliberately carry NO
/// `keyboardShortcut` — ⌘R and ⌘⇧R are `MaughamApp`'s menu commands and the
/// spec's keystroke-only rule is about there being ONE trigger, not one
/// button. A second binding here would be a second command competing for the
/// same key in whichever window happens to host the pane.
///
/// **Everything it decides is a static below, and everything it says is
/// `RoundNarrative`'s** (Task 2's hoist). The pane hands this view resolved
/// values; the view draws them. That is what lets the lane line, the
/// docId-scoped run phase, the report line's mutual exclusion and the empty
/// queue's teaching all be tested without a window — and what keeps Review's
/// copy from drifting from Author's, which is the whole reason `RoundNarrative`
/// stopped living on `DiagnosticsPane`.
///
/// The strip is **document scope only** and the pane's mount is where that is
/// enforced: it is a statement about ONE piece's pass, round and next run, and
/// across the project every section is a different piece with a different
/// answer.
@MainActor
struct ReviewRoundCockpit: View {
    // **This view holds no document id, and the absence is deliberate.** Every
    // value below is already resolved FOR one piece by the pane, and both
    // verbs close over the piece they belong to at the mount. A `docId` stored
    // here would be a second copy of the subject that nothing draws and
    // nothing checks against the resolved values beside it — exactly the shape
    // of parallel state tripwire 6 is about. The one place the id is
    // load-bearing is `phase(runState:docId:)`, which takes it as an argument.

    /// Every pass the project names (`ProjectManifest.effectiveReviewPasses`) —
    /// the picker's contents when no pass is active.
    let passes: [ReviewPass]
    /// The piece's **recorded** active pass id, already validated against
    /// `passes` (`ActivePassMemory.validatedActivePass`).
    ///
    /// Deliberately NOT the queue's `resolvedPassId`, which is a filter — a
    /// lens the writer widened to see every note. What the run mints its lane
    /// from is this value (`CompilerEnvironment+Project`'s `activePass`
    /// closure), so a strip keyed on the filter would name one lane and run
    /// another. `passOrderNudge` refuses the same substitution for the same
    /// reason.
    let activePassId: String?
    /// The newest round number in that lane, or `nil` before any
    /// (`DiagnosticsStore.latestRound(forPass:docId:)`, which consults the
    /// standing run before the ring — the one spelling).
    let round: Int?
    let phase: RunPhase
    /// What the last round says about itself — the fresh-eyes header or the
    /// since-last-round comparison, resolved by `reportLine(history:run:annotations:)`.
    /// `nil` when there is no round to report on.
    let reportLine: String?
    /// Ask for a round. `true` is the cold read (⌘⇧R).
    let onRun: (_ freshEyes: Bool) -> Void
    /// Record which pass this piece is being reviewed through. The write
    /// itself is `ProjectWindow.recordActivePass` — the ONE writer of
    /// `UIState.activePassMemory` — reached through the mount, never spelled
    /// again here or in the pane.
    let onSetActivePass: (_ passId: String) -> Void

    /// **Whether a run is in flight on THIS document.**
    ///
    /// A separate type from `CompilerOrchestrator.RunState` because that state
    /// is per WINDOW and this strip is per DOCUMENT: `.nothingNew` and
    /// `.failed` describe runs that are over, and a run on another chapter is
    /// nothing this strip has anything to say about.
    enum RunPhase: Equatable {
        case idle
        case running(CompilerOrchestrator.DeltaCounts)
    }

    // MARK: - The decisions, pure

    /// **The second reader of `orchestrator.runState`, scoped the way the
    /// first one is** (`DiagnosticsPane.headerState`'s `where runDocId == docId`).
    ///
    /// Drop the scope and a run on chapter 2 makes chapter 1's strip claim it
    /// is being checked and refuse its own Run button — the same defect the
    /// header's `where` clauses exist to prevent, in a second surface.
    static func phase(
        runState: CompilerOrchestrator.RunState, docId: String
    ) -> RunPhase {
        if case .running(let runDocId, let checking) = runState, runDocId == docId {
            return .running(checking)
        }
        return .idle
    }

    /// **"<Pass> · <Editor> · round N"**, or "round —" before the lane has one.
    ///
    /// The editor comes through `effectiveEditorName` — never the raw field —
    /// because a customized manifest can store a preset-id pass that predates
    /// it, and that resolution's ultimate fallback is the pass's own NAME. So
    /// a writer's own "Beta Read" pass would read "Beta Read · Beta Read"; the
    /// line collapses that rather than saying it twice.
    ///
    /// An em dash rather than "round 0" or a silent omission: a piece with a
    /// pass set and no round yet is exactly the state the Run button is for,
    /// and the line should say where the writer is, not imply a round happened.
    static func laneLine(pass: ReviewPass, round: Int?) -> String {
        let number = round.map(String.init) ?? "\u{2014}"
        let editor = pass.effectiveEditorName
        guard editor != pass.name else { return "\(pass.name) \u{00b7} round \(number)" }
        return "\(pass.name) \u{00b7} \(editor) \u{00b7} round \(number)"
    }

    /// **One line after a round, and the two candidates are mutually exclusive
    /// by construction.** A cold read was briefed on no prior findings, so a
    /// comparison drawn over it would name a difference the run never made —
    /// `RoundNarrative.sinceLastRoundLine` refuses that round from the other
    /// end, and this is what stands in its place.
    ///
    /// `annotations` must be the document's queue in EVERY state. The
    /// arithmetic (`SinceLastRound`) does its own status filtering; a caller
    /// that pre-filtered to open notes would report zero resolved forever.
    static func reportLine(
        history: [RoundRecord], run: CompilerRun?, annotations: [Annotation]
    ) -> String? {
        RoundNarrative.freshEyesHeader(run: run)
            ?? RoundNarrative.sinceLastRoundLine(
                history: history, run: run, annotations: annotations)
    }

    /// **What an empty queue says now** — the Review copy carry.
    ///
    /// It used to name one of the two ways the queue fills ("ask Claude for
    /// editorial feedback") and it was no longer the one Review is built
    /// around. Both are named, the round first and by its editor's name, so
    /// the empty state teaches the loop instead of describing the absence of
    /// one (spec §7).
    ///
    /// The offer itself is `RoundNarrative.runRoundTitle` — the same spelling
    /// the board chip's menu verb carries (M4 P2 Task 4), so the two places a
    /// reviewer meets the round in the same minute name it the same way.
    static func emptyQueueTeaching(editorName: String?) -> String {
        // `nil` here means no pass is active yet — there is no editor for
        // `RoundNarrative.runRoundTitle(editorName:)` to name (its parameter
        // is non-optional on purpose), so this arm is its own hand-written
        // sentence rather than a call through it with a placeholder editor.
        let round = editorName
            .map { "\(RoundNarrative.runRoundTitle(editorName: $0)) (\u{2318}R)" }
            ?? "Run a round (\u{2318}R)"
        return "Claude proposes; you dispose. \(round), or ask Claude in Claude Desktop."
    }

    // MARK: - Copy

    static let runTitle = "Run round"
    static let freshEyesTitle = "Fresh Eyes"
    static let setAPassTitle = "Set a pass"

    /// Why both buttons refuse mid-run. RULING-35's other half: a disabled
    /// control says why. Nothing is queued — there is one session per window,
    /// and a second turn is what the next keystroke does.
    static let busyReason =
        "This piece is being checked. The next round is the next keystroke."

    /// The tooltip names the round the press would actually produce — the
    /// offer, plus its NUMBER, which is the one thing the empty state's copy
    /// and the board chip's verb do not carry.
    ///
    /// The offer itself is `RoundNarrative.runRoundTitle`, like the other two
    /// (M4 P2 Task 4's review): three hand-built spellings of "Run X's round"
    /// in two files is how the personification comes to be worded three ways.
    static func runHelp(pass: ReviewPass?, round: Int?) -> String {
        let next = (round ?? 0) + 1
        guard let pass else { return "Check this piece now (\u{2318}R)" }
        let offer = RoundNarrative.runRoundTitle(
            editorName: pass.effectiveEditorName)
        return "\(offer) \(next) (\u{2318}R)"
    }

    static let freshEyesHelp =
        "Read the whole piece cold (\u{2318}\u{21e7}R) \u{2014} the warm session is "
        + "retired and this round is briefed on no prior findings."

    static let setAPassHelp =
        "Which pass is this piece being read through? The round is filed in "
        + "that lane, and its editor signs the notes."

    // MARK: - Verbs
    //
    // Named rather than inlined into the controls so a test can drive the one
    // the mounted menu cannot: a SwiftUI `Menu` builds its items when the
    // writer opens it, so the picker's item is unreachable from a hosted view
    // (measured in `InspectorPassLadderTests`). `setPass` is the identical code
    // path, minus AppKit's menu.
    //
    // **That substitution is only honest while the item actually calls it**,
    // and nothing a mounted test can reach says so — rewiring `passPicker`'s
    // button to anything else leaves every drive-through-`setPass` test green
    // over a picker that no longer does what they claim. So the link is a
    // census: `ReviewRoundCockpitTests.
    // test_thePickersItemCallsTheVerbTheTestsDriveItThrough` reads
    // `passPicker`'s own declaration and requires `setPass(pass.id)` in it.
    // Renaming this verb means moving that census with it.

    func setPass(_ passId: String) { onSetActivePass(passId) }

    func run(freshEyes: Bool) { onRun(freshEyes) }

    // MARK: - Body

    private var activePass: ReviewPass? {
        activePassId.flatMap { id in passes.first { $0.id == id } }
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// The one line under the lane: what is being read while a round is in
    /// flight, and what the last one found once it is not. The same mutual
    /// exclusion the Diagnostics pane keeps between its own two lines, in one
    /// slot because the column is narrow.
    private var statusLine: String? {
        switch phase {
        case .running(let counts): return RoundNarrative.checkingCopy(counts)
        case .idle: return reportLine
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            laneRow
            if let statusLine {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            runRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Where the reviewer is — or, when nobody has said, the one control that
    /// answers it.
    @ViewBuilder
    private var laneRow: some View {
        if let activePass {
            Text(Self.laneLine(pass: activePass, round: round))
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            passPicker
        }
    }

    /// **The picker, shown exactly when no pass is active.** A menu rather
    /// than a segmented row for `AnnotationsQueueToolbar`'s reason: a project
    /// may name any number of passes and the column's floor is 240pt.
    ///
    /// It writes nothing itself. The pass memory has one writer
    /// (`ProjectWindow.recordActivePass`) and this reaches it through the
    /// mount — the queue advises about passes; it never rules on one.
    @ViewBuilder
    private var passPicker: some View {
        Menu {
            ForEach(passes) { pass in
                Button(pass.name) { setPass(pass.id) }
            }
        } label: {
            Text(Self.setAPassTitle)
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Self.setAPassHelp)
    }

    /// The two ways to ask. **No `keyboardShortcut` on either** — see the type
    /// doc: these are second delivery sites for `MaughamApp`'s ⌘R / ⌘⇧R, not
    /// second bindings of them.
    @ViewBuilder
    private var runRow: some View {
        HStack(spacing: 6) {
            Button(Self.runTitle) { run(freshEyes: false) }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
                .help(isRunning ? Self.busyReason
                                : Self.runHelp(pass: activePass, round: round))
            Button(Self.freshEyesTitle) { run(freshEyes: true) }
                .buttonStyle(.bordered)
                .disabled(isRunning)
                .help(isRunning ? Self.busyReason : Self.freshEyesHelp)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }
}
