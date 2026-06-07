# Restore Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide the read/recover half of backups: list generations across all destinations (newest-first), verify a generation's integrity, find the newest *intact* one (auto-bisect), and restore a whole project **beside** the original (never overwriting it).

**Architecture:** `BackupRestore` (MaughamCore) on top of `BackupWriter`/`MerkleManifest` (merged). It reads the generation directories a destination holds, exposes their integrity via the embedded Merkle manifest, and copies a chosen generation's content into a fresh target folder (stripping the backup sidecars). Pure Foundation, fully `swift test`-able. **Restore-beside is the safety invariant: this engine never writes into the live project.** Single-document restore (op-log surgery into a live project) and all UI are later plans.

**Tech Stack:** Swift, `FileManager`, `BackupWriter`/`MerkleBuilder`/`MerkleManifest`, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-07-backup-and-integrity-design.md` §6 — restore-beside (never overwrite), integrity badge per generation, auto-bisect-to-good. *Out of scope (later plans):* single-document-via-ops restore, the restore browser UI, the "backups paused" warning (#1), derive-and-compare.

**Stacking:** Branch from `main` (the backup engine + Mac integration are merged there).

---

## Design notes the implementer must honor

- **Generation ids are ULIDs**, so lexical descending sort == newest-first.
- A generation directory is `<destination>/<id>/`, containing the project copy plus
  `BackupWriter.manifestName` (`.maugham-backup-manifest.json`) and
  `BackupSignature.signatureName` (`.maugham-backup-signature`). Those two sidecars are
  **backup bookkeeping** and must NOT be copied into a restored project.
- **`restoreBeside` never overwrites:** it throws if the target already exists, and it
  refuses to restore a generation that fails its own integrity check (don't recover
  corruption).

---

## File Structure

**Create:**
- `Packages/MaughamCore/Sources/MaughamCore/BackupRestore.swift` — `RestoreGeneration`, `RestoreError`, and `BackupRestore` (list / verify / newestIntact / restoreBeside).

**Test:**
- `Packages/MaughamCore/Tests/MaughamCoreTests/BackupRestoreTests.swift`

**Test command:** `swift test --package-path Packages/MaughamCore` (filter `--filter BackupRestoreTests`).

---

## Task 1: List generations across destinations (newest-first)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/BackupRestore.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupRestoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MaughamCore

final class BackupRestoreTests: XCTestCase {
    let when = Date(timeIntervalSince1970: 1_700_000_000)

    func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rs-\(UUID().uuidString)")
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    func destDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rsd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_listGenerations_mergesDestinationsNewestFirst() throws {
        let source = try makeTree(["a.md": "alpha"])
        let d1 = destDir(); let d2 = destDir()
        defer { [source, d1, d2].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try BackupWriter.write(source: source, to: d1, generationId: "01A", at: when)
        _ = try BackupWriter.write(source: source, to: d2, generationId: "01C", at: when)
        _ = try BackupWriter.write(source: source, to: d1, generationId: "01B", at: when)

        let gens = BackupRestore.listGenerations(across: [d1, d2])

        // Newest-first by ULID id, across both destinations.
        XCTAssertEqual(gens.map(\.id), ["01C", "01B", "01A"])
        XCTAssertEqual(gens.first?.destination, d2)
        XCTAssertEqual(gens.first?.builtAt, when)
    }

    func test_listGenerations_emptyWhenNoDestinationsOrGenerations() {
        XCTAssertTrue(BackupRestore.listGenerations(across: []).isEmpty)
        XCTAssertTrue(BackupRestore.listGenerations(across: [destDir()]).isEmpty)
    }
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `swift test --package-path Packages/MaughamCore --filter BackupRestoreTests`
Expected: FAIL — `BackupRestore` doesn't exist.

- [ ] **Step 3: Create `BackupRestore.swift`**

```swift
import Foundation

