import XCTest
@testable import Maugham

final class MCPToolsListSmokeTest: XCTestCase {
    func test_toolsList_includesAnnotationTools() async throws {
        let data = try await MCPToolsListHandler.handle(paramsJSON: nil)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        let tools = json["tools"] as! [[String: Any]]
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: [
            "add_comment", "add_suggested_change", "add_query",
            "add_craft_note", "list_annotations", "get_annotation"
        ]))
        // Dev builds also advertise the dev-only `test_` tools; count only the
        // production catalog here (see TestMCPCatalogConsistencyTests for the
        // dev-tool discovery coverage).
        let productionCount = names.filter { !$0.hasPrefix("test_") }.count
        XCTAssertEqual(productionCount, 47)
    }
}
