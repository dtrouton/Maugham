# Scoped Research Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make structural (containment) research associations visible everywhere — right pane, inbox promotion, MCP — via one typed `ResearchScope` routing seam, with zero data-model changes.

**Architecture:** A new `ResearchScope` enum + `ProjectStore` extension (`Maugham/Stores/ResearchScope.swift`) owns (a) scope-routed creation (collection piece → containment folder; novel chapter → shared + `linkedResearchIds`; single-doc → shared) and (b) derived-association lookup (`derivedResearchItems`). `LinkedResearchPane`, `CollectionResearchPane`, `InboxStore.promoteToResearch`, `PromoteInboxEntryTool`, and `ListAllLinksTool` all route through it.

**Tech Stack:** Swift / SwiftUI / AppKit, XCTest. Mac target only (`Maugham/` + `MaughamTests/`) — **no MaughamCore changes**.

**Spec:** `docs/superpowers/specs/2026-07-07-scoped-research-design.md`

## Global Constraints

- Run `./gen.sh` after adding any new source file (`Maugham.xcodeproj/` is generated; never commit it or edit `project.pbxproj`).
- Test command: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (append `-only-testing:MaughamTests/<Class>` for one class). Simulator "Busy" failures are flakes — re-run.
- Fail loudly on unknown/invalid ids — never silently fall back to `.shared` (spec Error handling; publishing-namespace-footgun lesson).
- No raw manuscript `.md`/`.fountain` reads as truth (tripwire 20) — nothing in this plan reads manuscript files; research-note file writes are fine (research is not op-log-backed).
- Empty-state panes need `ContentUnavailableView` + outer `.frame(maxWidth: .infinity, maxHeight: .infinity)` (tripwire 15) — `LinkedResearchPane` already complies; keep it.
- Test paragraph-ID tripwire 8 does not apply (no `.md` ↔ op log boundary crossed).
- Commit style: conventional commits (`feat:`, `test:`, `refactor:`, `docs:`), trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `ResearchScope` seam — routing, scoped creation, derivation

**Files:**
- Create: `Maugham/Stores/ResearchScope.swift`
- Test: `MaughamTests/ResearchScopeTests.swift`

