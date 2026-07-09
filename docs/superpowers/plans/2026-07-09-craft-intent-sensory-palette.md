# Craft Intent + Sensory Palette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Intent-first sensory groundedness — an optional per-piece craft-intent doc, subject-keyed palette cards (wall + right-pane mode), three read-only MCP tools (with crop-on-demand images), and a sense-pass guide topic, per the approved spec `docs/superpowers/specs/2026-07-09-craft-intent-sensory-palette-design.md`.

**Architecture:** Palette cards are ordinary research assets (`kind: .document`) under a `research/palette/` group in the manifest research tree, so CRUD/rename/trash/reorder ride the existing typed-mover machinery; a `PaletteCardParser` reads structure (kind/swatches/senses/images) out of the card markdown. The craft-intent doc is a conventionally-named research note (`craft-intent.md`) at the scope's research root — plain-edited, op-log-free, absence-is-valid. New `BinderSegment.palette` shows a wall (adaptive grid, Corkboard-style) in the center pane and auto-hides the inspector; new `DetailSegment.palette` (⌘⌥7) shows a read-only card beside the editor. MCP tools follow the `MCPTool` catalog pattern; `read_palette_card` reuses `ImageResponseBuilder`.

**Tech Stack:** Swift / SwiftUI (Mac target only — no MaughamCore or phone changes), XCTest, xcodegen.

## Global Constraints

- **No MaughamCore or MaughamPhone changes.** Everything lands in the `Maugham/` Mac target. (Phone scheme therefore does not need a test run; `TripwirePhoneGrepTest` greps only `MaughamPhone/` sources.)
- **Run `./gen.sh` after adding any new source file** — `Maugham.xcodeproj` is generated; never commit anything under it.
- Test command: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (narrow with `-only-testing:MaughamTests/<ClassName>` while iterating).
- **MCP never mutates** — all three new tools are read-only. Tool responses < 1 MB.
- Raw file reads of palette cards / intent docs need a `// adr-0018-ok: <reason>` line annotation or `TripwireGrepTests.test_noManuscriptFileReadsOutsideReconciler` fails.
- Any move/rename/trash of card/intent files goes through `DocumentStore.relocate`/`relocateUserContent`/`trash` (tripwire 14 auto-covers new `ProjectStore+*.swift` seams). This plan only *creates* files (plain writes are fine — `addResearchTextNote` precedent).
- New `maugham.*` events (none planned) would need `MaughamEvent.post`/receive helpers (tripwire 21).
- `ProjectWindow.body` changes: extract ViewModifiers if the type-checker complains; **a local Release build is required before tagging** (Task 12).
- No manifest schema bump: no new `AssetKind`/`ItemType` enum cases are introduced (cards are plain `.document` assets; card "kind" lives inside the markdown).
- Model hints for subagent dispatch: opus = Tasks 1, 2, 4, 10; sonnet = Tasks 3, 5, 6, 7, 8, 9, 11; haiku = Task 12.

---

### Task 1: PaletteCard model + parser

**Files:**
- Create: `Maugham/Models/PaletteCard.swift`
- Test: `MaughamTests/PaletteCardParserTests.swift`

**Interfaces:**
- Consumes: nothing (pure model + parser).
- Produces: `PaletteCard` (fields below), `PaletteCard.Kind` (`location|character|motif|other`), `PaletteCard.Sense` (`sight|sound|smell|touch|taste`), `PaletteCard.SensoryNote {sense: Sense?, text: String}`, `PaletteCardParser.parse(markdown:itemId:fallbackTitle:cardDirectory:) -> PaletteCard`, `PaletteCardParser.template(title:kind:) -> String`, `PaletteCard.color(fromHex:) -> (r: Double, g: Double, b: Double)?`.

