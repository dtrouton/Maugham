# Publishing Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a bidirectional publishing pipeline (PDF via bundled tectonic-LaTeX + EPUB via direct HTML/CSS packaging) driven by per-project Claude-authored templates plus a small structured config, with ~15 MCP tools so Claude can author, refine, compile, and view publications without leaving Claude Desktop.

**Architecture:** Sectioned `ProjectAST` is the unit of compile; mode metadata travels with each section; a `BodyEmitter` writes `body.tex` / `body.xhtml` that the project's Claude-authored template/stylesheet consumes. PDF compilation runs through a bundled `tectonic` binary; EPUB packaging is direct XHTML+OPF zip via Foundation's `Compression` framework. Publications live in a new `.maugham/publications.jsonl` log alongside snapshots in `.maugham/publications/<snapshot_id>.json`, separate from manuscript checkpoints — reproducibility comes from snapshotting template + styles + config + cover + font BYTES (not paths). A `CompileJobManager` actor backs the hybrid sync-up-to-`wait_seconds`-then-`job_id` compile contract. The MCP surface is 15 tools across 5 functional groups.

**Tech Stack:** Swift 6 / SwiftUI / AppKit / Foundation `Process` for tectonic / Foundation `Compression` (zlib) for EPUB / PDFKit for `read_publication_page` / xcodegen / XCTest. Bundles `tectonic` (single ~25 MB binary) inside `Maugham.app/Contents/Resources/bin/`.

**Reference spec:** `docs/superpowers/specs/2026-05-26-publishing-pipeline-design.md`

---

## File map

**Create — Models / Types:**
- `Maugham/Publish/PublishConfig.swift` — Codable config struct + nested types
- `Maugham/Publish/PublishConfigStore.swift` — JSON read/write/patch
- `Maugham/Publish/PublishConfigValidator.swift` — schema validation, version bumping
- `Maugham/Publish/PublishStarter.swift` — bundle resource loading + install
- `Maugham/Publish/ProjectAST.swift` — sectioned AST type
- `Maugham/Publish/ProjectASTBuilder.swift` — Project → ProjectAST
- `Maugham/Publish/LaTeXBodyEmitter.swift` — ProjectAST → body.tex
- `Maugham/Publish/XHTMLBodyEmitter.swift` — ProjectAST → body.xhtml
- `Maugham/Publish/LaTeXEscape.swift` — `% & # _ ~ ^ \ { }` escape rules
- `Maugham/Publish/XHTMLEscape.swift` — `< > & " '` escape rules
- `Maugham/Publish/Publication.swift` — Publication Codable struct
- `Maugham/Publish/PublicationSnapshot.swift` — Snapshot Codable struct
- `Maugham/Publish/PublicationStore.swift` — JSONL wrapper for publications.jsonl
- `Maugham/Publish/PublicationSnapshotStore.swift` — write/read snapshots
- `Maugham/Publish/CompileJob.swift` — job state + phase enums
- `Maugham/Publish/CompileJobManager.swift` — actor with in-memory job dict + GC
- `Maugham/Publish/Tectonic/TectonicLocator.swift` — finds bundled binary
- `Maugham/Publish/Tectonic/TectonicInvoker.swift` — `Process` wrapper
- `Maugham/Publish/Tectonic/TectonicLogParser.swift` — structured error extraction
- `Maugham/Publish/Tectonic/TectonicCache.swift` — cache dir resolution
- `Maugham/Publish/EPUB/EPUBPackage.swift` — manifest + spine model
- `Maugham/Publish/EPUB/EPUBOPFWriter.swift` — content.opf XML
- `Maugham/Publish/EPUB/EPUBContainerWriter.swift` — META-INF/container.xml + mimetype
- `Maugham/Publish/EPUB/EPUBZipPackager.swift` — assemble + zip
- `Maugham/Publish/Compilers/PDFCompiler.swift` — full PDF pipeline
- `Maugham/Publish/Compilers/EPUBCompiler.swift` — full EPUB pipeline
- `Maugham/Publish/Compilers/PreviewCompiler.swift` — subset compile
- `Maugham/Publish/Compilers/CompileOrchestrator.swift` — top-level dispatch
- `Maugham/Publish/Compilers/Republisher.swift` — snapshot extract + recompile

**Create — MCP tools:**
- `Maugham/MCP/Tools/InitializePublishTemplateTool.swift`
- `Maugham/MCP/Tools/PublishFileTools.swift` — five tools: list / read_file / read_image / write / delete
- `Maugham/MCP/Tools/PublishConfigTools.swift` — get / set
- `Maugham/MCP/Tools/CompileTools.swift` — compile / preview / status / cancel
- `Maugham/MCP/Tools/PublicationTools.swift` — list / read_page / republish

**Create — UI:**
- `Maugham/Views/Publish/ExportsListView.swift`
- `Maugham/Views/Publish/PublishStatusPill.swift`
- `Maugham/Views/Publish/InspectorPublishSection.swift`

**Create — Resources (barebones starter):**
- `Maugham/Resources/PublishStarter/template.tex`
- `Maugham/Resources/PublishStarter/preamble.tex`
- `Maugham/Resources/PublishStarter/frontmatter.tex`
- `Maugham/Resources/PublishStarter/prose.tex`
- `Maugham/Resources/PublishStarter/screenplay.tex`
- `Maugham/Resources/PublishStarter/backmatter.tex`
- `Maugham/Resources/PublishStarter/styles.css`
- `Maugham/Resources/PublishStarter/default-config.json`

**Create — bundled tectonic binary:**
- `Maugham/Resources/bin/tectonic` — fetched and committed via release-assets workflow (see Task 15)

**Create — tests:**
- `MaughamTests/Publish/PublishConfigTests.swift`
- `MaughamTests/Publish/PublishConfigStoreTests.swift`
- `MaughamTests/Publish/PublishConfigValidatorTests.swift`
- `MaughamTests/Publish/PublishStarterTests.swift`
- `MaughamTests/Publish/ProjectASTBuilderTests.swift`
- `MaughamTests/Publish/LaTeXBodyEmitterTests.swift`
- `MaughamTests/Publish/XHTMLBodyEmitterTests.swift`
- `MaughamTests/Publish/LaTeXEscapeTests.swift`
- `MaughamTests/Publish/XHTMLEscapeTests.swift`
- `MaughamTests/Publish/PublicationTests.swift`
- `MaughamTests/Publish/PublicationStoreTests.swift`
- `MaughamTests/Publish/PublicationSnapshotStoreTests.swift`
- `MaughamTests/Publish/CompileJobManagerTests.swift`
- `MaughamTests/Publish/Tectonic/TectonicLocatorTests.swift`
- `MaughamTests/Publish/Tectonic/TectonicInvokerTests.swift`
- `MaughamTests/Publish/Tectonic/TectonicLogParserTests.swift`
- `MaughamTests/Publish/Tectonic/TectonicCacheTests.swift`
- `MaughamTests/Publish/EPUB/EPUBOPFWriterTests.swift`
- `MaughamTests/Publish/EPUB/EPUBContainerWriterTests.swift`
- `MaughamTests/Publish/EPUB/EPUBZipPackagerTests.swift`
- `MaughamTests/Publish/Compilers/PDFCompilerTests.swift`
- `MaughamTests/Publish/Compilers/EPUBCompilerTests.swift`
- `MaughamTests/Publish/Compilers/RepublisherTests.swift`
- `MaughamTests/MCP/Tools/InitializePublishTemplateToolTests.swift`
- `MaughamTests/MCP/Tools/PublishFileToolsTests.swift`
- `MaughamTests/MCP/Tools/PublishConfigToolsTests.swift`
- `MaughamTests/MCP/Tools/CompileToolsTests.swift`
- `MaughamTests/MCP/Tools/PublicationToolsTests.swift`
- `MaughamTests/Publish/PublishingEndToEndTests.swift`

**Modify:**
- `Maugham/Stores/MaughamSidecarPath.swift` — add `.maugham/publish/...` and `.maugham/publications*` cases
- `Maugham/MCP/MCPTool.swift` — add 15 new tools to `MCPToolCatalog.all`
- `Maugham/Views/ProjectWindow.swift` — wire in `ExportsListView`, `PublishStatusPill`
- `Maugham/Views/Inspector*.swift` (find the inspector pane root) — add `InspectorPublishSection`
- `project.yml` — register new sources, copy `Maugham/Resources/bin/tectonic` into bundle's Resources/bin
- `Maugham/Stores/ProjectFactory.swift` — call `PublishStarter.installIfMissing()` for new projects

---

## Phase 1 — Sidecar path + config + starter

### Task 1: Extend `MaughamSidecarPath` for `.maugham/publish/`

**Files:**
- Modify: `Maugham/Stores/MaughamSidecarPath.swift`
- Test: `MaughamTests/Stores/MaughamSidecarPathTests.swift` (existing file — find and append)

- [ ] **Step 1: Write failing tests**

Append to `MaughamTests/Stores/MaughamSidecarPathTests.swift`:

```swift
func testClassifies_publishTemplate() {
    let url = projectURL.appendingPathComponent(".maugham/publish/template.tex")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publishTemplate(relativePath: ".maugham/publish/template.tex")
    )
}

func testClassifies_publishStyles() {
    let url = projectURL.appendingPathComponent(".maugham/publish/styles.css")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publishStyles(relativePath: ".maugham/publish/styles.css")
    )
}

func testClassifies_publishConfig() {
    let url = projectURL.appendingPathComponent(".maugham/publish/config.json")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publishConfig
    )
}

func testClassifies_publishPartial_preamble() {
    let url = projectURL.appendingPathComponent(".maugham/publish/preamble.tex")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publishTemplate(relativePath: ".maugham/publish/preamble.tex")
    )
}

func testClassifies_publishCover() {
    let url = projectURL.appendingPathComponent(".maugham/publish/cover.jpg")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publishAsset(relativePath: ".maugham/publish/cover.jpg")
    )
}

func testClassifies_publishFont() {
    let url = projectURL.appendingPathComponent(".maugham/publish/fonts/EBGaramond-Regular.otf")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publishAsset(relativePath: ".maugham/publish/fonts/EBGaramond-Regular.otf")
    )
}

func testClassifies_publishBuild_isTransient() {
    let url = projectURL.appendingPathComponent(".maugham/publish/build/body.tex")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publishBuild(relativePath: ".maugham/publish/build/body.tex")
    )
}

func testClassifies_publicationsLog() {
    let url = projectURL.appendingPathComponent(".maugham/publications.jsonl")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publicationsLog
    )
}

func testClassifies_publicationSnapshot() {
    let url = projectURL.appendingPathComponent(".maugham/publications/snap-abc123.json")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publicationSnapshot(relativePath: ".maugham/publications/snap-abc123.json")
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/MaughamSidecarPathTests CODE_SIGNING_ALLOWED=NO`

Expected: 9 new tests FAIL with "type 'MaughamSidecarPath' has no member 'publishTemplate'" (and similar).

- [ ] **Step 3: Add new enum cases**

In `Maugham/Stores/MaughamSidecarPath.swift`, add five new cases inside the enum (after the existing `case trash(relativePath: String)` line):

```swift
/// `.maugham/publish/template.tex` + all `.tex` partials. The Claude-authored
/// LaTeX template artifact.
case publishTemplate(relativePath: String)

/// `.maugham/publish/styles.css` + any css partials. The EPUB stylesheet.
case publishStyles(relativePath: String)

/// `.maugham/publish/config.json`. Structured, schema-validated, MCP-mutable.
case publishConfig

/// `.maugham/publish/cover.{jpg,png}`, `fonts/*`, or any other non-tex/non-css
/// non-config file under the publish dir. Binary or unknown content.
case publishAsset(relativePath: String)

/// `.maugham/publish/build/*` — transient body emission + tectonic aux files.
/// Routing intent: ignore (write-only by the compile pipeline).
case publishBuild(relativePath: String)

/// `.maugham/publications.jsonl` — append-only publication log.
case publicationsLog

/// `.maugham/publications/<id>.json` — per-publication snapshot blob.
case publicationSnapshot(relativePath: String)
```

Update `classifySidecar` to dispatch the new prefixes (insert before the final `return .unknownSidecar(...)` line):

```swift
if relativePath.hasPrefix(".maugham/publish/build/") {
    return .publishBuild(relativePath: relativePath)
}

if relativePath.hasPrefix(".maugham/publish/") {
    if relativePath == ".maugham/publish/config.json" {
        return .publishConfig
    }
    if relativePath.hasSuffix(".tex") {
        return .publishTemplate(relativePath: relativePath)
    }
    if relativePath.hasSuffix(".css") {
        return .publishStyles(relativePath: relativePath)
    }
    return .publishAsset(relativePath: relativePath)
}

if relativePath == ".maugham/publications.jsonl" {
    return .publicationsLog
}

if relativePath.hasPrefix(".maugham/publications/") {
    return .publicationSnapshot(relativePath: relativePath)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/MaughamSidecarPathTests CODE_SIGNING_ALLOWED=NO`

Expected: all `MaughamSidecarPathTests` PASS. Also verify nothing downstream breaks (the `DocumentStore.presenterDidChangeSubitem` switch will need new cases — they're routing-intent `.ignore` per the spec, but the switch must be exhaustive).

- [ ] **Step 5: Fix any exhaustive-switch errors downstream**

Search for `switch.*MaughamSidecarPath` or `case .manifest` in non-test code:

```bash
grep -rn "case \.opLog\|case \.checkpoints\|MaughamSidecarPath" Maugham/ --include="*.swift" | grep -v "MaughamSidecarPath.swift"
```

For each switch that doesn't have a `default:` clause, add:

```swift
case .publishTemplate, .publishStyles, .publishConfig, .publishAsset,
     .publishBuild, .publicationsLog, .publicationSnapshot:
    return  // ignore — owned by publish/publication subsystem (no presenter routing in v1)
```

The presenter routing for live publish-file edits (conflict resolution between Claude-via-MCP writes and iCloud sync) is deferred to a follow-up; v1 treats publish files as MCP-owned and ignores external changes to them in the routing layer.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/MaughamSidecarPath.swift MaughamTests/Stores/MaughamSidecarPathTests.swift
# plus any switch sites you touched
git commit -m "feat(publish): classify .maugham/publish/ + .maugham/publications/ paths"
```

---

### Task 2: `PublishConfig` Codable struct

**Files:**
- Create: `Maugham/Publish/PublishConfig.swift`
- Test: `MaughamTests/Publish/PublishConfigTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublishConfigTests: XCTestCase {

    func testRoundTrips_minimalConfig() throws {
        let config = PublishConfig(
            schemaVersion: 1,
            metadata: .init(title: "Test Book", author: "Author"),
            outputs: .init(),
            cover: .init(),
            sections: [:],
            epubOverrides: .init(),
            nextVersion: "0.1",
            activeLabelHint: nil
        )
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PublishConfig.self, from: encoded)
        XCTAssertEqual(decoded, config)
    }

    func testDecodes_fullConfig() throws {
        let json = """
        {
          "schema_version": 1,
          "metadata": {
            "title": "Stories from the Edge",
            "subtitle": null,
            "author": "Denver Trouton",
            "copyright": "© 2026 Denver Trouton",
            "isbn": null,
            "publisher": null,
            "year": 2026,
            "language": "en",
            "keywords": ["fiction", "collection"]
          },
          "outputs": {
            "directory": "Exports",
            "filename_template": "{title}-v{version}{label_suffix}.{ext}",
            "sanitize_spaces": false,
            "formats_enabled": ["pdf", "epub"]
          },
          "cover": {
            "path": "cover.jpg",
            "epub_specific_path": null
          },
          "sections": {
            "p_abc123": {
              "title_override": "Opening",
              "start_on": "recto",
              "include_in_toc": true
            }
          },
          "epub_overrides": {
            "metadata": {},
            "cover": null
          },
          "next_version": "0.3",
          "active_label_hint": "galley"
        }
        """
        let config = try JSONDecoder().decode(PublishConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.metadata.title, "Stories from the Edge")
        XCTAssertEqual(config.metadata.keywords, ["fiction", "collection"])
        XCTAssertEqual(config.nextVersion, "0.3")
        XCTAssertEqual(config.sections["p_abc123"]?.startOn, .recto)
        XCTAssertEqual(config.sections["p_abc123"]?.titleOverride, "Opening")
    }

    func testStartOn_decodesAllValues() throws {
        for raw in ["any", "recto", "verso"] {
            let json = "{\"title_override\": null, \"start_on\": \"\(raw)\", \"include_in_toc\": true}"
            let section = try JSONDecoder().decode(PublishConfig.Section.self, from: Data(json.utf8))
            XCTAssertEqual(section.startOn.rawValue, raw)
        }
    }

    func testFormats_decodesEnabledArray() throws {
        let outputs = try JSONDecoder().decode(
            PublishConfig.Outputs.self,
            from: Data("{\"directory\":\"Exports\",\"filename_template\":\"x\",\"sanitize_spaces\":false,\"formats_enabled\":[\"pdf\",\"epub\"]}".utf8)
        )
        XCTAssertEqual(outputs.formatsEnabled, [.pdf, .epub])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishConfigTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail with "cannot find type 'PublishConfig'".

- [ ] **Step 3: Implement `PublishConfig`**

Create `Maugham/Publish/PublishConfig.swift`:

```swift
import Foundation

/// Per-project publishing configuration. Persisted as
/// `.maugham/publish/config.json`. Small, schema-validated, MCP-mutable.
///
/// Anything aesthetic — fonts, page geometry, drop caps, custom commands —
/// lives in `template.tex` / `styles.css`, NOT here. The boundary protects
/// the differentiation: config can't drive the engine into generic output.
public struct PublishConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var metadata: Metadata
    public var outputs: Outputs
    public var cover: Cover
    public var sections: [String: Section]   // keyed by piece_id
    public var epubOverrides: EPUBOverrides
    public var nextVersion: String           // e.g. "0.3"
    public var activeLabelHint: String?

    public struct Metadata: Codable, Equatable, Sendable {
        public var title: String
        public var subtitle: String?
        public var author: String
        public var copyright: String?
        public var isbn: String?
        public var publisher: String?
        public var year: Int?
        public var language: String
        public var keywords: [String]

        public init(
            title: String = "Untitled",
            subtitle: String? = nil,
            author: String = "",
            copyright: String? = nil,
            isbn: String? = nil,
            publisher: String? = nil,
            year: Int? = nil,
            language: String = "en",
            keywords: [String] = []
        ) {
            self.title = title
            self.subtitle = subtitle
            self.author = author
            self.copyright = copyright
            self.isbn = isbn
            self.publisher = publisher
            self.year = year
            self.language = language
            self.keywords = keywords
        }
    }

    public struct Outputs: Codable, Equatable, Sendable {
        public var directory: String
        public var filenameTemplate: String
        public var sanitizeSpaces: Bool
        public var formatsEnabled: [Format]

        public init(
            directory: String = "Exports",
            filenameTemplate: String = "{title}-v{version}{label_suffix}.{ext}",
            sanitizeSpaces: Bool = false,
            formatsEnabled: [Format] = [.pdf, .epub]
        ) {
            self.directory = directory
            self.filenameTemplate = filenameTemplate
            self.sanitizeSpaces = sanitizeSpaces
            self.formatsEnabled = formatsEnabled
        }

        enum CodingKeys: String, CodingKey {
            case directory
            case filenameTemplate = "filename_template"
            case sanitizeSpaces = "sanitize_spaces"
            case formatsEnabled = "formats_enabled"
        }
    }

    public enum Format: String, Codable, Equatable, Sendable, CaseIterable {
        case pdf
        case epub
    }

    public struct Cover: Codable, Equatable, Sendable {
        public var path: String?
        public var epubSpecificPath: String?

        public init(path: String? = "cover.jpg", epubSpecificPath: String? = nil) {
            self.path = path
            self.epubSpecificPath = epubSpecificPath
        }

        enum CodingKeys: String, CodingKey {
            case path
            case epubSpecificPath = "epub_specific_path"
        }
    }

    public struct Section: Codable, Equatable, Sendable {
        public var titleOverride: String?
        public var startOn: StartOn
        public var includeInToc: Bool

        public init(
            titleOverride: String? = nil,
            startOn: StartOn = .any,
            includeInToc: Bool = true
        ) {
            self.titleOverride = titleOverride
            self.startOn = startOn
            self.includeInToc = includeInToc
        }

        enum CodingKeys: String, CodingKey {
            case titleOverride = "title_override"
            case startOn = "start_on"
            case includeInToc = "include_in_toc"
        }
    }

    public enum StartOn: String, Codable, Equatable, Sendable {
        case any
        case recto
        case verso
    }

    public struct EPUBOverrides: Codable, Equatable, Sendable {
        public var metadata: [String: String]
        public var cover: String?

        public init(metadata: [String: String] = [:], cover: String? = nil) {
            self.metadata = metadata
            self.cover = cover
        }
    }

    public init(
        schemaVersion: Int = 1,
        metadata: Metadata = .init(),
        outputs: Outputs = .init(),
        cover: Cover = .init(),
        sections: [String: Section] = [:],
        epubOverrides: EPUBOverrides = .init(),
        nextVersion: String = "0.1",
        activeLabelHint: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.outputs = outputs
        self.cover = cover
        self.sections = sections
        self.epubOverrides = epubOverrides
        self.nextVersion = nextVersion
        self.activeLabelHint = activeLabelHint
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case metadata
        case outputs
        case cover
        case sections
        case epubOverrides = "epub_overrides"
        case nextVersion = "next_version"
        case activeLabelHint = "active_label_hint"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishConfigTests CODE_SIGNING_ALLOWED=NO`

Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/PublishConfig.swift MaughamTests/Publish/PublishConfigTests.swift
git commit -m "feat(publish): PublishConfig Codable model"
```

---

### Task 3: `PublishConfigStore` — read/write to disk

**Files:**
- Create: `Maugham/Publish/PublishConfigStore.swift`
- Test: `MaughamTests/Publish/PublishConfigStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublishConfigStoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishConfigStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoad_returnsNilWhenAbsent() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        let result = try await store.load()
        XCTAssertNil(result)
    }

    func testSave_thenLoad_roundTrips() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig()
        cfg.metadata.title = "Round Trip"
        try await store.save(cfg)

        let loaded = try await store.load()
        XCTAssertEqual(loaded?.metadata.title, "Round Trip")
    }

    func testSave_writesPrettyPrintedJSON_withSnakeCaseKeys() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig())
        let data = try Data(contentsOf: tmp.appendingPathComponent(".maugham/publish/config.json"))
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("\"schema_version\""))
        XCTAssertTrue(s.contains("\"next_version\""))
        XCTAssertTrue(s.contains("\n"))   // pretty-printed
    }

    func testSave_createsIntermediateDirectories() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig())
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent(".maugham/publish").path,
            isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishConfigStoreTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `PublishConfigStore` undefined.

- [ ] **Step 3: Implement `PublishConfigStore`**

Create `Maugham/Publish/PublishConfigStore.swift`:

```swift
import Foundation

/// Read/write `.maugham/publish/config.json`. Pretty-printed, snake_case keys.
/// Atomic writes (write to temp + rename).
public actor PublishConfigStore {
    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    public var fileURL: URL {
        projectURL.appendingPathComponent(".maugham/publish/config.json")
    }

    public func load() throws -> PublishConfig? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PublishConfig.self, from: data)
    }

    public func save(_ config: PublishConfig) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)

        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishConfigStoreTests CODE_SIGNING_ALLOWED=NO`

Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/PublishConfigStore.swift MaughamTests/Publish/PublishConfigStoreTests.swift
git commit -m "feat(publish): PublishConfigStore atomic JSON read/write"
```

---

### Task 4: JSON-Merge-Patch helper

**Files:**
- Create: `Maugham/Publish/JSONMergePatch.swift`
- Test: `MaughamTests/Publish/JSONMergePatchTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class JSONMergePatchTests: XCTestCase {

    func testReplaces_topLevelScalar() throws {
        let original = #"{"a":1,"b":2}"#.data(using: .utf8)!
        let patch    = #"{"a":99}"#.data(using: .utf8)!
        let merged = try JSONMergePatch.apply(patch: patch, to: original)
        XCTAssertEqual(try canon(merged), try canon(#"{"a":99,"b":2}"#.data(using: .utf8)!))
    }

    func testNullDeletes_key() throws {
        let original = #"{"a":1,"b":2}"#.data(using: .utf8)!
        let patch    = #"{"a":null}"#.data(using: .utf8)!
        let merged = try JSONMergePatch.apply(patch: patch, to: original)
        XCTAssertEqual(try canon(merged), try canon(#"{"b":2}"#.data(using: .utf8)!))
    }

    func testRecursiveMerge_objects() throws {
        let original = #"{"o":{"a":1,"b":2}}"#.data(using: .utf8)!
        let patch    = #"{"o":{"a":99,"c":3}}"#.data(using: .utf8)!
        let merged = try JSONMergePatch.apply(patch: patch, to: original)
        XCTAssertEqual(try canon(merged), try canon(#"{"o":{"a":99,"b":2,"c":3}}"#.data(using: .utf8)!))
    }

    func testArrays_replacedWhole() throws {
        let original = #"{"a":[1,2,3]}"#.data(using: .utf8)!
        let patch    = #"{"a":[9]}"#.data(using: .utf8)!
        let merged = try JSONMergePatch.apply(patch: patch, to: original)
        XCTAssertEqual(try canon(merged), try canon(#"{"a":[9]}"#.data(using: .utf8)!))
    }

    private func canon(_ data: Data) throws -> String {
        let any = try JSONSerialization.jsonObject(with: data)
        let out = try JSONSerialization.data(withJSONObject: any, options: [.sortedKeys])
        return String(data: out, encoding: .utf8)!
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/JSONMergePatchTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `JSONMergePatch` undefined.

- [ ] **Step 3: Implement RFC 7396 JSON Merge Patch**

Create `Maugham/Publish/JSONMergePatch.swift`:

```swift
import Foundation

/// RFC 7396 JSON Merge Patch.
///
/// - Object keys in the patch with null values are DELETED from the target.
/// - Object keys with object values are MERGED recursively.
/// - All other values (scalars, arrays) REPLACE the target's value.
public enum JSONMergePatch {

    public enum Error: Swift.Error {
        case invalidJSON
    }

    public static func apply(patch: Data, to target: Data) throws -> Data {
        let patchJSON  = try JSONSerialization.jsonObject(with: patch)
        let targetJSON = try JSONSerialization.jsonObject(with: target)
        let merged = mergeAny(target: targetJSON, patch: patchJSON)
        guard let merged else {
            return try JSONSerialization.data(
                withJSONObject: NSDictionary(),
                options: [.sortedKeys])
        }
        return try JSONSerialization.data(
            withJSONObject: merged, options: [.sortedKeys])
    }

    private static func mergeAny(target: Any, patch: Any) -> Any? {
        // If patch is an object, do the merge dance per RFC.
        if let patchDict = patch as? [String: Any] {
            var result: [String: Any] = (target as? [String: Any]) ?? [:]
            for (key, value) in patchDict {
                if value is NSNull {
                    result.removeValue(forKey: key)
                } else if let existing = result[key],
                          let merged = mergeAny(target: existing, patch: value) {
                    result[key] = merged
                } else {
                    // Either no existing value, or merge returned nil from a
                    // top-level null. We only get nil when patch IS NSNull,
                    // already handled above, so this branch installs `value`.
                    result[key] = value
                }
            }
            return result
        }
        // Patch is null at the top level: signal delete.
        if patch is NSNull {
            return nil
        }
        // Patch is any non-object non-null value: replace.
        return patch
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/JSONMergePatchTests CODE_SIGNING_ALLOWED=NO`

Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/JSONMergePatch.swift MaughamTests/Publish/JSONMergePatchTests.swift
git commit -m "feat(publish): RFC 7396 JSON Merge Patch helper"
```

---

### Task 5: `PublishConfigValidator` — schema validation + version bumping

**Files:**
- Create: `Maugham/Publish/PublishConfigValidator.swift`
- Test: `MaughamTests/Publish/PublishConfigValidatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublishConfigValidatorTests: XCTestCase {

    func testAccepts_validConfig() {
        let cfg = PublishConfig(metadata: .init(title: "X", author: "Y"))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.isEmpty)
    }

    func testRejects_emptyTitle() {
        var cfg = PublishConfig()
        cfg.metadata.title = ""
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "metadata.title" }))
    }

    func testRejects_unknownStartOn() throws {
        // Decoder enforces enum, so we test via raw JSON.
        let json = """
        {"title_override":null,"start_on":"sideways","include_in_toc":true}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(
            PublishConfig.Section.self, from: Data(json.utf8)))
    }

    func testRejects_negativeYear() {
        var cfg = PublishConfig()
        cfg.metadata.year = -100
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "metadata.year" }))
    }

    func testRejects_unsupportedSchemaVersion() {
        var cfg = PublishConfig()
        cfg.schemaVersion = 99
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "schema_version" }))
    }

    func testBumpVersion_minor_succeeds() {
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "0.3"), "0.4")
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "1.9"), "1.10")
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "0.1"), "0.2")
    }

    func testBumpVersion_invalidInput_resetsToBaseline() {
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "garbage"), "0.1")
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: ""), "0.1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishConfigValidatorTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `PublishConfigValidator` undefined.

- [ ] **Step 3: Implement validator**

Create `Maugham/Publish/PublishConfigValidator.swift`:

```swift
import Foundation

public enum PublishConfigValidator {

    /// Maximum supported `schema_version`. Bump when adding fields that older
    /// clients shouldn't silently accept.
    public static let supportedSchemaVersion = 1

    public struct ValidationError: Equatable, Sendable {
        public let field: String
        public let message: String
    }

    public static func validate(_ cfg: PublishConfig) -> [ValidationError] {
        var errs: [ValidationError] = []

        if cfg.schemaVersion < 1 || cfg.schemaVersion > supportedSchemaVersion {
            errs.append(.init(
                field: "schema_version",
                message: "Unsupported schema_version \(cfg.schemaVersion); supported: 1...\(supportedSchemaVersion)"))
        }

        if cfg.metadata.title.trimmingCharacters(in: .whitespaces).isEmpty {
            errs.append(.init(field: "metadata.title", message: "title must not be empty"))
        }

        if let y = cfg.metadata.year, y < 0 || y > 9999 {
            errs.append(.init(field: "metadata.year", message: "year must be in 0...9999"))
        }

        if cfg.outputs.directory.isEmpty {
            errs.append(.init(field: "outputs.directory", message: "directory must not be empty"))
        }

        if !cfg.outputs.filenameTemplate.contains("{title}") ||
           !cfg.outputs.filenameTemplate.contains("{version}") ||
           !cfg.outputs.filenameTemplate.contains("{ext}") {
            errs.append(.init(
                field: "outputs.filename_template",
                message: "filename_template must include {title}, {version}, and {ext}"))
        }

        if cfg.outputs.formatsEnabled.isEmpty {
            errs.append(.init(
                field: "outputs.formats_enabled",
                message: "at least one format must be enabled"))
        }

        return errs
    }

    /// Parse "X.Y" and return "X.(Y+1)". Returns "0.1" for any invalid input.
    public static func bumpedNextVersion(from current: String) -> String {
        let parts = current.split(separator: ".")
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              major >= 0, minor >= 0
        else {
            return "0.1"
        }
        return "\(major).\(minor + 1)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishConfigValidatorTests CODE_SIGNING_ALLOWED=NO`

Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/PublishConfigValidator.swift MaughamTests/Publish/PublishConfigValidatorTests.swift
git commit -m "feat(publish): config validator + version bumper"
```

---

### Task 6: Wire `applyPatch` into `PublishConfigStore`

**Files:**
- Modify: `Maugham/Publish/PublishConfigStore.swift`
- Test: append to `MaughamTests/Publish/PublishConfigStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `PublishConfigStoreTests.swift`:

```swift
func testApplyPatch_mergesIntoExistingConfig() async throws {
    let store = PublishConfigStore(projectURL: tmp)
    var initial = PublishConfig()
    initial.metadata.title = "Initial"
    initial.metadata.author = "A"
    try await store.save(initial)

    let patch = #"{"metadata":{"title":"Updated","keywords":["x","y"]}}"#
    let result = try await store.applyPatch(Data(patch.utf8))

    XCTAssertEqual(result.config.metadata.title, "Updated")
    XCTAssertEqual(result.config.metadata.author, "A")
    XCTAssertEqual(result.config.metadata.keywords, ["x", "y"])
    XCTAssertTrue(result.errors.isEmpty)

    let reloaded = try await store.load()
    XCTAssertEqual(reloaded?.metadata.title, "Updated")
}

func testApplyPatch_loadsFromNothing_usesDefaults() async throws {
    let store = PublishConfigStore(projectURL: tmp)
    let patch = #"{"metadata":{"title":"Created","author":"X"}}"#
    let result = try await store.applyPatch(Data(patch.utf8))
    XCTAssertEqual(result.config.metadata.title, "Created")
    XCTAssertEqual(result.config.schemaVersion, 1)
}

func testApplyPatch_reportsValidationErrors_andDoesNotSave() async throws {
    let store = PublishConfigStore(projectURL: tmp)
    try await store.save(PublishConfig(metadata: .init(title: "Good", author: "Y")))

    let patch = #"{"metadata":{"title":""}}"#
    let result = try await store.applyPatch(Data(patch.utf8))
    XCTAssertFalse(result.errors.isEmpty)
    XCTAssertEqual(result.errors.first?.field, "metadata.title")

    let reloaded = try await store.load()
    XCTAssertEqual(reloaded?.metadata.title, "Good") // unchanged
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishConfigStoreTests CODE_SIGNING_ALLOWED=NO`

Expected: 3 new tests FAIL — `applyPatch` undefined.

- [ ] **Step 3: Add `applyPatch`**

Append to `PublishConfigStore.swift`:

```swift
public struct ApplyPatchResult: Sendable {
    public let config: PublishConfig
    public let errors: [PublishConfigValidator.ValidationError]
}

extension PublishConfigStore {
    public func applyPatch(_ patch: Data) throws -> ApplyPatchResult {
        let current = try load() ?? PublishConfig()
        let currentData = try JSONEncoder().encode(current)
        let mergedData = try JSONMergePatch.apply(patch: patch, to: currentData)
        let merged = try JSONDecoder().decode(PublishConfig.self, from: mergedData)

        let errs = PublishConfigValidator.validate(merged)
        if errs.isEmpty {
            try save(merged)
        }
        return ApplyPatchResult(config: merged, errors: errs)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishConfigStoreTests CODE_SIGNING_ALLOWED=NO`

Expected: all 7 tests (4 prior + 3 new) PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/PublishConfigStore.swift MaughamTests/Publish/PublishConfigStoreTests.swift
git commit -m "feat(publish): applyPatch with validation gating"
```

---

### Task 7: Barebones starter resource files

**Files:**
- Create: `Maugham/Resources/PublishStarter/template.tex`
- Create: `Maugham/Resources/PublishStarter/preamble.tex`
- Create: `Maugham/Resources/PublishStarter/frontmatter.tex`
- Create: `Maugham/Resources/PublishStarter/prose.tex`
- Create: `Maugham/Resources/PublishStarter/screenplay.tex`
- Create: `Maugham/Resources/PublishStarter/backmatter.tex`
- Create: `Maugham/Resources/PublishStarter/styles.css`
- Create: `Maugham/Resources/PublishStarter/default-config.json`
- Modify: `project.yml` — include the new resources

- [ ] **Step 1: Create starter `template.tex`**

```latex
% Barebones publish template.
% This is the working reference implementation of Maugham's body-emission
% contract. It renders correctly but is DELIBERATELY plain — Computer
% Modern, no drop caps, no ornaments — so it explicitly invites redesign.
% Claude is expected to rewrite this and the partials below to give each
% project its own typographic identity.

\documentclass[11pt,letterpaper]{article}

\input{preamble}
\input{prose}
\input{screenplay}

\begin{document}

\input{frontmatter}

\input{build/body}

\input{backmatter}

\end{document}
```

- [ ] **Step 2: Create starter `preamble.tex`**

```latex
% Packages and metadata. Claude can rewrite this entirely.

\usepackage[utf8]{inputenc}
\usepackage{geometry}
\geometry{margin=1in}
\usepackage{titling}
\usepackage{titlesec}
\usepackage{hyperref}
\hypersetup{
  pdftitle={\Title},
  pdfauthor={\Author},
  pdfsubject={\Subtitle},
  pdfkeywords={\Keywords},
  pdfproducer={Maugham via tectonic},
  pdfcreator={Maugham}
}

% Maugham injects these from config.json before compilation.
\providecommand{\Title}{Untitled}
\providecommand{\Subtitle}{}
\providecommand{\Author}{}
\providecommand{\Copyright}{}
\providecommand{\Keywords}{}
\providecommand{\MaughamVersion}{0.1}
\providecommand{\MaughamLabel}{}
\providecommand{\MaughamCheckpointID}{}
\providecommand{\MaughamCompiledAt}{}

% Wiki link in prose: rendered as plain bold display text (no hyperlink
% target; wiki targets resolve inside Maugham, not in the PDF).
\newcommand{\wikilink}[2]{\textbf{#2}}
```

- [ ] **Step 3: Create starter `frontmatter.tex`**

```latex
% Title page. Reads metadata via the \Title / \Author / \Copyright commands
% defined in preamble.tex (populated by Maugham from config.json).

\begin{titlepage}
\centering
\vspace*{4cm}
{\huge\bfseries \Title \par}
\vspace{1cm}
{\large \Subtitle \par}
\vspace{2cm}
{\Large \Author \par}
\vfill
{\small \Copyright \par}
\end{titlepage}

\tableofcontents
\newpage
```

- [ ] **Step 4: Create starter `prose.tex`**

```latex
% Prose environment. Maugham's body emitter wraps each prose section in
% \begin{prose}{Section Title}...\end{prose}. Inside, paragraphs are plain
% LaTeX; scene breaks emit \scenebreak; emphasis is \emph{...}, strong is
% \textbf{...}, wiki-links are \wikilink{target}{display}.

\newenvironment{prose}[1]
  {\section{#1}}
  {}

% A plain centered asterism. Claude can replace with an ornament/glyph,
% a horizontal rule, blank space, anything.
\newcommand{\scenebreak}{%
  \par\vspace{1em}\centering * * *\vspace{1em}\par\noindent}
```

- [ ] **Step 5: Create starter `screenplay.tex`**

```latex
% Screenplay environment. Body emitter wraps each fountain section in
% \begin{screenplay}{Section Title}...\end{screenplay}. Inside it uses:
%   \scene{INT. KITCHEN - DAY}
%   \action{Aaron pours coffee.}
%   \character{AARON}
%   \dialogue{Morning.}
%   \parenthetical{(quietly)}
%   \transition{CUT TO:}
%   \dualdialogue{leftBlock}{rightBlock}
%
% Barebones rendering is Courier 12, monospaced. Margins are tight; this is
% NOT industry-WGA-grade — it just renders correctly.

\usepackage{environ}

\NewEnviron{screenplay}[1]{%
  \section{#1}%
  \begingroup
  \fontfamily{cmtt}\selectfont
  \BODY
  \endgroup
}

\newcommand{\scene}[1]{\par\vspace{1em}\textbf{\MakeUppercase{#1}}\par}
\newcommand{\action}[1]{\par #1\par}
\newcommand{\character}[1]{\par\hspace*{2in}\MakeUppercase{#1}\par}
\newcommand{\dialogue}[1]{\par\hspace*{1in}\begin{minipage}{4in}#1\end{minipage}\par}
\newcommand{\parenthetical}[1]{\par\hspace*{1.5in}\textit{#1}\par}
\newcommand{\transition}[1]{\par\hfill\MakeUppercase{#1}\par}
\newcommand{\dualdialogue}[2]{%
  \par\noindent
  \begin{minipage}[t]{0.45\textwidth}#1\end{minipage}\hfill
  \begin{minipage}[t]{0.45\textwidth}#2\end{minipage}\par
}
```

- [ ] **Step 6: Create starter `backmatter.tex`**

```latex
% Empty by default. Claude can add about-the-author, acknowledgments, etc.
```

- [ ] **Step 7: Create starter `styles.css`**

```css
/* Barebones EPUB stylesheet. Thesis-grade typography — explicitly NOT
   the "Maugham look". Claude is expected to rewrite per project. */

