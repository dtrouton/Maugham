import Foundation

/// **The writer's two questions about one paragraph** (translation pipeline
/// spec §9, §11 — P4 Task 6).
///
/// A round is seven legs over a whole document and it ends in a report. This is
/// the other tempo: the caret is in a paragraph, the author wants to know what
/// it now says (**Gloss**) or whether it still says what they wrote (**Ask the
/// collator**), and one keystroke gets one answer. Each is a single-turn,
/// tool-less `ColdCall` on the pipeline's own rails — the third and fourth of
/// the spec's four cold callers, beside the reader and the collator.
///
/// **Neither mints anything.** The answer is drawn and that is all it does: no
/// ruling, no annotation, no round. What the author does with it — *Keep mine*,
/// *Make it a rule* — is a separate verb they press in the pane, and those go
/// through the one ruling door like every other statement write. The distance
/// between the two is one plausible convenience and nothing in a signature
/// refuses it (this type is handed the same two stores a mint would be written
/// through), so `TripwireGrepTests.test_aSpotCheckMintsNothing` scans this file
/// for the doors by name instead — which is also why none of them is named
/// here.
///
/// **The gloss never sees the source.** `GlossBriefing.Inputs` has no field for
/// it, and what this type reads for one is the **badge entries the pane already
/// holds** — the translated surface on screen — rather than the disk. Ask the
/// collator is the opposite by design: it IS the collator, narrowed to one pair
/// and its neighbours, holding both texts because judging drift is what it is
/// for.
@MainActor
enum SpotCheck {

    /// One spot-check's end: the answer, or the refusal in its own words. Two
    /// cases rather than an optional-plus-message, so a surface cannot draw a
    /// blank result and a refusal at the same time.
    enum Outcome<T: Equatable>: Equatable {
        case answered(T)
        case refused(String)
    }

    // MARK: - Copy

    static let glossTitle = "Gloss"
    static let askTitle = "Ask the Collator"
    /// The small-caps label the gloss is drawn under.
    static let glossLabel = "gloss"

    static let busyRefusal =
        "A cold session is already out \u{2014} wait for the round\u{2019}s leg or "
        + "the last spot-check to come back."

    static let notWiredRefusal =
        "This window has no Claude session to ask \u{2014} open the project again, "
        + "or check Settings \u{2192} General \u{2192} Claude integration."

    static let noTranslationRefusal =
        "This paragraph has no current translation to check. A spot-check reads "
        + "what the edition says here, and there is nothing here yet."

    static func glossButtonLabel(paragraphId: String) -> String {
        "\(glossTitle), paragraph \(paragraphId)"
    }

    static func askButtonLabel(paragraphId: String) -> String {
        "\(askTitle), paragraph \(paragraphId)"
    }

    // MARK: - Reading the surface

    /// The paragraph and its two neighbours, off the **translated** entries the
    /// pane is already showing. Nil when the surface does not hold that id at
    /// all — which is the honest answer for a paragraph with no translation in
    /// this language, since a translated surface is what these entries are.
    static func neighbours(
        of paragraphId: String, in entries: [TranslationBadgeLayout.Entry]
    ) -> (before: String?, paragraph: String, after: String?)? {
        guard let index = entries.firstIndex(where: { $0.paragraphId == paragraphId })
        else { return nil }
        return (before: index > 0 ? entries[index - 1].text : nil,
                paragraph: entries[index].text,
                after: index < entries.count - 1 ? entries[index + 1].text : nil)
    }

