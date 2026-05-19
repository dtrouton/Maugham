# Document-First-Class Op Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the operation log a first-class citizen by introducing a `Document` type that owns its op log + pending buffer + burst scheduler + autosave + conflict detection; `EditorHost` binds to `Document` directly; `DocumentStore` becomes a project-folder coordinator with a registry of open Documents.

**Architecture:** Stage 0 ships an editor integration test harness against the *current* API to serve as the conformance contract. Stages 1–5 introduce Document, route EditorHost through it, move presenter dispatch + autosave + conflict detection from DocumentStore into Document, and clean up two adjacent audit findings. Green-test gates between each stage.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit (NSTextView, NSFileCoordinator, NSFilePresenter), XCTest. Pure-Swift ULID/ParagraphID already exist.

**Spec:** [docs/superpowers/specs/2026-05-19-document-first-class-oplog-design.md](../specs/2026-05-19-document-first-class-oplog-design.md)

---

## Branch setup

Before any task, the implementer creates the feature branch:

```bash
git checkout -b feat/milestone-document-first-class
./gen.sh
```

All tasks land on this branch. Final smoke + ff-merge to main + tag on the last task.

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `Maugham/OpLog/Document.swift` | The new core type. Owns op log + pending buffer + burst scheduler + autosave + conflict detection for one manuscript. Exposes `displayText` as the only observed text-state property. |
| `MaughamTests/Editor/EditorIntegrationHarness.swift` | Programmatic NSTextView rig + helpers (typeCharacter, paste, setCursor, waitForAutosave). |
| `MaughamTests/Editor/EditorIntegrationHarnessTests.swift` | 10 tests — the conformance contract for the refactor. |
| `MaughamTests/OpLog/DocumentTests.swift` | Unit tests for Document in isolation. |

### Modified files

| Path | Reason |
|---|---|
| `Maugham/Editor/EditorCoordinator.swift` | Add `internal private(set) var applyExternalTextCallCount` for testability; later: remove `applyFocusDim` redundancy (Stage 5). |
| `Maugham/Stores/DocumentStore.swift` | Expose presenter (private→internal). Stage 2: add registry. Stage 3: remove op-log block + autosave + conflict detection + `openDocument` + `currentDocumentText` + `lastWrittenText`. |
| `Maugham/Views/EditorHost.swift` | Stage 2: full refactor to Document binding. |
| `Maugham/Views/ProjectWindow.swift` | Stage 4: re-route conflict sheet from `documentStore.pendingConflict` to `activeDocument?.pendingConflict` (sites at lines 92 and 679). |
| `Maugham/Editor/RenderFilter.swift` | Stage 5: char-bigram tier moves out into ShingleMatcher. |
| `Maugham/OpLog/ShingleMatcher.swift` | Stage 5: gains a bigram-overlap tier. |

---

## Task Plan

Tasks below are sequenced so each lands on a passing build. Subagent model annotation in `[]`: `H` = haiku (mechanical), `S` = sonnet (substantive), `O` = opus (genuinely tricky, broad codebase context).

---

### Task 1: Editor integration test harness rig [S]

**Files:**
- Create: `MaughamTests/Editor/EditorIntegrationHarness.swift`
- Modify: `Maugham/Editor/EditorCoordinator.swift` (add testability hook)

- [ ] **Step 1: Create the test directory + harness rig**

Create directory `MaughamTests/Editor/` if it doesn't exist. Then write the rig:

```swift
// MaughamTests/Editor/EditorIntegrationHarness.swift
import XCTest
import AppKit
import SwiftUI
@testable import Maugham

/// Drives a real NSTextView wired to a real EditorCoordinator, hosted in
/// an offscreen NSWindow, with a Binding<String> that mirrors what
/// EditorHost passes to EditorSurface. Provides helpers to simulate
/// typing, paste, cursor moves, and external-edit dispatch.
///
/// The harness is the conformance contract for the Document-first-class
/// refactor: tests pass against both the current API and the refactored
/// API. Test 8 (assertNoApplyExternalText during typing) fails today
/// and passes after Stage 2.
@MainActor
final class EditorIntegrationHarness {

    let window: NSWindow
    let scrollView: NSScrollView
    let textView: NSTextView
    let coordinator: EditorCoordinator
    let projectURL: URL
    let docPath: String

    /// Binding's @State backing — the test's view of "documentText".
    private var boundText: String

    init(
        mode: any WritingMode = ProseMode(),
        initialText: String = "",
        cursorLocation: Int? = nil
    ) {
        // Offscreen project directory.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EIH-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let mdURL = tmp.appendingPathComponent("manuscript/test.md")
        try! initialText.data(using: .utf8)?.write(to: mdURL, options: .atomic)

        self.projectURL = tmp
        self.docPath = "manuscript/test.md"
        self.boundText = initialText

        // Offscreen window + text view + scroll view.
        let storage = NSTextStorage(string: initialText)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 600))
        layout.addTextContainer(container)
        let tv = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 600),
            textContainer: container)
        tv.isEditable = true
        tv.isRichText = false
        tv.allowsUndo = true

        let sv = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        sv.documentView = tv
        self.scrollView = sv
        self.textView = tv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = sv
        self.window = win

        // Binding whose setter mirrors what EditorHost does today: store
        // the new value. The Document refactor will change this body but
        // the contract (boundText reflects user input) stays.
        let bindingTextRef = UnsafeMutablePointer<String>.allocate(capacity: 1)
        bindingTextRef.initialize(to: initialText)
        _ = bindingTextRef  // (placeholder; bindings created below)

        let coord = EditorCoordinator(
            text: Binding(
                get: { [weak self] in self?.boundText ?? "" },
                set: { [weak self] newValue in self?.boundText = newValue }),
            mode: mode,
            theme: .light, typography: .proseDefaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        tv.delegate = coord
        coord.attach(to: tv)
        self.coordinator = coord

        if let cursor = cursorLocation {
            tv.setSelectedRange(NSRange(location: cursor, length: 0))
        } else {
            tv.setSelectedRange(NSRange(
                location: (initialText as NSString).length, length: 0))
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Input simulation

    /// Insert a single character at the current selection, mirroring what
    /// AppKit does when the user presses a key. Goes through the full
    /// shouldChangeText → storage.replaceCharacters → didChangeText path
    /// so EditorCoordinator's delegate methods fire normally.
    func typeCharacter(_ c: Character) {
        let s = String(c)
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: s) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: s)
        textView.setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
        textView.didChangeText()
    }

    /// Type each character of the string sequentially. `intervalMs == 0`
    /// fires them back-to-back on the same runloop tick — the rapid-
    /// typing case that exposes binding races.
    func typeString(_ s: String, intervalMs: Int = 0) async {
        for c in s {
            typeCharacter(c)
            if intervalMs > 0 {
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    func setCursor(to location: Int) {
        let clamped = max(0, min(location, (textView.string as NSString).length))
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }

    func paste(_ s: String) {
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: s) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: s)
        textView.setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
        textView.didChangeText()
    }

    // MARK: - State inspection

    var currentText: String { textView.string }
    var cursorLocation: Int { textView.selectedRange().location }

    /// Invariant assertion for Test 8 and similar. Captures the
    /// applyExternalText call counter before `body`, runs body, asserts
    /// counter didn't move. Available via @testable EditorCoordinator.
    func assertNoApplyExternalText(
        file: StaticString = #file, line: UInt = #line,
        during body: () -> Void
    ) {
        let before = coordinator.applyExternalTextCallCount
        body()
        let after = coordinator.applyExternalTextCallCount
        XCTAssertEqual(after, before,
            "applyExternalText fired during user typing (\(after - before) times) — race condition",
            file: file, line: line)
    }
}
```

- [ ] **Step 2: Add the testability counter to EditorCoordinator**

Edit `Maugham/Editor/EditorCoordinator.swift`. In the property declarations near the top of the class, add:

