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

    // MARK: - The Tasks toolbar (retired)
    //
    // Its fit claims went with the Tasks pane (shell plan 2 Task 7); To
    // resolve's filter bar is measured by
    // `test_theFilterBarFitsTheColumnFloor` (`ResolvePaneTests`).

    // MARK: - To resolve's filter bar

    /// **Every chip and both trailing controls**, with long pass names: the
    /// chips scroll sideways, so the bar takes the width it is offered at the
    /// floor and at the default, and its trailing controls stay on the column.
    func test_theFilterBarFitsTheColumnFloor() {
        let passes = (1...4).map {
            ReviewPass(id: "p\($0)", name: "A long structural pass number \($0)")
        }
        let bar = ResolveFilterBar(
            chips: passes.map { .pass($0.id) } + [.mine, .checks, .questions, .others],
            selection: [.mine], passes: passes,
            showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
            onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
        let chipLabels = HStack(spacing: 4) {
            ForEach(bar.chips, id: \.self) { chip in
                Text(ResolveFilterBar.label(chip, passes: passes)).font(.caption).fixedSize()
                    .padding(.horizontal, 8)
            }
        }
        XCTAssertGreaterThan(Self.idealWidth(of: chipLabels), Self.ceiling,
                             "premise: the chips alone want more than the widest column")
        for width in Self.paneWidths {
            let (fits, measured) = Self.fits(bar, in: width)
            XCTAssertTrue(fits,
                "To resolve's filter bar wants \(measured)pt in a \(width)pt pane — "
                + "an over-wide row is cropped by the column (#122)")
        }
    }

    /// **With the triage control** (Task 7b): the chips still scroll, and the
    /// triage menu sits beside them as one icon, so the bar fits the column
    /// from its floor to its ceiling whatever choice is made.
    func test_theFilterBarWithTheTriageControlFitsTheNarrowColumn() {
        let passes = (1...4).map {
            ReviewPass(id: "p\($0)", name: "A long structural pass number \($0)")
        }
        for choice in ResolveTriageChoice.allCases {
            let bar = ResolveFilterBar(
                chips: passes.map { .pass($0.id) } + [.mine, .checks, .questions, .others],
                selection: [.mine], passes: passes,
                showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
                checksUnread: true, triage: choice,
                onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
            for width in Self.paneWidths + [Self.ceiling] {
                let (fits, measured) = Self.fits(bar, in: width)
                XCTAssertTrue(fits, "with triage \(choice) the bar wants \(measured)pt in a \(width)pt pane")
            }
        }
    }

    /// **The active choice's word is drawn, not dropped** (Task 7b fix): the
    /// bar with a choice on asks for more width than the bare flag — the
    /// word is there — and still fits every width (it wraps beneath the
    /// chips rather than clipping or reverting to the bare icon).
    func test_theActiveTriageWordIsDrawnAndStillFits() {
        func bar(_ choice: ResolveTriageChoice) -> ResolveFilterBar {
            ResolveFilterBar(chips: [.mine, .others], selection: [], passes: [],
                             showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
                             triage: choice, onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
        }
        let bare = Self.idealWidth(of: bar(.all))
        for choice in ResolveTriageChoice.allCases where choice != .all {
            XCTAssertGreaterThan(Self.idealWidth(of: bar(choice)), bare + 10,
                                 "\(choice)'s word must be drawn beside the flag")
            for width in Self.paneWidths + [Self.ceiling] {
                let (fits, measured) = Self.fits(bar(choice), in: width)
                XCTAssertTrue(fits, "\(choice) wants \(measured)pt in \(width)pt")
            }
        }
    }

    /// **The wrapped arm, measured** (Task 7b deferred minor): with more
    /// chips than any column holds and each choice, the arm that puts the
    /// triage control beneath the chips fits every width on its own.
    func test_theTriageControlsWrappedArmFitsWithMoreChipsThanFit() {
        let passes = (1...4).map {
            ReviewPass(id: "p\($0)", name: "A long structural pass number \($0)")
        }
        for choice in ResolveTriageChoice.allCases {
            let bar = ResolveFilterBar(
                chips: passes.map { .pass($0.id) } + [.mine, .checks, .questions, .others],
                selection: [.mine], passes: passes,
                showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
                triage: choice, onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
            for width in Self.paneWidths + [Self.ceiling] {
                let (fits, measured) = Self.fits(bar.wrapped, in: width)
                XCTAssertTrue(fits, "wrapped arm, \(choice): \(measured)pt in \(width)pt")
            }
        }
    }

    /// **The bare All flag keeps the chips' row** (review minor): however
    /// wide the chip set, the bar under All is one row tall — the flag is
    /// not pushed beneath the chips merely because they scroll.
    func test_theBareAllFlagStaysOnTheChipsRowHoweverWideTheChips() {
        let passes = (1...4).map {
            ReviewPass(id: "p\($0)", name: "A long structural pass number \($0)")
        }
        func bar(_ chips: [ResolveSource]) -> ResolveFilterBar {
            ResolveFilterBar(chips: chips, selection: [], passes: passes,
                             showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
                             triage: .all, onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
        }
        let wide = bar(passes.map { .pass($0.id) } + [.mine, .checks, .questions, .others])
        let narrow = bar([.mine])
        for width in Self.paneWidths + [Self.ceiling] {
            let oneRow = Self.size(of: narrow, proposing: width).height
            let measured = Self.size(of: wide, proposing: width)
            XCTAssertLessThanOrEqual(measured.width, width + Self.slack)
            XCTAssertEqual(measured.height, oneRow, accuracy: 1,
                           "under All at \(width)pt the wide bar is one row, like the narrow one")
            XCTAssertGreaterThan(Self.size(of: wide.wrapped, proposing: width).height, oneRow + 5,
                                 "control: the wrapped arm is taller, so the height check can fail")
        }
    }

    // MARK: - The census: every pane the right column can show

    /// **Every `DetailSegment`, walked off `allCases`**, rendered by the real
    /// `DetailPaneToggle` over real stores, with `InspectorView` as its
    /// inspector arm — so the pane picker and each pane's header are measured
    /// together, and a new pane joins by existing.
    ///
    /// Before #122 it failed on two panes: Tasks (the one-row toolbar, 392pt)
    /// and the Inspector (`InspectorView`'s `minWidth: 240`), both at 232pt.
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
            for width in Self.paneWidths {
                let (fits, measured) = Self.fits(fixture.pane(segment), in: width)
                if !fits { offenders.append("\(segment) → \(measured)pt in \(width)pt") }
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
        func pane(_ segment: DetailSegment) -> some View {
            DetailPaneToggle(
                store: store,
                segment: .constant(segment),
                selectedSubject: .constant(.item(itemId)),
                activeManuscriptItemId: itemId,
                subject: WindowSubject(open: .item(itemId), faces: .item(itemId)),
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
        "Maugham/Views/InboxPane.swift",
    ]

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = SourceTree.repoRoot.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }
}
