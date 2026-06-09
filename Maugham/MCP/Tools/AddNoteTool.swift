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
        "Optionally placed in an existing group."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"title":{"type":"string"},"body":{"type":"string"},"parent_group_id":{"type":"string"}},"required":["project_id","title","body"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let store = entry.store

        // Validate parent group if supplied
        if let parentId = params.parent_group_id {
            let exists = TreeWalk.first(in: store.manifest.research, where: {
                $0.id == parentId && $0.type == .group
            }) != nil
            if !exists {
                throw MCPError.invalidArgument("parent_group_id not found: \(parentId)")
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

        // Write the supplied body to the freshly-created file.
        if let path = created.path {
            let absURL = entry.url.appendingPathComponent(path)
            try params.body.write(to: absURL, atomically: true, encoding: .utf8)
        }

        NotificationCenter.default.post(
            name: .maughamMCPNoteAdded,
            object: nil,
            userInfo: [
                "project_id": params.project_id,
                "research_id": created.id,
                "title": created.title
            ])

        let result = Result(id: created.id, title: created.title, path: created.path ?? "")
        return try JSONEncoder().encode(result)
    }
}
