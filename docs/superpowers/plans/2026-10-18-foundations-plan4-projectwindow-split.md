# Foundations Plan 4: Splitting ProjectWindow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Break the 5,526-line `ProjectWindow.swift` (one struct with about 89 `@State`) into pieces an agent can read and change on their own. The pieces are:
- the free-standing types, each in its own file;
- a publish-centre model;
- one route type for the centre column;
- `CentreColumn` and `RightColumn` child views that own their own state;
- small state structs.

Each piece is a type, not an extension file. An extension of `ProjectWindow` still shares all of its state, so it would not shrink what an agent must load.

**Architecture:** Every step is a MOVE with identical behaviour.
- Plan 2 made every census and source test find code by type and symbol, so a move breaks no guardrail.
- Plan 3 took the services and stores out of the window into `ProjectSession`.

What stays in `ProjectWindow`:
- the persona, column and subject `@State`, which modifiers bind to;
- the `.task` and `onDisappear` wiring;
- the body's modifier chain.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest.

**Spec:** `docs/superpowers/notes/2026-10-17-foundations-audit.md` §3 A1 and A2, and reviewer A's recommendations 2, 4 and 8 (summarised in the note's §3/§4). This is plan 4 of §4.

## Global Constraints

- **No behaviour change.** Same views, same identities, same layout.
- **SwiftUI identity is load-bearing.** Moving a builder into a child view must keep the same structural position:
  - `EditorHost` must stay mounted under every centre overlay. `manuscriptEditor`'s `ZStack` keeps `EditorHost` first (tripwire 6). `ProjectAltitudeCentreTests` counts host lifetimes.
  - The canvas is ONE mount, and no new view reads `canvasModel.scene` (tripwire 30).
  - The mounted canvas editor stays frontmost (tripwire 27).
  - A document reload stays keyed on the path (tripwire 22).
- **No two-way flag-guarded sync** (tripwire 2). A child view receives bindings to the window's `@State`, never copies of it. Persona, column and subject state stays in `ProjectWindow`. Do not move it into an `@Observable` model whose `didSet` could re-enter.
- **Release type-check budget.** After EVERY task, run a Release build:
  - `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`;
  - run it from a script file, only when `pgrep -x xcodebuild` is empty.
- **Censuses stay as strong as before.** Plan 2's `SourceTree` lookups are type-keyed. If a moved symbol leaves `type:ProjectWindow` for a new type, retarget the census to name the new type and keep its planted control.
- **Comments are contract, not history.** When moving a block, shrink history-narrating doc comments ("Task N", "stage 3b", "used to", dates) to the contract plus a pointer to the ADR or note they cite. Keep every sentence that states a rule, and every test citation.
- **Do not edit `CLAUDE.md`, `docs/tripwires.md` or any `AREA.md`.** Plan 1 is rewriting them; the docs are swept at merge.
- **Gates:** `./scripts/test.sh` (fast) after each task; `./scripts/test.sh full` before the final review (it runs the `CanvasViewMounting*` family). Use `./scripts/test.sh only <Class…>` for focused runs. Never use raw `xcodebuild test`. Never `git push`.
- **Branch** `claude/foundations-plan4-projectwindow-split`, off plan 3's head 829fa49f. Worktree `/Users/denver/src/Maugham-plan4`.

## Review Focus

1. **A child view that re-creates `EditorHost` or the canvas on a subject or persona change.** The writer loses the cursor or undo, or the canvas resets its camera. *Pinned by:* `ProjectAltitudeCentreTests`' host-lifetime counts and the canvas mount tests, run in the full gate. Each task's report states the identity argument.
2. **A binding turned into a copy,** so a change in the child never reaches the window or the reverse. *Pinned by:* reviewers diffing every moved `@State` and binding. The persona, column and subject state never moves.
3. **A Release-only type-check failure.** *Pinned by:* a Release build after every task.
4. **A census that went vacuous after a symbol moved type.** *Pinned by:* plan 2's loud-scope and type-key failures, plus each retargeted census's control.
5. **A centre surface lost or shadowed** when the `ZStack` layers become one route. *Pinned by:* Task 3's exhaustive route switch and its pure-function tests over every persona × subject combination.

---

### Task 1: Free-standing types move to their own files

**Files:** create one file per type, or per tight family, under `Maugham/Views/`:
- `ProjectActiveSheet.swift`
- `CheckpointModifier.swift` (with `CheckpointFlashDecision`)
- `RewindModifier.swift`
- `FocusPostureModifier.swift`
- `CanvasCollapseModifier.swift`
- `ContainerWidthReporter.swift`
- `PersonaModifier.swift`
- `ParagraphNavModifier.swift`
- `EditorControlMirror.swift` (with `EditorControlMirrorModifier`)
- `TranslationReviewModifier.swift`
- `CanvasPromotionModifier.swift`
- `CompilerFlashSink.swift`
- `NoteOutcomeAlert.swift`

