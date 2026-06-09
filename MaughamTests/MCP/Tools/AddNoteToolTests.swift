import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class AddNoteToolTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AN-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    /// Returns a project wired with a real DocumentStore so that
    /// `scheduleFileSave` / `flushPendingSave` work end-to-end.
    private func makeProjectWithDocumentStore() async throws
        -> (URL, ProjectStore, DocumentStore, ProjectRegistry)
    {
        let url = try await ProjectFactory.createNovelProject(
            named: "ANFlush-\(UUID().uuidString.prefix(8))",
            in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg)
    }

    func test_addNote_createsFileAndManifestEntry() async throws {
        let (url, store, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = """
        {"project_id":"\(id)","title":"Sarah notes","body":"# Sarah\\n\\n32 years old."}
        """
        let json = try await AddNoteTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let result = try JSONDecoder().decode(
            AddNoteTool.Result.self, from: json)
        XCTAssertEqual(result.title, "Sarah notes")
        XCTAssertEqual(store.manifest.research.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(result.path).path))
        // Verify body actually written
        let written = try String(
            contentsOfFile: url.appendingPathComponent(result.path).path, encoding: .utf8)
        XCTAssertTrue(written.contains("32 years old"))
    }

    func test_addNote_postsNotification() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let exp = expectation(forNotification: .maughamMCPNoteAdded, object: nil)
        let req = "{\"project_id\":\"\(id)\",\"title\":\"x\",\"body\":\"y\"}"
        _ = try await AddNoteTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        await fulfillment(of: [exp], timeout: 2)
    }

    func test_addNote_validatesParentGroup() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"title\":\"x\",\"body\":\"y\",\"parent_group_id\":\"nope\"}"
        do {
            _ = try await AddNoteTool.handle(paramsJSON: Data(req.utf8), registry: reg)
            XCTFail()
        } catch MCPError.invalidArgument {
            // ok
        } catch {
            XCTFail("wrong: \(error)")
        }
    }

    // MARK: - Flush-before-body-write (tripwire 14 / finding 1.6)

    /// Regression test: `add_note` must flush any pending `scheduleFileSave`
    /// BEFORE writing the body, so a queued 750ms debounce can't overwrite the
    /// body with stale (e.g. empty) content.
    ///
    /// Race shape (finding 1.6):
    ///   1. A `scheduleFileSave` for the to-be-created path is pending
    ///      (e.g. a prior note at the same slug was being edited).
    ///   2. `add_note` creates the empty file then writes the body.
    ///   3. WITHOUT the flush: the pending scheduler fires AFTER the body write
    ///      and overwrites the file with its stale (empty) payload → body lost.
    ///   4. WITH the flush: the scheduler is drained before the body write; any
    ///      subsequent `flushPendingSave` call is a no-op → body survives.
    ///
    /// Strategy: schedule a pending empty-string save to the path that `add_note`
    /// will create (`research/flush-race.md` for title "Flush Race"), call
    /// `add_note` with body content, then simulate the debounce timer firing.
    /// With the fix the body is intact; without it the file would be empty.
    func test_addNote_flushesSchedulerBeforeBodyWrite() async throws {
        let (url, store, ds, reg) = try await makeProjectWithDocumentStore()
        defer { Task { await ds.close() } }

        let id = ProjectIdentifier.id(for: url)

        // The slug for "Flush Race" is "flush-race" → file "research/flush-race.md".
        // Verify slug determinism so this test is self-documenting.
        let slug = Slugifier.slug(from: "Flush Race")
        XCTAssertEqual(slug, "flush-race",
            "slug mismatch — update the path in this test if Slugifier changes")
        let expectedPath = "research/flush-race.md"

        // Pre-schedule an empty-string save to the path that `add_note` will
        // create. This simulates the scheduler holding a stale empty payload
        // at that path (e.g. a prior note at the same slug was edited, deleted,
        // and the scheduler still has the pending write).
        ds.scheduleFileSave(for: expectedPath, text: "")

        // Call add_note — this should flush the pending empty save first (via
        // `flushPendingSave`), then write the body to disk.
        // Build the JSON via JSONSerialization to avoid manual escaping.
        let bodyText = "This body must survive the pending autosave."
        let reqObj: [String: String] = [
            "project_id": id,
            "title": "Flush Race",
            "body": bodyText
        ]
        let reqData = try JSONSerialization.data(withJSONObject: reqObj)
        let json = try await AddNoteTool.handle(paramsJSON: reqData, registry: reg)
        let result = try JSONDecoder().decode(AddNoteTool.Result.self, from: json)
        XCTAssertEqual(result.path, expectedPath,
            "path mismatch — slug dedup fired, meaning the file already existed "
            + "on disk when add_note ran; check test setup")

        // Simulate the 750ms debounce firing AFTER add_note returns.
        // With the fix: the scheduler was already flushed inside add_note — this
        //   call finds no pending payload and is a no-op. The body survives.
        // Without the fix: the scheduler still holds the empty-string payload —
        //   this call fires it, overwriting the body with "" (data loss).
        try? await ds.flushPendingSave()

        // Assert the body is still on disk.
        let fileURL = url.appendingPathComponent(expectedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
            "research note file missing at '\(expectedPath)'")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains(bodyText),
            "body was overwritten — the pending empty-string autosave fired after "
            + "the body write (tripwire-14 / finding 1.6). "
            + "Fix: `flushPendingSave()` in AddNoteTool before the body write. "
            + "Got: '\(content)'")

        // Sanity: the manifest entry was recorded.
        XCTAssertEqual(store.manifest.research.count, 1)
    }
}