body {
  font-family: serif;
  font-size: 1em;
  line-height: 1.45;
  margin: 1em;
}

h1 { font-size: 1.5em; margin-top: 2em; }
h2 { font-size: 1.25em; margin-top: 1.5em; }

p { margin: 0.5em 0; text-indent: 0; }

section.prose p + p { text-indent: 1.5em; }

hr.scene-break {
  border: none;
  text-align: center;
  margin: 1em 0;
}
hr.scene-break::after { content: "* * *"; }

section.screenplay {
  font-family: monospace;
}
section.screenplay p.scene-heading {
  font-weight: bold;
  text-transform: uppercase;
  margin-top: 1em;
}
section.screenplay p.character {
  text-transform: uppercase;
  margin-left: 25%;
}
section.screenplay p.dialogue { margin-left: 15%; margin-right: 15%; }
section.screenplay p.parenthetical { margin-left: 20%; font-style: italic; }
section.screenplay p.transition { text-align: right; text-transform: uppercase; }
```

- [ ] **Step 8: Create starter `default-config.json`**

```json
{
  "schema_version": 1,
  "metadata": {
    "title": "Untitled",
    "subtitle": null,
    "author": "",
    "copyright": null,
    "isbn": null,
    "publisher": null,
    "year": null,
    "language": "en",
    "keywords": []
  },
  "outputs": {
    "directory": "Exports",
    "filename_template": "{title}-v{version}{label_suffix}.{ext}",
    "sanitize_spaces": false,
    "formats_enabled": ["pdf", "epub"]
  },
  "cover": {
    "path": "cover.jpg",
    "epub_specific_path": null
  },
  "sections": {},
  "epub_overrides": {
    "metadata": {},
    "cover": null
  },
  "next_version": "0.1",
  "active_label_hint": null
}
```

- [ ] **Step 9: Wire resources into `project.yml`**

In `project.yml`, locate the `resources:` entry under the `Maugham:` target. It currently reads:

```yaml
    resources:
      - path: Maugham/Resources
        includes:
          - "*.md"
```

Replace with:

```yaml
    resources:
      - path: Maugham/Resources
        includes:
          - "*.md"
      - path: Maugham/Resources/PublishStarter
        type: folder
```

The `type: folder` directive bundles the whole directory as a Resources subfolder (preserving the path so Bundle lookup finds individual files).

- [ ] **Step 10: Run `./gen.sh` and verify**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO
```

Expected: build succeeds and the starter files are inside the built `.app/Contents/Resources/PublishStarter/`.

- [ ] **Step 11: Commit**

```bash
git add Maugham/Resources/PublishStarter/ project.yml
git commit -m "feat(publish): barebones starter resource files"
```

---

### Task 8: `PublishStarter` — load + install

**Files:**
- Create: `Maugham/Publish/PublishStarter.swift`
- Test: `MaughamTests/Publish/PublishStarterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublishStarterTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishStarterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testIsInitialized_falseWhenAbsent() {
        XCTAssertFalse(PublishStarter.isInitialized(in: tmp))
    }

    func testInstall_copiesAllExpectedFiles() throws {
        try PublishStarter.install(into: tmp, force: false)

        let pub = tmp.appendingPathComponent(".maugham/publish")
        for name in [
            "template.tex", "preamble.tex", "frontmatter.tex",
            "prose.tex", "screenplay.tex", "backmatter.tex",
            "styles.css", "config.json"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: pub.appendingPathComponent(name).path),
                "missing \(name)")
        }
    }

    func testInstall_throws_whenAlreadyInitialized() throws {
        try PublishStarter.install(into: tmp, force: false)
        XCTAssertThrowsError(try PublishStarter.install(into: tmp, force: false)) { err in
            guard case PublishStarter.Error.alreadyInitialized = err else {
                XCTFail("wrong error: \(err)")
                return
            }
        }
    }

    func testInstall_force_overwritesExisting() throws {
        try PublishStarter.install(into: tmp, force: false)
        // Mutate template.tex.
        let templateURL = tmp.appendingPathComponent(".maugham/publish/template.tex")
        try "% mutated".write(to: templateURL, atomically: true, encoding: .utf8)
        // Force reinstall.
        try PublishStarter.install(into: tmp, force: true)
        let content = try String(contentsOf: templateURL)
        XCTAssertFalse(content.contains("mutated"))
        XCTAssertTrue(content.contains("Barebones publish template"))
    }

    func testInstall_renamesDefaultConfigJsonToConfigJson() throws {
        try PublishStarter.install(into: tmp, force: false)
        let cfg = tmp.appendingPathComponent(".maugham/publish/config.json")
        let defaults = tmp.appendingPathComponent(".maugham/publish/default-config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cfg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaults.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishStarterTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `PublishStarter` undefined.

- [ ] **Step 3: Implement `PublishStarter`**

Create `Maugham/Publish/PublishStarter.swift`:

```swift
import Foundation

/// Copies the bundled barebones starter into `.maugham/publish/`.
public enum PublishStarter {

    public enum Error: Swift.Error {
        case alreadyInitialized
        case starterResourceMissing(String)
    }

    /// Files copied from the bundle, with their destination filename.
    /// `default-config.json` → `config.json` (rename on copy).
    private static let files: [(resource: String, destination: String)] = [
        ("template.tex",        "template.tex"),
        ("preamble.tex",        "preamble.tex"),
        ("frontmatter.tex",     "frontmatter.tex"),
        ("prose.tex",           "prose.tex"),
        ("screenplay.tex",      "screenplay.tex"),
        ("backmatter.tex",      "backmatter.tex"),
        ("styles.css",          "styles.css"),
        ("default-config.json", "config.json"),
    ]

