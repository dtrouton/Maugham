# Issue #34 — Flick age measures the gesture, not our processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A flick's staleness is judged by the WRITER'S event timestamps, so a main-thread hitch can no longer eat a real flick — and the five coast-dependent mounting tests become deterministic under any machine load (the CI flake class in issue #34 dies at the root instead of being restaged around).

**Architecture (research 2026-08-12, superseding the issue's assumed mechanism):** flick VELOCITY is a pure position delta and already deterministic; the load-sensitive term is the age guard — `CanvasInteraction.maximumFlickAge` (100ms) compared across times stamped at *processing* time (`update`/`end`'s `now:` parameters default to `CACurrentMediaTime()` and production passes neither). Fix: the event seam carries a timestamp — AppKit's overrides pass `event.timestamp` (same clock base as `CACurrentMediaTime`, seconds since boot), the seam methods default it for compatibility, `handleDrag` forwards it into `interaction.update(…, now:)` and `interaction.end(now:)` — and the test harness's `drag` helper stamps synthetic times one frame apart, so the age is ~16ms regardless of scheduling. `CanvasInteraction` itself does not change.

**Tech Stack:** Swift/AppKit/SwiftUI, Mac scheme. Production: `CanvasEventView.swift`, `CanvasView.swift`. Tests: the mounting family harness + one new discriminating test.

## Global Constraints

- Branch: `claude/issue-34-flick-timestamps` off `main`.
- `CanvasInteraction.swift`'s `update(to:in:now:)`/`end(now:)` signatures are already right — do NOT change them; the change stops at the view/seam layer. `maximumFlickAge`'s value does not move.
- Canvas-area tripwires bind: no change to undo brackets (32), to the event view's layer order or focus rules (27), to membership (31). The seam's existing `Bool` parameter and `CanvasDragPhase` semantics are untouched — the timestamp is ADDED, nothing repurposed.
- Iteration command: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/CanvasViewMountingSurfaceTests -only-testing:MaughamTests/CanvasViewMountingEditingTests -only-testing:MaughamTests/CanvasInteractionTests` (the mounting classes cost ~70s total — that is the price of this task's subject; run the narrower `-only-testing:…/test_name` forms while iterating). Full gate `./scripts/test.sh full` before merge.
- Never touch `Maugham.xcodeproj/`/`project.yml`; no new files.
- OUT OF SCOPE, deliberately: the two press-stops-a-coast tests' opposite-edge fragility (`< 82` preconditions — frame-count-in-wall-time variance, a different mechanism timestamps cannot fix; note it on the issue at close, do not touch it here); any restage loop (the point of this fix is to not need one); `MCPColdStartTests` (pattern source only).

---

### Task 1: The timestamp seam, the forwarding, the harness stamps, and the discriminating test

**Files:**
- Modify: `Maugham/Canvas/CanvasEventView.swift` (`onDrag` closure type ~line 45; seam methods `applyMouseDown`/`applyMouseDragged`/`applyMouseUp` ~lines 275-291; AppKit overrides `mouseDown`/`mouseDragged`/`mouseUp(with:)` ~lines 315-325)
- Modify: `Maugham/Canvas/CanvasView.swift` (`handleDrag` — forward the time into `interaction.update(to:in:now:)` at ~line 1946 and `interaction.end(now:)` at ~line 1988; the closure wiring site that sets `onDrag`)
- Modify: `Maugham/Canvas/CanvasInteraction.swift` (ONLY the stale doc comment at lines ~49-57 — the "band assertion guards the tight direction" paragraph — which describes the mounted family's blind spot this task closes; rewrite it to say the live surface now carries event timestamps and the mounted tests pin plausible ones)
- Modify: `MaughamTests/Canvas/CanvasViewMountingTests.swift` (`drag(_:from:through:)` ~lines 404-418 — stamp synthetic times; its "No pumping between the samples" doc comment becomes about the STAMPS, not about runloop discipline)
- Test: `MaughamTests/Canvas/CanvasViewMountingSurfaceTests.swift` (one new test beside the flick test)

**Interfaces:**
- Produces: `onDrag: ((CGPoint, CanvasDragPhase, Bool, TimeInterval) -> Void)?`; seam methods gain `timestamp: TimeInterval = CACurrentMediaTime()` as their LAST parameter (defaulted, so any caller not passing one keeps exactly today's behavior); the AppKit overrides pass `event.timestamp`.

- [ ] **Step 1: Write the failing discriminating test**

Beside `test_aFlickCarriesTheCardOnPastWhereThePointerLetGo`:

```swift
    /// Issue #34's root, pinned: the flick's age must measure the WRITER'S
    /// gesture, never our processing. The samples here are stamped one frame
    /// apart — a fast, real throw — while the RUNLOOP stalls far past
    /// `maximumFlickAge` between the last two deliveries, which is exactly
    /// what a loaded machine does. Before the seam carried timestamps, the
    /// age was measured across our own stall and the guard ate the flick
    /// (the card stopped dead at 40 — CI run 31627910133's sibling
    /// signature); with event time on the seam, the stall is invisible.
    func test_aProcessingStallBetweenTheLastTwoSamplesDoesNotEatTheFlick() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        let t0 = CACurrentMediaTime()
        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 1, timestamp: t0)
        events.applyMouseDragged(to: CGPoint(x: 70, y: 40), timestamp: t0 + 1.0/60)
        events.applyMouseDragged(to: CGPoint(x: 80, y: 40), timestamp: t0 + 2.0/60)
        // The machine hitches: far longer than maximumFlickAge passes on the
        // wall clock between the last two DELIVERIES…
        pump(CanvasInteraction.maximumFlickAge * 2)
        // …but the RELEASE is stamped one frame after the last sample, which
        // is what the writer's hand actually did.
        events.applyMouseUp(at: CGPoint(x: 80, y: 40), timestamp: t0 + 3.0/60)
        pumpUntilSaved()

        let node = try XCTUnwrap(savedScene(after: window, root: root).node(scrapID))
        XCTAssertEqual(node.origin.x, 87.8, accuracy: 1.0,
                       "the stall between deliveries ate the flick — the age "
                       + "guard is reading OUR clock, not the writer's gesture")
    }
