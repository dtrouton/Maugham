import SwiftUI
import MaughamCore

/// **The queue's two doors into the lessons ledger** (editorial letter P2 Task
/// 8, spec §6).
///
/// The letter offers a habit; the queue offers a *note*. A Le Guin question
/// raised under a habit the writer has already been told about carries that
/// habit's heading (`Annotation.lessonHeading`, Task 2), and the writer's answer
/// to it can be "yes, and I do that on purpose". That answer is **This is a
/// choice**: a stet that also files. The second door is **Keep as lesson…** on
/// an accepted craft note — spec §6's own second door, where the note's words
/// are the raw material for an entry the writer shortens by hand.
///
/// **A composite verb, not a second write.** Everything here reaches the ledger
/// through `LessonLedgerVerbs`, which is the only production file that names
/// `.lessons` to `RulingPerformer` (global constraint 14,
/// `TripwireGrepTests.test_theLessonsLedgerIsWrittenFromOneFile`). What this
/// file adds is what the LETTER's verbs have no business knowing: how to read an
/// annotation's provenance, how to find a stetted twin, and how to order a
/// ledger write against a `Document` op. `LessonLedgerVerbs` holds no
/// `Document` and this is why it can stay that way.
///
/// **The order is the contract, and it is `QueryRuling.commit`'s** one surface
/// over. The ruling goes first: a stet that landed first would settle the note
/// and could then lose the decision to one refusal, with nothing left on screen
/// to press again. Ruling first, the worst case is a ledger row the writer can
/// see and a note they stet by hand.
///
/// **⌘Z reaches the stet and not the ledger** (ADR 0023). They are separate acts
/// against separate logs — the annotation's lifecycle op and the ledger
/// statement's own — and nothing here groups them. That asymmetry is said out
/// loud in the confirmation the second stet raises, because a writer who
/// pressed one button reasonably expects one ⌘Z to take all of it back.
@MainActor
enum QueueLedgerVerbs {

    // MARK: - Copy (constraint 12 — the writer's register, never a field name)

    /// The row's verb on a question raised under a habit.
    static let choiceTitle = "This is a choice"

    /// The row's verb on an accepted craft note — spec §6's second door.
    static let keepTitle = "Keep as lesson\u{2026}"

    /// The second stet's two answers, and the way out that is neither.
    ///
    /// **Cancel exists and carries the alert's `.cancel` role** (Denver's
    /// ruling, fix round 1). Escape has to abandon: a keystroke that settles a
    /// note is not a way out of a question, and a writer who pressed it to make
    /// the dialog go away would find the note gone from their queue.
    static let makeItAChoiceTitle = "Make it a choice"
    static let justStetTitle = "Just stet"
    static let cancelTitle = "Cancel"

    /// The second stet's question, carrying the heading verbatim (global
    /// constraint 15): what is filed is exactly the entry the round was briefed
    /// on, and the writer can see that before they press.
    static func secondStetTitle(_ heading: String) -> String {
        "Make \u{201C}\(heading)\u{201D} a choice?"
    }

    /// **What the second stet's confirmation says, ⌘Z included.**
    ///
    /// The undo sentence is not decoration. One press does two things to two
    /// logs, and only one of them is on the writer's undo stack; a writer who
    /// pressed ⌘Z expecting the whole act back would find the ledger row still
    /// there and no control on screen that made it.
    static let secondStetHelp =
        "You let this stand once already. Filing it as a choice tells every "
        + "later check the habit is deliberate, so it stops being raised. "
        + "The ledger entry stays; \u{2318}Z reopens the note."

    /// The choice verb's tooltip — the same two facts, before the press.
    static let choiceHelp =
        "This is a choice \u{2014} file this habit in your ledger as a decision "
        + "you have made, and let the note stand. The ledger entry stays; "
        + "\u{2318}Z reopens the note."

