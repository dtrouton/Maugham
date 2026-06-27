# Editor Control Plane — Design

**Date:** 2026-06-27
**Status:** Proposed
**Area:** `Maugham/Editor/` (the SwiftUI↔AppKit editor seam) + `Maugham/Views/ProjectWindow.swift`, `EditorHost.swift`

## Summary

Give editor **control state** (posture, appearance, the review annotation set) a
first-class owned model that the `EditorCoordinator` observes directly, instead
of smuggling it through the view layer's layout-gated `updateNSView` plus a
growing set of one-way notifications. This ends a structural fragility class in
the most fragile area of the codebase, and it does so by *reducing* what touches
the cursor-critical text path — not by touching it more.

This is *document-first-class, but for control*: the data plane (manuscript
text) already has an owned model (`Document`) that the coordinator binds to
directly, which is why it's stable. The control plane never got that treatment.

## Problem (root cause, empirically confirmed)

Opening a project, the editor was read-only on the writer's own local document
until they switched binder pieces. Instrumented logging of the SwiftUI→AppKit
chain on the `collaborator` role resolve showed:

```
updateNSView FIRED      lockEditing=true     ← initial layout (x2)
… ProjectWindow.body / EditorHost.body re-run several more times, still true …
resolveCollaborator SET role=author          ← async iCloud probe lands
ProjectWindow.body  re-eval  lockEditing=false   ✓ re-runs
EditorHost.body     re-eval  lockEditing=false   ✓ re-runs
(… updateNSView NEVER fires again …)
```

So the SwiftUI body chain re-evaluates correctly with the new value —
`EditorHost` rebuilds `EditorSurface(lockEditing: false)`. The break is the last
hop: **`EditorSurface.updateNSView` is not called after that rebuild.** The same
trace shows why: across 4+ body re-evaluations `updateNSView` fired only twice —
it is driven by AppKit **layout passes**, not by SwiftUI body re-evaluation. A
pure `@State` change (the async resolve) re-runs the bodies but doesn't dirty the
representable's AppKit layout, so `updateNSView` stays pending until the next
layout-triggering interaction — switching pieces — which is exactly the
workaround that "fixed" it.

### Scope of the class

This affects **every control payload delivered only through `updateNSView`** —
`theme`, `typography`, `typewriterScroll`, focus prefs, `lockEditing`,
`isReviewMode`, the review annotation set, and the provider/handler wiring. The
reason only posture surfaced the bug: every other control payload changes via
**direct user interaction** (clicking a setting, typing), and that interaction
*itself* triggers the layout pass that flushes `updateNSView`. Posture is the
only payload that changes from an **async background resolve** with no
accompanying interaction, so it is the one that got stranded.

A targeted fix already shipped to `main` (commit `c80f11b`): a key-window-guarded
`maughamReviewPostureResolved` notification → `EditorCoordinator.applyResolvedPosture`.
It is correct in shape but is the third such notification patch. The notifications
(`maughamToggleReviewMode`, `maughamReviewAnnotationsChanged`,
`maughamReviewPostureResolved`) are the *symptom* of the missing control plane:
each is a bypass for "this payload needed to reach the coordinator off a layout
pass."

## Structural diagnosis: a missing control plane

Two planes cross this seam with very different change-cadences:

- **Data plane** — the manuscript text. High-frequency, cursor-critical,
  single-writer. *Already first-classed:* `Document` owns the substrate/op-log/
  autosave and `EditorHost` binds the coordinator to it directly. Healthy
  precisely *because* it has an owned model, not props pushed through the view.

- **Control plane** — posture, appearance, the review annotation set. State that
  *configures* the editor rather than *being edited*. **No owned model.** It
  lives as scattered `@State` on `ProjectWindow` (`collaborator`,
  `isReviewModeOn`) + `@Environment` (`userPreferences`), and reaches the
  coordinator by being smuggled through `updateNSView` (layout-gated), patched
  with one-way notifications.

"Missing control plane" = control state is *homeless*: authored in views,
delivered through a bridge whose flush trigger (layout) doesn't match when
control actually changes. Every downstream symptom (the async-posture bug, the
appearance lag, the dual delivery mechanisms) traces to that one gap.

## Design

### The `EditorControl` model

A new `@Observable final class EditorControl` (Mac target, `Maugham/Editor/`) is
the single source of truth for editor control state:

```swift
@Observable final class EditorControl {
    // Posture (membrane)
    var isReviewMode: Bool = false
    var lockEditing: Bool = false
    // Appearance
    var theme: Theme = .light
    var typography: TypographySettings = .defaults
    var typewriterScroll: Bool = false
    var sentenceFocus: Bool = false
    var paragraphFocus: Bool = false
    // Review render set
    var reviewAnnotations: [Annotation] = []
}
```

- **`ProjectWindow` owns it** (a `@State EditorControl`) and is its **sole
  writer**. It mirrors its derived control into the model via `.onChange`
  handlers off the existing sources (`effectivePosture`, `userPreferences`, the
  effective typography, the active `Document`'s annotation set). `.onChange`
  fires on body re-evaluation — which the trace proved happens reliably — so the
  model always reflects the latest control, independent of layout.
- It is threaded down `EditorHost → EditorSurface` and handed to the coordinator
  **at `attach`** (a reference, not copied).

### The bridge: coordinator observes the model

The coordinator is an AppKit `NSObject`, not a SwiftUI view, so it consumes the
model via Observation's re-arming `withObservationTracking` — pure AppKit-side,
no view layer, no layout-gating:

```swift
private func observeControl() {
    guard let control else { return }
    withObservationTracking {
        applyControl(control)              // reads the tracked properties
    } onChange: { [weak self] in
        Task { @MainActor in self?.observeControl() }   // re-arm after the change
    }
}

func applyControl(_ c: EditorControl) {
    setLockEditing(c.lockEditing)          // existing no-op-guarded setters
    setReviewMode(c.isReviewMode)
    applyAppearanceIfChanged(c.theme, c.typography)
    applyTypewriterScroll(c.typewriterScroll)   // guarded
    applyFocusPrefs(c.sentenceFocus, c.paragraphFocus)  // guarded
    setReviewAnnotations(c.reviewAnnotations)   // guarded
}
```

`applyControl` is called once on `attach` (initial state) and once per control
change thereafter. Every sub-apply is already no-op-guarded, so a single
property change re-applies only the area that changed.

### What `updateNSView` becomes

`updateNSView` sheds all control. It shrinks to:

- the text-binding check (`if textView.string != text { applyExternalText(text) }`
  — cloud-conflict only, **unchanged**),
- frame/width tracking (genuinely layout-coincident),
- gutter install/remove (mode change).

The cursor-critical path is touched by *strictly less* than today.

### Wiring (providers/handlers) — out of scope, stays as-is

The ~14 provider/handler closures (`paragraphRangeProvider`, `imagePasteHandler`,
review action handlers, …) are **not** part of this refactor. They are set-once
per surface lifetime (re-assigned on document switch, which rebuilds the
surface), they are not stateful control that changes off-interaction, and they
are not Equatable (closures). They keep being assigned in `make/updateNSView` as
today. Folding them in is a separate, optional cleanup; including them here would
widen the blast radius without serving the goal.

## Invariants

New (the two disciplines that keep this fast and safe):

- **D1 — `EditorControl` contains only genuine control state; never text- or
  cursor-derived values.** If cursor position or any per-keystroke value leaked
  into the model, `withObservationTracking` would fire on the hot path. The
  model is posture + appearance + annotation set, full stop.
- **D2 — `applyControl` stays per-sub-area no-op-guarded.** A single property
  change must not redundantly do whole-doc work for unchanged areas. (The
  existing setters already guarantee this; the rule is to keep it.)

Preserved (existing, must not regress):

- **Single writer to the text view**; `displayText` written once
  (`Document.setFullText`).
- **`applyExternalText` stays cloud-conflict-only** (tripwire 7 + harness test
  `test_endOfFileTyping_doesNotFireApplyExternalText`).
- **One-way only**: `ProjectWindow` writes `EditorControl`; the coordinator only
  reads it. Nothing reads coordinator state back into the model (tripwires 2/6 —
  no bidirectional sync, no flag-guard loops).
- The text binding shape is **untouched**.

## Notification collapse

- `maughamReviewPostureResolved` — **deleted.** Posture flows via the model.
- `maughamToggleReviewMode` (⌘⌥R menu command) — **stays** as a menu→window
  command, but its only job becomes flipping `ProjectWindow.isReviewModeOn` →
  `EditorControl.isReviewMode`. The coordinator **stops observing it directly**,
  removing the documented dual-source-of-truth between the notification path and
  `updateNSView`'s reconciler.
- `maughamReviewAnnotationsChanged` — **collapses**: an AnnotationsPane edit
  updates the source set → `EditorControl.reviewAnnotations` → coordinator. (The
  on-entry provider *pull* in `setReviewMode` stays; it solves a different
  first-toggle-timing problem and does not depend on the layout cadence.)

Net: three notifications + several `updateNSView` control pushes → **one observed
model**.

## Performance

No meaningful concern; a small hot-path win.

- The keystroke path does not touch the control plane (control props never change
  per keystroke), so `withObservationTracking` stays dormant during typing — zero
  added hot-path cost.
- It *removes* work from the per-keystroke `updateNSView` (the appearance/
  posture/typewriter/focus compares + setter calls that ran on every
  `displayText`-driven re-render move off that path).
- Observation fires only on rare control events (posture resolve, theme change,
  ⌘⌥R, annotation create/edit) — a handful per session. The re-arm cost is
  negligible at that cadence.
- The one inherent cost (`applyAppearance` whole-doc restyle on a theme change)
  is unchanged — it happens today too, just triggered by the model instead of a
  layout pass.

D1 and D2 are what keep these properties true.

## Migration sequencing (incremental, under the test net)

Done as small steps, each leaving the full suite green — never a big-bang rewrite
of the fragile area. The "parallel then remove" shape means the model runs
*alongside* the existing pushes first (no-op guards make double-application
safe), and old paths are deleted only once the model path is proven.

1. **Introduce** `EditorControl` + `EditorCoordinator.applyControl` + the
   `withObservationTracking` bridge. Wire `ProjectWindow` to own + mirror into
   the model and hand it to `attach`. Existing `updateNSView` pushes and
   notifications **stay active in parallel.** Suite green.
2. **Posture onto the model**; delete `maughamReviewPostureResolved` and the
   coordinator's posture push from `updateNSView`. Verify the original bug
   (edit-own-doc-on-open) via the new unit bridge test + smoke.
3. **Appearance onto the model**; remove the appearance/typewriter/focus pushes
   from `updateNSView`. Verify theme/typography/typewriter still apply.
4. **Annotation set onto the model**; collapse `maughamReviewAnnotationsChanged`
   and the coordinator's `maughamToggleReviewMode` observation. Verify review
   authoring marks/rail update without a toggle.
5. **Shrink `updateNSView`** to text + frame + gutter; delete dead control code
   and the now-unused `EditorSurface` control props. Full suite + manual smoke.

## Testing strategy

- **New** `EditorControlBridgeTests` (Mac): mutate an `EditorControl` handed to a
  coordinator and assert the membrane/appearance/annotation state follows —
  **with no key window and no notification**. (A bonus the notification approach
  couldn't get: the control-plane path is fully unit-testable; the
  key-window-guarded notification was smoke-only.)
- **Keep** all existing cursor/binding harness tests green throughout — they are
  the regression net for the invariants (`EditorIntegrationHarnessTests`,
  `ReviewModeMembraneTests`, `DeferredRestyleTests`,
  `WindowedTypographyEquivalenceTests`).
- **Manual smoke:** open own local doc → editable immediately (no piece switch);
  theme/typography change applies live; ⌘⌥R on/off; review authoring updates
  marks without a toggle; long-scrolled-doc typing unaffected.

## Non-goals (YAGNI)

- **Not** touching the text binding / data plane.
- **Not** folding the provider/handler wiring into the model (separate optional
  cleanup).
- **Not** building a general SwiftUI↔AppKit observation framework — one concrete
  model for one concrete seam.
- **Not** changing review-render semantics, posture policy, or appearance
  behaviour — only *how* control reaches the coordinator.

## Risks

- **Refactoring the most fragile area.** Mitigated by: the change *reduces* what
  touches the cursor path; the parallel-then-remove sequencing; and the existing
  harness suite as the net. Each step is independently revertable.
- **`withObservationTracking` re-arm correctness** (must re-arm after every fire;
  must tear down with the coordinator). Covered by the bridge unit test and a
  deinit/teardown check.
- **Discipline drift** (D1/D2) over time. Mitigated by recording both as
  invariants in `Maugham/Editor/AREA.md` alongside the existing tripwires.
