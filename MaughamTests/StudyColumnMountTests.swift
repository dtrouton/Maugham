import XCTest
import AppKit
import SwiftUI
import ApplicationServices
import Observation
import MaughamCore
@testable import Maugham

/// **The prose keeps its measure.** Studying a pinned reference used to insert a
/// FOURTH column between the binder and the prose (`AssistantColumnModifier`'s
/// `HStack`, M2 §6.2); Denver, having written beside one, ruled the opposite —
/// a studied reference takes the RIGHT column, in place of the pane picker and
/// the pane, at the right column's own width (spec §3.2, 2026-08-25).
///
/// **Why this file exists at all.** `AssistantColumnTests` pins the *decision*
/// (`AssistantColumn.isPresented`) and the *chain* (the reveal and the three
/// dismisses), and both would stay green against a study column mounted
/// anywhere at all — including back in the centre. What only a mounted split
/// view can say is the thing the ruling is actually about: **the writing column
/// does not move**. So the assertion here is a measurement of the prose, taken
/// before and after, with the detail column's contents checked to prove the
/// study really happened rather than silently failing to present.
///
/// **The prose is measured from INSIDE the centre column**, by a
/// `GeometryReader`, and never off the split view's arranged subview — see
/// `StudyProbe.proseWidth`, which records the falsification that forced the
/// distinction: rebuilding the old fourth column inside the content arm left
/// the arranged subview's width identical to the point, so the first draft of
/// this file passed the very design it was written to rule out.
///
/// **The harness, not `ProjectWindow`.** `ProjectWindow.assistant` is
/// `@State private`; nothing outside the view can study a pin in a real window,
/// so a real mount could observe the arm only by clicking a References row
/// through a full project — a synthetic click, which needs the test host to be
/// the active app (CLAUDE.md's build-flow notes) and would make this file
/// unrunnable on a locked screen for a fact that is about layout. What is
/// mounted instead is `DetailColumnWidthTests.DetailColumnHarness`'s shape: a
/// three-column `NavigationSplitView` carrying the production floors, the
/// production width sum, and a REAL `AssistantColumn` in the detail arm behind
/// the real `AssistantColumn.isPresented`.
///
/// The gap that leaves — that `ProjectWindow.detailColumn` really composes it
/// this way — is what the census in that method's own comment carries.
@MainActor
final class StudyColumnMountTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        settle(0.05)
        windows.removeAll()
        temp = nil
    }

    // MARK: - The measurement

    /// **Study, and the prose is exactly as wide as it was.** The two facts are
    /// asserted together on purpose: a centre width that did not move because
    /// the study never presented would pass half of this test, so the detail
    /// column is read for `AssistantColumn.closeLabel` in the same breath.
    func test_studyingAPinDoesNotNarrowTheProse() async throws {
        try skipUnlessThisDisplayCanMountTheWindowFloor()
        let (url, store) = try await makeProject()
        let probe = StudyProbe()
        let (window, split) = try await mount(probe, store: store, projectRoot: url)

        let before = probe.proseWidth
        XCTAssertGreaterThan(before, 0,
                             "premise: the writing column reported a width — "
                             + "without one this test measures nothing")

        probe.assistant.study(aPin())
        await pump(0.8)

        XCTAssertEqual(probe.proseWidth, before, accuracy: 1,
                       "studying a reference must not take a point from the "
                       + "writing column — that is the whole of Denver's "
                       + "ruling. Measured \(probe.proseWidth)pt against "
                       + "\(before)pt")
        XCTAssertEqual(split.arrangedSubviews.count, 3,
                       "and it must not have minted a fourth column to do it")

        // **The presentation check the doc comment promises**, added in
        // fix-round 1: without it a prose width that did not move BECAUSE the
        // study never presented passes this test, and the sibling that would
        // have caught that skips wherever no assistive client attaches. Last,
        // so the measurement above still runs in that environment before this
        // line skips out.
        XCTAssertTrue(
            try strings(in: window).contains(where: { $0.contains(AssistantColumn.closeLabel) }),
            "the width did not move because the study never presented — this "
            + "test would otherwise pass on a column that does nothing")
    }

    /// The other half: the right column really swaps its contents. Studying puts
    /// the reference's own close affordance there; closing hands the pane back.
    /// Read through the accessibility tree, which is how every other mounted
    /// surface in this suite is read.
    func test_theRightColumnSwapsBetweenTheStudyAndThePane() async throws {
        try skipUnlessThisDisplayCanMountTheWindowFloor()
        let (url, store) = try await makeProject()
        let probe = StudyProbe()
        let (window, _) = try await mount(probe, store: store, projectRoot: url)

        XCTAssertTrue(try strings(in: window).contains(Self.paneMarker),
                      "premise: the right column opens on its pane")

        probe.assistant.study(aPin())
        await pump(0.8)

        var shown = try strings(in: window)
        XCTAssertTrue(shown.contains(where: { $0.contains(AssistantColumn.closeLabel) }),
                      "the study column is not in the right column. Found: "
                      + shown.joined(separator: " | "))
        XCTAssertFalse(shown.contains(Self.paneMarker),
                       "and it stands IN PLACE OF the pane rather than beside it")

        probe.assistant.dismiss()
        await pump(0.8)

        shown = try strings(in: window)
        XCTAssertTrue(shown.contains(Self.paneMarker),
                      "closing hands the pane back — the column stays visible "
                      + "showing whatever the segment still holds, which is why "
                      + "there is no stash to restore (tripwire 2)")
        XCTAssertFalse(shown.contains(where: { $0.contains(AssistantColumn.closeLabel) }))
    }

    /// **The study column is the right column's width, not one of its own.**
    /// Asked of production's own sum rather than restated: what the column is
    /// given is `ProjectWindow.effectiveDetailColumnWidth`, and it is the same
    /// number with a reference up as without one.
    func test_theStudyColumnIsExactlyAsWideAsThePaneWas() async throws {
        try skipUnlessThisDisplayCanMountTheWindowFloor()
        let (url, store) = try await makeProject()
        let probe = StudyProbe()
        let (_, split) = try await mount(probe, store: store, projectRoot: url)

        let paneWidth = detailWidth(of: split)
        probe.assistant.study(aPin())
        await pump(0.8)

        XCTAssertEqual(detailWidth(of: split), paneWidth, accuracy: 1,
                       "a studied reference takes the column as it found it")
    }

    // MARK: - The harness

    /// A marker no other surface in the harness draws, so "the pane is showing"
    /// is a string match that cannot be satisfied by chrome.
    private static let paneMarker = "Inspector stand-in"

    /// What the harness's detail arm is a function of, outside the view.
    @Observable
    @MainActor
    final class StudyProbe {
        let assistant = AssistantColumnModel()
        var persona: Persona = .author
        var isNoChromeOn = false
        var width: Double = UIState.defaultDetailColumnWidth
        private(set) var containerWidth: Double?
        /// **What the writer's page is actually laid out at**, reported by a
        /// `GeometryReader` INSIDE the centre column rather than read off the
        /// split view's arranged subview.
        ///
        /// The distinction is the whole reason this property exists, and it was
        /// found by falsification: rebuild the old fourth column *inside* the
        /// content arm and the arranged subview's width does not move by a
        /// single point — the split view is still handing that column the same
        /// number, and it is the prose within it that gives up 340pt. A test
        /// measuring the arranged subview passed the old design unchanged.
        var proseWidth: Double = 0

        func noteContainerWidth(_ width: Double) {
            guard ProjectWindow.recordsContainerWidth(width, over: containerWidth) else { return }
            containerWidth = width
        }
    }

    /// `ProjectWindow.detailColumn`'s composition, at harness scale: the
    /// production floors, the production width sum, and the real arm.
    private struct StudyColumnHarness: View {
        let probe: StudyProbe
        let store: ProjectStore
        let projectRoot: URL

        var body: some View {
            NavigationSplitView {
                Color.gray.navigationSplitViewColumnWidth(
                    min: ProjectWindow.binderColumnFloor, ideal: 240)
            } content: {
                prose.navigationSplitViewColumnWidth(
                    min: ProjectWindow.centreColumnFloor, ideal: 720)
            } detail: {
                detailColumn
                    .navigationSplitViewColumnWidth(
                        ProjectWindow.effectiveDetailColumnWidth(
                            persisted: probe.width, containerWidth: probe.containerWidth))
            }
            .modifier(ContainerWidthReporter(onWidth: { probe.noteContainerWidth($0) }))
        }

        /// The writing column, reporting the width it was actually laid out
        /// at. `ProjectWindow`'s centre arm is an editor and this is a
        /// rectangle, but what is being measured is the room the split view and
        /// anything wrapping it leave — which is the same question either way.
        private var prose: some View {
            GeometryReader { geo in
                Color.white
                    .onAppear { probe.proseWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in probe.proseWidth = new }
            }
        }

        @ViewBuilder
        private var detailColumn: some View {
            HStack(spacing: 0) {
                if AssistantColumn.isPresented(studied: probe.assistant.studied,
                                               persona: probe.persona,
                                               isNoChromeOn: probe.isNoChromeOn) {
                    AssistantColumn(store: store, projectRoot: projectRoot,
                                    assistant: probe.assistant)
                } else {
                    VStack(spacing: 0) {
                        Text(StudyColumnMountTests.paneMarker)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private func mount(_ probe: StudyProbe, store: ProjectStore,
                       projectRoot: URL) async throws -> (NSWindow, NSSplitView) {
        let frame = CGRect(x: 0, y: 0, width: 980, height: 700)
        let hosting = NSHostingView(rootView: AnyView(
            StudyColumnHarness(probe: probe, store: store, projectRoot: projectRoot)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pump(1.0)

        // The premise, read off the window this test actually got rather than
        // the one it asked for: AppKit clamps a window to its display, and CI's
        // is 1024pt wide (CLAUDE.md's runner-parity note).
        XCTAssertEqual(window.frame.width, 980, accuracy: 1,
                       "premise: the window opened at the width this file "
                       + "measures against")

        var found: [NSSplitView] = []
        collect(NSSplitView.self, in: try XCTUnwrap(window.contentView), into: &found)
        let split = try XCTUnwrap(found.first,
                                  "the NavigationSplitView never reached the "
                                  + "hierarchy — nothing below measures anything")
        XCTAssertEqual(split.arrangedSubviews.count, 3,
                       "premise: three columns, and the last is the one the "
                       + "study is supposed to take")
        return (window, split)
    }

    private func skipUnlessThisDisplayCanMountTheWindowFloor() throws {
        let display = (NSScreen.main ?? NSScreen.screens.first)
            .map { Double($0.visibleFrame.width) } ?? .greatestFiniteMagnitude
        try XCTSkipUnless(
            display >= Double(ProjectWindow.windowFloor),
            "test_studyColumnMount: this display is \(display)pt wide, narrower "
            + "than the window's own \(ProjectWindow.windowFloor)pt floor, so "
            + "the three columns cannot be mounted at the widths this file "
            + "measures")
    }

    private func detailWidth(of split: NSSplitView) -> Double {
        Double(split.arrangedSubviews.last?.frame.width ?? -1)
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    // MARK: - Reading the window

    /// `AssistantColumnTests`' guard, verbatim: SwiftUI builds an accessibility
    /// tree only when an assistive client is attached to the process.
    private func strings(in window: NSWindow) throws -> [String] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so "
                + "SwiftUI never built the tree this test reads")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
            .flatMap { element -> [String] in
                [axAttribute(element, "accessibilityLabel") as? String,
                 axAttribute(element, "accessibilityValue") as? String,
                 axAttribute(element, "accessibilityTitle") as? String].compactMap { $0 }
            }
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

    // MARK: - Fixtures

    private func aPin() -> PinnedReference {
        PinnedReference(id: "res-note", kind: .research(itemId: "res-note"),
                        title: "The falls at night")
    }

    private func makeProject() async throws -> (URL, ProjectStore) {
        let root = temp.url.appendingPathComponent("Proj-\(UUID().uuidString.prefix(6))")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manuscript"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("research"),
                               withIntermediateDirectories: true)
        try "Chapter one.".write(to: root.appendingPathComponent("manuscript/c1.md"),
                                 atomically: true, encoding: .utf8)
        try "The water is loud all night.".write(
            to: root.appendingPathComponent("research/the-falls-at-night.md"),
            atomically: true, encoding: .utf8)

        let note = ResearchItem(id: "res-note", title: "The falls at night", type: .asset,
                                kind: .document, path: "research/the-falls-at-night.md")
        let manifest = ProjectManifest(
            type: .novel, title: "Study", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                      path: "manuscript/c1.md")],
            research: [note])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest)
            .write(to: root.appendingPathComponent("project.maugham.json"))

        return (root, try await ProjectStore.load(from: root))
    }

    private func pump(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            settle(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
