# Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn first contact with Maugham into a writer-centric experience — a welcome carousel that forks into hands-on sample projects, an in-app Help window and a Claude-queryable help tool both reading one bundled docs source, and a writer-first README.

**Architecture:** A single set of topic files under `docs/guide/` (+ `index.json`) is the source of truth, GitHub-rendered and bundled into the Mac app. `HelpTopicIndex` is the shared loader; both `HelpWindow` (SwiftUI) and the `get_help` MCP tool read topics through it. The first-run `WelcomeCarousel` (presented from `WelcomeHost`) ends in a fork that calls `SampleProjectBuilder`, which copies a bundled sample project folder to a deduped path and opens it through the standard load path so `Bootstrap.run` mints `¶id` anchors. README is reordered writer-first.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest, xcodegen (`project.yml` + `./gen.sh`), MaughamCore SPM package.

---

## Conventions for every task

- **Test/build command (Mac):** `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
- **After adding ANY new file or editing `project.yml`:** run `./gen.sh` first (xcodegen re-globs sources). New `.swift` files under `Maugham/` are auto-included by the folder glob, but only after `./gen.sh`.
- **Branch:** work on the existing `onboarding` branch.
- **Bundle access in tests:** the guide/samples live in the *app* bundle, not the test bundle. Loaders therefore take an injectable directory `URL`; production resolves it from `Bundle.main`, tests pass a temp/`#filePath`-derived directory. This is the key testability seam — honour it in every loader.

---

## File Structure

**New files**
- `docs/guide/getting-started.md`, `editor-and-focus.md`, `structure-and-binder.md`, `research.md`, `right-pane.md`, `screenplay.md`, `claude-desktop.md`, `publishing.md`, `reference.md` — topic source (single source of truth)
- `docs/guide/index.json` — `[{slug,title,order}]`
- `Maugham/Help/HelpTopicIndex.swift` — loads index + resolves topic markdown from a directory URL
- `Maugham/MCP/Tools/GetHelpTool.swift` — `get_help` MCP tool
- `Maugham/Views/GuideMarkdownView.swift` — reusable read-only markdown renderer (block parser lifted from `ResearchNotePreviewPane`)
- `Maugham/Views/HelpWindow.swift` — sidebar + content Help window
- `Maugham/Views/WelcomeCarousel.swift` — first-run paged tour (+ `WelcomeSlide` model + `WelcomeIllustration` view)
- `Maugham/Stores/SampleProjectBuilder.swift` — materialize a bundled sample to disk + open
- `Maugham/Resources/Samples/novel/…` and `Maugham/Resources/Samples/screenplay/…` — bundled sample project folders
- `MaughamTests/HelpTopicIndexTests.swift`, `GetHelpToolTests.swift`, `SampleProjectBuilderTests.swift`, `WelcomeCarouselTests.swift`, `GuideDocsDriftTests.swift`

**Modified files**
- `project.yml` — bundle `docs/guide` + `Maugham/Resources/Samples`; exclude samples from sources
- `Maugham/Preferences/UserPreferences.swift` — `hasCompletedWelcome` flag
- `Maugham/MCP/MCPTool.swift` — register `GetHelpTool`
- `Maugham/Models/MaughamNotifications.swift` — `.maughamShowWelcome`, `.maughamShowHelp`
- `Maugham/MaughamApp.swift` — Help window `WindowGroup`; Help menu items
- `Maugham/MaughamApp.swift` (`WelcomeHost`) — first-launch carousel + notification handling
- `README.md` — writer-first rewrite
- `Maugham/MCP/AREA.md` — tool count 43→44, add `get_help`
- `docs/user-guide.md` — replaced by a pointer to `docs/guide/`

---

## Task 1: Split the guide into topic files + index.json

**Files:**
- Create: `docs/guide/{getting-started,editor-and-focus,structure-and-binder,research,right-pane,screenplay,claude-desktop,publishing,reference}.md`
- Create: `docs/guide/index.json`
- Modify: `docs/user-guide.md` (replace body with pointer)

- [ ] **Step 1: Create `docs/guide/index.json`** — the canonical topic list/order:

```json
[
  { "slug": "getting-started",     "title": "Getting Started",        "order": 1 },
  { "slug": "editor-and-focus",    "title": "The Editor & Focus",     "order": 2 },
  { "slug": "structure-and-binder","title": "Structure & the Binder", "order": 3 },
  { "slug": "research",            "title": "Research",               "order": 4 },
  { "slug": "right-pane",          "title": "Inspector, Research & Outline", "order": 5 },
  { "slug": "screenplay",          "title": "Screenplays",            "order": 6 },
  { "slug": "claude-desktop",      "title": "Writing with Claude",    "order": 7 },
  { "slug": "publishing",          "title": "Publishing to PDF & EPUB","order": 8 },
  { "slug": "reference",           "title": "Reference",              "order": 9 }
]
```

- [ ] **Step 2: Create each topic file by migrating the matching section of `docs/user-guide.md`.** The existing guide already contains all this prose — move each section verbatim into its file, giving each file a single `#` H1 matching its `title`. Mapping (sections are the `##` headings in `docs/user-guide.md`):
  - `getting-started.md` ← "Getting started"
  - `editor-and-focus.md` ← "The editor"
  - `structure-and-binder.md` ← "Working with the manuscript"
  - `right-pane.md` ← "The right pane: Inspector, Research, Outline"
  - `research.md` ← "Research"
  - `screenplay.md` ← "Screenplay mode"
  - `claude-desktop.md` ← "Claude Desktop integration"
  - `reference.md` ← "Keyboard shortcuts" + "On-disk layout" + "Troubleshooting"
  - `publishing.md` ← **new short section** (the current guide lacks one): describe Claude co-authoring a bespoke LaTeX template → personalised PDF, standard EPUB, outputs in `Exports/`, the `.maugham/publish/` config + `EMISSION.md` contract, and "ask Claude to 'set up publishing for this project.'" Pull facts from `README.md:47` and `Maugham/Publish/` `EMISSION.md`.

