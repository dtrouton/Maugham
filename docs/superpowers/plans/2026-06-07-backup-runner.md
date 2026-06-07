# Backup Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Orchestrate backups across multiple destinations — best-effort and independent (one destination failing never aborts the others), with retention applied per destination and a skip-unchanged guard that prevents idle saves from churning backup history.

**Architecture:** `BackupRunner` (MaughamCore) sits on top of `BackupWriter` (Plan 2). It builds the current source's Merkle root once, and for each destination: if the destination's newest generation already has that root, it **skips** (no churn); otherwise it writes a new generation and prunes to the destination's retention. Each destination is handled in its own `do/catch` so a failure is captured as an outcome rather than thrown. Full backups only (essential/full classification deferred). Destinations are plain `URL`s — security-scoped bookmarks and config persistence are the Mac layer, deferred to a later plan.

**Tech Stack:** Swift, `FileManager`, the existing `BackupWriter` / `MerkleBuilder` / `MerkleManifest` (all MaughamCore), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-07-backup-and-integrity-design.md` — §5.1 (each destination independent + best-effort), §5.4 (skip if unchanged), §5.6 (per-destination retention), §5.8 (per-destination outcome data that status will consume). *Out of scope (later plans):* essential/full classification (§5.3), security-scoped bookmarks + config (§5.1/§5.9), checkpoint trigger + `NSFileCoordinator` source read (§5.4), restore (§6), UI (§5.8 surface).

**Stacking:** Branch from `main` (Plans 1+2 are merged there; this needs `BackupWriter`).

---

## Design notes the implementer must honor

- **No wall-clock in core:** `generationId` (a ULID string) and `builtAt: Date` are caller-supplied.
- **Root hash is content-only:** `MerkleManifest.rootHash` is computed over the file path+hash entries, *not* `builtAt`, so comparing roots across generations correctly detects content changes regardless of when each was built. The skip-unchanged check relies on this.
- **Best-effort independence:** `run` never throws. Per-destination failures become `.failed` outcomes; other destinations still proceed.
- **Same generationId across destinations in one run is intended** — a single backup run stamps one id and writes it to every destination, so a generation id identifies "the project at moment T" across all destinations.

---

## File Structure

**Create:**
- `Packages/MaughamCore/Sources/MaughamCore/BackupRunner.swift` — `BackupDestination`, `BackupOutcome`, `BackupRunner.run(...)` + `latestRootHash` helper.

**Test:**
- `Packages/MaughamCore/Tests/MaughamCoreTests/BackupRunnerTests.swift`

**Test command:** `swift test --package-path Packages/MaughamCore` (filter: `--filter BackupRunnerTests`).

---

## Task 1: Destination + outcome types and the latest-root helper

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/BackupRunner.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupRunnerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MaughamCore

final class BackupRunnerTests: XCTestCase {
    let when = Date(timeIntervalSince1970: 1_700_000_000)

    func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("br-\(UUID().uuidString)")
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    func destDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("brd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_latestRootHash_nilWhenNoGenerations() throws {
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertNil(try BackupRunner.latestRootHash(at: dest))
    }

    func test_latestRootHash_matchesNewestGenerationManifest() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        let gen = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        XCTAssertEqual(try BackupRunner.latestRootHash(at: dest), gen.manifest.rootHash)
    }
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `swift test --package-path Packages/MaughamCore --filter BackupRunnerTests`
Expected: FAIL — `BackupRunner` doesn't exist.

- [ ] **Step 3: Create `BackupRunner.swift`**

```swift
import Foundation

/// A configured backup target: where to write and how many generations to keep.
/// Plain URL — security-scoped bookmark resolution and config persistence are the
/// Mac layer's job; this stays pure and testable.
public struct BackupDestination: Equatable, Sendable {
    public let url: URL
    public let retention: Int
    public init(url: URL, retention: Int) {
        self.url = url
        self.retention = retention
    }
}

/// The result of attempting a backup to one destination. `run` returns one per
/// destination; status UI will consume these.
public enum BackupOutcome: Sendable, Equatable {
    case written(destination: URL, generation: BackupGeneration)
    case skippedUnchanged(destination: URL)
    case failed(destination: URL, message: String)

    public var destination: URL {
        switch self {
        case .written(let d, _), .skippedUnchanged(let d), .failed(let d, _): return d
        }
    }
}