**Interfaces:**
- Consumes (existing `ProjectStore` API): `addResearchTextNote(parentId:title:)`, `addResearchAsset(parentId:fromURL:)`, `addResearchLink(parentId:title:url:)`, `addPieceResearchNote(pieceId:title:)`, `addPieceResearchAsset(pieceId:fromURL:)`, `addPieceResearchLink(pieceId:title:url:)`, `linkResearch(researchId:toDocumentId:)`, `manifest`, `TreeWalk.collect`, `ProjectStoreError.fileSystemError`.
- Produces (used by Tasks 2–6):
  - `public enum ResearchScope: Equatable { case shared; case document(String) }`
  - `ProjectStore.createResearchNote(scope: ResearchScope, title: String = "Untitled Note") async throws -> ResearchItem`
  - `ProjectStore.createResearchAsset(scope: ResearchScope, fromURL: URL) async throws -> ResearchItem`
  - `ProjectStore.createResearchLink(scope: ResearchScope, title: String, url: String) async throws -> ResearchItem`
  - `ProjectStore.derivedResearchItems(forDocumentId: String) -> [ResearchItem]`
  - `ProjectStore.linkableResearchItems(forDocumentId: String) -> [ResearchItem]`
  - `ProjectStore.isResearchScopeTarget(_ docId: String) -> Bool`
  - `ProjectStore.researchScopeTargets() -> [StructureItem]`
  - `static ProjectStore.pieceResearchPrefix(for piece: StructureItem) -> String?`

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/ResearchScopeTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ResearchScopeTests: XCTestCase {

    // MARK: - Fixtures

    /// Hand-built single-chapter project (LinkedResearchTests pattern) with one
    /// shared research item, for novel / shortStory / screenplay cases.
    private func makeProject(type: ProjectType) async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scope-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "Chapter 1 content\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "Sarah\n".write(
            to: tmp.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Chapter 1", type: .document,
            path: "manuscript/c1.md")
        let sarah = ResearchItem(
            id: "res-sarah", title: "Sarah", type: .asset, kind: .document,
            path: "research/sarah.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        return (tmp, store)
    }

    /// Real collection with one loose piece (PieceResearchTests pattern).
    private func makeCollection() async throws -> (URL, ProjectStore, StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopeColl-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, piece)
    }

    // MARK: - createResearchNote routing

    func test_note_collectionPiece_landsInPieceFolder_noLink() async throws {
        let (_, store, piece) = try await makeCollection()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Sarah Notes")
        XCTAssertTrue(note.path?.hasPrefix("pieces/01-story-a/research/") == true,
                      "got: \(note.path ?? "nil")")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: piece.id), [],
                       "containment must not also write linkedResearchIds")
    }

    func test_note_novelChapter_sharedPlusLink() async throws {
        let (_, store) = try await makeProject(type: .novel)
        let note = try await store.createResearchNote(
            scope: .document("ch-1"), title: "Backstory")
        XCTAssertTrue(note.path?.hasPrefix("research/") == true,
                      "got: \(note.path ?? "nil")")
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: "ch-1").contains(note.id))
    }

    func test_note_shortStory_sharedOnly_noLink() async throws {
        let (_, store) = try await makeProject(type: .shortStory)
        let note = try await store.createResearchNote(
            scope: .document("ch-1"), title: "Backstory")
        XCTAssertTrue(note.path?.hasPrefix("research/") == true)
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [],
                       "single-doc derivation covers it; no redundant link")
    }

    func test_note_sharedScope_matchesLegacyBehavior() async throws {
        let (_, store) = try await makeProject(type: .novel)
        let note = try await store.createResearchNote(scope: .shared, title: "Loose Idea")
        XCTAssertTrue(note.path?.hasPrefix("research/") == true)
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [])
    }

    func test_note_unknownDocId_throws() async throws {
        let (_, store) = try await makeProject(type: .novel)
        do {
            _ = try await store.createResearchNote(scope: .document("nope"), title: "x")
            XCTFail("expected throw")
        } catch { /* expected — fail loudly, never fall back to shared */ }
    }

    func test_note_collectionReferencePiece_throws() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopeRef-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let ref = StructureItem(
            id: "ref-1", title: "Elsewhere", type: .document,
            path: nil, pieceKind: .reference)
        let manifest = ProjectManifest(
            type: .collection, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ref], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        do {
            _ = try await store.createResearchNote(scope: .document("ref-1"), title: "x")
            XCTFail("expected throw for reference piece")
        } catch { /* expected */ }
        XCTAssertFalse(store.isResearchScopeTarget("ref-1"))
    }

    // MARK: - createResearchLink routing

    func test_link_collectionPiece_syntheticPathUnderPieceFolder() async throws {
        let (_, store, piece) = try await makeCollection()
        let link = try await store.createResearchLink(
            scope: .document(piece.id), title: "Wiki", url: "https://example.com")
        XCTAssertTrue(link.path?.hasPrefix("pieces/01-story-a/research/") == true,
                      "got: \(link.path ?? "nil")")
        XCTAssertEqual(link.kind, .link)
    }

    // MARK: - derivedResearchItems

    func test_derived_collectionPiece_returnsContainmentItems() async throws {
        let (_, store, piece) = try await makeCollection()
        let note = try await store.addPieceResearchNote(pieceId: piece.id, title: "Owned")
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")
        let derived = store.derivedResearchItems(forDocumentId: piece.id)
        XCTAssertEqual(derived.map(\.id), [note.id])
    }

    func test_derived_novelChapter_isEmpty() async throws {
        let (_, store) = try await makeProject(type: .novel)
        XCTAssertEqual(store.derivedResearchItems(forDocumentId: "ch-1"), [])
    }

    func test_derived_singleDoc_returnsAllAssets() async throws {
        let (_, store) = try await makeProject(type: .screenplay)
        let derived = store.derivedResearchItems(forDocumentId: "ch-1")
        XCTAssertEqual(derived.map(\.id), ["res-sarah"])
    }

    // MARK: - linkableResearchItems (picker exclusion)

    func test_linkable_excludesDerivedItems() async throws {
        let (_, store, piece) = try await makeCollection()
        let owned = try await store.addPieceResearchNote(pieceId: piece.id, title: "Owned")
        let shared = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")
        let linkable = store.linkableResearchItems(forDocumentId: piece.id)
        XCTAssertFalse(linkable.contains { $0.id == owned.id },
                       "derived items must not be offered for linking")
        XCTAssertTrue(linkable.contains { $0.id == shared.id })
    }

    // MARK: - researchScopeTargets

    func test_scopeTargets_novel_listsDocuments() async throws {
        let (_, store) = try await makeProject(type: .novel)
        XCTAssertEqual(store.researchScopeTargets().map(\.id), ["ch-1"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ResearchScopeTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `createResearchNote`, `derivedResearchItems`, etc. not found.

- [ ] **Step 3: Write the implementation**

Create `Maugham/Stores/ResearchScope.swift`:

```swift
import Foundation
import MaughamCore

/// Where a new research item lands (typed cross-area seam, ADR 0010 pattern).
/// `.document` routes by project type — collection loose piece → the piece's
/// research/ folder (containment: travels on promotion, ADR-free portability);
/// novel chapter → shared research + `linkedResearchIds`; single-doc types →
/// shared research (derivation already surfaces everything as the document's).
/// Spec: docs/superpowers/specs/2026-07-07-scoped-research-design.md
public enum ResearchScope: Equatable {
    case shared
    case document(String)
}

extension ProjectStore {

    /// How `.document(id)` routes for this project. Throws on ids that are
    /// not valid targets (unknown, groups, collection reference pieces) —
    /// never falls back to `.shared` silently.
    enum ResearchRouting: Equatable {
        case pieceFolder(pieceId: String)
        case sharedPlusLink(documentId: String)
        case sharedOnly
    }

    func researchRouting(forDocumentId docId: String) throws -> ResearchRouting {
        guard let item = TreeWalk.collect(
            in: manifest.structure, where: { $0.id == docId }).first else {
            throw ProjectStoreError.fileSystemError(
                "Unknown research target document: \(docId)")
        }
        guard item.type == .document else {
            throw ProjectStoreError.fileSystemError(
                "Research target must be a document, not a group: \(docId)")
        }
        switch manifest.type {
        case .collection:
            guard item.pieceKind == .loose else {
                throw ProjectStoreError.fileSystemError(
                    "Referenced pieces keep research in their own project: \(docId)")
            }
            return .pieceFolder(pieceId: docId)
        case .novel:
            return .sharedPlusLink(documentId: docId)
        case .shortStory, .screenplay:
            return .sharedOnly
        case .unknown:
            throw ProjectStoreError.fileSystemError(
                "Cannot scope research in a project of unknown type")
        }
    }

    /// True when `docId` is a valid `.document` research-scope target.
    public func isResearchScopeTarget(_ docId: String) -> Bool {
        (try? researchRouting(forDocumentId: docId)) != nil
    }

    /// All valid `.document` scope targets (drives the promote-target picker).
    public func researchScopeTargets() -> [StructureItem] {
        TreeWalk.collect(in: manifest.structure, where: { $0.type == .document })
            .filter { isResearchScopeTarget($0.id) }
    }

    // MARK: - Scoped creation

    private func route(
        _ scope: ResearchScope,
        shared: () async throws -> ResearchItem,
        piece: (String) async throws -> ResearchItem
    ) async throws -> ResearchItem {
        switch scope {
        case .shared:
            return try await shared()
        case .document(let docId):
            switch try researchRouting(forDocumentId: docId) {
            case .pieceFolder(let pieceId):
                return try await piece(pieceId)
            case .sharedPlusLink(let documentId):
                let item = try await shared()
                try await linkResearch(researchId: item.id, toDocumentId: documentId)
                return item
            case .sharedOnly:
                return try await shared()
            }
        }
    }

    @discardableResult
    public func createResearchNote(
        scope: ResearchScope, title: String = "Untitled Note"
    ) async throws -> ResearchItem {
        try await route(scope,
            shared: { try await addResearchTextNote(parentId: nil, title: title) },
            piece: { try await addPieceResearchNote(pieceId: $0, title: title) })
    }

    @discardableResult
    public func createResearchAsset(
        scope: ResearchScope, fromURL sourceURL: URL
    ) async throws -> ResearchItem {
        try await route(scope,
            shared: { try await addResearchAsset(parentId: nil, fromURL: sourceURL) },
            piece: { try await addPieceResearchAsset(pieceId: $0, fromURL: sourceURL) })
    }

    @discardableResult
    public func createResearchLink(
        scope: ResearchScope, title: String, url linkURL: String
    ) async throws -> ResearchItem {
        try await route(scope,
            shared: { try await addResearchLink(parentId: nil, title: title, url: linkURL) },
            piece: { try await addPieceResearchLink(pieceId: $0, title: title, url: linkURL) })
    }

    // MARK: - Derived (structural) association

    /// Path prefix under which a collection loose piece's research lives, or
    /// nil for anything else. THE containment predicate — CollectionResearchPane
    /// and derivedResearchItems must both use this (spec: derivation agreement).
    public static func pieceResearchPrefix(for piece: StructureItem) -> String? {
        guard piece.pieceKind == .loose, let piecePath = piece.path else { return nil }
        return "\((piecePath as NSString).deletingLastPathComponent)/research/"
    }

    /// Research items structurally associated with a document — no link record.
    /// Collection loose piece → containment (path prefix); single-doc project
    /// types → every research asset; multi-doc (novel) → none (chapters
    /// associate via linkedResearchIds only).
    public func derivedResearchItems(forDocumentId docId: String) -> [ResearchItem] {
        switch manifest.type {
        case .collection:
            guard let piece = manifest.structure.first(where: { $0.id == docId }),
                  let prefix = Self.pieceResearchPrefix(for: piece) else { return [] }
            return manifest.research.filter { $0.path?.hasPrefix(prefix) == true }
        case .shortStory, .screenplay:
            return TreeWalk.collect(in: manifest.research, where: { $0.type == .asset })
        case .novel, .unknown:
            return []
        }
    }

    /// Items the link picker offers: everything except what is already
    /// structurally associated (linking those would be redundant).
    public func linkableResearchItems(forDocumentId docId: String) -> [ResearchItem] {
        let derivedIds = Set(derivedResearchItems(forDocumentId: docId).map(\.id))
        return TreeWalk.collect(in: manifest.research, where: { _ in true })
            .filter { !derivedIds.contains($0.id) }
    }
}
```

- [ ] **Step 4: Regenerate project and run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ResearchScopeTests 2>&1 | tail -20`
Expected: all ResearchScopeTests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ResearchScope.swift MaughamTests/ResearchScopeTests.swift
git commit -m "feat(research): ResearchScope typed seam — scoped creation + derived association"
```

---

### Task 2: `CollectionResearchPane` uses the shared containment predicate

**Files:**
- Modify: `Maugham/Views/CollectionResearchPane.swift:188-195` (`pieceItems`), `:206-221` (`addNote`), `:234-249` (`addLinkForScope`), `:334-347` (`scopeFor`)

**Interfaces:**
- Consumes (Task 1): `ProjectStore.pieceResearchPrefix(for:)`, `createResearchNote(scope:title:)`, `createResearchLink(scope:title:url:)`, `ResearchScope`.
- Produces: nothing new — behavior-preserving refactor so binder and right pane share one predicate and one creation path.

- [ ] **Step 1: Refactor `pieceItems` and `scopeFor` onto the shared predicate**

Replace `pieceItems(piece:)`:

```swift
    private func pieceItems(piece: StructureItem) -> [ResearchItem] {
        store.derivedResearchItems(forDocumentId: piece.id)
    }
```

In `scopeFor(item:)`, replace the prefix computation inside the loop:

```swift
    private func scopeFor(item: ResearchItem) -> Scope {
        guard let path = item.path, path.hasPrefix("pieces/") else {
            return .shared
        }
        for piece in store.manifest.structure where piece.pieceKind == .loose {
            if let prefix = ProjectStore.pieceResearchPrefix(for: piece),
               path.hasPrefix(prefix) {
                return .piece(piece.id)
            }
        }
        return .shared
    }
```

- [ ] **Step 2: Route note/link creation through the scoped API**

Replace the switch bodies in `addNote(scope:)` and `addLinkForScope(title:url:)`:

```swift
    private func addNote(scope: Scope) async {
        do {
            let item: ResearchItem
            switch scope {
            case .shared:
                item = try await store.createResearchNote(scope: .shared)
            case .piece(let pieceId):
                item = try await store.createResearchNote(scope: .document(pieceId))
            }
            selectedResearchId = item.id
            pendingRenameId = item.id
        } catch {
            pendingError = error.localizedDescription
        }
    }
```

```swift
    private func addLinkForScope(title: String, url: String) async {
        do {
            let link: ResearchItem
            switch addLinkScope {
            case .shared:
                link = try await store.createResearchLink(
                    scope: .shared, title: title, url: url)
            case .piece(let pieceId):
                link = try await store.createResearchLink(
                    scope: .document(pieceId), title: title, url: url)
            }
            selectedResearchId = link.id
        } catch {
            pendingError = error.localizedDescription
        }
    }
```

(Leave `runImport` on `importPieceResearchFiles` — it is the bulk path and already piece-aware.)

- [ ] **Step 3: Run the collection + research test suites**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PieceResearchTests -only-testing:MaughamTests/PieceResearchAssetsTests -only-testing:MaughamTests/AddResearchTextNoteTests -only-testing:MaughamTests/ResearchScopeTests 2>&1 | tail -20`
Expected: PASS (behavior-preserving; note title default "Untitled Note" is preserved by `createResearchNote`'s default parameter).

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/CollectionResearchPane.swift
git commit -m "refactor(binder): CollectionResearchPane routes through ResearchScope seam"
```

---

### Task 3: Right pane — derived section + creation menu + picker exclusion

**Files:**
- Modify: `Maugham/Views/LinkedResearchPane.swift` (header menu, sectioned list, drop guard, sheets)
- Modify: `Maugham/Views/LinkedResearchRow.swift` (optional unlink)
- Modify: `Maugham/Views/ResearchLinkPickerSheet.swift:74-79` (`filteredItems`)
- Modify: `Maugham/Views/DetailPaneToggle.swift:104-106` (help copy)
- Create: `Maugham/Views/NewResearchNoteSheet.swift`

**Interfaces:**
- Consumes (Task 1): `derivedResearchItems(forDocumentId:)`, `linkableResearchItems(forDocumentId:)`, `isResearchScopeTarget(_:)`, `createResearchNote/Asset/Link(scope:…)`. Consumes existing `AddResearchLinkSheet(onAdd: (String, String) -> Void, onCancel: () -> Void)`.
- Produces: `NewResearchNoteSheet(onCreate: (String) -> Void)` (reused nowhere else yet); `LinkedResearchRow.onUnlink` becomes `(() -> Void)?`.

- [ ] **Step 1: Make `LinkedResearchRow.onUnlink` optional**

In `Maugham/Views/LinkedResearchRow.swift` change the property and button:

```swift
    let item: ResearchItem
    let onUnlink: (() -> Void)?
```

```swift
            Spacer()
            if let onUnlink {
                Button(action: onUnlink) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Unlink")
            }
```

(The existing trailing-closure call site in `LinkedResearchPane` still compiles.)

- [ ] **Step 2: Create `Maugham/Views/NewResearchNoteSheet.swift`**

```swift
import SwiftUI

/// Minimal title prompt for creating a research note from the right pane
/// (which has no inline-rename affordance, unlike the binder rows).
struct NewResearchNoteSheet: View {
    @State private var title: String = ""
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Research Note").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 300)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(title.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Untitled Note" : title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
```

- [ ] **Step 3: Rework `LinkedResearchPane`**

Replace the file body (keep the `viewer(for:)` comment about `ResearchPreview` verbatim — it is load-bearing):

```swift
import SwiftUI
import AppKit
import MaughamCore

struct LinkedResearchPane: View {
    @Bindable var store: ProjectStore
    let activeDocumentId: String?
    @State private var showingLinkPicker: Bool = false
    @State private var showingNewNote: Bool = false
    @State private var showingAddLink: Bool = false
    @State private var actionError: String?
    @State private var viewedItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingLinkPicker) {
            if let docId = activeDocumentId {
                ResearchLinkPickerSheet(store: store, documentId: docId)
            }
        }
        .sheet(isPresented: $showingNewNote) {
            if let docId = activeDocumentId {
                NewResearchNoteSheet { title in
                    Task {
                        do {
                            _ = try await store.createResearchNote(
                                scope: .document(docId), title: title)
                        } catch { actionError = error.localizedDescription }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddLink) {
            AddResearchLinkSheet(
                onAdd: { title, url in
                    if let docId = activeDocumentId {
                        Task {
                            do {
                                _ = try await store.createResearchLink(
                                    scope: .document(docId), title: title, url: url)
                            } catch { actionError = error.localizedDescription }
                        }
                    }
                    showingAddLink = false
                },
                onCancel: { showingAddLink = false })
        }
        .alert("Couldn’t add research", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .onChange(of: activeDocumentId) { _, _ in
            // Different manuscript doc selected → reset viewer to list
            viewedItemId = nil
        }
    }

    private var header: some View {
        HStack {
            if viewedItemId != nil {
                Button {
                    viewedItemId = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("Back to research list")
            }
            Text(headerTitle).font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if viewedItemId == nil {
                Menu {
                    Button("Link Research…") { showingLinkPicker = true }
                    Divider()
                    Button("New Note…") { showingNewNote = true }
                    Button("Add File…") { Task { await runAddFile() } }
                    Button("Add Link…") { showingAddLink = true }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!canCreate)
                .help("Add or link research for this document")
            }
        }
        .padding(8)
    }

    private var canCreate: Bool {
        guard let docId = activeDocumentId else { return false }
        return store.isResearchScopeTarget(docId)
    }

    private var headerTitle: String {
        if let id = viewedItemId,
           let item = store.resolveResearchLinks([id]).first {
            return item.title
        }
        return "Research"
    }

    private var derivedSectionTitle: String {
        store.manifest.type == .collection ? "Piece Research" : "Project Research"
    }

    @ViewBuilder
    private var content: some View {
        if let id = viewedItemId,
           let item = store.resolveResearchLinks([id]).first {
            viewer(for: item)
        } else if let docId = activeDocumentId {
            list(for: docId)
        } else {
            ContentUnavailableView {
                Label("No document selected", systemImage: "doc.text")
            } description: {
                Text("Select a chapter or scene to see its research")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func viewer(for item: ResearchItem) -> some View {
        // Always use ResearchPreview here — its TextPreview branch handles
        // .document read-only without going through DocumentStore. Using
        // ResearchNoteEditor would hijack DocumentStore's active document
        // and evict the manuscript doc from the editor pane.
        ResearchPreview(projectURL: store.url, item: item)
    }

    @ViewBuilder
    private func list(for docId: String) -> some View {
        let derived = store.derivedResearchItems(forDocumentId: docId)
        let derivedIds = Set(derived.map(\.id))
        let linked = linkedItems(for: docId).filter { !derivedIds.contains($0.id) }
        Group {
            if derived.isEmpty && linked.isEmpty {
                ContentUnavailableView {
                    Label("No research yet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Create research from the + menu, or drag research items here to link them.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !derived.isEmpty {
                        Section(derivedSectionTitle) {
                            ForEach(derived) { item in
                                Button {
                                    viewedItemId = item.id
                                } label: {
                                    LinkedResearchRow(item: item, onUnlink: nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !linked.isEmpty {
                        Section("Linked") {
                            ForEach(linked) { item in
                                Button {
                                    viewedItemId = item.id
                                } label: {
                                    LinkedResearchRow(item: item) {
                                        Task {
                                            try? await store.unlinkResearch(
                                                researchId: item.id,
                                                fromDocumentId: docId)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            // Ignore drags of items already structurally associated — a link
            // would be redundant and double-display the item.
            for id in ids where !derivedIds.contains(id) {
                Task {
                    try? await store.linkResearch(
                        researchId: id, toDocumentId: docId)
                }
            }
            return true
        }
    }

    private func runAddFile() async {
        guard let docId = activeDocumentId else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                _ = try await store.createResearchAsset(
                    scope: .document(docId), fromURL: url)
            } catch { actionError = error.localizedDescription }
        }
    }

    private func linkedItems(for docId: String) -> [ResearchItem] {
        let ids = store.linkedResearchIds(forDocumentId: docId)
        return store.resolveResearchLinks(ids)
    }
}
```

- [ ] **Step 4: Picker exclusion in `ResearchLinkPickerSheet`**

Replace `filteredItems()`:

```swift
    private func filteredItems() -> [ResearchItem] {
        let all = store.linkableResearchItems(forDocumentId: documentId)
        if query.isEmpty { return all }
        let lower = query.lowercased()
        return all.filter { $0.title.lowercased().contains(lower) }
    }
```

- [ ] **Step 5: Update the segment help copy in `DetailPaneToggle`**

At `DetailPaneToggle.swift:104-106` change the `.research` segment help:

```swift
            Image(systemName: "doc.text.magnifyingglass")
                .tag(DetailSegment.research)
                .help("Research — this document's own and linked research (⌘⌥2)")
```

- [ ] **Step 6: Regenerate, build, run affected suites**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ResearchScopeTests -only-testing:MaughamTests/LinkedResearchTests 2>&1 | tail -20`
Expected: PASS (store behavior unchanged; view changes are compile-verified).

- [ ] **Step 7: Commit**

```bash
git add Maugham/Views/LinkedResearchPane.swift Maugham/Views/LinkedResearchRow.swift \
        Maugham/Views/ResearchLinkPickerSheet.swift Maugham/Views/DetailPaneToggle.swift \
        Maugham/Views/NewResearchNoteSheet.swift
git commit -m "feat(right-pane): derived Piece/Project Research section + in-pane creation menu"
```

---

### Task 4: Inbox promotion destinations (store + pane + target picker)

**Files:**
- Modify: `Maugham/Stores/InboxStore.swift:188-220` (`promoteToResearch`)
- Modify: `Maugham/Views/InboxPane.swift` (props, context menu, promote action, sheet)
- Modify: `Maugham/Views/DetailPaneToggle.swift:179-192` (`inboxPane` — pass active doc)
- Create: `Maugham/Views/PromoteTargetPickerSheet.swift`
- Test: `MaughamTests/InboxPromoteTests.swift` (extend)

**Interfaces:**
- Consumes (Task 1): `ResearchScope`, `createResearchNote(scope:title:)`, `createResearchAsset(scope:fromURL:)`, `isResearchScopeTarget(_:)`, `researchScopeTargets()`.
- Produces: `InboxStore.promoteToResearch(_ entry: InboxEntry, projectStore: ProjectStore, scope: ResearchScope = .shared) async throws -> ResearchItem` (Task 5 depends on the `scope` parameter); `PromoteTargetPickerSheet(store: ProjectStore, onPick: (String) -> Void)`.

- [ ] **Step 1: Write the failing tests**

Append to `MaughamTests/InboxPromoteTests.swift` (inside the class; reuse its `openProject`/`seed` helpers):

```swift
    // MARK: - Scoped promotion (spec 2026-07-07)

    private func openCollection() async throws
        -> (URL, ProjectStore, InboxStore, DocumentStore, StructureItem) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("promote-coll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "PC", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/inbox/audio"),
            withIntermediateDirectories: true)
        return (url, store, InboxStore(projectURL: url, deviceId: "mac"), ds, piece)
    }

    func test_promoteText_pieceScope_landsInPieceFolder() async throws {
        let (url, store, inbox, ds, piece) = try await openCollection()
        try await seed(url, [InboxEntry(
            id: "tp1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Piece-scoped idea.")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "tp1" })

        let created = try await inbox.promoteToResearch(
            entry, projectStore: store, scope: .document(piece.id))

        XCTAssertTrue(created.path?.hasPrefix("pieces/01-story-a/research/") == true,
                      "got: \(created.path ?? "nil")")
        let body = try String(contentsOf: url.appendingPathComponent(created.path!),
                              encoding: .utf8)
        XCTAssertEqual(body, "Piece-scoped idea.")
        XCTAssertFalse(inbox.entries.contains { $0.id == "tp1" })
        withExtendedLifetime(ds) {}
    }

    func test_promoteAudio_pieceScope_assetLandsInPieceFolder_originalRemoved() async throws {
        let (url, store, inbox, ds, piece) = try await openCollection()
        let assetURL = url.appendingPathComponent(".maugham/inbox/audio/p1.m4a")
        try Data("fake-audio".utf8).write(to: assetURL)
        try await seed(url, [InboxEntry(
            id: "pa1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "p1.m4a",
            transcript: "dictated", transcriptionState: .whisperFinal)])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "pa1" })

        let created = try await inbox.promoteToResearch(
            entry, projectStore: store, scope: .document(piece.id))

        XCTAssertTrue(created.path?.hasPrefix("pieces/01-story-a/research/") == true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(created.path!).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
        withExtendedLifetime(ds) {}
    }

    func test_promoteText_novelChapterScope_createsLink() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let chapterId = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        try await seed(url, [InboxEntry(
            id: "tn1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Chapter-scoped idea.")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "tn1" })

        let created = try await inbox.promoteToResearch(
            entry, projectStore: store, scope: .document(chapterId))

        XCTAssertTrue(created.path?.hasPrefix("research/") == true)
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: chapterId).contains(created.id))
        withExtendedLifetime(ds) {}
    }

    func test_promote_unknownTargetId_throws_andEntryStaysNew() async throws {
        let (url, store, inbox, ds) = try await openProject()
        try await seed(url, [InboxEntry(
            id: "tx1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Orphan idea.")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "tx1" })
        do {
            _ = try await inbox.promoteToResearch(
                entry, projectStore: store, scope: .document("doc-nope"))
            XCTFail("expected throw")
        } catch { /* expected — fail loudly, no shared fallback */ }
        XCTAssertTrue(inbox.entries.contains { $0.id == "tx1" },
                      "failed promote must leave the entry in the inbox")
        withExtendedLifetime(ds) {}
    }
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/InboxPromoteTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `promoteToResearch` has no `scope:` parameter.

