# Maugham/Canvas — AREA notes

*The Plan persona's centre column: a freeform planning canvas. Read this before editing anything in this directory.*

Binding design: `docs/superpowers/specs/2026-07-25-planning-canvas-design.md` — **§7A is binding** and constrains §7's feel work. Decisions of record: [ADR 0026](../../docs/adr/0026-planning-canvas-rendering.md). Measurements: `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`.

---

## The architecture, and why the alternative lost

**A single SwiftUI `Canvas` draws every node; exactly one real `NSTextView` is mounted, on the scrap being edited; the camera is a manual CTM inside the draw call.** Hit testing is an inverse transform plus a reverse-z rect test against the model, so it never touches SwiftUI's event machinery. Culling is `guard rect.intersects(viewport)` in the draw loop — no `ForEach` identity to destroy, so virtualisation cannot cost the writer their focus or an in-progress edit.

**Someone will propose `NSScrollView` with real subviews again.** It is the runner-up and it looks better on paper: crisp text, real editing, and `setMagnification(_:centeredAt:)` for free. It is disqualified by measurement, not taste — read `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md` (Q1) before re-opening it. SwiftUI content hosted inside a magnified `NSScrollView` reports the **same `.global` frame at every zoom** (200 pt at 1.0×, 1.25×, 1.5×, 2×, 3× and 0.6× alike, where AppKit says 250/300/400/600/120), and synthesised clicks land 2/8 — both successes at magnification 1.0. At 1.5× the gesture fires with the point multiplied by the magnification instead of unapplied; **at 2× the mistranslated point falls outside the view's bounds and clicks stop registering entirely.** One `NSHostingView` per node does not escape it. AppKit itself is flawless under magnification; the advantage is only available to a pure-AppKit node layer, which is against the grain of the whole codebase.

---

## The shared TextKit stack — `ScrapLayout`

§7A.2 names the drawn/edited seam the biggest risk in the design: if the two layouts differ at all, text jumps every time the writer clicks in and again when they click out. The mitigation is structural — **one layout, both consumers read it.** `ScrapLayout` builds one `NSTextContentStorage` / `NSTextLayoutManager` / `NSTextContainer` stack per scrap, and `CanvasRenderer.drawCard` and the mounted `NSTextView` both draw through it.

Three requirements. Each is verbatim from the spike; each breaks the surface silently:

1. **`contentStorage.textStorage = NSTextStorage(...)`, NEVER `contentStorage.attributedString = ...`.** *Symptom:* the scrap lays out and renders perfectly, `textView.textContentStorage` is identity-equal to ours — and `textView.textStorage` is nil, `textView.string` is empty, and both real keystrokes and `insertText` are silent no-ops. A card that draws beautifully and refuses a single character. **This one fails as a UI bug and is a wiring bug**, which is why it has its own tripwire (26).
2. **`lineFragmentPadding = 0`** (`NSTextContainer` defaults to 5), **`widthTracksTextView = false`**, **`textContainerInset = .zero`**. *Symptom:* any one left at its default shifts drawn against edited. `textContainerInset` is the nastiest: it feeds `textContainerOrigin` (where the *view* paints) and reaches the shared container through nothing, so **27% of pixels move while every geometry assertion still passes** — measured during Task 3. Geometry equality is structurally incapable of seeing this class, which is why `ScrapLayoutTests` carries a bitmap diff alongside the signature comparison.
3. **Draw at the window's true `backingScaleFactor` × camera zoom, and NEVER derive that scale by hand.** *Symptom:* deriving it from pixel width bakes in AppKit's frame rounding and shifts glyphs by a subpixel — "text jumps" wearing a measurement-artifact disguise. `CanvasRenderer` satisfies this by doing nothing; `GraphicsContext.withCGContext` already hands over a context at backing scale under the camera CTM. A grep test forbids `backingScaleFactor`/`convertToBacking`/`convertFromBacking`/`pixelsWide`/`pixelsHigh` in code anywhere in this directory.

`ScrapLayout.init(textColor:)` defaults to `.labelColor`, but **every construction under `Maugham/Canvas/` must name `textColor: CanvasRenderer.cardInk`** — grep-enforced, because taking the default gives the same colour today and so nothing would break if you forgot. `cardPaper`/`cardInk` are appearance-dynamic (paper 1.000 under Aqua / 0.235 under DarkAqua, ink `labelColor` 0.00 / 1.00). A paper-white card in dark mode is a light-mode skeuomorph, not an honest object on the ground (§7.2).

