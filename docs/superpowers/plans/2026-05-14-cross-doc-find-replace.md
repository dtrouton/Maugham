# Cross-Document Find/Replace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two complementary find surfaces — re-enable NSTextView's built-in find bar (in-doc, `⌘F`) and add a new cross-document search via a conditional `BinderSegment.find` (`⌘⌥F`).

**Architecture:** A new `ProjectSearchEngine` value type walks `manifest.structure` + `manifest.research`, reads each document, emits `SearchMatch` records. `ProjectStore` exposes `currentSearch: SearchResults?` observable + per-match and bulk replace operations. A new `ProjectSearchView` SwiftUI binder segment hosts the search field, options, and grouped results. Click → editor jumps via notification + NSTextView selection.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (NSTextView find bar, NSRegularExpression), Foundation file IO.

**Reference spec:** `docs/superpowers/specs/2026-05-14-cross-doc-find-replace-design.md`

---

## File map

**Create:**
- `Maugham/Models/SearchMatch.swift` — `SearchMatch`, `SearchOptions`, `SearchResults`, `SearchDocumentSource`
- `Maugham/Stores/ProjectSearchEngine.swift` — pure value type, walks both trees, emits matches
- `Maugham/Views/ProjectSearchView.swift` — SwiftUI surface bound to `BinderSegment.find`
- `MaughamTests/ProjectSearchEngineTests.swift`
- `MaughamTests/ProjectSearchReplaceTests.swift`
- `MaughamTests/SearchInEditorJumpTests.swift`

**Modify:**
- `Maugham/Models/BinderSegment.swift` — add `.find` case
- `Maugham/Models/MaughamNotifications.swift` — `maughamFindInProject`, `maughamFindMatchSelected`
- `Maugham/Stores/ProjectStore.swift` — `currentSearch`, `searchInProgress`, `performSearch`, `clearSearch`, `replaceMatch`, `replaceAll`
- `Maugham/Editor/EditorSurface.swift` — flip `usesFindBar = true`, scroll-to-match observer
- `Maugham/Editor/EditorCoordinator.swift` — observer for find-match-selected → scroll + select
- `Maugham/Views/BinderPaneToggle.swift` — conditional `.find` segment
- `Maugham/Views/ProjectWindow.swift` — `findActive: Bool` state, `⌘⌥F` notification subscriber
- `Maugham/MaughamApp.swift` — `Find in Project…` command with `⌘⌥F`

---

## Phase 1 — Substrate: data model + engine

### Task 1: Data types

**Files:**
- Create: `Maugham/Models/SearchMatch.swift`
- Test: `MaughamTests/ProjectSearchEngineTests.swift` (test types only, engine in T2)

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/ProjectSearchEngineTests.swift`:

```swift
import XCTest
@testable import Maugham

final class SearchTypesTests: XCTestCase {
    func test_SearchMatch_isIdentifiable() {
        let m = SearchMatch(
            id: UUID(),
            documentPath: "manuscript/foo.md",
            documentTitle: "Foo",
            documentSource: .manuscript,
            lineNumber: 1,
            charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "foo bar",
            matchRangeInLine: NSRange(location: 0, length: 3))
        XCTAssertEqual(m.documentSource, .manuscript)
    }

    func test_SearchResults_countsMatchesAndDocuments() {
        let m1 = SearchMatch(
            id: UUID(), documentPath: "a.md", documentTitle: "A",
            documentSource: .manuscript, lineNumber: 1,
            charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "foo", matchRangeInLine: NSRange(location: 0, length: 3))
        let m2 = SearchMatch(
            id: UUID(), documentPath: "a.md", documentTitle: "A",
            documentSource: .manuscript, lineNumber: 2,
            charRangeInDocument: NSRange(location: 10, length: 3),
            linePreview: "foo", matchRangeInLine: NSRange(location: 0, length: 3))
        let m3 = SearchMatch(
            id: UUID(), documentPath: "b.md", documentTitle: "B",
            documentSource: .research, lineNumber: 1,
            charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "foo", matchRangeInLine: NSRange(location: 0, length: 3))
        let r = SearchResults(
            query: "foo", options: SearchOptions(), matches: [m1, m2, m3])
        XCTAssertEqual(r.matchCount, 3)
        XCTAssertEqual(r.documentCount, 2)
    }

    func test_SearchOptions_defaultsCaseInsensitiveNoWholeWord() {
        let o = SearchOptions()
        XCTAssertFalse(o.caseSensitive)
        XCTAssertFalse(o.wholeWord)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/SearchTypesTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8
```
Expected: COMPILE FAIL — types don't exist.

- [ ] **Step 3: Create the types**

Create `Maugham/Models/SearchMatch.swift`:

```swift
import Foundation

/// Which side of the project a search match came from.
public enum SearchDocumentSource: String, Codable, Sendable, Equatable {
    case manuscript
    case research
}

/// One occurrence of the search query inside a document.
public struct SearchMatch: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let documentPath: String
    public let documentTitle: String
    public let documentSource: SearchDocumentSource
    public let lineNumber: Int                // 1-indexed
    public let charRangeInDocument: NSRange   // Whole-document character range
    public let linePreview: String             // Possibly-truncated containing line
    public let matchRangeInLine: NSRange      // Range within linePreview to highlight

    public init(
        id: UUID = UUID(),
        documentPath: String,
        documentTitle: String,
        documentSource: SearchDocumentSource,
        lineNumber: Int,
        charRangeInDocument: NSRange,
        linePreview: String,
        matchRangeInLine: NSRange
    ) {
        self.id = id
        self.documentPath = documentPath
        self.documentTitle = documentTitle
        self.documentSource = documentSource
        self.lineNumber = lineNumber
        self.charRangeInDocument = charRangeInDocument
        self.linePreview = linePreview
        self.matchRangeInLine = matchRangeInLine
    }
}

/// User-selectable matching options. Both default to false (case-insensitive
/// non-whole-word search).
public struct SearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var wholeWord: Bool