```

(If `maximumFlickAge` is not visible to the test target, use `0.2` with a comment naming the constant it doubles. The pump between the last dragged and the up is the load simulation — deterministic, not probabilistic.)

- [ ] **Step 2: Run it — expect FAIL at compile** (no `timestamp:` parameter exists). Add the seam parameters (Step 3's `CanvasEventView` half only), re-run — expect FAIL at the assertion: the card stops at 40, because production still stamps at processing time. That RED is the defect, reproduced deterministically.

- [ ] **Step 3: Implement the seam and the forwarding**

`CanvasEventView.swift`:

```swift
    var onDrag: ((CGPoint, CanvasDragPhase, Bool, TimeInterval) -> Void)?
```

```swift
    func applyMouseDown(at point: CGPoint, clickCount: Int,
                        timestamp: TimeInterval = CACurrentMediaTime()) { … onDrag?(point, .began, …, timestamp) … }
    func applyMouseDragged(to point: CGPoint,
                           timestamp: TimeInterval = CACurrentMediaTime()) {
        guard isDragging else { return }
        onDrag?(point, .changed, false, timestamp)
    }
    func applyMouseUp(at point: CGPoint,
                      timestamp: TimeInterval = CACurrentMediaTime()) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(point, .ended, false, timestamp)
    }
```

(Adapt `applyMouseDown`'s body to its real shape — the pattern is: the timestamp rides last, defaulted. Every seam caller that passes nothing behaves exactly as today.) The AppKit overrides pass `event.timestamp`:

```swift
    override func mouseDragged(with event: NSEvent) { …applyMouseDragged(to: p, timestamp: event.timestamp)… }
