import SwiftUI
import MaughamCore
import os

/// Diagnostic channel for the Translation pane. Subsystem from the running
/// bundle id so dev/stable logs separate without hardcoding a literal
/// (tripwire 13 spirit); mirrors `TranslationStore`'s own logger.
private let translationPaneLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham",
    category: "TranslationReviewPane")

/// Pure view-model logic behind `TranslationReviewPane` (Task 14), extracted so
/// the cursor→paragraph mapping and the open-query filter can be unit-tested
/// without AppKit or a live `Document` (`TranslationReviewPaneLogicTests`).
enum TranslationReviewPaneLogic {

    /// The translation-badge entry the cursor sits in, mapped through the
    /// TRANSLATED render (`TranslationBadgeLayout.ranges` over the badge
    /// entries) — NOT `Document.paragraphId(at:)`, which walks the source
    /// `displayText` and would resolve the wrong paragraph in this read-only
    /// derived surface.
    ///
    /// Walk semantics mirror `Document.paragraphId(at:)`: the last entry whose
    /// range starts at or before the cursor wins, so a cursor at a block's end
    /// boundary or inside the `"\n\n"` separator gap belongs to the PRECEDING
    /// block, a negative cursor clamps to the first, and a beyond-end cursor
    /// clamps to the last.
    static func selectedEntry(
        cursorLocation: Int, entries: [TranslationBadgeLayout.Entry]
    ) -> TranslationBadgeLayout.Entry? {
        let ranges = TranslationBadgeLayout.ranges(entries: entries)
        guard let first = ranges.first else { return nil }
        var selectedId = first.paragraphId
        for r in ranges {
            if cursorLocation >= r.range.location {
                selectedId = r.paragraphId
            } else {
                break
            }
        }
        return entries.first { $0.paragraphId == selectedId }
    }

    /// Open queries belonging to the active translation pass: `kind == .query`,
    /// `status == .open`, and the SAME `language` as the review posture. A nil
    /// language means the editor is not in translation review, so there is
    /// nothing to reply to — return empty rather than letting a query with a
    /// nil language tag match on `nil == nil`.
    static func openQueries(
        _ annotations: [Annotation], language: String?
    ) -> [Annotation] {
        guard let language else { return [] }
        return annotations.filter {
            $0.kind == .query && $0.status == .open && $0.language == language
        }
    }

    // MARK: - Spot-checks (P4 Task 6)

    /// **Does this answer still belong on screen?** A gloss or a collation is
    /// asked about ONE paragraph and takes seconds to come back; the buttons are
    /// disabled while it is out but the caret is not, so the writer can move
    /// while a call is in flight. Clearing on the move is not enough — the
    /// in-flight call resolves AFTERWARDS and writes its answer into the state
    /// the move just cleared, putting the wrong prose under the right heading.
    ///
    /// This is the sharpest version of that bug in the app: a gloss is the
    /// author's only reading of a language they cannot read, so they have
    /// nothing to check it against and no way to notice it is about the
    /// paragraph above.
    ///
    /// A pure predicate rather than an inline comparison, so the rule is
    /// assertable without mounting the pane.
    static func answerStillBelongs(askedAbout paragraphId: String,
                                   selected: String?) -> Bool {
        paragraphId == selected
    }

    // MARK: - Orphans (Task 5)

    /// One orphaned translation row for display: the paragraph id its stale
    /// translation was recorded against (a paragraph the manuscript no longer
    /// has) and that translation's text.
    struct OrphanRow: Identifiable, Equatable {
        let id: String
        let staleText: String
    }

    /// Map `TranslatedDocument.orphans` to display rows. Post Phase 0,
    /// `TranslationDeriver.derive` resolves orphans through `latestByParagraph`
    /// (latest wins, tombstone removes), so every record here already has
    /// non-nil text — the nil-guard is a defensive backstop that should be
    /// dead code by construction, not a load-bearing filter.
    static func orphanRows(from orphans: [TranslationRecord]) -> [OrphanRow] {
        orphans.compactMap { rec in
            guard let text = rec.text else { return nil }
            return OrphanRow(id: rec.paragraphId, staleText: text)
        }
    }

