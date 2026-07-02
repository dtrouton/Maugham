# Scene-storage release spike — outcome (ADR 0021, Task 12)

**Date:** 2026-07-02
**Branch:** `feat/adr-0021-scoped-window-events`
**Timebox:** half a day, allowed to fail. An honest documented failure is the
success condition. **Do NOT restructure window presentation** (no
NSWindowController rewrite, no scene-architecture change).

## Question

Does anything *cheap* make SwiftUI actually release a closed project window's
view graph? `WindowGroup(id: "project", for: URL.self)` (`MaughamApp.swift:231`)
retains a closed window's scene storage — verified 2026-07-02, **no ARC cycle on
our side** (see `Maugham/Editor/AREA.md` effective-appearance bullet,
`EditorCoordinator.detach()` doc comment, and
`docs/superpowers/notes/2026-07-02-window-teardown-audit.md`). With the ADR 0021
liveness guard shipped on this branch, a closed window's coordinator is inert AND
deaf (`MaughamEvent.isLive` drops every scoped delivery; `receiverContext`
returns nil once `isDetached`). The residual is bounded RAM. This spike probes
whether a cheap lever releases that RAM.

**Success metric:** a weak ref to a CLOSED window's `EditorCoordinator` goes nil
without app quit.

## What is / isn't observable here

The success metric requires the **SwiftUI scene lifecycle** (open a window, close
it, watch the graph). That lifecycle is **not drivable from an XCTest host** — an
XCTest can't stand up an `App`/`WindowGroup` and close a scene the way the running
app does. So the spike splits into two halves:

1. **ARC-side claim (headlessly verifiable):** "the leak is SwiftUI scene
   retention, not our own retain cycle." Pinned by
   `MaughamTests/EditorCoordinatorReleaseTests.swift` (green — see below).
2. **Scene-release claim (manual only):** "does closing the window free the
   coordinator, with/without each lever." Requires the running GUI app. The
   dev-build-only `CoordinatorLeakProbe` + **View → Dump Coordinator Leak Probe
   (dev)** menu item are the instrument; the manual recipe is below. Numbers are
   left for the user to run — this note does not claim scene-release results it
   cannot observe.

## Headless result (ARC side) — PASS

`EditorCoordinatorReleaseTests`:

- `test_coordinatorReleasedWhenLastStrongRefDrops` — a coordinator created and
  `attach()`-ed, with its text view still alive, is released the moment its last
  *external* strong reference drops. Proves **no internal retain cycle**: the
  text view holds the coordinator only weakly (`NSTextView.delegate` and
  `MaughamTextView.coordinator` are both weak), and the ~30 `[weak self]`
  captures + observer tokens add none. If this failed, the post-close leak would
  be *our* bug, fixable in our code — it doesn't, so it isn't.
- `test_detachedCoordinatorStillReleased` — `detach()` (nils `textView`, cancels
  the three async Tasks, removes the five observer tokens) adds no cycle: a
  detached coordinator is still freed when its last strong ref drops. This is the
  ARC basis for "detach() neutralises the zombie."

(Full-dealloc of the `NSTextView` itself is intentionally NOT asserted: TextKit
retains the view through its own layout-manager/text-storage graph independent of
our edge, so a dealloc assertion is a TextKit artifact, not a signal about our
code. The coordinator→textView release on `detach()` is already pinned by
`EditorAppearanceChangeTests.test_detach_releasesViewAndSilencesRestyle`.)

**Takeaway:** the retention is entirely on SwiftUI's side of the boundary. No
change to our code can force it; only a SwiftUI-level lever could.

## Attempts (the three cheap levers)

### Attempt 1 — clear the presented value on close (`$url = nil` / `dismissWindow(id:"project", value:url)`)

