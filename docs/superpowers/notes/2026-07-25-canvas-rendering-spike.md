# Canvas rendering spike (M1C §7A.7)

*Run 2026-07-25, before writing the 1C plans. Spec §7A.7 called for a timeboxed
spike rather than planning eight tasks of Canvas-drawing past an unmade decision.
This is the result.*

**Verdict: the spec's recommendation wins — SwiftUI `Canvas` drawing every node,
one real `NSTextView` mounted on the focused scrap. The runner-up is
disqualified, and the recommendation's own biggest risk is retired.**

Harness: standalone `swiftc` binaries, `-target arm64-apple-macos14.0`, sources
under the session scratchpad (`spike/q1*.swift`, `q3*.swift`, `q4_zoomedit.swift`).
Nothing was added to the Maugham project.

## Environment caveat, stated first

Everything below was measured on **macOS 26.5.2 (25F84)**. The spec's citations
are against macOS 15 and the bug reports date from 2020–2021. Maugham's
deployment target is **macOS 14**. So:

- A bug that **reproduces** on 26 also affects 14/15. Q1's result is safe to act on.
- A hazard that **does not reproduce** on 26 (Q2) is *not* thereby cleared on
  14/15. I have no 14/15 machine here. Q2's finding is worth exactly what it is:
  the mechanism that produces the seams is absent in this configuration.

---

## Q1 — NSScrollView magnification vs hosted SwiftUI: **the bug reproduces**

The runner-up architecture is disqualified.

Two independent methods agree, and one needs no synthetic events at all.

**Method 1 — event-free coordinate probe.** A `GeometryReader` inside hosted
SwiftUI content reports its own `.global` frame; AppKit's `convert(_:to: nil)`
on the same document view is the truth.

| magnification | SwiftUI `.global` size | AppKit says |
|---|---|---|
| 1.00 | 200 | 200 ✅ |
| 1.25 | 200 | 250 ❌ |
| 1.50 | 200 | 300 ❌ |
| 2.00 | 200 | 400 ❌ |
| 3.00 | 200 | 600 ❌ |
| 0.60 | 200 | 120 ❌ |

SwiftUI's coordinate space is **completely unaware** of the scroll view's
magnification. It reports the same frame at every zoom.

**Method 2 — synthesized clicks, with a plain AppKit view as the control.**

- Plain `NSView` subviews: **4/4 hit correctly** under magnification.
- Hosted SwiftUI: **2/8** — and the 2 were both at magnification 1.0.

The failure has a precise shape, from the per-node run:

- at **1.5×**, the gesture fires but reports local `(150,150)` where the click
  was at the view's centre `(100,100)` — the point is multiplied by the
  magnification instead of having it unapplied;
- at **2.0×**, the mistranslated point falls **outside** the view's bounds, so
  the gesture never fires at all and clicks stop working entirely.

**One `NSHostingView` per node does not escape it.** That was worth testing —
per-node hosting gives each node its own AppKit frame, so AppKit routes the
event correctly and only the final in-view hit test is SwiftUI's. It fails
anyway, at the same magnifications, in the same way.

**What this does and does not disqualify.** AppKit itself is flawless here:
`NSTextView.convert(_:from: nil)` round-tripped to `(130.00, 8.00)` and yielded
caret index 24 at *every* magnification from 0.6× to 3×. `setMagnification(_:centeredAt:)`
held its anchor to 0.0pt drift. The runner-up's advertised advantages are real —
they are just only available to a **pure AppKit** node layer. Every canvas node
(regions, chips, images, palette cards) would have to be an AppKit view rather
than SwiftUI, against the grain of the entire codebase. That is the
disqualification.

**The recommendation is untouched by this**, because it never uses
`NSScrollView` magnification: its camera is a manual CTM inside `Canvas`.

## Q2 — `_NSTiledLayer` seams at ~1.5×: **does not reproduce**

Tested document views of 4000×3000 and 16000×12000 at magnifications 1.0, 1.25,
1.5, 1.75, 2.0.

- Layer class is `NSViewBackingLayer` in every case — **not** a tiled layer.
- `draw(_:)` receives **one rect** covering the visible region, never multiple
  tiles. No tile boundaries exist, at any zoom tested.
- Non-integral device-pixel edges: 0 at every magnification above 1.0.

Seams require tiles; there are no tiles. That is a sound inference, but be clear
about what it is not: **I could not capture real pixels.**
`CGWindowListCreateImage` is now unavailable (SourceKit reports it as removed,
not merely deprecated), and ScreenCaptureKit needs a permission grant this
session cannot obtain. So this is "the mechanism is absent", not "I looked at the
screen and saw no seam". Given Q1 already rules out the magnification route, the
residual risk is close to zero — nothing we plan to build uses it.