- [ ] **Step 3: Add the `scope` parameter to `InboxStore.promoteToResearch`**

In `Maugham/Stores/InboxStore.swift` replace the method signature and creation calls (doc comment: append "A `scope` routes the created item — shared research, a collection piece's folder, or a chapter link (spec 2026-07-07)."):

```swift
    @discardableResult
    func promoteToResearch(
        _ entry: InboxEntry, projectStore: ProjectStore,
        scope: ResearchScope = .shared
    ) async throws -> ResearchItem {
        let created: ResearchItem
        switch entry.kind {
        case .text:
            created = try await projectStore.createResearchNote(
                scope: scope, title: promotionTitle(for: entry))
            if let path = created.path {
                let dest = projectStore.url.appendingPathComponent(path)
                try? (entry.inlineText ?? "").write(
                    to: dest, atomically: true, encoding: .utf8)
            }
        case .image, .audio:
            guard let asset = assetURL(for: entry),
                  FileManager.default.fileExists(atPath: asset.path) else {
                throw InboxError.assetMissing(entry.sourceFilename ?? entry.id)
            }
            // createResearchAsset copies; remove the inbox original to finish
            // the move. The asset lives under .maugham/inbox/ and is never an
            // open Document, so no close-before-FS guard (tripwire 14) needed.
            created = try await projectStore.createResearchAsset(
                scope: scope, fromURL: asset)
            try? FileManager.default.removeItem(at: asset)
        }
        await updateStatus(id: entry.id, to: .promoted)
        return created
    }
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/InboxPromoteTests 2>&1 | tail -10`
Expected: all PASS (including the three pre-existing tests — default `.shared` preserves behavior).

