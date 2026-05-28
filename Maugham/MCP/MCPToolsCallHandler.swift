import Foundation

/// MCP `tools/call` handler. Unwraps `{name, arguments}` and dispatches to
/// the underlying tool handler via the router, then wraps the result.
///
/// **Error surface contract:** every failure from a tool handler — whether
/// `MCPError.toolError`, `.invalidArgument`, `.internalError`,
/// `.projectNotOpen`, or any other Swift error — becomes a tool result
/// with `isError: true` and a structured `{error, message, hint?, ...}`
/// payload as the text content. Only true protocol-level failures
/// (`MCPRouterError.methodNotFound`, malformed `tools/call` params)
/// continue to throw as JSON-RPC errors. This is what keeps generic MCP
/// clients (Claude Desktop) from rendering tool failures as a flat
/// "Tool execution failed" with no actionable detail.
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
            // Protocol-level: malformed tools/call envelope. Stays as JSON-RPC.
            throw MCPError.invalidArgument("name and arguments required")
        }
        // Re-encode arguments as Data for the underlying handler.
        let argsData: Data?
        if let args = params.arguments {
            argsData = try JSONEncoder().encode(args)
        } else {
            argsData = nil
        }
        do {
            let resultData = try await router.dispatch(
                method: params.name, paramsJSON: argsData)
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
        } catch MCPRouterError.methodNotFound(let name) {
            // Protocol-level: method not registered. Rethrow so it surfaces
            // as a JSON-RPC -32601-style error rather than a tool result.
            throw MCPRouterError.methodNotFound(name)
        } catch {
            // Tool-handler failure. Convert to structured isError=true result.
            let payload = toolErrorPayload(for: error)
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
    }

    /// Map any error thrown from a tool handler into a structured payload.
    /// Tools that build a payload via `MCPError.toolError` pass through
    /// unchanged; legacy MCPError cases and generic Swift errors are
    /// converted to consistent shapes so agents always see actionable
    /// `{error, message, hint?, ...}` instead of a flat "Tool execution
    /// failed". Public so individual tools or tests can preview the
    /// rendered shape without round-tripping through the router.
    public static func toolErrorPayload(for error: Error) -> MCPError.ToolErrorPayload {
        switch error {
        case let MCPError.toolError(payload):
            return payload
        case let MCPError.invalidArgument(message):
            return .init(
                error: "invalid_argument",
                message: message)
        case let MCPError.internalError(message):
            return .init(
                error: "internal_error",
                message: message)
        case MCPError.projectNotOpen:
            return .init(
                error: "project_not_open",
                message: MCPError.projectNotOpen.message,
                hint: "Call list_projects to refresh project IDs, or open the project in Maugham.")
        case MCPError.maughamNotRunning:
            return .init(
                error: "maugham_not_running",
                message: MCPError.maughamNotRunning.message)
        case MCPError.mcpDisabled:
            return .init(
                error: "mcp_disabled",
                message: MCPError.mcpDisabled.message,
                hint: "Enable MCP in Maugham → Settings.")
        default:
            return .init(
                error: "internal_error",
                message: "\(error)")
        }
    }
}
