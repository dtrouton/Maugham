# Planning canvas 1C-a — surface and scraps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Plan persona's centre column — a pannable, zoomable canvas that draws **scraps**, mounts one real editor on the focused scrap, and carries undo, momentum and an accessibility tree.

**Architecture:** A single SwiftUI `Canvas` draws every node off a model that already owns each node's position, so there is no geometry to read back. The camera is a manual CTM (`cx.translateBy`/`cx.scaleBy`) driven by a transparent `NSViewRepresentable` that overrides `scrollWheel(with:)`/`magnify(with:)` — **not** `NSScrollView` magnification, which the spike proved cannot translate coordinates into SwiftUI content. Scrap text is laid out through a TextKit 2 stack that is *the same stack* the mounted `NSTextView` edits, so drawn and edited glyphs land on identical pixels. The ground is a Metal shader in a sibling layer beneath the content, never an overlay.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, TextKit 2 (`NSTextContentStorage` / `NSTextLayoutManager`), Metal `[[stitchable]]` shader (macOS 14+), XCTest.

## Global Constraints

- **This slice is SCRAPS ONLY — and that is a *slice* boundary, never a milestone one.** Spec §8A.1 gives *item* nodes (research notes, palette cards, images dragged in from the binder) to a separate plan, **1C-d**, and says in the same breath that **images are in scope for milestone M1C, not deferred past it**: M1C is not finished without them, and *no plan may cite §8A.1 as authorising their omission from the milestone* — this one included. What 1C-a defers is the order of work, not the work. Task 17 records the boundary in the ADR so it stays a decision rather than becoming an accident. In 1C-a:
  - The `CanvasNodeKind.item(referenceId:)` case and the `CanvasNodeID.item(_:)` id spelling **stay** in the model and the codec — plans 1C-b and 1C-c already consume them and must not break.
  - An item node **renders as a placeholder card** carrying its reference id. That is the finished behaviour *for this slice*; 1C-d replaces it with the real title, kind glyph and thumbnail.
  - **Do not build:** a drop target, `CanvasItemPresentation` or any title/thumbnail resolution, any image decoding, downsampling or cache, any `.draggable`/`.dropDestination`/`DropClassification` wiring. If a task seems to need one of these, it belongs to 1C-d — stop and say so rather than inventing it.
- **Mac-only.** `Packages/MaughamCore` and `MaughamPhone` are untouched, exactly as 1B was (spec §9). Nothing in this plan may add a file under either.
- **Deployment target macOS 14.0.** No API newer than 14.0 without a fallback.
- **Plain text on disk.** Scrap *text* is content and lives in `canvas.md` at project root. Positions, geometry and seeds are derived UI state and live in `.maugham/canvas.json` (spec §8).
- **The canvas never writes to a research note, palette card or image** (spec §8). Item nodes hold a reference and a position, nothing else.
- **`ProjectWindow.body`'s expression budget is zero.** No new top-level modifier. The canvas reaches the centre column by adding `case canvas` to `BinderSegment` and to `Persona.binderSegments(for:)` — `ProjectWindow.existingEditorSwitch` already routes on `binderSegment`.
- **`BinderSegmentPicker` requires uniform `Image` children** — every `BinderSegment` must return an SF Symbol from `pickerSymbolName`. Mixed `Image`/`Text` in that `ForEach` shipped smoke defect C on 2026-07-25.
- **Never `.scaleEffect` for zoom.** It scales rendered output (blurry text), reports unscaled geometry, and breaks `NSCursor` tracking (spec §7A.1).
- **Seeded irregularity must be stable** — derived from the node id, never random per frame (spec §7.2). It applies to the **whole card**, chrome and text together. The card that takes focus **animates to level over ~120 ms and settles back on blur** (spec §7A.5) — the straighten is the focus affordance, and it is what lets the editor always *become the visible text* axis-aligned. The editor itself mounts on the click, so no keystroke is lost; only its visibility waits. Task 7 owns the interpolated value; Task 10 owns the clock that drives it.
- **`NotificationCenter` (tripwire 21).** The *subscribe* patterns in `TripwireGrepTests` are scoped to `.maugham` names, so observing `NSApplication.willTerminateNotification` needs no annotation. **The *post* pattern is NOT scoped**: `TripwireGrepTests.adr0021PostPattern` is the bare string `NotificationCenter\.default\.post\(`, and `MaughamTests/` is one of the scanned directories. So any `NotificationCenter.default.post(` this plan writes — including the one in Task 5's test — must carry `// adr-0021-ok: <reason>` **on the line where the call starts**, or `test_noRawMaughamPostsOrSubscriptionsOutsideWrapper` fails. No `maugham.*` post or subscription outside `MaughamEvent` at all; nothing here needs one.
- **`ContentUnavailableView` needs `.frame(maxWidth: .infinity, maxHeight: .infinity)`** and the enclosing `VStack` needs `alignment: .top` (tripwire 15 — recurred 4+ times).
- **`Maugham.xcodeproj/` is generated and gitignored.** Never `git add` anything under it. A `project.pbxproj` in a diff is a red flag.
- **Every Step 2 begins with `./gen.sh &&`.** `MaughamTests/Canvas/` is a new directory: until `./gen.sh` runs, the new test file is not in the project at all, and `-only-testing MaughamTests/<Class>` then runs **zero** tests and reports **success** — a green RED step, which is worse than no RED step.
- `-only-testing` uses `MaughamTests/<ClassName>`, **never** a folder path.
- Run `./gen.sh` after adding any new source file. Run `xcodebuild` in the **foreground** (timeout 600000). Any task touching a view needs a **Release** build before it is called done — the Release type-check budget is stricter than Debug and v0.8.0 shipped a Release-only failure this way.

## Cross-plan contract with 1C-b and 1C-c

1C-a ships the surface; 1C-b (regions) and 1C-c (lines and promotion) build on it. Two of those seams are worth stating here so nobody has to reverse-engineer them.

**Who owns the scene.** In 1C-a, `CanvasView` owns `scene`, `scraps`, `layouts`, `camera`, `editingNodeID` and `caretIndex` as `@State`. **1C-b Task 4 introduces `@Observable final class CanvasModel` and moves `scene`, `scraps`, selection, the `CanvasStore` and the undo manager into it**, because the region inspector in the right-hand column needs the same scene the canvas draws. `camera`, `layouts`, `editingNodeID` and `caretIndex` stay in `CanvasView` — they are properties of one *view* of the canvas. That move is expected, planned, and is 1C-b's work, not 1C-a's. Do not build `CanvasModel` here.

**Where undo lives.** `CanvasUndo` is built in **1C-a Task 15**, snapshot-based, and 1C-b Task 4 rebinds it to `CanvasModel` without changing the class. Task 15 states the reasoning in full.

**Three spellings 1C-b's Interfaces block currently gets wrong** (its text was written against an earlier draft of this plan). Whoever executes 1C-b should reconcile against *this* file, which is the source of truth for 1C-a's API:

| 1C-b says | 1C-a actually ships | Why |
|---|---|---|
| `CanvasStore.flush(scene:scraps:)` | `CanvasStore.flush()` — no arguments | The store keeps the last debounced payload so it can flush on `NSApplication.willTerminateNotification`. `.onDisappear` does not fire on quit. Use `save(scene:scraps:)` for an immediate write with a payload in hand. |
| `ProjectStore.paletteSwatchColors: [Color]` | `ProjectStore.paletteSwatchHexes() -> [String]` | `PaletteCard.swatches` is `[String]` hex and `MaughamCore`'s `PaletteCard.color(fromHex:)` is the one parser. A `[Color]` seam forces a second conversion site and hides malformed hexes behind a silent `.clear`. |
| `CanvasView(model:projectRoot:paletteSwatches: [Color])` | 1C-a ships `CanvasView(projectRoot:paletteSwatchHexes:)`; 1C-b changes the initialiser | Keep the hex spelling when adding `model:`. |

## Evidence this plan is built on

`docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md` — read it before Task 3. Three findings are load-bearing and are repeated at their tasks:

1. `NSTextContentStorage.textStorage = NSTextStorage(...)`, **never** `.attributedString = ...`. The latter renders perfectly and silently refuses every keystroke.
2. `lineFragmentPadding = 0` (defaults to 5), `widthTracksTextView = false`, `textContainerInset = .zero`.
3. Draw at the window's true `backingScaleFactor` × camera zoom — **never** a hand-derived scale. Task 7 pins this.

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Canvas/CanvasNode.swift` | `CanvasNode`, `CanvasNodeKind`, `CanvasNodeID`, `CanvasCardMetrics` |
| `Maugham/Canvas/CanvasScene.swift` | The whole scene: nodes in z-order, lookup, mutation helpers. Pure value type. |
| `Maugham/Canvas/ScrapText.swift` | The `canvas.md` plain-text format: parse and render |
| `Maugham/Canvas/ScrapLayout.swift` | The shared TextKit 2 stack. The single place the three spike requirements are encoded. |
| `Maugham/Canvas/CanvasCamera.swift` | Pan/zoom state, the CTM, and the inverse transform used for hit testing |
| `Maugham/Canvas/CanvasSceneCodec.swift` | `Codable` shape + schema version for `.maugham/canvas.json` |
| `Maugham/Canvas/CanvasStore.swift` | Owns disk I/O for both `canvas.json` and `canvas.md`; debounced autosave; quit flush |
| `Maugham/Canvas/CanvasEventView.swift` | `NSViewRepresentable` overriding `scrollWheel`/`magnify`/mouse |
| `Maugham/Canvas/CanvasRenderer.swift` | The draw pass: culling, seeded rotation, focus-straighten interpolation (`CanvasFocusStraighten`), card drawing |
| `Maugham/Canvas/CanvasGround.metal` | `[[stitchable]]` grain shader, sampled in content space |
| `Maugham/Canvas/CanvasGround.swift` | The Metal-shader ground, as a sibling layer beneath content |
| `Maugham/Canvas/ScrapEditorHost.swift` | `ScrapEditorContainer` + `ScrapEditorHost` + `ScrapEditorGeometry` — one `NSTextView`, bounds-scaled by zoom |
| `Maugham/Canvas/CanvasView.swift` | Composes ground + `Canvas` + event view + editor host |
| `Maugham/Canvas/CanvasInteraction.swift` | Drag/resize/create state machine + `CanvasMomentum` |
| `Maugham/Canvas/CanvasAccessibility.swift` | The AX mirror of the scene graph (spec §7A.6) |
| `Maugham/Canvas/CanvasUndo.swift` | Canvas-scoped undo records |
| `Maugham/Canvas/AREA.md` | Area guidance |
| `Maugham/Models/BinderSegment.swift` | *Modify* — add `case canvas`, conform to `CaseIterable` |
| `Maugham/Models/Persona.swift` | *Modify* — Plan's `binderSegments(for:)` |
| `Maugham/Views/ProjectWindow.swift` | *Modify* — two switch arms + one comment |
| `Maugham/Views/BinderPaneToggle.swift` | *Modify* — one switch arm (line 28) |
| `Maugham/Views/CollectionBinderPaneToggle.swift` | *Modify* — one switch arm (line 36) |
| `Maugham/Stores/ProjectStore+Palette.swift` | *Modify* — `paletteSwatchHexes()` |

---

### Task 1: The scene model

**Files:**
- Create: `Maugham/Canvas/CanvasNode.swift`
- Create: `Maugham/Canvas/CanvasScene.swift`
- Test: `MaughamTests/Canvas/CanvasSceneTests.swift`

**Interfaces:**
- **Consumes:** nothing.
- **Produces:**
  - `struct CanvasNodeID: Hashable, Codable, Sendable` — `init(_ raw: String)`, `var raw: String`, `static func item(_ referenceId: String) -> CanvasNodeID`.
  - `enum CanvasNodeKind: Equatable, Sendable` — `case scrap`, `case item(referenceId: String)`.
  - `struct CanvasNode: Equatable, Sendable` — `id`, `kind`, `origin: CGPoint`, `width: CGFloat`, `cachedHeight: CGFloat?`, `z: Int`, `var frame: CGRect?`.
  - `enum CanvasCardMetrics` — `static let inset: CGFloat`, `static let minimumTextWidth: CGFloat`, `static func textWidth(forCardWidth:) -> CGFloat`, `static func cardHeight(forTextHeight:) -> CGFloat`, `static func textOrigin(inCard:) -> CGPoint`, `static func textSize(inCard:) -> CGSize`.
  - `struct CanvasScene: Equatable, Sendable` — `init(nodes:)`, `var nodes: [CanvasNode]`, `var unorderedNodes: [CanvasNode]`, `var count: Int`, `var isEmpty: Bool`, `node(_:)`, `insert(_:)`, `remove(_:)`, `move(_:to:)`, `setWidth(_:for:)`, `setCachedHeight(_:for:)`, `topmostNode(at:)`, `nodes(intersecting:)`, `var topZ: Int`.

**`nodes` sorts on every access, so nothing that runs per frame may touch it.** It is `O(n log n)` with a `String` comparison in the predicate, and at this plan's 2,000-node bound that is a real cost in a `body` or a draw loop. Three accessors exist so no caller has to pay it needlessly, and each states which one it is for:

- `nodes` — draw order, back to front. For the draw pass and for anything that genuinely needs the whole scene in order.
- `unorderedNodes` — every node, no defined order. For callers that impose their own; the accessibility tree sorts rows-then-columns, so paying for the draw-order sort first is pure waste.
- `count` — the node count without materialising or sorting anything. `CanvasAccessibility.summary` is read from `body`.

`topmostNode(at:)` and `nodes(intersecting:)` **filter first and order the survivors**, which is what makes culling and hit testing proportional to what they return rather than to the scene.

`width` is authoritative and height is derived (spec §7A.3). `cachedHeight` exists because §7A.3 requires caching the measured height so layout is stable until something forces a re-measure.

`CanvasCardMetrics` lives here rather than in the renderer because **both** the draw pass and the mounted editor read it. Two spellings of the inset would put drawn text and edited text on different rects — which is exactly the §7A.2 jump this whole architecture exists to prevent.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasSceneTests: XCTestCase {

    private func scrap(_ id: String, x: CGFloat, y: CGFloat, z: Int = 0) -> CanvasNode {
        CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                   origin: CGPoint(x: x, y: y), width: 240, z: z)
    }

    func test_insertAndLookup_roundTrips() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 10, y: 20))
        XCTAssertEqual(scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 10, y: 20))
        XCTAssertNil(scene.node(CanvasNodeID("nope")))
    }

    func test_move_changesOriginOnly() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        scene.move(CanvasNodeID("a"), to: CGPoint(x: 100, y: 50))
        let n = scene.node(CanvasNodeID("a"))
        XCTAssertEqual(n?.origin, CGPoint(x: 100, y: 50))
        XCTAssertEqual(n?.width, 240, "move must not disturb the authoritative width")
    }

    func test_setWidth_clearsTheDerivedHeight() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        scene.setCachedHeight(80, for: CanvasNodeID("a"))
        scene.setWidth(300, for: CanvasNodeID("a"))
        XCTAssertEqual(scene.node(CanvasNodeID("a"))?.width, 300)
        XCTAssertNil(scene.node(CanvasNodeID("a"))?.cachedHeight,
                     "a rewrapped scrap must be re-measured before it is hit-tested")
    }

    func test_topmostNodeAt_prefersHigherZ() {
        var scene = CanvasScene()
        scene.insert(scrap("low", x: 0, y: 0, z: 1))
        scene.insert(scrap("high", x: 0, y: 0, z: 9))
        scene.setCachedHeight(80, for: CanvasNodeID("low"))
        scene.setCachedHeight(80, for: CanvasNodeID("high"))
        XCTAssertEqual(scene.topmostNode(at: CGPoint(x: 5, y: 5))?.id, CanvasNodeID("high"))
    }

    func test_topmostNodeAt_missesOutsideAnyNode() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        scene.setCachedHeight(80, for: CanvasNodeID("a"))
        XCTAssertNil(scene.topmostNode(at: CGPoint(x: 900, y: 900)))
    }

    func test_nodeWithoutCachedHeight_isNotHitTestable() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        XCTAssertNil(scene.topmostNode(at: CGPoint(x: 5, y: 5)),
                     "an unmeasured node has no height and must not swallow clicks")
    }

    func test_remove_dropsTheNode() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        scene.remove(CanvasNodeID("a"))
        XCTAssertNil(scene.node(CanvasNodeID("a")))
    }

    func test_topZ_isTheHighestZOrZeroOnAnEmptyScene() {
        var scene = CanvasScene()
        XCTAssertEqual(scene.topZ, 0)
        scene.insert(scrap("a", x: 0, y: 0, z: 4))
        scene.insert(scrap("b", x: 0, y: 0, z: 2))
        XCTAssertEqual(scene.topZ, 4)
    }

    /// `nodes` sorts on every access. `count` and `unorderedNodes` exist so that
    /// callers running inside `body` or a draw loop do not have to.
    func test_countAndUnorderedNodesDoNotDependOnTheSortedList() {
        var scene = CanvasScene()
        for i in 0..<20 { scene.insert(scrap("n\(i)", x: CGFloat(i), y: 0, z: 20 - i)) }
        XCTAssertEqual(scene.count, 20)
        XCTAssertEqual(Set(scene.unorderedNodes.map(\.id)),
                       Set(scene.nodes.map(\.id)),
                       "unorderedNodes must be the same SET, only unsorted")
    }

    /// Culling and hit testing filter first and order the survivors. That must
    /// not change the answer — the front-most card is still the front-most card.
    func test_filterFirstOrderingMatchesTheDrawOrder() {
        var scene = CanvasScene()
        for (i, z) in [7, 2, 9, 2, 5].enumerated() {
            scene.insert(scrap("n\(i)", x: 0, y: 0, z: z))
            scene.setCachedHeight(80, for: CanvasNodeID("n\(i)"))
        }
        let all = CGRect(x: -1000, y: -1000, width: 4000, height: 4000)
        XCTAssertEqual(scene.nodes(intersecting: all).map(\.id), scene.nodes.map(\.id),
                       "culling must return draw order, back to front")
        XCTAssertEqual(scene.topmostNode(at: CGPoint(x: 5, y: 5))?.id,
                       scene.nodes.last?.id,
                       "the hit test must agree with the draw order about which "
                       + "card is in front — including the id tiebreak at equal z")
    }

    // MARK: - The item id namespace
    //
    // 1C-a renders item nodes as placeholders and 1C-d completes them, but the
    // ID SPELLING is consumed by 1C-b and 1C-c and is pinned here.

    func test_itemNodeIDEncodesItsReference() {
        XCTAssertEqual(CanvasNodeID.item("r-9").raw, "item:r-9")
    }

    func test_itemAndScrapWithTheSameRawStringDoNotCollide() {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                                origin: .zero, width: 180))
        scene.insert(CanvasNode(id: CanvasNodeID("r-9"), kind: .scrap,
                                origin: .zero, width: 240))
        XCTAssertEqual(scene.nodes.count, 2)
    }

    // MARK: - Card metrics

    func test_textWidthIsTheCardWidthLessBothInsets() {
        XCTAssertEqual(CanvasCardMetrics.textWidth(forCardWidth: 240),
                       240 - CanvasCardMetrics.inset * 2)
    }

    func test_textWidthNeverCollapsesBelowTheMinimum() {
        XCTAssertEqual(CanvasCardMetrics.textWidth(forCardWidth: 4),
                       CanvasCardMetrics.minimumTextWidth)
    }

    func test_cardHeightAndTextSizeAreInverses() {
        let cardHeight = CanvasCardMetrics.cardHeight(forTextHeight: 88)
        let frame = CGRect(x: 10, y: 20, width: 240, height: cardHeight)
        XCTAssertEqual(CanvasCardMetrics.textSize(inCard: frame).height, 88, accuracy: 0.0001)
        XCTAssertEqual(CanvasCardMetrics.textSize(inCard: frame).width,
                       CanvasCardMetrics.textWidth(forCardWidth: 240), accuracy: 0.0001)
    }

    func test_textOriginIsInsetFromTheCardOrigin() {
        let frame = CGRect(x: 10, y: 20, width: 240, height: 100)
        XCTAssertEqual(CanvasCardMetrics.textOrigin(inCard: frame),
                       CGPoint(x: 10 + CanvasCardMetrics.inset, y: 20 + CanvasCardMetrics.inset))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasSceneTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasScene' in scope`.

(`./gen.sh` first, always: `MaughamTests/Canvas/` is a new directory and an ungenerated test file makes `-only-testing` run zero tests and report success.)

- [ ] **Step 3: Write the implementation**

`Maugham/Canvas/CanvasNode.swift`:

```swift
import Foundation

/// Stable identity for a canvas node. A scrap's id is minted here; an item
/// node's id is derived from the thing it points at, so the same research
/// note can never appear twice on the canvas by accident.
public struct CanvasNodeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }

    /// Item nodes are identified by what they reference. Two adds of the same
    /// research item resolve to one node.
    ///
    /// 1C-a does not create item nodes — 1C-d owns the drag-in route (spec
    /// §8A.1) — but this spelling is consumed by 1C-b and 1C-c and by the
    /// sidecar codec, so it lives here and is pinned by test.
    public static func item(_ referenceId: String) -> CanvasNodeID {
        CanvasNodeID("item:\(referenceId)")
    }
}

/// What a node *is*. The distinction is the whole data model (spec §3):
/// items already exist and the canvas holds only their position; scraps exist
/// only here.
public enum CanvasNodeKind: Equatable, Sendable {
    /// A loose thought typed straight onto the canvas. Text lives in
    /// `canvas.md`, keyed by the node id. This is the ONLY kind 1C-a creates.
    case scrap
    /// Something that already exists in the project. `referenceId` is the
    /// research item id / palette card id. The canvas NEVER writes to it.
    ///
    /// In 1C-a an item node draws as a PLACEHOLDER card carrying its reference
    /// id. 1C-d adds the drop target, the real title, the kind glyph and the
    /// thumbnail path. Do not build any of that here.
    case item(referenceId: String)
}

/// One node. `width` is authoritative; the text reflows to fit and the height
/// is derived (spec §7A.3). `cachedHeight` is the last measured height, held so
/// layout is stable until something forces a re-measure.
public struct CanvasNode: Equatable, Sendable {
    public let id: CanvasNodeID
    public var kind: CanvasNodeKind
    public var origin: CGPoint
    /// The CARD's width, not the text box's — see `CanvasCardMetrics`.
    public var width: CGFloat
    public var cachedHeight: CGFloat?
    public var z: Int

    public init(id: CanvasNodeID,
                kind: CanvasNodeKind,
                origin: CGPoint,
                width: CGFloat,
                cachedHeight: CGFloat? = nil,
                z: Int = 0) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.width = width
        self.cachedHeight = cachedHeight
        self.z = z
    }

    /// The node's rect in canvas content coordinates, or nil if it has never
    /// been measured. A node with no measured height must not be hit-testable —
    /// guessing a height would let an unmeasured node swallow clicks.
    public var frame: CGRect? {
        guard let h = cachedHeight else { return nil }
        return CGRect(origin: origin, size: CGSize(width: width, height: h))
    }
}

/// Card geometry, in ONE place.
///
/// `CanvasNode.width` is the CARD width; the text box inside it is inset on all
/// four sides, and the card's height is the measured text height plus the same
/// inset twice. Both `CanvasRenderer` (which draws the text) and `CanvasView`
/// (which mounts the editor over it) read these functions.
///
/// A second spelling of the inset anywhere would put the drawn glyphs and the
/// edited glyphs on different rects — which is precisely the §7A.2 "text jumps
/// on focus" failure, arriving by the back door.
public enum CanvasCardMetrics {
    /// Text flush to a card edge reads as broken. 10pt is the same breathing
    /// room `PaletteCardTile` gives its content.
    public static let inset: CGFloat = 10
    /// Below this a scrap wraps to one word per line and the measured height
    /// runs away.
    public static let minimumTextWidth: CGFloat = 40

    public static func textWidth(forCardWidth width: CGFloat) -> CGFloat {
        max(minimumTextWidth, width - inset * 2)
    }

    public static func cardHeight(forTextHeight height: CGFloat) -> CGFloat {
        height + inset * 2
    }

    public static func textOrigin(inCard frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + inset, y: frame.minY + inset)
    }

    public static func textSize(inCard frame: CGRect) -> CGSize {
        CGSize(width: textWidth(forCardWidth: frame.width),
               height: max(0, frame.height - inset * 2))
    }
}
```

`Maugham/Canvas/CanvasScene.swift`:

```swift
import Foundation

/// Every node on one project's canvas. One canvas per project (spec §2);
/// regions do all the dividing, and they arrive in 1C-b.
///
/// Pure value type with no I/O — `CanvasStore` owns persistence. Nodes are held
/// in a dictionary for lookup plus an explicit z-order, because the draw pass
/// walks in z-order and hit testing walks it in reverse.
public struct CanvasScene: Equatable, Sendable {
    private var byID: [CanvasNodeID: CanvasNode]

    public init(nodes: [CanvasNode] = []) {
        byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
    }

    /// Nodes in draw order — back to front. The id is the tiebreak so the order
    /// is total and stable: two nodes at the same z must not swap places
    /// between frames, or the front-most-wins hit test becomes a coin flip.
    ///
    /// **This sorts on every access.** Nothing that runs per frame — a `body`, a
    /// draw loop, an accessibility rebuild — may reach for it without a reason.
    /// Use `unorderedNodes` when you impose your own order and `count` when you
    /// only want the number.
    public var nodes: [CanvasNode] {
        byID.values.sorted(by: Self.isBehind)
    }

    /// Every node, in NO defined order. For callers that sort by something else
    /// — `CanvasAccessibility` reads the canvas out in rows then columns, so
    /// paying for the draw-order sort first and then re-sorting is pure waste.
    public var unorderedNodes: [CanvasNode] { Array(byID.values) }

    /// The node count, without materialising or sorting the list.
    /// `CanvasAccessibility.summary` is read from `body`.
    public var count: Int { byID.count }

    public var isEmpty: Bool { byID.isEmpty }

    /// The total draw order: z, then id. Factored out so `nodes`,
    /// `topmostNode(at:)` and `nodes(intersecting:)` cannot disagree about which
    /// card is in front.
    private static func isBehind(_ a: CanvasNode, _ b: CanvasNode) -> Bool {
        (a.z, a.id.raw) < (b.z, b.id.raw)
    }

    /// Highest z in the scene, or 0 when empty. `+ 1` is where a new node goes.
    public var topZ: Int { byID.values.map(\.z).max() ?? 0 }

    public func node(_ id: CanvasNodeID) -> CanvasNode? { byID[id] }

    public mutating func insert(_ node: CanvasNode) { byID[node.id] = node }

    public mutating func remove(_ id: CanvasNodeID) { byID[id] = nil }

    public mutating func move(_ id: CanvasNodeID, to origin: CGPoint) {
        byID[id]?.origin = origin
    }

    public mutating func setWidth(_ width: CGFloat, for id: CanvasNodeID) {
        // A width change invalidates the derived height; the next measure pass
        // refills it. Leaving a stale height here is how a resized scrap would
        // hit-test against its old shape.
        byID[id]?.width = width
        byID[id]?.cachedHeight = nil
    }

    public mutating func setCachedHeight(_ height: CGFloat, for id: CanvasNodeID) {
        byID[id]?.cachedHeight = height
    }

    /// Highest node whose measured frame contains `point`, in content
    /// coordinates. Front-most wins.
    ///
    /// Filter first, then take the maximum — `nodes.reversed().first { … }`
    /// would sort the whole scene on every click for one answer.
    public func topmostNode(at point: CGPoint) -> CanvasNode? {
        byID.values
            .filter { $0.frame?.contains(point) == true }
            .max(by: Self.isBehind)
    }

    /// Nodes whose frame intersects `rect`, in draw order. This is the whole of
    /// virtualisation (spec §7A.1): culling is an intersection test in the draw
    /// loop, not a `ForEach` the renderer has to keep view identity for.
    ///
    /// Filter first, then order the survivors. Sorting the scene and then
    /// filtering gives the same answer for `O(scene log scene)` instead of
    /// `O(scene + visible log visible)`, inside the loop Task 16 asserts is
    /// proportional to the viewport.
    public func nodes(intersecting rect: CGRect) -> [CanvasNode] {
        byID.values
            .filter { $0.frame?.intersects(rect) == true }
            .sorted(by: Self.isBehind)
    }
}
```

- [ ] **Step 4: Regenerate the project and run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasSceneTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 16 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasNode.swift Maugham/Canvas/CanvasScene.swift MaughamTests/Canvas/CanvasSceneTests.swift project.yml
git commit -m "feat(canvas): scene model — nodes, z-order, card metrics, culling and hit-test primitives"
```

---

### Task 2: The scrap text file (`canvas.md`)

**Files:**
- Create: `Maugham/Canvas/ScrapText.swift`
- Test: `MaughamTests/Canvas/ScrapTextTests.swift`

**Interfaces:**
- **Consumes:** `CanvasNodeID` (Task 1).
- **Produces:** `enum ScrapText` with `static let banner: String`, `static func render(_ scraps: [CanvasNodeID: String]) -> String`, `static func parse(_ markdown: String) -> [CanvasNodeID: String]`.

**Decision this plan makes** (spec §10 left it open): scraps live in **`canvas.md` at project root**, one file. Not under `research/` — §3.2 requires that scraps do *not* appear in the research tree, and `research/` is exactly where the tree looks. Not one file per region — regions are a 1C-b concept and a scrap can be loose.

Format: one `##` heading per scrap carrying the node id, then the scrap's text. Readable in any editor forever, which is the whole point of §3.2.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class ScrapTextTests: XCTestCase {

    func test_renderThenParse_roundTrips() {
        let scraps: [CanvasNodeID: String] = [
            CanvasNodeID("s1"): "The falls at night.",
            CanvasNodeID("s2"): "October's doctor was kind about it.",
        ]
        let parsed = ScrapText.parse(ScrapText.render(scraps))
        XCTAssertEqual(parsed, scraps)
    }

    func test_render_isStableAcrossCalls() {
        let scraps: [CanvasNodeID: String] = [
            CanvasNodeID("b"): "second", CanvasNodeID("a"): "first",
        ]
        XCTAssertEqual(ScrapText.render(scraps), ScrapText.render(scraps),
                       "dictionary order must not leak into the file, or every "
                       + "save rewrites the whole thing and churns the diff")
    }

    func test_parse_keepsMultipleParagraphsAndBlankLines() {
        let md = """
        <!-- maugham:canvas-scraps -->

        ## s1

        First paragraph.

        Second paragraph.
        """
        XCTAssertEqual(ScrapText.parse(md)[CanvasNodeID("s1")],
                       "First paragraph.\n\nSecond paragraph.")
    }

    func test_parse_toleratesAnUnknownPreamble() {
        let md = """
        Some writer wrote a note at the top of the file.

        ## s1

        Body.
        """
        XCTAssertEqual(ScrapText.parse(md)[CanvasNodeID("s1")], "Body.")
    }

    func test_parse_emptyFileYieldsNoScraps() {
        XCTAssertTrue(ScrapText.parse("").isEmpty)
    }

    func test_roundTrip_preservesTextThatLooksLikeAHeading() {
        let scraps = [CanvasNodeID("s1"): "## not a scrap heading\n\nbody"]
        // A scrap whose own text starts with ## must survive; the renderer
        // indents it so the parser cannot mistake it for a new scrap.
        XCTAssertEqual(ScrapText.parse(ScrapText.render(scraps)), scraps)
    }

    func test_roundTrip_preservesTextThatAlreadyBeginsWithSpaceThenHashes() {
        // The escape adds ONE space to any line that reads as a heading once its
        // leading spaces are stripped, and the unescape removes exactly one from
        // the same class of line. A naive `hasPrefix(" ## ")` unescape eats a
        // space the writer typed.
        let scraps = [CanvasNodeID("s1"): " ## indented on purpose\n\nbody"]
        XCTAssertEqual(ScrapText.parse(ScrapText.render(scraps)), scraps)
    }

    func test_roundTrip_preservesAnEmptyScrap() {
        // A freshly created scrap has no text yet and must still round-trip,
        // or double-click-then-quit loses the node's very existence.
        let scraps = [CanvasNodeID("s1"): ""]
        XCTAssertEqual(ScrapText.parse(ScrapText.render(scraps)), scraps)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapTextTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'ScrapText' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The `canvas.md` format — the one place scrap *content* lives.
///
/// Scraps are plain text on disk (spec §3.2) so a writer can read them in any
/// editor forever. Positions live in the sidecar; the words do not. This file
/// sits at PROJECT ROOT, deliberately not under `research/`: §3.2 requires that
/// scraps do not appear in the research tree, and `research/` is where the tree
/// looks.
public enum ScrapText {

    /// Marks the file as Maugham's. Purely informational — the parser tolerates
    /// its absence, because a writer may well have edited the file by hand.
    public static let banner = "<!-- maugham:canvas-scraps -->"

    /// A scrap body line that would otherwise read as a scrap heading gets one
    /// space of indent on the way out, removed on the way in. Without this, a
    /// scrap whose text begins "## something" splits into two scraps on reload.
    ///
    /// The test is "does it read as a heading once its leading spaces are
    /// stripped", NOT "does it start with `## `". Both halves use the same test,
    /// so the pair is a bijection on every input. Keying the unescape on the
    /// literal `" ## "` instead would eat a space the writer typed, silently, on
    /// the one line where they had already indented a heading themselves.
    private static func readsAsHeading(_ line: some StringProtocol) -> Bool {
        line.drop(while: { $0 == " " }).hasPrefix("## ")
    }

    private static func escape(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { readsAsHeading($0) ? " " + $0 : String($0) }
            .joined(separator: "\n")
    }

    private static func unescape(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(" ") && readsAsHeading($0) ? String($0.dropFirst()) : String($0) }
            .joined(separator: "\n")
    }

    /// Deterministic: scraps are emitted in id order so that saving an
    /// unchanged canvas produces a byte-identical file.
    public static func render(_ scraps: [CanvasNodeID: String]) -> String {
        var out = [banner, ""]
        for id in scraps.keys.sorted(by: { $0.raw < $1.raw }) {
            out.append("## \(id.raw)")
            out.append("")
            out.append(escape(scraps[id] ?? ""))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    public static func parse(_ markdown: String) -> [CanvasNodeID: String] {
        var result: [CanvasNodeID: String] = [:]
        var currentID: CanvasNodeID?
        var body: [String] = []

        func flush() {
            guard let id = currentID else { return }
            // Trim only the blank lines the renderer added around the body. An
            // empty scrap therefore survives as "" rather than vanishing.
            var lines = body
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            result[id] = unescape(lines.joined(separator: "\n"))
            body = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                let raw = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                currentID = raw.isEmpty ? nil : CanvasNodeID(raw)
            } else if currentID != nil {
                body.append(String(line))
            }
            // Anything before the first heading is preamble and is dropped —
            // the file may have been hand-edited.
        }
        flush()
        return result
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapTextTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/ScrapText.swift MaughamTests/Canvas/ScrapTextTests.swift project.yml
git commit -m "feat(canvas): canvas.md scrap-text format, deterministic and hand-edit tolerant"
```

---

### Task 3: The shared TextKit stack — and the §7A.2 pin

**Read `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md` before starting.** This task encodes the three requirements it found. Getting any of them wrong produces a scrap that looks perfect and either refuses to accept typing or jumps on every focus.

**Files:**
- Create: `Maugham/Canvas/ScrapLayout.swift`
- Test: `MaughamTests/Canvas/ScrapLayoutTests.swift`

**Interfaces:**
- **Consumes:** nothing.
- **Produces:** `final class ScrapLayout` with
  - `init(text: String, width: CGFloat, font: NSFont)`
  - `var text: String { get }`
  - `var measuredHeight: CGFloat { get }`
  - `func setWidth(_ width: CGFloat)`
  - `func draw(into cgContext: CGContext, at origin: CGPoint)`
  - `func makeEditor(frame: CGRect) -> NSTextView`
  - `func characterIndex(at localPoint: CGPoint) -> Int`
  - `var lineGeometrySignature: [String] { get }` — test seam, the fragment/line geometry the focus-blur pin compares
  - `var debugLineFragmentPadding: CGFloat { get }` — test seam
  - `var debugWidthTracksTextView: Bool { get }` — test seam

- [ ] **Step 1: Write the failing test**

This is the regression §7A.2 says to pin "the moment it works". It is the most likely thing to creep back.

```swift
import XCTest
import AppKit
@testable import Maugham

final class ScrapLayoutTests: XCTestCase {

    private let sample = "The falls at night: sodium light on the spray, and "
        + "nobody there but the man selling ponchos. October says the doctor "
        + "was kind about it, which is not the same as being right."

    private func layout(width: CGFloat = 240) -> ScrapLayout {
        ScrapLayout(text: sample, width: width,
                    font: NSFont(name: "Iowan Old Style", size: 13)
                        ?? .systemFont(ofSize: 13))
    }

    /// Put `editor` in a real window. `NSTextView` needs one before `insertText`
    /// does anything, and the spike's harness failures were all missing windows.
    @discardableResult
    private func host(_ editor: NSTextView) -> NSWindow {
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSView(frame: editor.frame)
        window.contentView?.addSubview(editor)
        editor.layoutSubtreeIfNeeded()
        return window
    }

    /// THE §7A.2 PIN. If drawn and edited layout differ by even a fraction, text
    /// visibly jumps every time the writer clicks in and again when they click
    /// out. Spike verified this holds; this test keeps it holding.
    func test_layoutIsIdenticalAcrossFocusAndBlur() {
        let l = layout()
        let beforeFocus = l.lineGeometrySignature
        XCTAssertFalse(beforeFocus.isEmpty)

        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240,
                                                height: l.measuredHeight))
        host(editor)

        XCTAssertEqual(l.lineGeometrySignature, beforeFocus,
                       "mounting the editor changed the layout — text will jump on focus")

        editor.removeFromSuperview()
        XCTAssertEqual(l.lineGeometrySignature, beforeFocus,
                       "unmounting the editor changed the layout — text will jump on blur")
    }

    /// The trap the spike found: with `attributedString` wiring the scrap
    /// renders perfectly and silently swallows every keystroke.
    func test_mountedEditorActuallyEditsTheSharedStack() {
        let l = layout()
        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240,
                                                height: l.measuredHeight))
        host(editor)

        XCTAssertEqual(editor.string.count, sample.count,
                       "the editor cannot see the text — this is the "
                       + "attributedString-instead-of-textStorage wiring bug")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(l.text.hasPrefix("Z"),
                      "typing did not reach the shared stack")
    }

    func test_containerDefaultsAreOverridden() {
        let l = layout()
        // lineFragmentPadding defaults to 5 and would shift drawn against edited.
        XCTAssertEqual(l.debugLineFragmentPadding, 0)
        XCTAssertFalse(l.debugWidthTracksTextView)
    }

    func test_mountedEditorHasZeroInsetAndLeavesUndoToTheCanvas() {
        let l = layout()
        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        XCTAssertEqual(editor.textContainerInset, .zero,
                       "a non-zero inset shifts edited text against drawn text")
        XCTAssertFalse(editor.allowsUndo,
                       "with allowsUndo the text view registers its OWN step on the "
                       + "shared canvas manager and the canvas snapshot registers a "
                       + "second one covering the same change — one keystroke, two "
                       + "steps, and the text view's step targets an NSTextStorage "
                       + "the next rebuildLayouts() orphans (Task 15)")
    }

    func test_measuredHeightIsPositiveAndGrowsAsWidthShrinks() {
        let wide = layout(width: 400).measuredHeight
        let narrow = layout(width: 200).measuredHeight
        XCTAssertGreaterThan(wide, 0)
        XCTAssertGreaterThan(narrow, wide, "narrower scrap must wrap to more lines")
    }

    func test_setWidth_reflowsAndChangesHeight() {
        let l = layout(width: 400)
        let before = l.measuredHeight
        l.setWidth(200)
        XCTAssertGreaterThan(l.measuredHeight, before)
    }

    /// Sample the MIDDLE of each line, derived from the layout itself. An
    /// earlier draft walked down in a literal 17 pt stride, which only samples
    /// distinct lines while Iowan Old Style 13's line height stays at or above
    /// 17 pt — a theme change or an OS font update would make the test start
    /// sampling the same line twice and fail for a reason that is not a bug.
    func test_characterIndexAtPoint_isMonotonicDownTheLines() {
        let l = layout()
        let lineCount = l.lineGeometrySignature.count
        XCTAssertGreaterThan(lineCount, 2, "the fixture must wrap to several lines")
        let lineHeight = l.measuredHeight / CGFloat(lineCount)
        let indices = (0..<lineCount).map {
            l.characterIndex(at: CGPoint(x: 90, y: (CGFloat($0) + 0.5) * lineHeight))
        }
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(Set(indices).count, indices.count)
    }

    func test_drawIntoContext_putsInkOnThePage() {
        let l = layout()
        let w = 480, h = Int(ceil(l.measuredHeight)) * 2
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: l.measuredHeight)
        ctx.scaleBy(x: 1, y: -1)
        l.draw(into: ctx, at: .zero)

        let bytes = UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self,
                                                                   capacity: ctx.bytesPerRow * h),
                                        count: ctx.bytesPerRow * h)
        let ink = stride(from: 1, to: bytes.count, by: 4).filter { bytes[$0] < 200 }.count
        XCTAssertGreaterThan(ink, 500, "nothing was drawn")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapLayoutTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'ScrapLayout' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import AppKit

/// One scrap's text, laid out ONCE through a TextKit 2 stack that is used for
/// BOTH the `Canvas` draw and the mounted `NSTextView`.
///
/// Spec §7A.2 names the drawn/edited seam the biggest risk in the design: if the
/// two layouts differ at all, text jumps every time the writer clicks in and
/// again when they click out. The mitigation is structural — there is only one
/// layout, and both consumers read it.
///
/// Three requirements, all verified by the 2026-07-25 rendering spike. Changing
/// any of them silently breaks the surface:
///
/// 1. `contentStorage.textStorage = NSTextStorage(...)`, NEVER
///    `contentStorage.attributedString = ...`. With `attributedString` the stack
///    lays out and draws perfectly, `textView.textContentStorage` is identity-equal
///    to ours, and yet `textView.textStorage` is nil, `textView.string` is empty,
///    and BOTH real keystrokes and `insertText` are silent no-ops. A scrap that
///    renders beautifully and refuses to accept a single character.
/// 2. `lineFragmentPadding = 0` (NSTextContainer defaults to 5),
///    `widthTracksTextView = false`, `textContainerInset = .zero`. Any one left
///    at its default shifts drawn against edited.
/// 3. Callers must draw at the window's true `backingScaleFactor` × camera zoom,
///    and must NEVER derive that scale by hand — deriving it from pixel width
///    bakes in AppKit's frame rounding and shifts glyphs by a subpixel, which is
///    the "text jumps" failure wearing a measurement-artifact disguise.
///    `CanvasRenderer` satisfies this by doing nothing: `GraphicsContext`'s
///    `withCGContext` already hands over a context at backing scale under the
///    camera CTM. Task 7 pins that no scale is derived anywhere in `Maugham/Canvas/`.
final class ScrapLayout {

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let container: NSTextContainer

    init(text: String, width: CGFloat, font: NSFont) {
        // REQUIREMENT 1 — see the class doc. Do not "simplify" this to
        // `contentStorage.attributedString = ...`.
        contentStorage.textStorage = NSTextStorage(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]))

        container = NSTextContainer(size: CGSize(width: width,
                                                 height: CGFloat.greatestFiniteMagnitude))
        // REQUIREMENT 2 — see the class doc.
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false

        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    var text: String { contentStorage.textStorage?.string ?? "" }

    var measuredHeight: CGFloat {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        // An empty scrap still needs a line's worth of height, or a freshly
        // created scrap has a zero-height frame and is not hit-testable — the
        // writer double-clicks, gets a caret, and can never click back into it.
        return max(ceil(layoutManager.usageBoundsForTextContainer.height),
                   Self.emptyLineHeight)
    }

    /// One line at the canvas font. Deliberately generous rather than measured:
    /// the exact value only matters until the first character is typed.
    private static let emptyLineHeight: CGFloat = 18

    func setWidth(_ width: CGFloat) {
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    /// Draw into a context whose CTM the caller has already set to the camera
    /// (translate + scale) and which is in top-left (flipped) text coordinates.
    /// The caller applies NO scale of its own — see requirement 3.
    func draw(into cgContext: CGContext, at origin: CGPoint) {
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let p = fragment.layoutFragmentFrame.origin
            fragment.draw(at: CGPoint(x: origin.x + p.x, y: origin.y + p.y), in: cgContext)
            return true
        }
    }

    /// Mount a real editor on THIS stack. The returned view shares the container,
    /// so what it edits is what we draw.
    func makeEditor(frame: CGRect) -> NSTextView {
        let tv = NSTextView(frame: frame, textContainer: container)
        tv.textContainerInset = .zero          // REQUIREMENT 2
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        // DELIBERATELY false. The canvas undo manager reaches this view through
        // the responder chain (`ScrapEditorContainer.undoManager`), so ⌘Z while
        // editing runs the CANVAS stack. If the view also registered its own
        // typing steps on that same manager, every keystroke would land twice:
        // the writer's ⌘Z would run the canvas snapshot (reverting the edit),
        // and the text view's queued step would still be sitting there pointed
        // at an `NSTextStorage` that `rebuildLayouts()` has since replaced — so
        // the second ⌘Z would appear to do nothing. Snapshots own scrap text;
        // Task 15 states the decision and its cost in full.
        tv.allowsUndo = false
        return tv
    }

    /// Place the caret from the click point (spec §7A.2, the rule borrowed from
    /// Miro) so clicking into a scrap lands where the writer aimed. `localPoint`
    /// is relative to the TEXT origin, not the card origin — callers convert
    /// through `CanvasCardMetrics.textOrigin(inCard:)`.
    func characterIndex(at localPoint: CGPoint) -> Int {
        var index = 0
        var best = CGFloat.greatestFiniteMagnitude
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let base = contentStorage.offset(from: contentStorage.documentRange.location,
                                             to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let top = fragment.layoutFragmentFrame.origin.y + line.typographicBounds.minY
                let distance = abs(localPoint.y - (top + line.typographicBounds.height / 2))
                if distance < best {
                    best = distance
                    let inLine = line.characterIndex(
                        for: CGPoint(x: localPoint.x, y: line.typographicBounds.height / 2))
                    index = base + inLine
                }
            }
            return true
        }
        return index
    }

    // MARK: - Test seams

    /// The fragment and line geometry the focus/blur pin compares. Formatted to
    /// six decimal places so a subpixel drift cannot hide behind `==` on Doubles.
    var lineGeometrySignature: [String] {
        var out: [String] = []
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let f = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments {
                out.append(String(format: "%.6f/%.6f/%.6f/%.6f/%.6f/%.6f",
                                  f.origin.x, f.origin.y,
                                  line.typographicBounds.origin.y,
                                  line.typographicBounds.width,
                                  line.glyphOrigin.x, line.glyphOrigin.y))
            }
            return true
        }
        return out
    }

    var debugLineFragmentPadding: CGFloat { container.lineFragmentPadding }
    var debugWidthTracksTextView: Bool { container.widthTracksTextView }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapLayoutTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 8 tests.

- [ ] **Step 5: Falsify the pin**

Prove the §7A.2 test can actually fail. Temporarily change `container.lineFragmentPadding = 0` to `= 5`, re-run, and confirm `test_containerDefaultsAreOverridden` fails by name. Then restore. Then temporarily change `contentStorage.textStorage = NSTextStorage(...)` to `contentStorage.attributedString = NSAttributedString(...)`, re-run, and confirm `test_mountedEditorActuallyEditsTheSharedStack` fails. Then restore and re-run to green.

Record both observed failure messages in the task report. A pin nobody has seen fail is not evidence.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/ScrapLayout.swift MaughamTests/Canvas/ScrapLayoutTests.swift project.yml
git commit -m "feat(canvas): shared TextKit 2 stack for drawn and edited scrap text

Draw and edit read ONE layout, so focus and blur cannot move the glyphs
(spec 7A.2). Encodes the three requirements the rendering spike found;
the focus/blur pin and the editability pin were both falsified before
being accepted."
```

---

### Task 4: The camera

**Files:**
- Create: `Maugham/Canvas/CanvasCamera.swift`
- Test: `MaughamTests/Canvas/CanvasCameraTests.swift`

**Interfaces:**
- **Consumes:** nothing.
- **Produces:** `struct CanvasCamera: Equatable` with `var pan: CGPoint`, `var zoom: CGFloat`, `static let zoomRange: ClosedRange<CGFloat>`, `func contentPoint(fromView:) -> CGPoint`, `func viewPoint(fromContent:) -> CGPoint`, `func visibleContentRect(viewSize:) -> CGRect`, `mutating func zoom(to:anchoringViewPoint:)`, `mutating func panBy(_ delta: CGSize)`.

Hit testing is an inverse transform plus a reverse-z rect test against the model (spec §7A.1). `contentPoint(fromView:)` is that inverse transform, and it is pure, so it is fully testable without a window.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasCameraTests: XCTestCase {

    func test_identityCamera_mapsPointsUnchanged() {
        let c = CanvasCamera()
        XCTAssertEqual(c.contentPoint(fromView: CGPoint(x: 10, y: 20)), CGPoint(x: 10, y: 20))
        XCTAssertEqual(c.viewPoint(fromContent: CGPoint(x: 10, y: 20)), CGPoint(x: 10, y: 20))
    }

    func test_viewAndContentTransforms_areInverses() {
        var c = CanvasCamera()
        c.zoom = 2.5
        c.pan = CGPoint(x: -300, y: 120)
        let p = CGPoint(x: 173.25, y: -44.5)
        let round = c.contentPoint(fromView: c.viewPoint(fromContent: p))
        XCTAssertEqual(round.x, p.x, accuracy: 0.0001)
        XCTAssertEqual(round.y, p.y, accuracy: 0.0001)
    }

    /// Zoom-to-cursor. The point under the pointer must not move — the runner-up
    /// architecture got this free from setMagnification(_:centeredAt:) and we
    /// owe it by hand.
    func test_zoomAnchoring_holdsThePointUnderTheCursor() {
        var c = CanvasCamera()
        let anchorView = CGPoint(x: 400, y: 250)
        let contentBefore = c.contentPoint(fromView: anchorView)
        c.zoom(to: 2.75, anchoringViewPoint: anchorView)
        let contentAfter = c.contentPoint(fromView: anchorView)
        XCTAssertEqual(contentAfter.x, contentBefore.x, accuracy: 0.0001)
        XCTAssertEqual(contentAfter.y, contentBefore.y, accuracy: 0.0001)
        XCTAssertEqual(c.zoom, 2.75, accuracy: 0.0001)
    }

    func test_zoomIsClampedToItsRange() {
        var c = CanvasCamera()
        c.zoom(to: 99, anchoringViewPoint: .zero)
        XCTAssertEqual(c.zoom, CanvasCamera.zoomRange.upperBound)
        c.zoom(to: 0.0001, anchoringViewPoint: .zero)
        XCTAssertEqual(c.zoom, CanvasCamera.zoomRange.lowerBound)
    }

    func test_clampedZoom_stillAnchors() {
        var c = CanvasCamera()
        let anchor = CGPoint(x: 120, y: 90)
        let before = c.contentPoint(fromView: anchor)
        c.zoom(to: 999, anchoringViewPoint: anchor)
        let after = c.contentPoint(fromView: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001,
                       "anchoring must use the CLAMPED zoom, not the requested one")
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
    }

    func test_visibleContentRect_shrinksAsZoomGrows() {
        var c = CanvasCamera()
        let size = CGSize(width: 800, height: 600)
        let at1 = c.visibleContentRect(viewSize: size)
        c.zoom = 2
        let at2 = c.visibleContentRect(viewSize: size)
        XCTAssertEqual(at1.width, 800, accuracy: 0.0001)
        XCTAssertEqual(at2.width, 400, accuracy: 0.0001)
    }

    /// `panBy` translates the CONTENT by the delta it is given. Direction is the
    /// caller's business — `CanvasEventNSView` decides what a scroll wheel means;
    /// the camera only applies it. (The old name for this test claimed the
    /// opposite of what the assertion checks.)
    func test_panBy_translatesContentByTheDelta() {
        var c = CanvasCamera()
        c.panBy(CGSize(width: 50, height: 30))
        XCTAssertEqual(c.viewPoint(fromContent: .zero), CGPoint(x: 50, y: 30))
    }

    func test_panBy_accumulates() {
        var c = CanvasCamera()
        c.panBy(CGSize(width: 50, height: 30))
        c.panBy(CGSize(width: -20, height: 5))
        XCTAssertEqual(c.pan, CGPoint(x: 30, y: 35))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasCameraTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasCamera' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Pan and zoom for the canvas.
///
/// Applied with `cx.translateBy` / `cx.scaleBy` inside the `Canvas` draw so
/// glyphs rasterise under the final CTM and stay crisp at every zoom. NOT
/// `.scaleEffect`, which scales rendered output, reports unscaled geometry
/// through `GeometryProxy`, and breaks `NSCursor` tracking (spec §7A.1).
///
/// NOT `NSScrollView.magnification` either: the 2026-07-25 spike confirmed on
/// macOS 26.5.2 that SwiftUI content hosted in a magnified `NSScrollView` is
/// completely unaware of the magnification — it reports the same `.global`
/// frame at every zoom, and above ~2x the mistranslated point falls outside the
/// view and clicks stop registering entirely.
struct CanvasCamera: Equatable {

    /// Where content origin sits in view coordinates.
    var pan: CGPoint = .zero
    var zoom: CGFloat = 1

    /// tldraw ships a comparable range. Below 0.1 nothing is legible; above 6
    /// a scrap fills the window and the writer wants the editor, not the canvas.
    static let zoomRange: ClosedRange<CGFloat> = 0.1...6.0

    func viewPoint(fromContent p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.x, y: p.y * zoom + pan.y)
    }

    /// The inverse transform. This IS the hit test (spec §7A.1) — convert the
    /// click into content space, then walk the model in reverse z-order. It
    /// never touches SwiftUI's event machinery.
    func contentPoint(fromView p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom)
    }

    /// What the viewport can see, in content coordinates. The draw loop culls
    /// against this: `guard rect.intersects(viewport) else { continue }`.
    func visibleContentRect(viewSize: CGSize) -> CGRect {
        CGRect(origin: contentPoint(fromView: .zero),
               size: CGSize(width: viewSize.width / zoom, height: viewSize.height / zoom))
    }

    /// Translate the content by `delta`, in VIEW points. Sign is the caller's
    /// decision; this only applies it.
    mutating func panBy(_ delta: CGSize) {
        pan.x += delta.width
        pan.y += delta.height
    }

    /// Zoom while holding one view point still — zoom-to-cursor.
    ///
    /// The clamp is applied BEFORE the anchoring maths. Anchoring against the
    /// requested zoom and then clamping drifts the anchor precisely when the
    /// writer is pinned at a limit and pushing further, which is exactly when
    /// they are watching it.
    mutating func zoom(to newZoom: CGFloat, anchoringViewPoint anchor: CGPoint) {
        let clamped = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let contentUnderAnchor = contentPoint(fromView: anchor)
        zoom = clamped
        pan = CGPoint(x: anchor.x - contentUnderAnchor.x * clamped,
                      y: anchor.y - contentUnderAnchor.y * clamped)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasCameraTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasCamera.swift MaughamTests/Canvas/CanvasCameraTests.swift project.yml
git commit -m "feat(canvas): camera — pan, clamped zoom-to-cursor, inverse-transform hit testing"
```

---

### Task 5: The sidecar store

**Files:**
- Create: `Maugham/Canvas/CanvasSceneCodec.swift`
- Create: `Maugham/Canvas/CanvasStore.swift`
- Test: `MaughamTests/Canvas/CanvasStoreTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNode`, `CanvasNodeID`, `CanvasNodeKind` (Task 1); `ScrapText` (Task 2).
- **Produces:**
  - `struct CanvasSceneDTO: Codable` — `static let currentSchemaVersion: Int`, `init(scene:)`, `var scene: CanvasScene`.
  - `final class CanvasStore` with
    - `init(projectRoot: URL)`
    - `static let sidecarRelativePath = ".maugham/canvas.json"`
    - `static let scrapsRelativePath = "canvas.md"`
    - `func load() -> (scene: CanvasScene, scraps: [CanvasNodeID: String])`
    - `func save(scene: CanvasScene, scraps: [CanvasNodeID: String])`
    - `func scheduleSave(scene: CanvasScene, scraps: [CanvasNodeID: String])`
    - `func flush()` — **no arguments**; writes whatever `scheduleSave` last queued
    - `var beforeFlush: (() -> Void)?` — the owner's last chance to fold live editor text into the payload
    - `var hasPendingWrite: Bool` — test seam

Schema evolution follows ADR 0015: unknown enum cases decode to a sentinel or are dropped; a newer `schemaVersion` degrades to empty rather than throwing.

**Why `flush()` takes no arguments.** The store keeps the last debounced payload so the flush path has something to write without a caller who still remembers it. That is what makes the app-quit hook possible: `CanvasStore` observes `NSApplication.willTerminateNotification` itself and flushes. `.onDisappear` alone does **not** cover quit — the previous shape's doc comment claimed it did.

**Why `queue:` is `nil` and not `.main`.** `addObserver(forName:object:queue:using:)` runs the block **synchronously on the posting thread only when `queue` is nil**. With `.main` the block is *enqueued*, and during `willTerminateNotification` that hop may never run before the process exits — which defeats the entire reason `flush()` became argument-free. It also breaks the test below, which asserts `hasPendingWrite == false` on the same turn as the post.

**Why `beforeFlush` exists.** The words a writer has just typed live in the mounted editor's `NSTextStorage` until something pulls them into the model. `CanvasView` does that on every keystroke, but the flush path must not *depend* on that having happened — so the store gives the owner one synchronous call immediately before it writes. Task 10 binds it to `syncActiveEdit`. A `beforeFlush` that calls `scheduleSave` cannot recurse: `scheduleSave` only posts a work item, and `flush` cancels it on the next line.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AppKit
@testable import Maugham

final class CanvasStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleScene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("s1"), kind: .scrap,
                            origin: CGPoint(x: 12, y: 34), width: 240,
                            cachedHeight: 88, z: 1))
        // An item node is not CREATED by 1C-a, but the codec must carry one:
        // 1C-b and 1C-c depend on this round-trip.
        s.insert(CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                            origin: CGPoint(x: 400, y: 100), width: 180,
                            cachedHeight: 120, z: 2))
        return s
    }

    func test_saveThenLoad_roundTripsSceneAndScraps() {
        let store = CanvasStore(projectRoot: root)
        let scene = sampleScene()
        let scraps = [CanvasNodeID("s1"): "The falls at night."]
        store.save(scene: scene, scraps: scraps)

        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertEqual(loaded.scene, scene)
        XCTAssertEqual(loaded.scraps, scraps)
    }

    func test_load_onAFreshProjectYieldsAnEmptyCanvas() {
        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertTrue(loaded.scene.isEmpty)
        XCTAssertTrue(loaded.scraps.isEmpty)
    }

    func test_sidecarAndScrapsLandAtTheirDocumentedPaths() {
        CanvasStore(projectRoot: root).save(scene: sampleScene(),
                                            scraps: [CanvasNodeID("s1"): "x"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".maugham/canvas.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("canvas.md").path),
            "scrap TEXT is content and belongs at project root, not in the sidecar")
    }

    /// Spec §8: the sidecar is derived UI state, deletable without loss of
    /// content. Deleting it must lose positions but never words.
    func test_deletingTheSidecar_losesLayoutButKeepsTheWords() throws {
        let store = CanvasStore(projectRoot: root)
        store.save(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "The falls at night."])
        try FileManager.default.removeItem(at: root.appendingPathComponent(".maugham/canvas.json"))

        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertTrue(loaded.scene.isEmpty)
        XCTAssertEqual(loaded.scraps[CanvasNodeID("s1")], "The falls at night.")
    }

    /// ADR 0015 — a sidecar from a newer build must not throw the canvas away.
    func test_aNewerSchemaVersionLoadsAsEmptyRatherThanCrashing() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"schemaVersion":999,"nodes":[]}"#
            .write(to: dir.appendingPathComponent("canvas.json"),
                   atomically: true, encoding: .utf8)
        XCTAssertTrue(CanvasStore(projectRoot: root).load().scene.isEmpty)
    }

    func test_corruptSidecarLoadsAsEmptyRatherThanCrashing() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json at all".write(to: dir.appendingPathComponent("canvas.json"),
                                    atomically: true, encoding: .utf8)
        XCTAssertTrue(CanvasStore(projectRoot: root).load().scene.isEmpty)
    }

    func test_unknownNodeKindIsDroppedNotFatal() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"schemaVersion":1,"nodes":[
          {"id":"s1","kind":"scrap","x":0,"y":0,"width":240,"z":0},
          {"id":"weird","kind":"hologram","x":0,"y":0,"width":240,"z":0}
        ]}
        """
        try json.write(to: dir.appendingPathComponent("canvas.json"),
                       atomically: true, encoding: .utf8)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertNotNil(scene.node(CanvasNodeID("s1")))
        XCTAssertNil(scene.node(CanvasNodeID("weird")))
    }

    // MARK: - Debounce and flush

    func test_scheduleSaveDoesNotWriteImmediately() {
        let store = CanvasStore(projectRoot: root)
        store.scheduleSave(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "x"])
        XCTAssertTrue(store.hasPendingWrite)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("canvas.md").path))
    }

    /// The 750ms window is exactly long enough to lose the last drag on quit.
    func test_flushWritesThePendingDebouncedPayload() {
        let store = CanvasStore(projectRoot: root)
        store.scheduleSave(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "The falls."])
        store.flush()
        XCTAssertFalse(store.hasPendingWrite)
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scraps[CanvasNodeID("s1")],
                       "The falls.")
    }

    func test_flushWithNothingPendingWritesNothing() {
        let store = CanvasStore(projectRoot: root)
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("canvas.md").path),
            "an empty flush must not stamp an empty canvas.md over a real one")
    }

    /// `.onDisappear` does not fire on app quit. The store owns the quit hook
    /// itself so no caller has to remember.
    ///
    /// This asserts on the SAME TURN as the post, which only holds because the
    /// observer is registered with `queue: nil` — the block then runs
    /// synchronously on the posting thread. With `queue: .main` it is enqueued
    /// instead, this test fails, and at real quit time the hop may never run.
    func test_appTerminationFlushesThePendingWrite() {
        let store = CanvasStore(projectRoot: root)
        store.scheduleSave(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "quit me"])
        NotificationCenter.default.post(   // adr-0021-ok: AppKit lifecycle notification, not a maugham.* event
            name: NSApplication.willTerminateNotification, object: NSApplication.shared)
        XCTAssertFalse(store.hasPendingWrite)
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scraps[CanvasNodeID("s1")],
                       "quit me")
    }

    /// C5's last line of defence. The words the writer just typed live in the
    /// mounted editor until something pulls them into the model; the store gives
    /// its owner one synchronous call to do that before it writes.
    func test_beforeFlushCanReplaceThePayloadOnItsWayOut() {
        let store = CanvasStore(projectRoot: root)
        store.scheduleSave(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "stale"])
        store.beforeFlush = { [weak store] in
            store?.scheduleSave(scene: self.sampleScene(),
                                scraps: [CanvasNodeID("s1"): "what the writer actually typed"])
        }
        store.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scraps[CanvasNodeID("s1")],
                       "what the writer actually typed")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasStoreTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasStore' in scope`.

- [ ] **Step 3: Write the codec**

`Maugham/Canvas/CanvasSceneCodec.swift`:

```swift
import Foundation

/// The on-disk shape of `.maugham/canvas.json`.
///
/// Derived UI state (spec §8): positions, geometry and seeds. Deletable without
/// loss of content — the words live in `canvas.md`. Kept separate from
/// `CanvasScene` so the in-memory model is free to change shape without
/// rewriting every writer's sidecar.
struct CanvasSceneDTO: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var nodes: [NodeDTO]

    struct NodeDTO: Codable {
        var id: String
        var kind: String            // "scrap" | "item"
        var referenceId: String?    // set when kind == "item"
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var cachedHeight: CGFloat?
        var z: Int
    }

    init(scene: CanvasScene) {
        schemaVersion = Self.currentSchemaVersion
        nodes = scene.nodes.map { n in
            switch n.kind {
            case .scrap:
                return NodeDTO(id: n.id.raw, kind: "scrap", referenceId: nil,
                               x: n.origin.x, y: n.origin.y, width: n.width,
                               cachedHeight: n.cachedHeight, z: n.z)
            case .item(let ref):
                return NodeDTO(id: n.id.raw, kind: "item", referenceId: ref,
                               x: n.origin.x, y: n.origin.y, width: n.width,
                               cachedHeight: n.cachedHeight, z: n.z)
            }
        }
    }

    /// Unknown node kinds are DROPPED, not fatal (ADR 0015's spirit): a canvas
    /// written by a newer build still opens, minus the nodes this build cannot
    /// draw. Losing the whole canvas because one node is from the future is the
    /// worse failure.
    var scene: CanvasScene {
        var s = CanvasScene()
        for dto in nodes {
            let kind: CanvasNodeKind?
            switch dto.kind {
            case "scrap": kind = .scrap
            case "item": kind = dto.referenceId.map { CanvasNodeKind.item(referenceId: $0) }
            default: kind = nil
            }
            guard let kind else { continue }
            s.insert(CanvasNode(id: CanvasNodeID(dto.id), kind: kind,
                                origin: CGPoint(x: dto.x, y: dto.y),
                                width: dto.width, cachedHeight: dto.cachedHeight, z: dto.z))
        }
        return s
    }
}
```

- [ ] **Step 4: Write the store**

`Maugham/Canvas/CanvasStore.swift`:

```swift
import AppKit

/// Disk I/O for the canvas: the derived sidecar and the plain-text scraps.
///
/// Two files with two different statuses, and the split is the point (spec §8):
/// `.maugham/canvas.json` is derived state and may be deleted without losing a
/// word; `canvas.md` is content and is never written anywhere else.
final class CanvasStore {

    static let sidecarRelativePath = ".maugham/canvas.json"
    static let scrapsRelativePath = "canvas.md"

    private let projectRoot: URL
    private var pendingSave: DispatchWorkItem?
    /// The last payload `scheduleSave` queued. Held so `flush()` needs no
    /// arguments and so the app-quit hook has something to write.
    private var pendingPayload: (scene: CanvasScene, scraps: [CanvasNodeID: String])?
    private var terminationObserver: NSObjectProtocol?

    /// The owner's last chance to fold live editor text into the payload before
    /// it is written. `CanvasView` binds this to `syncActiveEdit`, so a quit
    /// mid-sentence writes the sentence. Calling `scheduleSave` from here is
    /// safe and is the intended use — it only queues, and `flush` cancels the
    /// queue on the very next line.
    var beforeFlush: (() -> Void)?

    /// Matches `DocumentStore`'s autosave debounce, so canvas edits and
    /// manuscript edits settle on the same rhythm.
    private let debounceInterval: TimeInterval = 0.75

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
        // `.onDisappear` does NOT fire on app quit, and the 750ms debounce is
        // exactly long enough to lose the writer's last drag. This is an AppKit
        // lifecycle notification, not a `maugham.*` one, so it is outside
        // `MaughamEvent`'s remit (tripwire 21).
        //
        // `queue: nil` is REQUIRED, not a default. With a queue the block is
        // enqueued rather than run on the posting thread, and during termination
        // the hop may never run — which is precisely the write this observer
        // exists to guarantee.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.flush()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        // Deliberately NOT flushing here. Every real path is already covered —
        // the debounce timer, `CanvasView.onDisappear`, and app termination —
        // and a `deinit` write lands wherever the store happens to die, which in
        // tests is a temp directory `tearDown` has already removed.
    }

    var hasPendingWrite: Bool { pendingPayload != nil }

    private var sidecarURL: URL { projectRoot.appendingPathComponent(Self.sidecarRelativePath) }
    private var scrapsURL: URL { projectRoot.appendingPathComponent(Self.scrapsRelativePath) }

    func load() -> (scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        let scraps = (try? String(contentsOf: scrapsURL, encoding: .utf8))
            .map(ScrapText.parse) ?? [:]

        guard let data = try? Data(contentsOf: sidecarURL),
              let dto = try? JSONDecoder().decode(CanvasSceneDTO.self, from: data),
              dto.schemaVersion <= CanvasSceneDTO.currentSchemaVersion else {
            // Corrupt, absent, or from a newer build. An empty layout with the
            // words intact is a recoverable state; a crash is not.
            return (CanvasScene(), scraps)
        }
        return (dto.scene, scraps)
    }

    func save(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        pendingSave?.cancel()
        pendingSave = nil
        pendingPayload = nil
        writeNow(scene: scene, scraps: scraps)
    }

    /// Debounced — a drag emits a position per frame and must not emit a write
    /// per frame.
    func scheduleSave(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        pendingSave?.cancel()
        pendingPayload = (scene, scraps)
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Write whatever `scheduleSave` last queued, now. Called from the debounce
    /// timer, from `CanvasView.onDisappear`, and from app termination. A no-op
    /// when nothing is pending — it must never stamp an empty canvas over a real
    /// one.
    func flush() {
        // The owner's last chance to fold live editor text into the payload.
        beforeFlush?()
        pendingSave?.cancel()
        pendingSave = nil
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        writeNow(scene: payload.scene, scraps: payload.scraps)
    }

    private func writeNow(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        try? FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(CanvasSceneDTO(scene: scene)) {
            try? data.write(to: sidecarURL, options: .atomic)
        }
        try? ScrapText.render(scraps).write(to: scrapsURL, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasStoreTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 12 tests.

Also run the tripwire suite — this task is the one that writes a `NotificationCenter.default.post(` into `MaughamTests/`, and the ADR 0021 post pattern is unconditional:

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/TripwireGrepTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS. If `test_noRawMaughamPostsOrSubscriptionsOutsideWrapper` fails, the `// adr-0021-ok:` annotation is missing or is on the wrong line — it must be on the line where the call *starts*.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasSceneCodec.swift Maugham/Canvas/CanvasStore.swift MaughamTests/Canvas/CanvasStoreTests.swift project.yml
git commit -m "feat(canvas): sidecar + canvas.md persistence, argument-free flush covering app quit"
```

---

### Task 6: Camera and pointer input

**Files:**
- Create: `Maugham/Canvas/CanvasEventView.swift`
- Test: `MaughamTests/Canvas/CanvasEventViewTests.swift`

**Interfaces:**
- **Consumes:** `CanvasCamera` (Task 4).
- **Produces:**
  - `enum CanvasDragPhase: Equatable, Sendable` — `case began`, `case changed`, `case ended`. **This is the only drag vocabulary in the plan.** Tasks 10 and 13 use exactly these names; there is no `DragPhase`, no `onDragBegan`/`onDragChanged`/`onDragEnded` triple.
  - `final class CanvasEventNSView: NSView` — `var camera: CanvasCamera`, `var canvasUndoManager: UndoManager?`, `var onCameraChange: ((CanvasCamera) -> Void)?`, `var onClick: ((CGPoint, Int) -> Void)?` (view point, click count), `var onDrag: ((CGPoint, CanvasDragPhase) -> Void)?` (view point, phase); testable seams `applyScroll(deltaX:deltaY:precise:)`, `applyMagnify(magnification:at:)`, `applyMouseDown(at:clickCount:)`, `applyMouseDragged(to:)`, `applyMouseUp(at:)`.
  - `struct CanvasEventView: NSViewRepresentable` — `@Binding var camera: CanvasCamera`, `var onClick: (CGPoint, Int) -> Void`, `var onDrag: (CGPoint, CanvasDragPhase) -> Void`, `var undoManager: UndoManager?`.

SwiftUI cannot supply any of this: it exposes no scroll-wheel API on macOS, `MagnificationGesture` gives no centre point, and `.simultaneousGesture(DragGesture())` never fires on macOS (spec §7A.1).

The event logic lives in plain methods on the `NSView` so it can be tested without synthesizing `NSEvent`s. **The spike learned this the hard way:** synthesized-event harnesses failed their own controls twice, and `NSTextView.mouseDown` runs a modal tracking loop that deadlocks a post-then-pump harness.

**This view is NOT frontmost.** Task 10 places it *beneath* the mounted scrap editor so the editor receives clicks natively (caret placement, drag-select, double-click-word). `mouseDown` therefore does not call `super` — nothing behind it wants the event, and `NSResponder.mouseDown`'s default is to pass up the chain, which would hand canvas clicks to the window.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AppKit
@testable import Maugham

final class CanvasEventViewTests: XCTestCase {

    private func view() -> CanvasEventNSView {
        let v = CanvasEventNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        v.camera = CanvasCamera()
        return v
    }

    func test_scrollPansTheCamera() {
        let v = view()
        v.applyScroll(deltaX: 20, deltaY: -15, precise: true)
        XCTAssertEqual(v.camera.pan, CGPoint(x: 20, y: -15))
        XCTAssertEqual(v.camera.zoom, 1, "scrolling must not zoom")
    }

    func test_coarseWheelTicksAreAmplifiedRelativeToTrackpad() {
        let precise = view(); precise.applyScroll(deltaX: 0, deltaY: 3, precise: true)
        let wheel = view(); wheel.applyScroll(deltaX: 0, deltaY: 3, precise: false)
        XCTAssertGreaterThan(wheel.camera.pan.y, precise.camera.pan.y)
    }

    func test_magnifyZoomsAndHoldsTheAnchor() {
        let v = view()
        let anchor = CGPoint(x: 300, y: 200)
        let before = v.camera.contentPoint(fromView: anchor)
        v.applyMagnify(magnification: 0.5, at: anchor)   // +50%
        XCTAssertEqual(v.camera.zoom, 1.5, accuracy: 0.0001)
        let after = v.camera.contentPoint(fromView: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
    }

    func test_magnifyIsClamped() {
        let v = view()
        for _ in 0..<50 { v.applyMagnify(magnification: 1.0, at: .zero) }
        XCTAssertEqual(v.camera.zoom, CanvasCamera.zoomRange.upperBound)
        for _ in 0..<200 { v.applyMagnify(magnification: -0.5, at: .zero) }
        XCTAssertEqual(v.camera.zoom, CanvasCamera.zoomRange.lowerBound)
    }

    func test_repeatedMagnifyCompoundsRatherThanResets() {
        let v = view()
        v.applyMagnify(magnification: 0.1, at: .zero)
        let once = v.camera.zoom
        v.applyMagnify(magnification: 0.1, at: .zero)
        XCTAssertGreaterThan(v.camera.zoom, once)
    }

    func test_viewAcceptsFirstMouseSoOneClickReachesTheCanvas() {
        XCTAssertTrue(view().acceptsFirstMouse(for: nil),
                      "an inactive window must not eat the writer's first click")
    }

    // MARK: - The one drag vocabulary

    func test_aFullDragEmitsBeganChangedEndedInOrder() {
        let v = view()
        var phases: [CanvasDragPhase] = []
        var points: [CGPoint] = []
        v.onDrag = { p, phase in points.append(p); phases.append(phase) }

        v.applyMouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        v.applyMouseDragged(to: CGPoint(x: 40, y: 20))
        v.applyMouseDragged(to: CGPoint(x: 70, y: 30))
        v.applyMouseUp(at: CGPoint(x: 70, y: 30))

        XCTAssertEqual(phases, [.began, .changed, .changed, .ended])
        XCTAssertEqual(points.first, CGPoint(x: 10, y: 10))
        XCTAssertEqual(points.last, CGPoint(x: 70, y: 30))
    }

    func test_draggedWithoutAMouseDownEmitsNothing() {
        let v = view()
        var phases: [CanvasDragPhase] = []
        v.onDrag = { _, phase in phases.append(phase) }
        v.applyMouseDragged(to: CGPoint(x: 40, y: 20))
        v.applyMouseUp(at: CGPoint(x: 40, y: 20))
        XCTAssertTrue(phases.isEmpty, "a drag that never began must not end")
    }

    func test_clickReportsItsClickCountSoDoubleClickIsDistinguishable() {
        let v = view()
        var counts: [Int] = []
        v.onClick = { _, count in counts.append(count) }
        v.applyMouseDown(at: .zero, clickCount: 1)
        v.applyMouseUp(at: .zero)
        v.applyMouseDown(at: .zero, clickCount: 2)
        v.applyMouseUp(at: .zero)
        XCTAssertEqual(counts, [1, 2])
    }

    /// ⌘Z on the canvas reaches `CanvasUndo` through the responder chain:
    /// `NSWindow.undo(_:)` asks the first responder for its `undoManager`.
    func test_theViewVendsTheCanvasUndoManagerToTheResponderChain() {
        let v = view()
        let manager = UndoManager()
        v.canvasUndoManager = manager
        XCTAssertTrue(v.acceptsFirstResponder)
        XCTAssertTrue(v.undoManager === manager)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasEventViewTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasEventNSView' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import AppKit
import SwiftUI

/// The three phases of a canvas drag. ONE vocabulary, used by the event view,
/// `CanvasView` and `CanvasInteraction`.
enum CanvasDragPhase: Equatable, Sendable {
    case began
    case changed
    case ended
}

/// Where the canvas gets its camera and pointer input.
///
/// SwiftUI cannot supply any of this on macOS: there is no scroll-wheel API,
/// `MagnificationGesture` provides no centre point (so zoom-to-cursor is
/// impossible), and `.simultaneousGesture(DragGesture())` never fires at all
/// (spec §7A.1). So a transparent `NSView` sits in the canvas stack and
/// overrides the AppKit entry points.
///
/// It sits BENEATH the mounted scrap editor (see `CanvasView`), so while a scrap
/// is being edited the editor gets the mouse and the writer gets AppKit's own
/// caret placement, drag-select and double-click-word for free. That is why
/// `mouseDown` does not call `super`: nothing behind this view wants the event,
/// and `NSResponder`'s default would hand canvas clicks to the window.
///
/// The event LOGIC is in plain methods, not inside the `NSEvent` overrides,
/// because synthesizing AppKit events in tests is unreliable — the 2026-07-25
/// spike had two synthetic-event harnesses fail their own control cases, and
/// discovered that `NSTextView.mouseDown` runs a modal tracking loop that
/// deadlocks a post-then-pump harness.
final class CanvasEventNSView: NSView {

    var camera = CanvasCamera()
    var canvasUndoManager: UndoManager?
    var onCameraChange: ((CanvasCamera) -> Void)?
    /// (view point, click count). Click count 2 is "enter the scrap under this
    /// point, or make a new one here".
    var onClick: ((CGPoint, Int) -> Void)?
    var onDrag: ((CGPoint, CanvasDragPhase) -> Void)?

    private var isDragging = false

    override var isFlipped: Bool { true }

    /// Without this, the first click into an unfocused window is spent
    /// activating it — on a canvas that is a lost thought.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ⌘Z with nothing being edited must reach the canvas's own undo stack.
    /// `NSWindow.undo(_:)` asks the first responder for its `undoManager`, so
    /// this view has to be able to hold first responder and vend it.
    override var acceptsFirstResponder: Bool { true }

    override var undoManager: UndoManager? { canvasUndoManager ?? super.undoManager }

    // MARK: - Testable seams

    func applyScroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) {
        // A non-precise (mouse wheel) tick is coarse; scale it so a wheel and a
        // trackpad move the canvas by comparable amounts.
        let factor: CGFloat = precise ? 1 : 8
        camera.panBy(CGSize(width: deltaX * factor, height: deltaY * factor))
        onCameraChange?(camera)
    }

    /// `NSEvent.magnification` is a DELTA fraction, so the new zoom compounds
    /// off the current one.
    func applyMagnify(magnification: CGFloat, at anchor: CGPoint) {
        camera.zoom(to: camera.zoom * (1 + magnification), anchoringViewPoint: anchor)
        onCameraChange?(camera)
    }

    func applyMouseDown(at point: CGPoint, clickCount: Int) {
        isDragging = true
        onClick?(point, clickCount)
        onDrag?(point, .began)
    }

    func applyMouseDragged(to point: CGPoint) {
        guard isDragging else { return }
        onDrag?(point, .changed)
    }

    func applyMouseUp(at point: CGPoint) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(point, .ended)
    }

    // MARK: - AppKit entry points

    override func scrollWheel(with event: NSEvent) {
        applyScroll(deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas)
    }

    override func magnify(with event: NSEvent) {
        applyMagnify(magnification: event.magnification,
                     at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        // Take first responder so ⌘Z lands on the canvas undo stack once the
        // writer has clicked out of a scrap.
        window?.makeFirstResponder(self)
        applyMouseDown(at: convert(event.locationInWindow, from: nil),
                       clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        applyMouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        applyMouseUp(at: convert(event.locationInWindow, from: nil))
    }
}

/// Bridges `CanvasEventNSView` into SwiftUI. Transparent — it contributes no
/// drawing, only events.
struct CanvasEventView: NSViewRepresentable {
    @Binding var camera: CanvasCamera
    var onClick: (CGPoint, Int) -> Void
    var onDrag: (CGPoint, CanvasDragPhase) -> Void
    var undoManager: UndoManager?

    func makeNSView(context: Context) -> CanvasEventNSView {
        let v = CanvasEventNSView(frame: .zero)
        v.camera = camera
        wire(v)
        return v
    }

    func updateNSView(_ v: CanvasEventNSView, context: Context) {
        // Only push a camera the view did not itself originate, or a drag
        // fights its own updates.
        if v.camera != camera { v.camera = camera }
        wire(v)
    }

    private func wire(_ v: CanvasEventNSView) {
        v.onCameraChange = { camera = $0 }
        v.onClick = onClick
        v.onDrag = onDrag
        v.canvasUndoManager = undoManager
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasEventViewTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasEventView.swift MaughamTests/Canvas/CanvasEventViewTests.swift project.yml
git commit -m "feat(canvas): scroll/magnify/click/drag input via NSViewRepresentable

One drag vocabulary (CanvasDragPhase). The view sits BENEATH the mounted
editor so AppKit gives the writer caret placement and word selection."
```

---

### Task 7: The renderer

**Files:**
- Create: `Maugham/Canvas/CanvasRenderer.swift`
- Test: `MaughamTests/Canvas/CanvasRendererTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNode`, `CanvasNodeID`, `CanvasNodeKind`, `CanvasCardMetrics` (Task 1); `ScrapLayout` (Task 3); `CanvasCamera` (Task 4).
- **Produces:**
  - `struct CanvasFocusStraighten: Equatable` — `static let secondsToLevel: TimeInterval`, `private(set) var focusedNodeID: CanvasNodeID?`, `var isSettled: Bool`, `func progress(for id: CanvasNodeID) -> CGFloat`, `func isLevel(_ id: CanvasNodeID) -> Bool`, `mutating func focus(_ id: CanvasNodeID?)`, `@discardableResult mutating func step(elapsed: TimeInterval) -> Bool`.
  - `enum CanvasRenderer` with
    - `static func seededRotation(for id: CanvasNodeID) -> Angle`
    - `static func drawnAngle(for id: CanvasNodeID, straighten: CanvasFocusStraighten) -> Angle`
    - `static func cardTransform(inCard frame: CGRect, angle: Angle) -> CGAffineTransform`
    - `static func localPoint(_ contentPoint: CGPoint, inCard frame: CGRect, angle: Angle) -> CGPoint`
    - `static func visibleNodes(in scene: CanvasScene, camera: CanvasCamera, viewSize: CGSize) -> [CanvasNode]`
    - `static func placeholderLabel(forReference referenceId: String) -> String`
    - `static let resizeHandleSize: CGFloat`
    - `static func drawsOwnText(_ id: CanvasNodeID, visibleEditorNodeID: CanvasNodeID?) -> Bool`
    - `static func draw(scene: CanvasScene, camera: CanvasCamera, viewSize: CGSize, layouts: [CanvasNodeID: ScrapLayout], visibleEditorNodeID: CanvasNodeID?, straighten: CanvasFocusStraighten, into cx: inout GraphicsContext)` — **`visibleEditorNodeID:` suppresses that node's TEXT only.** Its **card is still drawn** — §7A.5 makes the focused card the only square one on the canvas, and there is nothing to be square if the card vanishes.

    **The parameter is named for the editor being VISIBLE, not for the editor existing and not for the node being edited.** Task 10 keeps three states apart and only the third belongs here:

    | | the writer is editing it | its editor exists, is first responder, takes keystrokes | its editor is the visible text |
    |---|---|---|---|
    | `CanvasView.editingNodeID` | yes | — | — |
    | `CanvasView.mountedEditorNodeID` | — | yes, from the click | — |
    | `CanvasView.visibleEditorNodeID` | — | — | yes, from `isLevel` |

    The mount happens on the click, because an editor that arrives ~120 ms late is ~120 ms in which the writer's first characters reach no editor at all. Its *visibility* is what waits for the straighten. So for that window the editor exists but is not drawn, and this parameter is `nil` — the renderer keeps drawing the card's text, which is the live shared `NSTextStorage` and therefore updates as the writer types. Passing `mountedEditorNodeID` here instead would blank the drawn text from frame one while the invisible editor drew nothing in its place: the glyphs would vanish, then reappear straight, which is the §7A.2 jump arriving by the very route §7A.5 exists to close. An earlier draft of this plan spelled the parameter `editingNodeID:` and did exactly that. Task 10 derives this parameter and the editor's own visibility from **one** property, so the two cannot flip on different frames.

**Two decisions this task makes, both load-bearing.**

1. **The seeded rotation applies to the WHOLE card, and the focused card animates to level.** This is spec §7A.5, and it is a decision, not a compromise — record it as such in the ADR (Task 17).

   §7.2 asks for a seeded fraction of a degree so everything reads as *put down* rather than snapped to a grid. §7A.5 resolves what happens when the writer clicks into one: **the entire card — chrome and text together — animates to level over ~120 ms, and settles back to its seeded angle on blur.** The card being edited is therefore the only square one on the canvas, which is a "this one is live" signal that costs nothing because everything else stays tilted.

   Three things follow, and each of them makes the rest of the plan *simpler*:

   - **The editor is never the visible text until the card is level** — because Task 10 gates the editor's *visibility* on this animation finishing (`isLevel(_:)`), and gates the renderer's text suppression on the same predicate. The editor itself mounts on the click, so no keystroke is lost; it is simply not drawn yet. `.rotationEffect` never arises, so §7A.2's glyph-origin pin compares two unrotated layouts. §7A.5 requirement 1 orders it: resolve the caret, **then** animate, **then** hand the text over.
   - **The caret index is resolved at click time, in the card's local unrotated space** (§7A.5 requirement 1) — `localPoint(_:inCard:angle:)` is that inverse transform, and it is pure. Straightening first would move the click point out from under the cursor, and the caret would land somewhere the writer did not aim.
   - **Animate, never snap** (§7A.5 requirement 2). An instant jump reads as a rendering bug. The straighten fraction is a value the renderer interpolates — the same per-frame shape as Task 13's momentum decay, driven off the same `TimelineView` clock, so there is no new machinery.

   **Do not repeat the old justification.** An earlier draft claimed a mounted `NSTextView` "cannot be rotated". That is false: `NSView.frameRotation` rotates a real view and renders it crisply. The reason the editor mounts level is §7A.5's design — the straightening *is* the focus affordance — not an AppKit limitation. Writing the false version down again would invite someone to "fix" it.

   **One transform, used forwards and backwards.** `cardTransform(inCard:angle:)` is the only definition of a card's rotation. `drawCard` concatenates it onto the context; `localPoint` inverts it. An earlier draft had the renderer call `GraphicsContext.rotate(by:)` and `localPoint` build its own `R(−θ)` by hand, and nothing checked that the two agreed about which way positive is — a flip would have doubled the caret error rather than removing it, silently, because a round-trip test passes under either convention. With one definition there is nothing to flip, and the test pins that definition against literal trigonometry rather than against itself.

   Hit testing (`CanvasScene.topmostNode(at:)`) stays on the **unrotated** rect. At 0.6° the worst-case discrepancy is `r·θ` where `r` is the centre-to-corner distance: **≈1.4 pt at the corner of a default 240×80 card** (`r` = 126.5 pt), growing with the card's diagonal. That band sits **exactly where `resizeHandle` draws and `CanvasInteraction.begin` tests** — this is not somewhere a writer never aims, and the earlier draft claiming otherwise had it backwards. It is accepted because 1.4 pt is inside pointer slop and the 14 pt resize target absorbs it whole, while a rotated hit test would have to be kept in sync with a running animation for no gain.

2. **The renderer derives no scale of its own.** Spike requirement 3 says draw at the window's true `backingScaleFactor` × camera zoom, and warns that computing that scale by hand "is exactly the 'text jumps' failure dressed up as a measurement artifact". `GraphicsContext.withCGContext` already hands over a context at backing scale, under the CTM we set from the camera — so the correct implementation is to touch neither. A test greps `Maugham/Canvas/` for the tempting spellings.

**Item nodes draw as placeholders in this slice** — a dashed card carrying `Item · <referenceId>`. 1C-d resolves the real title, kind glyph and thumbnail (spec §8A.1). Do not resolve anything from the project store here.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
@testable import Maugham

final class CanvasRendererTests: XCTestCase {

    func test_seededRotation_isStableForTheSameID() {
        let a = CanvasRenderer.seededRotation(for: CanvasNodeID("s1"))
        let b = CanvasRenderer.seededRotation(for: CanvasNodeID("s1"))
        XCTAssertEqual(a.degrees, b.degrees, accuracy: 1e-12,
                       "a card that shimmers between renders is the failure §7.2 forbids")
    }

    func test_seededRotation_differsAcrossIDs() {
        let angles = (0..<40).map { CanvasRenderer.seededRotation(for: CanvasNodeID("s\($0)")).degrees }
        XCTAssertGreaterThan(Set(angles.map { Int($0 * 1_000_000) }).count, 30,
                             "rotation must actually vary, or nothing was put down by hand")
    }

    func test_seededRotation_staysUnderOneDegree() {
        for i in 0..<400 {
            let d = CanvasRenderer.seededRotation(for: CanvasNodeID("node-\(i)")).degrees
            XCTAssertLessThan(abs(d), 1.0, "§7.2 says a seeded FRACTION of a degree")
        }
    }

    // MARK: - §7A.5, focus straightens the card

    func test_anUnfocusedCardIsDrawnAtItsFullSeededAngle() {
        let straighten = CanvasFocusStraighten()
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: CanvasNodeID("s1"), straighten: straighten).degrees,
                       CanvasRenderer.seededRotation(for: CanvasNodeID("s1")).degrees,
                       accuracy: 1e-12)
    }

    func test_theFocusedCardEndsUpExactlyLevel() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: CanvasNodeID("s1"), straighten: straighten).degrees,
                       0, accuracy: 1e-12,
                       "the editor mounts on this card — anything but level and the "
                       + "glyph-origin pin is comparing a rotated layout to a flat one")
    }

    /// §7A.5 requirement 2: an instant jump reads as a rendering bug.
    func test_straighteningIsAnimatedRatherThanSnapped() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        XCTAssertTrue(straighten.step(elapsed: 1.0 / 60), "still animating after one frame")
        let p = straighten.progress(for: CanvasNodeID("s1"))
        XCTAssertGreaterThan(p, 0)
        XCTAssertLessThan(p, 1, "one frame must not complete the straighten")
    }

    func test_straighteningTakesAboutTheSpecifiedTime() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        var elapsed: TimeInterval = 0
        while straighten.step(elapsed: 1.0 / 60) { elapsed += 1.0 / 60 }
        XCTAssertEqual(elapsed, CanvasFocusStraighten.secondsToLevel, accuracy: 1.0 / 30,
                       "~120ms reads as the card responding; much longer reads as lag")
    }

    /// `isSettled` gates the `TimelineView`'s clock, so it must mean "every card
    /// is at ITS target", not "every progress value is 1". A completed focus
    /// leaves the entry at 1; blur clears `focusedNodeID` and that entry's target
    /// becomes 0 — but an `allSatisfy { $0.value >= 1 }` reads it as settled, the
    /// clock pauses on the spot, `step` is never called again, and the card stays
    /// level forever. Click in, click out onto empty canvas — the commonest path
    /// there is — and "the card being edited is the only square one on the canvas"
    /// is simply false.
    func test_blurSettlesTheCardBackToItsSeededAngle() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(straighten.isSettled, "a completed focus must pause the clock")

        straighten.focus(nil)
        XCTAssertFalse(straighten.isSettled, "blur must animate back, not snap back")
        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: CanvasNodeID("s1"), straighten: straighten).degrees,
                       CanvasRenderer.seededRotation(for: CanvasNodeID("s1")).degrees,
                       accuracy: 1e-12)
        XCTAssertTrue(straighten.isSettled, "a settled canvas must pause its clock")
    }

    /// The gate Task 10 REVEALS the editor behind. The editor is mounted and
    /// taking keystrokes well before this; `isLevel` is when it becomes the
    /// VISIBLE text and the renderer stops drawing that card's own. §7A.5
    /// requirement 1 orders it: caret, then animate, then hand the text over.
    /// Showing the editor at progress 0 puts axis-aligned glyphs on a card that
    /// is still up to 0.6° off level, at the unrotated text origin, with the
    /// drawn text already suppressed — the glyphs jump straight the instant the
    /// writer clicks and the card catches up afterwards, which is precisely the
    /// §7A.2 failure.
    func test_aCardIsNotLevelUntilTheStraightenCompletes() {
        var straighten = CanvasFocusStraighten()
        let id = CanvasNodeID("s1")
        XCTAssertFalse(straighten.isLevel(id), "an untouched card is at its seeded angle")

        straighten.focus(id)
        XCTAssertFalse(straighten.isLevel(id), "the animation has not started yet")
        straighten.step(elapsed: 1.0 / 60)
        XCTAssertFalse(straighten.isLevel(id), "one frame in, the card is still tilted")

        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(straighten.isLevel(id))
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: id, straighten: straighten).degrees,
                       0, accuracy: 1e-12,
                       "isLevel must not be able to be true while the card is tilted")
    }

    func test_blurStopsTheCardBeingLevelImmediately() {
        var straighten = CanvasFocusStraighten()
        let id = CanvasNodeID("s1")
        straighten.focus(id)
        while straighten.step(elapsed: 1.0 / 60) { }
        straighten.focus(nil)
        XCTAssertFalse(straighten.isLevel(id),
                       "focus has left, so the editor must not still be the "
                       + "visible text on a card that is on its way back to its angle")
    }

    func test_onlyTheFocusedCardIsEverLevel() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        while straighten.step(elapsed: 1.0 / 60) { }
        straighten.focus(CanvasNodeID("s2"))
        XCTAssertFalse(straighten.isLevel(CanvasNodeID("s1")),
                       "s1 is settling back and must not report level")
        XCTAssertFalse(straighten.isLevel(CanvasNodeID("s2")), "s2 has only just started")
        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(straighten.isLevel(CanvasNodeID("s2")))
        XCTAssertFalse(straighten.isLevel(CanvasNodeID("s1")))
    }

    // MARK: - The handover from drawn text to editor

    /// The half of the swap the renderer owns. While the card is straightening
    /// its editor is mounted but invisible, so the words on screen are the ones
    /// this pass draws — and they are drawn from the shared `NSTextStorage` the
    /// editor is mutating, so they update as the writer types. The renderer
    /// stops only when the editor becomes visible, at `isLevel`.
    ///
    /// Both halves flip on the same value — `CanvasView.visibleEditorNodeID` —
    /// so there is never a frame with both drawing and never a frame with
    /// neither. A card blank for a tenth of a second and then full of straight
    /// glyphs is the §7A.2 jump.
    func test_theCardKeepsDrawingItsOwnTextUntilTheEditorIsVisible() {
        var straighten = CanvasFocusStraighten()
        let id = CanvasNodeID("s1")
        straighten.focus(id)
        straighten.step(elapsed: 1.0 / 60)

        // Mid-straighten: nothing is visible-editing, so the card draws its own.
        XCTAssertFalse(straighten.isLevel(id))
        XCTAssertTrue(CanvasRenderer.drawsOwnText(id, visibleEditorNodeID: nil),
                      "the card stopped drawing its text while the editor was "
                      + "still invisible — the words vanish for ~120ms")

        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(straighten.isLevel(id))
        XCTAssertFalse(CanvasRenderer.drawsOwnText(id, visibleEditorNodeID: id),
                       "the editor is the visible text now; drawing it again "
                       + "double-draws every glyph (spec §7A.2, the Excalidraw rule)")
    }

    /// Click from scrap A straight to scrap B while A is still settling back and
    /// both `isLevel` values are false — so NEITHER is suppressed. At most one
    /// node is ever suppressed, because the suppression is keyed on a single
    /// optional rather than on a per-node predicate.
    func test_atMostOneNodeEverStopsDrawingItsOwnText() {
        let a = CanvasNodeID("s1")
        let b = CanvasNodeID("s2")
        var straighten = CanvasFocusStraighten()
        straighten.focus(a)
        while straighten.step(elapsed: 1.0 / 60) { }
        straighten.focus(b)
        straighten.step(elapsed: 1.0 / 60)

        XCTAssertFalse(straighten.isLevel(a))
        XCTAssertFalse(straighten.isLevel(b))
        XCTAssertTrue(CanvasRenderer.drawsOwnText(a, visibleEditorNodeID: nil),
                      "A is settling back with no editor on it — it must draw "
                      + "its own text again the frame focus leaves")
        XCTAssertTrue(CanvasRenderer.drawsOwnText(b, visibleEditorNodeID: nil))

        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(CanvasRenderer.drawsOwnText(a, visibleEditorNodeID: b))
        XCTAssertFalse(CanvasRenderer.drawsOwnText(b, visibleEditorNodeID: b))
    }

    /// The sign of the card rotation, pinned against literal trigonometry.
    ///
    /// A round-trip test cannot catch a flipped convention: if `cardTransform`
    /// and `localPoint` both flipped, the round trip would still close, and the
    /// caret error at a card corner would silently double instead of vanishing.
    /// This asserts the transform's actual matrix, at an exaggerated angle where
    /// a flip is unmissable.
    func test_cardTransformRotatesInTheDirectionTheRendererDraws() {
        let frame = CGRect(x: 100, y: 100, width: 240, height: 80)
        let angle = Angle.degrees(30)
        let t = CanvasRenderer.cardTransform(inCard: frame, angle: angle)
        XCTAssertEqual(t.a, cos(angle.radians), accuracy: 1e-9)
        XCTAssertEqual(t.b, sin(angle.radians), accuracy: 1e-9)
        XCTAssertEqual(t.c, -sin(angle.radians), accuracy: 1e-9)
        XCTAssertEqual(t.d, cos(angle.radians), accuracy: 1e-9)

        XCTAssertEqual(CGPoint(x: frame.midX, y: frame.midY).applying(t).x,
                       frame.midX, accuracy: 1e-9, "the centre is the fixed point")
        XCTAssertEqual(CGPoint(x: frame.midX, y: frame.midY).applying(t).y,
                       frame.midY, accuracy: 1e-9)
        XCTAssertGreaterThan(CGPoint(x: frame.midX + 10, y: frame.midY).applying(t).y,
                             frame.midY,
                             "in the canvas's flipped, y-down space a positive "
                             + "angle carries the right-hand edge downward")
    }

    /// There must be exactly ONE definition of a card's rotation. A second one —
    /// `GraphicsContext.rotate(by:)` in the draw pass, say — is a convention the
    /// caret inverse has no way to check itself against.
    func test_noFileInTheCanvasAreaRotatesOutsideCardTransform() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Maugham/Canvas", isDirectory: true)

        var offenders: [String] = []
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        for case let url as URL in walker! where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }     // doc comments may NAME it
                if line.contains(".rotate(by:") || line.contains("rotationEffect(") {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a card's rotation has one definition — CanvasRenderer."
                      + "cardTransform — which localPoint inverts. A second "
                      + "rotation is a sign convention nothing checks: \(offenders)")
    }

    /// §7A.5 requirement 1: resolve the caret in the card's own unrotated space,
    /// at click time. Straightening first moves the click point out from under
    /// the cursor.
    func test_localPointInvertsTheCardsRotation() {
        let frame = CGRect(x: 100, y: 100, width: 240, height: 80)
        let angle = Angle.degrees(0.6)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(CanvasRenderer.localPoint(centre, inCard: frame, angle: angle).x,
                       centre.x, accuracy: 1e-9, "the centre is the fixed point")
        XCTAssertEqual(CanvasRenderer.localPoint(centre, inCard: frame, angle: angle).y,
                       centre.y, accuracy: 1e-9)

        // A corner of the drawn (rotated) card maps back onto the corner of the
        // unrotated one.
        let corner = CGPoint(x: frame.maxX, y: frame.maxY)
        let rotated = CGPoint(
            x: centre.x + (corner.x - centre.x) * cos(angle.radians) - (corner.y - centre.y) * sin(angle.radians),
            y: centre.y + (corner.x - centre.x) * sin(angle.radians) + (corner.y - centre.y) * cos(angle.radians))
        let back = CanvasRenderer.localPoint(rotated, inCard: frame, angle: angle)
        XCTAssertEqual(back.x, corner.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, corner.y, accuracy: 1e-6)

        // And it is the inverse of the transform the renderer actually applies,
        // not of a second hand-written one.
        let drawn = corner.applying(CanvasRenderer.cardTransform(inCard: frame, angle: angle))
        XCTAssertEqual(drawn.x, rotated.x, accuracy: 1e-9)
        XCTAssertEqual(drawn.y, rotated.y, accuracy: 1e-9)
    }

    func test_visibleNodes_cullsOffscreenNodes() {
        var scene = CanvasScene()
        for i in 0..<50 {
            var n = CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 1000, y: 0), width: 240)
            n.cachedHeight = 100
            scene.insert(n)
        }
        let visible = CanvasRenderer.visibleNodes(in: scene, camera: CanvasCamera(),
                                                  viewSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.id, CanvasNodeID("n0"))
    }

    func test_visibleNodes_growsAsYouZoomOut() {
        var scene = CanvasScene()
        for i in 0..<50 {
            var n = CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 300, y: 0), width: 240)
            n.cachedHeight = 100
            scene.insert(n)
        }
        var wide = CanvasCamera(); wide.zoom = 0.15
        XCTAssertGreaterThan(
            CanvasRenderer.visibleNodes(in: scene, camera: wide,
                                        viewSize: CGSize(width: 800, height: 600)).count,
            CanvasRenderer.visibleNodes(in: scene, camera: CanvasCamera(),
                                        viewSize: CGSize(width: 800, height: 600)).count)
    }

    func test_visibleNodes_returnsDrawOrderBackToFront() {
        var scene = CanvasScene()
        for (i, z) in [5, 1, 3].enumerated() {
            var n = CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                               origin: .zero, width: 240, z: z)
            n.cachedHeight = 100
            scene.insert(n)
        }
        let zs = CanvasRenderer.visibleNodes(in: scene, camera: CanvasCamera(),
                                             viewSize: CGSize(width: 800, height: 600)).map(\.z)
        XCTAssertEqual(zs, zs.sorted())
    }

    /// 1C-a draws item nodes as placeholders; 1C-d gives them titles and
    /// thumbnails (spec §8A.1). The label must name the reference so a writer
    /// looking at a canvas from a newer build can tell what is on it.
    func test_itemPlaceholderLabelNamesItsReference() {
        XCTAssertTrue(CanvasRenderer.placeholderLabel(forReference: "r-9").contains("r-9"))
    }

    /// Spike requirement 3: draw at the window's true backingScaleFactor ×
    /// camera zoom, and NEVER derive that scale. `GraphicsContext.withCGContext`
    /// already supplies exactly that product, so the correct implementation
    /// computes nothing — and this test says so out loud, because "helpfully"
    /// adding a scale is the shape of the bug.
    func test_noFileInTheCanvasAreaDerivesItsOwnRasterScale() throws {
        let forbidden = ["backingScaleFactor", "convertToBacking", "convertFromBacking",
                         "NSScreen.main?.backingScaleFactor", "pixelsWide", "pixelsHigh"]
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Maugham/Canvas", isDirectory: true)

        var offenders: [String] = []
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        for case let url as URL in walker! where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Doc comments may NAME the hazard; only code may not use it.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for pat in forbidden where line.contains(pat) {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "the canvas must never derive a raster scale — withCGContext "
                      + "already supplies backingScaleFactor x camera zoom, and a "
                      + "hand-derived scale bakes in AppKit frame rounding and shifts "
                      + "glyphs by a subpixel (spike requirement 3): \(offenders)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRendererTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasRenderer' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import SwiftUI

/// How level each card is drawn, per spec §7A.5.
///
/// **The card that takes focus animates to level over ~120 ms, and settles back
/// to its seeded angle on blur. That is the focus affordance** — the card being
/// edited is the only square one on the canvas, and everything else stays
/// tilted, so the signal costs nothing.
///
/// It is a plain interpolated value stepped once per frame, NOT `withAnimation`:
/// a model value read inside a `Canvas` draw closure is not in SwiftUI's
/// animation graph and would jump straight to its final value. `CanvasView`
/// drives `step(elapsed:)` from the same `TimelineView` that drives
/// `CanvasMomentum` — the same per-frame shape, so no new machinery.
///
/// Two cards can be in flight at once: the one being left settles back while the
/// one being entered straightens. Hence a dictionary rather than a single value.
/// Entries at zero are dropped, so `isSettled` is cheap and an idle canvas pauses
/// its clock.
struct CanvasFocusStraighten: Equatable {

    /// §7A.5: "over ~120 ms". Long enough to read as the card responding, short
    /// enough that the beat before the caret appears reads as responsiveness
    /// rather than lag.
    static let secondsToLevel: TimeInterval = 0.12

    private(set) var focusedNodeID: CanvasNodeID?
    private var progressByNode: [CanvasNodeID: CGFloat] = [:]

    /// True when every entry is at ITS OWN target — the clock may be paused.
    ///
    /// **"At its target", not "at 1".** Only the focused card's target is 1;
    /// every other card's is 0, and `step` deletes an entry the moment it gets
    /// there, so an empty dictionary satisfies this rule for free. Writing it as
    /// `allSatisfy { $0.value >= 1 }` looks equivalent and is not: after a
    /// completed focus the dictionary holds `[s1: 1]`, and `focus(nil)` clears
    /// `focusedNodeID` without touching that entry — so the naive version reports
    /// settled the instant the writer clicks away, `TimelineView` pauses, `step`
    /// is never called again, and **the card stays level until something
    /// unrelated restarts the clock.** Click in, click out onto empty canvas is
    /// the commonest path on the surface, and §7A.5's "the card being edited is
    /// the only square one on the canvas" is false for the rest of the session.
    var isSettled: Bool {
        progressByNode.allSatisfy { $0.key == focusedNodeID && $0.value >= 1 }
    }

    /// 0 = the card's full seeded angle, 1 = level.
    func progress(for id: CanvasNodeID) -> CGFloat { progressByNode[id] ?? 0 }

    /// True only when this card is the focused one AND has finished
    /// straightening — i.e. it is drawn at exactly 0°.
    ///
    /// **This is the gate `CanvasView` REVEALS the editor behind** (§7A.5
    /// requirement 1: caret, then animate, then hand the text over). It gates
    /// visibility, NOT existence: the editor is mounted and first responder from
    /// the instant the writer clicks, or the first characters of a
    /// double-click-and-type would reach nothing. Both halves matter: the
    /// `focusedNodeID` check is what hides the editor again on blur, and the
    /// progress check is what keeps it hidden during the ~120 ms straighten,
    /// when axis-aligned glyphs over a still-tilted card would snap straight —
    /// the §7A.2 failure §7A.5 exists to close.
    func isLevel(_ id: CanvasNodeID) -> Bool {
        focusedNodeID == id && progress(for: id) >= 1
    }

    mutating func focus(_ id: CanvasNodeID?) {
        guard id != focusedNodeID else { return }
        focusedNodeID = id
        if let id, progressByNode[id] == nil { progressByNode[id] = 0 }
    }

    /// Advance one frame. Returns `true` while anything is still moving.
    @discardableResult
    mutating func step(elapsed: TimeInterval) -> Bool {
        let delta = CGFloat(elapsed / Self.secondsToLevel)
        var moving = false
        for (id, current) in progressByNode {
            let target: CGFloat = (id == focusedNodeID) ? 1 : 0
            if abs(target - current) <= delta {
                if target == 0 {
                    progressByNode.removeValue(forKey: id)
                } else {
                    progressByNode[id] = target
                }
            } else {
                progressByNode[id] = current + (target > current ? delta : -delta)
                moving = true
            }
        }
        return moving
    }
}

/// The draw pass. Everything on the canvas is drawn — there are ~2 views on
/// screen rather than 300 (spec §7A.1), which is what keeps the surface out of
/// the macOS 15 `_hitTestForEvent` regression and away from SwiftUI's missing
/// lazy 2D container.
///
/// SCALE: this file derives none. The `GraphicsContext` handed to `draw` is
/// already at the window's `backingScaleFactor`, and `withCGContext` preserves
/// it under the camera CTM we set — so the product spike requirement 3 asks for
/// is what we already have. Computing a scale from pixel width instead bakes in
/// AppKit's frame rounding and shifts glyphs by a subpixel, which is the "text
/// jumps" failure wearing a measurement-artifact disguise.
/// `CanvasRendererTests.test_noFileInTheCanvasAreaDerivesItsOwnRasterScale` pins it.
enum CanvasRenderer {

    /// The size of the resize affordance in the card's bottom-right corner —
    /// the side of the square `CanvasInteraction.begin` tests, and the legs of
    /// the triangle `resizeHandle` draws. See `resizeHandle` for why the two
    /// shapes differ deliberately.
    static let resizeHandleSize: CGFloat = 14

    /// §7.2: each card sits at a seeded fraction of a degree — nothing is rough,
    /// but everything was *put down* rather than snapped to a grid.
    ///
    /// Deterministic from the node id. A card must never shimmer or shift
    /// between renders, so this cannot be `Double.random` and cannot depend on
    /// anything that varies per frame. SplitMix64 over a stable string hash —
    /// note `String.hashValue` is seeded per process and would give a card a
    /// different tilt on every launch.
    static func seededRotation(for id: CanvasNodeID) -> Angle {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a offset basis
        for byte in id.raw.utf8 {
            h = (h ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        // SplitMix64 finaliser — cheap, and well distributed in the low bits.
        var z = h &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z = z ^ (z >> 31)

        // Map to ±0.6°, comfortably a fraction of a degree.
        let unit = Double(z % 10_000) / 10_000.0        // 0..<1
        return .degrees((unit * 2 - 1) * 0.6)
    }

    /// The angle a card is ACTUALLY drawn at right now: its seeded angle, scaled
    /// down toward zero as it straightens (spec §7A.5). At full straighten it is
    /// exactly level, which is what lets the editor take over the text
    /// axis-aligned and the §7A.2 glyph-origin pin compare two unrotated layouts.
    static func drawnAngle(for id: CanvasNodeID, straighten: CanvasFocusStraighten) -> Angle {
        .degrees(seededRotation(for: id).degrees * (1 - Double(straighten.progress(for: id))))
    }

    /// The rotation a card is drawn under, about its own centre. **The only
    /// definition of it.**
    ///
    /// `drawCard` concatenates this onto the graphics context and `localPoint`
    /// inverts it, so the draw pass and the caret hit test cannot disagree about
    /// which way positive is. An earlier draft called `GraphicsContext.rotate(by:)`
    /// in one place and hand-wrote `R(−θ)` in the other, and nothing checked that
    /// they matched — a flipped convention would have DOUBLED the caret error at
    /// a card corner rather than removing it, and a round-trip test passes under
    /// either convention so nothing would have said so.
    /// `CanvasRendererTests.test_cardTransformRotatesInTheDirectionTheRendererDraws`
    /// pins the matrix against literal trigonometry.
    static func cardTransform(inCard frame: CGRect, angle: Angle) -> CGAffineTransform {
        CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: angle.radians)
            .translatedBy(x: -frame.midX, y: -frame.midY)
    }

    /// Map a canvas-space point into a card's own unrotated space — the inverse
    /// of `cardTransform`.
    ///
    /// §7A.5 requirement 1: resolve the caret index at CLICK TIME in this space,
    /// then animate, then mount with the target already known. Straightening
    /// first would move the click point out from under the cursor and the caret
    /// would land somewhere the writer did not aim.
    static func localPoint(_ contentPoint: CGPoint, inCard frame: CGRect, angle: Angle) -> CGPoint {
        contentPoint.applying(cardTransform(inCard: frame, angle: angle).inverted())
    }

    /// Virtualisation, entire (spec §7A.1): an intersection test in the draw
    /// loop. No `ForEach` identity to preserve, so culling cannot destroy focus
    /// or an in-progress edit.
    static func visibleNodes(in scene: CanvasScene,
                             camera: CanvasCamera,
                             viewSize: CGSize) -> [CanvasNode] {
        scene.nodes(intersecting: camera.visibleContentRect(viewSize: viewSize))
    }

    /// 1C-a draws item nodes as placeholders. 1C-d resolves the real title,
    /// kind glyph and thumbnail (spec §8A.1) — do not do it here.
    static func placeholderLabel(forReference referenceId: String) -> String {
        "Item · \(referenceId)"
    }

    /// Whether this pass draws a node's own text, or leaves it to the editor.
    ///
    /// The rule is Excalidraw's (spec §7A.2): while a scrap's editor is the
    /// VISIBLE text, drawing the text too would double-draw it. The converse is
    /// the half that has been got wrong twice — while the editor is *not*
    /// visible, this pass must draw, whether or not an editor exists.
    ///
    /// A single optional, not a per-node predicate, so at most one node on the
    /// canvas can ever stop drawing its own text.
    static func drawsOwnText(_ id: CanvasNodeID, visibleEditorNodeID: CanvasNodeID?) -> Bool {
        id != visibleEditorNodeID
    }

    /// Draw every visible node under the camera's CTM.
    ///
    /// `visibleEditorNodeID` suppresses that node's TEXT only — see
    /// `drawsOwnText`. Its CARD is still drawn: §7A.5 makes the focused card the
    /// only square one on the canvas, and there is nothing to be square if the
    /// card disappears the moment it is clicked.
    ///
    /// **It is the node whose editor is VISIBLE — neither the node being edited
    /// nor the node whose editor merely exists.** All three differ for the
    /// ~120 ms of the straighten: the writer's click sets
    /// `CanvasView.editingNodeID` and mounts the editor immediately, so no
    /// keystroke is lost, but the editor stays invisible until the card is
    /// level. Through that window this pass keeps drawing the card's text — and
    /// it is live text, because the layout wraps the same `NSTextStorage` the
    /// invisible editor is mutating, and `CanvasView.syncActiveEdit` bumps
    /// `revision` on every keystroke. Blanking it on the click instead would
    /// leave the card empty for that beat and then fill it with axis-aligned
    /// glyphs — the jump §7A.5 was written to prevent. `CanvasView` derives this
    /// argument and the editor's own visibility from ONE property, so they
    /// cannot flip on different frames.
    static func draw(scene: CanvasScene,
                     camera: CanvasCamera,
                     viewSize: CGSize,
                     layouts: [CanvasNodeID: ScrapLayout],
                     visibleEditorNodeID: CanvasNodeID?,
                     straighten: CanvasFocusStraighten,
                     into cx: inout GraphicsContext) {
        cx.translateBy(x: camera.pan.x, y: camera.pan.y)
        cx.scaleBy(x: camera.zoom, y: camera.zoom)

        for node in visibleNodes(in: scene, camera: camera, viewSize: viewSize) {
            guard let frame = node.frame else { continue }
            let ownText = drawsOwnText(node.id, visibleEditorNodeID: visibleEditorNodeID)
            drawCard(node, frame: frame,
                     layout: ownText ? layouts[node.id] : nil,
                     angle: drawnAngle(for: node.id, straighten: straighten),
                     into: &cx)
        }
    }

    /// §7.2: crisp edges, honest objects sitting on the textured ground. The
    /// real/manufactured line runs between the ground and the cards, not through
    /// each card — so no paper fibre here.
    ///
    /// The rotation applies to the WHOLE card, chrome and text together (spec
    /// §7A.5). `angle` is already interpolated by `CanvasFocusStraighten`, so the
    /// card the editor is about to take over arrives here at 0°. A `nil` layout
    /// means "the editor is VISIBLE on this scrap and is drawing its text".
    private static func drawCard(_ node: CanvasNode,
                                 frame: CGRect,
                                 layout: ScrapLayout?,
                                 angle: Angle,
                                 into cx: inout GraphicsContext) {
        let shape = Path(roundedRect: frame, cornerRadius: 3)

        var card = cx
        // ONE definition of the card rotation — the same transform `localPoint`
        // inverts. `concatenating` applies it in the card's space, INSIDE the
        // camera CTM already on the context.
        card.transform = cardTransform(inCard: frame, angle: angle)
            .concatenating(card.transform)

        // Light falls from one corner (§7.1) — a single soft drop, not a glow.
        card.drawLayer { shadow in
            shadow.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, x: 1, y: 2))
            shadow.fill(shape, with: .color(.white))
        }
        card.fill(shape, with: .color(Color(nsColor: .textBackgroundColor)))

        switch node.kind {
        case .scrap:
            card.stroke(shape, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
        case .item:
            // A placeholder reads as unfinished on purpose — 1C-d fills it in.
            card.stroke(shape, with: .color(Color(nsColor: .separatorColor)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        card.fill(resizeHandle(in: frame),
                  with: .color(Color(nsColor: .separatorColor).opacity(0.8)))

        switch node.kind {
        case .scrap:
            // nil = this scrap's editor is mounted and IS its visible text.
            guard let layout else { return }
            let origin = CanvasCardMetrics.textOrigin(inCard: frame)
            card.drawLayer { inner in
                inner.clip(to: shape)
                inner.withCGContext { cg in
                    cg.saveGState()
                    cg.translateBy(x: origin.x, y: origin.y)
                    layout.draw(into: cg, at: .zero)
                    cg.restoreGState()
                }
            }
        case .item(let referenceId):
            var text = card.resolve(
                Text(placeholderLabel(forReference: referenceId))
                    .font(.system(size: 11)))
            text.shading = .color(Color(nsColor: .secondaryLabelColor))
            card.draw(text, at: CanvasCardMetrics.textOrigin(inCard: frame), anchor: .topLeading)
        }
    }

    /// The corner mark a writer aims at to rewrap a scrap.
    ///
    /// **The MARK is a triangle; the TARGET is the whole square**, and that is
    /// deliberate rather than a drift. `CanvasInteraction.begin` tests
    /// `x >= maxX - resizeHandleSize && y >= maxY - resizeHandleSize`, so the
    /// upper-left half of the square — above the triangle's hypotenuse — resizes
    /// without being inked. A target slightly larger than its mark is the right
    /// way round: it forgives a near miss, where the reverse would swallow drags
    /// the writer aimed at the card. One constant fixes the SIZE of both, so the
    /// two cannot drift apart; the shapes are not the same shape and this plan
    /// no longer claims they are.
    /// `CanvasInteractionTests.test_theUnmarkedHalfOfTheCornerSquareStillResizes`
    /// pins the over-size so a future tidy-up cannot quietly shrink the target
    /// to the ink.
    private static func resizeHandle(in frame: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: frame.maxX - resizeHandleSize, y: frame.maxY))
        p.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        p.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - resizeHandleSize))
        p.closeSubpath()
        return p
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRendererTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 21 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasRenderer.swift MaughamTests/Canvas/CanvasRendererTests.swift project.yml
git commit -m "feat(canvas): draw pass — viewport culling, focus-straighten rotation, item placeholders

The whole card carries its seeded angle, and the card that takes focus
animates to level over ~120ms and settles back on blur (spec 7A.5).
isSettled means every card is at ITS target, not that every progress
value is 1 — the latter pauses the clock on blur and strands the card
level. isLevel is the gate Task 10 REVEALS the editor behind (it mounts
on the click; only its visibility waits), so the editor always takes over
the text axis-aligned and the 7A.2 glyph-origin pin compares two
unrotated layouts. drawsOwnText is the other half of that one swap: at
most one node ever stops drawing its own text, and only while the editor
is visible on it. One cardTransform, used forwards by the draw pass
and inverted by the caret hit test. Pins that no file in Maugham/Canvas
derives a raster scale or a second rotation of its own."
```

---

### Task 8: The ground

**Files:**
- Create: `Maugham/Canvas/CanvasGround.metal`
- Create: `Maugham/Canvas/CanvasGround.swift`
- Test: `MaughamTests/Canvas/CanvasGroundTests.swift`

**Interfaces:**
- **Consumes:** `CanvasCamera` (Task 4).
- **Produces:**
  - `struct CanvasGround: View` — `let camera: CanvasCamera`, `let wash: [Color]`, `static let grainScale: CGFloat`.
  - `enum CanvasGroundPalette` — `static let washOpacity: Double`, `static let maximumSwatches: Int`, `static func validHexes(_ hexes: [String]) -> [String]`, `static func wash(fromHex hexes: [String]) -> [Color]`.

**The seam is `[String]` hex, not `[Color]`.** `PaletteCard.swatches` is `[String]` of `"#RRGGBB"`; `MaughamCore`'s `PaletteCard.color(fromHex:)` is the one parser. Typing the seam `[Color]` would have forced a second conversion site and hidden malformed hexes behind a silent `.clear`.

**Hard constraint (spec §7A.4):** a shader applied *over* a subtree containing an `NSViewRepresentable` logs a warning and renders a placeholder. The ground must be a **sibling layer beneath** the content, never an overlay across it. Task 10 composes it that way; this task must not introduce an overlay.

**`.drawingGroup()` is deliberately absent.** An earlier draft carried one with the comment "keeps the grain off the content subtree" — which was wrong twice: the isolation comes from the ground being a ZStack *sibling*, and `.drawingGroup()` would add an offscreen render target on every pan for a subtree that is already one GPU-filled rectangle. Do not add it back.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
import Metal
@testable import Maugham

final class CanvasGroundTests: XCTestCase {

    /// §7.1: "Dosage is the risk — at 15% a grim palette yields a canvas you
    /// cannot work on. The wash is felt, not seen."
    func test_washOpacityStaysInTheFeltNotSeenBand() {
        XCTAssertGreaterThanOrEqual(CanvasGroundPalette.washOpacity, 0.03)
        XCTAssertLessThanOrEqual(CanvasGroundPalette.washOpacity, 0.05)
    }

    func test_washFromNoSwatches_isEmptyNotACrash() {
        XCTAssertTrue(CanvasGroundPalette.wash(fromHex: []).isEmpty)
        XCTAssertTrue(CanvasGroundPalette.validHexes([]).isEmpty)
    }

    func test_washIsCappedSoOnePaletteCannotStripeTheGround() {
        let many = (0..<40).map { _ in "#8A6F4D" }
        XCTAssertEqual(CanvasGroundPalette.validHexes(many).count,
                       CanvasGroundPalette.maximumSwatches)
        XCTAssertEqual(CanvasGroundPalette.wash(fromHex: many).count,
                       CanvasGroundPalette.maximumSwatches)
    }

    /// Order is the palette's, not the dictionary's — the wash of a project
    /// must look the same on every launch.
    func test_washPreservesSwatchOrder() {
        let hexes = ["#8A6F4D", "#2F3B4C", "#C0392B"]
        XCTAssertEqual(CanvasGroundPalette.validHexes(hexes), hexes)
    }

    func test_malformedHexesAreDroppedRatherThanPaintedClear() {
        let hexes = ["#8A6F4D", "not-a-colour", "", "#GGGGGG", "#2F3B4C"]
        XCTAssertEqual(CanvasGroundPalette.validHexes(hexes), ["#8A6F4D", "#2F3B4C"])
    }

    func test_shortFormHexIsAccepted() {
        XCTAssertEqual(CanvasGroundPalette.validHexes(["#abc"]), ["#abc"])
    }

    /// C5: the shader must actually be compiled into the app. A `.metal` file
    /// that never reaches the target leaves `.colorEffect` a silent no-op and
    /// the ground renders flat — which looks like a design choice, not a bug.
    func test_groundShaderIsCompiledIntoTheDefaultMetalLibrary() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        let library = try device.makeDefaultLibrary(bundle: .main)
        XCTAssertTrue(library.functionNames.contains { $0.contains("canvasGround") },
                      "CanvasGround.metal did not compile into the app's default.metallib. "
                      + "Functions found: \(library.functionNames)")
    }

    /// C5 again, from the other side: writing the shader and never applying it
    /// is the failure this pins. Source-level because there is no runtime hook
    /// that reports "this view has a colorEffect".
    func test_canvasGroundActuallyAppliesTheShader() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()    // MaughamTests/Canvas
                .deletingLastPathComponent()    // MaughamTests
                .deletingLastPathComponent()    // repo root
                .appendingPathComponent("Maugham/Canvas/CanvasGround.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains(".colorEffect("),
                      "CanvasGround declares a shader it never applies")
        XCTAssertTrue(source.contains("ShaderLibrary.canvasGround"),
                      "the applied shader must be the one CanvasGround.metal defines")
        XCTAssertFalse(source.contains(".drawingGroup()"),
                       "drawingGroup adds an offscreen render target per pan and buys "
                       + "nothing here — the ground is one GPU-filled rectangle, and "
                       + "isolation comes from being a ZStack sibling")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasGroundTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasGroundPalette' in scope`.

- [ ] **Step 3: Write the shader**

`Maugham/Canvas/CanvasGround.metal`:

```metal
#include <metal_stdlib>
using namespace metal;

// Seeded value noise. Generated per-pixel in CONTENT space, not screen space:
// a shader using bare `position` makes the grain crawl across the paper as you
// pan (spec §7A.4).
static float hash21(float2 p) {
    // SplitMix-flavoured integer hash. Deliberately not `fract(sin(...))`,
    // which bands badly on Apple GPUs at low amplitude.
    uint2 q = uint2(int2(floor(p))) * uint2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y) * 1597334673u;
    n = (n ^ (n >> 15)) * 2246822519u;
    n = (n ^ (n >> 13)) * 3266489917u;
    return float(n ^ (n >> 16)) / 4294967295.0;
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// A `colorEffect` shader: SwiftUI supplies `position` (this view's local
// coordinate space) and `currentColor` (the pixel already painted — here the
// appearance-resolved base colour). Everything after those is a uniform we pass.
//
// pan/zoom arrive as uniforms so the grain is sampled in CONTENT space and
// stays put under the writer's hand.
[[ stitchable ]]
half4 canvasGround(float2 position,
                   half4 currentColor,
                   float2 pan,
                   float zoom,
                   float grainScale) {
    float2 content = (position - pan) / max(zoom, 0.0001);

    // Fade grain amplitude as a function of zoom to kill moire on zoom-out.
    // Analytically fwidth(content) == 1.0/zoom, so no derivative functions are
    // needed (spec §7A.4).
    float amplitude = 0.055 * smoothstep(0.25, 1.0, zoom);

    float n = valueNoise(content * grainScale) - 0.5;
    half3 rgb = currentColor.rgb + half3(half(n * amplitude));

    // Light falls from one corner (§7.1). Light ages better than texture.
    float2 lit = content * 0.0004;
    half fall = half(clamp(1.0 - 0.10 * length(lit - float2(-0.35, -0.35)), 0.86, 1.0));

    return half4(rgb * fall, currentColor.a);
}
```

- [ ] **Step 4: Write the Swift side**

`Maugham/Canvas/CanvasGround.swift`:

```swift
import SwiftUI
import MaughamCore

/// The canvas ground.
///
/// MUST be a sibling layer BENEATH the content, never an overlay across it: a
/// shader applied over a subtree containing an `NSViewRepresentable` logs a
/// warning and renders a placeholder (spec §7A.4, documented on
/// `colorEffect`/`layerEffect`/`distortionEffect`). The canvas has two of them —
/// the event view and the mounted scrap editor — so this view holds no content
/// of its own and `CanvasView` stacks it underneath.
///
/// No `.drawingGroup()`. It would add an offscreen render target on every pan
/// for a subtree that is already a single GPU-filled rectangle, and the
/// isolation it was once credited with actually comes from the ZStack.
struct CanvasGround: View {
    let camera: CanvasCamera
    /// 3–5% wash from the project's own sensory palette swatches (§7.1).
    let wash: [Color]

    /// Grain cell size in CONTENT points. Small enough to read as tooth, large
    /// enough that a zoomed-out canvas is not a moiré field.
    static let grainScale: CGFloat = 0.9

    private var baseColor: Color {
        // Light: a muted canvas weave. Dark: slate under a lamp — a different
        // material, not the same texture inverted. Paper is a light-mode idea.
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)
                : NSColor(calibratedRed: 0.93, green: 0.915, blue: 0.88, alpha: 1)
        })
    }

    var body: some View {
        Rectangle()
            .fill(baseColor)
            // The shader reads the filled base as `currentColor`, so the
            // appearance resolution stays in Swift and the grain is content-space.
            .colorEffect(
                ShaderLibrary.canvasGround(
                    .float2(camera.pan.x, camera.pan.y),
                    .float(camera.zoom),
                    .float(Self.grainScale)))
            .overlay {
                // The wash is felt, not seen — see CanvasGroundPalette.washOpacity.
                if !wash.isEmpty {
                    LinearGradient(colors: wash,
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(CanvasGroundPalette.washOpacity)
                        .blendMode(.softLight)
                }
            }
            .allowsHitTesting(false)
    }
}

enum CanvasGroundPalette {
    /// §7.1 names the dosage and names the risk: "Washed 3–5% by the project's
    /// own sensory palette swatches… at 15% a grim palette yields a canvas you
    /// cannot work on. The wash is felt, not seen."
    static let washOpacity: Double = 0.04

    /// A palette with thirty entries would stripe the ground rather than tint it.
    static let maximumSwatches = 5

    /// The seam is HEX, matching `PaletteCard.swatches`. Malformed entries are
    /// dropped rather than painted `.clear` — a silent transparent band in the
    /// gradient is a bug that looks like a design choice. Order is the palette's.
    static func validHexes(_ hexes: [String]) -> [String] {
        hexes.filter { PaletteCard.color(fromHex: $0) != nil }
            .prefix(maximumSwatches)
            .map { $0 }
    }

    static func wash(fromHex hexes: [String]) -> [Color] {
        validHexes(hexes).compactMap { hex in
            guard let c = PaletteCard.color(fromHex: hex) else { return nil }
            return Color(red: c.r, green: c.g, blue: c.b)
        }
    }
}
```

- [ ] **Step 5: Confirm the `.metal` file joins the target**

`project.yml`'s Maugham target lists `path: Maugham` wholesale, so `CanvasGround.metal` should be picked up. Confirm rather than assume — a `.metal` that misses the Sources phase makes `.colorEffect` a silent no-op:

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -i "metal"
```
Expected: a `CompileMetalFile` line naming `CanvasGround.metal` and a `MetalLink`/`default.metallib` line. If absent, add an explicit `- path: Maugham/Canvas/CanvasGround.metal` source entry to the Maugham target in `project.yml` and re-run.

- [ ] **Step 6: Run the tests and a Release build**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasGroundTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 8 tests. `test_groundShaderIsCompiledIntoTheDefaultMetalLibrary` must PASS, not skip — record its outcome in the task report.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasGround.metal Maugham/Canvas/CanvasGround.swift MaughamTests/Canvas/CanvasGroundTests.swift project.yml
git commit -m "feat(canvas): ground — content-space grain shader, hex palette wash at felt-not-seen dosage

The shader is APPLIED, not merely written: .colorEffect(ShaderLibrary.canvasGround)
with pan/zoom/grainScale uniforms, pinned by a library-resolution test."
```

---

### Task 9: The mounted scrap editor

**Files:**
- Create: `Maugham/Canvas/ScrapEditorHost.swift`
- Test: `MaughamTests/Canvas/ScrapEditorHostTests.swift`

**Interfaces:**
- **Consumes:** `ScrapLayout` (Task 3); `CanvasCamera` (Task 4).
- **Produces:**
  - `final class ScrapEditorContainer: NSView, NSTextViewDelegate` — `private(set) var textView: NSTextView?`, `var isEditorVisible: Bool` (default `true`), `var canvasUndoManager: UndoManager?`, `var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?`, `var onMagnify: ((CGFloat, CGPoint) -> Void)?`, `var onTextChanged: (() -> Void)?`, `@discardableResult func mount(layout: ScrapLayout, unscaledSize: CGSize, zoom: CGFloat) -> Bool` (returns `true` when the editor was built or rebuilt), `func requestFocus(caretIndex: Int?)`, `func unmount()`; testable seams `applyScroll(deltaX:deltaY:precise:)`, `applyMagnify(magnification:atEditorPoint:)`.
  - `struct ScrapEditorHost: NSViewRepresentable` — `let layout: ScrapLayout`, `let unscaledSize: CGSize`, `let zoom: CGFloat`, `let caretIndex: Int?`, `let isEditorVisible: Bool`, `let undoManager: UndoManager?`, `let onScroll: (CGFloat, CGFloat, Bool) -> Void`, `let onMagnify: (CGFloat, CGPoint) -> Void`, `let onTextChanged: () -> Void`. **The parameter is `unscaledSize: CGSize`, not `frame: CGRect`** — the host owns the size, `CanvasView` owns the position.
  - `enum ScrapEditorGeometry` — `static func viewPoint(fromEditorPoint: CGPoint, textOrigin: CGPoint, camera: CanvasCamera) -> CGPoint`.

**Five defects this task exists to not have.** Each is a smoke failure a writer meets in the first minute, and none is caught by a test that counts subviews.

1. **First responder.** `makeNSView` runs *before* the view is in a window, so `tv.window` is `nil` and `tv.window?.makeFirstResponder(tv)` is a silent no-op. Focus is therefore **requested** and claimed again from `viewDidMoveToWindow`.
2. **Rebinding.** `mount` must rebuild the text view when the *layout identity* changes, not merely when there is no text view. Creating it only `if textView == nil` means clicking from scrap A to scrap B keeps editing A — and a test that counts subviews passes anyway.
3. **The writer's words never leave the editor.** Typing mutates the shared `NSTextStorage` inside `ScrapLayout`. If nothing tells the canvas that happened, `scraps[id]` still holds the text as it was *before* the writer typed — so the debounced payload is stale, the drawn card never grows, and **double-click empty space → type a sentence → ⌘Q → relaunch leaves an empty scrap.** That is the product constitution's must #1, *the words are safe*, failing on the very first interaction. The container is therefore the text view's `NSTextViewDelegate` and reports every change through `onTextChanged`; Task 10 folds it into the model on the spot.
4. **The pinch anchor is in the wrong space.** `magnify(with:)` converts `event.locationInWindow` into the **container's** bounds — the scrap's own unzoomed text box. Handing that straight to `camera.zoom(to:anchoringViewPoint:)`, which expects canvas view space, zooms about a point the writer never touched. (`CanvasEventNSView` is correct only because its space *is* canvas space.) So this file forwards a point in its own space, says so in the name (`atEditorPoint:`), and `ScrapEditorGeometry.viewPoint` is the one place that maps it — through `CanvasCamera`'s existing transform, because the editor is placed unrotated at the card's text origin and, while it is *visible*, the card under it is level (§7A.5).

5. **An invisible editor that still swallows the pointer.** The editor is mounted from the instant the writer clicks — otherwise the first characters of a double-click-and-type reach nothing — but for the ~120 ms of the straighten it is not drawn, because the card is still drawing its own rotating text (Task 10). An invisible, frontmost `NSView` that keeps hit-testing is a trap: a click or a pinch inside that window would be resolved against the editor's *unrotated* box while the writer is looking at a card up to 0.6° off level. So visibility and hit testing are the same switch — `isEditorVisible` sets `alphaValue` **and** short-circuits `hitTest(_:)`. First responder is unaffected by both, which is the point: key events go to the window's first responder and never through hit testing, so an invisible editor still takes every keystroke while the pointer passes through to `CanvasEventNSView`, whose space *is* canvas space. Do not reach for `.hidden()` or `isHidden` — AppKit moves first responder off a hidden view, which is exactly the keystroke loss this is here to prevent.

**Zoomed editing uses bounds scaling** — the spike's Q4. Grow the container's `frame` by zoom, hold its `bounds` at the unzoomed size. Coordinates round-trip correctly at every zoom tested (1×–3×) and AppKit re-rasterises, so text stays crisp. Crucially it involves **no re-layout**, so Task 3's proven drawn/edited agreement carries over unchanged. Do not reach for `.scaleEffect`, and do not re-lay-out the editor at a scaled font size.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/ScrapEditorHostTests.swift`:

```swift
import XCTest
import AppKit
@testable import Maugham

final class ScrapEditorHostTests: XCTestCase {

    private let size = CGSize(width: 240, height: 100)

    private func layout(_ text: String = "The falls at night: sodium light on the "
                        + "spray, and nobody there but the man selling ponchos.") -> ScrapLayout {
        ScrapLayout(text: text, width: 240,
                    font: NSFont(name: "Iowan Old Style", size: 13) ?? .systemFont(ofSize: 13))
    }

    /// Keep the window alive for the length of the test — a released window
    /// drops first responder and the assertion becomes a coin flip.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func host(_ container: ScrapEditorContainer) -> NSWindow {
        let frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSView(frame: frame)
        window.contentView?.addSubview(container)
        container.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    func test_boundsScalingLeavesTheUnzoomedCoordinateSpaceIntact() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 2)
        XCTAssertEqual(container.frame.size, CGSize(width: 480, height: 200))
        XCTAssertEqual(container.bounds.size, size,
                       "bounds must stay unzoomed — that is what keeps the drawn "
                       + "and edited layouts identical at zoom")
    }

    func test_zoomChangeResizesFrameButNeverBounds() {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout()
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        let signature = l.lineGeometrySignature
        container.mount(layout: l, unscaledSize: size, zoom: 3)
        XCTAssertEqual(container.bounds.size, size)
        XCTAssertEqual(l.lineGeometrySignature, signature,
                       "zooming must not re-lay-out the text")
    }

    func test_mountedEditorSharesTheLayoutStack() {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout()
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)
        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(l.text.hasPrefix("Z"))
    }

    func test_remountingTheSameLayoutKeepsOneEditorAndDoesNotRebuild() {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout()
        XCTAssertTrue(container.mount(layout: l, unscaledSize: size, zoom: 1))
        XCTAssertFalse(container.mount(layout: l, unscaledSize: size, zoom: 1),
                       "the same layout must not tear down a live editor")
        XCTAssertEqual(container.subviews.count, 1)
    }

    /// Counting subviews is not enough: an editor still bound to the FIRST
    /// scrap while the writer types into the second is invisible to a count.
    func test_remountingADifferentLayoutRebindsTheEditorToTheNewScrap() {
        let container = ScrapEditorContainer(frame: .zero)
        let first = layout("first scrap")
        let second = layout("second scrap")

        container.mount(layout: first, unscaledSize: size, zoom: 1)
        host(container)
        XCTAssertTrue(container.mount(layout: second, unscaledSize: size, zoom: 1),
                      "a different layout must rebuild the editor")
        XCTAssertEqual(container.subviews.count, 1,
                       "a second mount must not leave the first editor behind")

        container.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(second.text.hasPrefix("Z"),
                      "the editor is still bound to the FIRST scrap — clicking from "
                      + "scrap A to scrap B keeps editing A")
        XCTAssertFalse(first.text.hasPrefix("Z"))
    }

    /// `makeNSView` runs before the view is in a window, so
    /// `tv.window` is nil and makeFirstResponder is a silent no-op.
    func test_focusRequestedBeforeMountIsClaimedOnceTheViewEntersAWindow() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        container.requestFocus(caretIndex: 3)
        XCTAssertNil(container.window, "precondition: not in a window yet")

        let window = host(container)

        XCTAssertTrue(window.firstResponder === container.textView,
                      "focus was requested while window was nil and silently dropped — "
                      + "the scrap mounts and refuses every keystroke")
        XCTAssertEqual(container.textView?.selectedRange().location, 3)
    }

    func test_focusRequestedWhileAlreadyInAWindowIsImmediate() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        let window = host(container)
        container.requestFocus(caretIndex: 0)
        XCTAssertTrue(window.firstResponder === container.textView)
    }

    /// The whole reason the editor mounts on the click rather than on `isLevel`:
    /// double-click empty canvas and start typing, and the first characters must
    /// land somewhere. They land here, in an editor nobody can see yet, while the
    /// renderer keeps drawing the card's own (rotating, live) text.
    func test_anInvisibleEditorStillHoldsFocusAndTakesKeystrokes() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        let l = layout("before")
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        container.isEditorVisible = false
        let window = host(container)
        container.requestFocus(caretIndex: 0)

        XCTAssertEqual(container.alphaValue, 0,
                       "the editor must not be drawn while the card is still "
                       + "drawing its own text — that is a double-draw")
        XCTAssertTrue(window.firstResponder === container.textView,
                      "invisible must not mean unfocused, or the writer's first "
                      + "characters after a double-click go nowhere")

        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(l.text.hasPrefix("Z"),
                      "a keystroke during the straighten was discarded")
    }

    /// Visibility and hit testing are the same switch. While the editor is
    /// invisible the pointer belongs to `CanvasEventNSView`, whose space IS
    /// canvas space — so nothing resolves a click or a pinch against the
    /// editor's unrotated box while the card under it is still tilted.
    func test_anInvisibleEditorLetsThePointerThroughToTheCanvas() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        host(container)
        let inside = CGPoint(x: 10, y: 10)

        XCTAssertNotNil(container.hitTest(inside),
                        "precondition: a visible editor owns its own mouse")
        container.isEditorVisible = false
        XCTAssertNil(container.hitTest(inside),
                     "an invisible editor is still frontmost — if it hit-tests it "
                     + "eats the click and anchors the pinch on a card that is "
                     + "not where the writer sees it")
    }

    func test_caretIndexBeyondTheTextIsClampedRatherThanCrashing() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        let l = layout("short")
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)
        container.requestFocus(caretIndex: 9_999)
        XCTAssertEqual(container.textView?.selectedRange().location, 5)
    }

    /// C5. Typing mutates the shared NSTextStorage in place. If nothing reports
    /// that, `scraps[id]` keeps the text as it was BEFORE the writer typed — the
    /// debounced payload is stale, the drawn card never grows, and quitting
    /// without clicking away leaves an empty scrap on disk.
    func test_typingReportsItselfSoTheCanvasCanFoldItIntoTheModel() {
        let container = ScrapEditorContainer(frame: .zero)
        var changes = 0
        container.onTextChanged = { changes += 1 }
        let l = layout("before")
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)

        container.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertGreaterThan(changes, 0,
                             "nothing told the canvas the writer typed — the words "
                             + "live only in the NSTextStorage and are lost on quit")
        XCTAssertTrue(l.text.hasPrefix("Z"))
    }

    func test_mountSetsTheContainerAsTheTextViewsDelegate() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        XCTAssertTrue(container.textView?.delegate === container,
                      "without the delegate there is no textDidChange and C5 returns")
    }

    /// The editor is frontmost, so it gets the scroll wheel while the writer is
    /// editing. Without forwarding, panning dies wherever the scrap is.
    func test_theContainerForwardsScrollAndMagnifyToTheCamera() {
        let container = ScrapEditorContainer(frame: .zero)
        var scrolls: [CGFloat] = []
        var magnifications: [CGFloat] = []
        container.onScroll = { _, dy, _ in scrolls.append(dy) }
        container.onMagnify = { m, _ in magnifications.append(m) }
        container.applyScroll(deltaX: 0, deltaY: 12, precise: true)
        container.applyMagnify(magnification: 0.25, atEditorPoint: .zero)
        XCTAssertEqual(scrolls, [12])
        XCTAssertEqual(magnifications, [0.25])
    }

    /// I7. The container's bounds are the scrap's own UNZOOMED text box, so the
    /// point it forwards is not canvas space and must not be scaled on the way
    /// out either — `ScrapEditorGeometry` is the one place that maps it.
    func test_theForwardedMagnifyPointStaysInTheEditorsOwnUnzoomedSpace() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 2)
        var points: [CGPoint] = []
        container.onMagnify = { _, p in points.append(p) }
        container.applyMagnify(magnification: 0.1, atEditorPoint: CGPoint(x: 10, y: 20))
        XCTAssertEqual(points, [CGPoint(x: 10, y: 20)],
                       "the container must not pre-apply zoom — bounds are unzoomed")
    }

    /// The mapping the composed view uses. Anchoring the pinch on the raw
    /// editor point instead zooms about a point the writer never touched.
    func test_editorPointsMapIntoCanvasViewSpaceThroughTheCamera() {
        var camera = CanvasCamera()
        camera.zoom = 2
        camera.pan = CGPoint(x: 50, y: 30)
        let mapped = ScrapEditorGeometry.viewPoint(fromEditorPoint: CGPoint(x: 10, y: 10),
                                                   textOrigin: CGPoint(x: 100, y: 100),
                                                   camera: camera)
        // content (110,110) -> view (50 + 220, 30 + 220)
        XCTAssertEqual(mapped.x, 270, accuracy: 0.0001)
        XCTAssertEqual(mapped.y, 250, accuracy: 0.0001)
    }

    func test_theMountedEditorUsesTheCanvasUndoManager() {
        let container = ScrapEditorContainer(frame: .zero)
        let manager = UndoManager()
        container.canvasUndoManager = manager
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        host(container)
        XCTAssertTrue(container.textView?.undoManager === manager,
                      "⌘Z while a scrap is focused must run the CANVAS stack — the "
                      + "text view has allowsUndo == false and owns no stack of "
                      + "its own (Task 15)")
        XCTAssertFalse(container.textView?.allowsUndo == true,
                       "one change, one step: see ScrapLayout.makeEditor")
    }

    /// Spec §7A.6: the mounted editor must stay reachable by VoiceOver. It is a
    /// real NSTextView, so this is about not hiding it.
    ///
    /// **Expect this one to need adjustment on its first run.** It asserts
    /// AppKit's *defaults* on views that were never added to a window, and
    /// `isAccessibilityElement()` is not contractually pinned for an unhosted
    /// `NSView`. If it fails, host the container with `host(container)` first and
    /// re-check; if it still disagrees, assert the thing that actually matters —
    /// that this file sets neither `setAccessibilityElement(false)` on the text
    /// view nor `true` on the container — rather than deleting the test.
    func test_theMountedEditorIsExposedToAccessibility() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        XCTAssertFalse(container.isAccessibilityElement(),
                       "the container must not absorb its text view's AX identity")
        XCTAssertTrue(container.textView?.isAccessibilityElement() == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapEditorHostTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'ScrapEditorContainer' in scope`.

- [ ] **Step 3: Write the editor host**

`Maugham/Canvas/ScrapEditorHost.swift`:

```swift
import AppKit
import SwiftUI

/// Holds the one real `NSTextView` the canvas ever mounts, and scales it to the
/// camera's zoom by BOUNDS SCALING: the frame grows, the bounds do not.
///
/// This is what `NSScrollView.magnification` does internally, and the
/// 2026-07-25 spike verified it: coordinates round-trip exactly at zoom 1, 1.5,
/// 2 and 3, and ink area grows as zoom², which means AppKit genuinely
/// re-rasterises rather than upscaling a blurry bitmap.
///
/// The decisive property is that it involves **no re-layout**. The alternative —
/// laying the editor out at font×zoom and width×zoom — also reproduces the same
/// line breaks (measured, four fonts, 0.5x–3x), but it re-runs layout, and every
/// re-layout is a chance for drawn and edited to diverge. Bounds scaling keeps
/// that door shut. Do NOT replace this with `.scaleEffect`: it scales rendered
/// output, so the text blurs, and it breaks `NSCursor` tracking (spec §7A.1).
///
/// This view is the FRONTMOST layer of the canvas, so the writer gets AppKit's
/// own caret placement, drag-select and double-click-word. The cost is that it
/// also receives scroll and magnify while a scrap is focused, so it forwards
/// both back to the camera.
final class ScrapEditorContainer: NSView, NSTextViewDelegate {

    private(set) var textView: NSTextView?
    /// Identity of the layout the current text view is bound to. Rebinding is
    /// keyed on THIS, not on `textView == nil`: clicking from scrap A to scrap B
    /// must rebuild, and a subview count cannot tell the difference.
    private var mountedLayout: ObjectIdentifier?

    private var wantsFocus = false
    private var pendingCaretIndex: Int?

    /// Whether the editor is the VISIBLE text of its scrap.
    ///
    /// It is mounted, focused and taking keystrokes long before this goes true:
    /// `CanvasView` mounts on the click so nothing the writer types is lost, and
    /// flips this at `CanvasFocusStraighten.isLevel(_:)`, on the same frame the
    /// renderer stops drawing that card's own text. While it is `false` the
    /// words on screen are the drawn ones — the same shared `NSTextStorage`,
    /// rotating with the card.
    ///
    /// It drives TWO things and both are required. `alphaValue` stops the
    /// double-draw. `hitTest(_:)` stops an invisible frontmost view owning the
    /// mouse: a click or a pinch inside that window would be resolved against
    /// this view's UNROTATED box while the card beneath is still up to 0.6° off
    /// level, so the pointer belongs to `CanvasEventNSView` — whose space is
    /// canvas space — until the handover is complete.
    ///
    /// **Not `isHidden`, and not SwiftUI's `.hidden()`.** AppKit moves first
    /// responder off a hidden view, which loses exactly the keystrokes mounting
    /// early exists to keep. `alphaValue` and `hitTest` leave the responder
    /// chain alone.
    /// Guarded on a real change: `updateNSView` re-wires this on every body
    /// pass, and `revision` ticks at frame rate through every straighten, coast
    /// and drag — an unguarded `alphaValue` write would dirty the layer 60–120
    /// times a second to set it to the value it already had.
    var isEditorVisible: Bool = true {
        didSet {
            guard isEditorVisible != oldValue else { return }
            alphaValue = isEditorVisible ? 1 : 0
        }
    }

    var canvasUndoManager: UndoManager?
    var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
    /// (magnification delta, point in THIS view's own unzoomed space). NOT
    /// canvas space — see `applyMagnify`.
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    /// Fired on every change the writer makes. The canvas folds the text into
    /// its model on the spot; without this the words live only in the shared
    /// `NSTextStorage` and are lost on quit (C5).
    var onTextChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    /// See `isEditorVisible`. Returning `nil` takes this view out of the hit
    /// chain entirely, so the click reaches `CanvasEventNSView` beneath it — and
    /// leaves first responder, and therefore every keystroke, untouched.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditorVisible else { return nil }
        return super.hitTest(point)
    }

    /// `NSTextView` asks its delegate, then walks the responder chain. This
    /// container is its superview, so returning the canvas manager here is what
    /// makes ⌘Z-while-editing run the canvas stack. The text view itself has
    /// `allowsUndo == false` and registers nothing, so there is exactly one
    /// stack and exactly one step per change (Task 15).
    override var undoManager: UndoManager? { canvasUndoManager ?? super.undoManager }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        onTextChanged?()
    }

    /// Returns `true` when the editor was built or rebuilt.
    @discardableResult
    func mount(layout: ScrapLayout, unscaledSize: CGSize, zoom: CGFloat) -> Bool {
        let identity = ObjectIdentifier(layout)
        var rebuilt = false
        if mountedLayout != identity {
            textView?.delegate = nil
            textView?.removeFromSuperview()
            let tv = layout.makeEditor(frame: CGRect(origin: .zero, size: unscaledSize))
            // Without this there is no `textDidChange`, and the writer's words
            // never reach the model (C5).
            tv.delegate = self
            addSubview(tv)
            textView = tv
            mountedLayout = identity
            rebuilt = true
        }
        textView?.frame = CGRect(origin: .zero, size: unscaledSize)

        // Frame in zoomed (view) space; bounds in unzoomed (content) space.
        frame = CGRect(origin: frame.origin,
                       size: CGSize(width: unscaledSize.width * zoom,
                                    height: unscaledSize.height * zoom))
        bounds = CGRect(origin: .zero, size: unscaledSize)
        return rebuilt
    }

    /// Focus is REQUESTED, never taken on the spot.
    ///
    /// `NSViewRepresentable.makeNSView` runs BEFORE the view is in a window, so
    /// `textView.window` is nil and `window?.makeFirstResponder(_:)` is a silent
    /// no-op. The scrap then mounts, looks perfect, and refuses every keystroke —
    /// which reads as "typing does nothing", the headline interaction failing.
    /// So record the wish and claim it again from `viewDidMoveToWindow`.
    func requestFocus(caretIndex: Int?) {
        wantsFocus = true
        pendingCaretIndex = caretIndex
        claimFocusIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimFocusIfPossible()
    }

    private func claimFocusIfPossible() {
        guard wantsFocus, let tv = textView, let window else { return }
        if let index = pendingCaretIndex {
            tv.setSelectedRange(NSRange(location: min(index, tv.string.count), length: 0))
        }
        window.makeFirstResponder(tv)
        wantsFocus = false
        pendingCaretIndex = nil
    }

    func unmount() {
        textView?.delegate = nil
        textView?.removeFromSuperview()
        textView = nil
        mountedLayout = nil
        wantsFocus = false
        pendingCaretIndex = nil
    }

    // MARK: - Camera forwarding (testable seams, as in CanvasEventNSView)

    func applyScroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) {
        onScroll?(deltaX, deltaY, precise)
    }

    /// `editorPoint` is in THIS view's own coordinate space — the scrap's
    /// unzoomed text box, because bounds scaling holds `bounds` at the unzoomed
    /// size. It is NOT canvas space, and handing it straight to
    /// `CanvasCamera.zoom(to:anchoringViewPoint:)` — which expects canvas space
    /// — zooms about a point the writer never touched. `CanvasEventNSView` gets
    /// away with the identical code only because ITS space is canvas space. The
    /// one place that maps between them is `ScrapEditorGeometry.viewPoint`.
    func applyMagnify(magnification: CGFloat, atEditorPoint point: CGPoint) {
        onMagnify?(magnification, point)
    }

    override func scrollWheel(with event: NSEvent) {
        applyScroll(deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas)
    }

    override func magnify(with event: NSEvent) {
        applyMagnify(magnification: event.magnification,
                     atEditorPoint: convert(event.locationInWindow, from: nil))
    }
}

/// The one place a point in the mounted editor's space becomes a point in canvas
/// VIEW space.
///
/// The editor's space is content space translated to the card's text origin —
/// exactly, and with **no rotation term**, because `CanvasView` places the
/// container at the UNROTATED text origin and the container itself is never
/// rotated. As a mapping of the editor's own box this is unconditionally right.
///
/// What it cannot express is the card's *drawn* angle, and there is now a window
/// in which those differ: the editor is mounted from the click (so no keystroke
/// is lost) while the card spends ~120 ms straightening under it. Anchoring a
/// pinch through here during that window would be off by up to `r·θ` — ≈1.4 pt
/// at the corner of a default card — from where the writer's fingers are on the
/// card they can see.
///
/// **That window is closed by hit testing, not by arithmetic.** This function is
/// only ever reached from an event the container received, and
/// `ScrapEditorContainer.hitTest(_:)` returns `nil` while `isEditorVisible` is
/// false, so the event goes to `CanvasEventNSView` instead — whose space *is*
/// canvas space, with no approximation at all. By the time anything reaches this
/// function the card is level and drawn angle and editor box agree exactly.
///
/// The one thing that can still read the editor's geometry while it is invisible
/// is AppKit's own input-method candidate window, which anchors on the text
/// view's rect. Its error is bounded by the same ≈1.4 pt the unrotated hit test
/// already accepts, and it lasts a tenth of a second; it is accepted, not
/// overlooked.
enum ScrapEditorGeometry {
    static func viewPoint(fromEditorPoint point: CGPoint,
                          textOrigin: CGPoint,
                          camera: CanvasCamera) -> CGPoint {
        camera.viewPoint(fromContent: CGPoint(x: textOrigin.x + point.x,
                                              y: textOrigin.y + point.y))
    }
}

/// SwiftUI wrapper. Exactly one of these is ever in the hierarchy — the scrap
/// currently being edited (spec §7A.1). It is in the hierarchy from the instant
/// the writer clicks; `isEditorVisible` is what waits for the straighten.
struct ScrapEditorHost: NSViewRepresentable {
    let layout: ScrapLayout
    /// The TEXT box size, in content points. `CanvasView` owns the position and
    /// the card inset; this view owns only the editor.
    let unscaledSize: CGSize
    let zoom: CGFloat
    /// Where the writer clicked, so the caret lands where they aimed
    /// (spec §7A.2, the rule borrowed from Miro).
    let caretIndex: Int?
    /// Whether this editor is the visible text yet — see
    /// `ScrapEditorContainer.isEditorVisible`. `CanvasView` derives it from the
    /// same property it hands the renderer, so the editor appearing and the card
    /// ceasing to draw its text happen on one frame.
    let isEditorVisible: Bool
    let undoManager: UndoManager?
    let onScroll: (CGFloat, CGFloat, Bool) -> Void
    /// (magnification delta, point in the EDITOR's own unzoomed space). The
    /// caller maps it with `ScrapEditorGeometry.viewPoint`.
    let onMagnify: (CGFloat, CGPoint) -> Void
    /// Every change the writer makes, so the canvas can fold it into the model
    /// immediately (C5). Not debounced here — the store already debounces.
    let onTextChanged: () -> Void

    func makeNSView(context: Context) -> ScrapEditorContainer {
        let c = ScrapEditorContainer(frame: .zero)
        wire(c)
        c.mount(layout: layout, unscaledSize: unscaledSize, zoom: zoom)
        // Deliberately a REQUEST: there is no window yet.
        c.requestFocus(caretIndex: caretIndex)
        return c
    }

    func updateNSView(_ c: ScrapEditorContainer, context: Context) {
        wire(c)
        // Only re-claim focus when the editor was actually rebound — otherwise
        // every camera nudge would slam the caret back to the click point.
        if c.mount(layout: layout, unscaledSize: unscaledSize, zoom: zoom) {
            c.requestFocus(caretIndex: caretIndex)
        }
    }

    static func dismantleNSView(_ c: ScrapEditorContainer, coordinator: ()) {
        c.unmount()
    }

    private func wire(_ c: ScrapEditorContainer) {
        c.isEditorVisible = isEditorVisible
        c.canvasUndoManager = undoManager
        c.onScroll = onScroll
        c.onMagnify = onMagnify
        c.onTextChanged = onTextChanged
    }
}
```

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapEditorHostTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 17 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. **A Debug pass is not evidence** — the Release type-check budget is stricter, and v0.8.0 shipped a Release-only failure this way.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/ScrapEditorHost.swift MaughamTests/Canvas/ScrapEditorHostTests.swift project.yml
git commit -m "feat(canvas): one bounds-scaled NSTextView mounted on the focused scrap

Focus is requested and claimed on viewDidMoveToWindow (makeNSView has no
window yet); mount rebinds on layout identity, not on textView == nil;
the container is the text view's delegate so every keystroke reaches the
model rather than living only in the shared NSTextStorage; and the pinch
anchor it forwards is named for the space it is actually in.

isEditorVisible is one switch over alphaValue AND hitTest, so the editor
can be mounted and first responder while the card is still straightening
without double-drawing its text or stealing the pointer. Never isHidden:
AppKit moves first responder off a hidden view, which loses the very
keystrokes mounting early exists to keep."
```

---

### Task 10: The composed canvas view

**Files:**
- Create: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasCompositionTests.swift`

**Interfaces:**
- **Consumes:** everything from Tasks 1–9.
- **Produces:** `struct CanvasView: View` — `let projectRoot: URL`, `let paletteSwatchHexes: () -> [String]`.

**Layer order is the defect this task exists to not have.** The ZStack is `CanvasGround` → `Canvas` → `CanvasEventView` → `ScrapEditorHost`, and the **editor is frontmost**. If the event view were in front it would eat click-to-place-caret, drag-select and double-click-word — the headline interaction — while every test still passed. Ground and `Canvas` opt out of hit testing so the event view reaches everything the editor does not cover. The editor container forwards `scrollWheel`/`magnify` back to the camera so panning and zooming still work with the pointer over the focused scrap.

**The editor mounts on the click; it becomes VISIBLE when the card is level. Those are two different things and this task keeps them apart.** Spec §7A.5 requirement 1 orders the handover — resolve the caret, **then** animate, **then** let the editor be the text — and §7A.5 licenses "a beat between click and caret". It does not license discarded keystrokes.

Two drafts each got one half of this wrong, in opposite directions:

- The first set `editingNodeID` and called `straighten.focus(_:)` in the same turn, and let the editor be the visible text from the very next body pass, at progress 0. For the whole ~120 ms axis-aligned glyphs sat at the *unrotated* text origin over chrome that was still up to 0.6° off level and closing, with the drawn text already suppressed — so the glyphs jumped straight the instant the writer clicked and the card caught up afterwards. That is the §7A.2 failure by §7A.5's own route.
- The second fixed the jump by deferring the **mount** to `isLevel`. But an editor that does not exist cannot be first responder: double-click empty canvas, start typing immediately, and the first character or two go nowhere at all.

So there are two properties, and the names have to make the difference unmissable because one name serving both meanings is what produced the first draft:

| property | means | gate |
|---|---|---|
| `mountedEditorNodeID` | the editor **exists** — in the hierarchy, first responder, taking keystrokes | `editingNodeID`, from the click |
| `visibleEditorNodeID` | the editor **is the visible text** | `editingNodeID` **and** `straighten.isLevel(id)` |

Through the straighten the editor exists and is invisible, and the renderer keeps drawing the card's text. That drawn text is *live*: `layouts[id]` wraps the same `NSTextStorage` the invisible editor is mutating, and `syncActiveEdit` already folds every keystroke back into `scraps` and bumps `revision`, so the words appear on the rotating card as they are typed. At `isLevel` the editor becomes visible and the renderer stops drawing that node's text — **both flip on `visibleEditorNodeID`, one property read once per body pass**, so there is never a frame with both and never a frame with neither. That is the whole correctness argument: the swap reveals nothing that was not already on screen, and no keystroke is lost.

No new machinery is needed: `straighten.focus(_:)` already unpauses the clock, so the reveal lands ~120 ms later on its own. `CanvasCompositionTests` pins it, because nothing else can observe it — the mount is a `@ViewBuilder` branch on private `@State`.

**Clicking from scrap A straight to scrap B while A is still settling back** is the case where all of this has to hold at once. `handleClick` calls `commitActiveEdit()` (A's text is folded into the model), then sets `editingNodeID = B` and `straighten.focus(B)`. `isLevel(A)` is false the same frame — `focus(_:)` moves `focusedNodeID` — and `isLevel(B)` is false because B has only just started, so `visibleEditorNodeID` is `nil` and **both** cards draw their own text. Exactly one node can ever be suppressed because the suppression is keyed on a single optional, not on a per-node predicate. And A's editor is not left invisible-but-mounted: `mountedEditorNodeID` is now B, the `if let` branch stays taken, so SwiftUI reuses the same `ScrapEditorHost` and `updateNSView` calls `mount(layout:)` with B's layout — which rebinds on layout identity (Task 9's defect 2) and tears A's text view out. Only leaving for empty canvas takes the branch away, and that is the path `dismantleNSView`/`unmount()` covers.

**The words are safe, and that is not the same as "there is a save path".** Typing mutates the `NSTextStorage` inside `ScrapLayout`; nothing else knows until this view is told. So there are three commit points, and all three are required:

- **while typing** — `onTextChanged` → `syncActiveEdit()`, every keystroke. This is also what makes the drawn card grow as the text wraps to a new line;
- **on `.onDisappear`** — sync, then flush;
- **immediately before the store writes** — `CanvasStore.beforeFlush`, which covers app quit without this view having to observe termination itself.

`syncActiveEdit()` pushes no undo step of its own. `commitActiveEdit()` is the *outer* undo boundary and is called when focus leaves a scrap; Task 15 gives it the gesture bracket, and also gives `syncActiveEdit` the *inner* boundaries — a sentence ending, or a beat of stillness — that keep a long visit from collapsing into a single ⌘Z. Neither is one step per keystroke.

**Two counters, and they are not interchangeable.** `layouts` holds `ScrapLayout` *objects*. Typing mutates the object in place, so SwiftUI sees no `@State` change and the `Canvas` never redraws. So:

- **`revision`** is the redraw counter. Read **in `body`** (not inside the draw closure — a `@State` read only registers a dependency during body evaluation) and bumped by every path that mutates a layout or the scene in place, **including every animation frame**. It ticks at 60–120 Hz whenever anything is moving.
- **`sceneRevision`** is the structural counter, bumped only when the *shape or content* of the scene changes: load, create, delete, undo, the end of a drag or resize, momentum coming to rest, and leaving a scrap. Task 14 keys the accessibility tree off this one. Keying it off `revision` instead rebuilds a scene-proportional list — a full sort plus a copy of every scrap's string — at frame rate for the whole of every drag, coast and straighten.

**The straighten clock lives here.** Spec §7A.5's focused card animates to level over ~120 ms, and `CanvasFocusStraighten` (Task 7) is stepped once per frame from a `TimelineView(.animation(paused:))`. Task 13 adds momentum to the *same* timeline and widens the pause condition; do not create a second one.

**No `GeometryReader`.** `Canvas`'s own `size` parameter already supplies the viewport the renderer culls against, and the `.position` calls that place the mounted editor resolve in the ZStack's space. A `GeometryReader` whose proxy nothing reads is a second layout pass for nothing.

**Interaction is deliberately incomplete here.** `onDrag` is wired to a stub with a one-line comment; Task 13 fills it in. `undoManager` is `nil`, and `lastKeystrokeAt` is written but never read; Task 15 fills in both. Do not invent any of the three.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasCompositionTests.swift`:

```swift
import XCTest
@testable import Maugham

/// There is no runtime hook that reports a SwiftUI ZStack's z-order, and the
/// failure it guards against — the event view eating click-to-place-caret — is
/// invisible to every other test in this plan while being the first thing a
/// writer hits. So it is pinned at the source, the way `TripwireGrepTests` pins
/// its rules.
final class CanvasCompositionTests: XCTestCase {

    private func canvasViewSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Maugham/Canvas/CanvasView.swift"), encoding: .utf8)
    }

    /// Comment lines are excluded, exactly as
    /// `CanvasRendererTests.test_noFileInTheCanvasAreaDerivesItsOwnRasterScale`
    /// does it. A doc comment that NAMES a modifier is documentation; only code
    /// counts. Without this the file's own layer-order comment is scanned as if
    /// it were source and the count is whatever the prose happens to say.
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Just the `body` property, so a search over the whole file cannot find a
    /// "mountedEditor" outside the ZStack and make the z-order assertion
    /// meaningless.
    private func bodySource(_ src: String) throws -> String {
        let start = try XCTUnwrap(src.range(of: "var body: some View"))
        let end = try XCTUnwrap(src.range(of: "private var mountedEditorNodeID"),
                                "the mount gate must be declared after `body`")
        return String(src[start.upperBound..<end.lowerBound])
    }

    /// One declaration, from its name to the next blank line. `codeOnly` has
    /// already dropped the doc comments, so what separates declarations is
    /// exactly the blank lines the author left between them.
    private func declarationSource(_ src: String, named name: String) throws -> String {
        let start = try XCTUnwrap(src.range(of: name), "\(name) is not declared")
        let rest = String(src[start.lowerBound...])
        let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
    }

    /// The whole `mountedEditor` property — `isEditorVisible:` is an ARGUMENT to
    /// `ScrapEditorHost`, so a slice that stops at `ScrapEditorHost(` cannot see
    /// it. `load()` is the declaration that follows.
    private func mountedEditorBuilder(_ src: String) throws -> String {
        let start = try XCTUnwrap(src.range(of: "private var mountedEditor: some View"))
        let end = try XCTUnwrap(src.range(of: "private func load()"),
                                "`load()` must follow `mountedEditor`")
        return String(src[start.upperBound..<end.lowerBound])
    }

    /// Two assertions, because either alone is fakeable: the ZStack must place
    /// `mountedEditor` after `CanvasEventView`, and `mountedEditor` must be the
    /// thing that builds a `ScrapEditorHost`.
    func test_theMountedEditorIsInFrontOfTheEventView() throws {
        let src = codeOnly(try canvasViewSource())
        let body = try bodySource(src)
        let event = try XCTUnwrap(body.range(of: "CanvasEventView("),
                                  "CanvasView no longer composes CanvasEventView")
        // The frontmost layer is the LAST thing in the ZStack, so `.backwards`
        // finds the composition slot even if a future edit adds another mention
        // of the name above the event view.
        let slot = try XCTUnwrap(body.range(of: "mountedEditor", options: .backwards),
                                 "CanvasView no longer composes mountedEditor")
        XCTAssertTrue(event.lowerBound < slot.lowerBound,
                      "the event view is in FRONT of the mounted editor, so it eats "
                      + "click-to-place-caret, drag-select and double-click-word — "
                      + "the writer sees 'typing does nothing'")

        // `mountedEditorNodeID` shares this prefix, so match the full signature.
        let declaration = try XCTUnwrap(src.range(of: "private var mountedEditor: some View"))
        let host = try XCTUnwrap(src.range(of: "ScrapEditorHost("),
                                 "CanvasView no longer composes ScrapEditorHost")
        XCTAssertTrue(declaration.lowerBound < host.lowerBound,
                      "the editor must be built inside `mountedEditor`, or the "
                      + "z-order assertion above is checking the wrong symbol")
    }

    func test_theGroundAndTheDrawnLayerDoNotHitTest() throws {
        let src = codeOnly(try canvasViewSource())
        let ground = try XCTUnwrap(src.range(of: "CanvasGround("))
        let canvas = try XCTUnwrap(src.range(of: "Canvas {"))
        let event = try XCTUnwrap(src.range(of: "CanvasEventView("))
        XCTAssertTrue(ground.lowerBound < canvas.lowerBound,
                      "the shader ground must be BENEATH the content (spec §7A.4)")
        XCTAssertTrue(canvas.lowerBound < event.lowerBound)
        let beforeEvents = String(src[src.startIndex..<event.lowerBound])
        XCTAssertEqual(
            beforeEvents.components(separatedBy: ".allowsHitTesting(false)").count - 1, 2,
            "both the ground and the drawn layer must opt out of hit testing, or "
            + "clicks never reach the event view")
    }

    /// The editor must EXIST from the click. §7A.5 licenses a late caret, not
    /// lost keystrokes: gate the mount itself on `isLevel` and the first
    /// character or two of a double-click-and-type reach no editor at all.
    /// No runtime test can see this — the mount is a @ViewBuilder branch on
    /// private @State.
    func test_theEditorMountsOnTheClickSoNoKeystrokeIsLost() throws {
        let src = codeOnly(try canvasViewSource())
        let gate = try declarationSource(src, named: "private var mountedEditorNodeID")
        XCTAssertTrue(gate.contains("editingNodeID"))
        XCTAssertFalse(gate.contains("isLevel"),
                       "the MOUNT is gated on the straighten, so the editor does "
                       + "not exist while the writer is typing into it — only "
                       + "visibleEditorNodeID may read isLevel")

        // The builder mounts off that property, not off the visibility one.
        let builder = try mountedEditorBuilder(src)
        XCTAssertTrue(builder.contains("if let id = mountedEditorNodeID"),
                      "the editor must be built off the MOUNT gate")
        XCTAssertFalse(builder.contains("if let id = visibleEditorNodeID"),
                       "mountedEditor is branching on visibility — the "
                       + "deferred-mount defect wearing the new names")
    }

    /// …and must be INVISIBLE until the card is level. Axis-aligned glyphs at
    /// the unrotated text origin over a card still up to 0.6° off level, with
    /// the drawn text already suppressed, snap straight the instant the writer
    /// clicks — the §7A.2 failure by the route §7A.5 exists to close.
    func test_theEditorIsInvisibleUntilTheCardIsLevel() throws {
        let src = codeOnly(try canvasViewSource())
        let gate = try declarationSource(src, named: "private var visibleEditorNodeID")
        XCTAssertTrue(gate.contains("straighten.isLevel("),
                      "the visibility gate must be its own named property, "
                      + "distinct from the mount gate, and it must read isLevel — "
                      + "otherwise the editor is visible at progress 0 and the "
                      + "text jumps straight")

        let builder = try mountedEditorBuilder(src)
        XCTAssertTrue(builder.contains("isEditorVisible: visibleEditorNodeID == id"),
                      "the editor's visibility must come from the same property "
                      + "the renderer is handed, or the two flip on different frames")
    }

    /// The correctness argument in one assertion: the renderer's text
    /// suppression and the editor's visibility read ONE property, so the swap
    /// reveals nothing that was not already on screen. Two spellings of the
    /// predicate is a frame with both drawing, or a frame with neither.
    func test_theRendererAndTheEditorSwapOnTheSamePredicate() throws {
        let src = codeOnly(try canvasViewSource())
        XCTAssertTrue(src.contains("visibleEditorNodeID: visibleEditorNodeID"),
                      "CanvasRenderer.draw must be handed the VISIBILITY id — "
                      + "passing the mount id suppresses the drawn text while an "
                      + "invisible editor draws nothing in its place")
        XCTAssertEqual(src.components(separatedBy: "straighten.isLevel(").count - 1, 1,
                       "there must be exactly one place the straighten is asked "
                       + "whether the card is level; a second is a second predicate")
    }

    /// I7. The editor forwards a point in its OWN unzoomed space; anchoring the
    /// pinch on it directly zooms about a point the writer never touched.
    func test_theFocusedEditorsPinchAnchorGoesThroughTheGeometryMapper() throws {
        let src = codeOnly(try canvasViewSource())
        XCTAssertTrue(src.contains("ScrapEditorGeometry.viewPoint"),
                      "onMagnify hands back an EDITOR-space point — it must be "
                      + "mapped into canvas space before it anchors a zoom")
    }

    func test_theCanvasIsNotHiddenFromAccessibility() throws {
        let src = try canvasViewSource()
        XCTAssertFalse(src.contains("accessibilityHidden(true)"))
        XCTAssertFalse(src.contains("accessibilityElement(children: .ignore)"),
                       "spec §7A.6: we own the canvas AX tree — ignoring children "
                       + "throws away the mounted editor with it")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasCompositionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — no `Maugham/Canvas/CanvasView.swift` to read.

- [ ] **Step 3: Write the composed view**

`Maugham/Canvas/CanvasView.swift`:

```swift
import AppKit
import SwiftUI

/// The Plan persona's centre column.
///
/// LAYER ORDER IS A HARD CONSTRAINT, not a preference:
///
///   1. `CanvasGround`      — shader, hit testing off
///   2. `Canvas`            — drawn nodes, hit testing off
///   3. `CanvasEventView`   — camera + pointer
///   4. `ScrapEditorHost`   — the one live editor, FRONTMOST
///
/// The ground is a SIBLING BENEATH the content because a shader applied *over*
/// a subtree holding an `NSViewRepresentable` renders a placeholder (spec §7A.4),
/// and this view has two of them. The editor is in FRONT of the event view
/// because that is the only way the writer gets AppKit's own click-to-place-caret,
/// drag-select and double-click-word; with the order reversed the event view
/// swallows all three and the surface reads as "typing does nothing".
/// `CanvasCompositionTests` pins both — and deliberately does NOT count the
/// modifier names written out in this comment, which is why they are described
/// here rather than spelled.
struct CanvasView: View {
    let projectRoot: URL
    /// Deferred on purpose: `ProjectStore.paletteSwatchHexes()` reads every
    /// palette card off disk, and evaluating that inside `ProjectWindow.body`
    /// would do file I/O per render. The canvas pulls it once, on appear.
    let paletteSwatchHexes: () -> [String]

    @State private var camera = CanvasCamera()
    @State private var scene = CanvasScene()
    @State private var scraps: [CanvasNodeID: String] = [:]
    @State private var layouts: [CanvasNodeID: ScrapLayout] = [:]
    @State private var editingNodeID: CanvasNodeID?
    @State private var caretIndex: Int?
    @State private var wash: [Color] = []
    @State private var store: CanvasStore?
    /// §7A.5: the focused card animates to level and settles back on blur.
    @State private var straighten = CanvasFocusStraighten()

    /// `layouts` holds ScrapLayout REFERENCES. Typing mutates the object in
    /// place, so `@State` observes no change and the `Canvas` never redraws.
    /// Every path that mutates a layout or the scene in place bumps this, and
    /// `body` READS it — a `@State` read only registers a dependency during body
    /// evaluation, so reading it inside the draw closure would do nothing.
    ///
    /// This is the REDRAW counter and it ticks once per animation frame. Nothing
    /// scene-proportional may key off it — see `sceneRevision`.
    @State private var revision = 0

    /// The STRUCTURAL counter: bumped only when the shape or content of the
    /// scene changes — load, create, delete, undo, the end of a drag or resize,
    /// momentum coming to rest, and leaving a scrap. Task 14's accessibility
    /// tree is rebuilt from this and never from `revision`, which every frame of
    /// every straighten, coast and drag increments.
    @State private var sceneRevision = 0

    /// When the writer last folded a keystroke into the model. A gap wider than
    /// `ScrapUndoBeat.idleSeconds` closes the open "Edit Scrap" gesture, so a
    /// long visit to a scrap is several ⌘Z steps rather than one. Cleared
    /// whenever focus moves. **Written in this task, read in Task 15** — like
    /// `undoManager: nil`, it is a placed seam rather than a forgotten one.
    @State private var lastKeystrokeAt: Date?

    private let scrapFont = NSFont(name: "Iowan Old Style", size: 13)
        ?? .systemFont(ofSize: 13)

    var body: some View {
        // Read here, not in the closure — see `revision`.
        let drawRevision = revision

        // No GeometryReader: `Canvas`'s own `size` is the viewport the renderer
        // culls against, and `.position` below resolves in this ZStack's space.
        ZStack {
            CanvasGround(camera: camera, wash: wash)
                .allowsHitTesting(false)

            // The clock §7A.5's straightening runs on. Paused the moment nothing
            // is animating, so an idle canvas costs nothing. Task 13 adds
            // momentum to THIS timeline — do not create a second one.
            TimelineView(.animation(paused: straighten.isSettled)) { context in
                Canvas { cx, size in
                    _ = drawRevision
                    CanvasRenderer.draw(scene: scene, camera: camera, viewSize: size,
                                        layouts: layouts,
                                        visibleEditorNodeID: visibleEditorNodeID,
                                        straighten: straighten, into: &cx)
                }
                .allowsHitTesting(false)
                .onChange(of: context.date) { previous, now in
                    straighten.step(elapsed: now.timeIntervalSince(previous))
                    revision += 1
                }
            }

            CanvasEventView(
                camera: $camera,
                onClick: { viewPoint, clickCount in
                    handleClick(at: camera.contentPoint(fromView: viewPoint),
                                clickCount: clickCount)
                },
                // Task 13 drives CanvasInteraction from this. Until then a drag
                // is a no-op, deliberately — not a forgotten stub.
                onDrag: { _, _ in },
                // Task 15 supplies the canvas undo manager.
                undoManager: nil)

            mountedEditor
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load() }
        .onDisappear {
            // Fold the live editor's text in BEFORE the write, or a persona
            // switch mid-sentence loses the sentence.
            syncActiveEdit()
            store?.flush()
        }
    }

    /// The node whose real editor EXISTS right now — in the hierarchy, first
    /// responder, taking keystrokes. That is from the instant the writer clicks,
    /// with no gate on the straighten.
    ///
    /// **This is deliberately not `visibleEditorNodeID`, and the two must not be
    /// merged back together.** Deferring the *mount* to `isLevel` was a real
    /// defect: for ~120 ms there was no editor to be first responder, so
    /// double-click empty canvas and type immediately and the first character or
    /// two reached nothing at all. §7A.5 says there is "a beat between click and
    /// caret" — a late caret is the accepted cost; discarded keystrokes are not.
    private var mountedEditorNodeID: CanvasNodeID? { editingNodeID }

    /// The node whose editor is the VISIBLE text right now — `nil` for the
    /// ~120 ms the clicked card spends straightening, and `nil` again the moment
    /// focus leaves.
    ///
    /// **The renderer's text suppression and the editor's own visibility both
    /// read THIS**, one property, once per body pass. So the drawn text cannot
    /// be blanked while nothing is drawing it in its place, and the editor
    /// cannot appear over a card that is still tilted: the two flip on the same
    /// frame and the swap reveals nothing that was not already on screen. Spec
    /// §7A.5 requirement 1 is an ordering — caret, then animate, then hand the
    /// text over — and this property is the "then". `straighten.focus(_:)` has
    /// already unpaused the clock, so it arrives on its own about a tenth of a
    /// second later; there is no timer and no completion callback.
    ///
    /// Through that window the card keeps drawing its own text, and it is LIVE
    /// text: `layouts[id]` wraps the same `NSTextStorage` the invisible editor is
    /// mutating, and `syncActiveEdit` bumps `revision` on every keystroke, so the
    /// words appear on the rotating card as they are typed.
    ///
    /// Making the editor visible from the click was the first draft's defect:
    /// axis-aligned glyphs at the unrotated text origin over chrome that was
    /// still up to 0.6° off level, so they snapped straight on the click and the
    /// card caught up behind them — spec §7A.2's failure by §7A.5's own route.
    private var visibleEditorNodeID: CanvasNodeID? {
        guard let id = editingNodeID, straighten.isLevel(id) else { return nil }
        return id
    }

    /// Frontmost, from the click. Invisible — and transparent to the pointer —
    /// until the card it sits on is level.
    @ViewBuilder
    private var mountedEditor: some View {
        if let id = mountedEditorNodeID,
           let node = scene.node(id),
           case .scrap = node.kind,
           let layout = layouts[id],
           let frame = node.frame {
            let textSize = CanvasCardMetrics.textSize(inCard: frame)
            let textOrigin = CanvasCardMetrics.textOrigin(inCard: frame)
            let viewOrigin = camera.viewPoint(fromContent: textOrigin)
            ScrapEditorHost(layout: layout,
                            unscaledSize: textSize,
                            zoom: camera.zoom,
                            caretIndex: caretIndex,
                            // The same property the renderer is handed above, so
                            // the editor appearing and the card ceasing to draw
                            // its text are one event, not two.
                            isEditorVisible: visibleEditorNodeID == id,
                            undoManager: nil,          // Task 15
                            onScroll: { dx, dy, precise in
                                let factor: CGFloat = precise ? 1 : 8
                                camera.panBy(CGSize(width: dx * factor, height: dy * factor))
                            },
                            onMagnify: { magnification, editorPoint in
                                // The container hands back a point in the
                                // EDITOR's own unzoomed space. Anchoring the
                                // zoom on it directly would zoom about a point
                                // the writer never touched.
                                let anchor = ScrapEditorGeometry.viewPoint(
                                    fromEditorPoint: editorPoint,
                                    textOrigin: textOrigin,
                                    camera: camera)
                                camera.zoom(to: camera.zoom * (1 + magnification),
                                            anchoringViewPoint: anchor)
                            },
                            onTextChanged: { syncActiveEdit() })
                .frame(width: textSize.width * camera.zoom,
                       height: textSize.height * camera.zoom)
                .position(x: viewOrigin.x + textSize.width * camera.zoom / 2,
                          y: viewOrigin.y + textSize.height * camera.zoom / 2)
        }
    }

    // MARK: - Loading and measuring

    private func load() {
        let s = CanvasStore(projectRoot: projectRoot)
        // The store's own quit hook writes whatever was last queued; this makes
        // sure what was last queued includes the sentence the writer is halfway
        // through. `.onDisappear` does not fire on ⌘Q.
        s.beforeFlush = { syncActiveEdit() }
        store = s
        let loaded = s.load()
        scene = loaded.scene
        scraps = loaded.scraps
        wash = CanvasGroundPalette.wash(fromHex: paletteSwatchHexes())
        rebuildLayouts()
    }

    /// Build a layout per scrap and fill in the derived heights the model needs
    /// for hit testing and culling.
    ///
    /// Called from `load`, and again from every path that can leave a node
    /// unmeasured: creating a scrap, finishing a resize, committing an edit. A
    /// node with no `cachedHeight` has no `frame`, so it is invisible to both
    /// hit testing and culling — it is on the canvas and cannot be clicked.
    private func rebuildLayouts() {
        for node in scene.nodes {
            guard case .scrap = node.kind else { continue }
            let existing = layouts[node.id]
            let text = scraps[node.id] ?? ""
            let layout: ScrapLayout
            if let existing, existing.text == text {
                existing.setWidth(CanvasCardMetrics.textWidth(forCardWidth: node.width))
                layout = existing
            } else {
                layout = ScrapLayout(
                    text: text,
                    width: CanvasCardMetrics.textWidth(forCardWidth: node.width),
                    font: scrapFont)
                layouts[node.id] = layout
            }
            scene.setCachedHeight(
                CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight),
                for: node.id)
        }
        // Layouts for nodes that no longer exist would keep their text alive.
        layouts = layouts.filter { scene.node($0.key) != nil }
        revision += 1
        // Every caller of this — load, create, resize-end, undo — has changed the
        // shape of the scene, so the accessibility tree is stale.
        sceneRevision += 1
    }

    // MARK: - The writer's words

    /// Fold the live editor's text back into the model and re-measure the card.
    ///
    /// **Called on EVERY keystroke** (`ScrapEditorHost.onTextChanged`), from
    /// `.onDisappear`, and from `CanvasStore.beforeFlush`. Typing mutates the
    /// `NSTextStorage` inside `ScrapLayout` in place; until this runs, `scraps`
    /// still holds the text as it was before the writer typed, the queued save
    /// payload is stale, and the drawn card never grows past the height it had
    /// when it was last measured. Quit at that moment and the scrap comes back
    /// empty — the words are safe is the one promise this surface cannot break.
    ///
    /// Pushes no undo step of its OWN, deliberately — one per keystroke is the
    /// other failure. Task 15 gives it a `fromKeystroke:` flag and, behind that
    /// flag, the two inner undo boundaries: a beat of stillness or a finished
    /// sentence closes the open gesture and opens the next (`ScrapUndoBeat`). The
    /// flag exists because the other two callers below run at teardown and at
    /// app quit, where moving an undo boundary would leave a half-open bracket.
    /// In Task 10 the body is the six lines below and there is no flag yet.
    private func syncActiveEdit() {
        guard let id = editingNodeID, let layout = layouts[id] else { return }
        guard scraps[id] != layout.text else { return }
        scraps[id] = layout.text
        scene.setCachedHeight(
            CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight), for: id)
        revision += 1
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    /// The outer undo boundary: focus is leaving the scrap. Task 15 closes the
    /// "Edit Scrap" gesture here; until then it is the same work as
    /// `syncActiveEdit`, plus the accessibility tree, whose synthetic element for
    /// this scrap has been stale for the whole visit — deliberately, because the
    /// real `NSTextView` was the accessible thing while the writer was in it.
    private func commitActiveEdit() {
        syncActiveEdit()
        lastKeystrokeAt = nil
        sceneRevision += 1
    }

    // MARK: - Clicks

    /// Single click: leave whatever was being edited. Double click: enter the
    /// scrap under the pointer (Task 13 adds "or make one here").
    ///
    /// The single/double split is the standard canvas idiom, and it is what lets
    /// a single click start a DRAG while the editor is unmounted — with the
    /// editor frontmost, a focused scrap owns its own mouse.
    private func handleClick(at contentPoint: CGPoint, clickCount: Int) {
        commitActiveEdit()

        guard clickCount >= 2,
              let node = scene.topmostNode(at: contentPoint),
              case .scrap = node.kind,
              let layout = layouts[node.id],
              let frame = node.frame else {
            editingNodeID = nil
            caretIndex = nil
            straighten.focus(nil)
            store?.scheduleSave(scene: scene, scraps: scraps)
            return
        }

        // §7A.5 requirement 1: resolve the caret in the card's LOCAL, UNROTATED
        // space at CLICK TIME — before the card straightens. Straightening first
        // moves the click point out from under the cursor, and the caret lands
        // somewhere the writer did not aim.
        let angle = CanvasRenderer.drawnAngle(for: node.id, straighten: straighten)
        let local = CanvasRenderer.localPoint(contentPoint, inCard: frame, angle: angle)
        let textOrigin = CanvasCardMetrics.textOrigin(inCard: frame)
        caretIndex = layout.characterIndex(
            at: CGPoint(x: local.x - textOrigin.x, y: local.y - textOrigin.y))

        editingNodeID = node.id
        lastKeystrokeAt = nil
        // The editor mounts on this line's body pass and takes keystrokes at
        // once; what it does not do yet is SHOW. `visibleEditorNodeID` withholds
        // that until `straighten.isLevel(_:)`, about a tenth of a second from
        // here, and until then the drawn text stays visible, keeps rotating, and
        // grows as the writer types into the editor nobody can see. Spec §7A.5
        // calls that beat responsiveness rather than lag.
        straighten.focus(node.id)
        store?.scheduleSave(scene: scene, scraps: scraps)
    }
}
```

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasCompositionTests -only-testing MaughamTests/ScrapEditorHostTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 7 + 17 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. **A Debug pass is not evidence** — the Release type-check budget is stricter, and v0.8.0 shipped a Release-only failure this way.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasView.swift MaughamTests/Canvas/CanvasCompositionTests.swift project.yml
git commit -m "feat(canvas): the composed canvas surface

Editor frontmost so AppKit supplies caret placement and word selection;
the ground is a sibling beneath, never an overlay. Every keystroke is
folded into the model on the spot and again before any write, so a quit
mid-sentence keeps the sentence. The focused card straightens to level
over ~120ms on the same timeline the momentum coast will use (7A.5); the
caret is resolved in the card's unrotated space before it animates. The
editor MOUNTS on the click, so nothing typed into a brand-new scrap is
lost, and only its VISIBILITY waits for level — visibleEditorNodeID feeds
both that and the renderer's text suppression, so the card's own text
stays on screen and rotating, updating as you type, right up to the one
frame the editor takes over."
```

---

### Task 11: The `canvas` binder segment and the switches it forces

This task makes the segment **exist and be routed everywhere**. Task 12 makes Plan *offer* it. Splitting there is deliberate: adding the case forces seven exhaustive switches at once and the tree does not compile until all seven are handled, so they belong together; changing Plan's segment list breaks two long-standing assertions in an existing test file and belongs on its own.

**Files:**
- Modify: `Maugham/Models/BinderSegment.swift` (add `case canvas`; conform to `CaseIterable`)
- Modify: `Maugham/Views/ProjectWindow.swift` (the `switch binderSegment` inside `existingEditorSwitch` at line 850, the one inside `existingInspectorSwitch` at line 1019, and `shouldShowStatusFooter`'s guard at line 789)
- Modify: `Maugham/Views/BinderPaneToggle.swift` (the `switch segment` at **line 28**)
- Modify: `Maugham/Views/CollectionBinderPaneToggle.swift` (the `switch segment` at **line 36**)
- Modify: `Maugham/Stores/ProjectStore+Palette.swift` (add `paletteSwatchHexes()`)
- Modify: `MaughamTests/PersonaBinderSegmentTests.swift` (two hardcoded arrays become `allCases`)
- Modify: `MaughamTests/PersonaMemoryTests.swift` (two hardcoded arrays become `allCases`)
- Test: `MaughamTests/Canvas/CanvasSegmentTests.swift`

**Interfaces:**
- **Consumes:** `CanvasView(projectRoot:paletteSwatchHexes:)` (Task 10); `CanvasGroundPalette` (Task 8).
- **Produces:**
  - `BinderSegment.canvas`, and `BinderSegment: CaseIterable`.
  - `ProjectStore.paletteSwatchHexes() -> [String]`.

**No new top-level modifier.** `ProjectWindow.existingEditorSwitch` already routes the centre column on `binderSegment`, so adding `case canvas` puts the canvas there. Adding the case makes the compiler enumerate every exhaustive switch over `BinderSegment` — that is the mechanism, and it is why the seven sites are one task rather than a hunt.

**The seven exhaustive switches, named.** Do not go looking; these are all of them, verified against the tree on 2026-07-25:

| Site | File:line | What `.canvas` returns |
|---|---|---|
| `BinderSegment.isTransient` | `Maugham/Models/BinderSegment.swift` | `false` — a persona surface, not a runtime state |
| `BinderSegment.displayName(for:)` | `Maugham/Models/BinderSegment.swift` | `"Canvas"`, every project type |
| `BinderSegment.pickerSymbolName` | `Maugham/Models/BinderSegment.swift` | `"square.on.circle"` — must be distinct from the six existing symbols |
| `ProjectWindow.existingEditorSwitch` | `Maugham/Views/ProjectWindow.swift:850` (the `switch`; the `func` is at 847) | `CanvasView` |
| `ProjectWindow.existingInspectorSwitch` | `Maugham/Views/ProjectWindow.swift:1019` (the `switch`; the `func` is at 1018) | a full-frame `ContentUnavailableView` |
| `BinderPaneToggle` left column | `Maugham/Views/BinderPaneToggle.swift:28` | `ResearchView` |
| `CollectionBinderPaneToggle` left column | `Maugham/Views/CollectionBinderPaneToggle.swift:36` | `CollectionResearchPane` |

**What the binder shows under the canvas segment: the research tree.** Spec §10 left this open and now records the answer. Umbrella §6.3 gives Plan a Left surface of "Research tree", and spec §8A.1 *depends* on it — dragging a research item onto the canvas (1C-d) requires the tree to be beside it. So `.canvas` and `.research` render the same left pane; the picker distinguishes them and the centre column is what actually differs. That is deliberate, not an oversight, and the arms carry a comment saying so.

**No persona offers `.canvas` yet, so nothing in `PersonaBinderSegmentTests` changes value.** That is Task 12's job. The segment is reachable by the compiler and by `UIState`, but not yet by a writer.

**Four hardcoded `[BinderSegment]` arrays would silently under-test the new case.** Rather than adding `.canvas` to each and leaving the drift class open, make `BinderSegment: CaseIterable` and replace all four with `BinderSegment.allCases`. They are **not** four of a kind, and two of them assert things this task is directly responsible for getting right — know which is which before you run them:

| Site | Test | What it starts asserting about `.canvas` |
|---|---|---|
| `PersonaBinderSegmentTests.swift:122` | `test_everySegmentHasADistinctPickerSymbol` | `pickerSymbolName` is non-empty **and distinct from all six existing symbols**. If `"square.on.circle"` collides, this is the test that says so. |
| `PersonaBinderSegmentTests.swift:132` | `test_everySegmentHasANonEmptyDisplayNameForEveryProjectType` | `displayName(for:)` is non-empty for **every** `ProjectType`, not just novel and collection. |
| `PersonaMemoryTests.swift:74` | `test_recordThenRestore_honoursOfferedAndTransientForEverySegment` | A generic record/restore loop reading `isTransient` off the enum. |
| `PersonaMemoryTests.swift:132` | `test_restore_alwaysYieldsAnOfferedSegment` | A generic loop over candidate segments and each persona's offered list. |

All four strengthen rather than break, so the step is safe — but the first two are the ones that can actually go red here, and they go red for a real reason. Run them and read the failure; do not assume.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasSegmentTests.swift`:

```swift
import XCTest
@testable import Maugham
import MaughamCore

final class CanvasSegmentTests: XCTestCase {

    /// The picker renders uniform `Image` children only. A segment with no
    /// symbol is smoke defect C (2026-07-25) waiting to happen again.
    func test_canvasHasAPickerSymbolAndADisplayName() {
        XCTAssertFalse(BinderSegment.canvas.pickerSymbolName.isEmpty)
        XCTAssertEqual(BinderSegment.canvas.displayName(for: .novel), "Canvas")
        XCTAssertEqual(BinderSegment.canvas.displayName(for: .collection), "Canvas")
    }

    /// `CaseIterable` exists so the four hardcoded segment arrays in the persona
    /// tests can never again miss a new case.
    func test_allCasesCoversEverySegmentAndSymbolsStayDistinct() {
        XCTAssertEqual(BinderSegment.allCases.count, 7)
        XCTAssertTrue(BinderSegment.allCases.contains(.canvas))
        let symbols = BinderSegment.allCases.map(\.pickerSymbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count,
                       "an icon-only picker cannot show two segments the same glyph")
    }

    /// The canvas is a persona surface, not a transient state — it must not be
    /// carried across a persona switch the way Find and Trash are.
    func test_canvasIsNotTransient() {
        XCTAssertFalse(BinderSegment.canvas.isTransient)
    }

    func test_canvasSurvivesAUIStateRoundTrip() throws {
        var state = UIState.empty
        state.binderSegment = .canvas
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(back.binderSegment, .canvas)
    }

    /// Spec §10's answer: the binder shows the research tree under the canvas
    /// segment, because §8A.1's drag-in route (1C-d) needs the tree beside the
    /// canvas. Pinned at the source because a SwiftUI switch arm has no runtime
    /// handle — the same technique `CanvasCompositionTests` uses.
    func test_bothBinderTogglesRouteTheCanvasSegmentToTheResearchTree() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root

        let novel = try String(contentsOf: repoRoot
            .appendingPathComponent("Maugham/Views/BinderPaneToggle.swift"), encoding: .utf8)
        XCTAssertTrue(novel.contains("case .research, .canvas:"),
                      "BinderPaneToggle must render ResearchView for .canvas")

        let collection = try String(contentsOf: repoRoot
            .appendingPathComponent("Maugham/Views/CollectionBinderPaneToggle.swift"),
                                    encoding: .utf8)
        XCTAssertTrue(collection.contains("case .research, .canvas:"),
                      "CollectionBinderPaneToggle must render CollectionResearchPane for .canvas")
    }

    /// The seam between the store and the ground: the store vends hex strings
    /// and `CanvasGroundPalette` is the one parser. (`ProjectStore` itself is
    /// exercised end to end elsewhere; this pins the shape of what it hands over.)
    func test_theGroundAcceptsTheHexesTheStoreVends() throws {
        let hexes: [String] = CanvasGroundPalette.validHexes(["#8A6F4D", "#2F3B4C"])
        XCTAssertEqual(hexes, ["#8A6F4D", "#2F3B4C"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasSegmentTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `type 'BinderSegment' has no member 'canvas'`.

- [ ] **Step 3: Add the case and fill in the three `BinderSegment` switches**

In `Maugham/Models/BinderSegment.swift`, add `CaseIterable` to the conformance list and the case:

```swift
public enum BinderSegment: String, Codable, Equatable, Sendable, CaseIterable {
    case manuscript
    case research
    case palette
    case scenes
    /// The Plan persona's centre column — the freeform planning canvas (M1C).
    /// One canvas per project (spec §2); regions do all the dividing.
    case canvas
    case trash
    case find
```

`CaseIterable` is not decoration: two test files held four hardcoded `[BinderSegment]` arrays that would each have silently skipped the new case. Step 5 replaces them.

`isTransient` — `.canvas` joins the non-transient list:
```swift
        case .manuscript, .research, .palette, .scenes, .canvas: return false
```

`displayName(for:)`:
```swift
        case .canvas: return "Canvas"
```

`pickerSymbolName` — every segment must return a symbol, or the picker's uniform-`Image` `ForEach` breaks (smoke defect C):
```swift
        case .canvas: return "square.on.circle"
```

Then build and confirm the compiler names exactly the four remaining sites and nothing else:

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -B2 -A4 "must be exhaustive"
```
Expected: `ProjectWindow.existingEditorSwitch`, `ProjectWindow.existingInspectorSwitch`, `BinderPaneToggle`, `CollectionBinderPaneToggle`. If a fifth appears, stop and report it — the table above claims to be complete.

- [ ] **Step 4: Route the four view switches**

`ProjectWindow.existingEditorSwitch` — note `store.url`, which is what `ProjectStore` actually exposes (`Maugham/Stores/ProjectStore.swift:68`, `public let url: URL`). There is no `rootURL`:

```swift
        case .canvas:
            CanvasView(projectRoot: store.url,
                       paletteSwatchHexes: { store.paletteSwatchHexes() })
```

`ProjectWindow.existingInspectorSwitch` — the full-frame chain is tripwire 15, which has recurred four or more times:

```swift
        case .canvas:
            ContentUnavailableView("Canvas", systemImage: "square.on.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
```

`Maugham/Views/BinderPaneToggle.swift:28` — fold `.canvas` into the existing `.research` arm:

```swift
                case .research, .canvas:
                    // Spec §10: the canvas segment shows the RESEARCH TREE.
                    // Umbrella §6.3 gives Plan a Left surface of "Research
                    // tree", and §8A.1's drag-in route (1C-d) needs the tree
                    // beside the canvas to drag from. The two segments share a
                    // left pane on purpose; the centre column is what differs.
                    ResearchView(store: store, selectedResearchId: $selectedResearchId)
```

`Maugham/Views/CollectionBinderPaneToggle.swift:36` — the same decision, the collection pane:

```swift
                case .research, .canvas:
                    // Spec §10 — see BinderPaneToggle for the reasoning.
                    CollectionResearchPane(
                        store: store,
                        selectedResearchId: $selectedResearchId,
                        activePiece: activePiece,
                        onAddSharedNote: onAddSharedNote,
                        onAddPieceNote: onAddPieceNote)
```

Neither toggle's Exports footer needs touching: both are `==` comparisons against `.manuscript`/`.scenes`, and the canvas is correctly excluded.

Add `paletteSwatchHexes()` to `Maugham/Stores/ProjectStore+Palette.swift`, beside the other palette accessors — the canvas must not learn the palette's storage shape:

```swift
    /// Every palette card's swatches, flattened in card order then swatch
    /// order. The canvas ground washes itself 3–5% with these (spec §7.1).
    ///
    /// A FUNCTION, not a computed property: `loadPaletteCards()` reads every
    /// card off disk, and a property would invite a call from inside
    /// `ProjectWindow.body`. `CanvasView` calls it once, on appear.
    public func paletteSwatchHexes() -> [String] {
        loadPaletteCards().flatMap(\.swatches)
    }
```

- [ ] **Step 5: Replace the four hardcoded segment arrays**

```swift
// PersonaBinderSegmentTests.swift:122  (test_everySegmentHasADistinctPickerSymbol)
        let all = BinderSegment.allCases
// PersonaBinderSegmentTests.swift:132  (test_everySegmentHasANonEmptyDisplayNameForEveryProjectType)
        let all = BinderSegment.allCases
// PersonaMemoryTests.swift:74          (test_recordThenRestore_honoursOfferedAndTransientForEverySegment)
        let all = BinderSegment.allCases
// PersonaMemoryTests.swift:132         (test_restore_alwaysYieldsAnOfferedSegment)
        let allBinder = BinderSegment.allCases
```

Note that the first two both use `Set(symbols).count == all.count` / a non-empty `displayName(for:)` across **every** `ProjectType` — see the table above. If either goes red, the fault is in Step 3's two `BinderSegment` properties, not in the substitution.

- [ ] **Step 6: Check the footer guard the compiler cannot see**

`ProjectWindow.swift:789` — inside `shouldShowStatusFooter`, which is declared at 787 — reads:

```swift
        guard binderSegment == .manuscript || binderSegment == .scenes else {
```

This is an `==` comparison, so adding the case does **not** flag it. The behaviour is already correct — the word-count footer should not show on the canvas — so leave it. Add a comment so the next reader knows it was considered rather than missed:

```swift
        // `.canvas` is deliberately absent: the footer reports manuscript
        // metrics, and readiness stays silent about the canvas (umbrella §7, §9).
        guard binderSegment == .manuscript || binderSegment == .scenes else {
```

- [ ] **Step 7: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasSegmentTests -only-testing MaughamTests/PersonaBinderSegmentTests -only-testing MaughamTests/PersonaMemoryTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 6 tests in `CanvasSegmentTests`. The two persona suites must be **unchanged in outcome** — no persona offers `.canvas` yet, so if either goes red the case leaked into a persona list ahead of Task 12.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Models/BinderSegment.swift \
        Maugham/Views/ProjectWindow.swift Maugham/Views/BinderPaneToggle.swift \
        Maugham/Views/CollectionBinderPaneToggle.swift \
        Maugham/Stores/ProjectStore+Palette.swift \
        MaughamTests/Canvas/CanvasSegmentTests.swift \
        MaughamTests/PersonaBinderSegmentTests.swift MaughamTests/PersonaMemoryTests.swift
git commit -m "feat(canvas): BinderSegment.canvas, routed through all seven switches

No new top-level modifier — existingEditorSwitch already routes the
centre column on binderSegment. Resolves spec 10's open question about
the left column: both binder toggles show the research tree under the
canvas segment, which is what 8A.1's drag-in route will need.
BinderSegment gains CaseIterable so the four hardcoded segment arrays in
the persona tests cannot miss a case again. No persona offers the segment
yet; that is Task 12."
```

---

### Task 12: Plan leads with the canvas

**Files:**
- Modify: `Maugham/Models/Persona.swift` (Plan's `binderSegments(for:)` and the doc comment above it)
- Modify: `MaughamTests/PersonaBinderSegmentTests.swift` (**two assertions change**)
- Test: `MaughamTests/Canvas/CanvasPersonaTests.swift`

**Interfaces:**
- **Consumes:** `BinderSegment.canvas` (Task 11).
- **Produces:** `Persona.plan.binderSegments(for:) == [.canvas, .research, .palette]` for every project type, so `Persona.plan.binderHome(for:) == .canvas`.

**Two existing assertions break and are fixed here**, not left for the full-suite run to discover:

- `MaughamTests/PersonaBinderSegmentTests.swift:6-8` — `test_planPersona_leadsWithResearch` asserts `Persona.plan.binderHome(for: .novel) == .research`.
- `MaughamTests/PersonaBinderSegmentTests.swift:53-57` — `test_planPersona_exactSegments` asserts `Persona.plan.binderSegments(for: .novel) == [.research, .palette]`.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasPersonaTests.swift`:

```swift
import XCTest
@testable import Maugham
import MaughamCore

final class CanvasPersonaTests: XCTestCase {

    func test_planOffersTheCanvasFirstOnEveryProjectType() {
        for type in [ProjectType.novel, .screenplay, .collection] {
            let segments = Persona.plan.binderSegments(for: type)
            XCTAssertEqual(segments.first, .canvas,
                           "Plan's centre column is the canvas (umbrella §6.3) — \(type)")
            XCTAssertEqual(Persona.plan.binderHome(for: type), .canvas)
        }
    }

    func test_planStillOffersResearchAndPalette() {
        let segments = Persona.plan.binderSegments(for: .novel)
        XCTAssertTrue(segments.contains(.research))
        XCTAssertTrue(segments.contains(.palette))
    }

    func test_noOtherPersonaOffersTheCanvas() {
        for persona in [Persona.author, .review, .publish] {
            for type in [ProjectType.novel, .screenplay, .collection] {
                XCTAssertFalse(persona.binderSegments(for: type).contains(.canvas),
                               "\(persona) must not offer the canvas")
            }
        }
    }

    func test_switchingAwayFromPlanLeavesTheCanvas() {
        // Author does not offer .canvas, so a coerced segment must land on
        // Author's own home rather than stranding the writer on a blank column.
        let author = Persona.author.binderSegments(for: .novel)
        XCTAssertFalse(author.contains(.canvas))
        XCTAssertEqual(Persona.author.binderHome(for: .novel), .manuscript)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasPersonaTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — Plan's first segment is `.research`.

- [ ] **Step 3: Put the canvas in Plan's list**

In `Maugham/Models/Persona.swift`, replace Plan's `case .plan:` arm in `binderSegments(for:)`:

```swift
        case .plan:
            // §6.3 gives Plan a canvas centre column, so the canvas leads and is
            // therefore `binderHome` — entering Plan lands on it. Research and
            // Palette follow: Research is §6.3's Left surface, and the binder is
            // where a palette card is picked.
            //
            // The manuscript segment stays deliberately ABSENT, for the reason
            // recorded before the canvas existed: the coercion rule keeps any
            // segment the destination offers, so including it would let a writer
            // entering Plan from the manuscript simply stay on it and never see
            // the planning surfaces at all. Not a gate — a forced navigation
            // still selects the manuscript segment and `visibleSegments`
            // renders it, and ⌘2 is one keystroke away.
            return [.canvas, .research, .palette]
```

Update the doc comment above `binderSegments(for:)`: the sentence reading

> Two of those four surfaces do not exist yet (M1C builds the canvas, M1D the editions list)

becomes

> One of those four surfaces does not exist yet (M1D builds the editions list).

- [ ] **Step 4: Update the two assertions this task breaks**

`MaughamTests/PersonaBinderSegmentTests.swift`:

```swift
    func test_planPersona_leadsWithTheCanvas() {
        // M1C: Plan's centre column is the freeform planning canvas, so the
        // canvas leads its segment list and is therefore its binderHome.
        XCTAssertEqual(Persona.plan.binderHome(for: .novel), .canvas)
    }
```

```swift
    func test_planPersona_exactSegments() {
        // §6.3 Left = "Research tree" and centre = the canvas (M1C). The canvas
        // leads because entering Plan should land on it; Research follows as
        // §6.3's Left surface and as the source 1C-d drags items from.
        // Manuscript is deliberately absent so the coercion rule can't strand a
        // writer on it (see Persona.swift).
        XCTAssertEqual(Persona.plan.binderSegments(for: .novel), [.canvas, .research, .palette])
    }
```

- [ ] **Step 5: Run both full suites and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: the whole Mac suite green, including `CanvasPersonaTests` (4 tests) and the updated `PersonaBinderSegmentTests` and `PersonaMemoryTests`. Integration failures only surface in the FULL suite — the edition-identity milestone learned this the expensive way; do not call this task done off a filtered run.

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: green — this confirms nothing leaked into MaughamCore, since M1C is Mac-only by design.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Models/Persona.swift \
        MaughamTests/Canvas/CanvasPersonaTests.swift \
        MaughamTests/PersonaBinderSegmentTests.swift
git commit -m "feat(canvas): Plan's centre column is the canvas

The canvas leads Plan's segment list and is therefore Plan's binderHome,
so entering Plan lands on it. No other persona offers it."
```

---

### Task 13: Create, move, resize — and momentum

**Files:**
- Create: `Maugham/Canvas/CanvasInteraction.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasInteractionTests.swift`
- Test: `MaughamTests/Canvas/CanvasMomentumTests.swift`

**The peer file is not optional.** An earlier draft said "add to `CanvasView.swift`, or a peer file if the view file is growing". Plans 1C-b and 1C-c both list `Maugham/Canvas/CanvasInteraction.swift` as existing. It is a peer file.

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNode`, `CanvasNodeID`, `CanvasCardMetrics` (Task 1); `CanvasRenderer.resizeHandleSize` (Task 7); `CanvasDragPhase` (Task 6).
- **Produces:**
  - `struct CanvasInteraction` — `static let minimumScrapWidth: CGFloat`, `static let defaultScrapWidth: CGFloat`, `var isActive: Bool`, `var activeNodeID: CanvasNodeID?`, `var isResizing: Bool`, `mutating func begin(at: CGPoint, in: CanvasScene)`, `mutating func beginResize(_: CanvasNodeID, at: CGPoint, in: CanvasScene)`, `mutating func update(to: CGPoint, in: inout CanvasScene)`, `@discardableResult mutating func end() -> (id: CanvasNodeID, velocity: CGSize)?`, `static func createScrap(at: CGPoint, in: inout CanvasScene) -> CanvasNodeID`.
  - `struct CanvasMomentum: Equatable` — `static let decayPerFrame: CGFloat`, `static let restSpeed: CGFloat`, `static let maximumLaunchSpeed: CGFloat`, `private(set) var nodeID: CanvasNodeID?`, `private(set) var velocity: CGSize`, `var isAtRest: Bool`, `mutating func launch(_: CanvasNodeID, velocity: CGSize)`, `mutating func stop()`, `@discardableResult mutating func step(_ scene: inout CanvasScene) -> Bool`.

**Momentum, built rather than described.** §7.3 says cards carry momentum and come to rest rather than snapping, and calls it "where tools actually acquire feel". The mechanism is a **velocity term plus an explicit per-frame decay the renderer reads** — not `withAnimation`. `withAnimation` interpolates `Animatable` values through the SwiftUI view graph; a plain model value read inside a `Canvas` draw closure is not in that graph and would simply jump to its final value.

**Task 10 already built the clock** — the `TimelineView(.animation(paused:))` §7A.5's straightening runs on. This task **widens its pause condition and steps a second model in the same tick**. Do not add a second `TimelineView`: two animation timelines over one `Canvas` is two redraw sources fighting for the same frame.

- [ ] **Step 1: Write the failing tests**

`MaughamTests/Canvas/CanvasInteractionTests.swift`:

```swift
import XCTest
@testable import Maugham

final class CanvasInteractionTests: XCTestCase {

    private func sceneWithOneScrap() -> CanvasScene {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("s1"), kind: .scrap,
                           origin: CGPoint(x: 100, y: 100), width: 240)
        n.cachedHeight = 80
        s.insert(n)
        return s
    }

    func test_dragMovesTheNodeByTheDragDelta() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
        i.update(to: CGPoint(x: 160, y: 130), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.origin, CGPoint(x: 150, y: 120))
    }

    func test_dragOnEmptySpaceMovesNothing() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 900, y: 900), in: scene)
        XCTAssertFalse(i.isActive)
        i.update(to: CGPoint(x: 950, y: 950), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.origin, CGPoint(x: 100, y: 100))
    }

    func test_dragPreservesWidthAndDoesNotReMeasure() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
        i.update(to: CGPoint(x: 400, y: 400), in: &scene)
        let n = scene.node(CanvasNodeID("s1"))
        XCTAssertEqual(n?.width, 240)
        XCTAssertEqual(n?.cachedHeight, 80, "moving a scrap must not re-measure it")
    }

    /// §7A.3: width is authoritative; resizing rewraps and the height is derived.
    func test_resizeChangesWidthAndClearsTheCachedHeight() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID("s1"), at: CGPoint(x: 340, y: 140), in: scene)
        i.update(to: CGPoint(x: 400, y: 140), in: &scene)
        let n = scene.node(CanvasNodeID("s1"))
        XCTAssertEqual(n?.width, 300)
        XCTAssertNil(n?.cachedHeight, "a rewrapped scrap must be re-measured before it is hit-tested")
    }

    func test_resizeIsClampedToAWorkableMinimum() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID("s1"), at: CGPoint(x: 340, y: 140), in: scene)
        i.update(to: CGPoint(x: 0, y: 140), in: &scene)
        XCTAssertGreaterThanOrEqual(scene.node(CanvasNodeID("s1"))!.width,
                                    CanvasInteraction.minimumScrapWidth)
    }

    /// The corner target the state machine hit-tests takes its size from the
    /// same constant the renderer draws the mark from.
    func test_grabbingTheBottomRightCornerResizesRatherThanMoves() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        // Card is (100,100) 240x80, so the corner square starts at
        // (340 - 14, 180 - 14) = (326, 166).
        i.begin(at: CGPoint(x: 334, y: 174), in: scene)
        XCTAssertTrue(i.isResizing)
        i.update(to: CGPoint(x: 384, y: 174), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.width, 290)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.origin, CGPoint(x: 100, y: 100),
                       "a resize must not also move the card")
    }

    /// The TARGET is the whole 14x14 corner square; the MARK `resizeHandle`
    /// draws is the triangle below its hypotenuse. The upper-left half is
    /// therefore live but uninked, deliberately — a target slightly larger than
    /// its mark forgives a near miss. (326,166) is the square's top-left corner;
    /// (329,169) is inside the square and above the triangle.
    func test_theUnmarkedHalfOfTheCornerSquareStillResizes() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 329, y: 169), in: scene)
        XCTAssertTrue(i.isResizing,
                      "shrinking the target down to the ink would make the corner "
                      + "feel like it misses")
    }

    /// ...and one point outside the square still moves the card, so the target
    /// has not silently grown either.
    func test_justOutsideTheCornerSquareMovesRatherThanResizes() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 320, y: 160), in: scene)
        XCTAssertTrue(i.isActive)
        XCTAssertFalse(i.isResizing)
    }

    func test_newScrapLandsAtTheClickAndOnTop() {
        var scene = sceneWithOneScrap()
        let id = CanvasInteraction.createScrap(at: CGPoint(x: 500, y: 400), in: &scene)
        let n = scene.node(id)
        XCTAssertEqual(n?.origin, CGPoint(x: 500, y: 400))
        XCTAssertGreaterThan(n!.z, scene.node(CanvasNodeID("s1"))!.z)
        XCTAssertNil(n?.cachedHeight, "a new scrap is measured by the view, not guessed here")
    }

    func test_createdScrapIDsAreUnique() {
        var scene = CanvasScene()
        let ids = (0..<200).map { _ in CanvasInteraction.createScrap(at: .zero, in: &scene) }
        XCTAssertEqual(Set(ids).count, 200)
        XCTAssertEqual(scene.nodes.count, 200)
    }

    // MARK: - Velocity, for §7.3's momentum

    func test_endReturnsTheFinalDragDeltaAsVelocity() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
        i.update(to: CGPoint(x: 130, y: 110), in: &scene)
        i.update(to: CGPoint(x: 160, y: 118), in: &scene)   // last frame: +30, +8
        let flick = i.end()
        XCTAssertEqual(flick?.id, CanvasNodeID("s1"))
        XCTAssertEqual(flick?.velocity, CGSize(width: 30, height: 8))
        XCTAssertFalse(i.isActive)
    }

    func test_aResizeYieldsNoFlick() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID("s1"), at: CGPoint(x: 340, y: 140), in: scene)
        i.update(to: CGPoint(x: 400, y: 140), in: &scene)
        XCTAssertNil(i.end(), "a rewrap must not send the card skating")
    }

    func test_aDragWithOnlyOneSampleYieldsZeroVelocity() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
        i.update(to: CGPoint(x: 160, y: 130), in: &scene)
        XCTAssertEqual(i.end()?.velocity, .zero,
                       "one sample is a placement, not a throw")
    }
}
```

`MaughamTests/Canvas/CanvasMomentumTests.swift`:

```swift
import XCTest
@testable import Maugham

final class CanvasMomentumTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap,
                           origin: .zero, width: 240)
        n.cachedHeight = 80
        s.insert(n)
        return s
    }

    func test_aFreshMomentumIsAtRest() {
        XCTAssertTrue(CanvasMomentum().isAtRest)
    }

    func test_aFlickBelowTheRestSpeedNeverStarts() {
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 0.2, height: 0.1))
        XCTAssertTrue(m.isAtRest, "a nudge is a placement, not a throw")
    }

    func test_steppingMovesTheNodeAndDecays() {
        var s = scene()
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 20, height: 0))

        var displacements: [CGFloat] = []
        var previous = s.node(CanvasNodeID("a"))!.origin.x
        while m.step(&s) {
            let now = s.node(CanvasNodeID("a"))!.origin.x
            displacements.append(now - previous)
            previous = now
        }
        XCTAssertGreaterThan(displacements.count, 3)
        XCTAssertEqual(displacements, displacements.sorted(by: >),
                       "each frame must carry the card less far than the last")
        XCTAssertTrue(m.isAtRest)
    }

    func test_momentumComesToRestQuicklyEnoughToFeelLikeAnObject() {
        var s = scene()
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 999, height: 0))
        var frames = 0
        while m.step(&s) { frames += 1; if frames > 600 { break } }
        XCTAssertLessThan(frames, 60, "a card still coasting after a second is a bug")
        XCTAssertLessThan(s.node(CanvasNodeID("a"))!.origin.x, 400,
                          "a flick must not launch the card off the canvas")
    }

    func test_launchSpeedIsCappedSoAJitteryTrackpadCannotFireACard() {
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 5_000, height: 0))
        XCTAssertLessThanOrEqual(hypot(m.velocity.width, m.velocity.height),
                                 CanvasMomentum.maximumLaunchSpeed + 0.0001)
    }

    func test_steppingANodeThatVanishedStopsRatherThanCrashing() {
        var s = CanvasScene()
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("gone"), velocity: CGSize(width: 20, height: 0))
        XCTAssertFalse(m.step(&s))
        XCTAssertTrue(m.isAtRest)
    }

    func test_stopHaltsACoastingCard() {
        var s = scene()
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 20, height: 0))
        m.stop()
        XCTAssertTrue(m.isAtRest)
        XCTAssertFalse(m.step(&s))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasInteractionTests -only-testing MaughamTests/CanvasMomentumTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasInteraction' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/CanvasInteraction.swift`**

```swift
import Foundation

/// Drag, resize and create, as a pure state machine so the gestures are
/// testable without a window.
struct CanvasInteraction {

    /// Narrower than this and a scrap wraps to one word per line.
    static let minimumScrapWidth: CGFloat = 120
    static let defaultScrapWidth: CGFloat = 240

    private enum Mode: Equatable {
        case idle
        case moving(CanvasNodeID, grabOffset: CGSize)
        case resizing(CanvasNodeID, startWidth: CGFloat, startX: CGFloat)
    }

    private var mode: Mode = .idle
    /// The last two drag samples, for §7.3's flick velocity. Drag updates arrive
    /// once per frame, so the difference between them IS points-per-frame — no
    /// timestamps, and the same unit `CanvasMomentum` decays.
    private var lastPoint: CGPoint?
    private var previousPoint: CGPoint?

    var isActive: Bool { mode != .idle }

    var activeNodeID: CanvasNodeID? {
        switch mode {
        case .idle: return nil
        case .moving(let id, _): return id
        case .resizing(let id, _, _): return id
        }
    }

    var isResizing: Bool {
        if case .resizing = mode { return true }
        return false
    }

    /// A press inside the card's bottom-right corner square starts a resize;
    /// anywhere else starts a move. The square's side is
    /// `CanvasRenderer.resizeHandleSize`, the same constant the mark is drawn
    /// from, so the two cannot drift apart in SIZE. They are not the same SHAPE:
    /// the mark is the triangle below the square's hypotenuse, so the upper-left
    /// half of this target is live but uninked — deliberately, because a target
    /// larger than its mark forgives a near miss and the reverse swallows drags
    /// the writer aimed at the card. See `CanvasRenderer.resizeHandle`.
    mutating func begin(at contentPoint: CGPoint, in scene: CanvasScene) {
        lastPoint = nil
        previousPoint = nil
        guard let node = scene.topmostNode(at: contentPoint), let frame = node.frame else {
            mode = .idle
            return
        }
        let handle = CanvasRenderer.resizeHandleSize
        if contentPoint.x >= frame.maxX - handle && contentPoint.y >= frame.maxY - handle {
            beginResize(node.id, at: contentPoint, in: scene)
        } else {
            mode = .moving(node.id, grabOffset: CGSize(width: contentPoint.x - node.origin.x,
                                                       height: contentPoint.y - node.origin.y))
        }
    }

    mutating func beginResize(_ id: CanvasNodeID, at contentPoint: CGPoint, in scene: CanvasScene) {
        lastPoint = nil
        previousPoint = nil
        guard let node = scene.node(id) else { mode = .idle; return }
        mode = .resizing(id, startWidth: node.width, startX: contentPoint.x)
    }

    mutating func update(to contentPoint: CGPoint, in scene: inout CanvasScene) {
        guard mode != .idle else { return }
        previousPoint = lastPoint
        lastPoint = contentPoint

        switch mode {
        case .idle:
            break
        case .moving(let id, let grab):
            scene.move(id, to: CGPoint(x: contentPoint.x - grab.width,
                                       y: contentPoint.y - grab.height))
        case .resizing(let id, let startWidth, let startX):
            // §7A.3: width is authoritative, the text reflows, the height is
            // derived. `setWidth` clears the cached height for exactly that
            // reason — `CanvasView.rebuildLayouts()` refills it when the gesture
            // ends.
            scene.setWidth(max(Self.minimumScrapWidth, startWidth + (contentPoint.x - startX)),
                           for: id)
        }
    }

    /// Ends the gesture and reports the flick, if there was one: the node that
    /// moved and its final per-frame velocity. A resize never flicks — rewrapping
    /// a scrap must not send it skating.
    @discardableResult
    mutating func end() -> (id: CanvasNodeID, velocity: CGSize)? {
        defer {
            mode = .idle
            lastPoint = nil
            previousPoint = nil
        }
        guard case .moving(let id, _) = mode else { return nil }
        guard let last = lastPoint, let previous = previousPoint else {
            // One sample is a placement, not a throw.
            return (id, .zero)
        }
        return (id, CGSize(width: last.x - previous.x, height: last.y - previous.y))
    }

    /// Mint a scrap at a point. IDs are unique within the scene by construction
    /// rather than by luck — the canvas will accumulate hundreds of these, and
    /// a short random id collides at that scale (tripwire 23's lesson, applied
    /// to a different id space).
    ///
    /// `cachedHeight` is deliberately nil: the new scrap has no text and only
    /// `ScrapLayout` may say how tall that is. `CanvasView` measures it in the
    /// same turn, which is why the create path calls `rebuildLayouts()`.
    static func createScrap(at contentPoint: CGPoint, in scene: inout CanvasScene) -> CanvasNodeID {
        var id = CanvasNodeID(UUID().uuidString.prefix(8).lowercased())
        while scene.node(id) != nil {
            id = CanvasNodeID(UUID().uuidString.prefix(8).lowercased())
        }
        scene.insert(CanvasNode(id: id, kind: .scrap, origin: contentPoint,
                                width: defaultScrapWidth, cachedHeight: nil,
                                z: scene.topZ + 1))
        return id
    }
}

/// §7.3: "Cards carry momentum and come to rest rather than snapping. This is
/// where tools actually acquire feel, it reads as craft rather than theme, and
/// unlike texture it never dates."
///
/// A velocity term plus an EXPLICIT per-frame decay, because `withAnimation`
/// cannot do this job: it interpolates `Animatable` values through the SwiftUI
/// view graph, and a plain model value read inside a `Canvas` draw closure is
/// not in that graph — the card would simply appear at its final position.
/// `CanvasView` drives `step(_:)` from `TimelineView(.animation(paused:))`.
///
/// Velocity is in CONTENT points per frame. Drag samples arrive once per frame,
/// so `CanvasInteraction.end()`'s delta is already in this unit.
struct CanvasMomentum: Equatable {

    /// Per-frame multiplier. 0.80 gives a ~20-frame (⅓ second) coast, which
    /// reads as an object being let go rather than a spring being released.
    static let decayPerFrame: CGFloat = 0.80
    /// Below this the card is at rest. Also the floor a flick must clear.
    static let restSpeed: CGFloat = 0.5
    /// Total travel is roughly `speed / (1 - decay)`, so this caps a flick at
    /// about 200 content points. Uncapped, a trackpad jitter fires the card off
    /// the canvas.
    static let maximumLaunchSpeed: CGFloat = 40

    private(set) var nodeID: CanvasNodeID?
    private(set) var velocity: CGSize = .zero

    var isAtRest: Bool { nodeID == nil }

    mutating func launch(_ id: CanvasNodeID, velocity v: CGSize) {
        let speed = hypot(v.width, v.height)
        guard speed >= Self.restSpeed else { stop(); return }
        let scale = min(speed, Self.maximumLaunchSpeed) / speed
        nodeID = id
        velocity = CGSize(width: v.width * scale, height: v.height * scale)
    }

    mutating func stop() {
        nodeID = nil
        velocity = .zero
    }

    /// Advance one frame. Returns `true` while still coasting.
    @discardableResult
    mutating func step(_ scene: inout CanvasScene) -> Bool {
        guard let id = nodeID, let node = scene.node(id) else { stop(); return false }
        scene.move(id, to: CGPoint(x: node.origin.x + velocity.width,
                                   y: node.origin.y + velocity.height))
        velocity = CGSize(width: velocity.width * Self.decayPerFrame,
                          height: velocity.height * Self.decayPerFrame)
        if hypot(velocity.width, velocity.height) < Self.restSpeed {
            stop()
            return false
        }
        return true
    }
}
```

- [ ] **Step 4: Wire it into `CanvasView`**

Three edits to `Maugham/Canvas/CanvasView.swift`.

**(a)** Two new `@State` properties beside the others:

```swift
    @State private var interaction = CanvasInteraction()
    @State private var momentum = CanvasMomentum()
```

**(b)** Widen the existing timeline's pause condition, step momentum in the same tick, and replace the `onDrag` stub. Task 10's `TimelineView` block becomes:

```swift
            // ONE clock, two interpolated models: §7A.5's straightening and
            // §7.3's coast. Paused only when BOTH are settled, so an idle canvas
            // costs nothing. `withAnimation` cannot do either job — a plain model
            // value read inside a Canvas draw closure is not in the SwiftUI
            // animation graph (see CanvasMomentum).
            TimelineView(.animation(paused: straighten.isSettled && momentum.isAtRest)) { context in
                Canvas { cx, size in
                    _ = drawRevision
                    CanvasRenderer.draw(scene: scene, camera: camera, viewSize: size,
                                        layouts: layouts,
                                        visibleEditorNodeID: visibleEditorNodeID,
                                        straighten: straighten, into: &cx)
                }
                .allowsHitTesting(false)
                .onChange(of: context.date) { previous, now in
                    straighten.step(elapsed: now.timeIntervalSince(previous))
                    // Guarded on `isAtRest` so a tick that exists only to
                    // straighten a card does not reset the save debounce.
                    if !momentum.isAtRest, !momentum.step(&scene) {
                        store?.scheduleSave(scene: scene, scraps: scraps)
                        // The card has come to rest somewhere new, so the
                        // accessibility tree's frames are stale. Bumped HERE and
                        // not once per coasting frame: `sceneRevision` is the
                        // structural counter and a coast is one structural
                        // change, at its end.
                        sceneRevision += 1
                    }
                    revision += 1
                }
            }

            CanvasEventView(
                camera: $camera,
                onClick: { viewPoint, clickCount in
                    handleClick(at: camera.contentPoint(fromView: viewPoint),
                                clickCount: clickCount)
                },
                onDrag: { viewPoint, phase in
                    handleDrag(at: camera.contentPoint(fromView: viewPoint), phase: phase)
                },
                undoManager: nil)      // Task 15
```

**(c)** `handleClick` grows the create path, and `handleDrag` arrives:

```swift
    private func handleClick(at contentPoint: CGPoint, clickCount: Int) {
        commitActiveEdit()

        guard clickCount >= 2 else {
            editingNodeID = nil
            caretIndex = nil
            // The card settles back over ~120ms. `isSettled` is false the moment
            // focus leaves — it means "every card is at ITS target", not "every
            // progress value is 1" — so the clock keeps running until it lands.
            straighten.focus(nil)
            store?.scheduleSave(scene: scene, scraps: scraps)
            return
        }

        // Double click on a scrap enters it; on empty space it makes one.
        if let node = scene.topmostNode(at: contentPoint),
           case .scrap = node.kind,
           let layout = layouts[node.id],
           let frame = node.frame {
            // §7A.5 requirement 1 — caret first, in the card's unrotated space,
            // THEN animate. See Task 10.
            let angle = CanvasRenderer.drawnAngle(for: node.id, straighten: straighten)
            let local = CanvasRenderer.localPoint(contentPoint, inCard: frame, angle: angle)
            let textOrigin = CanvasCardMetrics.textOrigin(inCard: frame)
            caretIndex = layout.characterIndex(
                at: CGPoint(x: local.x - textOrigin.x, y: local.y - textOrigin.y))
            editingNodeID = node.id
            lastKeystrokeAt = nil
            // The editor mounts here and takes keystrokes at once; it is its
            // VISIBILITY that is withheld — `visibleEditorNodeID` releases that
            // when `straighten.isLevel(_:)` goes true, ~120ms from now.
            straighten.focus(node.id)
        } else if scene.topmostNode(at: contentPoint) == nil {
            let id = CanvasInteraction.createScrap(at: contentPoint, in: &scene)
            scraps[id] = ""
            // A new scrap has no cachedHeight, so it has no frame, so it is
            // invisible to hit testing and culling until it is measured.
            // `rebuildLayouts()` also bumps `sceneRevision` for the AX tree.
            rebuildLayouts()
            editingNodeID = id
            caretIndex = 0
            lastKeystrokeAt = nil
            straighten.focus(id)
        }
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    private func handleDrag(at contentPoint: CGPoint, phase: CanvasDragPhase) {
        switch phase {
        case .began:
            // A focused scrap owns its own mouse — the editor is in front of the
            // event view — so a drag can only start on an unfocused card.
            guard editingNodeID == nil else { return }
            momentum.stop()
            interaction.begin(at: contentPoint, in: scene)
        case .changed:
            guard interaction.isActive else { return }
            interaction.update(to: contentPoint, in: &scene)
            revision += 1
        case .ended:
            guard interaction.isActive else { return }
            let wasResizing = interaction.isResizing
            let flick = interaction.end()
            if wasResizing {
                // The rewrap cleared the cached height; re-measure before the
                // card is hit-tested or culled again. `rebuildLayouts()` bumps
                // `sceneRevision` itself.
                rebuildLayouts()
            } else {
                // A move is one structural change, recorded at the end of the
                // gesture rather than once per drag frame. If the card is about
                // to coast, the timeline bumps `sceneRevision` again when it
                // comes to rest.
                sceneRevision += 1
                if let flick { momentum.launch(flick.id, velocity: flick.velocity) }
            }
            store?.scheduleSave(scene: scene, scraps: scraps)
            revision += 1
        }
    }
```

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasInteractionTests -only-testing MaughamTests/CanvasMomentumTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 13 + 7 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasInteraction.swift Maugham/Canvas/CanvasView.swift \
        MaughamTests/Canvas/CanvasInteractionTests.swift MaughamTests/Canvas/CanvasMomentumTests.swift project.yml
git commit -m "feat(canvas): create, move and resize scraps, with momentum

Width authoritative, height derived; every path that can leave a node
unmeasured re-measures it, or the node has no frame and is invisible to
hit testing. Momentum is a velocity term plus an explicit per-frame decay
driven by TimelineView — withAnimation cannot animate a model value read
inside a Canvas draw closure."
```

---

### Task 14: The accessibility layer — resolving spec §7A.6

**Files:**
- Create: `Maugham/Canvas/CanvasAccessibility.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasAccessibilityTests.swift`

**Spec §7A.6 is unambiguous:** *"We own accessibility for the canvas. Drawn content has no AX tree… Budget an AX layer mirroring the scene graph; Figma does exactly this. **Not optional in a writing tool.**"* Spec §10 lists it as an open question with two outcomes — build it or soften the claim. This task builds it.

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNode`, `CanvasNodeID`, `CanvasNodeKind` (Task 1); `CanvasCamera` (Task 4); `CanvasRenderer.placeholderLabel(forReference:)` (Task 7).
- **Produces:**
  - `enum CanvasAXRole: String, Equatable, Sendable` — `case scrap`, `case item`.
  - `struct CanvasAXElement: Equatable, Identifiable` — `let id: CanvasNodeID`, `let role: CanvasAXRole`, `let label: String`, `let value: String`, `let contentFrame: CGRect` (CONTENT coordinates), `func viewFrame(in camera: CanvasCamera) -> CGRect`.
  - `enum CanvasAccessibility` — `static let canvasLabel: String`, `static let emptyCanvasValue: String`, `static let emptyScrapValue: String`, `static func elements(scene:scraps:) -> [CanvasAXElement]`, `static func summary(scene:) -> String`.
  - `struct CanvasAXChildren: View, Equatable` — `let elements: [CanvasAXElement]`, `let camera: CanvasCamera`. The synthetic children, extracted so `.equatable()` can stop SwiftUI rebuilding N views per body pass.

**Four decisions, each stated rather than hedged.**

1. **Every node is in the tree, not just the visible ones.** Culling is a *drawing* optimisation; a node you cannot see is still a node you must be able to reach, and a VoiceOver user navigates the canvas by walking its elements, not by panning first. An offscreen element's rect resolves offscreen — that is honest, and it is what lets an assistive client scroll to it.
2. **Reading order is rows top-to-bottom, then left-to-right within a row** — not z-order, which is a drawing concern and would read a canvas out in the order the writer happened to touch it. Rows are banded so cards that are roughly level read as one row.
3. **The mounted editor stays a real `NSTextView`** and is therefore natively accessible — IME, caret, spell-check, selection, all of it. That is the entire reason for the one-real-editor-on-focus rule (§7A.6 quotes the W3C list of what drawing text forfeits). The AX work here is to *not hide it*: no `.accessibilityElement(children: .ignore)` on the stack, no `.accessibilityHidden(true)`. `CanvasCompositionTests` (Task 10) already pins that; `ScrapEditorHostTests` pins the container side.
4. **The element list is CAMERA-INDEPENDENT, is keyed on STRUCTURE, and is not rebuilt during `body`.** Building it copies every scrap's text and sorts the result. Three things are required and each closes a different leak:

   - **Content-space frames.** Elements carry `contentFrame`, so a pan or a zoom does not invalidate the *list* at all. The camera is applied per element, as arithmetic, where the element is positioned.
   - **Keyed on `sceneRevision`, never on `revision`.** `revision` is the redraw counter: `handleDrag(.changed)` bumps it, and the timeline's own `.onChange(of: context.date)` bumps it again on every frame of every straighten and every momentum coast. An `.onChange(of: revision)` therefore rebuilds a scene-proportional list at 60–120 Hz for the whole of any drag, coast or focus animation — sorting the scene and copying every scrap's string, at the 2,000-node bound this plan supports, inside the loop Task 16 asserts is proportional to the *viewport*. `sceneRevision` (Task 10) is bumped only by load, create, delete, undo, the end of a drag or resize, momentum coming to rest, and leaving a scrap. **Not** per keystroke either: while a scrap is focused the real `NSTextView` is the accessible thing, so its synthetic twin may be stale until the writer leaves.
   - **Sorted from `unorderedNodes`, and counted with `count`.** `CanvasScene.nodes` sorts on every access, so `elements` reading it and then re-sorting by a different comparator pays for the draw-order sort for nothing, and `summary` reading `scene.nodes.count` from inside `body` is a 2,000-element sort per body evaluation.

The SwiftUI mechanism is `View.accessibilityChildren(children:)` (**macOS 13+**, not 12 — the deployment target is 14, so no availability guard is needed either way), which replaces a view's accessibility children with synthetic elements laid out in its own coordinate space — exactly the Figma shape §7A.6 names.

**The children builder is extracted and `.equatable()`, and one cost is accepted openly.** `ForEach(axElements)` reads `camera`, so left inline it is re-evaluated on every body pass — N synthetic views per frame, which is the same scene-proportional-work-in-a-per-frame-loop the bullet above forbids, just one layer down. Extracting it into a small `Equatable` view keyed on `(elements, camera)` lets SwiftUI skip it whenever neither changed, which is **every animation path in this plan**: a straighten, a momentum coast, a node drag and typing all leave the camera alone. What it does *not* skip is a pan or a zoom, where the frames genuinely have to follow the camera to stay pointable. That residue is bounded by the same 2,000-node number and is accepted; the condition that would force a change is a measured pan regression at the supported bound.

Two alternatives were considered and rejected. Culling the AX list to the viewport contradicts decision 1 — a node you cannot see is still a node you must be able to reach. Positioning the children in content space and applying the camera once with `.offset`/`.scaleEffect` over the whole AX layer would be `O(1)` per frame, but it is **unverified** that SwiftUI resolves accessibility frames through a `scaleEffect`, and it would put a modifier this plan bans everywhere else into the one file where a reader cannot tell it is safe. If the pan does regress, verify that behaviour first rather than assuming it.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasAccessibilityTests: XCTestCase {

    private func scrapNode(_ id: String, x: CGFloat, y: CGFloat) -> CanvasNode {
        CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                   origin: CGPoint(x: x, y: y), width: 240, cachedHeight: 80)
    }

    private func sampleScene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(scrapNode("s1", x: 0, y: 0))
        s.insert(scrapNode("s2", x: 400, y: 8))       // same band as s1, to its right
        s.insert(scrapNode("s3", x: 0, y: 400))
        s.insert(CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                            origin: CGPoint(x: 400, y: 400), width: 180, cachedHeight: 120))
        return s
    }

    private let scraps: [CanvasNodeID: String] = [
        CanvasNodeID("s1"): "The falls at night.",
        CanvasNodeID("s2"): "October's doctor was kind about it.",
        CanvasNodeID("s3"): "",
    ]

    func test_everyNodeIsAnAccessibilityElement() {
        let elements = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
        XCTAssertEqual(elements.count, 4)
    }

    /// Culling is a DRAWING optimisation. A node you cannot see is still a node
    /// you must be able to reach.
    func test_offscreenNodesAreStillInTheTree() {
        var scene = sampleScene()
        scene.insert(scrapNode("far", x: 90_000, y: 90_000))
        let elements = CanvasAccessibility.elements(scene: scene, scraps: scraps)
        XCTAssertTrue(elements.contains { $0.id == CanvasNodeID("far") })
    }

    func test_readingOrderIsRowsThenColumns() {
        let ids = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps).map(\.id.raw)
        XCTAssertEqual(ids, ["s1", "s2", "s3", "item:r-9"],
                       "roughly-level cards must read left to right as one row, "
                       + "not in the order the writer happened to touch them")
    }

    func test_aScrapCarriesItsTextAsItsValue() {
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
            .first { $0.id == CanvasNodeID("s1") }
        XCTAssertEqual(element?.role, .scrap)
        XCTAssertEqual(element?.value, "The falls at night.")
        XCTAssertTrue(element?.label.contains("Scrap") == true)
    }

    func test_anEmptyScrapSaysSoRatherThanReadingAsBlank() {
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
            .first { $0.id == CanvasNodeID("s3") }
        XCTAssertEqual(element?.value, CanvasAccessibility.emptyScrapValue)
        XCTAssertFalse(CanvasAccessibility.emptyScrapValue.isEmpty)
    }

    func test_anItemNodeIsLabelledAsAReference() {
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
            .first { $0.id == .item("r-9") }
        XCTAssertEqual(element?.role, .item)
        XCTAssertTrue(element?.value.contains("r-9") == true)
    }

    /// Frames are in VIEW coordinates, so an assistive client can point at them.
    func test_elementsAreCameraIndependentAndResolveThroughTheCamera() throws {
        let element = try XCTUnwrap(
            CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
                .first { $0.id == CanvasNodeID("s1") })
        XCTAssertEqual(element.contentFrame, CGRect(x: 0, y: 0, width: 240, height: 80),
                       "elements must not depend on the camera — otherwise every "
                       + "scroll event rebuilds a scene-proportional list inside a "
                       + "per-frame loop")

        var camera = CanvasCamera()
        camera.zoom = 2
        camera.pan = CGPoint(x: 50, y: 30)
        XCTAssertEqual(element.viewFrame(in: camera),
                       CGRect(x: 50, y: 30, width: 480, height: 160),
                       "an assistive client points at VIEW coordinates")
    }

    func test_anUnmeasuredNodeIsStillReachable() {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: CanvasNodeID("new"), kind: .scrap,
                                origin: .zero, width: 240))   // no cachedHeight
        let elements = CanvasAccessibility.elements(scene: scene, scraps: [:])
        XCTAssertEqual(elements.count, 1,
                       "a scrap the writer just made must not be unreachable "
                       + "until it happens to be measured")
        XCTAssertGreaterThan(elements[0].contentFrame.height, 0)
    }

    func test_anEmptyCanvasAnnouncesItselfRatherThanBeingSilent() {
        XCTAssertEqual(CanvasAccessibility.summary(scene: CanvasScene()),
                       CanvasAccessibility.emptyCanvasValue)
        XCTAssertTrue(CanvasAccessibility.summary(scene: sampleScene()).contains("4"))
    }

    /// The tree is only real if the view actually installs it.
    func test_canvasViewInstallsTheAccessibilityChildren() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()    // MaughamTests/Canvas
                .deletingLastPathComponent()    // MaughamTests
                .deletingLastPathComponent()    // repo root
                .appendingPathComponent("Maugham/Canvas/CanvasView.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains(".accessibilityChildren"),
                      "spec §7A.6: drawn content has no AX tree and we own one — "
                      + "CanvasAccessibility exists but CanvasView never installs it")
        XCTAssertTrue(source.contains("CanvasAccessibility.elements"))
    }

    /// The tree must be rebuilt on a state change, never inside `body`. `body`
    /// runs per scroll event, per drag frame and per momentum tick; building a
    /// scene-proportional list there is exactly the work Task 16 asserts stays
    /// proportional to the viewport.
    func test_theTreeIsBuiltOnChangeRatherThanInsideBody() throws {
        let source = try canvasViewSource()
        let build = try XCTUnwrap(source.range(of: "CanvasAccessibility.elements"))
        let onChange = try XCTUnwrap(source.range(of: ".onChange(of: sceneRevision"),
                                     "the AX tree must be rebuilt from an onChange")
        XCTAssertTrue(onChange.lowerBound < build.lowerBound,
                      "CanvasAccessibility.elements is being called before the "
                      + "onChange that should own it — i.e. inside body")
    }

    /// ...and on the STRUCTURAL counter, not the redraw one. `revision` is
    /// bumped by `handleDrag(.changed)` and again by the timeline's per-frame
    /// `.onChange(of: context.date)`, which covers both the straighten clock and
    /// every momentum coast — so an `.onChange(of: revision)` here rebuilds the
    /// whole tree at 60–120 Hz through any drag, coast or focus animation.
    func test_theTreeIsNotKeyedOnTheRedrawCounter() throws {
        XCTAssertFalse(codeOnly(try canvasViewSource()).contains(".onChange(of: revision"),
                       "the accessibility tree is keyed on the redraw counter — it "
                       + "will sort the scene and copy every scrap's string once "
                       + "per frame for the whole of every animation")
    }

    /// The children read the camera, so inline in `body` they are N synthetic
    /// views rebuilt per frame — the same scene-proportional work, one layer
    /// down from the cached list.
    func test_theSyntheticChildrenAreExtractedAndEquatable() throws {
        let src = codeOnly(try canvasViewSource())
        XCTAssertTrue(src.contains("CanvasAXChildren(elements: axElements, camera: camera)"))
        XCTAssertTrue(src.contains(".equatable()"),
                      "without .equatable() the extraction buys nothing — SwiftUI "
                      + "re-evaluates the children on every body pass")
        XCTAssertFalse(src.contains("ForEach(axElements)"),
                       "the ForEach belongs in CanvasAXChildren, not in body")
    }

    private func canvasViewSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Maugham/Canvas/CanvasView.swift"), encoding: .utf8)
    }

    /// A doc comment that NAMES a modifier is documentation; only code counts —
    /// the same rule `CanvasCompositionTests` uses, for the same reason.
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasAccessibilityTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasAccessibility' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/CanvasAccessibility.swift`**

```swift
import SwiftUI

/// What a canvas element is, for an assistive client.
enum CanvasAXRole: String, Equatable, Sendable {
    case scrap
    case item
}

/// One synthetic accessibility element mirroring one node of the scene graph.
struct CanvasAXElement: Equatable, Identifiable {
    let id: CanvasNodeID
    let role: CanvasAXRole
    /// What the element IS, plus where — "Scrap, 3 of 12" reads badly, so the
    /// label carries the kind and the value carries the words.
    let label: String
    let value: String
    /// CONTENT coordinates, deliberately: an element that carried view
    /// coordinates would be invalidated by every pan and zoom, so the whole list
    /// would be rebuilt on every scroll event — scene-proportional work inside a
    /// per-frame loop. The camera is applied at the point of use instead.
    let contentFrame: CGRect

    /// Where an assistive client should point, right now.
    func viewFrame(in camera: CanvasCamera) -> CGRect {
        let origin = camera.viewPoint(fromContent: contentFrame.origin)
        return CGRect(x: origin.x, y: origin.y,
                      width: contentFrame.width * camera.zoom,
                      height: contentFrame.height * camera.zoom)
    }
}

/// The canvas's accessibility tree.
///
/// Spec §7A.6: *"We own accessibility for the canvas. Drawn content has no AX
/// tree… Budget an AX layer mirroring the scene graph; Figma does exactly this.
/// Not optional in a writing tool."*
///
/// Three rules, each deliberate:
///
/// 1. **Every node is here, not just the visible ones.** Culling is a drawing
///    optimisation; a node you cannot see is still a node you must be able to
///    reach, and an assistive client walks elements rather than panning first.
/// 2. **Reading order is rows, then columns** — banded by y so roughly-level
///    cards read left to right. Z-order is a drawing concern and would read the
///    canvas out in the order the writer happened to touch it.
/// 3. **The mounted editor is a real `NSTextView`** and is natively accessible.
///    That is the whole point of the one-real-editor-on-focus rule: drawing text
///    forfeits IME, caret placement, spell-check, selection and
///    magnification-follows-caret. Nothing here may hide it.
/// 4. **Nothing here depends on the camera**, so panning and zooming — the
///    commonest per-frame path — cannot invalidate the list. `CanvasView`
///    rebuilds it from an `.onChange(of: sceneRevision)`, never inside `body`
///    and never from `revision`, which every animation frame increments.
enum CanvasAccessibility {

    static let canvasLabel = "Planning canvas"
    static let emptyCanvasValue = "Empty canvas. Double-click to add a scrap."
    static let emptyScrapValue = "Empty scrap"

    /// Cards within this many points of each other vertically read as one row.
    private static let rowBand: CGFloat = 60
    /// A node that has never been measured still needs a rect, or it drops out
    /// of the tree the instant a writer creates it.
    private static let unmeasuredHeight: CGFloat = 40

    static func elements(scene: CanvasScene,
                         scraps: [CanvasNodeID: String]) -> [CanvasAXElement] {
        // `unorderedNodes`, not `nodes`: `nodes` sorts into DRAW order on every
        // access, and this method immediately re-sorts into READING order. One
        // sort, not two.
        scene.unorderedNodes
            .sorted { a, b in
                let bandA = (a.origin.y / rowBand).rounded(.down)
                let bandB = (b.origin.y / rowBand).rounded(.down)
                if bandA != bandB { return bandA < bandB }
                if a.origin.x != b.origin.x { return a.origin.x < b.origin.x }
                return a.id.raw < b.id.raw
            }
            .map { node in
                let frame = CGRect(origin: node.origin,
                                   size: CGSize(width: node.width,
                                                height: node.cachedHeight ?? unmeasuredHeight))
                switch node.kind {
                case .scrap:
                    let text = scraps[node.id] ?? ""
                    return CanvasAXElement(
                        id: node.id, role: .scrap,
                        label: "Scrap",
                        value: text.isEmpty ? emptyScrapValue : text,
                        contentFrame: frame)
                case .item(let referenceId):
                    return CanvasAXElement(
                        id: node.id, role: .item,
                        label: "Reference",
                        value: CanvasRenderer.placeholderLabel(forReference: referenceId),
                        contentFrame: frame)
                }
            }
    }

    /// What the canvas itself says when focused, before its children are walked.
    ///
    /// `scene.count`, never `scene.nodes.count` — this is read from `body`, and
    /// `nodes` sorts the whole scene to hand back a number the dictionary
    /// already knows.
    static func summary(scene: CanvasScene) -> String {
        let count = scene.count
        guard count > 0 else { return emptyCanvasValue }
        return "\(count) \(count == 1 ? "item" : "items")"
    }
}

/// The synthetic children, extracted so SwiftUI can skip rebuilding them.
///
/// Inline in `CanvasView.body`, this `ForEach` re-evaluates N views on every
/// body pass because it reads `camera` — scene-proportional work at frame rate,
/// which is what `CanvasAccessibility`'s own doc comment forbids one layer up.
/// As an `Equatable` view used with `.equatable()`, SwiftUI skips it whenever
/// neither the elements nor the camera changed: a straighten, a coast, a node
/// drag and typing all qualify. A pan or a zoom does rebuild it — the frames
/// have to follow the camera to stay pointable — and that is the accepted cost,
/// bounded by the same 2,000-node number Task 16 defends.
struct CanvasAXChildren: View, Equatable {
    let elements: [CanvasAXElement]
    let camera: CanvasCamera

    var body: some View {
        ForEach(elements) { element in
            let frame = element.viewFrame(in: camera)
            Color.clear
                .frame(width: max(1, frame.width), height: max(1, frame.height))
                .position(x: frame.midX, y: frame.midY)
                .accessibilityElement()
                .accessibilityLabel(element.label)
                .accessibilityValue(element.value)
        }
    }
}
```

- [ ] **Step 4: Install the tree in `CanvasView`**

Two edits to `Maugham/Canvas/CanvasView.swift`.

**(a)** Hold the tree in `@State` and rebuild it **only when the scene's structure changes** — never inline in `body`, and never off the redraw counter:

```swift
    /// Rebuilt from `.onChange(of: sceneRevision)`, deliberately NOT computed in
    /// `body` and deliberately NOT keyed on `revision`.
    ///
    /// Building it copies every scrap's text and sorts the result. `body` runs on
    /// every scroll event, every drag frame and every momentum tick, so computing
    /// it there is scene-proportional work inside the loop Task 16 asserts is
    /// viewport-proportional — and `revision` is bumped by every one of those
    /// frames, so keying the rebuild off it is the same defect with an extra
    /// step. `sceneRevision` moves only when the scene's shape or content does.
    /// The elements carry CONTENT frames, so a pan or a zoom does not invalidate
    /// them at all.
    @State private var axElements: [CanvasAXElement] = []
```

and on the ZStack, beside `.onAppear`:

```swift
        .onChange(of: sceneRevision, initial: true) { _, _ in
            axElements = CanvasAccessibility.elements(scene: scene, scraps: scraps)
        }
```

**(b)** Attach them to the drawn layer — the `Canvas` inside the `TimelineView`, immediately after `.allowsHitTesting(false)`:

```swift
                .accessibilityLabel(CanvasAccessibility.canvasLabel)
                .accessibilityValue(CanvasAccessibility.summary(scene: scene))
                .accessibilityChildren {
                    // Spec §7A.6: drawn content has no AX tree, so we build one.
                    // These are synthetic elements laid out in the Canvas's own
                    // coordinate space — the mounted editor is a real NSTextView
                    // and is exposed on its own.
                    //
                    // EXTRACTED and .equatable() rather than an inline ForEach:
                    // the children read the camera, so inline they would be
                    // rebuilt on every body pass — N views per frame for the
                    // whole of every straighten, coast and drag, which is the
                    // very thing `axElements` is cached to avoid. As an
                    // Equatable view SwiftUI skips them unless the elements or
                    // the camera actually moved.
                    CanvasAXChildren(elements: axElements, camera: camera)
                        .equatable()
                }
```

Do **not** add `.accessibilityElement(children: .ignore)` or `.accessibilityHidden(true)` anywhere in this file — either would throw the mounted editor away with the drawn nodes. `CanvasCompositionTests` fails if you do.

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasAccessibilityTests -only-testing MaughamTests/CanvasCompositionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 13 + 7 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasAccessibility.swift Maugham/Canvas/CanvasView.swift \
        MaughamTests/Canvas/CanvasAccessibilityTests.swift project.yml
git commit -m "feat(canvas): accessibility tree mirroring the scene graph

Resolves spec 7A.6, which calls this not optional in a writing tool, and
spec 10's open question. Every node is an element (culling is a drawing
concern), reading order is rows then columns, and the mounted NSTextView
stays natively accessible because nothing hides it. The tree is keyed on
a structural counter rather than the redraw counter, and the synthetic
children are an extracted Equatable view — either one left as-is rebuilds
the whole scene's worth of AX at frame rate through every animation."
```

---

### Task 15: Undo — resolving spec §10

**Files:**
- Create: `Maugham/Canvas/CanvasUndo.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasUndoTests.swift`

**Spec §10 left this open:** *"Canvas edits are sidecar state, not op-log ops. Whether ⌘Z spans them, and if so how, given ADR 0023's op-log-backed model."*

**Decision: a canvas-scoped `UndoManager` with snapshot-based records, not the op log.** Four reasons, stated so the next reader does not relitigate:

1. ADR 0023's unified undo works by appending **compensating ops** to the op log. Canvas geometry is explicitly derived state that may be deleted without loss (spec §8). Putting it in the op log would make the sidecar non-derived — it would become the only record of a move — and that contradicts §8 directly.
2. ⌘Z already means "undo what is in front of you": in the editor it undoes text via the editor's own undo manager. A canvas-scoped manager is the same rule, not a new one.
3. Doing nothing is not an option. A drag that scatters a carefully arranged region with no way back is the single most likely way this surface loses a writer's trust.
4. **Snapshots, not per-property inverses.** 1C-b's region drags mutate a region's frame *and* every resident's origin; recording per-property inverses for that is how you get a half-undone drag. One snapshot per gesture is exactly correct and cheap — `CanvasScene` is a value type holding hundreds of nodes, not millions.

**Where undo lives, across the three plans.** `CanvasUndo` is built here, in 1C-a, and **1C-b Task 4 rebinds it to `CanvasModel` without changing the class**. That is why the state is reached through two closures rather than being owned: in 1C-a the owner is `CanvasView`'s `@State`, in 1C-b it is `CanvasModel`. Only the closures get rebound. 1C-a ships a canvas a writer drags scraps around on, so it ships with ⌘Z.

**5. Scrap TEXT is a snapshot too, and the mounted editor registers nothing.** `ScrapLayout.makeEditor` sets `allowsUndo = false` (Task 3). This is a decision with a cost, and both halves need stating.

The alternative — letting the text view register its own typing steps on the shared manager while `CanvasUndo` *also* snapshots the text — puts **one change on the stack twice**. After typing and clicking out, ⌘Z runs the canvas snapshot and reverts everything; the text view's queued step is still there, pointed at an `NSTextStorage` that `rebuildLayouts()` has since replaced, so the *second* ⌘Z appears to do nothing. "One stack in the order they happened" would be false in the one way a writer notices.

So the canvas owns text undo. The **outer** boundary is focus: `beginGesture("Edit Scrap")` when a scrap takes focus, `endGesture()` when focus leaves.

**Inside a visit the boundary is a sentence or a beat of stillness, not the whole visit and not the keystroke.** `syncActiveEdit` runs on every change, and it calls `breakGesture()` — close and immediately reopen — on two signals:

- **a finished sentence**: the scrap's text now ends in `.`, `!` or `?` and did not before, evaluated *after* the keystroke is folded in, so the terminator belongs to the step it closes;
- **an idle beat**: `ScrapUndoBeat.idleSeconds` of stillness since the last fold, evaluated *before* the keystroke is folded in, so the step that closes ends where the writer actually paused. No timer is involved — the pause is noticed retroactively at the next keystroke, which is the only moment it matters.

`ScrapUndoBeat` is a pure enum holding those two rules, so the policy is unit-testable without a run loop and without a text view.

Three options were on the table and this is the third. **Per-visit** — one ⌘Z takes back everything typed since the writer clicked in — is a real loss on a scrap that took a paragraph, and it is what an earlier draft accepted. **Per-word** is only reachable by handing undo back to the text view (`allowsUndo = true`), which is the double-registration defect above: one change on the stack twice, with the text view's copy pointed at an `NSTextStorage` that `rebuildLayouts()` has since orphaned. A gesture break per *word* would also mean a whole-scene snapshot per word, and the snapshot is the thing that makes 1C-b's region drags correct, so its frequency has to stay coarse. Per-sentence has the granularity a writer notices and none of the hazard. Record the rejection in the ADR (Task 17) so it is not relitigated.

**The accepted cost, stated where a writer will see it.** Inside a scrap, ⌘Z takes back a sentence — or the run of typing since the last pause — rather than a word. Task 17 Step 5 requires the user guide to say so; every other statement of this cost in the plan is developer-facing.

**`UndoManager.groupsByEvent`, and why `beginGesture` opens no group.** It defaults to `true`, which installs a run-loop observer that opens an implicit top-level group per event and closes it at end of event. Two things follow:

- Calling `undo()` synchronously, outside a run loop, while that implicit group is open raises `NSInternalInconsistencyException` ("undo was called with too many nested undo groups"). **Every test in this file therefore sets `undo.groupsByEvent = false`.**
- An explicit group of ours **cannot span an event boundary** — and an "Edit Scrap" gesture spans as many events as the writer types keystrokes. So `beginGesture` takes a *snapshot* and nothing else; `endGesture` opens the group, registers, sets the action name and closes the group, all synchronously in one event. That also disposes of the empty-group problem: `UndoManager` pushes a closed group whether or not anything was registered inside it, so opening one at `beginGesture` would leave a step behind after a gesture that changed nothing — and ⌘Z after a stray click would then undo the writer's last *real* edit while appearing to do nothing.

**6. ⌘Z pressed *during* an open gesture must not corrupt that gesture's baseline.** `beginGesture` captures the snapshot at focus-in and registers nothing until focus-out, so the manager is live and undoable for the whole visit. Type in A → click out → double-click into B (the new gesture's snapshot `S0` holds A's new text) → ⌘Z reverts A → type in B → click out: `endGesture` diffs against `S0` and registers a step whose *undo* re-applies exactly what the writer just undid. The words stay safe on disk, but ⌘Z visibly does the wrong thing, which is the same loss of trust reason 3 is about.

The fix is one line inside the undo closure: **after `applySnapshot`, re-baseline any open gesture on the state the undo produced.** Closing the gesture before servicing the undo is the other candidate and was rejected — the only hook for it is `NSUndoManagerWillUndoChange`, and registering or closing a group while the manager is mid-undo turns the registration into a *redo*. Re-baselining is local, synchronous and testable.

There is a second-order effect worth knowing about rather than guarding: `CanvasView.applySnapshot` calls `rebuildLayouts()`, which replaces the `ScrapLayout` of any scrap whose text changed. If that is the focused scrap, `ScrapEditorHost.updateNSView` sees a new layout identity and rebinds the editor — which is exactly right, because otherwise the mounted editor would keep showing the text the undo just discarded. The caret returns to the click index. That is Task 9's rebinding path doing its job, not an accident.

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNodeID` (Task 1).
- **Produces:**
  - `enum ScrapUndoBeat` — `static let idleSeconds: TimeInterval`, `static func hasGoneIdle(since last: Date?, now: Date) -> Bool`, `static func completesASentence(before: String, after: String) -> Bool`.
  - `final class CanvasUndo` with
    - `typealias Snapshot = (scene: CanvasScene, scraps: [CanvasNodeID: String])`
    - `init(undoManager: UndoManager)`
    - `var readSnapshot: (() -> Snapshot)?` and `var applySnapshot: ((Snapshot) -> Void)?` — bound by whoever owns the state (`CanvasView` here, `CanvasModel` in 1C-b)
    - `func beginGesture(_ name: String)`
    - `func endGesture()` — closes the group, registering nothing if the snapshot is unchanged
    - `func breakGesture()` — close and immediately reopen under the same name; a no-op outside a gesture, and inside a nested one
    - `func mutate(_ name: String, _ body: () -> Void)` — begin/body/end
    - `func noteCameraChanged()` — deliberately not undoable
    - `var isInGesture: Bool` — test seam

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AppKit
@testable import Maugham

final class CanvasUndoTests: XCTestCase {

    /// Every test sets `groupsByEvent = false`. It defaults to TRUE, which
    /// installs a run-loop observer that opens an implicit top-level group per
    /// event; calling `undo()` synchronously while that group is open raises
    /// NSInternalInconsistencyException. Production keeps the default, safely,
    /// because every gesture is bracketed inside one event — see CanvasUndo.
    private func manager() -> UndoManager {
        let m = UndoManager()
        m.groupsByEvent = false
        return m
    }

    /// Stands in for the state owner: `CanvasView`'s `@State` in 1C-a,
    /// `CanvasModel` in 1C-b. The seam is the same either way.
    private final class Box {
        var scene = CanvasScene()
        var scraps: [CanvasNodeID: String] = [:]
    }

    private func wire(_ undo: CanvasUndo, to box: Box) {
        undo.readSnapshot = { (box.scene, box.scraps) }
        undo.applySnapshot = { box.scene = $0.scene; box.scraps = $0.scraps }
    }

    private func boxWithScrap() -> Box {
        let box = Box()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap,
                           origin: CGPoint(x: 100, y: 100), width: 240)
        n.cachedHeight = 80
        box.scene.insert(n)
        box.scraps[CanvasNodeID("a")] = "The falls at night."
        return box
    }

    func test_undoRestoresAMovedNode() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        }
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 900, y: 900))

        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
    }

    func test_redoReappliesTheMove() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        }
        m.undo()
        m.redo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 900, y: 900))
    }

    func test_undoRestoresADeletedScrapAndItsText() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Delete Scrap") {
            box.scene.remove(CanvasNodeID("a"))
            box.scraps[CanvasNodeID("a")] = nil
        }
        XCTAssertTrue(box.scene.isEmpty)

        m.undo()
        XCTAssertNotNil(box.scene.node(CanvasNodeID("a")))
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.",
                       "restoring a node without its words is not an undo")
    }

    /// A drag emits a position per frame. One ⌘Z must undo the whole gesture,
    /// not 60 of them.
    func test_oneDragIsOneUndoStep() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Move Scrap")
        for x in stride(from: CGFloat(110), through: 900, by: 10) {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: x, y: 100))
        }
        undo.endGesture()

        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
        XCTAssertFalse(m.canUndo, "the whole drag must collapse into one step")
    }

    /// A drag that starts and ends on the same pixel must not leave a step
    /// behind — otherwise ⌘Z after a stray click undoes the writer's last REAL
    /// edit while appearing to do nothing.
    func test_aGestureThatChangesNothingPushesNoUndoStep() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Move Scrap")
        undo.endGesture()
        XCTAssertFalse(m.canUndo)
    }

    func test_undoActionNamesAreWriterFacing() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 1, y: 1))
        }
        XCTAssertEqual(m.undoActionName, "Move Scrap")
    }

    func test_typingThenDraggingUndoesInReverseChronologicalOrder() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Typing") { box.scraps[CanvasNodeID("a")] = "The falls at noon." }
        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        }

        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at noon.",
                       "the drag came last, so it undoes first")
        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.")
    }

    /// Camera moves are navigation, not edits. Undoing a pan would be baffling.
    func test_panningAndZoomingAreNotUndoable() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)
        undo.noteCameraChanged()
        XCTAssertFalse(m.canUndo)
    }

    func test_nestedBeginsAreBalancedRatherThanRaising() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Outer")
        undo.beginGesture("Inner")     // a gesture arriving mid-gesture
        box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 5, y: 5))
        undo.endGesture()
        XCTAssertTrue(undo.isInGesture, "the outer gesture is still open")
        undo.endGesture()
        XCTAssertFalse(undo.isInGesture)

        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
    }

    func test_endWithoutBeginIsANoOpRatherThanACrash() {
        let undo = CanvasUndo(undoManager: manager())
        undo.endGesture()
        XCTAssertFalse(undo.isInGesture)
    }

    // MARK: - Granularity inside one visit

    /// A visit that ran to three sentences must not collapse into one ⌘Z.
    func test_breakingAGestureSplitsAVisitIntoSeparateSteps() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Edit Scrap")
        box.scraps[CanvasNodeID("a")] = "One."
        undo.breakGesture()
        XCTAssertTrue(undo.isInGesture, "the visit is still open")
        box.scraps[CanvasNodeID("a")] = "One. Two."
        undo.endGesture()

        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "One.")
        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.")
    }

    func test_breakingAGestureWithNothingTypedLeavesNoStepBehind() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Edit Scrap")
        undo.breakGesture()
        undo.breakGesture()
        undo.endGesture()
        XCTAssertFalse(m.canUndo, "a pause during which nothing was typed is not a step")
    }

    func test_breakingOutsideAGestureIsANoOp() {
        let undo = CanvasUndo(undoManager: manager())
        undo.breakGesture()
        XCTAssertFalse(undo.isInGesture)
    }

    /// Splitting an outer gesture from inside a nested one would close a bracket
    /// the caller still believes it holds.
    func test_breakingInsideANestedGestureIsANoOp() {
        let box = boxWithScrap()
        let undo = CanvasUndo(undoManager: manager())
        wire(undo, to: box)
        undo.beginGesture("Outer")
        undo.beginGesture("Inner")
        undo.breakGesture()
        undo.endGesture()
        XCTAssertTrue(undo.isInGesture, "the outer gesture must still be open")
        undo.endGesture()
        XCTAssertFalse(undo.isInGesture)
    }

    // MARK: - ScrapUndoBeat, the policy

    func test_aFinishedSentenceIsABoundary() {
        XCTAssertTrue(ScrapUndoBeat.completesASentence(before: "The falls at night",
                                                       after: "The falls at night."))
        XCTAssertTrue(ScrapUndoBeat.completesASentence(before: "", after: "?"))
    }

    func test_aPartialSentenceIsNotABoundary() {
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "The falls at nigh",
                                                        after: "The falls at night"))
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "", after: ""))
    }

    /// An ellipsis is one boundary, not three — and backing over a full stop is
    /// not a boundary at all.
    func test_repeatedTerminatorsAndDeletionsDoNotEachFire() {
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "Well.", after: "Well.."))
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "Well...", after: "Well.."))
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "Well.", after: "Well"))
    }

    func test_stillnessLongerThanTheBeatIsABoundary() {
        let now = Date()
        XCTAssertFalse(ScrapUndoBeat.hasGoneIdle(since: nil, now: now),
                       "the first keystroke of a visit ends nothing")
        XCTAssertFalse(ScrapUndoBeat.hasGoneIdle(
            since: now.addingTimeInterval(-ScrapUndoBeat.idleSeconds / 2), now: now))
        XCTAssertTrue(ScrapUndoBeat.hasGoneIdle(
            since: now.addingTimeInterval(-ScrapUndoBeat.idleSeconds - 0.1), now: now))
    }

    // MARK: - ⌘Z with a live editor

    private func layout(_ text: String) -> ScrapLayout {
        ScrapLayout(text: text, width: 240,
                    font: NSFont(name: "Iowan Old Style", size: 13) ?? .systemFont(ofSize: 13))
    }

    @discardableResult
    private func host(_ view: NSView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 100)
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSView(frame: frame)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }
    private var windows: [NSWindow] = []
    override func tearDown() { windows.removeAll(); super.tearDown() }

    /// I10. The mounted editor must not put its own step on the shared manager:
    /// one change would land twice, and the text view's copy would target an
    /// NSTextStorage that the snapshot's `rebuildLayouts()` has replaced — so the
    /// second ⌘Z would appear to do nothing.
    func test_typingIntoTheMountedEditorRegistersNothingOfItsOwn() {
        let m = manager()
        let container = ScrapEditorContainer(frame: .zero)
        container.canvasUndoManager = m
        container.mount(layout: layout("before"), unscaledSize: CGSize(width: 240, height: 100),
                        zoom: 1)
        host(container)

        container.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertFalse(m.canUndo,
                       "the text view registered a step of its own — with the "
                       + "canvas snapshot that is one change on the stack twice")
    }

    /// The whole shape, end to end: focus opens the gesture, typing runs through
    /// the shared stack, blur closes it, one ⌘Z takes the visit back.
    func test_oneUndoAfterTypingRestoresTheTextTheWriterStartedWith() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Edit Scrap")                       // focus in
        box.scraps[CanvasNodeID("a")] = "The falls at noon."   // several keystrokes
        box.scraps[CanvasNodeID("a")] = "The falls at noon, and the ponchos."
        undo.endGesture()                                     // focus out

        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.")
        XCTAssertFalse(m.canUndo,
                       "an uninterrupted run of typing with no sentence end and no "
                       + "pause is ONE step, not one per keystroke")
    }

    /// I11. `beginGesture` captures its baseline at focus-in and registers
    /// nothing until focus-out, so the manager stays live and undoable for the
    /// whole visit. If the writer presses ⌘Z mid-visit, that baseline is stale
    /// the moment the undo lands — and closing the gesture against it registers a
    /// step whose UNDO re-applies exactly what was just undone.
    func test_undoingWhileAScrapIsFocusedDoesNotResurrectTheUndoneEdit() {
        let box = boxWithScrap()                     // a = "The falls at night."
        var second = CanvasNode(id: CanvasNodeID("b"), kind: .scrap,
                                origin: CGPoint(x: 400, y: 0), width: 240)
        second.cachedHeight = 80
        box.scene.insert(second)
        box.scraps[CanvasNodeID("b")] = "ponchos"

        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        // Visit A and leave.
        undo.beginGesture("Edit Scrap")
        box.scraps[CanvasNodeID("a")] = "The falls at noon."
        undo.endGesture()

        // Visit B, press ⌘Z mid-visit, keep typing, then leave.
        undo.beginGesture("Edit Scrap")
        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.",
                       "precondition: ⌘Z reverted A")
        box.scraps[CanvasNodeID("b")] = "ponchos, and the man selling them"
        undo.endGesture()

        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("b")], "ponchos",
                       "the second ⌘Z must take back what was typed into B")
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.",
                       "closing the gesture re-applied the edit the writer had "
                       + "already undone — the gesture's baseline was never "
                       + "refreshed after applySnapshot")
    }

    func test_anUnwiredRecorderRecordsNothingRatherThanCrashing() {
        let m = manager()
        let undo = CanvasUndo(undoManager: m)   // no readSnapshot / applySnapshot
        undo.mutate("Move Scrap") { }
        XCTAssertFalse(m.canUndo)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasUndoTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasUndo' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/CanvasUndo.swift`**

```swift
import AppKit

/// Undo for the canvas.
///
/// Spec §10 left this open. The answer is a canvas-scoped `UndoManager`, NOT the
/// op log, and the reasoning must survive:
///
/// ADR 0023's unified undo appends COMPENSATING OPS to the op log. Canvas
/// geometry is derived state that may be deleted without loss (spec §8).
/// Putting it in the op log would make the sidecar the only record of a move —
/// no longer derived — which contradicts §8 directly. ⌘Z already means "undo
/// what is in front of you"; in the editor it runs the editor's own undo
/// manager. This is the same rule, not a new one.
///
/// **Snapshots, not per-property inverses.** 1C-b's region drags mutate a
/// region's frame AND every resident's origin; recording per-property inverses
/// for that is how you get a half-undone drag. `CanvasScene` is a value type
/// holding hundreds of nodes, so a snapshot per gesture is cheap and exactly
/// correct.
///
/// **The state is reached through two closures rather than owned**, because the
/// owner changes between plans: `CanvasView`'s `@State` in 1C-a, `CanvasModel`
/// in 1C-b Task 4. Only the closures get rebound; this class does not change.
///
/// **Scrap TEXT and scrap GEOMETRY share ONE stack, and only this class writes
/// to it.** The mounted `NSTextView` has `allowsUndo == false` (see
/// `ScrapLayout.makeEditor`) and registers nothing; `CanvasView` hands this
/// manager to `ScrapEditorHost`, whose container vends it down the responder
/// chain, so ⌘Z while a scrap is focused runs the canvas stack. If the text view
/// registered too, one change would land twice — and its copy would target an
/// `NSTextStorage` that the snapshot's `rebuildLayouts()` has replaced, so the
/// second ⌘Z would appear to do nothing.
///
/// **Granularity inside a scrap is the SENTENCE, not the visit and not the
/// word.** The outer bracket is focus; `breakGesture()` supplies the inner ones,
/// driven by `ScrapUndoBeat` — a finished sentence, or a beat of stillness.
/// Per-word is only reachable by giving the text view `allowsUndo`, which is the
/// double-registration defect above, and a break per word would also mean a
/// whole-scene snapshot per word.
///
/// **`beginGesture` opens NO `UndoManager` group**, and that is deliberate twice
/// over:
///
/// - `groupsByEvent` defaults to `true` and installs a run-loop observer that
///   opens an implicit top-level group per event. An explicit group of ours
///   cannot span an event boundary — and an "Edit Scrap" gesture spans as many
///   events as the writer types keystrokes.
/// - `UndoManager` pushes a closed group whether or not anything was registered
///   inside it. Opening one at `beginGesture` would leave a step behind after a
///   gesture that changed nothing, and ⌘Z after a stray click would undo the
///   writer's last REAL edit while appearing to do nothing.
///
/// So `beginGesture` takes a snapshot, and `endGesture` opens/registers/names/
/// closes synchronously inside one event. **Tests must set `groupsByEvent` to
/// `false`**: calling `undo()` synchronously outside a run loop while the
/// implicit group is open raises `NSInternalInconsistencyException`.
///
/// **Camera changes are NOT undoable** — panning and zooming are navigation, and
/// undoing a pan would be baffling.
final class CanvasUndo {

    typealias Snapshot = (scene: CanvasScene, scraps: [CanvasNodeID: String])

    /// Read the current state. Set by the owner.
    var readSnapshot: (() -> Snapshot)?
    /// Put a snapshot back. Set by the owner.
    var applySnapshot: ((Snapshot) -> Void)?

    private let undoManager: UndoManager
    private var depth = 0
    private var snapshotAtGestureStart: Snapshot?
    private var gestureName = ""

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    var isInGesture: Bool { depth > 0 }

    /// Open a gesture: take a snapshot, remember the name. **No `UndoManager`
    /// call happens here** — see the class doc. Nested calls are absorbed, so a
    /// gesture arriving mid-gesture cannot leave the manager unbalanced.
    func beginGesture(_ name: String) {
        depth += 1
        guard depth == 1 else { return }
        snapshotAtGestureStart = readSnapshot?()
        gestureName = name
    }

    /// Close the gesture, registering an undo only if the state actually moved.
    /// The group is opened HERE and closed on the next line, so it never spans an
    /// event boundary and an unchanged gesture pushes nothing at all.
    func endGesture() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }

        defer {
            snapshotAtGestureStart = nil
            gestureName = ""
        }
        guard let before = snapshotAtGestureStart, let now = readSnapshot?() else { return }
        guard before.scene != now.scene || before.scraps != now.scraps else { return }

        undoManager.beginUndoGrouping()
        register(before)
        undoManager.setActionName(gestureName)
        undoManager.endUndoGrouping()
    }

    /// Close the open gesture and immediately open another under the same name.
    ///
    /// This is what gives a long visit to a scrap more than one ⌘Z. `endGesture`
    /// registers nothing when the snapshot is unchanged, so a break at a moment
    /// nothing was typed costs a snapshot read and leaves the stack alone.
    ///
    /// A no-op outside a gesture, and a no-op inside a NESTED one — splitting an
    /// outer gesture from within an inner one would close a bracket the caller
    /// still believes it holds.
    func breakGesture() {
        guard depth == 1 else { return }
        let name = gestureName
        endGesture()
        beginGesture(name)
    }

    /// `beginGesture` / body / `endGesture`, for the common one-shot case.
    func mutate(_ name: String, _ body: () -> Void) {
        beginGesture(name)
        body()
        endGesture()
    }

    /// Deliberately does nothing. Named rather than absent so the next author
    /// sees the decision instead of assuming an omission.
    func noteCameraChanged() { }

    /// Register `snapshot` as the state to return to. On undo it re-registers
    /// the state it replaced, which is what gives redo for free — and every
    /// re-registration lands inside the group `UndoManager` opens around an
    /// undo, so the redo is one step too.
    private func register(_ snapshot: Snapshot) {
        undoManager.registerUndo(withTarget: self) { target in
            // `readSnapshot` is OPTIONAL — an unwired recorder must record
            // nothing rather than trap.
            guard let current = target.readSnapshot?() else { return }
            target.register(current)
            target.applySnapshot?(snapshot)

            // The writer pressed ⌘Z with a scrap still focused, so a gesture is
            // open and its baseline was captured BEFORE this undo ran. Left
            // alone, `endGesture` would diff against that stale baseline and
            // register a step whose UNDO re-applies exactly what the writer just
            // undid: type in A, click into B, ⌘Z (A reverts), type in B, click
            // out — and the next ⌘Z brings A's discarded text back. Re-baseline
            // on the state the undo produced.
            if target.depth > 0 {
                target.snapshotAtGestureStart = target.readSnapshot?()
            }
        }
    }
}

/// When a run of typing inside one scrap becomes its own undo step.
///
/// Pure, so the policy is testable without a run loop, a timer or a text view.
/// `CanvasView.syncActiveEdit` asks these two questions on every change and
/// calls `CanvasUndo.breakGesture()` when either says yes.
///
/// Neither rule needs a timer: an idle beat is noticed retroactively at the next
/// keystroke, which is the only moment it can matter.
enum ScrapUndoBeat {

    /// Stillness this long ends a step. Long enough that a pause for thought
    /// mid-sentence is not chopped up, short enough that coming back to a scrap
    /// after a break does not extend the previous ⌘Z.
    static let idleSeconds: TimeInterval = 1.5

    /// Characters that end a sentence for this purpose. Over-eager on "Mr." and
    /// "e.g.", and that is fine — an extra boundary gives the writer a finer
    /// ⌘Z, never a coarser one.
    private static let terminators: Set<Character> = [".", "!", "?"]

    /// True when the writer has been still long enough that the run of typing
    /// before the pause should stand as its own step. Asked BEFORE the new
    /// keystroke is folded in, so the step that closes ends at the pause.
    static func hasGoneIdle(since last: Date?, now: Date) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) >= idleSeconds
    }

    /// True when this edit just finished a sentence — the text now ends in a
    /// terminator and did not before. Asked AFTER the keystroke is folded in, so
    /// the full stop belongs to the step it closes.
    ///
    /// Deliberately blind to edits made away from the end of the text: the idle
    /// beat covers those, and a rule that fired on any terminator anywhere would
    /// fire on a deletion too.
    static func completesASentence(before: String, after: String) -> Bool {
        guard let now = after.last, terminators.contains(now) else { return false }
        guard let previous = before.last else { return true }
        return !terminators.contains(previous)
    }
}
```

- [ ] **Step 4: Wire it into `CanvasView`**

Four edits to `Maugham/Canvas/CanvasView.swift`.

**(a)** Own the manager and the recorder:

```swift
    /// Scoped to the canvas, not the window. `@Environment(\.undoManager)` would
    /// give a window-lifetime manager, and a persona switch mid-drag would then
    /// leave a half-open group on it.
    @State private var undoManager = UndoManager()
    @State private var undo: CanvasUndo?
```

**(b)** Build and wire it in `load()`, after the store is set up:

```swift
        let recorder = CanvasUndo(undoManager: undoManager)
        recorder.readSnapshot = { (scene, scraps) }
        recorder.applySnapshot = { snapshot in
            scene = snapshot.scene
            scraps = snapshot.scraps
            rebuildLayouts()            // heights are derived; re-measure them
            store?.scheduleSave(scene: scene, scraps: scraps)
        }
        undo = recorder
```

**(c)** Replace the two `undoManager: nil` placeholders from Tasks 10 and 13 with `undoManager: undoManager` — in `CanvasEventView(...)` and in `ScrapEditorHost(...)`. The event view vends it to the responder chain so ⌘Z works with nothing focused; the editor container vends it to the text view so ⌘Z *while editing* runs the same stack (the text view registers nothing of its own — `allowsUndo == false`).

**(d)** Bracket every mutating gesture. In `handleDrag`:

```swift
        case .began:
            guard editingNodeID == nil else { return }
            momentum.stop()
            interaction.begin(at: contentPoint, in: scene)
            if interaction.isActive {
                undo?.beginGesture(interaction.isResizing ? "Resize Scrap" : "Move Scrap")
            }
```

```swift
        case .ended:
            guard interaction.isActive else { return }
            let wasResizing = interaction.isResizing
            let flick = interaction.end()
            if wasResizing {
                rebuildLayouts()
            } else if let flick {
                momentum.launch(flick.id, velocity: flick.velocity)
            }
            undo?.endGesture()
            store?.scheduleSave(scene: scene, scraps: scraps)
            revision += 1
```

Momentum's coast is deliberately **inside** no gesture: it is the tail of the drag the writer already made, and the undo snapshot taken at `.began` predates it, so one ⌘Z returns the card to where it started rather than to where it stopped skating.

**(e)** Bracket a visit to a scrap, and break it at sentences and pauses. The gesture opens when the scrap takes focus and closes when focus leaves; inside the visit `syncActiveEdit` splits it. It must NOT open and close around each keystroke — that is one ⌘Z per character.

`syncActiveEdit` grows the two breaks, **behind a `fromKeystroke` flag**. Two things about the shape are load-bearing:

- **Where each break sits relative to the fold.** The idle break goes **before** it, so the step that closes ends where the writer paused; the sentence break goes **after** it, so the full stop belongs to the step it closes.
- **Only a real keystroke may move an undo boundary.** `syncActiveEdit` has three callers, and the other two — `.onDisappear` and `CanvasStore.beforeFlush` — run at teardown and at app quit. A writer who paused for two seconds and then quit would otherwise trip the idle break at `beforeFlush`, closing a step and reopening a gesture on a view that is going away. That is the half-open bracket this task's `groupsByEvent` discussion is about, arriving from the save path instead of the focus path. The default is `false` so the housekeeping callers need no change.

```swift
    private func syncActiveEdit(fromKeystroke: Bool = false) {
        guard let id = editingNodeID, let layout = layouts[id] else { return }
        let updated = layout.text
        guard scraps[id] != updated else { return }
        let previous = scraps[id] ?? ""
        let now = Date()

        // BEFORE the fold: the writer stopped for a beat, so what they typed
        // before the pause stands as its own step.
        if fromKeystroke, ScrapUndoBeat.hasGoneIdle(since: lastKeystrokeAt, now: now) {
            undo?.breakGesture()
        }

        scraps[id] = updated
        scene.setCachedHeight(
            CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight), for: id)
        revision += 1
        store?.scheduleSave(scene: scene, scraps: scraps)

        // AFTER the fold: the sentence just ended, and the terminator belongs to
        // the step that ends with it.
        if fromKeystroke,
           ScrapUndoBeat.completesASentence(before: previous, after: updated) {
            undo?.breakGesture()
        }
        if fromKeystroke { lastKeystrokeAt = now }
    }
```

and the editor's callback is the one caller that passes `true` — in `mountedEditor`:

```swift
                            onTextChanged: { syncActiveEdit(fromKeystroke: true) })
```

`commitActiveEdit` becomes the closing half:

```swift
    /// The outer undo boundary: focus is leaving the scrap. `syncActiveEdit` has
    /// already folded the text in (on every keystroke) and broken the gesture at
    /// each sentence and pause; this closes whatever is still open. `endGesture`
    /// registers nothing if the text is unchanged, so clicking in and straight
    /// back out leaves no step behind.
    private func commitActiveEdit() {
        syncActiveEdit()
        undo?.endGesture()
        lastKeystrokeAt = nil
        sceneRevision += 1
    }
```

and both focus-in paths in `handleClick` open it — the existing scrap:

```swift
            editingNodeID = node.id
            straighten.focus(node.id)
            undo?.beginGesture("Edit Scrap")
```

and the create path, where the creation itself is its own step first:

```swift
        } else if scene.topmostNode(at: contentPoint) == nil {
            var id = CanvasNodeID("")
            undo?.mutate("New Scrap") {
                id = CanvasInteraction.createScrap(at: contentPoint, in: &scene)
                scraps[id] = ""
            }
            rebuildLayouts()
            editingNodeID = id
            caretIndex = 0
            straighten.focus(id)
            // Whatever the writer now types is a second, separate step.
            undo?.beginGesture("Edit Scrap")
        }
```

`.onDisappear` keeps calling `syncActiveEdit()` — with `fromKeystroke` left at its default `false` — rather than `commitActiveEdit()`: the words must be written, but there is no writer left to press ⌘Z at teardown, and closing a gesture during a view's disappear is the kind of state mutation SwiftUI is entitled to complain about. `CanvasStore.beforeFlush` is the same case at app quit.

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasUndoTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 22 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasUndo.swift Maugham/Canvas/CanvasView.swift \
        MaughamTests/Canvas/CanvasUndoTests.swift project.yml
git commit -m "feat(canvas): canvas-scoped snapshot undo covering geometry and scrap text

Resolves spec 10's undo question: an UndoManager scoped to the canvas,
not op-log compensating ops — canvas state is derived (8) and putting it
in the op log would stop it being derived. Snapshots rather than
per-property inverses, so 1C-b's region drags need no new machinery. The
state is reached through two closures, so 1C-b Task 4 can move ownership
to CanvasModel without touching this class. The mounted NSTextView has
allowsUndo == false and registers nothing, so one change is one step;
granularity inside a scrap is the SENTENCE, via a gesture break on a
finished sentence or a beat of stillness. An undo serviced mid-gesture
re-baselines that gesture, so closing it cannot resurrect the edit the
writer just undid."
```

---

### Task 16: Performance bounds — resolving spec §10

**Files:**
- Test: `MaughamTests/Canvas/CanvasPerformanceProbeTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNode`, `CanvasNodeID` (Task 1); `CanvasCamera` (Task 4); `CanvasRenderer.visibleNodes(in:camera:viewSize:)` (Task 7).
- **Produces:** `CanvasPerformanceProbeTests.supportedNodeCount = 2_000`, the number Task 17's AREA.md records. No production code.

**Spec §10 left this open:** *"Performance bounds. What node count must stay smooth. §7A.1 settles how it virtualises; the open part is the number."*

**Decision: 2,000 nodes, as a fixture-gated probe, not a wall-clock assertion.** `TypingLatencyProbeTests` (`MaughamTests/Performance/TypingLatencyProbeTests.swift`) is the named precedent — it is the house pattern for exactly this, because a wall-clock assertion on CI hardware is a flaky test that gets disabled and then protects nothing.

The number: tldraw ships a hard 4,000-shape cap and freezes zoom above 500 shapes; Excalidraw degrades around 5,000. A Playlist-scale collection is tens of nodes. 2,000 is far above any real canvas and well below where the surveyed tools break, so it is a ceiling that catches an algorithmic regression rather than a number the writer will ever meet.

What is actually asserted is **complexity, not milliseconds**: culling must keep the drawn set proportional to the viewport, not to the scene.

**The fixture is a fixed 20-column grid, and the arithmetic is worked here so nobody has to trust it.** An earlier draft laid nodes out at `x = (i % 100) * 300` — which makes the *number of rows* depend on the node count, so a 200-node scene covered 2 rows and a 2,000-node scene covered 4, and the "same camera sees the same count" assertion compared 8 against 16 and could never pass. With 20 columns:

- Node `i` sits at `x = (i % 20) * 300`, `y = (i / 20) * 200`, size 240 × 100.
- The viewport is 1200 × 800 at zoom 1, so the visible content rect is `(0, 0, 1200, 800)`.
- Columns intersecting it: x = 0, 300, 600, 900 → **4**. (x = 1200 gives `[1200, 1440]`, which only touches the edge, and `CGRect.intersects` is false for edge contact.)
- Rows intersecting it: y = 0, 200, 400, 600 → **4**. (y = 800 gives `[800, 900]`, edge contact again.)
- 200 nodes fill rows 0–9; 2,000 nodes fill rows 0–99. Both cover rows 0–3 completely.
- So both yield **4 × 4 = 16**. The assertion is meaningful and passes.

- [ ] **Step 1: Write the test**

```swift
import XCTest
@testable import Maugham

final class CanvasPerformanceProbeTests: XCTestCase {

    /// The bound spec §10 asked for. Far above any real canvas (a Playlist-scale
    /// collection is tens of nodes) and below where tldraw (4,000) and
    /// Excalidraw (~5,000) degrade.
    static let supportedNodeCount = 2_000

    /// A FIXED 20-column grid, so the grid's extent in both axes is independent
    /// of the node count. Cards are 240x100 on a 300x200 pitch, so a 1200x800
    /// viewport at zoom 1 admits columns x=0,300,600,900 and rows y=0,200,400,600
    /// — 4 x 4 = 16 nodes — for ANY count of 80 or more. If the columns were
    /// derived from the count, a bigger scene would be a taller grid and the
    /// culling assertion below would compare two different geometries.
    private static let columns = 20

    private func bigScene(_ count: Int) -> CanvasScene {
        var s = CanvasScene()
        for i in 0..<count {
            var n = CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i % Self.columns) * 300,
                                               y: CGFloat(i / Self.columns) * 200),
                               width: 240)
            n.cachedHeight = 100
            s.insert(n)
        }
        return s
    }

    private let viewSize = CGSize(width: 1200, height: 800)

    /// Guard the fixture itself. If this fails, the culling assertion below is
    /// comparing two different pictures and its result means nothing.
    func test_theFixtureCoversTheViewportAtEveryScaleUnderTest() {
        for count in [200, Self.supportedNodeCount] {
            XCTAssertEqual(
                CanvasRenderer.visibleNodes(in: bigScene(count), camera: CanvasCamera(),
                                            viewSize: viewSize).count,
                16, "the \(count)-node fixture does not fill the viewport as computed")
        }
    }

    /// The property §7A.1 depends on: the drawn set is proportional to the
    /// VIEWPORT, not to the scene. This is a complexity assertion, not a
    /// wall-clock one — a millisecond budget on CI hardware is a flaky test
    /// that gets disabled and then protects nothing (TypingLatencyProbeTests
    /// is the house precedent).
    func test_culledSetDependsOnViewportNotSceneSize() {
        let small = CanvasRenderer.visibleNodes(in: bigScene(200), camera: CanvasCamera(),
                                                viewSize: viewSize).count
        let large = CanvasRenderer.visibleNodes(in: bigScene(Self.supportedNodeCount),
                                                camera: CanvasCamera(),
                                                viewSize: viewSize).count
        XCTAssertEqual(small, large,
                       "a 10x larger scene must not draw more nodes at the same "
                       + "camera — culling is the whole of virtualisation")
    }

    func test_aFullSceneStillCullsToAHandful() {
        let visible = CanvasRenderer.visibleNodes(in: bigScene(Self.supportedNodeCount),
                                                  camera: CanvasCamera(),
                                                  viewSize: viewSize)
        XCTAssertLessThan(visible.count, 60)
    }

    /// A fixture-gated probe: measured, reported, and only failed on an
    /// order-of-magnitude regression.
    func test_cullingAtTheSupportedBoundIsNotPathological() {
        let scene = bigScene(Self.supportedNodeCount)
        let camera = CanvasCamera()

        let start = Date()
        for _ in 0..<60 {
            _ = CanvasRenderer.visibleNodes(in: scene, camera: camera, viewSize: viewSize)
        }
        let perFrame = Date().timeIntervalSince(start) / 60 * 1000
        print("[probe] cull of \(Self.supportedNodeCount) nodes: \(String(format: "%.3f", perFrame)) ms/frame")

        // 8ms is half a 60Hz frame spent purely culling — an absurd budget that
        // only an algorithmic regression (an accidental O(n²)) could exceed.
        XCTAssertLessThan(perFrame, 8.0,
                          "culling got dramatically slower — suspect an O(n²) in "
                          + "CanvasScene.nodes or a lost early-out")
    }

    func test_zoomingOutFarStillTerminatesQuickly() {
        let scene = bigScene(Self.supportedNodeCount)
        var camera = CanvasCamera()
        camera.zoom = CanvasCamera.zoomRange.lowerBound
        let start = Date()
        let visible = CanvasRenderer.visibleNodes(in: scene, camera: camera, viewSize: viewSize)
        print("[probe] zoomed-out cull returned \(visible.count) nodes in "
              + "\(String(format: "%.3f", Date().timeIntervalSince(start) * 1000)) ms")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    /// Hit testing walks the same sorted list in reverse and runs on every
    /// click. A regression here is felt directly.
    func test_hitTestingAtTheSupportedBoundIsNotPathological() {
        let scene = bigScene(Self.supportedNodeCount)
        let start = Date()
        for _ in 0..<60 { _ = scene.topmostNode(at: CGPoint(x: 610, y: 410)) }
        let perClick = Date().timeIntervalSince(start) / 60 * 1000
        print("[probe] hit test over \(Self.supportedNodeCount) nodes: \(String(format: "%.3f", perClick)) ms")
        XCTAssertLessThan(perClick, 8.0)
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasPerformanceProbeTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 6 tests. Record the three `[probe]` figures in the task report — they are the baseline a future regression is measured against.

**If `test_theFixtureCoversTheViewportAtEveryScaleUnderTest` fails**, the fixture is wrong and the culling assertion beside it is meaningless — fix the fixture arithmetic against the table in this task, not the assertion.

**If `test_culledSetDependsOnViewportNotSceneSize` fails while the fixture guard passes**, culling is genuinely broken and the architecture's central claim with it. Stop and fix `CanvasRenderer.visibleNodes` / `CanvasScene.nodes(intersecting:)`; do not relax the assertion.

- [ ] **Step 3: Commit**

The supported-node-count line goes into `Maugham/Canvas/AREA.md`, which **Task 17 creates** — so it is written there, not here, and this commit touches only the test file.

```bash
git add MaughamTests/Canvas/CanvasPerformanceProbeTests.swift project.yml
git commit -m "test(canvas): performance bound — 2,000 nodes, culling and hit-test probes

Resolves spec 10's performance question. Asserts complexity (the drawn
set tracks the viewport, not the scene) rather than milliseconds, per the
TypingLatencyProbeTests precedent, and guards its own fixture — a grid
whose height varied with the node count made the central assertion
unpassable in an earlier draft."
```

---

### Task 17: Docs, AREA.md and the ADR

**Files:**
- Create: `Maugham/Canvas/AREA.md`
- Create: `docs/adr/0026-planning-canvas-rendering.md`
- Modify: `docs/adr/README.md`
- Modify: `CLAUDE.md` (per-area pointer table, tripwire table)
- Modify: `docs/guide/` (the topic covering personas)
- Modify: `docs/roadmap.md`, `docs/problem-map.md`

**Interfaces:**
- **Consumes:** every symbol built in Tasks 1–16; `CanvasPerformanceProbeTests.supportedNodeCount` (Task 16) as the number AREA.md records.
- **Produces:** documentation only. No Swift.

Rule 10 of the default workflow: when a roadmap item flips •→✓, sweep sibling docs for now-false claims **in the same commit**. Rule 7: help/docs describe what *ships* — so the guide says the canvas draws scraps, and says nothing about dragging research in, which is 1C-d.

- [ ] **Step 1: Write `Maugham/Canvas/AREA.md`**

Cover, at minimum, each of these — a bullet per line, with the symptom named where there is one:

- **The architecture in three sentences, and why the alternative lost.** Link `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`. Someone will propose `NSScrollView` again; the note is the answer.
- **The three `ScrapLayout` requirements, verbatim, with the symptom each produces when broken.** The `attributedString` one especially: it fails silently and looks like a UI bug rather than a wiring bug.
- **Card metrics live in `CanvasCardMetrics` and nowhere else.** A second spelling of the inset puts drawn text and edited text on different rects — the §7A.2 jump by the back door.
- **The whole card carries its seeded angle, and focus straightens it** (§7A.5). The focused card animates to level over ~120 ms and settles back on blur; that is the focus affordance. Three parts of it are load-bearing and each has failed in draft:
  - **The editor MOUNTS on the click; it becomes VISIBLE on `isLevel`.** Two properties, and merging them back into one is how this has failed twice, in opposite directions. `CanvasView.mountedEditorNodeID` is `editingNodeID` — the editor exists, is first responder and takes keystrokes from frame one, or a double-click-and-type loses its first character or two. `CanvasView.visibleEditorNodeID` adds `straighten.isLevel(_:)`, and the *same* property feeds both `ScrapEditorHost.isEditorVisible` and `CanvasRenderer.draw`'s `visibleEditorNodeID:` — so the card's own text stays on screen and rotating (live, off the shared `NSTextStorage`) right up to the one frame the editor takes over. Make the editor visible on the click instead and axis-aligned glyphs land at the unrotated text origin over a still-tilted card with the drawn text already suppressed: they snap straight and the card catches up behind them, which is §7A.2's failure by §7A.5's own route.
  - **While it is invisible the editor is also transparent to the pointer.** `ScrapEditorContainer.isEditorVisible` drives `alphaValue` *and* `hitTest(_:)`, so through the straighten a click or a pinch reaches `CanvasEventNSView` — whose space is canvas space — instead of being resolved against the editor's unrotated box under a card up to 0.6° off level. That is what keeps `ScrapEditorGeometry.viewPoint`'s "no rotation term" honest: the function is only ever reached from an event the container received, and it receives none while invisible. Never `isHidden`/`.hidden()` — AppKit moves first responder off a hidden view, which loses the keystrokes the early mount exists to keep.
  - **`CanvasFocusStraighten.isSettled` means "every card is at ITS target", not "every progress value is 1".** The naive spelling reports settled the instant focus leaves — the entry is still at 1 while its target is now 0 — so `TimelineView` pauses, `step` is never called again, and the card stays level for the rest of the session.
  - **The caret index is resolved in the card's unrotated space *before* the animation starts**, or the click point moves out from under the cursor. `CanvasRenderer.cardTransform` is the one definition of the card rotation; `localPoint` inverts *it*, not a second hand-written `R(−θ)`. A grep test forbids `rotate(by:)`/`rotationEffect` anywhere in this area, because a flipped convention doubles the caret error instead of removing it and a round-trip test passes either way.

  **Do not write down the old claim that an `NSTextView` cannot be rotated** — `NSView.frameRotation` rotates a real view and renders it crisply; the reason the editor is level is the design, not AppKit.
- **Hit testing is on the unrotated rect, and that band is at the resize corner.** Worst case is `r·θ` ≈ 1.4 pt at the corner of a default 240×80 card, growing with the diagonal. It sits exactly where `CanvasRenderer.resizeHandle` draws and `CanvasInteraction.begin` tests — not somewhere a writer never aims — and is accepted because 1.4 pt is inside pointer slop and the 14 pt target absorbs it.
- **The resize TARGET is the whole 14 pt corner square; the MARK is the triangle below its hypotenuse.** One constant fixes the size of both so they cannot drift; the shapes differ deliberately, because a target larger than its mark forgives a near miss. Do not shrink the target to the ink.
- **`CanvasScene.nodes` sorts on every access.** Per-frame and per-`body` callers use `count` or `unorderedNodes`; `topmostNode(at:)` and `nodes(intersecting:)` filter first and order the survivors. `CanvasAccessibility.summary` reading `scene.nodes.count` from `body` was a 2,000-element sort per body evaluation.
- **Layer order: ground → drawn → events → editor (frontmost).** With the event view in front, click-to-place-caret, drag-select and double-click-word all die and the surface reads as "typing does nothing". `CanvasCompositionTests` pins it.
- **Ground beneath, never an overlay**, and what happens if you get it wrong (a placeholder render, plus a console warning).
- **The mounted editor's focus is requested, not taken** — `makeNSView` has no window yet, so `makeFirstResponder` there is a silent no-op.
- **`mount` rebinds on layout identity, not on `textView == nil`** — otherwise clicking from scrap A to scrap B keeps editing A, and a subview count cannot tell.
- **Bounds scaling for the zoomed editor**; never `.scaleEffect`; never re-layout.
- **`layouts` holds reference types in `@State`.** Typing mutates in place, so the `Canvas` will not redraw without the `revision` counter — and `revision` must be read in `body`, not inside the draw closure.
- **Two counters, and they are not interchangeable.** `revision` is the redraw counter and ticks once per animation frame. `sceneRevision` is the structural one — load, create, delete, undo, the end of a drag or resize, momentum coming to rest, leaving a scrap — and it is what the accessibility tree is keyed on. Keying anything scene-proportional on `revision` runs it at 60–120 Hz through every drag, coast and straighten.
- **The writer's words leave the editor on every keystroke.** `ScrapEditorContainer` is the text view's delegate; `textDidChange` → `syncActiveEdit()` → model + debounced save. Named symptom if it is ever removed: type into a new scrap, quit without clicking away, and the scrap comes back empty — plus the card never grows while you type. Three commit points, all required: on change, on `.onDisappear`, and via `CanvasStore.beforeFlush`.
- **`canvas.json` is derived and deletable; `canvas.md` is content and is not.**
- **`CanvasStore.flush()` takes no arguments** and covers app quit via `NSApplication.willTerminateNotification`, because `.onDisappear` does not fire on quit. The observer takes `queue: nil` — with a queue the block is enqueued and the hop may never run before the process exits.
- **The crash floor: a force-quit loses up to 750 ms of typing since the writer last paused.** That matches `DocumentStore`'s autosave debounce, so it is the same number a manuscript gives — but it is **not** the same guarantee. A manuscript has the op log behind it: the ops are appended and a crash costs at most the debounce window of a *rendered* file. The canvas has no op log, so `canvas.md` and `canvas.json` are the only records and 750 ms of scrap text is genuinely gone. State it that way; do not let "matches `DocumentStore`" imply parity.
- **A `NotificationCenter.default.post(` anywhere in this area or its tests needs `// adr-0021-ok:`** on the line the call starts. The ADR 0021 post pattern is unconditional; only the *subscribe* patterns are scoped to `.maugham` names.
- **Undo is snapshot-based and canvas-scoped**, and reaches state through two closures so 1C-b can move ownership to `CanvasModel`. `beginGesture` opens no `UndoManager` group — a group cannot span an event boundary (and an "Edit Scrap" gesture spans as many events as keystrokes), and a closed empty group still pushes a step. Tests must set `groupsByEvent = false`; production must not.
- **Only a real keystroke may move an undo boundary.** `syncActiveEdit(fromKeystroke:)` defaults to `false`, and the two housekeeping callers — `.onDisappear` and `CanvasStore.beforeFlush` — take that default. Without the flag, a writer who pauses and then quits trips the idle break inside `beforeFlush`, which closes a step and reopens a gesture on a view that is going away.
- **An undo serviced while a gesture is open re-baselines that gesture.** The baseline is captured at focus-in and nothing is registered until focus-out, so a ⌘Z mid-visit leaves it stale: close the gesture against it and you register a step whose *undo* re-applies what the writer just undid. The one line that fixes it lives at the end of `CanvasUndo.register`'s closure. Closing the gesture before servicing the undo instead needs `NSUndoManagerWillUndoChange`, and registering while the manager is mid-undo makes the registration a *redo*.
- **The mounted editor has `allowsUndo = false`.** Snapshots own scrap text. If the text view registered too, one change would land on the stack twice, and its copy would target an `NSTextStorage` that `rebuildLayouts()` has replaced — so the second ⌘Z would appear to do nothing. **Granularity inside a scrap is the sentence:** the outer bracket is focus, and `breakGesture()` splits the visit on a finished sentence or `ScrapUndoBeat.idleSeconds` of stillness. Per-word is only reachable through `allowsUndo`, which is the defect above, and would also mean a whole-scene snapshot per word. This cost is writer-facing — the guide's persona topic says what ⌘Z does inside a scrap, and that sentence is part of the contract, not a nicety.
- **We own the accessibility tree** (§7A.6) — every node, all of them, rows-then-columns; never `.accessibilityElement(children: .ignore)` on the stack. Two rules keep it off the frame path, and both are needed:
  - Elements carry **content**-space frames and are rebuilt from `.onChange(of: sceneRevision)`, never inside `body` and **never from `revision`**: `revision` is bumped by `handleDrag(.changed)` and by the timeline's per-frame `.onChange(of: context.date)`, so keying the tree on it sorts the scene and copies every scrap's string at 60–120 Hz through any drag, coast or straighten.
  - The synthetic children live in `CanvasAXChildren`, used with `.equatable()`. Inline in `body` the `ForEach` reads `camera` and so rebuilds N views per frame. Extracted, SwiftUI skips it unless the elements or the camera actually moved — which covers every animation path here. A pan or a zoom does still rebuild it; that is accepted, bounded by the 2,000-node number, and the thing to verify before reaching for `.scaleEffect` over the AX layer is whether SwiftUI resolves accessibility frames through it at all.
- **Supported scale: 2,000 nodes.** Not a hard cap — nothing enforces it — but the number the culling probe defends. Above it, expect the draw pass rather than the culling to become the limit. tldraw caps at 4,000; Excalidraw degrades near 5,000.
- **The test-harness note:** `NSTextView.mouseDown` runs a modal event-tracking loop, so a post-then-pump harness deadlocks. Post both mouseDown and mouseUp before pumping — and every negative result needs a control that passed.
- **What 1C-a deliberately does not do:** item nodes render as placeholders; the drop target, image handling and title resolution are 1C-d; regions are 1C-b; lines and promotion are 1C-c. **This is a slice boundary, not a milestone one** — spec §8A.1 puts images inside M1C, and nothing here may be cited as authorising their omission from it.

- [ ] **Step 2: Write ADR 0026**

Check the highest existing ADR number first — 0025 is the persona shell, so 0026 unless something landed since:

```bash
ls docs/adr/ | sort | tail -3
```

The ADR records, with the spike's measurements as evidence. **Every one of these is a decision, not a deviation** — 1C-a takes no deviations from the spec:

1. **A drawn canvas over hosted views**, and the disqualification of `NSScrollView` magnification (SwiftUI content reports the same `.global` frame at every zoom; above ~2× clicks stop registering entirely).
2. **The shared-TextKit rule** — one layout stack for drawn and edited text — and the three requirements it comes with.
3. **Scrap text in `canvas.md`, layout in `.maugham/canvas.json`**, and why the split is the point.
4. **The whole card carries its seeded angle; focus straightens it over ~120 ms** (spec §7A.5). Record why this makes §7A.2 *easier*: the editor is always axis-aligned when it becomes the visible text, so the glyph-origin pin compares two unrotated layouts and `.rotationEffect` never arises. Record that "always" is enforced by a **gate on visibility, not on existence**, and record both failures it sits between, because they pull in opposite directions: making the editor visible on the click blanks the drawn text for the whole animation and lands straight glyphs over a tilted card; deferring the *mount* to `CanvasFocusStraighten.isLevel(_:)` leaves ~120 ms with no first responder, so a double-click-and-type loses its opening characters. The resolution is two properties — `mountedEditorNodeID` (the editor exists, from the click) and `visibleEditorNodeID` (the editor is the visible text, from `isLevel`) — with the second feeding the editor's visibility and the renderer's text suppression alike, so they flip on one frame and the swap reveals only what was already on screen. Record the corollary that keeps the geometry honest: while invisible the editor does not hit-test either, so no click or pinch is ever resolved against its unrotated box under a tilted card. Record the caret rule — resolved in the card's unrotated space at click time, before the animation — and that there is exactly one definition of the card rotation (`cardTransform`), used forwards by the draw pass and inverted by the caret, because a second one is a sign convention nothing can check. Record that the animation is interpolated per frame on the same clock as §7.3's momentum. **Do not restate the earlier, false claim that an `NSTextView` cannot be rotated**; `NSView.frameRotation` does exactly that, crisply.
5. **Undo is a canvas-scoped snapshot `UndoManager`, not op-log compensating ops**, because canvas state is derived (§8) and op-logging it would stop it being derived. Record the second half too: the mounted editor has `allowsUndo = false`, so one change is one step. Record the granularity decision **and the option that was rejected**, so it is not relitigated: inside a scrap the boundary is the **sentence** — the outer bracket is focus, and `breakGesture()` splits the visit on a finished sentence or a beat of stillness. **Per-word was rejected**: it is only reachable by handing undo back to the text view (`allowsUndo = true`), which puts one change on the stack twice and leaves the text view's copy pointed at an `NSTextStorage` that `rebuildLayouts()` has orphaned — so the second ⌘Z appears to do nothing; and a gesture break per word would mean a whole-scene snapshot per word, when the snapshot is the thing that makes 1C-b's region drags correct. **Per-visit was also rejected** as too coarse for a scrap that ran to a paragraph. State the residual cost in writer's terms, and note that the guide says it too.
6. **We own the canvas accessibility tree**, resolving §7A.6's "not optional in a writing tool".
7. **1C-a ships scraps only; item nodes are placeholders and belong to 1C-d.** Record it as a decision about the *order of work*, with the boundary stated explicitly: spec §8A.1 places images **inside milestone M1C**, so this is a slice boundary and never a licence to ship M1C without them. Record what 1C-d owes: the drop target, `DropClassification` for browser drags, a `CGImageSource` thumbnail path and a bounded cache keyed by path (tripwire 22).

Cite the constitution principles by name, per CLAUDE.md — including **must #1, *the words are safe***, which is the principle the three commit points in `CanvasView` exist to satisfy.

Add the row to `docs/adr/README.md`.

- [ ] **Step 3: Add the tripwires**

Add to CLAUDE.md's tripwire table (numbers follow the highest currently present — 24 at time of writing, so 25–30; re-check the highest before you write them, and renumber the whole block if something landed in between):

| # | Rule | Why (1 clause) | Enforced / more |
|---|---|---|---|
| 25 | No `NSScrollView.magnification` under SwiftUI content, and no `.scaleEffect` for canvas zoom | SwiftUI's coordinate space is unaware of magnification — same `.global` frame at every zoom, and above ~2× clicks stop registering entirely (measured, macOS 26.5.2); `.scaleEffect` blurs text and breaks `NSCursor` tracking | `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`; `CanvasCameraTests` |
| 26 | `NSTextContentStorage.textStorage = NSTextStorage(...)`, never `.attributedString =` | With `attributedString` the scrap renders perfectly and silently swallows every keystroke — `textStorage` nil, `string` empty, `insertText` a no-op | `ScrapLayoutTests.test_mountedEditorActuallyEditsTheSharedStack` |
| 27 | The canvas's mounted editor stays the FRONTMOST layer, its focus is *requested* not taken, and it mounts on the click while its VISIBILITY waits for the card to be level | An event view in front eats click-to-place-caret, drag-select and double-click-word; `makeFirstResponder` in `makeNSView` runs with a nil window and is a silent no-op; showing the editor on the click puts axis-aligned glyphs over a still-tilted card with the drawn text already suppressed, so they snap straight and the card follows, while deferring the *mount* to `isLevel` leaves ~120 ms in which typing reaches no editor at all — none of the four is visible to a subview count | `CanvasCompositionTests`; `ScrapEditorHostTests`; `CanvasRendererTests` (`isLevel`, `drawsOwnText`) |
| 28 | Text living in a shared `NSTextStorage` must be folded into the model on `textDidChange`, not only at a focus boundary | The debounced payload is whatever was queued *before* the writer typed, so type-then-quit writes an empty scrap and the drawn card never grows — the words are safe (constitution must #1) failing on the first interaction | `ScrapEditorHostTests.test_typingReportsItselfSoTheCanvasCanFoldItIntoTheModel`; `CanvasStoreTests.test_beforeFlushCanReplaceThePayloadOnItsWayOut` |
| 29 | A clock's "settled" predicate compares each value to ITS OWN target, never to a constant | `CanvasFocusStraighten.isSettled` written as `allSatisfy { $0.value >= 1 }` is true the instant focus leaves — the entry is still 1 while its target is now 0 — so `TimelineView` pauses, the settle-back never runs, and the card stays level for the rest of the session | `CanvasRendererTests.test_blurSettlesTheCardBackToItsSeededAngle` |
| 30 | Nothing scene-proportional may key off a per-frame redraw counter | `CanvasView.revision` ticks on every drag frame, straighten frame and momentum frame; the accessibility tree keyed on it sorted the scene and copied every scrap's string at 60–120 Hz. Use the structural counter (`sceneRevision`), and extract camera-reading `ForEach`es into `.equatable()` subviews | `CanvasAccessibilityTests.test_theTreeIsNotKeyedOnTheRedrawCounter` |

- [ ] **Step 4: Update the per-area table**

Add a `Maugham/Canvas/` row to CLAUDE.md's per-area pointer table:

> | `Maugham/Canvas/` | The Plan persona's centre column: a SwiftUI `Canvas` draws every node, one real `NSTextView` mounts on the focused scrap off the SAME TextKit stack. Camera is a manual CTM — never `.scaleEffect`, never `NSScrollView.magnification` (ADR 0026). Ground is a Metal shader BENEATH the content. **Read `Maugham/Canvas/AREA.md`**. |

- [ ] **Step 5: Sweep for now-false claims**

```bash
grep -rn -i "canvas" docs/roadmap.md docs/problem-map.md docs/guide/ CLAUDE.md docs/adr/0025-persona-shell.md | grep -iv "corkboard"
```

Known targets:
- `Persona.swift`'s `binderSegments(for:)` doc comment said "M1C builds the canvas" — Task 12 already fixed that; confirm.
- `docs/adr/0025-persona-shell.md` for the same forward reference.
- The guide's persona topic, which currently tells writers Plan offers Research and Palette. It now offers Canvas, Research and Palette, and the canvas is the centre column. **Describe only what ships** (rule 7): scraps, drag, resize, zoom, undo. Not regions, not lines, not promotion, not dragging research in.
- **The guide must say what ⌘Z does inside a scrap.** This is not optional prose. The undo granularity decision has a cost a writer meets directly — ⌘Z takes back a sentence, or the run of typing since you last paused, rather than a word — and every other place this plan states it (a test message, a code comment, ADR 0026, `AREA.md`, the `CanvasUndo` class doc, Task 15) is developer-facing. A writer who expects word-by-word undo and gets a sentence will read it as a bug unless the guide told them. One or two sentences in the persona topic, in the writer's terms: what ⌘Z takes back inside a scrap, and that ⌘Z outside one undoes a whole drag rather than a frame of it.
- `docs/roadmap.md` — flip the 1C-a item and leave 1C-b/1C-c/1C-d as open.
- `docs/problem-map.md` — the planning/thinking job moves from • to ~ (the canvas exists; promotion, which is what makes it pay off, is 1C-c).

- [ ] **Step 6: Run the doc-sync tests and both full suites**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/DocSyncTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: full Mac suite green.

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: green — confirms nothing leaked into MaughamCore, since M1C is Mac-only by design.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/AREA.md docs/adr/0026-planning-canvas-rendering.md docs/adr/README.md \
        CLAUDE.md docs/guide docs/roadmap.md docs/problem-map.md
git commit -m "docs(canvas): AREA.md, ADR 0026, three tripwires, guide and roadmap sweep"
```

---

## Whole-slice verification

After Task 17, before 1C-b:

- [ ] Full Mac suite green (`xcodebuild … -scheme Maugham test`)
- [ ] Full phone suite green — confirms nothing leaked into MaughamCore
- [ ] Release build succeeds
- [ ] **Whole-branch review** of the full diff. Per-task reviews cannot see emergent interactions; the T5×T6 precedent on the unified-undo milestone and the CRITICAL that eight per-task reviews missed on the persona shell are why this is not optional.
- [ ] Confirm no `Maugham.xcodeproj/` path appears anywhere in the branch diff: `git diff main --stat | grep -i xcodeproj` must print nothing.

**Smoke, by hand.** The first four lines are the ones that catch the defects this rewrite exists to prevent — do not skim them.

- [ ] New project → ⌘1 (Plan) → the canvas fills the centre column and the binder shows the **research tree**.
- [ ] **Double-click empty space → type a sentence.** If nothing appears, the editor is not first responder or the event view is in front of it — both were live defects.
- [ ] **Now quit with ⌘Q without clicking away first.** Relaunch, reopen: **the sentence is there.** This is the one that fails if the writer's words only ever live in the editor's `NSTextStorage`, and it is the product constitution's must #1. Do not substitute "click away, then quit" — that is a different path and it passes when this one does not.
- [ ] Keep typing past the end of the first line. **The card grows** as the text wraps. If it does not, nothing is re-measuring while you type — and the same gap is what loses the words above.
- [ ] Click away, then **double-click back into the middle of a word**. The caret lands where you aimed, and **the text does not move by a hair** on focus or on blur. The tests assert glyph geometry; only your eye catches a jump inside their tolerance. This is the §7A.2 failure the whole architecture exists to prevent.
- [ ] Watch the card as you click into it: it **animates to level over about a tenth of a second** and settles back to its angle when you click away (§7A.5). An instant jump reads as a rendering bug; more than about a fifth of a second reads as lag.
- [ ] **Double-click empty canvas and type immediately — no characters are lost, and the text does not jump.** Both halves matter and they fail in opposite directions. A missing first character or two means the editor is not mounted until the card is level, so the keystrokes reached nothing. Glyphs that snap straight the instant you click, with the chrome swinging up behind them, mean the editor was made visible before the card was level — the §7A.2 failure by §7A.5's own route. What you should see is the words appearing on the card as it rotates up to square, with the caret arriving a beat after them.
- [ ] **Click into a card, then click onto empty canvas, and keep watching it.** It must lean back to its angle within about a tenth of a second. A card that stays perfectly square after you leave means `isSettled` reported settled on blur and the clock stopped — and from then on nothing else on the canvas animates either.
- [ ] Double-click into a *second* scrap. You must be editing the second one — an editor still bound to the first is invisible to every automated check.
- [ ] **Pan the canvas. The grain must not crawl.** If the texture slides under the cards, the shader is sampling screen space instead of content space (§7A.4).
- [ ] Zoom in to ~3× and back out. Text stays crisp at every step; the point under the pointer stays under the pointer.
- [ ] Scroll and pinch **with the pointer over a focused scrap** — the canvas must still pan and zoom, and the pinch must zoom about **the point under your fingers**, not somewhere else on the canvas.
- [ ] Drag a scrap and let go with some speed: it **carries and comes to rest** rather than stopping dead (§7.3).
- [ ] **⌘Z once undoes the whole drag**, not one frame of it, and returns the card to where the drag started, not to where it stopped coasting.
- [ ] Type, then drag, then ⌘Z twice: the drag comes back first, then the typing. **Then press ⌘Z a third time** — it must either undo something real or do nothing because the stack is empty. A ⌘Z that visibly does nothing while the stack still says it can undo is the double-registration defect (I10) returning.
- [ ] **Type three sentences into one scrap without leaving it, then press ⌘Z three times.** Each press should take back roughly one sentence, not all three at once and not one character. Then pause a couple of seconds mid-sentence, type some more, and ⌘Z once: only what you typed after the pause comes back.
- [ ] **Type in one scrap, click into a second, press ⌘Z, then type in the second and click away.** The first scrap must stay reverted. If your ⌘Z quietly comes undone when you leave the second scrap, the open gesture's baseline was never refreshed after the undo.
- [ ] Drag a scrap's bottom-right corner: it rewraps, and stays clickable afterwards.
- [ ] Turn on VoiceOver, focus the canvas, and walk it: each scrap announces itself with its text, and entering one lands you in a real text field.
- [ ] Quit with ⌘Q **within a second of the last drag**, relaunch, reopen: the scrap is where you left it, with its words. (This is the path `.onDisappear` alone does not cover.)
- [ ] Delete `.maugham/canvas.json` by hand and reopen: the layout is gone, the words are not.

**Do not push or tag.** M1 is three slices; 1B is merged and deliberately unpushed, 1A is unwritten. Nothing ships until all three are in.