**Card markdown convention** (documented in the type's doc comment):

```markdown
# The Flat

kind: location

## Swatches

- #8A6F4D
- #2F3B4C

## Senses

- smell: turpentine and cold ash
- sound: tram-rattle through the shutters
- cold quarry tile underfoot

## Images

- ../paris-flat.jpg
```

Rules: title = first `# ` heading (else `fallbackTitle`); `kind:` line anywhere before the first `##` (unknown/missing → `.other`); `## Swatches` list items must match `#RGB`/`#RRGGBB` (others ignored); `## Senses` list items with a leading `<sense>:` token (case-insensitive) are tagged, others untagged; `## Images` list items are paths relative to the card's directory, resolved to project-relative; inline `![alt](path)` images anywhere in the body are ALSO collected (deduped). Unknown sections are ignored (parser is read-only; cards are edited as raw markdown so there is no renderer to round-trip).

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/PaletteCardParserTests.swift
import XCTest
@testable import Maugham

final class PaletteCardParserTests: XCTestCase {

    private let fullCard = """
    # The Flat

    kind: location

    ## Swatches

    - #8A6F4D
    - #2F3B4C
    - not-a-swatch

    ## Senses

    - smell: turpentine and cold ash
    - SOUND: tram-rattle through the shutters
    - cold quarry tile underfoot

    ## Images

    - ../paris-flat.jpg

    Some prose with an inline image ![view](window.jpg).
    """

    func test_parse_fullCard() {
        let card = PaletteCardParser.parse(
            markdown: fullCard, itemId: "res-1", fallbackTitle: "fallback",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.researchItemId, "res-1")
        XCTAssertEqual(card.title, "The Flat")
        XCTAssertEqual(card.kind, .location)
        XCTAssertEqual(card.swatches, ["#8A6F4D", "#2F3B4C"])
        XCTAssertEqual(card.notes.count, 3)
        XCTAssertEqual(card.notes[0], .init(sense: .smell, text: "turpentine and cold ash"))
        XCTAssertEqual(card.notes[1], .init(sense: .sound, text: "tram-rattle through the shutters"))
        XCTAssertEqual(card.notes[2], .init(sense: nil, text: "cold quarry tile underfoot"))
        XCTAssertEqual(card.imagePaths, ["research/paris-flat.jpg", "research/palette/window.jpg"])
    }

    func test_parse_missingKindAndTitle_usesFallbacks() {
        let card = PaletteCardParser.parse(
            markdown: "just prose", itemId: "res-2", fallbackTitle: "Untitled Card",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.title, "Untitled Card")
        XCTAssertEqual(card.kind, .other)
        XCTAssertTrue(card.swatches.isEmpty)
        XCTAssertTrue(card.notes.isEmpty)
        XCTAssertTrue(card.imagePaths.isEmpty)
    }

    func test_parse_unknownKind_isOther() {
        let card = PaletteCardParser.parse(
            markdown: "# X\n\nkind: banana\n", itemId: "res-3", fallbackTitle: "X",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.kind, .other)
    }

    func test_template_parsesBackToItsOwnFields() {
        let md = PaletteCardParser.template(title: "Harbor at Dawn", kind: .location)
        let card = PaletteCardParser.parse(
            markdown: md, itemId: "res-4", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.title, "Harbor at Dawn")
        XCTAssertEqual(card.kind, .location)
    }

    func test_hexColor_parsing() {
        XCTAssertNotNil(PaletteCard.color(fromHex: "#8A6F4D"))
        XCTAssertNotNil(PaletteCard.color(fromHex: "#fff"))
        XCTAssertNil(PaletteCard.color(fromHex: "8A6F4D"))
        XCTAssertNil(PaletteCard.color(fromHex: "#GGGGGG"))
        let rgb = PaletteCard.color(fromHex: "#FF0000")
        XCTAssertEqual(rgb?.r ?? 0, 1.0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PaletteCardParserTests` (after `./gen.sh` picks up the new test file — it will fail to compile: `PaletteCard` not defined. A compile failure of the test target is the expected "red".)

- [ ] **Step 3: Implement `Maugham/Models/PaletteCard.swift`**

```swift
import Foundation

/// A parsed sensory-palette card. Cards are plain markdown research assets under
/// `research/palette/`; this type is the READ model — cards are edited as raw
/// markdown, so there is no renderer (template(title:kind:) seeds new cards).
public struct PaletteCard: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case location, character, motif, other
    }
    public enum Sense: String, CaseIterable, Sendable {
        case sight, sound, smell, touch, taste
    }
    public struct SensoryNote: Equatable, Sendable {
        public let sense: Sense?
        public let text: String
        public init(sense: Sense?, text: String) {
            self.sense = sense
            self.text = text
        }
    }

    public let researchItemId: String
    public let title: String
    public let kind: Kind
    public let swatches: [String]      // validated "#RGB" / "#RRGGBB"
    public let notes: [SensoryNote]
    public let imagePaths: [String]    // project-relative

    public var id: String { researchItemId }

    /// "#RRGGBB" / "#RGB" → normalized rgb components, nil if malformed.
    public static func color(fromHex hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.hasPrefix("#") else { return nil }
        var body = String(hex.dropFirst())
        if body.count == 3 { body = body.map { "\($0)\($0)" }.joined() }
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }
}

public enum PaletteCardParser {

    public static func template(title: String, kind: PaletteCard.Kind) -> String {
        """
        # \(title)

        kind: \(kind.rawValue)

        ## Swatches

        ## Senses

        ## Images

        """
    }

    public static func parse(
        markdown: String, itemId: String, fallbackTitle: String, cardDirectory: String
    ) -> PaletteCard {
        var title: String?
        var kind: PaletteCard.Kind = .other
        var swatches: [String] = []
        var notes: [PaletteCard.SensoryNote] = []
        var images: [String] = []

        enum Section { case none, swatches, senses, images, unknown }
        var section: Section = .none
        var seenSectionHeading = false

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                seenSectionHeading = true
                switch line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() {
                case "swatches": section = .swatches
                case "senses": section = .senses
                case "images": section = .images
                default: section = .unknown
                }
                continue
            }
            if line.hasPrefix("# "), title == nil {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if !seenSectionHeading, line.lowercased().hasPrefix("kind:") {
                let raw = line.dropFirst("kind:".count).trimmingCharacters(in: .whitespaces)
                kind = PaletteCard.Kind(rawValue: raw.lowercased()) ?? .other
                continue
            }
            guard line.hasPrefix("- ") else { continue }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            switch section {
            case .swatches:
                if PaletteCard.color(fromHex: item) != nil { swatches.append(item) }
            case .senses:
                if let colon = item.firstIndex(of: ":"),
                   let sense = PaletteCard.Sense(
                       rawValue: item[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) {
                    let text = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    notes.append(.init(sense: sense, text: text))
                } else {
                    notes.append(.init(sense: nil, text: item))
                }
            case .images:
                images.append(resolve(path: item, relativeTo: cardDirectory))
            case .none, .unknown:
                break
            }
        }

        // Inline ![alt](path) images anywhere in the body, deduped against section images.
        let inlinePattern = /!\[[^\]]*\]\(([^)]+)\)/
        for match in markdown.matches(of: inlinePattern) {
            let resolved = resolve(path: String(match.1), relativeTo: cardDirectory)
            if !images.contains(resolved) { images.append(resolved) }
        }

        return PaletteCard(
            researchItemId: itemId,
            title: title ?? fallbackTitle,
            kind: kind,
            swatches: swatches,
            notes: notes,
            imagePaths: images)
    }

    /// Resolve a card-relative path ("../x.jpg", "y.jpg") to project-relative,
    /// collapsing "..". Absolute paths and URLs pass through unchanged.
    private static func resolve(path: String, relativeTo directory: String) -> String {
        guard !path.hasPrefix("/"), !path.contains("://") else { return path }
        var components = directory.split(separator: "/").map(String.init)
        for part in path.split(separator: "/") {
            switch part {
            case "..": if !components.isEmpty { components.removeLast() }
            case ".": continue
            default: components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }
}
```

- [ ] **Step 4: `./gen.sh`, run tests, verify PASS**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PaletteCardParserTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/PaletteCard.swift MaughamTests/PaletteCardParserTests.swift
git commit -m "feat(palette): PaletteCard model + markdown parser"
```

---

### Task 2: ProjectStore+Palette store seam

**Files:**
- Create: `Maugham/Stores/ProjectStore+Palette.swift`
- Test: `MaughamTests/ProjectStorePaletteTests.swift`

**Interfaces:**
- Consumes: `PaletteCardParser.template(title:kind:)`, `PaletteCardParser.parse(...)` (Task 1); existing `ProjectStore.addResearchItem(parentId:title:kind:)`, `addResearchTextNote(parentId:title:)`, `manifest.research`, `saveManifest()`.
- Produces (all on `ProjectStore`):
  - `static let paletteFolderPath = "research/palette"`
  - `func paletteGroup() -> ResearchItem?`
  - `@discardableResult func ensurePaletteGroup() async throws -> ResearchItem`
  - `@discardableResult func addPaletteCard(title: String, kind: PaletteCard.Kind) async throws -> ResearchItem`
  - `func paletteCardItems() -> [ResearchItem]` (document assets under the group, manifest order)
  - `func loadPaletteCards() -> [PaletteCard]` (read + parse each; skips unreadable files)

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/ProjectStorePaletteTests.swift
import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class ProjectStorePaletteTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(named: "PaletteTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_ensurePaletteGroup_createsFolderAndManifestGroup_once() async throws {
        let (url, store, ds) = try await makeNovel()
        XCTAssertNil(store.paletteGroup())
        let group = try await store.ensurePaletteGroup()
        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.path, ProjectStore.paletteFolderPath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(ProjectStore.paletteFolderPath).path))
        let again = try await store.ensurePaletteGroup()
        XCTAssertEqual(again.id, group.id)   // idempotent — no duplicate group
        await ds.close()
    }

    func test_addPaletteCard_writesTemplateAndManifestEntry() async throws {
        let (url, store, ds) = try await makeNovel()
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        XCTAssertEqual(item.kind, .document)
        XCTAssertTrue(item.path?.hasPrefix("research/palette/") ?? false)
        let fileURL = url.appendingPathComponent(item.path ?? "")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let card = PaletteCardParser.parse(
            markdown: contents, itemId: item.id, fallbackTitle: "x",
            cardDirectory: ProjectStore.paletteFolderPath)
        XCTAssertEqual(card.title, "The Flat")
        XCTAssertEqual(card.kind, .location)
        await ds.close()
    }

    func test_loadPaletteCards_returnsParsedCardsInManifestOrder() async throws {
        let (_, store, ds) = try await makeNovel()
        _ = try await store.addPaletteCard(title: "The Flat", kind: .location)
        _ = try await store.addPaletteCard(title: "Marlowe", kind: .character)
        let cards = store.loadPaletteCards()
        XCTAssertEqual(cards.map(\.title), ["The Flat", "Marlowe"])
        XCTAssertEqual(cards.map(\.kind), [.location, .character])
        XCTAssertEqual(store.paletteCardItems().count, 2)
        await ds.close()
    }

    func test_loadPaletteCards_emptyWithoutGroup() async throws {
        let (_, store, ds) = try await makeNovel()
        XCTAssertTrue(store.loadPaletteCards().isEmpty)
        XCTAssertTrue(store.paletteCardItems().isEmpty)
        await ds.close()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (compile error: no such members)**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ProjectStorePaletteTests`

- [ ] **Step 3: Implement `Maugham/Stores/ProjectStore+Palette.swift`**

```swift
import Foundation
import MaughamCore

/// Sensory-palette store seam. Palette cards are ordinary research `.document`
/// assets under the `research/palette/` group, so rename/move/trash ride the
/// existing typed-mover machinery (tripwire 14) and ResearchView affordances.
extension ProjectStore {

    public static let paletteFolderPath = "research/palette"
    public static let paletteGroupTitle = "Palette"

    /// The palette group in the research tree, if it exists.
    public func paletteGroup() -> ResearchItem? {
        manifest.research.first { $0.type == .group && $0.path == Self.paletteFolderPath }
    }

    /// Find-or-create the `research/palette/` group (idempotent).
    @discardableResult
    public func ensurePaletteGroup() async throws -> ResearchItem {
        if let existing = paletteGroup() { return existing }
        // addResearchItem(kind: nil) creates a group folder from the slugified
        // title — "Palette" → research/palette.
        return try await addResearchItem(parentId: nil, title: Self.paletteGroupTitle, kind: nil)
    }

    /// Create a new palette card seeded from the template, under the palette group.
    @discardableResult
    public func addPaletteCard(title: String, kind: PaletteCard.Kind) async throws -> ResearchItem {
        let group = try await ensurePaletteGroup()
        let item = try await addResearchTextNote(parentId: group.id, title: title)
        if let rel = item.path {
            let url = projectURL.appendingPathComponent(rel)
            try PaletteCardParser.template(title: title, kind: kind)
                .data(using: .utf8)?.write(to: url)
        }
        return item
    }

    /// Document assets under the palette group, in manifest (wall) order.
    public func paletteCardItems() -> [ResearchItem] {
        (paletteGroup()?.children ?? []).filter { $0.type == .asset && $0.kind == .document }
    }

    /// Read + parse every card. Unreadable files are skipped, not fatal.
    public func loadPaletteCards() -> [PaletteCard] {
        paletteCardItems().compactMap { item in
            guard let rel = item.path,
                  let md = try? String(
                      contentsOf: projectURL.appendingPathComponent(rel),
                      encoding: .utf8) // adr-0018-ok: palette card read, not manuscript
            else { return nil }
            return PaletteCardParser.parse(
                markdown: md, itemId: item.id, fallbackTitle: item.title,
                cardDirectory: (rel as NSString).deletingLastPathComponent)
        }
    }
}
```

Note: if `addResearchItem` / `addResearchTextNote` signatures differ slightly (e.g. label names), match the real ones in `ProjectStore+Research.swift:9` / `:119`. If `projectURL` is not the store's property name for the project root, use the real accessor (check `ProjectStore.swift` — `load(from:)` retains the URL).

- [ ] **Step 4: Run tests, verify PASS**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ProjectStorePaletteTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Run the tripwire suite (raw-read annotation + mover)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/TripwireGrepTests`
Expected: PASS (the `// adr-0018-ok:` annotation on the card read; no raw moves).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/ProjectStore+Palette.swift MaughamTests/ProjectStorePaletteTests.swift
git commit -m "feat(palette): ProjectStore palette seam — group, cards, parse-on-load"
```

---

### Task 3: ProjectStore+CraftIntent store seam

**Files:**
- Create: `Maugham/Stores/ProjectStore+CraftIntent.swift`
- Test: `MaughamTests/ProjectStoreCraftIntentTests.swift`

**Interfaces:**
- Consumes: existing `addResearchTextNote(parentId:title:)`, `createResearchNote(scope:title:)` (`ResearchScope.swift:88`), `pieceResearchPrefix(for:)` (`ResearchScope.swift:120`), `TreeWalk.find`.
- Produces (all on `ProjectStore`):
  - `static let craftIntentFileName = "craft-intent.md"`
  - `static let craftIntentTitle = "Craft Intent"`
  - `func craftIntentItem(forPieceId: String?) -> ResearchItem?` — nil pieceId = project scope; returns nil when absent (absence is valid)
  - `@discardableResult func createCraftIntent(forPieceId: String?) async throws -> ResearchItem` — returns the existing item if already present (idempotent)

Scope rules (from spec): project scope (all project types) → `research/craft-intent.md`; collection **loose piece** → that piece's own research folder (`pieces/<NN>-<slug>/research/craft-intent.md` via `createResearchNote(scope: .document(pieceId))`). Collection *reference* pieces are full projects — their intent is their own project-scope doc; no special handling here.

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/ProjectStoreCraftIntentTests.swift
import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class ProjectStoreCraftIntentTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    func test_projectScope_absentByDefault_thenCreated() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "IntentTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds

        XCTAssertNil(store.craftIntentItem(forPieceId: nil))   // absence is valid

        let item = try await store.createCraftIntent(forPieceId: nil)
        XCTAssertEqual(item.title, ProjectStore.craftIntentTitle)
        XCTAssertEqual(item.path, "research/craft-intent.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/craft-intent.md").path))
        XCTAssertEqual(store.craftIntentItem(forPieceId: nil)?.id, item.id)

        let again = try await store.createCraftIntent(forPieceId: nil)
        XCTAssertEqual(again.id, item.id)   // idempotent
        await ds.close()
    }

    func test_collectionLoosePiece_getsItsOwnIntent() async throws {
        let url = try await ProjectFactory.createCollectionProject(named: "Coll", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story One", mode: .prose)

        XCTAssertNil(store.craftIntentItem(forPieceId: piece.id))
        let item = try await store.createCraftIntent(forPieceId: piece.id)
        XCTAssertTrue(item.path?.hasSuffix("/research/craft-intent.md") ?? false)
        XCTAssertTrue(item.path?.hasPrefix("pieces/") ?? false)
        XCTAssertEqual(store.craftIntentItem(forPieceId: piece.id)?.id, item.id)
        // Project-scope lookup must NOT see the piece's intent doc.
        XCTAssertNil(store.craftIntentItem(forPieceId: nil))
        await ds.close()
    }
}
```

(If `ProjectFactory.createCollectionProject(named:in:)` / `addLoosePiece(title:mode:)` labels differ, match `ProjectFactory.swift:100` / `ProjectStore+CollectionPieces.swift:24`.)

- [ ] **Step 2: Run to verify compile failure (missing members)**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ProjectStoreCraftIntentTests`

- [ ] **Step 3: Implement `Maugham/Stores/ProjectStore+CraftIntent.swift`**

```swift
import Foundation
import MaughamCore

/// Craft-intent doc seam. One optional freeform markdown doc per intent scope:
/// the project (novel/screenplay/short-story/collection), or a loose collection
/// piece. Plain-edited research-note content — op-log-free. ABSENCE IS VALID:
/// lookups return nil without side effects; nothing nags.
extension ProjectStore {

    public static let craftIntentFileName = "craft-intent.md"
    public static let craftIntentTitle = "Craft Intent"

    /// Locate the intent doc for a scope. nil pieceId = project scope.
    public func craftIntentItem(forPieceId pieceId: String?) -> ResearchItem? {
        let expectedPrefix: String
        if let pieceId {
            guard let prefix = pieceResearchPrefix(for: pieceId) else { return nil }
            expectedPrefix = prefix
        } else {
            expectedPrefix = "research"
        }
        let expectedPath = expectedPrefix + "/" + Self.craftIntentFileName
        return TreeWalk.findFirst(in: manifest.research) { item in
            item.type == .asset && item.path == expectedPath
        }
    }

    /// Find-or-create the intent doc for a scope (idempotent).
    @discardableResult
    public func createCraftIntent(forPieceId pieceId: String?) async throws -> ResearchItem {
        if let existing = craftIntentItem(forPieceId: pieceId) { return existing }
        if let pieceId {
            return try await createResearchNote(
                scope: .document(pieceId), title: Self.craftIntentTitle)
        }
        return try await addResearchTextNote(parentId: nil, title: Self.craftIntentTitle)
    }
}
```

Implementation notes:
- `TreeWalk.findFirst(in:where:)` — if `TreeWalk` only offers `find(id:in:)`, add a small local recursive helper in this file instead (walk `children`, first match wins); do NOT modify TreeWalk in MaughamCore (Global Constraints: no Core changes).
- `addResearchTextNote(parentId: nil, title: "Craft Intent")` slugifies to `craft-intent.md` — verify the slug function produces exactly that (it lowercases + hyphenates; `AddResearchTextNoteTests` shows the convention). If the produced filename differs, adjust `craftIntentFileName` to match the slugger's output rather than fighting it.
- For collections, confirm `createResearchNote(scope: .document(pieceId))` routes to the piece research folder for loose pieces (`ResearchScope.swift` routing) — the test pins this.

- [ ] **Step 4: Run tests, verify PASS**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ProjectStoreCraftIntentTests`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore+CraftIntent.swift MaughamTests/ProjectStoreCraftIntentTests.swift
git commit -m "feat(intent): craft-intent doc seam — per-project + per-loose-piece, absence-is-valid"
```

---

### Task 4: BinderSegment.palette + the wall (center-pane surface)

**Files:**
- Modify: `Maugham/Models/BinderSegment.swift` (new case)
- Create: `Maugham/Views/Palette/PaletteWallView.swift`
- Create: `Maugham/Views/Palette/PaletteCardTile.swift`
- Create: `Maugham/Views/Palette/PaletteBinderList.swift`
- Modify: `Maugham/Views/BinderPaneToggle.swift` (picker tag + sidebar arm)
- Modify: `Maugham/Views/CollectionBinderPaneToggle.swift` (same)
- Modify: `Maugham/Views/ProjectWindow.swift` (`existingEditorSwitch` + `existingInspectorSwitch` arms, `selectedPaletteCardId` state, inspector auto-hide modifier)
- Test: `MaughamTests/Views/PaletteCardTileTests.swift`

**Interfaces:**
- Consumes: `ProjectStore.loadPaletteCards()`, `addPaletteCard(title:kind:)` (Task 2); `PaletteCard` (Task 1); existing `CorkboardGrid` layout idiom, `ResearchNoteEditor(...)` for card editing.
- Produces: `BinderSegment.palette` case; `PaletteWallView(store:selectedCardId:)`; `PaletteCardTile(card:thumbnail:isSelected:onSelect:)` with `nonisolated static func snippet(for notes: [PaletteCard.SensoryNote], limit: Int) -> String`; `PaletteBinderList(store:selectedCardId:)`; `ProjectWindow.@State selectedPaletteCardId: String?`; `PaletteSegmentModifier` (inspector auto-hide/restore).

Behavior:
- **Sidebar (palette segment):** `PaletteBinderList` — a `List(selection: $selectedCardId)` of card titles with kind icons, plus a bottom "+ New Card" `Menu` (one item per `PaletteCard.Kind`) calling `store.addPaletteCard(title: "New \(kind) card", kind: kind)` then selecting it.
- **Center:** if `selectedPaletteCardId == nil` → `PaletteWallView` (adaptive `LazyVGrid`, min 220, of `PaletteCardTile`s; tile click sets selection). If non-nil → `ResearchNoteEditor` for that card's path with a "‹ Wall" back button in a small header row (mirror how `existingEditorSwitch`'s `.research` arm mounts `ResearchNoteEditor` at `ProjectWindow.swift:777-796`).
- **Empty wall:** `ContentUnavailableView("No palette cards", systemImage: "paintpalette", description: Text("Gather images, swatches, and sensory notes per location, character, or motif."))` + `.frame(maxWidth: .infinity, maxHeight: .infinity)`; outer container `.frame(..., alignment: .top)` (tripwire 15).
- **Cards load once per appearance** into `@State private var cards: [PaletteCard]` via `.task(id: store.manifest.modified)`; thumbnails (first image per card) load in the same task into `[String: NSImage]`, downscaled to ≤320px — never inside tile bodies (tripwire 4). Thumbnail file read is a UI image load, not a text read — `NSImage(contentsOf:)` doesn't match the ADR-0018 grep patterns; no annotation needed.
- **Tile click:** `Button { onSelect() } label: { ... }.buttonStyle(.plain)` (tripwire 9).
- **Tile content:** thumbnail (or kind SF-symbol placeholder: location `mappin.and.ellipse`, character `person`, motif `sparkles`, other `square.grid.2x2`), title, swatch strip (`HStack` of 16×16 `RoundedRectangle`s filled from `PaletteCard.color(fromHex:)`), up to 2 sensory-note lines via `PaletteCardTile.snippet(for:limit:)`.
- **Inspector auto-hide:** new `PaletteSegmentModifier` (ViewModifier on the ProjectWindow modifier chain — do NOT inline in `body`, type-check ceiling):

```swift
/// Entering the palette segment hides the right pane so the wall gets width;
/// leaving restores the pane's prior visibility exactly (spec: no stuck-hidden
/// inspector). Kept out of ProjectWindow.body for the type-checker budget.
private struct PaletteSegmentModifier: ViewModifier {
    let binderSegment: BinderSegment
    @Binding var showInspector: Bool
    @Binding var inspectorWasVisibleBeforePalette: Bool?
    @Binding var selectedPaletteCardId: String?

    func body(content: Content) -> some View {
        content.onChange(of: binderSegment) { old, new in
            if new == .palette && old != .palette {
                inspectorWasVisibleBeforePalette = showInspector
                showInspector = false
            } else if old == .palette && new != .palette {
                if let prior = inspectorWasVisibleBeforePalette { showInspector = prior }
                inspectorWasVisibleBeforePalette = nil
                selectedPaletteCardId = nil
            }
        }
    }
}
```

(A ⌘⌥N shortcut that sets `showInspector = true` while in palette wins — the user explicitly asked for the pane; don't fight it.)

- **`BinderSegment`:** add `case palette` (non-conditional — always available, like `.research`; no coercion `.onChange` needed). Old app versions reading a `ui-state.json` with `"palette"` fall back to `.manuscript` via `UIState`'s defensive decode — no schema bump.
- **`existingInspectorSwitch`** gets `case .palette:` returning `ContentUnavailableView("Palette", systemImage: "paintpalette").frame(maxWidth: .infinity, maxHeight: .infinity)` (pane is normally hidden here anyway).
- **Picker tags** in both `BinderPaneToggle.swift` and `CollectionBinderPaneToggle.swift`: `Image(systemName: "paintpalette").tag(BinderSegment.palette).help("Palette")`, placed after Research.

- [ ] **Step 1: Write the failing static-helper test**

```swift
// MaughamTests/Views/PaletteCardTileTests.swift
import XCTest
@testable import Maugham

final class PaletteCardTileTests: XCTestCase {
    func test_snippet_prefersTaggedNotes_andCapsAtLimit() {
        let notes: [PaletteCard.SensoryNote] = [
            .init(sense: nil, text: "untagged line"),
            .init(sense: .smell, text: "turpentine"),
            .init(sense: .sound, text: "tram-rattle"),
        ]
        XCTAssertEqual(
            PaletteCardTile.snippet(for: notes, limit: 2),
            "smell: turpentine\nsound: tram-rattle")
    }

    func test_snippet_fallsBackToUntagged_andEmpty() {
        XCTAssertEqual(
            PaletteCardTile.snippet(for: [.init(sense: nil, text: "just a line")], limit: 2),
            "just a line")
        XCTAssertEqual(PaletteCardTile.snippet(for: [], limit: 2), "")
    }

    func test_kindSymbol_mapping() {
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .location), "mappin.and.ellipse")
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .character), "person")
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .motif), "sparkles")
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .other), "square.grid.2x2")
    }
}
```

Snippet rule: take tagged notes first (in order), then untagged, up to `limit`; tagged render as `"<sense>: <text>"`, untagged as bare text; joined with `\n`.

- [ ] **Step 2: Run to verify compile failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PaletteCardTileTests`

