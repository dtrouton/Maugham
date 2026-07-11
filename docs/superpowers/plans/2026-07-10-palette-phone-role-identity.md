# Palette Everywhere (Role Identity + Phone) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Durable role-based identity for the palette group + craft-intent docs, PaletteCard family promoted to MaughamCore, phone palette capture (inbox additive fields + Capture aim row) and read-only phone palette browsing, Mac promote-into-card + MCP params — per spec `docs/superpowers/specs/2026-07-10-palette-phone-and-role-identity-design.md`.

**Architecture:** `ResearchItem.role: ResearchRole?` (tolerant `.unknown` decode) with role-first lookups + Mac-side lazy stamping makes renames supported. `PaletteCard`/parser/renderer + palette conventions + a pure shared `PaletteLookup` move to MaughamCore (tripwire 19). Capture rides the existing per-device inbox JSONL with two additive fields; the Mac promote seam gains a palette destination; the phone Read tab gains a Palette section mirroring the AnnotationsStore pattern with one new eviction-safe image loader.

**Tech Stack:** Swift (MaughamCore/Foundation), SwiftUI Mac + iOS, XCTest, xcodegen.

## Global Constraints

- Branch: `feat/palette-phone-role-identity` off main. `./gen.sh` after adding/moving files; never commit anything under `Maugham.xcodeproj/`.
- **MaughamCore changes → BOTH schemes tested**: Mac `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`; phone `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO` (simulator "Busy/preflight" = flake, re-run; never `simctl shutdown all`).
- **No manifest schema bump**: `role` is additive-optional (absent → nil; unknown raw → `.unknown` sentinel, matching the `ItemType`/`AssetKind` ADR-0015 pattern). Inbox fields likewise additive (synthesized decoder ⇒ missing keys → nil). `ProjectManifest.currentSchemaVersion` stays 3.
- Lazy healing, no migrations: fallback path/filename lookups stamp `role` on hit (Mac only — the phone never writes the manifest).
- Phone reads: EVERY file read = `downloads.ensureDownloaded(url)` then `io.coordinatedRead(at: url)` (AREA.md tripwire 6; `TripwirePhoneGrepTest` ADR-0018 grep fails raw reads without `// adr-0018-ok:`). Phone palette is STRICTLY read-only.
- Phone UI logic testable as pure functions + `@Observable` stores with injected deps (mirror `AnnotationsStore`/`AnnotationLoading`); UI is build-verified; on-device/simulator smoke is the phone verification of record.
- Mac tripwires 4/9/14/15 as usual; MCP promote stays within the sanctioned inbox scope (read + promote only).
- Canonical constants move to Core as `PaletteConvention` (`folderPath = "research/palette"`, `groupTitle = "Palette"`, `craftIntentFileName = "craft-intent.md"`, `craftIntentTitle = "Craft Intent"`); Mac `ProjectStore` statics become aliases to it.
- Model hints: opus = Tasks 1, 3, 5, 6, 7; sonnet = Tasks 2, 4, 8, 9; Task 10 controller-run.
- Key verified facts (2026-07-10 exploration): `ResearchItem` is synthesized-Codable with a memberwise init (trailing defaulted param = zero ripple; construction sites `ProjectStore+Research.swift:27,78,101,179`, `ProjectStore+CollectionPieces.swift:469,507,538`); Core promotion = file placement under `Packages/MaughamCore/Sources/MaughamCore/` + `./gen.sh` (no Package.swift edit), tests to `Packages/MaughamCore/Tests/MaughamCoreTests/`; `PaletteCard.swift` imports Foundation only (moves clean); consumers needing `import MaughamCore` added: `PaletteTools.swift`, `PaletteBinderList/PaletteWallView/PalettePane/PaletteCardEditor/PaletteCardTile.swift`, `MaughamTests/Views/Palette*Tests.swift`; `InboxEntry` is synthesized-Codable with explicit snake_case `CodingKeys`; phone writer chain `CaptureView` → `InboxCaptureWriter.writeText/writeImage/writeAudio` → `buildEntry`; Mac promote seam `InboxStore.promoteToResearch(_:projectStore:scope:)`; MCP tool `Maugham/MCP/Tools/InboxTools.swift` `PromoteInboxEntryTool.Params {project_id, entry_id, title?, target_document_id?}`; phone Read drill `ProjectsListView` → `BinderView` (Sections "Manuscript"/"Research"; `readableResearch = TreeWalk.leaves(in: manifest.research).filter(ReadIcons.isReadableResearch)`) → `DocumentReaderView.load()` (ensureDownloaded→coordinatedRead→MarkdownBlocks); phone has ZERO image rendering today (`MarkdownBlocks.adapt` drops `.soloImage`); phone card-title picker needs NO file reads (titles = palette group children's `ResearchItem.title` in the already-decoded manifest).

---

### Task 1: Core — ResearchRole + PaletteConvention + PaletteLookup

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ResearchItem.swift`
- Create: `Packages/MaughamCore/Sources/MaughamCore/PaletteConvention.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ResearchRoleTests.swift`

**Interfaces:**
- Produces: `ResearchRole` enum (`paletteGroup = "palette_group"`, `craftIntent = "craft_intent"`, `unknown`) with tolerant decode; `ResearchItem.role: ResearchRole?` (trailing defaulted init param, `CodingKeys` entry `role`); `PaletteConvention` statics (values in Global Constraints); `PaletteLookup.paletteGroup(in: [ResearchItem]) -> ResearchItem?` and `PaletteLookup.craftIntentItem(in: [ResearchItem], researchPrefix: String) -> ResearchItem?` — pure, role-first then path/filename fallback, NO stamping (shared by phone + Mac; Mac wraps with stamping in Task 3).

- [ ] **Step 1: Write failing tests**

```swift
// Packages/MaughamCore/Tests/MaughamCoreTests/ResearchRoleTests.swift
import XCTest
@testable import MaughamCore

final class ResearchRoleTests: XCTestCase {
    func test_legacyJSON_withoutRole_decodesNil() throws {
        let json = #"{"id":"res-1","title":"Palette","type":"group","path":"research/palette"}"#
        let item = try JSONDecoder().decode(ResearchItem.self, from: Data(json.utf8))
        XCTAssertNil(item.role)
    }

    func test_unknownRoleRawValue_decodesUnknownSentinel() throws {
        let json = #"{"id":"res-1","title":"X","type":"asset","role":"from_the_future"}"#
        let item = try JSONDecoder().decode(ResearchItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.role, .unknown)
    }

    func test_roleRoundTrips() throws {
        let item = ResearchItem(id: "res-1", title: "Palette", type: .group,
                                path: "research/palette", role: .paletteGroup)
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(ResearchItem.self, from: data)
        XCTAssertEqual(back.role, .paletteGroup)
    }

    func test_paletteLookup_roleFirst_beatsPathMatch() {
        let renamed = ResearchItem(id: "res-a", title: "Moods", type: .group,
                                   path: "research/moods", role: .paletteGroup)
        let impostor = ResearchItem(id: "res-b", title: "Palette", type: .group,
                                    path: "research/palette")
        XCTAssertEqual(PaletteLookup.paletteGroup(in: [impostor, renamed])?.id, "res-a")
    }

    func test_paletteLookup_pathFallback_whenNoRole() {
        let legacy = ResearchItem(id: "res-c", title: "Palette", type: .group,
                                  path: "research/palette")
        XCTAssertEqual(PaletteLookup.paletteGroup(in: [legacy])?.id, "res-c")
        XCTAssertNil(PaletteLookup.paletteGroup(in: []))
    }

    func test_craftIntentLookup_roleFirst_thenFilenameFallback_scoped() {
        let renamedIntent = ResearchItem(id: "res-d", title: "What this needs", type: .asset,
                                         kind: .document, path: "research/what-this-needs.md",
                                         role: .craftIntent)
        XCTAssertEqual(PaletteLookup.craftIntentItem(
            in: [renamedIntent], researchPrefix: "research").map(\.id), "res-d")
        let legacy = ResearchItem(id: "res-e", title: "Craft Intent", type: .asset,
                                  kind: .document, path: "research/craft-intent.md")
        XCTAssertEqual(PaletteLookup.craftIntentItem(
            in: [legacy], researchPrefix: "research").map(\.id), "res-e")
        // Piece-scoped doc must NOT match project scope.
        let pieceDoc = ResearchItem(id: "res-f", title: "Craft Intent", type: .asset,
                                    kind: .document,
                                    path: "pieces/01-story/research/craft-intent.md",
                                    role: .craftIntent)
        XCTAssertNil(PaletteLookup.craftIntentItem(in: [pieceDoc], researchPrefix: "research"))
        XCTAssertEqual(PaletteLookup.craftIntentItem(
            in: [pieceDoc], researchPrefix: "pieces/01-story/research").map(\.id), "res-f")
    }
}
```

- [ ] **Step 2: Run to verify red** — `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamCoreTests/ResearchRoleTests` (after `./gen.sh`; compile failure = red). (If MaughamCoreTests runs via `swift test` in the package, use `cd Packages/MaughamCore && swift test --filter ResearchRoleTests` — check how AnnotationInverseTests is run; use whichever works, state it.)

- [ ] **Step 3: Implement**

In `ResearchItem.swift`, following the `ItemType` tolerant-decode idiom exactly:

```swift
/// Marks items with app-level meaning that must survive rename/move
/// (ADR-0015-tolerant: unknown raw values decode to `.unknown`, which no
/// lookup matches — semantically equivalent to nil for old readers).
public enum ResearchRole: String, Codable, Sendable {
    case paletteGroup = "palette_group"
    case craftIntent = "craft_intent"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ResearchRole(rawValue: raw) ?? .unknown
    }
}
```

Add `public var role: ResearchRole?` to the stored properties and `role: ResearchRole? = nil` as the LAST init param (zero call-site ripple). If the struct has an explicit `CodingKeys` enum add `role`; if keys are synthesized, nothing more.

`PaletteConvention.swift`:

```swift
import Foundation

