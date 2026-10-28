import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Every right-column pane fits the narrowest column a writer can have** (#122).
///
/// Denver's smoke, macOS 27: the Tasks toolbar's … menu sat half off the
/// column's trailing edge and its Doc/Project picker was cut at the leading
/// edge. The toolbar wanted about 300pt on one row; the pane is drawn at the
/// column's width less the resize handle, 272pt by default and 232pt at the
/// floor. An over-wide pane inflates its own layout width, and `RightColumn`'s
/// frame then clipped it — centred, so on both edges.
///
/// **The instrument is `AnnotationsQueueToolbarWidthTests`'**: a proposal, not
/// a frame walk. `NSHostingController.sizeThatFits(in:)` offers the content a
/// width and returns the width it takes; overflow is `measured > proposed`.
/// Windowless: nothing here is mounted or pressed (tripwire 33).
@MainActor
final class RightColumnPaneWidthTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // The panes style text through production typography.
        FontWarmup.ensure()
    }

    // MARK: - The widths a pane is drawn at

    /// A pane gets the column's width less the resize handle's gutter.
    private static func paneWidth(column: Double) -> CGFloat {
        CGFloat(column) - RightColumn.resizeHandleWidth
    }

    /// The narrowest a pane is ever drawn: the floor a writer can drag to.
    private static var floor: CGFloat {
        paneWidth(column: UIState.detailColumnWidthRange.lowerBound)
    }

    /// The floor and the default, the width Denver's screenshot was taken in.
    private static var paneWidths: [CGFloat] {
        [floor, paneWidth(column: UIState.defaultDetailColumnWidth)]
    }

    private static var ceiling: CGFloat {
        paneWidth(column: UIState.detailColumnWidthRange.upperBound)
    }

    /// Sub-pixel slack for SwiftUI's rounding to the backing scale.
    private static let slack: CGFloat = 0.5

    // MARK: - The instrument

    private static func size(of view: some View, proposing width: CGFloat) -> CGSize {
        let controller = NSHostingController(rootView: AnyView(view))
        _ = controller.view
        return controller.sizeThatFits(in: CGSize(width: width, height: 4000))
    }

    private static func fits(_ view: some View, in width: CGFloat) -> (Bool, CGFloat) {
        let measured = size(of: view, proposing: width).width
        return (measured <= width + slack, measured)
    }

    /// What a variant asks for before any column squeezes it — the ideal under
    /// an unspecified proposal (a row holding a `Spacer` fills any proposal, so
    /// `sizeThatFits` cannot answer this).
    private static func idealWidth(of view: some View) -> CGFloat {
        NSHostingView(rootView: AnyView(view)).intrinsicContentSize.width
    }

    // MARK: - The planted control

    /// The check says no to an over-wide view and yes to a flexible one, so a
    /// green census below is a measurement and not a check that cannot fail.
    func test_theCheckFailsAnOverWideViewAndPassesAFlexibleOne() {
        let overWide = HStack(spacing: 0) {
            Text("Doc · Project").fixedSize()
            Color.clear.frame(width: Self.floor + 40, height: 20)
        }
        let (overFits, overMeasured) = Self.fits(overWide, in: Self.floor)
        XCTAssertFalse(overFits,
            "a fixed \(Self.floor + 40)pt row measured \(overMeasured)pt at the "
            + "\(Self.floor)pt floor — the instrument cannot see overflow")

        let flexible = HStack { Text("Doc"); Spacer(); Text("…") }
        XCTAssertTrue(Self.fits(flexible, in: Self.floor).0,
                      "the control: a flexible row fits")

        // **Why no pane wears `.frame(minWidth: 0, …)` as a "safety net".** It
        // answers the proposed width whatever its content wants, so this
        // instrument reads it as fitting — and it centres the overflow inside
        // itself, cropping both edges again. The one net is `RightColumn`'s
        // leading-aligned clip; the rule is that every pane fits.
        let (maskedFits, _) = Self.fits(
            overWide.frame(minWidth: 0, maxWidth: .infinity), in: Self.floor)
        XCTAssertTrue(maskedFits,
            "measured fact this census relies on: a minWidth-0 frame hides "
            + "its content's overflow from sizeThatFits")
    }

    // MARK: - The Tasks toolbar

    /// Every optional control drawn: + and the … menu.
    private func tasksToolbar(variant: TasksPaneToolbar.Variant? = nil) -> some View {
        TasksPaneToolbar(
            scope: .constant(.project),
            statusFilter: .constant(.open),
            showsNewTask: true,
            newTaskDisabled: false,
            showsBulkMenu: true,
            onNewTask: {},
            onArchiveAllDone: {},
            variant: variant)
    }

    /// **The headline claim.** At the floor and at the default the toolbar takes
    /// the width it is offered and no more.
    func test_theTasksToolbarFitsTheColumn() {
        for width in Self.paneWidths {
            let (fits, measured) = Self.fits(tasksToolbar(), in: width)
            XCTAssertTrue(fits,
                "the Tasks toolbar wants \(measured)pt in a \(width)pt pane — "
                + "an over-wide row is cropped by the column (#122)")
        }
    }

    /// **`ViewThatFits` draws its last child whether it fits or not**, so the
    /// two-row fallback must itself fit the floor — with every control in it.
    func test_theTasksToolbarsLastVariantFitsTheFloor() {
        let (fits, measured) = Self.fits(tasksToolbar(variant: .twoRows), in: Self.floor)
        XCTAssertTrue(fits,
            "the two-row fallback wants \(measured)pt at the \(Self.floor)pt "
            + "floor; it is drawn there regardless, and cropped")
    }

    /// **Every variant is reachable inside the column's own range**, and the
    /// widest really is drawn at the ceiling — otherwise a toolbar that stacked
    /// at every width would pass the fit claims above.
    func test_everyTasksToolbarVariantIsReachable() {
        for variant in TasksPaneToolbar.Variant.allCases {
            let ideal = Self.idealWidth(of: tasksToolbar(variant: variant))
            XCTAssertLessThanOrEqual(ideal, Self.ceiling,
                "\(variant) wants \(ideal)pt and the widest pane is "
                + "\(Self.ceiling)pt: it can never be drawn")
        }
        let atCeiling = Self.size(of: tasksToolbar(), proposing: Self.ceiling)
        let stacked = Self.size(of: tasksToolbar(variant: .twoRows), proposing: Self.ceiling)
        XCTAssertLessThan(atCeiling.height, stacked.height,
            "at the widest column the toolbar is on one row "
            + "(\(atCeiling.height)pt), not stacked (\(stacked.height)pt)")
    }

    // MARK: - The census: every pane the right column can show

    /// **Every `DetailSegment`, walked off `allCases`**, rendered by the real
    /// `DetailPaneToggle` over real stores, with `InspectorView` as its
    /// inspector arm — so the pane picker and each pane's header are measured
    /// together, and a new pane joins by existing.
    ///
    /// Each pane is measured in its first-render state over a fresh novel with
    /// one open document. What it cannot see: content a pane loads in a
    /// `.task` after its first frame, and the panes the column shows outside
    /// `DetailPaneToggle` (the study column, the canvas's region inspector, a
    /// Collection's piece inspectors).
    func test_noRightColumnPaneIsWiderThanTheColumn() async throws {
        let fixture = try await makeFixture()
        var offenders: [String] = []
        for segment in DetailSegment.allCases {
            let persona = Persona.allCases.first { $0.panes.contains(segment) } ?? .author
            for width in Self.paneWidths {
                let (fits, measured) = Self.fits(fixture.pane(segment, persona), in: width)
                if !fits { offenders.append("\(segment) (\(persona)) → \(measured)pt in \(width)pt") }
            }
        }
        XCTAssertEqual(offenders, [],
            "these right-column panes are wider than the pane they are drawn "
            + "in, and the column crops them (#122):\n"
            + offenders.joined(separator: "\n"))
    }

    private struct Fixture {
        let store: ProjectStore
        let documentStore: DocumentStore
        let docId: String
        let itemId: String
        /// The app injects these at its root; the annotation and statement
        /// panes read them.
        let preferences: UserPreferences

        @MainActor
        func pane(_ segment: DetailSegment, _ persona: Persona) -> some View {
            DetailPaneToggle(
                store: store,
                segment: .constant(segment),
                selectedSubject: .constant(.item(itemId)),
                activeManuscriptItemId: itemId,
                persona: persona,
                projectURL: store.url,
                activeDocId: docId,
                allDocIds: [docId],
                device: "test-mac",
                session: "s1",
                docPaths: [:],
                documentStore: documentStore,
                editorControl: EditorControl(),
                compilerModel: .standard,
                assistant: AssistantColumnModel()
            ) {
                InspectorView(store: store, selectedItemId: itemId,
                              metrics: EditorMetrics(wordCount: 0, characterCount: 0,
                                                     readingMinutes: 0),
                              onOpenProjectSettings: {}, posture: .author)
            }
            .environment(AgentRoster())
            .environment(preferences)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let url = try await ProjectFactory.createNovelProject(
            named: "Width-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        let item = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure, where: { $0.path != nil }).first,
            "premise: the novel template has a document to open")
        let path = try XCTUnwrap(item.path)
        try "- [ ] A task with a long enough body to wrap in a narrow column.\n\nA paragraph."
            .write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let document = try await Document.load(url: url.appendingPathComponent(path),
                                               device: "macA", session: "s1", presenter: nil)
        documentStore.register(document: document, for: path)
        let suite = "RightColumnPaneWidth-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Fixture(store: store, documentStore: documentStore,
                       docId: document.docId, itemId: item.id,
                       preferences: UserPreferences(defaults: UserDefaults(suiteName: suite)!))
    }

    // MARK: - No list paints a fill of its own

    /// **A right-column pane's `List` hides its content background.** A
    /// `.sidebar` list paints the sidebar material and an `.inset` one its own
    /// fill; no other pane has either (#122's grey column). A grep census,
    /// narrow on purpose: the right-column panes that hold a `List`, each
    /// `.listStyle(` matched by a `.scrollContentBackground(.hidden)`.
    func test_everyRightColumnListHidesItsContentBackground() throws {
        for file in Self.rightColumnListFiles {
            let lines = try Self.codeLines(of: file)
            let styles = lines.filter { $0.contains(".listStyle(") }.count
            let hidden = lines.filter { $0.contains(".scrollContentBackground(.hidden)") }.count
            XCTAssertGreaterThan(styles, 0, "premise: \(file) styles a List")
            XCTAssertEqual(hidden, styles,
                "\(file) has \(styles) styled List(s) and \(hidden) hidden "
                + "content background(s): a list without one paints a fill the "
                + "other right-column panes do not have (#122)")
        }
    }

    /// The right-column panes that hold a `List`.
    private static let rightColumnListFiles = [
        "Maugham/Views/TasksPane.swift",
        "Maugham/Views/InboxPane.swift",
    ]

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = SourceTree.repoRoot.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }
}
