import Foundation

/// Pure projection from an op log + current paragraph map to a list of
/// `WriterTask`. Mirrors `AnnotationDeriver` shape; no I/O, no `Document`
/// reference. Same inputs → same output.
///
/// See `docs/superpowers/specs/2026-05-23-tasks-design.md` §5 and
/// `docs/superpowers/specs/2026-05-25-task-anchors-and-lifecycle.md` §2.3.
public enum TaskDeriver {

    // MARK: - MintedAnchor side-channel

    /// Side-channel record describing a freshly-minted task anchor that the
    /// caller (Document) must persist back into paragraph text. Each value
    /// names the paragraph and intra-paragraph location where the anchor
    /// span should be spliced in.
    ///
    /// Task 5 consumes this to rewrite `paragraphs[paragraphId]`; Task 4
    /// only emits it.
    public struct MintedAnchor: Equatable, Sendable {
        public let paragraphId: String
        /// Post-scan body (anchor-free, exactly what the scanner returned —
        /// no whitespace normalization).
        public let body: String
        /// Freshly minted 6-char anchor id (alphabet matches ParagraphID).
        public let anchorId: String
        /// 0-based line index within the paragraph. For markdown line tasks
        /// this is the line containing the `- [ ]`; for Fountain inline
        /// tasks it is the line containing the `[[todo:…]]` segment.
        public let lineIndex: Int
        /// Optional intra-line UTF-16 offset for Fountain inline tasks,
        /// pointing immediately after the closing `]]` of the matched
        /// segment. `nil` for markdown line-style tasks (whole-line append).
        public let intraLineOffset: Int?
        public let kind: TaskKind

        public init(
            paragraphId: String, body: String, anchorId: String,
            lineIndex: Int, intraLineOffset: Int?, kind: TaskKind
        ) {
            self.paragraphId = paragraphId
            self.body = body
            self.anchorId = anchorId
            self.lineIndex = lineIndex
            self.intraLineOffset = intraLineOffset
            self.kind = kind
        }
    }

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
    /// - Returns: The sorted task list (parent-then-child interleave), a
    ///   side-channel of rebalance ops, and a side-channel of
    ///   freshly-minted task anchors that the caller should persist back
    ///   into paragraph text.
    public static func derive(
        ops: [Op],
        paragraphs: [String: String],
        docId: String
    ) -> (tasks: [WriterTask], rebalanceOps: [Op], mintedAnchors: [MintedAnchor]) {

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
        //    `[[todo:]]`/`[[done:]]`. Both produce synth ids keyed on the
        //    per-task `<!--t-XXXXXX-->` anchor in the .md. Tasks without
        //    anchors get one minted on the spot; the side-channel
        //    `mintedAnchors` lets the caller persist them back into
        //    paragraph text. No more body-hash dedupe — each anchor is
        //    unique by construction.
        var inlines: [WriterTask] = []
        var mintedAnchors: [MintedAnchor] = []
        var inlineTailIndex = 0

        // Deterministic order across rederives: sort paragraph ids.
        let paragraphKeys = paragraphs.keys.sorted()

        for pid in paragraphKeys {
            guard let text = paragraphs[pid] else { continue }

            // 2a. Markdown checkboxes — line-scan.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (lineIndex, line) in lines.enumerated() {
                guard let match = MarkdownCheckboxScanner.match(String(line))
                else { continue }
                let anchorId: String
                if let existing = match.anchorId {
                    anchorId = existing
                } else {
                    let fresh = TaskAnchorID.mint()
                    anchorId = fresh
                    mintedAnchors.append(MintedAnchor(
                        paragraphId: pid,
                        body: match.body,
                        anchorId: fresh,
                        lineIndex: lineIndex,
                        intraLineOffset: nil,
                        kind: .inlineMarkdown))
                }
                let synth = "inline:\(docId):\(anchorId)"
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

            // 2b. Fountain boneyards — scan across the whole paragraph.
            //     Use both `matchAll` (carries Match metadata incl. anchorId)
            //     and `matchTodoAll` (carries NSRange positions). Both come
            //     from the same regex, in source order, so zipping is safe.
            let bones = FountainBoneyardScanner.matchAll(text)
            let positions = FountainBoneyardScanner.matchTodoAll(text)
            let ns = text as NSString
            for (bone, pos) in zip(bones, positions) {
                let anchorId: String
                // Compute lineIndex and intraLineOffset from the position.
                // lineIndex = count of "\n" chars in [0, prefixRange.location).
                // intraLineOffset = bodyRange.upperBound + 2 (the `]]` glyph),
                // expressed relative to the START OF THE LINE, not absolute.
                let prefixLoc = pos.prefixRange.location
                let bodyUpper = pos.bodyRange.location + pos.bodyRange.length
                // Find the absolute position immediately after `]]`.
                let afterCloseAbs = bodyUpper + 2
                // Walk back to find the start of the line containing prefix.
                var lineIndex = 0
                var lineStartAbs = 0
                if prefixLoc > 0 {
                    let prefixHead = ns.substring(
                        with: NSRange(location: 0, length: prefixLoc))
                    let nsPrefixHead = prefixHead as NSString
                    // Count newlines.
                    var i = 0
                    while i < nsPrefixHead.length {
                        let ch = nsPrefixHead.character(at: i)
                        if ch == 0x0A {
                            lineIndex += 1
                            lineStartAbs = i + 1
                        }
                        i += 1
                    }
                }
                let intraLineOffset = afterCloseAbs - lineStartAbs
                if let existing = bone.anchorId {
                    anchorId = existing
                } else {
                    let fresh = TaskAnchorID.mint()
                    anchorId = fresh
                    mintedAnchors.append(MintedAnchor(
                        paragraphId: pid,
                        body: bone.body,
                        anchorId: fresh,
                        lineIndex: lineIndex,
                        intraLineOffset: intraLineOffset,
                        kind: .fountainBoneyard))
                }
                let synth = "inline:\(docId):\(anchorId)"
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

        // 2c. Archived inline tasks (text gone, op log remembers).
        //     Inline tasks vanish from the text scan once their anchor is
        //     spliced out by archive. To keep them in the Archived filter,
        //     synthesize entries from `.taskArchive` ops whose taskId has
        //     the `inline:` prefix AND whose synth-id isn't represented in
        //     the live `inlines` array we just built. `Document.archiveTask`
        //     captures the task's body + kind in the op provenance for
        //     exactly this purpose.
        let livePresentIds = Set(inlines.map(\.id))
        for op in effectiveOps where op.kind == .taskArchive {
            guard let tid = op.provenance?.taskId,
                  tid.hasPrefix("inline:"),
                  !livePresentIds.contains(tid),
                  let body = op.provenance?.taskBody,
                  let kindRaw = op.provenance?.taskKind,
                  let kind = TaskKind(rawValue: kindRaw)
            else { continue }
            // Preserve doc identity for the doc-scope filter. The synth-id
            // shape is `inline:<docId>:<anchorId>`; extract docId so the
            // pane's Document-scope archive filter can still find it.
            // paragraphId is nil — the anchor's been spliced out of text.
            let parts = tid.split(separator: ":")
            let extractedDocId = parts.count >= 3 ? String(parts[1]) : docId
            inlines.append(WriterTask(
                id: tid,
                kind: kind,
                anchor: TaskAnchor(docId: extractedDocId, paragraphId: nil),
                body: body,
                status: .archived,
                priority: 0,
                parentTaskId: nil,
                createdAt: op.at,
                createdBySession: op.provenance?.sessionId))
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

        return (sorted, rebalanceOps, mintedAnchors)
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
