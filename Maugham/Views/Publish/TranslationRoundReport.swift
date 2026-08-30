import Foundation

/// **What the author reads after a pipeline round** (translation pipeline spec
/// §8, Plan 4 Task 3) — as rows and copy, so everything the surface could get
/// wrong is a pure function with no window in it.
///
/// `DesignGate`'s discipline one desk over, and for a sharper reason. A round is
/// seven legs of machine work over prose in a language the author may not read,
/// and the whole point of this surface is that they can still judge it: what
/// draws is **their own words, the collator's gloss, and the reader's report in
/// the author's language**. The translation itself is available only inside a
/// row the writer opens on purpose (spec §12). That rule is a property of what
/// these rows CARRY — a `DepartureRow` has a `source` and a `gloss` and no
/// translated text at all — which is why it lives here rather than in a
/// convention the next view to draw a round could quietly break.
enum TranslationRoundReport {

    // MARK: - Where your prose was changed

    /// One departure the collator raised, with what the translator did about it.
    ///
    /// `source` is the author's own paragraph as the document holds it NOW, and
    /// it is optional because a round outlives the prose it judged: a paragraph
    /// the writer has since deleted leaves a departure with nothing to quote.
    /// `before`/`after` are the translation, and they are the one place on this
    /// surface where target-language text appears — drawn only under a
    /// disclosure the writer opens.
    struct DepartureRow: Identifiable, Equatable {
        let id: String
        let paragraphId: String
        let source: String?
        let gloss: String
        let note: String
        let verdict: String
        let kind: String
        let outcomeLine: String?
        let before: String?
        let after: String?
        let isDismissed: Bool
    }

    /// The collator's verdict on a paragraph that moved away from the original.
    /// The one raw value this file compares against, because it decides whether
    /// an unanswered departure was work the fix leg never reached or a paragraph
    /// that was never work at all.
    static let driftedVerdict = "drifted"

    /// **Every departure the round recorded, in the record's own order.**
    ///
    /// `sources` is the live paragraph text by id, resolved once by the host —
    /// never read here, because a row is drawn on a body path and tripwire 4's
    /// rule is that a surface asks the disk nothing.
    static func departureRows(_ round: TranslationRound,
                              sources: [String: String],
                              translatorName: String = anonymousTranslator) -> [DepartureRow] {
        round.departures.map { departure in
            let rewrite = addressedRewrite(departure.outcome)
            // **Two facts, read from two places** (Task 4's fix round). The
            // translator's is `outcome`; the author's own "Fine" is `dismissed`.
            // The legacy `.dismissed` outcome is read as a dismissal too, so a
            // record written before the split still draws as one.
            let isDismissed = departure.dismissed == true || departure.outcome == .dismissed
            return DepartureRow(
                id: departure.id,
                paragraphId: departure.paragraphId,
                source: sources[departure.paragraphId],
                gloss: departure.gloss,
                note: departure.note,
                verdict: departure.verdict,
                kind: departure.kind,
                // **The translator's sentence wins where there is one** — a
                // dismissed row that was ALSO rewritten still says so, which is
                // the whole point of keeping the two facts apart. Where the
                // translator did nothing, the author's own "Fine" is what
                // happened to this row, and it outranks the fix leg's silence:
                // a `drifted` departure with no outcome is the fix leg never
                // reaching it, a `holds` one was never work for the translator,
                // and neither is news once the author has settled it.
                outcomeLine: outcomeLine(departure.outcome, translatorName: translatorName)
                    ?? (isDismissed ? dismissedLine
                        : (departure.verdict == driftedVerdict ? unreachedLine : nil)),
                before: rewrite?.before,
                after: rewrite?.after,
                isDismissed: isDismissed)
        }
    }

