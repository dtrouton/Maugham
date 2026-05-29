import XCTest
@testable import Maugham

@MainActor
final class ListMaughamToolsToolTests: XCTestCase {

    // MARK: - Full catalog

    func test_listMaughamTools_returnsFullCatalog() async throws {
        let data = try await ListMaughamToolsTool.handle(paramsJSON: nil, registry: ProjectRegistry())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let tools = json["tools"] as! [[String: Any]]
        let server = json["server"] as! [String: Any]
        let returned = json["returned"] as! Int
        let toolCount = server["tool_count"] as! Int

        // Unfiltered: tools == server.tool_count == catalog size == returned.
        let catalogCount = MCPToolCatalog.all.count
        XCTAssertEqual(toolCount, catalogCount,
                       "server.tool_count must equal the live catalog size")
        XCTAssertEqual(tools.count, catalogCount,
                       "tools array must contain every catalog entry when unfiltered")
        XCTAssertEqual(returned, tools.count,
                       "returned must match the actual tools array length")

        // A few known names must be present.
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("compile"),
                      "expected 'compile' in tool list")
        XCTAssertTrue(names.contains("set_piece_style"),
                      "expected 'set_piece_style' in tool list")
        XCTAssertTrue(names.contains("list_maugham_tools"),
                      "list_maugham_tools must include itself")
    }

    // MARK: - name_contains filter

    func test_listMaughamTools_nameContainsFilter() async throws {
        let params = #"{"name_contains":"piece"}"#
        let data = try await ListMaughamToolsTool.handle(
            paramsJSON: Data(params.utf8), registry: ProjectRegistry())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let tools = json["tools"] as! [[String: Any]]
        let server = json["server"] as! [String: Any]
        let returned = json["returned"] as! Int
        let toolCount = server["tool_count"] as! Int

        // Filtered subset must be strictly smaller than the full catalog.
        XCTAssertLessThan(returned, toolCount,
                          "filter 'piece' should match fewer than all tools")
        XCTAssertEqual(returned, tools.count,
                       "returned must match the filtered tools array length")

        // server.tool_count must still be the TOTAL catalog size, not the filtered count.
        XCTAssertEqual(toolCount, MCPToolCatalog.all.count,
                       "server.tool_count must be the full total regardless of filter")

        // Every returned name must contain "piece".
        for tool in tools {
            let name = (tool["name"] as? String) ?? ""
            XCTAssertTrue(name.lowercased().contains("piece"),
                          "filter='piece' returned a non-matching tool: \(name)")
        }

        // Expected piece tools are present in the filtered results.
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("set_piece_style"), "expected 'set_piece_style'")
        XCTAssertTrue(names.contains("clear_piece_style"), "expected 'clear_piece_style'")
    }

    // MARK: - Server identity

    func test_listMaughamTools_serverIdentityPresent() async throws {
        let data = try await ListMaughamToolsTool.handle(paramsJSON: nil, registry: ProjectRegistry())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let server = json["server"] as! [String: Any]

        let name = server["name"] as? String ?? ""
        let buildVariant = server["build_variant"] as? String ?? ""
        let version = server["version"] as? String ?? ""
        let toolCount = server["tool_count"] as? Int

        XCTAssertFalse(name.isEmpty, "server.name must be non-empty")
        XCTAssertFalse(buildVariant.isEmpty, "server.build_variant must be non-empty")
        XCTAssertFalse(version.isEmpty, "server.version must be non-empty")
        XCTAssertNotNil(toolCount, "server.tool_count must be an integer")

        // built_at distinguishes one (placeholder-versioned) dev build from
        // another. The running test executable has an mtime, so it must be a
        // non-empty ISO8601 string here (key is always present; null only if
        // the executable mtime is somehow unreadable).
        let builtAt = server["built_at"] as? String
        XCTAssertNotNil(builtAt, "server.built_at must be an ISO8601 string for the running binary")
        XCTAssertFalse(builtAt?.isEmpty ?? true, "server.built_at must be non-empty")

        // build = CFBundleVersion (git short SHA on Debug, run_number on Release).
        // Always present as a non-empty string (key never absent).
        let build = server["build"] as? String
        XCTAssertNotNil(build, "server.build must be present (CFBundleVersion)")
        XCTAssertFalse(build?.isEmpty ?? true, "server.build must be non-empty")

        // server.name must match the same value used in the initialize handshake.
        XCTAssertEqual(name, BuildVariant.current.mcpServerKey,
                       "server.name must match BuildVariant.current.mcpServerKey")

        // build_variant must be one of the known values.
        XCTAssertTrue(["dev", "stable"].contains(buildVariant),
                      "build_variant must be 'dev' or 'stable', got: \(buildVariant)")
    }
}
