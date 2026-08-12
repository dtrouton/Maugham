// Maugham/Views/RecoveredHistorySheet.swift
import SwiftUI
import MaughamCore

/// The read-only report `HistoryPane`'s Retry surfaces when a returned
/// set-aside op-log file carries paragraphs the merged draft doesn't have
/// (Plan B, spec §5's writer-facing half). Each orphan's text is copyable;
/// "Append to End" lands it as an ordinary paragraph via `insertParagraph` —
/// a freshly minted id and a fresh op, not a resurrection of the orphan's
/// original one (this is a merge decision the writer makes, not the history
/// silently rejoining the draft).
struct RecoveredHistorySheet: View {
    let report: RecoveredHistoryReport
    /// The OPEN document only — the register's Append constraint. `nil` when
    /// the writer hasn't opened this document this session; Append is then
    /// disabled with `documentClosedReason` rather than silently reaching
    /// for a closed doc through some other path.
    let document: Document?
    let onDismiss: () -> Void

    @State private var appendedIds: Set<String> = []

    /// Shown in place of the per-orphan Append control when `document` is
    /// nil. Pinned as a `static let` (not inlined) so the copy is testable
    /// without mounting the sheet — same discipline as `HistoryPane`'s
    /// notice statics.
    static let documentClosedReason = "Open the document to append"

    /// Appends `orphan.text` as a new paragraph after `document`'s current
    /// last paragraph. `sequence.last` is read fresh on every call (not
    /// captured once), so repeated appends land in the order the writer
    /// clicked them. `insertParagraph` treats a `nil` `after` (an empty
    /// document) the same as an append, so this is correct there too.
    ///
    /// A `static` function over an explicit `Document` argument rather than
    /// a private method on the view — testable directly without mounting,
    /// matching `HistoryPane.predecessorIndex`'s pattern for view-adjacent
    /// pure logic.
    @discardableResult
    static func append(_ orphan: RecoveredHistoryReport.Orphan, to document: Document) -> String {
        document.insertParagraph(after: document.sequence.last, text: orphan.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if report.orphans.isEmpty {
                ContentUnavailableView(
                    "Nothing recovered",
                    systemImage: "checkmark.circle",
                    description: Text("Recovered history merged — nothing was missing"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(report.orphans) { orphan in
                            orphanRow(orphan)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Recovered history").font(.headline)
            Spacer()
            if !report.orphans.isEmpty {
                Button("Append All to End", action: appendAll)
                    .disabled(document == nil || allAppended)
            }
            Button("Done", action: onDismiss)
        }
        .padding(12)
    }

    private var allAppended: Bool {
        Set(report.orphans.map(\.id)).isSubset(of: appendedIds)
    }

    @ViewBuilder
    private func orphanRow(_ orphan: RecoveredHistoryReport.Orphan) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(orphan.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            appendControl(orphan)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private func appendControl(_ orphan: RecoveredHistoryReport.Orphan) -> some View {
        if let document {
            if appendedIds.contains(orphan.id) {
                Label("Appended", systemImage: "checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Append to End") {
                    Self.append(orphan, to: document)
                    appendedIds.insert(orphan.id)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        } else {
            Text(Self.documentClosedReason)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func appendAll() {
        guard let document else { return }
        for orphan in report.orphans where !appendedIds.contains(orphan.id) {
            Self.append(orphan, to: document)
            appendedIds.insert(orphan.id)
        }
    }
}
