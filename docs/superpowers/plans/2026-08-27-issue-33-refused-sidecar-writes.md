# Issue #33 — transient canvas write arms must not save over a refused sidecar

**Issue:** https://github.com/dtrouton/Maugham/issues/33
**Spec authority:** the issue text, `Maugham/Canvas/AREA.md` (Persistence section, the `SidecarState` paragraph), and ADR 0026. Constitution must #1 (*the words are safe*) extends here to *the arrangement is safe*: a layout this build cannot read is not this build's to destroy.
**Branch:** `worktree-issue-33-refused-sidecar-writes`, off main `358bf714`.

## The defect, re-verified 2026-08-27

`CanvasStore.load()` reports `Loaded.sidecar: SidecarState` (`.decoded` / `.absent` / `.refused`). `CanvasModel.attach` reads it (`CanvasModel.swift:339`) and withholds the load-time repair save on `.refused`. Nothing else reads it. Three transient write arms — a `load()` followed by a `save()`/`saveSceneOnly()` with no live model — ignore it, so on a refused sidecar (damaged bytes, or `schemaVersion` above `CanvasSceneDTO.currentSchemaVersion`) they treat the empty scene as the real one, land one node on it, and write a current-schema file over the writer's whole arrangement:

| arm | file | today |
|---|---|---|
| `CanvasCapture.send` sidecar arm (Send to Canvas, Plan closed) | `Maugham/Canvas/CanvasCapture.swift:254-264` | **destroys the layout** |
| `CanvasClaudeWrite.apply` sidecar arm (`add_canvas_scraps`, no live model) | `Maugham/Canvas/CanvasClaudeWrite.swift:119-132` | **destroys the layout** |
| `ProjectStore.repointCanvasMarks` (craft-intent adoption, runs inside `ProjectStore.load`) | `Maugham/Stores/ProjectStore+StatementAdoption.swift:292-303` | safe **by accident** — an empty scene repoints 0 marks and `guard moved > 0` returns first |

A fourth interaction the issue did not know: `InboxStore.sendToCanvas`'s `.image` arm (`Maugham/Stores/InboxStore.swift:486-506`) asks `CanvasCapture.existingNode` (which answers "not here" on a refused sidecar) and then **ingests a copy into `canvas_assets/` before `send` runs**. A refusal placed only inside `send` would strand that copy in the well on every attempt.

## Global constraints

