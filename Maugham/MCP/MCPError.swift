import Foundation

/// Maugham-specific MCP error codes. Plain JSON-RPC errors (-32600..-32603)
/// are returned without going through this enum.
public enum MCPError: Error, Equatable {
    case maughamNotRunning      // -32001: binary couldn't reach socket
    case projectNotOpen         // -32002: project_id not in registry
    case mcpDisabled            // -32003: user toggled off in Settings
    case invalidArgument(String)// -32602: param decoding / validation failure
    case internalError(String)  // -32603: unexpected

    public var code: Int {
        switch self {
        case .maughamNotRunning: return -32001
        case .projectNotOpen:    return -32002
        case .mcpDisabled:       return -32003
        case .invalidArgument:   return -32602
        case .internalError:     return -32603
        }
    }

    public var message: String {
        switch self {
        case .maughamNotRunning:     return "Maugham isn't running."
        case .projectNotOpen:        return "That project isn't open in Maugham."
        case .mcpDisabled:           return "Maugham's MCP connection is turned off in Settings."
        case .invalidArgument(let m):return "Invalid argument: \(m)"
        case .internalError(let m):  return "Internal error: \(m)"
        }
    }
}
