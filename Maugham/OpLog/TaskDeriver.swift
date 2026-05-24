import Foundation
import CryptoKit

/// Pure projection from an op log + current paragraph map to a list of
/// `WriterTask`. Mirrors `AnnotationDeriver` shape; no I/O, no `Document`
/// reference. Same inputs → same output.
///
/// See `docs/superpowers/specs/2026-05-23-tasks-design.md` §5.
public enum TaskDeriver {

    // MARK: - Public entry point

    /// Derive the task projection for a single `docId`.
    ///
    /// - Parameters:
    ///   - ops: The op log for this doc (or the project log if `docId ==
    ///     "__project__"`). Order must reflect on-disk order; lifecycle ops
    ///     within the array follow latest-wins semantics by walk order.
    ///   - paragraphs: Map of `paragraphId` → current paragraph text. Empty
    ///     for the project log (no manuscript-backed inline tasks).
    ///   - docId: The doc this derive is for; appears in `TaskAnchor.docId`
    ///     and in synthetic inline/fountain task ids.
    /// - Returns: The sorted task list (parent-then-child interleave) and a
    ///   side-channel of rebalance ops that the caller should append to its
    ///   op log so the rebalanced priorities persist.
    public static func derive(
        ops: [Op],
        paragraphs: [String: String],
        docId: String
    ) -> (tasks: [WriterTask], rebalanceOps: [Op]) {

        // 0. Apply rewind semantics: if there is a `.checkpointRestore` with
        //    `synthesisSource == .rewind`, task ops between its `sourceCheckpoint`
        //    and the restore op itself are "undone." Replay is: all ops up to
        //    and including `sourceCheckpoint`, then all ops after the restore op
        //    (new post-rewind mutations). Multiple nested rewinds are handled by
        //    folding: the last rewind wins.
        //
        //    Only task-lifecycle kinds are excluded from the rewind window (they
        //    are the only state owned purely by TaskDeriver). Manuscript ops such
        //    as `.typingBurst` are not excluded here because `paragraphs` is
        //    already the post-restore text state when `Document.rebuildTasksCache`
        //    calls us (paragraph state is managed by `Deriver`, not TaskDeriver).
        let effectiveOps: [Op]
        if let rewindOp = ops.last(where: {
            $0.kind == .checkpointRestore
                && $0.provenance?.synthesisSource == .rewind
        }),
           let sourceId = rewindOp.provenance?.sourceCheckpoint,
           let sourceIdx = ops.firstIndex(where: { $0.opId == sourceId }),
           let rewindIdx = ops.firstIndex(where: { $0.opId == rewindOp.opId })
        {
            // Task-lifecycle op kinds that live in the rewind window and must
            // be discarded. Non-task ops in the window are also discarded here
            // for simplicity — `paragraphs` already reflects post-restore text.
            let taskKinds: Set<OpKind> = [
                .taskCreate, .taskStatusChange, .taskPriorityChange,
                .taskParentChange, .taskBodyEdit, .taskArchive
            ]
            // Prefix through sourceCheckpoint + suffix after the restore op.
            let before = Array(ops.prefix(through: sourceIdx))
            let after   = Array(ops.dropFirst(rewindIdx + 1))
            // From the window (sourceIdx+1 ..< rewindIdx) keep only non-task ops
            // (there are currently none, but guard against future additions).
            let window = ops[(sourceIdx + 1) ..< rewindIdx].filter {
                !taskKinds.contains($0.kind)
            }
            effectiveOps = before + window + after
        } else {
            effectiveOps = ops
        }

        // 1. Walk ops once. Build pane-created seeds + lifecycle overrides
        //    for synthetic-id (inline/fountain) targets.
        var panes: [String: PaneSeed] = [:]
        var overrides: [String: InlineOverride] = [:]

        for op in effectiveOps {
            switch op.kind {
            case .taskCreate:
                guard let id = op.provenance?.taskId,
                      let body = op.provenance?.taskBody,
                      let prio = op.provenance?.taskPriority else { continue }
                panes[id] = PaneSeed(
                    id: id,
                    body: body,
                    priority: prio,
                    parentTaskId: op.provenance?.taskParentId,
                    status: .open,
                    createdAt: op.at,
                    createdBySession: op.provenance?.sessionId,
                    anchorDocId: op.docId)

            case .taskStatusChange:
                guard let id = op.provenance?.taskId,
                      let statusRaw = op.provenance?.taskStatus,
                      let status = TaskStatus(rawValue: statusRaw) else { continue }
                if panes[id] != nil {
                    panes[id]?.status = status
                } else {
                    overrides[id, default: .init()].status = status
                }

            case .taskPriorityChange:
                guard let id = op.provenance?.taskId,
                      let prio = op.provenance?.taskPriority else { continue }
                if panes[id] != nil {
                    panes[id]?.priority = prio
                } else {
                    overrides[id, default: .init()].priority = prio
                }

            case .taskParentChange:
                guard let id = op.provenance?.taskId,
                      let raw = op.provenance?.taskParentId else { continue }
                // "" sentinel clears parent; any other value sets it.
                let resolved: String? = raw.isEmpty ? nil : raw
                if panes[id] != nil {
                    panes[id]?.parentTaskId = resolved
                } else {
                    overrides[id, default: .init()].parentTaskId = .some(resolved)
                }

            case .taskBodyEdit:
                guard let id = op.provenance?.taskId,
                      let body = op.provenance?.taskBody else { continue }
                if panes[id] != nil {
                    panes[id]?.body = body
                }
                // Body edits on synthetic ids are ignored — inline body edits
                // happen via paragraph text and change the synthetic id.

            case .taskArchive:
                guard let id = op.provenance?.taskId else { continue }
                if panes[id] != nil {
                    panes[id]?.status = .archived
                } else {
                    overrides[id, default: .init()].status = .archived
                }

            default:
                break
            }
        }

        // 2. Scan paragraphs for inline markdown checkboxes + Fountain
        //    `[[todo:]]`/`[[done:]]`. Both produce synthetic, body-hash-keyed
        //    ids. Duplicate-body collapse via `seenIds`.
        var inlines: [WriterTask] = []
        var seenIds: Set<String> = []
        var inlineTailIndex = 0

        // Deterministic order across rederives: sort paragraph ids.
        let paragraphKeys = paragraphs.keys.sorted()

        for pid in paragraphKeys {
            guard let text = paragraphs[pid] else { continue }

            // 2a. Markdown checkboxes — line-scan.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                if let match = MarkdownCheckboxScanner.match(String(line)) {
                    let synth = "inline:\(docId):\(pid):\(bodyHash(match.body))"
                    if seenIds.contains(synth) { continue }
                    seenIds.insert(synth)
                    inlineTailIndex += 1
                    var task = WriterTask(
                        id: synth,
                        kind: .inlineMarkdown,
                        anchor: TaskAnchor(docId: docId, paragraphId: pid),
                        body: match.body,
                        status: match.checked ? .done : .open,
                        priority: defaultTailPriority(index: inlineTailIndex),
                        parentTaskId: nil,
                        createdAt: Date.distantPast,
                        createdBySession: nil)
                    task = applyOverride(task, overrides[synth])
                    inlines.append(task)
                }
            }