- [ ] **Step 5: Create `Maugham/Views/PromoteTargetPickerSheet.swift`**

```swift
import SwiftUI
import MaughamCore

/// Searchable list of manuscript documents (chapters / loose pieces) that can
/// receive scoped research — drives the inbox "Promote to Research for…" action.
struct PromoteTargetPickerSheet: View {
    @Bindable var store: ProjectStore
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search documents…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(filteredTargets()) { item in
                    Button {
                        onPick(item.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(item.title)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationTitle("Promote to Research for…")
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func filteredTargets() -> [StructureItem] {
        let all = store.researchScopeTargets()
        if query.isEmpty { return all }
        let lower = query.lowercased()
        return all.filter { $0.title.lowercased().contains(lower) }
    }
}
```

- [ ] **Step 6: Wire the destinations into `InboxPane`**

In `Maugham/Views/InboxPane.swift`:

a. Add a property after `projectStore` and a state after `showingTrash`:

```swift
    /// Active manuscript document — target of the fast "Promote to Research
    /// for [title]" path. Nil (or an invalid target) hides that menu item.
    let activeDocumentId: String?
```

```swift
    @State private var promotePicking: InboxEntry?
```

b. Add after the `.alert` modifier in `body`:

```swift
        .sheet(item: $promotePicking) { entry in
            PromoteTargetPickerSheet(store: projectStore) { docId in
                promote(entry, scope: .document(docId))
            }
        }
```

