import Foundation
import MaughamCore

/// MCP `initialize` handshake handler. Claude Desktop and other MCP clients
/// send this as the first message after spawning the server; the response
/// advertises protocol version, server identity, and capabilities.
public enum MCPInitializeHandler {
    public static let method = "initialize"

    public struct ServerInfo: Codable, Equatable {
        public let name: String
        public let version: String
    }
    public struct ToolsCapability: Codable, Equatable {}
    /// Empty object value under `capabilities.extensions.<id>` — per SEP-2640,
    /// signals "extension supported, no optional features" (see SkillsExtension
    /// pin comment; `directoryRead` is the only optional flag and unimplemented).
    public struct EmptyObject: Codable, Equatable {}
    public struct Capabilities: Codable, Equatable {
        public let tools: ToolsCapability
        /// SEP-2640: extensions declared as an object keyed by extension id.
        public let extensions: [String: EmptyObject]
    }
    public struct Result: Codable, Equatable {
        public let protocolVersion: String
        public let serverInfo: ServerInfo
        public let capabilities: Capabilities
    }

    public static func handle(paramsJSON: Data?) async throws -> Data {
        // Mirror the protocol version the client advertises if present, else
        // fall back to a known version. Claude Desktop currently sends
        // "2025-11-25"; matching keeps it happy.
        let protocolVersion: String = {
            guard let data = paramsJSON,
                  let any = try? JSONDecoder().decode(AnyJSON.self, from: data),
                  case .object(let obj) = any,
                  case .string(let pv) = obj["protocolVersion"] else {
                return "2025-11-25"
            }
            return pv
        }()
        let result = Result(
            protocolVersion: protocolVersion,
            serverInfo: ServerInfo(
                name: BuildVariant.current.mcpServerKey,
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"),
            capabilities: Capabilities(
                tools: ToolsCapability(),
                extensions: [SkillsExtension.extensionId: EmptyObject()]))
        return try JSONEncoder().encode(result)
    }
}
