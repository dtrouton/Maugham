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
        let resultData: Data
        do {
            resultData = try await router.dispatch(
                method: params.name, paramsJSON: argsData)
        } catch let MCPError.toolError(payload) {
            // MCP tool-execution failures: return as a result with
            // isError=true and the structured payload as the text block.
            // The agent can then parse the JSON and route on `error` /
            // `hint` rather than getting a generic "Tool execution
            // failed" from the JSON-RPC error path.
            let text = String(data: payload.encodedJSON(), encoding: .utf8) ?? "{}"
            let envelope = AnyJSON.object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ]),
                "isError": .bool(true)
            ])
            return try JSONEncoder().encode(envelope)
        }
        // Polymorphic wrapping: if the tool already returned an MCP envelope
        // (a JSON object with a top-level `content` array), pass it through.
        // This lets tools emit non-text content blocks (image, etc.) without
        // every tool needing to know about the envelope shape.
        if let obj = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
           obj["content"] is [Any] {
            return resultData
        }
        // Default: wrap arbitrary JSON as a text content block.
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