```swift
/// Number of times applyExternalText has been called. Internal so
/// @testable importers (EditorIntegrationHarness) can assert invariants
/// about typing not triggering external-text replacement. Production
/// never reads this.
internal private(set) var applyExternalTextCallCount: Int = 0
```

And at the top of `applyExternalText(_ text: String)`, add one line:

```swift
func applyExternalText(_ text: String) {
    applyExternalTextCallCount += 1
    guard let textView, textView.string != text else { return }
    // ... existing body unchanged
}
```

- [ ] **Step 3: Build, confirm compile**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift \
        MaughamTests/Editor/EditorIntegrationHarness.swift
git commit -m "test: editor integration harness rig + applyExternalText counter"
```

---

### Task 2: Harness tests 1–5 (baseline typing) [S]

**Files:**
- Create: `MaughamTests/Editor/EditorIntegrationHarnessTests.swift`

- [ ] **Step 1: Write the five baseline tests**

```swift
// MaughamTests/Editor/EditorIntegrationHarnessTests.swift
import XCTest
@testable import Maugham

@MainActor
final class EditorIntegrationHarnessTests: XCTestCase {

    func test_singleCharacterTyped_textViewMatchesUserInput() {
        let rig = EditorIntegrationHarness(initialText: "")
        rig.typeCharacter("a")
        XCTAssertEqual(rig.currentText, "a")
        XCTAssertEqual(rig.cursorLocation, 1)
    }

    func test_rapidTyping_preservesCursorAtEnd() async {
        let rig = EditorIntegrationHarness(initialText: "")
        await rig.typeString("The quick brown fox")
        XCTAssertEqual(rig.currentText, "The quick brown fox")
        XCTAssertEqual(rig.cursorLocation, 19,
            "after typing 19 chars at end, cursor must be at 19")
    }

    func test_rapidTyping_inMiddle_preservesInsertionPoint() async {
        let rig = EditorIntegrationHarness(initialText: "Hello world")
        rig.setCursor(to: 5)  // between "Hello" and " world"
        await rig.typeString(", dear")
        XCTAssertEqual(rig.currentText, "Hello, dear world")
        XCTAssertEqual(rig.cursorLocation, 11)  // 5 + 6 typed chars
    }

    func test_trailingSpace_persistsAcrossAutosave() async throws {
        let rig = EditorIntegrationHarness(initialText: "")
        await rig.typeString("hello ")
        // Wait > 750ms for any autosave to complete + onChange to run.
        try await Task.sleep(for: .milliseconds(900))
        await rig.typeString("world")
        // The trailing space we typed should still be present.
        XCTAssertEqual(rig.currentText, "hello world",
            "trailing space typed before autosave must persist")
    }

    func test_pasteMultiCharString_preservesCursorAtPasteEnd() {
        let rig = EditorIntegrationHarness(initialText: "")
        rig.paste("foo bar")
        XCTAssertEqual(rig.currentText, "foo bar")
        XCTAssertEqual(rig.cursorLocation, 7)
    }
}
```

- [ ] **Step 2: Run the tests**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/EditorIntegrationHarnessTests test 2>&1 | tail -15
```
Expected: 5 tests, **0 failures** (the recent fixes should hold).

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/Editor/EditorIntegrationHarnessTests.swift
git commit -m "test: harness tests 1-5 (baseline typing invariants)"
```

---

### Task 3: Harness tests 6–7 (external edit dispatch) [S]

**Files:**
- Modify: `MaughamTests/Editor/EditorIntegrationHarnessTests.swift`
- Modify: `MaughamTests/Editor/EditorIntegrationHarness.swift` (add a writeExternalMdContent helper)

- [ ] **Step 1: Add the helper to the harness**

In `MaughamTests/Editor/EditorIntegrationHarness.swift`, add inside the class:

```swift
/// Simulate an external tool writing new bytes to the manuscript file
/// on disk. The harness needs a DocumentStore to drive presenter
/// callbacks for these tests. Current implementation: load a real
/// DocumentStore so the presenter fires.
func attachDocumentStore() async throws -> DocumentStore {
    // Manifest must exist for DocumentStore.open to work.
    let manifest = ProjectManifest(
        type: .novel, title: "T", author: "A",
        created: Date(), modified: Date(),
        structure: [
            StructureItem(
                id: "doc-test", type: .document, title: "Test",
                path: docPath)
        ],
        research: [])
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    try enc.encode(manifest).write(
        to: projectURL.appendingPathComponent("project.maugham.json"))
    return try await DocumentStore.open(url: projectURL)
}

func writeExternalMdContent(_ content: String) async throws {
    let mdURL = projectURL.appendingPathComponent(docPath)
    try content.data(using: .utf8)!.write(to: mdURL, options: .atomic)
    // Give the presenter callback a tick to fire.
    try await Task.sleep(for: .milliseconds(100))
}
```

- [ ] **Step 2: Add tests 6 and 7**

Append to `EditorIntegrationHarnessTests.swift`:

```swift
func test_externalEditWithIdsIntact_ingestsSilently() async throws {
    let rig = EditorIntegrationHarness(
        initialText: "<!-- ¶a3f9 -->\n\nHello.\n")
    _ = try await rig.attachDocumentStore()

    // Externally rewrite the .md, keeping the ¶id intact but changing
    // the paragraph body. Reconciler.classify should return
    // .silentIngest; the editor view should reflect the change without
    // a conflict sheet surfacing.
    try await rig.writeExternalMdContent(
        "<!-- ¶a3f9 -->\n\nHello, edited.\n")
    try await Task.sleep(for: .milliseconds(300))

    // Today this path may not be fully wired end-to-end (audit finding
    // #3). After Stage 3 it will be. For now we document the expected
    // post-refactor behaviour:
    // XCTAssertTrue(rig.currentText.contains("edited"))
    // The test is `XCTSkip`'d today; Stage 3 will un-skip.
    throw XCTSkip("Reconciler end-to-end path is wired in Stage 3")
}

func test_externalEditWithIdsStripped_surfacesConflict() async throws {
    let rig = EditorIntegrationHarness(
        initialText: "<!-- ¶a3f9 -->\n\nHello.\n")
    _ = try await rig.attachDocumentStore()

    // External tool stripped the ¶id comment. Reconciler should
    // classify as .needsSheet, surfacing pendingConflict.
    try await rig.writeExternalMdContent("Hello, edited (no IDs).\n")
    try await Task.sleep(for: .milliseconds(300))

    // Same situation — Stage 3 will un-skip.
    throw XCTSkip("Reconciler end-to-end path is wired in Stage 3")
}
```

- [ ] **Step 3: Run the tests**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/EditorIntegrationHarnessTests test 2>&1 | tail -15
```
Expected: 7 tests; 5 pass, 2 skipped. (The skipped tests stay as placeholders for Stage 3 to un-skip.)

- [ ] **Step 4: Commit**

```bash
git add MaughamTests/Editor/EditorIntegrationHarness.swift \
        MaughamTests/Editor/EditorIntegrationHarnessTests.swift
git commit -m "test: harness tests 6-7 (external edit) skipped until Stage 3"
```

---

### Task 4: Harness tests 8–10 (race regression + burst behaviour) [S]

**Files:**
- Modify: `MaughamTests/Editor/EditorIntegrationHarnessTests.swift`

- [ ] **Step 1: Add tests 8, 9, 10**

