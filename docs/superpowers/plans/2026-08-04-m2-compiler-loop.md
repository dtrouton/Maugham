# M2 Plan 1 — the compiler loop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tight feedback loop end to end — one keystroke runs a warm `claude -p` session over the op-log delta and streams ¶-anchored diagnostics into a new pane, with the four fates (fix / ignore / promote-to-task / answer-into-intent) and drift detection.

**Architecture:** A new `Maugham/Compiler/` area: a pure `DeltaBuilder` over `[Op]`, a `CompilerPromptBuilder`, a `CompilerRunner` seam whose production implementation manages one long-lived `claude -p` stream-json process, and a per-device transient `DiagnosticsStore` sidecar (never the op log). One new `DetailSegment.diagnostics` pane. Spec: `docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md`. Spike evidence (flags, latency, socket concurrency all verified 2026-08-04): `docs/superpowers/notes/2026-08-04-m2-spike.md`.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest, `Process` + pipes (the `TectonicInvoker` pattern), JSON sidecars.

## Global Constraints

- **A plan carries contracts and verified signatures, never function bodies** (`memory/feedback_plan_code_is_a_liability.md`). Test intents below are contracts; implementers write the code TDD, red first.
- `./gen.sh` after adding any file and BEFORE `-only-testing` runs; `-only-testing` paths are flat (folder-shaped paths run 0 tests and exit green).
- Build/test: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`; skip the wall-clock MCP suites with `-skip-testing:MaughamTests/MCPServerLifecycleTests` when running whole.
- MaughamCore's own suites: `cd Packages/MaughamCore && swift test` (neither scheme runs them).
- **Warm builds re-emit no warnings** — `touch` the file (or clean) before believing a warning-absence claim. A Sendable/concurrency diagnostic on a file you just wrote is real.
- Diagnostics arrival must never touch the editor binding (tripwires 3, 6). No raw NotificationCenter (tripwire 21 — `MaughamEvent` only). Sidecar filenames take `DeviceSlug` (tripwire 24). No raw manuscript read as truth (tripwire 20) — the delta comes from ops, current text from the live `Document`.
- The store is **derived state**: deleting `.maugham/diagnostics/` must cost nothing durable.
- Copy register: understated, honest, never claiming more than happened. No dialogs for failures — pane states.
- Commit after every green task. **No push at any point.**
- Subagent models: opus for tasks 2, 5, 6, 9, 10; sonnet for 1, 3, 7, 8; haiku acceptable for 4. Reviewers: haiku.

## File Structure

```
Maugham/Compiler/                    (new area — Task 1 creates, Task 10 finishes AREA.md)
  Diagnostic.swift                   models + sidecar DTOs
  DiagnosticsStore.swift             @Observable store, per-device sidecar
  DeltaBuilder.swift                 pure function over [Op]
  CompilerPrompt.swift               prompt assembly + context diffing
  CompilerAllowlist.swift            enumerated read-only MCP tools
  CompilerRunner.swift               seam (protocol + run/session state)
  ClaudeCLISession.swift             warm process, stream-json, locator
  DiagnosticIngest.swift             validate + store write
  IntentAppendPerformer.swift        answer → statement append
  AREA.md
