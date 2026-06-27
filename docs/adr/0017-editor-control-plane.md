# 0017 — Editor control plane: an observed model, not `updateNSView`/notifications

- **Status:** Accepted
- **Date:** 2026-06-27
- **Design detail:** `docs/superpowers/specs/2026-06-27-editor-control-plane-design.md`

## Context

The editor seam (`EditorHost → EditorSurface → EditorCoordinator`) carries two
kinds of payload with very different cadences:

- **Data plane** — the manuscript text. Already first-classed: `Document` owns
  the substrate/op-log and the coordinator binds to it directly. This is the
  stable part, *because* it has an owned model.
- **Control plane** — posture (`lockEditing` / `isReviewMode`), appearance
  (theme / typography / typewriter / focus), the review annotation set. This had
  **no owned model**. It lived as scattered `@State` on `ProjectWindow` and
  `@Environment`, and reached the AppKit coordinator by being pushed through
  `EditorSurface.updateNSView`, patched with one-way notifications
  (`maughamToggleReviewMode`, `maughamReviewAnnotationsChanged`,
  `maughamReviewPostureResolved`).

A 2026-06-27 investigation root-caused a "can't edit my own document on open
until I switch binder pieces" bug to this: instrumentation proved
`updateNSView` is driven by AppKit **layout passes, not SwiftUI body
re-evaluation**. The body chain re-evaluated correctly when the async iCloud
role resolve flipped `.unknown → .author`, but `updateNSView` did not fire (no
layout pass), so the resolved posture stranded until a layout-triggering
interaction. The class affects *every* control payload delivered only through
`updateNSView`; posture was the only one that surfaced it because it is the only
payload that changes from an async background resolve rather than from a user
interaction that *itself* triggers layout. The accreting notifications were the
symptom: each was a bypass for "this payload needed to reach the coordinator off
a layout pass."

## Decision

Give the control plane a first-class owned model — an `@Observable
EditorControl` (posture + appearance + review annotation set) — that
`ProjectWindow` owns and is the sole writer of, and that the `EditorCoordinator`
**observes directly** via Observation's re-arming `withObservationTracking`
(pure AppKit-side; no view layer; not layout-gated).

The standing rule for this seam:

> **Editor control state flows through `EditorControl`. It does not ride
> `updateNSView`, and it does not get a new notification.** Adding a control
> signal means adding a property to `EditorControl`, not a prop to
> `EditorSurface`/`updateNSView` or a `Notification.Name`.

`updateNSView` is reduced to genuinely layout-coincident concerns (the text
binding check — still cloud-conflict-only — plus frame/gutter). The text/data
plane is untouched.

Two invariants keep it fast and safe:

- **D1** — `EditorControl` contains only control state, never text- or
  cursor-derived values (else observation fires on the keystroke hot path).
- **D2** — the coordinator's `applyControl` stays per-sub-area no-op-guarded.

## Consequences

- **The cursor-critical path shrinks.** Control leaves `updateNSView`, so the
  most fragile path is touched by strictly less. This *reduces* risk relative to
  the status quo; it does not add to it. The existing cursor/binding invariants
  (single writer; `applyExternalText` cloud-conflict-only — tripwire 7; one-way
  only — tripwires 2/6) are preserved, and the harness suite remains the net.
- **Three review notifications collapse into one observed model.**
  `maughamReviewPostureResolved` is deleted; the ⌘⌥R menu command
  (`maughamToggleReviewMode`) now only flips a model property and the coordinator
  stops observing it directly (removing the documented dual-source-of-truth);
  `maughamReviewAnnotationsChanged` collapses into the model's annotation set.
- **Posture/appearance propagation becomes unit-testable** without a key window
  or a posted notification (the prior notification path was smoke-only because of
  its key-window guard).
- **A small hot-path win:** the per-keystroke control bookkeeping that ran inside
  the `displayText`-driven `updateNSView` (appearance/posture/typewriter/focus
  compares + setters) leaves the keystroke path. Observation fires only on rare
  control events.
- **Relationship to other records:** this is the control-plane analogue of the
  data-plane move recorded as *document-first-class* (`Document` owns text). It
  reinforces tripwires 2/6/7 in `Maugham/Editor/AREA.md`, where D1/D2 and the
  "no new control notification / no control via `updateNSView`" rule are recorded
  alongside them.
- **Scope held deliberately small (YAGNI):** the provider/handler *wiring*
  closures are not folded into the model (they are set-once, non-stateful, not
  `Equatable`); the text binding is not touched; no general SwiftUI↔AppKit
  observation framework is built — one concrete model for one concrete seam.
- Implemented incrementally (parallel-then-remove) under the existing test net;
  see the design doc for the sequencing.
