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

    func test_binary_synthesizesNotRunning_whenSocketAbsent() throws {
        guard let bin = binaryURL() else {
            throw XCTSkip("maugham-mcp not built in this product dir")
        }
        // Point the binary at a socket path that definitely doesn't exist.
        let process = Process()
        process.executableURL = bin
        process.environment = ["MAUGHAM_MCP_SOCKET":
            "/tmp/definitely-not-a-real-socket-\(UUID()).sock"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let request = #"{"jsonrpc":"2.0","id":7,"method":"list_projects"}"# + "\n"
        inPipe.fileHandleForWriting.write(Data(request.utf8))
        // Close stdin so the binary exits after writing its response.
        inPipe.fileHandleForWriting.closeFile()
        // Read response — binary will close stdout when it exits, unblocking this.
        let resp = try XCTUnwrap(
            outPipe.fileHandleForReading.readDataToEndOfFile())
        let body = String(data: resp, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("-32001"), "expected -32001 in: \(body)")
        XCTAssertTrue(body.contains("\"id\":7"), "expected id 7 in: \(body)")
    }
}
