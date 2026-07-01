import XCTest
@testable import Maugham
@testable import MaughamCore

final class TestLifecycleToolsTests: XCTestCase {
    @MainActor
    func test_flushAutosave_writesCleanMarkdownToDisk() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Flush")
        defer { fx.teardown() }
        _ = try await TestApplyEditTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)","new_text":"Hello world."}"#.data(using: .utf8),
            registry: fx.registry)
        _ = try await TestFlushAutosaveTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)"}"#.data(using: .utf8),
            registry: fx.registry)
        let onDisk = try String(contentsOf: fx.docFileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("Hello world."))
        XCTAssertFalse(onDisk.contains("<!-- ¶"), "disk form must be anchor-free (ADR 0019)")
    }

    @MainActor
    func test_flushAutosave_resultReportsCleanDiskBytes() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "FlushBytes")
        defer { fx.teardown() }
        _ = try await TestApplyEditTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)","new_text":"Hello world."}"#.data(using: .utf8),
            registry: fx.registry)
        let data = try await TestFlushAutosaveTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)"}"#.data(using: .utf8),
            registry: fx.registry)
        let result = try JSONDecoder().decode(TestFlushAutosaveTool.Result.self, from: data)
        XCTAssertTrue(result.ok)
        XCTAssertGreaterThan(result.clean_disk_bytes, 0)
    }

    @MainActor
    func test_checkpoint_capturesAndReportsCount() async throws {
        let fx = try await OpenTestProjectFixture.novel(named: "Checkpoint")
        defer { fx.teardown() }
        _ = try await TestApplyEditTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)","new_text":"Hello world."}"#.data(using: .utf8),
            registry: fx.registry)
        let data = try await TestCheckpointTool.handle(paramsJSON:
            #"{"project_id":"\#(fx.projectId)","doc_id":"\#(fx.docId)","label":"My Checkpoint"}"#.data(using: .utf8),
            registry: fx.registry)
        let result = try JSONDecoder().decode(TestCheckpointTool.Result.self, from: data)
        XCTAssertEqual(result.label, "My Checkpoint")
        XCTAssertGreaterThanOrEqual(result.checkpoint_count, 1)
    }

    // test_quit is NOT unit-tested here: it terminates the host process
    // (MaughamTests runs injected into the live Maugham.app), which would
    // kill the test runner. It's verified in the manual smoke instead.

    @MainActor
    func test_resetWorkspace_emptiesRoot() async throws {
        let junk = TestWorkspace.root.appendingPathComponent("junk.txt")
        try? FileManager.default.createDirectory(at: TestWorkspace.root, withIntermediateDirectories: true)
        try "x".write(to: junk, atomically: true, encoding: .utf8)
        _ = try await TestResetWorkspaceTool.handle(paramsJSON: nil, registry: ProjectRegistry())
        XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: TestWorkspace.root.path))
    }
}