Modify `Maugham/Views/ProjectWindow.swift` to remove the moved code.

**Contract:**
- Move each type out of `ProjectWindow.swift` (today about lines 18-28 and 4213-5526) byte for byte, apart from visibility.
- `private struct` becomes internal only where another file needs it; keep `private`/`fileprivate` where the type is used in one file only.
- The nested modifiers inside the struct (`TopChromeModifier`, `PaletteWallModifier`, `SessionAndNavigationModifier`, `CollectionPieceModifier`) stay nested in this task.
- Delete the dead `@State private var showingBootstrapNotice` (audit A: declared, never read). Grep to confirm first.
- Run `./gen.sh`. These are new files.
- Retarget censuses as needed:
  - `RunMenuTitlesTests` expects `struct PersonaModifier` in a file.
  - Plan 3 retyped `restoreToOpUndoable(` to `type:RewindModifier`.
  - Plan 2 retyped persona decision sites to `type:PersonaModifier`.

  These follow the type automatically. Check that each still passes, and that a planted control still fires.

- [ ] **Step 1:** Move the types, then `./gen.sh`.
- [ ] **Step 2:** `./scripts/test.sh` must be green, with no census edits needed. If one is needed, the move broke a file-name assumption plan 2 missed: fix the census to key by type, and record it.
- [ ] **Step 3:** Release build.
- [ ] **Step 4:** Commit: `refactor(views): ProjectWindow's free-standing modifiers and decisions live in their own files`

---

### Task 2: `PublishCentreModel` — the publish centre's four `@State` become one model

**Files:**
- Create `Maugham/Views/Publish/PublishCentreModel.swift`
- Create `MaughamTests/PublishCentreModelTests.swift`
- Modify `ProjectWindow.swift`
- Modify `PublishPreviewModifier`, wherever it lives

**Contract:**

```swift
@MainActor @Observable
final class PublishCentreModel {
    var preview: PublishPreview?            // today's `publishPreview` @State — use its real type
    var selectedPublicationID: …?           // `publishSelectedPublicationID`
    private(set) var selectedProposal: …?   // `publishSelectedProposal`
    private(set) var selectedRound: …?      // `publishSelectedRound`
    func show(proposal:) { selectedProposal = proposal; selectedRound = nil }   // the two clear each other (today: ProjectWindow ~:3225-3232)
    func show(round:)    { selectedRound = round; selectedProposal = nil }
    func clearProposal() / clearRound()     // the existing dismiss paths
    func publishSelection(after compiled: …)  // the existing "a new compile resets the picker" rule — move it, don't rewrite it
}
```

Read the four `@State` declarations and every write to them before writing this. Each write site maps to exactly one model method or property.

`ProjectWindow` holds `@State private var publishCentre = PublishCentreModel()`. `publishCentre(...)`, the static decision, reads the model's values.

- [ ] **Step 1: Tests first.**
  - (a) `show(proposal:)` clears the round, and the reverse.
  - (b) `publishSelection(after:)` behaves exactly as the window's old inline rule did. Pin the old rule's cases from its existing tests in `PublishPreviewCentreTests`.
- [ ] **Step 2:** Implement and adopt. Run the fast gate and a Release build.
- [ ] **Step 3:** Commit: `refactor(views): the publish centre's selection is one model whose proposal and round clear each other`

---

### Task 3: `CentreRoute` — one exhaustive answer for what the centre shows

**Files:**
- Create `Maugham/Views/CentreRoute.swift`
- Create `MaughamTests/CentreRouteTests.swift`
- Modify `ProjectWindow.swift` (`editorPane` about :2008, `manuscriptEditor` about :2102)

**Today:** two mechanisms decide the centre, and neither checks it covers every case.
- An if/else chain in `editorPane`: palette wall → research → canvas → reference → editor.
- Independent `if` layers in `manuscriptEditor`'s `ZStack`: altitude, review board, then the `publishCentre` switch with 4 arms.

Which surface wins comes from ZStack order plus implication tests.

**Contract:**

```swift
enum CentreRoute: Equatable {
    case paletteWall, research(id: String), canvas, reference(…), editor(overlay: CentreOverlay?)
}
enum CentreOverlay: Equatable { case altitude, reviewBoard, book(…), notice(…), designGate(…), translationRound(…) }  // the real arms — read them
extension ProjectWindow {
    static func centreRoute(persona: Persona, subject: BinderSubject?, showsPaletteWall: Bool, publish: PublishCentre?, …) -> CentreRoute
}
```