**Status: prepared as a runnable recipe against the probe; NOT left as compiled
speculative code.** Rationale: the lever is a behavioural change to window
presentation that can only be *judged* by the manual probe run, and the brief is
explicit — prepare instrumentation + document steps rather than ship unverified
behavioural code (which would also be dead experiment code the timebox says to
delete). The probe is the compiled instrument; the lever is a two-line diff the
user (or the next dev) applies to run the definitive A/B:

```swift
// ProjectWindow.swift — add to the environment reads:
@Environment(\.dismissWindow) private var dismissWindow
// …and in the existing .onDisappear, after the close()/unregister:
.onDisappear {
    mcpRegistry.unregister(url: url)
    Task { await documentStore?.close() }
    dismissWindow(id: "project", value: url)   // ← attempt 1
}
```

**Expected outcome (strong prior, to be confirmed by the probe):** no release.
`WindowGroup(id:for:)` scene storage is keyed by the presented value and pooled
for reuse across the app's lifetime; `dismissWindow` (and clearing the binding)
*closes/hides* the window but does not deterministically drop the backing scene
storage — this is the documented framework behaviour the whole ADR 0021 addendum
is premised on. The manual run either confirms framework-cost (live stays 1) or,
if SwiftUI has changed, is a cheap win (live → 0); the probe reads it either way.

### Attempt 2 — nil heavy `@State` in `.onDisappear` (shrink the zombie's footprint)

**Status: assessed, not adopted. Marginal, and largely already done.** The
dominant retained cost is the coordinator + `NSScrollView→NSTextView→NSTextStorage`
graph, which this lever does **not** touch (the graph is owned by the retained
view tree, not by a nil-able `@State`). Of the heavy `@State` on `ProjectWindow`:

- `documentStore` — already released in effect: `.onDisappear` calls
  `documentStore?.close()` (ends the session, flushes the pending save, removes
  the file presenter). The reference itself rides the retained view graph, but
  its *live* resources are freed on close.
- `lastParsedScript: FountainScript?` — a value type; nilling it in `.onDisappear`
  would let the retained `FountainScript` (parsed screenplay AST) free early. For
  a large screenplay this is real but bounded bytes, and it does nothing for the
  editor graph that dominates the footprint. Nilling `@State` you're about to
  leak anyway is a code smell that buys a fraction of the residual.

Verdict: not worth a permanent behavioural wrinkle. If a future footprint pass
shows the parsed AST is a material share of the zombie, revisit — but the lever
shrinks, never releases, so it doesn't move the success metric.

### Attempt 3 — `NSWindow.isReleasedWhenClosed` / `window.contentView = nil` via the cached `WindowAccessor` ref

**Status: REJECTED as unsafe and out-of-scope. Not attempted in code.** The
`NSWindow` for a `WindowGroup` scene is **owned and lifecycle-managed by SwiftUI**.
Forcing `isReleasedWhenClosed = true` on it invites a double-free/crash (SwiftUI
still holds and may re-touch the window after close), and nil-ing `contentView`
tears out SwiftUI's hosting view from under it. Both fight the framework's window
management rather than cooperating with it — that is *restructuring window
presentation*, which this task's hard rule forbids, and neither is "cheap." The
existing headless test `EditorCoordinatorCycleTests.test_maughamNavigateToScene`
sets `isReleasedWhenClosed = false` on its *own* manually-created `NSWindow` for
exactly the opposite reason (to keep a test window alive) — that's a test-owned
window, not a SwiftUI-managed scene.

## Footprint methodology (user-to-run — no GUI numbers claimed here)

Per the perf-milestone recipe. **Stage a large fixture** (the probe recipe reads
screenplay chunks from `/tmp/maugham-perf-probe/`; see
`docs/superpowers/plans/2026-06-10-typing-perf.md` step 1 and
`docs/superpowers/notes/2026-06-10-typing-perf-baseline.md`). A ~250pp
single-file screenplay (or ~140pp+, as used in the typing-perf live samples) is
the intended stress fixture.

Baseline vs. each lever, in a **dev build**:

1. Launch the dev app; note the pid (`pgrep -f Maugham` or Activity Monitor).
2. Open the large-fixture project → the editor mounts a coordinator (probe now
   `live=1 total=1`; confirm via **View → Dump Coordinator Leak Probe (dev)**,
   read the `[spike] CoordinatorLeakProbe: live=… total=…` line in Console.app /
   Xcode).
3. `footprint <pid>` (or Xcode's Memory gauge) → record RSS baseline-with-doc.
4. Close the project window (⌘W or red button). Let the run loop turn (a few
   seconds; switch away and back).
5. **Dump the probe again.** `live` still 1 ⇒ the coordinator (and its graph) is
   retained — **framework cost confirmed**. `live` → 0 ⇒ SwiftUI released it.
6. `footprint <pid>` again → the delta from step 3 is the per-closed-window
   residual (the bounded RAM the liveness guard leaves inert).
7. To measure a lever: apply the Attempt-1 diff above, rebuild, repeat 1–6; the
   `live` count after step 4 is the verdict for that lever.

`footprint`/`sample <pid>` on the live app is the verification method of record
for this class of question (headless probes can't see scene retention), exactly
as the typing-perf milestone found for its per-keystroke costs.

## Instrumentation kept (dev-build only, justified)

- `Maugham/Editor/CoordinatorLeakProbe.swift` — whole file `#if MAUGHAM_DEV_BUILD`.
  A weak registry of every `EditorCoordinator`; `snapshot()` / `dump()` report
  `(live, total)`. Absent from stable, so it can never hold a coordinator alive
  in a shipping build.
- `EditorCoordinator.init` — one dev-gated line registering `self` with the probe.
- `MaughamApp.swift` — a dev-gated **View → Dump Coordinator Leak Probe (dev)**
  menu item calling `CoordinatorLeakProbe.dump()`.

These EARN their keep: they are the *only* way to read the success metric (the
scene-release half is manual), and the brief explicitly asks to prepare exactly
this instrument. Everything else (the three levers) is documented above rather
than left as compiled experiment code.

## Measured outcome (2026-07-02, manual run — loop closed)

Run on macOS 26.5, dev build `88e4d2b`, 174 KB / 400-scene single-file
screenplay fixture, window closed via ⌘W. Instrument: `heap <pid>` instance
counts (`EditorCoordinator`, `Document` under `Maugham.debug.dylib`) +
`footprint <pid>` — note `heap` works WITHOUT the in-app probe menu, so it is
the scriptable instrument of record; `CoordinatorLeakProbe` remains the
in-app/Console option.

| Step | live `EditorCoordinator` | live `Document` | phys_footprint |
|---|---|---|---|
| Project open | 1 | 1 | 150 MB |
| ⌘W (close window) | **1 — retained** | 1 | 112 MB |
| Reopen SAME project | **2 — new instance minted** | 2 | 125 MB |
| ⌘W again | **2** | **2** | 150 MB |

Three findings:

1. **Scene retention confirmed** — the closed window's coordinator (and its
   Document) survive ⌘W indefinitely. The ADR 0021 premise holds as measured.
2. **The retained scene is NOT reused.** Reopening the *same* URL mints a
   fresh coordinator/Document; the old pair stays stranded. Retention buys
   nothing — it is pure waste, not a warm cache.
3. **The residual is monotonic across open/close cycles, not bounded.** One
   stranded coordinator+Document pair per cycle; footprint suggests roughly
   tens of MB per cycle at this fixture size (noisy — window-server/graphics
   memory dominates the swings; the instance counts are the reliable signal).
   A writer repeatedly opening and closing a large project in a long-lived app
   session accumulates stranded editor graphs. With the liveness guard they do
   NO work — this is RAM only — but "bounded residual" in the ADR addendum
   understated it; the addendum has been corrected.

Attempt 1 (`dismissWindow` lever) remains un-run — finding 2 lowers its odds
further (SwiftUI isn't holding the storage for reuse, so a dismiss hint seems
unlikely to trigger release), but the A/B recipe stands if anyone wants the
definitive answer. **The accumulation finding upgrades the future
explicit-window-hosting milestone from "if footprint ever matters" to "worth
scheduling if long-session RAM complaints appear"** — the trigger to watch is
Activity Monitor creep after a day of opening/closing big projects.

## Retain-root trace + prior art (2026-07-02, follow-up)

`leaks <pid> --trace=<coordinator addr>` (address from
`heap <pid> -addresses EditorCoordinator`) gives the exact roots for the
stranded coordinator — no more inference:

1. **PRIMARY: `static GraphHost.sharedGraph` (SwiftUICore `__DATA_DIRTY`) →
   AGGraphStorage → … → `ViewLeafView<PlatformViewRepresentableAdaptor
   <Maugham.EditorSurface>>` → `__strong value.coordinator` → EditorCoordinator.**
   SwiftUI's shared AttributeGraph keeps the dead scene's view-graph nodes
   alive after ⌘W. This is a framework-internal *static*; nothing we own is on
   the path. It also proves **`dismantleNSView` never runs on window close**
   (the representable's node is never torn down) — `detach()` fires only on
   in-window teardowns like the `.id(path)` piece flip. The liveness guard is
   unaffected: `MaughamEvent.isLive` checks `isVisible || isMiniaturized`, so
   the zombie (whose retained `@State` still strongly holds the closed
   `NSWindow`) is still correctly dropped.
2. Secondary: NotificationCenter registrar entries → the coordinator's five
   observers — not removed because neither `deinit` nor `detach()` ever ran
   (pinned by root 1). Removing them eagerly wouldn't help; root 1 suffices.

**Hypotheses tested and disproven along the way:**
- *Our `@State private var window: NSWindow?` (WindowAccessor) pins the graph*
  — NO. A/B with `window = nil` in ProjectWindow's `.onDisappear`: coordinator
  still retained (1 live after close). Reverted.
- *byla.lt-style interference (custom `NSWindowDelegate` replacing
  `SwiftUI.AppKitWindowController`, which performs close-time release)* — NOT
  our case; Maugham sets no window delegate (grep-verified).

**Prior art:** the closed-window release path exists and works in SwiftUI
(byla.lt, "This Window Is Leaking" — leaks only when the framework delegate is
replaced), but representable-under-App-lifecycle leaks on macOS have been
reported since Xcode 12 with no resolution (Charts #4555, closed "missing
info"; assorted Apple-forums threads on macOS SwiftUI memory climbing). No
public report names the `GraphHost.sharedGraph` dead-scene retention this
trace pins — worth filing a Feedback with Apple: minimal repro is any
`WindowGroup(id:for:)` window hosting an `NSViewRepresentable` whose
coordinator is strongly held by the representable's stored value; close the
window; `heap`/`leaks --trace` shows the AG root.

## Conclusion

**Documented as framework cost — needs one manual probe run to close the loop.**

- The ARC-side claim is **proven headlessly**: the leak is SwiftUI
  `WindowGroup` scene retention, not a retain cycle we own or can fix in our
  code (`EditorCoordinatorReleaseTests`, green).
- No *cheap, safe* lever is expected to release the scene storage: Attempt 1 is
  the documented framework limitation (recipe + probe provided to confirm),
  Attempt 2 shrinks-not-releases and is largely already done, Attempt 3 is
  unsafe and out-of-scope.
- With the ADR 0021 **liveness guard**, the retained graph is **inert and deaf**
  — a closed window receives nothing and does no work. The residual is bounded
  RAM per closed window, which the footprint recipe above quantifies on demand.
- **Recommendation:** keep the retention as a documented framework cost (matching
  the window-teardown audit's standing conclusion). Do NOT restructure window
  presentation to chase it; if a future footprint run shows the residual is
  material at scale, that is its own milestone (explicit `NSWindowController`
  hosting), not a spike lever.