c. Replace the first context-menu button in `row(_:)`:

```swift
            Button("Promote to Research") { promote(entry, scope: .shared) }
            if let target = activePromoteTarget {
                Button("Promote to Research for “\(target.title)”") {
                    promote(entry, scope: .document(target.id))
                }
            }
            Button("Promote to Research for…") { promotePicking = entry }
```

d. Replace `promote(_:)` and add the target lookup:

```swift
    private func promote(_ entry: InboxEntry, scope: ResearchScope) {
        audio.stop()
        Task {
            do {
                try await store.promoteToResearch(
                    entry, projectStore: projectStore, scope: scope)
            } catch { promoteError = error.localizedDescription }
        }
    }

    private var activePromoteTarget: StructureItem? {
        guard let id = activeDocumentId,
              projectStore.isResearchScopeTarget(id) else { return nil }
        return TreeWalk.collect(
            in: projectStore.manifest.structure, where: { $0.id == id }).first
    }
```

e. In `Maugham/Views/DetailPaneToggle.swift` `inboxPane`, pass the active document:

```swift
            InboxPane(store: ds.inboxStore, projectStore: store,
                      activeDocumentId: activeManuscriptItemId,
                      canTranscribe: Self.localTranscriptionAvailable,
                      retranscribe: { entry in Task { await ds.retranscribe(entry) } })
```