    /// What the translator did, in one sentence — or `nil` when they did
    /// nothing and nothing was asked of them.
    ///
    /// `translatorName` is defaulted rather than required so the rows and this
    /// static agree by construction when neither has a name in hand; the view
    /// passes the edition's real translator, and a caller comparing two
    /// outcomes needs neither.
    static func outcomeLine(_ outcome: TranslationRound.DepartureOutcome?,
                            translatorName: String = anonymousTranslator) -> String? {
        switch outcome {
        case .none:
            return nil
        case .addressed:
            return "\(translatorName) rewrote the paragraph."
        case .declined(let reason, _):
            return "\(translatorName) declined: \(reason)"
        case .dismissed:
            return dismissedLine
        }
    }

    private static func addressedRewrite(
        _ outcome: TranslationRound.DepartureOutcome?
    ) -> TranslationRound.Rewrite? {
        if case .addressed(let rewrite) = outcome { return rewrite }
        return nil
    }

    // MARK: - Disagreements

    /// A note or departure the translator declined — one row, whichever it was.
    ///
    /// **Two bylines, because there are two people in the disagreement**:
    /// `noteAuthor` is whoever raised it (the reader by name, the collator for a
    /// departure — a departure record carries no author of its own, so the
    /// caller supplies it) and `translatorName` is who turned it down.
    ///
    /// `annotationId` is the query the declined note minted, and it is optional:
    /// the pipeline mints one only where a declined note had somewhere to go
    /// (P3's declined-mint), so a row can exist with nothing to reject.
    struct DisagreementRow: Identifiable, Equatable {
        let id: String
        let paragraphId: String
        let text: String
        let reason: String
        let noteAuthor: String
        let translatorName: String
        let annotationId: String?
        /// "Reader's right" over a reader's note, "Collator's right" over a
        /// departure — the writer is siding with a named person, and the two
        /// are different people.
        let rightVerbTitle: String
    }

    static func disagreementRows(_ round: TranslationRound,
                                 translatorName: String,
                                 collatorName: String) -> [DisagreementRow] {
        round.disagreements.map { disagreement in
            DisagreementRow(
                id: disagreement.recordId,
                paragraphId: disagreement.paragraphId,
                text: disagreement.text,
                reason: disagreement.reason,
                noteAuthor: disagreement.author ?? collatorName,
                translatorName: translatorName,
                annotationId: disagreement.annotationId,
                rightVerbTitle: {
                    if case .departure = disagreement { return collatorsRightTitle }
                    return readersRightTitle
                }())
        }
    }

    // MARK: - Glossary proposals

    /// A term the round proposes fixing for the rest of the book. `id` is the
    /// index into `round.glossaryProposals`, because that is what a verb files
    /// against — the records carry no id of their own.
    struct ProposalRow: Identifiable {
        let id: Int
        let term: String
        let rendering: String
        let reason: String
        let adopted: Bool
        let skipped: Bool
    }

    static func proposalRows(_ round: TranslationRound) -> [ProposalRow] {
        round.glossaryProposals.enumerated().map { index, proposal in
            ProposalRow(id: index, term: proposal.term, rendering: proposal.rendering,
                        reason: proposal.reason, adopted: proposal.adopted,
                        skipped: proposal.skipped == true)
        }
    }

    // MARK: - The reader's report

    /// One of the two reader columns: which read it was, its verdict in words,
    /// and what the reader wrote.
    ///
    /// `legRecord` is the round's own record for this leg, and it is what lets a
    /// missing report say something true — see `missingReaderText`.
    static func readerColumn(_ record: TranslationRound.ReaderReportRecord?,
                             leg: TranslationRound.Leg,
                             legRecord: TranslationRound.LegRecord? = nil)
    -> (title: String, verdict: String, text: String) {
        (title: leg == .read ? firstReadTitle : secondReadTitle,
         verdict: record.map { verdictLabel($0.verdict) } ?? emDash,
         text: record?.text ?? missingReaderText(leg: leg, legRecord: legRecord))
    }

