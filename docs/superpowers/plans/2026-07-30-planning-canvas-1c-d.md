# M1C-d — getting things onto the canvas

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`. Steps use checkbox (`- [ ]`) syntax.

**Goal:** An item node becomes a thing the writer can *see* — real title, kind glyph, thumbnail — and four routes put things on the canvas: a research drag, an external file or browser drop, an inbox capture, and the canvas at full width.

**Architecture:** An item node gains a second provenance. `CanvasNodeKind.item` currently carries a bare `referenceId` and means *this already exists in the project*; it comes to carry a two-case `CanvasItemReference` — `.project(id:)` for that, and `.owned(path:)` for a capture or a drop that has nowhere else to live (spec §3.1's 2026-07-30 amendment). Owned assets are ingested through **one pair** on `ProjectStore` over the saver research notes and palette cards already share, into `canvas_assets/` beside `canvas.md`. Every route — research drag, Finder drop, browser bitmap, inbox — is a **caller** of that pair, never a storage decision of its own. What an item node *shows* is resolved from the manifest (referenced) or from the path (owned), cached against a manifest-change key, and never computed in `body`.

**Tech stack:** Swift 6, SwiftUI + AppKit, `CGImageSource` for downsampling. No new dependency. **No new MCP tool** — spec §8A.4 rules the inbox route has no MCP write path, so the catalogue stays at 54 and no tools-list test moves.

---

## How this plan is written, and why it is not the skill's default shape

**It carries contracts, symptoms and verified signatures — not function bodies.** That is a standing ruling (`memory/feedback_plan_code_is_a_liability.md`): full bodies in a plan become the shipped defect, because an implementer edits them into place instead of writing against the file. It is also what held up last time — the 1C-c3 plan carried almost no code on purpose and that survived contact; what failed was its ordering table, wrong in two of five rows. So each task states **the requirement, the failure it must not have, and the test that must exist**, and leaves the ordering to the implementer reading the real file.

**Every signature quoted below was read out of the tree on 2026-07-30**, at the line given. Anything not quoted is deliberately not asserted.

**Tasks 9–13 are stated, not written.** Task 8's whole deliverable is turning them into full tasks against the code tasks 1–7 will have built. This is not a placeholder: writing them now would mean writing contracts against Swift that does not exist, which is the thing that cost M1C four review rounds and three near-deletions of one plan's work by another. It is one plan, one branch, one whole-branch review, one smoke, one merge.

---

## Global constraints

Every task's requirements implicitly include these.

- **This is a slice boundary, never a milestone one.** Spec §8A.1 puts images **inside M1C**, "not deferred past it", and says no plan may cite it as authorising their omission. This plan may not be cited to that end either.
- **Nothing is pushed or tagged.** M1 ships when 1A, 1B and the whole of 1C are in. `main` is at `fb81e54`, 224 commits unpushed, deliberately.
- **Tripwire 31 — no *transition* is ever membership.** If you write `region.frame.contains(…)` in a move or a resize path, stop. A drop and a creation are the only geometric readings, and both read the node's **centre**.
- **Tripwire 32 — the two undo-bracket verbs are not interchangeable.** From inside `CanvasView`, a mutation arriving mid-gesture is refused. From another column there is no gesture of the caller's own to protect, so it goes through `CanvasModel.mutateFromInspector`. **Count the census array in `TripwireGrepTests`, not any prose count** — a "four files" claim over a five-entry array survived three review passes one slice ago.
- **Tripwire 22 — an image cache is keyed by PATH, not id.**
- **Tripwire 4 — no per-row/per-node computation without caching.** Anything scene-proportional keys on `sceneRevision`, never `revision` (tripwire 30).
- **Tripwire 26 — `NSTextContentStorage.textStorage =`, never `.attributedString =`.**
- **Every new production primitive gets its callers counted before it is called done.** `grep -rn <symbol> Maugham/` — this area has shipped **four** built-and-unreachable halves and every one was found by a caller count, never by a test.
- **A task that adds a production caller runs the census suites**, not only the suites for the types it edits: `grep -rln "test_.*HasAProductionCaller\|productionFiles()" MaughamTests/` — three files. A census went red and stayed red for four tasks because one brief listed only the latter.
- **Commit in coherent pieces as you go.** Two subagents died mid-task on transient API errors last slice, leaving 598 and then 8 files uncommitted.
- **Do not run the MCP transport suites.** Use `-skip-testing:MaughamTests/MCPServerLifecycleTests`, and apply the fails-in-suite/passes-alone discriminator before believing a red run is yours (`docs/superpowers/notes/2026-07-29-mcp-clock-dependent-tests.md`).
- **`XCTAssertNil` through an optional chain is censused** in `MaughamTests/Canvas` — unwrap first, or annotate `// nil-chain-ok: <reason>`.
- **A calibration figure quoted in `Maugham/Canvas/AREA.md` must use the `` `constant` (value) `` notation** or `DocSyncTests` cannot see it.
- **Every negative assertion needs a control that passed, and every census needs a planted offender.**

### Build

```
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -skip-testing:MaughamTests/MCPServerLifecycleTests
```

The phone scheme is untouched by this slice (spec §9: the canvas is Mac-only) — but run it once at Task 8 and once at the end, because `MaughamCore` is shared and the two schemes are independent.

### Verified signatures this plan builds on

