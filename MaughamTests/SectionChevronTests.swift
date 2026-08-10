import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The tree's two section headers carry their own disclosure chevron** —
/// Denver's smoke, 2026-08-10, the second finding in this header after the
/// wall's door.
///
/// What he reported: the expand/collapse affordance appears only on mouse-over,
/// and when it materialises it shoves the `+` and Open Wall icons left. Both
/// halves are the system's: `Section(isExpanded:)` under `.listStyle(.sidebar)`
/// renders a hover-revealed chevron of its own, and it takes its space out of
/// the header's trailing group when it arrives. There is no API to make it
/// permanent, so the fix stops letting the system draw it at all — the
/// `Section`s go back to plain, the rows are rendered conditionally on the same
/// two booleans, and the chevron is ours.
///
/// **The state did not move.** `researchSectionExpanded` / `paletteSectionExpanded`
/// are where stage-3a Task 4 put them, and `reveal()`, ⌘⌥R and ⌘⌥P write them
/// exactly as before — this suite's sibling assertions in
/// `BinderTreeSectionsTests`, `AltitudeKeyspaceTests` and
/// `ResearchSubjectRevealTests` are unchanged and still passing. What changed is
/// only who draws the triangle and who reads the flag to decide whether to emit
/// rows.
///
/// **Why the chevron is at the trailing edge** rather than in the outline gutter
/// where every ROW's triangle sits (`BinderTreeIndentationTests` measures those
/// at x=12). It is where the system put its own, so it is where Denver has been
/// reaching for it; the header is a `ListTableHeaderView`, not an outline row,
/// so it has no gutter to sit in and a hand-drawn leading chevron would line up
/// with nothing. The trade is recorded rather than hidden: the section headers
/// and the group rows beneath them now disclose from opposite edges.
@MainActor
final class SectionChevronTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - Always visible

    /// **The system's hover-revealed chevron is gone**, which is the mechanism
    /// half of the fix and the only way to be sure ours is not sitting beside
    /// it.
    ///
    /// `Section(isExpanded:)` mounts its chevron as a real `NSButton` alongside
    /// the `ListTableHeaderView` itself — both are children of the header's
    /// `ListTableRowView`, and the button is measured at `(295, y, 15, 19)` on
    /// this SDK, `isHidden` until the pointer arrives, drawn in front of the
    /// SwiftUI content and overlapping the `+` menu. A plain `Section` mounts
    /// none there.
    ///
    /// **The depth is the whole discriminator, and it took two wrong drafts to
    /// land on it.** Written as "no `NSButton` anywhere under the header" it
    /// failed against the finished fix, because our own chevron mounts an
    /// `NSButton` too (a `Button(.plain)` wrapping a rotated `Image` does, where
    /// `openWallButton`'s unrotated one leaves only a `_FocusRingView` — measured
    /// both ways in this suite). Written as "none among the header VIEW's own
    /// children" it went green over a fixture that still had a system chevron,
    /// because the button is a sibling of that view rather than a child of it —
    /// caught only by the control below, which is the entire reason the control
    /// is here. Ours lives inside the header's hosting view; the system's is one
    /// level out, in the row.
    func test_noSystemHoverChevronIsMountedInAnySectionHeader() async throws {
        let mount = try await mountTree()
        let content = try XCTUnwrap(mount.window.contentView)
        for header in sectionHeaders(in: mount.window) {
            let siblings = systemChevrons(besideHeader: header)
            XCTAssertTrue(
                siblings.isEmpty,
                "a section header row still mounts \(siblings.count) AppKit "
                + "`NSButton`(s) beside the header view — "
                + "\(siblings.map { "\($0.convert($0.bounds, to: content)) hidden=\($0.isHidden)" }). "
                + "That is `Section(isExpanded:)`'s own hover-revealed chevron, "
                + "the thing that appears on mouse-over and shoves the `+` and "
                + "Open Wall icons left")
        }
    }

    /// The control for the one above: it must be able to SEE the system chevron,
    /// or "no `NSButton` beside the hosting view" is a sentence about a shape
    /// that never existed. The offender is the pre-fix spelling —
    /// `Section(isExpanded:)` — mounted in a fixture of its own, since production
    /// no longer has one to look at.
    func test_control_theProbeSeesTheSystemChevronWhenASectionStillHasOne() async throws {
        let window = try mountBare(AnyView(SystemChevronProbeView()))
        await waitOut(0.6)
        let headers = sectionHeaders(in: window)
        try XCTSkipUnless(headers.count == 2,
                          "this display mounted \(headers.count) headers")
        let siblings = headers.flatMap { systemChevrons(besideHeader: $0) }
        XCTAssertFalse(
            siblings.isEmpty,
            "a `Section(isExpanded:)` header row mounted no `NSButton` beside "
            + "the header view on this SDK — so the assertion above is green "
            + "over any shape at all and proves nothing about the fix")
    }

    /// **Ours is on screen and clickable on a window that has never been
    /// hovered.**
    ///
    /// The strong form of "always visible": this window receives no `mouseMoved`
    /// and no `mouseEntered` in its whole life, and the very first event it ever
    /// sees is a click on the chevron — which must land. A hover-revealed
    /// affordance cannot pass this.
    ///
    /// The Research header is the one asserted on because it has no other button
    /// in it, so "the header's one focus ring" is unambiguous there.
    func test_theChevronTakesAColdClickWithNoHoverFirst() async throws {
        let mount = try await mountTree()
        let research = try headerGeometry(.research, in: mount.window)
        XCTAssertTrue(mount.state.researchSectionExpanded, "premise: it opens open")

        let landed = await click(at: CGPoint(x: research.chevron.midX,
                                             y: research.chevron.midY),
                                 in: mount.window)
        XCTAssertTrue(landed, "the click reached no view at all")
        await pumpUntil(deadline: 5) { !mount.state.researchSectionExpanded }

        XCTAssertFalse(
            mount.state.researchSectionExpanded,
            "the first event this window ever saw was a click on the Research "
            + "chevron, and the section did not close — either nothing is drawn "
            + "there until the pointer arrives, or what is drawn is not wired to "
            + "the flag")
    }

    /// Both headers carry one, not just the one that was easiest to reach.
    func test_bothSectionsCarryAChevronThatTogglesTheirOwnFlag() async throws {
        let mount = try await mountTree()
        for section in [Section.research, .palette] {
            let geometry = try headerGeometry(section, in: mount.window)
            let before = mount.state.isExpanded(section)
            _ = await click(at: CGPoint(x: geometry.chevron.midX,
                                        y: geometry.chevron.midY),
                            in: mount.window)
            await pumpUntil(deadline: 5) { mount.state.isExpanded(section) != before }
            XCTAssertEqual(mount.state.isExpanded(section), !before,
                           "\(section)'s chevron did not toggle its own flag")
        }
    }

    // MARK: - No shift

    /// **The accessories do not move when the section opens and closes** — the
    /// pinnable half of "no layout shift on hover".
    ///
    /// A hover-revealed chevron is unobservable from a synthetic-event test
    /// (`NSTrackingArea` needs the window server to move a real pointer). What
    /// IS observable is the property that made the hover shift possible: an
    /// affordance whose presence is conditional takes its space when it arrives.
    /// Ours is unconditional, so the `+` menu and the Open Wall icon must sit at
    /// exactly the same x through a full open→closed→open cycle — including the
    /// closed state, which is the one the system chevron rendered differently.
    func test_theAccessoriesDoNotMoveAcrossAnExpansionCycle() async throws {
        let mount = try await mountTree()
        let open = try headerGeometry(.palette, in: mount.window)

        mount.state.paletteSectionExpanded = false
        await pumpUntil(deadline: 5) { self.rowCount(in: mount.window) < mount.rows }
        let closed = try headerGeometry(.palette, in: mount.window)

        mount.state.paletteSectionExpanded = true
        await pumpUntil(deadline: 5) { self.rowCount(in: mount.window) == mount.rows }
        let reopened = try headerGeometry(.palette, in: mount.window)

        for (state, geometry) in [("closed", closed), ("reopened", reopened)] {
            XCTAssertEqual(
                geometry.door.origin.x, open.door.origin.x, accuracy: 0.5,
                "\(state): the Open Wall icon moved from x=\(open.door.origin.x) "
                + "to x=\(geometry.door.origin.x). The whole point of drawing "
                + "our own chevron is that the header's trailing group is the "
                + "same width in every state")
            XCTAssertEqual(
                geometry.menu.origin.x, open.menu.origin.x, accuracy: 0.5,
                "\(state): the `+` menu moved from x=\(open.menu.origin.x) to "
                + "x=\(geometry.menu.origin.x)")
            XCTAssertEqual(
                geometry.chevron.origin.x, open.chevron.origin.x, accuracy: 0.5,
                "\(state): the chevron itself moved, so it is being laid out "
                + "differently open and closed")
        }
    }

    /// **Closing a section takes its rows and leaves its header** — the
    /// behaviour the conditional content has to reproduce, and the premise
    /// `ResearchSubjectRevealTests` already depends on (`open - 2` for a closed
    /// Research section holding two notes).
    func test_closingASectionHidesItsRowsAndKeepsItsHeader() async throws {
        let mount = try await mountTree()
        let headers = sectionHeaders(in: mount.window).count
        XCTAssertEqual(headers, 2, "premise: Research and Palette")

        mount.state.researchSectionExpanded = false
        await pumpUntil(deadline: 5) { self.rowCount(in: mount.window) < mount.rows }

        XCTAssertLessThan(rowCount(in: mount.window), mount.rows,
                          "closing the Research section drew the same number of "
                          + "rows — the content is not reading the flag")
        XCTAssertEqual(
            sectionHeaders(in: mount.window).count, headers,
            "a section whose content builder produces nothing lost its header "
            + "row — the chevron that reopens it went with it, and the writer "
            + "cannot get back in")
    }

    // MARK: - The chevron is a real target

    /// The door's own lesson, applied to the control beside it: a bare `Image`
    /// in a `Button(.plain)` hit-tests the box it draws in and nothing more, so
    /// the chevron gets the same explicit frame and content shape. Swept the way
    /// `PaletteWallDoorHitAreaTests` sweeps the door.
    func test_theWholeChevronIsClickableTopToBottom() async throws {
        let mount = try await mountTree()
        let research = try headerGeometry(.research, in: mount.window)

        var dead: [String] = []
        for (name, point) in [
            ("top", CGPoint(x: research.chevron.midX, y: research.chevron.minY + 0.5)),
            ("bottom", CGPoint(x: research.chevron.midX, y: research.chevron.maxY - 0.5)),
            ("left", CGPoint(x: research.chevron.minX + 0.5, y: research.chevron.midY)),
            ("right", CGPoint(x: research.chevron.maxX - 0.5, y: research.chevron.midY))
        ] {
            let before = mount.state.researchSectionExpanded
            _ = await click(at: point, in: mount.window)
            await pumpUntil(deadline: 2) {
                mount.state.researchSectionExpanded != before
            }
            if mount.state.researchSectionExpanded == before { dead.append(name) }
        }
        XCTAssertTrue(dead.isEmpty,
                      "\(dead) of the chevron's own \(research.chevron) did not "
                      + "toggle the section — the chevron has the door's bug")
    }

    /// **The chevron did not cost the header its height.** Same guard the door's
    /// frame has: both headers must stay the height the row can hold, or the two
    /// sections at the foot of every tree stop lining up.
    func test_theChevronDidNotGrowTheHeaderRows() async throws {
        let mount = try await mountTree()
        let heights = sectionHeaders(in: mount.window).map(\.frame.height)
        XCTAssertEqual(Set(heights).count, 1,
                       "the section headers are \(heights)pt tall — the "
                       + "chevron's frame has grown past what the row holds")
    }

    // MARK: - Reading the mounted tree

    enum Section: String, CustomStringConvertible {
        case research, palette
        var description: String { rawValue.capitalized }
    }

    /// A header's three trailing accessories, in `content` coordinates.
    private struct HeaderGeometry {
        /// The Open Wall icon. `.zero` in the Research header, which has none.
        let door: CGRect
        let menu: CGRect
        let chevron: CGRect
    }

    /// **Which header is which, without counting rows.** The Palette header is
    /// the one carrying two buttons (the door and the chevron); Research carries
    /// only its chevron. Derived rather than indexed, because the row a section
    /// lands on differs per project type and a hand-counted index is a fixture
    /// that goes quietly wrong (`BinderTreeMultiselectMountTests`' own lesson).
    private func headerGeometry(_ section: Section,
                                in window: NSWindow) throws -> HeaderGeometry {
        let content = try XCTUnwrap(window.contentView)
        var byHeader: [(header: NSView, rings: [CGRect], menu: CGRect?)] = []
        for header in sectionHeaders(in: window) {
            let kids = descendants(of: header)
            let rings = kids
                .filter { String(describing: type(of: $0)).contains("FocusRing") }
                .map { $0.convert($0.bounds, to: content) }
                .sorted { $0.minX < $1.minX }
            let menu = kids
                .first { String(describing: type(of: $0)).contains("SwiftUIPopupButton") }
                .map { $0.convert($0.bounds, to: content) }
            byHeader.append((header, rings, menu))
        }
        try XCTSkipUnless(byHeader.count == 2,
                          "this display mounted \(byHeader.count) section headers")

        let wanted = section == .palette
            ? byHeader.max(by: { $0.rings.count < $1.rings.count })
            : byHeader.min(by: { $0.rings.count < $1.rings.count })
        let hit = try XCTUnwrap(wanted)
        // **Asserted, not skipped.** This is a claim about what production
        // builds — Palette carries the door AND a chevron, Research a chevron
        // alone — rather than about what this display could afford, and the two
        // want different instruments. A skip here would let the whole suite go
        // quiet the day the chevrons came back out, which is the one day it
        // exists for.
        XCTAssertEqual(
            byHeader.map(\.rings.count).sorted(), [1, 2],
            "the two headers mounted \(byHeader.map(\.rings.count)) buttons; "
            + "Palette should carry the door and a chevron, Research a chevron")
        let menu = try XCTUnwrap(hit.menu, "\(section)'s header mounted no `+` menu")
        let chevron = try XCTUnwrap(hit.rings.last,
                                    "\(section)'s header mounted no chevron")
        return HeaderGeometry(
            door: section == .palette ? try XCTUnwrap(hit.rings.first) : .zero,
            menu: menu, chevron: chevron)
    }

    /// The system's hover chevrons for one header: `NSButton`s sitting beside
    /// the `ListTableHeaderView` in its row, which is where
    /// `Section(isExpanded:)` puts them and where ours — inside the header's own
    /// hosting view — never appears.
    private func systemChevrons(besideHeader header: NSView) -> [NSView] {
        (header.superview?.subviews ?? []).filter { $0 is NSButton }
    }

    private func sectionHeaders(in window: NSWindow) -> [NSView] {
        views(in: window).filter {
            String(describing: type(of: $0)).contains("ListTableHeaderView")
        }
    }

    private func rowCount(in window: NSWindow) -> Int {
        views(in: window).compactMap { $0 as? NSTableView }.first?.numberOfRows ?? 0
    }

    /// One click, and whether any view took it. In `content` coordinates.
    @discardableResult
    private func click(at point: CGPoint, in window: NSWindow) async -> Bool {
        guard let content = window.contentView else { return false }
        let inWindow = content.convert(point, to: nil)
        let landed = content.hitTest(inWindow) != nil
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
        pump(0.02)
        return landed
    }

    private func views(in window: NSWindow) -> [NSView] {
        guard let root = window.contentView else { return [] }
        return descendants(of: root)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    // MARK: - Hosting

    private struct Mount {
        let window: NSWindow
        let state: BinderTreeSectionsState
        /// The row count with both sections open, so a close is a comparison
        /// rather than a hard-coded delta.
        let rows: Int
    }

    /// A window over a view with no project behind it — the control's fixture.
    private func mountBare(_ root: AnyView) throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    private func mountTree() async throws -> Mount {
        let store = try await novel()
        let state = BinderTreeSectionsState()
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(rootView: AnyView(
            ChevronProbeView(store: store, treeState: state)))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.sectionHeaders(in: window).count == 2 }
        // The palette section loads its cards from disk once per manifest
        // change, so its rows arrive a turn after the headers do.
        pump(0.3)
        return Mount(window: window, state: state, rows: rowCount(in: window))
    }

    /// A novel with two notes and a card, so both sections have rows to lose
    /// when they close.
    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        for title in ["Ships", "Tides"] {
            _ = try await store.addResearchTextNote(parentId: nil, title: title)
        }
        _ = try await store.addPaletteCard(title: "A place", kind: .location)
        await store.wordCountPopulationTask?.value
        return store
    }
}

