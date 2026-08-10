import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The whole of the wall's door is clickable** — Denver's smoke, 2026-08-10:
/// the Palette header's "Open Wall" icon answered a click on its top half and
/// did nothing at all on its bottom.
///
/// **What was measured, before the fix.** A real `BinderView`, mounted, with
/// synthetic mouse events swept a point at a time down the icon's column: the
/// button's live region was **13×10pt sitting in the middle of a 19pt header
/// row**, against an icon whose own mounted frame is 15.5×12.5pt. A click in the
/// dead band did *nothing* — it did not open the wall and it did not toggle the
/// section either; the header's own `.contentShape(Rectangle())` swallowed it.
/// That is the "does nothing" the writer reported, and the reason it reads as a
/// half is that the band is a fraction of the row the eye takes for the target.
///
/// **The `isExpanded:` conversion was not the cause**, which is worth recording
/// because it is where the bug was first looked for (stage-3a Task 4 converted
/// both section headers, and the door demonstrably worked in the 2b smoke). A
/// plain `Section` header carrying an identical `Button(.plain) { Image(…) }`
/// measures the identical 10pt band — see
/// `test_control_aPlainSectionHeaderMeasuresTheSameLiveRegion`. The door has
/// always been this small.
///
/// **Why this suite drives real mouse events rather than `NSView.hitTest`.** The
/// brief asked for hit-testing, and the attempt is recorded here so the next
/// reader does not repeat it: every point across this header — over the icon,
/// over the title, over blank space — resolves to the one
/// `NSHostingView<…HeaderForSectionModifier>` that hosts the whole header.
/// SwiftUI does its own hit-testing *inside* that view, so a `Button(.plain)`
/// has no `NSView` of its own to resolve to and an AppKit hit test cannot tell
/// the door from the background it sits on. The `+` menu beside it is the
/// exception and the reason the distinction matters: `SwiftUI.Menu` mounts a
/// real `SwiftUIPopupButton`, which is why that accessory never had the defect.
///
/// So the instrument is the delivery path itself — `leftMouseDown`/`leftMouseUp`
/// through the window, the shape `ProjectAltitudeCentreTests` uses for the
/// corkboard card, which works because SwiftUI's hit-testing does not consult
/// `acceptsFirstMouse`. It is strictly stronger than a hit test: it asserts the
/// writer's click reaches the closure, not merely that a view is in front.
/// `test_control_theSweepCanSeeAMiss` is what keeps that from being vacuous.
@MainActor
final class PaletteWallDoorHitAreaTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // This suite mounts a tree that styles text through production
        // typography (the fontd cold-start window, CLAUDE.md).
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

    // MARK: - The door

    /// **Every point of the icon opens the wall, top edge to bottom edge.**
    ///
    /// The premise is read off the window this display actually granted, never
    /// off the window that was asked for (CI's screen is 1024pt wide and
    /// `NSWindow` clamps to it): the icon's own mounted frame comes from the
    /// `_FocusRingView` SwiftUI leaves for a `Button`, and the size a header
    /// accessory is *entitled* to comes from the `+` menu's real `NSView` beside
    /// it — so this asserts a relationship between two things in the mounted
    /// window rather than a number chosen here.
    func test_theWholeOpenWallIconOpensTheWall() async throws {
        let mount = try await mountTree()
        let door = try doorGeometry(in: mount.window)

        let measured = await liveBand(x: door.icon.midX, over: door.header,
                                      in: mount.window, counting: mount.opens)
        let band = try XCTUnwrap(
            measured, "no click anywhere down the icon's own column opened the wall")

        XCTAssertTrue(
            band.contains(door.icon.minY + 0.5) && band.contains(door.icon.maxY - 0.5),
            "the icon draws in \(door.icon) but only \(band) of that column "
            + "opens the wall — a click on its top or bottom edge does nothing "
            + "at all, which is the defect Denver reported as \"only the top "
            + "half works\"")
        // `band` is measured by sampling, so it can only bound the live region
        // from the inside: a region exactly `menu.height` tall reports one step
        // short of it, because the last sample inside sits a step below the
        // edge. The step is what that costs, spelled rather than absorbed into a
        // rounder number.
        XCTAssertGreaterThanOrEqual(
            band.length + Self.sweepStep, door.menu.height,
            "the door's live region is \(band.length)pt tall (swept at "
            + "\(Self.sweepStep)pt) against the `+` menu's \(door.menu.height)pt "
            + "beside it in the same header — two accessories on one row, one of "
            + "them a fraction of the target the other is")
    }

    /// The same claim across the icon, because the region was narrow as well as
    /// short (13pt against the icon's 15.5).
    func test_theWholeOpenWallIconIsLiveAcrossItsWidth() async throws {
        let mount = try await mountTree()
        let door = try doorGeometry(in: mount.window)

        var dead: [Double] = []
        for x in [door.icon.minX + 0.5, door.icon.midX, door.icon.maxX - 0.5] {
            let fired = await click(at: CGPoint(x: x, y: door.icon.midY),
                                    in: mount.window, counting: mount.opens)
            if !fired { dead.append(x) }
        }
        XCTAssertTrue(dead.isEmpty,
                      "x=\(dead) of the icon's own \(door.icon) did not open the "
                      + "wall — the door is narrower than the glyph it draws")
    }

    /// **The control that makes the two above mean something.** A sweep that
    /// fired on every click would pass them over any geometry at all; this one
    /// aims at the header's title, which is as far from the door as the row
    /// goes, and must reach nothing.
    func test_control_theSweepCanSeeAMiss() async throws {
        let mount = try await mountTree()
        let door = try doorGeometry(in: mount.window)

        let fired = await click(at: CGPoint(x: door.header.minX + 8,
                                            y: door.icon.midY),
                                in: mount.window, counting: mount.opens)
        XCTAssertFalse(fired,
                       "a click on the Palette header's own title opened the "
                       + "wall — this harness fires on any click at all, so "
                       + "nothing else in this suite is asserting anything")
    }

    /// **The Research header has no such defect, and its accessory is why.**
    ///
    /// Both headers were converted to `isExpanded:` together, so the sibling
    /// question is a fair one — but Research's only accessory is the same `+`
    /// `SwiftUI.Menu` the Palette header carries, and a `Menu` mounts a real
    /// `SwiftUIPopupButton` whose whole frame hit-tests. Asserted at the `NSView`
    /// level, which is exactly the instrument the door itself could not be
    /// measured with: every point down the popup's own column resolves to the
    /// popup, edge to edge.
    func test_theResearchHeadersPlusMenuIsLiveAcrossItsWholeFrame() async throws {
        let mount = try await mountTree()
        let content = try XCTUnwrap(mount.window.contentView)
        let popups = views(in: mount.window).filter {
            String(describing: type(of: $0)).contains("SwiftUIPopupButton")
        }
        try XCTSkipUnless(popups.count >= 2,
                          "this display mounted \(popups.count) section-header "
                          + "menus; the tree carries one per section")

        for popup in popups {
            let frame = popup.convert(popup.bounds, to: content)
            for y in [frame.minY + 0.5, frame.midY, frame.maxY - 0.5] {
                let point = content.convert(CGPoint(x: frame.midX, y: y), to: nil)
                let hit = content.hitTest(point)
                XCTAssertTrue(
                    hit === popup || hit?.isDescendant(of: popup) == true,
                    "y=\(y) of the `+` menu's own \(frame) hit-tests to "
                    + "\(hit.map { String(describing: type(of: $0)) } ?? "nothing") "
                    + "— the menus are the accessories that were never in doubt, "
                    + "so a failure here means the header's layout moved and the "
                    + "door's fix was measured against the wrong thing")
            }
        }
    }

    /// **The door grew its target without moving the row it sits in.**
    ///
    /// The fix gives the button the `+` menu's own 21×15pt frame; this is the
    /// guard that the frame stays something the header row can hold, so the
    /// Palette header keeps lining up with the Research one above it — the two
    /// sit at the foot of every tree in the app, and a header a few points
    /// taller than its neighbour is visible on every screen.
    ///
    /// **Where its edge actually is, measured rather than assumed.** A planted
    /// 19pt button leaves every header the same height and this test passes; a
    /// planted 30pt one grows the row and it fails. So 15 is a match with the
    /// menu rather than a cliff, and this guard has slack — which is worth
    /// knowing before reading a green run here as "the frame cannot change".
    /// Read as a relationship between the rows this window actually mounted
    /// rather than against 19.
    func test_theDoorDidNotGrowThePaletteHeaderPastTheResearchOne() async throws {
        let mount = try await mountTree()
        let content = try XCTUnwrap(mount.window.contentView)
        let headers = views(in: mount.window)
            .filter { String(describing: type(of: $0)).contains("ListTableHeaderView") }
            .map { $0.convert($0.bounds, to: content) }
        try XCTSkipUnless(headers.count >= 2,
                          "this display mounted \(headers.count) section headers; "
                          + "every tree carries Research and Palette")
        XCTAssertEqual(
            Set(headers.map(\.height)).count, 1,
            "the tree's section headers are \(headers.map(\.height))pt tall — the "
            + "door's frame has grown past what the row can hold, so the Palette "
            + "header no longer lines up with the Research one above it")
    }

    // MARK: - Where the defect did NOT come from

    /// **A plain `Section` header measures the same live region**, which is what
    /// clears stage-3a Task 4's `isExpanded:` conversion of having caused this.
    ///
    /// Two headers in one `List`, identical but for the binding, each carrying
    /// the shape `openWallButton` had *before* the fix — a bare `Image` in a
    /// `Button(.plain)`. If the collapsible conversion were the cause the two
    /// bands would differ; measured on this SDK they are the same 10pt.
    ///
    /// The old shape is spelled out here rather than reached for, deliberately:
    /// this is a record of a defect that no longer exists in production, and a
    /// test that imported the fixed button could not say anything about it.
    func test_control_aPlainSectionHeaderMeasuresTheSameLiveRegion() async throws {
        let box = HeaderShapeBox()
        let mount = try mount(AnyView(HeaderShapeProbeView(box: box)),
                              opens: Counter())
        await waitOut(0.5)
        let content = try XCTUnwrap(mount.window.contentView)
        let rings = views(in: mount.window)
            .filter { String(describing: type(of: $0)).contains("FocusRing") }
            .map { $0.convert($0.bounds, to: content) }
            .sorted { $0.minY < $1.minY }
        try XCTSkipUnless(rings.count == 2,
                          "this display mounted \(rings.count) buttons for two "
                          + "headers")

        var bands: [ClosedRange<Double>?] = []
        for (ring, counter) in zip(rings, [box.plain, box.collapsible]) {
            let column = CGRect(x: ring.minX, y: ring.minY - 6,
                                width: ring.width, height: ring.height + 12)
            bands.append(await liveBand(x: ring.midX, over: column,
                                        in: mount.window, counting: counter))
        }
        let plain = try XCTUnwrap(bands[0], "the plain header's button never fired")
        let collapsible = try XCTUnwrap(bands[1],
                                        "the collapsible header's button never fired")
        XCTAssertEqual(
            plain.length, collapsible.length, accuracy: 1,
            "a plain `Section` header's button is live over \(plain.length)pt and "
            + "a collapsible one's over \(collapsible.length)pt. They matched when "
            + "this was written, which is what cleared the `isExpanded:` "
            + "conversion of causing the door's dead band — if they have come "
            + "apart, the conversion HAS grown a hit-geometry cost and "
            + "`openWallButton`'s doc comment is now wrong")
    }

    // MARK: - Driving

    private struct Mount {
        let window: NSWindow
        let opens: Counter
    }

    /// The button's mounted geometry, and the header it lives in.
    private struct Door {
        /// The icon's own frame — the `_FocusRingView` SwiftUI leaves for a
        /// `Button`, which is the only `NSView` trace a `Button(.plain)` has.
        let icon: CGRect
        /// The `+` menu beside it: a real `SwiftUIPopupButton`, and the size a
        /// header accessory in this row is entitled to.
        let menu: CGRect
        let header: CGRect
    }

    private func doorGeometry(in window: NSWindow) throws -> Door {
        let content = try XCTUnwrap(window.contentView)
        let ring = try XCTUnwrap(
            views(in: window).first {
                String(describing: type(of: $0)).contains("FocusRing")
            },
            "no focus ring mounted, so the Palette header's `Button` left no "
            + "`NSView` trace to read its frame from. Views: "
            + "\(views(in: window).map { String(describing: type(of: $0)) })")
        // The header this button is in — the Research header carries a menu too,
        // and measuring the door against the wrong one would be measuring
        // nothing.
        var header: NSView? = ring.superview
        while let candidate = header,
              !String(describing: type(of: candidate)).contains("ListTableHeaderView") {
            header = candidate.superview
        }
        let headerView = try XCTUnwrap(header, "the button is not in a section header")
        let menu = try XCTUnwrap(
            descendants(of: headerView).first {
                String(describing: type(of: $0)).contains("SwiftUIPopupButton")
            },
            "the Palette header mounted no `+` menu to size the door against")
        let door = Door(icon: ring.convert(ring.bounds, to: content),
                        menu: menu.convert(menu.bounds, to: content),
                        header: headerView.convert(headerView.bounds, to: content))
        // The premise, off the window this display granted rather than the one
        // asked for: a header clamped to nothing cannot be asked where its
        // clickable parts are.
        try XCTSkipUnless(door.icon.height > 1 && door.menu.height > 1
                            && door.header.width > 100,
                          "this display mounted an icon of \(door.icon.size) and "
                          + "a header of \(door.header.size)")
        return door
    }

    /// How finely the sweeps sample. The measured band is always up to one step
    /// narrower than the real live region — see the assertion in
    /// `test_theWholeOpenWallIconOpensTheWall`.
    private static let sweepStep = 0.5

    /// The contiguous run of y values at `x` that reach `counter`, swept a
    /// `sweepStep` at a time over `column`.
    ///
    /// `counter` rather than the mount's own, because the control below sweeps
    /// two buttons in one window and has to tell them apart.
    private func liveBand(x: Double, over column: CGRect, in window: NSWindow,
                          counting counter: Counter) async -> ClosedRange<Double>? {
        var low: Double?
        var high: Double?
        for y in stride(from: column.minY - 2, through: column.maxY + 2,
                        by: Self.sweepStep) {
            guard await click(at: CGPoint(x: x, y: y), in: window,
                              counting: counter) else { continue }
            if low == nil { low = y }
            high = y
        }
        guard let low, let high else { return nil }
        return low...high
    }

    /// One click, and whether it reached `counter`. In `content` coordinates.
    private func click(at point: CGPoint, in window: NSWindow,
                       counting counter: Counter) async -> Bool {
        guard let content = window.contentView else { return false }
        let before = counter.count
        let inWindow = content.convert(point, to: nil)
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
        pump(0.01)
        return counter.count > before
    }

    // MARK: - Hosting

    private func mountTree() async throws -> Mount {
        let store = try await novel()
        let opens = Counter()
        let mount = try mount(AnyView(DoorHitAreaProbeView(
            store: store, onOpenPaletteWall: { opens.count += 1 })), opens: opens)
        await pumpUntil(deadline: 5) { self.firstTableView(in: mount.window) != nil }
        // The palette section loads its cards from disk once per manifest
        // change, so the section settles a turn after the table arrives.
        pump(0.3)
        return mount
    }

    private func mount(_ root: AnyView, opens: Counter) throws -> Mount {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return Mount(window: window, opens: opens)
    }

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

    // MARK: - Reading the hierarchy

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        views(in: window).compactMap { $0 as? NSTableView }.first
    }

    private func views(in window: NSWindow) -> [NSView] {
        guard let root = window.contentView else { return [] }
        return descendants(of: root)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

private extension ClosedRange where Bound == Double {
    var length: Double { upperBound - lowerBound }
}

// MARK: - Probes

/// How many times the door opened. A class, because the closure the tree calls
/// escapes into a SwiftUI view.
@MainActor
final class Counter {
    var count = 0
    init() {}
}

/// The real `BinderView` with the door wired to a counter — `PaletteWallDoorTests
/// .DoorProbeView`'s shape, kept separate because that suite drives the
/// accessibility tree and this one drives the mouse.
@MainActor
private struct DoorHitAreaProbeView: View {
    let store: ProjectStore
    let onOpenPaletteWall: () -> Void
    @State private var subject: BinderSubject?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        BinderView(store: store, selectedSubject: $subject,
                   treeState: treeState,
                   canOpenPaletteWall: true,
                   onOpenPaletteWall: onOpenPaletteWall)
    }
}

@MainActor
final class HeaderShapeBox {
    let plain = Counter()
    let collapsible = Counter()
    init() {}
}

/// Two section headers, identical but for the `isExpanded:` binding, each
/// carrying the button shape `openWallButton` had before the fix. See
/// `test_control_aPlainSectionHeaderMeasuresTheSameLiveRegion`.
@MainActor
private struct HeaderShapeProbeView: View {
    let box: HeaderShapeBox
    @State private var expanded = true

    var body: some View {
        List {
            Section {
                Text("row")
            } header: {
                header("Plain") { box.plain.count += 1 }
            }
            Section(isExpanded: $expanded) {
                Text("row")
            } header: {
                header("Collapsible") { box.collapsible.count += 1 }
            }
        }
        .listStyle(.sidebar)
    }

    private func header(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) {
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
