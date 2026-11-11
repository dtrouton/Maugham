import Foundation
import MaughamCore

/// `update_note(project_id, research_id, body)` — **the assistant replaces an
/// existing Research note's body** (ADR 0034), through the note door
/// (`DocumentStore.saveResearchNote(by: .assistant)`): the text it replaces
/// (the writer's unsaved edit included) is always kept as a version marked
/// "Before the assistant’s change", restorable from the inspector, and an
/// editor open on the note reloads. Research notes only — never the
/// manuscript, a palette card or a table — and never a raw file write.
public enum UpdateNoteTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let research_id: String
        public let body: String
    }
    /// Names the note; never carries its body (tripwire 10).
    public struct Result: Codable, Equatable {
        public let id: String
        public let title: String
        public let path: String
        public let kept_previous_version: Bool
    }
    public static let method = "update_note"
    public static let description =
        "Replace the whole body of an existing Research note (.md) with `body`, as the assistant. " +
        "The text it replaces, including any edit the writer has not saved yet, is kept as a version " +
        "marked \"Before the assistant’s change\" that the writer can restore from the note's inspector " +
        "(Versions). Read the note first with read_document; find its id with list_research. " +
        "Research notes only: never the manuscript, a palette card, or a Research table " +
        "(use write_research_cells). To create a note, use add_note."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"research_id":{"type":"string","description":"A Research note's id, from list_research."},"body":{"type":"string","description":"The note's whole new text (Markdown)."}},"required":["project_id","research_id","body"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        // Nothing is read or written before this.
        try MCPShareLock.refuseUnderAViewOnlyShare(
            entry.url, sentence: "This share is view-only, so a research note can’t be changed.")
        let store = entry.store
        let item = try noteItem(params.research_id, in: store)
        guard let ds = store.documentStore else {
            throw MCPError.invalidArgument("The project's window is not ready for a Research note.")
        }

        // The one door: no fallback, no retry. It has already told the
        // writer why in a notice when it could not save.
        guard case .saved(let kept) = await ds.saveResearchNote(
            itemId: item.id, text: params.body, by: .assistant) else {
            throw MCPError.invalidArgument(
                "'\(item.title)' (\(item.id)) wasn’t changed: Maugham couldn’t save it (the project’s window says why).")
        }
        // Asked again: the note may have moved while the save was awaited.
        let now = store.findResearchItem(id: item.id, in: store.manifest.research) ?? item
        let result = Result(id: now.id, title: now.title, path: now.path ?? "",
                            kept_previous_version: kept)
        return try JSONEncoder().encode(result)
    }

    /// The Research note `id` names, or a refusal that says what the id is
    /// instead. Asked of `ResearchTextRole` directly, not of the door's
    /// `takes`: the door takes palette cards too (they keep versions since
    /// 2026-11-11), and a card is never the assistant's to write (ADR 0034).
    @MainActor
    static func noteItem(_ id: String, in store: ProjectStore) throws -> ResearchItem {
        guard let item = store.findResearchItem(id: id, in: store.manifest.research) else {
            throw MCPError.invalidArgument(notInResearch(id, in: store))
        }
        let role = ResearchTextRole.of(item, structure: store.manifest.structure)
        if case .note = role { return item }
        throw MCPError.invalidArgument("'\(item.title)' (\(id)) \(whatItIs(item, role: role))")
    }

    /// An id outside Research: a manuscript document, a figure or a statement
    /// is named as such (MCP never writes manuscript text); anything else is unknown.
    @MainActor
    private static func notInResearch(_ id: String, in store: ProjectStore) -> String {
        let manifest = store.manifest
        if let doc = TreeWalk.find(id: id, in: manifest.structure) {
            return "'\(doc.title)' (\(id)) is a manuscript document, not a Research note; "
                + "Claude never changes manuscript text. Suggest a change with add_suggested_change."
        }
        if let figure = manifest.figures?.first(where: { $0.id == id }) {
            return "'\(figure.name)' (\(id)) is a figure, not a Research note; read it with read_figure."
        }
        if manifest.statements.contains(where: { $0.id == id }) {
            return "\(id) is a statement, not a Research note; a statement is the writer’s to change."
        }
        return "No Research item with id '\(id)'. Use list_research for the ids."
    }

    /// What a Research item that is not a note is, and where to go instead.
    private static func whatItIs(_ item: ResearchItem, role: ResearchTextRole?) -> String {
        if case .paletteCard = role {
            return "is a palette card, not a note; read it with read_palette_card."
        }
        switch item.type {
        case .group:
            return "is a Research group, not a note; add a note to it with add_note and parent_group_id."
        case .asset:
            switch item.kind {
            case .table: return "is a Research table, not a note; use write_research_cells."
            case .image: return "is a picture in Research, not a note; only a note’s text can be changed."
            case .pdf: return "is a PDF in Research, not a note; only a note’s text can be changed."
            case .audio: return "is a recording in Research, not a note; only a note’s text can be changed."
            case .link: return "is a web link in Research, not a note; only a note’s text can be changed."
            case .document where item.path == nil:
                return "has no file of its own, so it is not a note whose text can be changed."
            case .document:
                // Listed in Research, but its file is not in a Research
                // folder (the manuscript, Maugham's own files): never written.
                return "is not a Research note Maugham can change: its file is not in a Research folder."
            case nil:
                return "is not a Research note; only a note’s text can be changed."
            }
        }
    }
}
