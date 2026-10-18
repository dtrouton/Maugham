# #44: a canvas over a refused sidecar is read-only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When this build opens a canvas whose layout file (`.maugham/canvas.json`) it refuses, nothing writes over it: not the writer, not Claude, not an Inbox drag, and not a single click. The canvas says why, and offers a way out where one exists.

**Architecture:** There is one fact: the store's load answers *refused*, with a reason (newer or damaged). The model holds it from `attach`. The store refuses every write once its load came back refused (the backstop). The doors refuse loudly before any copy, and the surfaces hide or disable every edit affordance. **Read `docs/superpowers/notes/2026-10-18-issue-44-research.md` first.** Its sections (What `.refused` covers, Write paths, Gate design, MCP and Inbox, Banner, Tests) are the spec for each task's file:line details; this plan carries only the decisions.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest.

**Spec:** issue #44, plus Denver's rulings (2026-10-18) recorded on it and below.

## Rulings

- **Denver:** read-only plus a banner. Nobody writes over a refused sidecar.
- **Denver: newer-version sentence** (verbatim): *"This canvas was saved by a newer version of Maugham, so only its words are shown. Update Maugham to see and edit your layout."*
- **Denver: damaged file:** offer **Start a Fresh Layout**. It sets the damaged file aside (kept, never deleted) and the canvas becomes editable with the writer's words laid out again. Damaged sentence (controller): *"This canvas's layout file is damaged, so only its words are shown. Start a Fresh Layout sets the damaged file aside and lays your words out again."*
- **Controller: Promote… is off** on a read-only canvas. Promoting writes a mark, and the artifact would be made before the mark is refused.
- **Controller:** no `Posture` involvement (tripwire 51). The precedent is `ProjectWindow.shareIsReadOnly`, an OS/file lock beside the posture.
- **Controller:** a sidecar that exists but can't be READ (reported `.absent` today) is out of scope. File a follow-up issue in Task 6.

## Global Constraints

- **Coordination with the "oplog" session:** keep edits to `Maugham/Canvas/AREA.md` as small appended or replaced paragraphs, never a rewrite. Keep `TripwireGrepTests.swift` additions self-contained. Do NOT change how `liveCanvas`/`liveModel(of:)` is set or discovered; only ask the model it returns.
- Tripwire 32: no new `mutate`/inside-verb spelling in the outside files. Reading `model.isReadOnly`/`sidecarRefusal` is fine. Count the census array, never prose.
- Tripwire 27/28: the scrap editor stays frontmost when mounted. On a read-only canvas it never mounts for editing.
- Tripwire 33: no synthesised clicks, and no press-then-wait tests. Pin decisions windowlessly.
- `CanvasView.swift` has source-layout contracts in its header (AREA "Writing tests"). Read them before editing, and mount the banner outside `CanvasView`'s ZStack (`CanvasCompositionTests`).
- Tests build fixtures under `TestTemp.root` only. A refused sidecar is made by writing `{"schemaVersion": 999}` (newer) or `not json` (damaged).
- `./gen.sh` after adding a file. Iterate with `./scripts/test.sh`, and run `./scripts/test.sh full` before the PR. Never `pgrep -f xcodebuild`. If Core fails with only a `started.` line, another session's build killed it, so re-run.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage by path.

## Review Focus

1. **One click on a refused canvas writes nothing**, including the 750 ms debounced save, the quit flush, and `detach`. Both files are byte-identical after any interaction.
2. **A refused drop never strands a copy** in `canvas_assets/` (an external picture, or an Inbox capture).
3. **Claude gets the same error on both routes** (live and sidecar), and `list_canvas` tells Claude the layout isn't readable.
4. **Start a Fresh Layout** keeps the damaged file (renamed aside), and the canvas becomes editable in the same session without a reopen. It is never offered for a newer-version file.
5. **Pan, zoom, selection and the inspectors' displayed values still work**: read-only is not frozen.

---

### Task 1: The store knows why it refused, and refuses to write
Research: *What `.refused` covers*, *Gate design* layer 2. `CanvasStore.load()` tells a newer schema (probe `schemaVersion` first; `> current` means newer) from a damaged file. Carry the reason as `SidecarRefused.reason` (`.newerVersion`/`.damaged`); `errorDescription` is the matching Ruling sentence. One home answers *refused?* for both routes (`Loaded.refusal: SidecarRefused?`, used by `loadForTransientWrite` too). Once its load answered refused, the store's `scheduleSave`/`save`/`flush`/`saveSceneOnly` write nothing (`hasPendingWrite` stays false).
- Tests: the newer and damaged reasons; a newer file that also fails the full decode is still newer. After a refused load, every write verb leaves both files byte-identical. A writable load still writes.
- Commit: `fix(canvas): the store says why it refused a layout file and writes nothing over it (#44)`

