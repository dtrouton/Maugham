# Planning canvas 1C-a — surface and scraps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Plan persona's centre column — a pannable, zoomable canvas that draws **scraps**, mounts one real editor on the focused scrap, and carries undo, momentum and an accessibility tree.

**Architecture:** A single SwiftUI `Canvas` draws every node off a model that already owns each node's position, so there is no geometry to read back. The camera is a manual CTM (`cx.translateBy`/`cx.scaleBy`) driven by a transparent `NSViewRepresentable` that overrides `scrollWheel(with:)`/`magnify(with:)` — **not** `NSScrollView` magnification, which the spike proved cannot translate coordinates into SwiftUI content. Scrap text is laid out through a TextKit 2 stack that is *the same stack* the mounted `NSTextView` edits, so drawn and edited glyphs land on identical pixels. The ground is a Metal shader in a sibling layer beneath the content, never an overlay.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, TextKit 2 (`NSTextContentStorage` / `NSTextLayoutManager`), Metal `[[stitchable]]` shader (macOS 14+), XCTest.

## Global Constraints

- **This slice is SCRAPS ONLY.** Spec §8A.1 gives *item* nodes (research notes, palette cards, images dragged in from the binder) to a separate plan, **1C-d**. In 1C-a:
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
- **Seeded irregularity must be stable** — derived from the node id, never random per frame (spec §7.2). It applies to the card's **chrome only**, never to its text (Task 7 explains why).
- **No raw `maugham.*` `NotificationCenter` post or subscription outside `MaughamEvent`** (tripwire 21). Nothing in this plan needs one. AppKit's own lifecycle notifications (`NSApplication.willTerminateNotification`) are not `maugham.*` and are permitted.
- **`ContentUnavailableView` needs `.frame(maxWidth: .infinity, maxHeight: .infinity)`** and the enclosing `VStack` needs `alignment: .top` (tripwire 15 — recurred 4+ times).
- **`Maugham.xcodeproj/` is generated and gitignored.** Never `git add` anything under it. A `project.pbxproj` in a diff is a red flag.
- **Every Step 2 begins with `./gen.sh &&`.** `MaughamTests/Canvas/` is a new directory: until `./gen.sh` runs, the new test file is not in the project at all, and `-only-testing MaughamTests/<Class>` then runs **zero** tests and reports **success** — a green RED step, which is worse than no RED step.
- `-only-testing` uses `MaughamTests/<ClassName>`, **never** a folder path.
- Run `./gen.sh` after adding any new source file. Run `xcodebuild` in the **foreground** (timeout 600000). Any task touching a view needs a **Release** build before it is called done — the Release type-check budget is stricter than Debug and v0.8.0 shipped a Release-only failure this way.

## Cross-plan contract with 1C-b and 1C-c

1C-a ships the surface; 1C-b (regions) and 1C-c (lines and promotion) build on it. Two of those seams are worth stating here so nobody has to reverse-engineer them.

**Who owns the scene.** In 1C-a, `CanvasView` owns `scene`, `scraps`, `layouts`, `camera`, `editingNodeID` and `caretIndex` as `@State`. **1C-b Task 4 introduces `@Observable final class CanvasModel` and moves `scene`, `scraps`, selection, the `CanvasStore` and the undo manager into it**, because the region inspector in the right-hand column needs the same scene the canvas draws. `camera`, `layouts`, `editingNodeID` and `caretIndex` stay in `CanvasView` — they are properties of one *view* of the canvas. That move is expected, planned, and is 1C-b's work, not 1C-a's. Do not build `CanvasModel` here.