| Symbol | Signature as read | Where |
|---|---|---|
| `CanvasNodeKind` | `case scrap` / `case item(referenceId: String)` | `Maugham/Canvas/CanvasNode.swift:29` |
| `CanvasNodeID.item` | `static func item(_ referenceId: String) -> CanvasNodeID` → `"item:\(referenceId)"` | `CanvasNode.swift:21` |
| node id minting | `CanvasNodeID(UUID().uuidString.prefix(8).lowercased())`, retried against the scene | `CanvasInteraction.swift:453`, `CanvasClaudePlacement.swift:424` |
| `NodeDTO` | `var kind: String  // "scrap" | "item"` and `var referenceId: String?` | `CanvasSceneCodec.swift:36-37` |
| sidecar schema | `CanvasSceneDTO.currentSchemaVersion` == **7** | `CanvasSceneCodec.swift` |
| `CanvasStore` paths | `sidecarRelativePath = ".maugham/canvas.json"`, `scrapsRelativePath = "canvas.md"` | `CanvasStore.swift:10-11` |
| item height | `CanvasCardMetrics.itemPlaceholderHeight` (a derived `static let`) | `CanvasScrapMeasure.swift:98` |
| item heal arm | `rebuildLayouts`' exhaustive `switch node.kind`, `.item` arm sets the constant when `cachedHeight == nil` | `CanvasView.swift:619-651` |
| item drawing | dashed stroke at `CanvasRenderer.swift:1195`; label at `:1277` via `placeholderLabel(forReference:)` | `CanvasRenderer.swift` |
| `chipTitle` | `static func chipTitle(for:in:scraps:) -> String`, item arm at `:738` | `CanvasRenderer.swift:735` |
| `PromotionSource` | `case scrap(CanvasNodeID)` / `region` / `line`; `var noun: String` → `"card"` | `Promotion.swift:5-25` |
| `PromotionTarget` | `researchNote` / `paletteCard` / `intentStatement` / `wikiLink` | `Promotion.swift:30` |
| `ArtifactKind` | `researchNote` / `paletteCard` / `craftIntent` | `Promotion.swift:98` |
| item refusal | `Promotion.targets` returns `[]`; `blockedReason` returns `itemNodeReason` at `Promotion.swift:441` | `Promotion.swift:395-445` |
| inspector routing | `RegionInspectorPane` — region arm, line arm, `case .scrap = node.kind` arm, empty state | `RegionInspector.swift:23-70` |
| ingestion pair | `func addImage(toPaletteCard cardId: String, image: NSImage) async throws -> PaletteCard` and `(…fileURL: URL)` | `ProjectStore+Palette.swift:143`, `:153` |
| the saver | `ImagePasteHandler.saveAndReference(image:forNoteAt:in:) throws -> String` and `saveAndReferenceFile(from:forNoteAt:in:)`, both returning `![](./<slug>_assets/<file>)` | `ImagePasteHandler.swift:12`, `:31` |
| asset destination | private `destination(forNoteAt:in:ext:)` derives `<slug>_assets` from the note's own filename | `ImagePasteHandler.swift:45` |
| research asset | `func createResearchAsset(scope: ResearchScope, fromURL sourceURL: URL) async throws -> ResearchItem` | `ResearchScope.swift:117` |
| inbox promote | `func promoteToResearch(_:projectStore:scope:) async throws -> ResearchItem`, `promoteToPaletteCard(_:projectStore:cardId:)` | `InboxStore.swift:226`, `:270` |
| drop classifier | `DropClassification.action(hasFileURL:canLoadImage:) -> DropAction`, `fileURLs(from: [NSItemProvider]) async -> [URL]` | `Maugham/Views/DropClassification.swift:19` |
| internal drag | `.draggable(item.id)` + `.dropDestination(for: String.self)`; external via `.onDrop(of: [.fileURL, .image])` | `ResearchRow.swift:64`, `:69`, `:79` |
| external write seam | `CanvasClaudeWrite.readScene(store:projectRoot:) -> (scene:scraps:fromOpenCanvas:)` and `apply(_:store:projectRoot:) throws` | `CanvasClaudeWrite.swift:49`, `:81` |
| Plan's panes | `.inbox` is in `Persona.panes` for `.plan` | `Maugham/Models/Persona.swift:88` |
| ⌘\ | posts `.maughamToggleNoChrome` to `.keyWindow`; received by `FocusPostureModifier` | `MaughamApp.swift:189`, `ProjectWindow.swift:1545` |
| columns | three-column `NavigationSplitView` with **no** `columnVisibility` binding; `@State private var showInspector` | `ProjectWindow.swift:45`, `:93` |
| stash hazard | `PersonaModifier.clearsPaletteStash(from:to:)` | `ProjectWindow.swift:1641` |

---

## File map

**Create**

| File | Responsibility |
|---|---|
| `Maugham/Canvas/CanvasItemReference.swift` | The two provenances, and the one place a node's reference is destructured into "a project item" vs "a file we own". |
| `Maugham/Canvas/CanvasThumbnails.swift` | `CGImageSource` downsampling and the bounded path-keyed cache. Knows nothing about nodes. |
| `Maugham/Canvas/CanvasItemFacts.swift` | What an item node shows — title, glyph, thumbnail path — resolved from the manifest or the path. Pure; takes what it needs, reaches for nothing. |
| `Maugham/Canvas/ItemInspector.swift` | The fourth inspector arm. |
| `Maugham/Stores/ProjectStore+CanvasAssets.swift` | The ingestion pair's canvas twin. One file so the "one place decides where an image lands" rule is visible as a file, not as a convention. |

