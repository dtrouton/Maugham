# M1C-d — getting things onto the canvas

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`. Steps use checkbox (`- [ ]`) syntax.

**Goal:** An item node becomes a thing the writer can *see* — real title, kind glyph, thumbnail — and four routes put things on the canvas: a research drag, an external file or browser drop, an inbox capture, and the canvas at full width.

**Architecture:** An item node gains a second provenance. `CanvasNodeKind.item` currently carries a bare `referenceId` and means *this already exists in the project*; it comes to carry a two-case `CanvasItemReference` — `.project(id:)` for that, and `.owned(path:)` for a capture or a drop that has nowhere else to live (spec §3.1's 2026-07-30 amendment). Owned assets are ingested through **one pair** on `ProjectStore` over the saver research notes and palette cards already share, into `canvas_assets/` beside `canvas.md`. Every route — research drag, Finder drop, browser bitmap, inbox — is a **caller** of that pair, never a storage decision of its own. What an item node *shows* is resolved from the manifest (referenced) or from the path (owned), cached against a manifest-change key, and never computed in `body`.

**Tech stack:** Swift **5.10** language mode with Swift 6 concurrency checking as *warnings* (`project.yml:11`, `:120` — verified 2026-07-30; an earlier draft of this line said Swift 6 and was wrong). SwiftUI + AppKit, `CGImageSource` for downsampling. No new dependency. **No new MCP tool** — spec §8A.4 rules the inbox route has no MCP write path, so the catalogue stays at 54 and no tools-list test moves.

---

## How this plan is written, and why it is not the skill's default shape

**It carries contracts, symptoms and verified signatures — not function bodies.** That is a standing ruling (`memory/feedback_plan_code_is_a_liability.md`): full bodies in a plan become the shipped defect, because an implementer edits them into place instead of writing against the file. It is also what held up last time — the 1C-c3 plan carried almost no code on purpose and that survived contact; what failed was its ordering table, wrong in two of five rows. So each task states **the requirement, the failure it must not have, and the test that must exist**, and leaves the ordering to the implementer reading the real file.

**Every signature quoted below was read out of the tree on 2026-07-30**, at the line given. Anything not quoted is deliberately not asserted.

**Tasks 10–14 are stated, not written.** Task 9's whole deliverable is turning them into full tasks against the code tasks 1–8 will have built. This is not a placeholder: writing them now would mean writing contracts against Swift that does not exist, which is the thing that cost M1C four review rounds and three near-deletions of one plan's work by another. It is one plan, one branch, one whole-branch review, one smoke, one merge.

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
- **A new source file needs `./gen.sh` before ANY test count you quote means anything, and the miss is nearly silent.** *(Task 8, 2026-07-31.)* Its first full run reported ~3725 tests "green" and contained **neither new test file**; `-only-testing:MaughamTests/<NewSuite>` against the stale project ran **0 tests and exited 0**. It was caught by grepping the log for a test name, not by an exit code. Run `./gen.sh`, then confirm your new suite's name appears in the log.
- **Every new production primitive gets its callers counted before it is called done.** `grep -rn <symbol> Maugham/` — this area has shipped **four** built-and-unreachable halves and every one was found by a caller count, never by a test.
- **A task that adds a production caller runs the census suites**, not only the suites for the types it edits: `grep -rln "test_.*HasAProductionCaller\|productionFiles()" MaughamTests/` — three files. A census went red and stayed red for four tasks because one brief listed only the latter.
- **A scripted substitution that matches nothing exits 0 and looks like success.** *(Task 13, 2026-07-31.)* `perl -0pi -e 's/\Q…$columnVisibility…\E/…/'` **interpolates `$var` to empty even inside `\Q`**, so the pattern silently matches nothing. Same failure class as the bullet below: use python with an explicit occurrence-count assert.
- **A disable experiment must ASSERT ITS PATCH APPLIED before it draws a conclusion.** *(Task 11, 2026-07-31.)* Its first attempt patched nothing — the replacement string did not match, nothing was modified, the "experiment" ran against unmodified code and reported **green**, which reads exactly like "the test cannot see its subject". It was caught only because a census passing was implausible. A silent no-op patch is the one failure mode that inverts an experiment's meaning, so assert the match, then mutate.
- **Never revert a disable experiment with `git checkout -- <file>`.** *(Hit twice: Tasks 6 and 8.)* Mid-round, HEAD is the **pre-round** commit, so a whole-file checkout silently discards that file's other uncommitted edits along with the experiment. Both times it was caught by re-reading the diff rather than by anything red. Use a targeted edit, or copy the file aside first.
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

The phone scheme is untouched by this slice (spec §9: the canvas is Mac-only) — but run it once at Task 9 and once at the end, because `MaughamCore` is shared and the two schemes are independent.

### Verified signatures this plan builds on

| Symbol | Signature as read | Where |
|---|---|---|
| `CanvasNodeKind` | `case scrap` / `case item(referenceId: String)` | `Maugham/Canvas/CanvasNode.swift:29` |
| `CanvasNodeID.item` | `static func item(_ referenceId: String) -> CanvasNodeID` → `"item:\(referenceId)"` | `CanvasNode.swift:21` |
| node id minting | `CanvasNodeID(UUID().uuidString.prefix(8).lowercased())`, retried against the scene | `CanvasInteraction.swift:453`, `CanvasClaudePlacement.swift:424` |
| `NodeDTO` | `var kind: String  // "scrap" | "item"` and `var referenceId: String?` | `CanvasSceneCodec.swift:36-37` |
| sidecar schema | `CanvasSceneDTO.currentSchemaVersion` == **7** | `CanvasSceneCodec.swift` |
| `CanvasStore` paths | `sidecarRelativePath = ".maugham/canvas.json"`, `scrapsRelativePath = "canvas.md"` | `CanvasStore.swift:10-11` |
| item height | **Renamed by Task 5 to `CanvasCardMetrics.itemLabelOnlyHeight`** — it was `itemPlaceholderHeight` until the placeholder it was named for stopped existing. Same value, and now the FLOOR rather than the answer. | `CanvasScrapMeasure.swift` |
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

**Why nested rather than a third `CanvasNodeKind` case.** Roughly fifteen sites test `case .scrap = node.kind` and want both provenances to behave identically (the resize refusal, the promoted-stripe refusal, the tint refusal, the placeholder heal). Four destructure the reference. A third top-level case leaves every `.scrap` guard right and silently changes the meaning of `Promotion.swift:441`'s `if case .item = node.kind { return itemNodeReason }` — an owned node would fall through to the empty-text check and be offered a research note, a palette card and a **craft intent**. Nested makes that line keep refusing until Task 8 changes it deliberately, and makes the sites that genuinely differ exhaustive at the compiler.

**Requirements**

- `CanvasNodeID.item(_:)` is unchanged and stays the **project** spelling — its whole job is that two adds of one research item resolve to one node (`CanvasNode.swift:15-20`). An **owned** node's id is **minted**, not derived: there is nothing to deduplicate, each ingestion is its own file, and a filesystem path does not belong in an identity. Use the existing spelling (`UUID().uuidString.prefix(8).lowercased()`, retried against the scene) rather than a sixth one.
- Sidecar goes to **schema 8**, additive-optional in both directions, exactly as 4/5/6/7 were: a new optional `NodeDTO` field for the owned path beside the existing `referenceId`, so every schema-7 file decodes unchanged.
- **A DTO carrying both fields must not drop the node.** State one rule in the codec's doc comment and pin it. Losing a card to a hand-edited file is the failure the loader's home-conflict rule already refuses (it demotes rather than drops).
- The "from the future" fixture goes to **9**. It is `CanvasLineCodecTests.test_aSchemaEightSidecarLosesTheArrangementAndKeepsTheWords:106` — the *name* carries the number, so rename it too. It has needed rebumping at every bump so far or it stops exercising the refuse-a-newer-schema path.
- **FOUR tests pin the number and all four go red on the bump** — `CanvasPromotionCodecTests.swift:36`, `CanvasLineCodecTests.swift:27`, `PromotionContributionTests.swift:194` and `PromotionPieceTests.test_theSchemaIsFiveBecauseThisTaskAddedAField:148`. *This plan said three; Task 1's implementer found the fourth, whose name carries a stale number and so does not grep like the others.* Corrected 2026-07-30 — and the lesson is the count, not the list: **grep for the assertion, do not trust this bullet.** This is the "a new MCP tool breaks at least three tools-list tests" lesson wearing the codec's clothes: expect the red, and read each one rather than sed-ing the number, because a pinned version assertion is sometimes load-bearing for the fixture beside it.
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
- **This pair is the only writer of `canvas_assets/`.** Every route in tasks 10–12 is a caller. Consider whether a grep tripwire is worth it here; the palette's own `test_noRawWriteInPaletteStore` is the precedent and this seam has the same "five callers, one decision" shape.

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
- **A card's size VARIES — Task 6 makes item nodes resizable — so a naive "decode at the card's current size" is a decode per drag frame.** The two shapes that work are a bucketed target size (key the cache on path *and* bucket) or one generous decode that the draw pass scales down, which costs nothing on an already-small bitmap. Either is fine; a per-frame decode is not, and it is the failure this bullet exists to name.
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
- **Do not touch resize here. It is Task 6, and it depends on this task's measurement being real.** `CanvasInteraction.begin` takes the corner for `.scrap` only and `drawCard` inks the triangle for `.scrap` only; leave both exactly as they are until the height this task derives is genuinely a function of the width.
- **`CanvasRenderer.connectHandleRect` still subtracts `resizeHandleSize` on every card**, so a selected item node's connect dot sits as though a triangle it does not draw were below it. Judged cosmetic in 1C-c3 because the mark and its target still agree with each other. **This is the slice that makes it visible** if an item node gains chrome. Look at it; fix it or record that you looked and it still reads right.
- The tint refusal is unchanged: `CanvasRenderer.paper(for:)` refuses to tint an item node whatever its author says, and `seededRotation` reads the author. Neither moves here.