    /// Build and persist the purge batch: one tombstone record per id, all in
    /// a single `appendBatch` call (spec §2.2 — orphans are removed through
    /// the same `TranslationStore` append path the rest of the Mac side uses,
    /// never through MCP). `sourceHash` hashes the empty string: an orphan's
    /// paragraph no longer exists, so there is no live source text to hash
    /// against — mirrors `WriteTranslationTool`'s own delete-form record for
    /// an id outside the current sequence (source lookup falls back to `""`).
    static func purgeOrphans(
        _ ids: [String], docId: String, language: String,
        deviceSlug: DeviceSlug, projectURL: URL
    ) throws {
        guard !ids.isEmpty else { return }
        let records = ids.map {
            TranslationRecord(paragraphId: $0, language: language, text: nil,
                              sourceHash: TranslationHash.hash(""))
        }
        try TranslationStore.appendBatch(
            records, forDocId: docId, language: language,
            deviceSlug: deviceSlug, in: projectURL)
    }
}

/// The right-pane Translation segment (⌘⌥L). While translation review is
/// engaged, it shows the selected paragraph's SOURCE text (read-only, serif)
/// with a freshness chip, and the open translator queries for the active
/// language — each with a Reply that folds the writer's answer back into the
/// annotation via `acceptAnnotation`.
///
/// The selected paragraph tracks the editor cursor, but the editor is showing
/// the DERIVED translated surface, so the cursor offset is mapped through
/// `TranslationBadgeLayout.ranges` (Task 12), not the source `displayText`.
@MainActor
struct TranslationReviewPane: View {
    @Bindable var document: Document
    /// The editor control model — supplies the active translation language and
    /// the ordered per-paragraph freshness entries (each carrying its rendered
    /// translated text), threaded one-way from `ProjectWindow` (ADR 0017).
    let control: EditorControl
    /// The project — where an answered query's ruling is filed (publish
    /// department, Task 8). The statement layer is the project's, not the
    /// document's: an edition brief is project-scope by construction, and this
    /// pane's `document` could not address one.
    let store: ProjectStore
    /// **The window's one cold-call runner** (translation pipeline P4 Task 6) —
    /// what Gloss and Ask the collator ask through. Optional and defaulted so
    /// the probe callers that mount this pane without a window behind it keep
    /// compiling; pressing either verb without one says so in
    /// `SpotCheck.notWiredRefusal` rather than doing nothing.
    var coldCall: ColdCall? = nil
    /// The window's documents — the author's language is resolved through the
    /// imprint the desk is standing on, which lives in its UI state.
    var documentStore: DocumentStore? = nil
    /// The project root a spot-check reads its briefing from.
    var projectURL: URL? = nil
    /// The compiler's model setting, read at the press: one setting, every
    /// spawner.
    var model: String = CompilerOrchestrator.defaultModel
    /// The craft-intent cache, invalidated when a Keep mine goes to **every**
    /// edition — `TranslatorsNote`'s own rule (nothing derives a world from an
    /// edition brief, so the other home passes nil). Threaded rather than
    /// omitted because a directive filed here and one filed by ⌘⌥C are the same
    /// act, and a cache left stale by one of them is a difference the writer
    /// would find later and not be able to explain.
    var world: DeclaredWorldStore? = nil
    @Environment(\.undoManager) private var undoManager

    @State private var querySheet: Annotation?
    /// The query being answered as a ruling — the edition brief's `## Rulings`
    /// and this thread's reply, from one sentence (`QueryRuling`).
    @State private var rulingSheet: Annotation?
    /// What `QueryRuling.commit` refused, in its own words. Surfaced rather
    /// than logged: this act can land half-done, and a writer who is not told
    /// would answer again and mint a second ruling for one decision.
    @State private var rulingNotice: String?

    // MARK: - Spot-checks (P4 Task 6)

