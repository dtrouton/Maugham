# Translation Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-paragraph, language-tagged, freshness-tracked translations of manuscripts — written/read via MCP, reviewed read-only in the editor, publishable as a distinct edition with a blocking coverage gate.

**Architecture:** A new MaughamCore sidecar store (`.maugham/translations/<docId>.<lang>.<deviceSlug>.jsonl`, append-only, ULID-ordered LWW per paragraph) + a pure deriver that computes fresh/stale/missing against the live sequence. Three MCP tools operate on it. Publish substitutes translated text at `ProjectStoreASTSource.pieceRef` (before anchor-stripping) behind a blocking coverage gate. The editor gains a translation-review posture built on the existing WF1 review membrane (`EditorEditPolicy` + `shouldChangeTextIn`).

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest, xcodegen, existing MaughamCore primitives (`JSONLAppendStore`, `StableHash`, `MarkdownDisplayFilter`, `DeviceSlug`, `ULID`, `DerivedManuscriptCache`, `MarkdownBlockParser`, `FountainTokenizer`).

**Spec:** `docs/superpowers/specs/2026-07-22-translation-layer-design.md`. **ADR required** (Task 15).

## Global Constraints

- Branch: `feat/translation-layer`. Regenerate the project after any `project.yml`/package-source change: `./gen.sh`.
- Test commands (from repo root):
  - Mac: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (add `-only-testing:` per step)
  - Phone (MaughamCore changes must pass BOTH schemes): `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
- **MCP never mutates manuscript text** — translation tools write ONLY under `.maugham/translations/`, never `.md`/`.fountain`, never manuscript ops.
- **Never read the on-disk `.md` as truth** (tripwire 20). Current paragraph text: open doc → live `Document`; closed → `DerivedManuscriptCache`/`DerivedManuscript.derivedState`. Any new file-read of manuscript files needs `// adr-0018-ok:` annotation or `TripwireGrepTests` fails.
- **Filename builders take `DeviceSlug`, never `String`** (tripwire 24); interpolate `.raw` only at the filename point; the slug appears ONLY in filenames, never inside JSONL content.
- **No single shared JSONL across devices** (tripwire 17) — per-device translation files, merged on read.
- **No new `applyExternalText` call site** (tripwire 7; grep census `TripwireGrepTests.test_applyExternalTextHasExactlyOneProductionCallSite`) and typing must never trigger it (`EditorIntegrationHarness.assertNoApplyExternalText`).
- **No bare `ParagraphID.mint()` in production** (tripwire 23). Test paragraph-id literals crossing the .md boundary use 4-char restricted alphabet (`[0-9a-hjkmnp-tv-z]`), e.g. `"aaaa"` (tripwire 8).
- Paragraph ids are plain `String` throughout. Language tags: lowercase, regex `^[a-z]{2,3}(-[a-z0-9]{2,8})*$`.
- New MCP tools: add to `MCPToolCatalog.all` (`Maugham/MCP/MCPTool.swift:36-85`), bump `MaughamTests/MCP/MCPToolsListSmokeTest.swift:19` hardcoded count, update `Maugham/MCP/AREA.md` count prose in the SAME commit. Schemas must be `{"type":"object","properties":{...},"required":[...]}` string literals (`MCPCatalogConsistencyTests` validates parseability).
- All Codable additions to publish types must be optional/defaulted (synthesized or defaulting decoders) so existing `config.json` / `publications.jsonl` decode unchanged (ADR 0015).
- After any `ProjectWindow.body` change: local Release build before finishing (`xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`).
- Commit after every green task; commit messages `feat(translation): …` / `test(translation): …`.

## File Structure (created/modified)

```
Packages/MaughamCore/Sources/MaughamCore/
  TranslationRecord.swift        (new — wire type + language-tag validation)
  TranslationStore.swift         (new — filenames, append, merged LWW load)
  TranslationDeriver.swift       (new — hash normalization + TranslatedDocument derivation)
  TranslationConstructSkeleton.swift (new — construct-parity skeleton compare)
Packages/MaughamCore/Tests/MaughamCoreTests/
  TranslationStoreTests.swift, TranslationDeriverTests.swift,
  TranslationConstructSkeletonTests.swift (new)
Maugham/MCP/Tools/TranslationTools.swift   (new — 3 tools)
Maugham/MCP/MCPTool.swift                  (catalog +3)
Maugham/MCP/Tools/AnnotationCreationTools.swift (add_query language param)
Packages/MaughamCore/Sources/MaughamCore/Annotation.swift (+ language field)
Packages/MaughamCore/Sources/MaughamCore/AnnotationDeriver.swift (populate it)
Maugham/Publish/PublishConfig.swift        (language_overrides + effectiveMetadata)
Maugham/Publish/Publication.swift          (+ language)
Maugham/Publish/OutputFilenameBuilder.swift ({language} token)
Maugham/MCP/Tools/CompileTools.swift       (language/allow_stale params)
Maugham/Publish/CompileOrchestrator.swift  (threading + coverage gate)
Maugham/Publish/TranslationCoverage.swift  (new — gate + fountain drift check)
Maugham/Publish/ProjectStoreASTSource.swift (substitution)
Maugham/Publish/PDFCompiler.swift          (template.<lang>.tex, \MaughamLanguage)
Maugham/Publish/EPUBCompiler.swift         (styles.<lang>.css, dc:language)
Maugham/Publish/LanguageSuffixedFile.swift (new — suffix resolution helper)
Maugham/Editor/EditorControl.swift, EditorEditPolicy.swift, EditorCoordinator.swift (posture)
Maugham/Views/EditorHost.swift             (surface-text selection)
Maugham/Views/TranslationReviewPane.swift  (new — right-pane segment)
Maugham/Views/DetailPaneToggle.swift       (new segment)
Maugham/Views/ProjectWindow.swift + Maugham/MaughamApp.swift (picker, command)
Maugham/Models/MaughamNotifications.swift  (event names)
docs/skills/translation-pass/SKILL.md      (new)
docs/adr/0024-translation-layer.md         (new)
```

---

### Task 1: TranslationRecord + TranslationStore (MaughamCore)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/TranslationRecord.swift`
- Create: `Packages/MaughamCore/Sources/MaughamCore/TranslationStore.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/TranslationStoreTests.swift`

**Interfaces:**
- Consumes: `JSONLAppendStore<T>`, `DeviceSlug`, `ULID.generate()`, `OpLogStore.mergeSortedDedup` discipline (mirrored, not called).
- Produces:
  - `public struct TranslationRecord: Codable, Equatable, Sendable { public let opId, paragraphId, language: String; public let text: String?; public let sourceHash: String; public let verbatim: Bool; public let at: Date }` with `public init(opId: String = ULID.generate(), paragraphId: String, language: String, text: String?, sourceHash: String, verbatim: Bool = false, at: Date = Date())`; snake_case CodingKeys (`op_id`, `paragraph_id`, `source_hash`); `verbatim` decodes with default `false`, `text` optional (nil = tombstone).
  - `public static func TranslationRecord.isValidLanguageTag(_ s: String) -> Bool`
  - `public enum TranslationStore` (stateless namespace): `directoryURL(in:) -> URL` (`.maugham/translations/`), `fileURL(forDocId:language:deviceSlug:in:) -> URL`, `fileURLs(forDocId:language:in:) -> [URL]` (glob all devices), `languages(forDocId:in:) -> [String]`, `@MainActor append(_:forDocId:deviceSlug:in:) async throws`, `loadMerged(forDocId:language:in:) -> [TranslationRecord]` (opId-sorted, canonical-encoding tiebreak, first-wins dedup by opId), `latestByParagraph(_:) -> [String: TranslationRecord]` (HIGHEST opId per paragraphId wins; tombstone entries removed from the result).

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import MaughamCore

