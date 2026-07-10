# Palette Card Visual Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the raw-markdown palette-card editing flow with a visual card editor (colour picker + eyedropper swatches, drag/paste image well, sense-chip note entry, freeform body field) per the spec's 2026-07-10 "Card editor revision" — the model owns the file; Maugham regenerates the markdown on every edit.

**Architecture:** `PaletteCard` gains a freeform `body`; `PaletteCardRenderer` becomes the parser's exact inverse (canonical markdown, total round-trip by construction). The store gains `updatePaletteCard` (regenerate; title renames via the typed `updateResearchItem` mover, which already migrates `<slug>_assets/`) and image-add APIs reusing `ImagePasteHandler`'s existing `_assets` convention. `PaletteCardEditor` replaces the `ResearchNoteEditor` mount in `ProjectWindow`'s `.palette` arm. Wall, ⌘⌥7 pane (plus body display), MCP tools, storage location: unchanged.

**Tech Stack:** Swift/SwiftUI + AppKit (`NSColorSampler`, `NSImage`), Mac target only. macOS 14.0 deployment target (clears `.dropDestination` 13+ and `NSColorSampler` 12+ — verified in project.yml).

## Global Constraints

- Same branch: `feat/craft-intent-sensory-palette`. No MaughamCore/MaughamPhone changes; nothing committed under `Maugham.xcodeproj/`; `./gen.sh` after adding files.
- **Model owns the file:** external hand-edits are unsupported; parse-then-regenerate normalizes to canonical form; unknown sections are dropped (user decision 2026-07-10).
- **Canonical card markdown** (renderer output, parser input): `# Title` · blank · `kind: <kind>` · blank · body paragraphs (omitted when empty) · `## Swatches` / `## Senses` / `## Images` sections always present, list items only. Image list items are card-relative with `./` prefix (e.g. `- ./the-flat_assets/image-20260710-101500.png`) so `renameResearchPath`'s `./<oldSlug>_assets/` ref rewriting keeps working.
- Card images live in the card's sibling `<slug>_assets/` folder via `ImagePasteHandler`-style writes (create-only; tripwire 14 untouched). Title renames MUST go through `updateResearchItem(id:title:)` (typed mover; migrates `_assets`, rewrites refs).
- Tripwires: 4 (no I/O in row bodies), 9 (`Button(.plain)`), 15 (ContentUnavailableView framing) in any new view code; adr-0018-ok on raw reads.
- Tests: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (focused classes while iterating); FULL suite + **Release build** at the end (ProjectWindow changes again).
- Model hints: opus = Tasks A, B, C; sonnet = Task D; Task E controller-run.
- Key explored facts (2026-07-10 report): `ImagePasteHandler.saveAndReference(image:forNoteAt:in:) throws -> String` returns `![](./<slug>_assets/image-YYYYMMDD-HHMMSS.png)`; `updateResearchItem(id:title:caption:tags:url:)` at `ProjectStore+Research.swift:593`; current `.palette` editor arm at `ProjectWindow.swift:834-857`; drop idiom `.dropDestination(for: URL.self)` (ResearchView:51), paste idiom `.onPasteCommand(of: ["public.image", ...])` + `NSItemProvider`→`NSImage` (ResearchView:244-303); no existing ColorPicker/NSColorSampler use in the codebase.

---

### Task A: PaletteCard `body` + PaletteCardRenderer (total round-trip)

**Files:**
- Modify: `Maugham/Models/PaletteCard.swift`
- Test: `MaughamTests/PaletteCardParserTests.swift` (extend), `MaughamTests/PaletteCardRendererTests.swift` (new)