- `centreRoute` composes the existing static decisions (`subjectShowsAltitude`, `reviewCentreShowsBoard`, `publishCentre`, `showsPaletteWallCentre`, …). It does not restate them.
- `editorPane` becomes one `switch` over the route.
- `.editor(overlay:)` renders `ZStack { EditorHost(...); overlay }`, with `EditorHost` FIRST and ALWAYS present in that arm, so its identity survives every overlay change (tripwire 6). The overlay is a single `switch`.

- [ ] **Step 1: Tests first** (`CentreRouteTests`, windowless).
  - For every `Persona` × each subject shape (project, group, document, research, none) × palette wall on/off × each publish state, `centreRoute` returns the route that today's if-chain and ZStack layer order produce. Derive the expected table from the existing implication tests (`ReviewBoardRoutingTests`, `PublishPreviewCentreTests`, `ProjectAltitudeCentreTests`) and from the current code's order.
  - Add one test asserting there is no combination where two overlays would both have shown (the old "never both offered" comment, now a fact).
- [ ] **Step 2:** Implement. Rewrite `editorPane`/`manuscriptEditor` as switches over the route. Keep the canvas branch a single mount at the same structural position.
- [ ] **Step 3:** Run `./scripts/test.sh only ProjectAltitudeCentreTests ReviewBoardRoutingTests PublishPreviewCentreTests DesignGateTests CentreRouteTests`, then the fast gate and a Release build.
- [ ] **Step 4:** Commit: `refactor(views): one exhaustive CentreRoute decides the centre column; EditorHost stays mounted beneath every overlay`

---

### Task 4: `CentreColumn` — the centre column becomes its own view

