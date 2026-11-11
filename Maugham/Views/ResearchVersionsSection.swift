import SwiftUI
import MaughamCore

/// **A Research table's, note's or palette card's kept versions as the inspector lists them** (report
/// plan 9d Task 6, spec §10.1): newest first, the assistant's marked, with
/// *Restore previous version* (the newest) and a Restore on each row.
/// Everything a row says is worked out once here (tripwire 4), from the
/// version list and the clock, so the view only draws. A view-only share or
/// Review lists the versions with Restore disabled and says why.
enum ResearchVersionsModel {
    struct Row: Identifiable, Equatable {
        let id: String
        let version: ResearchVersion
        /// When the replaced state was saved, e.g. "Oct 31, 2026 at 3:04 PM".
        let when: String
        /// "Written by assistant" for a version whose bytes the assistant
        /// wrote; else nil.
        let mark: String?
        /// "Before the assistant’s change" for the state an assistant's write
        /// replaced; else nil.
        let replacedMark: String?
        let canRestore: Bool
    }

    static let assistantMark = "Written by assistant"
    static let beforeAssistantMark = "Before the assistant’s change"

    /// Why Restore is off, nil when it is on: a view-only share first, then
    /// Review (whose grid reads the table and refuses its edits) — the grid's
    /// own reasons and sentences (`FigureGridGate.Reason`).
    static func restoreRefusal(shareIsReadOnly: Bool, reviewing: Bool) -> FigureGridGate.Reason? {
        if shareIsReadOnly { return .viewOnlyShare }
        if reviewing { return .reviewMode }
        return nil
    }

    /// One row per version, in the order given (newest first); none restores
    /// while there is a `refusal`.
    /// A version of another kind than `kind` (the item's) is listed, not restorable.
    static func rows(from versions: [ResearchVersion], refusal: FigureGridGate.Reason?,
                     kind: ResearchVersionPayload = .table,
                     format: (Date) -> String = defaultFormat) -> [Row] {
        versions.map { v in
            Row(id: v.name, version: v, when: format(v.savedAt),
                mark: v.writtenBy == .assistant ? assistantMark : nil,
                replacedMark: v.replacedBy == .assistant ? beforeAssistantMark : nil,
                canRestore: refusal == nil && v.payload == kind)
        }
    }

    /// The line under an empty list — nil while the first listing loads
    /// (`rows` nil), so nothing flashes before the versions arrive.
    static func emptyLine(for rows: [Row]?) -> String? {
        rows?.isEmpty == true ? "No earlier versions yet." : nil
    }

    /// *Restore previous version*: the newest kept version, nil when there is
    /// none or Restore is refused.
    static func previous(in rows: [Row]) -> Row? {
        rows.first(where: \.canRestore)
    }

    /// What the Versions section lists for `item`: a table's, or a note's or
    /// palette card's (both text, kept by the note door), kept versions; nil
    /// for anything else (no section).
    static func kind(for item: ResearchItem, structure: [StructureItem]) -> ResearchVersionPayload? {
        if item.kind == .table, item.type == .asset { return .table }
        if ResearchNoteDoor.takes(item, structure: structure) { return .note }
        return nil
    }

    /// What a refusal calls `item`: "table", "card" or "note".
    static func noun(for item: ResearchItem, structure: [StructureItem]) -> String {
        if item.kind == .table { return "table" }
        if case .paletteCard = ResearchTextRole.of(item, structure: structure) { return "card" }
        return "note"
    }

    static let restored = "Restored."

    static func defaultFormat(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// What a restore says when it landed.
    static func sentence(for outcome: ResearchTableHost.Restored) -> String {
        switch outcome {
        case .whole: return restored
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
    /// Which kind of item this is (`ResearchVersionsModel.kind(for:)`).
    var kind: ResearchVersionPayload = .table
    /// What a refusal calls it (`ResearchVersionsModel.noun(for:)`).
    var noun: String = "table"
    /// The persona reads Research without changing it (Review).
    var reviewing: Bool = false

    /// Nil until the first listing lands.
    @State private var rows: [ResearchVersionsModel.Row]?
    @State private var message: String?
    @State private var isRestoring = false

    var body: some View {
        let refusal = ResearchVersionsModel.restoreRefusal(shareIsReadOnly: shareIsReadOnly, reviewing: reviewing)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Versions").font(.headline)
                Spacer()
                Button("Restore previous version") {
                    if let row = ResearchVersionsModel.previous(in: rows ?? []) { restore(row) }
                }
                .disabled(ResearchVersionsModel.previous(in: rows ?? []) == nil || isRestoring)
            }
            if let refusal {
                Text(refusal.sentence(noun: noun)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let empty = ResearchVersionsModel.emptyLine(for: rows) {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows ?? []) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.when).font(.callout)
                        if let mark = row.replacedMark {
                            Text(mark).font(.caption).foregroundStyle(.secondary)
                        }
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
        .task(id: Reload(revision: store.researchVersionsRevision, refusal: refusal)) {
            let versions = await ResearchVersionsModel.load(projectURL: store.projectURL, itemId: itemId)
            guard !Task.isCancelled else { return }
            rows = ResearchVersionsModel.rows(from: versions, refusal: refusal, kind: kind)
        }
    }

    /// What re-lists the versions: a kept version, or Restore turning on or off.
    private struct Reload: Equatable {
        let revision: Int
        let refusal: FigureGridGate.Reason?
    }

    private func restore(_ row: ResearchVersionsModel.Row) {
        isRestoring = true
        message = nil
        Task { @MainActor in
            defer { isRestoring = false }
            do {
                switch kind {
                case .table:
                    let outcome = try await store.restoreResearchTable(
                        itemId: itemId, to: row.version, shareIsReadOnly: shareIsReadOnly)
                    message = ResearchVersionsModel.sentence(for: outcome)
                case .note:
                    try await store.restoreResearchNote(
                        itemId: itemId, to: row.version, shareIsReadOnly: shareIsReadOnly)
                    message = ResearchVersionsModel.restored
                }
            } catch {
                message = "Couldn’t restore that version: \(error.localizedDescription)"
            }
        }
    }
}