public enum BackupRunner {
    /// The content root hash of the newest committed generation at `destination`,
    /// or nil if there are none (or the newest has no readable manifest). Used to
    /// decide whether the source has changed since the last backup.
    public static func latestRootHash(at destination: URL) throws -> String? {
        guard let id = try BackupWriter.generationIds(at: destination).last else { return nil }
        let manifestURL = destination
            .appendingPathComponent(id)
            .appendingPathComponent(BackupWriter.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let manifest = try JSONDecoder().decode(
            MerkleManifest.self, from: Data(contentsOf: manifestURL))
        return manifest.rootHash
    }
}
```

- [ ] **Step 4: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupRunnerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupRunner.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupRunnerTests.swift
git commit -m "feat(core): BackupRunner types + latestRootHash helper"
```

---

## Task 2: `run` — multi-destination, skip-unchanged, retention

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/BackupRunner.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BackupRunnerTests.swift` (add cases)

- [ ] **Step 1: Add the failing tests**

```swift
    func test_run_writesToAllDestinationsFirstTime() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let d1 = destDir(); let d2 = destDir()
        defer { [source, d1, d2].forEach { try? FileManager.default.removeItem(at: $0) } }

        let outcomes = BackupRunner.run(
            projectURL: source,
            destinations: [BackupDestination(url: d1, retention: 3),
                           BackupDestination(url: d2, retention: 3)],
            generationId: "01A", at: when)

