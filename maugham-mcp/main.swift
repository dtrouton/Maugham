import Foundation
import Darwin

// Ignore SIGPIPE process-wide. Writing to a peer-closed socket would
// otherwise terminate this binary silently and Claude Desktop logs
// "Server transport closed unexpectedly."
signal(SIGPIPE, SIG_IGN)

// Allow override via env var (used by tests).
let env = ProcessInfo.processInfo.environment
let socketPath = env["MAUGHAM_MCP_SOCKET"]
    ?? NSString(string: "~/Library/Application Support/Maugham/mcp.sock")
        .expandingTildeInPath

// How long a single request waits for the socket to (re)appear before we
// synthesize maugham_not_running. Default 15s covers a cold launch; tests
// override it (via MAUGHAM_MCP_RECONNECT_BUDGET_MS) to keep absent-socket
// synthesis fast.
let reconnectBudget: TimeInterval = env["MAUGHAM_MCP_RECONNECT_BUDGET_MS"]
    .flatMap { Double($0) }
    .map { $0 / 1000.0 }
    ?? 15.0

let bridge = JSONRPCBridge(socketPath: socketPath, reconnectBudget: reconnectBudget)
bridge.run()
