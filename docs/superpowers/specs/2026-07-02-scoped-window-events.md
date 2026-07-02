# Scoped window events — typed bus over NotificationCenter (ADR 0021)

- **Date:** 2026-07-02
- **Status:** Queued (next milestone after the op-log-spine-hardening branch
  lands). ADR: `docs/adr/0021-scoped-window-events.md` — read it first; the
  context, defect history, and rejected alternatives live there and are not
  repeated here.

## Goal

Every internal `maugham.*` event declares its delivery scope at the post site,
via a typed wrapper; receivers subscribe through helpers that implement each
scope filter exactly once; a tripwire makes an unscoped post fail CI.

## Design

### The wrapper (new file, `Maugham/Events/MaughamEvent.swift` — Mac target)

```swift
enum EventScope {
    case keyWindow                 // menu commands → key window only
    case document(docId: String)   // data events → windows presenting this doc
    case project(url: URL)         // data events → windows on this project
    case allWindows                // genuinely global fan-out
}
```

- `MaughamEvent.post(_ name: Notification.Name, to: EventScope, payload: [...])`
  wraps `NotificationCenter.default.post`, encoding the scope into `userInfo`
  under reserved keys (`maugham.scope.kind`, `maugham.scope.id`).
- Receive-side helpers (View extensions):
  - `.onKeyWindowCommand(_ name:) { … }` — resolves the hosting window once
    (the existing `window?.isKeyWindow == true` idiom, hoisted) and drops
    non-key deliveries.
  - `.onDocumentEvent(_ name:, docId:) { payload in … }` and
    `.onProjectEvent(_ name:, url:)` — compare the scope id, drop mismatches.
  - `.onGlobalEvent(_ name:)` — passthrough, exists so the tripwire's "every
    receiver goes through a helper" rule has no exceptions.
- **Liveness guard (in scope as of 2026-07-02):** every window-scoped helper
  (`.onKeyWindowCommand`, `.onDocumentEvent`, `.onProjectEvent`) ALSO drops
  delivery when the receiving view is no longer attached to a live window
  (`window == nil` after close). Rationale: scope filtering alone does not
  exclude CLOSED windows — SwiftUI's `WindowGroup` scene storage retains a
  closed window's view graph (verified 2026-07-02, no ARC cycle on our side),
  so a zombie receiver for project A still *matches* a legitimate
  project-A-scoped event and would do real work handling it. The key-window
  filter subsumes this for commands; the guard makes it explicit for the data
  classes. Written once, in the helpers — the ADR's whole philosophy.
  `.onGlobalEvent` deliberately does NOT get the guard by default
  (`appWillTerminate` must reach everything); audit each global receiver for
  whether a zombie handling it is harmful and note the finding per name.
- Alongside the guard, an **audit task**: verify the teardown discipline
  (`EditorCoordinator.detach()` via `dismantleNSView`, `DocumentStore`
  close/presenter-removal via `.onDisappear`) actually runs on every
  window-close path, and pin whatever of it is pinnable headlessly.
- Non-View receivers (AppKit/coordinator code using `addObserver`) get a
  matching non-View helper on `MaughamEvent` — with an explicit liveness
  contract (the owner passes a `isLive` closure or deregisters on detach; a
  coordinator past `detach()` must not act on deliveries).
- Phone target: not applicable (single-window; no `maugham.*` window bus).
  MaughamCore: no NC usage may be added there (the wrapper is Mac-side by
  design; core stays notification-free).

### Scope classification of the 39 existing names

From the 2026-07-02 survey (`grep Notification.Name` — re-verify at
implementation time; names may have shifted):

- **`.keyWindow` (~25):** `add.loose.piece`, `add.screenplay.piece`,
  `addResearchFile`, `close.find`, `dummySave`, `find.in.project`,
  `find.match.selected`, `link.project`, `named.checkpoint`,
  `navigate.to.scene`, `navigateToDocument`, `open.rewind`, `promote.piece`,
  `restore.last.deleted`, `save.checkpoint`, `set.detail.segment`,
  `shareForReview`, `show.help`, `show.syntax.help`, `showClaudeDesktopHelp`,
  `showProjectSettings`, `showProjectStatistics`, `tidyAllFilenames`,
  `toggle.research.preview`, `toggleFullScreen`, `toggleInspector`,
  `toggleNoChrome`, `toggleReviewMode`. Note some of these already carry
  hand-written key-window guards (ProjectWindow.swift has ~10) — the migration
  DELETES those guards in favor of the helper. `toggleInspector` currently has
  NO guard: fixing it is part of this class's migration (its double-window
  toggle is a live bug).
- **`.document` / `.project` (~8):** `script.did.update` (migrated from the
  tactical userInfo fix on the hardening branch), `maughamOpLogChanged`,
  `maughamCheckpointAdded`, `maughamInboxChanged`, `sessionLogChanged`,
  `mcp.note.added`, `maughamPublicationCompleted`. Pick `.document` vs
  `.project` per event by what receivers actually key on — read each receiver
  first; several already do userInfo comparisons that the helper replaces.
