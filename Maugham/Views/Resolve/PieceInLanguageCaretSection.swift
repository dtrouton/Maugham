import SwiftUI
import MaughamCore

/// **The caret's paragraph, in a piece read in a language** (shell p4 Task
/// 9; moved here from the translation review pane, which this task deletes):
/// its freshness, its source where the centre does not draw it under the
/// paragraph, the two spot-checks — what does it now say (Gloss), and does it
/// still say what I wrote (Ask the Collator) — with the author's verbs on a
/// collator's departure, and a table's cells when the paragraph is a table's
/// line.
///
/// Mounted by `PieceInLanguageHeadView` on the open piece only. It reads
/// `Document.cursorLocation` itself — a source caret, which the translated
/// surface keeps on the paragraph it shows (`EditorCoordinator.sourceLocation(forSurface:)`, shell
/// p4 Task 8) — so a caret move re-renders this section and nothing else.
@MainActor
struct PieceInLanguageCaretSection: View {
    @Bindable var document: Document
    let control: EditorControl
    let language: String
    let store: ProjectStore
    let documentStore: DocumentStore
    /// The compiler's model setting: one setting, every spawner.
    let model: String
    /// The craft-intent cache a Keep mine to every edition invalidates.
    let world: DeclaredWorldStore?

    @Environment(AgentRoster.self) private var roster: AgentRoster?

    /// The last gloss and collation, for the paragraph under the caret — held
    /// as `Outcome`s, so a refusal is a state this section can draw.
    @State private var gloss: SpotCheck.Outcome<String>?
    @State private var collation: SpotCheck.Outcome<CollatorReport>?
    @State private var spotChecking = false
    /// Departures the author said are fine. Transient on purpose: a spot-check
    /// is not a round, there is no record to write the disposition into, and
    /// the answer is gone the moment the caret moves.
    @State private var dismissedDepartures: Set<String> = []
    /// Departures whose Keep mine or Make it a rule has run: both file a
    /// dated note or ruling that never dedupes, so the row draws its outcome.
    @State private var settledDepartures: Set<String> = []
    @State private var sheet: Sheet?
    @State private var notice: String?

    private var entries: [TranslationBadgeLayout.Entry] { control.translationBadges.entries }

    /// The caret's paragraph — the source walk over a source caret.
    private var selected: TranslationBadgeLayout.Entry? {
        guard let id = document.paragraphId(at: document.cursorLocation) else { return nil }
        return entries.first { $0.paragraphId == id }
    }

    /// The author's verbs on a departure, from the window's posture door —
    /// the round report's own decision.
    private var authorVerbs: TranslationAuthorVerbs {
        TranslationAuthorVerbs.decide(
            document: documentStore.posture(forDocId: document.docId),
            editionBrief: documentStore.posture(
                ofStatement: .editionBrief(language), scope: .project,
                statements: store.manifest.statements),
            pieceIntent: documentStore.posture(
                ofStatement: .intent, scope: .document(document.docId),
                statements: store.manifest.statements))
    }

