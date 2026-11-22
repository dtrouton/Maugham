import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The palette wall is the Palette row** (shell-finish stage-2b Task 5; shell
/// p1 Task 2 made the wall a subject, Task 3 made the door a row).
///
/// The wall is open exactly while the window's subject has `open == .palette`
/// (`ProjectWindow.showsPaletteWallCentre`). Selecting the tree's Palette row
/// sets that through the click rule, nothing travels, and any subject change
/// that takes `open` elsewhere closes it — the stash and the Close rule are
/// `PaletteWallState`'s.
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

    // MARK: - The Palette row

    /// **Selecting the Palette row opens the wall where the writer is**: the
    /// click rule makes the palette what is open, from every centre. Nothing
    /// travels.
    func test_thePaletteRowOpensTheWall() {
        for open in SubjectSamples.everyOpen where open != .palette {
            let before = WindowSubject(open: open, faces: .item(SubjectSamples.pieceID))
            let subject = ClickRule.resolve(.palette, gesture: .click, current: before,
                                            structure: SubjectSamples.structure,
                                            projectType: .novel)
            XCTAssertEqual(subject.open, .palette, "from \(open)")
            XCTAssertTrue(ProjectWindow.showsPaletteWallCentre(subject: subject))
            XCTAssertFalse(ProjectWindow.showsStatusFooter(
                subject: subject, structure: SubjectSamples.structure),
                           "the manuscript footer is silent under the wall")
        }
    }

    /// The row is a row: every tree's Palette row carries the `.palette` tag
    /// the `List` selects, and no tree carries a door any more.
    func test_thePaletteRowIsTaggedAndTheDoorIsGone() throws {
        let sections = Self.codeOnly(try String(
            contentsOf: SourceTree.repoRoot.appendingPathComponent(
                "Maugham/Views/BinderTreeSections.swift"), encoding: .utf8))
        XCTAssertTrue(sections.contains(".tag(TreeRowTag.subject(.palette))"),
                      "the Palette row selects through the tree's `List`")
        for gone in ["openWallButton", "onOpenPaletteWall", "paletteWallTravels",
                     "pressPaletteWallDoor"] {
            let hits = try SourceTree.sources(under: "Maugham", base: SourceTree.repoRoot)
                .filter { Self.codeOnly($0.text).contains(gone) }.map { $0.path }
            XCTAssertEqual(hits, [], "the door's \(gone) survives in \(hits)")
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

    /// **Closing the wall keeps the order of the clicks before it** (shell p1
    /// final fix 2, N1): a piece clicked after a note on the canvas is still
    /// the part clicked last once the wall closes, and the close is not an
    /// arrival, so the right column's pane is not taken. A note opened while
    /// the wall was up still arrives.
    func test_closingTheWallKeepsTheLastClickedOrderAndIsNotAnArrival() {
        let note = BinderSubject.research("r-1")
        let canvas = WindowSubject(open: .canvas, faces: .canvas)
        let before = ClickRule.resolve(.item("ch-1"), gesture: .click,
            current: ClickRule.resolve(note, gesture: .click, current: canvas,
                                       structure: [], projectType: .novel),
            structure: [], projectType: .novel)
        XCTAssertFalse(before.besideIsLatest, "premise: the piece was clicked after the note")
        let atWall = ClickRule.resolve(.palette, gesture: .click, current: before,
                                       structure: [], projectType: .novel)
        let wall = PaletteWallState(inspectorWasVisibleBefore: true, subjectBeforeWall: before)
        let closed = wall.closingWall(atWall)
        XCTAssertEqual(closed, before)
        XCTAssertEqual(closed.lastClicked, .item("ch-1"))
        XCTAssertFalse(ResearchRevealModifier.isAnArrival(from: atWall, to: closed))

        let other = BinderSubject.research("r-2")
        let noteAtWall = ClickRule.resolve(other, gesture: .click, current: atWall,
                                           structure: [], projectType: .novel)
        let closedWithNew = wall.closingWall(noteAtWall)
        XCTAssertEqual(closedWithNew.beside?.treeSubject, other)
        XCTAssertEqual(closedWithNew.lastClicked, other, "control: a new note is the part clicked last")
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
            onClose: { closed = true }, isLocked: false))
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

        box.subject = Self.wall
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

    /// **The whole row, end to end**: the Palette row of a real tree selected,
    /// through the tree's `List` selection and the click rule, into the real
    /// `PaletteWallModifier`.
    func test_selectingThePaletteRowOpensTheWallInPlace() async throws {
        let store = try await novel()
        let box = WallBox()
        box.subject = SubjectSamples.opened(.canvas)
        let window = try await hostDoorProbe(store: store, box: box)

        try selectThePaletteRow(in: window)
        await pumpUntil(deadline: 5) { box.subject.open == .palette }

        XCTAssertEqual(box.subject.open, .palette, "the row did not open the wall")
        await pumpUntil(deadline: 5) { !box.showInspector }
        XCTAssertFalse(box.showInspector, "the open arm did not run over the click")
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

    /// **The planted control for the comparison census** (foundations plan
    /// 2): the widened ban catches an offender in a sibling view outside the
    /// window.
    func test_theBanReachesSiblingViews() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/ProjectWindow.swift": """
            struct ProjectWindow: View {
                var body: some View { Tree() }
            }
            """,
            "Maugham/Views/SomeSiblingView.swift": """
            struct SomeSiblingView {
                func f() -> Bool { subject.open == .palette }
            }
            """,
        ])
        XCTAssertEqual(try Self.dotPaletteComparisons(under: "Maugham/Views", base: base),
                       ["Maugham/Views/SomeSiblingView.swift: func f() -> Bool { subject.open == .palette }"])
    }

    private static let piece = SubjectSamples.opened(.item(SubjectSamples.pieceID))
    private static var wall: WindowSubject {
        ClickRule.resolve(.palette, gesture: .click, current: piece,
                          structure: SubjectSamples.structure, projectType: .novel)
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

    /// **The Palette row selected through the tree's own table**, found by
    /// the mark every tree label carries (`TreeTravelTargetView`, whose subject
    /// is the row's own) — never by position, which moves whenever the tree's
    /// furniture grows. `selectRowIndexes` reaches the `List`'s selection
    /// binding exactly as a click does.
    ///
    /// **Asserted, never skipped** (shell p1 final fix, M7): a `List` mounts
    /// only the rows on screen, so on a short display the row is scrolled into
    /// view one row at a time until it mounts. A test that skips on CI's
    /// narrower display is the flaky-test shape the no-skips gate exists for.
    private func selectThePaletteRow(in window: NSWindow) throws {
        let table = try XCTUnwrap(firstTableView(in: window))
        func mountedRow() -> Int? {
            guard let mark = allViews(in: table)
                    .compactMap({ $0 as? TreeTravelTargetView })
                    .first(where: { $0.subject == .palette }) else { return nil }
            let row = table.row(for: mark)
            return row >= 0 ? row : nil
        }
        var row = mountedRow()
        var next = 0
        while row == nil, next < table.numberOfRows {
            table.scrollRowToVisible(next)
            pump(0.02)
            row = mountedRow()
            next += 1
        }
        let paletteRow = try XCTUnwrap(row, "the tree mounted no Palette row in any scroll position")
        table.selectRowIndexes(IndexSet(integer: paletteRow), byExtendingSelection: false)
        pump(0.05)
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }
}

// MARK: - Probes

/// The tree and the wall's observer over one box, wired the way `ProjectWindow`
/// wires them: the tree writes the window subject through its own `List`
/// selection, and the modifier is the real one.
@MainActor
private struct DoorProbeView: View {
    let store: ProjectStore
    let box: WallBox
    let treeState = BinderTreeSectionsState()

    var body: some View {
        TreeHostFixture.binder(
            store: store,
            subject: Binding(get: { box.subject }, set: { box.subject = $0 }),
            treeState: treeState)
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
                              onClose: onCloseWall, isLocked: false)
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