    /// The last gloss and the last collation, for the paragraph under the
    /// caret. Held as `Outcome`s rather than values, so a refusal is a state
    /// this surface can draw rather than something that vanished.
    @State private var gloss: SpotCheck.Outcome<String>?
    @State private var collation: SpotCheck.Outcome<CollatorReport>?
    @State private var spotChecking = false
    /// Departures the author has said are fine. **Transient on purpose**: a
    /// spot-check is not a round, there is no record to write the disposition
    /// into, and the answer itself is gone the moment the caret moves.
    @State private var dismissedDepartures: Set<String> = []
    /// Departures whose Keep mine or Make it a rule has already run. Both
    /// file a dated note or ruling that never dedupes, so a row that has run
    /// one of them draws its outcome rather than offering either verb again —
    /// the round report's own `settled` set, same reasoning, same reset.
    @State private var settledSpotCheckDepartures: Set<String> = []
    /// Which spot-check sheet is up, and the refusal a verb came back with.
    @State private var spotCheckSheet: SpotCheckSheet?
    @State private var notice: String?

    private var entries: [TranslationBadgeLayout.Entry] {
        control.translationBadges.entries
    }

    private var selected: TranslationBadgeLayout.Entry? {
        TranslationReviewPaneLogic.selectedEntry(
            cursorLocation: document.cursorLocation, entries: entries)
    }

    private var openQueries: [Annotation] {
        // Observing annotationsVersion re-renders when the annotation cache
        // invalidates (a reply flips a query out of the open set).
        _ = document.annotationsVersion
        let all = document.annotations(
            filter: AnnotationFilter(kinds: [.query], statuses: [.open]))
        return TranslationReviewPaneLogic.openQueries(
            all, language: control.translationLanguage)
    }

