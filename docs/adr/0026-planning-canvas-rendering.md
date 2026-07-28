# ADR 0026 — Planning canvas: a drawn surface with one mounted editor

**Date:** 2026-07-26 · **Status:** Accepted · **Milestone:** M1C, plan 1C-a (branch `feat/planning-canvas-1c-a-2026-07-25`)

**Amended 2026-07-28 by plan 1C-b — regions** (branch `feat/planning-canvas-1c-b-2026-07-27`): decision 8 added, decisions 6 and 7 corrected where 1C-b made them false. Membership is part of the same canvas-architecture decision this ADR already records, so it is an amendment and not a new number.

## Context

Milestone M1's third plan gives the Plan persona a centre column: a freeform planning
canvas — "where you think before things have firmed up" (design
`docs/superpowers/specs/2026-07-25-planning-canvas-design.md` §1). Messy, spatial,
associative, no schema. Most of what lands on it will never become anything, and that is
the point.

Nothing in Maugham looked like this. Every existing surface is a list, a tree, a table or
a document; this one is a plane with a camera over it, holding freely-placed cards whose
text the writer edits **in place**. Two questions had no precedent in the codebase and
one of them is named in the design as the biggest risk in it:

- **How is the surface rendered and driven?** Hundreds of nodes, pan and zoom, crisp text
  at every scale, and real editing.
- **How does the seam between *drawn* text and *edited* text not show?** §7A.2: if the
  drawn layout and the editor's layout differ at all — line breaking, leading,
  hyphenation — the text visibly jumps every time the writer clicks in, and again when
  they click out. On every edit, in a tool whose whole promise is that the surface is
  trustworthy.

§7A of the design is binding and answers both, on the strength of a timeboxed spike
(`docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`) run before any
construction. This ADR records the decisions that spike settled, and the ones the build
of 1C-a settled after it. **Every item below is a decision, not a deviation: 1C-a takes
no deviations from the spec.**

Constitution principles in play: **must #1, *the words are safe*** (identity) — the
canvas is a new place a writer's words live, and it has no op log behind it; **must #2,
*get out of the way*** (identity in spirit) — a planning surface that imposes a schema
would be a method; **must #3, *delight, end to end*** (position) — §7's feel work, the
seeded angles, the momentum, the ground; and **must-not #1, *AI is never the author***
(identity) — the canvas is a planning surface in the parallel plane, which is what makes
§8A.2's Claude write path admissible at all.

## Decision

### 1. A drawn canvas over hosted views, with a manual CTM camera

A single SwiftUI `Canvas` draws every node. Exactly one real `NSTextView` is mounted, on
the scrap currently being edited. The camera is `cx.translateBy` / `cx.scaleBy` inside the
draw call, so glyphs rasterise under the final CTM and stay crisp at every zoom. Hit
testing is an inverse transform plus a reverse-z rect test against the model; culling is
`rect.intersects(viewport)` in the draw loop, which destroys no view identity and so
cannot cost the writer their focus or an in-progress edit.

This is convergence rather than preference — Excalidraw, tldraw, Miro, Figma and
AudioKit's `Flow` all do it, and Apple's own Freeform links MetalKit and bundles the iWork
drawing engine with no `NSTextView` in the binary at all.

**The runner-up is disqualified by measurement.** `NSScrollView` with a document view and
real subviews gets crisp text, real editing and `setMagnification(_:centeredAt:)` for
free. The spike tested it two independent ways and it fails against hosted SwiftUI
content:

| magnification | SwiftUI `.global` size | AppKit says |
|---|---|---|
| 1.00 | 200 | 200 ✅ |
| 1.25 | 200 | 250 ❌ |
| 1.50 | 200 | 300 ❌ |
| 2.00 | 200 | 400 ❌ |
| 3.00 | 200 | 600 ❌ |
| 0.60 | 200 | 120 ❌ |

