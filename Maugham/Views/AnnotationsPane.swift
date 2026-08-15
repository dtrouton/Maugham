import SwiftUI
import MaughamCore

@MainActor
struct AnnotationsPane: View {
    @Bindable var document: Document
    @Environment(UserPreferences.self) private var userPreferences
    /// The window's undo manager — passed into every accept so the Document
    /// registers its undo action against the manager ⌘Z reaches (and clears
    /// the stale native typing-undo stack; the ⌘Z EXC_BAD_ACCESS class).
    @Environment(\.undoManager) private var undoManager

    @State private var kindFilter: KindOption = .all
    @State private var triageFilter: AnnotationTriageFilter = .all
    @State private var authorFilter: String = AnnotationAuthorFilter.all
    @State private var showResolved: Bool = false
    @State private var rejectSheet: Annotation?
    @State private var querySheet: Annotation?
    @State private var staleConfirm: Annotation?
    /// A suggestion whose accept was REFUSED because its quoted phrase is no
    /// longer in the paragraph (RULING-5). Drives the told-why alert; the
    /// refusal itself is `Document.acceptAnnotation`'s throw — this state only
    /// makes it audible.
    @State private var anchorLostNotice: Annotation?
    /// The accepted suggestion pending a revert confirmation — set when the
    /// paragraph's text drifted since the accept, so reverting would clobber
    /// the intervening edits (mirror of `staleConfirm` on the accept path).
    @State private var revertConfirm: Annotation?
    /// The annotation currently being edited in the inline edit sheet (author
    /// self-service). Only ever the reviewer's own annotation (gated by the
    /// Edit affordance's `isOwn` check).
    @State private var editSheet: Annotation?
    /// The annotation pending a withdraw (delete) confirmation.
    @State private var withdrawConfirm: Annotation?
    /// Annotation ids currently showing the transient "stet" flourish after the
    /// writer STETS a note. Keyed per-row so it survives the ~2.5s window
    /// between the stet op and the row leaving the open list.
    ///
    /// It fired on REJECT until M3 P2, where the word got a verb of its own and
    /// the flourish went with it: "stet" means *let it stand*, and a rejected
    /// note is precisely the one that did not.
    @State private var stetFlourishIds: Set<String> = []
    /// Selection mode (M3 P2 Task 5). While on, every row grows a leading
    /// selection control and the bulk bar sits at the foot of the column. Off
    /// by default and off is the pane Task 4 left: a writer working one note at
    /// a time never sees a checkbox.
    @State private var showBulkBar: Bool = false
    /// The ids the writer has ticked. Read through `effectiveSelection`, never
    /// directly — an id in here can stop being on screen (a bulk stet hides its
    /// row under the default `[.open]` filter; a filter change narrows the set),
    /// and acting on a row nobody can see is the author filter's stale-target
    /// bug in another key.
    @State private var selectedIds: Set<String> = []
    /// The one summary a bulk run posts when some of it could not be done
    /// (`AnnotationBulkActions.Outcome.notice`). One notice for the batch —
    /// never an alert per refusal, and never silence.
    @State private var bulkNotice: String?
    /// True while a batch is running, so the bar's verbs cannot be fired twice
    /// over a set the first run is still changing.
    @State private var bulkInFlight: Bool = false

