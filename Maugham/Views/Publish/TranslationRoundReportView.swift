import SwiftUI
import AppKit
import MaughamCore

/// **The round report: seven legs of machine work, facing the author** —
/// translation pipeline P4 Task 3, spec §8.
///
/// A pipeline round translates a chapter, reads it, fixes it, reads it again,
/// fixes it again, collates it against the original and fixes it one last time.
/// What lands is a `TranslationRound`, and until this task it was a JSON file
/// with a line on the desk. Here it becomes the six things the author actually
/// has to know, in the spec's order: how it reads, where their prose was
/// changed, where the translator disagreed with the reader or the collator, what
/// the translator is asking them, what it wants to fix in the glossary, and what
/// the whole round came to.
///
/// **The central constraint is that the author may not read the target
/// language.** So nothing target-language-only draws by default (§12): every
/// section is the author's own prose, the collator's gloss of what the
/// translation now says, and the reader's report — all in the author's language.
/// The translation itself is one disclosure away inside a departure row, opened
/// on purpose. That rule is enforced by what `TranslationRoundReport`'s rows
/// CARRY, not by a convention here, and `TranslationRoundReportTests` reads the
/// collapsed surface off the accessibility tree to keep it that way.
///
/// **It takes values, never a store** (tripwire 4, the desk's rule): the round
/// arrives whole from the desk's Show, the sources and queries are resolved once
/// by `TranslationRoundReportHost` off a body path, and every verb is a closure.
///
/// **Opaque and full-frame**, `PublishPreviewCentre`'s rule: this is a layer of
/// `ProjectWindow.manuscriptEditor`'s `ZStack` with `EditorHost` and the altitude
/// view still mounted underneath, and anything translucent would read the
/// corkboard through the page.
///
/// **The round is a VALUE and the window owns it.** A verb that changes the
/// record hands the changed round to `onRoundChanged`, the window rewrites its
/// selection, and the next body pass draws a row that no longer offers what was
/// just done. A `@State` copy here would be the second source of truth this
/// shape exists to avoid — `DesignGateView`'s argument, one desk over.
@MainActor
struct TranslationRoundReportView: View {
    let round: TranslationRound
    /// The chapter this round is about, or nil when the document is no longer in
    /// the manifest — a round outlives the prose it judged.
    let chapterTitle: String?
    /// The author's live paragraphs by id, resolved by the host. A paragraph the
    /// writer has since deleted is simply absent.
    let sources: [String: String]
    /// The translator's open questions from this round's own window.
    let queries: [Annotation]
    /// **Why there are none, when the reason is that they could not be read**
    /// (RULING-7: unreadable is never presented as empty). Nil is the ordinary
    /// case — including a genuinely empty queue, which is a different fact and
    /// gets a different sentence.
    var queriesFailure: String? = nil
    let translatorName: String
    let collatorName: String
    var actions: TranslationRoundActions = TranslationRoundActions()
    var onClose: () -> Void = { }
    var onRoundChanged: (TranslationRound) -> Void = { _ in }
    /// Show a paragraph in the manuscript. Task 5 wires the click-through.
    var onReveal: (String) -> Void = { _ in }

    /// **What the last verb said** — a refusal in its own words, or the
    /// confirmation that it worked. The surface's ONE transient channel
    /// (`DesignGateView.notice`'s shape, `DepartmentPane`'s rule): a click that
    /// produces nothing visible is the silent no-op Global Constraint 2 exists
    /// against.
    @State private var notice: String?

    /// **How many verbs are out.** Every verb writes somewhere durable — the
    /// round's own record, a ruling, an annotation — so a second press mid-write
    /// is a second write, and a disabled control is a cheaper answer than a
    /// refusal.
    ///
    /// A count rather than a flag, and armed on the press itself, before the
    /// `Task` that runs the verb exists — arming it from inside that `Task`
    /// left the container enabled for a turn, wide enough for two fast clicks
    /// to enqueue two Tasks. What the surface must reflect is **an action that
    /// is out**, and a flag cleared by whichever call returns first would
    /// re-enable every verb with another still running.
    @State private var outstanding = 0