    public init(caseSensitive: Bool = false, wholeWord: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

/// A finished search pass — query, options, all matches sorted by
/// (source, document path, line number).
public struct SearchResults: Equatable, Sendable {
    public let query: String
    public let options: SearchOptions
    public let matches: [SearchMatch]

    public init(query: String, options: SearchOptions, matches: [SearchMatch]) {
        self.query = query
        self.options = options
        self.matches = matches
    }

    public var matchCount: Int { matches.count }
    public var documentCount: Int { Set(matches.map(\.documentPath)).count }
}
```

- [ ] **Step 4: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/SearchTypesTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Full suite + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 489 tests, with 0 failures` (486 prior + 3 new).

```bash
git add Maugham/Models/SearchMatch.swift MaughamTests/ProjectSearchEngineTests.swift
git commit -m "feat: SearchMatch / SearchOptions / SearchResults types

Pure value types for cross-document search. SearchMatch carries
the document path, title, source (manuscript/research), 1-indexed
line number, whole-doc char range, and a containing-line preview
with the match's intra-line range. SearchResults summarizes match
+ document counts; SearchOptions defaults to case-insensitive
non-whole-word.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: ProjectSearchEngine — manuscript pass

**Files:**
- Create: `Maugham/Stores/ProjectSearchEngine.swift`
- Test: `MaughamTests/ProjectSearchEngineTests.swift` (append)

- [ ] **Step 1: Add failing tests**

Append to `MaughamTests/ProjectSearchEngineTests.swift`:

```swift
@MainActor
final class ProjectSearchEngineTests: XCTestCase {
    /// Build a project on disk with manuscript items, return its URL.
    private func makeProject(manuscript: [(slug: String, content: String)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchEngine-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        var structure: [StructureItem] = []
        for (slug, content) in manuscript {
            try content.write(
                to: tmp.appendingPathComponent("manuscript/\(slug).md"),
                atomically: true, encoding: .utf8)
            structure.append(StructureItem(
                id: "ms-\(slug)", title: slug, type: .document,
                path: "manuscript/\(slug).md"))
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    func test_search_findsMatchInOneDocument() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "She walked to the kitchen.\nIt was empty.\n")
        ])
        let store = try await ProjectStore.load(from: project)

        let engine = ProjectSearchEngine()
        let results = await engine.search(
            query: "kitchen", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 1)
        XCTAssertEqual(results.matches[0].documentPath, "manuscript/chapter-1.md")
        XCTAssertEqual(results.matches[0].lineNumber, 1)
        XCTAssertEqual(results.matches[0].documentSource, .manuscript)
        XCTAssertEqual(results.matches[0].linePreview, "She walked to the kitchen.")
        XCTAssertEqual(results.matches[0].matchRangeInLine.length, 7)
    }

    func test_search_findsMultipleMatchesAcrossDocuments() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "kitchen scene one.\nkitchen scene two.\n"),
            ("chapter-2", "another kitchen.\nno match here.\n")
        ])
        let store = try await ProjectStore.load(from: project)

        let engine = ProjectSearchEngine()
        let results = await engine.search(
            query: "kitchen", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 3)
        XCTAssertEqual(results.documentCount, 2)
        // Sorted: chapter-1 lines 1,2 then chapter-2 line 1
        XCTAssertEqual(results.matches[0].documentPath, "manuscript/chapter-1.md")
        XCTAssertEqual(results.matches[0].lineNumber, 1)
        XCTAssertEqual(results.matches[1].lineNumber, 2)
        XCTAssertEqual(results.matches[2].documentPath, "manuscript/chapter-2.md")
    }

    func test_search_emptyQuery_returnsEmptyResults() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "some content\n")
        ])
        let store = try await ProjectStore.load(from: project)

        let results = await ProjectSearchEngine().search(
            query: "", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 0)
        XCTAssertEqual(results.query, "")
    }

    func test_search_caseInsensitiveByDefault() async throws {
        let project = try makeProject(manuscript: [
            ("c", "Kitchen\nKITCHEN\nkitchen\n")
        ])
        let store = try await ProjectStore.load(from: project)

        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 3)
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectSearchEngineTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8
```
Expected: COMPILE FAIL — `ProjectSearchEngine` doesn't exist.

- [ ] **Step 3: Implement ProjectSearchEngine (manuscript pass)**

Create `Maugham/Stores/ProjectSearchEngine.swift`:

```swift
import Foundation

/// Walks all manuscript + research-note documents and returns matches for
/// a query. Pure value type — no observable state, callers own caching.
@MainActor
public struct ProjectSearchEngine {
    public init() {}

    /// Run a search against the given project store. Reads files from disk
    /// (callers should flush pending writes first via DocumentStore).
    /// Yields between documents so cancellation can interrupt.
    public func search(
        query: String,
        options: SearchOptions,
        in store: ProjectStore
    ) async -> SearchResults {
        guard !query.isEmpty else {
            return SearchResults(query: query, options: options, matches: [])
        }

        var allMatches: [SearchMatch] = []

        // Manuscript pass
        let manuscriptDocs = Self.flattenManuscriptDocs(store.manifest.structure)
        for (item, fullPath) in manuscriptDocs {
            await Task.yield()
            if Task.isCancelled { break }
            let url = store.url.appendingPathComponent(fullPath)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let matches = Self.matchesIn(
                content: content,
                query: query,
                options: options,
                documentPath: fullPath,
                documentTitle: item.title,
                documentSource: .manuscript)
            allMatches.append(contentsOf: matches)
        }

        return SearchResults(query: query, options: options, matches: allMatches)
    }

    /// Recursively flatten structure tree, returning (item, path) pairs for
    /// .document-type items only. Group items are walked but not emitted.
    private static func flattenManuscriptDocs(
        _ items: [StructureItem]
    ) -> [(item: StructureItem, path: String)] {
        var out: [(item: StructureItem, path: String)] = []
        for item in items {
            switch item.type {
            case .document:
                if let path = item.path {
                    out.append((item, path))
                }
            case .group:
                if let children = item.children {
                    out.append(contentsOf: flattenManuscriptDocs(children))
                }
            }
        }
        return out
    }

