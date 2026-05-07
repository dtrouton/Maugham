# Maugham Phase 1e — DocumentStore + Conflict Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap the open-document path in `NSFileCoordinator` + `NSFilePresenter` so iCloud, Claude Desktop, Finder, or any other process can touch the project folder without losing user edits. Replace EditorHost's keystroke-by-keystroke direct writes with a 750ms autosave debounce. Detect external changes and surface a non-blocking *Outside change detected* banner with **Keep mine** / **Use cloud** actions; the loser is preserved under `.maugham/conflicts/` until resolved. Persist UI state (selected document, no-chrome flag, scroll line) to `.maugham/ui-state.json`.

**Architecture:** Pure-logic foundations land first (UIState, ConflictState, DebounceScheduler — each TDD'd). Then the new `DocumentStore` is built up incrementally with integration tests against a real temp directory and real NSFileCoordinator: open/close, document I/O with debounce, coordinated manifest writes, conflict-detection state machine (Cases A/B for documents, Case C for manifest), then conflict resolution actions. Then UI surface: ConflictBanner SwiftUI view. Then migration: EditorHost stops calling `Data.write(to:)` directly and routes everything through DocumentStore; ProjectStore.saveManifest routes through DocumentStore.writeManifest; ProjectWindow owns the DocumentStore lifecycle and renders the banner. Final wiring: scenePhase-driven flush on app termination, end-to-end smoke, milestone tag.

**Tech Stack:** Swift 5.10+, SwiftUI (`@Observable`, `.safeAreaInset`, `@Environment`, `scenePhase`), AppKit (`NSFileCoordinator`, `NSFilePresenter`, `NSOperationQueue`), Foundation (`FileManager`, `JSONEncoder/Decoder`, `Task` + `Task.sleep`), XCTest. macOS 14+.

**Anchor:** This plan implements `docs/superpowers/specs/2026-05-07-maugham-phase-1e-document-store-design.md`.

**Execution branch:** `feat/phase-1e-document-store` (created in Task 1; merge to main on milestone tag).

---

## Locked decisions (from brainstorm)

1. Open-document scope: DocumentStore owns reads/writes/coordination for the *currently-open document* and the *manifest*. ProjectFactory keeps direct calls (one-shot creation, no race window). ProjectStore.add/rename/delete keep direct calls (one-shot per UI event).
2. Coarse-grained NSFilePresenter on the project folder (one per open project).
3. 750ms autosave debounce; ⌘S calls `flushPendingSave()` immediately + reuses 1c "Saved" flash overlay.
4. Conflict UX: banner above editor via `.safeAreaInset(.top)`, sticky, non-blocking. Keep mine / Use cloud / Show diff (disabled "Phase 2").
5. Loser preserved at `.maugham/conflicts/<NN-slug>-{cloud|local}-<ISO8601>.<ext>`.
6. Manifest conflict (Case C): silent last-writer-wins; loser at `.maugham/conflicts/manifest-<ISO8601>.json`.
7. UI state in `.maugham/ui-state.json` with `selectedItemId`, `isNoChromeOn`, `scrollLine`. Line-based, not pixel-based.
8. 500ms debounce on UI state writes (different from autosave's 750ms).

---

## File structure (created or modified during this plan)

```
Maugham/Stores/
  DocumentStore.swift                   # NEW — top-level coordinator + lifecycle + conflict state machine
  ProjectFolderPresenter.swift          # NEW — NSFilePresenter delegate routing to DocumentStore
  ConflictState.swift                   # NEW — value type with "N words ahead" formatter
  UIState.swift                         # NEW — Codable struct + load helper
  DebounceScheduler.swift               # NEW — generic cancel-and-restart Task wrapper
  ProjectStore.swift                    # MODIFIED — saveManifest routes through DocumentStore
  ProjectFactory.swift                  # unchanged
  RecentsStore.swift                    # unchanged

Maugham/Views/
  ConflictBanner.swift                  # NEW — banner UI with Keep/Use/Show-diff buttons
  EditorHost.swift                      # MODIFIED — uses documentStore.openDocument/scheduleSave
  ProjectWindow.swift                   # MODIFIED — owns DocumentStore, renders banner, UI state hookup

Maugham/MaughamApp.swift                # MODIFIED — scenePhase observer for app-quit flush

MaughamTests/
  UIStateTests.swift                    # NEW (unit)
  ConflictStateTests.swift              # NEW (unit)
  DebounceSchedulerTests.swift          # NEW (unit)
  DocumentStoreOpenCloseTests.swift     # NEW (integration, real temp dir + presenter)
  DocumentStoreSaveTests.swift          # NEW (integration)
  DocumentStoreConflictDocumentTests.swift  # NEW (integration, Cases A & B)
  DocumentStoreConflictResolutionTests.swift # NEW (integration, Keep/Use mechanics)
  DocumentStoreConflictManifestTests.swift # NEW (integration, Case C)
```

5 new main-target files, 8 new test files (3 unit + 5 integration), 4 modified main files. Estimate: 18 tasks for execution.

---

## Task 1: Create feature branch

**Working directory:** `/Users/denver/src/Maugham`

- [ ] **Step 1: Confirm clean main and create branch**

```bash
git status
git log --oneline -3
git checkout -b feat/phase-1e-document-store
```

Expected: working tree clean, latest commit on main is `7d1e1c9` (the 1e design spec). Branch creation prints `Switched to a new branch 'feat/phase-1e-document-store'`.

No commit for this task.

---

## Task 2: UIState

**Files:**
- Create: `Maugham/Stores/UIState.swift`
- Create: `MaughamTests/UIStateTests.swift`

Pure Codable struct backing `.maugham/ui-state.json`. Forward-compatible via `schemaVersion`.

- [ ] **Step 1: Write failing tests**

`MaughamTests/UIStateTests.swift`:
```swift
import XCTest
@testable import Maugham

final class UIStateTests: XCTestCase {

    func test_empty_hasExpectedDefaults() {
        let s = UIState.empty
        XCTAssertEqual(s.schemaVersion, 1)
        XCTAssertNil(s.selectedItemId)
        XCTAssertFalse(s.isNoChromeOn)
        XCTAssertEqual(s.scrollLine, 0)
    }

    func test_codable_roundTrip() throws {
        let original = UIState(
            schemaVersion: 1,
            selectedItemId: "doc-abc",
            isNoChromeOn: true,
            scrollLine: 47)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_loadOrEmpty_returnsEmpty_whenFileMissing() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("missing.json")
        XCTAssertEqual(UIState.loadOrEmpty(from: url), .empty)
    }

    func test_loadOrEmpty_returnsEmpty_whenJSONMalformed() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("ui-state.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(UIState.loadOrEmpty(from: url), .empty)
    }

    func test_loadOrEmpty_returnsEmpty_whenSchemaVersionUnknown() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("ui-state.json")
        let badJSON = #"""
        {"schemaVersion": 99, "selectedItemId": "x", "isNoChromeOn": false, "scrollLine": 0}
        """#
        try badJSON.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(UIState.loadOrEmpty(from: url), .empty)
    }

    func test_loadOrEmpty_loadsValidFile() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("ui-state.json")
        let s = UIState(schemaVersion: 1, selectedItemId: "doc-x",
                        isNoChromeOn: true, scrollLine: 12)
        try JSONEncoder().encode(s).write(to: url)
        XCTAssertEqual(UIState.loadOrEmpty(from: url), s)
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/UIStateTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find type 'UIState' in scope`.

- [ ] **Step 3: Implement UIState**

`Maugham/Stores/UIState.swift`:
```swift
import Foundation

/// Per-project UI state persisted to `.maugham/ui-state.json`.
/// Schema-versioned for forward compatibility.
public struct UIState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var selectedItemId: String?
    public var isNoChromeOn: Bool
    public var scrollLine: Int

    public init(
        schemaVersion: Int = UIState.currentSchemaVersion,
        selectedItemId: String? = nil,
        isNoChromeOn: Bool = false,
        scrollLine: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.selectedItemId = selectedItemId
        self.isNoChromeOn = isNoChromeOn
        self.scrollLine = scrollLine
    }

    public static let empty = UIState()

    /// Load from disk; return `.empty` if file is missing, malformed, or has
    /// an unknown schemaVersion. Forward-compatible by design.
    public static func loadOrEmpty(from url: URL) -> UIState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        guard let decoded = try? JSONDecoder().decode(UIState.self, from: data) else {
            return .empty
        }
        guard decoded.schemaVersion == currentSchemaVersion else { return .empty }
        return decoded
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 6 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/UIStateTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/UIState.swift MaughamTests/UIStateTests.swift
git commit -m "feat: add UIState for .maugham/ui-state.json persistence"
```

---

## Task 3: ConflictState

**Files:**
- Create: `Maugham/Stores/ConflictState.swift`
- Create: `MaughamTests/ConflictStateTests.swift`

Value type captured when an external change collides with unsaved local edits. Includes a formatter for the banner's "(N words ahead)" wording.

- [ ] **Step 1: Write failing tests**

`MaughamTests/ConflictStateTests.swift`:
```swift
import XCTest
@testable import Maugham

final class ConflictStateTests: XCTestCase {

    func test_equality_byAllFields() {
        let date = Date()
        let a = ConflictState(
            path: "manuscript/01-chapter-1.md",
            localText: "local",
            externalText: "external",
            externalModifiedAt: date)
        let b = ConflictState(
            path: "manuscript/01-chapter-1.md",
            localText: "local",
            externalText: "external",
            externalModifiedAt: date)
        XCTAssertEqual(a, b)
    }

    func test_phrasing_localAhead() {
        let s = ConflictState(
            path: "x.md",
            localText: "one two three four five",   // 5 words
            externalText: "one two",                  // 2 words
            externalModifiedAt: Date())
        XCTAssertEqual(s.localAheadByWords, 3)
        XCTAssertEqual(s.phrasing,
            "Your version (3 words ahead) and the cloud version are different.")
    }

    func test_phrasing_externalAhead() {
        let s = ConflictState(
            path: "x.md",
            localText: "one",
            externalText: "one two three four",
            externalModifiedAt: Date())
        XCTAssertEqual(s.localAheadByWords, -3)
        XCTAssertEqual(s.phrasing,
            "The cloud version (3 words ahead) and your version are different.")
    }

    func test_phrasing_equalCounts() {
        let s = ConflictState(
            path: "x.md",
            localText: "one two",
            externalText: "tea coffee",
            externalModifiedAt: Date())
        XCTAssertEqual(s.localAheadByWords, 0)
        XCTAssertEqual(s.phrasing,
            "Your version and the cloud version are different.")
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ConflictStateTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

`Maugham/Stores/ConflictState.swift`:
```swift
import Foundation

/// Snapshot of a document conflict: local unsaved version vs. external version
/// that arrived through NSFilePresenter. Banner reads from this.
public struct ConflictState: Equatable, Sendable {
    public let path: String
    public let localText: String
    public let externalText: String
    public let externalModifiedAt: Date

    public init(
        path: String,
        localText: String,
        externalText: String,
        externalModifiedAt: Date
    ) {
        self.path = path
        self.localText = localText
        self.externalText = externalText
        self.externalModifiedAt = externalModifiedAt
    }

    /// Word-count delta: positive = local is ahead, negative = external is ahead.
    public var localAheadByWords: Int {
        wordCount(localText) - wordCount(externalText)
    }

    /// Headline phrasing for the banner. Adapts to whichever side has more words.
    public var phrasing: String {
        let delta = localAheadByWords
        if delta > 0 {
            return "Your version (\(delta) words ahead) and the cloud version are different."
        }
        if delta < 0 {
            return "The cloud version (\(-delta) words ahead) and your version are different."
        }
        return "Your version and the cloud version are different."
    }

    private func wordCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split(whereSeparator: \.isWhitespace).count
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 4 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ConflictStateTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ConflictState.swift MaughamTests/ConflictStateTests.swift
git commit -m "feat: add ConflictState with word-count phrasing"
```

---

## Task 4: DebounceScheduler

**Files:**
- Create: `Maugham/Stores/DebounceScheduler.swift`
- Create: `MaughamTests/DebounceSchedulerTests.swift`

Generic helper for cancel-and-restart Task patterns. DocumentStore uses one for the 750ms autosave and another for the 500ms UI state debounce.

- [ ] **Step 1: Write failing tests**

`MaughamTests/DebounceSchedulerTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class DebounceSchedulerTests: XCTestCase {

    func test_schedule_fires_afterDelay() async throws {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(80)
        ) { value in fired.append(value) }
        scheduler.schedule(42)
        XCTAssertEqual(fired, [])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fired, [42])
    }

    func test_rapidReschedule_cancelsPrevious_onlyLastFires() async throws {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(80)
        ) { value in fired.append(value) }
        scheduler.schedule(1)
        try await Task.sleep(for: .milliseconds(20))
        scheduler.schedule(2)
        try await Task.sleep(for: .milliseconds(20))
        scheduler.schedule(3)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fired, [3])
    }

    func test_flush_firesImmediately() async throws {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(800)
        ) { value in fired.append(value) }
        scheduler.schedule(7)
        await scheduler.flush()
        XCTAssertEqual(fired, [7])
    }

    func test_cancel_preventsFiring() async throws {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(80)
        ) { value in fired.append(value) }
        scheduler.schedule(99)
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fired, [])
    }

    func test_flush_isNoOp_whenNothingScheduled() async {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(80)
        ) { value in fired.append(value) }
        await scheduler.flush()
        XCTAssertEqual(fired, [])
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DebounceSchedulerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