    private var orphanRows: [TranslationReviewPaneLogic.OrphanRow] {
        TranslationReviewPaneLogic.orphanRows(from: control.translationBadges.orphans)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if control.translationLanguage == nil {
                ContentUnavailableView(
                    "Not in translation review",
                    systemImage: "character.book.closed",
                    description: Text("Enter translation review to see a paragraph's source text and reply to translator queries."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "No translation yet",
                    systemImage: "character.book.closed",
                    description: Text("This document has no translated paragraphs for the selected language."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        sourceSection
                        spotCheckSection
                        Divider()
                        queriesSection
                        if !orphanRows.isEmpty {
                            Divider()
                            orphansSection
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // **An answer belongs to the paragraph it was asked about.** A gloss
        // left standing while the caret moves is the wrong prose under the
        // right heading, and it is the author's only reading of a language they
        // do not read — so both results, the refusal and the dismissals go.
        .onChange(of: selected?.paragraphId) { _, _ in clearSpotChecks() }
        .sheet(item: $spotCheckSheet) { sheet in spotCheckSheetBody(sheet) }
        .sheet(item: $querySheet) { ann in
            TranslationQueryReplySheet(annotation: ann) { reply in
                Task { try? await document.acceptAnnotation(
                    id: ann.id, userResponse: reply, undoManager: undoManager) }
                querySheet = nil
            } onCancel: { querySheet = nil }
        }
        .sheet(item: $rulingSheet) { ann in
            // The tag is what opened the sheet, so it is there; the fallback
            // draws a sheet that refuses in `commit`'s own words rather than
            // crashing on the writer's sentence.
            QueryRulingSheet(
                annotation: ann,
                language: QueryRuling.language(of: ann) ?? ""
            ) { answer in
                answerAsRuling(ann, answer: answer)
                rulingSheet = nil
            } onCancel: { rulingSheet = nil }
        }
        .alert(
            "That answer could not be filed",
            isPresented: Binding(
                get: { rulingNotice != nil },
                set: { if !$0 { rulingNotice = nil } })
        ) {
            Button("OK") { rulingNotice = nil }
        } message: {
            Text(rulingNotice ?? "")
        }
    }

    /// Answer a translator's question as doctrine — the ruling in this
    /// edition's brief and the reply on the thread, from one sentence
    /// (`QueryRuling`, publish department Task 8).
    private func answerAsRuling(_ ann: Annotation, answer: String) {
        Task {
            rulingNotice = await QueryRuling.commit(
                answer, answering: ann, in: document, store: store,
                undoManager: undoManager)
        }
    }

    // MARK: - Source

    @ViewBuilder
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Source")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = selected?.status {
                    TranslationStatusChip(status: status)
                }
            }
            if let id = selected?.paragraphId,
               let source = document.paragraph(id: id), !source.isEmpty {
                Text(RenderFilter.stripTaskAnchorsInline(source))
                    .font(.system(.body, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text("Place the cursor in a paragraph to see its source text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Spot-checks (P4 Task 6)

    /// **Two questions about the paragraph under the caret** (spec §9): what
    /// does it now say, and does it still say what I wrote? Each is one cold
    /// call, one answer drawn here, and nothing written — the verbs on a
    /// departure are what write, and the author presses those.
    @ViewBuilder
    private var spotCheckSection: some View {
        if let paragraphId = selected?.paragraphId {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(SpotCheck.glossTitle) { runGloss(paragraphId) }
                        .controlSize(.small)
                        .disabled(spotChecksBusy)
                        .help(spotChecksBusy ? SpotCheck.busyRefusal : Self.glossHelp)
                        .accessibilityLabel(
                            SpotCheck.glossButtonLabel(paragraphId: paragraphId))
                    Button(SpotCheck.askTitle) { runAskTheCollator(paragraphId) }
                        .controlSize(.small)
                        .disabled(spotChecksBusy)
                        .help(spotChecksBusy ? SpotCheck.busyRefusal : Self.askHelp)
                        .accessibilityLabel(
                            SpotCheck.askButtonLabel(paragraphId: paragraphId))
                    Spacer(minLength: 0)
                    if spotChecking { ProgressView().controlSize(.small) }
                }
                if let line = noticeLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                glossResult
                collationResult
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let glossHelp =
        "Ask what this paragraph now says, rendered back into your own language."
    private static let askHelp =
        "Ask the collator whether this paragraph still says what you wrote."

    /// Busy is EITHER check of this pane's own, or the round's leg one column
    /// over: they share the window's single cold-call runner, and a button that
    /// looks pressable while a leg is out teaches the writer that the app
    /// ignores them.
    private var spotChecksBusy: Bool {
        spotChecking || coldCall?.isRunning == true
    }

    /// One caption, one channel — whether the refusal came from the call or
    /// from never making one.
    private var noticeLine: String? {
        if let notice { return notice }
        if case .refused(let sentence) = gloss { return sentence }
        if case .refused(let sentence) = collation { return sentence }
        return nil
    }

    @ViewBuilder
    private var glossResult: some View {
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
    }

    @ViewBuilder
    private var collationResult: some View {
        if case .answered(let report) = collation {
            VStack(alignment: .leading, spacing: 8) {
                Text(report.overall)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(departureRows(report)) { row in
                    DepartureRowView(
                        row: row,
                        isExpanded: false,
                        isSettled: settledSpotCheckDepartures.contains(row.id),
                        onFine: { dismissedDepartures.insert(row.id) },
                        onKeepMine: {
                            spotCheckSheet = .keepMine(
                                rowId: row.id, paragraphId: row.paragraphId,
                                excerpt: excerpt(for: row),
                                seed: row.note)
                        },
                        onMakeRule: { spotCheckSheet = .makeRule(id: row.id, seed: row.note) },
                        onReveal: { reveal(row.paragraphId) })
                }
            }
        }
    }

    /// The collator's departures as rows the shared view can draw.
    ///
    /// **The id is index-suffixed, never the bare paragraph id.** One report can
    /// raise two departures about one paragraph — a mistranslation and an
    /// inconsistency, say — and a `ForEach` over colliding ids draws one row and
    /// loses the other, while a "Fine" on either would dismiss both.
    ///
    /// `before`/`after` are nil: a spot-check judges what is on screen and has
    /// no rewrite to disclose, so the row draws no translated text at all —
    /// spec §12's rule holding by construction.
    private func departureRows(_ report: CollatorReport) -> [TranslationRoundReport.DepartureRow] {
        report.departures.enumerated().map { index, departure in
            let id = "\(departure.paragraphId)-\(index)"
            return TranslationRoundReport.DepartureRow(
                id: id,
                paragraphId: departure.paragraphId,
                source: sourceText(of: departure.paragraphId),
                gloss: departure.gloss,
                note: departure.note,
                verdict: departure.verdict.rawValue,
                kind: departure.kind.rawValue,
                outcomeLine: nil,
                before: nil,
                after: nil,
                isDismissed: dismissedDepartures.contains(id))
        }
    }

    private func sourceText(of paragraphId: String) -> String? {
        guard let text = document.paragraph(id: paragraphId), !text.isEmpty else { return nil }
        return RenderFilter.stripTaskAnchorsInline(text)
    }

    private func excerpt(for row: TranslationRoundReport.DepartureRow) -> String {
        DiagnosticsPane.truncatedDriftQuote(row.source ?? row.gloss)
    }

    /// The project a spot-check reads from. One spelling: the window's own when
    /// it threaded one, else the document's own store — never both consulted at
    /// a call site.
    private var projectRoot: URL {
        projectURL ?? document.opStore.projectURL
    }

    private func clearSpotChecks() {
        gloss = nil
        collation = nil
        notice = nil
        dismissedDepartures = []
        settledSpotCheckDepartures = []
    }

    private func runGloss(_ paragraphId: String) {
        runSpotCheck(about: paragraphId) { language, coldCall in
            await SpotCheck.gloss(
                paragraphId: paragraphId, language: language, entries: entries,
                store: store, documentStore: documentStore, projectURL: projectRoot,
                coldCall: coldCall, model: model)
        } assign: { outcome in
            gloss = outcome
        }
    }

    private func runAskTheCollator(_ paragraphId: String) {
        runSpotCheck(about: paragraphId) { language, coldCall in
            await SpotCheck.askTheCollator(
                paragraphId: paragraphId, docId: document.docId, language: language,
                store: store, documentStore: documentStore, projectURL: projectRoot,
                coldCall: coldCall, model: model)
        } assign: { outcome in
            collation = outcome
            dismissedDepartures = []
            settledSpotCheckDepartures = []
        }
    }

    /// **One press, one answer, about the paragraph it was asked about** — and
    /// the wiring refusal said out loud. Both verbs share this so neither can
    /// grow its own idea of what "no runner" looks like, and neither can grow
    /// its own idea of what to do with an answer that outlived the caret: the
    /// id asked about is captured at the press and checked against the live
    /// selection before anything is drawn (`answerStillBelongs`). `spotChecking`
    /// is cleared either way — the call really did finish.
    private func runSpotCheck<T: Equatable>(
        about paragraphId: String,
        call: @escaping (String, ColdCall) async -> SpotCheck.Outcome<T>,
        assign: @escaping (SpotCheck.Outcome<T>) -> Void
    ) {
        notice = nil
        guard let language = control.translationLanguage else { return }
        guard let coldCall else {
            notice = SpotCheck.notWiredRefusal
            return
        }
        spotChecking = true
        Task {
            let outcome = await call(language, coldCall)
            spotChecking = false
            guard TranslationReviewPaneLogic.answerStillBelongs(
                askedAbout: paragraphId, selected: selected?.paragraphId)
            else { return }
            assign(outcome)
        }
    }

    /// The way back into the manuscript — the same post the round report's rows
    /// make, so one row and the other move the window identically.
    private func reveal(_ paragraphId: String) {
        guard let language = control.translationLanguage else { return }
        TranslationReveal.post(.init(
            docId: document.docId, language: language, paragraphId: paragraphId))
    }

    // MARK: - The author's two verbs on a departure

    /// Which spot-check sheet is up. An enum rather than two booleans, the
    /// round report's own reasoning: one thing is on screen at a time.
    private enum SpotCheckSheet: Identifiable {
        // `rowId` carries the departure row's own id for `settledSpotCheckDepartures`
        // — distinct from `paragraphId`, which two rows can share (see
        // `departureRows`'s index-suffixed id).
        case keepMine(rowId: String, paragraphId: String, excerpt: String, seed: String)
        case makeRule(id: String, seed: String)

        var id: String {
            switch self {
            case .keepMine(_, let paragraphId, _, _): return "keep-mine:\(paragraphId)"
            case .makeRule(let id, _): return "make-rule:\(id)"
            }
        }
    }

    @ViewBuilder
    private func spotCheckSheetBody(_ sheet: SpotCheckSheet) -> some View {
        let language = control.translationLanguage ?? ""
        switch sheet {
        case .keepMine(let rowId, let paragraphId, let excerpt, let seed):
            // The app's ONE translator's-note sheet, seeded with the note the
            // author is disagreeing with and defaulted to THIS edition: they
            // are answering a departure in one language, not legislating for
            // every translator at once.
            let target = TranslatorsNote.Target(
                docId: document.docId, paragraphId: paragraphId,
                excerpt: excerpt, editions: [language])
            TranslatorsNoteSheet(
                target: target,
                onCommit: { instruction, home in
                    spotCheckSheet = nil
                    keepMine(rowId: rowId, target: target, instruction: instruction, home: home)
                },
                onCancel: { spotCheckSheet = nil },
                seed: seed,
                defaultHome: .edition(language))
        case .makeRule(let id, let seed):
            RoundRuleSheet(
                seed: seed, language: language,
                onCommit: { text in
                    spotCheckSheet = nil
                    makeRule(text, rowId: id, language: language)
                },
                onCancel: { spotCheckSheet = nil })
        }
    }

    /// **Keep mine** — a translator's note on this paragraph, so every later
    /// round is briefed to keep what the author wrote. The app's one
    /// translator's-note verb, reached from a third surface; only the
    /// provenance says where it was pressed.
    ///
    /// **One press, one sentence, whichever way it goes** — the round report's
    /// rule, in the round report's own words, because a writer who files the
    /// same note from two surfaces must not be told two different things about
    /// where it went.
    private func keepMine(rowId: String, target: TranslatorsNote.Target,
                          instruction: String, home: TranslatorsNote.Home) {
        Task {
            let refusal = await TranslatorsNote.commit(
                instruction, target: target, home: home, store: store, world: world,
                provenance: Self.keepMineProvenance)
            notice = refusal ?? TranslationRoundReport.keptLine(home: home)
            // Only on success — a refused note left nothing behind to guard
            // against refiling.
            if refusal == nil { settledSpotCheckDepartures.insert(rowId) }
        }
    }

    /// **Make it a rule** — doctrine for the edition rather than a directive
    /// about one paragraph, which is why it is unanchored and project-scope.
    /// `RulingPerformer` is the one door, here as everywhere.
    private func makeRule(_ text: String, rowId: String, language: String) {
        Task {
            do {
                try await RulingPerformer.rule(
                    text, provenance: Self.makeRuleProvenance,
                    kind: .editionBrief(language), forScope: .project,
                    store: store, world: nil)
                notice = TranslationRoundReport.ruledLine(language: language)
                settledSpotCheckDepartures.insert(rowId)
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// `TranslationRoundReport.provenance`'s shape with no round to name: a
    /// spot-check is the other tempo, and a later reader of the brief should be
    /// able to tell which one filed a line.
    private static let keepMineProvenance = "spot-check, keep mine"
    private static let makeRuleProvenance = "spot-check, make it a rule"

    // MARK: - Queries

    @ViewBuilder
    private var queriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Queries")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            if openQueries.isEmpty {
                Text("No open queries for this language.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(openQueries) { ann in
                    TranslationQueryRow(
                        annotation: ann,
                        onReply: { querySheet = ann },
                        onAnswerAsRuling: { rulingSheet = ann })
                    Divider()
                }
            }
        }
    }

    // MARK: - Orphans (Task 5)

    @ViewBuilder
    private var orphansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Orphans")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove All") { purgeOrphans(orphanRows.map(\.id)) }
                    .controlSize(.small)
            }
            ForEach(orphanRows) { row in
                OrphanRowView(row: row) { purgeOrphans([row.id]) }
                Divider()
            }
        }
    }

    /// Tombstone the given orphan ids in one batch and notify any live window
    /// on this project so the translation surface re-derives (mirrors
    /// `write_translation`'s own post-write notify). No confirmation sheet —
    /// spec §2.2's deliberate choice: the data is derived-stale by
    /// definition, recreatable by Claude, and tripwire 11's
    /// delete-and-recreate spirit applies.
    private func purgeOrphans(_ ids: [String]) {
        guard let language = control.translationLanguage else { return }
        let deviceSlug = DeviceSlug.make(from: MacDeviceID.current)
        do {
            try TranslationReviewPaneLogic.purgeOrphans(
                ids, docId: document.docId, language: language,
                deviceSlug: deviceSlug, projectURL: document.opStore.projectURL)
        } catch {
            // No sheet — spec §2.2 keeps this action silent — but a write that
            // failed must not vanish without trace: the rows stay on screen and
            // a retry is a click away, so the log is where the reason lives.
            translationPaneLog.warning(
                "orphan purge failed for \(ids.count, privacy: .public) id(s) in \(language, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        MaughamEvent.post(
            .maughamTranslationDidUpdate,
            to: .project(for: document.opStore.projectURL),
            payload: ["document_id": document.docId, "language": language])
    }
}

/// A single orphaned translation: the paragraph id it was translated against
/// and the stale text, with a per-row Remove (no confirmation — see
/// `TranslationReviewPane.purgeOrphans`).
private struct OrphanRowView: View {
    let row: TranslationReviewPaneLogic.OrphanRow
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(row.staleText)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Remove", action: onRemove)
                    .controlSize(.small)
            }
        }
    }
}

/// A single open translator query with its body, a Reply affordance, and —
/// where the question carries an edition — the answer that hardens into
/// doctrine (publish department, Task 8).
///
/// The gate is `QueryRuling.offersARuling` and not "this pane is in review",
/// even though every row here is language-tagged by the pane's own filter: the
/// queue asks the same question of the same annotation, and two surfaces
/// deciding eligibility differently is how one of them starts offering to file
/// an answer with nowhere to put it.
private struct TranslationQueryRow: View {
    let annotation: Annotation
    let onReply: () -> Void
    let onAnswerAsRuling: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(annotation.body)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack {
                Spacer()
                if QueryRuling.offersARuling(annotation) {
                    Button("Answer as ruling\u{2026}", action: onAnswerAsRuling)
                        .controlSize(.small)
                        .help("A dated ruling in the edition brief, and your reply here")
                }
                Button("Reply", action: onReply)
                    .controlSize(.small)
            }
        }
    }
}

