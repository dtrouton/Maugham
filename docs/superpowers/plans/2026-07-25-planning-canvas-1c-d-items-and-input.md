# Planning canvas 1C-d — item nodes, images and getting things onto the canvas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make item nodes real. Research notes, palette cards and photographs land on the canvas by drag — internal from the binder, external from Finder or a browser — draw with their own title, glyph and thumbnail, and can be removed from the canvas without ever touching the file on disk. Plus `⌘\` collapses both side columns when the canvas is the centre column.

**Architecture:** An item node stores a reference id and a position and nothing else (spec §3.1). Everything shown is *resolved* from the project manifest at load time, never persisted — one pass over the scene per manifest change, cached in view state, never recomputed in `body` (tripwire 4). Images decode **at** thumbnail size through `CGImageSource`, not at full size then redrawn, and live in a bounded LRU **keyed by file path** (tripwire 22). Internal drags reuse the app's `.draggable(id)` / `.dropDestination(for: String.self)` pattern; external drags route through `DropClassification`, become real research assets first and item nodes second, so the canvas never becomes a content store.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, ImageIO (`CGImageSource`), XCTest.

## Global Constraints

Everything in 1C-a's and 1C-b's Global Constraints still applies. In addition:

- **The canvas NEVER writes to a research note, palette card or image** (spec §3.1, §8). An item node holds a reference and a position. Deleting an item node removes it *from the canvas*, never from the project — so tripwire 14 is satisfied by the canvas never moving or deleting user content at all, not by routing through the typed mover. Task 6 pins that with a grep.
- **External drops become research assets first.** A photo dropped on the canvas is imported through `ProjectStore.importResearchFiles` and *then* referenced by a node. There is no canvas-owned image store, no copy under `.maugham/`, and no node that references a file the research tree does not know about.
- **Never `.dropDestination(for: URL.self)`.** Browser image drags carry rendered bitmaps rather than file URLs and that modifier silently rejects them (CoreTransferable error 0, recorded in `Maugham/Views/DropClassification.swift`'s doc comment). `[.fileURL, .image]` providers plus `DropClassification` is the only external-drop route. Task 5 pins it with a grep.
- **The image cache is keyed by PATH, never by id** (tripwire 22 — an id-keyed reload survives a rename and shows stale content; it has bitten twice, once in the palette rename-revert instance). `CanvasImageCache`'s only accessors take a path `String`; there is no id-keyed overload to reach for.
- **No image I/O in `body`.** `PaletteWallView`'s discipline is the pattern: load once in `.task(id: store.manifest.modified)`, tiles do no I/O in `body` (tripwire 4). Its `downscaled` helper is **not** the pattern — it decodes at full size and then redraws, so peak memory is the original's. Do not copy it, do not call it.
- **`ProjectWindow.body`'s expression budget is ZERO.** It is at 28 chained expressions; eleven extracted `ViewModifier`s exist solely to buy expressions back and the ceiling has been hit twice, once passing Debug and failing Release CI. Task 7 spends exactly one expression (a `columnVisibility:` argument) and buys three back first. Adding a `@State` property is free — a stored property is not a body expression. Task 7 adds two.
- **Tripwire 2 forbids flag-based loop guards.** Task 7's column stash inherits `PersonaModifier.clearsPaletteStash`'s exact ordering hazard and **extends that predicate** rather than deferring a pass.
- **`ContentUnavailableView` needs `.frame(maxWidth: .infinity, maxHeight: .infinity)` within 4 lines** and its enclosing `VStack` needs `alignment: .top` (tripwire 15, recurred 4+ times). This plan adds none; noted so a "helpful" empty state does not arrive unframed.
- **No raw `NotificationCenter.default.post(`** without `// adr-0021-ok: <reason>` on the line where the call *starts*. The pattern is unscoped and `MaughamTests/` is scanned. This plan writes none.
- **Mac-only.** `Packages/MaughamCore` and `MaughamPhone` are untouched (spec §9). No file in this plan may live under either.
- **Deployment target macOS 14.0.** No API newer than 14.0 without a fallback.
- **`Maugham.xcodeproj/` is generated and gitignored.** Never `git add` anything under it. A `project.pbxproj` in a diff is a red flag. `project.yml`'s `sources:` is a whole-directory glob over `Maugham` and `MaughamTests`, so new files need only `./gen.sh`, never a `project.yml` edit.
- **Every Step 2 begins with `./gen.sh &&`.** Until `./gen.sh` runs, a new test file is not in the project at all, and `-only-testing MaughamTests/<Class>` then runs **zero** tests and reports **success** — a green RED step, which is worse than no RED step.
- `-only-testing` takes `MaughamTests/<ClassName>`, **never a folder path**. A folder path runs zero tests and reports success.
- Run `xcodebuild` in the **foreground** (timeout 600000). **Any task touching a view needs a Release build before it is called done** — the Release type-check budget is stricter than Debug and v0.8.0 shipped a Release-only failure this way. That is Tasks 3, 4, 5, 6 and 7.

## What you inherit, and the three places the predecessors disagree

1C-a is the source of truth for its own API; its "Cross-plan contract" section says so, and lists three spellings 1C-b's Interfaces blocks get wrong. **Two more are load-bearing here**, and the pre-state this plan assumes is stated exactly so nothing has to be guessed.

**Verified against 1C-a Task 1, Task 4, Task 5, Task 7, Task 10, Task 13, Task 14 and 1C-b Tasks 1, 2, 4, 6 — these exist and this plan consumes them at these spellings:**

| Symbol | Signature | Source |
|---|---|---|
| `CanvasNodeID` | `init(_ raw: String)`, `var raw: String`, `static func item(_ referenceId: String) -> CanvasNodeID` (returns `CanvasNodeID("item:\(referenceId)")`) | 1C-a T1 |
| `CanvasNodeKind` | `case scrap`, `case item(referenceId: String)` | 1C-a T1 |
| `CanvasNode` | `init(id:kind:origin:width:cachedHeight:z:)`, `var frame: CGRect?` (nil when `cachedHeight == nil`) | 1C-a T1 |
| `CanvasCardMetrics` | `static let inset: CGFloat = 10`, `textWidth(forCardWidth:)`, `cardHeight(forTextHeight:)`, `textOrigin(inCard:)`, `textSize(inCard:)` | 1C-a T1 |
| `CanvasScene` | `nodes`, `unorderedNodes`, `count`, `node(_:)`, `insert(_:)`, `remove(_:)`, `move(_:to:)`, `setCachedHeight(_:for:)`, `topmostNode(at:)`, `nodes(intersecting:)`, `topZ` | 1C-a T1 |
| `CanvasCamera` | `contentPoint(fromView:) -> CGPoint`, `viewPoint(fromContent:)`, `visibleContentRect(viewSize:)` | 1C-a T4 |
| `CanvasRenderer` | `enum`; `seededRotation(for:)`, `drawnAngle(for:straighten:)`, `cardTransform(inCard:angle:)`, `localPoint(_:inCard:angle:)`, `visibleNodes(in:camera:viewSize:)`, `placeholderLabel(forReference:)`, `resizeHandleSize`, `draw(...)`, `private drawCard(_:frame:layout:angle:into:)` | 1C-a T7 |
| `CanvasAccessibility` | `elements(scene:scraps:) -> [CanvasAXElement]`, `summary(scene:)`; `CanvasAXElement(id:role:label:value:contentFrame:)`, `CanvasAXRole.scrap` / `.item` | 1C-a T14 |
| `CanvasInteraction` | `defaultScrapWidth`, `joinTarget(for frame: CGRect, in: CanvasScene) -> CanvasRegion?` | 1C-a T13, 1C-b T6 |
| `CanvasMembership` | `join(_:home:in:)`, `leave(_:from:in:)`, `homeRegion(of:in:) -> CanvasRegionID?`, `appearanceRegions(of:in:) -> [CanvasRegionID]` | 1C-b T2 |
| `CanvasModel` | `@Observable final class`; `private(set) var scene`, `private(set) var scraps`, `var selectedRegionID`, `let undoManager`, `load(projectRoot:)`, `flush()`, `withScene(persist:_:)`, `setScrapText(_:for:)`, `beginGesture(_:)`, `endGesture()`, `mutate(_ name:_ body:)`, `deleteSelectedRegion()` | 1C-b T4 |
| `CanvasEventView` / `CanvasEventNSView` | `onDeleteKey: (() -> Void)?` | 1C-b T6 |
| `CanvasView` | `init(model:projectRoot:paletteSwatchHexes:)` with `paletteSwatchHexes: [String]`; `@State camera`, `layouts`, `editingNodeID`, `caretIndex`, `interaction`, `revision`, `sceneRevision`, `straighten`; `mountedEditorNodeID` computed | 1C-b T4 |
| `ProjectStore` | `let url: URL` (the project root), `var manifest: ProjectManifest`, `manifest.research: [ResearchItem]`, `importResearchFiles(_:toParentId:) async throws -> [ResearchItem]`, `paletteSwatchHexes() -> [String]` | existing + 1C-a T11 |
| `TreeWalk.find(id:in:)` | `public static func find<N: TreeNode>(id: String, in nodes: [N]) -> N?`; `ResearchItem: TreeNode` | `Packages/MaughamCore/Sources/MaughamCore/TreeNode.swift:16` |
| `DropClassification` | `action(hasFileURL:canLoadImage:) -> DropAction`, `fileURLs(from: [NSItemProvider]) async -> [URL]` | `Maugham/Views/DropClassification.swift` |
| `PersonaModifier` | `applyPersonaChange(to:from:currentSegment:currentBinderSegment:projectType:memory:) -> Change`, `clearsPaletteStash(from:to:)` | `Maugham/Views/ProjectWindow.swift:1445`, `:1483` |

**Disagreement 1 — `CanvasItemPresentation` does not exist when this plan starts.** 1C-b's Task 5 Interfaces block cites "`CanvasItemPresentation` (1C-a Task 12 — the per-item title/glyph the view resolves from the project store)". 1C-a's Global Constraints say the opposite, in terms: *"Do not build: a drop target, `CanvasItemPresentation` or any title/thumbnail resolution…"*, and its Task 12 is "Plan leads with the canvas", which touches only `Persona.swift`. 1C-a is the declared source of truth for reconciliation, so **1C-b ships without `presentations:`**. This plan creates the type (Task 1) and threads it (Task 3).

**Disagreement 2 — the merged `CanvasRenderer.draw` signature.** 1C-b's Task 5 writes `draw(scene:camera:viewSize:layouts:presentations:scraps:selectedRegionID:editingNodeID:into:)` and does the card rotation inline; 1C-a's Task 7 ships `mountedEditorNodeID:` and `straighten:` and does the rotation through `drawnAngle`/`cardTransform`. 1C-b's own Step 4 instruction resolves it — *"if the merged 1C-a signature spells `presentations:` differently, keep the merged spelling"* — so **the pre-state this plan assumes is:**

```swift
static func draw(scene: CanvasScene,
                 camera: CanvasCamera,
                 viewSize: CGSize,
                 layouts: [CanvasNodeID: ScrapLayout],
                 scraps: [CanvasNodeID: String],
                 selectedRegionID: CanvasRegionID?,
                 mountedEditorNodeID: CanvasNodeID?,
                 straighten: CanvasFocusStraighten,
                 into cx: inout GraphicsContext)
```

with `private static func drawCard(_ node: CanvasNode, frame: CGRect, layout: ScrapLayout?, angle: Angle, into cx: inout GraphicsContext)` and `private static func chipTitle(for:scraps:)`.

**Task 3 Step 0 verifies this by grep and STOPS if it does not hold** — it does not guess. If `presentations:` is already present, 1C-b was executed against its own text rather than the reconciliation, and that must be reported before any code is written.

**Disagreement 3 — `CanvasUndo`'s task number.** 1C-b calls it "1C-a Task 13"; 1C-a builds it in Task 15. Immaterial here: this plan uses `CanvasModel.mutate(_:_:)` for every mutation and never touches `CanvasUndo` directly. 1C-b's Task 6 states the rule this plan obeys — *"One gesture, one mechanism; nesting the two produces a group containing a snapshot and gives you two ⌘Z presses for one drag."*

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Views/ResearchGlyph.swift` | *Create* — the SF Symbol for a research item, in one place |
| `Maugham/Views/ResearchRow.swift` | *Modify* — `kindIconName` delegates to `ResearchGlyph` |
| `Maugham/Canvas/CanvasItemPresentation.swift` | *Create* — `CanvasItemPresentation`, `CanvasItemResolver` |
| `Maugham/Canvas/CanvasImageCache.swift` | *Create* — `CanvasThumbnailDecoder`, `CanvasImageCache` |
| `Maugham/Canvas/CanvasItemNode.swift` | *Create* (Task 3) — item-card geometry: width, heights, the fitted thumbnail rect |
| `Maugham/Canvas/CanvasDrop.swift` | *Create* — `CanvasDropRouter`, `CanvasDropPlacement` |
| `Maugham/Canvas/CanvasFocusColumns.swift` | *Create* — `CanvasColumnStash`, `CanvasFocusColumns` (spec §8A.3) |
| `Maugham/Canvas/CanvasRenderer.swift` | *Modify* — item cards draw for real; the node selection ring |
| `Maugham/Canvas/CanvasAccessibility.swift` | *Modify* — AX reads the resolved title, not the placeholder |
| `Maugham/Canvas/CanvasModel.swift` | *Modify* — the image cache, node selection, canvas-only node removal |
| `Maugham/Canvas/CanvasView.swift` | *Modify* — resolve presentations + thumbnails; two drop destinations; selection |
| `Maugham/Canvas/ScrapEditorHost.swift` | *Modify* — the mounted text view stops claiming drops |
| `Maugham/Views/ProjectWindow.swift` | *Modify* — `store:` into `CanvasView`; `columnVisibility`; `ProjectOverlaysModifier`; `clearsColumnStash` |
| `Maugham/Canvas/AREA.md` | *Modify* — items, images, drops, the cache bound |
| `docs/adr/0026-planning-canvas-rendering.md` | *Modify* — the item-node decisions |
| `docs/guide/research.md`, the canvas guide topic, `docs/roadmap.md`, `docs/problem-map.md`, `CLAUDE.md` | *Modify* — docs sweep |

---

### Task 1: Resolving a reference to what the card shows

**Files:**
- Create: `Maugham/Views/ResearchGlyph.swift`
- Modify: `Maugham/Views/ResearchRow.swift`
- Create: `Maugham/Canvas/CanvasItemPresentation.swift`
- Test: `MaughamTests/Canvas/CanvasItemPresentationTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene.unorderedNodes`, `CanvasNodeID`, `CanvasNodeKind` (1C-a Task 1); `CanvasRenderer.placeholderLabel(forReference:) -> String` (1C-a Task 7); `ResearchItem` (`id`, `title`, `type: ItemType`, `kind: AssetKind?`, `path: String?`) and `TreeWalk.find(id:in:)` from `MaughamCore`.
- **Produces:**
  - `enum ResearchGlyph` — `static let groupSymbolName: String`, `static func symbolName(forKind: ResearchItem.AssetKind?) -> String`, `static func symbolName(for item: ResearchItem) -> String`.
  - `struct CanvasItemPresentation: Equatable, Sendable` — `var title: String`, `var symbolName: String`, `var relativePath: String?`, `var isMissing: Bool`, `var showsThumbnail: Bool`.
  - `enum CanvasItemResolver` — `static let missingSymbolName: String`, `static func presentation(forReference: String, in research: [ResearchItem]) -> CanvasItemPresentation`, `static func presentations(for scene: CanvasScene, in research: [ResearchItem]) -> [CanvasNodeID: CanvasItemPresentation]`.

**Everything an item card shows is resolved, never stored.** Spec §3.1: items appear on the canvas *as themselves*, the canvas holds only their position, and the file on disk remains the truth. So the sidecar keeps a reference id and nothing else — no cached title, no cached kind — and a rename in the research tree is reflected on the canvas the next time the manifest changes, with no migration and nothing to go stale. This is also why the schema does not change: `CanvasSceneDTO` already round-trips `kind: "item"` + `referenceId` (1C-a Task 5) and this plan adds no field to it.

**A dangling reference resolves to a visible "missing" card, never to a crash and never to a blank.** A writer can delete a research note that a canvas node points at. The node stays — deleting the note is not a statement about the canvas — and it reads as unresolved, carrying the reference id so the writer can tell *which* thing went. That is the fix-shape this codebase already prefers (fail loudly rather than silently no-op; see `project_publishing_namespace_footgun`). `CanvasRenderer.placeholderLabel(forReference:)` is reused verbatim as that label — it already exists, its 1C-a test already asserts it contains the reference id, and one spelling is better than two.

**Why `ResearchGlyph` exists.** `ResearchRow.kindIconName` is the app's existing kind→symbol mapping and it is `private`. An item card must show the same glyph the binder shows for the same note, or the writer cannot tell that the card *is* the note. Copying the switch is how the two drift; extracting it is fifteen lines. `ResearchRow`'s `icon` view is untouched — only the string it reads moves.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasItemPresentationTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

final class CanvasItemPresentationTests: XCTestCase {

    private func asset(_ id: String,
                       title: String,
                       kind: ResearchItem.AssetKind?,
                       path: String?) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .asset, kind: kind, path: path)
    }

    private func tree() -> [ResearchItem] {
        [
            ResearchItem(id: "g1", title: "Locations", type: .group, path: "research/locations",
                         children: [
                            asset("r-photo", title: "Falls, evening",
                                  kind: .image, path: "research/locations/falls.jpg"),
                            asset("r-note", title: "October's doctor",
                                  kind: .document, path: "research/locations/doctor.md"),
                         ]),
            asset("r-nopath", title: "A link", kind: .link, path: nil),
            asset("r-imagenopath", title: "Pasted photo", kind: .image, path: nil),
        ]
    }

    // MARK: - The glyph is the binder's glyph

    func test_everyAssetKindHasTheSameSymbolTheBinderShows() {
        XCTAssertEqual(ResearchGlyph.symbolName(forKind: .image), "photo")
        XCTAssertEqual(ResearchGlyph.symbolName(forKind: .pdf), "doc.richtext")
        XCTAssertEqual(ResearchGlyph.symbolName(forKind: .document), "doc.text")
        XCTAssertEqual(ResearchGlyph.symbolName(forKind: .audio), "speaker.wave.2")
        XCTAssertEqual(ResearchGlyph.symbolName(forKind: .link), "link")
        XCTAssertEqual(ResearchGlyph.symbolName(forKind: nil), "questionmark.circle")
    }

    func test_aGroupIsAFolderRegardlessOfKind() {
        let group = ResearchItem(id: "g", title: "Locations", type: .group, kind: .image)
        XCTAssertEqual(ResearchGlyph.symbolName(for: group), ResearchGlyph.groupSymbolName)
        XCTAssertEqual(ResearchGlyph.groupSymbolName, "folder")
    }

    // MARK: - Resolving one reference

    func test_anImageAssetResolvesToItsTitleGlyphAndPath() {
        let p = CanvasItemResolver.presentation(forReference: "r-photo", in: tree())
        XCTAssertEqual(p.title, "Falls, evening")
        XCTAssertEqual(p.symbolName, "photo")
        XCTAssertEqual(p.relativePath, "research/locations/falls.jpg")
        XCTAssertFalse(p.isMissing)
        XCTAssertTrue(p.showsThumbnail)
    }

    func test_resolutionReachesNestedItems() {
        XCTAssertEqual(
            CanvasItemResolver.presentation(forReference: "r-note", in: tree()).title,
            "October's doctor",
            "research is a tree; a flat scan of the roots would miss every "
            + "note a writer has filed in a group")
    }

    /// §3.1 says the file on disk is the truth. A non-image has a file too, but
    /// there is nothing to make a picture of, so the card is a title row.
    func test_aNonImageAssetShowsNoThumbnail() {
        let p = CanvasItemResolver.presentation(forReference: "r-note", in: tree())
        XCTAssertFalse(p.showsThumbnail)
        XCTAssertEqual(p.relativePath, "research/locations/doctor.md")
    }

    func test_anImageWithNoPathShowsNoThumbnail() {
        let p = CanvasItemResolver.presentation(forReference: "r-imagenopath", in: tree())
        XCTAssertEqual(p.symbolName, "photo")
        XCTAssertFalse(p.showsThumbnail,
                       "showsThumbnail is the ONE gate the decoder reads; an "
                       + "image with no path would send it a nil URL")
        XCTAssertNil(p.relativePath)
    }

    func test_aLinkResolvesWithoutAPathAndIsNotMissing() {
        let p = CanvasItemResolver.presentation(forReference: "r-nopath", in: tree())
        XCTAssertFalse(p.isMissing)
        XCTAssertEqual(p.symbolName, "link")
        XCTAssertNil(p.relativePath)
    }

    // MARK: - The dangling reference

    /// A writer may delete the note a canvas node points at. The node stays —
    /// deleting the note said nothing about the canvas — and it must read as
    /// unresolved AND name what went, not blank out.
    func test_aDeletedReferenceResolvesToAVisibleMissingCard() {
        let p = CanvasItemResolver.presentation(forReference: "r-gone", in: tree())
        XCTAssertTrue(p.isMissing)
        XCTAssertTrue(p.title.contains("r-gone"),
                      "the writer has to be able to tell WHICH reference went")
        XCTAssertEqual(p.symbolName, CanvasItemResolver.missingSymbolName)
        XCTAssertFalse(p.showsThumbnail)
        XCTAssertNil(p.relativePath)
    }

    func test_theMissingLabelIsTheRenderersExistingPlaceholderSpelling() {
        XCTAssertEqual(
            CanvasItemResolver.presentation(forReference: "r-gone", in: tree()).title,
            CanvasRenderer.placeholderLabel(forReference: "r-gone"),
            "one spelling, not two — 1C-a already ships and tests this label")
    }

    // MARK: - Resolving a whole scene

    func test_presentationsCoverEveryItemNodeAndNoScrap() {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: .item("r-photo"), kind: .item(referenceId: "r-photo"),
                                origin: .zero, width: 200, cachedHeight: 172))
        scene.insert(CanvasNode(id: .item("r-note"), kind: .item(referenceId: "r-note"),
                                origin: CGPoint(x: 300, y: 0), width: 200, cachedHeight: 42))
        scene.insert(CanvasNode(id: CanvasNodeID("s1"), kind: .scrap,
                                origin: CGPoint(x: 600, y: 0), width: 240, cachedHeight: 80))

        let map = CanvasItemResolver.presentations(for: scene, in: tree())
        XCTAssertEqual(Set(map.keys), [CanvasNodeID.item("r-photo"), CanvasNodeID.item("r-note")])
        XCTAssertEqual(map[.item("r-photo")]?.title, "Falls, evening")
    }

    func test_anEmptySceneResolvesToAnEmptyMap() {
        XCTAssertTrue(CanvasItemResolver.presentations(for: CanvasScene(), in: tree()).isEmpty)
    }

    /// A palette card is an ordinary `.document` research asset under the
    /// palette group (`ProjectStore+Palette.swift`), so it resolves through the
    /// SAME lookup as any other note. There is one reference namespace on the
    /// canvas — `ResearchItem.id` — and this test is what stops a second one
    /// being invented.
    func test_aPaletteCardResolvesThroughTheOneResearchNamespace() {
        let paletteTree = [
            ResearchItem(id: "pg", title: "Palette", type: .group, path: "research/palette",
                         children: [asset("pc-1", title: "October",
                                          kind: .document, path: "research/palette/october.md")],
                         role: .paletteGroup)
        ]
        let p = CanvasItemResolver.presentation(forReference: "pc-1", in: paletteTree)
        XCTAssertEqual(p.title, "October")
        XCTAssertFalse(p.isMissing)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasItemPresentationTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'ResearchGlyph' in scope`.

- [ ] **Step 3: Write the implementation**

`Maugham/Views/ResearchGlyph.swift`:

```swift
import MaughamCore

/// The SF Symbol for a research item, in ONE place.
///
/// Extracted from `ResearchRow.kindIconName` when the canvas gained item nodes:
/// an item card must show the same glyph the binder shows for the same note, or
/// the writer cannot tell that the card IS the note. A copied switch is how the
/// two drift.
enum ResearchGlyph {
    static let groupSymbolName = "folder"

    static func symbolName(for item: ResearchItem) -> String {
        item.type == .group ? groupSymbolName : symbolName(forKind: item.kind)
    }

    static func symbolName(forKind kind: ResearchItem.AssetKind?) -> String {
        switch kind {
        case .image:    return "photo"
        case .pdf:      return "doc.richtext"
        case .document: return "doc.text"
        case .audio:    return "speaker.wave.2"
        case .link:     return "link"
        case .none:     return "questionmark.circle"
        }
    }
}
```

`Maugham/Views/ResearchRow.swift` — replace the body of `kindIconName` (its six-case switch) with the delegation, leaving the `icon` view and everything else untouched:

```swift
    private var kindIconName: String { ResearchGlyph.symbolName(forKind: item.kind) }
```

`Maugham/Canvas/CanvasItemPresentation.swift`:

```swift
import Foundation
import MaughamCore

/// What an item node draws. RESOLVED from the manifest, never persisted.
///
/// Spec §3.1: items appear on the canvas as themselves; the canvas holds only
/// their position and the file on disk remains the truth. So the sidecar keeps
/// a reference id and nothing else — no cached title, no cached kind — and a
/// rename in the research tree shows up on the canvas with no migration and
/// nothing to go stale.
struct CanvasItemPresentation: Equatable, Sendable {
    var title: String
    var symbolName: String
    /// Project-relative path to the referenced file, when it has one. The
    /// thumbnail cache is keyed on the ABSOLUTE resolution of this and never on
    /// a node id (tripwire 22).
    var relativePath: String?
    /// The reference no longer names anything in the research tree.
    var isMissing: Bool
    /// The one gate the thumbnail decoder reads: an image asset that actually
    /// has a file.
    var showsThumbnail: Bool
}

enum CanvasItemResolver {
    /// A dangling reference reads as unresolved rather than blank. Deleting the
    /// note said nothing about the canvas, so the node stays and says so.
    static let missingSymbolName = "questionmark.square.dashed"

    static func presentation(forReference referenceId: String,
                             in research: [ResearchItem]) -> CanvasItemPresentation {
        guard let item = TreeWalk.find(id: referenceId, in: research) else {
            return CanvasItemPresentation(
                title: CanvasRenderer.placeholderLabel(forReference: referenceId),
                symbolName: missingSymbolName,
                relativePath: nil,
                isMissing: true,
                showsThumbnail: false)
        }
        let path = item.path
        return CanvasItemPresentation(
            title: item.title,
            symbolName: ResearchGlyph.symbolName(for: item),
            relativePath: path,
            isMissing: false,
            showsThumbnail: item.type == .asset && item.kind == .image && path != nil)
    }

    /// One pass over the scene, run when the manifest changes — never in `body`
    /// and never per frame (tripwire 4). `unorderedNodes`, not `nodes`: `nodes`
    /// sorts into draw order on every access and this produces a dictionary.
    static func presentations(for scene: CanvasScene,
                              in research: [ResearchItem])
        -> [CanvasNodeID: CanvasItemPresentation] {
        var out: [CanvasNodeID: CanvasItemPresentation] = [:]
        for node in scene.unorderedNodes {
            guard case .item(let referenceId) = node.kind else { continue }
            out[node.id] = presentation(forReference: referenceId, in: research)
        }
        return out
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasItemPresentationTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 12 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRendererTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — `placeholderLabel` gains a second consumer and its 1C-a test must still hold.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/ResearchGlyph.swift Maugham/Views/ResearchRow.swift \
        Maugham/Canvas/CanvasItemPresentation.swift \
        MaughamTests/Canvas/CanvasItemPresentationTests.swift
git commit -m "feat(canvas): resolve an item reference to a title, glyph and path

Everything an item card shows is derived from the manifest at load time,
never stored — so a rename in the research tree needs no migration and
nothing on the canvas goes stale (spec 3.1). A dangling reference
resolves to a visible missing card carrying the reference id rather than
to a blank or a crash, reusing the renderer's existing placeholder label
so there is one spelling. ResearchGlyph extracts the binder's kind-to-
symbol map so a card and the row it came from cannot drift apart."
```

---

### Task 2: Thumbnails that decode at target size, in a bounded path-keyed cache

**Files:**
- Create: `Maugham/Canvas/CanvasImageCache.swift`
- Test: `MaughamTests/Canvas/CanvasImageCacheTests.swift`

**Interfaces:**
- **Consumes:** nothing from this plan or its predecessors. `ImageIO` + `AppKit` only.
- **Produces:**
  - `enum CanvasThumbnailDecoder` — `static func thumbnail(atFileURL url: URL, maxPixelSize: Int) -> CGImage?`.
  - `final class CanvasImageCache` — `static let defaultByteBudget: Int`, `static func cost(of image: CGImage) -> Int`, `init(byteBudget: Int = CanvasImageCache.defaultByteBudget)`, `let byteBudget: Int`, `private(set) var totalCost: Int`, `var count: Int`, `func image(forPath path: String) -> CGImage?`, `func insert(_ image: CGImage, forPath path: String)`, `func removeAll()`.

**This is the first surface in Maugham with an unbounded image count, and the app has neither a cache nor real downsampling today.** `PaletteWallView.downscaled` decodes the whole image with `NSImage(contentsOf:)` and *then* redraws it small, so peak memory is the original's — a 48-megapixel photograph costs ~190 MB before the thumbnail exists. That is survivable for a palette wall of a dozen cards and is not survivable here. `CGImageSourceCreateThumbnailAtIndex` decodes **at** the requested size: the full raster is never materialised.

Three option keys are load-bearing and each is there for a reason:

- `kCGImageSourceCreateThumbnailFromImageAlways: true` — without it, a file carrying an embedded EXIF thumbnail hands back that thumbnail, which is typically 160 px and looks like mush on a card.
- `kCGImageSourceCreateThumbnailWithTransform: true` — without it, a photograph shot in portrait on a phone draws on its side, because the EXIF orientation is never applied.
- `kCGImageSourceShouldCacheImmediately: true` — decode happens here, on the loading pass, rather than lazily on the first draw, which would put a file read inside the `Canvas` draw closure.

`kCGImageSourceShouldCache: false` on the *source* keeps ImageIO from holding a second decoded copy alongside the one we asked for.

**The cache is keyed on the file PATH, never on a node id — tripwire 22, which has bitten twice, once in the palette rename-revert instance.** An item node's id is `item:<referenceId>` and survives a rename of the thing it points at; the file behind it does not. Keying on the id means a renamed research image keeps serving the picture that used to be at the old path — the exact "id-keyed reload survives a rename and shows stale content" failure. The type is the enforcement: `image(forPath:)` and `insert(_:forPath:)` are the only accessors and both take a path `String`. There is no id-keyed overload to reach for, and the resolver in Task 1 hands out `relativePath` rather than an id for precisely this reason.

**The bound, with its arithmetic.** `CanvasItemNode.thumbnailMaxPixelSize` (Task 3) is **512**, so a worst-case square thumbnail is 512 × 512 × 4 bytes = **1,048,576 B = 1 MiB** exactly. The budget is **48 MiB = 50,331,648 bytes**, i.e. 48 worst-case thumbnails resident — comfortably more than fit on screen at any zoom the canvas supports, and a hard ceiling two orders of magnitude below what a full-size decode of the same 48 photographs would take. Eviction is least-recently-used, driven by reads as well as writes, so panning back and forth across a canvas does not thrash the images the writer is actually looking at.

**One entry is never evicted.** An image whose own cost exceeds the entire budget would otherwise be inserted and immediately dropped, and the card would render blank forever while the decoder was re-run on every pass. Keeping it means the budget is a soft ceiling in exactly one degenerate case, which is the right trade.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasImageCacheTests.swift`:

```swift
import XCTest
import AppKit
@testable import Maugham

final class CanvasImageCacheTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A real PNG on disk — the decoder reads a file URL, so a synthetic
    /// in-memory image would not exercise it.
    @discardableResult
    private func writePNG(named name: String, width: Int, height: Int) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = rep.representation(using: .png, properties: [:])!
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A CGImage of an exact pixel size, so `cost` arithmetic is checkable by
    /// hand rather than by re-deriving the formula in the test.
    private func image(width: Int, height: Int) -> CGImage {
        let cx = CGContext(data: nil, width: width, height: height,
                           bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return cx.makeImage()!
    }

    // MARK: - Decoding AT size, not decoding then shrinking

    func test_theThumbnailIsScaledSoItsLONGEREdgeMatchesTheRequestedMaximum() throws {
        let url = try writePNG(named: "wide.png", width: 800, height: 600)
        let thumb = try XCTUnwrap(
            CanvasThumbnailDecoder.thumbnail(atFileURL: url, maxPixelSize: 200))
        // 800x600 with a 200px cap: scale 200/800 = 0.25, so 200 x 150.
        XCTAssertEqual(thumb.width, 200)
        XCTAssertEqual(thumb.height, 150)
    }

    func test_aTallImageIsCappedOnItsHeight() throws {
        let url = try writePNG(named: "tall.png", width: 300, height: 900)
        let thumb = try XCTUnwrap(
            CanvasThumbnailDecoder.thumbnail(atFileURL: url, maxPixelSize: 300))
        // 300x900 with a 300px cap: scale 300/900 = 1/3, so 100 x 300.
        XCTAssertEqual(thumb.width, 100)
        XCTAssertEqual(thumb.height, 300)
    }

    func test_aSmallImageIsNeverUpscaled() throws {
        let url = try writePNG(named: "small.png", width: 800, height: 600)
        let thumb = try XCTUnwrap(
            CanvasThumbnailDecoder.thumbnail(atFileURL: url, maxPixelSize: 4000))
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 800,
                                 "asking for more pixels than the file has must "
                                 + "not manufacture them")
    }

    func test_aNonImageFileDecodesToNilRatherThanThrowing() throws {
        let url = dir.appendingPathComponent("notes.md")
        try "# Not a picture".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(CanvasThumbnailDecoder.thumbnail(atFileURL: url, maxPixelSize: 200))
    }

    func test_aMissingFileDecodesToNil() {
        XCTAssertNil(CanvasThumbnailDecoder.thumbnail(
            atFileURL: dir.appendingPathComponent("nope.png"), maxPixelSize: 200))
    }

    func test_aNonPositiveMaxPixelSizeDecodesToNil() throws {
        let url = try writePNG(named: "any.png", width: 40, height: 40)
        XCTAssertNil(CanvasThumbnailDecoder.thumbnail(atFileURL: url, maxPixelSize: 0))
    }

    // MARK: - The bound

    func test_theDefaultBudgetIs48MiB() {
        XCTAssertEqual(CanvasImageCache.defaultByteBudget, 50_331_648,
                       "48 MiB = 48 worst-case 512x512 RGBA thumbnails, which is "
                       + "the bound AREA.md records")
    }

    func test_costIsFourBytesPerPixel() {
        XCTAssertEqual(CanvasImageCache.cost(of: image(width: 200, height: 150)), 120_000)
        XCTAssertEqual(CanvasImageCache.cost(of: image(width: 512, height: 512)), 1_048_576)
    }

    func test_evictionDropsTheLeastRecentlyUsedEntry() {
        let cache = CanvasImageCache(byteBudget: 1_000)
        // 10 x 10 x 4 = 400 bytes each; three of them is 1,200 > 1,000.
        cache.insert(image(width: 10, height: 10), forPath: "/p/a.png")
        cache.insert(image(width: 10, height: 10), forPath: "/p/b.png")
        XCTAssertEqual(cache.totalCost, 800)

        cache.insert(image(width: 10, height: 10), forPath: "/p/c.png")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.totalCost, 800)
        XCTAssertNil(cache.image(forPath: "/p/a.png"), "a was least recently used")
        XCTAssertNotNil(cache.image(forPath: "/p/b.png"))
        XCTAssertNotNil(cache.image(forPath: "/p/c.png"))
    }

    /// Reads have to count as use, or panning back to a card the writer is
    /// actually looking at evicts exactly the images they can see.
    func test_aReadMakesAnEntryRecentlyUsed() {
        let cache = CanvasImageCache(byteBudget: 1_000)
        cache.insert(image(width: 10, height: 10), forPath: "/p/a.png")
        cache.insert(image(width: 10, height: 10), forPath: "/p/b.png")
        _ = cache.image(forPath: "/p/a.png")          // a is now the most recent
        cache.insert(image(width: 10, height: 10), forPath: "/p/c.png")
        XCTAssertNotNil(cache.image(forPath: "/p/a.png"))
        XCTAssertNil(cache.image(forPath: "/p/b.png"), "b was least recently used")
    }

    func test_reinsertingAPathReplacesRatherThanDoubleCounting() {
        let cache = CanvasImageCache(byteBudget: 1_000)
        cache.insert(image(width: 10, height: 10), forPath: "/p/a.png")
        cache.insert(image(width: 5, height: 5), forPath: "/p/a.png")   // 5*5*4 = 100
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalCost, 100)
    }

    /// A soft ceiling in exactly one degenerate case: an image bigger than the
    /// whole budget is kept, because dropping it means a blank card and a
    /// re-decode on every pass, forever.
    func test_anEntryLargerThanTheWholeBudgetIsStillServed() {
        let cache = CanvasImageCache(byteBudget: 100)
        cache.insert(image(width: 10, height: 10), forPath: "/p/huge.png")
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.image(forPath: "/p/huge.png"))
    }

    func test_removeAllEmptiesTheCacheAndItsCost() {
        let cache = CanvasImageCache(byteBudget: 1_000)
        cache.insert(image(width: 10, height: 10), forPath: "/p/a.png")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }

    // MARK: - Tripwire 22: keyed by path, never by id

    /// Two item nodes referencing the same file share ONE decoded image. Keyed
    /// by node id they would be two.
    func test_twoNodesPointingAtOnePathShareOneEntry() {
        let cache = CanvasImageCache()
        cache.insert(image(width: 10, height: 10), forPath: "/p/falls.jpg")
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.image(forPath: "/p/falls.jpg"))
    }

    /// The rename case, stated directly. The node id is stable across a rename
    /// of the thing it points at; the path is not. An id-keyed cache would serve
    /// the OLD picture under the new name — tripwire 22, which has bitten twice.
    func test_aRenamedFileMissesRatherThanServingTheOldPicture() {
        let cache = CanvasImageCache()
        cache.insert(image(width: 10, height: 10), forPath: "/p/research/falls.jpg")
        XCTAssertNil(cache.image(forPath: "/p/research/falls-evening.jpg"),
                     "the reference id did not change and MUST NOT be the key")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasImageCacheTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasThumbnailDecoder' in scope`.

- [ ] **Step 3: Write the implementation**

`Maugham/Canvas/CanvasImageCache.swift`:

```swift
import AppKit
import ImageIO

/// Decode an image AT thumbnail size.
///
/// The canvas is the first surface in Maugham with an unbounded image count.
/// `PaletteWallView.downscaled` — the only prior art — decodes the whole image
/// with `NSImage(contentsOf:)` and then redraws it small, so peak memory is the
/// ORIGINAL's; a 48-megapixel photograph costs ~190 MB before the thumbnail
/// exists. `CGImageSourceCreateThumbnailAtIndex` never materialises the full
/// raster. Do not reach for the palette wall's helper here.
enum CanvasThumbnailDecoder {

    static func thumbnail(atFileURL url: URL, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0 else { return nil }
        // `ShouldCache: false` on the SOURCE: we want exactly one decoded copy,
        // the one asked for below, not ImageIO holding a second.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            // Without this an embedded EXIF thumbnail (typically 160px) is
            // handed back and the card looks like mush.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Without this a photograph shot in portrait draws on its side.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode HERE, on the loading pass — not lazily on first draw,
            // which would put a file read inside the Canvas draw closure.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A bounded least-recently-used cache of decoded thumbnails, **keyed by file
/// path**.
///
/// Tripwire 22: an id-keyed reload survives a rename and shows stale content,
/// and it has bitten twice — once in the palette rename-revert instance. An item
/// node's id is `item:<referenceId>` and is stable across a rename of the thing
/// it points at; the file behind it is not. So the key is the path, the only
/// accessors take a path, and there is deliberately no id-keyed overload to
/// reach for.
///
/// Not `NSCache`: its eviction is opaque and untestable, and the whole point of
/// this type is that the bound is a stated number with a test against it.
@MainActor
final class CanvasImageCache {

    /// 48 MiB. `CanvasItemNode.thumbnailMaxPixelSize` is 512, so a worst-case
    /// square thumbnail is 512 x 512 x 4 = 1 MiB exactly and this budget holds
    /// 48 of them — more than fit on screen at any zoom the canvas supports, and
    /// two orders of magnitude below a full-size decode of the same 48 files.
    static let defaultByteBudget = 48 * 1024 * 1024

    /// Decoded RGBA, four bytes a pixel. The image's own `bytesPerRow` is not
    /// used: it is padded for alignment and would make the budget depend on the
    /// hardware.
    static func cost(of image: CGImage) -> Int { image.width * image.height * 4 }

    let byteBudget: Int
    private(set) var totalCost = 0

    private struct Entry { let image: CGImage; let cost: Int }
    private var entries: [String: Entry] = [:]
    /// Least-recently-used FIRST. Linear, which is correct at this size: the
    /// budget holds tens of entries, not thousands, and a linked list would be
    /// more machinery than the bound justifies.
    private var recency: [String] = []

    init(byteBudget: Int = CanvasImageCache.defaultByteBudget) {
        self.byteBudget = byteBudget
    }

    var count: Int { entries.count }

    /// A read counts as use — otherwise panning back to a card the writer is
    /// looking at evicts exactly the images they can see.
    func image(forPath path: String) -> CGImage? {
        guard let entry = entries[path] else { return nil }
        touch(path)
        return entry.image
    }

    func insert(_ image: CGImage, forPath path: String) {
        drop(path)
        entries[path] = Entry(image: image, cost: Self.cost(of: image))
        recency.append(path)
        totalCost += Self.cost(of: image)
        evictIfNeeded()
    }

    func removeAll() {
        entries.removeAll()
        recency.removeAll()
        totalCost = 0
    }

    private func touch(_ path: String) {
        guard let i = recency.firstIndex(of: path) else { return }
        recency.remove(at: i)
        recency.append(path)
    }

    private func drop(_ path: String) {
        guard let entry = entries.removeValue(forKey: path) else { return }
        totalCost -= entry.cost
        if let i = recency.firstIndex(of: path) { recency.remove(at: i) }
    }

    /// `recency.count > 1` keeps the last entry whatever it costs: an image
    /// bigger than the whole budget would otherwise be inserted and immediately
    /// dropped, leaving a blank card and a re-decode on every pass, forever.
    private func evictIfNeeded() {
        while totalCost > byteBudget, recency.count > 1 {
            drop(recency[0])
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasImageCacheTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 15 tests.

**If `test_theThumbnailIsScaledSoItsLONGEREdgeMatchesTheRequestedMaximum` fails with a 160-ish size**, `kCGImageSourceCreateThumbnailFromImageAlways` was dropped and ImageIO handed back an embedded EXIF thumbnail. Restore the key; do not relax the assertion.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasImageCache.swift MaughamTests/Canvas/CanvasImageCacheTests.swift
git commit -m "feat(canvas): CGImageSource thumbnails and a bounded path-keyed cache

The canvas is the first surface with an unbounded image count and the app
had neither a cache nor real downsampling — PaletteWallView.downscaled
decodes at full size and then redraws, so peak memory is the original's.
CGImageSourceCreateThumbnailAtIndex decodes AT the target size and never
materialises the full raster.

Keyed on the file PATH, never on a node id: an item node's id survives a
rename of the thing it points at and the file behind it does not, which
is tripwire 22 exactly (it has bitten twice). The only accessors take a
path, so there is no id-keyed overload to reach for. Bound is 48 MiB =
48 worst-case 512x512 RGBA thumbnails, LRU by read as well as write, with
one degenerate exception: an entry larger than the whole budget is kept
rather than re-decoded on every pass forever."
```

---

### Task 3: Item cards draw for real — geometry, thumbnails, and the selection ring

**Files:**
- Create: `Maugham/Canvas/CanvasItemNode.swift`
- Modify: `Maugham/Canvas/CanvasRenderer.swift`
- Modify: `Maugham/Canvas/CanvasAccessibility.swift`
- Modify: `Maugham/Canvas/CanvasModel.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasItemNodeTests.swift`

**Interfaces:**
- **Consumes:** `CanvasCardMetrics.inset` / `textWidth(forCardWidth:)` / `cardHeight(forTextHeight:)` / `textOrigin(inCard:)` (1C-a T1); `CanvasNode`, `CanvasNodeID`, `CanvasNodeKind`, `CanvasScene` (1C-a T1); `CanvasRenderer.drawnAngle(for:straighten:)` / `cardTransform(inCard:angle:)` / `visibleNodes(in:camera:viewSize:)` / `placeholderLabel(forReference:)` (1C-a T7); `CanvasAccessibility.elements(scene:scraps:)` (1C-a T14); `CanvasItemPresentation`, `CanvasItemResolver.presentations(for:in:)` (Task 1); `CanvasImageCache`, `CanvasThumbnailDecoder.thumbnail(atFileURL:maxPixelSize:)` (Task 2); `CanvasModel.scene` / `scraps` (1C-b T4); `ProjectStore.url` / `manifest.research` / `manifest.modified`.
- **Produces:**
  - `enum CanvasItemNode` — `static let defaultWidth: CGFloat`, `static let titleRowHeight: CGFloat`, `static let thumbnailBoxHeight: CGFloat`, `static let thumbnailMaxPixelSize: Int`, `static func height(showsThumbnail: Bool) -> CGFloat`, `static func make(referenceId: String, at origin: CGPoint, z: Int, showsThumbnail: Bool) -> CanvasNode`, `static func thumbnailBox(inCard frame: CGRect) -> CGRect`, `static func fittedRect(imageSize: CGSize, in box: CGRect) -> CGRect`.
  - On `CanvasRenderer`: `static let selectionRingWidth: CGFloat`, and the amended `draw` / `drawCard` signatures below.
  - On `CanvasAccessibility`: `elements(scene:scraps:presentations:)`.
  - On `CanvasModel`: `@ObservationIgnored let imageCache: CanvasImageCache`, `var selectedNodeID: CanvasNodeID?`.
  - On `CanvasView`: `let store: ProjectStore`, `@State private var presentations`, `@State private var thumbnails`, `private func reloadItemContent()`.

- [ ] **Step 0: Verify the pre-state, and STOP if it does not hold**

```bash
grep -n "static func draw(" -A 10 Maugham/Canvas/CanvasRenderer.swift
grep -n "static func drawCard\|private static func drawCard" -A 6 Maugham/Canvas/CanvasRenderer.swift
grep -n "presentations" Maugham/Canvas/CanvasRenderer.swift Maugham/Canvas/CanvasView.swift
grep -n "static func elements" -A 3 Maugham/Canvas/CanvasAccessibility.swift
```

Expected: `draw(scene:camera:viewSize:layouts:scraps:selectedRegionID:mountedEditorNodeID:straighten:into:)`, `drawCard(_:frame:layout:angle:into:)`, **zero** hits for `presentations`, and `elements(scene:scraps:)`.

**If `presentations` already appears**, 1C-b was executed against its own Interfaces block rather than against 1C-a's reconciliation (see "Disagreement 1" at the top of this plan). Stop and report it — do not guess which half survived.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasItemNodeTests.swift`:

```swift
import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

final class CanvasItemNodeTests: XCTestCase {

    // MARK: - Card geometry

    func test_theCardWidthAndTheThumbnailBoxWidthAgree() {
        // 200 - 10 - 10 = 180.
        XCTAssertEqual(CanvasItemNode.defaultWidth, 200)
        XCTAssertEqual(CanvasCardMetrics.textWidth(forCardWidth: CanvasItemNode.defaultWidth), 180)
    }

    func test_aCardWithAThumbnailIsBoxPlusTitlePlusBothInsets() {
        // 130 (box) + 22 (title) = 152 of content; + 10 + 10 of inset = 172.
        XCTAssertEqual(CanvasItemNode.thumbnailBoxHeight, 130)
        XCTAssertEqual(CanvasItemNode.titleRowHeight, 22)
        XCTAssertEqual(CanvasItemNode.height(showsThumbnail: true), 172)
    }

    func test_aCardWithoutAThumbnailIsATitleRowPlusBothInsets() {
        // 22 of content; + 10 + 10 of inset = 42.
        XCTAssertEqual(CanvasItemNode.height(showsThumbnail: false), 42)
    }

    /// A node with no `cachedHeight` has no frame and is invisible to hit
    /// testing (1C-a Task 1). An item node's height is not measured from text,
    /// so it must be set at birth or the card cannot be clicked.
    func test_aMadeItemNodeIsImmediatelyHitTestable() {
        let node = CanvasItemNode.make(referenceId: "r-1", at: CGPoint(x: 10, y: 20),
                                       z: 3, showsThumbnail: true)
        XCTAssertEqual(node.id, CanvasNodeID.item("r-1"))
        XCTAssertEqual(node.kind, .item(referenceId: "r-1"))
        XCTAssertEqual(node.width, 200)
        XCTAssertEqual(node.z, 3)
        XCTAssertEqual(node.frame, CGRect(x: 10, y: 20, width: 200, height: 172))
    }

    func test_theThumbnailBoxSitsUnderTheCardsTopInsetAndAboveTheTitleRow() {
        let card = CGRect(x: 100, y: 200, width: 200, height: 172)
        // origin (110, 210); 180 wide; 130 tall.
        XCTAssertEqual(CanvasItemNode.thumbnailBox(inCard: card),
                       CGRect(x: 110, y: 210, width: 180, height: 130))
    }

    // MARK: - Aspect fit

    func test_aWideImageIsPillarboxedAndCentredVertically() {
        let box = CGRect(x: 0, y: 0, width: 180, height: 130)
        // 400x200: min(180/400, 130/200) = min(0.45, 0.65) = 0.45 -> 180 x 90.
        // Vertical slack (130 - 90) / 2 = 20.
        XCTAssertEqual(CanvasItemNode.fittedRect(imageSize: CGSize(width: 400, height: 200), in: box),
                       CGRect(x: 0, y: 20, width: 180, height: 90))
    }

    func test_aTallImageIsLetterboxedAndCentredHorizontally() {
        let box = CGRect(x: 0, y: 0, width: 180, height: 130)
        // 100x200: min(1.8, 0.65) = 0.65 -> 65 x 130.
        // Horizontal slack (180 - 65) / 2 = 57.5.
        XCTAssertEqual(CanvasItemNode.fittedRect(imageSize: CGSize(width: 100, height: 200), in: box),
                       CGRect(x: 57.5, y: 0, width: 65, height: 130))
    }

    func test_theFittedRectIsOffsetByTheBoxOrigin() {
        let box = CGRect(x: 110, y: 210, width: 180, height: 130)
        XCTAssertEqual(CanvasItemNode.fittedRect(imageSize: CGSize(width: 400, height: 200), in: box),
                       CGRect(x: 110, y: 230, width: 180, height: 90))
    }

    /// A zero-sized image would divide by zero and hand back NaN, which draws
    /// nothing and logs nothing.
    func test_aDegenerateImageSizeFitsToNothingRatherThanNaN() {
        let box = CGRect(x: 0, y: 0, width: 180, height: 130)
        XCTAssertEqual(CanvasItemNode.fittedRect(imageSize: .zero, in: box), .zero)
    }

    func test_theThumbnailIsDecodedAtFiveHundredAndTwelvePixels() {
        XCTAssertEqual(CanvasItemNode.thumbnailMaxPixelSize, 512,
                       "512 x 512 x 4 = 1 MiB, which is the unit CanvasImageCache's "
                       + "48 MiB budget is stated in")
    }

    // MARK: - The accessibility tree reads the resolved title

    func test_anItemNodeAnnouncesItsRealTitleRatherThanItsReferenceID() {
        var scene = CanvasScene()
        scene.insert(CanvasItemNode.make(referenceId: "r-photo", at: .zero,
                                         z: 0, showsThumbnail: true))
        let presentations: [CanvasNodeID: CanvasItemPresentation] = [
            .item("r-photo"): CanvasItemPresentation(
                title: "Falls, evening", symbolName: "photo",
                relativePath: "research/falls.jpg", isMissing: false, showsThumbnail: true)
        ]
        let elements = CanvasAccessibility.elements(
            scene: scene, scraps: [:], presentations: presentations)
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].role, .item)
        XCTAssertEqual(elements[0].value, "Falls, evening",
                       "an assistive client must hear what the writer sees, not "
                       + "an internal id")
    }

    /// §7A.6: we own the AX tree, and "unresolved" is information a screen
    /// reader user needs as much as a sighted one.
    func test_aMissingReferenceStillAnnouncesItselfWithItsReferenceID() {
        var scene = CanvasScene()
        scene.insert(CanvasItemNode.make(referenceId: "r-gone", at: .zero,
                                         z: 0, showsThumbnail: false))
        let elements = CanvasAccessibility.elements(
            scene: scene, scraps: [:], presentations: [:])
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].value,
                       CanvasRenderer.placeholderLabel(forReference: "r-gone"),
                       "an unresolved presentation must fall back to the same "
                       + "label the card draws, not to an empty string")
    }

    // MARK: - The selection ring

    func test_theSelectionRingIsDrawnAtAStatedWidth() {
        XCTAssertGreaterThan(CanvasRenderer.selectionRingWidth, 0,
                             "a selection that deletes on backspace must be "
                             + "visible before the writer presses it")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasItemNodeTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasItemNode' in scope`.

- [ ] **Step 3: Write `CanvasItemNode`**

`Maugham/Canvas/CanvasItemNode.swift`:

```swift
import Foundation

/// Item-card geometry, in ONE place — the same reason `CanvasCardMetrics`
/// exists. The draw pass and the drop handler both size an item card, and two
/// spellings would put the thumbnail on a different rect from the card it lives
/// in.
///
/// A scrap's height is DERIVED from its measured text (spec §7A.3). An item card
/// has no text to measure, so its height is a constant chosen by whether there
/// is a picture to show — and it must be set when the node is made, because a
/// node with no `cachedHeight` has no frame and is invisible to hit testing.
enum CanvasItemNode {
    /// Narrower than a scrap's 240: an item card is a reference, not a place to
    /// write, and a narrower card reads as a different kind of thing at a glance.
    static let defaultWidth: CGFloat = 200
    static let titleRowHeight: CGFloat = 22
    static let thumbnailBoxHeight: CGFloat = 130

    /// 512 x 512 x 4 = 1 MiB, which is the unit `CanvasImageCache`'s 48 MiB
    /// budget is stated in. Larger than the 180 x 130 pt box on purpose: the
    /// canvas zooms, and the image magnifies under the same CTM the glyphs do.
    static let thumbnailMaxPixelSize = 512

    static func height(showsThumbnail: Bool) -> CGFloat {
        CanvasCardMetrics.cardHeight(
            forTextHeight: showsThumbnail
                ? thumbnailBoxHeight + titleRowHeight
                : titleRowHeight)
    }

    /// `CanvasNodeID.item(_:)` is derived from the reference, so two adds of the
    /// same research item can only ever resolve to one node (1C-a Task 1).
    static func make(referenceId: String,
                     at origin: CGPoint,
                     z: Int,
                     showsThumbnail: Bool) -> CanvasNode {
        CanvasNode(id: .item(referenceId),
                   kind: .item(referenceId: referenceId),
                   origin: origin,
                   width: defaultWidth,
                   cachedHeight: height(showsThumbnail: showsThumbnail),
                   z: z)
    }

    /// The picture's box: the card's content rect, less the title row beneath it.
    static func thumbnailBox(inCard frame: CGRect) -> CGRect {
        let origin = CanvasCardMetrics.textOrigin(inCard: frame)
        return CGRect(x: origin.x, y: origin.y,
                      width: CanvasCardMetrics.textWidth(forCardWidth: frame.width),
                      height: thumbnailBoxHeight)
    }

    /// Aspect-fit, centred. Never fills: a cropped photograph on a planning
    /// surface hides the part the writer put it there for.
    static func fittedRect(imageSize: CGSize, in box: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: box.minX + (box.width - size.width) / 2,
                      y: box.minY + (box.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
```

- [ ] **Step 4: Amend the renderer**

In `Maugham/Canvas/CanvasRenderer.swift`, add the constant beside `resizeHandleSize`:

```swift
    /// The ring around the selected node. Backspace deletes it (Task 6), so the
    /// selection has to be visible before the writer presses the key.
    static let selectionRingWidth: CGFloat = 2
```

Extend `draw`'s parameter list with `presentations:`, `thumbnails:` and `selectedNodeID:`, keeping every existing parameter at its existing spelling and position:

```swift
    static func draw(scene: CanvasScene,
                     camera: CanvasCamera,
                     viewSize: CGSize,
                     layouts: [CanvasNodeID: ScrapLayout],
                     presentations: [CanvasNodeID: CanvasItemPresentation],
                     thumbnails: [CanvasNodeID: CGImage],
                     scraps: [CanvasNodeID: String],
                     selectedRegionID: CanvasRegionID?,
                     selectedNodeID: CanvasNodeID?,
                     mountedEditorNodeID: CanvasNodeID?,
                     straighten: CanvasFocusStraighten,
                     into cx: inout GraphicsContext) {
```

In the node pass, forward the three new values into `drawCard` — leave the culling call, the `hidingCollapsedResidents:` argument and the `angle:` computation exactly as 1C-b left them:

```swift
            drawCard(node, frame: frame,
                     layout: node.id == mountedEditorNodeID ? nil : layouts[node.id],
                     presentation: presentations[node.id],
                     thumbnail: thumbnails[node.id],
                     isSelected: node.id == selectedNodeID,
                     angle: drawnAngle(for: node.id, straighten: straighten),
                     into: &cx)
```

`chipTitle(for:scraps:)` gains the same map so a chip and the card it references cannot disagree about a title (spec §4.3):

```swift
    /// An appearance chip shows its subject's title. For a scrap that is the
    /// first line of its text; for an item it is the SAME resolved title the
    /// card draws — read from one map, so the two cannot disagree.
    private static func chipTitle(for node: CanvasNodeID,
                                  scraps: [CanvasNodeID: String],
                                  presentations: [CanvasNodeID: CanvasItemPresentation]) -> String {
        if let presentation = presentations[node] { return presentation.title }
        return (scraps[node] ?? "").split(separator: "\n").first.map(String.init) ?? ""
    }
```

and its one call site inside `draw`'s chip pass gains `presentations: presentations`.

Then replace `drawCard`'s signature and its `.item` arms. Everything before the first `switch node.kind` — the shape, the `card.transform` concatenation, the shadow layer and the fill — is 1C-a's and is untouched:

```swift
    private static func drawCard(_ node: CanvasNode,
                                 frame: CGRect,
                                 layout: ScrapLayout?,
                                 presentation: CanvasItemPresentation?,
                                 thumbnail: CGImage?,
                                 isSelected: Bool,
                                 angle: Angle,
                                 into cx: inout GraphicsContext) {
```

The border switch — a dashed edge now means "this reference no longer resolves", not "this slice has not built items yet":

```swift
        switch node.kind {
        case .scrap:
            card.stroke(shape, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
        case .item:
            // Dashed ONLY when unresolved. 1C-a dashed every item card because
            // it drew placeholders; a resolved reference is a real thing on the
            // canvas and reads as one.
            if presentation?.isMissing ?? true {
                card.stroke(shape, with: .color(Color(nsColor: .separatorColor)),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                card.stroke(shape, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
            }
        }

        if isSelected {
            card.stroke(shape, with: .color(Color(nsColor: .controlAccentColor)),
                        lineWidth: selectionRingWidth)
        }
```

and the content switch's `.item` arm:

```swift
        case .item(let referenceId):
            let presentation = presentation
                ?? CanvasItemPresentation(
                    title: placeholderLabel(forReference: referenceId),
                    symbolName: CanvasItemResolver.missingSymbolName,
                    relativePath: nil, isMissing: true, showsThumbnail: false)

            // The picture, when there is one AND it has been decoded. A card
            // whose thumbnail has not arrived yet shows its title row in the
            // meantime rather than jumping layout when it does — the height is
            // already reserved by `CanvasItemNode.height(showsThumbnail:)`.
            if presentation.showsThumbnail, let thumbnail {
                let box = CanvasItemNode.thumbnailBox(inCard: frame)
                let size = CGSize(width: CGFloat(thumbnail.width),
                                  height: CGFloat(thumbnail.height))
                // `decorative:` — no accessibility label, because the AX layer
                // announces this node itself (Task 3, Step 5). `scale: 1`: the
                // thumbnail is already in pixels and the CTM does the rest.
                let picture = card.resolve(Image(decorative: thumbnail, scale: 1))
                card.draw(picture, in: CanvasItemNode.fittedRect(imageSize: size, in: box))
            }

            let titleY = frame.maxY - CanvasCardMetrics.inset - CanvasItemNode.titleRowHeight / 2
            var glyph = card.resolve(
                Image(systemName: presentation.symbolName).font(.system(size: 10)))
            glyph.shading = .color(Color(nsColor: .secondaryLabelColor))
            card.draw(glyph,
                      at: CGPoint(x: frame.minX + CanvasCardMetrics.inset, y: titleY),
                      anchor: .leading)

            var title = card.resolve(
                Text(presentation.title).font(.system(size: 11)).lineLimit(1))
            title.shading = .color(Color(nsColor: presentation.isMissing
                                            ? .tertiaryLabelColor : .labelColor))
            card.draw(title,
                      at: CGPoint(x: frame.minX + CanvasCardMetrics.inset + 16, y: titleY),
                      anchor: .leading)
        }
```

- [ ] **Step 5: Amend the accessibility tree**

In `Maugham/Canvas/CanvasAccessibility.swift`, `elements` takes the same map and the `.item` arm reads it. Only the signature and that arm change; the reading-order sort and the `unmeasuredHeight` fallback are 1C-a's:

```swift
    static func elements(scene: CanvasScene,
                         scraps: [CanvasNodeID: String],
                         presentations: [CanvasNodeID: CanvasItemPresentation])
        -> [CanvasAXElement] {
```

```swift
                case .item(let referenceId):
                    // An assistive client must hear what the writer sees. An
                    // unresolved reference falls back to the SAME label the card
                    // draws — never to an empty string, which would make a
                    // missing card silent as well as blank.
                    return CanvasAXElement(
                        id: node.id, role: .item,
                        label: "Reference",
                        value: presentations[node.id]?.title
                            ?? CanvasRenderer.placeholderLabel(forReference: referenceId),
                        contentFrame: frame)
```

- [ ] **Step 6: Load the content once, and pass it in**

`Maugham/Canvas/CanvasModel.swift` — two stored properties. `@ObservationIgnored` on the cache: it is internal machinery whose mutation must not invalidate a view, and the decode pass bumps `CanvasView.revision` explicitly when new pictures land.

```swift
    /// Bounded, path-keyed (tripwire 22). Lives on the MODEL rather than the
    /// view so re-entering the Plan persona does not re-decode every photograph
    /// on the canvas — `CanvasView` is destroyed and rebuilt on every segment
    /// switch, the model is not.
    @ObservationIgnored let imageCache = CanvasImageCache()

    /// The node the writer has selected. Task 6 deletes it on ⌫ — from the
    /// canvas only, never from the project.
    var selectedNodeID: CanvasNodeID?
```

`Maugham/Canvas/CanvasView.swift` — one new stored property and two `@State` maps:

```swift
    /// Read for `manifest.research` (title/glyph/path resolution) and `url`
    /// (the project root the relative paths resolve against). Held, not copied:
    /// the resolution runs on `.task(id: store.manifest.modified)`, never in
    /// `body` (tripwire 4).
    let store: ProjectStore
```

```swift
    @State private var presentations: [CanvasNodeID: CanvasItemPresentation] = [:]
    /// The cache's per-pass projection. The cache is authoritative and bounded;
    /// this map holds only what it currently has, so an evicted image simply is
    /// not drawn until the next pass rather than pinning memory the budget
    /// already declined to spend.
    @State private var thumbnails: [CanvasNodeID: CGImage] = [:]
```

The draw call gains the three arguments:

```swift
                    CanvasRenderer.draw(scene: model.scene, camera: camera, viewSize: size,
                                        layouts: layouts,
                                        presentations: presentations,
                                        thumbnails: thumbnails,
                                        scraps: model.scraps,
                                        selectedRegionID: model.selectedRegionID,
                                        selectedNodeID: model.selectedNodeID,
                                        mountedEditorNodeID: mountedEditorNodeID,
                                        straighten: straighten, into: &cx)
```

and the accessibility call site gains `presentations: presentations`.

The loading pass, chained after the existing `.onAppear`/`.onDisappear` on the ZStack:

```swift
        .task(id: store.manifest.modified) { await reloadItemContent() }
```

```swift
    /// Resolve every item node's title/glyph/path and decode any thumbnails the
    /// cache does not already hold.
    ///
    /// `PaletteWallView`'s discipline: load once per manifest change, tiles do
    /// no I/O in `body` (tripwire 4). Its `downscaled` helper is NOT the
    /// pattern — see `CanvasThumbnailDecoder`.
    ///
    /// `await Task.yield()` between decodes so a canvas holding many
    /// photographs stays responsive while the first paint fills in. The cost is
    /// bounded and one-off: the cache is keyed by path and survives the view, so
    /// this runs on open and on a manifest change, not on every pan.
    private func reloadItemContent() async {
        let resolved = CanvasItemResolver.presentations(
            for: model.scene, in: store.manifest.research)
        presentations = resolved

        var built: [CanvasNodeID: CGImage] = [:]
        for (nodeID, presentation) in resolved {
            guard presentation.showsThumbnail, let relative = presentation.relativePath else {
                continue
            }
            let url = store.url.appendingPathComponent(relative)
            if let cached = model.imageCache.image(forPath: url.path) {
                built[nodeID] = cached
                continue
            }
            await Task.yield()
            guard let decoded = CanvasThumbnailDecoder.thumbnail(
                atFileURL: url, maxPixelSize: CanvasItemNode.thumbnailMaxPixelSize) else {
                continue
            }
            model.imageCache.insert(decoded, forPath: url.path)
            built[nodeID] = decoded
        }
        thumbnails = built
        // The pictures are new; the drawn output is stale. `revision` is the
        // redraw counter — `sceneRevision` is structural and nothing about the
        // scene's shape changed here.
        revision += 1
    }
```

`Maugham/Views/ProjectWindow.swift` — the `.canvas` arm of `existingEditorSwitch` gains one argument and stays a single expression:

```swift
        case .canvas:
            CanvasView(model: canvas,
                       store: store,
                       projectRoot: store.url,
                       paletteSwatchHexes: store.paletteSwatchHexes())
```

- [ ] **Step 7: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasItemNodeTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 13 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRendererTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-a's renderer tests must survive the signature change.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasAccessibilityTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-a's AX tests call `elements(scene:scraps:)`; update those call sites with `presentations: [:]`, which is the correct value for a scrap-only scene.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-b's chip tests call `chipTitle`/`draw`; update those call sites with `presentations: [:]`, `thumbnails: [:]`, `selectedNodeID: nil`.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas/CanvasItemNode.swift Maugham/Canvas/CanvasRenderer.swift \
        Maugham/Canvas/CanvasAccessibility.swift Maugham/Canvas/CanvasModel.swift \
        Maugham/Canvas/CanvasView.swift Maugham/Views/ProjectWindow.swift \
        MaughamTests/Canvas/CanvasItemNodeTests.swift \
        MaughamTests/Canvas/CanvasAccessibilityTests.swift \
        MaughamTests/Canvas/CanvasRegionRenderTests.swift
git commit -m "feat(canvas): item cards draw their real title, glyph and thumbnail

Replaces 1C-a's dashed placeholder. A dashed border now MEANS something —
this reference no longer resolves — rather than meaning the slice had not
been built. Titles resolve from the manifest on .task(id: manifest.modified)
and thumbnails decode at target size into the model-owned path-keyed
cache, so re-entering the Plan persona re-uses the pictures instead of
re-decoding them. Nothing does image I/O in body (tripwire 4).

The accessibility tree reads the resolved title too: an assistive client
hears what the writer sees, and an unresolved card falls back to the same
label it draws rather than going silent as well as blank."
```

---

### Task 4: Drag research onto the canvas — spec §8A.1

**Files:**
- Create: `Maugham/Canvas/CanvasDrop.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Modify: `Maugham/Canvas/ScrapEditorHost.swift`
- Test: `MaughamTests/Canvas/CanvasDropTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene.node(_:)` / `insert(_:)` / `move(_:to:)` / `topZ` (1C-a T1); `CanvasCamera.contentPoint(fromView:)` (1C-a T4); `CanvasItemNode.make(referenceId:at:z:showsThumbnail:)` (Task 3); `CanvasItemResolver.presentation(forReference:in:)` (Task 1); `CanvasModel.mutate(_:_:)` / `scene` (1C-b T4); `CanvasInteraction.joinTarget(for:in:) -> CanvasRegion?` and `CanvasMembership.join(_:home:in:)` (1C-b T2/T6); `TreeWalk.find(id:in:)`, `ResearchItem`.
- **Produces:**
  - `enum CanvasDropRouter` — `static func acceptedReferenceIDs(_ ids: [String], in research: [ResearchItem]) -> [String]`.
  - `enum CanvasDropPlacement` — `static let cascadeStep: CGFloat`, `static func points(count: Int, at origin: CGPoint) -> [CGPoint]`.
  - On `CanvasView`: `private func addItemNodes(referenceIds: [String], at contentPoint: CGPoint)`, and the `.dropDestination(for: String.self)` modifier.

**The binder is already beside the canvas and its rows are already draggable.** 1C-a Task 11 folds `.canvas` into `BinderPaneToggle`'s and `CollectionBinderPaneToggle`'s `.research` arms, so the Plan persona's left column *is* the research tree (spec §10's provisional answer, which §8A.1 depends on). `ResearchRow` already carries `.draggable(item.id)` publishing a plain `String` (`ResearchRow.swift:64`). So the drag source needs nothing: this task builds only the destination, and it uses the app's established pairing — `.dropDestination(for: String.self)` followed by `.onDrop(of: [.fileURL, .image])` — in the same order `ResearchRow.swift:69–88` ships it. That order is not a guess; it is the one combination in this codebase already known to let both an internal id drag and an external file drag land on one view.

