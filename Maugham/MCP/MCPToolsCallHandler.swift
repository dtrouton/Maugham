import Foundation

/// MCP `tools/call` handler. Unwraps `{name, arguments}` and dispatches to
/// the underlying tool handler via the router, then wraps the result as
/// MCP content blocks (`{content: [{type: "text", text: <JSON>}]}`).
public enum MCPToolsCallHandler {
    public static let method = "tools/call"

    public struct Params: Codable {
        public let name: String
        public let arguments: AnyJSON?
    }

    @MainActor
    public static func handle(paramsJSON: Data?, router: MCPRouter) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("name and arguments required")
        }
        // Re-encode arguments as Data for the underlying handler.
        let argsData: Data?
        if let args = params.arguments {
            argsData = try JSONEncoder().encode(args)
        } else {
            argsData = nil
        }
        let resultData = try await router.dispatch(
            method: params.name, paramsJSON: argsData)
        // Wrap as MCP content. The underlying tool returned arbitrary JSON;
        // we stringify and pass it as a text block so Claude can display
        // structured results in the conversation.
        let asText = String(data: resultData, encoding: .utf8) ?? "{}"
        let wrapped = AnyJSON.object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(asText)
                ])
            ])
        ])
        return try JSONEncoder().encode(wrapped)
    }
}
