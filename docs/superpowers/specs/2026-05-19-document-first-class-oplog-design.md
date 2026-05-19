# Document-First-Class Op Log — Design Spec

**Status:** Approved 2026-05-19 by user, ready for implementation planning.

**Goal:** Make the operation log a first-class citizen of the architecture by introducing a `Document` type that owns the op log + pending buffer + burst scheduler + autosave + conflict detection for a single manuscript. `EditorHost` binds to `Document` directly; `DocumentStore` becomes a project-folder coordinator that hosts a registry of open Documents. The `.md` file becomes a derived artifact rendered from Document on the existing autosave cadence.

**Why now:** The 2026-05-19 state-of-the-code audit identified the operation-log infrastructure as the strongest architectural lever for upcoming work (editing UX with annotations, craft principles, compile pipeline, history-pane forensic scrub — all build on the op log). The implementation as shipped runs the op log as a *parallel* system to the `.md`, with five distinct representations of the same content coexisting (`NSTextView.string`, `EditorHost.documentText`, `documentStore.currentDocumentText`, `priorStoredMarkdown`, on-disk `.md`). The recent cluster of editor-input bugs (`2ada988`, `c798afb`, `8c73883`) were all symptoms of those representations drifting apart at runloop-tick boundaries. The audit's headline finding — `Bootstrap.run` is implemented but never invoked from production, so the "stable paragraph identity" feature isn't actually running for any real document — confirms the integration is structurally bolted on rather than substrate.

**Why this specific design:** Making the Document the source of truth collapses the five representations into one (Document.displayText) plus its renders (NSTextView, on-disk `.md`). Drift becomes structurally impossible. Annotations get natural `op_id` anchoring. Cross-Mac iCloud log-merge becomes the transparent mechanism the spec originally promised.