Maugham/Views/DiagnosticsPane.swift  the pane
MaughamTests/Compiler*Tests.swift    one test file per source file above
```

---

### Task 1: Diagnostic models and the per-device DiagnosticsStore

**Files:**
- Create: `Maugham/Compiler/Diagnostic.swift`, `Maugham/Compiler/DiagnosticsStore.swift`
- Test: `MaughamTests/DiagnosticsStoreTests.swift`

**Interfaces — Produces:**
```swift
struct Diagnostic: Identifiable, Codable, Equatable, Sendable {
    let id: String                 // ULID
    let docId: String
    let anchor: Anchor?            // nil = drift diagnostic (pinned, no ¶)
    struct Anchor: Codable, Equatable, Sendable { let paragraphId: String; let anchorText: String }
    let body: String
    let category: String?          // free-form, display-only
    let runId: String
}
struct CompilerRun: Codable, Equatable, Sendable {
    let id: String; let at: Date; let model: String
    let lastOpId: String?          // the delta marker AFTER this run
    let deltaSummary: String       // e.g. "3 new, 2 revised ¶"
    let intentSnapshot: String?    // what the run checked against
}
@Observable @MainActor final class DiagnosticsStore {
    private(set) var version: Int              // monotonic; pane reads it
    func load(docId: String)                   // reads this device's sidecar only
    func replace(run: CompilerRun, diagnostics: [Diagnostic], docId: String)  // new run replaces un-promoted
    func live(docId: String, currentText: (String) -> String?) -> [Diagnostic]
        // filters: anchored + paragraph text == anchorText; drift notes always live
        // currentText(paragraphId) -> nil means the ¶ is gone → not live
    func dismiss(_ id: String, docId: String)  // answer/ignore removal
    func lastRun(docId: String) -> CompilerRun?
    func lastOpId(docId: String) -> String?    // the delta marker
    static func sidecarURL(projectRoot: URL, docId: String, device: DeviceSlug) -> URL
        // .maugham/diagnostics/<docId>.<slug>.json — interpolate .raw ONLY here (tripwire 24)
}
```

**Consumes:** `DeviceSlug.make(from:)` (`Packages/MaughamCore/Sources/MaughamCore/DeviceSlug.swift:32`); ULID minting as `Op` ids do.

**Steps:**
- [ ] Failing tests first, then implement, then commit. Test contracts:
  - `test_sidecarFilename_isPerDevice_andTakesDeviceSlug` — URL ends `<docId>.<slug>.json` under `.maugham/diagnostics/`; builder signature accepts `DeviceSlug`, not `String` (the compiler enforces; assert the path shape).
  - `test_replace_dropsThePreviousRunsDiagnostics` — two `replace` calls; only the second run's notes remain; version bumped each time.
  - `test_live_filtersAnchoredNotesWhoseParagraphChanged` — note with `anchorText: "old"`, currentText returns `"new"` → absent; returns `"old"` → present; returns nil (¶ deleted) → absent.
  - `test_live_keepsDriftNotesRegardlessOfText` — anchor nil → always live until dismissed/replaced.
  - `test_roundTrip_survivesRelaunch` — write, new store instance, load, equal.
  - `test_corruptSidecar_readsAsEmpty_neverThrows` — garbage bytes → empty store, no crash (derived state; losing it costs nothing).
  - `test_dismiss_removesOneNote_andBumpsVersion`.
- [ ] `./gen.sh`, run suite, commit.

---

### Task 2: DeltaBuilder — the pure function over ops

**Files:**
- Create: `Maugham/Compiler/DeltaBuilder.swift`
- Test: `MaughamTests/DeltaBuilderTests.swift`

**Interfaces — Produces:**
```swift
struct CompilerDelta: Equatable, Sendable {
    struct NewParagraph: Equatable, Sendable { let paragraphId: String; let text: String }
    struct RevisedParagraph: Equatable, Sendable { let paragraphId: String; let prior: String; let text: String }
    let new: [NewParagraph]
    let revised: [RevisedParagraph]     // in current sequence order
    let newestOpId: String?             // the next marker; nil if no ops after marker
    var isEmpty: Bool
}
enum DeltaBuilder {
    static func delta(ops: [Op], since markerOpId: String?,
                      currentParagraphs: [String: String], sequence: [String]) -> CompilerDelta
}
```

**Consumes:** `Op.ParagraphChange { paragraphId, prior, next }` (`Packages/MaughamCore/Sources/MaughamCore/Op.swift:17-30`); ULID string order == op order (`Deriver.opOrder`, `Deriver.swift:30-41`). Current text is passed in (from the live `Document`, walked by `sequence` — tripwire: `sequence` is authoritative).

**Contracts (golden tests, red first):**
- [ ] `test_firstRun_everythingIsNew` — `since: nil` → every paragraph in `sequence` is `new`, ordered by `sequence`.
- [ ] `test_revisedParagraph_carriesFirstSeenPrior` — two ops touch one ¶ after the marker; `prior` is the FIRST op's prior (the text as of the marker), `text` is current.
- [ ] `test_paragraphNewSinceMarker_hasNilPrior_andIsNew` — an op with `prior: nil` after the marker → `new`, even if later ops revised it.
- [ ] `test_deletedParagraph_isOmitted` — revised then removed from `currentParagraphs`/`sequence` → appears nowhere.
- [ ] `test_opsAtOrBeforeMarker_areIgnored` — strictly-after comparison on opId strings.
- [ ] `test_orderFollowsSequence_notOpArrival`.
- [ ] `test_newestOpId_advancesToTheLastOpSeen` and `test_noOpsAfterMarker_isEmpty_andKeepsNilNewestOpId`.
- [ ] Annotation/task ops touching no paragraph text (empty `changes`) contribute nothing — `test_nonTextOps_produceNoDeltaEntries`.
- [ ] `./gen.sh`, run, commit.

---

### Task 3: CompilerPrompt — assembly and context diffing

**Files:**
- Create: `Maugham/Compiler/CompilerPrompt.swift`
- Test: `MaughamTests/CompilerPromptTests.swift`

**Interfaces — Produces:**
```swift
struct CompilerContext: Equatable, Sendable {
    let projectId: String
    let intentText: String?          // resolved piece-first (caller resolves)
    let intentScopeLabel: String     // "this chapter" / "the project"
    let pinnedListing: [String]      // "title (id)" lines — ids the run can feed to read tools
    let paletteListing: [String]
}
enum CompilerPrompt {
    static func sessionSystemPreamble(projectId: String) -> String
    static func runMessage(delta: CompilerDelta, context: CompilerContext,
                           previousIntentHash: String?) -> (message: String, intentHash: String?)
}
```

**Contracts:**
- [ ] The run message labels new vs revised differently and attaches `prior` ONLY to revisions — `test_revisionsCarryPrior_newDoesNot`.
- [ ] Intent is embedded verbatim when `previousIntentHash` differs from the current hash, and replaced by a one-line "unchanged since last run" marker when equal — `test_intentIsDiffedIn_notResent`. Hash = SHA256 of the intent text; nil intent → no intent section and nil hash out.
- [ ] Pinned/palette sections list ids+titles only and name the MCP tools to read them (`read_document`, `read_palette_card`) — `test_listingsCarryIdsAndToolNames_notContents`.
- [ ] The standing drift question is present in every run message — `test_driftQuestionIsAlwaysAsked`.
- [ ] The output-format instruction demands a single JSON object `{"diagnostics":[{"paragraph_id":String?,"category":String?,"body":String}],"intent_drift":String?}` and states ¶ids must be copied exactly — `test_outputSchemaInstruction_matchesDiagnosticIngestExpectations` (Task 6 parses exactly this shape; the test pins the schema string both tasks share — put the schema literal in `CompilerPrompt.outputSchemaDescription` and have Task 6's parser tests reference the same constant, so they cannot drift).
- [ ] No paragraph anchors comments (`<!-- ¶id -->`) leak into embedded prose; the delta carries clean text with ids alongside — `test_embeddedProseIsClean`.
- [ ] `./gen.sh`, run, commit.

---

### Task 4: CompilerAllowlist — enumerated and censused

**Files:**
- Create: `Maugham/Compiler/CompilerAllowlist.swift`
- Test: `MaughamTests/CompilerAllowlistTests.swift`

**Interfaces — Produces:**
```swift
enum CompilerAllowlist {
    static let tools: [String]        // "mcp__maugham__<name>" entries
    static func cliArguments() -> [String]   // ["--allowedTools", joined]
}
```

**Contracts:**
- [ ] Every entry resolves to a tool in `MCPToolCatalog.all` (`Maugham/MCP/MCPTool.swift:36-91`) after stripping the `mcp__maugham__` prefix — `test_everyEntryNamesACatalogTool`.
- [ ] **No write tool is present**: assert the set is disjoint from the named writes — `add_note`, `add_comment`, `add_suggested_change`, `add_query`, `add_craft_note`, `add_canvas_scraps`, `promote_inbox_entry`, `move_research_item`, `link_research`, `unlink_research`, `write_translation`, `write_publish_file`, `delete_publish_file`, `set_publish_config`, `set_piece_style`, `clear_piece_style`, `initialize_publish_template`, `republish`, `compile`, `compile_cancel` — `test_noWriteToolIsAllowed`. Planted-offender companion: a test-local list containing `add_note` must FAIL the same predicate — `test_theCensusWouldCatchAWrite` (a census needs a control; `memory/feedback_census_over_warning.md`).
- [ ] Contains at minimum: `read_document`, `read_craft_intent`, `read_visual_language`, `list_palette_cards`, `read_palette_card`, `list_research`, `list_canvas`, `search_text`, `get_outline`, `get_metadata` — `test_theCompilerCanReachItsDeclaredContext`.
- [ ] `./gen.sh`, run, commit.

---

### Task 5: ClaudeCLISession — the warm process behind the seam

**Files:**
- Create: `Maugham/Compiler/CompilerRunner.swift`, `Maugham/Compiler/ClaudeCLISession.swift`
- Test: `MaughamTests/ClaudeCLISessionTests.swift` (+ fixture script, see below)

**Interfaces — Produces:**
```swift
enum CompilerRunEvent: Equatable, Sendable {
    case started
    case resultText(String)          // the final structured message of a turn
    case failed(CompilerRunFailure)
}
enum CompilerRunFailure: Equatable, Sendable {
    case cliNotFound, disabledByToggle, timedOut, sessionDied(detail: String), unusableOutput
}
protocol CompilerRunner: AnyObject {
    @MainActor func send(message: String, systemPreamble: String?) async -> CompilerRunEvent
    @MainActor func cancelCurrentRun()
    @MainActor func shutdown()       // toggle-off / project close / quit / idle
    @MainActor var isRunning: Bool { get }
}
@MainActor final class ClaudeCLISession: CompilerRunner {
    init(model: String, mcpConfigPath: URL, cliOverride: URL?,
         isEnabled: @escaping () -> Bool,     // reads UserPreferences.mcpEnabled
         idleTimeout: TimeInterval = 600, runTimeout: TimeInterval = 120)
    static func locateCLI() -> URL?          // PATH probe, UpdateInstaller.swift:226-229 pattern
    static func writeMCPConfig(bridgeBinary: URL, socketPath: String?, to dir: URL) throws -> URL
}
```

**Consumes:** `TectonicInvoker` (`Maugham/Publish/TectonicInvoker.swift:40`) as the Process/Pipe/continuation pattern; spike note for flags: `-p --input-format stream-json --output-format stream-json --verbose --model <m> --mcp-config <file> --strict-mcp-config` + `CompilerAllowlist.cliArguments()` (Task 4). Stream events interleave `system`/`assistant`/`rate_limit_event`; key on `type == "result"`, tolerate unknown types (spike note §Consequences).

**Contracts (integration tests drive a fake CLI — a shell script fixture in the test bundle that reads stdin lines and emits canned stream-json; NO network):**
- [ ] Lazy spawn: process starts on first `send`, not on init — `test_initSpawnsNothing`.
- [ ] Two sends reuse one process — `test_secondSendReusesTheProcess` (fake script counts invocations into a temp file).
- [ ] A `result` event resolves the in-flight send with `.resultText` — `test_resultEventResolvesTheSend`.
- [ ] `isEnabled() == false` refuses BEFORE spawn with `.disabledByToggle`, and `shutdown` kills a live process — `test_toggleGovernsSpawnAndLifetime`. **The refusal is asserted at the runner, not the UI.**
- [ ] CLI absent (override pointing nowhere, probe stubbed empty) → `.cliNotFound`, no throw — `test_missingCLIFailsHonestly`.
- [ ] Process dying mid-send → `.sessionDied`, and the NEXT send spawns fresh — `test_sessionDeathSelfHeals`.
- [ ] `cancelCurrentRun` terminates the turn, leaves the session usable — `test_cancelDoesNotKillTheSession` (acceptable implementation: kill + respawn-on-next-send; the contract is the next send works).
- [ ] Run exceeding `runTimeout` → `.timedOut` — `test_runTimeout` (fixture script sleeps; use a short injected timeout).
- [ ] Unknown event types in the stream are skipped without failure — `test_unknownStreamEventsAreTolerated`.
- [ ] `writeMCPConfig` emits the spike-verified shape `{"mcpServers":{"maugham":{"command":...,"env":{"MAUGHAM_MCP_SOCKET":...}}}}` — `test_mcpConfigShapeMatchesTheSpike`.
- [ ] `./gen.sh`, run, commit. **This file will hold `Process` + async — expect real Sendable diagnostics; heed them (CLAUDE.md build-flow).**

---

### Task 6: DiagnosticIngest — validate, then store

**Files:**
- Create: `Maugham/Compiler/DiagnosticIngest.swift`
- Test: `MaughamTests/DiagnosticIngestTests.swift`

**Interfaces — Produces:**
```swift
enum DiagnosticIngest {
    struct Outcome: Equatable { let accepted: [Diagnostic]; let droppedDangling: Int; let drift: Diagnostic? }
    static func parse(resultText: String, runId: String, docId: String,
                      liveParagraphText: (String) -> String?) -> Outcome?
        // nil = unusable output (not JSON / wrong shape). Tolerates fenced JSON (```json ... ```).
}
```

**Consumes:** the schema constant `CompilerPrompt.outputSchemaDescription` (Task 3) — parser and prompt pin the SAME shape.

**Contracts:**
- [ ] Well-formed output → `Diagnostic`s with `anchorText` captured from `liveParagraphText` at ingest — `test_anchorsCaptureLiveTextAtIngest` (that's what makes later dismissal exact-match).
- [ ] A ¶id the live doc doesn't know → dropped and counted, run not failed — `test_danglingParagraphIdsAreDroppedNotFatal`.
- [ ] `intent_drift` non-null → one anchorless drift `Diagnostic` with `category == "intent"` — `test_driftBecomesAnAnchorlessDiagnostic`.
- [ ] Fenced or bare JSON both parse; prose-only or truncated output → nil — `test_unusableOutputIsNilNotCrash`.
- [ ] A paragraph the writer already changed between prompt and result: `liveParagraphText` differs from the delta's text — the note is STILL ingested with the live text as anchor (it will read as live until the next edit; uniform staleness rule, no special case) — `test_midRunEditsDoNotDropNotes`.
- [ ] `./gen.sh`, run, commit.

---

### Task 7: The run command — key, menu, flash, delivery path

**Files:**
- Modify: `Maugham/Events/MaughamEvent.swift` (new name + typed post/receive helpers, following `postDetailSegment` at `:83`), `Maugham/MaughamApp.swift` (menu item + ⌘R), `Maugham/Views/ProjectWindow.swift` (receive → orchestrate)
- Create: `Maugham/Compiler/CompilerOrchestrator.swift` (owns per-doc session + store wiring; ProjectWindow-owned `@Observable`, the `CanvasModel` ownership pattern)
- Test: `MaughamTests/CompilerRunCommandTests.swift`

**Interfaces — Produces:**
```swift
@Observable @MainActor final class CompilerOrchestrator {
    var runState: RunState            // .idle | .running(docId:) | .failed(CompilerRunFailure, at: Date)
    func runRequested(docId: String)  // the ONE entry: builds delta, prompt, sends, ingests
    func cancel()
    func shutdown()                   // forwarded on project close / quit / toggle-off
}
// MaughamEvent: static func postCompilerRun() -> posts .keyWindow-scoped; receive helper on the window
```

**Contracts:**
- [ ] **The real-delivery-path test**: the menu command posts the event, a mounted receiver fires `runRequested` — model the path from `MaughamApp`'s button through `MaughamEvent` to the orchestrator, not a direct method call (the slice-3 ⌘Z lesson). `test_theRunKeyReachesTheOrchestratorThroughTheEvent`.
- [ ] ⌘R with a run in flight for the active doc is a quiet no-op — `test_runWhileRunningIsRefusedQuietly` (state unchanged, no second send on the runner seam — use a spy `CompilerRunner`).
- [ ] An empty delta short-circuits without spawning: state flips to a "nothing new since the last run" idle variant, no `send` — `test_emptyDeltaDoesNotSpawn`.
- [ ] The run flash: reuse the `SaveFlashOverlay` mechanism (`Maugham/Views/ProjectWindow.swift:115`) with its own binding + copy ("Checking…" register, verify exact copy against the pane's vocabulary); assert the binding flips on `runRequested` — `test_theAcknowledgmentFlashFires`.
- [ ] Marker advance: after a successful ingest the store's `lastOpId` equals the delta's `newestOpId` — `test_theMarkerAdvancesOnlyOnSuccess` (a failed run must NOT advance it).
- [ ] Scope note for the implementer: the orchestrator resolves intent piece-first (`ProjectStore.statement(kind:scope:)` at `Stores/ProjectStore+Statements.swift:145`, text via `statementText(of:)` at `:79`), and passes `Document` text closures — it never hands the runner the editor binding (tripwires 3/6).
- [ ] Verify ⌘R is still unbound at implementation time (`grep -n '"r", modifiers: .command' Maugham/MaughamApp.swift` variants) — if taken since this plan, pick ⌘⇧R and record in the commit message.
- [ ] `./gen.sh`, run, commit.

---

### Task 8: DiagnosticsPane + DetailSegment.diagnostics

**Files:**
- Modify: `Maugham/Models/DetailSegment.swift:4-60` (case + `systemImageName` + `helpText`), `Maugham/Models/Persona.swift` (Author registry `:216` — diagnostics becomes Author's FIRST pane; canonical order in `PersonaPaneRegistryTests` updated), `Maugham/Views/DetailPaneToggle.swift` (`segmentContent` no-default switch, ends `:349`), `Maugham/MaughamApp.swift:218-241` (⌘⌥D View-menu binding)
- Create: `Maugham/Views/DiagnosticsPane.swift`
- Test: `MaughamTests/DiagnosticsPaneTests.swift` (+ registry/DocSync updates)

**Contracts:**
- [ ] Registry: `.diagnostics` in Author's `panes` at position 0; absent from Plan/Review/Publish (reachable everywhere by ⌘⌥D per the lens rule — the registry only sets the picker) — update `PersonaPaneRegistryTests.canonicalPaneOrder` and the matrix test.
- [ ] Pane rows read `store.live(docId:currentText:)` through the version counter — `_ = store.version` then derive, the `AnnotationsPane.swift:80-82` idiom; `test_thePaneRerendersOnVersionBump` (mount, bump, assert row count).
- [ ] Row: category tag, body, ¶ excerpt; click-to-jump posts the same navigation the annotations row uses (find its post site in `AnnotationsPane` and reuse the event, not a copy). Drift note renders pinned at top with an "Open Intent" button that posts `postDetailSegment(.intent)`.
- [ ] Header states, each a test: idle-with-last-run-line / running / failed-with-honest-copy (`cliNotFound` names setup; `disabledByToggle` names the Settings toggle) / never-run / clean-run ("Nothing to flag."). `ContentUnavailableView` chains `.frame(maxWidth: .infinity, maxHeight: .infinity)` and the outer VStack is `alignment: .top` (tripwire 15 — the grep test will catch it anyway).
- [ ] Gear menu: model picker (haiku/sonnet/opus display names "Fast/Standard/Deep"), persisted per project in ui-state via the existing `updateUIState` path — find `PersonaMemory`'s persistence and ride the same file; `test_modelChoicePersistsPerProject`.
- [ ] Cancel button visible only while running, calls `orchestrator.cancel()`.
- [ ] `DocSyncTests`' shortcut gate + guide doc row for ⌘⌥D (`docs/guide/reference.md` — Task 10 sweeps docs; add the row HERE so DocSync stays green in this task).
- [ ] Streaming: notes appear as ingested (store `replace` then incremental appends is acceptable ONLY if the final state equals the batch result; simplest honest implementation = single ingest at turn end, and the pane's "running" state carries the streamed count if cheap. **Judgment recorded: per-turn batch ingest ships; per-event streaming rows are a polish task for Plan 2 if the batch feels slow in smoke.** The spike showed full turns in seconds.)
- [ ] Release build (this task touches `ProjectWindow`'s pane registry surface): `xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO` before reporting.
- [ ] `./gen.sh`, run, commit.

---

### Task 9: Promote to task — ¶-anchored pane tasks

**Files:**
- Modify: `Maugham/OpLog/Document+Tasks.swift:247-249` (`createPaneTask` gains `paragraphId: String? = nil`), `Maugham/OpLog/TaskDeriver.swift:337,360` (pane arm reads it), `Maugham/Views/DiagnosticsPane.swift` (Promote button), `Maugham/Compiler/CompilerOrchestrator.swift` (promote path)
- Test: `MaughamTests/DiagnosticPromoteToTaskTests.swift`

**Contracts:**
- [ ] `createPaneTask(body:parentTaskId:paragraphId:undoManager:)` threads the ¶id into the `.taskCreate` op so the derived `WriterTask.anchor.paragraphId` carries it — round-trip through the REAL `TaskDeriver`, not a stub: `test_aPromotedTaskIsParagraphAnchored`.
- [ ] Existing callers compile unchanged (defaulted param); `TasksPane.swift:706` unaffected — `test_paneCreatedTasksWithoutParagraphStayDocScoped`.
- [ ] **Schema check, on the record:** adding provenance content must NOT bump `ProjectManifest.currentSchemaVersion` — verify the ¶id rides the existing `changes[0].paragraphId` op field (the annotation pattern, `Op.swift:17-30`) rather than a new provenance key if a new key would alter the wire format. If a new provenance field is unavoidable, STOP and record — the spec (§4.5) pre-authorizes shipping promote-to-task doc-scoped in that case. `test_promotedTaskOpsDecodeUnderTheCurrentSchema` — encode the op, decode with the shipped decoder, no `.unknown` fallback.
- [ ] Task body = diagnostic body + provenance line: `— compiler, <date>, <model>, checked against: "<intent first line…>"`; ¶id NOT repeated in the body (it's in the anchor) — `test_theTaskBodyCarriesProvenanceNotPlumbing`.
- [ ] Promoting removes the diagnostic from the store (it has become durable elsewhere) — `test_promoteDismissesTheNote`.
- [ ] The promote is one undo step (createPaneTask already registers its inverse; assert ⌘Z removes the task and the diagnostic does NOT resurrect — the note's removal is store-side and not undoable, record that as intended in a comment-free assertion message).
- [ ] `./gen.sh`, run both Mac suite and `cd Packages/MaughamCore && swift test` (Op codec lives there), commit.

---

### Task 10: The answer flow, drift actions, AREA.md, doc sweep

**Files:**
- Create: `Maugham/Compiler/IntentAppendPerformer.swift`, `Maugham/Compiler/AREA.md`
- Modify: `Maugham/Views/DiagnosticsPane.swift` (reply field), `docs/guide/` (Author/compiler topic — one source, HelpWindow + `get_help` serve it), `docs/roadmap.md` (M2 entry, • for the surfaces plan), `CLAUDE.md` (Compiler row in per-area table)
- Test: `MaughamTests/IntentAppendPerformerTests.swift`

**Interfaces — Produces:**
```swift
@MainActor enum IntentAppendPerformer {
    static func append(answer: String, forDocId: String, store: ProjectStore) async throws
    // resolves the PIECE statement (mint if absent), appends the writer's words
    // as a new paragraph through the op log; PromotionPerformer's shape:
    // validate-first, flush autosave, never append to an unreadable file
}
```

**Consumes:** `ProjectStore.statement(kind:scope:)` (`ProjectStore+Statements.swift:145`), `lockStatementOpen(_:)` (`:124`), `statementText(of:)` (`:79`); `PromotionPerformer.swift` as the outside-writer pattern — including tripwire 32's lesson: this performer writes from OUTSIDE any canvas/editor gesture; it touches statements, not the canvas, so no bracket verb applies, but read the census test to confirm the boundary before assuming.

**Contracts:**
- [ ] Answer to a ¶-anchored note appends exactly one paragraph to the PIECE intent statement, op-logged (assert a new op exists whose `next` is the answer text) — `test_theAnswerBecomesAnIntentParagraph`.
- [ ] No statement yet → minted, manifest-registered, answer is its first paragraph — `test_answerMintsTheStatement`.
- [ ] The answered diagnostic dismisses — `test_answeringDismissesTheNote`.
- [ ] The append never routes to the PROJECT statement when the doc is piece-scoped — `test_scopeIsThePieceNeverTheProject`.
- [ ] **Planted offender:** a test proving Claude has NO write path to statements — assert the allowlist (Task 4) contains no statement-writing tool AND `MCPToolCatalog.all` contains none either; the offender variant adds a hypothetical name to the allowlist and the census fails — extend Task 4's census file, don't duplicate it.
- [ ] Unreadable/undecodable statement file → typed refusal, nothing written (must #1 on an append path) — `test_unreadableDestinationRefuses`.
- [ ] AREA.md: the seam map (runner/orchestrator/store/ingest), the lifetime rules, the fallback (`--resume`), tripwire pointers (17/24 sidecar, 3/6 arrival, allowlist census). Doc sweep: guide topic describes what SHIPS (loop only — no strip/references yet); roadmap M2 entry added with the surfaces plan marked open; CLAUDE.md area row added.
- [ ] `./gen.sh`, full Mac suite (with the MCP skip), MaughamCore `swift test`, commit.

---

## Self-review notes (run at write time)

- Spec §3.1–§3.5, §4.1–§4.5, §5.1–§5.2, §8, §10 loop half, §12 → Tasks 1–10 cover them; §6 (strip/references/posture-finding), §7 (pinned union/projection widening), §9 (the two ADRs) and the MCP-context wiring of pinned listings into real ids are **Plan 2**, derived after this builds. `CompilerContext.pinnedListing` ships EMPTY-capable in Plan 1 (the prompt builder takes whatever it's given; Plan 1 wires links only via `item.links` if trivially reachable at Task 7, else empty with a recorded TODO in the roadmap entry — not a silent cap: the guide topic says intent+delta is the context until the surfaces land).
- Type names cross-checked: `CompilerDelta` (2→3→7), `CompilerRunEvent`/`CompilerRunner` (5→7), `Diagnostic`/`DiagnosticsStore` (1→6→8→9→10), schema constant (3→6).
- Every task ends in its own commit; models per Global Constraints.
