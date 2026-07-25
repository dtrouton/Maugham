import SwiftUI
import MaughamCore

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
    @Environment(\.undoManager) private var undoManager

    @State private var querySheet: Annotation?

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
                        Divider()
                        queriesSection
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $querySheet) { ann in
            TranslationQueryReplySheet(annotation: ann) { reply in
                Task { try? await document.acceptAnnotation(
                    id: ann.id, userResponse: reply, undoManager: undoManager) }
                querySheet = nil
            } onCancel: { querySheet = nil }
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
                    TranslationQueryRow(annotation: ann) { querySheet = ann }
                    Divider()
                }
            }
        }
    }
}

/// A single open translator query with its body and a Reply affordance.
private struct TranslationQueryRow: View {
    let annotation: Annotation
    let onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(annotation.body)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack {
                Spacer()
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
/// `userResponse`). Kept file-private here rather than shared because the two
/// surfaces present the same op through independent panes.
@MainActor
private struct TranslationQueryReplySheet: View {
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
