import Foundation
import MaughamCore

/// What a ledger verb refused to do, in the writer's words.
///
/// Only the two refusals that are this file's own. Everything the performer or
/// the store already refuses in its own vocabulary — an empty ruling, an
/// unreadable destination, a file system that would not take the file —
/// propagates as `RulingFailure`/`ProjectStoreError` rather than being re-said
/// here in a second sentence that can drift from the one every other surface
/// shows (`RulingFailure`'s own restraint).
enum LessonLedgerFailure: LocalizedError, Equatable {
    /// Retire was aimed at a heading the ledger does not carry as a live
    /// lesson — never kept, already retired, or standing as a choice. Nothing
    /// is written for any of the three.
    case notOpen(String)
    /// *These are all choices* stopped part-way. The count is carried because
    /// the act is plural and its failure is partial: a writer told only that
    /// it failed would not know whether to press again.
    case someChoicesFiled(landed: Int, of: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .notOpen(let heading):
            return "\u{201C}\(heading)\u{201D} is not an open lesson in your ledger, "
                + "so nothing was retired."
        case .someChoicesFiled(let landed, let total, let reason):
            return "Maugham filed \(landed) of \(total) as choices and then stopped: "
                + reason
        }
    }
}

/// **The writer's verbs on the lessons ledger, in one file** (editorial letter
/// P2 Task 6, spec §6).
///
/// The ledger is the writer's own prose and moves only by the writer's hand —
/// the rule rulings already keep. The model's job is to *notice* and the
/// letter's job is to *offer*; these four verbs are what a press finally does,
/// and every one of them goes through `RulingPerformer`, the single door into
/// the writer-owned layer (spec §3.4).
///
/// **This is the ONLY production file that names `.lessons` to
/// `RulingPerformer`** (global constraint 14). Two hosts draw the letter and a
/// third surface — the queue — files choices, so three places could each spell
/// `rule(…, kind: .lessons, forScope: .project, …)` and drift on the scope,
/// the provenance or the choice marker with nothing red.
/// `TripwireGrepTests.test_theLessonsLedgerIsWrittenFromOneFile` is the census
/// that says so, with a planted offender as its control.
///
/// **Retire rewrites, it never revokes** (spec §6). A retired habit can come
/// back, and the entry says when it left; deleting the line would take the
/// record with it. `RulingPerformer.edit` is in-place, so the entry keeps its
/// position, the day it was ruled and its provenance.
///
/// **Identity is the heading, verbatim** (global constraint 15). Every string
/// these verbs are handed is one the model was *given* and echoed back. The app
/// decides whether it names a row in the writer's file — through
/// `LessonsLedger.matches`, exact after trimming — and a near-miss writes
/// nothing rather than retiring a row the writer never named.
@MainActor
enum LessonLedgerVerbs {

    // MARK: - Provenance

