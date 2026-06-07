# Backup Mac Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Substantive Mac/SwiftUI work — use a capable model (opus) for the coordinator + bookmark + checkpoint-wiring tasks.**

**Goal:** Make backups actually happen — configure destinations in a new "Backups" Settings tab (security-scoped folder bookmarks + retention), and on every checkpoint (⌘S / auto), verify project integrity then run `BackupRunner` to all destinations off the main actor, surfacing per-destination status.

**Architecture:** A `@MainActor @Observable BackupCoordinator` (mirrors `UpdateChecker`) owns resolved destinations + per-destination status, and exposes `backupNow(projectURL:)`. Destination *config* (security-scoped bookmark data + retention + display name) persists in `UserPreferences` (the existing UserDefaults-backed `@Observable` store). The checkpoint site in `ProjectWindow.CheckpointModifier` fires the backup after `CheckpointCapture.run` completes. Integrity is checked **before** each backup (decision 2026-06-07): a corrupt source is surfaced and the backup is skipped rather than propagating corruption. The `BackupSettingsTab` manages destinations via `NSOpenPanel` + `.withSecurityScope` bookmarks (the established `ProjectStore+References` pattern).

**Tech Stack:** Swift, SwiftUI (`@Observable`, `Form`/`TabView`), AppKit (`NSOpenPanel`), security-scoped bookmarks, the merged MaughamCore backup engine (`BackupRunner`/`BackupWriter`/`ProjectIntegrity`/`ULID`), XCTest (`@MainActor`, `TempDirectory`, `ProjectFactory`).

**Spec:** `docs/superpowers/specs/2026-06-07-backup-and-integrity-design.md` §5.1 (destinations), §5.4 (trigger + integrity-before-backup), §5.8 (status), §10 (decisions: retention local 10/remote 2, Backups Settings tab, verify on open + before each backup). *Deferred to a later plan:* restore (§6), the Verify-project menu command + on-open health *banner* placement, manifest-shadow, derive-and-compare, essential/full classification (this plan does full backups).

**Stacking:** Branch from `main` (the MaughamCore engine is merged there).

---

## Integration map (from codebase exploration)

- Settings tabs: `Maugham/Views/SettingsView.swift` (a `TabView`); tabs live in `Maugham/Views/SettingsTabs/` and take `@Bindable`/`@Environment(UserPreferences.self)`.
- App-level prefs: `Maugham/Preferences/UserPreferences.swift` — `@MainActor @Observable`, UserDefaults-backed, `didSet`-persisted, injected via `.environment(userPreferences)` in `Maugham/MaughamApp.swift`.
- Mac security-scoped bookmarks: `Maugham/Stores/ProjectStore+References.swift` — `url.bookmarkData(options: .withSecurityScope, ...)` and `URL(resolvingBookmarkData:options:[.withSecurityScope],...)`. `NSOpenPanel` usage in `Maugham/MaughamApp.swift`.
- Checkpoint trigger: `Maugham/Views/ProjectWindow.swift` → `CheckpointModifier` (`.onReceive(.maughamSaveCheckpoint)`), which has `store.url` and `allDocIds` and calls `CheckpointCapture.run(...)` then `onSaveFlash()`.
- Project URL: `ProjectStore.url` / `DocumentStore.projectURL`.
- Background work pattern: `Maugham/Updates/UpdateChecker.swift` (`@MainActor`, `@Published` state, `Task` loop).
- Tests: `MaughamTests/` with `TempDirectory` + `ProjectFactory`, `@MainActor final class`, `setUp() async throws`.

---

## File Structure

**Create:**
- `Maugham/Backup/BackupDestinationConfig.swift` — Codable per-destination config (bookmark data + retention + display name).
- `Maugham/Backup/BackupCoordinator.swift` — `@MainActor @Observable`: resolve destinations, run integrity-checked backups, hold status.
- `Maugham/Views/SettingsTabs/BackupSettingsTab.swift` — the Backups Settings tab UI.
- `MaughamTests/BackupCoordinatorTests.swift`

**Modify:**
- `Maugham/Preferences/UserPreferences.swift` — persist `[BackupDestinationConfig]`.
- `Maugham/Views/SettingsView.swift` — register the Backups tab.
- `Maugham/Views/ProjectWindow.swift` — fire `backupNow` after `CheckpointCapture.run`.
- `Maugham/MaughamApp.swift` — instantiate + inject `BackupCoordinator`; resolve bookmarks on launch.