SwiftUI's coordinate space is completely unaware of the scroll view's magnification — it
reports the same frame at every zoom. Synthesised clicks land 2/8 against a plain-`NSView`
control's 4/4, and both successes are at magnification 1.0: at 1.5× the gesture fires with
the point *multiplied* by the magnification instead of unapplied, and **at 2× the
mistranslated point falls outside the view's bounds and clicks stop registering
entirely.** One `NSHostingView` per node does not escape it. AppKit itself is flawless
under magnification; that advantage is only available to a pure-AppKit node layer, and
making every canvas node an AppKit view runs against the grain of the whole codebase.
`_NSTiledLayer` seams (the other standing hazard for any magnification route) did **not**
reproduce — there are no tiles to seam — but Q1 disqualifies the route regardless.

`.scaleEffect` is separately ruled out for zoom: it scales *rendered output* (text blurs),
reports unscaled geometry through `GeometryProxy`, and breaks `NSCursor` tracking (Apple
Forums 780215, DTS-acknowledged, no workaround). **Tripwire 25** carries both bans.

### 2. The shared-TextKit rule: one layout stack for drawn and edited text

§7A.2's mitigation is structural, not a patch: **draw with the same TextKit stack you edit
with.** `ScrapLayout` owns one `NSTextContentStorage` / `NSTextLayoutManager` /
`NSTextContainer` per scrap; `CanvasRenderer` draws through it and the mounted
`NSTextView` edits through it. Never SwiftUI `Text` for display and `NSTextView` for
editing.

Three requirements come with it, all verified by the spike, all silent when broken:

1. **`contentStorage.textStorage = NSTextStorage(...)`, never `.attributedString =`.**
   With `attributedString` the scrap lays out and renders perfectly while
   `textView.textStorage` is nil, `textView.string` is empty, and both real keystrokes and
   `insertText` are no-ops — a card that draws beautifully and refuses a single character.
   **Tripwire 26.**
2. **`lineFragmentPadding = 0`, `widthTracksTextView = false`, `textContainerInset =
   .zero`.** Any one left at its default shifts drawn against edited. `textContainerInset`
   is the worst of them: setting it to 5 moved **27% of the pixels while every geometry
   assertion still passed**, because it feeds `textContainerOrigin` (where the *view*
   paints) and never reaches the shared container. Geometry equality is structurally
   incapable of seeing that class, which is why the pin is a bitmap diff *as well as* a
   glyph-origin comparison.
3. **Draw at the window's true `backingScaleFactor` × camera zoom, and never derive that
   scale by hand.** Deriving it from pixel width bakes in AppKit's frame rounding and
   shifts glyphs by a subpixel. `GraphicsContext.withCGContext` already hands over a
   context at backing scale under the camera CTM, so the renderer satisfies this by doing
   nothing; a grep test forbids hand-derivation anywhere in the area.

The mounted editor gets zoom by **bounds scaling** — the frame grows, the bounds are held,
AppKit rasterises at the new scale — for the same reason: a re-layout at zoom changes line
breaking, which is §7A.2 again.

### 3. Scrap text in `canvas.md`; layout in `.maugham/canvas.json`

Scrap *text* is content and lives in `canvas.md` at the project root, one `## <id>` heading
per scrap. Positions, widths, cached heights, z-order and seeds are derived UI state and
live in `.maugham/canvas.json` behind a `schemaVersion` gate (ADR 0015: an unknown `kind`
is dropped rather than fatal; a newer schema degrades to an empty layout rather than
crashing).

**The split is the point.** Delete the sidecar by hand and the layout is gone, the words
are not. It is the same plain-text-on-disk commitment the manuscript makes, applied to a
surface whose geometry is genuinely disposable.

#### The ADR 0018 exception — a new category

`CanvasStore.load()` reads `canvas.md` and `.maugham/canvas.json` directly, which trips
tripwire 20's grep. Both lines carry `// adr-0018-ok:`, and **the reason is recorded here
because an inline comment will not survive a refactor and a future contributor greps the
tripwire's message, not `CanvasStore.swift`.**

