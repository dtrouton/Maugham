# Planning canvas 1C-a — surface and nodes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Plan persona's centre column — a pannable, zoomable canvas that draws scraps and item nodes, and mounts one real editor on the focused scrap.

**Architecture:** A single SwiftUI `Canvas` draws every node off a model that already owns each node's position, so there is no geometry to read back. The camera is a manual CTM (`cx.translateBy`/`cx.scaleBy`) driven by a transparent `NSViewRepresentable` that overrides `scrollWheel(with:)`/`magnify(with:)` — **not** `NSScrollView` magnification, which the spike proved cannot translate coordinates into SwiftUI content. Scrap text is laid out through a TextKit 2 stack that is *the same stack* the mounted `NSTextView` edits, so drawn and edited glyphs land on identical pixels. The ground is a Metal shader in a sibling layer beneath the content, never an overlay.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, TextKit 2 (`NSTextContentStorage` / `NSTextLayoutManager`), Metal `[[stitchable]]` shader (macOS 14+), XCTest.

## Global Constraints

- **Mac-only.** `Packages/MaughamCore` and `MaughamPhone` are untouched, exactly as 1B was (spec §9). Nothing in this plan may add a file under either.
- **Deployment target macOS 14.0.** No API newer than 14.0 without a fallback.
- **Plain text on disk.** Scrap *text* is content and lives in `canvas.md` at project root. Positions, geometry, membership, lines and seeds are derived UI state and live in `.maugham/canvas.json` (spec §8).
- **The canvas never writes to a research note, palette card or image** (spec §8). Item nodes hold a reference and a position, nothing else.
- **`ProjectWindow.body`'s expression budget is zero.** No new top-level modifier. The canvas reaches the centre column by adding `case canvas` to `BinderSegment` and to `Persona.binderSegments(for:)` — `ProjectWindow.existingEditorSwitch` already routes on `binderSegment`.
- **`BinderSegmentPicker` requires uniform `Image` children** — every `BinderSegment` must return an SF Symbol from `pickerSymbolName`. Mixed `Image`/`Text` in that `ForEach` shipped smoke defect C on 2026-07-25.
- **Never `.scaleEffect` for zoom.** It scales rendered output (blurry text), reports unscaled geometry, and breaks `NSCursor` tracking (spec §7A.1).
- **Seeded irregularity must be stable** — derived from the node id, never random per frame (spec §7.2).
- Run `./gen.sh` after adding any new source file. Run `xcodebuild` in the **foreground** (timeout 600000). Any task touching a view needs a **Release** build before the task is called done.
- `-only-testing` uses `MaughamTests/<ClassName>`, never folder paths.

## Evidence this plan is built on

`docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md` — read it before Task 3. Three findings are load-bearing and are repeated at their tasks:

1. `NSTextContentStorage.textStorage = NSTextStorage(...)`, **never** `.attributedString = ...`. The latter renders perfectly and silently refuses every keystroke.
2. `lineFragmentPadding = 0` (defaults to 5), `widthTracksTextView = false`, `textContainerInset = .zero`.
3. Draw at the window's true `backingScaleFactor` × camera zoom.

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Canvas/CanvasNode.swift` | `CanvasNode`, `CanvasNodeKind`, `CanvasNodeID` — one node, its position, its width |
| `Maugham/Canvas/CanvasScene.swift` | The whole scene: nodes in z-order, lookup, mutation helpers. Pure value type. |
| `Maugham/Canvas/CanvasSceneCodec.swift` | `Codable` shape + schema version for `.maugham/canvas.json` |
| `Maugham/Canvas/CanvasStore.swift` | Owns disk I/O for both `canvas.json` and `canvas.md`; debounced autosave |
| `Maugham/Canvas/ScrapText.swift` | The `canvas.md` plain-text format: parse and render |
| `Maugham/Canvas/ScrapLayout.swift` | The shared TextKit 2 stack. The single place the three spike requirements are encoded. |
| `Maugham/Canvas/CanvasCamera.swift` | Pan/zoom state, the CTM, and the inverse transform used for hit testing |
| `Maugham/Canvas/CanvasEventView.swift` | `NSViewRepresentable` overriding `scrollWheel`/`magnify` |
| `Maugham/Canvas/CanvasRenderer.swift` | The draw pass: culling, seeded rotation, node drawing |
| `Maugham/Canvas/CanvasGround.swift` | The Metal-shader ground, as a sibling layer beneath content |
| `Maugham/Canvas/CanvasGround.metal` | `[[stitchable]]` grain shader, sampled in content space |
| `Maugham/Canvas/ScrapEditorHost.swift` | Mounts one `NSTextView` on the focused scrap, bounds-scaled by zoom |
| `Maugham/Canvas/CanvasView.swift` | Composes ground + `Canvas` + event view + editor host |
| `Maugham/Models/BinderSegment.swift` | *Modify* — add `case canvas` |
| `Maugham/Models/Persona.swift` | *Modify* — Plan's `binderSegments(for:)` |
| `Maugham/Views/ProjectWindow.swift` | *Modify* — two switch arms only |

---

### Task 1: The scene model

**Files:**
- Create: `Maugham/Canvas/CanvasNode.swift`
- Create: `Maugham/Canvas/CanvasScene.swift`
- Test: `MaughamTests/Canvas/CanvasSceneTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `CanvasNodeID` (a `String` newtype), `CanvasNodeKind`, `CanvasNode` (`id`, `kind`, `origin: CGPoint`, `width: CGFloat`, `cachedHeight: CGFloat?`, `z: Int`), `CanvasScene` (`nodes: [CanvasNode]`, `node(_:)`, `insert(_:)`, `remove(_:)`, `move(_:to:)`, `setCachedHeight(_:for:)`, `topmostNode(at:)`).

`width` is authoritative and height is derived (spec §7A.3). `cachedHeight` exists because §7A.3 requires caching the measured height so layout is stable until something forces a re-measure.

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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasSceneTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasScene' in scope`.

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
    public static func item(_ referenceId: String) -> CanvasNodeID {
        CanvasNodeID("item:\(referenceId)")
    }
}

/// What a node *is*. The distinction is the whole data model (spec §3):
/// items already exist and the canvas holds only their position; scraps exist
/// only here.
public enum CanvasNodeKind: Equatable, Sendable {
    /// A loose thought typed straight onto the canvas. Text lives in
    /// `canvas.md`, keyed by the node id.
    case scrap
    /// Something that already exists in the project. `referenceId` is the
    /// research item id / palette card id. The canvas NEVER writes to it.
    case item(referenceId: String)
}

/// One node. `width` is authoritative; the text reflows to fit and the height
/// is derived (spec §7A.3). `cachedHeight` is the last measured height, held so
/// layout is stable until something forces a re-measure.
public struct CanvasNode: Equatable, Sendable {
    public let id: CanvasNodeID
    public var kind: CanvasNodeKind
    public var origin: CGPoint
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
        byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    /// Nodes in draw order — back to front.
    public var nodes: [CanvasNode] {
        byID.values.sorted { ($0.z, $0.id.raw) < ($1.z, $1.id.raw) }
    }

    public var isEmpty: Bool { byID.isEmpty }

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
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasNode.swift Maugham/Canvas/CanvasScene.swift MaughamTests/Canvas/CanvasSceneTests.swift project.yml
git commit -m "feat(canvas): scene model — nodes, z-order, culling and hit-test primitives"
```

---

### Task 2: The scrap text file (`canvas.md`)

**Files:**
- Create: `Maugham/Canvas/ScrapText.swift`
- Test: `MaughamTests/Canvas/ScrapTextTests.swift`

**Interfaces:**
- Consumes: `CanvasNodeID` (Task 1).
- Produces: `ScrapText.parse(_ markdown: String) -> [CanvasNodeID: String]`, `ScrapText.render(_ scraps: [CanvasNodeID: String]) -> String`.

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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapTextTests CODE_SIGNING_ALLOWED=NO`
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
    static let banner = "<!-- maugham:canvas-scraps -->"

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
            // Trim only the blank lines the renderer added around the body.
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
Expected: PASS, 6 tests.

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
- Consumes: nothing.
- Produces: `final class ScrapLayout` with `init(text: String, width: CGFloat, font: NSFont)`, `var text: String { get }`, `var measuredHeight: CGFloat { get }`, `func setWidth(_:)`, `func draw(into cgContext: CGContext, at origin: CGPoint)`, `func makeEditor(frame: CGRect) -> NSTextView`, `func characterIndex(at localPoint: CGPoint) -> Int`, and `var lineGeometrySignature: [String] { get }` (test seam — the fragment/line geometry the focus-blur pin compares).

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

