import XCTest
@testable import Maugham

final class ClaudeCodeSkillInstallTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private var url: URL { temp.url.appendingPathComponent("skills/maugham/SKILL.md") }

    func test_detect_notInstalled() {
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T"),
                       .notInstalled)
    }

    func test_install_thenCurrent_thenStale_thenUpdateRestores() throws {
        try ClaudeCodeSkillInstall.install(installURL: url, template: "T v1")
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T v1"),
                       .installedCurrent)
        // App update ships new template → stale
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T v2"),
                       .stale)
        try ClaudeCodeSkillInstall.install(installURL: url, template: "T v2")
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T v2"),
                       .installedCurrent)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "T v2")
    }

    func test_userEditedFile_readsAsStale_installOverwritesOnlyOnExplicitCall() throws {
        try ClaudeCodeSkillInstall.install(installURL: url, template: "T")
        try "user edited".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: "T"),
                       .stale)
        // detect() must never write:
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "user edited")
    }

    func test_cliCommand_stableAndDevShapes() {
        XCTAssertEqual(
            ClaudeCodeSkillInstall.cliCommand(
                serverKey: "maugham",
                binaryPath: "/Applications/Maugham.app/Contents/MacOS/maugham-mcp",
                socketPath: nil),
            "claude mcp add maugham /Applications/Maugham.app/Contents/MacOS/maugham-mcp")
        XCTAssertEqual(
            ClaudeCodeSkillInstall.cliCommand(
                serverKey: "maugham-dev",
                binaryPath: "/tmp/Dev.app/Contents/MacOS/maugham-mcp",
                socketPath: "/tmp/dev.sock"),
            "claude mcp add maugham-dev --env \"MAUGHAM_MCP_SOCKET=/tmp/dev.sock\" -- /tmp/Dev.app/Contents/MacOS/maugham-mcp")
    }
}
