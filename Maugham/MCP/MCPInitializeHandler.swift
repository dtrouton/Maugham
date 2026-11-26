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
        /// MCP's optional `instructions`: what every client reads before its
        /// first call (shell p5 Task 9 fix round 1). Claude Desktop never sees
        /// the `maugham-bootstrap` skill, so this is the one place a Desktop
        /// session learns how to talk about the window.
        public let instructions: String
    }

    /// **The server's instructions, spelled once.** What Maugham is, that
    /// Claude never writes manuscript text, to load a skill before a
    /// multi-step job, and to direct the writer by what they can see. The
    /// piece nouns are in backticks: MCP's literals keep code spans out of the
    /// fixed-noun census, and the instruction names them as words to use.
    public static let instructions = """
        Maugham is a Mac writing app. You never write manuscript text: you leave notes on it, \
        write research notes, add canvas cards and write translations in their own layer; the \
        writer decides what reaches the manuscript. Before a multi-step job (an editing pass, a \
        translation, a transcription, publishing), call get_help with topic "skills" and load \
        the skill for it. Talk to the writer about what they can see, not tool names: the \
        binder on the left picks what the window is about, the centre shows it, To resolve (⌘1) \
        is where your notes wait, Brief (⌘2) is what a piece is for, and Pulled up (⌘3) is one \
        thing read beside the text. Use the project's own word for a piece (`chapter`, `story`, \
        `script`, `section`).
        """

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
                extensions: [SkillsExtension.extensionId: EmptyObject()]),
            instructions: instructions)
        return try JSONEncoder().encode(result)
    }
}
