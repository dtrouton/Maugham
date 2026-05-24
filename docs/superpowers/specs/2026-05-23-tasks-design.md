# Tasks — Issue-Tracker Layer for Maugham

**Status:** Approved 2026-05-23 by user, ready for implementation planning.

**Goal:** Ship a unified task-tracking surface that combines three capture paths into one right-pane segment: inline `- [ ]` markdown checkboxes in any `.md`, Fountain `[[todo: …]]` boneyards in `.fountain`, and pane-created tasks with no text representation. Drag-and-drop priority reorder (rewindable), in-pane status toggle that rewrites the underlying text for inline tasks, single-level parent/child nesting, two scope filters (Document / Project), MCP read-only access.

**Why now:** The writer wants to record todos *in place* while drafting, not just in a separate list app. Inline checkboxes are the natural carrier (no context-switch out of writing); the list view is the triage / prioritization / progress surface. This is also the **pathfinder** for the "Author's IDE — analytical layers" arc on the roadmap: it teaches the architectural shape — structured author-owned side-data anchored to paragraph IDs, op-log derived, surfaced as a right-pane mode, MCP-readable — that the next layers (symbol DB, lint, writing analytics) will reuse.

**Working title:** `milestone-tasks`.

**Conformance contract:** Must not regress any test currently green (873 passing at merge from main; expected to be the same at milestone start). No new manuscript-load entry point — inline-task derivation runs against `Document.paragraphs` only, the established read surface. No subclass of `NSTextStorage`. No bidirectional SwiftUI↔AppKit sync. No `applyExternalText` call sites added (still exactly 3). The manuscript-membrane is preserved: Claude has no write tools in this milestone — `list_tasks` / `get_task` are read-only.

---

## 1. Problems addressed

The writer wants three things, and Maugham can't do any of them today:

### 1.1 Capture todos without leaving the page

While drafting Chapter 3, the writer thinks "I need to come back and tighten this dialogue." Today they either context-switch to another app (loses flow) or write a `TODO:` comment in the prose (cannot triage later). The standard markdown checkbox syntax — `- [ ] tighten Anna's dialogue` — is muscle memory from every other markdown tool. Maugham should recognize it.

### 1.2 Triage and prioritize without a manuscript edit

Once a writer has captured 20 inline todos across a manuscript, they need a list view to see them all together, reorder by importance, and check them off as they go. The same list should also accept *project-level* todos that don't belong inside any specific paragraph ("revise act 2", "rewrite the slap scene blocking").

### 1.3 Screenplay parity

Fountain has a native syntax for boneyard-style notes: `[[ … ]]`. Writers already use `[[todo: rewrite the slap scene]]` informally. Maugham should treat this as a first-class task with the same capture + triage affordances as prose.

### 1.4 Claude can read but not write

When Claude reviews a manuscript via MCP, it should be able to see the writer's todo list as context — *"I see you have an open todo to tighten Chapter 3's dialogue; here's a suggested revision via `add_suggested_change`."* — but the manuscript-membrane principle (ADR 0004) holds: tasks belong to the writer; Claude cannot close, archive, or create them.

---

## 2. Architecture overview

The closest existing precedent is **annotations**: structured side-data anchored to paragraph IDs, op-log derived with a version-token cache, surfaced as its own right-pane segment, MCP-readable. Tasks are designed to mirror that pattern wholesale, with three deliberate differences:

1. **Two capture sources alongside pane-creation.** Annotations come from Claude via MCP only. Tasks come from the writer typing `- [ ]` in `.md`, `[[todo: …]]` in `.fountain`, or pressing `+ New task` in the pane. This means `TaskDeriver` walks *both* `_opLogMirror` (pane-created records + priority/parent/archive lifecycle ops) and `paragraphs` (text-resident inline tasks).
2. **Priority is the reorder axis, and it is op-log-driven.** Drag-and-drop in the pane emits a `.taskPriorityChange` op. New tasks land at lowest priority. This is the first feature where the *display order* of a side-data surface is mutated by the writer, so the op kind exists to make those reorders rewindable.
3. **In-pane status toggle rewrites the underlying text for inline tasks.** Clicking a checkbox in the pane changes `- [ ]` to `- [x]` (or `[[todo:]]` to `[[done:]]`) in the document. This is intentional: the writer-driven action goes through the standard `Document.setParagraph(id:text:)` mutation path; the existing `.typingBurst` op carries the diff; rewind works for free; the autosave echo guard handles the disk write. There is no separate `.taskStatusChange` op for inline tasks — the text *is* the status. Pane-created tasks, which have no text, use a dedicated `.taskStatusChange` op.

