import Foundation
import MaughamCore

/// Assembles what one translator run sends to the spawned Claude: the role
/// frame, the writer's standing doctrine (craft intent + edition brief, with
/// its `## Rulings` intact — the rulings ARE the doctrine), this round's
/// work-list, neighbor context for continuity, the writer's queries, and the
/// report contract from `TranslatorReport`.
///
/// A pure function of its inputs — no I/O, no clock, no store lookup — mirrors
/// `CompilerPrompt`'s discipline exactly, for the same reason: a prompt
/// assembled this way is testable without a subprocess or a project on disk.
/// `TranslatorOrchestrator` (Task 4) is the one production caller and owns
/// gathering `Inputs` from the store, the deriver and the annotation layer;
/// this type does not know any of those exist.
enum TranslatorBriefing {

    // MARK: - Inputs

    /// Everything one briefing needs, already resolved by the caller. Every
    /// field here has a reader in `compose` — `CompilerAnnotationDisposition`'s
    /// discipline: small on purpose, nothing carried that has nowhere to go.
    struct Inputs: Equatable {

        /// One paragraph this round asks the translator to handle.
        struct WorkItem: Equatable {
            let paragraphId: String
            let sourceText: String
            let status: TranslationStatus
            /// The prior translation, when there is one to reconsider — a
            /// stale entry's own last answer. `nil` for `.missing` (nothing
            /// exists yet) and for `.fresh` (this type does not forbid a
            /// caller from listing one, but there is nothing to hand over).
            let priorTranslation: String?

            init(
                paragraphId: String, sourceText: String, status: TranslationStatus,
                priorTranslation: String? = nil
            ) {
                self.paragraphId = paragraphId
                self.sourceText = sourceText
                self.status = status
                self.priorTranslation = priorTranslation
            }
        }

        /// A paragraph immediately before or after a work item — read for
        /// continuity, never translated on its own.
        struct ContextParagraph: Equatable {
            let paragraphId: String
            let text: String

            init(paragraphId: String, text: String) {
                self.paragraphId = paragraphId
                self.text = text
            }
        }

        /// A question the translator raised that the writer has not answered
        /// yet.
        struct OpenQuery: Equatable {
            let paragraphId: String?
            let text: String

            init(paragraphId: String? = nil, text: String) {
                self.paragraphId = paragraphId
                self.text = text
            }
        }

        /// A question the writer has already answered — carried so the
        /// translator does not ask it again.
        struct AnsweredQuery: Equatable {
            let paragraphId: String?
            let text: String
            let answer: String

            init(paragraphId: String? = nil, text: String, answer: String) {
                self.paragraphId = paragraphId
                self.text = text
                self.answer = answer
            }
        }

        let translatorName: String
        let language: String
        /// `ProductionRole.effectiveBrief` for this translator, when the
        /// writer (or a preset) has one — `nil` is a real state (an unbriefed
        /// translator has none, per `ProductionRole`'s own doc) and `compose`
        /// simply omits the sentence rather than inventing a fallback.
        let roleBrief: String?
        let craftIntentText: String?
        /// The edition brief's markdown, verbatim — `read_edition_brief`'s own
        /// text, `## Rulings` and all. `nil` when the writer has not declared
        /// one for this language yet (a valid, deliberate state, not an
        /// error — `ReadEditionBriefTool`'s own doc).
        let editionBriefText: String?
        let workList: [WorkItem]
        let contextParagraphs: [ContextParagraph]
        let openQueries: [OpenQuery]
        let answeredQueries: [AnsweredQuery]
        /// What the manuscript has already established about the people and
        /// places this round's work names — `BibleStore.slice(matching:)` over
        /// the work-list's prose, the same ledger and the same rule the
        /// compiler's own briefing slices with.
        ///
        /// **A translator needs these more sharply than a reader does.**
        /// English lets a sentence stay silent about a doctor's gender; most
        /// of the languages this loop translates into do not, so a fact the
        /// compiler recorded ("October's doctor is a woman") is the difference
        /// between `la doctora` and an edition-wide error the writer has to
        /// catch by reading. Empty is the ordinary early state — a project
        /// whose compiler has never run has established nothing yet — and
        /// `compose` omits the section rather than announcing an empty ledger.
        let bibleFacts: [BibleFact]

