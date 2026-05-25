import Foundation

// MARK: - Project-scope tasks (milestone-tasks)
//
// Pane-created tasks that don't belong to any particular document live in
// `.maugham/ops/__project__.jsonl` — a synthetic doc id that flows through
// the existing op-log infrastructure (`OpLogStore`, the presenter classifier
// in `MaughamSidecarPath`, etc.) without a new sidecar enum case.
//
// `listTasksAcrossProject(filter:)` is the read API the right-pane Tasks
// segment will use in project scope. It aggregates open documents'
// `Document.tasks(filter:)` projections with the project op log, and caches
// the merged result behind a version-token key per spec §9.5.
//
// State for this seam (stored properties + the public observable
// `projectTasksVersion` + the cache) lives on `ProjectStore` itself — the
// `@Observable` macro can't synthesize storage in an extension, so this
// file holds only behavior.

extension ProjectStore {

    /// Reserved synthetic doc id for project-scope pane-created tasks.
    /// Ops written under `.maugham/ops/__project__.jsonl` use this as their
    /// `Op.docId`. `MaughamSidecarPath.classify` already routes that path
    /// to `.opLog(docId: "__project__")` because the path-shape parser is
    /// content-agnostic — no new case needed.
    public static let projectTasksDocId = "__project__"

    // MARK: - Mutation

    /// Create a new project-scope pane task. Returns a synthetic preview
    /// `WriterTask`; the next `listTasksAcrossProject(filter:)` call will
    /// re-derive and produce a matching task.
    @discardableResult
    public func createProjectPaneTask(
        body: String, parentTaskId: String? = nil
    ) -> WriterTask {
        ensureProjectOpLogLoaded()
        let opId = ULID.generate()
        let priority = lowestProjectTaskPriority() + 1.0
        let op = Op(
            opId: opId,
            docId: Self.projectTasksDocId,
            at: Date(),
            device: projectOpDevice,
            session: projectOpSession,
            kind: .taskCreate,
            changes: [],
            sequence: nil,
            provenance: Op.Provenance(
                sessionId: projectOpSession,
                taskId: opId,
                taskBody: body,
                taskPriority: priority,
                taskParentId: parentTaskId,
                taskKind: TaskKind.paneCreated.rawValue))
        appendProjectTaskOp(op)
        return WriterTask(
            id: opId, kind: .paneCreated,
            anchor: TaskAnchor(
                docId: Self.projectTasksDocId, paragraphId: nil),
            body: body, status: .open, priority: priority,
            parentTaskId: parentTaskId, createdAt: op.at,
            createdBySession: projectOpSession)
    }

    /// Append an op to the project-scope op log. Updates the sync mirror
    /// immediately, bumps the project-log version + the SwiftUI-observable
    /// `projectTasksVersion`, and fires a fire-and-forget disk append.
    /// JSONLAppendStore dedupes by opId so even pathological re-entry is
    /// safe on disk.
    public func appendProjectTaskOp(_ op: Op) {
        ensureProjectOpLogLoaded()
        _projectOpLogMirror.append(op)
        _projectLogVersion &+= 1
        projectTasksVersion &+= 1
        // Invalidate the cross-project cache so the next list rebuilds.
        _projectTasksCacheKey = nil

        let store = OpLogStore(projectURL: url)
        Task { @MainActor in
            try? await store.append(op)
        }
    }

    /// In-memory snapshot of the project-scope op log. Lazily-loaded from
    /// disk on first call; thereafter the sync mirror is authoritative.
    public func projectTasksOpLog() -> [Op] {
        ensureProjectOpLogLoaded()
        return _projectOpLogMirror
    }

    // MARK: - Aggregation read API

    /// Aggregate task list across every open document plus the project-scope
    /// op log. Behind a version-token cache (spec §9.5): repeated calls
    /// without intervening mutation reuse the same derivation.
    ///
    /// Closed documents are intentionally NOT included in this aggregation
    /// in this milestone — their inline `- [ ]` tasks only surface once the
    /// user opens the document. Pane-created project-wide tasks are
    /// independently visible via the project op log. A future milestone
    /// can extend this to read closed-doc op logs from disk; the cache key
    /// is shaped to accept a closed-doc mtime hash sum when that lands.
    public func listTasksAcrossProject(
        filter: TaskFilter
    ) -> [WriterTask] {
        ensureProjectOpLogLoaded()
        let key = currentAggregationKey()
        if _projectTasksCacheKey == key {
            return _projectTasksCache.filter(matches(filter))
        }
        return rebuildAggregationCache(key: key).filter(matches(filter))
    }

    // MARK: - Helpers

    private func currentAggregationKey() -> ProjectTasksCacheKey {
        let openSum = (documentStore?.allOpenDocuments() ?? [])
            .reduce(0) { $0 &+ $1.tasksVersion }
        // Fold closed-doc op log mtimes into the key so the cache
        // re-derives when a closed doc's tasks change (cross-Mac sync,
        // external edit, or a doc that was open earlier in the session
        // and has since been unloaded).
        var closedSum: Int = 0
        let openDocIds = Set((documentStore?.allOpenDocuments() ?? [])
            .map(\.docId))
        for item in Self.collectDocuments(in: manifest.structure) {
            if openDocIds.contains(item.id) { continue }
            let opLogURL = url.appendingPathComponent(
                ".maugham/ops/\(item.id).jsonl")
            if let attrs = try? FileManager.default.attributesOfItem(
                atPath: opLogURL.path),
               let mtime = attrs[.modificationDate] as? Date {
                closedSum &+= Int(mtime.timeIntervalSince1970 * 1000)
            }
        }
        return .init(
            perDocVersionSum: openSum &+ closedSum,
            projectLogVersion: _projectLogVersion)
    }

