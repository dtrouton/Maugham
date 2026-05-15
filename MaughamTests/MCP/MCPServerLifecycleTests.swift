import XCTest
import Foundation
import Darwin
@testable import Maugham

@MainActor
final class MCPServerLifecycleTests: XCTestCase {
    private func tmpSocketPath() -> String {
        let id = UUID().uuidString.prefix(8)
        return "/tmp/mcp-\(id).sock"
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "mcp-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func test_start_bindsSocket() async throws {
        let path = tmpSocketPath()
        let router = MCPRouter()
        let prefs = UserPreferences(defaults: ephemeralDefaults())
        let server = MCPServer(socketPath: path, router: router, preferences: prefs)
        try await server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func test_request_dispatchesViaRouter() async throws {
        let path = tmpSocketPath()
        let router = MCPRouter()
        router.register(method: "ping") { _ in Data("\"pong\"".utf8) }
        let prefs = UserPreferences(defaults: ephemeralDefaults())
        let server = MCPServer(socketPath: path, router: router, preferences: prefs)
        try await server.start()
        defer { Task { await server.stop() } }

        let req = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let resp = try await sendAndReceive(socketPath: path, request: req)
        XCTAssertTrue(resp.contains("\"result\":\"pong\""), "got: \(resp)")
    }

    func test_request_whenDisabled_returnsMCPDisabled() async throws {
        let path = tmpSocketPath()
        let router = MCPRouter()
        router.register(method: "ping") { _ in Data("\"pong\"".utf8) }
        let prefs = UserPreferences(defaults: ephemeralDefaults())
        prefs.mcpEnabled = false
        let server = MCPServer(socketPath: path, router: router, preferences: prefs)
        try await server.start()
        defer { Task { await server.stop() } }

        let req = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let resp = try await sendAndReceive(socketPath: path, request: req)
        XCTAssertTrue(resp.contains("-32003"), "got: \(resp)")
        XCTAssertFalse(resp.contains("\"result\""))
    }

    /// Connect to a Unix socket, write `request` + newline, read one line.
    /// All blocking syscalls run on DispatchQueue.global() via
    /// withCheckedContinuation so Swift's cooperative thread pool is never
    /// starved, keeping the main actor free for MCPRouter.dispatch hops.
    private func sendAndReceive(socketPath: String, request: String) async throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertTrue(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(
                    UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self),
                    src,
                    MemoryLayout.size(ofValue: dst.pointee))
            }
        }
        // Retry connect briefly — accept loop may not be ready immediately.
        var connected = false
        for _ in 0..<20 {
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if r == 0 { connected = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(connected, "connect failed after retries")

        // Send request + newline
        let line = request + "\n"
        _ = line.withCString { ptr in
            send(fd, ptr, strlen(ptr), 0)
        }
        // Read response on a GCD thread so we don't block a cooperative thread
        // while the server is awaiting the main actor for router.dispatch.
        let fdCopy = fd
        let resp: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buf = [UInt8](repeating: 0, count: 65_536)
                let n = recv(fdCopy, &buf, buf.count, 0)
                let s = n > 0
                    ? (String(bytes: buf.prefix(Int(n)), encoding: .utf8) ?? "")
                    : "recv returned \(n)"
                continuation.resume(returning: s)
            }
        }
        return resp
    }
}
