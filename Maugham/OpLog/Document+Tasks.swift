import Foundation
import MaughamCore

extension Document {

    /// Whether a paragraph-text delta touches inline-task markup. Used to
    /// gate the tasks-cache invalidation fast path so non-checkbox typing
    /// stays off the observable-write hot loop (annotation cache + sweep
    /// pay the same observation cost and are intentionally deferred to
    /// burst flush — see setFullText note for the AttributeGraph cycle /
    /// reentrant-layout history). Two markup syntaxes count:
    ///
    /// - Markdown `- [ ]` / `- [x]` (3-char bracket glyph)
    /// - Fountain `[[todo: …]]` / `[[done: …]]`
    ///
    /// True when either prior or next text contains a checkbox/todo
    /// marker — covers add, remove, and toggle equally. Cheap substring
    /// scan; no regex needed because the body-hash deriver re-runs on
    /// the cache rebuild anyway.
    internal static func changeTouchesTaskMarkup(
        prior: String?, next: String?
    ) -> Bool {
        func hasMarkup(_ s: String) -> Bool {
            return s.contains("- [ ]") || s.contains("- [x]")
                || s.contains("[[todo:") || s.contains("[[done:")
        }
        if let p = prior, hasMarkup(p) { return true }
        if let n = next, hasMarkup(n) { return true }
        return false
    }

    // MARK: - Task read API

    /// Project the current op log + paragraph map into the filtered task
    /// list. Same caching pattern as `annotations(filter:)`. Inline-task
    /// status is text-is-state (read from paragraph contents); pane-created
    /// task lifecycle rides the op log. See spec §6.
    public func tasks(filter: TaskFilter) -> [WriterTask] {
        if !_tasksCacheValid { rebuildTasksCache() }
        return _tasksCache.filter { task in
            guard filter.statuses.contains(task.status) else { return false }
            switch filter.scope {
            case .document(let scopeDocId):
                return task.anchor?.docId == scopeDocId
            case .project:
                return true
            }
        }
    }

    internal func invalidateTasksCache() {
        _tasksCacheValid = false
        tasksVersion &+= 1
    }

    private func rebuildTasksCache() {
        guard !_isRebuildingTasks else {
            // Re-entrancy guard: rebalance op append triggers
            // invalidateTasksCache, AND so does the .taskCreate op emitted
            // per minted anchor in this same rebuild. Both arrive during
            // an in-flight derive whose result is mathematically idempotent
            // for the next call (rebalance has well-spaced priorities, mints
            // have anchored bodies that the deriver leaves alone). Returning
            // early here is the correct outcome — the freshly invalidated
            // cache will lazily rebuild on the next external `tasks(filter:)`
            // call.
            return
        }
        _isRebuildingTasks = true
        defer { _isRebuildingTasks = false }

        let (tasks, rebalanceOps, mintedAnchors) = TaskDeriver.derive(
            ops: _opLogMirror, paragraphs: paragraphs, docId: docId)
        _tasksCache = tasks
        _tasksCacheValid = true

        // Persist minted anchors back into paragraph text so autosave writes
        // the anchored .md on the next 750ms cycle. The mutation to
        // `paragraphs` is silent: we don't invalidate the tasks cache (we
        // already have the derive result — and the next derive against the
        // newly anchored paragraphs would produce zero new mints). The
        // .taskCreate ops we emit per mint give cross-Mac merge an
        // authoritative creation timestamp + session id; appendTaskOpInternal
        // does invalidate the cache but the re-entrancy guard catches that
        // and short-circuits, which is exactly the intended behavior.
        if !mintedAnchors.isEmpty {
            applyMintedAnchors(mintedAnchors)
            for mint in mintedAnchors {
                let synth = "inline:\(docId):\(mint.anchorId)"
                let op = Op(
                    opId: ULID.generate(),
                    docId: docId, at: Date(),
                    device: device, session: session,
                    kind: .taskCreate,
                    changes: [], sequence: nil,
                    provenance: Op.Provenance(
                        sessionId: session,
                        taskId: synth,
                        taskBody: mint.body,
                        taskKind: mint.kind.rawValue))
                appendTaskOpInternal(op)
            }
            autosaveScheduler.schedule(())
        }

        // TaskDeriver returns rebalance ops with placeholder ids
        // ("rebalance_<task_id>") for determinism inside the pure projection.
        // Rewrite each to a freshly-minted ULID and append via the standard
        // path. The rebalance is mathematically idempotent (next derive
        // emits zero rebalance ops since priorities are now well-spaced),
        // so the re-invalidation triggered by the appends is harmless.
        for op in rebalanceOps {
            let standardized = op.withReplacedOpId(ULID.generate())
            appendTaskOpInternal(standardized)
        }
    }