**The failure it must not have:** an item node with no height (invisible and unclickable, saved that way), or drawn text that jumps between the draw pass and anything else.

**Tests that must exist**

- A raster fixture: a scene whose only difference is an item node **with** vs **without** a resolved thumbnail differs in pixels inside the card's rect (the house pattern — `CanvasRegionRenderTests` renders through `ImageRenderer` and counts changed pixels).
- An item node arriving with `cachedHeight: nil` is healed on load and is present in `nodes(intersecting:)` afterwards (this test exists — `test_anItemNodeThatArrivesWithNoHeightIsHealedOnLoad`; extend it, do not replace it).
- A corner drag on an item node **moves** it and does not resize it, driven **mid-drag through the real event view** — a re-measure at `.ended` hides the whole gesture. `CanvasViewMountingTests.test_aCornerDragOnClaudesSourcePageDoesNotTakeItOffTheCanvas` and `CanvasInteractionTests.test_theCornerOfAnItemNodeMovesItRatherThanResizingIt` are those tests, and they must still pass **unchanged in this task**. Task 6 inverts both deliberately, and re-points rather than deletes the safety property they carry.
- Raster fixtures resolve dynamic colours under an explicit appearance — the test process runs under DarkAqua, and a white-bitmap ink test once measured zero ink and passed everywhere except a dark-mode Mac.

- [ ] **Step 1:** Tests. Run; confirm failure.
- [ ] **Step 2:** Implement drawing.
- [ ] **Step 3:** Implement measurement; keep the heal as the floor.
- [ ] **Step 4:** Run; full Canvas suite; check `test_aCornerDragOnClaudesSourcePageDoesNotTakeItOffTheCanvas` and the whole `CanvasViewMountingTests` file green.
- [ ] **Step 5:** Commit — `feat(canvas): an item node shows what it is`.

---

## Task 6: An item node resizes

**Files:** Modify `CanvasInteraction.swift:286-300`, `CanvasRenderer.swift:1192-1200` (the mark), `CanvasScene.setWidth`. Test: `MaughamTests/Canvas/CanvasInteractionTests.swift`, `CanvasViewMountingTests.swift`, `CanvasRendererTests.swift`.

**Interfaces — consumes:** Task 5's item measurement pass. **This task is not safe before it exists.**

**Why this re-opens a ruling, and what makes it safe now.** Resize is `.scrap`-only because of a 1C-c3 whole-branch Critical: `CanvasScene.setWidth` clears `cachedHeight` by design, **nothing re-measured an item node**, and a node with no `cachedHeight` has no `frame` — dropped by both `nodes(intersecting:)` and `topmostNode(at:)`, so neither drawn nor clickable, and persisted that way through a save. One corner drag took the photographed page off the canvas permanently. **The guard was a fix for the missing measurement pass, not a ruling that item nodes should not resize**, and Task 5 is what supplies the pass. Once height is derived from width, `setWidth` clearing it is harmless: the re-measure restores it, exactly as it does for a scrap.

**It is also the rule the canvas already has, not a new one.** Spec §7A.3: width is authoritative and the height is derived. A scrap's text reflows; an image's height follows its aspect ratio. Same sentence, second content type. And a photographed page that cannot be enlarged is a weak answer to §8A.2's corollary, which asks that a reproduction and its source be **checkable side by side** — at placeholder size they are not.

**Requirements**

