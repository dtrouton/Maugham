import XCTest
@testable import Maugham

/// Project-scope task surface: `__project__` op log + cross-project
/// aggregation cache. Mirrors `DocumentTasksTests` shape. See
/// `docs/superpowers/specs/2026-05-23-tasks-design.md` §9.3 + §9.5.
@MainActor
final class ProjectStoreTasksTests: XCTestCase {

    // MARK: - Fixture

    private func makeProject(initialMd: String = "Hello.") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PROJ-TASKS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    /// Wrapper that holds both stores so the weak `documentStore` link stays
    /// alive for the duration of a test. ARC otherwise drops `ds` as soon
    /// as the fixture function returns and aggregation sees an empty list.
    private struct StoreBundle {
        let store: ProjectStore
        let ds: DocumentStore
    }

    private func makeBundle() async throws -> StoreBundle {
        let (url, _) = try makeProject()
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return StoreBundle(store: store, ds: ds)
    }

    // MARK: - Project pane task creation

    func test_createProjectPaneTask_persistsToProjectLog() async throws {
        let b = try await makeBundle()
        let task = b.store.createProjectPaneTask(body: "revise act 2")
        let tasks = b.store.listTasksAcrossProject(filter: .init(scope: .project))
        XCTAssertTrue(tasks.contains(where: { $0.id == task.id }))
        XCTAssertEqual(tasks.first(where: { $0.id == task.id })?.body, "revise act 2")
        XCTAssertEqual(tasks.first(where: { $0.id == task.id })?.kind, .paneCreated)
    }

    func test_listTasksAcrossProject_aggregatesAllDocsPlusProjectLog() async throws {
        let b = try await makeBundle()
        let docURL = b.store.url.appendingPathComponent("manuscript/c1.md")
        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        b.ds.register(document: doc, for: "manuscript/c1.md")
        // Drop an inline checkbox via paragraph mutation.
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }),
              let pid = bootstrap.changes.first?.paragraphId else {
            return XCTFail("no bootstrap paragraph")
        }
        doc.setParagraph(id: pid, text: "- [ ] doc-level thing")
        let projectTask = b.store.createProjectPaneTask(body: "project-level thing")

        let tasks = b.store.listTasksAcrossProject(filter: .init(scope: .project))
        XCTAssertTrue(
            tasks.contains { $0.kind == .inlineMarkdown && $0.body == "doc-level thing" },
            "aggregation should include inline task")
        XCTAssertTrue(tasks.contains { $0.id == projectTask.id })
    }

    func test_projectTasksOpLog_returnsAppendedOps() async throws {
        let b = try await makeBundle()
        XCTAssertTrue(b.store.projectTasksOpLog().isEmpty)
        _ = b.store.createProjectPaneTask(body: "a")
        _ = b.store.createProjectPaneTask(body: "b")
        let ops = b.store.projectTasksOpLog()
        XCTAssertEqual(ops.count, 2)
        XCTAssertTrue(ops.allSatisfy { $0.kind == .taskCreate })
        XCTAssertTrue(ops.allSatisfy { $0.docId == ProjectStore.projectTasksDocId })
    }

    func test_projectLogPath_classifiesAsOpLogDocId() {
        let url = URL(fileURLWithPath: "/p/.maugham/ops/__project__.jsonl")
        let projectURL = URL(fileURLWithPath: "/p")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .opLog(docId: "__project__"))
    }

    // MARK: - Cross-project aggregation cache (spec §9.5)

    func test_aggregationCache_hit_doesNotRederive() async throws {
        let b = try await makeBundle()
        _ = b.store.createProjectPaneTask(body: "a")
        _ = b.store.listTasksAcrossProject(filter: .init(scope: .project))
        #if DEBUG
        let countBefore = b.store._debugTasksRebuildCount
        _ = b.store.listTasksAcrossProject(filter: .init(scope: .project))
        XCTAssertEqual(b.store._debugTasksRebuildCount, countBefore,
            "second listTasksAcrossProject with no mutation should hit cache")
        #endif
    }

    func test_aggregationCache_invalidates_onProjectAppend() async throws {
        let b = try await makeBundle()
        _ = b.store.listTasksAcrossProject(filter: .init(scope: .project))
        #if DEBUG
        let countBefore = b.store._debugTasksRebuildCount
        _ = b.store.createProjectPaneTask(body: "b")
        _ = b.store.listTasksAcrossProject(filter: .init(scope: .project))
        XCTAssertGreaterThan(b.store._debugTasksRebuildCount, countBefore)
        #endif
    }

    func test_aggregationCache_invalidates_onPerDocTasksVersionBump() async throws {
        let b = try await makeBundle()
        let docURL = b.store.url.appendingPathComponent("manuscript/c1.md")
        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        b.ds.register(document: doc, for: "manuscript/c1.md")
        _ = b.store.listTasksAcrossProject(filter: .init(scope: .project))
        #if DEBUG
        let countBefore = b.store._debugTasksRebuildCount
        // Mutate the open document so its tasksVersion bumps.
        _ = doc.createPaneTask(body: "doc pane", parentTaskId: nil)
        _ = b.store.listTasksAcrossProject(filter: .init(scope: .project))
        XCTAssertGreaterThan(b.store._debugTasksRebuildCount, countBefore)
        #endif
    }

    func test_projectTasksVersion_isObservable_bumpsOnMutation() async throws {
        let b = try await makeBundle()
        let v1 = b.store.projectTasksVersion
        _ = b.store.createProjectPaneTask(body: "c")
        XCTAssertGreaterThan(b.store.projectTasksVersion, v1)
    }
}
