import SwiftUI
import MaughamCore

/// **Answering the first reader hardens into a standing instruction** (two
/// loops P2 Task 5, spec §4): one act, two records — `QueryRuling`'s shape,
/// aimed at the other person who reads this book.
///
/// The writer's own first reader raises a note in the queue. The writer answers
/// it once, and the sentence becomes:
///
/// 1. a dated ruling under her statement's `## Rulings`
///    (`Statement.Kind.firstReader`, `first-reader.md`), which
///    `CompilerPrompt` reads back to her next reading as *standing
///    instructions from the writer*; and
/// 2. the **reply on the thread**, so the note leaves the queue and the next
///    briefing's dispositions carry the answer instead of re-raising it.
///
/// **Why a second type rather than a second arm of `QueryRuling`.** That type's
/// whole subject is the EDITION a note belongs to: its predicate is a language
/// tag, its refusal names a brief, and its confirmation sentence is written in
/// the vocabulary of a translation. Her notes carry no language and never
/// could, and the destination is chosen by WHO WROTE the note rather than by
/// what it is tagged with. Folding the two into one predicate would mean a
/// single function whose answer depends on two unrelated facts, and the first
/// time either changed the other would move with it.
///
/// **No new door.** Everything here goes through `RulingPerformer.rule`, the
/// one way into the writer-owned layer (spec §3.4). This type chooses the
/// destination and orders the two writes, and holds no markdown of its own.
/// `TripwireGrepTests.test_theFirstReadersStatementIsWrittenFromOneFile` is the
/// census that keeps a second surface from spelling the write.
///
/// **The statement is not created here, and that is deliberate.**
/// `RulingPerformer.rule` is find-or-create for the statement and is the only
/// minting path in the app — so the first answer in a project mints
/// `first-reader.md`, and a `createStatement` call of this file's own would be
/// a second spelling of a decision that already has one owner.
/// `FirstReaderRulingTests.test_theFirstAnswerMintsHerStatement` pins the
/// behaviour rather than the call.
///
/// **`world:` is not a parameter**, for `QueryRuling`'s reason: nothing derives
/// a declared world from her statement, so every call here passes `nil`, and
/// there is nowhere to put a store for a later caller to fill in wrongly.
///
/// **Static, taking everything it touches**, so the whole act is drivable
/// against a real `ProjectStore` and a real `Document` without mounting a pane.
@MainActor
enum FirstReaderRuling {

    // MARK: - Who is offered this

