# Backup Recovery UI + Per-Project Keying — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. **Phase B is substantive Mac/SwiftUI (windows, banner, focused menu command) — use opus.** Phase A is unit-tested; Phase B is build-verified + manual smoke.

**Goal:** (A) Fix backup keying so each project's generations live under `<destination>/<projectKey>/` (not flat), so multiple projects can share a backup folder. (B) Build the recovery UI: a "⚠ Backups paused" banner on the project window and a dedicated `RestoreWindow` that lists a project's generations and restores one **beside** the original.

**Architecture:** Keying stays out of the project-agnostic core engine — the **Mac `BackupCoordinator`** appends a per-project key (the minted `ProjectManifest.id`, falling back to the folder name) to each destination URL before calling `BackupRunner`/`BackupRestore`. The banner mirrors `UpdateBannerView` (mounted via `.safeAreaInset(.top)` on `ProjectWindow`, observing `BackupCoordinator.lastResult`). `RestoreWindow` is a `WindowGroup(for: URL.self)` opened with the project URL from (a) the banner's "Restore…" button and (b) a `File → Restore from Backup…` command scoped to the focused project via `@FocusedValue`. Restore uses `BackupRestore.restoreBeside` into a user-chosen folder (`NSSavePanel`), then reveals it in Finder.

**Tech Stack:** SwiftUI (`WindowGroup`, `@FocusedValue`, `openWindow`, `.safeAreaInset`), AppKit (`NSSavePanel`, `NSWorkspace`), the merged MaughamCore backup/restore engine, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-07-backup-and-integrity-design.md` §5.2 (per-project keying by `manifest.id`), §6 (restore-beside), §10/§8 (decisions). *Deferred (recorded follow-on):* single-document restore (op-log surgery); derive-and-compare.

**Stacking:** Branch from `main`.

---

## Integration map (from codebase exploration)

- `ProjectManifest` (MaughamCore): `static let fileName = "project.maugham.json"`, `static func makeDecoder() -> JSONDecoder`, `var id: String?`.
- Update banner: `Maugham/Updates/UpdateBannerView.swift`; mounted on `ProjectWindow` at `.safeAreaInset(edge: .top, spacing: 0) { UpdateBannerView() }` (~ProjectWindow.swift:156).
- `BackupCoordinator` (`@MainActor @Observable`): `destinations: [BackupDestination]`, `lastResult: Result` (`.integrityFailed(summary:)`), injected on `ProjectWindow` via `.environment(backupCoordinator)` (MaughamApp ~258).
- Window scene pattern: `WindowGroup(id: "project", for: URL.self) { $url in … }` (MaughamApp ~253); opened via `@Environment(\.openWindow)` → `openWindow(id:"project", value: url)`. Auxiliary `Window("Check for Updates", id:)` + `UpdateMenuCommand` use `openWindow(id:)`.
- Window-scoped menu commands: post a notification handled by a per-window `ViewModifier` (the `RewindModifier`/`.maughamOpenRewind` pattern, scoped by `note.object == store.url`) — or `@FocusedValue`. Both are valid; this plan uses `@FocusedValue` for the project URL.
- `NSSavePanel` usage exists at ProjectWindow ~445; reveal-in-Finder is `NSWorkspace.shared.activateFileViewerSelecting([url])`.
- Restore engine (MaughamCore): `BackupRestore.listGenerations(across: [URL])`, `verify`, `newestIntact`, `restoreBeside(_:to:)`; `RestoreGeneration { destination, id, builtAt, directory }`.

---

## File Structure

**Create:**
- `Maugham/Views/BackupRecoveryBanner.swift` — the "backups paused" banner.
- `Maugham/Views/RestoreWindow.swift` — the restore browser + restore flow.

**Modify:**
- `Maugham/Backup/BackupCoordinator.swift` — per-project keying (`projectKey`, scope `backupNow`, `generations(forProject:)`).
- `Maugham/Views/ProjectWindow.swift` — mount the banner; set `@FocusedValue` project URL.
- `Maugham/MaughamApp.swift` — `RestoreWindow` scene; `File → Restore from Backup…` command.
- `MaughamTests/BackupCoordinatorTests.swift` — keying tests.

**Test:** Phase A via `xcodebuild … -only-testing:MaughamTests/BackupCoordinatorTests`; full suite before final commit. Phase B is build + the manual smoke at the end.

---

## PHASE A — Per-project keying (unit-tested)

### Task 1: Key generations by project under each destination

**Files:**
- Modify: `Maugham/Backup/BackupCoordinator.swift`
- Test: `MaughamTests/BackupCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests** (append to `BackupCoordinatorTests`)

