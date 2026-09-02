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
    static let keepTitle = "Keep this letter"

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

    /// **Which exercises have been accepted, for this mount.** By INDEX
    /// rather than by habit, because a `Letter.Habit` has no id and two
    /// habits could legitimately share a name.
    ///
    /// Deliberately not persisted. The task the button files is durable and
    /// op-logged; this is only what stops a writer filing the same exercise
    /// twice while reading one letter, and a letter does not outlive its run.
    @State private var acceptedExercises: Set<Int> = []

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
            Text(letter.about)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            oneThingPart
            workingPart
            habitsPart
            questionsPart
            scenesPart
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
                        Button(Self.acceptTitle) {
                            acceptedExercises.insert(index)
                            onAcceptExercise(habit)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        // **Disabled rather than gone.** A button that
                        // vanished on its own press would leave the writer
                        // unsure whether it fired; disabled says it did, and
                        // says the task is already filed.
                        .disabled(acceptedExercises.contains(index))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                    Button(Self.addToIntentTitle) { onAddTurnClause() }
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