    /// The reader an answer would be filed for, or nil when the project has
    /// named nobody.
    ///
    /// `QueryRuling.language(of:)`'s counterpart: it answers the DESTINATION,
    /// and every other member here is built on it, so "who is offered this" and
    /// "where does the sentence go" cannot come apart.
    ///
    /// Trimmed, on `ProjectManifest.authorReader`'s reason — a hand-edited
    /// `project.json` is a writer of this field too, and a reader whose name is
    /// a space is a byline nobody can read.
    static func readerName(in manifest: ProjectManifest) -> String? {
        let name = (manifest.firstReaderName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Whether the row draws "Answer as ruling…" for HER note.
    ///
    /// Four facts, and every one of them is load-bearing:
    ///
    /// - **Open only**, for `QueryRuling.offersARuling`'s reason: a settled
    ///   note has been answered, and answering it again would mint a second
    ///   standing instruction for one decision, dated a week apart.
    /// - **Unstamped** (`reviewPassId == nil`). She reads CHECKS and never
    ///   rounds (`AuthorReader`), so a stamped note is some editor's, filed in
    ///   a lane — and a lane's note answered into her statement would brief her
    ///   with doctrine the writer aimed at Gould.
    /// - **Untagged** (`language == nil`). A language tag is an edition query's,
    ///   and `QueryRuling` owns those. This is what makes the two offers
    ///   mutually exclusive rather than merely unlikely to collide, and
    ///   `RulingDestination.offered` is where that exclusivity is structural.
    /// - **Hers by name.** The author's display name is what the orchestrator
    ///   signs her notes with (`AuthorReader.editorName`), so it is the only
    ///   thing that distinguishes her check notes from the coach's. Compared
    ///   trimmed, because the manifest's side is trimmed on the way in and a
    ///   name that fails to match itself would silently withdraw the offer.
    ///
    /// **Kind is asked as well**, on `QueryRuling.language(of:)`'s reasoning: a
    /// reader's report mints as `.comment` and her letter's one question as
    /// `.query`, and a predicate that trusted authorship alone would start
    /// offering the affordance over a suggested change the day anything minted
    /// one in her name — an answer filed as doctrine about a rewrite nobody
    /// asked her for.
    ///
    /// **`.craftNote` is deliberately OUT, and it is a live question rather
    /// than a settled one.** An ANCHORLESS finding falls back to a craft note
    /// whatever section raised it (`CompilerNote.init(diagnostic:)`), so an
    /// observation of hers about the piece as a whole — arguably the most
    /// rulable thing she says — draws no offer today. The task's kind list is
    /// `.comment`/`.query` and this honours it rather than widening a spec'd
    /// enumeration on its own; adding the case here and its arm to
    /// `FirstReaderRulingTests.test_anAnchorlessNoteOfHersIsNotOfferedOneYet`
    /// is the whole change if the answer is that it should be in.
    static func offersARuling(_ annotation: Annotation, manifest: ProjectManifest) -> Bool {
        guard annotation.status == .open,
              annotation.reviewPassId == nil,
              annotation.language == nil,
              let name = readerName(in: manifest)
        else { return false }
        switch annotation.kind {
        case .comment, .query:
            let author = (annotation.author?.displayName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !author.isEmpty && author == name
        case .craftNote, .suggestedChange:
            return false
        }
    }

    // MARK: - What the writer is told

    /// The confirm affordance's sentence — **both destinations, before the
    /// click**, for `QueryRuling.confirmation`'s reason. Naming only her
    /// statement would leave the writer expecting the note still open; naming
    /// only the reply would hide the instruction this act exists to write.
    static func confirmation(name: String) -> String {
        "This becomes a dated instruction in \(name)\u{2019}s statement, "
            + "and posts as your reply here."
    }

    /// What the instruction's line says about where it came from, and what it
    /// settles.
    ///
    /// The excerpt goes through `DiagnosticsPane.truncatedDriftQuote` — a CALL
    /// rather than a second spelling of the budget — and every em-dash is
    /// collapsed to a hyphen first, because `RulingsSection.parseItem` splits
    /// an item on its RIGHT-MOST em-dash and one surviving inside the quote
    /// would move that split into the excerpt and cut the writer's own sentence
    /// off mid-word.
    ///
    /// A note with no words falls back to the bare line rather than printing an
    /// empty «».
    static func provenance(for annotation: Annotation, name: String) -> String {
        let words = annotation.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return "answering \(name)\u{2019}s note" }
        let sanitized = words.replacingOccurrences(of: "\u{2014}", with: "-")
        return "answering \(name)\u{2019}s note on "
            + "\u{00AB}\(DiagnosticsPane.truncatedDriftQuote(sanitized))\u{00BB}"
    }

    // MARK: - The act

    /// **Write the instruction, then post the reply.** Returns the refusal's
    /// own sentence, or nil.
    ///
    /// `QueryRuling.commit`'s contract, mirrored deliberately rather than
    /// merely resembled — the ORDER, the asymmetric undo and the half-done
    /// refusal are the same arguments about the same two logs:
    ///
    /// - **Ruling first.** A reply posted first would settle the note and could
    ///   then lose the instruction to one refusal — the writer's decision gone,
    ///   the thread closed so nothing asks again. This way the worst case is a
    ///   note the writer answers twice, which they can see and undo.
    /// - **A failure between the two is said out loud**, naming what did land.
    ///   A writer told only "that didn't work" would re-answer and file a
    ///   second instruction for a decision already in her statement.
    /// - **Undo is asymmetric.** The ruling is an op in her statement's own log
    ///   and ⌘Z reaches it from the stratum's rows; the reply is the
    ///   annotation's own lifecycle op with its own undo. Nothing here groups
    ///   the two, because they are separate acts against separate logs.
    static func commit(
        _ text: String, answering annotation: Annotation,
        in document: Document, store: ProjectStore, undoManager: UndoManager?
    ) async -> String? {
        // Unreachable from the queue — no row draws the affordance for a
        // project that has named nobody — and it refuses rather than asserting,
        // because a caller that got here has the writer's sentence in hand and
        // a crash would lose it.
        guard let name = readerName(in: store.manifest) else { return unnamedRefusal }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await RulingPerformer.rule(
                words, provenance: provenance(for: annotation, name: name),
                kind: .firstReader, forScope: .project,
                store: store, world: nil)
        } catch {
            return error.localizedDescription
        }

        do {
            try await document.acceptAnnotation(
                id: annotation.id, userResponse: words, undoManager: undoManager)
        } catch {
            return "Your instruction is in \(name)\u{2019}s statement, but the "
                + "reply could not be posted here: "
                + error.localizedDescription
                + " The note is still open — reply to it without ruling again."
        }
        return nil
    }

    /// The refusal for a project that has named no first reader. It says what
    /// is missing, because "couldn't do that" over an absent destination tells
    /// the writer nothing they can act on.
    static let unnamedRefusal =
        "This project has no first reader named, so there is no statement to "
        + "rule into. Name her in the First Reader pane, or reply to the note "
        + "instead."
}

/// **Where an "Answer as ruling…" press files — one decision, three readers**
/// (two loops P2 Task 5).
///
/// The queue's row draws the control, the sheet words it, and the pane's commit
/// routes it. Asked separately, those three would each carry their own `if`
/// over the two predicates, and the first note that satisfied one of them
/// differently would draw a button that opened a sheet promising a destination
/// the commit did not use.
///
/// **The exclusivity is structural rather than asserted.** An edition query
/// carries a `language` and hers never does, so the two predicates cannot both
/// answer for one note — and expressing that as a single-valued answer means no
/// caller has to know it. `FirstReaderRulingTests` still pins it, because the
/// fact is what makes this shape safe rather than merely tidy.
enum RulingDestination: Equatable {
    /// A translator's language-tagged question — `QueryRuling`'s.
    case editionBrief(language: String)
    /// The writer's own first reader's note — `FirstReaderRuling`'s.
    case firstReader(name: String)

