# Backup Generation Writer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the durable heart of the backup system: a pure-Foundation component that writes verified, immutable, timestamped full-copy *generations* of a project directory to a destination, each carrying a Merkle manifest, with retention pruning — the unit every backup destination stores.

**Architecture:** Lives in `Packages/MaughamCore` (reuses Plan 1's `MerkleManifest`/`MerkleBuilder`). A generation is a complete directory copy written atomically (copy into a hidden `.partial-<id>/`, then `moveItem` into place) so a reader/cloud-client never sees a torn generation. `FileManager.copyItem` is used for the copy — on same-volume APFS it performs **copy-on-write clones automatically**, so local generations are space-cheap with no `clonefile` plumbing; across volumes it's a real copy. Each generation embeds a `MerkleManifest` of the source files, verified immediately after copy. No UI, no security-scoped bookmarks, no project-structure knowledge, no checkpoint trigger — those are later stacked plans.

**Tech Stack:** Swift, `FileManager`, the existing `MerkleManifest`/`MerkleBuilder` (CryptoKit SHA-256), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-07-backup-and-integrity-design.md` — §5.5 (generation write: atomic `.partial`+rename, clone-or-copy, per-generation Merkle manifest, verify-on-write) and §5.6 (retention pruning). *Out of scope here:* §5.1 destinations/bookmarks, §5.3 full-vs-essential classification, §5.4 trigger/throttle, §5.7 test-restore, §5.8 status, §6 restore. This plan provides the primitive they will all call.

**Stacking:** This work stacks on `feat/integrity-primitive` (needs `MerkleManifest` from Plan 1). Branch from it.

---

## Design notes the implementer must honor

- **Generation id is injected**, never generated inside core (no `Date.now`/`ULID.generate()` inside these functions — keeps them deterministic and testable). Callers pass a ULID string + a `builtAt: Date`.
- **The manifest file lives inside the generation** at `.maugham-backup-manifest.json` and is **excluded from its own entries** (you can't hash a file that doesn't exist yet, and it must not invalidate its own verify).
- **Atomicity:** copy into `<destination>/.partial-<id>/`, write the manifest into it, verify, then `moveItem` to `<destination>/<id>/`. Clean up a leftover `.partial-<id>` from a prior failed run before starting. On any failure, remove the partial.
- **Immutability:** never modify an existing generation directory; only create new ones and delete whole old ones (retention).

---

## File Structure

**Create:**
- `Packages/MaughamCore/Sources/MaughamCore/BackupGeneration.swift` — `BackupGeneration` value type (id + manifest) and `BackupError`.
- `Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift` — `BackupWriter` enum: `relativeFilePaths(under:)`, `write(...)`, `generationIds(at:)`, `prune(...)`.

**Tests:**
- `Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift`

**Test command:** `swift test --package-path Packages/MaughamCore` (filter per task with `--filter`).

---

## Task 1: Recursive relative-path file enumeration

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/BackupGeneration.swift`
- Create: `Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MaughamCore

final class BackupWriterTests: XCTestCase {
    func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-\(UUID().uuidString)")
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    func test_relativeFilePaths_listsAllFilesRecursivelySorted() throws {
        let root = try makeTree(["a.md": "a", "sub/b.md": "b", "sub/deep/c.md": "c"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            try BackupWriter.relativeFilePaths(under: root),
            ["a.md", "sub/b.md", "sub/deep/c.md"])
    }

    func test_relativeFilePaths_emptyDirIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try BackupWriter.relativeFilePaths(under: root), [])
    }
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`
Expected: FAIL — `BackupWriter` doesn't exist.

- [ ] **Step 3: Create `BackupGeneration.swift`**

```swift
import Foundation

/// One immutable backup snapshot of a project directory: its id (caller-supplied,
/// typically a ULID for monotonic ordering) and the Merkle manifest of its files.
public struct BackupGeneration: Equatable, Sendable {
    public let id: String
    public let manifest: MerkleManifest
    public init(id: String, manifest: MerkleManifest) {
        self.id = id
        self.manifest = manifest
    }
}

public enum BackupError: Error, Equatable {
    /// The copied generation's bytes did not match the source manifest.
    case verificationFailed(mismatchedPaths: [String])
}
```

- [ ] **Step 4: Create `BackupWriter.swift` with the enumeration helper**

```swift
import Foundation

/// Writes/verifies/prunes immutable, timestamped full-copy backup generations of a
/// project directory. Pure Foundation: `FileManager.copyItem` performs APFS
/// copy-on-write clones automatically on same-volume destinations, so local
/// generations are space-cheap. Generation ids and timestamps are caller-supplied
/// (no wall-clock here) for deterministic behavior and testability.
public enum BackupWriter {
    /// The file name of the per-generation manifest, stored inside the generation
    /// and excluded from its own entries.
    public static let manifestName = ".maugham-backup-manifest.json"

    /// All file relative paths under `root` (recursive, files only — directories and
    /// symlinks excluded), sorted ascending. Paths use "/" separators.
    public static func relativeFilePaths(under root: URL) throws -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [], errorHandler: nil) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [String] = []
        for case let url as URL in en {
            let vals = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard vals.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            result.append(String(full.dropFirst(rootPath.count + 1)))
        }
        return result.sorted()
    }
}
```

- [ ] **Step 5: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupGeneration.swift \
        Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift
git commit -m "feat(core): BackupWriter.relativeFilePaths + BackupGeneration model"
```

---

## Task 2: Write a verified generation (atomic copy + manifest)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift` (add cases)

- [ ] **Step 1: Add the failing tests**

```swift
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private func destDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_write_copiesAllFilesAndEmbedsVerifiableManifest() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }

        let gen = try BackupWriter.write(source: source, to: dest, generationId: "01GEN", at: when)

        let genDir = dest.appendingPathComponent("01GEN")
        XCTAssertEqual(gen.id, "01GEN")
        XCTAssertEqual(try String(contentsOf: genDir.appendingPathComponent("a.md"), encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOf: genDir.appendingPathComponent("sub/b.md"), encoding: .utf8), "beta")
        // Manifest exists and verifies against the copied tree.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: genDir.appendingPathComponent(BackupWriter.manifestName).path))
        XCTAssertEqual(MerkleBuilder.verify(manifest: gen.manifest, root: genDir), [])
        // Manifest does not list itself.
        XCTAssertFalse(gen.manifest.entries.contains { $0.relativePath == BackupWriter.manifestName })
    }

    func test_write_leavesNoPartialDirOnSuccess() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01GEN", at: when)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        XCTAssertEqual(entries, ["01GEN"])  // no .partial-* left behind
    }

    func test_write_cleansLeftoverPartialFromPriorFailure() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        // Simulate a leftover partial from a crashed prior run.
        try FileManager.default.createDirectory(
            at: dest.appendingPathComponent(".partial-01GEN"), withIntermediateDirectories: true)
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01GEN", at: when)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), ["01GEN"])
    }
```

- [ ] **Step 2: Run, confirm failure** (`write` doesn't exist):

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`

- [ ] **Step 3: Add `write` to `BackupWriter`**

```swift
    /// Write a new generation of `source` into `<destination>/<generationId>/`.
    /// Copies into a hidden `.partial-<id>/` first, embeds a verified Merkle
    /// manifest, then atomically renames into place. Throws (and leaves no
    /// generation dir) on copy/verify failure. Returns the `BackupGeneration`.
    @discardableResult
    public static func write(
        source: URL, to destination: URL, generationId: String, at builtAt: Date
    ) throws -> BackupGeneration {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let partial = destination.appendingPathComponent(".partial-\(generationId)")
        let final = destination.appendingPathComponent(generationId)

        // Clean any leftovers from a crashed prior run.
        try? fm.removeItem(at: partial)

        do {
            // Copy the whole source tree (APFS CoW clone on same volume).
            try fm.copyItem(at: source, to: partial)

            // Build the manifest from the SOURCE file set (excludes the manifest
            // file, which doesn't exist in source), then write it into the partial.
            let rels = try relativeFilePaths(under: source)
            let manifest = try MerkleBuilder.build(root: source, relativePaths: rels, at: builtAt)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(
                to: partial.appendingPathComponent(manifestName), options: .atomic)

            // Verify the copied bytes match the manifest before committing.
            let mismatches = MerkleBuilder.verify(manifest: manifest, root: partial)
            guard mismatches.isEmpty else {
                throw BackupError.verificationFailed(mismatchedPaths: mismatches)
            }

            // Atomic commit.
            try? fm.removeItem(at: final)
            try fm.moveItem(at: partial, to: final)
            return BackupGeneration(id: generationId, manifest: manifest)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }
```

- [ ] **Step 4: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`
Expected: PASS (5 tests in the file now).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift
git commit -m "feat(core): BackupWriter.write — atomic verified generation copy"
```

---

## Task 3: List generations (sorted)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift` (add cases)

- [ ] **Step 1: Add the failing tests**

```swift
    func test_generationIds_listsCommittedGenerationsSortedIgnoringPartials() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01B", at: when)
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01C", at: when)
        // A stray partial + a stray dotfile must be ignored.
        try FileManager.default.createDirectory(
            at: dest.appendingPathComponent(".partial-XX"), withIntermediateDirectories: true)

        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01A", "01B", "01C"])
    }

    func test_generationIds_missingDestinationIsEmpty() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), [])
    }
```

- [ ] **Step 2: Run, confirm failure**

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`

- [ ] **Step 3: Add `generationIds` to `BackupWriter`**

```swift
    /// Committed generation ids under `destination`, sorted ascending (ULID ids sort
    /// chronologically). Ignores hidden entries (`.partial-*`, `.DS_Store`) and files.
    public static func generationIds(at destination: URL) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return [] }
        let entries = try fm.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        return entries.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return isDir ? name : nil
        }.sorted()
    }