**Modify (named per task; line numbers in the table above)**

`CanvasNode.swift`, `CanvasSceneCodec.swift`, `CanvasView.swift`, `CanvasRenderer.swift`, `CanvasAccessibility.swift`, `CanvasClaudePlacement.swift`, `Promotion.swift`, `PromotionPerformer.swift`, `RegionInspector.swift`, `Maugham/Views/ProjectWindow.swift`, `Maugham/Views/InboxPane.swift`, `Maugham/Canvas/AREA.md`, `docs/adr/0026-planning-canvas-rendering.md`, `docs/roadmap.md`, `docs/guide/`.

---

## Task 1: The two provenances, and the sidecar at schema 8

**Files:** Create `Maugham/Canvas/CanvasItemReference.swift`. Modify `CanvasNode.swift:29-40`, `CanvasSceneCodec.swift:36-37,112,152`, and every site that destructures an item reference — `CanvasAccessibility.swift:359`, `CanvasRenderer.swift:738,1277`, `CanvasClaudePlacement.swift`. Test: `MaughamTests/Canvas/CanvasSceneCodecTests.swift`, `CanvasLineCodecTests.swift`.

**Interfaces — produces:**

```
enum CanvasItemReference: Equatable, Hashable, Sendable {
    case project(id: String)     // a research item / palette card id — the canvas never writes to it
    case owned(path: String)     // PROJECT-RELATIVE, e.g. "canvas_assets/photo-20260730-121314.png"
}
case item(CanvasItemReference)   // replaces `case item(referenceId: String)`
```

**Why nested rather than a third `CanvasNodeKind` case.** Roughly fifteen sites test `case .scrap = node.kind` and want both provenances to behave identically (the resize refusal, the promoted-stripe refusal, the tint refusal, the placeholder heal). Four destructure the reference. A third top-level case leaves every `.scrap` guard right and silently changes the meaning of `Promotion.swift:441`'s `if case .item = node.kind { return itemNodeReason }` — an owned node would fall through to the empty-text check and be offered a research note, a palette card and a **craft intent**. Nested makes that line keep refusing until Task 7 changes it deliberately, and makes the sites that genuinely differ exhaustive at the compiler.

**Requirements**

- `CanvasNodeID.item(_:)` is unchanged and stays the **project** spelling — its whole job is that two adds of one research item resolve to one node (`CanvasNode.swift:15-20`). An **owned** node's id is **minted**, not derived: there is nothing to deduplicate, each ingestion is its own file, and a filesystem path does not belong in an identity. Use the existing spelling (`UUID().uuidString.prefix(8).lowercased()`, retried against the scene) rather than a sixth one.
- Sidecar goes to **schema 8**, additive-optional in both directions, exactly as 4/5/6/7 were: a new optional `NodeDTO` field for the owned path beside the existing `referenceId`, so every schema-7 file decodes unchanged.
- **A DTO carrying both fields must not drop the node.** State one rule in the codec's doc comment and pin it. Losing a card to a hand-edited file is the failure the loader's home-conflict rule already refuses (it demotes rather than drops).
- The "from the future" fixture goes to **9**. It is `CanvasLineCodecTests.test_aSchemaEightSidecarLosesTheArrangementAndKeepsTheWords:106` — the *name* carries the number, so rename it too. It has needed rebumping at every bump so far or it stops exercising the refuse-a-newer-schema path.
- **Three tests pin the number and all three go red on the bump** — `CanvasPromotionCodecTests.swift:36`, `CanvasLineCodecTests.swift:27`, `PromotionContributionTests.swift:194`, each an `XCTAssertEqual(CanvasSceneDTO.currentSchemaVersion, 7)`. Verified 2026-07-30. This is the "a new MCP tool breaks at least three tools-list tests" lesson wearing the codec's clothes: expect the red, and read each one rather than sed-ing the number, because a pinned version assertion is sometimes load-bearing for the fixture beside it.
- **Nothing in this task tints, draws or promotes an owned node differently.** It is the encoding only.

**The failure it must not have:** a schema-7 sidecar that decodes to a scene with fewer nodes than it has, or a schema-8 file an older build opens by silently reading an owned node as a project reference and rendering `Item · canvas_assets/photo-….png`.

**Tests that must exist**

- A schema-7 fixture round-trips to the same scene it does today (**control** — this is the assertion that proves the rest are not vacuous).
- A schema-8 fixture carrying an owned node decodes to `.owned(path:)` with the path intact, and re-encodes byte-identically.
- A schema-**9** fixture loses the arrangement and keeps the words (the renamed test).
- A DTO with both fields set decodes to *a node*, per whichever rule the doc comment states.
- **Disable experiment:** make the encoder drop the owned path and the round-trip test goes red while the schema-7 control stays green.

- [ ] **Step 1:** Write the codec tests above; run them; confirm they fail for the stated reason (not for a compile error in the test itself).
- [ ] **Step 2:** Add `CanvasItemReference`; change `CanvasNodeKind.item`; fix every destructure site the compiler names. Do not add behaviour at any of them.
- [ ] **Step 3:** Bump the DTO and `currentSchemaVersion` to 8; rename and rebump the future fixture to 9.
- [ ] **Step 4:** Full Mac suite. Run the three census files named in the global constraints.
- [ ] **Step 5:** Commit — `feat(canvas): an item node has two provenances, and the sidecar is at 8`.

