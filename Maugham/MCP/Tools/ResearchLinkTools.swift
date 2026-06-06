import Foundation

/// `link_research(project_id, research_id, document_id)` — connect a research
/// item to a manuscript document. Idempotent (re-linking is a no-op). Wraps
/// ProjectStore.linkResearch which writes the manifest and triggers autosave.
public enum LinkResearchTool: MCPTool {
    public static let method = "link_research"
    public static let description =
        "Link a research item to a manuscript document so it shows up in the " +
        "Inspector. Idempotent. Use get_outline + list_research to find ids."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"research_id":{"type":"string"},"document_id":{"type":"string"}},"required":["project_id","research_id","document_id"]}"#

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
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        try await entry.store.linkResearch(
            researchId: params.research_id, toDocumentId: params.document_id)
        return try JSONEncoder().encode(Result(linked: true))
    }
}

/// `unlink_research(project_id, research_id, document_id)` — remove a link.
/// Idempotent (unlinking an absent link is a no-op).
public enum UnlinkResearchTool: MCPTool {
    public static let method = "unlink_research"
    public static let description =
        "Remove a research-to-document link. Idempotent (no-op if the link doesn't exist)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"research_id":{"type":"string"},"document_id":{"type":"string"}},"required":["project_id","research_id","document_id"]}"#

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
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        try await entry.store.unlinkResearch(
            researchId: params.research_id, fromDocumentId: params.document_id)
        return try JSONEncoder().encode(Result(linked: false))
    }
}