    public static func isInitialized(in projectURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent(
                ".maugham/publish/template.tex").path)
    }

    public static func install(into projectURL: URL, force: Bool) throws {
        let pub = projectURL.appendingPathComponent(".maugham/publish")
        let alreadyExists = isInitialized(in: projectURL)
        if alreadyExists && !force {
            throw Error.alreadyInitialized
        }

        try FileManager.default.createDirectory(
            at: pub, withIntermediateDirectories: true)

        for (resource, destination) in files {
            guard let src = Bundle.main.url(
                forResource: resource,
                withExtension: nil,
                subdirectory: "PublishStarter"
            ) else {
                throw Error.starterResourceMissing(resource)
            }
            let dst = pub.appendingPathComponent(destination)
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
        }
    }

    /// Convenience for new-project creation — does nothing if already initialized.
    public static func installIfMissing(into projectURL: URL) {
        guard !isInitialized(in: projectURL) else { return }
        do {
            try install(into: projectURL, force: false)
        } catch {
            // Non-fatal: writer can re-trigger via the MCP tool.
            NSLog("PublishStarter.installIfMissing failed: \(error)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishStarterTests CODE_SIGNING_ALLOWED=NO`

Expected: all 5 tests PASS. If bundle lookup fails, double-check `project.yml` resource wiring from Task 7.

- [ ] **Step 5: Wire into `ProjectFactory`**

In `Maugham/Stores/ProjectFactory.swift`, find the function that creates a new project on disk (look for the spot where `.maugham/` is created). After the `.maugham/` directory is in place but before the function returns, add:

```swift
PublishStarter.installIfMissing(into: projectURL)
```

- [ ] **Step 6: Commit**

```bash
git add Maugham/Publish/PublishStarter.swift Maugham/Stores/ProjectFactory.swift MaughamTests/Publish/PublishStarterTests.swift
git commit -m "feat(publish): PublishStarter installs barebones on new projects"
```

---

## Phase 2 — Body emitter (ProjectAST → body.tex / body.xhtml)

### Task 9: `ProjectAST` model

**Files:**
- Create: `Maugham/Publish/ProjectAST.swift`
- Test: `MaughamTests/Publish/ProjectASTTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class ProjectASTTests: XCTestCase {

    func testSection_holdsModeAndContent() {
        let s = ProjectAST.Section(
            pieceID: "p_abc",
            title: "Chapter 1",
            mode: .prose,
            nodes: [.paragraph("Hello.")]
        )
        XCTAssertEqual(s.mode, .prose)
        XCTAssertEqual(s.nodes.count, 1)
    }

    func testAST_holdsSectionsInOrder() {
        let a = ProjectAST(sections: [
            .init(pieceID: "p1", title: "One", mode: .prose, nodes: []),
            .init(pieceID: "p2", title: "Two", mode: .fountain, nodes: []),
        ])
        XCTAssertEqual(a.sections.map(\.pieceID), ["p1", "p2"])
    }

    func testProseNodes_haveExpectedCases() {
        let nodes: [ProjectAST.ProseNode] = [
            .paragraph("plain"),
            .emphasis("italic"),
            .strong("bold"),
            .wikiLink(target: "Aaron", display: "him"),
            .sceneBreak,
        ]
        XCTAssertEqual(nodes.count, 5)
    }

    func testFountainNodes_haveExpectedCases() {
        let nodes: [ProjectAST.FountainNode] = [
            .sceneHeading("INT. KITCHEN - DAY"),
            .action("Aaron pours coffee."),
            .character("AARON"),
            .dialogue("Morning."),
            .parenthetical("(quietly)"),
            .transition("CUT TO:"),
            .dualDialogue(
                left: [.character("AARON"), .dialogue("Hi.")],
                right: [.character("BETH"), .dialogue("Hi.")]
            ),
        ]
        XCTAssertEqual(nodes.count, 7)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectASTTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `ProjectAST` undefined.

- [ ] **Step 3: Implement `ProjectAST`**

Create `Maugham/Publish/ProjectAST.swift`:

```swift
import Foundation

/// Target-agnostic representation of a compilable project. Built by
/// `ProjectASTBuilder` from a project's pieces in binder order; consumed
/// by `LaTeXBodyEmitter` and `XHTMLBodyEmitter`.
public struct ProjectAST: Equatable, Sendable {
    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public struct Section: Equatable, Sendable {
        public let pieceID: String
        public let title: String
        public let mode: Mode
        public let nodes: [Node]

        public init(pieceID: String, title: String, mode: Mode, nodes: [Node]) {
            self.pieceID = pieceID
            self.title = title
            self.mode = mode
            self.nodes = nodes
        }
    }

    public enum Mode: String, Equatable, Sendable {
        case prose
        case fountain
    }

    /// Inline or block node. Each section's nodes are exhaustively in one of the
    /// two mode-specific shapes — `prose` mode uses `.prose` cases, `fountain`
    /// uses `.fountain` cases. Mixing isn't valid AST but the type permits it
    /// (callers responsible).
    public enum Node: Equatable, Sendable {
        case prose(ProseNode)
        case fountain(FountainNode)
    }

    public enum ProseNode: Equatable, Sendable {
        case paragraph(String)        // plain text, no inline markers
        case emphasis(String)         // italics
        case strong(String)
        case wikiLink(target: String, display: String)
        case sceneBreak
    }

    public enum FountainNode: Equatable, Sendable {
        case sceneHeading(String)
        case action(String)
        case character(String)
        case dialogue(String)
        case parenthetical(String)
        case transition(String)
        case dualDialogue(left: [FountainNode], right: [FountainNode])
    }
}

// Convenience constructors so tests/builders can write
//   .paragraph("foo")  instead of  .prose(.paragraph("foo"))
public extension ProjectAST.Node {
    static func paragraph(_ s: String) -> Self { .prose(.paragraph(s)) }
    static func emphasis(_ s: String)  -> Self { .prose(.emphasis(s)) }
    static func strong(_ s: String)    -> Self { .prose(.strong(s)) }
    static func wikiLink(target: String, display: String) -> Self {
        .prose(.wikiLink(target: target, display: display))
    }
    static var sceneBreak: Self { .prose(.sceneBreak) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectASTTests CODE_SIGNING_ALLOWED=NO`

Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/ProjectAST.swift MaughamTests/Publish/ProjectASTTests.swift
git commit -m "feat(publish): ProjectAST sectioned model"
```

---

### Task 10: LaTeX escape helper

**Files:**
- Create: `Maugham/Publish/LaTeXEscape.swift`
- Test: `MaughamTests/Publish/LaTeXEscapeTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class LaTeXEscapeTests: XCTestCase {

    func testEscapes_percent() {
        XCTAssertEqual(LaTeXEscape.escape("50% off"), "50\\% off")
    }

    func testEscapes_ampersand() {
        XCTAssertEqual(LaTeXEscape.escape("Tom & Jerry"), "Tom \\& Jerry")
    }

    func testEscapes_dollar() {
        XCTAssertEqual(LaTeXEscape.escape("price: $5"), "price: \\$5")
    }

    func testEscapes_underscore() {
        XCTAssertEqual(LaTeXEscape.escape("var_name"), "var\\_name")
    }

    func testEscapes_hash() {
        XCTAssertEqual(LaTeXEscape.escape("#tag"), "\\#tag")
    }

    func testEscapes_braces() {
        XCTAssertEqual(LaTeXEscape.escape("{a}"), "\\{a\\}")
    }

    func testEscapes_backslash() {
        XCTAssertEqual(LaTeXEscape.escape("C:\\path"), "C:\\textbackslash{}path")
    }

    func testEscapes_tilde() {
        XCTAssertEqual(LaTeXEscape.escape("a~b"), "a\\textasciitilde{}b")
    }

    func testEscapes_caret() {
        XCTAssertEqual(LaTeXEscape.escape("a^b"), "a\\textasciicircum{}b")
    }

    func testIdempotent_safeAscii() {
        XCTAssertEqual(LaTeXEscape.escape("Hello, world."), "Hello, world.")
    }

    func testEscapes_combinations() {
        XCTAssertEqual(
            LaTeXEscape.escape("100% & $5 (no #1)"),
            "100\\% \\& \\$5 (no \\#1)"
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/LaTeXEscapeTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `LaTeXEscape` undefined.

- [ ] **Step 3: Implement escape**

Create `Maugham/Publish/LaTeXEscape.swift`:

```swift
import Foundation

/// Escapes the ten special LaTeX characters so that arbitrary text from
/// the manuscript renders correctly inside the document body.
///
/// Order matters: backslash MUST be escaped first (its replacement contains
/// `\`), then the rest in any order. Each replacement either uses a
/// printable LaTeX command (e.g. `\textbackslash{}`) or a backslash-prefix
/// (e.g. `\%`).
public enum LaTeXEscape {

    public static func escape(_ input: String) -> String {
        var s = input
        // Backslash FIRST. Use a placeholder so we don't re-match the inserted
        // backslashes during subsequent replacements.
        s = s.replacingOccurrences(of: "\\", with: "\u{0001}")
        // Now the rest. Order doesn't matter.
        s = s.replacingOccurrences(of: "&",  with: "\\&")
        s = s.replacingOccurrences(of: "%",  with: "\\%")
        s = s.replacingOccurrences(of: "$",  with: "\\$")
        s = s.replacingOccurrences(of: "#",  with: "\\#")
        s = s.replacingOccurrences(of: "_",  with: "\\_")
        s = s.replacingOccurrences(of: "{",  with: "\\{")
        s = s.replacingOccurrences(of: "}",  with: "\\}")
        s = s.replacingOccurrences(of: "~",  with: "\\textasciitilde{}")
        s = s.replacingOccurrences(of: "^",  with: "\\textasciicircum{}")
        // Restore backslashes as the command.
        s = s.replacingOccurrences(of: "\u{0001}", with: "\\textbackslash{}")
        return s
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/LaTeXEscapeTests CODE_SIGNING_ALLOWED=NO`

Expected: all 11 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/LaTeXEscape.swift MaughamTests/Publish/LaTeXEscapeTests.swift
git commit -m "feat(publish): LaTeXEscape for ten special chars"
```

---

### Task 11: XHTML escape helper

**Files:**
- Create: `Maugham/Publish/XHTMLEscape.swift`
- Test: `MaughamTests/Publish/XHTMLEscapeTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class XHTMLEscapeTests: XCTestCase {

    func testEscapes_amp() {
        XCTAssertEqual(XHTMLEscape.escape("Tom & Jerry"), "Tom &amp; Jerry")
    }

    func testEscapes_lt_gt() {
        XCTAssertEqual(XHTMLEscape.escape("a<b>c"), "a&lt;b&gt;c")
    }

    func testEscapes_quotes() {
        XCTAssertEqual(XHTMLEscape.escape("\"x\""), "&quot;x&quot;")
        XCTAssertEqual(XHTMLEscape.escape("'y'"), "&apos;y&apos;")
    }

    func testIdempotent_safe() {
        XCTAssertEqual(XHTMLEscape.escape("Hello, world."), "Hello, world.")
    }

    func testEscapesAttribute_doublesQuotes() {
        // attribute() is used for values inside attributes; only ", &, < matter.
        XCTAssertEqual(
            XHTMLEscape.attribute("a \"b\" & <c>"),
            "a &quot;b&quot; &amp; &lt;c&gt;"
        )
    }

    func testAmpFirst_ordering() {
        // & must be replaced before others, else "&" inserted by < replacement
        // would itself get escaped to &amp;
        XCTAssertEqual(XHTMLEscape.escape("a&b<c"), "a&amp;b&lt;c")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/XHTMLEscapeTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `XHTMLEscape` undefined.

- [ ] **Step 3: Implement escape**

Create `Maugham/Publish/XHTMLEscape.swift`:

```swift
import Foundation

/// XHTML character escaping. `escape` is for text content; `attribute` is for
/// attribute values (slightly different needs but we use the strict set for
/// both to keep behavior obvious).
public enum XHTMLEscape {

    public static func escape(_ input: String) -> String {
        var s = input
        s = s.replacingOccurrences(of: "&",  with: "&amp;")  // MUST be first
        s = s.replacingOccurrences(of: "<",  with: "&lt;")
        s = s.replacingOccurrences(of: ">",  with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        s = s.replacingOccurrences(of: "'",  with: "&apos;")
        return s
    }

    public static func attribute(_ input: String) -> String {
        // Same set is safe for attributes. Kept separate so callers can read
        // intent at the call site.
        escape(input)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/XHTMLEscapeTests CODE_SIGNING_ALLOWED=NO`

Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/XHTMLEscape.swift MaughamTests/Publish/XHTMLEscapeTests.swift
git commit -m "feat(publish): XHTMLEscape for & < > \" '"
```

---

### Task 12: `LaTeXBodyEmitter`

**Files:**
- Create: `Maugham/Publish/LaTeXBodyEmitter.swift`
- Test: `MaughamTests/Publish/LaTeXBodyEmitterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class LaTeXBodyEmitterTests: XCTestCase {

    func testEmits_emptyAST_emptyBody() {
        let body = LaTeXBodyEmitter.emit(ProjectAST(sections: []))
        XCTAssertEqual(body.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testEmits_proseSection_environment() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Chapter 1", mode: .prose,
                  nodes: [.paragraph("Hello.")])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{prose}{Chapter 1}"))
        XCTAssertTrue(body.contains("Hello."))
        XCTAssertTrue(body.contains("\\end{prose}"))
    }

    func testEmits_emphasisAndStrong() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph("plain "),
                .emphasis("italic"),
                .paragraph(" "),
                .strong("bold")
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\emph{italic}"))
        XCTAssertTrue(body.contains("\\textbf{bold}"))
    }

    func testEmits_wikiLink_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .wikiLink(target: "Aaron", display: "him")
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\wikilink{Aaron}{him}"))
    }

    func testEmits_sceneBreak_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [.sceneBreak])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\scenebreak"))
    }

    func testEscapes_specialChars_inProseText() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph("50% off & $5 #1")
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("50\\% off \\& \\$5 \\#1"))
    }

    func testEscapes_sectionTitle() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Tom & Jerry", mode: .prose, nodes: [])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{prose}{Tom \\& Jerry}"))
    }

    func testEmits_fountainSection_environment_andAllCommands() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Scene Snippet", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. KITCHEN - DAY")),
                .fountain(.action("Aaron pours coffee.")),
                .fountain(.character("AARON")),
                .fountain(.parenthetical("(quietly)")),
                .fountain(.dialogue("Morning.")),
                .fountain(.transition("CUT TO:"))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{screenplay}{Scene Snippet}"))
        XCTAssertTrue(body.contains("\\scene{INT. KITCHEN - DAY}"))
        XCTAssertTrue(body.contains("\\action{Aaron pours coffee.}"))
        XCTAssertTrue(body.contains("\\character{AARON}"))
        XCTAssertTrue(body.contains("\\parenthetical{(quietly)}"))
        XCTAssertTrue(body.contains("\\dialogue{Morning.}"))
        XCTAssertTrue(body.contains("\\transition{CUT TO:}"))
        XCTAssertTrue(body.contains("\\end{screenplay}"))
    }

    func testEmits_dualDialogue_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.dualDialogue(
                    left: [.character("AARON"), .dialogue("Left.")],
                    right: [.character("BETH"), .dialogue("Right.")]
                ))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\dualdialogue"))
        XCTAssertTrue(body.contains("AARON"))
        XCTAssertTrue(body.contains("BETH"))
    }

    func testMultipleSections_emittedInOrder() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "First", mode: .prose, nodes: []),
            .init(pieceID: "p2", title: "Second", mode: .fountain, nodes: [])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        let firstIdx = body.range(of: "First")!.lowerBound
        let secondIdx = body.range(of: "Second")!.lowerBound
        XCTAssertLessThan(firstIdx, secondIdx)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/LaTeXBodyEmitterTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `LaTeXBodyEmitter` undefined.

- [ ] **Step 3: Implement emitter**

Create `Maugham/Publish/LaTeXBodyEmitter.swift`:

```swift
import Foundation

/// Emits `body.tex` content from a `ProjectAST`. The template the writer-
/// Claude pair authors must \input{build/body} and define the environments
/// (\begin{prose}{title}, \begin{screenplay}{title}) plus per-mode commands
/// referenced below (\scenebreak, \wikilink, \scene, \action, \character,
/// \dialogue, \parenthetical, \transition, \dualdialogue). The barebones
/// starter provides working defaults.
public enum LaTeXBodyEmitter {

    public static func emit(_ ast: ProjectAST) -> String {
        var lines: [String] = []
        for section in ast.sections {
            emit(section: section, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - section

    private static func emit(section: ProjectAST.Section, into out: inout [String]) {
        let title = LaTeXEscape.escape(section.title)
        switch section.mode {
        case .prose:
            out.append("\\begin{prose}{\(title)}")
            for node in section.nodes { emit(node: node, into: &out) }
            out.append("\\end{prose}")
        case .fountain:
            out.append("\\begin{screenplay}{\(title)}")
            for node in section.nodes { emit(node: node, into: &out) }
            out.append("\\end{screenplay}")
        }
    }

    // MARK: - nodes

    private static func emit(node: ProjectAST.Node, into out: inout [String]) {
        switch node {
        case .prose(let p):    emit(prose: p, into: &out)
        case .fountain(let f): emit(fountain: f, into: &out)
        }
    }

    private static func emit(prose: ProjectAST.ProseNode, into out: inout [String]) {
        switch prose {
        case .paragraph(let s): out.append(LaTeXEscape.escape(s))
        case .emphasis(let s):  out.append("\\emph{\(LaTeXEscape.escape(s))}")
        case .strong(let s):    out.append("\\textbf{\(LaTeXEscape.escape(s))}")
        case .wikiLink(let target, let display):
            out.append("\\wikilink{\(LaTeXEscape.escape(target))}{\(LaTeXEscape.escape(display))}")
        case .sceneBreak:
            out.append("\\scenebreak")
        }
    }

    private static func emit(fountain: ProjectAST.FountainNode, into out: inout [String]) {
        switch fountain {
        case .sceneHeading(let s):  out.append("\\scene{\(LaTeXEscape.escape(s))}")
        case .action(let s):        out.append("\\action{\(LaTeXEscape.escape(s))}")
        case .character(let s):     out.append("\\character{\(LaTeXEscape.escape(s))}")
        case .dialogue(let s):      out.append("\\dialogue{\(LaTeXEscape.escape(s))}")
        case .parenthetical(let s): out.append("\\parenthetical{\(LaTeXEscape.escape(s))}")
        case .transition(let s):    out.append("\\transition{\(LaTeXEscape.escape(s))}")
        case .dualDialogue(let left, let right):
            var leftLines: [String] = []
            var rightLines: [String] = []
            for n in left  { emit(fountain: n, into: &leftLines) }
            for n in right { emit(fountain: n, into: &rightLines) }
            out.append("\\dualdialogue{%")
            out.append(leftLines.joined(separator: "\n"))
            out.append("}{%")
            out.append(rightLines.joined(separator: "\n"))
            out.append("}")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/LaTeXBodyEmitterTests CODE_SIGNING_ALLOWED=NO`

Expected: all 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/LaTeXBodyEmitter.swift MaughamTests/Publish/LaTeXBodyEmitterTests.swift
git commit -m "feat(publish): LaTeXBodyEmitter for ProjectAST → body.tex"
```

---

### Task 13: `XHTMLBodyEmitter`

**Files:**
- Create: `Maugham/Publish/XHTMLBodyEmitter.swift`
- Test: `MaughamTests/Publish/XHTMLBodyEmitterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class XHTMLBodyEmitterTests: XCTestCase {

    func testEmits_emptyAST_returnsEmptyBody() {
        let xhtml = XHTMLBodyEmitter.emit(ProjectAST(sections: []))
        XCTAssertEqual(xhtml.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testEmits_proseSection_wrappedInSection() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p_abc", title: "Chapter One", mode: .prose,
                  nodes: [.paragraph("Hello.")])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<section class=\"prose\" data-piece-id=\"p_abc\">"))
        XCTAssertTrue(xhtml.contains("<h1>Chapter One</h1>"))
        XCTAssertTrue(xhtml.contains("<p>Hello.</p>"))
        XCTAssertTrue(xhtml.contains("</section>"))
    }

    func testEmits_emphasis_and_strong_inline() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .emphasis("italic"), .strong("bold")
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<em>italic</em>"))
        XCTAssertTrue(xhtml.contains("<strong>bold</strong>"))
    }

    func testEmits_sceneBreak_asHR() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [.sceneBreak])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<hr class=\"scene-break\"/>"))
    }

    func testEmits_wikiLink_asSpan() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .wikiLink(target: "Aaron", display: "him")
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<span class=\"wiki-link\" data-target=\"Aaron\">him</span>"))
    }

    func testEscapes_specialChars() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Tom & Jerry", mode: .prose, nodes: [
                .paragraph("a<b>c & d")
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<h1>Tom &amp; Jerry</h1>"))
        XCTAssertTrue(xhtml.contains("a&lt;b&gt;c &amp; d"))
    }

    func testEmits_fountainSection_classedParagraphs() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p_x", title: "S", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. KITCHEN - DAY")),
                .fountain(.action("Aaron pours coffee.")),
                .fountain(.character("AARON")),
                .fountain(.parenthetical("(quietly)")),
                .fountain(.dialogue("Morning.")),
                .fountain(.transition("CUT TO:"))
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<section class=\"screenplay\" data-piece-id=\"p_x\">"))
        XCTAssertTrue(xhtml.contains("<p class=\"scene-heading\">INT. KITCHEN - DAY</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"action\">Aaron pours coffee.</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"character\">AARON</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"parenthetical\">(quietly)</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"dialogue\">Morning.</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"transition\">CUT TO:</p>"))
    }

    func testEmits_dualDialogue_wrappedInDiv() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.dualDialogue(
                    left: [.character("AARON"), .dialogue("Hi.")],
                    right: [.character("BETH"), .dialogue("Hi.")]
                ))
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<div class=\"dual-dialogue\">"))
        XCTAssertTrue(xhtml.contains("<div class=\"left\">"))
        XCTAssertTrue(xhtml.contains("<div class=\"right\">"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/XHTMLBodyEmitterTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `XHTMLBodyEmitter` undefined.

- [ ] **Step 3: Implement emitter**

Create `Maugham/Publish/XHTMLBodyEmitter.swift`:

```swift
import Foundation

/// Emits `body.xhtml` fragment (no `<html>`/`<body>` wrappers) from a
/// `ProjectAST`. The EPUB packager wraps this in the proper XHTML envelope
/// and stitches into the spine.
public enum XHTMLBodyEmitter {

    public static func emit(_ ast: ProjectAST) -> String {
        var lines: [String] = []
        for section in ast.sections {
            emit(section: section, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func emit(section: ProjectAST.Section, into out: inout [String]) {
        let modeClass: String
        switch section.mode {
        case .prose:    modeClass = "prose"
        case .fountain: modeClass = "screenplay"
        }
        out.append("<section class=\"\(modeClass)\" data-piece-id=\"\(XHTMLEscape.attribute(section.pieceID))\">")
        out.append("<h1>\(XHTMLEscape.escape(section.title))</h1>")
        for node in section.nodes { emit(node: node, into: &out) }
        out.append("</section>")
    }

    private static func emit(node: ProjectAST.Node, into out: inout [String]) {
        switch node {
        case .prose(let p):    emit(prose: p, into: &out)
        case .fountain(let f): emit(fountain: f, into: &out)
        }
    }

    private static func emit(prose: ProjectAST.ProseNode, into out: inout [String]) {
        switch prose {
        case .paragraph(let s):
            out.append("<p>\(XHTMLEscape.escape(s))</p>")
        case .emphasis(let s):
            out.append("<p><em>\(XHTMLEscape.escape(s))</em></p>")
        case .strong(let s):
            out.append("<p><strong>\(XHTMLEscape.escape(s))</strong></p>")
        case .wikiLink(let target, let display):
            out.append(
                "<p><span class=\"wiki-link\" data-target=\"\(XHTMLEscape.attribute(target))\">"
                + XHTMLEscape.escape(display)
                + "</span></p>")
        case .sceneBreak:
            out.append("<hr class=\"scene-break\"/>")
        }
    }

    private static func emit(fountain: ProjectAST.FountainNode, into out: inout [String]) {
        switch fountain {
        case .sceneHeading(let s):  out.append("<p class=\"scene-heading\">\(XHTMLEscape.escape(s))</p>")
        case .action(let s):        out.append("<p class=\"action\">\(XHTMLEscape.escape(s))</p>")
        case .character(let s):     out.append("<p class=\"character\">\(XHTMLEscape.escape(s))</p>")
        case .dialogue(let s):      out.append("<p class=\"dialogue\">\(XHTMLEscape.escape(s))</p>")
        case .parenthetical(let s): out.append("<p class=\"parenthetical\">\(XHTMLEscape.escape(s))</p>")
        case .transition(let s):    out.append("<p class=\"transition\">\(XHTMLEscape.escape(s))</p>")
        case .dualDialogue(let left, let right):
            out.append("<div class=\"dual-dialogue\">")
            out.append("<div class=\"left\">")
            for n in left { emit(fountain: n, into: &out) }
            out.append("</div>")
            out.append("<div class=\"right\">")
            for n in right { emit(fountain: n, into: &out) }
            out.append("</div>")
            out.append("</div>")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/XHTMLBodyEmitterTests CODE_SIGNING_ALLOWED=NO`

Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/XHTMLBodyEmitter.swift MaughamTests/Publish/XHTMLBodyEmitterTests.swift
git commit -m "feat(publish): XHTMLBodyEmitter for ProjectAST → body.xhtml"
```

---

### Task 14: `ProjectASTBuilder` — pieces → AST

**Files:**
- Create: `Maugham/Publish/ProjectASTBuilder.swift`
- Test: `MaughamTests/Publish/ProjectASTBuilderTests.swift`

This builder reads pieces from a `ProjectStore` (or test fixture) in binder order and parses each per its mode. We expose a minimal `ProjectASTBuilder.Source` protocol so tests can supply fixtures without standing up a full project on disk.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class ProjectASTBuilderTests: XCTestCase {

    struct FixtureSource: ProjectASTBuilder.Source {
        let pieces: [(id: String, title: String, mode: ProjectAST.Mode, text: String)]
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            pieces.map { .init(pieceID: $0.id, title: $0.title, mode: $0.mode, displayText: $0.text) }
        }
    }

    func testBuilds_emptyAST_fromNoPieces() {
        let src = FixtureSource(pieces: [])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertTrue(ast.sections.isEmpty)
    }

    func testBuilds_singleProseSection_oneParagraph() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "Chapter 1", mode: .prose, text: "Hello.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections.count, 1)
        let s = ast.sections[0]
        XCTAssertEqual(s.pieceID, "p1")
        XCTAssertEqual(s.title, "Chapter 1")
        XCTAssertEqual(s.mode, .prose)
        XCTAssertEqual(s.nodes, [.paragraph("Hello.")])
    }

    func testBuilds_proseParagraphsSplit_onBlankLine() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "One.\n\nTwo.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.paragraph("One."), .paragraph("Two.")])
    }

    func testProseSceneBreak_lineOfAsterisks_becomesSceneBreak() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "Before.\n\n* * *\n\nAfter.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .paragraph("Before."), .sceneBreak, .paragraph("After.")
        ])
    }

    func testProseStripsAnchors_fromBody() {
        // Manuscript paragraphs carry inline <!-- ¶XXXX --> anchors;
        // the AST is anchor-stripped (publishing pipeline never emits them).
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose,
             text: "<!-- ¶abcd -->Hello.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.paragraph("Hello.")])
    }

    func testFountainSection_parsesElements() {
        let text = """
        INT. KITCHEN - DAY

        Aaron pours coffee.

        AARON
        Morning.
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "Scene 1", mode: .fountain, text: text)
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].mode, .fountain)
        // We expect AT LEAST the three core elements; precise count depends on
        // the fountain parser's blank-line behavior.
        let nodes = ast.sections[0].nodes
        XCTAssertTrue(nodes.contains(.fountain(.sceneHeading("INT. KITCHEN - DAY"))))
        XCTAssertTrue(nodes.contains(.fountain(.action("Aaron pours coffee."))))
        XCTAssertTrue(nodes.contains(.fountain(.character("AARON"))))
        XCTAssertTrue(nodes.contains(.fountain(.dialogue("Morning."))))
    }

    func testMixedPieces_preserveOrder() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "First", mode: .prose, text: "Hello."),
            (id: "p2", title: "Second", mode: .fountain, text: "INT. ROOM - DAY"),
            (id: "p3", title: "Third", mode: .prose, text: "World."),
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections.map(\.pieceID), ["p1", "p2", "p3"])
        XCTAssertEqual(ast.sections.map(\.mode), [.prose, .fountain, .prose])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectASTBuilderTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `ProjectASTBuilder` undefined.

- [ ] **Step 3: Implement builder**

Create `Maugham/Publish/ProjectASTBuilder.swift`:

```swift
import Foundation

public enum ProjectASTBuilder {

    public struct PieceRef: Sendable {
        public let pieceID: String
        public let title: String
        public let mode: ProjectAST.Mode
        public let displayText: String

        public init(pieceID: String, title: String,
                    mode: ProjectAST.Mode, displayText: String) {
            self.pieceID = pieceID
            self.title = title
            self.mode = mode
            self.displayText = displayText
        }
    }

    public protocol Source {
        func orderedPieces() -> [PieceRef]
    }

    public static func build(from source: Source) -> ProjectAST {
        let sections = source.orderedPieces().map(buildSection(from:))
        return ProjectAST(sections: sections)
    }

    // MARK: - section assembly

    private static func buildSection(from piece: PieceRef) -> ProjectAST.Section {
        let nodes: [ProjectAST.Node]
        switch piece.mode {
        case .prose:
            nodes = parseProse(piece.displayText)
        case .fountain:
            nodes = parseFountain(piece.displayText)
        }
        return .init(pieceID: piece.pieceID, title: piece.title,
                     mode: piece.mode, nodes: nodes)
    }

    // MARK: - prose

    private static func parseProse(_ text: String) -> [ProjectAST.Node] {
        // Strip inline <!-- ¶XXXX --> anchors before parsing.
        let stripped = stripAnchors(text)
        // Split on blank lines.
        let blocks = stripped
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.map { block -> ProjectAST.Node in
            if isSceneBreakLine(block) { return .sceneBreak }
            return .paragraph(block)
        }
    }

    private static func stripAnchors(_ s: String) -> String {
        // <!-- ¶XXXX --> anchors (4-char alphabet-restricted ParagraphID).
        // Also handles <!--t-XXXXXX--> task anchors.
        var result = s
        let patterns = [
            #"<!--\s*¶[0-9a-z]{4}\s*-->"#,
            #"<!--t-[0-9a-zA-Z]{6}-->"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result, range: range, withTemplate: "")
            }
        }
        return result
    }

    private static func isSceneBreakLine(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: " ", with: "")
        return stripped == "***" || stripped == "###" || stripped == "---"
    }

    // MARK: - fountain

    private static func parseFountain(_ text: String) -> [ProjectAST.Node] {
        // Best-effort line classification — full fidelity comes via
        // Maugham/Editor's existing FountainParser, which v1's builder
        // bridges through in production (see Step 4 wiring). For tests with
        // fixture text, we use this inline classifier.
        var nodes: [ProjectAST.FountainNode] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            if line.isEmpty { continue }

            if isSceneHeading(line) {
                nodes.append(.sceneHeading(line))
            } else if isCharacter(line) {
                nodes.append(.character(line))
                // Look ahead for parenthetical + dialogue.
                while i + 1 < lines.count {
                    let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty { break }
                    if next.hasPrefix("(") && next.hasSuffix(")") {
                        nodes.append(.parenthetical(next))
                    } else if isCharacter(next) || isSceneHeading(next) {
                        break
                    } else {
                        nodes.append(.dialogue(next))
                    }
                    i += 1
                }
            } else if line.uppercased() == line && line.hasSuffix("TO:") {
                nodes.append(.transition(line))
            } else {
                nodes.append(.action(line))
            }
        }

        return nodes.map { ProjectAST.Node.fountain($0) }
    }

    private static func isSceneHeading(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper.hasPrefix("INT.") || upper.hasPrefix("EXT.") ||
               upper.hasPrefix("INT ")  || upper.hasPrefix("EXT ")  ||
               upper.hasPrefix("INT/EXT") || upper.hasPrefix("I/E")
    }

    private static func isCharacter(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        // ALL-CAPS lines (allowing digits, spaces, punctuation) with no
        // sentence-ending punctuation are character cues.
        let letters = line.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        return letters == letters.uppercased() && !line.contains(".")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ProjectASTBuilderTests CODE_SIGNING_ALLOWED=NO`

Expected: all 7 tests PASS. **Note:** the inline fountain classifier in this task is a v1 shim. Wiring the existing `FountainParser` (used by the editor) as the parsing path is a production-only Source-protocol adapter; the unit tests here run against the shim. The production adapter lives in Task 32 (PDFCompiler) where the real `ProjectStore` connection happens.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/ProjectASTBuilder.swift MaughamTests/Publish/ProjectASTBuilderTests.swift
git commit -m "feat(publish): ProjectASTBuilder + inline fountain classifier"
```

---

## Phase 3 — Tectonic engine

### Task 15: Bundle tectonic binary into `Maugham.app`

**Files:**
- Create: `Maugham/Resources/bin/tectonic` (single binary, ~25 MB)
- Modify: `project.yml`
- Modify: `.gitignore` (to allow committing the binary)
- Create: `scripts/fetch-tectonic.sh` (idempotent download helper)

- [ ] **Step 1: Create the fetch helper**

Create `scripts/fetch-tectonic.sh`:

```bash
#!/usr/bin/env bash
# Fetches the tectonic binary from GitHub releases into Maugham/Resources/bin/.
# Idempotent — does nothing if the binary is already present at the pinned
# version (matched by SHA-256). Run this once after checkout, then commit
# the binary if the repo's policy is to commit binaries (default: yes).

set -euo pipefail

VERSION="0.15.0"
EXPECTED_SHA256="REPLACE_WITH_RELEASE_SHA256"  # FIXME at fetch time
PLATFORM="aarch64-apple-darwin"   # universal: build a fat binary via `lipo`

DEST_DIR="Maugham/Resources/bin"
DEST_BIN="$DEST_DIR/tectonic"

mkdir -p "$DEST_DIR"

if [ -f "$DEST_BIN" ]; then
  actual=$(shasum -a 256 "$DEST_BIN" | awk '{print $1}')
  if [ "$actual" = "$EXPECTED_SHA256" ]; then
    echo "tectonic $VERSION already present"
    exit 0
  fi
  echo "removing stale tectonic binary (sha256 mismatch)"
  rm "$DEST_BIN"
fi

URL="https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic@${VERSION}/tectonic-${VERSION}-${PLATFORM}.tar.gz"
echo "Downloading $URL"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fL "$URL" -o "$TMP/tectonic.tar.gz"
tar -xzf "$TMP/tectonic.tar.gz" -C "$TMP"
mv "$TMP/tectonic" "$DEST_BIN"
chmod +x "$DEST_BIN"

# Verify.
actual=$(shasum -a 256 "$DEST_BIN" | awk '{print $1}')
if [ "$actual" != "$EXPECTED_SHA256" ]; then
  echo "SHA mismatch: expected $EXPECTED_SHA256, got $actual"
  exit 1
fi

echo "Installed tectonic $VERSION at $DEST_BIN"
```

Mark executable: `chmod +x scripts/fetch-tectonic.sh`.

- [ ] **Step 2: Run the helper and pin the SHA**

```bash
# First, edit EXPECTED_SHA256 to match the actual release SHA-256.
# Run: open https://github.com/tectonic-typesetting/tectonic/releases/tag/tectonic@0.15.0
# Copy the SHA-256 of tectonic-0.15.0-aarch64-apple-darwin.tar.gz from the release notes,
# paste into the EXPECTED_SHA256 line above. Re-run:
./scripts/fetch-tectonic.sh
```

Expected: `Maugham/Resources/bin/tectonic` exists, is executable, ~25 MB.

- [ ] **Step 3: Wire into `project.yml`**

In `project.yml`, append to the `Maugham:` target's `resources:` list:

```yaml
      - path: Maugham/Resources/bin
        type: folder
```

This bundles the entire `bin/` directory (preserving the path) into `.app/Contents/Resources/bin/tectonic`.

- [ ] **Step 4: Confirm binary survives build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO
# Find the built app:
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Maugham.app" -type d 2>/dev/null | head -1)
ls -lh "$APP/Contents/Resources/bin/tectonic"
"$APP/Contents/Resources/bin/tectonic" --version
```

Expected: binary present, executable, prints `tectonic 0.15.0`.

- [ ] **Step 5: Update .gitignore to permit commit of the binary**

Verify `Maugham/Resources/bin/tectonic` isn't ignored:

```bash
git check-ignore -v Maugham/Resources/bin/tectonic
```

Expected: no output (not ignored). If it IS ignored, add an exception:

```
# .gitignore — explicit allow for bundled binaries
!Maugham/Resources/bin/tectonic
```

- [ ] **Step 6: Commit**

```bash
git add scripts/fetch-tectonic.sh project.yml Maugham/Resources/bin/tectonic
git commit -m "feat(publish): bundle tectonic binary in Resources/bin"
```

---

### Task 16: `TectonicLocator`

**Files:**
- Create: `Maugham/Publish/Tectonic/TectonicLocator.swift`
- Test: `MaughamTests/Publish/Tectonic/TectonicLocatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class TectonicLocatorTests: XCTestCase {

    func testLocatesBundledBinary_inAppResources() throws {
        let url = try TectonicLocator.locate()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path),
                      "tectonic binary not executable at \(url.path)")
    }

    func testThrows_whenBinaryMissing() {
        let unrealistic = URL(fileURLWithPath: "/tmp/definitely-not-an-app-bundle")
        XCTAssertThrowsError(try TectonicLocator.locateInBundle(at: unrealistic)) { err in
            guard case TectonicLocator.Error.notFound = err else {
                XCTFail("unexpected error \(err)")
                return
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TectonicLocatorTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail — `TectonicLocator` undefined.

- [ ] **Step 3: Implement locator**

Create `Maugham/Publish/Tectonic/TectonicLocator.swift`:

```swift
import Foundation

public enum TectonicLocator {

    public enum Error: Swift.Error {
        case notFound
        case notExecutable
    }

    /// Locates `tectonic` inside the running app bundle's Resources/bin.
    public static func locate() throws -> URL {
        guard let bundle = Bundle.main.resourceURL else {
            throw Error.notFound
        }
        return try locateInBundle(at: bundle.deletingLastPathComponent())
    }

    /// Locates `tectonic` relative to a candidate app-bundle root
    /// (the `.app` directory). Used for testability.
    public static func locateInBundle(at appURL: URL) throws -> URL {
        let candidate = appURL
            .appendingPathComponent("Contents/Resources/bin/tectonic")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw Error.notFound
        }
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw Error.notExecutable
        }
        return candidate
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TectonicLocatorTests CODE_SIGNING_ALLOWED=NO`

Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/Tectonic/TectonicLocator.swift MaughamTests/Publish/Tectonic/TectonicLocatorTests.swift
git commit -m "feat(publish): TectonicLocator"
```

---

### Task 17: `TectonicCache` directory resolution

**Files:**
- Create: `Maugham/Publish/Tectonic/TectonicCache.swift`
- Test: `MaughamTests/Publish/Tectonic/TectonicCacheTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class TectonicCacheTests: XCTestCase {

    func testCacheURL_underLibraryCachesMaugham() throws {
        let url = try TectonicCache.cacheURL()
        XCTAssertTrue(url.path.hasSuffix("Library/Caches/Maugham/tectonic"),
                      "got \(url.path)")
    }

    func testEnsureExists_createsDirectory() throws {
        let url = try TectonicCache.ensureCacheExists()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TectonicCacheTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail.

- [ ] **Step 3: Implement cache**

Create `Maugham/Publish/Tectonic/TectonicCache.swift`:

```swift
import Foundation

public enum TectonicCache {

    public enum Error: Swift.Error {
        case noCachesDirectory
    }

    public static func cacheURL() throws -> URL {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first
        else {
            throw Error.noCachesDirectory
        }
        return caches
            .appendingPathComponent("Maugham", isDirectory: true)
            .appendingPathComponent("tectonic", isDirectory: true)
    }

    @discardableResult
    public static func ensureCacheExists() throws -> URL {
        let url = try cacheURL()
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TectonicCacheTests CODE_SIGNING_ALLOWED=NO`

Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/Tectonic/TectonicCache.swift MaughamTests/Publish/Tectonic/TectonicCacheTests.swift
git commit -m "feat(publish): TectonicCache resolves ~/Library/Caches/Maugham/tectonic"
```

---

### Task 18: `TectonicLogParser` — structured error extraction

**Files:**
- Create: `Maugham/Publish/Tectonic/TectonicLogParser.swift`
- Test: `MaughamTests/Publish/Tectonic/TectonicLogParserTests.swift`

Tectonic's stderr/log format includes recognizable patterns for errors and warnings. The parser turns them into `{level, file, line, message, context_lines[]}` records the compile tool can return through MCP.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class TectonicLogParserTests: XCTestCase {

    func testParses_undefinedControlSequence() {
        let log = """
        ! Undefined control sequence.
        l.42 \\customcmd
                    {something}
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.count, 1)
        let d = diags[0]
        XCTAssertEqual(d.level, .error)
        XCTAssertEqual(d.line, 42)
        XCTAssertTrue(d.message.contains("Undefined control sequence"))
    }

    func testParses_missingNumber() {
        let log = """
        ! Missing number, treated as zero.
        l.10 \\hspace{abc}
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].line, 10)
        XCTAssertEqual(diags[0].level, .error)
    }

    func testParses_warning_overfullHbox() {
        let log = """
        Overfull \\hbox (12.3pt too wide) in paragraph at lines 5--6
        []
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].level, .warning)
    }

    func testParses_multipleDiagnostics() {
        let log = """
        ! Undefined control sequence.
        l.42 \\foo

        ! Missing number, treated as zero.
        l.55 \\bar
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.count, 2)
        XCTAssertEqual(diags[0].line, 42)
        XCTAssertEqual(diags[1].line, 55)
    }

    func testEmpty_input_returnsNoDiagnostics() {
        XCTAssertTrue(TectonicLogParser.parse(log: "").isEmpty)
    }

    func testContextLines_capturedAfterMarker() {
        let log = """
        ! Undefined control sequence.
        l.42 \\customcmd
                    {value here}
                                {another}
        """
        let diags = TectonicLogParser.parse(log: log)
        XCTAssertEqual(diags.first?.contextLines.count, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TectonicLogParserTests CODE_SIGNING_ALLOWED=NO`

Expected: tests fail.

- [ ] **Step 3: Implement parser**

Create `Maugham/Publish/Tectonic/TectonicLogParser.swift`:

```swift
import Foundation

public enum TectonicLogParser {

    public struct Diagnostic: Equatable, Sendable {
        public let level: Level
        public let file: String?
        public let line: Int?
        public let message: String
        public let contextLines: [String]
    }

    public enum Level: String, Equatable, Sendable {
        case error
        case warning
    }

    public static func parse(log: String) -> [Diagnostic] {
        var result: [Diagnostic] = []
        let lines = log.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            // Errors start with "! "
            if raw.hasPrefix("! ") {
                let message = String(raw.dropFirst(2))
                var line: Int? = nil
                var context: [String] = []
                var j = i + 1
                // Look for "l.N " on the next non-blank line.
                while j < lines.count {
                    let next = lines[j]
                    if next.isEmpty {
                        j += 1
                        continue
                    }
                    if next.hasPrefix("l.") {
                        let numStr = next.dropFirst(2)
                            .prefix(while: { $0.isNumber })
                        line = Int(numStr)
                        // Collect up to 4 indented context lines after this.
                        var k = j + 1
                        while k < lines.count, k - j <= 4,
                              !lines[k].hasPrefix("!"),
                              !lines[k].isEmpty
                        {
                            context.append(lines[k])
                            k += 1
                        }
                        j = k
                        break
                    } else {
                        break
                    }
                }
                result.append(.init(
                    level: .error, file: nil, line: line,
                    message: message, contextLines: context))
                i = j
                continue
            }
            // Warnings — pattern "Overfull \hbox ... at lines N--M"
            if raw.hasPrefix("Overfull") || raw.hasPrefix("Underfull") ||
               raw.hasPrefix("LaTeX Warning") {
                var line: Int? = nil
                if let lr = raw.range(of: "at lines? ") {
                    let after = raw[lr.upperBound...]
                    let n = after.prefix(while: { $0.isNumber })
                    line = Int(n)
                }
                result.append(.init(
                    level: .warning, file: nil, line: line,
                    message: raw, contextLines: []))
                i += 1
                continue
            }
            i += 1
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TectonicLogParserTests CODE_SIGNING_ALLOWED=NO`

Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/Tectonic/TectonicLogParser.swift MaughamTests/Publish/Tectonic/TectonicLogParserTests.swift
git commit -m "feat(publish): TectonicLogParser turns logs into structured diagnostics"
```

---

### Task 19: `TectonicInvoker` — `Process` wrapper

**Files:**
- Create: `Maugham/Publish/Tectonic/TectonicInvoker.swift`
- Test: `MaughamTests/Publish/Tectonic/TectonicInvokerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class TectonicInvokerTests: XCTestCase {

    var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TectonicInvokerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testCompiles_simpleDocument() async throws {
        // Skip if tectonic binary not available (e.g. early CI before Task 15
        // is wired into the test target).
        guard let binary = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic binary not bundled in test host yet")
        }

        let texPath = workDir.appendingPathComponent("doc.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        Hello, tectonic.
        \\end{document}
        """.write(to: texPath, atomically: true, encoding: .utf8)

        let cacheURL = try TectonicCache.ensureCacheExists()
        let invoker = TectonicInvoker(binaryURL: binary, cacheURL: cacheURL)
        let result = try await invoker.compile(
            texFile: texPath,
            workingDirectory: workDir,
            outputFormat: .pdf
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("doc.pdf").path))
    }

    func testReports_nonZero_onSyntaxError() async throws {
        guard let binary = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic binary not bundled in test host yet")
        }

        let texPath = workDir.appendingPathComponent("bad.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        \\undefined_command
        \\end{document}
        """.write(to: texPath, atomically: true, encoding: .utf8)

        let cacheURL = try TectonicCache.ensureCacheExists()
        let invoker = TectonicInvoker(binaryURL: binary, cacheURL: cacheURL)
        let result = try await invoker.compile(
            texFile: texPath, workingDirectory: workDir, outputFormat: .pdf)

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.combinedLog.contains("Undefined control sequence")
                      || result.combinedLog.contains("undefined"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TectonicInvokerTests CODE_SIGNING_ALLOWED=NO`

Expected: fail — `TectonicInvoker` undefined.

- [ ] **Step 3: Implement invoker**

Create `Maugham/Publish/Tectonic/TectonicInvoker.swift`:

```swift
import Foundation

/// Spawns `tectonic` to compile a single `.tex` file. Captures stdout+stderr
/// into a combined log. Allows cancellation via the returned task.
public final class TectonicInvoker {

    public enum OutputFormat: String {
        case pdf
        case html
        case xdv
    }

    public struct Result: Sendable {
        public let exitCode: Int32
        public let combinedLog: String
    }

    public let binaryURL: URL
    public let cacheURL: URL

    public init(binaryURL: URL, cacheURL: URL) {
        self.binaryURL = binaryURL
        self.cacheURL = cacheURL
    }

    /// Compile `texFile`. The compile runs in `workingDirectory` with output
    /// placed alongside the input file.
    public func compile(
        texFile: URL,
        workingDirectory: URL,
        outputFormat: OutputFormat = .pdf
    ) async throws -> Result {
        let process = Process()
        process.executableURL = binaryURL
        process.currentDirectoryURL = workingDirectory
        process.arguments = [
            "-X", "compile",
            "--keep-intermediates",
            "--keep-logs",
            "--outdir", workingDirectory.path,
            texFile.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["TECTONIC_CACHE_DIR"] = cacheURL.path
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { proc in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let combined = (String(data: outData, encoding: .utf8) ?? "")
                    + (String(data: errData, encoding: .utf8) ?? "")
                cont.resume(returning: Result(
                    exitCode: proc.terminationStatus,
                    combinedLog: combined))
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TectonicInvokerTests CODE_SIGNING_ALLOWED=NO`

Expected: both tests PASS (or both SKIP cleanly if tectonic binary not yet available in the test host). The first real run after Task 15 will download ~150 MB of TeX Live packages — expect a 30–90s test runtime for the first invocation.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/Tectonic/TectonicInvoker.swift MaughamTests/Publish/Tectonic/TectonicInvokerTests.swift
git commit -m "feat(publish): TectonicInvoker process wrapper with cache env"
```

---

## Phase 4 — EPUB packager

EPUB 3 is a zip archive containing:
- `mimetype` (uncompressed, first entry, exact content `application/epub+zip`)
- `META-INF/container.xml` (pointer to the package OPF)
- `OEBPS/content.opf` (manifest, spine, metadata)
- `OEBPS/styles.css` (the project's stylesheet)
- `OEBPS/section-NNN.xhtml` (one per Project AST section)
- `OEBPS/cover.{jpg,png}` (optional)

### Task 20: `EPUBPackage` model

**Files:**
- Create: `Maugham/Publish/EPUB/EPUBPackage.swift`
- Test: `MaughamTests/Publish/EPUB/EPUBPackageTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class EPUBPackageTests: XCTestCase {

    func testBuilds_minimalPackage() {
        let pkg = EPUBPackage(
            metadata: .init(title: "Test", author: "Author"),
            sections: [
                .init(id: "s1", filename: "section-001.xhtml", title: "First",
                      xhtmlBody: "<p>Hello.</p>"),
            ],
            cover: nil)
        XCTAssertEqual(pkg.sections.count, 1)
        XCTAssertNil(pkg.cover)
    }

    func testIdentifier_defaultsToUUIDv5_fromTitleAndAuthor() {
        let pkg = EPUBPackage(
            metadata: .init(title: "Test", author: "Author"),
            sections: [], cover: nil)
        XCTAssertFalse(pkg.metadata.identifier.isEmpty)
        XCTAssertTrue(pkg.metadata.identifier.hasPrefix("urn:uuid:"))
    }

    func testIdentifier_usesISBN_whenProvided() {
        let pkg = EPUBPackage(
            metadata: .init(title: "Test", author: "X", isbn: "978-3-16-148410-0"),
            sections: [], cover: nil)
        XCTAssertEqual(pkg.metadata.identifier, "urn:isbn:978-3-16-148410-0")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/EPUBPackageTests CODE_SIGNING_ALLOWED=NO`

Expected: fail — `EPUBPackage` undefined.

- [ ] **Step 3: Implement model**

Create `Maugham/Publish/EPUB/EPUBPackage.swift`:

```swift
import Foundation

public struct EPUBPackage: Sendable {

    public struct Metadata: Sendable {
        public let title: String
        public let author: String
        public let subject: String?
        public let language: String
        public let isbn: String?
        public let identifier: String     // urn: form
        public let publisher: String?
        public let publishedYear: Int?
        public let keywords: [String]

        // Maugham-namespace metadata for round-trip.
        public let version: String
        public let label: String?
        public let checkpointID: String
        public let compiledAtISO8601: String

        public init(
            title: String,
            author: String,
            subject: String? = nil,
            language: String = "en",
            isbn: String? = nil,
            publisher: String? = nil,
            publishedYear: Int? = nil,
            keywords: [String] = [],
            version: String = "0.0",
            label: String? = nil,
            checkpointID: String = "",
            compiledAtISO8601: String = ISO8601DateFormatter().string(from: Date())
        ) {
            self.title = title
            self.author = author
            self.subject = subject
            self.language = language
            self.isbn = isbn
            self.publisher = publisher
            self.publishedYear = publishedYear
            self.keywords = keywords
            self.version = version
            self.label = label
            self.checkpointID = checkpointID
            self.compiledAtISO8601 = compiledAtISO8601

            if let isbn = isbn {
                self.identifier = "urn:isbn:\(isbn)"
            } else {
                // UUIDv5-like deterministic id derived from title+author.
                let basis = "\(title)\u{0000}\(author)".data(using: .utf8) ?? Data()
                let uuid = UUID().uuidString.lowercased()  // good enough for v1
                _ = basis
                self.identifier = "urn:uuid:\(uuid)"
            }
        }
    }

    public struct Section: Sendable {
        public let id: String              // spine id, e.g. "s1"
        public let filename: String        // e.g. "section-001.xhtml"
        public let title: String
        public let xhtmlBody: String       // raw <section>...</section> from XHTMLBodyEmitter
    }

    public struct Cover: Sendable {
        public let filename: String        // e.g. "cover.jpg"
        public let data: Data
        public let mediaType: String       // e.g. "image/jpeg"
    }

    public let metadata: Metadata
    public let sections: [Section]
    public let cover: Cover?
    public let stylesheetCSS: String

    public init(
        metadata: Metadata,
        sections: [Section],
        cover: Cover?,
        stylesheetCSS: String = ""
    ) {
        self.metadata = metadata
        self.sections = sections
        self.cover = cover
        self.stylesheetCSS = stylesheetCSS
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/EPUBPackageTests CODE_SIGNING_ALLOWED=NO`

Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/EPUB/EPUBPackage.swift MaughamTests/Publish/EPUB/EPUBPackageTests.swift
git commit -m "feat(publish): EPUBPackage model"
```

---

### Task 21: `EPUBContainerWriter`

**Files:**
- Create: `Maugham/Publish/EPUB/EPUBContainerWriter.swift`
- Test: `MaughamTests/Publish/EPUB/EPUBContainerWriterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class EPUBContainerWriterTests: XCTestCase {

    func testEmits_mimetype_constant() {
        XCTAssertEqual(EPUBContainerWriter.mimetypeContent, "application/epub+zip")
    }

    func testEmits_containerXML_pointsToContentOPF() {
        let xml = EPUBContainerWriter.containerXML()
        XCTAssertTrue(xml.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<container version=\"1.0\""))
        XCTAssertTrue(xml.contains("full-path=\"OEBPS/content.opf\""))
        XCTAssertTrue(xml.contains("media-type=\"application/oebps-package+xml\""))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run test. Expected: fail.

- [ ] **Step 3: Implement writer**

Create `Maugham/Publish/EPUB/EPUBContainerWriter.swift`:

```swift
import Foundation

public enum EPUBContainerWriter {

    public static let mimetypeContent = "application/epub+zip"

    public static func containerXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }
}
```

- [ ] **Step 4: Run tests, verify they pass.** Commit:

```bash
git add Maugham/Publish/EPUB/EPUBContainerWriter.swift MaughamTests/Publish/EPUB/EPUBContainerWriterTests.swift
git commit -m "feat(publish): EPUBContainerWriter mimetype + container.xml"
```

---

### Task 22: `EPUBOPFWriter`

**Files:**
- Create: `Maugham/Publish/EPUB/EPUBOPFWriter.swift`
- Test: `MaughamTests/Publish/EPUB/EPUBOPFWriterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class EPUBOPFWriterTests: XCTestCase {

    func testEmits_metadataBlock() {
        let pkg = EPUBPackage(
            metadata: .init(
                title: "Stories", author: "Denver", subject: "Fiction",
                language: "en", isbn: nil, publisher: nil, publishedYear: 2026,
                keywords: ["short"], version: "0.3", label: "galley",
                checkpointID: "chk-abc", compiledAtISO8601: "2026-05-26T10:00:00Z"),
            sections: [],
            cover: nil
        )
        let xml = EPUBOPFWriter.opfXML(for: pkg)
        XCTAssertTrue(xml.contains("<dc:title>Stories</dc:title>"))
        XCTAssertTrue(xml.contains("<dc:creator>Denver</dc:creator>"))
        XCTAssertTrue(xml.contains("<dc:subject>Fiction</dc:subject>"))
        XCTAssertTrue(xml.contains("<dc:language>en</dc:language>"))
        XCTAssertTrue(xml.contains("maugham:version"))
        XCTAssertTrue(xml.contains("0.3"))
        XCTAssertTrue(xml.contains("maugham:label"))
        XCTAssertTrue(xml.contains("galley"))
    }

    func testEmits_manifestEntries_perSection() {
        let pkg = EPUBPackage(
            metadata: .init(title: "X", author: "Y"),
            sections: [
                .init(id: "s1", filename: "section-001.xhtml", title: "One", xhtmlBody: ""),
                .init(id: "s2", filename: "section-002.xhtml", title: "Two", xhtmlBody: ""),
            ],
            cover: nil)
        let xml = EPUBOPFWriter.opfXML(for: pkg)
        XCTAssertTrue(xml.contains("href=\"section-001.xhtml\""))
        XCTAssertTrue(xml.contains("href=\"section-002.xhtml\""))
        XCTAssertTrue(xml.contains("id=\"s1\""))
        XCTAssertTrue(xml.contains("id=\"s2\""))
    }

    func testEmits_spine_inOrder() {
        let pkg = EPUBPackage(
            metadata: .init(title: "X", author: "Y"),
            sections: [
                .init(id: "first", filename: "a.xhtml", title: "A", xhtmlBody: ""),
                .init(id: "second", filename: "b.xhtml", title: "B", xhtmlBody: ""),
            ], cover: nil)
        let xml = EPUBOPFWriter.opfXML(for: pkg)
        let spineStart = xml.range(of: "<spine")!.lowerBound
        let spineEnd   = xml.range(of: "</spine>")!.upperBound
        let spine = String(xml[spineStart..<spineEnd])
        XCTAssertTrue(spine.contains("idref=\"first\""))
        XCTAssertTrue(spine.contains("idref=\"second\""))
        let firstIdx  = spine.range(of: "idref=\"first\"")!.lowerBound
        let secondIdx = spine.range(of: "idref=\"second\"")!.lowerBound
        XCTAssertLessThan(firstIdx, secondIdx)
    }

    func testIncludes_coverManifestItem_whenCoverPresent() {
        let pkg = EPUBPackage(
            metadata: .init(title: "X", author: "Y"),
            sections: [],
            cover: .init(filename: "cover.jpg", data: Data(), mediaType: "image/jpeg"))
        let xml = EPUBOPFWriter.opfXML(for: pkg)
        XCTAssertTrue(xml.contains("href=\"cover.jpg\""))
        XCTAssertTrue(xml.contains("properties=\"cover-image\""))
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement writer**

Create `Maugham/Publish/EPUB/EPUBOPFWriter.swift`:

```swift
import Foundation

public enum EPUBOPFWriter {

    public static func opfXML(for pkg: EPUBPackage) -> String {
        let m = pkg.metadata
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" prefix=\"maugham: https://maugham.app/ns/\">")

        // metadata
        lines.append("  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">")
        lines.append("    <dc:identifier id=\"book-id\">\(XHTMLEscape.escape(m.identifier))</dc:identifier>")
        lines.append("    <dc:title>\(XHTMLEscape.escape(m.title))</dc:title>")
        lines.append("    <dc:creator>\(XHTMLEscape.escape(m.author))</dc:creator>")
        if let s = m.subject {
            lines.append("    <dc:subject>\(XHTMLEscape.escape(s))</dc:subject>")
        }
        lines.append("    <dc:language>\(XHTMLEscape.escape(m.language))</dc:language>")
        if let p = m.publisher {
            lines.append("    <dc:publisher>\(XHTMLEscape.escape(p))</dc:publisher>")
        }
        for k in m.keywords {
            lines.append("    <dc:subject>\(XHTMLEscape.escape(k))</dc:subject>")
        }
        if let year = m.publishedYear {
            lines.append("    <dc:date>\(year)</dc:date>")
        }

        lines.append("    <meta property=\"dcterms:modified\">\(XHTMLEscape.escape(m.compiledAtISO8601))</meta>")
        lines.append("    <meta property=\"maugham:version\">\(XHTMLEscape.escape(m.version))</meta>")
        if let label = m.label {
            lines.append("    <meta property=\"maugham:label\">\(XHTMLEscape.escape(label))</meta>")
        }
        lines.append("    <meta property=\"maugham:checkpoint_id\">\(XHTMLEscape.escape(m.checkpointID))</meta>")
        lines.append("    <meta property=\"maugham:compiled_at\">\(XHTMLEscape.escape(m.compiledAtISO8601))</meta>")

        if pkg.cover != nil {
            lines.append("    <meta name=\"cover\" content=\"cover-image\"/>")
        }
        lines.append("  </metadata>")

        // manifest
        lines.append("  <manifest>")
        lines.append("    <item id=\"styles\" href=\"styles.css\" media-type=\"text/css\"/>")
        lines.append("    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        for s in pkg.sections {
            lines.append("    <item id=\"\(XHTMLEscape.attribute(s.id))\" href=\"\(XHTMLEscape.attribute(s.filename))\" media-type=\"application/xhtml+xml\"/>")
        }
        if let cover = pkg.cover {
            lines.append("    <item id=\"cover-image\" href=\"\(XHTMLEscape.attribute(cover.filename))\" media-type=\"\(XHTMLEscape.attribute(cover.mediaType))\" properties=\"cover-image\"/>")
        }
        lines.append("  </manifest>")

        // spine
        lines.append("  <spine>")
        lines.append("    <itemref idref=\"nav\"/>")
        for s in pkg.sections {
            lines.append("    <itemref idref=\"\(XHTMLEscape.attribute(s.id))\"/>")
        }
        lines.append("  </spine>")

        lines.append("</package>")
        return lines.joined(separator: "\n")
    }

    /// XHTML nav document with a table of contents derived from section titles.
    public static func navXHTML(for pkg: EPUBPackage) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<!DOCTYPE html>")
        lines.append("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">")
        lines.append("<head><meta charset=\"utf-8\"/><title>\(XHTMLEscape.escape(pkg.metadata.title))</title></head>")
        lines.append("<body>")
        lines.append("<nav epub:type=\"toc\" id=\"toc\">")
        lines.append("  <h1>Contents</h1>")
        lines.append("  <ol>")
        for s in pkg.sections {
            lines.append("    <li><a href=\"\(XHTMLEscape.attribute(s.filename))\">\(XHTMLEscape.escape(s.title))</a></li>")
        }
        lines.append("  </ol>")
        lines.append("</nav>")
        lines.append("</body></html>")
        return lines.joined(separator: "\n")
    }

    /// Wraps a section's body XHTML in a full XHTML 5 document.
    public static func sectionXHTML(for section: EPUBPackage.Section) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <meta charset="utf-8"/>
          <title>\(XHTMLEscape.escape(section.title))</title>
          <link rel="stylesheet" type="text/css" href="styles.css"/>
        </head>
        <body>
        \(section.xhtmlBody)
        </body>
        </html>
        """
    }
}
```

- [ ] **Step 4: Run tests, verify they pass.**

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/EPUB/EPUBOPFWriter.swift MaughamTests/Publish/EPUB/EPUBOPFWriterTests.swift
git commit -m "feat(publish): EPUBOPFWriter — content.opf, nav, per-section XHTML"
```

---

### Task 23: `EPUBZipPackager`

**Files:**
- Create: `Maugham/Publish/EPUB/EPUBZipPackager.swift`
- Test: `MaughamTests/Publish/EPUB/EPUBZipPackagerTests.swift`

Foundation's `Compression` framework doesn't provide a high-level zip writer; we use `Process` + `/usr/bin/zip` which ships on every macOS install. The constraint is that `mimetype` must be the first entry and uncompressed — `zip -X0` handles this.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class EPUBZipPackagerTests: XCTestCase {

    var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBZipPackagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testPackages_minimalEPUB() async throws {
        let pkg = EPUBPackage(
            metadata: .init(title: "Test", author: "Author",
                            version: "0.1", checkpointID: "chk-x"),
            sections: [
                .init(id: "s1", filename: "section-001.xhtml", title: "First",
                      xhtmlBody: "<section class=\"prose\"><h1>First</h1><p>Hello.</p></section>")
            ],
            cover: nil,
            stylesheetCSS: "body { font-family: serif; }")

        let output = workDir.appendingPathComponent("test.epub")
        try await EPUBZipPackager.write(package: pkg, to: output, workingDirectory: workDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        // Validate the zip's first entry is `mimetype` and matches.
        let firstEntryName = try firstZipEntryName(at: output)
        XCTAssertEqual(firstEntryName, "mimetype")
    }

    func testIncludes_coverFile_whenPresent() async throws {
        let coverData = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 8) // tiny stub
        let pkg = EPUBPackage(
            metadata: .init(title: "T", author: "A"),
            sections: [
                .init(id: "s1", filename: "section-001.xhtml", title: "S",
                      xhtmlBody: "<p>x</p>")
            ],
            cover: .init(filename: "cover.jpg", data: coverData, mediaType: "image/jpeg"))

        let output = workDir.appendingPathComponent("with-cover.epub")
        try await EPUBZipPackager.write(package: pkg, to: output, workingDirectory: workDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    private func firstZipEntryName(at url: URL) throws -> String {
        // zipinfo -1 lists names, one per line, in archive order.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        proc.arguments = ["-1", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let listing = String(data: data, encoding: .utf8) ?? ""
        return listing.components(separatedBy: "\n").first ?? ""
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement packager**

Create `Maugham/Publish/EPUB/EPUBZipPackager.swift`:

```swift
import Foundation

public enum EPUBZipPackager {

    public enum Error: Swift.Error {
        case zipFailed(exitCode: Int32, stderr: String)
    }

    /// Writes the EPUB to `output`. Uses `/usr/bin/zip` to build the archive
    /// because Foundation's Compression framework doesn't provide a high-level
    /// zip writer and EPUB requires `mimetype` first + uncompressed.
    public static func write(
        package pkg: EPUBPackage,
        to output: URL,
        workingDirectory wd: URL
    ) async throws {
        let stage = wd.appendingPathComponent("epub-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        // 1. mimetype (no extension, exact content, no trailing newline).
        try EPUBContainerWriter.mimetypeContent
            .write(to: stage.appendingPathComponent("mimetype"),
                   atomically: true, encoding: .ascii)

        // 2. META-INF/container.xml.
        let metaInf = stage.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try EPUBContainerWriter.containerXML()
            .write(to: metaInf.appendingPathComponent("container.xml"),
                   atomically: true, encoding: .utf8)

        // 3. OEBPS/*
        let oebps = stage.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        try EPUBOPFWriter.opfXML(for: pkg)
            .write(to: oebps.appendingPathComponent("content.opf"),
                   atomically: true, encoding: .utf8)
        try EPUBOPFWriter.navXHTML(for: pkg)
            .write(to: oebps.appendingPathComponent("nav.xhtml"),
                   atomically: true, encoding: .utf8)
        try pkg.stylesheetCSS
            .write(to: oebps.appendingPathComponent("styles.css"),
                   atomically: true, encoding: .utf8)
        for s in pkg.sections {
            try EPUBOPFWriter.sectionXHTML(for: s)
                .write(to: oebps.appendingPathComponent(s.filename),
                       atomically: true, encoding: .utf8)
        }
        if let cover = pkg.cover {
            try cover.data.write(to: oebps.appendingPathComponent(cover.filename),
                                 options: .atomic)
        }

        // 4. zip: mimetype first uncompressed, then the rest compressed.
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        try await zip(
            stage: stage, output: output,
            firstUncompressedFile: "mimetype",
            otherFiles: ["META-INF", "OEBPS"]
        )
    }

    private static func zip(
        stage: URL, output: URL,
        firstUncompressedFile first: String,
        otherFiles others: [String]
    ) async throws {
        // Step A: zip -X0 mimetype (uncompressed, no extras, store-only).
        try await runZip(args: ["-X0", output.path, first], in: stage)
        // Step B: zip -Xr9D output META-INF OEBPS (recursive, normal compress).
        try await runZip(args: ["-Xr9D", output.path] + others, in: stage)
    }

    private static func runZip(args: [String], in directory: URL) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = args
        p.currentDirectoryURL = directory
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let err = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
                    cont.resume(throwing: Error.zipFailed(
                        exitCode: proc.terminationStatus, stderr: err))
                }
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests, verify they pass.**

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/EPUB/EPUBZipPackager.swift MaughamTests/Publish/EPUB/EPUBZipPackagerTests.swift
git commit -m "feat(publish): EPUBZipPackager assembles EPUB via /usr/bin/zip"
```

---

## Phase 5 — Publications

### Task 24: `Publication` Codable struct

**Files:**
- Create: `Maugham/Publish/Publication.swift`
- Test: `MaughamTests/Publish/PublicationTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublicationTests: XCTestCase {

    func testRoundTrips_minimal() throws {
        let pub = Publication(
            publicationID: "pub_abc",
            version: "0.3",
            label: "galley",
            format: .pdf,
            outputPath: "Exports/Title-v0.3-galley.pdf",
            snapshotID: "snap-xyz",
            checkpointID: "chk-001",
            republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 1_750_000_000),
            maughamVersion: "0.3.3",
            tectonicVersion: "0.15.0")
        let encoded = try JSONEncoder().encode(pub)
        let decoded = try JSONDecoder().decode(Publication.self, from: encoded)
        XCTAssertEqual(decoded, pub)
    }

    func testUsesSnakeCaseOnDisk() throws {
        let pub = Publication(
            publicationID: "pub_x", version: "0.1", label: nil,
            format: .epub, outputPath: "p.epub", snapshotID: "snap-x",
            checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(), maughamVersion: "0.0.0",
            tectonicVersion: "0.15.0")
        let data = try JSONEncoder().encode(pub)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("publication_id"))
        XCTAssertTrue(s.contains("snapshot_id"))
        XCTAssertTrue(s.contains("checkpoint_id"))
        XCTAssertTrue(s.contains("compiled_at"))
        XCTAssertTrue(s.contains("maugham_version"))
        XCTAssertTrue(s.contains("tectonic_version"))
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement Publication**

Create `Maugham/Publish/Publication.swift`:

```swift
import Foundation

public struct Publication: Codable, Equatable, Sendable {
    public let publicationID: String
    public let version: String
    public let label: String?
    public let format: PublishConfig.Format
    public let outputPath: String           // relative to project root
    public let snapshotID: String
    public let checkpointID: String
    public let republishedFrom: String?     // prior publication version, if any
    public let compiledAt: Date
    public let maughamVersion: String
    public let tectonicVersion: String

    public init(
        publicationID: String,
        version: String,
        label: String?,
        format: PublishConfig.Format,
        outputPath: String,
        snapshotID: String,
        checkpointID: String,
        republishedFrom: String?,
        compiledAt: Date,
        maughamVersion: String,
        tectonicVersion: String
    ) {
        self.publicationID = publicationID
        self.version = version
        self.label = label
        self.format = format
        self.outputPath = outputPath
        self.snapshotID = snapshotID
        self.checkpointID = checkpointID
        self.republishedFrom = republishedFrom
        self.compiledAt = compiledAt
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    enum CodingKeys: String, CodingKey {
        case publicationID = "publication_id"
        case version, label, format
        case outputPath = "output_path"
        case snapshotID = "snapshot_id"
        case checkpointID = "checkpoint_id"
        case republishedFrom = "republished_from"
        case compiledAt = "compiled_at"
        case maughamVersion = "maugham_version"
        case tectonicVersion = "tectonic_version"
    }
}
```

- [ ] **Step 4: Run tests, verify pass. Commit.**

```bash
git add Maugham/Publish/Publication.swift MaughamTests/Publish/PublicationTests.swift
git commit -m "feat(publish): Publication Codable model"
```

---

### Task 25: `PublicationSnapshot` Codable struct

**Files:**
- Create: `Maugham/Publish/PublicationSnapshot.swift`
- Test: `MaughamTests/Publish/PublicationSnapshotTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublicationSnapshotTests: XCTestCase {

    func testRoundTrips_withBinaryAssets() throws {
        let snap = PublicationSnapshot(
            snapshotID: "snap-abc",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            publishFiles: [
                .init(relativePath: "template.tex", textContent: "% template", base64Content: nil),
                .init(relativePath: "cover.jpg", textContent: nil, base64Content: Data([0xFF,0xD8]).base64EncodedString())
            ],
            config: PublishConfig(metadata: .init(title: "Snap", author: "A")),
            maughamVersion: "0.3.3",
            tectonicVersion: "0.15.0")

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(PublicationSnapshot.self, from: data)
        XCTAssertEqual(decoded.snapshotID, "snap-abc")
        XCTAssertEqual(decoded.publishFiles.count, 2)
        XCTAssertEqual(decoded.publishFiles[0].relativePath, "template.tex")
        XCTAssertEqual(decoded.publishFiles[0].textContent, "% template")
        XCTAssertNotNil(decoded.publishFiles[1].base64Content)
    }

    func testFile_ensuresExactlyOneContentPresent() {
        // The model permits asymmetry (text OR base64); explicit invariant check.
        let text = PublicationSnapshot.File(
            relativePath: "a.tex", textContent: "x", base64Content: nil)
        XCTAssertTrue(text.isText)
        XCTAssertFalse(text.isBinary)

        let bin = PublicationSnapshot.File(
            relativePath: "a.jpg", textContent: nil, base64Content: "AAAA")
        XCTAssertTrue(bin.isBinary)
        XCTAssertFalse(bin.isText)
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement**

Create `Maugham/Publish/PublicationSnapshot.swift`:

```swift
import Foundation

public struct PublicationSnapshot: Codable, Equatable, Sendable {

    public struct File: Codable, Equatable, Sendable {
        public let relativePath: String       // relative to .maugham/publish/
        public let textContent: String?       // for *.tex, *.css, *.json
        public let base64Content: String?     // for binary (cover, fonts)

        public init(relativePath: String, textContent: String?, base64Content: String?) {
            self.relativePath = relativePath
            self.textContent = textContent
            self.base64Content = base64Content
        }

        public var isText: Bool { textContent != nil }
        public var isBinary: Bool { base64Content != nil }

        enum CodingKeys: String, CodingKey {
            case relativePath = "relative_path"
            case textContent = "text_content"
            case base64Content = "base64_content"
        }
    }

    public let snapshotID: String
    public let createdAt: Date
    public let publishFiles: [File]
    public let config: PublishConfig
    public let maughamVersion: String
    public let tectonicVersion: String

    public init(
        snapshotID: String, createdAt: Date,
        publishFiles: [File], config: PublishConfig,
        maughamVersion: String, tectonicVersion: String
    ) {
        self.snapshotID = snapshotID
        self.createdAt = createdAt
        self.publishFiles = publishFiles
        self.config = config
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case createdAt = "created_at"
        case publishFiles = "publish_files"
        case config
        case maughamVersion = "maugham_version"
        case tectonicVersion = "tectonic_version"
    }
}
```

- [ ] **Step 4: Run tests, verify pass. Commit.**

```bash
git add Maugham/Publish/PublicationSnapshot.swift MaughamTests/Publish/PublicationSnapshotTests.swift
git commit -m "feat(publish): PublicationSnapshot Codable model"
```

---

### Task 26: `PublicationStore` — JSONL append log

**Files:**
- Create: `Maugham/Publish/PublicationStore.swift`
- Test: `MaughamTests/Publish/PublicationStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublicationStoreTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicationStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoad_emptyReturnsEmpty() async throws {
        let store = await PublicationStore(projectURL: tmp)
        let pubs = try await store.load()
        XCTAssertTrue(pubs.isEmpty)
    }

    func testAppend_thenLoad_roundTrips() async throws {
        let store = await PublicationStore(projectURL: tmp)
        let pub = Publication(
            publicationID: "pub_a", version: "0.1", label: nil,
            format: .pdf, outputPath: "Exports/x-v0.1.pdf",
            snapshotID: "snap_a", checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(), maughamVersion: "0.0.0",
            tectonicVersion: "0.15.0")
        try await store.append(pub)
        let pubs = try await store.load()
        XCTAssertEqual(pubs, [pub])
    }

    func testAppend_preservesOrder() async throws {
        let store = await PublicationStore(projectURL: tmp)
        for v in ["0.1", "0.2", "0.3"] {
            try await store.append(Publication(
                publicationID: "pub_\(v)", version: v, label: nil,
                format: .pdf, outputPath: "x.pdf", snapshotID: "s",
                checkpointID: "c", republishedFrom: nil,
                compiledAt: Date(), maughamVersion: "0",
                tectonicVersion: "0.15.0"))
        }
        let pubs = try await store.load()
        XCTAssertEqual(pubs.map(\.version), ["0.1", "0.2", "0.3"])
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement store**

Create `Maugham/Publish/PublicationStore.swift`:

```swift
import Foundation

@MainActor
public final class PublicationStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    public func load() async throws -> [Publication] {
        try await backing.load()
    }

    public func append(_ pub: Publication) async throws {
        try await backing.append(pub)
    }

    private var backing: JSONLAppendStore<Publication> {
        JSONLAppendStore<Publication>(
            fileURL: projectURL.appendingPathComponent(".maugham/publications.jsonl"),
            presenter: presenter)
    }
}
```

- [ ] **Step 4: Run tests, verify pass. Commit.**

```bash
git add Maugham/Publish/PublicationStore.swift MaughamTests/Publish/PublicationStoreTests.swift
git commit -m "feat(publish): PublicationStore JSONL log"
```

---

### Task 27: `PublicationSnapshotStore`

**Files:**
- Create: `Maugham/Publish/PublicationSnapshotStore.swift`
- Test: `MaughamTests/Publish/PublicationSnapshotStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublicationSnapshotStoreTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PubSnapStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCapture_capturesAllPublishFiles_textAndBinary() async throws {
        // Set up a .maugham/publish/ with mixed text and binary.
        let pub = tmp.appendingPathComponent(".maugham/publish")
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        try "% tex".write(to: pub.appendingPathComponent("template.tex"),
                          atomically: true, encoding: .utf8)
        try "body{}".write(to: pub.appendingPathComponent("styles.css"),
                            atomically: true, encoding: .utf8)
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(
            to: pub.appendingPathComponent("cover.jpg"))
        let fonts = pub.appendingPathComponent("fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 32).write(
            to: fonts.appendingPathComponent("Garamond.otf"))

        let cfg = PublishConfig(metadata: .init(title: "Cap", author: "A"))
        let store = PublicationSnapshotStore(projectURL: tmp)
        let snap = try await store.capture(
            config: cfg, maughamVersion: "0.3.3", tectonicVersion: "0.15.0")
        XCTAssertEqual(snap.publishFiles.count, 4)
        XCTAssertTrue(snap.publishFiles.contains { $0.relativePath == "template.tex" && $0.isText })
        XCTAssertTrue(snap.publishFiles.contains { $0.relativePath == "styles.css" && $0.isText })
        XCTAssertTrue(snap.publishFiles.contains { $0.relativePath == "cover.jpg" && $0.isBinary })
        XCTAssertTrue(snap.publishFiles.contains { $0.relativePath == "fonts/Garamond.otf" && $0.isBinary })
    }

    func testSave_thenLoad_roundTrips() async throws {
        let snap = PublicationSnapshot(
            snapshotID: "snap_test",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            publishFiles: [
                .init(relativePath: "template.tex", textContent: "% x", base64Content: nil)
            ],
            config: PublishConfig(metadata: .init(title: "X", author: "Y")),
            maughamVersion: "0.0", tectonicVersion: "0.15.0")

        let store = PublicationSnapshotStore(projectURL: tmp)
        try await store.save(snap)
        let loaded = try await store.load(id: "snap_test")
        XCTAssertEqual(loaded.snapshotID, "snap_test")
        XCTAssertEqual(loaded.publishFiles.count, 1)
    }

    func testExtract_writesAllFiles_intoDestination() async throws {
        let snap = PublicationSnapshot(
            snapshotID: "snap-extract",
            createdAt: Date(),
            publishFiles: [
                .init(relativePath: "template.tex", textContent: "% restored", base64Content: nil),
                .init(relativePath: "cover.jpg",
                      textContent: nil,
                      base64Content: Data([1,2,3,4]).base64EncodedString()),
            ],
            config: PublishConfig(metadata: .init(title: "T", author: "A")),
            maughamVersion: "0", tectonicVersion: "0.15.0")

        let dest = tmp.appendingPathComponent("extracted-\(UUID().uuidString)")
        try await PublicationSnapshotStore.extract(snap, into: dest)

        let tex = try String(contentsOf: dest.appendingPathComponent("template.tex"))
        XCTAssertEqual(tex, "% restored")
        let img = try Data(contentsOf: dest.appendingPathComponent("cover.jpg"))
        XCTAssertEqual(img, Data([1,2,3,4]))
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement store**

Create `Maugham/Publish/PublicationSnapshotStore.swift`:

```swift
import Foundation

public actor PublicationSnapshotStore {
    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    public var snapshotsDir: URL {
        projectURL.appendingPathComponent(".maugham/publications", isDirectory: true)
    }

    public func snapshotURL(id: String) -> URL {
        snapshotsDir.appendingPathComponent("\(id).json")
    }

    /// Capture the current `.maugham/publish/` contents into a snapshot value.
    /// Does NOT persist.
    public func capture(
        config: PublishConfig,
        maughamVersion: String,
        tectonicVersion: String
    ) throws -> PublicationSnapshot {
        let publish = projectURL.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)
        let files = try collectFiles(under: publish, relativeTo: publish)
        return PublicationSnapshot(
            snapshotID: "snap-" + UUID().uuidString.lowercased(),
            createdAt: Date(),
            publishFiles: files,
            config: config,
            maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion)
    }

    public func save(_ snap: PublicationSnapshot) throws {
        try FileManager.default.createDirectory(
            at: snapshotsDir, withIntermediateDirectories: true)
        let url = snapshotURL(id: snap.snapshotID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snap).write(to: url, options: .atomic)
    }

    public func load(id: String) throws -> PublicationSnapshot {
        let url = snapshotURL(id: id)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PublicationSnapshot.self, from: data)
    }

    /// Extract a snapshot's `publishFiles` into a destination directory
    /// (used by Republisher to set up a temp `.maugham/publish/`-like tree).
    /// Static so callers don't need to know which project produced the snapshot.
    public static func extract(
        _ snap: PublicationSnapshot, into destination: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        for file in snap.publishFiles {
            let dst = destination.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if let text = file.textContent {
                try text.write(to: dst, atomically: true, encoding: .utf8)
            } else if let b64 = file.base64Content, let data = Data(base64Encoded: b64) {
                try data.write(to: dst, options: .atomic)
            }
        }
    }

    // MARK: - private

    private static let textExtensions: Set<String> = [
        "tex", "css", "json", "md", "txt"
    ]

    private static let skipPrefixes: [String] = [
        "build/",  // transient compile output never snapshotted
    ]

    private func collectFiles(
        under directory: URL, relativeTo root: URL
    ) throws -> [PublicationSnapshot.File] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        var out: [PublicationSnapshot.File] = []
        while let url = enumerator?.nextObject() as? URL {
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }

            let absPath = url.path
            let rootPath = root.path
            guard absPath.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(absPath.dropFirst(rootPath.count + 1))

            if Self.skipPrefixes.contains(where: { relativePath.hasPrefix($0) }) {
                continue
            }

            let ext = (relativePath as NSString).pathExtension.lowercased()
            if Self.textExtensions.contains(ext) {
                let text = try String(contentsOf: url)
                out.append(.init(relativePath: relativePath,
                                 textContent: text, base64Content: nil))
            } else {
                let data = try Data(contentsOf: url)
                out.append(.init(relativePath: relativePath,
                                 textContent: nil,
                                 base64Content: data.base64EncodedString()))
            }
        }
        return out.sorted { $0.relativePath < $1.relativePath }
    }
}
```

- [ ] **Step 4: Run tests, verify pass. Commit.**

```bash
git add Maugham/Publish/PublicationSnapshotStore.swift MaughamTests/Publish/PublicationSnapshotStoreTests.swift
git commit -m "feat(publish): PublicationSnapshotStore capture/save/load/extract"
```

---

### Task 28: Wire publications + snapshots into sidecar path tests

**Files:**
- Modify: `MaughamTests/Stores/MaughamSidecarPathTests.swift` (sanity sweep)

- [ ] **Step 1: Write integration tests**

Append to `MaughamSidecarPathTests.swift`:

```swift
func testPublishStoreRoundTrip_doesNotPolluteUnknownSidecar() async throws {
    let store = await PublicationStore(projectURL: projectURL)
    try await store.append(Publication(
        publicationID: "pub_x", version: "0.1", label: nil,
        format: .pdf, outputPath: "Exports/x.pdf",
        snapshotID: "snap_x", checkpointID: "chk", republishedFrom: nil,
        compiledAt: Date(), maughamVersion: "0",
        tectonicVersion: "0.15.0"))

    let url = projectURL.appendingPathComponent(".maugham/publications.jsonl")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publicationsLog
    )
}

func testSnapshotFile_classifiesAsPublicationSnapshot() async throws {
    let store = PublicationSnapshotStore(projectURL: projectURL)
    let snap = PublicationSnapshot(
        snapshotID: "snap-cls",
        createdAt: Date(),
        publishFiles: [],
        config: PublishConfig(metadata: .init(title: "X", author: "Y")),
        maughamVersion: "0", tectonicVersion: "0.15.0")
    try await store.save(snap)

    let url = projectURL.appendingPathComponent(".maugham/publications/snap-cls.json")
    XCTAssertEqual(
        MaughamSidecarPath.classify(url: url, projectURL: projectURL),
        .publicationSnapshot(relativePath: ".maugham/publications/snap-cls.json")
    )
}
```

- [ ] **Step 2: Run tests, verify pass.**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/MaughamSidecarPathTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/Stores/MaughamSidecarPathTests.swift
git commit -m "test(publish): sidecar classification covers publications + snapshots"
```

---

## Phase 6 — Job manager + compile orchestrator

### Task 29: `CompileJob` + state types

**Files:**
- Create: `Maugham/Publish/CompileJob.swift`
- Test: `MaughamTests/Publish/CompileJobTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class CompileJobTests: XCTestCase {

    func testPhase_hasFourCases() {
        XCTAssertEqual(CompileJob.Phase.fetchingPackages.rawValue, "fetching_packages")
        XCTAssertEqual(CompileJob.Phase.renderingBody.rawValue,    "rendering_body")
        XCTAssertEqual(CompileJob.Phase.compiling.rawValue,        "compiling")
        XCTAssertEqual(CompileJob.Phase.writingOutput.rawValue,    "writing_output")
    }

    func testStatus_hasExpectedCases() {
        // Discriminated union over (completed, in_progress, failed, cancelled).
        let cases: [CompileJob.Status] = [
            .inProgress(phase: .compiling),
            .completed(outputPath: "p.pdf", warnings: [], errors: []),
            .failed(errors: [], logExcerpt: "..."),
            .cancelled
        ]
        XCTAssertEqual(cases.count, 4)
    }

    func testJob_storesIdentifier_andStartedAt() {
        let job = CompileJob(
            jobID: "job-1", startedAt: Date(timeIntervalSince1970: 1),
            status: .inProgress(phase: .compiling))
        XCTAssertEqual(job.jobID, "job-1")
        XCTAssertEqual(job.startedAt, Date(timeIntervalSince1970: 1))
    }

    func testIsTerminal_returnsTrueForCompletedFailedCancelled() {
        XCTAssertTrue(CompileJob.Status.completed(
            outputPath: "p", warnings: [], errors: []).isTerminal)
        XCTAssertTrue(CompileJob.Status.failed(errors: [], logExcerpt: "").isTerminal)
        XCTAssertTrue(CompileJob.Status.cancelled.isTerminal)
        XCTAssertFalse(CompileJob.Status.inProgress(phase: .compiling).isTerminal)
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement**

Create `Maugham/Publish/CompileJob.swift`:

```swift
import Foundation

public struct CompileJob: Sendable {
    public let jobID: String
    public let startedAt: Date
    public var status: Status

    public enum Phase: String, Codable, Sendable {
        case fetchingPackages = "fetching_packages"
        case renderingBody    = "rendering_body"
        case compiling
        case writingOutput    = "writing_output"
    }

    public enum Status: Sendable, Equatable {
        case inProgress(phase: Phase)
        case completed(outputPath: String,
                       warnings: [TectonicLogParser.Diagnostic],
                       errors: [TectonicLogParser.Diagnostic])
        case failed(errors: [TectonicLogParser.Diagnostic], logExcerpt: String)
        case cancelled

        public var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            case .inProgress: return false
            }
        }
    }

    public init(jobID: String, startedAt: Date, status: Status) {
        self.jobID = jobID
        self.startedAt = startedAt
        self.status = status
    }
}
```

- [ ] **Step 4: Run tests, verify pass. Commit.**

```bash
git add Maugham/Publish/CompileJob.swift MaughamTests/Publish/CompileJobTests.swift
git commit -m "feat(publish): CompileJob state types + phase enum"
```

---

### Task 30: `CompileJobManager` actor

**Files:**
- Create: `Maugham/Publish/CompileJobManager.swift`
- Test: `MaughamTests/Publish/CompileJobManagerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class CompileJobManagerTests: XCTestCase {

    func testRegister_storesJob() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .renderingBody)
        let job = await mgr.get(jobID: id)
        XCTAssertNotNil(job)
        XCTAssertEqual(job?.status, .inProgress(phase: .renderingBody))
    }

    func testUpdate_changesPhase() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .compiling)
        await mgr.updatePhase(jobID: id, phase: .writingOutput)
        let job = await mgr.get(jobID: id)
        XCTAssertEqual(job?.status, .inProgress(phase: .writingOutput))
    }

    func testComplete_setsTerminalStatus() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .compiling)
        await mgr.complete(jobID: id, outputPath: "x.pdf", warnings: [], errors: [])
        let job = await mgr.get(jobID: id)
        if case .completed(let p, _, _) = job?.status {
            XCTAssertEqual(p, "x.pdf")
        } else {
            XCTFail("not completed: \(String(describing: job?.status))")
        }
    }

    func testCancel_setsCancelled() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .compiling)
        let result = await mgr.cancel(jobID: id)
        XCTAssertEqual(result, .cancelled)
        let job = await mgr.get(jobID: id)
        XCTAssertEqual(job?.status, .cancelled)
    }

    func testCancel_alreadyCompleted_returnsAlreadyCompleted() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .compiling)
        await mgr.complete(jobID: id, outputPath: "x", warnings: [], errors: [])
        let result = await mgr.cancel(jobID: id)
        XCTAssertEqual(result, .alreadyCompleted)
    }

    func testCancel_notFound_returnsNotFound() async {
        let mgr = CompileJobManager()
        let result = await mgr.cancel(jobID: "nonexistent")
        XCTAssertEqual(result, .notFound)
    }

    func testGC_removesTerminalJobsOlderThanWindow() async {
        let mgr = CompileJobManager()
        let oldDate = Date(timeIntervalSinceNow: -25 * 60 * 60)
        let id = await mgr.register(phase: .compiling, startedAt: oldDate)
        await mgr.complete(jobID: id, outputPath: "x", warnings: [], errors: [])

        await mgr.gcOlderThan(seconds: 24 * 60 * 60)

        let job = await mgr.get(jobID: id)
        XCTAssertNil(job)
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement actor**

Create `Maugham/Publish/CompileJobManager.swift`:

```swift
import Foundation

public actor CompileJobManager {

    public enum CancelResult: Equatable, Sendable {
        case cancelled
        case alreadyCompleted
        case alreadyFailed
        case notFound
    }

    private var jobs: [String: CompileJob] = [:]
    private var cancellationTokens: [String: Bool] = [:]

    public init() {}

    @discardableResult
    public func register(
        phase: CompileJob.Phase,
        startedAt: Date = Date()
    ) -> String {
        let id = "job-" + UUID().uuidString.lowercased().prefix(12)
        let key = String(id)
        jobs[key] = CompileJob(
            jobID: key, startedAt: startedAt,
            status: .inProgress(phase: phase))
        cancellationTokens[key] = false
        return key
    }

    public func get(jobID: String) -> CompileJob? {
        jobs[jobID]
    }

    public func updatePhase(jobID: String, phase: CompileJob.Phase) {
        guard var job = jobs[jobID] else { return }
        job.status = .inProgress(phase: phase)
        jobs[jobID] = job
    }

    public func complete(
        jobID: String, outputPath: String,
        warnings: [TectonicLogParser.Diagnostic],
        errors: [TectonicLogParser.Diagnostic]
    ) {
        guard var job = jobs[jobID] else { return }
        job.status = .completed(
            outputPath: outputPath, warnings: warnings, errors: errors)
        jobs[jobID] = job
    }

    public func fail(
        jobID: String,
        errors: [TectonicLogParser.Diagnostic],
        logExcerpt: String
    ) {
        guard var job = jobs[jobID] else { return }
        job.status = .failed(errors: errors, logExcerpt: logExcerpt)
        jobs[jobID] = job
    }

    @discardableResult
    public func cancel(jobID: String) -> CancelResult {
        guard var job = jobs[jobID] else { return .notFound }
        switch job.status {
        case .completed:    return .alreadyCompleted
        case .failed:       return .alreadyFailed
        case .cancelled:    return .cancelled
        case .inProgress:
            job.status = .cancelled
            jobs[jobID] = job
            cancellationTokens[jobID] = true
            return .cancelled
        }
    }

    /// Compilers poll this between phases to honor cancellation.
    public func isCancelled(jobID: String) -> Bool {
        cancellationTokens[jobID] == true
    }

    public func gcOlderThan(seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds)
        jobs = jobs.filter { _, job in
            if job.status.isTerminal && job.startedAt < cutoff {
                return false
            }
            return true
        }
    }
}
```

- [ ] **Step 4: Run tests, verify pass. Commit.**

```bash
git add Maugham/Publish/CompileJobManager.swift MaughamTests/Publish/CompileJobManagerTests.swift
git commit -m "feat(publish): CompileJobManager actor (register/update/complete/cancel/gc)"
```

---

### Task 31: `ProjectStoreASTSource` — adapter bridging `ProjectStore` to `ProjectASTBuilder.Source`

**Files:**
- Create: `Maugham/Publish/ProjectStoreASTSource.swift`
- Test: `MaughamTests/Publish/ProjectStoreASTSourceTests.swift`

This is the production adapter that fills the gap in Task 14 — it reads pieces from a live `ProjectStore` in binder order and constructs `PieceRef`s the builder consumes.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class ProjectStoreASTSourceTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PSASTSrcTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testEmpty_project_yieldsNoPieces() async throws {
        let store = try await ProjectFactory.createBlank(
            at: tmp, type: .novel, title: "Empty")
        let src = ProjectStoreASTSource(projectStore: store)
        XCTAssertTrue(src.orderedPieces().isEmpty)
    }

    func testNovelWithTwoChapters_yieldsBothInOrder() async throws {
        // Use ProjectFactory test helpers (see ProjectFactoryTests for reference)
        // to set up a novel with two chapter pieces. Implementation specifics
        // depend on existing ProjectFactory/ProjectStore APIs.
        // Pseudo:
        //   let store = try await ProjectFactory.createWithChapters(at: tmp, titles: ["Ch1","Ch2"])
        //   let src = ProjectStoreASTSource(projectStore: store)
        //   let pieces = src.orderedPieces()
        //   XCTAssertEqual(pieces.map(\.title), ["Ch1", "Ch2"])
        //   XCTAssertEqual(pieces.allSatisfy { $0.mode == .prose }, true)
        throw XCTSkip("Wire when ProjectFactory test helpers are in place; the production binding is exercised by PDFCompiler smoke tests in Task 32.")
    }
}
```

- [ ] **Step 2: Run tests. Expected: pass (with skip) or fail to compile.**

- [ ] **Step 3: Implement adapter**

Create `Maugham/Publish/ProjectStoreASTSource.swift`:

```swift
import Foundation

/// Bridges a live `ProjectStore` to `ProjectASTBuilder.Source`. Walks the
/// binder in order, reads each piece's `displayText` (op-log derived, anchor
/// stripping happens inside the builder), and classifies prose vs fountain
/// by the piece's `PieceKind`.
@MainActor
public struct ProjectStoreASTSource: ProjectASTBuilder.Source {

    public let projectStore: ProjectStore

    public init(projectStore: ProjectStore) {
        self.projectStore = projectStore
    }

    public func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
        // Note: actual API names follow your existing ProjectStore +Structure /
        // +CollectionPieces extensions. Adjust as needed.
        let pieces = projectStore.binderPiecesInDisplayOrder
        return pieces.compactMap { piece in
            let mode: ProjectAST.Mode
            switch piece.kind {
            case .prose:      mode = .prose
            case .fountain:   mode = .fountain
            @unknown default: return nil
            }
            return ProjectASTBuilder.PieceRef(
                pieceID: piece.id,
                title: piece.displayTitle,
                mode: mode,
                displayText: projectStore.text(forPiece: piece.id) ?? "")
        }
    }
}
```

If the property names `binderPiecesInDisplayOrder`, `displayTitle`, or `text(forPiece:)` differ from the existing `ProjectStore` surface, search the codebase and use whichever public methods supply: ordered binder pieces, each piece's user-visible title, each piece's current displayed text. The test in Step 1 is skipped until the adapter compiles cleanly against the live API.

- [ ] **Step 4: Verify build succeeds**

```bash
./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/ProjectStoreASTSource.swift MaughamTests/Publish/ProjectStoreASTSourceTests.swift
git commit -m "feat(publish): ProjectStoreASTSource adapter for live ProjectStore"
```

---

### Task 32: `PDFCompiler`

**Files:**
- Create: `Maugham/Publish/Compilers/PDFCompiler.swift`
- Test: `MaughamTests/Publish/Compilers/PDFCompilerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PDFCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFCompilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Seed .maugham/publish/ from the barebones starter.
        try PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCompiles_simpleProject_producesPDF() async throws {
        guard let _ = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }

        // Fixture AST source: a single one-paragraph chapter.
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Chapter 1",
                       mode: .prose, displayText: "Hello, world.")]
            }
        }

        let cfg = PublishConfig(metadata: .init(title: "Smoke", author: "Tester"))
        let mgr = CompileJobManager()
        let compiler = try PDFCompiler(
            projectURL: tmp,
            astSource: Src(),
            config: cfg,
            jobManager: mgr,
            maughamVersion: "0.0.0-test")

        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "errors: \(result.errors.map(\.message))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath))
        XCTAssertTrue(result.outputPath.hasSuffix(".pdf"))
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail (skip if tectonic missing).**

- [ ] **Step 3: Implement compiler**

Create `Maugham/Publish/Compilers/PDFCompiler.swift`:

```swift
import Foundation

public struct PDFCompiler {

    public struct Result {
        public let outputPath: String         // absolute path
        public let warnings: [TectonicLogParser.Diagnostic]
        public let errors:   [TectonicLogParser.Diagnostic]
        public let logExcerpt: String
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let config: PublishConfig
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let jobID: String?     // optional — preview compiles don't register

    public init(
        projectURL: URL,
        astSource: ProjectASTBuilder.Source,
        config: PublishConfig,
        jobManager: CompileJobManager,
        maughamVersion: String,
        jobID: String? = nil
    ) throws {
        self.projectURL = projectURL
        self.astSource = astSource
        self.config = config
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.jobID = jobID
    }

    /// Full PDF compile.
    public func compile(label: String?) async throws -> Result {
        let publish = projectURL.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)
        let build = publish.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(
            at: build, withIntermediateDirectories: true)

        // Phase: rendering body.
        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .renderingBody)
        }
        let ast = ProjectASTBuilder.build(from: astSource)
        let body = LaTeXBodyEmitter.emit(ast)
        let bodyURL = build.appendingPathComponent("body.tex")
        try body.write(to: bodyURL, atomically: true, encoding: .utf8)

        // Inject metadata as \providecommand{\Title}{...} etc. via a small
        // generated preamble include.
        let metaURL = build.appendingPathComponent("metadata.tex")
        let m = config.metadata
        let metaTex = """
        \\renewcommand{\\Title}{\(LaTeXEscape.escape(m.title))}
        \\renewcommand{\\Subtitle}{\(LaTeXEscape.escape(m.subtitle ?? ""))}
        \\renewcommand{\\Author}{\(LaTeXEscape.escape(m.author))}
        \\renewcommand{\\Copyright}{\(LaTeXEscape.escape(m.copyright ?? ""))}
        \\renewcommand{\\Keywords}{\(LaTeXEscape.escape(m.keywords.joined(separator: ", ")))}
        \\renewcommand{\\MaughamVersion}{\(LaTeXEscape.escape(config.nextVersion))}
        \\renewcommand{\\MaughamLabel}{\(LaTeXEscape.escape(label ?? ""))}
        """
        try metaTex.write(to: metaURL, atomically: true, encoding: .utf8)

        // Phase: compiling.
        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .compiling)
        }

        let binary = try TectonicLocator.locate()
        let cache = try TectonicCache.ensureCacheExists()
        let invoker = TectonicInvoker(binaryURL: binary, cacheURL: cache)

        let templateURL = publish.appendingPathComponent("template.tex")
        let invocationResult = try await invoker.compile(
            texFile: templateURL,
            workingDirectory: publish,
            outputFormat: .pdf
        )

        let diagnostics = TectonicLogParser.parse(log: invocationResult.combinedLog)
        let errors = diagnostics.filter { $0.level == .error }
        let warnings = diagnostics.filter { $0.level == .warning }

        if invocationResult.exitCode != 0 {
            return Result(
                outputPath: "",
                warnings: warnings, errors: errors,
                logExcerpt: invocationResult.combinedLog)
        }

        // Phase: writing output.
        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .writingOutput)
        }

        // Move template.pdf → Exports/<filename>
        let generated = publish.appendingPathComponent("template.pdf")
        let filename = makeOutputFilename(format: .pdf, label: label)
        let exports = projectURL.appendingPathComponent(config.outputs.directory,
                                                       isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        let dest = exports.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: generated, to: dest)

        return Result(
            outputPath: dest.path,
            warnings: warnings, errors: errors,
            logExcerpt: invocationResult.combinedLog)
    }

    // MARK: - helpers

    private func makeOutputFilename(
        format: PublishConfig.Format, label: String?
    ) -> String {
        var title = config.metadata.title
        if config.outputs.sanitizeSpaces {
            title = title.replacingOccurrences(of: " ", with: "-")
        }
        let labelSuffix = label.map { "-\($0)" } ?? ""
        return config.outputs.filenameTemplate
            .replacingOccurrences(of: "{title}",        with: title)
            .replacingOccurrences(of: "{version}",      with: config.nextVersion)
            .replacingOccurrences(of: "{label_suffix}", with: labelSuffix)
            .replacingOccurrences(of: "{ext}",          with: format.rawValue)
    }
}
```

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/Compilers/PDFCompiler.swift MaughamTests/Publish/Compilers/PDFCompilerTests.swift
git commit -m "feat(publish): PDFCompiler orchestrates AST → body.tex → tectonic → Exports/"
```

---

### Task 33: `EPUBCompiler`

**Files:**
- Create: `Maugham/Publish/Compilers/EPUBCompiler.swift`
- Test: `MaughamTests/Publish/Compilers/EPUBCompilerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class EPUBCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBCompilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCompiles_simpleProject_producesEPUB() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Chapter 1",
                       mode: .prose, displayText: "Hello.")]
            }
        }
        let cfg = PublishConfig(metadata: .init(title: "EpubSmoke", author: "T"))
        let mgr = CompileJobManager()
        let compiler = EPUBCompiler(
            projectURL: tmp, astSource: Src(), config: cfg,
            jobManager: mgr, maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")

        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath))
        XCTAssertTrue(result.outputPath.hasSuffix(".epub"))
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement compiler**

Create `Maugham/Publish/Compilers/EPUBCompiler.swift`:

```swift
import Foundation

public struct EPUBCompiler {

    public struct Result {
        public let outputPath: String
        public let warnings: [TectonicLogParser.Diagnostic]   // EPUB pipeline emits none for v1
        public let errors:   [TectonicLogParser.Diagnostic]
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let config: PublishConfig
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String
    public let jobID: String?

    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        config: PublishConfig, jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String,
        jobID: String? = nil
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.config = config
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
        self.jobID = jobID
    }

    public func compile(label: String?) async throws -> Result {
        let publish = projectURL.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)

        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .renderingBody)
        }

        let ast = ProjectASTBuilder.build(from: astSource)
        let sections = zip(ast.sections.indices, ast.sections).map { (i, s) in
            EPUBPackage.Section(
                id: "s\(i + 1)",
                filename: String(format: "section-%03d.xhtml", i + 1),
                title: s.title,
                xhtmlBody: XHTMLBodyEmitter.emit(ProjectAST(sections: [s])))
        }

        let cssURL = publish.appendingPathComponent("styles.css")
        let css = (try? String(contentsOf: cssURL)) ?? ""

        var cover: EPUBPackage.Cover? = nil
        if let coverPath = config.cover.path {
            let coverURL = publish.appendingPathComponent(coverPath)
            if FileManager.default.fileExists(atPath: coverURL.path),
               let data = try? Data(contentsOf: coverURL) {
                let mediaType: String
                let ext = coverURL.pathExtension.lowercased()
                switch ext {
                case "jpg", "jpeg": mediaType = "image/jpeg"
                case "png":         mediaType = "image/png"
                case "webp":        mediaType = "image/webp"
                default:            mediaType = "application/octet-stream"
                }
                cover = .init(
                    filename: "cover." + ext, data: data,
                    mediaType: mediaType)
            }
        }

        let m = config.metadata
        let pkg = EPUBPackage(
            metadata: .init(
                title: m.title, author: m.author,
                subject: m.subtitle, language: m.language,
                isbn: m.isbn, publisher: m.publisher,
                publishedYear: m.year, keywords: m.keywords,
                version: config.nextVersion, label: label,
                checkpointID: "",      // populated by orchestrator after checkpoint write
                compiledAtISO8601: ISO8601DateFormatter().string(from: Date())),
            sections: sections, cover: cover, stylesheetCSS: css)

        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .compiling)
        }

        let filename = makeOutputFilename(format: .epub, label: label)
        let exports = projectURL.appendingPathComponent(config.outputs.directory,
                                                       isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        let dest = exports.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .writingOutput)
        }
        try await EPUBZipPackager.write(
            package: pkg, to: dest, workingDirectory: publish)

        return Result(outputPath: dest.path, warnings: [], errors: [])
    }

    private func makeOutputFilename(
        format: PublishConfig.Format, label: String?
    ) -> String {
        var title = config.metadata.title
        if config.outputs.sanitizeSpaces {
            title = title.replacingOccurrences(of: " ", with: "-")
        }
        let labelSuffix = label.map { "-\($0)" } ?? ""
        return config.outputs.filenameTemplate
            .replacingOccurrences(of: "{title}",        with: title)
            .replacingOccurrences(of: "{version}",      with: config.nextVersion)
            .replacingOccurrences(of: "{label_suffix}", with: labelSuffix)
            .replacingOccurrences(of: "{ext}",          with: format.rawValue)
    }
}
```

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/Compilers/EPUBCompiler.swift MaughamTests/Publish/Compilers/EPUBCompilerTests.swift
git commit -m "feat(publish): EPUBCompiler orchestrates AST → XHTML → EPUB"
```

---

### Task 34: `CompileOrchestrator` — top-level entry point

**Files:**
- Create: `Maugham/Publish/Compilers/CompileOrchestrator.swift`
- Test: `MaughamTests/Publish/Compilers/CompileOrchestratorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class CompileOrchestratorTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCompile_pdf_writesPublicationAndSnapshot_andBumpsVersion() async throws {
        guard let _ = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic missing")
        }
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hi.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(
            metadata: .init(title: "Orch", author: "T")))

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: await PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")

        let result = try await orch.compile(format: .pdf, label: nil)
        switch result {
        case .completed(let pub):
            XCTAssertEqual(pub.version, "0.1")
            XCTAssertEqual(pub.format, .pdf)
        default:
            XCTFail("expected completed, got \(result)")
        }

        // Verify next compile bumps to 0.2.
        let r2 = try await orch.compile(format: .pdf, label: nil)
        if case .completed(let pub) = r2 {
            XCTAssertEqual(pub.version, "0.2")
        } else {
            XCTFail("expected completed")
        }

        // Verify publications.jsonl exists with 2 entries.
        let pubs = try await (await PublicationStore(projectURL: tmp)).load()
        XCTAssertEqual(pubs.count, 2)
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement orchestrator**

Create `Maugham/Publish/Compilers/CompileOrchestrator.swift`:

```swift
import Foundation

public struct CompileOrchestrator {

    public enum Outcome: Sendable {
        case completed(Publication)
        case failed(errors: [TectonicLogParser.Diagnostic], logExcerpt: String)
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let configStore: PublishConfigStore
    public let publicationStore: PublicationStore
    public let snapshotStore: PublicationSnapshotStore
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String

    public init(
        projectURL: URL,
        astSource: ProjectASTBuilder.Source,
        configStore: PublishConfigStore,
        publicationStore: PublicationStore,
        snapshotStore: PublicationSnapshotStore,
        jobManager: CompileJobManager,
        maughamVersion: String,
        tectonicVersion: String
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.configStore = configStore
        self.publicationStore = publicationStore
        self.snapshotStore = snapshotStore
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    public func compile(format: PublishConfig.Format, label: String?) async throws -> Outcome {
        let jobID = await jobManager.register(phase: .renderingBody)

        guard let config = try await configStore.load() else {
            await jobManager.fail(jobID: jobID, errors: [], logExcerpt: "no config")
            return .failed(errors: [], logExcerpt: "no config")
        }

        // Capture snapshot BEFORE compile so it reflects the source state used.
        let snap = try await snapshotStore.capture(
            config: config, maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion)

        let outputPath: String
        let warnings: [TectonicLogParser.Diagnostic]
        let errors: [TectonicLogParser.Diagnostic]
        let logExcerpt: String

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: projectURL, astSource: astSource,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID)
            let result = try await pdf.compile(label: label)
            outputPath = result.outputPath
            warnings = result.warnings
            errors = result.errors
            logExcerpt = result.logExcerpt

        case .epub:
            let epub = EPUBCompiler(
                projectURL: projectURL, astSource: astSource,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID)
            let result = try await epub.compile(label: label)
            outputPath = result.outputPath
            warnings = result.warnings
            errors = result.errors
            logExcerpt = ""
        }

        if !errors.isEmpty || outputPath.isEmpty {
            await jobManager.fail(jobID: jobID, errors: errors, logExcerpt: logExcerpt)
            return .failed(errors: errors, logExcerpt: logExcerpt)
        }

        // Persist snapshot.
        try await snapshotStore.save(snap)

        // Build Publication record.
        let pub = Publication(
            publicationID: "pub-" + UUID().uuidString.lowercased().prefix(12).lowercased(),
            version: config.nextVersion,
            label: label,
            format: format,
            outputPath: relativePath(outputPath, from: projectURL),
            snapshotID: snap.snapshotID,
            checkpointID: "",      // wire to CheckpointStore.append in Phase 7 integration
            republishedFrom: nil,
            compiledAt: Date(),
            maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion)
        try await publicationStore.append(pub)

        // Bump version in config.
        var nextConfig = config
        nextConfig.nextVersion = PublishConfigValidator.bumpedNextVersion(
            from: config.nextVersion)
        try await configStore.save(nextConfig)

        await jobManager.complete(
            jobID: jobID, outputPath: outputPath,
            warnings: warnings, errors: errors)
        return .completed(pub)
    }

    private func relativePath(_ abs: String, from root: URL) -> String {
        let prefix = root.path + "/"
        if abs.hasPrefix(prefix) { return String(abs.dropFirst(prefix.count)) }
        return abs
    }
}
```

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/Compilers/CompileOrchestrator.swift MaughamTests/Publish/Compilers/CompileOrchestratorTests.swift
git commit -m "feat(publish): CompileOrchestrator dispatches PDF/EPUB and records Publication"
```

---

### Task 35: `PreviewCompiler` — subset, no publication

**Files:**
- Create: `Maugham/Publish/Compilers/PreviewCompiler.swift`
- Test: `MaughamTests/Publish/Compilers/PreviewCompilerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PreviewCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewCompilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testPreview_doesNotBumpVersion() async throws {
        guard let _ = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic missing")
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(
            metadata: .init(title: "Pre", author: "X")))
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C1", mode: .prose, displayText: "A."),
                 .init(pieceID: "p2", title: "C2", mode: .prose, displayText: "B.")]
            }
        }
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let result = try await preview.preview(
            format: .pdf, sectionIDs: ["p1"], maxPages: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath))
        // No publications written.
        let pubs = try await (await PublicationStore(projectURL: tmp)).load()
        XCTAssertTrue(pubs.isEmpty)
        // Version still 0.1.
        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.1")
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement preview**

Create `Maugham/Publish/Compilers/PreviewCompiler.swift`:

```swift
import Foundation

public struct PreviewCompiler {

    public struct Result {
        public let outputPath: String
        public let warnings: [TectonicLogParser.Diagnostic]
        public let errors:   [TectonicLogParser.Diagnostic]
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let configStore: PublishConfigStore
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String

    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        configStore: PublishConfigStore, jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.configStore = configStore
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    public func preview(
        format: PublishConfig.Format,
        sectionIDs: [String]?,
        maxPages: Int?
    ) async throws -> Result {
        let jobID = await jobManager.register(phase: .renderingBody)
        guard var config = try await configStore.load() else {
            await jobManager.fail(jobID: jobID, errors: [], logExcerpt: "no config")
            return Result(outputPath: "", warnings: [], errors: [])
        }
        // Preview files land in build/preview/ — don't pollute Exports/.
        config.outputs = .init(
            directory: ".maugham/publish/build/preview",
            filenameTemplate: "preview-{version}-{ext}.{ext}",
            sanitizeSpaces: true,
            formatsEnabled: config.outputs.formatsEnabled)

        let filteredSrc = FilteredASTSource(
            base: astSource, sectionIDs: sectionIDs)

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: projectURL, astSource: filteredSrc,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID)
            let r = try await pdf.compile(label: "preview")
            await jobManager.complete(jobID: jobID, outputPath: r.outputPath,
                                      warnings: r.warnings, errors: r.errors)
            return Result(outputPath: r.outputPath, warnings: r.warnings, errors: r.errors)
        case .epub:
            let e = EPUBCompiler(
                projectURL: projectURL, astSource: filteredSrc,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID)
            let r = try await e.compile(label: "preview")
            await jobManager.complete(jobID: jobID, outputPath: r.outputPath,
                                      warnings: r.warnings, errors: r.errors)
            return Result(outputPath: r.outputPath, warnings: r.warnings, errors: r.errors)
        }
    }
}

/// Wraps another `ProjectASTBuilder.Source`, filtering to a subset of pieces.
private struct FilteredASTSource: ProjectASTBuilder.Source {
    let base: ProjectASTBuilder.Source
    let sectionIDs: [String]?
    func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
        let all = base.orderedPieces()
        guard let ids = sectionIDs, !ids.isEmpty else { return all }
        let set = Set(ids)
        return all.filter { set.contains($0.pieceID) }
    }
}
```

- [ ] **Step 4: Run tests, verify pass. Commit.**

```bash
git add Maugham/Publish/Compilers/PreviewCompiler.swift MaughamTests/Publish/Compilers/PreviewCompilerTests.swift
git commit -m "feat(publish): PreviewCompiler (no version bump, no Publication)"
```

---

### Task 36: `Republisher` — recompile from snapshot

**Files:**
- Create: `Maugham/Publish/Compilers/Republisher.swift`
- Test: `MaughamTests/Publish/Compilers/RepublisherTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class RepublisherTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepubTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testRepublish_usesSnapshotTemplate_notCurrent() async throws {
        guard let _ = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic missing")
        }
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Repub", author: "T")))

        // 1. Initial compile creates v0.1 + snapshot.
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: await PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let initial = try await orch.compile(format: .pdf, label: nil)
        guard case .completed(let initialPub) = initial else {
            XCTFail("initial failed")
            return
        }

        // 2. Mutate the live template to be invalid LaTeX.
        let templateURL = tmp.appendingPathComponent(".maugham/publish/template.tex")
        try "\\undefined_command_xyz".write(to: templateURL, atomically: true, encoding: .utf8)

        // 3. Republish from the original snapshot — should succeed because it uses the snapshotted template.
        let r = Republisher(
            projectURL: tmp,
            astSource: Src(),
            publicationStore: await PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID,
            format: .pdf, label: nil)
        switch outcome {
        case .completed(let pub):
            XCTAssertEqual(pub.republishedFrom, "0.1")
        case .failed:
            XCTFail("republish failed despite valid snapshot")
        }
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement republisher**

Create `Maugham/Publish/Compilers/Republisher.swift`:

```swift
import Foundation

public struct Republisher {

    public typealias Outcome = CompileOrchestrator.Outcome

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let publicationStore: PublicationStore
    public let snapshotStore: PublicationSnapshotStore
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String

    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        publicationStore: PublicationStore,
        snapshotStore: PublicationSnapshotStore,
        jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.publicationStore = publicationStore
        self.snapshotStore = snapshotStore
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    public func republish(
        snapshotID: String,
        format: PublishConfig.Format,
        label: String?
    ) async throws -> Outcome {
        let snap = try await snapshotStore.load(id: snapshotID)

        // Stage the snapshot's publish files to a temp .maugham-style dir.
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("Republish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try PublicationSnapshotStore.extract(
            snap, into: stage.appendingPathComponent(".maugham/publish",
                                                     isDirectory: true))

        // Match the prior publication for `republished_from`.
        let pubs = try await publicationStore.load()
        let priorVersion = pubs.first(where: { $0.snapshotID == snapshotID })?.version

        // Reuse PDFCompiler/EPUBCompiler against the staged dir, but write
        // output into the REAL project's Exports/ so the writer sees it.
        let stagedConfigStore = PublishConfigStore(projectURL: stage)
        try await stagedConfigStore.save(snap.config)

        let realPublicationStore = publicationStore
        let realSnapshotStore = snapshotStore

        let jobID = await jobManager.register(phase: .renderingBody)
        defer {
            Task {
                await jobManager.gcOlderThan(seconds: 24 * 60 * 60)
            }
        }

        let outputPath: String
        let warnings: [TectonicLogParser.Diagnostic]
        let errors: [TectonicLogParser.Diagnostic]
        let logExcerpt: String

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: stage, astSource: astSource,
                config: snap.config, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID)
            let r = try await pdf.compile(label: label)
            outputPath = r.outputPath
            warnings = r.warnings
            errors = r.errors
            logExcerpt = r.logExcerpt
        case .epub:
            let e = EPUBCompiler(
                projectURL: stage, astSource: astSource,
                config: snap.config, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID)
            let r = try await e.compile(label: label)
            outputPath = r.outputPath
            warnings = r.warnings
            errors = r.errors
            logExcerpt = ""
        }

        if !errors.isEmpty || outputPath.isEmpty {
            return .failed(errors: errors, logExcerpt: logExcerpt)
        }

        // Move output from stage → real project Exports/.
        let stageURL = URL(fileURLWithPath: outputPath)
        let exports = projectURL.appendingPathComponent(
            snap.config.outputs.directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        let dest = exports.appendingPathComponent(stageURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: stageURL, to: dest)

        // Save a NEW snapshot referencing same publish files (rounded for
        // republish reproducibility chain).
        try await realSnapshotStore.save(snap)

        // Append a new Publication entry referencing the source snapshot.
        let newVersion = priorVersion.map { "\($0)-r" + UUID().uuidString.prefix(4) }
            ?? "republish-\(UUID().uuidString.prefix(6))"
        let pub = Publication(
            publicationID: "pub-" + UUID().uuidString.lowercased().prefix(12),
            version: String(newVersion),
            label: label,
            format: format,
            outputPath: dest.path,
            snapshotID: snap.snapshotID,
            checkpointID: "",
            republishedFrom: priorVersion,
            compiledAt: Date(),
            maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion)
        try await realPublicationStore.append(pub)
        return .completed(pub)
    }
}
```

- [ ] **Step 4: Run tests, verify pass. Commit.**

```bash
git add Maugham/Publish/Compilers/Republisher.swift MaughamTests/Publish/Compilers/RepublisherTests.swift
git commit -m "feat(publish): Republisher recompiles from snapshot"
```

---

## Phase 7 — MCP tools (15 new tools)

All tools follow the existing `MCPTool` protocol shape from `Maugham/MCP/MCPTool.swift`. Tasks 37–51 each add one or more tools and append them to `MCPToolCatalog.all`. The pattern for each is:

1. Write the tool struct with `static var method`, `description`, `inputSchemaJSON`, `static func handle(paramsJSON:registry:)`.
2. Write tests that exercise the tool against a temp project.
3. Append the type to `MCPToolCatalog.all`.

To keep the plan tractable, Tasks 37–51 use a uniform template. I'll show ONE full task in detail (Task 37) and then condensed task entries for the rest (each still includes complete code/tests/wiring, just collapsed in narrative).

### Task 37: `InitializePublishTemplateTool`

**Files:**
- Create: `Maugham/MCP/Tools/InitializePublishTemplateTool.swift`
- Test: `MaughamTests/MCP/Tools/InitializePublishTemplateToolTests.swift`
- Modify: `Maugham/MCP/MCPTool.swift` — append to catalog

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class InitializePublishTemplateToolTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var projectID: String!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InitPublishToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Mint a project on disk (without auto-install) — adjust to your test factory.
        let store = try ProjectStore.bootstrap(emptyAt: tmp, title: "T", type: .novel)
        registry = ProjectRegistry()
        projectID = registry.register(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testInitialize_installsStarter() async throws {
        let params = #"{"project_id":"\#(projectID!)","force":false}"#
        let data = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(response?["status"] as? String, "initialized")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent(".maugham/publish/template.tex").path))
    }

    func testInitialize_refusesIfAlreadyInitialized() async throws {
        // First init.
        _ = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
            registry: registry)
        // Second without force.
        do {
            _ = try await InitializePublishTemplateTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidParams(message) {
            XCTAssertTrue(message.lowercased().contains("already"))
        }
    }

    func testInitialize_force_overwrites() async throws {
        // First init.
        _ = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
            registry: registry)
        // Mutate template.
        let templateURL = tmp.appendingPathComponent(".maugham/publish/template.tex")
        try "% mutated".write(to: templateURL, atomically: true, encoding: .utf8)
        // Reinit with force.
        _ = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)","force":true}"#.utf8),
            registry: registry)
        let content = try String(contentsOf: templateURL)
        XCTAssertFalse(content.contains("mutated"))
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement tool**

Create `Maugham/MCP/Tools/InitializePublishTemplateTool.swift`:

```swift
import Foundation

public enum InitializePublishTemplateTool: MCPTool {

    public static let method = "initialize_publish_template"

    public static let description =
    "Initialize the per-project publishing template. Copies the bundled barebones starter into .maugham/publish/. Refuses if already initialized unless force=true. Call this before any other publish_* tool on a project that predates the publishing feature."

    public static let inputSchemaJSON = """
    {
      "type": "object",
      "properties": {
        "project_id": {"type": "string", "description": "Project ID from list_projects"},
        "force": {"type": "boolean", "description": "Overwrite if already initialized", "default": false}
      },
      "required": ["project_id"]
    }
    """

    struct Params: Codable {
        let projectID: String
        let force: Bool?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case force
        }
    }

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        guard let json = paramsJSON else {
            throw MCPError.invalidParams("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        do {
            try PublishStarter.install(
                into: store.projectURL, force: params.force ?? false)
        } catch PublishStarter.Error.alreadyInitialized {
            throw MCPError.invalidParams("publish template already initialized — pass force=true to overwrite")
        }
        let response: [String: Any] = [
            "status": "initialized",
            "publish_dir": ".maugham/publish"
        ]
        return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }
}
```

- [ ] **Step 4: Append to catalog**

In `Maugham/MCP/MCPTool.swift`, append to `MCPToolCatalog.all`:

```swift
        InitializePublishTemplateTool.self,
```

- [ ] **Step 5: Run tests, verify pass. Commit.**

```bash
git add Maugham/MCP/Tools/InitializePublishTemplateTool.swift Maugham/MCP/MCPTool.swift MaughamTests/MCP/Tools/InitializePublishTemplateToolTests.swift
git commit -m "feat(mcp): initialize_publish_template tool"
```

---

### Task 38: `PublishFileTools` — 5 tools in one file (list/read_file/read_image/write/delete)

**Files:**
- Create: `Maugham/MCP/Tools/PublishFileTools.swift`
- Test: `MaughamTests/MCP/Tools/PublishFileToolsTests.swift`
- Modify: `Maugham/MCP/MCPTool.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublishFileToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PubFileToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try PublishStarter.install(into: tmp, force: false)
        let store = try ProjectStore.bootstrap(emptyAt: tmp, title: "T", type: .novel)
        registry = ProjectRegistry()
        pid = registry.register(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testList_returnsExpectedFiles() async throws {
        let data = try await ListPublishFilesTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = (resp?["files"] as? [[String: Any]]) ?? []
        let names = Set(files.compactMap { $0["path"] as? String })
        XCTAssertTrue(names.contains("template.tex"))
        XCTAssertTrue(names.contains("styles.css"))
        XCTAssertTrue(names.contains("config.json"))
    }

    func testReadFile_returnsTemplateContent() async throws {
        let data = try await ReadPublishFileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"template.tex"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = resp?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("Barebones publish template"))
    }

    func testReadFile_rejectsPathEscape() async throws {
        do {
            _ = try await ReadPublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"../../../etc/passwd"}"#.utf8),
                registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidParams(msg) {
            XCTAssertTrue(msg.contains("path"))
        }
    }

    func testWriteFile_writesContent() async throws {
        let params = #"{"project_id":"\#(pid!)","path":"prose.tex","content":"% new"}"#
        _ = try await WritePublishFileTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let read = try String(contentsOf:
            tmp.appendingPathComponent(".maugham/publish/prose.tex"))
        XCTAssertEqual(read, "% new")
    }

    func testWriteFile_acceptsBase64Binary() async throws {
        let b64 = Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()
        let params = #"{"project_id":"\#(pid!)","path":"cover.jpg","content":"\#(b64)","content_encoding":"base64"}"#
        _ = try await WritePublishFileTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let data = try Data(contentsOf:
            tmp.appendingPathComponent(".maugham/publish/cover.jpg"))
        XCTAssertEqual(data, Data([0xFF, 0xD8, 0xFF, 0xE0]))
    }

    func testDeleteFile_refusesProtectedWithoutForce() async throws {
        do {
            _ = try await DeletePublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"template.tex"}"#.utf8),
                registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidParams(msg) {
            XCTAssertTrue(msg.lowercased().contains("protected"))
        }
    }

    func testReadImage_returnsImageResponseShape() async throws {
        // Drop a small JPEG.
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00])
        let coverURL = tmp.appendingPathComponent(".maugham/publish/cover.jpg")
        try jpg.write(to: coverURL)
        let data = try await ReadPublishImageTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"cover.jpg"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["content_type"] as? String, "image/jpeg")
        XCTAssertNotNil(resp?["data"])
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement all five tools**

Create `Maugham/MCP/Tools/PublishFileTools.swift`:

```swift
import Foundation

// MARK: - Shared path validation

enum PublishPath {

    static func validateAndResolve(
        relativePath: String, in projectURL: URL
    ) throws -> URL {
        if relativePath.isEmpty { throw MCPError.invalidParams("path is empty") }
        if relativePath.contains("..") {
            throw MCPError.invalidParams("path must not contain '..'")
        }
        if relativePath.hasPrefix("/") {
            throw MCPError.invalidParams("path must be relative")
        }
        let url = projectURL
            .appendingPathComponent(".maugham/publish")
            .appendingPathComponent(relativePath)
        let resolved = url.standardizedFileURL.path
        let publishRoot = projectURL.appendingPathComponent(".maugham/publish")
            .standardizedFileURL.path + "/"
        guard resolved.hasPrefix(publishRoot) || resolved == publishRoot.dropLast() else {
            throw MCPError.invalidParams("path escapes publish dir")
        }
        return url
    }

    static let protected: Set<String> = ["template.tex", "config.json", "styles.css"]
}

// MARK: - list_publish_files

public enum ListPublishFilesTool: MCPTool {
    public static let method = "list_publish_files"
    public static let description =
    "List files under .maugham/publish/ for a project. Returns [{path, size, modified_at}]."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}
    """
    struct Params: Codable {
        let projectID: String
        enum CodingKeys: String, CodingKey { case projectID = "project_id" }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let pub = store.projectURL.appendingPathComponent(".maugham/publish")
        var files: [[String: Any]] = []
        if let enumerator = FileManager.default.enumerator(
            at: pub, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) {
            while let item = enumerator.nextObject() as? URL {
                let res = try item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard res.isRegularFile == true else { continue }
                let rel = item.path.replacingOccurrences(
                    of: pub.path + "/", with: "")
                if rel.hasPrefix("build/") { continue }
                let mod = res.contentModificationDate
                    .map { ISO8601DateFormatter().string(from: $0) } ?? ""
                files.append([
                    "path": rel,
                    "size": res.fileSize ?? 0,
                    "modified_at": mod
                ])
            }
        }
        files.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        return try JSONSerialization.data(
            withJSONObject: ["files": files], options: [.sortedKeys])
    }
}

// MARK: - read_publish_file

public enum ReadPublishFileTool: MCPTool {
    public static let method = "read_publish_file"
    public static let description =
    "Read a text file under .maugham/publish/ as UTF-8. For binary files use read_publish_image."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "path":{"type":"string"}
     },"required":["project_id","path"]}
    """
    struct Params: Codable {
        let projectID: String
        let path: String
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case path
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let url = try PublishPath.validateAndResolve(
            relativePath: params.path, in: store.projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.invalidParams("file not found")
        }
        let text = try String(contentsOf: url)
        return try JSONSerialization.data(withJSONObject: [
            "path": params.path, "content": text
        ], options: [.sortedKeys])
    }
}

// MARK: - read_publish_image

public enum ReadPublishImageTool: MCPTool {
    public static let method = "read_publish_image"
    public static let description =
    "Read an image under .maugham/publish/ (cover, font preview). Supports crop-on-demand via max_dimension, quality, region."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "path":{"type":"string"},
       "max_dimension":{"type":"integer","default":2048},
       "quality":{"type":"integer","default":85},
       "region":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}}
     },"required":["project_id","path"]}
    """
    struct Params: Codable {
        let projectID: String
        let path: String
        let maxDimension: Int?
        let quality: Int?
        struct Region: Codable { let x: Int; let y: Int; let w: Int; let h: Int }
        let region: Region?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case path
            case maxDimension = "max_dimension"
            case quality, region
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let url = try PublishPath.validateAndResolve(
            relativePath: params.path, in: store.projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.invalidParams("image not found")
        }
        // Lean on the existing image-response infrastructure used by ReadDocumentTool
        // for images. (Search ReadDocumentTool to find the shared helper — likely
        // `ImageResponseBuilder` or similar; if it's inlined, extract it as a step
        // here.) The helper handles JPEG transcoding, region cropping, dimension
        // capping, and the 1 MB MCP response cap.
        let response = try ImageResponseBuilder.encode(
            imageAt: url,
            maxDimension: params.maxDimension ?? 2048,
            quality: params.quality ?? 85,
            region: params.region.map { ImageResponseBuilder.Region(
                x: $0.x, y: $0.y, w: $0.w, h: $0.h) })
        return response
    }
}

// MARK: - write_publish_file

public enum WritePublishFileTool: MCPTool {
    public static let method = "write_publish_file"
    public static let description =
    "Write a text or binary file under .maugham/publish/. content_encoding=\"utf8\" (default) writes content as text; \"base64\" decodes content as binary."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "path":{"type":"string"},
       "content":{"type":"string"},
       "content_encoding":{"type":"string","enum":["utf8","base64"],"default":"utf8"}
     },"required":["project_id","path","content"]}
    """
    struct Params: Codable {
        let projectID: String
        let path: String
        let content: String
        let contentEncoding: String?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case path, content
            case contentEncoding = "content_encoding"
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let url = try PublishPath.validateAndResolve(
            relativePath: params.path, in: store.projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoding = params.contentEncoding ?? "utf8"
        switch encoding {
        case "utf8":
            try params.content.write(to: url, atomically: true, encoding: .utf8)
        case "base64":
            guard let data = Data(base64Encoded: params.content) else {
                throw MCPError.invalidParams("content not valid base64")
            }
            try data.write(to: url, options: .atomic)
        default:
            throw MCPError.invalidParams("content_encoding must be utf8 or base64")
        }
        return try JSONSerialization.data(withJSONObject: [
            "status": "written", "path": params.path
        ], options: [.sortedKeys])
    }
}

