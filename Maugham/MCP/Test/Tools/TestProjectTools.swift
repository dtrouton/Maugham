import Foundation
import MaughamCore

/// Shared result for the two drive tools: the on-disk facts of a
/// created/opened test project. `opened` reports whether a project window
/// actually registered a store within the bounded, non-fatal poll — `false`
/// in headless XCTest (no SwiftUI window), `true` in the running app.
public struct TestProjectResult: Codable {
    public let project_id: String
    public let url: String
    public let doc_ids: [String]
    public let opened: Bool
}

/// `test_create_project` — dev-only: create + (best-effort) open a project
/// under the test workspace, through the real `ProjectFactory` path.
public enum TestCreateProjectTool: MCPTool {
    public struct Params: Codable { let type: String; let name: String }
    public typealias Result = TestProjectResult
    public static let method = "test_create_project"
    public static let description = "Dev-only: create + open a project (novel/screenplay/short_story/collection) under the test workspace."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"type":{"type":"string"},"name":{"type":"string"}},"required":["type","name"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        // Ensure the workspace root exists WITHOUT wiping sibling test projects
        // (reset is a separate explicit tool).
        try FileManager.default.createDirectory(at: TestWorkspace.root, withIntermediateDirectories: true)
        let parent = TestWorkspace.root
        let url: URL
        switch p.type {
        case "novel":       url = try await ProjectFactory.createNovelProject(named: p.name, in: parent)
        case "screenplay":  url = try await ProjectFactory.createScreenplayProject(named: p.name, in: parent)
        case "short_story": url = try await ProjectFactory.createShortStoryProject(named: p.name, in: parent)
        case "collection":  url = try await ProjectFactory.createCollectionProject(named: p.name, in: parent)
        default: throw MCPError.invalidArgument("unknown type: \(p.type)")
        }
        // Belt-and-suspenders: the created path must be inside the workspace.
        try TestWorkspace.require(url)
        return try await TestProjectTools.encodeResult(url: url, registry: registry)
    }
}

/// `test_open_project` — dev-only: open an existing test-workspace project by
/// folder name.
public enum TestOpenProjectTool: MCPTool {
    public struct Params: Codable { let name: String }
    public typealias Result = TestProjectResult
    public static let method = "test_open_project"
    public static let description = "Dev-only: open an existing test-workspace project by folder name."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let url = TestWorkspace.root.appendingPathComponent(p.name)
        // Fence BEFORE touching the path — a `../` name can't escape the workspace.
        try TestWorkspace.require(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.invalidArgument("no such test project: \(p.name)")
        }
        return try await TestProjectTools.encodeResult(url: url, registry: registry)
    }
}

/// Shared plumbing for the two drive tools.
enum TestProjectTools {
    /// Build + encode the tool result: project_id from the URL, doc_ids read
    /// from the ON-DISK manifest (not an open Document — that is what makes the
    /// tools work headlessly), plus a best-effort window-open with a bounded,
    /// non-fatal registration poll.
    @MainActor
    static func encodeResult(url: URL, registry: ProjectRegistry) async throws -> Data {
        let projectId = ProjectIdentifier.id(for: url)
        let docIds = docIdsFromDisk(projectURL: url)
        let opened = await postOpenAndAwaitRegistration(url: url, registry: registry)
        return try JSONEncoder().encode(
            TestProjectResult(project_id: projectId, url: url.path, doc_ids: docIds, opened: opened))
    }

    /// Read document ids straight from the project manifest. A project's
    /// document ids are a fact of the manifest the instant `ProjectFactory`
    /// writes it — no live `Document` (and thus no SwiftUI window) required.
    /// Walks nested groups so compound structures are covered.
    static func docIdsFromDisk(projectURL: URL) -> [String] {
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? ProjectManifest.makeDecoder()
                  .decode(ProjectManifest.self, from: data) else {
            return []
        }
        var ids: [String] = []
        func walk(_ items: [StructureItem]) {
            for item in items {
                if item.type == .document { ids.append(item.id) }
                if let children = item.children { walk(children) }
            }
        }
        walk(manifest.structure)
        return ids
    }

    /// Post the dev-only open request and give the SwiftUI Welcome window a
    /// bounded, NON-FATAL chance to register the project store. In XCTest there
    /// is no window, so this returns `false` after the short budget — the tools
    /// never hang or throw on a missing window. In the running app the window
    /// opens and later inspect/edit tools resolve the now-open Document.
    @MainActor
    static func postOpenAndAwaitRegistration(url: URL, registry: ProjectRegistry) async -> Bool {
        let id = ProjectIdentifier.id(for: url)
        if registry.lookup(id: id) != nil { return true }
        NotificationCenter.default.post(
            name: .maughamTestOpenProject, object: nil, userInfo: ["url": url])
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline {
            if registry.lookup(id: id) != nil { return true }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        return false
    }
}