### 2.1 New files

- `Maugham/OpLog/Task.swift` — type surface: `Task`, `TaskKind` (`inlineMarkdown` / `fountainBoneyard` / `paneCreated`), `TaskStatus` (`open` / `done` / `archived`), `TaskAnchor`, `TaskFilter` (scope + statuses).
- `Maugham/OpLog/TaskDeriver.swift` — pure derivation function (mirrors `AnnotationDeriver.derive`). Inputs: `[Op]`, `[String: String]` paragraphs, `String` docId. Output: `[Task]` sorted by priority with parent-then-child interleave.
- `Maugham/Views/TasksPane.swift` — right-pane segment view. Toolbar (scope picker, status filter, `+ New task`), `List` of rows, drag-and-drop reorder via `.draggable` / `.dropDestination` mirroring `BinderRow`.
- `Maugham/Views/TaskRow.swift` — single row: SwiftUI `Toggle` checkbox, body text, source badge, kebab menu (archive / delete / set parent).
- `Maugham/MCP/Tools/TaskReadTools.swift` — `ListTasksTool` + `GetTaskTool` enum types conforming to `MCPTool`.
- `Maugham/Editor/MarkdownCheckboxTokenizer.swift` — line-scan pass extracted from the prose tokenizer for `^(\s*)- \[( |x)\] (.*)$` recognition. Emits a `Token.Kind.checkbox(checked:)` over the bracket range and a `plain` token over the body.
- `MaughamTests/TaskDeriverTests.swift`, `MaughamTests/TaskOpRoundTripTests.swift`, `MaughamTests/Integration/TasksPaneIntegrationTests.swift`, `MaughamTests/MCP/Tools/MCPTasksTests.swift`, `MaughamTests/TaskRewindTests.swift`, `MaughamTests/MarkdownCheckboxTokenizerTests.swift`, `MaughamTests/Fountain/FountainTodoBoneyardTests.swift`.

### 2.2 Modified files

- `Maugham/Models/DetailSegment.swift` — add `case tasks`.
- `Maugham/Views/DetailPaneToggle.swift` — add Picker option (SF Symbol `checklist.checked`, ⌘⌥5, help tooltip), add `case .tasks: tasksPane` branch to `segmentContent`, add `@ViewBuilder tasksPane` mirroring `annotationsPane`.
- `Maugham/Views/ProjectWindow.swift` — pass `projectStore` through to the `tasksPane` factory if needed (existing wiring covers it; verify at implementation time).
- `Maugham/OpLog/OpKind.swift` — add six new cases: `.taskCreate`, `.taskStatusChange`, `.taskPriorityChange`, `.taskParentChange`, `.taskBodyEdit`, `.taskArchive`.
- `Maugham/OpLog/Op.swift` (`Provenance`) — add optional fields: `taskId`, `taskBody`, `taskStatus`, `taskPriority`, `taskParentId`, `taskKind`.
- `Maugham/OpLog/Document.swift` — add `_tasksCache: [Task]`, `_tasksCacheValid: Bool`, `tasksVersion: Int`, `tasks(filter:) -> [Task]`, `invalidateTasksCache()`. Piggyback invalidation on the existing `_opLogMirror` and `paragraphs` mutation sites that already call `invalidateAnnotationsCache()`.
- `Maugham/OpLog/Document.swift` — add task-mutation API: `createPaneTask(body:scope:parent:)`, `setTaskStatus(id:status:)`, `setTaskPriority(id:priority:)`, `setTaskParent(id:parentId:)`, `archiveTask(id:)`, `editTaskBody(id:body:)`. These produce the op-log entries and invalidate cache.
- `Maugham/Stores/ProjectStore.swift` — add `projectTasksOpLog() -> [Op]`, `listTasksAcrossProject(filter:) -> [Task]`, `appendProjectTaskOp(_:)`. Project-scope pane-created tasks live in `.maugham/ops/__project__.jsonl`.
- `Maugham/Editor/EditorCoordinator.swift` — add markdown checkbox token recognition in the prose-mode token pipeline, paint with a clickable link attribute, handle click in `textView(_:clickedOnLink:at:)` to flip the bracket via `Document.setParagraph(id:text:)`.
- `Maugham/Editor/Fountain/FountainTokenizer.swift` — augment the existing `[[ ]]` boneyard recognizer with a `^\s*(todo|done):\s*` discriminator. Emit a checkbox token over the `todo:`/`done:` prefix range; click toggles via the same `setParagraph` route.
- `Maugham/MCP/MCPTool.swift` — append `ListTasksTool.self`, `GetTaskTool.self` to `MCPToolCatalog.all`.

