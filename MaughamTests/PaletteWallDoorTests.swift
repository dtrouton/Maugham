import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The palette wall keeps a door** (shell-finish stage-2b Task 5; shell p1
/// Task 2 made the wall a subject).
///
/// The wall is open exactly while the window's subject has `open == .palette`
/// (`ProjectWindow.showsPaletteWallCentre`). The Palette tree section's "Open
/// Wall" door sets that (`ProjectWindow.pressPaletteWallDoor`), nothing
/// travels, and any subject change that takes `open` elsewhere closes it — the
/// stash and the Close rule are `PaletteWallState`'s.
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

    // MARK: - showsPaletteWallCentre: the one question

    func test_theWallIsTheCentreExactlyWhenThePaletteIsOpen() {
        for open in SubjectSamples.everyOpen {
            XCTAssertEqual(
                ProjectWindow.showsPaletteWallCentre(subject: SubjectSamples.opened(open)),
                open == .palette, "\(open)")
        }
        // The faces do not open it: the palette in the faces with a piece open
        // is not the wall.
        XCTAssertFalse(ProjectWindow.showsPaletteWallCentre(
            subject: WindowSubject(open: .item(SubjectSamples.pieceID), faces: .palette)))
    }

    // MARK: - The door's press

    /// **The door opens the wall where the writer is**: `open` becomes the
    /// palette and the faces stay on what they were about. Nothing travels.
    func test_pressingTheDoorOpensTheWallAndLeavesTheFaces() {
        for open in SubjectSamples.everyOpen where open != .palette {
            var subject = WindowSubject(open: open, faces: .item(SubjectSamples.pieceID))
            ProjectWindow.pressPaletteWallDoor(subject: &subject)
            XCTAssertEqual(subject.open, .palette, "from \(open)")
            XCTAssertEqual(subject.faces, .item(SubjectSamples.pieceID),
                           "from \(open): the faces stay")
            XCTAssertTrue(ProjectWindow.showsPaletteWallCentre(subject: subject))
            XCTAssertFalse(ProjectWindow.showsStatusFooter(
                subject: subject, structure: SubjectSamples.structure),
                           "the manuscript footer is silent under the wall")
        }
    }

    // MARK: - applyPaletteWallChange: the wall's own fold

    func test_applyPaletteWallChange_opensStashesAndHidesTheInspector() {
        var showInspector = true
        var wall = PaletteWallState()
        var card: String? = "card-1"
        wall.applyPaletteWallChange(
            from: Self.piece, to: Self.wall, showInspector: &showInspector,
            selectedPaletteCardId: &card)
        XCTAssertFalse(showInspector)
        XCTAssertEqual(wall.inspectorWasVisibleBefore, true)
        XCTAssertEqual(wall.subjectBeforeWall, Self.piece)
        XCTAssertEqual(card, "card-1", "opening does not disturb a card already selected")
    }

    func test_applyPaletteWallChange_closesRestoresAndForgetsTheCard() {
        var showInspector = false
        var wall = PaletteWallState(inspectorWasVisibleBefore: true, subjectBeforeWall: Self.piece)
        var card: String? = "card-1"
        wall.applyPaletteWallChange(
            from: Self.wall, to: Self.piece, showInspector: &showInspector,
            selectedPaletteCardId: &card)
        XCTAssertTrue(showInspector)
        XCTAssertNil(wall.inspectorWasVisibleBefore)
        XCTAssertNil(wall.subjectBeforeWall)
        XCTAssertNil(card, "the wall forgets which card it had open")
    }

    /// A `nil` stash on the way out is a real state, not "nothing to restore" —
    /// see `applyPaletteWallChange`'s own doc comment.
    func test_applyPaletteWallChange_aMissingStashIsNotResurrected() {
        var showInspector = false
        var wall = PaletteWallState()
        var card: String? = "card-1"
        wall.applyPaletteWallChange(
            from: Self.wall, to: Self.piece, showInspector: &showInspector,
            selectedPaletteCardId: &card)
        XCTAssertFalse(showInspector, "nothing restores over a missing stash")
        XCTAssertNil(wall.inspectorWasVisibleBefore)
        XCTAssertNil(card)
    }

    /// A change that keeps the wall open (the faces moving) or keeps it shut
    /// touches nothing.
    func test_applyPaletteWallChange_isANoOpWhenTheWallDidNotOpenOrClose() {
        var facesMoved = Self.wall
        facesMoved.faces = .project
        for (from, to) in [(Self.wall, facesMoved), (Self.piece, SubjectSamples.opened(.canvas))] {
            var showInspector = true
            var wall = PaletteWallState()
            var card: String? = "card-1"
            wall.applyPaletteWallChange(
                from: from, to: to, showInspector: &showInspector,
                selectedPaletteCardId: &card)
            XCTAssertTrue(showInspector)
            XCTAssertNil(wall.inspectorWasVisibleBefore)
            XCTAssertEqual(card, "card-1")
        }
    }

    /// **The wall's Close goes back where the writer was**, or to the Book when
    /// nothing is remembered; over anything but the wall it is no change.
    func test_closingTheWallReturnsToTheSubjectItWasOpenedOver() {
        let wall = PaletteWallState(inspectorWasVisibleBefore: true, subjectBeforeWall: Self.piece)
        XCTAssertEqual(wall.closingWall(Self.wall), Self.piece)
        XCTAssertEqual(PaletteWallState().closingWall(Self.wall), .book)
        XCTAssertEqual(wall.closingWall(Self.piece), Self.piece)
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
            onClose: { closed = true }, persona: .author))
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

    /// **No `.palette` comparison outside the one question.** The wall is
    /// `showsPaletteWallCentre`; a second spelling of "is the wall open" in any
    /// view is a second answer free to disagree. Code lines only.
    func test_thePaletteIsComparedOnlyInTheOneQuestion() throws {
        let hits = try Self.dotPaletteComparisons(under: "Maugham/Views")
        XCTAssertEqual(hits.count, 1, "found \(hits)")
        XCTAssertTrue(hits.first?.hasPrefix("Maugham/Views/ProjectWindow.swift") == true,
                      "the one comparison is `showsPaletteWallCentre`'s: \(hits)")
    }

    // MARK: - Mounted: the real modifier, the real door

    /// **Any subject change that takes the wall away restores the inspector**,
    /// on the real modifier: an `onChange` that does not fire is
    /// indistinguishable from a rule that decided not to act.
    func test_theMountedModifierFoldsTheWallOnASubjectChange() async throws {
        let box = WallBox()
        box.subject = Self.piece
        box.showInspector = true
        _ = hostWallModifier(box: box)

        ProjectWindow.pressPaletteWallDoor(subject: &box.subject)
        await pumpUntil(deadline: 5) { !box.showInspector }
        XCTAssertFalse(box.showInspector, "the open arm hides the right column")
        XCTAssertEqual(box.wall.inspectorWasVisibleBefore, true)

        box.subject = ClickRule.resolve(.item("pc02"), gesture: .click,
                                        current: box.subject,
                                        structure: SubjectSamples.structure,
                                        projectType: .novel)
        await pumpUntil(deadline: 5) { box.showInspector }
        XCTAssertTrue(box.showInspector, "a tree click took the wall away and restored it")
        XCTAssertNil(box.wall.inspectorWasVisibleBefore)
    }

    /// **The whole door, end to end**: the real "Open Wall" button in a real
    /// tree, whose closure is `ProjectWindow.pressPaletteWallDoor` (the same
    /// function `ProjectWindow.openPaletteWall` calls), over the real
    /// `PaletteWallModifier`.
    func test_pressingTheDoorOpensTheWallInPlace() async throws {
        let store = try await novel()
        let box = WallBox()
        box.subject = SubjectSamples.opened(.canvas)
        let window = try await hostDoorProbe(store: store, box: box)

        try clickTheDoor(in: window)
        await pumpUntil(deadline: 5) { box.subject.open == .palette }

        XCTAssertEqual(box.subject.open, .palette, "the door did not open the wall")
        XCTAssertEqual(box.subject.faces, .canvas, "the faces stay where they were")
        await pumpUntil(deadline: 5) { !box.showInspector }
        XCTAssertFalse(box.showInspector, "the open arm did not run over the press")
    }

    /// **The window's own wiring**: both tree shells' `onOpenPaletteWall`
    /// closures must reach the door's press rather than writing the subject
    /// themselves.
    func test_bothTreeShellsReachTheDoor() throws {
        let presses = try Self.openPaletteWallPresses()
        XCTAssertEqual(presses.count, 2,
                       "the two tree shells (standard + Collection) are the "
                       + "door's only mount sites — found \(presses)")
        for line in presses {
            XCTAssertTrue(line.contains("openPaletteWall()"),
                          "a tree shell opens the wall directly: \(line)")
        }
    }

    /// Every `== .palette`/`!= .palette` code line under `root`, as "path: line",
    /// file by file. Comment lines are skipped.
    private static func dotPaletteComparisons(
        under root: String, base: URL = SourceTree.repoRoot
    ) throws -> [String] {
        try SourceTree.sources(under: root, base: base).flatMap { file in
            file.text.split(separator: "\n").filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                    && ($0.contains("== .palette") || $0.contains("!= .palette"))
            }.map { "\(file.path): \($0.trimmingCharacters(in: .whitespaces))" }
        }
    }

    /// The window's `onOpenPaletteWall:` code lines, read by TYPE — every file
    /// under `Maugham/` declaring `ProjectWindow`.
    private static func openPaletteWallPresses(base: URL = SourceTree.repoRoot) throws -> [Substring] {
        codeOnly(try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"], base: base))
            .split(separator: "\n")
            .filter { $0.contains("onOpenPaletteWall:") }
    }

    /// **The planted control for the reads above** (foundations plan 2): a
    /// `ProjectWindow` struct in one file and an `extension ProjectWindow` in
    /// another. The press count reads both files, and the widened ban catches
    /// an offender in a sibling view outside the window.
    func test_theReadsFollowTheTypeAndTheBansReachSiblingViews() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/ProjectWindow.swift": """
            struct ProjectWindow: View {
                var body: some View { Tree(onOpenPaletteWall: { openPaletteWall() }) }
            }
            """,
            "Maugham/Views/ProjectWindow+Wall.swift": """
            extension ProjectWindow {
                var other: some View { CollectionTree(onOpenPaletteWall: { openPaletteWall() }) }
            }
            """,
            "Maugham/Views/SomeSiblingView.swift": """
            struct SomeSiblingView {
                func f() -> Bool { subject.open == .palette }
            }
            """,
        ])
        XCTAssertEqual(try Self.openPaletteWallPresses(base: base).count, 2,
                       "the press count reads both of the window's files")
        XCTAssertEqual(try Self.dotPaletteComparisons(under: "Maugham/Views", base: base),
                       ["Maugham/Views/SomeSiblingView.swift: func f() -> Bool { subject.open == .palette }"])
    }

    private static let piece = SubjectSamples.opened(.item(SubjectSamples.pieceID))
    private static var wall: WindowSubject {
        var subject = piece
        ProjectWindow.pressPaletteWallDoor(subject: &subject)
        return subject
    }

    /// Source with `//` and `///` lines dropped — the shape
    /// `test_noComparisonAgainstDotPaletteSurvivesInProjectWindow` already uses
    /// inline, lifted out because two censuses here need it.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
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

    /// The real door and the real `PaletteWallModifier` over one box — the two
    /// production halves of the press, and nothing standing in for either.
    private func hostDoorProbe(
        store: ProjectStore, box: WallBox
    ) async throws -> NSWindow {
        let window = TestWindow.mount(AnyView(DoorProbeView(store: store, box: box)),
                                      size: CGSize(width: 320, height: 800),
                                      as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        pump(0.2)
        return window
    }

    /// The real `PaletteWallModifier` over a box the test drives, on a view with
    /// nothing else in it — the observer is the whole subject, so anything else
    /// mounted here could only supply another explanation for a closed wall.
    @discardableResult
    private func hostWallModifier(box: WallBox) -> NSWindow {
        let window = hostKeyWindow(WallProbeView(box: box))
        pump(0.1)
        return window
    }

    private func hostKeyWindow(_ view: some View) -> NSWindow {
        // `KeyTestWindow` because `.maughamCloseFind` is key-window scoped and
        // this suite sends real key events, which beep against a window that
        // never becomes key.
        let window = TestWindow.mount(AnyView(view), size: CGSize(width: 320, height: 600),
                                      as: KeyTestWindow.self)
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

    /// **A real mouse click on the door**, because an accessibility press
    /// skips in any process no assistive client attaches to — which is
    /// every process this suite has ever run in.
    ///
    /// It also subsumes the enablement claim: a disabled
    /// `Button` swallows a click, so a press that reaches its action proves the
    /// door is live in the persona it was pressed in.
    ///
    /// **Finding the door**: `PaletteWallDoorHitAreaTests.doorGeometry`'s
    /// structural discriminator, in miniature — the Palette header is the one
    /// carrying TWO buttons (its chevron and the door) where Research carries a
    /// chevron alone, and within it the door is the TRAILING one — the chevron
    /// leads the title since D1 (2026-09-19). Identifying it by position in the
    /// window instead is what silently measured the Research chevron when the
    /// chevrons landed.
    private func clickTheDoor(in window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        let headers = allViews(in: content).filter {
            String(describing: type(of: $0)).contains("ListTableHeaderView")
        }
        let ringsByHeader = headers.map { header in
            allViews(in: header)
                .filter { String(describing: type(of: $0)).contains("FocusRing") }
                .sorted { $0.convert($0.bounds, to: content).minX
                          < $1.convert($1.bounds, to: content).minX }
        }
        guard let palette = ringsByHeader.filter({ $0.count >= 2 })
                .max(by: { $0.count < $1.count }),
              let ring = palette.last
        else {
            throw XCTSkip(
                "this display mounted \(headers.count) section headers carrying "
                + "\(ringsByHeader.map(\.count)) buttons — no Palette header "
                + "with a door beside its chevron to click")
        }
        let icon = ring.convert(ring.bounds, to: content)
        try XCTSkipUnless(icon.height > 1 && icon.width > 1,
                          "this display mounted a door of \(icon.size)")
        let inWindow = content.convert(CGPoint(x: icon.midX, y: icon.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
        }
        pump(0.05)
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }
}

// MARK: - Probes

/// The door and the wall's observer over one box, wired the way `ProjectWindow`
/// wires them: the press comes from production
/// (`ProjectWindow.pressPaletteWallDoor`), and the modifier is the real one.
@MainActor
private struct DoorProbeView: View {
    let store: ProjectStore
    let box: WallBox
    let treeState = BinderTreeSectionsState()

    var body: some View {
        BinderView(
            store: store,
            selectedSubject: Binding(get: { box.subject.beside ?? box.subject.faces },
                                     set: { _ in }),
            treeState: treeState,
            paletteWallTravels: false,
            onOpenPaletteWall: { ProjectWindow.pressPaletteWallDoor(subject: &box.subject) })
        .modifier(ProjectWindow.PaletteWallModifier(
            paletteWall: Binding(get: { box.wall }, set: { box.wall = $0 }),
            showInspector: Binding(get: { box.showInspector },
                                   set: { box.showInspector = $0 }),
            selectedPaletteCardId: Binding(get: { box.selectedCardId },
                                           set: { box.selectedCardId = $0 }),
            subject: box.subject))
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
                              onClose: onCloseWall, persona: .author)
        }
    }
}

/// The window state the wall's rule reads and writes, held outside the view
/// so a test can drive the subject the way any of its writers does. At file
/// scope because `@Observable` cannot expand inside a `private` nested type.
@Observable
@MainActor
final class WallBox {
    var subject: WindowSubject = .book
    /// The window's `PaletteWallState`, whole — what `PaletteWallModifier`
    /// binds to.
    var wall = PaletteWallState()
    var showInspector = true
    var selectedCardId: String?
    init() {}
}

/// The REAL `ProjectWindow.PaletteWallModifier`, applied to nothing — the
/// observer is the subject under test.
@MainActor
private struct WallProbeView: View {
    let box: WallBox

    var body: some View {
        Color.clear
            .modifier(ProjectWindow.PaletteWallModifier(
                paletteWall: Binding(get: { box.wall }, set: { box.wall = $0 }),
                showInspector: Binding(get: { box.showInspector },
                                       set: { box.showInspector = $0 }),
                selectedPaletteCardId: Binding(get: { box.selectedCardId },
                                               set: { box.selectedCardId = $0 }),
                subject: box.subject))
    }
}
