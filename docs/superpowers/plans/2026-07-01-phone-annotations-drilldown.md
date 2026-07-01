# Phone Annotations Drill-down + Show-resolved Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the phone Annotations tab from one flat cross-project list into a project → chapter → notes drill-down, with a global Open/All control that also reveals resolved notes for review.

**Architecture:** A new `@Observable AnnotationsStore` owns the load + a grouped tree; a pure `AnnotationLoading.groupByChapter` maps each annotation's `docId` to its chapter title + parent-group (via `StructureItem.id == docId`); three drill-down views render mode-filtered subsets. All grouping/filtering/status-chip logic is pure and table-tested; the views are build-verified. No MaughamCore change, no schema bump, no cross-surface contract touched.

**Tech Stack:** Swift, SwiftUI, `MaughamCore` (Foundation-only shared package), XCTest hosted into the `MaughamPhone` app target.

## Global Constraints

- **Build after adding/removing any file:** `./gen.sh` (xcodegen regenerates the project from folder globs — `project.yml` globs `MaughamPhone/` and `MaughamPhoneTests/`). Never hand-edit `Maugham.xcodeproj/`; never commit anything under it.
- **Phone test command:** `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO`
- **A transient simulator "Busy / failed preflight checks" is a flake — re-run.** Do NOT `simctl shutdown all` before a launch.
- **Tripwire 4:** never derive/parse in a SwiftUI row body — grouping happens once in the store; rows render pre-derived values.
- **Tripwire 5:** no `NSFilePresenter`; refresh only on appear / pull-to-refresh / after a phone-side resolve.
- **Tripwire 15:** empty states keep BOTH `.frame(maxWidth:.infinity, maxHeight:.infinity)` and the `alignment:.top` variant.
- **Tripwire 3 (iOS):** doc-id parsing routes through `OpLogStore.docIds(...)` in MaughamCore — never a local stricter predicate.
- **`ProjectId` is `typealias ProjectId = String`** (declared in `MaughamPhone/Storage/RecentsTracker.swift`).
- **Undo/reopen is OUT OF SCOPE** (deferred milestone). Resolved rows are read-only.
- Commit after each task with a `feat(phone):` / `test(phone):` message.

---

## File Structure

- **`MaughamPhone/Annotations/AnnotationLoading.swift`** (modify) — pure core: add `allAnnotations(ops:)`, the grouped result types (`LoadedAnnotation`, `ChapterAnnotations`, `ProjectAnnotations`), `groupByChapter(_:structure:research:)`, `AnnotationsMode` + the visibility filters. No I/O, no SwiftUI.
- **`MaughamPhone/Annotations/AnnotationStatusChip.swift`** (create) — pure status → label/symbol mapping for resolved rows.
- **`MaughamPhone/Annotations/AnnotationsStore.swift`** (create) — `@Observable @MainActor` load + grouped tree + banner (moved from the view).
- **`MaughamPhone/Annotations/ChapterAnnotationsView.swift`** (create) — leaf: OPEN + optional RESOLVED sections.
- **`MaughamPhone/Annotations/ProjectChaptersView.swift`** (create) — middle: flat chapter rows sectioned by group.
- **`MaughamPhone/Annotations/AnnotationsListView.swift`** (modify) — becomes the Projects root over the store; adds the Open/All control + single-doc skip; loses the moved load logic and the nested `LoadedAnnotation`/`ProjectAnnotations`.
- **`MaughamPhoneTests/AnnotationLoadingTests.swift`** (modify) — add `allAnnotations`, `groupByChapter`, and mode-filter table tests.
- **`MaughamPhoneTests/AnnotationStatusChipTests.swift`** (create) — chip mapping tests.

---

## Task 1: `allAnnotations(ops:)` in AnnotationLoading

**Files:**
- Modify: `MaughamPhone/Annotations/AnnotationLoading.swift`
- Test: `MaughamPhoneTests/AnnotationLoadingTests.swift`

