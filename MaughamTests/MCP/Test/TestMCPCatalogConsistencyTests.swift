import XCTest
@testable import Maugham
@testable import MaughamCore

final class TestMCPCatalogConsistencyTests: XCTestCase {
    @MainActor
    func test_allTestMethods_arePrefixed_and_disjointFromProduction() {
        let prod = Set(MCPToolCatalog.all.map { $0.method })
        let test = Set(TestMCPToolCatalog.all.map { $0.method })
        for m in test { XCTAssertTrue(m.hasPrefix("test_"), "\(m) not test_-prefixed") }
        XCTAssertTrue(prod.isDisjoint(with: test), "test methods collide with production: \(prod.intersection(test))")
    }

    @MainActor
    func test_allTestTools_areDispatchable() async {
        let registry = ProjectRegistry()
        let router = MCPRouter()
        TestMCPToolCatalog.register(router: router, registry: registry)
        for tool in TestMCPToolCatalog.all {
            // test_quit takes no params, so dispatching it here would actually
            // run to completion and schedule NSApp.terminate — killing the
            // XCTest host process (MaughamTests runs injected into the live
            // Maugham.app via BUNDLE_LOADER/TEST_HOST). It's intentionally
            // unverifiable by automated dispatch; see the manual smoke.
            if tool.method == TestQuitTool.method { continue }
            do { _ = try await router.dispatch(method: tool.method, paramsJSON: nil) }
            catch MCPRouterError.methodNotFound(let m) { XCTFail("\(m) not registered") }
            catch { /* param/state errors fine */ }
        }
    }

    @MainActor
    func test_ping_returnsOkAndVariant() async throws {
        let registry = ProjectRegistry()
        let data = try await TestPingTool.handle(paramsJSON: nil, registry: registry)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertEqual(obj?["variant"] as? String, "dev")
    }

    /// Regression (2026-07-01, live-smoke find): the test tools were registered
    /// on the router (dispatchable) but the DISCOVERY paths — `tools/list` and
    /// `list_maugham_tools` — advertised only `MCPToolCatalog.all`. MCP clients
    /// discover tools via `tools/list`, so the test tools were invisible and
    /// uncallable despite every unit test passing (they dispatched on the router
    /// directly, never through discovery). Both surfaces must advertise the dev
    /// tools in a dev build.
    @MainActor
    func test_discoverySurfaces_advertiseTestTools_inDevBuild() async throws {
        let testMethods = TestMCPToolCatalog.all.map { $0.method }
        XCTAssertFalse(testMethods.isEmpty)

        // 1. tools/list (the MCP protocol discovery path Claude Code reads).
        let listData = try await MCPToolsListHandler.handle(paramsJSON: nil)
        let listObj = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let listed = Set((listObj?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        for m in testMethods { XCTAssertTrue(listed.contains(m), "tools/list missing dev tool \(m)") }
        for m in MCPToolCatalog.all.map({ $0.method }) {
            XCTAssertTrue(listed.contains(m), "tools/list dropped production tool \(m)")
        }

        // 2. list_maugham_tools (the authoritative self-report).
        let lmtData = try await ListMaughamToolsTool.handle(paramsJSON: nil, registry: ProjectRegistry())
        let lmtObj = try JSONSerialization.jsonObject(with: lmtData) as? [String: Any]
        let lmtNames = Set((lmtObj?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        for m in testMethods { XCTAssertTrue(lmtNames.contains(m), "list_maugham_tools missing dev tool \(m)") }
        let count = (lmtObj?["server"] as? [String: Any])?["tool_count"] as? Int
        XCTAssertEqual(count, MCPToolCatalog.all.count + TestMCPToolCatalog.all.count)
    }
}