```

- [ ] **Step 4: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift
git commit -m "feat(core): BackupWriter.generationIds lists sorted committed generations"
```

---

## Task 4: Retention pruning

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift` (add cases)

- [ ] **Step 1: Add the failing tests**

```swift
    func test_prune_keepsNewestNAndRemovesOlder() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        for id in ["01A", "01B", "01C", "01D"] {
            _ = try BackupWriter.write(source: source, to: dest, generationId: id, at: when)
        }
        let removed = try BackupWriter.prune(destination: dest, keeping: 2)
        XCTAssertEqual(removed, ["01A", "01B"])               // oldest removed
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01C", "01D"])  // newest kept
    }

    func test_prune_noOpWhenWithinLimit() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        XCTAssertEqual(try BackupWriter.prune(destination: dest, keeping: 5), [])
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01A"])
    }

    func test_prune_keepingZeroRemovesAll() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        XCTAssertEqual(try BackupWriter.prune(destination: dest, keeping: 0), ["01A"])
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), [])
    }
```

- [ ] **Step 2: Run, confirm failure**

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`

- [ ] **Step 3: Add `prune` to `BackupWriter`**

```swift
    /// Keep the newest `keeping` generations under `destination`; remove the rest.
    /// "Newest" = highest-sorting ids (ULID ids sort chronologically). `keeping`
    /// is clamped at 0. Returns the removed ids (ascending). Generations are
    /// immutable, so pruning only ever deletes whole old generation directories.
    @discardableResult
    public static func prune(destination: URL, keeping: Int) throws -> [String] {
        let keep = max(0, keeping)
        let ids = try generationIds(at: destination)
        guard ids.count > keep else { return [] }
        let toRemove = Array(ids.dropLast(keep))
        let fm = FileManager.default
        for id in toRemove {
            try fm.removeItem(at: destination.appendingPathComponent(id))
        }
        return toRemove
    }
```