---

## Card metrics live in `CanvasCardMetrics`, and nowhere else

`CanvasNode.width` is the CARD width; the text box is inset 10 pt on all four sides and the card height is the measured text height plus the same inset twice. `CanvasRenderer` (which draws the text) and `CanvasView` (which mounts the editor over it) both read those functions.

**A second spelling of the inset anywhere puts drawn glyphs and edited glyphs on different rects** — the §7A.2 "text jumps on focus" failure arriving by the back door, past every structural defence above.

---

## Focus straightens the card (§7A.5)

The whole card carries a seeded angle (±`CanvasMaterial.maximumTiltDegrees`, currently **1.2°** — FNV-1a over `id.raw` through a SplitMix64 finaliser, stable, never random per frame, chrome and text together). **The focused card animates to level over ~120 ms and settles back to its angle on blur.** That is the focus affordance: you pick the paper up and square it to write on, and the card being edited is the only square one on the canvas.

It also makes §7A.2 *easier*: at the moment the editor becomes the visible text, both layouts are unrotated, so the glyph-origin pin compares two axis-aligned layouts and `.rotationEffect` never enters the picture. `rotationEffect(`/`rotate(by:)` are grep-banned across this directory.

**Do not write down the old claim that an `NSTextView` cannot be rotated.** `NSView.frameRotation` rotates a real view and renders it crisply. The editor is level because that is the design, not because AppKit forces it.

Four parts are load-bearing, and each has failed in draft:

- **The editor MOUNTS on the click; it becomes VISIBLE on `isLevel`.** Two properties, and merging them back into one is how this has failed twice, in opposite directions.
  - `CanvasView.mountedEditorNodeID` is just `editingNodeID`: the editor exists, is first responder and takes keystrokes from frame one. Gate the *mount* on the straighten instead and there is no first responder for ~120 ms — double-click empty canvas, type immediately, and **the first character or two reach nothing at all.** §7A.5 allows a beat between click and caret; it does not allow discarded keystrokes.
  - `CanvasView.visibleEditorNodeID` adds `straighten.isLevel(_:)`, and **the same property feeds both `ScrapEditorHost.isEditorVisible` and `CanvasRenderer.draw`'s `visibleEditorNodeID:`** — one value, read once per body pass. So the card keeps drawing its own text (live, off the shared `NSTextStorage`, rotating as it goes) right up to the one frame the editor takes over, and the swap reveals nothing that was not already on screen. Make the editor visible on the click instead and axis-aligned glyphs land at the unrotated text origin over a card still up to 1.2° off level with the drawn text already suppressed: they snap straight and the card catches up behind them — **§7A.2's failure by §7A.5's own route.**
- **While it is invisible the editor is also transparent to the pointer.** `ScrapEditorContainer.isEditorVisible` drives `alphaValue` *and* `hitTest(_:)`, so through the straighten a click or a pinch reaches `CanvasEventNSView` — whose space is canvas space — rather than being resolved against the editor's unrotated box under a tilted card. That is what keeps `ScrapEditorGeometry.viewPoint`'s "no rotation term" honest: the function is only ever reached from an event the container received, and it receives none while invisible. **Never `isHidden` / `.hidden()`** — AppKit moves first responder off a hidden view, which loses the keystrokes the early mount exists to keep, and (measured) a hidden view leaves the accessibility tree while `alphaValue = 0` does not.
- **`CanvasFocusStraighten.isSettled` means "every card is at ITS target", not "every progress value is 1".** The naive `allSatisfy { $0.value >= 1 }` reports settled the instant focus leaves — the departing entry is still at 1 while its target is now 0 — so `TimelineView` pauses, `step` is never called again, and **the card stays level for the rest of the session** (and nothing else on the canvas animates either). `step(elapsed:)` returns `!isSettled` for a non-positive delta on purpose; do not "fix" that to `false`.
- **The caret index is resolved in the card's unrotated space BEFORE the animation starts**, or the click point moves out from under the cursor. `CanvasRenderer.cardTransform` is the one definition of the card rotation; `localPoint` inverts *it*, never a second hand-written `R(−θ)`. A flipped sign convention doubles the caret error instead of removing it, and a round-trip test passes either way — which is why the grep ban above exists.

---

## Hit testing, and the resize corner