    /// Splice freshly-minted task anchors back into paragraph text. Each
    /// `MintedAnchor` carries the paragraph id, line index, and (for
    /// Fountain inline tasks) an intra-line UTF-16 offset for the anchor
    /// span insertion point. Markdown line-style tasks get the anchor
    /// appended at end-of-line with a separating space.
    ///
    /// Mutates `paragraphs` directly and records the new text in the
    /// pending buffer so the next `typingBurst` op captures the anchored
    /// form — without this, the .md on disk would carry anchors but the
    /// op log would replay the un-anchored prior text and clobber them
    /// on reload (Deriver folds typing_burst into the paragraph map,
    /// taking precedence over disk parse). Does NOT invalidate the tasks
    /// cache; the caller — `rebuildTasksCache` — already holds the
    /// post-mint derive result.
    private func applyMintedAnchors(_ mints: [TaskDeriver.MintedAnchor]) {
        // Group by paragraph so we apply all mints to a paragraph in one
        // splice pass (line indices remain stable when we walk lines once).
        var byParagraph: [String: [TaskDeriver.MintedAnchor]] = [:]
        for mint in mints {
            byParagraph[mint.paragraphId, default: []].append(mint)
        }
        for (pid, group) in byParagraph {
            guard let current = paragraphs[pid] else { continue }
            var lines = current.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)
            // Sort mints within a line by descending intraLineOffset so the
            // earlier insertion doesn't shift offsets for later ones on the
            // same line. Cross-line ordering doesn't matter because each
            // line is mutated independently.
            let sorted = group.sorted { a, b in
                if a.lineIndex != b.lineIndex { return a.lineIndex < b.lineIndex }
                let aOff = a.intraLineOffset ?? Int.max
                let bOff = b.intraLineOffset ?? Int.max
                return aOff > bOff
            }
            for mint in sorted {
                guard mint.lineIndex >= 0, mint.lineIndex < lines.count else {
                    continue
                }
                let comment = TaskAnchorID.formatComment(mint.anchorId)
                let line = lines[mint.lineIndex]
                if let intra = mint.intraLineOffset {
                    // Fountain inline: splice anchor at the UTF-16 offset.
                    let ns = line as NSString
                    if intra >= 0 && intra <= ns.length {
                        let head = ns.substring(with: NSRange(location: 0, length: intra))
                        let tail = ns.substring(from: intra)
                        lines[mint.lineIndex] = head + comment + tail
                    }
                } else {
                    // Markdown line-style: append at end-of-line with a space
                    // separator (matches the format the deriver expects).
                    lines[mint.lineIndex] = "\(line) \(comment)"
                }
            }
            let priorText = paragraphs[pid]
            let nextText = lines.joined(separator: "\n")
            paragraphs[pid] = nextText
            // Record into pending so the next typing_burst carries the
            // anchored form. Without this, reload-from-log replays the
            // un-anchored prior text into paragraphs and strips the anchor.
            pending.recordChange(
                paragraphId: pid, prior: priorText, next: nextText)
            burstScheduler.recordActivity()
        }
    }

    /// Sync helper for task-lifecycle and rebalance ops. Updates the
    /// in-memory mirror immediately so the next `tasks(filter:)` reflects
    /// the change without waiting for the async disk append. Fires a
    /// fire-and-forget `opStore.append` so the op also lands in
    /// `.maugham/ops/<docId>.jsonl`. JSONLAppendStore dedupes by opId, so
    /// even pathological re-entry is safe on disk.
    internal func appendTaskOpInternal(_ op: Op) {
        _opLogMirror.append(op)
        invalidateTasksCache()
        // Annotation cache only invalidates for annotation ops — task ops
        // don't change annotation derivation, so skip the bump.
        let store = opStore
        Task { @MainActor in
            try? await store.append(op)
        }
    }

    // MARK: - Task mutation API

    /// Create a new pane-anchored task on this document. Returns a synthetic
    /// preview `WriterTask`; the real derived task lands via the deriver on
    /// the next `tasks(filter:)` call (and matches this preview field-for-
    /// field by construction).
    @discardableResult
    public func createPaneTask(body: String, parentTaskId: String?) -> WriterTask {
        let opId = ULID.generate()
        let priority = lowestPriorityForDoc() + 1.0
        let parentField: String? = parentTaskId
        let op = Op(
            opId: opId,
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskCreate,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: opId,
                taskBody: body,
                taskPriority: priority,
                taskParentId: parentField,
                taskKind: TaskKind.paneCreated.rawValue))
        appendTaskOpInternal(op)
        return WriterTask(
            id: opId, kind: .paneCreated,
            anchor: TaskAnchor(docId: docId, paragraphId: nil),
            body: body, status: .open, priority: priority,
            parentTaskId: parentTaskId,
            createdAt: op.at,
            createdBySession: session)
    }

    public func setTaskStatus(id: String, status: TaskStatus) {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskStatusChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskStatus: status.rawValue))
        appendTaskOpInternal(op)
    }

    public func setTaskPriority(id: String, priority: Double) {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskPriorityChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskPriority: priority))
        appendTaskOpInternal(op)
    }

    public func setTaskParent(id: String, parentTaskId: String?) {
        // "" sentinel clears parent (matches TaskDeriver convention); any
        // non-empty value sets it. The deriver maps "" → nil on read.
        let parentField = parentTaskId ?? ""
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskParentChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskParentId: parentField))
        appendTaskOpInternal(op)
    }

    public func editPaneTaskBody(id: String, body: String) {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskBodyEdit,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskBody: body))
        appendTaskOpInternal(op)
    }

    public func archiveTask(id: String) {
        // Capture body + kind BEFORE archiving so the .taskArchive op
        // carries enough info for the deriver to synthesize an entry in
        // the Archived filter. Inline tasks become derive-invisible after
        // archive (the anchor is spliced out of paragraph text); without
        // this metadata they'd vanish from the pane entirely, losing the
        // audit trail.
        let archived = _tasksCache.first(where: { $0.id == id })

        // Emit the .taskArchive op first so the lifecycle event lands in the
        // op log even when no anchor can be located (pane-created tasks, or
        // an inline anchor that's already been spliced out of the .md).
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskArchive,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskBody: archived?.body,
                taskKind: archived?.kind.rawValue))
        appendTaskOpInternal(op)

        // Extract the anchor id from the synth-id. Pane-created tasks have
        // `id == opId` (no `inline:` prefix) and never carry inline text —
        // op-only archive is sufficient.
        guard let anchorId = Self.extractAnchorId(fromTaskId: id) else { return }
        guard let location = locateTaskAnchor(anchorId: anchorId) else {
            // Anchor isn't in any paragraph — already spliced out or never
            // present (e.g. stale tasks pane row). Op-only archive.
            return
        }

        guard let para = paragraphs[location.paragraphId] else { return }
        let mutated = Self.spliceArchivedTask(
            from: para,
            anchorRangeInLine: location.anchorRangeInLine,
            lineIndex: location.lineIndex)
        if mutated.isEmpty {
            // Sole task in the paragraph → paragraph collapses. The sweep
            // reason carries the removed id so annotations on it archive
            // through the normal path.
            deleteParagraph(id: location.paragraphId)
        } else {
            setParagraph(id: location.paragraphId, text: mutated)
        }
    }

    /// Extract the 6-char anchor id from a task synth-id of the form
    /// `inline:<docId>:<anchorId>`. Returns nil for pane-created task ids
    /// (which are bare ULIDs with no `inline:` prefix).
    internal static func extractAnchorId(fromTaskId id: String) -> String? {
        guard id.hasPrefix("inline:") else { return nil }
        // docId can itself be arbitrary, but task synth-ids always end with
        // `:<anchorId>` and anchorId never contains `:`. Trailing component.
        guard let lastColon = id.lastIndex(of: ":") else { return nil }
        let anchor = String(id[id.index(after: lastColon)...])
        return TaskAnchorID.parseComment(TaskAnchorID.formatComment(anchor))
    }

    /// Find a task anchor across all paragraphs in `paragraphs` (not just
    /// those in `sequence` — defensive against orphan paragraphs that haven't
    /// been pruned yet). Returns the (paragraphId, 0-based line index within
    /// that paragraph, NSRange of the anchor span within that line).
    internal func locateTaskAnchor(
        anchorId: String
    ) -> (paragraphId: String, lineIndex: Int, anchorRangeInLine: NSRange)? {
        let target = TaskAnchorID.formatComment(anchorId)
        // Walk in sequence order first so the result is deterministic when
        // an orphan paragraph also happens to contain the anchor.
        var visited = Set<String>()
        for pid in sequence {
            visited.insert(pid)
            if let hit = Self.locateAnchor(target, in: paragraphs[pid] ?? "") {
                return (pid, hit.lineIndex, hit.range)
            }
        }
        for (pid, text) in paragraphs where !visited.contains(pid) {
            if let hit = Self.locateAnchor(target, in: text) {
                return (pid, hit.lineIndex, hit.range)
            }
        }
        return nil
    }

    private static func locateAnchor(
        _ target: String, in paragraph: String
    ) -> (lineIndex: Int, range: NSRange)? {
        let lines = paragraph.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let ns = line as NSString
            let r = ns.range(of: target)
            if r.location != NSNotFound {
                return (idx, r)
            }
        }
        return nil
    }

    /// Splice an archived task out of its paragraph text per spec §2.7.
    ///
    /// - Line-style (`- [ ] body <!--t-XXXXXX-->`): delete the whole line +
    ///   its terminating `\n` (or the leading `\n` if last line). If only
    ///   one line existed, returns "" so the caller can collapse the
    ///   paragraph.
    /// - Inline (`[[todo: body]]<!--t-XXXXXX-->` mid-prose): splice the
    ///   bracketed segment + its anchor; collapse one adjacent whitespace
    ///   when both sides are whitespace-bordered. When only one side is
    ///   whitespace, splice the segment + that one whitespace. When neither
    ///   side is whitespace (word-glue, rare), splice only the segment.
    internal static func spliceArchivedTask(
        from paragraph: String,
        anchorRangeInLine: NSRange,
        lineIndex: Int
    ) -> String {
        let lines = paragraph.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count else { return paragraph }
        let line = lines[lineIndex]
        let ns = line as NSString

        // Decide line-style vs inline by whether the line — once stripped of
        // the anchor — matches the markdown checkbox shape. The anchor sits
        // at the very end of a line-style task: anything between `]` and
        // the anchor is whitespace + body + optional trailing space.
        let checkboxPrefix = try! NSRegularExpression(
            pattern: #"^\s*- \[(?: |x)\] "#)
        let prefixMatch = checkboxPrefix.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length))
        let anchorAtLineEnd = (anchorRangeInLine.location
            + anchorRangeInLine.length == ns.length)
        let isLineStyle: Bool = {
            guard let m = prefixMatch else { return false }
            guard anchorAtLineEnd else { return false }
            // The anchor must be the only `<!--t-…-->` span on this line for
            // line-style treatment — multiple-anchors-per-line falls through
            // to the inline splice path. (Multi-anchor lines are unusual for
            // checkbox lines but possible if a writer types one inline.)
            let countRegex = try! NSRegularExpression(
                pattern: #"<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#)
            let count = countRegex.numberOfMatches(
                in: line, range: NSRange(location: 0, length: ns.length))
            _ = m  // suppress unused-warning when count != 1
            return count == 1
        }()

        if isLineStyle {
            // Delete the entire line, plus one surrounding `\n`. Joining the
            // remaining lines with "\n" handles both:
            //   - middle / first line: leading `\n` of next line is dropped
            //     implicitly by the join.
            //   - last line: the trailing `\n` before this line is dropped
            //     because we remove the array element before joining.
            var mutated = lines
            mutated.remove(at: lineIndex)
            return mutated.joined(separator: "\n")
        }

        // Inline splice. Find the full bracketed segment + anchor span. The
        // anchor span ends at `anchorRangeInLine.upperBound`; the segment
        // start is the leftmost `[[` before the anchor whose matched
        // `[[(todo|done): …]]<!--t-XXXXXX-->` ends exactly at the anchor.
        let segmentPattern = #"\[\[(?:todo|done):\s*.*?\]\]<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#
        // swiftlint:disable:next force_try
        let segmentRegex = try! NSRegularExpression(pattern: segmentPattern)
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = segmentRegex.matches(in: line, range: fullRange)
        guard let segment = matches.first(where: { match in
            // Match ends exactly at the anchor's end → this is the bracketed
            // segment that owns the target anchor.
            match.range.location + match.range.length
                == anchorRangeInLine.location + anchorRangeInLine.length
        }) else {
            // Couldn't pair a `[[…]]` to this anchor (malformed inline; e.g.
            // glued anchor with no preceding `[[`). Conservative: drop only
            // the anchor span itself.
            let mutatedLine = ns.replacingCharacters(
                in: anchorRangeInLine, with: "")
            return Self.replaceLine(lines, at: lineIndex, with: mutatedLine)
        }

        let segRange = segment.range
        let before = segRange.location == 0
            ? ""
            : ns.substring(with: NSRange(
                location: segRange.location - 1, length: 1))
        let afterStart = segRange.location + segRange.length
        let after = afterStart >= ns.length
            ? ""
            : ns.substring(with: NSRange(location: afterStart, length: 1))
        let leftIsWS = !before.isEmpty
            && before.rangeOfCharacter(from: .whitespaces) != nil
        let rightIsWS = !after.isEmpty
            && after.rangeOfCharacter(from: .whitespaces) != nil

        var spliceStart = segRange.location
        var spliceLength = segRange.length
        if leftIsWS && rightIsWS {
            // Both sides whitespace → consume the LEADING whitespace char
            // (collapses "X _seg_ Y" to "X Y").
            spliceStart -= 1
            spliceLength += 1
        } else if leftIsWS && !rightIsWS {
            // Only left whitespace → consume it (trailing-of-paragraph case
            // "X _seg_$" → "X$").
            spliceStart -= 1
            spliceLength += 1
        } else if !leftIsWS && rightIsWS {
            // Only right whitespace → consume it (start-of-paragraph case
            // "^_seg_ X" → "X").
            spliceLength += 1
        }
        // else: neither side whitespace (word-glue) → splice only the segment

        let spliceRange = NSRange(location: spliceStart, length: spliceLength)
        let mutatedLine = ns.replacingCharacters(in: spliceRange, with: "")
        return Self.replaceLine(lines, at: lineIndex, with: mutatedLine)
    }

    private static func replaceLine(
        _ lines: [String], at index: Int, with newLine: String
    ) -> String {
        var mutated = lines
        mutated[index] = newLine
        return mutated.joined(separator: "\n")
    }

    /// Lowest priority across the doc's currently-derived tasks. Pane-created
    /// tasks get `lowest + 1.0` so they land at the head of the list (the
    /// user's most-recent-first reading default). Returns 0.0 when there are
    /// no tasks yet.
    private func lowestPriorityForDoc() -> Double {
        // Use the cached projection; build it if necessary.
        if !_tasksCacheValid { rebuildTasksCache() }
        let priorities = _tasksCache
            .filter { $0.anchor?.docId == docId }
            .map(\.priority)
        return priorities.min() ?? 0.0
    }
}