- **There are THREE `.scrap` guards, not two, and this plan said two.** *(Corrected 2026-07-31 by Task 6's implementer.)* The mark (`drawCard`'s triangle) and the target (`CanvasInteraction.begin`'s corner) are the two anyone lists — **and `CanvasView.remeasure` is the third**, the per-frame re-derive. Widen the first two and leave it, and **the gesture is the original Critical for its whole length** — the node has no height for every frame of the drag — while every post-mouse-up assertion stays green, because `.ended` re-measures and hides it. That is why the mid-drag requirement below is not a stylistic preference. One constant (`CanvasRenderer.resizeHandleSize`) fixes the size of mark and target both; `drawCard`'s adjacency comment calls moving a mark across the conditional line a **design change, not a tidy-up**.
- **Prefer removing the `.scrap` condition to adding an `.item` one.** Before 1C-c3 the triangle was drawn unconditionally; if every node kind now measures, the honest end state is the uniform rule restored, and `drawCard` goes back to two unconditional marks rather than three conditions. Check that against the file — if a non-image item node (a research note reference) has no sensible resize, say so and take the narrower change with the reason written down.
- **An image keeps its aspect ratio.** Width authoritative, height derived from the image plus the label chrome — so a corner drag scales rather than distorts. A distorting resize would be the one place on this surface where the drawn thing stops being a faithful reproduction, which is the corollary's own subject.
- **The floor stays.** Task 5's heal-to-constant — now spelled **`CanvasCardMetrics.itemLabelOnlyHeight`**, renamed from `itemPlaceholderHeight` in that task — is what covers a node whose facts or thumbnail have not arrived yet; a resize while unresolved must land on the floor height, never on nil.
- **`CanvasRenderer.connectHandleRect` subtracts `resizeHandleSize` on every card** and was cosmetically wrong for an item node precisely because the triangle was not drawn. **Task 5 looked at it, left it, and measured why**: the clamp only bites below a card height of 42 pt, every pictured item card is ~205 pt, and on a label-only card the dot sits 4 pt above centre inside a 14 pt target — so fixing it there would have been a change this task undoes. **Restoring the triangle is what makes the subtraction correct.** Verify that rather than assuming it, and delete the note in Task 14 if it is now true.

**The failure it must not have:** an item node persisted with no height. It is invisible, unclickable and unrecoverable without hand-editing the sidecar, and it reached disk once already.

**Tests that must exist**

- **The two tests this task inverts are re-pointed, not deleted.** `test_aCornerDragOnClaudesSourcePageDoesNotTakeItOffTheCanvas` and `test_theCornerOfAnItemNodeMovesItRatherThanResizingIt` assert the old behaviour. Their replacements must assert the **safety property underneath it**: after a corner drag on an item node, driven **mid-drag through the real event view** and then flushed to disk, the node still has a height, is still returned by `nodes(intersecting:)` and is still found by `topmostNode(at:)`. A re-measure at `.ended` hides the whole gesture, which is why mid-drag is not optional.
- The corner drag changes the width and the height follows the aspect ratio — assert the ratio, not two literals.
- A resize below the minimum is refused or clamped, whichever the scrap path already does; do not invent a second rule.
- The mark is drawn on an item node (raster fixture, under an explicit appearance).
- **Control:** a scrap still resizes exactly as it did, and `test_theUnmarkedHalfOfTheCornerSquareStillResizes` is green — that test exists to stop a tidy-up shrinking the target to the ink, and this task edits precisely that code.
- **Disable experiment:** remove Task 5's item measurement and the mid-drag survival test goes red with a nil height, which is the original Critical reproducing on demand.

- [ ] **Step 1:** Write the re-pointed tests. Run; confirm the new ones fail and the scrap control passes.
- [ ] **Step 2:** Widen the target in `CanvasInteraction.begin` and the mark in `drawCard`, together, in one commit.
- [ ] **Step 3:** Run the whole `CanvasViewMountingTests`, `CanvasInteractionTests` and `CanvasRendererTests` files, not only the new cases.
- [ ] **Step 4:** Commit — `feat(canvas): an item node resizes, now that it is measured`.

---

## Task 7: The item node's inspector arm

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

## Task 8: An owned item node promotes

**Files:** Modify `Promotion.swift:395-445` (targets, `blockedReason`, `itemNodeReason`), `PromotionPerformer.swift`, `PromotionSheet.swift`, `ItemInspector.swift` (Task 7). Test: `MaughamTests/Canvas/PromotionTests.swift` and peers.

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

## Task 9: Re-derive tasks 10–14 against the built code

**Files:** Modify this plan.

This is a **plan task**, not a code task, and it is the sequencing device that replaces splitting the milestone. Tasks 10–14 are stated below as requirements and failures; their contracts cannot be written until tasks 1–8 exist, because they call into them.

- [x] **Step 1:** Read what tasks 1–8 actually built — `CanvasItemReference`, the ingestion pair's real signature, `CanvasItemFacts`' real shape, `ItemInspector`'s parameters, and whether `CanvasClaudeWrite`'s seam took the shape Task 12 needs.
- [x] **Step 2:** Re-read `Maugham/Canvas/AREA.md`. Tasks 1–7 will have changed it; the statements below were written against the 2026-07-30 version.
- [x] **Step 2b:** **Place the region-with-an-image gap, which Task 8 made collectable.** Spec §6's 2026-07-29 amendment says the palette-card row's case *"gets stronger rather than weaker in 1C-d: a palette card is worth making from a region that holds an **image**, which the canvas cannot hold until then."* The canvas holds one now — and promoting such a region still produces a card with **no images**. Task 8 recorded it at the site (`Promotion.plan`'s region arm) rather than guessing, because it is a decision about the *region's* row rather than the item's. `ProjectStore.addImage(toPaletteCard:fileURL:)` is already wired into that file, so it is small. Decide: a task, or a recorded ruling that the region row stays text-only and why.
- [x] **Step 2a:** **Give `list_canvas` an answer for an owned item node, or rule that it does not need one.** Task 1's implementer raised this and no task owns it: an owned node reports `kind: "item"` with `reference_id: null`, because a project-relative path does not belong in a field documented as an item id and adding a wire field was outside that task. Once tasks 10–12 land, that is **a card Claude can see and cannot identify** — and `list_canvas` is a read, so reporting geometry and identity is legitimately its job (the no-position rule constrains the *write* tool). Decide, and write the decision down: a new optional field on the read, or a stated ruling that an owned asset is deliberately opaque to Claude. Either way it becomes a task or a recorded decision, not a silence. **If it adds a field, `Maugham/MCP/AREA.md` has three prose occurrences of the tool count that `DocSyncTests` cannot see** — the count does not change here, but check the file's `list_canvas` description does not go stale.
- [x] **Step 3:** Write tasks 10–14 in full, in the shape tasks 1–8 use: files, interfaces with **verified** signatures, requirements, the failure each must not have, the tests, the disable experiment. Contracts, not bodies.
- [x] **Step 4:** Run the Mac suite **and the phone suite** once here — `MaughamCore` is shared and the two schemes are independent.
- [x] **Step 5:** Commit — `docs(plan): 1C-d's second half, derived against the built code`.

---

## Tasks 10–14, written at Task 9 against the built code

*The statements these replace were written on 2026-07-30 against tasks 1–8's* intended *shapes. What follows was derived on 2026-07-31 against what they actually built, and **every signature below was read out of the tree at the line given on that date**. Two decisions Task 9 was required to make rather than write up are recorded first, because two tasks depend on them.*

### Signatures verified at Task 9 (2026-07-31)

These are the ones tasks 10–14 call into and the table at the top of this plan does not carry. Anything not quoted here is deliberately not asserted.

| Symbol | Signature as read | Where |
|---|---|---|
| the two provenances | `case project(id: String)` / `case owned(path: String)` | `Maugham/Canvas/CanvasItemReference.swift:28`, `:37` |
| ingestion pair | `public func ingestCanvasAsset(image: NSImage) async throws -> String` and `(fileURL: URL)`, each returning the **project-relative** path | `Maugham/Stores/ProjectStore+CanvasAssets.swift:44`, `:54` |
| the saver, underneath it | `saveAndReferenceFile(from:forNoteAt:in:) throws -> String` — takes `sourceURL.pathExtension` as given and **validates nothing**; a `.txt` copies happily | `Maugham/Editor/ImagePasteHandler.swift:31-40` |
| item facts | `static func resolve(_ reference: CanvasItemReference, in index: CanvasItemIndex) -> CanvasItemFacts` | `Maugham/Canvas/CanvasItemFacts.swift:87` |
| the manifest index | `struct CanvasItemIndex`, `static func over(research: [ResearchItem]) -> CanvasItemIndex`, `func entry(of itemID: String) -> Entry?`, `let fingerprint: String` | `CanvasItemFacts.swift:191`, `:284`, `:320`, `:259` |
| its production build site | `itemIndex: Self.canvasItemIndex(in: store)`, on the `CanvasView(` mount | `Maugham/Views/ProjectWindow.swift:906-909` |
| **the canvas is the CONTENT column** | `CanvasView(model:projectRoot:paletteSwatchHexes:itemIndex:)` is inside `contentColumn` (`:758`–`:970`), not `detailColumn` (`:971`) | `ProjectWindow.swift:906` |
| view point → canvas point | `func contentPoint(fromView p: CGPoint) -> CGPoint` | `Maugham/Canvas/CanvasCamera.swift:32` |
| the drop's membership rule | `static func joinTarget(for node: CanvasNodeID, in scene: CanvasScene) -> CanvasRegionID?` — **returns nil for a node with no `frame`** | `Maugham/Canvas/CanvasInteraction.swift:593` |
| the create-then-measure-then-join sequence | `beginGesture("New Scrap")` → `withScene { createScrap }` → `setScrapText` → `rebuildLayouts()` → `withScene { joinTarget → join → bumpSceneRevision }` | `Maugham/Canvas/CanvasView.swift:1158-1200` |
| node minting | `static func createScrap(at contentPoint: CGPoint, in scene: inout CanvasScene) -> CanvasNodeID`, retried against the scene | `CanvasInteraction.swift:467` |
| membership write | `public static func join(_ node: CanvasNodeID, home: CanvasRegionID, in scene: inout CanvasScene)` | `Maugham/Canvas/CanvasMembership.swift:14` |
| drop classification | `nonisolated static func action(hasFileURL: Bool, canLoadImage: Bool) -> DropAction` (`.fileURL`/`.image`/`.ignore`); `static func fileURLs(from providers: [NSItemProvider]) async -> [URL]`; **`private static func loadImageAsTempFile(provider:) async -> URL?`** | `Maugham/Views/DropClassification.swift:20`, `:31`, `:64`; enum at `:11` |
| the four existing adopters | `.onDrop(of: [.fileURL, .image], …)` | `ResearchView.swift:57`, `CollectionResearchPane.swift:105` and `:148`, `PaletteCardEditor.swift:225` |
| internal drag payload | `.draggable(item.id)` — the **raw** id, no prefix; received by `.dropDestination(for: String.self)` | `ResearchRow.swift:64`, `:69` |
| **the canvas has no drop code at all** | zero `onDrop` / `dropDestination` / `.draggable(` under `Maugham/Canvas/` | grep, 2026-07-31 |
| inbox promote siblings | `func promoteToResearch(_:projectStore:scope:) async throws -> ResearchItem` and `func promoteToPaletteCard(_:projectStore:cardId:) async throws -> PaletteCard` | `Maugham/Stores/InboxStore.swift:226`, `:270` |
| the `.promoted` flip | `updateStatus(id:to:resolvedAt:)` (non-throwing) and `updateStatusThrowing(id:to:resolvedAt:)` | `InboxStore.swift:164`, `:179` |
| inbox asset | `func assetURL(for entry: InboxEntry) -> URL?` | `InboxStore.swift:381` |
| capture kinds | `case text, image, audio`; `inlineText: String?`; `transcript: String?` | `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift:18`, `:80`, `:81` |
| the empty-transcript refusal | `.audio` with an empty transcript throws `InboxError.nothingToPromote(entry.id)` | `InboxStore.swift:294-295` |
| the inbox row's menu | `.contextMenu` with `Button("Promote to Research")` `:194`, `Button("Promote to Palette Card…")` `:207`; **no `.draggable`, no `selection:`** | `Maugham/Views/InboxPane.swift:193-227`, `:49` |
| its async pattern | `private func promote(_ entry: InboxEntry, scope: ResearchScope)` → `Task { do { … } catch { promoteError = … } }` | `InboxPane.swift:232-240` |
| the loose-placement rule | **`private`** `static func regionOrigin(in scene: CanvasScene) -> CGPoint` → `occupied.maxX + gutter` over every node frame **and** every region frame | `Maugham/Canvas/CanvasClaudePlacement.swift:368` |
| the attached/detached seam | `static func readScene(store:projectRoot:) -> (scene:scraps:fromOpenCanvas:)`; `static func apply(_:store:projectRoot:) throws`; **`private static func liveModel(of:)` is the one place `store.liveCanvas` and `isAttached` are written** | `Maugham/Canvas/CanvasClaudeWrite.swift:49`, `:81`, `:136` |
| the outside-column verb | `func mutateFromInspector(_ name: String, scrapTexts: [CanvasNodeID: String] = [:], _ body: (inout CanvasScene) -> Void)` | `Maugham/Canvas/CanvasModel.swift:431` |
| `list_canvas`' owned arm | `case .item(.owned): kind = "item"; referenceId = nil; text = nil` | `Maugham/MCP/Tools/CanvasTools.swift:194-209` |
| the promotion's picture | `let picture: PromotedPicture?` on `PromotionPlan`, **singular, no memberwise default**; `struct PromotedPicture { node; assetPath; paletteCardID }` | `Maugham/Canvas/Promotion.swift:546`, `PromotedPicture` above it |
| the region arm's recorded gap | `picture: nil` with the "left unbuilt rather than guessed at here" comment | `Promotion.swift:835-845` |
| the region's member bodies | `private static func regionBodies(_ region: CanvasRegion, in scene: CanvasScene, scraps:) -> [(CanvasNodeID, String)]` — **home members only**, reading order | `Promotion.swift:1033` |
| ⌘\ | `MaughamEvent.post(.maughamToggleNoChrome, to: .keyWindow)` under `.keyboardShortcut("\\", modifiers: .command)`; received by `FocusPostureModifier` | `Maugham/MaughamApp.swift:189-192`; `ProjectWindow.swift:1559`, `:1568` |
| what focus mode does today | `applyNoChrome()` — titlebar transparency, title visibility, the three standard buttons. **It touches no column.** | `ProjectWindow.swift:1290-1297` |
| the split view | `NavigationSplitView { binderColumn } content: { contentColumn } detail: { detailColumn }` — **no `columnVisibility:` argument** | `ProjectWindow.swift:93-100` |
| the right column's existing switch | `if showInspector { inspectorPane(…) }` | `ProjectWindow.swift:971-976` |
| the stash hazard | `PaletteSegmentModifier`'s `.onChange(of: binderSegment)`; `static func clearsPaletteStash(from current: BinderSegment, to next: BinderSegment) -> Bool` | `ProjectWindow.swift:469-478`; `:1664` |
| the eleven modifiers on `body` | `.modifier(` at `:166, :259, :276, :284, :287, :293, :317, :321, :326, :331, :338` | `ProjectWindow.swift` |
| the stale guide sentence | *"For now the page shows as a placeholder card carrying its reference — the picture itself arrives with the rest of the image work."* | `docs/guide/getting-started.md:111` |

---

### Decision A (Step 2a) — `list_canvas` gains one optional field, and it is the PROVENANCE, never the path

**The state today.** `ListCanvasTool.describe` has three arms (`CanvasTools.swift:183-210`). An owned node takes the third and emits `kind: "item"`, `reference_id: null`, `text: null` — a card with geometry, possibly a promotion mark, and **nothing at all that says what it is**. That arm's own comment says the answer "is a decision for the slice that first creates one", and tasks 11 and 12 are that slice.

**Ruled: add one optional field to `ListCanvasTool.Node` carrying the provenance — `"project"` or `"owned"` — absent for a scrap. Do not put the path on the wire.**

Three reasons, in the order they decided it.

1. **`list_canvas` is a read, and identity is a read's job.** The no-id/no-position rule is a constraint on the *write* tool (`add_canvas_scraps`' five keys, `AREA.md`'s "The MCP surface"), and that file already says so in as many words: *"`list_canvas` reports geometry, legitimately, being a read."* Silence here is not that ruling extended; it is a hole.
2. **A path is not a smaller answer, it is a worse one.** Nothing in the catalogue reads a file by project-relative path — `read_document` resolves a document or research id. Handing Claude `canvas_assets/photo-….png` gives it a string it can feed to nothing, in the field a reader will most reasonably feed to something else. That is the id/path smear `CanvasItemReference` exists to stop, arriving on the wire instead of in the model.
3. **What Claude actually lacks is a distinction, and one word supplies it.** Today a null `reference_id` on an item node happens to mean "owned", but the field is documented as *"the research item / palette card an item node points at. Absent for a scrap"* — so the null is undocumented rather than deliberate, and the next arm added makes it ambiguous. A stated provenance is the fact, costs one optional key, and reads correctly for both cases.

**What it deliberately does not do**, recorded so the next author meets a decision rather than a gap, exactly as §8A.4's own last paragraph does for `read_inbox_entry`: **Claude still cannot see an owned picture's pixels.** The missing piece would be an image response keyed on a canvas node id, which is a new read tool and a new response shape, and it is not in this slice.

**Cost, checked.** No tool is added, so the catalogue stays at **54** and no tools-list test moves. `AddCanvasScrapsTool.Params` is untouched, so `test_theSignatureCannotExpressAPositionOrAnId` is not in scope. `Params` for `list_canvas` is untouched. What *does* move is `MaughamTests/MCP/Tools/CanvasToolsTests.swift` around `:132` and `:142`, which assert on `reference_id` — read them rather than editing past them. This is **Task 11's** to carry, because Task 11 is what first mints an owned node in production.

### Decision B (Step 2b) — the region-with-an-image gap becomes a task, and it is Task 12a

**Ruled: a task, and it is not as small as the brief hoped.** Spec §6's 2026-07-29 amendment is a ruling, not an aspiration: the palette-card row *"gets stronger rather than weaker in 1C-d: a palette card is worth making from a region that holds an image, which the canvas cannot hold until then."* Shipping 1C-d with an image-holding region promoting to a picture-less palette card ships the amendment's own stated weakness inside the milestone that was supposed to remove it. This project has no defer bucket (`memory/feedback_no_defer_bucket.md`).

**Why it is not two lines.** `PromotionPlan.picture` is `PromotedPicture?` — **singular** (`Promotion.swift:546`) — and a region can hold several; and §6.3's contribution record is defined over *"members whose text went in"*, which is `regionBodies`, which reads the scrap table and cannot see a picture. Task 8's fix round then made the record's clear skip item nodes on `CanvasNodeKind.isScrap` (ledger, Task 8 M1). So carrying pictures reopens the contributor predicate deliberately. That is real work with a real blast radius and it is stated rather than hidden.

**Numbered 12a rather than renumbered in.** The house already does this — `1C-c2a`, `1C-c2b` — and renumbering would strand the ledger's own pointers ("CARRY TO TASK 14", "deferred to Task 14's sweep"). It sits after Task 12 for an execution reason and not an alphabetical one: nothing in production mints an owned node until tasks 11 and 12 land, so before them this row cannot be smoked either.

**One question inside it is Denver's, not the plan's**, and Task 12a ships a stated default rather than blocking on it. See that task's *FOR DENVER* requirement.

---

## Task 10: The drop target, and the research drag

**Spec:** §8A.1. **Files:** Create `Maugham/Canvas/CanvasDrop.swift` (the pure router). Modify `Maugham/Canvas/CanvasView.swift` (the modifier and the create path), `Maugham/Views/ProjectWindow.swift:906-909` (whatever the drop needs handed to it). Test: create `MaughamTests/Canvas/CanvasDropTests.swift`; modify `MaughamTests/Canvas/PromotionCommandTests.swift` (the wiring census).

**Interfaces — consumes:** `CanvasCamera.contentPoint(fromView:)` (`CanvasCamera.swift:32`); `CanvasInteraction.joinTarget(for:in:)` (`CanvasInteraction.swift:593`); `CanvasMembership.join(_:home:in:)` (`CanvasMembership.swift:14`); `CanvasNodeID.item(_:)` (`CanvasNode.swift:31`); `CanvasItemIndex.entry(of:)` (`CanvasItemFacts.swift:320`) — **already a parameter of `CanvasView`**, so validation costs no new wiring; the create-then-measure-then-join sequence at `CanvasView.swift:1158-1200`.

**Interfaces — produces:** a **pure** router — dropped payload plus the scene plus the index in, a decision out — and one `.dropDestination(for: String.self)` on the canvas that does nothing but call it. The split is not stylistic: SwiftUI's drop delivery is not drivable from XCTest, so the decision has to be testable somewhere the tests can reach, and the *wiring* has to be pinned by a census instead. 1C-b's own lesson, recorded in the ledger: routing decisions want a pure function tested exhaustively.

**Requirements**

- **A research item id creates a REFERENCED item node at the drop point.** The file is untouched; the canvas holds a position. The id is `CanvasNodeID.item(id)`, which is the whole point of that spelling — two adds of one research item resolve to one node (`CanvasNode.swift:22-32`).
- **An id already on the canvas is not re-created and not moved.** `CanvasScene.insert` is keyed by id (`CanvasScene.swift:63`), so a second drop would **overwrite the existing node** — silently discarding its membership, its promotion mark, its width, its z and its author. Select the existing node instead; bringing it on screen is the established courtesy (`camera.bring(_:toViewPoint:)`, used by the arrival banner's Show at `CanvasView.swift:666`). Moving it would be a geometry-driven change to something the writer placed, which is what `CanvasClaudePlacement`'s `.cited`/`.adopted` split already refuses for the same reason (`AREA.md`, "The page is never moved").
- **Validate the id against `CanvasItemIndex` before creating anything.** The binder drags manuscript pieces and tasks with the same raw-id payload (`PieceRow.swift:62`, `TasksPane.swift:246`), so a string arriving here is not necessarily a research item. A node created for an id in no manifest draws `CanvasItemFacts.missingTitle` — *"No longer in the project."* — **from birth**, which is a card the writer cannot fix and cannot explain.
- **A research GROUP: decide it, out loud, and check both neighbours first.** `CanvasItemKind.group` exists and resolves deliberately (`CanvasItemFacts.swift:135-137`: *"'no longer in the project' said over a folder the writer can see in the binder is a lie"*), while `AddCanvasScrapsTool` **refuses** a group id (`AREA.md`, "Refusals"). Those are not in conflict — one is Claude naming a photographed source page, the other is a writer pointing at a folder — but they must not disagree *silently*. Recommendation: accept it, because Task 4 built the glyph and the ruling for exactly this case. Whichever way it goes, the reason goes in the router's doc comment, not in a plan.
- **Measure, THEN join.** `joinTarget` reads the node's **centre** and returns nil for a node with no `frame` (`CanvasInteraction.swift:594`), so a join asked before `rebuildLayouts()` silently joins nothing — on every drop, forever, with nothing red. `CanvasView.swift:1177-1185` already carries this warning in prose for the scrap path; this is its second instance.
- **The centre a drop reads is the label-only floor's**, because an item node's height is `CanvasCardMetrics.itemLabelOnlyHeight` until its thumbnail resolves. Do not await a decode to make the join exact — the wait is unbounded and the writer is holding a mouse button. State the consequence and leave it.
- **Tripwire 31: this is the task's ONE legitimate geometric reading.** `joinTarget` and nothing else. If `region.frame.contains(…)` appears anywhere else in the diff, it is wrong.
- **One drop is one undo step, and the verb is `mutateFromInspector`.** *(This bullet said the opposite until 2026-07-31; Task 10's implementer refused to build it and showed why. The wrong version is quoted here rather than deleted, because the reasoning that defeated it is the useful part.)* It read: *"It is `mutate`'s family and **not** `mutateFromInspector`: a drop is delivered to the canvas view, and there is no other column's gesture to protect."* **Delivery is not the discriminator.** The discriminator is whether the arriving mutation has a bracket **of its own** to protect, and AREA.md `:502` says so in the sentence the bullet misread — *"`CanvasView` keeps using `mutate` — everything it does is already inside its own bracket **by construction**."* A binder→canvas drop is not: the gesture starts in the left column.
  **The reachable repro, verified:** double-click bare canvas (opens `beginGesture("Edit Scrap")`, `CanvasView.swift:1200`), type, then — without clicking the canvas — drag a research row from the tree and drop it. Nothing closes that bracket, because `commitActiveEdit` has exactly one caller (`CanvasView.swift:1106`, inside `handleClick`) and a drag starting in the binder never reaches it. The drop arrives at depth 1, `beginGesture` takes no snapshot (`CanvasUndo.swift:100-105`) and `endGesture` registers nothing (`:110-113`), so the card rides into the writer's next sentence. That is `CanvasClaudeWrite`'s shape (AREA.md `:611`, *"the sharpest of the five because it needs no gesture at all"*) with a hand on it.
  **The existing census already rules on it**: `canvasBracketCensus` skips only `theCanvasSurface` and `canvasBracketDefiners`, scans every file containing `CanvasModel`, and `withScene` is an inside verb (`TripwireGrepTests.swift:1771-1799`) — so a `CanvasDrop.swift` using the inside family fails the census by construction. **`CanvasDrop.swift` becomes a census entry; count the array rather than any number here.**
- **The node is BORN MEASURED, at `CanvasCardMetrics.itemLabelOnlyHeight`** — `CanvasClaudePlacement.swift:248`'s existing spelling for the identical case, a producer with no view to measure what it creates. That removes the ordering hazard instead of pinning it, which matters because `mutateFromInspector` runs `onSceneChangedExternally` **after** its body inside the bracket (`CanvasModel.swift:431-439`), so an insert → measure → join sequence cannot be expressed in one call and splitting it would be two brackets for one drop.
- **The accepted cost, on the record:** with "Edit Scrap" open, a drop closes the writer's run of typing into its own step and reopens the visit — one extra ⌘Z boundary mid-sentence. That is what the verb does everywhere else it is used, and it is far the cheaper failure: the alternative is a ⌘Z aimed at prose taking a card with it.
- **Task 12's inbox route is the third caller of this drop target and inherits this verb**, so the question is settled once here rather than re-litigated one task later with a different answer.

**The failure it must not have:** a second drop of an item already on the canvas destroying that node's membership, mark and geometry — a silent overwrite that looks exactly like nothing happening.

**Tests that must exist**

- The router, exhaustively over the product it decides on: id present in the index × node already in the scene × drop point inside a region / outside every region. A table-driven test, `CanvasPersonaTests`' shape for the same reason.
- A node created by the router has a non-nil `cachedHeight` after the measure and is returned by `scene.nodes(intersecting:)`. Present in `topmostNode(at:)` too — the 1C-c3 Critical was a node dropped by both.
- Dropped inside a region by centre, its home is that region; dropped so that its **centre** is one point outside the region's edge, it is homeless. (Not its origin — the corner test is the one §4.2 cites against Obsidian.)
- A second drop of the same id changes the existing node's origin, width, home region, `promotedItemID` and `z` **not at all**. **Control:** a drop of a *different* id in the same test does create a second node, so the first assertion cannot pass by drops being broken.
- An id in no `CanvasItemIndex` creates nothing. **Control:** the same id, with an entry added to the index, does create one.
- One drop is one ⌘Z, asserted on `CanvasUndo.undoMenuItemTitle` and not on the post-⌘Z scene. A scene-only observable cannot tell "its own step" from "folded into the neighbour", demonstrated twice in one slice (`AREA.md`, "Writing tests in this area").
- **Wiring census:** the `.dropDestination` mount line on `CanvasView`'s real body, added to `PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite`, with a planted-offender arm. ****Count the array. Do not read a number from this plan** — the figure written here was already wrong when the brief was drafted (`ItemInspector` had made it six at Task 8) and the census stands at seven now. A prose count over an array, in a task whose own review turned on exactly that.** A pure router with no modifier on it is this area's fifth built-and-unreachable half, and all four previous ones were found by a caller count rather than by a test.
- **Disable experiment (substituted 2026-07-31, stricter than the original):** drop the `cachedHeight:` argument on the created node — the membership tests go red while every creation test stays green. The original said *"move the join above `rebuildLayouts()`"*, which falsified an **ordering** that merely happened to produce a measured node; this falsifies **"a dropped node lands measured"** directly. It earned its keep twice: run against Task 10's own tests it also exposed a **vacuous assertion** — `test_aCardWhoseCentreLandsOnePointOutsideTheRegionIsHomeless` stayed green with the node born unmeasured, because "homeless" is satisfied just as well by there being no centre at all. That test now carries a second control asserting the card was measured.

- [ ] **Step 1:** Write the router's tests and watch them fail for the stated reason.
- [ ] **Step 2:** Build the router; mount it; extend the census.
- [ ] **Step 3:** `grep -rn CanvasDrop Maugham/` — confirm a production caller. Run the three census files named in the global constraints, not only the Canvas suite.
- [ ] **Step 4:** Full Mac suite. Release build if `ProjectWindow.body` moved.
- [ ] **Step 5:** Commit — `feat(canvas): research drags onto the canvas`.

---

## Task 11: External drops — a photo from Finder or a browser

**Spec:** §8A.1. **Files:** Modify `Maugham/Canvas/CanvasView.swift` (the second drop modifier), `Maugham/Canvas/CanvasDrop.swift` (Task 10), `Maugham/Views/DropClassification.swift` (see below), `Maugham/Views/ProjectWindow.swift` (the ingest closure), `Maugham/MCP/Tools/CanvasTools.swift` (Decision A). Test: `MaughamTests/Canvas/CanvasDropTests.swift`, `MaughamTests/MCP/Tools/CanvasToolsTests.swift`, `MaughamTests/TripwireGrepTests.swift`.

**Interfaces — consumes:** `DropClassification.action(hasFileURL:canLoadImage:)` (`DropClassification.swift:20`); `DropClassification.fileURLs(from:)` (`:31`); `ProjectStore.ingestCanvasAsset(fileURL:)` (`ProjectStore+CanvasAssets.swift:54`) and `(image:)` (`:44`); Task 10's router and its measure-then-join ordering.

**Requirements**

- **`.onDrop(of: [.fileURL, .image], isTargeted:)`, and never `.dropDestination(for: URL.self)`.** Browser image drags carry rendered bitmaps rather than file URLs and that modifier rejects them with CoreTransferable error 0 — nothing logged, nothing red, nothing on screen. The canvas is the **fifth** adopter of `DropClassification` (`ResearchView.swift:57`, `CollectionResearchPane.swift:105` and `:148`, `PaletteCardEditor.swift:225`) and adds no classification logic of its own.
- **The ingested node is `.owned(path:)` with a MINTED id.** Not `CanvasNodeID.item(path)` — `CanvasNode.swift:8-16` rules it out explicitly, and says which spelling to use. There is no sixth.
- **Await first, touch the scene second.** `ingestCanvasAsset` is `async throws`; an `inout CanvasScene` cannot cross a suspension point. That is Swift rather than style — `CanvasClaudeWrite.swift:26-31` and `PromotionPerformer` both turn on it.
- **`ingestCanvasAsset(image:)` is at risk of being this area's fifth unreachable half, and this task is where that is settled.** If the browser-bitmap branch goes through `DropClassification.loadImageAsTempFile` (`:64`, currently `private`) it lands on the *file* twin and the image twin ends the milestone with **zero production callers** — built, tested, unreachable, exactly like ⌘Z, `CanvasScene.remove`, `addAppearance` and `lines(touching:)` before it. **Count `grep -rn ingestCanvasAsset Maugham/` before calling this task done.** Recommendation: give the image twin its caller here and retire the *fourth* hand-rolled `loadObject(ofClass: NSImage.self)` at the same time — three exist already (`DropClassification.swift:66`, `ResearchView.swift:336`, `PaletteCardEditor.swift:420`) and a shared `image(from:)` beside `fileURLs(from:)` is where it belongs. If the temp-file route is taken instead, the image twin is deleted or given its caller; a third answer is not available, and the ledger records which was taken.
- **Refuse a non-image file, and this is a real hole rather than a hypothetical.** `ImagePasteHandler.saveAndReferenceFile` takes `sourceURL.pathExtension` as given and **validates nothing** (`:31-40`), so a `.txt` dropped on the canvas copies into `canvas_assets/`, mints an owned node, draws the `photo` glyph and queues a decode that can only fail — and `CanvasThumbnails` **memoises failures**, so it is one permanent dead cache entry per mistake (`CanvasItemFacts.swift:33-37`). Check the type before ingesting, not after.
- **A multi-file drop lands every file**, each with its own node, none exactly on another. `CanvasClaudePlacement.cardGap` (`:60`) is the existing spacing constant; do not mint a second.
- **A failed ingest leaves nothing on the canvas and is not silent.** The inbox's `.alert("Couldn't promote", …)` over a `@State private var promoteError: String?` is the nearest precedent (`InboxPane.swift:29`, `:72`). **If a banner is chosen instead, say so out loud** — this plan's own known-gaps section says a fourth transient overlay in this window must be declared rather than quietly added.
- **Decision A ships here** (see above): `ListCanvasTool.Node` gains one optional provenance field, `"project"` or `"owned"`, absent for a scrap; the path does not go on the wire. This task is where it lands because this task is what first mints an owned node in production. Read `CanvasToolsTests.swift:132` and `:142` rather than editing past them, and check `Maugham/MCP/AREA.md`'s `list_canvas` description for the sentence that goes stale. **The tool count does not change** — it stays 54 and no tools-list test moves.

**The failure it must not have:** a browser drag that appears to do nothing, with nothing logged and nothing red.

**Tests that must exist**

- The canvas's *use* of the classifier, not the classifier: providers with a file URL route to the file twin; providers with only an image route to the image twin; providers with neither create nothing. `DropClassification.action` is already tested — do not re-test it.
- The created node's reference is `.owned(path:)` and the path is project-relative: **no leading `./`, no `file://`, no `![](`**. All three are named in `CanvasItemReference.swift:30-37` as the failures, so assert all three rather than "it is non-empty".
- The file exists under `canvas_assets/`, and the **source file still exists** — it is a copy, not a move (`ProjectStore+CanvasAssets.swift:50-53`).
- A `.txt` drop creates no node and copies no file. **Control:** the same drop with a `.png` does both.
- `list_canvas` on a scene holding one owned node and one referenced node reports two different provenances, and **the owned one's response contains the path nowhere at all** — assert the absence, which is the decision, rather than the presence, which is the easy half.
- **Tripwire census:** the canvas's drop modifiers name `[.fileURL, .image]`, and `dropDestination(for: URL` appears nowhere in `Maugham/Canvas/`. With a planted-offender companion — a census over a *forbidden* token is the shape that passes while blind (`AREA.md`, "Writing tests in this area").
- **Disable experiment:** replace the `[.fileURL, .image]` provider route with `.dropDestination(for: URL.self)` and the browser-bitmap test goes red while the Finder-file test stays green. That is the bug the spec names, reproduced on demand.

- [ ] **Step 1:** Tests. Run; confirm failure.
- [ ] **Step 2:** The two branches, over the ingestion pair.
- [ ] **Step 3:** Decision A on `ListCanvasTool.Node`.
- [ ] **Step 4:** `grep -rn ingestCanvasAsset Maugham/` and record both twins' caller counts in the report.
- [ ] **Step 5:** Full Mac suite plus the three census files.
- [ ] **Step 6:** Commit — `feat(canvas): a photograph dropped on the canvas has a home`.

---

## Task 12: Inbox → canvas, both routes, all three kinds

**Spec:** §8A.4 and its 2026-07-30 amendment. **Files:** Modify `Maugham/Stores/InboxStore.swift` (the third sibling), `Maugham/Views/InboxPane.swift:193-240` (the drag and the command), `Maugham/Canvas/CanvasClaudeWrite.swift` **or** a sibling beside it (see below), `Maugham/Canvas/CanvasClaudePlacement.swift:368` (the loose-placement rule), `Maugham/Canvas/CanvasDrop.swift` (the third payload). Test: create `MaughamTests/Stores/InboxToCanvasTests.swift`; modify `MaughamTests/TripwireGrepTests.swift`, `MaughamTests/Canvas/CanvasDropTests.swift`.

**Interfaces — consumes:** `InboxStore.promoteToPaletteCard` (`:270`) as the **contract to copy**; `InboxStore.assetURL(for:)` (`:381`); `InboxStore.updateStatusThrowing(id:to:resolvedAt:)` (`:179`); `InboxEntry.Kind` `.text/.image/.audio`, `inlineText`, `transcript` (`InboxEntry.swift:18`, `:80`, `:81`); `ProjectStore.ingestCanvasAsset(fileURL:)` (`ProjectStore+CanvasAssets.swift:54`); `CanvasClaudeWrite.readScene`/`apply` (`:49`, `:81`); `CanvasClaudePlacement.regionOrigin(in:)` (`:368`, **private today**).

**Requirements**

- **A third sibling beside the two, never a new spelling of them** (§8A.4). Copy-then-remove so a failure leaves a harmless duplicate; flip to `.promoted` **only after every mutating step has succeeded**.
- **The two existing siblings order it differently, and this task must not pick by coincidence.** `promoteToResearch` removes the source asset at `:250` and flips at `:252`; `promoteToPaletteCard` copies at `:305`, flips at `:312`, and removes at `:315`. §8A.4's sentence is the palette one's order. Follow it and say so, so the next reader does not think the two disagree by accident.
- **All three capture kinds or it does not ship** (§8A.4's own ruling, and the reason this section is 1C-d's rather than 1C-c3's). Text → a scrap carrying `inlineText`. Voice → a scrap carrying `transcript`. Photograph → an **owned** item node through the ingestion pair.
- **A voice capture with no transcript is refused and stays in the inbox.** `promoteToPaletteCard` already throws `InboxError.nothingToPromote(entry.id)` on exactly this (`:294-295`); a blank scrap plus a `.promoted` entry is the capture lost.
- **Route 1, the drag, is the third caller of Task 10's drop target and adds no placement rule.** The row gains `.draggable`; `InboxPane` has none today (`:49` has no `selection:` either).
- **The drag payload is PREFIXED, and this deliberately breaks the house's raw-id pattern.** `ResearchRow.swift:64` sends `item.id` bare, and every existing drop target reads one id space. The canvas is the first that reads **two**: a research item id and an inbox entry ULID are not tellable apart, and Task 10's rule refuses any string not in `CanvasItemIndex` — so a bare ULID would be silently rejected by the target built one task earlier. Prefix it (`"inbox:<id>"`), destructure it in Task 10's router, and put the reason in the router's doc comment where the next drop source will read it.
- **Route 2, the command, sits beside "Promote to Palette Card…" on the row** (`InboxPane.swift:207`) and matches that file's async pattern exactly (`:232-240`: `Task { do … catch { promoteError = … } }`). It is not redundant: a drag is unreachable from the keyboard, unreachable to VoiceOver, and unavailable with the pane closed or another persona on screen.
- **The command's placement is LOOSE and never in a region**, and that asymmetry with §8A.2 is the amendment's own ruling — Claude's batch takes a region because the corollary requires a derived scrap stay tied to its source; a writer sending one capture has already decided what it is, and a container they will delete is friction. **So the command route does not call `joinTarget`.** A helpful implementer will add it for symmetry with the drag; that is the ruling broken, not a tidy-up.
- **Do not spell a second `occupied.maxX + gutter`.** `CanvasClaudePlacement.regionOrigin(in:)` (`:368`) is that rule and it is `private`; widen it, and rename it, since it now serves a bare card as well as a region. A second copy is two answers to "clear of the writer's work" that will drift.
- **The write goes through the one attached/detached seam, and the invariant is the DISCRIMINATOR rather than the filename.** `CanvasClaudeWrite.liveModel(of:)` (`:136`) is the single place `store.liveCanvas` and `isAttached` are written together, and its own doc comment is why: the read and the write must not come to different conclusions about which canvas is real. **Whichever shape this task takes — generalising that file, or a sibling that shares the helper — that pair may appear exactly once in production, and a grep census is what holds it.** If the file is **renamed**, tripwire 32's census array changes: edit it in the same commit and **count the array, never this sentence** (it holds five entries today, and `Maugham/Canvas/AREA.md:611` describes that file by name). If a **sixth writer** appears, it grows. Recommendation: do not rename — the name is about Claude and this is not Claude — and take the sibling, sharing `liveModel`.
- **`mutateFromInspector`, the bump on its own line, `flush()` and not `scheduleSave`.** Tripwire 32's sharpest repro is a write arriving while the writer is inside a scrap with "Edit Scrap" held open and **nothing on either side closes their bracket**; a Send from a pane in the other column has none of its own to protect either. The words travel **inside** the bracket via `scrapTexts:` — `CanvasModel.swift:412-427` records both other orderings as measured failures.
- **The writer is told, and told where** (§8A.4's amendment: the landing place is off-screen by construction, so it *may not be silent*). Reuse `CanvasClaudeArrivalModifier`'s host if it can carry a non-Claude arrival; if it cannot, this is a **fourth** transient overlay in a window where two on screen already draw over each other, and this plan's known-gaps section requires that be said out loud rather than quietly added.
- **The command must work with the Plan persona closed** — that is its whole point — so it exercises the detached route and `save`, exactly as `CanvasClaudeWrite`'s sidecar arm does.

**The failures it must not have:** a capture that leaves the inbox and appears nowhere the writer is looking; a send arriving while the writer is inside a scrap that rides into their next sentence; a half-promoted entry.

**Tests that must exist**

- **Six cases: three kinds × two routes.** The "all three or it does not ship" rule only bites if a missing kind is a red test rather than an absence.
- A photograph's node is `.owned(path:)`, its file is under `canvas_assets/`, and the **inbox asset is gone** while the entry is `.promoted`.
- A failed canvas write leaves the entry **not** `.promoted` and its asset in place. **Disable experiment:** move the flip above the write and this goes red while the happy-path tests stay green.
- The command route's node lands outside the union of every existing node and region frame, and is in **no** region. **Control:** the drag route with the same entry, dropped inside a region, does join it — so the "no region" assertion cannot pass by membership being broken.
- A voice capture with `transcript == nil` is refused, creates nothing, and stays in the inbox.
- One send is one ⌘Z, asserted on `CanvasUndo.undoMenuItemTitle`. **Disable experiment:** swap `mutateFromInspector` for `mutate` with an "Edit Scrap" gesture open and the step is folded into the writer's, which is the census's own repro made executable.
- **Census:** `store.liveCanvas` together with `isAttached` appears exactly once in production, with a planted-offender companion.
- If the drag route ships, its `.draggable` on the row joins the wiring census — **count that array.**

- [ ] **Step 1:** Tests for the store sibling. Run; confirm failure.
- [ ] **Step 2:** The sibling, over the palette one's ordering.
- [ ] **Step 3:** The two UI routes; the prefixed payload in Task 10's router; the widened placement rule.
- [ ] **Step 4:** `./gen.sh` before quoting any count — a new test file's absence is nearly silent (global constraints), and confirm the new suite's name appears in the log.
- [ ] **Step 5:** Full Mac suite plus the three census files plus tripwire 32's array, counted.
- [ ] **Step 6:** Commit — `feat(canvas): a capture reaches the canvas in one act`.

---

## Task 12a: A region that holds a picture promotes with it

**Spec:** §6's 2026-07-29 amendment, quoted rather than re-derived: *"A region produces a research note. … The palette card **stays** on the row, and its case gets stronger rather than weaker in 1C-d: a palette card is worth making from a region that holds an image, which the canvas cannot hold until then. Today it makes a card of joined prose with no swatches and no images, which is why it could not be the only option."*

**Files:** Modify `Maugham/Canvas/Promotion.swift:812-845` (the region arm and `PromotionPlan.picture`), `Maugham/Canvas/PromotionPerformer.swift`, `Maugham/Canvas/PromotionSheet.swift` (the preview sentence), `Maugham/Views/ProjectWindow.swift:1891+` (`CanvasPromotionModifier`, if the request gains an index). Test: `MaughamTests/Canvas/PromotionTests.swift` and its peers, `PromotionContributionTests.swift`.

**Interfaces — consumes:** `PromotedPicture { node; assetPath; paletteCardID }` and `PromotionPlan.picture` (`Promotion.swift:546`); `Promotion.regionBodies` (`:1033`, home members in reading order); `ProjectStore.addImage(toPaletteCard:fileURL:)` (`ProjectStore+Palette.swift:153`) — **already reached from `PromotionPerformer`** by Task 8's picture rows; `CanvasItemIndex.Entry.thumbnailPath` (`CanvasItemFacts.swift:197`), built at `ProjectWindow.swift:908`.

**Requirements**

- **The PALETTE CARD row only.** The amendment's sentence is about the palette card; a region's research **note** is prose and gains nothing here.
- **`picture` is singular and a region can hold several.** `PromotionPlan.picture` is `PromotedPicture?` with no memberwise default, on purpose (`Promotion.swift:538-546`). Widening is this task's decision and it must be **one field, not two** — two fields for one fact is the smear this file spends its length refusing. Recommendation: `pictures: [PromotedPicture]`, the four rows with none carrying `[]`, and `PromotionPerformer.validate`'s "refuses a picture row that arrives without one" becoming "refuses one that arrives empty". Note that `PromotionFailure.nothingToCopy` reads *"There is no picture on this card"* (`PromotionPerformer.swift:149`) and a region is not a card.
- **Home members only, in `regionBodies`' reading order.** A visitor is not luggage (§4.3), and that is already this file's rule for the words.
- **Both provenances, and the referenced one costs one argument.** An **owned** picture must be carried — it exists nowhere else. A **referenced** image resolves to a file through `CanvasItemIndex.Entry.thumbnailPath`, which `Promotion.plan` is not handed today (it takes `ArtifactIndex` — titles and kinds, deliberately no paths, `CanvasItemFacts.swift:174-182`). The index is already built in `ProjectWindow` at `:908`, in the same file as `CanvasPromotionModifier` (`:1891`), so handing it to the request is one argument rather than a new construction site. If that turns out not to hold when you read it, ship owned-only and record the referenced case as a stated gap with the one line that would close it — do not fork a second path index.
- **RULED 2026-07-31 by Denver — a picture reports its promotion exactly as a text scrap does.** *("they should report their promotion in the same way as the text scraps.")* Spec §6.3 now carries the amendment; **quote it, do not re-derive it, and do not ship this as a default with a flag** — it is a ruling now. The reasoning below is kept because it is why the question had to be asked.
- **The original framing, for context —** §6.3 defines the record over *"exactly the members whose text went in"*, which is `regionBodies`, which reads the scrap table and cannot see a picture; and Task 8's fix round made the record's clear skip item nodes on the predicate `CanvasNodeKind.isScrap`. So a picture that went into the palette card, on today's rules, records **nothing** — and its card says *"Not promoted yet"* while its picture is in the artifact, which is word for word the smoke report §6.3 was written to answer (*"not all the scraps know they were promoted, some think they weren't"*). **The record covers any home member whose CONTENT went in, words or picture** — §6.3's subject is *this card's stuff is in that artifact*, and a picture is stuff. Ruled, not defaulted. Everything else in §6.3 is unchanged and binding: `contributedToItemID` and never the mark, no route into `existingArtifact`, recorded at promotion time, neither drawn nor announced.
- **The preview says what will be copied.** §6.1 requires the writer see what will be produced *and where*; a sheet that names joined prose while silently copying three photographs fails that on its own terms.
- **One gesture, one bracket, one undo step** — §6.3's rule, unchanged, and `PromotionPerformer` already satisfies it. Do not open a second bracket for the pictures.

**The failure it must not have:** a picture appended to a palette card **replacing** that card's existing images. That is the 1C-c2 Critical's exact shape — a mark that resolved for the wrong target and rewrote a card's backing file — and `addImage` appending is the thing to assert rather than assume.

**Tests that must exist**

- A region holding one owned picture and two text scraps promotes to a palette card carrying the joined prose **and** the picture.
- Two pictures land in `regionBodies`' reading order, both of them.
- The card's **existing** images, swatches and sensory notes are undisturbed. This is the Critical's assertion and it is not optional.
- A **referenced** image in the region lands too, or the stated gap is recorded and the test asserts the recorded behaviour rather than nothing.
- The contributing picture node carries the contribution record and **not** `promotedItemID` — §6.3's load-bearing distinction, and the failure it prevents is a re-promotion offering to rewrite a six-card note with one card's content.
- **Control:** a region with no picture in it promotes exactly as it does today. Without this the whole task could be passing by making every region promotion different.
- **Disable experiment:** drop the pictures from the region arm's plan and the picture assertions go red while the prose control stays green.

- [ ] **Step 1:** Tests. Run; confirm failure.
- [ ] **Step 2:** Widen the plan's picture field and the region arm; fix every arm the compiler names.
- [ ] **Step 3:** The performer's write; the sheet's sentence.
- [ ] **Step 4:** The contribution predicate, with the FOR DENVER note in the report.
- [ ] **Step 5:** Full Canvas suite plus the promotion suites; `PromotionCommandTests` — count that array.
- [ ] **Step 6:** Commit — `feat(canvas): a region promotes with the pictures in it`.

---

## Task 13: `⌘\` collapses to the canvas

**Spec:** §8A.3. **Files:** Modify `Maugham/Views/ProjectWindow.swift` (`:93` the split view, a new `ViewModifier`, the stash predicate at `:1664`). `MaughamApp.swift:189-192` is **unchanged** — the key is reused. Test: `MaughamTests/Views/CanvasPersonaTests.swift` or a peer; `MaughamTests/Canvas/PromotionCommandTests.swift` (the wiring census).

**Interfaces — consumes:** `.maughamToggleNoChrome` posted to `.keyWindow` (`MaughamApp.swift:190`) and received at `FocusPostureModifier` (`ProjectWindow.swift:1568`); `showInspector` (`:45`) and the `if showInspector` gate on the detail column (`:971-976`); `PersonaModifier.clearsPaletteStash(from:to:)` (`:1664`); `InspectorRoute` (`:996`) as the established "is the canvas showing" decision.

**The finding that reshapes this task.** **The canvas is the CONTENT column, not the detail column** — `CanvasView(` is inside `contentColumn` (`:758`–`:970`) at `:906`. So "collapse both side columns" means hide the **sidebar** and hide the **detail**, with the canvas — the middle column — left. `NavigationSplitViewVisibility.detailOnly` looks like the value that does this and **hides the canvas itself**; the value wanted is `.doubleColumn` (sidebar hidden, content and detail shown) *together with* `showInspector == false`, which already renders the detail column empty. That is the whole mechanism and it is worth two sentences here because it is one wrong enum case away from shipping a canvas that disappears when the writer asks to see more of it.

**Requirements**

- **The same key, the same event, no second subscription.** `⌘\` already posts `.maughamToggleNoChrome` to `.keyWindow` and `FocusPostureModifier` already receives it. Adding a second `.onKeyWindowCommand` for the same name in the same window is tripwire 21's territory; extend the existing handler's effect instead.
- **Only when the centre is the canvas.** `⌘\` in the editor must behave exactly as it does today — `applyNoChrome()` touches the titlebar and the three standard buttons and **no column** (`:1290-1297`). Reuse the predicate `InspectorRoute` already encodes (`:996`, with its own doc comment about the canvas check sitting *above* the project-type split, because leaving it below is what let two paths disagree and shipped a smoke-found bug). Do not spell a second "is the canvas showing" test.
- **Never automatic on entering the persona** (§8A.3, in those words). The palette wall's `PaletteSegmentModifier` *does* auto-hide the inspector on entry and the canvas deliberately does not follow it, because you need the binder open to drag research in — which Task 10 has now made true rather than prospective.
- **A collapse that stashes state inherits `clearsPaletteStash`'s exact ordering hazard.** `PaletteSegmentModifier`'s `.onChange(of: binderSegment)` (`:469-478`) fires in a *later* update pass and would restore `inspectorWasVisibleBeforePalette` over a force-close; `clearsPaletteStash` (`:1664`) exists solely to drop that stash first. **Extend the predicate, never defer a pass** — tripwire 2 is precisely that a flag cleared synchronously has already leaked by the time `.onChange` runs, and it killed cursor↔binder sync in 3d.
- **No new expression in `ProjectWindow.body`.** One `.modifier(…)` line, joining the eleven at `:166, :259, :276, :284, :287, :293, :317, :321, :326, :331, :338`. The chain is at the SwiftUI type-checker ceiling and three sibling modifiers exist because inlining broke the Release build (`:1585-1587`). **Run a local Release build before committing** — CLAUDE.md's rule, and this task edits that chain.
- **Say what happens when the writer leaves the canvas collapsed.** A hidden binder in the editor with no visible way back is worse than the thing this feature fixes. Recommendation: release the collapse when the centre stops being the canvas, in the same pass that clears the stash — the `clearsPaletteStash` shape, which exists for this class of ordering.

**The failure it must not have:** a stashed column visibility restored over the collapse by a later update pass — tripwire 2's exact shape.

**Tests that must exist**

- **The decision is a pure function** over `(is the centre the canvas, isNoChromeOn, the prior visibility)` → `(NavigationSplitViewVisibility, showInspector)`, tested **exhaustively over the product**. This window's two routing bugs were both found by making the decision pure and testing the product rather than the one path a plan named; `InspectorRoute`/`CanvasPersonaTests` is the precedent and its doc comment says why (`:979-996`).
- The collapsed value is asserted **by case**, not as "not `.all`" — `.detailOnly` is the trap and only an equality assertion catches it.
- `⌘\` **off** the canvas leaves the split view at `.all` and `showInspector` untouched. The control, and without it every assertion above is satisfied by a modifier that fires everywhere.
- The stash survives the sequence that broke the palette: collapse on the canvas → switch persona → switch back. **Disable experiment:** remove the predicate extension and this goes red while the plain collapse stays green.
- **Wiring census:** the `.modifier(…)` mount line joins `PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite`, which names `ProjectWindow.swift` for **six** tokens today — **count the array**, and note the census's own recorded reason: a modifier's subscription lives inside its struct body in the same file, so deleting the mount line leaves every token present and every test green while the feature is unreachable from the real window. That has happened twice.

- [ ] **Step 1:** The pure function and its exhaustive test. Run; confirm failure.
- [ ] **Step 2:** The `columnVisibility:` binding on the split view and the modifier that drives it.
- [ ] **Step 3:** Extend the stash predicate; test the persona round trip.
- [ ] **Step 4:** Full Mac suite; the three census files; **Release build**.
- [ ] **Step 5:** Commit — `feat(canvas): ⌘\ gives the canvas the window`.

---

## Task 14: The sweep, and the whole-branch review

**Files:** `Maugham/Canvas/AREA.md`, `Maugham/MCP/AREA.md`, `docs/adr/0026-planning-canvas-rendering.md`, `docs/roadmap.md`, `docs/guide/getting-started.md`, `CLAUDE.md`, plus any source doc comment the sweep finds false. Docs move in the **same commit** as the behaviour where that is still possible, and this task is what catches what did not (CLAUDE.md rule 10).

**The ledger is this task's input and nothing else holds these.** Every line below was carried forward by a task or a review and has a named origin.

**Owed because the behaviour finally exists**

- **A guide entry for the whole of 1C-d.** Task 8 deliberately wrote none — the promotion row it built could not be described, because nothing in production minted an owned node until tasks 11 and 12. It can now: dragging research in, dropping a photo, sending a capture, promoting a picture, and `⌘\`.
- **`docs/guide/getting-started.md:111` is stale, verified 2026-07-31**: *"For now the page shows as a placeholder card carrying its reference — the picture itself arrives with the rest of the image work."* Task 5 falsified it.
- **ADR 0026 §10 and `docs/roadmap.md` still say §8A.2's reproduction corollary is visible "at 1C-d" in the FUTURE tense** *(Task 5's carry).* `Maugham/Canvas/AREA.md` was swept in that task and is **not** drift — do not re-sweep it for this.
- **`Maugham/Canvas/AREA.md:664-668`, "What the canvas does not do yet"**, loses its 1C-d bullet. Follow the file's own convention: the closed item is *rewritten as what shipped* rather than deleted, the way regions, lines, delete, appearances and the MCP surface each were.
- **`docs/roadmap.md:65` flips • → ✓** with its entry, and the sibling docs are swept in the same commit (rule 10).
- **CLAUDE.md's Canvas row** gains the two provenances, `canvas_assets/`, the four routes onto the canvas and `⌘\`; and its `list_canvas` sentence in the MCP row gains Decision A's field. **The tool count does not change** — `Maugham/MCP/AREA.md` has three prose occurrences of it that `DocSyncTests` cannot see, so check them and leave them at 54.

**Open for Denver, asked and not edited on a review finding**

- **`CLAUDE.md:116` says "the inspector's three arms" and "a scrap, region or line".** It is four arms, five posting sites and a fourth table row *(Task 8's I1; the implementer declined to touch CLAUDE.md on a review finding and asked directly).* Put it to him; do not decide it here.
- **Task 5's M5 — glyph ink versus title — is FOR DENVER AT SMOKE.** Carry it to the smoke list, not into a fix.
- **Task 7's smoke note:** the item arm's heading reads **"Reference"** for both provenances, because that is what VoiceOver already says for both (`CanvasAccessibility.itemKind`). It reads slightly oddly over an owned picture, and it is one constant.

**Prose that is false, each with its origin**

- **`Promotion.swift`'s `PromotionSource.noun` comment says `PromotedArtifactSection.Subject` "covers only the two subjects that have a PANE".** All three have panes; what `Subject` covers is the two that have that **section** *(Task 7, found and CONFIRMED twice in the ledger).* One word wide, and it is the false-**reason** class — the class that is worse than a stale count, because a reason is what the next implementer acts on.
- **`Maugham/Canvas/AREA.md` describes the thumbnail schedule two ways**, one of them two fix-rounds stale at `:61`, and `:78` still quotes the **deleted** `hashValue` caveat *(Task 5's D3).*
- **Two prose figures in `AREA.md` quote one run of a process-seeded ordering** *(Task 5's D5).* The assertion message is correctly general; only the prose is over-specific.
- **ADR 0026's new pointer sentence answers a different question than the one it replaced** *(Task 8's N1).*
- **Stray double blank line at `CanvasView.swift:264-265`** *(Task 5's D4)* — and note that file has **five source-layout contracts** documented in its own header, one of which *crashes* the test rather than failing it. Read the header before touching whitespace there.
- Task 5's remaining open Minors — **M3, M6, M7, M8, M9, D2** — are triaged here, each done or dropped on merit. There is no defer bucket (`memory/feedback_no_defer_bucket.md`).

**Counts, which are counted and never recited**

- **Tripwire 32's census array** — five entries at the start of this slice. Task 8 confirmed it unchanged; Task 12 may change it. `Maugham/Canvas/AREA.md:611` describes `CanvasClaudeWrite.swift` **by name**, so a rename lands there too.
- **`PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite`** — five files, twelve tokens, six of them `ProjectWindow`'s. Tasks 10, 12 and 13 each add one. **Count the array, not `AREA.md:656`'s sentence about it.**
- Any calibration figure quoted in `Maugham/Canvas/AREA.md` uses the `` `constant` (value) `` notation or `DocSyncTests` cannot see it.

**Then the whole-branch review.**

- **It gets the ledger as a first-class input beside the diff**, pointed at the *seams*. It has found a Critical or a cross-surface contradiction in **every one of six slices**, in files no task's diff contained — most recently a resize that deleted the page card permanently.
- **Name the seams for it**: the drop router's three payload spaces (research id, inbox id, external file); `ingestCanvasAsset`'s two twins and their caller counts; the `isAttached` discriminator's single-writer rule; the contribution predicate that Task 12a widened; the column-visibility stash against the palette's.
- **Every reviewer writes its verdict to a file BEFORE replying.** Two reviewers went idle without reporting last slice and one 21 KB verdict was recovered only because the file existed.
- **Read the tree after any interrupted subagent** (`memory/feedback_whole_branch_review_earns_it.md`).

- [ ] **Step 1:** The behaviour-owed docs — guide, `getting-started.md:111`, roadmap, AREA.md's "does not do yet", CLAUDE.md's rows.
- [ ] **Step 2:** The false-prose list above, each verified in source first-hand rather than taken from this plan.
- [ ] **Step 3:** Every count re-counted from its array.
- [ ] **Step 4:** Denver's three items put to him, unedited.
- [ ] **Step 5:** Full Mac suite **and** the phone suite; `./gen.sh` first; Release build.
- [ ] **Step 6:** Commit — `docs(canvas): 1C-d, swept`.
- [ ] **Step 7:** The whole-branch review, then the smoke.

---

## Self-review against the spec

| Spec | Task |
|---|---|
| §3.1 amendment — two provenances, owned by path | 1 |
| §8 — owned captures in an assets folder beside the scraps file | 2 |
| §8A.1 — images, `CGImageSource` thumbnail, path-keyed bounded cache | 3 |
| §8A.1 — real title, kind glyph, thumbnail | 4, 5 |
| §8A.2 corollary — visible at 1C-d, and enlargeable enough to check against | 5, 6 |
| §7A.3 — width authoritative, height derived — extended to an image | 6 |
| ADR 0026 §10 — item-node inspector arm | 7 |
| §6 amendment — an owned node promotes; a referenced one does not | 8 |
| §8A.1 — drop target, internal research drag | 10 |
| §8A.1 — `DropClassification` for browser drags | 11 |
| §8A.2 amendment — `list_canvas` reports what an owned card *is* (Decision A) | 11 |
| §8A.4 + amendment — inbox → canvas, all three kinds, drag and command | 12 |
| §6's 2026-07-29 amendment — the region row's palette card carries its pictures (Decision B) | 12a |
| §8A.3 — `⌘\` collapses both columns | 13 |
| CLAUDE.md rule 10 — sibling docs in the same commit | 14 |
| §6.1 — the writer sees what will be produced, *and where* (the picture rows' preview) | 12a |
| §4.2 / tripwire 31 — a drop is a legitimate geometric reading and the only one | 10 |

**Known gaps, stated rather than hidden.**

- **Tasks 10–14 were derived on 2026-07-31 against the built code, and Task 9 is closed.** Every signature they quote was read out of the tree at the line given on that date, and the table above them carries the ones this plan's header table did not. Two things moved in the derivation and are called out here rather than left in the diff: **`list_canvas` gains one optional provenance field** (Decision A, shipped in Task 11) and **the region-with-an-image gap became Task 12a** (Decision B) rather than a recorded ruling.
- **This plan now runs 15 tasks**, over CLAUDE.md rule 12's ~10 cap and one further over than it was. Recorded rather than fixed by pretending: the milestone is not usable in halves, Task 9 is the mitigation the cap exists to buy, and Task 12a is a spec ruling this slice would otherwise ship the stated weakness of. It is deliberately scoped so a reviewer could reject it while approving its neighbours.
- **One question inside Task 12a is the writer's, not the plan's.** Extending §6.3's contribution record from *words that went in* to *a picture that went in* is an extension of Denver's own post-smoke ruling. Task 12a ships a stated default and flags it rather than blocking; it is one predicate to overturn.
- **Task 11 leaves a caller count to be settled rather than settling it here.** `ProjectStore.ingestCanvasAsset(image:)` ends the milestone unreachable if the browser-bitmap branch takes the temp-file route. The task names the count, the two acceptable answers and the four hand-rolled `NSImage`-from-provider spellings the shared answer would retire; it does not pick, because the pick wants the file open.
- **The overlapping-banner problem is not fixed here.** Three `.overlay(alignment: .top)` transient banners already share the window and two on screen at once draw over each other; the honest fix is one banner host for the window, which is its own slice. **Two tasks can now reach for a fourth** — Task 11's failed-ingest report and Task 12's "the writer is told, and told where" — and both are required to say so out loud rather than quietly adding one. Task 11's nearest precedent is an alert; Task 12's is `CanvasClaudeArrivalModifier`'s existing host.
- **Claude still cannot see an owned picture's pixels**, and that is Decision A's deliberate edge. The missing piece is an image response keyed on a canvas node id — a new read tool and a new response shape. Recorded so the next author meets a decision rather than a gap, exactly as spec §8A.4's last paragraph does for `read_inbox_entry`.
- **`CanvasInteraction.regionHit` is still the next projection to lift** onto `CanvasScene`, and until it moves `CanvasScene` cannot go to MaughamCore. Not this slice's, and not made worse by it.