/// Canonical palette/craft-intent conventions shared by Mac and phone
/// (tripwire 19). Path/filename are the LEGACY identity fallbacks; role
/// (`ResearchItem.role`) is the durable identity.
public enum PaletteConvention {
    public static let folderPath = "research/palette"
    public static let groupTitle = "Palette"
    public static let craftIntentFileName = "craft-intent.md"
    public static let craftIntentTitle = "Craft Intent"
}

/// Pure role-first lookups (no stamping — Mac wraps these with lazy healing;
/// the phone uses them read-only).
public enum PaletteLookup {
    public static func paletteGroup(in research: [ResearchItem]) -> ResearchItem? {
        if let byRole = research.first(where: { $0.type == .group && $0.role == .paletteGroup }) {
            return byRole
        }
        return research.first { $0.type == .group && $0.path == PaletteConvention.folderPath }
    }

    public static func craftIntentItem(
        in research: [ResearchItem], researchPrefix: String
    ) -> ResearchItem? {
        let prefix = researchPrefix.hasSuffix("/") ? researchPrefix : researchPrefix + "/"
        let scoped = TreeWalk.collect(in: research) { item in
            item.type == .asset && (item.path?.hasPrefix(prefix) ?? false)
        }
        if let byRole = scoped.first(where: { $0.role == .craftIntent }) { return byRole }
        return scoped.first { ($0.path as NSString?)?.lastPathComponent == PaletteConvention.craftIntentFileName }
    }
}
```

Note: `paletteGroup` searches TOP-LEVEL research only (matches Mac's current `manifest.research.first` semantics); `craftIntentItem` deep-collects because piece docs nest. Verify `TreeWalk.collect(in:where:)`'s exact signature and `NSString` availability in Core (Foundation — fine).

- [ ] **Step 4: Run green**, then BOTH full schemes (Core changed): Mac + phone commands from Global Constraints.
- [ ] **Step 5: Commit** `feat(core): ResearchRole + PaletteConvention + shared PaletteLookup`

---

### Task 2: Core move — PaletteCard family to MaughamCore

**Files:**
- Move: `Maugham/Models/PaletteCard.swift` → `Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift`
- Move: `MaughamTests/PaletteCardParserTests.swift` + `MaughamTests/PaletteCardRendererTests.swift` → `Packages/MaughamCore/Tests/MaughamCoreTests/` (change `@testable import Maugham` → `@testable import MaughamCore`)
- Modify (add `import MaughamCore`): `Maugham/MCP/Tools/PaletteTools.swift`, `Maugham/Views/Palette/PaletteBinderList.swift`, `PaletteWallView.swift`, `PalettePane.swift`, `PaletteCardEditor.swift`, `PaletteCardTile.swift`, `MaughamTests/Views/PaletteCardEditorTests.swift`, `PaletteCardTileTests.swift`, `PalettePaneTests.swift` (and `MCPTool.swift` only if it references the types — check)
- Modify: `docs/superpowers/notes/cross-surface-contracts.md` (new registry row: palette card model/parse/render — shared-impl tier, single MaughamCore implementation)
- Modify: `Maugham/Stores/ProjectStore+Palette.swift` + `ProjectStore+CraftIntent.swift`: statics become aliases (`public static let paletteFolderPath = PaletteConvention.folderPath` etc.) so existing call sites keep compiling.

**Interfaces:**
- Consumes: Task 1 (`PaletteConvention`).
- Produces: `PaletteCard`/`PaletteCardParser`/`PaletteCardRenderer` importable from MaughamCore, identical API (names kept, per house precedent — MarkdownDisplayFilter/AnnotationInverse).

- [ ] **Step 1: Move the files** (git mv), flip test imports, add consumer imports, alias the constants. NO behavior change anywhere — this is a pure relocation; any diff beyond imports/paths/aliases is scope creep.
- [ ] **Step 2: `./gen.sh`, run the moved tests** (`-only-testing:MaughamCoreTests/PaletteCardParserTests -only-testing:MaughamCoreTests/PaletteCardRendererTests` via the Mac scheme, or `swift test` per Task 1's finding) — all 15 green unchanged.
- [ ] **Step 3: FULL Mac suite + FULL phone suite** (Core changed; phone now compiles the moved file — its grep tripwires walk `MaughamPhone/` only, but the file must build for iOS: it imports Foundation only, verified).
- [ ] **Step 4: Commit** `refactor(core): PaletteCard family → MaughamCore (tripwire 19; registry row)`

---

### Task 3: Mac — role-first lookups, lazy stamping, rename support, title display

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Palette.swift` (`paletteGroup()`, `ensurePaletteGroup()`), `Maugham/Stores/ProjectStore+CraftIntent.swift` (`craftIntentItem(forPieceId:)`, `createCraftIntent(forPieceId:)`)
- Modify: `Maugham/Views/Palette/PaletteWallView.swift` + `PaletteBinderList.swift` (header showing the group's actual title)
- Test: `MaughamTests/ProjectStorePaletteTests.swift`, `MaughamTests/ProjectStoreCraftIntentTests.swift` (extend)

**Interfaces:**
- Consumes: `PaletteLookup`, `PaletteConvention` (Task 1); existing `updateResearchItem(id:title:)` rename machinery.
- Produces: `paletteGroup()` = `PaletteLookup.paletteGroup(in: manifest.research)` + lazy stamp; `ensurePaletteGroup()` stamps `role = .paletteGroup` on create AND on legacy-heal; `craftIntentItem(forPieceId:)` role-first via `PaletteLookup.craftIntentItem(in:researchPrefix:)` + lazy stamp; `createCraftIntent` stamps on create. New: `ProjectStore.paletteGroupDisplayTitle: String` (the group's live title, falling back to `PaletteConvention.groupTitle`). Wall/sidebar show it as a small header.

Lazy stamping shape (both lookups): when the role-first pass misses but the fallback hits, mutate the found item's `role` in the manifest (via the store's existing `mutateItem`-style manifest mutation + `saveManifest()`), fire-and-forget (`Task { }`) so the lookup itself stays synchronous and read-shaped — OR make the lookup `@discardableResult`-mutating where call sites allow async. Choose the simplest shape that keeps `paletteGroup()`'s synchronous signature (existing callers are sync); a deferred `Task { await self.stampRole(...) }` from within the sync lookup is acceptable; guard against double-stamping.

- [ ] **Step 1: Failing tests** (extend both test classes):

```swift
func test_paletteGroup_survivesRename_andStampsLegacy() async throws {
    let (_, store, ds) = try await makeNovel()
    let group = try await store.ensurePaletteGroup()
    XCTAssertEqual(group.role, .paletteGroup)          // stamped at creation
    _ = try await store.addPaletteCard(title: "The Flat", kind: .location)
    try await store.updateResearchItem(id: group.id, title: "Moods")
    XCTAssertEqual(store.paletteGroup()?.id, group.id) // role survives rename
    XCTAssertEqual(store.loadPaletteCards().count, 1)  // wall still finds cards
    let again = try await store.ensurePaletteGroup()
    XCTAssertEqual(again.id, group.id)                 // no duplicate group minted
    await ds.close()
}

func test_legacyPaletteGroup_getsLazilyStamped() async throws {
    let (_, store, ds) = try await makeNovel()
    // Simulate a v0.19.0 project: group exists with path identity, no role.
    let legacy = try await store.addResearchItem(parentId: nil, title: "Palette", kind: nil)
    XCTAssertNil(legacy.role)
    let found = store.paletteGroup()
    XCTAssertEqual(found?.id, legacy.id)
    // Allow the deferred stamp to land, then verify persisted.
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(TreeWalk.find(id: legacy.id, in: store.manifest.research)?.role, .paletteGroup)
    await ds.close()
}
```

Mirror both for craft intent (`craftIntentItem` survives note rename via `updateResearchItem(id:title:"What this story needs")`; legacy stamp test). Match real helper names.

- [ ] **Step 2: Red** → **Step 3: Implement** per Interfaces (aliased constants from Task 2 already point at `PaletteConvention`). Wall/sidebar header: a `Text(store.paletteGroupDisplayTitle).font(.headline)` row atop `PaletteWallView` (above the grid, respecting tripwire 15 outer framing) and as `PaletteBinderList`'s list header.
- [ ] **Step 4: Focused green → FULL Mac suite** (no Core change in this task → phone not required).
- [ ] **Step 5: Commit** `feat(palette): role-first identity — rename-proof group/intent lookups + lazy healing + live title`

---

### Task 4: Core — inbox palette fields + phone writer params

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxEntry.swift`
- Modify: `MaughamPhone/Capture/InboxCaptureWriter.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/SchemaEvolutionToleranceTests.swift` (extend), `MaughamPhoneTests/InboxCaptureWriterTests.swift` (extend)

**Interfaces:**
- Produces: `InboxEntry.paletteSubject: String?` + `InboxEntry.sense: String?` (stored props + `CodingKeys` entries `palette_subject`/`sense`; synthesized decoder handles legacy lines → nil). `InboxCaptureWriter.writeText/writeImage/writeAudio` gain trailing `paletteSubject: String? = nil, sense: String? = nil` params threaded through `buildEntry`.

- [ ] **Step 1: Failing tests** — Core: decode a legacy JSONL line (no new keys) → nils; round-trip a stamped entry through `JSONLAppendStore` encode/decode. Phone: `test_writeText_withPaletteAim_roundTripsThroughMacReader` — write with `paletteSubject: "The Flat", sense: "smell"`, read back via `JSONLAppendStore<InboxEntry>.load()`, assert both fields; and an unaimed write still round-trips with nils.
- [ ] **Step 2: Red** → **Step 3: Implement** (fields last in the struct; CodingKeys snake_case; writer params default nil = zero ripple at existing call sites).
- [ ] **Step 4: BOTH full schemes** (Core changed).
- [ ] **Step 5: Commit** `feat(inbox): additive palette aim fields (palette_subject, sense) + phone writer plumbing`

---

### Task 5: Phone — Capture aim row

**Files:**
- Modify: `MaughamPhone/Capture/CaptureView.swift` (+ the three sheets only if the aim state is passed per-sheet — prefer CaptureView-level state threaded into `recordCapture`/writer calls)
- Create: `MaughamPhone/Capture/PaletteAimPicker.swift` (subject picker sheet: project's card titles + free-text new subject + optional sense chip)
- Test: `MaughamPhoneTests/PaletteAimTests.swift` (pure helpers)

**Interfaces:**
- Consumes: `PaletteLookup.paletteGroup(in:)` (Task 1) — card titles = the group's `.document` children's `ResearchItem.title` values from `selectedProject.manifest.research` (NO file reads); `InboxCaptureWriter` palette params (Task 4).
- Produces: `PaletteAim` value (`struct PaletteAim: Equatable { var subject: String; var sense: String? }`), `@State private var paletteAim: PaletteAim?` on CaptureView (nil = plain inbox, the default — aiming NEVER required); a compact aim row under the project pill ("Aim: Inbox ▾" / "Aim: 🎨 The Flat · smell ▾") opening `PaletteAimPicker`; pure helper `PaletteAimPicker.cardTitles(in research: [ResearchItem]) -> [String]` (tested).

Behavior: aim persists across captures within the session (deliberate — you're often gathering for one subject), resets on project change. Each capture threads `paletteAim?.subject`/`paletteAim?.sense` into the writer call. Sense chips use the five raw values (`sight/sound/smell/touch/taste`) — plain strings on the phone; the Mac maps them to `PaletteCard.Sense` at promote time (tolerant).

- [ ] **Step 1: Failing pure-helper tests** (`cardTitles` filters `.asset && .document` children of the role-first group, preserves manifest order; empty when no group).
- [ ] **Step 2: Red** → **Step 3: Implement** (mirror `ProjectPickerSheet`'s sheet idiom; `@Observable`-free — plain `@State` since state is view-local; reset via `.onChange(of: currentProjectId)`).
- [ ] **Step 4: Phone suite green** (+ Mac compiles untouched — no Mac change).
- [ ] **Step 5: Commit** `feat(phone): palette aim row on Capture — subject picker + sense chip, never required`

---

### Task 6: Phone — Read tab Palette section + card view + intent row

**Files:**
- Modify: `MaughamPhone/Read/BinderView.swift` (new `Section("Palette")`; EXCLUDE palette-group descendants from the existing Research section to kill the current duplication)
- Create: `MaughamPhone/Read/PaletteLoading.swift` (pure: section model from manifest + parsed card from text), `MaughamPhone/Read/PaletteCardView.swift` (read-only card: swatches, sense-grouped notes, body, images), `MaughamPhone/Read/PhoneImageLoader.swift` (the ONE new substrate piece: eviction-safe image load)
- Modify: `MaughamPhone/Read/ReadIcons.swift` (kind icons — reuse the Mac's SF-symbol names: location `mappin.and.ellipse`, character `person`, motif `sparkles`, other `square.grid.2x2`)
- Test: `MaughamPhoneTests/PaletteLoadingTests.swift`

**Interfaces:**
- Consumes: `PaletteLookup`/`PaletteConvention` (Task 1); `PaletteCard`/`PaletteCardParser` from Core (Task 2); `DownloadCoordinator.ensureDownloaded`, `CoordinatedFileIO.coordinatedRead` (existing); `MarkdownBlocks` (for the craft-intent doc and card body rendering).
- Produces: `PaletteLoading.paletteCards(in research: [ResearchItem]) -> [ResearchItem]` (the group's `.document` children, manifest order — pure, tested); `PaletteLoading.excludingPalette(_ leaves: [ResearchItem], research: [ResearchItem]) -> [ResearchItem]` (filters palette-group descendants + the craft-intent item out of `readableResearch` — pure, tested); `PhoneImageLoader.load(_ url: URL, downloads: DownloadCoordinator, io: CoordinatedFileIO) async throws -> UIImage?` (ensureDownloaded → coordinatedRead → `UIImage(data:)` — the coordinatedRead path needs NO adr-0018 annotation); `PaletteCardView(project: BrowsedProject, item: ResearchItem, downloads:, io:)`.

Behavior:
- `BinderView`: `Section("Palette")` appears only when `PaletteLookup.paletteGroup(in:)` finds a group; rows = card titles with kind icon (kind requires parsing the FILE — too heavy for the list; use a generic palette icon per row instead, kind appears in the detail view. State this tradeoff in code comment). A **Craft Intent** row appears when `PaletteLookup.craftIntentItem(in: manifest.research, researchPrefix: "research")` hits (project scope only per spec) — opens `DocumentReaderView` on that path (it's plain markdown; existing reader just works).
- `PaletteCardView.load()`: mirrors `DocumentReaderView.load()` exactly (downloading state, ensureDownloaded, coordinatedRead, decode) then `PaletteCardParser.parse(markdown:itemId:fallbackTitle:cardDirectory:)`; renders title+kind, swatch strip (Color from `PaletteCard.color(fromHex:)`), sense-grouped notes (group with `Sense.allCases` order, untagged last — reuse the grouping shape from Mac's `PalettePane.groupedNotes` but implement locally as a pure fn in `PaletteLoading`, tested; the Mac static is app-target, not Core), body via `MarkdownBlocks.parse`, images via `PhoneImageLoader` in a `.task` (progressive: text first, images as they arrive; eviction-tolerant — a failed image shows a placeholder, never an error screen).
- Recents: `recents.recordOpen(project.id)` like BinderView does.

- [ ] **Step 1: Failing pure tests** (`paletteCards` order/filter; `excludingPalette` removes group descendants + intent doc but keeps ordinary research; `groupedNotes` phone twin).
- [ ] **Step 2: Red** → **Step 3: Implement**.
- [ ] **Step 4: Phone suite green (incl. `TripwirePhoneGrepTest` — the image loader MUST route through `coordinatedRead`); Mac suite untouched-but-run once** (BinderView shares no Mac code; cheap insurance).
- [ ] **Step 5: Commit** `feat(phone): Read-tab Palette section — card view, sense groups, eviction-safe images, intent row`

---

### Task 7: Mac — promote into palette card

**Files:**
- Modify: `Maugham/Stores/InboxStore.swift` (new `promoteToPaletteCard`)
- Modify: `Maugham/Views/InboxPane.swift` (context-menu destinations), Create: `Maugham/Views/PalettePickerSheet.swift` (card picker + New Card, subject preselect)
- Test: `MaughamTests/InboxPromoteTests.swift` (extend) + `MaughamTests/InboxPalettePromoteRoundTripTests.swift` (the cross-surface integration test)

**Interfaces:**
- Consumes: `store.paletteCardItems()`, `store.addPaletteCard(title:kind:)`, `store.updatePaletteCard(_:)`, `store.addImage(toPaletteCard:fileURL:)` (existing Mac palette seam); `InboxEntry.paletteSubject/sense` (Task 4); `PaletteCard.Sense(rawValue:)`.
- Produces:
```swift
@discardableResult
func promoteToPaletteCard(
    _ entry: InboxEntry, projectStore: ProjectStore, cardId: String
) async throws -> PaletteCard
```
Behavior by kind: `.text` → append `SensoryNote(sense: entry.sense.flatMap(PaletteCard.Sense.init(rawValue:)), text: <inlineText first line-joined>)` via `updatePaletteCard`; `.audio` → same using `entry.transcript ?? ""` (empty transcript → throw `InboxError`-family "nothing to promote yet"); `.image` → `addImage(toPaletteCard:fileURL: assetURL)` then `removeItem` on the inbox original (mirror the move semantics of `promoteToResearch`'s asset path). All: `updateStatus(id:to:.promoted)`. Unknown cardId propagates the palette seam's throw.
- InboxPane menu gains: **"Promote to Palette Card…"** (opens `PalettePickerSheet`) and, when `entry.paletteSubject` case-insensitively matches an existing card title, a direct **"Promote to Palette: <title>"** item. `PalettePickerSheet`: searchable card list (preselect subject match), "New Card '<subject>'…" row when a subject exists but matches nothing (mints via `addPaletteCard(title: subject, kind: .other)` then promotes).

- [ ] **Step 1: Failing tests** — extend `InboxPromoteTests` with: text+sense → tagged note lands on card + entry promoted; image → file lands in card `_assets` + inbox original gone; audio with transcript → untagged/tagged note; audio without transcript → throws, entry stays `.new`. Round-trip integration test (`InboxPalettePromoteRoundTripTests`): build a PHONE-shaped entry (use `InboxCaptureWriter`-equivalent fields incl. `palette_subject`/`sense` written via `JSONLAppendStore` seed idiom from `InboxPromoteTests.seed`), promote via the new API, then `store.loadPaletteCards()` re-parses and the note/image is present — the tripwire-19 safety net.
- [ ] **Step 2: Red** → **Step 3: Implement** → **Step 4: Focused + FULL Mac suite green.**
- [ ] **Step 5: Commit** `feat(inbox): promote into palette card — text/audio→sensory note, image→image well, subject preselect`

---

### Task 8: MCP — promote_inbox_entry palette destination

**Files:**
- Modify: `Maugham/MCP/Tools/InboxTools.swift` (`PromoteInboxEntryTool`)
- Test: `MaughamTests/MCP/Tools/InboxToolsTests.swift` (extend)

**Interfaces:**
- Consumes: `promoteToPaletteCard` (Task 7); `paletteCardItems()`.
- Produces: `Params` gains `palette_card_id: String?` and `palette_subject: String?` (mutually exclusive with `target_document_id` and with each other — violations → `MCPError.invalidArgument` naming the conflict). `palette_card_id` → direct promote; `palette_subject` → case-insensitive title match (no match → invalidArgument listing existing card titles; the tool does NOT mint cards — creation stays a writer decision in the UI). Result unchanged for research promotes; palette promotes return `{research_id: cardId, title: cardTitle, path: cardPath}` (reusing the Result shape — document in the tool description). Description updated; `list_inbox` Summary gains `palette_subject`/`sense` passthrough (additive).

- [ ] **Step 1: Failing tests** (palette_card_id promote lands note; palette_subject match; subject no-match → invalidArgument with titles; exclusivity violations; legacy call with neither still promotes to research).
- [ ] **Step 2: Red** → **Step 3: Implement** → **Step 4: Focused + `MCPCatalogConsistencyTests` + the two pinned catalog tests UNCHANGED (no new tool — params only; verify the pinned name-set tests still pass untouched).**
- [ ] **Step 5: Commit** `feat(mcp): promote_inbox_entry palette destination (palette_card_id / palette_subject)`

---

### Task 9: Docs sweep

**Files:** `docs/guide/sense-pass.md` (+ "from your phone" paragraph: aim captures at a subject, browse the palette in Read, triage the sense pass in Annotations — describe what SHIPS, verify against code), `Maugham/MCP/AREA.md` (promote tool params note; tool count UNCHANGED at 47), `Maugham/Stores/AREA.md` (role identity + promote-to-card), `MaughamPhone/AREA.md` (Palette section, aim row, image loader seam), `docs/superpowers/notes/cross-surface-contracts.md` (verify Task 2's row present; add inbox palette-fields row — contracted-divergence tier: phone writes raw sense strings, Mac maps tolerantly), `docs/roadmap.md` (shipped entry; resolve the palette-group rename deferred item), spec Status → Implemented.

- [ ] **Step 1: Make the edits** (each file's voice; docs describe what ships).
- [ ] **Step 2: `-only-testing:MaughamTests/GuideDocsDriftTests` green; grep no stale claims** (`grep -rn "rename" docs/guide/sense-pass.md` sanity).
- [ ] **Step 3: Commit** `docs: palette-everywhere sweep — role identity, phone capture/read, promote params`

---

### Task 10: Verification (controller-run)

- [ ] FULL Mac suite → TEST SUCCEEDED.
- [ ] FULL phone suite → TEST SUCCEEDED (re-run on simulator Busy flake).
- [ ] Mac Release build → BUILD SUCCEEDED (wall/sidebar header touched view code; cheap insurance regardless).
- [ ] Report the manual smoke checklist (user runs; paired-release decision after):
  1. Mac: rename the Palette group to "Moods" via Research → wall keeps cards, header says "Moods", "+ New Card" adds to the same group. Rename the intent doc → inspector still shows "Open Craft Intent".
  2. Mac: open a v0.19.0-era project (no roles) → wall works immediately; rename survives thereafter (lazy stamp).
  3. Phone: Read → project → Palette section lists cards; card shows swatches/notes/body/images (try one evicted image); Craft Intent row renders.
  4. Phone: Capture → aim at "The Flat" + smell → dictate a line; snap a photo aimed at a new subject "Harbour".
  5. Mac: Inbox shows both; "Promote to Palette: The Flat" lands the tagged note; the photo's subject offers "New Card 'Harbour'…" → card minted with image.
  6. Claude Desktop: `promote_inbox_entry` with `palette_subject`; `list_inbox` shows the aim fields.
  7. Regression: unaimed captures promote to research exactly as before.
- [ ] After user smoke: merge/tag decision — paired release Mac v0.20.0 + phone-v0.6.0 (write both release-notes files first per `docs/RELEASING.md`; phone pipeline via `cut-phone-release.sh`).

## Plan self-review notes

- Spec coverage: Component 1 → Tasks 1+3; Component 2 → Task 2; Component 3 → Tasks 4+5; Component 4 → Task 6; Component 5 → Task 7 (+8 for MCP); Component 6 → Task 9; paired release → Task 10. Phone card editing, fifth tab, per-piece phone intent: correctly absent.
- The duplication fix (palette cards currently flattened into the phone's Research section) is owned by Task 6's `excludingPalette`.
- Type consistency: `PaletteAim`, `PaletteLookup.paletteGroup(in:)`, `promoteToPaletteCard(_:projectStore:cardId:)`, `PhoneImageLoader.load` spelled identically at production and consumption sites.
- Both-scheme runs are mandatory in Tasks 1, 2, 4 (Core changes); Mac-only for 3, 7, 8; phone-only focus for 5, 6 (with one cheap Mac run in 6).