### 2.3 Deleted code

None. This is a purely additive milestone.

---

## 3. Data model

### 3.1 `Task` (in `Maugham/OpLog/Task.swift`)

```swift
public enum TaskKind: String, Codable, Sendable, Equatable {
    case inlineMarkdown   = "inline_markdown"
    case fountainBoneyard = "fountain_boneyard"
    case paneCreated      = "pane_created"
}

public enum TaskStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case open, done, archived
}

public struct TaskAnchor: Codable, Sendable, Equatable {
    public let docId: String
    public let paragraphId: String?      // nil iff TaskKind == .paneCreated && scope == .project
}

public struct Task: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: TaskKind
    public let anchor: TaskAnchor?
    public let body: String
    public let status: TaskStatus
    public let priority: Double
    public let parentTaskId: String?
    public let createdAt: Date
    public let createdBySession: String?
}

public struct TaskFilter: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        case document(docId: String)
        case project
    }
    public var scope: Scope
    public var statuses: Set<TaskStatus>   // default [.open]
}
```

### 3.2 Identity

- **Pane-created tasks:** `id` = the `opId` of the `.taskCreate` op that produced them. Stable across rederives.
- **Inline tasks:** synthetic `id` = `"inline:\(docId):\(¶id):\(bodyHash)"` where `bodyHash` is the first 8 hex chars of SHA-256 over the *normalized* body — trim leading/trailing whitespace, lowercase, collapse internal runs of whitespace to a single space. Stable across reorder within a paragraph (adding `- [ ]` above an existing one does not shift the hash), stable across cosmetic edits captured by the normalization, stable across rederives. Loses identity on a substantive body edit (typo fix → new hash) — accepted; substantive body edits are rare and a writer "rewriting" a task is arguably a new task. The normalization is the deliberate ergonomic concession to typo fixes.
- **Fountain `[[todo:]]` tasks:** synthetic `id` = `"fountain:\(docId):\(¶id):\(bodyHash)"` with identical normalization-then-hash. The bracket location within the paragraph is not part of the id.
- **Collision within a paragraph:** if a writer types the same normalized body twice in one paragraph (e.g., `- [ ] fix this` on two separate lines), both lines collapse to one task in the deriver. Acceptable — semantically duplicate todos are duplicates regardless of whether the writer noticed; the second checkbox glyph still renders, but pane state is single-row. Documented in code comment.

The single `bodyHash` helper lives on `TaskDeriver` (`bodyHash(normalized body: String) -> String`) and is exhaustively unit-tested for stability across the normalization classes above.

### 3.3 Priority representation: fractional `Double`

Two reorder costs matter:

- **A single drag-drop emits exactly one op.** Integer-sequence ordering ("priority = position") would require rewriting every neighbor on every drag, producing N priority-change ops per drag — pollution in the rewind scrubber.
- **Inserting between two existing tasks is O(1).** New priority = `(left.priority + right.priority) / 2`. New-task-at-tail = `lastPriority + 1.0`. Lowest-priority-on-create satisfied.

The downside is precision drift. `Double` between two values exhausts after ~53 halvings between the same two anchors in a worst-case adversarial sequence. Mitigation:

- **Rebalance pass inside `TaskDeriver`.** When two consecutive siblings' priorities differ by less than `1e-9`, rewrite the affected sibling chunk with evenly-spaced integer priorities (e.g., 1.0, 2.0, 3.0, …) by emitting one synthetic `.taskPriorityChange` per rewritten task. Runs once per derive, only when needed. Invisible to the user. Property-tested (`TaskDeriverTests.test_rebalance_firesWhenPrioritiesConverge`).

The integer-sequence alternative was considered and ruled out; the fractional approach is what Figma, Linear, and Notion use for the same reason.

---

## 4. Op-log additions

Six new `OpKind` cases. Inline status changes do **not** emit a `.taskStatusChange` — they ride the existing `.typingBurst` (text flip is the status). Pane-created task status changes use `.taskStatusChange`.

| OpKind | Provenance fields populated | Notes |
|---|---|---|
| `.taskCreate` | `taskId` (= op_id), `taskBody`, `taskKind` (`"pane_created"`), `taskPriority`, `taskParentId?` | Only fires for pane-created tasks. Inline tasks are derived from text — no creation op. |
| `.taskStatusChange` | `taskId`, `taskStatus` (`"open"` / `"done"` / `"archived"`) | Pane-created tasks only. |
| `.taskPriorityChange` | `taskId`, `taskPriority` | Fires for *all* task kinds (inline, fountain, pane-created) since priority is op-only state for every kind. |
| `.taskParentChange` | `taskId`, `taskParentId` (`""` empty-string sentinel clears the parent) | All kinds. |
| `.taskBodyEdit` | `taskId`, `taskBody` | Pane-created tasks only. Inline-task body edits go through the standard text-edit path. |
| `.taskArchive` | `taskId` | All kinds. Distinct op (not just status=archived) to keep archive a one-way action with its own rewind ticker. |

