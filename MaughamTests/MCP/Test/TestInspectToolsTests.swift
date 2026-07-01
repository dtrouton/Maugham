import XCTest
@testable import Maugham
@testable import MaughamCore

final class TestInspectToolsTests: XCTestCase {
    @MainActor
    func test_dumpDocument_reportsParagraphsAndDisplayText() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Inspect")
        defer { fx.teardown() }
        let params = #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)"}"#.data(using: .utf8)
        let data = try await TestDumpDocumentTool.handle(paramsJSON: params, registry: fx.registry)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["display_text"])
        XCTAssertNotNil(obj?["sequence"])
    }

    @MainActor
    func test_dumpDocument_paragraphsKeyedBySequence_andCleanDiskFormStripsAnchors() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Inspect")
        defer { fx.teardown() }
        let params = #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)"}"#.data(using: .utf8)
        let data = try await TestDumpDocumentTool.handle(paramsJSON: params, registry: fx.registry)
        let result = try JSONDecoder().decode(TestDumpDocumentTool.Result.self, from: data)

        XCTAssertFalse(result.sequence.isEmpty, "freshly bootstrapped doc should have at least one paragraph")
        for id in result.sequence {
            XCTAssertNotNil(result.paragraphs[id], "paragraph \(id) from sequence missing from paragraphs dict")
        }
        XCTAssertTrue(result.materialized.contains("<!-- ¶"),
            "materialized form is expected to carry inline ¶id anchors: \(result.materialized)")
        XCTAssertFalse(result.clean_disk_form.contains("<!--"),
            "clean_disk_form must have anchors stripped: \(result.clean_disk_form)")
    }

    @MainActor
    func test_dumpDocument_unknownProject_throws() async throws {
        let registry = ProjectRegistry()
        let params = #"{"project_id":"nope","doc_id":"doc-x"}"#.data(using: .utf8)
        do {
            _ = try await TestDumpDocumentTool.handle(paramsJSON: params, registry: registry)
            XCTFail("expected unknownProjectID toolError")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    @MainActor
    func test_dumpDocument_docNotOpen_throwsInvalidArgument() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Inspect")
        defer { fx.teardown() }
        let params = #"{"project_id":"\#(fx.projectId)","doc_id":"doc-not-open"}"#.data(using: .utf8)
        do {
            _ = try await TestDumpDocumentTool.handle(paramsJSON: params, registry: fx.registry)
            XCTFail("expected invalidArgument")
        } catch MCPError.invalidArgument {
            // expected
        }
    }

    @MainActor
    func test_dumpOplog_reportsBootstrapOp() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Inspect")
        defer { fx.teardown() }
        let params = #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)"}"#.data(using: .utf8)
        let data = try await TestDumpOplogTool.handle(paramsJSON: params, registry: fx.registry)
        let result = try JSONDecoder().decode(TestDumpOplogTool.Result.self, from: data)

        XCTAssertGreaterThan(result.count, 0, "a freshly loaded doc should have at least a bootstrap op")
        XCTAssertEqual(result.ops.count, result.count)
        XCTAssertTrue(result.ops.contains { $0.kind == "bootstrap" },
            "expected a bootstrap op in the log; got kinds: \(result.ops.map { $0.kind })")
        XCTAssertEqual(result.ops.map { $0.sequence_index }, Array(0..<result.count))
    }
}