    /// Find all matches of `query` in `content` according to `options`.
    /// Returns matches in document order.
    private static func matchesIn(
        content: String,
        query: String,
        options: SearchOptions,
        documentPath: String,
        documentTitle: String,
        documentSource: SearchDocumentSource
    ) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        let nsContent = content as NSString
        let lines = content.components(separatedBy: "\n")

        var lineStartOffset = 0
        for (i, line) in lines.enumerated() {
            let lineNumber = i + 1
            let nsLine = line as NSString

            let lineRanges = findRanges(in: nsLine, query: query, options: options)
            for r in lineRanges {
                let docRange = NSRange(
                    location: lineStartOffset + r.location,
                    length: r.length)
                let preview = Self.truncatePreview(line: line, around: r)
                matches.append(SearchMatch(
                    documentPath: documentPath,
                    documentTitle: documentTitle,
                    documentSource: documentSource,
                    lineNumber: lineNumber,
                    charRangeInDocument: docRange,
                    linePreview: preview.text,
                    matchRangeInLine: preview.range))
            }

            lineStartOffset += nsLine.length + 1  // +1 for the newline
        }
        _ = nsContent  // silence unused warning
        return matches
    }

    /// Find all match ranges in a single line.
    private static func findRanges(
        in line: NSString,
        query: String,
        options: SearchOptions
    ) -> [NSRange] {
        var ranges: [NSRange] = []

        if options.wholeWord {
            let escaped = NSRegularExpression.escapedPattern(for: query)
            let pattern = "\\b\(escaped)\\b"
            let regexOptions: NSRegularExpression.Options =
                options.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: regexOptions) else { return [] }
            let fullRange = NSRange(location: 0, length: line.length)
            regex.enumerateMatches(in: line as String, options: [], range: fullRange) { match, _, _ in
                if let r = match?.range { ranges.append(r) }
            }
        } else {
            let searchOptions: NSString.CompareOptions =
                options.caseSensitive ? [] : [.caseInsensitive]
            var startLocation = 0
            while startLocation < line.length {
                let remaining = NSRange(
                    location: startLocation,
                    length: line.length - startLocation)
                let r = line.range(
                    of: query, options: searchOptions, range: remaining)
                if r.location == NSNotFound { break }
                ranges.append(r)
                startLocation = r.location + max(r.length, 1)
            }
        }

        return ranges
    }

    /// Truncate long lines to ~120 chars centered on the match, with ellipsis
    /// markers. Re-computes the match range against the truncated string.
    private static func truncatePreview(
        line: String, around range: NSRange
    ) -> (text: String, range: NSRange) {
        let maxLength = 120
        let nsLine = line as NSString
        if nsLine.length <= maxLength {
            return (line, range)
        }

        let halfWindow = (maxLength - range.length) / 2
        let leftStart = max(0, range.location - halfWindow)
        let rightEnd = min(nsLine.length, range.location + range.length + halfWindow)
        let prefix = leftStart > 0 ? "…" : ""
        let suffix = rightEnd < nsLine.length ? "…" : ""

        let segment = nsLine.substring(with: NSRange(
            location: leftStart, length: rightEnd - leftStart))
        let truncated = "\(prefix)\(segment)\(suffix)"
        let newMatchStart = (prefix as NSString).length + (range.location - leftStart)
        let newRange = NSRange(location: newMatchStart, length: range.length)
        return (truncated, newRange)
    }
}
```

- [ ] **Step 4: Run targeted + full**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectSearchEngineTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 4 tests, with 0 failures`.

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 493 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectSearchEngine.swift MaughamTests/ProjectSearchEngineTests.swift
git commit -m "feat: ProjectSearchEngine manuscript pass

Walks manifest.structure flat-recursively, emits SearchMatch per
line match per .document item with a path. Case-insensitive by
default. Whole-word uses regex with \\b boundaries; non-whole-word
uses NSString.range(of:options:). Line previews truncated to
~120 chars centered on the match. Yields between documents so
caller-side task cancellation works.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Engine — research notes + options

