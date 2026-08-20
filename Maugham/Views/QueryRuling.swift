import SwiftUI
import MaughamCore

/// **Answering a translator hardens into doctrine** (publish department, spec
/// §4): one act, two records.
///
/// A translator's question arrives as a `language`-tagged annotation — an
/// anchored `.query`, or the `.craftNote` a whole-document question has to mint
/// as (`addAnnotation` refuses an anchorless `.query`; P2). The writer answers
/// it once, and the sentence becomes:
///
/// 1. a dated, itemized **ruling** under that edition's brief `## Rulings`,
///    carrying the question's own words as its «excerpt» — the shape
///    `DiagnosticsPane.commitAnswer` gives a conformance strain's answer, for
///    the same reason: a decision the next round is checked against has to say
///    what it decided *about*; and
/// 2. the **reply on the thread**, so the question leaves the queue and the
///    next briefing's dispositions carry the answer instead of re-raising it.
///
/// **No new door.** Everything here goes through `RulingPerformer.rule`, which
/// is the one way into the writer-owned layer (spec §3.4) — this type chooses
/// the destination and orders the two writes, and holds no markdown of its own.
///
/// **The language is the question's, and there is no picker.** A query knows
/// which edition it belongs to; asking the writer would let a Spanish decision
/// be filed under the French brief with nothing red. `.editionBrief(lang)` at
/// `.project` scope is the brief's own address — the same one `DepartmentPaneHost`
/// opens and `TranslatorEnvironment` briefs from.
///
/// **`world:` is not a parameter, and that is the discipline made structural.**
/// `RulingPerformer`'s cache holds *intent* readings; nothing derives a world
/// from an edition brief, so every brief-side call passes `nil`. Rather than
/// leaving a `DeclaredWorldStore?` here for a later caller to fill in wrongly,
/// there is nowhere to put one: `commit` cannot pass anything but `nil`.
///
/// **Static, taking everything it touches**, so the whole act is drivable
/// against a real `ProjectStore` and a real `Document` without mounting a pane
/// — `DiagnosticsPane.commitAnswer`'s shape and `RulingsStratum`'s, and the
/// reason `QueryRulingTests` can assert at the op log rather than at a preview.
@MainActor
enum QueryRuling {

    // MARK: - Who is offered this

    /// The edition a note belongs to, or nil if it belongs to none.
    ///
    /// **Kind is asked as well as the tag**, though `AnnotationDeriver` only
    /// ever projects `language` onto these two: a predicate that trusted the
    /// tag alone would silently start offering the affordance the day some
    /// other kind gained one, and this is the gate on which brief a sentence
    /// is filed under.
    static func language(of annotation: Annotation) -> String? {
        switch annotation.kind {
        case .query, .craftNote:
            guard let tag = annotation.language, !tag.isEmpty else { return nil }
            return tag
        case .comment, .suggestedChange:
            return nil
        }
    }

    /// Whether the row draws "Answer as ruling…".
    ///
    /// Open only. A settled question has already been answered, and offering to
    /// answer it again would mint a second ruling for one decision — the record
    /// the writer is checked against saying the same thing twice, dated a week
    /// apart.
    static func offersARuling(_ annotation: Annotation) -> Bool {
        annotation.status == .open && language(of: annotation) != nil
    }

    // MARK: - What the writer is told

    /// The confirm affordance's sentence — **both destinations, before the
    /// click**. Naming only the brief would leave the writer expecting the
    /// translator's thread still open; naming only the reply would hide the
    /// doctrine this act exists to write.
    static func confirmation(language: String) -> String {
        let edition = TranslationReviewIndicator.displayLabel(forLanguageTag: language)
        return "This becomes a dated ruling in the \(edition) edition brief, "
            + "and posts as your reply here."
    }