## Q3 — TextKit-shared layout: **holds, exactly**

§7A.2 names this the biggest risk in the design. It is retired, with pixels.

Method: own a TextKit 2 stack, draw it into a bitmap via
`NSTextLayoutFragment.draw(at:in:)` the way a `Canvas` would, then mount a real
`NSTextView` on the **same** `NSTextContainer`, render that into a bitmap of
identical geometry, and diff.

| case | drawn vs edited |
|---|---|
| Iowan Old Style 13 @ 260 | 0.0028%, max channel delta 1 |
| Iowan Old Style 13 @ 187.5 | 0.0069%, delta 1 |
| System 13 @ 220 | **0.0000%**, delta 0 |
| Menlo 11 @ 301 | **0.0000%**, delta 0 |
| Times New Roman 15.5 @ 244 | **0.0000%**, delta 0 |
| Georgia 14 @ 250 | 0.0021%, delta 1 |

Ink bounding boxes are identical (`dx 0, dy 0`) in every case. The residual
handful of delta-1 pixels is colour-space normalisation in my comparison, not
layout. Fragment geometry is **byte-identical across focus and across blur**, and
click-to-caret is monotonic and lands in the line the drawing put under the
cursor.

Fractional scrap widths (240.25, 240.75, 244.3, 301.7) are fine — all ≤0.0065%.

### Three requirements this surfaced, none of them obvious

1. **`cs.textStorage = NSTextStorage(...)`, never `cs.attributedString = ...`.**
   This is the trap. With `attributedString`, everything *looks* right — the
   stack lays out, the drawn glyphs are perfect, `tv.textContentStorage === ours`
   is `true` — but `tv.textStorage` is `nil`, `tv.string` is empty, and **both a
   real synthesized keystroke and `insertText` are silent no-ops.** A scrap that
   renders beautifully and refuses to accept a single character. With
   `textStorage`, typing reaches the shared stack and the drawing stack stays in
   sync.

2. **`container.lineFragmentPadding = 0`** (it defaults to **5**),
   `widthTracksTextView = false`, `textView.textContainerInset = .zero`. Any one
   of these left at its default shifts drawn against edited.

3. **Draw at the window's true `backingScaleFactor` × camera zoom.** Deriving the
   scale from pixel width instead bakes in AppKit's own frame rounding and
   shifts glyphs by a subpixel — that produced a spurious 13–20% pixel
   difference in an intermediate run and is exactly the "text jumps" failure
   dressed up as a measurement artifact.

## Q4 — the gap §7A leaves open: the mounted editor at zoom ≠ 1

The drawn layer zooms via the `Canvas` CTM. The mounted `NSTextView` is a real
view; §7A does not say how it appears at 1.5×. Both candidate mechanisms work:

- **Bounds scaling** (grow `frame`, hold `bounds` — what `NSScrollView`
  magnification does internally): coordinates round-trip correctly at k = 1, 1.5,
  2, 3 (caret index 24 every time), and ink area grows as k² (12.5k → 27.4k →
  50.0k → 105.7k), confirming genuine re-rasterisation rather than a blurry
  upscale. **No re-layout at all**, so Q3's proven agreement carries over
  unchanged. This is the one to build.
- **Proportional re-layout** (font × k, width × k): line breaks are *identical*
  across Iowan, Times, Georgia and Helvetica at k = 0.5 … 3.0. Viable as a
  fallback and useful as a cross-check, but it re-lays-out, so it reopens a door
  bounds scaling keeps shut.

## Incidental finding, for whoever writes canvas tests

`NSTextView.mouseDown` runs a **modal event-tracking loop** until it sees
mouseUp. A test harness that posts mouseDown, pumps, then posts mouseUp
deadlocks — the pump never returns, so mouseUp is never posted. Post both before
pumping. This cost two runs here.

Relatedly: two of my early runs produced confident-looking failures that were
harness defects (a never-shown window rendering blank; a hand-rolled
`displayIgnoringOpacity` into a flipped context corrupting subsequent hit
testing; a window that would not stay key). **Every negative result in this note
is backed by a control that passed.** Any canvas test asserting "the click
missed" needs the same discipline.

## What the plan takes from this

- Build the recommendation as written in §7A.1. It survived; its rival did not.
- §7A.2's mitigation is not merely advisable, it is **verified** — and it comes
  with three concrete requirements (above) that belong in the first task, not
  discovered in the fourth.
- Pin the focus/blur agreement as a test the moment it works, per §7A.2. The
  measurement is cheap: fragment geometry equality across mount and unmount, plus
  a bitmap diff. Both are offscreen and need no permissions.
- Zoomed editing uses bounds scaling. Write it down before someone reaches for
  `.scaleEffect`.
- Drop `_NSTiledLayer` from the risk register for the chosen architecture.