```swift
    @MainActor
    func test_backupNow_keysGenerationsUnderProjectSubfolder() async throws {
        let proj = try tempProjectWithOps()  // existing helper
        // Give the project a manifest with a known id.
        try #"{"id":"proj-AAAA","schemaVersion":1}"#.write(
            to: proj.appendingPathComponent("project.maugham.json"), atomically: true, encoding: .utf8)
        let dest = destDir()                  // existing helper
        defer { [proj, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]

        await coordinator.backupNow(projectURL: proj, generationId: "01GEN", at: Date(timeIntervalSince1970: 1))

        // Generation lives under <dest>/<manifest.id>/, NOT flat under <dest>.
        XCTAssertEqual(try BackupWriter.generationIds(at: dest.appendingPathComponent("proj-AAAA")), ["01GEN"])
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), [])  // nothing flat
    }

    @MainActor
    func test_generationsForProject_listsOnlyThatProject() async throws {
        let projA = try tempProjectWithOps()
        try #"{"id":"proj-A","schemaVersion":1}"#.write(
            to: projA.appendingPathComponent("project.maugham.json"), atomically: true, encoding: .utf8)
        let projB = try tempProjectWithOps()
        try #"{"id":"proj-B","schemaVersion":1}"#.write(
            to: projB.appendingPathComponent("project.maugham.json"), atomically: true, encoding: .utf8)
        let dest = destDir()
        defer { [projA, projB, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]
        await coordinator.backupNow(projectURL: projA, generationId: "01A", at: Date(timeIntervalSince1970: 1))
        await coordinator.backupNow(projectURL: projB, generationId: "01B", at: Date(timeIntervalSince1970: 2))

        // Same shared destination, but each project sees only its own generations.
        XCTAssertEqual(coordinator.generations(forProject: projA).map(\.id), ["01A"])
        XCTAssertEqual(coordinator.generations(forProject: projB).map(\.id), ["01B"])
    }
```

> If `tempProjectWithOps()`/`destDir()` aren't already present from the Plan 4 tests, add the same minimal helpers used there (create `.maugham/ops` with one valid `Op` line; create a temp dir).

- [ ] **Step 2: Run, confirm failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/BackupCoordinatorTests`

- [ ] **Step 3: Add keying to `BackupCoordinator`**

Add the helper and scope `backupNow`'s destinations through it. Read the real `backupNow` and edit in place — keep the integrity-before-backup block; only change what destinations are passed to `BackupRunner.run`.

```swift
    /// The per-project subfolder name under a destination: the project's minted
    /// `ProjectManifest.id`, falling back to the folder name if the manifest has
    /// no id (older projects). Keeps each project's generations separate so several
    /// projects can share one backup destination.
    public static func projectKey(for projectURL: URL) -> String {
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: data),
           let id = manifest.id, !id.isEmpty {
            return id
        }
        return projectURL.lastPathComponent
    }

    /// Per-project destination URLs (`<destination>/<projectKey>`), preserving retention.
    private func projectDestinations(for projectURL: URL) -> [BackupDestination] {
        let key = Self.projectKey(for: projectURL)
        return destinations.map {
            BackupDestination(url: $0.url.appendingPathComponent(key), retention: $0.retention)
        }
    }

    /// Generations for one project across all destinations, newest-first.
    public func generations(forProject projectURL: URL) -> [RestoreGeneration] {
        BackupRestore.listGenerations(across: projectDestinations(for: projectURL).map(\.url))
    }
```

Then in `backupNow`, change the `BackupRunner.run(...)` call to use the per-project destinations:

```swift
        let dests = projectDestinations(for: projectURL)
        let outcomes = await Task.detached {
            BackupRunner.run(projectURL: projectURL, destinations: dests, generationId: generationId, at: now)
        }.value
```

- [ ] **Step 4: Run, confirm PASS** (the new tests + the existing ones)

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/BackupCoordinatorTests`

