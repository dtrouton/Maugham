import XCTest
import MaughamCore
@testable import Maugham

final class TestEditToolTests: XCTestCase {
    @MainActor
    func test_applyEdit_setsDisplayText_viaEditorPath() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Edit")
        defer { fx.teardown() }
        let params = #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)","new_text":"The cat sat."}"#.data(using: .utf8)
        _ = try await TestApplyEditTool.handle(paramsJSON: params, registry: fx.registry)
        let dump = try await TestDumpDocumentTool.handle(
            paramsJSON: #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)"}"#.data(using: .utf8),
            registry: fx.registry)
        let obj = try JSONSerialization.jsonObject(with: dump) as? [String: Any]
        XCTAssertEqual(obj?["display_text"] as? String, "The cat sat.")
    }
}