**Files:**
- Modify: `Maugham/Stores/ProjectSearchEngine.swift`
- Modify: `MaughamTests/ProjectSearchEngineTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `ProjectSearchEngineTests`:

```swift
    private func makeProjectWithResearch(
        manuscript: [(String, String)],
        research: [(String, String)]
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchEngineFull-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)

        var structure: [StructureItem] = []
        for (slug, content) in manuscript {
            try content.write(
                to: tmp.appendingPathComponent("manuscript/\(slug).md"),
                atomically: true, encoding: .utf8)
            structure.append(StructureItem(
                id: "ms-\(slug)", title: slug, type: .document,
                path: "manuscript/\(slug).md"))
        }

        var researchItems: [ResearchItem] = []
        for (slug, content) in research {
            try content.write(
                to: tmp.appendingPathComponent("research/\(slug).md"),
                atomically: true, encoding: .utf8)
            researchItems.append(ResearchItem(
                id: "res-\(slug)", title: slug, type: .asset, kind: .document,
                path: "research/\(slug).md", addedAt: Date()))
        }

        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: researchItems)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    func test_search_findsInResearchNotes() async throws {
        let project = try makeProjectWithResearch(
            manuscript: [("c1", "kitchen\n")],
            research: [("sarah", "Sarah hates the kitchen.\n")])
        let store = try await ProjectStore.load(from: project)

        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 2)
        XCTAssertEqual(results.documentCount, 2)
        let manuscriptMatches = results.matches.filter { $0.documentSource == .manuscript }
        let researchMatches = results.matches.filter { $0.documentSource == .research }
        XCTAssertEqual(manuscriptMatches.count, 1)
        XCTAssertEqual(researchMatches.count, 1)
    }

    func test_search_caseSensitive_excludesMismatchedCase() async throws {
        let project = try makeProject(manuscript: [
            ("c", "Kitchen\nKITCHEN\nkitchen\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let options = SearchOptions(caseSensitive: true, wholeWord: false)
        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: options, in: store)

        XCTAssertEqual(results.matchCount, 1)
        XCTAssertEqual(results.matches[0].lineNumber, 3)
    }

    func test_search_wholeWord_excludesSubstringMatches() async throws {
        let project = try makeProject(manuscript: [
            ("c", "kitchenette is not it\nkitchen is\nfit kitchen there\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let options = SearchOptions(caseSensitive: false, wholeWord: true)
        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: options, in: store)

        XCTAssertEqual(results.matchCount, 2,
            "expected kitchenette excluded (substring); kitchen lines 2 + 3 matched")
        XCTAssertEqual(results.matches[0].lineNumber, 2)
        XCTAssertEqual(results.matches[1].lineNumber, 3)
    }

    func test_search_regexSpecialCharsInQuery_treatedLiterally() async throws {
        let project = try makeProject(manuscript: [
            ("c", "a.b matches dot literal\nacb does not\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let results = await ProjectSearchEngine().search(
            query: "a.b", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 1)
        XCTAssertEqual(results.matches[0].lineNumber, 1)
    }
```

- [ ] **Step 2: Verify failures**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectSearchEngineTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: 4 failures (research, case-sensitive, whole-word — case-sensitive passes by accident if T2 was case-insensitive, but verify; the regex-special-chars test passes by accident with the `.range(of:)` path since that's plain-text matching, but verify).

Adjust expected count based on what actually fails.

- [ ] **Step 3: Extend `search` to also walk research**

In `ProjectSearchEngine.swift`, add a research-walking helper:

```swift
/// Flatten research tree, returning (item, path) pairs for .document-kind
/// items whose path ends with .md.
private static func flattenResearchDocs(
    _ items: [ResearchItem]
) -> [(item: ResearchItem, path: String)] {
    var out: [(item: ResearchItem, path: String)] = []
    for item in items {
        if item.type == .asset,
           item.kind == .document,
           let path = item.path,
           path.hasSuffix(".md") {
            out.append((item, path))
        }
        if let children = item.children {
            out.append(contentsOf: flattenResearchDocs(children))
        }
    }
    return out
}
```

In `search(...)`, after the manuscript loop, add the research loop:

```swift
// Research pass
let researchDocs = Self.flattenResearchDocs(store.manifest.research)
for (item, fullPath) in researchDocs {
    await Task.yield()
    if Task.isCancelled { break }
    let url = store.url.appendingPathComponent(fullPath)
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
    let matches = Self.matchesIn(
        content: content,
        query: query,
        options: options,
        documentPath: fullPath,
        documentTitle: item.title,
        documentSource: .research)
    allMatches.append(contentsOf: matches)
}
```

The `matchesIn` function already honors `options.caseSensitive` and `options.wholeWord` — the case-sensitive and whole-word tests should pass without further changes (verify; if not, adjust `findRanges` to honor the options correctly).

Regex-special-chars test: `findRanges` non-whole-word path uses `.range(of:)` which is literal — passes. Whole-word path uses `NSRegularExpression.escapedPattern(for:)` — also literal. Both safe.

- [ ] **Step 4: Run targeted + full**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectSearchEngineTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 8 tests, with 0 failures`.

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 497 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectSearchEngine.swift MaughamTests/ProjectSearchEngineTests.swift
git commit -m "feat: search includes research notes; case + whole-word options

Walks manifest.research flat-recursively, includes .document-kind
items with .md paths. matchesIn now correctly honors options:
- caseSensitive false (default) → .caseInsensitive
- wholeWord true → regex with \\b boundaries
- regex-special chars in query are escaped before regex use
- non-whole-word uses NSString.range(of:options:) for speed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — ProjectStore integration: observable search + replace

### Task 4: ProjectStore — performSearch + currentSearch observable + debounce

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: `MaughamTests/ProjectSearchEngineTests.swift` (add a test for store-level search)

- [ ] **Step 1: Add failing test**

Append to `ProjectSearchEngineTests`:

```swift
    func test_store_performSearch_populatesCurrentSearch() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)

        await store.performSearch(query: "kitchen", options: SearchOptions())
        // Wait for debounce + execution
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNotNil(store.currentSearch)
        XCTAssertEqual(store.currentSearch?.matchCount, 1)
    }

    func test_store_clearSearch_resetsCurrentSearch() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)

        await store.performSearch(query: "kitchen", options: SearchOptions())
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotNil(store.currentSearch)

        store.clearSearch()
        XCTAssertNil(store.currentSearch)
    }
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectSearchEngineTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8
```
Expected: COMPILE FAIL — `performSearch`, `clearSearch`, `currentSearch` don't exist.

- [ ] **Step 3: Add stored properties + methods to ProjectStore**

In `Maugham/Stores/ProjectStore.swift`, add stored properties near the existing observable state:

```swift
public private(set) var currentSearch: SearchResults?
public private(set) var searchInProgress: Bool = false
private var searchTask: Task<Void, Never>?
```

Add public methods (place near the existing surface — after `updateInspector` is a reasonable spot):

```swift
/// Run a cross-document search. Cancels any in-flight search; debounces 300ms.
/// Flushes pending writes for the active document first so the search reads
/// the freshest content from disk.
public func performSearch(
    query: String, options: SearchOptions
) async {
    searchTask?.cancel()

    let task = Task { [weak self] in
        // Debounce
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }
        guard let self else { return }

        // Pre-search flush so disk reflects active-doc edits
        try? await self.documentStore?.flushPendingSave()
        if Task.isCancelled { return }

        await MainActor.run { self.searchInProgress = true }

        let engine = ProjectSearchEngine()
        let results = await engine.search(query: query, options: options, in: self)

        if Task.isCancelled { return }

        await MainActor.run {
            self.currentSearch = results
            self.searchInProgress = false
        }
    }
    searchTask = task
}

public func clearSearch() {
    searchTask?.cancel()
    searchTask = nil
    currentSearch = nil
    searchInProgress = false
}
```

If `ProjectStore` is `@MainActor`, the explicit `MainActor.run` wraps may be redundant — adapt to whatever isolation is in place. The key is that `currentSearch` updates trigger Observable view re-renders.

- [ ] **Step 4: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectSearchEngineTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 10 tests, with 0 failures`.

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 499 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectSearchEngineTests.swift
git commit -m "feat: ProjectStore exposes currentSearch + performSearch / clearSearch

300ms debounce on performSearch; pre-search flush via
documentStore.flushPendingSave so disk reflects active-doc edits.
Cancellation chains through both debounce and engine walks.
currentSearch and searchInProgress are Observable, drive the
Find binder segment in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: ProjectStore — replaceMatch (single)

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: `MaughamTests/ProjectSearchReplaceTests.swift` (new)

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/ProjectSearchReplaceTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class ProjectSearchReplaceTests: XCTestCase {
    private func makeProject(manuscript: [(String, String)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchReplace-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        var structure: [StructureItem] = []
        for (slug, content) in manuscript {
            try content.write(
                to: tmp.appendingPathComponent("manuscript/\(slug).md"),
                atomically: true, encoding: .utf8)
            structure.append(StructureItem(
                id: "ms-\(slug)", title: slug, type: .document,
                path: "manuscript/\(slug).md"))
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    func test_replaceMatch_writesNewContentToDisk() async throws {
        let project = try makeProject(manuscript: [
            ("c1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let matches = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store).matches
        XCTAssertEqual(matches.count, 1)

        try await store.replaceMatch(matches[0], with: "library")

        let content = try String(
            contentsOf: project.appendingPathComponent("manuscript/c1.md"))
        XCTAssertEqual(content, "the library is empty\n")
    }

    func test_replaceMatch_withEmptyString_deletesMatch() async throws {
        let project = try makeProject(manuscript: [
            ("c1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let matches = await ProjectSearchEngine().search(
            query: "kitchen ", options: SearchOptions(), in: store).matches
        XCTAssertEqual(matches.count, 1)

        try await store.replaceMatch(matches[0], with: "")

        let content = try String(
            contentsOf: project.appendingPathComponent("manuscript/c1.md"))
        XCTAssertEqual(content, "the is empty\n")
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectSearchReplaceTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: COMPILE FAIL — `replaceMatch` doesn't exist.

- [ ] **Step 3: Implement `replaceMatch`**

In `ProjectStore.swift`, add:

```swift
/// Replace a single search match with the given replacement text.
/// Loads the file, splices the replacement into the match's char range,
/// saves via the document store.
public func replaceMatch(
    _ match: SearchMatch, with replacement: String
) async throws {
    let url = self.url.appendingPathComponent(match.documentPath)
    let original = try String(contentsOf: url, encoding: .utf8)
    let ns = original as NSString
    guard match.charRangeInDocument.location + match.charRangeInDocument.length
            <= ns.length else {
        // Stale match (file changed since search). Caller should re-run search.
        throw ProjectStoreError.fileSystemError("Match range out of bounds")
    }
    let updated = ns.replacingCharacters(
        in: match.charRangeInDocument, with: replacement) as String
    try updated.write(to: url, atomically: true, encoding: .utf8)
}
```

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 501 tests, with 0 failures`.

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectSearchReplaceTests.swift
git commit -m "feat: ProjectStore.replaceMatch for single-match replacement

Loads file, splices replacement at match.charRangeInDocument,
writes atomically. Empty replacement deletes the match. Throws
if the match range no longer fits (e.g., document edited since
search) — caller re-runs search to refresh.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: ProjectStore — replaceAll (right-to-left within each doc)

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Modify: `MaughamTests/ProjectSearchReplaceTests.swift`

- [ ] **Step 1: Add failing tests**

Append:

```swift
    func test_replaceAll_replacesAllMatchesPerDoc() async throws {
        let project = try makeProject(manuscript: [
            ("c1", "kitchen here\nand kitchen there\n"),
            ("c2", "no kitchen anywhere\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store)
        XCTAssertEqual(results.matchCount, 3)

        try await store.replaceAll(in: results, with: "library")

        let c1 = try String(contentsOf: project.appendingPathComponent("manuscript/c1.md"))
        let c2 = try String(contentsOf: project.appendingPathComponent("manuscript/c2.md"))
        XCTAssertEqual(c1, "library here\nand library there\n")
        XCTAssertEqual(c2, "no library anywhere\n")
    }

    func test_replaceAll_rightToLeftOrderPreservesOffsets() async throws {
        // Multiple matches on the same line; offsets must apply right-to-left
        // so earlier matches' ranges stay valid.
        let project = try makeProject(manuscript: [
            ("c1", "ab ab ab\n")  // 3 matches of "ab" at offsets 0, 3, 6
        ])
        let store = try await ProjectStore.load(from: project)
        let results = await ProjectSearchEngine().search(
            query: "ab", options: SearchOptions(), in: store)
        XCTAssertEqual(results.matchCount, 3)

        try await store.replaceAll(in: results, with: "XYZ")  // longer than "ab"

        let content = try String(contentsOf: project.appendingPathComponent("manuscript/c1.md"))
        XCTAssertEqual(content, "XYZ XYZ XYZ\n")
    }
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectSearchReplaceTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: 2 failures.

- [ ] **Step 3: Implement `replaceAll`**

In `ProjectStore.swift`:

```swift
/// Replace all matches in the given results with `replacement`.
/// Groups by document; applies replacements right-to-left within each
/// document so earlier offsets aren't shifted by later edits.
public func replaceAll(
    in results: SearchResults, with replacement: String
) async throws {
    let grouped = Dictionary(grouping: results.matches, by: \.documentPath)
    for (path, matches) in grouped {
        let url = self.url.appendingPathComponent(path)
        let original = try String(contentsOf: url, encoding: .utf8)
        var ns = original as NSString
        // Right-to-left order
        let ordered = matches.sorted { $0.charRangeInDocument.location > $1.charRangeInDocument.location }
        for match in ordered {
            // Guard against out-of-bounds in case content changed
            guard match.charRangeInDocument.location + match.charRangeInDocument.length
                    <= ns.length else { continue }
            ns = ns.replacingCharacters(
                in: match.charRangeInDocument, with: replacement) as NSString
        }
        try (ns as String).write(to: url, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 503 tests, with 0 failures`.

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectSearchReplaceTests.swift
git commit -m "feat: ProjectStore.replaceAll groups by doc, right-to-left

Groups matches by documentPath. Within each doc, applies
replacements in descending location order so earlier matches'
ranges stay valid as later ones shift. One atomic write per
affected document.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — UI: binder segment, search view, editor integration

### Task 7: `BinderSegment.find` + conditional picker

**Files:**
- Modify: `Maugham/Models/BinderSegment.swift`
- Modify: `Maugham/Views/BinderPaneToggle.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Add enum case**

In `Maugham/Models/BinderSegment.swift`:

```swift
public enum BinderSegment: String, Codable, Equatable, Sendable {
    case manuscript
    case research
    case scenes
    case trash
    case find   // NEW
}
```

- [ ] **Step 2: Add findActive state to ProjectWindow**

In `Maugham/Views/ProjectWindow.swift`, near other `@State`:

```swift
@State private var findActive: Bool = false
```

(No init or persistence — purely session-scoped.)

- [ ] **Step 3: Conditional picker in BinderPaneToggle**

In `Maugham/Views/BinderPaneToggle.swift`, find the Picker block. Add `Find` segment conditionally and add a body case that renders a placeholder for now (real view in T8):

```swift
// In the Picker:
if findActive {
    Text("Find").tag(BinderSegment.find)
}

// In the body switch:
case .find:
    Text("Find UI lands in Task 8")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
```

Add a `findActive: Bool` Binding parameter to BinderPaneToggle and thread it through from ProjectWindow's call site.

Also add a coercion `.onChange(of: findActive)` that, when findActive becomes false, snaps `segment` back to `.manuscript`:

```swift
.onChange(of: findActive) { _, newValue in
    if !newValue && segment == .find {
        segment = projectType == .screenplay ? .scenes : .manuscript
    }
}
```

- [ ] **Step 4: Build verification**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run full suite + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 503 tests, with 0 failures`.

```bash
git add Maugham/Models/BinderSegment.swift Maugham/Views/BinderPaneToggle.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: BinderSegment.find + conditional picker

Adds a 4th 'Find' segment in BinderPaneToggle, shown only when
findActive is true (driven from ProjectWindow). Placeholder body;
ProjectSearchView lands in the next task. Auto-coerces back to
manuscript/scenes when findActive turns off mid-active state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: ProjectSearchView (search field + results list + per-row replace)

**Files:**
- Create: `Maugham/Views/ProjectSearchView.swift`
- Modify: `Maugham/Views/BinderPaneToggle.swift`

- [ ] **Step 1: Create the view**

Create `Maugham/Views/ProjectSearchView.swift`:

```swift
import SwiftUI

struct ProjectSearchView: View {
    @Bindable var store: ProjectStore
    @Binding var isActive: Bool

    @State private var query: String = ""
    @State private var replacement: String = ""
    @State private var options: SearchOptions = SearchOptions()
    @State private var showReplace: Bool = false
    @State private var pendingError: String?
    @State private var showingReplaceAllConfirm: Bool = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            DispatchQueue.main.async { queryFocused = true }
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: options) { _, _ in scheduleSearch() }
        .confirmationDialog(
            "Replace all matches?",
            isPresented: $showingReplaceAllConfirm
        ) {
            Button("Replace All", role: .destructive) {
                Task { await runReplaceAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(store.currentSearch?.matchCount ?? 0) matches will be replaced.")
        }
        .alert("Search error",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Find in project", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                Button {
                    isActive = false
                    store.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Toggle("Replace…", isOn: $showReplace)
                .toggleStyle(.switch)
                .controlSize(.small)
            if showReplace {
                HStack {
                    TextField("Replace with", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                    Button("Replace All") {
                        showingReplaceAllConfirm = true
                    }
                    .disabled(store.currentSearch?.matchCount ?? 0 == 0)
                }
            }
            HStack(spacing: 16) {
                Toggle("Aa", isOn: Binding(
                    get: { options.caseSensitive },
                    set: { options.caseSensitive = $0 }))
                    .toggleStyle(.button)
                    .help("Case sensitive")
                Toggle("W", isOn: Binding(
                    get: { options.wholeWord },
                    set: { options.wholeWord = $0 }))
                    .toggleStyle(.button)
                    .help("Whole word")
                Spacer()
                if let r = store.currentSearch {
                    Text("\(r.matchCount) in \(r.documentCount) docs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if store.searchInProgress {
            VStack { ProgressView().padding() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let r = store.currentSearch, !r.matches.isEmpty {
            resultsList(r)
        } else if !query.isEmpty {
            VStack {
                Text("No matches")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Text("Type to search across manuscript and research")
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultsList(_ results: SearchResults) -> some View {
        let grouped = Dictionary(grouping: results.matches, by: \.documentPath)
        let sortedKeys = grouped.keys.sorted { (a, b) in
            let aIsManuscript = a.hasPrefix("manuscript/")
            let bIsManuscript = b.hasPrefix("manuscript/")
            if aIsManuscript != bIsManuscript { return aIsManuscript }
            return a < b
        }
        return List {
            ForEach(sortedKeys, id: \.self) { path in
                if let matches = grouped[path], !matches.isEmpty {
                    Section(header: Text("\(matches[0].documentTitle) — \(matches.count) match\(matches.count == 1 ? "" : "es")")) {
                        ForEach(matches) { match in
                            row(for: match)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(for match: SearchMatch) -> some View {
        HStack(spacing: 8) {
            Text("\(match.lineNumber)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
            Text(highlightedPreview(for: match))
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 4)
            if showReplace {
                Button {
                    Task { await runReplaceMatch(match) }
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.plain)
                .help("Replace this match")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            NotificationCenter.default.post(
                name: .maughamFindMatchSelected,
                object: nil,
                userInfo: ["match": match])
        }
    }

    private func highlightedPreview(for match: SearchMatch) -> AttributedString {
        var attr = AttributedString(match.linePreview)
        let nsPreview = match.linePreview as NSString
        let r = match.matchRangeInLine
        guard r.location >= 0,
              r.location + r.length <= nsPreview.length else { return attr }
        if let strRange = Range(r, in: match.linePreview),
           let attrRange = Range(strRange, in: attr) {
            attr[attrRange].backgroundColor = .yellow.opacity(0.4)
        }
        return attr
    }

    private func scheduleSearch() {
        Task {
            await store.performSearch(query: query, options: options)
        }
    }

    private func runReplaceMatch(_ match: SearchMatch) async {
        do {
            try await store.replaceMatch(match, with: replacement)
            await store.performSearch(query: query, options: options)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func runReplaceAll() async {
        guard let r = store.currentSearch else { return }
        do {
            try await store.replaceAll(in: r, with: replacement)
            await store.performSearch(query: query, options: options)
        } catch {
            pendingError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Replace placeholder in BinderPaneToggle**

In `Maugham/Views/BinderPaneToggle.swift`, change the `.find` body case:

```swift
case .find:
    ProjectSearchView(store: store, isActive: $findActive)
```

- [ ] **Step 3: Add the maughamFindMatchSelected notification name**

In `Maugham/Models/MaughamNotifications.swift`, append:

```swift
public static let maughamFindMatchSelected = Notification.Name("maugham.find.match.selected")
```

- [ ] **Step 4: Build + run full suite + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 503 tests, with 0 failures` (no new tests; T11 covers the jump integration).

```bash
git add Maugham/Views/ProjectSearchView.swift Maugham/Views/BinderPaneToggle.swift Maugham/Models/MaughamNotifications.swift
git commit -m "feat: ProjectSearchView with grouped results + per-row replace

Live-debounced search via store.performSearch on query/options
change. Results grouped by document with line-number gutter and
highlighted-range previews. Per-row Replace icon when the Replace
disclosure is open. Replace All button with confirmation modal.
Click row posts maughamFindMatchSelected for editor jump (wired
in T11).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: `⌘⌥F` Find in Project menu command + ⌘F find bar enable

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Modify: `Maugham/Editor/EditorSurface.swift`

- [ ] **Step 1: Add notification + menu command**

In `Maugham/Models/MaughamNotifications.swift`:

```swift
public static let maughamFindInProject = Notification.Name("maugham.find.in.project")
```

In `Maugham/MaughamApp.swift`, find the `.commands { ... }` block. Add a command (alongside the existing groups; pattern after `Restore Last Deleted Item`):

```swift
CommandGroup(after: .pasteboard) {
    Button("Find in Project…") {
        NotificationCenter.default.post(
            name: .maughamFindInProject, object: nil)
    }
    .keyboardShortcut("f", modifiers: [.command, .option])
}
```

(If a CommandGroup(after: .pasteboard) already exists for `Restore Last Deleted Item`, add the Find button inside it instead of creating a duplicate group.)

- [ ] **Step 2: ProjectWindow subscribes to open Find segment**

In `Maugham/Views/ProjectWindow.swift`, add an `.onReceive`:

```swift
.onReceive(NotificationCenter.default.publisher(
    for: .maughamFindInProject)) { _ in
    findActive = true
    binderSegment = .find
}
```

If `body` complexity bites, route through `SessionAndNavigationModifier` (existing pattern).

- [ ] **Step 3: Re-enable NSTextView find bar**

In `Maugham/Editor/EditorSurface.swift`, find the line `textView.usesFindBar = false` (around line 57). Flip it:

```swift
textView.usesFindBar = true
```

- [ ] **Step 4: Build + run full suite + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 503 tests, with 0 failures`.

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift Maugham/Editor/EditorSurface.swift
git commit -m "feat: ⌘⌥F Find in Project + ⌘F re-enables NSTextView find bar

⌘⌥F opens the Find binder segment, focuses the search field.
⌘F in the editor surfaces NSTextView's built-in find bar (in-doc
search, navigation, replace) — previously hard-disabled. Both
surfaces complement each other.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Editor jump-to-match wiring

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Test: `MaughamTests/SearchInEditorJumpTests.swift` (new)

- [ ] **Step 1: Write failing test**

Create `MaughamTests/SearchInEditorJumpTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class SearchInEditorJumpTests: XCTestCase {
    func test_findMatchSelected_updatesSelectedItemId() async throws {
        // Simulate the wiring: posting the maughamFindMatchSelected
        // notification with a manuscript match should result in
        // the store's currentSearch matching docPath being addressable.
        // For unit-level test, verify the match's docPath maps to a
        // StructureItem whose id can be selected.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindJump-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        try "kitchen here\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Chapter 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: tmp)
        let matches = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store).matches
        XCTAssertEqual(matches.count, 1)
        let match = matches[0]

        // Helper: convert match path → manifest item id
        let id = store.manifest.structure.first(where: { $0.path == match.documentPath })?.id
        XCTAssertEqual(id, "ch-1")
    }
}
```

(Note: this test verifies the manifest-lookup half. The NSTextView scroll/select half is too view-heavy to unit test cleanly; T11 manual smoke verifies the visible behavior.)

- [ ] **Step 2: Verify it passes**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/SearchInEditorJumpTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 1 test, with 0 failures` — this test just verifies the lookup half via existing manifest API.

- [ ] **Step 3: Add EditorCoordinator scroll-to-range observer**

In `Maugham/Editor/EditorCoordinator.swift`, near other notification observers (look for `jumpObserver` or similar), add:

```swift
private var findMatchObserver: NSObjectProtocol?

// In init/attach, alongside other observers:
findMatchObserver = NotificationCenter.default.addObserver(
    forName: .maughamFindMatchSelected,
    object: nil,
    queue: .main
) { [weak self] note in
    guard let self,
          let match = note.userInfo?["match"] as? SearchMatch,
          let textView = self.textView else { return }

    // Defer to allow the document load to complete first.
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 50_000_000)
        let range = match.charRangeInDocument
        guard let storage = textView.textStorage,
              range.location + range.length <= storage.length else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }
}

// In deinit:
if let token = findMatchObserver {
    NotificationCenter.default.removeObserver(token)
}
```

- [ ] **Step 4: ProjectWindow updates `selectedItemId` / `selectedResearchId` on match selected**

In `Maugham/Views/ProjectWindow.swift`, add `.onReceive`:

```swift
.onReceive(NotificationCenter.default.publisher(
    for: .maughamFindMatchSelected)) { note in
    guard let store = store,
          let match = note.userInfo?["match"] as? SearchMatch else { return }
    switch match.documentSource {
    case .manuscript:
        if let item = findStructureItemByPath(match.documentPath, in: store.manifest.structure) {
            selectedItemId = item.id
        }
    case .research:
        if let item = findResearchItemByPath(match.documentPath, in: store.manifest.research) {
            selectedResearchId = item.id
        }
    }
}

private func findStructureItemByPath(_ path: String, in items: [StructureItem]) -> StructureItem? {
    for item in items {
        if item.path == path { return item }
        if let children = item.children,
           let nested = findStructureItemByPath(path, in: children) {
            return nested
        }
    }
    return nil
}

private func findResearchItemByPath(_ path: String, in items: [ResearchItem]) -> ResearchItem? {
    for item in items {
        if item.path == path { return item }
        if let children = item.children,
           let nested = findResearchItemByPath(path, in: children) {
            return nested
        }
    }
    return nil
}
```

(If `body` complexity bites, route the `.onReceive` through `SessionAndNavigationModifier`.)

- [ ] **Step 5: Build + run full suite + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 504 tests, with 0 failures` (503 prior + 1 new).

```bash
git add Maugham/Editor/EditorCoordinator.swift Maugham/Views/ProjectWindow.swift MaughamTests/SearchInEditorJumpTests.swift
git commit -m "feat: editor jumps to selected search match

ProjectWindow listens for maughamFindMatchSelected and updates
selectedItemId or selectedResearchId based on the match's source.
The existing editor-load machinery picks up the change.
EditorCoordinator listens too and, after a small post-load delay,
sets the textView's selectedRange to the match and scrolls into
view — using NSTextView's native selection highlight.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Final smoke + tag

### Task 11: Final smoke + tag

- [ ] **Build + launch**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

- [ ] **Manual smoke checklist**

1. Open a project with at least 3 manuscript items and a couple of research notes.
2. **In-doc find**: focus the editor, press `⌘F`. NSTextView find bar appears at the top of the editor. Type a word. Match highlights live. `⌘G` / `⌘⇧G` navigate. Replace inline works.
3. **Cross-doc find**: press `⌘⌥F`. Binder picker shows a new "Find" segment, search field is focused. Type a word; results appear after a brief pause, grouped by document with line previews and highlighted ranges.
4. Toggle "Aa" (case sensitive) and "W" (whole word). Results refresh.
5. Click a result row. Editor scrolls to that document, cursor lands on the match, NSTextView selection highlights it.
6. Open the Replace disclosure. Type a replacement. Click the per-row Replace icon — that single match replaces, results refresh.
7. Click Replace All → confirmation modal → confirm → all remaining matches replaced.
8. Search for an empty query → results clear; placeholder shown.
9. Close the Find segment (X button). Binder returns to Manuscript. The Find segment is hidden until `⌘⌥F` is pressed again.
10. Type a regex-special-character query like `a.b` (with a literal dot) → matches treat the dot literally.
11. Trash some items via the binder. Confirm trashed docs are NOT searched.
12. Phase 1c features still work (focus, typewriter scroll), Phase 1b unaffected, 3c features (parser, navigator) unaffected.

- [ ] **Push + tag**

```bash
git checkout main
git merge --ff-only feat/milestone-find-replace
git tag -a milestone-find-replace -m "Cross-Document Find/Replace — Group 1

In-doc find re-enabled via NSTextView's built-in find bar (⌘F).
Cross-doc find via new conditional BinderSegment.find (⌘⌥F):
live debounced search across manuscript + research notes, options
for case-sensitive and whole-word, click-to-jump editor scroll,
per-match and Replace All flows.

~504 tests passing."
git push origin main
git push origin milestone-find-replace
```

- [ ] **Update memory**

Create `~/.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_find_replace.md` describing the milestone, API surface, and any known limitations carried forward.

Add entry to MEMORY.md index.

---

## Spec coverage check

| Spec section | Covered by task(s) |
|---|---|
| In-doc find (⌘F) — usesFindBar = true | T9 |
| Cross-doc find (⌘⌥F) — entry point | T9 |
| SearchMatch / SearchOptions / SearchResults types | T1 |
| ProjectSearchEngine manuscript walk | T2 |
| ProjectSearchEngine research walk | T3 |
| Case-sensitive + whole-word options | T3 |
| Regex-special-char query literal-treatment | T3 |
| Long-line truncation (~120 chars centered) | T2 (`truncatePreview` helper) |
| ProjectStore.performSearch + currentSearch | T4 |
| 300ms debounce + cancellation | T4 |
| Pre-search flush via DocumentStore.flushPendingSave | T4 |
| ProjectStore.replaceMatch | T5 |
| ProjectStore.replaceAll (right-to-left within doc) | T6 |
| BinderSegment.find + conditional picker | T7 |
| ProjectSearchView (search field, options, grouped results) | T8 |
| Per-row replace + Replace All with confirm | T8 |
| Highlighted line previews | T8 (`highlightedPreview` helper) |
| Click result → notification → ProjectWindow updates selection | T10 |
| Editor scroll to + select match range | T10 |
| Smoke + tag | T11 |

Total task count: 11.
Test count target: 486 → ~504 (18 new across all tasks).