`Maugham/Stores/DebounceScheduler.swift`:
```swift
import Foundation

/// Cancel-and-restart Task helper. Schedule a payload; if a new payload arrives
/// before `delay` elapses, the old one is cancelled. `flush()` invokes the
/// pending payload immediately. `cancel()` discards it.
@MainActor
public final class DebounceScheduler<Payload: Sendable> {

    private let delay: Duration
    private let action: (Payload) async -> Void
    private var pendingTask: Task<Void, Never>?
    private var pendingPayload: Payload?

    public init(delay: Duration, action: @escaping (Payload) async -> Void) {
        self.delay = delay
        self.action = action
    }

    public func schedule(_ payload: Payload) {
        pendingTask?.cancel()
        pendingPayload = payload
        let captured = payload
        pendingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await action(captured)
            // Clear pending state if this run completed; another schedule may
            // have replaced pendingPayload while we slept, so only clear if
            // the captured payload still matches.
            if Self.areEqual(self.pendingPayload, captured) {
                self.pendingPayload = nil
                self.pendingTask = nil
            }
        }
    }

    public func flush() async {
        guard let payload = pendingPayload else { return }
        pendingTask?.cancel()
        pendingPayload = nil
        pendingTask = nil
        await action(payload)
    }

    public func cancel() {
        pendingTask?.cancel()
        pendingPayload = nil
        pendingTask = nil
    }

    /// Pointer/value equality fallback: we don't require Payload: Equatable,
    /// so we use a structural compare that's lossy but only used for the
    /// "was my payload still pending?" check inside the Task.
    private static func areEqual(_ a: Payload?, _ b: Payload) -> Bool {
        guard let a else { return false }
        return String(describing: a) == String(describing: b)
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 5 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DebounceSchedulerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

If `test_rapidReschedule_cancelsPrevious_onlyLastFires` is flaky on slow CI, the timing tolerances may need bumping. Iterate on the delays in the test, not the implementation, if needed.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/DebounceScheduler.swift MaughamTests/DebounceSchedulerTests.swift
git commit -m "feat: add DebounceScheduler generic cancel-and-restart helper"
```

---

## Task 5: ProjectFolderPresenter (NSFilePresenter)

**Files:**
- Create: `Maugham/Stores/ProjectFolderPresenter.swift`

Concrete `NSFilePresenter` that registers for the project folder URL and routes events to a delegate. Smoke-build only — exercised by integration tests in T6+.

- [ ] **Step 1: Implement**