    /// Which of the two this note is offered, or nil for the great majority
    /// that are offered neither.
    ///
    /// **A nil manifest answers the edition arm and never hers.** Hosts that
    /// hold no project identity (a row rendered outside a window) still draw
    /// the translator's affordance, which turns on the note alone; her arm
    /// needs a name, and there is nowhere to read one from.
    @MainActor
    static func offered(
        for annotation: Annotation, manifest: ProjectManifest?
    ) -> RulingDestination? {
        if QueryRuling.offersARuling(annotation),
           let language = QueryRuling.language(of: annotation) {
            return .editionBrief(language: language)
        }
        if let manifest, FirstReaderRuling.offersARuling(annotation, manifest: manifest),
           let name = FirstReaderRuling.readerName(in: manifest) {
            return .firstReader(name: name)
        }
        return nil
    }

    /// The sheet's "both destinations" sentence, in the destination's own
    /// vocabulary.
    @MainActor
    var confirmation: String {
        switch self {
        case .editionBrief(let language): return QueryRuling.confirmation(language: language)
        case .firstReader(let name): return FirstReaderRuling.confirmation(name: name)
        }
    }

    /// What a press over a note offered NEITHER destination says. Unreachable
    /// from the queue — no row draws the control — and neutral about which
    /// destination is missing, because at this point neither was found and
    /// naming one would be a guess the writer cannot act on.
    static let noDestinationRefusal =
        "There is nowhere to file this answer as a ruling. Reply to the note "
        + "instead."

    /// The control's help, which names where the sentence lands. Two words
    /// apart, and the difference is the whole point: a writer hovering over the
    /// button on her note should not be told about an edition brief.
    var help: String {
        switch self {
        case .editionBrief:
            return "Answer as ruling\u{2026} \u{2014} a dated ruling in the "
                + "edition brief, and your reply here"
        case .firstReader(let name):
            return "Answer as ruling\u{2026} \u{2014} a dated instruction in "
                + "\(name)\u{2019}s statement, and your reply here"
        }
    }
}