- [ ] **Step 7: Regenerate, build, run inbox suites**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/InboxPromoteTests -only-testing:MaughamTests/InboxStoreLastWinsTests -only-testing:MaughamTests/InboxRetranscribeTests 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Stores/InboxStore.swift Maugham/Views/InboxPane.swift \
        Maugham/Views/DetailPaneToggle.swift Maugham/Views/PromoteTargetPickerSheet.swift \
        MaughamTests/InboxPromoteTests.swift
git commit -m "feat(inbox): promote-to-destination — shared, active document, or picked target"
```

---

### Task 5: MCP — `promote_inbox_entry` gains `target_document_id`

**Files:**
- Modify: `Maugham/MCP/Tools/InboxTools.swift:87-122` (`PromoteInboxEntryTool`)
- Test: Create `MaughamTests/MCP/Tools/InboxToolsTests.swift`

**Interfaces:**
- Consumes (Task 4): `InboxStore.promoteToResearch(_:projectStore:scope:)`; (Task 1) `ResearchScope`.
- Produces: `promote_inbox_entry` accepts optional `target_document_id: String` (schema + params); result shape unchanged.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/MCP/Tools/InboxToolsTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

/// `promote_inbox_entry` with the optional `target_document_id` scope
/// (spec 2026-07-07). The tool resolves the live inbox via
/// store.documentStore.inboxStore, so tests wire a real DocumentStore.
@MainActor
final class InboxToolsTests: XCTestCase {

    private func openNovelWithRegistry() async throws
        -> (URL, ProjectStore, DocumentStore, ProjectRegistry, String) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("inboxtool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createNovelProject(named: "IT", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg, ProjectIdentifier.id(for: url))
    }

    private func seed(_ url: URL, _ entries: [InboxEntry]) async throws {
        let file = url.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        let s = JSONLAppendStore<InboxEntry>(fileURL: file)
        for e in entries { try await s.append(e) }
    }

    func test_promote_withTargetDocumentId_linksToChapter() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        let chapterId = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        try await seed(url, [InboxEntry(
            id: "e1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Scoped capture.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e1","target_document_id":"\#(chapterId)"}"#
        let data = try await PromoteInboxEntryTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let result = try JSONDecoder().decode(
            PromoteInboxEntryTool.Result.self, from: data)

        XCTAssertTrue(store.linkedResearchIds(forDocumentId: chapterId)
            .contains(result.research_id))
        withExtendedLifetime(ds) {}
    }

    func test_promote_withoutTarget_isSharedAndUnlinked() async throws {
        let (url, store, ds, reg, projectId) = try await openNovelWithRegistry()
        try await seed(url, [InboxEntry(
            id: "e2", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Plain capture.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e2"}"#
        let data = try await PromoteInboxEntryTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let result = try JSONDecoder().decode(
            PromoteInboxEntryTool.Result.self, from: data)

        XCTAssertTrue(result.path.hasPrefix("research/"))
        withExtendedLifetime(ds) {}
    }

    func test_promote_unknownTargetDocumentId_failsLoudly() async throws {
        let (url, _, ds, reg, projectId) = try await openNovelWithRegistry()
        try await seed(url, [InboxEntry(
            id: "e3", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Doomed capture.")])

        let params = #"{"project_id":"\#(projectId)","entry_id":"e3","target_document_id":"doc-nope"}"#
        do {
            _ = try await PromoteInboxEntryTool.handle(
                paramsJSON: Data(params.utf8), registry: reg)
            XCTFail("expected throw for unknown target_document_id")
        } catch { /* expected */ }
        withExtendedLifetime(ds) {}
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/InboxToolsTests 2>&1 | tail -10`
Expected: `test_promote_withTargetDocumentId_linksToChapter` and `test_promote_unknownTargetDocumentId_failsLoudly` FAIL (param is silently ignored by the decoder today, so no link is created and no error is thrown).