- [ ] **Step 3: Replace `docs/user-guide.md` body** with a pointer:

```markdown
# Maugham — User Guide

The user guide now lives as topic files under [`docs/guide/`](guide/), so the
same text can be rendered on GitHub, bundled into the app (Help → Maugham Help),
and answered by Claude via the `get_help` MCP tool. Start with
[Getting Started](guide/getting-started.md).
```

- [ ] **Step 4: Verify the files exist and JSON parses:**

Run: `python3 -c "import json,glob,os; idx=json.load(open('docs/guide/index.json')); files={os.path.basename(f)[:-3] for f in glob.glob('docs/guide/*.md')}; slugs={e['slug'] for e in idx}; print('OK' if slugs==files else f'MISMATCH idx-only={slugs-files} file-only={files-slugs}')"`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add docs/guide docs/user-guide.md
git commit -m "docs(guide): split user-guide into per-topic files + index.json"
```

---

## Task 2: Bundle the guide and sample dirs into the app

**Files:**
- Modify: `project.yml:31-42` (sources excludes) and `project.yml:73-76` (resources)
- Create: `Maugham/Resources/Samples/.keep` (placeholder dir so the folder ref resolves before Task 7 authors content)

- [ ] **Step 1: Add the samples exclude** to the `Maugham` source entry (so `.md`/`.fountain` seeds aren't treated as compilable sources), mirroring the existing `PublishStarter`/`bin` excludes. Under `sources: - path: Maugham / excludes:` add:

```yaml
          - "Resources/Samples/**"
```

- [ ] **Step 2: Add two folder references** — the guide (repo docs, rendered on GitHub and bundled) and the samples. After the existing `Maugham/Resources/bin` folder ref (`project.yml:41-42`) add:

```yaml
      - path: docs/guide
        type: folder
      - path: Maugham/Resources/Samples
        type: folder
```

- [ ] **Step 3: Create the placeholder** so the folder ref resolves on a clean checkout:

```bash
mkdir -p Maugham/Resources/Samples
touch Maugham/Resources/Samples/.keep
```

- [ ] **Step 4: Regenerate and build to confirm the project is valid:**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Confirm the guide landed in the built bundle:**

Run: `find build -path "*Maugham.app/Contents/Resources/guide/index.json" 2>/dev/null | head -1`
Expected: a path is printed (the bundled `guide/` folder exists). If empty, the folder reference didn't take — recheck Step 2.

- [ ] **Step 6: Commit**

```bash
git add project.yml Maugham/Resources/Samples/.keep
git commit -m "build: bundle docs/guide and Resources/Samples into the Mac app"
```

---

## Task 3: `HelpTopicIndex` loader

**Files:**
- Create: `Maugham/Help/HelpTopicIndex.swift`
- Test: `MaughamTests/HelpTopicIndexTests.swift`

- [ ] **Step 1: Write the failing test.** It builds a temp guide dir, then exercises the loader through its injectable-directory initializer:

```swift
import XCTest
@testable import Maugham

final class HelpTopicIndexTests: XCTestCase {
    private func makeGuideDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = """
        [{"slug":"b-topic","title":"B Topic","order":2},
         {"slug":"a-topic","title":"A Topic","order":1}]
        """
        try index.write(to: dir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        try "# A Topic\nHello A.".write(to: dir.appendingPathComponent("a-topic.md"), atomically: true, encoding: .utf8)
        try "# B Topic\nHello B.".write(to: dir.appendingPathComponent("b-topic.md"), atomically: true, encoding: .utf8)
        return dir
    }

    func test_topicsSortedByOrder() throws {
        let index = try HelpTopicIndex(directory: makeGuideDir())
        XCTAssertEqual(index.topics.map(\.slug), ["a-topic", "b-topic"])
        XCTAssertEqual(index.topics.map(\.title), ["A Topic", "B Topic"])
    }

    func test_markdownForKnownSlug() throws {
        let index = try HelpTopicIndex(directory: makeGuideDir())
        XCTAssertEqual(try index.markdown(for: "a-topic"), "# A Topic\nHello A.")
    }