The reason is *not* "scraps are outside the op log". Plenty of things are outside the op
log and still get flagged; a `.md`'s mere existence outside the op log is not the
exemption. The real reason is that **`canvas.md` has no second source of truth to disagree
with.** ADR 0018 exists to stop two representations of the same content drifting — a stale
`.md` read back as input while the op log holds the fresh derivation. Scrap text has
exactly **one** persisted representation, and `CanvasStore.load()` *is* its reconciler.
There is no drift to reintroduce.

This is the **first "plain-text content deliberately never op-logged" category in the
codebase**, and the tripwire's own sanctioned-reasons list does not name it. Anything
later claiming the same exemption must meet the same test: one persisted representation,
and this is the code that reads it.

#### The crash floor, stated honestly

Saves are debounced 750 ms, matching `DocumentStore`, so canvas edits and manuscript edits
settle on one rhythm. **It is not the same guarantee.** A manuscript has the op log behind
it: the ops are appended as they happen and a crash costs at most the debounce window of a
*rendered* file. The canvas has no op log; `canvas.md` and `canvas.json` are the only
records, and a force-quit genuinely loses up to 750 ms of scrap text.

Against must #1 that floor is accepted for a scratch surface, and it is defended
structurally rather than hoped for. **The writer's words leave the editor on every
keystroke** — `textDidChange` folds the live `NSTextStorage` into the model, re-measures
the card and queues the save — and there are **three commit points**: on change, on
`.onDisappear`, and through `CanvasStore.beforeFlush` on `NSApplication.willTerminateNotification`
(`.onDisappear` does not fire on ⌘Q, and the termination observer takes `queue: nil` so it
runs synchronously on the posting thread rather than being enqueued for a hop that may
never happen). **Tripwire 28.** Without the first of those three, typing into a new scrap
and quitting without clicking away writes an empty scrap — must #1 failing on the first
interaction the writer has with the surface.

### 4. The whole card carries its seeded angle; focus straightens it over ~120 ms

§7.2 puts each card at a seeded angle (±`CanvasMaterial.maximumTiltDegrees`, derived from
the node id, stable across renders — deterministic irregularity, never random per frame).
Calibrated by eye against the running app: 0.6° at first, **1.2° from 2026-07-27** at the
writer's request. §7A.5 makes
the straighten the focus affordance: **click a card and the entire card animates to level,
chrome and text together, over ~120 ms, settling back to its angle on blur.** The card
being edited is the only square one on the canvas. The rotation is a value the renderer
interpolates per frame on the same clock as §7.3's momentum — no timer, no completion
callback, no new machinery.

**This makes §7A.2 easier, not harder.** The editor is always axis-aligned by the time it
*is* the visible text, so the glyph-origin pin compares two unrotated layouts and
`.rotationEffect` never arises.

**"Always" is enforced by a gate on VISIBILITY, not on EXISTENCE**, and the decision sits
between two failures that pull in opposite directions:

- Make the editor **visible on the click** and axis-aligned glyphs land at the unrotated
  text origin over a card still up to 1.2° off level, with the drawn text already
  suppressed: they snap straight and the card catches up behind them. That is §7A.2's
  failure, reached by §7A.5's own route.
- Defer the **mount** to `CanvasFocusStraighten.isLevel(_:)` and there is no first
  responder for ~120 ms: double-click empty canvas, type immediately, and the opening
  characters reach nothing at all. §7A.5 allows a beat between click and caret; it does not
  allow discarded keystrokes.

The resolution is **two properties**: `CanvasView.mountedEditorNodeID` (the editor exists,
from the click) and `CanvasView.visibleEditorNodeID` (the editor is the visible text, from
`isLevel`). The second feeds the editor's visibility *and* the renderer's text suppression
alike — one value, read once per body pass — so they flip on one frame and the swap
reveals only what was already on screen. Through the straighten the card goes on drawing
its own text, live off the same `NSTextStorage` the invisible editor is mutating, so the
words appear on the rotating card as they are typed. **Tripwire 27**; merging the two
properties back into one is how this failed twice.