```swift
func test_endOfFileTyping_doesNotFireApplyExternalText() {
    let rig = EditorIntegrationHarness(initialText: "Hello")
    rig.setCursor(to: 5)

    rig.assertNoApplyExternalText {
        rig.typeCharacter(" ")
        rig.typeCharacter("w")
        rig.typeCharacter("o")
        rig.typeCharacter("r")
        rig.typeCharacter("l")
        rig.typeCharacter("d")
    }

    XCTAssertEqual(rig.currentText, "Hello world")
    XCTAssertEqual(rig.cursorLocation, 11)
}

func test_documentSwitch_flushesPendingBurst_beforeNewBinding() async throws {
    // This test pins the contract that switching documents flushes any
    // pending burst on the previously-loaded doc. The harness today
    // doesn't run a multi-doc binder, so this test is XCTSkip'd until
    // Stage 2 lands DocumentStore.register + Document.close.
    throw XCTSkip("Multi-doc switching wired in Stage 2 via Document.close")
}

func test_burst_appendOnceAtIdleThreshold() async throws {
    // BurstScheduler is idle: 30s, max: 90s today. Verifying a single
    // typing_burst op lands after the idle threshold requires either a
    // 30-second test (too slow) or a test-only constructor that lets
    // us override the thresholds. Stage 1 lands the Document type with
    // testable thresholds; this test un-skips then.
    throw XCTSkip("Testable burst thresholds land with Document in Stage 1")
}
```

- [ ] **Step 2: Run the tests**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/EditorIntegrationHarnessTests test 2>&1 | tail -15
```
Expected: 10 tests; 6 pass (1-5 + 8), 4 skipped (6, 7, 9, 10). Test 8 passes today because the recent fix (`8c73883`) closed the binding-loop race.

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/Editor/EditorIntegrationHarnessTests.swift
git commit -m "test: harness tests 8-10 (race regression + burst contract)"
```

---

### Task 5: Document type — skeleton + load factory [O]

**Files:**
- Create: `Maugham/OpLog/Document.swift`
- Modify: `Maugham/Stores/DocumentStore.swift` (expose presenter)

You're on opus because Document is the foundation; getting the load factory right (Bootstrap wiring + crash-recovery + initial state) determines everything downstream.

- [ ] **Step 1: Expose DocumentStore's presenter**

In `Maugham/Stores/DocumentStore.swift`, change:

```swift
private var presenter: ProjectFolderPresenter?
```

to:

```swift
internal var presenter: NSFilePresenter? { return _presenter }
private var _presenter: ProjectFolderPresenter?
```