> Note: the existing Plan-4 `test_backupNow_writesGenerationAndRecordsStatus` asserts a generation under `dest` directly — update it to assert under `dest/<key>` (give that test's project a manifest id, or assert under `dest/<projectFolderName>` since no manifest → folder-name fallback). Fix it to match the new keying; don't delete the assertion.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Backup/BackupCoordinator.swift MaughamTests/BackupCoordinatorTests.swift
git commit -m "fix(backup): key generations per project (manifest.id) under each destination"
```

---

## PHASE B — Recovery UI (build-verified + manual smoke)

### Task 2: "Backups paused" banner

**Files:**
- Create: `Maugham/Views/BackupRecoveryBanner.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Create `BackupRecoveryBanner.swift`**

```swift
import SwiftUI

/// Shown across the top of a project window when the last backup was refused
/// because the project failed its integrity check — pairs the warning with the
/// Restore remedy. Mirrors `UpdateBannerView`.
struct BackupRecoveryBanner: View {
    let projectURL: URL
    @Environment(BackupCoordinator.self) private var backupCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if case .integrityFailed = backupCoordinator.lastResult {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Backups paused — this project failed an integrity check")
                        .font(.callout)
                    Text("New saves aren't being backed up until this is resolved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore…") { openWindow(id: "backup-restore", value: projectURL) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
            .overlay(Divider(), alignment: .bottom)
        }
    }
}
```

- [ ] **Step 2: Mount it on `ProjectWindow`** next to the update banner. Find `.safeAreaInset(edge: .top, spacing: 0) { UpdateBannerView() }` and add the backup banner (the project URL is available as `url`/`store.url`):

```swift
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    UpdateBannerView()
                    if let store { BackupRecoveryBanner(projectURL: store.url) }
                }
            }
```

> Read the real mount site; match whatever `store`/`url` binding is in scope. If `store` is optional and not yet loaded, the `if let` guards it.

- [ ] **Step 3: Build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/BackupRecoveryBanner.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat(backup): 'backups paused — integrity failed' banner with Restore action"
```

---

### Task 3: RestoreWindow + scene + File-menu entry + restore flow

**Files:**
- Create: `Maugham/Views/RestoreWindow.swift`
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (focused value)

- [ ] **Step 1: Create `RestoreWindow.swift`**

```swift
import SwiftUI
import AppKit
import MaughamCore

struct RestoreWindow: View {
    let projectURL: URL
    @Environment(BackupCoordinator.self) private var backupCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var generations: [RestoreGeneration] = []
    @State private var selection: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Restore \(projectURL.lastPathComponent)").font(.headline)
                .padding(12)
            Divider()
            if generations.isEmpty {
                ContentUnavailableView("No backups found",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("No backup generations exist for this project yet."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(generations, id: \.id, selection: $selection) { gen in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gen.builtAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? gen.id)
                            Text(gen.destination.deletingLastPathComponent().lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if BackupRestore.verify(gen).isEmpty {
                            Label("Verified", systemImage: "checkmark.seal").labelStyle(.iconOnly)
                                .foregroundStyle(.green).help("Integrity verified")
                        } else {
                            Label("Corrupt", systemImage: "exclamationmark.triangle").labelStyle(.iconOnly)
                                .foregroundStyle(.orange).help("This generation failed verification")
                        }
                    }
                }
            }
            Divider()
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Restore a Copy…") { restore() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }.padding(12)
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { generations = backupCoordinator.generations(forProject: projectURL) }
    }

    private func restore() {
        guard let id = selection, let gen = generations.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.message = "Choose where to restore a copy of this project."
        panel.nameFieldStringValue = projectURL.lastPathComponent + " (restored)"
        panel.directoryURL = projectURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            // NSSavePanel may have created/cleared the target; restoreBeside refuses an
            // existing target, so remove an empty placeholder the panel made.
            try? FileManager.default.removeItem(at: target)
            let restored = try BackupRestore.restoreBeside(gen, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([restored])
            dismiss()
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
        }
    }
}
```

> `ContentUnavailableView` needs the fill frame (tripwire 15) — applied above. Verify `RestoreGeneration` is the type name from MaughamCore; `verify`/`restoreBeside` are static on `BackupRestore`.

- [ ] **Step 2: Register the scene + menu command + focused value in `MaughamApp.swift`**

Add the scene (near the `project` WindowGroup), injecting the coordinator:

```swift
        WindowGroup("Restore Backup", id: "backup-restore", for: URL.self) { $projectURL in
            if let projectURL {
                RestoreWindow(projectURL: projectURL)
                    .environment(backupCoordinator)
            } else {
                Text("No project").foregroundStyle(.secondary)
            }
        }
        .windowResizability(.contentMinSize)
```

Add a `File` menu command that opens it for the focused project (define a focused-value key):

```swift
// Top level (e.g. in MaughamApp.swift or a small Focus file):
struct FocusedProjectURLKey: FocusedValueKey { typealias Value = URL }
extension FocusedValues {
    var projectURL: URL? {
        get { self[FocusedProjectURLKey.self] }
        set { self[FocusedProjectURLKey.self] = newValue }
    }
}
```

In the app's `.commands { … }` (add a `CommandGroup`):

```swift
            CommandGroup(after: .saveItem) {
                FocusedRestoreButton()
            }
```

```swift
private struct FocusedRestoreButton: View {
    @FocusedValue(\.projectURL) private var projectURL
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Restore from Backup…") {
            if let projectURL { openWindow(id: "backup-restore", value: projectURL) }
        }
        .disabled(projectURL == nil)
    }
}
```

- [ ] **Step 3: Publish the focused project URL from `ProjectWindow`** — add to its body:

```swift
            .focusedSceneValue(\.projectURL, store?.url)