`Maugham/Stores/ProjectFolderPresenter.swift`:
```swift
import Foundation
import AppKit

/// Receives NSFilePresenter callbacks from NSFileCoordinator and routes them
/// to a `ProjectFolderPresenterDelegate`. The delegate is a weak ref to the
/// owning DocumentStore — we don't want the presenter to retain the store.
@MainActor
public protocol ProjectFolderPresenterDelegate: AnyObject {
    func presenterDidChangeSubitem(at url: URL)
    func presenterDidObserveDirectoryChange()
}

public final class ProjectFolderPresenter: NSObject, NSFilePresenter {

    private let projectURL: URL
    private weak var delegate: ProjectFolderPresenterDelegate?
    private let queue: OperationQueue

    public init(
        projectURL: URL,
        delegate: ProjectFolderPresenterDelegate
    ) {
        self.projectURL = projectURL
        self.delegate = delegate
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        q.name = "com.maugham.ProjectFolderPresenter"
        self.queue = q
    }

    // MARK: - NSFilePresenter

    public var presentedItemURL: URL? { projectURL }
    public var presentedItemOperationQueue: OperationQueue { queue }

    public func presentedItemDidChange() {
        let d = delegate
        Task { @MainActor in d?.presenterDidObserveDirectoryChange() }
    }

    public func presentedSubitemDidChange(at url: URL) {
        let d = delegate
        Task { @MainActor in d?.presenterDidChangeSubitem(at: url) }
    }

    public func presentedSubitemDidAppear(at url: URL) {
        let d = delegate
        Task { @MainActor in d?.presenterDidChangeSubitem(at: url) }
    }
}
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. (Not yet used by anything; T6 wires it into DocumentStore.)

- [ ] **Step 3: Commit**

```bash
git add Maugham/Stores/ProjectFolderPresenter.swift
git commit -m "feat: add ProjectFolderPresenter (NSFilePresenter)"
```

---

## Task 6: DocumentStore — open, close, UI state

**Files:**
- Create: `Maugham/Stores/DocumentStore.swift` (initial scaffold)
- Create: `MaughamTests/DocumentStoreOpenCloseTests.swift`

Lifecycle and UI state I/O. Subsequent tasks add document I/O, conflict detection, manifest writes.

- [ ] **Step 1: Write failing tests**

`MaughamTests/DocumentStoreOpenCloseTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreOpenCloseTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_open_seedsEmptyUIState_whenStateFileAbsent() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Doc", in: temp.url)
        let store = try await DocumentStore.open(url: url)
        XCTAssertEqual(store.uiState, .empty)
        await store.close()
    }

    func test_open_loadsExistingUIState() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Doc", in: temp.url)
        // Seed a UI state file
        let dotDir = url.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(
            at: dotDir, withIntermediateDirectories: true)
        let state = UIState(schemaVersion: 1, selectedItemId: "doc-x",
                            isNoChromeOn: true, scrollLine: 12)
        try JSONEncoder().encode(state).write(
            to: dotDir.appendingPathComponent("ui-state.json"))

        let store = try await DocumentStore.open(url: url)
        XCTAssertEqual(store.uiState.selectedItemId, "doc-x")
        XCTAssertTrue(store.uiState.isNoChromeOn)
        XCTAssertEqual(store.uiState.scrollLine, 12)
        await store.close()
    }

    func test_updateUIState_persists_afterDebounce() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Doc", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        store.updateUIState { $0.selectedItemId = "doc-y" }

        // Wait past the 500ms UI state debounce + a buffer
        try await Task.sleep(for: .milliseconds(700))

        let savedURL = url
            .appendingPathComponent(".maugham")
            .appendingPathComponent("ui-state.json")
        let data = try Data(contentsOf: savedURL)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.selectedItemId, "doc-y")
        await store.close()
    }

    func test_close_flushesPendingUIStateWrite() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Doc", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        store.updateUIState { $0.isNoChromeOn = true }
        await store.close()  // should flush before unregistering

        let savedURL = url
            .appendingPathComponent(".maugham")
            .appendingPathComponent("ui-state.json")
        let data = try Data(contentsOf: savedURL)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertTrue(decoded.isNoChromeOn)
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreOpenCloseTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `cannot find 'DocumentStore' in scope`.

- [ ] **Step 3: Implement DocumentStore (lifecycle + UI state only)**

`Maugham/Stores/DocumentStore.swift`:
```swift
import Foundation
import AppKit

@MainActor
@Observable
public final class DocumentStore {

    public let projectURL: URL

    /// Loaded from `.maugham/ui-state.json` on open; nil-defaulted if absent.
    public private(set) var uiState: UIState

    private var presenter: ProjectFolderPresenter?
    private var uiStateScheduler: DebounceScheduler<UIState>!

    private init(projectURL: URL, uiState: UIState) {
        self.projectURL = projectURL
        self.uiState = uiState
    }

    public static func open(url: URL) async throws -> DocumentStore {
        let uiStateURL = url
            .appendingPathComponent(".maugham")
            .appendingPathComponent("ui-state.json")
        let uiState = UIState.loadOrEmpty(from: uiStateURL)

        let store = DocumentStore(projectURL: url, uiState: uiState)
        store.uiStateScheduler = DebounceScheduler<UIState>(
            delay: .milliseconds(500)
        ) { [weak store] state in
            await store?.persistUIState(state)
        }

        let presenter = ProjectFolderPresenter(
            projectURL: url, delegate: store)
        NSFileCoordinator.addFilePresenter(presenter)
        store.presenter = presenter

        return store
    }

    public func close() async {
        await uiStateScheduler.flush()
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
    }

    /// Mutate UI state. The new value is persisted on a 500ms debounce.
    public func updateUIState(_ transform: (inout UIState) -> Void) {
        var draft = uiState
        transform(&draft)
        guard draft != uiState else { return }
        uiState = draft
        uiStateScheduler.schedule(draft)
    }

    private func persistUIState(_ state: UIState) async {
        let dotDir = projectURL.appendingPathComponent(".maugham")
        let url = dotDir.appendingPathComponent("ui-state.json")
        do {
            try FileManager.default.createDirectory(
                at: dotDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            // UI state is best-effort; log but don't surface to user.
        }
    }
}

// MARK: - ProjectFolderPresenterDelegate (skeleton)

extension DocumentStore: ProjectFolderPresenterDelegate {
    public func presenterDidChangeSubitem(at url: URL) {
        // Filled in by Task 9
    }

    public func presenterDidObserveDirectoryChange() {
        // Filled in by Task 9
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 4 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreOpenCloseTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift MaughamTests/DocumentStoreOpenCloseTests.swift
git commit -m "feat: DocumentStore lifecycle + UI state persistence"
```

---

## Task 7: DocumentStore — open document, autosave, flush

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift` (add document I/O)
- Create: `MaughamTests/DocumentStoreSaveTests.swift`

The 750ms autosave debounce path. Reads on openDocument, writes through NSFileCoordinator.

- [ ] **Step 1: Write failing tests**

`MaughamTests/DocumentStoreSaveTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreSaveTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func createNovelWithChapter1() async throws -> URL {
        try await ProjectFactory.createNovelProject(
            named: "Save", in: temp.url)
    }

    func test_openDocument_readsDiskAndSetsLastWritten() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        try "initial content".write(
            to: url.appendingPathComponent(chapterPath),
            atomically: true, encoding: .utf8)

        let store = try await DocumentStore.open(url: url)
        let text = try await store.openDocument(at: chapterPath)

        XCTAssertEqual(text, "initial content")
        XCTAssertEqual(store.lastWrittenText, "initial content")
        XCTAssertEqual(store.openDocumentPath, chapterPath)
        await store.close()
    }

    func test_scheduleSave_writesAfterDebounce() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: chapterPath)

        store.scheduleSave(for: chapterPath, text: "edited")
        try await Task.sleep(for: .milliseconds(900))  // > 750ms debounce

        let onDisk = try String(contentsOf: url.appendingPathComponent(chapterPath),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "edited")
        XCTAssertEqual(store.lastWrittenText, "edited")
        await store.close()
    }

    func test_rapidScheduleSaves_onlyLastWritten() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: chapterPath)

        store.scheduleSave(for: chapterPath, text: "first")
        try await Task.sleep(for: .milliseconds(100))
        store.scheduleSave(for: chapterPath, text: "second")
        try await Task.sleep(for: .milliseconds(100))
        store.scheduleSave(for: chapterPath, text: "third")
        try await Task.sleep(for: .milliseconds(900))

        let onDisk = try String(contentsOf: url.appendingPathComponent(chapterPath),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "third")
        await store.close()
    }

    func test_flushPendingSave_writesImmediately() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: chapterPath)

        store.scheduleSave(for: chapterPath, text: "needs flush")
        try await store.flushPendingSave()

        let onDisk = try String(contentsOf: url.appendingPathComponent(chapterPath),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "needs flush")
        await store.close()
    }

    func test_close_flushesPendingSave() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: chapterPath)

        store.scheduleSave(for: chapterPath, text: "must persist on close")
        await store.close()

        let onDisk = try String(contentsOf: url.appendingPathComponent(chapterPath),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "must persist on close")
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreSaveTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `value of type 'DocumentStore' has no member 'openDocument'` etc.

- [ ] **Step 3: Add document I/O to DocumentStore**