**Hit testing is on the unrotated rect.** The mismatch band is `r·θ` — about **2.6 pt at the corner of a default 240×80 card** (r = 126.5 pt, θ = 1.2°), growing with the diagonal and with the tilt. It is not somewhere a writer never aims: it sits exactly where `CanvasRenderer.resizeHandle` draws and `CanvasInteraction.begin` tests. Accepted because 2.6 pt is inside pointer slop and the 14 pt target absorbs it — **but this is the reason `CanvasMaterial.maximumTiltDegrees` has a ceiling.** A calibration round that keeps raising the tilt eventually pushes this band past the target that absorbs it. `CanvasRenderer.cullingBleed` carries the same `r·θ` term for a different reason (a card culled while a corner is still on screen) and `CanvasRendererTests.test_theCullingBleedCoversTheRotationOverhangAtTheCalibratedTilt` re-does that arithmetic on every run.

**The resize TARGET is the whole 14 pt corner square; the MARK is the triangle below its hypotenuse.** One constant (`CanvasRenderer.resizeHandleSize`) fixes the size of both so they cannot drift, and the shapes differ deliberately: a target slightly larger than its mark forgives a near miss, where the reverse would swallow drags the writer aimed at the card. **Do not shrink the target to the ink** — `CanvasInteractionTests.test_theUnmarkedHalfOfTheCornerSquareStillResizes` exists to stop a tidy-up doing exactly that.

---

## Composition and layering

**Layer order: ground → drawn nodes → events → editor (frontmost).** With the event view in front of the editor, click-to-place-caret, drag-select and double-click-word all die and the surface reads as "typing does nothing". `CanvasCompositionTests` pins the order.

**The ground is a sibling BENEATH the content, never an overlay.** A shader applied *over* a subtree containing an `NSViewRepresentable` logs a console warning and renders a grey placeholder (§7A.4) — and this view has two of them. So `ZStack { CanvasGround(...); content }`, never `content.background { CanvasGround(...) }` and never `.colorEffect` on anything containing `CanvasEventView` or the editor. Nothing is thrown and nothing goes red; you get a placeholder and a warning.

Pass the ground the **same live camera `@State`** the draw pass uses. A stale or default camera makes the grain crawl under the cards as you pan, and `CanvasGroundTests` constructs its own cameras so it cannot see that.

**`CanvasScene.nodes` sorts on every access.** Per-frame and per-`body` callers use `count` or `unorderedNodes`; `topmostNode(at:)` and `nodes(intersecting:)` filter first and order the survivors. `CanvasAccessibility.summary` reading `scene.nodes.count` from `body` was a 2,000-element sort per body evaluation.

---

## The material — `CanvasMaterial`

**Every number the canvas's *look* is calibrated with lives in `CanvasMaterial.swift`, and nowhere else.** The look is tuned by eye against the running app by the writer, so a constant he wants to move must be findable without reading a Metal file: `CanvasGround.metal` holds no material literals at all and takes grain amplitude, lamp depth, lamp floor and lamp reach as uniforms. **Do not inline a number back into the shader** — a shader constant is a constant nobody can find, and this whole seam exists because the first calibration round could not.

| To change | Edit |
|---|---|
| more / less texture | `lightGrainAmplitude`, `darkGrainAmplitude` |
| stronger / weaker lamp | `lightLampDepth`/`darkLampDepth` (how fast), `lightLampFloor`/`darkLampFloor` (how far); `lampReach` for the throw |
| lighter / darker ground | `lightBase`, `darkBase` |
| more / less card separation | `darkCardPaper` up, or `darkBase` down |
| more / less tilt | `maximumTiltDegrees` |

**Light and dark are two materials, not one texture inverted** (§7.1: "Dark: slate under a lamp… Paper is a light-mode idea"). Every knob that differs is a *pair*, and `CanvasGroundTests.test_theTwoAppearancesAreCalibratedSeparately` stops a tidy-up collapsing them — light was signed off on 2026-07-26 and dark was recalibrated on 2026-07-27; putting dark's hotter grain on light undoes an approval.

Three constraints bind any further calibration:

- **The card must stay lighter than the ground in both appearances, including at peak grain.** A card darker than its surface reads as a hole cut out, not an object resting on it (§7.2) — as fatal as unreadable text. Pinned by `test_theCardIsLighterThanTheGroundInBothAppearances`, which reads the grain amplitude, so raising the texture has a ceiling and the test names it.
- **Author colours in sRGB.** `NSColor(calibratedRed:)` with the same digits resolves ~30% lighter and the lift is invisible in the source. `test_theGroundResolvesToTheValuesItIsAuthoredWith` and `test_theCardPaperIsTextBackgroundInLightAndItsOwnValueInDark` pin the resolved components against the literals.
- **`cardPaper` is `textBackgroundColor` in LIGHT ONLY.** Dark takes a dedicated 0.235: the system colour is 0.118 in dark, which is *below* the raised ground and turns every scrap into a hole. `cardInk` is still `labelColor` (white in dark) and is the ceiling on how light the dark paper may go — `test_theCardsInkContrastsWithItsPaperInBothAppearances` says when.

**Test the dark ground by rendering it.** Every fixture here was pinned to `.light` through Task 8, so a dark canvas that was flat black shipped with the suite entirely green — the shader ran, the grain was anchored, the zoom faded, and it was still unusable. `renderGround(pan:zoom:size:scheme:)` takes a scheme; `test_theDarkGroundIsAMaterialRatherThanABlackFill` measures brightness, grain energy and the lamp's sweep in 8-bit levels.

---

## The mounted editor

- **Its focus is requested, not taken.** `makeNSView` has no window yet, so `makeFirstResponder` there is a silent no-op. `updateNSView` re-claims it.
- **`mount` rebinds on layout IDENTITY, not on `textView == nil`.** Otherwise clicking from scrap A to scrap B keeps editing A — and a subview count cannot tell the difference. The mounted layout is held as a `weak var ScrapLayout?` compared with `!==`, not an `ObjectIdentifier`: an identifier held past its object's lifetime can be matched by a *different* layout allocated at the same address, skipping the rebuild and leaving the writer typing into the scrap they just left.
- **Zoom is BOUNDS SCALING** — the frame grows, the bounds are held, and AppKit rasterises the glyphs at the new scale. Never `.scaleEffect` (blurry, wrong geometry, breaks `NSCursor` tracking) and never a re-layout (a re-layout at zoom changes line breaking, which is §7A.2 again). **Do not "harden" this against external frame writes.** Measured 2026-07-26 across 11 cases: `NSView` stores a per-axis frame→bounds *scale*, not a bounds size, and a frame write on its own moves `bounds.size` to preserve that scale — hosted, unhosted, through a layout pass and via superview autoresize alike. Forcing `bounds.size = unscaledSize` after every `setFrameSize` makes the scale `frame.size / unscaledSize` *by definition*, i.e. whatever the external writer chose (measured (2.083, 2.1) and (2.833, 3.0) under exactly that prescription) — which manufactures the 7A.2 failure this file exists to prevent. `mount` writes both rectangles on every call, so the invariant is *established*, not merely maintained, and the frame-then-bounds order is load-bearing.
- **`allowsUndo = false`** — see the undo section below. `NSTextView` gates `undoManager` on `allowsUndo` and returns nil before consulting the delegate or the responder chain (measured all three paths on macOS 26.5), so ⌘Z reaches the canvas stack through `undo:`/`redo:` forwarding on `ScrapEditorContainer`. **Do not delete that forwarding expecting the responder chain or `undoManagerForTextView:` to take over. Neither does.**
- **Caret clamping is in UTF-16 units** (`(tv.string as NSString).length`), not `Character` count — `NSRange` and `ScrapLayout.characterIndex(at:)` are UTF-16, and a scrap containing an emoji otherwise drags a valid caret backwards into the wrong word.

---

## State, counters, and the writer's words

**`layouts` holds reference types in `@State`.** Typing mutates a `ScrapLayout` in place, so the `Canvas` will not redraw without the `revision` counter — and `revision` must be read in `body`, not inside the draw closure, or SwiftUI never sees the dependency.

**Two counters, and they are not interchangeable:**

| | ticks on | keyed to it |
|---|---|---|
| `revision` | every animation frame — every drag frame, straighten frame, coast frame, keystroke | the `Canvas` redraw, and nothing else |
| `sceneRevision` | load, create, delete, undo, the end of a drag or resize, a coast ending (at rest, or truncated by a press), leaving a scrap | the accessibility tree |

**Delete joined that list in 1C-b**, and this file twice said it never would. Its bump is the one place a caller does not spell it: `CanvasView.deleteSelection()` bumps the MODEL's counter and lets the mirror in `body` deliver it, so `rebuildLayouts(bumpsStructuralCounter: false)` is right there beside it — the undo apply is the only other caller that spells it that way, and for the same reason.