- [ ] **Step 3: Implement the views + wiring**

`PaletteCardTile.swift` (the pure helpers are the tested surface; body follows CorkboardGrid's card at `CorkboardGrid.swift:25-73`):

```swift
import SwiftUI

struct PaletteCardTile: View {
    let card: PaletteCard
    let thumbnail: NSImage?
    let isSelected: Bool
    let onSelect: () -> Void

    nonisolated static func kindSymbol(for kind: PaletteCard.Kind) -> String {
        switch kind {
        case .location: "mappin.and.ellipse"
        case .character: "person"
        case .motif: "sparkles"
        case .other: "square.grid.2x2"
        }
    }

    nonisolated static func snippet(for notes: [PaletteCard.SensoryNote], limit: Int) -> String {
        let tagged = notes.filter { $0.sense != nil }
        let untagged = notes.filter { $0.sense == nil }
        return (tagged + untagged).prefix(limit).map { note in
            if let sense = note.sense { "\(sense.rawValue): \(note.text)" } else { note.text }
        }.joined(separator: "\n")
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 110).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(height: 110)
                        .overlay(Image(systemName: Self.kindSymbol(for: card.kind))
                            .font(.title).foregroundStyle(.secondary))
                }
                HStack(spacing: 4) {
                    Image(systemName: Self.kindSymbol(for: card.kind))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(card.title).font(.headline).lineLimit(1)
                }
                if !card.swatches.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(card.swatches.prefix(8), id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(swatchColor(hex)).frame(width: 16, height: 16)
                        }
                    }
                }
                let snippet = Self.snippet(for: card.notes, limit: 2)
                if !snippet.isEmpty {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func swatchColor(_ hex: String) -> Color {
        guard let rgb = PaletteCard.color(fromHex: hex) else { return .clear }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
```

`PaletteWallView.swift`:

```swift
import SwiftUI

/// The palette wall — center-pane surface for BinderSegment.palette.
/// Cards + thumbnails load once per manifest change (tripwire 4); tiles do
/// no I/O in body.
struct PaletteWallView: View {
    let store: ProjectStore
    @Binding var selectedCardId: String?

    @State private var cards: [PaletteCard] = []
    @State private var thumbnails: [String: NSImage] = [:]

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]
    private static let thumbnailMaxEdge: CGFloat = 320

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView(
                    "No palette cards",
                    systemImage: "paintpalette",
                    description: Text("Gather images, swatches, and sensory notes per location, character, or motif. Add a card from the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(cards) { card in
                            PaletteCardTile(
                                card: card,
                                thumbnail: thumbnails[card.id],
                                isSelected: selectedCardId == card.id,
                                onSelect: { selectedCardId = card.id })
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: store.manifest.modified) { await reload() }
    }

    private func reload() async {
        let loaded = store.loadPaletteCards()
        var thumbs: [String: NSImage] = [:]
        for card in loaded {
            guard let first = card.imagePaths.first else { continue }
            let url = store.projectURL.appendingPathComponent(first)
            if let image = NSImage(contentsOf: url) {
                thumbs[card.id] = downscaled(image, maxEdge: Self.thumbnailMaxEdge)
            }
        }
        cards = loaded
        thumbnails = thumbs
    }

    private func downscaled(_ image: NSImage, maxEdge: CGFloat) -> NSImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let scale = maxEdge / longest
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        out.unlockFocus()
        return out
    }
}
```

`PaletteBinderList.swift`:

```swift
import SwiftUI

/// Palette-segment sidebar: card list + "+ New Card" kind menu.
struct PaletteBinderList: View {
    let store: ProjectStore
    @Binding var selectedCardId: String?

    @State private var cards: [PaletteCard] = []

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedCardId) {
                ForEach(cards) { card in
                    Label(card.title, systemImage: PaletteCardTile.kindSymbol(for: card.kind))
                        .tag(card.id)
                }
            }
            .listStyle(.sidebar)
            Divider()
            Menu {
                ForEach(PaletteCard.Kind.allCases, id: \.self) { kind in
                    Button(kind.rawValue.capitalized) {
                        Task {
                            let item = try? await store.addPaletteCard(
                                title: "New \(kind.rawValue)", kind: kind)
                            selectedCardId = item?.id
                        }
                    }
                }
            } label: {
                Label("New Card", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .padding(8)
        }
        .task(id: store.manifest.modified) { cards = store.loadPaletteCards() }
    }
}
```

Wiring (follow the exploration recipe exactly):
1. `BinderSegment.swift`: add `case palette` after `case research`.
2. `BinderPaneToggle.swift` + `CollectionBinderPaneToggle.swift`: add the picker tag and a `case .palette:` sidebar arm mounting `PaletteBinderList(store:selectedCardId:)`. Thread a new `@Binding var selectedPaletteCardId: String?` from `ProjectWindow` the same way `$selectedResearchId` is threaded (`ProjectWindow.binderColumn` → toggle init).
3. `ProjectWindow.swift`:
   - `@State private var selectedPaletteCardId: String?` and `@State private var inspectorWasVisibleBeforePalette: Bool?` near line 40.
   - `existingEditorSwitch` (`:749`): add
     ```swift
     case .palette:
         if let cardId = selectedPaletteCardId,
            let item = store.paletteCardItems().first(where: { $0.id == cardId }),
            let path = item.path {
             VStack(spacing: 0) {
                 HStack {
                     Button { selectedPaletteCardId = nil } label: {
                         Label("Wall", systemImage: "chevron.left")
                     }
                     .buttonStyle(.plain)
                     Spacer()
                 }
                 .padding(.horizontal, 12).padding(.vertical, 6)
                 Divider()
                 ResearchNoteEditor(/* same init the .research arm uses, for `path` */)
             }
         } else {
             PaletteWallView(store: store, selectedCardId: $selectedPaletteCardId)
         }
     ```
     (Copy the exact `ResearchNoteEditor` init from the `.research` arm at `:777-796` — same store/documentStore/path plumbing.)
   - `existingInspectorSwitch` (`:883`): add `case .palette:` → `ContentUnavailableView("Palette", systemImage: "paintpalette").frame(maxWidth: .infinity, maxHeight: .infinity)`.
   - Add `PaletteSegmentModifier` (code above) to the `.modifier(...)` chain (lines 245-297).
4. If the compiler reports "unable to type-check this expression in reasonable time" ANYWHERE in `ProjectWindow.body` — that diagnostic is REAL; extract further ViewModifiers.

- [ ] **Step 4: Run helper tests + full Mac suite**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PaletteCardTileTests`
Expected: 3 tests PASS.
Then the full suite (exhaustive-switch changes ripple): `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/BinderSegment.swift Maugham/Views/Palette/ Maugham/Views/BinderPaneToggle.swift Maugham/Views/CollectionBinderPaneToggle.swift Maugham/Views/ProjectWindow.swift MaughamTests/Views/PaletteCardTileTests.swift
git commit -m "feat(palette): palette binder segment — wall, card tiles, sidebar list, inspector auto-hide"
```

---

### Task 5: DetailSegment.palette — right-pane card mode (⌘⌥7)

**Files:**
- Modify: `Maugham/Models/DetailSegment.swift` (new case)
- Create: `Maugham/Views/Palette/PalettePane.swift`
- Modify: `Maugham/Views/DetailPaneToggle.swift` (picker tag + `segmentContent` arm)
- Test: `MaughamTests/Views/PalettePaneTests.swift`

**Interfaces:**
- Consumes: `ProjectStore.loadPaletteCards()` (Task 2), `PaletteCard` (Task 1), `PaletteCardTile.kindSymbol(for:)` (Task 4), `AdaptiveFilterRow` conventions.
- Produces: `DetailSegment.palette` case; `PalettePane(store:)` with `nonisolated static func senseSymbol(for: PaletteCard.Sense) -> String`.

Behavior: a card `Picker`/`Menu` at top (manifest order); below, the selected card rendered **read-only**: images (downscaled, loaded in `.task`), swatch strip, sensory notes grouped by sense with SF-symbol icons (sight `eye`, sound `ear`, smell `nose` — if `nose` is unavailable on macOS 15 use `wind`, verify in SF Symbols — touch `hand.raised`, taste `mouth`), untagged notes last under an ellipsis icon. Empty states per tripwire 15: no cards → `ContentUnavailableView("No palette cards", systemImage: "paintpalette", description: Text("Add cards from the Palette segment (binder)."))`; cards but none picked → auto-pick the first. Selected card id is pane-local `@State` (not persisted — YAGNI). Keyboard: `.keyboardShortcut("7", modifiers: [.command, .option])` inline on the picker tag, mirroring ⌘⌥4/5/6 (`DetailPaneToggle.swift:95-146`).

- [ ] **Step 1: Write the failing test**

```swift
// MaughamTests/Views/PalettePaneTests.swift
import XCTest
@testable import Maugham

final class PalettePaneTests: XCTestCase {
    func test_senseSymbol_coversAllSenses() {
        for sense in PaletteCard.Sense.allCases {
            XCTAssertFalse(PalettePane.senseSymbol(for: sense).isEmpty)
        }
        XCTAssertEqual(PalettePane.senseSymbol(for: .sight), "eye")
        XCTAssertEqual(PalettePane.senseSymbol(for: .touch), "hand.raised")
    }

    func test_groupedNotes_ordersTaggedBySenseThenUntagged() {
        let notes: [PaletteCard.SensoryNote] = [
            .init(sense: nil, text: "loose"),
            .init(sense: .taste, text: "salt"),
            .init(sense: .sight, text: "green light"),
        ]
        let groups = PalettePane.groupedNotes(notes)
        XCTAssertEqual(groups.map(\.sense), [.sight, .taste, nil])
        XCTAssertEqual(groups.first?.notes.map(\.text), ["green light"])
    }
}
```

`groupedNotes(_:) -> [(sense: PaletteCard.Sense?, notes: [SensoryNote])]` groups in `Sense.allCases` order (only non-empty groups), untagged group last.

- [ ] **Step 2: Run to verify compile failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PalettePaneTests`

- [ ] **Step 3: Implement**

`DetailSegment.swift`: add `case palette` after `case inbox`.

`PalettePane.swift`:

```swift
import SwiftUI

/// Right-pane mode (⌘⌥7): pick a palette card and write against it — read-only
/// images, swatches, and sensory notes beside the editor. Cards load once per
/// manifest change (tripwire 4).
struct PalettePane: View {
    let store: ProjectStore

    @State private var cards: [PaletteCard] = []
    @State private var selectedCardId: String?
    @State private var images: [NSImage] = []

    nonisolated static func senseSymbol(for sense: PaletteCard.Sense) -> String {
        switch sense {
        case .sight: "eye"
        case .sound: "ear"
        case .smell: "nose"        // verify availability; fallback "wind"
        case .touch: "hand.raised"
        case .taste: "mouth"       // verify availability; fallback "fork.knife"
        }
    }

    nonisolated static func groupedNotes(
        _ notes: [PaletteCard.SensoryNote]
    ) -> [(sense: PaletteCard.Sense?, notes: [PaletteCard.SensoryNote])] {
        var groups: [(sense: PaletteCard.Sense?, notes: [PaletteCard.SensoryNote])] = []
        for sense in PaletteCard.Sense.allCases {
            let matching = notes.filter { $0.sense == sense }
            if !matching.isEmpty { groups.append((sense, matching)) }
        }
        let untagged = notes.filter { $0.sense == nil }
        if !untagged.isEmpty { groups.append((nil, untagged)) }
        return groups
    }

    private var selectedCard: PaletteCard? {
        cards.first { $0.id == selectedCardId } ?? cards.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if cards.isEmpty {
                ContentUnavailableView(
                    "No palette cards",
                    systemImage: "paintpalette",
                    description: Text("Add cards from the Palette segment (binder)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Card", selection: Binding(
                    get: { selectedCard?.id ?? "" },
                    set: { selectedCardId = $0 })) {
                    ForEach(cards) { card in
                        Text(card.title).tag(card.id)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                Divider()
                if let card = selectedCard {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                                Image(nsImage: image)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            if !card.swatches.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(card.swatches, id: \.self) { hex in
                                        if let rgb = PaletteCard.color(fromHex: hex) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                                                .frame(width: 20, height: 20)
                                                .help(hex)
                                        }
                                    }
                                }
                            }
                            ForEach(Array(Self.groupedNotes(card.notes).enumerated()),
                                    id: \.offset) { _, group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(
                                        group.sense?.rawValue.capitalized ?? "Notes",
                                        systemImage: group.sense.map(Self.senseSymbol(for:))
                                            ?? "ellipsis")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(Array(group.notes.enumerated()), id: \.offset) { _, note in
                                        Text(note.text).font(.callout)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: store.manifest.modified) { reloadCards() }
        .task(id: selectedCard?.id) { reloadImages() }
    }

    private func reloadCards() { cards = store.loadPaletteCards() }

    private func reloadImages() {
        guard let card = selectedCard else { images = []; return }
        images = card.imagePaths.compactMap {
            NSImage(contentsOf: store.projectURL.appendingPathComponent($0))
        }
    }
}
```

`DetailPaneToggle.swift`: add the picker tag after `.inbox`:

```swift
Image(systemName: "paintpalette")
    .tag(DetailSegment.palette)
    .help("Palette Card (⌘⌥7)")
    .keyboardShortcut("7", modifiers: [.command, .option])
```

and the `segmentContent` arm: `case .palette: PalettePane(store: store)` (thread `store` the same way `tasksPane`/`inboxPane` get theirs).

- [ ] **Step 4: Run tests, verify PASS; spot-check SF symbol names**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PalettePaneTests`
Expected: 2 tests PASS. Also verify `NSImage(systemSymbolName:accessibilityDescription:)` returns non-nil for `"nose"` and `"mouth"` in a quick unit assertion or manual check; substitute fallbacks if nil and update the `senseSymbol` test accordingly.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/DetailSegment.swift Maugham/Views/Palette/PalettePane.swift Maugham/Views/DetailPaneToggle.swift MaughamTests/Views/PalettePaneTests.swift
git commit -m "feat(palette): right-pane palette-card mode (cmd-opt-7) — write against a card"
```

---

### Task 6: Inspector craft-intent affordance

**Files:**
- Modify: `Maugham/Views/InspectorView.swift` (project-scope section)
- Modify: `Maugham/Views/PieceInspector.swift` (loose-piece section)
- Modify: `Maugham/Views/ProjectWindow.swift` (open-intent navigation closure)
- Test: `MaughamTests/ProjectStoreCraftIntentTests.swift` (extend)

**Interfaces:**
- Consumes: `craftIntentItem(forPieceId:)` / `createCraftIntent(forPieceId:)` (Task 3).
- Produces: a `Section("Craft Intent")` in both inspectors with ONE quiet affordance: "Open Craft Intent" when the doc exists, "Add craft intent…" when absent (creates then opens). Both call `onOpenCraftIntent(item.id)` — a closure threaded from `ProjectWindow` that sets `binderSegment = .research; selectedResearchId = itemId` (the research editor then opens it — existing click-to-edit flow). **Never a nag or badge** (spec: absence is valid).

- [ ] **Step 1: Write the failing test (store-level: the affordance's exact call sequence)**

Append to `ProjectStoreCraftIntentTests`:

```swift
func test_addThenOpen_sequence_returnsResearchItemIdForNavigation() async throws {
    let url = try await ProjectFactory.createNovelProject(named: "IntentNav", in: temp.url)
    let store = try await ProjectStore.load(from: url)
    let ds = try await DocumentStore.open(url: url)
    store.documentStore = ds
    // The affordance's behavior: create-if-absent, then navigate by item id.
    let item = try await store.createCraftIntent(forPieceId: nil)
    XCTAssertNotNil(TreeWalk.find(id: item.id, in: store.manifest.research))
    await ds.close()
}
```

(If `TreeWalk.find(id:in:)`'s label differs, match the call in `ProjectWindow.swift:777-796`.)

- [ ] **Step 2: Run to verify it fails / passes-trivially**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ProjectStoreCraftIntentTests`
This test passes off Task 3's work — it pins the navigation contract (item id resolvable in the research tree). Verify it passes, then wire the UI.

- [ ] **Step 3: Implement the inspector sections**

In `InspectorView.swift`, after the existing `Section("Document")` block (`:23`), following the house style (plain `Section` + `Button`):

```swift
Section("Craft Intent") {
    if let intent = store.craftIntentItem(forPieceId: nil) {
        Button("Open Craft Intent") { onOpenCraftIntent(intent.id) }
    } else {
        Button("Add craft intent…") {
            Task {
                if let item = try? await store.createCraftIntent(forPieceId: nil) {
                    onOpenCraftIntent(item.id)
                }
            }
        }
    }
}
```

Add `let onOpenCraftIntent: (String) -> Void` to `InspectorView`'s properties and inits/call sites. Mirror the same section in `PieceInspector.swift` with `forPieceId: piece.id` (loose pieces only — `ReferencePieceInspector` is untouched; a reference's intent belongs to its own project). In `ProjectWindow.swift`, where `InspectorView`/`PieceInspector` are constructed (the `inspectorContent` closure / `existingInspectorSwitch`), pass:

```swift
onOpenCraftIntent: { itemId in
    binderSegment = .research
    selectedResearchId = itemId
}
```

- [ ] **Step 4: Run full Mac suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: all green (init-site changes compile everywhere).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/InspectorView.swift Maugham/Views/PieceInspector.swift Maugham/Views/ProjectWindow.swift MaughamTests/ProjectStoreCraftIntentTests.swift
git commit -m "feat(intent): quiet Add/Open Craft Intent affordance in inspectors"
```

---

### Task 7: MCP tool — read_craft_intent

**Files:**
- Create: `Maugham/MCP/Tools/CraftIntentTools.swift`
- Modify: `Maugham/MCP/MCPTool.swift` (catalog entry)
- Test: `MaughamTests/MCP/Tools/CraftIntentToolTests.swift`

**Interfaces:**
- Consumes: `craftIntentItem(forPieceId:)` (Task 3); `decodeParams`/`resolveProject` (`MCPToolHelpers.swift`).
- Produces: `ReadCraftIntentTool` — method `read_craft_intent`, params `{project_id: String, item_id?: String}` (item_id = collection loose-piece id; omitted = project scope), result `{exists: Bool, markdown: String?, path: String?}`. **Absence returns `exists: false` — NOT an error** (spec: absence is a first-class valid state).

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/MCP/Tools/CraftIntentToolTests.swift
import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class CraftIntentToolTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeRegisteredNovel() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry) {
        let url = try await ProjectFactory.createNovelProject(named: "IntentMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg)
    }

    func test_absentIntent_returnsExistsFalse_notError() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        let id = ProjectIdentifier.id(for: url)
        let json = try await ReadCraftIntentTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        let result = try JSONDecoder().decode(ReadCraftIntentTool.Result.self, from: json)
        XCTAssertFalse(result.exists)
        XCTAssertNil(result.markdown)
        await ds.close()
    }

    func test_presentIntent_returnsMarkdown() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let item = try await store.createCraftIntent(forPieceId: nil)
        try "This story lives in the body. The port scenes should smell."
            .data(using: .utf8)!
            .write(to: url.appendingPathComponent(item.path!))
        let id = ProjectIdentifier.id(for: url)
        let json = try await ReadCraftIntentTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        let result = try JSONDecoder().decode(ReadCraftIntentTool.Result.self, from: json)
        XCTAssertTrue(result.exists)
        XCTAssertEqual(result.markdown,
            "This story lives in the body. The port scenes should smell.")
        XCTAssertEqual(result.path, "research/craft-intent.md")
        await ds.close()
    }

    func test_unknownProject_throwsToolError() async throws {
        let reg = ProjectRegistry()
        do {
            _ = try await ReadCraftIntentTool.handle(
                paramsJSON: Data("{\"project_id\":\"nope\"}".utf8), registry: reg)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }
}
```

(Match the exact `ProjectRegistry` registration call to `ListResearchToolTests.swift`'s fixture if `register(url:store:)` differs.)

- [ ] **Step 2: Run to verify compile failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/CraftIntentToolTests`

- [ ] **Step 3: Implement**

```swift
// Maugham/MCP/Tools/CraftIntentTools.swift
import Foundation

/// read_craft_intent — the writer's optional statement of what a piece needs
/// sensorially. ABSENCE IS VALID: returns {exists: false}, never an error.
public enum ReadCraftIntentTool: MCPTool {
    public static let method = "read_craft_intent"
    public static let description =
        "Read the writer's craft-intent doc — an optional freeform statement of what "
        + "the story (or a collection piece) needs, e.g. sensory groundedness goals. "
        + "Returns exists:false when the writer has not declared one; that is a valid, "
        + "deliberate state — do not invent a standard on their behalf. Pass item_id "
        + "for a collection loose piece; omit for project scope."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"item_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let item_id: String?
    }
    public struct Result: Codable, Equatable {
        public let exists: Bool
        public let markdown: String?
        public let path: String?
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        guard let item = entry.store.craftIntentItem(forPieceId: params.item_id),
              let rel = item.path else {
            return try JSONEncoder().encode(Result(exists: false, markdown: nil, path: nil))
        }
        let url = entry.url.appendingPathComponent(rel)
        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? "" // adr-0018-ok: craft-intent note read, not manuscript
        return try JSONEncoder().encode(Result(exists: true, markdown: markdown, path: rel))
    }
}
```

Add `ReadCraftIntentTool.self` to `MCPToolCatalog.all` in `MCPTool.swift` (before `GetHelpTool.self`).

- [ ] **Step 4: Run new tests + catalog consistency, verify PASS**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/CraftIntentToolTests -only-testing:MaughamTests/MCPCatalogConsistencyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/CraftIntentTools.swift Maugham/MCP/MCPTool.swift MaughamTests/MCP/Tools/CraftIntentToolTests.swift
git commit -m "feat(mcp): read_craft_intent tool — absence-is-valid contract"
```

---

### Task 8: MCP tool — list_palette_cards

**Files:**
- Create: `Maugham/MCP/Tools/PaletteTools.swift`
- Modify: `Maugham/MCP/MCPTool.swift` (catalog entry)
- Test: `MaughamTests/MCP/Tools/PaletteToolsTests.swift`

**Interfaces:**
- Consumes: `loadPaletteCards()` (Task 2), `PaletteCard` (Task 1).
- Produces: `ListPaletteCardsTool` — method `list_palette_cards`, params `{project_id}`, result `{cards: [{id, title, kind, swatches: [String], note_count: Int, image_paths: [String]}]}`. (Swatches and image paths are small — inline them; notes are summarized by count, full text comes from `read_palette_card`.)

- [ ] **Step 1: Write the failing test**

```swift
// MaughamTests/MCP/Tools/PaletteToolsTests.swift
import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class PaletteToolsTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    func makeProjectWithCard() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry, ResearchItem) {
        let url = try await ProjectFactory.createNovelProject(named: "PaletteMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try """
        # The Flat

        kind: location

        ## Swatches

        - #8A6F4D

        ## Senses

        - smell: turpentine
        - sound: tram-rattle
        """.data(using: .utf8)!.write(to: url.appendingPathComponent(item.path!))
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg, item)
    }

    func test_listPaletteCards_returnsSummaries() async throws {
        let (url, _, ds, reg, item) = try await makeProjectWithCard()
        let id = ProjectIdentifier.id(for: url)
        let json = try await ListPaletteCardsTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        let result = try JSONDecoder().decode(ListPaletteCardsTool.Result.self, from: json)
        XCTAssertEqual(result.cards.count, 1)
        let card = try XCTUnwrap(result.cards.first)
        XCTAssertEqual(card.id, item.id)
        XCTAssertEqual(card.title, "The Flat")
        XCTAssertEqual(card.kind, "location")
        XCTAssertEqual(card.swatches, ["#8A6F4D"])
        XCTAssertEqual(card.note_count, 2)
        XCTAssertTrue(card.image_paths.isEmpty)
        await ds.close()
    }

    func test_listPaletteCards_emptyProject_returnsEmpty() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Empty", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let json = try await ListPaletteCardsTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\"}".utf8),
            registry: reg)
        let result = try JSONDecoder().decode(ListPaletteCardsTool.Result.self, from: json)
        XCTAssertTrue(result.cards.isEmpty)
        await ds.close()
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PaletteToolsTests`

- [ ] **Step 3: Implement (in `Maugham/MCP/Tools/PaletteTools.swift`)**

```swift
import Foundation

/// list_palette_cards — summaries of the project's sensory-palette cards.
public enum ListPaletteCardsTool: MCPTool {
    public static let method = "list_palette_cards"
    public static let description =
        "List the project's sensory-palette cards (subject-keyed reference material: "
        + "locations, characters, motifs — each with swatches, sensory notes, images). "
        + "Use read_palette_card for a card's full notes and images."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable { public let project_id: String }
    public struct CardSummary: Codable, Equatable {
        public let id: String
        public let title: String
        public let kind: String
        public let swatches: [String]
        public let note_count: Int
        public let image_paths: [String]
    }
    public struct Result: Codable, Equatable { public let cards: [CardSummary] }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let cards = entry.store.loadPaletteCards().map { card in
            CardSummary(
                id: card.researchItemId, title: card.title, kind: card.kind.rawValue,
                swatches: card.swatches, note_count: card.notes.count,
                image_paths: card.imagePaths)
        }
        return try JSONEncoder().encode(Result(cards: cards))
    }
}
```

Add `ListPaletteCardsTool.self` to `MCPToolCatalog.all`.

- [ ] **Step 4: Run tests + catalog consistency, verify PASS**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PaletteToolsTests -only-testing:MaughamTests/MCPCatalogConsistencyTests`

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/PaletteTools.swift Maugham/MCP/MCPTool.swift MaughamTests/MCP/Tools/PaletteToolsTests.swift
git commit -m "feat(mcp): list_palette_cards tool"
```

---

### Task 9: MCP tool — read_palette_card (text + crop-on-demand images)

**Files:**
- Modify: `Maugham/MCP/Tools/PaletteTools.swift` (add `ReadPaletteCardTool`)
- Modify: `Maugham/MCP/MCPTool.swift` (catalog entry)
- Test: `MaughamTests/MCP/Tools/PaletteToolsTests.swift` (extend)

**Interfaces:**
- Consumes: `loadPaletteCards()`, `PaletteCard`, `ImageResponseBuilder.render(at:region:requestedMax:quality:) -> Rendered`, `ImageResponseBuilder.encodeEnvelope(at:region:maxDimension:quality:) -> Data`, `AnyJSON`.
- Produces: `ReadPaletteCardTool` — method `read_palette_card`, params `{project_id, card_id, image?: String, max_dimension?: Int, quality?: Int, region?: Region}`.
  - **Without `image`:** a `{"content": [...]}` envelope — first a `text` block containing the card's full markdown, then a thumbnail `image` block per card image at `requestedMax: 512` (capped at 6 images; if more, the text block ends with a note listing the omitted paths). Thumbnails at 512px JPEG q85 run ~30–120 KB each — 6 stay well under the 1 MB cap.
  - **With `image`** (one of the card's `imagePaths`): a single full-quality crop-on-demand image via `ImageResponseBuilder.encodeEnvelope(at:region:maxDimension:quality:)` — identical semantics to `read_document`'s image path.
  - Unknown `card_id` / `image` not on the card → `MCPError.invalidArgument` with a listing hint.

- [ ] **Step 1: Write the failing tests (extend `PaletteToolsTests`)**

```swift
func test_readPaletteCard_textOnly_returnsContentEnvelopeWithMarkdown() async throws {
    let (url, _, ds, reg, item) = try await makeProjectWithCard()
    let id = ProjectIdentifier.id(for: url)
    let req = "{\"project_id\":\"\(id)\",\"card_id\":\"\(item.id)\"}"
    let json = try await ReadPaletteCardTool.handle(
        paramsJSON: Data(req.utf8), registry: reg)
    let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
    XCTAssertEqual(content.count, 1)   // no images on this card → text block only
    XCTAssertEqual(content[0]["type"] as? String, "text")
    let text = try XCTUnwrap(content[0]["text"] as? String)
    XCTAssertTrue(text.contains("turpentine"))
    await ds.close()
}

func test_readPaletteCard_withImages_appendsThumbnailBlocks() async throws {
    let (url, store, ds, reg, item) = try await makeProjectWithCard()
    // Write a real image into research/ and reference it from the card.
    let imageURL = url.appendingPathComponent("research/flat.png")
    try makePNG(width: 900, height: 600).write(to: imageURL)
    let md = try String(contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
        + "\n## Images\n\n- ../flat.png\n"
    try md.data(using: .utf8)!.write(to: url.appendingPathComponent(item.path!))
    _ = store  // silence unused warning
    let id = ProjectIdentifier.id(for: url)
    let req = "{\"project_id\":\"\(id)\",\"card_id\":\"\(item.id)\"}"
    let json = try await ReadPaletteCardTool.handle(paramsJSON: Data(req.utf8), registry: reg)
    let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
    XCTAssertEqual(content.count, 2)
    XCTAssertEqual(content[0]["type"] as? String, "text")
    XCTAssertEqual(content[1]["type"] as? String, "image")
    XCTAssertEqual(content[1]["mimeType"] as? String, "image/jpeg")
    XCTAssertNotNil(content[1]["data"] as? String)
    await ds.close()
}

func test_readPaletteCard_singleImage_usesCropOnDemandEnvelope() async throws {
    let (url, _, ds, reg, item) = try await makeProjectWithCard()
    let imageURL = url.appendingPathComponent("research/flat.png")
    try makePNG(width: 900, height: 600).write(to: imageURL)
    let md = try String(contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
        + "\n## Images\n\n- ../flat.png\n"
    try md.data(using: .utf8)!.write(to: url.appendingPathComponent(item.path!))
    let id = ProjectIdentifier.id(for: url)
    let req = "{\"project_id\":\"\(id)\",\"card_id\":\"\(item.id)\",\"image\":\"research/flat.png\"}"
    let json = try await ReadPaletteCardTool.handle(paramsJSON: Data(req.utf8), registry: reg)
    let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
    XCTAssertEqual(content.last?["type"] as? String, "image")
    await ds.close()
}

func test_readPaletteCard_unknownCard_throwsInvalidArgument() async throws {
    let (url, _, ds, reg, _) = try await makeProjectWithCard()
    let id = ProjectIdentifier.id(for: url)
    let req = "{\"project_id\":\"\(id)\",\"card_id\":\"res-nope\"}"
    do {
        _ = try await ReadPaletteCardTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        XCTFail("expected throw")
    } catch let MCPError.toolError(payload) {
        XCTAssertEqual(payload.error, "invalid_argument")
    } catch MCPError.invalidArgument {
        // acceptable — MCPToolsCallHandler maps this to invalid_argument
    }
    await ds.close()
}

/// Solid-color PNG fixture (no bundled assets needed).
private func makePNG(width: Int, height: Int) -> Data {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    return rep.representation(using: .png, properties: [:])!
}
```

(Check `DocumentToolsTests.swift` first — if it already has an image-fixture helper, reuse its approach/name instead of duplicating.)

- [ ] **Step 2: Run to verify compile failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PaletteToolsTests`

- [ ] **Step 3: Implement `ReadPaletteCardTool` (append to `PaletteTools.swift`)**

```swift
import AppKit

/// read_palette_card — a card's full markdown plus its images.
/// Without `image`: text + per-image thumbnails (512px). With `image`: that one
/// image full-quality with crop-on-demand (same semantics as read_document).
public enum ReadPaletteCardTool: MCPTool {
    public static let method = "read_palette_card"
    public static let description =
        "Read one sensory-palette card: its full markdown (kind, swatches, sensory "
        + "notes) plus thumbnails of its images. Pass image (a path from the card's "
        + "image_paths) for one full-quality image, with optional region/max_dimension/"
        + "quality crop-on-demand like read_document."
    public static let inputSchemaJSON = #"""
    {"type":"object","properties":{
      "project_id":{"type":"string"},
      "card_id":{"type":"string"},
      "image":{"type":"string"},
      "max_dimension":{"type":"integer"},
      "quality":{"type":"integer"},
      "region":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}}}
    },"required":["project_id","card_id"]}
    """#

    public struct Params: Codable {
        public let project_id: String
        public let card_id: String
        public let image: String?
        public let max_dimension: Int?
        public let quality: Int?
        public let region: ImageResponseBuilder.Region?
    }

    private static let thumbnailMax = 512
    private static let maxThumbnails = 6

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        guard let card = entry.store.loadPaletteCards()
            .first(where: { $0.researchItemId == params.card_id }) else {
            throw MCPError.invalidArgument(
                "unknown card_id \(params.card_id) — call list_palette_cards for valid ids")
        }
        guard let item = entry.store.paletteCardItems()
            .first(where: { $0.id == params.card_id }), let rel = item.path else {
            throw MCPError.internalError("palette card \(params.card_id) has no path")
        }

        // Single-image full-quality path — identical semantics to read_document.
        if let imagePath = params.image {
            guard card.imagePaths.contains(imagePath) else {
                throw MCPError.invalidArgument(
                    "image \(imagePath) is not on card \(params.card_id); its images are: "
                    + card.imagePaths.joined(separator: ", "))
            }
            return try ImageResponseBuilder.encodeEnvelope(
                at: entry.url.appendingPathComponent(imagePath),
                region: params.region,
                maxDimension: params.max_dimension,
                quality: params.quality)
        }

        // Overview path: text block (full markdown) + thumbnails.
        let markdown = (try? String(
            contentsOf: entry.url.appendingPathComponent(rel),
            encoding: .utf8)) ?? "" // adr-0018-ok: palette card read, not manuscript
        var text = markdown
        let shown = card.imagePaths.prefix(maxThumbnails)
        let omitted = card.imagePaths.dropFirst(maxThumbnails)
        if !omitted.isEmpty {
            text += "\n\n[\(omitted.count) more image(s) not thumbnailed: "
                + omitted.joined(separator: ", ")
                + " — fetch each via the image parameter.]"
        }
        var blocks: [AnyJSON] = [.object(["type": .string("text"), "text": .string(text)])]
        for path in shown {
            let url = entry.url.appendingPathComponent(path)
            guard let rendered = try? ImageResponseBuilder.render(
                at: url, region: nil, requestedMax: thumbnailMax, quality: nil) else { continue }
            blocks.append(.object([
                "type": .string("image"),
                "data": .string(rendered.jpeg.base64EncodedString()),
                "mimeType": .string("image/jpeg")
            ]))
        }
        return try JSONEncoder().encode(AnyJSON.object(["content": .array(blocks)]))
    }
}
```

Match `ImageResponseBuilder.render`'s exact signature (`render(at:region:requestedMax:quality:)` per exploration; adjust labels if the real ones differ) and `AnyJSON`'s case spellings to the codebase. Add `ReadPaletteCardTool.self` to `MCPToolCatalog.all`.

- [ ] **Step 4: Run tests + catalog consistency, verify PASS**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PaletteToolsTests -only-testing:MaughamTests/MCPCatalogConsistencyTests`
Expected: PASS (7 palette-tool tests total).

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/PaletteTools.swift Maugham/MCP/MCPTool.swift MaughamTests/MCP/Tools/PaletteToolsTests.swift
git commit -m "feat(mcp): read_palette_card — markdown + thumbnails + crop-on-demand single image"
```

---

### Task 10: Sense-pass guide topic (the curated prompt template)

**Files:**
- Create: `docs/guide/sense-pass.md`
- Modify: `docs/guide/index.json` (insert entry, renumber)
- Modify: `docs/guide/claude-desktop.md` (one cross-reference line)

**Interfaces:**
- Consumes: the guide pipeline (`HelpTopicIndex`, `get_help`, drift tests — all automatic).
- Produces: slug `sense-pass`, served by Help window (⌘?) AND the `get_help` MCP tool — the single-source rule.

- [ ] **Step 1: Write `docs/guide/sense-pass.md`**

```markdown
# The Sense Pass

A **sense pass** is a revision audit: does the prose actually deliver the
sensations the story needs? It is intent-first — Claude measures your draft
against *your* declared standard, not a universal rule. A deliberately spare
story is not "missing" sensory detail.

## The three-part loop

1. **Declare** — write a *craft intent* doc: a freeform statement of what this
   piece needs. Add one from the inspector (**Add craft intent…**). Not having
   one is a valid choice; it means you've decided this piece doesn't need the
   apparatus.
2. **Gather** — build *palette cards* in the Palette segment: one card per
   location, character, or motif, holding images, colour swatches, and sensory
   notes (tagged sight / sound / smell / touch / taste). Keep a card open
   beside the editor with ⌘⌥7 while you draft.
3. **Audit** — ask Claude (via Claude Desktop + the Maugham MCP connection) to
   run the sense pass below. Claude reads your intent, your palette, and the
   manuscript, and leaves paragraph-anchored annotations you triage in the
   Annotations pane (⌘⌥A) — Accept, Reject, or Archive, as with any annotation.

## The prompt

Paste this into Claude Desktop (adjust the document name):

> Run a sense pass on **[document]** in my project **[project]**.
>
> 1. Call `read_craft_intent` first. If no intent doc exists, tell me so and
>    ask whether I want a generic pass or help drafting an intent doc — do not
>    invent a standard silently.
> 2. Call `list_palette_cards`, then `read_palette_card` for each card relevant
>    to this document (look at its locations, characters, motifs).
> 3. Read the document and audit it against my stated intent and the gathered
>    palette: Which scenes deliver the sensations I said they should? Where is
>    the prose all sight and no body? Which palette material never reached the
>    page? Where is groundedness *absent by my own design* — and therefore fine?
> 4. Leave your findings as paragraph-anchored annotations: `add_comment` for
>    observations, `add_craft_note` for reusable principles. Anchor each note
>    to the specific paragraph it concerns.

## What Claude can and cannot do

Claude reads the intent doc, palette cards (including images), and manuscript;
it writes only into the annotation layer. It never edits your manuscript, your
intent doc, or your palette — those are yours.
```

- [ ] **Step 2: Update `docs/guide/index.json`**

Insert after `claude-desktop` (order 8) and renumber the rest:

```json
  { "slug": "claude-desktop",      "title": "Writing with Claude",    "order": 8 },
  { "slug": "sense-pass",          "title": "The Sense Pass",         "order": 9 },
  { "slug": "annotations-and-suggestions", "title": "Annotations & Suggestions", "order": 10 },
  { "slug": "publishing",          "title": "Publishing to PDF & EPUB","order": 11 },
  { "slug": "reference",           "title": "Reference",              "order": 12 }
```

- [ ] **Step 3: Add one line to `docs/guide/claude-desktop.md`** (wherever tool capabilities are listed): a sentence pointing to the sense-pass topic, e.g. `For an intent-first revision audit of sensory groundedness, see **The Sense Pass**.`

- [ ] **Step 4: Run the drift + help tests, verify PASS**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/GuideDocsDriftTests -only-testing:MaughamTests/HelpTopicIndexTests -only-testing:MaughamTests/GetHelpToolTests`
Expected: PASS (index ↔ files lockstep holds).

- [ ] **Step 5: Commit**

```bash
git add docs/guide/sense-pass.md docs/guide/index.json docs/guide/claude-desktop.md
git commit -m "docs(guide): sense-pass topic — the curated prompt template"
```

---

### Task 11: Documentation sweep — AREA.md, CLAUDE.md, roadmap, spec status

**Files:**
- Modify: `Maugham/MCP/AREA.md` (tool catalogue 44 → 47: add the three tools under a "Palette / craft intent" group; update the `## Tool catalogue (44)` heading)
- Modify: `CLAUDE.md` (MCP per-area pointer row: "44 tools" → "47 tools")
- Modify: `Maugham/Stores/AREA.md` (one paragraph: palette + craft-intent seams — cards are research assets under `research/palette/`; `craft-intent.md` per scope; both plain-edited, absence-is-valid)
- Modify: `docs/roadmap.md` (Group 1 "Visual reference": mark the mood-board item shipped as this milestone, one summary line in the house style referencing the spec; note the deferred follow-ons: mechanical lint layer, freeform canvas, phone surface)
- Modify: `docs/superpowers/specs/2026-07-09-craft-intent-sensory-palette-design.md` (Status: → implemented)

- [ ] **Step 1: Make all five edits** (match each file's existing voice and table/format conventions; keep the roadmap entry to the shipped-item house style — date, one dense sentence, deferred follow-ons listed).

- [ ] **Step 2: Verify no stale counts**

Run: `grep -rn "44 tools\|catalogue (44)" CLAUDE.md Maugham/MCP/AREA.md`
Expected: no matches.

- [ ] **Step 3: Commit**

```bash
git add Maugham/MCP/AREA.md CLAUDE.md Maugham/Stores/AREA.md docs/roadmap.md docs/superpowers/specs/2026-07-09-craft-intent-sensory-palette-design.md
git commit -m "docs: palette/craft-intent milestone — AREA/CLAUDE/roadmap/spec sweep (44→47 tools)"
```

---

### Task 12: Full verification — suite, Release build, smoke checklist

**Files:** none created; this is the gate.

- [ ] **Step 1: Full Mac test suite**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: all green (including `TripwireGrepTests` and `MCPCatalogConsistencyTests`).

- [ ] **Step 2: Release build (mandatory — `ProjectWindow.body` changed)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. If the type-checker times out, extract further ViewModifiers from `ProjectWindow` and re-run.

- [ ] **Step 3: Report the manual smoke checklist to the user** (the user runs smoke tests manually — do NOT claim these verified):

1. New Novel → Palette segment → inspector auto-hides → "+ New Card" (location) → card opens → add a swatch, a tagged sense line, and an image reference → back to Wall → tile shows swatches + snippet.
2. Manuscript segment → inspector restored to its prior state → ⌘⌥7 → card renders beside the editor.
3. Inspector → "Add craft intent…" → editor opens on `research/craft-intent.md` → type intent → relaunch → content intact (750ms plain autosave).
4. Collection → loose piece → piece inspector → per-piece intent lands under `pieces/<NN>-<slug>/research/`.
5. Claude Desktop: `read_craft_intent` (absent → exists:false; present → markdown), `list_palette_cards`, `read_palette_card` (thumbnails + single-image crop), `get_help` topic `sense-pass` — then run the sense-pass prompt end-to-end and confirm annotations land in ⌘⌥A.

- [ ] **Step 4: Commit anything outstanding; hand off for merge/tag decision** (do not tag — release is the user's call; see `docs/RELEASING.md` when they ask).

---

## Plan self-review notes

- Spec coverage: intent doc (T3, T6), palette model/disk (T1, T2), wall + auto-hide (T4), right-pane mode (T5), 3 MCP tools with images (T7–T9), sense-pass template as a guide topic serving Help + `get_help` (T10), docs/tripwires/tool-count (T11), Release-build risk (T12). Out-of-scope items from the spec are untouched.
- Exact signatures for pre-existing code come from the 2026-07-09 exploration reports; where a label might drift, the task says which real file/line to match rather than guessing silently.
- Types cross-task: `PaletteCard.Kind`/`Sense`/`SensoryNote`, `loadPaletteCards()`, `paletteCardItems()`, `craftIntentItem(forPieceId:)`, `createCraftIntent(forPieceId:)` are used with identical spellings in Tasks 2–9.