        init(
            translatorName: String, language: String, roleBrief: String? = nil,
            craftIntentText: String? = nil, editionBriefText: String? = nil,
            workList: [WorkItem] = [], contextParagraphs: [ContextParagraph] = [],
            openQueries: [OpenQuery] = [], answeredQueries: [AnsweredQuery] = [],
            bibleFacts: [BibleFact] = []
        ) {
            self.translatorName = translatorName
            self.language = language
            self.roleBrief = roleBrief
            self.craftIntentText = craftIntentText
            self.editionBriefText = editionBriefText
            self.workList = workList
            self.contextParagraphs = contextParagraphs
            self.openQueries = openQueries
            self.answeredQueries = answeredQueries
            self.bibleFacts = bibleFacts
        }
    }

    // MARK: - Cap discipline

    /// How many answered queries a briefing lists, mirroring
    /// `CompilerPrompt.settledDispositionLimit`'s asymmetry: an open query is
    /// what blocks the writer right now and is never truncated, while
    /// answered ones accumulate for the life of the edition and would
    /// eventually be most of the prompt. Own value — the shape is borrowed,
    /// not the constant.
    static let answeredQueryLimit = 12

    /// How much of an answer's own prose a briefing line carries — the same
    /// job `CompilerPrompt.dispositionExcerptLimit` does for a disposition's
    /// reason, and the same reasoning: a writer's answer is free text and can
    /// run to a paragraph.
    static let answerExcerptLimit = 160

    // MARK: - Compose