**Corollary that keeps the geometry honest:** while invisible the editor does not
hit-test either (`isEditorVisible` drives `alphaValue` *and* `hitTest(_:)`), so no click or
pinch is ever resolved against its unrotated box under a tilted card — every such event
reaches `CanvasEventNSView`, whose space is canvas space. `ScrapEditorGeometry.viewPoint`
therefore has no rotation term and does not need one. Never `isHidden`: AppKit moves first
responder off a hidden view, which loses the keystrokes the early mount exists to keep.

**Caret rule:** the caret index is resolved in the card's local, unrotated space at click
time, *before* the animation starts, or the click point moves out from under the cursor.
**`CanvasRenderer.cardTransform` is the one definition of the card rotation** — the draw
pass concatenates it, `localPoint` inverts it — because a second, hand-written `R(−θ)` is a
sign convention nothing can check: a flipped one doubles the caret error instead of
removing it, and a round-trip test passes either way. `rotationEffect(` and `rotate(by:)`
are grep-banned across the area.

A related invariant, recorded because its naive spelling is the natural one:
**`CanvasFocusStraighten.isSettled` compares each value to ITS OWN target**, never to a
constant. `allSatisfy { $0.value >= 1 }` is true the instant focus leaves — the departing
entry is still at 1 while its target is now 0 — so `TimelineView` pauses, the settle-back
never runs, and the card stays level for the rest of the session, along with every other
animation on the surface. **Tripwire 29.**

**Correction of record:** §7A.5 justified the straighten partly with "a mounted
`NSTextView` cannot be rotated". That is false — `NSView.frameRotation` rotates a real view
and renders it crisply. The editor is level because that is the design, and the design
stands on its own merits: it is the physical metaphor the surface is already reaching for,
and it retires the §7A.2 risk at the seam rather than managing it.

### 5. Undo is a canvas-scoped snapshot `UndoManager`, not op-log compensating ops

ADR 0023 made ⌘Z op-log-backed across every manuscript operation, via compensating ops.
The canvas does not join that scheme. **Canvas state is derived (§8) — op-logging it would
stop it being derived**, and would make a scratch surface's every nudge a durable
manuscript-plane fact. `CanvasUndo` registers whole-scene snapshots on an `UndoManager`
owned by this surface; `@Environment(\.undoManager)` would hand back a window-lifetime
manager shared with the manuscript editor's stack, where a persona switch mid-drag would
leave a half-open group.

`CanvasUndo` owns no state — it reads and writes its owner's through two closures, which is
what let 1C-b move the same class onto `CanvasModel` by rebinding them. The class did not
change.

**Amendment, 2026-07-28: a second column mutating the scene needs the opposite verb, and
this is tripwire 32.** Once the region inspector could change the scene from the right-hand
column, "which bracket am I inside" stopped having one answer:

- **From the canvas itself**, a mutation arriving mid-gesture is the writer's own gesture,
  and the right answer is to **refuse** — `CanvasView.deleteSelection`'s `isInGesture`
  guard. Closing it would end a bracket the writer still believes they hold.
- **From another column**, there is no gesture of the caller's own to protect, so
  `CanvasModel.mutateFromInspector` **closes, runs and reopens** — exactly what
  `CanvasUndo.undo()` already does. The reopen is load-bearing: the run of typing in
  progress becomes its own step under its own name, and the writer's visit resumes still
  bracketed.

Getting this wrong is silent. The nested `beginGesture` takes no snapshot, the nested
`endGesture` registers nothing, and the edit rides into whatever step the open gesture
eventually closes — so a ⌘Z aimed at a sentence takes a region's name with it. **It was
missed three times inside one slice, by independent implementers arriving from both
entry points**, which is why the rule is a grep census in `TripwireGrepTests` rather than a
comment. The reachable repro is a **double-click on a region's own chrome bar**: click 1
selects the region, click 2 finds no node, mints a scrap and opens "Edit Scrap", and the
`clickCount >= 2` guard never reassigns the selection. It is *not* a double-click on a card
— AppKit sends `clickCount: 1` first, so that click has already moved the selection.