**Where undo lives.** `CanvasUndo` is built in **1C-a Task 13**, snapshot-based, and 1C-b Task 4 rebinds it to `CanvasModel` without changing the class. Task 13 states the reasoning in full.

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
| `Maugham/Canvas/CanvasRenderer.swift` | The draw pass: culling, seeded chrome rotation, card drawing |
| `Maugham/Canvas/CanvasGround.metal` | `[[stitchable]]` grain shader, sampled in content space |
| `Maugham/Canvas/CanvasGround.swift` | The Metal-shader ground, as a sibling layer beneath content |
| `Maugham/Canvas/ScrapEditorHost.swift` | `ScrapEditorContainer` + `ScrapEditorHost` — one `NSTextView`, bounds-scaled by zoom |
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
  - `struct CanvasScene: Equatable, Sendable` — `init(nodes:)`, `var nodes: [CanvasNode]`, `var isEmpty: Bool`, `node(_:)`, `insert(_:)`, `remove(_:)`, `move(_:to:)`, `setWidth(_:for:)`, `setCachedHeight(_:for:)`, `topmostNode(at:)`, `nodes(intersecting:)`, `var topZ: Int`.

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
    public var nodes: [CanvasNode] {
        byID.values.sorted { ($0.z, $0.id.raw) < ($1.z, $1.id.raw) }
    }

    public var isEmpty: Bool { byID.isEmpty }

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
    /// coordinates. Reverse z-order, so the front-most wins.
    public func topmostNode(at point: CGPoint) -> CanvasNode? {
        nodes.reversed().first { $0.frame?.contains(point) == true }
    }

    /// Nodes whose frame intersects `rect`. This is the whole of virtualisation
    /// (spec §7A.1): culling is an intersection test in the draw loop, not a
    /// `ForEach` the renderer has to keep view identity for.
    public func nodes(intersecting rect: CGRect) -> [CanvasNode] {
        nodes.filter { $0.frame?.intersects(rect) == true }
    }
}
```

- [ ] **Step 4: Regenerate the project and run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasSceneTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 14 tests.

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
    private static func escape(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("## ") ? " " + $0 : String($0) }
            .joined(separator: "\n")
    }

    private static func unescape(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(" ## ") ? String($0.dropFirst()) : String($0) }
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
Expected: PASS, 7 tests.

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

    func test_mountedEditorHasZeroInsetAndAllowsUndo() {
        let l = layout()
        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        XCTAssertEqual(editor.textContainerInset, .zero,
                       "a non-zero inset shifts edited text against drawn text")
        XCTAssertTrue(editor.allowsUndo,
                      "the canvas undo manager needs the text view to register typing")
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

    func test_characterIndexAtPoint_isMonotonicDownTheLines() {
        let l = layout()
        var indices: [Int] = []
        var y: CGFloat = 6
        while y < l.measuredHeight { indices.append(l.characterIndex(at: CGPoint(x: 90, y: y))); y += 17 }
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
        // The canvas undo manager reaches the text view through the responder
        // chain (`ScrapEditorContainer.undoManager`), but only if the view
        // registers its typing at all.
        tv.allowsUndo = true
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
Expected: PASS, 9 tests.

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
    - `var hasPendingWrite: Bool` — test seam

Schema evolution follows ADR 0015: unknown enum cases decode to a sentinel or are dropped; a newer `schemaVersion` degrades to empty rather than throwing.

**Why `flush()` takes no arguments.** The store keeps the last debounced payload so the flush path has something to write without a caller who still remembers it. That is what makes the app-quit hook possible: `CanvasStore` observes `NSApplication.willTerminateNotification` itself and flushes. `.onDisappear` alone does **not** cover quit — the previous shape's doc comment claimed it did.

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
    func test_appTerminationFlushesThePendingWrite() {
        let store = CanvasStore(projectRoot: root)
        store.scheduleSave(scene: sampleScene(), scraps: [CanvasNodeID("s1"): "quit me"])
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification,
                                        object: NSApplication.shared)
        XCTAssertFalse(store.hasPendingWrite)
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scraps[CanvasNodeID("s1")],
                       "quit me")
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

    /// Matches `DocumentStore`'s autosave debounce, so canvas edits and
    /// manuscript edits settle on the same rhythm.
    private let debounceInterval: TimeInterval = 0.75

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
        // `.onDisappear` does NOT fire on app quit, and the 750ms debounce is
        // exactly long enough to lose the writer's last drag. This is an AppKit
        // lifecycle notification, not a `maugham.*` one, so it is outside
        // `MaughamEvent`'s remit (tripwire 21).
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.flush()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        // A store going away with an unwritten drag is the same data loss as a
        // quit. Write it out rather than cancelling it.
        flush()
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
    /// timer, from `CanvasView.onDisappear`, from app termination, and from
    /// `deinit`. A no-op when nothing is pending — it must never stamp an empty
    /// canvas over a real one.
    func flush() {
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
Expected: PASS, 11 tests.

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
  - `enum CanvasDragPhase: Equatable, Sendable` — `case began`, `case changed`, `case ended`. **This is the only drag vocabulary in the plan.** Tasks 9 and 11 use exactly these names; there is no `DragPhase`, no `onDragBegan`/`onDragChanged`/`onDragEnded` triple.
  - `final class CanvasEventNSView: NSView` — `var camera: CanvasCamera`, `var canvasUndoManager: UndoManager?`, `var onCameraChange: ((CanvasCamera) -> Void)?`, `var onClick: ((CGPoint, Int) -> Void)?` (view point, click count), `var onDrag: ((CGPoint, CanvasDragPhase) -> Void)?` (view point, phase); testable seams `applyScroll(deltaX:deltaY:precise:)`, `applyMagnify(magnification:at:)`, `applyMouseDown(at:clickCount:)`, `applyMouseDragged(to:)`, `applyMouseUp(at:)`.
  - `struct CanvasEventView: NSViewRepresentable` — `@Binding var camera: CanvasCamera`, `var onClick: (CGPoint, Int) -> Void`, `var onDrag: (CGPoint, CanvasDragPhase) -> Void`, `var undoManager: UndoManager?`.

SwiftUI cannot supply any of this: it exposes no scroll-wheel API on macOS, `MagnificationGesture` gives no centre point, and `.simultaneousGesture(DragGesture())` never fires on macOS (spec §7A.1).

The event logic lives in plain methods on the `NSView` so it can be tested without synthesizing `NSEvent`s. **The spike learned this the hard way:** synthesized-event harnesses failed their own controls twice, and `NSTextView.mouseDown` runs a modal tracking loop that deadlocks a post-then-pump harness.

**This view is NOT frontmost.** Task 9 places it *beneath* the mounted scrap editor so the editor receives clicks natively (caret placement, drag-select, double-click-word). `mouseDown` therefore does not call `super` — nothing behind it wants the event, and `NSResponder.mouseDown`'s default is to pass up the chain, which would hand canvas clicks to the window.

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
Expected: PASS, 11 tests.

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
- **Produces:** `enum CanvasRenderer` with
  - `static func seededRotation(for id: CanvasNodeID) -> Angle`
  - `static func visibleNodes(in scene: CanvasScene, camera: CanvasCamera, viewSize: CGSize) -> [CanvasNode]`
  - `static func placeholderLabel(forReference referenceId: String) -> String`
  - `static let resizeHandleSize: CGFloat`
  - `static func draw(scene: CanvasScene, camera: CanvasCamera, viewSize: CGSize, layouts: [CanvasNodeID: ScrapLayout], editingNodeID: CanvasNodeID?, into cx: inout GraphicsContext)` — **`editingNodeID:` is part of the signature.** Task 9 passes it; while a scrap's editor is live the editor *is* the visible text, so drawing it too would double-draw (spec §7A.2, the Excalidraw rule).

**Two decisions this task makes, both load-bearing.**

1. **Seeded rotation applies to the card's CHROME ONLY — never to its text.** §7.2 asks for a seeded fraction of a degree so everything reads as *put down* rather than snapped to a grid. But the mounted `NSTextView` is a real view: rotating it would mean `.rotationEffect`, which renders through a transform and blurs the glyphs — and *not* rotating it while the drawn text is rotated means the text visibly swings straight the instant the writer clicks in. That is the §7A.2 jump arriving by a route the spec did not anticipate. So the card's shape, shadow, border and resize handle rotate; the text inside draws axis-aligned at `CanvasCardMetrics.textOrigin(inCard:)`. At ≤0.6° the card edge carries the whole effect and the text lands on identical pixels drawn or edited. Record this as a deviation in the ADR (Task 15).

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

    /// The grab target in the card's bottom-right corner.
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

    /// Draw every visible node under the camera's CTM.
    ///
    /// `editingNodeID` is skipped entirely: while a scrap's editor is live, the
    /// editor IS the visible text, so drawing it too would double-draw (spec
    /// §7A.2, the rule borrowed from Excalidraw).
    static func draw(scene: CanvasScene,
                     camera: CanvasCamera,
                     viewSize: CGSize,
                     layouts: [CanvasNodeID: ScrapLayout],
                     editingNodeID: CanvasNodeID?,
                     into cx: inout GraphicsContext) {
        cx.translateBy(x: camera.pan.x, y: camera.pan.y)
        cx.scaleBy(x: camera.zoom, y: camera.zoom)

        for node in visibleNodes(in: scene, camera: camera, viewSize: viewSize) {
            guard node.id != editingNodeID, let frame = node.frame else { continue }
            drawCard(node, frame: frame, layout: layouts[node.id], into: &cx)
        }
    }

    /// §7.2: crisp edges, honest objects sitting on the textured ground. The
    /// real/manufactured line runs between the ground and the cards, not through
    /// each card — so no paper fibre here.
    ///
    /// The seeded rotation is applied to the card's CHROME only. The text draws
    /// axis-aligned, because the mounted `NSTextView` cannot be rotated without
    /// `.rotationEffect` (which blurs it) and a card whose drawn text is rotated
    /// while its edited text is not swings straight on every click — the §7A.2
    /// jump by another route. At ≤0.6° the card edge carries the whole effect.
    private static func drawCard(_ node: CanvasNode,
                                 frame: CGRect,
                                 layout: ScrapLayout?,
                                 into cx: inout GraphicsContext) {
        let shape = Path(roundedRect: frame, cornerRadius: 3)

        var chrome = cx
        // Rotate about the card's own centre, not the canvas origin.
        chrome.translateBy(x: frame.midX, y: frame.midY)
        chrome.rotate(by: seededRotation(for: node.id))
        chrome.translateBy(x: -frame.midX, y: -frame.midY)

        // Light falls from one corner (§7.1) — a single soft drop, not a glow.
        chrome.drawLayer { shadow in
            shadow.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, x: 1, y: 2))
            shadow.fill(shape, with: .color(.white))
        }
        chrome.fill(shape, with: .color(Color(nsColor: .textBackgroundColor)))

        switch node.kind {
        case .scrap:
            chrome.stroke(shape, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
        case .item:
            // A placeholder reads as unfinished on purpose — 1C-d fills it in.
            chrome.stroke(shape, with: .color(Color(nsColor: .separatorColor)),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        chrome.fill(resizeHandle(in: frame),
                    with: .color(Color(nsColor: .separatorColor).opacity(0.8)))

        // TEXT: unrotated, clipped to the unrotated card. See the doc above.
        switch node.kind {
        case .scrap:
            guard let layout else { return }
            let origin = CanvasCardMetrics.textOrigin(inCard: frame)
            cx.drawLayer { inner in
                inner.clip(to: shape)
                inner.withCGContext { cg in
                    cg.saveGState()
                    cg.translateBy(x: origin.x, y: origin.y)
                    layout.draw(into: cg, at: .zero)
                    cg.restoreGState()
                }
            }
        case .item(let referenceId):
            var text = cx.resolve(
                Text(placeholderLabel(forReference: referenceId))
                    .font(.system(size: 11)))
            text.shading = .color(Color(nsColor: .secondaryLabelColor))
            cx.draw(text, at: CanvasCardMetrics.textOrigin(inCard: frame), anchor: .topLeading)
        }
    }

    /// The corner triangle a writer grabs to rewrap a scrap. `CanvasInteraction`
    /// hit-tests the same square, from the same constant.
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
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasRenderer.swift MaughamTests/Canvas/CanvasRendererTests.swift project.yml
git commit -m "feat(canvas): draw pass — viewport culling, seeded chrome rotation, item placeholders

Rotation is applied to the card's chrome only: a rotated drawn glyph run
against an unrotatable NSTextView is the 7A.2 jump by another route.
Pins that no file in Maugham/Canvas derives a raster scale of its own."
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

**Hard constraint (spec §7A.4):** a shader applied *over* a subtree containing an `NSViewRepresentable` logs a warning and renders a placeholder. The ground must be a **sibling layer beneath** the content, never an overlay across it. Task 9 composes it that way; this task must not introduce an overlay.

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

### Task 9: The canvas view and the focused editor

**Files:**
- Create: `Maugham/Canvas/ScrapEditorHost.swift`
- Create: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/ScrapEditorHostTests.swift`
- Test: `MaughamTests/Canvas/CanvasCompositionTests.swift`

