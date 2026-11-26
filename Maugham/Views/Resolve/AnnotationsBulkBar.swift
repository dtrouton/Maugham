import SwiftUI
import MaughamCore

/// **Bulk over the open piece's notes** (M3 P2 Task 5) — `ResolvePane` mounts
/// it under the rows in selection mode. Moved from the Annotations pane's
/// queue file when that pane was deleted (shell plan 2 Task 7).
@MainActor
struct AnnotationsBulkBar: View {
    let document: Document
    let rows: [Annotation]
    let selection: Set<String>
    let targets: [Annotation]
    let documentStore: DocumentStore
    let bulkInFlight: Bool
    @Binding var selectedIds: Set<String>
    let verbs: ResolveNoteVerbs

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
