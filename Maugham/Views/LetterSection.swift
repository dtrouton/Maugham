import SwiftUI
import MaughamCore

/// **The letter on screen** — the compiler's sixth section, drawn as prose
/// rather than a list of findings (editorial letter P1 Task 9, spec §3.5).
///
/// One view, two hosts. Author's Diagnostics pane mounts it at the top of the
/// report, above This check and Conformance, because the letter is what the
/// writer reads first and the notes are the margin. Review's round cockpit
/// mounts the identical view inside a disclosure under its own status line.
/// A second spelling would be two letters that could disagree about what the
/// same run said.
///
/// **It decides nothing and writes nothing.** Every verb is a closure the
/// host supplies: the jump is the host's event, Accept as task is the host's
/// `Document.createPaneTask`, Add to intent is the host's `RulingPerformer`
/// call, and Keep is the host's promote-to-research. What this view owns is
/// the reading order, which parts draw at all, and the one piece of per-run
/// memory a writer would notice if it were missing — which exercises they
/// have already accepted.
///
/// **Parts in the schema's reading order, and an empty part draws nothing.**
/// `about`, the one thing, What's working, Habits, Questions, Scenes, the
/// standing turn offer, the signature, Keep this letter. A heading over an
/// empty list would tell the writer the letter had a section about their
/// habits when it had nothing to say about them.
///
/// **Copy is the writer's register, never the schema's** (global constraint
/// 12). Nothing on screen says `one_thing`, `working` or `strong_default`:
/// the one thing is a sentence in its own weight with no label at all, and
/// the scene position reaches the writer only as the presence or absence of
/// the offer at the table's foot.
@MainActor
struct LetterSection: View {

    // MARK: - Copy
    //
    // Named constants rather than literals in the body, so the tests assert
    // the words the writer reads rather than a paraphrase of them — and so a
    // change to the register is one edit, in the file the register lives in.

    static let title = "Letter"
    static let workingTitle = "What's working"
    static let habitsTitle = "Habits"
    static let questionsTitle = "Questions"
    static let scenesTitle = "Scenes"
    static let acceptTitle = "Accept as task"
    static let addToIntentTitle = "Add to intent"
    /// **The same offer, when the piece is measured against the book's
    /// intent** (final review, Critical). A piece with no intent of its own
    /// reads the project's, and that is where the clause is filed \u{2014} so the
    /// button says so before the press rather than after it, in the writer's
    /// register and never the scope's word.
    static let addToBookIntentTitle = "Add to the book's intent"
    static let keepTitle = "Keep this letter"

    /// **The ledger's three verbs, in the writer's register** (P2 Task 6, spec
    /// §6). Nothing on screen says "lesson heading", "ledger entry" or
    /// `.lessons`: what the writer reads is what the press does.
    static let keepAsLessonTitle = "Keep as lesson"
    static let allChoicesTitle = "These are all choices"
    static let retireTitle = "Retire"
    /// What the Retire control reads once it has retired — the press's own
    /// answer, in place of the offer it replaces. Disabled rather than gone,
    /// `acceptTitle`'s rule one section up.
    static let retiredTitle = "Retired."

    /// The caption over the answer: the writer's own ask, quoted back.
    ///
    /// **The ask is drawn as well as the answer** because the two are half a
    /// conversation apart. A writer can clear or rewrite their ask the moment
    /// the check ends, so an answer standing alone would be a reply to a
    /// question nothing on screen asked (`Letter.asked`'s own note).
    static func askedCaption(_ asked: String) -> String {
        "You asked: \u{201C}\(asked)\u{201D}"
    }

    /// What a warm round can honestly say about a lesson it did not meet: it
    /// read a delta, and a three-paragraph delta proves nothing about a habit
    /// (spec §6). A line, and no button.
    static func warmRetiredLine(_ heading: String) -> String {
        "I didn't find \u{201C}\(heading)\u{201D} in what changed."
    }

    /// What a Fresh Eyes round can say: it read the whole piece cold, which is
    /// the evidence §6 says a retirement stands on. Drawn with the offer.
    static func freshRetiredLine(_ heading: String) -> String {
        "I didn't find \u{201C}\(heading)\u{201D} anywhere in this piece."
    }