    /// The keep verb's tooltip.
    static let keepHelp =
        "Keep as lesson\u{2026} \u{2014} shorten this note to one sentence and "
        + "file it in your ledger, where every later check reads it."

    /// The refusal for a note with no heading to file. Unreachable from the
    /// row (nothing draws the verb without one) and it refuses rather than
    /// asserting, on `QueryRuling.commit`'s reasoning: a caller that got here
    /// has the writer's press in hand and a crash would lose the note with it.
    static let headinglessRefusal =
        "This note isn\u{2019}t raised under anything in your ledger, so there "
        + "is no heading to file as a choice. Stet it instead."

    // MARK: - Whether an offer stands

    /// The habit heading this note was raised under, or nil.
    ///
    /// Blank is nil, and that subsumes the `!= nil` half of every predicate
    /// below: `LessonLedgerVerbs.makeChoice` refuses a blank heading, and a
    /// button whose only outcome is a refusal is worse than no button
    /// (`LessonOffer.keepIsOffered`'s own rule).
    static func heading(of annotation: Annotation) -> String? {
        let heading = (annotation.lessonHeading ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.isEmpty ? nil : heading
    }

    /// **Whether the row draws "This is a choice".**
    ///
    /// Four things have to be true, and each is a different reason:
    ///
    /// - a **heading**, because that is what would be filed, verbatim;
    /// - **compiler-authored**, because a habit is something a round noticed —
    ///   a person's note carrying a heading is not a coach's observation about
    ///   the writer's own tendencies;
    /// - **open**, for `QueryRuling.offersARuling`'s reason: a settled note has
    ///   already been answered, and answering it again would file the same
    ///   decision twice, dated a week apart;
    /// - a **question**, because that is the shape a habit reaches the queue in
    ///   (the letter's `questions` mint as `.query`, P1 Task 4). A craft note
    ///   has its own door below.
    static func offersAChoice(_ annotation: Annotation) -> Bool {
        heading(of: annotation) != nil
            && annotation.isCompilerAuthored
            && annotation.status == .open
            && annotation.kind == .query
    }

    /// **Whether the row draws "Keep as lesson…"** — spec §6's second door.
    ///
    /// An **accepted** craft note is one the writer has already agreed with,
    /// which is exactly when its point is worth carrying into every later
    /// check. Offering it on an open note would be asking the writer to decide
    /// two things at once; offering it on a rejected one would file a lesson
    /// out of something they disagreed with.
    ///
    /// Compiler-authored for `offersAChoice`'s reason. No heading is required:
    /// the sheet is where a heading is made, out of the note's own words.
    ///
    /// **And withdrawn once the note's own sentence stands in the ledger** —
    /// open, a settled choice, or retired (P3 Task 8, Denver's ruling B).
    /// `LessonOffer.keepIsOffered` is the same rule one door over and for the
    /// same reason: each of the three is the writer having already decided
    /// about exactly this sentence, and a second Keep files a duplicate row
    /// that then briefs every later round twice about one thing.
    ///
    /// **Exact identity of the whole body, after trimming** (global constraint
    /// 15) — never a fuzzy match. A near-miss, a trailing full stop, still
    /// draws: the note and the standing entry are then two different sentences
    /// and the app does not guess on the writer's behalf. That the hide is
    /// therefore rare is by construction, because the sheet exists to shorten a
    /// paragraph into a sentence and what is filed is usually the writer's
    /// edit rather than these words; the honest protection against a duplicate
    /// stays `LessonLedgerVerbs.keepAsLesson`'s own find-or-create, which is
    /// asked of the heading actually being filed.
    static func offersAKeep(_ annotation: Annotation, ledgerText: String?) -> Bool {
        guard annotation.isCompilerAuthored
            && annotation.status == .accepted
            && annotation.kind == .craftNote
        else { return false }
        guard let ledgerText else { return true }
        let body = annotation.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !LessonsLedger.parse(ledgerText).entries.contains { entry in
            LessonsLedger.matches(body, heading: entry.heading)
        }
    }

    /// **Whether stetting this note should ASK instead of just stetting** —
    /// the heading to offer, or nil for the plain stet.
    ///
    /// The second stet is the evidence. Once is a note let stand; twice on the
    /// same habit is a pattern, and spec §6 says the app may *offer* at that
    /// point and never file on its own.
    ///
    /// Three conditions:
    ///
    /// - the note carries a heading;
    /// - **another** note under the same heading is already `.stetted` —
    ///   `LessonsLedger.matches` decides that, exact after trimming, so a
    ///   heading the model re-spelled names no twin;
    /// - the heading is **not already a choice** in the ledger. A second offer
    ///   for a decision the writer has already filed is noise, and pressing it
    ///   would file the row twice.
    ///
    /// Deliberately NOT gated on kind, status or authorship. What is being
    /// offered is a fact about the *heading*, and a heading only ever reaches an
    /// annotation from a round in the first place.
    ///
    /// **`all` is the PROJECT's notes, and unfiltered** (P3 Task 8, Denver's
    /// ruling A). Project-scope, because the ledger this may file into is
    /// project-scope and a habit is the writer's rather than a chapter's: a
    /// pattern showing up once per chapter is exactly the one worth naming, and
    /// a per-document search would never see it. Unfiltered, because
    /// `Document.annotations()` defaults to `[.open]` and
    /// `ProjectStore.listAnnotationsAcrossProject` filters nothing — a caller
    /// handing over the default query would find no stetted twin, ever, and the
    /// offer would simply never appear (`stetAnnotation`'s own capture makes
    /// the same correction for the same reason).
    static func secondStetOffer(
        for annotation: Annotation, among all: [Annotation], ledgerText: String?
    ) -> String? {
        guard let heading = heading(of: annotation) else { return nil }
        let alreadyAChoice = LessonsLedger.choices(in: ledgerText ?? "")
            .contains { LessonsLedger.matches(heading, heading: $0) }
        guard !alreadyAChoice else { return nil }
        let twin = all.contains { other in
            other.id != annotation.id
                && other.status == .stetted
                && LessonsLedger.matches(
                    heading, heading: (other.lessonHeading ?? ""))
        }
        return twin ? heading : nil
    }

    // MARK: - Provenance

    /// **What a row filed from the queue says about where it came from.**
    ///
    /// `LessonLedgerVerbs.provenance`'s sentence, over the note's own facts
    /// rather than a run's: the voice is the note's author — which for a
    /// compiler-authored note is the editor who wrote it (Le Guin, Lish) — and
    /// the lane is the pass it was stamped with, at the round it was raised in.
    /// A lesson outlives the note that raised it, so this is the one place that
    /// record can be made.
    ///
    /// The lane resolution is `LetterKeep.laneLine`'s, called rather than
    /// respelled: a lesson filed from the queue and a lesson filed from the
    /// letter must say the same thing about the same round.
    static func provenance(for annotation: Annotation, store: ProjectStore) -> String {
        LessonLedgerVerbs.provenance(
            voice: AnnotationAuthorPresentation.label(for: annotation.author),
            lane: LetterKeep.laneLine(
                passId: annotation.reviewPassId,
                round: annotation.compilerRound,
                // **No stage.** A note carries a pass and a round; the draft
                // stage is a stamp on a RUN's letter about that run's own
                // delta, and putting it on a row filed from the queue would
                // attribute one reading of the delta to whatever round
                // happened to raise this note (global constraint 28).
                stage: nil, store: store))
    }

    // MARK: - The acts

    /// **This is a choice: the ruling, then the stet.** Returns the refusal's
    /// own sentence, or nil.
    ///
    /// See the type doc for why the order is what it is. The two failure
    /// sentences are different because the two states they describe are: a
    /// refused ruling has changed nothing, and a refused stet has left a
    /// decision in the ledger with the note still open — a writer told only
    /// "that didn't work" would press again and file the row twice.
    static func makeChoice(
        _ annotation: Annotation, in document: Document,
        store: ProjectStore, world: DeclaredWorldStore?, undoManager: UndoManager?
    ) async -> String? {
        guard let heading = heading(of: annotation) else { return headinglessRefusal }
        do {
            try await LessonLedgerVerbs.makeChoice(
                heading, provenance: provenance(for: annotation, store: store),
                store: store, world: world)
        } catch {
            return error.localizedDescription
        }
        do {
            try await document.stetAnnotation(
                id: annotation.id, undoManager: undoManager)
        } catch {
            return "Your choice is in the ledger, but the note could not be "
                + "let stand: \(error.localizedDescription) "
                + "It is still open \u{2014} stet it without filing again."
        }
        return nil
    }

    /// **Keep as lesson: the writer's own sentence, filed.** Returns the
    /// refusal's own sentence, or nil.
    ///
    /// No annotation op. The note is already accepted, and filing a lesson out
    /// of it is a second, independent act — resolving it again would be this
    /// verb deciding something the writer already decided.
    ///
    /// The blank guard is a belt behind the sheet's disabled Commit: the sheet
    /// is the writer-facing refusal, and this is what stops a caller filing an
    /// entry that reads as the writer's commitment to nothing.
    static func keepAsLesson(
        _ heading: String, from annotation: Annotation,
        store: ProjectStore, world: DeclaredWorldStore?
    ) async -> String? {
        let words = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            return RulingFailure.emptyRuling.localizedDescription
        }
        do {
            try await LessonLedgerVerbs.keepAsLesson(
                words, provenance: provenance(for: annotation, store: store),
                store: store, world: world)
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}

/// **A second stet waiting on the writer's yes** — what the offer is about, and
/// what each of its two answers does.
///
/// `DesignGateConfirmation`'s shape and for exactly its reason: an alert is
/// drawn by the window server, and a headless mount can neither read its words
/// nor press its buttons. A pane that kept this only as private view state
/// would put the ledger's one offer out of reach of every test in the suite —
/// so the pair travels as a value, the alert's buttons run these closures, and
/// nothing about what a press does is decided in the alert.
struct ChoiceOffer: Identifiable {
    /// The note being stetted. Its id, not the note, because this outlives one
    /// render and an annotation is a projection.
    let annotationId: String
    /// The ledger heading the offer names, verbatim.
    let heading: String
    let makeItAChoice: () -> Void
    let justStet: () -> Void
    /// Abandon: the offer goes away and the note is left exactly as the writer
    /// found it. What Escape does, and the only one of the three that touches
    /// neither the ledger nor the note.
    let cancel: () -> Void

    var id: String { annotationId }
}

/// The sheet behind **Keep as lesson…** — one field, prefilled with the note.
///
/// `QueryRulingSheet`'s shape, and the prefill is the point of it: a craft note
/// is a paragraph, a ledger entry is a sentence, and the writer's job here is to
/// shorten one into the other rather than to retype it from memory. The entry
/// IS the sentence — a lesson has no title and no body — so what is on screen is
/// exactly what will be filed.
@MainActor
struct LessonHeadingSheet: View {
    let annotation: Annotation
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var heading: String

    init(annotation: Annotation,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.annotation = annotation
        self.onCommit = onCommit
        self.onCancel = onCancel
        _heading = State(initialValue: annotation.body)
    }

    private var trimmed: String {
        heading.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sentence case, the register the verb and the guide both use
            // (constraint 12) — never Title Case invented at the sheet.
            Text("Keep as lesson")
                .font(.headline)
            TextEditor(text: $heading)
                .frame(minHeight: 90)
                .border(Color.gray.opacity(0.3))
            Text("This becomes a dated entry in your ledger, and every later "
                 + "check is measured against it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Keep as lesson") { onCommit(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20).frame(width: 400)
    }
}