```

> Read the real ProjectWindow body to place this on the top-level content. If `store` is optional, `store?.url` is fine (nil until loaded → command disabled, which is correct).

- [ ] **Step 4: Build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED.

- [ ] **Step 5: Full test suite (no regression)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` → TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Views/RestoreWindow.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat(backup): RestoreWindow + File-menu entry; restore beside via save panel"
```

---

## Manual smoke (after Task 3)

1. **Keying:** add a backup destination, ⌘S in Project A; in Finder the generation is under `<dest>/<project-id>/<ULID>/` (a subfolder per project, not flat). Back up a *second* project to the same destination → a *second* `<dest>/<project-id-2>/` appears; they don't intermix.
2. **Restore (proactive):** **File → Restore from Backup…** → window lists this project's generations with ✓ badges → select one → "Restore a Copy…" → choose a folder → it restores and reveals in Finder; the live project is untouched.
3. **Warning + reactive restore:** corrupt an op-log line, ⌘S → the **orange "Backups paused" banner** appears → click **Restore…** → same window opens for this project.
4. Restoring a **corrupt-badged** generation shows the "failed verification" error and writes nothing.

---

## Self-Review

**Spec coverage:** §5.2 per-project keying → Task 1 (`projectKey` + scoped `backupNow`/`generations`). §6 restore-beside + integrity badge + auto-bisect-available → Task 3 (uses `BackupRestore`). §10 banner placement → Task 2; entry points = banner + File menu (Settings button dropped: per-project action, Settings has no project context). Deferred (recorded): single-doc restore, derive-and-compare.

**Placeholder scan:** SwiftUI/wiring steps point at real files to read and match (mount site, commands block, focused value placement) — the code to add is complete.

**Type consistency:** `BackupCoordinator.projectKey`/`projectDestinations`/`generations(forProject:)`; `RestoreGeneration`/`BackupRestore.listGenerations`/`verify`/`restoreBeside`; `FocusedValues.projectURL`. All match merged signatures.

**Risk notes:** (a) the existing Plan-4 keying test must be updated to the subfolder layout (Task 1 Step 4 note). (b) `@FocusedValue` menu wiring is the fiddliest part — if it resists, the banner still covers the critical reactive path; fall back to a notification-based command scoped like `RewindModifier`. (c) `NSSavePanel` creates the chosen path — `restoreBeside` refuses an existing target, so remove the placeholder first (done in code).

---

## Execution Handoff

Saved to `docs/superpowers/plans/2026-06-07-backup-recovery-and-keying.md`. Branch from `main`. Execute via superpowers:subagent-driven-development — **opus for both phases** (Phase A touches the keying correctness; Phase B is SwiftUI scene/focus/window wiring). Phase A unit-tested; Phase B build-verified, then the manual smoke above.
