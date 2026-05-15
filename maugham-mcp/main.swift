import Foundation

// Allow override via env var (used by tests).
let socketPath = ProcessInfo.processInfo.environment["MAUGHAM_MCP_SOCKET"]
    ?? NSString(string: "~/Library/Application Support/Maugham/mcp.sock")
        .expandingTildeInPath

let bridge = JSONRPCBridge(socketPath: socketPath)
bridge.run()