**Interfaces:**
- **Consumes:** everything from Tasks 1–8.
- **Produces:**
  - `final class ScrapEditorContainer: NSView` — `private(set) var textView: NSTextView?`, `var canvasUndoManager: UndoManager?`, `var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?`, `var onMagnify: ((CGFloat, CGPoint) -> Void)?`, `@discardableResult func mount(layout: ScrapLayout, unscaledSize: CGSize, zoom: CGFloat) -> Bool` (returns `true` when the editor was built or rebuilt), `func requestFocus(caretIndex: Int?)`, `func unmount()`.
  - `struct ScrapEditorHost: NSViewRepresentable` — `let layout: ScrapLayout`, `let unscaledSize: CGSize`, `let zoom: CGFloat`, `let caretIndex: Int?`, `let undoManager: UndoManager?`, `let onScroll: (CGFloat, CGFloat, Bool) -> Void`, `let onMagnify: (CGFloat, CGPoint) -> Void`. **The parameter is `unscaledSize: CGSize`, not `frame: CGRect`** — the host owns the size, `CanvasView` owns the position.
  - `struct CanvasView: View` — `let projectRoot: URL`, `let paletteSwatchHexes: () -> [String]`.

**Three defects this task exists to not have.** Each is a "typing does nothing" smoke failure and none of them is caught by a test that only counts subviews.

1. **Layer order.** The ZStack is `CanvasGround` → `Canvas` → `CanvasEventView` → `ScrapEditorHost`. The **editor is frontmost**. If the event view were in front it would eat click-to-place-caret, drag-select and double-click-word — the headline interaction — while every test still passed. Ground and `Canvas` take `.allowsHitTesting(false)` so the event view reaches everything the editor does not cover. The editor container forwards `scrollWheel`/`magnify` back to the camera so panning and zooming still work with the pointer over the focused scrap.
2. **First responder.** `makeNSView` runs *before* the view is in a window, so `tv.window` is `nil` and `tv.window?.makeFirstResponder(tv)` is a silent no-op. Focus is therefore **requested** and claimed again from `viewDidMoveToWindow`.
3. **Rebinding.** `mount` must rebuild the text view when the *layout identity* changes, not merely when there is no text view. Creating it only `if textView == nil` means clicking from scrap A to scrap B keeps editing A — and a test that counts subviews passes anyway.

**Zoomed editing uses bounds scaling** — the spike's Q4. Grow the container's `frame` by zoom, hold its `bounds` at the unzoomed size. Coordinates round-trip correctly at every zoom tested (1×–3×) and AppKit re-rasterises, so text stays crisp. Crucially it involves **no re-layout**, so Task 3's proven drawn/edited agreement carries over unchanged. Do not reach for `.scaleEffect`, and do not re-lay-out the editor at a scaled font size.

**A note on `@State` and reference types.** `layouts` holds `ScrapLayout` *objects*. Typing mutates the object in place, so SwiftUI sees no `@State` change and the `Canvas` never redraws. `CanvasView` therefore carries a `revision` counter, read **in `body`** (not inside the draw closure — a `@State` read only registers a dependency during body evaluation) and bumped by every path that mutates a layout or the scene in place.

**Interaction is deliberately incomplete here.** `onDrag` is wired to a stub with a one-line comment; Task 11 fills it in. `undoManager` is `nil`; Task 13 fills it in. Do not invent either.

- [ ] **Step 1: Write the failing tests**

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

    /// C9. Counting subviews is not enough: an editor still bound to the FIRST
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

    /// C8, second defect. `makeNSView` runs before the view is in a window, so
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

    func test_caretIndexBeyondTheTextIsClampedRatherThanCrashing() {
        let container = ScrapEditorContainer(frame: CGRect(origin: .zero, size: size))
        let l = layout("short")
        container.mount(layout: l, unscaledSize: size, zoom: 1)
        host(container)
        container.requestFocus(caretIndex: 9_999)
        XCTAssertEqual(container.textView?.selectedRange().location, 5)
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
        container.applyMagnify(magnification: 0.25, at: .zero)
        XCTAssertEqual(scrolls, [12])
        XCTAssertEqual(magnifications, [0.25])
    }

    func test_theMountedEditorUsesTheCanvasUndoManager() {
        let container = ScrapEditorContainer(frame: .zero)
        let manager = UndoManager()
        container.canvasUndoManager = manager
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        host(container)
        XCTAssertTrue(container.textView?.undoManager === manager,
                      "typing and dragging must land on ONE stack in the order "
                      + "they happened")
    }

    /// Spec §7A.6: the mounted editor must stay reachable by VoiceOver. It is a
    /// real NSTextView, so this is about not hiding it.
    func test_theMountedEditorIsExposedToAccessibility() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: size, zoom: 1)
        XCTAssertFalse(container.isAccessibilityElement(),
                       "the container must not absorb its text view's AX identity")
        XCTAssertTrue(container.textView?.isAccessibilityElement() == true)
    }
}
```

`MaughamTests/Canvas/CanvasCompositionTests.swift`:

```swift
import XCTest
@testable import Maugham

/// C8, first defect. There is no runtime hook that reports a SwiftUI ZStack's
/// z-order, and the failure it guards against — the event view eating
/// click-to-place-caret — is invisible to every other test in this plan while
/// being the first thing a writer hits. So it is pinned at the source, the way
/// `TripwireGrepTests` pins its rules.
final class CanvasCompositionTests: XCTestCase {