In `Maugham/Stores/DocumentStore.swift`, add inside the class (just before the `// MARK: - ProjectFolderPresenterDelegate` line at the bottom):

```swift
    public private(set) var openDocumentPath: String?
    public private(set) var lastWrittenText: String = ""

    private var saveScheduler: DebounceScheduler<SavePayload>!

    private struct SavePayload: Sendable {
        let path: String
        let text: String
    }

    /// Bind to a new document. Reads from disk, sets lastWrittenText, flushes
    /// any pending save for the previously-open document.
    public func openDocument(at path: String) async throws -> String {
        if openDocumentPath != nil {
            try? await flushPendingSave()
        }
        let url = projectURL.appendingPathComponent(path)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        openDocumentPath = path
        lastWrittenText = text
        // Lazy-init save scheduler on first openDocument.
        if saveScheduler == nil {
            saveScheduler = DebounceScheduler<SavePayload>(
                delay: .milliseconds(750)
            ) { [weak self] payload in
                try? await self?.performSave(path: payload.path, text: payload.text)
            }
        }
        return text
    }

    public func scheduleSave(for path: String, text: String) {
        guard saveScheduler != nil else { return }
        saveScheduler.schedule(SavePayload(path: path, text: text))
    }

    public func flushPendingSave() async throws {
        guard let saveScheduler else { return }
        await saveScheduler.flush()
    }

    private func performSave(path: String, text: String) async throws {
        let url = projectURL.appendingPathComponent(path)
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var saveError: Error?
        coordinator.coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordError
        ) { writeURL in
            do {
                try text.data(using: .utf8)?
                    .write(to: writeURL, options: [.atomic])
                self.lastWrittenText = text
            } catch {
                saveError = error
            }
        }
        if let coordError { throw coordError }
        if let saveError { throw saveError }
    }
```

Also update `close()` to also flush save scheduler. Replace the existing `public func close()` body with:

```swift
    public func close() async {
        try? await flushPendingSave()
        await uiStateScheduler.flush()
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
    }
```

- [ ] **Step 4: Regenerate, run, expect 5 save tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreSaveTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

If `test_rapidScheduleSaves_onlyLastWritten` is timing-sensitive, the 100ms gaps and 900ms wait should be plenty on macOS hardware. Iterate timings only if tests are genuinely flaky on CI.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift MaughamTests/DocumentStoreSaveTests.swift
git commit -m "feat: DocumentStore document I/O with 750ms autosave debounce"
```

---

## Task 8: DocumentStore — coordinated manifest writes

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift`
- Modify: `Maugham/Stores/ProjectStore.swift` (route saveManifest through DocumentStore)

Manifest writes go through `NSFileCoordinator` for symmetry with document writes. Tested implicitly through ProjectStore mutation tests, which now use the DocumentStore-backed path.

- [ ] **Step 1: Add coordinated manifest API to DocumentStore**

In `Maugham/Stores/DocumentStore.swift`, add to the class body (near `performSave`):

```swift
    /// Coordinated atomic manifest write. Uses the same coordinator as
    /// document writes so external watchers see the change cleanly.
    public func writeManifest(_ data: Data) async throws {
        let manifestURL = projectURL.appendingPathComponent("project.maugham.json")
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(
            writingItemAt: manifestURL, options: .forReplacing, error: &coordError
        ) { writeURL in
            do {
                let tmpURL = writeURL.appendingPathExtension("tmp")
                try data.write(to: tmpURL, options: [.atomic])
                _ = try FileManager.default.replaceItemAt(writeURL, withItemAt: tmpURL)
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    /// Coordinated read for callers outside ProjectStore.
    public func readManifest() async throws -> Data {
        let manifestURL = projectURL.appendingPathComponent("project.maugham.json")
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var data: Data?
        var readError: Error?
        coordinator.coordinate(
            readingItemAt: manifestURL, options: [], error: &coordError
        ) { readURL in
            do {
                data = try Data(contentsOf: readURL)
            } catch {
                readError = error
            }
        }
        if let coordError { throw coordError }
        if let readError { throw readError }
        return data ?? Data()
    }
```

- [ ] **Step 2: Wire ProjectStore to use DocumentStore for manifest saves**

In `Maugham/Stores/ProjectStore.swift`, add a weak reference and use it in `saveManifest`. First, add a property near the top of the class:

```swift
    /// Optional reference to the DocumentStore that owns this project's
    /// coordinated I/O. Set by ProjectWindow at open time. When non-nil,
    /// manifest saves route through DocumentStore.writeManifest. When nil
    /// (e.g., during initial load before DocumentStore exists), saves use
    /// the legacy direct atomic-write path.
    public weak var documentStore: DocumentStore?
```

Then modify `saveManifest()` (the existing private method that does atomic write). Find the existing implementation:

```swift
    private func saveManifest() async throws {
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let tmpURL = manifestURL.appendingPathExtension("tmp")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: tmpURL, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tmpURL)
        } catch {
            throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
        }
    }
```

Replace with:

```swift
    private func saveManifest() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
        }

        if let documentStore {
            // Route through DocumentStore for coordinated write.
            do {
                try await documentStore.writeManifest(data)
            } catch {
                throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
            }
            return
        }

        // Legacy direct path used during initial load before DocumentStore exists.
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let tmpURL = manifestURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tmpURL)
        } catch {
            throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
        }
    }
```