**Test command:** `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (Mac scheme; slower than core `swift test`). Run per-task where practical; full run before the final commit. SwiftUI view tasks (BackupSettingsTab, wiring) are **manual-smoke** verified, not unit-tested.

---

## PHASE A — Config + Coordinator (logic; unit-tested)

### Task 1: `BackupDestinationConfig` + UserPreferences persistence

**Files:**
- Create: `Maugham/Backup/BackupDestinationConfig.swift`
- Modify: `Maugham/Preferences/UserPreferences.swift`
- Test: `MaughamTests/BackupCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

@MainActor
final class BackupCoordinatorTests: XCTestCase {
    func test_userPreferences_persistsBackupDestinations() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let cfg = BackupDestinationConfig(
            id: "d1", displayName: "Local", bookmark: Data([1, 2, 3]), retention: 10)
        do {
            let prefs = UserPreferences(defaults: defaults)
            prefs.backupDestinations = [cfg]
        }
        // A fresh instance on the same defaults must reload it.
        let reloaded = UserPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.backupDestinations, [cfg])
    }
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/BackupCoordinatorTests`
Expected: FAIL — `BackupDestinationConfig` / `backupDestinations` don't exist.

- [ ] **Step 3: Create `Maugham/Backup/BackupDestinationConfig.swift`**

```swift
import Foundation

/// Persisted configuration for one backup destination. The security-scoped
/// bookmark (resolved to a URL at use time) plus how many generations to keep.
/// `id` is stable so status can be keyed to it across resolves.
public struct BackupDestinationConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var bookmark: Data
    public var retention: Int
    public init(id: String, displayName: String, bookmark: Data, retention: Int) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.retention = retention
    }
}
```

- [ ] **Step 4: Add persistence to `UserPreferences.swift`**

Add a stored key, a `didSet`-persisted property, and load-on-init. Follow the existing pattern in the file:

```swift
    private static let backupDestinationsKey = "maugham.backupDestinations"

    public var backupDestinations: [BackupDestinationConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(backupDestinations) {
                defaults.set(data, forKey: Self.backupDestinationsKey)
            }
        }
    }
```

In `init(defaults:)`, after the existing loads, decode (default to empty):

```swift
        if let data = defaults.data(forKey: Self.backupDestinationsKey),
           let decoded = try? JSONDecoder().decode([BackupDestinationConfig].self, from: data) {
            self.backupDestinations = decoded
        } else {
            self.backupDestinations = []
        }
```

> NOTE: read the real `UserPreferences.swift` first; place the property and the init-load consistently with how `theme`/other prefs are done. If init assigns stored properties before the `defaults` capture, mirror that ordering.

- [ ] **Step 5: Run, confirm PASS**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/BackupCoordinatorTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Backup/BackupDestinationConfig.swift Maugham/Preferences/UserPreferences.swift MaughamTests/BackupCoordinatorTests.swift
git commit -m "feat(backup): BackupDestinationConfig + UserPreferences persistence"
```

---

### Task 2: Bookmark resolution → `BackupDestination`

**Files:**
- Modify: `Maugham/Backup/BackupCoordinator.swift` (create)
- Test: `MaughamTests/BackupCoordinatorTests.swift` (add cases)

- [ ] **Step 1: Add the failing test** (round-trips a real folder through a bookmark)

```swift
    func test_resolveDestinations_roundTripsRealFolderBookmark() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let cfg = BackupDestinationConfig(id: "d1", displayName: "L", bookmark: bookmark, retention: 7)

        let resolved = BackupCoordinator.resolveDestinations([cfg])

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].retention, 7)
        XCTAssertEqual(resolved[0].url.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)
    }

    func test_resolveDestinations_dropsUnresolvableBookmarks() {
        let cfg = BackupDestinationConfig(id: "bad", displayName: "X", bookmark: Data([9, 9, 9]), retention: 3)
        XCTAssertTrue(BackupCoordinator.resolveDestinations([cfg]).isEmpty)
    }
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Create `Maugham/Backup/BackupCoordinator.swift` with the resolver**

```swift
import Foundation
import MaughamCore

@MainActor
@Observable
public final class BackupCoordinator {
    public init() {}