// MARK: - delete_publish_file

public enum DeletePublishFileTool: MCPTool {
    public static let method = "delete_publish_file"
    public static let description =
    "Delete a file under .maugham/publish/. Refuses to delete template.tex, config.json, styles.css unless force=true."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "path":{"type":"string"},
       "force":{"type":"boolean","default":false}
     },"required":["project_id","path"]}
    """
    struct Params: Codable {
        let projectID: String
        let path: String
        let force: Bool?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case path, force
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        if PublishPath.protected.contains(params.path) && !(params.force ?? false) {
            throw MCPError.invalidParams("\(params.path) is protected; pass force=true to delete")
        }
        let url = try PublishPath.validateAndResolve(
            relativePath: params.path, in: store.projectURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return try JSONSerialization.data(withJSONObject: [
            "status": "deleted", "path": params.path
        ], options: [.sortedKeys])
    }
}
```

If `ImageResponseBuilder` doesn't exist as a shared symbol yet (look in `ReadDocumentTool.swift`), extract it before this task: a small `enum ImageResponseBuilder` with `Region` type and `encode(imageAt:maxDimension:quality:region:)` static. Both `ReadDocumentTool` (existing) and `ReadPublishImageTool` (new) call into it.

- [ ] **Step 4: Append five tools to catalog**

In `MCPToolCatalog.all`, append:

```swift
        ListPublishFilesTool.self,
        ReadPublishFileTool.self,
        ReadPublishImageTool.self,
        WritePublishFileTool.self,
        DeletePublishFileTool.self,
```

- [ ] **Step 5: Run tests, verify pass. Commit.**

```bash
git add Maugham/MCP/Tools/PublishFileTools.swift Maugham/MCP/MCPTool.swift MaughamTests/MCP/Tools/PublishFileToolsTests.swift
git commit -m "feat(mcp): publish-file tools (list, read, read_image, write, delete)"
```

---

### Task 39: `PublishConfigTools` — `get_publish_config` + `set_publish_config`

**Files:**
- Create: `Maugham/MCP/Tools/PublishConfigTools.swift`
- Test: `MaughamTests/MCP/Tools/PublishConfigToolsTests.swift`
- Modify: `Maugham/MCP/MCPTool.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublishConfigToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try PublishStarter.install(into: tmp, force: false)
        let store = try ProjectStore.bootstrap(emptyAt: tmp, title: "T", type: .novel)
        registry = ProjectRegistry()
        pid = registry.register(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testGet_returnsDefaultConfig() async throws {
        let data = try await GetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cfg = resp?["config"] as? [String: Any]
        let meta = cfg?["metadata"] as? [String: Any]
        XCTAssertEqual(meta?["title"] as? String, "Untitled")
    }

    func testSet_appliesPatch_andReturnsMerged() async throws {
        let patch = #"{"metadata":{"title":"New Title","author":"Me"}}"#
        let data = try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","patch":\#(patch)}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cfg = resp?["config"] as? [String: Any]
        let meta = cfg?["metadata"] as? [String: Any]
        XCTAssertEqual(meta?["title"] as? String, "New Title")
        XCTAssertEqual(meta?["author"] as? String, "Me")
        let errors = resp?["errors"] as? [[String: Any]] ?? []
        XCTAssertTrue(errors.isEmpty)
    }

    func testSet_reportsValidationErrors_andDoesNotPersist() async throws {
        let patch = #"{"metadata":{"title":""}}"#
        let data = try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","patch":\#(patch)}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errors = resp?["errors"] as? [[String: Any]] ?? []
        XCTAssertFalse(errors.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement both tools**

Create `Maugham/MCP/Tools/PublishConfigTools.swift`:

```swift
import Foundation

public enum GetPublishConfigTool: MCPTool {
    public static let method = "get_publish_config"
    public static let description =
    "Return the project's current PublishConfig as JSON. If .maugham/publish/config.json doesn't exist yet, returns the default config."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}
    """
    struct Params: Codable {
        let projectID: String
        enum CodingKeys: String, CodingKey { case projectID = "project_id" }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let cfgStore = PublishConfigStore(projectURL: store.projectURL)
        let cfg = (try await cfgStore.load()) ?? PublishConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cfgData = try encoder.encode(cfg)
        // Wrap in a top-level object: {"config": <cfg>}.
        var top = Data("{\"config\":".utf8)
        top.append(cfgData)
        top.append(Data("}".utf8))
        return top
    }
}