1. **The rule has ONE home.** `SidecarState` decides whether a write may happen; call sites consult it and never re-spell `!= .refused`. A sibling predicate for the transient case is allowed (its rationale differs from the repair's); both must delegate to one private rule.
2. **Refuse before mutating, and refuse before the copy.** No arm may load, mutate, and then discover it must not save. In `sendToCanvas`, the refusal precedes `ingestCanvasAsset` and precedes the status flip; the entry stays `.new`.
3. **Refuse loudly, in the caller's own vocabulary.** Send to Canvas surfaces through the existing `promoteError` alert (`InboxPane.swift:401-415`, "Couldn't promote"); `add_canvas_scraps` returns an `MCPError.toolError` payload with a machine code, a sentence, a hint and `fields` naming the project. No silent no-ops.
4. **The file is byte-identical before and after a refused attempt.** Every refusal test asserts `Data(contentsOf: sidecarURL)` unchanged (the #28 idiom, `CanvasModelTests`), never merely a scene comparison.
5. **Every refusal test has a control**: the same operation against an `.absent` sidecar still writes. Without the control, the refusal is not falsifiable.
6. **The live-model arms are unchanged.** With the Plan persona open, both writes go through `CanvasModel` and are the writer's own act from this build. (Out of scope, recorded as a follow-up at close: a *Claude* write through a live model attached over a refused sidecar also flushes over it; `CanvasModel` does not retain `SidecarState` past `attach`, and widening that is a different change.)
7. Paragraph/node ids in tests use 4-char literals from `[0-9a-hjkmnp-tv-z]` (tripwire 8). No hardcoded `"maugham"` strings (tripwire 13). No bare `ParagraphID.mint()` (tripwire 23).
8. Run `./scripts/test.sh` after each task; name the covering test classes in the report. The full gate runs once before merge.
9. CLAUDE.md rule 10: any doc sentence a task falsifies is corrected in that task's commit, not deferred to Task 4. Task 4 is the sweep for what the code tasks did not already touch.

## Task 1 — the predicate and the error (`CanvasStore`)

**Files:** `Maugham/Canvas/CanvasStore.swift`; tests in `MaughamTests/Canvas/CanvasStoreTests.swift`.

1. In `SidecarState`, add a sibling to `acceptsARepairWrite`:
   ```swift
   /// Whether a write made with NO canvas open — Send to Canvas with the Plan
   /// persona closed, `add_canvas_scraps` with no live model, craft-intent
   /// adoption re-pointing marks — may be written back.
   ///
   /// The same answer as the repair's, for a different reason. A repair is
   /// withheld because nobody asked for it; a transient write is REFUSED
   /// because somebody did, and has to be told: an inbox entry must not flip
   /// to promoted for a card that landed in a file about to be discarded, and
   /// a tool call must fail rather than report success (issue #33).
   var acceptsATransientWrite: Bool { isWritable }
   ```
   and refactor `acceptsARepairWrite` to read the same private `isWritable` (`self != .refused`). One rule, two named readers. Keep `acceptsARepairWrite`'s existing comment; it is still true.
2. Add, nested in `CanvasStore`:
   ```swift
   /// The sidecar is there and this build cannot read it — a newer build's
   /// schema, or damaged bytes — so a write made with no canvas open is
   /// refused rather than allowed to replace somebody's whole arrangement.
   struct SidecarRefused: Error, LocalizedError, Equatable {
       /// The project's folder name, for the sentence.
       let projectName: String
       var errorDescription: String? {
           "The canvas layout in “\(projectName)” was saved by a newer version of Maugham, or is damaged, and this version won't overwrite it. Update Maugham to add to this canvas."
       }
   }
   ```
   and a convenience on `CanvasStore`:
   ```swift
   /// The one place a transient write asks permission. Loads, and throws
   /// `SidecarRefused` when the sidecar is present and unreadable.
   func loadForTransientWrite() throws -> Loaded {
       let loaded = load()
       guard loaded.sidecar.acceptsATransientWrite else {
           throw SidecarRefused(projectName: projectRoot.lastPathComponent)
       }
       return loaded
   }
   ```
   (`projectRoot` is the store's existing stored URL — check the property's actual name and use it.)
3. Tests, in `CanvasStoreTests`, mirroring `test_loadSaysWhetherAnEmptySceneMeansNothingOrSomethingItCannotRead` (`:57-75`):
   - `test_theTransientPredicateAgreesWithTheRepairPredicateOnEveryCase` — iterate `.decoded`, `.absent`, `.refused`; assert `acceptsATransientWrite == acceptsARepairWrite` for each and that only `.refused` is false.
   - `test_loadForTransientWriteThrowsOnANewerSchemaAndOnDamagedBytes` — seed `{"schemaVersion":999,"nodes":[]}` → `XCTAssertThrowsError`, with the error cast to `CanvasStore.SidecarRefused` and `projectName == root.lastPathComponent`; then seed `not json at all` → same.
   - `test_loadForTransientWriteReturnsTheSceneWhenTheSidecarIsAbsentOrDecoded` — the control: no file → returns `.absent` without throwing; a current-schema file with one node → returns it with `.decoded`.

**Commit:** `feat(canvas): SidecarState says whether a transient write may happen, and CanvasStore can refuse one (#33)`

## Task 2 — Send to Canvas refuses, before the copy and before the flip

**Files:** `Maugham/Canvas/CanvasCapture.swift`, `Maugham/Stores/InboxStore.swift`, `Maugham/Stores/ProjectStore+StatementAdoption.swift`; tests in `MaughamTests/Stores/InboxToCanvasTests.swift` (fixture at `:36-90`; mirror `test_theCommandWritesTheSidecarWhenNoCanvasIsOpen` at `:503`).

1. `CanvasCapture.send` becomes `throws` (`@discardableResult static func send(...) throws -> CanvasNodeID`). In the sidecar arm replace `let loaded = sidecar.load()` with `let loaded = try sidecar.loadForTransientWrite()`. The live-model arm is untouched. Its one production caller is `InboxStore.sendToCanvas:508` — add `try`. Update `send`'s doc comment with one sentence: it throws `CanvasStore.SidecarRefused` on the sidecar route when the file is present and unreadable (issue #33).
2. Add to `CanvasCapture`:
   ```swift
   /// Asked by `InboxStore.sendToCanvas` BEFORE it copies a picture into the
   /// well: a refusal that only `send` could raise would strand that copy in
   /// `canvas_assets/` on every attempt (issue #33). With a canvas open there is
   /// nothing to ask — the live model is the writer's own act from this build.
   static func refuseUnlessWritable(store: ProjectStore, projectRoot: URL) throws {
       guard liveModel(of: store) == nil else { return }
       _ = try CanvasStore(projectRoot: projectRoot).loadForTransientWrite()
   }
   ```
   and call it in `InboxStore.sendToCanvas` as the first statement of the function body, before the `switch`. (A second `load()` on the sidecar route is accepted: `existingNode` already loads once more on the image arm, and the file is small.)
3. `ProjectStore.repointCanvasMarks`: replace `var scene = canvas.load().scene` with a `guard let loaded = try? canvas.loadForTransientWrite() else { return }` / `var scene = loaded.scene` — it is documented "never throws and never blocks the adoption", so a refusal is a silent return here (the adoption must still land; marks on a layout this build cannot read stay as they were, which is "exactly today's behaviour" per its own comment). Add one sentence to that doc comment saying so and naming #33. No test can observe this arm's outcome (an empty scene repoints nothing either way) — say so in the report; the guard exists so the safety is typed rather than accidental.
4. Tests in `InboxToCanvasTests`, each seeding a refused sidecar the way `CanvasModelTests.seedUnreadableSidecar` does (write `{"schemaVersion":999,"nodes":[{"id":"futr","kind":"scrap","x":10,"y":10,"width":240,"z":3}]}` to `.maugham/canvas.json`, and a `canvas.md` with `ScrapText.banner` + `## futr` + words) with **no** live canvas:
   - `test_aTextCaptureIsRefusedWhenTheSidecarIsUnreadable_andTheFileIsUntouched` — `sendToCanvas` throws `CanvasStore.SidecarRefused`; `Data(contentsOf: sidecarURL)` equals the bytes seeded; the entry's status is still `.new` (read it back through the inbox store).
   - `test_aPhotographIsRefusedBeforeItIsCopiedIntoTheWell` — `.image` entry via `seedImageAsset`; `sendToCanvas` throws; the `canvas_assets/` directory does not exist (or is empty if it pre-exists); the inbox original is still at its path; the sidecar bytes are unchanged; status still `.new`.
   - `test_aDamagedSidecarRefusesTheSameWay` — `not json at all`, text entry, same three assertions as the first.
   - `test_theCommandStillWritesWhenThereIsNoSidecarToLose` — the control: no `canvas.json` at all, text entry → returns a node id, the sidecar now exists and decodes with that node, status `.promoted`. (If `test_theCommandWritesTheSidecarWhenNoCanvasIsOpen` already asserts exactly this, extend it with the status assertion and name it as the control in a comment instead of duplicating.)
5. `Maugham/Stores/AREA.md` "Inbox → canvas seam" section (~`:236-242`): where the refusals are enumerated (`nothingToPromote`, `assetMissing`), add `CanvasStore.SidecarRefused` — raised before the copy and before the flip, only on the sidecar route (#33).

**Commit:** `fix(inbox): Send to Canvas refuses a sidecar this build cannot read — before the copy, before the flip (#33)`

## Task 3 — `add_canvas_scraps` refuses with a named error

**Files:** `Maugham/Canvas/CanvasClaudeWrite.swift`, `Maugham/MCP/Tools/CanvasTools.swift`; tests in `MaughamTests/Canvas/CanvasClaudeWriteTests.swift` (fixture `:33-70`, mirror `test_aClosedCanvasIsWrittenToTheSidecar` at `:155`) and `MaughamTests/MCP/Tools/CanvasToolsTests.swift` (find its `add_canvas_scraps` refusal tests — the `no_scraps`/`blank_scrap` ones — and mirror their shape for the payload assertions).

1. `CanvasClaudeWrite.apply` is already `throws`. In the sidecar arm replace `let loaded = sidecar.load()` (~`:120`) with `let loaded = try sidecar.loadForTransientWrite()`, before any mutation. Amend the doc comment at `:76-80`: "Nothing throws today" is now false — it throws `CanvasStore.SidecarRefused` on the sidecar route (#33).
2. In `AddCanvasScrapsTool.handle`, wrap the `try CanvasClaudeWrite.apply(...)` call (`:513`) so a `CanvasStore.SidecarRefused` becomes:
   ```swift
   throw MCPError.toolError(payload: .init(
       error: "canvas_sidecar_unreadable",
       message: refused.errorDescription ?? "The canvas layout can't be read by this version of Maugham.",
       hint: "Update Maugham on this Mac before adding to this canvas. list_canvas shows only what this version can read, so the empty scene it reported is not the writer's real layout.",
       fields: ["project": .string(refused.projectName)]))
   ```
   Any other error propagates as before. Move or rewrite the `// ---- Nothing above can fail from here on. ----` marker at `:500` — it is false once the write can refuse; the honest marker is that validation is complete and the one remaining refusal is the sidecar's.
3. Tests:
   - `CanvasClaudeWriteTests.test_aClosedCanvasWithAnUnreadableSidecarRefusesTheWrite` — seed the newer-schema sidecar + `canvas.md` as in Task 2, `store.liveCanvas == nil`, `XCTAssertThrowsError(try CanvasClaudeWrite.apply(...))` cast to `SidecarRefused`; sidecar bytes unchanged; `canvas.md` bytes unchanged.
   - `CanvasClaudeWriteTests.test_aDamagedSidecarRefusesTheWriteToo` — `not json at all`, same assertions.
   - The existing `test_aClosedCanvasIsWrittenToTheSidecar` is the control; add a one-line comment naming it so.
   - `CanvasToolsTests.test_addCanvasScrapsRefusesAnUnreadableSidecarWithANamedError` — through the tool: the result is an `isError` tool result whose payload has `error == "canvas_sidecar_unreadable"`, a `project` field equal to the project folder name, and a non-empty hint; the sidecar bytes are unchanged; no `maughamCanvasNodesAdded` event was posted (assert however the sibling tests observe posts — if none does, skip that assertion and say so).
4. `Maugham/Canvas/AREA.md:848` refusal list: add `canvas_sidecar_unreadable`, and reword the lead sentence — the four validation refusals happen before anything is written; the sidecar refusal is the write's own, raised before any mutation on the sidecar route only. `Maugham/MCP/AREA.md:84` (`add_canvas_scraps` entry): one clause naming the new refusal.

**Commit:** `fix(mcp): add_canvas_scraps refuses a sidecar this build cannot read, and says so (#33)`

## Task 4 — the doc sweep

**Files:** `Maugham/Canvas/AREA.md`, `docs/guide/research.md` or `docs/guide/getting-started.md` (whichever holds the Send to Canvas sentence you judge the right home), `docs/roadmap.md` if it carries a #28/#33 line.

1. `Maugham/Canvas/AREA.md:690`, the sentence "A refused sidecar is surfaced in memory and **not written back** (`SidecarState.acceptsARepairWrite`, read at the end of `CanvasModel.attach`); the file survives being looked at, and is replaced only by an edit the writer actually makes from this build." Rewrite so it is true after Tasks 1–3: name both predicates, name the three transient arms that now consult `acceptsATransientWrite` through `loadForTransientWrite`, and state the two loud refusals (the inbox alert, the tool's `canvas_sidecar_unreadable`). Keep "Absent keeps the save … the control" — still true. Note the recorded exclusion from Global Constraint 6 in one clause.
2. Guide: one **"Failing-loudly:"** sentence in the house style of `docs/guide/publishing.md:43`, beside the Send to Canvas instruction (`docs/guide/getting-started.md:148` or `docs/guide/research.md:28`): a project whose canvas was last saved by a newer Maugham refuses the send and says so; update Maugham.
3. Grep the tree for any other sentence claiming a refused sidecar is never written or that `add_canvas_scraps`' refusals are all pre-write (`grep -rn "acceptsARepairWrite\|refused sidecar\|before anything is written" Maugham docs register`) and correct what Tasks 2–3 did not already. Report what the grep found and what you changed.
4. No test changes expected; `DocSyncTests` may pin something — run `./scripts/test.sh` anyway.

**Commit:** `docs(canvas): the refused sidecar is refused by every write with no canvas open (#33)`
