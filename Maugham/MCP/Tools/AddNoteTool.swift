import Foundation

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
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id, title, body required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let store = entry.store

        // Validate parent group if supplied
        if let parentId = params.parent_group_id {
            if !Self.groupExists(id: parentId, in: store.manifest.research) {
                throw MCPError.invalidArgument("parent_group_id not found: \(parentId)")
            }
        }

        // Use the existing research-create path — creates an empty .md file
        // with slug dedup, manifest mutation, autosave behavior identical to
        // New Text Note in the binder.
        let created = try await store.addResearchTextNote(
            parentId: params.parent_group_id,
            title: params.title)

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

    private static func groupExists(id: String, in items: [ResearchItem]) -> Bool {
        for item in items {
            if item.id == id && item.type == .group { return true }
            if let kids = item.children, groupExists(id: id, in: kids) { return true }
        }
        return false
    }
}