            // 2b. Fountain boneyards — scan across the whole paragraph.
            let bones = FountainBoneyardScanner.matchAll(text)
            for bone in bones {
                let synth = "fountain:\(docId):\(pid):\(bodyHash(bone.body))"
                if seenIds.contains(synth) { continue }
                seenIds.insert(synth)
                inlineTailIndex += 1
                var task = WriterTask(
                    id: synth,
                    kind: .fountainBoneyard,
                    anchor: TaskAnchor(docId: docId, paragraphId: pid),
                    body: bone.body,
                    status: bone.done ? .done : .open,
                    priority: defaultTailPriority(index: inlineTailIndex),
                    parentTaskId: nil,
                    createdAt: Date.distantPast,
                    createdBySession: nil)
                task = applyOverride(task, overrides[synth])
                inlines.append(task)
            }
        }

        // 3. Merge inlines + pane-created. Pane order: by createdAt then id
        //    so output is stable.
        var all: [WriterTask] = inlines
        let paneSeedsSorted = panes.values.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id < b.id
        }
        for seed in paneSeedsSorted {
            // Pane tasks anchored to the doc they were created in. For the
            // project log (docId == "__project__"), `seed.anchorDocId` is
            // "__project__" — caller decides how to surface it.
            all.append(WriterTask(
                id: seed.id,
                kind: .paneCreated,
                anchor: TaskAnchor(docId: seed.anchorDocId, paragraphId: nil),
                body: seed.body,
                status: seed.status,
                priority: seed.priority,
                parentTaskId: seed.parentTaskId,
                createdAt: seed.createdAt,
                createdBySession: seed.createdBySession))
        }

        // 4. Normalize parent references — if a child points to a parent id
        //    that isn't in the result set, treat as parent-less.
        let knownIds = Set(all.map(\.id))
        all = all.map { task in
            guard let parent = task.parentTaskId, !knownIds.contains(parent) else {
                return task
            }
            return WriterTask(
                id: task.id, kind: task.kind, anchor: task.anchor,
                body: task.body, status: task.status, priority: task.priority,
                parentTaskId: nil,
                createdAt: task.createdAt,
                createdBySession: task.createdBySession)
        }

        // 5. Rebalance precision-drift check.
        let (balanced, rebalanceOps) = rebalanceIfNeeded(all, docId: docId)

        // 6. Sort parent-then-child interleave.
        let sorted = sortParentInterleaved(balanced)

        return (sorted, rebalanceOps)
    }

    // MARK: - bodyHash (spec §3.2)

    /// Normalized SHA-256 prefix. Trim → lowercase → collapse internal
    /// whitespace → SHA-256 → first 8 hex chars (= first 4 bytes hex-encoded).
    /// `internal` (not `private`) so synthetic-id tests can pin it without
    /// re-running the full derive.
    internal static func bodyHash(_ body: String) -> String {
        let normalized = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Internals

    private struct PaneSeed {
        let id: String
        var body: String
        var priority: Double
        var parentTaskId: String?
        var status: TaskStatus
        let createdAt: Date
        let createdBySession: String?
        let anchorDocId: String
    }

    /// Holds lifecycle overrides keyed by synthetic (inline / fountain) id —
    /// the underlying task surface doesn't exist as a pane seed.
    private struct InlineOverride {
        var status: TaskStatus? = nil
        var priority: Double? = nil
        /// `.some(nil)` means "clear parent"; `.none` means "no override".
        var parentTaskId: String?? = .none
    }

    private static func applyOverride(_ task: WriterTask, _ ov: InlineOverride?) -> WriterTask {
        guard let ov else { return task }
        let parent: String?
        if case .some(let p) = ov.parentTaskId {
            parent = p
        } else {
            parent = task.parentTaskId
        }
        return WriterTask(
            id: task.id,
            kind: task.kind,
            anchor: task.anchor,
            body: task.body,
            status: ov.status ?? task.status,
            priority: ov.priority ?? task.priority,
            parentTaskId: parent,
            createdAt: task.createdAt,
            createdBySession: task.createdBySession)
    }

    private static func defaultTailPriority(index: Int) -> Double {
        // Inline tasks default to large evenly-spaced priorities so a pane
        // task created with `lowestPriority + 1.0` slots ahead naturally.
        // Tests don't rely on this magnitude — only on order being stable.
        return Double(index)
    }

    // MARK: - Rebalance

    /// Detect precision drift within sibling groups (same `parentTaskId`).
    /// If any consecutive pair within a group has priority delta < 1e-9,
    /// rewrite the whole group with evenly-spaced integer priorities (1.0,
    /// 2.0, …) and emit one `.taskPriorityChange` per rewritten task.
    private static func rebalanceIfNeeded(
        _ tasks: [WriterTask], docId: String
    ) -> (rebalanced: [WriterTask], ops: [Op]) {

        // Group by parentTaskId. We use the optional directly as key via a
        // sentinel for nil.
        var groups: [String: [WriterTask]] = [:]
        for t in tasks {
            let key = t.parentTaskId ?? "__root__"
            groups[key, default: []].append(t)
        }

        var newOps: [Op] = []
        var newPriorities: [String: Double] = [:]

        for (_, members) in groups {
            let sorted = members.sorted { $0.priority < $1.priority }
            guard sorted.count >= 2 else { continue }
            var needs = false
            for i in 1..<sorted.count {
                if (sorted[i].priority - sorted[i - 1].priority) < 1e-9 {
                    needs = true
                    break
                }
            }
            if !needs { continue }
            for (idx, t) in sorted.enumerated() {
                let newPrio = Double(idx + 1)
                if newPrio != t.priority {
                    newPriorities[t.id] = newPrio
                    newOps.append(Op(
                        opId: "rebalance_\(t.id)",
                        docId: docId,
                        at: Date(),
                        device: "rebalance",
                        session: "rebalance",
                        kind: .taskPriorityChange,
                        changes: [],
                        sequence: nil,
                        provenance: Op.Provenance(
                            taskId: t.id,
                            taskPriority: newPrio)))
                } else {
                    // Even if unchanged, ensure the in-memory result has it.
                    newPriorities[t.id] = newPrio
                }
            }
        }

        guard !newOps.isEmpty || !newPriorities.isEmpty else { return (tasks, []) }

        let rebalanced = tasks.map { t -> WriterTask in
            guard let p = newPriorities[t.id] else { return t }
            return WriterTask(
                id: t.id, kind: t.kind, anchor: t.anchor,
                body: t.body, status: t.status, priority: p,
                parentTaskId: t.parentTaskId,
                createdAt: t.createdAt,
                createdBySession: t.createdBySession)
        }
        return (rebalanced, newOps)
    }

    // MARK: - Parent-then-child interleave sort

    private static func sortParentInterleaved(_ tasks: [WriterTask]) -> [WriterTask] {
        let parents = tasks.filter { $0.parentTaskId == nil }
            .sorted { $0.priority < $1.priority }
        var childrenByParent: [String: [WriterTask]] = [:]
        for t in tasks where t.parentTaskId != nil {
            childrenByParent[t.parentTaskId!, default: []].append(t)
        }
        var result: [WriterTask] = []
        for parent in parents {
            result.append(parent)
            let kids = (childrenByParent[parent.id] ?? [])
                .sorted { $0.priority < $1.priority }
            result.append(contentsOf: kids)
        }
        return result
    }
}