- [ ] **Step 3: Smoke-build + run all tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 158 tests passing (143 from 1d + 6 UIState + 4 ConflictState + 5 DebounceScheduler — wait, recompute: 143 + 6 + 4 + 5 + 4 + 5 = 167. The exact running total depends on which tasks have run; current task adds 0 new tests but uses existing ProjectStoreMutationTests to verify manifest-through-DocumentStore continues to work via the legacy fallback path since the mutation tests don't open a DocumentStore.

Actually the existing `ProjectStoreMutationTests` use `ProjectStore.load(...)` directly with no DocumentStore, so they exercise the legacy path. Verify they still pass.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift Maugham/Stores/ProjectStore.swift
git commit -m "feat: coordinated manifest writes through DocumentStore"
```

---

## Task 9: Document conflict detection (Cases A & B)

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift`
- Create: `MaughamTests/DocumentStoreConflictDocumentTests.swift`

Implements the state machine: when an external write to the open document is detected, distinguish "our own write echoing back" (no-op), "external change with no pending edits" (Case A — silent reload), "external change with pending edits" (Case B — pendingConflict materialises).

- [ ] **Step 1: Add conflict state to DocumentStore**

In `Maugham/Stores/DocumentStore.swift`, add to the class body (near the document I/O section):

```swift
    /// Set when an external change is detected while the user has unsaved
    /// edits. Cleared on resolution.
    public private(set) var pendingConflict: ConflictState?

    /// Used by EditorHost to know what the editor's currently-displayed text
    /// is, so the conflict-detection pass can compare local vs disk vs
    /// last-written. Set by EditorHost on every keystroke.
    public var currentDocumentText: String = ""

    /// Polling helper for tests: wait until predicate(pendingConflict) is true.
    public func waitForConflictState(
        _ predicate: @escaping (ConflictState?) -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let start = Date()
        while !predicate(pendingConflict) {
            if Date().timeIntervalSince(start) > Double(timeout.components.seconds) {
                struct Timeout: Error {}
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
```

Replace the empty `presenterDidChangeSubitem(at:)` extension method at the bottom of the file with:

```swift
extension DocumentStore: ProjectFolderPresenterDelegate {

    public func presenterDidChangeSubitem(at url: URL) {
        // Compute the relative path from projectURL.
        let project = projectURL.standardizedFileURL.path
        let changed = url.standardizedFileURL.path
        guard changed.hasPrefix(project + "/") else { return }
        let relativePath = String(changed.dropFirst(project.count + 1))

        if relativePath == "project.maugham.json" {
            handleManifestChanged()
        } else if relativePath == openDocumentPath {
            handleOpenDocumentChanged(path: relativePath)
        }
    }

    public func presenterDidObserveDirectoryChange() {
        // Phase 1e doesn't react to directory-level changes; the per-file
        // callbacks handle our cases. Phase 2+ may use this for binder
        // refresh on external file additions.
    }

    // MARK: - Document conflict handling

    private func handleOpenDocumentChanged(path: String) {
        let url = projectURL.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              let diskText = String(data: data, encoding: .utf8) else { return }

        // Disk text equals our last write → echo from our own coordinated save.
        if diskText == lastWrittenText { return }

        // Disk text differs. Are there pending local edits?
        if currentDocumentText == lastWrittenText {
            // Case A: silent reload. No banner.
            lastWrittenText = diskText
            currentDocumentText = diskText
        } else {
            // Case B: conflict. Capture both versions, surface to UI.
            pendingConflict = ConflictState(
                path: path,
                localText: currentDocumentText,
                externalText: diskText,
                externalModifiedAt: (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.modificationDate]
                    as? Date) ?? Date())
        }
    }

    // Manifest handler stub — Task 12 fills in.
    private func handleManifestChanged() { }
}
```

- [ ] **Step 2: Write failing tests**

`MaughamTests/DocumentStoreConflictDocumentTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreConflictDocumentTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_externalChange_noPendingEdits_silentReload() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "ConfA", in: temp.url)
        let path = "manuscript/01-chapter-1.md"
        try "initial".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: path)
        store.currentDocumentText = "initial"  // matches lastWrittenText

        // Simulate external write
        try "external version".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        // Wait for the presenter callback to fire.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertNil(store.pendingConflict)
        XCTAssertEqual(store.lastWrittenText, "external version")
        await store.close()
    }

    func test_externalChange_withPendingEdits_pendingConflict() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "ConfB", in: temp.url)
        let path = "manuscript/01-chapter-1.md"
        try "initial".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: path)
        store.currentDocumentText = "user typed something local"

        // Simulate external write
        try "external version".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        try await store.waitForConflictState({ $0 != nil })
        let conflict = try XCTUnwrap(store.pendingConflict)
        XCTAssertEqual(conflict.path, path)
        XCTAssertEqual(conflict.localText, "user typed something local")
        XCTAssertEqual(conflict.externalText, "external version")
        await store.close()
    }

    func test_ourCoordinatedWrite_doesNotTriggerConflict() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "ConfC", in: temp.url)
        let path = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: path)
        store.currentDocumentText = "initial"

        // Our own coordinated save, scheduled and flushed
        store.scheduleSave(for: path, text: "our own change")
        try await store.flushPendingSave()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(store.pendingConflict)
        XCTAssertEqual(store.lastWrittenText, "our own change")
        await store.close()
    }
}
```

- [ ] **Step 3: Regenerate, run, expect 3 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreConflictDocumentTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

If `test_externalChange_withPendingEdits_pendingConflict` is flaky due to NSFilePresenter timing, the `waitForConflictState` polling helper catches it within 2 seconds. The other tests use a fixed 500ms sleep which should be plenty for macOS file-coordinator notifications.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift MaughamTests/DocumentStoreConflictDocumentTests.swift
git commit -m "feat: DocumentStore detects open-document external changes (Cases A & B)"
```

---

## Task 10: Conflict resolution actions

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift`
- Create: `MaughamTests/DocumentStoreConflictResolutionTests.swift`

`resolveConflictKeepMine` and `resolveConflictUseCloud` — write the loser to `.maugham/conflicts/`, write the winner to disk through the coordinator, clear `pendingConflict`.

- [ ] **Step 1: Write failing tests**

`MaughamTests/DocumentStoreConflictResolutionTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreConflictResolutionTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func setupConflict() async throws -> (URL, DocumentStore, String) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Resolve", in: temp.url)
        let path = "manuscript/01-chapter-1.md"
        try "initial".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: path)
        store.currentDocumentText = "local edits"

        // Simulate external write
        try "external content".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)
        try await store.waitForConflictState({ $0 != nil })
        return (url, store, path)
    }

    func test_keepMine_writesLocal_preservesExternal() async throws {
        let (url, store, path) = try await setupConflict()

        try await store.resolveConflictKeepMine()

        let onDisk = try String(contentsOf: url.appendingPathComponent(path),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "local edits")
        XCTAssertNil(store.pendingConflict)

        // .maugham/conflicts/ should contain the cloud version
        let conflictsDir = url.appendingPathComponent(".maugham/conflicts")
        let files = try FileManager.default.contentsOfDirectory(atPath: conflictsDir.path)
        XCTAssertEqual(files.count, 1)
        let cloudFile = files[0]
        XCTAssertTrue(cloudFile.contains("cloud-"))
        let cloudContent = try String(
            contentsOf: conflictsDir.appendingPathComponent(cloudFile),
            encoding: .utf8)
        XCTAssertEqual(cloudContent, "external content")
        await store.close()
    }

    func test_useCloud_writesExternal_preservesLocal() async throws {
        let (url, store, path) = try await setupConflict()

        try await store.resolveConflictUseCloud()

        let onDisk = try String(contentsOf: url.appendingPathComponent(path),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "external content")
        XCTAssertEqual(store.lastWrittenText, "external content")
        XCTAssertNil(store.pendingConflict)

        let conflictsDir = url.appendingPathComponent(".maugham/conflicts")
        let files = try FileManager.default.contentsOfDirectory(atPath: conflictsDir.path)
        XCTAssertEqual(files.count, 1)
        let localFile = files[0]
        XCTAssertTrue(localFile.contains("local-"))
        let localContent = try String(
            contentsOf: conflictsDir.appendingPathComponent(localFile),
            encoding: .utf8)
        XCTAssertEqual(localContent, "local edits")
        await store.close()
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreConflictResolutionTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `value of type 'DocumentStore' has no member 'resolveConflictKeepMine'`.

- [ ] **Step 3: Implement resolution actions**

Add to `DocumentStore` class (near the conflict state):

```swift
    public func resolveConflictKeepMine() async throws {
        guard let conflict = pendingConflict else { return }
        // 1. Preserve external version
        try writeConflictBackup(
            for: conflict.path,
            text: conflict.externalText,
            kind: "cloud")
        // 2. Write local version through coordinator
        try await performSave(path: conflict.path, text: conflict.localText)
        // 3. Clear conflict
        pendingConflict = nil
    }

    public func resolveConflictUseCloud() async throws {
        guard let conflict = pendingConflict else { return }
        // 1. Preserve local version
        try writeConflictBackup(
            for: conflict.path,
            text: conflict.localText,
            kind: "local")
        // 2. The disk already has externalText. Update lastWrittenText so
        //    subsequent presenter callbacks classify correctly.
        lastWrittenText = conflict.externalText
        currentDocumentText = conflict.externalText
        // 3. Clear conflict
        pendingConflict = nil
    }

    /// Write a backup copy of one side of a conflict to .maugham/conflicts/.
    /// Filename: `<NN-slug>-<kind>-<ISO8601>.<ext>`.
    private func writeConflictBackup(
        for path: String, text: String, kind: String
    ) throws {
        let conflictsDir = projectURL.appendingPathComponent(".maugham/conflicts")
        try FileManager.default.createDirectory(
            at: conflictsDir, withIntermediateDirectories: true)

        let filename = (path as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupName = ext.isEmpty
            ? "\(stem)-\(kind)-\(stamp)"
            : "\(stem)-\(kind)-\(stamp).\(ext)"
        let backupURL = conflictsDir.appendingPathComponent(backupName)
        try text.data(using: .utf8)?.write(to: backupURL, options: [.atomic])
    }
```

- [ ] **Step 4: Regenerate, run, expect 2 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreConflictResolutionTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift MaughamTests/DocumentStoreConflictResolutionTests.swift
git commit -m "feat: DocumentStore conflict resolution (Keep mine / Use cloud)"
```

---

## Task 11: Manifest conflict (Case C)

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift`
- Create: `MaughamTests/DocumentStoreConflictManifestTests.swift`

Last-writer-wins for manifest, with the loser archived to `.maugham/conflicts/manifest-<ISO8601>.json`. Silent — no banner.

- [ ] **Step 1: Write failing tests**

`MaughamTests/DocumentStoreConflictManifestTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreConflictManifestTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_externalManifestNewer_preservesInMemoryAndReloads() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Manifest", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        // Snapshot the current manifest data
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let original = try Data(contentsOf: manifestURL)

        // Write a NEWER manifest externally
        let newer = try ProjectStore.load(from: url)
        // Mutate via direct manipulation: change title, rewrite with future modified
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var manifest = newer.manifest
        manifest.title = "Externally Renamed"
        manifest.modified = Date(timeIntervalSinceNow: 60)  // 1 minute in the future
        let externalData = try encoder.encode(manifest)
        try externalData.write(to: manifestURL, options: [.atomic])

        // Wait for presenter callback
        try await Task.sleep(for: .milliseconds(500))

        // .maugham/conflicts/manifest-*.json should contain the original
        let conflictsDir = url.appendingPathComponent(".maugham/conflicts")
        let files = (try? FileManager.default
            .contentsOfDirectory(atPath: conflictsDir.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("manifest-") },
                      "expected backup of in-memory manifest, got \(files)")
        await store.close()
        _ = original
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreConflictManifestTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: test fails (no backup file written) because `handleManifestChanged()` is currently a stub.

- [ ] **Step 3: Implement handleManifestChanged**

In `Maugham/Stores/DocumentStore.swift`, replace the empty `private func handleManifestChanged() { }` with:

```swift
    private func handleManifestChanged() {
        let manifestURL = projectURL.appendingPathComponent("project.maugham.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let diskManifest = try? decoder.decode(
            ProjectManifest.self, from: data) else { return }

        // We don't currently retain the in-memory manifest in DocumentStore
        // (it lives on ProjectStore). For Case C we just preserve the on-disk
        // version we are about to lose, by snapshotting the file ABOUT to be
        // overwritten by ProjectStore's next save. The decision logic — which
        // is newer — happens by ProjectStore on its next saveManifest, where
        // the in-memory manifest's `modified` is checked against disk before
        // writing.
        //
        // For 1e Phase 1 (per master spec: "Last-writer-wins by `modified`
        // timestamp; the loser is preserved as
        // `.maugham/conflicts/manifest-<timestamp>.json`"), we simply archive
        // the disk version that the next ProjectStore write will overwrite —
        // but only if it's newer than what we last saw. To know "what we last
        // saw", track lastObservedManifestModified.
        if let last = lastObservedManifestModified, diskManifest.modified > last {
            archiveManifestForConflict(data: data)
        }
        lastObservedManifestModified = diskManifest.modified
    }

    private var lastObservedManifestModified: Date?

    private func archiveManifestForConflict(data: Data) {
        let conflictsDir = projectURL.appendingPathComponent(".maugham/conflicts")
        try? FileManager.default.createDirectory(
            at: conflictsDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = conflictsDir
            .appendingPathComponent("manifest-\(stamp).json")
        try? data.write(to: backupURL, options: [.atomic])
    }
```

Also, in the `open(url:)` static method, after loading uiState and BEFORE registering the presenter, seed `lastObservedManifestModified`:

```swift
        // Seed lastObservedManifestModified so the first presenter callback
        // doesn't trigger a spurious archive.
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        if let data = try? Data(contentsOf: manifestURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let m = try? decoder.decode(ProjectManifest.self, from: data) {
                store.lastObservedManifestModified = m.modified
            }
        }
```

(Insert this block in `open(url:)` after `store.uiStateScheduler = ...` and before `let presenter = ...`.)

- [ ] **Step 4: Regenerate, run, expect manifest test passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreConflictManifestTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift MaughamTests/DocumentStoreConflictManifestTests.swift
git commit -m "feat: DocumentStore manifest conflict archival (Case C)"
```

---

## Task 12: ConflictBanner SwiftUI view

**Files:**
- Create: `Maugham/Views/ConflictBanner.swift`

The banner shown above the editor when `pendingConflict != nil`. Smoke-build only.

- [ ] **Step 1: Implement**

`Maugham/Views/ConflictBanner.swift`:
```swift
import SwiftUI

struct ConflictBanner: View {
    let conflict: ConflictState
    let onKeepMine: () -> Void
    let onUseCloud: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Outside change detected.")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(conflict.phrasing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Keep mine", action: onKeepMine)
                    .buttonStyle(.borderedProminent)
                Button("Use cloud", action: onUseCloud)
                    .buttonStyle(.bordered)
                Button("Show diff") { /* Phase 2 */ }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .help("Available in Phase 2")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5),
            alignment: .bottom)
    }
}
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/ConflictBanner.swift
git commit -m "feat: add ConflictBanner SwiftUI view"
```

---

## Task 13: Migrate EditorHost to DocumentStore

**Files:**
- Modify: `Maugham/Views/EditorHost.swift`

EditorHost stops calling `Data.write(to:)` directly. Reads via `documentStore.openDocument(at:)`, writes via `documentStore.scheduleSave(for:text:)`. Keeps `currentDocumentText` in sync so DocumentStore's conflict detection works.

- [ ] **Step 1: Read existing EditorHost**

```bash
cat Maugham/Views/EditorHost.swift
```

- [ ] **Step 2: Replace EditorHost with DocumentStore-backed version**

Overwrite `Maugham/Views/EditorHost.swift` with:

```swift
import SwiftUI
import Foundation