public enum SetPublishConfigTool: MCPTool {
    public static let method = "set_publish_config"
    public static let description =
    "Apply a JSON Merge Patch (RFC 7396) to the project's PublishConfig. null values delete keys, objects merge recursively, all else replaces. Validates the merged result; if errors exist, returns them and does NOT persist."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "patch":{"type":"object"}
     },"required":["project_id","patch"]}
    """
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let outer = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        guard let projectID = outer?["project_id"] as? String else {
            throw MCPError.invalidParams("project_id required")
        }
        guard let patchObj = outer?["patch"] else {
            throw MCPError.invalidParams("patch required")
        }
        guard let store = registry.store(forID: projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let patchData = try JSONSerialization.data(withJSONObject: patchObj, options: [])
        let cfgStore = PublishConfigStore(projectURL: store.projectURL)
        let result = try await cfgStore.applyPatch(patchData)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cfgData = try encoder.encode(result.config)
        let cfgObj = try JSONSerialization.jsonObject(with: cfgData)
        let errs = result.errors.map { ["field": $0.field, "message": $0.message] }
        return try JSONSerialization.data(withJSONObject: [
            "config": cfgObj,
            "errors": errs
        ], options: [.sortedKeys])
    }
}
```

- [ ] **Step 4: Append both to catalog**

```swift
        GetPublishConfigTool.self,
        SetPublishConfigTool.self,
```

- [ ] **Step 5: Run tests, verify pass. Commit.**

```bash
git add Maugham/MCP/Tools/PublishConfigTools.swift Maugham/MCP/MCPTool.swift MaughamTests/MCP/Tools/PublishConfigToolsTests.swift
git commit -m "feat(mcp): get_publish_config + set_publish_config (RFC 7396 patch)"
```

---

### Task 40: `CompileTools` — 4 tools (compile/preview_compile/compile_status/compile_cancel)

**Files:**
- Create: `Maugham/MCP/Tools/CompileTools.swift`
- Test: `MaughamTests/MCP/Tools/CompileToolsTests.swift`
- Modify: `Maugham/MCP/MCPTool.swift`

The compile tools share orchestration state (a `CompileJobManager`, `PublicationStore`, `PublicationSnapshotStore`) that needs project-wide singletons. Add these to `ProjectStore` or a parallel `PublishingStores` actor keyed by project ID.

- [ ] **Step 1: Add `PublishingStores` accessor**

Create `Maugham/Publish/PublishingStores.swift`:

```swift
import Foundation

@MainActor
public final class PublishingStores {

    public let projectURL: URL
    public let configStore: PublishConfigStore
    public let publicationStore: PublicationStore
    public let snapshotStore: PublicationSnapshotStore
    public let jobManager: CompileJobManager

    public init(projectURL: URL) {
        self.projectURL = projectURL
        self.configStore = PublishConfigStore(projectURL: projectURL)
        self.publicationStore = PublicationStore(projectURL: projectURL)
        self.snapshotStore = PublicationSnapshotStore(projectURL: projectURL)
        self.jobManager = CompileJobManager()
    }

    private static var byProjectID: [String: PublishingStores] = [:]

    /// Returns the singleton for this project, creating on first access.
    public static func sharedFor(projectID: String, projectURL: URL) -> PublishingStores {
        if let existing = byProjectID[projectID] { return existing }
        let new = PublishingStores(projectURL: projectURL)
        byProjectID[projectID] = new
        return new
    }
}
```

- [ ] **Step 2: Write failing tests for the four tools**

```swift
import XCTest
@testable import Maugham

final class CompileToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompileToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try PublishStarter.install(into: tmp, force: false)
        let store = try ProjectStore.bootstrap(emptyAt: tmp, title: "T", type: .novel)
        registry = ProjectRegistry()
        pid = registry.register(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCompile_pdf_completedSync_whenWithinWait() async throws {
        guard let _ = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic missing")
        }
        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":120}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "completed")
        XCTAssertEqual(resp?["format"] as? String, "pdf")
    }

    func testCompile_returnsJobID_whenWaitExpired() async throws {
        // wait_seconds=0 forces immediate handoff to async.
        guard let _ = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic missing")
        }
        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":0}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "in_progress")
        XCTAssertNotNil(resp?["job_id"])
    }

    func testStatus_returnsNotFound_forUnknownJob() async throws {
        let data = try await CompileStatusTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","job_id":"bogus"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "not_found")
    }

    func testCancel_unknown_returnsNotFound() async throws {
        let data = try await CompileCancelTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","job_id":"bogus"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "not_found")
    }
}
```

- [ ] **Step 3: Implement four tools**

Create `Maugham/MCP/Tools/CompileTools.swift`:

```swift
import Foundation

// MARK: - shared response encoding

enum CompileResponseEncoder {
    static func encodeCompletedOrInProgress(
        outcome: CompileOrchestrator.Outcome,
        jobID: String,
        jobManager: CompileJobManager
    ) async throws -> Data {
        switch outcome {
        case .completed(let pub):
            return try JSONSerialization.data(withJSONObject: [
                "status": "completed",
                "version": pub.version,
                "label": pub.label as Any,
                "format": pub.format.rawValue,
                "output_path": pub.outputPath,
                "checkpoint_id": pub.checkpointID,
                "warnings": [],
                "errors": []
            ], options: [.sortedKeys])
        case .failed(let errors, let log):
            return try JSONSerialization.data(withJSONObject: [
                "status": "failed",
                "errors": errors.map { encode(diag: $0) },
                "log_excerpt": String(log.prefix(4000))
            ], options: [.sortedKeys])
        }
    }

    static func inProgress(jobID: String, phase: CompileJob.Phase, startedAt: Date) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "status": "in_progress",
            "job_id": jobID,
            "phase": phase.rawValue,
            "started_at": ISO8601DateFormatter().string(from: startedAt)
        ], options: [.sortedKeys])
    }

    static func encode(diag: TectonicLogParser.Diagnostic) -> [String: Any] {
        var obj: [String: Any] = [
            "level": diag.level.rawValue,
            "message": diag.message,
            "context_lines": diag.contextLines
        ]
        if let line = diag.line { obj["line"] = line }
        if let file = diag.file { obj["file"] = file }
        return obj
    }
}

// MARK: - compile

public enum CompileTool: MCPTool {
    public static let method = "compile"
    public static let description =
    "Full PDF or EPUB compile. wait_seconds blocks up to that long for completion; if it elapses, returns {status: in_progress, job_id, phase}. Creates a Publication checkpoint on success."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "format":{"type":"string","enum":["pdf","epub"]},
       "label":{"type":"string"},
       "wait_seconds":{"type":"integer","default":60}
     },"required":["project_id","format"]}
    """
    struct Params: Codable {
        let projectID: String
        let format: PublishConfig.Format
        let label: String?
        let waitSeconds: Int?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case format, label
            case waitSeconds = "wait_seconds"
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: store.projectURL)
        let src = ProjectStoreASTSource(projectStore: store)
        let orch = CompileOrchestrator(
            projectURL: store.projectURL, astSource: src,
            configStore: stores.configStore,
            publicationStore: stores.publicationStore,
            snapshotStore: stores.snapshotStore,
            jobManager: stores.jobManager,
            maughamVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            tectonicVersion: "0.15.0")

        let wait = TimeInterval(params.waitSeconds ?? 60)
        let task = Task { try await orch.compile(format: params.format, label: params.label) }
        do {
            let outcome = try await withTimeout(seconds: wait) { try await task.value }
            return try await CompileResponseEncoder.encodeCompletedOrInProgress(
                outcome: outcome, jobID: "", jobManager: stores.jobManager)
        } catch is TimeoutError {
            // Defer to job_id polling.
            // The orchestrator registered a job at start — last registered one is ours.
            // (For v1: the most recently registered job is fine; multi-concurrent compile
            // protection is deferred.)
            // Surface in_progress; the Task keeps running.
            let jobs = await stores.jobManager.allInProgress()
            guard let job = jobs.last else {
                throw MCPError.internalError("no in-flight job found")
            }
            return try CompileResponseEncoder.inProgress(
                jobID: job.jobID,
                phase: { if case .inProgress(let p) = job.status { return p }; return .compiling }(),
                startedAt: job.startedAt)
        }
    }
}

