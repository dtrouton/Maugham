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

        // T5: the recordEditorTextWrite bookkeeping side-effect must actually
        // run (not just setFullText). ProjectStore caches the per-doc word count
        // written by recordWordCount inside recordEditorTextWrite, so a non-nil,
        // increased cachedWordCount proves the second half of the editor binding
        // fired. "The cat sat." is 3 prose words.
        let store = try XCTUnwrap(fx.registry.lookup(id: fx.projectId)?.store)
        let words = store.cachedWordCount(for: fx.docId)
        XCTAssertEqual(words, 3, "recordEditorTextWrite bookkeeping did not run (word count not recorded)")
    }

    /// Safety-boundary guard: a project that is OPEN in the registry but NOT
    /// under TestWorkspace.root must be rejected by the fence — test_apply_edit
    /// must THROW (not mutate) rather than touch a real out-of-workspace project.
    @MainActor
    func test_applyEdit_outsideWorkspace_throws() async throws {
        let fx = try await OpenTestProjectFixture.novelOutsideWorkspace(named: "EditGuard")
        defer { fx.teardown() }
        let params = #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)","new_text":"Should not land."}"#.data(using: .utf8)
        do {
            _ = try await TestApplyEditTool.handle(paramsJSON: params, registry: fx.registry)
            XCTFail("expected the TestWorkspace.require fence to throw for an out-of-workspace project")
        } catch TestWorkspaceError.outsideWorkspace {
            // expected
        }
        // And it must not have mutated the doc.
        let doc = try XCTUnwrap(fx.documentStore.document(forDocId: fx.docId))
        XCTAssertEqual(doc.displayText, "First paragraph.")
    }
}
