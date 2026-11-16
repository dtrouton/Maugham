import Foundation
import MaughamCore

/// `add_note(project_id, title, body, parent_group_id?)` — creates a `.document`
/// research item under `research/` and posts maughamMCPNoteAdded for the UI.
public enum AddNoteTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let title: String
        public let body: String
        public let parent_group_id: String?
    }
    public struct Result: Codable, Equatable {
        public let id: String
        public let title: String
        public let path: String
    }
    public static let method = "add_note"
    public static let description =
        "Create a research note (.md) under the project's research folder. " +
        "Optionally placed in an existing group, but never the Palette: cards are the writer's."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"title":{"type":"string"},"body":{"type":"string"},"parent_group_id":{"type":"string"}},"required":["project_id","title","body"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        try MCPShareLock.refuseUnderAViewOnlyShare(
            entry.url, sentence: "This share is view-only, so a research note can’t be added.")
        let store = entry.store

        // Validate parent group if supplied
        if let parentId = params.parent_group_id {
            let exists = TreeWalk.first(in: store.manifest.research, where: {
                $0.id == parentId && $0.type == .group
            }) != nil
            if !exists {
                throw MCPError.invalidArgument("parent_group_id not found: \(parentId)")
            }
            // The Palette holds the writer's cards, whatever the group is
            // called (role-first), and the assistant writes notes only
            // (ADR 0034; #141 N1, RULING-61): refused before anything exists.
            if parentId == PaletteLookup.paletteGroup(in: store.manifest.research)?.id {
                throw MCPError.invalidArgument(
                    "The Palette holds the writer's cards; add_note can't create one. "
                    + "Add the note to another Research group.")
            }
        }

        // Use the existing research-create path — creates an empty .md file
        // with slug dedup, manifest mutation, autosave behavior identical to
        // New Text Note in the binder.
        let created = try await store.addResearchTextNote(
            parentId: params.parent_group_id,
            title: params.title)

        // Drain any pending `scheduleFileSave` for this project BEFORE writing
        // the body. Without this flush, a queued 750ms debounce (e.g. the user
        // was editing a research note that happened to share the same path as
        // the new file) can fire AFTER the body write and overwrite it with
        // empty content — the classic tripwire-14 research-note race.
        // `flushPendingSave` is a no-op when documentStore is nil (tests that
        // don't wire a DocumentStore) or when no save is pending.
        try? await store.documentStore?.flushPendingSave()

        // Write the supplied body to the freshly-created file — through the
        // note door when a store is wired, as the assistant's (#141 N5), so
        // the writer's first edit keeps it marked as the assistant's. It
        // must land: the note already exists, and nothing over it is lost
        // (the file was just made empty).
        if let documentStore = store.documentStore {
            guard case .saved = await documentStore.saveResearchNote(
                itemId: created.id, text: params.body, by: .assistant, mustLand: true, from: store) else {
                throw ProjectStoreError.researchTextNotSaved(title: created.title)
            }
        } else {
            // Never given a store: the raw write. Lost it (teardown): refused,
            // never raw (#141 N6).
            guard store.rawNoteWriteWithNoDoor() == .allowed else {
                throw ProjectStoreError.noteWriteRefusedAsTheProjectCloses
            }
            if let path = created.path {
                let absURL = try ProjectStore.resolvedProjectPathToChange(path, under: entry.url)
                try params.body.write(to: absURL, atomically: true, encoding: .utf8)  // raw-research-text: no-door fallback
            }
        }

        // Project-scoped (ADR 0021): the project id that was manual payload +
        // a receiver-side compare is now the delivery scope itself.
        MaughamEvent.post(
            .maughamMCPNoteAdded,
            to: .project(id: params.project_id),
            payload: [
                "research_id": created.id,
                "title": created.title
            ])

        let result = Result(id: created.id, title: created.title, path: created.path ?? "")
        return try JSONEncoder().encode(result)
    }
}