    /// **The standing offer at the scene table's foot** (spec §3.4). It is a
    /// question rather than a verdict for the reason the whole
    /// `.strongDefault` arm exists: nothing here may synthesize a clause on
    /// the writer's behalf, so the app asks and the writer answers.
    static let turnOfferLine = "Hold every scene to a turn?"

    /// **The sentence the offer files, in one spelling.** Both hosts file it,
    /// and it must contain `ScenePosition.turnClausePhrases`' "every scene
    /// must turn" verbatim — that phrase is what the next round's
    /// `ScenePosition.derive` reads back out of the writer's own statement to
    /// answer `.strongDeclared`. Changing the wording without changing that
    /// list would leave the offer standing on every round forever, which is
    /// exactly the loop `RulingPerformerTests`' round-trip pins.
    static let turnClauseRuling = "Every scene must turn."

    static let wantsColumn = "Wants"
    static let changesColumn = "Changes"
    static let turnColumn = "Turn"
    static let chargeColumn = "Charge"

    // MARK: - Inputs

    let letter: Letter
    /// **The run this letter came out of** \u{2014} what the per-mount memory
    /// below is keyed on. `nil` for a host with no run, which is a letter with
    /// no memory rather than one that remembers the last run's presses.
    let runId: String?
    /// The voice's name and the round it signed — built by the host through
    /// ``signature(voice:round:)`` so Author and Review sign the same letter
    /// the same way.
    let signature: String
    /// `(paragraphId) -> the paragraph's text now`, the closure the
    /// Diagnostics pane already holds. A ref carries the words the paragraph
    /// said when the letter was written; a jump chip shows what it says now,
    /// falling back to the ref's own excerpt when the paragraph cannot be
    /// read (`chipRef(for:currentText:)`).
    let currentText: (String) -> String?
    let onJump: (String) -> Void
    let onAcceptExercise: (Letter.Habit) -> Void
    /// **`nil` hides the offer outright.** The host is what knows whether the
    /// run was in the strong form WITHOUT a clause of the writer's
    /// (`ScenePosition.strongDefault`) and whether there is anywhere to file
    /// a ruling; this view adds the other half of the condition — a scene row
    /// that does not turn (``hasTurnlessScene(_:)``).
    let onAddTurnClause: (() -> Void)?
    /// **What the offer's button says, decided by the host and never here.**
    /// The tense follows the scope the ruling will actually be filed at
    /// (`TurnClauseOffer.buttonTitle`), and only the host can know it: this
    /// view holds no store and cannot resolve which intent the piece is
    /// measured against. A default would be this view deciding in silence, and
    /// the wrong half of the time it would name a destination the write does
    /// not use.
    let addToIntentTitle: String
    let onKeep: () -> Void
    /// **What a failed Add to intent said**, in the host's own refusal
    /// channel. Not in the plan's input list and added deliberately: without
    /// it a ruling the op log refused would leave a button that looks pressed
    /// and an intent that never moved — the silent-refusal defect
    /// `AnnotationsPane.performAccept`'s named catch exists to prevent.
    var offerFailure: String? = nil
    /// What Keep this letter said once it had kept one — *Kept as "…"*,
    /// naming the note the store actually made (`LetterKeep.confirmation`).
    /// Drawn under the button when a host supplies one.
    var keepConfirmation: String? = nil
    /// **What a failed Keep said**, in the same shape `offerFailure` takes one
    /// line up and for the same reason (Task 9's own note): a note the file
    /// system refused would otherwise leave a button that looks pressed and a
    /// letter that went nowhere. Red rather than secondary, because the
    /// confirmation slot beside it is where success speaks and the two must
    /// not be mistaken for each other.
    var keepFailure: String? = nil