**What this spec does NOT cover:**
- The editing annotation schema (`suggested_change` / `comment` / `query` / `craft_note`) and accept/reject UX — separate downstream milestone, depends on this one.
- `craft_principles.md` foundation — separate small milestone, can land in parallel.
- Compile pipeline integration (LaTeX through pandoc, design specs).
- Real-time multi-writer collaboration — still future extension per the original OpLog spec §7.
- `ProjectStore.swift` split into files by concern — orthogonal cleanup (audit finding #6).
- `OpLogStore` + `CheckpointStore` shared `JSONLAppendStore<T>` abstraction — orthogonal (audit finding #9).
- `CharacterAutocompleter` dead-code decision — needs its own revive-vs-delete call.

**Constraint:** must not regress milestone-1e behaviour (autosave, conflict resolution, session tracking).

---

## 1. `Document` type — surface area

```swift
@MainActor
@Observable
public final class Document {
    // === Observed by editor/UI consumers ===

    /// Materialised display form (no inline ¶id comments). The single
    /// observed text-state property. Set internally only at the end of
    /// every mutation path so SwiftUI sees one observable change per
    /// edit — the structural fix for the binding-loop race.
    public private(set) var displayText: String = ""

    /// Cursor location persisted per-document. Editor reads on attach,
    /// writes on selection change. UIState persists via the existing
    /// debounce path.
    public var cursorLocation: Int = 0

    /// Pending external-edit conflict from the Reconciler classify path.
    /// Replaces DocumentStore.pendingConflict for per-document concerns.
    public private(set) var pendingConflict: ConflictState?

    // === Mutation API ===

    /// Editor entry point. Parses new text, diffs against current
    /// derived state, appends paragraph-change ops to the pending
    /// buffer, updates internal derived state, and finally writes
    /// _displayText. All internal work happens before _displayText is
    /// touched so SwiftUI sees exactly one observable change.
    public func setFullText(_ text: String)

    /// Programmatic paragraph mutation. Used by annotations / Claude
    /// actions / restore. Constructs a single-paragraph Op directly
    /// without re-parsing the whole document.
    public func setParagraph(id: String, text: String)
    public func insertParagraph(after: String?, text: String) -> String
    public func deleteParagraph(id: String)
    public func reorder(sequence: [String])

    // === Restore / history ===

    public func emitCheckpointRestoreOp(
        toCheckpoint: Checkpoint,
        scope: Restore.Scope) async throws
    public func opLog() -> [Op]
    public func paragraphsAt(opId: String) -> [String: String]

    // === Persistence ===

    /// Render the on-disk .md form (with inline ¶id comments).
    public func materialize() -> String

    /// Force-flush the pending buffer as a typing_burst op. Called on
    /// ⌘S, doc-switch, window-close.
    public func flushBurstNow() async throws

    /// Flush pending burst + flush pending autosave. Called when the
    /// document is leaving memory.
    public func close() async

    // === External-edit ingest ===

    /// Called by DocumentStore's presenter delegate when the manuscript
    /// file changes externally. Runs Reconciler.classify and dispatches
    /// to echo / silentIngest / needsSheet.
    public func handleExternalDiskChange(diskMd: String) async throws

    /// Called when the op log file changes externally (iCloud sync from
    /// another Mac). Reloads + dedupes + sorts + re-derives. Transparent
    /// to the user — no conflict UI.
    public func handleExternalLogChange() async throws

    // === Conflict resolution ===

    public func resolveConflictKeepMine() async throws
    public func resolveConflictUseExternal() async throws

    // === Construction ===

    public static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?
    ) async throws -> Document
}
```

### Internal state (private)

- `url: URL` — the .md file path on disk.
- `docId: String` — stable identifier.
- `device: String`, `session: String` — stamped onto every emitted Op.
- `presenter: NSFilePresenter?` — used for NSFileCoordinator-coordinated reads/writes.
- `opStore: OpLogStore`
- `pendingBuffer: PendingBuffer`
- `burstScheduler: BurstScheduler`
- `autosaveScheduler: DebounceScheduler<Void>` — 750 ms debounce; on fire, writes `materialize()` to disk.
- `paragraphs: [String: String]` — current derived state (private).
- `sequence: [String]` — current paragraph order (private).
- `lastWrittenText: String` — bytes most recently written to disk; used by external-edit echo detection.

### Discipline: one observable write per mutation

Every public mutation method (`setFullText`, `setParagraph`, etc., `handleExternalDiskChange`, `handleExternalLogChange`, restore op application) follows the pattern:

1. Validate inputs.
2. Compute new ops.
3. Append to pending buffer (in-memory + .pending.jsonl mirror via existing PendingBuffer).
4. Update internal `paragraphs` / `sequence`.
5. Schedule autosave (debounced).
6. **Write `_displayText` exactly once** at the end, after all internal state is settled.

This is the structural fix for the binding-loop race. SwiftUI re-evaluates body at most once per mutation, reads `displayText` at its final value, and `updateNSView` always sees a consistent `(textView, text)` pair.

---

## 2. `DocumentStore` — reduced role

After Document takes the substrate, `DocumentStore` becomes a project-folder coordinator with a registry of open Documents.

### What stays in DocumentStore

- Manifest read/write (project-level, via NSFileCoordinator).
- Session tracking (`recordSessionActivity`, idle timer, `flushSessionOnQuit`).
- UI state persistence (debounced uiState write, cursor positions keyed by doc-id).
- Rename plan execution (project-level structural changes).
- Coordinated copy / move helpers (used by Duplicate, Tidy, Collection moves).
- `ProjectFolderPresenter` delegate conformance — receives presenter callbacks and dispatches.

### What moves to Document

- `currentDocumentText`, `lastWrittenText` (per-document).
- Autosave path (`scheduleSave`, `performSave`, `flushPendingSave`).
- Conflict detection (`handleOpenDocumentChanged`, Case A / Case B, `resolveConflictKeepMine`, `resolveConflictUseCloud`, conflict backup write).
- Op-log integration block (`beginOpLogContext` through `persistPendingBufferToDisk`) — entire 120-line block.
- `openDocument(at:)` — replaced by `Document.load(...)`.

### Registry — presenter dispatch glue

DocumentStore holds the registry indexed primarily by relative manuscript path (the natural identifier on the EditorHost side):

```swift
private var openDocuments: [String: Document] = [:]  // keyed by relative path
```

Public API:

```swift
public func register(document: Document, for path: String)
public func unregister(path: String)
public func document(for path: String) -> Document?
public func document(forDocId docId: String) -> Document?
```

`document(forDocId:)` iterates the values once and returns the Document whose `docId` matches — acceptable for the registry size (typically 1, ceiling of a handful with multi-window).

`presenterDidChangeSubitem(at:)` switches on path:

- `project.maugham.json` → manifest archive logic (today's path, unchanged).
- A registered manuscript path → `document(for: path)?.handleExternalDiskChange(diskMd: ...)`.
- `.maugham/ops/<id>.jsonl` → `document(forDocId: id)?.handleExternalLogChange()`.
- `.maugham/checkpoints.jsonl` → post `maughamCheckpointAdded` notification (existing path).

### Net file-size impact

DocumentStore: 587 → ~250–300 lines. Document: new file at ~400 lines.

---

## 3. `EditorHost` binding shape

```swift
struct EditorHost: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let selectedItemId: String?
    var onTextChange: ((String) -> Void)? = nil
    var wikiLinkResolver: ((String) -> Bool)? = nil
    var wikiLinkClickResolver: ((String) -> String?)? = nil
    @Environment(UserPreferences.self) private var userPreferences

    @State private var document: Document?
    @State private var loadedItemId: String?
    /// Tracked alongside loadedItemId so doc-switch can unregister the
    /// prior path from the DocumentStore registry (which is path-keyed).
    @State private var priorLoadedPath: String?

    private static let sessionId: String = UUID().uuidString
    private static let deviceId: String = {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "unknown-host" : name
    }()

    var body: some View {
        Group {
            if let item = currentItem, item.type == .document, let path = item.path,
               let doc = document, loadedItemId == item.id {
                EditorSurface(
                    text: Binding(
                        get: { doc.displayText },
                        set: { doc.setFullText($0) }
                    ),
                    theme: userPreferences.theme,
                    typography: ProjectStore.effectiveTypography(
                        override: store.manifest.typography,
                        userDefault: userPreferences.typography),
                    mode: WritingModeFactory.mode(for: path),
                    typewriterScroll: userPreferences.typewriterScroll,
                    sentenceFocus: userPreferences.sentenceFocus,
                    paragraphFocus: userPreferences.paragraphFocus,
                    initialCursorLocation: doc.cursorLocation,
                    onCursorChanged: { doc.cursorLocation = $0 },
                    wikiLinkResolver: wikiLinkResolver,
                    wikiLinkClickResolver: wikiLinkClickResolver,
                    showElementGutter: store.manifest.showElementGutter ?? true
                )
                .id(path)
            } else if currentItem?.type == .group {
                placeholder("Select a document inside this group to edit.")
            } else if currentItem?.type == .document {
                placeholder("Loading…")
            } else {
                placeholder("Select a document.")
            }
        }
        .onChange(of: selectedItemId) { _, _ in
            Task { await loadDocumentIfNeeded() }
        }
        .onChange(of: document?.displayText) { _, newValue in
            if let text = newValue { onTextChange?(text) }
        }
        .task { await loadDocumentIfNeeded() }
    }

    private func loadDocumentIfNeeded() async {
        guard let item = currentItem,
              item.type == .document,
              let path = item.path,
              loadedItemId != item.id else { return }
        // Close + unregister the prior Document if any. Track the prior
        // path in @State so we can unregister precisely (item.id and path
        // aren't the same key; the registry is path-keyed).
        if let prior = document, let priorPath = priorLoadedPath {
            await prior.close()
            documentStore.unregister(path: priorPath)
        }
        do {
            let doc = try await Document.load(
                url: store.url.appendingPathComponent(path),
                device: Self.deviceId,
                session: Self.sessionId,
                presenter: documentStore.presenter)
            documentStore.register(document: doc, for: path)
            document = doc
            loadedItemId = item.id
            priorLoadedPath = path
            onTextChange?(doc.displayText)
        } catch {
            document = nil
            loadedItemId = item.id
            priorLoadedPath = nil
        }
    }
}
```

### What changes vs current shape

- No `documentText` (@State) — `Document.displayText` is the truth.
- No `priorStoredMarkdown` — Document holds prior state internally.
- No `documentStore.currentDocumentText = ...` writes — Document holds it.
- The binding's setter calls `doc.setFullText`, which writes `_displayText` once at the end. Only one observable change per keystroke → only one body re-eval → only one `updateNSView` with a consistent `(textView, text)` pair.
- `onTextChange` (for ProjectWindow's metric updates) fires via `.onChange(of: document?.displayText)` — the same trigger SwiftUI uses for the rest of the view tree.

---

## 4. `.md` persistence cadence + external-edit reconciliation

### Persistence cadence — unchanged behaviour, relocated owner

Document maintains an internal `DebounceScheduler<Void>` (750 ms) that fires `materialize()` and writes the result via NSFileCoordinator. Trigger points:

- Any mutation (`setFullText`, paragraph mutations) calls `scheduleAutosave()` which re-arms the debounce.
- `flushBurstNow()` and `close()` flush the pending autosave synchronously.
- The 750 ms cadence is identical to today's user experience.

After a write, `lastWrittenText` is updated to the materialized bytes so external-edit echo detection works.

### External-edit reconciliation — same Reconciler, relocated owner

**Path 1: `.md` changed externally** (BBEdit, sed, iCloud sync from another Mac's `.md`)

`DocumentStore.presenterDidChangeSubitem` routes to `Document.handleExternalDiskChange(diskMd:)`:

1. Compare `diskMd` to `lastWrittenText`. If equal: echo, return.
2. Run `Reconciler.classify(diskMd:, derivedMd:)`:
   - `.echo` → no-op.
   - `.silentIngest(changes:)` → construct one `external_edit` Op carrying the changes, append, re-derive, update `_displayText`. Editor reflects via observable change. No UI surfaces.
   - `.needsSheet(orphanCount:)` → set `pendingConflict`. UI surfaces existing diff sheet bound to `document.pendingConflict`. Resolution calls `Document.resolveConflictKeepMine()` or `resolveConflictUseExternal()`.

**Path 2: `.maugham/ops/<id>.jsonl` changed externally** (iCloud sync from another Mac)

`DocumentStore.presenterDidChangeSubitem` routes to `Document.handleExternalLogChange()`:

1. `OpLogStore.load(docId:)` — reloads, dedupes by `op_id`, sorts.
2. `Deriver.derive(ops:)` — computes new state from merged log.
3. Update internal `paragraphs` / `sequence`.
4. Write `_displayText` once. Editor reflects via observable change.

No conflict UI for the log-merge path. The transparent-sync mechanism the OpLog spec promised, now actually wired.

---

## 5. `Bootstrap` wiring + load-time invariant

`Document.load(url:device:session:presenter:)` runs Bootstrap as part of construction whenever a document is opened that lacks inline `¶id` comments or has no op log file yet. The audit's headline finding (Bootstrap never called from production) fixes naturally.

```swift
public static func load(
    url: URL,
    device: String,
    session: String,
    presenter: NSFilePresenter?
) async throws -> Document {
    let docId = try resolveDocId(for: url)
    let projectURL = url.deletingLastPathComponent()
        .deletingLastPathComponent()  // path/manuscript/foo.md → path

    // Bootstrap detection: needs migration if no op log file OR if .md
    // has no inline ¶id markers.
    let opLogPath = projectURL
        .appendingPathComponent(".maugham/ops/\(docId).jsonl")
    let logExists = FileManager.default.fileExists(atPath: opLogPath.path)
    let storedBytes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let parsed = ParagraphParser.parse(storedBytes)
    let needsBootstrap = !logExists || parsed.allSatisfy { $0.id == nil }

    if needsBootstrap {
        _ = try await Bootstrap.run(
            projectURL: projectURL,
            docId: docId,
            mdURL: url,
            device: device,
            session: session)
    }

    let opStore = OpLogStore(projectURL: projectURL, presenter: presenter)
    let pending = PendingBuffer(projectURL: projectURL, docId: docId)
    try await pending.loadFromDisk()

    var ops = try await opStore.load(docId: docId)

    // Crash recovery: fold any pending changes into a synthesized
    // typing_burst op so editorial classification survives the crash.
    if !pending.isEmpty() {
        let recovered = Op(
            opId: ULID.generate(), docId: docId, at: Date(),
            device: device, session: session, kind: .typingBurst,
            changes: pending.snapshot())
        try await opStore.append(recovered)
        try await pending.clear()
        ops.append(recovered)
    }

    let initial = Deriver.derive(ops: ops)
    return Document(
        url: url, docId: docId, device: device, session: session,
        presenter: presenter, opStore: opStore, pending: pending,
        paragraphs: initial.paragraphs, sequence: initial.sequence)
}
```

Bootstrap runs once per document, the first time Maugham encounters it. The `.md` file gains inline `¶id` comments at that moment. From there on, the op log carries the canonical state.

---

## 6. Editor integration test harness — write first

`MaughamTests/Editor/EditorIntegrationHarness.swift` ships before any Document code lands. Tests run against the *current* `EditorHost` + `EditorCoordinator`. They become the conformance contract the refactor must satisfy.

### Rig

```swift
@MainActor
final class EditorIntegrationHarness {
    let window: NSWindow      // offscreen
    let textView: NSTextView  // real, attached to window
    let coordinator: EditorCoordinator
    let documentStore: DocumentStore
    let projectURL: URL
    let docPath: String

    /// applyExternalText call recorder for invariant assertions.
    private(set) var applyExternalTextCallCount: Int = 0

    func makeRig(
        mode: any WritingMode = ProseMode(),
        initialText: String = "",
        cursorLocation: Int? = nil
    ) -> Self
    func typeCharacter(_ c: Character)
    func typeString(_ s: String, intervalMs: Int = 0)
    func setCursor(to: Int)
    func selectRange(_ range: NSRange)
    func waitForAutosave() async throws
    func flushPendingBurst() async throws
    func writeExternalMdContent(_ content: String) async throws
    func assertNoApplyExternalText(during body: () -> Void)
}
```

### Tests (10, regression for each bug class)

1. **`test_singleCharacterTyped_textViewMatchesUserInput`** — type "a"; cursor at 1.
2. **`test_rapidTyping_preservesCursorAtEnd`** — type "The quick brown fox" character by character; final cursor at string length.
3. **`test_rapidTyping_inMiddle_preservesInsertionPoint`** — same with mid-text cursor.
4. **`test_trailingSpace_persistsAcrossAutosave`** — type "hello "; await autosave; type another char; space still present.
5. **`test_pasteMultiCharString_preservesCursorAtPasteEnd`** — paste "foo bar"; cursor advances by 7.
6. **`test_externalEditWithIdsIntact_ingestsSilently`** — write modified `.md` with intact `¶id`s under presenter; editor updates without conflict sheet; cursor preserved.
7. **`test_externalEditWithIdsStripped_surfacesConflict`** — write `.md` with `¶id`s removed; `pendingConflict` set on Document.
8. **`test_endOfFileTyping_doesNotFireApplyExternalText`** — at end of doc, type one char; `applyExternalText` was not called. (Post-refactor invariant — fails today, passes after Stage 2.)
9. **`test_documentSwitch_flushesPendingBurst_beforeNewBinding`** — type in doc A, switch to doc B; doc A's op log received the typing_burst.
10. **`test_burst_appendOnceAtIdleThreshold`** — type a burst, wait > 30 s, exactly one typing_burst op in log.

Tests 1–5, 9, 10 should pass today (assuming the recent fixes hold). Test 8 fails today and passes after Stage 2. Tests 6, 7 may be partially broken today (Reconciler integration is untested end-to-end per audit); they pin the contract for Stage 3.

### Out of scope for the harness

- Real Xcode UI tests — too slow / flaky for the binding-layer bugs.
- Document-internals tests (parse, diff, op emission) — those go in `DocumentTests.swift` later.
- Mode-specific behaviour (Tab cycle, smart typography) — covered by existing `EditorCoordinatorCycleTests`.

---

## 7. Migration sequence — 5 stages

Each stage is independently testable, reversible, and gated by all tests passing.

### Stage 0 — Test harness against current API

Ship `EditorIntegrationHarnessTests` from §6 with all 10 tests against today's editor. Tests 1–5, 9, 10 pass; tests 6, 7 may be partially broken; test 8 fails (post-refactor invariant). Document the failures explicitly.

**Gate:** harness compiles, runs, recorded pass/fail status matches expectations. No production code changes.

### Stage 1 — Introduce `Document` type, alongside existing code

- `Maugham/OpLog/Document.swift` — full API from §1.
- `Document.load(...)` implements Bootstrap + log-load + crash-recovery per §5.
- `setFullText` / paragraph mutations / `materialize` / `flushBurstNow` / `handleExternalDiskChange` / `handleExternalLogChange` / `resolveConflict*` implemented.
- Internal autosave via `DebounceScheduler<Void>` per §4.
- `MaughamTests/OpLog/DocumentTests.swift` — unit tests for Document in isolation.

**Gate:** Document compiles, has unit-test coverage, but nothing in production references it. All 706 + harness tests still pass.

### Stage 2 — Route `EditorHost` through `Document`

- `EditorHost` per §3: `@State document: Document?` replaces `documentText` + `priorStoredMarkdown` + reads of `documentStore.currentDocumentText`.
- `DocumentStore` gains `register(document:for:)` / `unregister(path:)` / `document(for:)` registry.
- Binding becomes `Binding(get: { doc.displayText }, set: { doc.setFullText($0) })`.
- `loadDocumentIfNeeded` constructs `Document.load(...)` and registers.

**Gate:** all harness tests pass. End-of-file typing works without races (test 8 now passes). DocumentStore still has its op-log block (now dead) and autosave/conflict code (now duplicated).

### Stage 3 — Move presenter dispatch into `DocumentStore` registry

- `DocumentStore.presenterDidChangeSubitem` switches on path:
  - manifest → archive (existing).
  - manuscript file → `documents[path]?.handleExternalDiskChange(...)`.
  - op log → look up Document, `handleExternalLogChange()`.
  - checkpoints → post existing notification.
- Remove `handleOpenDocumentChanged` / Case A / Case B / `resolveConflictKeepMine` / `resolveConflictUseCloud` from DocumentStore — Document owns these.
- Remove `openDocument(at:)`, `currentDocumentText`, `lastWrittenText`, `scheduleSave`, `performSave`, `flushPendingSave` — Document owns these.
- Remove op-log integration block (`beginOpLogContext` through `persistPendingBufferToDisk`).

**Gate:** DocumentStore drops from 587 to ~250–300 lines. All harness tests pass. Tests 6 and 7 (external-edit reconciliation) now pass — the path is wired end-to-end via Document.

### Stage 4 — UI conflict-sheet hookup + cursor migration

- Conflict resolution UI re-routes to `document?.pendingConflict`.
- `resolveConflict*` UI actions call into Document.
- Cursor positions migrate from `documentStore.cursor(for:)` to `Document.cursorLocation`. Persistence via UIState keyed by doc-id; load on Document construction, save via existing UIState debounce.

**Gate:** all harness tests pass including 7. Full app smoke for: type, save, ⌘S, switch docs, external edit via Finder, simulated iCloud log sync.

### Stage 5 — Cleanup

- **Char-bigram tier moves into `ShingleMatcher`** (audit finding #5). Either as a sibling function (e.g. `bigramOverlap`) or behind a unified `bestMatch` that tries tiers internally. `RenderFilter` calls `ShingleMatcher` exclusively; no local bigram code.
- **`applyFocusDim` redundancy removed** (audit finding #11). Currently called from three places (inside `retokenizeAndStyle`, at end of `textDidChange`, inside `textViewDidChangeSelection`). The textDidChange call is redundant with the retokenize call. Reduce to two paths: retokenize (covers text changes) and selection change (covers cursor moves without text changes). Document the remaining intent.
- Update auto-memory (`project_milestone_document_first_class.md` + index entry in `MEMORY.md`).
- Tag and merge.

**Total: 8–12 tasks across 5 stages.**

---

## 8. Decisions locked

| # | Decision | Rationale |
|---|---|---|
| 1 | Hybrid mutation API on Document (`setFullText` + paragraph-level methods) | Editor uses full-text (NSTextView's natural interface); annotations and programmatic edits use paragraph-level (the spec's intended op_id anchoring). |
| 2 | OpLog + PendingBuffer + BurstScheduler owned by Document | The truly-first-class shape. Each open Document is self-contained. |
| 3 | Document is `@Observable`; EditorHost uses explicit `Binding(get:, set:)` | Single observed property (`displayText`); setter calls into Document, no intermediate `@State`. The recent binding-loop race is structurally impossible. |
| 4 | DocumentStore evolves to project-folder coordinator + Document registry | Per-doc concerns (autosave, conflict, content) move to Document; project-level concerns (manifest, sessions, UI state, rename) stay. |
| 5 | `.md` persistence cadence unchanged (750 ms autosave debounce) | No user-perceptible latency change; familiar behaviour. |
| 6 | External `.md` edit → Reconciler classify, owned by Document | Same logic as today, relocated. Cleaner end-to-end via the registry. |
| 7 | External op log change → log-merge transparent to UI | The spec's promise, now actually wired via `handleExternalLogChange`. |
| 8 | Bootstrap runs inside `Document.load` when needed | Fixes the audit's headline finding (Bootstrap never called from production). |
| 9 | Test harness ships before the refactor; serves as conformance contract | The class of bugs the unit suite missed is exactly the class we'd ship in editing UX and compile. Pays for itself across the migration and future milestones. |
| 10 | 5-stage migration with green-test gates between each stage | No big-bang. No two-week branch divergence. Reversible at each step. |

---

## 9. Out of scope — explicit

- Annotation schema and accept/reject UX — separate downstream milestone, depends on this one.
- `craft_principles.md` foundation — separate small milestone, parallel-ok.
- Compile pipeline / typesetting — separate major milestone.
- Real-time multi-writer collab — still future extension per OpLog spec §7.
- ProjectStore file-level split (audit finding #6) — orthogonal cleanup, can land anytime.
- OpLogStore + CheckpointStore shared `JSONLAppendStore<T>` (audit finding #9) — orthogonal cleanup.
- CharacterAutocompleter dead-code decision (audit finding #4) — needs its own revive-vs-delete call; deferred.
- History pane forensic burst-level scrub — separate enhancement on top of the checkpoint browser that shipped.