    private func canvasViewSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Maugham/Canvas/CanvasView.swift"), encoding: .utf8)
    }

    /// Two assertions, because either alone is fakeable: the ZStack must place
    /// `mountedEditor` after `CanvasEventView`, and `mountedEditor` must be the
    /// thing that builds a `ScrapEditorHost`.
    func test_theMountedEditorIsInFrontOfTheEventView() throws {
        let src = try canvasViewSource()
        let event = try XCTUnwrap(src.range(of: "CanvasEventView("),
                                  "CanvasView no longer composes CanvasEventView")
        let slot = try XCTUnwrap(src.range(of: "mountedEditor"),
                                 "CanvasView no longer composes mountedEditor")
        XCTAssertTrue(event.lowerBound < slot.lowerBound,
                      "the event view is in FRONT of the mounted editor, so it eats "
                      + "click-to-place-caret, drag-select and double-click-word — "
                      + "the writer sees 'typing does nothing'")

        let declaration = try XCTUnwrap(src.range(of: "private var mountedEditor"))
        let host = try XCTUnwrap(src.range(of: "ScrapEditorHost("),
                                 "CanvasView no longer composes ScrapEditorHost")
        XCTAssertTrue(declaration.lowerBound < host.lowerBound,
                      "the editor must be built inside `mountedEditor`, or the "
                      + "z-order assertion above is checking the wrong symbol")
    }

    func test_theGroundAndTheDrawnLayerDoNotHitTest() throws {
        let src = try canvasViewSource()
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

    func test_theCanvasIsNotHiddenFromAccessibility() throws {
        let src = try canvasViewSource()
        XCTAssertFalse(src.contains("accessibilityHidden(true)"))
        XCTAssertFalse(src.contains("accessibilityElement(children: .ignore)"),
                       "spec §7A.6: we own the canvas AX tree — ignoring children "
                       + "throws away the mounted editor with it")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapEditorHostTests -only-testing MaughamTests/CanvasCompositionTests CODE_SIGNING_ALLOWED=NO`
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
final class ScrapEditorContainer: NSView {

    private(set) var textView: NSTextView?
    /// Identity of the layout the current text view is bound to. Rebinding is
    /// keyed on THIS, not on `textView == nil`: clicking from scrap A to scrap B
    /// must rebuild, and a subview count cannot tell the difference.
    private var mountedLayout: ObjectIdentifier?

    private var wantsFocus = false
    private var pendingCaretIndex: Int?

    var canvasUndoManager: UndoManager?
    var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?

    override var isFlipped: Bool { true }

    /// `NSTextView` asks its delegate, then walks the responder chain. This
    /// container is its superview, so returning the canvas manager here puts
    /// typing and geometry on ONE undo stack in the order they happened.
    override var undoManager: UndoManager? { canvasUndoManager ?? super.undoManager }

    /// Returns `true` when the editor was built or rebuilt.
    @discardableResult
    func mount(layout: ScrapLayout, unscaledSize: CGSize, zoom: CGFloat) -> Bool {
        let identity = ObjectIdentifier(layout)
        var rebuilt = false
        if mountedLayout != identity {
            textView?.removeFromSuperview()
            let tv = layout.makeEditor(frame: CGRect(origin: .zero, size: unscaledSize))
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

    func applyMagnify(magnification: CGFloat, at point: CGPoint) {
        onMagnify?(magnification, point)
    }

    override func scrollWheel(with event: NSEvent) {
        applyScroll(deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas)
    }

    override func magnify(with event: NSEvent) {
        applyMagnify(magnification: event.magnification,
                     at: convert(event.locationInWindow, from: nil))
    }
}

/// SwiftUI wrapper. Exactly one of these is ever in the hierarchy — the scrap
/// currently being edited (spec §7A.1).
struct ScrapEditorHost: NSViewRepresentable {
    let layout: ScrapLayout
    /// The TEXT box size, in content points. `CanvasView` owns the position and
    /// the card inset; this view owns only the editor.
    let unscaledSize: CGSize
    let zoom: CGFloat
    /// Where the writer clicked, so the caret lands where they aimed
    /// (spec §7A.2, the rule borrowed from Miro).
    let caretIndex: Int?
    let undoManager: UndoManager?
    let onScroll: (CGFloat, CGFloat, Bool) -> Void
    let onMagnify: (CGFloat, CGPoint) -> Void

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
        c.canvasUndoManager = undoManager
        c.onScroll = onScroll
        c.onMagnify = onMagnify
    }
}
```

- [ ] **Step 4: Write the composed view**

`Maugham/Canvas/CanvasView.swift`:

```swift
import AppKit
import SwiftUI

/// The Plan persona's centre column.
///
/// LAYER ORDER IS A HARD CONSTRAINT, not a preference:
///
///   1. `CanvasGround`      — shader, `.allowsHitTesting(false)`
///   2. `Canvas`            — drawn nodes, `.allowsHitTesting(false)`
///   3. `CanvasEventView`   — camera + pointer
///   4. `ScrapEditorHost`   — the one live editor, FRONTMOST
///
/// The ground is a SIBLING BENEATH the content because a shader applied *over*
/// a subtree holding an `NSViewRepresentable` renders a placeholder (spec §7A.4),
/// and this view has two of them. The editor is in FRONT of the event view
/// because that is the only way the writer gets AppKit's own click-to-place-caret,
/// drag-select and double-click-word; with the order reversed the event view
/// swallows all three and the surface reads as "typing does nothing".
/// `CanvasCompositionTests` pins both.
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

    /// `layouts` holds ScrapLayout REFERENCES. Typing mutates the object in
    /// place, so `@State` observes no change and the `Canvas` never redraws.
    /// Every path that mutates a layout or the scene in place bumps this, and
    /// `body` READS it — a `@State` read only registers a dependency during body
    /// evaluation, so reading it inside the draw closure would do nothing.
    @State private var revision = 0

    private let scrapFont = NSFont(name: "Iowan Old Style", size: 13)
        ?? .systemFont(ofSize: 13)

    var body: some View {
        // Read here, not in the closure — see `revision`.
        let drawRevision = revision

        GeometryReader { geo in
            ZStack {
                CanvasGround(camera: camera, wash: wash)
                    .allowsHitTesting(false)

                Canvas { cx, size in
                    _ = drawRevision
                    CanvasRenderer.draw(scene: scene, camera: camera, viewSize: size,
                                        layouts: layouts, editingNodeID: editingNodeID,
                                        into: &cx)
                }
                .allowsHitTesting(false)

                CanvasEventView(
                    camera: $camera,
                    onClick: { viewPoint, clickCount in
                        handleClick(at: camera.contentPoint(fromView: viewPoint),
                                    clickCount: clickCount)
                    },
                    // Task 11 drives CanvasInteraction from this. Until then a
                    // drag is a no-op, deliberately — not a forgotten stub.
                    onDrag: { _, _ in },
                    // Task 13 supplies the canvas undo manager.
                    undoManager: nil)

                mountedEditor
            }
            .onAppear { load() }
            .onDisappear { store?.flush() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Frontmost. Present only while a scrap is being edited.
    @ViewBuilder
    private var mountedEditor: some View {
        if let id = editingNodeID,
           let node = scene.node(id),
           case .scrap = node.kind,
           let layout = layouts[id],
           let frame = node.frame {
            let textSize = CanvasCardMetrics.textSize(inCard: frame)
            let viewOrigin = camera.viewPoint(fromContent:
                CanvasCardMetrics.textOrigin(inCard: frame))
            ScrapEditorHost(layout: layout,
                            unscaledSize: textSize,
                            zoom: camera.zoom,
                            caretIndex: caretIndex,
                            undoManager: nil,          // Task 13
                            onScroll: { dx, dy, precise in
                                let factor: CGFloat = precise ? 1 : 8
                                camera.panBy(CGSize(width: dx * factor, height: dy * factor))
                            },
                            onMagnify: { magnification, point in
                                camera.zoom(to: camera.zoom * (1 + magnification),
                                            anchoringViewPoint: point)
                            })
                .frame(width: textSize.width * camera.zoom,
                       height: textSize.height * camera.zoom)
                .position(x: viewOrigin.x + textSize.width * camera.zoom / 2,
                          y: viewOrigin.y + textSize.height * camera.zoom / 2)
        }
    }

    // MARK: - Loading and measuring

    private func load() {
        let s = CanvasStore(projectRoot: projectRoot)
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
    }

    /// Pull the live text out of the editing scrap's layout and back into the
    /// model, then re-measure it. Called before focus moves and before a save.
    private func commitActiveEdit() {
        guard let id = editingNodeID, let layout = layouts[id] else { return }
        scraps[id] = layout.text
        scene.setCachedHeight(
            CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight), for: id)
        revision += 1
    }

    // MARK: - Clicks

    /// Single click: leave whatever was being edited. Double click: enter the
    /// scrap under the pointer (Task 11 adds "or make one here").
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
            store?.scheduleSave(scene: scene, scraps: scraps)
            return
        }

        let textOrigin = CanvasCardMetrics.textOrigin(inCard: frame)
        editingNodeID = node.id
        caretIndex = layout.characterIndex(
            at: CGPoint(x: contentPoint.x - textOrigin.x, y: contentPoint.y - textOrigin.y))
        store?.scheduleSave(scene: scene, scraps: scraps)
    }
}
```

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapEditorHostTests -only-testing MaughamTests/CanvasCompositionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 11 + 3 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. **A Debug pass is not evidence** — the Release type-check budget is stricter, and v0.8.0 shipped a Release-only failure this way.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/ScrapEditorHost.swift Maugham/Canvas/CanvasView.swift MaughamTests/Canvas/ScrapEditorHostTests.swift MaughamTests/Canvas/CanvasCompositionTests.swift project.yml
git commit -m "feat(canvas): composed surface + one bounds-scaled editor on the focused scrap

Editor frontmost so AppKit supplies caret placement and word selection;
focus is requested and claimed on viewDidMoveToWindow (makeNSView has no
window yet); mount rebinds on layout identity, not on textView == nil."
```

---

### Task 10: Wire the canvas into the Plan persona

**Files:**
- Modify: `Maugham/Models/BinderSegment.swift` (add `case canvas`; conform to `CaseIterable`)
- Modify: `Maugham/Models/Persona.swift` (Plan's `binderSegments(for:)` and the doc comment above it)
- Modify: `Maugham/Views/ProjectWindow.swift` (`existingEditorSwitch` ~line 847, `existingInspectorSwitch` ~line 1018, `shouldShowStatusFooter` ~line 787)
- Modify: `Maugham/Views/BinderPaneToggle.swift` (the `switch segment` at **line 28**)
- Modify: `Maugham/Views/CollectionBinderPaneToggle.swift` (the `switch segment` at **line 36**)
- Modify: `Maugham/Stores/ProjectStore+Palette.swift` (add `paletteSwatchHexes()`)
- Modify: `MaughamTests/PersonaBinderSegmentTests.swift` (**two assertions change**, two arrays become `allCases`)
- Modify: `MaughamTests/PersonaMemoryTests.swift` (two arrays become `allCases`)
- Test: `MaughamTests/Canvas/CanvasSegmentTests.swift`

**Interfaces:**
- **Consumes:** `CanvasView(projectRoot:paletteSwatchHexes:)` (Task 9); `CanvasGroundPalette` (Task 8).
- **Produces:**
  - `BinderSegment.canvas`, and `BinderSegment: CaseIterable`.
  - `Persona.plan.binderSegments(for:) == [.canvas, .research, .palette]` for every project type, so `Persona.plan.binderHome(for:) == .canvas`.
  - `ProjectStore.paletteSwatchHexes() -> [String]`.

**No new top-level modifier.** `ProjectWindow.existingEditorSwitch` already routes the centre column on `binderSegment`, so adding `case canvas` puts the canvas there. Adding the case makes the compiler enumerate every exhaustive switch over `BinderSegment` — that is the mechanism, and it is why this is one task rather than a hunt.

**The five exhaustive switches, named.** Do not go looking; these are all of them, verified against the tree on 2026-07-25:

| Site | File:line | What `.canvas` returns |
|---|---|---|
| `BinderSegment.isTransient` | `Maugham/Models/BinderSegment.swift` | `false` — a persona surface, not a runtime state |
| `BinderSegment.displayName(for:)` | `Maugham/Models/BinderSegment.swift` | `"Canvas"`, every project type |
| `BinderSegment.pickerSymbolName` | `Maugham/Models/BinderSegment.swift` | `"square.on.circle"` — must be distinct from the six existing symbols |
| `ProjectWindow.existingEditorSwitch` | `Maugham/Views/ProjectWindow.swift:847` | `CanvasView` |
| `ProjectWindow.existingInspectorSwitch` | `Maugham/Views/ProjectWindow.swift:1018` | a full-frame `ContentUnavailableView` |
| `BinderPaneToggle` left column | `Maugham/Views/BinderPaneToggle.swift:28` | `ResearchView` |
| `CollectionBinderPaneToggle` left column | `Maugham/Views/CollectionBinderPaneToggle.swift:36` | `CollectionResearchPane` |

**What the binder shows under the canvas segment: the research tree.** Spec §10 left this open and now records the answer. Umbrella §6.3 gives Plan a Left surface of "Research tree", and spec §8A.1 *depends* on it — dragging a research item onto the canvas (1C-d) requires the tree to be beside it. So `.canvas` and `.research` render the same left pane; the picker distinguishes them and the centre column is what actually differs. That is deliberate, not an oversight, and the arms carry a comment saying so.

**Two existing test assertions break and are fixed in this task**, not left for the full-suite run to discover:

- `MaughamTests/PersonaBinderSegmentTests.swift:6-8` — `test_planPersona_leadsWithResearch` asserts `Persona.plan.binderHome(for: .novel) == .research`.
- `MaughamTests/PersonaBinderSegmentTests.swift:53-57` — `test_planPersona_exactSegments` asserts `Persona.plan.binderSegments(for: .novel) == [.research, .palette]`.

**Four hardcoded `[BinderSegment]` arrays would silently under-test the new case.** Rather than adding `.canvas` to each and leaving the drift class open, make `BinderSegment: CaseIterable` and replace all four with `BinderSegment.allCases`:
`PersonaBinderSegmentTests.swift:122`, `:132`, `PersonaMemoryTests.swift:74`, `:132`.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasSegmentTests.swift`:

```swift
import XCTest
@testable import Maugham
import MaughamCore

final class CanvasSegmentTests: XCTestCase {

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

    func test_switchingAwayFromPlanLeavesTheCanvas() {
        // Author does not offer .canvas, so a coerced segment must land on
        // Author's own home rather than stranding the writer on a blank column.
        let author = Persona.author.binderSegments(for: .novel)
        XCTAssertFalse(author.contains(.canvas))
        XCTAssertEqual(Persona.author.binderHome(for: .novel), .manuscript)
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

    func test_paletteSwatchHexesFlattensEveryCardsSwatches() throws {
        // ProjectStore is exercised end to end elsewhere; this only pins that
        // the accessor exists and returns hex strings, which is the seam
        // CanvasGroundPalette parses.
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

`CaseIterable` is not decoration: four test files held hardcoded `[BinderSegment]` arrays that would each have silently skipped the new case. Step 6 replaces them.

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

- [ ] **Step 4: Put the canvas in Plan's list**

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

- [ ] **Step 5: Route the four view switches**

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

- [ ] **Step 6: Update the tests this task breaks**

`MaughamTests/PersonaBinderSegmentTests.swift` — the two Plan assertions:

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

Then replace all four hardcoded arrays with `BinderSegment.allCases`:

```swift
// PersonaBinderSegmentTests.swift:122 and :132
        let all = BinderSegment.allCases
// PersonaMemoryTests.swift:74
        let all = BinderSegment.allCases
// PersonaMemoryTests.swift:132
        let allBinder = BinderSegment.allCases
```

All four are generic loops over `binderSegments`/`isTransient`/`binderHome`, so they strengthen rather than break — but run them and confirm, don't assume.

- [ ] **Step 7: Check the footer guard the compiler cannot see**

`ProjectWindow.swift:787-791` reads:

```swift
        guard binderSegment == .manuscript || binderSegment == .scenes else {
```

This is an `==` comparison, so adding the case does **not** flag it. The behaviour is already correct — the word-count footer should not show on the canvas — so leave it. Add a comment so the next reader knows it was considered rather than missed:

```swift
        // `.canvas` is deliberately absent: the footer reports manuscript
        // metrics, and readiness stays silent about the canvas (umbrella §7, §9).
        guard binderSegment == .manuscript || binderSegment == .scenes else {
```

- [ ] **Step 8: Run the full suite and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: the whole Mac suite green, including the updated `PersonaBinderSegmentTests` and `PersonaMemoryTests`. Integration failures only surface in the FULL suite — the edition-identity milestone learned this the expensive way; do not call this task done off a filtered run.

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: green — this confirms nothing leaked into MaughamCore, since M1C is Mac-only by design.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Maugham/Models/BinderSegment.swift Maugham/Models/Persona.swift \
        Maugham/Views/ProjectWindow.swift Maugham/Views/BinderPaneToggle.swift \
        Maugham/Views/CollectionBinderPaneToggle.swift \
        Maugham/Stores/ProjectStore+Palette.swift \
        MaughamTests/Canvas/CanvasSegmentTests.swift \
        MaughamTests/PersonaBinderSegmentTests.swift MaughamTests/PersonaMemoryTests.swift
git commit -m "feat(canvas): Plan's centre column is the canvas

Adds BinderSegment.canvas at the head of Plan's segment list, so it is
also Plan's binderHome. No new top-level modifier — existingEditorSwitch
already routes on binderSegment. Resolves spec 10's open question about
the left column: both binder toggles show the research tree under the
canvas segment, which is what 8A.1's drag-in route will need.
BinderSegment gains CaseIterable so the four hardcoded segment arrays in
the persona tests cannot miss a case again."
```

---

### Task 11: Create, move, resize — and momentum

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

**Momentum, built rather than described.** §7.3 says cards carry momentum and come to rest rather than snapping, and calls it "where tools actually acquire feel". The mechanism is a **velocity term plus an explicit per-frame decay the renderer reads** — not `withAnimation`. `withAnimation` interpolates `Animatable` values through the SwiftUI view graph; a plain model value read inside a `Canvas` draw closure is not in that graph and would simply jump to its final value. So `CanvasView` wraps the drawn layer in `TimelineView(.animation(paused: momentum.isAtRest))` and steps the model once per tick.

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

    /// The corner handle the renderer draws is the same square the state machine
    /// hit-tests, off one constant.
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
    /// anywhere else starts a move. The corner is `CanvasRenderer.resizeHandleSize`
    /// — the same constant the renderer draws, so the target and the mark cannot
    /// drift apart.
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

**(b)** Wrap the drawn layer in a timeline so momentum has a clock, and replace the `onDrag` stub. The `Canvas` block from Task 9 becomes:

```swift
                // The clock momentum coasts on. Paused when nothing is moving,
                // so an idle canvas costs nothing. `withAnimation` cannot do
                // this: a plain model value read inside a Canvas draw closure is
                // not in the SwiftUI animation graph (see CanvasMomentum).
                TimelineView(.animation(paused: momentum.isAtRest)) { context in
                    Canvas { cx, size in
                        _ = drawRevision
                        CanvasRenderer.draw(scene: scene, camera: camera, viewSize: size,
                                            layouts: layouts, editingNodeID: editingNodeID,
                                            into: &cx)
                    }
                    .allowsHitTesting(false)
                    .onChange(of: context.date) { _, _ in
                        if !momentum.step(&scene) {
                            store?.scheduleSave(scene: scene, scraps: scraps)
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
                    undoManager: nil)      // Task 13
```

**(c)** `handleClick` grows the create path, and `handleDrag` arrives:

```swift
    private func handleClick(at contentPoint: CGPoint, clickCount: Int) {
        commitActiveEdit()

        guard clickCount >= 2 else {
            editingNodeID = nil
            caretIndex = nil
            store?.scheduleSave(scene: scene, scraps: scraps)
            return
        }

        // Double click on a scrap enters it; on empty space it makes one.
        if let node = scene.topmostNode(at: contentPoint),
           case .scrap = node.kind,
           let layout = layouts[node.id],
           let frame = node.frame {
            let textOrigin = CanvasCardMetrics.textOrigin(inCard: frame)
            editingNodeID = node.id
            caretIndex = layout.characterIndex(
                at: CGPoint(x: contentPoint.x - textOrigin.x,
                            y: contentPoint.y - textOrigin.y))
        } else if scene.topmostNode(at: contentPoint) == nil {
            let id = CanvasInteraction.createScrap(at: contentPoint, in: &scene)
            scraps[id] = ""
            // A new scrap has no cachedHeight, so it has no frame, so it is
            // invisible to hit testing and culling until it is measured.
            rebuildLayouts()
            editingNodeID = id
            caretIndex = 0
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
                // card is hit-tested or culled again.
                rebuildLayouts()
            } else if let flick {
                momentum.launch(flick.id, velocity: flick.velocity)
            }
            store?.scheduleSave(scene: scene, scraps: scraps)
            revision += 1
        }
    }
```

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasInteractionTests -only-testing MaughamTests/CanvasMomentumTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 11 + 7 tests.

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

### Task 12: The accessibility layer — resolving spec §7A.6

**Files:**
- Create: `Maugham/Canvas/CanvasAccessibility.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasAccessibilityTests.swift`

**Spec §7A.6 is unambiguous:** *"We own accessibility for the canvas. Drawn content has no AX tree… Budget an AX layer mirroring the scene graph; Figma does exactly this. **Not optional in a writing tool.**"* Spec §10 lists it as an open question with two outcomes — build it or soften the claim. This task builds it.

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNode`, `CanvasNodeID`, `CanvasNodeKind` (Task 1); `CanvasCamera` (Task 4); `CanvasRenderer.placeholderLabel(forReference:)` (Task 7).
- **Produces:**
  - `enum CanvasAXRole: String, Equatable, Sendable` — `case scrap`, `case item`.
  - `struct CanvasAXElement: Equatable, Identifiable` — `let id: CanvasNodeID`, `let role: CanvasAXRole`, `let label: String`, `let value: String`, `let frame: CGRect` (VIEW coordinates).
  - `enum CanvasAccessibility` — `static let canvasLabel: String`, `static let emptyCanvasValue: String`, `static let emptyScrapValue: String`, `static func elements(scene:scraps:camera:) -> [CanvasAXElement]`, `static func summary(scene:) -> String`.

**Three decisions, each stated rather than hedged.**

1. **Every node is in the tree, not just the visible ones.** Culling is a *drawing* optimisation; a node you cannot see is still a node you must be able to reach, and a VoiceOver user navigates the canvas by walking its elements, not by panning first. Frames are still in view coordinates, so an offscreen element's rect is offscreen — that is honest, and it is what lets an assistive client scroll to it.
2. **Reading order is rows top-to-bottom, then left-to-right within a row** — not z-order, which is a drawing concern and would read a canvas out in the order the writer happened to touch it. Rows are banded so cards that are roughly level read as one row.
3. **The mounted editor stays a real `NSTextView`** and is therefore natively accessible — IME, caret, spell-check, selection, all of it. That is the entire reason for the one-real-editor-on-focus rule (§7A.6 quotes the W3C list of what drawing text forfeits). The AX work here is to *not hide it*: no `.accessibilityElement(children: .ignore)` on the stack, no `.accessibilityHidden(true)`. `CanvasCompositionTests` (Task 9) already pins that; `ScrapEditorHostTests` pins the container side.

The SwiftUI mechanism is `View.accessibilityChildren(children:)` (macOS 12+), which replaces a view's accessibility children with synthetic elements laid out in its own coordinate space — exactly the Figma shape §7A.6 names.

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
        let elements = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps,
                                                    camera: CanvasCamera())
        XCTAssertEqual(elements.count, 4)
    }

    /// Culling is a DRAWING optimisation. A node you cannot see is still a node
    /// you must be able to reach.
    func test_offscreenNodesAreStillInTheTree() {
        var scene = sampleScene()
        scene.insert(scrapNode("far", x: 90_000, y: 90_000))
        let elements = CanvasAccessibility.elements(scene: scene, scraps: scraps,
                                                    camera: CanvasCamera())
        XCTAssertTrue(elements.contains { $0.id == CanvasNodeID("far") })
    }

    func test_readingOrderIsRowsThenColumns() {
        let ids = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps,
                                               camera: CanvasCamera()).map(\.id.raw)
        XCTAssertEqual(ids, ["s1", "s2", "s3", "item:r-9"],
                       "roughly-level cards must read left to right as one row, "
                       + "not in the order the writer happened to touch them")
    }

    func test_aScrapCarriesItsTextAsItsValue() {
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps,
                                                   camera: CanvasCamera())
            .first { $0.id == CanvasNodeID("s1") }
        XCTAssertEqual(element?.role, .scrap)
        XCTAssertEqual(element?.value, "The falls at night.")
        XCTAssertTrue(element?.label.contains("Scrap") == true)
    }

    func test_anEmptyScrapSaysSoRatherThanReadingAsBlank() {
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps,
                                                   camera: CanvasCamera())
            .first { $0.id == CanvasNodeID("s3") }
        XCTAssertEqual(element?.value, CanvasAccessibility.emptyScrapValue)
        XCTAssertFalse(CanvasAccessibility.emptyScrapValue.isEmpty)
    }

    func test_anItemNodeIsLabelledAsAReference() {
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps,
                                                   camera: CanvasCamera())
            .first { $0.id == .item("r-9") }
        XCTAssertEqual(element?.role, .item)
        XCTAssertTrue(element?.value.contains("r-9") == true)
    }

    /// Frames are in VIEW coordinates, so an assistive client can point at them.
    func test_framesFollowTheCamera() {
        var camera = CanvasCamera()
        camera.zoom = 2
        camera.pan = CGPoint(x: 50, y: 30)
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps,
                                                   camera: camera)
            .first { $0.id == CanvasNodeID("s1") }
        XCTAssertEqual(element?.frame, CGRect(x: 50, y: 30, width: 480, height: 160))
    }

    func test_anUnmeasuredNodeIsStillReachable() {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: CanvasNodeID("new"), kind: .scrap,
                                origin: .zero, width: 240))   // no cachedHeight
        let elements = CanvasAccessibility.elements(scene: scene, scraps: [:],
                                                    camera: CanvasCamera())
        XCTAssertEqual(elements.count, 1,
                       "a scrap the writer just made must not be unreachable "
                       + "until it happens to be measured")
        XCTAssertGreaterThan(elements[0].frame.height, 0)
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
    /// VIEW coordinates, so an assistive client can point at it.
    let frame: CGRect
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
                         scraps: [CanvasNodeID: String],
                         camera: CanvasCamera) -> [CanvasAXElement] {
        scene.nodes
            .sorted { a, b in
                let bandA = (a.origin.y / rowBand).rounded(.down)
                let bandB = (b.origin.y / rowBand).rounded(.down)
                if bandA != bandB { return bandA < bandB }
                if a.origin.x != b.origin.x { return a.origin.x < b.origin.x }
                return a.id.raw < b.id.raw
            }
            .map { node in
                let height = node.cachedHeight ?? unmeasuredHeight
                let viewOrigin = camera.viewPoint(fromContent: node.origin)
                let frame = CGRect(x: viewOrigin.x, y: viewOrigin.y,
                                   width: node.width * camera.zoom,
                                   height: height * camera.zoom)
                switch node.kind {
                case .scrap:
                    let text = scraps[node.id] ?? ""
                    return CanvasAXElement(
                        id: node.id, role: .scrap,
                        label: "Scrap",
                        value: text.isEmpty ? emptyScrapValue : text,
                        frame: frame)
                case .item(let referenceId):
                    return CanvasAXElement(
                        id: node.id, role: .item,
                        label: "Reference",
                        value: CanvasRenderer.placeholderLabel(forReference: referenceId),
                        frame: frame)
                }
            }
    }

    /// What the canvas itself says when focused, before its children are walked.
    static func summary(scene: CanvasScene) -> String {
        let count = scene.nodes.count
        guard count > 0 else { return emptyCanvasValue }
        return "\(count) \(count == 1 ? "item" : "items")"
    }
}
```

- [ ] **Step 4: Install the tree in `CanvasView`**

Two edits to `Maugham/Canvas/CanvasView.swift`.

**(a)** Compute the elements alongside `drawRevision` at the top of `body`, so the `@State` reads register:

```swift
        let drawRevision = revision
        let axElements = CanvasAccessibility.elements(scene: scene, scraps: scraps,
                                                      camera: camera)
```

**(b)** Attach them to the drawn layer — the `Canvas` inside the `TimelineView`, immediately after `.allowsHitTesting(false)`:

```swift
                    .accessibilityLabel(CanvasAccessibility.canvasLabel)
                    .accessibilityValue(CanvasAccessibility.summary(scene: scene))
                    .accessibilityChildren {
                        // Spec §7A.6: drawn content has no AX tree, so we build
                        // one. These are synthetic elements laid out in the
                        // Canvas's own coordinate space — the mounted editor is
                        // a real NSTextView and is exposed on its own.
                        ForEach(axElements) { element in
                            Color.clear
                                .frame(width: max(1, element.frame.width),
                                       height: max(1, element.frame.height))
                                .position(x: element.frame.midX, y: element.frame.midY)
                                .accessibilityElement()
                                .accessibilityLabel(element.label)
                                .accessibilityValue(element.value)
                        }
                    }
```

Do **not** add `.accessibilityElement(children: .ignore)` or `.accessibilityHidden(true)` anywhere in this file — either would throw the mounted editor away with the drawn nodes. `CanvasCompositionTests` fails if you do.

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasAccessibilityTests -only-testing MaughamTests/CanvasCompositionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 11 + 3 tests.

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
stays natively accessible because nothing hides it."
```

---

### Task 13: Undo — resolving spec §10

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

**The subtlety:** scrap text and scrap geometry must share one stack. The mounted `NSTextView` brings its own undo manager, and if it stays separate then ⌘Z after typing-then-dragging undoes the drag while the writer expects the typing. Task 9's `ScrapEditorContainer.undoManager` override already routes the text view to whichever manager it is handed; this task hands it the canvas one.

**`UndoManager.groupsByEvent` — the thing that makes the tests raise if you skip it.** It defaults to `true`, which installs a run-loop observer that opens an implicit top-level group per event and closes it at end of event. Calling `undo()` synchronously, outside a run loop, while that implicit group is open raises `NSInternalInconsistencyException` ("undo was called with too many nested undo groups"). **Every test in this file therefore sets `undo.groupsByEvent = false`.**

Production keeps the default `true`, and that is safe *because every record is bracketed synchronously inside one event*: `beginGesture` → mutate → `endGesture` all run inside the same mouse-up handler, so our group never spans an event boundary. Keeping `true` in production is what lets the mounted `NSTextView` coalesce typing per event, which is the behaviour a writer expects from ⌘Z in a text field.

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNodeID` (Task 1).
- **Produces:** `final class CanvasUndo` with
  - `typealias Snapshot = (scene: CanvasScene, scraps: [CanvasNodeID: String])`
  - `init(undoManager: UndoManager)`
  - `var readSnapshot: (() -> Snapshot)?` and `var applySnapshot: ((Snapshot) -> Void)?` — bound by whoever owns the state (`CanvasView` here, `CanvasModel` in 1C-b)
  - `func beginGesture(_ name: String)`
  - `func endGesture()` — closes the group, registering nothing if the snapshot is unchanged
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
/// **Scrap TEXT and scrap GEOMETRY share ONE stack.** The mounted `NSTextView`
/// brings its own undo manager, and if it stays separate then ⌘Z after
/// typing-then-dragging undoes the drag while the writer is expecting the
/// typing. `CanvasView` hands this manager to `ScrapEditorHost`, whose container
/// vends it down the responder chain, so both land on one stack in the order
/// they happened.
///
/// **`groupsByEvent` stays at its default `true` in production.** It installs a
/// run-loop observer that opens an implicit top-level group per event; every
/// gesture here is bracketed synchronously inside ONE event (begin → mutate →
/// end all run in the same mouse-up handler), so our group never spans an event
/// boundary, and keeping the default is what lets the mounted `NSTextView`
/// coalesce typing the way a writer expects. **Tests must set it to `false`**:
/// calling `undo()` synchronously outside a run loop while the implicit group is
/// open raises `NSInternalInconsistencyException`.
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

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    var isInGesture: Bool { depth > 0 }

    /// Open a gesture. Nested calls are absorbed — a gesture arriving mid-gesture
    /// (a drag interrupted by a keystroke path) must not open a second group and
    /// leave the manager unbalanced.
    func beginGesture(_ name: String) {
        depth += 1
        guard depth == 1 else { return }
        snapshotAtGestureStart = readSnapshot?()
        undoManager.beginUndoGrouping()
        undoManager.setActionName(name)
    }

    /// Close the gesture, registering an undo only if the state actually moved.
    /// A drag that starts and ends on the same pixel must not push a step —
    /// otherwise ⌘Z after a stray click undoes the writer's last REAL edit while
    /// appearing to do nothing.
    func endGesture() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }

        defer { snapshotAtGestureStart = nil }
        guard let before = snapshotAtGestureStart, let now = readSnapshot() else {
            undoManager.endUndoGrouping()
            return
        }
        if before.scene != now.scene || before.scraps != now.scraps {
            register(before)
        }
        undoManager.endUndoGrouping()
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
            guard let current = target.readSnapshot() else { return }
            target.register(current)
            target.applySnapshot?(snapshot)
        }
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

**(c)** Replace the two `undoManager: nil` placeholders from Task 9 with `undoManager: undoManager` — in `CanvasEventView(...)` and in `ScrapEditorHost(...)`. The event view vends it to the responder chain so ⌘Z works with nothing focused; the editor container vends it to the text view so typing lands on the same stack.

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

In `handleClick`, wrap the create path:

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
        }
```

And in `commitActiveEdit`, so a text change is a step:

```swift
    private func commitActiveEdit() {
        guard let id = editingNodeID, let layout = layouts[id] else { return }
        guard scraps[id] != layout.text else { return }
        undo?.mutate("Edit Scrap") { scraps[id] = layout.text }
        scene.setCachedHeight(
            CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight), for: id)
        revision += 1
    }
