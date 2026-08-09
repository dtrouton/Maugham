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
    /// Annotation ids currently showing the transient "stet" flourish after a
    /// reject of a suggested change. Keyed per-row so it survives the ~2.5s
    /// window between the reject op and the row leaving the open list.
    @State private var stetIds: Set<String> = []

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
        // Keep any row mid-"stet" on screen even after its reject flips the
        // status out of the open filter, so the ~2.5s flourish is visible. The
        // retained row is appended at the end (not re-spliced at its prior
        // index) — it only lingers briefly before the stet completes and it
        // drops out.
        if !stetIds.isEmpty {
            let present = Set(rows.map(\.id))
            let retained = document.annotations(filter: AnnotationFilter(statuses: nil))
                .filter { stetIds.contains($0.id) && !present.contains($0.id) }
            rows.append(contentsOf: retained)
        }
        let selected = effectiveAuthorFilter
        return rows.filter {
            AnnotationAuthorFilter.matches($0, selected: selected)
        }
    }

    private var authorLabels: [String] {
        AnnotationAuthorFilter.distinctLabels(in: kindStatusAnnotations)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if visibleAnnotations.isEmpty {
                ContentUnavailableView(
                    "No annotations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Claude proposes; you dispose. Ask Claude for editorial feedback to see annotations here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleAnnotations) { ann in
                            AnnotationRow(
                                annotation: ann,
                                showingStet: stetIds.contains(ann.id),
                                isOwn: AnnotationOwnership.isOwn(
                                    ann, localName: userPreferences.collaboratorDisplayName),
                                onAccept: { accept(ann) },
                                onReject: { rejectSheet = ann },
                                onArchive: { archive(ann) },
                                onReply: { querySheet = ann },
                                onEdit: { editSheet = ann },
                                onWithdraw: { withdrawConfirm = ann },
                                onRevert: { revert(ann) },
                                onJumpToParagraph: { jump(ann) })
                            Divider()
                        }
                    }
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
        // For a suggested change, show the proofreader's "stet" flourish briefly
        // before the rejected row leaves the open list. The op is recorded
        // immediately (never blocked); the stet flag keeps the row on-screen for
        // ~1.5s so the strike-through resolves back with a "stet" mark.
        if ann.kind == .suggestedChange {
            stetIds.insert(ann.id)
            Task {
                try? await document.rejectAnnotation(id: ann.id, userResponse: reason, undoManager: undoManager)
                // Hold ~2.5s so the strike-removed "prior" text + the STET badge
                // read clearly before the row resolves out of the open list. The
                // op above already landed; this only governs the visual dwell.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                stetIds.remove(ann.id)
            }
        } else {
            Task { try? await document.rejectAnnotation(id: ann.id, userResponse: reason, undoManager: undoManager) }
        }
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
struct AnnotationRow: View {
    let annotation: Annotation
    var showingStet: Bool = false
    /// True iff this is the local reviewer's own human annotation — gates the
    /// Edit + Delete (withdraw) affordances. Claude's / other humans' rows
    /// never show them.
    var isOwn: Bool = false
    let onAccept: () -> Void
    let onReject: () -> Void
    let onArchive: () -> Void
    let onReply: () -> Void
    var onEdit: () -> Void = {}
    var onWithdraw: () -> Void = {}
    var onRevert: () -> Void = {}
    let onJumpToParagraph: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(annotation.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if annotation.kind == .suggestedChange {
                diffCard
            }
            actionRow
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onJumpToParagraph() }
        .animation(.easeInOut(duration: 0.3), value: showingStet)
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
        if showingStet {
            stetCard
        } else {
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
    }

    /// The proofreader's "stet" treatment shown briefly on rejecting a suggested
    /// change: the struck prior text is reinstated (no strike), marked with a
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

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            switch annotation.kind {
            case .comment:
                Button("Got it", action: onAccept).buttonStyle(.borderedProminent)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            case .suggestedChange:
                if annotation.status == .accepted {
                    // Accepted rows (visible under the resolved/All filter):
                    // the one meaningful action is putting the text back.
                    // ⌘Z only reaches the MOST RECENT accept; this reaches
                    // any accepted suggestion at any time.
                    Button("Revert", action: onRevert).buttonStyle(.bordered)
                        .help("Restore the pre-accept text and reopen this suggestion")
                } else {
                    Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
                    Button("Reject\u{2026}", action: onReject).buttonStyle(.bordered)
                    Button("Archive", action: onArchive).buttonStyle(.bordered)
                }
            case .query:
                Button("Reply\u{2026}", action: onReply).buttonStyle(.borderedProminent)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            case .craftNote:
                Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
                Button("Reject\u{2026}", action: onReject).buttonStyle(.bordered)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            }
            if isOwn {
                Spacer(minLength: 4)
                ownAffordances
            }
        }
        .controlSize(.small)
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