    /// **The lessons ledger as it stands, read once by the host** (P2 Task 6).
    /// This view holds no store, so the offers it draws — which habits can
    /// still be kept, which of the round's "not found" headings name a live
    /// lesson — are asked of `LessonOffer` against this text.
    /// `nil` is a project whose writer has kept nothing yet, which is not the
    /// same as a project with no ledger to consult: nothing has been decided,
    /// so every habit can be kept and nothing can be retired.
    var ledgerText: String? = nil
    /// **`nil` hides Keep as lesson outright**, `onAddTurnClause`'s shape and
    /// for its reason: a button with nowhere to file is worse than none.
    var onKeepAsLesson: ((Letter.Habit) -> Void)? = nil
    /// **`nil` hides These are all choices**, and the host is what decides —
    /// `LessonOffer.allChoicesIsOffered` needs the run, which this view does
    /// not hold.
    var onAllChoices: (() -> Void)? = nil
    /// **`nil` is a WARM round, and non-nil is Fresh Eyes** — the one input
    /// that carries the round's own tense into the retired part.
    ///
    /// It reads as a plain optional handler and decides copy as well, so it is
    /// worth saying plainly: only a Fresh Eyes round read the whole piece, so
    /// only a Fresh Eyes round may offer a retirement (spec §6). The host
    /// supplies this closure exactly when `run.freshEyes == true`; a warm round
    /// passes `nil` and gets the line without the button. The alternative — a
    /// separate `freshEyes` flag beside the closure — is two inputs that can
    /// disagree, and the disagreement would be a Retire button over a delta.
    var onRetire: ((String) -> Void)? = nil
    /// **What a refused ledger verb said**, in the host's own refusal channel —
    /// `offerFailure`'s twin, one channel for all three verbs. Without it a
    /// ruling the op log turned away would leave a button that looks pressed
    /// and a ledger that never moved.
    var ledgerFailure: String? = nil

    /// **Which exercises have been accepted, for this mount and this RUN.** By
    /// INDEX rather than by habit, because a `Letter.Habit` has no id and two
    /// habits could legitimately share a name.
    ///
    /// Deliberately not persisted. The task the button files is durable and
    /// op-logged; this is only what stops a writer filing the same exercise
    /// twice while reading one letter, and a letter does not outlive its run.
    @State private var acceptedExercises: Set<Int> = []
    /// **The run those indices belong to** (final review, Important). An index
    /// means nothing outside one letter: held across runs, the next round's
    /// first habit is born disabled, and a disabled Accept as task is the app
    /// saying the task is already filed. Neither host applies `.id(runId)`, so
    /// the memory carries its own run rather than trusting the view's identity
    /// \u{2014} the shape `LetterKeep.Kept` and `TurnClauseOffer.filedRunId`
    /// already take.
    @State private var acceptedRunId: String?

    /// Whether this run has already filed the habit at `index`. A memory from
    /// another run answers no, and is dropped on the next press.
    private func hasAccepted(_ index: Int) -> Bool {
        acceptedRunId == runId && acceptedExercises.contains(index)
    }

    /// Remember the press, against the run that made it. Read at render time
    /// rather than cleared by an `onChange`, so a run swap never draws one
    /// frame with the previous run's answers in it.
    private func remember(_ index: Int) {
        if acceptedRunId != runId {
            acceptedRunId = runId
            acceptedExercises = []
        }
        acceptedExercises.insert(index)
    }

    /// **What this mount has already filed into the ledger, for this RUN** (P2
    /// Task 6) — kept lessons by habit index, retirements by heading, and the
    /// one plural press.
    ///
    /// One run key for all three, because all three are presses on one letter
    /// and a letter does not outlive its run. Held across runs the next
    /// round's first habit would be born disabled, and a disabled *Keep as
    /// lesson* is the app saying the lesson is already in the ledger —
    /// `acceptedExercises`' defect, in three more places.
    ///
    /// Retirements are keyed by HEADING rather than by index, unlike the
    /// habits: a retirable heading is a string the letter names, the list it
    /// sits in is filtered against the writer's file, and an index into a
    /// filtered list means nothing if the file moves under it.
    ///
    /// Deliberately not persisted. What the presses file is durable and
    /// op-logged; this is only what stops the writer filing the same entry
    /// twice while reading one letter.
    @State private var keptLessons: Set<Int> = []
    @State private var retiredLessons: Set<String> = []
    @State private var allChoicesFiled = false
    @State private var ledgerRunId: String?