```

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasUndoTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 11 tests.

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
to CanvasModel without touching this class."
```

---

### Task 14: Performance bounds — resolving spec §10

**Files:**
- Test: `MaughamTests/Canvas/CanvasPerformanceProbeTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNode`, `CanvasNodeID` (Task 1); `CanvasCamera` (Task 4); `CanvasRenderer.visibleNodes(in:camera:viewSize:)` (Task 7).
- **Produces:** `CanvasPerformanceProbeTests.supportedNodeCount = 2_000`, the number Task 15's AREA.md records. No production code.

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

The supported-node-count line goes into `Maugham/Canvas/AREA.md`, which **Task 15 creates** — so it is written there, not here, and this commit touches only the test file.

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

### Task 15: Docs, AREA.md and the ADR

**Files:**
- Create: `Maugham/Canvas/AREA.md`
- Create: `docs/adr/0026-planning-canvas-rendering.md`
- Modify: `docs/adr/README.md`
- Modify: `CLAUDE.md` (per-area pointer table, tripwire table)
- Modify: `docs/guide/` (the topic covering personas)
- Modify: `docs/roadmap.md`, `docs/problem-map.md`

**Interfaces:**
- **Consumes:** every symbol built in Tasks 1–14; `CanvasPerformanceProbeTests.supportedNodeCount` (Task 14) as the number AREA.md records.
- **Produces:** documentation only. No Swift.

