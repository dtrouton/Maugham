# The tree scrolls on a pass swap — investigation, 2026-08-18

**Status: NOT REPRODUCED. No fix shipped.** What landed is a mounted regression
suite with a positive control (`MaughamTests/TreeScrollStabilityTests.swift`) and
this record, so the next session does not re-derive eight falsified hypotheses.

## The report (Denver's smoke, with a screenshot)

In Review, **at some window sizes**, swapping the review pass from the round
cockpit's lane picker leaves the LEFT column — the binder tree — scrolled down:
the project row and the first chapters are off the top, where before the swap the
top was pinned. Nothing about a pass concerns the tree's scroll position.

## What is now known for certain

**The tree has exactly one production scroll**, and the whole app has four:

| site | what it scrolls |
|---|---|
| `BinderTreeSectionsState.consumePendingScroll` → `proxy.scrollTo(.researchHeader, anchor: .center)` | the tree |
| …`.paletteHeader`, `.center` | the tree |
| …`.row(subject)`, `.center` | the tree |
| `AnnotationsPane.scroll(to:proxy:)` → `scrollTo(piece, anchor: .top)` | the annotations queue (right column), on a **scope** change only |

`grep -rn "scrollRowToVisible\|scrollToVisible\|defaultScrollAnchor\|scrollPosition\|scrollTo("`
over `Maugham/` + `Packages/` returns those four and nothing else.

**A `.researchHeader` request produces exactly the reported picture.** Measured on
a mounted tree, 40 chapters, 380pt viewport, 1460pt of content: offset **0 →
1080** — the foot of the tree, project row and first pieces gone. So the symptom's
SHAPE is the one-shot reveal machinery's; the open question is what fires it.

**Nothing in the pass-swap path writes `scrollRequest`.** Its five writers are
⌘⌥R (`.researchHeader`), ⌘⌥P (`.paletteHeader`), the find-match handler, and the
two forced reveals (`openResearchItem`, `handleShowLatestMCPNote`). The cockpit's
picker calls `setPass` → `onSetActivePass` → `ProjectWindow.recordActivePass` →
`documentStore.updateUIState { $0.activePassMemory.record(…) }`, one line, and no
other window state moves with it.

## Falsified hypotheses — do not re-derive these

Each was driven on a mounted tree (40 chapters, content 1460pt over a 360–860pt
viewport, a chapter selected at row 26, the list scrolled to the top first), in
BOTH a probe host (`NavigationSplitView` + the real `BinderPaneToggle`, with an
ancestor reading `uiState`) and, where marked, the REAL `ProjectWindow` mounted on
a real project in Review with the annotations queue up.

| # | hypothesis | result |
|---|---|---|
| a | a `TreeScrollTarget`/`scrollTo` re-fires on a `uiState`-observing re-render | **false** — offset 0→0 (probe AND real window). `consumePendingScroll` is a no-op with nothing pending, and nothing pending arrives |
| b | `List(selection:)` re-application scrolls the selection into view | **false** — and stronger: this SwiftUI host does not push a changed selection `get` into `NSTableView` at all. Preselecting a far-down subject before mount leaves `selectedRow == -1`; changing `probe.subject` after mount leaves `selectedRow` where the click put it. Programmatic selection cannot scroll what it cannot select |
| c | the tree's data identity churns on the pass write, resetting the offset | **false** — offset preserved at a NON-ZERO position too (300 → 300 across the write), so no rebuild-to-top and no restore |
| d | the tree remembers a scroll position and restores it on remount | **false** — reveal to 1080, hand-scroll to 0, unmount (find overlay up) and remount: lands at 0, request still `nil` |
| e | focus returning to the tree (menu closing) scrolls the selection into view | **untested, NOT falsified** — `makeFirstResponder(table)` moved nothing, but with the screen locked the test window can never be key, so this measurement is void (see "Why it could not be reproduced") |
| f | the window grows/moves under the swap (AppKit silently growing past the declared minimum, which this window does do — 500 → 592pt at mount) | **false for the write** — `window.frame` identical before and after in the real window |
| g | it needs a particular window size | **false across a sweep** — 700×540, 800×400, 900×600, 1000×700, 1100×420, 1280×800, 1470×900, 1470×400: every one 0→0 |
| h | a plain re-layout does it (window resized, wider then shorter) | **false** — 1200×500 → 900×500 → 900×300, offset 0 throughout |

## Why it could not be reproduced

The gesture is a **click on a SwiftUI `Menu`**, and the two ingredients only that
delivers — an NSMenu tracking session, and focus leaving and returning to a KEY
window — are unavailable in this session:

- `ioreg -n Root -d1 | grep ScreenIsLocked` → **`CGSSessionScreenIsLocked = Yes`**
  for the whole session. Per CLAUDE.md's mounted-click caveat, a locked screen
  denies activation; `makeKeyAndOrderFront` does not make the test window key, so
  hypothesis (e) cannot be measured.
- The real app is worse off: launched from `DerivedData` with the screen locked,
  `AXUIElementCreateApplication(pid)` reports **0 windows** — the app's scenes are
  never realised, so neither AX inspection nor an AX press is possible.

## What to do next (screen unlocked, app in the foreground)

1. Reproduce by hand first, and note the window size and whether the tree's
   selected chapter was above or below the fold.
2. With the dev build running, watch the sidebar's `NSScrollView`
   (`contentView.bounds.origin.y`) — a `+scroll`-observing `NSNotification`
   (`NSView.boundsDidChangeNotification` on the clip view, with
   `postsBoundsChangedNotifications = true`) plus `Thread.callStackSymbols` at the
   moment it moves names the caller in one shot. That single stack decides
   between "`consumePendingScroll` fired" and "AppKit/SwiftUI moved it".
3. If it is `consumePendingScroll`, the bug is a `scrollRequest` written by
   something the census above says cannot write it — check the five writers with
   a breakpoint rather than by reading.
4. If it is AppKit, hypothesis (e) is the live one: the menu's dismissal restoring
   first responder to the sidebar `List`. The fix then belongs at the picker
   (`ReviewRoundCockpit.lanePicker`), not at the tree.

## The regression suite

`MaughamTests/TreeScrollStabilityTests.swift` — three tests: the contract in the
probe host, the contract in the real `ProjectWindow` (plus "the window did not
resize under it"), and **the positive control** that fires a reveal request and
measures the tree actually moving. The control is the load-bearing part: without
it, two assertions that a number stayed still would pass just as happily on a
harness that could never have seen it move. They are green on unmodified code —
they pin the contract and the falsifications; they do not stand in for a fix.