    /// **What stands in a reader column with no report — and it is never the
    /// OTHER column's news.**
    ///
    /// A skipped second read is good news (the first found nothing to fix); a
    /// skipped first read is the opposite. One sentence for both was a column
    /// that could tell the writer their round went well when it had stopped
    /// before it began, which is the failure this function exists to make
    /// impossible: the leg decides which silence this is. A leg that failed or
    /// was cancelled prefers its own recorded sentence (`LegRecord.reason`) to
    /// anything written here.
    static func missingReaderText(leg: TranslationRound.Leg,
                                  legRecord: TranslationRound.LegRecord?) -> String {
        // No record at all: the round never reached this leg to record one.
        guard let legRecord else { return roundStoppedLine(before: leg) }
        switch legRecord.status {
        case .ran:
            // It ran and wrote nothing. Not news, and nothing to explain.
            return emDash
        case .skipped:
            return leg == .reread ? nothingChangedLine : firstReadSkippedLine
        case .failed, .cancelled:
            let reason = legRecord.reason?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return reason.isEmpty ? roundStoppedLine(before: leg) : reason
        }
    }

    /// The round's own record for a leg — `readerColumn`'s `legRecord`, asked
    /// here so the view carries no rule of its own.
    static func legRecord(_ round: TranslationRound,
                          _ leg: TranslationRound.Leg) -> TranslationRound.LegRecord? {
        round.legs.first { $0.leg == leg }
    }

    /// A reader's or collator's raw verdict, humanised: `reads_as_native` →
    /// "Reads as native". Generic over the vocabulary rather than a table,
    /// because the readers' verdict strings are the pipeline's and a table here
    /// would be a second, staler copy of them.
    static func verdictLabel(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ")
        guard let first = words.first else { return emDash }
        return first.uppercased() + words.dropFirst()
    }

    // MARK: - The header and the summary

    /// "Round 3 · Chapter 2 · Spanish" — and without the chapter when the
    /// document is no longer in the manifest, rather than a gap between two
    /// separators.
    static func header(_ round: TranslationRound, chapterTitle: String?) -> String {
        ["Round \(round.number)", chapterTitle,
         TranslationReviewIndicator.displayLabel(forLanguageTag: round.language)]
            .compactMap { $0 }
            .joined(separator: " \u{00b7} ")
    }

