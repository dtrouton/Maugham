import SwiftUI
import MaughamCore

@MainActor
struct AnnotationsPane: View {
    @Bindable var document: Document

    @State private var kindFilter: KindOption = .all
    @State private var authorFilter: String = AnnotationAuthorFilter.all
    @State private var showResolved: Bool = false
    @State private var rejectSheet: Annotation?
    @State private var querySheet: Annotation?
    @State private var staleConfirm: Annotation?
    /// Annotation ids currently showing the transient "stet" flourish after a
    /// reject of a suggested change. Keyed per-row so it survives the brief
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
        // status out of the open filter, so the flourish is visible. Preserve
        // the original ordering by splicing the retained row at its prior index.
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
                                onAccept: { accept(ann) },
                                onReject: { rejectSheet = ann },
                                onArchive: { archive(ann) },
                                onReply: { querySheet = ann },
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
                    id: ann.id, userResponse: reply) }
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
                    Task { try? await document.acceptAnnotation(id: ann.id) }
                }
                staleConfirm = nil
            }
            Button("Cancel", role: .cancel) { staleConfirm = nil }
        } message: {
            Text("Applying this suggestion will replace the current paragraph text with the originally-proposed replacement.")
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
        Task { try? await document.acceptAnnotation(id: ann.id) }
    }

    private func reject(_ ann: Annotation, reason: String) {
        // For a suggested change, show the proofreader's "stet" flourish briefly
        // before the rejected row leaves the open list. The op is recorded
        // immediately (never blocked); the stet flag keeps the row on-screen for
        // ~1.5s so the strike-through resolves back with a "stet" mark.
        if ann.kind == .suggestedChange {
            stetIds.insert(ann.id)
            Task {
                try? await document.rejectAnnotation(id: ann.id, userResponse: reason)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                stetIds.remove(ann.id)
            }
        } else {
            Task { try? await document.rejectAnnotation(id: ann.id, userResponse: reason) }
        }
    }

    private func archive(_ ann: Annotation) {
        Task { try? await document.archiveAnnotation(id: ann.id) }
    }

    private func jump(_ ann: Annotation) {
        guard let pid = ann.paragraphId else { return }
        NotificationCenter.default.post(
            name: .maughamNavigateToParagraph,
            object: nil,
            userInfo: ["paragraph_id": pid])
    }
}

@MainActor
struct AnnotationRow: View {
    let annotation: Annotation
    var showingStet: Bool = false
    let onAccept: () -> Void
    let onReject: () -> Void
    let onArchive: () -> Void
    let onReply: () -> Void
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
        .animation(.easeInOut(duration: 0.2), value: showingStet)
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
                if let prior = annotation.priorText {
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
    /// dotted underline and a small "stet" caret to say "let it stand".
    @ViewBuilder
    private var stetCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let prior = annotation.priorText {
                Text(AnnotationRow.displayText(prior))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .underline(true, pattern: .dot)
            }
            Text("stet")
                .font(.caption2.italic())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .transition(.opacity)
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            switch annotation.kind {
            case .comment:
                Button("Got it", action: onAccept).buttonStyle(.borderedProminent)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            case .suggestedChange:
                Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
                Button("Reject\u{2026}", action: onReject).buttonStyle(.bordered)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            case .query:
                Button("Reply\u{2026}", action: onReply).buttonStyle(.borderedProminent)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            case .craftNote:
                Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
                Button("Reject\u{2026}", action: onReject).buttonStyle(.bordered)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
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
