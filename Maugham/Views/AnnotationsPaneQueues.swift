import SwiftUI
import MaughamCore

// MARK: - Document scope

/// **The centred document's queue** — its two empty states, its rows, the
/// Deleted section and the bulk bar. Values in from `AnnotationsPane` (the
/// rows its lens leaves, the selection it holds); every press goes back out
/// through the pane's verbs and row wiring.
@MainActor
struct AnnotationsDocumentQueue: View {
    let document: Document
    /// The rows after every filter, in queue order (`visibleAnnotations`).
    let rows: [Annotation]
    let deletedNotes: [AnnotationDeriver.WithdrawnAnnotation]
    let showResolved: Bool
    let showBulkBar: Bool
    /// `effectiveSelection(in: rows)` — the ticks narrowed to what is on screen.
    let selection: Set<String>
    /// `bulkTargets(in: rows)` — what a bulk verb acts on.
    let targets: [Annotation]
    /// The pane's `ledgerText`, read only where rows are drawn.
    let ledgerText: () -> String?
    let documentStore: DocumentStore
    let cockpitActivePass: ReviewPass?
    let bulkInFlight: Bool
    @Binding var selectedIds: Set<String>
    let wiring: AnnotationRowWiring
    let verbs: AnnotationsPaneVerbs

    @ViewBuilder
    var body: some View {
        if rows.isEmpty && deletedNotes.isEmpty {
            // **Two different empty states, and only one of them is empty**
            // (M4 P2 Task 8, T3 carry; widened, then corrected, in review).
            // `rows` is the pool after EVERY filter — kind, status, author,
            // triage and pass — has narrowed it; a writer whose queue is
            // merely filtered down to nothing was being told to go ask for a
            // round that had, in fact, already answered.
            //
            // **The pool this checks against is `.open`, never every
            // status.** A writer who has settled every note (the loop's own
            // success state) has zero open notes and, typically, some
            // resolved ones — counting those as "still there" would claim
            // Kind/Author/Triage/the pass filter was hiding notes that ONLY
            // Show Resolved can reveal, over a queue that is genuinely and
            // correctly empty (`documentQueueIsGenuinelyEmpty`'s own doc
            // comment carries the fuller account, incl. why this cannot
            // disagree with `emptyState`'s `.settled` arm on the sibling
            // pane). Never `kindStatusAnnotations` either: that pre-filters
            // by KIND, so a writer narrowed to Suggestions on a document
            // holding only open comments would have read `pool.isEmpty` too
            // and drawn the round-teaching "No annotations" over notes the
            // KIND filter alone was hiding.
            if !AnnotationsPane.documentQueueIsGenuinelyEmpty(
                pool: document.annotations(filter: AnnotationFilter(statuses: [.open])),
                visibleRows: rows) {
                ContentUnavailableView(
                    "No notes match your filters",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Your queue isn\u{2019}t empty \u{2014} these "
                        + "notes are just hidden by Kind, Author, Triage, or "
                        + "the pass filter. Widen one to see them."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // **The empty state teaches the loop** (M4 P2 Task 3). It used
                // to name one of the two ways this queue fills — "ask Claude
                // for editorial feedback" — and that is no longer the one
                // Review is built around. Both are named now, the round first
                // and by the editor who reads it
                // (`ReviewRoundCockpit.emptyQueueTeaching`).
                //
                // **The editor comes from the piece's STAGE, and from
                // nothing else** (two loops P1 Task 2). The teaching's whole
                // job is to name the round ⌘R would actually make here, and a
                // round is a stage's or it is refused (`RoundEditor`) — so an
                // unassigned piece names nobody and falls back to the
                // keystroke alone. It reads the nilable arm rather than
                // `effectiveEditorName ?? "Claude"`, because "Claude" is the
                // byline a passless run signs with and not an editor to
                // invite: "Run Claude's round" is the sentence this optional
                // exists to avoid.
                ContentUnavailableView(
                    "No annotations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(ReviewRoundCockpit.emptyQueueTeaching(
                        editorName: cockpitActivePass?.effectiveEditorName)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                let livePids = Set(document.sequence)
                let posture = documentStore.posture(forDocId: document.docId)
                // One read for the whole pass, for `ledgerText`'s reason.
                let ledger = ledgerText()
                LazyVStack(spacing: 0) {
                    AnnotationListView(
                        annotations: rows, docId: document.docId,
                        document: document, livePids: livePids,
                        ledgerText: ledger, isSelectable: showBulkBar,
                        selection: selection, wiring: wiring)
                    // RULING-34: delete is normalised for annotations too.
                    // The writer's withdrawn notes are findable here and
                    // restorable — not gone at one expired ⌘Z's mercy.
                    if showResolved && !deletedNotes.isEmpty {
                        Text("Deleted")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.top, 10)
                        ForEach(deletedNotes, id: \.id) { note in
                            HStack(spacing: 8) {
                                Text(note.body)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer()
                                // A restore undoes a WITHDRAWAL, so it follows
                                // the deleter (ruling P, Ruling D): what SHE
                                // deleted is hers to restore whatever her
                                // rung. Asked of the door's own judgement, by
                                // KEY (P3c plan 2 Task 8) — never by the
                                // display name a withdraw op stamps — and
                                // hidden where the door would refuse it.
                                if AnnotationRowVerbs.restoresDeleted(
                                    posture: posture,
                                    standing: document.restoreStanding(
                                        annotationId: note.id)) {
                                    Button("Restore") { verbs.reopen(document, id: note.id) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
            // Only over rows: the Deleted section below the queue is
            // restore-only, and a bar offering to accept nothing is a
            // dead control (RULING-35).
            //
            // Nor over a document whose posture offers no bulk verb (P3c Task
            // 5): a bar of Select All and nothing to press is the same dead
            // control.
            if showBulkBar && !rows.isEmpty
                && AnnotationsPane.bulkOffersAVerb(posture: documentStore.posture(forDocId: document.docId)) {
                Divider()
                AnnotationsBulkBar(
                    document: document, rows: rows, selection: selection,
                    targets: targets, documentStore: documentStore,
                    bulkInFlight: bulkInFlight, selectedIds: $selectedIds,
                    verbs: verbs)
            }
        }
    }
}

// MARK: - The bulk bar

/// **Bulk over the document queue** (M3 P2 Task 5) — `AnnotationsDocumentQueue`
/// mounts it under the rows in selection mode.
@MainActor
struct AnnotationsBulkBar: View {
    let document: Document
    let rows: [Annotation]
    let selection: Set<String>
    let targets: [Annotation]
    let documentStore: DocumentStore
    let bulkInFlight: Bool
    @Binding var selectedIds: Set<String>
    let verbs: AnnotationsPaneVerbs

    var body: some View { bulkBar(document: document, rows: rows) }

    /// The bulk bar. Two rows so nothing truncates in a narrow column: the
    /// scope on top (what is being acted on, and the one control that changes
    /// it), the verbs below.
    @ViewBuilder
    private func bulkBar(document: Document, rows: [Annotation]) -> some View {
        // ONE document, so one posture for every row the bar would act on —
        // asked of the document the bar acts on, never the window's.
        let posture = documentStore.posture(forDocId: document.docId)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(selection.isEmpty ? "Select All" : "Deselect All") {
                    selectedIds = selection.isEmpty ? Set(rows.map(\.id)) : []
                }
                .buttonStyle(.link)
                Spacer(minLength: 4)
                Text(selection.isEmpty
                     ? "All \(targets.count) shown"
                     : "\(selection.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                bulkTriageMenu(document: document, targets: targets,
                               hasSelection: !selection.isEmpty, posture: posture)
            }
            HStack(spacing: 8) {
                bulkButton(.accept, document: document, targets: targets,
                           hasSelection: !selection.isEmpty, posture: posture,
                           help: "Answer these at once. ⌘Z reverses the batch — "
                               + "except for accepted suggestions, where it reaches "
                               + "only the last; use a row's Revert for the others.")
                bulkButton(.stet, document: document, targets: targets,
                           hasSelection: !selection.isEmpty, posture: posture,
                           help: "Read, considered — and the words stand. "
                               + "Resolves these without applying or refusing anything.")
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    /// Not drawn at all where the posture forbids the verb (P3c Task 5) —
    /// hidden, not disabled; disabled only where the NOTES leave nothing to do.
    @ViewBuilder
    private func bulkButton(
        _ verb: AnnotationBulkActions.BulkVerb, document: Document,
        targets: [Annotation], hasSelection: Bool, posture: Posture, help: String
    ) -> some View {
        if AnnotationBulkActions.offers(verb, under: posture) {
            let planned = AnnotationBulkActions.plan(targets, verb: verb, posture: posture)
            Button(AnnotationBulkActions.buttonTitle(
                verb, planned: planned.count, targetCount: targets.count,
                hasSelection: hasSelection)
            ) {
                verbs.runBulk(verb, on: planned, in: document)
            }
            .buttonStyle(.bordered)
            .disabled(planned.isEmpty || bulkInFlight)
            .help(help)
        }
    }

    /// Marking a pile is the gesture bulk was built for — a writer skims forty
    /// notes, flags what they mean to do, then works the `Do` band. Each item
    /// carries its own honest count, since the notes already holding that mark
    /// are not reached (the row's menu refuses the same re-mark).
    @ViewBuilder
    private func bulkTriageMenu(
        document: Document, targets: [Annotation], hasSelection: Bool,
        posture: Posture
    ) -> some View {
        if AnnotationBulkActions.offers(.triage(nil), under: posture) {
            bulkTriageMenuBody(document: document, targets: targets,
                               hasSelection: hasSelection, posture: posture)
        }
    }

    @ViewBuilder
    private func bulkTriageMenuBody(
        document: Document, targets: [Annotation], hasSelection: Bool,
        posture: Posture
    ) -> some View {
        Menu {
            ForEach(TriageMark.allCases, id: \.self) { mark in
                bulkMenuItem(.triage(mark), document: document, targets: targets,
                             hasSelection: hasSelection, posture: posture)
            }
            Divider()
            bulkMenuItem(.triage(nil), document: document, targets: targets,
                         hasSelection: hasSelection, posture: posture)
        } label: {
            Label("Triage", systemImage: "flag")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(bulkInFlight)
        .help("Mark what you plan to do about all of these")
    }

    @ViewBuilder
    private func bulkMenuItem(
        _ verb: AnnotationBulkActions.BulkVerb, document: Document,
        targets: [Annotation], hasSelection: Bool, posture: Posture
    ) -> some View {
        let planned = AnnotationBulkActions.plan(targets, verb: verb, posture: posture)
        Button(AnnotationBulkActions.buttonTitle(
            verb, planned: planned.count, targetCount: targets.count,
            hasSelection: hasSelection)
        ) {
            verbs.runBulk(verb, on: planned, in: document)
        }
        .disabled(planned.isEmpty)
    }

}

// MARK: - Project scope (M3 P2 Task 7)

/// **Every piece's notes, by the board's rows** — sections, each piece's
/// header (its yield and its lock), and RULING-54's footnote. Values in from
/// `AnnotationsPane`; every press goes out through the row wiring.
@MainActor
struct AnnotationsProjectQueue: View {
    let focusPiece: String?
    let scope: AnnotationScope
    let snapshot: ProjectAnnotationsSnapshot
    let sections: [AnnotationScopeSections.Section]
    let notice: String?
    /// The pane's `ledgerText`, read only where rows are drawn.
    let ledgerText: () -> String?
    let documentStore: DocumentStore
    let wiring: AnnotationRowWiring

    @ViewBuilder
    var body: some View {
        if sections.isEmpty && notice == nil {
            ContentUnavailableView(
                "No annotations in this project",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Every piece's notes gather here. Ask Claude for editorial feedback to see annotations."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    let ledger = ledgerText()
                    LazyVStack(spacing: 0) {
                        ForEach(sections) { section in
                            // The sequences travel DOWN from the one snapshot
                            // read: asking the store per section would restat
                            // every closed piece's op log once per heading.
                            // The ledger travels with them, for the same reason
                            // one directory over (`ledgerText`).
                            sectionView(section, sequences: snapshot.sequences,
                                        ledgerText: ledger)
                        }
                        if let notice { unreadableFootnote(notice) }
                    }
                }
                .onAppear { scroll(to: focusPiece, proxy: proxy) }
                .onChange(of: scope) { _, newScope in
                    if case .project(let piece) = newScope {
                        scroll(to: piece, proxy: proxy)
                    }
                }
            }
        }
    }

    /// Bring an arriving piece's section into view (Task 9's click-through from
    /// the board sets `focusPiece`). Deferred a tick: the sections mount lazily
    /// and a `scrollTo` issued in the same pass lands on a stack that has not
    /// laid its rows out yet — the `TreeScrollTarget` shape.
    private func scroll(to piece: String?, proxy: ScrollViewProxy) {
        guard let piece else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            withAnimation { proxy.scrollTo(piece, anchor: .top) }
        }
    }

    @ViewBuilder
    private func sectionView(
        _ section: AnnotationScopeSections.Section,
        sequences: [String: [String]],
        ledgerText: String?
    ) -> some View {
        switch section.kind {
        case .group(let depth):
            Text(section.title)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12 + CGFloat(depth) * 12)
                .padding(.trailing, 12)
                .padding(.top, 14).padding(.bottom, 2)
                .id(section.id)
        case .piece:
            pieceSection(section, sequences: sequences, ledgerText: ledgerText)
        }
    }

    @ViewBuilder
    private func pieceSection(
        _ section: AnnotationScopeSections.Section,
        sequences: [String: [String]],
        ledgerText: String?
    ) -> some View {
        // The row's own document, and the whole of the open-vs-closed question:
        // a closed piece's notes are readable here and actable in ITS window.
        let rowDocument = documentStore.document(forDocId: section.id)
        let livePids = Set(rowDocument?.sequence
            ?? sequences[section.id] ?? [])
        // Ruling AJ (P3c plan 2 Task 8): the root yielding on this piece hides
        // its rows' verbs, so the header says whose piece it is and offers the
        // same Edit Anyway the standing line over the editor offers.
        let yield = AnnotationScopePolicy.yieldNotice(
            posture: documentStore.posture(forDocId: section.id),
            docId: section.id)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(section.annotations.count)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                if let yield {
                    Text(yield.reason)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(AnnotationScopePolicy.editAnywayTitle) {
                        documentStore.overrideYield(docId: yield.docId)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Spacer(minLength: 4)
                if rowDocument == nil {
                    Image(systemName: "lock")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(AnnotationScopePolicy.closedPieceReason)
                        .accessibilityLabel(AnnotationScopePolicy.closedPieceReason)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            AnnotationListView(
                annotations: section.annotations, docId: section.id,
                document: rowDocument, livePids: livePids,
                ledgerText: ledgerText, wiring: wiring)
        }
        .id(section.id)
    }

    /// RULING-54's honesty half at the queue's foot — see
    /// `AnnotationScopeSections.unreadableNotice`.
    @ViewBuilder
    private func unreadableFootnote(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.caption2)
            Text(notice).font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