private extension BinderTreeSectionsState {
    func isExpanded(_ section: SectionChevronTests.Section) -> Bool {
        switch section {
        case .research: return researchSectionExpanded
        case .palette: return paletteSectionExpanded
        }
    }
}

// MARK: - Probes

/// The shape this fix removed: a `Section(isExpanded:)` header carrying the same
/// trailing accessory. Its hover chevron is what
/// `test_control_theProbeSeesTheSystemChevronWhenASectionStillHasOne` looks for.
@MainActor
private struct SystemChevronProbeView: View {
    @State private var expanded = true

    var body: some View {
        List {
            Section {
                Text("row")
            } header: {
                header("Plain")
            }
            Section(isExpanded: $expanded) {
                Text("row")
            } header: {
                header("Collapsible")
            }
        }
        .listStyle(.sidebar)
    }

    private func header(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: {}) {
                Image(systemName: "rectangle.grid.2x2")
            }
            .buttonStyle(.plain)
            SwiftUI.Menu {
                Button("New") {}
            } label: {
                Image(systemName: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contentShape(Rectangle())
    }
}

/// The real `BinderView` over a state the test holds, so expansion can be driven
/// from outside as well as clicked.
@MainActor
private struct ChevronProbeView: View {
    let store: ProjectStore
    let treeState: BinderTreeSectionsState
    @State private var subject: BinderSubject?

    var body: some View {
        BinderView(store: store, selectedSubject: $subject,
                   treeState: treeState,
                   canOpenPaletteWall: true,
                   onOpenPaletteWall: {})
    }
}
