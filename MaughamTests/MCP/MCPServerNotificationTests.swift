import XCTest
import Foundation
import Darwin
@testable import Maugham

@MainActor
final class MCPServerNotificationTests: XCTestCase {
    private func tmpSocketPath() -> String {
        let id = UUID().uuidString.prefix(8)
        return "/tmp/mcpn-\(id).sock"
    }
    private func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "mcpn-test-\(UUID().uuidString)")!
    }

    func test_notificationRequest_producesNoResponse() async throws {
        // A JSON-RPC notification has no `id`. Per the spec, the server MUST NOT
        // reply. Our smoke discovered that Claude Desktop sends
        // `notifications/initialized` after handshake; if we reply, Claude treats
        // it as a protocol error.
        let path = tmpSocketPath()
        let router = MCPRouter()
        let prefs = UserPreferences(defaults: ephemeralDefaults())
        let server = MCPServer(socketPath: path, router: router, preferences: prefs)
        try await server.start()
        defer { Task { await server.stop() } }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertTrue(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                let destPtr = UnsafeMutableRawPointer(dst)
                    .assumingMemoryBound(to: CChar.self)
                _ = strlcpy(destPtr, src, MemoryLayout.size(ofValue: dst.pointee))
            }
        }
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
        XCTAssertTrue(connected)

        // Send a notification (no id field).
        let notif = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
        _ = notif.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }

        // Wait briefly and verify no bytes arrive. Use non-blocking recv with timeout.
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)  // 250ms
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, 0)
        // We expect EAGAIN (-1 with errno EAGAIN/EWOULDBLOCK) or 0 (peer closed).
        // We MUST NOT receive any bytes.
        XCTAssertLessThanOrEqual(n, 0,
            "Server replied to a notification: \(String(bytes: buf.prefix(max(0, Int(n))), encoding: .utf8) ?? "")")
    }
}