    @discardableResult
    private func rebuildAggregationCache(
        key: ProjectTasksCacheKey
    ) -> [WriterTask] {
        #if DEBUG
        _debugTasksRebuildCount &+= 1
        #endif

        var all: [WriterTask] = []

        // 1a. Open-doc tasks (every status, so the cached array can serve
        //     any follow-up filter without re-derive).
        let allStatuses = Set(TaskStatus.allCases)
        var openDocIds: Set<String> = []
        if let ds = documentStore {
            for doc in ds.allOpenDocuments() {
                openDocIds.insert(doc.docId)
                let docTasks = doc.tasks(
                    filter: TaskFilter(
                        scope: .document(docId: doc.docId),
                        statuses: allStatuses))
                all.append(contentsOf: docTasks)
            }
        }

        // 1b. Closed-doc tasks. Walk every document in the manifest that
        //     isn't currently open; read its op log + .md directly without
        //     instantiating a full `Document` actor. This keeps the Tasks
        //     pane's Project scope honest — every chapter contributes,
        //     not just whatever's loaded in the editor right now.
        //
        //     Sync disk reads here are deliberate: the project-pane
        //     refresh shouldn't block on async actor initialization for
        //     every doc, and per-doc op logs are small. The aggregation
        //     cache key folds each closed doc's op-log mtime so we
        //     re-derive only when something on disk changes.
        for item in Self.collectDocuments(in: manifest.structure) {
            if openDocIds.contains(item.id) { continue }
            guard let path = item.path else { continue }
            let fileURL = url.appendingPathComponent(path)
            let opLogURL = url.appendingPathComponent(
                ".maugham/ops/\(item.id).jsonl")
            // Read paragraphs from the .md (the autosave-canonical source
            // for ordering and live paragraph text).
            let mdText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let parsed = ParagraphParser.parse(mdText)
            var paragraphs: [String: String] = [:]
            for p in parsed {
                guard let pid = p.id else { continue }
                paragraphs[pid] = p.text
            }
            // Read ops from the op log JSONL.
            var ops: [Op] = []
            if FileManager.default.fileExists(atPath: opLogURL.path),
               let data = try? Data(contentsOf: opLogURL),
               let text = String(data: data, encoding: .utf8) {
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let lineData = String(line).data(using: .utf8),
                          let op = try? dec.decode(Op.self, from: lineData)
                    else { continue }
                    ops.append(op)
                }
            }
            let (closedTasks, _) = TaskDeriver.derive(
                ops: ops, paragraphs: paragraphs, docId: item.id)
            all.append(contentsOf: closedTasks)
        }

        // 2. Project-scope pane-created tasks. Derive from the synthetic
        //    op log directly. No paragraphs (this log never references any).
        let (projectTasks, _) = TaskDeriver.derive(
            ops: _projectOpLogMirror,
            paragraphs: [:],
            docId: Self.projectTasksDocId)
        all.append(contentsOf: projectTasks)

        _projectTasksCache = all
        _projectTasksCacheKey = key
        projectTasksVersion &+= 1
        return all
    }

    private func matches(_ filter: TaskFilter) -> (WriterTask) -> Bool {
        return { task in
            guard filter.statuses.contains(task.status) else { return false }
            switch filter.scope {
            case .document(let docId):
                return task.anchor?.docId == docId
            case .project:
                return true
            }
        }
    }

    /// Lowest priority across the project-scope op log's currently-derived
    /// tasks. New project pane tasks get `lowest + 1.0` so they land at the
    /// head of the list. Mirrors `Document.lowestPriorityForDoc`.
    private func lowestProjectTaskPriority() -> Double {
        let (projectTasks, _) = TaskDeriver.derive(
            ops: _projectOpLogMirror,
            paragraphs: [:],
            docId: Self.projectTasksDocId)
        return projectTasks.map(\.priority).min() ?? 0.0
    }

    /// Lazily populate `_projectOpLogMirror` from disk the first time any
    /// project-task entry point is hit. After the first call the mirror is
    /// authoritative — disk writes are fire-and-forget but `JSONLAppendStore`
    /// dedupes by opId so we won't double-count on a future reload.
    private func ensureProjectOpLogLoaded() {
        guard !_projectOpLogLoaded else { return }
        _projectOpLogLoaded = true
        let logURL = url
            .appendingPathComponent(".maugham/ops/\(Self.projectTasksDocId).jsonl")
        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        // Synchronous read — the project log is tiny (pane-created tasks
        // only). Skipping NSFileCoordinator here is acceptable for this
        // local-only synthetic log; if iCloud coordination ever matters,
        // route through OpLogStore.load via a startup async task instead.
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        var seen = Set<String>()
        var ops: [Op] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let d = String(line).data(using: .utf8),
                  let op = try? dec.decode(Op.self, from: d) else { continue }
            if seen.insert(op.opId).inserted {
                ops.append(op)
            }
        }
        ops.sort { $0.opId < $1.opId }
        _projectOpLogMirror = ops
    }
}
