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
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/x"),
            .configured(path: "/x"))
    }

    func test_state_isStalePath_whenMaughamEntryPathDiffers() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham":{"command":"/old/path/maugham-mcp"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/new/path/maugham-mcp"),
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