    func test_unknownSlugThrows() throws {
        let index = try HelpTopicIndex(directory: makeGuideDir())
        XCTAssertThrowsError(try index.markdown(for: "missing"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/HelpTopicIndexTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: FAIL — "cannot find 'HelpTopicIndex' in scope".

- [ ] **Step 3: Write the implementation:**

```swift
import Foundation

/// Loads the bundled documentation index (`guide/index.json`) and resolves
/// topic markdown. The single seam both `HelpWindow` and `GetHelpTool` read
/// through — neither hand-rolls bundle lookups. Directory is injected so
/// tests can point at a temp dir; production uses `.bundled()`.
struct HelpTopicIndex {
    struct Topic: Codable, Hashable {
        let slug: String
        let title: String
        let order: Int
    }

    enum LoadError: Error { case indexMissing, topicMissing(String) }

    let directory: URL
    let topics: [Topic]

    init(directory: URL) throws {
        self.directory = directory
        let indexURL = directory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL) else { throw LoadError.indexMissing }
        let decoded = try JSONDecoder().decode([Topic].self, from: data)
        self.topics = decoded.sorted { $0.order < $1.order }
    }

    /// Production loader: the `guide/` folder bundled by `project.yml`.
    static func bundled() throws -> HelpTopicIndex {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("guide"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("index.json").path)
        else { throw LoadError.indexMissing }
        return try HelpTopicIndex(directory: url)
    }

    func markdown(for slug: String) throws -> String {
        guard topics.contains(where: { $0.slug == slug }) else { throw LoadError.topicMissing(slug) }
        let url = directory.appendingPathComponent("\(slug).md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw LoadError.topicMissing(slug)
        }
        return text
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/HelpTopicIndexTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Help/HelpTopicIndex.swift MaughamTests/HelpTopicIndexTests.swift
git commit -m "feat(help): HelpTopicIndex loader with injectable directory seam"
```

---

## Task 4: Drift guard — real `docs/guide` ↔ index ↔ project.yml

**Files:**
- Test: `MaughamTests/GuideDocsDriftTests.swift`

This locates the *real* repo `docs/guide` via `#filePath` (CI-safe; the test source path is fixed at compile time), so it guards the actual shipped docs, not a fixture.

- [ ] **Step 1: Write the test:**

```swift
import XCTest
@testable import Maugham

final class GuideDocsDriftTests: XCTestCase {
    /// Repo root = three levels up from MaughamTests/GuideDocsDriftTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
    }

    func test_indexMatchesFilesExactly() throws {
        let guideDir = repoRoot.appendingPathComponent("docs/guide")
        let index = try HelpTopicIndex(directory: guideDir)
        let slugsInIndex = Set(index.topics.map(\.slug))

        let mdFiles = try FileManager.default
            .contentsOfDirectory(at: guideDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
        let slugsOnDisk = Set(mdFiles)

        XCTAssertEqual(slugsInIndex, slugsOnDisk,
            "index.json and docs/guide/*.md disagree: index-only=\(slugsInIndex.subtracting(slugsOnDisk)) file-only=\(slugsOnDisk.subtracting(slugsInIndex))")
    }

    func test_everyTopicMarkdownIsReadableAndNonEmpty() throws {
        let index = try HelpTopicIndex(directory: repoRoot.appendingPathComponent("docs/guide"))
        for topic in index.topics {
            let md = try index.markdown(for: topic.slug)
            XCTAssertFalse(md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(topic.slug).md is empty")
        }
    }

    func test_projectYamlBundlesTheGuide() throws {
        let yml = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("path: docs/guide"),
            "project.yml must bundle docs/guide as a resource folder, or the in-app Help window ships empty")
    }
}
```

- [ ] **Step 2: Run to verify it passes** (Tasks 1–2 already satisfy it):

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/GuideDocsDriftTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: PASS (3 tests). If `test_indexMatchesFilesExactly` fails, fix `index.json`/files from Task 1.

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/GuideDocsDriftTests.swift
git commit -m "test(help): drift guard tying index.json, docs/guide files, and bundling"
```

---

## Task 5: `GetHelpTool` MCP tool

**Files:**
- Create: `Maugham/MCP/Tools/GetHelpTool.swift`
- Modify: `Maugham/MCP/MCPTool.swift:79` (add to catalog)
- Test: `MaughamTests/GetHelpToolTests.swift`

- [ ] **Step 1: Write the failing test.** It drives the tool's pure responder with an injected index (no `Bundle.main` dependency):

```swift
import XCTest
@testable import Maugham

final class GetHelpToolTests: XCTestCase {
    private func tempIndex() throws -> HelpTopicIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"[{"slug":"focus","title":"Focus","order":1}]"#
            .write(to: dir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        try "# Focus\nUse Cmd-backslash.".write(
            to: dir.appendingPathComponent("focus.md"), atomically: true, encoding: .utf8)
        return try HelpTopicIndex(directory: dir)
    }

    func test_noTopicReturnsIndex() throws {
        let data = try GetHelpTool.respond(paramsJSON: nil, index: tempIndex())
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let topics = obj["topics"] as! [[String: Any]]
        XCTAssertEqual(topics.first?["slug"] as? String, "focus")
        XCTAssertEqual(topics.first?["title"] as? String, "Focus")
    }

    func test_knownTopicReturnsMarkdown() throws {
        let params = #"{"topic":"focus"}"#.data(using: .utf8)
        let data = try GetHelpTool.respond(paramsJSON: params, index: tempIndex())
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["slug"] as? String, "focus")
        XCTAssertEqual(obj["markdown"] as? String, "# Focus\nUse Cmd-backslash.")
    }

    func test_unknownTopicThrows() throws {
        let params = #"{"topic":"nope"}"#.data(using: .utf8)
        XCTAssertThrowsError(try GetHelpTool.respond(paramsJSON: params, index: tempIndex()))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/GetHelpToolTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: FAIL — "cannot find 'GetHelpTool' in scope".

- [ ] **Step 3: Write the tool** (pure `respond` is the test seam; `handle` wires `Bundle.main`):

```swift
import Foundation
import MaughamCore

/// MCP tool: `get_help` — read-only access to Maugham's user documentation,
/// the same topic files the writer reads in Help → Maugham Help. Lets Claude
/// answer "how do I X in Maugham?" from authoritative text.
public enum GetHelpTool: MCPTool {
    public static let method = "get_help"
    public static let description =
        "Read Maugham's own user documentation. Omit `topic` to get the list of available help topics (slug + title); pass a `topic` slug to get that topic's full markdown. Use this to answer questions about how to use Maugham (focus mode, the binder, screenplays, publishing, Claude integration, keyboard shortcuts, on-disk layout, troubleshooting)."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"topic":{"type":"string","description":"Optional help topic slug (e.g. \\"getting-started\\", \\"editor-and-focus\\"). Omit to list all topics."}}}
    """

    struct Params: Codable { let topic: String? }

    /// Pure responder — unit-testable with an injected index.
    static func respond(paramsJSON: Data?, index: HelpTopicIndex) throws -> Data {
        let topic = paramsJSON
            .flatMap { try? JSONDecoder().decode(Params.self, from: $0) }?
            .topic

        if let topic, !topic.isEmpty {
            let md = try index.markdown(for: topic)   // throws topicMissing on unknown
            return try JSONSerialization.data(withJSONObject: [
                "slug": topic, "markdown": md
            ], options: [.sortedKeys])
        }

        let topics = index.topics.map { ["slug": $0.slug, "title": $0.title] }
        return try JSONSerialization.data(withJSONObject: [
            "topics": topics, "count": topics.count
        ], options: [.sortedKeys])
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let index = try HelpTopicIndex.bundled()
        return try respond(paramsJSON: paramsJSON, index: index)
    }
}
```

- [ ] **Step 4: Register in the catalog.** In `Maugham/MCP/MCPTool.swift`, add to the `MCPToolCatalog.all` array after `ListMaughamToolsTool.self` (line ~79):

```swift
        ListMaughamToolsTool.self,
        GetHelpTool.self
```

(Add a comma after `ListMaughamToolsTool.self` if it's currently the last entry.)

- [ ] **Step 5: Run tests to verify they pass** (includes the catalog-consistency test that asserts every tool's schema parses):

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/GetHelpToolTests -only-testing:MaughamTests/MCPCatalogConsistencyTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Maugham/MCP/Tools/GetHelpTool.swift Maugham/MCP/MCPTool.swift MaughamTests/GetHelpToolTests.swift
git commit -m "feat(mcp): get_help tool exposing bundled docs to Claude (43->44 tools)"
```

---

## Task 6: `GuideMarkdownView` reusable renderer

Lift the block-parsing approach from `ResearchNotePreviewPane` (`Maugham/Views/ResearchNotePreviewPane.swift`) into a standalone view that renders arbitrary markdown text (headings, paragraphs, bullet lists, fenced code) without the project-relative image logic. Used by `HelpWindow`.

**Files:**
- Create: `Maugham/Views/GuideMarkdownView.swift`
- Test: `MaughamTests/GuideMarkdownViewTests.swift`

- [ ] **Step 1: Write the failing test** against the pure block parser:

```swift
import XCTest
@testable import Maugham

final class GuideMarkdownViewTests: XCTestCase {
    func test_parsesHeadingsParagraphsBulletsAndCode() {
        let md = """
        # Title
        Intro line.
        - first
        - second
        ```
        let x = 1
        ```
        """
        let blocks = GuideMarkdownView.parse(md)
        guard case .heading(let level, let text) = blocks[0] else { return XCTFail("expected heading") }
        XCTAssertEqual(level, 1); XCTAssertEqual(text, "Title")
        guard case .paragraph = blocks[1] else { return XCTFail("expected paragraph") }
        guard case .bullet = blocks[2] else { return XCTFail("expected bullet") }
        guard case .bullet = blocks[3] else { return XCTFail("expected bullet") }
        guard case .code(let code) = blocks[4] else { return XCTFail("expected code") }
        XCTAssertEqual(code, "let x = 1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/GuideMarkdownViewTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: FAIL — "cannot find 'GuideMarkdownView' in scope".

- [ ] **Step 3: Write the view + parser:**

```swift
import SwiftUI

/// Read-only markdown renderer for bundled help topics. Block parser mirrors
/// `ResearchNotePreviewPane` (headings + inline-markdown paragraphs) plus
/// bullets and fenced code; no project-relative image resolution.
struct GuideMarkdownView: View {
    let markdown: String

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case code(String)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var inCode = false
        var codeLines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { blocks.append(.code(codeLines.joined(separator: "\n"))); codeLines = [] }
                inCode.toggle()
                continue
            }
            if inCode { codeLines.append(line); continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let body = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(hashes, 6), text: body))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        return blocks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                    render(block)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level)).fontWeight(.semibold)
                .padding(.top, level <= 2 ? 10 : 4)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .textSelection(.enabled)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            }.textSelection(.enabled)
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level { case 1: return .title; case 2: return .title2; case 3: return .title3; default: return .headline }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/GuideMarkdownViewTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/GuideMarkdownView.swift MaughamTests/GuideMarkdownViewTests.swift
git commit -m "feat(help): GuideMarkdownView read-only renderer for bundled topics"
```

---

## Task 7: `HelpWindow` + window + Help menu item

**Files:**
- Create: `Maugham/Views/HelpWindow.swift`
- Modify: `Maugham/Models/MaughamNotifications.swift` (add `.maughamShowHelp`)
- Modify: `Maugham/MaughamApp.swift` (add `Window(id:"help")`; add Help menu "Maugham Help")

- [ ] **Step 1: Add the notification** in `Maugham/Models/MaughamNotifications.swift` (after `.maughamShowSyntaxHelp`, line ~20):

```swift
    public static let maughamShowHelp = Notification.Name("maugham.show.help")
    public static let maughamShowWelcome = Notification.Name("maugham.show.welcome")
```

(Both added now; `.maughamShowWelcome` is used in Task 11.)

- [ ] **Step 2: Write `HelpWindow.swift`:**

```swift
import SwiftUI

/// "Maugham Help" — a resizable window with a topic sidebar (from the bundled
/// `guide/index.json`) and a rendered-markdown content pane. Reads the same
/// files as the `get_help` MCP tool via `HelpTopicIndex`.
struct HelpWindow: View {
    @State private var index: HelpTopicIndex?
    @State private var selectedSlug: String?
    @State private var loadError: String?

    var body: some View {
        NavigationSplitView {
            if let index {
                List(index.topics, id: \.slug, selection: $selectedSlug) { topic in
                    Text(topic.title).tag(topic.slug)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            } else {
                Text(loadError ?? "Loading…").foregroundStyle(.secondary)
            }
        } detail: {
            if let index, let slug = selectedSlug,
               let md = try? index.markdown(for: slug) {
                GuideMarkdownView(markdown: md)
            } else {
                ContentUnavailableView("Maugham Help",
                    systemImage: "book",
                    description: Text("Choose a topic from the list."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            do {
                let idx = try HelpTopicIndex.bundled()
                index = idx
                selectedSlug = idx.topics.first?.slug
            } catch { loadError = "Help content unavailable." }
        }
    }
}
```

- [ ] **Step 3: Register the window** in `Maugham/MaughamApp.swift`. After the `Window("Check for Updates", id: updateWindowID)` block (line ~293), add:

```swift
        Window("Maugham Help", id: "help") {
            HelpWindow()
        }
        .windowResizability(.contentMinSize)
```

- [ ] **Step 4: Add the Help menu item.** In the `CommandGroup(replacing: .help)` block (`Maugham/MaughamApp.swift:242`), add before "Syntax Reference":

```swift
                Button("Maugham Help") {
                    NotificationCenter.default.post(name: .maughamShowHelp, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)
```

- [ ] **Step 5: Open the window on the notification.** The menu posts a notification; a small bridge opens the window. In `MaughamApp`'s `WelcomeHost` (it always exists) — actually open from the app-level scene. Add to the `WelcomeHost` body's `.onReceive` chain (so it works from the Welcome window) AND register the same handler where project windows live. Simplest single point: add an `.onReceive` to `WelcomeHost` (line ~367) opening the window via `openWindow`:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowHelp)) { _ in
            openWindow(id: "help")
        }
```

Note: `WelcomeHost` already has `@Environment(\.openWindow) private var openWindow`. Project windows also need this — `ProjectWindow` should mirror the handler. Add the same `.onReceive` + `@Environment(\.openWindow)` to `ProjectWindow.body` (find the existing `.onReceive(... .maughamShowSyntaxHelp)` handler in `Maugham/Views/ProjectWindow.swift` and add the help one beside it, calling `openWindow(id: "help")`).

- [ ] **Step 6: Build and smoke the window manually:**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (Manual: launch app → Help → Maugham Help → window opens with topic list + content. Verified in the final smoke, Task 13.)

- [ ] **Step 7: Commit**

```bash
git add Maugham/Views/HelpWindow.swift Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat(help): in-app Maugham Help window (Cmd-?) reading bundled guide"
```

---

## Task 8: `SampleProjectBuilder` + bundled sample seeds

The seeds are authored as complete project folders and bundled (Task 2 set up `Resources/Samples`). The builder copies a seed folder to a deduped destination, installs the publishing starter, and returns the URL; the caller opens it through the normal load path (which runs `Bootstrap.run`).

**Files:**
- Create: `Maugham/Resources/Samples/novel/` — a real Novel project folder
- Create: `Maugham/Resources/Samples/screenplay/` — a real Screenplay project folder
- Create: `Maugham/Stores/SampleProjectBuilder.swift`
- Test: `MaughamTests/SampleProjectBuilderTests.swift`

- [ ] **Step 1: Author the Novel seed.** Create a minimal real project under `Maugham/Resources/Samples/novel/`:
  - `project.maugham.json` — a Novel manifest with three chapters. Use the exact `ProjectManifest` shape from `ProjectFactory.createSingleDocumentProject` (`type: .novel`, `structure` = three `.document` items with `id` `doc-001`/`doc-002`/`doc-003`, paths `manuscript/01-welcome.md`, `manuscript/02-try-it.md`, `manuscript/03-going-further.md`, each `status: "draft"`). Author it by hand to match `ProjectManifest`'s encoded keys (open any existing project's `project.maugham.json` for the exact field spelling, or generate one by creating a Novel in the app and copying it).
  - `manuscript/01-welcome.md` — welcome prose whose text *is* the tour, e.g.:
    ```markdown
    # Welcome to Maugham

    This is a real project — edit anything, or delete it when you're done.
    Everything you type autosaves as plain text on disk.

    Try it: put your cursor at the end of this line and write a sentence.
    ```
  - `manuscript/02-try-it.md` — invites trying features: focus mode (⌘\), the Inspector (synopsis/status/tags), wiki-links (`[[Going Further]]`), and the Outline (⌘⌥3).
  - `manuscript/03-going-further.md` — points at Help → Maugham Help, Claude Desktop setup, and publishing.
  - `research/about-this-sample.md` — one note explaining the Research pane.
  - Do **not** include a `.maugham/` folder or inline `¶id` anchors — `Bootstrap.run` mints anchors on first open.

- [ ] **Step 2: Author the Screenplay seed** under `Maugham/Resources/Samples/screenplay/`:
  - `project.maugham.json` — a `type: .screenplay` manifest with one `.document` item `id: doc-001`, path `manuscript/01-welcome.fountain`, `status: "draft"` (mirror `createSingleDocumentProject` with `.screenplay`).
  - `manuscript/01-welcome.fountain` — a tiny valid Fountain scene that doubles as a tour:
    ```fountain
    Title: Welcome — A Maugham Sample

    INT. MAUGHAM — DAY

    A WRITER stares at a blank page. Then types.

    WRITER
    (delighted)
    Tab cycles element types. Cmd-slash opens the syntax sheet.

    FADE OUT.
    ```

- [ ] **Step 3: Regenerate so the seeds are bundled, then write the failing test:**

```swift
import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class SampleProjectBuilderTests: XCTestCase {
    func test_buildsNovelSampleThatLoadsWithAnchors() async throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("samples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Inject the repo seed dir so the test doesn't depend on the app bundle.
        let seedRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent() // repo root
            .appendingPathComponent("Maugham/Resources/Samples")

        let url = try await SampleProjectBuilder.build(.novel, seedsRoot: seedRoot, destinationParent: parent)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("project.maugham.json").path))

        // Open through the standard load path so Bootstrap mints anchors.
        let doc = try await Document.load(
            from: url.appendingPathComponent("manuscript/01-welcome.md"), projectURL: url)
        XCTAssertTrue(doc.text.contains("<!-- ¶"), "Bootstrap should have minted inline anchors on load")
    }

    func test_dedupesDestinationName() async throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("samples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let seedRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Resources/Samples")

        let first = try await SampleProjectBuilder.build(.novel, seedsRoot: seedRoot, destinationParent: parent)
        let second = try await SampleProjectBuilder.build(.novel, seedsRoot: seedRoot, destinationParent: parent)
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
    }
}
```

**Note for the implementer:** confirm `Document.load`'s exact signature in `Maugham/OpLog/` / `Maugham/Editor/EditorHost.swift` (CLAUDE.md: "contract surface is `Document.load`"). Adjust the test's `Document.load(...)` call and the anchor assertion (`<!-- ¶`) to the real API if the parameter labels differ — the *intent* (open via the Bootstrap-routed load path, assert anchors present) is what matters.

- [ ] **Step 4: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/SampleProjectBuilderTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: FAIL — "cannot find 'SampleProjectBuilder' in scope".

- [ ] **Step 5: Write the builder:**

```swift
import Foundation
import MaughamCore

/// Materializes a bundled sample project (novel/screenplay) onto disk as a
/// normal, fully-editable project. Copies the seed folder to a deduped path
/// and installs the publishing starter. The CALLER opens the result through
/// the standard load path so `Bootstrap.run` mints the inline ¶id anchors —
/// the builder never constructs `Document` directly (hard invariant).
enum SampleProjectBuilder {
    enum Kind: String { case novel, screenplay
        /// User-visible destination name; the leading word uses the build
        /// variant display name so dev/stable don't collide (tripwire 13).
        func destinationName() -> String { "\(BuildVariant.current.displayName) Sample \(rawValue.capitalized)" }
    }

    enum BuildError: Error { case seedMissing(String) }

    /// `seedsRoot` is injectable for tests; production passes the bundled dir.
    static func build(_ kind: Kind,
                      seedsRoot: URL,
                      destinationParent: URL) async throws -> URL {
        let fm = FileManager.default
        let seed = seedsRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
        guard fm.fileExists(atPath: seed.appendingPathComponent(ProjectManifest.fileName).path) else {
            throw BuildError.seedMissing(kind.rawValue)
        }

        let dest = dedupedURL(name: kind.destinationName(), in: destinationParent)
        try fm.copyItem(at: seed, to: dest)
        await PublishStarter.installIfMissing(into: dest)
        return dest
    }

    /// Production convenience: bundled seeds + ~/Documents.
    @MainActor
    static func buildInDocuments(_ kind: Kind) async throws -> URL {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Samples") else {
            throw BuildError.seedMissing("Samples")
        }
        let docs = fmDocumentsURL()
        return try await build(kind, seedsRoot: bundled, destinationParent: docs)
    }

    private static func fmDocumentsURL() -> URL {
        (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    private static func dedupedURL(name: String, in parent: URL) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/SampleProjectBuilderTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: PASS (2 tests). If the `Document.load` call fails to compile, fix per the Step 3 note.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Resources/Samples Maugham/Stores/SampleProjectBuilder.swift MaughamTests/SampleProjectBuilderTests.swift
git commit -m "feat(onboarding): bundled novel/screenplay samples + SampleProjectBuilder"
```

---

## Task 9: `hasCompletedWelcome` preference

**Files:**
- Modify: `Maugham/Preferences/UserPreferences.swift`
- Test: `MaughamTests/UserPreferencesTests.swift` (append)

- [ ] **Step 1: Write the failing test** (append to `UserPreferencesTests.swift`):

```swift
    func test_hasCompletedWelcome_defaultsFalseAndPersists() {
        let suite = "test-welcome-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = UserPreferences(defaults: defaults)
        XCTAssertFalse(prefs.hasCompletedWelcome)
        prefs.hasCompletedWelcome = true

        let reloaded = UserPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.hasCompletedWelcome)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/UserPreferencesTests/test_hasCompletedWelcome_defaultsFalseAndPersists CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: FAIL — no member `hasCompletedWelcome`.

- [ ] **Step 3: Add the flag** to `UserPreferences.swift`. Add the key constant beside the others (line ~20): `private static let hasCompletedWelcomeKey = "maugham.hasCompletedWelcome"`. Add the property beside `mcpEnabled` (line ~53):

```swift
    public var hasCompletedWelcome: Bool {
        didSet { defaults.set(hasCompletedWelcome, forKey: Self.hasCompletedWelcomeKey) }
    }
```

And in `init` (beside the other bool reads, line ~93):

```swift
        self.hasCompletedWelcome =
            defaults.object(forKey: Self.hasCompletedWelcomeKey) as? Bool ?? false
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/UserPreferencesTests/test_hasCompletedWelcome_defaultsFalseAndPersists CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Preferences/UserPreferences.swift MaughamTests/UserPreferencesTests.swift
git commit -m "feat(onboarding): hasCompletedWelcome preference (first-launch gate)"
```

---

## Task 10: `WelcomeCarousel` (slides + illustrations + paging + fork)

**Files:**
- Create: `Maugham/Views/WelcomeCarousel.swift`
- Test: `MaughamTests/WelcomeCarouselTests.swift`

- [ ] **Step 1: Write the failing test** against the slide model (the data is the testable seam; the view is verified in smoke):

```swift
import XCTest
@testable import Maugham

final class WelcomeCarouselTests: XCTestCase {
    func test_eightSlidesInOrderEndingWithGetStarted() {
        let slides = WelcomeSlide.all
        XCTAssertEqual(slides.count, 8)
        XCTAssertEqual(slides.first?.id, .welcome)
        XCTAssertEqual(slides.last?.id, .getStarted)
        // Each non-final slide has heading + body copy.
        for slide in slides {
            XCTAssertFalse(slide.heading.isEmpty)
            XCTAssertFalse(slide.body.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/WelcomeCarouselTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: FAIL — "cannot find 'WelcomeSlide' in scope".

- [ ] **Step 3: Write the model + view.** The `illustration` is drawn in SwiftUI now, behind a slot (`imageName: String?`) that a real screenshot can fill later:

```swift
import SwiftUI
import MaughamCore

struct WelcomeSlide: Identifiable, Equatable {
    enum ID: String { case welcome, structure, focus, organize, collaborate, publish, safety, getStarted }
    let id: ID
    let symbol: String        // SF Symbol for the drawn illustration
    let heading: String
    let body: String
    var imageName: String?    // future: bundled screenshot overrides the symbol

    static let all: [WelcomeSlide] = [
        .init(id: .welcome,    symbol: "doc.text",            heading: "A room of one's own",
              body: "Maugham is a focus editor for serious creative writing. Your words live as plain text you own."),
        .init(id: .structure,  symbol: "sidebar.left",        heading: "Shape the whole work",
              body: "Stories, novels, screenplays, collections. The Binder holds your structure — drag to reorder."),
        .init(id: .focus,      symbol: "scope",               heading: "Disappear into the page",
              body: "Focus mode, typewriter scroll, sentence dimming, smart dashes & quotes. ⌘\\ hides everything but the words."),
        .init(id: .organize,   symbol: "rectangle.3.group",   heading: "Keep the threads",
              body: "Synopses, status, tags, word targets, [[wiki-links]], an Outline corkboard, research beside the draft."),
        .init(id: .collaborate,symbol: "bubble.left.and.text.bubble.right", heading: "A reader who never rewrites you",
              body: "Claude Desktop can read, annotate and research — but never edits your manuscript. That stays yours."),
        .init(id: .publish,    symbol: "books.vertical",      heading: "Publish, beautifully",
              body: "Claude co-authors a bespoke LaTeX template tuned to your taste — a deeply personalised PDF, or a clean standard EPUB."),
        .init(id: .safety,     symbol: "clock.arrow.circlepath", heading: "Nothing is ever lost",
              body: "Autosave, a full edit history you can rewind, iCloud sync, ⌘S checkpoints. Write fearlessly."),
        .init(id: .getStarted, symbol: "sparkles",            heading: "Your turn",
              body: "Try a hands-on sample, or start a project of your own.")
    ]
}

/// First-run tour. Paged slides ending in a three-way fork. The three fork
/// actions + Skip are injected so the host owns navigation and the
/// completion flag.
struct WelcomeCarousel: View {
    let onSampleNovel: () -> Void
    let onSampleScreenplay: () -> Void
    let onNewProject: () -> Void
    let onSkip: () -> Void

    @State private var index = 0
    private var slides: [WelcomeSlide] { WelcomeSlide.all }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip", action: onSkip).buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(12)

            Spacer()
            illustration(slides[index].symbol)
            Text(slides[index].heading)
                .font(.system(size: 28, weight: .light, design: .serif))
                .padding(.top, 16)
            Text(slides[index].body)
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460).padding(.top, 8)
            Spacer()

            if slides[index].id == .getStarted {
                forkButtons
            } else {
                navButtons
            }
            dots.padding(.vertical, 18)
        }
        .frame(width: 640, height: 480)
    }

    private func illustration(_ symbol: String) -> some View {
        // Drawn-in-code illustration; swap to bundled screenshot via imageName later.
        Image(systemName: symbol)
            .font(.system(size: 84, weight: .thin))
            .foregroundStyle(.tint)
            .frame(height: 120)
    }

    private var navButtons: some View {
        HStack {
            Button("Back") { index -= 1 }.disabled(index == 0)
            Spacer()
            Button("Next") { index += 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(.horizontal, 40)
    }

    private var forkButtons: some View {
        VStack(spacing: 10) {
            Button { onSampleNovel() } label: { Label("Try a sample Novel", systemImage: "book").frame(maxWidth: 320) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button { onSampleScreenplay() } label: { Label("Try a sample Screenplay", systemImage: "film").frame(maxWidth: 320) }
                .controlSize(.large)
            Button { onNewProject() } label: { Label("Start a project of my own", systemImage: "doc.badge.plus").frame(maxWidth: 320) }
                .controlSize(.large)
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(slides.indices, id: \.self) { i in
                Circle().fill(i == index ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/WelcomeCarouselTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/WelcomeCarousel.swift MaughamTests/WelcomeCarouselTests.swift
git commit -m "feat(onboarding): WelcomeCarousel — 8-slide tour with sample fork"
```

---

## Task 11: Wire the carousel + Sample Projects menu into `WelcomeHost`

**Files:**
- Modify: `Maugham/MaughamApp.swift` (`WelcomeHost`, Help `CommandGroup`)

- [ ] **Step 1: Present the carousel from `WelcomeHost`.** Add to `WelcomeHost` (`Maugham/MaughamApp.swift:351`): an `@Environment(UserPreferences.self) private var prefs` (confirm `UserPreferences` is injected into the Welcome scene; if not, also add `.environment(userPreferences)` to the `Window("Maugham — Welcome")` scene at line ~51, matching how the project scene injects it at line ~259), a `@State private var showingWelcome = false`, and a `@State private var pendingSampleError: String?`.

Add these modifiers to the `WelcomeView` (alongside the existing `.sheet`/`.onReceive` chain, ~line 364):

```swift
        .sheet(isPresented: $showingWelcome) {
            WelcomeCarousel(
                onSampleNovel:      { completeWelcome(); openSample(.novel) },
                onSampleScreenplay: { completeWelcome(); openSample(.screenplay) },
                onNewProject:       { completeWelcome(); showingNewProject = true },
                onSkip:             { completeWelcome() }
            )
        }
        .onAppear {
            if !prefs.hasCompletedWelcome { showingWelcome = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowWelcome)) { _ in
            showingWelcome = true
        }
```

- [ ] **Step 2: Add the helper methods** to `WelcomeHost`:

```swift
    @MainActor private func completeWelcome() {
        prefs.hasCompletedWelcome = true
        showingWelcome = false
    }

    @MainActor private func openSample(_ kind: SampleProjectBuilder.Kind) {
        Task {
            do {
                let url = try await SampleProjectBuilder.buildInDocuments(kind)
                open(url)   // records in Recents + opens the project window
            } catch {
                pendingSampleError = error.localizedDescription
            }
        }
    }
```

- [ ] **Step 3: Add the Help menu entries.** In the `CommandGroup(replacing: .help)` (`Maugham/MaughamApp.swift:242`), after the "Maugham Help" button (Task 7) add:

```swift
                Button("Welcome to Maugham") {
                    NotificationCenter.default.post(name: .maughamShowWelcome, object: nil)
                }
                Menu("Sample Projects") {
                    Button("Novel") {
                        NotificationCenter.default.post(name: .maughamOpenSample,
                            object: nil, userInfo: ["kind": "novel"])
                    }
                    Button("Screenplay") {
                        NotificationCenter.default.post(name: .maughamOpenSample,
                            object: nil, userInfo: ["kind": "screenplay"])
                    }
                }
                Divider()
```

- [ ] **Step 4: Add the `.maughamOpenSample` notification** to `Maugham/Models/MaughamNotifications.swift`:

```swift
    public static let maughamOpenSample = Notification.Name("maugham.open.sample")
```

And handle it in `WelcomeHost` (so samples open from the menu even when only the Welcome window has the builder wiring):

```swift
        .onReceive(NotificationCenter.default.publisher(for: .maughamOpenSample)) { note in
            let kind = (note.userInfo?["kind"] as? String) == "screenplay" ? SampleProjectBuilder.Kind.screenplay : .novel
            openSample(kind)
        }
```

- [ ] **Step 5: Regenerate, build, and run the full suite:**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` (all targets green).

- [ ] **Step 6: Commit**

```bash
git add Maugham/MaughamApp.swift Maugham/Models/MaughamNotifications.swift
git commit -m "feat(onboarding): first-launch carousel, Welcome to Maugham + Sample Projects menu"
```

---

## Task 12: README rewrite (writer-first)

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite `README.md`** in this order. Reuse the existing wording where it already reads well — this is reorder + reframe, not invention.
  1. **Title + one-paragraph pitch** (keep the current opening sentence, expand to two lines on *what a writer gets*).
  2. **What you can do** — a short bulleted feature tour for writers: focus writing (focus mode, typewriter, dimming, smart typography); structure (binder, four project types); organize (inspector, outline, wiki-links, research); screenplays (Fountain, scene navigator); write with Claude (read/annotate, never rewrites); publish (personalised PDF / standard EPUB). Add `<!-- screenshot: … -->` HTML-comment slots beside 2–3 bullets for later images.
  3. **Install** — keep the current Install section verbatim (`README.md:9-17`).
  4. **Documentation** — "Full guide: [`docs/guide/`](docs/guide/), or open **Help → Maugham Help** in the app. Ask Claude `get_help` for any topic."
  5. **Writing with Claude** — condense the current "Claude Desktop integration" section (`README.md:43-51`) to benefit-led prose; keep the setup one-liner and the publishing sentence.
  6. **Development** — a single section at the bottom absorbing today's **Build**, **Test**, **Layout**, and **Working in this repo** sections (`README.md:19-71`) verbatim under one `## Development` heading with `###` subsections. Nothing deleted.

- [ ] **Step 2: Verify the drift test still passes** (it greps `project.yml`, unaffected) and the doc references resolve:

Run: `test -d docs/guide && grep -q "docs/guide" README.md && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): writer-first rewrite; developer detail demoted to Development section"
```

---

## Task 13: AREA docs + full verification + smoke

**Files:**
- Modify: `Maugham/MCP/AREA.md` (tool count + `get_help`)

- [ ] **Step 1: Update `Maugham/MCP/AREA.md`** — change the tool count from 43 to 44 and add `get_help` to the tool list with a one-line description. Also grep for other "43 tools" mentions and update the user-facing ones:

Run: `grep -rn "43 tools" README.md docs CLAUDE.md Maugham 2>/dev/null`
Then update each user-facing occurrence to "44 tools". (CLAUDE.md is user-maintained — note it in the final summary rather than editing silently if it appears.)

- [ ] **Step 2: Run the FULL test suite (both schemes).** Mac:

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`.

Phone (MaughamCore is shared; nothing here touches it, but CLAUDE.md requires both schemes when core could be affected — this milestone is Mac-only, so this is a safety check):

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Release build** (CLAUDE.md: after `ProjectWindow.body`/menu changes, build Release before tagging — stricter type-check budget):

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual smoke (user runs this).** Document the checklist in the commit body:
  - Delete the `maugham.hasCompletedWelcome` default (`defaults delete com.maugham.Maugham.dev maugham.hasCompletedWelcome`) to simulate first launch.
  - Launch → carousel appears → page through 8 slides → **Try a sample Novel** → project opens from `~/Documents/Maugham Sample Novel`, in Recents → edit a line → ⌘Q → relaunch → **no carousel**, sample in Recents, edit intact.
  - Help → **Welcome to Maugham** → carousel reopens. Help → **Sample Projects ▸ Screenplay** → screenplay sample opens, Fountain styled, scene in navigator.
  - Help → **Maugham Help** (⌘?) → window opens, sidebar lists 9 topics, clicking renders markdown.
  - In Claude Desktop: "how do I use focus mode in Maugham?" → Claude calls `get_help` and answers from `editor-and-focus`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/AREA.md
git commit -m "docs(mcp): AREA tool count 43->44 (get_help); onboarding smoke checklist"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** Deliverable 1 (docs split + bundle) → Tasks 1–2, 4. Deliverable 2 (Help window + MCP) → Tasks 3, 5, 6, 7. Deliverable 3 (carousel) → Tasks 9, 10, 11. Deliverable 4 (sample projects) → Task 8, 11. Deliverable 5 (README) → Task 12. AREA/tool-count + verification → Task 13. All spec sections mapped.
- **Hard invariants:** sample opening routes through `Document.load`/`Bootstrap` (Task 8 test asserts anchors); destination naming uses `BuildVariant.current.displayName` (tripwire 13); no raw user-content moves (builder copies, never moves); MCP fails loudly on unknown topic (Task 5); `ContentUnavailableView` framed per tripwire 15 (Task 7).
- **Type consistency:** `HelpTopicIndex.Topic{slug,title,order}`, `markdown(for:)`, `GetHelpTool.respond(paramsJSON:index:)`, `WelcomeSlide.all`/`WelcomeSlide.ID`, `SampleProjectBuilder.Kind{novel,screenplay}`/`build(_:seedsRoot:destinationParent:)`/`buildInDocuments(_:)` used consistently across tasks. Notifications `.maughamShowHelp`/`.maughamShowWelcome`/`.maughamOpenSample` declared in Task 7/11 before use.
- **Open implementer note:** the exact `Document.load` signature (Task 8, Step 3) must be confirmed against `Maugham/OpLog/`/`EditorHost` and the call/assertion adjusted; intent is fixed.