- [ ] **Step 3: Implement the param**

In `Maugham/MCP/Tools/InboxTools.swift`, update `PromoteInboxEntryTool`:

```swift
/// `promote_inbox_entry(project_id, entry_id, title?, target_document_id?)` —
/// move a capture into research and mark it promoted. Non-destructive; mirrors
/// the InboxPane action. `target_document_id` scopes the created item to a
/// chapter or collection piece (spec 2026-07-07); omitted → shared research.
public enum PromoteInboxEntryTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let entry_id: String
        public let title: String?
        public let target_document_id: String?
    }
    public struct Result: Codable, Equatable {
        public let research_id: String
        public let title: String
        public let path: String
    }

    public static let method = "promote_inbox_entry"
    public static let description =
        "Move an inbox capture into the project's research and mark it " +
        "promoted. Non-destructive (the capture becomes a research item). " +
        "Optional target_document_id scopes it to a chapter or collection " +
        "piece: piece → its research folder; novel chapter → shared research " +
        "plus a research link. Unknown ids fail."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"entry_id":{"type":"string"},"title":{"type":"string"},"target_document_id":{"type":"string"}},"required":["project_id","entry_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let (store, inbox) = try liveInbox(registry, projectId: params.project_id)
        await inbox.refresh()
        guard var entry = inbox.entries.first(where: { $0.id == params.entry_id }) else {
            throw MCPError.invalidArgument(
                "inbox entry not found or already resolved: \(params.entry_id)")
        }
        if let title = params.title, !title.isEmpty { entry.title = title }
        let scope: ResearchScope =
            params.target_document_id.map { .document($0) } ?? .shared
        let created = try await inbox.promoteToResearch(
            entry, projectStore: store, scope: scope)
        return try JSONEncoder().encode(Result(
            research_id: created.id, title: created.title, path: created.path ?? ""))
    }
}
```

- [ ] **Step 4: Run the new tests plus the MCP catalog/tools-list suites** (onboarding-milestone lesson: schema changes ripple into list tests)

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/InboxToolsTests -only-testing:MaughamTests/MCPToolsListSmokeTest -only-testing:MaughamTests/MCPCatalogConsistencyTests -only-testing:MaughamTests/MCPProtocolHandlersTests 2>&1 | tail -10`
Expected: PASS. If a tools-list test pins the old schema/description string, update the pinned expectation to the new text — do not weaken the assertion.

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/InboxTools.swift MaughamTests/MCP/Tools/InboxToolsTests.swift
git commit -m "feat(mcp): promote_inbox_entry target_document_id — scoped promotion from Claude"
```

---

### Task 6: MCP — `list_all_links` + `find_references` see containment

**Files:**
- Modify: `Maugham/MCP/Tools/ListAllLinksTool.swift` (description `:10-14`, edges loop after `:65`)
- Modify: `Maugham/MCP/Tools/ReferenceTools.swift` (`FindReferencesTool`: description `:125-129`, backref scan after `:158`, `Reference.kind` comment `:122`)
- Test: `MaughamTests/MCP/Tools/ListAllLinksToolTests.swift`, `MaughamTests/MCP/Tools/ReferenceToolsTests.swift` (extend both)

**Interfaces:**
- Consumes (Task 1): `ProjectStore.derivedResearchItems(forDocumentId:)`.
- Produces: `list_all_links` edge `kind == "piece_research"` (loose piece → containment-owned research item); `find_references` backref `kind == "piece_research"` (owning piece, when the target is a piece-owned research item). Existing kinds unchanged.

- [ ] **Step 1: Write the failing test**

