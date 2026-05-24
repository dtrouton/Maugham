import XCTest
@testable import Maugham

@MainActor
final class MCPTasksTests: XCTestCase {

    // MARK: - Fixture

    private struct Harness {
        let projectURL: URL
        let projectId: String
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let doc: Document
        let docPath: String
    }

    private func makeHarness(initialMd: String = "Hello.") async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-test"
        try initialMd.write(
            to: tmp.appendingPathComponent(docPath),
            atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: docId, title: "C1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let pStore = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        pStore.documentStore = ds

        let docURL = tmp.appendingPathComponent(docPath)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: pStore)
        let projectId = ProjectIdentifier.id(for: tmp)

        return Harness(
            projectURL: tmp, projectId: projectId,
            projectStore: pStore, documentStore: ds,
            registry: reg, doc: doc, docPath: docPath)
    }

    private func firstParagraphId(of doc: Document) async throws -> String {
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }),
              let pid = bootstrap.changes.first?.paragraphId else {
            XCTFail("no bootstrap paragraph")
            throw NSError(domain: "test", code: 0)
        }
        return pid
    }

    private func decodeListResponse(_ data: Data) throws -> ListTasksTool.Response {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(ListTasksTool.Response.self, from: data)
    }

    private func decodeRecord(_ data: Data) throws -> TaskRecord {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(TaskRecord.self, from: data)
    }

    // MARK: - list_tasks

    func test_listTasks_documentScope_returnsTasksForThatDoc() async throws {
        let h = try await makeHarness(initialMd: "Hello.")
        let pid = try await firstParagraphId(of: h.doc)
        h.doc.setParagraph(id: pid, text: "- [ ] inline thing")
        _ = h.doc.createPaneTask(body: "pane thing", parentTaskId: nil)
        // A project-scope pane task should NOT appear in doc scope.
        _ = h.projectStore.createProjectPaneTask(body: "project thing")

        let args: [String: Any] = [
            "project_id": h.projectId,
            "scope": "document",
            "document_id": h.doc.docId
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ListTasksTool.handle(
            paramsJSON: data, registry: h.registry)
        let response = try decodeListResponse(result)

        let bodies = Set(response.tasks.map(\.body))
        XCTAssertTrue(bodies.contains("inline thing"))
        XCTAssertTrue(bodies.contains("pane thing"))
        XCTAssertFalse(
            bodies.contains("project thing"),
            "project-scope tasks must not leak into document scope")

        await h.documentStore.close()
    }

    func test_listTasks_projectScope_aggregatesAllSources() async throws {
        let h = try await makeHarness(initialMd: "Hello.")
        let pid = try await firstParagraphId(of: h.doc)
        h.doc.setParagraph(id: pid, text: "- [ ] inline thing")
        _ = h.doc.createPaneTask(body: "doc pane", parentTaskId: nil)
        _ = h.projectStore.createProjectPaneTask(body: "project pane")

        let args: [String: Any] = [
            "project_id": h.projectId,
            "scope": "project"
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ListTasksTool.handle(
            paramsJSON: data, registry: h.registry)
        let response = try decodeListResponse(result)

        let bodies = Set(response.tasks.map(\.body))
        XCTAssertTrue(bodies.contains("inline thing"))
        XCTAssertTrue(bodies.contains("doc pane"))
        XCTAssertTrue(bodies.contains("project pane"))

        // The project-scope task surfaces its synthetic doc id literally.
        let projectRecord = response.tasks.first { $0.body == "project pane" }
        XCTAssertEqual(
            projectRecord?.document_id, ProjectStore.projectTasksDocId)

        await h.documentStore.close()
    }

    func test_listTasks_statusFilter_open_excludesDoneAndArchived() async throws {
        let h = try await makeHarness(initialMd: "Hello.")
        let openTask = h.doc.createPaneTask(body: "still open", parentTaskId: nil)
        let doneTask = h.doc.createPaneTask(body: "finished", parentTaskId: nil)
        h.doc.setTaskStatus(id: doneTask.id, status: .done)
        let archivedTask = h.doc.createPaneTask(body: "gone", parentTaskId: nil)
        h.doc.archiveTask(id: archivedTask.id)

        // Default statuses (omitted) → open only.
        let args: [String: Any] = [
            "project_id": h.projectId,
            "scope": "document",
            "document_id": h.doc.docId
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ListTasksTool.handle(
            paramsJSON: data, registry: h.registry)
        let response = try decodeListResponse(result)

        let ids = Set(response.tasks.map(\.id))
        XCTAssertTrue(ids.contains(openTask.id))
        XCTAssertFalse(ids.contains(doneTask.id))
        XCTAssertFalse(ids.contains(archivedTask.id))

        // Explicit ["done","archived"] should surface the other two.
        let argsAll: [String: Any] = [
            "project_id": h.projectId,
            "scope": "document",
            "document_id": h.doc.docId,
            "statuses": ["done", "archived"]
        ]
        let dataAll = try JSONSerialization.data(withJSONObject: argsAll)
        let resultAll = try await ListTasksTool.handle(
            paramsJSON: dataAll, registry: h.registry)
        let responseAll = try decodeListResponse(resultAll)
        let idsAll = Set(responseAll.tasks.map(\.id))
        XCTAssertFalse(idsAll.contains(openTask.id))
        XCTAssertTrue(idsAll.contains(doneTask.id))
        XCTAssertTrue(idsAll.contains(archivedTask.id))

        await h.documentStore.close()
    }

    func test_listTasks_documentScope_withoutDocId_returnsErrorEnvelope() async throws {
        let h = try await makeHarness()

        let args: [String: Any] = [
            "project_id": h.projectId,
            "scope": "document"
            // document_id intentionally omitted.
        ]
        let data = try JSONSerialization.data(withJSONObject: args)

        do {
            _ = try await ListTasksTool.handle(
                paramsJSON: data, registry: h.registry)
            XCTFail("expected toolError for missing document_id")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "document_id_required")
        } catch {
            XCTFail("expected MCPError.toolError, got \(error)")
        }

        await h.documentStore.close()
    }

    // MARK: - get_task

    func test_getTask_unknownId_returnsTaskNotFoundError() async throws {
        let h = try await makeHarness()
        _ = h.doc.createPaneTask(body: "a", parentTaskId: nil)

        let args: [String: Any] = [
            "project_id": h.projectId,
            "task_id": "no-such-id"
        ]
        let data = try JSONSerialization.data(withJSONObject: args)

        do {
            _ = try await GetTaskTool.handle(
                paramsJSON: data, registry: h.registry)
            XCTFail("expected toolError for unknown task_id")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "task_not_found")
            // Echo the requested id back in the structured payload.
            if case .string(let echoed) = payload.fields["task_id"] {
                XCTAssertEqual(echoed, "no-such-id")
            } else {
                XCTFail("task_not_found payload missing task_id field")
            }
        } catch {
            XCTFail("expected MCPError.toolError, got \(error)")
        }

        await h.documentStore.close()
    }

    func test_getTask_known_returnsFullRecord() async throws {
        let h = try await makeHarness()
        let task = h.doc.createPaneTask(body: "ship it", parentTaskId: nil)

        let args: [String: Any] = [
            "project_id": h.projectId,
            "task_id": task.id
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await GetTaskTool.handle(
            paramsJSON: data, registry: h.registry)
        let record = try decodeRecord(result)

        XCTAssertEqual(record.id, task.id)
        XCTAssertEqual(record.body, "ship it")
        XCTAssertEqual(record.kind, "pane_created")
        XCTAssertEqual(record.status, "open")
        XCTAssertEqual(record.document_id, h.doc.docId)

        await h.documentStore.close()
    }

    // MARK: - Catalog consistency

    func test_catalogConsistency_includesListTasksAndGetTask() {
        let methods = MCPToolCatalog.all.map { $0.method }
        XCTAssertTrue(methods.contains("list_tasks"))
        XCTAssertTrue(methods.contains("get_task"))
    }

    func test_noTaskWriteToolsExist() {
        let methods = MCPToolCatalog.all.map { $0.method }
        XCTAssertFalse(methods.contains("create_task"))
        XCTAssertFalse(methods.contains("complete_task"))
        XCTAssertFalse(methods.contains("archive_task"))
        XCTAssertFalse(methods.contains("reorder_task"))
    }
}
