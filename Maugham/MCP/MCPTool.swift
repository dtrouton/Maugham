import Foundation

/// Single source of truth for an MCP tool. Each conformer co-locates its
/// catalog metadata (name, description, JSON-Schema) with its handler. The
/// `MCPToolCatalog.all` list is the only place tools are enumerated; both
/// the `tools/list` response and the router registration derive from it.
///
/// Adding a new tool: implement `MCPTool` on the tool type, then add the
/// type to `MCPToolCatalog.all`. The protocol's static requirements make
/// drift between catalog and dispatcher physically impossible.
public protocol MCPTool {
    /// The MCP method name surfaced to clients (e.g. `"list_projects"`).
    static var method: String { get }

    /// Human-readable description shown in `tools/list`. Read by Claude
    /// Desktop and other MCP clients to decide when to call the tool.
    static var description: String { get }

    /// JSON-Schema for the tool's input, encoded as a JSON string. Kept
    /// as a string (not a Swift type) because schemas are small, rarely
    /// change, and benefit from being inspected verbatim during review.
    /// `MCPCatalogConsistencyTests` asserts every entry parses.
    static var inputSchemaJSON: String { get }

    /// Dispatch entry point. Receives the raw `params` JSON from the MCP
    /// request and the live `ProjectRegistry` for resolving project IDs.
    /// `@MainActor` because tools read the project graph, which lives on
    /// the main actor.
    @MainActor
    static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data
}

/// The single, ordered list of MCP tools the app exposes. Both
/// `MCPToolsListHandler` and `MaughamApp.registerTools` derive from this.
public enum MCPToolCatalog {
    public static let all: [any MCPTool.Type] = [
        ListProjectsTool.self,
        GetMetadataTool.self,
        GetOutlineTool.self,
        ReadDocumentTool.self,
        SearchTextTool.self,
        ListScenesTool.self,
        FindReferencesTool.self,
        GetSessionStatsTool.self,
        AddNoteTool.self,
        ListResearchTool.self,
        ListDocumentsByTagTool.self,
        LinkResearchTool.self,
        UnlinkResearchTool.self,
        ListAllLinksTool.self,
        AddCommentTool.self,
        AddSuggestedChangeTool.self,
        AddQueryTool.self,
        AddCraftNoteTool.self,
        ListAnnotationsTool.self,
        GetAnnotationTool.self,
        ListTasksTool.self,
        GetTaskTool.self,
        InitializePublishTemplateTool.self,
        GetPublishConfigTool.self,
        SetPublishConfigTool.self,
        ListPublishFilesTool.self,
        ReadPublishFileTool.self,
        ReadPublishImageTool.self,
        WritePublishFileTool.self,
        DeletePublishFileTool.self,
        CompileTool.self,
        PreviewCompileTool.self,
        CompileStatusTool.self,
        CompileCancelTool.self,
        ListPublicationsTool.self,
        ReadPublicationPageTool.self,
        RepublishTool.self,
        SetPieceStyleTool.self,
        ClearPieceStyleTool.self,
        ListInboxTool.self,
        ReadInboxEntryTool.self,
        PromoteInboxEntryTool.self,
        ListMaughamToolsTool.self,
        GetHelpTool.self
    ]

    /// Registers every catalog tool on the given router. Called from
    /// `MaughamApp` for production and from `MCPCatalogConsistencyTests`
    /// for the seam test — both use the same path so drift is impossible.
    @MainActor
    public static func register(router: MCPRouter, registry: ProjectRegistry) {
        for tool in all {
            router.register(method: tool.method) { params in
                try await tool.handle(paramsJSON: params, registry: registry)
            }
        }
    }
}