Rule 10 of the default workflow: when a roadmap item flips •→✓, sweep sibling docs for now-false claims **in the same commit**. Rule 7: help/docs describe what *ships* — so the guide says the canvas draws scraps, and says nothing about dragging research in, which is 1C-d.

- [ ] **Step 1: Write `Maugham/Canvas/AREA.md`**

Cover, at minimum, each of these — a bullet per line, with the symptom named where there is one:

- **The architecture in three sentences, and why the alternative lost.** Link `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`. Someone will propose `NSScrollView` again; the note is the answer.
- **The three `ScrapLayout` requirements, verbatim, with the symptom each produces when broken.** The `attributedString` one especially: it fails silently and looks like a UI bug rather than a wiring bug.
- **Card metrics live in `CanvasCardMetrics` and nowhere else.** A second spelling of the inset puts drawn text and edited text on different rects — the §7A.2 jump by the back door.
- **Seeded rotation is chrome-only.** Rotating the text would mean rotating an `NSTextView`, which means `.rotationEffect`, which blurs; not rotating the editor while the drawing is rotated makes the text swing straight on every click. Recorded as a deviation from §7.2 in ADR 0026.
- **Layer order: ground → drawn → events → editor (frontmost).** With the event view in front, click-to-place-caret, drag-select and double-click-word all die and the surface reads as "typing does nothing". `CanvasCompositionTests` pins it.
- **Ground beneath, never an overlay**, and what happens if you get it wrong (a placeholder render, plus a console warning).
- **The mounted editor's focus is requested, not taken** — `makeNSView` has no window yet, so `makeFirstResponder` there is a silent no-op.
- **`mount` rebinds on layout identity, not on `textView == nil`** — otherwise clicking from scrap A to scrap B keeps editing A, and a subview count cannot tell.
- **Bounds scaling for the zoomed editor**; never `.scaleEffect`; never re-layout.
- **`layouts` holds reference types in `@State`.** Typing mutates in place, so the `Canvas` will not redraw without the `revision` counter — and `revision` must be read in `body`, not inside the draw closure.
- **`canvas.json` is derived and deletable; `canvas.md` is content and is not.**
- **`CanvasStore.flush()` takes no arguments** and covers app quit via `NSApplication.willTerminateNotification`, because `.onDisappear` does not fire on quit.
- **Undo is snapshot-based and canvas-scoped**, and reaches state through two closures so 1C-b can move ownership to `CanvasModel`. Tests must set `groupsByEvent = false`; production must not.
- **We own the accessibility tree** (§7A.6) — every node, all of them, rows-then-columns; never `.accessibilityElement(children: .ignore)` on the stack.
- **Supported scale: 2,000 nodes.** Not a hard cap — nothing enforces it — but the number the culling probe defends. Above it, expect the draw pass rather than the culling to become the limit. tldraw caps at 4,000; Excalidraw degrades near 5,000.
- **The test-harness note:** `NSTextView.mouseDown` runs a modal event-tracking loop, so a post-then-pump harness deadlocks. Post both mouseDown and mouseUp before pumping — and every negative result needs a control that passed.
- **What 1C-a deliberately does not do:** item nodes render as placeholders; the drop target, image handling and title resolution are 1C-d; regions are 1C-b; lines and promotion are 1C-c.

