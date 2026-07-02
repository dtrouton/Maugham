# Scoped Window Events (ADR 0021) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every internal `maugham.*` event declares its delivery scope at the post site via a typed `MaughamEvent` wrapper; receive helpers implement each scope filter (including the closed-window liveness guard) exactly once; a tripwire makes a raw `maugham.*` post/subscription fail CI.

**Architecture:** A thin typed layer over NotificationCenter (`Maugham/Events/`): `MaughamEvent.post(_:to:object:payload:)` encodes an `EventScope` into reserved userInfo keys; a pure `shouldDeliver(_:to:)` filter plus View modifiers (`.onKeyWindowCommand` / `.onDocumentEvent` / `.onProjectEvent` / `.onGlobalEvent`) and a non-View `MaughamEvent.observe` helper own every drop rule. The 41 existing names migrate per-name-atomically (post + all receivers in one commit); the tripwire lands LAST.

**Tech Stack:** Swift / SwiftUI / AppKit, XCTest. Mac target only (`Maugham/` + `MaughamTests/`). No new dependencies.

## Global Constraints

- **Mac-only milestone.** Zero changes to `MaughamPhone/`. Zero NC usage may be added to `Packages/MaughamCore` (the wrapper is Mac-side by design; core stays notification-free). Inventory confirmed 2026-07-02: all `maugham*` NC usage is already Mac-target-only.
- **Per-name atomic migration.** A name's post site(s) and ALL its receivers move to the wrapper in the same commit. Reason: a helper-migrated receiver DROPS a raw (unscoped) legacy post — split migration silently kills the event. Never migrate receive-side ahead of post-side.
- **No semantic changes to delivery timing.** Same NotificationCenter underneath; `object:` passthrough preserved where a payload rides it (`FountainScript`, `publicationID`).
- **Do NOT resurrect `.maughamEffectiveAppearanceChanged`.** Deleted in v0.12.6, replaced by a direct per-view call (`effectiveAppearanceDidChange()`). See `Maugham/Editor/AREA.md`.
- **Apple system notifications are out of scope** (`NSApplication.willTerminateNotification` bridge observer, `NSText.didChange`, `NSView.boundsDidChange`, `NSWindow.didChangeBackingProperties`, `NSApplication.didBecomeActive`). Only the `maugham.*` namespace migrates.
- **The tripwire lands LAST** (Task 9) so CI is never red mid-migration.
- **After adding any new source file, run `./gen.sh`** (the `.xcodeproj` is generated from `project.yml` globs). Never hand-edit `project.pbxproj`.
- **Any change to `ProjectWindow.swift` body/modifiers ⇒ local Release build before tagging** (`xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`). Tasks 3 and 5 touch it heavily.
- **TDD throughout.** Write the failing test first for every wrapper/filter behavior and every migrated receiver class.
- Test command (Mac): `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (append `-only-testing:MaughamTests/<Class>` per task). Phone scheme runs once, in Task 11 (final verification): `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`.
- Simulator "Busy / failed preflight checks" is a flake — re-run; don't `simctl shutdown all`.

## The settled scope classification (41 names, re-verified against the tree 2026-07-02)

Two names were added since the ADR's 39-name survey (`maughamNavigateToParagraph`, `maughamNavigateToAnnotation`, collaboration WF1); the count is now 41: 39 in `Maugham/Models/MaughamNotifications.swift` + `maughamTestOpenProject` (`Maugham/MCP/Test/TestOpenBridge.swift:14`) + `maughamPublicationCompleted` (`Maugham/Views/Publish/ExportsListView.swift:125`).

**`.keyWindow` (27):** `toggleFullScreen`, `dummySave`, `showProjectSettings`, `showClaudeDesktopHelp`, `shareForReview`, `toggleInspector` (live double-window bug — fixed by this migration), `tidyAllFilenames`, `showProjectStatistics`, `addResearchFile`, `showSyntaxHelp`, `restoreLastDeleted`, `toggleResearchPreview`, `findInProject`, `setDetailSegment`, `closeFind`, `toggleNoChrome`, `toggleReviewMode`, `saveCheckpoint`, `namedCheckpoint`, `addLoosePiece`, `addScreenplayPiece`, `linkProject`, `promotePiece`, `navigateToScene`, `navigateToParagraph`, `navigateToAnnotation`, `findMatchSelected`.

**`.project` (7):** `scriptDidUpdate` (absorbs `ScriptUpdateRouting`), `openRewind`, `mcpNoteAdded`, `checkpointAdded`, `sessionLogChanged`, `publicationCompleted`, `navigateToDocument`.

**`.allWindows` (5):** `appWillTerminate`, `newProject`, `openProject`, `showHelp`, `testOpenProject` (dev-only).

**Deleted (2):** `opLogChanged`, `inboxChanged` — posted but received NOWHERE in the tree (inventory-confirmed; `InboxStore.refresh()` is a direct call at `DocumentStore.swift:764`, not an NC subscription). Task 6 deletes them after re-verifying.

**`.document`:** no production name currently needs it (its would-have-been user `opLogChanged` is dead). The enum case ships and is unit/liveness-tested so the first future doc-scoped event has a ready, tested home.

Two deliberate deviations from the spec's provisional (~2026-07-02-survey) lists, both sanctioned by the spec's own instruction to *read each receiver first*:

1. **`navigateToDocument` is `.project`, not `.keyWindow`.** One of its three post sites is `ProjectStatisticsWindow` (`:16`) — a separate window that IS key at click time, so the receiver's existing key-window guard (`ProjectWindow.swift:388`) makes stats-window navigation dead today. Project scoping fixes it (one window per project URL — `WindowGroup(for: URL.self)` dedups).
2. **`openRewind` stays project-scoped** (spec's key-window list predates reading the receiver): its receiver already does a correct `note.object as? URL == store?.url` comparison from the rewind-milestone retrofit. The migration preserves those semantics, swapping URL equality for `ProjectIdentifier.id` equality (symlink-stable, matches `scriptDidUpdate`/`mcpNoteAdded`).

`EventScope.project` carries `id: String` (`ProjectIdentifier.id(for:)`), not a raw `URL` — the existing correct scoped receivers (`scriptDidUpdate`, `mcpNoteAdded`) already compare project ids, and `EditorCoordinator` (a `.project` poster) holds only the id, not the URL. A `.project(for: URL)` convenience covers URL-holding call sites.

## File Structure

- Create: `Maugham/Events/MaughamEvent.swift` — `EventScope`, `MaughamEvent.post`, reserved scope keys, `EventReceiverContext`, `shouldDeliver`, `isLive`. The single home of every filter rule.
- Create: `Maugham/Events/MaughamEvent+Receive.swift` — View modifiers + non-View `observe`.
- Create: `MaughamTests/Events/MaughamEventTests.swift` — pure filter tests + post-encoding tests.
- Create: `MaughamTests/Events/MaughamEventLivenessTests.swift` — real-NSWindow closed-window tests + zombie-coordinator test (Task 8 adds to it).
- Modify: `Maugham/MaughamApp.swift` (17 command posts + 4 receivers + willTerminate bridge), `Maugham/Views/ProjectWindow.swift` (~30 receivers; deletes ~10 hand-written guards), `Maugham/Editor/EditorCoordinator.swift` (5 non-View receivers, 2 posts, `detach()`), `Maugham/Stores/DocumentStore.swift` (4 posts, 2 deleted), plus the per-name post/receiver files listed in each task's site table.
- Delete: `Maugham/Editor/ScriptUpdateRouting.swift` (absorbed into the wrapper, Task 5).
- Modify: `MaughamTests/TripwireGrepTests.swift` (Task 9), `MaughamTests/Editor/ScriptUpdateScopingTests.swift` → renamed/rewritten, `MaughamTests/RewindEntryPointsTests.swift`, `MaughamTests/Editor/EditorCoordinatorCycleTests.swift` (raw posts → wrapper).
- Docs (Task 10): `docs/adr/0021-scoped-window-events.md`, `CLAUDE.md`, `Maugham/Editor/AREA.md`, `Maugham/Views/AREA.md`, `docs/roadmap.md`, `Maugham/Models/MaughamNotifications.swift` doc comments.

---

### Task 1: Wrapper core — `EventScope`, `MaughamEvent.post`, `shouldDeliver`

**Files:**
- Create: `Maugham/Events/MaughamEvent.swift`
- Create: `MaughamTests/Events/MaughamEventTests.swift`

**Interfaces (Produces — later tasks rely on these exact signatures):**
```swift
enum EventScope: Equatable {
    case keyWindow
    case document(docId: String)
    case project(id: String)
    case allWindows
    static func project(for url: URL) -> EventScope
}
enum MaughamEvent {
    static let scopeKindKey: String   // "maugham.scope.kind"
    static let scopeIdKey: String     // "maugham.scope.id"
    static func post(_ name: Notification.Name, to scope: EventScope,
                     object: Any? = nil, payload: [AnyHashable: Any] = [:])
    @MainActor static func isLive(_ window: NSWindow?) -> Bool
    static func shouldDeliver(_ note: Notification, to context: EventReceiverContext) -> Bool
}
struct EventReceiverContext {
    enum Kind: Equatable {
        case keyWindow
        case document(docId: String)
        case project(id: String)
        case global
    }
    let kind: Kind
    let isWindowLive: Bool
    let isWindowKey: Bool
    @MainActor static func forWindow(_ window: NSWindow?, kind: Kind) -> EventReceiverContext
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/Events/MaughamEventTests.swift
import XCTest
@testable import Maugham

/// ADR 0021: scope is declared at the post site and enforced by ONE filter.
/// These tests exercise the pure core — post encoding + shouldDeliver — with
/// hand-built contexts (no real windows; liveness with real windows is
/// MaughamEventLivenessTests).
final class MaughamEventTests: XCTestCase {

    private let testName = Notification.Name("maugham.test.event")

    private func capturePost(_ scope: EventScope,
                             object: Any? = nil,
                             payload: [AnyHashable: Any] = [:]) -> Notification {
        var captured: Notification?
        let obs = NotificationCenter.default.addObserver(
            forName: testName, object: nil, queue: nil) { captured = $0 }
        defer { NotificationCenter.default.removeObserver(obs) }
        MaughamEvent.post(testName, to: scope, object: object, payload: payload)
        return captured!
    }