**Interfaces:**
- Produces: `static func allAnnotations(ops: [Op]) -> [Annotation]` (every derived annotation, all statuses, `AnnotationDeriver`'s newest-first order). `openAnnotations` is refactored to `allAnnotations(ops:).filter { $0.status == .open }`.

- [ ] **Step 1: Write the failing test**

Add to `AnnotationLoadingTests.swift` (uses the file's existing `suggestionOp`/`acceptOp`/`commentOp` builders):

```swift
    // MARK: - allAnnotations

    func test_allAnnotations_includesResolvedAndOpen() {
        let creation = suggestionOp(opId: "01CREATION", paragraphId: "k7m3", prior: "Old.", next: "New.")
        let accept = acceptOp(opId: "01ACCEPT", sourceAnnotationId: "01CREATION", paragraphId: "k7m3", prior: "Old.", next: "New.")
        let comment = commentOp(opId: "01COMMENT", paragraphId: "k7m3", body: "nice line")

        let all = AnnotationLoading.allAnnotations(ops: [creation, accept, comment])
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        XCTAssertEqual(all.count, 2, "both the resolved suggestion and the open comment are present")
        XCTAssertEqual(byId["01CREATION"]?.status, .accepted)
        XCTAssertEqual(byId["01COMMENT"]?.status, .open)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/AnnotationLoadingTests/test_allAnnotations_includesResolvedAndOpen`
Expected: FAIL — compile error, `allAnnotations` not a member of `AnnotationLoading`.

- [ ] **Step 3: Write minimal implementation**

In `AnnotationLoading.swift`, add `allAnnotations` and re-point `openAnnotations` at it:

```swift
    /// Every derived annotation for one document's merged op stream (all
    /// statuses), in `AnnotationDeriver`'s newest-first order. The show-resolved
    /// (All) mode needs resolved annotations too, so we derive the full set once
    /// and let callers partition by `.status`.
    static func allAnnotations(ops: [Op]) -> [Annotation] {
        let paragraphs = Deriver.derive(ops: ops).paragraphs
        return AnnotationDeriver.derive(ops: ops, paragraphs: paragraphs)
    }

    /// Open annotations only — the triage subset. Kept as the thin filter over
    /// `allAnnotations` so the two never drift.
    static func openAnnotations(ops: [Op]) -> [Annotation] {
        allAnnotations(ops: ops).filter { $0.status == .open }
    }
```

Delete the old body of `openAnnotations` (the two-line `Deriver.derive`/`AnnotationDeriver.derive`/`.filter` version).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/AnnotationLoadingTests`
Expected: PASS (new test + the pre-existing `openAnnotations` tests still green).

- [ ] **Step 5: Commit**

```bash
git add MaughamPhone/Annotations/AnnotationLoading.swift MaughamPhoneTests/AnnotationLoadingTests.swift
git commit -m "feat(phone): AnnotationLoading.allAnnotations (all statuses); openAnnotations reuses it"
```

---

## Task 2: Grouped types + `groupByChapter`

**Files:**
- Modify: `MaughamPhone/Annotations/AnnotationLoading.swift`
- Test: `MaughamPhoneTests/AnnotationLoadingTests.swift`

**Interfaces:**
- Produces:
  - `struct LoadedAnnotation: Identifiable { let annotation: Annotation; let docId: String; var id: String }`
  - `struct ChapterAnnotations: Identifiable { let docId: String; let chapterTitle: String; let groupTitle: String?; let open: [LoadedAnnotation]; let resolved: [LoadedAnnotation]; var id: String; var openCount: Int; var resolvedCount: Int }`
  - `struct ProjectAnnotations: Identifiable { let id: ProjectId; let projectName: String; let projectURL: URL; let chapters: [ChapterAnnotations]; var openCount: Int; var resolvedCount: Int }`
  - `static func groupByChapter(_ annotations: [LoadedAnnotation], structure: [StructureItem], research: [ResearchItem]) -> [ChapterAnnotations]`
- Consumes: `TreeWalk.leaves` (MaughamCore), `StructureItem`, `ResearchItem`, `Annotation`.

- [ ] **Step 1: Write the failing tests**

Add to `AnnotationLoadingTests.swift`:

```swift
    // MARK: - groupByChapter

    /// Helper: a LoadedAnnotation with a chosen status, for grouping tests.
    private func loaded(_ id: String, docId: String, status: AnnotationStatus) -> LoadedAnnotation {
        let ann = Annotation(
            id: id, kind: .comment, paragraphId: "k7m3", body: "b",
            suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), createdBySession: nil,
            status: status, userResponse: nil, resolvedAt: nil, isStale: false)
        return LoadedAnnotation(annotation: ann, docId: docId)
    }

    private func doc(_ id: String, _ title: String) -> StructureItem {
        StructureItem(id: id, title: title, type: .document, path: "\(title).md")
    }
    private func group(_ id: String, _ title: String, _ kids: [StructureItem]) -> StructureItem {
        StructureItem(id: id, title: title, type: .group, children: kids)
    }

    func test_groupByChapter_binderOrder_withParentGroupHeaders() {
        let structure = [
            group("g1", "Act I", [doc("doc-a", "Arrival"), doc("doc-b", "The Letter")]),
            group("g2", "Act II", [doc("doc-c", "Nightfall")]),
        ]
        let anns = [
            loaded("n3", docId: "doc-c", status: .open),
            loaded("n1", docId: "doc-a", status: .open),
            loaded("n2", docId: "doc-b", status: .open),
        ]
        let chapters = AnnotationLoading.groupByChapter(anns, structure: structure, research: [])
        XCTAssertEqual(chapters.map(\.docId), ["doc-a", "doc-b", "doc-c"], "binder order, not annotation order")
        XCTAssertEqual(chapters.map(\.chapterTitle), ["Arrival", "The Letter", "Nightfall"])
        XCTAssertEqual(chapters.map(\.groupTitle), ["Act I", "Act I", "Act II"])
    }

    func test_groupByChapter_partitionsOpenAndResolved() {
        let structure = [doc("doc-a", "Arrival")]
        let anns = [
            loaded("n1", docId: "doc-a", status: .open),
            loaded("n2", docId: "doc-a", status: .accepted),
            loaded("n3", docId: "doc-a", status: .archived),
        ]
        let chapters = AnnotationLoading.groupByChapter(anns, structure: structure, research: [])
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].open.map(\.id), ["n1"])
        XCTAssertEqual(Set(chapters[0].resolved.map(\.id)), ["n2", "n3"])
        XCTAssertEqual(chapters[0].openCount, 1)
        XCTAssertEqual(chapters[0].resolvedCount, 2)
    }

    func test_groupByChapter_ungroupedDocument_hasNilGroupTitle() {
        let structure = [doc("doc-a", "Loose Chapter")]
        let chapters = AnnotationLoading.groupByChapter([loaded("n1", docId: "doc-a", status: .open)], structure: structure, research: [])
        XCTAssertEqual(chapters[0].groupTitle, nil)
    }

    func test_groupByChapter_researchFallbackTitle() {
        let research = [ResearchItem(id: "doc-r", title: "World Bible", type: .document, path: "r.md")]
        let chapters = AnnotationLoading.groupByChapter([loaded("n1", docId: "doc-r", status: .open)], structure: [], research: research)
        XCTAssertEqual(chapters.map(\.chapterTitle), ["World Bible"])
        XCTAssertEqual(chapters.map(\.groupTitle), ["Research"])
    }

    func test_groupByChapter_unmappedDocId_goesToOther_lastAndNeverDropped() {
        let structure = [doc("doc-a", "Arrival")]
        let anns = [
            loaded("n1", docId: "doc-a", status: .open),
            loaded("n2", docId: "doc-ORPHAN9999", status: .open),
        ]
        let chapters = AnnotationLoading.groupByChapter(anns, structure: structure, research: [])
        XCTAssertEqual(chapters.map(\.docId), ["doc-a", "doc-ORPHAN9999"], "unmapped sorts last, never dropped")
        XCTAssertEqual(chapters.last?.groupTitle, "Other")
        XCTAssertTrue(chapters.last?.chapterTitle.contains("doc-ORPHAN") ?? false)
    }

    func test_groupByChapter_empty_isEmpty() {
        XCTAssertTrue(AnnotationLoading.groupByChapter([], structure: [], research: []).isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/AnnotationLoadingTests`
Expected: FAIL — compile error, `LoadedAnnotation`/`ChapterAnnotations`/`groupByChapter` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `AnnotationLoading.swift` (top-level types + method inside the `enum AnnotationLoading`). Add the types ABOVE the enum or in the same file at top level:

```swift
/// One annotation plus the docId it came from. Promoted to top-level (was nested
/// in AnnotationsListView) so the store, the grouping function, and the three
/// drill-down views share one type.
struct LoadedAnnotation: Identifiable {
    let annotation: Annotation
    let docId: String
    var id: String { annotation.id }
}

/// One document's (chapter/piece's) annotations, split by status, tagged with its
/// binder title and immediate parent-group title (the drill-down section header).
struct ChapterAnnotations: Identifiable {
    let docId: String            // == StructureItem.id
    let chapterTitle: String
    let groupTitle: String?      // immediate parent group's title, or nil / "Research" / "Other"
    let open: [LoadedAnnotation]
    let resolved: [LoadedAnnotation]
    var id: String { docId }
    var openCount: Int { open.count }
    var resolvedCount: Int { resolved.count }
}

/// One project's annotations, broken down by chapter. `chapters` holds every
/// chapter with any note; the view filters by Open/All mode.
struct ProjectAnnotations: Identifiable {
    let id: ProjectId
    let projectName: String
    let projectURL: URL
    let chapters: [ChapterAnnotations]
    var openCount: Int { chapters.reduce(0) { $0 + $1.openCount } }
    var resolvedCount: Int { chapters.reduce(0) { $0 + $1.resolvedCount } }
}
```

Add inside `enum AnnotationLoading`:

```swift
    /// Group a project's annotations (ALL statuses) by document, in binder order,
    /// each tagged with its chapter title + immediate parent-group title.
    ///
    /// docId → chapter is `StructureItem.id == docId` (the same id the op-log
    /// filename carries). A docId not in `structure` falls back to the `research`
    /// tree ("Research" header); a docId in neither is surfaced under "Other"
    /// with a docId-stub title (never dropped — fail-visible). Mapped chapters
    /// sort by binder pre-order; unmapped/Other sort last.
    static func groupByChapter(
        _ annotations: [LoadedAnnotation],
        structure: [StructureItem],
        research: [ResearchItem]
    ) -> [ChapterAnnotations] {
        // 1. docId -> (title, parentGroupTitle) + a binder-order index.
        var meta: [String: (title: String, group: String?)] = [:]
        var order: [String: Int] = [:]
        var counter = 0

        func walk(_ items: [StructureItem], parentGroup: String?) {
            for item in items {
                switch item.type {
                case .group:
                    walk(item.children ?? [], parentGroup: item.title)
                case .document:
                    if meta[item.id] == nil {
                        meta[item.id] = (item.title, parentGroup)
                        order[item.id] = counter; counter += 1
                    }
                }
            }
        }
        walk(structure, parentGroup: nil)

        // Research leaves as a fallback locus, ordered after the manuscript.
        for item in TreeWalk.leaves(in: research) where meta[item.id] == nil {
            meta[item.id] = (item.title, "Research")
            order[item.id] = counter; counter += 1
        }

        // 2. Bucket by docId.
        var byDoc: [String: [LoadedAnnotation]] = [:]
        for a in annotations { byDoc[a.docId, default: []].append(a) }

        // 3. Build chapters (open/resolved partition preserves derive order).
        var chapters: [ChapterAnnotations] = byDoc.map { docId, anns in
            let m = meta[docId]
            let title = m?.title ?? "Other (\(docIdStub(docId)))"
            let group = m?.group ?? (m == nil ? "Other" : nil)
            return ChapterAnnotations(
                docId: docId,
                chapterTitle: title,
                groupTitle: group,
                open: anns.filter { $0.annotation.status == .open },
                resolved: anns.filter { $0.annotation.status != .open })
        }
        chapters.sort { a, b in
            let oa = order[a.docId] ?? Int.max
            let ob = order[b.docId] ?? Int.max
            if oa != ob { return oa < ob }
            return a.docId < b.docId    // stable tie-break for two unmapped docs
        }
        return chapters
    }

    /// Short, human-readable stub of an unmapped docId for the "Other" fallback.
    static func docIdStub(_ docId: String) -> String {
        String(docId.prefix(16))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/AnnotationLoadingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MaughamPhone/Annotations/AnnotationLoading.swift MaughamPhoneTests/AnnotationLoadingTests.swift
git commit -m "feat(phone): groupByChapter + grouped annotation types (binder-order, group headers, research/Other fallback)"
```

---

## Task 3: `AnnotationsMode` + visibility filters

**Files:**
- Modify: `MaughamPhone/Annotations/AnnotationLoading.swift`
- Test: `MaughamPhoneTests/AnnotationLoadingTests.swift`

**Interfaces:**
- Produces:
  - `enum AnnotationsMode: String, CaseIterable { case open, all; var title: String }`
  - `static func visibleChapters(_ chapters: [ChapterAnnotations], mode: AnnotationsMode) -> [ChapterAnnotations]`
  - `static func visibleProjects(_ projects: [ProjectAnnotations], mode: AnnotationsMode) -> [ProjectAnnotations]` (returns each project with its chapters already filtered to the mode; drops projects left with none).

- [ ] **Step 1: Write the failing tests**

Add to `AnnotationLoadingTests.swift`:

```swift
    // MARK: - mode filters

    private func chapter(_ docId: String, open: Int, resolved: Int) -> ChapterAnnotations {
        ChapterAnnotations(
            docId: docId, chapterTitle: docId, groupTitle: nil,
            open: (0..<open).map { loaded("o\(docId)\($0)", docId: docId, status: .open) },
            resolved: (0..<resolved).map { loaded("r\(docId)\($0)", docId: docId, status: .accepted) })
    }

    func test_visibleChapters_open_hidesZeroOpen() {
        let chapters = [chapter("doc-a", open: 2, resolved: 1), chapter("doc-b", open: 0, resolved: 3)]
        XCTAssertEqual(AnnotationLoading.visibleChapters(chapters, mode: .open).map(\.docId), ["doc-a"])
        XCTAssertEqual(AnnotationLoading.visibleChapters(chapters, mode: .all).map(\.docId), ["doc-a", "doc-b"])
    }

    func test_visibleProjects_open_dropsFullyResolvedProject_all_keepsIt() {
        let p = ProjectAnnotations(
            id: "p1", projectName: "Novel", projectURL: URL(fileURLWithPath: "/tmp/p1"),
            chapters: [chapter("doc-b", open: 0, resolved: 3)])
        XCTAssertTrue(AnnotationLoading.visibleProjects([p], mode: .open).isEmpty)
        let all = AnnotationLoading.visibleProjects([p], mode: .all)
        XCTAssertEqual(all.map(\.id), ["p1"])
        XCTAssertEqual(all.first?.chapters.map(\.docId), ["doc-b"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/AnnotationLoadingTests`
Expected: FAIL — `AnnotationsMode` / `visibleChapters` / `visibleProjects` undefined.

- [ ] **Step 3: Write minimal implementation**

Add the mode enum at top-level in `AnnotationLoading.swift` (near the grouped types):

```swift
/// The Annotations tab's global scope toggle. `open` (default) drives triage;
/// `all` reveals fully-triaged chapters/projects for review.
enum AnnotationsMode: String, CaseIterable {
    case open, all
    var title: String { self == .open ? "Open" : "All" }
}
```

Add inside `enum AnnotationLoading`:

```swift
    /// Chapters visible in a mode: `open` keeps only chapters with ≥1 open note;
    /// `all` keeps any chapter with a note at all.
    static func visibleChapters(_ chapters: [ChapterAnnotations], mode: AnnotationsMode) -> [ChapterAnnotations] {
        switch mode {
        case .open: return chapters.filter { $0.openCount > 0 }
        case .all:  return chapters.filter { $0.openCount > 0 || $0.resolvedCount > 0 }
        }
    }

    /// Projects visible in a mode, each rebuilt with only its mode-visible
    /// chapters. A project left with no visible chapter is dropped.
    static func visibleProjects(_ projects: [ProjectAnnotations], mode: AnnotationsMode) -> [ProjectAnnotations] {
        projects.compactMap { p in
            let vis = visibleChapters(p.chapters, mode: mode)
            guard !vis.isEmpty else { return nil }
            return ProjectAnnotations(
                id: p.id, projectName: p.projectName, projectURL: p.projectURL, chapters: vis)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/AnnotationLoadingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MaughamPhone/Annotations/AnnotationLoading.swift MaughamPhoneTests/AnnotationLoadingTests.swift
git commit -m "feat(phone): AnnotationsMode + Open/All visibility filters"
```

---

## Task 4: `AnnotationStatusChip` (resolved-row status → label/symbol)

**Files:**
- Create: `MaughamPhone/Annotations/AnnotationStatusChip.swift`
- Test: `MaughamPhoneTests/AnnotationStatusChipTests.swift`

**Interfaces:**
- Produces:
  - `static func AnnotationStatusChip.label(_ s: AnnotationStatus) -> String?` (nil for `.open`)
  - `static func AnnotationStatusChip.symbol(_ s: AnnotationStatus) -> String?` (nil for `.open`)

- [ ] **Step 1: Write the failing test**

Create `MaughamPhoneTests/AnnotationStatusChipTests.swift`:

```swift
import XCTest
@testable import MaughamPhone
import MaughamCore

final class AnnotationStatusChipTests: XCTestCase {
    func test_openHasNoChip() {
        XCTAssertNil(AnnotationStatusChip.label(.open))
        XCTAssertNil(AnnotationStatusChip.symbol(.open))
    }

    func test_resolvedStatusesHaveLabelAndSymbol() {
        for status in [AnnotationStatus.accepted, .rejected, .archived] {
            XCTAssertNotNil(AnnotationStatusChip.label(status), "\(status) needs a label")
            XCTAssertNotNil(AnnotationStatusChip.symbol(status), "\(status) needs a symbol")
        }
        XCTAssertEqual(AnnotationStatusChip.label(.accepted), "Accepted")
        XCTAssertEqual(AnnotationStatusChip.label(.rejected), "Rejected")
        XCTAssertEqual(AnnotationStatusChip.label(.archived), "Archived")
    }
}
```

- [ ] **Step 2: Run test — first `./gen.sh` to pick up the new files, then verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/AnnotationStatusChipTests`
Expected: FAIL — `AnnotationStatusChip` undefined (test file compiles against nothing).

- [ ] **Step 3: Write minimal implementation**

Create `MaughamPhone/Annotations/AnnotationStatusChip.swift`:

```swift
import MaughamCore

/// Pure status → chip vocabulary for resolved annotation rows (All mode). Phone-
/// local presentation: MaughamCore owns the *kind* icon (`AnnotationKind.systemImageName`,
/// a cross-surface contract) but there is no shared *status* chip, so this stays
/// here. Out of a view body so it is trivially testable and the vocabulary lives
/// in one place.
enum AnnotationStatusChip {
    /// Human label for a resolved status; nil for `.open` (open rows show no chip).
    static func label(_ status: AnnotationStatus) -> String? {
        switch status {
        case .open:     return nil
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .archived: return "Archived"
        }
    }

    /// SF Symbol for a resolved status; nil for `.open`.
    static func symbol(_ status: AnnotationStatus) -> String? {
        switch status {
        case .open:     return nil
        case .accepted: return "checkmark.circle"
        case .rejected: return "xmark.circle"
        case .archived: return "archivebox"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/AnnotationStatusChipTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MaughamPhone/Annotations/AnnotationStatusChip.swift MaughamPhoneTests/AnnotationStatusChipTests.swift
git commit -m "feat(phone): AnnotationStatusChip status->label/symbol for resolved rows"
```

---

## Task 5: `AnnotationsStore` — @Observable load + grouped tree

**Files:**
- Create: `MaughamPhone/Annotations/AnnotationsStore.swift`
- Modify: `MaughamPhone/Annotations/AnnotationsListView.swift` (remove the moved logic in Task 8; for THIS task only create the store — the view still compiles as-is)

**Interfaces:**
- Produces `@MainActor @Observable final class AnnotationsStore`:
  - `init(projectsBrowser: ProjectsBrowser, downloads: DownloadCoordinator, recents: RecentsTracker)`
  - `private(set) var projects: [ProjectAnnotations]`
  - `private(set) var banner: AnnotationsBanner.Banner`
  - `private(set) var isLoading: Bool`
  - `private(set) var didLoad: Bool`
  - `func loadIfNeeded() async`
  - `func reload() async`
- Consumes: `AnnotationLoading.allAnnotations`, `AnnotationLoading.groupByChapter`, `OpLogStore`, `DownloadCoordinator`, `AnnotationsBanner`, `DownloadStateLite`.

- [ ] **Step 1: Create the store**

Create `MaughamPhone/Annotations/AnnotationsStore.swift`. The load / banner logic is moved verbatim from `AnnotationsListView` (`reload`, `openAnnotations(for:)` → generalized to `allAnnotations`, `refreshBanner`, `projectDownloadState`, `lite`), now producing the grouped tree:

```swift
import Foundation
import MaughamCore

/// Owns the Annotations tab's load + the grouped project→chapter tree, so the
/// three drill-down levels (root/chapters/notes) share one source of truth and a
/// resolve deep in the stack recomputes every level's counts on reload. Mirrors
/// `ProjectsBrowser`'s shape: plain `@Observable`, injected deps, `@MainActor`
/// (the UI observes on main). Heavy work stays off the render path — `reload` is
/// invoked from `.task`, the unlock button, pull-to-refresh, and the resolve
/// tick only (tripwire 4).
@MainActor
@Observable
final class AnnotationsStore {
    private let projectsBrowser: ProjectsBrowser
    private let downloads: DownloadCoordinator
    private let recents: RecentsTracker

    /// Every project with ≥1 note (open or resolved), each broken down by
    /// chapter. The view filters to Open/All via `AnnotationLoading.visibleProjects`.
    private(set) var projects: [ProjectAnnotations] = []
    private(set) var banner: AnnotationsBanner.Banner = .none
    private(set) var isLoading = false
    private(set) var didLoad = false

    init(projectsBrowser: ProjectsBrowser, downloads: DownloadCoordinator, recents: RecentsTracker) {
        self.projectsBrowser = projectsBrowser
        self.downloads = downloads
        self.recents = recents
    }

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        await reload()
    }

    /// Walk every project, load its annotations (all statuses), group by chapter,
    /// then recompute the recents' download banner.
    func reload() async {
        isLoading = true
        defer { isLoading = false; didLoad = true }

        var results: [ProjectAnnotations] = []
        for project in projectsBrowser.projects {
            let anns = await loadedAnnotations(for: project)
            guard !anns.isEmpty else { continue }
            let chapters = AnnotationLoading.groupByChapter(
                anns, structure: project.manifest.structure, research: project.manifest.research)
            results.append(ProjectAnnotations(
                id: project.id,
                projectName: project.manifest.title,
                projectURL: project.url,
                chapters: chapters))
        }
        projects = results
        await refreshBanner()
    }

    /// All annotations (open + resolved) for one project: enumerate `.maugham/ops/`,
    /// resolve distinct doc ids, fault each doc's op-log files in (best-effort —
    /// an evicted iCloud file reads as empty with NO error), load + derive.
    private func loadedAnnotations(for project: BrowsedProject) async -> [LoadedAnnotation] {
        let opsDir = project.url.appendingPathComponent(".maugham/ops", isDirectory: true)
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: opsDir.path)) ?? []
        let docIds = AnnotationLoading.docIds(inOpsDirectoryFilenames: filenames)
        guard !docIds.isEmpty else { return [] }

        let store = OpLogStore(projectURL: project.url)
        var all: [LoadedAnnotation] = []
        for docId in docIds {
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: project.url) {
                try? await downloads.ensureDownloaded(url)
            }
            guard let ops = try? await store.load(docId: docId) else { continue }
            all.append(contentsOf: AnnotationLoading.allAnnotations(ops: ops)
                .map { LoadedAnnotation(annotation: $0, docId: docId) })
        }
        return all
    }

    // MARK: - Banner (moved verbatim from AnnotationsListView)

    private func refreshBanner() async {
        let recentIds = recents.recents
        let recentProjects = projectsBrowser.projects.filter { recentIds.contains($0.id) }
        var states: [DownloadStateLite] = []
        for project in recentProjects {
            states.append(await projectDownloadState(project))
        }
        banner = AnnotationsBanner.banner(forRecentStates: states)
    }

    private func projectDownloadState(_ project: BrowsedProject) async -> DownloadStateLite {
        let opsDir = project.url.appendingPathComponent(".maugham/ops", isDirectory: true)
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: opsDir.path)) ?? []
        let docIds = AnnotationLoading.docIds(inOpsDirectoryFilenames: filenames)

        var urls: [URL] = []
        for docId in docIds {
            urls.append(contentsOf: OpLogStore.opLogFileURLs(forDocId: docId, in: project.url))
        }
        guard !urls.isEmpty else { return .downloaded }

        var lites: [DownloadStateLite] = []
        for url in urls {
            for await state in await downloads.observe(url) {
                lites.append(Self.lite(state))
                break
            }
        }
        if lites.contains(.downloading) { return .downloading }
        if lites.allSatisfy({ $0 == .failed }) && !lites.isEmpty { return .failed }
        if lites.contains(.notDownloaded) { return .notDownloaded }
        return .downloaded
    }

    private static func lite(_ state: DownloadCoordinator.DownloadState) -> DownloadStateLite {
        switch state {
        case .notDownloaded: return .notDownloaded
        case .downloading: return .downloading
        case .downloaded: return .downloaded
        case .failed: return .failed
        }
    }
}
```

- [ ] **Step 2: Regenerate + build-verify the store compiles**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. (`AnnotationsListView` still has its own copies of these helpers — that's fine; both compile. They're deduplicated in Task 8.)

- [ ] **Step 3: Commit**

```bash
git add MaughamPhone/Annotations/AnnotationsStore.swift
git commit -m "feat(phone): AnnotationsStore — @Observable load + grouped project/chapter tree"
```

---

## Task 6: `ChapterAnnotationsView` (leaf — OPEN + optional RESOLVED)

**Files:**
- Create: `MaughamPhone/Annotations/ChapterAnnotationsView.swift`

**Interfaces:**
- Produces `struct ChapterAnnotationsView: View` with init params:
  `chapter: ChapterAnnotations, projectId: ProjectId, projectURL: URL, recents: RecentsTracker, mode: AnnotationsMode, onResolved: () -> Void`
- Consumes: `AnnotationDetailView(annotation:projectId:projectURL:docId:recents:onResolved:)`, `AnnotationsIcons.kindSymbol`, `AnnotationStatusChip`.

- [ ] **Step 1: Create the view**

Create `MaughamPhone/Annotations/ChapterAnnotationsView.swift`:

```swift
import SwiftUI
import MaughamCore

/// Drill-down leaf: one chapter's notes. `Open` mode shows just the open notes;
/// `All` mode adds a dimmed RESOLVED section with status chips. Every row pushes
/// the unchanged `AnnotationDetailView`; resolved rows are read-only there (its
/// action buttons already hide for non-open annotations). Rows render only
/// pre-derived values (tripwire 4).
@MainActor
struct ChapterAnnotationsView: View {
    let chapter: ChapterAnnotations
    let projectId: ProjectId
    let projectURL: URL
    let recents: RecentsTracker
    let mode: AnnotationsMode
    var onResolved: () -> Void = {}

    var body: some View {
        List {
            Section(header: Text("Open")) {
                if chapter.open.isEmpty {
                    Text("No open notes").foregroundStyle(.secondary)
                } else {
                    ForEach(chapter.open) { loaded in
                        noteLink(loaded, resolved: false)
                    }
                }
            }
            if mode == .all && !chapter.resolved.isEmpty {
                Section(header: Text("Resolved")) {
                    ForEach(chapter.resolved) { loaded in
                        noteLink(loaded, resolved: true)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(chapter.chapterTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func noteLink(_ loaded: LoadedAnnotation, resolved: Bool) -> some View {
        NavigationLink {
            AnnotationDetailView(
                annotation: loaded.annotation,
                projectId: projectId,
                projectURL: projectURL,
                docId: loaded.docId,
                recents: recents,
                onResolved: onResolved)
        } label: {
            NoteRow(annotation: loaded.annotation, dimmed: resolved)
        }
    }
}

/// One note row: kind icon + body preview + (for a resolved row) a status chip.
/// Drops the project name the old cross-project list carried — we're already
/// inside a project→chapter.
private struct NoteRow: View {
    let annotation: Annotation
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: AnnotationsIcons.kindSymbol(annotation.kind))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(annotation.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let label = AnnotationStatusChip.label(annotation.status),
                       let symbol = AnnotationStatusChip.symbol(annotation.status) {
                        Label(label, systemImage: symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if annotation.isStale {
                        Text("stale")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.yellow.opacity(0.25), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(dimmed ? 0.6 : 1)
    }
}
```

- [ ] **Step 2: Regenerate + build-verify**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add MaughamPhone/Annotations/ChapterAnnotationsView.swift
git commit -m "feat(phone): ChapterAnnotationsView leaf — OPEN + dimmed RESOLVED sections"
```

---

## Task 7: `ProjectChaptersView` (middle — flat chapters, group headers)

**Files:**
- Create: `MaughamPhone/Annotations/ProjectChaptersView.swift`

**Interfaces:**
- Produces `struct ProjectChaptersView: View` with init params:
  `project: ProjectAnnotations, recents: RecentsTracker, mode: AnnotationsMode, onResolved: () -> Void`
  (the `project` passed in already has its chapters filtered to `mode` by the caller).
- Consumes: `ChapterAnnotationsView`.

- [ ] **Step 1: Create the view**

Create `MaughamPhone/Annotations/ProjectChaptersView.swift`:

```swift
import SwiftUI
import MaughamCore

/// Drill-down middle level: a project's chapters/pieces with notes, as a flat
/// list in binder order, sectioned under each chapter's parent-group title.
/// `project.chapters` is already filtered to the current mode by the caller.
/// Row taps push `ChapterAnnotationsView`. No parsing in a row body (tripwire 4).
@MainActor
struct ProjectChaptersView: View {
    let project: ProjectAnnotations
    let recents: RecentsTracker
    let mode: AnnotationsMode
    var onResolved: () -> Void = {}

    /// Chapters grouped into ordered (header, chapters) sections, preserving
    /// binder order. Computed once, not per row.
    private var sections: [(header: String?, chapters: [ChapterAnnotations])] {
        var out: [(String?, [ChapterAnnotations])] = []
        for chapter in project.chapters {
            if let last = out.last, last.0 == chapter.groupTitle {
                out[out.count - 1].1.append(chapter)
            } else {
                out.append((chapter.groupTitle, [chapter]))
            }
        }
        return out.map { (header: $0.0, chapters: $0.1) }
    }

    var body: some View {
        List {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section(header: section.header.map(Text.init)) {
                    ForEach(section.chapters) { chapter in
                        NavigationLink {
                            ChapterAnnotationsView(
                                chapter: chapter,
                                projectId: project.id,
                                projectURL: project.projectURL,
                                recents: recents,
                                mode: mode,
                                onResolved: onResolved)
                        } label: {
                            ChapterRow(chapter: chapter, mode: mode)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(project.projectName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One chapter row: title + open count, plus a muted "+N resolved" in All mode.
private struct ChapterRow: View {
    let chapter: ChapterAnnotations
    let mode: AnnotationsMode

    var body: some View {
        HStack {
            Text(chapter.chapterTitle)
            Spacer()
            Text("\(chapter.openCount)")
                .foregroundStyle(.secondary)
            if mode == .all && chapter.resolvedCount > 0 {
                Text("+\(chapter.resolvedCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
```

- [ ] **Step 2: Regenerate + build-verify**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add MaughamPhone/Annotations/ProjectChaptersView.swift
git commit -m "feat(phone): ProjectChaptersView middle level — flat chapters, group-header sections"
```

---

## Task 8: `AnnotationsListView` root — store-backed, Open/All, single-doc skip

**Files:**
- Modify: `MaughamPhone/Annotations/AnnotationsListView.swift`

**Interfaces:**
- The view's public init is unchanged (`projectsBrowser`, `downloads`, `recents`, `authGate`) so `MaughamPhoneApp` needs no edit. Internally it now owns an `AnnotationsStore` and reads from it.
- Consumes: `AnnotationsStore`, `AnnotationLoading.visibleProjects`, `ProjectChaptersView`, `ChapterAnnotationsView`, `AnnotationsMode`.

- [ ] **Step 1: Rewrite the view**

Replace the entire contents of `MaughamPhone/Annotations/AnnotationsListView.swift` with the store-backed root. This DELETES the nested `LoadedAnnotation` / `ProjectAnnotations` structs (now top-level in `AnnotationLoading`) and the moved load/banner helpers (now in `AnnotationsStore`), and KEEPS the `AnnotationsIcons` enum (still used by `ChapterAnnotationsView`'s row) and the unlock gate + empty state + banner row:

```swift
import SwiftUI
import MaughamCore

/// Annotations-tab root: the Projects level of a project → chapter → notes
/// drill-down, behind the optional Face ID gate. Heavy work lives in
/// `AnnotationsStore` (load + group once); this view renders mode-filtered
/// projects only. A global Open/All control reveals resolved notes for review.
/// Tapping a project pushes its chapters, or — when a project has exactly one
/// chapter visible in the current mode — skips straight to that chapter's notes.
@MainActor
struct AnnotationsListView: View {
    let projectsBrowser: ProjectsBrowser
    let downloads: DownloadCoordinator
    let recents: RecentsTracker
    let authGate: LaunchAuthGate

    @State private var store: AnnotationsStore
    @State private var mode: AnnotationsMode = .open
    /// Bumped by a detail view after it resolves an annotation, so the store
    /// reloads and counts recompute at every level.
    @State private var resolveTick = 0

    init(projectsBrowser: ProjectsBrowser, downloads: DownloadCoordinator, recents: RecentsTracker, authGate: LaunchAuthGate) {
        self.projectsBrowser = projectsBrowser
        self.downloads = downloads
        self.recents = recents
        self.authGate = authGate
        _store = State(initialValue: AnnotationsStore(
            projectsBrowser: projectsBrowser, downloads: downloads, recents: recents))
    }

    /// Projects visible in the current mode, chapters pre-filtered.
    private var visibleProjects: [ProjectAnnotations] {
        AnnotationLoading.visibleProjects(store.projects, mode: mode)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Annotations")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Scope", selection: $mode) {
                            ForEach(AnnotationsMode.allCases, id: \.self) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                    }
                }
                .onChange(of: resolveTick) { _, _ in
                    Task { if authGate.isUnlocked { await store.reload() } }
                }
                .task {
                    await authGate.evaluate()
                    if authGate.isUnlocked { await store.loadIfNeeded() }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !authGate.isUnlocked {
            unlockScreen
        } else if store.isLoading && !store.didLoad {
            ProgressView("Loading annotations…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleProjects.isEmpty {
            emptyState
        } else {
            projectList
        }
    }

    // MARK: - Unlock gate

    @ViewBuilder
    private var unlockScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Unlock to triage annotations")
                .font(.headline)
            if authGate.state == .evaluating {
                ProgressView()
            } else {
                Button {
                    Task {
                        await authGate.evaluate()
                        if authGate.isUnlocked { await store.loadIfNeeded() }
                    }
                } label: {
                    Label("Unlock with Face ID", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state (tripwire 15: both frames)

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            mode == .open ? "No open annotations" : "No annotations",
            systemImage: "checkmark.bubble",
            description: Text(mode == .open
                ? "Claude hasn’t left any open notes, or they’re all resolved."
                : "Claude hasn’t left any notes in your projects yet."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - The project list

    private var projectList: some View {
        List {
            if store.banner != .none {
                Section { bannerRow }
            }
            ForEach(recentSection) { project in
                projectRow(project)
            }
            .modifier(SectionHeaderIfPresent(recentSection.isEmpty ? nil : "Recent"))
            ForEach(otherSection) { project in
                projectRow(project)
            }
            .modifier(SectionHeaderIfPresent(otherSection.isEmpty ? nil : "Other projects"))
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.reload() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A project row whose destination skips the chapters level when only one
    /// chapter is visible in the current mode.
    @ViewBuilder
    private func projectRow(_ project: ProjectAnnotations) -> some View {
        NavigationLink {
            destination(for: project)
        } label: {
            ProjectSummaryRow(project: project, mode: mode)
        }
    }

    @ViewBuilder
    private func destination(for project: ProjectAnnotations) -> some View {
        if project.chapters.count == 1, let only = project.chapters.first {
            ChapterAnnotationsView(
                chapter: only,
                projectId: project.id,
                projectURL: project.projectURL,
                recents: recents,
                mode: mode,
                onResolved: { resolveTick &+= 1 })
        } else {
            ProjectChaptersView(
                project: project,
                recents: recents,
                mode: mode,
                onResolved: { resolveTick &+= 1 })
        }
    }

    @ViewBuilder
    private var bannerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: bannerIcon)
                .foregroundStyle(.secondary)
            Text(store.banner.text)
                .font(.callout)
            Spacer()
            switch store.banner {
            case .needsDownload:
                Button("Sync now") { Task { await store.reload() } }
                    .font(.callout)
            case .failed:
                Button("Retry") { Task { await store.reload() } }
                    .font(.callout)
            case .syncing, .none:
                EmptyView()
            }
        }
    }

    private var bannerIcon: String {
        switch store.banner {
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .needsDownload: return "icloud.and.arrow.down"
        case .failed: return "exclamationmark.icloud"
        case .none: return "icloud"
        }
    }

    // MARK: - Sectioning (Recent vs Other), preserved from the flat list

    private var recentSection: [ProjectAnnotations] {
        let recentIds = recents.recents
        return visibleProjects.filter { recentIds.contains($0.id) }
    }

    private var otherSection: [ProjectAnnotations] {
        let recentIds = recents.recents
        return visibleProjects.filter { !recentIds.contains($0.id) }
    }
}

/// Applies a `Section` header to a `ForEach` only when a title is present, so an
/// empty Recent/Other bucket contributes no stray header.
private struct SectionHeaderIfPresent: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let title {
            Section(header: Text(title)) { content }
        } else {
            content
        }
    }
}

/// One project row: name + open count, plus a muted "+N resolved" in All mode.
private struct ProjectSummaryRow: View {
    let project: ProjectAnnotations
    let mode: AnnotationsMode

    var body: some View {
        HStack {
            Text(project.projectName)
            Spacer()
            Text("\(project.openCount)")
                .foregroundStyle(.secondary)
            if mode == .all && project.resolvedCount > 0 {
                Text("+\(project.resolvedCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Pure SF-Symbol mapping for annotation kinds — shared by the drill-down rows.
/// Delegates to `AnnotationKind.systemImageName` (MaughamCore), the single source
/// of truth shared with the Mac surface.
enum AnnotationsIcons {
    static func kindSymbol(_ kind: AnnotationKind) -> String {
        kind.systemImageName
    }
}
```

- [ ] **Step 2: Regenerate + build-verify**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. If the compiler flags a duplicate `AnnotationsIcons`, `LoadedAnnotation`, or `ProjectAnnotations` — the old nested copies weren't removed; delete them from this file (they now live in `AnnotationLoading.swift`).

- [ ] **Step 3: Run the full phone test suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO`
Expected: PASS — all pre-existing phone tests plus the new `AnnotationLoadingTests` / `AnnotationStatusChipTests`. (Transient "Busy / failed preflight checks" → re-run.)

- [ ] **Step 4: Commit**

```bash
git add MaughamPhone/Annotations/AnnotationsListView.swift
git commit -m "feat(phone): Annotations root — drill-down over AnnotationsStore, Open/All, single-doc skip"
```

---

## Task 9: Core + Mac regression guard

The only shared-package touch is additive (new pure phone-target functions; no MaughamCore edit), but the two schemes are independent (CLAUDE.md) and MaughamCore builds into both. Confirm nothing in this change accidentally reached shared code.

- [ ] **Step 1: Verify no MaughamCore / Mac file changed**

Run (compares this feature's commits against `main` — swap `main` for the actual branch point if different): `git diff --name-only main...HEAD -- Packages/ Maugham/ | grep . || echo "NO SHARED/MAC FILES TOUCHED"`
Expected: `NO SHARED/MAC FILES TOUCHED` (only `MaughamPhone/`, `MaughamPhoneTests/`, and `docs/` in the diff). If the work was committed directly on `main`, diff against the pre-work commit instead (`git diff --name-only <first-plan-commit>^..HEAD -- Packages/ Maugham/`).

If any `Packages/` or `Maugham/` file shows up, stop — the change leaked out of the phone target; revisit.

- [ ] **Step 2: Build the Mac scheme (independent-schemes discipline)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED (MaughamCore still compiles for the Mac; nothing regressed).

- [ ] **Step 3: Commit (no-op if clean)**

No code change expected here. If Step 1/2 surfaced a fix, commit it:

```bash
git add -A
git commit -m "fix(phone): keep Annotations drill-down inside the phone target"
```

---

## Manual smoke (user-run, after the plan lands)

Per `MaughamPhone/AREA.md`'s smoke lesson — the seam bugs live at the iCloud / op-log boundary the unit tests mock away. On a running build (simulator or TestFlight):

1. Open Annotations → confirm the **Projects** level lists only projects with open notes; **Recent** sorts first.
2. Tap a multi-chapter project → confirm chapters appear **in binder order**, grouped under Act/group headers, with correct open counts.
3. Tap a **Screenplay** (single doc) → confirm it **skips** straight to the notes (no one-row chapter level).
4. Open a note → Accept/Reject/Archive → back out → confirm the **count drops** at chapter and project levels, and a fully-triaged chapter/project **disappears in Open mode**.
5. Flip to **All** → confirm fully-triaged chapters/projects reappear, and each chapter shows a dimmed **Resolved** section with Accepted/Rejected/Archived chips; opening a resolved note shows **no action buttons**.
6. Pull-to-refresh at the root; confirm the sync banner behaves as before.

---

## Self-Review

**Spec coverage:**
- Drill-down (project→chapter→notes) → Tasks 6, 7, 8. ✓
- `StructureItem.id == docId` mapping → Task 2 (`groupByChapter`). ✓
- Binder order + parent-group section headers → Task 2 + Task 7. ✓
- Research fallback + unmapped→"Other" (never dropped) → Task 2. ✓
- Single-document skip → Task 8 (`destination(for:)`). ✓
- `AnnotationsStore` single source of truth → Task 5. ✓
- Show-resolved Open/All global control → Task 3 (filters) + Task 8 (Picker). ✓
- Open-primary counts + muted resolved secondary → Tasks 7, 8 rows. ✓
- Leaf OPEN + dimmed RESOLVED with status chips → Tasks 4, 6. ✓
- Resolve loop (resolveTick → store.reload) → Task 8. ✓
- Recent/Other sectioning preserved → Task 8. ✓
- Face ID gate + banner + pull-to-refresh preserved → Tasks 5, 8. ✓
- Undo/reopen OUT of scope → not implemented (resolved rows read-only, Task 6). ✓
- Tripwires 3/4/5/15 + no-MaughamCore-change → Task 9 guard. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `LoadedAnnotation`/`ChapterAnnotations`/`ProjectAnnotations`/`AnnotationsMode` defined in Task 2–3 and consumed with the same field names in Tasks 5–8; `AnnotationsStore` init signature matches its construction in Task 8; `ChapterAnnotationsView`/`ProjectChaptersView` init params match their call sites; `AnnotationDetailView(annotation:projectId:projectURL:docId:recents:onResolved:)` matches the real initializer. ✓
```