**The second half is the mounted editor's `allowsUndo = false`**, so one change is one
step. (Measured on macOS 26.5: `NSTextView` gates `undoManager` on `allowsUndo` and returns
nil *before* consulting the delegate or the responder chain, so ⌘Z reaches the canvas stack
through `undo:`/`redo:` forwarding on `ScrapEditorContainer`. That forwarding is the only
route found that keeps `allowsUndo` false.)

**Granularity inside a scrap is the SENTENCE.** The outer bracket is focus; `breakGesture()`
splits the visit on a finished sentence or a beat of stillness (`ScrapUndoBeat.idleSeconds`,
1.5 s). The two rejected options are recorded so they are not relitigated:

- **Per-word, rejected.** It is only reachable by handing undo back to the text view
  (`allowsUndo = true`), which puts one change on the stack twice and leaves the text
  view's copy pointed at an `NSTextStorage` that `rebuildLayouts()` has replaced — so the
  *second* ⌘Z appears to do nothing, which is precisely the trust loss undo exists to
  prevent. A gesture break per word would also mean a whole-scene snapshot per word, when
  the snapshot is the thing that makes 1C-b's region drags correct.
- **Per-visit, rejected** as too coarse for a scrap that ran to a paragraph.

**The residual cost is writer-facing and stated in the writer's terms:** ⌘Z inside a scrap
takes back roughly a sentence, or the run of typing since the writer last paused — not a
word. Every other place this is recorded (a test message, a code comment, `AREA.md`, the
`CanvasUndo` class doc) is developer-facing, so **the guide's Personas topic says it too**.
A writer who expects word-by-word undo and gets a sentence reads it as a bug unless the
guide told them.

### 6. We own the canvas accessibility tree

§7A.6 is unambiguous: drawn content has no accessibility tree, and an AX layer mirroring
the scene graph is "not optional in a writing tool". `CanvasAccessibility` publishes an
element for **every node, all of them**, in rows-then-columns reading order (a proximity
walk, not a fixed grid — a grid reads two cards 2 pt apart as different rows whenever they
straddle a cell boundary).

