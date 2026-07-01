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
}