Then update the three internal references (`self.presenter = presenter`, `if let presenter`, `NSFileCoordinator(filePresenter: presenter)`) to use `_presenter` for the writes and `presenter` for the reads where they cross the public boundary. (Most internal uses stay as `_presenter` since they're inside DocumentStore.)

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Write Document.swift skeleton + load factory**

Create `Maugham/OpLog/Document.swift`:

```swift
import Foundation
import AppKit

/// Per-manuscript canonical state. Owns its op log + pending buffer +
/// burst scheduler + autosave + conflict detection. The single
/// `displayText` property is the only observed text-state; SwiftUI body
/// re-evaluates against it, and every internal mutation path writes
/// `_displayText` exactly once at the end so updateNSView always sees a
/// consistent (textView, text) pair.
///
/// See docs/superpowers/specs/2026-05-19-document-first-class-oplog-design.md
@MainActor
@Observable
public final class Document {

    // === Public observed state ===
    public private(set) var displayText: String = ""
    public var cursorLocation: Int = 0
    public private(set) var pendingConflict: ConflictState?

    // === Internal state ===
    private let url: URL
    public let docId: String
    private let device: String
    private let session: String
    private let presenter: NSFilePresenter?
    private let opStore: OpLogStore
    private let pending: PendingBuffer
    private let burstScheduler: BurstScheduler

    private var paragraphs: [String: String]
    private var sequence: [String]
    private var lastWrittenText: String

    /// Internal autosave debounce (replaces DocumentStore.scheduleSave).
    private var autosaveScheduler: DebounceScheduler<Void>!

    private init(
        url: URL, docId: String, device: String, session: String,
        presenter: NSFilePresenter?, opStore: OpLogStore,
        pending: PendingBuffer, burstScheduler: BurstScheduler,
        paragraphs: [String: String], sequence: [String],
        lastWrittenText: String
    ) {
        self.url = url
        self.docId = docId
        self.device = device
        self.session = session
        self.presenter = presenter
        self.opStore = opStore
        self.pending = pending
        self.burstScheduler = burstScheduler
        self.paragraphs = paragraphs
        self.sequence = sequence
        self.lastWrittenText = lastWrittenText
    }

    /// Construct a Document from an on-disk manuscript file. Runs the
    /// Bootstrap migration if needed (the .md lacks inline ¶id markers
    /// or no op log exists yet). Recovers from a crashed pending buffer
    /// by folding its contents into a synthesized typing_burst op.
    public static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?
    ) async throws -> Document {
        // Resolve doc-id by looking up the manifest. For tests + initial
        // setup, fall back to a deterministic id derived from the path.
        let docId = try resolveDocId(for: url)

        // projectURL is the parent of the manuscript/ folder.
        let projectURL = url.deletingLastPathComponent()
            .deletingLastPathComponent()

        // Bootstrap detection.
        let opLogPath = projectURL
            .appendingPathComponent(".maugham/ops/\(docId).jsonl")
        let logExists = FileManager.default.fileExists(atPath: opLogPath.path)
        let storedBytes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let parsed = ParagraphParser.parse(storedBytes)
        let needsBootstrap = !logExists || parsed.allSatisfy { $0.id == nil }

        if needsBootstrap {
            _ = try await Bootstrap.run(
                projectURL: projectURL, docId: docId,
                mdURL: url, device: device, session: session)
        }

        let opStore = OpLogStore(projectURL: projectURL, presenter: presenter)
        let pending = PendingBuffer(projectURL: projectURL, docId: docId)
        try await pending.loadFromDisk()

        var ops = try await opStore.load(docId: docId)

        // Crash recovery: fold any pending changes into a real op.
        if !pending.isEmpty() {
            let recovered = Op(
                opId: ULID.generate(), docId: docId, at: Date(),
                device: device, session: session, kind: .typingBurst,
                changes: pending.snapshot())
            try await opStore.append(recovered)
            try await pending.clear()
            ops.append(recovered)
        }

        let initial = Deriver.derive(ops: ops)
        let lastWritten = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // BurstScheduler with default thresholds.
        let burstHolder = WeakBurstHolder()
        let burst = BurstScheduler(
            idle: .seconds(30), max: .seconds(90)
        ) {
            Task { @MainActor in
                try? await burstHolder.document?.flushBurstNow()
            }
        }

        let doc = Document(
            url: url, docId: docId, device: device, session: session,
            presenter: presenter, opStore: opStore, pending: pending,
            burstScheduler: burst,
            paragraphs: initial.paragraphs, sequence: initial.sequence,
            lastWrittenText: lastWritten)
        burstHolder.document = doc

        // Initialize autosave + displayText.
        doc.autosaveScheduler = DebounceScheduler<Void>(
            delay: .milliseconds(750)
        ) { [weak doc] _ in
            try? await doc?.performAutosave()
        }
        doc.recomputeDisplayText()
        return doc
    }

    private func recomputeDisplayText() {
        var rendered = ""
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            if !rendered.isEmpty { rendered.append("\n\n") }
            rendered.append(text)
        }
        displayText = rendered
    }

    private func performAutosave() async throws {
        let bytes = materialize()
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var writeErr: Error?
        coord.coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordErr
        ) { wu in
            do {
                try bytes.data(using: .utf8)?.write(to: wu, options: .atomic)
                self.lastWrittenText = bytes
            } catch {
                writeErr = error
            }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    public func materialize() -> String {
        return Materializer.materialize(
            paragraphs: paragraphs, sequence: sequence)
    }

    // === Stubs to be filled in by Tasks 6-8 ===
    public func setFullText(_ text: String) {
        fatalError("setFullText: implemented in Task 6")
    }
    public func setParagraph(id: String, text: String) {
        fatalError("setParagraph: implemented in Task 6")
    }
    public func insertParagraph(after: String?, text: String) -> String {
        fatalError("insertParagraph: implemented in Task 6")
    }
    public func deleteParagraph(id: String) {
        fatalError("deleteParagraph: implemented in Task 6")
    }
    public func reorder(sequence: [String]) {
        fatalError("reorder: implemented in Task 6")
    }
    public func flushBurstNow() async throws {
        fatalError("flushBurstNow: implemented in Task 7")
    }
    public func close() async {
        fatalError("close: implemented in Task 7")
    }
    public func handleExternalDiskChange(diskMd: String) async throws {
        fatalError("handleExternalDiskChange: implemented in Task 8")
    }
    public func handleExternalLogChange() async throws {
        fatalError("handleExternalLogChange: implemented in Task 8")
    }
    public func resolveConflictKeepMine() async throws {
        fatalError("resolveConflictKeepMine: implemented in Task 8")
    }
    public func resolveConflictUseExternal() async throws {
        fatalError("resolveConflictUseExternal: implemented in Task 8")
    }
}

/// Looks up the doc-id for a manuscript path. For now resolves via the
/// manifest if available; falls back to a deterministic hash of the
/// relative path. Test helper; real lookup will use ProjectStore.
internal func resolveDocId(for url: URL) throws -> String {
    let projectURL = url.deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifestURL = projectURL
        .appendingPathComponent("project.maugham.json")
    let relativePath = url.path
        .replacingOccurrences(of: projectURL.path + "/", with: "")
    if let data = try? Data(contentsOf: manifestURL) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let manifest = try? dec.decode(ProjectManifest.self, from: data),
           let item = findItemByPath(relativePath, in: manifest.structure) {
            return item.id
        }
    }
    // Fallback: deterministic id from path. Sufficient for tests.
    return "doc-\(relativePath.hashValue.magnitude)"
}

private func findItemByPath(_ path: String, in items: [StructureItem]) -> StructureItem? {
    for item in items {
        if item.path == path { return item }
        if let kids = item.children,
           let found = findItemByPath(path, in: kids) { return found }
    }
    return nil
}

/// Indirection so BurstScheduler's fire closure can reference the
/// Document without a retain cycle.
@MainActor
private final class WeakBurstHolder {
    weak var document: Document?
}
```

- [ ] **Step 3: Build, confirm compile**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Tests still pass (Document isn't used by anything yet).

- [ ] **Step 4: Commit**

```bash
git add Maugham/OpLog/Document.swift Maugham/Stores/DocumentStore.swift
git commit -m "feat: Document type skeleton + load factory with Bootstrap + crash-recovery"
```

---

### Task 6: Document mutation API — setFullText + paragraph methods [O]

**Files:**
- Modify: `Maugham/OpLog/Document.swift`

You're on opus because the mutation API determines how Document interacts with downstream consumers; getting it wrong here makes editing UX harder later.

- [ ] **Step 1: Implement setFullText (the editor entry point)**

Replace the `setFullText` stub in `Document.swift` with:

```swift
public func setFullText(_ text: String) {
    // Build the next stored form by running restoreComments against
    // the current materialized state. This is the same parse+diff
    // that EditorHost used to do; relocating it to Document.
    let priorStored = Materializer.materialize(
        paragraphs: paragraphs, sequence: sequence)
    let nextStored = RenderFilter.restoreComments(
        stored: priorStored, displayEdited: text)

    // Parse the new stored form to extract paragraph-level changes.
    let priorParsed = ParagraphParser.parse(priorStored)
    let nextParsed = ParagraphParser.parse(nextStored)
    var priorById: [String: String] = [:]
    for p in priorParsed {
        if let id = p.id { priorById[id] = p.text }
    }

    // Collect changes and the new sequence.
    var changes: [Op.ParagraphChange] = []
    var newSequence: [String] = []
    for p in nextParsed {
        guard let id = p.id else { continue }
        newSequence.append(id)
        let prior = priorById[id]
        if prior != p.text {
            changes.append(.init(paragraphId: id, prior: prior, next: p.text))
            pending.recordChange(
                paragraphId: id, prior: prior, next: p.text)
        }
    }

    // Update internal derived state.
    var newParagraphs: [String: String] = paragraphs
    for change in changes {
        newParagraphs[change.paragraphId] = change.next
    }
    let sequenceChanged = (newSequence != sequence)
    self.paragraphs = newParagraphs
    self.sequence = newSequence

    // Tickle the burst scheduler so the typing_burst op fires on
    // idle / max thresholds.
    if !changes.isEmpty || sequenceChanged {
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
    }

    // ONE @Observable write at the end. SwiftUI sees one body re-eval.
    recomputeDisplayText()
}
```

- [ ] **Step 2: Implement paragraph mutation API**

```swift
public func setParagraph(id: String, text: String) {
    let prior = paragraphs[id]
    guard prior != text else { return }
    pending.recordChange(paragraphId: id, prior: prior, next: text)
    paragraphs[id] = text
    burstScheduler.recordActivity()
    autosaveScheduler.schedule(())
    recomputeDisplayText()
}

public func insertParagraph(after: String?, text: String) -> String {
    let newId = ParagraphID.mint()
    paragraphs[newId] = text
    if let after, let idx = sequence.firstIndex(of: after) {
        sequence.insert(newId, at: idx + 1)
    } else {
        sequence.append(newId)
    }
    pending.recordChange(paragraphId: newId, prior: nil, next: text)
    burstScheduler.recordActivity()
    autosaveScheduler.schedule(())
    recomputeDisplayText()
    return newId
}

public func deleteParagraph(id: String) {
    guard paragraphs[id] != nil else { return }
    let priorText = paragraphs[id]
    paragraphs.removeValue(forKey: id)
    sequence.removeAll { $0 == id }
    // Record deletion as an op with empty next text (consumer-visible
    // marker that the paragraph went away; sequence change carries the
    // ordering).
    pending.recordChange(paragraphId: id, prior: priorText, next: "")
    burstScheduler.recordActivity()
    autosaveScheduler.schedule(())
    recomputeDisplayText()
}

public func reorder(sequence: [String]) {
    self.sequence = sequence
    // No paragraph-change ops for pure reorder; the next typing_burst
    // emission will carry the new sequence as its `sequence` field.
    burstScheduler.recordActivity()
    autosaveScheduler.schedule(())
    recomputeDisplayText()
}
```

- [ ] **Step 3: Build + run all tests to confirm no regressions**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: same suite count as before + harness tests passing.

- [ ] **Step 4: Commit**

```bash
git add Maugham/OpLog/Document.swift
git commit -m "feat: Document mutation API (setFullText + paragraph methods)"
```

---

### Task 7: Document persistence — flushBurstNow + close [S]

**Files:**
- Modify: `Maugham/OpLog/Document.swift`

- [ ] **Step 1: Implement flushBurstNow and close**

Replace the corresponding stubs in `Document.swift`:

```swift
public func flushBurstNow() async throws {
    guard !pending.isEmpty() else { return }
    let changes = pending.snapshot()
    // Capture the latest sequence on the burst so cross-Mac merge sees
    // ordering changes.
    let op = Op(
        opId: ULID.generate(),
        docId: docId, at: Date(),
        device: device, session: session,
        kind: .typingBurst,
        changes: changes,
        sequence: sequence,
        provenance: nil)
    try await opStore.append(op)
    try await pending.clear()
}

public func close() async {
    // Flush any pending burst so editorial classification survives the
    // close (matches EditorHost's onDocChange behaviour).
    try? await flushBurstNow()
    // Flush any pending autosave so the .md reflects the final state.
    await autosaveScheduler.flush()
}
```

- [ ] **Step 2: Persist pending buffer mid-burst (crash safety)**

Add a hook into autosaveScheduler so the pending buffer is mirrored to `.pending.jsonl` on each autosave tick (matches the existing crash-recovery story):

```swift
private func performAutosave() async throws {
    // Mirror pending buffer to disk for crash recovery.
    try? await pending.flushToDisk()

    let bytes = materialize()
    let coord = NSFileCoordinator(filePresenter: presenter)
    var coordErr: NSError?
    var writeErr: Error?
    coord.coordinate(
        writingItemAt: url, options: .forReplacing, error: &coordErr
    ) { wu in
        do {
            try bytes.data(using: .utf8)?.write(to: wu, options: .atomic)
            self.lastWrittenText = bytes
        } catch {
            writeErr = error
        }
    }
    if let coordErr { throw coordErr }
    if let writeErr { throw writeErr }
}
```

- [ ] **Step 3: Build + run full suite**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: tests pass.

- [ ] **Step 4: Commit**

```bash
git add Maugham/OpLog/Document.swift
git commit -m "feat: Document persistence (flushBurstNow + close + crash-safe pending mirror)"
```

---

### Task 8: Document external-edit ingest + conflict resolution [O]

**Files:**
- Modify: `Maugham/OpLog/Document.swift`

You're on opus because external-edit handling has subtle invariants (echo vs ingest vs sheet, log-merge vs disk-conflict) and is the path the audit flagged as untested end-to-end.

- [ ] **Step 1: Implement handleExternalDiskChange**

Replace the stub:

```swift
public func handleExternalDiskChange(diskMd: String) async throws {
    // Echo guard: this is the file change we ourselves just wrote.
    guard diskMd != lastWrittenText else { return }

    let derivedMd = materialize()
    let classification = Reconciler.classify(
        diskMd: diskMd, derivedMd: derivedMd)

    switch classification {
    case .echo:
        return

    case .silentIngest(let changes):
        // Construct an external_edit op carrying the changes.
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .externalEdit,
            changes: changes,
            sequence: nil,
            provenance: .init(synthesisSource: "disk_at_ingest"))
        try await opStore.append(op)
        // Update internal state.
        for change in changes {
            paragraphs[change.paragraphId] = change.next
        }
        lastWrittenText = diskMd
        recomputeDisplayText()

    case .needsSheet(let orphanCount):
        // Surface a pending conflict. UI reads document.pendingConflict.
        pendingConflict = ConflictState(
            path: url.path,
            localText: derivedMd,
            externalText: diskMd,
            externalModifiedAt: Date())
        _ = orphanCount  // (currently unused; could feed into the UI sheet)
    }
}
```

- [ ] **Step 2: Implement handleExternalLogChange (cross-Mac log-merge)**

```swift
public func handleExternalLogChange() async throws {
    // Reload the log file (OpLogStore.load dedupes by op_id and sorts).
    let ops = try await opStore.load(docId: docId)

    // Re-derive from the merged log.
    let state = Deriver.derive(ops: ops)
    self.paragraphs = state.paragraphs
    self.sequence = state.sequence

    // No conflict UI for log merge. Just publish the new state.
    recomputeDisplayText()
}
```

- [ ] **Step 3: Implement conflict resolution**

```swift
public func resolveConflictKeepMine() async throws {
    guard let conflict = pendingConflict else { return }

    // Preserve the external version as a conflict backup before
    // overwriting (matches DocumentStore's existing backup behaviour).
    try writeConflictBackup(text: conflict.externalText, kind: "cloud")

    // Schedule an autosave of our current derived state. The disk
    // re-write happens via the autosave path.
    autosaveScheduler.schedule(())
    await autosaveScheduler.flush()
    pendingConflict = nil
}

public func resolveConflictUseExternal() async throws {
    guard let conflict = pendingConflict else { return }

    // Preserve our local version as a backup before accepting external.
    try writeConflictBackup(text: conflict.localText, kind: "local")

    // Ingest the external bytes as a synthesized external_edit op,
    // same as the silent-ingest path would have done if IDs had been
    // intact.
    try await handleExternalDiskChangeForceIngest(diskMd: conflict.externalText)
    pendingConflict = nil
}

private func handleExternalDiskChangeForceIngest(diskMd: String) async throws {
    // For "Use cloud" resolution: ignore the Reconciler classification
    // and ingest the diskMd verbatim. The new paragraphs may get fresh
    // IDs minted by restoreComments since the user-typed IDs are gone.
    let priorStored = materialize()
    let nextStored = RenderFilter.restoreComments(
        stored: priorStored, displayEdited:
            RenderFilter.stripComments(diskMd))
    let parsed = ParagraphParser.parse(nextStored)

    var newParagraphs: [String: String] = [:]
    var newSequence: [String] = []
    var changes: [Op.ParagraphChange] = []
    for p in parsed {
        guard let id = p.id else { continue }
        let prior = paragraphs[id]
        newParagraphs[id] = p.text
        newSequence.append(id)
        if prior != p.text {
            changes.append(.init(paragraphId: id, prior: prior, next: p.text))
        }
    }

    let op = Op(
        opId: ULID.generate(),
        docId: docId, at: Date(),
        device: device, session: session,
        kind: .externalEdit,
        changes: changes,
        sequence: newSequence,
        provenance: .init(synthesisSource: "use_cloud_resolution"))
    try await opStore.append(op)
    self.paragraphs = newParagraphs
    self.sequence = newSequence
    self.lastWrittenText = diskMd
    recomputeDisplayText()
}

private func writeConflictBackup(text: String, kind: String) throws {
    let projectURL = url.deletingLastPathComponent()
        .deletingLastPathComponent()
    let conflictsDir = projectURL.appendingPathComponent(".maugham/conflicts")
    try FileManager.default.createDirectory(
        at: conflictsDir, withIntermediateDirectories: true)
    let filename = url.lastPathComponent
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

- [ ] **Step 4: Build + run full suite**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/OpLog/Document.swift
git commit -m "feat: Document external-edit ingest + conflict resolution"
```

---

### Task 9: Document unit tests [S]

**Files:**
- Create: `MaughamTests/OpLog/DocumentTests.swift`

- [ ] **Step 1: Write unit tests for Document in isolation**

```swift
// MaughamTests/OpLog/DocumentTests.swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentTests: XCTestCase {

    private func makeProject(initialMd: String = "") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DOC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        // Minimal manifest so resolveDocId can find the doc.
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", type: .document, title: "C1",
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    func test_load_emptyDocument_displayTextIsEmpty() async throws {
        let (project, path) = try makeProject(initialMd: "")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        XCTAssertEqual(doc.displayText, "")
    }

    func test_load_existingMd_runsBootstrapAndPopulatesDisplayText() async throws {
        let (project, path) = try makeProject(initialMd: "Hello world.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        // After bootstrap, the .md gained inline ¶id markers; displayText
        // is the stripped form.
        XCTAssertEqual(doc.displayText, "Hello world.")
    }

    func test_setFullText_updatesDisplayTextOnce() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        doc.setFullText("Hello world.")
        XCTAssertEqual(doc.displayText, "Hello world.")
    }

    func test_setFullText_emitsParagraphChangeIntoPendingBuffer() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        doc.setFullText("Hello world.")
        try await doc.flushBurstNow()
        let opStore = OpLogStore(projectURL: project)
        let ops = try await opStore.load(docId: doc.docId)
        // Bootstrap op + typing_burst op.
        XCTAssertGreaterThanOrEqual(ops.count, 2)
        let burst = ops.last!
        XCTAssertEqual(burst.kind, .typingBurst)
    }

    func test_materialize_roundTripsThroughBootstrap() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n\nWorld.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let rendered = doc.materialize()
        // Rendered form has inline ¶id markers; parsing back yields the
        // same paragraph texts.
        let parsed = ParagraphParser.parse(rendered)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].text, "Hello.")
        XCTAssertEqual(parsed[1].text, "World.")
    }

    func test_close_flushesBurstAndAutosave() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        doc.setFullText("Hello world.")
        await doc.close()
        // After close, the .md on disk reflects materialize().
        let onDisk = try String(
            contentsOf: project.appendingPathComponent(path),
            encoding: .utf8)
        XCTAssertTrue(onDisk.contains("Hello world."))
    }

    func test_handleExternalDiskChange_echo_isNoOp() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        // Force lastWrittenText to match the diskMd we'll feed in.
        doc.setFullText("Hello.")
        await doc.close()
        let onDisk = try String(
            contentsOf: project.appendingPathComponent(path),
            encoding: .utf8)
        try await doc.handleExternalDiskChange(diskMd: onDisk)
        XCTAssertNil(doc.pendingConflict)
    }
}
```

- [ ] **Step 2: Run + confirm pass**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentTests test 2>&1 | tail -5
```
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 3: Run full suite**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: 720+ tests passing.

- [ ] **Step 4: Commit**

```bash
git add MaughamTests/OpLog/DocumentTests.swift
git commit -m "test: Document unit tests (load + setFullText + persistence + external-edit)"
```

---

### Task 10: DocumentStore registry + EditorHost migration [O]

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift` (add registry; keep existing op-log block for now)
- Modify: `Maugham/Views/EditorHost.swift` (full refactor to Document binding)

You're on opus because this is the cutover: the editor stops using `documentText` + `priorStoredMarkdown` + `currentDocumentText` and starts using `Document`. Must not break milestone-1e behaviour (autosave + conflict resolution) — those still work via DocumentStore's existing paths until Stage 3 removes them.

- [ ] **Step 1: Add the Document registry to DocumentStore**

In `Maugham/Stores/DocumentStore.swift`, add new public methods near the bottom of the class (before the extension):

```swift
// MARK: - Document registry (Stage 2 of document-first-class refactor)

private var openDocuments: [String: Document] = [:]

public func register(document: Document, for path: String) {
    openDocuments[path] = document
}

public func unregister(path: String) {
    openDocuments.removeValue(forKey: path)
}

public func document(for path: String) -> Document? {
    openDocuments[path]
}

public func document(forDocId docId: String) -> Document? {
    openDocuments.values.first(where: { $0.docId == docId })
}
```

- [ ] **Step 2: Refactor EditorHost to use Document**

Replace the entire `body` of `Maugham/Views/EditorHost.swift` with the design from spec §3:

```swift
// Top of struct EditorHost:
@State private var document: Document?
@State private var loadedItemId: String?
@State private var priorLoadedPath: String?

// Body:
var body: some View {
    Group {
        if let item = currentItem, item.type == .document, let path = item.path,
           let doc = document, loadedItemId == item.id {
            EditorSurface(
                text: Binding(
                    get: { doc.displayText },
                    set: { doc.setFullText($0) }
                ),
                theme: userPreferences.theme,
                typography: ProjectStore.effectiveTypography(
                    override: store.manifest.typography,
                    userDefault: userPreferences.typography),
                mode: WritingModeFactory.mode(for: path),
                typewriterScroll: userPreferences.typewriterScroll,
                sentenceFocus: userPreferences.sentenceFocus,
                paragraphFocus: userPreferences.paragraphFocus,
                initialCursorLocation: doc.cursorLocation,
                onCursorChanged: { doc.cursorLocation = $0 },
                wikiLinkResolver: wikiLinkResolver,
                wikiLinkClickResolver: wikiLinkClickResolver,
                showElementGutter: store.manifest.showElementGutter ?? true
            )
            .id(path)
        } else if currentItem?.type == .group {
            placeholder("Select a document inside this group to edit.")
        } else if currentItem?.type == .document {
            placeholder("Loading…")
        } else {
            placeholder("Select a document.")
        }
    }
    .onChange(of: selectedItemId) { _, _ in
        Task { await loadDocumentIfNeeded() }
    }
    .onChange(of: document?.displayText) { _, newValue in
        if let text = newValue { onTextChange?(text) }
    }
    .task { await loadDocumentIfNeeded() }
}

private func loadDocumentIfNeeded() async {
    guard let item = currentItem,
          item.type == .document,
          let path = item.path,
          loadedItemId != item.id else { return }
    if let prior = document, let priorPath = priorLoadedPath {
        await prior.close()
        documentStore.unregister(path: priorPath)
    }
    do {
        let doc = try await Document.load(
            url: store.url.appendingPathComponent(path),
            device: Self.deviceId,
            session: Self.sessionId,
            presenter: documentStore.presenter)
        documentStore.register(document: doc, for: path)
        document = doc
        loadedItemId = item.id
        priorLoadedPath = path
        onTextChange?(doc.displayText)
    } catch {
        document = nil
        loadedItemId = item.id
        priorLoadedPath = nil
    }
}
```

Remove these existing fields from EditorHost:
- `@State private var documentText: String = ""`
- `@State private var priorStoredMarkdown: String = ""`
- The two `.onChange(of: ...)` blocks for documentText and documentStore.lastWrittenText (replaced by `.onChange(of: document?.displayText)`).

- [ ] **Step 3: Build + run all tests**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: tests pass. Test 8 in EditorIntegrationHarnessTests should still pass (it was passing post-`8c73883`).

- [ ] **Step 4: Smoke test in app**

Open Xcode, run the app, type in a document. Verify:
- Cursor stays where you put it
- Typing at end of file works correctly
- Saving via ⌘S works
- Closing the app cleanly persists

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift Maugham/Views/EditorHost.swift
git commit -m "feat: EditorHost binds to Document; DocumentStore gains registry"
```

---

### Task 11: Move presenter dispatch + remove old DocumentStore code [O]

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift` (remove ~250 lines, route presenter callbacks)

You're on opus because this is the structural removal: DocumentStore loses op-log block (~120 lines), autosave path (~80 lines), conflict detection (~80 lines), `openDocument`, `currentDocumentText`, `lastWrittenText`. Must not regress the harness tests.

- [ ] **Step 1: Update presenterDidChangeSubitem to route via the registry**

Replace the body of `presenterDidChangeSubitem(at:)` in the extension at the bottom of `DocumentStore.swift`:

```swift
public func presenterDidChangeSubitem(at url: URL) {
    let project = projectURL.standardizedFileURL.path
    let changed = url.standardizedFileURL.path
    guard changed.hasPrefix(project + "/") else { return }
    let relativePath = String(changed.dropFirst(project.count + 1))

    // Manifest changes — handle in DocumentStore (existing path).
    if relativePath == "project.maugham.json" {
        handleManifestChanged()
        return
    }

    // Op log changes — route to the matching Document.
    if relativePath.hasPrefix(".maugham/ops/")
        && relativePath.hasSuffix(".jsonl")
        && !relativePath.hasSuffix(".pending.jsonl") {
        let filename = (relativePath as NSString).lastPathComponent
        let docId = (filename as NSString).deletingPathExtension
        if let doc = document(forDocId: docId) {
            Task { @MainActor in
                try? await doc.handleExternalLogChange()
            }
        }
        NotificationCenter.default.post(
            name: .maughamOpLogChanged, object: nil,
            userInfo: ["path": relativePath])
        return
    }

    // Checkpoints — post the existing notification.
    if relativePath == ".maugham/checkpoints.jsonl" {
        NotificationCenter.default.post(
            name: .maughamCheckpointAdded, object: nil)
        return
    }

    // Manuscript document changes — route to the Document.
    if let doc = document(for: relativePath) {
        Task { @MainActor in
            let mdURL = projectURL.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: mdURL),
                  let diskText = String(data: data, encoding: .utf8) else { return }
            try? await doc.handleExternalDiskChange(diskMd: diskText)
        }
    }
}
```

- [ ] **Step 2: Remove the now-obsolete code**

Delete from `Maugham/Stores/DocumentStore.swift`:

1. The entire `// MARK: - Op log integration` block (the `OpLogContext` struct, `opLogContext`, `burstScheduler` properties, and methods `beginOpLogContext` / `recordParagraphChange` / `opLogPendingIsEmpty` / `flushBurstNow` / `persistPendingBufferToDisk`).
2. The autosave path: `saveScheduler`, `SavePayload`, `scheduleSave`, `flushPendingSave`, `performSave`.
3. The `currentDocumentText`, `lastWrittenText`, `openDocumentPath` properties.
4. The `openDocument(at:)` method.
5. The conflict detection methods: `resolveConflictKeepMine`, `resolveConflictUseCloud`, `writeConflictBackup`, `handleOpenDocumentChanged`.
6. The `pendingConflict` property and `waitForConflictState`, `waitForLastWrittenText` helpers (now lives on Document).
7. The cursor-position methods: `cursor(for:)`, `setCursor(_:for:)`, `cursorPositions` (now on Document).

Keep:
- `projectURL`, `uiState`, `uiStateScheduler`, `lastObservedManifestModified`, `sessionTracker`, `idleTimerToken`, `lastKnownProjectWordCount`, `sessionIdleThreshold`
- `presenter`, `_presenter`
- `open(url:)`, `close()`
- `updateUIState(_:)`
- `writeManifest(_:)`, `readManifest()`
- Session tracking: `loadSessionLog()`, `appendSessionEvent()`, `recordSessionActivity()`, `flushSessionOnQuit()`
- Rename execution: `executeRenamePlan(_:)`, `executeCopy(from:to:)`, `coordinatedMove(from:to:)`
- `persistUIState(_:)`
- Manifest conflict archive: `handleManifestChanged()`, `archiveManifestForConflict(data:)`
- `presenterDidChangeSubitem(at:)` (updated above)
- `presenterDidObserveDirectoryChange()`

Net result: DocumentStore goes from 587 to ~250 lines.

- [ ] **Step 3: Update callers**

The following callers in other files will fail compilation after the removal — update them:

- Any code that called `documentStore.scheduleSave(for:text:)` — these were in `EditorHost` (already removed in Task 10) and possibly `ResearchNoteEditor`. Check with `grep -rn "scheduleSave\|currentDocumentText\|lastWrittenText\|openDocument" Maugham/` and migrate to either Document or ResearchStore as appropriate.
- `ResearchNoteEditor.swift` likely uses `documentStore.scheduleSave` for research notes. Research notes aren't Documents; they continue via direct file IO. Add a small `DocumentStore.scheduleResearchSave(for:text:)` if needed (just a renamed scheduleSave), OR switch the research path to direct NSFileCoordinator coordinated writes.

Verify with:

```bash
grep -rn "scheduleSave\|currentDocumentText\|lastWrittenText\|openDocument\|cursor(for:" Maugham/ MaughamTests/
```
Update each site.

- [ ] **Step 4: Build, fix any remaining call sites**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -20
```
Address every error. Common ones likely: tests that polled `documentStore.pendingConflict` (DocumentStoreConflictResolutionTests) — these need to migrate to `document.pendingConflict` (and probably move to DocumentTests.swift).

- [ ] **Step 5: Run full suite**

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: tests pass, including harness tests 6, 7 which can now be un-skipped (do that next).

- [ ] **Step 6: Un-skip harness tests 6 and 7**

In `MaughamTests/Editor/EditorIntegrationHarnessTests.swift`, replace the `throw XCTSkip(...)` body of `test_externalEditWithIdsIntact_ingestsSilently` and `test_externalEditWithIdsStripped_surfacesConflict` with the real assertions that the spec §6 describes:

```swift
func test_externalEditWithIdsIntact_ingestsSilently() async throws {
    let rig = EditorIntegrationHarness(
        initialText: "<!-- ¶a3f9 -->\n\nHello.\n")
    let docStore = try await rig.attachDocumentStore()
    let doc = try await Document.load(
        url: rig.projectURL.appendingPathComponent(rig.docPath),
        device: "m", session: "s", presenter: docStore.presenter)
    docStore.register(document: doc, for: rig.docPath)

    try await rig.writeExternalMdContent(
        "<!-- ¶a3f9 -->\n\nHello, edited.\n")
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertNil(doc.pendingConflict,
        "intact ¶ids → silent ingest, no conflict sheet")
    XCTAssertTrue(doc.displayText.contains("edited"))
}

func test_externalEditWithIdsStripped_surfacesConflict() async throws {
    let rig = EditorIntegrationHarness(
        initialText: "<!-- ¶a3f9 -->\n\nHello.\n")
    let docStore = try await rig.attachDocumentStore()
    let doc = try await Document.load(
        url: rig.projectURL.appendingPathComponent(rig.docPath),
        device: "m", session: "s", presenter: docStore.presenter)
    docStore.register(document: doc, for: rig.docPath)

    try await rig.writeExternalMdContent("Hello, edited (no IDs).\n")
    try await Task.sleep(for: .milliseconds(500))

    XCTAssertNotNil(doc.pendingConflict,
        "stripped ¶ids → conflict surfaces")
}
```

Run and confirm:

```bash
xcodebuild -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/EditorIntegrationHarnessTests test 2>&1 | tail -5
```
Expected: 10 tests, 0 skipped, 0 failures (the burst-threshold test 10 may stay skipped until we add a testable BurstScheduler constructor; that's fine).

- [ ] **Step 7: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift \
        MaughamTests/Editor/EditorIntegrationHarnessTests.swift \
        Maugham/ ...  # any other callers
git commit -m "refactor: move autosave + conflict + op-log from DocumentStore into Document; route presenter via registry"
```

---

### Task 12: UI conflict-sheet re-route + cursor migration [S]

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift` (two sites: lines 92 and 679)

- [ ] **Step 1: Re-route both pendingConflict reads in ProjectWindow**

`ProjectWindow.swift` currently has two sites that read `documentStore.pendingConflict`. Find them with:

```bash
grep -n "documentStore.pendingConflict" Maugham/Views/ProjectWindow.swift
```

Both need to read from the currently-active Document instead. Look up the active Document via the registry:

```swift
// Replace each occurrence of:
//   documentStore.pendingConflict
// with:
//   activeDocument?.pendingConflict
//
// Where activeDocument is a computed property added near the top of
// ProjectWindow's body or as a private var:
private var activeDocument: Document? {
    guard let id = selectedItemId,
          let item = findItem(id: id, in: store.manifest.structure),
          let path = item.path else { return nil }
    return documentStore.document(for: path)
}
```

The resolution actions (`resolveConflictKeepMine`, `resolveConflictUseCloud`) similarly call into Document:

```swift
// Replace:
//   try await documentStore.resolveConflictKeepMine()
// With:
//   try await activeDocument?.resolveConflictKeepMine()
//
// And:
//   try await documentStore.resolveConflictUseCloud()
// With:
//   try await activeDocument?.resolveConflictUseExternal()
```

(Note: `resolveConflictUseCloud` renamed to `resolveConflictUseExternal` on Document — more accurate since it covers iCloud + BBEdit + sed.)

- [ ] **Step 2: Build + run full suite**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: tests pass.

- [ ] **Step 3: Smoke test in app**

Open Xcode, run, simulate an external edit (modify a manuscript file in Finder while Maugham is open). Verify the conflict sheet appears and resolution actions work.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/ProjectWindow.swift
git commit -m "refactor: ProjectWindow conflict sheet binds to Document.pendingConflict"
```

---

### Task 13: Stage 5 cleanup — char-bigram tier moves into ShingleMatcher [H]

**Files:**
- Modify: `Maugham/OpLog/ShingleMatcher.swift` (add bigram function)
- Modify: `Maugham/Editor/RenderFilter.swift` (call into ShingleMatcher, remove local bigram code)
- Modify: `MaughamTests/OpLog/ShingleMatcherTests.swift` (add tests for bigram tier)

- [ ] **Step 1: Add character-bigram tier to ShingleMatcher**

In `Maugham/OpLog/ShingleMatcher.swift`, add:

```swift
/// Character-bigram overlap. Used as a fallback when word-shingle
/// matching fails for very short texts (< 4 words). Returns a value in
/// 0...1 indicating how many character bigrams overlap.
public static func bigramOverlap(_ a: String, _ b: String) -> Double {
    let bigramsA = bigrams(of: a)
    let bigramsB = bigrams(of: b)
    if bigramsA.isEmpty && bigramsB.isEmpty { return 1.0 }
    if bigramsA.isEmpty || bigramsB.isEmpty { return 0.0 }
    let inter = bigramsA.intersection(bigramsB).count
    let minSize = min(bigramsA.count, bigramsB.count)
    return Double(inter) / Double(minSize)
}

private static func bigrams(of text: String) -> Set<String> {
    let lower = text.lowercased()
    let chars = Array(lower)
    guard chars.count >= 2 else { return chars.isEmpty ? [] : [lower] }
    var s = Set<String>()
    for i in 0..<(chars.count - 1) {
        s.insert(String(chars[i...i+1]))
    }
    return s
}
```

- [ ] **Step 2: Update RenderFilter to call into ShingleMatcher**

In `Maugham/Editor/RenderFilter.swift`, find the char-bigram fallback inside `restoreComments`. Replace the inline computation with a call to `ShingleMatcher.bigramOverlap`. The signature of the third tier becomes:

```swift
// Third tier in restoreComments:
if let m = unmatchedById.max(by: {
    ShingleMatcher.bigramOverlap(d.text, $0.value)
        < ShingleMatcher.bigramOverlap(d.text, $1.value)
}), ShingleMatcher.bigramOverlap(d.text, m.value) >= 0.6 {
    pairs.append((m.key, d.text))
    unmatchedById.removeValue(forKey: m.key)
    continue
}
```

Remove the local `characterBigrams(of:)` helper from `RenderFilter.swift`.

- [ ] **Step 3: Add ShingleMatcher tests for the new tier**

In `MaughamTests/OpLog/ShingleMatcherTests.swift`, add:

```swift
func test_bigramOverlap_identicalShortText_isOne() {
    XCTAssertEqual(ShingleMatcher.bigramOverlap("hello", "hello"), 1.0, accuracy: 0.001)
}

func test_bigramOverlap_minorEditOnShortText_isHigh() {
    let score = ShingleMatcher.bigramOverlap("First.", "First, edited.")
    XCTAssertGreaterThan(score, 0.6)
}

func test_bigramOverlap_disjointText_isLow() {
    let score = ShingleMatcher.bigramOverlap("xyz", "abc")
    XCTAssertLessThan(score, 0.3)
}
```

- [ ] **Step 4: Run all tests**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/OpLog/ShingleMatcher.swift \
        Maugham/Editor/RenderFilter.swift \
        MaughamTests/OpLog/ShingleMatcherTests.swift
git commit -m "refactor: char-bigram tier moves into ShingleMatcher (audit #5)"
```

---

### Task 14: Stage 5 cleanup — applyFocusDim redundancy [H]

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`

- [ ] **Step 1: Audit where applyFocusDim is called**

```bash
grep -n "applyFocusDim" Maugham/Editor/EditorCoordinator.swift
```
Expected: three call sites — at the end of `retokenizeAndStyle()`, at the end of `textDidChange(_:)`, and inside `textViewDidChangeSelection(_:)`.

- [ ] **Step 2: Remove the redundant call from textDidChange**

The `retokenizeAndStyle()` call inside `textDidChange(_:)` already invokes `applyFocusDim` at its tail. The second invocation at the end of `textDidChange(_:)` is redundant for the text-change path.

Find and delete the line:

```swift
applyFocusDim(in: textView)
```

…inside `func textDidChange(_:)`. (Leave the call inside `retokenizeAndStyle()` and the call in `textViewDidChangeSelection(_:)` — both are intentional.)

Add a comment on the surviving calls so the next reader understands the intent:

```swift
// In retokenizeAndStyle, at the tail:
// applyFocusDim runs here because text changes require re-dimming. The
// textDidChange path delegates to us; no separate dim call needed.
applyFocusDim(in: textView)

// In textViewDidChangeSelection, near the existing call:
// applyFocusDim runs here for cursor-move-only selections (arrow keys,
// click) that don't go through retokenizeAndStyle.
applyFocusDim(in: textView)
```

- [ ] **Step 3: Run full suite**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: tests pass. Focus dim behaviour is unchanged.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift
git commit -m "refactor: remove applyFocusDim redundancy in textDidChange (audit #11)"
```

---

### Task 15: Final smoke + merge + tag + auto-memory update [H]

- [ ] **Step 1: Run full test suite one final time**

```bash
./gen.sh
xcodebuild -scheme Maugham -destination 'platform=macOS' test 2>&1 | grep -E "Executed.*tests|TEST SUCCEEDED|TEST FAILED" | tail -3
```
Expected: all tests pass.

- [ ] **Step 2: Manual smoke checklist**

Build and launch the app. Verify:
- [ ] Open existing manuscript project. Bootstrap notice appears (still using the one shipped in op-log milestone).
- [ ] Editor loads, displayText is the stripped form.
- [ ] Type characters at end of file — cursor stays put, no jumps.
- [ ] Type rapidly (mash keyboard) — cursor and text remain consistent.
- [ ] Type, pause, type again — trailing whitespace preserved.
- [ ] ⌘S triggers checkpoint (existing flow).
- [ ] Switch between documents in the binder — old doc's burst flushes; new doc loads.
- [ ] Edit a manuscript file externally in BBEdit, preserving ¶ids — Maugham silently ingests.
- [ ] Edit externally with ¶ids stripped — conflict sheet appears, resolution works.

- [ ] **Step 3: Ff-merge to main**

```bash
git checkout main
git merge --ff-only feat/milestone-document-first-class
```

- [ ] **Step 4: Tag and push**

```bash
git tag milestone-document-first-class
git push origin main
git push origin milestone-document-first-class
```

- [ ] **Step 5: Delete local branch**

```bash
git branch -d feat/milestone-document-first-class
```

- [ ] **Step 6: Update auto-memory**

Create `~/.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_document_first_class.md`:

```markdown
---
name: Milestone document-first-class shipped 2026-MM-DD
description: Operation log promoted from bolted-on system to canonical state. Document type owns op log + buffer + scheduler + autosave + conflict detection per manuscript; EditorHost binds to Document directly; DocumentStore is now a project-folder coordinator with Document registry. Headline audit finding fixed (Bootstrap now runs).
type: project
---

Shipped 2026-MM-DD, tag `milestone-document-first-class`. NNN tests
passing (up from 706).

## What's in
- New Document type at Maugham/OpLog/Document.swift (~400 lines)
- DocumentStore drops from 587 to ~250 lines; gains registry API
- EditorHost binds to Document.displayText (single source of truth);
  no more documentText / priorStoredMarkdown / currentDocumentText
- Bootstrap runs at Document.load — fixes audit headline finding
- Editor integration test harness at MaughamTests/Editor/
- Char-bigram tier moved into ShingleMatcher (audit #5)
- applyFocusDim redundancy in textDidChange removed (audit #11)

## Carry-forwards
- ProjectStore.swift split into multiple files (audit #6)
- OpLogStore + CheckpointStore shared JSONLAppendStore<T> (audit #9)
- CharacterAutocompleter dead-code decision (audit #4)
- BurstScheduler testable thresholds (harness test #10 still XCTSkip'd)
- MCP first-call-after-restart still flaky (deferred per memory)

## Foundation for what comes next
- Editing UX (annotations, accept/reject) — op_id anchoring is now natural
- craft_principles.md — Document is the right place to observe norms
- Compile pipeline — materialize() is the integration point
- History pane forensic scrub — opLog() exposes the burst-level history
```

Update `~/.claude/projects/-Users-denver-src-Maugham/memory/MEMORY.md` with a one-line index entry following the existing pattern.

Replace `2026-MM-DD` and `NNN` with the actual values.