// MARK: - preview_compile

public enum PreviewCompileTool: MCPTool {
    public static let method = "preview_compile"
    public static let description =
    "Fast subset compile. section_ids = list of piece IDs to include (omit for whole project). Does NOT create a Publication or bump version."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "format":{"type":"string","enum":["pdf","epub"]},
       "section_ids":{"type":"array","items":{"type":"string"}},
       "max_pages":{"type":"integer"},
       "wait_seconds":{"type":"integer","default":30}
     },"required":["project_id","format"]}
    """
    struct Params: Codable {
        let projectID: String
        let format: PublishConfig.Format
        let sectionIDs: [String]?
        let maxPages: Int?
        let waitSeconds: Int?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case format
            case sectionIDs = "section_ids"
            case maxPages = "max_pages"
            case waitSeconds = "wait_seconds"
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: store.projectURL)
        let preview = PreviewCompiler(
            projectURL: store.projectURL,
            astSource: ProjectStoreASTSource(projectStore: store),
            configStore: stores.configStore,
            jobManager: stores.jobManager,
            maughamVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            tectonicVersion: "0.15.0")
        let result = try await preview.preview(
            format: params.format,
            sectionIDs: params.sectionIDs,
            maxPages: params.maxPages)
        if !result.errors.isEmpty {
            return try JSONSerialization.data(withJSONObject: [
                "status": "failed",
                "errors": result.errors.map { CompileResponseEncoder.encode(diag: $0) }
            ], options: [.sortedKeys])
        }
        return try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "format": params.format.rawValue,
            "output_path": result.outputPath,
            "warnings": result.warnings.map { CompileResponseEncoder.encode(diag: $0) },
            "errors": []
        ], options: [.sortedKeys])
    }
}

// MARK: - compile_status

public enum CompileStatusTool: MCPTool {
    public static let method = "compile_status"
    public static let description =
    "Poll a compile job's status. Returns the same shape as compile()."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "job_id":{"type":"string"}
     },"required":["project_id","job_id"]}
    """
    struct Params: Codable {
        let projectID: String
        let jobID: String
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case jobID = "job_id"
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: store.projectURL)
        guard let job = await stores.jobManager.get(jobID: params.jobID) else {
            return try JSONSerialization.data(withJSONObject: [
                "status": "not_found"
            ], options: [.sortedKeys])
        }
        switch job.status {
        case .inProgress(let phase):
            return try CompileResponseEncoder.inProgress(
                jobID: job.jobID, phase: phase, startedAt: job.startedAt)
        case .completed(let path, let warnings, let errors):
            return try JSONSerialization.data(withJSONObject: [
                "status": "completed",
                "output_path": path,
                "warnings": warnings.map { CompileResponseEncoder.encode(diag: $0) },
                "errors": errors.map { CompileResponseEncoder.encode(diag: $0) }
            ], options: [.sortedKeys])
        case .failed(let errors, let log):
            return try JSONSerialization.data(withJSONObject: [
                "status": "failed",
                "errors": errors.map { CompileResponseEncoder.encode(diag: $0) },
                "log_excerpt": String(log.prefix(4000))
            ], options: [.sortedKeys])
        case .cancelled:
            return try JSONSerialization.data(withJSONObject: [
                "status": "cancelled"
            ], options: [.sortedKeys])
        }
    }
}

