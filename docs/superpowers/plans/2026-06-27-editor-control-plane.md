# Editor Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give editor control state (posture, appearance, review annotation set) a first-class `@Observable EditorControl` model that the `EditorCoordinator` observes directly, removing control from the layout-gated `updateNSView` and collapsing the review notifications.

**Architecture:** `ProjectWindow` owns an `EditorControl` and mirrors its derived control into it; the model is threaded down `EditorHost → EditorSurface` and handed to the coordinator at `attach`; the coordinator observes it via re-arming `withObservationTracking` and applies changes through existing no-op-guarded setters. Done parallel-then-remove: the model runs alongside the existing pushes first, and old paths are deleted only once proven. The text/data plane is untouched.

**Tech Stack:** Swift, SwiftUI, AppKit, Observation framework (`@Observable`, `withObservationTracking`). Mac target only (`Maugham/`); no MaughamCore changes.

## Global Constraints

- **Do not touch the text binding / data plane.** `Binding(get: { doc.displayText }, set: { doc.setFullText($0) })` stays exactly as is.
- **`applyExternalText` stays cloud-conflict-only** — no new caller (tripwire 7). The harness test `test_endOfFileTyping_doesNotFireApplyExternalText` must stay green.
- **One-way only.** SwiftUI-side sources write *downhill* into `EditorControl`; the coordinator only *reads* it. Nothing reads coordinator state back into the model (tripwires 2/6).
- **D1** — `EditorControl` contains only control state, never text- or cursor-derived values.
- **D2** — `EditorCoordinator.applyControl` stays per-sub-area no-op-guarded (a single property change re-applies only the changed area).
- **Logging/identity:** no hardcoded `"maugham"`/socket strings (tripwire 13) — N/A here but keep in mind.
- **Build/test commands:**
  - `./gen.sh` only if files are added to the target (run after Task 1 adds `EditorControl.swift`).
  - `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
- **Commit after every task.** Branch: `feat/editor-control-plane` (already exists; spec + ADR already committed there).

---

### Task 1: `EditorControl` model + coordinator `applyControl` + observation bridge

Introduces the model and the AppKit-side observation, unit-tested at the coordinator level. No view wiring yet; existing `updateNSView` pushes remain untouched.

**Files:**
- Create: `Maugham/Editor/EditorControl.swift`
- Modify: `Maugham/Editor/EditorCoordinator.swift` (add `control` ref, `observeControl`, `applyControl`)
- Modify: `project.yml` is NOT needed (xcodegen globs `Maugham/**`); run `./gen.sh` to pick up the new file.
- Test: `MaughamTests/Editor/EditorControlBridgeTests.swift`

**Interfaces:**
- Produces:
  - `EditorControl` — `@Observable final class` with mutable `var`s: `isReviewMode: Bool`, `lockEditing: Bool`, `theme: Theme`, `typography: TypographySettings`, `typewriterScroll: Bool`, `sentenceFocus: Bool`, `paragraphFocus: Bool`, `reviewAnnotations: [Annotation]`.
  - `EditorCoordinator.observeControl(_ control: EditorControl)` — stores the ref, runs the initial apply, and arms re-observation.
  - `EditorCoordinator.applyControl(_ c: EditorControl)` — applies all control via the guarded setters.
- Consumes (existing coordinator API): `setLockEditing(_:)`, `setReviewMode(_:)`, `applyAppearance(theme:typography:)`, `applyTypewriterScroll(_:)`, `applyFocusPrefs(sentence:paragraph:)`, `setReviewAnnotations(_:)`, plus the `private(set)` props `theme`, `typography`, `typewriterScroll`, `sentenceFocus`, `paragraphFocus`.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/Editor/EditorControlBridgeTests.swift`:

```swift
import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

@MainActor
final class EditorControlBridgeTests: XCTestCase {

    private func makeCoordinator() -> (EditorCoordinator, NSTextView) {
        final class TextBox { var value = "Hello world" }
        let box = TextBox()
        let coordinator = EditorCoordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            mode: ProseMode(),
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        tv.string = box.value
        tv.delegate = coordinator
        coordinator.attach(to: tv)
        return (coordinator, tv)
    }

    /// Wait briefly for the re-arming observation Task to apply.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// The model drives the membrane: initial apply locks; a later change unlocks
    /// in place (no key window, no notification, no view rebuild).
    func test_controlModel_drivesMembraneOnChange() async {
        let (coordinator, _) = makeCoordinator()
        let control = EditorControl()
        control.lockEditing = true
        control.isReviewMode = true

        coordinator.observeControl(control)   // initial apply
        XCTAssertTrue(coordinator.lockEditing, "initial apply must lock")
        XCTAssertTrue(coordinator.isReviewMode)

        // Resolve to author.
        control.lockEditing = false
        control.isReviewMode = false
        await settle()

        XCTAssertFalse(coordinator.lockEditing, "model change must unlock in place")
        XCTAssertFalse(coordinator.isReviewMode)
    }

    /// Appearance flows through the model too, guarded (D2): a typography change
    /// lands on the coordinator.
    func test_controlModel_drivesAppearance() async {
        let (coordinator, _) = makeCoordinator()
        let control = EditorControl()
        control.theme = .light
        control.typography = .defaults
        coordinator.observeControl(control)

        var bumped = TypographySettings.defaults
        bumped.fontSize = bumped.fontSize + 3
        control.typography = bumped
        await settle()

        XCTAssertEqual(coordinator.typography.fontSize, bumped.fontSize,
            "typography change must reach the coordinator via the model")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/EditorControlBridgeTests 2>&1 | tail -20`
Expected: FAIL to compile — `cannot find 'EditorControl' in scope` / no `observeControl`.

- [ ] **Step 3: Create the `EditorControl` model**

Create `Maugham/Editor/EditorControl.swift`:

```swift
import Foundation
import MaughamCore
import Observation

/// First-class model for editor CONTROL state — the configuration the editor
/// needs that is NOT the manuscript text. The data plane (text) is owned by
/// `Document`; this is its control-plane analogue (ADR 0017).
///
/// `ProjectWindow` owns one of these and mirrors its derived control into it;
/// the `EditorCoordinator` observes it via `withObservationTracking`. Flow is
/// strictly one-way (sources → model → coordinator); the coordinator never
/// writes back.
///
/// INVARIANT D1: only genuine control state lives here — never text- or
/// cursor-derived values. If a per-keystroke value leaked in, the coordinator's
/// observation would fire on the typing hot path.
@Observable
final class EditorControl {
    // Posture (membrane).
    var isReviewMode: Bool = false
    var lockEditing: Bool = false

    // Appearance.
    var theme: Theme = .light
    var typography: TypographySettings = .defaults
    var typewriterScroll: Bool = false
    var sentenceFocus: Bool = false
    var paragraphFocus: Bool = false

    // Review render set (open annotations shown in review posture).
    var reviewAnnotations: [Annotation] = []

    init() {}
}
```

- [ ] **Step 4: Add `applyControl` + `observeControl` to the coordinator**

In `Maugham/Editor/EditorCoordinator.swift`, add a stored property near the other observer state (after `reviewPostureObserver`, around line 228):

```swift
    /// The control-plane model (ADR 0017). Set once at `attach` via
    /// `observeControl`; the coordinator READS it (never writes). nil until
    /// `observeControl` runs.
    private var control: EditorControl?
```

Then add these methods (place them next to `setLockEditing`/`setReviewMode`, after `setReviewMode`'s closing brace, around line 675):

```swift
    /// Begin observing the control-plane model. Runs an initial apply, then
    /// re-arms on every change via Observation. Pure AppKit-side — independent
    /// of SwiftUI's layout cadence, which is the whole point (ADR 0017): a
    /// control change that doesn't trigger a layout pass (e.g. the async iCloud
    /// role resolve) still reaches the membrane here.
    func observeControl(_ control: EditorControl) {
        self.control = control
        armControlObservation()
    }

    private func armControlObservation() {
        guard let control else { return }
        withObservationTracking {
            applyControl(control)            // reads every tracked property
        } onChange: { [weak self] in
            // onChange fires once (pre-change). Re-arm on the next main-actor
            // turn — after the mutation commits — so the re-applied values are
            // current. Re-entering withObservationTracking synchronously inside
            // onChange is unsafe, hence the hop.
            Task { @MainActor [weak self] in self?.armControlObservation() }
        }
    }

    /// Apply the full control model through the existing setters. INVARIANT D2:
    /// every sub-area is no-op-guarded, so a single property change re-applies
    /// only the area that changed (the setters that aren't self-guarding —
    /// appearance/typewriter/focus — are guarded here at the call site, exactly
    /// as `updateNSView` did).
    func applyControl(_ c: EditorControl) {
        setLockEditing(c.lockEditing)        // self-guarded
        setReviewMode(c.isReviewMode)        // self-guarded
        if theme != c.theme || typography != c.typography {
            applyAppearance(theme: c.theme, typography: c.typography)
        }
        if typewriterScroll != c.typewriterScroll {
            applyTypewriterScroll(c.typewriterScroll)
        }
        if sentenceFocus != c.sentenceFocus || paragraphFocus != c.paragraphFocus {
            applyFocusPrefs(sentence: c.sentenceFocus, paragraph: c.paragraphFocus)
        }
        setReviewAnnotations(c.reviewAnnotations)   // self-guarded
    }
```

- [ ] **Step 5: Regenerate the project and run the test to verify it passes**

Run:
```bash
./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/EditorControlBridgeTests 2>&1 | tail -20
```
Expected: PASS (both tests).

- [ ] **Step 6: Run the full suite to confirm no regression**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures"`
Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Editor/EditorControl.swift Maugham/Editor/EditorCoordinator.swift MaughamTests/Editor/EditorControlBridgeTests.swift
git commit -m "feat(editor): EditorControl model + coordinator observation bridge (ADR 0017)"
```

---

### Task 2: Thread `EditorControl` through the views, populated in parallel

`ProjectWindow` owns the model, mirrors posture + appearance into it, and threads it to the coordinator at `attach`. The existing `updateNSView` pushes and notifications **stay active** — the model shadows them (no-op guards make double-application safe). No behavior change; this is the scaffolding the later cut-over tasks rely on.

**Files:**
- Modify: `Maugham/Editor/EditorSurface.swift` (accept `control`, call `observeControl` after `attach`)
- Modify: `Maugham/Views/EditorHost.swift` (accept `control`, pass to `EditorSurface`)
- Modify: `Maugham/Views/ProjectWindow.swift` (own `@State editorControl`, mirror sources, pass to `EditorHost`)

**Interfaces:**
- Consumes: `EditorControl`, `EditorCoordinator.observeControl(_:)` (Task 1).
- Produces: `EditorSurface.control: EditorControl` and `EditorHost.control: EditorControl` stored properties; `ProjectWindow` owns `editorControl` and keeps it in sync.

- [ ] **Step 1: Add `control` to `EditorSurface` and observe it after attach**

In `Maugham/Editor/EditorSurface.swift`, add a stored property alongside the other inputs (after `lockEditing`, around line 26):

```swift
    /// Control-plane model (ADR 0017). The coordinator observes this directly;
    /// it is the channel for posture/appearance/annotation changes, replacing
    /// the per-prop pushes in updateNSView. Threaded ONE-WAY from ProjectWindow.
    var control: EditorControl
```

In `makeNSView`, immediately after `context.coordinator.attach(to: textView)` (line 223), add:

```swift
        // Hand the control-plane model to the coordinator. It observes the model
        // from here on; the per-prop pushes below remain during the parallel
        // migration (ADR 0017) and are removed in later tasks.
        context.coordinator.observeControl(control)
```

Because `control` has no default, update the two existing `EditorSurface(...)` call sites in `EditorHost.swift` in the next step (the compiler will flag them).

- [ ] **Step 2: Add `control` to `EditorHost` and pass it down**

In `Maugham/Views/EditorHost.swift`, add a stored property near `lockEditing` (around line 45):

```swift
    /// Control-plane model owned by ProjectWindow, threaded ONE-WAY to the
    /// EditorSurface/coordinator (ADR 0017).
    var control: EditorControl
```

In `body`, add `control: control,` to the `EditorSurface(...)` initializer (next to `lockEditing: lockEditing,`, around line 100):

```swift
                    isReviewMode: isReviewMode,
                    lockEditing: lockEditing,
                    control: control,
```

(If a second `EditorSurface(...)` call exists in this file — e.g. a research-note path — add `control: control,` there too. Grep: `grep -n "EditorSurface(" Maugham/Views/EditorHost.swift`.)

- [ ] **Step 3: `ProjectWindow` owns the model and mirrors sources into it**

In `Maugham/Views/ProjectWindow.swift`, add the state (near `collaborator`, around line 61):

```swift
    /// Control-plane model for the editor (ADR 0017). ProjectWindow is its sole
    /// posture/appearance writer; EditorHost writes the annotation set (Task 5).
    /// Threaded down to the coordinator, which observes it.
    @State private var editorControl = EditorControl()
```

Pass it into the `EditorHost(...)` initializer in `existingEditorSwitch` (after `lockEditing: effectivePosture.lockEditing`, around line 776):

```swift
                isReviewMode: effectivePosture.isReviewMode,
                lockEditing: effectivePosture.lockEditing,
                control: editorControl
```

Add mirroring modifiers next to the existing `.onChange(of: effectivePosture)` (the posture-push block added in commit `c80f11b`, around line 285). Replace nothing yet — ADD these so the model stays current (the existing notification post stays for now):

```swift
        .onChange(of: effectivePosture) { _, posture in
            editorControl.isReviewMode = posture.isReviewMode
            editorControl.lockEditing = posture.lockEditing
        }
        .onChange(of: userPreferences.theme) { _, t in editorControl.theme = t }
        .onChange(of: effectiveTypography) { _, t in editorControl.typography = t }
        .onChange(of: userPreferences.typewriterScroll) { _, v in
            editorControl.typewriterScroll = v
        }
        .onChange(of: userPreferences.sentenceFocus) { _, v in
            editorControl.sentenceFocus = v
        }
        .onChange(of: userPreferences.paragraphFocus) { _, v in
            editorControl.paragraphFocus = v
        }
        .onAppear {
            // Seed the model from current sources (onChange only fires on change).
            editorControl.isReviewMode = effectivePosture.isReviewMode
            editorControl.lockEditing = effectivePosture.lockEditing
            editorControl.theme = userPreferences.theme
            editorControl.typography = effectiveTypography
            editorControl.typewriterScroll = userPreferences.typewriterScroll
            editorControl.sentenceFocus = userPreferences.sentenceFocus
            editorControl.paragraphFocus = userPreferences.paragraphFocus
        }
```

Add a computed helper for the effective typography (mirrors what `EditorHost` passes today) near `effectivePosture` (around line 308):

```swift
    /// The typography the editor actually uses — manifest override else user
    /// default. Mirrors the value EditorHost passes to EditorSurface, so the
    /// control model and the (still-active) prop path agree during migration.
    private var effectiveTypography: TypographySettings {
        guard let store else { return userPreferences.typography }
        return ProjectStore.effectiveTypography(
            override: store.manifest.typography,
            userDefault: userPreferences.typography)
    }
```

- [ ] **Step 4: Build and run the full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures|error:"`
Expected: 0 failures (the model now shadows the existing pushes; no behavior change).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/EditorSurface.swift Maugham/Views/EditorHost.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat(editor): thread EditorControl through the views (parallel with existing pushes)"
```

---

### Task 3: Cut posture over to the model; delete the posture notification

Posture now flows ONLY through `EditorControl`. Remove the posture pushes from `updateNSView`/`makeNSView` and delete the `maughamReviewPostureResolved` machinery (the targeted fix from `c80f11b`, now subsumed).

**Files:**
- Modify: `Maugham/Editor/EditorSurface.swift` (drop `setLockEditing`/`setReviewMode` pushes + the `isReviewMode`/`lockEditing` props)
- Modify: `Maugham/Views/EditorHost.swift` (drop `isReviewMode`/`lockEditing` props + args)
- Modify: `Maugham/Views/ProjectWindow.swift` (drop the `maughamReviewPostureResolved` post; drop `isReviewMode`/`lockEditing` args to `EditorHost`)
- Modify: `Maugham/Editor/EditorCoordinator.swift` (remove `reviewPostureObserver` + `applyResolvedPosture` + the deinit removal)
- Modify: `Maugham/Models/MaughamNotifications.swift` (remove `maughamReviewPostureResolved`)
- Test: `MaughamTests/Editor/ReviewModeMembraneTests.swift` (retarget the posture-resolve test onto the model)

**Interfaces:**
- Consumes: `EditorControl`, `observeControl`/`applyControl` (Tasks 1–2).

- [ ] **Step 1: Retarget the posture-resolve regression test onto the model**

In `MaughamTests/Editor/ReviewModeMembraneTests.swift`, replace `test_applyResolvedPosture_unlocksMembraneOnRoleResolve` with a model-driven version:

```swift
    /// Resolved-posture push regression (the "can't edit my own doc until I flip
    /// pieces" bug), now via the control plane (ADR 0017): mutating the observed
    /// EditorControl unlocks the membrane in place — no key window, no notification.
    @MainActor
    func test_controlModelResolve_unlocksMembrane() async {
        final class TextBox { var value = "Hello world" }
        let box = TextBox()
        let coordinator = EditorCoordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            mode: ProseMode(),
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        tv.string = box.value
        tv.delegate = coordinator
        coordinator.attach(to: tv)

        let control = EditorControl()
        control.isReviewMode = true
        control.lockEditing = true
        coordinator.observeControl(control)   // open posture: locked

        XCTAssertFalse(
            coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                 replacementString: "x"),
            "own doc opens locked while role unresolved")

        control.isReviewMode = false
        control.lockEditing = false
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(
            coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                 replacementString: "x"),
            "role resolving to author must re-open the membrane in place")
    }
```

- [ ] **Step 2: Run it to verify it passes (model path already wired)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ReviewModeMembraneTests/test_controlModelResolve_unlocksMembrane 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 3: Remove the posture pushes from `EditorSurface`**

In `Maugham/Editor/EditorSurface.swift`:
- Delete the `var isReviewMode: Bool = false` and `var lockEditing: Bool = false` stored properties (around lines 19 and 26).
- In `makeNSView`, delete lines 250–251:
  ```swift
        context.coordinator.setLockEditing(lockEditing)
        context.coordinator.setReviewMode(isReviewMode)
  ```
  Keep the `setReviewAnnotations(reviewAnnotations)` seed at line 246 (annotations migrate in Task 5).
- In `updateNSView`, delete lines 317–318:
  ```swift
        context.coordinator.setLockEditing(lockEditing)
        context.coordinator.setReviewMode(isReviewMode)
  ```

- [ ] **Step 4: Remove the posture props from `EditorHost` and `ProjectWindow`**

In `Maugham/Views/EditorHost.swift`:
- Delete the `var isReviewMode: Bool = false` and `var lockEditing: Bool = false` properties (around lines 38–45).
- In the `EditorSurface(...)` call, delete the `isReviewMode: isReviewMode,` and `lockEditing: lockEditing,` arguments (around lines 99–100).

In `Maugham/Views/ProjectWindow.swift`:
- In the `EditorHost(...)` call, delete `isReviewMode: effectivePosture.isReviewMode,` and `lockEditing: effectivePosture.lockEditing,` (keep `control: editorControl`).
- Delete the `.onChange(of: effectivePosture)` block that posts `maughamReviewPostureResolved` (the `guard window?.isKeyWindow ...; NotificationCenter.default.post(name: .maughamReviewPostureResolved ...)` block). Keep the OTHER `.onChange(of: effectivePosture)` added in Task 2 that mirrors into `editorControl`.

- [ ] **Step 5: Remove the notification + coordinator observer**

In `Maugham/Models/MaughamNotifications.swift`, delete the `maughamReviewPostureResolved` declaration and its doc comment.

In `Maugham/Editor/EditorCoordinator.swift`:
- Delete the `reviewPostureObserver` stored property + its doc comment.
- Delete the `reviewPostureObserver = NotificationCenter.default.addObserver(forName: .maughamReviewPostureResolved ...)` registration block.
- Delete the `applyResolvedPosture(isReviewMode:lockEditing:)` method.
- Delete the `if let token = reviewPostureObserver { NotificationCenter.default.removeObserver(token) }` from `deinit`.

(Also update `MaughamTests/Editor/ReviewModeMembraneTests.swift` if it still references `applyResolvedPosture` — the Step 1 replacement removed the only caller.)

- [ ] **Step 6: Build and run the full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures|error:"`
Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(editor): posture flows via EditorControl; delete maughamReviewPostureResolved (ADR 0017)"
```

---

### Task 4: Cut appearance over to the model

Theme/typography/typewriter/focus now flow only through the model. Remove their pushes from `updateNSView`.

**Files:**
- Modify: `Maugham/Editor/EditorSurface.swift` (drop the appearance/typewriter/focus blocks in `updateNSView`)

**Interfaces:**
- Consumes: `EditorControl` appearance fields (mirrored in Task 2), `applyControl` (Task 1).

- [ ] **Step 1: Remove the appearance pushes from `updateNSView`**

In `Maugham/Editor/EditorSurface.swift` `updateNSView`, delete these three blocks:
- the `if context.coordinator.theme != theme || context.coordinator.typography != typography { context.coordinator.applyAppearance(...) ... container.size = ... }` block (around lines 270–281). **Keep** the `textView.columnWidth`/`container.size` re-set only if it depends on a layout concern — it depends on `typography`; move that width re-set into a small `.onChange`-free path is out of scope, so instead keep the column-width update but drive it off the model: replace the whole block's condition with a comparison against the coordinator's now-model-applied typography. Simplest correct move: leave the `columnWidth`/`container.size` recompute in `updateNSView` (it is layout, not control) but remove only the `applyAppearance` call. Concretely, change the block to:
  ```swift
        // Appearance itself flows via EditorControl (ADR 0017); only the
        // text-container width remains a layout concern handled here.
        let columnWidth = mode.textColumnWidth(typography: typography)
        if abs(textView.columnWidth - columnWidth) > 0.5 {
            textView.columnWidth = columnWidth
            textView.textContainer?.size = NSSize(
                width: columnWidth, height: .greatestFiniteMagnitude)
        }
  ```
- the `if context.coordinator.typewriterScroll != typewriterScroll { context.coordinator.applyTypewriterScroll(typewriterScroll) }` block (around lines 282–284) — delete entirely.
- the `if context.coordinator.sentenceFocus != sentenceFocus || context.coordinator.paragraphFocus != paragraphFocus { context.coordinator.applyFocusPrefs(...) }` block (around lines 285–289) — delete entirely.

- [ ] **Step 2: Build and run the full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures|error:"`
Expected: 0 failures. (`WindowedTypographyEquivalenceTests` and any appearance tests must stay green — they exercise the coordinator setters directly, which are unchanged.)

- [ ] **Step 3: Manual smoke (record result in the commit)**

Build + run the dev app; change theme and font size in Settings, toggle typewriter scroll. Confirm each applies live. (If a SwiftUI `userPreferences` change doesn't trigger a layout pass, the model `.onChange` still fires — that's the fix working.)

- [ ] **Step 4: Commit**

```bash
git add Maugham/Editor/EditorSurface.swift
git commit -m "feat(editor): appearance flows via EditorControl; updateNSView sheds it (ADR 0017)"
```

---

### Task 5: Cut the review annotation set over; collapse the review notifications

The open-annotation set flows through the model (written by `EditorHost` from its `Document`). Remove `setReviewAnnotations` from `make/updateNSView`, and collapse `maughamReviewAnnotationsChanged` + the coordinator's direct `maughamToggleReviewMode` observation. The on-entry provider pull (`reviewAnnotationsProvider`) stays — it solves a different first-toggle timing problem.

**Files:**
- Modify: `Maugham/Views/EditorHost.swift` (write `editorControl.reviewAnnotations` from the Document; drop the `reviewAnnotations:` prop on `EditorSurface`)
- Modify: `Maugham/Editor/EditorSurface.swift` (drop `reviewAnnotations` prop + the two `setReviewAnnotations` pushes)
- Modify: `Maugham/Editor/EditorCoordinator.swift` (drop ONLY the `maughamReviewAnnotationsChanged` observer; KEEP the `maughamToggleReviewMode` observer for synchronous ⌘⌥R entry — Bug B)

**Interfaces:**
- Consumes: `EditorControl.reviewAnnotations`, `applyControl` (sets it via guarded `setReviewAnnotations`).

- [ ] **Step 1: Write `editorControl.reviewAnnotations` from `EditorHost`**

In `Maugham/Views/EditorHost.swift`, `EditorHost` needs the control model (added Task 2) and the Document. Add, on the `EditorSurface` (or a wrapping view) inside the `if let doc` branch, a sync that mirrors the open set into the model whenever it changes:

```swift
                .onChange(of: doc.annotationsVersion) { _, _ in
                    control.reviewAnnotations = isReviewMode
                        ? doc.annotations(filter: AnnotationFilter(statuses: [.open]))
                        : []
                }
                .onChange(of: isReviewMode) { _, nowReview in
                    control.reviewAnnotations = nowReview
                        ? doc.annotations(filter: AnnotationFilter(statuses: [.open]))
                        : []
                }
                .onAppear {
                    control.reviewAnnotations = isReviewMode
                        ? doc.annotations(filter: AnnotationFilter(statuses: [.open]))
                        : []
                }
```

Then delete the `reviewAnnotations:` argument from the `EditorSurface(...)` call (the `reviewAnnotations: isReviewMode ? {...}() : [],` block around lines 172–176). Keep `reviewAnnotationsProvider:` (the on-entry pull).

Note: `isReviewMode` is still an `EditorHost` input in Task 2's state. If Task 3 removed it, re-source it: read `control.isReviewMode` instead of the removed prop in the three closures above (`control.isReviewMode ? ... : []`).

- [ ] **Step 2: Remove the annotation pushes from `EditorSurface`**

In `Maugham/Editor/EditorSurface.swift`:
- Delete the `var reviewAnnotations: [Annotation] = []` stored property (around line 85).
- In `makeNSView`, delete `context.coordinator.setReviewAnnotations(reviewAnnotations)` (line 246).
- In `updateNSView`, delete `context.coordinator.setReviewAnnotations(reviewAnnotations)` (line 322).

(`applyControl` now calls `setReviewAnnotations(c.reviewAnnotations)`, so the set still reaches the coordinator — via the model.)

- [ ] **Step 3: Collapse the annotation-changed notification (KEEP the ⌘⌥R command observer)**

In `Maugham/Editor/EditorCoordinator.swift`:
- **KEEP** the `maughamToggleReviewMode` observer (`reviewToggleObserver`). This is the documented **Bug B** fix: ⌘⌥R must flip the membrane *synchronously* so a fast Enter right after toggling review ON cannot slip an edit through (`ReviewModeMembraneTests.test_setReviewMode_blocksMutationImmediately`). Routing it only through the model makes the apply async (an observation Task hop), re-opening that race. The observer and the model both derive from the same `isReviewModeOn` and converge via `setReviewMode`'s no-op guard, so there is no dual-source-of-truth divergence (same convergence the AREA already documents for the toggle + `updateNSView` pair). `ProjectWindow` already flips `isReviewModeOn` on ⌘⌥R, key-window-guarded (`ProjectWindow.swift:1273-1277`), so the model stays consistent too.
- **Delete** the `maughamReviewAnnotationsChanged` observer + `reviewAnnotationsChangedObserver` property + its `deinit` removal **only after** confirming the model sync (Step 1) covers the AnnotationsPane-edit case. It does: an AnnotationsPane edit bumps `doc.annotationsVersion`, which the Step 1 `.onChange` mirrors into the model → `applyControl` → `setReviewAnnotations` → recompute. **Keep** `refreshReviewMarksFromProvider` (used by the in-editor create flow) and the on-entry `reviewAnnotationsProvider` pull.

- [ ] **Step 4: Build and run the full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures|error:"`
Expected: 0 failures. (`ReviewModeMembraneTests` — first-toggle/create-while-in-review — must stay green; they drive the coordinator directly and use the provider pull, which is unchanged.)

- [ ] **Step 5: Manual smoke**

Dev app: enter review (⌘⌥R), create a comment, edit/withdraw from the AnnotationsPane — confirm marks/rail update without toggling review off/on. Toggle ⌘⌥R off/on.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(editor): annotation set + review toggle via EditorControl; collapse review notifications (ADR 0017)"
```

---

### Task 6: Shrink `updateNSView`, update AREA.md, full smoke

Final cleanup: confirm `updateNSView` carries only text + frame + gutter, remove any now-dead props, and record D1/D2 + the control-plane rule in the area guide.

**Files:**
- Modify: `Maugham/Editor/EditorSurface.swift` (remove any unused stored props left over)
- Modify: `Maugham/Editor/AREA.md`

- [ ] **Step 1: Audit `updateNSView` for residual control**

Run: `grep -n "context.coordinator\." Maugham/Editor/EditorSurface.swift`
Confirm `updateNSView` only calls: the text-binding check (`applyExternalText`), gutter install/remove, `imagePasteHandler`/provider wiring assignments (out of scope, fine), and frame/width. No `setLockEditing`/`setReviewMode`/`applyAppearance`/`applyTypewriterScroll`/`applyFocusPrefs`/`setReviewAnnotations` remain. Remove any stray ones.

- [ ] **Step 2: Remove dead stored props**

Run `xcodebuild ... build` and address any "never used" warnings for `EditorSurface`/`EditorHost` props removed from the call paths (e.g. `theme`/`typography` are still used by `makeCoordinator` for the INITIAL coordinator state — keep those; only remove props with zero remaining readers). Use the compiler as the guide.

- [ ] **Step 3: Update `Maugham/Editor/AREA.md`**

Add a "Control plane (ADR 0017)" subsection under Layout, stating:
- Control state (posture/appearance/review annotation set) flows through `EditorControl`, observed by the coordinator via `withObservationTracking`; it does NOT ride `updateNSView` and does NOT get a new notification.
- D1: `EditorControl` holds only control state, never text-/cursor-derived values.
- D2: `applyControl` stays per-sub-area no-op-guarded.
- `updateNSView` is text + frame + gutter only; the text binding/data plane is unchanged.

- [ ] **Step 4: Full suite + Release build (ProjectWindow.body changed → Release type-check budget)**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures"
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: 0 failures; `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Full manual smoke**

Open own local doc → editable immediately (no piece switch); theme/typography/typewriter change live; ⌘⌥R on/off; review authoring updates without a toggle; type into a long scrolled document and confirm no cursor/scroll regression.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/EditorSurface.swift Maugham/Editor/AREA.md
git commit -m "refactor(editor): updateNSView is text+frame+gutter only; AREA.md control-plane invariants (ADR 0017)"
```

---

## Notes for the implementer

- **The async-apply timing in tests:** the coordinator re-arms observation on the next main-actor turn, so a model mutation applies *after* a `Task` hop. Tests must `await` a short settle (`Task.sleep(for: .milliseconds(50))`) before asserting. Production code never depends on synchronous apply.
- **If Task 5 (annotations) proves entangled**, it can be deferred: Tasks 1–4 already end the core fragility class (posture + appearance off the layout-gated path). Stop after Task 4, leave the annotation set on its current notification path, and file a follow-up. Do NOT block the posture/appearance win on the annotation migration.
- **Cursor invariants are the net.** If any harness test in `EditorIntegrationHarnessTests` / `ReviewModeMembraneTests` / `DeferredRestyleTests` / `WindowedTypographyEquivalenceTests` goes red, stop and treat it as a real regression, not a test to update.
