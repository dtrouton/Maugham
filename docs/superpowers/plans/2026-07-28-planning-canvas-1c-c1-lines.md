# Planning canvas 1C-c1 — lines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A writer can draw a line between two cards, see it, select it, name it, and take it back — and the line is scratch, exactly like everything else on this surface.

**Architecture:** A line is two node ids and an optional label. It has no type and must never gain one. It joins `CanvasSelection` as a third case, so the compiler enumerates every place selection is read. It draws as a pass **inside** `CanvasRenderer.draw`, between the region pass and the card pass, culled to the viewport like every other per-frame walk. Two routes draw one: ⇧-drag from any card, and a drag from a connect mark shown on the **selected** card. Its label is edited in the right-hand column beside the region inspector, through `mutateFromInspector` — not in a sheet.

**One rule governs where a line sits: cards over lines over regions, in drawing and in hit-testing alike.** This is not a new rule — cards already beat region chrome *and* draw above it — so lines slot into it rather than becoming an exception. Its whole value is that there is no second rule to write down, defend and watch drift, and Task 3 records the two packages that were rejected for needing one.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest. Builds on 1C-a (the surface) and 1C-b (regions), both merged. No MaughamCore change, no phone change (spec §9).

---

## Why this plan is one third of 1C-c

The 2026-07-25 draft (`2026-07-25-planning-canvas-1c-c-lines-and-promotion.md`, 10 tasks, 4,474 lines) covers three genuinely separate things: **lines**, **promotion**, and **the MCP canvas surface**. It is at CLAUDE.md rule 12's cap already, and 1C-b — re-derived to 8 tasks, all under the cap — still needed three follow-ups.

More decisively, **rule 11**: the draft was written against 1C-a's and 1C-b's APIs before either existed, and the re-derivation below found that most of its model-layer assumptions are now wrong. Promotion and the MCP surface both read `CanvasSelection`, which this plan changes; writing them now would repeat the exact mistake this re-derivation exists to correct.

So 1C-c becomes three plans. **This is the first.** The other two are scoped in the appendix, with the findings that survive, and are to be re-derived against the code *this* plan builds.

**The draft is superseded, not amended.** Do not read it for spellings — every symbol below was checked against the file named. Where this plan and the draft disagree, this plan is right and the draft is stale.

---

## What the re-derivation found

Everything in this section was greppable on `main` at `dcb03a1`. Each line is a place the draft would have failed to compile, failed the suite, or shipped a defect.

