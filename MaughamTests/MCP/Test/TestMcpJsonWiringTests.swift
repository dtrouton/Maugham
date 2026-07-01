import XCTest

final class TestMcpJsonWiringTests: XCTestCase {
    /// Walks up from this file's path to the repo root. `MaughamTests/MCP/Test/`
    /// is 4 path components below root (MaughamTests, MCP, Test, filename), so
    /// 4 `deletingLastPathComponent()` calls land on root. Verified against the
    /// actual presence of `.mcp.json` below, rather than trusting the depth blindly.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func test_mcpJson_pointsAtWrapperAndDevServerKey() throws {
        let root = repoRoot()

        let mcpJsonURL = root.appendingPathComponent(".mcp.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: mcpJsonURL.path),
            "computed repo root \(root.path) does not contain .mcp.json — path-walk depth is wrong"
        )
        let scriptsDirURL = root.appendingPathComponent("scripts")
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scriptsDirURL.path, isDirectory: &isDir) && isDir.boolValue,
            "computed repo root \(root.path) does not contain scripts/ — path-walk depth is wrong"
        )

        let data = try Data(contentsOf: mcpJsonURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = obj?["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?["maugham-test"], ".mcp.json must define the maugham-test server")

        let script = root.appendingPathComponent("scripts/maugham-test-mcp.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path), "wrapper must be executable")
    }
}
