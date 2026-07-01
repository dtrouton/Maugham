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

    // MARK: - test_list_checkpoints

    @MainActor
    func test_listCheckpoints_reflectsCapturedCheckpoint() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Cps")
        defer { fx.teardown() }
        _ = try await TestCheckpointTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)","label":"one"}"#.data(using: .utf8),
            registry: fx.registry)
        let data = try await TestListCheckpointsTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)"}"#.data(using: .utf8), registry: fx.registry)
        let result = try JSONDecoder().decode(TestListCheckpointsTool.Result.self, from: data)
        XCTAssertGreaterThanOrEqual(result.count, 1)
        XCTAssertTrue(result.labels.contains("one"), "expected 'one' among captured labels: \(result.labels)")
    }

    @MainActor
    func test_listCheckpoints_unknownProject_throws() async throws {
        let registry = ProjectRegistry()
        do {
            _ = try await TestListCheckpointsTool.handle(paramsJSON:
                #"{"project_id":"nope"}"#.data(using: .utf8), registry: registry)
            XCTFail("expected unknownProjectID toolError")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    // MARK: - test_pending_buffer

    @MainActor
    func test_pendingBuffer_reflectsUnburstedEdit() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Pending")
        defer { fx.teardown() }
        let docParams = #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)"}"#.data(using: .utf8)

        // Before any edit, the freshly-bootstrapped doc has nothing un-bursted.
        let before = try JSONDecoder().decode(
            TestPendingBufferTool.Result.self,
            from: try await TestPendingBufferTool.handle(paramsJSON: docParams, registry: fx.registry))
        XCTAssertEqual(before.change_count, 0)

        _ = try await TestApplyEditTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)","new_text":"First paragraph.\n\nSecond paragraph."}"#
                .data(using: .utf8), registry: fx.registry)

        let after = try JSONDecoder().decode(
            TestPendingBufferTool.Result.self,
            from: try await TestPendingBufferTool.handle(paramsJSON: docParams, registry: fx.registry))
        XCTAssertGreaterThanOrEqual(after.change_count, 1, "editing should record at least one un-bursted paragraph change")
    }

    // MARK: - test_autosave_status

    @MainActor
    func test_autosaveStatus_transitionsFromPendingToFlushed() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Autosave")
        defer { fx.teardown() }
        let docParams = #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)"}"#.data(using: .utf8)

        _ = try await TestApplyEditTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)","new_text":"First paragraph.\n\nSecond paragraph."}"#
                .data(using: .utf8), registry: fx.registry)

        let pendingStatus = try JSONDecoder().decode(
            TestAutosaveStatusTool.Result.self,
            from: try await TestAutosaveStatusTool.handle(paramsJSON: docParams, registry: fx.registry))
        XCTAssertTrue(pendingStatus.has_pending, "un-bursted edit should report has_pending == true")
        XCTAssertFalse(pendingStatus.last_echo_written_at.isEmpty)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: pendingStatus.last_echo_written_at),
            "last_echo_written_at should be a valid ISO8601 timestamp")

        _ = try await TestFlushAutosaveTool.handle(paramsJSON: docParams, registry: fx.registry)

        let flushedStatus = try JSONDecoder().decode(
            TestAutosaveStatusTool.Result.self,
            from: try await TestAutosaveStatusTool.handle(paramsJSON: docParams, registry: fx.registry))
        XCTAssertFalse(flushedStatus.has_pending, "flushing the burst + autosave should drain the pending buffer")
    }

    @MainActor
    func test_autosaveStatus_docNotOpen_throwsInvalidArgument() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Autosave")
        defer { fx.teardown() }
        let params = #"{"project_id":"\#(fx.projectId)","doc_id":"doc-not-open"}"#.data(using: .utf8)
        do {
            _ = try await TestAutosaveStatusTool.handle(paramsJSON: params, registry: fx.registry)
            XCTFail("expected invalidArgument")
        } catch MCPError.invalidArgument {
            // expected
        }
    }
}
