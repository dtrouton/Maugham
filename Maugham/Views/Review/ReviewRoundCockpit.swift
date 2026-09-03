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
    /// the lane picker's contents, in every state.
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
    ///
    /// **The lane it counts is the piece's, which is the coach's when no
    /// stage is set**: the pane asks `latestRound` with `pass?.id ?? coach?.id`
    /// so her numbered rounds reach this strip (editorial letter P1, Task 6).
    let round: Int?
    /// **Who holds the coach's seat** — `ProjectManifest.effectiveCoach`, nil
    /// once the writer has vacated it (spec §4.1).
    ///
    /// Read for ONE thing: what the lane label says over a piece with no
    /// stage assigned. She reads any unassigned piece, so "Set a pass" over
    /// one is not merely terse but wrong — ⌘R already files a numbered round
    /// in her lane and the notes already arrive signed by her.
    ///
    /// She never reaches `lanePickerItems`. She is not a lane a piece can be
    /// moved into: `ActivePassMemory.validatedActivePass` refuses her id
    /// because she is absent from `effectiveReviewPasses`, so a menu item
    /// offering her would be a control that does nothing. Handing a piece
    /// BACK to her is setting its pass to untouched on the board, which is
    /// what the guide says (`docs/guide/review-passes.md`).
    let coach: ReviewPass?
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
    /// End the run in flight — `CompilerOrchestrator.cancel()`, the exact
    /// verb `DiagnosticsPane`'s own Cancel button calls. Cancel's semantics
    /// come free: it ends the turn through `.sessionDied(detail: .cancelled)`,
    /// which `CompilerRunFailure.isTheWritersOwnDoing` already routes to
    /// `.idle` before `runState` is ever set (`finish`'s failure arm) — so
    /// this strip needs no cancelled-specific copy of its own, and pressing
    /// it returns the strip to idle with the Run button pressable again, the
    /// same as any other run that finished.
    ///
    /// Only reachable from `.running` — the arm this strip has anything to
    /// cancel from.
    let onCancel: () -> Void

    /// **The gear menu's persisted choice** — `DiagnosticsPane`'s own
    /// `compilerModel`, threaded here so Review carries the same control
    /// (editorial letter P1, Task 8). Depth is a per-PROJECT setting, not a
    /// per-persona one: a writer who set Deep in Author must find Deep here
    /// too, and a change made from either home is the one write.
    let compilerModel: CompilerModelChoice
    /// Reaches `ProjectWindow`'s ONE handler — the same closure
    /// `DiagnosticsPane` calls, never a second spelling of the persistence.
    let onCompilerModelChange: (CompilerModelChoice) -> Void

    /// **What the last run's letter says, in one line** (editorial letter P1
    /// Task 9, spec §3.5) — the one thing, else the say-back. `nil` when the
    /// run left no letter, which draws no line and no disclosure rather than
    /// an empty triangle over nothing.
    ///
    /// Defaulted so a caller that predates the letter — every probe mount,
    /// and any host with no sidecar behind it — keeps compiling with a strip
    /// that simply has no letter in it. `AnnotationsPane` is the one
    /// production caller and passes both (its own census).
    var letterLine: String? = nil
    /// **The stage the last run derived, for the lane line's own word**
    /// (editorial letter P3, spec §3.8). `Letter.draftStage` — the ONE
    /// conversion from the stored raw — off the same run `letterLine` is built
    /// from.
    ///
    /// **The number and the word on that line do not always come from the same
    /// run, and the difference shows on a lane switch.** The stage is the last
    /// RUN's, whatever pass that run was in; the round is the LANE's
    /// (`AnnotationsPane.cockpitRound` → `DiagnosticsStore.latestRound(forPass:docId:)`,
    /// which answers the standing run's round when its pass matches and
    /// otherwise falls back to the newest round in the ring for that pass). So
    /// selecting a pass the writer has not run since some other pass's rounds
    /// stacked up shows that pass's own round beside the stage of a run filed
    /// in a different lane. Both are honest facts about the piece; neither is
    /// "the last run's" on its own.
    ///
    /// Defaulted for `letterLine`'s reason: every probe mount predates it and
    /// keeps compiling with a strip that simply names no stage.
    var stage: DraftStage? = nil
    /// The section the disclosure opens: the host's own `LetterSection`,
    /// wired to the host's verbs. A closure rather than a `Letter`, because
    /// Accept as task, Add to intent and Keep all need the host's document,
    /// project and undo manager — and because Review must open the SAME view
    /// Author draws rather than a second one that could disagree with it.
    var letterDisclosure: (() -> AnyView)? = nil

    /// **What the writer has asked of the next round on this piece, and where
    /// to file a change to it** (P2 Task 7, spec §3.7) — one value, because the
    /// stored ask, the commit and the document they belong to are one subject
    /// (`AskField.Input`'s own note).
    ///
    /// **`nil` hides the field outright**, `letterDisclosure`'s rule: a host
    /// with no diagnostics store behind it has nowhere to put a sentence, and a
    /// box that swallows what is typed into it is worse than no box. Every P1
    /// probe mount passes nothing and draws the strip it always drew.
    ///
    /// It carries a `docId` and the type doc above says this view holds none.
    /// That still stands: this is not the strip's subject, it is one already-
    /// resolved value the pane built for the field it is handing down, exactly
    /// as `letterDisclosure` hands down a closure over the pane's own document.
    /// Nothing here reads it.
    var ask: AskField.Input? = nil

    /// **What the last thing the run key did means for THIS document.**
    ///
    /// A separate type from `CompilerOrchestrator.RunState` because that state
    /// is per WINDOW and this strip is per DOCUMENT: a run on another chapter
    /// is nothing this strip has anything to say about, in any of its states.
    ///
    /// **`.failed` is a case here, and it was not until Denver's 2026-08-18
    /// smoke.** This enum used to hold `idle` and `running` alone, on the
    /// argument that ".failed describes a run that is over" — true, and beside
    /// the point: a run that is over having produced NOTHING renders the strip
    /// exactly like a clean idle, so a round that died at the session budget is
    /// indistinguishable from one that came back with no notes. Denver read two
    /// timed-out rounds (Structural, then Line) as "returned nothing" and only
    /// found the failure in Author's Diagnostics pane, a persona away from the
    /// button he pressed. A failure must surface where the run was launched.
    ///
    /// `.nothingNew` stays folded into `.idle`: it is a run that worked and had
    /// nothing to read, which is what the report line under it already says.
    enum RunPhase: Equatable {
        case idle
        case running(CompilerOrchestrator.DeltaCounts)
        /// A run on THIS document that ended without an answer. `at` is the
        /// moment it did — carried for the same reason the pane's header state
        /// carries it, so a later surface can age the line rather than needing
        /// a second read of the orchestrator.
        case failed(CompilerRunFailure, at: Date)
    }

    // MARK: - The decisions, pure

    /// **The second reader of `orchestrator.runState`, scoped the way the
    /// first one is** (`DiagnosticsPane.headerState`'s `where runDocId == docId`).
    ///
    /// Drop the scope and a run on chapter 2 makes chapter 1's strip claim it
    /// is being checked and refuse its own Run button — the same defect the
    /// header's `where` clauses exist to prevent, in a second surface. The
    /// failure arm needs it for the sharper half of the same reason: a red line
    /// over chapter 1 about a death in chapter 2 is a lie the strip would keep
    /// telling until the next run, and one the writer would answer by pressing
    /// Run on a document that never failed.
    ///
    /// **Only a genuine failure reaches `.failed`**, and this reads the run
    /// state rather than re-filtering it: `CompilerOrchestrator.finish` already
    /// routes anything `CompilerRunFailure.isTheWritersOwnDoing` — cancel, the
    /// AI toggle, project close, a second run arriving mid-flight — to `.idle`
    /// before the state is ever set, so a second filter here would be a copy of
    /// that rule with nothing keeping the two in step (`CompilerRunCommandTests`
    /// pins the orchestrator's half).
    static func phase(
        runState: CompilerOrchestrator.RunState, docId: String
    ) -> RunPhase {
        switch runState {
        case .running(let runDocId, let checking) where runDocId == docId:
            return .running(checking)
        case .failed(let runDocId, let failure, let at) where runDocId == docId:
            return .failed(failure, at: at)
        default:
            return .idle
        }
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
    ///
    /// **The stage the last run derived rides the end of it** (editorial letter
    /// P3, global constraint 28) — "Copyedit · Gould · round 3 · drafting", so
    /// a writer who wants the full letter mid-draft knows to ask for Fresh
    /// Eyes (spec §3.8).
    ///
    /// A `DraftStage` rather than a string, so this file and
    /// `LetterSection.signature` are the only two that read `laneWord` and the
    /// lane's spelling cannot multiply. `nil` — a run that wrote no letter, or
    /// a caller holding a note rather than a run — leaves the line exactly what
    /// it was.
    ///
    /// **The word appends only beside a NAMED round** (RULING-R14). The em-dash
    /// arm says nothing has run in this lane, and a stage on it would be the
    /// last run in some OTHER lane describing a lane that has never been read.
    static func laneLine(
        pass: ReviewPass, round: Int?, stage: DraftStage? = nil
    ) -> String {
        let number = round.map(String.init) ?? "\u{2014}"
        let editor = pass.effectiveEditorName
        let word = stageWord(stage, round: round)
        guard editor != pass.name else {
            return "\(pass.name) \u{00b7} round \(number)\(word)"
        }
        return "\(pass.name) \u{00b7} \(editor) \u{00b7} round \(number)\(word)"
    }

    /// The stage as it appends to a lane line, or nothing at all. The ONE
    /// place this file reads `DraftStage.laneWord`, so `laneLine` and
    /// `coachLine` cannot punctuate the same word two ways.
    ///
    /// **`round` is half the condition** (RULING-R14): the word qualifies a
    /// round, so no round means no word, in either line. Spelling that once
    /// here is what stops the two arms disagreeing about it.
    private static func stageWord(_ stage: DraftStage?, round: Int?) -> String {
        guard let stage, round != nil else { return "" }
        return " \u{00b7} \(stage.laneWord)"
    }

    /// **What the lane picker's own label says** — the lane line once a pass is
    /// active, and the invitation before one is.
    ///
    /// One function rather than two call sites choosing between two strings,
    /// because the control is now ONE control: the row that says where the
    /// reviewer is *is* the row that changes it (Denver's 2026-08-18 smoke).
    /// Before that the lane was a plain `Text` and the picker existed only in
    /// the passless arm, so a piece already in a pass could only be moved to
    /// another lane by going back to the board and clicking a different chip —
    /// the exact undiscoverability the strip was built to end.
    /// **Three arms since the seat exists** (editorial letter P1, Task 6): a
    /// stage's lane line, the coach's own line over an unassigned piece, and
    /// the invitation when nobody is reading it at all.
    ///
    /// A stage always wins. The coach reads what nobody was ASSIGNED, so a
    /// piece handed to Lish reads through Lish whatever the seat says — the
    /// label answers the piece's question, never the project's.
    ///
    /// **The stage is threaded to whichever arm draws and the invitation
    /// carries none** (P3): nobody is reading the piece, so no run derived
    /// anything about its delta.
    static func laneLabel(
        pass: ReviewPass?, round: Int?, coach: ReviewPass?, stage: DraftStage? = nil
    ) -> String {
        if let pass { return laneLine(pass: pass, round: round, stage: stage) }
        if let coach { return coachLine(coach: coach, round: round, stage: stage) }
        return setAPassTitle
    }

    /// **"Le Guin reads this piece", then "Le Guin · round 3"** — an
    /// introduction before her first round and the lane line's own shape
    /// after it.
    ///
    /// Deliberately NOT `laneLine`'s "round —" over the first state. A stage
    /// with no round yet is a lane the writer just chose and the em dash says
    /// "nothing has run in it"; the coach was never chosen, so her first
    /// appearance has to say what she IS before it can say what she has
    /// counted. And her PASS name is never drawn — "Workshop · Le Guin" would
    /// put a lane on screen that no control can select and the board never
    /// shows.
    ///
    /// **Her introduction carries NO stage word** (RULING-R14). "Le Guin reads
    /// this piece" says who she is, not what a run found — and the case is
    /// reachable rather than theoretical: a piece whose pass was cleared after
    /// a run has a last run with a stage on its letter and no round in HER
    /// lane, so the word there would describe a reading she never made. The
    /// stage qualifies a round, and appends only beside a named one.
    static func coachLine(
        coach: ReviewPass, round: Int?, stage: DraftStage? = nil
    ) -> String {
        let name = coach.effectiveEditorName
        let word = stageWord(stage, round: round)
        guard let round else { return "\(name) reads this piece" }
        return "\(name) \u{00b7} round \(round)\(word)"
    }

    /// One row of the lane picker: a pass the project names, and whether it is
    /// the lane this piece is being read through.
    struct LanePickerItem: Identifiable {
        let pass: ReviewPass
        /// Whether this is the piece's active pass. Exactly one item carries
        /// it, or none — see `lanePickerItems`.
        let isCurrent: Bool

        var id: String { pass.id }
    }

    /// **The picker's whole truth table** — the ladder in the project's own
    /// order, with the active lane checked.
    ///
    /// Exposed and pure for `ReviewBoardChipVerbs.chipMenuItems`' reason: a
    /// SwiftUI `Menu` builds its items only when the writer opens it, so a
    /// hosted test can neither see them nor press one (measured in
    /// `InspectorPassLadderTests`). A checkmark rule asserted nowhere is how a
    /// picker that ticks the wrong lane — or every lane — ships green.
    ///
    /// **`current` naming a pass this project does not have leaves NOTHING
    /// checked, and that is the honest reading.** The value reaching this view
    /// is already `ActivePassMemory.validatedActivePass`, so the case is a
    /// manifest edited out from under a recorded id; ticking some other lane
    /// would claim the piece is being read through a pass nobody chose.
    static func lanePickerItems(
        passes: [ReviewPass], current: String?
    ) -> [LanePickerItem] {
        passes.map { LanePickerItem(pass: $0, isCurrent: $0.id == current) }
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
    static let cancelTitle = "Cancel"

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

    /// One tooltip for both states, because it asks the question the control
    /// answers in both: it reads as an invitation over "Set a pass" and as an
    /// offer to change lanes over a lane line.
    static let setAPassHelp =
        "Which pass is this piece being read through? The round is filed in "
        + "that lane, and its editor signs the notes."

    /// The same question, plus the answer that already holds while nobody has
    /// chosen one (editorial letter P1, Task 6). Over a coached piece the
    /// bare invitation implies the round has no reader and no lane, and both
    /// are false — so the tooltip says whose it is until a pass is set.
    ///
    /// Only the unassigned-and-held state gains the sentence: with a stage
    /// active the piece is that editor's and the seat has nothing to do with
    /// it, and with the seat vacant there is nobody to name.
    static func setAPassHelp(pass: ReviewPass?, coach: ReviewPass?) -> String {
        guard pass == nil, let coach else { return setAPassHelp }
        return "Which pass is this piece being read through? Until you set "
            + "one it is \(coach.effectiveEditorName)'s. The round is filed in "
            + "that lane, and its editor signs the notes."
    }

    /// **The one thing, else the say-back** — the derivation, in one place,
    /// so the strip and its host cannot disagree about what the letter's line
    /// says.
    ///
    /// `nil` for no letter and for an EMPTY one: `Letter.isEmpty` ignores
    /// `about`, so a letter carrying only the say-back has no section to
    /// disclose, and a line over a disclosure that opens nothing would be a
    /// control the writer presses twice to learn there was nothing there.
    /// **Blank is absent, not a line** (fix round 1, Minor 2). `one_thing` is
    /// `<string|null>` on the wire and a model writing `""` for "nothing to
    /// fix" is well within it; taken literally that drew an empty caption
    /// under the status line with a disclosure triangle beside it. Both halves
    /// are trimmed, and a letter whose every line is blank has no line at all.
    static func letterLine(_ letter: Letter?) -> String? {
        guard let letter, !letter.isEmpty else { return nil }
        for candidate in [letter.oneThing, letter.about] {
            let trimmed = (candidate ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Verbs
    //
    // Named rather than inlined into the controls so a test can drive the one
    // the mounted menu cannot: a SwiftUI `Menu` builds its items when the
    // writer opens it, so the picker's item is unreachable from a hosted view
    // (measured in `InspectorPassLadderTests`). `setPass` is the identical code
    // path, minus AppKit's menu.
    //
    // **That substitution is only honest while the item actually calls it**,
    // and nothing a mounted test can reach says so — rewiring `lanePicker`'s
    // button to anything else leaves every drive-through-`setPass` test green
    // over a picker that no longer does what they claim. So the link is a
    // census: `ReviewRoundCockpitTests.
    // test_thePickersItemCallsTheVerbTheTestsDriveItThrough` reads
    // `lanePicker`'s own declaration and requires `setPass(item.pass.id)` in
    // it, and that it iterates `lanePickerItems` rather than a second list of
    // its own. Renaming this verb — or the picker — means moving that census
    // with it.

    func setPass(_ passId: String) { onSetActivePass(passId) }

    func run(freshEyes: Bool) { onRun(freshEyes) }

    /// **`setPass`'s own substitution, for the gear menu embedded in
    /// `lanePicker`.** `CompilerModelMenu`'s `onChange` closure IS
    /// `onCompilerModelChange` (`lanePicker`'s own declaration, guarded by
    /// `test_theModelMenusItemCallsTheVerbTheTestsDriveItThrough`), so this is
    /// the identical call a test can drive without AppKit's menu ever opening.
    func changeModel(_ choice: CompilerModelChoice) { onCompilerModelChange(choice) }

    // MARK: - Body

    private var activePass: ReviewPass? {
        activePassId.flatMap { id in passes.first { $0.id == id } }
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// The one line under the lane: what is being read while a round is in
    /// flight, why the last one did not answer if it failed, and what it found
    /// otherwise. The same mutual exclusion the Diagnostics pane keeps between
    /// its own lines, in one slot because the column is narrow.
    ///
    /// **The failure REPLACES the report line rather than sitting beside it.**
    /// The since-last-round comparison and the fresh-eyes header both describe
    /// the last round that finished, which is an older run than the one that
    /// just died; drawn under a failure they would read as that failure's own
    /// result and tell the writer a dead round found three things.
    ///
    /// The copy is `RoundNarrative.failureCopy` — the sentence Author's
    /// Diagnostics pane says about the same death, in one spelling, so a writer
    /// who checks the other pane to understand this one finds the same account
    /// of it (`ReviewRoundCockpitTests`' one-spelling census).
    private var statusLine: String? {
        switch phase {
        case .running(let counts): return RoundNarrative.checkingCopy(counts)
        case .failed(let failure, _): return RoundNarrative.failureCopy(failure)
        case .idle: return reportLine
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            lanePicker
            if let statusLine {
                Text(statusLine)
                    .font(.caption)
                    // Red only for a failure, on `DiagnosticsPane.header`'s
                    // rule: the strip's ordinary lines are secondary, and a
                    // colour that never changes is a colour that says nothing.
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            letterRow
            askRow
            runRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// **The letter, under the status line and above the buttons** (spec
    /// §3.5). One line of it, and a disclosure that opens the whole thing
    /// inline — the reviewer reads what the round came back with without
    /// leaving the queue for Author's pane.
    ///
    /// The line alone draws when a host supplies no disclosure: a caption is
    /// still worth more than nothing, and a triangle that opens an empty box
    /// is worse than no triangle.
    @ViewBuilder
    private var letterRow: some View {
        if let letterLine {
            if let letterDisclosure {
                DisclosureGroup {
                    letterDisclosure()
                } label: {
                    Text(letterLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(letterLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// **Ask about…, between the letter and the buttons** (spec §3.7): the
    /// last thing the reviewer reads before pressing Run, which is where a
    /// sentence about what this round is for belongs.
    ///
    /// The same `AskField` Author's header draws — one field over one
    /// per-document value, so a worry typed in either home is the worry the
    /// next ⌘R is briefed with, whichever home ran it. **It starts nothing**:
    /// the keystroke is the only trigger, and this row has no Run verb in it.
    @ViewBuilder
    private var askRow: some View {
        if let ask {
            AskField(input: ask)
        }
    }

    /// **Where the reviewer is, and the one control that moves them** — the
    /// same control, in both states (Denver's 2026-08-18 smoke).
    ///
    /// The lane row used to be a plain `Text` once a pass was active and a
    /// picker only before one was, which meant the strip could say *Structural
    /// · Perkins · round 2* and offer no way to read the piece through any
    /// other lane. The only lane-switcher left was another chip click on the
    /// board — the undiscoverability the cockpit exists to end, reappearing one
    /// step further in. So the line IS the button: its label is `laneLabel`
    /// (the lane line, or the invitation), and `.menuStyle(.borderlessButton)`
    /// is what draws the chevron that says so.
    ///
    /// A menu rather than a segmented row for `AnnotationsQueueToolbar`'s
    /// reason: a project may name any number of passes and the column's floor
    /// is 240pt. **No `.fixedSize()`** — the passless label was two short words
    /// and could afford one; a lane line carries a writer's own pass name and
    /// must stay compressible, which is what `AnnotationsQueueToolbarWidthTests`
    /// measures. The `Spacer` is what keeps it left rather than a `maxWidth`
    /// frame, so the pressable area is the line and its chevron and not the
    /// whole width of the column.
    ///
    /// It writes nothing itself. The pass memory has one writer
    /// (`ProjectWindow.recordActivePass`) and this reaches it through the
    /// mount — the queue advises about passes; it never rules on one.
    @ViewBuilder
    private var lanePicker: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(Self.lanePickerItems(
                    passes: passes, current: activePassId)
                ) { item in
                    Button {
                        setPass(item.pass.id)
                    } label: {
                        // The active lane is checkmarked — the board chip
                        // menu's idiom, and a `Label` rather than a `Toggle`
                        // for its reason: these are a choice among lanes, and
                        // a menu of toggles reads as N independent switches.
                        if item.isCurrent {
                            Label(item.pass.name, systemImage: "checkmark")
                        } else {
                            Text(item.pass.name)
                        }
                    }
                }
            } label: {
                Text(Self.laneLabel(pass: activePass, round: round,
                                    coach: coach, stage: stage))
                    // The coach's line is a lane the piece is really in, so it
                    // carries the lane line's own weight; only the invitation
                    // — nobody reading at all — stays light.
                    .font(activePass == nil && coach == nil
                          ? .callout : .callout.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .menuStyle(.borderlessButton)
            .help(Self.setAPassHelp(pass: activePass, coach: coach))
            Spacer(minLength: 0)
            // **The same depth control Author's Diagnostics pane carries**
            // (editorial letter P1, Task 8) — trailing, after the Spacer, so
            // it sits at the row's far edge the way the pane's own gear menu
            // sits at its header's far edge, rather than crowding the lane
            // label it shares a row with.
            CompilerModelMenu(choice: compilerModel, onChange: onCompilerModelChange)
        }
    }

    /// The two ways to ask, plus — while running — the one way out. **No
    /// `keyboardShortcut` on Run or Fresh Eyes** — see the type doc: these
    /// are second delivery sites for `MaughamApp`'s ⌘R / ⌘⇧R, not second
    /// bindings of them.
    ///
    /// **Only `.running` refuses, and `.failed` deliberately does not.** The
    /// remedy for a round that timed out, or for a session that died, is
    /// another round — a strip that reports a failure and then withholds the
    /// button that answers it is RULING-35's dead control with a red line over
    /// it. `isRunning` is therefore the whole predicate; a `!isFailure` added
    /// here would be the defect.
    ///
    /// **Cancel is `.running`-only** — the tracked follow-up from the
    /// failure-visibility review. At the 300s timeout the strip can say
    /// "Checking N paragraphs…" for up to five minutes with nothing to press;
    /// `DiagnosticsPane`'s header carries the identical control
    /// (`.bordered`, `.controlSize(.small)`) for the same run, and this is the
    /// strip that launched it. It calls `onCancel` and nothing else — the
    /// writer-caused mapping that returns the strip to idle is the
    /// orchestrator's, not a rule this button restates.
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
            if isRunning {
                Button(Self.cancelTitle) { onCancel() }
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }
}