All task ops carry `changes: []` — they do not mutate paragraph text. Provenance gains the following optional fields in `Op.swift`:

```swift
public var taskId: String?
public var taskBody: String?
public var taskStatus: String?
public var taskPriority: Double?
public var taskParentId: String?
public var taskKind: String?
```

Conform existing JSONL round-trip tests to verify lossless encode/decode of each new field (`TaskOpRoundTripTests`).

---

## 5. `TaskDeriver`

Pure function. Same shape as `AnnotationDeriver.derive`. Pseudocode:

```
1. Walk ops once.
   For .taskCreate:
       seed Task(id: opId, kind: .paneCreated, anchor: TaskAnchor(docId, nil)
                if op is in the project log else (docId, nil),
                body: provenance.taskBody!, status: .open,
                priority: provenance.taskPriority!, parentTaskId: provenance.taskParentId)
       store in panes[opId].
   For .taskStatusChange / .taskPriorityChange / .taskParentChange
       / .taskBodyEdit / .taskArchive:
       lookup provenance.taskId; if found in panes, mutate latest-wins.
       Otherwise stash in inlineOverrides[taskId] (for synthetic-id targets).

2. Line-scan paragraphs.
   For each paragraph (¶id, text):
       split into lines; for each line matching ^(\s*)- \[( |x)\] (.*)$:
           body = captureGroup3
           id = "inline:\(docId):\(¶id):\(bodyHash(body))"   // hash of normalized body
           if seenIds.contains(id) { continue }              // collision dedupe
           seed Task(id, kind: .inlineMarkdown, anchor: (docId, ¶id),
                     body: body, status: x ? .done : .open,
                     priority: defaultTail(docId), parentTaskId: nil)
           apply inlineOverrides[id] if present (priority / parent / archive).

3. Same for Fountain boneyards.
   Within each paragraph, scan for [[(todo|done):\s*(.*?)]] occurrences:
       body = captureGroup2
       id = "fountain:\(docId):\(¶id):\(bodyHash(body))"
       if seenIds.contains(id) { continue }
       seed Task with kind: .fountainBoneyard, status from todo/done, body from capture.
       apply inlineOverrides[id] if present.

4. Merge panes + inlines + fountains into one array.

5. Detect parent-priority-cluster precision drift; if any consecutive sibling
   pair has priority delta < 1e-9, emit rebalance ops (returned as a side-channel
   for the caller to append). Re-apply.

6. Sort: parents first by their own priority; children grouped after their
   parent, sorted by child priority. One level of nesting; if a child references
   an unknown parent (e.g., parent rewound away), treat as parent-less.

7. Apply filter: scope (.document filters to anchor.docId == docId; .project
   includes everything from all docs + the __project__ log), then statuses.
```

The deriver is pure and unit-tested in isolation (`TaskDeriverTests`). Document caches its result by version token (see §6).

---

## 6. `Document` integration

Add three pieces of state mirroring the annotation cache pattern verified in `Document.swift:46-48`:

```swift
private var _tasksCache: [Task] = []
private var _tasksCacheValid: Bool = false
public private(set) var tasksVersion: Int = 0
```

Add to every existing `invalidateAnnotationsCache()` call site (lines 397, 639, 693, 733 confirmed) a paired `invalidateTasksCache()` call. The hot-path observation guard at `Document.swift:466` applies unchanged — invalidate but don't rebuild; lazy rebuild on first read of `tasks(filter:)`.

Public read API:

```swift
public func tasks(filter: TaskFilter) -> [Task] {
    if !_tasksCacheValid { rebuildTasksCache() }
    return _tasksCache.filter { task in /* apply filter */ }
}
```

Public mutation API (each appends an op, invalidates the cache, persists via the existing op-log autosave flow):

```swift
@discardableResult public func createPaneTask(body: String, parentTaskId: String?) -> Task
public func setTaskStatus(id: String, status: TaskStatus)
public func setTaskPriority(id: String, priority: Double)
public func setTaskParent(id: String, parentTaskId: String?)
public func editPaneTaskBody(id: String, body: String)
public func archiveTask(id: String)
```

