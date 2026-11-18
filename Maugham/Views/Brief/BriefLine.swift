import Foundation
import MaughamCore

/// **The Brief in a sentence** — the one line the corkboard card, the outline,
/// the line above the prose and the MCP listing all show for a piece.
///
/// The stored `StructureItem.synopsis` IS the line: a project written before
/// Brief needs no migration. When it is absent the line is the opening of the
/// piece's intent, by `IntentStrip.line(from:)` — the one opening rule (first
/// prose line, headings skipped, at most `IntentStrip.maximumLength`
/// characters, cut at a word boundary), never a second copy of it.
enum BriefLine {

    /// The trimmed synopsis, else the opening of `intentEssay`, else nil.
    ///
    /// A synopsis that trims to empty is ABSENT: `updateInspector` cannot clear
    /// the field to nil and stores `""`, so an emptied line must fall back
    /// exactly as a never-written one does.
    static func display(synopsis: String?, intentEssay: String?) -> String? {
        if let stored = synopsis?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        return IntentStrip.line(from: intentEssay)
    }

    /// The stored synopsis as Brief's line field shows it: nil when it trims
    /// to empty.
    static func stored(_ synopsis: String?) -> String? {
        guard let trimmed = synopsis?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// **When the line index must be rebuilt**: the manifest changed (a
    /// synopsis, the structure), a statement's text changed out of sight
    /// (`ProjectStore.statementTextRevision`), or a statement open in a pane
    /// was typed in (its live `displayText`). A view keys `.task(id:)` on it.
    struct RefreshKey: Hashable {
        let manifestModified: Date
        let statementRevision: Int
        /// Statement id → its open pane's current text.
        let liveStatementTexts: [String: String]
    }

    /// The key, read in `body`: two stored values and the open statement
    /// panes' texts (one or two, never one per row). Reading a live
    /// `Document`'s `displayText` here is what makes typing in a pane
    /// invalidate the view.
    @MainActor
    static func refreshKey(store: ProjectStore) -> RefreshKey {
        RefreshKey(
            manifestModified: store.manifest.modified,
            statementRevision: store.statementTextRevision,
            liveStatementTexts: Dictionary(
                store.openStatementDocuments.keys.compactMap { id in
                    store.openStatementDocument(id: id).map { (id, $0.displayText) }
                },
                uniquingKeysWith: { first, _ in first }))
    }

    /// `docId → line` for every item of the structure that has one. **Built in
    /// a `.task`, never in `body` or per row** (tripwire 4;
    /// `BriefLineTests.test_theLineIndexIsBuiltOutsideBody`): it reads a
    /// statement per piece.
    ///
    /// A document falls back to ITS OWN intent (`.document(id)`), never the
    /// effective one: a chapter with no intent of its own showing the book's
    /// opening on every card is not that chapter's line (Denver's controller
    /// ruling, 2026-11-18). **The line above the prose differs on purpose**:
    /// `IntentStrip.line(store:…)` falls back to the EFFECTIVE intent, as it
    /// always has — it is the running head of the one piece being written,
    /// where the book's sentence is what applies. A group has no intent
    /// and shows only its synopsis. An unreadable intent (RULING-54) gives no
    /// fallback — a card's line is chrome, as the strip's is; Brief names it.
    @MainActor
    static func index(store: ProjectStore) -> [String: String] {
        var lines: [String: String] = [:]
        for item in TreeWalk.collect(in: store.manifest.structure, where: { _ in true }) {
            let essay: String?
            if item.type == .document, stored(item.synopsis) == nil,
               let intent = store.statement(kind: .intent, scope: .document(item.id)),
               let text = try? store.statementText(of: intent) {
                essay = StatementEssay.half(of: text)
            } else {
                essay = nil
            }
            if let line = display(synopsis: item.synopsis, intentEssay: essay) {
                lines[item.id] = line
            }
        }
        return lines
    }
}