    private var working: Bool { outstanding > 0 }

    /// The departure rows whose translation the writer has opened. Local, and
    /// keyed by row id rather than index, because the round is re-handed to this
    /// view on every write-back and an index would move under an opened row.
    @State private var expanded: Set<String> = []

    /// **Rows whose Keep mine / right / rule verb has already run, this view
    /// session.** None of the three changes the ROUND record — they write a
    /// ruling or a note beside it — so nothing about the row itself would ever
    /// hide the button again, and `RulingPerformer.rule` does not dedupe: a
    /// second press files a second, identical dated ruling. Local view state,
    /// not a record change, on the same reasoning as `expanded` — a fresh round
    /// draws every row fresh, verbs included.
    @State private var settled: Set<String> = []

    @State private var sheet: ReportSheet?

    private var departureRows: [TranslationRoundReport.DepartureRow] {
        TranslationRoundReport.departureRows(round, sources: sources,
                                             translatorName: translatorName)
    }

    private var disagreementRows: [TranslationRoundReport.DisagreementRow] {
        TranslationRoundReport.disagreementRows(round, translatorName: translatorName,
                                                collatorName: collatorName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    readerSection
                    changedSection
                    disagreementsSection
                    questionsSection
                    proposalsSection
                    summarySection
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                // **One place, every verb.** The sections' controls all write
                // something durable, so while one is out none of the others may
                // start; disabling the container rather than each button is what
                // keeps that from being a flag each new row has to remember.
                .disabled(working)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        // **A different round is a different report.** Keyed on the round's
        // identity rather than the whole value: a verb's own write-back changes
        // the value and must NOT clear the sentence it just produced, which is
        // the one thing telling the writer what happened.
        .onChange(of: roundIdentity) { _, _ in
            notice = nil
            expanded = []
            settled = []
        }
        .sheet(item: $sheet) { sheet in
            sheetBody(sheet)
        }
    }

    private var roundIdentity: String { "\(round.language)#\(round.number)" }

    /// Which round this is, and the way out.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TranslationRoundReport.header(round, chapterTitle: chapterTitle))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button(TranslationRoundReport.closeTitle) { onClose() }
                    .controlSize(.small)
                    .accessibilityLabel(TranslationRoundReport.closeAccessibilityLabel)
                    .help("Stop reading this round and show the compiled book "
                          + "again. Nothing about the round changes.")
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(notice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 1. The reader's report

    /// Two columns, because the round read the chapter twice and the interesting
    /// fact is the movement between them.
    private var readerSection: some View {
        section(TranslationRoundReport.readerHeading) {
            HStack(alignment: .top, spacing: 16) {
                readerColumn(round.leg2, leg: .read)
                readerColumn(round.leg4, leg: .reread)
            }
            if let overall = round.collatorOverall {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TranslationRoundReport.collatorHeading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(overall)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func readerColumn(_ record: TranslationRound.ReaderReportRecord?,
                              leg: TranslationRound.Leg) -> some View {
        let column = TranslationRoundReport.readerColumn(
            record, leg: leg,
            legRecord: TranslationRoundReport.legRecord(round, leg))
        return VStack(alignment: .leading, spacing: 3) {
            Text(column.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(column.verdict)
                .font(.callout.weight(.medium))
            Text(column.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 2. Where your prose was changed

    private var changedSection: some View {
        section(TranslationRoundReport.changedHeading) {
            if departureRows.isEmpty {
                emptyLine(TranslationRoundReport.nothingChangedInProseLine)
            } else {
                ForEach(departureRows) { row in
                    DepartureRowView(
                        row: row,
                        isExpanded: expanded.contains(row.id),
                        isSettled: settled.contains(row.id),
                        onFine: { run { await actions.dismiss(round, row.id) } },
                        onKeepMine: {
                            sheet = .keepMine(rowId: row.id, paragraphId: row.paragraphId,
                                              excerpt: row.source ?? row.gloss,
                                              seed: row.note)
                        },
                        onMakeRule: { sheet = .makeRule(id: row.id, seed: row.note) },
                        onReveal: { onReveal(row.paragraphId) },
                        onToggleExpanded: {
                            if expanded.contains(row.id) {
                                expanded.remove(row.id)
                            } else {
                                expanded.insert(row.id)
                            }
                        })
                }
            }
        }
    }

    // MARK: - 3. Disagreements

    private var disagreementsSection: some View {
        section(TranslationRoundReport.disagreementsHeading) {
            if disagreementRows.isEmpty {
                emptyLine(TranslationRoundReport.noDisagreementsLine)
            } else {
                ForEach(disagreementRows) { row in disagreementRow(row) }
            }
        }
    }

    /// The note, who raised it, and why the translator turned it down — then the
    /// author's three ways of settling it.
    ///
    /// **Translator's right needs a query to settle**, and a declined note only
    /// minted one where there was somewhere for it to go (P3's declined mint).
    /// With none there is nothing to reject, and the row says so rather than
    /// drawing a button that would have to refuse.
    private func disagreementRow(
        _ row: TranslationRoundReport.DisagreementRow
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            revealLine(paragraphId: row.paragraphId)
            Text("\(row.noteAuthor):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.translatorName) declined: \(row.reason)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.annotationId == nil {
                // Named with the row's OWN right-verb: a departure offers the
                // collator's and a note the reader's.
                Text(TranslationRoundReport.noQueryForThisNote(
                    rightVerb: row.rightVerbTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let annotationId = row.annotationId {
                    Button(TranslationRoundReport.translatorsRightTitle) {
                        run { await actions.translatorsRight(round, annotationId) }
                    }
                    .controlSize(.small)
                    .accessibilityLabel(
                        TranslationRoundReport.translatorsRightLabel(id: row.id))
                    .help("Side with the translator. The question they raised is "
                          + "settled and your prose stands as translated.")
                }
                // **Reader's-or-Collator's right and Make it a rule both file a
                // dated ruling** (`RulingPerformer.rule`, which does not
                // dedupe), so once one of them has answered `.done` this round
                // the row draws that outcome instead of offering either verb
                // again — a second press would refile the same doctrine.
                if settled.contains(row.id) {
                    Text(TranslationRoundReport.ruledOutcomeLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(row.rightVerbTitle) {
                        run(settling: row.id) {
                            // The row's own verb travels with the act: "Reader's
                            // right" over a note, "Collator's right" over a
                            // departure. It is what the settled thread records and
                            // what the ruling's provenance names.
                            await actions.readersRight(round, row.annotationId ?? "",
                                                       row.paragraphId, row.text,
                                                       row.rightVerbTitle)
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel(
                        TranslationRoundReport.rightLabel(id: row.id, verb: row.rightVerbTitle))
                    .help("Side with the note. It becomes a directive on this "
                          + "paragraph for every later round.")
                    Button(TranslationRoundReport.makeRuleTitle) {
                        sheet = .makeRule(id: row.id, seed: row.text)
                    }
                    .controlSize(.small)
                    .accessibilityLabel(
                        TranslationRoundReport.makeRuleLabel(disagreement: row.id))
                    .help(DepartureRowCopy.makeRuleHelp)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 4. Questions for you

    private var questionsSection: some View {
        section(TranslationRoundReport.questionsHeading) {
            // **A read that failed is not an empty queue** (RULING-7). Above the
            // empty line rather than instead of it, because the two are
            // different facts and only one of them is good news.
            if let queriesFailure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(queriesFailure)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(queriesFailure)
            } else if queries.isEmpty {
                emptyLine(TranslationRoundReport.noQuestionsLine)
            } else {
                ForEach(queries) { query in questionRow(query) }
            }
        }
    }

    private func questionRow(_ query: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let paragraphId = query.paragraphId {
                revealLine(paragraphId: paragraphId)
            }
            Text(query.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(TranslationRoundReport.answerTitle) { sheet = .answer(query) }
                    .controlSize(.small)
                    .accessibilityLabel(TranslationRoundReport.answerLabel(id: query.id))
                    .help("Reply to the translator. The question leaves your queue.")
                // The same predicate the queue and the translation pane ask, so
                // the three surfaces cannot come to disagree about who is
                // offered doctrine (`QueryRuling.offersARuling`).
                if QueryRuling.offersARuling(query),
                   let language = QueryRuling.language(of: query) {
                    Button(TranslationRoundReport.answerAsRulingTitle) {
                        sheet = .ruling(query, language: language)
                    }
                    .controlSize(.small)
                    .accessibilityLabel(
                        TranslationRoundReport.answerAsRulingLabel(id: query.id))
                    .help(QueryRuling.confirmation(language: language))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 5. Glossary proposals

    private var proposalsSection: some View {
        section(TranslationRoundReport.proposalsHeading) {
            let rows = TranslationRoundReport.proposalRows(round)
            if rows.isEmpty {
                emptyLine(TranslationRoundReport.noProposalsLine)
            } else {
                ForEach(rows) { row in proposalRow(row) }
            }
        }
    }

    private func proposalRow(_ row: TranslationRoundReport.ProposalRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\u{00AB}\(row.term)\u{00BB} \u{2192} \u{00AB}\(row.rendering)\u{00BB}")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if row.adopted {
                    Text(TranslationRoundReport.adoptedLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if row.skipped {
                    Text(TranslationRoundReport.skippedLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(TranslationRoundReport.adoptTitle) {
                        run { await actions.adopt(round, row.id) }
                    }
                    .controlSize(.small)
                    .accessibilityLabel(TranslationRoundReport.adoptLabel(index: row.id))
                    .help("Fix this rendering for the rest of the book. Every "
                          + "later round is briefed on it.")
                    Button(TranslationRoundReport.skipTitle) {
                        run { await actions.skip(round, row.id) }
                    }
                    .controlSize(.small)
                    .accessibilityLabel(TranslationRoundReport.skipLabel(index: row.id))
                    .help("Leave this term alone. It is not proposed again.")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 6. Summary

    private var summarySection: some View {
        section(TranslationRoundReport.summaryHeading) {
            Text(round.summary ?? TranslationRoundReport.emDash)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(TranslationRoundReport.countsLine(round))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer(minLength: 0)
                // The round's own notes settle in the same queue every other
                // note does — this is the door, not a second queue.
                Button(TranslationRoundReport.openQueueTitle) {
                    MaughamEvent.postDetailSegment(.annotations)
                }
                .controlSize(.small)
                .help("Open the notes queue, where this round\u{2019}s questions "
                      + "and every other open note are disposed of.")
            }
        }
    }

    // MARK: - Sheets

    /// Which sheet is up. An enum rather than four booleans for
    /// `DesignGate.Verb`'s reason: one thing is on screen at a time, and four
    /// flags is a state where two of them are true.
    private enum ReportSheet: Identifiable {
        // `rowId` is the departure row's id, carried through for `settled` —
        // distinct from `paragraphId`, which is what the note itself is
        // anchored to and is not always unique per row.
        case keepMine(rowId: String, paragraphId: String, excerpt: String, seed: String)
        case makeRule(id: String, seed: String)
        case answer(Annotation)
        case ruling(Annotation, language: String)

        var id: String {
            switch self {
            case .keepMine(_, let paragraphId, _, _): return "keep-mine:\(paragraphId)"
            case .makeRule(let id, _): return "make-rule:\(id)"
            case .answer(let annotation): return "answer:\(annotation.id)"
            case .ruling(let annotation, _): return "ruling:\(annotation.id)"
            }
        }
    }

    @ViewBuilder
    private func sheetBody(_ sheet: ReportSheet) -> some View {
        switch sheet {
        case .keepMine(let rowId, let paragraphId, let excerpt, let seed):
            // The app's ONE translator's-note sheet, seeded with the note the
            // author is agreeing with — and defaulted to THIS edition, because
            // the writer is answering a departure in one language rather than
            // legislating for every translator at once.
            TranslatorsNoteSheet(
                target: TranslatorsNote.Target(
                    docId: round.docId, paragraphId: paragraphId,
                    excerpt: excerpt, editions: [round.language]),
                onCommit: { instruction, home in
                    self.sheet = nil
                    run(settling: rowId) {
                        await actions.keepMine(round, paragraphId, instruction, home)
                    }
                },
                onCancel: { self.sheet = nil },
                seed: seed,
                defaultHome: .edition(round.language))
        case .makeRule(let id, let seed):
            RoundRuleSheet(
                seed: seed, language: round.language,
                onCommit: { text in
                    self.sheet = nil
                    run(settling: id) { await actions.makeRule(round, text) }
                },
                onCancel: { self.sheet = nil })
        case .answer(let annotation):
            TranslationQueryReplySheet(
                annotation: annotation,
                onReply: { text in
                    self.sheet = nil
                    run { await actions.answer(round, annotation, text) }
                },
                onCancel: { self.sheet = nil })
        case .ruling(let annotation, let language):
            QueryRulingSheet(
                annotation: annotation,
                confirmation: QueryRuling.confirmation(language: language),
                onCommit: { text in
                    self.sheet = nil
                    run { await actions.answerAsRuling(round, annotation, text) }
                },
                onCancel: { self.sheet = nil })
        }
    }

    // MARK: - Running a verb

    /// **One press, one sentence** — whichever way it goes (Global Constraint
    /// 2/4) — and the changed record back to the window when there is one.
    ///
    /// `settling` names the row whose Keep mine / right / rule verb this is —
    /// nil for a verb that changes the round record itself (Fine,
    /// Translator's right) and so needs no `settled` guard. On `.done` that
    /// row joins `settled`, which is what stops a second press from filing the
    /// same ruling twice.
    private func run(settling rowId: String? = nil,
                     _ action: @escaping () async -> TranslationRoundActions.Outcome) {
        notice = nil
        // **Counted before the `Task` exists, not inside it.** The container
        // that disables every verb reads `outstanding` on this same turn — a
        // bump made inside `Task { @MainActor in … }` lands one turn late, so
        // a second fast click sees zero outstanding and enqueues a second
        // Task before the first has had a chance to disable anything.
        outstanding += 1
        Task { @MainActor in
            let outcome = await action()
            outstanding -= 1
            switch outcome {
            case .done(let updated, let sentence):
                // **The write-back**, and the reason this view holds no copy of
                // the round: the record the verb produced is on disk, and the
                // window's own value is what this surface reads.
                if let updated { onRoundChanged(updated) }
                notice = sentence
                if let rowId { settled.insert(rowId) }
            case .refused(let sentence):
                notice = sentence
            }
        }
    }

    // MARK: - Shared bits

    /// The author's own paragraph as a way back into the manuscript.
    /// `Button(.plain)`, never a tap gesture (tripwire 9).
    private func revealLine(paragraphId: String) -> some View {
        Button { onReveal(paragraphId) } label: {
            Text(sources[paragraphId] ?? TranslationRoundReport.sourceMissingLine)
                .font(sources[paragraphId] == nil ? .caption : .callout)
                .foregroundStyle(sources[paragraphId] == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            TranslationRoundReport.revealAccessibilityLabel(paragraphId: paragraphId))
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A heading and its content. No `.textCase` on the heading: the section
    /// headings are the spec's own words and a test reads them off the
    /// accessibility tree.
    private func section<Content: View>(
        _ heading: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
