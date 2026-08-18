# The tree scrolls on a pass swap — investigation, 2026-08-18

**Status: STILL OPEN. The fourth session shipped HARDENING, not the fix for
Denver's bug.**

What the fourth session established, and what it did not:

- **Demonstrated and pinned**: the displacement MECHANISM. A layout minimum that
  exceeds the window makes SwiftUI centre rather than compress, and the tree's
  scroll view leaves through the top with a negative origin. Driven end to end in
  a probe, at −26.5pt.
- **Fixed, as hardening**: `AnnotationsPane`'s advisory nudge
  (`passOrderNudge`) raised that pane's own minimum height by 26pt on the pass
  write. Real, measured, now impossible (`Maugham/Views/WindowFloorFree.swift`).
- **FALSIFIED**: that this was Denver's bug. Planted-offender measurement
  against the real `ProjectWindow` shows a column's minimum height **does not
  reach this window at all** — a 700pt demand on the annotations pane, on the
  sidebar column, on the centre column, or on the detail column's own root each
  left `contentMinSize` at 540, while the same offender outside the split view
  turned it 700. No pane can set this window's floor by any amount, so the 26pt
  was never on the production path.
- **NOT explained**: session 3's 596–636 band, where the split view laid out
  shorter than the window after the write. That band was read off
  `fittingSize` going 592 → 637, and `WindowFloorFreeLayout` deliberately still
  answers the content's IDEAL to an unspecified proposal — which is what
  `fittingSize` asks. **So 592 → 637 stands, unchanged, after the fix.** Whatever
  produces it is not the nudge's minimum, and it is not fixed.

**The band's cause is unknown and is the live question.** The next discriminator
is unchanged from the third session: Denver's hand smoke in the real app with the
extended probe, which now writes `settled +1s/+3s/+8s` lines carrying `fits`,
`fittingH` and `windowH`, and captures frame changes on the scroll view **and
every ancestor** with a stack. A `settled` line with `fits=false`, or a `frame`
line with a stack, names it in one shot.

Read the fourth session at the bottom for the measurement, the fix and its
limits; the three sessions above it are the narrowing, and their falsified
hypotheses still stand — do not re-derive them.

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

---

## Second session, 2026-08-18 — Denver's decisive evidence, the differencing, the probe

**New evidence.** It reproduces from BOTH the cockpit's lane picker and a board
chip click. That kills the Menu-click/focus framing as the *whole* story (a chip
is a plain `Button`, no `NSMenu` tracking session) and it means the shared
trigger is the one line both paths reach:
`documentStore.updateUIState { $0.activePassMemory.record(…) }`.

It also demotes the mounted "real `ProjectWindow`" measurement above. Its own
record contains the fidelity gap: in that host `List(selection:)` never pushed a
programmatic selection into the `NSTableView` at all (`selectedRow == -1`), so
the one AppKit mechanism whose geometry matches the screenshot could not have
been observed there either way. The screen is still locked
(`CGSSessionScreenIsLocked = Yes`), so that gap could not be closed this session.

### Differencing the compositions — verdict: NO candidate

Every reader of `documentStore.uiState` in the app (grep `\.uiState` over
`Maugham/`, minus `Maugham/Stores/` and `updateUIState` call sites):

| site | position | column |
|---|---|---|
| `AnnotationsPane.swift:223` | **body** (`activePassMemory` computed property) | right |
| `ProjectWindow.swift:1827` | closure handed to `EditorHost` (`activeReviewPassId`) | centre |
| `ProjectWindow.swift:841/1197/3972/4015/4045` | action methods (persona/wall presses) | — |
| `ProjectWindow.swift:3355–3417` | `load()` | — |
| `TreeTravel.swift:346` | `.onKeyWindowCommand` handler | — |
| `CompilerEnvironment+Project.swift:164` | run-environment closure | — |
| `AnnotationToolHelpers.swift:94` | MCP tool | — |

**The left column contains none of them.** `BinderPaneToggle`, `BinderView`,
`BinderRow`, `BinderTreeSections`, `BinderPieceFold`, `BinderTreeDrops`,
`ResearchRow`, `TreeSectionDerivation`, `SceneNavigatorPane`,
`CollectionPiecesPane`, `CollectionBinderPaneToggle` and `ProjectSearchView` do
not read `uiState` — none of them so much as *takes* a `DocumentStore`. And
`ProjectWindow.body` does not read it either, so the pass write does not
invalidate even the body that builds the column. `@Observable` tracking is
per-stored-property, and `uiState` is one property, so this is the whole census:
the write invalidates `AnnotationsPane` (and `EditorHost`, through the closure)
and nothing else.