**Interfaces:**
- Consumes: existing `PaletteCard`/`PaletteCardParser`.
- Produces: `PaletteCard.body: String` (new stored field, default `""`; keep the memberwise init source-compatible by giving `body` a default parameter value); `PaletteCardRenderer.render(_ card: PaletteCard, cardDirectory: String) -> String`; `PaletteCardRenderer.relativize(_ projectRelativePath: String, from cardDirectory: String) -> String` (inverse of the parser's `resolve`).

**Behavior:**
- Parser change: while `section == .none` (after title/kind handling, before any `##`), non-blank lines that aren't the title line or the `kind:` line accumulate into `body` (joined with `\n`, consecutive blank lines collapsed to paragraph breaks `\n\n`, trimmed). Lines inside `.unknown` sections stay dropped.
- Renderer emits the canonical form from Global Constraints. Swatches uppercase-normalized (`#8a6f4d` → `#8A6F4D` — parse accepts either; render canonicalizes). Sense notes render as `- <sense>: <text>` / `- <text>`. Images render as `- <relativized>` where `relativize` produces `./x` for paths under `cardDirectory`, else `../`-climbing paths.
- Round-trip law (THE test): for any model built from editor-reachable values, `parse(render(card)) == card` (with `researchItemId`/`fallbackTitle` supplied to parse).

- [ ] **Step 1: Write failing tests**

```swift
// MaughamTests/PaletteCardRendererTests.swift
import XCTest
@testable import Maugham

final class PaletteCardRendererTests: XCTestCase {
    private func roundTrip(_ card: PaletteCard, dir: String = "research/palette") -> PaletteCard {
        let md = PaletteCardRenderer.render(card, cardDirectory: dir)
        return PaletteCardParser.parse(
            markdown: md, itemId: card.researchItemId,
            fallbackTitle: "fallback", cardDirectory: dir)
    }

    func test_roundTrip_fullCard() {
        let card = PaletteCard(
            researchItemId: "res-1", title: "The Flat", kind: .location,
            swatches: ["#8A6F4D", "#2F3B4C"],
            notes: [.init(sense: .smell, text: "turpentine"),
                    .init(sense: nil, text: "cold quarry tile")],
            imagePaths: ["research/palette/the-flat_assets/image-1.png",
                         "research/paris.jpg"],
            body: "Third-floor walk-up.\n\nThe light goes green before rain.")
        XCTAssertEqual(roundTrip(card), card)
    }

    func test_roundTrip_emptyEverything() {
        let card = PaletteCard(researchItemId: "res-2", title: "Bare", kind: .other,
                               swatches: [], notes: [], imagePaths: [], body: "")
        XCTAssertEqual(roundTrip(card), card)
    }

    func test_render_imagePathsAreCardRelativeWithDotSlash() {
        let card = PaletteCard(researchItemId: "res-3", title: "X", kind: .motif,
                               swatches: [], notes: [],
                               imagePaths: ["research/palette/x_assets/a.png"], body: "")
        let md = PaletteCardRenderer.render(card, cardDirectory: "research/palette")
        XCTAssertTrue(md.contains("- ./x_assets/a.png"))
        XCTAssertFalse(md.contains("research/palette/x_assets"))
    }

    func test_render_normalizesSwatchCase() {
        let card = PaletteCard(researchItemId: "res-4", title: "X", kind: .other,
                               swatches: ["#8a6f4d"], notes: [], imagePaths: [], body: "")
        XCTAssertTrue(PaletteCardRenderer.render(card, cardDirectory: "research/palette")
            .contains("- #8A6F4D"))
    }

    func test_relativize() {
        XCTAssertEqual(PaletteCardRenderer.relativize(
            "research/palette/x_assets/a.png", from: "research/palette"), "./x_assets/a.png")
        XCTAssertEqual(PaletteCardRenderer.relativize(
            "research/paris.jpg", from: "research/palette"), "../paris.jpg")
    }
}
```

Extend `PaletteCardParserTests` with body capture:

```swift
func test_parse_capturesFreeformBodyBeforeSections() {
    let md = """
    # The Flat

    kind: location

    Third-floor walk-up.

    The light goes green before rain.

    ## Swatches

    - #8A6F4D
    """
    let card = PaletteCardParser.parse(
        markdown: md, itemId: "res-b", fallbackTitle: "x",
        cardDirectory: "research/palette")
    XCTAssertEqual(card.body, "Third-floor walk-up.\n\nThe light goes green before rain.")
    XCTAssertEqual(card.swatches, ["#8A6F4D"])
}

func test_parse_noBody_isEmptyString() {
    let md = PaletteCardParser.template(title: "T", kind: .other)
    XCTAssertEqual(PaletteCardParser.parse(
        markdown: md, itemId: "res-c", fallbackTitle: "x",
        cardDirectory: "research/palette").body, "")
}
```

- [ ] **Step 2: Run to verify red** (`-only-testing:MaughamTests/PaletteCardRendererTests -only-testing:MaughamTests/PaletteCardParserTests` — compile failure on `body`/renderer = expected red)
- [ ] **Step 3: Implement** — add `body` to the struct (default `""` in init); parser body-accumulation per Behavior; new `PaletteCardRenderer` enum in the same file (it's the parser's inverse; keeping them together makes drift visible):

```swift
public enum PaletteCardRenderer {
    public static func render(_ card: PaletteCard, cardDirectory: String) -> String {
        var out = "# \(card.title)\n\nkind: \(card.kind.rawValue)\n"
        if !card.body.isEmpty { out += "\n\(card.body)\n" }
        out += "\n## Swatches\n\n"
        for s in card.swatches { out += "- \(s.uppercased())\n" }
        out += "\n## Senses\n\n"
        for n in card.notes {
            out += n.sense.map { "- \($0.rawValue): \(n.text)\n" } ?? "- \(n.text)\n"
        }
        out += "\n## Images\n\n"
        for p in card.imagePaths { out += "- \(relativize(p, from: cardDirectory))\n" }
        return out
    }

    public static func relativize(_ path: String, from directory: String) -> String {
        let dirParts = directory.split(separator: "/").map(String.init)
        let pathParts = path.split(separator: "/").map(String.init)
        var common = 0
        while common < dirParts.count && common < pathParts.count - 1
                && dirParts[common] == pathParts[common] { common += 1 }
        let climbs = dirParts.count - common
        let rest = pathParts[common...].joined(separator: "/")
        return climbs == 0 ? "./\(rest)"
            : String(repeating: "../", count: climbs) + rest
    }
}
```

Note the round-trip subtlety the tests pin: parse uppercases nothing, so the model must hold uppercase swatches for equality — the EDITOR (Task C) always produces uppercase via the hex formatter, and render normalizes defensively. Blank-line collapsing in body capture must match what render emits (`\n\n` between paragraphs).

- [ ] **Step 4: Run green** (both classes + existing parser tests unchanged)
- [ ] **Step 5: Commit** `feat(palette): freeform body + PaletteCardRenderer — total round-trip`

---

### Task B: Store — updatePaletteCard + image add

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Palette.swift`
- Test: `MaughamTests/ProjectStorePaletteTests.swift` (extend)

**Interfaces:**
- Consumes: `PaletteCardRenderer` (Task A); `updateResearchItem(id:title:...)` (`ProjectStore+Research.swift:593`, typed-mover rename + `_assets` migration); `ImagePasteHandler.saveAndReference(image:forNoteAt:in:)`; `PaletteCardParser`.
- Produces (on `ProjectStore`):
  - `func updatePaletteCard(_ card: PaletteCard) async throws` — persists the model: if `card.title` differs from the manifest item's title, first `updateResearchItem(id: card.researchItemId, title: card.title)` (file+assets rename; re-fetch the item for its NEW path, and remap `card.imagePaths` prefixes `<oldSlug>_assets/` → `<newSlug>_assets/` derived from old/new paths), then write `PaletteCardRenderer.render(remappedCard, cardDirectory:)` to the (possibly new) path, then `manifest.modified = Date()` + `saveManifest()` (drives `.task(id:)` reloads).
  - `@discardableResult func addImage(toPaletteCard cardId: String, image: NSImage) async throws -> PaletteCard` — `ImagePasteHandler.saveAndReference` into the card's `_assets`, parse the returned `![](./…)` ref's path, resolve to project-relative, append to the model, `updatePaletteCard`.
  - `@discardableResult func addImage(toPaletteCard cardId: String, fileURL: URL) async throws -> PaletteCard` — copy the file (preserving extension, timestamp-named like ImagePasteHandler) into `_assets/`, append, `updatePaletteCard`. (A small file-URL sibling of `saveAndReference` — implement locally in this seam or extend ImagePasteHandler with a `saveAndReferenceFile` twin; prefer extending ImagePasteHandler so naming/dedupe logic stays in one place.)
- Throws on unknown cardId (`ProjectStoreError`-family, match the seam's existing error style).

- [ ] **Step 1: Failing tests** (extend `ProjectStorePaletteTests`; reuse `makeNovel()`):

```swift
func test_updatePaletteCard_regeneratesCanonicalFile() async throws {
    let (url, store, ds) = try await makeNovel()
    let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
    var card = store.loadPaletteCards()[0]
    card = PaletteCard(researchItemId: card.researchItemId, title: card.title,
                       kind: .location, swatches: ["#8A6F4D"],
                       notes: [.init(sense: .smell, text: "turpentine")],
                       imagePaths: [], body: "Walk-up.")
    try await store.updatePaletteCard(card)
    let reloaded = store.loadPaletteCards()[0]
    XCTAssertEqual(reloaded, card)
    let onDisk = try String(contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
    XCTAssertTrue(onDisk.contains("- smell: turpentine"))
    await ds.close()
}

func test_updatePaletteCard_titleRename_movesFileAndAssets() async throws {
    let (url, store, ds) = try await makeNovel()
    _ = try await store.addPaletteCard(title: "Old Name", kind: .character)
    var card = store.loadPaletteCards()[0]
    // seed an asset image first, so the rename must carry it
    let png = makePNGData(width: 40, height: 40)
    let tmp = url.appendingPathComponent("tmp.png"); try png.write(to: tmp)
    card = try await store.addImage(toPaletteCard: card.researchItemId, fileURL: tmp)
    XCTAssertTrue(card.imagePaths[0].contains("old-name_assets/"))

    let renamed = PaletteCard(researchItemId: card.researchItemId, title: "New Name",
                              kind: card.kind, swatches: card.swatches,
                              notes: card.notes, imagePaths: card.imagePaths, body: card.body)
    try await store.updatePaletteCard(renamed)
    let reloaded = store.loadPaletteCards()[0]
    XCTAssertEqual(reloaded.title, "New Name")
    XCTAssertTrue(reloaded.imagePaths[0].contains("new-name_assets/"))
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: url.appendingPathComponent(reloaded.imagePaths[0]).path))
    await ds.close()
}