    /// What the ruling's line says about where it came from, and what it
    /// settles.
    ///
    /// The excerpt is the question's own text, trimmed through
    /// `DiagnosticsPane.truncatedDriftQuote` — the same budget for the same
    /// reason (an excerpt riding inside a provenance line the writer reads for
    /// as long as the decision stands), so this is a CALL rather than a second
    /// spelling of it. Every em-dash is collapsed to a hyphen first:
    /// `RulingsSection.parseItem` splits an item on its RIGHT-MOST em-dash, so
    /// one surviving inside the quote would move that split into the excerpt
    /// and cut the writer's own sentence off mid-word.
    ///
    /// A question with no words falls back to the bare line rather than
    /// printing an empty «».
    static func provenance(for annotation: Annotation) -> String {
        let words = annotation.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return "answered a translator query" }
        let sanitized = words.replacingOccurrences(of: "\u{2014}", with: "-")
        return "answered a translator query: "
            + "\u{00AB}\(DiagnosticsPane.truncatedDriftQuote(sanitized))\u{00BB}"
    }

    // MARK: - The act

    /// **Write the ruling, then post the reply.** Returns the refusal's own
    /// sentence, or nil.
    ///
    /// **The order is the contract.** A reply posted first would settle the
    /// question and could then lose the doctrine to one refusal — the writer's
    /// decision gone, and the thread closed so nothing asks again. Ruling
    /// first, the worst case is a question the writer answers twice, which they
    /// can see and undo. It is `DiagnosticsPane.commitAnswer`'s ordering
    /// argument, one surface over.
    ///
    /// **A failure between the two is said out loud**, naming what did land: a
    /// writer told only "that didn't work" would re-answer and mint a second
    /// ruling for the decision that is already in the brief.
    ///
    /// Undo is asymmetric and deliberately so, for `commitAnswer`'s reason: the
    /// ruling is an op in the brief's own log and ⌘Z reaches it from the
    /// stratum's rows, while the reply is the annotation's own lifecycle op
    /// with its own undo — passing the window's manager is what puts the reply
    /// on the writer's stack, and nothing here groups the two into one step
    /// (ADR 0023's warning is that grouping state is what corrupts).
    static func commit(
        _ text: String, answering annotation: Annotation,
        in document: Document, store: ProjectStore, undoManager: UndoManager?
    ) async -> String? {
        // Unreachable from either surface — no row without an edition draws the
        // affordance — and it refuses rather than asserting, because a caller
        // that got here has the writer's sentence in hand and a crash would
        // lose it. Never a guessed destination: an answer filed under a brief
        // the question does not belong to is checked against the wrong edition
        // from then on, silently.
        guard let language = language(of: annotation) else { return editionlessRefusal }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await RulingPerformer.rule(
                words, provenance: provenance(for: annotation),
                kind: .editionBrief(language), forScope: .project,
                store: store, world: nil)
        } catch {
            return error.localizedDescription
        }

        do {
            try await document.acceptAnnotation(
                id: annotation.id, userResponse: words, undoManager: undoManager)
        } catch {
            return "Your ruling is in the "
                + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
                + " edition brief, but the reply could not be posted here: "
                + error.localizedDescription
                + " The question is still open — reply to it without ruling again."
        }
        return nil
    }

    /// The refusal for a note that belongs to no edition. It says where the
    /// answer WOULD have gone, because "couldn't do that" over a missing
    /// destination tells the writer nothing they can act on.
    static let editionlessRefusal =
        "This question isn\u{2019}t tagged with an edition, so there is no "
        + "brief to rule into. Reply to it instead."
}

/// The sheet behind "Answer as ruling…" — **one component, both hosts**.
///
/// The queue (`AnnotationsPane`) and the translation pane each draw their own
/// card, and each opens this: the sentence the writer types is going to two
/// places, and a second spelling of the sheet is how one of them would
/// eventually stop saying so.
@MainActor
struct QueryRulingSheet: View {
    let annotation: Annotation
    /// The edition the answer will be filed under — the annotation's own tag,
    /// resolved by the host so the sheet never has to answer "and if it has
    /// none?" (it is not opened for a note that has none).
    let language: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var answer: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answer as Ruling")
                .font(.headline)
            Text(annotation.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $answer)
                .frame(minHeight: 90)
                .border(Color.gray.opacity(0.3))
            // Both destinations, before the click — see `QueryRuling.confirmation`.
            Text(QueryRuling.confirmation(language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Answer as Ruling") {
                    onCommit(answer.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(answer.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 400)
    }
}