    /// What the ledger line says about where it came from.
    ///
    /// `TurnClauseOffer.provenance(voice:)`'s sentence plus the round's lane
    /// when there is one. A lesson outlives the letter that raised it by
    /// design, so *which* round noticed it is the one fact a writer reading
    /// their ledger months later cannot recover any other way — where an
    /// intent clause sits beside the essay it belongs to and needs no round.
    ///
    /// A passless run has no lane, and the empty string is what stops the
    /// provenance inventing one (`LetterKeep.laneLine`'s own answer).
    static func provenance(voice: String, lane: String?) -> String {
        let base = "from \(voice)'s letter"
        let lane = (lane ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return lane.isEmpty ? base : "\(base) \u{00b7} \(lane)"
    }

    // MARK: - Writing

    /// File a habit as a live lesson. The heading IS the entry text — a lesson
    /// is a sentence the writer commits to, not a record with a title.
    ///
    /// `RulingPerformer.rule` is find-or-create, so the first Keep in a project
    /// mints the ledger statement; nothing has to check whether it is there.
    static func keepAsLesson(
        _ heading: String, provenance: String,
        store: ProjectStore, world: DeclaredWorldStore?
    ) async throws {
        try await RulingPerformer.rule(
            heading, provenance: provenance,
            kind: .lessons, forScope: .project, store: store, world: world)
    }

    /// File a habit as a settled choice — the negative space of a lesson (spec
    /// §6). The marker is `LessonsLedger.choiceText`'s and never a second
    /// spelling: the grammar that reads a row is what must recognise it.
    ///
    /// **The heading is checked here, and it has to be.** `RulingPerformer`
    /// refuses a ruling with nothing to say, but it sees the marked text — and
    /// `Choice: ` is not empty, so a blank heading would sail past that guard
    /// and file a row reading `Choice:` with nothing after it, which then
    /// briefs every round as something the writer decided. `keepAsLesson`
    /// needs no such check: its heading IS the ruling, so the performer's own
    /// refusal is exact.
    static func makeChoice(
        _ heading: String, provenance: String,
        store: ProjectStore, world: DeclaredWorldStore?
    ) async throws {
        guard !heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RulingFailure.emptyRuling }
        try await RulingPerformer.rule(
            LessonsLedger.choiceText(heading), provenance: provenance,
            kind: .lessons, forScope: .project, store: store, world: world)
    }

    /// **Every habit in the letter, as choices, in one act** — the seeding
    /// gesture §6 names: a Fresh Eyes read over a finished piece followed by
    /// *These are all choices* seeds the list in one press rather than six
    /// stets.
    ///
    /// **Sequential and stopping, not best-effort.** Each entry is its own op
    /// on one statement, so running them concurrently would be several writers
    /// on one document; and carrying on past a refusal would report a partial
    /// ledger as a whole one. The count of what landed rides on the error
    /// because the act is plural — a writer told only that it failed would not
    /// know whether pressing again duplicates what already went in.
    static func makeChoices(
        _ headings: [String], provenance: String,
        store: ProjectStore, world: DeclaredWorldStore?
    ) async throws {
        var landed = 0
        for heading in headings {
            do {
                try await makeChoice(
                    heading, provenance: provenance, store: store, world: world)
                landed += 1
            } catch {
                throw LessonLedgerFailure.someChoicesFiled(
                    landed: landed, of: headings.count,
                    reason: error.localizedDescription)
            }
        }
    }

    /// **Retire a lesson in place, dated** (spec §6).
    ///
    /// The row is located by HEADING against the file as it stands at the
    /// moment of the write, never by an id a caller remembered: a `Ruling.id`
    /// is a digest of its own text, so it goes stale the instant anything
    /// edits the line (`LessonsLedger`'s addressing note,
    /// `RulingsStratum`'s own rule).
    ///
    /// **A heading that is not an OPEN lesson refuses and writes nothing.**
    /// Never kept, already retired, or standing as a choice — all three are a
    /// press against a row the offer should not have drawn, and filing a
    /// second retirement over one of them would rewrite a line the writer did
    /// not aim at.
    static func retire(
        _ heading: String, on date: Date,
        store: ProjectStore, world: DeclaredWorldStore?
    ) async throws {
        let rows = RulingsStratum.currentRows(
            kind: .lessons, forScope: .project, store: store)
        guard let row = rows.first(where: { row in
            LessonsLedger.kind(of: row.text) == .lesson
                && LessonsLedger.matches(
                    heading, heading: LessonsLedger.heading(of: row.text))
        }) else {
            throw LessonLedgerFailure.notOpen(heading)
        }
        try await RulingPerformer.edit(
            rulingId: row.id,
            newText: LessonsLedger.retiredText(heading, on: date),
            kind: .lessons, forScope: .project, store: store, world: world)
    }

    // MARK: - Reading

    /// The ledger's markdown, or nil for a project whose writer has kept
    /// nothing yet.
    ///
    /// RULING-54: `statementText` throws on an unreadable file, and this is a
    /// fringe reader like `CompilerEnvironment`'s own `lessons` closure — an
    /// offer drawn over no ledger is the offer every project got before the
    /// first Keep, and the ledger pane's editor owns surfacing the refusal.
    static func ledgerText(store: ProjectStore) -> String? {
        guard let ledger = store.statement(kind: .lessons, scope: .project)
        else { return nil }
        return try? store.statementText(of: ledger)
    }
}

