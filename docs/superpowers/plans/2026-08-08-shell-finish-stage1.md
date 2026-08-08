# Shell Finish Plan 1 — the width and the strip

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The two daily annoyances die first: the right column holds one writer-owned width through every persona and pane switch, and a segment strip with one option never renders.

**Architecture:** Spec `docs/superpowers/specs/2026-08-08-shell-finish-design.md` §2/§5/§9 stage 1. Task 1 is diagnose-then-fix: the detail column has ONE `navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)` (`ProjectWindow.swift:1359`), so the shifting is almost certainly the split view resetting to `ideal` when the detail content's view identity changes across personas/panes — the fix is a persisted width driving `ideal` plus stable identity (or a custom divider if SwiftUI won't hold it; the task carries both routes). Task 2 hides the choiceless picker.

**Tech Stack:** Swift 6 / SwiftUI, XCTest.

## Global Constraints

- Contracts not bodies; TDD; `./gen.sh` if files added; flat `-only-testing`; Release build (ProjectWindow); commit register; **no push**.
- The width is writer-owned: persisted per window in ui-state (additive field, decode-defaulted, NO schema bump — extend the encoder census), min/max clamps stay.
- The strip rule is the spec's interim: a picker exists only where a real choice exists; the full tree (stage 2) makes it permanent. The transient cases (find/trash appearing) must still SHOW the picker when they make the choice real — the rule is about the choice count, not the persona.
- Subagent models: opus task 1 (SwiftUI diagnosis), sonnet task 2; reviewers haiku/sonnet.

---

### Task 1: One width, held

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift:1355-1361` (the detail column), `Maugham/Stores/UIState.swift` (the field), possibly `Maugham/Views/DetailPaneToggle.swift` (identity)
- Test: `MaughamTests/DetailColumnWidthTests.swift` (new)

**Contracts:**
- [ ] DIAGNOSE FIRST, in the report: reproduce the reset (persona switch, pane switch) in a minimal harness or by reasoned trace of the identity change; name the mechanism before fixing (systematic-debugging's rule — the fix must match the found cause, not the symptom).
- [ ] `UIState.detailColumnWidth: Double?` (additive; nil → the current 280 default; clamped 240…480 on read — widen max from 360: a writer-owned width may be wider than today's cap, and the clamp is the safety); encoder census extended.
- [ ] The split view's `ideal` reads the persisted value; the detail content's identity is stabilized so a persona/pane switch does not re-apply defaults (whatever the diagnosis found — stable `id`, a single container view, or a custom divider as last resort; the report defends the route).
- [ ] Capturing the writer's drag: SwiftUI exposes no direct dragged-width callback — the known honest routes are a GeometryReader observation writing back to ui-state (debounced), or the custom divider. Whichever ships, the write-back must not fight the persisted value (no feedback loop: `test_aPersonaSwitchDoesNotWriteTheWidth`).
- [ ] Tests: width survives persona round-trip (mount, set width, switch all four personas, assert geometry unchanged — the mounted-view discipline; note CI runner parity per CLAUDE.md build-flow); width survives pane switch; persists across store round-trip; clamps.
- [ ] Release build; commit.

### Task 2: A choiceless picker renders nothing

**Files:**
- Modify: `Maugham/Views/BinderSegmentPicker.swift` (or its two callers `BinderPaneToggle.swift:20`/`CollectionBinderPaneToggle.swift:28` — pick the single spelling: the picker itself owns the rule so a third caller cannot forget it)
- Test: `MaughamTests/BinderSegmentPickerTests.swift` (find the existing suite; extend)

**Contracts:**
- [ ] `segments.count <= 1` → the picker renders nothing (no empty bar, no reserved height — the tree's header sits flush where it stood; assert layout, not just absence).
- [ ] A transient joining (find activated, trash non-empty) makes the choice real → the picker APPEARS with it, and disappears when it leaves — both directions.
- [ ] Plan (four segments) unchanged; Author/Review/Publish (one segment) show no strip — per-persona assertions via the registry, not literals.
- [ ] AX: the segments remain reachable by their commands when the picker is hidden (⌘⌥F/trash flows unaffected — delivery-path check on one of them).
- [ ] Release build; commit.

---

Whole-branch review (small branch, still mandatory — sixteen consecutive finds); merge unpushed; ledger + handoff line. Stages 2–3 planned after this builds (rule 11).
