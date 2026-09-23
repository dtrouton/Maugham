// Maugham/Views/LoadQuestions.swift
import Foundation
import MaughamCore

/// **What a load can ask the writer** (signed op log P3b Task 7, spec §4.5 and
/// §7.2).
///
/// A load holds lines for three reasons, and they are not three questions.
///
/// - A **stranger's** lines are `AdmissionDecision`'s, and that queue is
///   unchanged: *this device is not in your book — let it in?*
/// - An **unsigned** stream's lines and an admitted person's **unjudgeable**
///   ones are not questions at all. There is nothing the writer can press that
///   would change either — no key to admit, no permit this build can read — so
///   they get a SENTENCE (`HeldLines.sentence`) in History and the Inbox, and
///   no control.
/// - A **piece nobody has claimed** is the one question a load raises that the
///   writer can answer on the spot, and it is this file.
///
/// Spec §4.5: an author of *some* pieces, writing with her own hand, putting
/// manuscript text into a piece that is in nobody's scope. That is *she started
/// something new* — a question rather than a violation — and until it is
/// answered her paragraphs sit outside the draft with nothing on screen saying
/// so. The partition that held them says whose they are and which piece they
/// are in (`Document.startedAPiece` → `HeldLineUnion.startedAPiece`); this
/// turns that into a question with two answers.
///
/// **Never *yours*.** The two answers are *theirs* and *not now*, and there is
/// deliberately no third. Nothing in this app applies one device's text as the
/// opening of another's piece: the root claims a piece by WRITING in it, which
/// makes `UnownedPiece.aBookAuthorHasWrittenItsText` true and REFUSES her lines
/// — a different act with a different outcome, reached by typing rather than by
/// a button. A *yours* here would be a control nothing could honour.
///
/// Pure, and deliberately ignorant of the folder: it is handed the counts a
/// load already produced, the registry a reader already verified, the titles
/// the manifest already holds, and this device's own memory of what it has
/// already asked. Nothing here reads a file, so the whole of what the writer
/// would be shown is decidable in a unit test.
enum LoadQuestions {

    /// One piece somebody started that nobody has claimed.
    struct NewPiece: Identifiable, Equatable {
        /// The person record's fingerprint — the holder her lines are held
        /// under, and the subject of the permit change *Theirs* would write.
        let person: String
        /// What this book calls them: their label, else their four-character
        /// code, which is what their Mac shows for itself.
        let name: String
        let docId: String
        /// What the writer knows the piece as. Never empty — a piece the
        /// manifest has no title for gets a placeholder, because having no
        /// title is not a reason to say nothing about words waiting outside
        /// the draft.
        let title: String
        /// How much of theirs is waiting on this answer.
        let heldLines: Int

        /// Per PERSON and per PIECE, which is the grain of the question and
        /// the grain the *not now* memory is keyed at.
        var id: String { "\(person)/\(docId)" }

        /// **The question**, naming both so the writer can answer it without
        /// going to look anything up.
        var question: String {
            "\(name) started \u{201C}\(title)\u{201D} — is it theirs?"
        }

        /// What pressing *Theirs* is about to do, and what it is not. It names
        /// the piece rather than the rung, because *what may they write* is a
        /// question this sentence must not answer twice (tripwire 47).
        var consequence: String {
            let waiting = heldLines == 1
                ? "The 1 line waiting"
                : "The \(heldLines) lines waiting"
            return "\(waiting) will join the draft, and \(name) will be able to "
                + "go on writing in this piece. Nothing else they may write "
                + "changes."
        }

        /// Both answers, and there is no third.
        var theirsTitle: String { "Theirs" }
        var notNowTitle: String { "Not now" }

        /// What *Not now* does, said plainly: nothing. It is not a refusal and
        /// it is not an answer — it is the writer saying they will decide
        /// later, and the words go on waiting exactly as they are.
        var notNowConsequence: String {
            "Nothing is written and nothing is set aside. The question waits in "
                + "People & Devices until you answer it."
        }
    }

    /// **Every piece question this window should raise**, ordered by person
    /// and then by piece so two runs over one folder ask in the same order.
    ///
    /// The filters, and why each is both directions:
    ///
    /// 1. Something is actually held (`counts`), because a question about
    ///    nothing is a question with no consequence to state.
    /// 2. `HeldLines.holder` says this is an admitted person — **asked, never
    ///    re-derived** (tripwire 39's shape). A stranger's lines are the
    ///    admission sheet's and asking both would ask the writer twice; an
    ///    unsigned stream has no person and no permit at all, and its way back
    ///    in is the Inbox.
    /// 3. `RegistryAdmission.changePermitOutcome` says this Mac could actually
    ///    answer it. Only the root that admitted somebody may widen their
    ///    scope, so on any other Mac this is a button that can only refuse —
    ///    and the verb's own rule is asked rather than restated, which is what
    ///    keeps this file out of the authority business (tripwires 41, 47).
    /// 4. This device has not already asked (`declined`). *Not now* is
    ///    remembered per person and per piece, and it is remembered so that a
    ///    load never nags: the question goes on waiting in People & Devices,
    ///    where the writer goes when they are ready.
    static func newPieces(
        held: HeldLineUnion,
        registry: Registry,
        titles: [String: String],
        declined: Set<OpLogDeviceState.DeclinedPiece>,
        me: String
    ) -> [NewPiece] {
        held.startedAPiece.keys.sorted().flatMap { holder -> [NewPiece] in
            guard let waiting = held.counts[holder], waiting > 0 else { return [] }
            // Task 2's one classifier, asked with Task 7's widened input. A
            // holder the walk named here IS an admitted person in every honest
            // case; the check is what makes that a fact rather than an
            // assumption, and it is the same function every other surface asks.
            guard case .permitPending(let person, true) = HeldLines.holder(
                of: holder, registry: registry, startedAPiece: true)
            else { return [] }
            guard (try? RegistryAdmission.changePermitOutcome(
                person: person, by: me, in: registry).get()) != nil
            else { return [] }
            let name = registry.person(person)?.label ?? DeviceCode.short(person)
            return (held.startedAPiece[holder] ?? []).sorted().compactMap { docId in
                guard !declined.contains(
                    .init(person: person, docId: docId)) else { return nil }
                return NewPiece(
                    person: person, name: name, docId: docId,
                    title: titles[docId] ?? "a new piece", heldLines: waiting)
            }
        }
    }
}