- [ ] **Step 2: Write ADR 0026**

Check the highest existing ADR number first — 0025 is the persona shell, so 0026 unless something landed since:

```bash
ls docs/adr/ | sort | tail -3
```

The ADR records, with the spike's measurements as evidence:

1. **A drawn canvas over hosted views**, and the disqualification of `NSScrollView` magnification (SwiftUI content reports the same `.global` frame at every zoom; above ~2× clicks stop registering entirely).
2. **The shared-TextKit rule** — one layout stack for drawn and edited text — and the three requirements it comes with.
3. **Scrap text in `canvas.md`, layout in `.maugham/canvas.json`**, and why the split is the point.
4. **Seeded rotation applied to card chrome only** — a deviation from §7.2's literal reading, taken to protect §7A.2's guarantee.
5. **Undo is a canvas-scoped snapshot `UndoManager`, not op-log compensating ops**, because canvas state is derived (§8) and op-logging it would stop it being derived.
6. **We own the canvas accessibility tree**, resolving §7A.6's "not optional in a writing tool".

Cite the constitution principles by name, per CLAUDE.md.

Add the row to `docs/adr/README.md`.

- [ ] **Step 3: Add the tripwires**

Add to CLAUDE.md's tripwire table (numbers follow the highest currently present — 24 at time of writing, so 25–27):