- **`.allWindows` (~6):** `appWillTerminate`,
  ~~`effective.appearance.changed`~~ (DELETED on fix/oplog-spine-hardening,
  2026-07-02 — NOT migrated: it was mis-classified here as global. It was the
  THIRD live instance of the unscoped-broadcast defect this branch has hit
  (after `script.did.update` and the control-plane observation, commit
  aaecd1a). `MaughamTextView.viewDidChangeEffectiveAppearance` posted it
  `object: nil` on EVERY view's first mount — i.e. every piece flip — fanning a
  whole-doc restyle to every live coordinator including leaked closed-window
  ones. Replaced with a DIRECT per-view coordinator call
  (`effectiveAppearanceDidChange()`), so there is no `maugham.*` appearance name
  left for this milestone to migrate. See `Maugham/Editor/AREA.md`.),
  `newProject`, `openProject`, `maughamTestOpenProject` (dev),
  and any name that is genuinely Welcome-window/global. Deliveries unchanged;
  they migrate for tripwire uniformity only.

Names that turn out to be posted AND received in one window only (no cross-
window traffic possible) still migrate — uniformity is what makes the
tripwire's rule simple.

### The tripwire

In `TripwireGrepTests` (house style — shared constants + planted-offender
self-test, like the ADR 0018 guard):

- Any `NotificationCenter.default.post` whose name-argument line references a
  `maugham` name, outside `MaughamEvent.swift`, fails.
- Any `publisher(for: .maugham…)` / `addObserver(forName: .maugham…)` outside
  the wrapper's helpers fails.
- Escape hatch: `// adr-0021-ok: <reason>` for the genuinely-raw cases
  (`MaughamApp.swift`'s `willTerminateNotification` bridge posting
  `.maughamAppWillTerminate`, and system-notification observers, which are not
  `maugham.*` and are out of scope).

## Plan shape (subagent-driven; mostly mechanical)

1. **Wrapper + helpers + unit tests** (scope filtering: key-window drop,
   document mismatch drop, global passthrough). Substantive.
2. **Migrate `.keyWindow` class** (biggest, most mechanical — haiku-grade with
   a per-name checklist; deletes the ~10 hand-written guards; fixes
   `toggleInspector`). Test: two-window harness asserts single-window delivery
   for a representative command; regression run of existing window tests.
3. **Migrate data events** (per-event receiver reading required; absorbs the
   hardening branch's `script.did.update` userInfo fix into the wrapper).
4. **Migrate globals + land the tripwire** (tripwire lands LAST so CI is never
   red mid-migration).
5. Docs: ADR 0021 status → Implemented; `Maugham/Views/AREA.md`-equivalent
   pointer (ProjectWindow guidance) updated; CLAUDE.md tripwire table gets a
   row.

### Spike (timeboxed, allowed to fail): releasing closed-window scene storage

Half a day, no more. Investigate whether anything cheap makes SwiftUI actually
release a closed project window's view graph (the `WindowGroup(id:"project",
for: URL.self)` retention verified 2026-07-02) — e.g. clearing the presented
value binding on close. Success = a weak ref to a closed window's coordinator
goes nil without app quit; record the measurement either way (footprint before/
after closing a large-doc window). If the spike fails, the retention stays a
documented framework cost — with the liveness guard above, zombies are inert
AND deaf, so the residual is bounded RAM only. Do NOT restructure window
presentation (explicit NSWindowControllers etc.) inside this milestone.

## Non-goals

- No change to notification *timing/semantics* — same NC delivery underneath.
- No migration of Apple system notifications (`willTerminateNotification`,
  appearance KVO, etc.) — only the `maugham.*` namespace.
- No `@Observable`-based replacement of data events in this milestone (noted in
  the ADR as a compatible future direction per event).
- No window-presentation restructuring to defeat scene-storage retention —
  spike only (above); the full fix, if ever needed, is its own milestone.

## Acceptance

- Zero raw `maugham.*` posts/subscriptions outside the wrapper (tripwire green
  with planted-offender proof).
- **Closed windows receive nothing:** per scope class, a test that closes
  window A (or tears down its harness equivalent), posts an event scoped to
  A's project/document, and asserts A's receiver never fires and no restyle/
  work counter moves.
- Two-window manual smoke: ⌘⌥I toggles ONLY the key window's inspector; a
  screenplay piece flip in window B causes no relayout/scene-navigator change
  in window A; rewind/checkpoint/find commands hit only the key window; close
  a large-doc window, then edit/flip in another — no stall, no work attributed
  to the closed window.
- Spike outcome recorded (released or documented-as-framework-cost, with
  footprint numbers).
- Full Mac + phone suites green.
