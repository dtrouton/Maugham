import XCTest
@testable import Maugham

final class SetupClaudeDesktopConfigTests: XCTestCase {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CDC-\(UUID())")
    }

    func test_state_isMissing_whenFileAbsent() {
        let dir = tmp()
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/x"),
            .missing)
    }

    func test_state_isUnconfigured_whenNoMaughamEntry() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"other":{"command":"x"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/x"),
            .unconfigured)
    }

    func test_state_isConfigured_whenPathMatches() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham":{"command":"/x"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/x", serverKey: "maugham"),
            .configured(path: "/x"))
    }

    func test_state_isStalePath_whenMaughamEntryPathDiffers() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham":{"command":"/old/path/maugham-mcp"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/new/path/maugham-mcp", serverKey: "maugham"),
            .stalePath(currentPath: "/old/path/maugham-mcp"))
    }

    func test_state_isCorrupt_whenJSONUnparseable() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try "not json {{{".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/x"),
            .corrupt)
    }
}

extension SetupClaudeDesktopConfigTests {
    func test_merge_writesMaughamEntry_preservingOthers() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"other":{"command":"/x"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/Applications/Maugham.app/Contents/MacOS/maugham-mcp",
            serverKey: "maugham")
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        let maugham = try XCTUnwrap(servers["maugham"] as? [String: Any])
        XCTAssertEqual(maugham["command"] as? String,
                       "/Applications/Maugham.app/Contents/MacOS/maugham-mcp")
    }

    func test_merge_createsFile_whenAbsent() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try ClaudeDesktopConfig.merge(configURL: path, maughamBinary: "/x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func test_remove_deletesEntry_preservingOthers() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham":{"command":"/x"},"other":{"command":"/y"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        try ClaudeDesktopConfig.removeMaughamEntry(configURL: path, serverKey: "maugham")
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["maugham"])
        XCTAssertNotNil(servers["other"])
    }

    func test_merge_throws_whenExistingConfigIsCorrupt() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try "not json".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/x"))
    }

    func test_detect_explicitDevKeyMatchesEntry() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham-dev":{"command":"/dev/path/maugham-mcp"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(
                configURL: path, expectedBinary: "/dev/path/maugham-mcp", serverKey: "maugham-dev"),
            .configured(path: "/dev/path/maugham-mcp"))
    }

    func test_detect_stableKeyIgnoresDevEntry() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham-dev":{"command":"/dev/x"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/stable/x", serverKey: "maugham"),
            .unconfigured)
    }

    func test_merge_writesEnvBlockWhenSocketPathProvided() throws {
        let dir = tmp()
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try ClaudeDesktopConfig.merge(
            configURL: path,
            maughamBinary: "/x",
            serverKey: "maugham-dev",
            socketPath: "/tmp/dev.sock")
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        let devEntry = try XCTUnwrap(servers["maugham-dev"] as? [String: Any])
        XCTAssertEqual(devEntry["command"] as? String, "/x")
        let env = try XCTUnwrap(devEntry["env"] as? [String: String])
        XCTAssertEqual(env["MAUGHAM_MCP_SOCKET"], "/tmp/dev.sock")
    }

    func test_merge_devAndStableCoexist() throws {
        let dir = tmp()
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/stable", serverKey: "maugham", socketPath: "/s.sock")
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/dev", serverKey: "maugham-dev", socketPath: "/d.sock")
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["maugham"])
        XCTAssertNotNil(servers["maugham-dev"])
    }

    func test_remove_onlyRemovesGivenKey() throws {
        let dir = tmp()
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/stable", serverKey: "maugham")
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/dev", serverKey: "maugham-dev")
        try ClaudeDesktopConfig.removeMaughamEntry(configURL: path, serverKey: "maugham-dev")
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["maugham"])
        XCTAssertNil(servers["maugham-dev"])
    }
}
