import Foundation
import MaughamCore

// MARK: - Shared record shape

/// Single JSON record shape used by both `list_tasks` and `get_task`.
/// Mirrors spec §10.1. `document_id` surfaces the task anchor's docId
/// verbatim — including the synthetic literal `"__project__"` for
/// project-scope pane-created tasks. That choice (rather than `null`)
/// gives the agent a stable handle that round-trips through the rest of
/// the read API: `read_document` would refuse `"__project__"`, but the
/// id itself is meaningful as "this task belongs to the project, not a
/// document," and the agent can branch on it without losing information.
public struct TaskRecord: Codable, Equatable {
    public let id: String
    public let kind: String
    public let document_id: String?
    public let paragraph_id: String?
    public let body: String
    public let status: String
    public let priority: Double
    public let parent_task_id: String?
    public let created_at: Date

    public init(_ task: WriterTask) {
        self.id = task.id
        self.kind = task.kind.rawValue
        self.document_id = task.anchor?.docId
        self.paragraph_id = task.anchor?.paragraphId
        self.body = task.body
        self.status = task.status.rawValue
        self.priority = task.priority
        self.parent_task_id = task.parentTaskId
        self.created_at = task.createdAt
    }
}

// MARK: - Error envelopes

extension MCPError {
    /// `task_not_found` — caller passed a `task_id` that isn't in the
    /// project's current derived task set. Same shape as
    /// `paragraph_not_found` for editing-milestone parity.
    public static func taskNotFound(taskId: String) -> MCPError {
        .toolError(payload: .init(
            error: "task_not_found",
            message: "Task '\(taskId)' is not in the project's current task set.",
            hint: "Call list_tasks (scope=\"project\") to refresh the task ids and retry. Task ids are stable across reorder/parent changes but disappear when the underlying op is rewound or the inline checkbox/boneyard text is removed.",
            fields: ["task_id": .string(taskId)]))
    }

    /// `document_id_required` — `list_tasks` was called with
    /// `scope == "document"` but no `document_id`.
    public static func taskDocumentIdRequired() -> MCPError {
        .toolError(payload: .init(
            error: "document_id_required",
            message: "list_tasks with scope=\"document\" requires document_id.",
            hint: "Either pass document_id or use scope=\"project\" to aggregate across the whole project.",
            fields: ["scope": .string("document")]))
    }
}

// MARK: - list_tasks

public enum ListTasksTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let scope: String
        public let document_id: String?
        public let statuses: [String]?
    }
    public struct Response: Codable, Equatable {
        public let tasks: [TaskRecord]
    }

    public static let method = "list_tasks"
    public static let description =
        "List tasks in a project. Aggregates inline `- [ ]` markdown " +
        "checkboxes, Fountain `[[todo:]]` boneyards, and pane-created " +
        "tasks. `scope`: \"document\" (requires document_id) or " +
        "\"project\" (every open doc + project-scope pane tasks). " +
        "`statuses` defaults to [\"open\"]; pass [\"open\",\"done\",\"archived\"] " +
        "to see everything. Read-only — task writes belong to the writer."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"scope":{"type":"string","enum":["document","project"]},"document_id":{"type":"string"},"statuses":{"type":"array","items":{"type":"string","enum":["open","done","archived"]}}},"required":["project_id","scope"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)

        // Default = open only. Explicit empty array also collapses to default.
        let statusFilter: Set<TaskStatus> = params.statuses.flatMap { raws in
            let set = Set(raws.compactMap(TaskStatus.init(rawValue:)))
            return set.isEmpty ? nil : set
        } ?? [.open]

        let tasks: [WriterTask]
        switch params.scope {
        case "document":
            guard let docId = params.document_id, !docId.isEmpty else {
                throw MCPError.taskDocumentIdRequired()
            }
            tasks = try await tasksForDocumentScope(
                projectEntry: entry, docId: docId, statuses: statusFilter)
        case "project":
            let filter = TaskFilter(scope: .project, statuses: statusFilter)
            tasks = entry.store.listTasksAcrossProject(filter: filter)
        default:
            throw MCPError.invalidArgument(
                "scope must be \"document\" or \"project\"")
        }

        let response = Response(tasks: tasks.map(TaskRecord.init))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(response)
    }

    /// Resolve doc-scope tasks. Loads the document transiently if it isn't
    /// already open in the editor — same policy as the annotation read
    /// tools so closed documents are still queryable.
    @MainActor
    private static func tasksForDocumentScope(
        projectEntry: ProjectRegistry.Entry,
        docId: String,
        statuses: Set<TaskStatus>
    ) async throws -> [WriterTask] {
        let filter = TaskFilter(
            scope: .document(docId: docId), statuses: statuses)
        // Live doc preferred — shared cache + version-token bookkeeping.
        if let ds = projectEntry.store.documentStore,
           let doc = ds.document(forDocId: docId) {
            return doc.tasks(filter: filter)
        }
        // Transient load. If docId isn't in the manifest, fall through to
        // an empty result rather than erroring — same shape as searching
        // for tasks in a non-existent doc returning [] (no `document_not_found`
        // error envelope was specified in §10; aligning with that silence).
        guard let item = TreeWalk.find(
                id: docId, in: projectEntry.store.manifest.structure),
              let path = item.path else {
            return []
        }
        let docURL = projectEntry.url.appendingPathComponent(path)
        let doc = try await Document.load(
            url: docURL, device: "mcp",
            session: "mcp-\(UUID().uuidString.prefix(8))",
            presenter: nil)
        let result = doc.tasks(filter: filter)
        Task { await doc.close() }
        return result
    }
}

// MARK: - get_task

public enum GetTaskTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let task_id: String
    }

    public static let method = "get_task"
    public static let description =
        "Return the full record for a single task by id. Searches across " +
        "every open document plus the project-scope pane-task log. Errors " +
        "with `task_not_found` if no derived task currently matches the id."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"task_id":{"type":"string"}},"required":["project_id","task_id"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)

        // Walk the project-scope aggregation across every status — the
        // caller asked for a specific id, not a status-filtered list, so
        // surface done/archived hits too.
        let filter = TaskFilter(
            scope: .project, statuses: Set(TaskStatus.allCases))
        let tasks = entry.store.listTasksAcrossProject(filter: filter)
        guard let match = tasks.first(where: { $0.id == params.task_id })
        else {
            throw MCPError.taskNotFound(taskId: params.task_id)
        }

        let record = TaskRecord(match)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(record)
    }
}