func test_addImage_nsimage_landsInAssetsAndModel() async throws {
    let (url, store, ds) = try await makeNovel()
    _ = try await store.addPaletteCard(title: "Pics", kind: .motif)
    let cardId = store.loadPaletteCards()[0].researchItemId
    let image = NSImage(size: NSSize(width: 30, height: 30))
    let card = try await store.addImage(toPaletteCard: cardId, image: image)
    XCTAssertEqual(card.imagePaths.count, 1)
    XCTAssertTrue(card.imagePaths[0].hasPrefix("research/palette/pics_assets/"))
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: url.appendingPathComponent(card.imagePaths[0]).path))
    XCTAssertEqual(store.loadPaletteCards()[0], card)   // persisted
    await ds.close()
}

func test_updatePaletteCard_unknownId_throws() async throws {
    let (_, store, ds) = try await makeNovel()
    let ghost = PaletteCard(researchItemId: "res-ghost", title: "G", kind: .other,
                            swatches: [], notes: [], imagePaths: [], body: "")
    do { try await store.updatePaletteCard(ghost); XCTFail("expected throw") } catch {}
    await ds.close()
}
```

(`makePNGData` — add a tiny local helper mirroring PaletteToolsTests' fixture. NSImage with zero reps: ensure `addImage(image:)` locks focus / rasterizes like ImagePasteHandler does — check its PNG encoding path handles a blank NSImage; if it throws on empty reps, draw a fill first in the test.)

- [ ] **Step 2: Red** (compile failure on new members)
- [ ] **Step 3: Implement** per Interfaces. Sequencing in `updatePaletteCard` on rename: (1) capture old item path/slug; (2) `updateResearchItem(id:title:)`; (3) re-fetch item by id for new path; (4) remap `imagePaths` occurrences of `"<oldSlug>_assets/"` → `"<newSlug>_assets/"`; (5) render with `cardDirectory = (newPath as NSString).deletingLastPathComponent`; (6) write (plain `String.write` — creation-style content write, same as addPaletteCard); (7) `manifest.modified = Date()`; `try await saveManifest()`. Non-rename path skips 1–4. Raw read sites keep `// adr-0018-ok:` annotations.
- [ ] **Step 4: Green** (`ProjectStorePaletteTests` + `TripwireGrepTests` — the mover tripwire must stay clean: file copy into `_assets` is a create, use `FileManager.copyItem` ONLY via ImagePasteHandler-style helper file if the tripwire's patterns flag it — check `userContentMoverPatterns` = `.moveItem(`/`.moveToTrash(` only, so `copyItem` is fine)
- [ ] **Step 5: Commit** `feat(palette): updatePaletteCard + image-add store APIs — model owns the file`

---

### Task C: PaletteCardEditor view (replaces raw-markdown editing)

**Files:**
- Create: `Maugham/Views/Palette/PaletteCardEditor.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (`.palette` arm: swap `ResearchNoteEditor` mount for `PaletteCardEditor`)
- Test: `MaughamTests/Views/PaletteCardEditorTests.swift` (static helpers)

**Interfaces:**
- Consumes: `store.loadPaletteCards()`, `store.updatePaletteCard(_:)`, `store.addImage(toPaletteCard:image:)`, `store.addImage(toPaletteCard:fileURL:)` (Task B); `PaletteCardTile.kindSymbol(for:)`, `PalettePane.senseSymbol(for:)`; `store.url`.
- Produces: `PaletteCardEditor(store:cardId:)`; `nonisolated static func hexString(r: Double, g: Double, b: Double) -> String` (→ `#RRGGBB`, uppercase, clamped) and `nonisolated static func hexString(from nsColor: NSColor) -> String?` (sRGB-converted; nil if colorspace conversion fails) — the tested surface.

**View structure (one `ScrollView` + `VStack(alignment: .leading, spacing: 16)`, all edits debounced ~500ms into `store.updatePaletteCard`):**
- **Title**: `TextField` bound to a local draft; commit on debounce (rename ride-through per Task B).
- **Kind**: segmented `Picker` over `PaletteCard.Kind.allCases` with `kindSymbol` icons.
- **Swatches**: `HStack` of chips (`RoundedRectangle` + hover ✕ delete, tripwire 9 buttons); a `ColorPicker("", selection: $newSwatchColor, supportsOpacity: false)` whose `.onChange` appends `hexString` of the picked colour; an eyedropper `Button` calling
  ```swift
  NSColorSampler().show { picked in
      guard let picked, let hex = Self.hexString(from: picked) else { return }
      appendSwatch(hex)
  }
  ```
- **Images**: `LazyVGrid` of thumbnails (loaded in `.task(id:)` off the card's imagePaths — tripwire 4; hover ✕ remove = model edit) + a drop/paste target zone:
  ```swift
  .dropDestination(for: URL.self) { urls, _ in
      Task { for u in urls { try? await store.addImage(toPaletteCard: cardId, fileURL: u) } }
      return true
  }
  .onPasteCommand(of: [.image]) { providers in /* NSItemProvider → NSImage → store.addImage(image:) — mirror ResearchView.loadAndImportImage's provider dance */ }
  ```
- **Sensory notes**: rows (sense icon via `senseSymbol` or `ellipsis`, text, ✕ delete); quick-entry `TextField` + six chips (five senses + "untagged") that submit `SensoryNote(sense:text:)` and clear the field.
- **Freeform body**: `TextEditor` bound to a draft, debounced into the model; placeholder-style caption "Anything else about this subject…".
- **Empty/err state**: if `cardId` no longer resolves, `ContentUnavailableView` full-frame (tripwire 15) — the wall back-button remains above it via the existing ProjectWindow chrome.

**State discipline (tripwires 3/6-adjacent):** ONE local `@State private var draft: PaletteCard?` seeded in `.task(id: cardId)`; every control mutates `draft`; a single debounced persist task writes `store.updatePaletteCard(draft)`. Do NOT re-seed the draft from `store.manifest.modified` while this editor is frontmost (our own save would clobber in-flight typing) — re-seed only on `cardId` change. Adds via `store.addImage*` return the updated card: merge its `imagePaths` into `draft` rather than re-seeding wholesale.

**ProjectWindow change:** inside the existing `.palette` arm's `VStack` (back-button chrome stays), replace the `ResearchNoteEditor(...)` mount with `PaletteCardEditor(store: store, cardId: cardId)`. Delete the now-unused `path`/`item` unwrap only if nothing else needs it (keep the `item` lookup for existence check → fall through to wall when card vanished, as today).

- [ ] **Step 1: Failing tests**

```swift
// MaughamTests/Views/PaletteCardEditorTests.swift
import XCTest
@testable import Maugham

final class PaletteCardEditorTests: XCTestCase {
    func test_hexString_fromComponents() {
        XCTAssertEqual(PaletteCardEditor.hexString(r: 1, g: 0, b: 0), "#FF0000")
        XCTAssertEqual(PaletteCardEditor.hexString(r: 0.5411, g: 0.4352, b: 0.3019), "#8A6F4D")
        XCTAssertEqual(PaletteCardEditor.hexString(r: 2, g: -1, b: 0), "#FF0000") // clamped
    }

    func test_hexString_fromNSColor_sRGBConversion() {
        let c = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertNotNil(PaletteCardEditor.hexString(from: c))
        XCTAssertEqual(PaletteCardEditor.hexString(from: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)), "#00FF00")
    }

    func test_hexString_roundTripsThroughParserValidation() {
        let hex = PaletteCardEditor.hexString(r: 0.2, g: 0.4, b: 0.6)
        XCTAssertNotNil(PaletteCard.color(fromHex: hex))
    }
}
```

- [ ] **Step 2: Red** (compile failure)
- [ ] **Step 3: Implement** per structure above. `hexString(r:g:b:)`: clamp to 0...1, `String(format: "#%02X%02X%02X", Int(round(r*255)), …)`. `hexString(from:)`: `nsColor.usingColorSpace(.sRGB)` then components. If `ProjectWindow.body` hits the type-check ceiling again, extract further modifiers (house pattern).
- [ ] **Step 4: Green** (focused class), then FULL Mac suite (ProjectWindow + exhaustive switches ripple)
- [ ] **Step 5: Commit** `feat(palette): visual card editor — swatch picker/eyedropper, image drop/paste, sense chips, freeform body`

---

### Task D: Right-pane body display + docs alignment

**Files:**
- Modify: `Maugham/Views/Palette/PalettePane.swift` (render `card.body` read-only under the note groups)
- Modify: `docs/guide/sense-pass.md` (gather step: wording now describes the visual editor — "drag images in, pick swatches with the colour picker or eyedropper, tag notes by sense"; remove/adjust anything implying markdown editing)
- Modify: `docs/roadmap.md` (the shipped entry gains the visual-editor sentence; drop any raw-markdown-editing phrasing)
- Modify: `docs/superpowers/specs/2026-07-09-craft-intent-sensory-palette-design.md` (Status: revision → implemented)
- Test: `MaughamTests/Views/PalettePaneTests.swift` (extend if a static helper is touched; otherwise no new tests — view-only additive)

- [ ] **Step 1:** PalettePane: after the grouped notes, `if !card.body.isEmpty { Text(card.body).font(.callout) }` with a caption divider, matching the pane's existing style.
- [ ] **Step 2:** Docs edits per above; run `-only-testing:MaughamTests/GuideDocsDriftTests -only-testing:MaughamTests/PalettePaneTests`.
- [ ] **Step 3: Commit** `feat(palette): body in right-pane card; docs align with visual editor`

---

### Task E: Verification (controller-run)

- [ ] Full Mac suite → TEST SUCCEEDED (watch the two pinned MCP tool-count tests — unchanged this time, no new tools).
- [ ] Release build → BUILD SUCCEEDED (ProjectWindow changed again).
- [ ] Report the UPDATED manual smoke checklist to the user (replaces the plan-v1 checklist):
  1. New Novel → Palette → "+ New Card" (location) → visual editor opens (NOT markdown).
  2. Click + on swatches → colour picker → chip appears; eyedropper → sample a colour from anywhere on screen → chip appears.
  3. Drag a JPEG from Finder onto the image well → thumbnail appears; paste a copied image → second thumbnail.
  4. Add a sense note via quick-entry + chip; add an untagged note; type freeform body text.
  5. Back to Wall → tile shows image thumbnail, swatches, note snippet. Two rapid card adds → both tiles appear (final-review watch-item).
  6. Rename the card title in the editor → wall + sidebar update; the image still renders (assets folder migrated).
  7. ⌘⌥7 → card shows swatches, notes, images, AND the body text.
  8. Open the card's `.md` in an outside editor: confirm it's clean canonical markdown (informational — not an editing surface).
  9. Claude Desktop: `read_palette_card` returns the body text in the markdown + the images; sense-pass prompt end-to-end.
  10. Craft intent flow unchanged: inspector Add/Open → editor → relaunch intact.

## Plan self-review notes

- The Task A round-trip law is the load-bearing test: editor-reachable model → canonical file → identical model. Parser's body capture must exactly mirror render's body emission (blank-line handling) — pinned by `test_roundTrip_fullCard`.
- Rename remapping (Task B steps 1–4) is the trickiest seam; `test_updatePaletteCard_titleRename_movesFileAndAssets` pins it end-to-end including the physical asset file.
- No MCP/schema changes anywhere: `read_palette_card` returns the full markdown (body included automatically); summaries unchanged.
