import XCTest
import MaughamCore
@testable import Maugham

/// End-to-end regression for A5 (sidecar-supplied relative-path traversal):
/// a hostile or corrupted sidecar value must not be able to read or move
/// files outside the project root. One test per migrated surface —
/// `TrashStore` (trash `meta.json`), `read_document` (manifest research
/// `path`), `InboxStore` (inbox `sourceFilename`). The escape-rejection unit
/// matrix itself lives in `SafeRelativePathTests` (MaughamCoreTests); these
/// confirm the gate is actually wired into each call site.
@MainActor
final class SafeRelativePathSecurityTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    // MARK: - TrashStore.restore

    /// A trash `meta.json` whose `originalRelativePath` escapes the project
    /// root (crafted directly on disk — meta.json isn't re-validated at
    /// write time by every caller) must fail restore loudly rather than
    /// move the trashed file outside the project.
    func test_trashRestore_escapingOriginalRelativePath_throws_fileStaysInTrash() async throws {
        let project = temp.url.appendingPathComponent("TrashEscape")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let trashRoot = project.appendingPathComponent(".trash")
        let entryFolder = trashRoot.appendingPathComponent("20260101-000000-evil")
        try FileManager.default.createDirectory(at: entryFolder, withIntermediateDirectories: true)
        try "trashed content".write(
            to: entryFolder.appendingPathComponent("chapter.md"),
            atomically: true, encoding: .utf8)
        let maliciousMeta = """
        {
          "originalRelativePath": "../../../../tmp/srp-escape-\(UUID().uuidString).md",
          "displayTitle": "Evil",
          "itemMetadata": "",
          "originalParentId": null,
          "originalIndex": 0
        }
        """
        try maliciousMeta.write(
            to: entryFolder.appendingPathComponent("meta.json"),
            atomically: true, encoding: .utf8)

        let store = TrashStore(projectURL: project)
        do {
            _ = try await store.restore(trashId: "20260101-000000-evil")
            XCTFail("expected restore to throw on an escaping originalRelativePath")
        } catch let error as TrashStore.TrashError {
            guard case .unsafeRelativePath = error else {
                return XCTFail("expected .unsafeRelativePath, got \(error)")
            }
        }

        // The trashed file must still be sitting in the trash folder — never
        // moved to the escaping destination.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryFolder.appendingPathComponent("chapter.md").path),
            "file must remain in trash after a rejected restore")
    }

    // MARK: - read_document (research item path)

    /// A manifest research item whose `path` escapes the project root must
    /// fail `read_document` loudly rather than read a file elsewhere on disk.
    func test_readDocument_escapingResearchItemPath_throws() async throws {
        let project = temp.url.appendingPathComponent("ReadDocEscape")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let secretName = "srp-secret-\(UUID().uuidString).md"
        let secretURL = temp.url.appendingPathComponent(secretName)
        try "TOP SECRET, outside the project".write(
            to: secretURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secretURL) }

        let evilItem = ResearchItem(
            id: "research-evil", title: "Evil Note", type: .asset, kind: .document,
            path: "../\(secretName)")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [evilItem])
        try ProjectManifest.makeEncoder().encode(manifest).write(
            to: project.appendingPathComponent(ProjectManifest.fileName))

        let store = try await ProjectStore.load(from: project)
        let registry = ProjectRegistry()
        registry.register(url: project, store: store)
        let projectId = ProjectIdentifier.id(for: project)

        let paramsData = try JSONSerialization.data(withJSONObject: [
            "project_id": projectId,
            "document_id": "research-evil"])

        do {
            _ = try await ReadDocumentTool.handle(paramsJSON: paramsData, registry: registry)
            XCTFail("expected read_document to throw on an escaping research item path")
        } catch let error as MCPError {
            guard case .invalidArgument = error else {
                return XCTFail("expected .invalidArgument, got \(error)")
            }
        }
    }

    // MARK: - InboxStore.assetURL (sourceFilename)

    /// An inbox entry whose `sourceFilename` escapes the kind's asset subdir
    /// must resolve to no asset (same as an entry with no asset at all),
    /// so promote fails loudly (`InboxError.assetMissing`) instead of
    /// relocating a file from outside the inbox.
    func test_inboxPromote_escapingSourceFilename_failsLoudly_assetMissing() async throws {
        let parent = temp.url.appendingPathComponent("InboxEscape")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createNovelProject(named: "InboxEscape", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        defer { withExtendedLifetime(ds) {} }

        // A real file sitting just outside the inbox's audio subdir — the
        // attack target a "../../evil.m4a" sourceFilename would reach for.
        let inboxDir = url.appendingPathComponent(".maugham/inbox")
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let outsideTarget = inboxDir.appendingPathComponent("evil.m4a")
        try Data("should never be touched".utf8).write(to: outsideTarget)

        let inbox = InboxStore(projectURL: url, deviceId: "mac")
        let entry = InboxEntry(
            id: "escape1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "../evil.m4a",
            transcript: "irrelevant", transcriptionState: .whisperFinal)
        let seedFile = url.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        try await JSONLAppendStore<InboxEntry>(fileURL: seedFile).append(entry)
        await inbox.refresh()
        let loaded = try XCTUnwrap(inbox.entries.first { $0.id == "escape1" })

        XCTAssertNil(inbox.assetURL(for: loaded),
            "an escaping sourceFilename must not resolve to a URL")

        do {
            _ = try await inbox.promoteToResearch(loaded, projectStore: store)
            XCTFail("expected promote to throw on an escaping sourceFilename")
        } catch InboxStore.InboxError.assetMissing { /* expected */ }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideTarget.path),
            "the file outside the inbox subdir must be untouched")
    }
}