    /// What the round came to, in figures: "2 notes · 3 departures · 2 declined".
    static func countsLine(_ round: TranslationRound) -> String {
        [count(round.notes.count, "note"),
         count(round.departures.count, "departure"),
         "\(round.declinedCount) declined"]
            .joined(separator: " \u{00b7} ")
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// **Where a ruling this surface writes says it came from** — "round 3, keep
    /// mine". The verbs that mint one are Task 4's; the sentence is here because
    /// it is copy, and because a provenance line spelled at the wiring site is
    /// one no test can read.
    static func provenance(round: TranslationRound, verb: String) -> String {
        "round \(round.number), \(verb)"
    }

    // MARK: - Copy

    static let emDash = "\u{2014}"

    /// The subject of an outcome line with no name in hand.
    static let anonymousTranslator = "The translator"

    static let readerHeading = "The reader\u{2019}s report"
    static let changedHeading = "Where your prose was changed"
    static let disagreementsHeading = "Disagreements"
    static let questionsHeading = "Questions for you"
    static let proposalsHeading = "Glossary proposals"
    static let summaryHeading = "Summary"

    static let firstReadTitle = "First read"
    static let secondReadTitle = "Second read"
    static let collatorHeading = "The collator"

    static let fineTitle = "Fine"
    static let keepMineTitle = "Keep mine"
    static let makeRuleTitle = "Make it a rule"
    static let translatorsRightTitle = "Translator\u{2019}s right"
    static let readersRightTitle = "Reader\u{2019}s right"
    static let collatorsRightTitle = "Collator\u{2019}s right"
    static let adoptTitle = "Adopt"
    static let skipTitle = "Skip"
    static let answerTitle = "Answer"
    static let answerAsRulingTitle = "Answer as ruling\u{2026}"
    static let openQueueTitle = "Open the queue"
    static let closeTitle = "Back to the book"

    /// Distinct from the visible title for the reason every control on this
    /// department's surfaces carries one (`DesignGate.Verb.accessibilityLabel`):
    /// the visible words are told apart by where they sit, which a linear
    /// accessibility tree does not carry.
    static let closeAccessibilityLabel = "Back to the book"

    static let adoptedLine = "Adopted"
    static let skippedLine = "Skipped"

    static let dismissedLine = "You said this was fine."

    // MARK: - What a verb answers with (Task 4)

    // Every verb answers in a sentence whichever way it goes (Global
    // Constraint 2), so the copy for the DOING half lives here beside the copy
    // for the reading half — a sentence spelled at the wiring site is one no
    // test can read, which is the same argument `provenance` above is here for.

    /// **The row the verb was aimed at is not in the round any more.** A round
    /// travels as a VALUE and the writer may be looking at one the ring has
    /// since rewritten; acting on an index or an id that is no longer there
    /// would write a record this surface invented.
    static let rowGone =
        "That row is no longer part of this round \u{2014} reopen the round to "
        + "see what it holds now."

    /// **Both destinations, after the click** — `TranslatorsNoteCopy.confirmation`'s
    /// pair, past tense, because the writer chose the home in the sheet and the
    /// confirmation has to say which one it actually reached.
    static func keptLine(home: TranslatorsNote.Home) -> String {
        switch home {
        case .everyEdition:
            return "Kept \u{2014} your instruction is a dated ruling in this "
                + "piece\u{2019}s craft intent, briefed to every edition."
        case .edition(let language):
            return "Kept \u{2014} your instruction is a dated ruling in the "
                + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
                + " edition brief."
        }
    }

    /// "Make it a rule" — always the edition's own brief, never the book's
    /// intent, which is why this sentence names the edition and `keptLine`'s
    /// does not always.
    static func ruledLine(language: String) -> String {
        "Ruled \u{2014} it is doctrine for the "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " edition from the next round on."
    }

    static let translatorsRightLine =
        "You sided with the translator. The question is settled and your prose "
        + "stands as translated."

    static let readersRightLine =
        "You sided with the note. It is a dated directive on that paragraph "
        + "from the next round on."

    static let answeredLine = "Your reply is on the question."

    /// **An empty reply settles a question with nothing in it.** Both sheets
    /// disable their confirm button on empty text, so this is unreachable from
    /// the surface as it stands — which is exactly why it is a refusal rather
    /// than a trust: the verb, not the sheet, is what makes it impossible.
    static let emptyReply =
        "A reply needs words \u{2014} the translator is waiting on an answer, "
        + "and an empty one closes the question without giving them any."

    /// **A glossary proposal with an empty half is not a glossary entry.**
    /// Adopting one would write `«» → «niebla»` into the doctrine every later
    /// round is checked against, and no reader of that line could tell what it
    /// was ever about.
    static let emptyGlossaryTerm =
        "This proposal is missing its term or its rendering, so there is "
        + "nothing to fix for the rest of the book."

    /// **A failure BETWEEN two writes says what did land** (`QueryRuling.commit`'s
    /// rule, and for its reason): a writer told only "that didn't work" answers
    /// again and mints a second ruling for the decision already in the brief.
    static func ruledButNoReply(reason: String) -> String {
        "Your directive is in the edition brief, but the reply could not be "
            + "posted on the question: \(reason) The question is still open "
            + "\u{2014} answer it without ruling again."
    }

    /// The same shape one verb over: the term is doctrine, and only the round's
    /// own record — which is derived — failed to say so.
    static func adoptedButNotRecorded(term: String, reason: String) -> String {
        "\u{201C}\(term)\u{201D} is fixed for the rest of the book, but this "
            + "round\u{2019}s record could not be marked: \(reason)"
    }

    /// A `drifted` departure the fix leg never reached — the round stopped, or
    /// the paragraph lost its translation in between.
    static let unreachedLine = "The fix leg never reached this paragraph."

    static let nothingChangedLine =
        "The second read was skipped \u{2014} nothing changed after the first."

    /// The opposite news, in its own words: nothing reached the reader at all.
    static let firstReadSkippedLine =
        "The first read was skipped \u{2014} nothing was translated to read."

    /// A leg the round failed or cancelled before finishing, with no sentence of
    /// its own recorded.
    static func roundStoppedLine(before leg: TranslationRound.Leg) -> String {
        "The round stopped before the \(leg == .read ? "first" : "second") read."
    }

    static let sourceMissingLine =
        "This paragraph is no longer in the document."

    static let noDisagreementsLine =
        "The translator did everything the reader and the collator asked."

    static let noQuestionsLine =
        "No open questions from this edition."

    static let noProposalsLine =
        "This round proposed no glossary terms."

    static let nothingChangedInProseLine =
        "Nothing in your prose was flagged this round."

    /// The standing refusal for a surface that has been handed no wiring —
    /// `DesignGate.notWired`'s shape, and the default every action carries so a
    /// press can never be a silent no-op (Global Constraint 2).
    static let notWired = "This window isn\u{2019}t ready to act on a round yet."

    /// **The verb named here is the row's own**, never a fixed spelling: a
    /// declined DEPARTURE offers Collator's right and a declined NOTE offers
    /// Reader's right, so a sentence that named one of them over both told half
    /// the rows about a button they do not have.
    static func noQueryForThisNote(rightVerb: String) -> String {
        "No query was minted for this note, so there is nothing to reject "
            + "\u{2014} \(rightVerb) and \(makeRuleTitle) still apply."
    }

    /// **The questions could not be read**, which is not the same fact as there
    /// being none (RULING-7: unreadable is never presented as empty). The
    /// failure's own sentence rides along, because a writer can act on "the file
    /// is locked" and cannot act on "something went wrong".
    static func questionsUnreadable(reason: String) -> String {
        "The translator\u{2019}s questions for this round can\u{2019}t be read: "
            + reason
    }

    // MARK: - Per-row accessibility labels

    /// Every verb on this surface is drawn once per row, so its visible title
    /// says nothing about WHICH row a linear tree is standing in. Each label
    /// therefore names its own subject — and the two sections that both offer
    /// "Make it a rule" name theirs differently, because a departure and the
    /// disagreement it became share an id.

    static func fineLabel(id: String) -> String { "\(fineTitle), change \(id)" }

    static func keepMineLabel(id: String) -> String { "\(keepMineTitle), change \(id)" }

    static func makeRuleLabel(id: String) -> String { "\(makeRuleTitle), change \(id)" }

    static func makeRuleLabel(disagreement id: String) -> String {
        "\(makeRuleTitle), disagreement \(id)"
    }

    static func translatorsRightLabel(id: String) -> String {
        "\(translatorsRightTitle), disagreement \(id)"
    }

    static func rightLabel(id: String, verb: String) -> String {
        "\(verb), disagreement \(id)"
    }

    static func adoptLabel(index: Int) -> String {
        "\(adoptTitle) glossary proposal \(index + 1)"
    }

    static func skipLabel(index: Int) -> String {
        "\(skipTitle) glossary proposal \(index + 1)"
    }

    static func answerLabel(id: String) -> String { "\(answerTitle), question \(id)" }

    static func answerAsRulingLabel(id: String) -> String {
        "\(answerAsRulingTitle), question \(id)"
    }

    /// Follows the disclosure's own state, because a label still saying "Show"
    /// over a control that now hides is the one thing a screen reader has no way
    /// to see past.
    static func expandLabel(id: String, expanded: Bool) -> String {
        expanded
            ? "Hide the translation of change \(id)"
            : "Show the translation of change \(id)"
    }

    static func revealAccessibilityLabel(paragraphId: String) -> String {
        "Show paragraph \(paragraphId) in the manuscript"
    }
}