- [ ] **Step 4: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift
git commit -m "feat(core): BackupWriter.prune retains newest N generations"
```

---

## Task 5: Corruption detection on a stored generation

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift` (add cases)

> This is the "is this stored generation still intact?" check restore/auto-bisect will call. It reads the embedded manifest and verifies the generation's files against it.

- [ ] **Step 1: Add the failing tests**

```swift
    func test_verifyGeneration_cleanWhenUntouched() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        XCTAssertEqual(try BackupWriter.verifyGeneration(id: "01A", at: dest), [])
    }

    func test_verifyGeneration_detectsTamper() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        // Corrupt a file inside the committed generation.
        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try BackupWriter.verifyGeneration(id: "01A", at: dest), ["a.md"])
    }
```

- [ ] **Step 2: Run, confirm failure**

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`

- [ ] **Step 3: Add `verifyGeneration` to `BackupWriter`**

```swift
    /// Verify a committed generation's files against its embedded manifest. Returns
    /// the relative paths that mismatch or are missing (empty == intact). Throws if
    /// the generation or its manifest can't be read.
    public static func verifyGeneration(id: String, at destination: URL) throws -> [String] {
        let genDir = destination.appendingPathComponent(id)
        let manifestURL = genDir.appendingPathComponent(manifestName)
        let manifest = try JSONDecoder().decode(
            MerkleManifest.self, from: Data(contentsOf: manifestURL))
        return MerkleBuilder.verify(manifest: manifest, root: genDir)
    }
```

- [ ] **Step 4: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupWriterTests`
Expected: PASS (12 tests).

- [ ] **Step 5: Run full core suite**

Run: `swift test --package-path Packages/MaughamCore`
Expected: PASS (all).

- [ ] **Step 6: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupWriterTests.swift
git commit -m "feat(core): BackupWriter.verifyGeneration checks a stored generation"
```

---

## Self-Review

**Spec coverage (spec §5.5–§5.6):**
- §5.5 atomic `.partial`+rename → Task 2 (`.partial-<id>` then `moveItem`). ✓
- §5.5 clone-or-copy → `FileManager.copyItem` (auto-CoW on same volume). ✓
- §5.5 per-generation Merkle manifest + verify-on-write → Task 2. ✓
- §5.6 retention pruning (keep newest N) → Task 4. ✓
- Generation listing (needed by retention + future restore/status) → Task 3. ✓
- Stored-generation integrity check (needed by future restore/auto-bisect) → Task 5. ✓
- Deferred (correctly absent): destinations/bookmarks (§5.1), full-vs-essential classification (§5.3), trigger (§5.4), test-restore (§5.7), status (§5.8), restore (§6). These call `BackupWriter`; they are later stacked plans.

**Placeholder scan:** No TBD/vague steps; every code step is complete.

**Type consistency:** `BackupWriter.manifestName`, `.relativeFilePaths`, `.write`, `.generationIds`, `.prune`, `.verifyGeneration` used consistently across tasks. `BackupGeneration(id:manifest:)` and `BackupError.verificationFailed` defined Task 1, used Task 2. `MerkleBuilder.build(root:relativePaths:at:)` / `.verify(manifest:root:)` and `MerkleManifest` Codable are the real Plan-1 signatures.

**Cross-surface:** All in MaughamCore (shared), pure Foundation + the existing CryptoKit-backed manifest — no new dependency, no UI, no app-structure coupling.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-07-backup-generation-writer.md`. Stacks on `feat/integrity-primitive`. Execute via superpowers:subagent-driven-development (fresh subagent per task; this project's default).