    /// THE §7A.2 PIN. If drawn and edited layout differ by even a fraction, text
    /// visibly jumps every time the writer clicks in and again when they click
    /// out. Spike verified this holds; this test keeps it holding.
    func test_layoutIsIdenticalAcrossFocusAndBlur() {
        let l = layout()
        let beforeFocus = l.lineGeometrySignature
        XCTAssertFalse(beforeFocus.isEmpty)

        let editor = l.makeEditor(frame: CGRect(x: 0, y: 0, width: 240,
                                                height: l.measuredHeight))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSView(frame: editor.frame)
        window.contentView?.addSubview(editor)
        editor.layoutSubtreeIfNeeded()

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
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSView(frame: editor.frame)
        window.contentView?.addSubview(editor)
        editor.layoutSubtreeIfNeeded()

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

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapLayoutTests CODE_SIGNING_ALLOWED=NO`
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
/// 3. Callers must draw at the window's true `backingScaleFactor` × camera zoom.
///    Deriving a scale from pixel width instead bakes in AppKit's frame rounding
///    and shifts glyphs by a subpixel — the "text jumps" failure in disguise.
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
        return ceil(layoutManager.usageBoundsForTextContainer.height)
    }

    func setWidth(_ width: CGFloat) {
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    /// Draw into a context whose CTM the caller has already set to the camera
    /// (translate + scale) and flipped into top-left text coordinates.
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
        return tv
    }

    /// Place the caret from the click point (spec §7A.2, the rule borrowed from
    /// Miro) so clicking into a scrap lands where the writer aimed.
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
                    let inLine = line.characterIndex(for: CGPoint(x: localPoint.x, y: line.typographicBounds.height / 2))
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
Expected: PASS, 7 tests.

- [ ] **Step 5: Falsify the pin**

Prove the §7A.2 test can actually fail. Temporarily change `container.lineFragmentPadding = 0` to `= 5`, re-run, and confirm `test_containerDefaultsAreOverridden` fails by name. Then restore. Then temporarily change `contentStorage.textStorage = NSTextStorage(...)` to `contentStorage.attributedString = ...`, re-run, and confirm `test_mountedEditorActuallyEditsTheSharedStack` fails. Then restore and re-run to green.

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
- Consumes: nothing.
- Produces: `struct CanvasCamera` with `pan: CGPoint`, `zoom: CGFloat`, `static let zoomRange: ClosedRange<CGFloat>`, `func contentPoint(fromView viewPoint: CGPoint) -> CGPoint`, `func viewPoint(fromContent contentPoint: CGPoint) -> CGPoint`, `func visibleContentRect(viewSize: CGSize) -> CGRect`, `mutating func zoom(to newZoom: CGFloat, anchoringViewPoint: CGPoint)`, `mutating func panBy(_ delta: CGSize)`.

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

    func test_panBy_movesContentOppositeToTheDrag() {
        var c = CanvasCamera()
        c.panBy(CGSize(width: 50, height: 30))
        XCTAssertEqual(c.viewPoint(fromContent: .zero), CGPoint(x: 50, y: 30))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasCameraTests CODE_SIGNING_ALLOWED=NO`
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
Expected: PASS, 7 tests.

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
- Consumes: `CanvasScene`, `CanvasNode` (Task 1), `ScrapText` (Task 2).
- Produces: `final class CanvasStore` with `init(projectRoot: URL)`, `func load() -> (scene: CanvasScene, scraps: [CanvasNodeID: String])`, `func save(scene:scraps:)`, `func scheduleSave(scene:scraps:)`, and `static let sidecarRelativePath = ".maugham/canvas.json"`, `static let scrapsRelativePath = "canvas.md"`.

Schema evolution follows ADR 0015: unknown enum cases decode to a sentinel, non-optional fields get a custom decoder.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
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
        s.insert(CanvasNode(id: CanvasNodeID.item("r-9"), kind: .item(referenceId: "r-9"),
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasStoreTests CODE_SIGNING_ALLOWED=NO`
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
import Foundation

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

    /// Matches `DocumentStore`'s autosave debounce, so canvas edits and
    /// manuscript edits settle on the same rhythm.
    private let debounceInterval: TimeInterval = 0.75

    init(projectRoot: URL) { self.projectRoot = projectRoot }

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
        writeNow(scene: scene, scraps: scraps)
    }

    /// Debounced — a drag emits a position per frame and must not emit a write
    /// per frame.
    func scheduleSave(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeNow(scene: scene, scraps: scraps)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Flush any debounced write. Call on window close and app quit — the
    /// 750ms window is exactly long enough to lose the last drag on quit.
    func flush(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        guard pendingSave != nil else { return }
        save(scene: scene, scraps: scraps)
    }

    private func writeNow(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        pendingSave = nil
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
Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasSceneCodec.swift Maugham/Canvas/CanvasStore.swift MaughamTests/Canvas/CanvasStoreTests.swift project.yml
git commit -m "feat(canvas): sidecar + canvas.md persistence, corrupt/newer sidecar degrades to empty"
```

---

### Task 6: Scroll and magnify events

**Files:**
- Create: `Maugham/Canvas/CanvasEventView.swift`
- Test: `MaughamTests/Canvas/CanvasEventViewTests.swift`

**Interfaces:**
- Consumes: `CanvasCamera` (Task 4).
- Produces: `struct CanvasEventView: NSViewRepresentable` taking `camera: Binding<CanvasCamera>`, `onClick: (CGPoint) -> Void`, `onDrag: (CGPoint, CGPoint, DragPhase) -> Void`; and `final class CanvasEventNSView: NSView` exposing `applyScroll(deltaX:deltaY:precise:)` and `applyMagnify(magnification:at:)` as testable seams.

SwiftUI cannot do this: it exposes no scroll-wheel API on macOS, `MagnificationGesture` gives no centre point, and `.simultaneousGesture(DragGesture())` never fires on macOS (spec §7A.1).

The event logic lives in plain methods on the `NSView` so it can be tested without synthesizing `NSEvent`s. **The spike learned this the hard way:** synthesized-event harnesses failed their own controls twice, and `NSTextView.mouseDown` runs a modal tracking loop that deadlocks a post-then-pump harness.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasEventViewTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasEventNSView' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import AppKit
import SwiftUI

/// Where the canvas gets its camera input.
///
/// SwiftUI cannot supply any of this on macOS: there is no scroll-wheel API,
/// `MagnificationGesture` provides no centre point (so zoom-to-cursor is
/// impossible), and `.simultaneousGesture(DragGesture())` never fires at all
/// (spec §7A.1). So a transparent `NSView` sits over the canvas and overrides
/// the three AppKit entry points.
///
/// The event LOGIC is in plain methods, not inside the `NSEvent` overrides,
/// because synthesizing AppKit events in tests is unreliable — the 2026-07-25
/// spike had two synthetic-event harnesses fail their own control cases, and
/// discovered that `NSTextView.mouseDown` runs a modal tracking loop that
/// deadlocks a post-then-pump harness. Test the methods; keep the overrides
/// thin enough to read.
final class CanvasEventNSView: NSView {

    var camera = CanvasCamera()
    var onCameraChange: ((CanvasCamera) -> Void)?
    var onClick: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }

    /// Without this, the first click into an unfocused window is spent
    /// activating it — on a canvas that is a lost thought.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        onClick?(convert(event.locationInWindow, from: nil))
    }
}

/// Bridges `CanvasEventNSView` into SwiftUI. Transparent — it contributes no
/// drawing, only events.
struct CanvasEventView: NSViewRepresentable {
    @Binding var camera: CanvasCamera
    var onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CanvasEventNSView {
        let v = CanvasEventNSView(frame: .zero)
        v.camera = camera
        v.onCameraChange = { camera = $0 }
        v.onClick = onClick
        return v
    }

    func updateNSView(_ v: CanvasEventNSView, context: Context) {
        // Only push a camera the view did not itself originate, or a drag
        // fights its own updates.
        if v.camera != camera { v.camera = camera }
        v.onCameraChange = { camera = $0 }
        v.onClick = onClick
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasEventViewTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasEventView.swift MaughamTests/Canvas/CanvasEventViewTests.swift project.yml
git commit -m "feat(canvas): scroll/magnify camera input via NSViewRepresentable"
```

---

### Task 7: The renderer

**Files:**
- Create: `Maugham/Canvas/CanvasRenderer.swift`
- Test: `MaughamTests/Canvas/CanvasRendererTests.swift`

**Interfaces:**
- Consumes: `CanvasScene`, `CanvasNode`, `CanvasCamera`, `ScrapLayout`.
- Produces: `enum CanvasRenderer` with `static func seededRotation(for id: CanvasNodeID) -> Angle`, `static func visibleNodes(in scene: CanvasScene, camera: CanvasCamera, viewSize: CGSize) -> [CanvasNode]`, and `static func draw(scene:camera:viewSize:layouts:into cx: inout GraphicsContext)`.

§7.2's seeded sub-degree rotation becomes a transform in the draw call. The seed derives from the node id and is **stable** — a card must never shimmer between renders.

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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRendererTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasRenderer' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import SwiftUI

/// The draw pass. Everything on the canvas is drawn — there are ~2 views on
/// screen rather than 300 (spec §7A.1), which is what keeps the surface out of
/// the macOS 15 `_hitTestForEvent` regression and away from SwiftUI's missing
/// lazy 2D container.
enum CanvasRenderer {

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

    /// Draw every visible node under the camera's CTM.
    ///
    /// `editingNodeID` is skipped: while a scrap's editor is live, the editor IS
    /// the visible text, so drawing it too would double-draw (spec §7A.2, the
    /// rule borrowed from Excalidraw).
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

            var layer = cx
            // Rotate about the card's own centre, not the canvas origin.
            layer.translateBy(x: frame.midX, y: frame.midY)
            layer.rotate(by: seededRotation(for: node.id))
            layer.translateBy(x: -frame.midX, y: -frame.midY)

            drawCard(node, frame: frame, layout: layouts[node.id], into: &layer)
        }
    }

    /// §7.2: crisp edges, honest objects sitting on the textured ground. The
    /// real/manufactured line runs between the ground and the cards, not through
    /// each card — so no paper fibre here.
    private static func drawCard(_ node: CanvasNode,
                                 frame: CGRect,
                                 layout: ScrapLayout?,
                                 into cx: inout GraphicsContext) {
        let shape = Path(roundedRect: frame, cornerRadius: 3)

        // Light falls from one corner (§7.1) — a single soft drop, not a glow.
        cx.drawLayer { shadow in
            shadow.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, x: 1, y: 2))
            shadow.fill(shape, with: .color(.white))
        }
        cx.fill(shape, with: .color(Color(nsColor: .textBackgroundColor)))
        cx.stroke(shape, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)

        guard let layout else { return }
        cx.drawLayer { inner in
            inner.clip(to: shape)
            inner.withCGContext { cg in
                cg.saveGState()
                cg.translateBy(x: frame.minX, y: frame.minY)
                layout.draw(into: cg, at: .zero)
                cg.restoreGState()
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRendererTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasRenderer.swift MaughamTests/Canvas/CanvasRendererTests.swift project.yml
git commit -m "feat(canvas): draw pass — viewport culling, stable seeded card rotation"
```

---

### Task 8: The ground

**Files:**
- Create: `Maugham/Canvas/CanvasGround.metal`
- Create: `Maugham/Canvas/CanvasGround.swift`
- Test: `MaughamTests/Canvas/CanvasGroundTests.swift`
- Modify: `project.yml` (the `.metal` file must join the Maugham target's sources)

**Interfaces:**
- Consumes: `CanvasCamera`.
- Produces: `struct CanvasGround: View` taking `camera: CanvasCamera` and `wash: [Color]`; `enum CanvasGroundPalette` with `static func wash(from swatches: [Color]) -> [Color]` and `static let washOpacity: Double`.

**Hard constraint (spec §7A.4):** a shader applied *over* a subtree containing an `NSViewRepresentable` logs a warning and renders a placeholder. The ground must be a **sibling layer beneath** the content, never an overlay across it. Task 9 composes it that way; this task must not introduce an overlay.

- [ ] **Step 1: Write the failing test**

The shader itself is GPU code and is verified by eye in the smoke. What is testable — and what has a stated failure mode in the spec — is the wash dosage.

```swift
import XCTest
import SwiftUI
@testable import Maugham

final class CanvasGroundTests: XCTestCase {

    /// §7.1: "Dosage is the risk — at 15% a grim palette yields a canvas you
    /// cannot work on. The wash is felt, not seen."
    func test_washOpacityStaysInTheFeltNotSeenBand() {
        XCTAssertGreaterThanOrEqual(CanvasGroundPalette.washOpacity, 0.03)
        XCTAssertLessThanOrEqual(CanvasGroundPalette.washOpacity, 0.05)
    }

    func test_washFromNoSwatches_isEmptyNotACrash() {
        XCTAssertTrue(CanvasGroundPalette.wash(from: []).isEmpty)
    }

    func test_washIsCappedSoOnePaletteCannotStripeTheGround() {
        let many = (0..<40).map { _ in Color.red }
        XCTAssertLessThanOrEqual(CanvasGroundPalette.wash(from: many).count, 5)
    }

    func test_washPreservesSwatchOrder() {
        let swatches: [Color] = [.red, .green, .blue]
        XCTAssertEqual(CanvasGroundPalette.wash(from: swatches).count, 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasGroundTests CODE_SIGNING_ALLOWED=NO`
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

// pan/zoom arrive as uniforms so the grain is sampled in content space and
// stays put under the writer's hand.
[[ stitchable ]]
half4 canvasGround(float2 position,
                   half4 currentColor,
                   float2 pan,
                   float zoom,
                   half4 base,
                   float grainScale) {
    float2 content = (position - pan) / max(zoom, 0.0001);

    // Fade grain amplitude as a function of zoom to kill moire on zoom-out.
    // Analytically fwidth(content) == 1.0/zoom, so no derivative functions are
    // needed (spec §7A.4).
    float amplitude = 0.055 * smoothstep(0.25, 1.0, zoom);

    float n = valueNoise(content * grainScale) - 0.5;
    half3 rgb = base.rgb + half3(half(n * amplitude));

    // Light falls from one corner (§7.1). Light ages better than texture.
    float2 lit = content * 0.0004;
    half fall = half(clamp(1.0 - 0.10 * length(lit - float2(-0.35, -0.35)), 0.86, 1.0));

    return half4(rgb * fall, base.a);
}
```

- [ ] **Step 4: Write the Swift side**

`Maugham/Canvas/CanvasGround.swift`:

```swift
import SwiftUI

/// The canvas ground.
///
/// MUST be a sibling layer BENEATH the content, never an overlay across it: a
/// shader applied over a subtree containing an `NSViewRepresentable` logs a
/// warning and renders a placeholder (spec §7A.4, documented on
/// `colorEffect`/`layerEffect`/`distortionEffect`). The canvas has an
/// `NSViewRepresentable` in it — the event view, and the mounted scrap editor.
struct CanvasGround: View {
    let camera: CanvasCamera
    /// 3–5% wash from the project's own sensory palette swatches (§7.1).
    let wash: [Color]

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
            .overlay {
                // The wash is felt, not seen — see CanvasGroundPalette.washOpacity.
                if !wash.isEmpty {
                    LinearGradient(colors: wash, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(CanvasGroundPalette.washOpacity)
                        .blendMode(.softLight)
                }
            }
            .drawingGroup()   // keeps the grain off the content subtree
            .allowsHitTesting(false)
    }
}

enum CanvasGroundPalette {
    /// §7.1 names the dosage and names the risk: "Washed 3–5% by the project's
    /// own sensory palette swatches… at 15% a grim palette yields a canvas you
    /// cannot work on. The wash is felt, not seen."
    static let washOpacity: Double = 0.04

    /// At most five swatches. A palette with thirty entries would stripe the
    /// ground rather than tint it.
    static func wash(from swatches: [Color]) -> [Color] {
        Array(swatches.prefix(5))
    }
}
```

- [ ] **Step 5: Add the `.metal` file to the target**

The `.metal` source must compile into the Maugham target. Confirm `project.yml`'s Maugham target sources include `Maugham/Canvas/` (it will, if the directory is listed wholesale), then `./gen.sh` and check the build log names `CanvasGround.metal`:

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -i "metal\|CanvasGround"
```
Expected: a `CompileMetalFile` line for `CanvasGround.metal`. If absent, add an explicit source entry in `project.yml` and re-run.

- [ ] **Step 6: Run the tests and a Release build**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasGroundTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 4 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasGround.metal Maugham/Canvas/CanvasGround.swift MaughamTests/Canvas/CanvasGroundTests.swift project.yml
git commit -m "feat(canvas): ground — content-space grain, palette wash at felt-not-seen dosage"
```

---

### Task 9: The canvas view and the focused editor

**Files:**
- Create: `Maugham/Canvas/ScrapEditorHost.swift`
- Create: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/ScrapEditorHostTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces: `struct CanvasView: View` taking `projectRoot: URL`, `paletteSwatches: [Color]`; `struct ScrapEditorHost: NSViewRepresentable` taking `layout: ScrapLayout`, `frame: CGRect`, `zoom: CGFloat`, `caretIndex: Int?`.

**Zoomed editing uses bounds scaling** — the spike's Q4. Grow the container's `frame` by zoom, hold its `bounds` at the unzoomed size. Coordinates round-trip correctly at every zoom tested (1×–3×) and AppKit re-rasterises, so text stays crisp. Crucially it involves **no re-layout**, so Task 3's proven drawn/edited agreement carries over unchanged. Do not reach for `.scaleEffect`, and do not re-lay-out the editor at a scaled font size.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AppKit
@testable import Maugham

final class ScrapEditorHostTests: XCTestCase {

    private func layout() -> ScrapLayout {
        ScrapLayout(text: "The falls at night: sodium light on the spray, and nobody "
                    + "there but the man selling ponchos.",
                    width: 240,
                    font: NSFont(name: "Iowan Old Style", size: 13) ?? .systemFont(ofSize: 13))
    }

    func test_boundsScalingLeavesTheUnzoomedCoordinateSpaceIntact() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: CGSize(width: 240, height: 100), zoom: 2)
        XCTAssertEqual(container.frame.size, CGSize(width: 480, height: 200))
        XCTAssertEqual(container.bounds.size, CGSize(width: 240, height: 100),
                       "bounds must stay unzoomed — that is what keeps the drawn "
                       + "and edited layouts identical at zoom")
    }

    func test_zoomChangeResizesFrameButNeverBounds() {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout()
        container.mount(layout: l, unscaledSize: CGSize(width: 240, height: 100), zoom: 1)
        let signature = l.lineGeometrySignature
        container.mount(layout: l, unscaledSize: CGSize(width: 240, height: 100), zoom: 3)
        XCTAssertEqual(container.bounds.size, CGSize(width: 240, height: 100))
        XCTAssertEqual(l.lineGeometrySignature, signature,
                       "zooming must not re-lay-out the text")
    }

    func test_mountedEditorSharesTheLayoutStack() {
        let container = ScrapEditorContainer(frame: .zero)
        let l = layout()
        container.mount(layout: l, unscaledSize: CGSize(width: 240, height: 100), zoom: 1)
        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(l.text.hasPrefix("Z"))
    }

    func test_remountingReplacesRatherThanStacksEditors() {
        let container = ScrapEditorContainer(frame: .zero)
        container.mount(layout: layout(), unscaledSize: CGSize(width: 240, height: 100), zoom: 1)
        container.mount(layout: layout(), unscaledSize: CGSize(width: 240, height: 100), zoom: 1)
        XCTAssertEqual(container.subviews.count, 1,
                       "a second mount must not leave the first editor behind")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapEditorHostTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'ScrapEditorContainer' in scope`.

- [ ] **Step 3: Write the editor host**

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
final class ScrapEditorContainer: NSView {

    private(set) var textView: NSTextView?

    override var isFlipped: Bool { true }

    func mount(layout: ScrapLayout, unscaledSize: CGSize, zoom: CGFloat) {
        if textView == nil {
            let tv = layout.makeEditor(frame: CGRect(origin: .zero, size: unscaledSize))
            addSubview(tv)
            textView = tv
        }
        textView?.frame = CGRect(origin: .zero, size: unscaledSize)

        // Frame in zoomed (view) space; bounds in unzoomed (content) space.
        frame = CGRect(origin: frame.origin,
                       size: CGSize(width: unscaledSize.width * zoom,
                                    height: unscaledSize.height * zoom))
        bounds = CGRect(origin: .zero, size: unscaledSize)
    }

    func unmount() {
        textView?.removeFromSuperview()
        textView = nil
    }
}

/// SwiftUI wrapper. Exactly one of these is ever in the hierarchy — the scrap
/// currently being edited (spec §7A.1).
struct ScrapEditorHost: NSViewRepresentable {
    let layout: ScrapLayout
    let unscaledSize: CGSize
    let zoom: CGFloat
    /// Where the writer clicked, so the caret lands where they aimed
    /// (spec §7A.2, `characterIndexForInsertion` rule borrowed from Miro).
    let caretIndex: Int?

    func makeNSView(context: Context) -> ScrapEditorContainer {
        let c = ScrapEditorContainer(frame: .zero)
        c.mount(layout: layout, unscaledSize: unscaledSize, zoom: zoom)
        if let caretIndex, let tv = c.textView {
            tv.setSelectedRange(NSRange(location: caretIndex, length: 0))
            tv.window?.makeFirstResponder(tv)
        }
        return c
    }

    func updateNSView(_ c: ScrapEditorContainer, context: Context) {
        c.mount(layout: layout, unscaledSize: unscaledSize, zoom: zoom)
    }

    static func dismantleNSView(_ c: ScrapEditorContainer, coordinator: ()) {
        c.unmount()
    }
}
```

- [ ] **Step 4: Write the composed view**

`Maugham/Canvas/CanvasView.swift`. Note the layer order — ground **beneath**, never an overlay (spec §7A.4).

```swift
import SwiftUI

/// The Plan persona's centre column.
///
/// Layer order matters and is a hard constraint, not a preference: the ground
/// is a SIBLING BENEATH the content. A shader applied *over* a subtree holding
/// an `NSViewRepresentable` renders a placeholder (spec §7A.4), and this view
/// has two of them — the event view and the mounted scrap editor.
struct CanvasView: View {
    let projectRoot: URL
    let paletteSwatches: [Color]

    @State private var camera = CanvasCamera()
    @State private var scene = CanvasScene()
    @State private var scraps: [CanvasNodeID: String] = [:]
    @State private var layouts: [CanvasNodeID: ScrapLayout] = [:]
    @State private var editingNodeID: CanvasNodeID?
    @State private var caretIndex: Int?
    @State private var store: CanvasStore?

    private let scrapFont = NSFont(name: "Iowan Old Style", size: 13)
        ?? .systemFont(ofSize: 13)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CanvasGround(camera: camera,
                             wash: CanvasGroundPalette.wash(from: paletteSwatches))

                Canvas { cx, size in
                    CanvasRenderer.draw(scene: scene, camera: camera, viewSize: size,
                                        layouts: layouts, editingNodeID: editingNodeID,
                                        into: &cx)
                }

                if let id = editingNodeID,
                   let node = scene.node(id),
                   let layout = layouts[id],
                   let frame = node.frame {
                    ScrapEditorHost(layout: layout,
                                    unscaledSize: frame.size,
                                    zoom: camera.zoom,
                                    caretIndex: caretIndex)
                        .frame(width: frame.width * camera.zoom,
                               height: frame.height * camera.zoom)
                        .position(x: camera.viewPoint(fromContent: frame.origin).x
                                     + frame.width * camera.zoom / 2,
                                  y: camera.viewPoint(fromContent: frame.origin).y
                                     + frame.height * camera.zoom / 2)
                }

                CanvasEventView(camera: $camera, onClick: { viewPoint in
                    handleClick(at: camera.contentPoint(fromView: viewPoint))
                })
            }
            .onAppear { load(viewSize: geo.size) }
            .onDisappear { store?.flush(scene: scene, scraps: scraps) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(viewSize: CGSize) {
        let s = CanvasStore(projectRoot: projectRoot)
        store = s
        let loaded = s.load()
        scene = loaded.scene
        scraps = loaded.scraps
        rebuildLayouts()
    }

    /// Build a layout per scrap and fill in the derived heights the model needs
    /// for hit testing and culling.
    private func rebuildLayouts() {
        for node in scene.nodes {
            guard case .scrap = node.kind else { continue }
            let layout = ScrapLayout(text: scraps[node.id] ?? "",
                                     width: node.width, font: scrapFont)
            layouts[node.id] = layout
            scene.setCachedHeight(layout.measuredHeight, for: node.id)
        }
    }

    private func handleClick(at contentPoint: CGPoint) {
        // Commit any in-flight edit before moving focus, so the drawn text the
        // renderer picks up is current.
        if let editing = editingNodeID, let layout = layouts[editing] {
            scraps[editing] = layout.text
            scene.setCachedHeight(layout.measuredHeight, for: editing)
        }

        guard let node = scene.topmostNode(at: contentPoint),
              case .scrap = node.kind,
              let layout = layouts[node.id],
              let frame = node.frame else {
            editingNodeID = nil
            caretIndex = nil
            store?.scheduleSave(scene: scene, scraps: scraps)
            return
        }

        editingNodeID = node.id
        caretIndex = layout.characterIndex(
            at: CGPoint(x: contentPoint.x - frame.minX, y: contentPoint.y - frame.minY))
        store?.scheduleSave(scene: scene, scraps: scraps)
    }
}
```

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapEditorHostTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 4 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. **A Debug pass is not evidence** — the Release type-check budget is stricter, and v0.8.0 shipped a Release-only failure this way.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/ScrapEditorHost.swift Maugham/Canvas/CanvasView.swift MaughamTests/Canvas/ScrapEditorHostTests.swift project.yml
git commit -m "feat(canvas): composed surface + one bounds-scaled editor on the focused scrap"
```

---

### Task 10: Wire the canvas into the Plan persona

**Files:**
- Modify: `Maugham/Models/BinderSegment.swift`
- Modify: `Maugham/Models/Persona.swift:151-164` (Plan's `binderSegments(for:)`)
- Modify: `Maugham/Views/ProjectWindow.swift` (`existingEditorSwitch`, `existingInspectorSwitch`, `shouldShowStatusFooter`)
- Test: `MaughamTests/Canvas/CanvasSegmentTests.swift`
- Test: `MaughamTests/PersonaBinderSegmentTests.swift` (extend)

**No new top-level modifier.** `ProjectWindow.existingEditorSwitch` already routes the centre column on `binderSegment`, so adding `case canvas` puts the canvas there. Adding the case makes the compiler enumerate every exhaustive switch over `BinderSegment` — that is the mechanism, and it is why this is one task rather than a hunt.

Expect the compiler to name: `BinderSegment.isTransient`, `displayName(for:)`, `pickerSymbolName`, `ProjectWindow.existingEditorSwitch`, `ProjectWindow.existingInspectorSwitch`. Also check `ProjectWindow.swift:789`'s `shouldShowStatusFooter` guard, which is an `==` comparison rather than a switch and so will **not** be flagged.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham
import MaughamCore

final class CanvasSegmentTests: XCTestCase {

    func test_planOffersTheCanvasFirstOnEveryProjectType() {
        for type in [ProjectType.novel, .screenplay, .collection] {
            let segments = Persona.plan.binderSegments(for: type)
            XCTAssertEqual(segments.first, .canvas,
                           "Plan's centre column is the canvas (design §6.3) — \(type)")
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasSegmentTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `type 'BinderSegment' has no member 'canvas'`.

- [ ] **Step 3: Add the case and let the compiler enumerate the work**

In `Maugham/Models/BinderSegment.swift`, add to the enum:

```swift
    /// The Plan persona's centre column — the freeform planning canvas (M1C).
    /// One canvas per project (spec §2); regions do all the dividing.
    case canvas
```

Then build and let the compiler list every switch that must grow an arm:

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -A2 "must be exhaustive"
```

Fill in each site:

`BinderSegment.isTransient` — `.canvas` joins the non-transient list:
```swift
        case .manuscript, .research, .palette, .scenes, .canvas: return false
```

`BinderSegment.displayName(for:)`:
```swift
        case .canvas: return "Canvas"
```

`BinderSegment.pickerSymbolName` — every segment must return a symbol, or the picker's uniform-`Image` `ForEach` breaks:
```swift
        case .canvas: return "square.on.circle"
```

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

Update the doc comment above `binderSegments(for:)`: the line reading "Two of those four surfaces do not exist yet (M1C builds the canvas, M1D the editions list)" now has one fewer — change to "One of those four surfaces does not exist yet (M1D builds the editions list)".

- [ ] **Step 5: Route the centre column and the inspector**

In `ProjectWindow.existingEditorSwitch`, add:

```swift
        case .canvas:
            CanvasView(projectRoot: store.rootURL,
                       paletteSwatches: store.paletteSwatchColors)
```

In `ProjectWindow.existingInspectorSwitch`, add. Note the full-frame chain — tripwire 15 has recurred four or more times:

```swift
        case .canvas:
            ContentUnavailableView("Canvas", systemImage: "square.on.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
```

If `ProjectStore` has no `paletteSwatchColors`, add it as a small computed property beside the existing palette accessors rather than reaching into the manifest from `CanvasView` — the canvas must not learn the palette's storage shape.

- [ ] **Step 6: Check the footer guard the compiler cannot see**

`ProjectWindow.swift:789` reads:

```swift
        guard binderSegment == .manuscript || binderSegment == .scenes else {
```

This is an `==` comparison, so adding the case does **not** flag it. The behaviour is already correct — the word-count footer should not show on the canvas — so leave it. Add a comment so the next reader knows it was considered rather than missed:

```swift
        // `.canvas` is deliberately absent: the footer reports manuscript
        // metrics, and readiness stays silent about the canvas (umbrella §7, §9).
        guard binderSegment == .manuscript || binderSegment == .scenes else {
```

- [ ] **Step 7: Run the full suite and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: the whole Mac suite green. Integration failures only surface in the FULL suite — the edition-identity milestone learned this the expensive way; do not call this task done off a filtered run.

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: green — this confirms nothing leaked into MaughamCore, since M1C is Mac-only by design.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Models/BinderSegment.swift Maugham/Models/Persona.swift Maugham/Views/ProjectWindow.swift MaughamTests/Canvas/CanvasSegmentTests.swift
git commit -m "feat(canvas): Plan's centre column is the canvas

Adds BinderSegment.canvas and puts it at the head of Plan's binder
segments, so it is also Plan's binderHome. No new top-level modifier —
existingEditorSwitch already routes on binderSegment."
```

---

### Task 11: Create, move and resize scraps

**Files:**
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasInteractionTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `CanvasInteraction` — a pure state machine for drag/resize/create, so the gestures are testable without a window.

Motion: §7.3 says cards carry momentum and come to rest rather than snapping. That lives here.

- [ ] **Step 1: Write the failing test**

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
        i.update(to: CGPoint(x: 950, y: 950), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.origin, CGPoint(x: 100, y: 100))
    }

    func test_dragPreservesWidthAndInvalidatesNothing() {
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

    func test_newScrapLandsAtTheClickAndOnTop() {
        var scene = sceneWithOneScrap()
        let id = CanvasInteraction.createScrap(at: CGPoint(x: 500, y: 400), in: &scene)
        let n = scene.node(id)
        XCTAssertEqual(n?.origin, CGPoint(x: 500, y: 400))
        XCTAssertGreaterThan(n!.z, scene.node(CanvasNodeID("s1"))!.z)
    }

    func test_createdScrapIDsAreUnique() {
        var scene = CanvasScene()
        let ids = (0..<200).map { _ in CanvasInteraction.createScrap(at: .zero, in: &scene) }
        XCTAssertEqual(Set(ids).count, 200)
        XCTAssertEqual(scene.nodes.count, 200)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasInteraction' in scope`.

- [ ] **Step 3: Write the implementation**

Add to `Maugham/Canvas/CanvasView.swift` (or a peer file `CanvasInteraction.swift` if the view file is growing):

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

    var isActive: Bool { mode != .idle }

    mutating func begin(at contentPoint: CGPoint, in scene: CanvasScene) {
        guard let node = scene.topmostNode(at: contentPoint) else { mode = .idle; return }
        mode = .moving(node.id, grabOffset: CGSize(width: contentPoint.x - node.origin.x,
                                                   height: contentPoint.y - node.origin.y))
    }

    mutating func beginResize(_ id: CanvasNodeID, at contentPoint: CGPoint, in scene: CanvasScene) {
        guard let node = scene.node(id) else { mode = .idle; return }
        mode = .resizing(id, startWidth: node.width, startX: contentPoint.x)
    }

    mutating func update(to contentPoint: CGPoint, in scene: inout CanvasScene) {
        switch mode {
        case .idle:
            break
        case .moving(let id, let grab):
            scene.move(id, to: CGPoint(x: contentPoint.x - grab.width,
                                       y: contentPoint.y - grab.height))
        case .resizing(let id, let startWidth, let startX):
            // §7A.3: width is authoritative, the text reflows, the height is
            // derived. `setWidth` clears the cached height for exactly that
            // reason — the next measure pass refills it.
            scene.setWidth(max(Self.minimumScrapWidth, startWidth + (contentPoint.x - startX)),
                           for: id)
        }
    }

    mutating func end() { mode = .idle }

    /// Mint a scrap at a point. IDs are unique within the scene by construction
    /// rather than by luck — the canvas will accumulate hundreds of these, and
    /// a 4-character random id collides at that scale (tripwire 23's lesson,
    /// applied to a different id space).
    static func createScrap(at contentPoint: CGPoint, in scene: inout CanvasScene) -> CanvasNodeID {
        var id = CanvasNodeID(UUID().uuidString.prefix(8).lowercased())
        while scene.node(id) != nil {
            id = CanvasNodeID(UUID().uuidString.prefix(8).lowercased())
        }
        let topZ = scene.nodes.last?.z ?? 0
        scene.insert(CanvasNode(id: id, kind: .scrap, origin: contentPoint,
                                width: defaultScrapWidth, cachedHeight: nil, z: topZ + 1))
        return id
    }
}
```

Then wire it into `CanvasView`: give `CanvasEventNSView` `onDragBegan`/`onDragChanged`/`onDragEnded` callbacks alongside `onClick` (mirroring `mouseDragged`/`mouseUp`), drive `CanvasInteraction` from them, and add a double-click-on-empty-space path that calls `createScrap` and focuses the new scrap immediately.

For §7.3's momentum: on `end()`, if the drag had velocity, animate the node's origin to rest with `withAnimation(.interpolatingSpring(stiffness: 170, damping: 22))`. Cards come to rest rather than snapping; this reads as craft and, unlike texture, never dates.

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 7 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas/CanvasInteractionTests.swift project.yml
git commit -m "feat(canvas): create, move and resize scraps; width authoritative, height derived"
```

---

### Task 12: Item nodes

**Files:**
- Modify: `Maugham/Canvas/CanvasRenderer.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasItemNodeTests.swift`

Items appear on the canvas **as themselves**; the canvas holds only their position, the file on disk is untouched, and deleting a node from the canvas removes it from the canvas, never from the project (spec §3.1).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasItemNodeTests: XCTestCase {

    func test_addingTheSameResearchItemTwiceYieldsOneNode() {
        var scene = CanvasScene()
        CanvasItemNode.add(referenceId: "r-9", at: CGPoint(x: 0, y: 0), in: &scene)
        CanvasItemNode.add(referenceId: "r-9", at: CGPoint(x: 500, y: 500), in: &scene)
        XCTAssertEqual(scene.nodes.count, 1)
    }

    func test_addingTheSameItemAgainMovesTheExistingNode() {
        var scene = CanvasScene()
        CanvasItemNode.add(referenceId: "r-9", at: CGPoint(x: 0, y: 0), in: &scene)
        CanvasItemNode.add(referenceId: "r-9", at: CGPoint(x: 500, y: 500), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID.item("r-9"))?.origin, CGPoint(x: 500, y: 500))
    }

    func test_removingAnItemNodeReportsNoProjectDeletion() {
        var scene = CanvasScene()
        CanvasItemNode.add(referenceId: "r-9", at: .zero, in: &scene)
        let outcome = CanvasItemNode.remove(CanvasNodeID.item("r-9"), from: &scene)
        XCTAssertEqual(outcome, .removedFromCanvasOnly,
                       "spec §3.1: never from the project")
        XCTAssertTrue(scene.isEmpty)
    }

    func test_itemNodeIDEncodesItsReference() {
        XCTAssertEqual(CanvasNodeID.item("r-9").raw, "item:r-9")
    }

    func test_itemAndScrapWithTheSameRawStringDoNotCollide() {
        var scene = CanvasScene()
        CanvasItemNode.add(referenceId: "r-9", at: .zero, in: &scene)
        scene.insert(CanvasNode(id: CanvasNodeID("r-9"), kind: .scrap,
                                origin: .zero, width: 240))
        XCTAssertEqual(scene.nodes.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasItemNodeTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasItemNode' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Item nodes: things that already exist, appearing on the canvas as themselves.
///
/// The canvas holds ONLY their position (spec §3.1). The file on disk is
/// untouched and remains the truth, and removing a node from the canvas removes
/// it from the canvas — never from the project. The return type of `remove`
/// says so at the type level rather than in a comment, because "delete" on a
/// spatial surface is exactly the gesture a writer will fear.
enum CanvasItemNode {

    enum RemovalOutcome: Equatable {
        /// The only outcome there is. Named rather than `Void` so a future
        /// author reaching for a project-level delete has to add a case, and
        /// adding it means arguing with spec §3.1.
        case removedFromCanvasOnly
        case notPresent
    }

    /// Idempotent by construction: the node id is derived from the reference, so
    /// adding the same research item twice moves the node the writer already has
    /// rather than minting a second one. Two nodes for one note would be the
    /// copy problem §4.3 rejects outright.
    static func add(referenceId: String, at contentPoint: CGPoint, in scene: inout CanvasScene) {
        let id = CanvasNodeID.item(referenceId)
        if scene.node(id) != nil {
            scene.move(id, to: contentPoint)
            return
        }
        let topZ = scene.nodes.last?.z ?? 0
        scene.insert(CanvasNode(id: id, kind: .item(referenceId: referenceId),
                                origin: contentPoint, width: 180,
                                cachedHeight: 120, z: topZ + 1))
    }

    @discardableResult
    static func remove(_ id: CanvasNodeID, from scene: inout CanvasScene) -> RemovalOutcome {
        guard scene.node(id) != nil else { return .notPresent }
        scene.remove(id)
        return .removedFromCanvasOnly
    }
}
```

Then in `CanvasRenderer.drawCard`, branch on `node.kind`: a `.scrap` draws its `ScrapLayout`; an `.item` draws its title and a small kind glyph, resolved by `CanvasView` from the project store and passed in as a `[CanvasNodeID: CanvasItemPresentation]` map. Keep the resolution in `CanvasView` — the renderer must not learn how to read a manifest.

Add a drop target on `CanvasView` accepting research items from the binder, calling `CanvasItemNode.add`.

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasItemNodeTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 5 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas/CanvasItemNodeTests.swift project.yml
git commit -m "feat(canvas): item nodes — reference-derived ids, canvas-only removal"
```

---

### Task 13: Undo — resolving spec §10

**Files:**
- Create: `Maugham/Canvas/CanvasUndo.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasUndoTests.swift`

**Spec §10 left this open:** *"Canvas edits are sidecar state, not op-log ops. Whether ⌘Z spans them, and if so how, given ADR 0023's op-log-backed model."*

**Decision: a canvas-scoped `NSUndoManager`, not the op log.** Three reasons, and the plan states them so the next reader does not relitigate:

1. ADR 0023's unified undo works by appending **compensating ops** to the op log. Canvas geometry is explicitly derived state that may be deleted without loss (spec §8). Putting it in the op log would make the sidecar non-derived — it would become the only record of a move — and that contradicts §8 directly.
2. ⌘Z already means "undo what is in front of you": in the editor it undoes text via the editor's own undo manager. A canvas-scoped manager is the same rule, not a new one.
3. Doing nothing is not an option. A drag that scatters a carefully arranged region with no way back is the single most likely way this surface loses a writer's trust.

The subtlety: **scrap text and scrap geometry must share one stack.** The mounted `NSTextView` brings its own undo manager, and if it stays separate, ⌘Z after typing-then-dragging undoes the drag while the writer expects the typing. The canvas view supplies its undo manager to the text view so both land on one stack in the order they happened.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AppKit
@testable import Maugham

final class CanvasUndoTests: XCTestCase {

    private func sceneWithScrap() -> CanvasScene {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap,
                           origin: CGPoint(x: 100, y: 100), width: 240)
        n.cachedHeight = 80
        s.insert(n)
        return s
    }

    func test_undoRestoresAMovedNode() {
        var scene = sceneWithScrap()
        let undo = UndoManager()
        let recorder = CanvasUndo(undoManager: undo)

        recorder.recordMove(CanvasNodeID("a"), from: CGPoint(x: 100, y: 100), in: { $0 })
        scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        recorder.apply(&scene)

        undo.undo()
        recorder.apply(&scene)
        XCTAssertEqual(scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
    }

    func test_redoReappliesTheMove() {
        var scene = sceneWithScrap()
        let undo = UndoManager()
        let recorder = CanvasUndo(undoManager: undo)
        recorder.recordMove(CanvasNodeID("a"), from: CGPoint(x: 100, y: 100), in: { $0 })
        scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        recorder.apply(&scene)
        undo.undo(); recorder.apply(&scene)
        undo.redo(); recorder.apply(&scene)
        XCTAssertEqual(scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 900, y: 900))
    }

    func test_undoRestoresADeletedScrapAndItsText() {
        var scene = sceneWithScrap()
        var scraps = [CanvasNodeID("a"): "The falls at night."]
        let undo = UndoManager()
        let recorder = CanvasUndo(undoManager: undo)

        recorder.recordDelete(CanvasNodeID("a"), node: scene.node(CanvasNodeID("a"))!,
                              text: scraps[CanvasNodeID("a")])
        scene.remove(CanvasNodeID("a"))
        scraps[CanvasNodeID("a")] = nil

        undo.undo()
        recorder.apply(&scene, scraps: &scraps)
        XCTAssertNotNil(scene.node(CanvasNodeID("a")))
        XCTAssertEqual(scraps[CanvasNodeID("a")], "The falls at night.",
                       "restoring a node without its words is not an undo")
    }

    /// A drag emits a position per frame. One ⌘Z must undo the whole gesture,
    /// not 60 of them.
    func test_oneDragIsOneUndoStep() {
        var scene = sceneWithScrap()
        let undo = UndoManager()
        let recorder = CanvasUndo(undoManager: undo)

        recorder.beginGesture("Move Scrap")
        recorder.recordMove(CanvasNodeID("a"), from: CGPoint(x: 100, y: 100), in: { $0 })
        for x in stride(from: CGFloat(110), through: 900, by: 10) {
            scene.move(CanvasNodeID("a"), to: CGPoint(x: x, y: 100))
        }
        recorder.endGesture()

        undo.undo()
        recorder.apply(&scene)
        XCTAssertEqual(scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
        XCTAssertFalse(undo.canUndo, "the whole drag must collapse into one step")
    }

    func test_undoActionNamesAreWriterFacing() {
        let undo = UndoManager()
        let recorder = CanvasUndo(undoManager: undo)
        recorder.beginGesture("Move Scrap")
        recorder.recordMove(CanvasNodeID("a"), from: .zero, in: { $0 })
        recorder.endGesture()
        XCTAssertEqual(undo.undoActionName, "Move Scrap")
    }

    /// Camera moves are navigation, not edits. Undoing a pan would be baffling.
    func test_panningAndZoomingAreNotUndoable() {
        let undo = UndoManager()
        let recorder = CanvasUndo(undoManager: undo)
        recorder.noteCameraChanged()
        XCTAssertFalse(undo.canUndo)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasUndoTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasUndo' in scope`.

- [ ] **Step 3: Write the implementation**

`CanvasUndo` wraps an `NSUndoManager` and records inverse closures. Key points to encode:

```swift
import AppKit

/// Undo for the canvas.
///
/// Spec §10 left this open. The answer is a canvas-scoped `UndoManager`, NOT
/// the op log, and the reasoning must survive:
///
/// ADR 0023's unified undo appends COMPENSATING OPS to the op log. Canvas
/// geometry is derived state that may be deleted without loss (spec §8).
/// Putting it in the op log would make the sidecar the only record of a move —
/// no longer derived — which contradicts §8 directly. ⌘Z already means "undo
/// what is in front of you"; in the editor it runs the editor's own undo
/// manager. This is the same rule, not a new one.
///
/// Scrap TEXT and scrap GEOMETRY share ONE stack. The mounted `NSTextView`
/// brings its own undo manager, and if it stays separate then ⌘Z after
/// typing-then-dragging undoes the drag while the writer is expecting the
/// typing. `CanvasView` hands this manager to the text view (via
/// `NSTextViewDelegate.undoManager(for:)`) so both land on one stack in the
/// order they happened.
///
/// Camera changes are NOT undoable — panning and zooming are navigation, and
/// undoing a pan would be baffling.
final class CanvasUndo {
    private let undoManager: UndoManager
    init(undoManager: UndoManager) { self.undoManager = undoManager }

    /// Coalesce a whole drag into one step. A drag emits a position per frame;
    /// without grouping, one ⌘Z would rewind a single frame of it.
    func beginGesture(_ name: String) {
        undoManager.beginUndoGrouping()
        undoManager.setActionName(name)
    }

    func endGesture() { undoManager.endUndoGrouping() }

    func noteCameraChanged() { /* deliberately not undoable — see the class doc */ }
    …
}
```

Register inverses with `undoManager.registerUndo(withTarget:handler:)`, capturing the prior value. Each registration re-registers its own inverse on undo, which is what gives redo for free.

In `CanvasView`, own an `UndoManager`, pass it to `CanvasUndo`, and supply it to the mounted editor by making `ScrapEditorContainer`'s text view delegate return it from `undoManager(for:)`. Wrap every `CanvasInteraction` gesture in `beginGesture`/`endGesture`.

**Do not** use `@Environment(\.undoManager)` — the canvas needs a manager whose lifetime matches the canvas, not the window, or a persona switch mid-drag leaves a half-open group.

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasUndoTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 6 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasUndo.swift Maugham/Canvas/CanvasView.swift MaughamTests/Canvas/CanvasUndoTests.swift project.yml
git commit -m "feat(canvas): canvas-scoped undo covering geometry and scrap text

Resolves spec §10's undo question: an UndoManager scoped to the canvas,
not op-log compensating ops — canvas state is derived (§8) and putting
it in the op log would stop it being derived."
```

---

### Task 14: Performance bounds — resolving spec §10

**Files:**
- Test: `MaughamTests/Canvas/CanvasPerformanceProbeTests.swift`

**Spec §10 left this open:** *"Performance bounds. What node count must stay smooth. §7A.1 settles how it virtualises; the open part is the number."*

**Decision: 2,000 nodes, as a fixture-gated probe, not a wall-clock assertion.** `TypingLatencyProbeTests` is the named precedent — it is the house pattern for exactly this, because a wall-clock assertion on CI hardware is a flaky test that gets disabled and then protects nothing.

The number: tldraw ships a hard 4,000-shape cap and freezes zoom above 500 shapes; Excalidraw degrades around 5,000. A Playlist-scale collection is tens of nodes. 2,000 is far above any real canvas and well below where the surveyed tools break, so it is a ceiling that catches an algorithmic regression rather than a number the writer will ever meet.

What is actually asserted is **complexity, not milliseconds**: culling must keep the drawn set proportional to the viewport, not to the scene. That is the property §7A.1 relies on, and it is the one that can silently regress.

- [ ] **Step 1: Write the test**

```swift
import XCTest
@testable import Maugham

final class CanvasPerformanceProbeTests: XCTestCase {

    /// The bound spec §10 asked for. Far above any real canvas (a Playlist-scale
    /// collection is tens of nodes) and below where tldraw (4,000) and
    /// Excalidraw (~5,000) degrade.
    static let supportedNodeCount = 2_000

    private func bigScene(_ count: Int) -> CanvasScene {
        var s = CanvasScene()
        for i in 0..<count {
            var n = CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i % 100) * 300,
                                               y: CGFloat(i / 100) * 200),
                               width: 240)
            n.cachedHeight = 100
            s.insert(n)
        }
        return s
    }

    /// The property §7A.1 depends on: the drawn set is proportional to the
    /// VIEWPORT, not to the scene. This is a complexity assertion, not a
    /// wall-clock one — a millisecond budget on CI hardware is a flaky test
    /// that gets disabled and then protects nothing (TypingLatencyProbeTests
    /// is the house precedent).
    func test_culledSetDependsOnViewportNotSceneSize() {
        let viewSize = CGSize(width: 1200, height: 800)
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
                                                  viewSize: CGSize(width: 1200, height: 800))
        XCTAssertLessThan(visible.count, 60)
    }

    /// A fixture-gated probe: measured, reported, and only failed on an
    /// order-of-magnitude regression.
    func test_cullingAtTheSupportedBoundIsNotPathological() {
        let scene = bigScene(Self.supportedNodeCount)
        let camera = CanvasCamera()
        let viewSize = CGSize(width: 1200, height: 800)

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
        let visible = CanvasRenderer.visibleNodes(in: scene, camera: camera,
                                                  viewSize: CGSize(width: 1200, height: 800))
        print("[probe] zoomed-out cull returned \(visible.count) nodes in "
              + "\(String(format: "%.3f", Date().timeIntervalSince(start) * 1000)) ms")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasPerformanceProbeTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 4 tests. Record the two `[probe]` figures in the task report — they are the baseline a future regression is measured against.

**If `test_culledSetDependsOnViewportNotSceneSize` fails**, culling is not working and the architecture's central claim is broken. Stop and fix before continuing; do not relax the assertion.

- [ ] **Step 3: Record the bound**

Add to `Maugham/Canvas/AREA.md` (Task 15 writes the file; add this line there if it does not exist yet):

> **Supported scale: 2,000 nodes.** Not a hard cap — nothing enforces it — but the number the culling probe defends. Above it, expect the draw pass rather than the culling to become the limit. tldraw caps at 4,000; Excalidraw degrades near 5,000.

- [ ] **Step 4: Commit**

```bash
git add MaughamTests/Canvas/CanvasPerformanceProbeTests.swift project.yml
git commit -m "test(canvas): performance bound — 2,000 nodes, culling probe

Resolves spec §10's performance question. Asserts complexity (drawn set
tracks the viewport, not the scene) rather than milliseconds, per the
TypingLatencyProbeTests precedent."
```

---

### Task 15: Docs, AREA.md and the ADR

**Files:**
- Create: `Maugham/Canvas/AREA.md`
- Create: `docs/adr/0026-planning-canvas-rendering.md`
- Modify: `docs/adr/README.md`
- Modify: `CLAUDE.md` (per-area pointer table, tripwires)
- Modify: `docs/guide/` (the topic covering personas)
- Modify: `docs/roadmap.md`, `docs/problem-map.md`

Rule 10 of the default workflow: when a roadmap item flips •→✓, sweep sibling docs for now-false claims **in the same commit**. Rule 7: help/docs describe what *ships*.

- [ ] **Step 1: Write `Maugham/Canvas/AREA.md`**

Cover, at minimum:
- The architecture in three sentences and *why the alternative lost* — link the spike note. Someone will propose `NSScrollView` again.
- The three `ScrapLayout` requirements, verbatim, with the symptom each produces when broken. The `attributedString` one especially: it fails silently and looks like a UI bug rather than a wiring bug.
- Ground-beneath-not-overlay, and what happens if you get it wrong (placeholder render).
- Bounds scaling for the zoomed editor; never `.scaleEffect`; never re-layout.
- `canvas.json` is derived and deletable; `canvas.md` is content and is not.
- The test-harness note: `NSTextView.mouseDown` runs a modal tracking loop.

- [ ] **Step 2: Write ADR 0026**

Check the highest existing ADR number first — 0025 is the persona shell, so 0026 unless something landed since:

```bash
ls docs/adr/ | sort | tail -3
```

The ADR records: drawn canvas over hosted views, with the spike's measurements as the evidence; the shared-TextKit rule; scrap text in `canvas.md` and layout in the sidecar. Cite the constitution principles by name, per CLAUDE.md.

- [ ] **Step 3: Add the tripwire**

Add to CLAUDE.md's tripwire table:

| # | Rule | Why | Enforced |
|---|---|---|---|
| 25 | No `NSScrollView.magnification` under SwiftUI content, and no `.scaleEffect` for canvas zoom | SwiftUI's coordinate space is unaware of magnification — same `.global` frame at every zoom, and above ~2× clicks stop registering entirely (measured, macOS 26.5.2); `.scaleEffect` blurs text and breaks `NSCursor` tracking | `docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md`; `CanvasCameraTests` |
| 26 | `NSTextContentStorage.textStorage = NSTextStorage(...)`, never `.attributedString =` | With `attributedString` the scrap renders perfectly and silently swallows every keystroke — `textStorage` nil, `string` empty, `insertText` a no-op | `ScrapLayoutTests.test_mountedEditorActuallyEditsTheSharedStack` |

- [ ] **Step 4: Update the per-area table**

Add a `Maugham/Canvas/` row to CLAUDE.md's per-area pointer table pointing at the new AREA.md.

- [ ] **Step 5: Sweep for now-false claims**

```bash
grep -rn "canvas" docs/roadmap.md docs/problem-map.md docs/guide/ CLAUDE.md | grep -iv "corkboard"
```

Persona.swift's `binderSegments(for:)` doc comment said "M1C builds the canvas" — Task 10 already fixed that. Check `docs/adr/0025-persona-shell.md` for the same forward reference, and the guide's persona section, which currently tells writers Plan offers Research and Palette.

- [ ] **Step 6: Run the doc-sync tests and the full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/DocSyncTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: full Mac suite green.

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: green.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/AREA.md docs/adr/0026-planning-canvas-rendering.md docs/adr/README.md CLAUDE.md docs/guide docs/roadmap.md docs/problem-map.md
git commit -m "docs(canvas): AREA.md, ADR 0026, two tripwires, guide and roadmap sweep"
```

---

## Whole-slice verification

After Task 15, before 1C-b:

- [ ] Full Mac suite green (`xcodebuild … -scheme Maugham test`)
- [ ] Full phone suite green — confirms nothing leaked into MaughamCore
- [ ] Release build succeeds
- [ ] **Whole-branch review** of the full diff. Per-task reviews cannot see emergent interactions; the T5×T6 precedent on the unified-undo milestone and the CRITICAL that eight per-task reviews missed on the persona shell are why this is not optional.
- [ ] Smoke, by hand: New project → ⌘1 → canvas appears → double-click empty space → type a sentence → click away → **the text does not move** → click back in → the caret lands where you clicked → drag the scrap → zoom in and out → **⌘Z once undoes the whole drag, not one frame of it** → type, then drag, then ⌘Z twice and confirm the typing and the drag come back in that order → quit → reopen → the scrap is where you left it, with its words.
- [ ] Watch specifically for the §7A.2 failure the pin exists to prevent: **any visible jump of the text on focus or on blur.** The test asserts glyph geometry; only your eye can catch a jump the test's tolerance would let through.

**Do not push or tag.** M1 is three slices; 1B is merged and deliberately unpushed, 1A is unwritten. Nothing ships until all three are in.
