import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The right column as `ProjectWindow.detailColumn` mounts it — the real
/// `DetailPaneToggle` over real stores — inside the real three-column
/// `NavigationSplitView`, at the width `ProjectWindow.effectiveDetailColumnWidth`
/// pins it to, under the window's own `.frame(minWidth:minHeight:)`.
///
/// The other two columns are plain fills. The census is about a HEIGHT demand
/// travelling OUT of the right column, and a demanding column grows the split
/// whatever the others contain — measured both ways on 2026-08-08, with the real
/// binder tree and the real `EditorHost` in place and with neither.
@MainActor
private struct DetailColumnCensusHarness: View {
    @Bindable var store: ProjectStore
    let probe: DetailSegmentProbe
    let documentStore: DocumentStore
    let docId: String
    let orchestrator: CompilerOrchestrator
    let diagnostics: DiagnosticsStore
    let bible: BibleStore
    let world: DeclaredWorldStore

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Color.gray.navigationSplitViewColumnWidth(
                min: ProjectWindow.binderColumnFloor, ideal: 240)
        } content: {
            Color.white.navigationSplitViewColumnWidth(
                min: ProjectWindow.centreColumnFloor, ideal: 720)
        } detail: {
            DetailPaneToggle(
                store: store,
                segment: Binding(get: { probe.segment }, set: { probe.segment = $0 }),
                outlineLayout: Binding(get: { probe.layout }, set: { probe.layout = $0 }),
                selectedSubject: Binding(get: { probe.subject },
                                         set: { probe.subject = $0 }),
                activeManuscriptItemId: probe.subject?.itemID,
                persona: .author,
                // False, deliberately: a collection hides `.outline`, and a
                // segment the window never renders is a segment this census
                // would report on without measuring. The project below is a
                // novel for the same reason.
                hideOutline: false,
                projectURL: store.url,
                activeDocId: docId,
                allDocIds: [docId],
                device: "test-mac",
                session: "s1",
                docPaths: [:],
                documentStore: documentStore,
                editorControl: EditorControl(),
                compilerOrchestrator: orchestrator,
                diagnosticsStore: diagnostics,
                bibleStore: bible,
                declaredWorldStore: world,
                compilerModel: .standard,
                assistant: AssistantColumnModel()
            ) {
                InspectorView(store: store, selectedItemId: probe.subject?.itemID,
                              metrics: EditorMetrics(wordCount: 0, characterCount: 0,
                                                   readingMinutes: 0),
                              onOpenProjectSettings: {})
            }
            .navigationSplitViewColumnWidth(
                ProjectWindow.effectiveDetailColumnWidth(
                    persisted: UIState.defaultDetailColumnWidth,
                    containerWidth: 1200))
        }
        .frame(minWidth: ProjectWindow.windowFloor, minHeight: 540)
    }
}

@Observable
@MainActor
private final class DetailSegmentProbe {
    var segment: DetailSegment = .inspector
    var layout: OutlineLayout = .table
    var subject: BinderSubject?
    init(subject: BinderSubject?) { self.subject = subject }
}