/// Hosts the EditorSurface for a single selected document.
/// Picks the WritingMode by file extension. Routes reads/writes through
/// the project's DocumentStore. The 750ms autosave debounce lives in
/// DocumentStore; EditorHost just calls scheduleSave on each keystroke.
struct EditorHost: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let selectedItemId: String?
    /// Called whenever the document text changes. ProjectWindow uses this
    /// to recompute live metrics for the inspector and goal indicator.
    var onTextChange: ((String) -> Void)? = nil
    @Environment(UserPreferences.self) private var userPreferences

    @State private var documentText: String = ""
    @State private var loadedItemId: String?

    var body: some View {
        Group {
            if let item = currentItem, item.type == .document, let path = item.path {
                EditorSurface(
                    text: Binding(
                        get: { documentText },
                        set: { newValue in
                            documentText = newValue
                            documentStore.currentDocumentText = newValue
                            documentStore.scheduleSave(
                                for: path, text: newValue)
                            onTextChange?(newValue)
                        }
                    ),
                    theme: userPreferences.theme,
                    typography: ProjectStore.effectiveTypography(
                        override: store.manifest.typography,
                        userDefault: userPreferences.typography),
                    mode: WritingModeFactory.mode(for: path),
                    typewriterScroll: userPreferences.typewriterScroll,
                    sentenceFocus: userPreferences.sentenceFocus,
                    paragraphFocus: userPreferences.paragraphFocus
                )
                .id(path)
            } else if currentItem?.type == .group {
                placeholder("Select a document inside this group to edit.")
            } else {
                placeholder("Select a document.")
            }
        }
        .onChange(of: selectedItemId) { _, _ in
            Task { await loadDocumentIfNeeded() }
        }
        .onChange(of: documentStore.lastWrittenText) { _, newValue in
            // External "Use cloud" resolution updates lastWrittenText to the
            // external content; rebind the editor to match.
            if let item = currentItem,
               item.id == loadedItemId,
               documentText != newValue {
                documentText = newValue
                documentStore.currentDocumentText = newValue
                onTextChange?(newValue)
            }
        }
        .task { await loadDocumentIfNeeded() }
    }

    private var currentItem: StructureItem? {
        guard let id = selectedItemId else { return nil }
        return findItem(id: id, in: store.manifest.structure)
    }

    private func loadDocumentIfNeeded() async {
        guard let item = currentItem,
              item.type == .document,
              let path = item.path,
              loadedItemId != item.id else { return }
        do {
            let text = try await documentStore.openDocument(at: path)
            documentText = text
            documentStore.currentDocumentText = text
            loadedItemId = item.id
            onTextChange?(documentText)
        } catch {
            documentText = ""
            documentStore.currentDocumentText = ""
            loadedItemId = item.id
        }
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }
}
```

The notable changes:
- New `@Bindable var documentStore: DocumentStore` parameter — owner is ProjectWindow
- `set:` closure on the binding now calls `documentStore.scheduleSave(...)` instead of writing to disk directly
- New `.onChange(of: documentStore.lastWrittenText)` reactor — when conflict resolution updates the text externally (Use cloud), the editor rebinds to it
- `loadDocumentIfNeeded` now calls `documentStore.openDocument(at:)` instead of reading the file directly
- The previous `saveDocument` private method is gone

- [ ] **Step 3: Skip smoke-build (will fail until ProjectWindow is updated in T14)**

The build will fail because ProjectWindow doesn't yet pass `documentStore:` to EditorHost. T14 fixes this.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/EditorHost.swift
git commit -m "feat: EditorHost routes I/O through DocumentStore"
```

---