    /// Resolve persisted configs into runnable destinations. Unresolvable/stale
    /// bookmarks are dropped (the Settings UI surfaces them separately). Starts
    /// security-scoped access for each resolved URL (held for the process; the
    /// folder is the user's chosen backup root).
    public static func resolveDestinations(_ configs: [BackupDestinationConfig]) -> [BackupDestination] {
        configs.compactMap { cfg in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: cfg.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale) else { return nil }
            _ = url.startAccessingSecurityScopedResource()
            return BackupDestination(url: url, retention: cfg.retention)
        }
    }
}
```

- [ ] **Step 4: Run, confirm PASS**

- [ ] **Step 5: Commit**

```bash
git add Maugham/Backup/BackupCoordinator.swift MaughamTests/BackupCoordinatorTests.swift
git commit -m "feat(backup): BackupCoordinator.resolveDestinations from security-scoped bookmarks"
```

---

### Task 3: `backupNow` — integrity-before-backup + status

**Files:**
- Modify: `Maugham/Backup/BackupCoordinator.swift`
- Test: `MaughamTests/BackupCoordinatorTests.swift` (add cases)

- [ ] **Step 1: Add the failing tests**

```swift
    private func tempProjectWithOps() throws -> URL {
        let proj = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: proj.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
        // a valid op line so the project is non-empty + integrity-clean
        let op = Op(opId: "01ABC", docId: "doc-0f0f0f0f", at: Date(timeIntervalSince1970: 0),
                    device: "macA", session: "s", kind: .checkpoint, changes: [], sequence: nil, provenance: nil)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let line = String(data: try enc.encode(op), encoding: .utf8)!
        try (line + "\n").write(to: proj.appendingPathComponent(".maugham/ops/doc-0f0f0f0f.macA.jsonl"), atomically: true, encoding: .utf8)
        return proj
    }
    private func destDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dst-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_backupNow_writesGenerationAndRecordsStatus() async throws {
        let proj = try tempProjectWithOps(); let dest = destDir()
        defer { [proj, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]

        await coordinator.backupNow(projectURL: proj, generationId: "01GEN", at: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01GEN"])
        if case .ok = coordinator.lastResult { } else { XCTFail("expected ok, got \(String(describing: coordinator.lastResult))") }
    }

    func test_backupNow_abortsAndFlagsWhenSourceCorrupt() async throws {
        let proj = try tempProjectWithOps(); let dest = destDir()
        defer { [proj, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        // Corrupt the op log so ProjectIntegrity.check is unhealthy.
        try "GARBAGE NOT JSON\n".write(to: proj.appendingPathComponent(".maugham/ops/doc-0f0f0f0f.macA.jsonl"), atomically: true, encoding: .utf8)
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]

        await coordinator.backupNow(projectURL: proj, generationId: "01GEN", at: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(try BackupWriter.generationIds(at: dest), [])  // nothing backed up
        if case .integrityFailed = coordinator.lastResult { } else { XCTFail("expected integrityFailed, got \(String(describing: coordinator.lastResult))") }
    }
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add state + `backupNow` to `BackupCoordinator`**

```swift
    /// Resolved destinations to back up to. Set from UserPreferences at app launch
    /// and whenever the config changes.
    public var destinations: [BackupDestination] = []

    /// Outcome of the most recent backup attempt (drives status UI).
    public enum Result: Sendable, Equatable {
        case idle
        case ok(written: Int, skipped: Int, failed: Int, at: Date)
        case integrityFailed(summary: String)
        case noDestinations
    }
    public private(set) var lastResult: Result = .idle

    /// Run an integrity check, then (if clean) back up to all destinations. A
    /// corrupt source is surfaced and the backup is skipped — corruption must not
    /// propagate to destinations. Never throws.
    public func backupNow(projectURL: URL, generationId: String, at now: Date) async {
        guard !destinations.isEmpty else { lastResult = .noDestinations; return }

        // Integrity-before-backup (decision 2026-06-07).
        if let report = try? await ProjectIntegrity.check(projectURL: projectURL), !report.isHealthy {
            let summary = "skips:\(report.docSkips.count) twins:\(report.conflictTwins.count) dangling:\(report.danglingPointers.count)"
            lastResult = .integrityFailed(summary: summary)
            return
        }

        // BackupRunner.run is synchronous filesystem work; hop off the main actor.
        let dests = destinations
        let outcomes = await Task.detached {
            BackupRunner.run(projectURL: projectURL, destinations: dests, generationId: generationId, at: now)
        }.value

        var written = 0, skipped = 0, failed = 0
        for o in outcomes {
            switch o {
            case .written: written += 1
            case .skippedUnchanged: skipped += 1
            case .failed: failed += 1
            }
        }
        lastResult = .ok(written: written, skipped: skipped, failed: failed, at: now)
    }
```

> NOTE: `BackupRunner`/`BackupDestination`/`BackupWriter`/`ProjectIntegrity`/`Op`/`JSONLAppendStore` are all in `MaughamCore` (already `import MaughamCore` at top). `BackupRunner.run` is a `nonisolated` static so it's safe in `Task.detached`.

- [ ] **Step 4: Run, confirm PASS**

- [ ] **Step 5: Run the full Mac suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: BUILD + TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Backup/BackupCoordinator.swift MaughamTests/BackupCoordinatorTests.swift
git commit -m "feat(backup): BackupCoordinator.backupNow — integrity-checked backup + status"
```

---

## PHASE B — UI + wiring (manual-smoke verified)

### Task 4: Backups Settings tab

**Files:**
- Create: `Maugham/Views/SettingsTabs/BackupSettingsTab.swift`
- Modify: `Maugham/Views/SettingsView.swift`

- [ ] **Step 1: Create `BackupSettingsTab.swift`**

```swift
import SwiftUI
import AppKit

struct BackupSettingsTab: View {
    @Bindable var preferences: UserPreferences

    var body: some View {
        Form {
            Section("Backup destinations") {
                if preferences.backupDestinations.isEmpty {
                    Text("No destinations. Add a folder outside iCloud (a local folder, external drive, or a Dropbox/Drive-synced folder) to keep verified copies of your projects.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(preferences.backupDestinations) { cfg in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(cfg.displayName)
                            Text("Keep \(cfg.retention) generations").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { remove(cfg) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add destination…") { addDestination() }
            }
            Section {
                Text("Backups run automatically when you save (⌘S). A copy is verified, then written to each destination; a corrupt project is detected and skipped rather than backed up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func addDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a backup folder (outside iCloud)."
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        // local folder → keep 10 generations by default (decision 2026-06-07).
        let cfg = BackupDestinationConfig(
            id: UUID().uuidString, displayName: url.lastPathComponent, bookmark: bookmark, retention: 10)
        preferences.backupDestinations.append(cfg)
    }

    private func remove(_ cfg: BackupDestinationConfig) {
        preferences.backupDestinations.removeAll { $0.id == cfg.id }
    }
}
```

- [ ] **Step 2: Register the tab in `SettingsView.swift`**

Add inside the `TabView`, following the existing pattern (the view gets `UserPreferences` — read the file for whether it's `@Environment` or passed in, and match):

```swift
            BackupSettingsTab(preferences: themeManager)
                .tabItem { Label("Backups", systemImage: "externaldrive.badge.timemachine") }
```

> If `SettingsView` exposes `UserPreferences` under a different binding name than `themeManager`, use that. Match the established tab call style exactly.

- [ ] **Step 3: Build (no unit test for SwiftUI views)**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/SettingsTabs/BackupSettingsTab.swift Maugham/Views/SettingsView.swift
git commit -m "feat(backup): Backups settings tab — add/remove destinations"
```

---

### Task 5: Inject the coordinator + wire the checkpoint trigger

**Files:**
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Instantiate + inject `BackupCoordinator` in `MaughamApp.swift`**

Mirror how `UserPreferences`/`UpdateChecker` are created and injected. Add a stored `@State`/property:

```swift
    @State private var backupCoordinator = BackupCoordinator()
```

Inject into the environment alongside the existing `.environment(userPreferences)`:

```swift
                .environment(backupCoordinator)
```

And resolve destinations at launch + whenever prefs change — in the app's existing `.task`/onChange surface (mirror where `UpdateChecker.startBackgroundLoop()` is kicked off):

```swift
                .task {
                    backupCoordinator.destinations =
                        BackupCoordinator.resolveDestinations(userPreferences.backupDestinations)
                }
                .onChange(of: userPreferences.backupDestinations) { _, new in
                    backupCoordinator.destinations = BackupCoordinator.resolveDestinations(new)
                }
```

> Read `MaughamApp.swift` to place these on the correct scene/view (the same one that already carries `.environment(userPreferences)`).

- [ ] **Step 2: Fire backup after checkpoint in `ProjectWindow.swift`**

In `CheckpointModifier`, read the injected coordinator and call it after `CheckpointCapture.run`. Add `@Environment(BackupCoordinator.self) private var backupCoordinator` to the modifier (or thread it through if the modifier can't hold `@Environment` — read the file). In the `.onReceive(.maughamSaveCheckpoint)` task, after the `CheckpointCapture.run(...)` call:

```swift
                    _ = try? await CheckpointCapture.run(
                        projectURL: store.url, activeDocId: activeDocId, allDocIds: allDocIds,
                        device: _checkpointDeviceId, session: _checkpointSessionId, label: nil)
                    onSaveFlash()
                    // Back up after the checkpoint is durable. Fire-and-forget; the
                    // coordinator hops off-main internally and records status.
                    await backupCoordinator.backupNow(
                        projectURL: store.url, generationId: ULID.generate(), at: Date())
```

> `ULID` is in MaughamCore (`import MaughamCore` is already present in this file via the OpLog types — confirm). If `CheckpointModifier` can't gain an `@Environment` cleanly, pass the coordinator into the modifier from `ProjectWindow`'s body where other env values are read.

- [ ] **Step 3: Build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat(backup): inject BackupCoordinator + run backup on checkpoint"
```

---

### Task 6: Surface backup status in the save flash

**Files:**
- Modify: `Maugham/Views/SaveFlashOverlay.swift` (and its call site if needed)

- [ ] **Step 1: Show the last backup result in the flash**

When ⌘S flashes "Saved", append a backup hint if a backup just ran. Read `SaveFlashOverlay.swift` and its call site; add an optional subtitle driven by `BackupCoordinator.lastResult`:

```swift
    // In SaveFlashOverlay, add:
    var backupNote: String? = nil
    // ...inside the HStack, after "Saved":
    if let backupNote {
        Text("· \(backupNote)").font(.system(size: 11)).foregroundStyle(.secondary)
    }
```

At the call site (ProjectWindow), compute the note from the coordinator:

```swift
    private func backupNote(_ r: BackupCoordinator.Result) -> String? {
        switch r {
        case .idle, .noDestinations: return nil
        case .ok(let w, let s, let f, _):
            if f > 0 { return "backup: \(f) failed" }
            if w > 0 { return "backed up" }
            return s > 0 ? "backup up to date" : nil
        case .integrityFailed: return "⚠ integrity check failed — not backed up"
        }
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/SaveFlashOverlay.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat(backup): surface backup result in the save flash"
```

---

## Manual smoke test (run after Task 6)

1. Launch dev build → Settings → **Backups** → Add destination → pick `~/MaughamBackups` (create it). It appears, "Keep 10 generations".
2. Open a project, type a sentence, ⌘S. Flash shows "Saved · backed up".
3. In Finder, `~/MaughamBackups/<manifest.id>/<ULID>/` exists, contains the project + `.maugham-backup-manifest.json`.
4. ⌘S again with no edits → a second generation is NOT created (skip-unchanged). Edit, ⌘S → a new generation appears.
5. Corrupt an op-log line by hand, ⌘S → flash shows "⚠ integrity check failed — not backed up"; no new generation written.

---

## Self-Review

**Spec coverage:** §5.1 destinations (config + bookmarks + Settings tab) → Tasks 1,2,4. §5.4 trigger + integrity-before-backup → Tasks 3,5. §5.6 retention (default 10) → Tasks 1,4 + engine. §5.8 status → Tasks 3,6. Decisions (retention 10/remote 2 default, Backups tab, verify-before-backup) honored. Deferred (restore, on-open verify banner, classification, manifest-shadow, derive-and-compare) correctly absent.

**Placeholder scan:** SwiftUI/wiring tasks reference real files to read before editing (UserPreferences binding name, MaughamApp injection site, CheckpointModifier env access) — these are "match the existing pattern" notes, not placeholders; the code to add is fully given.

**Type consistency:** `BackupDestinationConfig` (Task 1) used in 2,4,5. `BackupCoordinator.resolveDestinations`/`destinations`/`backupNow`/`Result`/`lastResult` consistent across 2,3,5,6. Engine APIs (`BackupRunner.run`, `BackupWriter.generationIds`, `BackupDestination`, `ProjectIntegrity.check`, `ULID.generate`) are the merged MaughamCore signatures.

**Risk notes for the implementer:** (a) `UserPreferences.init` ordering — place the new load consistently. (b) `CheckpointModifier` gaining `@Environment(BackupCoordinator.self)` — if a ViewModifier can't read it cleanly, thread it from `ProjectWindow`. (c) Security-scoped `startAccessingSecurityScopedResource` is started at resolve and intentionally not balanced with `stop` (process-lifetime access to the user's backup root) — acceptable for v1; note it.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-07-backup-mac-integration.md`. Branch from `main`. Execute via superpowers:subagent-driven-development — **use opus for Tasks 3 and 5** (coordinator logic + checkpoint/app wiring are the substantive, architecture-touching tasks; the rest are mechanical given the code above). Phase A is unit-tested; Phase B is build-verified + the manual smoke above.