    private func hasKept(_ index: Int) -> Bool {
        ledgerRunId == runId && keptLessons.contains(index)
    }

    private func hasRetired(_ heading: String) -> Bool {
        ledgerRunId == runId && retiredLessons.contains(heading)
    }

    private func hasFiledAllChoices() -> Bool {
        ledgerRunId == runId && allChoicesFiled
    }

    /// Drop another run's answers before recording this one's — read at render
    /// time rather than cleared by an `onChange`, so a run swap never draws one
    /// frame with the previous run's presses in it (`remember(_:)`'s rule).
    private func forgetAnotherRun() {
        guard ledgerRunId != runId else { return }
        ledgerRunId = runId
        keptLessons = []
        retiredLessons = []
        allChoicesFiled = false
    }

    private func rememberKept(_ index: Int) {
        forgetAnotherRun()
        keptLessons.insert(index)
    }

    private func rememberRetired(_ heading: String) {
        forgetAnotherRun()
        retiredLessons.insert(heading)
    }

    private func rememberAllChoices() {
        forgetAnotherRun()
        allChoicesFiled = true
    }

    // MARK: - Decisions

    /// The signature: the voice's name, and the round it signed.
    ///
    /// The lane's pass name is deliberately absent. In Review it is already
    /// the line directly above (`ReviewRoundCockpit.laneLine`), and in Author
    /// the pane holds no pass list to name one from — a signature that said
    /// the pass in one home and not the other would be two signatures.
    static func signature(voice: String, round: Int?) -> String {
        guard let round else { return "\u{2014} \(voice)" }
        return "\u{2014} \(voice) \u{00b7} round \(round)"
    }