    /// **The whole collator's briefing, cut down to one pair and its
    /// neighbours** — and cut down in the pairs ALONE. The author's own
    /// standards travel whole: craft intent, the edition brief, the glossary and
    /// every directive stay exactly as the round would have sent them, because a
    /// doctrine narrowed with the text is a spot-check judging the paragraph
    /// against rules the author never relaxed.
    ///
    /// `briefedParagraphIds` follows the pairs by construction, so the parse
    /// gate narrows with them: a departure about a paragraph this call did not
    /// show is refused by `CollatorReport.parse`, not by a caller remembering.
    static func narrow(
        _ inputs: CollatorBriefing.Inputs, to paragraphId: String
    ) -> CollatorBriefing.Inputs? {
        guard let index = inputs.pairs.firstIndex(where: { $0.paragraphId == paragraphId })
        else { return nil }
        let lower = max(0, index - 1)
        let upper = min(inputs.pairs.count - 1, index + 1)
        return CollatorBriefing.Inputs(
            collatorName: inputs.collatorName,
            language: inputs.language,
            authorLanguage: inputs.authorLanguage,
            roleBrief: inputs.roleBrief,
            craftIntentText: inputs.craftIntentText,
            editionBriefText: inputs.editionBriefText,
            glossary: inputs.glossary,
            pairs: Array(inputs.pairs[lower...upper]))
    }

    // MARK: - Gloss

    static func gloss(
        paragraphId: String, language: String,
        entries: [TranslationBadgeLayout.Entry],
        store: ProjectStore, documentStore: DocumentStore?, projectURL: URL,
        coldCall: ColdCall, model: String
    ) async -> Outcome<String> {
        guard let context = neighbours(of: paragraphId, in: entries),
              !context.paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .refused(noTranslationRefusal) }
        guard !coldCall.isRunning else { return .refused(busyRefusal) }

        let editionBrief = TranslatorOrchestrator.Environment.editionBriefText(
            language: language, store: store)
        let inputs = GlossBriefing.Inputs(
            language: TranslationPipeline.Environment.languageName(tag: language),
            authorLanguage: TranslationPipeline.Environment.authorLanguage(
                store: store, documentStore: documentStore, projectURL: projectURL),
            textureLine: GlossBriefing.textureLine(in: editionBrief),
            before: context.before, paragraph: context.paragraph, after: context.after)

        let event = await coldCall.call(
            message: GlossBriefing.compose(inputs: inputs),
            preamble: TranslationPipeline.coldPreamble, model: model)
        return read(event, parse: GlossReport.parse)
    }

    // MARK: - Ask the collator

    static func askTheCollator(
        paragraphId: String, docId: String, language: String,
        store: ProjectStore, documentStore: DocumentStore?, projectURL: URL,
        coldCall: ColdCall, model: String
    ) async -> Outcome<CollatorReport> {
        guard let whole = TranslationPipeline.Environment.collatorBriefing(
            docId: docId, language: language, store: store,
            documentStore: documentStore, projectURL: projectURL)
        else { return .refused(TranslationPipeline.unbriefableSentence(role: "collator")) }
        guard let narrowed = narrow(whole, to: paragraphId),
              narrowed.briefedParagraphIds.contains(paragraphId)
        else { return .refused(noTranslationRefusal) }
        guard !coldCall.isRunning else { return .refused(busyRefusal) }

        let briefed = narrowed.briefedParagraphIds
        let event = await coldCall.call(
            message: CollatorBriefing.compose(inputs: narrowed),
            preamble: TranslationPipeline.coldPreamble, model: model)
        return read(event) { CollatorReport.parse($0, briefedParagraphIds: briefed) }
    }

    // MARK: - Reading one turn

    /// **One switch over the turn**, both verbs, in `TranslationPipeline
    /// .coldLeg`'s own words: the round and the spot-check die through the same
    /// `CompilerRunFailure`, and a writer who sees one sentence in the desk and
    /// a differently-worded account of the same death in the pane learns to
    /// trust neither. `.started` is unusable output rather than a state to wait
    /// in: a cold call resolves on its result.
    private static func read<T: Equatable>(
        _ event: CompilerRunEvent, parse: (String) -> T?
    ) -> Outcome<T> {
        switch event {
        case .resultText(let text):
            guard let value = parse(text) else {
                return .refused(RoundNarrative.failureCopy(.unusableOutput,
                                                           session: .translation))
            }
            return .answered(value)
        case .failed(let failure):
            return .refused(RoundNarrative.failureCopy(failure, session: .translation))
        case .started:
            return .refused(RoundNarrative.failureCopy(.unusableOutput,
                                                       session: .translation))
        }
    }
}