**Files:**
- Create `Maugham/Views/CentreColumn.swift`
- Modify `ProjectWindow.swift` (the content column builder about :1444, plus `editorPane`, `manuscriptEditor`, `canvasCentre` and the board's `refreshOpenNotes`)

**Contract:**
- Move these into `struct CentreColumn: View`:
  - `editorPane`/`manuscriptEditor`/`canvasCentre`;
  - the review board's open-notes counts and their refresh (`openNotesCounts`, `openNotesUnreadable`, `refreshOpenNotes`);
  - the helpers only they use.
- It takes:
  - the stores;
  - `canvasModel` as a `let` (it must never read `.scene`; tripwire 30);
  - `editorControl`;
  - `PublishCentreModel`;
  - the route inputs;
  - bindings for every window `@State` it writes (`selectedSubject`, `annotationScopeRequest`, `detailSegment` and others; read every write site);
  - closures for the window's verbs.
- `CentreColumn` is mounted ONCE where the content column builder rendered the centre, at the same structural position, so `EditorHost` and the canvas keep their identity.
- Write the identity argument in the report: what SwiftUI sees before and after.
- Censuses: plan 2 type-keyed the window. Symbols that move into `CentreColumn` leave `type:ProjectWindow`. Update each affected census to name `type:CentreColumn`, or the directory scope, and keep its control. Run the full census class after the move.

- [ ] **Step 1:** Move the code. Run `./gen.sh`.
- [ ] **Step 2:** Run `./scripts/test.sh only` over the centre suites (`ProjectAltitudeCentreTests`, `ReviewBoardRoutingTests`, `ReviewBoardPaneTests`, `PublishPreviewCentreTests`, `DesignGateTests`, `CanvasLiveSeamTests`, `RegionBindingTests`, `TripwireGrepTests`), then the fast gate, then a Release build.
- [ ] **Step 3:** Commit: `refactor(views): CentreColumn owns the centre column's builders and the board's counts; mounted once, same identity`

---

### Task 5: `RightColumn` — the detail column becomes its own view

**Files:**
- Create `Maugham/Views/RightColumn.swift`
- Modify `ProjectWindow.swift` (the detail column builder about :2705, `inspectorPane` about :3181, the resize handle, and the study-column arm)

**Contract:**
- Move these into `struct RightColumn: View`:
  - the resize handle and its drag state (`detailDragStartWidth`);
  - the study arm;
  - the inspector arm (`inspectorPane` and `researchOrSubject`);
  - the canvas and collection inspector builders.
- It takes the effective width as a VALUE, plus a binding for the persisted width it writes (`detailColumnWidth`). `DetailColumnWidthTests` has a one-width census: the `.frame(width:)` and `.navigationSplitViewColumnWidth` pair must keep reading one computed width.
- Plan 3 already injects the roster, bible and world into the environment at `inspectorPane`. Keep that injection on `RightColumn`.
- `RightColumn` is mounted once, at the same structural position.

- [ ] **Step 1:** Move the code, then run `./gen.sh`.
- [ ] **Step 2:** Run `./scripts/test.sh only DetailColumnWidthTests AssistantColumnTests StudyColumnMountTests TranslatorEnvironmentTests DesignerEnvironmentTests ResearchSubjectRevealTests TripwireGrepTests`, then the fast gate and a Release build.
- [ ] **Step 3:** Commit: `refactor(views): RightColumn owns the detail column — resize, study, inspector — and reads one width`

---

### Task 6: Small state structs, the sheets enum, and persona predicates

**Files:**
- Modify `ProjectWindow.swift`
- Modify `Maugham/Models/Persona.swift`
- Modify `IntentStrip.swift`
- Modify `BinderPaneToggle.swift` and `CollectionBinderPaneToggle.swift`
- Modify `MaughamApp.swift`
- Modify `MaughamTests/TripwireGrepTests.swift`

**Contract:**
- `PaletteWallState`: the three palette-wall `@State` (`showsPaletteWall`, `wallTravelPending`, `inspectorWasVisibleBeforePalette`) become one struct. Its existing static inout folds become mutating methods. The struct is a value in ONE `@State`, never an `@Observable` (tripwire 2).
- `WindowFlashes`: the flash and banner `@State` (`showingSaveFlash`, `showingCompilerFlash`, `compilerFlashLabel`, `compilerFlashGeneration`, `mcpBanner`) become one struct.
- Sheets: fold `showingCheckpointLabelSheet` and `showingSyntaxHelp` into `ProjectActiveSheet` cases, so one `.sheet(item:)` presents them, if that is behaviour-neutral. Read the sheet modifiers first. If two sheets can be open at once today, leave that pair alone and say so.
- Persona predicates (audit A):
  - Add `Persona.showsPaletteWall`, `Persona.showsIntentStrip` and `Persona.showsExports`, each an exhaustive switch.
  - Replace these literal comparisons with them:
    - `persona != .plan` at `ProjectWindow` (`showsPaletteWallCentre`);
    - `persona == .author` at `IntentStrip` (twice);
    - the Exports gate in `BinderPaneToggle` and `CollectionBinderPaneToggle`.
  - Derive `MaughamApp`'s ⌘1–⌘4 from `Persona.shortcutKey`.
  - Add a `TripwireGrepTests` census banning `persona ==`/`!= .` comparisons in `Maugham/Views`, with an allow-list of the files that legitimately need them, each with a reason. Include a planted control.

- [ ] **Step 1: Tests first.** The three predicates over every persona must answer exactly what the old literals answered. The census control must fire.
- [ ] **Step 2:** Implement, then run the fast gate and a Release build.
- [ ] **Step 3:** Commit: `refactor(views): palette-wall and flash state are values; persona predicates replace persona-name comparisons, censused`

---

### Task 7: Comment-to-contract pass on what remains of `ProjectWindow.swift`

**Files:** `Maugham/Views/ProjectWindow.swift`, plus the new files from Tasks 1–6 if they carried history over.

**Contract:**
- For each doc comment, keep:
  - the contract: what the member guarantees and the rule it enforces;
  - the test citation;
  - one pointer to the ADR or note that holds the history.
- Delete milestone narrative: "Task N", "stage 3b", "the 2026-08-25 bug was…", "used to".
- Never delete a sentence that states a rule.
- Measure before and after: the comment line count and the total LOC. Target: `ProjectWindow.swift`'s comment share under 40%.
- No code changes in this task. Run `git diff --stat` and `git diff -w` to show only comment lines changed.

- [ ] **Step 1:** Do the pass. Run `./scripts/test.sh` (comments only; it must stay green) and a Release build.
- [ ] **Step 2:** Commit: `docs(views): ProjectWindow's comments state contracts; the history lives in the ADRs and notes they cite`

---

## Finish

1. `./scripts/test.sh full` green, including the `CanvasViewMounting*` family, plus a Release build.
2. Whole-branch review on opus. It should:
   - check every task's identity argument against the code;
   - hunt for a binding that became a copy;
   - confirm `EditorHost` and the canvas are each mounted once in every route;
   - confirm no census became vacuous;
   - report the before and after LOC and `@State` counts for `ProjectWindow`.
3. Smoke for Denver, with all four personas:
   - Type, switch personas and switch back: the cursor and undo survive.
   - Open the canvas, pan, switch away and back: the camera survives.
   - Drag the right column's width: it persists.
   - Open the palette wall, the review board, a compiled book and the design gate.
4. Do not merge without Denver.