    /// Assemble one briefing message. Section order: role frame, declared
    /// intent, edition brief, established facts, this round's work, neighbor
    /// context, queries, the report contract — the frame everything else is
    /// read through comes first, the output-shape instruction comes last,
    /// `CompilerPrompt`'s own ordering rule.
    static func compose(inputs: Inputs) -> String {
        var sections: [String] = [roleFrame(inputs)]

        if let intent = inputs.craftIntentText, !intent.isEmpty {
            sections.append("Declared intent:\n\(cleaned(intent))")
        }
        if let brief = inputs.editionBriefText, !brief.isEmpty {
            sections.append(
                "Edition brief for \(inputs.language) — the writer's doctrine for "
                    + "this edition, including any rulings settled in earlier "
                    + "sessions. Honor a standing ruling exactly as it reads; it is "
                    + "the writer's own settled answer, not a suggestion:\n"
                    + cleaned(brief))
        }
        if let bible = bibleSection(inputs.bibleFacts) {
            sections.append(bible)
        }

        sections.append(workListSection(inputs.workList))
        if let context = contextSection(inputs) {
            sections.append(context)
        }
        if let queries = queriesSection(inputs) {
            sections.append(queries)
        }

        sections.append(TranslatorReport.schemaDescription)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Role frame

    /// Who is reading, and what they are for — `CompilerPrompt.passSection`'s
    /// shape. Unlike a review pass, there is no briefless fallback sentence:
    /// an unbriefed translator genuinely has no doctrine of their own
    /// (`ProductionRole.effectiveBrief`'s own doc), and inventing one here
    /// would be a register the writer never chose.
    private static func roleFrame(_ inputs: Inputs) -> String {
        var lines = [
            "You are \(inputs.translatorName), translating this manuscript into "
                + "\(inputs.language). You translate; you never see your words "
                + "written back — Maugham ingests."
        ]
        if let brief = inputs.roleBrief, !brief.isEmpty {
            lines.append(cleaned(brief))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Established facts

    /// What the manuscript has established about the people and places this
    /// round names — `CompilerPrompt.bibleSection`'s `subject: fact` line
    /// shape, under a heading that says what a translator is supposed to DO
    /// with it. The compiler is told these so it can notice a contradiction;
    /// a translator is told them so a grammatical choice English never forced
    /// comes out right, which is a different instruction and is spelled out
    /// rather than left to be inferred from a bare list.
    ///
    /// `nil` for an empty slice: a project whose compiler has never run has
    /// established nothing, and announcing an empty ledger would read as "we
    /// know nothing about these people", which is not the same claim.
    private static func bibleSection(_ facts: [BibleFact]) -> String? {
        guard !facts.isEmpty else { return nil }
        var lines = [
            "Established so far — what the manuscript has already settled about "
                + "the people and places in this round's work (genders, names, "
                + "ages, relationships). Honor them in grammatical choices the "
                + "source language never had to make; where a fact and the "
                + "source disagree, raise a query rather than pick a side:"
        ]
        for fact in facts {
            lines.append("- \(fact.subject): \(cleaned(fact.fact))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Work list

    private static func workListSection(_ items: [Inputs.WorkItem]) -> String {
        guard !items.isEmpty else {
            return "This round's work: nothing needs translation right now."
        }
        var lines = [
            "This round's work — for each paragraph below, answer with an "
                + "entry: a full translation, or \"verbatim\" if it should carry "
                + "over unchanged:"
        ]
        for item in items {
            lines.append(contentsOf: workItemLines(item))
        }
        return lines.joined(separator: "\n")
    }

    private static func workItemLines(_ item: Inputs.WorkItem) -> [String] {
        switch item.status {
        case .missing:
            return [
                "[\(item.paragraphId)] (missing — no translation yet)",
                cleaned(item.sourceText),
            ]
        case .stale:
            var lines = [
                "[\(item.paragraphId)] (stale — the source has changed since this "
                    + "was last translated)",
                "Source: \(cleaned(item.sourceText))",
            ]
            if let prior = item.priorTranslation {
                lines.append("Prior translation: \(cleaned(prior))")
            }
            return lines
        case .fresh:
            // Not the ordinary case — a fresh entry needs no work — but this
            // type does not forbid a caller from listing one, so render it
            // plainly rather than silently dropping what the caller asked
            // for.
            return ["[\(item.paragraphId)]", cleaned(item.sourceText)]
        }
    }

    // MARK: - Neighbor context

    /// The paragraph before/after each work item, deduped against the
    /// work-list itself and against repeats of its own (one paragraph can be
    /// the neighbor of two work items), and marked as context rather than
    /// work.
    private static func contextSection(_ inputs: Inputs) -> String? {
        var seen = Set(inputs.workList.map(\.paragraphId))
        var deduped: [Inputs.ContextParagraph] = []
        for paragraph in inputs.contextParagraphs {
            guard !seen.contains(paragraph.paragraphId) else { continue }
            seen.insert(paragraph.paragraphId)
            deduped.append(paragraph)
        }
        guard !deduped.isEmpty else { return nil }

        var lines = [
            "Context — the paragraph immediately before or after a work item "
                + "above, for continuity only. These are not this round's work; "
                + "do not include them in \"entries\":"
        ]
        for paragraph in deduped {
            lines.append("[\(paragraph.paragraphId)] (context)")
            lines.append(cleaned(paragraph.text))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Queries

    private static func queriesSection(_ inputs: Inputs) -> String? {
        guard !inputs.openQueries.isEmpty || !inputs.answeredQueries.isEmpty else {
            return nil
        }
        var lines: [String] = ["Queries from earlier rounds."]
        if !inputs.openQueries.isEmpty {
            lines.append("")
            lines.append(
                "Open \u{2014} the writer has not answered these yet. Do not raise "
                    + "the same question again:")
            lines.append(
                contentsOf: inputs.openQueries.map { queryLine(paragraphId: $0.paragraphId, text: $0.text) })
        }
        if !inputs.answeredQueries.isEmpty {
            lines.append("")
            lines.append(
                "Answered \u{2014} the writer's own words. Do not ask these again:")
            lines.append(
                contentsOf: inputs.answeredQueries.prefix(answeredQueryLimit).map(answeredQueryLine(_:)))
            let elided = inputs.answeredQueries.count - answeredQueryLimit
            if elided > 0 {
                lines.append("- \u{2026}and \(elided) more the writer has already answered.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func queryLine(paragraphId: String?, text: String) -> String {
        "- \(queryLocation(paragraphId)) \(cleaned(text))"
    }

    private static func answeredQueryLine(_ query: Inputs.AnsweredQuery) -> String {
        "- \(queryLocation(query.paragraphId)) \(cleaned(query.text)) "
            + "\u{2192} \(shortened(cleaned(query.answer)))"
    }

    private static func queryLocation(_ paragraphId: String?) -> String {
        guard let paragraphId else { return "(whole document)" }
        return "[\(paragraphId)]"
    }

    /// Enough of the writer's answer to recognise it by —
    /// `CompilerPrompt.shortened`'s job and reasoning, mirrored: an answer is
    /// free text, can carry newlines, and either would break a bullet list
    /// into what reads as several queries.
    private static func shortened(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard collapsed.count > answerExcerptLimit else { return collapsed }
        return collapsed.prefix(answerExcerptLimit) + "\u{2026}"
    }

    // MARK: - Anchor hygiene

    /// Defense in depth, `CompilerPrompt.cleaned`'s own reasoning: nothing
    /// embedded in a prompt should ever leak a `¶id` anchor, even though the
    /// caller's inputs are expected to already be clean display text.
    private static func cleaned(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
    }
}