```

`CanvasView.swift`: `handleDrag` gains the timestamp from the closure and forwards it — `interaction.update(to: contentPoint, in: &$0, now: timestamp)` and `interaction.end(now: timestamp)`. Every other `handleDrag` consumer of the phase/point is untouched. If `handleDrag` has arms that call neither `update` nor `end` (region sweeps, resizes), they simply ignore the time — do not thread it further than the two interaction calls.

`CanvasInteraction.swift` doc comment (lines ~49-57): rewrite the "the band assertion guards the tight direction" paragraph — the mounted tests now stamp one-frame-apart event times and the live surface carries `event.timestamp`, so the blind spot it describes is closed; the band test remains the pure-unit pin on the boundary's exact position.

- [ ] **Step 4: Stamp the harness**

`CanvasViewMountingTests.swift` `drag`:

```swift
    /// A press, an optional path, and a release, through the same seam the
    /// AppKit overrides call — stamped one frame apart, because the age
    /// guard reads EVENT time (issue #34): the machine's scheduling between
    /// these calls is invisible to the flick, exactly as a real writer's
    /// hitch-free gesture is what these tests stage.
    func drag(_ events: CanvasEventNSView,
              from start: CGPoint,
              through path: [CGPoint]) {
        var t = CACurrentMediaTime()
        events.applyMouseDown(at: start, clickCount: 1, timestamp: t)
        for point in path { t += 1.0/60; events.applyMouseDragged(to: point, timestamp: t) }
        events.applyMouseUp(at: path.last ?? start, timestamp: t + 1.0/60)
    }
```

- [ ] **Step 5: Run the coast family + the interaction unit suite**

Run: the Global Constraints iteration command, plus `-only-testing:MaughamTests/CanvasViewMountingRegionTests` once (the seam signature touched every consumer). Expected: all pass, including the new test (GREEN), the original flick test, the two press-stops-a-coast tests, the two undo-coast tests, and `CanvasInteractionTests` untouched-and-green (`test_theFlickStalenessBoundaryIsWhereItSaysItIs` drives `now:` directly and must not need changes).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasEventView.swift Maugham/Canvas/CanvasView.swift Maugham/Canvas/CanvasInteraction.swift MaughamTests/Canvas/CanvasViewMountingTests.swift MaughamTests/Canvas/CanvasViewMountingSurfaceTests.swift
git commit -m "fix(canvas): the flick's age measures the gesture, not our processing (#34)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: AREA.md + full gate

**Files:**
- Modify: `Maugham/Canvas/AREA.md` — wherever the flick/momentum machinery is documented (search `maximumFlickAge` / momentum), one tight sentence: the age guard reads event timestamps as of issue #34, so a processing hitch cannot eat a flick, and the mounted tests stamp one-frame-apart times.

- [ ] **Step 1:** Add the sentence in AREA.md's voice.
- [ ] **Step 2:** Run `./scripts/test.sh full` (timeout 600000) — green, no skips expected. If it fails, capture and report BLOCKED; do not commit.
- [ ] **Step 3:** Commit:

```bash
git add Maugham/Canvas/AREA.md
git commit -m "docs(canvas): record the event-time flick age (#34)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes

- The issue's literal fix-shape (restage) is deliberately NOT implemented — Denver's 2026-08-12 ruling chose the deterministic seam fix after research showed the velocity is already deterministic and the age guard was the real mechanism; record that on the issue at close, along with the out-of-scope note about the `< 82` opposite-edge preconditions (frame-count variance, untouched).
- Type consistency: the seam signature (`timestamp: TimeInterval = CACurrentMediaTime()`, last parameter) is spelled once in Task 1 and used identically in the harness and the new test.
- The two "so nothing flicks" drags and every region/resize drag are immune by construction (zero delta / non-moving modes) and are not touched.
