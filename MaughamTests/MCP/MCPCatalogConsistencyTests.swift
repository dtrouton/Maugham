import XCTest
@testable import Maugham

/// Seam test owned by neither MCPToolsListHandler nor MaughamApp.registerTools.
/// Asserts the contract: every tool the catalog advertises is dispatchable,
/// and every dispatched method is advertised. Catches drift between the two
/// sides without depending on either side's internal logic.
@MainActor
final class MCPCatalogConsistencyTests: XCTestCase {

    // MARK: - Catalog ↔ tools/list

    /// Every method in MCPToolCatalog.all appears in the tools/list response,
    /// and tools/list never advertises anything not in the catalog.
    func test_catalogMethods_matchToolsListResponse() async throws {
        let catalogMethods = Set(MCPToolCatalog.all.map { $0.method })

        let data = try await MCPToolsListHandler.handle(paramsJSON: nil)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tools = json["tools"] as! [[String: Any]]
        let advertisedMethods = Set(tools.compactMap { $0["name"] as? String })

        XCTAssertEqual(catalogMethods, advertisedMethods,
                       "tools/list and MCPToolCatalog.all must list the same methods")
    }

    // MARK: - Catalog ↔ router

    /// Every catalog method round-trips through the router that production
    /// registration produces — i.e., no method in the catalog is missing
    /// from the dispatcher.
    func test_catalogMethods_areAllDispatchable() async {
        let registry = ProjectRegistry()
        let router = MCPRouter()
        MCPToolCatalog.register(router: router, registry: registry)

        for tool in MCPToolCatalog.all {
            do {
                _ = try await router.dispatch(method: tool.method, paramsJSON: nil)
            } catch MCPRouterError.methodNotFound(let m) {
                XCTFail("catalog method \(m) is not registered on the router")
            } catch {
                // Any other error (param decoding, missing project, etc.) is fine —
                // we only assert the wiring exists, not that the tool succeeds with
                // nil params.
            }
        }
    }

    // MARK: - Schema sanity

    /// Each tool's inputSchemaJSON parses as valid JSON. Catches typos at
    /// test time rather than at Claude Desktop's first tools/list call.
    func test_everyToolHasParseableInputSchema() throws {
        for tool in MCPToolCatalog.all {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)),
                "\(tool.method) has malformed inputSchemaJSON")
        }
    }

    /// Each tool's inputSchema declares object type and a properties dict.
    /// Claude Desktop relies on this shape; a regression here breaks argument
    /// rendering for all clients.
    func test_everyToolSchemaIsAnObjectWithProperties() throws {
        for tool in MCPToolCatalog.all {
            let parsed = try JSONSerialization.jsonObject(
                with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any]
            XCTAssertEqual(parsed?["type"] as? String, "object",
                           "\(tool.method) inputSchema.type must be \"object\"")
            XCTAssertNotNil(parsed?["properties"],
                            "\(tool.method) inputSchema must declare properties")
        }
    }
}
