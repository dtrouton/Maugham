import Foundation

/// `link_research(project_id, research_id, document_id)` — connect a research
/// item to a manuscript document. Idempotent (re-linking is a no-op). Wraps
/// ProjectStore.linkResearch which writes the manifest and triggers autosave.
public enum LinkResearchTool {
    public static let method = "link_research"

    public struct Params: Codable {
        public let project_id: String
        public let research_id: String
        public let document_id: String
    }
    public struct Result: Codable, Equatable {
        public let linked: Bool
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id, research_id, document_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        try await entry.store.linkResearch(
            researchId: params.research_id, toDocumentId: params.document_id)
        return try JSONEncoder().encode(Result(linked: true))
    }
}

/// `unlink_research(project_id, research_id, document_id)` — remove a link.
/// Idempotent (unlinking an absent link is a no-op).
public enum UnlinkResearchTool {
    public static let method = "unlink_research"

    public struct Params: Codable {
        public let project_id: String
        public let research_id: String
        public let document_id: String
    }
    public struct Result: Codable, Equatable {
        public let linked: Bool
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id, research_id, document_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        try await entry.store.unlinkResearch(
            researchId: params.research_id, fromDocumentId: params.document_id)
        return try JSONEncoder().encode(Result(linked: false))
    }
}