@MainActor
final class TranslationStoreTests: XCTestCase {
    private var projectURL: URL!
    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: projectURL) }

    func test_filename_template() {
        let url = TranslationStore.fileURL(
            forDocId: "d_chapter-01", language: "es",
            deviceSlug: DeviceSlug.unsafeForTesting("maca-1234"), in: projectURL)
        XCTAssertEqual(url.path,
            projectURL.appendingPathComponent(".maugham/translations/d_chapter-01.es.maca-1234.jsonl").path)
    }

    func test_languageTagValidation() {
        XCTAssertTrue(TranslationRecord.isValidLanguageTag("es"))
        XCTAssertTrue(TranslationRecord.isValidLanguageTag("pt-br"))
        XCTAssertFalse(TranslationRecord.isValidLanguageTag("ES"))
        XCTAssertFalse(TranslationRecord.isValidLanguageTag(""))
        XCTAssertFalse(TranslationRecord.isValidLanguageTag("e"))
        XCTAssertFalse(TranslationRecord.isValidLanguageTag("es_MX"))
    }

    func test_appendAndLoadMerged_roundTrip() async throws {
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        let rec = TranslationRecord(paragraphId: "aaaa", language: "es",
                                    text: "Hola", sourceHash: "deadbeefdeadbeef")
        try await TranslationStore.append(rec, forDocId: "doc1", deviceSlug: slug, in: projectURL)
        let loaded = TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL)
        XCTAssertEqual(loaded, [rec])
    }

    func test_loadMerged_mergesAcrossDeviceFiles_opIdOrdered_deduped() async throws {
        let a = DeviceSlug.unsafeForTesting("maca-1111")
        let b = DeviceSlug.unsafeForTesting("macb-2222")
        let r1 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "v1", sourceHash: "h1")
        let r2 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "v2", sourceHash: "h1")
        // ULID.generate() is process-monotonic: r1.opId < r2.opId
        try await TranslationStore.append(r2, forDocId: "doc1", deviceSlug: b, in: projectURL)
        try await TranslationStore.append(r1, forDocId: "doc1", deviceSlug: a, in: projectURL)
        try await TranslationStore.append(r1, forDocId: "doc1", deviceSlug: b, in: projectURL) // duplicate opId
        let loaded = TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: projectURL)
        XCTAssertEqual(loaded.map(\.opId), [r1.opId, r2.opId])
    }

    func test_latestByParagraph_lastOpIdWins_andTombstoneRemoves() {
        let r1 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "old", sourceHash: "h")
        let r2 = TranslationRecord(paragraphId: "aaaa", language: "es", text: "new", sourceHash: "h")
        let t  = TranslationRecord(paragraphId: "bbbb", language: "es", text: "x", sourceHash: "h")
        let tomb = TranslationRecord(paragraphId: "bbbb", language: "es", text: nil, sourceHash: "h")
        let latest = TranslationStore.latestByParagraph([r1, r2, t, tomb])
        XCTAssertEqual(latest["aaaa"]?.text, "new")
        XCTAssertNil(latest["bbbb"])
    }

    func test_languages_scansDirectory() async throws {
        let slug = DeviceSlug.unsafeForTesting("maca-1234")
        for lang in ["es", "fr"] {
            try await TranslationStore.append(
                TranslationRecord(paragraphId: "aaaa", language: lang, text: "x", sourceHash: "h"),
                forDocId: "doc1", deviceSlug: slug, in: projectURL)
        }
        XCTAssertEqual(TranslationStore.languages(forDocId: "doc1", in: projectURL).sorted(), ["es", "fr"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamCoreTests/TranslationStoreTests`
Expected: BUILD FAILURE — `TranslationRecord`/`TranslationStore` undefined.

- [ ] **Step 3: Implement**

`TranslationRecord.swift`:

```swift
import Foundation

/// One translated paragraph for one language. Append-only wire type; newest
/// opId per (paragraphId, language) wins. `text == nil` is a tombstone.
public struct TranslationRecord: Codable, Equatable, Sendable {
    public let opId: String
    public let paragraphId: String
    public let language: String
    public let text: String?
    public let sourceHash: String
    public let verbatim: Bool
    public let at: Date

    public init(opId: String = ULID.generate(), paragraphId: String, language: String,
                text: String?, sourceHash: String, verbatim: Bool = false, at: Date = Date()) {
        self.opId = opId; self.paragraphId = paragraphId; self.language = language
        self.text = text; self.sourceHash = sourceHash; self.verbatim = verbatim; self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case opId = "op_id", paragraphId = "paragraph_id", language, text
        case sourceHash = "source_hash", verbatim, at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opId = try c.decode(String.self, forKey: .opId)
        paragraphId = try c.decode(String.self, forKey: .paragraphId)
        language = try c.decode(String.self, forKey: .language)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        sourceHash = try c.decode(String.self, forKey: .sourceHash)
        verbatim = try c.decodeIfPresent(Bool.self, forKey: .verbatim) ?? false
        at = try c.decode(Date.self, forKey: .at)
    }

    /// Lowercase BCP-47-ish: primary subtag 2-3 letters, optional subtags.
    public static func isValidLanguageTag(_ s: String) -> Bool {
        s.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})*$", options: .regularExpression) != nil
    }
}
```

`TranslationStore.swift` — mirror `OpLogStore`'s single-source filename helpers and `mergeSortedDedup` discipline (`OpLogStore.swift:241,:376-394`). Canonical encoding uses `JSONLAppendStore<TranslationRecord>.dateEncoding` + `.sortedKeys` for the tiebreak, exactly like the op-log merge:

```swift
import Foundation

/// Sidecar store for per-paragraph translations. Per-device files under
/// `.maugham/translations/` (tripwire 17); newest-opId-wins per paragraph.
public enum TranslationStore {
    public static func directoryURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/translations")
    }

    public static func fileURL(forDocId docId: String, language: String,
                               deviceSlug: DeviceSlug, in projectURL: URL) -> URL {
        directoryURL(in: projectURL)
            .appendingPathComponent("\(docId).\(language).\(deviceSlug.raw).jsonl")
    }

    /// All device files for one (docId, language), any device slug.
    public static func fileURLs(forDocId docId: String, language: String,
                                in projectURL: URL) -> [URL] {
        let dir = directoryURL(in: projectURL)
        let prefix = "\(docId).\(language)."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jsonl") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// Distinct languages present for a doc (scans filenames).
    public static func languages(forDocId docId: String, in projectURL: URL) -> [String] {
        let dir = directoryURL(in: projectURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var langs = Set<String>()
        for n in names where n.hasPrefix("\(docId).") && n.hasSuffix(".jsonl") {
            let rest = n.dropFirst(docId.count + 1).dropLast(".jsonl".count)
            let parts = rest.split(separator: ".")
            if parts.count == 2, TranslationRecord.isValidLanguageTag(String(parts[0])) {
                langs.insert(String(parts[0]))
            }
        }
        return Array(langs)
    }

    @MainActor
    public static func append(_ record: TranslationRecord, forDocId docId: String,
                              deviceSlug: DeviceSlug, in projectURL: URL) async throws {
        let url = fileURL(forDocId: docId, language: record.language,
                          deviceSlug: deviceSlug, in: projectURL)
        try await JSONLAppendStore<TranslationRecord>(fileURL: url).append(record)
    }

    /// opId-ascending, canonical-content tiebreak, first-wins dedup by opId —
    /// same total-order discipline as OpLogStore.mergeSortedDedup.
    public static func loadMerged(forDocId docId: String, language: String,
                                  in projectURL: URL) -> [TranslationRecord] {
        var all: [TranslationRecord] = []
        for url in fileURLs(forDocId: docId, language: language, in: projectURL) {
            guard let bytes = try? Data(contentsOf: url) else { continue }
            all.append(contentsOf:
                JSONLAppendStore<TranslationRecord>.parse(bytes: bytes, dedupKey: nil, sortedBy: nil).elements)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = JSONLAppendStore<TranslationRecord>.dateEncoding
        func canonical(_ r: TranslationRecord) -> String {
            (try? enc.encode(r)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let sorted = all.sorted {
            $0.opId != $1.opId ? $0.opId < $1.opId : canonical($0) < canonical($1)
        }
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.opId).inserted }
    }

    /// Highest opId per paragraphId wins; tombstones (text == nil) remove the key.
    public static func latestByParagraph(_ records: [TranslationRecord]) -> [String: TranslationRecord] {
        var out: [String: TranslationRecord] = [:]
        for r in records.sorted(by: { $0.opId < $1.opId }) {
            if r.text == nil { out.removeValue(forKey: r.paragraphId) }
            else { out[r.paragraphId] = r }
        }
        return out
    }
}
```

Adjust to the real `JSONLAppendStore.parse` signature (`JSONLAppendStore.swift:95`) if the label spelling differs — compile errors will tell you.

- [ ] **Step 4: Run tests to verify pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamCoreTests/TranslationStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore
git commit -m "feat(translation): TranslationRecord + TranslationStore — per-device JSONL, opId LWW"
```

---

### Task 2: Hash normalization + TranslationDeriver + construct skeleton (MaughamCore)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/TranslationDeriver.swift`
- Create: `Packages/MaughamCore/Sources/MaughamCore/TranslationConstructSkeleton.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/TranslationDeriverTests.swift`, `.../TranslationConstructSkeletonTests.swift`

**Interfaces:**
- Consumes: `TranslationRecord`, `TranslationStore.latestByParagraph`, `MarkdownDisplayFilter.stripAnchors`, `StableHash.fnv1a64Hex`, `MarkdownBlockParser.parse`.
- Produces:
  - `public enum TranslationHash { static func normalize(_ text: String) -> String; static func hash(_ text: String) -> String }` — normalize = `stripAnchors` → strip each line's trailing whitespace → trim outer whitespace; hash = `fnv1a64Hex(normalize(text))`.
  - `public enum TranslationStatus: String, Codable, Sendable { case fresh, stale, missing }`
  - `public struct TranslatedDocument: Sendable { public struct Entry: Sendable { public let paragraphId: String; public let sourceText: String; public let translatedText: String?; public let status: TranslationStatus; public let verbatim: Bool }; public let language: String; public let entries: [Entry]; public let orphans: [TranslationRecord] }` plus computed `public var freshCount/staleCount/missingCount: Int`.
  - `public enum TranslationDeriver { static func derive(records: [TranslationRecord], sequence: [String], paragraphs: [String: String], language: String) -> TranslatedDocument }` — walk `sequence` (authoritative), status by comparing `record.sourceHash` to `TranslationHash.hash(paragraphs[id])`; records whose id ∉ sequence → `orphans`.
  - `public struct ConstructSkeleton: Equatable { public let blockKinds: [String]; public let strongCount: Int; public let emphCount: Int }` with `public static func of(_ text: String) -> ConstructSkeleton` and `public static func warnings(source: String, translation: String, paragraphId: String) -> [String]` (empty when skeletons match; human-readable strings when not).

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import MaughamCore

final class TranslationDeriverTests: XCTestCase {
    func test_hashNormalization_stripsAnchorsAndTrailingWhitespace() {
        XCTAssertEqual(TranslationHash.hash("Hello world"),
                       TranslationHash.hash("Hello world   "))
        XCTAssertEqual(TranslationHash.hash("Line one\nLine two"),
                       TranslationHash.hash("Line one  \nLine two\t"))
        XCTAssertEqual(TranslationHash.hash("Text <!--t-aaaaaa--> tail"),
                       TranslationHash.hash("Text  tail")) // task anchor stripped
        XCTAssertNotEqual(TranslationHash.hash("Hello"), TranslationHash.hash("Hola"))
    }

    func test_derive_statuses() {
        let paragraphs = ["aaaa": "One", "bbbb": "Two", "cccc": "Three"]
        let sequence = ["aaaa", "bbbb", "cccc"]
        let records = [
            TranslationRecord(paragraphId: "aaaa", language: "es", text: "Uno",
                              sourceHash: TranslationHash.hash("One")),
            TranslationRecord(paragraphId: "bbbb", language: "es", text: "Dos",
                              sourceHash: TranslationHash.hash("OLD TEXT")),
            TranslationRecord(paragraphId: "zzzz", language: "es", text: "Huérfano",
                              sourceHash: "x"),
        ]
        let doc = TranslationDeriver.derive(records: records, sequence: sequence,
                                            paragraphs: paragraphs, language: "es")
        XCTAssertEqual(doc.entries.map(\.status), [.fresh, .stale, .missing])
        XCTAssertEqual(doc.entries.map(\.paragraphId), sequence) // sequence order
        XCTAssertEqual(doc.orphans.map(\.paragraphId), ["zzzz"])
        XCTAssertEqual(doc.freshCount, 1); XCTAssertEqual(doc.staleCount, 1)
        XCTAssertEqual(doc.missingCount, 1)
        XCTAssertNil(doc.entries[2].translatedText)
        XCTAssertEqual(doc.entries[2].sourceText, "Three")
    }

    func test_derive_latestWinsWithinRecords() {
        let old = TranslationRecord(paragraphId: "aaaa", language: "es", text: "vieja",
                                    sourceHash: TranslationHash.hash("One"))
        let new = TranslationRecord(paragraphId: "aaaa", language: "es", text: "nueva",
                                    sourceHash: TranslationHash.hash("One"))
        let doc = TranslationDeriver.derive(records: [old, new], sequence: ["aaaa"],
                                            paragraphs: ["aaaa": "One"], language: "es")
        XCTAssertEqual(doc.entries[0].translatedText, "nueva")
    }
}

final class TranslationConstructSkeletonTests: XCTestCase {
    func test_matchingSkeleton_noWarnings() {
        XCTAssertTrue(ConstructSkeleton.warnings(
            source: "> **Doctor:** How are you feeling?",
            translation: "> **Doctora:** ¿Cómo se siente?", paragraphId: "aaaa").isEmpty)
    }
    func test_lostStrong_warns() {
        let w = ConstructSkeleton.warnings(
            source: "> **Doctor:** How are you feeling?",
            translation: "> Doctora: ¿Cómo se siente?", paragraphId: "aaaa")
        XCTAssertFalse(w.isEmpty)
        XCTAssertTrue(w[0].contains("aaaa"))
    }
    func test_blockKindChange_warns() {
        XCTAssertFalse(ConstructSkeleton.warnings(
            source: "## Session Two", translation: "Sesión dos", paragraphId: "bbbb").isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure** — same `-only-testing` pattern, both new test classes. Expected: BUILD FAILURE (types undefined).

- [ ] **Step 3: Implement**

`TranslationDeriver.swift`:

```swift
import Foundation

public enum TranslationHash {
    /// Display form (anchors stripped), per-line trailing whitespace stripped,
    /// outer whitespace trimmed. Consequence (accepted, documented): an edit
    /// that only changes trailing whitespace — including a markdown two-space
    /// hard break — does not flip staleness.
    public static func normalize(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
            .components(separatedBy: "\n")
            .map { line in
                var l = Substring(line)
                while let last = l.last, last == " " || last == "\t" { l = l.dropLast() }
                return String(l)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func hash(_ text: String) -> String {
        StableHash.fnv1a64Hex(normalize(text))
    }
}

public enum TranslationStatus: String, Codable, Sendable { case fresh, stale, missing }

public struct TranslatedDocument: Sendable {
    public struct Entry: Sendable {
        public let paragraphId: String
        public let sourceText: String
        public let translatedText: String?
        public let status: TranslationStatus
        public let verbatim: Bool
    }
    public let language: String
    public let entries: [Entry]
    public let orphans: [TranslationRecord]

    public var freshCount: Int { entries.lazy.filter { $0.status == .fresh }.count }
    public var staleCount: Int { entries.lazy.filter { $0.status == .stale }.count }
    public var missingCount: Int { entries.lazy.filter { $0.status == .missing }.count }
}

public enum TranslationDeriver {
    /// `sequence` is authoritative order (hard invariant). Freshness is derived,
    /// never stored.
    public static func derive(records: [TranslationRecord], sequence: [String],
                              paragraphs: [String: String], language: String) -> TranslatedDocument {
        let latest = TranslationStore.latestByParagraph(records)
        let inSequence = Set(sequence)
        var entries: [TranslatedDocument.Entry] = []
        for id in sequence {
            let source = paragraphs[id] ?? ""
            if let rec = latest[id] {
                let status: TranslationStatus =
                    rec.sourceHash == TranslationHash.hash(source) ? .fresh : .stale
                entries.append(.init(paragraphId: id, sourceText: source,
                                     translatedText: rec.text, status: status,
                                     verbatim: rec.verbatim))
            } else {
                entries.append(.init(paragraphId: id, sourceText: source,
                                     translatedText: nil, status: .missing, verbatim: false))
            }
        }
        let orphans = records.filter { !inSequence.contains($0.paragraphId) }
        return TranslatedDocument(language: language, entries: entries, orphans: orphans)
    }
}
```

`TranslationConstructSkeleton.swift`:

```swift
import Foundation

/// Cheap structural fingerprint used to warn when a translation drops or adds
/// markdown constructs (a lost `**bold**` speaker label silently reclassifies
/// typography downstream). Warning tier only — never blocks a write.
public struct ConstructSkeleton: Equatable {
    public let blockKinds: [String]
    public let strongCount: Int
    public let emphCount: Int

    public static func of(_ text: String) -> ConstructSkeleton {
        let stripped = MarkdownDisplayFilter.stripAnchors(text)
        let blocks = MarkdownBlockParser.parse(stripped)
        // Block kind = the case name of each parsed block.
        let kinds = blocks.map { String(describing: $0).components(separatedBy: "(")[0] }
        // Delimiter counting: "**"/"__" pairs = strong; leftover single "*"/"_"
        // flanked by non-space = emph. Deliberately dumb and deterministic.
        func counts(_ s: String) -> (strong: Int, emph: Int) {
            var strong = 0, emphMarkers = 0
            let chars = Array(s)
            var i = 0
            while i < chars.count {
                if chars[i] == "*" || chars[i] == "_" {
                    if i + 1 < chars.count, chars[i + 1] == chars[i] {
                        strong += 1; i += 2; continue
                    }
                    emphMarkers += 1
                }
                i += 1
            }
            return (strong / 2, emphMarkers / 2)
        }
        let c = counts(stripped)
        return ConstructSkeleton(blockKinds: kinds, strongCount: c.strong, emphCount: c.emph)
    }

    public static func warnings(source: String, translation: String,
                                paragraphId: String) -> [String] {
        let s = of(source), t = of(translation)
        var out: [String] = []
        if s.blockKinds != t.blockKinds {
            out.append("¶\(paragraphId): block structure changed (source \(s.blockKinds) → translation \(t.blockKinds))")
        }
        if s.strongCount != t.strongCount {
            out.append("¶\(paragraphId): **strong** run count changed (\(s.strongCount) → \(t.strongCount))")
        }
        if s.emphCount != t.emphCount {
            out.append("¶\(paragraphId): *emphasis* run count changed (\(s.emphCount) → \(t.emphCount))")
        }
        return out
    }
}
```

Check `MarkdownBlockParser.parse`'s actual return type (`Packages/MaughamCore/Sources/MaughamCore/MarkdownBlockParser.swift`) and derive `kinds` from its real block enum cases rather than `String(describing:)` if the enum exposes a cleaner discriminator.

- [ ] **Step 4: Run tests to verify pass** — both classes green.
- [ ] **Step 5: Run the PHONE scheme too** (MaughamCore changed): full `MaughamPhone` test command from Global Constraints. Expected: PASS.
- [ ] **Step 6: Commit** — `feat(translation): hash normalization, TranslationDeriver, construct skeleton`

---

### Task 3: MCP `write_translation` (+ catalog 48→49)

**Files:**
- Create: `Maugham/MCP/Tools/TranslationTools.swift`
- Modify: `Maugham/MCP/MCPTool.swift:36-85` (catalog), `MaughamTests/MCP/MCPToolsListSmokeTest.swift:19` (48→49), `Maugham/MCP/AREA.md` (count prose)
- Test: `MaughamTests/MCP/Tools/WriteTranslationToolTests.swift`

**Interfaces:**
- Consumes: `TranslationStore`, `TranslationHash`, `ConstructSkeleton`, `decodeParams`/`resolveProject` (`MCPToolHelpers.swift`), `MCPError`, `DeviceSlug.make(from: MacDeviceID.current)`, live `Document` via `entry.store.documentStore?.document(forDocId:)`, closed via `entry.store.derivedCache.state(forDocId:in:)`.
- Produces: `public enum WriteTranslationTool: MCPTool`, `method = "write_translation"`. Also a shared helper other translation tools reuse:
  `@MainActor func currentParagraphState(projectId:documentId:registry:) throws -> (sequence: [String], paragraphs: [String: String], projectURL: URL)` — open doc → `(doc.sequence, doc.paragraphs, url)`; closed → `derivedCache.state` fields. NEVER reads the `.md` (tripwire 20).

Input schema (string literal):

```json
{"type":"object","properties":{
  "project_id":{"type":"string"},"document_id":{"type":"string"},
  "language":{"type":"string","description":"lowercase tag, e.g. es, pt-br"},
  "entries":{"type":"array","items":{"type":"object","properties":{
    "paragraph_id":{"type":"string"},"text":{"type":"string"},
    "verbatim":{"type":"boolean","description":"copy current source text as the translation (chrome idiom)"}},
    "required":["paragraph_id"]}}},
 "required":["project_id","document_id","language","entries"]}
```

Behavior (each numbered point needs a test):
1. Invalid language tag → `MCPError.invalidArgument("invalid language tag: …")`.
2. Entry with neither `text` nor `verbatim:true`, or both → `invalidArgument` naming the paragraph id.
3. **All-or-nothing:** collect every `paragraph_id` not in the current `sequence`; if any, throw `invalidArgument("unknown paragraph ids: …")` listing ALL of them; nothing appended.
4. For each entry: `sourceHash = TranslationHash.hash(currentParagraphText)` (server-stamped); `verbatim` entries get `text = currentParagraphText`, `verbatim = true`.
5. Append one `TranslationRecord` per entry via `TranslationStore.append` with `DeviceSlug.make(from: MacDeviceID.current)`.
6. Non-verbatim entries: `ConstructSkeleton.warnings(source:translation:paragraphId:)` collected.
7. Response JSON: `{"written": N, "language": "es", "warnings": [ ... ]}`.

- [ ] **Step 1: Write failing tests.** Model the harness on an existing tool test in `MaughamTests/MCP/Tools/` (e.g. the add_query/add_comment tests) — copy its registry + temp-project fixture setup verbatim. Cases: happy-path batch of 2 (assert both records on disk via `TranslationStore.loadMerged`, hashes match `TranslationHash.hash` of the fixture paragraphs); unknown-id all-or-nothing (assert error message lists both bad ids AND store is empty); verbatim entry copies source text; construct-drift warning present when translation drops a `**`; invalid tag rejected.
- [ ] **Step 2: Run to verify failure.** `-only-testing:MaughamTests/MCP/Tools/WriteTranslationToolTests` → build failure (tool undefined).
- [ ] **Step 3: Implement** `TranslationTools.swift` with `WriteTranslationTool` + the shared `currentParagraphState` helper, following `AddQueryTool` (`AnnotationCreationTools.swift:107-150`) for Params/decode/error idioms. Add `WriteTranslationTool.self` to `MCPToolCatalog.all`. Description should end with: `"See get_help topic 'translation-pass' for the translation workflow."`
- [ ] **Step 4: Bump counts.** `MCPToolsListSmokeTest.swift:19` → 49; `Maugham/MCP/AREA.md` "Tool catalogue (48)" → 49 and any other `48` prose (lines ~84/86/148/175).
- [ ] **Step 5: Run** `-only-testing:MaughamTests/MCP` (whole MCP suite — catches `MCPCatalogConsistencyTests` schema validation + smoke count). Expected: PASS.
- [ ] **Step 6: Commit** — `feat(translation): write_translation MCP tool (catalog 49)`

---

### Task 4: MCP `read_translation` + `translation_status` (+ catalog 49→51)

**Files:**
- Modify: `Maugham/MCP/Tools/TranslationTools.swift`, `Maugham/MCP/MCPTool.swift`, `MaughamTests/MCP/MCPToolsListSmokeTest.swift` (→51), `Maugham/MCP/AREA.md`
- Test: `MaughamTests/MCP/Tools/ReadTranslationToolTests.swift`, `.../TranslationStatusToolTests.swift`

**Interfaces:**
- Consumes: Task 3's `currentParagraphState`, `TranslationDeriver`, `MCPResponseBudget.enforce` (`Maugham/MCP/MCPResponseBudget.swift:40`).
- Produces: `ReadTranslationTool` (`method = "read_translation"`), `TranslationStatusTool` (`method = "translation_status"`).

`read_translation` schema: `{project_id, document_id, language, status?}` (`status` enum-described in the property description: `"fresh"|"stale"|"missing"` — omit for all). Response per entry: `{"paragraph_id","source_text","translated_text","status","verbatim"}` in sequence order, wrapped `{"language","entries":[…],"orphan_count":N}`. **Final encode goes through `MCPResponseBudget.enforce(encoded, hint: "filter with status=stale or status=missing to reduce payload")`** — read_translation returns whole-doc data and must self-enforce the 900 KB budget like `ReadDocumentTool` (`DocumentTools.swift:120-124`).

`translation_status` schema: `{project_id, document_id?}` — with `document_id`: one doc; without: every manuscript doc in the project (walk `ProjectStore.collectDocuments(in: manifest.structure)` skipping `.reference`, same walk as `ProjectStoreASTSource.orderedPieces`). Response per doc per language: `{"document_id","language","fresh":N,"stale":N,"missing":N,"orphans":N,"open_queries":N}` where `open_queries` counts annotations with `kind == .query`, `status == .open`, and `language == <lang>` (the field lands in Task 5 — until then return 0; Task 5 flips it on and tests it).

- [ ] **Step 1: Write failing tests.** read: status filter returns only stale entries; unfiltered returns all in sequence order; unknown language returns empty entries (not an error — status "missing" for all). status: counts across two languages; project-wide walk covers 2 docs.
- [ ] **Step 2: Verify failure.**
- [ ] **Step 3: Implement both tools; catalog 49→51; smoke test →51; AREA.md prose →51.** Tool descriptions reference `get_help` topic `translation-pass`.
- [ ] **Step 4: Run** `-only-testing:MaughamTests/MCP`. Expected: PASS.
- [ ] **Step 5: Commit** — `feat(translation): read_translation + translation_status (catalog 51)`

---

### Task 5: `add_query` language tag → Annotation.language

**Files:**
- Modify: `Maugham/MCP/Tools/AnnotationCreationTools.swift:107-150` (Params + schema), `Packages/MaughamCore/Sources/MaughamCore/Annotation.swift` (field), `Packages/MaughamCore/Sources/MaughamCore/AnnotationDeriver.swift` (populate)
- Test: extend the existing add_query tests in `MaughamTests/MCP/Tools/`; add `MaughamCoreTests/AnnotationDeriverLanguageTests.swift`

**Interfaces:**
- Produces: `Annotation.language: String?` (new memberwise-init param, default `nil` — `Annotation` is NOT Codable, so this is a pure struct change with no wire-schema or Mac+phone pairing impact); `add_query` accepts optional `"language"`.

Mechanism: `add_query`'s whole `Params` already flows into the op's `toolArgs` provenance via `annotationToolArgsJSON(params)` (`AnnotationCreationTools.swift:194-200`) — adding `language: String?` to `Params` + `"language":{"type":"string"}` to the schema (NOT to `required`) persists it with **zero op-schema change**. `AnnotationDeriver` then extracts it when building the in-memory `Annotation`: where the deriver constructs an `Annotation` from a `claudeQuery` op, decode the op's `toolArgs` JSON (`[String: JSONValue]`-style; a two-line `JSONDecoder` into a `private struct ToolArgsLanguage: Decodable { let language: String? }`) and pass it to the `Annotation` init. Validate the tag with `TranslationRecord.isValidLanguageTag` at the tool layer (reject invalid; absent = nil).

- [ ] **Step 1: Failing tests.** Core: an op whose toolArgs contains `"language":"es"` derives an Annotation with `language == "es"`; toolArgs without it → nil; malformed toolArgs JSON → nil (never throws). Tool: add_query with `language: "es"` round-trips into `doc.annotations` with `language == "es"`; invalid tag → `invalidArgument`.
- [ ] **Step 2: Verify failure. Step 3: Implement. Step 4: Run** `-only-testing:MaughamCoreTests/AnnotationDeriverLanguageTests -only-testing:MaughamTests/MCP` **plus the phone scheme** (MaughamCore changed). Expected: PASS — phone compiles unchanged because the new struct field has a default.
- [ ] **Step 5:** Flip Task 4's `open_queries` count to use `annotation.language` and add the test case.
- [ ] **Step 6: Commit** — `feat(translation): add_query language tag, surfaced on in-memory Annotation`

---

### Task 6: PublishConfig `language_overrides` + `{language}` token + `Publication.language`

**Files:**
- Modify: `Maugham/Publish/PublishConfig.swift`, `Maugham/Publish/OutputFilenameBuilder.swift`, `Maugham/Publish/Publication.swift`, `Maugham/Publish/PublishConfigValidator.swift`
- Test: `MaughamTests/Publish/PublishConfigLanguageTests.swift` (new), extend `MaughamTests/Publish/` filename/validator tests

**Interfaces:**
- Produces:
  - `PublishConfig.LanguageOverride: Codable, Equatable, Sendable { public var metadata: [String: String] }` — mirrors `EPUBOverrides` (`PublishConfig.swift:221`): default `[:]`, custom `encode(to:)`, snake_case key `metadata`.
  - `PublishConfig.languageOverrides: [String: LanguageOverride]` (CodingKey `language_overrides`, default `[:]`; top-level decode is synthesized, so add `= [:]`… **NB the top-level `init(from:)` is synthesized from CodingKeys — a plain default won't survive decode of old configs. Add `decodeIfPresent` handling by writing an explicit top-level `init(from:)` OR make the property optional. Follow whichever pattern review of `PublishConfig.swift` shows is least invasive; the test locks the requirement: old config.json without the key decodes with `[:]`.**
  - `PublishConfig.effectiveMetadata(language: String?) -> Metadata` — returns `metadata` unchanged when `language == nil`; otherwise copies `metadata`, sets `language` field to the tag, then applies the override dict's known keys: `title`, `subtitle`, `author`, `copyright`, `isbn`, `publisher`, `year` (Int-parsed; unparseable ignored), `language`, `keywords` (comma-split, trimmed).
  - `OutputFilenameBuilder.make(config:format:label:language:)` — new `language: String?` parameter; substitutes `{language}` with the tag or `""`; **also**, when `language != nil` and the template does NOT contain `{language}`, insert `-<lang>` before `.{ext}` so editions can't silently collide with the source edition. Existing call sites pass `language: nil`.
  - `Publication.language: String?` — `decodeIfPresent`, snake_case `language`.
  - Validator: each `language_overrides` key must pass `TranslationRecord.isValidLanguageTag` → `ValidationError(field: "language_overrides.<key>", …)`.

- [ ] **Step 1: Failing tests:** old-config decode tolerance (raw JSON fixture without the key → `[:]`); effectiveMetadata override precedence (`title` overridden, `author` inherited, dc-language: tag wins, explicit override beats tag); `{language}` token substitution; no-token auto-suffix collision guard; Publication JSONL decode tolerance (line without `language`); validator rejects `"ES"` key.
- [ ] **Step 2–4: Fail → implement → pass** (`-only-testing:MaughamTests/Publish`).
- [ ] **Step 5: Commit** — `feat(translation): language_overrides, {language} filename token, Publication.language`

---

### Task 7: Compile `language`/`allow_stale` threading + snapshot fold

**Files:**
- Modify: `Maugham/MCP/Tools/CompileTools.swift` (Params+schema: `language?`, `allow_stale?` default false), `Maugham/Publish/CompileOrchestrator.swift` (`compile(format:label:language:allowStale:)`), `Maugham/Publish/PDFCompiler.swift` + `Maugham/Publish/EPUBCompiler.swift` (accept `language: String?`), `Maugham/Publish/PreviewCompiler.swift` if it calls the same seams
- Test: `MaughamTests/Publish/CompileLanguageThreadingTests.swift`

Threading rules (each is a test):
1. `CompileOrchestrator.compile` computes `let effective = config` with `metadata = config.effectiveMetadata(language: language)` **before** `snapshotStore.capture(config:)` — the snapshot freezes the language-effective config, so **republish reproduces the edition with zero further changes** (`Republisher` reads `snap.config`).
2. `Publication` is built with `language: language`.
3. `OutputFilenameBuilder.make(..., language: language)`.
4. EPUB dc:language: `EPUBCompiler` uses `config.metadata.language` as today — correct automatically because the orchestrator handed it the effective config (test asserts OPF contains `<dc:language>es</dc:language>`).
5. PDF `build/metadata.tex` gains `\renewcommand{\MaughamLanguage}{<tag-or-en>}` next to the existing renewcommands (`PDFCompiler.swift:54-65`) so edition templates can branch on it.
6. `language == nil` compiles are byte-identical to before (regression guard: run existing `PublishBodyRenderingEndToEndTests` unchanged).

- [ ] **Steps: failing tests → implement → `-only-testing:MaughamTests/Publish` green → commit** — `feat(translation): per-compile language threading, snapshot fold, republish-safe`

---

### Task 8: AST substitution in `ProjectStoreASTSource`

**Files:**
- Modify: `Maugham/Publish/ProjectStoreASTSource.swift`, `Maugham/Publish/CompileOrchestrator.swift` + `Maugham/MCP/Tools/CompileTools.swift` (construct source with language)
- Test: `MaughamTests/Publish/ASTTranslationSubstitutionTests.swift`

**Interfaces:**
- `ProjectStoreASTSource.init(projectStore:language:allowStale:)` — both default nil/false; stored.
- In `pieceRef(for:)` (`ProjectStoreASTSource.swift:31-48`), when `language != nil`: get `(sequence, paragraphs)` — open doc → live `Document`; closed → `derivedCache.state(forDocId:in:)` — then `TranslationStore.loadMerged` → `TranslationDeriver.derive` → build `displayText` as: for each entry, `entry.translatedText ?? entry.sourceText` (missing/stale fallback is legal here ONLY because the coverage gate (Task 9) has already blocked unless `allowStale`), joined with `"\n\n"`. When `language == nil`: existing materialize path untouched.

**The load-bearing invariant test — identity-translation equivalence:** for a fixture doc, write `verbatim`-style identity records for every paragraph, then assert
`sourceWithLanguage.pieceRef(for: piece).displayText` (after `MarkdownDisplayFilter.stripAnchors`, i.e. what `ProjectASTBuilder` sees at `ProjectASTBuilder.swift:51`) produces an AST **equal** to the `language: nil` path's AST via `ProjectASTBuilder.build`. This pins the `"\n\n"` join against the Materializer's block semantics — if they diverge (e.g. fountain dialogue blocks), the test fails and the join must be fixed to match `stripAnchors(materialize())`, not the test loosened. Include one prose AND one fountain fixture (fountain: character+dialogue in one paragraph, scene heading in another).

- [ ] **Steps: failing tests (incl. both identity-equivalence fixtures + a real substitution asserting translated text lands in AST nodes) → implement → green → commit** — `feat(translation): AST translation substitution with identity-equivalence pin`

---

### Task 9: Coverage gate + Fountain element-drift warnings

**Files:**
- Create: `Maugham/Publish/TranslationCoverage.swift`
- Modify: `Maugham/Publish/CompileOrchestrator.swift` (gate between config-load and format branch — model on the version-collision guard at `CompileOrchestrator.swift:55-75`)
- Test: `MaughamTests/Publish/TranslationCoverageGateTests.swift`

**Interfaces:**

```swift
@MainActor
enum TranslationCoverage {
    struct Report {
        struct PieceGap { let pieceID: String; let title: String
                          let stale: [String]; let missing: [String] }   // ¶ids
        let gaps: [PieceGap]
        let fountainDriftWarnings: [String]
        var isBlocked: Bool { gaps.contains { !$0.stale.isEmpty || !$0.missing.isEmpty } }
    }
    static func check(projectStore: ProjectStore, language: String) -> Report
}
```

Behavior:
1. Walk the same pieces as `ProjectStoreASTSource.orderedPieces()`; derive each; collect stale/missing ¶id lists per piece.
2. **Zero-layer guard:** if NO piece has any translation record for the language → gate fails with a single error `"no translation layer for '<lang>' — run write_translation first"` (never emit a source-language book labeled as an edition).
3. Fountain drift: for each fountain-mode piece with full coverage, tokenize source text and substituted text with `FountainTokenizer().parse` and compare `lines.map(\.element)` (`ScreenplayElement`, `FountainLine.element`); on mismatch produce a warning naming the piece + first divergent index + both element names.
4. Orchestrator: when `language != nil`, run `check`; if `report.isBlocked && !allowStale` → `jobManager.fail` with one `TectonicLogParser.Diagnostic(level: .error, …)` per piece-gap, message format `"<title>: N stale (¶a, ¶b), M missing (¶c)"` → returns `.failed` (surfaces via `CompileResponseEncoder.encodeFailed` unchanged). If `allowStale`, convert gaps to warnings itemizing every fallback paragraph; drift warnings always attach to `warnings`.

- [ ] **Steps: failing tests (blocked compile lists exact ¶ids; allow_stale passes with itemized warnings; zero-layer guard; fountain ALL-CAPS action→character drift warns; fully-fresh compile passes clean) → implement → green → commit** — `feat(translation): blocking coverage gate + fountain element-drift warnings`

---

### Task 10: Language-suffixed template resolution

**Files:**
- Create: `Maugham/Publish/LanguageSuffixedFile.swift`
- Modify: `Maugham/Publish/PDFCompiler.swift` (template selection at `:76`), `Maugham/Publish/EPUBCompiler.swift` (css at `:61`), `Maugham/Publish/CompileOrchestrator.swift` (style_file rewrite)
- Test: `MaughamTests/Publish/LanguageSuffixedFileTests.swift`

**Interfaces:**

```swift
enum LanguageSuffixedFile {
    /// "template.tex" + "es" → "template.es.tex" if it exists under dir, else base.
    static func resolve(_ filename: String, language: String?, under dir: URL) -> String
}
```

Application points:
1. `PDFCompiler`: `templateURL` resolves via `resolve("template.tex", language:, under: publish)`.
2. `EPUBCompiler`: `resolve("styles.css", …)`.
3. **Per-piece style_file:** `LaTeXBodyEmitter` has no filesystem access, so the orchestrator rewrites the in-memory effective config before emit: for each `sections[*].styleFile`, replace with `resolve(styleFile, language:, under: publishDir)`. Emitter untouched → EMISSION byte-gate untouched.
4. **`LaTeXSafeFilename` dot-check:** add a direct test that `LaTeXSafeFilename("october-passed-me-by.es") != nil`; if the guard rejects dots, widen it (with an injection-safety test that `..`/`/` still fail).
5. `frontmatter.tex` and other `\input` partials are intentionally NOT Swift-resolved: a `template.es.tex` references `frontmatter.es` itself — that's the per-edition template job (spec §4; skill documents it).

- [ ] **Steps: failing tests (present→suffixed, absent→base, nil→base; PDF template pick; css pick; style_file rewrite honors existence; safe-filename dots) → implement → green → run FULL Mac publish suite (`-only-testing:MaughamTests/Publish`) including `EmissionContractTests` byte-gate → commit** — `feat(translation): language-suffixed template/style resolution`

---

### Task 11: Editor translation-review posture (read-only surface swap)

**Files:**
- Modify: `Maugham/Editor/EditorControl.swift` (`translationLanguage: String?`), `Maugham/Editor/EditorEditPolicy.swift`, `Maugham/Editor/EditorCoordinator.swift` (flag + setter), `Maugham/Views/EditorHost.swift`
- Test: `MaughamTests/Editor/TranslationReviewPostureTests.swift` (+ extend `EditorEditPolicy` unit tests)

Design (from the WF1 posture template — this task's reviewer should read `Maugham/Editor/AREA.md` first):
1. `EditorEditPolicy.allowsTextMutation(isReviewMode:lockEditing:isTranslationReview:)` — returns false when any is true. Update the single choke-point call in `textView(_:shouldChangeTextIn:replacementString:)` (`EditorCoordinator.swift:842-845`).
2. Coordinator: `private(set) var isTranslationReview = false` + `func setTranslationReview(_:)` — plain stored flags, no observers (tripwire 2).
3. **Surface text selection in EditorHost:** add `@State private var translatedSurfaceText: String? = nil`. When `control.translationLanguage` becomes non-nil (a dedicated `.onChange`), compute once: `TranslationStore.loadMerged` + `TranslationDeriver.derive` against the live doc's `sequence`/`paragraphs`, build the render (entry order; translated text, or sourceText for missing), store in the @State. The EditorSurface `text:` value becomes `translatedSurfaceText ?? doc.displayText`; the binding's `set` gains a first-line guard `guard translatedSurfaceText == nil else { return }` (defense in depth — the membrane already blocks all edits). Buffer swap on mode change flows through the EXISTING `EditorSurface.updateNSView` `applyExternalText` site (`EditorSurface.swift:337-340`) — a mode change is exactly the whole-buffer-replace it exists for; **no new call site** (census stays at one), and the harness pin (typing never triggers it) is unaffected because typing is blocked entirely.
4. This `translatedSurfaceText` is deliberate one-way threaded state, NOT parallel observable state feeding the binding (tripwire 6): it is recomputed only on explicit events (language selected, annotationsVersion tick while in mode), never observed from `displayText`.

- [ ] **Step 1: Failing tests.** Policy unit: all 8 flag combinations. Harness (`EditorIntegrationHarness`): enter translation review → simulated typing mutates NOTHING (op log length unchanged, `doc.displayText` unchanged) wrapped in the harness's op-count assertions; exit mode → typing works again; `assertNoApplyExternalText` around the typing (not around the mode flip).
- [ ] **Step 2–4: Fail → implement → green.** Run `-only-testing:MaughamTests/Editor` AND the tripwire suite `-only-testing:MaughamTests/TripwireGrepTests` (census must still count exactly one `applyExternalText` production call site).
- [ ] **Step 5: Commit** — `feat(translation): read-only translation-review posture (membrane-enforced, zero ops)`

---

### Task 12: Staleness badges + dimmed missing paragraphs

**Files:**
- Create: `Maugham/Editor/TranslationBadgeOverlayView.swift`
- Modify: `Maugham/Editor/EditorCoordinator+ReviewRender.swift` neighborhood (install/remove reconciliation modeled on `EditorSurface.swift:352-358`), `Maugham/Views/EditorHost.swift` (thread per-paragraph status list into the coordinator via `EditorControl`)
- Test: `MaughamTests/Editor/TranslationBadgeMappingTests.swift`

Approach: an overlay `NSView` over the left `textContainerInset` (the `ElementGutterView`/review-overlay pattern — visible-range-only, `¶id → UTF-16 range` via the existing `reviewParagraphRangeProvider`/`doc.displayRange(forParagraphId:)` wiring). Because the surface shows TRANSLATED text, ranges must come from the translated render: EditorHost passes the coordinator an ordered `[(paragraphId: String, status: TranslationStatus)]` plus the translated text; the overlay computes paragraph ranges by walking the translated text's blocks in the same order (same `"\n\n"` join as the render — expose the range computation as a pure function `TranslationBadgeLayout.ranges(entries:renderedText:) -> [(String, NSRange, TranslationStatus)]` so it's unit-testable without AppKit). Draw: amber dot for `.stale`, gray hollow dot + `.tertiaryLabelColor` temporary-attribute dimming over the paragraph range for `.missing` (dimming applied in the coordinator when in translation mode, cleared on exit). Fresh draws nothing.

- [ ] **Steps: failing unit tests for `TranslationBadgeLayout.ranges` (offsets across multi-line paragraphs, missing entries using source text) → implement overlay + dimming → green → commit** — `feat(translation): stale badges + dimmed missing paragraphs in review surface`

---

### Task 13: Language picker + mode entry/exit

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift` (`maughamEnterTranslationReview` payload `["language": String]`, `maughamExitTranslationReview`), `Maugham/MaughamApp.swift` (menu command in the `CommandGroup(after: .toolbar)` at `:177`: submenu "Translation Review" listing `TranslationStore.languages(forDocId:in:)` for the active doc + "Off"), `Maugham/Views/ProjectWindow.swift` (a `TranslationReviewModifier` ViewModifier — mirror `EditorControlMirrorModifier` `:1346` — owning `@State translationLanguage: String?`, receiving the events via `.onKeyWindowCommand`, mirroring one-way into `editorControl.translationLanguage`; plus a top `.safeAreaInset` indicator next to `ReviewModeIndicator` (`:702-710`) showing "Reviewing: Español (es) — N stale" with an exit button)
- Test: `MaughamTests/Editor/TranslationReviewEventTests.swift` (event post/receive round-trip via `MaughamEvent.observe`)

Notes: coordinator ALSO subscribes directly (the `reviewToggleObserver` template, `EditorCoordinator.swift:475-481`) for a synchronous membrane flip — the `control.*` mirror lands a frame later. Language display names via `Locale.current.localizedString(forLanguageCode:)` with the raw tag as fallback.

- [ ] **Steps: failing event tests → implement → green → `xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO` (ProjectWindow.body changed — Release type-check budget) → commit** — `feat(translation): language picker, review-mode entry/exit`

---

### Task 14: Right-pane Translation segment (source + queries + reply)

**Files:**
- Create: `Maugham/Views/TranslationReviewPane.swift`
- Modify: `Maugham/Views/DetailPaneToggle.swift` (new `DetailSegment.translation` case, icon `character.book.closed`, ⌘⌥8, help "Translation"), `Maugham/Views/ProjectWindow.swift` (segment content case; auto-select the segment on entering translation review)
- Test: `MaughamTests/Views/TranslationReviewPaneLogicTests.swift` (extract pane view-model logic as testable pure functions)

Pane content, driven by `doc.paragraphId(at: doc.cursorLocation)` (the footer pattern, `ProjectWindow.swift:744-748`) — note the cursor is in the TRANSLATED text, so map cursor→paragraph through `TranslationBadgeLayout.ranges` (Task 12), not `doc.paragraphId(at:)`:
1. **Source section:** selected paragraph's `sourceText` as read-only `Text` (serif, the `RewindWindow.swift:189-191` idiom) + status chip (fresh/stale/missing).
2. **Queries section:** `doc.annotations` filtered `kind == .query && language == control.translationLanguage && status == .open`, each row with body + Reply button → `QueryReplySheet` (copy from `AnnotationsPane.swift:684`) → `document.acceptAnnotation(id:userResponse:undoManager:)` (`AnnotationsPane.swift:157-159`).
3. Empty states use `ContentUnavailableView` — **must chain `.frame(maxWidth: .infinity, maxHeight: .infinity)` and the pane's outer VStack needs `alignment: .top`** (tripwire 15; `TripwireGrepTests.test_contentUnavailableViewAlwaysChainsFullFrame` enforces).

- [ ] **Steps: failing logic tests (cursor→entry mapping, query filter incl. language) → implement → green incl. TripwireGrepTests → Release build (ProjectWindow.body touched) → commit** — `feat(translation): right-pane translation segment with source + query reply`

---

### Task 15: `translation-pass` skill + ADR 0024 + docs sweep

**Files:**
- Create: `docs/skills/translation-pass/SKILL.md`, `docs/adr/0024-translation-layer.md`, `docs/guide/` topic file for translation review (follow existing topic-file format in `docs/guide/`)
- Modify: `Maugham/MCP/AREA.md` (tool list + skills list), `CLAUDE.md` (MCP tool count 48→51 in the per-area pointer row), `docs/roadmap.md`, `docs/product.md`/`docs/problem-map.md` if they enumerate capabilities
- Test: `MaughamTests/MCP/SkillsExtensionTests.swift` picks up the new skill automatically (strict dev `SkillIndex.bundled()` fails on malformed frontmatter); add one assertion that `translation-pass` is listed.

SKILL.md (frontmatter `name: translation-pass`, one-line trigger-shaped `description`), intent-first per `feedback_skill_authoring_intent` — deliverable + ranked what-matters + tools-as-affordances, NOT step-by-step ceremony. It must carry: the loop (`translation_status` → `read_translation` status-filtered → batch `write_translation` → `compile` with `language` → repeat until the gate passes); conventions (identity-translate chrome with `verbatim: true`; preserve inline markers/speaker labels — the construct-parity warning is the tripwire, heed it; author `.es.tex` template variants for language-coupled templates — the gate does NOT cover template text, that's your job; raise voice/register decisions as `add_query` with `language` rather than guessing). Verify every tool-name/param mention against the actual schemas (Task 3/4/7 as merged).

ADR 0024 covers: second Claude-parallel data plane; derived-never-stored freshness with server-stamped hashes; blocking coverage gate; language-suffixed template rule; per-compile language with snapshot fold (republish-safe); read-only review posture rationale.

- [ ] **Steps: write files → `./gen.sh` (bundled docs changed) → run `-only-testing:MaughamTests/MCP/SkillsExtensionTests` → sweep sibling docs for now-false claims (Default workflow rule 10) → commit** — `docs(translation): translation-pass skill, ADR 0024, docs sweep`

---

### Task 16: End-to-end integration + full-suite gate

**Files:**
- Test: `MaughamTests/Integration/TranslationFlowTests.swift` (new)

- [ ] **Step 1: Write the end-to-end test:** create temp project → doc with 3 paragraphs → write_translation (2 real + 1 verbatim) → all fresh → edit one paragraph via `doc.setParagraph` → translation_status shows 1 stale → compile with language → BLOCKED listing that ¶id → retranslate it → compile passes → `Publication.language == "es"`, output filename contains the language, EPUB OPF/dc:language correct (pick pdf OR epub per assertion, both covered across cases).
- [ ] **Step 2: Full Mac suite:** `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` — everything, including all tripwire greps and the EMISSION byte-gate. Expected: PASS.
- [ ] **Step 3: Full phone suite** (MaughamCore changed across the branch). Expected: PASS.
- [ ] **Step 4: Release build** (`-configuration Release build CODE_SIGNING_ALLOWED=NO`). Expected: BUILD SUCCEEDED.
- [ ] **Step 5: Commit** — `test(translation): end-to-end flow — write → stale → gate → retranslate → publish`

**After Task 16 (not a task — process):** whole-branch review (Default workflow rule 9 — per-task reviews cannot see emergent interactions), then the acceptance smoke: via `mcp__maugham_test__*` on the dev app, produce **Playlist, Volumen Uno** — Spanish edition of the real Playlist project **without touching the English source or shared templates** — exercising chrome `verbatim`, construct parity, fountain drift, `.es.tex` templates, `language_overrides` metadata, and the gate loop, with `read_publication_page` as the visual check. User runs the final manual smoke.
