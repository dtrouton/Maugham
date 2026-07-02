# 0021 — Window events are scoped at the post site (typed event bus over NotificationCenter)

- **Status:** Accepted (implementation queued — see
  `docs/superpowers/specs/2026-07-02-scoped-window-events.md`)
- **Date:** 2026-07-02

## Context

`NotificationCenter` grew into the app's de-facto internal bus: **39 custom
`maugham.*` notification names, ~60 post sites, ~54 receivers** (2026-07-02
survey). The traffic falls into three natural scope classes:

1. **Key-window commands** (~25 names — `toggleInspector`, `save.checkpoint`,
   `find.in.project`, `open.rewind`, `promote.piece`, …). These exist because
   SwiftUI menu `Commands` can't reach window state directly; the intended
   receiver is *the key window only*.
2. **Document/project data events** (~8 — `opLogChanged`, `checkpointAdded`,
   `script.did.update`, `inboxChanged`, `mcp.note.added`, …). Intended
   receivers: *windows presenting that document/project*.
3. **Genuinely global** (~6 — `appWillTerminate`, `effective.appearance.changed`,
   `openProject`, …).

For classes 1 and 2, delivery scoping is a **per-receiver, hand-written
convention** (`guard window?.isKeyWindow == true`, or a userInfo comparison).
`NotificationCenter`'s API makes the wrong thing frictionless — `post(name:)`
requires no scope and `onReceive` filters nothing — so broadcast-to-all-windows
became the *default* flow and correct scoping an act of per-site remembering.

That defect class has now shipped at least three times:

- **History-rewind milestone (2026-05-21):** `open.rewind` had to be
  retrofitted with multi-window scoping.
- **`script.did.update` (found 2026-07-02):** posted unscoped from every
  screenplay re-tokenize; every `ProjectWindow` overwrote its own
  `lastParsedScript` from any window's screenplay. With a large screenplay
  window open, an unrelated Collection window's piece flip triggered a ~1s
  whole-window relayout of the big editor (main-thread stall visible as a
  "Loading…" pause), and silently clobbered the other window's scene-navigator
  payload.
- **`toggleInspector` (found 2026-07-02, unfixed at time of writing):** the
  receiver at `ProjectWindow.swift:185` has no key-window guard — with two
  project windows open, ⌘⌥I toggles the inspector in **both**.

## Decision

**Scope is declared where the event is posted, enforced by types — not
remembered where it is received.** A thin typed layer over NotificationCenter:

```swift
MaughamEvent.post(.toggleInspector, to: .keyWindow)
MaughamEvent.post(.scriptDidUpdate(script), to: .document(docId))
MaughamEvent.post(.appearanceChanged, to: .allWindows)
```

- Every post names a destination: `.keyWindow`, `.document(docId)`,
  `.project(url)`, or `.allWindows`. There is no unscoped post.
- Matching receive modifiers (`.onKeyWindowCommand(_:)`,
  `.onDocumentEvent(_:docId:)`, …) implement each filter **once**, in the
  subscription helper — not in 54 receiver closures.
- The layer is NotificationCenter underneath (userInfo carries the scope), so
  old and new coexist and the 39 names migrate incrementally.
- **A tripwire test enforces it** (house style — cf. tripwire 13, the ADR 0018
  annotation guard): a raw `NotificationCenter.default.post` of a `maugham.*`
  name outside the wrapper fails CI, with a planted-offender self-test. The
  fourth occurrence of this bug becomes unwritable, not merely unlikely.

Rejected alternatives:

- **Per-window `NotificationCenter` instances** — structural isolation, but the
  menu-command class inherently needs a router to the key window, so a routing
  layer is required anyway; and data events legitimately fan out to several
  windows showing the same project. Wrong tool for both dominant classes.
- **Replace NC with direct `@Observable` observation** — right long-term shape
  for the *data-event* class (the ADR 0017 control plane demonstrates it), but
  useless for menu commands. May be adopted opportunistically per event later;
  it composes with, rather than replaces, this decision.

## Addendum (2026-07-02) — liveness is part of delivery scope

Scope filtering alone does not exclude **closed** windows: SwiftUI's
`WindowGroup` scene storage retains a closed window's view graph (verified —
no ARC cycle on our side), so a zombie receiver for project A still *matches*
a legitimate project-A-scoped event and does real work handling it. The
receive helpers therefore also carry a **liveness guard** (drop delivery when
the receiving view has no live window), making the milestone's guarantee "a
closed window receives nothing," not merely "receivers only get their own
events." Actually *releasing* the retained graph is framework behavior and
stays out of scope beyond a timeboxed spike (see the spec) — with the guard,
zombies are inert and deaf; the residual is bounded memory.

## Consequences

- Posting an event forces the author to answer "who is this for?" at compile
  time; the reviewer sees the answer in the diff.
- The key-window filter and document filter exist in exactly one place each.
- `toggleInspector`'s double-window bug is fixed by the migration itself (its
  class is `.keyWindow`).
- The `script.did.update` scoping shipped tactically ahead of this ADR (on the
  op-log-spine-hardening branch) is absorbed into the wrapper when its name
  migrates.
- Receivers keep working during migration; each name moves in one small,
  testable commit. Mechanical bulk suits haiku-grade subagent passes.
- New cost: one more house pattern to know. Mitigated by the tripwire pointing
  violators at the wrapper, and the wrapper being ~a screen of code.