/// One restorable generation: which destination holds it, its id, and when it was
/// written (read from the embedded manifest, nil if unreadable).
public struct RestoreGeneration: Equatable, Sendable {
    public let destination: URL
    public let id: String
    public let builtAt: Date?
    public init(destination: URL, id: String, builtAt: Date?) {
        self.destination = destination
        self.id = id
        self.builtAt = builtAt
    }
    /// The generation directory `<destination>/<id>`.
    public var directory: URL { destination.appendingPathComponent(id) }
}

public enum RestoreError: Error, Equatable {
    case targetAlreadyExists(URL)
    case generationCorrupt(mismatchedPaths: [String])
}

public enum BackupRestore {
    /// All generations across `destinations`, newest-first (ULID ids sort
    /// chronologically). `builtAt` is read from each generation's manifest.
    public static func listGenerations(across destinations: [URL]) -> [RestoreGeneration] {
        var all: [RestoreGeneration] = []
        for dest in destinations {
            let ids = (try? BackupWriter.generationIds(at: dest)) ?? []
            for id in ids {
                let manifestURL = dest.appendingPathComponent(id)
                    .appendingPathComponent(BackupWriter.manifestName)
                let builtAt = (try? JSONDecoder().decode(
                    MerkleManifest.self, from: Data(contentsOf: manifestURL)))?.builtAt
                all.append(RestoreGeneration(destination: dest, id: id, builtAt: builtAt))
            }
        }
        return all.sorted { $0.id > $1.id }
    }
}
```

- [ ] **Step 4: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupRestoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupRestore.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupRestoreTests.swift
git commit -m "feat(core): BackupRestore.listGenerations across destinations, newest-first"
```

---

## Task 2: Verify a generation + newest-intact (auto-bisect)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/BackupRestore.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupRestoreTests.swift` (add cases)

- [ ] **Step 1: Add the failing tests**

```swift
    func test_newestIntact_skipsCorruptGenerationsToFindGoodOne() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { [source, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)  // good
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01B", at: when)  // will corrupt
        // Corrupt the newest generation's content.
        try "ROT".write(to: dest.appendingPathComponent("01B/a.md"), atomically: true, encoding: .utf8)

        let intact = BackupRestore.newestIntact(across: [dest])
        XCTAssertEqual(intact?.id, "01A")  // bisected past the corrupt 01B
    }

    func test_newestIntact_nilWhenAllCorruptOrNone() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { [source, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertNil(BackupRestore.newestIntact(across: [dest]))  // none
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(BackupRestore.newestIntact(across: [dest]))  // all corrupt
    }

    func test_verify_returnsMismatchedPaths() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { [source, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        let gen = BackupRestore.listGenerations(across: [dest])[0]
        XCTAssertEqual(BackupRestore.verify(gen), [])
        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(BackupRestore.verify(gen), ["a.md"])
    }
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add `verify` + `newestIntact` to `BackupRestore`**

```swift
    /// The relative paths in `gen` that don't match its manifest (empty == intact).
    /// Throws nothing — an unreadable manifest yields `[]` (treated as can't-verify;
    /// `newestIntact` therefore won't pick a generation whose manifest is gone — see
    /// note). Use for an integrity badge in the restore list.
    public static func verify(_ gen: RestoreGeneration) -> [String] {
        ((try? BackupWriter.verifyGeneration(id: gen.id, at: gen.destination)) ?? ["<unverifiable>"])
    }

    /// The newest generation across `destinations` that verifies intact, or nil if
    /// none do — the "auto-bisect-to-good" path for recovering from corruption.
    public static func newestIntact(across destinations: [URL]) -> RestoreGeneration? {
        listGenerations(across: destinations).first { verify($0).isEmpty }
    }
```

> Note on `verify`: an unreadable/missing manifest returns `["<unverifiable>"]` (non-empty), so such a generation is treated as *not intact* and skipped by `newestIntact` — we won't blindly restore something we can't check.

- [ ] **Step 4: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupRestoreTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupRestore.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupRestoreTests.swift
git commit -m "feat(core): BackupRestore.verify + newestIntact (auto-bisect-to-good)"
```

---