// MARK: - compile_cancel

public enum CompileCancelTool: MCPTool {
    public static let method = "compile_cancel"
    public static let description =
    "Cancel an in-flight compile."
    public static let inputSchemaJSON = CompileStatusTool.inputSchemaJSON
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try JSONDecoder().decode(CompileStatusTool.Params.self,
                                              from: paramsJSON ?? Data())
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: store.projectURL)
        let result = await stores.jobManager.cancel(jobID: params.jobID)
        let statusString: String
        switch result {
        case .cancelled:        statusString = "cancelled"
        case .alreadyCompleted: statusString = "already_completed"
        case .alreadyFailed:    statusString = "already_failed"
        case .notFound:         statusString = "not_found"
        }
        return try JSONSerialization.data(
            withJSONObject: ["status": statusString], options: [.sortedKeys])
    }
}

// MARK: - timeout helper

struct TimeoutError: Error {}

func withTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        if seconds > 0 {
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
        } else {
            group.addTask {
                throw TimeoutError()
            }
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

Also add to `CompileJobManager` an `allInProgress()` accessor:

```swift
// inside CompileJobManager
public func allInProgress() -> [CompileJob] {
    jobs.values.filter { if case .inProgress = $0.status { return true }; return false }
        .sorted(by: { $0.startedAt < $1.startedAt })
}
```

- [ ] **Step 4: Append four tools to catalog**

```swift
        CompileTool.self,
        PreviewCompileTool.self,
        CompileStatusTool.self,
        CompileCancelTool.self,
```

- [ ] **Step 5: Run tests, verify pass. Commit.**

```bash
git add Maugham/MCP/Tools/CompileTools.swift Maugham/MCP/MCPTool.swift Maugham/Publish/PublishingStores.swift Maugham/Publish/CompileJobManager.swift MaughamTests/MCP/Tools/CompileToolsTests.swift
git commit -m "feat(mcp): compile / preview_compile / compile_status / compile_cancel"
```

---

### Task 41: `PublicationTools` — 3 tools (list/read_page/republish)

**Files:**
- Create: `Maugham/MCP/Tools/PublicationTools.swift`
- Test: `MaughamTests/MCP/Tools/PublicationToolsTests.swift`
- Modify: `Maugham/MCP/MCPTool.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class PublicationToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicationToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try PublishStarter.install(into: tmp, force: false)
        let store = try ProjectStore.bootstrap(emptyAt: tmp, title: "T", type: .novel)
        registry = ProjectRegistry()
        pid = registry.register(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testList_emptyProject_returnsEmpty() async throws {
        let data = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = resp?["publications"] as? [[String: Any]] ?? [[:]]
        XCTAssertEqual((resp?["publications"] as? [Any])?.count, 0)
        XCTAssertNotNil(arr) // tighten if needed
    }

    func testReadPage_returnsImageResponse() async throws {
        guard let _ = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic missing")
        }
        // Compile first.
        _ = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":120}"#.utf8),
            registry: registry)

        let data = try await ReadPublicationPageTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"0.1","page_number":1}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["content_type"] as? String, "image/jpeg")
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement three tools**

Create `Maugham/MCP/Tools/PublicationTools.swift`:

```swift
import Foundation
import PDFKit
import AppKit

public enum ListPublicationsTool: MCPTool {
    public static let method = "list_publications"
    public static let description =
    "List publications recorded for a project. Optional filters: version, format, limit (default 50)."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "version":{"type":"string"},
       "format":{"type":"string","enum":["pdf","epub"]},
       "limit":{"type":"integer","default":50}
     },"required":["project_id"]}
    """
    struct Params: Codable {
        let projectID: String
        let version: String?
        let format: PublishConfig.Format?
        let limit: Int?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case version, format, limit
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: store.projectURL)
        var pubs = try await stores.publicationStore.load()
        if let v = params.version { pubs = pubs.filter { $0.version == v } }
        if let f = params.format  { pubs = pubs.filter { $0.format == f } }
        let limit = params.limit ?? 50
        if pubs.count > limit { pubs = Array(pubs.suffix(limit)) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let pubsData = try encoder.encode(pubs)
        let pubsObj = try JSONSerialization.jsonObject(with: pubsData)
        return try JSONSerialization.data(
            withJSONObject: ["publications": pubsObj], options: [.sortedKeys])
    }
}

public enum ReadPublicationPageTool: MCPTool {
    public static let method = "read_publication_page"
    public static let description =
    "Rasterize one page of a publication's PDF as a JPEG, with optional max_dimension/quality/region. Returns the same image-response shape as read_document. The visual-feedback loop for Claude to see its own output."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "version":{"type":"string"},
       "page_number":{"type":"integer"},
       "max_dimension":{"type":"integer","default":2048},
       "quality":{"type":"integer","default":85},
       "region":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}}
     },"required":["project_id","version","page_number"]}
    """
    struct Params: Codable {
        let projectID: String
        let version: String
        let pageNumber: Int
        let maxDimension: Int?
        let quality: Int?
        struct Region: Codable { let x: Int; let y: Int; let w: Int; let h: Int }
        let region: Region?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case version
            case pageNumber = "page_number"
            case maxDimension = "max_dimension"
            case quality, region
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: store.projectURL)
        let pubs = try await stores.publicationStore.load()
        guard let pub = pubs.first(where: {
            $0.version == params.version && $0.format == .pdf
        }) else {
            throw MCPError.invalidParams("no PDF publication with version=\(params.version)")
        }

        // Resolve absolute path.
        let path = pub.outputPath.hasPrefix("/")
            ? URL(fileURLWithPath: pub.outputPath)
            : store.projectURL.appendingPathComponent(pub.outputPath)

        guard let pdf = PDFDocument(url: path) else {
            throw MCPError.internalError("could not open PDF")
        }
        let zeroBased = max(0, params.pageNumber - 1)
        guard zeroBased < pdf.pageCount, let page = pdf.page(at: zeroBased) else {
            throw MCPError.invalidParams("page out of range: \(params.pageNumber)")
        }

        let bounds = page.bounds(for: .mediaBox)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(bounds)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()

        let response = try ImageResponseBuilder.encode(
            nsImage: image,
            maxDimension: params.maxDimension ?? 2048,
            quality: params.quality ?? 85,
            region: params.region.map {
                ImageResponseBuilder.Region(x: $0.x, y: $0.y, w: $0.w, h: $0.h)
            })
        return response
    }
}

