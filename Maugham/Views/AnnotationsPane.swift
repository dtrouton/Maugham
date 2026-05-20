import SwiftUI

@MainActor
struct AnnotationsPane: View {
    @Bindable var document: Document

    @State private var kindFilter: KindOption = .all
    @State private var showResolved: Bool = false
    @State private var rejectSheet: Annotation?
    @State private var querySheet: Annotation?
    @State private var staleConfirm: Annotation?

    enum KindOption: String, CaseIterable, Identifiable {
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

    private var visibleAnnotations: [Annotation] {
        // Observing annotationsVersion forces re-render when cache invalidates.
        _ = document.annotationsVersion
        return document.annotations(filter: filter)
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
        .sheet(item: $rejectSheet) { ann in
            RejectReasoningSheet(annotation: ann) { reason in
                Task { try? await document.rejectAnnotation(
                    id: ann.id, userResponse: reason) }
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
        // ScrollView keeps the pills on one line even when the pane is
        // narrow. Without it SwiftUI wraps the text inside each Button
        // ("Suggestions" → "Sug-\ngestions") which looks broken at narrow
        // widths the user can dial down to. The trailing Resolved toggle
        // sits outside the scroll so it stays reachable.
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(KindOption.allCases) { opt in
                        Button(opt.label) { kindFilter = opt }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(opt == kindFilter
                                ? Color.secondary.opacity(0.3)
                                : Color.clear)
                            .clipShape(Capsule())
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.trailing, 6)
            }
            // Resolved is the only non-kind control — render as a compact
            // icon-only toggle to save horizontal space. The tooltip
            // explains; tapping flips between open-only and all statuses.
            Button {
                showResolved.toggle()
            } label: {
                Image(systemName: showResolved
                    ? "tray.full" : "tray")
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

    private func accept(_ ann: Annotation) {
        if ann.kind == .suggestedChange && ann.isStale {
            staleConfirm = ann
            return
        }
        Task { try? await document.acceptAnnotation(id: ann.id) }
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
private struct AnnotationRow: View {
    let annotation: Annotation
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
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Label(kindLabel, systemImage: kindIcon)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(kindColor)
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

    @ViewBuilder
    private var diffCard: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let prior = annotation.priorText {
                Text("\u{2212} \(prior)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            if let suggested = annotation.suggestedText {
                Text("+ \(suggested)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
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

    private var kindLabel: String {
        switch annotation.kind {
        case .comment: return "Comment"
        case .suggestedChange: return "Suggestion"
        case .query: return "Query"
        case .craftNote: return "Craft note"
        }
    }
    private var kindIcon: String {
        switch annotation.kind {
        case .comment: return "bubble.left"
        case .suggestedChange: return "wand.and.stars"
        case .query: return "questionmark.circle"
        case .craftNote: return "ruler"
        }
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