    /// The table figure the caret's paragraph is the line of, else nil
    /// (`TranslationCellRows.tableFigure`, Publish's rule).
    private var figureUnderCaret: FigureRecord? {
        guard let selected, let text = document.paragraphs[selected.paragraphId],
              let path = TreeWalk.find(id: document.docId, in: store.manifest.structure)?.path
        else { return nil }
        return TranslationCellRows.tableFigure(
            inParagraph: text, documentPath: path, records: store.manifest.figures ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let selected {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.heading)
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    TranslationStatusChip(status: selected.status)
                }
                // The source, where the centre does not draw it under the
                // paragraph (source-under turned off).
                if !control.showsSourceUnder, let source = document.paragraph(id: selected.paragraphId),
                   !source.isEmpty {
                    Text(RenderFilter.stripTaskAnchorsInline(source))
                        .font(.system(.callout, design: .serif))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                spotChecks(selected.paragraphId)
                if let figure = figureUnderCaret {
                    TranslationCellsSection(
                        figure: figure, language: language, documentStore: documentStore,
                        projectURL: store.url, cardVersion: control.figureCardVersion)
                }
            } else {
                // No translated surface at all is not a caret the writer can
                // move (fix round 1, M4): say what is missing.
                Text(entries.isEmpty ? Self.noSurfaceLine : Self.placeCaretLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // An answer belongs to the paragraph it was asked about: a gloss left
        // standing while the caret moves is the wrong prose under the right
        // heading, in a language the author may not read.
        .onChange(of: selected?.paragraphId) { _, _ in clear() }
        .sheet(item: $sheet) { sheetBody($0) }
    }

    static let heading = "This paragraph"
    static let placeCaretLine = "Put the caret in a paragraph to spot-check it."
    static let noSurfaceLine =
        "Spot-checks need this translation on screen, and it is not: see the line above the text."
    static let glossHelp = "Ask what this paragraph now says, rendered back into your own language."
    static let askHelp = "Ask the collator whether this paragraph still says what you wrote."

    /// **Does this answer still belong on screen?** A spot-check takes
    /// seconds; the caret can move while it is out, and the answer that
    /// resolves afterwards must not land under the wrong paragraph. Pure.
    static func answerStillBelongs(askedAbout paragraphId: String, selected: String?) -> Bool {
        paragraphId == selected
    }

    // MARK: The spot-checks

    @ViewBuilder
    private func spotChecks(_ paragraphId: String) -> some View {
        FlowLayout(spacing: 6) {
            Button(SpotCheck.glossTitle) { runGloss(paragraphId) }
                .controlSize(.small).fixedSize()
                .disabled(busy)
                .help(busy ? SpotCheck.busyRefusal : Self.glossHelp)
                .accessibilityLabel(SpotCheck.glossButtonLabel(paragraphId: paragraphId))
            Button(SpotCheck.askTitle) { runAsk(paragraphId) }
                .controlSize(.small).fixedSize()
                .disabled(busy)
                .help(busy ? SpotCheck.busyRefusal : Self.askHelp)
                .accessibilityLabel(SpotCheck.askButtonLabel(paragraphId: paragraphId))
            if spotChecking { ProgressView().controlSize(.small) }
        }
        if let line = noticeLine {
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if case .answered(let text) = gloss {
            VStack(alignment: .leading, spacing: 4) {
                Text(SpotCheck.glossLabel)
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if case .answered(let report) = collation {
            Text(report.overall)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Self.departureRows(report, dismissed: dismissedDepartures,
                                       source: sourceText(of:))) { row in
                DepartureRowView(
                    row: row, isExpanded: false,
                    isSettled: settledDepartures.contains(row.id),
                    verbs: authorVerbs,
                    onFine: { dismissedDepartures.insert(row.id) },
                    onKeepMine: {
                        sheet = .keepMine(rowId: row.id, paragraphId: row.paragraphId,
                                          excerpt: CheckNarrative.truncatedDriftQuote(row.source ?? row.gloss),
                                          seed: row.note)
                    },
                    onMakeRule: { sheet = .makeRule(id: row.id, seed: row.note) },
                    onReveal: {
                        TranslationReveal.post(.init(docId: document.docId, language: language,
                                                     paragraphId: row.paragraphId))
                    })
            }
        }
    }

    /// Busy is either check of this section's own, or a round's leg one
    /// column over: they share the window's single cold-call runner.
    private var busy: Bool { spotChecking || roster?.coldCall.isRunning == true }

    private var noticeLine: String? {
        if let notice { return notice }
        if case .refused(let sentence) = gloss { return sentence }
        if case .refused(let sentence) = collation { return sentence }
        return nil
    }

    /// The collator's departures as rows. **The id is index-suffixed**: one
    /// report can raise two departures about one paragraph, and colliding ids
    /// would draw one row and dismiss both on one Fine. `before`/`after` are
    /// nil: a spot-check judges what is on screen and has no rewrite to show.
    static func departureRows(_ report: CollatorReport, dismissed: Set<String>,
                              source: (String) -> String?) -> [TranslationRoundReport.DepartureRow] {
        report.departures.enumerated().map { index, departure in
            let id = "\(departure.paragraphId)-\(index)"
            return TranslationRoundReport.DepartureRow(
                id: id, paragraphId: departure.paragraphId,
                source: source(departure.paragraphId),
                gloss: departure.gloss, note: departure.note,
                verdict: departure.verdict.rawValue, kind: departure.kind.rawValue,
                outcomeLine: nil, before: nil, after: nil,
                isDismissed: dismissed.contains(id))
        }
    }

    private func sourceText(of paragraphId: String) -> String? {
        guard let text = document.paragraph(id: paragraphId), !text.isEmpty else { return nil }
        return RenderFilter.stripTaskAnchorsInline(text)
    }

    private func clear() {
        gloss = nil
        collation = nil
        notice = nil
        dismissedDepartures = []
        settledDepartures = []
    }

    private func runGloss(_ paragraphId: String) {
        let entries = entries
        run(about: paragraphId) { coldCall in
            await SpotCheck.gloss(
                paragraphId: paragraphId, language: language, entries: entries,
                store: store, documentStore: documentStore, projectURL: store.url,
                coldCall: coldCall, model: model)
        } assign: { gloss = $0 }
    }

    private func runAsk(_ paragraphId: String) {
        let docId = document.docId
        run(about: paragraphId) { coldCall in
            await SpotCheck.askTheCollator(
                paragraphId: paragraphId, docId: docId, language: language,
                store: store, documentStore: documentStore, projectURL: store.url,
                coldCall: coldCall, model: model)
        } assign: { outcome in
            collation = outcome
            dismissedDepartures = []
            settledDepartures = []
        }
    }

    /// One press, one answer, about the paragraph it was asked about — and
    /// the wiring refusal said out loud.
    private func run<T: Equatable>(about paragraphId: String,
                                   call: @escaping (ColdCall) async -> SpotCheck.Outcome<T>,
                                   assign: @escaping (SpotCheck.Outcome<T>) -> Void) {
        notice = nil
        guard let coldCall = roster?.coldCall else {
            notice = SpotCheck.notWiredRefusal
            return
        }
        spotChecking = true
        Task {
            let outcome = await call(coldCall)
            spotChecking = false
            guard Self.answerStillBelongs(askedAbout: paragraphId, selected: selected?.paragraphId)
            else { return }
            assign(outcome)
        }
    }

    // MARK: The author's two verbs on a departure

    private enum Sheet: Identifiable {
        case keepMine(rowId: String, paragraphId: String, excerpt: String, seed: String)
        case makeRule(id: String, seed: String)

        var id: String {
            switch self {
            case .keepMine(let rowId, _, _, _): return "keep-mine:\(rowId)"
            case .makeRule(let id, _): return "make-rule:\(id)"
            }
        }
    }

    @ViewBuilder
    private func sheetBody(_ which: Sheet) -> some View {
        switch which {
        case .keepMine(let rowId, let paragraphId, let excerpt, let seed):
            // The app's one translator's-note sheet, defaulted to THIS edition.
            let target = TranslatorsNote.Target(docId: document.docId, paragraphId: paragraphId,
                                                excerpt: excerpt, editions: [language])
            TranslatorsNoteSheet(
                target: target,
                onCommit: { instruction, home in
                    sheet = nil
                    keepMine(rowId: rowId, target: target, instruction: instruction, home: home)
                },
                onCancel: { sheet = nil },
                seed: seed,
                defaultHome: authorVerbs.keepMineHome(language: language),
                offering: authorVerbs.keepMineHomes(language: language))
        case .makeRule(let id, let seed):
            RoundRuleSheet(seed: seed, language: language,
                           onCommit: { text in
                               sheet = nil
                               makeRule(text, rowId: id)
                           },
                           onCancel: { sheet = nil })
        }
    }

    static let keepMineProvenance = "spot-check, keep mine"
    static let makeRuleProvenance = "spot-check, make it a rule"

    /// Keep mine: a translator's note on this paragraph, in the round
    /// report's words whichever way it goes.
    private func keepMine(rowId: String, target: TranslatorsNote.Target,
                          instruction: String, home: TranslatorsNote.Home) {
        Task {
            let refusal = await TranslatorsNote.commit(
                instruction, target: target, home: home, store: store, world: world,
                provenance: Self.keepMineProvenance)
            notice = refusal ?? TranslationRoundReport.keptLine(home: home)
            if refusal == nil { settledDepartures.insert(rowId) }
        }
    }

    /// Make it a rule: doctrine for the edition, through the one door.
    private func makeRule(_ text: String, rowId: String) {
        Task {
            do {
                try await RulingPerformer.rule(
                    text, provenance: Self.makeRuleProvenance,
                    kind: .editionBrief(language), forScope: .project,
                    store: store, world: nil)
                notice = TranslationRoundReport.ruledLine(language: language)
                settledDepartures.insert(rowId)
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}
