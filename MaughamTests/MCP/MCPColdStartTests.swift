import XCTest
import Darwin

/// Regression pin for the deferred "first-MCP-call-after-restart" flake
/// (deferred 2026-05-17). The bridge (`maugham-mcp`) had two asymmetric
/// reconnect paths: when it had a *prior* connection it polled for 15s for the
/// socket to come back (covering a cold relaunch), but when it had *no* prior
/// connection — the very first call after the app launches, which is the case
/// users actually hit — it made only a couple of short backoff attempts
/// (~1.5s) and then synthesized `maugham_not_running`. A cold launch that took
/// longer than that lost its first call; a retry seconds later succeeded.
///
/// These tests drive the real `maugham-mcp` binary against an in-process stub
/// Unix-socket listener (standing in for `MCPServer`) so we can control exactly
/// when the "app" binds the socket.
final class MCPColdStartTests: XCTestCase {

    // MARK: - The regression: first call after launch, no prior connection

    /// The bridge starts with NO server present (Claude Desktop spawned it
    /// while Maugham was closed). A request arrives; the "app" binds the socket
    /// 2.5s later — longer than the old ~1.5s fast-fail but well within a normal
    /// cold launch. The bridge must poll and deliver a REAL response, not
    /// synthesize `maugham_not_running`.
    ///
    /// RED against the pre-fix binary: the no-prior-connection path fast-failed
    /// at ~1.5s, so this returned -32001. GREEN with the unified poll.
    ///
    /// **Staged-scenario discipline (2026-08-08).** This is a three-way race by
    /// construction — bridge budget, `asyncAfter`-scheduled bind, read window —
    /// and on a loaded machine the STAGING can fail without the shipped
    /// behaviour being wrong: the stub's bind slips past the budget and the
    /// bridge correctly synthesizes the very answer the regression produced
    /// (2026-07-29, in-suite). So each attempt records when the stub ACTUALLY
    /// bound, and an attempt whose bind landed outside the safe window is
    /// discarded and restaged (bounded, the mint-and-return pattern) instead of
    /// failing. A TIMELY bind that still yields -32001 is the regression and
    /// fails immediately, on any attempt. The budget is 15_000 —
    /// `MAUGHAM_MCP_RECONNECT_BUDGET_MS`'s production default, so this now
    /// tests the shipped constant rather than a tighter stand-in.
    func test_firstCallAfterLaunch_pollsUntilServerBinds_noPriorConnection() throws {
        guard let bin = Self.binaryURL() else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        let budget: TimeInterval = 15.0   // == production default, see doc comment
        let attempts = 3
        for attempt in 1...attempts {
            let path = Self.tempSocketPath()
            defer { unlink(path) }

            // Bridge is launched with no listener present.
            let proc = try Self.launchBridge(
                bin: bin, socketPath: path, budgetMs: Int(budget * 1000))
            defer { Self.terminate(proc) }
            Self.drainInitialConnect()

            // Bring the "app" up 2.5s after we fire the request — past the old
            // fast-fail window, inside the poll budget. Record the REAL bind
            // moment; the schedule is an intention, not a fact.
            var listener: StubSocketListener?
            var boundAt: Date?
            let sentAt = Date()
            let bringUp = DispatchWorkItem {
                listener = try? StubSocketListener(path: path)
                boundAt = Date()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: bringUp)
            defer { listener?.stop(unlinkFile: false) }

            do {
                try Self.send(proc, #"{"jsonrpc":"2.0","id":1,"method":"list_projects"}"#)
            } catch {
                // The child died inside the launch/drain window — the 2026-08-09
                // CI failure arrived exactly here. Same verdict as a late bind:
                // the scenario wasn't staged, so discard and restage, bounded.
                bringUp.cancel()   // don't let the +2.5s bind fire into a discarded attempt
                if attempt < attempts { continue }
                return XCTFail("could not stage the cold-start scenario in "
                    + "\(attempts) attempts — \(error)")
            }
            let body = Self.readLine(proc, timeout: budget + 2)

            if !body.contains("\"served_by\":\"stub\"") {
                let bindDelay = boundAt.map { $0.timeIntervalSince(sentAt) }
                // Bind never happened inside the read, or landed within 3s of
                // the budget's edge: the scenario wasn't staged, so the reply
                // proves nothing either way — a fast-fail regression would show
                // a TIMELY bind and a -32001 body, which falls through to the
                // assertions below on every attempt.
                if bindDelay == nil || bindDelay! > budget - 3 {
                    if attempt < attempts { continue }
                    return XCTFail(
                        "could not stage the cold-start scenario in \(attempts) "
                        + "attempts — the stub's bind landed at "
                        + "\(bindDelay.map { String(format: "%.1fs", $0) } ?? "never") "
                        + "against a \(Int(budget))s budget each time. That is a "
                        + "machine pathology worth a human look, not a bridge "
                        + "defect; last body: \(body)")
                }
            }

            XCTAssertTrue(body.contains("\"served_by\":\"stub\""),
                "expected a REAL response once the server bound; got: \(body)")
            XCTAssertFalse(body.contains("-32001"),
                "first call after launch must not synthesize not_running; got: \(body)")
            XCTAssertTrue(body.contains("\"id\":1"), "wrong id; got: \(body)")
            return
        }
    }

    // MARK: - Guard: after-restart through the same long-lived bridge

    /// Establish a live connection, kill the "app", restart it on the same
    /// socket path, and send a call immediately through the SAME bridge process.
    /// The bridge must reconnect and deliver a real response. (This path polled
    /// 15s even before the fix; the test guards it against regression.)
    func test_callAfterRestart_reconnectsThroughSameBridge() throws {
        guard let bin = Self.binaryURL() else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        let path = Self.tempSocketPath()
        defer { unlink(path) }

        let l1 = try StubSocketListener(path: path)
        let proc = try Self.launchBridge(bin: bin, socketPath: path, budgetMs: 10_000)
        defer { Self.terminate(proc) }
        Self.drainInitialConnect()

        // Request 1 establishes the prior connection.
        try Self.send(proc, #"{"jsonrpc":"2.0","id":1,"method":"list_projects"}"#)
        let r1 = Self.readLine(proc, timeout: 6)
        XCTAssertTrue(r1.contains("\"id\":1"), "req1 setup failed; got: \(r1)")

        // Kill the app (close listen + client fds). Simulate an unclean exit by
        // leaving the socket file on disk — the new server unlinks it on bind.
        l1.stop(unlinkFile: false)
        Thread.sleep(forTimeInterval: 0.2)

        // Restart the app on the same path, then fire immediately.
        let l2 = try StubSocketListener(path: path)
        defer { l2.stop(unlinkFile: false) }

        try Self.send(proc, #"{"jsonrpc":"2.0","id":2,"method":"list_projects"}"#)
        let r2 = Self.readLine(proc, timeout: 9)
        XCTAssertTrue(r2.contains("\"served_by\":\"stub\""),
            "expected a REAL response after restart; got: \(r2)")
        XCTAssertTrue(r2.contains("\"id\":2"), "wrong id after restart; got: \(r2)")
    }

    // MARK: - Contract guard: genuinely-absent app still synthesizes

    /// When the app is genuinely not running, the bridge must still synthesize
    /// `maugham_not_running` after exhausting its (test-shortened) budget — the
    /// poll is bounded, not retry-forever (ADR 0003).
    func test_absentApp_synthesizesAfterBoundedBudget() throws {
        guard let bin = Self.binaryURL() else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        let path = Self.tempSocketPath()  // never bound
        let proc = try Self.launchBridge(bin: bin, socketPath: path, budgetMs: 300)
        defer { Self.terminate(proc) }
        Self.drainInitialConnect()

        try Self.send(proc, #"{"jsonrpc":"2.0","id":5,"method":"list_projects"}"#)
        let body = Self.readLine(proc, timeout: 5)
        XCTAssertTrue(body.contains("-32001"),
            "absent app must synthesize not_running; got: \(body)")
        XCTAssertTrue(body.contains("\"id\":5"), "wrong id; got: \(body)")
    }

    // MARK: - Harness

    /// **Dead-bridge discipline (2026-08-12, issue #32).** A child that died on
    /// a loaded machine must not RAISE through the harness: NSFileHandle's ObjC
    /// `writeData:` raises NSFileHandleOperationException on a dead fd, and
    /// XCTest converts that to an instant failure BEFORE the read — bypassing
    /// the staged-scenario restage discipline entirely (2026-08-09, CI run
    /// 31299861454: 0.344s = launch + 0.3s drain + first write). `send` now
    /// throws this instead; test 1 restages it through its bounded loop, and
    /// tests 2–3 let it propagate so the failure message IS the diagnosis.
    private struct BridgeDied: Error, CustomStringConvertible {
        let phase: String
        let underlying: String
        var description: String {
            "bridge child died (\(phase)): \(underlying) — on a loaded machine "
                + "this is machine pathology worth a human look, not a bridge defect"
        }
    }

    private static func binaryURL() -> URL? {
        let hostExecutableURL = Bundle.main.executableURL
        let dir = hostExecutableURL?.deletingLastPathComponent()
            ?? Bundle.main.bundleURL.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("maugham-mcp")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        let builtDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let sibling = builtDir.appendingPathComponent("maugham-mcp")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        return nil
    }

    private static func tempSocketPath() -> String {
        // Keep well under sockaddr_un's 104-byte sun_path limit.
        "/tmp/mcp-cold-\(UUID().uuidString.prefix(8)).sock"
    }

    private static func launchBridge(bin: URL, socketPath: String, budgetMs: Int) throws -> Process {
        let p = Process()
        p.executableURL = bin
        p.environment = [
            "MAUGHAM_MCP_SOCKET": socketPath,
            "MAUGHAM_MCP_RECONNECT_BUDGET_MS": "\(budgetMs)"]
        p.standardInput = Pipe()
        p.standardOutput = Pipe()
        try p.run()
        return p
    }

    /// Give the binary a moment for its startup connect attempt to settle.
    private static func drainInitialConnect() { Thread.sleep(forTimeInterval: 0.3) }

    private static func send(_ p: Process, _ json: String) throws {
        guard p.isRunning else {
            throw BridgeDied(phase: "before the write",
                underlying: "exit status \(p.terminationStatus)")
        }
        let handle = (p.standardInput as! Pipe).fileHandleForWriting
        do {
            try handle.write(contentsOf: Data((json + "\n").utf8))
        } catch {
            throw BridgeDied(phase: "during the write", underlying: "\(error)")
        }
    }

    private static func readLine(_ p: Process, timeout: TimeInterval) -> String {
        let handle = (p.standardOutput as! Pipe).fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        var buf = Data()
        while Date() < deadline {
            let avail = handle.availableData
            if !avail.isEmpty {
                buf.append(avail)
                if buf.contains(0x0A) { break }
            } else if !p.isRunning {
                break   // EOF from a dead child; nothing more is coming
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return String(data: buf, encoding: .utf8) ?? ""
    }

    private static func terminate(_ p: Process) {
        if let pipe = p.standardInput as? Pipe {
            // Throwing Swift API, not `closeFile()` — this runs from a `defer`
            // in every test, and a dead child's fd must not raise there either
            // (hardening `send` alone would just move the exception here).
            try? pipe.fileHandleForWriting.close()
        }
        if p.isRunning { p.terminate() }
    }
}

/// Minimal in-process AF_UNIX listener that answers each JSON-RPC request line
/// with a success result tagged `served_by: stub`. Stands in for `MCPServer`
/// so cold-start / restart timing can be controlled from the test.
final class StubSocketListener {
    let path: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var clientFDs: [Int32] = []
    private var stopped = false

    init(path: String) throws {
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Err.create(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(
                    UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self),
                    src, MemoryLayout.size(ofValue: dst.pointee))
            }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else { let e = errno; close(fd); throw Err.bind(e) }
        guard listen(fd, 5) == 0 else { let e = errno; close(fd); throw Err.listen(e) }
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            var ca = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = accept(listenFD, &ca, &len)
            if cfd < 0 {
                lock.lock(); let done = stopped; lock.unlock()
                if done { return }
                continue
            }
            lock.lock()
            if stopped { lock.unlock(); close(cfd); return }
            clientFDs.append(cfd)
            lock.unlock()
            Thread.detachNewThread { [weak self] in self?.serve(cfd) }
        }
    }

    private func serve(_ cfd: Int32) {
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(cfd, &buf, buf.count)
            if n <= 0 { close(cfd); return }
            pending.append(buf, count: Int(n))
            while let idx = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<idx])
                pending.removeSubrange(...idx)
                guard
                    let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let id = obj["id"]
                else { continue }
                let idLit: String = (id as? Int).map { "\($0)" } ?? "\"\(id)\""
                let resp = "{\"jsonrpc\":\"2.0\",\"id\":\(idLit),\"result\":{\"served_by\":\"stub\"}}\n"
                let out = Data(resp.utf8)
                _ = out.withUnsafeBytes { raw -> Int in
                    write(cfd, raw.baseAddress, raw.count)
                }
            }
        }
    }

    func stop(unlinkFile: Bool) {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let fds = clientFDs
        clientFDs.removeAll()
        let lfd = listenFD
        listenFD = -1
        lock.unlock()
        if lfd >= 0 { close(lfd) }
        for c in fds { close(c) }  // force bridge's connection to see EOF
        if unlinkFile { unlink(path) }
    }

    enum Err: Error { case create(Int32), bind(Int32), listen(Int32) }
}
