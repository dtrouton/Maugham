import SwiftUI
import MaughamCore

/// **A Research table's kept versions as the inspector lists them** (report
/// plan 9d Task 6, spec §10.1): newest first, the assistant's marked, with
/// *Restore previous version* (the newest) and a Restore on each row.
/// Everything a row says is worked out once here (tripwire 4), from the
/// version list and the clock, so the view only draws.
enum ResearchVersionsModel {
    struct Row: Identifiable, Equatable {
        let id: String
        let version: ResearchVersion
        /// When the replaced state was saved, e.g. "Oct 31, 2026 at 3:04 PM".
        let when: String
        /// "Written by assistant" for a version the assistant wrote; else nil.
        let mark: String?
        let canRestore: Bool
    }

    static let assistantMark = "Written by assistant"

    /// One row per version, in the order given (newest first). A view-only
    /// share restores nothing.
    static func rows(from versions: [ResearchVersion], viewOnly: Bool,
                     format: (Date) -> String = defaultFormat) -> [Row] {
        versions.map { v in
            Row(id: v.name, version: v, when: format(v.savedAt),
                mark: v.writtenBy == .assistant ? assistantMark : nil,
                canRestore: !viewOnly)
        }
    }

    /// *Restore previous version*: the newest kept version, nil when there is
    /// none or the share is view-only.
    static func previous(in rows: [Row]) -> Row? {
        rows.first(where: \.canRestore)
    }

    static func defaultFormat(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// What a restore says when it landed.
    static func sentence(for outcome: ResearchTableHost.Restored) -> String {
        switch outcome {
        case .whole: return "Restored."
        case .cellsOnly: return "Restored the cells; that version’s formats and widths couldn’t be restored."
        }
    }

    /// The versions, listed off the main actor.
    static func load(projectURL: URL, itemId: String) async -> [ResearchVersion] {
        await Task.detached {
            ResearchVersionStore(projectURL: projectURL).versions(itemId: itemId)
        }.value
    }
}

struct ResearchVersionsSection: View {
    let store: DocumentStore
    let itemId: String
    let shareIsReadOnly: Bool

    @State private var rows: [ResearchVersionsModel.Row] = []
    @State private var message: String?
    @State private var isRestoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Versions").font(.headline)
                Spacer()
                Button("Restore previous version") {
                    if let row = ResearchVersionsModel.previous(in: rows) { restore(row) }
                }
                .disabled(ResearchVersionsModel.previous(in: rows) == nil || isRestoring)
            }
            if rows.isEmpty {
                Text("No earlier versions yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.when).font(.callout)
                        if let mark = row.mark {
                            Text(mark).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Restore") { restore(row) }
                        .disabled(!row.canRestore || isRestoring)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: store.researchVersionsRevision) {
            let versions = await ResearchVersionsModel.load(projectURL: store.projectURL, itemId: itemId)
            rows = ResearchVersionsModel.rows(from: versions, viewOnly: shareIsReadOnly)
        }
    }

    private func restore(_ row: ResearchVersionsModel.Row) {
        isRestoring = true
        message = nil
        Task { @MainActor in
            defer { isRestoring = false }
            do {
                let outcome = try await store.restoreResearchTable(
                    itemId: itemId, to: row.version, shareIsReadOnly: shareIsReadOnly)
                message = ResearchVersionsModel.sentence(for: outcome)
            } catch {
                message = "Couldn’t restore that version: \(error.localizedDescription)"
            }
        }
    }
}