/// **No pane may grow the window's columns — every pane, not the one that did.**
///
/// This is the census `memory/feedback_census_over_warning.md` asks for, and the
/// count that earned it is two shipped instances plus one live sibling: the
/// cold-start offer's sentence and the Diagnostics header both carried
/// `fixedSize(horizontal: false, vertical: true)` outside any scroll container
/// (`DiagnosticsPaneColumnHeightTests` has the mechanism and the writer's
/// report), and `ViewOnlyShareNotice` carried a third. A defect shape that
/// arrives three times is not retired by a comment telling the next author not
/// to do it.
///
/// **What it measures.** For every `DetailSegment` — walked off `allCases`, so a
/// new pane joins the census by existing rather than by someone remembering to
/// add it — the right column is asked to render that pane and the split view is
/// measured against the window. A pane whose content cannot be broken
/// vertically claims a minimum height, `NSSplitView` sizes itself to its tallest
/// column, and every column overflows the window together. There is no
/// max-height constraint for AppKit to break, which is why this fails silently
/// and differently from the WIDTH conflict `DetailColumnWidthTests` documents.
///
/// **What it cannot see, and what covers that instead.** It only walks the right
/// column. The centre column's three `safeAreaInset(edge: .top)`s can demand
/// height too, and `ViewOnlyShareNotice` is one of them — that case is measured
/// by `test_theViewOnlyNoticeDoesNotGrowTheColumnsEither`, which puts the real
/// notice in the real inset position rather than asserting anything about panes.
///
/// **Runner parity applies** (CLAUDE.md): these mount real AppKit views, so a
/// green run here says nothing about a runner on a different macOS major.
/// Measured on macOS 26.5, 2026-08-08.
@MainActor
final class DetailPaneColumnHeightCensusTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private let windowHeight: CGFloat = 700

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        await waitOut(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The census

    /// Every pane the right column can show, in one window, one at a time.
    ///
    /// **One mount, `allCases` flipped through it**, rather than a window per
    /// pane: the demand is re-resolved on every segment change (that is what
    /// made the original defect appear on a click), and a mount apiece would put
    /// fifteen windows in a suite that already mounts real ones.
    ///
    /// **The premise rides in the same loop as the measurement, deliberately.**
    /// It began as a test of its own and was folded back in: it walks all
    /// fifteen segments through a real settle, so as a separate test it doubled
    /// this file's mounted wall clock — and CLAUDE.md records that overlapping
    /// mounted suites are what starvation-shaped flakes feed on. One loop
    /// carries both, and either assertion failing says which.
    ///
    /// **The settle is a CONDITION, not a fixed wait, and that is a measured
    /// requirement rather than tidiness.** With a flat `waitOut(0.45)` per
    /// segment this file spun the run loop for ~7 seconds straight, and
    /// `DeclaredWorldDeriverTests.test_anOrdinaryRunFinishesWellInsideTheDeadline`
    /// — which asks a real subprocess to answer inside 300ms — went red whenever
    /// it landed on a worker beside this one. Discriminated rather than filed
    /// under the known-flake list it is genuinely on: alongside two unrelated
    /// mounted suites it passes, alongside this one it failed, so this suite was
    /// the cause and not the weather. `settledHeight` waits for the layout to
    /// stop moving instead of always paying the worst case, which keeps the same
    /// 0.45s ceiling for the segments that need it.
    func test_noDetailPaneGrowsTheColumnsPastTheWindow() async throws {
        let (window, split, probe) = try await mountCensus()
        let content = try XCTUnwrap(window.contentView).frame.height

        var overflowing: [String] = []
        var paneHeights: Set<Double> = []
        for segment in DetailSegment.allCases {
            probe.segment = segment
            await settle(split)
            XCTAssertEqual(probe.segment, segment,
                           "premise: \(segment) is the pane actually on screen — "
                           + "`DetailPaneToggle` snaps a segment its picker "
                           + "cannot render, and a snapped-away segment would "
                           + "be measured without being shown")
            if split.frame.height > content + 1 {
                overflowing.append("\(segment) → \(split.frame.height)pt")
            }
            paneHeights.insert(Double(
                try XCTUnwrap(split.arrangedSubviews.last).fittingSize.height))
        }

        XCTAssertEqual(
            overflowing, [],
            "a pane may not be taller than the window it is a column of. In a "
            + "\(content)pt window these grew the whole split view, which takes "
            + "the binder and the writing column with it: "
            + "\(overflowing.joined(separator: ", ")). The usual cause is "
            + "`fixedSize(horizontal: false, vertical: true)` on a `Text` "
            + "outside a `ScrollView` — see `DiagnosticsPaneColumnHeightTests`.")

        XCTAssertGreaterThan(
            paneHeights.count, 1,
            "the census's own premise: the panes must not all report one "
            + "height. If they do, flipping the segment is changing nothing and "
            + "the sweep above measured a single view fifteen times")
    }

    /// Turn the run loop until the split view's height has stopped moving, or
    /// the ceiling is reached.
    ///
    /// **Two consecutive equal readings, after a floor.** The floor matters: a
    /// pane swap is not instantaneous, so "unchanged since the last poll" is
    /// true for the frame or two before SwiftUI has done anything, and a settle
    /// that believed it would measure the OUTGOING pane and call the census
    /// green. The ceiling is the old fixed wait, so nothing that used to be
    /// measurable has become unmeasurable — only the segments that settle early
    /// stop paying for the ones that do not.
    private func settle(_ split: NSSplitView) async {
        await waitOut(floorSettle)
        var previous = split.frame.height
        let deadline = Date().addingTimeInterval(ceilingSettle - floorSettle)
        while Date() < deadline {
            await waitOut(0.05)
            let now = split.frame.height
            if now == previous { return }
            previous = now
        }
    }

    /// Below this, a reading can be of the pane that is leaving.
    private let floorSettle: TimeInterval = 0.1
    /// The fixed wait this settle replaced — still the worst case.
    private let ceilingSettle: TimeInterval = 0.45

    // MARK: - The planted offender

    /// **The census must be able to SEE an offending pane.** The same window and
    /// the same measurement, with a column built from the shape the fix removed
    /// — and the production sentences, so a rewording moves the offender rather
    /// than leaving it asserting a string nobody says any more.
    ///
    /// Its companion is the census above: this proves the measurement catches an
    /// offender, that one proves no shipped pane is one.
    func test_thePlantedOffenderIsSeenByTheSameMeasurement() async throws {
        let window = try await mountColumns {
            VStack(spacing: 0) {
                Text(DiagnosticsPane.headerCopy(for: .failed(.cliNotFound, at: Date())))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                Divider()
                Text(DiagnosticsPane.coldStartOfferSentence)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        let split = try splitView(in: window)
        let content = try XCTUnwrap(window.contentView).frame.height

        XCTAssertGreaterThan(
            split.frame.height, content + 50,
            "the offender must still reproduce, or the census is a measurement "
            + "that cannot fail (measured \(split.frame.height) against "
            + "\(content)pt of window)")
    }

    /// And the control on the control: the same measurement over a column that
    /// behaves says nothing. Without this the offender test could be passing
    /// because the harness always overflows.
    func test_theControlAWellBehavedColumnDoesNotOverflow() async throws {
        let window = try await mountColumns {
            Text("a pane that can be broken")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        let split = try splitView(in: window)
        let content = try XCTUnwrap(window.contentView).frame.height

        XCTAssertEqual(split.frame.height, content, accuracy: 1,
                       "the harness must not overflow on its own")
    }

    // MARK: - The centre column's insets, which the census cannot walk

    /// **`ViewOnlyShareNotice`, in the position production puts it.**
    ///
    /// It is a `safeAreaInset(edge: .top)` on the WRITING column
    /// (`ProjectWindow.contentColumn`), not a pane, so nothing above walks it —
    /// and it carried the same modifier as the two sites the fix removed. A
    /// notice that grows the window is worse than the two panes were: it is
    /// shown to an iCloud reviewer on a view-only share, who is the reader least
    /// able to work out that the layout is the app's fault rather than theirs.
    ///
    /// Measured against the same window as everything else here.
    func test_theViewOnlyNoticeDoesNotGrowTheColumnsEither() async throws {
        let window = try await mountColumns(
            centreTopInset: { ViewOnlyShareNotice() },
            detail: { Text("pane").frame(maxWidth: .infinity, maxHeight: .infinity) })
        let split = try splitView(in: window)
        let content = try XCTUnwrap(window.contentView).frame.height

        XCTAssertEqual(
            split.frame.height, content, accuracy: 1,
            "the view-only notice must fit the window it banners — it measured "
            + "\(split.frame.height) against \(content)pt")
    }

    /// **What removing the notice's modifier cost, which turned out to be
    /// nothing at all — and this is the assertion that keeps that true.**
    ///
    /// The obvious companion to a layout fix is "the sentence still wraps".
    /// Measured, the notice never wraps: at 11pt it is one 404pt line against a
    /// writing column whose own floor is 480, so the width at which
    /// `fixedSize(horizontal: false, vertical: true)` would have done anything
    /// cannot occur in a real window. It was paying an 866pt column in a 732pt
    /// one (`test_theViewOnlyNoticeDoesNotGrowTheColumnsEither` with the
    /// modifier restored) for a protection that never arose.
    ///
    /// So this asserts the fact the removal rests on rather than a wrap that
    /// does not happen. If the sentence is ever lengthened past the column's
    /// floor it goes red, and whoever lengthens it has to decide deliberately
    /// what a second line should do here — which is the right moment for that
    /// question, and the only one at which it is a real question.
    func test_theViewOnlyNoticeNeverNeedsToWrapInARealWindow() {
        let oneLine = NSHostingView(rootView: AnyView(
            Text(ViewOnlyShareNotice.sentence)
                .font(.system(size: 11, weight: .medium)))).fittingSize

        XCTAssertLessThan(
            Double(oneLine.width), Double(ProjectWindow.centreColumnFloor),
            "the notice's sentence must fit the writing column's own floor "
            + "(\(ProjectWindow.centreColumnFloor)pt) on one line — measured "
            + "\(oneLine.width)pt. Past that it would wrap, and a wrapping "
            + "banner is a decision to make on purpose rather than discover")
    }

    // MARK: - Fixtures

    private func mountCensus() async throws
    -> (NSWindow, NSSplitView, DetailSegmentProbe) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Census-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore

        // A real, registered, never-run manuscript — so the Diagnostics arm
        // renders the COLD-START OFFER rather than an empty state. The census
        // is worth little if it walks past the one pane state that shipped the
        // defect, and `DetailPaneToggle` builds its `activeDocument` closure
        // out of this registry rather than taking a document.
        let item = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure, where: { $0.path != nil }).first,
            "premise: the novel template has a document to open")
        let path = try XCTUnwrap(item.path)
        let fileURL = url.appendingPathComponent(path)
        try "First paragraph, with some words in it.\n\nSecond paragraph, with more."
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let document = try await Document.load(url: fileURL, device: "macA",
                                               session: "s1", presenter: nil)
        documentStore.register(document: document, for: path)

        // An orchestrator left UNCONFIGURED, deliberately: its `runState` is
        // `.idle`, which with no run on record is exactly the `.neverRun` the
        // offer is drawn for, and configuring one would need a `claude` process
        // this census has no business spawning.
        let orchestrator = CompilerOrchestrator()
        let device = DeviceSlug.make(from: "test-mac")
        let diagnostics = DiagnosticsStore(projectRoot: url, device: device)
        XCTAssertTrue(
            DiagnosticsPane.showsColdStartOffer(
                state: .neverRun, liveParagraphCount: document.sequence.count,
                hasRefused: false),
            "premise: the census walks a Diagnostics pane in the state that "
            + "shipped the defect, not an empty one")

        let probe = DetailSegmentProbe(subject: .item(item.id))
        let window = try await host(AnyView(
            DetailColumnCensusHarness(
                store: store, probe: probe, documentStore: documentStore,
                docId: document.docId, orchestrator: orchestrator,
                diagnostics: diagnostics,
                bible: BibleStore(projectRoot: url, device: device),
                world: DeclaredWorldStore(projectRoot: url, device: device))))
        return (window, try splitView(in: window), probe)
    }

    /// The three columns with a caller-supplied right column and centre inset —
    /// the shape the offender, the control and the notice are measured in.
    private func mountColumns<TopInset: View, Detail: View>(
        @ViewBuilder centreTopInset: @escaping () -> TopInset = { EmptyView() },
        @ViewBuilder detail: @escaping () -> Detail
    ) async throws -> NSWindow {
        try await host(AnyView(
            NavigationSplitView(columnVisibility: .constant(.all)) {
                Color.gray.navigationSplitViewColumnWidth(
                    min: ProjectWindow.binderColumnFloor, ideal: 240)
            } content: {
                Color.white
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) { centreTopInset() }
                    .navigationSplitViewColumnWidth(
                        min: ProjectWindow.centreColumnFloor, ideal: 720)
            } detail: {
                detail().navigationSplitViewColumnWidth(
                    ProjectWindow.effectiveDetailColumnWidth(
                        persisted: UIState.defaultDetailColumnWidth,
                        containerWidth: 1200))
            }
            .frame(minWidth: ProjectWindow.windowFloor, minHeight: 540)))
    }

    private func host(_ view: AnyView) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: windowHeight)
        let hosting = NSHostingView(
            rootView: AnyView(view.environment(UserPreferences())))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await waitOut(1.0)
        return window
    }

    private func splitView(in window: NSWindow) throws -> NSSplitView {
        var splits: [NSSplitView] = []
        collect(NSSplitView.self, in: try XCTUnwrap(window.contentView), into: &splits)
        let split = try XCTUnwrap(splits.first,
                                  "the NavigationSplitView never reached the "
                                  + "hierarchy — nothing here measures anything")
        XCTAssertEqual(split.arrangedSubviews.count, 3, "premise: three columns")
        return split
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}
