# Editing — Annotations + History Pane — Design Spec

**Status:** Approved 2026-05-19 by user, ready for implementation planning.

**Goal:** Introduce a Claude-as-collaborative-editor surface: four annotation kinds (comment / suggested_change / query / craft_note) with a unified open → accepted/rejected/archived lifecycle, an Annotations pane in the right column for editorial action, and an extended History pane that surfaces the full op vocabulary (typing, annotations, external edits, checkpoints) for forensic scrub. Builds directly on the Document-first-class foundation.

**Why now:** The Document type now owns the per-document op log; `claudeSuggestion` / `claudeAccept` / `claudeReject` op kinds already exist in the schema but no production code creates or consumes them. This milestone wires them up end-to-end and adds the three missing kinds (comment, query, craft_note). The History pane currently shows only checkpoints; extending it to surface the full op stream unlocks both the editorial conversation history and the forensic burst-level view in one place.

**Why this specific design:** The editorial vision (from the user's earlier brainstorm) requires durable separation between "manuscript is yours" and "Claude operates in a parallel annotation layer." Annotations as first-class ops give us: natural `op_id` anchoring; rejected suggestions stay in history so future sessions don't re-suggest the same thing; provenance (session, prompt) travels with each annotation; cross-Mac log-merge applies without modification. Two right-pane segments (Annotations + History) keep editorial-action and forensic-scrub jobs distinct without cramping either surface.

**What this spec does NOT cover:**
- `craft_principles.md` project-local file. Accepted craft_notes live in the annotation log only for v1; a follow-up milestone can aggregate them into a project-level digest.
- Sub-paragraph range anchors for suggested_change.
- Inline annotation marks in the editor text view (margin glyphs, gutter rendering).
- Bulk annotation operations.
- Cross-document annotation views.
- Real-time multi-writer collaboration (future extension per the Document-first-class spec §7).

**Constraint:** must not regress the EditorIntegrationHarness conformance contract (10 tests) shipped with milestone-document-first-class.

---

## 1. Op schema extensions

`Op` envelope shape is unchanged; the kind set expands and `Op.Provenance` gains three optional fields.

### 1.1 `OpKind` — 4 new cases

```swift
public enum OpKind: String, Codable, Equatable, Sendable {
    // Existing
    case typingBurst = "typing_burst"
    case externalEdit = "external_edit"
    case checkpoint
    case checkpointRestore = "checkpoint_restore"
    case bootstrap
    case claudeSuggestion = "claude_suggestion"
    case claudeAccept = "claude_accept"
    case claudeReject = "claude_reject"

    // NEW — annotation creation
    case claudeComment = "claude_comment"
    case claudeQuery = "claude_query"
    case claudeCraftNote = "claude_craft_note"

    // NEW — annotation lifecycle
    case claudeArchive = "claude_archive"
}
```

### 1.2 `Op.Provenance` — 3 new optional fields

```swift
public struct Provenance: Codable, Equatable, Sendable {
    // Existing
    public let sessionId: String?
    public let prompt: String?
    public let toolArgs: String?
    public let sourceCheckpoint: String?
    public let synthesisSource: String?
    public let orphanRecoveryMethod: String?

    // NEW — annotation semantics
    /// Claude's prose body for the annotation. Required on the four
    /// creation kinds (comment / suggested_change / query / craft_note);
    /// nil on lifecycle transition ops.
    public let annotationBody: String?

    /// The op_id of the originating annotation. Set on accept/reject/
    /// archive ops to link them to their source creation op; nil on
    /// creation kinds.
    public let sourceAnnotationId: String?

    /// User's prose response — captured on reject (the user's reasoning)
    /// and on accept-of-query (the user's reply). Optional elsewhere.
    public let userResponse: String?
}
```

### 1.3 Reuse of existing fields

- `Op.changes[0].paragraphId` carries the paragraph anchor for `comment`, `suggested_change`, `query`. Empty `changes` for `craft_note` (doc-scoped).
- `Op.changes` for `suggested_change` carries `paragraphId`, `prior` (current paragraph text), `next` (suggested text).
- `Op.changes` for `claude_accept` of a `suggested_change` carries the same `paragraphId`/`prior`/`next`, applied to the manuscript when the op replays.
- `Op.changes` empty for `claude_accept` of comment / query / craft_note (no manuscript mutation).
- `Op.changes` empty for `claude_reject` and `claude_archive`.

The schema repurposes `changes` as both "what paragraph this annotation is about" and "what change to apply on accept" — same field serves both roles.

---

## 2. Document API for annotations

### 2.1 Supporting types — new file `Maugham/OpLog/Annotation.swift`

```swift
public enum AnnotationKind: String, Codable, Equatable, Sendable {
    case comment
    case suggestedChange = "suggested_change"
    case query
    case craftNote = "craft_note"
}

public enum AnnotationStatus: String, Codable, Equatable, Sendable {
    case open, accepted, rejected, archived
}

public struct Annotation: Equatable, Sendable, Identifiable {
    public let id: String                   // op_id of the creation op
    public let kind: AnnotationKind
    public let paragraphId: String?         // nil for craftNote
    public let body: String                 // Claude's prose
    public let suggestedText: String?       // suggestedChange only
    public let priorText: String?           // captured at suggestion time
    public let createdAt: Date
    public let createdBySession: String?
    public let status: AnnotationStatus
    public let userResponse: String?
    public let resolvedAt: Date?
    public let isStale: Bool                // priorText != current paragraph
}

public struct AnnotationFilter: Equatable, Sendable {
    public var kinds: Set<AnnotationKind>? = nil
    public var statuses: Set<AnnotationStatus>? = [.open]
    public var paragraphId: String? = nil
    public init(...)
}
```

### 2.2 Document mutation API — extension methods

```swift
extension Document {
    public func addAnnotation(
        kind: AnnotationKind,
        paragraphId: String?,
        body: String,
        suggestedText: String? = nil,
        prompt: String? = nil,
        toolArgs: String? = nil
    ) async throws -> String

    public func acceptAnnotation(
        id: String, userResponse: String? = nil
    ) async throws

    public func rejectAnnotation(
        id: String, userResponse: String? = nil
    ) async throws

    public func archiveAnnotation(id: String) async throws

    public func annotations(
        filter: AnnotationFilter = AnnotationFilter()
    ) -> [Annotation]
}
```

### 2.3 Derived-state mechanics

- Document holds `private var _annotationsCache: [Annotation] = []` rebuilt whenever an annotation-affecting op is appended.
- Rebuild algorithm: walk op log, find creation ops (the 4 kinds); for each, find the latest lifecycle op (accept/reject/archive) with `provenance.sourceAnnotationId == this op's id`. Derive status from latest. Apply `isStale` check by comparing captured `priorText` to current paragraph text.
- `annotations(filter:)` applies the filter to the cache. Returned list sorted by creation time descending by default.
- The cache and the paragraph map are independent derived projections of the same op log — both consistent with "log is source of truth, state is derived."
- For SwiftUI observation, Document gains a separate `@Observable` annotation-version counter that increments when the cache is rebuilt. UI views observing `document.annotations` re-render; editor view (observing `document.displayText`) doesn't re-render on annotation-only changes.

### 2.4 Membrane semantics — what "accept" does, by kind

- **`suggestedChange`**: the `claude_accept` op carries the suggested `changes`; Document's existing op-replay machinery applies them to `paragraphs` and updates `displayText`. The same op resolves annotation status to accepted. **One op, two effects.**
- **`comment`**: `claude_accept` op has empty `changes`; only annotation status changes.
- **`query`**: `claude_accept` op has empty `changes`; `userResponse` captures the user's reply.
- **`craftNote`**: `claude_accept` op has empty `changes`; status becomes accepted; surfaces in `list_annotations(kind: craft_note, status: accepted)` for next-session Claude.

### 2.5 Stale annotation handling

`Annotation.isStale` is true when `priorText` was captured at suggestion time and `paragraphs[paragraphId]` no longer matches. UI uses this to show a "Stale" badge and confirm accept ("paragraph has changed; apply anyway?"). Reject/Archive work normally on stale annotations.

### 2.6 Paragraph-deletion cleanup

When a paragraph is removed from `sequence` — via `Document.deleteParagraph(id:)`, via `setFullText` whose parse drops the paragraph, or via an `external_edit` ingest that omits it — any open annotations anchored to that paragraph are auto-archived in the same pass. The lifecycle op emitted is `claude_archive` with `provenance.synthesisSource = "paragraph_deleted"`. Future Claude sessions querying `list_annotations` see the archived state with the cause as context.

The cleanup runs at the end of every mutation that updates `sequence`: after the new sequence is settled but before `_displayText` is written. Annotations on paragraphs that survived the mutation are unchanged.

### 2.7 Single-observable-write discipline preserved

Every annotation mutation method writes the annotation cache, increments the annotation-version counter, and (for suggestedChange accept) writes `_displayText`. Other transitions leave `_displayText` alone — no spurious editor re-renders. The Document-first-class invariant ("one observable write per mutation") still holds because each mutation writes one of two observable surfaces (`displayText` OR annotation-version), not both.

---

## 3. MCP tool surface

Claude proposes; user disposes. Claude gets creation + read tools only.

### 3.1 Four creation tools

```
add_comment(project_id, document_id, paragraph_id, body)
  → { annotation_id }

add_suggested_change(project_id, document_id, paragraph_id, body, suggested_text)
  → { annotation_id }

add_query(project_id, document_id, paragraph_id, body)
  → { annotation_id }

add_craft_note(project_id, document_id, body)
  → { annotation_id }
```

Each op is stamped with `provenance.sessionId` (MCP session), `provenance.prompt` (if caller provides), and `provenance.toolArgs` (input record for forensic inspection).

### 3.2 Two read tools

```
list_annotations(project_id, document_id,
                 kinds?: ["comment" | "suggested_change" | "query" | "craft_note"],
                 statuses?: ["open" | "accepted" | "rejected" | "archived"],
                 paragraph_id?)
  → [{ id, kind, paragraph_id?, body, suggested_text?, status,
       user_response?, created_at, resolved_at? }]

get_annotation(project_id, document_id, annotation_id)
  → full annotation including state-transition history
```

**Load-bearing queries:**
- `list_annotations(kind: craft_note, status: accepted)` — next-session Claude consulting accepted craft principles.
- `list_annotations(paragraph_id: "a3f9")` — Claude checking prior conversation on a paragraph before suggesting a new change. Surfaces both prior accepted suggestions AND prior rejected ones with `user_response` so Claude doesn't re-suggest the same thing.

### 3.3 Registration

Six new schema declarations in `MCPToolsListHandler.swift`. Six new `router.register` calls in `MaughamApp.swift`. Tool registry grows from 14 → 20.

### 3.4 No lifecycle tools

No `accept_annotation` / `reject_annotation` / `archive_annotation` MCP tools. Lifecycle is the user's job via the Annotations pane. This is non-negotiable per the editorial vision — Claude operates in the parallel annotation layer and never mutates the manuscript directly.

---

## 4. Annotations pane (SwiftUI)

### 4.1 New file: `Maugham/Views/AnnotationsPane.swift`

```swift
struct AnnotationsPane: View {
    @Bindable var document: Document
    @State private var kindFilter: KindFilter = .all
    @State private var showResolved: Bool = false
    @State private var rejectSheet: Annotation? = nil
    @State private var querySheet: Annotation? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleAnnotations) { ann in
                        AnnotationRow(
                            annotation: ann,
                            onAccept: { accept(ann) },
                            onReject: { rejectSheet = ann },
                            onArchive: { archive(ann) },
                            onReply: { querySheet = ann },
                            onJumpToParagraph: { jumpTo(ann) })
                        Divider()
                    }
                }
            }
        }
        .sheet(item: $rejectSheet) { ann in
            RejectReasoningSheet(annotation: ann) { reason in
                Task { try? await document.rejectAnnotation(
                    id: ann.id, userResponse: reason) }
                rejectSheet = nil
            }
        }
        .sheet(item: $querySheet) { ann in
            QueryReplySheet(annotation: ann) { reply in
                Task { try? await document.acceptAnnotation(
                    id: ann.id, userResponse: reply) }
                querySheet = nil
            }
        }
    }
}
```

### 4.2 Toolbar

Top of pane: kind-filter pills (`All / Comments / Suggestions / Queries / Craft`) + open/all toggle. Filter persists per-window via UIState.

### 4.3 Per-kind row rendering

`AnnotationRow` switches on `annotation.kind`:
- **`.comment`**: body text + `[Got it]` + `[Archive]`.
- **`.suggestedChange`**: body + inline diff card (prior in red strikethrough, suggested in green) + `[Accept]` + `[Reject…]` + `[Archive]`. "Stale" badge if `annotation.isStale`.
- **`.query`**: body + `[Reply…]` + `[Archive]`. Reply opens `QueryReplySheet`.
- **`.craftNote`**: body + `[Accept (apply)]` + `[Reject…]` + `[Archive]`. Doc-scoped chip replaces paragraph context.

### 4.4 Sheets

- **`RejectReasoningSheet`**: TextField for `userResponse` + `[Cancel]` + `[Reject]`. Per editorial vision, captures "no, leave it" / "tried this, prefer the original because X." Becomes part of annotation history.
- **`QueryReplySheet`**: TextField for reply + `[Cancel]` + `[Reply]`. Reply text stored as `userResponse` on the resulting `claude_accept` op.

### 4.5 DetailSegment integration

`Maugham/Models/DetailSegment.swift` gains a case:
```swift
public enum DetailSegment: String, CaseIterable, Hashable {
    case inspector
    case annotations   // NEW
    case research
    case outline
    case history
}
```

Order in `DetailPaneToggle`: Inspector → Annotations → Research → Outline → History. Annotations sits next to Inspector because both are action surfaces for the active document.

### 4.6 Keyboard shortcut

`⌘⌥A` — mnemonic. Doesn't conflict with existing `⌘⌥1` (Inspector), `⌘⌥2` (Research), `⌘⌥3` (Outline), `⌘⌥4` (History). User muscle memory preserved.

### 4.7 Wiring

`ProjectWindow.swift` adds the new segment routing alongside the existing segments — same pattern as the milestone-document-first-class checkpoint integration.

---

## 5. History pane extension

### 5.1 Replace `CheckpointBrowserPane.swift` with `HistoryPane.swift`

The History segment now shows the full op vocabulary. The existing checkpoint-revert flow (`PartialRestorePicker`, `CheckpointLabelPromptSheet`) is reused unchanged.

### 5.2 Data sources

```swift
enum HistoryEntry: Identifiable {
    case op(Op)
    case checkpoint(Checkpoint)
    var id: String { switch self { ... } }
    var timestamp: Date { switch self { ... } }
}
```

Merged reverse-chronologically:
- `document.opLog()` — per-doc op log
- `CheckpointStore(projectURL:).load()` — project-wide checkpoints, scoped to those that have a `doc_pointer` for the active doc

### 5.3 Filter pills

Single-select, top of pane:
- **All** (default)
- **Checkpoints** — `checkpoint` + `checkpoint_restore`
- **Edits** — `typing_burst` + `bootstrap`
- **Annotations** — `claude_comment`, `claude_suggestion`, `claude_query`, `claude_craft_note`, `claude_accept`, `claude_reject`, `claude_archive`
- **External** — `external_edit`

Selection persists per-window via UIState.

### 5.4 Per-kind row rendering

`HistoryRow` switches on entry type and op kind:
- **`typing_burst`**: "Typed · N paragraphs · ¶id" + first-line snippet of the latest change.
- **`claude_suggestion`**: kind icon + body preview (first 80 chars).
- **`claude_accept`**: "Accepted suggestion" + `paragraph_id`; expanded row shows inline diff (prior → next).
- **`claude_reject`**: "Rejected suggestion" + `userResponse` as italicised quote.
- **`claude_archive`**: kind icon + body preview, dimmed; synthesisSource shown if present ("paragraph_deleted").
- **`claude_comment` / `claude_query` / `claude_craft_note`**: kind icon + body preview.
- **`external_edit`**: "External edit ingested · N paragraphs · ingest method".
- **`checkpoint`**: label + word count + active-doc context + `[Revert here…]` → existing `PartialRestorePicker`.
- **`checkpoint_restore`**: "Reverted to checkpoint '<label>'" + N paragraphs touched.
- **`bootstrap`**: "Initial — pre-tracking content".

### 5.5 Click semantics

- **Plain click**: expand the row in-place (full diff or full body).
- **⌘-click**: jump editor to affected paragraph via existing `.maughamNavigateToDocument` notification.
- **Click on Revert button**: opens `PartialRestorePicker` (existing component, unchanged).

### 5.6 Read-only annotations

Annotation rows in History do NOT show accept/reject/archive controls. Lifecycle controls live only in the Annotations pane. The two surfaces have distinct jobs; mixing would make navigation feel cramped.

### 5.7 Performance

LazyVStack handles virtualization. Op log is already in memory post-load; CheckpointStore.load reads on `.task`. No pagination for v1; revisit when measured.

### 5.8 File mechanics

- **Delete** `Maugham/Views/CheckpointBrowserPane.swift`.
- **Create** `Maugham/Views/HistoryPane.swift` (~300–400 lines including subviews).
- **Keep** `PartialRestorePicker.swift` and `CheckpointLabelPromptSheet.swift` unchanged.
- **Update** `DetailPaneToggle.swift` to route `.history` → `HistoryPane`.

---

## 6. Edge cases, tests, scope

### 6.1 Migration

Pure additive — existing op logs have no `claude_*` annotation ops. No bootstrap pass needed; no on-disk format change beyond appending new ops over time.

### 6.2 Test harness extensions

New file `MaughamTests/OpLog/AnnotationTests.swift` with 10 tests:

1. `test_addComment_appendsClaudeCommentOp`
2. `test_addSuggestedChange_includesPriorAndSuggested`
3. `test_acceptSuggestedChange_appliesChangeToDocument`
4. `test_acceptComment_doesNotChangeDisplayText`
5. `test_rejectWithUserResponse_capturesReasoning`
6. `test_archive_leavesAnnotationInHistoryButOutOfDefaultView`
7. `test_annotation_isMarkedStaleWhenParagraphChanges`
8. `test_paragraphDeletion_autoArchivesAnnotations`
9. `test_listAnnotations_filtersByKindAndStatus`
10. End-to-end: Claude adds via MCP → annotation appears in Document.annotations → user accepts via Document.acceptAnnotation → manuscript reflects change → list_annotations shows accepted state.

Plus harness tests for the UI flow under EditorIntegrationHarness; the existing 10 harness tests continue to pass as the conformance contract.

### 6.3 Explicit out of scope

- `craft_principles.md` project-local file (separate follow-up milestone).
- Sub-paragraph range anchors for suggested_change.
- Inline annotation marks in the editor text view.
- Bulk annotation operations.
- Cross-document annotation views.
- Annotations in non-active documents.
- Notification on cross-Mac annotation arrivals (the existing log-merge handles this automatically; in-window count-badge handles in-session arrivals).
- Real-time multi-writer collaboration.

---

## 7. Decisions locked

| # | Decision | Rationale |
|---|---|---|
| 1 | Annotations are ops; derived state | Matches Document-first-class philosophy; one log, append-only, cross-Mac log-merge transfers unchanged. |
| 2 | 4 kinds (comment / suggested_change / query / craft_note), unified open → accepted/rejected/archived lifecycle | Distinct intents but uniform state model keeps UI predictable; per-kind accept semantics vary internally. |
| 3 | Two right-pane segments: Annotations + History | Action vs forensic-scrub jobs stay distinct; History extends to show all ops, Annotations focuses on actionable items. |
| 4 | craft_notes live in annotation log only (v1) | Smaller scope; `craft_principles.md` can ship as follow-up; annotations work end-to-end without a new file format. |
| 5 | paragraph_id for action kinds; doc-scoped for craft_note | Each kind anchors at its natural granularity; nullable anchor schema. |
| 6 | 6 new MCP tools (4 creation + 2 read), no lifecycle tools for Claude | "Claude proposes, user disposes" — manuscript membrane is the user's. |
| 7 | accept-of-suggestedChange = one op, two effects (applies change + resolves status) | Cleaner single-op semantics; derivation handles both updates. |
| 8 | DetailSegment order: Inspector → Annotations → Research → Outline → History | Annotations is action-oriented, sits next to Inspector. |
| 9 | ⌘⌥A for Annotations | Mnemonic; doesn't conflict with existing ⌘⌥1-4. |
| 10 | Stale badge + confirm-dialog on stale suggested_change accept; auto-archive on paragraph deletion | Predictable handling of the lifecycle/staleness edge case without losing the editorial conversation record. |