Append to `ListAllLinksToolTests` (follow the file's existing decode pattern for `[ListAllLinksTool.Edge]`):

```swift
    func test_listAllLinks_emitsPieceResearchEdges_forCollections() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-PR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Owned Note")
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)

        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(projectId)\"}".utf8), registry: reg)
        let edges = try JSONDecoder().decode([ListAllLinksTool.Edge].self, from: json)

        XCTAssertTrue(edges.contains {
            $0.kind == "piece_research" && $0.from_id == piece.id && $0.to_id == owned.id
        }, "containment must surface as a piece_research edge; edges: \(edges)")
        XCTAssertFalse(edges.contains {
            $0.kind == "piece_research" && $0.to_title == "Shared Note"
        }, "shared research must not appear as piece_research")
    }
```

And append to `ReferenceToolsTests` (reuse its existing fixture style; a fresh collection fixture like the one above is fine):

```swift
    func test_findReferences_pieceOwnedResearch_returnsOwningPiece() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FR-PR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Owned Note")
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)

        let params = #"{"project_id":"\#(projectId)","target":"\#(owned.id)"}"#
        let json = try await FindReferencesTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self, from: json)

        XCTAssertTrue(refs.contains {
            $0.kind == "piece_research" && $0.from_id == piece.id
        }, "owning piece must back-reference its research; refs: \(refs)")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ListAllLinksToolTests -only-testing:MaughamTests/ReferenceToolsTests 2>&1 | tail -10`
Expected: both new tests FAIL (no `piece_research` edges/backrefs emitted).

- [ ] **Step 3: Emit the edges**

In `ListAllLinksTool.handle`, insert after the linked-research loop (after line 65) and before the wiki loop:

```swift
        // Containment edges — a collection loose piece owns research by path
        // prefix (the strongest association; spec 2026-07-07 ends MCP's
        // blindness to it). Uses the same derivation as the panes.
        for piece in store.manifest.structure where piece.pieceKind == .loose {
            for r in store.derivedResearchItems(forDocumentId: piece.id) {
                edges.append(Edge(
                    from_id: piece.id,
                    from_title: piece.title,
                    to_id: r.id,
                    to_title: r.title,
                    kind: "piece_research"))
            }
        }
```

Update the tool `description` constant (and the `Edge.kind` doc comment at `:26`) to list the new kind:

```swift
    public static let description =
        "Return the full reference graph as edges: every manuscript document's " +
        "linked-research and [[wiki-link]] targets, plus collection pieces' " +
        "own (folder-scoped) research. Each edge has from_id/from_title, " +
        "to_id (null for unresolved wiki targets) / to_title, and kind " +
        "('linked_research' / 'piece_research' / 'wiki' / 'wiki_unresolved')."
```

In `Maugham/MCP/Tools/ReferenceTools.swift` (`FindReferencesTool.handle`), insert after the linked-research backref scan (after line 158) and before the wiki scan:

```swift
        // Containment backref — a collection loose piece owning the target
        // research item by path prefix is a reference too (spec 2026-07-07).
        if let rid = resolvedId {
            for piece in store.manifest.structure where piece.pieceKind == .loose {
                if store.derivedResearchItems(forDocumentId: piece.id)
                    .contains(where: { $0.id == rid }),
                   seenFromIds.insert(piece.id).inserted {
                    refs.append(Reference(
                        from_id: piece.id,
                        from_title: piece.title,
                        kind: "piece_research"))
                }
            }
        }
```

Update `Reference.kind`'s comment at `:122` to `// "wiki", "linked_research", or "piece_research"` and append to the tool `description`: `" Piece-owned research returns its owning piece as a piece_research backref."`

- [ ] **Step 4: Run the tool + tools-list suites**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ListAllLinksToolTests -only-testing:MaughamTests/ReferenceToolsTests -only-testing:MaughamTests/ReferenceOpLogSourceTests -only-testing:MaughamTests/MCPToolsListSmokeTest -only-testing:MaughamTests/MCPCatalogConsistencyTests 2>&1 | tail -10`
Expected: PASS (update any pinned description strings as in Task 5).

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/ListAllLinksTool.swift Maugham/MCP/Tools/ReferenceTools.swift \
        MaughamTests/MCP/Tools/ListAllLinksToolTests.swift MaughamTests/MCP/Tools/ReferenceToolsTests.swift
git commit -m "feat(mcp): containment visible to Claude — piece_research edges + backrefs"
```

---

### Task 7: Promotion regression test, docs, full sweep

**Files:**
- Test: `MaughamTests/Collection/PromotePieceTests.swift` (extend — read the file's existing fixture helpers first and reuse them)
- Modify: `docs/guide/structure-and-binder.md`, `docs/guide/claude-desktop.md`, `docs/guide/reference.md` (whichever of these describe linked research / inbox promotion — grep each for "Linked Research", "linked research", "Promote", "promote_inbox_entry", "list_all_links" and update the affected passages)
- Modify: `Maugham/MCP/AREA.md` (tool descriptions for `promote_inbox_entry` / `list_all_links`, if the file lists per-tool summaries)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing new — regression coverage + shipped-behavior docs (CLAUDE.md: "Help/docs surfaces describe what ships").

- [ ] **Step 1: Write the promotion follow-through regression test**

Append to `PromotePieceTests` (adapt fixture names to the file's existing helpers — it already creates a collection, adds a loose piece, and calls `promotePieceToProject`; mirror that setup):

```swift
    func test_promotedProject_carriedResearch_isDerivedForItsDocument() async throws {
        // Collection with a piece that owns one research note.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("promote-derive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: parent)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let note = try await store.addPieceResearchNote(pieceId: piece.id, title: "Carried")

        let dest = parent.appendingPathComponent("StoryA")
        _ = try await store.promotePieceToProject(pieceId: piece.id, destination: dest)

        // The promoted single-doc project derives the carried research for its
        // document with no re-linking (spec §6: promotion follow-through).
        let promoted = try await ProjectStore.load(from: dest)
        let docId = try XCTUnwrap(
            TreeWalk.collect(in: promoted.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        let derived = promoted.derivedResearchItems(forDocumentId: docId)
        XCTAssertTrue(derived.contains { $0.title == note.title },
                      "carried research must appear derived; got: \(derived.map(\.title))")
        XCTAssertTrue(derived.allSatisfy { $0.path?.hasPrefix("research/") == true },
                      "carried paths must be rewritten to research/…")
    }
```

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PromotePieceTests 2>&1 | tail -10`
Expected: PASS immediately (this pins behavior that Tasks 1–6 made true; if it fails, the derivation rule or promotion path-rewrite regressed — fix before proceeding). If `promotePieceToProject` requires a `DocumentStore`, wire one exactly as `InboxPromoteTests.openProject` does.

- [ ] **Step 2: Update the guide docs (single docs source — served by Help window, `get_help`, and GitHub)**

Grep first: `grep -n -i "linked research\|promote" docs/guide/*.md`. Then update the affected passages to describe (shipped behavior only):
- The right-pane Research mode shows a **Piece Research** (collections) / **Project Research** (single-doc projects) section automatically — piece research needs no linking step — plus the **Linked** section, and its **+** menu can create notes/files/links scoped to the open document.
- Inbox captures can be promoted to shared research, to the active document, or to a picked chapter/piece.
- `promote_inbox_entry` accepts `target_document_id`; `list_all_links` includes `piece_research` edges.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/GuideDocsDriftTests -only-testing:MaughamTests/GuideCorpusRenderabilityTest -only-testing:MaughamTests/HelpTopicIndexTests 2>&1 | tail -10`
Expected: PASS (these gate the guide corpus).

- [ ] **Step 3: Update `Maugham/MCP/AREA.md`** — if it carries per-tool one-liners, refresh the two changed tools; do not change the tool count (44, unchanged).

- [ ] **Step 4: Full Mac suite + phone guard**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: TEST SUCCEEDED.

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: TEST SUCCEEDED (no MaughamCore changes in this plan, so this is a guard; "Busy/preflight" failures are simulator flakes — re-run).

- [ ] **Step 5: Commit**

```bash
git add MaughamTests/Collection/PromotePieceTests.swift docs/guide/ Maugham/MCP/AREA.md
git commit -m "test(promotion): carried research derives in promoted project; docs: scoped research"
```

---

## Manual smoke (writer-run, after merge to a build)

1. Collection: open a piece → binder + add piece note → right pane ⌘⌥2 shows it under **Piece Research** with no linking step.
2. Right pane + menu → New Note… on a novel chapter → note appears under **Linked** immediately; picker no longer offers items already in the derived section.
3. Phone capture → Mac inbox ⌘⌥6 → context menu shows all three promote items → "Promote to Research for [piece]" lands the note in the piece folder.
4. Promote a piece to a standalone project → its right pane shows the carried research under **Project Research** with no re-linking.

## Model guidance (subagent dispatch)

- Task 1: **opus** (routing seam — the load-bearing task).
- Tasks 2, 7: **haiku** (mechanical refactor / test-and-docs).
- Tasks 3, 4: **sonnet or opus** (SwiftUI composition + store seam).
- Tasks 5, 6: **sonnet** (MCP tool surface, established patterns).
- Reviewer subagents: **haiku**.