`commitActiveEdit`'s bump is guarded on a scrap having been focused. It runs at the head of `handleClick`, and `onClick` precedes `onDrag(.began)`, so unguarded it rebuilt the whole tree on **every mouse-down** — including the press that starts a drag. The coast's second bump (`handleDrag(.began)`) exists because of that guard: a press truncates a coast, so the timeline's rest branch never runs, and without it the tree keeps the frame the card had when the writer let go.

Keying anything scene-proportional on `revision` runs it at 60–120 Hz through every drag, coast and straighten. That is tripwire 30, and it is how the accessibility tree came to sort the scene and copy every scrap's string per frame.

**The writer's words leave the editor on every keystroke.** `ScrapEditorContainer` is the text view's delegate; `textDidChange` → `onTextChanged` → `CanvasView.syncActiveEdit()` → fold into `scraps`, re-measure the card, bump `revision`, schedule the debounced save. *Named symptom if this is ever removed:* type into a new scrap, quit without clicking away, and **the scrap comes back empty** — plus the card never grows while you type, because nothing is re-measuring. Three commit points, all required:

1. on change (`onTextChanged`),
2. `.onDisappear` (persona switch, window close),
3. `CanvasStore.beforeFlush` (app quit).

`syncActiveEdit` folds the string and nothing else. `onTextChanged` fires synchronously inside `textDidChange`, so rebuilding layouts from there would replace an `NSTextStorage` from inside its own text view's change notification.

---

## Persistence

**`canvas.json` is derived and deletable; `canvas.md` is content and is not.** Positions, geometry, seeds and z-order live in `.maugham/canvas.json`; scrap *text* lives in `canvas.md` at the project root. Delete the sidecar by hand and the layout is gone, the words are not. That split is the point (§8).

**`CanvasStore.load()` reads both files directly, and both lines carry `// adr-0018-ok:`.** The reason matters and is not the obvious one — see [ADR 0026 §"The ADR 0018 exception"](../../docs/adr/0026-planning-canvas-rendering.md). Short version: **`canvas.md` has no second source of truth to disagree with.** ADR 0018 exists to stop two representations of the same content drifting; scrap text has exactly one persisted representation, so there is no drift to reintroduce. "It is outside the op log" is *not* the exemption — plenty of things are and still get flagged.

**`CanvasStore.flush()` takes no arguments** (it writes whatever `scheduleSave` last queued) and covers app quit via `NSApplication.willTerminateNotification`, because `.onDisappear` does not fire on ⌘Q. **The observer takes `queue: nil`** — that is required, not a default: with a queue the block is enqueued rather than run on the posting thread, and during termination the hop may never run before the process exits.

**The crash floor: a force-quit loses up to 750 ms of typing since the writer last paused.** That is the same number `DocumentStore`'s autosave debounce gives, so the canvas and the manuscript settle on one rhythm — **but it is not the same guarantee.** A manuscript has the op log behind it: the ops are appended as they happen and a crash costs at most the debounce window of a *rendered* file. The canvas has no op log. `canvas.md` and `canvas.json` are the only records, and 750 ms of scrap text is genuinely gone. Do not let "matches `DocumentStore`" imply parity.

---

## Undo

**Snapshot-based and canvas-scoped.** `CanvasUndo` registers whole-scene snapshots on a `UndoManager` owned by this surface, not on the window's — `@Environment(\.undoManager)` would give a window-lifetime manager shared with the manuscript editor's op-log stack (ADR 0023), and a persona switch mid-drag would leave a half-open group on it. Canvas state is derived (§8); op-logging it would stop it being derived.

`CanvasUndo` owns no state of its own — it reads and writes its owner's through two closures. That is what let 1C-b Task 3 move the same class onto `CanvasModel` by rebinding them; the class itself did not change. **`CanvasModel` is the owner now**: it holds the scene, the scrap text, the selection, the sidecar store and the recorder, because the region inspector in the right-hand column reads and mutates the same scene the canvas draws. `CanvasView` keeps everything that is a property of one *view* of that state — camera, layouts, editing focus, the straighten, momentum, `revision` and `sceneRevision`.