### Task 2: The model holds the refusal; its verbs don't mutate
Research: *Gate design* layer 1. `CanvasModel.sidecarRefusal: CanvasStore.SidecarRefused?` is observable and set on every `attach`, with `isReadOnly`. When read-only, `mutate`, `mutateFromInspector`, `setScrapText` and `removeScrapText` return without changing memory. `withScene(persist: false)` still works (re-measures).
- Tests: attach over each refused kind sets the fact; attach over a writable file clears it; each verb is a no-op when read-only; `withScene(persist:false)` still applies.
- Commit: `fix(canvas): a model attached over a refused layout holds the refusal and its verbs change nothing (#44)`

### Task 3: Claude and the Inbox are refused at the door, on both routes
Research: *MCP and Inbox*, *Gate design* layer 3 (first bullet). Add one helper beside `CanvasClaudeWrite.liveModel(of:)` answering the refusal for a project, live or not (keep `liveModel` spelled once, per `CanvasLiveSeamTests`). `CanvasClaudeWrite.apply`'s live arm, `CanvasCapture.send`'s live arm and `refuseUnlessWritable` all throw it before `mutateFromInspector`, and before any asset copy. `refuseUnlessWritable` stops returning early for a live model. Correct `add_canvas_scraps`'s hint and the marker comment. `list_canvas` gains `layout_readable` (false when refused) and the reason's sentence, on both routes.
- Tests: Claude's live route throws the same error as the sidecar route; Inbox send with a live read-only model leaves the row `.new` and copies nothing; `list_canvas` reports `layout_readable: false` with the sentence. Run `MCPProtocolHandlersTests` (catalogue-shape tests) in the gate.
- Commit: `fix(canvas): Claude and the Inbox are refused before they touch a read-only canvas (#44)`

### Task 4: The canvas and its inspectors offer no edits
Research: *Gate design* layer 3 (view, inspectors, Promote). In `CanvasView`, when read-only:
- a double-click acts as a single click;
- a drag begins no interaction (pan and zoom are unaffected);
- `deleteSelection` returns false;
- research and capture drops return false;
- an external drop returns false before `CanvasExternalDrop.ingest`.

Inspector value fields are `.disabled`, and verb buttons (Delete, Cite, Remove from Region, Promote…) are hidden. `ItemInspector`'s Promote… is hidden. `CanvasPromotionModifier.isPromotable` includes the fact, and `PromotionPerformer` checks before creating an artifact. Put each view decision behind a pure predicate the tests can ask.
- Tests: windowless, on the predicates and on `PromotionPerformer` (no artifact made). No clicks (tripwire 33).
- Commit: `fix(canvas): a read-only canvas offers no edits, and Promote is off (#44)`

### Task 5: The banner, and Start a Fresh Layout
Research: *Banner*. Add `CanvasReadOnlyNotice` in `ProjectWindow.canvasCentre` via `.safeAreaInset(edge: .top)`, styled like `ViewOnlyShareNotice`. It has `static` sentences (production words the tests ask for), shows the reason's Ruling sentence, stays visible under ⌘\, and carries an accessibility label. For `.damaged` it also shows a **Start a Fresh Layout** button calling one verb, e.g. `CanvasModel.startFreshLayout()` or a store verb it calls. The verb:
- moves `.maugham/canvas.json` aside to `.maugham/canvas.damaged-<yyyyMMdd-HHmmss>.json`, never deleting it, and never overwriting an existing aside file;
- re-attaches, so the model is writable and the orphan row becomes the layout;
- saves once.

It is refused for `.newerVersion`. Check `TrashStore`/the typed mover rules (tripwire 14 covers user-editable content; `.maugham/` sidecars are derived) and state which applies in the commit.
- Tests: the sentence per reason; the verb keeps the damaged bytes under the aside name, leaves the model writable with every scrap's words present, and refuses for newer; the banner predicate is windowless.
- Commit: `feat(canvas): a read-only canvas says why, and a damaged layout can be set aside (#44)`

### Task 6: Docs and the follow-up
- `Maugham/Canvas/AREA.md`: replace the "the writer's own edit still writes" / "replaced only by an edit" position with the read-only account (small replaced paragraph). The single-click finding goes in its history line.
- Update the canvas topic in `docs/guide/` (find it) with one short paragraph on the notice and the button. Help describes what ships.
- CLAUDE.md's Canvas row needs no edit unless it states the old position (check; the oplog session is slimming CLAUDE.md, so change at most one phrase).
- File the follow-up issue: an unreadable-but-present sidecar is reported `.absent` and written over (research *What `.refused` covers*, adjacent hazard). Label it `audit`.
- Commit: `docs(canvas): a refused layout is read-only (#44)`

### Finish
- [ ] `./scripts/test.sh full`, green.
- [ ] Whole-branch review (opus), told not to build.
- [ ] Message the oplog session before merging.
- [ ] PR closing #44, with Denver's smoke. Make a canvas, quit, set `.maugham/canvas.json`'s `schemaVersion` to 999, reopen Plan, and check that the notice shows and clicks change nothing. Then replace the file with `not json`, reopen, press Start a Fresh Layout, and check that the words come back editable and the damaged file is kept beside it.