The three things a row's geometry could turn on were checked directly and none
moves:

- **identity** — `.tag(BinderSubject.item(id))` / `.id(BinderSubject.item(id))`,
  a function of `item.id` alone.
- **height** — `BinderRow` is one `HStack` with `lineLimit(1)`; no wrap, no
  variable-height arm.
- **content** — `statusDot` is `ReviewStatus.derived(passStates:passes:legacyStatus:)`
  over `item.passStates` + `manifest.effectiveReviewPasses` + `item.status`.
  All manifest. `activePassMemory` reaches it nowhere.

The `List(selection:)` GET is `BinderTreeSelection.shown(state.selection,
subject:)` — a pure function of `treeState.selection` (written only from the
List's own `set`) and `ProjectWindow.selectedSubject` (`@State`). The pass write
touches neither.

And the disk write is inert: `MaughamSidecarPath` classifies
`.maugham/ui-state.json` as `.uiState`, which
`DocumentStore.presenterDidChangeSubitem` explicitly ignores. No reload, no
manifest change, nothing downstream.

**So the scroll is not a re-render of the tree caused by the pass write.** It is
AppKit or SwiftUI moving the offset for a reason no Swift source in this repo
states — which is exactly what a stack trace answers and static reading cannot.

### The one asymmetry worth handing forward

The board-chip path writes `selectedSubject = .item(pieceId)` *before*
`recordActivePass` (`ProjectWindow.onNavigate`, ~line 1894). A programmatic
subject write does **not** update `treeState.selection` — only the List's own
`set` does — so `shown` returns `[.item(pieceId)]`, a set the table did not
have. That is a real selection change, and a selection push is precisely the
geometry Denver photographed (selected row visible, top scrolled off).

It is not the answer, for two reasons: it is *legitimate* on that path (a chip
opens that chapter, and the tree following it is correct), and the cockpit's
lane picker writes no subject at all — `AnnotationsPane` never touches
`selectedSubject`; its only outbound verb here is `onSetActivePass`. So nothing
was changed on this account. The probe's two stacks will separate them in one
reproduction: if the chip's trace is a selection push and the picker's is not,
they are two different mechanisms wearing one symptom.

### The probe

`Maugham/Views/TreeScrollProbe.swift`, attached in all three tree hosts
immediately after `consumingTreeScrollRequests`. Dev builds only AND never in a
test host (`BuildVariant.dev` && `NSClassFromString("XCTestCase") == nil`);
`MAUGHAM_TREE_SCROLL_PROBE=0` turns it off in a dev build too. When the gate is
shut `View.treeScrollProbe()` returns `self` unchanged — nothing mounts, nothing
subscribes.

Output, both sinks, every line prefixed `TREESCROLL`:

```
log stream --predicate 'category == "TreeScrollProbe"' --info
log show --last 10m --predicate 'category == "TreeScrollProbe"' --info
grep 'TREESCROLL move' ~/Library/Application\ Support/Maugham\ Dev/tree-scroll-probe.log
```

A `move` line carries old→new y, the delta, viewport and content heights,
`appActive`, `keyWindow`, the window's first responder class, and how many
further changes the previous burst suppressed; the 48 `#N` lines under it are
the stack. One stack per burst (400ms), so a drag logs once.

**Reading it.** `BinderTreeSectionsState.consumePendingScroll` in the trace ⇒ a
`scrollRequest` was written by something the census above says cannot write one;
go to the five writers with a breakpoint. Its absence ⇒ AppKit/SwiftUI, and the
`firstResponder` field plus whether the trace runs through `NSTableView`
selection machinery says which.

---

## Third session, 2026-08-18 — the frame, and why the install line is not evidence

Denver reproduced with the probe installed and it logged **zero** clip-bounds
moves. The probe's own install line was then read as showing the pathology
already standing:

```
TREESCROLL installed … scrollFrameInWindow=(8.0,-121.0 200.0x705.0) viewportH=705.0 contentH=746.0 window=Playlist
```

### The mechanism the numbers describe is real, and is now demonstrated

A tree can be displaced **without scrolling**: a scroll view laid out somewhere
the window cannot show moves every row on screen and moves no offset at all.
That is what a clip-bounds instrument cannot see, and it is exactly the reported
picture — top rows gone, scroller untouched.

`TreeScrollStabilityTests.test_control_aWindowShorterThanItsMinimumPutsTheTreeOutsideIt`
now proves it happens in this app: squeeze `ProjectWindow`'s hosting view below
the height its own layout needs and SwiftUI does **not** compress — it keeps the
minimum size and CENTRES it, driving the tree's scroll view out of the window
**with its frame origin negative**, i.e. the top of the tree above the window's
top edge. Measured: host 300pt ⇒ scroll view 462pt at y **−42**.

The squeeze must go through a container view. `NSHostingView` stamps the
window's `contentMinSize`, and the window then clamps every `setContentSize`
back up — a harness that resizes the window silently measures a legal size and
passes.

### Not reproduced — the pass write does not do it

Frame containment was asserted against the REAL `ProjectWindow` mounted on a
**clone of Denver's own Playlist project**, driving production's own
`updateUIState { $0.activePassMemory.record(…) }`:

| sweep | result |
|---|---|
| 7 fresh mounts, 900/700/640/617/592/560/540 | inside, before and after |
| 31 window heights 900→300 in 20pt steps, resize then write | inside, every one |
| 40 `Persona` × `DetailSegment` states at the minimum height, each with the write and its converse | inside, all 80 measurements |
| with a toolbar + `.fullSizeContentView` (the real window's chrome) and without | inside, both |
| 12 consecutive pass swaps | inside, every one |

### The install line is a pre-layout snapshot, and here is the proof

1. **A second install line exists**, from another window 17 minutes later:
   `scrollFrameInWindow=(0.0,0.0 699.0x462.0)`. `x=0` and a 699pt-wide sidebar
   are not a settled layout of this app — the tree's scroll view is at `x=8` and
   never wider than its column.
2. **Arithmetic.** For Playlist's composition a settled sidebar list is
   `windowContentHeight − 250` tall (measured across every sweep above). 705
   would need a window content height of 955. The tallest content height any
   window can have on that Mac is **811** (measured: ask for 900, get 811 —
   screen 1470×956 less the menu bar, titlebar and Dock). 705 is not a settled
   height for any window on that display.

So the retry ladder (150ms after the anchor lands, well inside a window restore)
caught the column before it had its final height. **The probe now writes
`settled +1s/+3s/+8s` lines for exactly this reason** — believe those, not
`installed`.

### What the pass write DOES do — a real, latched finding

`window.contentMinSize` is stamped once at mount (980×592 for Playlist) but
SwiftUI's own `fittingSize.height` for the same window **rises 592 → 637 on the
pass write and stays there** — it is a property of the pass, not a transient
(five samples over a second; the converse write puts it back). 20 unrelated
`uiState` writes (`detailColumnWidth`) move it by nothing, so this is the pass
write's and not any write's.

At window heights inside that band the whole `NavigationSplitView` is then laid
out **shorter than the window**, permanently:

| window content height | split view after the write |
|---|---|
| 596 | 585 |
| 610 | 596.5 |
| 620 | 611.5 |
| 630 | 626.5 |
| 636 | 635.5 |
| 640 | 640 (no change — 637 fits) |

The left column's list shrinks with it (306 → 299pt at 592). The tree loses rows
off the **bottom**, not the top, and 11pt is not 121 — so this is not the
reported bug, but it is the only thing the pass write is measured to do to that
column, and it is where a fix would start. The 45pt is almost certainly a
right-column surface that appears when a pass is active (the round cockpit's
order nudge is the shape); it was NOT narrowed to a view this session.

### Status

**Still not reproduced. No fix shipped.** What landed: the frame half of the
probe (frame changes on the scroll view *and every ancestor*, `fits`/`fittingH`/
`windowH` on every line, and the settled snapshots), plus two tests —
`test_aPassSwapLeavesTheTreeInsideItsWindow` (the sweep) and its positive
control. Next reproduction should be driven **in the real app** with the
extended probe: a `settled` line with `fits=false`, or a `frame` line with a
stack, names it in one shot.

---

## Fourth session, 2026-08-18 — a minimum-height leak found and closed, and why it is not the bug

**Read the header first.** This session found a real defect, fixed it, and did
NOT close the report. What follows is worth having on its own terms; the
"therefore Denver's bug is fixed" step is the one it cannot take, and the reason
is stated at the end of each part.

### The view: `AnnotationsPane.passOrderNudge`

The third session's latched finding — *the pass write raises the layout's
minimum height and it stays* — was narrowed to a single view by measuring the
minimum height of each candidate in isolation.

**Two different numbers wear the name "the layout's minimum", and the whole
session turns on the difference.** `window.contentMinSize` on an
`NSHostingView` whose `sizingOptions` are `[.minSize]` is the MINIMUM: the stamp
a window measures its own legal sizes against. `fittingSize` with no sizing
option is the IDEAL. The third session's 592 → 637 is the second one; everything
below measures the first. They are not the same quantity and the fix moves only
one of them — see "What this does not explain".

`AnnotationsPane` alone, one chapter, width 320, no cockpit:

| moment | `window.contentMinSize` |
|---|---|
| before the pass write | (320, **50**) |
| after `record(piece:passId: "line")` | (320, **76**) |

**+26pt, and 26pt is exactly the nudge.** Measured standalone at several widths:

| view | 200 | 240 | 260 | 280 | 320 | 380 |
|---|---|---|---|---|---|---|
| `ReviewRoundCockpit(activePassId: nil)` | 56 | 56 | 56 | 56 | 56 | 56 |
| `ReviewRoundCockpit(activePassId: "line")` | 56 | 56 | 56 | 56 | 56 | 56 |
| the nudge + its `Divider` | **39** | **26** | 26 | 26 | 26 | 26 |

So the cockpit's height does not move with the pass at all — the strip is there
in both states and the lane label fits on one line at every column width this
app allows. The nudge is the whole delta: `PassOrderAdvice.advice` answers nil
before the write (no pass recorded) and non-nil after (the LINE pass is being
worked while STRUCTURAL, which precedes it, is still open), so a caption plus a
divider appears — 26pt at one wrapped line, 39pt at two.

**Why it is a minimum and not merely a height.** `AnnotationsPane`'s body is a
non-scrolling `VStack`: toolbar, cockpit, nudge, then the queue. Each strip
demands its full height as a MINIMUM, the `VStack` sums them, and SwiftUI
propagates that all the way out to `NSHostingView`. The queue below them
compresses; the chrome does not.

A tempting inference to NOT draw: that the third session's 45pt is this 26pt
plus a width-dependent second line. It might be, and Playlist's own pass names
are longer than the presets'. But the 45pt was measured on `fittingSize`, an
IDEAL, and the 26pt is a MINIMUM — so the arithmetic compares two different
quantities, and no measurement here connects them. The 45pt remains unattributed.

### How a raised minimum displaces a tree — and why this one cannot

`window.contentMinSize` is stamped **once, at mount**. A pane whose minimum
rises afterwards cannot push the window back out, so the writer's window keeps a
height the window still considers legal while the layout has decided it needs
more — and SwiftUI **centres what it cannot compress**. The whole
`NavigationSplitView` is then laid out shorter than the window and pushed up,
the sidebar's scroll view acquires a negative frame origin, and the top of the
binder tree ends up above the window's top edge with its scroller never having
moved. That is the third session's control test, and it is Denver's screenshot.

Reproduced end to end in `test_aPassSwapCannotPushTheTreeOutOfAWindowThatAlreadyFitsIt`
with the fix reverted: host 315pt, band 301.5–327.5, tree scroll view at
**y = −26.5**.

**And in the real window it cannot happen — measured, not argued.** That probe
composition deliberately has no `ProjectWindow.frame(minHeight: 540)` in front of
it, because with the floor there the column's whole demand — 76pt at its largest
— is 7× short of binding it. The third session's own stamp says the same from the
other end: `contentMinSize` on Playlist was **980×592**, and 592 is the floor,
not the column.

Then the census (below) settled it outright, with planted offenders against the
real `ProjectWindow`, each a `.frame(minHeight: 700)`:

| offender planted on | `window.contentMinSize.height` |
|---|---|
| `AnnotationsPane` (outside its own modifier) | **540** — absorbed |
| the sidebar column | **540** — absorbed |
| the centre column | **540** — absorbed |
| the detail column's own root | **540** — absorbed |
| `ProjectWindow.body`, outside the split view | **700** — red in every state |

**In this window's composition, a column's minimum height does not reach the
window.** So no pane can set the floor by any amount, the 26pt leak was never on
the production path, and `.doesNotRaiseTheWindowFloor()` does no work in the
shipped app. It is kept as defence in depth, pinned by tests, and its doc says
so.

**Where the demand is absorbed was NOT isolated, and the obvious guess is
wrong.** The same 700pt offender in a MINIMAL three-column `NavigationSplitView`
probe propagates to the window intact — so this is something about
`ProjectWindow`'s own split-view chrome (its overlays, `navigationTitle`,
toolbar, sheets) and **not** a general property of `NavigationSplitView`. A
probe test asserting the general claim was written, measured, found false, and
deleted rather than weakened; the finding lives here and in the census's doc as
a measurement. Isolating the absorber is open work and is plausibly the same
question as the 596–636 band.

### The fix — `WindowFloorFreeLayout`

`Maugham/Views/WindowFloorFree.swift`, applied as `.doesNotRaiseTheWindowFloor()`
at the end of `AnnotationsPane.body`. The rule it expresses: **a pane's content
growing is a reason to compress or scroll that pane, never a reason to move the
window's floor.** The floor is `ProjectWindow`'s own `.frame(minHeight: 540)`
and nothing else's business.

It is a `Layout` because neither of the obvious levers can LOWER a reported
minimum: `frame(minHeight: 0)` returns `max(0, childMinimum)`, and
`layoutPriority` only redistributes space a stack already has. The container
answers a definite height proposal — the minimum query included — with the space
it was offered, and an unspecified or infinite one with the content's ideal. The
WIDTH answer is passed through unchanged, deliberately: this column has a floor
its toolbar is measured against (`AnnotationsQueueToolbarWidthTests`). The clip
is part of the contract — below the height its chrome wants, the pane loses its
own bottom rather than another column losing its top.

### The tests

- `test_aPassSwapDoesNotRaiseTheAnnotationColumnsMinimumHeight` — the cause,
  measured as `window.contentMinSize`. Red without the fix: **50 → 76**.
- `test_aPassSwapCannotPushTheTreeOutOfAWindowThatAlreadyFitsIt` — the
  mechanism, in a three-column probe with the REAL tree and the REAL queue and
  no `ProjectWindow.frame(minHeight:)` in front of them. The container height is
  **measured, not hardcoded**: the pane's ideal height either side of the write
  brackets the band the defect opens, and the host is sized halfway between, so
  the test keeps straddling the band across fixtures, fonts and OS versions. Red
  without the fix (tree at y = −26.5).
- `test_aPassSwapLeavesTheTreeInsideItsWindow` — the real-window sweep, extended
  with the 636→596 band, and each point now also asserts the split view FILLS
  its window. **Read `assertSplitViewFillsItsWindow`'s doc before trusting that
  band**: `NSHostingView` stamps `contentMinSize` and the window clamps every
  `setContentSize` back up, so this sweep cannot actually place a window below
  its content's minimum — the band is walked, not reproduced, and the assertion
  guards a FUTURE pane pushing the layout minimum past 540, which is the only
  way this composition can go short.
- `test_theWindowsMinimumHeightIsProjectWindowsOwnFloor` — the durable guard
  (see below).

**The guard is the census, not the modifier.** A per-pane modifier protects the
pane it is on and nothing else, and this bug's shape is *some pane's chrome
quietly exceeds the window's floor*. So the load-bearing test is the census:
across every persona × pane state, the window's RESOLVED minimum height must
equal `ProjectWindow`'s own explicit floor and never a pane's demand. Any future
pane whose chrome exceeds 540 goes red **by name**, whether or not anyone
thought to give it a modifier.

### What this does not explain

Session 3's 596–636 band. That was `fittingSize` reading 592 → 637, and
`WindowFloorFreeLayout` answers an unspecified proposal — the one `fittingSize`
makes — with the content's ideal, unchanged and on purpose. **592 → 637 stands
after the fix.** Whatever raises the IDEAL by 45pt and holds it there is still
unidentified, and it is the live question. See the header for the next
discriminator.

### Open

- The band above. Unknown cause; Denver's hand smoke with the extended probe is
  the next step.
- Every other non-scrolling column pane has the same shape. They are covered by
  the census rather than by modifiers of their own — a modifier per pane is a
  list someone has to remember to add to, and the census is not.
