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
            return DepartureRow(
                id: departure.id,
                paragraphId: departure.paragraphId,
                source: sources[departure.paragraphId],
                gloss: departure.gloss,
                note: departure.note,
                verdict: departure.verdict,
                kind: departure.kind,
                // A `drifted` departure with no outcome at all is the fix leg
                // never reaching it — skipped, failed, cancelled. A `holds` one
                // was never work for the translator, so there is nothing to say.
                outcomeLine: outcomeLine(departure.outcome, translatorName: translatorName)
                    ?? (departure.verdict == driftedVerdict ? unreachedLine : nil),
                before: rewrite?.before,
                after: rewrite?.after,
                isDismissed: departure.outcome == .dismissed)
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
    /// `skipped` is the leg's own status, and it is the difference between two
    /// silences: a second read that never ran because the first found nothing to
    /// fix (`nothingChangedLine`, which is good news) and a column with no
    /// record for any other reason (an em-dash, which is not news at all).
    static func readerColumn(_ record: TranslationRound.ReaderReportRecord?,
                             leg: TranslationRound.Leg,
                             skipped: Bool = false)
    -> (title: String, verdict: String, text: String) {
        (title: leg == .read ? firstReadTitle : secondReadTitle,
         verdict: record.map { verdictLabel($0.verdict) } ?? emDash,
         text: record?.text ?? (skipped ? nothingChangedLine : emDash))
    }

    /// Whether the round recorded this leg as skipped — `readerColumn`'s
    /// `skipped`, asked here so the view carries no rule of its own.
    static func legWasSkipped(_ round: TranslationRound,
                              _ leg: TranslationRound.Leg) -> Bool {
        round.legs.contains { $0.leg == leg && $0.status == .skipped }
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

    /// A `drifted` departure the fix leg never reached — the round stopped, or
    /// the paragraph lost its translation in between.
    static let unreachedLine = "The fix leg never reached this paragraph."

    static let nothingChangedLine =
        "The second read was skipped \u{2014} nothing changed after the first."

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

    static let noQueryForThisNote =
        "No query was minted for this note, so there is nothing to reject "
        + "\u{2014} Reader\u{2019}s right and Make it a rule still apply."

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

    static func expandLabel(id: String) -> String {
        "Show the translation of change \(id)"
    }

    static func revealAccessibilityLabel(paragraphId: String) -> String {
        "Show paragraph \(paragraphId) in the manuscript"
    }
}