    /// Whether any scene row does not turn — the half of the offer's
    /// condition this view owns. A row whose `turn` is whitespace is
    /// turn-less: the model writes `""` for a blank cell, and a cell holding
    /// one space is the same blank.
    static func hasTurnlessScene(_ letter: Letter) -> Bool {
        (letter.scenes ?? []).contains {
            $0.turn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether any scene row carries a charge — what decides the fourth
    /// column. Weak-form tables carry none at all, and an always-drawn column
    /// of blanks would tell a writer their reader had nothing to say about
    /// charge when the form has no charge to say anything about.
    static func hasCharge(_ scenes: [Letter.Scene]) -> Bool {
        scenes.contains { !($0.charge ?? "").isEmpty }
    }

    /// The words a jump chip carries — **never a paragraph id**
    /// (`DiagnosticsPane.jumpExcerpt`'s rule, one layer out). The live
    /// paragraph when it can be read, the ref's own remembered excerpt when
    /// it cannot, and `nil` when neither has any words in it.
    static func chipRef(
        for ref: Diagnostic.Ref, currentText: (String) -> String?
    ) -> Diagnostic.Ref? {
        let live = (currentText(ref.paragraphId) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = live.isEmpty
            ? ref.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            : live
        guard !words.isEmpty else { return nil }
        return Diagnostic.Ref(
            paragraphId: ref.paragraphId,
            excerpt: DiagnosticsPane.truncatedDriftQuote(words))
    }

    /// "and N more" for the refs beyond the first. `nil` for a row with one
    /// ref or none, which is most of them.
    ///
    /// It counts the refs the ENTRY carries, not the ones a chip was drawn
    /// for: a habit citing three paragraphs stands on three whether or not the
    /// first of them still has words in it (fix round 1, Minor 3).
    static func andMore(_ refs: [Diagnostic.Ref]) -> String? {
        guard refs.count > 1 else { return nil }
        return "and \(refs.count - 1) more"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.title)
                .font(.callout.weight(.semibold))
            answerPart
            Text(letter.about)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            oneThingPart
            workingPart
            habitsPart
            questionsPart
            scenesPart
            retiredPart
            ledgerFailurePart
            offerPart
            Text(signature)
                .font(.caption)
                .foregroundStyle(.secondary)
            keepPart
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **The answer to what the writer asked, first** (P2 Task 6, spec §3.1).
    /// Before the say-back, because a writer who asked something reads for that
    /// before anything else, and a reply buried under the letter's own opening
    /// is a reply they have to hunt for.
    ///
    /// The ASK draws only as this answer's caption. An ask with no answer draws
    /// nothing at all: the letter is never refused over a missing answer, and a
    /// caption alone would be the app quoting the writer's own question back at
    /// them with silence under it.
    @ViewBuilder
    private var answerPart: some View {
        if let answer = letter.answer, !answer.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let asked = letter.asked,
                   !asked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(Self.askedCaption(asked))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(answer)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Saunders's rule, in its own weight and with no label. A header saying
    /// "One thing" over a single sentence would be the schema showing
    /// through; the emphasis is what says it is the one thing.
    @ViewBuilder
    private var oneThingPart: some View {
        if let oneThing = letter.oneThing, !oneThing.isEmpty {
            Text(oneThing)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var workingPart: some View {
        if !letter.working.isEmpty {
            sectionHeader(Self.workingTitle)
            ForEach(Array(letter.working.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.what)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(entry.why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    refRow(entry.refs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var habitsPart: some View {
        if !letter.habits.isEmpty {
            sectionHeader(Self.habitsTitle)
            ForEach(Array(letter.habits.enumerated()), id: \.offset) { index, habit in
                VStack(alignment: .leading, spacing: 3) {
                    Text(habit.name)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if !habit.cost.isEmpty {
                        Text(habit.cost)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    refRow(habit.refs)
                    if let exercise = habit.exercise, !exercise.isEmpty {
                        Text(exercise)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    habitVerbs(habit, at: index)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            allChoicesPart
        }
    }

    /// **A habit's two buttons, side by side.**
    ///
    /// They answer different questions and neither implies the other: *Accept
    /// as task* files the exercise the round proposed, and needs an exercise to
    /// exist; *Keep as lesson* commits the habit itself to the ledger, and a
    /// habit with no exercise is as worth keeping as one with. Drawn together
    /// because they are the two things a writer does with one habit, and the
    /// row draws nothing at all when neither stands.
    @ViewBuilder
    private func habitVerbs(_ habit: Letter.Habit, at index: Int) -> some View {
        let exercise = habit.exercise ?? ""
        let keeps = onKeepAsLesson != nil
            && LessonOffer.keepIsOffered(habit, ledgerText: ledgerText)
        if !exercise.isEmpty || keeps {
            HStack(spacing: 8) {
                if !exercise.isEmpty {
                    Button(Self.acceptTitle) {
                        remember(index)
                        onAcceptExercise(habit)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    // **Disabled rather than gone.** A button that
                    // vanished on its own press would leave the writer
                    // unsure whether it fired; disabled says it did, and
                    // says the task is already filed.
                    .disabled(hasAccepted(index))
                }
                if keeps, let onKeepAsLesson {
                    Button(Self.keepAsLessonTitle) {
                        rememberKept(index)
                        onKeepAsLesson(habit)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(hasKept(index))
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// **These are all choices** — the seeding gesture (spec §6): a Fresh Eyes
    /// read over a finished piece, and one press instead of six stets.
    ///
    /// Drawn only when the host handed over a way to file it, which is the host
    /// saying the round was Fresh Eyes and raised more than one habit
    /// (`LessonOffer.allChoicesIsOffered`). It sits under the habits rather
    /// than beside any one of them, because it is about all of them.
    @ViewBuilder
    private var allChoicesPart: some View {
        if let onAllChoices {
            Button(Self.allChoicesTitle) {
                rememberAllChoices()
                onAllChoices()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(hasFiledAllChoices())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// **What the round looked for and did not find** (spec §6), narrowed to
    /// the lessons the writer's ledger actually carries — a heading the model
    /// re-spelled, or one already retired, draws nothing at all rather than an
    /// offer about a row that is not there (`LessonOffer.retirable`).
    ///
    /// **The tense is the round's, and it decides whether there is a button.**
    /// A warm round read a delta, and a three-paragraph delta proves nothing
    /// about a habit, so it says what it can and offers nothing. A Fresh Eyes
    /// round read the whole piece cold, which is the evidence a retirement
    /// stands on. `onRetire` is what carries that distinction in
    /// (see its own note).
    @ViewBuilder
    private var retiredPart: some View {
        let headings = LessonOffer.retirable(letter, ledgerText: ledgerText)
        if !headings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(headings, id: \.self) { heading in
                    if let onRetire {
                        HStack(spacing: 8) {
                            Text(Self.freshRetiredLine(heading))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(hasRetired(heading)
                                   ? Self.retiredTitle : Self.retireTitle) {
                                rememberRetired(heading)
                                onRetire(heading)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(hasRetired(heading))
                            Spacer(minLength: 0)
                        }
                    } else {
                        Text(Self.warmRetiredLine(heading))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// **One refusal channel for all three ledger verbs**, drawn where the
    /// ledger's own parts end.
    ///
    /// Keep as lesson sits in Habits and Retire sits below Scenes, so a
    /// refusal drawn beside the press would be two slots — and the one for a
    /// habit would vanish with the button the moment the ledger it failed to
    /// join was re-read. Red rather than secondary, `keepFailure`'s rule: the
    /// letter's other captions are where success speaks.
    @ViewBuilder
    private var ledgerFailurePart: some View {
        if let ledgerFailure {
            Text(ledgerFailure)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var questionsPart: some View {
        if !letter.questions.isEmpty {
            sectionHeader(Self.questionsTitle)
            ForEach(Array(letter.questions.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.question)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    refRow(entry.refs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// **The scene table** — compact, and blank cells blank (spec §3.5). A
    /// blank `changes` is an observation the letter's prose may pick up, and
    /// filling it with a dash here would put words in the reader's mouth.
    ///
    /// `scenes == nil` and `scenes == []` both draw nothing, and they mean
    /// different things upstream — the piece does not move by scenes, versus
    /// a table with no rows — but neither is a table, so neither gets a
    /// heading.
    @ViewBuilder
    private var scenesPart: some View {
        if let scenes = letter.scenes, !scenes.isEmpty {
            sectionHeader(Self.scenesTitle)
            let charged = Self.hasCharge(scenes)
            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    columnHeader(Self.wantsColumn)
                    columnHeader(Self.changesColumn)
                    columnHeader(Self.turnColumn)
                    if charged { columnHeader(Self.chargeColumn) }
                }
                ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                    GridRow {
                        cell(scene.wants)
                        cell(scene.changes)
                        cell(scene.turn)
                        if charged { cell(scene.charge ?? "") }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// **The standing offer** — drawn only when the host handed over a way to
    /// file the clause AND a row does not turn. Both halves matter: the host
    /// knows the run's position and where a ruling would go, this view knows
    /// whether the table has anything the clause would bite on.
    @ViewBuilder
    private var offerPart: some View {
        if let onAddTurnClause, Self.hasTurnlessScene(letter) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Self.turnOfferLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(addToIntentTitle) { onAddTurnClause() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
                if let offerFailure {
                    Text(offerFailure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var keepPart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(Self.keepTitle) { onKeep() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if let keepConfirmation {
                Text(keepConfirmation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let keepFailure {
                Text(keepFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func cell(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A row's first ref as a jump chip, plus "and N more" for the rest —
    /// the shape spec §3.5 asks of a question row, applied to every part that
    /// carries refs, because a reference the writer cannot travel to is a
    /// reference they have to hunt for.
    @ViewBuilder
    private func refRow(_ refs: [Diagnostic.Ref]) -> some View {
        let chip = refs.first.flatMap {
            Self.chipRef(for: $0, currentText: currentText)
        }
        let more = Self.andMore(refs)
        // **The count does not depend on the chip** (fix round 1, Minor 3).
        // Drawn only inside `if let chip`, "and 2 more" vanished whenever the
        // FIRST ref had no words left in it — a paragraph rewritten to nothing
        // — and the row then claimed the habit stood on one place when it
        // stood on three. The chip is a way to travel; the count is a fact
        // about the note.
        if chip != nil || more != nil {
            HStack(spacing: 6) {
                if let chip { ExcerptChip(ref: chip, onJump: onJump) }
                if let more {
                    Text(more)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