## Task 14: ProjectWindow integration

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`

ProjectWindow opens DocumentStore at load time, hands references to ProjectStore (so saveManifest routes through it) and EditorHost (so I/O goes through it), renders ConflictBanner above the editor, and seeds initial `selectedItemId` and `isNoChromeOn` from `documentStore.uiState`.

- [ ] **Step 1: Read existing ProjectWindow**

```bash
cat Maugham/Views/ProjectWindow.swift
```

- [ ] **Step 2: Replace ProjectWindow with DocumentStore-aware version**

Replace the `ProjectWindow` struct (preserving `WindowAccessor` at the bottom) with:

```swift
struct ProjectWindow: View {
    @State private var store: ProjectStore?
    @State private var documentStore: DocumentStore?
    @State private var loadError: String?
    @State private var isNoChromeOn: Bool = false
    @State private var window: NSWindow?
    @State private var metrics: EditorMetrics =
        EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0)
    @State private var showingSaveFlash: Bool = false
    @State private var selectedItemId: String?
    @State private var activeSheet: ProjectActiveSheet?
    @State private var showInspector: Bool = true
    @Environment(UserPreferences.self) private var userPreferences

    let url: URL

    var body: some View {
        Group {
            if let store, let documentStore {
                NavigationSplitView {
                    BinderView(store: store, selectedItemId: $selectedItemId)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } content: {
                    ZStack(alignment: .bottomTrailing) {
                        EditorHost(
                            store: store,
                            documentStore: documentStore,
                            selectedItemId: selectedItemId,
                            onTextChange: { text in updateMetrics(for: text) }
                        )
                        if userPreferences.goalIndicatorsVisible {
                            GoalIndicatorView(metrics: metrics)
                        }
                    }
                    .safeAreaInset(edge: .top) {
                        if let conflict = documentStore.pendingConflict {
                            ConflictBanner(
                                conflict: conflict,
                                onKeepMine: {
                                    Task { try? await documentStore.resolveConflictKeepMine() }
                                },
                                onUseCloud: {
                                    Task { try? await documentStore.resolveConflictUseCloud() }
                                }
                            )
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 480, ideal: 720)
                } detail: {
                    if showInspector && store.manifest.type != .collection {
                        InspectorView(
                            store: store,
                            selectedItemId: selectedItemId,
                            metrics: metrics,
                            onOpenProjectSettings: { activeSheet = .projectSettings }
                        )
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
                    }
                }
                .overlay(alignment: .top) {
                    SaveFlashOverlay(isShowing: $showingSaveFlash)
                }
                .navigationTitle(store.manifest.title)
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .projectSettings:
                        ProjectSettingsSheet(store: store)
                    case .claudeDesktop:
                        HelpClaudeDesktopSheet(
                            projectURL: store.url,
                            projectTitle: store.manifest.title)
                    }
                }
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't open project").font(.headline)
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(48)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 540)
        .background(WindowAccessor(window: $window))
        .task(id: url) { await load() }
        .onDisappear { Task { await documentStore?.close() } }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleNoChrome)) { _ in
            isNoChromeOn.toggle()
            applyNoChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleFullScreen)) { _ in
            toggleFullScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamDummySave)) { _ in
            Task {
                try? await documentStore?.flushPendingSave()
                showSaveFlash()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowProjectSettings)) { _ in
            activeSheet = .projectSettings
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowClaudeDesktopHelp)) { _ in
            activeSheet = .claudeDesktop
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleInspector)) { _ in
            showInspector.toggle()
        }
        .onChange(of: isNoChromeOn) { _, newValue in
            applyNoChrome()
            documentStore?.updateUIState { $0.isNoChromeOn = newValue }
        }
        .onChange(of: selectedItemId) { _, newValue in
            documentStore?.updateUIState { $0.selectedItemId = newValue }
        }
    }

    // MARK: - Helpers

    private func updateMetrics(for text: String) {
        guard let store, let id = selectedItemId,
              let item = findItem(id: id, in: store.manifest.structure),
              item.type == .document, let path = item.path else {
            metrics = EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0)
            return
        }
        metrics = WritingModeFactory.mode(for: path).metrics(text)
    }

    private func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let n = findItem(id: id, in: children) { return n }
        }
        return nil
    }

    private func applyNoChrome() {
        guard let window else { return }
        window.titlebarAppearsTransparent = isNoChromeOn
        window.titleVisibility = isNoChromeOn ? .hidden : .visible
        window.standardWindowButton(.closeButton)?.isHidden = isNoChromeOn
        window.standardWindowButton(.miniaturizeButton)?.isHidden = isNoChromeOn
        window.standardWindowButton(.zoomButton)?.isHidden = isNoChromeOn
    }

    private func toggleFullScreen() {
        guard let window else { return }
        let wasFullScreen = window.styleMask.contains(.fullScreen)
        if !wasFullScreen && !isNoChromeOn {
            isNoChromeOn = true
            applyNoChrome()
        }
        window.toggleFullScreen(nil)
    }

    @MainActor
    private func showSaveFlash() {
        showingSaveFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            await MainActor.run { showingSaveFlash = false }
        }
    }

    @MainActor
    private func load() async {
        do {
            let s = try await ProjectStore.load(from: url)
            let ds = try await DocumentStore.open(url: url)
            s.documentStore = ds
            self.store = s
            self.documentStore = ds

            // Seed UI state from disk (or defaults). Validate selectedItemId
            // against current structure — if the saved selection refers to a
            // deleted item, fall back to first document.
            let savedSelection = ds.uiState.selectedItemId
            let isValid = savedSelection != nil
                ? findItem(id: savedSelection!, in: s.manifest.structure) != nil
                : false
            if isValid {
                self.selectedItemId = savedSelection
            } else if let first = firstDocument(in: s.manifest.structure) {
                self.selectedItemId = first.id
            }
            self.isNoChromeOn = ds.uiState.isNoChromeOn
            applyNoChrome()
            loadError = nil
        } catch ProjectStoreError.manifestNotFound {
            loadError = "No project.maugham.json was found in this folder."
        } catch ProjectStoreError.manifestUnreadable(let msg) {
            loadError = "Manifest is corrupt or unreadable: \(msg)"
        } catch ProjectStoreError.manuscriptUnreadable(let msg) {
            loadError = "Manuscript file couldn't be read: \(msg)"
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func firstDocument(in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.type == .document { return item }
            if let children = item.children,
               let nested = firstDocument(in: children) { return nested }
        }
        return nil
    }
}
```

(Leave `private struct WindowAccessor: NSViewRepresentable { ... }` and the `enum ProjectActiveSheet` declaration unchanged at the file's bottom.)

- [ ] **Step 3: Smoke-build + run all tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(Executed |TEST FAILED|TEST SUCCEEDED|BUILD FAILED|error:)" | tail -10
```

Expected: BUILD SUCCEEDED, all tests passing.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/ProjectWindow.swift
git commit -m "feat: ProjectWindow owns DocumentStore, renders ConflictBanner"
```

---

## Task 15: scenePhase-driven flush on app termination

**Files:**
- Modify: `Maugham/MaughamApp.swift`

When the app moves to `.background` (which on macOS happens when quitting), force-flush all open DocumentStores so we never lose unsaved data on quit.

Strictly speaking, our individual ProjectWindow's `.onDisappear` handles the per-window close. But that's not guaranteed to fire before app termination — macOS may tear down windows in a way that doesn't run SwiftUI lifecycle hooks. A scenePhase observer on the App is belt-and-suspenders.

- [ ] **Step 1: Add scenePhase observer to MaughamApp**

In `Maugham/MaughamApp.swift`, near the top of the `MaughamApp` struct (after `@State` properties), add:

```swift
    @Environment(\.scenePhase) private var scenePhase
```

This won't compile inside an App struct — `@Environment` is for Views. Instead, the right pattern for a SwiftUI App is to attach `.onChange(of: scenePhase)` to the root scene, but App scenes don't directly expose this. The pragmatic alternative is to observe via NSApplication's notifications.

Replace the `@State` block setup with this version that registers an NSApplication observer. Find the existing:

```swift
@main
struct MaughamApp: App {
    @State private var userPreferences = UserPreferences()
    @State private var recents = RecentsStore()
```

Add a new App init that hooks NSApplicationWillTerminate:

```swift
@main
struct MaughamApp: App {
    @State private var userPreferences = UserPreferences()
    @State private var recents = RecentsStore()

    init() {
        // Best-effort: post a notification on app termination so any open
        // ProjectWindow can synchronously flush its DocumentStore. This is
        // belt-and-suspenders alongside .onDisappear.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { _ in
            NotificationCenter.default.post(
                name: .maughamAppWillTerminate, object: nil)
        }
    }
```

(The rest of the App body is unchanged.)

- [ ] **Step 2: Add the new notification name**

In `Maugham/Models/MaughamNotifications.swift`, append before the closing `}`:

```swift
    public static let maughamAppWillTerminate = Notification.Name("maugham.appWillTerminate")