**The file on disk is untouched.** Dropping creates a node holding a reference and a position (spec §3.1). Nothing is copied, nothing is written to the research note, and the manifest does not change — which is exactly why `addItemNodes` calls `reloadItemContent()` itself rather than waiting for `.task(id: store.manifest.modified)` to re-fire, since on an internal drop it never will.

**An id that does not name a research item is refused.** `BinderRow` and `PieceRow` publish document and piece ids through the same `.draggable(String)` channel, and a Finder drag often carries the filename as plain text. Accepting any string would mint an item node pointing at nothing, which resolves to a permanent "missing" card the writer never asked for. `acceptedReferenceIDs` filters against the actual research tree and the handler returns `false` when nothing survives, so an unrecognised drag is declined rather than absorbed.

**Re-dropping something the canvas already holds MOVES it.** `CanvasNodeID.item(_:)` is derived from the reference, so there is one node per referenced thing by construction (1C-a Task 1's doc comment says so in terms: *"Two adds of the same research item resolve to one node."*). The alternative — silently doing nothing — leaves the writer dragging a card that is already on the canvas somewhere off-screen, with no feedback at all.

**Landing on a region joins it, and that is §4.2's deliberate act.** Dropping a node onto a region adds it; geometry never does. A drag from the binder to a spot inside "Act II fog" is as deliberate as dragging a card there from elsewhere on the canvas, so it goes through the same `CanvasInteraction.joinTarget` + `CanvasMembership.join` pair 1C-b already uses for the canvas-internal case, rather than a second rule.

**The mounted scrap editor stops claiming drops.** `NSTextView` registers for dragged types by default, so a research item dropped exactly on the one focused scrap would be delivered to the text view and inserted as text — a drop that behaves differently on one card than on the rest of the surface, which is a smoke report waiting to happen. `unregisterDraggedTypes()` on the scrap text view makes the canvas's drop semantics uniform. Nothing is lost: only one editor is ever mounted, so there is no cross-scrap text drag to preserve.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasDropTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

final class CanvasDropTests: XCTestCase {

    private func tree() -> [ResearchItem] {
        [
            ResearchItem(id: "g1", title: "Locations", type: .group, path: "research/locations",
                         children: [
                            ResearchItem(id: "r-photo", title: "Falls", type: .asset,
                                         kind: .image, path: "research/locations/falls.jpg"),
                            ResearchItem(id: "r-note", title: "Doctor", type: .asset,
                                         kind: .document, path: "research/locations/doctor.md"),
                         ]),
        ]
    }

    // MARK: - What the canvas will accept

    func test_aResearchIDIsAccepted() {
        XCTAssertEqual(CanvasDropRouter.acceptedReferenceIDs(["r-photo"], in: tree()),
                       ["r-photo"])
    }

    func test_aGroupIDIsAcceptedTooBecauseAGroupIsAResearchItem() {
        XCTAssertEqual(CanvasDropRouter.acceptedReferenceIDs(["g1"], in: tree()), ["g1"])
    }

    /// `BinderRow` and `PieceRow` publish DOCUMENT and PIECE ids through the
    /// same `.draggable(String)` channel, and a Finder drag often carries the
    /// filename as plain text. Accepting any string mints a node pointing at
    /// nothing — a permanent "missing" card the writer never asked for.
    func test_anIDThatIsNotAResearchItemIsRefused() {
        XCTAssertTrue(CanvasDropRouter.acceptedReferenceIDs(["doc-42"], in: tree()).isEmpty)
        XCTAssertTrue(CanvasDropRouter.acceptedReferenceIDs(["falls.jpg"], in: tree()).isEmpty)
    }

    func test_aMixedDropKeepsOnlyTheResearchIDsAndTheirOrder() {
        XCTAssertEqual(
            CanvasDropRouter.acceptedReferenceIDs(["doc-42", "r-note", "nope", "r-photo"],
                                                  in: tree()),
            ["r-note", "r-photo"])
    }

    func test_anEmptyDropIsRefused() {
        XCTAssertTrue(CanvasDropRouter.acceptedReferenceIDs([], in: tree()).isEmpty)
    }

    // MARK: - Where several dropped items land

    func test_oneItemLandsExactlyWhereItWasDropped() {
        XCTAssertEqual(CanvasDropPlacement.points(count: 1, at: CGPoint(x: 100, y: 100)),
                       [CGPoint(x: 100, y: 100)])
    }

    /// Several files dropped at once must not stack into one visible card.
    func test_severalItemsCascadeByAFixedStep() {
        XCTAssertEqual(CanvasDropPlacement.cascadeStep, 24)
        // 3 at (100, 100), step 24: (100,100), (124,124), (148,148).
        XCTAssertEqual(CanvasDropPlacement.points(count: 3, at: CGPoint(x: 100, y: 100)),
                       [CGPoint(x: 100, y: 100),
                        CGPoint(x: 124, y: 124),
                        CGPoint(x: 148, y: 148)])
    }

    func test_zeroItemsPlaceNothing() {
        XCTAssertTrue(CanvasDropPlacement.points(count: 0, at: .zero).isEmpty)
    }

    func test_aNegativeCountPlacesNothingRatherThanTrapping() {
        XCTAssertTrue(CanvasDropPlacement.points(count: -1, at: .zero).isEmpty)
    }

    // MARK: - The node a drop produces

    /// §3.1: the canvas holds a reference and a position. This asserts the shape
    /// of what a drop creates without going through SwiftUI, which cannot be
    /// driven from a unit test.
    func test_aDroppedImageBecomesAnItemNodeSizedForAThumbnail() {
        let presentation = CanvasItemResolver.presentation(forReference: "r-photo", in: tree())
        let node = CanvasItemNode.make(referenceId: "r-photo",
                                       at: CGPoint(x: 40, y: 60), z: 1,
                                       showsThumbnail: presentation.showsThumbnail)
        XCTAssertEqual(node.frame, CGRect(x: 40, y: 60, width: 200, height: 172))
    }

    func test_aDroppedNoteBecomesATitleRowCard() {
        let presentation = CanvasItemResolver.presentation(forReference: "r-note", in: tree())
        let node = CanvasItemNode.make(referenceId: "r-note",
                                       at: CGPoint(x: 40, y: 60), z: 1,
                                       showsThumbnail: presentation.showsThumbnail)
        XCTAssertEqual(node.frame, CGRect(x: 40, y: 60, width: 200, height: 42))
    }

    /// The id is derived from the reference, so a second drop of the same note
    /// cannot mint a second node.
    func test_droppingTheSameItemTwiceResolvesToOneNode() {
        var scene = CanvasScene()
        scene.insert(CanvasItemNode.make(referenceId: "r-note", at: .zero,
                                         z: 0, showsThumbnail: false))
        let id = CanvasNodeID.item("r-note")
        XCTAssertNotNil(scene.node(id))
        scene.move(id, to: CGPoint(x: 500, y: 500))
        XCTAssertEqual(scene.count, 1)
        XCTAssertEqual(scene.node(id)?.origin, CGPoint(x: 500, y: 500),
                       "a re-drop MOVES the card the writer already has; doing "
                       + "nothing leaves them dragging at a card that is "
                       + "somewhere off-screen with no feedback")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasDropTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasDropRouter' in scope`.

- [ ] **Step 3: Write `CanvasDrop.swift`**

`Maugham/Canvas/CanvasDrop.swift`:

```swift
import Foundation
import MaughamCore

/// What the canvas will accept from an internal drag.
///
/// `ResearchRow` publishes `.draggable(item.id)` — a plain `String` — and so do
/// `BinderRow` (document ids) and `PieceRow` (piece ids). A Finder drag often
/// carries a filename as plain text as well. So the canvas filters: an id that
/// does not name something in the research tree is refused, because accepting it
/// would mint an item node pointing at nothing and leave the writer with a
/// permanent "missing" card they never asked for.
enum CanvasDropRouter {
    static func acceptedReferenceIDs(_ ids: [String],
                                     in research: [ResearchItem]) -> [String] {
        ids.filter { id in TreeWalk.find(id: id, in: research) != nil }
    }
}

/// Where several things dropped at once land.
enum CanvasDropPlacement {
    /// Enough that each card's title row is readable behind the next. Smaller
    /// and a multi-file drop reads as one card; larger and a drop of six flings
    /// the last one out of the viewport.
    static let cascadeStep: CGFloat = 24

    static func points(count: Int, at origin: CGPoint) -> [CGPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            CGPoint(x: origin.x + CGFloat(i) * cascadeStep,
                    y: origin.y + CGFloat(i) * cascadeStep)
        }
    }
}
```

- [ ] **Step 4: Wire the drop destination**

`Maugham/Canvas/CanvasView.swift` — chained on the ZStack, immediately after `.task(id: store.manifest.modified)`. `.dropDestination(for: String.self)` comes FIRST and `.onDrop(of: [.fileURL, .image])` (Task 5) second, matching `ResearchRow.swift:69–88` — the one ordering in this codebase already known to let both an internal id drag and an external file drag land on one view:

```swift
        // `location` is in this view's local space, which is the same space
        // `CanvasEventView` reports clicks in — so one conversion, the same one
        // the click path uses.
        .dropDestination(for: String.self) { ids, location in
            let refs = CanvasDropRouter.acceptedReferenceIDs(ids, in: store.manifest.research)
            guard !refs.isEmpty else { return false }
            addItemNodes(referenceIds: refs, at: camera.contentPoint(fromView: location))
            return true
        }
```

```swift
    /// Spec §8A.1. The file on disk is untouched: a node holds a reference and a
    /// position, nothing else (§3.1).
    ///
    /// One `model.mutate` for the whole drop, so ⌘Z takes back a drop of six
    /// files as one act (1C-b Task 6's rule: one gesture, one mechanism — this
    /// must NOT also be wrapped in `CanvasUndo.beginGesture`).
    private func addItemNodes(referenceIds: [String], at contentPoint: CGPoint) {
        guard !referenceIds.isEmpty else { return }
        let research = store.manifest.research
        let points = CanvasDropPlacement.points(count: referenceIds.count, at: contentPoint)

        model.mutate("Add to Canvas") { scene in
            for (i, referenceId) in referenceIds.enumerated() {
                let id = CanvasNodeID.item(referenceId)
                if scene.node(id) != nil {
                    // Already on the canvas. `CanvasNodeID.item(_:)` is derived
                    // from the reference, so there is one node per referenced
                    // thing by construction — move it to where the writer just
                    // dropped rather than silently doing nothing.
                    scene.move(id, to: points[i])
                } else {
                    let showsThumbnail = CanvasItemResolver
                        .presentation(forReference: referenceId, in: research).showsThumbnail
                    scene.insert(CanvasItemNode.make(referenceId: referenceId,
                                                     at: points[i],
                                                     z: scene.topZ + 1,
                                                     showsThumbnail: showsThumbnail))
                }
                // §4.2: dropping a node ONTO a region adds it, and a drag from
                // the binder to a spot inside a region is as deliberate as a
                // drag from elsewhere on the canvas. Same pair 1C-b uses for the
                // internal case — not a second rule.
                if let frame = scene.node(id)?.frame,
                   let target = CanvasInteraction.joinTarget(for: frame, in: scene) {
                    CanvasMembership.join(id, home: target.id, in: &scene)
                }
            }
        }

        sceneRevision += 1
        // An internal drop does not touch the manifest, so
        // `.task(id: store.manifest.modified)` will never re-fire for it. The
        // new cards would draw as unresolved until something else changed.
        Task { await reloadItemContent() }
    }
```

`Maugham/Canvas/ScrapEditorHost.swift` — one line where the `NSTextView` is configured, beside 1C-a's `allowsUndo = false`:

```swift
        // The canvas owns drops (spec §8A.1). `NSTextView` registers for dragged
        // types by default, so a research item dropped exactly on the one
        // focused scrap would be inserted as text — a drop that behaves
        // differently on one card than on the rest of the surface. Nothing is
        // lost: only one editor is ever mounted, so there is no cross-scrap
        // text drag to preserve.
        textView.unregisterDraggedTypes()
```

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasDropTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 12 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasCompositionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-a's layer-order pins must survive two new modifiers on the ZStack.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasDrop.swift Maugham/Canvas/CanvasView.swift \
        Maugham/Canvas/ScrapEditorHost.swift MaughamTests/Canvas/CanvasDropTests.swift
git commit -m "feat(canvas): drop a research item onto the canvas (spec 8A.1)

The binder is already beside the canvas and ResearchRow is already
draggable, so this is the destination only, using the app's established
.draggable(id) / .dropDestination(for: String.self) pairing in the same
order ResearchRow ships it.

The file on disk is untouched — a node holds a reference and a position.
An id that does not name a research item is REFUSED rather than absorbed:
BinderRow and PieceRow publish through the same String channel and a
Finder drag carries a filename, and either would mint a permanent missing
card. A re-drop moves the card the writer already has, because the node
id is derived from the reference. Landing on a region joins it through
the same joinTarget/join pair as an internal drag — 4.2's deliberate act,
not a second rule.

The mounted scrap editor unregisters its dragged types so the canvas's
drop behaviour is uniform instead of differing on the one focused card."
```

---

### Task 5: Photographs from Finder and the browser — spec §8A.1's external route

**Files:**
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasExternalDropTests.swift`

**Interfaces:**
- **Consumes:** `DropClassification.action(hasFileURL:canLoadImage:) -> DropAction` and `DropClassification.fileURLs(from: [NSItemProvider]) async -> [URL]` (`Maugham/Views/DropClassification.swift`); `ProjectStore.importResearchFiles(_:toParentId:) async throws -> [ResearchItem]`; `CanvasView.addItemNodes(referenceIds:at:)` and `reloadItemContent()` (Task 4 / Task 3); `CanvasCamera.contentPoint(fromView:)`.
- **Produces:** on `CanvasView`, `private func importExternalDrop(_ providers: [NSItemProvider], at contentPoint: CGPoint) async` and the `.onDrop(of: [.fileURL, .image], isTargeted: nil)` modifier.

**Do not hand-roll this.** `.dropDestination(for: URL.self)` silently rejects a browser image drag: those carry a rendered bitmap rather than a file URL, and CoreTransferable fails with error 0 and no diagnostic. That is recorded in `DropClassification`'s own doc comment, the canonical fix landed for the palette well in `d55891c`, and all three Research zones plus `PaletteCardEditor` already route through it. The canvas is the fifth adopter and adds no classification logic of its own — `DropClassification.fileURLs(from:)` already turns Finder file URLs into themselves and browser bitmaps into a temp PNG, and returns nothing for a remote-URL-only drag because we never fetch over the network.

**An external photo becomes a real research asset first and an item node second.** This is the load-bearing decision of the task and it follows straight from §3.1: items on the canvas are *things that already exist*, and the file on disk is the truth. So the import goes through `ProjectStore.importResearchFiles` — the same path the Research pane uses, which copies into `research/`, dedupes the filename and writes the manifest — and only then does the canvas reference what came back. The alternatives were both rejected: a canvas-owned image store under `.maugham/` would make the sidecar non-derived, contradicting §8's "deletable without loss of content"; and a node pointing at the writer's `~/Downloads` would break the moment they tidied up.

**Imported files land at the research root.** `toParentId: nil`. It is the one destination that does not require inventing a rule about which group a canvas drop belongs to, it matches the collection pane's root-drop behaviour (`CollectionResearchPane.swift:389`), and the writer can file it afterwards with the machinery that already exists. Task 8's guide text says so plainly rather than leaving it to be discovered.

**The manifest changes here, so `.task(id: store.manifest.modified)` re-fires on its own.** `addItemNodes` also calls `reloadItemContent()` (Task 4) because an *internal* drop does not touch the manifest; on this path the two overlap harmlessly, and the cache means the second pass decodes nothing.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasExternalDropTests.swift`:

```swift
import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Maugham

final class CanvasExternalDropTests: XCTestCase {

    // MARK: - The canvas must route through the shared classifier

    /// A Finder drag carries BOTH a file URL and a bitmap; the on-disk file wins
    /// because it preserves the original name and extension.
    func test_aFinderDragPrefersTheFileURL() {
        XCTAssertEqual(DropClassification.action(hasFileURL: true, canLoadImage: true),
                       .fileURL)
    }

    /// The whole reason `DropClassification` exists: a browser image drag has no
    /// file URL, so `.dropDestination(for: URL.self)` rejects it with
    /// CoreTransferable error 0 and no diagnostic.
    func test_aBrowserImageDragFallsToTheRenderedBitmap() {
        XCTAssertEqual(DropClassification.action(hasFileURL: false, canLoadImage: true),
                       .image)
    }

    func test_aRemoteURLOnlyDragIsIgnoredBecauseWeNeverFetch() {
        XCTAssertEqual(DropClassification.action(hasFileURL: false, canLoadImage: false),
                       .ignore)
    }

    func test_aBrowserBitmapProviderYieldsATempFileURL() async throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemTeal.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        image.unlockFocus()

        let provider = NSItemProvider(object: image)
        let urls = await DropClassification.fileURLs(from: [provider])
        let url = try XCTUnwrap(urls.first,
                                "a rendered-bitmap drag must land as an importable "
                                + "file, or every browser drag onto the canvas is lost")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "png")
        try? FileManager.default.removeItem(at: url)
    }

    func test_noProvidersYieldNoURLs() async {
        let urls = await DropClassification.fileURLs(from: [])
        XCTAssertTrue(urls.isEmpty)
    }

    // MARK: - Tripwire: never the URL-only drop destination

    /// `.dropDestination(for: URL.self)` silently rejects browser image drags
    /// (CoreTransferable error 0, recorded in `DropClassification`'s doc
    /// comment). Every external-drop zone in the app routes through
    /// `[.fileURL, .image]` providers plus the shared classifier, and the canvas
    /// is the fifth adopter. A grep is the only thing that stops the tempting
    /// one-liner coming back.
    func test_theCanvasNeverUsesTheURLOnlyDropDestination() throws {
        let dir = Self.repoRoot.appendingPathComponent("Maugham/Canvas", isDirectory: true)
        var offenders: [String] = []
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.components(separatedBy: .newlines).enumerated()
            where line.contains("dropDestination(for: URL.self)") {
                offenders.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            ".dropDestination(for: URL.self) silently rejects browser image "
            + "drags (CoreTransferable error 0). Use .onDrop(of: [.fileURL, "
            + ".image]) plus DropClassification — see Maugham/Views/"
            + "DropClassification.swift. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Sibling guard: the canvas must not grow its own copy of the classifier.
    func test_theCanvasDoesNotReimplementTheClassifier() throws {
        let dir = Self.repoRoot.appendingPathComponent("Maugham/Canvas", isDirectory: true)
        var offenders: [String] = []
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.components(separatedBy: .newlines).enumerated()
            where line.contains("loadObject(ofClass: NSImage.self)")
                || line.contains("UTType.fileURL.identifier") {
                offenders.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "Provider loading belongs in DropClassification, not in the canvas. "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// `#filePath` is `…/MaughamTests/Canvas/CanvasExternalDropTests.swift`, so
    /// three deletions reach the repo root.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasExternalDropTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — the file does not compile until it exists in the project, and once it does the two grep tests are the ones that must pass immediately while the rest exercise existing code. If **all** seven pass on the first run, that is correct and expected: this task's implementation is a wiring change, and its own guard is that the wiring cannot be written the wrong way. Proceed to Step 3 and re-run.

- [ ] **Step 3: Wire the external drop**

`Maugham/Canvas/CanvasView.swift` — chained on the ZStack immediately **after** the `.dropDestination(for: String.self)` from Task 4, mirroring `ResearchRow.swift:79`:

```swift
        // Browser image drags carry a rendered bitmap rather than a file URL, so
        // `[.fileURL, .image]` providers plus `DropClassification` is the only
        // route that lands them — see that file's doc comment. Never
        // `.dropDestination(for: URL.self)`.
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers, location in
            guard !providers.isEmpty else { return false }
            let point = camera.contentPoint(fromView: location)
            Task { await importExternalDrop(providers, at: point) }
            return true
        }
```

and the handler:

```swift
    /// Spec §8A.1's external route. The photograph becomes a REAL research asset
    /// first and an item node second, because §3.1 says items on the canvas are
    /// things that already exist and the file on disk is the truth.
    ///
    /// Rejected alternatives: a canvas-owned image store under `.maugham/` would
    /// make the sidecar non-derived, contradicting §8's "deletable without loss
    /// of content"; a node pointing at the writer's `~/Downloads` would break the
    /// moment they tidied up.
    ///
    /// `toParentId: nil` — the research root. The one destination that needs no
    /// rule about which group a canvas drop belongs to, matching
    /// `CollectionResearchPane`'s root drop; the writer files it afterwards with
    /// the machinery that already exists.
    private func importExternalDrop(_ providers: [NSItemProvider],
                                    at contentPoint: CGPoint) async {
        let urls = await DropClassification.fileURLs(from: providers)
        guard !urls.isEmpty else { return }
        guard let imported = try? await store.importResearchFiles(urls, toParentId: nil),
              !imported.isEmpty else { return }
        addItemNodes(referenceIds: imported.map(\.id), at: contentPoint)
    }
```

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasExternalDropTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 7 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasDropTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasView.swift MaughamTests/Canvas/CanvasExternalDropTests.swift
git commit -m "feat(canvas): external photo drops route through DropClassification

Browser image drags carry a rendered bitmap rather than a file URL, so
.dropDestination(for: URL.self) rejects them with CoreTransferable error
0 and no diagnostic. The canvas is the fifth adopter of the shared
[.fileURL, .image] + DropClassification route and adds no classification
of its own; two greps over Maugham/Canvas/ stop the tempting one-liner
and a local copy of the provider loading from coming back.

An external photo becomes a real research asset first and an item node
second (spec 3.1), imported to the research root through the same
ProjectStore path the Research pane uses. A canvas-owned image store
under .maugham/ would make the sidecar non-derived; a node pointing at
~/Downloads would break the moment the writer tidied up."
```

---

### Task 6: Removing a node removes it from the canvas, never from the project

**Files:**
- Modify: `Maugham/Canvas/CanvasModel.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasNodeRemovalTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene.node(_:)` / `remove(_:)` / `topmostNode(at:)` / `count` / `region(_:)` / `insertRegion(_:)` (1C-a T1, 1C-b T2); `CanvasRegion.homeMembers` / `appearances` (1C-b T1); `CanvasMembership.join(_:home:in:)` / `addAppearance(_:to:in:)` / `homeRegion(of:in:)` / `appearanceRegions(of:in:)` / `leave(_:from:in:)` (1C-b T2); `CanvasModel.mutate(_:_:)` / `withScene(persist:_:)` / `load(projectRoot:)` / `flush()` / `undoManager` / `selectedRegionID` / `deleteSelectedRegion()` (1C-b T4); `CanvasStore(projectRoot:)` / `load()` (1C-a T5); `CanvasModel.selectedNodeID` and `CanvasRenderer.selectionRingWidth` (Task 3); `CanvasItemNode.make(referenceId:at:z:showsThumbnail:)` (Task 3); `CanvasEventView.onDeleteKey` (1C-b T6).
- **Produces:** on `CanvasModel`, `func removeSelectedNodeFromCanvas()` and `func selectNode(_ id: CanvasNodeID?)`; on `CanvasView`, an amended `handleClick` and an amended `onDeleteKey` route.

**Spec §8A.1 states the property this task delivers, and it is the one a writer will test on their first afternoon:** *"Deleting a node from the canvas removes it from the canvas, never from the project."* A card the writer put down and then thought better of must be removable without a second thought, and the thought they must never have to have is *"will this delete my photograph?"*

**Tripwire 14 is satisfied by not moving or deleting user content at all.** The rule says any move or delete of user-editable content routes through the typed `DocumentStore` mover, because a 750 ms autosave otherwise recreates the file at the old path. The canvas has nothing to route: removing a node is a mutation of `CanvasScene`, which lives in the sidecar. So the guard here is the *inverse* one — a grep asserting that nothing under `Maugham/Canvas/` reaches for `removeItem`, `trashItem`, `moveItem`, `moveToTrash`, `relocate`, `deleteResearchItem` or `importResearchFiles`. That grep is the whole safety property, stated as a test rather than as a comment.

`CanvasView.importExternalDrop` (Task 5) calls `importResearchFiles`, so `CanvasView.swift` is allow-listed for that one symbol with the reason: an *import* creates content, it does not move or delete any. `CanvasStore.swift` is allow-listed wholesale — it owns `canvas.md` and `.maugham/canvas.json`, both of which are the canvas's own files and neither of which is a manuscript or a research asset.

**Deleting a member must also leave its regions.** A region's `homeMembers` / `appearances` are sets of `CanvasNodeID` (1C-b Task 1). Removing a node without leaving them strands an id that names nothing — the region would count a member it can never draw, and 1C-b's tether and chip passes would look up a node that is gone. `CanvasMembership.leave` is the existing door; membership changes only by deliberate act (§4.2), and deleting the node *is* the deliberate act.

**Selection is model state, for the same reason `selectedRegionID` is.** 1C-b put region selection on `CanvasModel` so the canvas and the inspector agree about one value. Node selection is the same shape and belongs beside it. Task 3 already draws the ring; this task is what sets the value.

**A node wins over a region on ⌫.** If the writer has just clicked a card, that card is what "delete" means. Clicking a card clears the region selection and vice versa, so the two can never both be set and the precedence never actually arbitrates — it is stated so that a future change to one of the two clear-sites cannot silently make ⌫ ambiguous.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasNodeRemovalTests.swift`:

```swift
import XCTest
@testable import Maugham

final class CanvasNodeRemovalTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func loadedModel() -> CanvasModel {
        let model = CanvasModel()
        model.load(projectRoot: root)
        model.withScene { scene in
            scene.insert(CanvasItemNode.make(referenceId: "r-photo",
                                             at: CGPoint(x: 100, y: 100),
                                             z: 1, showsThumbnail: true))
            var scrap = CanvasNode(id: CanvasNodeID("s1"), kind: .scrap,
                                   origin: CGPoint(x: 400, y: 100), width: 240)
            scrap.cachedHeight = 80
            scene.insert(scrap)
            scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                            frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        return model
    }

    // MARK: - Selection

    func test_selectingANodeClearsAnyRegionSelection() {
        let model = loadedModel()
        model.selectedRegionID = CanvasRegionID("r1")
        model.selectNode(.item("r-photo"))
        XCTAssertEqual(model.selectedNodeID, CanvasNodeID.item("r-photo"))
        XCTAssertNil(model.selectedRegionID,
                     "two live selections make ⌫ ambiguous")
    }

    func test_selectingNothingClearsTheNodeSelection() {
        let model = loadedModel()
        model.selectNode(.item("r-photo"))
        model.selectNode(nil)
        XCTAssertNil(model.selectedNodeID)
    }

    // MARK: - Removal is canvas-only

    func test_removingAnItemNodeTakesItOffTheSceneOnly() {
        let model = loadedModel()
        model.selectNode(.item("r-photo"))
        model.removeSelectedNodeFromCanvas()
        XCTAssertNil(model.scene.node(.item("r-photo")))
        XCTAssertNil(model.selectedNodeID)
        XCTAssertEqual(model.scene.count, 1, "the scrap is untouched")
    }

    func test_removingWithNothingSelectedDoesNothing() {
        let model = loadedModel()
        model.removeSelectedNodeFromCanvas()
        XCTAssertEqual(model.scene.count, 2)
    }

    /// A region's membership is a set of node ids. Leaving a stale id behind
    /// makes the region count a member it can never draw, and 1C-b's tether and
    /// chip passes then look up a node that is gone.
    func test_removingAResidentAlsoLeavesItsRegions() throws {
        let model = loadedModel()
        model.withScene { scene in
            CanvasMembership.join(.item("r-photo"), home: CanvasRegionID("r1"), in: &scene)
        }
        XCTAssertEqual(CanvasMembership.homeRegion(of: .item("r-photo"), in: model.scene),
                       CanvasRegionID("r1"))

        model.selectNode(.item("r-photo"))
        model.removeSelectedNodeFromCanvas()

        let region = try XCTUnwrap(model.scene.region(CanvasRegionID("r1")))
        XCTAssertFalse(region.homeMembers.contains(.item("r-photo")))
        XCTAssertFalse(region.appearances.contains(.item("r-photo")))
    }

    func test_removingANodeThatMerelyAppearsSomewhereAlsoLeavesThatRegion() {
        let model = loadedModel()
        model.withScene { scene in
            CanvasMembership.addAppearance(.item("r-photo"), to: CanvasRegionID("r1"), in: &scene)
        }
        model.selectNode(.item("r-photo"))
        model.removeSelectedNodeFromCanvas()
        XCTAssertTrue(CanvasMembership.appearanceRegions(of: .item("r-photo"),
                                                         in: model.scene).isEmpty)
    }

    /// ⌘Z is what makes a destructive gesture on a spatial surface survivable.
    func test_removalIsOneUndoStep() {
        let model = loadedModel()
        model.selectNode(.item("r-photo"))
        model.removeSelectedNodeFromCanvas()
        model.undoManager.undo()
        XCTAssertNotNil(model.scene.node(.item("r-photo")))
        XCTAssertEqual(model.scene.node(.item("r-photo"))?.origin, CGPoint(x: 100, y: 100))
    }

    func test_removalSurvivesToDiskSoItIsNotUndoneByAReopen() {
        let model = loadedModel()
        model.selectNode(.item("r-photo"))
        model.removeSelectedNodeFromCanvas()
        model.flush()
        XCTAssertNil(CanvasStore(projectRoot: root).load().scene.node(.item("r-photo")))
    }

    // MARK: - Tripwire 14, inverted: the canvas touches no user content

    /// Spec §8A.1: "Deleting a node from the canvas removes it from the canvas,
    /// never from the project." Tripwire 14 says any move or delete of
    /// user-editable content routes through the typed `DocumentStore` mover. The
    /// canvas has nothing to route — removal is a mutation of a sidecar value —
    /// so the guard is the inverse one, and it IS the safety property.
    func test_nothingInTheCanvasAreaMovesOrDeletesUserContent() throws {
        let dir = Self.repoRoot.appendingPathComponent("Maugham/Canvas", isDirectory: true)
        // `CanvasStore` owns canvas.md and .maugham/canvas.json — the canvas's
        // OWN files, neither a manuscript nor a research asset.
        let exemptFiles: Set<String> = ["CanvasStore.swift"]
        // An IMPORT creates content; it moves and deletes nothing (Task 5).
        let exemptPairs: Set<String> = ["CanvasView.swift|importResearchFiles"]
        let forbidden = ["removeItem", "trashItem", "moveItem", "moveToTrash",
                         "relocateUserContent", "relocate(", "deleteResearchItem",
                         "importResearchFiles"]

        var offenders: [String] = []
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let name = file.lastPathComponent
            guard !exemptFiles.contains(name) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.components(separatedBy: .newlines).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                for needle in forbidden where line.contains(needle) {
                    guard !exemptPairs.contains("\(name)|\(needle)") else { continue }
                    offenders.append("\(name):\(i + 1)  \(needle)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "The canvas must never move or delete user content (spec §3.1/§8A.1, "
            + "tripwire 14). Removing a node removes it FROM THE CANVAS. If a "
            + "canvas feature genuinely needs to move user content, it routes "
            + "through the typed DocumentStore mover and gets an entry in this "
            + "test's exemption list with a reason. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasNodeRemovalTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `value of type 'CanvasModel' has no member 'selectNode'`.

- [ ] **Step 3: Write the implementation**

`Maugham/Canvas/CanvasModel.swift` — beside `deleteSelectedRegion()`:

```swift
    /// Node selection, beside region selection and for the same reason: the
    /// canvas and anything in the right-hand column must agree about one value.
    ///
    /// Selecting a node clears the region selection. Two live selections would
    /// make ⌫ ambiguous, and "whichever the writer touched last" is only a rule
    /// if exactly one of them can be set.
    func selectNode(_ id: CanvasNodeID?) {
        selectedNodeID = id
        if id != nil { selectedRegionID = nil }
    }

    /// Spec §8A.1: "Deleting a node from the canvas removes it from the canvas,
    /// never from the project." No file is moved, trashed or rewritten — this is
    /// a mutation of a sidecar value, which is why tripwire 14's typed mover is
    /// not involved and why `CanvasNodeRemovalTests` greps to keep it that way.
    ///
    /// Leaving the node's regions first is not optional: a region's membership
    /// is a set of ids, and a stale id makes it count a member it can never
    /// draw. Membership changes only by deliberate act (§4.2) — deleting the
    /// node IS the deliberate act.
    func removeSelectedNodeFromCanvas() {
        guard let id = selectedNodeID else { return }
        mutate("Remove from Canvas") { scene in
            if let home = CanvasMembership.homeRegion(of: id, in: scene) {
                CanvasMembership.leave(id, from: home, in: &scene)
            }
            for region in CanvasMembership.appearanceRegions(of: id, in: scene) {
                CanvasMembership.leave(id, from: region, in: &scene)
            }
            scene.remove(id)
        }
        selectedNodeID = nil
    }
```

`Maugham/Canvas/CanvasView.swift` — in `handleClick`, after the existing commit-the-in-flight-edit block and alongside whatever 1C-b's region hit test already does, record the node under the pointer. A click on empty canvas clears the selection, which is what makes ⌫ safe:

```swift
        // Selection follows the click. Empty canvas clears it — a ⌫ that
        // deletes something the writer stopped looking at three gestures ago is
        // the failure this line exists to prevent.
        model.selectNode(model.scene.topmostNode(at: contentPoint)?.id)
```

and route the delete key, replacing 1C-b Task 6's region-only closure:

```swift
                onDeleteKey: {
                    // A node wins: if the writer just clicked a card, that card
                    // is what "delete" means. The two selections are mutually
                    // exclusive (`CanvasModel.selectNode`), so this precedence
                    // never actually arbitrates — it is stated so a future
                    // change to either clear-site cannot make ⌫ ambiguous in
                    // silence.
                    if model.selectedNodeID != nil {
                        model.removeSelectedNodeFromCanvas()
                    } else {
                        model.deleteSelectedRegion()
                    }
                    sceneRevision += 1
                },
```

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasNodeRemovalTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 9 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasModelTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-b's model tests must survive the two new members.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-b's ⌫-deletes-a-region behaviour must still hold when no node is selected.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasModel.swift Maugham/Canvas/CanvasView.swift \
        MaughamTests/Canvas/CanvasNodeRemovalTests.swift
git commit -m "feat(canvas): ⌫ removes a node from the canvas, never from the project

Spec 8A.1's stated property, and the one a writer tests on their first
afternoon. Removal is a mutation of a sidecar value, so tripwire 14's
typed mover is not involved — and the guard is the INVERSE one: a grep
asserting nothing under Maugham/Canvas/ reaches for removeItem,
trashItem, moveItem, moveToTrash, relocate or deleteResearchItem. That
grep is the safety property, not a comment about it.

Deleting a resident leaves its regions first, or the region counts a
member it can never draw and 1C-b's tether and chip passes look up a node
that is gone. Node and region selection are mutually exclusive so ⌫ is
never ambiguous, and a click on empty canvas clears the selection."
```

---

### Task 7: `⌘\` collapses both side columns on the canvas — spec §8A.3

**Files:**
- Create: `Maugham/Canvas/CanvasFocusColumns.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Modify: `MaughamTests/PersonaModifierTests.swift`
- Test: `MaughamTests/Canvas/CanvasFocusColumnsTests.swift`

**Interfaces:**
- **Consumes:** `BinderSegment` and its `.canvas` / `.palette` cases (1C-a T11); `PersonaModifier.applyPersonaChange(to:from:currentSegment:currentBinderSegment:projectType:memory:) -> Change` and `PersonaModifier.clearsPaletteStash(from:to:)` (`ProjectWindow.swift:1445`, `:1483`); `PersonaMemory(binder:)`; `DetailSegment`.
- **Produces:**
  - `struct CanvasColumnStash: Equatable` — `var showInspector: Bool`, `var columnVisibility: NavigationSplitViewVisibility`.
  - `enum CanvasFocusColumns` — `static let collapsed: CanvasColumnStash`, `static func isCanvasFocus(isNoChromeOn: Bool, segment: BinderSegment) -> Bool`, `static func resolve(isCanvasFocus: Bool, stash: CanvasColumnStash?, current: CanvasColumnStash) -> (stash: CanvasColumnStash?, apply: CanvasColumnStash)?`.
  - On `PersonaModifier`: `static let columnStashingSegments: Set<BinderSegment>`, `static func clearsColumnStash(from: BinderSegment, to: BinderSegment) -> Bool` (**replaces** `clearsPaletteStash`), and two new bindings `columnVisibility`, `canvasColumnStash`.
  - On `ProjectWindow`: `@State private var columnVisibility: NavigationSplitViewVisibility`, `@State private var canvasColumnStash: CanvasColumnStash?`, `private struct CanvasFocusColumnsModifier`, `private struct ProjectOverlaysModifier`.

**Reuse `⌘\`, do not add a key.** Focus mode already hides the titlebar, the traffic lights, the persona bar and the status footer. On the canvas it additionally collapses both side columns. That extends muscle memory the writer already has, and the exit is the key they already know.

**It is a deliberate toggle and never automatic on entering the persona.** Spec §8A.3 is explicit about why: auto-collapsing would fight §8A.1, because you need the binder open to drag research across and only then do you want it gone. The palette wall *does* hide the inspector automatically on entry (`PaletteSegmentModifier`); the canvas deliberately declines that precedent, and Task 8 records the divergence so it does not read as an oversight later.

**Which column each mechanism hides.** The right column already has one: `detailColumn(store:documentStore:)` is a `@ViewBuilder` that returns nothing when `showInspector == false`. The left one does not, so this task adds a `columnVisibility` binding on the `NavigationSplitView` and sets it to `.doubleColumn` — which, in a three-column split, means "content and detail, no sidebar". The two together leave the centre column alone with the canvas in it.

**The ordering hazard, and why the predicate is extended rather than duplicated.** `PersonaModifier.clearsPaletteStash` exists because `PaletteSegmentModifier`'s `.onChange(of: binderSegment)` fires in a *later* update pass than the persona handler, so its exit arm would restore the stashed inspector visibility *over* the persona switch's `showInspector = true`. A canvas column stash has exactly the same shape and inherits exactly the same hazard. Tripwire 2 forbids the obvious fix — a flag-based guard or a deferred pass — because `.onChange` fires after a synchronous flag-clear and the guard leaks.

So the existing predicate is **generalised**, not copied:

```swift
static let columnStashingSegments: Set<BinderSegment> = [.palette, .canvas]
static func clearsColumnStash(from: BinderSegment, to: BinderSegment) -> Bool
```

and the persona handler drops *both* stashes when it fires. Dropping the palette stash while leaving the canvas is a no-op — `inspectorWasVisibleBeforePalette` is non-nil only while the binder is on `.palette` — so one predicate covering both is strictly safer than two that can fall out of step. A second predicate is a second thing to forget.

**The persona handler must force-open BOTH columns.** It already sets `showInspector = true`. Without `columnVisibility = .all` beside it, a writer who leaves canvas focus mode by pressing ⌘2 lands in the Author persona with the sidebar still collapsed and no obvious way back — the stash that would have restored it was just dropped, correctly, by the line above.

**One `.onChange`, on one derived value.** `isCanvasFocus` is `isNoChromeOn && binderSegment == .canvas`. Observing the two inputs separately would fire twice for a single ⌘\-on-canvas and the second pass would read a stash the first had just written. `CanvasFocusColumns.resolve` returns `nil` for "nothing to do", so a repeat in either direction is inert rather than destructive — which is what makes the single trigger safe rather than merely tidy.

**`ProjectWindow.body`'s budget: this task spends one expression and buys three back first.** `body` is at 28 chained expressions, eleven extracted `ViewModifier`s exist solely to buy expressions back, and the ceiling has been hit twice — once passing Debug and failing Release CI. `columnVisibility: $columnVisibility` is one added initialiser argument. Before adding it, the two `.overlay` blocks and the `.animation` chained on the `NavigationSplitView` move into `ProjectOverlaysModifier`: −3, +1, net **−2**. `CanvasFocusColumnsModifier` is one more `.modifier(…)` on the outer chain: net **−1** overall, and the two `@State` properties are free (a stored property is not a body expression).

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasFocusColumnsTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Maugham

final class CanvasFocusColumnsTests: XCTestCase {

    private let open = CanvasColumnStash(showInspector: true, columnVisibility: .all)

    // MARK: - When the rule applies at all

    func test_focusModeOnTheCanvasCollapsesTheColumns() {
        XCTAssertTrue(CanvasFocusColumns.isCanvasFocus(isNoChromeOn: true, segment: .canvas))
    }

    /// §8A.3: a deliberate toggle, never automatic on entering the persona.
    /// Entering the canvas with focus mode off must change nothing — you need
    /// the binder open to drag research across (§8A.1).
    func test_enteringTheCanvasAloneCollapsesNothing() {
        XCTAssertFalse(CanvasFocusColumns.isCanvasFocus(isNoChromeOn: false, segment: .canvas))
    }

    /// ⌘\ off the canvas keeps its existing meaning exactly: chrome only.
    func test_focusModeOffTheCanvasDoesNotTouchTheColumns() {
        XCTAssertFalse(CanvasFocusColumns.isCanvasFocus(isNoChromeOn: true, segment: .manuscript))
        XCTAssertFalse(CanvasFocusColumns.isCanvasFocus(isNoChromeOn: true, segment: .research))
        XCTAssertFalse(CanvasFocusColumns.isCanvasFocus(isNoChromeOn: true, segment: .palette))
    }

    // MARK: - The transition

    func test_collapsingStashesWhatWasThereAndHidesBothColumns() throws {
        let step = try XCTUnwrap(
            CanvasFocusColumns.resolve(isCanvasFocus: true, stash: nil, current: open))
        XCTAssertEqual(step.stash, open, "leaving must restore exactly what was there")
        XCTAssertEqual(step.apply.showInspector, false)
        XCTAssertEqual(step.apply.columnVisibility, .doubleColumn,
                       "in a three-column split, .doubleColumn is content+detail "
                       + "— the sidebar is the one that goes")
        XCTAssertEqual(step.apply, CanvasFocusColumns.collapsed)
    }

    func test_leavingRestoresExactlyWhatWasStashed() throws {
        let closedInspector = CanvasColumnStash(showInspector: false, columnVisibility: .all)
        let step = try XCTUnwrap(
            CanvasFocusColumns.resolve(isCanvasFocus: false,
                                       stash: closedInspector,
                                       current: CanvasFocusColumns.collapsed))
        XCTAssertNil(step.stash)
        XCTAssertEqual(step.apply, closedInspector,
                       "a writer who had the inspector closed before ⌘\\ must not "
                       + "have it opened for them on the way out")
    }

    /// The single `.onChange` fires on a derived value, so a repeat is possible.
    /// It must be inert, not destructive — a second collapse that re-stashed
    /// would capture the ALREADY-collapsed state and strand both columns hidden.
    func test_collapsingTwiceDoesNothingTheSecondTime() {
        XCTAssertNil(CanvasFocusColumns.resolve(isCanvasFocus: true,
                                                stash: open,
                                                current: CanvasFocusColumns.collapsed))
    }

    func test_leavingWithNoStashDoesNothing() {
        XCTAssertNil(CanvasFocusColumns.resolve(isCanvasFocus: false,
                                                stash: nil,
                                                current: open))
    }

    /// The persona-switch path: the handler drops the stash, so the later pass
    /// that would have restored it finds nothing and leaves the force-open alone.
    func test_aDroppedStashMakesTheRestoreArmANoOp() {
        XCTAssertNil(CanvasFocusColumns.resolve(isCanvasFocus: false,
                                                stash: nil,
                                                current: CanvasFocusColumns.collapsed))
    }

    func test_theRoundTripIsLossless() throws {
        let before = CanvasColumnStash(showInspector: true, columnVisibility: .all)
        let collapse = try XCTUnwrap(
            CanvasFocusColumns.resolve(isCanvasFocus: true, stash: nil, current: before))
        let restore = try XCTUnwrap(
            CanvasFocusColumns.resolve(isCanvasFocus: false,
                                       stash: collapse.stash,
                                       current: collapse.apply))
        XCTAssertEqual(restore.apply, before)
    }
}
```

`MaughamTests/PersonaModifierTests.swift` — rename the three existing `clearsPaletteStash` tests to `clearsColumnStash` (the assertions are unchanged; only the symbol moves) and add two:

```swift
    /// The canvas column stash (spec §8A.3) inherits the palette stash's exact
    /// ordering hazard, so it is covered by the SAME predicate rather than by a
    /// second one — a second predicate is a second thing to forget.
    func test_clearsColumnStash_whenAPersonaChangeLeavesTheCanvas() {
        let change = PersonaModifier.applyPersonaChange(
            to: .author, from: .plan, currentSegment: .inspector,
            currentBinderSegment: .canvas, projectType: .novel,
            memory: .empty)
        XCTAssertNotEqual(change.binderSegment, .canvas)
        XCTAssertTrue(PersonaModifier.clearsColumnStash(
            from: .canvas, to: change.binderSegment))
    }

    func test_clearsColumnStash_isFalseWhenTheCanvasSurvives() {
        // Plan REMEMBERS the canvas, so the binder stays put — nothing to clear,
        // and the exit arm never fires anyway.
        let change = PersonaModifier.applyPersonaChange(
            to: .plan, from: .author, currentSegment: .inspector,
            currentBinderSegment: .canvas, projectType: .novel,
            memory: PersonaMemory(binder: ["plan": .canvas]))
        XCTAssertEqual(change.binderSegment, .canvas)
        XCTAssertFalse(PersonaModifier.clearsColumnStash(
            from: .canvas, to: change.binderSegment))
    }

    func test_bothStashOwningSegmentsAreCovered() {
        XCTAssertEqual(PersonaModifier.columnStashingSegments, [.palette, .canvas])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasFocusColumnsTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasFocusColumns' in scope`.

- [ ] **Step 3: Write the rule**

`Maugham/Canvas/CanvasFocusColumns.swift`:

```swift
import SwiftUI

/// The two side columns' visibility, captured on entering canvas focus mode so
/// leaving restores exactly what the writer had — including "the inspector was
/// already closed", which is why this is a stash rather than a boolean.
struct CanvasColumnStash: Equatable {
    var showInspector: Bool
    var columnVisibility: NavigationSplitViewVisibility
}

/// Spec §8A.3. `⌘\` already hides the titlebar, traffic lights, persona bar and
/// status footer; ON THE CANVAS it additionally collapses both side columns.
/// Reusing the key extends muscle memory the writer already has, and the exit is
/// the key they already know.
///
/// **Deliberate, never automatic on entering the persona.** Auto-collapsing
/// would fight §8A.1: you need the binder open to drag research across, and only
/// then do you want it gone. The palette wall DOES hide the inspector on entry
/// (`PaletteSegmentModifier`); the canvas declines that precedent on purpose.
enum CanvasFocusColumns {
    /// `.doubleColumn` in a three-column split means content + detail: the
    /// sidebar is the one that goes. The inspector goes via `showInspector`,
    /// which `ProjectWindow.detailColumn` already gates on.
    static let collapsed = CanvasColumnStash(showInspector: false,
                                             columnVisibility: .doubleColumn)

    static func isCanvasFocus(isNoChromeOn: Bool, segment: BinderSegment) -> Bool {
        isNoChromeOn && segment == .canvas
    }

    /// The whole rule, pure — so the ordering hazard is testable without SwiftUI.
    ///
    /// Returns `nil` for "nothing to do". That matters: the caller observes ONE
    /// derived value, so a repeat in either direction is possible, and a second
    /// collapse that re-stashed would capture the already-collapsed state and
    /// strand both columns hidden. Inert, not destructive.
    static func resolve(isCanvasFocus: Bool,
                        stash: CanvasColumnStash?,
                        current: CanvasColumnStash)
        -> (stash: CanvasColumnStash?, apply: CanvasColumnStash)? {
        if isCanvasFocus {
            guard stash == nil else { return nil }
            return (stash: current, apply: collapsed)
        } else {
            guard let stash else { return nil }
            return (stash: nil, apply: stash)
        }
    }
}
```

- [ ] **Step 4: Buy back the expressions, then spend one**

`Maugham/Views/ProjectWindow.swift`, in the private-modifier section beside `PaletteSegmentModifier`:

```swift
/// The save-flash and MCP-note overlays, pulled off the split view.
///
/// `ProjectWindow.body` is at the SwiftUI type-checker ceiling — eleven
/// extracted `ViewModifier`s exist solely to buy expressions back, and the
/// ceiling has been hit twice, once passing Debug and failing Release CI. This
/// task spends one expression on `columnVisibility:`, so it gives three back
/// first.
private struct ProjectOverlaysModifier: ViewModifier {
    @Binding var showingSaveFlash: Bool
    let mcpBanner: MCPBannerModel
    let onShowLatestMCPNote: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                SaveFlashOverlay(isShowing: $showingSaveFlash)
            }
            .overlay(alignment: .top) {
                if let title = mcpBanner.title {
                    MCPNoteBanner(
                        title: title,
                        count: mcpBanner.count,
                        onShow: onShowLatestMCPNote,
                        onDismiss: { mcpBanner.dismiss() }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: mcpBanner.title)
    }
}

/// Spec §8A.3's toggle, kept out of `ProjectWindow.body` for the same budget.
///
/// ONE `.onChange`, on ONE derived value. Observing `isNoChromeOn` and
/// `binderSegment` separately would fire twice for a single ⌘\-on-canvas and the
/// second pass would read a stash the first had just written — and tripwire 2
/// forbids papering over that with a flag, because `.onChange` fires after the
/// synchronous flag-clear and the guard leaks.
///
/// The persona-switch collision is handled at the OTHER end:
/// `PersonaModifier.clearsColumnStash` drops the stash in the persona handler,
/// so this modifier's later pass finds nothing to restore and leaves the
/// force-open alone. Same shape as the palette stash, same predicate.
private struct CanvasFocusColumnsModifier: ViewModifier {
    let isNoChromeOn: Bool
    let binderSegment: BinderSegment
    @Binding var showInspector: Bool
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var stash: CanvasColumnStash?

    private var isCanvasFocus: Bool {
        CanvasFocusColumns.isCanvasFocus(isNoChromeOn: isNoChromeOn, segment: binderSegment)
    }

    func body(content: Content) -> some View {
        content.onChange(of: isCanvasFocus) { _, focused in
            guard let step = CanvasFocusColumns.resolve(
                isCanvasFocus: focused,
                stash: stash,
                current: CanvasColumnStash(showInspector: showInspector,
                                           columnVisibility: columnVisibility))
            else { return }
            stash = step.stash
            showInspector = step.apply.showInspector
            columnVisibility = step.apply.columnVisibility
        }
    }
}
```

Two `@State` properties beside `inspectorWasVisibleBeforePalette` (stored properties, not body expressions — free):

```swift
    /// The leading column's visibility. `.doubleColumn` collapses the sidebar in
    /// a three-column split; `ProjectWindow.detailColumn` already gates the
    /// trailing one on `showInspector`.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Both columns' visibility captured on entering canvas focus mode (spec
    /// §8A.3). Dropped rather than restored on a persona switch — see
    /// `PersonaModifier.clearsColumnStash`.
    @State private var canvasColumnStash: CanvasColumnStash?
```

In `body`, replace the two `.overlay` blocks and the `.animation` line chained on the `NavigationSplitView` with one modifier, and add the initialiser argument:

```swift
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    binderColumn(store: store)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } content: {
                    contentColumn(store: store, documentStore: documentStore)
                } detail: {
                    detailColumn(store: store, documentStore: documentStore)
                }
                .modifier(ProjectOverlaysModifier(
                    showingSaveFlash: $showingSaveFlash,
                    mcpBanner: mcpBanner,
                    onShowLatestMCPNote: { handleShowLatestMCPNote() }))
                .navigationTitle(store.manifest.title)
```

and add one modifier to the outer chain, beside `PaletteSegmentModifier`:

```swift
        .modifier(CanvasFocusColumnsModifier(
            isNoChromeOn: isNoChromeOn,
            binderSegment: binderSegment,
            showInspector: $showInspector,
            columnVisibility: $columnVisibility,
            stash: $canvasColumnStash))
```

- [ ] **Step 5: Extend the predicate**

In `PersonaModifier`, replace `clearsPaletteStash` — the doc comment is rewritten to cover both owners rather than duplicated:

```swift
    /// Binder segments that own a stash of side-column visibility:
    /// `PaletteSegmentModifier`'s pre-palette inspector stash, and
    /// `CanvasFocusColumnsModifier`'s two-column stash (spec §8A.3).
    static let columnStashingSegments: Set<BinderSegment> = [.palette, .canvas]

    /// True when a persona change moves the binder OFF a segment that owns a
    /// column stash — the case where that stash must be DROPPED rather than
    /// restored.
    ///
    /// Both owners run their `.onChange(of:)` in a LATER update pass than this
    /// handler, so their exit arms would restore stashed visibility *over* the
    /// force-open below and land the writer in the new persona with a closed
    /// column — unlike every other persona-switch path. Clearing the stash here,
    /// rather than deferring the force-open by a pass, makes those arms no-op
    /// restores without depending on SwiftUI pass ordering, which is the
    /// fragility tripwire 2 is about.
    ///
    /// EXTENDED for the canvas rather than duplicated. Dropping the palette
    /// stash while leaving the canvas is a no-op — it is non-nil only while the
    /// binder is on `.palette` — so one predicate covering both is strictly
    /// safer than two that can fall out of step.
    static func clearsColumnStash(from current: BinderSegment,
                                  to next: BinderSegment) -> Bool {
        columnStashingSegments.contains(current) && current != next
    }
```

Two new bindings on the modifier:

```swift
    @Binding var columnVisibility: NavigationSplitViewVisibility
    /// `CanvasFocusColumnsModifier`'s stash. Written here only to DROP it.
    @Binding var canvasColumnStash: CanvasColumnStash?
```

and in the `.maughamSetPersona` handler, the clear and the force-open:

```swift
                if Self.clearsColumnStash(from: binderSegment, to: change.binderSegment) {
                    inspectorWasVisibleBeforePalette = nil
                    canvasColumnStash = nil
                }
                persona = change.persona
                detailSegment = change.segment
                binderSegment = change.binderSegment
                showInspector = true
                // BOTH columns. Without this, a writer leaving canvas focus mode
                // by pressing ⌘2 lands in the new persona with the sidebar still
                // collapsed and no obvious way back — the stash that would have
                // restored it was just dropped, correctly, by the line above.
                columnVisibility = .all
```

and the call site in `body` gains the two bindings:

```swift
        .modifier(PersonaModifier(persona: $persona,
                                  detailSegment: $detailSegment,
                                  binderSegment: $binderSegment,
                                  showInspector: $showInspector,
                                  inspectorWasVisibleBeforePalette: $inspectorWasVisibleBeforePalette,
                                  columnVisibility: $columnVisibility,
                                  canvasColumnStash: $canvasColumnStash,
                                  window: window,
                                  documentStore: documentStore,
                                  projectType: store?.manifest.type ?? .novel))
```

- [ ] **Step 6: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasFocusColumnsTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 9 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PersonaModifierTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, including the three renamed tests and the three new ones.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. **This is the gate that matters for this task.** If it fails with `the compiler is unable to type-check this expression in reasonable time`, `body` went over its ceiling: extract another chained modifier into a `ViewModifier` — do not delete the `columnVisibility:` argument, which is the feature.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasFocusColumns.swift Maugham/Views/ProjectWindow.swift \
        MaughamTests/Canvas/CanvasFocusColumnsTests.swift \
        MaughamTests/PersonaModifierTests.swift
git commit -m "feat(canvas): ⌘\\ collapses both side columns on the canvas (spec 8A.3)

Reuses the focus-mode key rather than adding one, and is a deliberate
toggle rather than automatic on entering the persona — auto-collapsing
would fight the drag-in route, since you need the binder open to pull
research across and only then want it gone.

The ordering hazard is the palette stash's, exactly: PaletteSegmentModifier's
.onChange fires in a LATER pass than the persona handler and would restore
a stale stash over the force-open. So clearsPaletteStash is GENERALISED to
clearsColumnStash over {palette, canvas} rather than copied — a second
predicate is a second thing to forget — and the persona handler now
force-opens both columns, or ⌘2 out of canvas focus mode strands the
sidebar. One .onChange on one derived value, and resolve() returns nil for
'nothing to do' so a repeat is inert rather than destructive (tripwire 2).

Body budget: three chained expressions bought back into
ProjectOverlaysModifier before one initialiser argument is spent, so the
net is one cheaper than before."
```

---

### Task 8: Docs, AREA.md and the ADR amendment

**Files:**
- Modify: `Maugham/Canvas/AREA.md`
- Modify: `docs/adr/0026-planning-canvas-rendering.md`
- Modify: `docs/guide/research.md`
- Modify: the guide topic 1C-a's Task 17 gave the canvas (locate it: `grep -rln -i "canvas" docs/guide/`)
- Modify: `docs/roadmap.md`, `docs/problem-map.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- **Consumes:** every symbol built in Tasks 1–7. No new Swift.
- **Produces:** documentation only.

Two standing rules apply. **Rule 7:** help and docs describe what *ships*, not what is planned — 1C-a's Task 17 explicitly wrote a guide that "says nothing about dragging research in, which is 1C-d", and that sentence is now false, so it is this task's job to make it true again. **Rule 10:** when a roadmap item flips •→✓, sweep sibling docs for now-false claims **in the same commit**.

- [ ] **Step 1: `Maugham/Canvas/AREA.md`**

Append a section covering, each in one or two sentences:

- **Item nodes hold a reference and a position, nothing else.** Title, glyph, path and "is there a picture" are resolved from `manifest.research` by `CanvasItemResolver` on `.task(id: store.manifest.modified)` — never in `body` (tripwire 4), never persisted. A rename in the research tree therefore needs no migration.
- **A dashed border means the reference no longer resolves.** It used to mean "1C-a has not built this yet"; it does not any more, and a future reader will otherwise assume the old meaning.
- **`CanvasImageCache` is keyed by PATH, never by id — tripwire 22.** State the bound with its arithmetic: `thumbnailMaxPixelSize = 512`, so a worst-case thumbnail is 512 × 512 × 4 = 1 MiB, and the 48 MiB budget holds 48 of them. State the one exception: an entry larger than the whole budget is kept rather than re-decoded forever.
- **Never `PaletteWallView.downscaled`, and never `.dropDestination(for: URL.self)`.** One decodes at full size and then shrinks; the other silently rejects browser image drags. Both are grep-guarded (`CanvasExternalDropTests`) and both are easy to reach for.
- **The canvas moves and deletes nothing on disk.** `CanvasNodeRemovalTests.test_nothingInTheCanvasAreaMovesOrDeletesUserContent` is the enforcement; if a future feature genuinely needs to, it routes through the typed `DocumentStore` mover (tripwire 14) and adds an exemption with a reason.
- **The residual scale risk, stated rather than buried.** `reloadItemContent` decodes every item node's thumbnail on the load pass, yielding between decodes. That is a first-paint cost, off `body`, once per manifest change, and the path-keyed cache means re-entering the persona re-uses it. If a writer ever puts several hundred photographs on one canvas, this is where it will show, and the fix is viewport-scoped decoding — deliberately not built here, because the bound is known and the cost is one-off.
- **`⌘\` on the canvas collapses both side columns**, why it is not automatic (§8A.3, and the divergence from `PaletteSegmentModifier` is deliberate), and that the stash is dropped — not restored — by `PersonaModifier.clearsColumnStash`.

- [ ] **Step 2: `docs/adr/0026-planning-canvas-rendering.md`**

Amend rather than adding an ADR number. 1C-a's Task 17 Step 7 recorded item nodes as a *slice* boundary and listed what 1C-d owes: "the drop target, `DropClassification` for browser drags, a `CGImageSource` thumbnail path and a bounded cache keyed by path (tripwire 22)". Close it out:

- Mark that debt discharged, naming each piece.
- Record the decision that **an external drop becomes a research asset first and a node second**, with the two rejected alternatives and why (a `.maugham/`-owned image store makes the sidecar non-derived, contradicting §8; a node pointing at `~/Downloads` breaks when the writer tidies up).
- Record that **presentation is resolved, never stored**, and that this is why the sidecar schema did not change.
- Record that **`clearsPaletteStash` became `clearsColumnStash`** and why the predicate was extended rather than duplicated — this is the third recurrence of the same later-pass ordering hazard and the ADR is where the next reader will look for it.

- [ ] **Step 3: `docs/guide/research.md`**

Add a short section — what ships, in the writer's language:

- Drag any research item onto the canvas; it appears as a card. The file is not moved or copied, and removing the card does not delete anything.
- Drop a photo from Finder or drag one out of a browser onto the canvas: it is filed into Research (at the top level, so file it wherever you like afterwards) and appears as a card at the same time.
- Dropping onto a region puts the item in that region.
- ⌫ removes the selected card from the canvas.

- [ ] **Step 4: the canvas guide topic**

`grep -rln -i "canvas" docs/guide/` finds the topic 1C-a's Task 17 wrote. Two edits:

- Remove or rewrite the sentence saying the canvas holds only scraps — it is now false.
- Add: `⌘\` gives the canvas the whole window, and the same key brings the columns back.

If the topic is a **new** slug, `docs/guide/index.json` already carries it and no index edit is needed; confirm with `grep -n canvas docs/guide/index.json` rather than assuming either way.

- [ ] **Step 5: `docs/roadmap.md` and `docs/problem-map.md`**

Flip the canvas item's status where 1C-a/1C-b left it partial, and sweep both files for any line still describing the canvas as scraps-only. Spec §8A.1's boundary sentence — *"images are in scope for this milestone, not deferred past it… no plan may cite this section as authorising their omission"* — is satisfied by this slice; if either doc carries a "images later" note, it goes.

- [ ] **Step 6: `CLAUDE.md`**

One line in the per-area pointer table's `Maugham/Canvas/` row (1C-a Task 17 creates the row): item nodes resolve their presentation from the manifest and never persist it; the image cache is bounded and **keyed by path, not id**. No new tripwire number — this is tripwire 22 recurring, and adding a 25th row for the same rule is how a tripwire table stops being read.

- [ ] **Step 7: Verify the docs claim only what ships**

```bash
grep -rn -i "scrap" docs/guide/ | grep -i "only"
grep -rn -i "1C-d\|not yet\|coming\|planned" Maugham/Canvas/AREA.md docs/guide/
```

Expected: nothing describing the canvas as scraps-only, and no forward-looking claim in a shipping doc (rule 7).

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas/AREA.md docs/adr/0026-planning-canvas-rendering.md \
        docs/guide/ docs/roadmap.md docs/problem-map.md CLAUDE.md
git commit -m "docs(canvas): items, images and drag-in — 1C-a's recorded debt discharged

1C-a's ADR listed what this slice owed: the drop target, DropClassification
for browser drags, a CGImageSource thumbnail path and a bounded cache keyed
by path. Each is named as delivered.

Records the decision that an external drop becomes a research asset first
and a node second, with both rejected alternatives; that presentation is
resolved rather than stored, which is why the sidecar schema did not
change; and that clearsPaletteStash became clearsColumnStash because this
is the third recurrence of the same later-pass ordering hazard.

Rule 7: the guide now describes drag-in and ⌘\\ because they ship, and no
longer says the canvas holds only scraps."
```

---

## Whole-slice verification

Run after Task 8, before the branch is offered for review. Per CLAUDE.md rule 9, a **whole-branch review** follows: per-task reviews cannot see emergent interactions, and the two most recent milestones each had one caught only at that stage (T5×T6 in unified-undo; one emergent bug in hardening).

- [ ] **Both schemes green.**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
  -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
```

The phone scheme must be green **and untouched**: this slice adds no file under `Packages/MaughamCore` or `MaughamPhone` (spec §9). Confirm with `git diff --stat main -- Packages MaughamPhone`, which must print nothing.

- [ ] **Release build.**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```

- [ ] **No generated project in the diff.**

```bash
git diff --stat main -- Maugham.xcodeproj
```

Expected: nothing. A `project.pbxproj` in a diff is a red flag.

- [ ] **The four grep guards actually ran.** `-only-testing MaughamTests/CanvasExternalDropTests MaughamTests/CanvasNodeRemovalTests MaughamTests/TripwireGrepTests` and confirm a non-zero test count in the output. A folder path, or a class name that does not exist, runs **zero** tests and reports success.

- [ ] **Smoke, by hand.** The seams no test can reach:

1. Plan persona → drag a research note from the binder onto the canvas → it lands where the pointer was, with the note's real title and its binder glyph.
2. Rename that note in the binder → the card's title follows.
3. Drag an image research item on → the thumbnail appears, right way up, not stretched. Zoom to maximum — it should not turn to mush (that is what `thumbnailMaxPixelSize = 512` buys).
4. Drag a photo from Finder onto the canvas → it appears in Research at the top level **and** as a card. Then drag an image **out of a browser window** — this is the one `.dropDestination(for: URL.self)` would silently swallow.
5. Drop something inside a region → it joins; drag the region → it travels.
6. Select a card, press ⌫ → the card goes, the file is still in Research. ⌘Z → the card comes back where it was.
7. Drop the same note twice → one card, moved, not two.
8. Delete a note from Research that a card points at → the card stays and reads as unresolved, naming the reference.
9. ⌘\ on the canvas → both columns collapse. ⌘\ again → both return, and the inspector returns to whatever it was, including closed.
10. ⌘\ on the canvas, then ⌘2 → the Author persona opens with **both** columns visible. Then ⌘1 back to Plan and ⌘\ twice — the columns must still restore correctly, which is the ordering hazard.
11. Quit with a card mid-drag-in and relaunch → the canvas is as it was.

- [ ] **MCP dev-app pre-smoke** (the commonmark-fountain lesson: a dev-app MCP pass caught a defect after every test was green). With the dev app running, `mcp__maugham_test__list_research` on the smoke project and confirm that an image dropped on the canvas appears in the research tree with a sane title and path — i.e. that the external-drop route really did file it rather than referencing a temp PNG.

- [ ] **Whole-branch review** (rule 9), with the reviewer pointed at the full diff and told to run the suite rather than read it (hardening-milestone lesson: reviewers-that-run beat reviewers-that-read).