| The draft assumed | The built code says |
|---|---|
| `CanvasModel.selectedRegionID` + a new `selectedLineID`, with `selectLine`/`selectRegion` doors enforcing exclusivity | **`CanvasModel.selection: CanvasSelection?`** — one enum, `case node` / `case region` (`CanvasRegion.swift:15`). Exclusivity is already structural. A `.line` case gets it for free, and makes the compiler enumerate every reader. |
| `CanvasModel.load(projectRoot:)` | **`attach(projectRoot:)`** (`CanvasModel.swift:118`), with `detach()` as its pair. |
| `CanvasModel.deleteSelectedRegion()` | Does not exist. Delete is **`CanvasView.deleteSelection() -> Bool`** (`CanvasView.swift:917`), which switches on `model.selection`, guards on `isInGesture`, and returns whether anything went so `keyDown` can beep. |
| `CanvasRenderer.regionLayerDepth` / `nodeLayerDepth`, and a `drawLines` call added to `CanvasView`'s draw closure | **No layer-depth constants exist.** Draw order is the sequence of passes inside `CanvasRenderer.draw`, documented in its own doc comment. Lines belong as a pass *inside* `draw` — which means **`CanvasView.swift`'s five source-layout contracts are not touched at all.** |
| `draw(… selectedRegionID: …)`, `mountedEditorNodeID` restatement worries | `draw(scene:camera:viewSize:layouts:scraps:**selection:**visibleEditorNodeID:straighten:**pendingRegionDraw:**into:)` (`CanvasRenderer.swift:526`). It already takes the whole selection and already carries one piece of transient gesture chrome. |
| `CanvasInteraction.beginRegionDrag` / `beginRegionResize` / `createRegion(from:to:)`, and a `@State regionDrawStart` on the view | **One `begin(at:in:)`** decides among five modes including `.drawingRegion`; the swept rect lives in the interaction as `pendingRegionDraw`; `createRegion(_ rect:in:)` takes the rect. There is no view-side start point and no ⌥ modifier — **a bare drag on empty canvas draws a region.** |
| `CanvasEventNSView.onDeleteKey: (() -> Void)?` | `(() -> Bool)?` — the return value is what stops a ⌫ over nothing being silently swallowed (`CanvasEventView.swift:46`, 254). |
| `CanvasScene` has a private `mutateNode(_:_:)` helper to reuse | It does not. Per-node mutators write `byID[id]?.field` inline (`setWidth`, `setCachedHeight`). |
| Region title fallback needs a new `"Untitled region"` constant | `CanvasRegion.untitledLabel` and `displayLabel` already exist (`CanvasRegion.swift:47`, 90). |
| Double-clicking a line opens a label sheet, inserted "before the branch that clears the selection" | `handleClick`'s double-click arm switches on `clickTarget(at:)`, which is node-or-empty. **A double-click on a line today mints a scrap under it** — and AppKit's `clickCount: 1` first click has already selected the line, so the writer gets "Edit Scrap" open while the inspector shows a line. That is tripwire 32's own repro shape. `clickTarget` must gain a line case. |
| A new surface may call `model.mutate` / `withScene` | **`TripwireGrepTests.test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly`** asserts the census equals exactly `["RegionInspector.swift": ["mutateFromInspector"]]`. Any file outside `CanvasView.swift` that names `CanvasModel` and calls `mutate`/`withScene`/`beginGesture`/`endGesture`/`breakGesture`/`setScrapText`/`removeScrapText` fails the suite, and must instead use `mutateFromInspector` and be added to that expectation by name. |
| Tripwire number 32 is free | **32 is taken** (1C-b's undo-bracket rule). The table ends at 32; the next free number is 33. |
| `ProjectWindow` holds `@State var canvas` | It is `@State private var canvasModel` (`ProjectWindow.swift:76`), and `ProjectWindow.pieceChoices(in:)` already exists — do not re-derive the `TreeWalk` for it. |
| A separate Plan-persona guide topic exists | The canvas lives in `docs/guide/getting-started.md` under "The planning canvas", whose last line currently reads *"Connecting lines, dragging research onto the canvas, and turning a scrap into a real chapter or note are all still to come."* |

The draft's schema-3 bump also bundled `author` and `promotedItemID` onto the node DTO. Those belong to promotion (1C-c2) and the Claude write path (1C-c3). **This plan ships `lines` only, at schema 3**; each later slice takes its own additive-optional bump. Shipping a field nothing reads is the "built, exercised, no caller" failure this area has produced three times.

---

## Global Constraints

Everything in 1C-a's and 1C-b's constraints still applies, and `Maugham/Canvas/AREA.md` is binding. In addition:

- **No typed edge vocabulary, ever** (spec §5, §9). Kinopio shipped author-typed connections for years and removed them in April 2026 for confusing first-time users. `CanvasLine` has no `kind` and must not gain one. The optional free-text label is the whole vocabulary.
- **Precedence is stated in the UI, once, plainly** (spec §5): wiki-links are durable, canvas lines are scratch. 1C-c2 states it in the promotion sheet, where it costs the writer something. **This plan states it in the guide and nowhere else** — a line drawn is not the moment the distinction bites, and a permanent banner saying so is chrome on a surface whose feel is open space.
- **`ProjectWindow.body` gains nothing.** This plan adds no line to it. `canvasInspector(store:)` is a method and stays one expression.
- **`CanvasView.swift` is edited in four named methods only** — `handleClick`, `clickTarget`, `selectionTarget`, `deleteSelection`, `handleDrag`, plus one `let` in `body` and one argument on the `CanvasRenderer.draw` call. **Read the five source-layout contracts in its header before touching it** (declaration order, adjacency, blank-line separation, and two raw-source scans — contract 1 *crashes* the test rather than failing it, and contract 5 fails on a modifier *named in a comment*).
- **Nothing scene-proportional keys off `revision`** (tripwire 30). The line passes are per-frame, so they cull; the accessibility tree stays on `sceneRevision`.
- **The undo-bracket census** (tripwire 32) is a hard gate on Tasks 5 and 6. From inside `CanvasView` use `mutate`/`beginGesture`; from the inspector column use `mutateFromInspector` and update the census expectation in the same commit.
- `./gen.sh` after adding ANY new file. Run `xcodebuild` in the **foreground**, one at a time. Never dispatch two implementers at once — they share the working tree. Never commit anything under `Maugham.xcodeproj/`.
- `-only-testing` takes `MaughamTests/<ClassName>`, **never a folder path** — a folder path runs zero tests and reports success. Confirm the test count in the output.
- **Release build after Tasks 3, 4, 5, 6 and 7.** Every one of them touches a view; the Release type-check budget is stricter than Debug.
- SourceKit's `No such module` / `Cannot find type … in scope` is stale-index noise. The one real diagnostic is *"unable to type-check this expression in reasonable time"*.
- **Every function this plan adds gets a `grep -rn` for its production callers before its task is called done**, recorded in the task report. Three unreachable halves have shipped in this area and all three were found by a caller count, never by a test.

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Canvas/CanvasLine.swift` | **New.** `CanvasLineID`, `CanvasLine`, `CanvasLineHit`. No `kind`. |
| `Maugham/Canvas/CanvasScene.swift` | *Modify* — line storage, `endpoints(of:)`, `remove` scrubs lines |
| `Maugham/Canvas/CanvasRegion.swift` | *Modify* — `CanvasSelection.line` case (it lives in this file) |
| `Maugham/Canvas/CanvasSceneCodec.swift` | *Modify* — schema 2 → 3, `LineDTO` |
| `Maugham/Canvas/CanvasRenderer.swift` | *Modify* — the line pass, the pending-line chrome, culling, the label pill |
| `Maugham/Canvas/CanvasInteraction.swift` | *Modify* — `Mode.drawingLine`, `Kind.drawingLine`, `begin(at:in:connecting:)` |
| `Maugham/Canvas/CanvasEventView.swift` | *Modify* — the drag callback carries whether ⇧ was down |
| `Maugham/Canvas/CanvasView.swift` | *Modify* — five methods, one `let`, one draw argument |
| `Maugham/Canvas/CanvasModel.swift` | *Modify* — `selectedLine`, and the `.line` arm of `clearSelectionIfItNoLongerResolves` |
| `Maugham/Canvas/LineInspector.swift` | **New.** The selected line, in the right-hand column |
| `Maugham/Canvas/RegionInspector.swift` | *Modify* — `RegionInspectorPane` routes on `model.selection` |
| `Maugham/Canvas/CanvasAccessibility.swift` | *Modify* — lines reach VoiceOver |
| `Maugham/Canvas/AREA.md`, `docs/guide/getting-started.md`, `docs/roadmap.md`, `docs/problem-map.md` | *Modify* — Task 7 |

---

### Task 1: `CanvasLine`, and lines in the scene

**Files:**
- Create: `Maugham/Canvas/CanvasLine.swift`
- Modify: `Maugham/Canvas/CanvasScene.swift`
- Test: `MaughamTests/Canvas/CanvasLineTests.swift`

**Interfaces:**
- **Consumes:** `CanvasNodeID`, `CanvasNode.frame`, `CanvasScene.node(_:)`/`insert(_:)`/`remove(_:)` — all `CanvasNode.swift`, `CanvasScene.swift`.
- **Produces:**
  - `struct CanvasLineID: Hashable, Codable, Sendable, CustomStringConvertible` — `init(_ raw: String)`, `var raw: String`. **Match `CanvasNodeID`/`CanvasRegionID` exactly**, `description` included; a third id type spelled differently is a third thing to remember.
  - `struct CanvasLine: Equatable, Sendable` — `let id`, `var from`, `var to`, `var label: String?`, `func touches(_:) -> Bool`. **No `kind`.**
  - `enum CanvasLineHit` — `static let tolerance: CGFloat`, `static func distance(from:toSegment:_:) -> CGFloat`, `static func line(at:in:) -> CanvasLineID?`.
  - On `CanvasScene`: `var lines: [CanvasLine]` (id-sorted), `insertLine`, `removeLine`, `updateLine(_:_:)`, `lines(touching:)`, `endpoints(of:) -> (CGPoint, CGPoint)?`.

**A line to a node inside a COLLAPSED region is neither drawn nor clickable.** *(Added 2026-07-28 during Task 3's review; the first draft of this plan missed it entirely.)* A resident of a collapsed region keeps its frame — `CanvasScene` hides it through `hiddenNodes`, and `endpoints(of:)` reads the frame directly — so nothing about the geometry says the card is off screen. Both neighbouring per-frame passes already guard exactly this and say so in prose: `CanvasRenderer.tethers` ("a collapsed region draws none of its residents, so a line to one lands on empty ground") and `appearanceChips`, which filters on `!scene.isHidden(_:)`. **The line passes join that list**, and the same rule governs Task 5's hit test — otherwise there is a line the writer can click and cannot see, which is worse than one they can see and cannot click.

**Endpoints are node CENTRES, and a line to an unmeasured node has none.** Centre is the same reading `CanvasInteraction.joinTarget` already takes for a drop, so the canvas has one answer to "where is this card". An unmeasured node has no `frame` at all — `CanvasNode.frame` returns nil without a `cachedHeight` — and drawing to a guessed position would twitch the instant the real measurement arrived.

**`lines` sorts on every access, and unlike `CanvasScene.nodes` that is safe.** Say why in the doc comment: the per-frame reader is `CanvasRenderer.visibleLines`, and lines are bounded by nothing (a writer can draw one per card) — so the sort *is* on the frame path and is accepted only because the collection is small in practice and the culling filter runs after it. **If a canvas ever makes this measurable, the fix is an `unorderedLines` peer, exactly as `nodes`/`unorderedNodes` split.** Write that sentence down; the next author will otherwise reintroduce `nodes`' bug.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasLineTests.swift`. Fixture: nodes `a` at (0,0,240,80) → centre (120,40), `b` at (400,0,240,80) → centre (520,40), `c` at (800,0,240,80).

Assertions, each with the reason in its message:

- `test_aLineCarriesNoTypeOnlyAnOptionalLabel` — a fresh line's `label` is nil, **and** `Mirror(reflecting:).children` is exactly `["from", "id", "label", "to"]`. The absence of a `kind` is the assertion; the message names Kinopio's April 2026 removal and tells the next author to re-read spec §5 before changing it.
- `test_labelCanBeSetAndCleared` — through `updateLine`, both directions.
- `test_linesAreOrderedStablyByID` — insert `l2` then `l1`, read `["l1", "l2"]`. Dictionary order must reach neither the draw pass nor the sidecar.
- `test_linesTouchingFindsBothDirections` — a line `a→b` and a line `c→a` both come back for `a`.
- `test_aSelfLineIsRejected` — `insertLine` with `from == to` leaves `lines` empty. A line from a node to itself has nothing to say and draws as a blob.
- `test_duplicateLinesBetweenTheSamePairAreAllowed` — two differently-labelled thoughts about one pair are both legitimate, and a line costs nothing to be wrong about.
- `test_deletingANodeDeletesItsLines` — `remove(a)` drops every line touching `a` and keeps the rest. A line to a node that is gone would draw into nowhere.
- `test_endpointsAreNodeCentres` — (120,40) and (520,40).
- `test_endpointsAreNilWhenAnEndIsUnmeasured` — one node with no `cachedHeight`.
- `test_distanceToSegmentIsPerpendicularInsideTheSpan` — (300,44) to (120,40)–(520,40) is 4.
- `test_distanceToSegmentClampsAtBothEndpoints` — (120,140) is 100, and (20,40) is 100. **Both ends, and the second is the one that matters**: without the clamp a click a mile past the card lands on the infinite line the segment sits on.
- `test_lineAtPointHitsWithinToleranceAndMissesOutside` — asserts `tolerance == 6`, then a hit at 4pt off and a miss at 10pt off.
- `test_lineAtPointTakesTheNearestOfTwoOverlappingLines` — two lines within tolerance of one point; the nearer id comes back. (The `best` comparison in `line(at:)` is otherwise unfalsifiable — first-found would pass every other test here.)
- `test_lineAtPointIgnoresUnmeasuredLines` — a line whose ends have no frames is not clickable, because it is not drawn and an invisible target is a click the writer cannot explain.

- [ ] **Step 2: Run test to verify it fails**

`./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLineTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasLine' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/CanvasLine.swift`**

```swift
import Foundation

/// Stable identity for a line. Minted by `CanvasInteraction` with a uniqueness
/// loop against the scene, exactly as `createScrap` and `createRegion` mint
/// theirs — never by a bare random call.
public struct CanvasLineID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// A freeform line between two nodes.
///
/// **Untyped, deliberately, and it must not gain a `kind`** (spec §5, §9).
/// Kinopio built author-typed connections, shipped them for years, and removed
/// them in April 2026 because "connection types were confusing for people I
/// observed using the tool for the first time". An untyped edge with an optional
/// free-text label is the empirically supported floor.
///
/// A line carries no semantics and asserts nothing. It costs nothing to draw and
/// nothing to be wrong about, which is what thinking needs. `[[wiki-links]]`
/// remain the durable relationship layer, reached deliberately through promotion
/// — and that precedence is stated in the guide, and in 1C-c2's promotion sheet
/// where it costs the writer something.
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

/// Clicking a line. Kept out of `CanvasScene` so the geometry is a pure function
/// with no scene state to get wrong, testable against literal arithmetic rather
/// than against itself.
public enum CanvasLineHit {

    /// Pointer slop. The stroke is far too thin to aim at, so the target is
    /// deliberately much larger than the ink — the same reason the card's resize
    /// TARGET is the whole corner square while its MARK is only the triangle.
    public static let tolerance: CGFloat = 6

    /// Distance from `point` to the SEGMENT `a`–`b`, clamped at BOTH ends.
    /// Without the clamp a click far beyond either card still lands on the
    /// infinite line the segment sits on.
    public static func distance(from point: CGPoint,
                                toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// The NEAREST line within `tolerance`, or nil. Nearest and not first-found:
    /// two lines leaving the same card run within a few points of each other for
    /// their whole first stretch, and picking either would be a coin flip the
    /// writer cannot predict.
    ///
    /// Lines whose endpoints are unmeasured are skipped — they are not drawn,
    /// and an invisible target is a click the writer cannot explain.
    public static func line(at point: CGPoint, in scene: CanvasScene) -> CanvasLineID? {
        var best: (id: CanvasLineID, distance: CGFloat)?
        for line in scene.lines {
            guard let ends = scene.endpoints(of: line) else { continue }
            let d = distance(from: point, toSegment: ends.0, ends.1)
            guard d <= tolerance, best == nil || d < best!.distance else { continue }
            best = (line.id, d)
        }
        return best?.id
    }
}
```

- [ ] **Step 4: Extend `CanvasScene`**

Add `private var linesByID: [CanvasLineID: CanvasLine] = [:]` beside `regionsByID`, and the accessors. Note `CanvasScene.init` takes `nodes:` and `regions:` — **do not add a `lines:` parameter**; nothing needs one and every existing call site would keep compiling silently either way, which is how an unused parameter survives. Tests build lines with `insertLine`.

`insertLine` rejects `from == to`. `endpoints(of:)` returns nil unless both `node(_)?.frame` resolve, and returns the two `CGPoint(x: midX, y: midY)` centres.

Extend `remove(_ id: CanvasNodeID)` — which already forgets region memberships — with the line scrub, **snapshotting the keys first**:

```swift
        // A line to a node that is gone would draw into nowhere. `linesByID.keys`
        // is a live view onto the dictionary; writing through `linesByID` while
        // iterating it is the kind of thing copy-on-write happens to make safe
        // rather than the kind of thing that IS safe.
        for lineID in Array(linesByID.keys) where linesByID[lineID]?.touches(id) == true {
            linesByID[lineID] = nil
        }
```

`CanvasScene`'s synthesised `Equatable` picks the new dictionary up, and `CanvasUndo`'s snapshots carry the whole scene — so lines are on the undo stack from this task with no further work. **Do not add a parallel line snapshot.**

- [ ] **Step 5: Run the tests**

`./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLineTests CODE_SIGNING_ALLOWED=NO` — PASS, 14 tests.

Then, unfiltered on the neighbours the scene grew under:
`-only-testing MaughamTests/CanvasSceneTests`, `MaughamTests/CanvasMembershipTests`, `MaughamTests/CanvasUndoTests`. All PASS.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasLine.swift Maugham/Canvas/CanvasScene.swift MaughamTests/Canvas/CanvasLineTests.swift project.yml
git commit -m "feat(canvas): untyped lines with optional labels

No kind, and there must not be one (spec §5): Kinopio shipped typed
connections for years and deleted them in April 2026. Endpoints are node
centres, the same reading joinTarget takes; an unmeasured end is not drawn
and not clickable."
```

---

### Task 2: The sidecar — schema 2 → 3

**Files:**
- Modify: `Maugham/Canvas/CanvasSceneCodec.swift`
- Test: `MaughamTests/Canvas/CanvasLineCodecTests.swift`

**Interfaces:**
- **Consumes:** `CanvasLine`, `CanvasLineID`, `CanvasScene.insertLine`/`lines` (Task 1); `CanvasSceneDTO` (`currentSchemaVersion`, `nodes: [NodeDTO]`, `regions: [RegionDTO]?`), `CanvasStore.load()`/`save(scene:scraps:)`.
- **Modifies:** `CanvasSceneDTO` — `currentSchemaVersion` 2 → 3, a nested `LineDTO`, `var lines: [LineDTO]?`.

**Additive-optional, ADR 0015.** `lines` is optional so every schema-2 sidecar 1C-b wrote decodes unchanged rather than throwing on a missing key. In the other direction `CanvasStore.load` already refuses a `schemaVersion` above its own and returns an empty layout **with the scraps intact** — so a schema-3 canvas opened by an older build costs the arrangement and never the words. Re-read that guard before changing anything near it.

**Endpoint validation at the disk boundary, and it goes through `insertLine`.** A hand-edited sidecar can name a node that is not in the file; that line would draw into nowhere. The loop skips those and inserts through `insertLine` rather than the dictionary, so the self-line rule is single-sourced — the same shape `RegionDTO`'s membership validation already takes (`CanvasSceneCodec.swift:94`, the contested-home resolution).

**Membership arrays are written `.sorted()` and lines are written in id order for the same reason:** saving an unchanged canvas must be byte-identical *across processes*, and `Set`/`Dictionary` iteration is deterministic only within one run. A test that saves twice from one value cannot see this — decode the DTO and assert the order instead.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasLineCodecTests.swift`, following `CanvasRegionCodecTests`' shape (a temp `root`, a `writeSidecar(_ json: String)` helper writing `.maugham/canvas.json`).

- `test_theSchemaVersionIsThree`
- `test_linesRoundTripThroughDisk` — id, from, to and label all survive `save` → `load`.
- `test_aSchemaV2SidecarLoadsWithNoLines` — a hand-written schema-2 file with nodes and `"regions":[]` opens, and `lines` is empty. ADR 0015's additive-optional contract.
- `test_aLineNamingAMissingNodeIsDropped` — `{"from":"ghost","to":"also"}` against an empty `nodes` array.
- `test_aSelfLineInTheFileIsDropped` — with the message *"insertLine rejects self-lines; the loader must go through it"*.
- `test_linesAreWrittenInIDOrderRegardlessOfDictionaryIteration` — insert `l9`, `l1`, `l5`; **decode the DTO** off disk and assert `["l1","l5","l9"]`. Decoding the DTO, not the scene: `CanvasScene.lines` sorts on read, so a scene-level assertion passes under any write order at all.
- `test_aSchemaFourSidecarLosesTheArrangementAndKeepsTheWords` — write `"schemaVersion":4` plus a real `canvas.md`, and assert the scene is empty *and* `scraps` is not. This is the guard that makes the bump non-destructive in both directions, and 1C-c2 and 1C-c3 each bump again — so it wants a line count of one, here, not three.

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `type 'CanvasSceneDTO' has no member 'lines'`, or the version assertion reading 2.

- [ ] **Step 3: Extend the codec**

`currentSchemaVersion = 3   // was 2 (regions, 1C-b)`, a `struct LineDTO: Codable { var id, from, to: String; var label: String? }`, and `var lines: [LineDTO]?`.

In `init(scene:)`, `self.lines = scene.lines.map { … }` — `scene.lines` is already id-sorted, so no second `.sorted()` and no second opinion about the order.

In `var scene: CanvasScene`, after nodes and regions are built (match the existing local's name):

```swift
        // Endpoint validation, the same shape the region loader applies to
        // memberships: a line naming a node that is not in this file would draw
        // into nowhere. Through `insertLine` rather than the dictionary, so the
        // self-line rule has exactly one definition.
        for dto in lines ?? [] {
            let from = CanvasNodeID(dto.from), to = CanvasNodeID(dto.to)
            guard s.node(from) != nil, s.node(to) != nil else { continue }
            s.insertLine(CanvasLine(id: CanvasLineID(dto.id), from: from, to: to, label: dto.label))
        }
```

- [ ] **Step 4: Run the tests**

`./gen.sh && … -only-testing MaughamTests/CanvasLineCodecTests` — PASS, 7 tests.
Then `MaughamTests/CanvasRegionCodecTests` and `MaughamTests/CanvasStoreTests` — both still PASS. The version literal is what is most likely to have moved under them.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasSceneCodec.swift MaughamTests/Canvas/CanvasLineCodecTests.swift project.yml
git commit -m "feat(canvas): persist lines (sidecar schema 2→3)

Additive-optional both ways: a schema-2 file opens with no lines, and an
older build opening this one loses the arrangement and never the words."
```

---

### Task 3: Drawing lines — a pass inside `draw`

**Files:**
- Modify: `Maugham/Canvas/CanvasRenderer.swift`
- Modify: `Maugham/Canvas/CanvasRegion.swift` (the `CanvasSelection.line` case)
- Modify: `Maugham/Canvas/CanvasModel.swift`, `Maugham/Canvas/CanvasView.swift` (whatever the new case makes the compiler flag)
- Test: `MaughamTests/Canvas/CanvasLineRenderTests.swift`

**Interfaces:**
- **Consumes:** `CanvasLine`, `CanvasScene.lines`/`endpoints(of:)` (Task 1); `CanvasCamera.visibleContentRect(viewSize:)`; `CanvasMaterial`; the existing `draw` (`CanvasRenderer.swift:526`).
- **Produces on `CanvasRenderer`:** `struct LineGeometry: Equatable`, `static func lineGeometry(in:) -> [LineGeometry]`, `static func visibleLines(in:camera:viewSize:) -> [LineGeometry]`, `static func lineLabelBox(for:) -> CGRect`, `static let connectHandleSize: CGFloat`, `static func connectHandleRect(inCard:) -> CGRect`, plus private `drawLine`/`drawPendingLine` passes.
- **Modifies:** `CanvasSelection` gains `case line(CanvasLineID)`; `draw` gains one parameter, `pendingLine: (from: CGPoint, to: CGPoint)?`; `drawCard`'s `isSelected` block gains the connect mark.

**The connect mark is drawn on the SELECTED card, and that is the discoverable half of the gesture.** ⇧-drag (Task 4) has no chrome and therefore no discovery path but the guide, and nobody explores by holding a modifier. The three alternatives were each rejected on this surface's own terms:

- *Hover-revealed edge handles* — what tldraw, Miro, FigJam and Obsidian Canvas have all converged on. They need `NSTrackingArea` and `mouseMoved`, which `CanvasEventNSView` does not have, plus a hovered-node state and a redraw per pointer move: new per-frame state on a surface whose whole architecture is keeping per-frame work viewport-proportional. And handles blooming on every card the pointer crosses is the diagramming-tool look §5 positions against — lines here are scratch, not a vocabulary.
- *A drag from the card's border band*, Scapple's answer and the nearest relative. It steals roughly an eighth of the card from *move*, sits inside the `r·θ` tilt mismatch band, and puts a connect zone along the top edge — where the text starts, and where cards already overlap region chrome.
- *A permanent mark on every card.* Defensible — `drawCard` already inks the resize triangle unconditionally, outside the `isSelected` block, so permanent card chrome is this surface's established grammar rather than a departure. Rejected only because a second always-on mark overstates what §5 calls a thing that "costs nothing to draw and nothing to be wrong about".

Selection chrome costs nothing new: selection already exists, already reaches `drawCard` as `isSelected`, and already triggers a redraw. Discovery is clicking a card — the most natural act after dragging one — and the mark is there. Dragging it runs the identical path as ⇧-drag, so the findable route teaches the fast one.

**Geometry, and the one rule to write down.** `connectHandleRect(inCard:)` is a `connectHandleSize` square on the card's right edge, vertically centred, **clamped to stay above the resize square**. On a card too short for both, the corner belongs to resize — it is the permanent mark, and a target that moved depending on the card's height would be worse than one that is sometimes absent. Size it from a named constant so the mark and Task 4's target cannot drift apart, exactly as `resizeHandleSize` fixes both for the resize corner. The **target may be larger than the mark**, and should be, for the reason `CanvasInteractionTests.test_theUnmarkedHalfOfTheCornerSquareStillResizes` exists: a target slightly larger than its ink forgives a near miss, where the reverse swallows drags the writer aimed at the card.

**`CanvasSelection` gains the case here, not in Task 5, and that ordering is deliberate.** The renderer is the first consumer that needs it, and adding the case makes the compiler enumerate every reader at once. Run `grep -rn "model\.selection\|selectedRegion" Maugham --include="*.swift"` first and reconcile against what the build then flags — as of `dcb03a1` the only two **switches** over `CanvasSelection` are `CanvasModel.clearSelectionIfItNoLongerResolves` and `CanvasView.deleteSelection`; the other readers compare or pattern-match a single case and compile unchanged. **That enumeration is the point:** a caller count is what has found every unreachable half in this area, and here the compiler does it for free.

`CanvasModel.selectedRegion` is a `guard case .region` and needs no change; add a peer `selectedLine: CanvasLine?` beside it, resolving through `scene.lines` so a stale id after an undo answers nil. Give `clearSelectionIfItNoLongerResolves` its `.line` arm — **a snapshot carries the scene, not the selection**, so an undo that takes back a line otherwise leaves the inspector holding a dangling id.

**Lines draw INSIDE `draw`, as a pass between regions and cards.** Above regions, because a line into a region's area must not vanish under it. Beneath cards, because a line's job is to connect cards and a line crossing over one reads as damage. `draw`'s own doc comment already enumerates its passes and says the order is the design — **extend that list to five and keep the reasoning in the same voice.** Do not add layer-depth constants: they do not exist, they would not enforce anything, and the sequence of calls is already the single source of truth.

**Above the WHOLE region pass — the bar, the label and the region's resize mark, not just the wash — and Task 5 hit-tests in the same order.** `drawRegion` is one pass that inks all five things, so "above regions" is one decision, not two, and the click precedence is bound to it: **the thing drawn on top takes the click.** Two alternatives were worked through and rejected, and both failed for the same reason:

- *Chrome beats the line while the line draws over it* — the shape an earlier draft of this plan specified. A line inks over a region's title and its resize triangle while the chrome silently takes the click: hit-testing disagreeing with what is visibly frontmost, which is this area's oldest defect class wearing a new coat.
- *Split `drawRegion` so lines slide under the label* — trades one special case for another and does not even work: the bar's tint would still be under the visible line while taking its click.

Neither loss is worth a special case in the first place. A near-perpendicular crossing costs the line about 24 pt of a length measured in hundreds, and costs the bar about 12 pt of a width measured in hundreds. **What one rule buys is that a writer can state it and never be surprised**, and that there is no second rule for a later tidy-up to drift away from.

*Open for smoke, not pre-solved:* a hairline at `lineOpacity` crossing a region's 11 pt label, which happens only for a line entering a region from directly above. If it reads as damage the fix is nudging the label, **not** reopening the precedence.

**The pending line is transient chrome and draws LAST, beside the sweep.** It is the one thing on the surface that is not in the model. Dashed, so an in-progress line never reads as one that exists — the same signal `drawSweep` uses for the same reason. Take it as a `(from:to:)` tuple rather than reaching into `CanvasInteraction`: the renderer knows nothing about gestures, and `pendingRegionDraw: CGRect?` is the precedent one parameter over.

**Lines are culled to the viewport.** `lineGeometry(in:)` is the unculled projection the geometry tests assert against; `visibleLines` is what the draw pass calls. The whole architecture rests on per-frame work being viewport-proportional (`visibleNodes`, `visibleRegions`, and the 2,000-node probe) and "there are fewer lines than nodes" is an assertion nothing bounds — a writer can draw one per card. AREA.md's Scale section already names tethers and chips as the known unbounded per-frame work; lines joining that list uncounted would be a regression on the one number this surface defends.

**The hairline inset in `visibleLines` is DEFENSIVE, and the reason it is there is not the one this plan first gave.** *(Corrected 2026-07-28 during Task 3, by measurement on macOS 26.5. The original claim — that `CGRect.intersects` is false for an empty rect, so an axis-aligned line would silently stop drawing — is **false**, and an assertion written from it is green with the inset deleted.)*

What was measured: `intersects` is false only for a **null** rect, not an empty one. `CGRect(x: 100, y: 20, width: 440, height: 0).intersects(CGRect(x: 0, y: 0, width: 800, height: 600))` is **true**. So a horizontal line's zero-height box survives culling on its own.

The real hazard is one spelling over. `box.intersection(viewport)` of that same rect is not null and **is** empty — so a tidy-up to `!box.intersection(viewport).isEmpty`, which reads as an obvious equivalent, culls every horizontal and vertical line on the canvas. Two cards side by side is the ordinary case, not a corner one, and the failure is silent and total.

**Keep the inset** — two lines against a silent, total failure, in the same spirit as the resize target being larger than its mark and `cullingBleed`'s rotation overhang. But pin it with an assertion that can actually fail: assert the inset on the bounding box directly, and do not write a `visibleLines` test claiming to isolate something it cannot see. **Carry the measurement in the doc comment**, not the story — a rule whose stated reason is false is worse than no rule, because the next author tests the reason, finds it holds without the code, and deletes the code.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasLineRenderTests.swift`. Geometry and culling are pure and assert against literals; the drawn output follows `CanvasRegionRenderTests`' raster idiom — render two scenes differing in exactly one model fact through `ImageRenderer` and count changed pixels.

Pure:
- `test_lineGeometryResolvesToNodeCentresAndCarriesTheLabel`
- `test_linesToUnmeasuredNodesAreNotProjected`
- `test_theLabelBoxIsCentredOnTheSegmentMidpoint` — midX 320, midY 40, non-zero width.
- `test_theLabelBoxIsEmptyForAnUnlabelledLine` — an unlabelled line must not reserve a pill of empty ground.
- `test_aLineFarOutsideTheViewportIsCulled` — `lineGeometry` still sees both; `visibleLines` returns only the near one.
- `test_aLineInsideTheViewportSurvivesCulling` — **the control the negative test needs.** Every negative result in this area needs one that passed.
- The axis-aligned-culling assertion. **The obvious shape of this test cannot fail** — see the corrected paragraph above: a zero-height box survives `intersects` unaided, so a `visibleLines` test asserting "the horizontal line is still there" is green with the inset deleted. Assert the **inset on the bounding box directly** instead, and verify by mutation that removing the inset turns it red. If you keep a `visibleLines`-level test beside it, name it for the true behavioural claim (an axis-aligned line survives culling) and do not claim in its message that it guards the inset.

The connect handle, pure:
- `test_theConnectHandleSitsOnTheCardsRightEdgeAndInsideIt`
- `test_theConnectHandleNeverOverlapsTheResizeCorner` — over a range of card heights, **including one too short for both**, where it yields.
- `test_theConnectHandleAndItsMarkComeFromOneConstant` — the target is at least the mark, so a near miss is forgiven rather than swallowed.

Raster (all under `performAsCurrentDrawingAppearance` for the scheme they claim — the test process runs under DarkAqua, and a dynamic `NSColor` resolved without it gives the dark value under a light render):
- `test_aLineIsActuallyDrawnBetweenItsTwoCards` — the same scene with and without the line differs in pixels **on the segment's midpoint band**, not merely somewhere.
- `test_aSelectedLineDrawsHeavierThanAnUnselectedOne` — more ink, same geometry.
- `test_theLineDrawsBeneathTheCardsAndAboveEveryPartOfTheRegion` — a line routed under a card leaves the card's pixels untouched; a line crossing a region's **wash**, its **chrome bar** and its **resize triangle** is on top in all three. **This is the pass-order assertion, and it is what binds the draw order to Task 5's click order.**

  **"Pixels changed" is NOT that assertion, and the first draft of this bullet said it was.** *(Corrected 2026-07-28 during Task 3.)* Every part of a region is translucent, so a line drawn **underneath** still shows through and still changes pixels — `differingPixels > 0` is green under both orderings, which is precisely the unfalsifiable shape this plan keeps warning about. Render the line **selected** so its stroke is fully opaque, pick a pixel row the stroke fully covers, and assert the colour there is **byte-identical** over the region and over bare ground. Verify by mutation that moving the line loop ahead of the region loop fails all three parts independently.
- `test_thePendingLineIsDashedAndTheFinishedOneIsNot` — the two differ, so "in progress" is legible without the writer being told.
- `test_theConnectMarkIsDrawnOnlyOnTheSelectedCard` — two cards, one selected: the mark's rect differs from the unselected scene on one card and not the other. The negative half is what stops it becoming permanent chrome by accident.

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `cannot find 'lineGeometry'`.

- [ ] **Step 3: Add the case, and follow the compiler**

`CanvasSelection` in `CanvasRegion.swift` gains `case line(CanvasLineID)`. Build, and fix exactly what the compiler flags:
- `CanvasModel.clearSelectionIfItNoLongerResolves` — a `.line` arm dropping a selection whose line has left the scene.
- `CanvasView.deleteSelection` — a `.line` arm; **leave it returning `false` in this task** and give it real behaviour in Task 5. A stub that deletes nothing is honest for one commit; a stub that silently succeeds is not.

Add `CanvasModel.selectedLine` beside `selectedRegion`.

- [ ] **Step 4: Extend `CanvasRenderer`**

Constants beside the existing card and region ones — and **every look-calibrated number goes in `CanvasMaterial.swift`, not here**. `CanvasMaterial` is where the writer tunes the surface by eye, and a constant they cannot find is one they cannot change. So: `lineWidth`, `lineOpacity`, `selectedLineWidth`, the label pill's height, padding and background opacity, and the pending dash pattern all live in `CanvasMaterial` with light/dark pairs where the two appearances differ. `CanvasRenderer` holds only the geometry.

```swift
    struct LineGeometry: Equatable {
        let id: CanvasLineID
        let from: CGPoint
        let to: CGPoint
        let label: String?
    }

    /// Endpoints resolve to node CENTRES. A node that has never been measured
    /// has no frame, so its lines are not projected — drawing to a guessed
    /// position would twitch as soon as the real measurement arrived.
    static func lineGeometry(in scene: CanvasScene) -> [LineGeometry] { … }

    /// The lines whose bounding box meets the viewport, and only those.
    ///
    /// Per-frame work on this surface is viewport-proportional by design — the
    /// rule `visibleNodes`/`visibleRegions` follow, and the reason the
    /// 2,000-node probe passes. Lines are the one collection nothing bounds: a
    /// writer can draw one for every card, so "there are fewer lines than nodes"
    /// is not an argument.
    ///
    /// Bounding box rather than exact segment/rect intersection: the false
    /// positives are long diagonals whose box straddles the viewport, which are
    /// cheap to stroke and correct to draw.
    ///
    /// *** The hairline inset is defensive, and the doc comment must carry the
    /// MEASUREMENT rather than the story. *** Measured on macOS 26.5:
    /// `intersects` is false only for a NULL rect, not an empty one, so a
    /// horizontal line's zero-height box survives culling unaided. What the
    /// inset defends against is the neighbouring spelling —
    /// `!box.intersection(viewport).isEmpty` reads as an obvious equivalent and
    /// culls every horizontal and vertical line on the canvas, silently and
    /// totally.
    static func visibleLines(in scene: CanvasScene, camera: CanvasCamera,
                             viewSize: CGSize) -> [LineGeometry] { … }

    /// The label pill, centred on the segment's midpoint. Empty when there is no
    /// label — an unlabelled line must not reserve a pill of empty ground.
    ///
    /// The pill measures its text by a per-character advance rather than through
    /// a TextKit stack, and that is legitimate HERE and nowhere near a card:
    /// §7A.2's same-stack rule exists because a card's drawn text has to agree
    /// with a mounted editor's, and no editor ever mounts on a line.
    static func lineLabelBox(for geometry: LineGeometry) -> CGRect { … }
```

In `draw`, between the region loop and the node loop:

```swift
        for line in visibleLines(in: scene, camera: camera, viewSize: viewSize) {
            drawLine(line, isSelected: selection == .line(line.id), on: cx)
        }
```

and beside the existing sweep, last:

```swift
        if let pendingLine { drawPendingLine(from: pendingLine.from, to: pendingLine.to, on: cx) }
```

**Selection draws heavier and fully opaque rather than in an accent colour.** The canvas already spends its colour budget on the region ring and the palette wash (§7.1), and a line is thin enough that weight reads faster than hue.

Both private draw passes take the context **by value**, exactly as `drawCard`, `drawRegion`, `drawTether` and `drawChip` do — nothing a pass does may leak into the next thing drawn.

In `drawCard`, the connect mark goes **inside the existing `if isSelected` block**, beside the selection stroke and *not* beside the unconditional `resizeHandle` fill two lines below it. The two sit adjacent in the source and mean opposite things; a comment saying which is which belongs there, because the next author will read them as a pair. Drawn inside the card's rotated transform, like everything else in `drawCard`, so it tilts with the card and straightens with it — a mark that stayed level while its card leaned would read as chrome belonging to the canvas rather than to the card.

- [ ] **Step 5: Pass the pending line from `CanvasView`**

In `body`, beside the existing `let sweep = interaction.pendingRegionDraw`, add `let pendingLine = interaction.pendingLine` — **read in `body`, not inside the draw closure**, for exactly the reason spelled beside `sweep`: `interaction` is `@State`, and a `@State` read registers a dependency only during body evaluation. Read in the closure it registers nothing and the rubber band appears a frame late or not at all.

Add `pendingLine: pendingLine` to the `CanvasRenderer.draw(…)` call. `interaction.pendingLine` arrives in Task 4 — **until then pass `nil` literally**; committing a call that reads a symbol no task has written is the failure this plan exists to avoid.

- [ ] **Step 6: Run the tests and a Release build**

`./gen.sh && … -only-testing MaughamTests/CanvasLineRenderTests` — PASS, 15 tests.
Then `MaughamTests/CanvasRendererTests`, `MaughamTests/CanvasRegionRenderTests`, `MaughamTests/CanvasCompositionTests`, `MaughamTests/CanvasModelTests` — all PASS. The composition suite reads `CanvasView.swift` as text; if it fails, re-read the five source-layout contracts before changing anything.

`xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO` — BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas/CanvasLineRenderTests.swift project.yml
git commit -m "feat(canvas): draw lines above regions and beneath cards

Above the WHOLE region pass, not just its wash, so the draw order and Task
5's click order are one rule rather than two. A pass inside
CanvasRenderer.draw, culled to the viewport like every other per-frame walk
— a writer can draw a line per card, so lines are the one collection
nothing bounds. The hairline inset in visibleLines is what keeps
axis-aligned lines from silently disappearing. The connect mark is drawn on
the selected card only."
```

---

### Task 4: The gesture — ⇧-drag, and the selected card's connect mark

**Files:**
- Modify: `Maugham/Canvas/CanvasInteraction.swift`
- Modify: `Maugham/Canvas/CanvasEventView.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasLineGestureTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene.topmostNode(at:)`/`insertLine`, `CanvasLine`, `CanvasLineID` (Task 1); `CanvasInteraction`'s `private enum Mode`, `Kind`, `begin(at:in:)`, `update(to:in:now:)`, `end(now:)`, `hasMoved`, `pendingRegionDraw`; `CanvasEventNSView.applyMouseDown(at:clickCount:)`; `CanvasView.handleDrag(at:phase:)`, `CanvasView.gestureName(for:)`.
- **Produces on `CanvasInteraction`:** `case drawingLine(from: CanvasNodeID, origin: CGPoint, current: CGPoint)` on `Mode`, `case drawingLine` on `Kind`, `var pendingLine: (from: CGPoint, to: CGPoint)?`, `static func newLineID(in:) -> CanvasLineID`, `mutating func endLine(at:in:) -> CanvasLineID?`.
- **Modifies:** `begin(at:in:)` → `begin(at:in:connecting:)`; `CanvasEventNSView.onDrag` and `CanvasEventView.onDrag` → `(CGPoint, CanvasDragPhase, Bool)`.

**Two routes, one path.** ⇧-drag from any card, and a drag starting inside the connect mark on the *selected* card (Task 3). Both resolve to the same `connecting: true` before `CanvasInteraction` sees anything, so there is exactly one implementation of what a connect drag does — and the discoverable route and the fast one cannot drift into behaving differently.

**`CanvasView` decides which, and `begin` takes a plain `Bool`.** The connect-mark test needs `model.selection`, which `CanvasView` has and `CanvasInteraction` deliberately does not; widening `begin` to take the selection would hand the gesture layer a second opinion about what is selected. So `handleDrag` computes `connecting = shiftHeld || pressIsInTheSelectedCardsConnectHandle(contentPoint)` and passes the answer down.

**`begin` takes `connecting:` with NO default value.** A default would keep the existing call site compiling and hide the fact that there is exactly one. There is one; make it say so.

**The modifier is threaded through the event view rather than read off `NSEvent.modifierFlags` at the point of use.** A static global read is untestable except by faking it, and lesson 4 of the 1C-b handoff is that anything with a gesture needs one test that models the real delivery path end to end. `applyMouseDown(at:clickCount:)` already *has* the event; giving `onDrag` a third argument means `window.sendEvent(_:)` with a ⇧-flagged `NSEvent` reaches `begin` through production code, and `begin` itself becomes a pure function of `(point, scene, Bool)` that can be tested exhaustively.

**The connect-mark route depends on an ordering that is already a written contract, so lean on it rather than restating it.** `applyMouseDown` fires `onClick` strictly before `onDrag(.began)`, and its comment calls that a contract and not an incidental detail. So the press that selects a card is *also* the press that could start a connect drag from it — meaning a writer must click the card once to reveal the mark, then press the mark, which is two gestures and is correct. **Do not "helpfully" make the first press on an unselected card's handle position start a connect drag**: the mark was not drawn there yet, so the writer aimed at nothing, and the surface would be doing something they could not have predicted.

**⇧ matters only when the press lands on a node.** A ⇧-drag on bare canvas falls straight through to the region sweep — there is no marquee select on this surface (§9), so ⇧ is not overloaded. Insert the branch at the head of `begin`, **inside** the existing `if let node = scene.topmostNode(...)` block and before the resize-corner test, so a ⇧-press on a card's corner draws a line rather than resizing: the writer holding ⇧ has already said which gesture they mean.

**The rubber band anchors at the source card's CENTRE, not at the press point.** The band and the finished line must describe the same geometry, or the line visibly jumps the instant it is created.

**A drag ending on empty canvas, or back on the source card, creates nothing.** A line needs two distinct ends; a dangling one is not a thought. `endLine` returns nil and the gesture closes having changed nothing — `CanvasUndo.endGesture` already declines to register an unchanged gesture, so there is no empty step to clean up.

**The gesture name comes from `Kind`, through the existing `gestureName(for:)` switch** (`CanvasView.swift:975`). Adding `.drawingLine` to `Kind` makes that switch non-exhaustive, which is the compiler telling you the writer needs a word for the Edit menu. It is **"Draw Line"** — the item reads "Undo Draw Line".

**`update` and `end` must handle the new mode explicitly.** `update`'s switch is exhaustive over `Mode`, so the compiler will demand an arm: it advances `current` and nothing else. `end`'s flick detection is `guard case .moving` and already returns nil for every other mode — leave it. **A line drag must not move the source card**, and this is what guarantees it.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasLineGestureTests.swift`. Fixture as Task 1; a point inside `a` is (10,10), inside `b` is (410,10).

Pure, on `CanvasInteraction`:
- `test_aConnectingDragFromOneCardToAnotherCreatesALine` — `begin(connecting: true)` on `a`, `update` partway, `endLine` on `b`: one line, `from == a`, `to == b`, **label nil** ("a new line asserts nothing until the writer says so").
- `test_aConnectingDragOnACardsResizeCornerDrawsALineRatherThanResizing` — press inside the corner square with `connecting: true`; `kind == .drawingLine`, `isResizing == false`.
- `test_anUnmodifiedDragOnACardStillMovesIt` — the control. Without it, "connecting draws a line" is satisfied by a build where every drag draws a line.
- `test_aConnectingDragOnBareCanvasStillSweepsARegion` — ⇧ is not overloaded.

Pure, on `CanvasView`'s route decision — extract it as a `static func` over `(point, selection, scene)` rather than a private computed property, so it is reachable without hosting SwiftUI. **This is lesson 2**: the region inspector had a caller and was still unreachable, because the decision one level above it was never tested over its inputs.
- `test_aPressInsideTheSelectedCardsConnectHandleConnects`
- `test_theSamePointOnAnUnselectedCardDoesNot` — the mark is not drawn there, so the writer aimed at nothing.
- `test_theSamePointOnTheSelectedCardWithARegionSelectedInsteadDoesNot`
- `test_aPressOutsideTheHandleOnTheSelectedCardStillMovesIt`
- `test_shiftConnectsFromAnyCardSelectedOrNot` — the two routes are independent, and neither is a special case of the other.
- `test_thePendingLineAnchorsAtTheSourceCentreAndFollowsThePointer`
- `test_thePendingLineIsClearedWhenTheDragEnds`
- `test_aDragEndingOnEmptyCanvasCreatesNothing` — and `pendingLine` is nil after.
- `test_aDragEndingOnTheSourceCardCreatesNothing`
- `test_endLineWithoutBeginningOneDoesNothing`
- `test_aLineDragNeverMovesTheSourceCard` — `update` through the whole drag, then assert the source node's `origin` is unchanged. This is the arm on `update`'s switch, and without it the source card follows the pointer.
- `test_newLineIDsDoNotCollideWithExistingOnes`

Through the real delivery path, in `CanvasViewMountingTests` (the file that already hosts the hosted-window harness) — **and these are the ones that matter**:
- `test_aShiftDragBetweenTwoCardsReachesTheSceneThroughTheRealEventPath` — build a real `NSEvent` with `.shift` in its `modifierFlags`, send mouseDown/mouseDragged/mouseUp through `window.sendEvent(_:)`, and read the line back off `model.scene`. Post the mouseDown and mouseUp **before** pumping (`NSTextView.mouseDown` runs a modal tracking loop and a post-then-pump harness deadlocks), and use `waitOut(_:)` rather than `pump(_:)` for anything asserting elapsed time.
- `test_aDragFromTheSelectedCardsConnectHandleReachesTheSceneTheSameWay` — real events, **no modifier**, and the card selected by a real click first rather than by assigning `model.selection` in the test. The whole claim of this route is that a writer can reach it without knowing anything, so the test must not know anything either.
- `test_drawingALineIsOneUndoStepCalledDrawLine` — assert **`model.undo.undoMenuItemTitle`**, not just the post-⌘Z scene. An undo test whose only observable is the scene cannot tell "its own step" from "folded into the neighbour's", and that has been demonstrated twice in this area on a nesting bug. Run it **through both routes**: they share one path today and a later change is exactly what would give them two.

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `extra argument 'connecting' in call`.

- [ ] **Step 3: Extend `CanvasInteraction`**

Add the `Mode` case, the `Kind` case, `pendingLine`, `newLineID(in:)` and `endLine(at:in:)`. `endLine` takes `inout CanvasScene` and is fully synchronous — there is no `await` anywhere on this path, so the `inout` is legal.

`newLineID` mirrors `createScrap` and `createRegion` exactly — `UUID().uuidString.prefix(8).lowercased()` with a uniqueness loop against the scene — so the canvas has one id shape and not three.

`endLine` ends with `defer { mode = .idle }` and refuses when there is no pending line, no node under the drop point, or the drop node is the source.

- [ ] **Step 4: Thread the modifier**

`CanvasEventNSView.applyMouseDown(at:clickCount:shiftHeld:)`, forwarding into `onDrag?(point, .began, shiftHeld)`. `applyMouseDragged`/`applyMouseUp` pass `false` — only `.began` reads it, and a modifier released mid-drag must not abandon a line the writer is halfway through drawing. **Say that in a comment**; it is the kind of thing a later "consistency" edit removes.

`mouseDown(with:)` reads `event.modifierFlags.contains(.shift)`. **Do not reach for `charactersIgnoringModifiers` or any other event property here** — the delete-key comment two screens down records that it ignores every modifier except Shift, and that fact belongs to `keyDown`, not to this.

`CanvasEventView.onDrag` widens to match, and `wire(_:)` forwards it.

- [ ] **Step 5: Route it in `handleDrag`**

`handleDrag(at:phase:shiftHeld:)`. In `.began`, after the coast-stop and the `guard editingNodeID == nil` (**both stay exactly where they are** — a focused scrap owns its own mouse, and any press stops a coast), resolve the two routes into one Bool through the extracted `static func` and pass it into `interaction.begin`.

**Resolve it after the focus guard, not before.** A drag inside a focused scrap belongs to the editor, which is in front and takes the mouse itself; asking about connect handles above that guard would compute an answer for a press the canvas never sees. `.changed` needs **no** line-specific branch at all: `update` handles the mode and `interaction.isActive` is already true for it.

`.ended` reads whether this was a line drag **before `end()` clears the mode**, exactly where `drawnRegion` and `movedNode` are already read for the same reason (`CanvasView.swift:1064`), and branches in the same `if/else if` chain:

```swift
            if let drawnRegion { … }                       // unchanged
            else if wasDrawingLine {
                model.withScene(persist: false) {
                    if let id = interaction.endLine(at: contentPoint, in: &$0) {
                        model.selection = .line(id)
                        mintedLine = true
                    }
                }
            } else if let movedNode, interaction.hasMoved { … }   // unchanged
```

**A line drag that minted nothing is not a structural change**, and it takes the same guard the sweep already has: the `bumpSceneRevision()` at the bottom is conditional on `drawnRegion == nil || mintedRegion`, and that predicate must grow the line term rather than a second `if` beside it. Every ⇧-press on a card that drifted a point would otherwise sort the scene, copy every scrap's string and rebuild two cached lists in the other column.

**Do not restructure that switch.** Three tasks across three plans now write into `handleDrag`, and every guard, bump and bail-out in it is load-bearing in 1C-a or 1C-b — the coast truncation and its bump, the `wasResizing` unconditional `rebuildLayouts()`, the `endGesture()` placement *above* the `hasMoved` bail-out, and the `momentum.launch`. An earlier draft of this task lost six of them by rewriting rather than extending.

- [ ] **Step 6: Run the tests and a Release build**

`./gen.sh && … -only-testing MaughamTests/CanvasLineGestureTests` — PASS, 16 tests.
`-only-testing MaughamTests/CanvasViewMountingTests` — PASS, and **confirm the count grew by three.**
`-only-testing MaughamTests/CanvasInteractionTests`, `MaughamTests/CanvasRegionInteractionTests`, `MaughamTests/CanvasEventViewTests` — all PASS. `begin`'s new argument touches every one of them.
Release build — BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas project.yml
git commit -m "feat(canvas): draw a line by ⇧-drag, or from the selected card's mark

Two routes resolved to one Bool before CanvasInteraction sees anything, so
the discoverable route and the fast one cannot drift apart. The modifier is
threaded through the event view rather than read off NSEvent at the point
of use, so the whole gesture is reachable from a test that sends a real
event through the window. A drag that minted no line is not a structural
change and takes the sweep's own guard."
```

---

### Task 5: Selecting a line, and taking it back

**Files:**
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: extend `MaughamTests/Canvas/CanvasLineGestureTests.swift`, `MaughamTests/Canvas/CanvasViewMountingTests.swift`

**Interfaces:**
- **Consumes:** `CanvasLineHit.line(at:in:)` (Task 1), `CanvasSelection.line` (Task 3), `CanvasModel.selectedLine` (Task 3).
- **Modifies:** `CanvasView.selectionTarget(at:)`, `CanvasView.ClickTarget` + `clickTarget(at:)`, `CanvasView.deleteSelection()`.

**The hit precedence is: card, then a line, then a region's chrome or resize corner, then nothing — which is the draw order read backwards, and that is the entire justification.** Cards first and unconditionally, matching `CanvasInteraction.begin`'s own precedence, so clicking a thing and dragging it never disagree about which thing it was. Then lines, because Task 3 draws them above every part of a region: **the thing drawn on top takes the click.**

**This reverses an earlier draft of this plan, and the reasoning is worth keeping** because the reverse reads perfectly plausible. That draft gave the region chrome priority on the grounds that the bar is a region's only grab handle — true, but it left the line drawn *over* the bar while the bar took the click, so hit-testing disagreed with what was visibly frontmost. Measured against each other the two losses are both negligible: a near-perpendicular crossing costs the line about 24 pt of a length in the hundreds, and costs the bar about 12 pt of a width in the hundreds. Neither is worth a special case. What the draw order buys is **one rule for the whole surface, stated once, that a later tidy-up cannot drift away from** — and it is not a new rule, since cards already beat region chrome *and* draw above it.

Write the rule in the comment, not the trade. If someone re-opens this, the question to put to them is which package they are proposing *whole* — draw order and click order move together or the defect comes straight back.

**`clickTarget` gains a line case, and this is a real bug the draft would have shipped.** Today a double-click on a line falls through to `.emptyCanvas` and **mints a scrap under it** — and AppKit sends `clickCount: 1` first, so the first click has already selected the line. The writer gets "Edit Scrap" open while the inspector shows a line: tripwire 32's own repro shape, arriving through a new door. The line case behaves exactly like `.unenterableNode` — it falls to `leaveTheOpenScrap()` and mints nothing. **A double-click on a line does not open an editor of any kind**; the label is edited in the other column (Task 6), which is where the region's label already is.

**`deleteSelection`'s `.line` arm replaces Task 3's stub**, and inherits both existing rules without restating them: the `isInGesture` guard at the head (a delete inside somebody else's bracket registers no step of its own and, if that bracket never closes, is not recoverable at all), and the `return false` for a selection that no longer resolves (nothing went, so nothing was used, so the key travels on and AppKit beeps).

**A line delete never touches its cards**, and a card delete already takes its lines with it (Task 1). One gesture either way, so one ⌘Z.

- [ ] **Step 1: Write the failing tests**

Model-level:
- `test_clickingALineSelectsIt`
- `test_aLineToAResidentOfACollapsedRegionIsNotClickable` — and its control, that the same line becomes clickable again when the region is expanded. Drawing and hit testing take one rule (Task 3 added the `!scene.isHidden(_:)` filter to `lineGeometry`); a line the writer can click and cannot see is worse than one they can see and cannot click.
- `test_aClickOnACardBeatsALineRunningUnderIt` — the control for the precedence, and the reason it is first.
- `test_aClickOnALineCrossingARegionsChromeBarSelectsTheLine` — the reversal, with the rule in the message: the line is drawn on top there, so the line takes the click.
- `test_aClickOnTheSameChromeBarAwayFromTheLineStillSelectsTheRegion` — the control the reversal needs. Without it, "the line wins" is satisfied by a build where a region with a line anywhere near it can no longer be grabbed at all.
- `test_theClickOrderIsTheDrawOrderReadBackwards` — assert the two orders against each other rather than each against a literal, so a change to one that is not made to the other goes red. This is the test that would have caught the earlier draft's shape, and it is the reason both orders live in one place.
- `test_aClickOnBareCanvasClearsALineSelection`
- `test_deleteRemovesTheSelectedLineAndLeavesBothCards` — `scene.count` unchanged, and one ⌘Z brings the line back.
- `test_deleteWithALineSelectedMidGestureIsRefused` — open a gesture, ⌫, the line survives and `deleteSelection` returned false.
- `test_deletingACardTakesItsLinesAndOneUndoBringsBothBack` — one snapshot carries the scene, so they cannot be restored out of step.
- `test_undoingBackPastALineClearsAStaleLineSelection` — `selectedLine` is nil, not a dangling id. This is `clearSelectionIfItNoLongerResolves`' `.line` arm, and nothing else can see it.

Through the real path, in `CanvasViewMountingTests`:
- `test_aDoubleClickOnALineDoesNotMintAScrapUnderIt` — **send both clicks**, `clickCount: 1` then `clickCount: 2`, exactly as the writer's hand produces them. A test that jumps straight to `clickCount: 2` proves nothing here; that shortcut has produced a wrong repro five times in this area.
- `test_backspaceDeletesTheSelectedLineThroughTheRealResponderChain` — a real `NSEvent` through `window.sendEvent(_:)`, and **read what reached DISK**. Do not replace it with one that calls `deleteSelection()`: that is precisely the test that passed throughout 1C-a while ⌘Z was greyed out in the Edit menu.

- [ ] **Step 2–4: RED, implement, GREEN**

Add `case line(CanvasLineID)` to the private `ClickTarget` enum and the branch to `clickTarget(at:)`; add the line test to `selectionTarget(at:)` **between the node hit and the region hit**; fill in `deleteSelection`'s `.line` arm with `model.mutate("Delete Line") { $0.removeLine(id) }` and let the shared tail (`model.selection = nil`, `bumpSceneRevision()`, `scheduleSave()`, `return true`) do the rest.

- [ ] **Step 5: Caller census**

```bash
grep -rn "CanvasLineHit\|selectedLine\|removeLine\|insertLine\|endLine\|pendingLine\|connectHandle" Maugham/
```

Every function Tasks 1–5 added must appear with at least one **production** caller. Record the list in the task report. `CanvasScene.remove`'s line scrub, `updateLine` and `lines(touching:)` are the three most likely to be reachable only from tests at this point — `updateLine` gets its caller in Task 6, and if `lines(touching:)` still has none by Task 7, **delete it** rather than shipping a fourth unreachable half.

- [ ] **Step 6: Run the tests and a Release build**

Filtered runs, then `MaughamTests/CanvasViewMountingTests` and `MaughamTests/CanvasUndoTests` in full. Release build.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasView.swift MaughamTests/Canvas project.yml
git commit -m "feat(canvas): select a line, and ⌫ takes it back

Click order is the draw order read backwards — card, line, region — so the
thing drawn on top takes the click, and there is one rule rather than a
special case for the chrome bar. A double-click on a line no longer mints a
scrap under it: the first click had already selected the line, which is
tripwire 32's repro arriving through a new door."
```

---

### Task 6: The line's label, in the right-hand column

**Files:**
- Create: `Maugham/Canvas/LineInspector.swift`
- Modify: `Maugham/Canvas/RegionInspector.swift` (`RegionInspectorPane` only)
- Modify: `MaughamTests/TripwireGrepTests.swift` (the census expectation)
- Test: `MaughamTests/Canvas/LineInspectorTests.swift`

**Interfaces:**
- **Consumes:** `CanvasModel.selection`/`selectedLine`/`mutateFromInspector`/`sceneRevision`; `CanvasScene.updateLine` (Task 1); `RegionInspectorPane` (`RegionInspector.swift:14`).
- **Produces:** `struct LineInspector: View` with `static func normalise(_ raw: String) -> String?` and `func commitLabel(_ new: String)`; a third arm on `RegionInspectorPane`'s body.

**A sheet was the draft's answer and it is the wrong one.** The region's label is edited in the right-hand column; a line's belongs in the same place, for the same reasons — no modal to dismiss, the same discovery path, and the selected thing is described where the writer already looks. It also puts the edit on the correct side of tripwire 32.

**This file MUST use `mutateFromInspector` and MUST be added to the census expectation** in `TripwireGrepTests.test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly`, which today asserts the census equals exactly `["RegionInspector.swift": ["mutateFromInspector"]]`. It becomes a two-entry dictionary. **The census is not a ban — it names the call sites**, so adding a legitimate one is a deliberate edit there rather than a mystery failure. Adding the file without updating it fails the suite; updating it while calling `mutate` fails the suite differently, which is the point.

**Why the outside verb, concretely.** A visit to a scrap holds "Edit Scrap" open for as long as focus is in it, and nothing on the inspector's side closes it. Through `mutate` the rename would nest: depth 2 takes no snapshot, depth 1 registers nothing, **and the label change is on no undo step at all** — worse than absent, because the open gesture's baseline predates it, so the writer's next keystroke carries the label into a step called "Edit Scrap" and a ⌘Z aimed at a sentence takes the line's name with it.

**Every commit checks the value actually moved before mutating**, exactly as `RegionInspector.commitLabel` does. The field commits on focus loss as well as on ⌘↩, so the no-op commit is the common case. What the guard buys past `endGesture`'s own decline is the rest: no snapshot, no queued disk write, no canvas redraw.

**Whitespace-only is *no label*, not a label made of spaces** — storing one draws an empty pill on the line forever. `normalise` is `static` and pure so that rule is testable without hosting SwiftUI.

**Tripwire 15 applies to the empty state.** `RegionInspectorPane`'s existing `ContentUnavailableView` chains `.frame(maxWidth: .infinity, maxHeight: .infinity)` and depends on `DetailPaneToggle`'s outer `alignment: .top`. Do not break that chain while adding the third arm; it has recurred four or more times.

**Tripwire 16 does not apply.** That rule is about an inline rename `TextField` appearing inside a `List(selection:)` row and racing the list's focus pass. This field is always present in a static form.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/LineInspectorTests.swift`, following `RegionBindingTests`' shape:
- `test_whitespaceOnlyIsNoLabelRatherThanALabelOfSpaces` — `normalise` over `"   \n "`, `""`, and `"  because of the ponchos  "`.
- `test_committingALabelIsOneUndoStepCalledLabelLine` — assert `model.undo.undoMenuItemTitle`, then ⌘Z, then that the **line still exists** and only its label went.
- `test_anUnchangedLabelRegistersNothing` — commit the same string twice; `undoManager.canUndo` is unchanged by the second.
- `test_aCommitFromTheInspectorWhileAScrapIsFocusedIsItsOwnStep` — **open a real "Edit Scrap" gesture first**, commit the label, and assert the step's own name. This is the one that goes red if `mutateFromInspector` is ever swapped for `mutate`, and its premise (a gesture is genuinely open) is asserted rather than left in a docstring.
- `test_clearingTheLabelRemovesItRatherThanStoringEmptyString`

And in `TripwireGrepTests`, no new test — the existing census's expectation changes, and `test_canvasUndoBracketCensusFiresOnAPlantedInsideVerb` already proves it fires.

- [ ] **Step 2–4: RED, implement, GREEN**

`RegionInspectorPane.body` routes on `model.selection`:

```swift
        switch model.selection {
        case .region: … RegionInspector(…)
        case .line:   … LineInspector(…)
        case .node, .none: … ContentUnavailableView(…)
        }
```

**Resolve `selectedRegion`/`selectedLine` HERE, one leaf down from `ProjectWindow`, and nowhere higher.** `CanvasModel` is `@Observable` with the whole scene in one stored property, which every drag frame and every coast frame writes — resolving in `ProjectWindow.canvasInspector` would register the whole window's body as a dependency of the drag loop and re-evaluate it at 60–120 Hz. The doc comment at the top of `RegionInspector.swift` says this; keep it true.

`.node` selected shows the same empty state as nothing selected. **A scrap inspector is not this plan's**, and inventing a stub one here would be a surface with nothing to say.

- [ ] **Step 5: Update the census and run it**

Edit the expectation in `TripwireGrepTests` to `["LineInspector.swift": ["mutateFromInspector"], "RegionInspector.swift": ["mutateFromInspector"]]`, in the same commit as the file.

`-only-testing MaughamTests/TripwireGrepTests` — PASS. Then `MaughamTests/RegionBindingTests`, `MaughamTests/LineInspectorTests`, `MaughamTests/CanvasPersonaTests`. Release build.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas MaughamTests project.yml
git commit -m "feat(canvas): name a line in the inspector, beside the region

Through mutateFromInspector, never mutate (tripwire 32): a visit to a scrap
holds Edit Scrap open and nothing on the inspector's side closes it, so
through the inside verb the label would land on no undo step at all and
ride into the writer's next sentence."
```

---

### Task 7: VoiceOver, and the docs sweep

**Files:**
- Modify: `Maugham/Canvas/CanvasAccessibility.swift`
- Modify: `Maugham/Canvas/AREA.md`, `docs/guide/getting-started.md`, `docs/roadmap.md`, `docs/problem-map.md`
- Test: extend `MaughamTests/Canvas/CanvasAccessibilityTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene.lines`/`lines(touching:)` (Task 1); `CanvasAccessibility.elements(scene:scraps:)` and `summary(scene:)`.

**Drawn content has no accessibility tree and §7A.6 calls one "not optional in a writing tool".** A line is invisible to a VoiceOver user by default, and a relationship nobody can perceive is not a relationship.

**Lines do not become elements of their own.** An element carries a content-space frame, and a line's is a bounding box a user would navigate into and find nothing in. Instead: **each connected node's label names how many lines touch it and what they are called**, and `summary` reports the total. That keeps the whole line layer on the `sceneRevision` rebuild — `elements` is already gated there, never on `revision` — and adds no new frame path.

**`lines(touching:)` gets its production caller here.** If this task is reached and it still has none, that is the Task 5 census's answer arriving late; use it or delete it.

**Open for the VoiceOver walk, and recorded rather than resolved:** whether a line should be independently navigable. `AREA.md` already carries one such divergence (the focused scrap announced twice) and it is answered by a real VoiceOver session, not a unit test. Add this one beside it in the same voice.

- [ ] **Step 1: Write the failing test**

- `test_aConnectedScrapSaysSoInItsLabel` — and an unconnected one does not. The negative half is the control.
- `test_aLabelledLineIsNamedInBothItsEndpointsLabels` — the label is the only thing a line says, so it must reach both ends.
- `test_theSummaryReportsTheLineCount`
- `test_theTreeIsStillNotKeyedOnTheRedrawCounter` — the existing tripwire-30 test must still pass; add the line fields to whatever fixture it drives so its coverage grows with the tree rather than staying frozen at 1C-b's shape.

- [ ] **Step 2–4: RED, implement, GREEN**

- [ ] **Step 5: `Maugham/Canvas/AREA.md`**

Add a **"Lines"** section, in the file's existing voice — the rule, then the named symptom if it is broken:

- **Untyped, and it must not gain a `kind`.** Kinopio shipped author-typed connections for years and removed them in April 2026 for confusing first-time users. Spec §5, §9.
- **Two routes draw one, and they resolve to one Bool before `CanvasInteraction` sees anything.** ⇧-drag from any card is the fast route; a drag from the connect mark on the **selected** card is the findable one. `CanvasView` decides — the mark test needs the selection, and handing that to the gesture layer would give it a second opinion about what is selected. Keeping the routes joined at `connecting:` is what stops the discoverable one and the fast one drifting into behaving differently.
- **The connect mark is drawn only on the SELECTED card**, inside `drawCard`'s `isSelected` block — *not* beside the unconditional `resizeHandle` fill two lines below it, which the two adjacent calls make very easy to get wrong. Hover-revealed handles (the tldraw/Miro/FigJam/Obsidian consensus) were rejected because they need `NSTrackingArea`, `mouseMoved`, a hovered-node state and a redraw per pointer move — new per-frame state on a surface whose architecture is keeping per-frame work viewport-proportional — and because handles blooming on every card the pointer crosses is the diagramming look §5 positions against. Scapple's border-drag was rejected for stealing an eighth of the card from *move*, inside the `r·θ` band, along the edge where the text starts. A **permanent** mark was the closest call, since `drawCard` already inks the resize triangle unconditionally; it lost only because a second always-on mark overstates a thing §5 calls costless to be wrong about.
- **The connect target is on the right edge, vertically centred, clamped above the resize square**, both sized from one constant so the mark and the target cannot drift. On a card too short for both, **the corner belongs to resize** — it is the permanent mark, and a target that moved with the card's height would be worse than one sometimes absent. Target ≥ mark, for the reason `test_theUnmarkedHalfOfTheCornerSquareStillResizes` exists.
- **The first press on an unselected card's handle position must NOT connect.** The mark was not drawn there, so the writer aimed at nothing. `applyMouseDown` fires `onClick` before `onDrag(.began)` — a written contract, not an accident — so click-then-press is two gestures and that is correct.
- **The modifier is threaded through `CanvasEventNSView.applyMouseDown` rather than read off `NSEvent.modifierFlags` at the point of use** — a static global read cannot be driven by a test that sends a real event, and this area has shipped a whole feature nothing could reach. `begin(at:in:connecting:)` has **no default** on that argument, deliberately: a default hides the fact that there is exactly one caller. Only `.began` reads it, so a modifier released mid-drag does not abandon the line in progress.
- **Endpoints are node CENTRES** — the same reading `joinTarget` takes for a drop, so the canvas has one answer to "where is this card". A line to an unmeasured node is neither drawn nor clickable: drawing to a guessed position twitches the moment the measurement arrives.
- **A line to a resident of a COLLAPSED region is neither drawn nor clickable either**, and the reason it is easy to miss is that the geometry says nothing: a hidden node keeps its frame, and `endpoints(of:)` reads the frame. `lineGeometry` filters on `!scene.isHidden(_:)`, joining `tethers` and `appearanceChips`, which guard the same thing for the same reason. Drawing and hit testing take the identical rule — a line the writer can click and cannot see is worse than one they can see and cannot click. **The 1C-c1 plan shipped without this and Task 3's review caught it**; it is written here because nothing in the geometry will remind the next author.
- **`CanvasLineHit.distance` clamps at BOTH ends.** Without it a click far past either card lands on the infinite line the segment sits on. `line(at:)` takes the NEAREST rather than the first found — two lines leaving one card run within a few points of each other for their whole first stretch.
- **ONE RULE: cards over lines over regions, in drawing and in hit-testing alike.** The click order is the draw order read backwards, and `test_theClickOrderIsTheDrawOrderReadBackwards` asserts the two against each other rather than each against a literal — so a change to one that is not made to the other goes red. Cards beat everything unconditionally, matching `CanvasInteraction.begin`, so a click and a drag never disagree about which thing it was.

  **This is not a new rule** — cards already beat region chrome *and* draw above it — which is exactly why lines slot in rather than becoming an exception, and why there is no second rule here to defend.

  **An earlier draft of the 1C-c1 plan had it the other way**, giving the chrome bar priority because it is a region's only grab handle. That is true and it is still the wrong answer: it left the line drawn *over* the bar while the bar took the click, which is hit-testing disagreeing with what is visibly frontmost. Splitting `drawRegion` so lines slide under the label does not rescue it either — the bar's tint stays under the visible line. Measured, both losses are negligible: a near-perpendicular crossing costs the line ~24 pt of a length in the hundreds and costs the bar ~12 pt of a width in the hundreds. **If anyone re-opens this, the question is which package they propose *whole*; draw order and click order move together or the defect returns.**

  *Open, for a smoke session and not for a unit test:* a hairline at `lineOpacity` crossing a region's 11 pt label, which only happens for a line entering a region from directly above. If it reads as damage, nudge the label.
- **A double-click on a line mints nothing.** It fell to `.emptyCanvas` in the first draft and made a scrap under the line the `clickCount: 1` click had just selected — tripwire 32's repro shape arriving through a new door.
- **Lines draw as a pass INSIDE `CanvasRenderer.draw`, between regions and cards** — above the *whole* region pass, which inks the wash, the bar, the label, the collapsed count and the region's resize triangle in one go. The order is the sequence of calls, exactly as it is for the other four passes. **There are no layer-depth constants and adding some would enforce nothing.**
- **The draw pass culls** — `visibleLines`, never `lineGeometry`. Lines are the one collection on this surface that nothing bounds.
- **The hairline inset in `visibleLines` is DEFENSIVE, and the obvious story about it is false.** Measured 2026-07-28 on macOS 26.5: `CGRect.intersects` is false only for a **null** rect, not an empty one — `CGRect(x: 100, y: 20, width: 440, height: 0).intersects(CGRect(x: 0, y: 0, width: 800, height: 600))` is **true**, so a horizontal line's zero-height box survives culling unaided. What the inset defends against is one spelling over: `!box.intersection(viewport).isEmpty` reads as an obvious equivalent, is false for that same box, and culls every horizontal and vertical line on the canvas — silently, totally, and two cards side by side is the ordinary case. **Do not write the version of this note that says `intersects` fails on an empty rect.** The 1C-c1 plan said exactly that, an assertion written from it was green with the inset deleted, and a rule whose stated reason is false is worse than no rule: the next author tests the reason, finds it holds without the code, and deletes the code.
- **`CanvasScene.lines` sorts on every access and that is currently safe**, unlike `nodes`. If a canvas ever makes it measurable the fix is an `unorderedLines` peer, exactly as `nodes`/`unorderedNodes` split — not a cache.
- **Deleting a node deletes its lines** (`CanvasScene.remove`), and self-lines are rejected in `insertLine` — the codec goes through `insertLine`, so that rule has one definition.
- **The label is edited in the RIGHT-HAND COLUMN through `mutateFromInspector`**, never in a sheet and never through `mutate`. The census in `TripwireGrepTests` names `LineInspector.swift` for that reason.
- **A line drag that minted nothing is not a structural change**, and it shares the sweep's guard rather than growing a second one.

Extend the two-counter table's `sceneRevision` row with drawing and deleting a line, and add the VoiceOver divergence beside the existing one.

Update the **"What the canvas does not do yet"** section: 1C-c's entry becomes promotion only, and **lines move out of it into the body of the file** — the same treatment regions and delete got, recorded rather than quietly deleted.

- [ ] **Step 6: Sweep the guide, the roadmap and the problem map**

`docs/guide/getting-started.md`, "The planning canvas". Describe only what **ships** (CLAUDE.md rule 7). **Lead with the findable route, not the shortcut**: click a card and a small mark appears on its right edge — drag from it to another card to draw a line between them; once you know it is there, ⇧-drag from any card does the same without selecting first. Then: click a line to select it and name it in the Inspector; ⌫ removes it and leaves both cards; deleting a card takes its lines with it; a line drawn over a region takes the click there, because it is the thing on top. And plainly, once: lines are scratch — they stay on the canvas and are not the durable relationship layer. **Do not describe promotion, item thumbnails or dragging research in.**

Its closing line currently reads *"Connecting lines, dragging research onto the canvas, and turning a scrap into a real chapter or note are all still to come."* — drop lines from that list, keep the other two.

`docs/roadmap.md:56` — split the `• 1C-c` entry into `1C-c1` (✓, this plan), `1C-c2` (• promotion) and `1C-c3` (• the MCP canvas surface), with the split's reason in one clause. **Do not flip the M1C parent to ✓**: §8A.1's images are inside M1C, 1C-d is unwritten, and promotion is the step that makes the canvas pay off.

`docs/problem-map.md:28` — the planning row's parenthetical says lines are still to come. Lines are now in; promotion and dragging research in are not. Move the row's status only as far as the evidence supports.

**No new tripwire.** Nothing this plan ships is a rule someone would break by accident that the compiler and the existing tests do not already catch: `CanvasSelection`'s new case is compiler-enumerated, the undo verb is the existing census, and the culling inset has a test whose message names the symptom. **32 is taken by 1C-b** — the draft's arithmetic was wrong — so if 1C-c2 or 1C-c3 needs one it is 33.

- [ ] **Step 7: Full verification**

```bash
./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```

All green. The phone suite must be untouched — this slice adds no MaughamCore and no phone code (§9), so a phone failure means something leaked into the shared package. If the simulator reports "Busy / failed preflight checks" more than twice, `xcrun simctl boot` the device the destination actually resolves to rather than re-running (observed once on 2026-07-28; a second occurrence makes it a rule).

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas docs MaughamTests project.yml
git commit -m "docs(canvas): lines reach VoiceOver, AREA.md and the guide

No new tripwire: the new CanvasSelection case is compiler-enumerated and
the undo verb is the existing census. 32 is 1C-b's — the draft's arithmetic
was wrong, and the next free number is 33."
```

---

## Whole-slice verification

- [ ] Full Mac suite, full phone suite, Release build — all green
- [ ] **Caller census over everything the slice added**, in one command, with the answer in the report:
      `grep -rn "CanvasLine\|lineGeometry\|visibleLines\|lineLabelBox\|endLine\|pendingLine\|selectedLine\|connectHandle\|LineInspector" Maugham/`
      Every symbol has a production caller, or it is deleted. Three unreachable halves have shipped in this area and **all three were found this way, none by a test.**
- [ ] **Whole-branch review of the 1C-c1 diff.** Per-task reviews cannot see emergent interactions (the T5×T6 precedent). Look especially at:
      - `handleDrag`'s `.ended` chain — Tasks 4 and 5 both write into it, and 1C-b's guards interleave with the new branch;
      - the `bumpSceneRevision` predicate, which now has two "minted nothing" terms;
      - `CanvasView.swift`'s five source-layout contracts, which no task should have disturbed and every task could have.
- [ ] **Ask it of every assertion written:** could this have failed for the reason it exists? Nine assertions that could not were found during 1C-b, several in the plan's own test code — one passing on 8-bit quantisation noise, one on a coincidence where the test's own ⌘Z composed two steps into the right answer. Mutation batteries are the house standard.
- [ ] **Smoke, by hand:**
  1. click a scrap → **the connect mark appears on its right edge** → drag from it to another scrap → a dashed band follows the pointer → release → a line appears and is selected. **Then click elsewhere: the mark is gone.** This is the discoverability claim, and it is the one to judge first — everything after it assumes the writer found the gesture.
  2. ⇧-drag from a scrap that is *not* selected → the same line, no mark needed
  3. the Inspector shows the line → type a name → ⌘Z → the name goes → ⌘⇧Z → it comes back, and the Edit menu said "Undo Label Line"
  4. click a card that a line runs under → the **card** is selected, not the line
  5. click a region's chrome bar **where a line crosses it** → the **line** is selected, because it is the thing drawn on top. Then click the same bar a little to one side → the **region**. Does the rule read as obvious, or as the region having become hard to grab?
  6. **double-click a line → no scrap is created** (this is the one the earlier draft would have shipped broken)
  7. select the line → ⌫ → the line goes and both cards stay → ⌘Z → it comes back
  8. delete a card the line touched → the line goes with it → one ⌘Z brings back both the card, its words and the line
  9. ⇧-drag from a card back onto itself, and onto bare canvas → nothing is created either time
  10. zoom out until the cards are small → the lines still land on the cards' middles; zoom in past 2× → clicking a line still selects it, and the connect mark is still aimable
  11. lay two cards exactly side by side so their line is perfectly horizontal → **it draws** (the axis-aligned culling case)
  12. quit and reopen → lines, labels, and everything but the selection survive
  13. **Is the connect mark enough?** Item 1 is the test. If a writer who has not read the guide does not find it, the remaining fallback is a hover-revealed handle — and that costs `NSTrackingArea`, `mouseMoved` and a hovered-node redraw, so it is a real change and not a tweak. If instead the mark reads as *clutter* on the selected card, the answer is the opposite one: drop it and keep ⇧ alone. Both are UI changes, not model ones.

---

## What 1C-c2 and 1C-c3 inherit

Do not write either plan until 1C-c1 is **built and merged**. Both read `CanvasSelection`, which this plan changes, and both were drafted against an API that turned out to be wrong in eleven places. Re-derive each against the built code — that ordering is the whole lesson of `memory/feedback_plan_detail_and_sequencing.md`, and 1C-b is the evidence it works.

### 1C-c2 — promotion

Spec §6 and §6.1. One previewable verb turning a scrap, a region or a line into a durable artifact. Roughly: the promotion model (pure, §6's table executable), the performer, the sheet, and the gesture that resolves spec §10's first open question.

What survives the re-derivation and is worth carrying over:

- **The `.wikiLink` rule is the spec, not a deviation.** Spec §6.1 now carries the rule *and its evidence* verbatim: `[[X]]` resolves against the manifest (`ProjectStore.resolveDocumentId(forTitle:)` over documents, `ListAllLinksTool`'s title index over documents *and* research items) and a scrap is in neither. Quote §6.1. **Do not write "deviation" anywhere, least of all in an ADR** — an earlier spec draft read "when both ends are text" and was corrected on 2026-07-25; a deviation recorded in an ADR would outlive the draft that caused it.
- **`PromotionPerformer` must be `@MainActor` and `async throws`, and no `inout` may appear on that path.** `ProjectStore` is `@MainActor` and `addResearchTextNote`, `addPaletteCard`, `updatePaletteCard` and `createCraftIntent` are all `async throws`. An `inout CanvasScene` cannot cross an `await` in Swift 6. Scene changes go through `CanvasModel`, synchronously, after the awaits.
- **It is subject to tripwire 32.** `PromotionPerformer.swift` is not `CanvasView.swift`, so it must use `mutateFromInspector` and join the census expectation. This is not a formality: `beginPromotion` runs while "Edit Scrap" may be open.
- **`flushPendingSave()` before every body write** (`DocumentStore.swift:259`; the reasoning is at `AddNoteTool.swift:48-55`) — a queued 750 ms `scheduleFileSave` otherwise fires after the write and blanks the note.
- **Validate first, write second**, so a refused promotion leaves nothing behind.
- **⌘⇧P is taken** by "Toggle Research Preview" (`MaughamApp.swift:208`); **⌘⇧↩ is free**, verified against every `keyboardShortcut` in that file. Note there is already a `maughamPromotePiece` notification for collection pieces — a canvas one needs a distinct name and the menu wording should not collide.
- **`ProjectWindow.pieceChoices(in:)` already exists** — do not re-derive the `TreeWalk`.
- **`CanvasRegion.displayLabel` and `untitledLabel` already exist** — do not mint a second "Untitled region".
- **A `store` on `CanvasView` must never be read from `body` or anything `body` calls.** `ProjectStore` is `@Observable`; one read in the body tree re-evaluates the whole canvas on every manifest mutation, including the `modified` bump an autosave in another pane produces. `paletteSwatchHexes` is a deferred closure for exactly this reason.
- **Its own additive-optional schema bump** for `promotedItemID` — do not fold it into 1C-c1's.
- Spec §10's promotion-gesture question is 1C-c2's to close, in an ADR.

### 1C-c3 — the MCP canvas surface

Spec §8A.2. `list_canvas` and `add_canvas_scraps`, and the constitution's reproduction corollary made structural.

- **Tool count is 52** today (`MCPToolCatalog.all`). Both docs literals are real: `CLAUDE.md`'s `**52 tools**` and `Maugham/MCP/AREA.md`'s `## Tool catalogue (52)` — **plus a second, prose occurrence at `AREA.md:92` that `DocSyncTests` cannot see**, because it matches on `firstMatch`. `grep -n "52" Maugham/MCP/AREA.md` and fix every hit. A new tool breaks at least three tools-list tests.
- **`MCPTool` is `static var method` / `description` / `inputSchemaJSON` and `@MainActor static func handle(paramsJSON:registry:)`.** There is no `name` and no `run(projectRoot:)`. `decodeParams`/`resolveProject` are protocol-extension helpers (`MCPToolHelpers.swift`), and an unknown project throws `MCPError.unknownProjectID`, not `invalidArgument`.
- **The write tool is subject to tripwire 32, and this is the sharpest instance.** The draft's `model.beginGesture` / `withScene` / `setScrapText` / `endGesture` inside `CanvasTools.swift` would fail the census — and the failure it names is real: an MCP write arriving while the writer holds "Edit Scrap" open registers no undo step of its own and rides into the writer's next sentence. Use `mutateFromInspector` and join the census.
- **`ProjectStore.canvasModel` goes in `ProjectWindow.load()`**, beside `s.documentStore = ds`. The `@State` is named `canvasModel`, not `canvas`.
- **The corollary is enforced by what the signature cannot express** — no position, no node id, no region id — and the scene mutation should be a pure `inout` function of its own, separate from the tool, so the live-model and on-disk paths share one definition of where Claude puts things. That separation was the draft's best idea and it survives whole.
- Its own additive-optional schema bump for `author`, reusing `AnnotationAuthor.SourceKind` (`SpanAnchor.swift:23`) rather than minting a second provenance enum, per spec §8A.2 constraint 1.
- Spec §10's MCP-write-surface question is 1C-c3's to close.

### After 1C-c

Build 1C-c2, then 1C-c3, then re-derive **1C-d** (§8A: item thumbnails, the drop target, images) against all of it. Then **1A**, the spine — which forces a paired Mac + phone release, because adding an `OpKind` bumps the manifest schema and an older phone build refuses to open the project at all.

**M1 is complete only when 1A, 1B and the whole of 1C are in. Do not push or tag before then.** Slicing the implementation is fine; slicing the release is not.
