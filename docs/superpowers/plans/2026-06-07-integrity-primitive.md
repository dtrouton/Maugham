# Integrity Primitive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, Foundation-level corruption-detection layer in MaughamCore that turns today's *silent* op-log corruption into a *surfaced, quarantined, verifiable* signal — the "alarm" half of the Backup & Integrity milestone.

**Architecture:** All work lands in `Packages/MaughamCore` (Foundation-only substrate shared by Mac + phone, so the detection is single-sourced — tripwire 19). We make the op-log parser report which lines it skipped (non-breaking: a new `loadDiagnosed()` alongside the existing `load()`), add a content-hashing manifest primitive, add three pure consistency checks (dangling checkpoint pointers, iCloud conflict-twins, op-log parse skips), and tie them into one `ProjectIntegrity.check(projectURL:) → IntegrityReport`. No UI in this plan; the "Verify project" action and health indicator are Plan 2 (their placement is an open question in the spec). Restore/backup is Plan 2.

**Tech Stack:** Swift, async/await, `@MainActor`-isolated stores, `CryptoKit` (SHA-256 — a deliberate, justified addition to MaughamCore; available on both macOS and iOS, so it does not break the shared-package contract), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-07-backup-and-integrity-design.md` (§4 Integrity primitive; this plan covers §4.1, §4.2, §4.4, §4.5, and the §4.7 aggregator data model — *not* the §4.7 UI, §4.3 manifest-shadow, or §4.6 derive-and-compare, which are deferred to Plan 2).

---

## File Structure

**Create:**
- `Packages/MaughamCore/Sources/MaughamCore/ParseDiagnostics.swift` — value type describing lines a JSONL load skipped (raw bytes + best-effort offset).
- `Packages/MaughamCore/Sources/MaughamCore/IntegrityQuarantine.swift` — writes skipped raw lines to `.maugham/conflicts/quarantine/` for forensic recovery.
- `Packages/MaughamCore/Sources/MaughamCore/MerkleManifest.swift` — flat-with-root content manifest (`MerkleManifest` + `MerkleBuilder.build/verify`, SHA-256).
- `Packages/MaughamCore/Sources/MaughamCore/IntegrityChecks.swift` — pure consistency checks (dangling checkpoint pointers, conflict-twins).
- `Packages/MaughamCore/Sources/MaughamCore/ProjectIntegrity.swift` — `IntegrityReport` + `ProjectIntegrity.check(projectURL:)` aggregator.
- Tests: one `*Tests.swift` per source file in `Packages/MaughamCore/Tests/MaughamCoreTests/`.

**Modify:**
- `Packages/MaughamCore/Sources/MaughamCore/JSONLAppendStore.swift` — extract a coordinated `readBytes()`; add `loadDiagnosed()`; route `load()` through it (no behavior change for existing callers).

**Test command (fast path, core only):**
`swift test --package-path Packages/MaughamCore`
Before committing a task, also confirm the Mac scheme still builds the package:
`./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (run once at the end of the plan, not per-task — it's slow).

---

## Task 1: Parse diagnostics — surface the silent skip

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/ParseDiagnostics.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/JSONLAppendStore.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ParseDiagnosticsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// ParseDiagnosticsTests.swift
import XCTest
@testable import MaughamCore

private struct Item: Codable, Equatable, Sendable { let id: String }

final class ParseDiagnosticsTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    func test_loadDiagnosed_reportsSkippedMidFileLine() async throws {
        // Two valid lines around one corrupt (non-JSON) middle line.
        let url = try tempFile(#"{"id":"a"}"# + "\n" + "NOT JSON\n" + #"{"id":"b"}"# + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONLAppendStore<Item>(fileURL: url)

        let result = try await store.loadDiagnosed()

        XCTAssertEqual(result.elements, [Item(id: "a"), Item(id: "b")])
        XCTAssertEqual(result.diagnostics.skipped.count, 1)
        XCTAssertEqual(result.diagnostics.skipped.first?.raw, "NOT JSON")
        XCTAssertFalse(result.diagnostics.isClean)
    }

    @MainActor
    func test_load_stillReturnsElementsAndIgnoresDiagnostics() async throws {
        let url = try tempFile(#"{"id":"a"}"# + "\n" + "garbage\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONLAppendStore<Item>(fileURL: url)
        let elements = try await store.load()
        XCTAssertEqual(elements, [Item(id: "a")])
    }

    @MainActor
    func test_blankLinesAreNotCorruption() async throws {
        let url = try tempFile(#"{"id":"a"}"# + "\n\n" + #"{"id":"b"}"# + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONLAppendStore<Item>(fileURL: url)
        let result = try await store.loadDiagnosed()
        XCTAssertEqual(result.elements.count, 2)
        XCTAssertTrue(result.diagnostics.isClean)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MaughamCore --filter ParseDiagnosticsTests`
Expected: FAIL — `loadDiagnosed` and `ParseDiagnostics` do not exist (compile error).

- [ ] **Step 3: Create the `ParseDiagnostics` value type**

```swift
// ParseDiagnostics.swift
import Foundation

/// What a JSONL load skipped. A skipped line is one that failed to decode into
/// `Element` — historically dropped silently (`try? decode else continue`). This
/// turns that silent drop into reportable data so corruption can be surfaced and
/// quarantined instead of vanishing.
public struct ParseDiagnostics: Sendable, Equatable {
    public struct SkippedLine: Sendable, Equatable {
        /// Best-effort byte offset of the line start within the file. Assumes
        /// single `\n` separators; a forensic hint, not a guarantee.
        public let byteOffset: Int
        /// The raw line text (or "<non-utf8>" if it wasn't decodable as UTF-8).
        public let raw: String
        public init(byteOffset: Int, raw: String) {
            self.byteOffset = byteOffset
            self.raw = raw
        }
    }
    public var skipped: [SkippedLine]
    public init(skipped: [SkippedLine] = []) { self.skipped = skipped }
    public var isClean: Bool { skipped.isEmpty }
}
```

- [ ] **Step 4: Refactor `JSONLAppendStore` to add diagnosed load (non-breaking)**

In `JSONLAppendStore.swift`, replace the existing `load()` and `parseAndPostProcess(bytes:)` with a shared coordinated read plus a diagnosing parser. Keep `append`, the date coders, and the init unchanged.

```swift
    public func load() async throws -> [Element] {
        parseDiagnosed(bytes: try readBytes()).elements
    }

    /// Like `load()`, but also reports lines that failed to decode (previously
    /// dropped silently). Use this where corruption must be surfaced.
    public func loadDiagnosed() async throws -> (elements: [Element], diagnostics: ParseDiagnostics) {
        parseDiagnosed(bytes: try readBytes())
    }

    /// Coordinated read of the whole file; empty Data if the file is absent.
    private func readBytes() throws -> Data {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Data() }
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var bytes: Data?
        coord.coordinate(readingItemAt: fileURL, options: [], error: &coordErr) { ru in
            bytes = try? Data(contentsOf: ru)
        }
        if let coordErr { throw coordErr }
        return bytes ?? Data()
    }

    private func parseDiagnosed(bytes: Data) -> (elements: [Element], diagnostics: ParseDiagnostics) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = Self.dateDecoding
        var elements: [Element] = []
        var seen = Set<String>()
        var skipped: [ParseDiagnostics.SkippedLine] = []
        var offset = 0
        for lineBytes in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let lineLen = lineBytes.count
            defer { offset += lineLen + 1 }  // +1 for the consumed newline
            if lineBytes.isEmpty { continue }  // blank line: not corruption
            let data = Data(lineBytes)
            guard let element = try? dec.decode(Element.self, from: data) else {
                let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                skipped.append(.init(byteOffset: offset, raw: raw))
                continue
            }
            if let key = dedupKey?(element), !seen.insert(key).inserted { continue }
            elements.append(element)
        }
        if let sortedBy { elements.sort(by: sortedBy) }
        return (elements, ParseDiagnostics(skipped: skipped))
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/MaughamCore --filter ParseDiagnosticsTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the full core suite to confirm no regression in existing callers**

Run: `swift test --package-path Packages/MaughamCore`
Expected: PASS — existing OpLog/Checkpoint tests still green (they call `load()`, whose behavior is unchanged).

- [ ] **Step 7: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/ParseDiagnostics.swift \
        Packages/MaughamCore/Sources/MaughamCore/JSONLAppendStore.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/ParseDiagnosticsTests.swift
git commit -m "feat(core): JSONLAppendStore.loadDiagnosed surfaces skipped lines"
```

---

## Task 2: Quarantine skipped lines

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/IntegrityQuarantine.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/IntegrityQuarantineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// IntegrityQuarantineTests.swift
import XCTest
@testable import MaughamCore

final class IntegrityQuarantineTests: XCTestCase {
    private func tempProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proj-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_record_writesRawLinesUnderConflictsQuarantine() throws {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        let skipped = [
            ParseDiagnostics.SkippedLine(byteOffset: 11, raw: "NOT JSON"),
            ParseDiagnostics.SkippedLine(byteOffset: 25, raw: "{partial"),
        ]

        let written = try IntegrityQuarantine.record(
            skipped: skipped, forDocId: "doc-0f677d7e", in: proj, stamp: "20260607-140000")

        let dir = proj.appendingPathComponent(".maugham/conflicts/quarantine")
        XCTAssertEqual(written.deletingLastPathComponent(), dir)
        let contents = try String(contentsOf: written, encoding: .utf8)
        XCTAssertTrue(contents.contains("NOT JSON"))
        XCTAssertTrue(contents.contains("{partial"))
        XCTAssertTrue(contents.contains("doc-0f677d7e"))
    }

    func test_record_emptySkippedWritesNothing() throws {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        let written = try IntegrityQuarantine.record(
            skipped: [], forDocId: "doc-0f677d7e", in: proj, stamp: "x")
        XCTAssertNil(written)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MaughamCore --filter IntegrityQuarantineTests`
Expected: FAIL — `IntegrityQuarantine` does not exist.

- [ ] **Step 3: Implement `IntegrityQuarantine`**

```swift
// IntegrityQuarantine.swift
import Foundation

/// Persists op-log lines that failed to decode (from `ParseDiagnostics`) into
/// `.maugham/conflicts/quarantine/` so they are never silently lost — a writer or
/// a future tool can inspect/recover them. Append-only, best-effort forensics;
/// not part of the logical op log.
public enum IntegrityQuarantine {
    /// Writes `skipped` for `docId` to
    /// `.maugham/conflicts/quarantine/<docId>.<stamp>.jsonl`. Returns the file URL,
    /// or nil if there was nothing to quarantine. `stamp` is injected (no wall-clock
    /// in core) so the file name is deterministic in tests.
    @discardableResult
    public static func record(
        skipped: [ParseDiagnostics.SkippedLine],
        forDocId docId: String,
        in projectURL: URL,
        stamp: String
    ) throws -> URL? {
        guard !skipped.isEmpty else { return nil }
        let dir = projectURL.appendingPathComponent(".maugham/conflicts/quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(docId).\(stamp).jsonl")
        let body = skipped.map { line in
            // One JSON record per quarantined line: where it was + the raw text.
            #"{"doc_id":"\#(docId)","byte_offset":\#(line.byteOffset),"raw":\#(jsonString(line.raw))}"#
        }.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: file, options: .atomic)
        return file
    }

    /// Minimal JSON string escaping for the raw payload.
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        out += "\""
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MaughamCore --filter IntegrityQuarantineTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/IntegrityQuarantine.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/IntegrityQuarantineTests.swift
git commit -m "feat(core): IntegrityQuarantine persists skipped op-log lines"
```

---

## Task 3: Content manifest (Merkle root)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/MerkleManifest.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/MerkleManifestTests.swift`

> **Note:** This is a *flat manifest with a single root hash* (not a deep binary tree). It satisfies "one root verifies the whole project; a mismatch localizes the file." A true tree is an O(log n)-localization optimization we can add later if file counts ever warrant it; for hundreds of files, flat verify is fine.

- [ ] **Step 1: Write the failing test**

```swift
// MerkleManifestTests.swift
import XCTest
@testable import MaughamCore

final class MerkleManifestTests: XCTestCase {
    private func tempRoot(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mk-\(UUID().uuidString)")
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    func test_build_isDeterministicAndOrderIndependent() throws {
        let root = try tempRoot(["a.txt": "alpha", "sub/b.txt": "beta"])
        defer { try? FileManager.default.removeItem(at: root) }
        let m1 = try MerkleBuilder.build(root: root, relativePaths: ["a.txt", "sub/b.txt"], at: when)
        let m2 = try MerkleBuilder.build(root: root, relativePaths: ["sub/b.txt", "a.txt"], at: when)
        XCTAssertEqual(m1.rootHash, m2.rootHash)
        XCTAssertEqual(m1.entries.map(\.relativePath), ["a.txt", "sub/b.txt"])
    }

    func test_verify_detectsTamperAndMissing() throws {
        let root = try tempRoot(["a.txt": "alpha", "b.txt": "beta"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try MerkleBuilder.build(root: root, relativePaths: ["a.txt", "b.txt"], at: when)

        XCTAssertEqual(MerkleBuilder.verify(manifest: manifest, root: root), [])  // clean

        try "TAMPERED".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        XCTAssertEqual(Set(MerkleBuilder.verify(manifest: manifest, root: root)), ["a.txt", "b.txt"])
    }

    func test_manifest_isCodableRoundTrip() throws {
        let root = try tempRoot(["a.txt": "alpha"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try MerkleBuilder.build(root: root, relativePaths: ["a.txt"], at: when)
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(MerkleManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MaughamCore --filter MerkleManifestTests`
Expected: FAIL — `MerkleManifest` / `MerkleBuilder` do not exist.

- [ ] **Step 3: Implement the manifest + builder**

```swift
// MerkleManifest.swift
import Foundation
import CryptoKit

/// A content manifest over a set of files: per-file SHA-256 plus one root hash
/// computed over the sorted entries. Comparing the root verifies the whole set;
/// `verify` localizes which files changed/disappeared. Used both for live
/// "verify project" and as each backup generation's integrity record.
public struct MerkleManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let relativePath: String
        public let sha256: String
        public let byteCount: Int
        public init(relativePath: String, sha256: String, byteCount: Int) {
            self.relativePath = relativePath
            self.sha256 = sha256
            self.byteCount = byteCount
        }
    }
    public let entries: [Entry]   // sorted by relativePath
    public let rootHash: String
    public let builtAt: Date
    public init(entries: [Entry], rootHash: String, builtAt: Date) {
        self.entries = entries
        self.rootHash = rootHash
        self.builtAt = builtAt
    }
}

public enum MerkleBuilder {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Build a manifest by hashing each file at `root/relativePath`. `builtAt` is
    /// injected (no wall-clock in core). Throws if any listed file can't be read.
    public static func build(root: URL, relativePaths: [String], at builtAt: Date) throws -> MerkleManifest {
        var entries: [MerkleManifest.Entry] = []
        for rel in relativePaths.sorted() {
            let data = try Data(contentsOf: root.appendingPathComponent(rel))
            entries.append(.init(relativePath: rel, sha256: sha256Hex(data), byteCount: data.count))
        }
        let rootLines = entries.map { "\($0.relativePath)\t\($0.sha256)" }.joined(separator: "\n")
        return MerkleManifest(entries: entries, rootHash: sha256Hex(Data(rootLines.utf8)), builtAt: builtAt)
    }

    /// Returns the relative paths whose current bytes don't match the manifest
    /// (mismatched hash, or missing/unreadable). Empty == intact.
    public static func verify(manifest: MerkleManifest, root: URL) -> [String] {
        manifest.entries.compactMap { entry in
            guard let data = try? Data(contentsOf: root.appendingPathComponent(entry.relativePath))
            else { return entry.relativePath }
            return sha256Hex(data) == entry.sha256 ? nil : entry.relativePath
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MaughamCore --filter MerkleManifestTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/MerkleManifest.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/MerkleManifestTests.swift
git commit -m "feat(core): MerkleManifest content-hash manifest with root + verify"
```

---

## Task 4: Dangling checkpoint-pointer check

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/IntegrityChecks.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/IntegrityChecksTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// IntegrityChecksTests.swift
import XCTest
@testable import MaughamCore

final class IntegrityChecksTests: XCTestCase {
    private func checkpoint(_ id: String, pointers: [String: String]) -> Checkpoint {
        Checkpoint(checkpointId: id, label: "l", labelSource: .auto,
                   at: Date(timeIntervalSince1970: 0), device: "d", activeDoc: "doc-1",
                   docPointers: pointers, manuscriptWordCount: 0)
    }

    func test_danglingCheckpointPointers_flagsMissingOpIds() {
        let cps = [
            checkpoint("cp1", pointers: ["doc-1": "op-a", "doc-2": "op-x"]),
            checkpoint("cp2", pointers: ["doc-1": "op-gone"]),
        ]
        let opsByDoc: [String: Set<String>] = ["doc-1": ["op-a"], "doc-2": ["op-x"]]

        let dangling = IntegrityChecks.danglingCheckpointPointers(checkpoints: cps, opsByDoc: opsByDoc)

        XCTAssertEqual(dangling, [
            IntegrityChecks.DanglingPointer(checkpointId: "cp2", docId: "doc-1", opId: "op-gone")
        ])
    }

    func test_danglingCheckpointPointers_cleanWhenAllResolve() {
        let cps = [checkpoint("cp1", pointers: ["doc-1": "op-a"])]
        let dangling = IntegrityChecks.danglingCheckpointPointers(
            checkpoints: cps, opsByDoc: ["doc-1": ["op-a"]])
        XCTAssertTrue(dangling.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MaughamCore --filter IntegrityChecksTests`
Expected: FAIL — `IntegrityChecks` does not exist.

- [ ] **Step 3: Implement the dangling-pointer check**

```swift
// IntegrityChecks.swift
import Foundation

/// Pure, allocation-light consistency checks over already-loaded data. No file I/O
/// here (callers supply the loaded ops/checkpoints/filenames) so each check is a
/// trivially testable function.
public enum IntegrityChecks {
    public struct DanglingPointer: Equatable, Sendable {
        public let checkpointId: String
        public let docId: String
        public let opId: String
        public init(checkpointId: String, docId: String, opId: String) {
            self.checkpointId = checkpointId
            self.docId = docId
            self.opId = opId
        }
    }

    /// Checkpoint `docPointers` that reference an op id not present in that doc's
    /// known op set — evidence the op log lost ops (corruption or a dropped twin).
    public static func danglingCheckpointPointers(
        checkpoints: [Checkpoint], opsByDoc: [String: Set<String>]
    ) -> [DanglingPointer] {
        var result: [DanglingPointer] = []
        for cp in checkpoints {
            for (docId, opId) in cp.docPointers.sorted(by: { $0.key < $1.key }) {
                if !(opsByDoc[docId]?.contains(opId) ?? false) {
                    result.append(.init(checkpointId: cp.checkpointId, docId: docId, opId: opId))
                }
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MaughamCore --filter IntegrityChecksTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/IntegrityChecks.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/IntegrityChecksTests.swift
git commit -m "feat(core): IntegrityChecks.danglingCheckpointPointers"
```

---

## Task 5: iCloud conflict-twin detection

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/IntegrityChecks.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/IntegrityChecksTests.swift` (add cases)

> iCloud names a losing conflict copy `"<base> 2.jsonl"`, `"<base> 3.jsonl"`, etc. (a space + integer before the extension). The loader globs `<docId>.*.jsonl` and would silently ignore these, so their *presence* is the signal that iCloud dropped a concurrent write — exactly tripwire 17's failure, made visible.

- [ ] **Step 1: Add the failing test**

```swift
    // append to IntegrityChecksTests
    func test_conflictTwins_detectsICloudNumberedCopies() {
        let names = [
            "doc-0f677d7e.macA.jsonl",       // normal
            "doc-0f677d7e.macA 2.jsonl",     // iCloud conflict twin
            "scene-f8c9644e 3.jsonl",        // twin without device slug
            "doc-0f677d7e.phoneB.jsonl",     // normal
            "notes.txt",                     // ignored (not jsonl)
        ]
        XCTAssertEqual(
            Set(IntegrityChecks.conflictTwins(inOpsDirectoryFilenames: names)),
            ["doc-0f677d7e.macA 2.jsonl", "scene-f8c9644e 3.jsonl"])
    }

    func test_conflictTwins_emptyWhenNone() {
        XCTAssertTrue(IntegrityChecks.conflictTwins(
            inOpsDirectoryFilenames: ["doc-0f677d7e.macA.jsonl"]).isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MaughamCore --filter IntegrityChecksTests`
Expected: FAIL — `conflictTwins(inOpsDirectoryFilenames:)` does not exist.

- [ ] **Step 3: Add the check to `IntegrityChecks`**

```swift
    /// Filenames that look like iCloud conflict copies (`"... N.jsonl"`, a space +
    /// integer before the extension). Their presence means iCloud resolved a
    /// concurrent append by dropping a sibling — silent data loss (tripwire 17).
    public static func conflictTwins(inOpsDirectoryFilenames names: [String]) -> [String] {
        names.filter { name in
            guard name.hasSuffix(".jsonl") else { return false }
            let stem = name.dropLast(".jsonl".count)
            return stem.range(of: #" \d+$"#, options: .regularExpression) != nil
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MaughamCore --filter IntegrityChecksTests`
Expected: PASS (4 tests in the file).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/IntegrityChecks.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/IntegrityChecksTests.swift
git commit -m "feat(core): IntegrityChecks.conflictTwins detects iCloud twins"
```

---

## Task 6: `ProjectIntegrity.check` aggregator

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/ProjectIntegrity.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ProjectIntegrityTests.swift`

> Ties Tasks 1, 4, 5 into one live-project health report. For every doc op-log file it runs `loadDiagnosed` (skips), validates checkpoint pointers against the merged ops, and scans the ops dir for conflict-twins. (Merkle verify is for backup generations — Plan 2 — so it is not part of the *live* project check.)

- [ ] **Step 1: Write the failing test**

```swift
// ProjectIntegrityTests.swift
import XCTest
@testable import MaughamCore

final class ProjectIntegrityTests: XCTestCase {
    private func makeProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
        return url
    }
    private func writeOps(_ project: URL, file: String, lines: [String]) throws {
        let url = project.appendingPathComponent(".maugham/ops/\(file)")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    func test_check_healthyProjectReportsClean() async throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        // One valid op line (an Op encodes with these keys; a minimal hand-written
        // line is enough — it must decode to Op).
        let op = Op(opId: "01ABC", docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 0),
                    device: "macA", session: "s", kind: .checkpoint, changes: [],
                    sequence: nil, provenance: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let line = String(data: try enc.encode(op), encoding: .utf8)!
        try writeOps(proj, file: "doc-0f677d7e.macA.jsonl", lines: [line])

        let report = try await ProjectIntegrity.check(projectURL: proj)
        XCTAssertTrue(report.isHealthy)
    }

    @MainActor
    func test_check_flagsCorruptLineAndConflictTwin() async throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, file: "doc-0f677d7e.macA.jsonl", lines: ["GARBAGE NOT JSON"])
        try writeOps(proj, file: "doc-0f677d7e.macA 2.jsonl", lines: ["{}"])

        let report = try await ProjectIntegrity.check(projectURL: proj)

        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.docSkips.first?.docId, "doc-0f677d7e")
        XCTAssertEqual(report.docSkips.first?.skipped.first?.raw, "GARBAGE NOT JSON")
        XCTAssertEqual(report.conflictTwins, ["doc-0f677d7e.macA 2.jsonl"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MaughamCore --filter ProjectIntegrityTests`
Expected: FAIL — `ProjectIntegrity` does not exist.

> If `Op`'s initializer signature differs from the test, fix the test's `Op(...)` call to match the real `Op.init` in `Packages/MaughamCore/Sources/MaughamCore/Op.swift` (read it first) — the point is one valid op line, not the exact field set.

- [ ] **Step 3: Implement the aggregator**

```swift
// ProjectIntegrity.swift
import Foundation

/// A live-project health report: op-log parse skips per doc, dangling checkpoint
/// pointers, and iCloud conflict-twins. The data model behind the future
/// "Verify project" action (UI is Plan 2). Backup-generation Merkle verification
/// is separate (also Plan 2).
public struct IntegrityReport: Equatable, Sendable {
    public struct DocSkips: Equatable, Sendable {
        public let docId: String
        public let skipped: [ParseDiagnostics.SkippedLine]
    }
    public let docSkips: [DocSkips]
    public let conflictTwins: [String]
    public let danglingPointers: [IntegrityChecks.DanglingPointer]

    public var isHealthy: Bool {
        docSkips.allSatisfy { $0.skipped.isEmpty } && conflictTwins.isEmpty && danglingPointers.isEmpty
    }
}

@MainActor
public enum ProjectIntegrity {
    public static func check(projectURL: URL) async throws -> IntegrityReport {
        let opsDir = projectURL.appendingPathComponent(".maugham/ops")
        let filenames = ((try? FileManager.default.contentsOfDirectory(
            at: opsDir, includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent)

        // Per-doc parse skips + the merged op-id set (for pointer validation).
        var docSkips: [IntegrityReport.DocSkips] = []
        var opsByDoc: [String: Set<String>] = [:]
        for docId in OpLogStore.docIds(inOpsDirectoryFilenames: filenames).sorted() {
            var skips: [ParseDiagnostics.SkippedLine] = []
            var opIds: Set<String> = []
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
                let store = JSONLAppendStore<Op>(fileURL: url, dedupKey: { $0.opId })
                let result = try await store.loadDiagnosed()
                skips.append(contentsOf: result.diagnostics.skipped)
                opIds.formUnion(result.elements.map(\.opId))
            }
            if !skips.isEmpty { docSkips.append(.init(docId: docId, skipped: skips)) }
            opsByDoc[docId] = opIds
        }

        // Project-scope ops (__project__) hold checkpoints' target docs too; include
        // their op ids so cross-doc pointers resolve.
        let checkpoints = (try? await CheckpointStore(projectURL: projectURL).load()) ?? []
        let dangling = IntegrityChecks.danglingCheckpointPointers(
            checkpoints: checkpoints, opsByDoc: opsByDoc)

        return IntegrityReport(
            docSkips: docSkips,
            conflictTwins: IntegrityChecks.conflictTwins(inOpsDirectoryFilenames: filenames),
            danglingPointers: dangling)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MaughamCore --filter ProjectIntegrityTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full core suite**

Run: `swift test --package-path Packages/MaughamCore`
Expected: PASS (all core tests).

- [ ] **Step 6: Confirm the Mac scheme still builds + tests (slow, once)**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: BUILD + TEST SUCCEEDED (CryptoKit links on the Mac target; no app-side caller changed).

- [ ] **Step 7: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/ProjectIntegrity.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/ProjectIntegrityTests.swift
git commit -m "feat(core): ProjectIntegrity.check aggregates the live health report"
```

---

## Self-Review

**Spec coverage (spec §4):**
- §4.1 surface silent skip → Task 1; quarantine → Task 2. ✓
- §4.2 Merkle manifest → Task 3. ✓
- §4.4 checkpoint-pointer validation → Task 4. ✓
- §4.5 set-integrity (conflict-twin) → Task 5. ✓ (missing-sibling sub-case deferred — needs a device registry, noted in spec.)
- §4.7 aggregator *data model* → Task 6. ✓ (the *UI* "Verify project" action + health indicator is Plan 2, by design — UI placement is spec §10 open.)
- §4.3 manifest shadow, §4.6 derive-and-compare → **deferred to Plan 2** (both touch Mac write/render paths; called out in the plan header). Not gaps — explicit scope.

**Placeholder scan:** No "TBD"/"handle errors"/"similar to" — every code step is complete. The one conditional ("if `Op.init` differs, adjust the test") points at a real file to read, not a placeholder.

**Type consistency:** `ParseDiagnostics.SkippedLine` used identically in Tasks 1, 2, 6. `IntegrityChecks.DanglingPointer` defined Task 4, used Task 6. `MerkleManifest`/`MerkleBuilder` self-contained Task 3. `loadDiagnosed()` defined Task 1, used Task 6. `OpLogStore.docIds`/`opLogFileURLs` are existing APIs (verified in the store source). ✓

**Cross-surface:** All changes are MaughamCore (shared) — no target-local copies, satisfies tripwire 19. CryptoKit added to the package is available on macOS + iOS, so the phone target still builds.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-07-integrity-primitive.md`. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task with two-stage review between tasks. Fast iteration; matches this project's default workflow.
2. **Inline Execution** — execute the tasks in this session with checkpoints for review.

Which approach?