        XCTAssertEqual(outcomes.count, 2)
        for o in outcomes {
            guard case .written = o else { return XCTFail("expected written, got \(o)") }
        }
        XCTAssertEqual(try BackupWriter.generationIds(at: d1), ["01A"])
        XCTAssertEqual(try BackupWriter.generationIds(at: d2), ["01A"])
    }

    func test_run_skipsUnchangedSourceSecondTime() throws {
        let source = try makeTree(["a.md": "alpha"])
        let d1 = destDir()
        defer { [source, d1].forEach { try? FileManager.default.removeItem(at: $0) } }

        _ = BackupRunner.run(projectURL: source,
                             destinations: [BackupDestination(url: d1, retention: 3)],
                             generationId: "01A", at: when)
        // Nothing changed → second run with a NEW id must skip, not write a twin.
        let second = BackupRunner.run(projectURL: source,
                                      destinations: [BackupDestination(url: d1, retention: 3)],
                                      generationId: "01B", at: when)
        guard case .skippedUnchanged = second[0] else { return XCTFail("expected skip, got \(second[0])") }
        XCTAssertEqual(try BackupWriter.generationIds(at: d1), ["01A"])  // still just the first
    }

    func test_run_writesNewGenerationWhenSourceChanges() throws {
        let source = try makeTree(["a.md": "alpha"])
        let d1 = destDir()
        defer { [source, d1].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = BackupRunner.run(projectURL: source,
                             destinations: [BackupDestination(url: d1, retention: 3)],
                             generationId: "01A", at: when)
        // Change the source, then a second run must write a new generation.
        try "CHANGED".write(to: source.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let second = BackupRunner.run(projectURL: source,
                                      destinations: [BackupDestination(url: d1, retention: 3)],
                                      generationId: "01B", at: when)
        guard case .written = second[0] else { return XCTFail("expected written, got \(second[0])") }
        XCTAssertEqual(try BackupWriter.generationIds(at: d1), ["01A", "01B"])
    }

    func test_run_appliesRetentionPerDestination() throws {
        let source = try makeTree(["a.md": "v0"])
        let d1 = destDir()
        defer { [source, d1].forEach { try? FileManager.default.removeItem(at: $0) } }
        // Three changing runs, retention 2 → oldest pruned.
        for (i, id) in ["01A", "01B", "01C"].enumerated() {
            try "v\(i)".write(to: source.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            _ = BackupRunner.run(projectURL: source,
                                 destinations: [BackupDestination(url: d1, retention: 2)],
                                 generationId: id, at: when)
        }
        XCTAssertEqual(try BackupWriter.generationIds(at: d1), ["01B", "01C"])
    }

    func test_run_oneFailingDestinationDoesNotAbortOthers() throws {
        let source = try makeTree(["a.md": "alpha"])
        let good = destDir()
        // A destination URL where a FILE sits where the dir must be → createDirectory fails.
        let badParent = destDir()
        let bad = badParent.appendingPathComponent("blocker")
        try "x".write(to: bad, atomically: true, encoding: .utf8)  // `bad` is a file, not a dir
        defer { [source, good, badParent].forEach { try? FileManager.default.removeItem(at: $0) } }

        let outcomes = BackupRunner.run(
            projectURL: source,
            destinations: [BackupDestination(url: bad, retention: 3),
                           BackupDestination(url: good, retention: 3)],
            generationId: "01A", at: when)

        guard case .failed = outcomes[0] else { return XCTFail("expected failed for bad dest, got \(outcomes[0])") }
        guard case .written = outcomes[1] else { return XCTFail("expected written for good dest, got \(outcomes[1])") }
        XCTAssertEqual(try BackupWriter.generationIds(at: good), ["01A"])  // good one still succeeded
    }
}
```

- [ ] **Step 2: Run, confirm failure** (`run` doesn't exist):

Run: `swift test --package-path Packages/MaughamCore --filter BackupRunnerTests`

- [ ] **Step 3: Add `run` to `BackupRunner`**

```swift
    /// Back up `projectURL` to each destination. Best-effort and independent: a
    /// failing destination becomes a `.failed` outcome and never aborts the others.
    /// A destination whose newest generation already matches the current source is
    /// `.skippedUnchanged` (so idle saves don't churn retention). After a write, the
    /// destination is pruned to its retention. Never throws. `generationId` is a
    /// caller-supplied ULID stamped onto every destination written this run.
    public static func run(
        projectURL: URL,
        destinations: [BackupDestination],
        generationId: String,
        at builtAt: Date
    ) -> [BackupOutcome] {
        // Build the source root once; if the source itself is unreadable, every
        // destination fails identically.
        let sourceRoot: String
        do {
            let rels = try BackupWriter.relativeFilePaths(under: projectURL)
            sourceRoot = try MerkleBuilder.build(
                root: projectURL, relativePaths: rels, at: builtAt).rootHash
        } catch {
            return destinations.map {
                .failed(destination: $0.url, message: "source unreadable: \(error)")
            }
        }

        return destinations.map { dest in
            do {
                if let latest = try latestRootHash(at: dest.url), latest == sourceRoot {
                    return .skippedUnchanged(destination: dest.url)
                }
                let gen = try BackupWriter.write(
                    source: projectURL, to: dest.url, generationId: generationId, at: builtAt)
                try BackupWriter.prune(destination: dest.url, keeping: dest.retention)
                return .written(destination: dest.url, generation: gen)
            } catch {
                return .failed(destination: dest.url, message: "\(error)")
            }
        }
    }
```

- [ ] **Step 4: Run, confirm PASS**

Run: `swift test --package-path Packages/MaughamCore --filter BackupRunnerTests`
Expected: PASS (7 tests in the file).

- [ ] **Step 5: Run the full core suite**

Run: `swift test --package-path Packages/MaughamCore`
Expected: PASS (all).

- [ ] **Step 6: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/BackupRunner.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/BackupRunnerTests.swift
git commit -m "feat(core): BackupRunner.run — multi-destination best-effort backup with skip-unchanged"
```

---

## Self-Review

**Spec coverage:**
- §5.1 each destination independent + best-effort → `run` maps each destination through its own `do/catch`; Task 2 `test_run_oneFailingDestinationDoesNotAbortOthers`. ✓
- §5.4 skip if unchanged → root-hash comparison; `test_run_skipsUnchangedSourceSecondTime` + `test_run_writesNewGenerationWhenSourceChanges`. ✓
- §5.6 per-destination retention → `prune` after write; `test_run_appliesRetentionPerDestination`. ✓
- §5.8 per-destination outcome data → `BackupOutcome` (.written/.skippedUnchanged/.failed) returned per destination. ✓
- Deferred (correctly absent): classification (§5.3), bookmarks/config (§5.1/§5.9), trigger + coordinated read (§5.4), restore (§6), UI. These wrap `BackupRunner`.

**Placeholder scan:** none — all code complete.

**Type consistency:** `BackupDestination(url:retention:)`, `BackupOutcome` cases, `BackupRunner.run`/`latestRootHash` consistent across tasks. Uses real Plan-2 APIs: `BackupWriter.write(source:to:generationId:at:)`, `.generationIds(at:)`, `.prune(destination:keeping:)`, `.relativeFilePaths(under:)`, `.manifestName`, and `MerkleBuilder.build(root:relativePaths:at:)` / `MerkleManifest.rootHash`. `BackupGeneration` is `Equatable` (so `BackupOutcome: Equatable` synthesizes).

**Cross-surface:** all MaughamCore, pure Foundation, additive — no UI, no new dependency.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-07-backup-runner.md`. Branch from `main`. Execute via superpowers:subagent-driven-development.