For **inline-task status changes initiated from the pane**, the call site does *not* invoke `setTaskStatus`. Instead it calls `setParagraph(id:text:)` after locally flipping `[ ]` ↔ `[x]` (or `todo:` ↔ `done:`) at the known character offset within the paragraph. That mutation produces a `.typingBurst` op carrying the diff. The task list re-derives on the next read; the cache invalidation is triggered by the existing paragraph-mutation path.

---

## 7. Tokenizer and editor surface

### 7.1 Prose-mode (markdown) checkbox token

Add a regex pass to the prose tokenizer (`Maugham/Editor/Tokenizer/...` — implementation locates the exact file at implementation time). Regex: `^(\s*)- \[( |x)\] (.*)$`, multiline.

Per match, emit three tokens:
- `syntaxPunctuation` over `(\s*)- ` (the bullet syntax)
- `checkbox(checked: Bool)` over the 3-character `[ ]` or `[x]` glyph
- `plain` over the body

In `EditorCoordinator.applyTokens`, when painting a `checkbox` token range, set:

```swift
[NSAttributedString.Key.link: "maugham://task/toggle?paragraphId=<¶id>&offset=<utf16-offset>",
 NSAttributedString.Key.cursor: NSCursor.pointingHand,
 MaughamCheckboxAttr.key: token.checked]
```

The standard AppKit click path is `NSTextViewDelegate.textView(_:clickedOnLink:at:)`. The existing wiki-link click path in `EditorCoordinator` is the pattern — add a `maugham://task/toggle` URL-scheme branch there. Click handler:

1. Parse `paragraphId` and `offset` from URL.
2. `let paragraph = document.paragraph(id: paragraphId)`.
3. Flip the bracket character at `offset` (`[ ]` → `[x]` or `[x]` → `[ ]`).
4. `document.setParagraph(id: paragraphId, text: flipped)`.

No new op kind. The `.typingBurst` is the rewind unit.

### 7.2 Fountain `[[todo:]]` / `[[done:]]`

The Fountain tokenizer already recognizes `[[ ]]` boneyards (existing code in `FountainTokenizer.swift`). Add a discriminator *inside* the existing recognizer: when the boneyard content matches `^\s*(todo|done):\s*(.*?)$`, emit two tokens for the bracket contents:

- `checkbox(checked: name == "done")` over the `todo:` / `done:` prefix (5 chars)
- `boneyardBody` over the rest (existing style)

Click route is identical to §7.1 — flip `todo:` ↔ `done:` via `setParagraph`.