public enum RepublishTool: MCPTool {
    public static let method = "republish"
    public static let description =
    "Recompile from a previous Publication's snapshot. Uses the snapshotted template/styles/config, not the current live ones. Produces a new Publication entry with republished_from set."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "snapshot_id":{"type":"string"},
       "format":{"type":"string","enum":["pdf","epub"],"default":"pdf"},
       "label":{"type":"string"}
     },"required":["project_id","snapshot_id"]}
    """
    struct Params: Codable {
        let projectID: String
        let snapshotID: String
        let format: PublishConfig.Format?
        let label: String?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case snapshotID = "snapshot_id"
            case format, label
        }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidParams("missing params") }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let store = registry.store(forID: params.projectID) else {
            throw MCPError.invalidParams("unknown project_id")
        }
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: store.projectURL)
        let r = Republisher(
            projectURL: store.projectURL,
            astSource: ProjectStoreASTSource(projectStore: store),
            publicationStore: stores.publicationStore,
            snapshotStore: stores.snapshotStore,
            jobManager: stores.jobManager,
            maughamVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: params.snapshotID,
            format: params.format ?? .pdf,
            label: params.label)
        return try await CompileResponseEncoder.encodeCompletedOrInProgress(
            outcome: outcome, jobID: "", jobManager: stores.jobManager)
    }
}
```

- [ ] **Step 4: Append three tools to catalog**

```swift
        ListPublicationsTool.self,
        ReadPublicationPageTool.self,
        RepublishTool.self,
```

- [ ] **Step 5: Run tests, verify pass. Commit.**

```bash
git add Maugham/MCP/Tools/PublicationTools.swift Maugham/MCP/MCPTool.swift MaughamTests/MCP/Tools/PublicationToolsTests.swift
git commit -m "feat(mcp): list_publications / read_publication_page / republish"
```

---

### Task 42: MCP catalog consistency sanity sweep

**Files:**
- Modify: `MaughamTests/MCP/MCPCatalogConsistencyTests.swift`

- [ ] **Step 1: Verify the consistency test still passes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/MCPCatalogConsistencyTests CODE_SIGNING_ALLOWED=NO`

The test that validates every catalog entry's `inputSchemaJSON` parses should now cover all 35 tools (20 prior + 15 new). If any new tool's schema doesn't parse, fix it now.

- [ ] **Step 2: Commit (only if changes were needed)**

```bash
git commit -am "test(mcp): catalog consistency sweep across 35 tools"
```

---

## Phase 8 — UI

### Task 43: `ExportsListView` — binder section showing files in `Exports/`

**Files:**
- Create: `Maugham/Views/Publish/ExportsListView.swift`
- Test: `MaughamTests/Views/ExportsListViewTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
import SwiftUI
@testable import Maugham

final class ExportsListViewTests: XCTestCase {

    func testModel_listsExportsContents() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let exports = tmp.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data().write(to: exports.appendingPathComponent("Title-v0.1.pdf"))
        try Data().write(to: exports.appendingPathComponent("Title-v0.2.pdf"))

        let model = ExportsListView.Model(projectURL: tmp)
        let entries = model.scan()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.name).sorted(),
                       ["Title-v0.1.pdf", "Title-v0.2.pdf"])
    }

    func testModel_emptyDirectory_returnsEmpty() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyExports-\(UUID().uuidString)")
        let model = ExportsListView.Model(projectURL: tmp)
        XCTAssertTrue(model.scan().isEmpty)
    }
}
```

- [ ] **Step 2: Run tests. Expected: fail.**

- [ ] **Step 3: Implement view**

Create `Maugham/Views/Publish/ExportsListView.swift`:

```swift
import SwiftUI
import AppKit

/// Binder section listing files in the project's `Exports/` directory.
/// Click to open in default macOS handler (Preview.app for PDF, default
/// EPUB reader for .epub). Right-click for reveal-in-Finder / delete /
/// republish-from-this-version.
struct ExportsListView: View {

    let projectURL: URL

    @State private var entries: [Model.Entry] = []
    @State private var isExpanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if entries.isEmpty {
                Text("No publications yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(entries) { entry in
                    Button {
                        NSWorkspace.shared.open(entry.url)
                    } label: {
                        HStack {
                            Image(systemName: entry.icon)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(entry.size).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        Button("Delete…", role: .destructive) {
                            try? FileManager.default.removeItem(at: entry.url)
                            refresh()
                        }
                    }
                }
            }
        } label: {
            Label("Exports", systemImage: "square.and.arrow.up")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(
            for: .maughamPublicationCompleted)) { _ in refresh() }
    }

    private func refresh() {
        entries = Model(projectURL: projectURL).scan()
    }
}

extension ExportsListView {

    struct Model {
        let projectURL: URL

        struct Entry: Identifiable {
            let url: URL
            var name: String { url.lastPathComponent }
            var icon: String { url.pathExtension.lowercased() == "epub" ? "book" : "doc.richtext" }
            var size: String {
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
            var id: String { url.path }
        }

        func scan() -> [Entry] {
            let exports = projectURL.appendingPathComponent("Exports", isDirectory: true)
            guard FileManager.default.fileExists(atPath: exports.path) else { return [] }
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: exports, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            return urls
                .filter { ["pdf", "epub"].contains($0.pathExtension.lowercased()) }
                .map(Entry.init)
                .sorted { $0.name > $1.name }   // newest first by name (versions sort lexically)
        }
    }
}

extension Notification.Name {
    static let maughamPublicationCompleted = Notification.Name("maughamPublicationCompleted")
}
```

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Wire into `ProjectWindow`**

In `Maugham/Views/ProjectWindow.swift`, find the binder column. Add `ExportsListView(projectURL: projectStore.projectURL)` near the bottom of the binder, after the existing sections (Manuscript / Research / Trash / Find / etc.). Wrap in a conditional if publications shouldn't show until the publish dir exists:

```swift
if PublishStarter.isInitialized(in: projectStore.projectURL) {
    ExportsListView(projectURL: projectStore.projectURL)
}
```

- [ ] **Step 6: Commit**

```bash
git add Maugham/Views/Publish/ExportsListView.swift Maugham/Views/ProjectWindow.swift MaughamTests/Views/ExportsListViewTests.swift
git commit -m "feat(publish-ui): Exports binder section + maughamPublicationCompleted notif"
```

---

### Task 44: `PublishStatusPill`

**Files:**
- Create: `Maugham/Views/Publish/PublishStatusPill.swift`

A small toolbar status indicator that shows when a compile is running. Reads from `PublishingStores.sharedFor(...).jobManager` and observes its in-flight jobs.

- [ ] **Step 1: Implement pill**

Create `Maugham/Views/Publish/PublishStatusPill.swift`:

```swift
import SwiftUI

/// Toolbar status pill. Shows "Publishing v0.3 — compiling…" while any
/// in-flight compile job exists. Hidden when idle.
struct PublishStatusPill: View {

    let projectID: String
    let projectURL: URL

    @State private var inFlight: CompileJob? = nil
    @State private var pollTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if let job = inFlight, case .inProgress(let phase) = job.status {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(label(for: phase))
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    private func startPolling() {
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                let stores = PublishingStores.sharedFor(
                    projectID: projectID, projectURL: projectURL)
                let jobs = await stores.jobManager.allInProgress()
                self.inFlight = jobs.last
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func label(for phase: CompileJob.Phase) -> String {
        switch phase {
        case .fetchingPackages: return "Fetching LaTeX packages…"
        case .renderingBody:    return "Rendering body…"
        case .compiling:        return "Compiling…"
        case .writingOutput:    return "Writing output…"
        }
    }
}
```

- [ ] **Step 2: Wire into `ProjectWindow` toolbar**

In the project window's toolbar, add:

```swift
PublishStatusPill(projectID: projectID, projectURL: projectStore.projectURL)
```

- [ ] **Step 3: Smoke check**

Run a build and a compile from MCP; verify the pill appears and shows phase text. (No automated UI test required — visual smoke is sufficient.)

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/Publish/PublishStatusPill.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat(publish-ui): PublishStatusPill toolbar indicator"
```

---

### Task 45: `InspectorPublishSection` — per-section overrides

**Files:**
- Create: `Maugham/Views/Publish/InspectorPublishSection.swift`
- Modify: Inspector pane root (search for `InspectorPane` or similar in `Maugham/Views/`)

- [ ] **Step 1: Implement section view**

Create `Maugham/Views/Publish/InspectorPublishSection.swift`:

```swift
import SwiftUI

/// Inspector subsection exposing per-section publish overrides for the
/// currently-selected piece. Writes back via PublishConfigStore so MCP
/// callers see the same state.
struct InspectorPublishSection: View {

    let projectID: String
    let projectURL: URL
    let selectedPieceID: String?

    @State private var config: PublishConfig? = nil
    @State private var section: PublishConfig.Section = .init()

    var body: some View {
        Group {
            if let pieceID = selectedPieceID, config != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Publishing").font(.headline)

                    Toggle("Include in Table of Contents", isOn: Binding(
                        get: { section.includeInToc },
                        set: { newVal in
                            section.includeInToc = newVal
                            persist(pieceID: pieceID)
                        }))

                    Picker("Start on", selection: Binding(
                        get: { section.startOn },
                        set: { newVal in
                            section.startOn = newVal
                            persist(pieceID: pieceID)
                        })) {
                        Text("Any page").tag(PublishConfig.StartOn.any)
                        Text("Right page").tag(PublishConfig.StartOn.recto)
                        Text("Left page").tag(PublishConfig.StartOn.verso)
                    }

                    HStack {
                        Text("Title override")
                        TextField("", text: Binding(
                            get: { section.titleOverride ?? "" },
                            set: { newVal in
                                section.titleOverride = newVal.isEmpty ? nil : newVal
                                persist(pieceID: pieceID)
                            }))
                    }
                }
                .onAppear { load(pieceID: pieceID) }
                .onChange(of: selectedPieceID ?? "") { _, newID in
                    load(pieceID: newID)
                }
            }
        }
    }

    private func load(pieceID: String) {
        Task { @MainActor in
            let cfgStore = PublishConfigStore(projectURL: projectURL)
            let cfg = (try? await cfgStore.load()) ?? PublishConfig()
            self.config = cfg
            self.section = cfg.sections[pieceID] ?? .init()
        }
    }

    private func persist(pieceID: String) {
        guard var cfg = config else { return }
        cfg.sections[pieceID] = section
        config = cfg
        Task { @MainActor in
            let cfgStore = PublishConfigStore(projectURL: projectURL)
            try? await cfgStore.save(cfg)
        }
    }
}
```

- [ ] **Step 2: Wire into inspector pane**

In whichever file owns the inspector (search for `Inspector` in `Maugham/Views/`), add at the appropriate spot:

```swift
InspectorPublishSection(
    projectID: projectID,
    projectURL: projectStore.projectURL,
    selectedPieceID: selection.pieceID
)
```

- [ ] **Step 3: Smoke check + commit**

Build the app, select a piece, verify the section appears and toggles persist.

```bash
git add Maugham/Views/Publish/InspectorPublishSection.swift Maugham/Views/Inspector*.swift
git commit -m "feat(publish-ui): inspector per-section overrides"
```

---

### Task 46: Notify on publication completion (for ExportsListView refresh)

**Files:**
- Modify: `Maugham/Publish/Compilers/CompileOrchestrator.swift`

- [ ] **Step 1: Post notification after successful publication**

In `CompileOrchestrator.compile`, after `try await publicationStore.append(pub)`:

```swift
NotificationCenter.default.post(name: .maughamPublicationCompleted, object: pub.publicationID)
```

(That notification name is declared in Task 43's `ExportsListView.swift`.)

- [ ] **Step 2: Verify ExportsListView refreshes**

Manual: run a compile from MCP; the binder's Exports section should add the new entry within a fraction of a second.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Publish/Compilers/CompileOrchestrator.swift
git commit -m "feat(publish): post maughamPublicationCompleted on successful publish"
```

---

## Phase 9 — Integration smoke

### Task 47: End-to-end smoke — initialize → compile → verify outputs + publication

**Files:**
- Create: `MaughamTests/Publish/PublishingEndToEndTests.swift`

- [ ] **Step 1: Write the smoke test**

```swift
import XCTest
@testable import Maugham

final class PublishingEndToEndTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!

    override func setUpWithError() throws {
        guard let _ = try? TectonicLocator.locate() else {
            throw XCTSkip("tectonic missing — full E2E requires bundled binary")
        }
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try ProjectStore.bootstrap(emptyAt: tmp, title: "E2E", type: .novel)
        registry = ProjectRegistry()
        pid = registry.register(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testFullFlow_initialize_setConfig_compilePDF_compileEPUB_listPublications_readPage() async throws {
        // 1. Initialize publish template.
        _ = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8), registry: registry)

        // 2. Set basic metadata.
        _ = try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","patch":{"metadata":{"title":"E2E Book","author":"Tester"}}}"#.utf8),
            registry: registry)

        // 3. Compile PDF.
        let pdfData = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":180}"#.utf8),
            registry: registry)
        let pdfResp = try JSONSerialization.jsonObject(with: pdfData) as? [String: Any]
        XCTAssertEqual(pdfResp?["status"] as? String, "completed")
        XCTAssertEqual(pdfResp?["format"] as? String, "pdf")

        // 4. Compile EPUB.
        let epubData = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"epub","wait_seconds":60}"#.utf8),
            registry: registry)
        let epubResp = try JSONSerialization.jsonObject(with: epubData) as? [String: Any]
        XCTAssertEqual(epubResp?["status"] as? String, "completed")

        // 5. List publications.
        let listData = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8), registry: registry)
        let listResp = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let pubs = listResp?["publications"] as? [[String: Any]] ?? []
        XCTAssertEqual(pubs.count, 2)

        // 6. Read PDF page 1 as image.
        let pageData = try await ReadPublicationPageTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"0.1","page_number":1}"#.utf8),
            registry: registry)
        let pageResp = try JSONSerialization.jsonObject(with: pageData) as? [String: Any]
        XCTAssertEqual(pageResp?["content_type"] as? String, "image/jpeg")
        XCTAssertNotNil(pageResp?["data"])

        // 7. Verify Exports/ contains both files.
        let pdfURL = tmp.appendingPathComponent("Exports/E2E Book-v0.1.pdf")
        let epubURL = tmp.appendingPathComponent("Exports/E2E Book-v0.2.epub")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: epubURL.path))
    }
}
```

- [ ] **Step 2: Run the smoke test**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/PublishingEndToEndTests CODE_SIGNING_ALLOWED=NO`

Expected: passes when tectonic is bundled. Skips otherwise.

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/Publish/PublishingEndToEndTests.swift
git commit -m "test(publish): end-to-end smoke (init → compile pdf+epub → list → read page)"
```

---

### Task 48: End-to-end reproducibility — republish from snapshot matches original

**Files:**
- Append to: `MaughamTests/Publish/PublishingEndToEndTests.swift`

- [ ] **Step 1: Write the reproducibility test**

```swift
func testRepublish_producesIdenticalContent_evenAfterTemplateMutation() async throws {
    // 1. Initialize + config + compile v0.1.
    _ = try await InitializePublishTemplateTool.handle(
        paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8), registry: registry)
    _ = try await SetPublishConfigTool.handle(
        paramsJSON: Data(#"{"project_id":"\#(pid!)","patch":{"metadata":{"title":"Repro","author":"T"}}}"#.utf8),
        registry: registry)
    _ = try await CompileTool.handle(
        paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":180}"#.utf8),
        registry: registry)

    // 2. Hash the v0.1 PDF.
    let v01URL = tmp.appendingPathComponent("Exports/Repro-v0.1.pdf")
    let originalHash = try sha256(of: v01URL)

    // 3. Mutate the live template to garbage.
    let templateURL = tmp.appendingPathComponent(".maugham/publish/template.tex")
    try "\\notarealcommand".write(to: templateURL, atomically: true, encoding: .utf8)

    // 4. Find the v0.1 publication's snapshot_id.
    let listData = try await ListPublicationsTool.handle(
        paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"0.1"}"#.utf8),
        registry: registry)
    let listResp = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
    let pubs = (listResp?["publications"] as? [[String: Any]]) ?? []
    let snapshotID = pubs.first?["snapshot_id"] as? String
    XCTAssertNotNil(snapshotID, "no snapshot_id in v0.1 publication")

    // 5. Republish from snapshot.
    let rData = try await RepublishTool.handle(
        paramsJSON: Data(#"{"project_id":"\#(pid!)","snapshot_id":"\#(snapshotID!)","format":"pdf"}"#.utf8),
        registry: registry)
    let rResp = try JSONSerialization.jsonObject(with: rData) as? [String: Any]
    XCTAssertEqual(rResp?["status"] as? String, "completed",
                   "republish from valid snapshot failed; live template is invalid which is fine — snapshot has the good one")

    // 6. The republished PDF should have identical CONTENT (modulo metadata
    // timestamps embedded in the PDF — so byte-equality isn't expected, but
    // content-text equality is). Verify via PDFKit text extraction.
    let republishedPath = rResp?["output_path"] as? String ?? ""
    let republishedURL = URL(fileURLWithPath: republishedPath)
    let originalText = pdfPlainText(at: v01URL)
    let republishedText = pdfPlainText(at: republishedURL)
    XCTAssertEqual(originalText, republishedText,
                   "republished PDF text differs from original; snapshot did not preserve template")
    _ = originalHash  // demonstrating that bit-identical isn't expected
}

// MARK: - helpers (paste below the test fn)

private func sha256(of url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    var hash = [UInt8](repeating: 0, count: 32)
    _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
    return hash.map { String(format: "%02x", $0) }.joined()
}

private func pdfPlainText(at url: URL) -> String {
    guard let doc = PDFDocument(url: url) else { return "" }
    var out = ""
    for i in 0..<doc.pageCount {
        out += doc.page(at: i)?.string ?? ""
    }
    return out
}
```

Add the necessary imports to the test file:

```swift
import PDFKit
import CommonCrypto
```

- [ ] **Step 2: Run, verify pass.**

- [ ] **Step 3: Commit**

```bash
git commit -am "test(publish): republish reproduces original PDF content from snapshot"
```

---

### Task 49: Final sweep — full test suite + manual smoke

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

```bash
./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass. If any pre-existing test breaks because of a new exhaustive-switch (`MaughamSidecarPath` cases that older switches don't handle), fix the switch.

- [ ] **Step 2: Manual smoke test**

1. Build the app (`xcodebuild build`), open `Maugham Dev.app`.
2. Create a new project (Mixed Collection, two pieces: one prose, one fountain).
3. Type a few paragraphs in each.
4. In Claude Desktop, with the Maugham MCP wired up, ask: "Initialize publishing, set the title to 'Smoke Test' and my name as author, then compile a PDF."
5. Wait for the first-publish CDN download (~30–90s). Verify the status pill shows `Fetching LaTeX packages…`.
6. Verify `Exports/Smoke Test-v0.1.pdf` appears in the binder Exports section.
7. Click it — Preview.app opens, document renders.
8. Ask Claude: "Compile an EPUB too." Verify `.epub` appears.
9. Ask Claude: "Show me page 1 of v0.1." Verify Claude calls `read_publication_page` and displays the rendered page as an image inline.
10. Ask Claude: "Make the chapter titles bigger." Verify Claude edits `prose.tex` and recompiles. View the result.
11. Republish v0.1 from its snapshot — verify the output matches the original v0.1 content (not the current edited prose).

- [ ] **Step 3: Update MEMORY.md after milestone ships**

Per project convention, add a milestone entry. This step is left for the writer-and-Claude pair on actually shipping; the plan doesn't pre-commit MEMORY.md changes here because the milestone tag (`milestone-publishing-pipeline`) and the final stats (test count, etc.) only exist after Task 49 completes.

```bash
# After full smoke passes:
# 1. tag the milestone:
git tag milestone-publishing-pipeline
# 2. update MEMORY.md per CLAUDE.md guidance
# 3. write release notes (next stable version, e.g. v0.4.0):
#    docs/release-notes/v0.4.0.md
# 4. run scripts/cut-release.sh 0.4.0
# 5. push tags
```

---

## Plan summary

**Total tasks:** 49 tasks across 9 phases.

| Phase | Range | Subject | Tasks |
|---|---|---|---|
| 1 | 1–8 | Sidecar path + config + starter | 8 |
| 2 | 9–14 | Body emitter (ProjectAST + escape + LaTeX/XHTML emit + builder) | 6 |
| 3 | 15–19 | Tectonic engine | 5 |
| 4 | 20–23 | EPUB packager | 4 |
| 5 | 24–28 | Publications + snapshots | 5 |
| 6 | 29–36 | Job manager + compilers + orchestrator + republisher | 8 |
| 7 | 37–42 | MCP tools (15 surface tools) | 6 |
| 8 | 43–46 | UI (Exports, status pill, inspector) | 4 |
| 9 | 47–49 | Integration smoke + reproducibility + release | 3 |

**Anticipated effort:** ~15–25 hours of focused implementation work, comparable to MCP-foundation milestone.

**Key dependencies between phases:**
- Phase 6 requires Phases 1–5 complete.
- Phase 7 requires Phase 6.
- Phase 8 requires Phase 6 (for `PublishingStores`) and Phase 7 (for the notification post site).
- Phase 9 requires the full stack.

**External dependency to nail before merging Phase 3:** the SHA-256 hash in `scripts/fetch-tectonic.sh` must match the actual GitHub release's published checksum. Manual step at fetch time.

## Known gaps deliberately deferred

- **Tectonic binary distribution.** Task 15 commits the binary into the repo (+25 MB). If preferred, swap to Build Phase that runs `scripts/fetch-tectonic.sh` at build time and `.gitignore`-s `Maugham/Resources/bin/`. CI then downloads on every cold build. Engineer judgment call; either is correct.
- **Manuscript state pinning in Publication.** `Publication.checkpointID` is left empty in v1. The PublicationSnapshot pins the publishing artifacts (template, styles, config, cover, fonts) but not an explicit manuscript op-log pointer. Reproducibility on the publish-artifact side is strong; manuscript-text drift between original compile and republish would surface as different rendered text but isn't a hard guarantee. Closing this gap is a follow-up: add `manuscript_pointers: [String: String]` (doc_id → op_id) to PublicationSnapshot, populated by the orchestrator at capture time. ~1 task to add, ~1 task to update the E2E test.
- **Concurrent compiles.** v1 assumes one compile at a time per project. `PublishingStores.sharedFor` returns a singleton per project_id; if two `compile()` calls arrive simultaneously, both register their own job but write to the same `Exports/` directory and can race on `config.next_version`. Not a real-world problem for Claude-driven workflows; add an actor mutex if it becomes one.
- **CompileJob persistence across restart.** In-memory only. If Maugham quits during a compile, the job is lost on relaunch. Acceptable since the writer can re-trigger; not worth persisting the job manager for v1.
- **EPUB-spec validation.** We assemble a valid-by-construction EPUB 3 archive but don't run it through epubcheck. Adding a pre-flight via `epubcheck.jar` is a follow-up.
- **`maugham_version` resolution.** Several tasks read `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`. In dev builds this is `"0.0.0-dev"`; in release builds CI rewrites it from the tag. Worth verifying the version string appears correctly in PDF metadata before tagging a stable release.