## Task 3: Restore beside (never overwrite)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/BackupRestore.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupRestoreTests.swift` (add cases)

- [ ] **Step 1: Add the failing tests**

```swift
    func test_restoreBeside_copiesProjectWithoutBackupSidecars() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        // Give it a signature sidecar too (as a real backup run would).
        try "sig".write(to: dest.appendingPathComponent("01A/\(BackupSignature.signatureName)"),
                        atomically: true, encoding: .utf8)
        let gen = BackupRestore.listGenerations(across: [dest])[0]
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("restored-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }

        let result = try BackupRestore.restoreBeside(gen, to: target)

        XCTAssertEqual(result, target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.md"), encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("sub/b.md"), encoding: .utf8), "beta")
        // Backup bookkeeping must NOT appear in a restored project.
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(BackupWriter.manifestName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(BackupSignature.signatureName).path))
    }

    func test_restoreBeside_refusesExistingTarget() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        let target = destDir()  // already exists
        defer { [source, dest, target].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        let gen = BackupRestore.listGenerations(across: [dest])[0]
        XCTAssertThrowsError(try BackupRestore.restoreBeside(gen, to: target)) {
            XCTAssertEqual($0 as? RestoreError, .targetAlreadyExists(target))
        }
    }

    func test_restoreBeside_refusesCorruptGeneration() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)
        let gen = BackupRestore.listGenerations(across: [dest])[0]
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString)")
        XCTAssertThrowsError(try BackupRestore.restoreBeside(gen, to: target)) {
            XCTAssertEqual($0 as? RestoreError, .generationCorrupt(mismatchedPaths: ["a.md"]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))  // nothing written
    }
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add `restoreBeside` to `BackupRestore`**

```swift
    /// Restore `gen` into a NEW folder at `target` — never into the live project.
    /// Refuses if `target` exists or the generation fails integrity. Strips the
    /// backup sidecars (manifest + signature) so the result is a clean project.
    /// Returns `target`.
    @discardableResult
    public static func restoreBeside(_ gen: RestoreGeneration, to target: URL) throws -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else {
            throw RestoreError.targetAlreadyExists(target)
        }
        let mismatches = verify(gen)
        guard mismatches.isEmpty else {
            throw RestoreError.generationCorrupt(mismatchedPaths: mismatches)
        }
        // Copy the whole generation (APFS CoW where possible), then drop the sidecars.
        try fm.copyItem(at: gen.directory, to: target)
        for sidecar in [BackupWriter.manifestName, BackupSignature.signatureName] {
            try? fm.removeItem(at: target.appendingPathComponent(sidecar))
        }
        return target
    }
```

- [ ] **Step 4: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupRestoreTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Run the full core suite**

Run: `swift test --package-path Packages/MaughamCore`
Expected: PASS (all).

- [ ] **Step 6: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupRestore.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupRestoreTests.swift
git commit -m "feat(core): BackupRestore.restoreBeside — never-overwrite project recovery"
```

---

## Self-Review

**Spec coverage (§6):** restore-beside never-overwrite → Task 3 (`targetAlreadyExists` guard, copies to a new folder, strips sidecars). integrity badge per generation → Task 2 `verify`. auto-bisect-to-good → Task 2 `newestIntact`. generation listing newest-first → Task 1. Deferred (correctly absent): single-document-via-ops restore, the restore UI, the "backups paused" warning, derive-and-compare.

**Placeholder scan:** none — all code complete.

**Type consistency:** `RestoreGeneration(destination:id:builtAt:)` + `.directory`, `RestoreError` cases, `BackupRestore.listGenerations`/`verify`/`newestIntact`/`restoreBeside` consistent across tasks. Uses real merged APIs: `BackupWriter.generationIds`/`verifyGeneration`/`manifestName`, `BackupSignature.signatureName`, `MerkleManifest.builtAt`.

**Cross-surface:** all MaughamCore, pure Foundation, additive — no UI, no app coupling.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-07-restore-engine.md`. Branch from `main`. Execute via superpowers:subagent-driven-development.
