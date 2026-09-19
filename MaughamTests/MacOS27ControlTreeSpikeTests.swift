import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// **SPIKE (Task 2, macOS 27 shell slice) — what a mounted SwiftUI `Picker` and
/// `Menu` publish, in the view hierarchy and in the accessibility tree.**
///
/// Nothing here asserts. Every case dumps and skips; the dumps are the output,
/// and they are in
/// `docs/superpowers/notes/2026-09-19-split-view-tie-break-spike.md`'s
/// *The accessibility tree on 27* section. Delete this file when Task 4 lands
/// its rule.
///
/// **It is off unless asked for.** A suite with no assertions has nothing to
/// say in a gate, and these cases mount eight windows and drive several hundred
/// synthetic clicks. `MAUGHAM_SPIKE=1` runs it; every other run skips by name,
/// so the evidence stays reproducible without costing the gate:
///
/// ```
/// MAUGHAM_SPIKE=1 xcodebuild -project Maugham.xcodeproj -scheme Maugham \
///   -only-testing:MaughamTests/MacOS27ControlTreeSpikeTests test \
///   CODE_SIGNING_ALLOWED=NO
/// # dumps land in $TMPDIR/maugham-ax-spike.txt
/// ```
@MainActor
final class MacOS27ControlTreeSpikeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_SPIKE"] == "1",
            "the macOS 27 control-tree spike runs only under MAUGHAM_SPIKE=1 — "
            + "it asserts nothing, and its findings are in "
            + "docs/superpowers/notes/2026-09-19-split-view-tie-break-spike.md")
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    /// Where the dumps land. `print` goes to the xctest process's stdout, which
    /// `xcodebuild` swallows into the xcresult; a file is readable.
    private static let sink: URL = {
        let path = ProcessInfo.processInfo.environment["MAUGHAM_SPIKE_DUMP"]
            ?? NSTemporaryDirectory() + "maugham-ax-spike.txt"
        return URL(fileURLWithPath: path)
    }()

    private func record(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: Self.sink) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.sink)
        }
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp?.cleanup()
        temp = nil
    }

    // MARK: - The environment this was measured in

    func test_dump_theToolchainAndTheDisplay() throws {
        let info = ProcessInfo.processInfo
        record("""

        ### environment
        os: \(info.operatingSystemVersionString)
        assistive client attachable: \(assistiveClientAttachable())
        main screen: \(NSScreen.main?.frame.size.debugDescription ?? "none")
        """)
    }

    // MARK: - 1. The pass ladder (`Picker(.menu)` in a plain VStack)

    func test_dump_thePieceInspectorsLadder() async throws {
        let (store, ds, piece) = try await collection()
        documentStores.append(ds)
        let window = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)), size: CGSize(width: 420, height: 700))
        await waitOut(0.6)

        record("\n### PieceInspector — NSView hierarchy")
        record(viewDump(window))
        record("\n### PieceInspector — NSPopUpButton census")
        record(popupCensus(window))
        record("\n### PieceInspector — accessibility tree")
        record(try axDump(window))
    }

    /// The document arm — the ladder inside `Form(.grouped)`.
    func test_dump_theDocumentInspectorsLadder() async throws {
        let (store, ds, item) = try await novel()
        documentStores.append(ds)
        let window = mount(AnyView(InspectorView(
            store: store,
            selectedItemId: item.id,
            metrics: EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0),
            onOpenProjectSettings: {})), size: CGSize(width: 420, height: 900))
        await waitOut(0.8)

        record("\n### InspectorView — NSPopUpButton census")
        record(popupCensus(window))
        record("\n### InspectorView — accessibility tree")
        record(try axDump(window))
    }

    /// The bare control, with nothing else in the window — the cleanest read of
    /// what `Picker(.menu)` is on this SDK.
    func test_dump_aBarePickerMenu() async throws {
        let window = mount(AnyView(BarePickerProbe()), size: CGSize(width: 320, height: 200))
        await waitOut(0.5)

        record("\n### bare Picker(.menu) — NSView hierarchy")
        record(viewDump(window))
        record("\n### bare Picker(.menu) — NSPopUpButton census")
        record(popupCensus(window))
        record("\n### bare Picker(.menu) — accessibility tree")
        record(try axDump(window))
    }

    // MARK: - 2. The admission sheet (`Menu(.borderlessButton)`)

    func test_dump_theAdmissionSheet() async throws {
        let request = AdmissionRequest(
            fingerprint: "ffff2222", ownName: "Denver’s iPhone",
            code: DeviceCode.short("ffff2222"), waitingCount: 14,
            proposedLabel: "Denver’s iPhone", knownLabels: ["Amelia", "Denver"])
        let window = mount(AnyView(AdmissionSheet(
            request: request, projectTitle: "Playlist", refusal: nil,
            onAdmit: { _ in }, onNotNow: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 520, height: 400))
        await waitOut(0.5)

        record("\n### AdmissionSheet — NSView hierarchy")
        record(viewDump(window))
        record("\n### AdmissionSheet — accessibility tree")
        record(try axDump(window))
        record("\n### AdmissionSheet — axTexts (what the failing assertion reads)")
        record(try axTexts(in: window).map { "  · \($0)" }.joined(separator: "\n"))
    }

    /// The same menu with nothing around it.
    func test_dump_aBareBorderlessMenu() async throws {
        let window = mount(AnyView(BareMenuProbe()), size: CGSize(width: 320, height: 200))
        await waitOut(0.5)

        record("\n### bare Menu(.borderlessButton) with .accessibilityLabel — NSView hierarchy")
        record(viewDump(window))
        record("\n### bare Menu(.borderlessButton) — accessibility tree")
        record(try axDump(window))
    }

    // MARK: - 3. The tree's section headers

    func test_dump_theTreesSectionHeaders() async throws {
        let store = try await treeProject()
        let state = BinderTreeSectionsState()
        let box = SpikeCounter()
        let window = mount(AnyView(SpikeTreeProbe(
            store: store, treeState: state, onOpenPaletteWall: { box.count += 1 })),
            size: CGSize(width: 320, height: 600))
        await pumpUntil(deadline: 5) { self.headerViews(in: window).count == 2 }
        pump(0.4)

        record("\n### BinderView section headers — the header ROWS, full subtree")
        let content = try XCTUnwrap(window.contentView)
        for header in headerViews(in: window) {
            let row = header.superview
            record("— header \(describe(header, in: content))")
            record("  row: \(row.map { describe($0, in: content) } ?? "none")")
            if let row {
                record(viewDump(root: row, in: content, indent: 4))
            }
        }
        record("\n### BinderView — FocusRing census (what the two suites find the chevron by)")
        for view in allViews(in: window)
        where String(describing: type(of: view)).contains("FocusRing") {
            record("  \(describe(view, in: content))")
        }
        record("\n### BinderView — accessibility tree (buttons only)")
        for element in try axElements(in: window) {
            guard let role = axAttribute(element, "accessibilityRole") as? String,
                  role.contains("Button") || role.contains("Disclosure") else { continue }
            record("  " + axLine(element))
        }

        // The delivery path the two red tests use, measured.
        record("\n### the click the red tests send, per header accessory")
        for header in headerViews(in: window) {
            let rings = descendants(of: header)
                .filter { String(describing: type(of: $0)).contains("FocusRing") }
                .sorted { $0.convert($0.bounds, to: content).minX
                          < $1.convert($1.bounds, to: content).minX }
            record("  header at \(header.convert(header.bounds, to: content)): "
                  + "\(rings.count) rings")
            for ring in rings {
                let frame = ring.convert(ring.bounds, to: content)
                let point = content.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
                let hit = content.hitTest(point)
                record("    ring \(frame) -> hitTest \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
            }
        }
        _ = box
    }

    /// `SectionChevronTests.test_bothSectionsCarryAChevronThatTogglesTheirOwnFlag`,
    /// replayed with the geometry printed at every step — Research's chevron
    /// fires and Palette's does not, and this says where the two clicks land.
    func test_dump_theBothSectionsChevronSweep() async throws {
        let store = try await treeProject()
        let state = BinderTreeSectionsState()
        let window = mount(AnyView(SpikeTreeProbe(
            store: store, treeState: state, onOpenPaletteWall: {})),
            size: CGSize(width: 320, height: 600))
        await pumpUntil(deadline: 5) { self.headerViews(in: window).count == 2 }
        pump(0.4)
        let content = try XCTUnwrap(window.contentView)

        func rings() -> [(header: CGRect, rings: [CGRect])] {
            headerViews(in: window).map { header in
                (header.convert(header.bounds, to: content),
                 descendants(of: header)
                    .filter { String(describing: type(of: $0)).contains("FocusRing") }
                    .map { $0.convert($0.bounds, to: content) }
                    .sorted { $0.minX < $1.minX })
            }
        }

        record("\n### the bothSections sweep, step by step")
        record("  start: research=\(state.researchSectionExpanded) "
               + "palette=\(state.paletteSectionExpanded)")
        record("  geometry: \(rings())")

        // Step 1 — Research (the one that passes).
        let research = try XCTUnwrap(rings().min(by: { $0.rings.count < $1.rings.count }))
        let researchChevron = try XCTUnwrap(research.rings.last)
        record("  click Research chevron at \(researchChevron)")
        sendClick(at: CGPoint(x: researchChevron.midX, y: researchChevron.midY), in: window)
        await pumpUntil(deadline: 5) { !state.researchSectionExpanded }
        record("  after: research=\(state.researchSectionExpanded)")
        record("  geometry IMMEDIATELY after the pumpUntil returns: \(rings())")
        pump(0.5)
        record("  geometry after a further 0.5s pump:              \(rings())")

        // Step 2 — Palette (the one that fails). Both readings, so the note can
        // say which one the red test was clicking into.
        let palette = try XCTUnwrap(rings().max(by: { $0.rings.count < $1.rings.count }))
        let paletteChevron = try XCTUnwrap(palette.rings.last)
        record("  click Palette chevron at \(paletteChevron) "
               + "(palette=\(state.paletteSectionExpanded))")
        sendClick(at: CGPoint(x: paletteChevron.midX, y: paletteChevron.midY), in: window)
        await pumpUntil(deadline: 3) { !state.paletteSectionExpanded }
        record("  after: palette=\(state.paletteSectionExpanded)")

        // And a sweep down the Palette chevron's whole column, to see whether
        // ANY y in it is live.
        var live: [Double] = []
        for y in stride(from: paletteChevron.minY - 8, through: paletteChevron.maxY + 8, by: 0.5) {
            let before = state.paletteSectionExpanded
            sendClick(at: CGPoint(x: paletteChevron.midX, y: y), in: window)
            pump(0.02)
            if state.paletteSectionExpanded != before { live.append(y) }
        }
        record("  live y down the Palette chevron column: \(live)")
        record("  final geometry: \(rings())")
    }

    /// The same two chevrons with NO prior click — does Palette's fire when it
    /// is the first thing the window is asked to do?
    func test_dump_thePaletteChevronAlone() async throws {
        let store = try await treeProject()
        let state = BinderTreeSectionsState()
        let window = mount(AnyView(SpikeTreeProbe(
            store: store, treeState: state, onOpenPaletteWall: {})),
            size: CGSize(width: 320, height: 600))
        await pumpUntil(deadline: 5) { self.headerViews(in: window).count == 2 }
        pump(0.4)
        let content = try XCTUnwrap(window.contentView)
        let headers = headerViews(in: window).map { header in
            (descendants(of: header)
                .filter { String(describing: type(of: $0)).contains("FocusRing") }
                .map { $0.convert($0.bounds, to: content) }
                .sorted { $0.minX < $1.minX })
        }
        let palette = try XCTUnwrap(headers.max(by: { $0.count < $1.count }))
        let chevron = try XCTUnwrap(palette.last)
        let door = try XCTUnwrap(palette.first)
        record("\n### the Palette chevron with nothing clicked before it")
        record("  door=\(door) chevron=\(chevron) palette=\(state.paletteSectionExpanded)")
        sendClick(at: CGPoint(x: chevron.midX, y: chevron.midY), in: window)
        await pumpUntil(deadline: 3) { !state.paletteSectionExpanded }
        record("  after one click at the chevron's centre: palette=\(state.paletteSectionExpanded)")
    }

    /// Palette's chevron, clicked repeatedly at one point, with the flag
    /// sampled after each — the door beside it is clicked first as a control.
    func test_dump_thePaletteChevronRepeated() async throws {
        let store = try await treeProject()
        let state = BinderTreeSectionsState()
        let opened = SpikeCounter()
        let window = mount(AnyView(SpikeTreeProbe(
            store: store, treeState: state, onOpenPaletteWall: { opened.count += 1 })),
            size: CGSize(width: 320, height: 600))
        await pumpUntil(deadline: 5) { self.headerViews(in: window).count == 2 }
        pump(0.4)
        let content = try XCTUnwrap(window.contentView)

        func paletteRings() -> [CGRect] {
            headerViews(in: window).map { header in
                descendants(of: header)
                    .filter { String(describing: type(of: $0)).contains("FocusRing") }
                    .map { $0.convert($0.bounds, to: content) }
                    .sorted { $0.minX < $1.minX }
            }.max(by: { $0.count < $1.count }) ?? []
        }

        record("\n### Palette's chevron, clicked ten times at one point")
        let rings = paletteRings()
        record("  rings=\(rings)")
        let door = try XCTUnwrap(rings.first)
        let chevron = try XCTUnwrap(rings.last)

        sendClick(at: CGPoint(x: door.midX, y: door.midY), in: window)
        record("  control — one click on the DOOR: opens=\(opened.count)")

        for attempt in 1...10 {
            let before = state.paletteSectionExpanded
            sendClick(at: CGPoint(x: chevron.midX, y: chevron.midY), in: window)
            let immediately = state.paletteSectionExpanded
            pump(0.05)
            let after50 = state.paletteSectionExpanded
            await pumpUntil(deadline: 0.5) { state.paletteSectionExpanded != before }
            record("  attempt \(attempt) at \(chevron): before=\(before) "
                   + "immediately=\(immediately) after50ms=\(after50) "
                   + "afterPump=\(state.paletteSectionExpanded) "
                   + "rings now \(paletteRings())")
        }
    }

    /// The decisive one: the Palette chevron clicked five times with NOTHING
    /// clicked before it, and the whole tree's accessibility tree beside it.
    func test_dump_thePaletteChevronCold() async throws {
        let store = try await treeProject()
        let state = BinderTreeSectionsState()
        let window = mount(AnyView(SpikeTreeProbe(
            store: store, treeState: state, onOpenPaletteWall: {})),
            size: CGSize(width: 320, height: 600))
        await pumpUntil(deadline: 5) { self.headerViews(in: window).count == 2 }
        pump(0.4)
        let content = try XCTUnwrap(window.contentView)
        let rings = headerViews(in: window).map { header in
            descendants(of: header)
                .filter { String(describing: type(of: $0)).contains("FocusRing") }
                .map { $0.convert($0.bounds, to: content) }
                .sorted { $0.minX < $1.minX }
        }
        let chevron = try XCTUnwrap((rings.max(by: { $0.count < $1.count }) ?? []).last)

        record("\n### Palette's chevron, five clicks, NOTHING clicked before")
        for attempt in 1...5 {
            let before = state.paletteSectionExpanded
            sendClick(at: CGPoint(x: chevron.midX, y: chevron.midY), in: window)
            record("  attempt \(attempt): before=\(before) "
                   + "after=\(state.paletteSectionExpanded) "
                   + "fired=\(state.paletteSectionExpanded != before)")
        }

        record("\n### BinderView — the WHOLE accessibility tree")
        record(try axDump(window))
    }

    /// **Does an `accessibilityIdentifier` reach these two controls on 27?**
    /// If it does, Task 4 has a hook that needs no sibling-label arithmetic.
    func test_dump_identifiersOnAPickerAndAMenu() async throws {
        let window = mount(AnyView(IdentifiedControlsProbe()),
                           size: CGSize(width: 360, height: 300))
        await waitOut(0.6)

        record("\n### identifiers — NSView hierarchy")
        record(viewDump(window))
        record("\n### identifiers — accessibility tree")
        record(try axDump(window))
    }

    /// The proposed re-derivation, measured: each section's chevron clicked in
    /// a window of its own, so no click follows another click's relayout.
    func test_dump_eachChevronInItsOwnWindow() async throws {
        record("\n### each chevron clicked in a freshly mounted window")
        for wanted in ["research", "palette"] {
            let store = try await treeProject()
            let state = BinderTreeSectionsState()
            let window = mount(AnyView(SpikeTreeProbe(
                store: store, treeState: state, onOpenPaletteWall: {})),
                size: CGSize(width: 320, height: 600))
            await pumpUntil(deadline: 5) { self.headerViews(in: window).count == 2 }
            pump(0.4)
            let content = try XCTUnwrap(window.contentView)
            let byHeader = headerViews(in: window).map { header in
                descendants(of: header)
                    .filter { String(describing: type(of: $0)).contains("FocusRing") }
                    .map { $0.convert($0.bounds, to: content) }
                    .sorted { $0.minX < $1.minX }
            }
            let rings = wanted == "palette"
                ? byHeader.max(by: { $0.count < $1.count })
                : byHeader.min(by: { $0.count < $1.count })
            let chevron = try XCTUnwrap((rings ?? []).last)
            let before = wanted == "palette"
                ? state.paletteSectionExpanded : state.researchSectionExpanded
            sendClick(at: CGPoint(x: chevron.midX, y: chevron.midY), in: window)
            await pumpUntil(deadline: 3) {
                (wanted == "palette" ? state.paletteSectionExpanded
                                     : state.researchSectionExpanded) != before
            }
            let after = wanted == "palette"
                ? state.paletteSectionExpanded : state.researchSectionExpanded
            record("  \(wanted): chevron=\(chevron) before=\(before) after=\(after) "
                   + "fired=\(after != before)")
        }
    }

    /// Can the mounted ladder be DRIVEN at all on 27 — what actions does its
    /// node expose, and does `accessibilityPerformPress` reach it?
    func test_dump_canTheLadderBeDriven() async throws {
        let (store, ds, piece) = try await collection()
        documentStores.append(ds)
        let window = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)), size: CGSize(width: 420, height: 700))
        await waitOut(0.6)

        record("\n### can the ladder be driven?")
        for element in try axElements(in: window) {
            guard (axAttribute(element, "accessibilityRole") as? String) == "AXPopUpButton"
            else { continue }
            let actions = axAttribute(element, "accessibilityActionNames") as? [String]
            record("  \(type(of: element)) value="
                   + "\(String(describing: axAttribute(element, "accessibilityValue"))) "
                   + "actions=\(actions ?? []) "
                   + "respondsToPress="
                   + "\((element as? NSObject)?.responds(to: NSSelectorFromString("accessibilityPerformPress")) ?? false) "
                   + "children=\(axAttribute(element, "accessibilityChildren") as? [AnyObject] ?? [])")
        }
    }

    /// What TYPE the menu's title comes back as — the reason `axTexts`' `as?
    /// String` cannot see it.
    func test_dump_theMenuTitlesType() async throws {
        let window = mount(AnyView(BareMenuProbe()), size: CGSize(width: 320, height: 200))
        await waitOut(0.5)
        record("\n### the menu's title, by type")
        for element in try axElements(in: window) {
            guard (axAttribute(element, "accessibilityRole") as? String) == "AXMenuButton"
            else { continue }
            for key in ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"] {
                let raw = axAttribute(element, key)
                record("  \(key): type=\(raw.map { String(describing: type(of: $0)) } ?? "nil") "
                       + "asString=\(raw as? String ?? "<not a String>") "
                       + "asAttributed=\((raw as? NSAttributedString)?.string ?? "<not attributed>")")
            }
        }
    }

    /// The control probe the two red suites mount: two `Section`s in a bare
    /// `List`, one plain and one `isExpanded:`, each carrying a
    /// `Button(.plain) { Image }`. This is the fixture whose buttons "never
    /// fired".
    func test_dump_theHeaderShapeControlProbe() async throws {
        let box = SpikeHeaderBox()
        let window = mount(AnyView(SpikeHeaderShapeProbe(box: box)),
                           size: CGSize(width: 320, height: 400))
        await waitOut(0.8)
        let content = try XCTUnwrap(window.contentView)

        record("\n### control probe — NSView hierarchy")
        record(viewDump(window))
        record("\n### control probe — FocusRing census")
        let rings = allViews(in: window)
            .filter { String(describing: type(of: $0)).contains("FocusRing") }
            .map { $0.convert($0.bounds, to: content) }
            .sorted { $0.minY < $1.minY }
        record("  \(rings)")

        // Sweep exactly the way the red test sweeps, and report every y.
        for (index, ring) in rings.enumerated() {
            let counter = index == 0 ? box.plain : box.collapsible
            var live: [Double] = []
            for y in stride(from: ring.minY - 8, through: ring.maxY + 8, by: 0.5) {
                let before = counter.count
                sendClick(at: CGPoint(x: ring.midX, y: y), in: window)
                if counter.count > before { live.append(y) }
            }
            record("  ring \(index) \(ring): live y values \(live)")
        }
        record("\n### control probe — accessibility tree")
        record(try axDump(window))
    }

    // MARK: - Dumping

    private func assistiveClientAttachable() -> String {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        return "error=\(error.rawValue) role=\(role.map { String(describing: $0) } ?? "nil")"
    }

    private func viewDump(_ window: NSWindow) -> String {
        guard let content = window.contentView else { return "  <no content view>" }
        return viewDump(root: content, in: content, indent: 2)
    }

    private func viewDump(root: NSView, in content: NSView, indent: Int) -> String {
        var out: [String] = []
        func walk(_ view: NSView, _ depth: Int) {
            out.append(String(repeating: " ", count: indent + depth * 2)
                       + describe(view, in: content))
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        walk(root, 0)
        return out.joined(separator: "\n")
    }

    private func describe(_ view: NSView, in content: NSView) -> String {
        let frame = view.convert(view.bounds, to: content)
        var bits = ["\(type(of: view))",
                    "frame=\(short(frame))",
                    "hidden=\(view.isHidden)"]
        if let control = view as? NSControl {
            bits.append("enabled=\(control.isEnabled)")
            if !control.stringValue.isEmpty { bits.append("string=\u{201C}\(control.stringValue)\u{201D}") }
        }
        if let popup = view as? NSPopUpButton {
            bits.append("items=\(popup.itemTitles)")
            bits.append("title=\u{201C}\(popup.title)\u{201D}")
            bits.append("delegate=\(String(describing: popup.menu?.delegate))")
        }
        let identifier = view.accessibilityIdentifier()
        if !identifier.isEmpty { bits.append("axid=\u{201C}\(identifier)\u{201D}") }
        if let role = view.accessibilityRole()?.rawValue { bits.append("axrole=\(role)") }
        if let label = view.accessibilityLabel(), !label.isEmpty {
            bits.append("axlabel=\u{201C}\(label)\u{201D}")
        }
        return bits.joined(separator: " ")
    }

    private func short(_ rect: CGRect) -> String {
        func n(_ value: Double) -> String { String(format: "%.1f", value) }
        return "(\(n(rect.minX)),\(n(rect.minY)) \(n(rect.width))×\(n(rect.height)))"
    }

    private func popupCensus(_ window: NSWindow) -> String {
        var popups: [NSPopUpButton] = []
        if let root = window.contentView { collect(NSPopUpButton.self, in: root, into: &popups) }
        guard !popups.isEmpty else {
            return "  ZERO NSPopUpButton in the whole window "
                + "(this is what `ladderPopups` returns, and why the six reds fail)"
        }
        return popups.map {
            "  \(type(of: $0)) items=\($0.itemTitles) title=\u{201C}\($0.title)\u{201D} "
            + "delegate=\(String(describing: $0.menu?.delegate))"
        }.joined(separator: "\n")
    }

    private func axDump(_ window: NSWindow) throws -> String {
        try requireAssistiveClient()
        guard let content = window.contentView else { return "  <no content view>" }
        var out: [String] = []
        func walk(_ element: AnyObject, _ depth: Int) {
            guard depth < 40 else { return }
            out.append(String(repeating: " ", count: 2 + depth * 2) + axLine(element))
            let children = axAttribute(element, "accessibilityChildren") as? [AnyObject] ?? []
            for child in children { walk(child, depth + 1) }
        }
        walk(content, 0)
        return out.joined(separator: "\n")
    }

    private func axLine(_ element: AnyObject) -> String {
        var bits = ["\(type(of: element))"]
        for key in ["accessibilityRole", "accessibilitySubrole", "accessibilityRoleDescription",
                    "accessibilityIdentifier", "accessibilityTitle", "accessibilityLabel",
                    "accessibilityValue", "accessibilityHelp"] {
            if let value = axAttribute(element, key) {
                let text = String(describing: value)
                guard text != "nil", !text.isEmpty else { continue }
                bits.append("\(key.replacingOccurrences(of: "accessibility", with: "").lowercased())"
                            + "=\u{201C}\(text.prefix(60))\u{201D}")
            }
        }
        if let enabled = axEnabled(element) { bits.append("enabled=\(enabled)") }
        if let actions = axAttribute(element, "accessibilityActionNames") as? [String],
           !actions.isEmpty {
            bits.append("actions=\(actions)")
        }
        let children = axAttribute(element, "accessibilityChildren") as? [AnyObject] ?? []
        bits.append("kids=\(children.count)")
        return bits.joined(separator: " ")
    }

    // MARK: - Driving

    private func sendClick(at point: CGPoint, in window: NSWindow) {
        guard let content = window.contentView else { return }
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
    }

    // MARK: - Hosting + fixtures

    private func mount(_ view: AnyView, size: CGSize) -> NSWindow {
        let window = TestWindow.mount(view, size: size, as: SilentTestWindow.self)
        windows.append(window)
        pump()
        return window
    }

    private func headerViews(in window: NSWindow) -> [NSView] {
        allViews(in: window).filter {
            String(describing: type(of: $0)).contains("ListTableHeaderView")
        }
    }

    private func allViews(in window: NSWindow) -> [NSView] {
        guard let root = window.contentView else { return [] }
        return descendants(of: root)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func collection() async throws -> (ProjectStore, DocumentStore, StructureItem) {
        let url = try await ProjectFactory.createCollectionProject(named: "Spike", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (store, ds, piece)
    }

    private func novel() async throws -> (ProjectStore, DocumentStore, StructureItem) {
        let url = try await ProjectFactory.createNovelProject(named: "Spike", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (store, ds, store.manifest.structure[0])
    }

    private func treeProject() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Tree-\(UUID().uuidString.prefix(6))", in: temp.url)
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

// MARK: - Probes

@MainActor
final class SpikeCounter {
    var count = 0
    init() {}
}

@MainActor
final class SpikeHeaderBox {
    let plain = SpikeCounter()
    let collapsible = SpikeCounter()
    init() {}
}

@MainActor
private struct BarePickerProbe: View {
    @State private var selection: Int? = nil

    var body: some View {
        VStack {
            Picker("Structural", selection: $selection) {
                Text("Untouched").tag(Int?.none)
                Text("In Progress").tag(Int?.some(1))
                Text("Done").tag(Int?.some(2))
                Text("Skip").tag(Int?.some(3))
            }
            .pickerStyle(.menu)
        }
        .padding()
    }
}

@MainActor
private struct BareMenuProbe: View {
    @State private var typed = ""

    var body: some View {
        HStack {
            TextField("Label", text: $typed)
            SwiftUI.Menu {
                Button("Amelia") { typed = "Amelia" }
                Button("Denver") { typed = "Denver" }
            } label: {
                Text("this is also…")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(Text("this is also…"))
        }
        .padding()
    }
}

@MainActor
private struct IdentifiedControlsProbe: View {
    @State private var selection: Int? = nil
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Structural", selection: $selection) {
                Text("Untouched").tag(Int?.none)
                Text("Done").tag(Int?.some(2))
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("ladder.structural")

            Picker("Line", selection: $selection) {
                Text("Untouched").tag(Int?.none)
                Text("Done").tag(Int?.some(2))
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("ladder.line")
            .disabled(true)

            SwiftUI.Menu {
                Button("Amelia") { typed = "Amelia" }
            } label: {
                Text("this is also…")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(Text("this is also…"))
            .accessibilityIdentifier("admission.knownLabels")
        }
        .padding()
    }
}

@MainActor
private struct SpikeTreeProbe: View {
    let store: ProjectStore
    let treeState: BinderTreeSectionsState
    let onOpenPaletteWall: () -> Void
    @State private var subject: BinderSubject?

    var body: some View {
        BinderView(store: store, selectedSubject: $subject,
                   treeState: treeState,
                   paletteWallTravels: false,
                   onOpenPaletteWall: onOpenPaletteWall)
    }
}

@MainActor
private struct SpikeHeaderShapeProbe: View {
    let box: SpikeHeaderBox
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
