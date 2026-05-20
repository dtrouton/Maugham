import Foundation

/// Maugham-specific MCP error codes. Plain JSON-RPC errors (-32600..-32603)
/// are returned without going through this enum.
public enum MCPError: Error, Equatable {
    case maughamNotRunning      // -32001: binary couldn't reach socket
    case projectNotOpen         // -32002: project_id not in registry
    case mcpDisabled            // -32003: user toggled off in Settings
    case invalidArgument(String)// -32602: param decoding / validation failure
    case internalError(String)  // -32603: unexpected
    /// Structured tool-result error. Per the MCP spec, tool execution
    /// failures should be returned as a tools/call result with
    /// `isError: true` so the calling agent can read structured fields
    /// (`error` code, `hint`, etc.) from the result content — not as a
    /// JSON-RPC error, which generic MCP clients tend to surface as a
    /// flat "Tool execution failed" with no actionable detail.
    ///
    /// `MCPToolsCallHandler` catches this case and emits the proper tool
    /// result envelope; other MCPError cases continue to throw through
    /// and become JSON-RPC errors (right for protocol-level failures
    /// like projectNotOpen / mcpDisabled).
    case toolError(payload: ToolErrorPayload)

    public var code: Int {
        switch self {
        case .maughamNotRunning: return -32001
        case .projectNotOpen:    return -32002
        case .mcpDisabled:       return -32003
        case .invalidArgument:   return -32602
        case .internalError:     return -32603
        case .toolError:         return -32099  // not reachable via JSON-RPC error path
        }
    }

    public var message: String {
        switch self {
        case .maughamNotRunning:     return "Maugham isn't running."
        case .projectNotOpen:        return "That project isn't open in Maugham."
        case .mcpDisabled:           return "Maugham's MCP connection is turned off in Settings."
        case .invalidArgument(let m):return "Invalid argument: \(m)"
        case .internalError(let m):  return "Internal error: \(m)"
        case .toolError(let p):      return p.message
        }
    }

    // MARK: - Structured tool errors

    /// Machine-readable + human-readable error payload carried by
    /// `.toolError` cases. JSON-encoded as the text content of an
    /// isError-marked tool result so MCP clients can route on `error`
    /// (the code) and act on `hint`.
    public struct ToolErrorPayload: Equatable, Sendable {
        public let error: String              // machine code, e.g. "paragraph_not_found"
        public let message: String            // human-readable summary
        public let hint: String?              // suggested next action for the agent
        public let fields: [String: String]   // arbitrary string-keyed context

        public init(
            error: String, message: String,
            hint: String? = nil, fields: [String: String] = [:]
        ) {
            self.error = error
            self.message = message
            self.hint = hint
            self.fields = fields
        }

        /// JSON-encode the payload for embedding as a tool result's text
        /// content block. Stable key ordering (alphabetical) so clients
        /// can string-match deterministically.
        public func encodedJSON() -> Data {
            var obj: [String: AnyJSON] = [
                "error":   .string(error),
                "message": .string(message),
            ]
            if let hint { obj["hint"] = .string(hint) }
            for (k, v) in fields { obj[k] = .string(v) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(AnyJSON.object(obj))) ?? Data("{}".utf8)
        }
    }

    // MARK: - Convenience constructors

    /// `paragraph_not_found` — caller passed a paragraph_id that isn't in
    /// the current document sequence. Most common cause: the agent cached
    /// IDs from an earlier read_document response and the document has
    /// been edited since. IDs in Maugham are stable across small edits
    /// (kept by exact match or character-bigram match ≥ 0.6) but can
    /// change when a paragraph is deleted, split, or substantially
    /// rewritten — so the contract is "re-read after substantial edits."
    public static func paragraphNotFound(
        paragraphId: String, currentCount: Int
    ) -> MCPError {
        .toolError(payload: .init(
            error: "paragraph_not_found",
            message: "Paragraph '\(paragraphId)' is not in the current document sequence.",
            hint: "Call read_document to refresh paragraph anchors and retry with a current id. Paragraph ids are stable across small edits but can change when a paragraph is deleted, split, or substantially rewritten.",
            fields: [
                "paragraph_id": paragraphId,
                "current_paragraph_count": String(currentCount)
            ]))
    }

    /// `prior_text_capture_failed` — paragraph exists in the sequence
    /// but its text snapshot couldn't be captured. Indicates an internal
    /// consistency bug; defensive check for the future.
    public static func priorTextCaptureFailed(
        paragraphId: String
    ) -> MCPError {
        .toolError(payload: .init(
            error: "prior_text_capture_failed",
            message: "Paragraph '\(paragraphId)' is in the sequence but its text snapshot returned nil.",
            hint: "Internal inconsistency between paragraphs map and sequence. Please retry; if it persists, report.",
            fields: ["paragraph_id": paragraphId]))
    }
}
