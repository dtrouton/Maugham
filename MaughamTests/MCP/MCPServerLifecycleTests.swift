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

    /// If a client disconnects between sending its request and the server's
    /// response write, send() fails. The server must:
    /// 1) Not be killed by SIGPIPE
    /// 2) Exit the connection's handler loop cleanly
    /// 3) Keep the listening socket open so new connections still work
    func test_server_survives_clientDisconnectMidResponse() async throws {
        let path = tmpSocketPath()
        let router = MCPRouter()
        // Slow handler — gives the test time to close the client before
        // the server's send() runs.
        router.register(method: "slow") { _ in
            try? await Task.sleep(for: .milliseconds(150))
            return Data("\"ok\"".utf8)
        }
        let prefs = UserPreferences(defaults: ephemeralDefaults())
        let server = MCPServer(socketPath: path, router: router, preferences: prefs)
        try await server.start()
        defer { Task { await server.stop() } }

        // Open a client, send the slow request, close immediately.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertTrue(fd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(
                    UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self),
                    src, MemoryLayout.size(ofValue: dst.pointee))
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

        let req = #"{"jsonrpc":"2.0","id":1,"method":"slow"}"# + "\n"
        _ = req.withCString { send(fd, $0, strlen($0), 0) }
        // Immediately close before the server's handler responds.
        close(fd)

        // Wait past the slow handler. If the server were killed by SIGPIPE,
        // a subsequent connection would fail. If it cleanly handled the
        // disconnect, a new connection succeeds.
        try await Task.sleep(for: .milliseconds(400))

        // Open a second client and verify the listening socket still works.
        let fd2 = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertTrue(fd2 >= 0)
        defer { close(fd2) }
        let r2 = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd2, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(r2, 0, "server should still accept connections after a peer disconnect; errno=\(errno)")
    }

    /// The read in `sendAndReceive` must never go back onto a global dispatch
    /// queue, because this test host runs permanently AT libdispatch's
    /// 64-thread ceiling and a block posted there may never be scheduled.
    ///
    /// Measured 2026-08-15 with `/usr/bin/sample` on a deliberately stalled
    /// gate and then on a clean single-suite run:
    ///
    /// | process | threads | in `-[NSAnimation _runBlocking]` |
    /// |---|---|---|
    /// | `Maugham.app` launched normally | 10 | 1 |
    /// | any xctest host, during launch, before a test runs | 68 | 63–64 |
    ///
    /// with `sample` reporting *"Dispatch Thread Soft Limit: 64 reached in
    /// 3490 of 3490 samples — too many dispatch threads blocked in synchronous
    /// operations"*. The animations are AppKit's and are unfinished because
    /// nothing drives them to completion in a test host; the product is not
    /// affected (see the table's first row).
    ///
    /// This is a census, not a style rule: a `DispatchQueue.global` here is
    /// what made this class park a whole gate with no deadline, no output and
    /// no test name, three times in two days.
    func test_theReadDoesNotDependOnTheDispatchPoolThisHostHasAlreadyExhausted() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        // COMMENT LINES ARE STRIPPED FIRST. The prose above has to be able to
        // name the thing it forbids — a whole-file substring census failed on
        // its own explanation, twice, which is a cheap mistake to make and an
        // expensive one to read back.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // Assembled at runtime so the census does not match its own line.
        let forbidden = "DispatchQueue" + ".global"
        XCTAssertFalse(
            code.contains(forbidden),
            """
            `sendAndReceive` reads on a dedicated `Thread` on purpose. A global \
            dispatch queue cannot be relied on in this host — it is already at \
            the 64-thread ceiling before the first test runs, so the block may \
            never start, and the SO_RCVTIMEO that lives inside it can then \
            never fire. That combination is an unkillable, unnamed park.
            """)
        XCTAssertTrue(
            source.contains("let reader = Thread {"),
            "the dedicated reader thread is the mechanism this census protects")
    }

    /// Connect to a Unix socket, write `request` + newline, read one line.
    /// The blocking `recv` runs on a dedicated `Thread` via
    /// `withCheckedContinuation`, so Swift's cooperative pool is never starved
    /// — the main actor stays free for `MCPRouter.dispatch` hops — AND the
    /// read cannot be starved by the dispatch pool this host has already
    /// exhausted (see the census above).
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
        // **A response that never arrives must FAIL, not hang.**
        //
        // The server writes its response only after hopping to the main actor
        // for `MCPRouter.dispatch`, so anything that keeps the main actor busy
        // stops the write — and an untimed `recv` then blocks forever. Measured
        // 2026-07-29: this class passes alone in 6.9s (this test in 0.003s) and
        // `test_request_dispatchesViaRouter` never returned inside the full
        // 3,399-test suite — 45 minutes with no output, no failure, no name.
        //
        // That is the cost being paid here, and it is not the missing response:
        // it is that **a hang is indistinguishable from a slow suite**, so the
        // whole run has to be killed and nothing says which test stopped it or
        // why. With a timeout the same defect arrives as one named assertion.
        //
        // The trigger — what holds the main actor at suite scale, and which
        // other tests are in it — is unresolved and deliberately still open;
        // this makes it *diagnosable* rather than fatal. 10s is ~3,000× the
        // passing time, so it can only fire on a genuine stall.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        // Read the response on a **dedicated `Thread`**, not a global dispatch
        // queue — see `test_theReadDoesNotDependOnTheDispatchPoolThisHostHasAlreadyExhausted`.
        //
        // Measured 2026-08-15: every Maugham xctest host reaches libdispatch's
        // 64-thread soft limit DURING LAUNCH, with all 64 parked in
        // `-[NSAnimation _runBlocking]` (the same app launched normally has
        // one such thread and ten in total, so this is a property of the test
        // host, not of the product). At the ceiling a
        // `DispatchQueue.global(...).async` block is at the mercy of the
        // workqueue governor: usually it gets a thread in microseconds, and
        // sometimes it never gets one at all.
        //
        // That was the whole defect. The `SO_RCVTIMEO` below lives INSIDE the
        // block, so when the block never ran, the timeout that `5fe107b` added
        // to turn this hang into a named failure could not fire either — the
        // continuation simply never resumed. The result was a park with no
        // deadline, no output and no test name, which killed whole local gates
        // (three sightings, 2026-08-14/15) and is why this class was quarantined.
        //
        // A `Thread` is created directly by the kernel and is not drawn from
        // the dispatch pool, so it cannot be starved by it. The timeout can
        // now always fire, which restores the property that this test either
        // passes or fails within 10s — never parks.
        let fdCopy = fd
        let resp: String = await withCheckedContinuation { continuation in
            let reader = Thread {
                var buf = [UInt8](repeating: 0, count: 65_536)
                let n = recv(fdCopy, &buf, buf.count, 0)
                let err = errno
                let s: String
                if n > 0 {
                    s = String(bytes: buf.prefix(Int(n)), encoding: .utf8) ?? ""
                } else if n < 0 && (err == EAGAIN || err == EWOULDBLOCK) {
                    // The timeout above fired. Name it, so the failure message
                    // is the diagnosis rather than the start of one.
                    s = "recv timed out after 10s — no response was written. "
                        + "The server dispatches on the main actor; something is "
                        + "holding it. This is a stall, not a wrong answer."
                } else {
                    s = "recv returned \(n), errno=\(err)"
                }
                continuation.resume(returning: s)
            }
            reader.name = "mcp-test-recv"
            reader.stackSize = 512 * 1024
            reader.start()
        }
        return resp
    }
}