/// **Whether an offer stands — pure, and asked by the view** (editorial letter
/// P2 Task 6).
///
/// `LetterSection` holds no store, so every predicate here takes the ledger's
/// markdown as a value the host already read. They are separated from the verbs
/// above for the reason `TurnClauseOffer.isOffered` is separated from its
/// `handler`: what is offered is asserted directly, without a window and
/// without a project on disk.
enum LessonOffer {

    /// **What this letter says it did not find, narrowed to what the writer's
    /// ledger actually carries as a live lesson** — verbatim, and in the
    /// letter's own order.
    ///
    /// The intersection is the whole point (global constraint 15). A heading
    /// the model re-spelled, one the writer retired between the briefing and
    /// the read, and one that has since become a choice all name no live
    /// lesson — and an offer to retire any of them would be Maugham asking
    /// about a row that is not there.
    ///
    /// The strings returned are the LETTER's, not the file's, because
    /// `LessonsLedger.matches` forgives only whitespace and the two are
    /// otherwise the same words.
    static func retirable(_ letter: Letter, ledgerText: String?) -> [String] {
        guard let ledgerText else { return [] }
        let open = LessonsLedger.open(in: ledgerText)
        return letter.retiredHeadings.filter { candidate in
            open.contains { LessonsLedger.matches(candidate, heading: $0) }
        }
    }

    /// **The entry text a habit would be kept as.** The lesson the round drew
    /// out of the habit when it offered one, else the habit's own name.
    ///
    /// A ledger entry has no title and no body: the sentence IS the entry, so
    /// what goes in has to be the most useful sentence available. An empty
    /// `lesson` is read as absent rather than kept as the writer's commitment
    /// to nothing — `RulingPerformer.rule` would refuse it anyway, and
    /// refusing at the press with no explanation is worse than not offering.
    static func lessonHeading(for habit: Letter.Habit) -> String {
        let lesson = (habit.lesson ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lesson.isEmpty ? habit.name : lesson
    }

    /// Whether *Keep as lesson* stands for this habit.
    ///
    /// **False when the heading already stands anywhere in the ledger** — open,
    /// a choice, or retired. Each is a decision the writer already made about
    /// exactly this sentence, and a second Keep would file a duplicate row that
    /// then briefs every round twice. Retired counts for the same reason it is
    /// never deleted: the writer is done with it, and re-offering it is the
    /// coach forgetting.
    ///
    /// A habit with nothing to say answers false rather than offering a button
    /// that files an empty ruling.
    static func keepIsOffered(_ habit: Letter.Habit, ledgerText: String?) -> Bool {
        let heading = lessonHeading(for: habit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heading.isEmpty else { return false }
        guard let ledgerText else { return true }
        return !LessonsLedger.parse(ledgerText).entries.contains { entry in
            LessonsLedger.matches(heading, heading: entry.heading)
        }
    }

    /// Whether *These are all choices* stands.
    ///
    /// **Fresh Eyes only, and only over more than one habit.** The gesture is
    /// the one §6 names — a cold read of the whole piece, whose habits are
    /// therefore a claim about the piece rather than about a three-paragraph
    /// delta — and over a single habit it is *This is a choice* wearing a
    /// plural's clothes, where the writer already has that habit's own button.
    static func allChoicesIsOffered(_ letter: Letter, freshEyes: Bool) -> Bool {
        freshEyes && letter.habits.count >= 2
    }

    /// The same question asked of a run, for a caller that holds one. It
    /// delegates rather than restating the rule, so the view and the host
    /// cannot come to different answers about the same letter.
    static func allChoicesIsOffered(_ letter: Letter, run: CompilerRun?) -> Bool {
        allChoicesIsOffered(letter, freshEyes: run?.freshEyes == true)
    }
}