---

## Task 2: The canvas owns its assets

**Files:** Create `Maugham/Stores/ProjectStore+CanvasAssets.swift`. Test: `MaughamTests/Stores/`.

**Interfaces — consumes:** `ImagePasteHandler.saveAndReference(image:forNoteAt:in:)` and `saveAndReferenceFile(from:forNoteAt:in:)` (`ImagePasteHandler.swift:12`, `:31`); `CanvasStore.scrapsRelativePath` (`CanvasStore.swift:11`).

**Interfaces — produces:** one pair, mirroring `ProjectStore+Palette.swift:143`/`:153` in shape and in `async throws`-ness, each returning the **project-relative path** of the stored asset — the string that goes into `CanvasItemReference.owned(path:)`.

**Requirements**

- **`canvas_assets/` at the project root, beside `canvas.md`** (spec §8's 2026-07-30 line). It is **content, not derived**: deleting `.maugham/canvas.json` costs the arrangement and must never cost the photographs. Do not put it under `.maugham/`.
- **Reuse the saver; do not write a second one.** `ImagePasteHandler.destination(forNoteAt:in:ext:)` derives `<slug>_assets` from the note's own filename, so passing `CanvasStore.scrapsRelativePath` yields `canvas_assets/` with no new naming, no new dedupe and no new timestamp format. If that does not hold when you read it, say so rather than forking the saver.
- **The pair returns a path, not a Markdown ref.** The saver returns `![](./canvas_assets/…)`. Resolving that to a project-relative path is a thing `ProjectStore+Palette` already does for the card model — share that resolution or state in a comment why it could not be shared. A second spelling of ref→path is the drift.
- **This pair is the only writer of `canvas_assets/`.** Every route in tasks 9–11 is a caller. Consider whether a grep tripwire is worth it here; the palette's own `test_noRawWriteInPaletteStore` is the precedent and this seam has the same "five callers, one decision" shape.

**The failure it must not have:** an absolute path, a `file://` URL or a Markdown ref reaching `CanvasItemReference.owned(path:)`. Any of the three renders nothing, keys the thumbnail cache on a string that differs between Macs, and breaks the moment the project is moved or synced.

**Tests that must exist**

- Ingesting an `NSImage` puts a file under `canvas_assets/` and returns a path that is relative, has no leading `./`, and resolves against the project URL to the file that was written.
- The file-URL twin preserves the source extension.
- Two ingestions of the same source file produce two distinct paths (dedupe is the saver's, and this is the assertion that says we did not defeat it).
- **Control:** a project with no ingestion has no `canvas_assets/` directory — the pair creates it, nothing else does.

- [ ] **Step 1:** Write the tests; run; confirm they fail.
- [ ] **Step 2:** Implement the pair over the shared saver.
- [ ] **Step 3:** Run; full Stores suite.
- [ ] **Step 4:** Commit — `feat(canvas): the canvas owns the images it ingests`.

---

## Task 3: Thumbnails — downsample at decode, cache by path

**Files:** Create `Maugham/Canvas/CanvasThumbnails.swift`. Test: `MaughamTests/Canvas/CanvasThumbnailTests.swift`.

**Interfaces — produces:** a thumbnail lookup taking a **project-relative path plus the project URL** and a target pixel size, returning an image or nil. Knows nothing about `CanvasNode`, `CanvasScene` or SwiftUI.

**Requirements**

- **Decode AT thumbnail size through `CGImageSource`** — `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways` and `kCGImageSourceThumbnailMaxPixelSize`. **Not** full-size decode then redraw. The palette wall's helper does exactly that and is the thing this must not copy; the canvas is the first surface in Maugham with an unbounded image count (spec §8A.1).
- **The cache is bounded and keyed by PATH** (tripwire 22). An id key is wrong twice over: an owned node has no item id, and a referenced image's id is stable across a file change while the pixels are not.
- **Nothing here runs on the frame path.** The draw pass may *read* a resolved thumbnail; it must not trigger a decode. State how a miss is handled (draw the card without one and resolve off the frame path) and pin it.
- Bound and eviction policy is yours; the number goes in `CanvasMaterial` only if it is a *look* constant, which this is not — it is a memory bound, so it belongs beside the cache with a comment saying why it is not in `CanvasMaterial`.

**The failure it must not have:** a 6000×4000 photograph decoding at full size on the canvas's draw pass, once per frame, per card.

**Tests that must exist**

- A large fixture image resolves to a thumbnail whose pixel dimensions are ≤ the requested maximum **and** whose aspect ratio matches the source.
- The same path twice is one decode (assert on a decode counter, not on wall-clock time).
- The cache evicts at its bound, and the **control** is that a second request for a still-resident path does not re-decode — without it, an always-evicting cache passes the eviction assertion.
- A missing file returns nil rather than throwing or trapping.
- **Disable experiment:** remove `kCGImageSourceThumbnailMaxPixelSize` and the dimensions assertion goes red while the aspect-ratio and cache assertions stay green.

- [ ] **Step 1:** Write the tests, including a committed fixture image large enough that full-size decode is distinguishable. Run; confirm failure.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** Run; full Canvas suite.
- [ ] **Step 4:** Commit — `feat(canvas): thumbnails decode small and cache by path`.

---

## Task 4: What an item node says it is

**Files:** Create `Maugham/Canvas/CanvasItemFacts.swift`. Test: `MaughamTests/Canvas/CanvasItemFactsTests.swift`.

**Interfaces — consumes:** `CanvasItemReference` (Task 1).

**Interfaces — produces:** a pure resolver from a `CanvasItemReference` (plus whatever manifest lookup it is *handed*) to the three facts the renderer and the inspector both need: a **title**, a **kind glyph** (SF Symbol name), and an optional **thumbnail path**.

**Requirements**

- **Pure, and handed its lookups rather than reaching for them.** This is `Promotion`/`ArtifactIndex`'s own shape and the reason it is testable: `ArtifactIndex` is built once when the sheet opens and passed in (`Maugham/Canvas/AREA.md`, Promotion). A `ProjectStore` read from a `body`, or from anything a `body` calls, is the failure `CanvasAuthorLine` documents.
- **A referenced item resolves title and kind from the manifest.** A **deleted** one does not resolve — and must produce a sentence rather than a raw id, exactly as `PromotedArtifactSection.contributionArtifactMissing` does, because an id is not something the writer can read.
- **An owned item has no manifest entry and never will.** Its title comes from the file; decide what it is (the filename, or a fixed noun) and state why in the doc comment.
- **Resolution is cached against a manifest-change key and never recomputed in `body`** (tripwire 4 — per-row Fountain re-parses became O(N²) on binder click in 3d). `sceneRevision` is the wrong key on its own: the manifest can change without the scene changing (the writer renames the research note a card points at).

**The failure it must not have:** the title resolving per frame, or an item node whose research note has been deleted drawing `Item · res-3f2a`.

**Tests that must exist**

- A referenced item resolves to the manifest's title and a kind glyph that differs between a note, a palette card and an image.
- A referenced item that is **not** in the manifest resolves to the missing-artifact sentence and no id appears in the string (assert the id is absent — that is the assertion, not that the sentence is non-empty).
- An owned item resolves without any manifest at all.
- **Control:** the resolver called twice with the same inputs returns equal facts (so the caching test in Task 5 is measuring caching and not nondeterminism).

- [ ] **Step 1:** Tests. Run; confirm failure.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** Run; full Canvas suite.
- [ ] **Step 4:** Commit — `feat(canvas): an item node resolves what it is`.

---

## Task 5: The item node draws itself, and is measured

**Files:** Modify `CanvasRenderer.swift:1192-1200,1270-1290,735-745`, `CanvasView.swift:619-651`, `CanvasScrapMeasure.swift:98`. Test: `MaughamTests/Canvas/CanvasRendererTests.swift`, `CanvasViewMountingTests.swift`.

**Interfaces — consumes:** `CanvasItemFacts` (Task 4), `CanvasThumbnails` (Task 3).

**Requirements**

- **The dashed placeholder goes.** `CanvasRenderer.swift:1195`'s dashed stroke and `:1277`'s `placeholderLabel(forReference:)` are the finished behaviour *for 1C-c3's slice*, and this is the slice that replaces them: title, kind glyph, thumbnail when there is one.
- **This is what closes §8A.2's reproduction corollary**, and that is a constitutional obligation rather than a nicety — ADR 0026 §10 says "structural here, visible at 1C-d" in those words. The photographed page and the scraps read off it must be **comparable by looking**. Do not write down that the corollary is satisfied until a raster fixture says the page shows its own image.
- **`rebuildLayouts`' `.item` arm genuinely measures now** — an item's height depends on whether it has a thumbnail, so `CanvasCardMetrics.itemPlaceholderHeight` stops being the answer. **The heal stays as the floor**: a node whose facts have not resolved yet must still get *a* height, because a node with no `cachedHeight` has no `frame`, and `nodes(intersecting:)` and `topmostNode(at:)` both drop it — not drawn, not clickable, and persisted that way. That is the 1C-c3 whole-branch Critical and it is one line from returning.
- **Resize stays `.scrap`-only. Do not re-open it.** `CanvasInteraction.begin` takes the corner for `.scrap` only and `drawCard` inks the triangle for `.scrap` only, and those two are **one decision** (the mark and its target). Nothing in §8A requires an item's width to mean anything, so widening this is a design act with no requirement behind it, and the failure it re-opens is a card deleted permanently by one drag. If a later task finds it genuinely needs item resize, it takes the mark and the target together and restores the measurement pass first.
- **`CanvasRenderer.connectHandleRect` still subtracts `resizeHandleSize` on every card**, so a selected item node's connect dot sits as though a triangle it does not draw were below it. Judged cosmetic in 1C-c3 because the mark and its target still agree with each other. **This is the slice that makes it visible** if an item node gains chrome. Look at it; fix it or record that you looked and it still reads right.
- The tint refusal is unchanged: `CanvasRenderer.paper(for:)` refuses to tint an item node whatever its author says, and `seededRotation` reads the author. Neither moves here.

**The failure it must not have:** an item node with no height (invisible and unclickable, saved that way), or drawn text that jumps between the draw pass and anything else.

**Tests that must exist**

- A raster fixture: a scene whose only difference is an item node **with** vs **without** a resolved thumbnail differs in pixels inside the card's rect (the house pattern — `CanvasRegionRenderTests` renders through `ImageRenderer` and counts changed pixels).
- An item node arriving with `cachedHeight: nil` is healed on load and is present in `nodes(intersecting:)` afterwards (this test exists — `test_anItemNodeThatArrivesWithNoHeightIsHealedOnLoad`; extend it, do not replace it).
- A corner drag on an item node **moves** it and does not resize it, driven **mid-drag through the real event view** — a re-measure at `.ended` hides the whole gesture. `CanvasViewMountingTests.test_aCornerDragOnClaudesSourcePageDoesNotTakeItOffTheCanvas` is that test; it must still pass unchanged.
- Raster fixtures resolve dynamic colours under an explicit appearance — the test process runs under DarkAqua, and a white-bitmap ink test once measured zero ink and passed everywhere except a dark-mode Mac.

- [ ] **Step 1:** Tests. Run; confirm failure.
- [ ] **Step 2:** Implement drawing.
- [ ] **Step 3:** Implement measurement; keep the heal as the floor.
- [ ] **Step 4:** Run; full Canvas suite; check `test_aCornerDragOnClaudesSourcePageDoesNotTakeItOffTheCanvas` and the whole `CanvasViewMountingTests` file green.
- [ ] **Step 5:** Commit — `feat(canvas): an item node shows what it is`.

---

## Task 6: The item node's inspector arm

**Files:** Create `Maugham/Canvas/ItemInspector.swift`. Modify `RegionInspector.swift:23-70` (the routing), `Maugham/Views/ProjectWindow.swift` (whatever the arm needs handed to it). Test: `MaughamTests/Canvas/RegionBindingTests.swift` or a peer.

**Interfaces — consumes:** `CanvasItemFacts` (Task 4).

**Requirements**

- **A selected item node currently shows *"Select something on the canvas"*.** That is ADR 0026 §10's recorded decision-not-bug, and it is this task's whole subject. The arm wanted is small: the reference's **title**, an **Open in Research** button, and the provenance row.
- **`onOpenResearchItem` already exists on the pane** (`RegionInspector.swift:36`) and is reached only from the two arms that do not render for an item node. This arm is its third caller — and there is no default on it, deliberately, so the compiler will ask.
- **The author line goes through the one implementation both existing arms are handed** — `CanvasAuthorLine.forCard` / `.forRegion` and `CanvasAuthorLineRow`. Do **not** spell the sentence in this arm. `RegionBindingTests.test_bothInspectorArmsRenderTheOneAuthorLine` is the census that forbids it, and it will need to become three arms. **Count the array.**
- **Open in Research is meaningless for an OWNED node** — there is no research item to open. Decide what it offers instead (Reveal in Finder, or nothing) and make the decision a value, not an `if` inside `body`: `_ConditionalContent` is branch-invariant and a `Form`'s contents are not inspectable, which is why every decision in this directory is a value.
- **Which arm the pane renders cannot be asserted directly.** Pin it as the neighbouring arms are pinned: a caller census plus each resolver's behaviour. Arm order cannot be wrong — `selection` is one enum.

**The failure it must not have:** the card arm's sentences rendering for an item node. Every one of them is wrong for a reference ("The words live on the card", "Promoting takes a copy"), which is exactly why the `.scrap` guard at `RegionInspector.swift:45` is right and must stay right.

**Tests that must exist**

- The arm's resolver returns the title for a referenced node and the owned equivalent for an owned one.
- The author line census now names three arms and fails both when it empties and when it grows.
- A **planted-offender** companion: an arm spelling the author sentence itself fails the census.
- **Control:** a selected *scrap* still renders the card arm, and a selection of nothing still renders the empty state.

- [ ] **Step 1:** Tests. Run; confirm failure.
- [ ] **Step 2:** Build the arm; route to it.
- [ ] **Step 3:** Run; full Canvas suite **and** the three census files.
- [ ] **Step 4:** `grep -rn ItemInspector Maugham/` — confirm a production caller exists. This is the check that found all four of this area's unreachable halves.
- [ ] **Step 5:** Commit — `feat(canvas): an item node has something to say for itself`.

---

## Task 7: An owned item node promotes

**Files:** Modify `Promotion.swift:395-445` (targets, `blockedReason`, `itemNodeReason`), `PromotionPerformer.swift`, `PromotionSheet.swift`, `ItemInspector.swift` (Task 6). Test: `MaughamTests/Canvas/PromotionTests.swift` and peers.

**Interfaces — consumes:** `CanvasItemReference` (Task 1); `ProjectStore.createResearchAsset(scope:fromURL:)` (`ResearchScope.swift:117`); `ProjectStore.addImage(toPaletteCard:fileURL:)` (`ProjectStore+Palette.swift:153`).

**The ruling this implements** is spec §6's 2026-07-30 amendment. Quote it; do not re-derive it.

**Requirements**

- **`Promotion.targets` answers for an OWNED node and still returns `[]` for a REFERENCED one.** The destinations are the inbox's own two — a research asset, or an image on a palette card — because it is the same object one hop later. **No `.intentStatement`**: an intent is prose about how a piece is written and a photograph is not a sentence.
- **`Promotion.itemNodeReason` stays alive and becomes the *referenced* node's sentence**, not every item node's. `Promotion.swift:441`'s `if case .item = node.kind` is the line that changes, and it must not become a line that lets an owned node fall through to the empty-text check.
- **It is a SNAPSHOT and the asset is COPIED** (§6.1 ruling 1, restated in the amendment). Promoting does not hand the file to research and turn the node into a reference. The mark records which artifact it produced, exactly as a scrap's does.
- **Validate first, write second** — a refused promotion leaves nothing behind. `PromotionPerformer` is `@MainActor async throws` with **no `inout` on the path**, because an `inout CanvasScene` cannot cross an `await`; scene changes happen through `CanvasModel`, synchronously, after the awaits.
- **The mark is written through `mutateFromInspector`, never `mutate`** — tripwire 32, and `PromotionPerformer.swift` is already the census's third entry.
- **`PromotionTarget` may need a new case, and `PromotionTarget.producedArtifactKind` is what stops one promotion destroying another's artifact.** If you add a case, it answers that property truthfully or you have re-opened the 1C-c2 Critical: with titles alone, every mark resolved for every updatable target and a re-promote wrote raw scrap text over a palette card's backing file.
- **`PromotionSource.noun` returns `"card"` for `.scrap`**, and an owned photograph is not a card. Check every refusal sentence an owned node can reach and make the noun true, or say why "card" is still the writer's word for it.

**The failure it must not have:** promoting an owned photograph twice offering to *rewrite* the palette card it went into, and replacing that card's other images. That is the 1C-c2 Critical's exact shape.

**Tests that must exist**

- An owned node offers exactly the two targets; a referenced node offers none and says `itemNodeReason`.
- Promoting to a research asset produces a research item whose file is a **copy** — the `canvas_assets/` original still exists and the node is still `.owned` afterwards.
- Promoting to a palette card appends to that card's image well and **does not** disturb its existing images, swatches or sensory notes.
- A kind mismatch **declines the update** rather than refusing the promotion (the existing rule — a duplicate note is a cost the writer can undo, their palette is not).
- One promotion is **one ⌘Z** — assert on the undo step's *name* (`CanvasUndo.undoMenuItemTitle`, the AppKit-computed title), not on the scene. A test whose only observable is the post-⌘Z scene cannot tell "its own step" from "folded into the neighbouring step", and that has been demonstrated twice in one slice.
- **Disable experiment:** open a second bracket in the performer and the one-⌘Z test goes red with a second step left on the stack.

- [ ] **Step 1:** Tests. Run; confirm failure.
- [ ] **Step 2:** Targets and refusal.
- [ ] **Step 3:** The performer's two destinations.
- [ ] **Step 4:** Wire the sheet and the `Promote…` button in the item arm — the button posts the **same** `.maughamPromoteCanvasSelection` command the menu and ⌘⇧↩ post, so button and keystroke cannot drift. A post from inside a sheet is dropped; these live in the project window.
- [ ] **Step 5:** Run; full Canvas suite; `PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite` — **count that array**.
- [ ] **Step 6:** Commit — `feat(canvas): the photograph on the canvas can become research`.

---

## Task 8: Re-derive tasks 9–13 against the built code

**Files:** Modify this plan.

This is a **plan task**, not a code task, and it is the sequencing device that replaces splitting the milestone. Tasks 9–13 are stated below as requirements and failures; their contracts cannot be written until tasks 1–7 exist, because they call into them.

- [ ] **Step 1:** Read what tasks 1–7 actually built — `CanvasItemReference`, the ingestion pair's real signature, `CanvasItemFacts`' real shape, `ItemInspector`'s parameters, and whether `CanvasClaudeWrite`'s seam took the shape Task 11 needs.
- [ ] **Step 2:** Re-read `Maugham/Canvas/AREA.md`. Tasks 1–7 will have changed it; the statements below were written against the 2026-07-30 version.
- [ ] **Step 3:** Write tasks 9–13 in full, in the shape tasks 1–7 use: files, interfaces with **verified** signatures, requirements, the failure each must not have, the tests, the disable experiment. Contracts, not bodies.
- [ ] **Step 4:** Run the Mac suite **and the phone suite** once here — `MaughamCore` is shared and the two schemes are independent.
- [ ] **Step 5:** Commit — `docs(plan): 1C-d's second half, derived against the built code`.

---

## Tasks 9–13 — stated, to be written at Task 8

Each names its spec authority, the requirement, and the failure it must not have. **Do not implement from these; Task 8 turns them into tasks.**

### Task 9 — The drop target, and the research drag (spec §8A.1)

Dropping a research item on the canvas creates a **referenced** item node at the drop point; the file is untouched. Internal drags follow the app's established `.draggable(id)` / `.dropDestination(for: String.self)` pattern (`ResearchRow.swift:64`, `:69`).

*Failure it must not have:* a drop that lands a node with no measured height, or one that changes any region's membership by a rule other than "the node's centre is inside it" (tripwire 31 — a drop is a legitimate geometric reading; nothing else in this task is).

### Task 10 — External drops (spec §8A.1)

A photo from Finder or a browser lands as an **owned** item node through the Task 2 pair. **Never `.dropDestination(for: URL.self)`** — browser image drags carry rendered bitmaps rather than file URLs and that modifier silently rejects them (CoreTransferable error 0). `[.fileURL, .image]` providers plus `DropClassification.fileURLs(from:)` is the only route, and the canvas adds no classification logic of its own — it is the fifth adopter.

*Failure it must not have:* a browser drag that appears to do nothing, with nothing logged and nothing red.

### Task 11 — Inbox → canvas (spec §8A.4, and its 2026-07-30 amendment)

**Two routes.** An inbox row is **draggable onto the canvas and lands where it is dropped** — the third caller of Task 9's drop target, with no placement rule of its own. A **Send to Canvas** command stays beside "Promote to Palette" on the row (`InboxPane.swift:194-207`) for the keyboard, VoiceOver and a closed pane, and takes the one fallback: loose, clear of the writer's existing work (`CanvasClaudePlacement`'s `occupied.maxX + gutter`), **never in a region**.

**All three capture kinds or it does not ship.** Text and voice become a **scrap** — words into `canvas.md` keyed by the new node's id. A photograph becomes an **owned** item node.

It **reuses the promote contract rather than restating it**: copy-then-remove so a failure leaves a harmless duplicate rather than losing the capture, and flip the entry to `.promoted` **only after every mutating step has succeeded**. A third sibling beside `promoteToResearch`/`promoteToPaletteCard`, not a new spelling of them.

**The write goes through the attached/detached seam, which is `CanvasClaudeWrite`'s** (`CanvasClaudeWrite.swift:49`, `:81`) — `isAttached`, never `liveCanvas != nil`; one `mutateFromInspector` bracket with the words travelling **inside** it via `scrapTexts:`; `bumpSceneRevision()` on its own line; `flush()` rather than `scheduleSave`. Whether that means generalising the file or adding an entry point is Task 8's call — but if the file is renamed or a sixth writer appears, **tripwire 32's census array changes and must be counted, not recited.**

*Failures it must not have:* a capture that leaves the inbox and appears nowhere the writer is looking; a send arriving while the writer is inside a scrap that rides into their next sentence (the census's sharpest repro, and this route needs no gesture of its own either); a half-promoted entry.

### Task 12 — Collapse to the canvas (spec §8A.3)

`⌘\` on the canvas additionally collapses **both** side columns. Reuse the key — focus mode already hides titlebar, traffic lights, persona bar and footer; the exit is the key the writer already knows. **Deliberate toggle, never automatic on entering the persona** (that would fight §8A.1 — you need the binder open to drag research in).

Two recorded hazards. `PersonaModifier.clearsPaletteStash` (`ProjectWindow.swift:1641`) exists because `PaletteSegmentModifier`'s `.onChange` fires in a *later* update pass; any column-collapse that stashes state inherits that ordering hazard and must **extend the predicate rather than defer a pass** (tripwire 2). And column visibility **must not add an expression to `ProjectWindow.body`** — the chain is at the SwiftUI type-checker ceiling and three sibling modifiers exist because inlining broke the Release build. Note the `NavigationSplitView` at `ProjectWindow.swift:93` has **no** `columnVisibility` binding today.

*Failure it must not have:* a stashed column visibility restored over the collapse by a later update pass — tripwire 2's exact shape, which killed cursor↔binder sync in 3d.

### Task 13 — The sweep, and the ledger

Docs move in the same commit as the behaviour (CLAUDE.md rule 10). `Maugham/Canvas/AREA.md` — "What the canvas does not do yet" loses its 1C-d bullet, "Not built" loses the item-node arm and the placeholder page, the two-provenance material joins, and any calibration figure uses the `` `constant` (value) `` notation or `DocSyncTests` cannot see it. ADR 0026 decisions 7 and 10 record what shipped and what the corollary now is. `docs/roadmap.md` flips 1C-d •→✓. `docs/guide/` describes what **ships**. CLAUDE.md's Canvas row and any tripwire whose census changed.

**Then the whole-branch review**, and it gets the **ledger** as a first-class input beside the diff, pointed at the *seams*. It has found a Critical or a cross-surface contradiction in **every one of six slices**, in files no task's diff contained. Every reviewer writes its verdict to a file **before** replying — two reviewers went idle without reporting last slice and the work was lost.

---

## Self-review against the spec

| Spec | Task |
|---|---|
| §3.1 amendment — two provenances, owned by path | 1 |
| §8 — owned captures in an assets folder beside the scraps file | 2 |
| §8A.1 — images, `CGImageSource` thumbnail, path-keyed bounded cache | 3 |
| §8A.1 — real title, kind glyph, thumbnail | 4, 5 |
| §8A.2 corollary — visible at 1C-d | 5 |
| ADR 0026 §10 — item-node inspector arm | 6 |
| §6 amendment — an owned node promotes; a referenced one does not | 7 |
| §8A.1 — drop target, internal research drag | 9 |
| §8A.1 — `DropClassification` for browser drags | 10 |
| §8A.4 + amendment — inbox → canvas, all three kinds, drag and command | 11 |
| §8A.3 — `⌘\` collapses both columns | 12 |
| CLAUDE.md rule 10 — sibling docs in the same commit | 13 |

**Known gaps, stated rather than hidden.**

- **Tasks 9–13 carry no code and no verified signatures yet.** That is Task 8's deliverable and the reason Task 8 exists.
- **This plan runs ~13 tasks, over CLAUDE.md rule 12's ~10 cap.** Recorded rather than fixed by pretending: the milestone is not usable in halves, and Task 8 is the mitigation the cap exists to buy.
- **The overlapping-banner problem is not fixed here.** Three `.overlay(alignment: .top)` transient banners already share the window and two on screen at once draw over each other; the honest fix is one banner host for the window, which is its own slice. If Task 11's command uses a banner, it is a **fourth** and the plan should say so out loud rather than quietly adding it.
- **`CanvasInteraction.regionHit` is still the next projection to lift** onto `CanvasScene`, and until it moves `CanvasScene` cannot go to MaughamCore. Not this slice's, and not made worse by it.
