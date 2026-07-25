# Planning canvas 1C-c — lines, promotion and the MCP canvas surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A writer can draw a line between two cards and label it; can promote a scrap, a region or a line into a durable artifact through one previewable verb; and Claude can read the canvas and — from a photograph the writer drew on paper — add scraps to it that are visibly marked as Claude's and visibly tied to the image they came from.

**Architecture:** Lines are untyped, optionally labelled, stored in the sidecar, and assert nothing. Promotion is one verb with a preview: the writer sees exactly what will be produced and where, before committing, and may decline every suggestion. The MCP surface is one read tool and one write tool; the write tool cannot create a derived node without also placing its source image beside it inside a region, so a derived node's origin is never unrecoverable.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest. Builds directly on 1C-a (the surface) and 1C-b (regions). No MaughamCore change, no phone change.

## Global Constraints

Everything in 1C-a's and 1C-b's Global Constraints still applies. In addition:

- **The governing rule of the whole milestone** (spec §1): *nothing on the canvas becomes durable except by an explicit act the writer performs and can predict the outcome of.*
- **No typed edge vocabulary** (spec §5, §9). Kinopio built exactly that, shipped it for years, and removed it in April 2026 because "connection types were confusing for people I observed using the tool for the first time". Untyped edges with an optional free-text label is the empirically supported floor. `CanvasLine` has no `kind` and must not gain one.
- **No automatic linking** (spec §6.1). Promotion may *suggest* and must never impose. Every offer defaults to declined.
- **Promotion is never required.** The canvas must be completely usable by a writer who never promotes anything.
- **Promotion is allowed to be lossy, and that is a feature** (spec §6.1). Promoting a region need not preserve its lines or its layout — but it must *say* what it drops.
- **Precedence is stated in the UI, once, plainly** (spec §5): wiki-links are durable, canvas lines are scratch. It lives in the promotion sheet's footer, where the writer meets it exactly when the distinction matters.
- **Claude-created nodes are visibly marked** (spec §8A.2 constraint 1), reusing `AnnotationAuthor.SourceKind` — the annotation layer's existing provenance shape — rather than inventing a second one.
- **Must-not #1's reproduction corollary applies in full** (spec §8A.2 constraint 2, `docs/constitution.md` "Corollary: reproduction is not a license to author"). *"The reproduction and its source must be checkable side by side."* So the write tool places the source image node and every derived scrap in one region, in one act. **There is no code path by which Claude creates a loose derived node.**
- `./gen.sh` after adding ANY new file. Run `xcodebuild` in the **foreground**. Never commit anything under `Maugham.xcodeproj/`.
- `-only-testing` takes `MaughamTests/<ClassName>` — **never a folder path**. A folder path silently runs zero tests and reports success.
- **`./gen.sh &&` leads every Step 2** in this plan. New test files are not in the generated project until `gen.sh` runs, so without it the RED step fails to compile the *target* rather than failing for the stated reason.
- **Release build after anything touching a view.** Tasks 3, 6 and 8 touch views.
- **Zero `ProjectWindow.body` expression budget.** This slice adds **no** line to `body`. It adds one line to `ProjectWindow.load()` (a method) and one argument to the existing `CanvasView(...)` call inside `existingEditorSwitch`'s `.canvas` arm (still one expression).
- **Tripwire 21:** no raw `NotificationCenter.default.post(` without `// adr-0021-ok:` on the line the call starts. The post pattern is unconditional and scans `MaughamTests/` too. This slice adds one notification name and posts it through `MaughamEvent.post`, which is the sanctioned wrapper.
- **Tripwire 20 / ADR 0018:** any `String(contentsOf:` in this slice reads a *research note*, not a manuscript, and every such line carries `// adr-0018-ok: research note` on the line the read starts.
- **Tripwire 14:** promotion **creates** and never moves or deletes user content, so the typed `DocumentStore` mover is not on this path. It must still create through `ProjectStore`'s existing APIs rather than writing files directly, or the manifest and the disk diverge. No `moveItem` / `moveToTrash` appears anywhere in this slice.

## Cross-plan API verification — do this before Task 1

The previous draft of this plan failed review because it invented APIs. Every symbol below was checked against the definition named. **1C-a's "Cross-plan contract" section is the authority for 1C-a's spellings**, and where 1C-b's Interfaces block disagrees with 1C-a, 1C-a wins.

Run this first and reconcile anything that does not match:

```bash
grep -n "struct CanvasNode\b\|struct CanvasNodeID\|enum CanvasNodeKind\|struct CanvasScene\|enum CanvasCardMetrics" Maugham/Canvas/CanvasNode.swift Maugham/Canvas/CanvasScene.swift
grep -n "struct .*DTO\|currentSchemaVersion" Maugham/Canvas/CanvasSceneCodec.swift
grep -n "func \|private enum Mode" Maugham/Canvas/CanvasInteraction.swift
grep -n "selectedRegionID\|func withScene\|func setScrapText\|func mutate\|func beginGesture\|func endGesture\|func flush\|func deleteSelectedRegion" Maugham/Canvas/CanvasModel.swift
grep -n "static func draw\|LayerDepth\|static func visibleNodes\|cardTransform" Maugham/Canvas/CanvasRenderer.swift
grep -n "onDeleteKey\|onClick\|onDrag" Maugham/Canvas/CanvasEventView.swift
grep -n "handleClick\|handleDragBegan\|handleDragChanged\|handleDragEnded\|CanvasView(" Maugham/Canvas/CanvasView.swift Maugham/Views/ProjectWindow.swift
```

