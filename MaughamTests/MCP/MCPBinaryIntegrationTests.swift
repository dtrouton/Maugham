import XCTest

final class MCPBinaryIntegrationTests: XCTestCase {
    private func binaryURL() -> URL? {
        // The maugham-mcp binary is copied next to the test host. The test host
        // is Maugham.app/Contents/MacOS/Maugham; the binary is at the same level.
        let hostExecutableURL = Bundle.main.executableURL
        let dir = hostExecutableURL?.deletingLastPathComponent()
            ?? Bundle.main.bundleURL.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("maugham-mcp")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        // Fallback: BUILT_PRODUCTS_DIR sibling.
        let builtDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let sibling = builtDir.appendingPathComponent("maugham-mcp")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    /// Mirror of MCPColdStartTests' dead-bridge discipline (2026-08-12, issue
    /// #32) — see that file's `BridgeDied` doc for the CI history. Kept
    /// per-file because the two harnesses share no types today. Exposure here
    /// is lower (no staged race, so nothing to restage): the point is only
    /// that a dead child arrives as this diagnosis, never as
    /// NSFileHandleOperationException.
    private struct BridgeDied: Error, CustomStringConvertible {
        let phase: String
        let underlying: String
        var description: String {
            "bridge child died (\(phase)): \(underlying) — on a loaded machine "
                + "this is machine pathology worth a human look, not a bridge defect"
        }
    }

    /// Writes exactly the bytes given (call sites already embed their own
    /// newlines) through the throwing Swift API, guarded on liveness.
    private func send(_ p: Process, raw text: String) throws {
        guard p.isRunning else {
            throw BridgeDied(phase: "before the write",
                underlying: "exit status \(p.terminationStatus)")
        }
        let handle = (p.standardInput as! Pipe).fileHandleForWriting
        do {
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            throw BridgeDied(phase: "during the write", underlying: "\(error)")
        }
    }

    func test_binary_synthesizesNotRunning_whenSocketAbsent() throws {
        guard let bin = binaryURL() else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        // Point the binary at a socket path that definitely doesn't exist.
        let process = Process()
        process.executableURL = bin
        process.environment = [
            "MAUGHAM_MCP_SOCKET":
                "/tmp/definitely-not-a-real-socket-\(UUID()).sock",
            // Keep absent-socket synthesis fast: the production default reconnect
            // budget is 15s (covers a cold app launch); these tests exercise the
            // never-appears path and only need to see the synthesized error.
            "MAUGHAM_MCP_RECONNECT_BUDGET_MS": "200"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let request = #"{"jsonrpc":"2.0","id":7,"method":"list_projects"}"# + "\n"
        try send(process, raw: request)
        // Read one line response (new design is line-by-line, not EOF-delimited).
        let chunk = try? collectResponseLine(from: outPipe.fileHandleForReading, timeout: 5)
        // Close stdin so the binary exits cleanly.
        try? inPipe.fileHandleForWriting.close()
        let body = chunk ?? ""
        XCTAssertTrue(body.contains("-32001"), "expected -32001 in: \(body)")
        XCTAssertTrue(body.contains("\"id\":7"), "expected id 7 in: \(body)")
    }
}

extension MCPBinaryIntegrationTests {
    /// Smoke test: the binary stays alive after the socket peer disappears,
    /// synthesizing per-request maugham_not_running errors. (We don't
    /// actually need a running socket-listener — we just hammer requests
    /// at the binary with a bogus socket path and verify it keeps
    /// responding without exiting.)
    func test_binary_keepsAliveAndSynthesizes_underRepeatedRequests() throws {
        guard let bin = binaryURL() else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        let process = Process()
        process.executableURL = bin
        process.environment = [
            "MAUGHAM_MCP_SOCKET":
                "/tmp/definitely-not-a-real-socket-\(UUID()).sock",
            // Keep absent-socket synthesis fast: the production default reconnect
            // budget is 15s (covers a cold app launch); these tests exercise the
            // never-appears path and only need to see the synthesized error.
            "MAUGHAM_MCP_RECONNECT_BUDGET_MS": "200"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // Send three requests in succession. Read each response. Verify
        // all three return -32001 and the binary is still running between
        // requests (it's not — we have no good "still alive" check across
        // requests without timing-out, so we use a generous read between
        // requests).
        for i in 1...3 {
            let req = "{\"jsonrpc\":\"2.0\",\"id\":\(i),\"method\":\"ping\"}\n"
            try send(process, raw: req)
            // Read just up to one response's length-ish; the binary writes
            // line-delimited responses so we read until we see a newline.
            let chunk = try? collectResponseLine(from: outPipe.fileHandleForReading, timeout: 5)
            let body = chunk ?? ""
            XCTAssertTrue(body.contains("-32001"),
                "request \(i) didn't get an error response; got: \(body)")
            XCTAssertTrue(body.contains("\"id\":\(i)"),
                "request \(i) response had wrong id; got: \(body)")
        }
        try? inPipe.fileHandleForWriting.close()
    }

    /// Verify that closing stdin causes the binary to exit cleanly.
    func test_binary_exitsCleanly_onStdinClose() throws {
        guard let bin = binaryURL() else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        let process = Process()
        process.executableURL = bin
        process.environment = [
            "MAUGHAM_MCP_SOCKET":
                "/tmp/definitely-not-a-real-socket-\(UUID()).sock",
            // Keep absent-socket synthesis fast: the production default reconnect
            // budget is 15s (covers a cold app launch); these tests exercise the
            // never-appears path and only need to see the synthesized error.
            "MAUGHAM_MCP_RECONNECT_BUDGET_MS": "200"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()

        // Send one request then close stdin.
        let req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}\n"
        try send(process, raw: req)
        _ = try? collectResponseLine(from: outPipe.fileHandleForReading, timeout: 5)
        try? inPipe.fileHandleForWriting.close()

        // The property is "stdin closes ⇒ the binary exits" — the expectation
        // fulfills on the exit EVENT, so this allowance costs nothing when
        // green and models no product constant. It was 5s, and on 2026-07-29 a
        // loaded serial suite starved the subprocess past it (the test took
        // 9.4s and measured the machine, not the binary). 60s can only fire on
        // a binary that genuinely does not exit.
        // A dedicated `Thread`, NOT a global dispatch queue: this host reaches
        // libdispatch's 64-thread ceiling during launch (see
        // `MCPServerLifecycleTests`' census), so a block posted to a global
        // queue can be scheduled late or never — and a watcher scheduled late
        // reports the exit late, which is indistinguishable from a binary that
        // did not exit. That is what made this test "load-sensitive" in the
        // 2026-07-29 note; it never was.
        let exitExpectation = expectation(description: "binary exits")
        let watcher = Thread {
            process.waitUntilExit()
            exitExpectation.fulfill()
        }
        watcher.name = "mcp-binary-exit-watch"
        watcher.stackSize = 512 * 1024
        watcher.start()
        wait(for: [exitExpectation], timeout: 60)
        XCTAssertFalse(process.isRunning)
    }

    /// Read up to one newline-terminated line from a FileHandle with a
    /// soft timeout (returns whatever's been received so far when the
    /// timeout fires).
    private func collectResponseLine(
        from handle: FileHandle, timeout: TimeInterval
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var buf = Data()
        while Date() < deadline {
            let avail = handle.availableData
            if !avail.isEmpty {
                buf.append(avail)
                if buf.contains(0x0A) { break }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return String(data: buf, encoding: .utf8) ?? ""
    }

    /// A malformed JSON line (or one with no extractable id) should be dropped
    /// silently — emitting a synthesized response with null id would corrupt
    /// Claude Desktop's outstanding-request tracking.
    func test_binary_dropsResponse_whenIncomingLineHasNoExtractableId() throws {
        guard let bin = binaryURL() else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        let process = Process()
        process.executableURL = bin
        process.environment = [
            "MAUGHAM_MCP_SOCKET":
                "/tmp/definitely-not-a-real-socket-\(UUID()).sock",
            // Keep absent-socket synthesis fast: the production default reconnect
            // budget is 15s (covers a cold app launch); these tests exercise the
            // never-appears path and only need to see the synthesized error.
            "MAUGHAM_MCP_RECONNECT_BUDGET_MS": "200"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // Send a structurally malformed request that has neither `id` nor
        // `method` — it parses as JSON but carries no extractable id. The
        // binary must NOT write a null-id response; it should drop silently.
        let bogus = #"{"jsonrpc":"2.0","garbage":true}"# + "\n"
        try send(process, raw: bogus)

        // Follow immediately with a real request to confirm the binary is
        // still alive and the bogus line didn't generate any output.
        let real = #"{"jsonrpc":"2.0","id":99,"method":"x"}"# + "\n"
        try send(process, raw: real)

        let body = (try? collectResponseLine(
            from: outPipe.fileHandleForReading, timeout: 5)) ?? ""
        try? inPipe.fileHandleForWriting.close()

        // The first (and only) response must be for id 99 — the real request.
        // The bogus line should have generated no output at all.
        XCTAssertTrue(body.contains("\"id\":99"),
            "expected response for id 99 (bogus dropped); got: \(body)")
        XCTAssertFalse(body.contains("\"id\":null"),
            "must not emit null-id responses; got: \(body)")
    }

    /// JSON-RPC notifications (no `id` field) get no response. The binary
    /// must forward them and immediately accept the next stdin line — not
    /// block waiting for a response that never comes. Regression for the
    /// "MCP shows connected but Claude can't see tools" bug: Claude Desktop
    /// sends `notifications/initialized` after the handshake, and if the
    /// binary blocked there, subsequent `tools/list` never makes it through.
    func test_binary_doesNotBlockOnNotification_andProcessesNextRequest() throws {
        guard let bin = binaryURL() else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        let process = Process()
        process.executableURL = bin
        process.environment = [
            "MAUGHAM_MCP_SOCKET":
                "/tmp/definitely-not-a-real-socket-\(UUID()).sock",
            // Keep absent-socket synthesis fast: the production default reconnect
            // budget is 15s (covers a cold app launch); these tests exercise the
            // never-appears path and only need to see the synthesized error.
            "MAUGHAM_MCP_RECONNECT_BUDGET_MS": "200"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // 1. Send an id-less notification first. Binary should NOT block.
        let notif = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
        try send(process, raw: notif)

        // 2. Immediately send a request. If the binary blocked on the
        //    notification, this never gets read.
        let req = #"{"jsonrpc":"2.0","id":42,"method":"list_projects"}"# + "\n"
        try send(process, raw: req)

        // 3. We should get a response for the request within a few seconds.
        let body = (try? collectResponseLine(
            from: outPipe.fileHandleForReading, timeout: 5)) ?? ""
        try? inPipe.fileHandleForWriting.close()
        XCTAssertTrue(body.contains("\"id\":42"),
            "expected response for id 42 (notification didn't block); got: \(body)")
        XCTAssertTrue(body.contains("-32001"),
            "expected synthesized maugham_not_running; got: \(body)")
    }
}