    enum KindOption: String, CaseIterable, Identifiable, FilterRowItem {
        case all, comments, suggestions, queries, craft

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .comments: return "Comments"
            case .suggestions: return "Suggestions"
            case .queries: return "Queries"
            case .craft: return "Craft"
            }
        }

        var symbolName: String {
            switch self {
            case .all: return "circle"
            case .comments: return "bubble.left"
            case .suggestions: return "pencil.line"
            case .queries: return "questionmark.circle"
            case .craft: return "book"
            }
        }

        var kind: AnnotationKind? {
            switch self {
            case .all: return nil
            case .comments: return .comment
            case .suggestions: return .suggestedChange
            case .queries: return .query
            case .craft: return .craftNote
            }
        }
    }

    private var filter: AnnotationFilter {
        let kinds: Set<AnnotationKind>? = kindFilter.kind.map { Set([$0]) }
        let statuses: Set<AnnotationStatus>? = showResolved ? nil : [.open]
        return AnnotationFilter(kinds: kinds, statuses: statuses)
    }

    /// Annotations after the kind/status filter, before the author filter.
    /// The distinct-authors list derives from these so it reflects everything
    /// currently in scope regardless of which author is selected.
    private var kindStatusAnnotations: [Annotation] {
        // Observing annotationsVersion forces re-render when cache invalidates.
        _ = document.annotationsVersion
        return document.annotations(filter: filter)
    }

    /// The author filter, ignored when its target is no longer in scope (e.g.
    /// the status filter changed and that contributor's only rows fell away).
    /// Prevents a stale selection from hiding everything with no way to reset.
    private var effectiveAuthorFilter: String {
        guard authorFilter != AnnotationAuthorFilter.all else { return authorFilter }
        return authorLabels.contains(authorFilter) ? authorFilter : AnnotationAuthorFilter.all
    }

    private var visibleAnnotations: [Annotation] {
        var rows = kindStatusAnnotations
        // Keep any row mid-"stet" on screen even after the stet flips its status
        // out of the open filter, so the ~2.5s flourish is visible. Where it is
        // re-inserted no longer matters: the queue sort below puts it back in
        // its own place, which is where the writer's eye already is.
        if !stetFlourishIds.isEmpty {
            let present = Set(rows.map(\.id))
            let retained = document.annotations(filter: AnnotationFilter(statuses: nil))
                .filter { stetFlourishIds.contains($0.id) && !present.contains($0.id) }
            rows.append(contentsOf: retained)
        }
        let selected = effectiveAuthorFilter
        let filtered = rows.filter {
            AnnotationAuthorFilter.matches($0, selected: selected)
                && triageFilter.matches($0)
        }
        // The queue's working order (M3 P2): what the writer said they'd do,
        // then document order. The DERIVER's newest-first order (claim
        // M5-AN-004) is untouched — that claim is about the projection, and
        // this sorts the pane's rows out of it.
        return AnnotationQueueOrder.sorted(filtered, sequence: document.sequence)
    }

    private var authorLabels: [String] {
        AnnotationAuthorFilter.distinctLabels(in: kindStatusAnnotations)
    }

    /// The selection narrowed to what is actually on screen — the self-healing
    /// read of `selectedIds`, mirroring `effectiveAuthorFilter`'s shape (a
    /// computed fallback, because a stored set cannot be pruned from inside
    /// `body`). A bulk stet that hides its own rows leaves the tick marks
    /// pointing at nothing; this is what stops the next verb acting on them.
    /// The stored set is pruned to this after each run.
    private var effectiveSelection: Set<String> {
        guard !selectedIds.isEmpty else { return [] }
        return selectedIds.intersection(visibleAnnotations.map(\.id))
    }

    /// What a bulk verb acts on: the selection when there is one, else the
    /// whole visible filtered set (spec §5's "over the current filtered set").
    /// The bar says which, so the writer is never guessing.
    private var bulkTargets: [Annotation] {
        let selection = effectiveSelection
        guard !selection.isEmpty else { return visibleAnnotations }
        return visibleAnnotations.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            let deletedNotes = showResolved ? document.withdrawnAnnotations() : []
            if visibleAnnotations.isEmpty && deletedNotes.isEmpty {
                ContentUnavailableView(
                    "No annotations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Claude proposes; you dispose. Ask Claude for editorial feedback to see annotations here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    let livePids = Set(document.sequence)
                    let selection = effectiveSelection
                    LazyVStack(spacing: 0) {
                        ForEach(visibleAnnotations) { ann in
                            AnnotationRow(
                                annotation: ann,
                                revertIsEnabled: AnnotationRowPolicy.revertEnabled(ann, livePids: livePids),
                                showingStet: stetFlourishIds.contains(ann.id),
                                isOwn: AnnotationOwnership.isOwn(
                                    ann, localName: userPreferences.collaboratorDisplayName),
                                isSelectable: showBulkBar,
                                isSelected: selection.contains(ann.id),
                                onToggleSelection: { toggleSelection(ann.id) },
                                onAccept: { accept(ann) },
                                onReject: { rejectSheet = ann },
                                onStet: { stet(ann) },
                                onTriage: { mark in triage(ann, mark: mark) },
                                onArchive: { archive(ann) },
                                onReply: { querySheet = ann },
                                onEdit: { editSheet = ann },
                                onWithdraw: { withdrawConfirm = ann },
                                onRevert: { revert(ann) },
                                onReopen: {
                                    Task { try? await document.reopenAnnotation(id: ann.id, undoManager: undoManager) }
                                },
                                onJumpToParagraph: { jump(ann) })
                            Divider()
                        }
                        // RULING-34: delete is normalised for annotations too.
                        // The writer's withdrawn notes are findable here and
                        // restorable — not gone at one expired ⌘Z's mercy.
                        if showResolved {
                            let deleted = deletedNotes
                            if !deleted.isEmpty {
                                Text("Deleted")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.top, 10)
                                ForEach(deleted, id: \.id) { note in
                                    HStack(spacing: 8) {
                                        Text(note.body)
                                            .font(.callout).foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Spacer()
                                        Button("Restore") {
                                            Task { try? await document.reopenAnnotation(id: note.id) }
                                        }
                                        .buttonStyle(.bordered).controlSize(.small)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    Divider()
                                }
                            }
                        }
                    }
                }
                // Only over rows: the Deleted section below the queue is
                // restore-only, and a bar offering to accept nothing is a
                // dead control (RULING-35).
                if showBulkBar && !visibleAnnotations.isEmpty {
                    Divider()
                    bulkBar
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $rejectSheet) { ann in
            RejectReasoningSheet(annotation: ann) { reason in
                reject(ann, reason: reason)
                rejectSheet = nil
            } onCancel: { rejectSheet = nil }
        }
        .sheet(item: $querySheet) { ann in
            QueryReplySheet(annotation: ann) { reply in
                Task { try? await document.acceptAnnotation(
                    id: ann.id, userResponse: reply, undoManager: undoManager) }
                querySheet = nil
            } onCancel: { querySheet = nil }
        }
        .alert(
            "Paragraph has changed since this suggestion",
            isPresented: Binding(
                get: { staleConfirm != nil },
                set: { if !$0 { staleConfirm = nil } })
        ) {
            Button("Apply anyway") {
                if let ann = staleConfirm {
                    Task { await performAccept(ann) }
                }
                staleConfirm = nil
            }
            Button("Cancel", role: .cancel) { staleConfirm = nil }
        } message: {
            Text("Applying this suggestion will replace the current paragraph text with the originally-proposed replacement.")
        }
        .alert(
            "This suggestion can no longer be applied",
            isPresented: Binding(
                get: { anchorLostNotice != nil },
                set: { if !$0 { anchorLostNotice = nil } })
        ) {
            Button("OK") { anchorLostNotice = nil }
        } message: {
            Text(anchorLostMessage)
        }
        .alert(
            "Paragraph has changed since this suggestion was accepted",
            isPresented: Binding(
                get: { revertConfirm != nil },
                set: { if !$0 { revertConfirm = nil } })
        ) {
            Button("Revert anyway") {
                if let ann = revertConfirm { performRevert(ann) }
                revertConfirm = nil
            }
            Button("Cancel", role: .cancel) { revertConfirm = nil }
        } message: {
            Text("Reverting will replace the current paragraph text with what it was before the accept. Edits made since the accept will be lost.")
        }
        .alert(
            "Not everything in the batch could be done",
            isPresented: Binding(
                get: { bulkNotice != nil },
                set: { if !$0 { bulkNotice = nil } })
        ) {
            Button("OK") { bulkNotice = nil }
        } message: {
            Text(bulkNotice ?? "")
        }
        .sheet(item: $editSheet) { ann in
            EditAnnotationSheet(annotation: ann) { newBody, newSuggested in
                editOwn(ann, newBody: newBody, newSuggested: newSuggested)
                editSheet = nil
            } onCancel: { editSheet = nil }
        }
        .alert(
            "Delete your annotation",
            isPresented: Binding(
                get: { withdrawConfirm != nil },
                set: { if !$0 { withdrawConfirm = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let ann = withdrawConfirm { withdrawOwn(ann) }
                withdrawConfirm = nil
            }
            Button("Cancel", role: .cancel) { withdrawConfirm = nil }
        } message: {
            Text("This removes your annotation. The history is preserved, but the annotation will no longer appear here or in the editor.")
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 0) {
            AdaptiveFilterRow(
                items: KindOption.allCases,
                selection: $kindFilter)
                .layoutPriority(1)
            Spacer(minLength: 4)
            selectionModeButton
            triageFilterMenu
            authorMenu
            Button {
                showResolved.toggle()
            } label: {
                Image(systemName: showResolved ? "tray.full" : "tray")
                    .font(.caption)
                    .foregroundStyle(showResolved
                        ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(showResolved
                ? "Showing all statuses · click to show only open"
                : "Showing open only · click to include resolved")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    /// Selection mode's door. A mode rather than always-on checkboxes: the
    /// column is 280pt and a writer answering notes one at a time should not
    /// pay for a control they are not using. Leaving the mode drops the ticks —
    /// a selection nobody can see is a trap the next entry would spring.
    @ViewBuilder
    private var selectionModeButton: some View {
        Button {
            showBulkBar.toggle()
            if !showBulkBar { selectedIds.removeAll() }
        } label: {
            Image(systemName: "checklist")
                .font(.caption)
                .foregroundStyle(showBulkBar ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(showBulkBar
            ? "Leave selection mode"
            : "Select several notes and answer them together")
    }

    /// The bulk bar. Two rows so nothing truncates in a narrow column: the
    /// scope on top (what is being acted on, and the one control that changes
    /// it), the verbs below.
    @ViewBuilder
    private var bulkBar: some View {
        let targets = bulkTargets
        let selection = effectiveSelection
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(selection.isEmpty ? "Select All" : "Deselect All") {
                    selectedIds = selection.isEmpty
                        ? Set(visibleAnnotations.map(\.id))
                        : []
                }
                .buttonStyle(.link)
                Spacer(minLength: 4)
                Text(selection.isEmpty
                     ? "All \(targets.count) shown"
                     : "\(selection.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                bulkTriageMenu(targets: targets, hasSelection: !selection.isEmpty)
            }
            HStack(spacing: 8) {
                bulkButton(.accept, targets: targets,
                           hasSelection: !selection.isEmpty,
                           help: "Answer these at once. ⌘Z reverses the batch — "
                               + "except for accepted suggestions, where it reaches "
                               + "only the last; use a row's Revert for the others.")
                bulkButton(.stet, targets: targets,
                           hasSelection: !selection.isEmpty,
                           help: "Read, considered — and the words stand. "
                               + "Resolves these without applying or refusing anything.")
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    @ViewBuilder
    private func bulkButton(
        _ verb: AnnotationBulkActions.BulkVerb, targets: [Annotation],
        hasSelection: Bool, help: String
    ) -> some View {
        let planned = AnnotationBulkActions.plan(targets, verb: verb)
        Button(AnnotationBulkActions.buttonTitle(
            verb, planned: planned.count, targetCount: targets.count,
            hasSelection: hasSelection)
        ) {
            runBulk(verb, on: planned)
        }
        .buttonStyle(.bordered)
        .disabled(planned.isEmpty || bulkInFlight)
        .help(help)
    }

    /// Marking a pile is the gesture bulk was built for — a writer skims forty
    /// notes, flags what they mean to do, then works the `Do` band. Each item
    /// carries its own honest count, since the notes already holding that mark
    /// are not reached (the row's menu refuses the same re-mark).
    @ViewBuilder
    private func bulkTriageMenu(
        targets: [Annotation], hasSelection: Bool
    ) -> some View {
        Menu {
            ForEach(TriageMark.allCases, id: \.self) { mark in
                bulkMenuItem(.triage(mark), targets: targets,
                             hasSelection: hasSelection)
            }
            Divider()
            bulkMenuItem(.triage(nil), targets: targets,
                         hasSelection: hasSelection)
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
        _ verb: AnnotationBulkActions.BulkVerb, targets: [Annotation],
        hasSelection: Bool
    ) -> some View {
        let planned = AnnotationBulkActions.plan(targets, verb: verb)
        Button(AnnotationBulkActions.buttonTitle(
            verb, planned: planned.count, targetCount: targets.count,
            hasSelection: hasSelection)
        ) {
            runBulk(verb, on: planned)
        }
        .disabled(planned.isEmpty)
    }

    /// Run one verb over the planned ids.
    ///
    /// **No undo group wraps this** (ADR 0023's D1 corollary): a group would
    /// have to cover accept, and `Document.acceptAnnotation` calls
    /// `removeAllActions` from inside itself. Each note registers its own undo
    /// action instead; `NSUndoManager`'s event grouping then coalesces the
    /// batch, so one ⌘Z reverses it — which is what one deliberate click should
    /// cost. The accepted consequence is accept's own: each accept wipes the
    /// previous one's registration, so after a bulk accept only the LAST
    /// suggestion is reachable by ⌘Z and the rest need a row's Revert. The
    /// Accept button's tooltip says so; `AnnotationBulkActionsTests` pins it.
    private func runBulk(
        _ verb: AnnotationBulkActions.BulkVerb, on ids: [String]
    ) {
        guard !ids.isEmpty, !bulkInFlight else { return }
        bulkInFlight = true
        // The same flourish a single Stet wears, at scale: the rows stay put
        // for ~2.5s wearing the proofreader's mark before they resolve out of
        // the open list, so the writer sees what they just did.
        if verb == .stet { stetFlourishIds.formUnion(ids) }
        Task {
            let outcome = await AnnotationBulkActions.perform(
                verb, on: ids, in: document, undoManager: undoManager)
            bulkInFlight = false
            // Selection hygiene: the run may have taken its own rows off
            // screen. Prune to what is still visible rather than leaving ticks
            // pointing at nothing.
            selectedIds = effectiveSelection
            if let notice = outcome.notice { bulkNotice = notice }
            if verb == .stet {
                // Drop the mark from anything that did NOT stet immediately:
                // the flourish says "this note has been let stand", and a row
                // wearing it for 2.5s over a note that is still open is the
                // surface lying about what happened.
                stetFlourishIds.subtract(
                    Set(ids).subtracting(outcome.succeeded))
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                stetFlourishIds.subtract(outcome.succeeded)
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// The queue's own filter (M3 P2): show only what you said you'd do, only
    /// what you said you'd decline, only what you haven't looked at yet. A menu
    /// rather than another segmented row — the toolbar already carries the kind
    /// filter, and five more segments would push both into icon-only mode in a
    /// 280pt column.
    @ViewBuilder
    private var triageFilterMenu: some View {
        Menu {
            ForEach(AnnotationTriageFilter.allCases) { option in
                Button {
                    triageFilter = option
                } label: {
                    if option == triageFilter {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Label(
                triageFilter == .all ? "Triage" : triageFilter.label,
                systemImage: triageFilter == .all ? "flag" : "flag.fill")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by what you plan to do about each note")
    }

    @ViewBuilder
    private var authorMenu: some View {
        let labels = authorLabels
        // Only worth showing when more than one contributor is present.
        if labels.count > 1 {
            Menu {
                Button(AnnotationAuthorFilter.all) {
                    authorFilter = AnnotationAuthorFilter.all
                }
                Divider()
                ForEach(labels, id: \.self) { name in
                    Button(name) { authorFilter = name }
                }
            } label: {
                Label(
                    authorFilter == AnnotationAuthorFilter.all ? "Author" : authorFilter,
                    systemImage: "person.crop.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter annotations by who wrote them")
        }
    }

    private func accept(_ ann: Annotation) {
        if ann.kind == .suggestedChange && ann.isStale {
            staleConfirm = ann
            return
        }
        Task { await performAccept(ann) }
    }

    private var anchorLostMessage: String {
        let quoted: String
        if let quote = anchorLostNotice?.span?.quote, !quote.isEmpty {
            quoted = " (\u{201C}\(quote)\u{201D})"
        } else {
            quoted = ""
        }
        return "The passage it would replace\(quoted) is no longer in the "
            + "paragraph, so applying it could put the replacement in the wrong "
            + "place. The suggestion stays open — ask Claude for a fresh one "
            + "against the current text."
    }

    /// The one accept executor for suggestion-capable paths: a refusal for a
    /// lost span anchor (RULING-5) is surfaced, never swallowed — `try?` here
    /// would be the M5-AN-050 silence back again.
    private func performAccept(_ ann: Annotation) async {
        do {
            try await document.acceptAnnotation(id: ann.id, undoManager: undoManager)
        } catch let error as AnnotationAcceptError where error == .suggestionAnchorLost {
            anchorLostNotice = ann
        } catch {
            documentLog.error("acceptAnnotation failed for \(ann.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reject(_ ann: Annotation, reason: String) {
        Task { try? await document.rejectAnnotation(
            id: ann.id, userResponse: reason, undoManager: undoManager) }
    }

    /// Stet — the proofreader's own gesture, and now the only one that wears the
    /// proofreader's mark. The op is recorded immediately (never blocked); the
    /// flag holds the row on-screen ~2.5s so the STET badge and the reinstated
    /// text read clearly before the row resolves out of the open list.
    private func stet(_ ann: Annotation) {
        stetFlourishIds.insert(ann.id)
        Task {
            try? await document.stetAnnotation(id: ann.id, undoManager: undoManager)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            stetFlourishIds.remove(ann.id)
        }
    }

    /// Mark (or clear) what the writer plans to do about a note. Not a
    /// resolution — the row stays exactly as open as it was; only its place in
    /// the queue moves.
    private func triage(_ ann: Annotation, mark: TriageMark?) {
        Task { try? await document.triageAnnotation(
            id: ann.id, mark: mark, undoManager: undoManager) }
    }

    private func archive(_ ann: Annotation) {
        Task { try? await document.archiveAnnotation(id: ann.id, undoManager: undoManager) }
    }

    /// Revert an accepted suggestion from the pane (visible under the
    /// resolved/All filter). Reaches accepts ⌘Z can't — ⌘Z only undoes the
    /// most recent one. Gated behind a confirm when the paragraph drifted
    /// since the accept (revert restores the PRE-accept text, clobbering the
    /// intervening edits) — mirror of the accept path's `staleConfirm` gate.
    /// Only THIS pane button gates: the ⌘Z undo closure calls
    /// `revertAcceptedAnnotation` directly (undo of an immediately-prior
    /// action needs no confirm).
    private func revert(_ ann: Annotation) {
        if document.acceptedTextDrifted(annotationId: ann.id) {
            revertConfirm = ann
            return
        }
        performRevert(ann)
    }

    /// Passing the window's undo manager makes the revert itself ⌘Z-undoable
    /// (re-accept, original reply preserved).
    private func performRevert(_ ann: Annotation) {
        Task { try? await document.revertAcceptedAnnotation(
            id: ann.id, undoManager: undoManager) }
    }

    /// Author self-service edit of one's own annotation. The pane updates via
    /// `annotationsVersion`; the notification refreshes the key-window editor's
    /// crafted marks immediately (mirrors the create-case refresh).
    private func editOwn(_ ann: Annotation, newBody: String, newSuggested: String?) {
        Task {
            try? await document.editReviewerAnnotation(
                id: ann.id,
                newBody: newBody,
                newSuggestedText: newSuggested,
                authorName: userPreferences.collaboratorDisplayName,
                undoManager: undoManager)
            // No explicit editor notify: the edit bumps `annotationsVersion` on
            // the shared Document, which EditorHost mirrors into the control model
            // → `applyControl` → `setReviewAnnotations`, recomputing crafted marks
            // automatically (ADR 0017).
        }
    }

    /// Author self-service withdraw (delete) of one's own annotation.
    private func withdrawOwn(_ ann: Annotation) {
        Task {
            try? await document.withdrawReviewerAnnotation(
                id: ann.id,
                authorName: userPreferences.collaboratorDisplayName,
                undoManager: undoManager)
        }
    }

    private func jump(_ ann: Annotation) {
        // Span-precise navigation: the editor selects the exact resolved span
        // when it has one, else falls back to the paragraph. Carry both so the
        // fallback works even when the span is stale / paragraph-level. Also post
        // the legacy paragraph notification so ProjectWindow still focuses the
        // manuscript pane.
        var info: [String: Any] = ["annotation_id": ann.id]
        if let pid = ann.paragraphId { info["paragraph_id"] = pid }
        MaughamEvent.post(
            .maughamNavigateToAnnotation, to: .keyWindow, payload: info)
        if let pid = ann.paragraphId {
            MaughamEvent.post(
                .maughamNavigateToParagraph, to: .keyWindow,
                payload: ["paragraph_id": pid])
        }
    }
}

@MainActor
/// Row-level control policy — pure, so RULING-35's no-dead-controls rule is
/// testable without mounting the pane.
enum AnnotationRowPolicy {
    /// Revert makes sense only for an accepted suggestion whose anchor
    /// paragraph still exists — an enabled Revert that silently does nothing
    /// was the M5-AN-030 defect.
    static func revertEnabled(_ ann: Annotation, livePids: Set<String>) -> Bool {
        guard ann.status == .accepted, ann.kind == .suggestedChange,
              let pid = ann.paragraphId else { return true }
        return livePids.contains(pid)
    }
}

struct AnnotationRow: View {
    let annotation: Annotation
    var revertIsEnabled: Bool = true
    var showingStet: Bool = false
    /// True iff this is the local reviewer's own human annotation — gates the
    /// Edit + Delete (withdraw) affordances. Claude's / other humans' rows
    /// never show them.
    var isOwn: Bool = false
    /// Multiselect (M3 P2 Task 5) — true only while the pane is in selection
    /// mode. The control is a `Button`, so it takes the click the row's
    /// whole-body `.onTapGesture` would otherwise read as navigation: selecting
    /// a note and travelling to it are different intentions and must not share
    /// a gesture.
    var isSelectable: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}
    let onAccept: () -> Void
    let onReject: () -> Void
    /// M3 P2's fourth resolution — read, considered, and the words stand.
    var onStet: () -> Void = {}
    /// Set or clear the note's triage mark (nil clears). Pane-only: the margin
    /// card deliberately has no triage affordance — see `ReviewCardActions`.
    var onTriage: (TriageMark?) -> Void = { _ in }
    let onArchive: () -> Void
    let onReply: () -> Void
    var onEdit: () -> Void = {}
    var onWithdraw: () -> Void = {}
    var onRevert: () -> Void = {}
    /// RULING-29: resolution is the writer's to reverse, from the surface that
    /// shows it — rendered for archived, rejected and (M3 P2) stetted rows.
    var onReopen: () -> Void = {}
    let onJumpToParagraph: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelectable { selectionToggle }
            rowContent
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onJumpToParagraph() }
        .animation(.easeInOut(duration: 0.3), value: showingStet)
    }

    @ViewBuilder
    private var selectionToggle: some View {
        Button(action: onToggleSelection) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .help(isSelected ? "Deselect this note" : "Select this note")
        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(annotation.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = annotation.previousRejectionReason, !reason.isEmpty {
                // RULING-31: the writer's rejection reason is part of the
                // note's history and stays visible after a reopen.
                Text("Previously rejected: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            // Stet reaches every kind now, so the flourish has to as well —
            // it can no longer live inside the suggestion-only diff card.
            if showingStet {
                stetCard
            } else if annotation.kind == .suggestedChange {
                diffCard
            }
            actionRow
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Label(annotation.kind.displayName, systemImage: annotation.kind.systemImageName)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(kindColor)
            authorBadge
            if annotation.isStale {
                Text("Stale")
                    .font(.caption2.smallCaps())
                    .padding(.horizontal, 4)
                    .background(Color.orange.opacity(0.3))
                    .clipShape(Capsule())
            }
            Spacer()
            Text(relativeTimestamp)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Author provenance badge: a colour dot (matching the editor review marks
    /// via `ReviewPalette`) plus the author's display label. nil author → Claude
    /// with the reserved terracotta dot.
    @ViewBuilder
    private var authorBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(authorColor)
                .frame(width: 7, height: 7)
            Text(AnnotationAuthorPresentation.label(for: annotation.author))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help("Authored by \(AnnotationAuthorPresentation.label(for: annotation.author))")
    }

    private var authorColor: Color {
        Color(nsColor: ReviewPalette().color(for: annotation.author))
    }

    /// Strips inline task anchors (`<!--t-XXXXXX-->`) from annotation text before
    /// display. Mirrors `AnnotationDetailView.displayText` on the phone side.
    /// Pure + nonisolated so it's directly unit-testable.
    nonisolated static func displayText(_ raw: String) -> String {
        MarkdownDisplayFilter.stripTaskAnchorsInline(raw)
    }

    @ViewBuilder
    private var diffCard: some View {
        VStack(alignment: .leading, spacing: 1) {
            // "Before" matches the suggestion's grain: the SPAN's original
            // text for a sub-paragraph suggestion, else the whole paragraph —
            // so a one-word suggestion reads `very angry → furious`, not
            // `<whole paragraph> → furious` (SuggestionDisplay, shared w/ phone).
            if let prior = SuggestionDisplay.before(for: annotation) {
                Text("\u{2212} \(AnnotationRow.displayText(prior))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            if let suggested = annotation.suggestedText {
                Text("+ \(AnnotationRow.displayText(suggested))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The proofreader's "stet" treatment shown briefly on stetting a note: for
    /// a suggestion the struck prior text is reinstated (no strike), marked with a
    /// dotted underline, and headed by a clear "STET — let it stand" badge so the
    /// gesture is unmistakable rather than a faint italic aside. A subtle tinted
    /// card + the row-level fade give the eye something to catch in the ~2.5s
    /// dwell before the row resolves.
    @ViewBuilder
    private var stetCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("STET")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(stetAccent)
                    .clipShape(Capsule())
                Text("let it stand")
                    .font(.caption2.italic())
                    .foregroundStyle(stetAccent)
            }
            if let prior = SuggestionDisplay.before(for: annotation) {
                Text(AnnotationRow.displayText(prior))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .underline(true, pattern: .dot, color: stetAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stetAccent.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(stetAccent.opacity(0.5), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .transition(.opacity)
    }

    /// A legible, intentional editor's-ink colour for the stet mark — distinct
    /// from the red/green diff so the eye reads it as a separate gesture.
    private var stetAccent: Color { Color(red: 0.20, green: 0.45, blue: 0.78) }

    /// RULING-29's arm: a resolution is the writer's to reverse, from the
    /// surface that shows it. Stet joined archive and reject there in M3 P2 — it
    /// is a resolution like the other two. Exhaustive on purpose: a fifth status
    /// must decide whether it is reopenable, not inherit an `else`.
    private var showsReopen: Bool {
        switch annotation.status {
        case .archived, .rejected, .stetted: return true
        case .open, .accepted: return false
        }
    }

    /// The row's answers. Every verb keeps its word at the pane's default width;
    /// under pressure (a 240pt column, an own suggestion carrying seven
    /// controls) the secondary ones fall back to icons with the same word as the
    /// tooltip, the way `AdaptiveFilterRow` degrades the kind filter above. The
    /// primary verb — Accept / Got it / Reply — never loses its label.
    @ViewBuilder
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actions(useIcons: false)
            actions(useIcons: true)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func actions(useIcons: Bool) -> some View {
        HStack(spacing: 8) {
            if showsReopen {
                // (An accepted suggestion keeps its Revert below — reopening it
                // is Revert's job, text included.)
                Button("Reopen", action: onReopen).buttonStyle(.bordered)
                    .help("Return this to the open list — resolution is yours to reverse (⌘Z re-applies it)")
            } else {
                dispositions(useIcons: useIcons)
            }
            triageMenu
            if isOwn {
                Spacer(minLength: 4)
                ownAffordances
            }
        }
    }

    @ViewBuilder
    private func dispositions(useIcons: Bool) -> some View {
        switch annotation.kind {
        case .comment:
            Button("Got it", action: onAccept).buttonStyle(.borderedProminent)
            stetButton(useIcons: useIcons)
            secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
        case .suggestedChange:
            if annotation.status == .accepted {
                // Accepted rows (visible under the resolved/All filter):
                // the one meaningful action is putting the text back.
                // ⌘Z only reaches the MOST RECENT accept; this reaches
                // any accepted suggestion at any time.
                Button("Revert", action: onRevert).buttonStyle(.bordered)
                    .disabled(!revertIsEnabled)
                    .help(revertIsEnabled
                          ? "Restore the pre-accept text and reopen this suggestion"
                          : "Its paragraph was deleted — there is nothing to revert into")
            } else {
                Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
                secondary("Reject\u{2026}", symbol: "xmark", useIcons: useIcons, action: onReject)
                stetButton(useIcons: useIcons)
                secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
            }
        case .query:
            Button("Reply\u{2026}", action: onReply).buttonStyle(.borderedProminent)
            stetButton(useIcons: useIcons)
            secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
        case .craftNote:
            Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
            secondary("Reject\u{2026}", symbol: "xmark", useIcons: useIcons, action: onReject)
            stetButton(useIcons: useIcons)
            secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
        }
    }

    /// Stet — offered wherever Archive is, and the margin card mirrors it
    /// (`ReviewCardActions`). The symbol is the proofreader's own mark: dots
    /// under the words that stand.
    @ViewBuilder
    private func stetButton(useIcons: Bool) -> some View {
        secondary(
            "Stet", symbol: "textformat.abc.dottedunderline", useIcons: useIcons,
            help: "Read, considered — and the words stand. Resolves the note without applying or refusing anything.",
            action: onStet)
    }

    @ViewBuilder
    private func secondary(
        _ title: String, symbol: String, useIcons: Bool,
        help: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if useIcons {
                Image(systemName: symbol)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .help(help ?? title)
    }

    /// What the writer plans to DO about this note — the queue's sort key, not a
    /// resolution. The mark it already holds is checked AND disabled: re-applying
    /// it appends an op whose ⌘Z undoes nothing the writer can see, so the
    /// affordance refuses rather than the verb.
    @ViewBuilder
    private var triageMenu: some View {
        Menu {
            ForEach(TriageMark.allCases, id: \.self) { mark in
                Button {
                    onTriage(mark)
                } label: {
                    if annotation.triage == mark {
                        Label(mark.queueLabel, systemImage: "checkmark")
                    } else {
                        Text(mark.queueLabel)
                    }
                }
                .disabled(annotation.triage == mark)
            }
            if annotation.triage != nil {
                Divider()
                Button("Clear") { onTriage(nil) }
            }
        } label: {
            if let mark = annotation.triage {
                Label(mark.queueLabel, systemImage: mark.symbolName)
            } else {
                Image(systemName: "flag")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(annotation.triage.map { "Triaged \($0.queueLabel) — change or clear it" }
              ?? "Mark what you plan to do about this note")
    }

    /// Edit (pencil) + Delete (trash) for the reviewer's own annotation only.
    @ViewBuilder
    private var ownAffordances: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
        }
        .buttonStyle(.bordered)
        .help("Edit your annotation")
        Button(action: onWithdraw) {
            Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
        .help("Delete your annotation")
    }

    private var kindColor: Color {
        switch annotation.kind {
        case .comment: return .blue
        case .suggestedChange: return .orange
        case .query: return .purple
        case .craftNote: return .yellow
        }
    }
    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(
            for: annotation.createdAt, relativeTo: Date())
    }
}

@MainActor
private struct RejectReasoningSheet: View {
    let annotation: Annotation
    let onReject: (String) -> Void
    let onCancel: () -> Void
    @State private var reason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why are you rejecting this?")
                .font(.headline)
            Text("Your reasoning is saved with the annotation so Claude can see it in future sessions.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $reason)
                .frame(minHeight: 80)
                .border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Reject") {
                    onReject(reason.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}

/// Inline editor for the reviewer's own annotation (author self-service).
/// Pre-fills the body; for a suggested change, also exposes the replacement
/// text. On commit delivers (newBody, newSuggested?) where newSuggested is nil
/// for non-suggestion kinds. Mirrors the look of the reject/reply sheets.
@MainActor
private struct EditAnnotationSheet: View {
    let annotation: Annotation
    /// (newBody, newSuggestedText?) — newSuggestedText is nil unless this is a
    /// suggested change.
    let onCommit: (String, String?) -> Void
    let onCancel: () -> Void
    @State private var noteBody: String
    @State private var suggested: String

    init(
        annotation: Annotation,
        onCommit: @escaping (String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.annotation = annotation
        self.onCommit = onCommit
        self.onCancel = onCancel
        _noteBody = State(initialValue: AnnotationRow.displayText(annotation.body))
        _suggested = State(initialValue:
            annotation.suggestedText.map(AnnotationRow.displayText) ?? "")
    }

    private var isSuggestion: Bool { annotation.kind == .suggestedChange }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit your \(annotation.kind.displayName.lowercased())")
                .font(.headline)
            Text("Only you can edit or delete your own annotations.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Note")
                .font(.caption.smallCaps()).foregroundStyle(.secondary)
            TextEditor(text: $noteBody)
                .frame(minHeight: 70)
                .border(Color.gray.opacity(0.3))
            if isSuggestion {
                Text("Replacement text")
                    .font(.caption.smallCaps()).foregroundStyle(.secondary)
                TextEditor(text: $suggested)
                    .frame(minHeight: 50)
                    .border(Color.gray.opacity(0.3))
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onCommit(
                        noteBody.trimmingCharacters(in: .whitespacesAndNewlines),
                        isSuggestion ? suggested : nil)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}

@MainActor
private struct QueryReplySheet: View {
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