| Symbol this plan consumes | Verified against | Spelling used here |
|---|---|---|
| `CanvasNodeID` | 1C-a Task 1 Interfaces | `init(_ raw: String)`, `var raw: String`, `static func item(_ referenceId: String) -> CanvasNodeID` (`.item("r-9").raw == "item:r-9"`, pinned by `CanvasSceneTests`) |
| `CanvasNodeKind` | 1C-a Task 1 | `case scrap`, `case item(referenceId: String)` |
| `CanvasNode` | 1C-a Task 1 | `id`, `kind`, `origin: CGPoint`, `width: CGFloat`, `cachedHeight: CGFloat?`, `z: Int`, `var frame: CGRect?`. **`origin` is a `CGPoint` — do not name the new provenance field `origin`.** |
| `CanvasScene` | 1C-a Task 1 + 1C-b Task 2 | `nodes`, `unorderedNodes`, `count`, `node(_:)`, `insert(_:)`, `remove(_:)`, `topmostNode(at:)`, `nodes(intersecting:)`, `topZ`, `regions`, `region(_:)`, `region(at:)`, `insertRegion(_:)`, `removeRegion(_:)`, `updateRegion(_:_:)`, `setRegionFrame(_:for:)` |
| `CanvasRegion` | 1C-b Task 1 | `id`, `label: String`, `frame: CGRect`, `homeMembers: Set<CanvasNodeID>`, `appearances: Set<CanvasNodeID>`, `boundPieceID: String?`, `isCollapsed: Bool` |
| `CanvasMembership` | 1C-b Task 2 | `join(_:home:in:)`, `addAppearance(_:to:in:)`, `leave(_:from:in:)`, `homeRegion(of:in:)` |
| `CanvasModel` | 1C-b Task 4 implementation | `private(set) var scene`, `private(set) var scraps`, `var selectedRegionID`, `var selectedRegion`, `let undoManager`, `load(projectRoot:)`, `flush()`, `withScene(persist:_:)`, `setScrapText(_:for:)`, `beginGesture(_:)`, `endGesture()`, `mutate(_:_:)`, `deleteSelectedRegion()` |
| `CanvasStore` | 1C-a Task 5 (**not** 1C-b's Interfaces block, which is wrong) | `init(projectRoot:)`, `load() -> (scene:scraps:)`, `save(scene:scraps:)`, `scheduleSave(scene:scraps:)`, **`flush()` takes no arguments** |
| `CanvasRenderer` | 1C-a Task 7 + 1C-b Task 5 | `regionLayerDepth`, `nodeLayerDepth`, `seededRotation(for:)`, `cardTransform(inCard:angle:)`, `visibleNodes(in:camera:viewSize:)`. **This plan never changes `draw`'s signature** — see Task 2. |
| `CanvasInteraction` | 1C-a Task 13 + 1C-b Task 6 | `struct` with a `private enum Mode`; `begin(at:in:)`, `beginResize(_:at:in:)`, `update(to:in:)`, `end()`, `endDrag(in:)`, `createScrap(at:in:)`, `createRegion(from:to:in:)`, `regionHit(at:in:)` |
| `CanvasEventNSView.onDeleteKey` | 1C-b Task 6 Step 4 | `var onDeleteKey: (() -> Void)?` |
| `CanvasView` | 1C-b Task 4 Step 4 | `let model: CanvasModel`, `let projectRoot: URL`, `let paletteSwatchHexes: [String]`, plus `@State camera/layouts/editingNodeID/caretIndex/interaction`; private `handleClick(at:)`, `handleDragBegan(from:)`, `handleDragChanged(to:)`, `handleDragEnded(from:to:)` |
| `MCPTool` | `Maugham/MCP/MCPTool.swift` | `static var method`, `static var description`, `static var inputSchemaJSON`, `@MainActor static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data`. **There is no `name` and no `run(projectRoot:)`.** |
| `ProjectStore` | `Maugham/Stores/ProjectStore.swift` | `@MainActor @Observable final class`; `url`, `manifest`, `weak var documentStore: DocumentStore?` |
| research/palette/intent creation | `ProjectStore+Research.swift:120`, `ProjectStore+Palette.swift:51,92`, `ProjectStore+CraftIntent.swift:33` | `addResearchTextNote(parentId:title:) async throws -> ResearchItem`, `addPaletteCard(title:kind:) async throws -> ResearchItem`, `updatePaletteCard(_:) async throws`, `createCraftIntent(forPieceId:) async throws -> ResearchItem` — **all `async throws` on a `@MainActor` type** |
| body-write pattern | `Maugham/MCP/Tools/AddNoteTool.swift:44-61` | create → `try? await store.documentStore?.flushPendingSave()` → write body. The flush is not optional; it is the tripwire-14 research-note race fix. |
| `AnnotationAuthor.SourceKind` | `Packages/MaughamCore/Sources/MaughamCore/SpanAnchor.swift:22` | `enum SourceKind: String, Codable, Equatable, Sendable { case claude; case human }` |
| `RegionInspector.PieceChoice` | 1C-b Task 7 Interfaces | nested `struct PieceChoice: Identifiable, Hashable` with `id: String`, `title: String` |
| `RegionBinding` | 1C-b Task 7 Interfaces | `bind(_:toPiece:in:)`, `unbind(_:in:)`, `references(forPiece:in:)`, `boundPiece(of:in:)` |
| `MCPResponseBudget` | `Maugham/MCP/MCPResponseBudget.swift:29,39` | `static let maxTextBytes = 900_000`, `static func enforce(_ payload: Data, hint: String) throws -> Data` |

**There is no `TestProjectFixture` in this codebase.** The house pattern is a per-file `private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry)`, copied into each test file — see `MaughamTests/MCP/Tools/AddNoteToolTests.swift:19-41`. The only shared fixture is `OpenTestProjectFixture` in `MaughamTests/MCP/Test/`, which is for the dev-only `test_` tools. Every task below that needs a project repeats the helper in its own file, in full.

## Three decisions this plan makes, and why

**1. `.wikiLink` promotion requires both ends to be already-promoted scraps.** Spec §6 says a line produces "a `[[wiki-link]]`, when both ends are text", and §5 calls wiki-links "the durable relationship layer". `ProjectStore.resolveDocumentId(forTitle:)` resolves a wiki title against the manifest, and `ListAllLinksTool` indexes documents *and* research items by title — a scrap is in neither, so a link naming a scrap resolves to nothing. Writing one would manufacture a durable-looking relationship between two things that do not durably exist, which is precisely the "manufactures precision the writer never claimed" failure §6.1 forbids. So a line offers `.wikiLink` only when **both** of its endpoint scraps carry a `promotedItemID`, and the link is appended to the `from` end's promoted note. When they do not, the sheet says so plainly — *"Promote both cards first; a canvas line is scratch."* — which is the precedence rule taught at the exact moment it bites.

**2. The promotion gesture is a menu command on the current selection, ⌘⇧↩, and there is no artifact rail.** Spec §10 left the gesture open. A rail is permanent chrome on a surface whose whole feel is open space (§7). A context menu needs a right-click path through `CanvasEventNSView` and an `NSMenu` pop, which is real machinery for a v1 affordance. A menu command is discoverable in the menu bar with its shortcut printed beside it, costs no chrome, and needs no new event plumbing beyond one notification name. **⌘⇧P is already taken** — `MaughamApp.swift:208` binds it to "Toggle Research Preview" — so this plan uses **⌘⇧↩**, which is free and reads as *commit this*, matching the Scrivener precedent §6.1 names. **Flag for smoke:** if the command feels undiscoverable, a right-click context action is the fallback, and that is a UI change, not a model change.

**3. The MCP write surface is one tool, and the region is derived, never addressed.** Spec §10 asks "one tool or several, and how a region is addressed when Claude groups a photo with what it read". One tool: `add_canvas_scraps`. The region is **not a parameter** — the tool creates it, places the source image node and every derived scrap inside it as residents, and returns its id. Claude cannot choose to put derived nodes somewhere else, because the parameter that would let it does not exist. That is the reproduction corollary enforced by the type signature rather than by good behaviour.

**Residual, stated plainly:** the source node draws as 1C-a's dashed `Item · <referenceId>` placeholder until **1C-d** resolves item thumbnails (spec §8A.1). The *tie* the corollary requires — the source and its derivations in one region, named and navigable — is complete in this slice; the *thumbnail* is 1C-d's, and 1C-d's plan must close it. Do not cite this note as authorising 1C-d's omission from M1C.

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Canvas/CanvasLine.swift` | `CanvasLineID`, `CanvasLine` — two endpoints, an optional label. No type. Plus `CanvasLineHit`. |
| `Maugham/Canvas/CanvasScene.swift` | *Modify* — lines join the scene; `author` / `promotedItemID` mutators |
| `Maugham/Canvas/CanvasNode.swift` | *Modify* — `author`, `promotedItemID` |
| `Maugham/Canvas/CanvasSceneCodec.swift` | *Modify* — schema 2 → 3 |
| `Maugham/Canvas/CanvasRenderer.swift` | *Modify* — draw lines, labels, the pending rubber band, the Claude mark, the promoted mark |
| `Maugham/Canvas/CanvasAccessibility.swift` | *Modify* — the Claude mark reaches VoiceOver |
| `Maugham/Canvas/CanvasInteraction.swift` | *Modify* — the line-drawing drag |
| `Maugham/Canvas/CanvasModel.swift` | *Modify* — line selection, label, delete-selection |
| `Maugham/Canvas/CanvasView.swift` | *Modify* — line gesture routing, the label sheet, the promotion sheet, the ⌘⇧↩ receiver |
| `Maugham/Canvas/LineLabelSheet.swift` | The one-field label editor |
| `Maugham/Canvas/Promotion.swift` | The promotion model: what each source can produce, and the preview |
| `Maugham/Canvas/PromotionPerformer.swift` | `@MainActor` executor against the real project stores |
| `Maugham/Canvas/PromotionSheet.swift` | `PromotionSheetModel` + the sheet |
| `Maugham/Canvas/CanvasClaudeAddition.swift` | The pure scene mutation behind the MCP write tool |
| `Maugham/MCP/Tools/CanvasTools.swift` | `ListCanvasTool`, `AddCanvasScrapsTool` |
| `Maugham/MCP/MCPTool.swift` | *Modify* — two catalog entries |
| `Maugham/Stores/ProjectStore.swift` | *Modify* — `weak var canvasModel: CanvasModel?` |
| `Maugham/Views/ProjectWindow.swift` | *Modify* — one line in `load()`, one argument in the `.canvas` editor arm |
| `Maugham/MaughamApp.swift` | *Modify* — the "Promote…" command |
| `Maugham/Models/MaughamNotifications.swift` | *Modify* — one notification name |

---

### Task 1: Lines, and the two node fields this slice adds

**Files:**
- Create: `Maugham/Canvas/CanvasLine.swift`
- Modify: `Maugham/Canvas/CanvasScene.swift`
- Modify: `Maugham/Canvas/CanvasNode.swift`
- Test: `MaughamTests/Canvas/CanvasLineTests.swift`

**Interfaces:**
- **Consumes:** `CanvasNodeID`, `CanvasNode` (`id`, `kind`, `origin: CGPoint`, `width`, `cachedHeight`, `z`, `frame`), `CanvasScene` (`insert(_:)`, `remove(_:)`, `node(_:)`) — 1C-a Task 1. `AnnotationAuthor.SourceKind` from `MaughamCore` (`case claude`, `case human`).
- **Produces:**
  - `struct CanvasLineID: Hashable, Codable, Sendable` — `init(_ raw: String)`, `var raw: String`.
  - `struct CanvasLine: Equatable, Sendable` — `let id: CanvasLineID`, `var from: CanvasNodeID`, `var to: CanvasNodeID`, `var label: String?`, `func touches(_:) -> Bool`. **No `kind`.**
  - `enum CanvasLineHit` — `static let tolerance: CGFloat`, `static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat`, `static func line(at point: CGPoint, in scene: CanvasScene) -> CanvasLineID?`.
  - On `CanvasNode`: `var author: AnnotationAuthor.SourceKind` (defaulting to `.human`), `var promotedItemID: String?`.
  - On `CanvasScene`: `var lines: [CanvasLine]`, `insertLine(_:)`, `removeLine(_:)`, `updateLine(_:_:)`, `lines(touching:) -> [CanvasLine]`, `endpoints(of:) -> (CGPoint, CGPoint)?`, `setAuthor(_:for:)`, `setPromotedItem(_:for:)`.

**Why `AnnotationAuthor.SourceKind` and not a new enum** (spec §8A.2 constraint 1: *"Reuse the annotation layer's provenance shape rather than inventing one"*): the app already answers "did a human or Claude make this?" exactly once, in `SpanAnchor.swift`, and every annotation surface reads it. A second two-case enum meaning the same thing is how the two answers drift.

**Why the field is `author` and not `origin`:** `CanvasNode.origin` is already the node's `CGPoint`.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasLineTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

final class CanvasLineTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in ["a", "b", "c"].enumerated() {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 400, y: 0), width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        return s
    }

    // MARK: - Lines carry no type (spec §5, §9)

    func test_aLineCarriesNoTypeOnlyAnOptionalLabel() {
        let l = CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b"))
        XCTAssertNil(l.label)
        // The ABSENCE of a kind/type property is the point. Kinopio shipped
        // author-typed connections for years and deleted them in April 2026.
        // If this assertion ever needs changing, re-read spec §5 first.
        XCTAssertEqual(Mirror(reflecting: l).children.compactMap(\.label).sorted(),
                       ["from", "id", "label", "to"])
    }

    func test_labelCanBeSetAndCleared() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.updateLine(CanvasLineID("l1")) { $0.label = "because of the ponchos" }
        XCTAssertEqual(s.lines.first?.label, "because of the ponchos")
        s.updateLine(CanvasLineID("l1")) { $0.label = nil }
        XCTAssertNil(s.lines.first?.label)
    }

    // MARK: - Scene storage

    func test_linesTouchingFindsBothDirections() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("c"), to: CanvasNodeID("a")))
        XCTAssertEqual(Set(s.lines(touching: CanvasNodeID("a")).map(\.id)),
                       [CanvasLineID("l1"), CanvasLineID("l2")])
    }

    func test_linesAreOrderedStablyByID() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("b"), to: CanvasNodeID("c")))
        XCTAssertEqual(s.lines.map(\.id.raw), ["l1", "l2"],
                       "dictionary order must not leak into the draw pass or the sidecar")
    }

    func test_deletingANodeDeletesItsLines() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("b"), to: CanvasNodeID("c")))
        s.remove(CanvasNodeID("a"))
        XCTAssertEqual(s.lines.map(\.id.raw), ["l2"],
                       "a line to a node that is gone would draw into nowhere")
    }

    func test_aSelfLineIsRejected() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("a")))
        XCTAssertTrue(s.lines.isEmpty)
    }

    func test_duplicateLinesBetweenTheSamePairAreAllowed() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "but only at night"))
        XCTAssertEqual(s.lines.count, 2,
                       "a line costs nothing to draw and nothing to be wrong about — two "
                       + "differently-labelled thoughts about one pair are both legitimate")
    }

    // MARK: - Endpoints

    /// Node "a" is (0,0,240,80) → centre (120,40). Node "b" is (400,0,240,80)
    /// → centre (520,40).
    func test_endpointsAreNodeCentres() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        let ends = s.endpoints(of: s.lines[0])
        XCTAssertEqual(ends?.0, CGPoint(x: 120, y: 40))
        XCTAssertEqual(ends?.1, CGPoint(x: 520, y: 40))
    }

    func test_endpointsAreNilWhenAnEndIsUnmeasured() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240))
        var b = CanvasNode(id: CanvasNodeID("b"), kind: .scrap, origin: CGPoint(x: 400, y: 0), width: 240)
        b.cachedHeight = 80
        s.insert(b)
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        XCTAssertNil(s.endpoints(of: s.lines[0]),
                     "drawing to a guessed position would twitch the moment the real "
                     + "measurement arrived")
    }

    // MARK: - Hit testing

    /// Segment (120,40)→(520,40). (300,44) is 4pt off; (300,50) is 10pt off.
    /// Tolerance is 6.
    func test_distanceToSegmentIsPerpendicularInsideTheSpan() {
        XCTAssertEqual(CanvasLineHit.distance(from: CGPoint(x: 300, y: 44),
                                              toSegment: CGPoint(x: 120, y: 40),
                                              CGPoint(x: 520, y: 40)), 4, accuracy: 0.0001)
    }

    /// Beyond an endpoint the nearest point is the endpoint itself, not the
    /// infinite line — otherwise a click a mile past the card selects the line.
    func test_distanceToSegmentClampsAtTheEndpoints() {
        XCTAssertEqual(CanvasLineHit.distance(from: CGPoint(x: 120, y: 140),
                                              toSegment: CGPoint(x: 120, y: 40),
                                              CGPoint(x: 520, y: 40)), 100, accuracy: 0.0001)
        XCTAssertEqual(CanvasLineHit.distance(from: CGPoint(x: 20, y: 40),
                                              toSegment: CGPoint(x: 120, y: 40),
                                              CGPoint(x: 520, y: 40)), 100, accuracy: 0.0001)
    }

    func test_lineAtPointHitsWithinToleranceAndMissesOutside() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        XCTAssertEqual(CanvasLineHit.tolerance, 6)
        XCTAssertEqual(CanvasLineHit.line(at: CGPoint(x: 300, y: 44), in: s), CanvasLineID("l1"))
        XCTAssertNil(CanvasLineHit.line(at: CGPoint(x: 300, y: 50), in: s))
    }

    func test_lineAtPointIgnoresUnmeasuredLines() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240))
        s.insert(CanvasNode(id: CanvasNodeID("b"), kind: .scrap,
                            origin: CGPoint(x: 400, y: 0), width: 240))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        XCTAssertNil(CanvasLineHit.line(at: CGPoint(x: 300, y: 44), in: s),
                     "a line that is not drawn must not be clickable")
    }

    // MARK: - The two node fields

    func test_aFreshNodeIsHumanAuthoredAndUnpromoted() {
        let n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        XCTAssertEqual(n.author, .human)
        XCTAssertNil(n.promotedItemID)
    }

    func test_authorAndPromotedItemRoundTripThroughTheScene() {
        var s = scene()
        s.setAuthor(.claude, for: CanvasNodeID("a"))
        s.setPromotedItem("res-7", for: CanvasNodeID("b"))
        XCTAssertEqual(s.node(CanvasNodeID("a"))?.author, .claude)
        XCTAssertEqual(s.node(CanvasNodeID("b"))?.promotedItemID, "res-7")
        XCTAssertEqual(s.node(CanvasNodeID("a"))?.promotedItemID, nil)
    }

    func test_promotedItemCanBeCleared() {
        var s = scene()
        s.setPromotedItem("res-7", for: CanvasNodeID("a"))
        s.setPromotedItem(nil, for: CanvasNodeID("a"))
        XCTAssertNil(s.node(CanvasNodeID("a"))?.promotedItemID)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLineTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasLine' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/CanvasLine.swift`**

```swift
import Foundation

public struct CanvasLineID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// A freeform line between two nodes.
///
/// **Untyped, deliberately.** There is no `kind` here and there must not be one
/// (spec §5, §9). Kinopio built author-typed connections, shipped them for
/// years, and removed them in April 2026 because "connection types were
/// confusing for people I observed using the tool for the first time". Untyped
/// edges with an optional free-text label is the empirically supported floor.
///
/// A line carries no semantics and asserts nothing. It costs nothing to draw
/// and nothing to be wrong about, which is what thinking needs.
/// `[[wiki-links]]` remain the durable relationship layer, reached deliberately
/// through promotion — and that precedence is stated in the promotion sheet,
/// once, plainly, because Obsidian's three-year confusion is entirely a
/// consequence of never answering "which of these is the real relationship?"
public struct CanvasLine: Equatable, Sendable {
    public let id: CanvasLineID
    public var from: CanvasNodeID
    public var to: CanvasNodeID
    /// Optional free text. Not a type, not a vocabulary, not validated.
    public var label: String?

    public init(id: CanvasLineID, from: CanvasNodeID, to: CanvasNodeID, label: String? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
    }

    public func touches(_ node: CanvasNodeID) -> Bool { from == node || to == node }
}

/// Clicking a line. Kept out of `CanvasScene` so the geometry is a pure
/// function with no scene state to get wrong, and testable against literal
/// arithmetic rather than against itself.
public enum CanvasLineHit {

    /// Pointer slop. A 1.5pt stroke is far too thin to aim at; the target is
    /// deliberately much larger than the ink, for the same reason 1C-a's resize
    /// target is larger than its mark.
    public static let tolerance: CGFloat = 6

    /// Distance from `point` to the SEGMENT `a`–`b`, clamped at both ends.
    /// Clamping matters: without it a click far beyond a card still lands on
    /// the infinite line the segment sits on.
    public static func distance(from point: CGPoint,
                                toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// The nearest line within `tolerance`, or nil. Lines whose endpoints are
    /// unmeasured are skipped — they are not drawn, and an invisible target is
    /// a click the writer cannot explain.
    public static func line(at point: CGPoint, in scene: CanvasScene) -> CanvasLineID? {
        var best: (id: CanvasLineID, distance: CGFloat)?
        for line in scene.lines {
            guard let ends = scene.endpoints(of: line) else { continue }
            let d = distance(from: point, toSegment: ends.0, ends.1)
            guard d <= tolerance else { continue }
            if best == nil || d < best!.distance { best = (line.id, d) }
        }
        return best?.id
    }
}
```

- [ ] **Step 4: Add the two fields to `CanvasNode`**

In `Maugham/Canvas/CanvasNode.swift`, import `MaughamCore` if it is not already imported, and add to `CanvasNode`:

```swift
    /// Who put this node on the canvas. Reuses the annotation layer's
    /// provenance shape (`AnnotationAuthor.SourceKind`) rather than inventing a
    /// second two-case enum meaning the same thing — spec §8A.2 constraint 1
    /// says so explicitly, and two answers to one question drift.
    ///
    /// Claude-authored nodes are drawn with a visible mark (Task 2) and
    /// announced as such to VoiceOver, so the writer can always tell what they
    /// wrote from what was read off a page.
    public var author: AnnotationAuthor.SourceKind = .human

    /// The research item this scrap has already been promoted into, if any.
    /// Nil is the normal state: most of what is on the canvas never becomes
    /// anything, and that is the point (spec §1).
    ///
    /// Two things read it: the drawn "already durable" mark, and
    /// `Promotion.targets`, which offers `.wikiLink` on a line only when both
    /// ends have one — a wiki-link naming a scrap resolves to nothing.
    public var promotedItemID: String?
```

Both are given defaults, so every existing `CanvasNode(...)` call site in 1C-a and 1C-b keeps compiling unchanged. Add them to the memberwise initialiser only if 1C-a wrote an explicit one; if it relies on the synthesised memberwise init, defaults are enough.

- [ ] **Step 5: Extend `CanvasScene`**

```swift
    private var linesByID: [CanvasLineID: CanvasLine] = [:]

    /// Sorted so neither the draw pass nor the sidecar inherits dictionary
    /// order. Line counts are tiny next to node counts, so unlike `nodes` this
    /// is not a per-frame hazard.
    public var lines: [CanvasLine] { linesByID.values.sorted { $0.id.raw < $1.id.raw } }

    public mutating func insertLine(_ line: CanvasLine) {
        // A line from a node to itself has nothing to say and draws as a blob.
        guard line.from != line.to else { return }
        linesByID[line.id] = line
    }

    public mutating func removeLine(_ id: CanvasLineID) { linesByID[id] = nil }

    public mutating func updateLine(_ id: CanvasLineID, _ mutate: (inout CanvasLine) -> Void) {
        guard var line = linesByID[id] else { return }
        mutate(&line)
        linesByID[line.id] = line
    }

    public func lines(touching node: CanvasNodeID) -> [CanvasLine] {
        lines.filter { $0.touches(node) }
    }

    /// Both endpoints in content space, or nil when either end has never been
    /// measured. Endpoints are node CENTRES.
    public func endpoints(of line: CanvasLine) -> (CGPoint, CGPoint)? {
        guard let a = node(line.from)?.frame, let b = node(line.to)?.frame else { return nil }
        return (CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY))
    }

    public mutating func setAuthor(_ author: AnnotationAuthor.SourceKind, for id: CanvasNodeID) {
        mutateNode(id) { $0.author = author }
    }

    public mutating func setPromotedItem(_ itemID: String?, for id: CanvasNodeID) {
        mutateNode(id) { $0.promotedItemID = itemID }
    }
```

`mutateNode(_:_:)` is whatever private per-node mutation helper 1C-a's `setWidth`/`setCachedHeight` already use; reuse it rather than adding a second one. If those two inline their dictionary access instead, inline these the same way.

Extend `remove(_ id: CanvasNodeID)` — which already clears region memberships from 1C-b — with:

```swift
        // A line to a node that is gone would draw into nowhere.
        for lineID in linesByID.keys where linesByID[lineID]?.touches(id) == true {
            linesByID[lineID] = nil
        }
```

`CanvasScene` is `Equatable`; adding a stored dictionary keeps the synthesised conformance, and `CanvasLine` is `Equatable`.

- [ ] **Step 5b: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLineTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 16 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasSceneTests CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasMembershipTests CODE_SIGNING_ALLOWED=NO`
Expected: both still PASS — the scene grew, nothing it already did changed.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasLine.swift Maugham/Canvas/CanvasScene.swift Maugham/Canvas/CanvasNode.swift MaughamTests/Canvas/CanvasLineTests.swift project.yml
git commit -m "feat(canvas): untyped lines with optional labels, plus node authorship and promotion marks

Lines have no kind and must not gain one (spec §5): Kinopio shipped typed
connections for years and deleted them in April 2026. Node authorship reuses
AnnotationAuthor.SourceKind rather than minting a second provenance enum."
```

---

### Task 2: Persist and draw — schema 2 → 3

**Files:**
- Modify: `Maugham/Canvas/CanvasSceneCodec.swift`
- Modify: `Maugham/Canvas/CanvasRenderer.swift`
- Modify: `Maugham/Canvas/CanvasAccessibility.swift`
- Test: `MaughamTests/Canvas/CanvasLinePersistenceTests.swift`

**Interfaces:**
- **Consumes:** `CanvasLine`, `CanvasLineID`, `CanvasScene.insertLine/lines/endpoints(of:)`, `CanvasNode.author/promotedItemID` (Task 1); `CanvasStore` (1C-a Task 5) — `init(projectRoot:)`, `load() -> (scene: CanvasScene, scraps: [CanvasNodeID: String])`, `save(scene:scraps:)`; `CanvasCamera` (1C-a Task 4); `CanvasRenderer.regionLayerDepth`/`nodeLayerDepth` (1C-b Task 5); `CanvasCardMetrics` (1C-a Task 1); `CanvasAccessibility.elements(scene:scraps:)` (1C-a Task 14).
- **Modifies:** `CanvasSceneDTO` — `currentSchemaVersion` 2 → 3, a nested `LineDTO`, `lines: [LineDTO]?`, and two new optional properties on the nested node DTO.
- **Produces on `CanvasRenderer`:** `static let lineLayerDepth: Int`, `struct LineGeometry: Equatable`, `static func lineGeometry(in:) -> [LineGeometry]`, `static func lineLabelBox(for:) -> CGRect`, `static func authorMarkFrame(inCard:) -> CGRect`, `static func promotedMarkFrame(inCard:) -> CGRect`, `static func drawLines(scene:selectedLineID:into:)`, `static func drawPendingLine(from:to:into:)`.

**`CanvasRenderer.draw`'s signature does not change.** 1C-a pins it as `draw(scene:camera:viewSize:layouts:mountedEditorNodeID:straighten:into:)` and 1C-b amends it to add `presentations:`, `scraps:` and `selectedRegionID:`. Lines come off `scene`, which `draw` already has, and the selected line comes off the model, which the *view* already has — so `drawLines` is called from `CanvasView`'s draw closure immediately after `draw`, not threaded through it. Two plans have now disagreed about that signature; this one does not touch it.

**Layer depth constants document the draw order; they do not enforce it.** The order is the order the calls appear in `CanvasView`'s closure. Set `lineLayerDepth` strictly between the two existing constants — if 1C-b left them adjacent, raise `nodeLayerDepth` by one first. `CanvasRegionRenderTests` asserts `regionLayerDepth < nodeLayerDepth`, which survives either way.

**Lines draw above regions and beneath cards.** Above regions because a line into a region's area must not vanish under it; beneath cards because a line's job is to connect cards, and a line crossing over one reads as damage.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasLinePersistenceTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

final class CanvasLinePersistenceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-lines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writeSidecar(_ json: String) throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("canvas.json"),
                       atomically: true, encoding: .utf8)
    }

    /// Node "a" is (0,0,240,80) → centre (120,40); node "b" is (400,0,240,80)
    /// → centre (520,40).
    private func sceneWithALine() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in ["a", "b"].enumerated() {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 400, y: 0), width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "because of the ponchos"))
        return s
    }

    // MARK: - Persistence

    func test_linesRoundTripThroughDisk() {
        CanvasStore(projectRoot: root).save(scene: sceneWithALine(), scraps: [:])
        let loaded = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(loaded.lines.count, 1)
        XCTAssertEqual(loaded.lines.first?.label, "because of the ponchos")
        XCTAssertEqual(loaded.lines.first?.from, CanvasNodeID("a"))
        XCTAssertEqual(loaded.lines.first?.to, CanvasNodeID("b"))
    }

    func test_authorAndPromotedItemRoundTripThroughDisk() {
        var s = sceneWithALine()
        s.setAuthor(.claude, for: CanvasNodeID("a"))
        s.setPromotedItem("res-7", for: CanvasNodeID("b"))
        CanvasStore(projectRoot: root).save(scene: s, scraps: [:])
        let loaded = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(loaded.node(CanvasNodeID("a"))?.author, .claude)
        XCTAssertEqual(loaded.node(CanvasNodeID("b"))?.author, .human)
        XCTAssertEqual(loaded.node(CanvasNodeID("b"))?.promotedItemID, "res-7")
        XCTAssertNil(loaded.node(CanvasNodeID("a"))?.promotedItemID)
    }

    func test_theSchemaVersionIsThree() {
        XCTAssertEqual(CanvasSceneDTO.currentSchemaVersion, 3)
    }

    /// ADR 0015: additive-optional. A schema-2 sidecar written before this
    /// slice must still open, with no lines and every node human-authored.
    func test_aSchemaV2SidecarLoadsWithNoLinesAndHumanAuthors() throws {
        try writeSidecar(#"""
        {"schemaVersion":2,"nodes":[{"id":"a","kind":"scrap","x":0,"y":0,"width":240,"z":0}],"regions":[]}
        """#)
        let loaded = CanvasStore(projectRoot: root).load().scene
        XCTAssertTrue(loaded.lines.isEmpty)
        XCTAssertEqual(loaded.node(CanvasNodeID("a"))?.author, .human)
    }

    /// The same validation regions already do for memberships: an endpoint
    /// naming a node that is not in the file would draw into nowhere.
    func test_aLineNamingAMissingNodeIsDropped() throws {
        try writeSidecar(#"""
        {"schemaVersion":3,"nodes":[],"regions":[],"lines":[{"id":"l1","from":"ghost","to":"also"}]}
        """#)
        XCTAssertTrue(CanvasStore(projectRoot: root).load().scene.lines.isEmpty)
    }

    func test_aSelfLineInTheFileIsDropped() throws {
        try writeSidecar(#"""
        {"schemaVersion":3,"nodes":[{"id":"a","kind":"scrap","x":0,"y":0,"width":240,"z":0}],"regions":[],"lines":[{"id":"l1","from":"a","to":"a"}]}
        """#)
        XCTAssertTrue(CanvasStore(projectRoot: root).load().scene.lines.isEmpty,
                      "insertLine rejects self-lines; the loader must go through it")
    }

    /// ADR 0015 again: an unknown author string must not throw. It degrades to
    /// `.human`, which is the safe direction — a node wrongly marked as the
    /// writer's own is a missing mark, not a false claim about Claude.
    func test_anUnknownAuthorStringDegradesToHuman() throws {
        try writeSidecar(#"""
        {"schemaVersion":3,"nodes":[{"id":"a","kind":"scrap","x":0,"y":0,"width":240,"z":0,"author":"martian"}],"regions":[],"lines":[]}
        """#)
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.node(CanvasNodeID("a"))?.author,
                       .human)
    }

    // MARK: - Geometry

    func test_lineGeometryResolvesToNodeCentres() {
        let g = CanvasRenderer.lineGeometry(in: sceneWithALine())
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.first?.from, CGPoint(x: 120, y: 40))
        XCTAssertEqual(g.first?.to, CGPoint(x: 520, y: 40))
        XCTAssertEqual(g.first?.label, "because of the ponchos")
    }

    func test_linesToUnmeasuredNodesAreNotDrawn() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240))
        s.insert(CanvasNode(id: CanvasNodeID("b"), kind: .scrap,
                            origin: CGPoint(x: 400, y: 0), width: 240))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        XCTAssertTrue(CanvasRenderer.lineGeometry(in: s).isEmpty)
    }

    /// The label box is centred on the segment's midpoint — (320,40) here —
    /// so it stays legible over the ground.
    func test_theLabelBoxIsCentredOnTheLine() {
        let g = CanvasRenderer.lineGeometry(in: sceneWithALine())[0]
        let box = CanvasRenderer.lineLabelBox(for: g)
        XCTAssertEqual(box.midX, 320, accuracy: 0.0001)
        XCTAssertEqual(box.midY, 40, accuracy: 0.0001)
        XCTAssertGreaterThan(box.width, 0)
    }

    func test_theLabelBoxIsEmptyForAnUnlabelledLine() {
        var s = sceneWithALine()
        s.updateLine(CanvasLineID("l1")) { $0.label = nil }
        let g = CanvasRenderer.lineGeometry(in: s)[0]
        XCTAssertTrue(CanvasRenderer.lineLabelBox(for: g).isEmpty,
                      "an unlabelled line must not reserve a pill of empty ground")
    }

    func test_linesDrawAboveRegionsAndBeneathNodes() {
        XCTAssertLessThan(CanvasRenderer.regionLayerDepth, CanvasRenderer.lineLayerDepth)
        XCTAssertLessThan(CanvasRenderer.lineLayerDepth, CanvasRenderer.nodeLayerDepth)
    }

    // MARK: - The two marks

    func test_bothMarksSitInsideTheCardAndDoNotOverlap() {
        let card = CGRect(x: 0, y: 0, width: 240, height: 80)
        let author = CanvasRenderer.authorMarkFrame(inCard: card)
        let promoted = CanvasRenderer.promotedMarkFrame(inCard: card)
        XCTAssertTrue(card.contains(author))
        XCTAssertTrue(card.contains(promoted))
        XCTAssertFalse(author.intersects(promoted),
                       "a node can be both Claude-authored and promoted; the two marks "
                       + "must be separately readable")
    }

    // MARK: - Accessibility (spec §7A.6 — we own the AX tree)

    func test_aClaudeAuthoredScrapAnnouncesItselfAsSuchToVoiceOver() {
        var s = sceneWithALine()
        s.setAuthor(.claude, for: CanvasNodeID("a"))
        let elements = CanvasAccessibility.elements(
            scene: s, scraps: [CanvasNodeID("a"): "The falls at night.",
                               CanvasNodeID("b"): "October's doctor."])
        let a = elements.first { $0.id == CanvasNodeID("a") }
        let b = elements.first { $0.id == CanvasNodeID("b") }
        XCTAssertTrue(a?.label.contains("Claude") == true,
                      "\"visibly marked\" (§8A.2) is not visual-only — a VoiceOver user must "
                      + "also be able to tell what they wrote from what was read off a page")
        XCTAssertFalse(b?.label.contains("Claude") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLinePersistenceTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `type 'CanvasSceneDTO' has no member 'currentSchemaVersion'` is wrong, so expect instead `cannot find 'lineGeometry'`/`value of type 'CanvasSceneDTO' has no member 'lines'`. Any compile failure naming a symbol this task adds is the right red.

- [ ] **Step 3: Extend the codec**

In `Maugham/Canvas/CanvasSceneCodec.swift`. First confirm the nested node DTO's name — 1C-b's peer is `RegionDTO`, so the node one is `NodeDTO` unless `grep -n "struct .*DTO" Maugham/Canvas/CanvasSceneCodec.swift` says otherwise; use whatever it reports and change nothing else in this block.

```swift
    public static let currentSchemaVersion = 3   // was 2 (regions, 1C-b)

    struct LineDTO: Codable {
        let id: String
        let from: String
        let to: String
        let label: String?
    }

    /// Additive-optional (ADR 0015): a schema-2 file has no `lines` key and
    /// decodes to nil, which is an empty canvas's worth of lines.
    var lines: [LineDTO]?
```

On the node DTO, two more additive-optional properties:

```swift
        /// `AnnotationAuthor.SourceKind.rawValue`. Absent — every node written
        /// before this slice — means `.human`.
        let author: String?
        /// The research item this scrap was promoted into, if any.
        let promotedItemID: String?
```

In `init(scene:)`, encode `author` as `node.author == .human ? nil : node.author.rawValue` (so the common case adds no bytes to every node in the file, which is the whole reason `canvas.json` stays small) and `promotedItemID` straight through, then:

```swift
        self.lines = scene.lines.map {
            LineDTO(id: $0.id.raw, from: $0.from.raw, to: $0.to.raw, label: $0.label)
        }
```

In `var scene: CanvasScene`, after nodes and regions are inserted:

```swift
        // Endpoint validation, the same shape regions already apply to
        // memberships: a line naming a node that is not in this file would draw
        // into nowhere. `insertLine` rejects self-lines, so going through it
        // rather than the dictionary is what makes that rule single-sourced.
        for dto in lines ?? [] {
            let from = CanvasNodeID(dto.from)
            let to = CanvasNodeID(dto.to)
            guard built.node(from) != nil, built.node(to) != nil else { continue }
            built.insertLine(CanvasLine(id: CanvasLineID(dto.id), from: from, to: to,
                                        label: dto.label))
        }
```

and where each node is built:

```swift
        // An unrecognised author degrades to .human rather than throwing
        // (ADR 0015). That direction is deliberate: a Claude node that loses
        // its mark understates provenance, whereas defaulting the other way
        // would claim Claude wrote something it did not.
        node.author = dto.author.flatMap(AnnotationAuthor.SourceKind.init(rawValue:)) ?? .human
        node.promotedItemID = dto.promotedItemID
```

(`built` is whatever local the existing `scene` builder already uses; match it.)

- [ ] **Step 4: Extend the renderer**

In `Maugham/Canvas/CanvasRenderer.swift`:

```swift
    /// Above regions (a line into a region's area must not vanish under it),
    /// beneath cards (a line crossing over a card reads as damage). These
    /// constants document the order; the order itself is the sequence of calls
    /// in `CanvasView`'s draw closure.
    static let lineLayerDepth = regionLayerDepth + 1

    static let lineWidth: CGFloat = 1.5
    static let lineOpacity: CGFloat = 0.45
    static let lineLabelPadding: CGFloat = 6
    static let lineLabelHeight: CGFloat = 18
    /// Rough per-character advance for the label pill. The pill is chrome, not
    /// text layout — it never has to agree with a mounted editor, so §7A.2's
    /// same-TextKit-stack rule does not reach it.
    static let lineLabelCharacterWidth: CGFloat = 6.5

    struct LineGeometry: Equatable {
        let id: CanvasLineID
        let from: CGPoint
        let to: CGPoint
        let label: String?
    }

    /// Endpoints resolve to node centres. Nodes that have never been measured
    /// have no frame, so their lines are not drawn — drawing to a guessed
    /// position would twitch as soon as the real measurement arrived.
    static func lineGeometry(in scene: CanvasScene) -> [LineGeometry] {
        scene.lines.compactMap { line in
            guard let ends = scene.endpoints(of: line) else { return nil }
            return LineGeometry(id: line.id, from: ends.0, to: ends.1, label: line.label)
        }
    }

    /// The label pill, centred on the segment's midpoint. Empty when there is
    /// no label — an unlabelled line must not reserve a pill of empty ground.
    static func lineLabelBox(for geometry: LineGeometry) -> CGRect {
        guard let label = geometry.label, !label.isEmpty else { return .zero }
        let width = CGFloat(label.count) * lineLabelCharacterWidth + lineLabelPadding * 2
        let mid = CGPoint(x: (geometry.from.x + geometry.to.x) / 2,
                          y: (geometry.from.y + geometry.to.y) / 2)
        return CGRect(x: mid.x - width / 2, y: mid.y - lineLabelHeight / 2,
                      width: width, height: lineLabelHeight)
    }

    /// Every line in the scene, plus its label pill. Selection draws thicker
    /// and fully opaque rather than in an accent colour: the canvas already
    /// spends its colour budget on the region ring and the palette wash (§7.1).
    static func drawLines(scene: CanvasScene, selectedLineID: CanvasLineID?,
                          into cx: inout GraphicsContext) {
        for geometry in lineGeometry(in: scene) {
            let isSelected = geometry.id == selectedLineID
            var path = Path()
            path.move(to: geometry.from)
            path.addLine(to: geometry.to)
            cx.stroke(path, with: .color(.primary.opacity(isSelected ? 1 : lineOpacity)),
                      lineWidth: isSelected ? lineWidth * 2 : lineWidth)

            let box = lineLabelBox(for: geometry)
            guard !box.isEmpty, let label = geometry.label else { continue }
            cx.fill(Path(roundedRect: box, cornerRadius: lineLabelHeight / 2),
                    with: .color(.primary.opacity(0.08)))
            cx.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
        }
    }

    /// The rubber band shown while a line is being drawn. Dashed, so an
    /// in-progress line never reads as a line that exists.
    static func drawPendingLine(from: CGPoint, to: CGPoint, into cx: inout GraphicsContext) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        cx.stroke(path, with: .color(.primary.opacity(lineOpacity)),
                  style: StrokeStyle(lineWidth: lineWidth, dash: [4, 4]))
    }

    // MARK: - The two card marks

    static let markSide: CGFloat = 7
    static let markInset: CGFloat = 6

    /// Spec §8A.2 constraint 1: Claude-created nodes must be VISIBLY marked, so
    /// the writer can tell at a glance what they wrote from what was read off a
    /// photograph. Top-right, because the top-left is where a card's first line
    /// of text starts.
    static func authorMarkFrame(inCard card: CGRect) -> CGRect {
        CGRect(x: card.maxX - markInset - markSide, y: card.minY + markInset,
               width: markSide, height: markSide)
    }

    /// "Already durable." A node can be both Claude-authored and promoted, so
    /// this sits below the author mark rather than sharing its corner.
    static func promotedMarkFrame(inCard card: CGRect) -> CGRect {
        CGRect(x: card.maxX - markInset - markSide,
               y: card.minY + markInset * 2 + markSide,
               width: markSide, height: markSide)
    }
```

In `drawCard`, after the card's ground and text are drawn, add:

```swift
        if node.author == .claude {
            cx.fill(Path(ellipseIn: authorMarkFrame(inCard: frame)),
                    with: .color(.secondary.opacity(0.55)))
        }
        if node.promotedItemID != nil {
            cx.stroke(Path(ellipseIn: promotedMarkFrame(inCard: frame)),
                      with: .color(.secondary.opacity(0.55)), lineWidth: 1)
        }
```

A filled dot for Claude, a hollow ring for promoted: two marks that are distinguishable without colour, which matters on a surface washed 3–5% by an arbitrary project palette (§7.1).

**Both marks are drawn inside the card's rotated transform**, so they tilt with the card and straighten with it — a mark that stayed level while its card leaned would read as chrome belonging to the canvas rather than to the card.

- [ ] **Step 5: Announce the mark to VoiceOver**

In `Maugham/Canvas/CanvasAccessibility.swift`, where a scrap element's `label` is built, prefix Claude-authored nodes:

```swift
    /// Spec §7A.6 owns this tree, and §8A.2's "visibly marked" is not
    /// visual-only: a VoiceOver user must be able to tell what they wrote from
    /// what was read off a page, and a drawn dot tells them nothing.
    static let claudeAuthoredLabelPrefix = "Read by Claude — "
```

and prepend it when `node.author == .claude`. Do not touch the element list's rebuild trigger: it is keyed on `sceneRevision` (1C-a Task 14), and authorship changes are structural, so they already ride that counter.

- [ ] **Step 6: Call the new draw passes from `CanvasView`**

In `CanvasView`'s `Canvas` closure, immediately **after** the existing `CanvasRenderer.draw(...)` call — do not change that call's arguments:

```swift
                CanvasRenderer.drawLines(scene: model.scene,
                                         selectedLineID: model.selectedLineID,
                                         into: &cx)
                if let pending = interaction.pendingLine {
                    CanvasRenderer.drawPendingLine(from: pending.from, to: pending.to, into: &cx)
                }
```

`model.selectedLineID` and `interaction.pendingLine` arrive in Task 3. **Until Task 3 lands, pass `selectedLineID: nil` and omit the `pendingLine` branch** — Task 3's Step 4 replaces both lines. Committing a draw call that reads a symbol no task has written is the failure mode this plan exists to avoid; this ordering keeps every commit green.

- [ ] **Step 7: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLinePersistenceTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 14 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionCodecTests CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasAccessibilityTests CODE_SIGNING_ALLOWED=NO`
Expected: all PASS. The schema bump and the layer-depth constants are the two things most likely to have moved under them.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas/CanvasLinePersistenceTests.swift
git commit -m "feat(canvas): persist lines and node provenance (schema 2→3), draw lines beneath cards

An unknown author string degrades to .human: a lost mark understates
provenance, the other direction would claim Claude wrote what it did not."
```

---

### Task 3: Drawing a line — the gesture, selection, the label, delete

**Files:**
- Modify: `Maugham/Canvas/CanvasInteraction.swift`
- Modify: `Maugham/Canvas/CanvasModel.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Create: `Maugham/Canvas/LineLabelSheet.swift`
- Test: `MaughamTests/Canvas/CanvasLineInteractionTests.swift`

**This is the task the previous draft did not have.** That draft modelled, persisted, codec'd and drew `CanvasLine`, called `insertLine` only from test fixtures, and then asked the smoke to "draw a line between two scraps → label it" against code no task wrote. **Nothing else in this plan may be started until a writer can draw a line.**

**Interfaces:**
- **Consumes:** `CanvasLine`, `CanvasLineID`, `CanvasLineHit`, `CanvasScene.insertLine/removeLine/updateLine/lines` (Task 1); `CanvasScene.topmostNode(at:)`, `CanvasNode.frame` (1C-a Task 1); `CanvasInteraction` (1C-a Task 13 / 1C-b Task 6) — a `struct` with `private enum Mode`, `private var mode: Mode`, `begin(at:in:)`, `beginRegionDrag(_:at:in:)`, `beginRegionResize(_:at:in:)`, `update(to:in:)`, `end()`, `endDrag(in:)`, `regionHit(at:in:)`, `createRegion(from:to:in:)`; `CanvasModel` (1C-b Task 4) — `scene`, `selectedRegionID`, `withScene(persist:_:)`, `mutate(_:_:)`, `deleteSelectedRegion()`; `CanvasEventNSView.onDeleteKey` (1C-b Task 6).
- **Produces on `CanvasInteraction`:** `struct PendingLine: Equatable { let fromNode: CanvasNodeID; let from: CGPoint; var to: CGPoint }`, `private(set) var pendingLine: PendingLine?`, `mutating func beginLine(from:at:in:)`, `mutating func updateLine(to:)`, `@discardableResult mutating func endLine(at:in:) -> CanvasLineID?`, `static func newLineID(in:) -> CanvasLineID`.
- **Produces on `CanvasModel`:** `var selectedLineID: CanvasLineID?`, `var selectedLine: CanvasLine?`, `func selectLine(_:)`, `func selectRegion(_:)`, `func setLineLabel(_:for:)`, `func deleteSelection()`.
- **Produces:** `struct LineLabelSheet: View` with `static func normalise(_ raw: String) -> String?` and `init(initialLabel: String?, onCommit: @escaping (String?) -> Void, onCancel: @escaping () -> Void)`.

**The gesture is ⇧-drag from one card to another.** ⌥-drag already draws a region (1C-b), and the modifier is read the same way 1C-b reads its own — `NSEvent.modifierFlags` at press time, in a computed property on `CanvasView`, rather than by widening `CanvasEventView`'s callback signature for one Bool. The two plans have disagreed about that signature's arity once already; this task does not touch it. **The ⇧ branch is tested first in `handleDragBegan`**, before the card branch, because a ⇧-drag that starts on a card must draw a line rather than move it.

**Selection is mutually exclusive, and it is enforced in `CanvasModel`, not at the call sites.** Two selected things means two ⌫ targets and an ambiguous "Promote…". `selectLine`/`selectRegion` are the two doors; 1C-b's three `model.selectedRegionID = id` assignments move to `model.selectRegion(id)`. Property observers on an `@Observable` stored property are avoided deliberately — the macro rewrites stored properties into computed ones, and a `didSet` there is exactly the kind of thing that works until it doesn't.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasLineInteractionTests.swift`:

```swift
import XCTest
@testable import Maugham

final class CanvasLineInteractionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-line-gesture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// "a" is (0,0,240,80) → centre (120,40); "b" is (400,0,240,80) → centre
    /// (520,40). A point inside "a" is (10,10); inside "b" is (410,10).
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in ["a", "b"].enumerated() {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 400, y: 0), width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        return s
    }

    private func loadedModel() -> CanvasModel {
        let model = CanvasModel()
        model.load(projectRoot: root)
        model.withScene { $0 = scene() }
        return model
    }

    // MARK: - Drawing

    func test_aDragFromOneCardToAnotherCreatesALine() {
        var s = scene()
        var i = CanvasInteraction()
        i.beginLine(from: CanvasNodeID("a"), at: CGPoint(x: 10, y: 10), in: s)
        i.updateLine(to: CGPoint(x: 300, y: 30))
        let created = i.endLine(at: CGPoint(x: 410, y: 10), in: &s)
        XCTAssertNotNil(created)
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines.first?.from, CanvasNodeID("a"))
        XCTAssertEqual(s.lines.first?.to, CanvasNodeID("b"))
        XCTAssertNil(s.lines.first?.label, "a new line asserts nothing until the writer says so")
    }

    /// The rubber band anchors at the source card's CENTRE, not at the press
    /// point, so the band and the finished line describe the same geometry.
    func test_thePendingLineAnchorsAtTheSourceCentreAndFollowsThePointer() {
        let s = scene()
        var i = CanvasInteraction()
        i.beginLine(from: CanvasNodeID("a"), at: CGPoint(x: 10, y: 10), in: s)
        XCTAssertEqual(i.pendingLine?.from, CGPoint(x: 120, y: 40))
        XCTAssertEqual(i.pendingLine?.to, CGPoint(x: 10, y: 10))
        i.updateLine(to: CGPoint(x: 300, y: 30))
        XCTAssertEqual(i.pendingLine?.to, CGPoint(x: 300, y: 30))
    }

    func test_thePendingLineIsClearedWhenTheDragEnds() {
        var s = scene()
        var i = CanvasInteraction()
        i.beginLine(from: CanvasNodeID("a"), at: CGPoint(x: 10, y: 10), in: s)
        _ = i.endLine(at: CGPoint(x: 410, y: 10), in: &s)
        XCTAssertNil(i.pendingLine)
    }

    func test_aDragEndingOnEmptyCanvasCreatesNothing() {
        var s = scene()
        var i = CanvasInteraction()
        i.beginLine(from: CanvasNodeID("a"), at: CGPoint(x: 10, y: 10), in: s)
        XCTAssertNil(i.endLine(at: CGPoint(x: 2000, y: 2000), in: &s))
        XCTAssertTrue(s.lines.isEmpty, "a line needs two ends; a dangling one is not a thought")
        XCTAssertNil(i.pendingLine)
    }

    func test_aDragEndingOnTheSourceCardCreatesNothing() {
        var s = scene()
        var i = CanvasInteraction()
        i.beginLine(from: CanvasNodeID("a"), at: CGPoint(x: 10, y: 10), in: s)
        XCTAssertNil(i.endLine(at: CGPoint(x: 20, y: 20), in: &s))
        XCTAssertTrue(s.lines.isEmpty)
    }

    func test_endLineWithoutBeginLineDoesNothing() {
        var s = scene()
        var i = CanvasInteraction()
        XCTAssertNil(i.endLine(at: CGPoint(x: 410, y: 10), in: &s))
        XCTAssertTrue(s.lines.isEmpty)
    }

    func test_newLineIDsDoNotCollideWithExistingOnes() {
        var s = scene()
        var i = CanvasInteraction()
        i.beginLine(from: CanvasNodeID("a"), at: CGPoint(x: 10, y: 10), in: s)
        _ = i.endLine(at: CGPoint(x: 410, y: 10), in: &s)
        i.beginLine(from: CanvasNodeID("b"), at: CGPoint(x: 410, y: 10), in: s)
        _ = i.endLine(at: CGPoint(x: 10, y: 10), in: &s)
        XCTAssertEqual(Set(s.lines.map(\.id)).count, 2)
    }

    // MARK: - Selection

    func test_selectingALineClearsTheRegionSelectionAndTheOtherWayRound() {
        let model = loadedModel()
        model.withScene {
            $0.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                         frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
            $0.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                     to: CanvasNodeID("b")))
        }
        model.selectRegion(CanvasRegionID("r1"))
        model.selectLine(CanvasLineID("l1"))
        XCTAssertNil(model.selectedRegionID,
                     "two selected things means two ⌫ targets and an ambiguous Promote")
        XCTAssertEqual(model.selectedLine?.id, CanvasLineID("l1"))

        model.selectRegion(CanvasRegionID("r1"))
        XCTAssertNil(model.selectedLineID)
        XCTAssertEqual(model.selectedRegionID, CanvasRegionID("r1"))
    }

    func test_selectedLineIsNilWhenTheLineIsGone() {
        let model = loadedModel()
        model.withScene {
            $0.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                     to: CanvasNodeID("b")))
        }
        model.selectLine(CanvasLineID("l1"))
        model.mutate("Delete Line") { $0.removeLine(CanvasLineID("l1")) }
        XCTAssertNil(model.selectedLine)
    }

    // MARK: - The label

    func test_settingALabelIsOneUndoStep() {
        let model = loadedModel()
        model.undoManager.groupsByEvent = false
        model.withScene {
            $0.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                     to: CanvasNodeID("b")))
        }
        model.setLineLabel("because of the ponchos", for: CanvasLineID("l1"))
        XCTAssertEqual(model.scene.lines.first?.label, "because of the ponchos")
        model.undoManager.undo()
        XCTAssertNil(model.scene.lines.first?.label)
        XCTAssertEqual(model.scene.lines.count, 1, "undoing a label must not undo the line")
    }

    func test_anEmptyLabelClearsRatherThanStoringWhitespace() {
        XCTAssertNil(LineLabelSheet.normalise("   \n "))
        XCTAssertNil(LineLabelSheet.normalise(""))
        XCTAssertEqual(LineLabelSheet.normalise("  because of the ponchos  "),
                       "because of the ponchos")
    }

    // MARK: - Delete

    func test_deleteRemovesTheSelectedLineAndLeavesItsCards() {
        let model = loadedModel()
        model.undoManager.groupsByEvent = false
        model.withScene {
            $0.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                     to: CanvasNodeID("b")))
        }
        model.selectLine(CanvasLineID("l1"))
        model.deleteSelection()
        XCTAssertTrue(model.scene.lines.isEmpty)
        XCTAssertNil(model.selectedLineID)
        XCTAssertEqual(model.scene.count, 2, "deleting a line must never delete a card")
        model.undoManager.undo()
        XCTAssertEqual(model.scene.lines.count, 1)
    }

    func test_deleteFallsThroughToTheSelectedRegionWhenNoLineIsSelected() {
        let model = loadedModel()
        model.withScene {
            $0.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                         frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        model.selectRegion(CanvasRegionID("r1"))
        model.deleteSelection()
        XCTAssertTrue(model.scene.regions.isEmpty)
        XCTAssertEqual(model.scene.count, 2, "deleting a region never deletes cards (1C-b §4.2)")
    }

    func test_deleteWithNothingSelectedDoesNothing() {
        let model = loadedModel()
        model.withScene {
            $0.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                     to: CanvasNodeID("b")))
        }
        model.deleteSelection()
        XCTAssertEqual(model.scene.lines.count, 1)
        XCTAssertEqual(model.scene.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLineInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `value of type 'CanvasInteraction' has no member 'beginLine'`.

- [ ] **Step 3: Extend `CanvasInteraction`**

Add a case to the existing `private enum Mode` and the four members. Note `endLine` takes `inout CanvasScene` and is fully synchronous — there is no `await` anywhere on this path, so the `inout` is legal.

```swift
    /// A line being drawn. Held separately from `Mode` rather than as
    /// associated values on it because the renderer reads it every frame and a
    /// `case` pattern-match per frame in the draw closure is noise.
    struct PendingLine: Equatable {
        let fromNode: CanvasNodeID
        /// The SOURCE CARD'S CENTRE, not the press point — the rubber band and
        /// the finished line must describe the same geometry, or the line
        /// visibly jumps the instant it is created.
        let from: CGPoint
        var to: CGPoint
    }

    private(set) var pendingLine: PendingLine?

    mutating func beginLine(from node: CanvasNodeID, at point: CGPoint, in scene: CanvasScene) {
        guard let frame = scene.node(node)?.frame else { return }
        mode = .drawingLine
        pendingLine = PendingLine(fromNode: node,
                                  from: CGPoint(x: frame.midX, y: frame.midY),
                                  to: point)
    }

    mutating func updateLine(to point: CGPoint) {
        pendingLine?.to = point
    }

    /// Finish the drag. Returns the new line's id, or nil when the drag ended
    /// on empty canvas or back on the source card — a line needs two distinct
    /// ends, and a dangling one is not a thought.
    @discardableResult
    mutating func endLine(at point: CGPoint, in scene: inout CanvasScene) -> CanvasLineID? {
        defer { pendingLine = nil; mode = .idle }
        guard let pending = pendingLine,
              let target = scene.topmostNode(at: point)?.id,
              target != pending.fromNode else { return nil }
        let id = Self.newLineID(in: scene)
        scene.insertLine(CanvasLine(id: id, from: pending.fromNode, to: target))
        return id
    }

    /// Mirrors `createRegion`'s id minting exactly (1C-b Task 6) so the canvas
    /// has one id shape, not two.
    static func newLineID(in scene: CanvasScene) -> CanvasLineID {
        var id = CanvasLineID(String(UUID().uuidString.prefix(8)).lowercased())
        while scene.lines.contains(where: { $0.id == id }) {
            id = CanvasLineID(String(UUID().uuidString.prefix(8)).lowercased())
        }
        return id
    }
```

`mode = .drawingLine` needs `case drawingLine` on the private `Mode` enum. `update(to:in:)` and `end()` must ignore `.drawingLine` — the line drag is driven by `updateLine`/`endLine`, and letting the generic path also run would move the source card while drawing from it.

- [ ] **Step 4: Extend `CanvasModel`**

```swift
    /// The selected line, or nil. Model state for the same reason
    /// `selectedRegionID` is: the canvas draws the selection and the ⌫ handler
    /// and the promotion command both act on it.
    var selectedLineID: CanvasLineID?

    var selectedLine: CanvasLine? {
        selectedLineID.flatMap { id in scene.lines.first { $0.id == id } }
    }

    /// Selection is EXCLUSIVE, and these two methods are the only doors.
    /// Two selected things means two ⌫ targets and an ambiguous "Promote…".
    func selectLine(_ id: CanvasLineID?) {
        selectedLineID = id
        if id != nil { selectedRegionID = nil }
    }

    func selectRegion(_ id: CanvasRegionID?) {
        selectedRegionID = id
        if id != nil { selectedLineID = nil }
    }

    /// One undo step per committed label, not one per keystroke — the sheet
    /// commits on OK, the same shape as `RegionInspector.commitLabel`.
    func setLineLabel(_ label: String?, for id: CanvasLineID) {
        mutate("Label Line") { $0.updateLine(id) { $0.label = label } }
    }

    /// ⌫ on the canvas. Line first, then region — the line is the smaller,
    /// more recently drawn thing, and a writer who has just selected one
    /// expects ⌫ to take it back.
    func deleteSelection() {
        if let id = selectedLineID {
            mutate("Delete Line") { $0.removeLine(id) }
            selectedLineID = nil
            return
        }
        deleteSelectedRegion()
    }
```

- [ ] **Step 5: Route the gesture in `CanvasView`**

Replace 1C-b Task 6's `handleDragBegan`/`handleDragEnded` with these, and add the modifier property beside `isDrawingRegionGesture`:

```swift
    /// ⇧-drag from a card draws a line to another card. Read from `NSEvent` at
    /// press time, exactly as `isDrawingRegionGesture` reads ⌥ — widening the
    /// event view's callback signature for one Bool would touch every call
    /// site, and two plans have already disagreed about that signature.
    private var isDrawingLineGesture: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    private func handleDragBegan(from contentPoint: CGPoint) {
        // The line branch is FIRST: a ⇧-drag that starts on a card must draw a
        // line rather than move the card.
        if isDrawingLineGesture, let node = model.scene.topmostNode(at: contentPoint)?.id {
            model.beginGesture("Draw Line")
            interaction.beginLine(from: node, at: contentPoint, in: model.scene)
        } else if case .resizeHandle(let id)? = CanvasInteraction.regionHit(at: contentPoint,
                                                                           in: model.scene) {
            model.selectRegion(id)
            model.beginGesture("Resize Region")
            interaction.beginRegionResize(id, at: contentPoint, in: model.scene)
        } else if model.scene.topmostNode(at: contentPoint) != nil {
            model.beginGesture("Move Scrap")
            interaction.begin(at: contentPoint, in: model.scene)
        } else if case .chrome(let id)? = CanvasInteraction.regionHit(at: contentPoint,
                                                                     in: model.scene) {
            model.selectRegion(id)
            model.beginGesture("Move Region")
            interaction.beginRegionDrag(id, at: contentPoint, in: model.scene)
        } else if isDrawingRegionGesture {
            model.beginGesture("Draw Region")
        }
        // A plain drag on empty canvas is a pan, which the event view handles.
    }

    private func handleDragChanged(to contentPoint: CGPoint) {
        if interaction.pendingLine != nil {
            interaction.updateLine(to: contentPoint)
            revision &+= 1   // the rubber band is redrawn from the model
            return
        }
        model.withScene { interaction.update(to: contentPoint, in: &$0) }
    }

    private func handleDragEnded(from start: CGPoint, to end: CGPoint) {
        if interaction.pendingLine != nil {
            model.withScene { scene in
                if let id = interaction.endLine(at: end, in: &scene) {
                    model.selectLine(id)
                }
            }
        } else if interaction.isActive {
            model.withScene { interaction.endDrag(in: &$0) }
        } else if isDrawingRegionGesture {
            model.withScene { scene in
                if let id = CanvasInteraction.createRegion(from: start, to: end, in: &scene) {
                    model.selectRegion(id)
                }
            }
        }
        interaction.end()
        model.endGesture()   // a gesture that changed nothing pushes no undo step
        sceneRevision &+= 1
    }
```

In `handleClick(at:)` (1C-b Task 4), immediately **before** the branch that clears the selection on an empty click, insert:

```swift
        // Lines are hit-tested only where no card was hit, so a line crossing
        // under a card never steals that card's click.
        if model.scene.topmostNode(at: contentPoint) == nil,
           let line = CanvasLineHit.line(at: contentPoint, in: model.scene) {
            model.selectLine(line)
            return
        }
```

and make the empty-click branch clear both: `model.selectLine(nil); model.selectRegion(nil)`.

Rewire ⌫ and add the label sheet:

```swift
                    onDeleteKey: { model.deleteSelection() })
```

```swift
    @State private var editingLineLabelID: CanvasLineID?
```

```swift
        .sheet(item: $editingLineLabelID) { id in
            LineLabelSheet(
                initialLabel: model.scene.lines.first { $0.id == id }?.label,
                onCommit: { label in
                    model.setLineLabel(label, for: id)
                    editingLineLabelID = nil
                },
                onCancel: { editingLineLabelID = nil })
        }
```

`.sheet(item:)` needs `CanvasLineID: Identifiable`; add `extension CanvasLineID: Identifiable { public var id: String { raw } }` in `CanvasLine.swift`.

Open it from a double-click on a selected line: in `handleClick(at:)`'s line branch above, when the click count is 2 set `editingLineLabelID = line` as well as selecting. `CanvasEventNSView.onClick` already carries the click count as its second argument (1C-a Task 6: `var onClick: ((CGPoint, Int) -> Void)?`).

Finally, replace Task 2 Step 6's placeholder call with the real one:

```swift
                CanvasRenderer.drawLines(scene: model.scene,
                                         selectedLineID: model.selectedLineID,
                                         into: &cx)
                if let pending = interaction.pendingLine {
                    CanvasRenderer.drawPendingLine(from: pending.from, to: pending.to, into: &cx)
                }
```

- [ ] **Step 6: Write `Maugham/Canvas/LineLabelSheet.swift`**

```swift
import SwiftUI

/// One field. A line's label is free text — not a type, not a vocabulary, not
/// validated (spec §5) — so there is nothing here to pick from and nothing to
/// get wrong.
struct LineLabelSheet: View {

    let initialLabel: String?
    let onCommit: (String?) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""

    /// Whitespace-only is *no label*, not a label made of spaces. Storing one
    /// would draw an empty pill on the line forever.
    static func normalise(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Line label").font(.headline)
            Text("Optional. A line carries no meaning of its own — this is just "
                 + "what you would have written beside it on paper.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onCommit(Self.normalise(draft)) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Done") { onCommit(Self.normalise(draft)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { draft = initialLabel ?? "" }
    }
}
```

- [ ] **Step 7: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLineInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 14 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionInteractionTests CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasInteractionTests CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasModelTests CODE_SIGNING_ALLOWED=NO`
Expected: all PASS. `CanvasModelTests` is the one to watch — the `selectedRegionID` assignments moved behind `selectRegion`.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas/CanvasLineInteractionTests.swift project.yml
git commit -m "feat(canvas): draw, select, label and delete lines

⇧-drag from card to card; double-click a line to label it; ⌫ deletes the
selected line then falls through to the selected region. Selection is
exclusive and enforced in CanvasModel, not at the call sites."
```

---

### Task 4: The promotion model — §6's table, executable, and a preview that never mutates

**Files:**
- Create: `Maugham/Canvas/Promotion.swift`
- Test: `MaughamTests/Canvas/PromotionTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene` (`node(_:)`, `region(_:)`, `lines`), `CanvasNode` (`kind`, `promotedItemID`), `CanvasNodeID`, `CanvasNodeKind`, `CanvasRegion` (`label`, `homeMembers`), `CanvasRegionID`, `CanvasLine`, `CanvasLineID` (Task 1, 1C-a Task 1, 1C-b Task 1); `RegionInspector.PieceChoice` (1C-b Task 7) — `id: String`, `title: String`.
- **Produces:**
  - `enum PromotionSource: Equatable` — `case scrap(CanvasNodeID)`, `case region(CanvasRegionID)`, `case line(CanvasLineID)`.
  - `enum PromotionTarget: String, Equatable, Hashable, CaseIterable` — `case researchNote`, `paletteCard`, `intentStatement`, `pieceBinding`, `wikiLink`; `var writerFacingName: String`.
  - `enum PromotionDiscard: Equatable, Hashable` — `case lines`, `case layout`.
  - `struct PromotionLinkOffer: Equatable` — `node: CanvasNodeID`, `itemID: String`, `title: String`.
  - `struct WikiLinkWrite: Equatable` — `intoNode: CanvasNodeID`, `intoItemID: String`, `appendedText: String`.
  - `struct PromotionPlan: Equatable` — `source`, `producedKind`, `title`, `body`, `destinationDescription`, `discards: Set<PromotionDiscard>`, `offeredLinks: [PromotionLinkOffer]`, `var linksAccepted: Bool = false`, `wikiLinkWrite: WikiLinkWrite?`, `pieceID: String?`.
  - `enum Promotion` — `static func targets(for:in:) -> [PromotionTarget]`, `static func blockedReason(for:in:) -> String?`, `static func plan(source:target:scraps:piece:in:) -> PromotionPlan?`, `static func title(from:) -> String`.

**`plan` takes `scene: CanvasScene`, not `inout CanvasScene`.** Building a preview never mutates anything, and that is what makes the preview honest. An `inout` here would also be the first step toward a signature that cannot survive contact with the performer, which is `async`.

Spec §6's table is the whole contract:

| Promote | Produces |
|---|---|
| A scrap | a research note, a palette card, or an intent statement |
| A region | a palette card, or a piece binding |
| A line | a `[[wiki-link]]`, when both ends are text |

**Why a line's ends must already be promoted.** See "Three decisions" above: `[[X]]` resolves against the manifest (documents in `ProjectStore.resolveDocumentId(forTitle:)`, documents *and* research items in `ListAllLinksTool`'s title index). A scrap is in neither, so a link naming one resolves to nothing — it would manufacture exactly the precision §6.1 forbids. `blockedReason` exists so the sheet can say why instead of showing an empty list, which is where a writer learns the precedence rule at the moment it costs them something.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/PromotionTests.swift`:

```swift
import XCTest
@testable import Maugham

final class PromotionTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in ["a", "b"].enumerated() {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 400, y: 0), width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        var img = CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                             origin: CGPoint(x: 800, y: 0), width: 180)
        img.cachedHeight = 120
        s.insert(img)
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [CanvasNodeID("a"), CanvasNodeID("b")]))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b")))
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("a"),
                                to: .item("r-9")))
        return s
    }

    private let texts: [CanvasNodeID: String] = [
        CanvasNodeID("a"): "The falls at night.\n\nSodium light on the spray.",
        CanvasNodeID("b"): "October's doctor was kind about it.",
    ]

    private let piece = RegionInspector.PieceChoice(id: "piece-3", title: "Chapter Three")

    // MARK: - §6's table, exactly

    func test_aScrapCanBecomeANoteAPaletteCardOrAnIntent() {
        XCTAssertEqual(Set(Promotion.targets(for: .scrap(CanvasNodeID("a")), in: scene())),
                       [.researchNote, .paletteCard, .intentStatement])
    }

    func test_aRegionCanBecomeAPaletteCardOrAPieceBinding() {
        XCTAssertEqual(Set(Promotion.targets(for: .region(CanvasRegionID("r1")), in: scene())),
                       [.paletteCard, .pieceBinding])
    }

    func test_anItemNodeOffersNothing() {
        XCTAssertTrue(Promotion.targets(for: .scrap(.item("r-9")), in: scene()).isEmpty,
                      "an item already exists — promoting it would duplicate it")
    }

    func test_anUnknownSourceOffersNothing() {
        let s = scene()
        XCTAssertTrue(Promotion.targets(for: .scrap(CanvasNodeID("ghost")), in: s).isEmpty)
        XCTAssertTrue(Promotion.targets(for: .region(CanvasRegionID("ghost")), in: s).isEmpty)
        XCTAssertTrue(Promotion.targets(for: .line(CanvasLineID("ghost")), in: s).isEmpty)
    }

    // MARK: - A line links two DURABLE things or nothing

    func test_aLineBetweenTwoUnpromotedScrapsOffersNothingAndSaysWhy() {
        let s = scene()
        XCTAssertTrue(Promotion.targets(for: .line(CanvasLineID("l1")), in: s).isEmpty)
        let reason = Promotion.blockedReason(for: .line(CanvasLineID("l1")), in: s)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("promote"),
                      "the sheet must teach the precedence rule at the moment it bites, "
                      + "not show an empty list")
    }

    func test_aLineBetweenTwoPromotedScrapsBecomesAWikiLink() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        s.setPromotedItem("res-b", for: CanvasNodeID("b"))
        XCTAssertEqual(Promotion.targets(for: .line(CanvasLineID("l1")), in: s), [.wikiLink])
        XCTAssertNil(Promotion.blockedReason(for: .line(CanvasLineID("l1")), in: s))
    }

    /// §6: "when both ends are text". An image end is not text, and it has no
    /// promoted note to write into either.
    func test_aLineTouchingANonTextNodeOffersNothing() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        XCTAssertTrue(Promotion.targets(for: .line(CanvasLineID("l2")), in: s).isEmpty)
    }

    func test_aLineWithOnlyOneEndPromotedOffersNothing() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        XCTAssertTrue(Promotion.targets(for: .line(CanvasLineID("l1")), in: s).isEmpty)
    }

    // MARK: - The plan is a PREVIEW

    func test_planNamesWhatWillBeProducedAndWhere() {
        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                                  scraps: texts, piece: nil, in: scene())
        XCTAssertEqual(plan?.producedKind, .researchNote)
        XCTAssertEqual(plan?.title, "The falls at night.")
        XCTAssertEqual(plan?.body, "The falls at night.\n\nSodium light on the spray.")
        XCTAssertEqual(plan?.destinationDescription, "research/")
        XCTAssertFalse(plan!.destinationDescription.isEmpty,
                       "the writer must see WHERE before committing (§6.1)")
    }

    func test_aNoteTitleComesFromTheFirstLine() {
        XCTAssertEqual(Promotion.title(from: "  The falls at night.  \n\nSodium light."),
                       "The falls at night.")
    }

    func test_anEmptyScrapProducesNoPlan() {
        XCTAssertNil(Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                                    scraps: [CanvasNodeID("a"): "   \n  "], piece: nil,
                                    in: scene()))
    }

    func test_aTargetTheSourceDoesNotOfferProducesNoPlan() {
        XCTAssertNil(Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .pieceBinding,
                                    scraps: texts, piece: piece, in: scene()))
    }

    func test_planningNeverMutatesTheScene() {
        let before = scene()
        var s = before
        _ = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                           scraps: texts, piece: nil, in: s)
        _ = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                           scraps: texts, piece: nil, in: s)
        _ = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .pieceBinding,
                           scraps: texts, piece: piece, in: s)
        XCTAssertEqual(s, before,
                       "nothing promotes because it sat somewhere long enough or looked "
                       + "like something (§6.1)")
    }

    // MARK: - Regions

    func test_regionPromotionJoinsItsResidentsInIDOrder() {
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: texts, piece: nil, in: scene())
        XCTAssertEqual(plan?.title, "Act II fog")
        XCTAssertEqual(plan?.body,
                       "The falls at night.\n\nSodium light on the spray."
                       + "\n\nOctober's doctor was kind about it.")
    }

    func test_anUnlabelledRegionGetsAWriterFacingFallbackTitle() {
        var s = scene()
        s.updateRegion(CanvasRegionID("r1")) { $0.label = "" }
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: texts, piece: nil, in: s)
        XCTAssertEqual(plan?.title, "Untitled region",
                       "1C-b creates regions with an empty label; an untitled palette card "
                       + "would be unfindable on the wall")
    }

    /// §6.1: promotion is ALLOWED to be lossy, and that is a feature — but the
    /// writer is told which parts are dropped.
    func test_regionPromotionDiscardsLinesAndLayoutAndSaysSo() {
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: texts, piece: nil, in: scene())
        XCTAssertEqual(plan?.discards, [.lines, .layout])
    }

    func test_scrapPromotionDiscardsNothing() {
        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                                  scraps: texts, piece: nil, in: scene())
        XCTAssertTrue(plan!.discards.isEmpty)
    }

    // MARK: - The offer (§6.1: may suggest, must never impose)

    func test_regionPromotionOffersLinkingOnlyForAlreadyPromotedMembers() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: texts, piece: nil, in: s)
        XCTAssertEqual(plan?.offeredLinks.map(\.node), [CanvasNodeID("a")])
        XCTAssertEqual(plan?.offeredLinks.first?.itemID, "res-a")
        XCTAssertEqual(plan?.offeredLinks.first?.title, "The falls at night.")
    }

    func test_theOfferDefaultsToDeclined() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: texts, piece: nil, in: s)
        XCTAssertFalse(plan!.linksAccepted,
                       "an offer that arrives pre-accepted is an imposition with a checkbox; "
                       + "the silent conversion is what §6.1 forbids outright")
    }

    func test_thereIsNoOfferWhenNoMemberIsPromoted() {
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: texts, piece: nil, in: scene())
        XCTAssertTrue(plan!.offeredLinks.isEmpty)
    }

    // MARK: - Wiki-links and bindings carry their execution path

    func test_theWikiLinkPlanNamesBothEndsAndWhereTheTextGoes() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        s.setPromotedItem("res-b", for: CanvasNodeID("b"))
        s.updateLine(CanvasLineID("l1")) { $0.label = "because of the ponchos" }
        let plan = Promotion.plan(source: .line(CanvasLineID("l1")), target: .wikiLink,
                                  scraps: texts, piece: nil, in: s)
        XCTAssertEqual(plan?.title, "The falls at night.")
        XCTAssertEqual(plan?.wikiLinkWrite?.intoNode, CanvasNodeID("a"))
        XCTAssertEqual(plan?.wikiLinkWrite?.intoItemID, "res-a")
        XCTAssertEqual(plan?.wikiLinkWrite?.appendedText,
                       "\n\n[[October's doctor was kind about it.]] — because of the ponchos\n")
    }

    func test_anUnlabelledLineAppendsJustTheLink() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        s.setPromotedItem("res-b", for: CanvasNodeID("b"))
        let plan = Promotion.plan(source: .line(CanvasLineID("l1")), target: .wikiLink,
                                  scraps: texts, piece: nil, in: s)
        XCTAssertEqual(plan?.wikiLinkWrite?.appendedText,
                       "\n\n[[October's doctor was kind about it.]]\n")
    }

    func test_thePieceBindingPlanCarriesThePieceAndNamesItInTheDestination() {
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .pieceBinding,
                                  scraps: texts, piece: piece, in: scene())
        XCTAssertEqual(plan?.pieceID, "piece-3")
        XCTAssertTrue(plan!.destinationDescription.contains("Chapter Three"))
        XCTAssertTrue(plan!.discards.isEmpty,
                      "binding drops nothing — the region stays exactly as it is")
    }

    func test_aPieceBindingWithNoPieceChosenProducesNoPlan() {
        XCTAssertNil(Promotion.plan(source: .region(CanvasRegionID("r1")), target: .pieceBinding,
                                    scraps: texts, piece: nil, in: scene()))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'Promotion' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/Promotion.swift`**

```swift
import Foundation

/// What is being promoted.
enum PromotionSource: Equatable {
    case scrap(CanvasNodeID)
    case region(CanvasRegionID)
    case line(CanvasLineID)
}

/// What it becomes. **This list IS spec §6's table** and must not grow without
/// amending the spec — every entry is a new durable artifact the writer can
/// create, and the whole design rests on that set being small and predictable.
enum PromotionTarget: String, Equatable, Hashable, CaseIterable {
    case researchNote
    case paletteCard
    case intentStatement
    case pieceBinding
    case wikiLink

    var writerFacingName: String {
        switch self {
        case .researchNote: return "Research note"
        case .paletteCard: return "Palette card"
        case .intentStatement: return "Craft intent"
        case .pieceBinding: return "Piece binding"
        case .wikiLink: return "Wiki-link"
        }
    }
}

/// What promoting will throw away. Promotion is ALLOWED to be lossy and that is
/// a feature (§6.1) — the spatial work was thinking; it earned its keep by
/// producing the artifact. Scapple → Scrivener keeps notes and drops
/// connections, deliberately. The writer is told which, in the preview.
enum PromotionDiscard: Equatable, Hashable {
    case lines
    case layout
}

/// An offer to link an already-promoted member to the artifact being produced.
/// An OFFER — see `PromotionPlan.linksAccepted`.
struct PromotionLinkOffer: Equatable {
    let node: CanvasNodeID
    /// The member's own promoted research item. Only promoted members can be
    /// offered: a link into a scrap has nowhere to be written.
    let itemID: String
    let title: String
}

/// The one durable write a line promotion makes. Carried on the plan so the
/// performer has an execution path rather than a description of one — the
/// previous draft's `perform` never received the scraps map and so could not
/// have written a wiki-link at all.
struct WikiLinkWrite: Equatable {
    let intoNode: CanvasNodeID
    let intoItemID: String
    let appendedText: String
}

/// The preview. The writer sees what will be produced, and where, before
/// committing — Scrivener's Commit is the model: a named command with a stated
/// rule and a predictable outcome (§6.1).
///
/// Building a plan NEVER mutates anything. That is what makes the preview
/// honest, and `test_planningNeverMutatesTheScene` pins it.
struct PromotionPlan: Equatable {
    let source: PromotionSource
    let producedKind: PromotionTarget
    var title: String
    var body: String
    /// Human-readable, shown verbatim in the sheet: "research/", "the palette
    /// wall", "the piece “Chapter Three”".
    let destinationDescription: String
    let discards: Set<PromotionDiscard>

    /// §6.1's "may suggest, must never impose". Promoting a region may *offer*
    /// to link its already-promoted members to the artifact it produced. That
    /// sits inside Shipman & Marshall's licence for machine inference precisely
    /// BECAUSE the writer sees it and can decline it cheaply.
    let offeredLinks: [PromotionLinkOffer]

    /// Defaults to FALSE, always. The same inference applied silently is
    /// forbidden: membership is n-ary and vague, wiki-links are binary and
    /// specific, and a silent conversion manufactures precision the writer
    /// never claimed — into a layer with backlinks and rename propagation,
    /// where it is expensive to undo.
    var linksAccepted: Bool = false

    let wikiLinkWrite: WikiLinkWrite?
    let pieceID: String?
}

enum Promotion {

    static let untitledRegionTitle = "Untitled region"

    /// Spec §6's table, executable.
    static func targets(for source: PromotionSource, in scene: CanvasScene) -> [PromotionTarget] {
        switch source {
        case .scrap(let id):
            // Only scraps promote. An item already exists as itself; promoting
            // it would duplicate it, and a second editable copy of one note is
            // exactly what §4.3 rejects.
            guard case .scrap = scene.node(id)?.kind else { return [] }
            return [.researchNote, .paletteCard, .intentStatement]

        case .region(let id):
            guard scene.region(id) != nil else { return [] }
            return [.paletteCard, .pieceBinding]

        case .line(let id):
            guard let line = scene.lines.first(where: { $0.id == id }),
                  promotedScrap(line.from, in: scene) != nil,
                  promotedScrap(line.to, in: scene) != nil else { return [] }
            return [.wikiLink]
        }
    }

    /// Why a source offers nothing, in words a writer can act on. Only lines
    /// have an interesting answer; everything else returns nil and the sheet
    /// simply shows the targets.
    static func blockedReason(for source: PromotionSource, in scene: CanvasScene) -> String? {
        guard case .line(let id) = source,
              let line = scene.lines.first(where: { $0.id == id }),
              targets(for: source, in: scene).isEmpty else { return nil }
        let bothText = isScrap(line.from, in: scene) && isScrap(line.to, in: scene)
        guard bothText else {
            return "A line becomes a wiki-link only between two cards of text."
        }
        // The precedence rule, taught at the moment it costs something:
        // wiki-links are durable and a scrap is not a place a link can point.
        return "Promote both cards first. A wiki-link has to point at something "
            + "that exists outside the canvas — a canvas line is scratch."
    }

    private static func isScrap(_ id: CanvasNodeID, in scene: CanvasScene) -> Bool {
        if case .scrap = scene.node(id)?.kind { return true }
        return false
    }

    /// The node's promoted research item id, when it is a scrap AND has one.
    private static func promotedScrap(_ id: CanvasNodeID, in scene: CanvasScene) -> String? {
        guard let node = scene.node(id), case .scrap = node.kind else { return nil }
        return node.promotedItemID
    }

    static func title(from body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Build the preview, or nil when this source cannot produce this target
    /// (or has nothing to produce it from). Pure: `scene` is read, never
    /// written.
    static func plan(source: PromotionSource,
                     target: PromotionTarget,
                     scraps: [CanvasNodeID: String],
                     piece: RegionInspector.PieceChoice?,
                     in scene: CanvasScene) -> PromotionPlan? {
        guard targets(for: source, in: scene).contains(target) else { return nil }

        switch source {
        case .scrap(let id):
            let body = text(of: id, in: scraps)
            guard !body.isEmpty else { return nil }
            return PromotionPlan(
                source: source, producedKind: target,
                title: title(from: body), body: body,
                destinationDescription: destination(for: target, piece: piece),
                discards: [], offeredLinks: [], wikiLinkWrite: nil, pieceID: nil)

        case .region(let id):
            guard let region = scene.region(id) else { return nil }
            if target == .pieceBinding {
                guard let piece else { return nil }
                return PromotionPlan(
                    source: source, producedKind: target,
                    title: regionTitle(region), body: "",
                    destinationDescription: destination(for: target, piece: piece),
                    // Binding drops nothing: the region stays exactly as it is.
                    discards: [], offeredLinks: [], wikiLinkWrite: nil, pieceID: piece.id)
            }
            let members = region.homeMembers.sorted { $0.raw < $1.raw }
            let bodies = members.compactMap { nodeID -> (CanvasNodeID, String)? in
                let t = text(of: nodeID, in: scraps)
                return t.isEmpty ? nil : (nodeID, t)
            }
            return PromotionPlan(
                source: source, producedKind: target,
                title: regionTitle(region),
                body: bodies.map(\.1).joined(separator: "\n\n"),
                destinationDescription: destination(for: target, piece: piece),
                // The spatial work is not carried across, and the writer is told.
                discards: [.lines, .layout],
                offeredLinks: bodies.compactMap { nodeID, body in
                    guard let itemID = promotedScrap(nodeID, in: scene) else { return nil }
                    return PromotionLinkOffer(node: nodeID, itemID: itemID,
                                              title: title(from: body))
                },
                wikiLinkWrite: nil, pieceID: nil)

        case .line(let id):
            guard let line = scene.lines.first(where: { $0.id == id }),
                  let fromItem = promotedScrap(line.from, in: scene) else { return nil }
            let fromTitle = title(from: text(of: line.from, in: scraps))
            let toTitle = title(from: text(of: line.to, in: scraps))
            guard !fromTitle.isEmpty, !toTitle.isEmpty else { return nil }
            let note = line.label.map { " — \($0)" } ?? ""
            let appended = "\n\n[[\(toTitle)]]\(note)\n"
            return PromotionPlan(
                source: source, producedKind: target,
                title: fromTitle, body: appended.trimmingCharacters(in: .whitespacesAndNewlines),
                destinationDescription: "the note “\(fromTitle)”",
                discards: [], offeredLinks: [],
                wikiLinkWrite: WikiLinkWrite(intoNode: line.from, intoItemID: fromItem,
                                             appendedText: appended),
                pieceID: nil)
        }
    }

    private static func text(of id: CanvasNodeID, in scraps: [CanvasNodeID: String]) -> String {
        (scraps[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 1C-b creates regions with an empty label. An untitled palette card is
    /// unfindable on the wall, so the fallback is writer-facing rather than "".
    private static func regionTitle(_ region: CanvasRegion) -> String {
        let trimmed = region.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitledRegionTitle : trimmed
    }

    private static func destination(for target: PromotionTarget,
                                    piece: RegionInspector.PieceChoice?) -> String {
        switch target {
        case .researchNote: return "research/"
        case .paletteCard: return "the palette wall"
        case .intentStatement: return "the project's craft intent"
        case .pieceBinding: return "the piece “\(piece?.title ?? "")”"
        case .wikiLink: return ""   // replaced per-plan above
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 24 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/Promotion.swift MaughamTests/Canvas/PromotionTests.swift project.yml
git commit -m "feat(canvas): the promotion model — §6's table, previews that never mutate

A line offers a wiki-link only when both ends are already promoted: [[X]]
resolves against the manifest, and a scrap is not in it, so linking two
scraps would manufacture precision the writer never claimed (§6.1). Link
offers default to DECLINED."
```

---

### Task 5: Performing a promotion — `@MainActor`, `async`, through the real store APIs

**Files:**
- Create: `Maugham/Canvas/PromotionPerformer.swift`
- Test: `MaughamTests/Canvas/PromotionPerformerTests.swift`

**The previous draft could not compile.** It declared `perform` synchronous and non-`@MainActor` while every store API it must call is `@MainActor async throws` (`ProjectStore` is `@MainActor`; `addResearchTextNote`, `addPaletteCard`, `updatePaletteCard`, `createCraftIntent` are all `async throws`), and it took `inout CanvasScene` — which cannot cross an `await` in Swift 6. So: **`PromotionPerformer` is `@MainActor`, `perform` is `async throws`, and there is no `inout` on this path.** Scene changes go through `CanvasModel`, synchronously, after the awaits.

**Interfaces:**
- **Consumes:** `PromotionPlan`, `PromotionTarget`, `PromotionSource`, `PromotionLinkOffer`, `WikiLinkWrite` (Task 4); `CanvasModel` — `scene`, `withScene(persist:_:)`, `mutate(_:_:)` (1C-b Task 4); `CanvasScene.setPromotedItem(_:for:)` (Task 1); `RegionBinding.bind(_:toPiece:in:)` (1C-b Task 7); `ProjectStore` (`@MainActor`) — `url`, `manifest.research`, `weak var documentStore`, `addResearchTextNote(parentId:title:) async throws -> ResearchItem`, `addPaletteCard(title:kind:) async throws -> ResearchItem`, `updatePaletteCard(_:) async throws`, `createCraftIntent(forPieceId:) async throws -> ResearchItem`; `DocumentStore.flushPendingSave() async throws`; `PaletteCard(researchItemId:title:kind:swatches:notes:imagePaths:body:)` and `PaletteCard.Kind.other` from `MaughamCore`; `TreeWalk.first(in:where:)`.
- **Produces:** `@MainActor struct PromotionPerformer` — `init(store: ProjectStore, model: CanvasModel)`, `func perform(_ plan: PromotionPlan) async throws -> PromotionResult`; `struct PromotionResult: Equatable` — `createdItemID: String?`, `writtenLinks: [CanvasNodeID]`, `boundPieceID: String?`; `enum PromotionFailure: LocalizedError` — `case emptyTitle`, `case emptyBody`, `case missingPiece`, `case missingWikiLinkWrite`, `case itemHasNoFile(String)`.

**Tripwire 14:** promotion **creates**; it never moves or deletes user content, so the typed `DocumentStore` mover is not on this path and no `moveItem`/`moveToTrash` appears in this file. It must still create through `ProjectStore`'s existing APIs rather than writing files directly, or the manifest and the disk diverge.

**The flush before the body write is not optional.** `AddNoteTool.swift:48-55` records why: a queued 750 ms `scheduleFileSave` for the same path can fire *after* the body write and overwrite it with stale content. Every body write in this file is preceded by one `try? await store.documentStore?.flushPendingSave()`.

**Validate first, write second.** An empty title or body throws before anything is created, so a promotion either fully succeeds or leaves nothing behind. A half-created artifact on a surface whose whole promise is predictability is worse than a refusal.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/PromotionPerformerTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PromotionPerformerTests: XCTestCase {

    /// The house pattern (`MaughamTests/MCP/Tools/AddNoteToolTests.swift:19`):
    /// a per-file helper, not a shared fixture. There is no `TestProjectFixture`
    /// in this codebase.
    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, try await ProjectStore.load(from: tmp))
    }

    /// "a" is the scrap being promoted; "b" is its neighbour.
    private func makeModel(at root: URL) -> CanvasModel {
        let model = CanvasModel()
        model.load(projectRoot: root)
        model.withScene { s in
            for (i, id) in ["a", "b"].enumerated() {
                var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                                   origin: CGPoint(x: CGFloat(i) * 400, y: 0), width: 240)
                n.cachedHeight = 80
                s.insert(n)
            }
            s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                        homeMembers: [CanvasNodeID("a"), CanvasNodeID("b")]))
            s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                    to: CanvasNodeID("b")))
        }
        model.setScrapText("The falls at night\n\nSodium light on the spray.", for: CanvasNodeID("a"))
        model.setScrapText("October's doctor", for: CanvasNodeID("b"))
        return model
    }

    private func body(of item: ResearchItem, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(item.path ?? ""), encoding: .utf8)
    }

    // MARK: - Scrap → research note

    func test_promotingAScrapCreatesARealResearchNoteWithItsBody() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                                  scraps: model.scraps, piece: nil, in: model.scene)!
        let result = try await PromotionPerformer(store: store, model: model).perform(plan)

        XCTAssertNotNil(result.createdItemID)
        let created = try XCTUnwrap(store.manifest.research.first { $0.title == "The falls at night" })
        XCTAssertEqual(created.id, result.createdItemID)
        XCTAssertTrue(try body(of: created, in: root).contains("Sodium light on the spray."))
    }

    /// §1 and §6: promotion is a seam, not a move. The canvas is scratch and
    /// stays scratch.
    func test_promotingAScrapLeavesItOnTheCanvasAndMarksIt() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                                  scraps: model.scraps, piece: nil, in: model.scene)!
        let result = try await PromotionPerformer(store: store, model: model).perform(plan)

        XCTAssertNotNil(model.scene.node(CanvasNodeID("a")))
        XCTAssertEqual(model.scraps[CanvasNodeID("a")],
                       "The falls at night\n\nSodium light on the spray.")
        XCTAssertEqual(model.scene.node(CanvasNodeID("a"))?.promotedItemID, result.createdItemID)
        XCTAssertNil(model.scene.node(CanvasNodeID("b"))?.promotedItemID)
    }

    /// Explicit and user-initiated (§6.1). A second promotion is a second
    /// explicit act, and it produces a second artifact rather than silently
    /// refusing or silently overwriting the first.
    func test_promotingTheSameScrapTwiceProducesTwoArtifacts() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                                  scraps: model.scraps, piece: nil, in: model.scene)!
        let first = try await performer.perform(plan)
        let second = try await performer.perform(plan)
        XCTAssertNotEqual(first.createdItemID, second.createdItemID)
        XCTAssertEqual(store.manifest.research.count, 2)
        XCTAssertEqual(model.scene.node(CanvasNodeID("a"))?.promotedItemID, second.createdItemID,
                       "the mark names the most recent promotion")
    }

    // MARK: - Scrap → palette card

    func test_promotingAScrapToAPaletteCardPutsItOnTheWall() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .paletteCard,
                                  scraps: model.scraps, piece: nil, in: model.scene)!
        _ = try await PromotionPerformer(store: store, model: model).perform(plan)

        let card = try XCTUnwrap(store.loadPaletteCards().first { $0.title == "The falls at night" })
        XCTAssertTrue(card.body.contains("Sodium light on the spray."),
                      "a palette card whose prose was dropped is not the scrap promoted")
        _ = root
    }

    // MARK: - Scrap → craft intent

    func test_promotingAScrapToAnIntentAppendsToTheIntentDoc() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .intentStatement,
                                  scraps: model.scraps, piece: nil, in: model.scene)!
        _ = try await PromotionPerformer(store: store, model: model).perform(plan)

        let intent = try XCTUnwrap(store.craftIntentItem(forPieceId: nil))
        XCTAssertTrue(try body(of: intent, in: root).contains("Sodium light on the spray."))
    }

    func test_promotingASecondIntentStatementKeepsTheFirst() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(
            Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .intentStatement,
                           scraps: model.scraps, piece: nil, in: model.scene)!)
        _ = try await performer.perform(
            Promotion.plan(source: .scrap(CanvasNodeID("b")), target: .intentStatement,
                           scraps: model.scraps, piece: nil, in: model.scene)!)

        let intent = try XCTUnwrap(store.craftIntentItem(forPieceId: nil))
        let text = try body(of: intent, in: root)
        XCTAssertTrue(text.contains("Sodium light on the spray."))
        XCTAssertTrue(text.contains("October's doctor"),
                      "an intent doc accumulates; the second statement must not replace the first")
    }

    // MARK: - Region → piece binding

    func test_promotingARegionToAPieceBindingSetsTheBindingAndTouchesNoFiles() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let piece = RegionInspector.PieceChoice(id: "piece-3", title: "Chapter Three")
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .pieceBinding,
                                  scraps: model.scraps, piece: piece, in: model.scene)!
        let result = try await PromotionPerformer(store: store, model: model).perform(plan)

        XCTAssertEqual(result.boundPieceID, "piece-3")
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.boundPieceID, "piece-3")
        XCTAssertTrue(store.manifest.research.isEmpty, "binding creates nothing")
        _ = root
    }

    // MARK: - The offer (§6.1)

    private func promoteBothScraps(_ store: ProjectStore,
                                   _ model: CanvasModel) async throws {
        let performer = PromotionPerformer(store: store, model: model)
        for id in [CanvasNodeID("a"), CanvasNodeID("b")] {
            _ = try await performer.perform(
                Promotion.plan(source: .scrap(id), target: .researchNote,
                               scraps: model.scraps, piece: nil, in: model.scene)!)
        }
    }

    func test_declinedLinkOffersWriteNoLinks() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: model.scraps, piece: nil, in: model.scene)!
        XCTAssertEqual(plan.offeredLinks.count, 2)
        XCTAssertFalse(plan.linksAccepted)

        let result = try await PromotionPerformer(store: store, model: model).perform(plan)
        XCTAssertTrue(result.writtenLinks.isEmpty)
        for item in store.manifest.research where item.path?.hasSuffix(".md") == true {
            XCTAssertFalse(try body(of: item, in: root).contains("[["),
                           "a declined offer must write nothing at all")
        }
    }

    func test_acceptedLinkOffersWriteExactlyTheOfferedLinks() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        var plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: model.scraps, piece: nil, in: model.scene)!
        plan.linksAccepted = true

        let result = try await PromotionPerformer(store: store, model: model).perform(plan)
        XCTAssertEqual(Set(result.writtenLinks), [CanvasNodeID("a"), CanvasNodeID("b")])
        let noteA = try XCTUnwrap(store.manifest.research.first { $0.title == "The falls at night" })
        XCTAssertTrue(try body(of: noteA, in: root).contains("[[Act II fog]]"))
    }

    // MARK: - Line → wiki-link

    func test_promotingALineAppendsTheLinkToTheFromEndsNote() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        model.mutate("Label Line") {
            $0.updateLine(CanvasLineID("l1")) { $0.label = "because of the ponchos" }
        }
        let plan = Promotion.plan(source: .line(CanvasLineID("l1")), target: .wikiLink,
                                  scraps: model.scraps, piece: nil, in: model.scene)!
        _ = try await PromotionPerformer(store: store, model: model).perform(plan)

        let noteA = try XCTUnwrap(store.manifest.research.first { $0.title == "The falls at night" })
        let noteB = try XCTUnwrap(store.manifest.research.first { $0.title == "October's doctor" })
        let textA = try body(of: noteA, in: root)
        XCTAssertTrue(textA.contains("[[October's doctor]] — because of the ponchos"))
        XCTAssertTrue(textA.contains("Sodium light on the spray."),
                      "appending must not replace the note")
        XCTAssertFalse(try body(of: noteB, in: root).contains("[["),
                       "a line writes ONE link, into the from end — not both ways")
    }

    // MARK: - Failure leaves nothing behind

    func test_anEmptyTitleThrowsAndCreatesNothing() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let plan = PromotionPlan(source: .scrap(CanvasNodeID("a")), producedKind: .researchNote,
                                 title: "  ", body: "something",
                                 destinationDescription: "research/", discards: [],
                                 offeredLinks: [], wikiLinkWrite: nil, pieceID: nil)
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(plan)
            XCTFail("expected a refusal")
        } catch PromotionFailure.emptyTitle {
            // ok
        }
        XCTAssertTrue(store.manifest.research.isEmpty)
        XCTAssertNil(model.scene.node(CanvasNodeID("a"))?.promotedItemID)
        _ = root
    }

    func test_aPieceBindingWithNoPieceThrows() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let plan = PromotionPlan(source: .region(CanvasRegionID("r1")), producedKind: .pieceBinding,
                                 title: "Act II fog", body: "",
                                 destinationDescription: "the piece “”", discards: [],
                                 offeredLinks: [], wikiLinkWrite: nil, pieceID: nil)
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(plan)
            XCTFail("expected a refusal")
        } catch PromotionFailure.missingPiece {
            // ok
        }
        XCTAssertNil(model.scene.region(CanvasRegionID("r1"))?.boundPieceID)
        _ = root
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionPerformerTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'PromotionPerformer' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/PromotionPerformer.swift`**

```swift
import Foundation
import MaughamCore

struct PromotionResult: Equatable {
    var createdItemID: String?
    var writtenLinks: [CanvasNodeID] = []
    var boundPieceID: String?
}

enum PromotionFailure: LocalizedError {
    case emptyTitle
    case emptyBody
    case missingPiece
    case missingWikiLinkWrite
    case itemHasNoFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "That card has no first line to use as a title."
        case .emptyBody: return "That card is empty."
        case .missingPiece: return "Choose a piece to bind this region to."
        case .missingWikiLinkWrite: return "Both ends of the line have to be promoted first."
        case .itemHasNoFile(let id): return "The note “\(id)” has no file on disk."
        }
    }
}

/// Executes an approved promotion.
///
/// **`@MainActor` and `async`, and neither is negotiable.** `ProjectStore` is a
/// `@MainActor` type and every creation API it exposes is `async throws`. A
/// synchronous performer cannot call any of them, and an `inout CanvasScene`
/// parameter cannot cross an `await` at all in Swift 6 — so scene changes go
/// through `CanvasModel` synchronously, after the awaits, and there is no
/// `inout` anywhere on this path.
///
/// **Tripwire 14 is not on this path**: promotion CREATES and never moves or
/// deletes user content, so the typed `DocumentStore` mover does not apply. It
/// still creates through `ProjectStore`'s existing APIs rather than writing
/// files directly, or the manifest and the disk diverge.
///
/// **Validate first, write second.** A promotion either fully succeeds or
/// leaves nothing behind: a half-created artifact on a surface whose whole
/// promise is predictability is worse than a refusal.
@MainActor
struct PromotionPerformer {

    let store: ProjectStore
    let model: CanvasModel

    func perform(_ plan: PromotionPlan) async throws -> PromotionResult {
        try validate(plan)

        var result = PromotionResult()

        switch plan.producedKind {
        case .researchNote:
            let item = try await store.addResearchTextNote(parentId: nil, title: plan.title)
            try await write(plan.body, to: item)
            result.createdItemID = item.id
            mark(plan.source, promotedInto: item.id)

        case .paletteCard:
            let item = try await store.addPaletteCard(title: plan.title, kind: .other)
            // The card model owns its file (`parse(render(card)) == card`), so
            // the prose goes through the model rather than being appended to
            // the template's markdown.
            try await store.updatePaletteCard(
                PaletteCard(researchItemId: item.id, title: item.title, kind: .other,
                            swatches: [], notes: [], imagePaths: [], body: plan.body))
            result.createdItemID = item.id
            mark(plan.source, promotedInto: item.id)

        case .intentStatement:
            let item = try await store.createCraftIntent(forPieceId: nil)
            try await append("\n\n\(plan.body)\n", to: item)
            result.createdItemID = item.id
            mark(plan.source, promotedInto: item.id)

        case .pieceBinding:
            guard case .region(let regionID) = plan.source, let pieceID = plan.pieceID else {
                throw PromotionFailure.missingPiece
            }
            model.mutate("Bind Region") { RegionBinding.bind(regionID, toPiece: pieceID, in: &$0) }
            result.boundPieceID = pieceID

        case .wikiLink:
            guard let write = plan.wikiLinkWrite else { throw PromotionFailure.missingWikiLinkWrite }
            let item = try researchItem(write.intoItemID)
            try await append(write.appendedText, to: item)
            result.createdItemID = item.id
            result.writtenLinks = [write.intoNode]
        }

        // §6.1's offer, serviced ONLY when the writer accepted it. The default
        // is declined and the sheet cannot commit an offer the writer did not
        // tick.
        if plan.linksAccepted {
            for offer in plan.offeredLinks {
                let item = try researchItem(offer.itemID)
                try await append("\n\n[[\(plan.title)]]\n", to: item)
                result.writtenLinks.append(offer.node)
            }
        }

        return result
    }

    // MARK: - Validation

    private func validate(_ plan: PromotionPlan) throws {
        if plan.producedKind == .pieceBinding {
            guard plan.pieceID != nil else { throw PromotionFailure.missingPiece }
            return
        }
        guard !plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromotionFailure.emptyTitle
        }
        if plan.producedKind == .wikiLink {
            guard plan.wikiLinkWrite != nil else { throw PromotionFailure.missingWikiLinkWrite }
            return
        }
        guard !plan.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromotionFailure.emptyBody
        }
    }

    // MARK: - Marking

    /// Record on the canvas that this scrap is now durable. Deliberately NOT an
    /// undo step: the note it names exists on disk, and a ⌘Z that removed the
    /// mark would leave the writer looking at a scrap that is silently already
    /// a note.
    private func mark(_ source: PromotionSource, promotedInto itemID: String) {
        guard case .scrap(let nodeID) = source else { return }
        model.withScene { $0.setPromotedItem(itemID, for: nodeID) }
    }

    // MARK: - Files

    private func researchItem(_ id: String) throws -> ResearchItem {
        guard let item = TreeWalk.first(in: store.manifest.research, where: { $0.id == id }) else {
            throw PromotionFailure.itemHasNoFile(id)
        }
        return item
    }

    private func fileURL(for item: ResearchItem) throws -> URL {
        guard let path = item.path, !path.isEmpty else {
            throw PromotionFailure.itemHasNoFile(item.id)
        }
        return store.url.appendingPathComponent(path)
    }

    /// Replace the item's file contents.
    ///
    /// The flush is the tripwire-14 research-note race fix from
    /// `AddNoteTool.swift:48-55`: a queued 750 ms `scheduleFileSave` for this
    /// path can otherwise fire AFTER the body write and overwrite it.
    private func write(_ text: String, to item: ResearchItem) async throws {
        try? await store.documentStore?.flushPendingSave()
        try text.write(to: try fileURL(for: item), atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to item: ResearchItem) async throws {
        try? await store.documentStore?.flushPendingSave()
        let url = try fileURL(for: item)
        // adr-0018-ok: research note, not manuscript — this file has no op log
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + text).write(to: url, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionPerformerTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 12 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/TripwireGrepTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — the `String(contentsOf:` in `append` carries its `// adr-0018-ok:` on the line the read starts, and nothing here moves user content.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/PromotionPerformer.swift MaughamTests/Canvas/PromotionPerformerTests.swift project.yml
git commit -m "feat(canvas): perform promotions through the existing store APIs

@MainActor and async because every ProjectStore creation API is; no inout
crosses an await. Validate first, write second, so a refused promotion
leaves nothing behind. Declined link offers write nothing at all."
```

---

### Task 6: The promotion sheet and the gesture — resolving spec §10

**Files:**
- Create: `Maugham/Canvas/PromotionSheet.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (one argument in the `.canvas` editor arm)
- Test: `MaughamTests/Canvas/PromotionSheetTests.swift`

**Spec §10 resolved:** *"The promotion gesture — drag onto an artifact rail, a context action, or a keystroke. Deliberately unresolved."* → **a menu command on the current selection, ⌘⇧↩.** The reasoning is in "Three decisions" at the top of this plan, including the ⌘⇧P collision with `MaughamApp.swift:208`'s "Toggle Research Preview". Flag for smoke: if it reads as undiscoverable, a right-click context action is the fallback, and that is a UI change, not a model change.

**Interfaces:**
- **Consumes:** `Promotion`, `PromotionSource`, `PromotionTarget`, `PromotionPlan`, `PromotionDiscard` (Task 4); `PromotionPerformer`, `PromotionResult` (Task 5); `CanvasModel` — `scene`, `scraps`, `selectedLineID`, `selectedRegionID`, `flush()` (1C-b Task 4 + Task 3); `RegionInspector.PieceChoice` (1C-b Task 7); `ProjectStore.manifest.structure` + `TreeWalk.collect(in:where:)`; `MaughamEvent.post(_:to:)` and `View.onKeyWindowCommand(_:window:perform:)` (`Maugham/Events/MaughamEvent+Receive.swift:18`).
- **Produces:**
  - `Notification.Name.maughamPromoteCanvasSelection`.
  - `@Observable final class PromotionSheetModel` — `init(source:scene:scraps:pieces:)`, `let source`, `var availableTargets: [PromotionTarget]`, `var blockedReason: String?`, `private(set) var selectedTarget: PromotionTarget?`, `func select(_:)`, `var editedTitle: String`, `var linksAccepted: Bool`, `var selectedPieceID: String?`, `var preview: PromotionPlan?`, `var resolvedPlan: PromotionPlan?`, `var canCommit: Bool`, `var discardNotice: String`, `static let precedenceNote: String`.
  - `struct PromotionSheet: View` — `init(model: PromotionSheetModel, onCommit: @escaping (PromotionPlan) -> Void, onCancel: @escaping () -> Void)`.
  - On `CanvasView`: `let store: ProjectStore` (new stored property).

**Two defaults are deliberate and must not be "improved":** `selectedTarget` starts nil, so nothing can be committed by pressing return on a sheet that just appeared; `linksAccepted` starts false, because an offer that arrives pre-accepted is an imposition with a checkbox.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/PromotionSheetTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class PromotionSheetTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in ["a", "b"].enumerated() {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 400, y: 0), width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [CanvasNodeID("a"), CanvasNodeID("b")]))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b")))
        return s
    }

    private let texts: [CanvasNodeID: String] = [
        CanvasNodeID("a"): "The falls\n\nbody",
        CanvasNodeID("b"): "October's doctor",
    ]

    private let pieces = [RegionInspector.PieceChoice(id: "piece-3", title: "Chapter Three")]

    private func model(_ source: PromotionSource, scene: CanvasScene? = nil) -> PromotionSheetModel {
        PromotionSheetModel(source: source, scene: scene ?? self.scene(),
                            scraps: texts, pieces: pieces)
    }

    func test_theSheetOffersExactlyTheTargetsTheModelAllows() {
        XCTAssertEqual(Set(model(.scrap(CanvasNodeID("a"))).availableTargets),
                       [.researchNote, .paletteCard, .intentStatement])
        XCTAssertEqual(Set(model(.region(CanvasRegionID("r1"))).availableTargets),
                       [.paletteCard, .pieceBinding])
    }

    func test_theSheetStartsWithNothingSelectedSoNothingCommitsByAccident() {
        let m = model(.scrap(CanvasNodeID("a")))
        XCTAssertNil(m.selectedTarget)
        XCTAssertNil(m.preview)
        XCTAssertFalse(m.canCommit)
    }

    func test_choosingATargetProducesAPreviewBeforeAnythingIsWritten() {
        let m = model(.scrap(CanvasNodeID("a")))
        m.select(.researchNote)
        XCTAssertEqual(m.preview?.title, "The falls")
        XCTAssertEqual(m.preview?.destinationDescription, "research/")
        XCTAssertTrue(m.canCommit)
    }

    func test_theWriterCanEditTheTitleBeforeCommitting() {
        let m = model(.scrap(CanvasNodeID("a")))
        m.select(.researchNote)
        m.editedTitle = "Niagara, 3am"
        XCTAssertEqual(m.resolvedPlan?.title, "Niagara, 3am")
        XCTAssertEqual(m.resolvedPlan?.body, "The falls\n\nbody",
                       "editing the title must not touch the body")
    }

    func test_choosingATargetSeedsTheEditableTitleFromThePreview() {
        let m = model(.scrap(CanvasNodeID("a")))
        m.select(.researchNote)
        XCTAssertEqual(m.editedTitle, "The falls")
    }

    func test_anEmptyEditedTitleBlocksCommit() {
        let m = model(.scrap(CanvasNodeID("a")))
        m.select(.researchNote)
        m.editedTitle = "   "
        XCTAssertFalse(m.canCommit, "the performer would refuse it; the sheet says so first")
    }

    // MARK: - The offer (§6.1)

    func test_theLinkOfferIsShownUncheckedForARegion() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        s.setPromotedItem("res-b", for: CanvasNodeID("b"))
        let m = model(.region(CanvasRegionID("r1")), scene: s)
        m.select(.paletteCard)
        XCTAssertEqual(m.preview?.offeredLinks.count, 2)
        XCTAssertFalse(m.linksAccepted)
        XCTAssertFalse(m.resolvedPlan!.linksAccepted)
    }

    func test_tickingTheOfferReachesThePlan() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        let m = model(.region(CanvasRegionID("r1")), scene: s)
        m.select(.paletteCard)
        m.linksAccepted = true
        XCTAssertTrue(m.resolvedPlan!.linksAccepted)
    }

    func test_theDiscardNoticeIsSurfacedForARegionAndSilentForAScrap() {
        let region = model(.region(CanvasRegionID("r1")))
        region.select(.paletteCard)
        XCTAssertFalse(region.discardNotice.isEmpty,
                       "the writer must be told the lines and layout are not carried across")

        let scrap = model(.scrap(CanvasNodeID("a")))
        scrap.select(.researchNote)
        XCTAssertTrue(scrap.discardNotice.isEmpty)
    }

    // MARK: - Piece binding

    func test_aPieceBindingCannotCommitUntilAPieceIsChosen() {
        let m = model(.region(CanvasRegionID("r1")))
        m.select(.pieceBinding)
        XCTAssertFalse(m.canCommit)
        m.selectedPieceID = "piece-3"
        XCTAssertTrue(m.canCommit)
        XCTAssertEqual(m.resolvedPlan?.pieceID, "piece-3")
    }

    // MARK: - A blocked source explains itself

    func test_aLineBetweenUnpromotedScrapsShowsNoTargetsAndAReason() {
        let m = model(.line(CanvasLineID("l1")))
        XCTAssertTrue(m.availableTargets.isEmpty)
        XCTAssertNotNil(m.blockedReason)
        XCTAssertFalse(m.canCommit)
    }

    func test_aLineBetweenPromotedScrapsCanCommit() {
        var s = scene()
        s.setPromotedItem("res-a", for: CanvasNodeID("a"))
        s.setPromotedItem("res-b", for: CanvasNodeID("b"))
        let m = model(.line(CanvasLineID("l1")), scene: s)
        XCTAssertEqual(m.availableTargets, [.wikiLink])
        XCTAssertNil(m.blockedReason)
        m.select(.wikiLink)
        XCTAssertTrue(m.canCommit)
        XCTAssertEqual(m.resolvedPlan?.wikiLinkWrite?.intoItemID, "res-a")
    }

    // MARK: - The precedence rule, stated once, plainly (§5)

    func test_thePrecedenceNoteNamesBothLayers() {
        let note = PromotionSheetModel.precedenceNote.lowercased()
        XCTAssertTrue(note.contains("wiki-link"))
        XCTAssertTrue(note.contains("scratch"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionSheetTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'PromotionSheetModel' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/PromotionSheet.swift`**

```swift
import SwiftUI

/// The promotion preview.
///
/// §6.1: the writer sees what will be produced, and where, before committing.
/// Scrivener's Commit is the model — a named command with a stated rule and a
/// predictable outcome.
///
/// Two defaults are deliberate and must not be "improved":
///
/// * `selectedTarget` starts nil. Nothing can be committed by pressing return
///   on a sheet that just appeared.
/// * `linksAccepted` starts false. Promotion may suggest and must never impose;
///   an offer that arrives pre-accepted is an imposition with a checkbox.
@Observable
final class PromotionSheetModel {

    /// Spec §5: *"Precedence must be stated in the UI, once, plainly."*
    /// Obsidian's three-year confusion is entirely a consequence of never
    /// answering "which of these is the real relationship?"
    static let precedenceNote =
        "Wiki-links are durable and travel with your project. "
        + "Canvas lines are scratch — they stay on the canvas."

    let source: PromotionSource
    let pieces: [RegionInspector.PieceChoice]

    private let scene: CanvasScene
    private let scraps: [CanvasNodeID: String]

    private(set) var selectedTarget: PromotionTarget?
    var editedTitle: String = ""
    var linksAccepted: Bool = false
    var selectedPieceID: String?

    init(source: PromotionSource, scene: CanvasScene,
         scraps: [CanvasNodeID: String], pieces: [RegionInspector.PieceChoice]) {
        self.source = source
        self.scene = scene
        self.scraps = scraps
        self.pieces = pieces
    }

    var availableTargets: [PromotionTarget] { Promotion.targets(for: source, in: scene) }

    /// Why there are no targets, in words a writer can act on. This is where
    /// the precedence rule is learned at the moment it costs something.
    var blockedReason: String? { Promotion.blockedReason(for: source, in: scene) }

    func select(_ target: PromotionTarget) {
        selectedTarget = target
        linksAccepted = false      // a new target is a new offer, and it is declined
        editedTitle = basePlan?.title ?? ""
    }

    private var chosenPiece: RegionInspector.PieceChoice? {
        selectedPieceID.flatMap { id in pieces.first { $0.id == id } }
    }

    private var basePlan: PromotionPlan? {
        guard let target = selectedTarget else { return nil }
        return Promotion.plan(source: source, target: target, scraps: scraps,
                              piece: chosenPiece, in: scene)
    }

    /// What will be produced, exactly as the model computes it. Read-only —
    /// the writer's edits are applied in `resolvedPlan`.
    var preview: PromotionPlan? { basePlan }

    /// The plan that will actually be performed: the preview plus the writer's
    /// title edit and their answer to the offer.
    var resolvedPlan: PromotionPlan? {
        guard var plan = basePlan else { return nil }
        plan.title = editedTitle
        plan.linksAccepted = linksAccepted
        return plan
    }

    var canCommit: Bool {
        guard let plan = resolvedPlan else { return false }
        if plan.producedKind == .pieceBinding { return plan.pieceID != nil }
        return !plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// §6.1: promotion is allowed to be lossy, and the writer is told which
    /// parts are dropped. Empty when nothing is.
    var discardNotice: String {
        guard let discards = preview?.discards, !discards.isEmpty else { return "" }
        var parts: [String] = []
        if discards.contains(.lines) { parts.append("the lines between these cards") }
        if discards.contains(.layout) { parts.append("their arrangement") }
        return "This keeps the words and leaves \(parts.joined(separator: " and ")) "
            + "on the canvas."
    }
}

struct PromotionSheet: View {

    @Bindable var model: PromotionSheetModel
    let onCommit: (PromotionPlan) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Promote").font(.headline)

            if let reason = model.blockedReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Make it", selection: Binding(
                    get: { model.selectedTarget },
                    set: { if let t = $0 { model.select(t) } })) {
                    Text("Choose…").tag(PromotionTarget?.none)
                    ForEach(model.availableTargets, id: \.self) { target in
                        Text(target.writerFacingName).tag(PromotionTarget?.some(target))
                    }
                }
                .pickerStyle(.menu)
            }

            if let preview = model.preview {
                if preview.producedKind == .pieceBinding {
                    Picker("Piece", selection: $model.selectedPieceID) {
                        Text("Choose…").tag(String?.none)
                        ForEach(model.pieces) { piece in
                            Text(piece.title).tag(String?.some(piece.id))
                        }
                    }
                } else {
                    TextField("Title", text: $model.editedTitle)
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        Text(preview.body)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                }

                Text("Goes to \(preview.destinationDescription).")
                    .font(.caption).foregroundStyle(.secondary)

                if !model.discardNotice.isEmpty {
                    Text(model.discardNotice).font(.caption).foregroundStyle(.secondary)
                }

                if !preview.offeredLinks.isEmpty {
                    // Visible, declinable, and DECLINED by default (§6.1).
                    Toggle(isOn: $model.linksAccepted) {
                        Text("Also link \(preview.offeredLinks.count) promoted cards to it")
                    }
                    ForEach(preview.offeredLinks, id: \.node) { offer in
                        Text("• \(offer.title)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            Text(PromotionSheetModel.precedenceNote)
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Promote") { if let plan = model.resolvedPlan { onCommit(plan) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCommit)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
```

- [ ] **Step 4: Add the notification and the menu command**

In `Maugham/Models/MaughamNotifications.swift`:

```swift
    /// Scope: .keyWindow — menu-command class. Promotes whatever the canvas has
    /// selected (spec §6). A window not showing the canvas simply has no
    /// receiver, which is the correct no-op.
    public static let maughamPromoteCanvasSelection =
        Notification.Name("maugham.promote.canvas.selection")
```

In `Maugham/MaughamApp.swift`, inside the second `CommandGroup(after: .pasteboard)` block (the one holding "Find in Project…" and "Restore Last Deleted Item"):

```swift
                Button("Promote\u{2026}") {
                    MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
```

**⌘⇧P is already bound** to "Toggle Research Preview" at `MaughamApp.swift:208`; ⌘⇧↩ is free and reads as *commit this*, which is the Scrivener framing §6.1 names. Confirm with `grep -n "keyboardShortcut" Maugham --include="*.swift" -r` before committing.

- [ ] **Step 5: Wire the sheet into `CanvasView`**

Add the store, the window accessor and the sheet state:

```swift
    /// Promotion writes through `ProjectStore`'s existing creation APIs, so the
    /// canvas needs it. `projectRoot` stays as it is — the sidecar path is a
    /// separate concern from the project graph and 1C-b's initialiser already
    /// carries it.
    let store: ProjectStore

    /// `onKeyWindowCommand` needs the hosting window (the `WindowAccessor`
    /// idiom, `MaughamEvent+Receive.swift`).
    @State private var window: NSWindow?
    @State private var promotionModel: PromotionSheetModel?
```

and on `CanvasView`'s own body (not `ProjectWindow.body`):

```swift
        .background(WindowAccessor(window: $window))
        .onKeyWindowCommand(.maughamPromoteCanvasSelection, window: window) { _ in
            beginPromotion()
        }
        .sheet(item: $promotionModel) { sheetModel in
            PromotionSheet(
                model: sheetModel,
                onCommit: { plan in
                    promotionModel = nil
                    Task { await performPromotion(plan) }
                },
                onCancel: { promotionModel = nil })
        }
```

`.sheet(item:)` needs identity; add `extension PromotionSheetModel: Identifiable { var id: ObjectIdentifier { ObjectIdentifier(self) } }` in `PromotionSheet.swift`.

```swift
    /// What "Promote…" acts on: the selected line, else the selected region,
    /// else the scrap whose editor is mounted. No new selection state — a
    /// writer who has clicked into a scrap has already told us which one.
    private var promotionSource: PromotionSource? {
        if let line = model.selectedLineID { return .line(line) }
        if let region = model.selectedRegionID { return .region(region) }
        if let node = editingNodeID { return .scrap(node) }
        return nil
    }

    private func beginPromotion() {
        guard let source = promotionSource else { return }
        // The words the writer has just typed live in the mounted editor until
        // something pulls them into the model, and a preview built from a stale
        // scrap would promote text the writer cannot see.
        syncActiveEdit()
        promotionModel = PromotionSheetModel(
            source: source, scene: model.scene, scraps: model.scraps,
            pieces: TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document })
                .map { RegionInspector.PieceChoice(id: $0.id, title: $0.title) })
    }

    @MainActor
    private func performPromotion(_ plan: PromotionPlan) async {
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(plan)
            model.flush()
            sceneRevision &+= 1   // the promoted mark is structural
        } catch {
            NSAlert(error: error).runModal()
        }
    }
```

- [ ] **Step 6: Pass the store from `ProjectWindow`**

In `existingEditorSwitch`'s `.canvas` arm, add `store: store` to the existing `CanvasView(...)` call. It stays a single expression, so the arm's budget is unchanged and **no line is added to `ProjectWindow.body`**.

- [ ] **Step 7: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionSheetTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 13 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/TripwireGrepTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — the new event is posted through `MaughamEvent.post` and received through `onKeyWindowCommand`, so no raw `NotificationCenter` appears.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. `ProjectWindow.body` gained nothing, but the `.canvas` arm changed, and the Release type-check budget is stricter than Debug.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift MaughamTests/Canvas/PromotionSheetTests.swift project.yml
git commit -m "feat(canvas): the promotion sheet and ⌘⇧↩ — resolves spec §10's gesture question

A menu command on the current selection, not a rail (permanent chrome on a
surface whose feel is open space) and not a context menu (an NSMenu pop for
a v1 affordance). ⌘⇧P was already Toggle Research Preview. Nothing is
selected when the sheet opens and the link offer arrives declined."
```

---

### Task 7: `list_canvas` — Claude reads the canvas

**Files:**
- Create: `Maugham/MCP/Tools/CanvasTools.swift`
- Modify: `Maugham/MCP/MCPTool.swift` (one catalog entry)
- Modify: `Maugham/Stores/ProjectStore.swift` (`weak var canvasModel`)
- Modify: `Maugham/Views/ProjectWindow.swift` (one line in `load()`)
- Modify: `Maugham/MCP/AREA.md`, `CLAUDE.md` (tool count 52 → 53, plus the row)
- Modify: `MaughamTests/MCP/MCPProtocolHandlersTests.swift` (the hardcoded name set)
- Test: `MaughamTests/MCP/Tools/CanvasReadToolTests.swift`

**Interfaces:**
- **Consumes:** `MCPTool` (`static var method`, `static var description`, `static var inputSchemaJSON`, `@MainActor static func handle(paramsJSON:registry:) async throws -> Data`); `decodeParams(_:from:)` and `resolveProject(_:in:)` (the shared MCP decode helpers used by every tool in `Maugham/MCP/Tools/`); `MCPResponseBudget.enforce(_:hint:)`; `ProjectRegistry` entry — `store`, `url`; `CanvasStore(projectRoot:).load()`; `CanvasScene`, `CanvasNode`, `CanvasRegion`, `CanvasLine`, `CanvasMembership.homeRegion(of:in:)` (Tasks 1, 1C-a, 1C-b).
- **Produces:** `enum ListCanvasTool: MCPTool` with nested `Params`/`Result`; `enum CanvasSource` with `@MainActor static func read(store:url:) -> (scene: CanvasScene, scraps: [CanvasNodeID: String])`; on `ProjectStore`, `public weak var canvasModel: CanvasModel?`.

**Read the LIVE canvas when a window has one, the disk otherwise.** This is the shape ADR 0018/0020 already uses for manuscripts — open doc → live `Document`, closed → `DerivedManuscript` — and the same shape `ProjectStore.documentStore` already takes: a weak reference set by `ProjectWindow` at open time, nil when no window is open. Without it, `list_canvas` returns whatever the 750 ms debounce last wrote, so a scrap the writer typed two seconds ago is invisible to Claude and the next write tool would clobber it.

- [ ] **Step 1: Write the failing test**

`MaughamTests/MCP/Tools/CanvasReadToolTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class CanvasReadToolTests: XCTestCase {

    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CRT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    private func populatedScene() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in ["a", "b"].enumerated() {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 400, y: 0), width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [CanvasNodeID("a")],
                                    appearances: [CanvasNodeID("b")]))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "because of the ponchos"))
        return s
    }

    private func call(_ reg: ProjectRegistry, _ url: URL) async throws -> ListCanvasTool.Result {
        let id = ProjectIdentifier.id(for: url)
        let data = try await ListCanvasTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        return try JSONDecoder().decode(ListCanvasTool.Result.self, from: data)
    }

    func test_theCatalogIncludesTheReadToolExactlyOnce() {
        let methods = MCPToolCatalog.all.map { $0.method }
        XCTAssertEqual(methods.filter { $0 == "list_canvas" }.count, 1)
        XCTAssertEqual(Set(methods).count, methods.count, "duplicate tool methods in the catalog")
    }

    func test_itReportsScrapsRegionsAndLinesFromDisk() async throws {
        let (url, _, reg) = try await makeProject()
        CanvasStore(projectRoot: url).save(
            scene: populatedScene(),
            scraps: [CanvasNodeID("a"): "The falls at night.",
                     CanvasNodeID("b"): "October's doctor."])

        let result = try await call(reg, url)
        XCTAssertEqual(Set(result.scraps.map(\.text)),
                       ["The falls at night.", "October's doctor."])
        XCTAssertEqual(result.lines.first?.label, "because of the ponchos")
        XCTAssertEqual(result.lines.first?.from, "a")
    }

    /// §4.3: a region must answer "which of these live here and which are
    /// visiting" at a glance — including to Claude, which cannot see the chips.
    func test_itDistinguishesResidentsFromVisitors() async throws {
        let (url, _, reg) = try await makeProject()
        CanvasStore(projectRoot: url).save(
            scene: populatedScene(),
            scraps: [CanvasNodeID("a"): "one", CanvasNodeID("b"): "two"])

        let region = try XCTUnwrap(try await call(reg, url).regions.first)
        XCTAssertEqual(region.lives_here, ["a"])
        XCTAssertEqual(region.appears_here, ["b"])
        XCTAssertEqual(region.label, "Act II fog")
    }

    /// Claude must be able to tell what it wrote from what the writer wrote —
    /// otherwise a second pass re-reads its own output as source material.
    func test_itReportsAuthorshipAndPromotionMarks() async throws {
        let (url, _, reg) = try await makeProject()
        var scene = populatedScene()
        scene.setAuthor(.claude, for: CanvasNodeID("a"))
        scene.setPromotedItem("res-7", for: CanvasNodeID("b"))
        CanvasStore(projectRoot: url).save(
            scene: scene, scraps: [CanvasNodeID("a"): "one", CanvasNodeID("b"): "two"])

        let result = try await call(reg, url)
        let a = try XCTUnwrap(result.scraps.first { $0.id == "a" })
        let b = try XCTUnwrap(result.scraps.first { $0.id == "b" })
        XCTAssertEqual(a.author, "claude")
        XCTAssertNil(a.promoted_item_id)
        XCTAssertEqual(b.author, "human")
        XCTAssertEqual(b.promoted_item_id, "res-7")
    }

    /// The live model wins over the disk: the sidecar autosave is debounced, so
    /// a scrap typed two seconds ago is not on disk yet.
    func test_itReadsTheLiveCanvasWhenAWindowHasOne() async throws {
        let (url, store, reg) = try await makeProject()
        CanvasStore(projectRoot: url).save(scene: CanvasScene(), scraps: [:])

        let model = CanvasModel()
        model.load(projectRoot: url)
        model.withScene { s in
            var n = CanvasNode(id: CanvasNodeID("live"), kind: .scrap, origin: .zero, width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        model.setScrapText("not on disk yet", for: CanvasNodeID("live"))
        store.canvasModel = model

        let result = try await call(reg, url)
        XCTAssertEqual(result.scraps.map(\.text), ["not on disk yet"])
    }

    func test_anEmptyCanvasReportsEmptyRatherThanFailing() async throws {
        let (url, _, reg) = try await makeProject()
        let result = try await call(reg, url)
        XCTAssertTrue(result.scraps.isEmpty)
        XCTAssertTrue(result.regions.isEmpty)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertTrue(result.items.isEmpty)
    }

    /// Tripwire 10 / ADR 0004: a canvas at this plan's supported scale can hold
    /// more text than the transport line takes, and an overrun is a silent
    /// truncation at the socket rather than an error.
    func test_anOversizedCanvasFailsLoudlyRatherThanOverrunningTheTransport() async throws {
        let (url, store, reg) = try await makeProject()
        let model = CanvasModel()
        model.load(projectRoot: url)
        model.withScene { s in
            var n = CanvasNode(id: CanvasNodeID("big"), kind: .scrap, origin: .zero, width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        model.setScrapText(String(repeating: "x", count: MCPResponseBudget.maxTextBytes + 1_000),
                           for: CanvasNodeID("big"))
        store.canvasModel = model

        do {
            _ = try await call(reg, url)
            XCTFail("expected payload_too_large")
        } catch MCPError.toolError(let payload) {
            XCTAssertEqual(payload.error, "payload_too_large")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasReadToolTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'ListCanvasTool' in scope`.

- [ ] **Step 3: Add the live-canvas reference to `ProjectStore`**

In `Maugham/Stores/ProjectStore.swift`, beside `documentStore`:

```swift
    /// Optional reference to the live canvas for this project, set by
    /// `ProjectWindow` at open time. Same shape and same reason as
    /// `documentStore` above, and the same shape ADR 0018 uses for manuscripts:
    /// open → the live model, closed → the file. The sidecar autosave is
    /// debounced, so a canvas read that went straight to disk would miss
    /// whatever the writer typed in the last 750 ms — and a canvas WRITE that
    /// went straight to disk would then be overwritten by the pending save.
    public weak var canvasModel: CanvasModel?
```

In `ProjectWindow.load()` (a method — **not** `body`), beside `s.documentStore = ds`:

```swift
            s.canvasModel = canvas
```

`canvas` is the `@State private var canvas = CanvasModel()` 1C-b Task 4 added to `ProjectWindow`. `@State` holds it for the window's lifetime, so the weak reference stays live exactly as long as the window does.

- [ ] **Step 4: Write `Maugham/MCP/Tools/CanvasTools.swift`**

```swift
import Foundation
import MaughamCore

/// Where a canvas read or write goes.
///
/// Open window → the live `CanvasModel`; no window → the sidecar on disk. This
/// is ADR 0018's shape (open doc → live `Document`, closed → `DerivedManuscript`)
/// applied to the canvas, and it is not an optimisation: the sidecar save is
/// debounced, so the disk is stale by up to 750 ms whenever a writer is working.
enum CanvasSource {
    @MainActor
    static func read(store: ProjectStore, url: URL)
        -> (scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        if let model = store.canvasModel { return (model.scene, model.scraps) }
        return CanvasStore(projectRoot: url).load()
    }
}

/// `list_canvas(project_id)` — the planning canvas: scraps and their text, item
/// nodes, regions with residents and visitors kept apart, and lines with their
/// labels.
public enum ListCanvasTool: MCPTool {

    public struct Params: Codable {
        public let project_id: String
    }

    public struct Scrap: Codable, Equatable {
        public let id: String
        public let text: String
        /// "human" or "claude" — `AnnotationAuthor.SourceKind`.
        public let author: String
        public let promoted_item_id: String?
        public let home_region_id: String?
    }
    public struct Item: Codable, Equatable {
        public let id: String
        public let reference_id: String
        public let author: String
        public let home_region_id: String?
    }
    public struct Region: Codable, Equatable {
        public let id: String
        public let label: String
        public let bound_piece_id: String?
        public let collapsed: Bool
        /// Nodes that LIVE here — only these move with the region and only
        /// these are bound to its piece (§4.3, §4.4).
        public let lives_here: [String]
        /// Nodes that merely APPEAR here. References, never copies.
        public let appears_here: [String]
    }
    public struct Line: Codable, Equatable {
        public let id: String
        public let from: String
        public let to: String
        /// Free text, or null. A line has no type and asserts nothing (§5).
        public let label: String?
    }
    public struct Result: Codable, Equatable {
        public let scraps: [Scrap]
        public let items: [Item]
        public let regions: [Region]
        public let lines: [Line]
    }

    public static let method = "list_canvas"
    public static let description =
        "Read the project's planning canvas: loose scraps and their text, item nodes, " +
        "labelled regions (residents and visitors reported separately), and the untyped " +
        "lines between cards. Canvas content is scratch — it is not manuscript and not " +
        "durable until the writer promotes it."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let (scene, scraps) = CanvasSource.read(store: entry.store, url: entry.url)

        var scrapRows: [Scrap] = []
        var itemRows: [Item] = []
        for node in scene.nodes {
            let home = CanvasMembership.homeRegion(of: node.id, in: scene)?.raw
            switch node.kind {
            case .scrap:
                scrapRows.append(Scrap(id: node.id.raw, text: scraps[node.id] ?? "",
                                       author: node.author.rawValue,
                                       promoted_item_id: node.promotedItemID,
                                       home_region_id: home))
            case .item(let referenceId):
                itemRows.append(Item(id: node.id.raw, reference_id: referenceId,
                                     author: node.author.rawValue, home_region_id: home))
            }
        }

        let result = Result(
            scraps: scrapRows,
            items: itemRows,
            regions: scene.regions.map { region in
                Region(id: region.id.raw, label: region.label,
                       bound_piece_id: region.boundPieceID, collapsed: region.isCollapsed,
                       lives_here: region.homeMembers.map(\.raw).sorted(),
                       appears_here: region.appearances.map(\.raw).sorted())
            },
            lines: scene.lines.map {
                Line(id: $0.id.raw, from: $0.from.raw, to: $0.to.raw, label: $0.label)
            })

        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(result),
            hint: "The canvas holds more text than one response can carry. Read the "
                + "promoted artifacts instead (list_research, list_palette_cards), or ask "
                + "the writer which region matters.")
    }
}
```

- [ ] **Step 5: Register it and update the counts**

Add `ListCanvasTool.self` to `MCPToolCatalog.all` in `Maugham/MCP/MCPTool.swift`. Both `MCPToolsListHandler` and `MaughamApp.registerTools` derive from the catalog, so there is no third registration site.

**A new MCP tool breaks at least three tools-list tests** (onboarding milestone lesson). Fix all of them in this commit:

- `MaughamTests/MCP/MCPProtocolHandlersTests.swift` — add `"list_canvas"` to the hardcoded name set (around line 58).
- `CLAUDE.md` — the MCP row's `**52 tools**` becomes `**53 tools**`. `DocSyncTests.test_toolCountSyncedAcrossDocsAndCatalog` regexes `\*\*(\d+) tools\*\*` and compares against `MCPToolCatalog.all.count`.
- `Maugham/MCP/AREA.md` — `## Tool catalogue (52)` becomes `(53)`, plus a one-line entry for `list_canvas`.

Any count literal must be derived from `MCPToolCatalog.all.count` in code; the two doc numbers are the only hardcoded copies and `DocSyncTests` is what keeps them honest.

- [ ] **Step 6: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasReadToolTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 7 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: full Mac suite green. **A filtered run will not surface the tools-list breakage** — `MCPProtocolHandlersTests`, `MCPToolsListSmokeTest`, `MCPCatalogConsistencyTests` and `DocSyncTests` all react to a catalog change.

- [ ] **Step 7: Commit**

```bash
git add Maugham/MCP Maugham/Stores/ProjectStore.swift Maugham/Views/ProjectWindow.swift CLAUDE.md MaughamTests project.yml
git commit -m "feat(mcp): list_canvas (52→53) — Claude reads the planning canvas

Reads the live CanvasModel when a window has one and the sidecar otherwise:
the canvas autosave is debounced, so the disk is stale by up to 750ms
whenever a writer is working. Residents and visitors are reported apart."
```

---

### Task 8: `add_canvas_scraps` — paper → photo → Claude → canvas (spec §8A.2)

**Files:**
- Create: `Maugham/Canvas/CanvasClaudeAddition.swift`
- Modify: `Maugham/MCP/Tools/CanvasTools.swift`
- Modify: `Maugham/MCP/MCPTool.swift` (one catalog entry)
- Modify: `Maugham/MCP/AREA.md`, `CLAUDE.md` (tool count 53 → 54, plus the row)
- Modify: `MaughamTests/MCP/MCPProtocolHandlersTests.swift`
- Test: `MaughamTests/Canvas/CanvasClaudeAdditionTests.swift`
- Test: `MaughamTests/MCP/Tools/CanvasWriteToolTests.swift`

**Spec §8A.2 is the whole task, and its two constraints are load-bearing:**

1. *"Claude-created nodes must be visibly marked as such."* Every node this tool creates gets `author = .claude` (Task 1), which the renderer draws as a filled dot and `CanvasAccessibility` announces as "Read by Claude" (Task 2).
2. *"The reproduction corollary applies in full… the photo stays on the canvas, and what Claude derives from it is visibly tied to it. A region containing both the image and its derived scraps is the natural form… Derived nodes must never be placed loose where their origin is unrecoverable."* So this tool creates the source node **and** the region **and** the scraps in one act, and **there is no parameter that could place a derived node anywhere else**. The corollary is enforced by the signature, not by good behaviour.

**Constitutionally this is permitted, and the reasoning is recorded rather than assumed** (spec §8A.2, `docs/constitution.md` must-not #1 and its corollary): must-not #1 forbids AI *originating manuscript text*; the canvas is a planning surface in the parallel plane, exactly where Claude already writes annotations, translations and palette material. Nothing Claude puts on the canvas is manuscript, and nothing reaches the manuscript except through promotion (§6), which is a deliberate writer act.

**No accept/reject queue.** The canvas is scratch by construction: the writer moves, edits, deletes or promotes Claude's nodes exactly as they would their own. The marking is what makes that a real choice.

**Interfaces:**
- **Consumes:** `CanvasScene`, `CanvasNode`, `CanvasNodeID` (+ `.item(_:)`), `CanvasNodeKind`, `CanvasRegion`, `CanvasRegionID`, `CanvasMembership.join(_:home:in:)` / `addAppearance(_:to:in:)` / `homeRegion(of:in:)`, `CanvasScene.setAuthor(_:for:)`; `CanvasSource.read(store:url:)` and `ListCanvasTool`'s file (Task 7); `CanvasModel.beginGesture(_:)`/`withScene(persist:_:)`/`setScrapText(_:for:)`/`endGesture()`/`flush()`; `CanvasStore(projectRoot:).load()/save(scene:scraps:)`; `TreeWalk.first(in:where:)`; `MCPError.invalidArgument(_:)`.
- **Produces:** `enum CanvasClaudeAddition` — the six layout constants, `struct CreatedScrap: Equatable`, `struct Outcome: Equatable`, `static func apply(sourceReferenceID:sourceTitle:regionLabel:texts:to:) -> Outcome?`; `enum AddCanvasScrapsTool: MCPTool` with nested `Params`/`Result`.

- [ ] **Step 1: Write the failing tests**

`MaughamTests/Canvas/CanvasClaudeAdditionTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

final class CanvasClaudeAdditionTests: XCTestCase {

    private func apply(to scene: inout CanvasScene,
                       texts: [String] = ["The falls at night", "October's doctor"],
                       label: String = "Read from “page 3”") -> CanvasClaudeAddition.Outcome? {
        CanvasClaudeAddition.apply(sourceReferenceID: "r-9", sourceTitle: "page 3",
                                   regionLabel: label, texts: texts, to: &scene)
    }

    /// Empty canvas. The source node is 180x120 at (0,0). Scraps are 240 wide
    /// and 96 tall on a 24pt gap, so the first sits at y = 0 + 120 + 24 = 144
    /// and the second at y = 144 + 96 + 24 = 264. The block's union is
    /// x 0…240, y 0…360; padded by 24 that is (-24, -24, 288, 408).
    func test_onAnEmptyCanvasTheBlockLandsAtTheOriginAndTheRegionEnclosesIt() {
        var s = CanvasScene()
        let outcome = apply(to: &s)!
        XCTAssertEqual(s.node(outcome.sourceNodeID)?.frame,
                       CGRect(x: 0, y: 0, width: 180, height: 120))
        XCTAssertEqual(s.node(outcome.created[0].id)?.frame,
                       CGRect(x: 0, y: 144, width: 240, height: 96))
        XCTAssertEqual(s.node(outcome.created[1].id)?.frame,
                       CGRect(x: 0, y: 264, width: 240, height: 96))
        XCTAssertEqual(s.region(outcome.regionID)?.frame,
                       CGRect(x: -24, y: -24, width: 288, height: 408))
    }

    /// A populated canvas. The tallest existing content ends at y = 80, so the
    /// block starts 48 below it at y = 128: the source is (0,128,180,120), the
    /// one scrap is (0,272,240,96), and the padded union is (-24,104,288,288).
    func test_theBlockLandsBelowExistingContentSoItNeverOverlaps() {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("existing"), kind: .scrap, origin: .zero, width: 240)
        n.cachedHeight = 80
        s.insert(n)
        let outcome = apply(to: &s, texts: ["The falls at night"])!
        XCTAssertEqual(s.node(outcome.sourceNodeID)?.frame,
                       CGRect(x: 0, y: 128, width: 180, height: 120))
        XCTAssertEqual(s.node(outcome.created[0].id)?.frame,
                       CGRect(x: 0, y: 272, width: 240, height: 96))
        XCTAssertEqual(s.region(outcome.regionID)?.frame,
                       CGRect(x: -24, y: 104, width: 288, height: 288))
    }

    // MARK: - The corollary

    func test_everyDerivedScrapAndTheSourceAreInTheOneRegion() {
        var s = CanvasScene()
        let outcome = apply(to: &s)!
        let region = try? XCTUnwrap(s.region(outcome.regionID))
        let members = (region?.homeMembers ?? []).union(region?.appearances ?? [])
        XCTAssertTrue(members.contains(outcome.sourceNodeID),
                      "the photo stays on the canvas beside what was read off it")
        for scrap in outcome.created {
            XCTAssertTrue(region?.homeMembers.contains(scrap.id) == true,
                          "a derived node must never land loose — its origin would be "
                          + "unrecoverable (constitution, reproduction corollary)")
        }
    }

    func test_theSourceNodeIsTheItemNodeForThatResearchID() {
        var s = CanvasScene()
        let outcome = apply(to: &s)!
        XCTAssertEqual(outcome.sourceNodeID, CanvasNodeID.item("r-9"))
        XCTAssertEqual(outcome.sourceNodeID.raw, "item:r-9")
        if case .item(let ref)? = s.node(outcome.sourceNodeID)?.kind {
            XCTAssertEqual(ref, "r-9")
        } else {
            XCTFail("the source must be an item node, not a scrap")
        }
    }

    /// §4.3: one home, many appearances. If the writer had already filed the
    /// photo somewhere, Claude's region must not steal it.
    func test_aSourceAlreadyFiledKeepsItsHomeAndJoinsAsAnAppearance() {
        var s = CanvasScene()
        var img = CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                             origin: CGPoint(x: 600, y: 0), width: 180)
        img.cachedHeight = 120
        s.insert(img)
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Photos",
                                    frame: CGRect(x: 560, y: -40, width: 300, height: 220),
                                    homeMembers: [CanvasNodeID.item("r-9")]))
        let outcome = apply(to: &s)!
        XCTAssertEqual(CanvasMembership.homeRegion(of: .item("r-9"), in: s), CanvasRegionID("r1"))
        XCTAssertTrue(s.region(outcome.regionID)?.appearances.contains(.item("r-9")) == true)
        XCTAssertEqual(s.node(.item("r-9"))?.origin, CGPoint(x: 600, y: 0),
                       "an existing source must not be moved out from under the writer")
    }

    // MARK: - Marking

    func test_derivedScrapsAreMarkedAsClaudesAndTheirTextIsReturned() {
        var s = CanvasScene()
        let outcome = apply(to: &s)!
        XCTAssertEqual(outcome.created.map(\.text), ["The falls at night", "October's doctor"])
        for scrap in outcome.created {
            XCTAssertEqual(s.node(scrap.id)?.author, .claude)
        }
    }

    /// The photograph is the writer's own page; Claude only placed it. What the
    /// mark answers is "did a person write these words, or did Claude read them
    /// off a page" — and for the image the honest answer is the former.
    func test_theSourceNodeIsNotMarkedAsClaudeAuthored() {
        var s = CanvasScene()
        let outcome = apply(to: &s)!
        XCTAssertEqual(s.node(outcome.sourceNodeID)?.author, .human)
    }

    // MARK: - Refusals

    func test_noTextsProducesNoOutcomeAndNoRegion() {
        var s = CanvasScene()
        XCTAssertNil(apply(to: &s, texts: []))
        XCTAssertNil(apply(to: &s, texts: ["   ", "\n"]))
        XCTAssertTrue(s.regions.isEmpty, "an empty reading must not leave an empty region behind")
        XCTAssertTrue(s.isEmpty)
    }

    func test_blankTextsAreDroppedRatherThanCreatingEmptyCards() {
        var s = CanvasScene()
        let outcome = apply(to: &s, texts: ["The falls at night", "   "])!
        XCTAssertEqual(outcome.created.count, 1)
    }

    func test_anEmptyRegionLabelFallsBackToOneNamingTheSource() {
        var s = CanvasScene()
        let outcome = apply(to: &s, label: "")!
        XCTAssertEqual(s.region(outcome.regionID)?.label, "Read from “page 3”")
    }
}
```

`MaughamTests/MCP/Tools/CanvasWriteToolTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class CanvasWriteToolTests: XCTestCase {

    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CWT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        // The photographed page, already in the project — this is what the
        // phone Capture inbox promotes into (spec §8A.2).
        let photo = try await store.addResearchTextNote(parentId: nil, title: "page 3")
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg, photo.id)
    }

    private func call(_ reg: ProjectRegistry, _ url: URL,
                      sourceID: String, texts: [String] = ["The falls at night"],
                      label: String? = nil) async throws -> AddCanvasScrapsTool.Result {
        var request: [String: Any] = [
            "project_id": ProjectIdentifier.id(for: url),
            "source_research_id": sourceID,
            "scraps": texts,
        ]
        if let label { request["region_label"] = label }
        let data = try await AddCanvasScrapsTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: request), registry: reg)
        return try JSONDecoder().decode(AddCanvasScrapsTool.Result.self, from: data)
    }

    func test_theCatalogIncludesTheWriteToolExactlyOnce() {
        let methods = MCPToolCatalog.all.map { $0.method }
        XCTAssertEqual(methods.filter { $0 == "add_canvas_scraps" }.count, 1)
    }

    /// The corollary, enforced by the SIGNATURE: there is no parameter that
    /// could put a derived node anywhere but the region holding its source.
    func test_theSchemaHasNoWayToPlaceANodeOutsideTheSourcesRegion() throws {
        let schema = try JSONSerialization.jsonObject(
            with: Data(AddCanvasScrapsTool.inputSchemaJSON.utf8)) as! [String: Any]
        let properties = schema["properties"] as! [String: Any]
        XCTAssertEqual(Set(properties.keys),
                       ["project_id", "source_research_id", "scraps", "region_label"],
                       "no x/y, no node_id, no region_id — the region is DERIVED from the "
                       + "source, never addressed by the caller")
        XCTAssertEqual(Set(schema["required"] as! [String]),
                       ["project_id", "source_research_id", "scraps"],
                       "source_research_id is required: a derived node with no recoverable "
                       + "origin must be unrepresentable")
    }

    func test_itWritesToDiskWhenNoWindowIsOpen() async throws {
        let (url, _, reg, photoID) = try await makeProject()
        let result = try await call(reg, url, sourceID: photoID,
                                    texts: ["The falls at night", "October's doctor"])

        let (scene, scraps) = CanvasStore(projectRoot: url).load()
        XCTAssertEqual(result.node_ids.count, 2)
        XCTAssertEqual(Set(result.node_ids.map { scraps[CanvasNodeID($0)] }),
                       ["The falls at night", "October's doctor"])
        for id in result.node_ids {
            XCTAssertEqual(scene.node(CanvasNodeID(id))?.author, .claude)
        }
        let region = try XCTUnwrap(scene.region(CanvasRegionID(result.region_id)))
        XCTAssertTrue(region.homeMembers.contains(CanvasNodeID(result.source_node_id))
                      || region.appearances.contains(CanvasNodeID(result.source_node_id)))
    }

    func test_itWritesThroughTheLiveModelAndTheWriterCanTakeItBack() async throws {
        let (url, store, reg, photoID) = try await makeProject()
        let model = CanvasModel()
        model.load(projectRoot: url)
        model.undoManager.groupsByEvent = false
        store.canvasModel = model

        _ = try await call(reg, url, sourceID: photoID)
        XCTAssertEqual(model.scene.count, 2, "the source node and one derived scrap")
        XCTAssertEqual(model.scene.regions.count, 1)

        model.undoManager.undo()
        XCTAssertTrue(model.scene.isEmpty,
                      "the writer deletes Claude's nodes exactly as they would their own "
                      + "(§8A.2) — including with ⌘Z")
        XCTAssertTrue(model.scene.regions.isEmpty)
    }

    func test_theDefaultRegionLabelNamesTheSource() async throws {
        let (url, store, reg, photoID) = try await makeProject()
        let model = CanvasModel()
        model.load(projectRoot: url)
        store.canvasModel = model
        let result = try await call(reg, url, sourceID: photoID)
        XCTAssertEqual(model.scene.region(CanvasRegionID(result.region_id))?.label,
                       "Read from “page 3”")
    }

    func test_anUnknownSourceResearchIDFailsLoudly() async throws {
        let (url, _, reg, _) = try await makeProject()
        do {
            _ = try await call(reg, url, sourceID: "not-a-real-id")
            XCTFail("expected a refusal")
        } catch MCPError.invalidArgument {
            // ok — tools fail loudly on unknown ids
        }
        XCTAssertTrue(CanvasStore(projectRoot: url).load().scene.isEmpty)
    }

    func test_anEmptyScrapListFailsLoudlyAndLeavesNoRegion() async throws {
        let (url, _, reg, photoID) = try await makeProject()
        do {
            _ = try await call(reg, url, sourceID: photoID, texts: ["  "])
            XCTFail("expected a refusal")
        } catch MCPError.invalidArgument {
            // ok
        }
        XCTAssertTrue(CanvasStore(projectRoot: url).load().scene.regions.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasClaudeAdditionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasClaudeAddition' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/CanvasClaudeAddition.swift`**

```swift
import Foundation
import MaughamCore

/// The one scene mutation behind `add_canvas_scraps`.
///
/// Pure and `inout`-only, with no store, no I/O and no `await`, so the tool's
/// two execution paths — the live `CanvasModel` and the sidecar on disk —
/// share one definition of what happens. Two hand-written copies of this would
/// be two answers to "where did Claude put things".
///
/// **The reproduction corollary is enforced here, structurally.** The source
/// node, the region and the derived scraps are created together or not at all,
/// and nothing in the signature can separate them. `docs/constitution.md`:
/// *"the reproduction and its source must be checkable side by side"*.
enum CanvasClaudeAddition {

    static let sourceNodeWidth: CGFloat = 180
    static let sourceNodeHeight: CGFloat = 120
    static let scrapWidth: CGFloat = 240
    /// A placeholder height so the new nodes are hit-testable and drawable
    /// immediately; the real measurement replaces it on the next layout pass
    /// (1C-a §7A.3 — width is authoritative, height is derived).
    static let estimatedScrapHeight: CGFloat = 96
    static let gap: CGFloat = 24
    static let regionPadding: CGFloat = 24
    /// Clearance between existing content and the new block, so Claude never
    /// drops cards on top of the writer's arrangement.
    static let blockGap: CGFloat = 48

    struct CreatedScrap: Equatable {
        let id: CanvasNodeID
        let text: String
    }

    struct Outcome: Equatable {
        let regionID: CanvasRegionID
        let sourceNodeID: CanvasNodeID
        let created: [CreatedScrap]
    }

    /// Returns nil when there is nothing to add — and in that case the scene is
    /// untouched, so an empty reading never leaves an empty region behind.
    @discardableResult
    static func apply(sourceReferenceID: String,
                      sourceTitle: String,
                      regionLabel: String,
                      texts: [String],
                      to scene: inout CanvasScene) -> Outcome? {
        let bodies = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !bodies.isEmpty else { return nil }

        let sourceNodeID = CanvasNodeID.item(sourceReferenceID)
        let sourceFrame: CGRect
        if let existing = scene.node(sourceNodeID)?.frame {
            // The writer already put the photo somewhere. Leave it exactly
            // where it is — Claude does not rearrange the canvas.
            sourceFrame = existing
        } else {
            let origin = blockOrigin(in: scene)
            var node = CanvasNode(id: sourceNodeID,
                                  kind: .item(referenceId: sourceReferenceID),
                                  origin: origin, width: sourceNodeWidth)
            node.cachedHeight = sourceNodeHeight
            // NOT marked as Claude's: the photograph is the writer's own page.
            // The mark answers "did a person write these words or did Claude
            // read them off a page", and for the image that is the former.
            node.z = scene.topZ + 1
            scene.insert(node)
            sourceFrame = CGRect(origin: origin, size: CGSize(width: sourceNodeWidth,
                                                              height: sourceNodeHeight))
        }

        var created: [CreatedScrap] = []
        var y = sourceFrame.maxY + gap
        for body in bodies {
            let id = newScrapID(in: scene)
            var node = CanvasNode(id: id, kind: .scrap,
                                  origin: CGPoint(x: sourceFrame.minX, y: y),
                                  width: scrapWidth)
            node.cachedHeight = estimatedScrapHeight
            node.author = .claude
            node.z = scene.topZ + 1
            scene.insert(node)
            created.append(CreatedScrap(id: id, text: body))
            y += estimatedScrapHeight + gap
        }

        let label = regionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let regionID = newRegionID(in: scene)
        var frame = sourceFrame
        for scrap in created {
            if let f = scene.node(scrap.id)?.frame { frame = frame.union(f) }
        }
        scene.insertRegion(CanvasRegion(
            id: regionID,
            label: label.isEmpty ? "Read from “\(sourceTitle)”" : label,
            frame: frame.insetBy(dx: -regionPadding, dy: -regionPadding)))

        for scrap in created {
            CanvasMembership.join(scrap.id, home: regionID, in: &scene)
        }
        // §4.3: one home, many appearances. If the writer had already filed the
        // photo, this region cites it rather than stealing it — a visitor is not
        // luggage.
        if CanvasMembership.homeRegion(of: sourceNodeID, in: scene) == nil {
            CanvasMembership.join(sourceNodeID, home: regionID, in: &scene)
        } else {
            CanvasMembership.addAppearance(sourceNodeID, to: regionID, in: &scene)
        }

        return Outcome(regionID: regionID, sourceNodeID: sourceNodeID, created: created)
    }

    /// Below everything already on the canvas, or the origin on an empty one.
    private static func blockOrigin(in scene: CanvasScene) -> CGPoint {
        var bottom: CGFloat?
        for node in scene.unorderedNodes {
            guard let f = node.frame else { continue }
            bottom = max(bottom ?? f.maxY, f.maxY)
        }
        for region in scene.regions {
            bottom = max(bottom ?? region.frame.maxY, region.frame.maxY)
        }
        guard let bottom else { return .zero }
        return CGPoint(x: 0, y: bottom + blockGap)
    }

    /// Mirrors `CanvasInteraction.createRegion`'s id minting (1C-b Task 6) and
    /// `CanvasInteraction.newLineID` (Task 3), so the canvas has one id shape.
    private static func newScrapID(in scene: CanvasScene) -> CanvasNodeID {
        var id = CanvasNodeID(String(UUID().uuidString.prefix(8)).lowercased())
        while scene.node(id) != nil {
            id = CanvasNodeID(String(UUID().uuidString.prefix(8)).lowercased())
        }
        return id
    }

    private static func newRegionID(in scene: CanvasScene) -> CanvasRegionID {
        var id = CanvasRegionID(String(UUID().uuidString.prefix(8)).lowercased())
        while scene.region(id) != nil {
            id = CanvasRegionID(String(UUID().uuidString.prefix(8)).lowercased())
        }
        return id
    }
}
```

- [ ] **Step 4: Add the tool to `Maugham/MCP/Tools/CanvasTools.swift`**

```swift
/// `add_canvas_scraps(project_id, source_research_id, scraps[], region_label?)`
/// — spec §8A.2's paper → photo → Claude → canvas route.
///
/// **Every created node is marked as Claude's**, and the source and everything
/// derived from it land in ONE region, in one act. There is deliberately no
/// parameter for a position, a node id or a region id: the corollary in
/// `docs/constitution.md` ("the reproduction and its source must be checkable
/// side by side") is enforced by what this signature cannot express, not by
/// Claude behaving well.
///
/// Nothing here is manuscript, and nothing reaches the manuscript except
/// through promotion (§6), which is a deliberate writer act.
public enum AddCanvasScrapsTool: MCPTool {

    public struct Params: Codable {
        public let project_id: String
        public let source_research_id: String
        public let scraps: [String]
        public let region_label: String?
    }

    public struct Result: Codable, Equatable {
        public let region_id: String
        public let source_node_id: String
        public let node_ids: [String]
    }

    public static let method = "add_canvas_scraps"
    public static let description =
        "Add scraps to the project's planning canvas, read off an image or note that is " +
        "already in the project (source_research_id — typically a photographed page from " +
        "the Capture inbox). The source and everything derived from it are placed together " +
        "in one new region, and every created card is marked as Claude's, so the writer can " +
        "always see what was read off which page. Canvas content is scratch: it is not " +
        "manuscript, and it becomes durable only when the writer promotes it."
    public static let inputSchemaJSON = #"""
    {"type":"object","properties":{"project_id":{"type":"string"},"source_research_id":{"type":"string"},"scraps":{"type":"array","items":{"type":"string"}},"region_label":{"type":"string"}},"required":["project_id","source_research_id","scraps"]}
    """#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)

        // Fail loudly on an unknown id — the house rule for every tool, and here
        // it is also what keeps a derived node's origin recoverable.
        guard let source = TreeWalk.first(in: entry.store.manifest.research,
                                          where: { $0.id == params.source_research_id }) else {
            throw MCPError.invalidArgument(
                "source_research_id not found: \(params.source_research_id)")
        }
        guard params.scraps.contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw MCPError.invalidArgument("scraps must contain at least one non-empty string")
        }

        let label = params.region_label ?? ""
        var outcome: CanvasClaudeAddition.Outcome?

        if let model = entry.store.canvasModel {
            // One gesture, so ⌘Z takes the whole addition back. §8A.2: "the
            // writer moves, edits, deletes or promotes Claude's nodes exactly as
            // they would their own" — including with undo.
            model.beginGesture("Add Cards from Claude")
            model.withScene { scene in
                outcome = CanvasClaudeAddition.apply(
                    sourceReferenceID: source.id, sourceTitle: source.title,
                    regionLabel: label, texts: params.scraps, to: &scene)
            }
            for scrap in outcome?.created ?? [] {
                model.setScrapText(scrap.text, for: scrap.id)
            }
            model.endGesture()
            model.flush()
        } else {
            let store = CanvasStore(projectRoot: entry.url)
            var (scene, scraps) = store.load()
            outcome = CanvasClaudeAddition.apply(
                sourceReferenceID: source.id, sourceTitle: source.title,
                regionLabel: label, texts: params.scraps, to: &scene)
            for scrap in outcome?.created ?? [] { scraps[scrap.id] = scrap.text }
            store.save(scene: scene, scraps: scraps)
        }

        guard let outcome else {
            throw MCPError.invalidArgument("scraps must contain at least one non-empty string")
        }
        return try JSONEncoder().encode(Result(
            region_id: outcome.regionID.raw,
            source_node_id: outcome.sourceNodeID.raw,
            node_ids: outcome.created.map(\.id.raw)))
    }
}
```

- [ ] **Step 5: Register it and update the counts**

Add `AddCanvasScrapsTool.self` to `MCPToolCatalog.all`, then — in the same commit, exactly as Task 7 — `"add_canvas_scraps"` into `MCPProtocolHandlersTests`' name set, `**53 tools**` → `**54 tools**` in CLAUDE.md, and `## Tool catalogue (53)` → `(54)` plus a row in `Maugham/MCP/AREA.md`.

- [ ] **Step 6: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasClaudeAdditionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 10 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasWriteToolTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 7 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: full Mac suite green — the catalog changed again.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasClaudeAddition.swift Maugham/MCP CLAUDE.md MaughamTests project.yml
git commit -m "feat(mcp): add_canvas_scraps (53→54) — paper → photo → Claude → canvas

Every created card is marked as Claude's, and the source image plus
everything read off it land in one region in one act. There is no
parameter for a position or a region id: the constitution's reproduction
corollary is enforced by what the signature cannot express."
```

---

### Task 9: The readiness guard, the ADR, and the milestone sweep

**Files:**
- Test: `MaughamTests/Canvas/CanvasReadinessTests.swift`
- Modify: `Maugham/Canvas/AREA.md` (created by 1C-a Task 17, extended by 1C-b Task 8)
- Create: `docs/adr/0027-canvas-promotion.md`; modify `docs/adr/README.md`
- Modify: `CLAUDE.md` (tripwire table)
- Modify: `docs/guide/` (the Plan-persona topic 1C-a Task 17 created), `docs/roadmap.md`, `docs/problem-map.md`

**Interfaces:**
- **Consumes:** everything Tasks 1–8 shipped; `ProjectStore.projectWordCount` (`Maugham/Stores/ProjectStore.swift`), `ProjectStore.manifest.structure`, `CanvasStore.scrapsRelativePath` (1C-a Task 5, `"canvas.md"`).
- **Produces:** no production Swift. One test file, and documentation.

- [ ] **Step 1: The readiness guard**

Spec §6.1 and umbrella §7/§9: *"Readiness counts promoted artifacts and stays silent about the canvas."* The canvas is unmeasurable by construction, and counting it would turn a thinking surface into a scoreboard — most of what is on it is not anything yet, so counting it would make a mess look like a deficit.

This is a **guard**, and it may well be all-green with no production change. That is a fine outcome; the test is the deliverable.

`MaughamTests/Canvas/CanvasReadinessTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class CanvasReadinessTests: XCTestCase {

    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, try await ProjectStore.load(from: tmp))
    }

    /// 500 words of scrap must not read as 500 words of progress.
    func test_scrapsDoNotCountTowardTheProjectWordCount() async throws {
        let (url, store) = try await makeProject()
        let before = store.projectWordCount

        var scene = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        n.cachedHeight = 80
        scene.insert(n)
        CanvasStore(projectRoot: url).save(
            scene: scene,
            scraps: [CanvasNodeID("a"): String(repeating: "word ", count: 500)])

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.projectWordCount, before,
                       "canvas.md must not be counted as manuscript")
    }

    /// `canvas.md` is a root-level `.md` file. Anything that globs for those and
    /// assumes manuscript would sweep it up.
    func test_canvasMdIsNotABinderDocument() async throws {
        let (url, _) = try await makeProject()
        CanvasStore(projectRoot: url).save(
            scene: CanvasScene(), scraps: [CanvasNodeID("a"): "The falls"])

        let reloaded = try await ProjectStore.load(from: url)
        let paths = TreeWalk.collect(in: reloaded.manifest.structure, where: { _ in true })
            .compactMap(\.path)
        XCTAssertFalse(paths.contains(CanvasStore.scrapsRelativePath),
                       "canvas.md is scrap content, not a binder document")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(CanvasStore.scrapsRelativePath).path),
            "…and it is genuinely on disk, so this assertion is not vacuous")
    }

    /// Promotion is what readiness counts, and it counts it because the artifact
    /// is real — not because the canvas told it so.
    func test_aPromotedScrapCountsExactlyOnceAsAResearchNote() async throws {
        let (url, store) = try await makeProject()
        let model = CanvasModel()
        model.load(projectRoot: url)
        model.withScene { s in
            var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        model.setScrapText("The falls at night\n\nbody", for: CanvasNodeID("a"))

        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                                  scraps: model.scraps, piece: nil, in: model.scene)!
        _ = try await PromotionPerformer(store: store, model: model).perform(plan)
        XCTAssertEqual(store.manifest.research.count, 1)
        XCTAssertEqual(model.scene.count, 1, "and the scrap is still on the canvas")
    }
}
```

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasReadinessTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 3 tests. **If any fails, that is a real leak** — something is globbing root-level `.md` files as manuscript. Fix it by excluding `CanvasStore.scrapsRelativePath` where the glob lives, and say so in the task report.

- [ ] **Step 2: Extend `Maugham/Canvas/AREA.md`**

Add a **"Lines"** section:

- Untyped, and why: Kinopio shipped author-typed connections for years and deleted them in April 2026 for confusing first-time users. `CanvasLine` has no `kind` and must not gain one.
- ⇧-drag from card to card draws one; double-click labels it; ⌫ deletes the selected line then falls through to the selected region.
- Endpoints are node **centres**, resolved per frame; a line to an unmeasured node is not drawn and not clickable, because drawing to a guessed position twitches the moment the measurement arrives.
- Deleting a node deletes its lines (`CanvasScene.remove`), and self-lines are rejected in `insertLine` — the loader goes through `insertLine` so that rule is single-sourced.
- `CanvasLineHit.distance` clamps at both endpoints. Without the clamp, a click far beyond a card still lands on the infinite line the segment sits on.
- Lines are hit-tested **only where no card was hit**, so a line running under a card never steals that card's click.

Add a **"Promotion"** section:

- §6's table, and that the list in `PromotionTarget` *is* that table — it must not grow without amending the spec.
- The two deliberate defaults: nothing selected when the sheet opens; the link offer arrives declined. Both have named symptoms if "improved".
- What promotion discards, and that being lossy is a feature (§6.1, Scapple → Scrivener).
- **Promotion never removes the scrap.** The canvas is scratch and stays scratch.
- **A line promotes only between two already-promoted scraps**, with the reason: `[[X]]` resolves against the manifest (`ProjectStore.resolveDocumentId(forTitle:)`, and `ListAllLinksTool`'s title index over documents *and* research items), and a scrap is in neither. `Promotion.blockedReason` is where the writer is told.
- `PromotionPerformer` is `@MainActor` and `async` because every `ProjectStore` creation API is; **no `inout` may appear on that path** — an `inout` cannot cross an `await`. An earlier draft of the 1C-c plan declared it synchronous and could not have compiled.
- The `flushPendingSave()` before every body write, with the symptom: a queued 750 ms `scheduleFileSave` fires after the write and blanks the note (`AddNoteTool.swift:48-55`).
- Validate first, write second: a refused promotion leaves nothing behind.

Add an **"MCP"** section:

- `list_canvas` reads the **live** `CanvasModel` when a window has one and the sidecar otherwise (`CanvasSource.read`). Straight-to-disk would be up to 750 ms stale, and a straight-to-disk *write* would then be overwritten by the pending save.
- `add_canvas_scraps` creates the source item node, the region and the derived scraps in one act, marks the scraps `.claude`, and leaves the source `.human`. **There is no parameter for a position, a node id or a region id**, and that absence is the constitution's reproduction corollary made structural. Adding one would be a constitutional change, not a feature.
- The live-model path brackets the whole addition in one `beginGesture`/`endGesture`, so ⌘Z takes it back.

Add to the "Who owns what" paragraph: `ProjectStore.canvasModel` is the live-canvas reference, set in `ProjectWindow.load()`, same shape and same reason as `ProjectStore.documentStore`.

- [ ] **Step 3: Write `docs/adr/0027-canvas-promotion.md`**

Check the highest existing number first — 1C-a takes 0026 and 1C-b amends it, so 0027 unless something landed since:

```bash
ls docs/adr/ | sort | tail -3
```

Record, citing constitution principles by name per CLAUDE.md:

- **Lines are untyped** — Kinopio's April 2026 removal after years in production; the optional free-text label is the empirically supported floor; the precedence statement (§5) is in the promotion sheet's footer, because Obsidian's three-year confusion is a consequence of never answering "which of these is the real relationship?"
- **Promotion is one previewable verb** — Scrivener's Commit as the precedent; Shipman & Marshall's conditional licence for machine inference (safe **iff** the writer sees it and can reject it cheaply); why the same inference applied silently is forbidden.
- **A line promotes only between promoted ends**, with the resolver evidence. **This is a deviation from a literal reading of spec §6** ("when both ends are text") and must be recorded as one: the literal reading produces a link that resolves to nothing.
- **The gesture question (§10) is resolved** as a menu command on the current selection at ⌘⇧↩, with the rail and the context menu rejected for stated reasons, the ⌘⇧P collision noted, and the fallback named.
- **The MCP write surface (§10) is resolved** as one tool whose region is derived rather than addressed, and why that is the corollary enforced structurally.
- **Claude-authored nodes reuse `AnnotationAuthor.SourceKind`** rather than a second provenance enum.
- **The residual**: the source node renders as 1C-a's placeholder until 1C-d resolves item thumbnails. The tie is complete; the picture is not.

- [ ] **Step 4: Add the tripwire**

Add to CLAUDE.md's tripwire table. 1C-a adds 25 and 26 and 1C-b adds 27, so **this is 28** — confirm with `grep -n "^| 2[5-9] " CLAUDE.md` before writing:

| # | Rule | Why (1 clause) | Enforced / more |
|---|---|---|---|
| 28 | Nothing on the canvas becomes durable except through `PromotionPerformer`, and Claude cannot create a canvas node without its source in the same region — no position/node/region parameter may be added to `add_canvas_scraps` | the promotion seam is the whole reason the canvas can be scratch, and a derived node whose origin is unrecoverable is the constitution's reproduction corollary broken | `PromotionTests`, `PromotionPerformerTests`, `CanvasWriteToolTests.test_theSchemaHasNoWayToPlaceANodeOutsideTheSourcesRegion`; ADR 0027 |

- [ ] **Step 5: Sweep the guide**

Find the Plan-persona topic 1C-a Task 17 created and 1C-b Task 8 extended:

```bash
grep -rln "canvas" docs/guide/
```

Describe only what **ships** (rule 7): drawing a line with ⇧-drag, double-clicking it to label it, ⌫ to remove it; Promote… (⌘⇧↩) on the selected line, region or the card you are typing in, what each can become, and that promoting never takes the card off the canvas; that the link offer is optional and off by default; and — plainly, once — that wiki-links are durable and canvas lines are scratch. Say that a card Claude added carries a mark and can be moved, edited, deleted or promoted like any other.

Do **not** describe item thumbnails or dragging research in; those are 1C-d.

- [ ] **Step 6: Sweep the milestone**

M1C is complete across 1C-a/b/c except 1C-d's §8A work. Sweep for now-false claims (rule 10):

```bash
grep -rn "canvas\|Canvas" docs/roadmap.md docs/problem-map.md docs/constitution.md CLAUDE.md | grep -iv corkboard
```

- `docs/roadmap.md`: the canvas milestone entry gains lines, promotion and the two MCP tools. **Do not flip it to ✓ yet** — §8A.1's images are inside M1C (spec §8A.1 says so explicitly and forbids citing it as authorising their omission), and 1C-d is unwritten. Say what is in and what is outstanding.
- `docs/problem-map.md`: the planning rows move from • toward ~ or ✓ as the evidence supports. "Get the mess out of my head and into one place" is now served; "turn a cluster into a piece" is served by the binding plus promotion.
- `docs/constitution.md`: no change is expected. If §8A.2's write path seems to need one, **stop and raise it** rather than editing the constitution inside an implementation task.

- [ ] **Step 7: Full verification**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/DocSyncTests CODE_SIGNING_ALLOWED=NO`
Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: all green. The phone suite must be untouched — this slice adds no MaughamCore and no phone code (spec §9), so a phone failure means something leaked into the shared package.

- [ ] **Step 8: Commit**

```bash
git add docs Maugham/Canvas/AREA.md CLAUDE.md MaughamTests/Canvas/CanvasReadinessTests.swift project.yml
git commit -m "docs(canvas): lines, promotion and the MCP canvas surface; ADR 0027; tripwire 28

Readiness stays silent about the canvas, and there is now a test that says
so. The roadmap entry is NOT flipped to ✓: §8A.1's images are inside M1C
and 1C-d is unwritten."
```

---

## Whole-slice verification

- [ ] Full Mac suite, full phone suite, Release build — all green
- [ ] **Whole-branch review of the 1C-c diff.** Per-task reviews cannot see emergent interactions (the T5×T6 precedent on the unified-undo milestone). Look especially at Task 3's edits to 1C-b's gesture routing and Task 6's `CanvasView` initialiser change.
- [ ] **Whole-milestone review of 1C-a + 1C-b + 1C-c together.** The scene model has now grown through three schema versions and three plans; per-slice reviews cannot see that.
- [ ] **MCP dev-app smoke through the raw socket** — `mcp__maugham_test__*` plus `list_canvas` on a real project with scraps, a region holding both residents and visitors, a labelled line, and a Claude-authored card; then `add_canvas_scraps` against a real research item and `list_canvas` again to confirm the region came back with the source inside it. This has caught defects after all tests were green (the commonmark-fountain milestone's E1), and it is the standard pre-smoke.
- [ ] **Smoke, by hand:**
  1. ⇧-drag from one scrap to another → a line appears → double-click it → label it → ⌘Z → the label goes → ⌘⇧Z → it comes back
  2. select the line → ⌫ → the line goes and both cards stay → ⌘Z → it comes back
  3. delete a card the line touched → the line goes with it
  4. click into a scrap → **Promote… (⌘⇧↩)** → the sheet opens with nothing selected → choose Research note → the preview shows the title, the body and "research/" → edit the title → Promote → the note is in the research tree AND the scrap is still on the canvas, now carrying the promoted mark
  5. promote the second scrap the same way → select the line between them → Promote… → it now offers Wiki-link (before, it said to promote both cards first) → Promote → the link is in the first note
  6. select a region → Promote… → Palette card → the link offer arrives **unchecked** → decline → Promote → the card is on the wall and no links were written → promote again and accept → exactly the offered links appear
  7. select the region → Promote… → Piece binding → pick a piece → the binding shows in the region inspector
  8. read the precedence line in the sheet footer — does it read plainly at the moment it matters?
  9. quit and reopen → lines, labels, regions, marks and bindings all survive
  10. **Does ⌘⇧↩ read as discoverable, or is the rail/context-menu fallback needed?** (§10's flagged question)

## M1 completion

1C-c is not the last slice of M1C: **1C-d owns spec §8A** (dragging research in, images, item thumbnails, collapse-to-canvas), and §8A.1 states plainly that images are inside this milestone and that no plan may cite it as authorising their omission. This plan's one residual — the source image node rendering as a placeholder — is 1C-d's to close.

**M1 is complete only when 1A (the spine) is also in.** 1B is merged; 1C-a/b/c/d land on the same branch line. **Do not push or tag until 1A, 1B and the whole of 1C are in.** Slicing the implementation is fine; slicing the release is not.

