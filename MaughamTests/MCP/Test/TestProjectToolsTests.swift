import XCTest
@testable import Maugham
@testable import MaughamCore

final class TestProjectToolsTests: XCTestCase {
    @MainActor
    func test_createProject_landsUnderWorkspace_andReturnsDocIds() async throws {
        try TestWorkspace.reset()
        let registry = ProjectRegistry()
        let params = #"{"type":"novel","name":"Smoke"}"#.data(using: .utf8)
        let data = try await TestCreateProjectTool.handle(paramsJSON: params, registry: registry)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let url = obj?["url"] as? String ?? ""
        XCTAssertTrue(url.hasPrefix(TestWorkspace.root.path), "project not under workspace: \(url)")
        // doc_ids derive from the on-disk manifest, so they're present even
        // though no SwiftUI window opens in a headless test.
        XCTAssertFalse((obj?["doc_ids"] as? [String] ?? []).isEmpty)
    }

    @MainActor
    func test_createProject_headless_reportsNotOpened() async throws {
        try TestWorkspace.reset()
        let registry = ProjectRegistry()
        let params = #"{"type":"novel","name":"Headless"}"#.data(using: .utf8)
        let data = try await TestCreateProjectTool.handle(paramsJSON: params, registry: registry)
        let result = try JSONDecoder().decode(TestProjectResult.self, from: data)
        // No SwiftUI window in XCTest → the non-fatal poll returns false rather
        // than hanging or throwing.
        XCTAssertFalse(result.opened)
        XCTAssertFalse(result.project_id.isEmpty)
    }

    @MainActor
    func test_createProject_unknownType_throwsInvalidArgument() async throws {
        try TestWorkspace.reset()
        let registry = ProjectRegistry()
        let params = #"{"type":"nonsense","name":"X"}"#.data(using: .utf8)
        do {
            _ = try await TestCreateProjectTool.handle(paramsJSON: params, registry: registry)
            XCTFail("expected invalidArgument for unknown type")
        } catch MCPError.invalidArgument {
            // expected
        }
    }

    @MainActor
    func test_openProject_returnsDocIdsFromDisk() async throws {
        try TestWorkspace.reset()
        let registry = ProjectRegistry()
        let createParams = #"{"type":"novel","name":"Reopen"}"#.data(using: .utf8)
        _ = try await TestCreateProjectTool.handle(paramsJSON: createParams, registry: registry)

        let openParams = #"{"name":"Reopen"}"#.data(using: .utf8)
        let data = try await TestOpenProjectTool.handle(paramsJSON: openParams, registry: registry)
        let result = try JSONDecoder().decode(TestProjectResult.self, from: data)
        XCTAssertTrue(result.url.hasPrefix(TestWorkspace.root.path))
        XCTAssertFalse(result.doc_ids.isEmpty, "open should read doc_ids from the on-disk manifest")
    }

    @MainActor
    func test_openProject_missing_throwsInvalidArgument() async throws {
        try TestWorkspace.reset()
        let registry = ProjectRegistry()
        let params = #"{"name":"DoesNotExist"}"#.data(using: .utf8)
        do {
            _ = try await TestOpenProjectTool.handle(paramsJSON: params, registry: registry)
            XCTFail("expected invalidArgument for missing project")
        } catch MCPError.invalidArgument {
            // expected
        }
    }

    @MainActor
    func test_openProject_traversalName_isFencedOutsideWorkspace() async throws {
        try TestWorkspace.reset()
        let registry = ProjectRegistry()
        let params = #"{"name":"../Evil"}"#.data(using: .utf8)
        do {
            _ = try await TestOpenProjectTool.handle(paramsJSON: params, registry: registry)
            XCTFail("expected outsideWorkspace fence for a traversal name")
        } catch TestWorkspaceError.outsideWorkspace {
            // expected — the fence rejects paths that escape the workspace
        }
    }
}