The tree is rebuilt from the **structural** counter (`sceneRevision`: load, create, delete,
undo, the end of a drag or resize, a coast ending — at rest or truncated by a press — and
leaving a scrap. *Amended 2026-07-28:* this list read "not deletion, which 1C-a has no path
for at all" until 1C-b built the caller — see decision 7) and never from
the per-frame redraw counter. Keying it on `revision` sorted the scene and copied every
scrap's string at 60–120 Hz through every drag, coast and straighten. That generalises past
accessibility, so it is **tripwire 30**: nothing scene-proportional may key off a per-frame
redraw counter, and camera-reading `ForEach`es belong in `.equatable()` subviews.

Entering a scrap lands the writer in the real `NSTextView`, which is the accessible thing
for the duration of the visit. **Known divergence, open for the smoke:** the synthetic twin
stays in the tree beside it and is stale for the visit, so a client walking mid-visit meets
the same card twice with two different strings. It refreshes on leaving.

### 7. 1C-a ships scraps only; item nodes are placeholders and belong to 1C-d

An item node renders as a placeholder card carrying its reference id — dashed border,
`Item · <refId>`. `CanvasNodeKind.item(referenceId:)` and the `CanvasNodeID.item(_:)`
spelling stay in the model and the codec and round-trip through the sidecar for real,
because 1C-b and 1C-c consume them.

**This is a decision about the ORDER OF WORK, and the boundary is stated explicitly: it is
a slice boundary, never a milestone one.** Spec §8A.1 places images **inside milestone
M1C** — "not deferred past it" — and says in the same breath that no plan may cite it as
authorising their omission from the milestone. This ADR may not be cited to that end
either. M1C is not finished without them.

**Deleting a scrap belonged to no slice, and 1C-b took it.** *(Amended 2026-07-28.)* 1C-a
built `CanvasScene.remove`, its inverse and the `"Delete Scrap"` undo step, exercised them
in `CanvasUndoTests`, and shipped no production caller for any of them — no key handler, no
menu item, no gesture. Three documents described `sceneRevision` as bumped on "delete"
until the whole-branch review found there was nothing to bump for, which is the same shape
as 1C-a's ⌘Z defect: a whole feature green at the model layer and dead at the delivery
path. 1C-b assigned it to itself, because regions force the "what happens to the contents"
question the moment they exist. ⌫ with something selected is now
`CanvasEventNSView.keyDown` → `CanvasView.deleteSelection()`, pinned by a test that sends a
real `NSEvent` through `window.sendEvent(_:)` and reads what reached disk.

Three rulings came out of building it and are recorded so they are not re-opened:

- **A key that does nothing and also suppresses the beep is indistinguishable from a broken
  app.** `deleteSelection()` returns whether anything actually went, and `keyDown` forwards
  a `false` to `super`, where AppKit's `noResponder` beeps. The canvas does not claim a key
  it did not use.
- **A ⌫ arriving while any gesture is open is refused, not absorbed.** `CanvasUndo`
  takes no snapshot when `beginGesture` nests and registers nothing when `endGesture` does
  not reach zero, so a delete inside somebody else's bracket collapses into it under the
  wrong name — and the lossy variant (⌫ in the run-loop turn after a double-click, before
  the editor claims first responder, then quit) put **the card and its words on disk with
  nothing on the stack that could bring them back**. That is must #1 failing, and the guard
  is one line asking the direct question: is a bracket open?
- **⌫ is `NSDeleteCharacter` (0x7F) and ⌦ is `NSDeleteFunctionKey` (0xF728).**
  `NSBackspaceCharacter` is 0x08 — Ctrl-H — and is unreachable through a `keyDown` switch
  anyway, because `charactersIgnoringModifiers` ignores every modifier except Shift.

**Still open inside M1C, and recorded here because nobody has decided it:** ⌫ is the only
route to deleting a *scrap*. Regions get a visible Delete button in the inspector; a scrap
has no inspector at all, so the discoverability gap is scrap-only. An Edit-menu Delete item
reaches outside `Maugham/Canvas/` and wants deciding whole.

**What 1C-d owes:** the drop target; `DropClassification` for browser image drags (which
carry rendered bitmaps rather than file URLs, so `.dropDestination(for: URL.self)` silently
rejects them); the real title, kind glyph and thumbnail; a `CGImageSource` downsampling
path; and a bounded image cache **keyed by path, not id** (tripwire 22). The canvas is the
first surface in Maugham with an unbounded image count, and no image cache or real
downsampling exists anywhere in the app today.

### 8. Region membership is stored, and geometry never changes it *(added 2026-07-28, plan 1C-b)*

A region is a labelled rectangle with two member sets. **A coordinate never adds or removes
a member** — not on move, not on resize, not on region creation. `CanvasMembership` is the
whole mutation surface and no function in it takes a point, a rect or an overlap: deciding
*which* region a drop meant is the gesture's job, recording it is the membership layer's,
and keeping the two apart is the decision.

**This is a bug-class elimination with three worked examples, not a preference** (spec
§4.2):

- **Obsidian Canvas** leaves a card poking one pixel outside a group, and out of it.
- **Scapple** recomputes membership from live geometry, so a note inside two overlapping
  shapes moves with whichever shape you happen to grab. Unfixed.
- **tldraw ejects children when a frame is resized — *despite* storing membership
  explicitly** ([#6017](https://github.com/tldraw/tldraw/issues/6017)).

The third is why the decision is phrased about the *transition rule* rather than about
storage. Storing membership is not the fix; tldraw stores it and ships the bug. The
firewall is `CanvasMembershipTests`, and it was falsified by introducing tldraw's own
defect and watching the test go red.

**One home, many appearances; copies were rejected outright** (§4.3). A card lives in at
most one region and may be *cited* in any number. A copy would mean two objects claiming to
be the same card, with no way to tell which is real and no answer to which one an edit
reaches — the same reasoning that keeps the manuscript's op log paragraph-keyed. Home
uniqueness is enforced in two places that must agree: `CanvasMembership.join` on the
mutation path, and the codec's loader at the disk boundary, where a hand-edited sidecar can
present a node that is home in two. Both resolve **first in id order keeps it**, and the
loser is demoted to an appearance rather than dropped — that region really did cite the
card, and inventing or discarding a relationship are both worse than recording the weaker
true one.

**Citing is an inspector act; the drop only makes homes.** A drop is a statement about where
a card *is*, and geometry can carry that. A citation is a statement about what a card *means
here*, and no gesture can infer it — so the "Appears here" section of the region inspector
carries a **Cite a Card** menu offering every card not already in the region, and
`RegionInspector.cite` is the only production caller of `CanvasMembership.addAppearance`.
The alternative considered was a modifier-held drop; it was rejected because it would thread
a modifier flag through `CanvasEventNSView`'s callbacks — the event signature this slice
kept stable throughout — to buy a gesture nobody would discover. The offer is behind the
same structural gate as the member lists (tripwire 30's rule, one column over) and needs it
more, because it walks the whole scene rather than one region's members; and a region with
nothing left to offer shows a sentence rather than a menu that opens on nothing.

**A drop is the only gesture that changes membership**, and it targets by the node's
**centre** — predictable and sayable ("drop it so its middle is inside"), where a corner is
the one-pixel absurdity §4.2 cites against Obsidian. Ties resolve on greatest overlap, then
the smaller region, then the smaller id. Collapsed regions are skipped, because a card that
disappears on drop is the worst failure available on a spatial surface. **Removal is always
its own act.**

**The accepted cost is a resident sitting visually outside the region that owns it, and it
is paid in the RENDERER, as a tether.** That is the trade the three tools above refused to
make, and it is the right way round for this product: a wrong-looking line is a rendering
problem the writer can see and fix, where a silent ejection is lost work. It is *get out of
the way* (must #2) read strictly — the surface records what the writer did and does not
quietly revise it because a rectangle moved.

**Region state lives in the canvas sidecar, at schema 2 — not in the manifest.** Labels,
frames, both member sets, the bound piece and the collapsed flag are all derived UI state
under decision 3's split, so they go in `.maugham/canvas.json` with the rest of the layout.
**That is why `RegionInspector` takes a `CanvasModel` and not a `ProjectStore`**: there is
nothing here for the project store to own, and reaching for it would put a second writer on
state whose only reconciler is `CanvasStore.load()`.

Both directions of the schema step are non-destructive, and the second is the one that
matters against must #1:

- A **schema-1** sidecar — every canvas 1C-a wrote — decodes unchanged; `regions` is
  optional rather than defaulted so a missing key is not a throw.
- A **schema-2** sidecar opened by an **older build** fails the `schemaVersion <= current`
  gate and yields an empty layout with `canvas.md` read as normal. **It costs the
  arrangement and never the words.** That is decision 3's split doing the job it exists for:
  the expensive thing to lose is the only thing that is not in the derived file.

**The bound piece is produced here and consumed in 1A.** `RegionBinding` writes it, the
inspector makes it settable, and the reference rail that reads it is unwritten. Binding
residents only, never appearances, is what stops two regions sharing a card and each
claiming it as their piece's context (§4.4).

Constitution principles this decision answers to: **must #1, *the words are safe*** — the
schema step and the delete path are both judged on what they do to `canvas.md`, not to the
layout; **must #2, *get out of the way*** — membership is what the writer said it was, and
geometry does not overrule them; **must #3, *delight, end to end*** — the tether, the wash
and the collapsed summary are how the accepted cost is made legible rather than merely
tolerated.

**Tripwire 31** carries the rule. **Tripwire 32** carries the undo-bracket verbs that
regions forced into the open — see decision 5.

## Consequences

- **More code than a `ZStack`**, and the accessibility layer is code that a hosted-view
  canvas would have got for free. Accepted in §7A.6; the alternatives fail a stated
  requirement.
- **Supported scale is 2,000 nodes** (`CanvasPerformanceProbeTests.supportedNodeCount`) —
  not a hard cap, but the number the culling probe defends. Measured: cull of 2,000 nodes
  0.082 ms/frame, hit test 0.052 ms, a zoomed-out cull returning 820 nodes in 1.429 ms.
  `Maugham/Canvas/AREA.md` records precisely what those probes do and do not pin; in short,
  they catch O(n²) and are not guaranteed to catch an ~11× constant-factor regression, and
  nothing *measures* `CanvasRenderer.draw`. (It is exercised — 1C-b renders it through
  `ImageRenderer` in six raster fixtures — but none of them is a timing probe, so the scale
  claim still rests on the transitive argument. This bullet said "nothing exercises `draw`
  directly" until 2026-07-28.) The known unbounded per-frame work is the tether and chip
  passes, which are not viewport-culled; when that is fixed, cull the **segment**, never the
  region.
- **Eight tripwires (25–32)** and `Maugham/Canvas/AREA.md`. They exist because almost every
  defect behind them is invisible to a subview count, a geometry assertion or a green
  suite — 30 and 32 were each found by a review rather than by a test, and 32 was reached
  three times in one slice before it was written down.
- **Hit testing is on the unrotated rect**, so there is a mismatch band of `r·θ` — ~2.6 pt
  at the corner of a default 240×80 card at the calibrated 1.2° tilt. It sits exactly where
  the resize mark is drawn and tested, and is accepted because 2.6 pt is inside pointer
  slop and the 14 pt target absorbs it. It is also the ceiling on further tilt
  calibration, and `CanvasRenderer.cullingBleed` carries the same term (a card culled while
  a corner is still on screen) with a test that re-does the arithmetic.
- **The canvas is Mac-only** (§9). `Packages/MaughamCore` and `MaughamPhone` are untouched,
  exactly as 1B was.
- **Open for the manual smoke**, recorded here rather than resolved on paper:
  - ~~**The ground uses one grain algorithm in both appearances**, so light and dark differ
    only by base fill colour.~~ **CLOSED 2026-07-27 by the smoke.** The writer's reading was
    "the canvas looks a little bland and black, the texture isn't coming in… this also leads
    to the cards not feeling differentiated enough". The cause was not the noise *character*
    but the *range*: the whole dark scene lived between 0.060 and 0.118, in which a ±0.028
    grain and a 14% lamp are a handful of 8-bit levels. Resolved by giving dark its own
    material rather than a second noise function — ground 0.060 → 0.115, grain 0.055 →
    0.075, lamp 0.10/0.86 → 0.26/0.66, and a **dedicated dark card paper of 0.235** in place
    of `textBackgroundColor`, whose 0.118 now sits below the ground. Card-to-ground
    separation goes 0.058 → 0.120. Every knob moved to `CanvasMaterial` as a named
    per-appearance constant, with the shader taking uniforms, because the writer calibrates
    these by eye and a literal in a `.metal` file is not findable. Light is untouched.
  - **The focused scrap is announced twice to VoiceOver**, once stale (decision 6). Whether
    `elements` needs to know the focused id is a question a VoiceOver walk settles.
- **Left to later slices** *(updated 2026-07-28)*: lines and promotion (1C-c); item nodes,
  drops and images (1C-d). Regions, `CanvasModel` and deleting a scrap were on this list and
  1C-b built all three. §8A.2's Claude write path is designed and unbuilt; its
  constitutional reasoning is recorded in the spec, not here.
- **Appearances had no creator for one commit, and 1C-b closed that too** *(2026-07-28)*.
  `CanvasMembership.addAppearance` shipped persisted, drawn as a chip, listed in the
  inspector and removable from it — every part under test, and no production caller. That is
  decision 7's own failure shape (built, exercised, unreachable) recurring inside the slice
  that closed it, found the same way: by counting production callers of a function the slice
  had just built, which no green suite can do. The creation path is the inspector's **Cite a
  Card** menu (decision 8), and a caller census now asserts the list by name so it fails both
  when it empties and when it grows. The lesson is kept rather than the gap: **a green suite
  cannot distinguish a fully-exercised function from a reachable one.**
- **⌫ is the only route to deleting a scrap**, because a scrap has no inspector to put a
  button in. Regions have one. See decision 7.