    // MARK: - Post encoding

    func test_post_encodesKeyWindowScope() {
        let note = capturePost(.keyWindow)
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeKindKey] as? String, "key-window")
        XCTAssertNil(note.userInfo?[MaughamEvent.scopeIdKey])
    }

    func test_post_encodesProjectScopeWithId() {
        let note = capturePost(.project(id: "proj_A"))
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeKindKey] as? String, "project")
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeIdKey] as? String, "proj_A")
    }

    func test_post_encodesDocumentScopeWithDocId() {
        let note = capturePost(.document(docId: "doc-abc"))
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeKindKey] as? String, "document")
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeIdKey] as? String, "doc-abc")
    }

    func test_post_preservesObjectAndPayload() {
        let payloadObject = NSObject()
        let note = capturePost(.allWindows, object: payloadObject, payload: ["id": "ch-1"])
        XCTAssertTrue(note.object as? NSObject === payloadObject)
        XCTAssertEqual(note.userInfo?["id"] as? String, "ch-1")
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeKindKey] as? String, "all-windows")
    }

    func test_projectScope_forURL_usesProjectIdentifier() {
        let url = URL(fileURLWithPath: "/tmp/some-project")
        XCTAssertEqual(EventScope.project(for: url),
                       EventScope.project(id: ProjectIdentifier.id(for: url)))
    }

    // MARK: - shouldDeliver: key-window class

    private func note(_ scope: EventScope, payload: [AnyHashable: Any] = [:]) -> Notification {
        capturePost(scope, payload: payload)
    }

    private func ctx(_ kind: EventReceiverContext.Kind,
                     live: Bool = true, key: Bool = false) -> EventReceiverContext {
        EventReceiverContext(kind: kind, isWindowLive: live, isWindowKey: key)
    }

    func test_keyWindowEvent_deliveredOnlyToKeyWindow() {
        let n = note(.keyWindow)
        XCTAssertTrue(MaughamEvent.shouldDeliver(n, to: ctx(.keyWindow, key: true)))
        XCTAssertFalse(MaughamEvent.shouldDeliver(n, to: ctx(.keyWindow, key: false)),
            "a non-key window must not receive a key-window command (the toggleInspector bug class)")
    }

    /// The toggleInspector regression shape: one event, two windows, exactly
    /// one delivery (ProjectWindow.swift:185 had NO guard — ⌘⌥I toggled BOTH).
    func test_toggleInspector_regression_singleWindowDelivery() {
        var deliveries = 0
        let keyCtx = ctx(.keyWindow, key: true)
        let backgroundCtx = ctx(.keyWindow, key: false)
        let obs = NotificationCenter.default.addObserver(
            forName: .maughamToggleInspector, object: nil, queue: nil) { n in
            if MaughamEvent.shouldDeliver(n, to: keyCtx) { deliveries += 1 }
            if MaughamEvent.shouldDeliver(n, to: backgroundCtx) { deliveries += 1 }
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        MaughamEvent.post(.maughamToggleInspector, to: .keyWindow)
        XCTAssertEqual(deliveries, 1, "⌘⌥I must toggle exactly ONE window's inspector")
    }

    // MARK: - shouldDeliver: document / project classes

    func test_documentEvent_deliveredOnlyToMatchingDocId() {
        let n = note(.document(docId: "doc-abc"))
        XCTAssertTrue(MaughamEvent.shouldDeliver(n, to: ctx(.document(docId: "doc-abc"))))
        XCTAssertFalse(MaughamEvent.shouldDeliver(n, to: ctx(.document(docId: "doc-xyz"))))
    }

    func test_projectEvent_deliveredOnlyToMatchingProjectId() {
        let n = note(.project(id: "proj_A"))
        XCTAssertTrue(MaughamEvent.shouldDeliver(n, to: ctx(.project(id: "proj_A"))))
        XCTAssertFalse(MaughamEvent.shouldDeliver(n, to: ctx(.project(id: "proj_B"))),
            "the script.did.update cross-window defect: a foreign project's event must be dropped")
    }

    // MARK: - shouldDeliver: liveness (closed windows receive NOTHING)

    func test_closedWindow_receivesNoDocumentOrProjectEvents() {
        XCTAssertFalse(MaughamEvent.shouldDeliver(
            note(.document(docId: "doc-abc")),
            to: ctx(.document(docId: "doc-abc"), live: false)),
            "a zombie receiver for the RIGHT doc must still be dropped when its window is closed")
        XCTAssertFalse(MaughamEvent.shouldDeliver(
            note(.project(id: "proj_A")),
            to: ctx(.project(id: "proj_A"), live: false)))
        XCTAssertFalse(MaughamEvent.shouldDeliver(
            note(.keyWindow), to: ctx(.keyWindow, live: false, key: false)))
    }

    func test_globalEvent_deliveredEvenWithoutLiveWindow() {
        // Deliberate: .onGlobalEvent has NO liveness guard (appWillTerminate
        // must reach everything). Per-name zombie-harm audit is in the docs.
        XCTAssertTrue(MaughamEvent.shouldDeliver(
            note(.allWindows), to: ctx(.global, live: false)))
    }

    // MARK: - shouldDeliver: scope-kind mismatch + unscoped posts

    func test_unscopedRawPost_isDropped() {
        var captured: Notification?
        let obs = NotificationCenter.default.addObserver(
            forName: testName, object: nil, queue: nil) { captured = $0 }
        defer { NotificationCenter.default.removeObserver(obs) }
        // adr-0021-ok: deliberately-raw post proving the helper drops legacy/unscoped traffic
        NotificationCenter.default.post(name: testName, object: nil)
        XCTAssertFalse(MaughamEvent.shouldDeliver(captured!, to: ctx(.keyWindow, key: true)),
            "an unscoped post must never be delivered through a scoped helper")
        XCTAssertFalse(MaughamEvent.shouldDeliver(captured!, to: ctx(.global)))
    }

    func test_scopeKindMismatch_isDropped() {
        // Posted .project but subscribed via the key-window helper: wiring bug, drop.
        let n = note(.project(id: "proj_A"))
        XCTAssertFalse(MaughamEvent.shouldDeliver(n, to: ctx(.keyWindow, key: true)))
    }

    func test_payloadMustNotShadowReservedKeys() {
        // Reserved keys are the wrapper's channel; a payload collision is a
        // programmer error. Verify post keeps the SCOPE's value.
        let n = capturePost(.project(id: "real"),
                            payload: ["unrelated": "fine"])
        XCTAssertEqual(n.userInfo?[MaughamEvent.scopeIdKey] as? String, "real")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MaughamEventTests`
Expected: BUILD FAILURE — `cannot find 'MaughamEvent' in scope` (the file doesn't exist yet). That's the failing state for a new-type task.

- [ ] **Step 3: Write the implementation**

```swift
// Maugham/Events/MaughamEvent.swift
import AppKit
import Foundation

/// Delivery scope for an internal `maugham.*` event, declared at the POST
/// site (ADR 0021). There is no unscoped post: NotificationCenter's
/// broadcast-by-default made the wrong thing frictionless and shipped the
/// same cross-window defect 3+ times (rewind retrofit, script.did.update,
/// toggleInspector). The scope kinds:
///
/// - `.keyWindow` — menu-command class; only the key window acts.
/// - `.document(docId:)` — data event for windows presenting this document.
/// - `.project(id:)` — data event for windows on this project. `id` is
///   `ProjectIdentifier.id(for:)`, NOT a raw URL (symlink-stable; matches the
///   pre-existing scriptDidUpdate / mcpNoteAdded idiom).
/// - `.allWindows` — genuinely global fan-out (app lifecycle, welcome window).
enum EventScope: Equatable {
    case keyWindow
    case document(docId: String)
    case project(id: String)
    case allWindows

    static func project(for url: URL) -> EventScope {
        .project(id: ProjectIdentifier.id(for: url))
    }

    var kindString: String {
        switch self {
        case .keyWindow: return "key-window"
        case .document: return "document"
        case .project: return "project"
        case .allWindows: return "all-windows"
        }
    }

    var idString: String? {
        switch self {
        case .document(let docId): return docId
        case .project(let id): return id
        case .keyWindow, .allWindows: return nil
        }
    }
}

/// The typed post/receive layer over NotificationCenter (ADR 0021). Underneath
/// it is plain NC — same delivery timing, `object:` passthrough — with the
/// scope riding `userInfo` under reserved keys. All `maugham.*` posts and
/// subscriptions go through here; TripwireGrepTests enforces it.
enum MaughamEvent {

    /// Reserved userInfo keys carrying the scope. Payload keys must not
    /// collide with these.
    static let scopeKindKey = "maugham.scope.kind"
    static let scopeIdKey = "maugham.scope.id"

    /// Post `name` to the given scope. `object` and `payload` pass through to
    /// NotificationCenter unchanged (payload keys must not shadow the
    /// reserved scope keys).
    static func post(
        _ name: Notification.Name,
        to scope: EventScope,
        object: Any? = nil,
        payload: [AnyHashable: Any] = [:]
    ) {
        assert(payload[scopeKindKey] == nil && payload[scopeIdKey] == nil,
               "payload must not shadow the reserved maugham.scope.* keys")
        var userInfo = payload
        userInfo[scopeKindKey] = scope.kindString
        if let id = scope.idString {
            userInfo[scopeIdKey] = id
        }
        // adr-0021-ok: the wrapper itself — the ONE sanctioned raw post site
        NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
    }

    /// Window liveness. A closed window is neither visible nor miniaturized;
    /// a miniaturized (Dock) window is still open and must keep receiving its
    /// data events. NOTE: `WindowAccessor` caches the NSWindow and never
    /// re-nils it, so `window == nil` is NOT a close check — this predicate
    /// is the liveness guard the ADR 0021 addendum requires (SwiftUI scene
    /// storage retains closed-window view graphs; a zombie receiver otherwise
    /// matches its own project's events and does real work).
    @MainActor
    static func isLive(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    /// THE scope filter — the single implementation of every drop rule.
    /// Receive helpers (View modifiers + `observe`) all funnel through here;
    /// receiver bodies never re-implement a guard.
    ///
    /// Drop rules:
    /// - unscoped note (no scope kind): dropped. Legacy/raw posts don't reach
    ///   scoped receivers; the tripwire (Task 9) makes such posts unwritable.
    /// - scope-kind mismatch (posted `.project`, subscribed `.onKeyWindowCommand`):
    ///   dropped — a wiring bug, not a delivery.
    /// - `.keyWindow`: delivered iff the receiver's window is key (key ⇒ live,
    ///   so the key check subsumes the liveness guard).
    /// - `.document`/`.project`: delivered iff the scope id matches AND the
    ///   receiver's window is live (closed windows receive NOTHING).
    /// - `.allWindows`: delivered unconditionally — deliberately NO liveness
    ///   guard (`appWillTerminate` must reach everything, including view
    ///   graphs SwiftUI has already detached). Each global name carries a
    ///   zombie-harm audit note in MaughamNotifications.swift.
    static func shouldDeliver(_ note: Notification, to context: EventReceiverContext) -> Bool {
        let kind = note.userInfo?[scopeKindKey] as? String
        let scopeId = note.userInfo?[scopeIdKey] as? String
        switch context.kind {
        case .keyWindow:
            guard kind == "key-window" else { return false }
            return context.isWindowKey
        case .document(let docId):
            guard kind == "document" else { return false }
            return context.isWindowLive && scopeId == docId
        case .project(let id):
            guard kind == "project" else { return false }
            return context.isWindowLive && scopeId == id
        case .global:
            return kind == "all-windows"
        }
    }
}

/// The receiver's side of the contract: what it subscribes as, plus the
/// window facts the filter needs. A plain value so `shouldDeliver` is
/// unit-testable without real windows; production receivers build it from
/// their hosting NSWindow via `forWindow`.
struct EventReceiverContext {
    enum Kind: Equatable {
        case keyWindow
        case document(docId: String)
        case project(id: String)
        case global
    }
    let kind: Kind
    let isWindowLive: Bool
    let isWindowKey: Bool

    @MainActor
    static func forWindow(_ window: NSWindow?, kind: Kind) -> EventReceiverContext {
        EventReceiverContext(
            kind: kind,
            isWindowLive: MaughamEvent.isLive(window),
            isWindowKey: window?.isKeyWindow == true)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MaughamEventTests`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Events/MaughamEvent.swift MaughamTests/Events/MaughamEventTests.swift
git commit -m "feat(events): MaughamEvent typed scoped-post wrapper + shouldDeliver filter (ADR 0021)"
```

---

### Task 2: Receive helpers — View modifiers + non-View `observe`, with real-window liveness tests

**Files:**
- Create: `Maugham/Events/MaughamEvent+Receive.swift`
- Create: `MaughamTests/Events/MaughamEventLivenessTests.swift`

**Interfaces:**
- Consumes: `MaughamEvent.shouldDeliver`, `EventReceiverContext.forWindow` (Task 1).
- Produces (all later migration tasks call exactly these):
```swift
extension View {
    func onKeyWindowCommand(_ name: Notification.Name, window: NSWindow?,
                            perform action: @escaping (Notification) -> Void) -> some View
    func onDocumentEvent(_ name: Notification.Name, docId: String, window: NSWindow?,
                         perform action: @escaping (Notification) -> Void) -> some View
    func onProjectEvent(_ name: Notification.Name, url: URL, window: NSWindow?,
                        perform action: @escaping (Notification) -> Void) -> some View
    func onGlobalEvent(_ name: Notification.Name,
                       perform action: @escaping (Notification) -> Void) -> some View
}
extension MaughamEvent {
    @MainActor
    static func observe(_ name: Notification.Name,
                        context: @escaping @MainActor () -> EventReceiverContext?,
                        handler: @escaping @MainActor (Notification) -> Void) -> NSObjectProtocol
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/Events/MaughamEventLivenessTests.swift
import XCTest
import AppKit
@testable import Maugham

/// ADR 0021 addendum: "a closed window receives nothing." These tests use
/// REAL NSWindows — open, close, assert the liveness predicate and the
/// non-View observe helper drop deliveries after close. (Key-window STATUS is
/// not reliably grantable in a headless test host, so key-semantics are pinned
/// at the filter level in MaughamEventTests; liveness IS pinnable with real
/// windows and is pinned here.)
@MainActor
final class MaughamEventLivenessTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.orderFront(nil)
        return w
    }

    func test_isLive_openWindow_true_closedWindow_false() {
        let w = makeWindow()
        XCTAssertTrue(MaughamEvent.isLive(w))
        w.close()
        XCTAssertFalse(MaughamEvent.isLive(w),
            "after close() the cached NSWindow reference must read as NOT live")
        XCTAssertFalse(MaughamEvent.isLive(nil))
    }

    func test_isLive_miniaturizedWindowStillLive() {
        // A Dock-miniaturized window is still open — its data events must
        // keep flowing. Build the predicate's input directly: close() makes
        // isVisible false; we assert the predicate's OR arm via a real window
        // where available. Headless miniaturize is unreliable, so pin the
        // predicate contract: isVisible==false && isMiniaturized==false → dead.
        let w = makeWindow()
        w.close()
        XCTAssertFalse(w.isVisible)
        XCTAssertFalse(w.isMiniaturized)
        XCTAssertFalse(MaughamEvent.isLive(w))
    }

    // MARK: - observe(): the non-View helper's liveness contract

    private let testName = Notification.Name("maugham.test.liveness")

    func test_observe_deliversToLiveProjectContext_dropsAfterClose() {
        let w = makeWindow()
        var workCounter = 0
        let token = MaughamEvent.observe(
            testName,
            context: { .forWindow(w, kind: .project(id: "proj_A")) },
            handler: { _ in workCounter += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(testName, to: .project(id: "proj_A"))
        XCTAssertEqual(workCounter, 1, "live window, matching project → delivered")

        w.close()
        MaughamEvent.post(testName, to: .project(id: "proj_A"))
        XCTAssertEqual(workCounter, 1,
            "closed window must receive NOTHING — even for its own project's events")
    }

    func test_observe_nilContext_meansNotLive_dropsDelivery() {
        // The explicit non-View liveness contract: the owner returns nil when
        // detached (EditorCoordinator past detach()). nil → drop.
        var isDetached = false
        var workCounter = 0
        let token = MaughamEvent.observe(
            testName,
            context: {
                isDetached ? nil : EventReceiverContext(
                    kind: .global, isWindowLive: true, isWindowKey: false)
            },
            handler: { _ in workCounter += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(testName, to: .allWindows)
        XCTAssertEqual(workCounter, 1)
        isDetached = true
        MaughamEvent.post(testName, to: .allWindows)
        XCTAssertEqual(workCounter, 1, "a detached owner must not act on deliveries")
    }

    func test_observe_documentScope_matchAndMismatch() {
        let w = makeWindow()
        defer { w.close() }
        var delivered = 0
        let token = MaughamEvent.observe(
            testName,
            context: { .forWindow(w, kind: .document(docId: "doc-abc")) },
            handler: { _ in delivered += 1 })
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.post(testName, to: .document(docId: "doc-abc"))
        MaughamEvent.post(testName, to: .document(docId: "doc-OTHER"))
        XCTAssertEqual(delivered, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MaughamEventLivenessTests`
Expected: BUILD FAILURE — `MaughamEvent.observe` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Maugham/Events/MaughamEvent+Receive.swift
import SwiftUI
import AppKit

/// Receive-side helpers (ADR 0021). Every `maugham.*` subscription goes
/// through one of these — the scope filter and the closed-window liveness
/// guard live in `MaughamEvent.shouldDeliver`, written exactly once. Receiver
/// bodies contain action logic only; hand-written `isKeyWindow` /
/// userInfo-comparison guards are deleted by the migration.
///
/// `window` is the receiving view's hosting NSWindow (the `WindowAccessor`
/// idiom — `ProjectWindow` already resolves it; panes that need one add
/// `@State private var window: NSWindow?` + `.background(WindowAccessor(window: $window))`).
extension View {

    /// Menu-command class: delivered only when this view's window is key.
    /// Key status implies liveness, so this also excludes closed windows.
    func onKeyWindowCommand(
        _ name: Notification.Name,
        window: NSWindow?,
        perform action: @escaping (Notification) -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { note in
            guard MaughamEvent.shouldDeliver(
                note, to: .forWindow(window, kind: .keyWindow)) else { return }
            action(note)
        }
    }

    /// Data event for windows presenting `docId`. Also drops delivery when
    /// this view's window is closed (liveness guard).
    func onDocumentEvent(
        _ name: Notification.Name,
        docId: String,
        window: NSWindow?,
        perform action: @escaping (Notification) -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { note in
            guard MaughamEvent.shouldDeliver(
                note, to: .forWindow(window, kind: .document(docId: docId))) else { return }
            action(note)
        }
    }

    /// Data event for windows on this project. Also drops delivery when this
    /// view's window is closed (liveness guard).
    func onProjectEvent(
        _ name: Notification.Name,
        url: URL,
        window: NSWindow?,
        perform action: @escaping (Notification) -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { note in
            guard MaughamEvent.shouldDeliver(
                note,
                to: .forWindow(window, kind: .project(id: ProjectIdentifier.id(for: url)))
            ) else { return }
            action(note)
        }
    }

    /// Global fan-out. Passthrough by design — NO liveness guard
    /// (`appWillTerminate` must reach everything); exists so the tripwire's
    /// "every receiver goes through a helper" rule has no exceptions. Each
    /// global name's zombie-harm audit note lives in MaughamNotifications.swift.
    func onGlobalEvent(
        _ name: Notification.Name,
        perform action: @escaping (Notification) -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { note in
            guard MaughamEvent.shouldDeliver(
                note,
                to: EventReceiverContext(kind: .global, isWindowLive: true, isWindowKey: false)
            ) else { return }
            action(note)
        }
    }
}

extension MaughamEvent {
    /// Non-View subscription (AppKit coordinators, workers). `context` is
    /// evaluated at EACH delivery on the main actor; return `nil` when the
    /// owner is no longer live — a `nil` context drops the delivery. This is
    /// the explicit liveness contract the spec requires: an
    /// `EditorCoordinator` past `detach()` must not act on deliveries, so its
    /// context closure returns nil once `isDetached` (and `detach()` also
    /// removes the token). Remove the returned token in detach()/deinit via
    /// `NotificationCenter.default.removeObserver(token)`.
    @MainActor
    static func observe(
        _ name: Notification.Name,
        context: @escaping @MainActor () -> EventReceiverContext?,
        handler: @escaping @MainActor (Notification) -> Void
    ) -> NSObjectProtocol {
        // adr-0021-ok: the wrapper itself — the ONE sanctioned raw subscription site
        NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { note in
            // NC posts these on .main (queue: .main), so we're on the main
            // thread; assumeIsolated bridges without a Task hop and asserts
            // in debug if that ever stops holding (the EditorCoordinator idiom).
            MainActor.assumeIsolated {
                guard let ctx = context(),
                      MaughamEvent.shouldDeliver(note, to: ctx) else { return }
                handler(note)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MaughamEventLivenessTests -only-testing:MaughamTests/MaughamEventTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Events/MaughamEvent+Receive.swift MaughamTests/Events/MaughamEventLivenessTests.swift
git commit -m "feat(events): receive helpers — View modifiers + non-View observe with liveness contract (ADR 0021)"
```

---

### Task 3: Migrate the `.keyWindow` class — View side (22 names)

The mechanical sweep. Post sites move to `MaughamEvent.post(name, to: .keyWindow, payload: …)`; receivers move to `.onKeyWindowCommand(name, window: window)`; **every hand-written `guard window?.isKeyWindow == true` in a migrated receiver is DELETED** (the helper owns it now). Receivers that had NO guard (the live bug class: `toggleInspector`, `toggleFullScreen`, `dummySave`, `showProjectSettings`, `showClaudeDesktopHelp`, `showSyntaxHelp`, `toggleResearchPreview`, `findInProject`, `setDetailSegment`, `closeFind`, `toggleNoChrome`) get the correct behavior for the first time.

The five names with EditorCoordinator (non-View) receivers — `navigateToScene`, `findMatchSelected`, `navigateToParagraph`, `navigateToAnnotation`, `toggleReviewMode` — migrate in Task 4 (per-name atomicity: their posts AND all their receivers move together there; do NOT touch them in this task).

**Files:**
- Modify: `Maugham/MaughamApp.swift` (menu posts: lines ~112–255, ~418, ~381)
- Modify: `Maugham/Views/ProjectWindow.swift` (receivers in body + `SessionAndNavigationModifier` + `CollectionPieceModifier` + `CheckpointModifier` + `FocusPostureModifier`)
- Modify: `Maugham/Views/CollectionPiecesPane.swift` (posts :55, :101, :105, :109), `Maugham/Views/BinderPaneToggle.swift` (no — that's navigateToScene, Task 4), `Maugham/Views/ProjectSearchView.swift` (:56 closeFind post only — :155 findMatchSelected is Task 4)
- Test: existing suites must stay green; the class's delivery semantics are already pinned by `MaughamEventTests` (Task 1). Add nothing new here except keeping `test_toggleInspector_regression_singleWindowDelivery` green.

**Interfaces:** Consumes Task 1 `MaughamEvent.post` + Task 2 `.onKeyWindowCommand` exactly as declared.

**Per-name site table (post ⇒ receivers). Migrate ONE NAME PER COMMIT** (`refactor(events): migrate <name> to .keyWindow scope`):

| # | Name | Post site(s) | Receiver(s) | Guard to DELETE |
|---|------|--------------|-------------|-----------------|
| 1 | maughamToggleInspector | MaughamApp:193 | ProjectWindow:185 | none existed — **bug fixed here** |
| 2 | maughamToggleFullScreen | MaughamApp:188 | ProjectWindow:163 | none existed |
| 3 | maughamDummySave | MaughamApp:124 | ProjectWindow:166 | none existed |
| 4 | maughamShowProjectSettings | MaughamApp:167 | ProjectWindow:172 | none existed |
| 5 | maughamShowClaudeDesktopHelp | MaughamApp:423 | ProjectWindow:175 | none existed |
| 6 | maughamShareForReview | MaughamApp:381 | ProjectWindow:178 | DELETE `guard window?.isKeyWindow == true` (`let store` check stays) |
| 7 | maughamTidyAllFilenames | MaughamApp:139 | ProjectWindow:375 | DELETE key guard |
| 8 | maughamShowProjectStatistics | MaughamApp:148 | ProjectWindow:195 | DELETE key guard |
| 9 | maughamAddResearchFile | MaughamApp:143 | ProjectWindow:394 | DELETE key guard |
| 10 | maughamShowSyntaxHelp | MaughamApp:418 | ProjectWindow:413 | none existed |
| 11 | maughamRestoreLastDeleted | MaughamApp:254 | ProjectWindow:416 | DELETE key guard |
| 12 | maughamToggleResearchPreview | MaughamApp:198 | ProjectWindow:423 | none existed |
| 13 | maughamFindInProject | MaughamApp:248 | ProjectWindow:430 | none existed |
| 14 | maughamSetDetailSegment | MaughamApp:204/211/218/225 (payload `["segment": …]`) | ProjectWindow:368 | none existed |
| 15 | maughamCloseFind | ProjectSearchView:56 | ProjectWindow:434 | none existed |
| 16 | maughamToggleNoChrome | MaughamApp:178 | ProjectWindow:1219 (FocusPostureModifier) | none existed |
| 17 | maughamSaveCheckpoint | MaughamApp:126 | ProjectWindow:1075 (CheckpointModifier) | DELETE key guard (store/documentStore checks stay) |
| 18 | maughamNamedCheckpoint | MaughamApp:131 | ProjectWindow:1104 | DELETE key guard (`store != nil` stays) |
| 19 | maughamAddLoosePiece | MaughamApp:153; ProjectWindow:604 (empty-state button); CollectionPiecesPane:101 | ProjectWindow:507 (CollectionPieceModifier) | DELETE key guard (`type == .collection` stays) |
| 20 | maughamAddScreenplayPiece | MaughamApp:157; CollectionPiecesPane:105 | ProjectWindow:520 | DELETE key guard (type check stays) |
| 21 | maughamLinkProject | MaughamApp:161; CollectionPiecesPane:109 | ProjectWindow:533 | DELETE key guard (type check stays) |
| 22 | maughamPromotePiece | CollectionPiecesPane:55 (payload `["piece_id": …]`) | ProjectWindow:550 | none existed (piece-membership + type checks STAY — they are action logic, not scope) |

(Line numbers are the 2026-07-02 survey; re-locate by name if drifted.)

**The exact transformation, worked for the bug name (#1). Every other row is the same two-sided rewrite:**

Post side, `MaughamApp.swift`:
```swift
// BEFORE
Button("Toggle Inspector") {
    NotificationCenter.default.post(
        name: .maughamToggleInspector, object: nil)
}
// AFTER
Button("Toggle Inspector") {
    MaughamEvent.post(.maughamToggleInspector, to: .keyWindow)
}
```

Receive side, `ProjectWindow.swift`:
```swift
// BEFORE
.onReceive(NotificationCenter.default.publisher(for: .maughamToggleInspector)) { _ in
    showInspector.toggle()
}
// AFTER
.onKeyWindowCommand(.maughamToggleInspector, window: window) { _ in
    showInspector.toggle()
}
```

Worked example for a guard-deleting row (#17, `saveCheckpoint` in `CheckpointModifier`):
```swift
// BEFORE
.onReceive(NotificationCenter.default.publisher(
    for: .maughamSaveCheckpoint)) { _ in
    guard window?.isKeyWindow == true,
          let store, let documentStore else { return }
    …body unchanged…
}
// AFTER — key guard deleted (helper owns it); non-scope preconditions stay
.onKeyWindowCommand(.maughamSaveCheckpoint, window: window) { _ in
    guard let store, let documentStore else { return }
    …body unchanged…
}
```

Worked example for a payload-carrying row (#14, `setDetailSegment`):
```swift
// Post (×4 in MaughamApp, one per segment):
MaughamEvent.post(.maughamSetDetailSegment, to: .keyWindow,
                  payload: ["segment": "inspector"])
// Receive (SessionAndNavigationModifier):
.onKeyWindowCommand(.maughamSetDetailSegment, window: window) { note in
    guard let raw = note.userInfo?["segment"] as? String,
          let seg = DetailSegment(rawValue: raw) else { return }
    showInspector = true
    detailSegment = seg
}
```

Also update the stale receiver comments that describe the old convention (e.g. `CollectionPieceModifier`'s "posted with `object: nil` … We act only when this window is key" → "Key-window command (ADR 0021): the helper scopes delivery; the type/membership checks below are action preconditions, not scope guards"). `SessionAndNavigationModifier`, `CheckpointModifier`, `CollectionPieceModifier`, `FocusPostureModifier` and `ParagraphNavModifier` keep their `window: NSWindow?` property — the helpers need it.

- [ ] **Step 1: Migrate name #1 (`toggleInspector`) exactly as shown above**
- [ ] **Step 2: Build + run the Task 1/2 test classes and `xcodebuild … test` for the full Mac suite once**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS (no regressions; no test observes these menu commands raw today).

- [ ] **Step 3: Commit** — `git commit -am "fix(events): toggleInspector scoped to key window — fixes double-window ⌘⌥I toggle (ADR 0021)"`
- [ ] **Step 4: Migrate names #2–#22, one commit each, same recipe**

For each: rewrite post side(s), rewrite receiver to `.onKeyWindowCommand`, delete the hand-written key guard if present, keep non-scope preconditions, update the receiver's convention comment. Build (`xcodebuild … build`) per name; full test run after every 5 names and at the end.

- [ ] **Step 5: Verify all hand-written key-window guards in migrated receivers are gone**

Run: `grep -n "isKeyWindow" Maugham/Views/ProjectWindow.swift`
Expected: zero hits in migrated `.onKeyWindowCommand` closures (hits may remain only in Task 4/5 names not yet migrated — after Task 5, ProjectWindow must have NO `isKeyWindow` at all).

- [ ] **Step 6: Full Mac suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

---

### Task 4: Migrate the `.keyWindow` class — names with EditorCoordinator (non-View) receivers (5 names)

These five names have an AppKit-side receiver in `EditorCoordinator.init` (tokens: `navigateObserver` :395, `findMatchObserver` :407, `paragraphNavigateObserver` :428, `annotationNavigateObserver` :457, `reviewToggleObserver` :471); three also have a ProjectWindow View receiver. All receivers per name move in the name's own commit.

This task also fixes three MORE live instances of the defect class: `navigateToScene` (:395), `findMatchSelected` (:407), and `navigateToParagraph` (:428) have NO key-window guard in the coordinator — every open window's editor moves its cursor/selection on another window's scene click, find click, or history/annotation/task jump.

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift` (5 observers + `detach()`)
- Modify: `Maugham/Views/BinderPaneToggle.swift` (:45 navigateToScene post), `Maugham/Views/ProjectSearchView.swift` (:155 findMatchSelected post), `Maugham/Views/HistoryPane.swift` (:280 navigateToParagraph post), `Maugham/Views/AnnotationsPane.swift` (:308 navigateToAnnotation, :311 navigateToParagraph posts), `Maugham/Views/TasksPane.swift` (:426 navigateToParagraph post — drop its `object: projectURL`, keep `doc_id`/`paragraph_id` in payload), `Maugham/MaughamApp.swift` (:183 toggleReviewMode post)
- Modify: `Maugham/Views/ProjectWindow.swift` (View receivers: findMatchSelected :439, navigateToParagraph :1248 in ParagraphNavModifier, toggleReviewMode :1224 in FocusPostureModifier)
- Modify: `MaughamTests/Editor/EditorCoordinatorCycleTests.swift` (:90 raw post → `MaughamEvent.post(.maughamNavigateToScene, to: .keyWindow, payload: …)`; the coordinator under test has no window, so if the assertion relied on delivery, give the test's text view a real ordered-front window — the Task 2 `makeWindow()` recipe — and mark the expectation accordingly)
- Test: add zombie-coordinator + scoping tests to `MaughamTests/Events/MaughamEventLivenessTests.swift`

**Interfaces:** Consumes `MaughamEvent.observe(_:context:handler:)` (Task 2). Adds to `EditorCoordinator`:
```swift
/// nil once detached or before attach — the observe() liveness contract.
private func receiverContext(_ kind: EventReceiverContext.Kind) -> EventReceiverContext?
```

- [ ] **Step 1: Write the failing test**

```swift
// Append to MaughamTests/Events/MaughamEventLivenessTests.swift

    /// ADR 0021: a detached (zombie) EditorCoordinator must not act on
    /// scoped events — the work counter must not move after detach().
    func test_detachedCoordinator_receivesNoNavigateToScene() {
        let storage = NSTextStorage(string: "INT. ROOM - DAY\n\nAction.\n")
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 600))
        layout.addTextContainer(container)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                            textContainer: container)
        let w = makeWindow()
        w.contentView = tv
        w.makeFirstResponder(tv)
        let binding: Binding<String> = .init(get: { tv.string }, set: { tv.string = $0 })
        let coordinator = EditorCoordinator(
            text: binding, mode: ScreenplayMode(),
            theme: .light, typography: .screenplayDefaults,
            typewriterScroll: false, sentenceFocus: false, paragraphFocus: false)
        coordinator.attach(to: tv)

        coordinator.detach()
        let before = tv.selectedRange()
        MaughamEvent.post(.maughamNavigateToScene, to: .keyWindow,
                          payload: ["lineLocation": 17])
        XCTAssertEqual(tv.selectedRange(), before,
            "a detached coordinator's editor must not move on a scoped navigate event")
        w.close()
    }
```

(Adjust the construction boilerplate to whatever `EditorCoordinatorCycleTests` already uses — reuse its factory if one exists rather than duplicating.)

- [ ] **Step 2: Run it — expected FAIL** (raw receiver currently fires whenever textView survives; after detach textView is nil so this may already pass — if it passes pre-change, strengthen it: assert via a counter on a NOT-detached coordinator whose window is closed, which today DOES move (the zombie bug), and goes quiet after migration):

```swift
    func test_closedWindowCoordinator_receivesNothing() {
        // Not detached (SwiftUI didn't dismantle), window closed: the ADR 0021
        // addendum zombie. Pre-migration this receiver fires; post-migration
        // the key-window context of a closed window drops it.
        …same setup…
        coordinator.attach(to: tv)
        w.close()                          // zombie: attached, window dead
        let before = tv.selectedRange()
        MaughamEvent.post(.maughamNavigateToScene, to: .keyWindow,
                          payload: ["lineLocation": 17])
        XCTAssertEqual(tv.selectedRange(), before)
    }
```

Run: `xcodebuild … -only-testing:MaughamTests/MaughamEventLivenessTests`
Expected: `test_closedWindowCoordinator_receivesNothing` FAILS pre-migration (selection moved) — proving the zombie defect — and the detached test may pass. Keep both.

- [ ] **Step 3: Migrate the coordinator's five observers**

In `EditorCoordinator`:

```swift
private func receiverContext(_ kind: EventReceiverContext.Kind) -> EventReceiverContext? {
    guard !isDetached, let tv = textView else { return nil }
    return .forWindow(tv.window, kind: kind)
}
```

Each observer, same shape (worked for navigateToScene — apply to all five; the hand-written `textView.window?.isKeyWindow == true` guards in annotationNavigateObserver and reviewToggleObserver are DELETED, the helper owns them now):

```swift
// BEFORE
navigateObserver = NotificationCenter.default.addObserver(
    forName: .maughamNavigateToScene, object: nil, queue: .main
) { [weak self] note in
    MainActor.assumeIsolated {
        guard let self,
              let location = note.userInfo?["lineLocation"] as? Int,
              let textView = self.textView else { return }
        self.navigateToLine(at: location, in: textView)
    }
}
// AFTER
navigateObserver = MaughamEvent.observe(
    .maughamNavigateToScene,
    context: { [weak self] in self?.receiverContext(.keyWindow) }
) { [weak self] note in
    guard let self,
          let location = note.userInfo?["lineLocation"] as? Int,
          let textView = self.textView else { return }
    self.navigateToLine(at: location, in: textView)
}
```

`findMatchObserver` keeps its 50ms defer Task; `paragraphNavigateObserver` keeps its cursor-positioning body; `annotationNavigateObserver` and `reviewToggleObserver` lose their inline `isKeyWindow` guards (comment updated: the synchronous-membrane-flip note for reviewToggle stays — it explains WHY an NC receiver exists at all, per Editor AREA.md Bug B).

In `detach()`, add token removal (the explicit liveness contract; deinit removal stays as belt):
```swift
for token in [navigateObserver, findMatchObserver, paragraphNavigateObserver,
              annotationNavigateObserver, reviewToggleObserver] {
    if let token { NotificationCenter.default.removeObserver(token) }
}
navigateObserver = nil; findMatchObserver = nil; paragraphNavigateObserver = nil
annotationNavigateObserver = nil; reviewToggleObserver = nil
```

- [ ] **Step 4: Migrate the five names' posts and View receivers (one commit per name)**

Posts (recipe as Task 3):
- `BinderPaneToggle:45` → `MaughamEvent.post(.maughamNavigateToScene, to: .keyWindow, payload: ["lineLocation": location])`
- `ProjectSearchView:155` → `MaughamEvent.post(.maughamFindMatchSelected, to: .keyWindow, payload: ["match": match])`
- `HistoryPane:280`, `AnnotationsPane:311` → `MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow, payload: ["paragraph_id": pid])`
- `TasksPane:426` → same, but DROP `object: projectURL` and keep `["doc_id": …, "paragraph_id": …]` payload (object-scoping is dead; both receivers ignored it — inventory finding 4)
- `AnnotationsPane:308` → `MaughamEvent.post(.maughamNavigateToAnnotation, to: .keyWindow, payload: info)` (annotation_id + optional paragraph_id)
- `MaughamApp:183` → `MaughamEvent.post(.maughamToggleReviewMode, to: .keyWindow)`

View receivers:
- `ProjectWindow:439` findMatchSelected → `.onKeyWindowCommand(.maughamFindMatchSelected, window: window) { note in … }` (store/match preconditions stay)
- `ProjectWindow:1248` (ParagraphNavModifier) → `.onKeyWindowCommand(.maughamNavigateToParagraph, window: window) { … }`, DELETE its key guard
- `ProjectWindow:1224` (FocusPostureModifier) → `.onKeyWindowCommand(.maughamToggleReviewMode, window: window) { … }`, DELETE its key guard

- [ ] **Step 5: Run the full Mac suite; expected PASS including the new zombie tests**
- [ ] **Step 6: Commit** (final commit of the task): `git commit -am "refactor(events): coordinator receivers via MaughamEvent.observe — fixes cross-window scene/find/paragraph navigation (ADR 0021)"`

---

### Task 5: Migrate the `.project` data-event class (7 names; absorbs ScriptUpdateRouting)

Per-event receiver reading required — substantive. Each name in its own commit. NOT key-window scoped: a background window's own project events must still reach it (e.g. an MCP-driven re-parse updating a background window's scene navigator).

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift` (scriptDidUpdate posts :1491–1505), `Maugham/Views/ProjectWindow.swift` (scriptDidUpdate :200, sessionLogChanged :380, navigateToDocument :386, mcpNoteAdded :456, openRewind :1141, checkpointAdded post :1187), `Maugham/Views/HistoryPane.swift` (openRewind posts :236/:346; checkpointAdded receiver :203), `Maugham/Stores/DocumentStore.swift` (sessionLogChanged post :376, checkpointAdded post :737), `Maugham/MCP/Tools/AddNoteTool.swift` (:63), `Maugham/Publish/CompileOrchestrator.swift` (:147), `Maugham/Views/Publish/ExportsListView.swift` (:75 receiver), `Maugham/Views/ProjectStatisticsWindow.swift` (:16 post, :37 receiver), `Maugham/Views/InspectorView.swift` (:80), `Maugham/Editor/EditorSurface.swift` (:383)
- Delete: `Maugham/Editor/ScriptUpdateRouting.swift`
- Modify: `MaughamTests/Editor/ScriptUpdateScopingTests.swift` (rewrite against the wrapper), `MaughamTests/RewindEntryPointsTests.swift` (:23/:30/:44/:51 raw posts/observers → wrapper)
- Panes gaining a window for the liveness guard: `HistoryPane`, `ExportsListView`, `ProjectStatisticsWindow` each add `@State private var window: NSWindow?` + `.background(WindowAccessor(window: $window))` (the ProjectWindow idiom).

**Per-name details:**

1. **`scriptDidUpdate`** — the wrapper ABSORBS the tactical v0.12.6 fix.
   - Post (`EditorCoordinator`, both the :1496 immediate and :1505 debounced sites; they share `originInfo` today):
     ```swift
     MaughamEvent.post(.maughamScriptDidUpdate,
                       to: .project(id: scriptOriginProjectId),
                       object: script)
     ```
     Delete the `originInfo` dictionary and the `ScriptUpdateRouting.projectIdKey` stamp.
   - Receive (`ProjectWindow:200`):
     ```swift
     .onProjectEvent(.maughamScriptDidUpdate, url: url, window: window) { note in
         if let script = note.object as? FountainScript {
             self.lastParsedScript = script
         }
     }
     ```
   - Delete `ScriptUpdateRouting.swift`. Rewrite `ScriptUpdateScopingTests` to pin the same three behaviors through the wrapper: foreign-project post not delivered, own-project post delivered, unscoped post not delivered — using `MaughamEvent.shouldDeliver` with `.project` contexts and a real posting coordinator for `test_poster_carriesProjectIdInUserInfo` (assert `userInfo[MaughamEvent.scopeIdKey]` now carries the origin id and `scopeKindKey == "project"`).
   - Keep the guidance comment at the receiver (background window's own MCP re-parse must still land — NOT key-window).

2. **`openRewind`** — semantics preserved, identity comparison upgraded.
   - Posts (`HistoryPane:236` and `:346`): `MaughamEvent.post(.maughamOpenRewind, to: .project(for: projectURL), payload: ["scrub_op_id": …, "scrub_op_at": …])` (payload only on the :346 site; drop `object: projectURL` — scope carries identity now).
   - Receive (`RewindModifier`, ProjectWindow:1141): `.onProjectEvent(.maughamOpenRewind, url: store?.url ?? url, window: window) { note in … }` — delete the `note.object as? URL == store?.url` guard; keep `selectedItemId != nil` and the scrub-cursor decoding. (RewindModifier doesn't hold `window`/`url` today: pass both in from `CheckpointModifier`, which receives them from ProjectWindow.)
   - Update `RewindEntryPointsTests` raw posts to `MaughamEvent.post(…, to: .project(for: projectURL), …)` and observer assertions to read the scope keys.

3. **`mcpNoteAdded`** — post (`AddNoteTool:63`): scope `.project(id: projectId)` (the tool already has `project_id` — move it from payload to scope; keep `research_id`/`title` payload). Receive (ProjectWindow:456): `.onProjectEvent(.maughamMCPNoteAdded, url: url, window: window)` — delete the manual `ProjectIdentifier.id(for: url) == projectId` comparison; keep the banner-bump body (the `DispatchQueue.main.async` hop can stay).

4. **`checkpointAdded`** — posts: `DocumentStore:737` → `.project(for: projectURL)` (DocumentStore knows its project root); `ProjectWindow:1187` (RewindModifier `.snapshotHere`) → `.project(for: store.url)`. Receive (`HistoryPane:203`): `.onProjectEvent(.maughamCheckpointAdded, url: projectURL, window: window)` — HistoryPane gains the WindowAccessor state (above). This FIXES another cross-window leak: today every open window's HistoryPane reloads on any project's checkpoint.

5. **`sessionLogChanged`** — post (`DocumentStore:376`) → `.project(for: projectURL)`. Receivers: ProjectWindow:380 → `.onProjectEvent(…, url: url, window: window)`; ProjectStatisticsWindow:37 → `.onProjectEvent(…, url: projectURL, window: window)` with its new WindowAccessor. (The stats window is its own scene — the liveness guard now also stops a closed stats window's zombie from reloading.)

6. **`publicationCompleted`** — post (`CompileOrchestrator:147`): `.project(for: <projectURL>)` keeping `object: pub.publicationID`; the orchestrator's project root is available at the call site (it just wrote into the project's `Exports/` — if the property is named differently, derive from the store it already holds; verify at implementation). Receive (`ExportsListView:75`): `.onProjectEvent(…, url: projectURL, window: window)` with its new WindowAccessor. Update the :147 comment ("observers filter by project URL if they care" → "scope declared at post; helper filters").
   Also update the declaration comment at `ExportsListView.swift:125`.

7. **`navigateToDocument`** — the scope-classification FIX (spec deviation 1, rationale in the header): posts must carry project identity:
   - `InspectorView:80` → `MaughamEvent.post(.maughamNavigateToDocument, to: .project(for: store.url), payload: ["id": id])`
   - `ProjectStatisticsWindow:16` → same with its `projectURL`. **This un-breaks stats-window navigation** (the old receiver key-guard could never pass while the stats window was key).
   - `EditorSurface:383` (wiki-link click in `MaughamTextView.mouseDown`) → the coordinator holds the project id: reuse `coordinator.scriptOriginProjectId` if it is wired for ALL modes (it is set by EditorSurface from EditorHost); if it turns out screenplay-only at implementation time, wire the same id unconditionally (rename to `originProjectId` if that reads better — one property, no parallel state, tripwire 6).
   - Receive (`ProjectWindow:386`): `.onProjectEvent(.maughamNavigateToDocument, url: url, window: window) { note in … }` — DELETE the key-window guard; keep the `["id"]` decoding + binderSegment/selectedItemId body.
   - Add a test to `MaughamEventTests`: `test_navigateToDocument_projectScoped_deliversToNonKeyProjectWindow` — build a `.project` context with `isWindowKey: false, isWindowLive: true` and assert delivery (this is the exact stats-window shape that was broken).

- [ ] **Step 1: For each name in order 1→7: write/adjust the failing test (per-name notes above), run it, migrate post+receivers, run the full relevant test classes, commit** (`refactor(events): migrate <name> to .project scope (ADR 0021)`; name 1's commit message notes the ScriptUpdateRouting absorption + deletion).
- [ ] **Step 2: After name 7: `grep -rn "isKeyWindow" Maugham/Views/ProjectWindow.swift`** — Expected: ZERO hits (all hand-written guards deleted across Tasks 3–5).
- [ ] **Step 3: `grep -rn "ScriptUpdateRouting" Maugham MaughamTests`** — Expected: zero hits.
- [ ] **Step 4: Full Mac suite — PASS. Commit any stragglers.**

---

### Task 6: Delete the two dead posts (`opLogChanged`, `inboxChanged`)

Both are posted and received NOWHERE (2026-07-02 inventory; `maughamOpLogChanged`'s claimed consumers reload via `checkpointAdded` + onChange instead; `maughamInboxChanged`'s documented consumer is a DIRECT `inboxStore.refresh()` call at `DocumentStore.swift:764`). Dead posts don't migrate — they get deleted; the tripwire (Task 9) prevents un-wrapped resurrection, and a future scoped re-introduction is one `MaughamEvent.post` away.

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift` (:732 opLogChanged post, :760 inboxChanged post — delete the posts, keep the surrounding logic: `handleExternalLogChange` dispatch and `inboxStore.refresh()` + worker poke are the real consumers and stay)
- Modify: `Maugham/Models/MaughamNotifications.swift` (delete both declarations + their doc comments)

- [ ] **Step 1: Re-verify deadness** — Run: `grep -rn "maughamOpLogChanged\|maughamInboxChanged" Maugham MaughamTests Packages MaughamPhone` — Expected: only the declaration lines + the two post sites. If ANY receiver appears (the tree may have moved), STOP: migrate that name as `.document(docId:)` / `.project` respectively instead of deleting, using the Task 5 recipe.
- [ ] **Step 2: Delete the posts and declarations.** In `DocumentStore.swift` case `.opLog(let docId)`: keep the `handleExternalLogChange` dispatch, delete only the `NotificationCenter.default.post` statement. In case `.inbox(let kind, _)`: keep the refresh + worker poke, delete only the post; fold the useful part of the old comment into the remaining code ("a capture or Mac-side status transition landed; refresh is a direct call — deliberately NOT a notification, ADR 0021 Task 6 deleted the dead broadcast").
- [ ] **Step 3: Build + full Mac suite** — Expected: PASS (nothing consumed them).
- [ ] **Step 4: Commit** — `git commit -am "refactor(events): delete dead maughamOpLogChanged/maughamInboxChanged posts (no receivers; ADR 0021 sweep)"`

---

### Task 7: Migrate the `.allWindows` class (5 names) + zombie-harm audit notes

Deliveries unchanged (passthrough) — these migrate for tripwire uniformity. `.onGlobalEvent` has no liveness guard; the spec requires a per-name audit of whether a zombie receiver handling it is harmful, recorded per name.

**Files:**
- Modify: `Maugham/MaughamApp.swift` — posts :112 (newProject), :116/:561 (openProject), :399 (showHelp), :37 (appWillTerminate — inside the `willTerminateNotification` bridge; the bridge's own `addObserver` for the SYSTEM notification stays raw, it is not a `maugham.*` name); receivers :478 (newProject), :481 (openProject), :488 (showHelp), :494 (testOpenProject, `#if MAUGHAM_DEV_BUILD`), :102 (appWillTerminate → MCP stop)
- Modify: `Maugham/Views/ProjectWindow.swift` — :188 appWillTerminate receiver, :1259 showHelp receiver, :567/:746 openProject posts
- Modify: `Maugham/Views/ReferencePieceInspector.swift` :83 (openProject post), `Maugham/MCP/Test/Tools/TestProjectTools.swift` :143 (testOpenProject post)
- Modify: `Maugham/Models/MaughamNotifications.swift` — audit notes (Step 3)

- [ ] **Step 1: Migrate each name (one commit each), recipe:**

```swift
// Post
MaughamEvent.post(.maughamOpenProject, to: .allWindows, payload: ["url": newProjectURL])
// Receive
.onGlobalEvent(.maughamOpenProject) { note in … }
```

`appWillTerminate` post inside the bridge: `MaughamEvent.post(.maughamAppWillTerminate, to: .allWindows)`.

- [ ] **Step 2: Run full Mac suite — PASS**
- [ ] **Step 3: Record the zombie-harm audit as doc comments on each name in `MaughamNotifications.swift`:**

```swift
/// Scope: .allWindows (no liveness guard — must reach everything).
/// Zombie-harm audit (ADR 0021):
/// - maughamAppWillTerminate: a closed window's zombie calls
///   documentStore?.close() — idempotent (already closed by .onDisappear);
///   harmless double-close. OK.
/// - maughamNewProject / maughamOpenProject / maughamTestOpenProject: sole
///   receiver is WelcomeHost; a retained closed-Welcome zombie would call
///   openWindow(id:value:) — idempotent for a WindowGroup value / singleton
///   Window (brings the one window forward). Harmless duplication at worst. OK.
/// - maughamShowHelp: receivers open the singleton "help" Window —
///   idempotent. OK. (Also why this stays .allWindows, not .keyWindow: Help
///   must work when NO project window exists.)
```

(Verify each claim while writing it — e.g. confirm `DocumentStore.close()` is idempotent by reading it; if any claim fails, note the actual behavior and flag it in the task report rather than papering over it.)

- [ ] **Step 4: Commit** — `git commit -am "refactor(events): globals via .allWindows + zombie-harm audit notes (ADR 0021)"`

---

### Task 8: Teardown-discipline audit + per-scope-class closed-window acceptance tests

Two halves. (a) Audit: verify `EditorCoordinator.detach()` (via `EditorSurface.dismantleNSView`) and `DocumentStore` close/presenter-removal (via `ProjectWindow.onDisappear`, `MaughamApp` termination path) actually run on every window-close path; pin what's pinnable headlessly. (b) The acceptance tests: per scope class, closed window ⇒ receiver never fires and no work counter moves (some already exist from Tasks 2/4 — this task completes the set).

**Files:**
- Modify: `MaughamTests/Events/MaughamEventLivenessTests.swift`
- Create: `docs/superpowers/notes/2026-07-02-window-teardown-audit.md`

- [ ] **Step 1: Audit (read-only).** Trace every window-close path for a ProjectWindow: red-button close, ⌘W, app quit (⌘Q — remember quit ≠ close(): `.onDisappear` does NOT run on quit, which is why the `appWillTerminate` flush exists), project window replaced via Recents. For each, record in the note: does `dismantleNSView` → `detach()` run? does `.onDisappear` → `documentStore.close()` + `mcpRegistry.unregister` run? Cite file:line. Sources: `EditorSurface.swift:257–262`, `ProjectWindow.swift:159–162`, `MaughamApp.swift:30–56`, `Maugham/Editor/AREA.md` teardown paragraph, memory note "quit≠close()".
- [ ] **Step 2: Pin what's pinnable.** If not already covered by existing tests (check `EditorCoordinatorCycleTests` and `EditorAppearanceChangeTests` first — do not duplicate): a test that `EditorSurface.dismantleNSView` calls `detach()` (coordinator's `isDetached` flips, `textView` nils), and a test that `detach()` removes the five observer tokens (post a scoped event after detach with a live window attached — handler must not fire; distinct from the context-nil path because token removal is the belt AND braces).
- [ ] **Step 3: Complete the per-scope-class closed-window matrix** in `MaughamEventLivenessTests` — one test per class asserting a work counter stays at 0 after `w.close()`:
  - `.keyWindow`: covered by Task 4's `test_closedWindowCoordinator_receivesNothing` ✓
  - `.project`: covered by Task 2's `test_observe_deliversToLiveProjectContext_dropsAfterClose` ✓ — add the View-helper equivalent if a lightweight harness is feasible; otherwise the filter + observe coverage stands (the View modifier is a 4-line funnel into the same `shouldDeliver`).
  - `.document`: add `test_closedWindow_documentEvent_dropped` — observe with `.document(docId:)` context over a real window, close, post matching docId, counter 0.
  - `.allWindows`: add `test_globalEvent_reachesClosedWindowReceiver_byDesign` — counter 1 after close, with a comment pointing at the Task 7 audit notes (this pins the DELIBERATE exception so a future "helpful" guard addition fails a test and forces a conversation).
- [ ] **Step 4: Run full Mac suite — PASS. Commit** — `git commit -am "test(events): closed-window acceptance matrix + teardown-discipline audit (ADR 0021)"`

---

### Task 9: The tripwire (LAST — CI is green before this lands)

House style: shared pattern constants + planted-offender self-test (mirrors the ADR 0018 guard in `TripwireGrepTests`). Line-based grep is insufficient here — the codebase splits `post(`/`publisher(for:` across lines — so the maugham-event tripwire scans WHOLE-FILE text with regexes, reporting the line of the match start.

**Rules:**
1. `NotificationCenter.default.post(` is forbidden in `Maugham/` and `MaughamTests/` outside `MaughamEvent.swift`, unless the line carries `// adr-0021-ok: <reason>`. (Catches every raw post regardless of name/line-splitting; we post no system notifications, so a raw post is a `maugham.*` post by construction — and if someone someday posts a system notification legitimately, that's what the annotation is for.)
2. `publisher\(\s*for:\s*\.maugham` (regex, whitespace/newline-tolerant) forbidden outside `MaughamEvent+Receive.swift`.
3. `addObserver\(\s*forName:\s*\.maugham` forbidden outside `MaughamEvent+Receive.swift`.

Sanctioned `// adr-0021-ok:` sites after Tasks 1–8 (the authoritative list, verify at implementation):
- `MaughamEvent.swift` post + `MaughamEvent+Receive.swift` addObserver (excluded by file allowlist; annotations there are documentation).
- `MaughamEventTests.swift` — the deliberately-raw unscoped-post test (already annotated in Task 1).

**Files:**
- Modify: `MaughamTests/TripwireGrepTests.swift`

- [ ] **Step 1: Write the tripwire + self-test**

```swift
    // MARK: - ADR 0021: no raw maugham.* posts/subscriptions outside the wrapper

    /// Whole-file regex patterns (the codebase splits post(/publisher( across
    /// lines, so line-based grep misses them). SHARED with the self-test.
    static let adr0021PostPattern = "NotificationCenter\\.default\\.post\\("
    static let adr0021SubscribePatterns = [
        "publisher\\(\\s*for:\\s*\\.maugham",
        "addObserver\\(\\s*forName:\\s*\\.maugham",
    ]

    /// Scan whole file text for regex matches; report `file:line`. A match
    /// whose LINE carries `// adr-0021-ok:` is exempt; comment-only lines are
    /// exempt.
    private func scanWholeText(
        in dirs: [URL], patterns: [String], allowed: Set<String>
    ) throws -> [String] {
        var offenders: [String] = []
        for dir in dirs {
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if allowed.contains(url.lastPathComponent) { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for pattern in patterns {
                    let regex = try NSRegularExpression(pattern: pattern)
                    let ns = text as NSString
                    regex.enumerateMatches(
                        in: text, range: NSRange(location: 0, length: ns.length)
                    ) { match, _, _ in
                        guard let match else { return }
                        let upTo = ns.substring(to: match.range.location)
                        let lineNumber = upTo.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
                        let lineStart = (upTo as NSString).range(
                            of: "\n", options: .backwards).location
                        let lineStartIndex = lineStart == NSNotFound ? 0 : lineStart + 1
                        let lineEnd = ns.range(
                            of: "\n", options: [],
                            range: NSRange(location: match.range.location,
                                           length: ns.length - match.range.location)).location
                        let lineEndIndex = lineEnd == NSNotFound ? ns.length : lineEnd
                        let line = ns.substring(
                            with: NSRange(location: lineStartIndex,
                                          length: lineEndIndex - lineStartIndex))
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.contains("// adr-0021-ok:") { return }
                        if trimmed.hasPrefix("//") { return }
                        offenders.append(
                            "\(url.lastPathComponent):\(lineNumber): \(trimmed)")
                    }
                }
            }
        }
        return offenders
    }

    /// ADR 0021: every `maugham.*` post/subscription goes through the
    /// MaughamEvent wrapper, which forces a delivery scope at the post site.
    /// A raw NotificationCenter post/subscription is the unscoped-broadcast
    /// defect class that shipped ≥3 times (rewind retrofit, script.did.update,
    /// toggleInspector). If a raw call is genuinely NOT a maugham event
    /// (e.g. posting an Apple system notification), annotate the line with
    /// `// adr-0021-ok: <reason>`.
    func test_noRawMaughamPostsOrSubscriptionsOutsideWrapper() throws {
        let testsDir = repoRoot.appendingPathComponent("MaughamTests", isDirectory: true)
        let offenders = try scanWholeText(
            in: [sourceDir, testsDir],
            patterns: [Self.adr0021PostPattern] + Self.adr0021SubscribePatterns,
            allowed: ["MaughamEvent.swift", "MaughamEvent+Receive.swift",
                      "TripwireGrepTests.swift"])
        XCTAssertTrue(offenders.isEmpty,
            "Raw NotificationCenter post/subscription outside the MaughamEvent "
            + "wrapper (ADR 0021). Post with MaughamEvent.post(_:to:) — every event "
            + "declares its scope — and receive via .onKeyWindowCommand / "
            + ".onDocumentEvent / .onProjectEvent / .onGlobalEvent / "
            + "MaughamEvent.observe. If this is genuinely not a maugham.* event, "
            + "annotate with // adr-0021-ok: <reason>. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the ADR 0021 tripwire FIRES on planted offenders —
    /// a raw post, a LINE-SPLIT publisher(for: .maugham…) subscription, and an
    /// addObserver(forName: .maugham…) — and that an annotated line and a
    /// comment line are exempt.
    func test_adr0021TripwireFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("tripwire-adr0021-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        func bad1() {
            NotificationCenter.default.post(name: .maughamToggleInspector, object: nil)
        }
        var bad2: some View {
            EmptyView().onReceive(NotificationCenter.default.publisher(
                for: .maughamOpenRewind)) { _ in }
        }
        func bad3() {
            _ = NotificationCenter.default.addObserver(forName: .maughamNavigateToScene,
                object: nil, queue: .main) { _ in }
        }
        func fine() {
            NotificationCenter.default.post(name: someSystemName, object: nil) // adr-0021-ok: planted exemption
            // comment mentioning NotificationCenter.default.post( is fine
        }
        """.write(to: tmp.appendingPathComponent("BadEventUser.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try scanWholeText(
            in: [tmp],
            patterns: [Self.adr0021PostPattern] + Self.adr0021SubscribePatterns,
            allowed: [])
        XCTAssertEqual(offenders.count, 3,
            "Self-check expected the raw post, the line-split publisher, and the "
            + "addObserver to fire (and only those). Got:\n"
            + offenders.joined(separator: "\n"))
    }
```

Note the `NSRegularExpression` patterns must use `dotMatchesLineSeparators`-free whitespace classes — `\\s` already matches newlines, which is exactly what catches the line-split `publisher(\n for: .maugham…)` form.

- [ ] **Step 2: Run** `xcodebuild … -only-testing:MaughamTests/TripwireGrepTests` — Expected: the SELF-TEST passes; the production check may list residual offenders. Fix every offender by migrating or annotating (each annotation needs a defensible reason — when in doubt, migrate).
- [ ] **Step 3: Re-run — PASS. Full Mac suite — PASS.**
- [ ] **Step 4: Commit** — `git commit -am "test(tripwire): forbid raw maugham.* posts/subscriptions outside MaughamEvent (ADR 0021)"`

---

### Task 10: Docs

**Files:**
- Modify: `docs/adr/0021-scoped-window-events.md` — Status → `Implemented (2026-07-02, this branch)`; add one line noting the two classification deviations (navigateToDocument → .project fixing stats-window nav; openRewind stays project) and the 2 dead-post deletions; note the final count (41 names re-verified).
- Modify: `CLAUDE.md` — add tripwire row **21**: `| 21 | No raw \`maugham.*\` NotificationCenter post/subscription outside \`MaughamEvent\` — every post declares scope (.keyWindow/.document/.project/.allWindows); receive helpers own each filter + the closed-window liveness guard | unscoped broadcast shipped the same defect ≥3× (rewind retrofit, script.did.update relayout/clobber, toggleInspector double-toggle); SwiftUI scene storage keeps closed-window zombies subscribed | \`Maugham/Events/MaughamEvent.swift\`; TripwireGrepTests; ADR 0021 |`
- Modify: `Maugham/Editor/AREA.md` — rewrite the "Scoped `maughamScriptDidUpdate` (Channel A)" bullet: routing now via `MaughamEvent` `.project` scope; `ScriptUpdateRouting` deleted; posters use `MaughamEvent.post(…, to: .project(id:))`, receivers `.onProjectEvent`. Keep the NOT-key-window rationale sentence verbatim.
- Modify: `Maugham/Views/AREA.md` — add a section: ProjectWindow receivers use the `MaughamEvent` helpers exclusively; hand-written `isKeyWindow` guards are extinct (grep-verifiable); new events pick a scope at the post site; panes needing liveness resolve their window via `WindowAccessor`.
- Modify: `docs/roadmap.md` — Group 4 "Scoped window events" entry: `•` → `✓ shipped (2026-07-02)` with a one-line summary (typed wrapper + liveness guard + tripwire; toggleInspector/navigation/checkpoint cross-window fixes; 2 dead posts deleted; spike outcome pointer).
- Modify: `Maugham/Models/MaughamNotifications.swift` — header comment: all names post via `MaughamEvent` (ADR 0021); group/annotate names by scope class (the Task 7 zombie audit notes are already in place).

- [ ] **Step 1: Make the edits above.**
- [ ] **Step 2: Verify no doc claims anything unshipped** (help/docs describe what ships).
- [ ] **Step 3: Commit** — `git commit -am "docs: ADR 0021 implemented — tripwire row 21, AREA pointers, roadmap"`

---

### Task 11: Full verification (both schemes + Release build)

- [ ] **Step 1: Full Mac suite** — `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` — PASS.
- [ ] **Step 2: Full phone suite** (MaughamCore untouched, but the rule is BOTH schemes) — `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO` — PASS (re-run once on simulator preflight flake).
- [ ] **Step 3: Release build** (ProjectWindow.body changed) — `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO` — SUCCEEDS. If the type-checker times out, extract the offending modifier chain into another ViewModifier (the established pattern).
- [ ] **Step 4: `grep -rn "isKeyWindow" Maugham/`** — Expected hits ONLY in `MaughamEvent.swift` (`EventReceiverContext.forWindow`) — every hand-written guard is gone.
- [ ] **Step 5: Commit anything outstanding; report the two-window manual smoke checklist (below) to the user.**

**Two-window manual smoke checklist (user-run, from the spec's acceptance):**
1. Open two different projects (A large screenplay, B a collection). ⌘⌥I with B key → ONLY B's inspector toggles. Repeat with A key.
2. Flip to a screenplay piece in B → NO relayout pause or scene-navigator change in A.
3. With B key: ⌘S checkpoint, ⌘⌥F find, History → Rewind… → all act on B only; A's panes untouched.
4. ⌘\ focus mode, ⌘⇧P research preview, ⌘⌥1/2/3 segment swap with B key → B only.
5. Click a chapter row in A's Project Statistics window → A's project window navigates to it (this was broken before; now fixed).
6. Close A (large doc), then type/flip pieces in B → no stall, no beachball, no work attributable to the closed window.
7. Quit + relaunch + reopen from Recents → text intact (standard smoke).

---

### Task 12: Timeboxed spike — releasing closed-window scene storage (allowed to fail)

**Timebox: half a day. Do NOT restructure window presentation.** With the liveness guard shipped, zombies are inert AND deaf — the residual is bounded RAM; this spike only probes whether something cheap releases it.

**Files:**
- Create: `docs/superpowers/notes/2026-07-02-scene-storage-spike.md` (the outcome record — REQUIRED either way)
- Possibly modify (dev-build only, behind `#if MAUGHAM_DEV_BUILD` if kept): `Maugham/MaughamApp.swift`, `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Instrument.** Dev-build-only weak registry: `WeakBox<EditorCoordinator>` recorded at coordinator creation, dumped via a debug menu item (or an existing dev hook). Success metric: the weak ref for a CLOSED window's coordinator goes nil without app quit.
- [ ] **Step 2: Attempts (in order, stop at success or timebox):**
  1. On `NSWindow.willCloseNotification` for a project window, clear the `WindowGroup(id:"project", for: URL.self)` presented value (`$url = nil` inside the scene closure, or `dismissWindow(id:"project", value:url)` from the environment) — does SwiftUI drop the scene storage?
  2. `.onDisappear`: nil out heavy `@State` (e.g. `lastParsedScript`, `documentStore` reference) — doesn't release the graph but may shrink the zombie's footprint materially; measure.
  3. Check whether `NSWindow.isReleasedWhenClosed` / explicit `window.contentView = nil` on close (via WindowAccessor's cached ref) releases the AppKit side even if SwiftUI state persists.
- [ ] **Step 3: Measure.** `footprint <pid>` (or Xcode memory gauge) before/after closing a large-doc window (stage a 250pp fixture per the perf-milestone recipe, `/tmp/maugham-perf-probe`), for baseline vs. each successful attempt.
- [ ] **Step 4: Record the outcome in the note** — released (which attempt, numbers) or documented-as-framework-cost (numbers, what was tried, why each failed). Link the note from `docs/adr/0021-scoped-window-events.md`'s addendum paragraph and delete any experiment code that didn't earn its keep.
- [ ] **Step 5: Commit** — `git commit -am "spike(events): scene-storage release attempt — outcome recorded (ADR 0021)"`

---

## Self-Review (done at plan time)

- **Spec coverage:** wrapper API ✓ (T1/T2), liveness guard in window-scoped helpers ✓ (T1/T2), `.onGlobalEvent` no-guard + per-name audit ✓ (T2/T7), non-View helper with explicit liveness contract ✓ (T2/T4), 41-name re-verified classification ✓ (header + T3–T7), hand-written guard deletion ✓ (T3–T5), toggleInspector fix + regression test ✓ (T1/T3), ScriptUpdateRouting absorption ✓ (T5), teardown audit ✓ (T8), closed-window test per scope class ✓ (T8 matrix), tripwire last with planted offender + shared constants + escape hatch ✓ (T9), docs ✓ (T10), both suites + Release build + manual smoke ✓ (T11), timeboxed spike with recorded outcome ✓ (T12). Non-goals respected: no timing changes, no system-notification migration, no @Observable replacement, no window-presentation restructuring.
- **Deviations from the spec's provisional lists, with rationale:** navigateToDocument → `.project` (stats-window poster is key; receiver key-guard = dead nav), openRewind stays `.project` (existing correct retrofit semantics), `EventScope.project(id:)` instead of `(url:)` (coordinator holds only the id; id comparison is the existing correct idiom), 2 dead posts deleted rather than wrapped (no receivers exist; tripwire prevents raw resurrection).
- **Type consistency:** `EventScope.project(id:)`/`.project(for:)`, `EventReceiverContext.Kind`, `MaughamEvent.post(_:to:object:payload:)`, `.onKeyWindowCommand(_:window:perform:)`, `MaughamEvent.observe(_:context:handler:)` used identically across T1–T9.