/// Freshness chip for the selected paragraph's translation (fresh / stale /
/// missing). Terse capsule mirroring the annotation-pane badge idiom.
private struct TranslationStatusChip: View {
    let status: TranslationStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch status {
        case .fresh: return "Fresh"
        case .stale: return "Stale"
        case .missing: return "Missing"
        }
    }

    private var tint: Color {
        switch status {
        case .fresh: return .green
        case .stale: return .orange
        case .missing: return .secondary
        }
    }
}

/// Reply sheet for a translator query — mirrors `AnnotationsPane`'s
/// `QueryReplySheet` (the writer's answer flows into `acceptAnnotation` as the
/// `userResponse`).
///
/// **No longer file-private, as of translation pipeline P4 Task 3.** The round
/// report's Questions section asks the writer for exactly this — a reply to a
/// translator's open query — and a second sheet saying the same thing is how the
/// two would eventually come to word it differently. `QueryRulingSheet` is
/// already shared between three surfaces for the same reason.
@MainActor
struct TranslationQueryReplySheet: View {
    let annotation: Annotation
    let onReply: (String) -> Void
    let onCancel: () -> Void
    @State private var reply: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply")
                .font(.headline)
            Text(annotation.body)
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $reply)
                .frame(minHeight: 80)
                .border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Reply") {
                    onReply(reply.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}