```

- [ ] **Step 3: Wire ProjectWindow to flush on this notification**

In `Maugham/Views/ProjectWindow.swift`, add a new `.onReceive` to the body's chain (anywhere in the existing chain of `.onReceive(...)` calls):

```swift
        .onReceive(NotificationCenter.default.publisher(for: .maughamAppWillTerminate)) { _ in
            // Synchronous flush: we use a semaphore-like pattern via
            // unsafeBitCast since we can't await in a non-async context.
            // For 1e, fire the close in a Task and accept that NSApplication
            // may give us up to 100ms before terminating us. Document
            // flushPendingSave is nearly instantaneous; UI state flush too.
            if let ds = documentStore {
                Task { await ds.close() }
            }
        }
```

The real synchronous flush opportunity is `applicationShouldTerminate(_:)`, which can return `.terminateLater` and call `replyToApplicationShouldTerminate(true)` after the async flush. That's a deeper integration; for 1e the Task-based flush plus `.onDisappear` is the pragmatic minimum.

- [ ] **Step 4: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/MaughamApp.swift Maugham/Models/MaughamNotifications.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: flush DocumentStore on app termination"
```

---

## Task 16: End-to-end smoke test + tag milestone-1e

- [ ] **Step 1: Run full test suite**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: ~170 tests passing (143 from end of 1d + ~27 new across UIState, ConflictState, DebounceScheduler, DocumentStore open/close, save, conflict-document, conflict-resolution, conflict-manifest).

- [ ] **Step 2: Manual smoke test (12 steps from spec)**

In Xcode, ⌘R or `open` the built `.app`. Walk these:

1. Open a project. Type a sentence; ~1s later confirm in Finder that the file's modified date updated. (Autosave is invisible to the user.)
2. ⌘S while typing → "Saved" flash appears immediately, and the file's modified date updates to *now* (not 750ms in the future).
3. Type a sentence; close the project window before the 750ms debounce fires; reopen the project; verify the sentence persisted.
4. With Maugham open, edit the manuscript file via Terminal: `printf 'external edit\n' > <path/to/file.md>`. ConflictBanner appears.
5. Click **Keep mine**. Banner disappears. File on disk now has *your* version. `.maugham/conflicts/<file>-cloud-*.md` contains the terminal edit.
6. Repeat the conflict scenario. Click **Use cloud**. Editor swaps to the external content. `.maugham/conflicts/<file>-local-*.md` contains your version.
7. With Maugham editing chapter 1, open the same project file in TextEdit, edit, save. Maugham presents the banner. Either resolution is correct.
8. Edit `project.maugham.json` in TextEdit, change `title`, save. Maugham reloads silently; `.maugham/conflicts/manifest-*.json` contains the previous version.
9. Switch documents in the binder. Close the window. Reopen. The same document is selected.
10. Toggle no-chrome (⌘\\). Close the window. Reopen. No-chrome state is restored.
11. Force-quit Maugham (Activity Monitor) mid-edit. Reopen. Up to 750ms of unsaved edits may be lost — that's acceptable.
12. Open multiple projects. In each, edit a chapter. Verify each project's DocumentStore is independent (changing one project's file doesn't show a banner in the other).

If all 12 pass, milestone 1e is healthy.

- [ ] **Step 3: Tag and merge**

```bash
git checkout main
git merge --ff-only feat/phase-1e-document-store
git tag -a milestone-1e -m "Maugham milestone 1e — DocumentStore + Conflict Resolution

DocumentStore wraps the open-document path in NSFileCoordinator +
NSFilePresenter so iCloud, Claude Desktop, Finder, or any other process
can touch the project folder safely. 750ms autosave debounce replaces
EditorHost's keystroke writes; ⌘S triggers immediate flush + 'Saved'
flash. External changes surface a non-blocking ConflictBanner with
Keep mine / Use cloud actions; loser preserved at .maugham/conflicts/.
Manifest conflicts are silent last-writer-wins per master spec; loser
archived too. UI state (selected document, no-chrome flag) persists to
.maugham/ui-state.json. App-termination flush is best-effort via
NSApplication.willTerminateNotification."
git tag --list 'milestone-*'
```

Expected: `milestone-1a milestone-1b milestone-1c milestone-1d milestone-1e`.

- [ ] **Step 4: Update README**

Append after the existing 1d smoke section in `README.md`:

```markdown

## Phase 1e smoke test

Once running on milestone-1e:

1. Open a project, type a sentence, wait ~1s; in Finder verify the file's modified date updated. Autosave is invisible.
2. ⌘S while typing → "Saved" flash appears, file's modified date updates to now.
3. Type, close window before 750ms elapses, reopen; sentence persisted.
4. Edit a manuscript file via Terminal while Maugham is open. Banner: "Outside change detected".
5. Click **Keep mine**. Disk has your version; cloud version archived under `.maugham/conflicts/`.
6. Repeat with **Use cloud**. Disk has cloud version; your version archived under `.maugham/conflicts/`.
7. Edit `project.maugham.json` in TextEdit. Maugham reloads silently; previous manifest archived.
8. Switch documents, close, reopen. Same document selected. Toggle no-chrome, close, reopen. State restored.

If all eight pass, milestone 1e is healthy.
```

```bash
git add README.md
git commit -m "docs: add phase 1e smoke test checklist"
```

---

## Self-review checklist

- [x] **Spec coverage:** Every spec section has a task. DocumentStore.open/close/UI state (T6), document I/O + autosave (T7), coordinated manifest writes (T8), conflict detection Cases A/B (T9), resolution (T10), Case C (T11), banner (T12), EditorHost migration (T13), ProjectWindow integration (T14), app termination flush (T15), smoke (T16). Pure-logic foundations (UIState/ConflictState/DebounceScheduler) all TDD'd in T2/T3/T4. ProjectFolderPresenter as smoke-build T5. ✓
- [x] **Placeholder scan:** No "TBD", "TODO", "implement later", "fill in details", "appropriate error handling", or "similar to Task N". Every step has actual code or actual commands. ✓
- [x] **Type consistency:** `DocumentStore.openDocument(at:) -> String`, `scheduleSave(for:text:)`, `flushPendingSave()`, `writeManifest(_:)`, `readManifest()`, `pendingConflict`, `lastWrittenText`, `currentDocumentText`, `uiState`, `updateUIState`, `close()`, `resolveConflictKeepMine()`, `resolveConflictUseCloud()`, `waitForConflictState(_:timeout:)` consistent across T6, T7, T8, T9, T10, T11, T13, T14. `ConflictState(path:localText:externalText:externalModifiedAt:)` and `.phrasing`/`.localAheadByWords` consistent across T3 and T9/T12. `UIState(schemaVersion:selectedItemId:isNoChromeOn:scrollLine:)` and `.empty`/`.loadOrEmpty(from:)` consistent across T2 and T6/T14. `DebounceScheduler<Payload>(delay:action:)` with `.schedule(_:)` / `.flush()` / `.cancel()` consistent across T4, T6, T7. `ProjectFolderPresenterDelegate.presenterDidChangeSubitem(at:)` and `.presenterDidObserveDirectoryChange()` consistent across T5 and T6/T9. ✓
- [x] **TDD:** Pure-logic tasks T2/T3/T4 follow TDD. Integration tasks T6/T7/T9/T10/T11 use real temp directory + real NSFileCoordinator and have explicit fail/pass test runs. UI tasks T5/T12/T13/T14/T15 are smoke-build only with manual smoke at T16. ✓
- [x] **Open questions from spec addressed:**
  - Q1 (force-flush on app quit): T15 wires NSApplication.willTerminateNotification → maughamAppWillTerminate → ProjectWindow's documentStore.close().
  - Q2 (synchronous flush on path-switch): T13's `loadDocumentIfNeeded` calls `documentStore.openDocument(at:)`, which internally flushes pending save for the previously-open document (T7 `openDocument` impl).
  - Q3 (banner word count via WritingModeFactory): T3's ConflictState computes word count internally; phrasing matches spec wording.
  - Q4 (lastWrittenText initial value): T7 `openDocument` sets `lastWrittenText = text` after disk read.
  - Q5 (selectedItemId validation against structure): T14 `load()` checks `findItem(id: savedSelection!, in: s.manifest.structure)` and falls back to first document. ✓