The change is a discriminator inside the existing recognizer, not a new tokenizer state. This avoids the Phase 3d ghosts (tripwire #1, #2).

---

## 8. `TasksPane` view

### 8.1 Layout

```
VStack(spacing: 0) {
    // Toolbar
    HStack {
        Picker("Scope", selection: $scope) {
            Text("Doc").tag(TaskFilter.Scope.document(docId: docId))
            Text("Project").tag(TaskFilter.Scope.project)
        }
        .pickerStyle(.segmented)
        .fixedSize()

        Spacer()

        AdaptiveFilterRow(
            items: TaskStatusFilterItem.allCases,
            selection: $statusSelection)

        Spacer()

        Button {
            createPaneTask()
        } label: {
            Image(systemName: "plus")
        }
        .help("New task")
        .disabled(scope is .document && activeDocId == nil)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)

    Divider()

    // Body
    if visibleTasks.isEmpty {
        ContentUnavailableView(
            "No tasks",
            systemImage: "checklist",
            description: Text("Type `- [ ]` in any paragraph, or press +."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
        List(visibleTasks, selection: $selectedTaskId) { task in
            TaskRow(task: task,
                    onToggle: { toggleStatus(task) },
                    onJump:   { jumpToParagraph(task) },
                    onArchive:{ archive(task) },
                    onDelete: { deleteIfPaneCreated(task) })
                .padding(.leading, task.parentTaskId == nil ? 0 : 18)
                .draggable(task.id) { TaskDragPreview(task: task) }
                .dropDestination(for: String.self) { ids, location in
                    handleReorderDrop(draggedIds: ids, target: task, at: location)
                }
        }
        .listStyle(.sidebar)
    }
}
```

Reuses the existing `AdaptiveFilterRow` control (from `milestone-ui-polish`) and the existing empty-state pattern (top-anchored toolbar + filling content). Click-row navigation uses the existing `.maughamNavigateToParagraph` notification (see `EditorCoordinator.swift:178`).

### 8.2 `TaskRow`

```
HStack(spacing: 6) {
    Toggle("", isOn: bindingForStatus)
        .toggleStyle(.checkbox)
        .labelsHidden()
    Text(task.body)
        .strikethrough(task.status == .done)
        .lineLimit(2)
    Spacer()
    sourceBadge(for: task.kind)  // SF Symbol: doc.text / film / square.dashed
    kebabMenu(task)
}
.contentShape(Rectangle())
.onTapGesture { onJump() }   // NB: must use .onTapGesture here because List(.sidebar)
                              // sidebar hit-testing requires explicit gesture (tripwire #9 caveat:
                              // the row is a List item, not a sidebar row — Button(.plain) also OK).
```

### 8.3 Drag-and-drop reorder semantics

Same shape as `BinderRow`'s drop intent classification. The location (`DropLocation`) within the target row determines:

- Top half → reorder **above** the target (new priority between target's prev sibling and target).
- Bottom half → reorder **below** the target.
- Center third → **nest under** the target as a child (only if the target is not already a child; one-level cap).

Each drop emits exactly one op (`.taskPriorityChange` for reorder, `.taskParentChange` for nest, or both if both change). Reorder among siblings = single op; cross-parent move = parent change + priority change.

### 8.4 Click-row navigation

```swift
private func jumpToParagraph(_ task: Task) {
    guard let anchor = task.anchor, let pid = anchor.paragraphId else {
        // Pane-created project task — no navigation target. NOP.
        return
    }
    NotificationCenter.default.post(
        name: .maughamNavigateToParagraph,
        object: projectURL,
        userInfo: ["docId": anchor.docId, "paragraphId": pid])
}
```

### 8.5 `+ New task` flow

A small sheet (or inline editor; sheet is the safer default for parity with binder rename):

```
TextField("New task", text: $body)
HStack {
    Picker("Scope", selection: $createScope) {
        Text("Document").tag(.document(docId: docId))
        Text("Project").tag(.project)
    }
    Spacer()
    Button("Cancel") { dismiss() }
    Button("Add") { commit() }.keyboardShortcut(.return)
}
```

`commit()` calls `document.createPaneTask(body:parentTaskId:nil)` for doc-scope, or `projectStore.createProjectPaneTask(body:)` for project-scope.

---

## 9. Persistence layout

### 9.1 Inline tasks: no new persistence

The `.md` (status via `[ ]`/`[x]`) and the existing per-doc op log (`.maugham/ops/<docId>.jsonl` — priority/parent/archive ops) are the only stores. Drift-free by construction; rewind is per-doc and already works.

### 9.2 Doc-scope pane-created tasks: extend the per-doc op log

A `.taskCreate` op anchored to a real document lands in `.maugham/ops/<docId>.jsonl`. The existing `OpLogStore`, `PendingBuffer`, `Reconciler`, `RewindCursor`, and `Presenter` paths all key on docId; no change needed.

### 9.3 Project-scope pane-created tasks: synthetic `__project__` doc id

Project-scope tasks ("revise act 2") have no document anchor. They live in `.maugham/ops/__project__.jsonl`. Three reasons this over a parallel `.maugham/tasks/project.jsonl`:

1. `MaughamSidecarPath.classify` already routes `.maugham/ops/__project__.jsonl` to `.opLog(docId: "__project__")` via the existing `opsPrefix` branch (verified by reading `MaughamSidecarPath.swift:88-95`). Zero new sidecar enum cases.
2. The existing op-log infrastructure handles per-doc append, conflict reconciliation, rewind, and presenter routing — all needed for project ops too.
3. A future project-level rewind affordance falls out naturally: "Rewind project tasks" reads `.maugham/ops/__project__.jsonl` the same way per-doc rewind reads its log.

Two small wiring needs:
- `ProjectStore.projectTasksOpLog() -> [Op]` — convenience reader (reuses `OpLogStore`).
- `ProjectStore.appendProjectTaskOp(_:)` — append + persist + invalidate any pane caches.

The `__project__` doc id is **reserved** going forward. Document this in `Maugham/Stores/AREA.md` (one line addition).

### 9.4 Manifest impact

None. The manifest schema is untouched.

### 9.5 Cross-project aggregation cache

`ProjectStore.listTasksAcrossProject(filter:)` walks every doc in the manifest plus the `__project__` op log. On a 50-document project this would otherwise re-derive 51 op-logs on every pane refresh, status-filter flip, or `tasksVersion` bump.

Cache shape on `ProjectStore`:

```swift
private struct ProjectTasksCacheKey: Equatable {
    let perDocVersionSum: Int    // Σ over open docs of doc.tasksVersion
    let projectLogVersion: Int   // bumped on appendProjectTaskOp / project-log reconcile
}

private var _projectTasksCache: [Task] = []
private var _projectTasksCacheKey: ProjectTasksCacheKey? = nil
public private(set) var projectTasksVersion: Int = 0   // SwiftUI-observable
```

Invariant: `listTasksAcrossProject(filter:)` computes the current `ProjectTasksCacheKey` first; if it matches `_projectTasksCacheKey`, return the cached array filtered through `filter`. If it differs, rebuild from scratch and update both.

- **Per-doc version sum.** Sum (with `&+`) over `documentStore.openDocuments.map(\.tasksVersion)`. Closed docs contribute zero — but their on-disk op logs *can* still produce tasks. The aggregation must also load closed docs' op logs; their effective version is "log file mtime hashed to Int." (A closed doc's op log can only change via reconcile-from-disk, which already bumps the open doc's `tasksVersion`; for *never-opened* docs the mtime hash is sufficient.)
- **Project log version.** Local counter on `ProjectStore`, incremented in `appendProjectTaskOp` and in the project-log reconcile path. Also bumped on cross-Mac merge.
- **SwiftUI observability.** `projectTasksVersion` is `@Published`-equivalent (or however `ProjectStore` already publishes — match existing pattern). Bumped after every cache rebuild and after every project-log append, even on cache hit when the project log appended. `TasksPane` observes it in Project scope; in Document scope, it observes the open Document's `tasksVersion` instead.

The cache is in-memory only — invalidated on `ProjectStore` deinit. Not persisted; rebuilding is O(N docs × ops-per-doc) which is fine on a cold open (the first pane refresh after launch).

A property test (`ProjectStoreTasksTests.test_aggregationCache_hit_doesNotRederive`) asserts that two back-to-back `listTasksAcrossProject` calls with no intervening mutation share a result-identity (or that a derive-counter doesn't tick twice).

---

## 10. MCP read tools

### 10.1 `list_tasks`

```
{
  "type": "object",
  "properties": {
    "project_id": { "type": "string" },
    "scope": { "type": "string", "enum": ["document", "project"] },
    "document_id": { "type": "string" },
    "statuses": { "type": "array", "items": { "type": "string", "enum": ["open","done","archived"] } }
  },
  "required": ["project_id", "scope"]
}
```

Validation:
- `scope == "document"` requires `document_id`.
- `scope == "project"` ignores `document_id`.
- `statuses` defaults to `["open"]`.

Returns an array of task records:

```json
{
  "tasks": [
    {
      "id": "op_2026-05-23T18:00:00.000Z_a4f2",
      "kind": "pane_created",
      "document_id": "doc_chapter-01",
      "paragraph_id": "abcd",
      "body": "tighten Anna's dialogue",
      "status": "open",
      "priority": 1.0,
      "parent_task_id": null,
      "created_at": "2026-05-23T18:00:00.000Z"
    }
  ]
}
```

### 10.2 `get_task`

Inputs: `{ "project_id": String, "task_id": String }`. Returns the full task record. Errors: `task_not_found` (with structured envelope per the editing-milestone pattern).

### 10.3 Registration

Append to `MCPToolCatalog.all` in `Maugham/MCP/MCPTool.swift`. `MCPCatalogConsistencyTests` will fail until both are added — that's intentional; that's the canary.

### 10.4 No write tools

The milestone deliberately ships **no** task-write MCP tools. Claude cannot create, complete, archive, edit, or reorder tasks. Manuscript-membrane (ADR 0004) holds.

---

## 11. Out of scope

Captured to make the boundary explicit:

- **MCP task-write tools.** No `create_task`, `complete_task`, `archive_task`, `reorder_task`. The writer owns the list.
- **Due dates, labels/tags, recurring tasks, reminders.** Not in this milestone — pure scope discipline. Daily-flow value lands without them.
- **Multi-level nesting.** Strictly one level (parent + children). No grandchildren. If a child is dragged onto another child, classify as "reorder, do not nest deeper."
- **Multi-select in the pane.** Single-task drag only.
- **Cross-project task aggregation.** Per-project only; opening another project does not surface its tasks here.
- **Project-scope rewind UI.** The `.maugham/ops/__project__.jsonl` log is rewindable by construction, but the modal UI is a future affordance.
- **Inline checkbox marks in the gutter.** A glyph in the editor gutter next to paragraphs with open tasks is a polish follow-up.
- **Task-body edits from the pane for inline tasks.** Editing a pane-row's body changes only pane-created task bodies. For inline tasks, the source of truth is text; the writer edits the `.md` to change the body. (Pane edit on an inline task is disabled, with a tooltip "edit the document text to change this task.")
- **Search across task bodies.** The existing project search already indexes manuscript text; inline task bodies are found that way. Pane-created tasks are not in the search index in this milestone — a follow-up.

---

## 12. Risks and known unknowns

- **Clickable checkboxes are new interactivity for prose mode.** The route is AppKit's `textView(_:clickedOnLink:at:)` delegate — *not* a SwiftUI binding setter — which clears tripwire #3. The checked state is a paint-pass attribute recomputed on every retokenize — clears tripwire #6. Verify with `EditorIntegrationHarnessTests`-style assertion that `applyExternalText` does not fire on a checkbox click.

- **Status-toggle-from-pane rewrites the `.md`.** This is the intended behavior, and the autosave echo guard at `Document.swift:1000` (`lastDiskEcho: EchoState`) already handles writer-driven `.md` rewrites without surfacing a conflict. Smoke-verify: click checkbox in pane → no `ConflictBanner` appears.

- **Pane-created task lifecycle vs annotation orphan sweep.** The orphan-annotation sweep iterates `_annotationsCache` only and is gated on `SweepReason.removed` paragraph ids (see CLAUDE.md "Per-area pointers" → OpLog). Tasks have a separate cache and are not annotations; the sweep cannot touch them. Cover with a test: delete a paragraph containing both an annotation and an inline task while a pane-created task exists; assert pane-created task survives, inline task vanishes (it lived in the deleted paragraph text), and annotation sweep fires only against annotations.

- **Fountain tokenizer extension carries Phase 3d ghosts.** The change is a *discriminator inside the existing `[[ ]]` recognizer*, not a new tokenizer state or `NSTextStorage` subclass. Add `FountainTodoBoneyardTests` to lock the boundary.

- **Fractional priority precision drift.** Worst-case adversarial sequence exhausts after ~53 halvings; realistic worst case in a single drafting session is ~20 inserts between the same two anchors. The `< 1e-9` rebalance trigger has ~30 halvings of headroom and rewrites the affected sibling chunk transparently. Property-tested.

- **Inline-task synthetic-id stability.** Resolved by body-hash keying (see §3.2). Adding `- [ ]` above an existing one no longer shifts the id; priority/parent ops survive reorder within a paragraph. The remaining sharp edge — substantive body edits losing identity — is documented in §3.2 and accepted (rare in practice; a substantively rewritten task is arguably a new task).

- **First MCP call after restart flake** (carry-forward from `memory/project_deferred_mcp_first_call.md`). Tasks tools inherit this and don't make it worse. The known stderr-logging fix in the CLI bridge would benefit annotations and tasks alike — out of scope here.

- **`__project__` doc id collides with a real user document.** Reserved going forward. If somehow a user has a `__project__.md` file, `Document.load` for that path would conflict — but `__project__` isn't a valid manifest item; the path `Maugham/.maugham/ops/__project__.jsonl` is a sidecar location with no corresponding manuscript. The conflict cannot arise in normal use. Note in `Maugham/Stores/AREA.md`.

---

## 13. Acceptance criteria

A writer can:

- Type `- [ ] write the inciting incident` into a manuscript paragraph and see the row appear in the Tasks pane (⌘⌥5) with kind "manuscript".
- Type `[[todo: rewrite the slap scene]]` into a `.fountain` and see the row appear with kind "screenplay".
- Open the Tasks pane, press `+ New task`, type "revise act 2", choose Project scope, and see the row appear without any `.md` file being modified.
- Drag a task above another in the pane and see priority persist across `⌘Q` + relaunch.
- Click a checkbox in the pane on an inline task and see the editor text flip to `- [x]`.
- Click a checkbox in the pane on a Fountain task and see the editor text flip to `[[done: …]]`.
- Drag an inline manuscript task onto the "revise act 2" pane-created task and see it nested under it (indented).
- Click any task row and see the editor jump to its source paragraph.
- Open Rewind, scrub past a reorder op, and see the order revert in the Tasks pane.
- Restart the app; all of the above persists.
- From Claude Desktop, call `list_tasks(project_id, scope: "project")` and see the same task set; calling any task-write tool fails because none exist.

All existing tests continue to pass. New tests added per §3 (`TaskDeriverTests`), §4 (`TaskOpRoundTripTests`), §7 (`MarkdownCheckboxTokenizerTests` + `FountainTodoBoneyardTests`), §8 (`TasksPaneIntegrationTests`), §10 (`MCPTasksTests`), and a `TaskRewindTests` that covers the rewind acceptance criterion above.
