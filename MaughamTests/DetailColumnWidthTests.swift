import XCTest
import AppKit
import SwiftUI
import Observation
@testable import Maugham

/// Holds the right column's inputs outside the view, and **counts every write of
/// the width**, so a test can tell a writer's drag from the app moving the
/// divider on its own.
@Observable
@MainActor
final class DetailColumnProbe {
    /// Which spelling the harness applies — the production one, or the range
    /// this task replaced. `.range` exists so the diagnosis is a measurement
    /// this suite keeps making rather than a paragraph in a report.
    enum Spelling { case width, range }

    var mounted: Bool = true
    /// Stands for the pane the right column is showing. `1` is a pane whose
    /// content wants to be wider than the column — an Outline table, a
    /// Diagnostics row, any label that will not break.
    var pane: Int = 0
    var visibility: NavigationSplitViewVisibility = .all

    private(set) var widthWrites: Int = 0
    var width: Double {
        didSet { widthWrites += 1 }
    }

    init(width: Double = 320, spelling: Spelling = .width) {
        self.width = width
        self.spelling = spelling
        self.widthWrites = 0
    }

    let spelling: Spelling
}

/// The right column composed the way `ProjectWindow.detailColumn` composes it:
/// a three-column `NavigationSplitView`, the detail column mounted behind a
/// `if showInspector`, and the pane's content swapped underneath.
@MainActor
private struct DetailColumnHarness: View {
    let probe: DetailColumnProbe

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { probe.visibility }, set: { probe.visibility = $0 })) {
            Color.gray.navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            Color.white.navigationSplitViewColumnWidth(min: 480, ideal: 720)
        } detail: {
            if probe.mounted { detailColumn }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch probe.spelling {
        case .width:
            pane.navigationSplitViewColumnWidth(probe.width)
        case .range:
            pane.navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        }
    }

    /// Three panes, and the third is load-bearing: pane `2` is a *different*
    /// view of the *same* narrow intrinsic width, which is how
    /// `test_neitherAPaneSwapNorAHideShowIsWhatMovedIt` separates "the identity
    /// changed" from "the content asked for more room".
    @ViewBuilder
    private var pane: some View {
        VStack(spacing: 0) {
            switch probe.pane {
            case 0:
                Text("Inspector")
            case 1:
                Text("a label this pane will not break, wanting far more width "
                     + "than the column was dragged to")
                    .fixedSize()
            default:
                Text("History")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// **One width, held through every persona and every pane switch.**
///
/// Denver, 2026-08-08: *"I hate that the right hand column keeps shifting widths
/// as I change modes, that needs to stop."*
///
/// **The mechanism, measured before anything was fixed** (macOS 26.5, 2026-08-08
/// — and note CLAUDE.md's runner-parity rule: these mount real AppKit views, so
/// a green run here says nothing about a runner on a different major).
/// `ProjectWindow` had exactly one `navigationSplitViewColumnWidth` on the
/// detail column and the width still moved, because **a range is not a width**.
/// `min:ideal:max:` declares the interval AppKit may resolve a divider inside,
/// and it re-resolves whenever something re-proposes. Two things do, and neither
/// is a view-identity change — the hypothesis this task opened with, falsified
/// here by `test_neitherAPaneSwapNorAHideShowIsWhatMovedIt`:
///
/// | what the writer did | dragged to | landed on |
/// |---|---|---|
/// | switched to a pane with wider content | 329 | 360 — the range's `max` |
/// | `⌘\` on the canvas and back (`.doubleColumn` → `.all`) | 329 | 240 — the range's `min` |
///
/// The fix is the single-argument spelling: a range with one value in it has
/// nothing left to re-resolve. `test_plantedOffender_theRangeIsWhatMovedIt`
/// keeps both rows of that table measurable, so the diagnosis cannot rot into a
/// comment nobody can check.
///
/// **What this harness is and is not.** It mounts a real `NavigationSplitView`
/// with the real modifier, so what it measures is AppKit's behaviour rather than
/// Maugham's. What ties it to production is the census at the bottom of this
/// file: the harness proves the spelling holds, the census proves the app uses
/// that spelling and writes the width from one place.
@MainActor
final class DetailColumnWidthTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        settle(0.05)
        windows.removeAll()
    }

    // MARK: - The width survives what a mode change does to this column

    /// A persona switch reaches this column through three observable signals,
    /// and it can fire all three in one press: `PersonaModifier` restores the
    /// destination's remembered pane (the content swaps), forces
    /// `showInspector = true` (the column may be re-mounted), and hands
    /// `columnVisibility` back to `.all` after a canvas collapse. All three are
    /// driven here, in that order, and the writer's 320 must come out the far
    /// side.
    func test_theWidthSurvivesAPersonaRoundTrip() async throws {
        let probe = DetailColumnProbe(width: 320)
        let split = try await mount(probe)
        XCTAssertEqual(width(of: split), 320, accuracy: 1,
                       "premise: the column opens at the writer's own width")

        for pane in [1, 2, 0] {
            probe.pane = pane
            probe.mounted = false
            await pump(0.5)
            probe.mounted = true
            probe.visibility = .doubleColumn
            await pump(0.5)
            probe.visibility = .all
            await pump(0.6)

            XCTAssertEqual(width(of: split), 320, accuracy: 1,
                           "pane \(pane): a mode change may move what the column "
                           + "SHOWS and must never move how wide it is")
        }
    }

    /// The cheaper half of the same rule, on its own: `⌘⌥`-letter pane
    /// shortcuts fire in every persona, and the pane they land on is the one
    /// whose content used to push the divider out to `max`.
    func test_theWidthSurvivesAPaneSwitch() async throws {
        let probe = DetailColumnProbe(width: 300)
        let split = try await mount(probe)

        probe.pane = 1
        await pump(0.7)
        XCTAssertEqual(width(of: split), 300, accuracy: 1,
                       "a pane whose content wants to be wider than the column "
                       + "must be given the column's width, not the other way "
                       + "round")

        probe.pane = 0
        await pump(0.7)
        XCTAssertEqual(width(of: split), 300, accuracy: 1)
    }

    /// **The hypothesis this task opened with, falsified.** The leading guess
    /// was that a view-identity change re-applies the modifier's `ideal`. It
    /// does not: with the RANGE spelling still in place, swapping the pane's
    /// content for one of the same intrinsic width and un-mounting/re-mounting
    /// the whole column both leave a dragged width exactly where it was. What
    /// moved it was the content's width demand and the visibility transition —
    /// which is why the fix is the spelling and not an `.id()`.
    func test_neitherAPaneSwapNorAHideShowIsWhatMovedIt() async throws {
        let probe = DetailColumnProbe(spelling: .range)
        let split = try await mount(probe)
        let dragged = try await dragDivider(of: split, toDetailWidth: 330)
        XCTAssertLessThan(dragged, 360,
                          "premise: the divider actually moved off the range's "
                          + "max, or this test measures nothing")

        probe.pane = 2      // same intrinsic width as pane 0
        await pump(0.6)
        XCTAssertEqual(width(of: split), dragged, accuracy: 1,
                       "an identity change alone does not re-apply `ideal`")

        probe.mounted = false
        await pump(0.5)
        probe.mounted = true
        await pump(0.6)
        XCTAssertEqual(width(of: split), dragged, accuracy: 1,
                       "and neither does un-mounting the column and putting it "
                       + "back — `showInspector` was never the culprit")
    }

    /// **The planted offender, and the diagnosis it keeps measurable.** The
    /// range spelling this task removed, driven through the same harness: a
    /// wide pane takes the column to the range's `max`, and a visibility round
    /// trip drops it on the range's `min`. If either row of this table ever
    /// stops reproducing, the tests above are passing for a reason nobody has
    /// checked.
    func test_plantedOffender_theRangeIsWhatMovedIt() async throws {
        let probe = DetailColumnProbe(spelling: .range)
        let split = try await mount(probe)
        let dragged = try await dragDivider(of: split, toDetailWidth: 330)

        probe.pane = 1
        await pump(0.7)
        XCTAssertEqual(width(of: split), 360, accuracy: 1,
                       "the offender: a pane wanting more width takes the "
                       + "column out to the range's max, over a width the "
                       + "writer had dragged to \(dragged)")

        probe.pane = 0
        await pump(0.6)
        probe.visibility = .doubleColumn
        await pump(0.6)
        probe.visibility = .all
        await pump(0.7)
        XCTAssertEqual(width(of: split), 240, accuracy: 1,
                       "and the offender's second half: a columnVisibility "
                       + "round trip — `⌘\\` on the canvas, then any persona "
                       + "switch — lands the column on the range's MIN")
    }

    // MARK: - Nothing but a drag writes the width

    /// **No feedback loop, structurally.** The other honest route to capturing a
    /// drag is a `GeometryReader` writing the observed width back to ui-state;
    /// with it, every transition above would report a width and write it, and
    /// the writer's number would be whatever the last transition happened to
    /// measure. A fixed column has no geometry of its own to report, so the
    /// count here is zero and the only writer left is the gesture.
    func test_aPersonaSwitchDoesNotWriteTheWidth() async throws {
        let probe = DetailColumnProbe(width: 300)
        let split = try await mount(probe)
        XCTAssertEqual(probe.widthWrites, 0, "premise: mounting wrote nothing")

        probe.pane = 1
        await pump(0.5)
        probe.mounted = false
        await pump(0.4)
        probe.mounted = true
        probe.visibility = .doubleColumn
        await pump(0.5)
        probe.visibility = .all
        await pump(0.6)

        XCTAssertEqual(probe.widthWrites, 0,
                       "a persona switch, a pane switch and a collapse round "
                       + "trip must write the width exactly never")
        XCTAssertEqual(width(of: split), 300, accuracy: 1)

        // The control: the gesture's own write does reach it, so a probe that
        // simply cannot count is not what the zero above is made of.
        probe.width = 360
        await pump(0.6)
        XCTAssertEqual(probe.widthWrites, 1)
        XCTAssertEqual(width(of: split), 360, accuracy: 1,
                       "and the column follows the value live, which is what "
                       + "makes the handle a resize rather than a jump")
    }

    // MARK: - The store contracts

    func test_theDraggedWidthRoundTripsThroughTheStore() throws {
        let original = UIState(detailColumnWidth: 412)
        let decoded = try JSONDecoder().decode(
            UIState.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded.detailColumnWidth, 412)
    }

    /// Additive: a file written before this key existed opens at the width the
    /// old range called `ideal`, so nothing moves for a writer who never
    /// touched the divider.
    func test_aFileWithoutTheKeyOpensAtTheOldIdeal() throws {
        let json = """
        {"schemaVersion": \(UIState.currentSchemaVersion)}
        """
        let decoded = try JSONDecoder().decode(
            UIState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.detailColumnWidth, 280)
        XCTAssertEqual(UIState.defaultDetailColumnWidth, 280)
    }

    /// The clamp is the safety on a value the writer owns, and a hand-edited
    /// `ui-state.json` is a writer of it with no gesture to limit it — so both
    /// ways in clamp, exactly as `assistantColumnWidth` does.
    func test_everyWayInIsClamped() throws {
        let range = UIState.detailColumnWidthRange
        XCTAssertTrue(range.contains(UIState.defaultDetailColumnWidth),
                      "a default outside its own clamp is a default nobody gets")

        XCTAssertEqual(UIState(detailColumnWidth: 4000).detailColumnWidth,
                       range.upperBound)
        XCTAssertEqual(UIState(detailColumnWidth: 10).detailColumnWidth,
                       range.lowerBound)

        for (written, expected) in [(4000.0, range.upperBound), (10.0, range.lowerBound)] {
            let json = """
            {"schemaVersion": \(UIState.currentSchemaVersion), \
            "detailColumnWidth": \(written)}
            """
            let decoded = try JSONDecoder().decode(UIState.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.detailColumnWidth, expected,
                           "a \(written)pt column restored into a window with no "
                           + "room for it is the case the decode clamp is for")
        }
    }

    /// The ceiling is wider than the old `max: 360` on purpose, and the reason
    /// is a measurement rather than a preference: at the window's own floor
    /// (`ProjectWindow`'s `minWidth: 980`) the widest right column still leaves
    /// the writing column above its `min: 480`. Measured 2026-08-08 at 499pt.
    func test_theWidestColumnStillLeavesTheNarrowestWindowItsProse() async throws {
        let probe = DetailColumnProbe(width: UIState.detailColumnWidthRange.upperBound)
        let split = try await mount(probe, windowWidth: 980)

        XCTAssertEqual(width(of: split), 480, accuracy: 1)
        let centre = try XCTUnwrap(split.arrangedSubviews.dropLast().last?.frame.width)
        XCTAssertGreaterThanOrEqual(centre, 480,
                                    "the right column may not squeeze the prose "
                                    + "below the editor's own minimum — measured "
                                    + "\(centre)pt")
    }

    // MARK: - The census: production asks for a width, from one place

    /// **What the harness above cannot see.** It measures AppKit, not Maugham —
    /// every assertion in this file would stay green if `ProjectWindow` went
    /// back to the range tomorrow. This is the line that ties the two together.
    func test_theRightColumnAsksForAWidthAndNotARange() throws {
        let code = try Self.codeLines(of: "Views/ProjectWindow.swift")

        XCTAssertEqual(
            code.filter { $0.contains("navigationSplitViewColumnWidth(detailColumnWidth)") }.count,
            1,
            "the detail column is pinned to the writer's own width, in exactly "
            + "one place")
        XCTAssertTrue(
            code.allSatisfy { !$0.contains("navigationSplitViewColumnWidth(min: 240") },
            "and it must not go back to declaring a range — a range is what "
            + "moved under the writer on every mode change (see this file's "
            + "planted offender for the two ways it does)")

        // A fixed column's own divider is inert (measured: a programmatic
        // `setPosition` on it moves nothing), so the handle is the ONLY way the
        // width can be changed. Losing the call loses the capability in
        // silence — the column would simply never be resizable again.
        XCTAssertTrue(
            code.contains { $0.contains("detailResizeHandle(documentStore: documentStore)") },
            "the column must mount its own resize handle: the split view's "
            + "divider cannot move a fixed column, so without this the writer's "
            + "one width is one width forever")
    }

    /// One write site, so the value the writer dragged to is the value that is
    /// stored — the shape `memory/feedback_census_over_warning.md` asks for on
    /// anything a second author could plausibly add a second writer to.
    func test_theWidthIsWrittenFromExactlyOneProductionSite() throws {
        XCTAssertEqual(try Self.filesWritingTheWidth(),
                       ["ProjectWindow.swift"],
                       "only the column's own drag handle may persist this "
                       + "width; anything else is a second author of the "
                       + "writer's layout")
    }

    /// **The control**, without which the census could be scanning a tree with
    /// nothing in it and reporting a list somebody wrote down.
    func test_theWriteCensusSeesASecondWriter() throws {
        XCTAssertEqual(
            try Self.filesWritingTheWidth(
                plus: ["SomeNewModifier.swift":
                        "documentStore.updateUIState { $0.detailColumnWidth = 280 }"]),
            ["ProjectWindow.swift", "SomeNewModifier.swift"])
    }

    /// And the control on the control: prose quoting the write is not a write.
    func test_theWriteCensusDoesNotCountAComment() throws {
        XCTAssertEqual(
            try Self.filesWritingTheWidth(
                plus: ["CommentedOnly.swift":
                        "/// written as `$0.detailColumnWidth = width`, once."]),
            ["ProjectWindow.swift"])
    }

    // MARK: - Census helpers

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }

    /// `plus` runs synthetic sources through the identical predicate, so the
    /// two companions above test *this* scan rather than a second copy of it.
    private static func filesWritingTheWidth(
        plus injected: [String: String] = [:]
    ) throws -> [String] {
        var sources: [(name: String, text: String)] = []
        let fm = FileManager.default
        let walker = try XCTUnwrap(
            fm.enumerator(at: appSourceDir, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            sources.append((url.lastPathComponent,
                            try String(contentsOf: url, encoding: .utf8)))
        }
        sources.append(contentsOf: injected.map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 })

        return sources.filter { source in
            SourceScan.codeLines(of: source.text).contains {
                $0.contains("$0.detailColumnWidth =")
            }
        }.map(\.name)
    }

    // MARK: - Hosting

    private func width(of split: NSSplitView) -> CGFloat {
        split.arrangedSubviews.last?.frame.width ?? -1
    }

    /// Drives the split view's own divider, which is how the RANGE spelling is
    /// dragged. The production spelling has no draggable divider — its handle
    /// writes the value — so this is only ever used on the offender.
    @discardableResult
    private func dragDivider(of split: NSSplitView,
                             toDetailWidth target: CGFloat) async throws -> CGFloat {
        split.setPosition(split.frame.width - target,
                          ofDividerAt: split.arrangedSubviews.count - 2)
        await pump(0.6)
        return width(of: split)
    }

    private func mount(_ probe: DetailColumnProbe,
                       windowWidth: CGFloat = 1200) async throws -> NSSplitView {
        let frame = CGRect(x: 0, y: 0, width: windowWidth, height: 700)
        let hosting = NSHostingView(rootView: AnyView(DetailColumnHarness(probe: probe)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pump(1.0)

        var found: [NSSplitView] = []
        collect(NSSplitView.self, in: try XCTUnwrap(window.contentView), into: &found)
        let split = try XCTUnwrap(found.first,
                                  "the NavigationSplitView never reached the "
                                  + "hierarchy — nothing below measures anything")
        XCTAssertEqual(split.arrangedSubviews.count, 3,
                       "premise: three columns, the last of which is the one "
                       + "this file is about")
        return split
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
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
