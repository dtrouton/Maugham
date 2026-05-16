import Foundation
import Darwin

// Ignore SIGPIPE process-wide. Writing to a peer-closed socket would
// otherwise terminate this binary silently and Claude Desktop logs
// "Server transport closed unexpectedly."
signal(SIGPIPE, SIG_IGN)

// Allow override via env var (used by tests).
let socketPath = ProcessInfo.processInfo.environment["MAUGHAM_MCP_SOCKET"]
    ?? NSString(string: "~/Library/Application Support/Maugham/mcp.sock")
        .expandingTildeInPath

let bridge = JSONRPCBridge(socketPath: socketPath)
bridge.run()