- **`beginGesture` opens no `UndoManager` group.** A group cannot span an event boundary, and an "Edit Scrap" gesture spans as many events as the writer types keystrokes; a closed *empty* group still pushes a step. **Tests must set `groupsByEvent = false`; production must not.** (With `groupsByEvent` off, an out-of-group registration raises rather than being absorbed — `register` guards for it explicitly.)
- **Only a real keystroke may move an undo boundary.** `syncActiveEdit(fromKeystroke:)` defaults to `false`, and the two housekeeping callers — `.onDisappear` and `CanvasStore.beforeFlush` — take that default. Without it, a writer who pauses and then quits trips the idle break inside `beforeFlush`, which closes a step and **reopens a gesture on a view that is going away**: a half-open bracket arriving from the save path instead of the focus path.
- **An undo serviced while a gesture is open re-baselines that gesture.** The baseline is captured at focus-in and nothing is registered until focus-out, so a ⌘Z mid-visit leaves it stale: close the gesture against it and you register a step whose *undo* re-applies what the writer just undid. The one line that fixes it lives at the end of `CanvasUndo.register`'s closure. Closing the gesture *before* servicing the undo instead needs `NSUndoManagerWillUndoChange`, and registering while the manager is mid-undo makes the registration a **redo**.
- **The mounted editor has `allowsUndo = false`.** Snapshots own scrap text. If the text view registered too, one change would land on the stack twice, and its copy would target an `NSTextStorage` that `rebuildLayouts()` has replaced — so the second ⌘Z would appear to do nothing.
- **⌘Z is reachable by exactly TWO routes, and BOTH are an explicit `undo:`/`redo:` pair with a `validateUserInterfaceItem` beside it.** `ScrapEditorContainer` (a scrap focused, through `CanvasUndo` so the open gesture closes first) and `CanvasEventNSView` (nothing focused, through the bare manager because no gesture can be open). **An `undoManager` override is NOT a third route and does not enable a menu item.** Measured 2026-07-27 on macOS 26.5: with `CanvasEventNSView` genuinely first responder in the real hosting hierarchy, `window.undoManager` was a *different* manager — `NSWindow` asks its delegate for `windowWillReturnUndoManager:` and otherwise vends its own; it does not ask the first responder. Believing otherwise shipped the 1C-a smoke defect: undo built and twenty-two tests deep, greyed out on a bare canvas, because every one of those tests drove the recorder or the manager directly. `CanvasViewMountingTests.test_undoIsReachableFromTheEditMenuWithNoScrapFocused` is the one that goes through resolve → validate → send.
- **Granularity inside a scrap is the SENTENCE.** The outer bracket is focus; `breakGesture()` splits the visit on a finished sentence or `ScrapUndoBeat.idleSeconds` (1.5 s) of stillness. The idle beat is asked BEFORE the keystroke is folded in (so the closing step ends where the writer stopped) and the sentence rule AFTER (so the full stop belongs to the step it closes). Swapping either is invisible in the code and obvious to a writer. **Per-word is only reachable through `allowsUndo`, which is the defect above**, and would also mean a whole-scene snapshot per word. This cost is writer-facing: the guide's Personas topic says what ⌘Z does inside a scrap, and that sentence is part of the contract, not a nicety.

The undo apply replaces the scene and then calls `CanvasModel.onSceneReplacedByUndo` — synchronously, inside the apply and a whole timeline tick before the coast could take another step. `CanvasView` binds that to `momentum.stop()` FIRST (a ⌘Z within ~1 s of a flick otherwise puts the card back at the pick-up point and lets the coast skate it away from there) and reconciles focus AFTER (an undo can remove the scrap the writer is standing in — double-click bare canvas, type, ⌘Z, ⌘Z is three keystrokes to it, and without the reconcile every drag is ignored until the writer happens to click somewhere).

**A replaced `ScrapLayout` under a live editor is SAFE, and the file says so with the measurement.** Measured 2026-07-26 on macOS 26.5: an `NSTextView` built through `NSTextView(frame:textContainer:)` **owns its TextKit 2 stack** — with the `ScrapLayout` released, the layout manager, content storage and text storage are all still alive and the view lays out and draws. Safe is not the same as correct: through that window the view still shows the text the undo discarded, and showing the restored words is the *rebind's* job. Which is why the replacement must be a **new** `ScrapLayout` rather than the old one mutated in place.

---

## Delete

**⌫ is `CanvasEventNSView.keyDown` → `CanvasView.deleteSelection()`, and it is deliberately a `keyDown` rather than `deleteBackward(_:)`** — the event view is not a text responder, never calls `interpretKeyEvents`, and so would never receive the action message.

