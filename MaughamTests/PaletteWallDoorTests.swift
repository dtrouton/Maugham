import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The palette wall keeps a door** (shell-finish stage-2b Task 5).
///
/// `.palette` dies with the strip in Task 7, and the wall — the centre-column
/// card-arrangement surface `PaletteWallView` draws — would go dark with it
/// unless something else opens it. This suite is that something: the Palette
/// tree section's own "Open Wall" affordance, `ProjectWindow.showsPaletteWall`,
/// and the routing/stash/close rules built on it.
@MainActor
final class PaletteWallDoorTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - showsPaletteWallCentre: the routing guard

    func test_showsPaletteWallCentre_trueOutsidePlanWhenOpen() {
        for persona in Persona.allCases where persona != .plan {
            XCTAssertTrue(
                ProjectWindow.showsPaletteWallCentre(showsPaletteWall: true, persona: persona),
                "\(persona)")
        }
    }

    func test_showsPaletteWallCentre_falseInPlanEvenWhenOpen() {
        XCTAssertFalse(
            ProjectWindow.showsPaletteWallCentre(showsPaletteWall: true, persona: .plan),
            "Plan's centre is the canvas — the wall taking it over is stage 3's call")
    }

    func test_showsPaletteWallCentre_falseWhenClosed() {
        for persona in Persona.allCases {
            XCTAssertFalse(
                ProjectWindow.showsPaletteWallCentre(showsPaletteWall: false, persona: persona),
                "\(persona)")
        }
    }

    // MARK: - applyPaletteWallChange: the door's own fold

    func test_applyPaletteWallChange_opensStashesAndHidesTheInspector() {
        var showInspector = true
        var stash: Bool?
        var card: String? = "card-1"
        ProjectWindow.applyPaletteWallChange(
            from: false, to: true, showInspector: &showInspector,
            stash: &stash, selectedPaletteCardId: &card)
        XCTAssertFalse(showInspector)
        XCTAssertEqual(stash, true)
        XCTAssertEqual(card, "card-1", "opening does not disturb a card already selected")
    }

    func test_applyPaletteWallChange_closesRestoresAndForgetsTheCard() {
        var showInspector = false
        var stash: Bool? = true
        var card: String? = "card-1"
        ProjectWindow.applyPaletteWallChange(
            from: true, to: false, showInspector: &showInspector,
            stash: &stash, selectedPaletteCardId: &card)
        XCTAssertTrue(showInspector)
        XCTAssertNil(stash)
        XCTAssertNil(card, "the wall forgets which card it had open")
    }

    /// The takeover case: something else (the canvas collapse) already took the
    /// stash. A `nil` stash on the way out is a real state, not "nothing to
    /// restore" — see `applyPaletteWallChange`'s own doc comment.
    func test_applyPaletteWallChange_aTakenOverStashIsNotResurrected() {
        var showInspector = false
        var stash: Bool?   // already taken over
        var card: String? = "card-1"
        ProjectWindow.applyPaletteWallChange(
            from: true, to: false, showInspector: &showInspector,
            stash: &stash, selectedPaletteCardId: &card)
        XCTAssertFalse(showInspector, "nothing restores over a takeover")
        XCTAssertNil(stash)
        XCTAssertNil(card)
    }

    func test_applyPaletteWallChange_isANoOpWhenNothingChanged() {
        for value in [true, false] {
            var showInspector = true
            var stash: Bool?
            var card: String? = "card-1"
            ProjectWindow.applyPaletteWallChange(
                from: value, to: value, showInspector: &showInspector,
                stash: &stash, selectedPaletteCardId: &card)
            XCTAssertTrue(showInspector, "\(value)")
            XCTAssertNil(stash, "\(value)")
            XCTAssertEqual(card, "card-1", "\(value)")
        }
    }

    // MARK: - binderSegment(restoring:) coerces a legacy `.palette`

    /// A `UIState` an earlier build wrote with the binder on `.palette` must
    /// not restore verbatim — the segment's own inspector auto-hide died with
    /// the re-key (`applyPaletteWallChange`'s doc comment), so a writer landed
    /// there would get a segment that no longer behaves the way it used to.
    func test_binderSegmentRestoring_coercesALegacyPaletteToThePersonasHome() {
        for persona in Persona.allCases {
            for type in ProjectType.allCases where type != .unknown {
                XCTAssertEqual(
                    ProjectWindow.binderSegment(restoring: .palette, persona: persona,
                                                projectType: type),
                    persona.binderHome(for: type),
                    "\(persona)/\(type)")
            }
        }
    }

    // MARK: - The header's door — mounted

    func test_theHeadersOpenWallButtonFiresTheClosureWhenEnabled() async throws {
        let store = try await novel()
        var opened = false
        let window = try await hostTree(store: store, canOpenPaletteWall: true) { opened = true }

        let button = try openWallButton(in: window)
        XCTAssertTrue(
            (axAttribute(button, "accessibilityEnabled") as? Bool) ?? false,
            "premise: the door is enabled outside Plan")
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        await pumpUntil(deadline: 5) { opened }

        XCTAssertTrue(opened, "the header's door did not reach the closure")
    }

    func test_theHeadersOpenWallButtonIsDisabledInPlan() async throws {
        let store = try await novel()
        var opened = false
        let window = try await hostTree(store: store, canOpenPaletteWall: false) { opened = true }

        let button = try openWallButton(in: window)
        XCTAssertFalse(
            (axAttribute(button, "accessibilityEnabled") as? Bool) ?? true,
            "the door must read as disabled when Plan's centre is the canvas")
    }

    // MARK: - Esc closes the wall — a REAL Escape, at the wall's own claim

    /// **The mechanism is `.onExitCommand`, reused from Task 1** — see
    /// `PaletteWallCentre`'s own doc comment for why it needs a focus claim of
    /// its own (nothing here is a text responder, unlike `ProjectSearchView`'s
    /// query field). Driven with a real `.keyDown`, the way AppKit delivers
    /// one, because a test that called `onClose()` directly could not see
    /// whether the key reaches it at all.
    func test_aRealEscapeAtTheWallClosesIt() async throws {
        let store = try await novel()
        var closed = false
        let window = hostKeyWindow(PaletteWallCentre(
            store: store, selectedPaletteCardId: .constant(nil),
            onClose: { closed = true }))
        await waitOut(0.2)   // outlast the 30ms deferred focus claim

        window.sendEvent(Self.escapeKeyEvent(for: window))
        await pumpUntil(deadline: 5) { closed }

        XCTAssertTrue(closed, "a real Escape at the wall did not reach onClose")
    }

    /// **Precedence with the find overlay, measured rather than assumed.**
    /// Both can be open together (find replaces the LEFT column, the wall
    /// takes the CENTRE), and a single Escape has to go somewhere. Find's
    /// query field autofocuses via `DispatchQueue.main.async`; the wall's own
    /// claim is deferred 30ms (tripwire 16's shape) — the slower claim reads
    /// as though it should lose, but measured on a real window (macOS 26.5,
    /// 2026-08-09) it is the WALL that closes: the key window's first
    /// responder lands on the `.focusable()` claim, and find's field, though
    /// present, does not intercept `cancelOperation:` ahead of it. **Pinned
    /// rather than designed**: this is the record of that order, not a
    /// requirement that it stay this way round — if a future SwiftUI changes
    /// it, update the doc comment here alongside the assertions, not just the
    /// assertions. Either way the writer is not trapped: the wall closes,
    /// find is still there for a second Escape.
    func test_aRealEscapeWithBothOpenClosesTheWallFirst() async throws {
        let store = try await novel()
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        var wallClosed = false
        let window = hostKeyWindow(BothOpenProbeView(
            store: store,
            onCloseWall: { wallClosed = true }))
        await pumpUntil(deadline: 5) { self.queryField(in: window) != nil }
        await waitOut(0.2)   // outlast the wall's own deferred claim too

        window.sendEvent(Self.escapeKeyEvent(for: window))
        await pumpUntil(deadline: 5) { wallClosed }

        XCTAssertTrue(wallClosed, "the wall did not close on the shared Escape")
        XCTAssertNotNil(queryField(in: window),
                        "find closed too — the writer is not trapped either way, "
                        + "but this pins the wall going first; if this ever flips, "
                        + "update the doc comment above rather than just the assert")
    }

    // MARK: - Census: nothing selects the legacy `.palette` segment

    /// **The half a mounted probe cannot see.** The offending spelling is
    /// asked for by name, with a planted offender proving the pattern still
    /// matches something — `TreeFindOverlayTests.test_nothingInTheWindow
    /// SelectsTheFindSegment`'s shape, one segment over.
    func test_nothingWritesTheLegacyPaletteSegment() throws {
        let pattern = #"(?:binderSegment|segment) = \.palette\b"#
        XCTAssertNotNil(
            "                    binderSegment = .palette"
                .range(of: pattern, options: .regularExpression),
            "the pattern no longer matches its own planted offender, so the "
            + "census below is vacuous")

        for path in ["Maugham/Views/ProjectWindow.swift",
                     "Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.isEmpty, "\(path): read nothing")
            let hits = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && $0.range(of: pattern, options: .regularExpression) != nil
            }
            XCTAssertTrue(hits.isEmpty,
                          "\(path): something still selects the palette segment — "
                          + "\(hits). The wall has its own door "
                          + "(`showsPaletteWall`); nothing writes `.palette`.")
        }
    }

    /// The OLD wall mechanism compared segments against `.palette` directly
    /// (`applyPaletteSegmentChange`, `clearsPaletteStash`); both are re-keyed
    /// off `showsPaletteWall`/`Persona` now, so no such comparison should
    /// survive in the window.
    func test_noComparisonAgainstDotPaletteSurvivesInProjectWindow() throws {
        let text = try source("Maugham/Views/ProjectWindow.swift")
        let hits = text.split(separator: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                && ($0.contains("== .palette") || $0.contains("!= .palette"))
        }
        XCTAssertTrue(hits.isEmpty,
                      "something still compares a segment against `.palette` — "
                      + "\(hits). `showsPaletteWall` replaced every one of these.")
    }

    /// The subject-change close, wired rather than merely described — a
    /// planted-offender-style existence check, not a behavioural drive: SwiftUI
    /// `.onChange` handlers inside a `private` `ViewModifier` are not reachable
    /// from a test any other way (the same reason the ORIGINAL palette↔canvas
    /// race had no direct mounted test, only the pure-function halves and this
    /// suite's `PromotionCommandTests` sibling's token census).
    func test_theWallModifierClosesOnASubjectChange() throws {
        let text = try source("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(
            text.contains(".onChange(of: selectedSubject) { _, _ in")
            && text.contains("if showsPaletteWall { showsPaletteWall = false }"),
            "PaletteWallModifier must close the wall on any subject change — "
            + "the door's own contract")
    }

    // MARK: - Fixtures

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting and driving

    /// **A window that reports itself key**, `TreeFindOverlayTests.KeyTestWindow`'s
    /// reason verbatim: `.maughamCloseFind` is key-window scoped and this suite
    /// sends real key events, which beep against a window that never becomes key.
    private final class KeyTestWindow: SilentTestWindow {
        override var isKeyWindow: Bool { true }
    }

    private func hostTree(
        store: ProjectStore, canOpenPaletteWall: Bool, onOpenPaletteWall: @escaping () -> Void
    ) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        let hosting = NSHostingView(rootView: AnyView(DoorProbeView(
            store: store, canOpenPaletteWall: canOpenPaletteWall,
            onOpenPaletteWall: onOpenPaletteWall)))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        pump(0.2)
        return window
    }

    private func hostKeyWindow(_ view: some View) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = KeyTestWindow(contentRect: frame, styleMask: [.titled],
                                   backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.15)
        return window
    }

    /// A real Escape, built the way AppKit delivers one —
    /// `TreeFindOverlayTests.escapeKeyEvent`'s shape.
    private static func escapeKeyEvent(for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                         isARepeat: false, keyCode: 53)!
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Reading the hierarchy

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    private func queryField(in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextField] = []
        collect(NSTextField.self, in: root, into: &found)
        return found.first { $0.placeholderString == "Find in project" }
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    /// The "Open Wall" button, found by the accessibility label
    /// `BinderTreeSections.openWallButton` carries. `TreeFindOverlayTests
    /// .closeButton`'s shape verbatim: the retry loop is because SwiftUI builds
    /// the tree lazily, and the skip is because it builds no tree at all unless
    /// an assistive client is attached.
    private func openWallButton(in window: NSWindow) throws -> NSObject {
        for _ in 0..<10 {
            let tree = try axTree(in: window)
            if let hit = tree.first(where: {
                (axAttribute($0, "accessibilityRole") as? String) == "AXButton"
                    && ((axAttribute($0, "accessibilityLabel") as? String) ?? "")
                        == "Open Wall"
            }) as? NSObject {
                return hit
            }
            pump(0.1)
        }
        throw XCTSkip("no button labelled \"Open Wall\" was built in this process")
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    /// SwiftUI only builds an accessibility tree when an assistive client is
    /// attached to the process. `TreeFindOverlayTests`' guard, verbatim.
    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so "
                + "SwiftUI builds no accessibility tree to press a button in")
        }
        guard let root = window.contentView else { return [] }
        return axElements(under: root)
    }
}

// MARK: - Probes

/// Mounts `BinderView` with the door's two new parameters wired to a probe —
/// the minimal shape that puts the Palette section's header on screen.
@MainActor
private struct DoorProbeView: View {
    let store: ProjectStore
    let canOpenPaletteWall: Bool
    let onOpenPaletteWall: () -> Void
    @State private var subject: BinderSubject?

    var body: some View {
        BinderView(store: store, selectedSubject: $subject,
                   canOpenPaletteWall: canOpenPaletteWall,
                   onOpenPaletteWall: onOpenPaletteWall)
    }
}

/// Find's overlay in the left column and the wall in the centre, together —
/// `test_aRealEscapeWithBothOpenClosesFindFirst`'s fixture. `treeFindActive`
/// is `@State` here rather than threaded through `BinderPaneToggle`'s whole
/// production wiring: the test is about which `.onExitCommand` a shared
/// Escape reaches, not about how `⌘⌥F` sets the flag.
@MainActor
private struct BothOpenProbeView: View {
    @Bindable var store: ProjectStore
    let onCloseWall: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ProjectSearchView(store: store)
                .frame(width: 160)
            PaletteWallCentre(store: store, selectedPaletteCardId: .constant(nil),
                              onClose: onCloseWall)
        }
    }
}