| # | Rule | Why (1 clause) | Enforced / more |
|---|---|---|---|
| 25 | No `NSScrollView.magnification` under SwiftUI content, and no `.scaleEffect` for canvas zoom | SwiftUI's coordinate space is unaware of magnification — same `.global` frame at every zoom, and above ~2× clicks stop registering entirely (measured, macOS 26.5.2); `.scaleEffect` blurs text and breaks `NSCursor` tracking | `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`; `CanvasCameraTests` |
| 26 | `NSTextContentStorage.textStorage = NSTextStorage(...)`, never `.attributedString =` | With `attributedString` the scrap renders perfectly and silently swallows every keystroke — `textStorage` nil, `string` empty, `insertText` a no-op | `ScrapLayoutTests.test_mountedEditorActuallyEditsTheSharedStack` |
| 27 | The canvas's mounted editor stays the FRONTMOST layer, and its focus is *requested* not taken | An event view in front eats click-to-place-caret, drag-select and double-click-word; `makeFirstResponder` in `makeNSView` runs with a nil window and is a silent no-op — both read as "typing does nothing" and neither is visible to a subview count | `CanvasCompositionTests`; `ScrapEditorHostTests` |

- [ ] **Step 4: Update the per-area table**

Add a `Maugham/Canvas/` row to CLAUDE.md's per-area pointer table:

> | `Maugham/Canvas/` | The Plan persona's centre column: a SwiftUI `Canvas` draws every node, one real `NSTextView` mounts on the focused scrap off the SAME TextKit stack. Camera is a manual CTM — never `.scaleEffect`, never `NSScrollView.magnification` (ADR 0026). Ground is a Metal shader BENEATH the content. **Read `Maugham/Canvas/AREA.md`**. |

- [ ] **Step 5: Sweep for now-false claims**

```bash
grep -rn -i "canvas" docs/roadmap.md docs/problem-map.md docs/guide/ CLAUDE.md docs/adr/0025-persona-shell.md | grep -iv "corkboard"
```

Known targets:
- `Persona.swift`'s `binderSegments(for:)` doc comment said "M1C builds the canvas" — Task 10 already fixed that; confirm.
- `docs/adr/0025-persona-shell.md` for the same forward reference.
- The guide's persona topic, which currently tells writers Plan offers Research and Palette. It now offers Canvas, Research and Palette, and the canvas is the centre column. **Describe only what ships** (rule 7): scraps, drag, resize, zoom, undo. Not regions, not lines, not promotion, not dragging research in.
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

After Task 15, before 1C-b:

- [ ] Full Mac suite green (`xcodebuild … -scheme Maugham test`)
- [ ] Full phone suite green — confirms nothing leaked into MaughamCore
- [ ] Release build succeeds
- [ ] **Whole-branch review** of the full diff. Per-task reviews cannot see emergent interactions; the T5×T6 precedent on the unified-undo milestone and the CRITICAL that eight per-task reviews missed on the persona shell are why this is not optional.
- [ ] Confirm no `Maugham.xcodeproj/` path appears anywhere in the branch diff: `git diff main --stat | grep -i xcodeproj` must print nothing.

**Smoke, by hand.** The first four lines are the ones that catch the defects this rewrite exists to prevent — do not skim them.

- [ ] New project → ⌘1 (Plan) → the canvas fills the centre column and the binder shows the **research tree**.
- [ ] **Double-click empty space → type a sentence.** If nothing appears, the editor is not first responder or the event view is in front of it — both were live defects.
- [ ] Click away, then **double-click back into the middle of a word**. The caret lands where you aimed, and **the text does not move by a hair** on focus or on blur. The tests assert glyph geometry; only your eye catches a jump inside their tolerance. This is the §7A.2 failure the whole architecture exists to prevent.
- [ ] Double-click into a *second* scrap. You must be editing the second one — an editor still bound to the first is invisible to every automated check.
- [ ] **Pan the canvas. The grain must not crawl.** If the texture slides under the cards, the shader is sampling screen space instead of content space (§7A.4).
- [ ] Zoom in to ~3× and back out. Text stays crisp at every step; the point under the pointer stays under the pointer.
- [ ] Scroll and pinch **with the pointer over a focused scrap** — the canvas must still pan and zoom.
- [ ] Drag a scrap and let go with some speed: it **carries and comes to rest** rather than stopping dead (§7.3).
- [ ] **⌘Z once undoes the whole drag**, not one frame of it, and returns the card to where the drag started, not to where it stopped coasting.
- [ ] Type, then drag, then ⌘Z twice: the drag comes back first, then the typing.
- [ ] Drag a scrap's bottom-right corner: it rewraps, and stays clickable afterwards.
- [ ] Turn on VoiceOver, focus the canvas, and walk it: each scrap announces itself with its text, and entering one lands you in a real text field.
- [ ] Quit with ⌘Q **within a second of the last drag**, relaunch, reopen: the scrap is where you left it, with its words. (This is the path `.onDisappear` alone does not cover.)
- [ ] Delete `.maugham/canvas.json` by hand and reopen: the layout is gone, the words are not.

**Do not push or tag.** M1 is three slices; 1B is merged and deliberately unpushed, 1A is unwritten. Nothing ships until all three are in.