- **Selection is a region → the region goes and its cards stay.** The canvas owns arrangement, not existence (§3.1, generalised); the membership records die with it, which is all `CanvasScene.removeRegion` touches.
- **Selection is a node → the node goes, its text goes from `canvas.md`, and `CanvasScene.remove` scrubs it from every region.** One gesture, so one ⌘Z brings back the card *and* its words — a snapshot carries the scene and the scrap text together and they cannot be restored out of step.
- **Nothing selected is a no-op, not a guess.**

**⌫ never fights the editor**, and that is a fact about first responder rather than about z-order: while a scrap is focused the mounted `NSTextView` holds it, so the window delivers the key there and the writer deletes a character. Measured 2026-07-28 by mutation — putting the event view in FRONT of the editor does not change it, while stopping the editor claiming focus deletes the whole card mid-sentence. `CanvasViewMountingTests.test_backspaceInsideAScrapDeletesACharacterAndNotTheCard` is the one that says so, and it clicks the card once before entering it so there is a live selection for the event view to destroy if it ever wins.

**1C-a shipped this feature's other half with no caller at all** — `CanvasScene.remove`, its inverse and the `"Delete Scrap"` undo step, all built, all exercised, no key and no menu item — which is the same shape as its ⌘Z defect. So `test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain` sends a real `NSEvent` through `window.sendEvent(_:)` and reads what reached DISK. **Do not replace it with a test that calls `deleteSelection()`**; that is precisely the test that would have passed throughout 1C-a.

---

## Accessibility — we own the tree (§7A.6)

Drawn content has no accessibility tree, and §7A.6 calls one "not optional in a writing tool". `CanvasAccessibility` mirrors the scene graph: **every node, all of them, in rows-then-columns reading order** (a proximity walk over the y-sorted list, starting a new band when the gap to the previous card exceeds `rowBand` — deliberately not a `(y / rowBand).rounded(.down)` grid, which reads two cards 2 pt apart as different rows whenever they straddle a multiple of 60). Never `.accessibilityElement(children: .ignore)` on the stack.

Two rules keep it off the frame path, and both are needed:

- **Elements carry content-space frames and are rebuilt from `.onChange(of: sceneRevision)`** — never inside `body`, and **never from `revision`**. `revision` is bumped by `handleDrag(.changed)` and by the timeline's per-frame `.onChange(of: context.date)`; keying the tree on it sorts the scene and copies every scrap's string at 60–120 Hz through any drag, coast or straighten.
- **The synthetic children live in `CanvasAXChildren`, used with `.equatable()`.** Inline in `body`, the `ForEach` reads `camera` and so rebuilds N views per frame. Extracted, SwiftUI skips it unless the elements or the camera actually moved — which covers every animation path here. A pan or a zoom does still rebuild it; that is accepted, bounded by the 2,000-node number, and the thing to verify before reaching for `.scaleEffect` over the AX layer is whether SwiftUI resolves accessibility frames through it at all.

**Known divergence, open for smoke:** the focused scrap is announced **twice**. The synthetic twin stays in the tree beside the real `NSTextView`, and because the rebuild is gated on `sceneRevision` its value is the text as of *entry* — so a VoiceOver user walking the canvas mid-visit meets the same card twice with two different strings. It refreshes on leaving. Whether `elements` needs to know the focused id is a question for a VoiceOver walk, not for a unit test.

---

## Scale

**Supported: 2,000 nodes** (`CanvasPerformanceProbeTests.supportedNodeCount`). Not a hard cap — nothing enforces it — but the number the culling probe defends. It is far above any real canvas (a Playlist-scale collection is tens of nodes); tldraw ships a hard 4,000-shape cap, Excalidraw degrades near 5,000. Above it, expect the *draw* pass rather than the culling to become the limit.

**Be precise about what defends that number**, because the probe's own comments were not, once:

- `test_culledSetDependsOnViewportNotSceneSize` is an **output-invariance** assertion, not a complexity one. It pins that culling happens and that its result is independent of scene size. It cannot see that `visibleNodes` does O(scene) internal work — `nodes(intersecting:)` filters `byID.values` before sorting, and that linear scan is unavoidable because **there is no spatial index.** (Its docstring used to claim to be a complexity assertion; corrected 2026-07-26.)
- **The three measured figures:** cull of 2,000 nodes **0.082 ms/frame** (~0.5% of a 60 Hz frame); hit test over 2,000 nodes **0.052 ms**; a zoomed-out cull returning 820 nodes in **1.429 ms**.
- **The 8 ms budgets are scoped to catching O(n²)**, and do that well — an O(n²) blowup at n = 2,000 is a ~2,000× regression, nowhere near survivable in ~100× headroom. They are **not** guaranteed to catch the specific regression `CanvasScene`'s own doc comment warns against: reverting `nodes(intersecting:)` from filter-then-sort to sort-then-filter is roughly a `log(2000) ≈ 11`× constant factor, plausibly inside that headroom. Read the doc comment, don't lean on the budget.
- **Nothing exercises `CanvasRenderer.draw` directly** — `GraphicsContext` is not practically constructible in XCTest. The transitive argument holds and is stated here rather than left implicit: `draw`'s only scene-size-dependent step *is* `visibleNodes`, and its per-node body is bounded by the same output count, which `test_aFullSceneStillCullsToAHandful` already bounds below 60. That is an inference, not a measurement.

---

## Writing tests in this area

- **`CanvasView.swift` has FIVE source-layout contracts**, documented in a header comment at the top of that file and enforced by grep tests elsewhere — declaration order, declaration adjacency, blank-line separation, and two raw-source scans. **Read that header before reformatting anything in the file**, because a reformat breaks one of them with a failure message pointing somewhere else entirely (and contract 1 *crashes* the test rather than failing it). The fifth is the sharpest: naming `accessibilityHidden(true)` or `accessibilityElement(children: .ignore)` **in a comment** fails a raw-source scan exactly as calling either would. It cost Task 14 a red suite.
- **`pump()` in `CanvasViewMountingTests` does NOT wait for its argument** — `RunLoop.run(until:)` returns as soon as it has nothing left to service, so `pump(1.8)` measured 0.76 s (the 750 ms save debounce, the last source on the loop). **`waitOut(_:)` is the one to use for any assertion about elapsed time.** `test_aPauseInsideAScrapEndsTheStepWhereTheWriterStopped` is the test that depends on it — its whole subject is that `ScrapUndoBeat.idleSeconds` of wall clock passes between two runs of typing — and it shipped with `pump`, passing on incidental run-loop sources rather than on anything it controlled. A new timing test written with `pump` will silently measure nothing.
- **`NSTextView.mouseDown` runs a modal event-tracking loop**, so a post-then-pump harness deadlocks. Post both the mouseDown and the mouseUp *before* pumping.
- **Every negative result needs a control that passed.** Thirteen unfalsifiable assertions were found and rewritten across this slice, most of them in tests whose *messages* claimed to catch the thing they were blind to. `[] == [].sorted()` is true; `sorted(by: >)` is stable and so passes under no decay at all; a proportionality test whose two fixtures share a grid cell proves nothing.
- **Raster fixtures:** the test process runs under DarkAqua. Resolving a dynamic `NSColor` without `performAsCurrentDrawingAppearance` gives you the dark value under a light-mode render — that is how a white-bitmap ink test came to measure zero ink and pass everywhere except a dark-mode Mac.
- **A `NotificationCenter.default.post(` anywhere in this area *or its tests* needs `// adr-0021-ok:`** on the line the call starts. The ADR 0021 *post* pattern is unconditional; only the *subscribe* patterns are scoped to `.maugham` names — which is why observing `NSApplication.willTerminateNotification` needs no annotation.

---

## What 1C-a deliberately does not do

Item nodes render as **placeholder cards carrying their reference id** — dashed border, `Item · <refId>`. That is the finished behaviour *for this slice*, not a stub awaiting a later milestone.

- **1C-d:** the drop target, `DropClassification` for browser drags, the real title, kind glyph and thumbnail, a `CGImageSource` downsampling path and a bounded cache keyed by path (tripwire 22).
- **1C-b:** regions, and `CanvasModel`.
- **1C-c:** lines, and promotion.

**Deleting a scrap was that gap, and 1C-b closed it.** ⌫ with something selected is `CanvasView.deleteSelection()`, reached from `CanvasEventNSView.keyDown` — see "Delete" below.

**This is a slice boundary, not a milestone one.** Spec §8A.1 puts **images inside milestone M1C** — "not deferred past it" — and says in the same breath that no plan may cite it as authorising their omission. Nothing here may be quoted to that end either. What 1C-a defers is the order of work, not the work.
